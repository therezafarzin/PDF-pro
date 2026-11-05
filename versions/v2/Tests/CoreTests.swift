import XCTest
import CoreGraphics
@testable import PDFStudy

final class FingerprintTests: XCTestCase {
    private func tempFile(_ bytes: Int, seed: UInt8 = 7, name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        var data = Data(count: bytes)
        for i in 0..<bytes { data[i] = UInt8(truncatingIfNeeded: i &* 31 &+ Int(seed)) }
        try data.write(to: url)
        return url
    }

    func testSameContentSameFingerprintRegardlessOfNameOrLocation() throws {
        let a = try tempFile(2_000_000, name: "a-\(UUID()).pdf")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let b = dir.appendingPathComponent("renamed.pdf")
        try FileManager.default.copyItem(at: a, to: b)
        XCTAssertEqual(try DocumentFingerprint.compute(url: a), try DocumentFingerprint.compute(url: b))
    }

    func testDifferentContentDifferentFingerprint() throws {
        XCTAssertNotEqual(try DocumentFingerprint.compute(url: try tempFile(1_000_000, seed: 1)),
                          try DocumentFingerprint.compute(url: try tempFile(1_000_000, seed: 2)))
    }

    func testSmallAndEmptyFilesWork() throws {
        XCTAssertEqual(try DocumentFingerprint.compute(url: try tempFile(0)).count, 64)
        XCTAssertEqual(try DocumentFingerprint.compute(url: try tempFile(10)).count, 64)
        XCTAssertEqual(try DocumentFingerprint.compute(url: try tempFile(300_000)).count, 64)
    }
}

final class StoreTests: XCTestCase {
    func makeStore() throws -> Store { try Store(inMemory: true) }
    func doc(_ id: String, path: String = "/tmp/x.pdf") -> DocumentRecord {
        DocumentRecord(id: id, title: "Buch \(id)", path: path, bookmark: nil, pageCount: 300, fileSize: 1000, addedAt: Date(), lastOpenedAt: nil, fileModifiedAt: nil)
    }

