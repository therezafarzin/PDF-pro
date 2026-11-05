# PDF Study — a native macOS PDF editor for studying German textbooks

Swift · SwiftUI · AppKit · PDFKit · TextKit · SQLite (WAL + FTS5) · Core Graphics · Vision (optional OCR).
No third-party dependencies, no network access, no accounts, no telemetry, no AI features.

> **Read this first — verification status.** This project was written in a Linux sandbox that has no Swift
> compiler, no Xcode and no macOS. **The app has never been compiled or run.** Expect a small number of compiler
> errors on the first build (typos, API signature details). What *was* verified here is listed in
> `FEATURES.md` ("Verified" vs "Unverified"). Please do not treat any macOS behaviour as tested until you
> have run the acceptance tests below on your Mac.

## Requirements
* Apple Silicon Mac (built for `arm64`), macOS 14 Sonoma or newer
* Xcode 16 or newer (App Store)
* [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — generates the `.xcodeproj` from `project.yml`

## Build and install
```bash
unzip PDFStudy.zip && cd PDFStudy
scripts/build.sh release       # generates the project, builds, copies "PDF Study.app" to dist/
scripts/make_dmg.sh            # optional: dist/PDF-Study.dmg
cp -R "dist/PDF Study.app" /Applications/
```
First launch: right-click the app → **Open** (ad-hoc signed, not notarized). 

Other commands: `scripts/build.sh run` (debug build and launch) · `scripts/build.sh test` (unit tests) ·
or `xcodegen generate && open PDFStudy.xcodeproj` and press ⌘R in Xcode.

If Xcode reports compile errors, send me the messages (or fix the one-liners); the code is organised so that each
error is local to one file. The project uses Swift language mode 5 with minimal concurrency checking on purpose
(strict Swift 6 checking could not be validated); the toolchain can be Swift 6.

## Checks you can run without a Mac
```bash
python3 scripts/verify_schema.py     # runs the real SQL schema + FTS5 German/Persian queries on SQLite (25 checks)
python3 scripts/verify_geometry.py   # independent check of the page-rotation math
python3 scripts/static_check.py      # brace balance, declared types, project paths
```

## Acceptance tests (run these on your Mac)
| # | Test | How |
|---|------|-----|
| 1 | Reopen at page 50 | Open a PDF, go to page 50, set 135 %, quit with ⌘Q, relaunch → same page/zoom/position (tabs are restored automatically). |
| 2 | Bilingual text box | Tool ⌘⇧T, click a page, type `Die gesellschaftliche Entwicklung یعنی توسعه اجتماعی و یکی از مهم‌ترین عوامل تغییر در جوامع مدرن است.` → check caret movement, selection, ZWNJ in «مهم‌ترین», editing in the middle of the text. |
| 3 | Several boxes | Create/move/resize/recolor several, close tab, reopen from Library. |
| 4 | Export | Highlight a German sentence (⌘⇧H), add a Persian box, **File ▸ Export PDF…** (Flattened), open in Preview. |
| 5 | Tabs | Open 3 PDFs, scroll each to different pages, switch tabs, quit and relaunch. |
| 6 | Large PDF | Open a 500+ page textbook, scroll rapidly, watch the thumbnails and search. |
| 7 | Crash safety | Edit a text box, immediately `kill -9 "PDF Study"` from Terminal, relaunch. Annotations are written within 0.4 s of typing and on every other change. |

## Using the app
* **Library** tab: dashboard, collections (nestable folders), tags, favorites, pinned, sort, full-text search over all indexed PDFs, drag & drop PDFs onto the window.
* **Reader**: sidebar (thumbnails, contents, bookmarks, annotations with find & replace, page note, vocabulary), inspector (⌥⌘I), toolbar (right-click ▸ *Customize Toolbar…*).
* **Highlight / underline / strike / squiggly**: pick the tool, select text. Right-click a selection for *Highlight as ▸ Vocabulary/Grammar/…*, *Expand to Sentence*, *Add to Vocabulary*, *Speak*.
* **Text boxes**: ⌘⇧T, click or drag; double-click to edit; Esc to finish. Paragraph direction (Auto/LTR/RTL) is in the inspector; reusable **Text Styles** are applied with one click.
* **Select annotations**: click; ⇧-click adds; ⌘-click selects a highlight; ⌥⌘A selects all on the page; arrows nudge.
* **Settings** (⌘,): appearance, accent color, density, shortcuts (every action is re-bindable), backups.

## Where your data lives
`~/Library/Application Support/PDF Study/` → `library.sqlite` (everything), `Backups/` (rotating full copies), `Thumbnails/`, `Original PDF Backups/` (made before any in-place embedding).
Your PDFs are **never modified** unless you choose *Version History ▸ Embed Annotations in Original PDF…* (a copy is stored first).

See `FEATURES.md` for the full checklist and `docs/ARCHITECTURE.md` for design decisions and known risks.
