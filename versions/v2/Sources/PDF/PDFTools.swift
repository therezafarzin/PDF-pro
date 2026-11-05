import AppKit
import PDFKit
import Vision

// MARK: - Runner (progress, cancellation, results)

@MainActor
final class ToolRunner: ObservableObject {
    @Published var progress = 0.0
    @Published var status = ""
    @Published var running = false
    @Published var finished = false
    @Published var outputs: [URL] = []
    @Published var notes: [String] = []
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?

    func run(_ work: @escaping @MainActor (ToolRunner) async throws -> Void) {
        guard !running else { return }
        running = true; finished = false; outputs = []; notes = []; errorMessage = nil; progress = 0; status = "Starting…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await work(self)
                if Task.isCancelled { self.errorMessage = "Cancelled." }
            } catch is CancellationError {
                self.errorMessage = "Cancelled."
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.running = false
            self.finished = true
            if self.errorMessage == nil { self.progress = 1 }
            self.status = ""
        }
    }

    func cancel() { task?.cancel() }
    func report(_ p: Double, _ s: String? = nil) { progress = min(max(p, 0), 1); if let s { status = s } }
    func checkCancelled() throws { try Task.checkCancellation() }
    func reset() { running = false; finished = false; outputs = []; notes = []; errorMessage = nil; progress = 0 }
}

enum ToolError: LocalizedError {
    case locked(String), unreadable(String), noPages(String), writeFailed(String), invalid(String)
    var errorDescription: String? {
        switch self {
        case .locked(let n): return "“\(n)” is password protected. Enter its password in the file list."
        case .unreadable(let n): return "“\(n)” could not be read. It may be damaged."
        case .noPages(let n): return "“\(n)” has no pages."
        case .writeFailed(let n): return "Could not write “\(n)”. Check that the folder is writable."
        case .invalid(let m): return m
        }
    }
}

// MARK: - Shared page drawing / rasterizing

enum PageDrawing {
    /// Draws a page (vector content + its existing annotations + optional app annotations) into a y-up
    /// context whose size equals `geometry.displaySize` (the page as displayed, rotation applied).
    static func draw(page: PDFPage, geometry g: PageGeometry, annotations: [AnnotationModel], in ctx: CGContext) {
        let box = CGRect(origin: .zero, size: g.displaySize)
        ctx.saveGState()
        if let ref = page.pageRef {
            ctx.concatenate(ref.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(ref)
            for a in page.annotations where a.type != "Link" && a.type != "Popup" && a.shouldDisplay {
                a.draw(with: .cropBox, in: ctx)
            }
        }
        ctx.restoreGState()
        guard !annotations.isEmpty else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: g.displaySize.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.concatenate(g.pToDisplay)
        for m in annotations.sorted(by: { $0.zIndex < $1.zIndex }) {
            AnnotationRenderer.draw(m, geometry: g, in: ctx, multiplyHighlights: true)
        }
        ctx.restoreGState()
    }
}

enum PageRasterizer {
    static func render(page: PDFPage, dpi: Int, annotations: [AnnotationModel] = [], maxPixels: Double = 40_000_000) -> CGImage? {
        let g = PageGeometry(box: page.bounds(for: .cropBox), rotation: page.rotation)
        let size = g.displaySize
        guard size.width > 0, size.height > 0 else { return nil }
        var scale = Double(dpi) / 72.0
        var w = (Double(size.width) * scale).rounded(.up)
        var h = (Double(size.height) * scale).rounded(.up)
        if w * h > maxPixels {
            let f = (maxPixels / (w * h)).squareRoot()
            scale *= f; w = (Double(size.width) * scale).rounded(.up); h = (Double(size.height) * scale).rounded(.up)
        }
        guard w >= 1, h >= 1, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        PageDrawing.draw(page: page, geometry: g, annotations: annotations, in: ctx)
        return ctx.makeImage()
    }

    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}

// MARK: - OCR text layer

enum OCRLayer {
    struct Line { var text: String; var box: CGRect }   // box normalised, origin bottom-left (Vision)

