import Foundation
import CoreGraphics

enum GeometryMath {
    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func boundingRect(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func union(_ rects: [CGRect]) -> CGRect {
        rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
    }

    /// Ramer–Douglas–Peucker simplification for freehand strokes.
    static func simplify(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var maxD: CGFloat = 0, idx = 0
        for i in 1..<(pts.count - 1) {
            let d = distance(from: pts[i], toSegment: pts[0], pts[pts.count - 1])
            if d > maxD { maxD = d; idx = i }
        }
        if maxD > epsilon {
            let l = simplify(Array(pts[0...idx]), epsilon: epsilon)
            let r = simplify(Array(pts[idx...]), epsilon: epsilon)
            return Array(l.dropLast()) + r
        }
        return [pts[0], pts[pts.count - 1]]
    }
}

/// Helpers for toggling markup (highlight/underline/...) on text that is already marked.
enum MarkupMath {
    /// Fraction (0...1) of `rect`'s area that `other` covers.
    static func overlapFraction(of rect: CGRect, with other: CGRect) -> CGFloat {
        let i = rect.intersection(other)
        guard !i.isNull, rect.width > 0, rect.height > 0 else { return 0 }
        return (i.width * i.height) / (rect.width * rect.height)
    }
    /// True when existing quads together cover at least `threshold` of `quad`.
    static func isCovered(_ quad: CGRect, by existing: [CGRect], threshold: CGFloat = 0.6) -> Bool {
        existing.reduce(CGFloat(0)) { $0 + overlapFraction(of: quad, with: $1) } >= threshold
    }
}

/// Maps between PDF page space (origin bottom-left, unrotated) and the
/// "display" space of an overlay (origin top-left, rotated as the page is shown).
///
/// The renderer draws in *flipped page space* ("P-space": origin top-left of the
/// unrotated crop box). `pToDisplay` is the affine transform from P-space to display space.
struct PageGeometry: Equatable {
    var box: CGRect
    var rotation: Int   // clockwise degrees, normalised to 0/90/180/270

    init(box: CGRect, rotation: Int) {
        self.box = box
        self.rotation = ((rotation % 360) + 360) % 360
    }

    var width: CGFloat { box.width }
    var height: CGFloat { box.height }

    var displaySize: CGSize {
        rotation % 180 == 0 ? CGSize(width: width, height: height) : CGSize(width: height, height: width)
    }

    // page space (y-up) <-> P-space (y-down, origin at box top-left)
    func pageToP(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - box.minX, y: box.maxY - p.y) }
    func pToPage(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + box.minX, y: box.maxY - p.y) }

    func pageToP(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX - box.minX, y: box.maxY - r.maxY, width: r.width, height: r.height)
    }
    func pToPage(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX + box.minX, y: box.maxY - r.maxY, width: r.width, height: r.height)
    }

    var pToDisplay: CGAffineTransform {
        switch rotation {
        case 90: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 270: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        default: return .identity
        }
    }

    func toDisplay(_ p: CGPoint) -> CGPoint { pageToP(p).applying(pToDisplay) }
    func fromDisplay(_ p: CGPoint) -> CGPoint { pToPage(p.applying(pToDisplay.inverted())) }

    func toDisplay(_ r: CGRect) -> CGRect { pageToP(r).applying(pToDisplay) }
    func fromDisplay(_ r: CGRect) -> CGRect { pToPage(r.applying(pToDisplay.inverted())) }
}

/// Parses user page ranges such as "1-5, 8, 10-12" (1-based) into 0-based sorted indices.
enum PageRangeParser {
    static func parse(_ text: String, pageCount: Int) -> [Int]? {
        let cleaned = text.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "،", with: ",")
        var result = Set<Int>()
        for part in cleaned.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let s = part.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            let bounds = s.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if bounds.count == 1, let n = Int(bounds[0]) {
                guard (1...pageCount).contains(n) else { return nil }
                result.insert(n - 1)
            } else if bounds.count == 2, let a = Int(bounds[0]), let b = Int(bounds[1]), a <= b {
                guard a >= 1, b <= pageCount else { return nil }
                for n in a...b { result.insert(n - 1) }
            } else {
                return nil
            }
        }
        return result.isEmpty ? nil : result.sorted()
    }
}