    func testReadingPositionRoundTripAndPersistenceAcrossReopen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).sqlite")
        var p = ReadingPosition()
        p.pageIndex = 49; p.pointX = 12.5; p.pointY = 640.25; p.scale = 1.35; p.fitMode = "custom"
        p.displayMode = 3; p.displaysAsBook = true; p.sidebarVisible = false; p.readingMode = "night"; p.rotations = [3: 90]
        do {
            let s = try Store(url: url)
            try s.upsertDocument(doc("D1"))
            s.savePosition(p, docID: "D1")
        }
        let reopened = try Store(url: url)   // simulates app restart
        let loaded = try XCTUnwrap(reopened.loadPosition(docID: "D1"))
        XCTAssertEqual(loaded.pageIndex, 49); XCTAssertEqual(loaded.scale, 1.35, accuracy: 1e-9)
        XCTAssertEqual(loaded.pointY, 640.25, accuracy: 1e-9); XCTAssertEqual(loaded.fitMode, "custom")
        XCTAssertEqual(loaded.displayMode, 3); XCTAssertTrue(loaded.displaysAsBook); XCTAssertFalse(loaded.sidebarVisible)
        XCTAssertEqual(loaded.rotations[3], 90); XCTAssertEqual(loaded.readingMode, "night")
    }

    func testPositionsAreIndependentPerDocument() throws {
        let s = try makeStore()
        try s.upsertDocument(doc("A")); try s.upsertDocument(doc("B"))
        var a = ReadingPosition(); a.pageIndex = 10
        var b = ReadingPosition(); b.pageIndex = 200
        s.savePosition(a, docID: "A"); s.savePosition(b, docID: "B")
        XCTAssertEqual(s.loadPosition(docID: "A")?.pageIndex, 10)
        XCTAssertEqual(s.loadPosition(docID: "B")?.pageIndex, 200)
    }

    func testAnnotationPersistenceAndDeletion() throws {
        let s = try makeStore(); try s.upsertDocument(doc("A"))
        var m = AnnotationModel(kind: .textBox, pageIndex: 5, rect: CGRect(x: 10, y: 20, width: 200, height: 80),
                                text: TextContent(rtf: Data(), plain: "Die Umweltverschmutzung یعنی آلودگی محیط زیست"))
        m.style.fill = RGBA(1, 1, 0.5)
        let h = AnnotationModel(kind: .highlight, pageIndex: 5, rect: CGRect(x: 1, y: 2, width: 3, height: 4), quads: [CGRect(x: 1, y: 2, width: 3, height: 4)])
        try s.saveAnnotations([m, h], docID: "A")
        let loaded = s.annotations(docID: "A")
        XCTAssertEqual(loaded.count, 2)
        let lm = try XCTUnwrap(loaded.first { $0.kind == .textBox })
        XCTAssertEqual(lm.rect, m.rect); XCTAssertEqual(lm.plainText, m.plainText); XCTAssertEqual(lm.style.fill, m.style.fill)
        try s.deleteAnnotations(ids: [m.id])
        XCTAssertEqual(s.annotations(docID: "A").count, 1)
    }

    func testAnnotationSearchFindsGermanAndPersian() throws {
        let s = try makeStore(); try s.upsertDocument(doc("A"))
        let m = AnnotationModel(kind: .textBox, pageIndex: 49, rect: .zero,
                                text: TextContent(rtf: Data(), plain: "Die gesellschaftliche Entwicklung یعنی توسعه اجتماعی"))
        try s.saveAnnotations([m], docID: "A")
        XCTAssertEqual(s.searchUser("gesellschaftliche").first?.page, 49)
        XCTAssertEqual(s.searchUser("توسعه").count, 1)
        XCTAssertEqual(s.searchUser("entwicklung یعنی").count, 1)
        try s.deleteAnnotations(ids: [m.id])
        XCTAssertTrue(s.searchUser("gesellschaftliche").isEmpty)
    }

    func testPDFIndexSearchGermanSpecialCharacters() throws {
        let s = try makeStore(); try s.upsertDocument(doc("A"))
        try s.indexPDFPages(docID: "A", pages: [(0, "Die Straße ist lang."), (1, "Müller wohnt in Köln."), (2, "می‌شود امتحان ۱۵")])
        XCTAssertEqual(s.searchPDF("Strasse").first?.page, 0)
        XCTAssertEqual(s.searchPDF("Straße").first?.page, 0)
        XCTAssertEqual(s.searchPDF("mueller").count, 0)   // documented: ue/ü equivalence is handled by PDF find variants only
        XCTAssertEqual(s.searchPDF("Muller").first?.page, 1)
        XCTAssertEqual(s.searchPDF("15").first?.page, 2)
    }

    func testRekeyKeepsEverything() throws {
        let s = try makeStore(); try s.upsertDocument(doc("OLD"))
        var pos = ReadingPosition(); pos.pageIndex = 7
        s.savePosition(pos, docID: "OLD")
        try s.saveAnnotations([AnnotationModel(kind: .rectangle, pageIndex: 1, rect: CGRect(x: 0, y: 0, width: 5, height: 5))], docID: "OLD")
        _ = s.addBookmark(docID: "OLD", page: 3, name: "Konjunktiv")
        try s.rekeyDocument(from: "OLD", to: "NEW")
        XCTAssertNil(s.document(id: "OLD"))
        XCTAssertEqual(s.loadPosition(docID: "NEW")?.pageIndex, 7)
        XCTAssertEqual(s.annotations(docID: "NEW").count, 1)
        XCTAssertEqual(s.bookmarks(docID: "NEW").first?.name, "Konjunktiv")
    }

    func testBookmarksPageNotesVocabularyProgress() throws {
        let s = try makeStore(); try s.upsertDocument(doc("A"))
        let b = s.addBookmark(docID: "A", page: 9, name: "Passiv")
        XCTAssertEqual(s.bookmarks(docID: "A").count, 1)
        s.renameBookmark(b.id, name: "Passiv Übung"); XCTAssertEqual(s.bookmarks(docID: "A").first?.name, "Passiv Übung")
        s.deleteBookmark(b.id); XCTAssertTrue(s.bookmarks(docID: "A").isEmpty)

        s.savePageNote(docID: "A", page: 2, text: "Wichtig یعنی مهم")
        XCTAssertEqual(s.pageNote(docID: "A", page: 2)?.text, "Wichtig یعنی مهم")
        XCTAssertEqual(s.searchUser("wichtig").first?.scope, .note)
        s.savePageNote(docID: "A", page: 2, text: "  ")
        XCTAssertNil(s.pageNote(docID: "A", page: 2))

        var v = VocabularyEntry(docID: "A", page: 4); v.word = "Umwelt"; v.article = .die; v.translation = "محیط زیست"
        s.saveVocabulary(v)
        XCTAssertEqual(s.vocabulary(docID: "A").first?.displayWord, "die Umwelt")
        XCTAssertEqual(s.searchUser("محیط").first?.scope, .vocab)

        s.markPageRead(docID: "A", page: 1); s.markPageRead(docID: "A", page: 1); s.markPageRead(docID: "A", page: 2)
        XCTAssertEqual(s.document(id: "A")?.pagesRead, 2)
        XCTAssertEqual(try XCTUnwrap(s.document(id: "A")).progress, 2.0 / 300.0, accuracy: 1e-9)
    }

    func testCollectionsFoldersAndTags() throws {
        let s = try makeStore(); try s.upsertDocument(doc("A"))
        let root = try XCTUnwrap(s.createCollection(name: "German"))
        let b1 = try XCTUnwrap(s.createCollection(name: "B1", parentID: root.id))
        s.add(document: "A", toCollection: b1.id)
        XCTAssertEqual(s.documentIDs(inCollection: root.id), ["A"])
        XCTAssertEqual(s.collectionTree().first?.children?.first?.name, "B1")
        s.setTags(["grammar", " B2 ", ""], for: "A")
        XCTAssertEqual(s.allDocuments().first?.tags.sorted(), ["B2", "grammar"])
        s.deleteCollection(root.id)
        XCTAssertTrue(s.documentIDs(inCollection: b1.id).isEmpty)
    }

    func testDefaultTextStylesSeededOnce() throws {
        let s = try makeStore()
        let first = s.textStyles()
        XCTAssertEqual(first.map { $0.name }, ["German Vocabulary", "Persian Translation", "Grammar Explanation", "Important Note", "Exam Tip", "Example Sentence"])
        s.deleteTextStyle(first[0].id)
        XCTAssertEqual(s.textStyles().count, 5)   // not re-seeded
    }

    func testSnapshotsKeepLimit() throws {
        let s = try makeStore(); try s.upsertDocument(doc("A"))
        let m = [AnnotationModel(kind: .ellipse, pageIndex: 0, rect: CGRect(x: 0, y: 0, width: 1, height: 1))]
        for i in 0..<5 { s.saveSnapshot(docID: "A", label: "v\(i)", models: m, keep: 3) }
        XCTAssertEqual(s.snapshots(docID: "A").count, 3)
        XCTAssertEqual(s.snapshotModels(id: s.snapshots(docID: "A")[0].id)?.count, 1)
    }

    func testBackupIsCompleteAndRotates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bk-\(UUID())")
        let s = try makeStore(); try s.upsertDocument(doc("A"))
        let bm = BackupManager(directory: dir, keep: 2)
        for i in 0..<4 { try bm.backup(s, label: "t\(i)"); Thread.sleep(forTimeInterval: 1.05) }
        XCTAssertEqual(bm.list().count, 2)
        let restored = try Store(url: bm.list()[0])
        XCTAssertNotNil(restored.document(id: "A"))
    }
}

