# Feature checklist and verification status

Legend — **Implemented**: code written for it. **Verified here**: checked in the Linux sandbox by running real code
(SQLite/Python). **Unverified**: needs compiling/running on macOS; *nothing* in the Swift layer has been compiled.

## Verified here (executed)
* SQL schema (all tables, constraints, `ON UPDATE CASCADE` re-keying, recursive collection query) — `scripts/verify_schema.py`
* FTS5 search: German (umlauts, ß↔ss, prefix, AND), Persian (ZWNJ, Persian/Arabic digits, Arabic ي/ك variants), mixed queries, malformed-query safety
* `VACUUM INTO` backups are complete and readable
* Page-rotation math (0/90/180/270 + inverse) — `scripts/verify_geometry.py`
* Brace balance / declared types / project paths across all 31 Swift files — `scripts/static_check.py`

*Caveat:* the Python checks use a Python mirror of `TextNormalizer.indexForm` to validate the **design**; the Swift implementation itself has not been executed.

## Implemented, unverified on macOS (unit tests written: `Tests/`)
| Area | Status |
|---|---|
| PDF open/render, continuous/single/two-page/book, fit width/page, zoom presets, rotate, full screen, distraction-free, thumbnails (native `PDFThumbnailView`), outline/ToC, go-to-page | Implemented |
| Exact reading-position restore (page + top-left point + zoom + layout + sidebar + rotations + mode), per document, two-pass restore after layout, saved on scroll/zoom/page (debounced) and on quit | Implemented (Tests 1, 5) |
| Content-based document identity (size + 3×256 KB SHA-256), security-scoped bookmark + path fallback, "Locate…" for missing files, re-key when file bytes change | Implemented; fingerprint/store tests written |
| Tabs, session restore, crash detection + notice, periodic/launch/quit/manual backups, version snapshots + restore | Implemented |
| Library: recents, favorites, pinned, collections (nested), tags, sort, grid/list, progress, drag & drop, dashboard, async thumbnails | Implemented |
| Annotations: text box, sticky note (collapse/expand), highlight/underline/strike/squiggly, rectangle, ellipse, line, arrow, pen, pencil, eraser | Implemented |
| Annotation management: multi-select (⇧), move, resize handles, nudge, copy/cut/paste, duplicate, group/ungroup, lock, z-order, delete, undo/redo (all operations incl. text) | Implemented; controller tests written |
| Rich text: font family/size, bold/italic/underline/strike, color, alignment, line & paragraph spacing, bullet/numbered lists, per-paragraph direction, background, border, radius, padding, opacity, fit-to-text, find & replace | Implemented |
| **Bidirectional editing**: TextKit-1 `NSTextView`, `.natural` base direction (UBA first-strong), RTF persistence, identical `NSAttributedString.draw` for screen and export | Implemented; **must be verified by Test 2** |
| Reusable text styles (6 defaults: German Vocabulary, Persian Translation, Grammar Explanation, Important Note, Exam Tip, Example Sentence; editable) | Implemented |
| Study: vocabulary entries (article, plural, POS, translation, example, explanation, notes, review flag), study highlight categories with custom colors, bookmarks, page notes, pages-read progress, dashboard, Anki TSV + CSV export, notes Markdown export | Implemented; store/exporter tests written |
| Search: in-PDF (async, variants for ß/ss, Persian forms), in annotations/notes/vocab (FTS5), across all indexed documents (background indexer) | Implemented; FTS queries verified |
| Export: flattened PDF (best bilingual fidelity), standard-annotation PDF, page ranges, outline preserved, print (via flattened copy), embed into original (with backup) | Implemented; exporter tests written |
| Customizable shortcuts (recorder, conflict detection), menu commands, Settings, light/dark/auto, accent color, density, customizable toolbar | Implemented |
| Optional: Vision OCR of a page to search index (`OCRService`), German text-to-speech, reading ruler, night/sepia mode, floating text editor (used on rotated pages) | Implemented (OCR/ruler/night: see limits) |

