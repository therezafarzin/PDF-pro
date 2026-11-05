#!/usr/bin/env python3
"""Runs the exact SQL embedded in Sources/Core/Schema.swift against a real SQLite and exercises
the queries used by Store.swift (FTS5 German/Persian search, upserts, cascades, recursive CTE).
This verifies the *database design*; it does not execute the Swift code."""
import re, sqlite3, sys, unicodedata, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "Sources/Core/Schema.swift").read_text()
m = re.search(r'// BEGIN-SQL-V1\s+static let v1 = """\n(.*?)\n\s*"""\s+// END-SQL-V1', src, re.S)
assert m, "schema markers not found"
sql = m.group(1)

db = sqlite3.connect(":memory:")
db.execute("PRAGMA foreign_keys=ON")
db.executescript(sql)
print("schema OK, sqlite", sqlite3.sqlite_version)

# ---- Python mirror of TextNormalizer.indexForm / ftsQuery (mirrors Swift logic) ----
def index_form(s):
    s = unicodedata.normalize("NFKC", s)
    out = []
    for ch in s:
        v = ord(ch)
        if v == 0x0643: out.append("\u06A9")
        elif v in (0x064A, 0x0649): out.append("\u06CC")
        elif v == 0x06C0: out.append("\u0647")
        elif v == 0x0640: continue
        elif 0x064B <= v <= 0x065F or v == 0x0670: continue
        elif v == 0x200C: out.append(" ")
        elif v == 0x200D: continue
        elif v in (0x200E,0x200F,0x202A,0x202B,0x202C,0x202D,0x202E,0x2066,0x2067,0x2068,0x2069,0x061C): continue
        elif v == 0xDF: out.append("ss")
        elif v == 0x1E9E: out.append("SS")
        elif 0x06F0 <= v <= 0x06F9: out.append(chr(48 + v - 0x06F0))
        elif 0x0660 <= v <= 0x0669: out.append(chr(48 + v - 0x0660))
        else: out.append(ch)
    return "".join(out)

def tokens(s):
    toks, cur = [], ""
    for ch in index_form(s):
        if ch.isalnum() or unicodedata.category(ch).startswith("M"): cur += ch
        elif cur: toks.append(cur); cur = ""
    if cur: toks.append(cur)
    return toks

def fts_query(s):
    t = [x.replace('"', "") for x in tokens(s)]
    if not t: return None
    parts = [f'"{x}"' for x in t]; parts[-1] += " *"
    return " ".join(parts)

fails = 0
def check(name, cond):
    global fails
    print(("PASS " if cond else "FAIL ") + name)
    if not cond: fails += 1

# ---- documents / upsert / cascade / rekey ----
db.execute("INSERT INTO documents(id,title,path,added_at) VALUES('A','Buch','/x/a.pdf',1)")
db.execute("""INSERT INTO documents(id,title,path,added_at) VALUES('A','Neu','/x/a.pdf',1)
              ON CONFLICT(id) DO UPDATE SET title=excluded.title""")
check("upsert updates title", db.execute("SELECT title FROM documents WHERE id='A'").fetchone()[0] == "Neu")
db.execute("INSERT INTO reading_positions VALUES('A','{\"pageIndex\":49}',1)")
db.execute("INSERT INTO annotations VALUES('u1','A',3,'textBox',0,'{}',1)")
db.execute("UPDATE documents SET id='B' WHERE id='A'")  # rekey: ON UPDATE CASCADE
check("rekey cascades to positions", db.execute("SELECT doc_id FROM reading_positions").fetchone()[0] == "B")
check("rekey cascades to annotations", db.execute("SELECT doc_id FROM annotations").fetchone()[0] == "B")
db.execute("DELETE FROM documents WHERE id='B'")
check("delete cascades", db.execute("SELECT COUNT(*) FROM annotations").fetchone()[0] == 0)

# ---- recursive collection query ----
db.execute("INSERT INTO documents(id,title,path,added_at) VALUES('D1','Grammatik','/g.pdf',1)")
db.executemany("INSERT INTO collections(id,name,parent_id,created_at) VALUES(?,?,?,1)",
               [("c1","German",None),("c2","B1","c1"),("c3","B2","c1")])
