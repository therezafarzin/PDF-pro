import Foundation

/// Database schema. The SQL between the BEGIN/END markers is extracted and executed by
/// `scripts/verify_schema.py`, so schema + queries are verified against a real SQLite in CI
/// even on machines without Swift.
enum Schema {
    static let currentVersion = 1

    // BEGIN-SQL-V1
    static let v1 = """
    CREATE TABLE IF NOT EXISTS documents (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        path TEXT NOT NULL,
        bookmark BLOB,
        page_count INTEGER NOT NULL DEFAULT 0,
        file_size INTEGER NOT NULL DEFAULT 0,
        added_at REAL NOT NULL,
        last_opened_at REAL,
        file_modified_at REAL,
        favorite INTEGER NOT NULL DEFAULT 0,
        pinned INTEGER NOT NULL DEFAULT 0,
        open_count INTEGER NOT NULL DEFAULT 0,
        indexed_at REAL
    );
    CREATE INDEX IF NOT EXISTS idx_documents_path ON documents(path);
    CREATE TABLE IF NOT EXISTS doc_tags (
        doc_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE ON UPDATE CASCADE,
        tag TEXT NOT NULL,
        PRIMARY KEY (doc_id, tag)
    );
    CREATE TABLE IF NOT EXISTS collections (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        parent_id TEXT REFERENCES collections(id) ON DELETE CASCADE,
        icon TEXT NOT NULL DEFAULT 'books.vertical',
        sort INTEGER NOT NULL DEFAULT 0,
        created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS collection_docs (
        collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
        doc_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE ON UPDATE CASCADE,
        PRIMARY KEY (collection_id, doc_id)
    );
    CREATE TABLE IF NOT EXISTS reading_positions (
        doc_id TEXT PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE ON UPDATE CASCADE,
        json TEXT NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS pages_read (
        doc_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE ON UPDATE CASCADE,
        page INTEGER NOT NULL,
        first_read REAL NOT NULL,
        PRIMARY KEY (doc_id, page)
    );
    CREATE TABLE IF NOT EXISTS page_visits (
        doc_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE ON UPDATE CASCADE,
        page INTEGER NOT NULL,
        last_visit REAL NOT NULL,
        visits INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (doc_id, page)
    );
    CREATE TABLE IF NOT EXISTS annotations (
        id TEXT PRIMARY KEY,
        doc_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE ON UPDATE CASCADE,
        page INTEGER NOT NULL,
        kind TEXT NOT NULL,
        z INTEGER NOT NULL DEFAULT 0,
        json TEXT NOT NULL,
        modified_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_annotations_doc ON annotations(doc_id, page);
    CREATE TABLE IF NOT EXISTS snapshots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        doc_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE ON UPDATE CASCADE,
        created_at REAL NOT NULL,
        label TEXT NOT NULL,
        count INTEGER NOT NULL,
        json TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS bookmarks (
        id TEXT PRIMARY KEY,
        doc_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE ON UPDATE CASCADE,
        page INTEGER NOT NULL,
        name TEXT NOT NULL,
        created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS page_notes (
        doc_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE ON UPDATE CASCADE,
        page INTEGER NOT NULL,
        text TEXT NOT NULL,
        updated_at REAL NOT NULL,
        PRIMARY KEY (doc_id, page)
    );
    CREATE TABLE IF NOT EXISTS vocabulary (
        id TEXT PRIMARY KEY,
        doc_id TEXT REFERENCES documents(id) ON DELETE SET NULL ON UPDATE CASCADE,
        page INTEGER,
        word TEXT NOT NULL,
        translation TEXT NOT NULL DEFAULT '',
        example TEXT NOT NULL DEFAULT '',
        explanation TEXT NOT NULL DEFAULT '',
        pos TEXT NOT NULL DEFAULT 'none',
        article TEXT NOT NULL DEFAULT '',
        plural TEXT NOT NULL DEFAULT '',
        notes TEXT NOT NULL DEFAULT '',
        needs_review INTEGER NOT NULL DEFAULT 0,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS text_styles (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        json TEXT NOT NULL,
        sort INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS kv (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS fts_user USING fts5(
        body, scope UNINDEXED, doc_id UNINDEXED, page UNINDEXED, ref_id UNINDEXED,
        tokenize = 'unicode61 remove_diacritics 2'
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS fts_pdf USING fts5(
        body, doc_id UNINDEXED, page UNINDEXED, scope UNINDEXED,
        tokenize = 'unicode61 remove_diacritics 2'
    );
    """
    // END-SQL-V1

    static func migrate(_ db: SQLiteDB) throws {
        let version = try db.query("PRAGMA user_version", []) { $0.int(0) }.first ?? 0
        if version < 1 {
            try db.transaction {
                try db.exec(v1)
                try db.exec("PRAGMA user_version = 1")
            }
        }
    }
}
