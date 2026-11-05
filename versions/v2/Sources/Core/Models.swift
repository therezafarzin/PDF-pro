import Foundation
import CoreGraphics

// MARK: - Color

/// Platform-neutral color so the model layer stays free of AppKit.
struct RGBA: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    static let black = RGBA(0, 0, 0)
    static let white = RGBA(1, 1, 1)
    static let clear = RGBA(0, 0, 0, 0)

    func with(alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }

    var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255)
    }
}

// MARK: - Study categories

enum StudyCategory: String, Codable, CaseIterable, Identifiable {
    case vocabulary, grammar, definition, exam, review
    var id: String { rawValue }

    var title: String {
        switch self {
        case .vocabulary: return "Vocabulary"
        case .grammar: return "Grammar"
        case .definition: return "Definition"
        case .exam: return "Exam"
        case .review: return "To Review"
        }
    }

    var defaultColor: RGBA {
        switch self {
        case .vocabulary: return RGBA(1.00, 0.86, 0.25)
        case .grammar: return RGBA(0.36, 0.67, 1.00)
        case .definition: return RGBA(0.44, 0.84, 0.50)
        case .exam: return RGBA(1.00, 0.45, 0.40)
        case .review: return RGBA(0.74, 0.55, 0.95)
        }
    }
}

// MARK: - Annotations

enum AnnotationKind: String, Codable, CaseIterable {
    case textBox, stickyNote
    case highlight, underline, strikeThrough, squiggly
    case rectangle, ellipse, line, arrow, ink

    var isMarkup: Bool {
        switch self {
        case .highlight, .underline, .strikeThrough, .squiggly: return true
        default: return false
        }
    }
    var isTextual: Bool { self == .textBox || self == .stickyNote }
    var isStroked: Bool { !isMarkup && !isTextual }
}

struct AnnotationStyle: Codable, Equatable {
    var stroke: RGBA = .black
    var fill: RGBA? = nil
    var strokeWidth: Double = 1
    var opacity: Double = 1
    var cornerRadius: Double = 0
    var padding: Double = 6
    var dashed: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stroke = try c.decodeIfPresent(RGBA.self, forKey: .stroke) ?? .black
        fill = try c.decodeIfPresent(RGBA.self, forKey: .fill)
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 1
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? 6
        dashed = try c.decodeIfPresent(Bool.self, forKey: .dashed) ?? false
    }
}

struct TextContent: Codable, Equatable {
    /// RTF preserves fonts, colors, paragraph direction and mixed scripts.
    var rtf: Data
    /// Plain copy used for search, export and fallbacks.
    var plain: String
    static let empty = TextContent(rtf: Data(), plain: "")
}

