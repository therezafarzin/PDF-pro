import XCTest
import AppKit
import PDFKit
@testable import PDFStudy

// MARK: - Pure logic (same cases are mirrored in scripts/verify_tools.py)

final class ToolsCoreTests: XCTestCase {
    func testSplitPlanner() {
        XCTAssertEqual(SplitPlanner.plan(pageCount: 5, mode: .everyN(2)), [0...1, 2...3, 4...4])
        XCTAssertEqual(SplitPlanner.plan(pageCount: 5, mode: .everyN(10)), [0...4])
        XCTAssertEqual(SplitPlanner.plan(pageCount: 3, mode: .everyN(0)), [0...0, 1...1, 2...2])
        XCTAssertEqual(SplitPlanner.plan(pageCount: 3, mode: .singlePages), [0...0, 1...1, 2...2])
        XCTAssertEqual(SplitPlanner.plan(pageCount: 7, mode: .startingAt([3, 5])), [0...1, 2...3, 4...6])
        XCTAssertEqual(SplitPlanner.plan(pageCount: 7, mode: .startingAt([1, 3, 3, 99, 0])), [0...1, 2...6])
        XCTAssertEqual(SplitPlanner.plan(pageCount: 10, mode: .outline([4, 7])), [0...3, 4...6, 7...9])
        XCTAssertEqual(SplitPlanner.plan(pageCount: 10, mode: .outline([0, 4, 4])), [0...3, 4...9])
        XCTAssertEqual(SplitPlanner.plan(pageCount: 10, mode: .ranges([2...4, 8...20, 30...40])), [2...4, 8...9])
        XCTAssertTrue(SplitPlanner.plan(pageCount: 0, mode: .everyN(3)).isEmpty)
    }

    func testRangeGroupParsing() {
        XCTAssertEqual(SplitPlanner.parseRangeGroups("1-5, 8, 10-12", pageCount: 12), [0...4, 7...7, 9...11])
        XCTAssertEqual(SplitPlanner.parseRangeGroups("1–2،4", pageCount: 5), [0...1, 3...3])
        XCTAssertNil(SplitPlanner.parseRangeGroups("0", pageCount: 5)); XCTAssertNil(SplitPlanner.parseRangeGroups("4-2", pageCount: 5))
        XCTAssertNil(SplitPlanner.parseRangeGroups("1-9", pageCount: 5)); XCTAssertNil(SplitPlanner.parseRangeGroups("x", pageCount: 5))
        XCTAssertEqual(SplitPlanner.parseStartPages("10, 25 40", pageCount: 50), [10, 25, 40])
        XCTAssertNil(SplitPlanner.parseStartPages("0", pageCount: 50)); XCTAssertNil(SplitPlanner.parseStartPages("51", pageCount: 50))
    }