final class ModelAndGeometryTests: XCTestCase {
    func testAnnotationCodableForwardCompatibility() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"textBox","pageIndex":2,"rect":[[1,2],[3,4]]}"#
        let m = try JSONDecoder().decode(AnnotationModel.self, from: Data(json.utf8))
        XCTAssertEqual(m.kind, .textBox); XCTAssertFalse(m.locked); XCTAssertEqual(m.zIndex, 0); XCTAssertTrue(m.quads.isEmpty)
    }

    func testHitTesting() {
        let box = AnnotationModel(kind: .textBox, pageIndex: 0, rect: CGRect(x: 100, y: 100, width: 50, height: 20))
        XCTAssertTrue(box.hitTest(CGPoint(x: 120, y: 110), tolerance: 2)); XCTAssertFalse(box.hitTest(CGPoint(x: 10, y: 10), tolerance: 2))
        let line = AnnotationModel(kind: .line, pageIndex: 0, rect: .zero, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
        XCTAssertTrue(line.hitTest(CGPoint(x: 50, y: 3), tolerance: 4)); XCTAssertFalse(line.hitTest(CGPoint(x: 50, y: 30), tolerance: 4))
        let outline = AnnotationModel(kind: .rectangle, pageIndex: 0, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(outline.hitTest(CGPoint(x: 50, y: 50), tolerance: 3)); XCTAssertTrue(outline.hitTest(CGPoint(x: 0, y: 50), tolerance: 3))
        let hl = AnnotationModel(kind: .highlight, pageIndex: 0, rect: .zero, quads: [CGRect(x: 0, y: 0, width: 50, height: 10)])
        XCTAssertTrue(hl.hitTest(CGPoint(x: 25, y: 5), tolerance: 0))
    }

    func testTranslateAndResize() {
        var m = AnnotationModel(kind: .line, pageIndex: 0, rect: CGRect(x: 0, y: 0, width: 100, height: 50), points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 50)])
        m = m.translated(dx: 10, dy: 5)
        XCTAssertEqual(m.points[1], CGPoint(x: 110, y: 55))
        let r = m.resized(to: CGRect(x: 10, y: 5, width: 200, height: 100))
        XCTAssertEqual(r.points[1].x, 210, accuracy: 1e-9); XCTAssertEqual(r.points[1].y, 105, accuracy: 1e-9)
    }

    func testPageGeometryRoundTripsForAllRotations() {
        let box = CGRect(x: 10, y: 20, width: 600, height: 800)
        for rot in [0, 90, 180, 270, -90, 450] {
            let g = PageGeometry(box: box, rotation: rot)
            for p in [CGPoint(x: 10, y: 20), CGPoint(x: 610, y: 820), CGPoint(x: 300, y: 400), CGPoint(x: 55, y: 777)] {
                let q = g.fromDisplay(g.toDisplay(p))
                XCTAssertEqual(q.x, p.x, accuracy: 1e-9, "rot \(rot)"); XCTAssertEqual(q.y, p.y, accuracy: 1e-9, "rot \(rot)")
            }
            let r = CGRect(x: 50, y: 60, width: 100, height: 30)
            let back = g.fromDisplay(g.toDisplay(r))
            XCTAssertEqual(back.origin.x, r.origin.x, accuracy: 1e-9); XCTAssertEqual(back.size.width, r.size.width, accuracy: 1e-9)
        }
    }

    func testPageGeometryKnownPoints() {
        let g0 = PageGeometry(box: CGRect(x: 0, y: 0, width: 600, height: 800), rotation: 0)
        XCTAssertEqual(g0.toDisplay(CGPoint(x: 0, y: 800)), CGPoint(x: 0, y: 0))       // top-left of page
        let g90 = PageGeometry(box: CGRect(x: 0, y: 0, width: 600, height: 800), rotation: 90)
        XCTAssertEqual(g90.displaySize, CGSize(width: 800, height: 600))
        XCTAssertEqual(g90.toDisplay(CGPoint(x: 0, y: 0)), CGPoint(x: 0, y: 0))        // bottom-left -> top-left after clockwise turn
        XCTAssertEqual(g90.toDisplay(CGPoint(x: 0, y: 800)), CGPoint(x: 800, y: 0))    // top-left -> top-right
    }

    func testPageRangeParser() {
        XCTAssertEqual(PageRangeParser.parse("1-3, 5, 8-9", pageCount: 10), [0, 1, 2, 4, 7, 8])
        XCTAssertEqual(PageRangeParser.parse("3,3,2", pageCount: 5), [1, 2])
        XCTAssertNil(PageRangeParser.parse("0", pageCount: 5)); XCTAssertNil(PageRangeParser.parse("4-2", pageCount: 5))
        XCTAssertNil(PageRangeParser.parse("1-9", pageCount: 5)); XCTAssertNil(PageRangeParser.parse("abc", pageCount: 5))
    }

    func testMarkupToggleMath() {
        let line = CGRect(x: 100, y: 500, width: 80, height: 12)
        XCTAssertEqual(MarkupMath.overlapFraction(of: line, with: line), 1, accuracy: 1e-9)
        XCTAssertTrue(MarkupMath.isCovered(line, by: [line.insetBy(dx: -1, dy: -1)]))
        XCTAssertTrue(MarkupMath.isCovered(line, by: [CGRect(x: 100, y: 500, width: 40, height: 12), CGRect(x: 140, y: 500, width: 40, height: 12)]))
        XCTAssertFalse(MarkupMath.isCovered(line, by: [CGRect(x: 300, y: 500, width: 80, height: 12)]))
        XCTAssertFalse(MarkupMath.isCovered(line, by: []))
    }

    func testSimplifyKeepsShape() {
        let pts = (0...100).map { CGPoint(x: CGFloat($0), y: 0.01 * CGFloat($0 % 2)) }
        XCTAssertEqual(GeometryMath.simplify(pts, epsilon: 0.5).count, 2)
    }

    func testRGBAHex() {
        XCTAssertEqual(RGBA(hex: "#3354CC")?.hex, "#3354CC"); XCTAssertNil(RGBA(hex: "nope"))
    }
}