    static func supportedLanguages() -> [String] {
        (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
    }

    static func recognize(_ image: CGImage, languages: [String]) async -> [Line] {
        await Task.detached(priority: .userInitiated) { () -> [Line] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let supported = (try? request.supportedRecognitionLanguages()) ?? []
            let wanted = languages.filter { supported.contains($0) }
            if wanted.isEmpty { request.automaticallyDetectsLanguage = true } else { request.recognitionLanguages = wanted }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do { try handler.perform([request]) } catch { return [] }
            var out: [Line] = []
            for obs in request.results ?? [] {
                if let c = obs.topCandidates(1).first, !c.string.isEmpty { out.append(Line(text: c.string, box: obs.boundingBox)) }
            }
            return out
        }.value
    }

    /// Writes recognised text as *invisible* text (PDF text render mode 3) so the page stays visually
    /// identical but becomes searchable/selectable. `ctx` is y-up with size `pageSize`.
    static func drawInvisible(_ lines: [Line], in ctx: CGContext, pageSize: CGSize) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in lines {
            let r = CGRect(x: line.box.minX * pageSize.width, y: line.box.minY * pageSize.height,
                           width: line.box.width * pageSize.width, height: line.box.height * pageSize.height)
            guard r.width > 1, r.height > 1 else { continue }
            let attr = NSAttributedString(string: line.text, attributes: [.font: NSFont.systemFont(ofSize: max(r.height * 0.8, 2))])
            let ct = CTLineCreateWithAttributedString(attr)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ct, &ascent, &descent, &leading))
            guard width > 0 else { continue }
            ctx.textMatrix = CGAffineTransform(scaleX: min(max(r.width / width, 0.1), 10), y: 1)
            ctx.textPosition = CGPoint(x: r.minX, y: r.minY + descent)
            CTLineDraw(ct, ctx)
        }
        ctx.restoreGState()
    }

    static func plainText(_ lines: [Line]) -> String {
        lines.sorted { $0.box.maxY > $1.box.maxY }.map { $0.text }.joined(separator: "\n")
    }
}

enum BlankPage {
    static func make(size: CGSize) -> PDFPage? {
        var box = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)?.copy() as? PDFPage
    }
}

// MARK: - Options

enum SplitStrategy: Equatable {
    case everyN(Int), singlePages, startingAt(String), ranges(String), topLevelBookmarks
}

struct ConvertOptions {
    var format: ConvertFormat = .png
    var dpi = 150
    var jpegQuality = 0.85
    var includeAnnotations = true
    var pageMarkers = true
    var ocrWhenNoText = false
    var languages: [String] = ["de-DE", "en-US"]
    var subfolder = true
}

// MARK: - Engine

@MainActor
enum PDFTools {

    // MARK: Helpers

    static func open(_ input: ToolInput) throws -> PDFDocument {
        FileAccess.begin(input.url)
        guard let doc = PDFDocument(url: input.url) else { throw ToolError.unreadable(input.url.lastPathComponent) }
        if doc.isLocked, !doc.unlock(withPassword: input.password) { throw ToolError.locked(input.url.lastPathComponent) }
        guard doc.pageCount > 0 else { throw ToolError.noPages(input.url.lastPathComponent) }
        return doc
    }

    static func pageIndices(_ input: ToolInput, _ doc: PDFDocument) throws -> [Int] {
        let t = input.pages.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return Array(0..<doc.pageCount) }
        guard let p = PageRangeParser.parse(t, pageCount: doc.pageCount) else {
            throw ToolError.invalid("“\(input.url.lastPathComponent)”: pages “\(t)” are not valid. Use numbers between 1 and \(doc.pageCount), like 1-5, 8.")
        }
        return p
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private static func hiddenTemp(near url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
    }

    private static func title(of doc: PDFDocument, fallback: String) -> String {
        let t = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return t.isEmpty ? fallback : t
    }

    /// Clones outline entries whose destination survives in `pageMap` (source page index -> destination page index).
    static func cloneOutline(_ src: PDFOutline, into parent: PDFOutline, srcDoc: PDFDocument, dst: PDFDocument, pageMap: [Int: Int]) {
        for i in 0..<src.numberOfChildren {
            guard let child = src.child(at: i) else { continue }
            let node = PDFOutline()
            node.label = child.label
            var hasDestination = false
            if let page = child.destination?.page, let newIndex = pageMap[srcDoc.index(for: page)], let newPage = dst.page(at: newIndex) {
                node.destination = PDFDestination(page: newPage, at: child.destination?.point ?? .zero)
                hasDestination = true
            }
            cloneOutline(child, into: node, srcDoc: srcDoc, dst: dst, pageMap: pageMap)
            if hasDestination || node.numberOfChildren > 0 { parent.insertChild(node, at: parent.numberOfChildren) }
        }
    }

