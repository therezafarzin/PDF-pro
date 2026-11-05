import AppKit
import PDFKit

enum ExportMode: String, CaseIterable, Identifiable {
    /// Annotations are drawn into the page content. Best fidelity for mixed Persian/German text
    /// in any viewer; annotations are no longer editable in other apps.
    case flattened
    /// Annotations are written as standard PDF annotations (editable elsewhere). Rich text is
    /// reduced to plain FreeText, so mixed-direction layout depends on the viewer.
    case standardAnnotations
    /// Pages only, no personal annotations.
    case plain
    var id: String { rawValue }
    var title: String {
        switch self {
        case .flattened: return "Flattened (best bilingual fidelity)"
        case .standardAnnotations: return "Standard PDF annotations (editable in other apps)"
        case .plain: return "Original pages only"
        }
    }
}

struct ExportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum PDFExporter {

    static func export(document: PDFDocument, annotations: [AnnotationModel], pages: [Int]?,
                       mode: ExportMode, to url: URL, progress: ((Double) -> Void)? = nil) async throws {
        let indices = pages ?? Array(0..<document.pageCount)
        guard !indices.isEmpty else { throw ExportError(message: "No pages selected.") }
        switch mode {
        case .flattened: try await exportFlattened(document, annotations, indices, url, progress)
        case .standardAnnotations: try exportStandard(document, annotations, indices, url)
        case .plain: try exportStandard(document, [], indices, url)
        }
        progress?(1)
    }

    // MARK: Flattened

    private static func exportFlattened(_ doc: PDFDocument, _ annotations: [AnnotationModel], _ indices: [Int],
                                        _ url: URL, _ progress: ((Double) -> Void)?) async throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let aux: [CFString: Any] = [kCGPDFContextTitle: doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? url.deletingPathExtension().lastPathComponent,
                                    kCGPDFContextCreator: "PDF Study"]
        guard let ctx = CGContext(tmp as CFURL, mediaBox: &defaultBox, aux as CFDictionary) else {
            throw ExportError(message: "Could not create the output file. Check that the destination is writable.")
        }
        let byPage = Dictionary(grouping: annotations, by: { $0.pageIndex })
        for (n, idx) in indices.enumerated() {
            guard let page = doc.page(at: idx) else { continue }
            let g = PageGeometry(box: page.bounds(for: .cropBox), rotation: page.rotation)
            var box = CGRect(origin: .zero, size: g.displaySize)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)

