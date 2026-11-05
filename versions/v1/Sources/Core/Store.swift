import Foundation

/// Persistence facade. All state lives in one SQLite database in Application Support.
/// Every mutation is written immediately (WAL), so nothing is lost if the app is killed.
final class Store {
    let db: SQLiteDB
    let url: URL?
    private let enc = JSONEncoder()
    private let dec = JSONDecoder()

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PDF Study", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    convenience init() throws {
        try self.init(url: Store.defaultDirectory().appendingPathComponent("library.sqlite"))
    }

    init(url: URL) throws {
        self.url = url
        db = try SQLiteDB(path: url.path)
        try Schema.migrate(db)
    }

    /// In-memory store for tests.
    init(inMemory: Bool) throws {
        url = nil
        db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
    }

    // MARK: Key/value

    func setValue(_ value: String, for key: String) {
        _ = try? db.run("INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
    }
    func value(for key: String) -> String? {
        (try? db.query("SELECT value FROM kv WHERE key = ?", [key]) { $0.string(0) })?.first
    }

    // MARK: Documents

    private static let docColumns = """
        d.id, d.title, d.path, d.bookmark, d.page_count, d.file_size, d.added_at, d.last_opened_at,
        d.file_modified_at, d.favorite, d.pinned, d.open_count, d.indexed_at,
        (SELECT COUNT(*) FROM pages_read r WHERE r.doc_id = d.id)
        """

    private func mapDoc(_ r: Row) -> DocumentRecord {
        DocumentRecord(id: r.string(0), title: r.string(1), path: r.string(2), bookmark: r.data(3),
                       pageCount: r.int(4), fileSize: r.int64(5), addedAt: r.date(6) ?? Date(),
                       lastOpenedAt: r.date(7), fileModifiedAt: r.date(8), isFavorite: r.bool(9),
                       isPinned: r.bool(10), openCount: r.int(11), indexedAt: r.date(12), pagesRead: r.int(13), tags: [])
    }

    func upsertDocument(_ d: DocumentRecord) throws {
        try db.run("""
            INSERT INTO documents(id, title, path, bookmark, page_count, file_size, added_at, last_opened_at, file_modified_at, favorite, pinned, open_count, indexed_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, path=excluded.path, bookmark=excluded.bookmark,
                page_count=excluded.page_count, file_size=excluded.file_size, file_modified_at=excluded.file_modified_at
            """, [d.id, d.title, d.path, d.bookmark, d.pageCount, d.fileSize, d.addedAt, d.lastOpenedAt,
                  d.fileModifiedAt, d.isFavorite, d.isPinned, d.openCount, d.indexedAt])
    }

    func document(id: String) -> DocumentRecord? {
        var d = (try? db.query("SELECT \(Store.docColumns) FROM documents d WHERE d.id = ?", [id], mapDoc))?.first
        d?.tags = tags(for: id)
        return d
    }

    func document(path: String) -> DocumentRecord? {
        var d = (try? db.query("SELECT \(Store.docColumns) FROM documents d WHERE d.path = ? ORDER BY d.added_at DESC LIMIT 1", [path], mapDoc))?.first
        if let id = d?.id { d?.tags = tags(for: id) }
        return d
    }

    func allDocuments() -> [DocumentRecord] {
        var docs = (try? db.query("SELECT \(Store.docColumns) FROM documents d", [], mapDoc)) ?? []
        let tagRows = (try? db.query("SELECT doc_id, tag FROM doc_tags ORDER BY tag COLLATE NOCASE", []) { ($0.string(0), $0.string(1)) }) ?? []
        var map: [String: [String]] = [:]
        for (id, tag) in tagRows { map[id, default: []].append(tag) }
        for i in docs.indices { docs[i].tags = map[docs[i].id] ?? [] }
        return docs
    }

    func markOpened(_ id: String) {
        _ = try? db.run("UPDATE documents SET last_opened_at = ?, open_count = open_count + 1 WHERE id = ?", [Date(), id])
    }
    func setFavorite(_ id: String, _ v: Bool) { _ = try? db.run("UPDATE documents SET favorite = ? WHERE id = ?", [v, id]) }
    func setPinned(_ id: String, _ v: Bool) { _ = try? db.run("UPDATE documents SET pinned = ? WHERE id = ?", [v, id]) }
    func setIndexed(_ id: String, _ date: Date?) { _ = try? db.run("UPDATE documents SET indexed_at = ? WHERE id = ?", [date, id]) }

    func removeDocument(_ id: String) {
        try? db.transaction {
            try db.run("DELETE FROM fts_user WHERE doc_id = ?", [id])
            try db.run("DELETE FROM fts_pdf WHERE doc_id = ?", [id])
            try db.run("DELETE FROM documents WHERE id = ?", [id])
        }
    }

    /// Moves every record of a document to a new id (used when the file's bytes changed,
    /// e.g. after embedding annotations or after another app re-saved the PDF).
    func rekeyDocument(from old: String, to new: String) throws {
        guard old != new else { return }
        try db.transaction {
            if document(id: new) != nil {
                // Target already known: drop the stale record, keep the existing target.
                try db.run("DELETE FROM documents WHERE id = ?", [old])
            } else {
                try db.run("UPDATE documents SET id = ? WHERE id = ?", [new, old])
            }
            try db.run("UPDATE fts_user SET doc_id = ? WHERE doc_id = ?", [new, old])
            try db.run("UPDATE fts_pdf SET doc_id = ? WHERE doc_id = ?", [new, old])
        }
    }

    // Tags
    func tags(for id: String) -> [String] {
        (try? db.query("SELECT tag FROM doc_tags WHERE doc_id = ? ORDER BY tag COLLATE NOCASE", [id]) { $0.string(0) }) ?? []
    }
    func setTags(_ tags: [String], for id: String) {
        try? db.transaction {
            try db.run("DELETE FROM doc_tags WHERE doc_id = ?", [id])
            for t in Set(tags.map { $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
                try db.run("INSERT OR IGNORE INTO doc_tags(doc_id, tag) VALUES(?, ?)", [id, t])
            }
        }
    }
    func allTags() -> [String] {
        (try? db.query("SELECT DISTINCT tag FROM doc_tags ORDER BY tag COLLATE NOCASE", []) { $0.string(0) }) ?? []
    }

    // MARK: Collections

    @discardableResult
    func createCollection(name: String, parentID: String? = nil, icon: String = "books.vertical") -> CollectionRecord? {
        let id = UUID().uuidString
        let sort = ((try? db.query("SELECT COALESCE(MAX(sort), 0) + 1 FROM collections", []) { $0.int(0) })?.first) ?? 0
        guard (try? db.run("INSERT INTO collections(id, name, parent_id, icon, sort, created_at) VALUES(?,?,?,?,?,?)",
                           [id, name, parentID, icon, sort, Date()])) != nil else { return nil }
        return CollectionRecord(id: id, name: name, parentID: parentID, icon: icon, sort: sort)
    }
    func renameCollection(_ id: String, name: String) { _ = try? db.run("UPDATE collections SET name = ? WHERE id = ?", [name, id]) }
    func deleteCollection(_ id: String) { _ = try? db.run("DELETE FROM collections WHERE id = ?", [id]) }

    func collections() -> [CollectionRecord] {
        (try? db.query("SELECT id, name, parent_id, icon, sort FROM collections ORDER BY sort, name COLLATE NOCASE", []) {
            CollectionRecord(id: $0.string(0), name: $0.string(1), parentID: $0.optString(2), icon: $0.string(3), sort: $0.int(4))
        }) ?? []
    }

    func collectionTree() -> [CollectionNode] {
        let all = collections()
        func build(parent: String?) -> [CollectionNode] {
            all.filter { $0.parentID == parent }.map { c in
                let kids = build(parent: c.id)
                return CollectionNode(id: c.id, name: c.name, icon: c.icon, children: kids.isEmpty ? nil : kids)
            }
        }
        return build(parent: nil)
    }

    func add(document id: String, toCollection cid: String) {
        _ = try? db.run("INSERT OR IGNORE INTO collection_docs(collection_id, doc_id) VALUES(?, ?)", [cid, id])
    }
    func remove(document id: String, fromCollection cid: String) {
        _ = try? db.run("DELETE FROM collection_docs WHERE collection_id = ? AND doc_id = ?", [cid, id])
    }
    /// Document ids in a collection, including sub-collections.
    func documentIDs(inCollection cid: String) -> Set<String> {
        let sql = """
            WITH RECURSIVE tree(id) AS (
                SELECT id FROM collections WHERE id = ?
                UNION ALL SELECT c.id FROM collections c JOIN tree t ON c.parent_id = t.id
            ) SELECT DISTINCT doc_id FROM collection_docs WHERE collection_id IN (SELECT id FROM tree)
            """
        return Set((try? db.query(sql, [cid]) { $0.string(0) }) ?? [])
    }
    func collectionIDs(for docID: String) -> Set<String> {
        Set((try? db.query("SELECT collection_id FROM collection_docs WHERE doc_id = ?", [docID]) { $0.string(0) }) ?? [])
    }

    // MARK: Reading position & progress

    func savePosition(_ p: ReadingPosition, docID: String) {
        guard let data = try? enc.encode(p), let json = String(data: data, encoding: .utf8) else { return }
        _ = try? db.run("""
            INSERT INTO reading_positions(doc_id, json, updated_at) VALUES(?,?,?)
            ON CONFLICT(doc_id) DO UPDATE SET json = excluded.json, updated_at = excluded.updated_at
            """, [docID, json, Date()])
    }

    func loadPosition(docID: String) -> ReadingPosition? {
        guard let json = (try? db.query("SELECT json FROM reading_positions WHERE doc_id = ?", [docID]) { $0.string(0) })?.first,
              let data = json.data(using: .utf8) else { return nil }
        return try? dec.decode(ReadingPosition.self, from: data)
    }

    func markPageRead(docID: String, page: Int) {
        _ = try? db.run("INSERT OR IGNORE INTO pages_read(doc_id, page, first_read) VALUES(?,?,?)", [docID, page, Date()])
    }
    func unmarkPageRead(docID: String, page: Int) {
        _ = try? db.run("DELETE FROM pages_read WHERE doc_id = ? AND page = ?", [docID, page])
    }
    func readPages(docID: String) -> Set<Int> {
        Set((try? db.query("SELECT page FROM pages_read WHERE doc_id = ?", [docID]) { $0.int(0) }) ?? [])
    }
    func recordVisit(docID: String, page: Int) {
        _ = try? db.run("""
            INSERT INTO page_visits(doc_id, page, last_visit, visits) VALUES(?,?,?,1)
            ON CONFLICT(doc_id, page) DO UPDATE SET last_visit = excluded.last_visit, visits = visits + 1
            """, [docID, page, Date()])
    }
    func recentPages(limit: Int = 12) -> [(docID: String, title: String, page: Int, date: Date)] {
        (try? db.query("""
            SELECT v.doc_id, d.title, v.page, v.last_visit FROM page_visits v
            JOIN documents d ON d.id = v.doc_id ORDER BY v.last_visit DESC LIMIT ?
            """, [limit]) { (docID: $0.string(0), title: $0.string(1), page: $0.int(2), date: $0.date(3) ?? Date()) }) ?? []
    }

    // MARK: Annotations

    func annotations(docID: String) -> [AnnotationModel] {
        let rows = (try? db.query("SELECT json FROM annotations WHERE doc_id = ? ORDER BY page, z, modified_at", [docID]) { $0.string(0) }) ?? []
        return rows.compactMap { $0.data(using: .utf8).flatMap { try? dec.decode(AnnotationModel.self, from: $0) } }
    }

    func saveAnnotations(_ models: [AnnotationModel], docID: String) throws {
        try db.transaction {
            for m in models {
                let data = try enc.encode(m)
                let json = String(decoding: data, as: UTF8.self)
                try db.run("""
                    INSERT INTO annotations(id, doc_id, page, kind, z, json, modified_at) VALUES(?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET page = excluded.page, kind = excluded.kind, z = excluded.z,
                        json = excluded.json, modified_at = excluded.modified_at
                    """, [m.id.uuidString, docID, m.pageIndex, m.kind.rawValue, m.zIndex, json, m.modifiedAt])
                try reindex(annotation: m, docID: docID)
            }
        }
    }

    func deleteAnnotations(ids: [UUID]) throws {
        try db.transaction {
            for id in ids {
                try db.run("DELETE FROM annotations WHERE id = ?", [id.uuidString])
                try db.run("DELETE FROM fts_user WHERE scope = 'annotation' AND ref_id = ?", [id.uuidString])
            }
        }
    }

    func deleteAllAnnotations(docID: String) throws {
        try db.transaction {
            try db.run("DELETE FROM annotations WHERE doc_id = ?", [docID])
            try db.run("DELETE FROM fts_user WHERE scope = 'annotation' AND doc_id = ?", [docID])
        }
    }

    private func reindex(annotation m: AnnotationModel, docID: String) throws {
        try db.run("DELETE FROM fts_user WHERE scope = 'annotation' AND ref_id = ?", [m.id.uuidString])
        let text = m.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            try db.run("INSERT INTO fts_user(body, scope, doc_id, page, ref_id) VALUES(?,?,?,?,?)",
                       [TextNormalizer.indexForm(text), "annotation", docID, m.pageIndex, m.id.uuidString])
        }
    }

    // Snapshots (version history)
    @discardableResult
    func saveSnapshot(docID: String, label: String, models: [AnnotationModel], keep: Int = 40) -> Int? {
        guard let data = try? enc.encode(models) else { return nil }
        let json = String(decoding: data, as: UTF8.self)
        guard (try? db.run("INSERT INTO snapshots(doc_id, created_at, label, count, json) VALUES(?,?,?,?,?)",
                           [docID, Date(), label, models.count, json])) != nil else { return nil }
        _ = try? db.run("""
            DELETE FROM snapshots WHERE doc_id = ? AND id NOT IN
            (SELECT id FROM snapshots WHERE doc_id = ? ORDER BY id DESC LIMIT ?)
            """, [docID, docID, keep])
        return (try? db.query("SELECT last_insert_rowid()", []) { $0.int(0) })?.first
    }
    func snapshots(docID: String) -> [VersionSnapshot] {
        (try? db.query("SELECT id, doc_id, created_at, label, count FROM snapshots WHERE doc_id = ? ORDER BY id DESC", [docID]) {
            VersionSnapshot(id: $0.int(0), docID: $0.string(1), createdAt: $0.date(2) ?? Date(), label: $0.string(3), count: $0.int(4))
        }) ?? []
    }
    func snapshotModels(id: Int) -> [AnnotationModel]? {
        guard let json = (try? db.query("SELECT json FROM snapshots WHERE id = ?", [id]) { $0.string(0) })?.first,
              let data = json.data(using: .utf8) else { return nil }
        return try? dec.decode([AnnotationModel].self, from: data)
    }

    // MARK: Bookmarks

    func addBookmark(docID: String, page: Int, name: String) -> BookmarkRecord {
        let b = BookmarkRecord(id: UUID().uuidString, docID: docID, page: page, name: name, createdAt: Date())
        _ = try? db.run("INSERT INTO bookmarks(id, doc_id, page, name, created_at) VALUES(?,?,?,?,?)", [b.id, docID, page, name, b.createdAt])
        _ = try? db.run("INSERT INTO fts_user(body, scope, doc_id, page, ref_id) VALUES(?,?,?,?,?)",
                        [TextNormalizer.indexForm(name), "bookmark", docID, page, b.id])
        return b
    }
    func renameBookmark(_ id: String, name: String) {
        _ = try? db.run("UPDATE bookmarks SET name = ? WHERE id = ?", [name, id])
        _ = try? db.run("UPDATE fts_user SET body = ? WHERE scope = 'bookmark' AND ref_id = ?", [TextNormalizer.indexForm(name), id])
    }
    func deleteBookmark(_ id: String) {
        _ = try? db.run("DELETE FROM bookmarks WHERE id = ?", [id])
        _ = try? db.run("DELETE FROM fts_user WHERE scope = 'bookmark' AND ref_id = ?", [id])
    }
    func bookmarks(docID: String?) -> [BookmarkRecord] {
        let sql = "SELECT id, doc_id, page, name, created_at FROM bookmarks" + (docID == nil ? "" : " WHERE doc_id = ?") + " ORDER BY page, created_at"
        return (try? db.query(sql, docID.map { [$0] } ?? []) {
            BookmarkRecord(id: $0.string(0), docID: $0.string(1), page: $0.int(2), name: $0.string(3), createdAt: $0.date(4) ?? Date())
        }) ?? []
    }

    // MARK: Page notes

    func pageNote(docID: String, page: Int) -> PageNote? {
        (try? db.query("SELECT doc_id, page, text, updated_at FROM page_notes WHERE doc_id = ? AND page = ?", [docID, page]) {
            PageNote(docID: $0.string(0), page: $0.int(1), text: $0.string(2), updatedAt: $0.date(3) ?? Date())
        })?.first
    }
    func pageNotes(docID: String) -> [PageNote] {
        (try? db.query("SELECT doc_id, page, text, updated_at FROM page_notes WHERE doc_id = ? ORDER BY page", [docID]) {
            PageNote(docID: $0.string(0), page: $0.int(1), text: $0.string(2), updatedAt: $0.date(3) ?? Date())
        }) ?? []
    }
    func savePageNote(docID: String, page: Int, text: String) {
        let refID = "\(docID):\(page)"
        try? db.transaction {
            try db.run("DELETE FROM fts_user WHERE scope = 'note' AND ref_id = ?", [refID])
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try db.run("DELETE FROM page_notes WHERE doc_id = ? AND page = ?", [docID, page])
            } else {
                try db.run("""
                    INSERT INTO page_notes(doc_id, page, text, updated_at) VALUES(?,?,?,?)
                    ON CONFLICT(doc_id, page) DO UPDATE SET text = excluded.text, updated_at = excluded.updated_at
                    """, [docID, page, text, Date()])
                try db.run("INSERT INTO fts_user(body, scope, doc_id, page, ref_id) VALUES(?,?,?,?,?)",
                           [TextNormalizer.indexForm(text), "note", docID, page, refID])
            }
        }
    }

    // MARK: Vocabulary

    private func mapVocab(_ r: Row) -> VocabularyEntry {
        VocabularyEntry(id: r.string(0), docID: r.optString(1), page: r.optInt(2), word: r.string(3), translation: r.string(4),
                        example: r.string(5), explanation: r.string(6),
                        partOfSpeech: PartOfSpeech(rawValue: r.string(7)) ?? .none,
                        article: GermanArticle(rawValue: r.string(8)) ?? .none,
                        plural: r.string(9), notes: r.string(10), needsReview: r.bool(11),
                        createdAt: r.date(12) ?? Date(), updatedAt: r.date(13) ?? Date())
    }
    private static let vocabColumns = "id, doc_id, page, word, translation, example, explanation, pos, article, plural, notes, needs_review, created_at, updated_at"

    func saveVocabulary(_ v: VocabularyEntry) {
        var e = v; e.updatedAt = Date()
        try? db.transaction {
            try db.run("""
                INSERT INTO vocabulary(\(Store.vocabColumns)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET doc_id=excluded.doc_id, page=excluded.page, word=excluded.word,
                  translation=excluded.translation, example=excluded.example, explanation=excluded.explanation,
                  pos=excluded.pos, article=excluded.article, plural=excluded.plural, notes=excluded.notes,
                  needs_review=excluded.needs_review, updated_at=excluded.updated_at
                """, [e.id, e.docID, e.page, e.word, e.translation, e.example, e.explanation, e.partOfSpeech.rawValue,
                      e.article.rawValue, e.plural, e.notes, e.needsReview, e.createdAt, e.updatedAt])
            try db.run("DELETE FROM fts_user WHERE scope = 'vocab' AND ref_id = ?", [e.id])
            let body = [e.word, e.translation, e.example, e.explanation, e.plural, e.notes].joined(separator: " ")
            try db.run("INSERT INTO fts_user(body, scope, doc_id, page, ref_id) VALUES(?,?,?,?,?)",
                       [TextNormalizer.indexForm(body), "vocab", e.docID ?? "", e.page ?? 0, e.id])
        }
    }
    func deleteVocabulary(_ id: String) {
        _ = try? db.run("DELETE FROM vocabulary WHERE id = ?", [id])
        _ = try? db.run("DELETE FROM fts_user WHERE scope = 'vocab' AND ref_id = ?", [id])
    }
    func vocabulary(docID: String? = nil) -> [VocabularyEntry] {
        let sql = "SELECT \(Store.vocabColumns) FROM vocabulary" + (docID == nil ? "" : " WHERE doc_id = ?") + " ORDER BY created_at DESC"
        return (try? db.query(sql, docID.map { [$0] } ?? [], mapVocab)) ?? []
    }

    // MARK: Text styles

    func textStyles() -> [TextStylePreset] {
        let rows = (try? db.query("SELECT json FROM text_styles ORDER BY sort, name COLLATE NOCASE", []) { $0.string(0) }) ?? []
        let styles = rows.compactMap { $0.data(using: .utf8).flatMap { try? dec.decode(TextStylePreset.self, from: $0) } }
        if styles.isEmpty && value(for: "styles_seeded") == nil {
            let defaults = TextStylePreset.defaults()
            defaults.forEach { saveTextStyle($0) }
            setValue("1", for: "styles_seeded")
            return defaults
        }
        return styles
    }
    func saveTextStyle(_ s: TextStylePreset) {
        guard let data = try? enc.encode(s) else { return }
        _ = try? db.run("""
            INSERT INTO text_styles(id, name, json, sort) VALUES(?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, json = excluded.json, sort = excluded.sort
            """, [s.id, s.name, String(decoding: data, as: UTF8.self), s.sort])
    }
    func deleteTextStyle(_ id: String) { _ = try? db.run("DELETE FROM text_styles WHERE id = ?", [id]) }

    // MARK: Search

    private func titles() -> [String: String] {
        Dictionary(uniqueKeysWithValues: ((try? db.query("SELECT id, title FROM documents", []) { ($0.string(0), $0.string(1)) }) ?? []))
    }

    /// Searches annotations, page notes, bookmarks and vocabulary.
    func searchUser(_ query: String, docID: String? = nil, limit: Int = 200) -> [SearchHit] {
        guard let q = TextNormalizer.ftsQuery(query) else { return [] }
        let titles = titles()
        var sql = "SELECT scope, doc_id, page, ref_id, snippet(fts_user, 0, '⟦', '⟧', '…', 14) FROM fts_user WHERE fts_user MATCH ?"
        var params: [any SQLConvertible] = [q]
        if let d = docID { sql += " AND doc_id = ?"; params.append(d) }
        sql += " ORDER BY rank LIMIT ?"; params.append(limit)
        return (try? db.query(sql, params) { r in
            SearchHit(scope: SearchScope(rawValue: r.string(0)) ?? .annotation, docID: r.string(1),
                      docTitle: titles[r.string(1)] ?? "", page: r.int(2), snippet: r.string(4), refID: r.optString(3))
        }) ?? []
    }

    func indexPDFPages(docID: String, pages: [(Int, String)]) throws {
        try db.transaction {
            for (page, text) in pages where !text.isEmpty {
                try db.run("INSERT INTO fts_pdf(body, doc_id, page, scope) VALUES(?,?,?,?)",
                           [TextNormalizer.indexForm(text), docID, page, "pdf"])
            }
        }
    }
    func clearPDFIndex(docID: String) { _ = try? db.run("DELETE FROM fts_pdf WHERE doc_id = ?", [docID]) }

    func searchPDF(_ query: String, docID: String? = nil, limit: Int = 200) -> [SearchHit] {
        guard let q = TextNormalizer.ftsQuery(query) else { return [] }
        let titles = titles()
        var sql = "SELECT doc_id, page, snippet(fts_pdf, 0, '⟦', '⟧', '…', 16) FROM fts_pdf WHERE fts_pdf MATCH ?"
        var params: [any SQLConvertible] = [q]
        if let d = docID { sql += " AND doc_id = ?"; params.append(d) }
        sql += " ORDER BY rank LIMIT ?"; params.append(limit)
        return (try? db.query(sql, params) { r in
            SearchHit(scope: .pdf, docID: r.string(0), docTitle: titles[r.string(0)] ?? "", page: r.int(1), snippet: r.string(2), refID: nil)
        }) ?? []
    }
}