/// Persisted annotation. Geometry is stored in PDF page space
/// (origin bottom-left, unrotated crop box) so it survives zoom, scrolling,
/// page rotation and layout changes.
struct AnnotationModel: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: AnnotationKind
    var pageIndex: Int
    var rect: CGRect
    var quads: [CGRect]
    var points: [CGPoint]
    var style: AnnotationStyle
    var text: TextContent?
    var locked: Bool
    var zIndex: Int
    var groupID: UUID?
    var collapsed: Bool
    var category: StudyCategory?
    var createdAt: Date
    var modifiedAt: Date

    init(id: UUID = UUID(), kind: AnnotationKind, pageIndex: Int, rect: CGRect,
         quads: [CGRect] = [], points: [CGPoint] = [], style: AnnotationStyle = AnnotationStyle(),
         text: TextContent? = nil, locked: Bool = false, zIndex: Int = 0, groupID: UUID? = nil,
         collapsed: Bool = false, category: StudyCategory? = nil) {
        self.id = id; self.kind = kind; self.pageIndex = pageIndex; self.rect = rect
        self.quads = quads; self.points = points; self.style = style; self.text = text
        self.locked = locked; self.zIndex = zIndex; self.groupID = groupID
        self.collapsed = collapsed; self.category = category
        self.createdAt = Date(); self.modifiedAt = Date()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(AnnotationKind.self, forKey: .kind)
        pageIndex = try c.decode(Int.self, forKey: .pageIndex)
        rect = try c.decode(CGRect.self, forKey: .rect)
        quads = try c.decodeIfPresent([CGRect].self, forKey: .quads) ?? []
        points = try c.decodeIfPresent([CGPoint].self, forKey: .points) ?? []
        style = try c.decodeIfPresent(AnnotationStyle.self, forKey: .style) ?? AnnotationStyle()
        text = try c.decodeIfPresent(TextContent.self, forKey: .text)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        zIndex = try c.decodeIfPresent(Int.self, forKey: .zIndex) ?? 0
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        category = try c.decodeIfPresent(StudyCategory.self, forKey: .category)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
    }

    var plainText: String { text?.plain ?? "" }

    /// Size of a collapsed sticky note icon in page units.
    static let stickyIconSize: CGFloat = 24

    /// Rect that is actually occupied on the page (collapsed sticky notes are small).
    var occupiedRect: CGRect {
        if kind == .stickyNote && collapsed {
            return CGRect(x: rect.minX, y: rect.maxY - Self.stickyIconSize,
                          width: Self.stickyIconSize, height: Self.stickyIconSize)
        }
        return rect
    }

    func translated(dx: CGFloat, dy: CGFloat) -> AnnotationModel {
        var m = self
        m.rect = rect.offsetBy(dx: dx, dy: dy)
        m.quads = quads.map { $0.offsetBy(dx: dx, dy: dy) }
        m.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        m.modifiedAt = Date()
        return m
    }

    /// Rescale geometry from the old rect to a new rect (used when resizing).
    func resized(to newRect: CGRect) -> AnnotationModel {
        var m = self
        let old = rect
        guard old.width > 0.001, old.height > 0.001 else { m.rect = newRect; return m }
        func mapPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(x: newRect.minX + (p.x - old.minX) / old.width * newRect.width,
                    y: newRect.minY + (p.y - old.minY) / old.height * newRect.height)
        }
        m.points = points.map(mapPoint)
        m.rect = newRect
        m.modifiedAt = Date()
        return m
    }

    /// Hit test in page space.
    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .highlight, .underline, .strikeThrough, .squiggly:
            return quads.contains { $0.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(p) }
        case .textBox, .stickyNote:
            return occupiedRect.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(p)
        case .rectangle:
            if style.fill != nil { return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(p) }
            let outer = rect.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = rect.insetBy(dx: tolerance, dy: tolerance)
            return outer.contains(p) && !(inner.width > 0 && inner.height > 0 && inner.contains(p))
        case .ellipse:
            guard rect.width > 0, rect.height > 0 else { return false }
            let cx = rect.midX, cy = rect.midY
            let rx = rect.width / 2 + tolerance, ry = rect.height / 2 + tolerance
            let v = pow((p.x - cx) / rx, 2) + pow((p.y - cy) / ry, 2)
            if style.fill != nil { return v <= 1 }
            let rxi = max(rect.width / 2 - tolerance, 0.1), ryi = max(rect.height / 2 - tolerance, 0.1)
            let vi = pow((p.x - cx) / rxi, 2) + pow((p.y - cy) / ryi, 2)
            return v <= 1 && vi >= 1
        case .line, .arrow, .ink:
            let tol = max(tolerance, CGFloat(style.strokeWidth) / 2 + 2)
            guard points.count >= 1 else { return false }
            if points.count == 1 { return hypot(points[0].x - p.x, points[0].y - p.y) <= tol }
            for i in 0..<(points.count - 1) where GeometryMath.distance(from: p, toSegment: points[i], points[i + 1]) <= tol {
                return true
            }
            return false
        }
    }
}

// MARK: - Reading position

