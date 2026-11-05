import AppKit

/// Draws annotations in "P-space" (origin top-left of the unrotated page box, y down).
/// The same code is used for the on-screen overlay and for PDF export, so output is identical.
enum AnnotationRenderer {
    private static let textCache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>(); c.countLimit = 400; return c
    }()

    static func attributedText(for m: AnnotationModel) -> NSAttributedString {
        let key = "\(m.id.uuidString)-\(m.modifiedAt.timeIntervalSince1970)" as NSString
        if let hit = textCache.object(forKey: key) { return hit }
        let a = RichText.decode(m.text)
        textCache.setObject(a, forKey: key)
        return a
    }

    static func draw(_ m: AnnotationModel, geometry g: PageGeometry, in ctx: CGContext,
                     drawText: Bool = true, multiplyHighlights: Bool = false) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let s = m.style
        let stroke = s.stroke.nsColor.cgColor
        switch m.kind {
        case .highlight:
            if multiplyHighlights { ctx.setBlendMode(.multiply) }
            ctx.setFillColor(s.stroke.with(alpha: s.opacity).cgColor)
            for q in m.quads {
                let r = g.pageToP(q)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil))
                ctx.fillPath()
            }
        case .underline, .strikeThrough, .squiggly:
            ctx.setStrokeColor(s.stroke.with(alpha: max(s.opacity, 0.9)).cgColor)
            ctx.setLineWidth(max(1, CGFloat(s.strokeWidth)))
            ctx.setLineCap(.round)
            for q in m.quads {
                let r = g.pageToP(q)
                if m.kind == .underline {
                    ctx.move(to: CGPoint(x: r.minX, y: r.maxY - 1)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 1))
                } else if m.kind == .strikeThrough {
                    ctx.move(to: CGPoint(x: r.minX, y: r.midY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.midY))
                } else {
                    var x = r.minX
                    let base = r.maxY - 1.5
                    ctx.move(to: CGPoint(x: x, y: base))
                    var up = true
                    while x < r.maxX {
                        x = min(x + 2.5, r.maxX)
                        ctx.addLine(to: CGPoint(x: x, y: base + (up ? -1.6 : 1.6)))
                        up.toggle()
                    }
                }
                ctx.strokePath()
            }
        case .rectangle, .ellipse:
            let r = g.pageToP(m.rect)
            ctx.setAlpha(CGFloat(s.opacity))
            let path: CGPath = m.kind == .ellipse ? CGPath(ellipseIn: r, transform: nil)
                : CGPath(roundedRect: r, cornerWidth: min(CGFloat(s.cornerRadius), r.width / 2), cornerHeight: min(CGFloat(s.cornerRadius), r.height / 2), transform: nil)
            if let f = s.fill { ctx.setFillColor(f.cgColor); ctx.addPath(path); ctx.fillPath() }
            if s.strokeWidth > 0 {
                setStroke(ctx, s, stroke); ctx.addPath(path); ctx.strokePath()
            }
        case .line, .arrow:
            guard m.points.count >= 2 else { return }
            let a = g.pageToP(m.points[0]), b = g.pageToP(m.points[m.points.count - 1])
            ctx.setAlpha(CGFloat(s.opacity))
            setStroke(ctx, s, stroke)
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            if m.kind == .arrow {
                let angle = atan2(b.y - a.y, b.x - a.x)
                let len = max(9, CGFloat(s.strokeWidth) * 4.5)
                let spread = CGFloat.pi / 7
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.setFillColor(stroke)
                ctx.move(to: b)
                ctx.addLine(to: CGPoint(x: b.x - len * cos(angle - spread), y: b.y - len * sin(angle - spread)))
                ctx.addLine(to: CGPoint(x: b.x - len * cos(angle + spread), y: b.y - len * sin(angle + spread)))
                ctx.closePath(); ctx.fillPath()
            }
        case .ink:
            let pts = m.points.map { g.pageToP($0) }
            guard let first = pts.first else { return }
            ctx.setAlpha(CGFloat(s.opacity))
            setStroke(ctx, s, stroke)
            ctx.move(to: first)
            if pts.count == 1 { ctx.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
            else if pts.count == 2 { ctx.addLine(to: pts[1]) }
            else {
                for i in 1..<(pts.count - 1) {
                    let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
                    ctx.addQuadCurve(to: mid, control: pts[i])
                }
                ctx.addLine(to: pts[pts.count - 1])
            }
            ctx.strokePath()
        case .textBox:
            drawBox(m, rect: g.pageToP(m.rect), ctx: ctx, drawText: drawText)
        case .stickyNote:
            if m.collapsed {
                drawStickyIcon(m, g: g, ctx: ctx)
            } else {
                drawBox(m, rect: g.pageToP(m.rect), ctx: ctx, drawText: drawText)
            }
        }
    }

    private static func setStroke(_ ctx: CGContext, _ s: AnnotationStyle, _ color: CGColor) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(max(0.25, CGFloat(s.strokeWidth)))
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setLineDash(phase: 0, lengths: s.dashed ? [CGFloat(s.strokeWidth) * 3, CGFloat(s.strokeWidth) * 2] : [])
    }

    private static func drawBox(_ m: AnnotationModel, rect r: CGRect, ctx: CGContext, drawText: Bool) {
        let s = m.style
        ctx.setAlpha(CGFloat(s.opacity))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let radius = min(CGFloat(s.cornerRadius), min(r.width, r.height) / 2)
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if let f = s.fill { ctx.setFillColor(f.cgColor); ctx.addPath(path); ctx.fillPath() }
        if m.kind == .stickyNote, s.fill == nil {
            ctx.setFillColor(RGBA(1, 0.93, 0.55).cgColor); ctx.addPath(path); ctx.fillPath()
        }
        if drawText {
            let inner = r.insetBy(dx: CGFloat(s.padding), dy: CGFloat(s.padding))
            if inner.width > 1, inner.height > 1, !m.plainText.isEmpty {
                ctx.saveGState()
                ctx.addPath(path); ctx.clip()
                let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = gc
                attributedText(for: m).draw(with: inner, options: [.usesLineFragmentOrigin, .usesFontLeading])
                NSGraphicsContext.restoreGraphicsState()
                ctx.restoreGState()
            }
        }
        if s.strokeWidth > 0, s.stroke.a > 0 {
            setStroke(ctx, s, s.stroke.cgColor)
            ctx.addPath(path); ctx.strokePath()
        }
        ctx.endTransparencyLayer()
    }

    private static func drawStickyIcon(_ m: AnnotationModel, g: PageGeometry, ctx: CGContext) {
        let r = g.pageToP(m.occupiedRect)
        let path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.setFillColor((m.style.fill ?? RGBA(1, 0.85, 0.25)).cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor(RGBA(0.55, 0.40, 0.05, 0.9).cgColor); ctx.setLineWidth(1)
        ctx.addPath(path); ctx.strokePath()
        ctx.setStrokeColor(RGBA(0.45, 0.32, 0.02, 0.9).cgColor)
        for i in 0..<3 {
            let y = r.minY + 7 + CGFloat(i) * 4.5
            ctx.move(to: CGPoint(x: r.minX + 5, y: y)); ctx.addLine(to: CGPoint(x: r.maxX - 5, y: y)); ctx.strokePath()
        }
    }
}
