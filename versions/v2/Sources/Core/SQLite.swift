import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

struct SQLiteError: Error, CustomStringConvertible {
    let message: String
    let code: Int32
    var description: String { "SQLite error \(code): \(message)" }
}

enum SQLValue {
    case null, int(Int64), double(Double), text(String), blob(Data)
}

protocol SQLConvertible { var sqlValue: SQLValue { get } }
extension String: SQLConvertible { var sqlValue: SQLValue { .text(self) } }
extension Int: SQLConvertible { var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLConvertible { var sqlValue: SQLValue { .int(self) } }
extension Double: SQLConvertible { var sqlValue: SQLValue { .double(self) } }
extension Bool: SQLConvertible { var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Data: SQLConvertible { var sqlValue: SQLValue { .blob(self) } }
extension Date: SQLConvertible { var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
extension UUID: SQLConvertible { var sqlValue: SQLValue { .text(uuidString) } }
extension Optional: SQLConvertible where Wrapped: SQLConvertible {
    var sqlValue: SQLValue { self.map { $0.sqlValue } ?? .null }
}

struct Row {
    let stmt: OpaquePointer
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func bool(_ i: Int32) -> Bool { int(i) != 0 }
    func string(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
    func optString(_ i: Int32) -> String? { isNull(i) ? nil : string(i) }
    func optInt(_ i: Int32) -> Int? { isNull(i) ? nil : int(i) }
    func date(_ i: Int32) -> Date? { isNull(i) ? nil : Date(timeIntervalSince1970: double(i)) }
    func data(_ i: Int32) -> Data? {
        guard !isNull(i) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: n)
    }
}

/// Minimal, thread-safe SQLite wrapper (WAL journaling, recursive lock, nested transactions).
final class SQLiteDB {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var transactionDepth = 0
    let path: String

    init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open"
            sqlite3_close_v2(handle)
            throw SQLiteError(message: msg, code: rc)
        }
        sqlite3_busy_timeout(handle, 5000)
        try exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;")
    }

    deinit { sqlite3_close_v2(handle) }

    private func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown", code: rc)
    }

    func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SQLiteError(message: msg, code: rc)
        }
    }

    private func prepare(_ sql: String, _ params: [any SQLConvertible]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let s = stmt else { throw error(rc) }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let brc: Int32
            switch p.sqlValue {
            case .null: brc = sqlite3_bind_null(s, idx)
            case .int(let v): brc = sqlite3_bind_int64(s, idx, v)
            case .double(let v): brc = sqlite3_bind_double(s, idx, v)
            case .text(let v): brc = sqlite3_bind_text(s, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let d):
                brc = d.withUnsafeBytes { sqlite3_bind_blob(s, idx, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
            }
            guard brc == SQLITE_OK else { sqlite3_finalize(s); throw error(brc) }
        }
        return s
    }

    @discardableResult
    func run(_ sql: String, _ params: [any SQLConvertible] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let s = try prepare(sql, params)
        defer { sqlite3_finalize(s) }
        let rc = sqlite3_step(s)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc) }
        return Int(sqlite3_changes(handle))
    }

    func query<T>(_ sql: String, _ params: [any SQLConvertible] = [], _ map: (Row) -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let s = try prepare(sql, params)
        defer { sqlite3_finalize(s) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW { out.append(map(Row(stmt: s))) }
            else if rc == SQLITE_DONE { break }
            else { throw error(rc) }
        }
        return out
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if transactionDepth > 0 { return try body() }
        try exec("BEGIN IMMEDIATE")
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Consistent online backup into a new file (single-file, WAL-checkpointed).
    func backup(to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        let escaped = destination.path.replacingOccurrences(of: "'", with: "''")
        try exec("VACUUM INTO '\(escaped)'")
    }

    func checkpoint() { try? exec("PRAGMA wal_checkpoint(TRUNCATE)") }
}
