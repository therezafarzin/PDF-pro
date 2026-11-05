# PDF Study

A native macOS app for studying PDF textbooks. Highlight and annotate, write
bilingual text boxes (German + Persian, with correct RTL/LTR handling), build a
vocabulary list, and search your whole library with full-text search.

**Version 2** adds *Quick Tools*: batch convert, combine, split, optimize, OCR,
a page editor and signatures.

- Swift · SwiftUI · AppKit · PDFKit · SQLite (FTS5) · Vision (optional OCR)
- No third-party dependencies, no network access, no accounts, no telemetry
- Apple Silicon, macOS 14 Sonoma or newer

> **Status:** the Swift code has been written and statically checked, but it has
> **not been compiled or run on a Mac yet**. Expect a few small build errors on
> the first build. Issues and pull requests are welcome.

## Install

Requirements: Apple Silicon Mac, macOS 14+, [Xcode 16+](https://apps.apple.com/app/xcode/id497799835),
and [Homebrew](https://brew.sh) (used to install XcodeGen automatically).

```bash
git clone https://github.com/therezafarzin/PDF-pro.git
cd PDF-pro
./Install.command
```

You can also double-click `Install.command` in Finder.
If macOS blocks it, right-click → **Open**, or run `bash Install.command`.

The installer lets you choose **Version 1** or **Version 2**, builds it from
source, removes any existing copy of PDF Study, and installs the new one to
`~/Applications`. Your library, annotations and backups are kept unless you
choose to delete them.

Non-interactive use:

```bash
./Install.command --version 2 --yes     # install Version 2 without prompts
./Install.command --uninstall           # remove the app (keeps your data)
./Install.command --uninstall --purge-data
```

## Versions

| Version | Folder | What it contains |
|---|---|---|
| 1 | `versions/v1` | Reader, annotations, bilingual text boxes, vocabulary, library, search, export |
| 2 | `versions/v2` | Everything in Version 1, plus Quick Tools (convert, combine, split, optimize, OCR, page editor, signature) |

Each folder has its own `README.md`, `FEATURES.md` and `docs/ARCHITECTURE.md`.

## Checks that run without a Mac

```bash
python3 versions/v2/scripts/verify_schema.py
python3 versions/v2/scripts/verify_geometry.py
python3 versions/v2/scripts/verify_tools.py
python3 versions/v2/scripts/static_check.py
```

## License

[MIT](LICENSE)
