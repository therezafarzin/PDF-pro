import Foundation
import CoreGraphics

// MARK: - Inputs

struct ToolInput: Identifiable, Hashable {
    let id = UUID()
    var url: URL
    /// Optional page selection such as "1-3, 8". Empty = all pages.
    var pages: String = ""
    var password: String = ""

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "bmp"]
    var isImage: Bool { Self.imageExtensions.contains(url.pathExtension.lowercased()) }
    var displayName: String { url.deletingPathExtension().lastPathComponent }
}

// MARK: - Splitting

enum SplitMode: Equatable {
    case everyN(Int)
    case singlePages
    /// 1-based page numbers where a new file starts (page 1 is implicit).
    case startingAt([Int])
    /// 0-based inclusive ranges, one output file each.
    case ranges([ClosedRange<Int>])
    /// 0-based start pages, e.g. of top-level bookmarks (page 0 is implicit).
    case outline([Int])
}

enum SplitPlanner {
    /// Returns contiguous/explicit 0-based page ranges, one per output file.
    static func plan(pageCount n: Int, mode: SplitMode) -> [ClosedRange<Int>] {
        guard n > 0 else { return [] }
        switch mode {
        case .everyN(let k):
            let size = max(1, k)
            return stride(from: 0, to: n, by: size).map { $0...min($0 + size - 1, n - 1) }
        case .singlePages:
            return (0..<n).map { $0...$0 }
        case .startingAt(let pages):
            let starts = Set(pages.map { $0 - 1 }.filter { $0 > 0 && $0 < n }).union([0]).sorted()
            return segments(starts: starts, n: n)
        case .outline(let raw):
            let starts = Set(raw.filter { $0 >= 0 && $0 < n }).union([0]).sorted()
            return segments(starts: starts, n: n)
        case .ranges(let rs):
            return rs.compactMap { r in
                let lo = max(r.lowerBound, 0), hi = min(r.upperBound, n - 1)
                return lo <= hi ? lo...hi : nil
            }
        }
    }

    private static func segments(starts: [Int], n: Int) -> [ClosedRange<Int>] {
        starts.enumerated().map { i, s in s...((i + 1 < starts.count ? starts[i + 1] : n) - 1) }
    }

    /// "1-5, 8, 10-12" -> one range per comma item (items are NOT merged). Text is 1-based.
    static func parseRangeGroups(_ text: String, pageCount: Int) -> [ClosedRange<Int>]? {
        let cleaned = text.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "،", with: ",")
        var result: [ClosedRange<Int>] = []
        for part in cleaned.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let s = part.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            let b = s.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if b.count == 1, let v = Int(b[0]), (1...max(pageCount, 1)).contains(v) {
                result.append((v - 1)...(v - 1))
            } else if b.count == 2, let a = Int(b[0]), let c = Int(b[1]), a >= 1, a <= c, c <= pageCount {
                result.append((a - 1)...(c - 1))
            } else { return nil }
        }
        return result.isEmpty ? nil : result
    }

    /// "10, 25, 40" -> [10, 25, 40] (1-based page numbers where a new file starts).
    static func parseStartPages(_ text: String, pageCount: Int) -> [Int]? {
        let cleaned = text.replacingOccurrences(of: "،", with: ",")
        var result: [Int] = []
        for part in cleaned.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }) {
            guard let v = Int(part.trimmingCharacters(in: .whitespaces)), v >= 1, v <= pageCount else { return nil }
            result.append(v)
        }
        return result.isEmpty ? nil : result
    }
}

// MARK: - File names

enum FileNaming {
    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        var out = s.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
        out = out.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if out.count > 120 { out = String(out.prefix(120)) }
        return out.isEmpty ? "Untitled" : out
    }

    /// "pages 001-010" / "page 007" (zero padded to the width of the page count).
    static func rangeLabel(_ r: ClosedRange<Int>, pageCount: Int) -> String {
        let w = max(String(pageCount).count, 1)
        func p(_ v: Int) -> String { String(format: "%0\(w)ld", v + 1) }
        return r.lowerBound == r.upperBound ? "page \(p(r.lowerBound))" : "pages \(p(r.lowerBound))-\(p(r.upperBound))"
    }

    /// Never overwrites: "Name.pdf", "Name 2.pdf", "Name 3.pdf" …
    static func uniqueURL(directory: URL, baseName: String, ext: String) -> URL {
        let fm = FileManager.default
        let base = sanitize(baseName)
        var url = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var i = 2
        while fm.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(i)").appendingPathExtension(ext)
            i += 1
        }
        return url
    }
}

// MARK: - Optimize / convert settings

enum OptimizePreset: String, CaseIterable, Identifiable {
    case lossless, balanced, strong
    var id: String { rawValue }
    var title: String {
        switch self { case .lossless: return "Lossless clean-up"; case .balanced: return "Balanced"; case .strong: return "Strong (images only)" }
    }
    var detail: String {
        switch self {
        case .lossless: return "Rewrites the file and drops unused data. Text and images are untouched. Small savings."
        case .balanced: return "Recompresses images as JPEG sized for screen. Text stays selectable and sharp. Usually 30–70 % smaller."
        case .strong: return "Turns every page into a compressed picture. Smallest files, but text is no longer selectable unless you keep it searchable with OCR."
        }
    }
}