final class TextNormalizerTests: XCTestCase {
    func testDirectionDetection() {
        XCTAssertEqual(TextNormalizer.dominantDirection(of: "Die Umwelt یعنی محیط"), .ltr)
        XCTAssertEqual(TextNormalizer.dominantDirection(of: "یعنی die Umwelt"), .rtl)
        XCTAssertEqual(TextNormalizer.dominantDirection(of: "123 ... (!)"), .neutral)
        XCTAssertTrue(TextNormalizer.isMixedDirection("Obwohl er krank war، ging er"))
        XCTAssertFalse(TextNormalizer.isMixedDirection("nur deutsch"))
    }

    func testIndexFormUnifiesPersianAndGerman() {
        XCTAssertEqual(TextNormalizer.indexForm("Straße"), "Strasse")
        XCTAssertEqual(TextNormalizer.indexForm("می\u{200C}شود"), "می شود")
        XCTAssertEqual(TextNormalizer.indexForm("كتاب ي"), "کتاب ی")
        XCTAssertEqual(TextNormalizer.indexForm("۱۵ ٢٣"), "15 23")
        XCTAssertEqual(TextNormalizer.indexForm("a\u{200F}b\u{202B}c"), "abc")
        XCTAssertEqual(TextNormalizer.indexForm("سَلام"), "سلام")
    }