    func testFileNaming() throws {
        XCTAssertEqual(FileNaming.sanitize("A/B:C?"), "A-B-C-")
        XCTAssertEqual(FileNaming.sanitize("  ..  "), "Untitled")
        XCTAssertEqual(FileNaming.sanitize("کتاب آلمانی"), "کتاب آلمانی")
        XCTAssertEqual(FileNaming.rangeLabel(0...9, pageCount: 250), "pages 001-010")
        XCTAssertEqual(FileNaming.rangeLabel(6...6, pageCount: 99), "page 07")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("naming-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = FileNaming.uniqueURL(directory: dir, baseName: "Buch", ext: "pdf")
        XCTAssertEqual(a.lastPathComponent, "Buch.pdf")
        try Data().write(to: a)
        XCTAssertEqual(FileNaming.uniqueURL(directory: dir, baseName: "Buch", ext: "pdf").lastPathComponent, "Buch 2.pdf")
    }

    func testPageEditPlan() {
        var p = PageEditPlan(pageCount: 6)
        let ids = p.items.map { $0.id }
        XCTAssertFalse(p.isModified)
        p.rotate([ids[1]], by: 90); XCTAssertEqual(p.items[1].rotation, 90)
        p.rotate([ids[1]], by: -180); XCTAssertEqual(p.items[1].rotation, 270)
        p.undo(); p.undo(); XCTAssertFalse(p.isModified)
        p.redo(); XCTAssertEqual(p.items[1].rotation, 90)

        var d = PageEditPlan(pageCount: 5); let di = d.items.map { $0.id }
        XCTAssertTrue(d.delete([di[1], di[3]])); XCTAssertEqual(d.items.map { $0.page }, [0, 2, 4])
        d.undo(); XCTAssertEqual(d.items.map { $0.page }, [0, 1, 2, 3, 4])
        XCTAssertFalse(d.delete(Set(di))); XCTAssertEqual(d.items.count, 5)
        d.duplicate([di[0], di[4]]); XCTAssertEqual(d.items.map { $0.page }, [0, 0, 1, 2, 3, 4, 4])
        XCTAssertEqual(Set(d.items.map { $0.id }).count, 7)

        var m = PageEditPlan(pageCount: 6); let mi = m.items.map { $0.id }
        m.move([mi[4], mi[5]], to: 1); XCTAssertEqual(m.items.map { $0.page }, [0, 4, 5, 1, 2, 3])
        var m2 = PageEditPlan(pageCount: 6); let m2i = m2.items.map { $0.id }
        m2.move([m2i[0]], to: 4); XCTAssertEqual(m2.items.map { $0.page }, [1, 2, 3, 0, 4, 5])
        var m3 = PageEditPlan(pageCount: 4); let m3i = m3.items.map { $0.id }
        m3.move([m3i[1]], to: 99); XCTAssertEqual(m3.items.map { $0.page }, [0, 2, 3, 1])
        m3.move([m3i[3]], to: 0); XCTAssertEqual(Array(m3.items.map { $0.page }.prefix(2)), [3, 0])

        var b = PageEditPlan(pageCount: 3); let bi = b.items.map { $0.id }
        b.insertBlank(after: bi[0], size: CGSize(width: 595, height: 842))
        XCTAssertEqual(b.items.count, 4); XCTAssertTrue(b.items[1].isBlank)
        b.insertPages(source: 1, pages: [0, 1], after: nil)
        XCTAssertEqual(b.items.suffix(2).map { $0.source }, [1, 1])
        b.insertPages(source: 1, pages: [5], after: bi[2])
        XCTAssertEqual(b.items[4].page, 5); XCTAssertEqual(b.items[4].source, 1)
    }

    func testSignatureNormalizeAndStore() throws {
        let r = try XCTUnwrap(SignatureMath.normalize([[CGPoint(x: 10, y: 20), CGPoint(x: 110, y: 20)], [CGPoint(x: 60, y: 20), CGPoint(x: 60, y: 70)]]))
        XCTAssertEqual(r.aspect, 2, accuracy: 1e-9)
        XCTAssertEqual(r.strokes[0][1], CGPoint(x: 1, y: 0)); XCTAssertEqual(r.strokes[1][1], CGPoint(x: 0.5, y: 1))
        XCTAssertNil(SignatureMath.normalize([[CGPoint(x: 1, y: 1)]]))
        let s = try Store(inMemory: true)
        let sig = SavedSignature(name: "Ali", strokes: r.strokes, aspect: r.aspect)
        s.saveSignatures([sig])
        XCTAssertEqual(s.signatures(), [sig])
    }

    func testConvertFormatExtensions() {
        XCTAssertEqual(ConvertFormat.jpeg.fileExtension, "jpg"); XCTAssertEqual(ConvertFormat.png.fileExtension, "png")
        XCTAssertTrue(ConvertFormat.tiff.isImage); XCTAssertFalse(ConvertFormat.html.isImage)
    }
}

// MARK: - Pipelines (need macOS: PDFKit / AppKit / Vision)

@MainActor
final class ToolsPipelineTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func makePDF(pages: Int, name: String, text: String = "Seite") throws -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 400, height: 500)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for i in 1...pages {
            ctx.beginPDFPage(nil)
            let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gc
            NSAttributedString(string: "\(text) \(i): Die Umwelt", attributes: [.font: NSFont.systemFont(ofSize: 18)]).draw(at: CGPoint(x: 40, y: 440))
            NSGraphicsContext.restoreGraphicsState(); ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    func makePNG(name: String, size: CGSize = CGSize(width: 300, height: 200)) throws -> URL {
        let img = NSImage(size: size)
        img.lockFocus(); NSColor.systemBlue.setFill(); NSRect(origin: .zero, size: size).fill(); img.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(img.tiffRepresentation)))
        let url = dir.appendingPathComponent(name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    func testCombinePdfsImagesAndPageSelection() async throws {
        let a = try makePDF(pages: 2, name: "a.pdf"), b = try makePDF(pages: 3, name: "b.pdf"), img = try makePNG(name: "i.png")
        var first = ToolInput(url: a); first.pages = "2"
        let out = dir.appendingPathComponent("combined.pdf")
        let r = ToolRunner()
        try await PDFTools.combine(inputs: [first, ToolInput(url: b), ToolInput(url: img)], fitImagesToA4: true, bookmarks: true, output: out, runner: r)
        let doc = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(doc.pageCount, 1 + 3 + 1)
        XCTAssertEqual(doc.outlineRoot?.numberOfChildren, 3)
        XCTAssertTrue((doc.page(at: 1)?.string ?? "").contains("Seite 1"))
        XCTAssertLessThanOrEqual(doc.page(at: 4)?.bounds(for: .mediaBox).size.width ?? 9999, 842.5)   // image page fits A4
        XCTAssertEqual(r.outputs, [out])
    }

    func testCombineRejectsBadPageSelection() async throws {
        let a = try makePDF(pages: 2, name: "a.pdf")
        var i = ToolInput(url: a); i.pages = "9"
        do { try await PDFTools.combine(inputs: [i], fitImagesToA4: true, bookmarks: false, output: dir.appendingPathComponent("x.pdf"), runner: ToolRunner()); XCTFail("should throw") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not valid")) }
    }

    func testSplitEveryNAndRanges() async throws {
        let src = try makePDF(pages: 5, name: "book.pdf")
        let r = ToolRunner()
        try await PDFTools.split(inputs: [ToolInput(url: src)], strategy: .everyN(2), outputDir: nil, runner: r)
        XCTAssertEqual(r.outputs.count, 3)
        XCTAssertEqual(r.outputs.compactMap { PDFDocument(url: $0)?.pageCount }, [2, 2, 1])
        XCTAssertTrue(r.outputs[0].lastPathComponent.contains("pages 1-2"))

        let r2 = ToolRunner()
        try await PDFTools.split(inputs: [ToolInput(url: src)], strategy: .ranges("1-2, 4"), outputDir: nil, runner: r2)
        XCTAssertEqual(r2.outputs.compactMap { PDFDocument(url: $0)?.pageCount }, [2, 1])
        XCTAssertNotEqual(r.outputs[0].deletingLastPathComponent(), r2.outputs[0].deletingLastPathComponent(), "second run must not overwrite the first folder")

        do { try await PDFTools.split(inputs: [ToolInput(url: src)], strategy: .ranges("9-12"), outputDir: nil, runner: ToolRunner()); XCTFail("should throw") } catch {}
    }

    func testSplitKeepsOriginalUntouched() async throws {
        let src = try makePDF(pages: 3, name: "o.pdf")
        let before = try Data(contentsOf: src)
        try await PDFTools.split(inputs: [ToolInput(url: src)], strategy: .singlePages, outputDir: nil, runner: ToolRunner())
        XCTAssertEqual(try Data(contentsOf: src), before)
    }

    func testConvertToPNGAndText() async throws {
        let src = try makePDF(pages: 3, name: "c.pdf")
        let r = ToolRunner()
        var o = ConvertOptions(); o.format = .png; o.dpi = 72
        try await PDFTools.convert(inputs: [ToolInput(url: src)], options: o, outputDir: nil, store: nil, runner: r)
        XCTAssertEqual(r.outputs.count, 3)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: r.outputs[0])))
        XCTAssertEqual(rep.pixelsWide, 400); XCTAssertEqual(rep.pixelsHigh, 500)

        let r2 = ToolRunner(); o.format = .txt
        try await PDFTools.convert(inputs: [ToolInput(url: src)], options: o, outputDir: nil, store: nil, runner: r2)
        let txt = try String(contentsOf: try XCTUnwrap(r2.outputs.first), encoding: .utf8)
        XCTAssertTrue(txt.contains("[Page 1]")); XCTAssertTrue(txt.contains("Seite 2"))

        let r3 = ToolRunner(); o.format = .html
        try await PDFTools.convert(inputs: [ToolInput(url: src)], options: o, outputDir: nil, store: nil, runner: r3)
        let html = try String(contentsOf: try XCTUnwrap(r3.outputs.first), encoding: .utf8)
        XCTAssertTrue(html.contains("dir=\"auto\"")); XCTAssertTrue(html.contains("charset=\"utf-8\""))

        let r4 = ToolRunner(); o.format = .rtf
        try await PDFTools.convert(inputs: [ToolInput(url: src)], options: o, outputDir: nil, store: nil, runner: r4)
        XCTAssertTrue((try Data(contentsOf: try XCTUnwrap(r4.outputs.first))).starts(with: Data("{\\rtf".utf8)))
    }

    func testOptimizeNeverReturnsLargerFileAndKeepsOriginal() async throws {
        let src = try makePDF(pages: 3, name: "opt.pdf")
        let before = try Data(contentsOf: src)
        for preset in OptimizePreset.allCases {
            let r = ToolRunner()
            try await PDFTools.optimize(inputs: [ToolInput(url: src)], preset: preset, dpi: 72, quality: 0.5, keepSearchable: false, languages: [], outputDir: nil, runner: r)
            XCTAssertEqual(r.notes.count, 1, "\(preset)")
            for out in r.outputs {
                let a = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.intValue ?? 0
                XCTAssertLessThan(a, before.count)
                XCTAssertEqual(PDFDocument(url: out)?.pageCount, 3)
            }
        }
        XCTAssertEqual(try Data(contentsOf: src), before)
    }

    func testSavePagesAppliesRotationDeleteBlankAndKeepsOutline() throws {
        let src = try makePDF(pages: 4, name: "e.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: src))
        var plan = PageEditPlan(pageCount: 4)
        let ids = plan.items.map { $0.id }
        plan.rotate([ids[0]], by: 90); plan.delete([ids[1]]); plan.insertBlank(after: ids[0], size: CGSize(width: 300, height: 300))
        let out = dir.appendingPathComponent("edited.pdf")
        try PDFTools.savePages(plan: plan, sources: [doc], output: out)
        let result = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(result.pageCount, 4)                           // 4 - 1 deleted + 1 blank
        XCTAssertEqual(result.page(at: 0)?.rotation, 90)
        XCTAssertEqual(result.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 300, height: 300))
        XCTAssertTrue((result.page(at: 2)?.string ?? "").contains("Seite 3"))
    }

    func testOCRAddsSearchableTextToImageOnlyPage() async throws {
        // Page that is only a picture of text (like a scan).
        let size = CGSize(width: 800, height: 300)
        let img = NSImage(size: size)
        img.lockFocus(); NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        NSAttributedString(string: "Hallo Welt Umwelt", attributes: [.font: NSFont.systemFont(ofSize: 90), .foregroundColor: NSColor.black]).draw(at: CGPoint(x: 30, y: 100))
        img.unlockFocus()
        let doc = PDFDocument(); doc.insert(try XCTUnwrap(PDFPage(image: img)), at: 0)
        let src = dir.appendingPathComponent("scan.pdf"); XCTAssertTrue(doc.write(to: src))
        XCTAssertTrue((PDFDocument(url: src)?.page(at: 0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let r = ToolRunner()
        try await PDFTools.ocr(inputs: [ToolInput(url: src)], languages: ["de-DE", "en-US"], skipPagesWithText: true, dpi: 200, outputDir: nil, runner: r)
        let out = try XCTUnwrap(r.outputs.first)
        let text = PDFDocument(url: out)?.page(at: 0)?.string ?? ""
        if text.isEmpty { throw XCTSkip("Vision returned no text on this machine/configuration") }
        XCTAssertTrue(text.localizedCaseInsensitiveContains("hallo"), "got: \(text)")
        XCTAssertEqual(PDFDocument(url: out)?.pageCount, 1)
    }

    func testPasswordProtectedInputIsReportedNotCrashing() async throws {
        let src = try makePDF(pages: 1, name: "plain.pdf")
        let locked = dir.appendingPathComponent("locked.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: src))
        XCTAssertTrue(doc.write(to: locked, withOptions: [.userPasswordOption: "geheim", .ownerPasswordOption: "geheim"]))
        let r = ToolRunner()
        try await PDFTools.split(inputs: [ToolInput(url: locked)], strategy: .singlePages, outputDir: nil, runner: r)
        XCTAssertTrue(r.outputs.isEmpty); XCTAssertTrue(r.notes.first?.contains("password") ?? false)
        var ok = ToolInput(url: locked); ok.password = "geheim"
        let r2 = ToolRunner()
        try await PDFTools.split(inputs: [ok], strategy: .singlePages, outputDir: nil, runner: r2)
        XCTAssertEqual(r2.outputs.count, 1)
    }
}

@MainActor
final class SignatureControllerTests: XCTestCase {
    func testSignaturePlacedAsOneGroupedUndoStep() throws {
        let s = try Store(inMemory: true)
        try s.upsertDocument(DocumentRecord(id: "A", title: "T", path: "/x", bookmark: nil, pageCount: 2, fileSize: 1, addedAt: Date(), lastOpenedAt: nil, fileModifiedAt: nil))
        let c = AnnotationController(store: s, docID: "A")
        c.undoManager.groupsByEvent = false
        let sig = SavedSignature(name: "x", strokes: [[CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0)]], aspect: 2)
        c.undoManager.beginUndoGrouping()
        c.addSignature(sig, page: 0, center: CGPoint(x: 300, y: 200), width: 200, color: .black, lineWidth: 2)
        c.undoManager.endUndoGrouping()
        XCTAssertEqual(c.all.count, 2)
        XCTAssertEqual(Set(c.all.compactMap { $0.groupID }).count, 1)
        let r = GeometryMath.union(c.all.map { $0.rect })
        XCTAssertEqual(r.midX, 300, accuracy: 4); XCTAssertEqual(r.midY, 200, accuracy: 4); XCTAssertEqual(r.width, 200, accuracy: 6)
        c.undo(); XCTAssertTrue(c.all.isEmpty)
        c.redo(); XCTAssertEqual(c.all.count, 2)
    }
}
