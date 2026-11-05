# Architecture

```
Sources/
  Core/   platform-neutral logic (Foundation/SQLite/CryptoKit only): models, geometry, text normalization,
          fingerprint, SQLite wrapper, schema, Store, backups, exporters
  PDF/    AppKit/PDFKit: renderer, annotation controller, overlay canvas, PDFView subclass, exporter,
          services (file access, thumbnails, indexer, OCR, speech), per-document ReaderSession, rich-text engine
  UI/     SwiftUI: app entry + commands, theme, library, reader chrome, sidebars, inspector, vocabulary, settings
Tests/    XCTest (Core + AppKit pipeline)
```

## Key decisions (and trade-offs)
1. **Application-managed annotation layer** (SQLite, JSON per annotation, geometry in PDF page space) instead of writing
   `PDFAnnotation`s into the file. Reason: PDFKit FreeText cannot hold rich mixed-direction text reliably; original PDFs stay
   untouched; undo/redo, search and styles are simple. Trade-off: other apps don't see annotations until you export.
   *Export modes:* **Flattened** (drawn with the same code as the screen → identical bilingual layout in Preview),
   **Standard annotations** (editable elsewhere; rich text degraded to plain FreeText), **Embed in original** (with backup).
2. **Text engine**: TextKit-1 `NSTextView` for editing (Core Text shaping, UBA bidi, caret/selection, ZWNJ), paragraph
   `baseWritingDirection = .natural` by default (not alignment tricks), RTF persistence, and `NSAttributedString.draw(with:)`
   for display/export so edit view == output.
3. **Overlays**: `PDFPageOverlayViewProvider` gives one overlay per visible page; PDFKit handles zoom/scroll/layout. Inside, a canvas whose
   `bounds` are in unscaled page points does all drawing/hit-testing; `PageGeometry` handles page rotation. Hit-testing passes
   clicks through to PDFKit unless a tool or an annotation needs them, so text selection keeps working.
4. **Identity**: SHA-256 of size + head/middle/tail samples; bookmarks + path as locators; `rekeyDocument` migrates all data if the bytes change.
5. **Durability**: every mutation is a SQLite WAL transaction; text edits persist after ≤0.4 s; clean-exit flag detects crashes;
   rotating `VACUUM INTO` backups (launch, every N minutes, manual, quit); per-document snapshots (version history).
6. **Search**: FTS5 (`unicode61 remove_diacritics 2`) over text normalized by `TextNormalizer.indexForm`
   (ß→ss, Arabic/Persian letter + digit unification, ZWNJ→space, bidi marks removed); PDFKit find with spelling variants for the open document.
7. **No sandbox** by default (`project.yml`): in-place saving next to the original needs directory access. Security-scoped
   bookmarks are still created/resolved so a sandboxed build only needs the entitlement flipped.
8. **Swift language mode 5**, minimal concurrency checking: validated strict-concurrency code was impossible without a compiler.
