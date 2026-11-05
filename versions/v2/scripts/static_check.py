#!/usr/bin/env python3
"""Static sanity checks for the Swift sources (no compiler available on the authoring machine):
 - balanced braces/brackets/parens per file (strings and comments skipped)
 - every type/protocol referenced in a curated list is declared somewhere
 - every method called on core types in a curated list is declared
 - project.yml references existing paths
This is NOT a substitute for compiling."""
import re, sys, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
files = sorted(root.glob("Sources/**/*.swift")) + sorted(root.glob("Tests/*.swift"))
fails = 0

def strip(src):
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            while i < n and src[i] != "\n": i += 1
        elif src.startswith("/*", i):
            j = src.find("*/", i); i = n if j < 0 else j + 2
        elif src.startswith('"""', i):
            j = src.find('"""', i + 3); i = n if j < 0 else j + 3; out.append('""')
        elif c == '"':
            i += 1
            depth = 0
            while i < n:
                if src[i] == "\\" and i + 1 < n and src[i+1] == "(":
                    depth += 1; i += 2; continue
                if src[i] == "\\": i += 2; continue
                if depth and src[i] == ")": depth -= 1; i += 1; continue
                if src[i] == '"' and not depth: i += 1; break
                i += 1
            out.append('""')
        else:
            out.append(c); i += 1
    return "".join(out)

all_src = ""
for f in files:
    raw = f.read_text(); s = strip(raw); all_src += s + "\n"
    for o, c in ("{}", "[]", "()"):
        if s.count(o) != s.count(c):
            print(f"FAIL balance {o}{c} in {f.relative_to(root)}: {s.count(o)} vs {s.count(c)}"); fails += 1

declared = set(re.findall(r"\b(?:class|struct|enum|protocol|actor|typealias)\s+([A-Z][A-Za-z0-9_]*)", all_src))
declared |= set(re.findall(r"extension\s+([A-Z][A-Za-z0-9_]*)", all_src))
used_custom = ["AnnotationController","AnnotationRenderer","AnnotationCanvasView","PageOverlayView","StudyPDFView","ReaderSession","RichText","TextOps",
 "PDFExporter","DocumentFingerprint","TextNormalizer","PageGeometry","GeometryMath","PageRangeParser","VocabularyExporter","NotesExporter","BackupManager",
 "Store","SQLiteDB","Schema","FileAccess","DocumentService","ThumbnailService","PDFTextIndexer","OCRService","Speaker","ShortcutManager","ShortcutRecorder",
 "InspectorView","SidebarView","SearchPanel","StatusBar","VocabularyEditor","ExportSheet","VersionsSheet","SettingsView","LibraryView","DashboardView",
 "TagEditor","CommitSlider","TextStyleEditor","FloatingTextEditor","ClosureMenuItem","LibraryModel","AppState","AppDelegate","Prompt","Theme","Density"]
for t in used_custom:
    if t not in declared: print("FAIL undeclared type:", t); fails += 1

# every `session.xyz(` / `controller.xyz(` / `store.xyz(` method used must exist
def methods_of(*names):
    m = set()
    for n in names: m |= set(re.findall(r"\bfunc\s+" + r"([A-Za-z_][A-Za-z0-9_]*)", all_src))
    return m
funcs = methods_of("x")
props = set(re.findall(r"\b(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)", all_src)) | set(re.findall(r"case\s+([a-z][A-Za-z0-9_]*)", all_src))
for recv in ("session", "controller", "store", "app", "lib", "ctl", "c", "s"):
    for name in sorted(set(re.findall(r"\b" + recv + r"\??\.([a-z][A-Za-z0-9_]*)\(", all_src))):
        if name not in funcs and name not in {"map","filter","sorted","append","first","contains","min","max","insert","remove","removeAll","formUnion","sink","store",
            "receive","reduce","prefix","dropFirst","joined","split","count","reversed","replacingOccurrences","trimmingCharacters","enumerated","compactMap","flatMap",
            "removeValue","allSatisfy","subtracting","firstIndex","index","lowercased","hasPrefix","hasSuffix","swapAt","toggle","sort","set","get","encode","decode",
            "value","string","int","data","date","bool","double","optString","isNull","int64","optInt","run","query","exec","transaction","backup","checkpoint","object",
            "addObserver","post","stroke","fill","insetBy","offsetBy","union","applying","contains","draw","write","copy","tiffRepresentation","representation"}:
            print(f"WARN {recv}.{name}( is not declared as a func in the project (may be a framework API)")

yml = (root / "project.yml").read_text()
for p in re.findall(r"path:\s*([A-Za-z0-9_/\.]+)", yml):
    if not (root / p).exists() and not p.endswith((".plist", ".entitlements")): print("FAIL missing path in project.yml:", p); fails += 1
print(f"checked {len(files)} Swift files; declared types: {len(declared)}; failures: {fails}")
sys.exit(1 if fails else 0)
