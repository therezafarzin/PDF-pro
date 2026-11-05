#!/usr/bin/env python3
"""Python mirror of the pure logic in Sources/Core/ToolsCore.swift (split planning, range parsing, file naming,
page-edit plan with undo, signature normalisation). The assertions are the same cases as in Tests/ToolsTests.swift.
Verifies the *design/semantics*; the Swift code itself is not executed here."""
import sys, uuid, re, copy
fails = 0
def check(name, cond):
    global fails
    print(("PASS " if cond else "FAIL ") + name)
    if not cond: fails += 1

# ---- SplitPlanner ----
def segments(starts, n):
    return [(s, (starts[i+1] if i+1 < len(starts) else n) - 1) for i, s in enumerate(starts)]
def plan(n, mode, arg=None):
    if n <= 0: return []
    if mode == "every":
        k = max(1, arg); return [(s, min(s+k-1, n-1)) for s in range(0, n, k)]
    if mode == "single": return [(i, i) for i in range(n)]
    if mode == "starting":
        starts = sorted(set(p-1 for p in arg if 0 < p-1 < n) | {0}); return segments(starts, n)
    if mode == "outline":
        starts = sorted(set(s for s in arg if 0 <= s < n) | {0}); return segments(starts, n)
    if mode == "ranges":
        out = []
        for lo, hi in arg:
            lo2, hi2 = max(lo, 0), min(hi, n-1)
            if lo2 <= hi2: out.append((lo2, hi2))
        return out
def parse_groups(text, n):
    text = text.replace("–", "-").replace("،", ",")
    res = []
    for part in re.split(r"[,;]", text):
        s = part.strip()
        if not s: continue
        b = [x.strip() for x in s.split("-")]
        if len(b) == 1 and b[0].isdigit() and 1 <= int(b[0]) <= max(n, 1): res.append((int(b[0])-1, int(b[0])-1))
        elif len(b) == 2 and b[0].isdigit() and b[1].isdigit() and 1 <= int(b[0]) <= int(b[1]) <= n: res.append((int(b[0])-1, int(b[1])-1))
        else: return None
    return res or None

check("every 2 of 5", plan(5, "every", 2) == [(0,1),(2,3),(4,4)])
check("every 10 of 5 -> one part", plan(5, "every", 10) == [(0,4)])
check("every 0 behaves as 1", plan(3, "every", 0) == [(0,0),(1,1),(2,2)])
check("single pages", plan(3, "single") == [(0,0),(1,1),(2,2)])
check("starting at 3 and 5 of 7", plan(7, "starting", [3, 5]) == [(0,1),(2,3),(4,6)])
check("starting at ignores 1, dupes, out of range", plan(7, "starting", [1, 3, 3, 99, 0]) == [(0,1),(2,6)])
check("outline starts incl. implicit page 0", plan(10, "outline", [4, 7]) == [(0,3),(4,6),(7,9)])
check("outline starts duplicates", plan(10, "outline", [0, 4, 4]) == [(0,3),(4,9)])
check("ranges clamp + drop invalid", plan(10, "ranges", [(2,4),(8,20),(30,40)]) == [(2,4),(8,9)])
check("empty doc", plan(0, "every", 3) == [])
check("parse groups keeps items separate", parse_groups("1-5, 8, 10-12", 12) == [(0,4),(7,7),(9,11)])
check("parse groups persian comma + en dash", parse_groups("1–2،4", 5) == [(0,1),(3,3)])
check("parse groups rejects bad", parse_groups("0", 5) is None and parse_groups("4-2", 5) is None and parse_groups("1-9", 5) is None and parse_groups("x", 5) is None)

# ---- FileNaming ----
def sanitize(s):
    bad = set('/\\:?*"<>|')
    out = "".join("-" if (c in bad or ord(c) < 32) else c for c in s).strip().strip(".")
    return (out[:120] if len(out) > 120 else out) or "Untitled"
def label(lo, hi, n):
    w = max(len(str(n)), 1); p = lambda v: str(v+1).zfill(w)
    return f"page {p(lo)}" if lo == hi else f"pages {p(lo)}-{p(hi)}"
check("sanitize slashes/colons", sanitize("A/B:C?") == "A-B-C-")
check("sanitize empty", sanitize("  ..  ") == "Untitled")
check("sanitize persian untouched", sanitize("کتاب آلمانی") == "کتاب آلمانی")
check("range label padding", label(0, 9, 250) == "pages 001-010" and label(6, 6, 99) == "page 07" and label(0, 0, 5) == "page 1")

# ---- PageEditPlan ----
class Item:
    def __init__(s, source, page, rot=0, blank=None): s.id = uuid.uuid4(); s.source = source; s.page = page; s.rot = rot; s.blank = blank
    def key(s): return (s.source, s.page, s.rot, s.blank)