db.execute("INSERT INTO collection_docs VALUES('c2','D1')")
rows = db.execute("""WITH RECURSIVE tree(id) AS (SELECT id FROM collections WHERE id = ?
    UNION ALL SELECT c.id FROM collections c JOIN tree t ON c.parent_id = t.id)
    SELECT DISTINCT doc_id FROM collection_docs WHERE collection_id IN (SELECT id FROM tree)""", ("c1",)).fetchall()
check("collection tree includes sub-collections", rows == [("D1",)])

# ---- FTS: German + Persian ----
def add_pdf(page, text): db.execute("INSERT INTO fts_pdf(body,doc_id,page,scope) VALUES(?,?,?,'pdf')", (index_form(text), "D1", page))
def search_pdf(q):
    fq = fts_query(q)
    return [r[0] for r in db.execute("SELECT page FROM fts_pdf WHERE fts_pdf MATCH ? ORDER BY rank", (fq,))] if fq else []

add_pdf(1, "Die Umweltverschmutzung ist ein großes Problem.")
add_pdf(2, "Obwohl er krank war, ging er trotzdem zur Arbeit.")
add_pdf(3, "Die Straße ist lang. Müller wohnt in Köln.")
add_pdf(4, "Die Umweltverschmutzung یعنی آلودگی محیط زیست و می‌شود")
add_pdf(5, "امتحان در تاریخ ۱۵ مارس برگزار می‌شود")
add_pdf(6, "كتاب جديد")  # Arabic kaf/yeh variants

check("German exact word", search_pdf("Umweltverschmutzung") == [1, 4])
check("German prefix", search_pdf("Umweltvers") == [1, 4])
check("German case-insensitive", search_pdf("OBWOHL") == [2])
check("ß matches ss", search_pdf("Strasse") == [3])
check("ss query matches ß", search_pdf("Straße") == [3])
check("umlaut folded (Muller -> Müller)", search_pdf("Muller") == [3])
check("umlaut kept (Müller)", search_pdf("Müller") == [3])
check("multi-word AND", search_pdf("er krank") == [2])
check("Persian word", search_pdf("آلودگی") == [4])
check("Persian ZWNJ word matches either form", search_pdf("می‌شود") == [4, 5] or search_pdf("می‌شود") == [5, 4])
check("Persian digits == western digits", search_pdf("15") == [5])
check("Persian digits query", search_pdf("۱۵") == [5])
check("Arabic kaf/yeh variants unify", search_pdf("کتاب") == [6] and search_pdf("جدید") == [6])
check("mixed query", search_pdf("Umweltverschmutzung یعنی") == [4])
check("empty query safe", search_pdf("   ") == [])
try:
    search_pdf('Arbeit" OR "x'); search_pdf('"'); search_pdf("a*b NEAR( ) -")
    check("malformed/quote-injection queries do not raise", True)
except Exception as e:
    check("malformed/quote-injection queries do not raise: %s" % e, False)

# ---- user FTS snippet / delete by ref ----
db.execute("INSERT INTO fts_user(body,scope,doc_id,page,ref_id) VALUES(?,?,?,?,?)",
           (index_form("Die gesellschaftliche Entwicklung یعنی توسعه اجتماعی"), "annotation", "D1", 49, "u9"))
r = db.execute("SELECT scope,page,ref_id,snippet(fts_user,0,'[',']','…',8) FROM fts_user WHERE fts_user MATCH ?",
               (fts_query("gesellschaftliche"),)).fetchall()
check("annotation search returns page + snippet", len(r) == 1 and r[0][1] == 49 and "[" in r[0][3])
db.execute("DELETE FROM fts_user WHERE scope='annotation' AND ref_id='u9'")
check("delete annotation index by ref", db.execute("SELECT COUNT(*) FROM fts_user").fetchone()[0] == 0)

# ---- backup via VACUUM INTO ----
import tempfile, os
d = tempfile.mkdtemp(); dest = os.path.join(d, "b.sqlite")
db.commit()
db.execute(f"VACUUM INTO '{dest}'")
b = sqlite3.connect(dest)
check("VACUUM INTO backup readable", b.execute("SELECT COUNT(*) FROM documents").fetchone()[0] == 1)
check("backup contains FTS data", b.execute("SELECT COUNT(*) FROM fts_pdf").fetchone()[0] == 6)

print("FAILURES:", fails); sys.exit(1 if fails else 0)
