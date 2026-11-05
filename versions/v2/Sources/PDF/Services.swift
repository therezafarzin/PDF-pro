import AppKit
import PDFKit
import Vision
import AVFoundation

// MARK: - File access (security-scoped bookmarks)

enum FileAccess {
    private static var accessed: [String: URL] = [:]

    static func makeBookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    /// Resolves the file for a library record: bookmark first (survives rename/move), then stored path.
    static func resolve(_ record: DocumentRecord) -> (url: URL, bookmark: Data?, moved: Bool)? {
        if let data = record.bookmark {
            var stale = false
            if let url = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)),
               FileManager.default.fileExists(atPath: url.path) || url.startAccessingSecurityScopedResource() {
                return (url, stale ? makeBookmark(for: url) : nil, url.path != record.path)
            }
        }
        let url = URL(fileURLWithPath: record.path)
        return FileManager.default.fileExists(atPath: url.path) ? (url, nil, false) : nil
    }

    static func begin(_ url: URL) {
        if accessed[url.path] == nil, url.startAccessingSecurityScopedResource() { accessed[url.path] = url }
    }
    static func end(_ url: URL) {
        if let u = accessed.removeValue(forKey: url.path) { u.stopAccessingSecurityScopedResource() }
    }
}

// MARK: - Document registration

@MainActor
enum DocumentService {
    /// Finds or creates the library record for a file. Identity is content-based, so renamed/moved
    /// files are recognised; if the same path now has different bytes (re-saved by another app) the
    /// existing record is migrated to the new fingerprint so notes and position are kept.
    static func register(url: URL, store: Store) async throws -> DocumentRecord {
        FileAccess.begin(url)
        let fp = try await Task.detached(priority: .userInitiated) { try DocumentFingerprint.compute(url: url) }.value
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attrs?[.modificationDate] as? Date
        let bookmark = FileAccess.makeBookmark(for: url)

        var record: DocumentRecord
        if var existing = store.document(id: fp) {
            existing.path = url.path; existing.bookmark = bookmark ?? existing.bookmark
            existing.fileSize = size; existing.fileModifiedAt = modified
            record = existing
        } else if let byPath = store.document(path: url.path) {
            try store.rekeyDocument(from: byPath.id, to: fp)
            var moved = byPath; moved.id = fp; moved.bookmark = bookmark ?? byPath.bookmark
            moved.fileSize = size; moved.fileModifiedAt = modified
            record = moved
            store.clearPDFIndex(docID: fp); store.setIndexed(fp, nil)
        } else {
            let doc = PDFDocument(url: url)
            let title = (doc?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? url.deletingPathExtension().lastPathComponent
            record = DocumentRecord(id: fp, title: title, path: url.path, bookmark: bookmark, pageCount: doc?.pageCount ?? 0,
                                    fileSize: size, addedAt: Date(), lastOpenedAt: nil, fileModifiedAt: modified)
        }
        try store.upsertDocument(record)
        return store.document(id: fp) ?? record
    }
}

// MARK: - Thumbnails

@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()
    private let cache = NSCache<NSString, NSImage>()
    private let dir: URL = {
        let d = Store.defaultDirectory().appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func thumbnail(for record: DocumentRecord) async -> NSImage? {
        let key = record.id as NSString
        if let img = cache.object(forKey: key) { return img }
        let file = dir.appendingPathComponent("\(record.id).png")
        if let img = NSImage(contentsOf: file) { cache.setObject(img, forKey: key); return img }
        guard let resolved = FileAccess.resolve(record) else { return nil }
        let url = resolved.url
        let data: Data? = await Task.detached(priority: .utility) {
            guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
            let img = page.thumbnail(of: CGSize(width: 360, height: 480), for: .cropBox)
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .png, properties: [:])
        }.value
        guard let data, let img = NSImage(data: data) else { return nil }
        try? data.write(to: file)
        cache.setObject(img, forKey: key)
        return img
    }

    func invalidate(_ id: String) {
        cache.removeObject(forKey: id as NSString)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).png"))
    }
}

// MARK: - Background PDF text indexer (cross-document search)

@MainActor
final class PDFTextIndexer: ObservableObject {
    @Published var activeTitle: String?
    @Published var progress: Double = 0
    private var queue: [DocumentRecord] = []
    private var running = false
    private let store: Store

    init(store: Store) { self.store = store }

    func enqueue(_ records: [DocumentRecord]) {
        for r in records where r.indexedAt == nil && !queue.contains(where: { $0.id == r.id }) { queue.append(r) }
        if !running { Task { await run() } }
    }

    private func run() async {
        running = true
        defer { running = false; activeTitle = nil }
        while !queue.isEmpty {
            let record = queue.removeFirst()
            guard let resolved = FileAccess.resolve(record) else { continue }
            activeTitle = record.title; progress = 0
            let store = self.store
            let url = resolved.url
            let ok: Bool = await Task.detached(priority: .background) { [weak self] in
                guard let doc = PDFDocument(url: url), !doc.isLocked else { return false }
                store.clearPDFIndex(docID: record.id)
                var batch: [(Int, String)] = []
                let total = doc.pageCount
                for i in 0..<total {
                    autoreleasepool {
                        if let s = doc.page(at: i)?.string, !s.isEmpty { batch.append((i, s)) }
                    }
                    if batch.count >= 20 || i == total - 1 {
                        try? store.indexPDFPages(docID: record.id, pages: batch); batch.removeAll()
                        let p = Double(i + 1) / Double(max(total, 1))
                        Task { @MainActor in self?.progress = p }
                    }
                }
                return true
            }.value
            if ok { store.setIndexed(record.id, Date()) }
        }
    }
}

// MARK: - OCR (Vision, on-device, optional)

enum OCRService {
    /// Recognises text on one page with Apple's on-device Vision framework. Languages the current
    /// macOS version does not support are skipped. Recognised text is only used for search/copy;
    /// it is not embedded as a selectable text layer.
    static func recognize(page: PDFPage) async -> String {
        let box = page.bounds(for: .cropBox)
        let scale: CGFloat = 2.5
        let size = CGSize(width: box.width * scale, height: box.height * scale)
        let image = page.thumbnail(of: size, for: .cropBox)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let supported = (try? request.supportedRecognitionLanguages()) ?? []
            let wanted = ["de-DE", "en-US", "fa-IR", "ar-SA"].filter { supported.contains($0) }
            if !wanted.isEmpty { request.recognitionLanguages = wanted }
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }
}

// MARK: - Text to speech

@MainActor
final class Speaker {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()
    func speakGerman(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "de-DE")
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synth.speak(u)
    }
    func stop() { synth.stopSpeaking(at: .immediate) }
}