struct ReadingPosition: Codable, Equatable {
    var pageIndex: Int = 0
    /// Top-left visible point of the viewport, in PDF page space.
    var pointX: Double = 0
    var pointY: Double = 0
    var scale: Double = 1
    /// "custom", "width" or "page"
    var fitMode: String = "width"
    /// Raw PDFDisplayMode value.
    var displayMode: Int = 1
    var displaysAsBook: Bool = false
    var sidebarVisible: Bool = true
    var sidebarTab: String = "pages"
    var inspectorVisible: Bool = false
    /// "normal", "night", "sepia"
    var readingMode: String = "normal"
    var lastSelectedPage: Int = 0
    var rotations: [Int: Int] = [:]
    var updatedAt: Date = Date()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pageIndex = try c.decodeIfPresent(Int.self, forKey: .pageIndex) ?? 0
        pointX = try c.decodeIfPresent(Double.self, forKey: .pointX) ?? 0
        pointY = try c.decodeIfPresent(Double.self, forKey: .pointY) ?? 0
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        fitMode = try c.decodeIfPresent(String.self, forKey: .fitMode) ?? "width"
        displayMode = try c.decodeIfPresent(Int.self, forKey: .displayMode) ?? 1
        displaysAsBook = try c.decodeIfPresent(Bool.self, forKey: .displaysAsBook) ?? false
        sidebarVisible = try c.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
        sidebarTab = try c.decodeIfPresent(String.self, forKey: .sidebarTab) ?? "pages"
        inspectorVisible = try c.decodeIfPresent(Bool.self, forKey: .inspectorVisible) ?? false
        readingMode = try c.decodeIfPresent(String.self, forKey: .readingMode) ?? "normal"
        lastSelectedPage = try c.decodeIfPresent(Int.self, forKey: .lastSelectedPage) ?? 0
        rotations = try c.decodeIfPresent([Int: Int].self, forKey: .rotations) ?? [:]
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

// MARK: - Library

struct DocumentRecord: Identifiable, Hashable {
    var id: String                    // content fingerprint
    var title: String
    var path: String
    var bookmark: Data?
    var pageCount: Int
    var fileSize: Int64
    var addedAt: Date
    var lastOpenedAt: Date?
    var fileModifiedAt: Date?
    var isFavorite: Bool = false
    var isPinned: Bool = false
    var openCount: Int = 0
    var indexedAt: Date? = nil
    var pagesRead: Int = 0
    var tags: [String] = []

    var progress: Double {
        guard pageCount > 0 else { return 0 }
        return min(1, Double(pagesRead) / Double(pageCount))
    }
    var url: URL { URL(fileURLWithPath: path) }
}

struct CollectionRecord: Identifiable, Hashable {
    var id: String
    var name: String
    var parentID: String?
    var icon: String
    var sort: Int
}

struct CollectionNode: Identifiable, Hashable {
    var id: String
    var name: String
    var icon: String
    var children: [CollectionNode]?
}

// MARK: - Study

struct BookmarkRecord: Identifiable, Hashable {
    var id: String
    var docID: String
    var page: Int
    var name: String
    var createdAt: Date
}

struct PageNote: Hashable {
    var docID: String
    var page: Int
    var text: String
    var updatedAt: Date
}

enum PartOfSpeech: String, Codable, CaseIterable, Identifiable {
    case none, noun, verb, adjective, adverb, preposition, conjunction, pronoun, particle, phrase
    var id: String { rawValue }
    var title: String { self == .none ? "—" : rawValue.capitalized }
}

enum GermanArticle: String, Codable, CaseIterable, Identifiable {
    case none = "", der, die, das
    var id: String { rawValue }
    var title: String { self == .none ? "—" : rawValue }
}

struct VocabularyEntry: Identifiable, Hashable {
    var id: String = UUID().uuidString
    var docID: String?
    var page: Int?
    var word: String = ""
    var translation: String = ""
    var example: String = ""
    var explanation: String = ""
    var partOfSpeech: PartOfSpeech = .none
    var article: GermanArticle = .none
    var plural: String = ""
    var notes: String = ""
    var needsReview: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var displayWord: String { article == .none ? word : "\(article.rawValue) \(word)" }
}

// MARK: - Reusable text styles

enum TextAlignmentOption: String, Codable, CaseIterable, Identifiable {
    case natural, left, center, right, justified
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum BaseDirectionOption: String, Codable, CaseIterable, Identifiable {
    case auto, ltr, rtl
    var id: String { rawValue }
    var title: String {
        switch self { case .auto: return "Automatic"; case .ltr: return "Left to Right"; case .rtl: return "Right to Left" }
    }
}

struct TextStylePreset: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var fontFamily: String
    var fontSize: Double
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var strikethrough: Bool = false
    var color: RGBA = .black
    var alignment: TextAlignmentOption = .natural
    var direction: BaseDirectionOption = .auto
    var lineSpacing: Double = 2
    var paragraphSpacing: Double = 4
    var box: AnnotationStyle = AnnotationStyle()
    var sort: Int = 0