    func testFoldAndQuery() {
        XCTAssertEqual(TextNormalizer.fold("MÜLLER"), "muller")
        XCTAssertEqual(TextNormalizer.ftsQuery("Die Umwelt"), "\"Die\" \"Umwelt\" *")
        XCTAssertNil(TextNormalizer.ftsQuery("  !!  "))
        XCTAssertEqual(TextNormalizer.ftsQuery("a\"b"), "\"a\" \"b\" *")   // quote is a separator, never injected into MATCH
    }

    func testPDFFindVariants() {
        let v = TextNormalizer.pdfFindVariants("Straße")
        XCTAssertTrue(v.contains("Strasse")); XCTAssertEqual(v.first, "Straße")
        XCTAssertTrue(TextNormalizer.pdfFindVariants("کتاب").contains("كتاب"))
        XCTAssertTrue(TextNormalizer.pdfFindVariants("می‌شود").contains("می شود"))
        XCTAssertTrue(TextNormalizer.pdfFindVariants("15").contains("۱۵"))
        XCTAssertTrue(TextNormalizer.pdfFindVariants("  ").isEmpty)
    }

    func testSentenceRange() {
        let t = "Das ist der erste Satz. Hier folgt der zweite Satz! Und ein dritter."
        let r = TextNormalizer.enclosingRange(in: t, around: 30, paragraph: false)
        XCTAssertTrue((t as NSString).substring(with: r).hasPrefix("Hier folgt"))
    }
}

final class PageRangeAndExportTests: XCTestCase {
    func testAnkiExportEscapesAndKeepsPersianRTL() {
        var v = VocabularyEntry(); v.word = "Umwelt"; v.article = .die; v.translation = "محیط زیست"; v.example = "Die <Umwelt> & wir\tTab"
        let out = VocabularyExporter.ankiTSV([v])
        XCTAssertTrue(out.hasPrefix("#separator:tab"))
        XCTAssertTrue(out.contains("dir=\"rtl\"")); XCTAssertTrue(out.contains("&lt;Umwelt&gt; &amp; wir"))
        XCTAssertEqual(out.split(separator: "\n").last?.split(separator: "\t", omittingEmptySubsequences: false).count, 3)
    }
    func testCSVQuoting() {
        var v = VocabularyEntry(); v.word = "a,b"; v.example = "say \"hi\""
        let out = VocabularyExporter.csv([v])
        XCTAssertTrue(out.hasPrefix("\u{FEFF}")); XCTAssertTrue(out.contains("\"a,b\"")); XCTAssertTrue(out.contains("\"say \"\"hi\"\"\""))
    }
    func testMarkdownNotesExport() {
        var v = VocabularyEntry(); v.word = "Haus"; v.translation = "خانه"
        let md = NotesExporter.markdown(title: "Buch", bookmarks: [BookmarkRecord(id: "1", docID: "d", page: 4, name: "Kapitel", createdAt: Date())],
                                        pageNotes: [PageNote(docID: "d", page: 1, text: "Notiz", updatedAt: Date())], annotations: [], vocabulary: [v])
        XCTAssertTrue(md.contains("p. 5: Kapitel")); XCTAssertTrue(md.contains("| Haus | خانه |"))
    }
}