    private static func writeDocument(_ doc: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any]? = nil) throws {
        let tmp = hiddenTemp(near: url)
        let ok = options == nil ? doc.write(to: tmp) : doc.write(to: tmp, withOptions: options)
        guard ok else { throw ToolError.writeFailed(url.lastPathComponent) }
        try PDFExporter.replace(url, with: tmp)
    }

    /// Moves a freshly drawn PDF to its destination, restoring the outline from `source` when it has one.
    private static func finalize(tmp: URL, to out: URL, source: PDFDocument, pageMap: [Int: Int]) throws {
        if source.outlineRoot != nil, let doc = PDFDocument(url: tmp) {
            let root = PDFOutline()
            if let srcRoot = source.outlineRoot { cloneOutline(srcRoot, into: root, srcDoc: source, dst: doc, pageMap: pageMap) }
            if root.numberOfChildren > 0 { doc.outlineRoot = root }
            let tmp2 = hiddenTemp(near: out)
            guard doc.write(to: tmp2) else { try? FileManager.default.removeItem(at: tmp); throw ToolError.writeFailed(out.lastPathComponent) }
            try? FileManager.default.removeItem(at: tmp)
            try PDFExporter.replace(out, with: tmp2)
        } else {
            try PDFExporter.replace(out, with: tmp)
        }
    }

    static func imagePage(_ url: URL, fitA4: Bool) throws -> PDFPage {
        guard let img = NSImage(contentsOf: url), img.size.width > 0, img.size.height > 0 else { throw ToolError.unreadable(url.lastPathComponent) }
        if fitA4 {
            let landscape = img.size.width > img.size.height
            let a4 = landscape ? CGSize(width: 842, height: 595) : CGSize(width: 595, height: 842)
            let options: [PDFPage.ImageInitializationOption: Any] = [
                .mediaBox: NSValue(rect: NSRect(origin: .zero, size: a4)),
                .upscaleIfSmaller: true,
            ]
            if let p = PDFPage(image: img, options: options) { return p }
        }
        guard let p = PDFPage(image: img) else { throw ToolError.unreadable(url.lastPathComponent) }
        return p
    }

    // MARK: Combine

    static func combine(inputs: [ToolInput], fitImagesToA4: Bool, bookmarks: Bool, output: URL, runner r: ToolRunner) async throws {
        guard !inputs.isEmpty else { throw ToolError.invalid("Add at least one file.") }
        let merged = PDFDocument()
        let root = PDFOutline()
        for (n, input) in inputs.enumerated() {
            try r.checkCancelled()
            r.report(Double(n) / Double(inputs.count), "Adding “\(input.url.lastPathComponent)”")
            let startIndex = merged.pageCount
            if input.isImage {
                merged.insert(try imagePage(input.url, fitA4: fitImagesToA4), at: merged.pageCount)
                if bookmarks, let page = merged.page(at: startIndex) {
                    let node = PDFOutline(); node.label = input.displayName
                    node.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .cropBox).maxY))
                    root.insertChild(node, at: root.numberOfChildren)
                }
            } else {
                let doc = try open(input)
                var map: [Int: Int] = [:]
                for i in try pageIndices(input, doc) {
                    guard let copy = doc.page(at: i)?.copy() as? PDFPage else { continue }
                    merged.insert(copy, at: merged.pageCount)
                    map[i] = merged.pageCount - 1
                }
                if bookmarks, merged.pageCount > startIndex, let first = merged.page(at: startIndex) {
                    let node = PDFOutline()
                    node.label = title(of: doc, fallback: input.displayName)
                    node.destination = PDFDestination(page: first, at: CGPoint(x: 0, y: first.bounds(for: .cropBox).maxY))
                    if let srcRoot = doc.outlineRoot { cloneOutline(srcRoot, into: node, srcDoc: doc, dst: merged, pageMap: map) }
                    root.insertChild(node, at: root.numberOfChildren)
                }
            }
            await Task.yield()
        }
        guard merged.pageCount > 0 else { throw ToolError.invalid("No pages to combine.") }
        if root.numberOfChildren > 0 { merged.outlineRoot = root }
        r.report(0.95, "Saving…")
        try writeDocument(merged, to: output)
        r.outputs.append(output)
        r.notes.append("\(merged.pageCount) pages from \(inputs.count) file\(inputs.count == 1 ? "" : "s").")
    }

    // MARK: Split

    private static func topLevelStarts(_ doc: PDFDocument) -> [(start: Int, label: String)] {
        guard let root = doc.outlineRoot else { return [] }
        var out: [(start: Int, label: String)] = []
        for i in 0..<root.numberOfChildren {
            if let c = root.child(at: i), let page = c.destination?.page { out.append((start: doc.index(for: page), label: c.label ?? "")) }
        }
        return out.sorted { $0.start < $1.start }
    }

    static func split(inputs: [ToolInput], strategy: SplitStrategy, outputDir: URL?, runner r: ToolRunner) async throws {
        let docs = inputs.filter { !$0.isImage }
        guard !docs.isEmpty else { throw ToolError.invalid("Add at least one PDF.") }
        for (n, input) in docs.enumerated() {
            try r.checkCancelled()
            let doc: PDFDocument
            do { doc = try open(input) } catch { r.notes.append("Skipped: \(error.localizedDescription)"); continue }
            let count = doc.pageCount
            var labels: [Int: String] = [:]
            let ranges: [ClosedRange<Int>]
            switch strategy {
            case .everyN(let k): ranges = SplitPlanner.plan(pageCount: count, mode: .everyN(k))
            case .singlePages: ranges = SplitPlanner.plan(pageCount: count, mode: .singlePages)
            case .startingAt(let t):
                guard let pts = SplitPlanner.parseStartPages(t, pageCount: count) else { throw ToolError.invalid("Enter page numbers between 1 and \(count), like 10, 25, 40.") }
                ranges = SplitPlanner.plan(pageCount: count, mode: .startingAt(pts))
            case .ranges(let t):
                guard let groups = SplitPlanner.parseRangeGroups(t, pageCount: count) else { throw ToolError.invalid("Enter ranges between 1 and \(count), like 1-5, 8, 10-12. Each item becomes its own file.") }
                ranges = SplitPlanner.plan(pageCount: count, mode: .ranges(groups))
            case .topLevelBookmarks:
                let starts = topLevelStarts(doc)
                guard !starts.isEmpty else { r.notes.append("“\(input.url.lastPathComponent)” has no bookmarks; skipped."); continue }
                for s in starts where labels[s.start] == nil { labels[s.start] = s.label }
                ranges = SplitPlanner.plan(pageCount: count, mode: .outline(starts.map { $0.start }))
            }
            let baseDir = outputDir ?? input.url.deletingLastPathComponent()
            let base = FileNaming.sanitize(input.displayName)
            var folder = baseDir.appendingPathComponent("\(base) – split")
            var k = 2
            while FileManager.default.fileExists(atPath: folder.path) { folder = baseDir.appendingPathComponent("\(base) – split \(k)"); k += 1 }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            for (i, range) in ranges.enumerated() {
                try r.checkCancelled()
                r.report((Double(n) + Double(i) / Double(max(ranges.count, 1))) / Double(docs.count), "“\(input.url.lastPathComponent)”: part \(i + 1) of \(ranges.count)")
                let part = PDFDocument()
                var map: [Int: Int] = [:]
                for p in range {
                    guard let copy = doc.page(at: p)?.copy() as? PDFPage else { continue }
                    part.insert(copy, at: part.pageCount); map[p] = part.pageCount - 1
                }
                guard part.pageCount > 0 else { continue }
                if let srcRoot = doc.outlineRoot {
                    let root = PDFOutline(); cloneOutline(srcRoot, into: root, srcDoc: doc, dst: part, pageMap: map)
                    if root.numberOfChildren > 0 { part.outlineRoot = root }
                }
                var name = "\(base) – \(FileNaming.rangeLabel(range, pageCount: count))"
                if let label = labels[range.lowerBound], !label.isEmpty { name = "\(base) – \(FileNaming.sanitize(label)) (\(FileNaming.rangeLabel(range, pageCount: count)))" }
                let url = FileNaming.uniqueURL(directory: folder, baseName: name, ext: "pdf")
                guard part.write(to: url) else { throw ToolError.writeFailed(url.lastPathComponent) }
                r.outputs.append(url)
                await Task.yield()
            }
            r.notes.append("“\(input.url.lastPathComponent)” → \(ranges.count) file\(ranges.count == 1 ? "" : "s") in “\(folder.lastPathComponent)”.")
        }
    }

    // MARK: Optimize

    static func optimize(inputs: [ToolInput], preset: OptimizePreset, dpi: Int, quality: Double, keepSearchable: Bool,
                         languages: [String], outputDir: URL?, runner r: ToolRunner) async throws {
        let docs = inputs.filter { !$0.isImage }
        guard !docs.isEmpty else { throw ToolError.invalid("Add at least one PDF.") }
        for (n, input) in docs.enumerated() {
            try r.checkCancelled()
            r.report(Double(n) / Double(docs.count), "Optimizing “\(input.url.lastPathComponent)”")
            let doc: PDFDocument
            do { doc = try open(input) } catch { r.notes.append("Skipped: \(error.localizedDescription)"); continue }
            let dir = outputDir ?? input.url.deletingLastPathComponent()
            let out = FileNaming.uniqueURL(directory: dir, baseName: "\(input.displayName) – optimized", ext: "pdf")
            switch preset {
            case .lossless:
                try writeDocument(doc, to: out)
            case .balanced:
                try writeDocument(doc, to: out, options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
            case .strong:
                try await rasterizedCopy(doc, dpi: dpi, quality: quality, keepSearchable: keepSearchable, languages: languages, out: out,
                                         runner: r, base: Double(n) / Double(docs.count), span: 1 / Double(docs.count))
            }
            let before = fileSize(input.url), after = fileSize(out)
            if after >= before {
                try? FileManager.default.removeItem(at: out)
                r.notes.append("“\(input.url.lastPathComponent)” is already compact (\(size(before))); no smaller file could be made.")
            } else {
                r.outputs.append(out)
                let pct = Int((Double(before - after) / Double(max(before, 1)) * 100).rounded())
                r.notes.append("“\(input.url.lastPathComponent)”: \(size(before)) → \(size(after)) (−\(pct) %)")
            }
        }
    }

    private static func rasterizedCopy(_ doc: PDFDocument, dpi: Int, quality: Double, keepSearchable: Bool, languages: [String],
                                       out: URL, runner r: ToolRunner, base: Double, span: Double) async throws {
        let tmp = hiddenTemp(near: out)
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(tmp as CFURL, mediaBox: &defaultBox, nil) else { throw ToolError.writeFailed(out.lastPathComponent) }
        let total = doc.pageCount
        for i in 0..<total {
            if Task.isCancelled { ctx.closePDF(); try? FileManager.default.removeItem(at: tmp); throw CancellationError() }
            r.report(base + span * Double(i) / Double(total), "Compressing page \(i + 1) of \(total)")
            guard let page = doc.page(at: i), let raster = PageRasterizer.render(page: page, dpi: dpi) else { continue }
            let g = PageGeometry(box: page.bounds(for: .cropBox), rotation: page.rotation)
            var box = CGRect(origin: .zero, size: g.displaySize)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            if let jpeg = PageRasterizer.jpegData(raster, quality: quality), let provider = CGDataProvider(data: jpeg as CFData),
               let jpegImage = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                ctx.draw(jpegImage, in: box)
            } else {
                ctx.draw(raster, in: box)
            }
            if keepSearchable {
                let lines = await OCRLayer.recognize(raster, languages: languages)
                OCRLayer.drawInvisible(lines, in: ctx, pageSize: g.displaySize)
            }
            ctx.endPDFPage()
            await Task.yield()
        }
        ctx.closePDF()
        try finalize(tmp: tmp, to: out, source: doc, pageMap: Dictionary(uniqueKeysWithValues: (0..<total).map { ($0, $0) }))
    }

    // MARK: OCR

    static func ocr(inputs: [ToolInput], languages: [String], skipPagesWithText: Bool, dpi: Int, outputDir: URL?, runner r: ToolRunner) async throws {
        let docs = inputs.filter { !$0.isImage }
        guard !docs.isEmpty else { throw ToolError.invalid("Add at least one PDF.") }
        for (n, input) in docs.enumerated() {
            try r.checkCancelled()
            let doc: PDFDocument
            do { doc = try open(input) } catch { r.notes.append("Skipped: \(error.localizedDescription)"); continue }
            let dir = outputDir ?? input.url.deletingLastPathComponent()
            let out = FileNaming.uniqueURL(directory: dir, baseName: "\(input.displayName) – OCR", ext: "pdf")
            let tmp = hiddenTemp(near: out)
            var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let ctx = CGContext(tmp as CFURL, mediaBox: &defaultBox, nil) else { throw ToolError.writeFailed(out.lastPathComponent) }
            let total = doc.pageCount
            var recognized = 0
            for i in 0..<total {
                if Task.isCancelled { ctx.closePDF(); try? FileManager.default.removeItem(at: tmp); throw CancellationError() }
                r.report((Double(n) + Double(i) / Double(total)) / Double(docs.count), "“\(input.url.lastPathComponent)”: page \(i + 1) of \(total)")
                guard let page = doc.page(at: i) else { continue }
                let g = PageGeometry(box: page.bounds(for: .cropBox), rotation: page.rotation)
                var box = CGRect(origin: .zero, size: g.displaySize)
                ctx.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
                PageDrawing.draw(page: page, geometry: g, annotations: [], in: ctx)
                let existing = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !(skipPagesWithText && existing.count >= 15), let raster = PageRasterizer.render(page: page, dpi: dpi) {
                    let lines = await OCRLayer.recognize(raster, languages: languages)
                    OCRLayer.drawInvisible(lines, in: ctx, pageSize: g.displaySize)
                    if !lines.isEmpty { recognized += 1 }
                }
                ctx.endPDFPage()
                await Task.yield()
            }
            ctx.closePDF()
            try finalize(tmp: tmp, to: out, source: doc, pageMap: Dictionary(uniqueKeysWithValues: (0..<total).map { ($0, $0) }))
            r.outputs.append(out)
            r.notes.append("“\(input.url.lastPathComponent)”: text recognized on \(recognized) of \(total) pages.")
        }
    }

    // MARK: Convert

    static func convert(inputs: [ToolInput], options o: ConvertOptions, outputDir: URL?, store: Store?, runner r: ToolRunner) async throws {
        let docs = inputs.filter { !$0.isImage }
        guard !docs.isEmpty else { throw ToolError.invalid("Add at least one PDF.") }
        for (n, input) in docs.enumerated() {
            try r.checkCancelled()
            let doc: PDFDocument
            do { doc = try open(input) } catch { r.notes.append("Skipped: \(error.localizedDescription)"); continue }
            let indices = try pageIndices(input, doc)
            let baseDir = outputDir ?? input.url.deletingLastPathComponent()
            let base = FileNaming.sanitize(input.displayName)
            var byPage: [Int: [AnnotationModel]] = [:]
            if o.includeAnnotations, o.format.isImage, let store, let id = try? DocumentFingerprint.compute(url: input.url) {
                byPage = Dictionary(grouping: store.annotations(docID: id), by: { $0.pageIndex })
            }
            func progress(_ i: Int) -> Double { (Double(n) + Double(i) / Double(max(indices.count, 1))) / Double(docs.count) }

            if o.format.isImage {
                var folder = baseDir
                if o.subfolder {
                    folder = baseDir.appendingPathComponent("\(base) – \(o.format.fileExtension)")
                    var k = 2
                    while FileManager.default.fileExists(atPath: folder.path) { folder = baseDir.appendingPathComponent("\(base) – \(o.format.fileExtension) \(k)"); k += 1 }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                }
                var written = 0
                for (i, p) in indices.enumerated() {
                    try r.checkCancelled()
                    r.report(progress(i), "“\(input.url.lastPathComponent)”: page \(p + 1)")
                    guard let page = doc.page(at: p), let img = PageRasterizer.render(page: page, dpi: o.dpi, annotations: byPage[p] ?? []) else { continue }
                    let rep = NSBitmapImageRep(cgImage: img)
                    let data: Data?
                    switch o.format {
                    case .png: data = rep.representation(using: .png, properties: [:])
                    case .jpeg: data = rep.representation(using: .jpeg, properties: [.compressionFactor: o.jpegQuality])
                    default: data = rep.representation(using: .tiff, properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue])
                    }
                    guard let data else { continue }
                    let url = FileNaming.uniqueURL(directory: folder, baseName: "\(base) – \(FileNaming.rangeLabel(p...p, pageCount: doc.pageCount))", ext: o.format.fileExtension)
                    try data.write(to: url)
                    written += 1
                    if r.outputs.count < 500 { r.outputs.append(url) }
                    await Task.yield()
                }
                r.notes.append("“\(input.url.lastPathComponent)” → \(written) image\(written == 1 ? "" : "s") in “\(folder.lastPathComponent)”.")
            } else {
                var pages: [(Int, String)] = []
                var ocrPages = 0
                for (i, p) in indices.enumerated() {
                    try r.checkCancelled()
                    r.report(progress(i), "“\(input.url.lastPathComponent)”: extracting text, page \(p + 1)")
                    guard let page = doc.page(at: p) else { continue }
                    var text = page.string ?? ""
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, o.ocrWhenNoText, let raster = PageRasterizer.render(page: page, dpi: 250) {
                        text = OCRLayer.plainText(await OCRLayer.recognize(raster, languages: o.languages)); ocrPages += 1
                    }
                    pages.append((p, text.precomposedStringWithCompatibilityMapping))
                    await Task.yield()
                }
                let url = FileNaming.uniqueURL(directory: baseDir, baseName: base, ext: o.format.fileExtension)
                try textDocument(pages: pages, format: o.format, markers: o.pageMarkers, title: input.displayName).write(to: url)
                r.outputs.append(url)
                let empty = pages.filter { $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
                var note = "“\(input.url.lastPathComponent)” → “\(url.lastPathComponent)”."
                if empty > 0 { note += " \(empty) page\(empty == 1 ? " has" : "s have") no text (scanned?). Use “Recognize text” or the OCR tool." }
                if ocrPages > 0 { note += " OCR used on \(ocrPages) page\(ocrPages == 1 ? "" : "s")." }
                r.notes.append(note)
            }
        }
    }

    private static func textDocument(pages: [(Int, String)], format: ConvertFormat, markers: Bool, title: String) throws -> Data {
        switch format {
        case .txt:
            let s = pages.map { markers ? "[Page \($0.0 + 1)]\n\($0.1)" : $0.1 }.joined(separator: "\n\n")
            return Data(s.utf8)
        case .rtf:
            let attrs = RichText.defaultAttributes()
            let all = NSMutableAttributedString()
            for (i, p) in pages.enumerated() {
                if markers { all.append(NSAttributedString(string: "[Page \(p.0 + 1)]\n", attributes: attrs)) }
                all.append(NSAttributedString(string: p.1 + (i < pages.count - 1 ? "\n\n" : ""), attributes: attrs))
            }
            guard let data = try? all.data(from: NSRange(location: 0, length: all.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else {
                throw ToolError.writeFailed("RTF")
            }
            return data
        default:
            func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
            var html = "<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>\(esc(title))</title><style>body{font-family:-apple-system,'Helvetica Neue',sans-serif;max-width:46em;margin:2em auto;padding:0 1em;line-height:1.55}section{margin-bottom:2em}h2{color:#888;font-size:.8em;font-weight:600}</style></head><body>\n"
            for (page, text) in pages {
                html += "<section id=\"p\(page + 1)\">" + (markers ? "<h2>Page \(page + 1)</h2>" : "")
                for para in text.components(separatedBy: "\n") where !para.trimmingCharacters(in: .whitespaces).isEmpty {
                    html += "<p dir=\"auto\">\(esc(para))</p>"
                }
                html += "</section>\n"
            }
            return Data((html + "</body></html>\n").utf8)
        }
    }

    // MARK: Page editor save

    static func savePages(plan: PageEditPlan, sources: [PDFDocument], output: URL) throws {
        guard let first = sources.first else { throw ToolError.invalid("No document loaded.") }
        let out = PDFDocument()
        var firstOccurrence: [Int: Int] = [:]
        for item in plan.items {
            let page: PDFPage
            if let size = item.blankSize {
                guard let blank = BlankPage.make(size: size) else { continue }
                page = blank
            } else if sources.indices.contains(item.source), let copy = sources[item.source].page(at: item.page)?.copy() as? PDFPage {
                page = copy
            } else { continue }
            if item.rotation != 0 { page.rotation = ((page.rotation + item.rotation) % 360 + 360) % 360 }
            out.insert(page, at: out.pageCount)
            if item.source == 0, !item.isBlank, firstOccurrence[item.page] == nil { firstOccurrence[item.page] = out.pageCount - 1 }
        }
        guard out.pageCount > 0 else { throw ToolError.invalid("The document would have no pages.") }
        if let srcRoot = first.outlineRoot {
            let root = PDFOutline(); cloneOutline(srcRoot, into: root, srcDoc: first, dst: out, pageMap: firstOccurrence)
            if root.numberOfChildren > 0 { out.outlineRoot = root }
        }
        try writeDocument(out, to: output)
    }
}