            // 1. Original page content (vector, fonts preserved) + its existing annotations.
            ctx.saveGState()
            if let ref = page.pageRef {
                ctx.concatenate(ref.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
                ctx.drawPDFPage(ref)
                for a in page.annotations where a.type != "Link" && a.type != "Popup" && a.shouldDisplay {
                    a.draw(with: .cropBox, in: ctx)
                }
            }
            ctx.restoreGState()

            // 2. Personal annotations in P-space.
            if let list = byPage[idx] {
                ctx.saveGState()
                ctx.translateBy(x: 0, y: g.displaySize.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.concatenate(g.pToDisplay)
                for m in list.sorted(by: { $0.zIndex < $1.zIndex }) {
                    AnnotationRenderer.draw(m, geometry: g, in: ctx, multiplyHighlights: true)
                }
                ctx.restoreGState()
            }
            ctx.endPDFPage()
            progress?(Double(n + 1) / Double(indices.count))
            if n % 4 == 3 { await Task.yield() }
        }
        ctx.closePDF()

        // Re-open to restore the table of contents on the exported pages.
        if doc.outlineRoot != nil, let out = PDFDocument(url: tmp) {
            copyOutline(from: doc, to: out, pageMap: Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($1, $0) }))
            let tmp2 = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
            guard out.write(to: tmp2) else { try? FileManager.default.removeItem(at: tmp); throw ExportError(message: "Could not finalize the exported PDF.") }
            try? FileManager.default.removeItem(at: tmp)
            try replace(url, with: tmp2)
        } else {
            try replace(url, with: tmp)
        }
    }

    private static func copyOutline(from src: PDFDocument, to dst: PDFDocument, pageMap: [Int: Int]) {
        guard let root = src.outlineRoot else { return }
        let newRoot = PDFOutline()
        func clone(_ o: PDFOutline, into parent: PDFOutline) {
            for i in 0..<o.numberOfChildren {
                guard let child = o.child(at: i) else { continue }
                let node = PDFOutline()
                node.label = child.label
                if let page = child.destination?.page, let newIdx = pageMap[src.index(for: page)], let newPage = dst.page(at: newIdx) {
                    node.destination = PDFDestination(page: newPage, at: child.destination?.point ?? .zero)
                    parent.insertChild(node, at: parent.numberOfChildren)
                    clone(child, into: node)
                } else if child.numberOfChildren > 0 {
                    // keep structure if descendants survive
                    let before = parent.numberOfChildren
                    parent.insertChild(node, at: before)
                    clone(child, into: node)
                    if node.numberOfChildren == 0 { node.removeFromParent() }
                }
            }
        }
        clone(root, into: newRoot)
        if newRoot.numberOfChildren > 0 { dst.outlineRoot = newRoot }
    }

    // MARK: Standard annotations

    private static func exportStandard(_ doc: PDFDocument, _ annotations: [AnnotationModel], _ indices: [Int], _ url: URL) throws {
        guard let copy = doc.copy() as? PDFDocument else { throw ExportError(message: "Could not copy the document.") }
        for (idx, list) in Dictionary(grouping: annotations, by: { $0.pageIndex }) {
            guard let page = copy.page(at: idx) else { continue }
            for m in list.sorted(by: { $0.zIndex < $1.zIndex }) {
                for a in nativeAnnotations(for: m) { page.addAnnotation(a) }
            }
        }
        let keep = Set(indices)
        for i in stride(from: copy.pageCount - 1, through: 0, by: -1) where !keep.contains(i) { copy.removePage(at: i) }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
        guard copy.write(to: tmp) else { throw ExportError(message: "Could not write the PDF.") }
        try replace(url, with: tmp)
    }

    static func nativeAnnotations(for m: AnnotationModel) -> [PDFAnnotation] {
        let s = m.style
        func border(_ w: Double) -> PDFBorder { let b = PDFBorder(); b.lineWidth = CGFloat(w); return b }
        func rel(_ p: CGPoint, _ b: CGRect) -> CGPoint { CGPoint(x: p.x - b.minX, y: p.y - b.minY) }
        switch m.kind {
        case .highlight, .underline, .strikeThrough, .squiggly:
            guard !m.quads.isEmpty else { return [] }
            let b = GeometryMath.union(m.quads)
            let subtype: PDFAnnotationSubtype = m.kind == .highlight ? .highlight : (m.kind == .strikeThrough ? .strikeOut : .underline)
            let a = PDFAnnotation(bounds: b, forType: subtype, withProperties: nil)
            a.color = s.stroke.with(alpha: m.kind == .highlight ? s.opacity : 1).nsColor
            a.quadrilateralPoints = m.quads.flatMap { q in
                [CGPoint(x: q.minX, y: q.maxY), CGPoint(x: q.maxX, y: q.maxY), CGPoint(x: q.minX, y: q.minY), CGPoint(x: q.maxX, y: q.minY)]
                    .map { NSValue(point: rel($0, b)) }
            }
            if let t = m.text?.plain, !t.isEmpty { a.contents = t }
            return [a]
        case .rectangle, .ellipse:
            let a = PDFAnnotation(bounds: m.rect, forType: m.kind == .ellipse ? .circle : .square, withProperties: nil)
            a.color = s.stroke.nsColor
            if let f = s.fill { a.interiorColor = f.nsColor }
            a.border = border(s.strokeWidth)
            return [a]
        case .line, .arrow:
            guard m.points.count >= 2 else { return [] }
            let b = m.rect
            let a = PDFAnnotation(bounds: b, forType: .line, withProperties: nil)
            a.startPoint = rel(m.points[0], b); a.endPoint = rel(m.points[m.points.count - 1], b)
            if m.kind == .arrow { a.endLineStyle = .closedArrow }
            a.color = s.stroke.nsColor; a.border = border(s.strokeWidth)
            return [a]
        case .ink:
            guard m.points.count >= 2 else { return [] }
            let b = m.rect
            let a = PDFAnnotation(bounds: b, forType: .ink, withProperties: nil)
            let path = NSBezierPath()
            path.move(to: rel(m.points[0], b))
            for p in m.points.dropFirst() { path.line(to: rel(p, b)) }
            a.add(path)
            a.color = s.stroke.nsColor; a.border = border(s.strokeWidth)
            return [a]
        case .textBox:
            let a = PDFAnnotation(bounds: m.rect, forType: .freeText, withProperties: nil)
            let attr = RichText.decode(m.text)
            a.contents = m.plainText
            if attr.length > 0 {
                a.font = attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? NSFont.systemFont(ofSize: 14)
                a.fontColor = attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor ?? .black
                if let p = attr.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
                    a.alignment = p.alignment == .center ? .center : (p.alignment == .right || p.baseWritingDirection == .rightToLeft ? .right : .left)
                }
            }
            a.color = (s.fill ?? .clear).nsColor
            a.border = border(s.strokeWidth)
            return [a]
        case .stickyNote:
            let a = PDFAnnotation(bounds: m.occupiedRect, forType: .text, withProperties: nil)
            a.contents = m.plainText
            a.iconType = .note
            a.color = (s.fill ?? RGBA(1, 0.9, 0.3)).nsColor
            return [a]
        }
    }

    // MARK: In-place embedding

    /// Writes annotations into the original file. A backup of the original bytes is made first and
    /// the file is replaced atomically. The caller must re-key the document (its bytes changed).
    static func embedInOriginal(document: PDFDocument, annotations: [AnnotationModel], originalURL: URL) throws -> URL {
        let backupURL = BackupManager.originalsDirectory()
            .appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(originalURL.lastPathComponent)")
        try FileManager.default.copyItem(at: originalURL, to: backupURL)
        guard let copy = document.copy() as? PDFDocument else { throw ExportError(message: "Could not copy the document.") }
        for (idx, list) in Dictionary(grouping: annotations, by: { $0.pageIndex }) {
            guard let page = copy.page(at: idx) else { continue }
            for m in list { for a in nativeAnnotations(for: m) { page.addAnnotation(a) } }
        }
        let tmp = originalURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
        guard copy.write(to: tmp) else { throw ExportError(message: "Could not write the PDF next to the original. If the folder is read-only, use Export instead.") }
        try replace(originalURL, with: tmp)
        return backupURL
    }

    private static func replace(_ dest: URL, with tmp: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dest)
        }
    }
}