    static func defaults() -> [TextStylePreset] {
        func box(fill: RGBA?, stroke: RGBA = .clear, width: Double = 0, radius: Double = 8) -> AnnotationStyle {
            var s = AnnotationStyle()
            s.fill = fill; s.stroke = stroke; s.strokeWidth = width; s.cornerRadius = radius; s.padding = 8
            return s
        }
        return [
            TextStylePreset(name: "German Vocabulary", fontFamily: "Helvetica Neue", fontSize: 15, bold: true,
                            color: RGBA(0.09, 0.22, 0.52), direction: .ltr,
                            box: box(fill: RGBA(1, 0.96, 0.78, 0.95)), sort: 0),
            TextStylePreset(name: "Persian Translation", fontFamily: "Geeza Pro", fontSize: 15,
                            color: RGBA(0.55, 0.10, 0.18), direction: .rtl,
                            box: box(fill: RGBA(1, 1, 1, 0.9)), sort: 1),
            TextStylePreset(name: "Grammar Explanation", fontFamily: "Helvetica Neue", fontSize: 13,
                            color: RGBA(0.08, 0.17, 0.33), lineSpacing: 3,
                            box: box(fill: RGBA(0.86, 0.93, 1, 0.95), stroke: RGBA(0.36, 0.67, 1), width: 1), sort: 2),
            TextStylePreset(name: "Important Note", fontFamily: "Helvetica Neue", fontSize: 13, bold: true,
                            color: RGBA(0.35, 0.18, 0.02),
                            box: box(fill: RGBA(1, 0.92, 0.80, 0.97), stroke: RGBA(0.95, 0.60, 0.15), width: 1.5), sort: 3),
            TextStylePreset(name: "Exam Tip", fontFamily: "Helvetica Neue", fontSize: 13, bold: true,
                            color: RGBA(0.45, 0.06, 0.06),
                            box: box(fill: RGBA(1, 0.90, 0.90, 0.97), stroke: RGBA(0.90, 0.30, 0.30), width: 1.5), sort: 4),
            TextStylePreset(name: "Example Sentence", fontFamily: "Georgia", fontSize: 13, italic: true,
                            color: RGBA(0.15, 0.15, 0.15), lineSpacing: 2,
                            box: box(fill: nil), sort: 5),
        ]
    }
}

// MARK: - Search

enum SearchScope: String { case pdf, annotation, note, vocab, bookmark, ocr }

struct SearchHit: Identifiable, Hashable {
    var id = UUID()
    var scope: SearchScope
    var docID: String
    var docTitle: String
    var page: Int
    var snippet: String
    var refID: String?
}

struct VersionSnapshot: Identifiable, Hashable {
    var id: Int
    var docID: String
    var createdAt: Date
    var label: String
    var count: Int
}