## Quick Tools (added after the first release)
Layout like the reference screenshot: *Quick Tools* card (Dashboard + sidebar item) with layout toggle, "choose tools" popover and sort (default / name / most used); also in the **PDF Tools** menu.
| Tool | What it does | Status |
|---|---|---|
| Batch Convert | PDF → PNG / JPEG / TIFF (dpi, quality, optional burn-in of *my annotations*), → TXT / RTF / HTML (RTL-aware `dir="auto"`), optional OCR for pages without text, page selection per file, batch | Implemented, unverified |
| Combine Files | PDFs + images → one PDF, per-file page ranges, reorder, A4 fitting, bookmark per file keeping each file's own outline | Implemented, unverified |
| Batch Split | every N pages, one per page, start at pages, ranges (one file each), top-level bookmarks (named after the chapter); outline kept per part; own sub-folder, never overwrites | Implemented; planning logic verified (Python mirror) |
| Optimize PDF | lossless clean-up, balanced (JPEG recompression via PDFKit write options), strong (rasterize + JPEG, optional searchable OCR layer); result discarded if not smaller; original untouched | Implemented, unverified |
| OCR PDF | Vision text recognition → *invisible text layer* over the unchanged page (searchable/selectable), language choice, skip pages that already have text | Implemented, unverified |
| Edit Pages | page organiser: drag to reorder, rotate, delete, duplicate, blank page, insert pages from another PDF, undo/redo, saves a **copy** | Implemented; model logic verified (Python mirror) |
| Sign | draw a signature once, keep it, place it as grouped pen strokes (one undo step) | Implemented, unverified. A visual signature, **not** a certificate-based digital signature |

**Deliberately not added:** *PDF zusammenfassen* (AI summary) and *PDF übersetzen* (translation) — you asked for no AI features; *eSign anfordern* — needs a server/account (the offline *Sign* tool replaces it). Word/Excel/PowerPoint export is not offered (not possible reliably without a conversion service). "Edit PDF" cannot rewrite the original text/images of a PDF; use annotations or Edit Pages.
New APIs to watch on first build: `PDFDocumentWriteOption.saveImagesAsJPEGOption` / `.optimizeImagesForScreenOption`, `PDFPage.ImageInitializationOption`, `VNRecognizeTextRequest.automaticallyDetectsLanguage`.

## Not implemented (honest list)
* Side-by-side document comparison, automatic vocabulary extraction, annotation templates (text *styles* exist), custom page background images (only night/sepia/system).
* OCR does **not** create a selectable text layer for scanned PDFs; the OCR function is exposed in code (`OCRService`) but has no menu item yet.
* Eraser removes whole pen strokes/shapes, not partial segments; marquee (rubber-band) selection is not implemented (use ⇧-click or ⌥⌘A).
* Squiggly underline exports as a plain underline in *standard-annotation* mode (flattened export draws it exactly).
* Existing PDF annotations are preserved in exports, but PDF links/forms are not preserved in the *flattened* export.
* No iCloud sync, no App Sandbox build (entitlements file has the sandbox off for reliable in-place saving).

## Known risks to check first on your Mac
1. `PDFPageOverlayViewProvider` overlay sizing/scaling at high zoom and on rotated pages (canvas is built to tolerate both frame-scaling and layer-scaling).
2. Caret/selection behaviour of mixed Persian/German text inside the overlay at zoom ≠ 100 % (Test 2) — if the inline editor misbehaves when scaled, the floating editor (`FloatingTextEditor`) is a ready fallback.
3. `PDFView.menu(for:)` override being used for the context menu.
4. Position restore timing (0.12 s / 0.45 s passes) on very large PDFs — adjust in `ReaderSession.restorePosition()`.
5. `PDFPage.pageRef` + `annotation.draw` path in flattened export for unusual PDFs (encrypted/portfolio).

## Review log
**Second review pass (read-through, no compiler available).** Fixed: tuple-label mismatch in `Store.recentPages`; duplicated/pasted
grouped annotations re-joined the original group; the thumbnail sidebar could stay unbound because it is created before the PDF view;
flattened export could write a PDF over the file it had just read (outline copy); two wrong test expectations
(`ftsQuery` quote handling, `UndoManager` needs an open group when `groupsByEvent = false`).
Re-run after fixes: `verify_schema.py` (25/25), `verify_geometry.py`, `static_check.py` (0 failures); default shortcuts: 49 bindings, no conflicts;
`VACUUM INTO` preserves `user_version`.

**User-reported fixes (after first install on macOS).**
1. Text box / sticky note disappeared right after being placed: switching the tool back to *Select* ended editing and deleted the still-empty box. The tool is now switched *before* the box is created (`switchToSelect:`); regression test `testTextBoxSurvivesSwitchingBackToSelectTool`.
2. Highlights stacked on top of each other and were hard to remove. Marking already-marked text with the same tool now toggles it off (or recolors it if the category/color differs); the Eraser now also removes highlights/underlines; math covered by `testMarkupToggleMath`.
