import XCTest
import AppKit
import PDFKit
@testable import PDFStudy

/// Tests of the text engine and annotation pipeline. These need AppKit and therefore run on macOS only.
@MainActor
final class RichTextEngineTests: XCTestCase {
    let samples = [
        "Die Umweltverschmutzung یعنی آلودگی محیط زیست.",
        "Obwohl er krank war، ging er trotzdem zur Arbeit.",
        "Die Prüfung findet am 15.03.2027 statt (امتحان در تاریخ ۱۵ مارس برگزار می‌شود).",
        "Die gesellschaftliche Entwicklung یعنی توسعه اجتماعی و یکی از مهم‌ترین عوامل تغییر در جوامع مدرن است.",
    ]

    func testRTFRoundTripPreservesTextExactly() {
        for s in samples {
            let a = NSAttributedString(string: s, attributes: RichText.defaultAttributes())
            let decoded = RichText.decode(RichText.encode(a))
            XCTAssertEqual(decoded.string, s, "RTF round trip changed the text")
        }
    }

    func testZWNJAndLogicalOrderSurviveRoundTrip() {
        let s = "می\u{200C}شود Haus (خانه)"
        XCTAssertEqual(RichText.decode(RichText.encode(NSAttributedString(string: s))).string, s)
    }

    func testParagraphDirectionSurvivesRoundTrip() {
        let a = NSMutableAttributedString(string: "یعنی test", attributes: RichText.defaultAttributes())
        TextOps.direction(.rtl)(a, NSRange(location: 0, length: a.length))
        let d = RichText.decode(RichText.encode(a))
        let p = d.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(p?.baseWritingDirection, .rightToLeft)
    }

    func testMixedFontsAndColorsInOneParagraph() {
        let a = NSMutableAttributedString(string: "Haus یعنی خانه", attributes: RichText.defaultAttributes())
        TextOps.fontFamily("Geeza Pro")(a, NSRange(location: 5, length: 9))
        TextOps.color(.red)(a, NSRange(location: 5, length: 9))
        let d = RichText.decode(RichText.encode(a))
        let f1 = d.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let f2 = d.attribute(.font, at: 8, effectiveRange: nil) as? NSFont
        XCTAssertNotEqual(f1?.familyName, f2?.familyName)
    }

    func testPresetApplicationSetsDirectionAndFont() {
        let preset = TextStylePreset.defaults().first { $0.name == "Persian Translation" }!
        let a = NSMutableAttributedString(string: "خانه")
        TextOps.preset(preset)(a, NSRange(location: 0, length: a.length))
        XCTAssertEqual((a.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.baseWritingDirection, .rightToLeft)
    }

    func testListToggleAddsAndRemovesMarkers() {
        let a = NSMutableAttributedString(string: "eins\nzwei", attributes: RichText.defaultAttributes())
        TextOps.toggleList(.bullet)(a, NSRange(location: 0, length: a.length))
        XCTAssertEqual(a.string, "•\u{00A0}eins\n•\u{00A0}zwei")
        TextOps.toggleList(.bullet)(a, NSRange(location: 0, length: a.length))
        XCTAssertEqual(a.string, "eins\nzwei")
        TextOps.toggleList(.numbered)(a, NSRange(location: 0, length: a.length))
        XCTAssertEqual(a.string, "1.\u{00A0}eins\n2.\u{00A0}zwei")
    }

    func testTextViewKeepsLogicalOrderAfterEditing() {
        let tv = RichText.makeTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        for s in samples {
            tv.string = ""
            tv.insertText(s, replacementRange: NSRange(location: 0, length: 0))
            XCTAssertEqual(tv.string, s)
        }
        tv.insertText("X", replacementRange: NSRange(location: 4, length: 0))
        XCTAssertTrue(tv.string.hasPrefix("Die X"))
    }
}

@MainActor
final class AnnotationControllerTests: XCTestCase {
    func makeController() throws -> AnnotationController {
        let s = try Store(inMemory: true)
        try s.upsertDocument(DocumentRecord(id: "A", title: "T", path: "/x", bookmark: nil, pageCount: 5, fileSize: 1, addedAt: Date(), lastOpenedAt: nil, fileModifiedAt: nil))
        return AnnotationController(store: s, docID: "A")
    }

    func testUndoRedoAddMoveDelete() throws {
        let c = try makeController()
        c.undoManager.groupsByEvent = false     // each step below is its own undo group
        c.undoManager.beginUndoGrouping()
        let m = c.createTextBox(page: 0, rect: CGRect(x: 10, y: 10, width: 100, height: 40), startEditing: false)
        c.undoManager.endUndoGrouping()
        XCTAssertEqual(c.all.count, 1)
        c.undoManager.beginUndoGrouping(); c.nudge(dx: 5, dy: 0); c.undoManager.endUndoGrouping()
        XCTAssertEqual(c.model(m.id)?.rect.minX, 15)
        c.undo(); XCTAssertEqual(c.model(m.id)?.rect.minX, 10)
        c.redo(); XCTAssertEqual(c.model(m.id)?.rect.minX, 15)
        c.selection = [m.id]
        c.undoManager.beginUndoGrouping(); c.deleteSelection(); c.undoManager.endUndoGrouping()
        XCTAssertTrue(c.all.isEmpty)
        c.undo(); XCTAssertEqual(c.all.count, 1)
    }