class Plan:
    def __init__(s, n): s.items = [Item(0, i) for i in range(n)]; s.orig = [i.key() for i in s.items]; s.u = []; s.r = []
    def keys(s): return [i.key() for i in s.items]
    def push(s): s.u.append([copy.copy(i) for i in s.items]); s.r.clear()
    def undo(s):
        if s.u: s.r.append(s.items); s.items = s.u.pop()
    def redo(s):
        if s.r: s.u.append(s.items); s.items = s.r.pop()
    def rotate(s, ids, d):
        if not ids: return
        s.push(); s.items = [copy.copy(i) for i in s.items]
        for i in s.items:
            if i.id in ids: i.rot = ((i.rot + d) % 360 + 360) % 360
    def delete(s, ids):
        if not ids or not any(i.id not in ids for i in s.items): return False
        s.push(); s.items = [i for i in s.items if i.id not in ids]; return True
    def duplicate(s, ids):
        if not ids: return
        s.push(); out = []
        for i in s.items:
            out.append(i)
            if i.id in ids: c = copy.copy(i); c.id = uuid.uuid4(); out.append(c)
        s.items = out
    def idx_after(s, id_):
        if id_ is None: return len(s.items)
        for n, i in enumerate(s.items):
            if i.id == id_: return n + 1
        return len(s.items)
    def insert_blank(s, after, size): s.push(); s.items.insert(s.idx_after(after), Item(0, 0, 0, size))
    def insert_pages(s, source, pages, after):
        if not pages: return
        s.push(); at = s.idx_after(after)
        s.items[at:at] = [Item(source, p) for p in pages]
    def move(s, ids, dest):
        moving = [i for i in s.items if i.id in ids]
        if not moving: return
        s.push(); dest = max(0, min(dest, len(s.items)))
        before = len([i for i in s.items[:dest] if i.id not in ids])
        rest = [i for i in s.items if i.id not in ids]
        rest[min(before, len(rest)):min(before, len(rest))] = moving; s.items = rest
    def pages(s): return [(i.source, i.page) for i in s.items]

p = Plan(6); ids = [i.id for i in p.items]
check("fresh plan not modified", p.keys() == p.orig)
p.rotate({ids[1]}, 90); check("rotate", p.items[1].rot == 90 and p.items[0].rot == 0)
p.rotate({ids[1]}, -180); check("rotate wraps to 270", p.items[1].rot == 270)
p.undo(); p.undo(); check("undo twice restores", p.keys() == p.orig)
p.redo(); check("redo", p.items[1].rot == 90)
p = Plan(5); ids = [i.id for i in p.items]
check("delete keeps others", p.delete({ids[1], ids[3]}) and [i.page for i in p.items] == [0, 2, 4])
p.undo(); check("undo delete", [i.page for i in p.items] == [0,1,2,3,4])
check("cannot delete all pages", p.delete(set(ids)) is False and len(p.items) == 5)
p.duplicate({ids[0], ids[4]}); check("duplicate after each", [i.page for i in p.items] == [0,0,1,2,3,4,4] and len({i.id for i in p.items}) == 7)
p = Plan(6); ids = [i.id for i in p.items]
p.move({ids[4], ids[5]}, 1); check("move block to front-ish", [i.page for i in p.items] == [0,4,5,1,2,3])
p = Plan(6); ids = [i.id for i in p.items]
p.move({ids[0]}, 4); check("move down: lands before original index 4", [i.page for i in p.items] == [1,2,3,0,4,5])
p = Plan(4); ids = [i.id for i in p.items]
p.move({ids[1]}, 99); check("move to end", [i.page for i in p.items] == [0,2,3,1])
p.move({ids[3]}, 0); check("move to start", [i.page for i in p.items][:2] == [3, 0])
p = Plan(3); ids = [i.id for i in p.items]
p.insert_blank(ids[0], (595, 842)); check("insert blank after first", p.items[1].blank == (595, 842) and len(p.items) == 4)
p.insert_pages(1, [0, 1], None); check("append pages from another source", p.pages()[-2:] == [(1,0),(1,1)])
p.insert_pages(1, [5], ids[2]); check("insert after given id", p.pages() == [(0,0),(0,0),(0,1),(0,2),(1,5),(1,0),(1,1)])
check("modified flag", p.keys() != p.orig)

# ---- Signature normalisation ----
def norm(strokes):
    pts = [q for s in strokes for q in s]
    if len(pts) < 2: return None
    xs = [x for x, _ in pts]; ys = [y for _, y in pts]
    minx, miny = min(xs), min(ys); w = max(max(xs)-minx, 1); h = max(max(ys)-miny, 1)
    return [[((x-minx)/w, (y-miny)/h) for x, y in s] for s in strokes], w/h
r = norm([[(10, 20), (110, 20)], [(60, 20), (60, 70)]])
check("normalise to unit box, aspect 2", r and r[1] == 2.0 and r[0][0][0] == (0.0, 0.0) and r[0][0][1] == (1.0, 0.0) and r[0][1][1] == (0.5, 1.0))
check("too few points -> None", norm([[(1, 1)]]) is None)

print("FAILURES:", fails); sys.exit(1 if fails else 0)
