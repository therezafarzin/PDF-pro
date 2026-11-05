import Foundation
import CryptoKit

/// Content-based document identity. Independent of file name and location, so renamed or
/// moved files keep their annotations and reading position.
///
/// The fingerprint hashes the file size plus three 256 KB samples (head, middle, tail),
/// which is fast even for multi-hundred-megabyte textbooks.
enum DocumentFingerprint {
    static let sampleSize = 256 * 1024

    static func compute(url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let size = try fh.seekToEnd()
        var hasher = SHA256()
        hasher.update(data: Data("PDFStudy-v1|\(size)|".utf8))

        func sample(at offset: UInt64) throws -> Data {
            try fh.seek(toOffset: offset)
            return try fh.read(upToCount: sampleSize) ?? Data()
        }
        hasher.update(data: try sample(at: 0))
        if size > UInt64(sampleSize * 2) {
            hasher.update(data: try sample(at: size / 2 - UInt64(sampleSize / 2)))
            hasher.update(data: try sample(at: size - UInt64(sampleSize)))
        } else if size > UInt64(sampleSize) {
            hasher.update(data: try sample(at: UInt64(sampleSize)))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