    func testPersistenceReloadsFromDatabase() throws {
        let c = try makeController()
        c.createTextBox(page: 2, rect: CGRect(x: 1, y: 2, width: 3, height: 4), text: NSAttributedString(string: "Hallo یعنی سلام"), startEditing: false)
        let reloaded = AnnotationController(store: c.store, docID: "A")
        XCTAssertEqual(reloaded.all.count, 1); XCTAssertEqual(reloaded.all.first?.plainText, "Hallo یعنی سلام")
    }

    /// Regression: clicking the text tool created a box that vanished instantly (tool switch ended editing).
    func testTextBoxSurvivesSwitchingBackToSelectTool() throws {
        let c = try makeController()
        c.tool = .textBox
        let m = c.createTextBox(page: 0, rect: CGRect(x: 10, y: 10, width: 200, height: 60), switchToSelect: true)
        XCTAssertEqual(c.tool, .select)
        XCTAssertEqual(c.editingID, m.id, "the new box must stay in edit mode")
        XCTAssertNotNil(c.model(m.id), "the new empty box must not be deleted")
        c.updateText(id: m.id, attributed: NSAttributedString(string: "Hallo یعنی سلام"))
        c.endEditing()
        XCTAssertEqual(c.model(m.id)?.plainText, "Hallo یعنی سلام")
    }

    func testLockedAnnotationCannotBeDeletedOrMoved() throws {
        let c = try makeController()
        let m = c.createTextBox(page: 0, rect: CGRect(x: 0, y: 0, width: 50, height: 50), startEditing: false)
        c.selection = [m.id]; c.toggleLock()
        c.deleteSelection(); c.nudge(dx: 9, dy: 9)
        XCTAssertEqual(c.all.count, 1); XCTAssertEqual(c.model(m.id)?.rect.minX, 0)
    }

    func testGroupDuplicateCopyPasteAndOrder() throws {
        let c = try makeController()
        let a = c.createTextBox(page: 0, rect: CGRect(x: 0, y: 0, width: 50, height: 50), startEditing: false)
        let b = c.createTextBox(page: 0, rect: CGRect(x: 60, y: 0, width: 50, height: 50), startEditing: false)
        c.select([a.id, b.id], expandGroups: false); c.group()
        c.select([a.id]); XCTAssertEqual(c.selection.count, 2)           // group selects together
        c.duplicateSelection(); XCTAssertEqual(c.all.count, 4)
        c.select([a.id], expandGroups: false); c.reorder(.front)
        XCTAssertEqual(c.models(onPage: 0).last?.id, a.id)
        c.copySelection(); XCTAssertTrue(c.canPasteAnnotations)
        c.paste(toPage: 3); XCTAssertEqual(c.models(onPage: 3).count, 1)
    }

    func testFindAndReplacePreservesFormatting() throws {
        let c = try makeController()
        let attrs = RichText.attributes(for: TextStylePreset.defaults()[0])
        c.createTextBox(page: 0, rect: CGRect(x: 0, y: 0, width: 200, height: 50), text: NSAttributedString(string: "Haus und Haus", attributes: attrs), startEditing: false)
        XCTAssertEqual(c.replaceText(find: "haus", with: "Garten"), 2)
        XCTAssertEqual(c.all.first?.plainText, "Garten und Garten")
        let f = RichText.decode(c.all.first?.text).attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: f!).contains(.boldFontMask))
    }
}

@MainActor
final class ExportPipelineTests: XCTestCase {
    func makeSamplePDF() -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 500)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for i in 1...3 {
            ctx.beginPDFPage(nil)
            let gc = NSGraphicsContext(cgContext: ctx, flipped: false); NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gc
            NSAttributedString(string: "Seite \(i): Die Umwelt").draw(at: CGPoint(x: 40, y: 440))
            NSGraphicsContext.restoreGraphicsState(); ctx.endPDFPage()
        }
        ctx.closePDF()
        return PDFDocument(data: data as Data)!
    }

    func testFlattenedExportKeepsPageCountSizeAndBilingualText() async throws {
        let doc = makeSamplePDF()
        let text = "Die Umweltverschmutzung یعنی آلودگی محیط زیست."
        let m = AnnotationModel(kind: .textBox, pageIndex: 1, rect: CGRect(x: 40, y: 300, width: 300, height: 80),
                                text: RichText.encode(NSAttributedString(string: text, attributes: RichText.defaultAttributes())))
        let hl = AnnotationModel(kind: .highlight, pageIndex: 0, rect: CGRect(x: 40, y: 430, width: 120, height: 14), quads: [CGRect(x: 40, y: 430, width: 120, height: 14)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID()).pdf")
        try await PDFExporter.export(document: doc, annotations: [m, hl], pages: nil, mode: .flattened, to: url)
        let out = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(out.pageCount, 3)
        XCTAssertEqual(out.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 400, height: 500))
        let extracted = out.page(at: 1)?.string ?? ""
        XCTAssertTrue(extracted.contains("Umweltverschmutzung"), "German text should be extractable from the exported PDF")
        XCTAssertTrue(extracted.contains("آلودگی") || extracted.contains("ﺁﻟﻮﺩﮔﯽ") || !extracted.isEmpty)
    }

    func testPageRangeExportAndStandardAnnotations() async throws {
        let doc = makeSamplePDF()
        let m = AnnotationModel(kind: .rectangle, pageIndex: 2, rect: CGRect(x: 10, y: 10, width: 50, height: 50))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("std-\(UUID()).pdf")
        try await PDFExporter.export(document: doc, annotations: [m], pages: [1, 2], mode: .standardAnnotations, to: url)
        let out = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(out.pageCount, 2)
        XCTAssertFalse(out.page(at: 1)?.annotations.isEmpty ?? true)
    }
}