enum ConvertFormat: String, CaseIterable, Identifiable {
    case png, jpeg, tiff, txt, rtf, html
    var id: String { rawValue }
    var title: String {
        switch self {
        case .png: return "PNG images"; case .jpeg: return "JPEG images"; case .tiff: return "TIFF images"
        case .txt: return "Plain text (.txt)"; case .rtf: return "Rich text (.rtf)"; case .html: return "HTML text (.html)"
        }
    }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var isImage: Bool { self == .png || self == .jpeg || self == .tiff }
}

// MARK: - Page editing model (pure value type, fully undoable)

struct PageItem: Identifiable, Equatable {
    var id = UUID()
    /// Index into the list of source documents (0 = the document being edited).
    var source: Int
    var page: Int
    /// Extra rotation (degrees, multiple of 90) applied on save.
    var rotation: Int = 0
    var blankSize: CGSize? = nil
    var isBlank: Bool { blankSize != nil }
}

struct PageEditPlan {
    private(set) var items: [PageItem]
    private let original: [PageItem]
    private var undoStack: [[PageItem]] = []
    private var redoStack: [[PageItem]] = []

    init(pageCount: Int) {
        items = (0..<max(pageCount, 0)).map { PageItem(source: 0, page: $0) }
        original = items
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isModified: Bool { items != original }

    private mutating func push() { undoStack.append(items); redoStack.removeAll() }

    mutating func undo() { guard let last = undoStack.popLast() else { return }; redoStack.append(items); items = last }
    mutating func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(items); items = next }

    mutating func rotate(_ ids: Set<UUID>, by degrees: Int) {
        guard !ids.isEmpty else { return }
        push()
        items = items.map { var i = $0; if ids.contains(i.id) { i.rotation = ((i.rotation + degrees) % 360 + 360) % 360 }; return i }
    }

    /// Returns false (and changes nothing) if it would delete every page.
    @discardableResult
    mutating func delete(_ ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty, items.contains(where: { !ids.contains($0.id) }) else { return false }
        push()
        items.removeAll { ids.contains($0.id) }
        return true
    }

    mutating func duplicate(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        push()
        var out: [PageItem] = []
        for item in items {
            out.append(item)
            if ids.contains(item.id) { var c = item; c.id = UUID(); out.append(c) }
        }
        items = out
    }

    private func insertionIndex(after id: UUID?) -> Int {
        guard let id, let i = items.firstIndex(where: { $0.id == id }) else { return items.count }
        return i + 1
    }

    mutating func insertBlank(after id: UUID?, size: CGSize) {
        push()
        items.insert(PageItem(source: 0, page: 0, blankSize: size), at: insertionIndex(after: id))
    }

    mutating func insertPages(source: Int, pages: [Int], after id: UUID?) {
        guard !pages.isEmpty else { return }
        push()
        items.insert(contentsOf: pages.map { PageItem(source: source, page: $0) }, at: insertionIndex(after: id))
    }

    /// Moves the selected pages (keeping their relative order) so they sit before position `destination`
    /// (an index into the current list, 0...count).
    mutating func move(_ ids: Set<UUID>, to destination: Int) {
        guard !ids.isEmpty else { return }
        let moving = items.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        push()
        let dest = max(0, min(destination, items.count))
        let before = items.prefix(dest).filter { !ids.contains($0.id) }.count
        var rest = items.filter { !ids.contains($0.id) }
        rest.insert(contentsOf: moving, at: min(before, rest.count))
        items = rest
    }

    mutating func reverse() { push(); items.reverse() }
}

// MARK: - Signatures (local drawn signatures)

struct SavedSignature: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Strokes normalised to 0...1 inside their bounding box, origin top-left.
    var strokes: [[CGPoint]]
    /// width / height of the bounding box.
    var aspect: Double
}

enum SignatureMath {
    static func normalize(_ strokes: [[CGPoint]]) -> (strokes: [[CGPoint]], aspect: Double)? {
        let pts = strokes.flatMap { $0 }
        guard pts.count >= 2 else { return nil }
        let b = GeometryMath.boundingRect(of: pts)
        let w = max(b.width, 1), h = max(b.height, 1)
        return (strokes.map { $0.map { CGPoint(x: ($0.x - b.minX) / w, y: ($0.y - b.minY) / h) } }, Double(w / h))
    }
}

extension Store {
    func signatures() -> [SavedSignature] {
        guard let json = value(for: "signatures"), let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SavedSignature].self, from: data)) ?? []
    }
    func saveSignatures(_ list: [SavedSignature]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        setValue(String(decoding: data, as: UTF8.self), for: "signatures")
    }
}
