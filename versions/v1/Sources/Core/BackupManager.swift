import Foundation

/// Periodic database backups with rotation. Backups are complete, openable SQLite files.
struct BackupManager {
    let directory: URL
    var keep: Int = 30

    init(directory: URL = Store.defaultDirectory().appendingPathComponent("Backups", isDirectory: true), keep: Int = 30) {
        self.directory = directory
        self.keep = keep
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    @discardableResult
    func backup(_ store: Store, label: String = "auto") throws -> URL {
        let name = "library-\(Self.formatter.string(from: Date()))-\(label).sqlite"
        let dest = directory.appendingPathComponent(name)
        try store.db.backup(to: dest)
        prune()
        return dest
    }

    func list() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "sqlite" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func prune() {
        let files = list()
        guard files.count > keep else { return }
        for f in files.dropFirst(keep) { try? FileManager.default.removeItem(at: f) }
    }

    /// Directory for copies of original PDFs made before they are modified in place.
    static func originalsDirectory() -> URL {
        let dir = Store.defaultDirectory().appendingPathComponent("Original PDF Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
