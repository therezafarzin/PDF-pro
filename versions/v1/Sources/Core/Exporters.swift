import Foundation

/// Text exporters: vocabulary lists (Anki-compatible TSV, CSV) and personal study notes.
enum VocabularyExporter {

    private static func html(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    /// Tab-separated file importable by Anki ("Basic" note type: Front, Back, Tags).
    /// Persian text is wrapped in a dir="rtl" span so Anki renders it correctly.
    static func ankiTSV(_ entries: [VocabularyEntry], deckTags: [String] = ["PDFStudy"]) -> String {
        var lines = ["#separator:tab", "#html:true", "#tags column:3"]
        for e in entries {
            let front = "<b>" + html(e.displayWord) + "</b>"
                + (e.partOfSpeech == .none ? "" : " <i>(\(e.partOfSpeech.rawValue))</i>")
            var back = "<div dir=\"rtl\" style=\"text-align:right\">" + html(e.translation) + "</div>"
            if !e.plural.isEmpty { back += "<div>Plural: \(html(e.plural))</div>" }
            if !e.example.isEmpty { back += "<div><i>" + html(e.example) + "</i></div>" }
            if !e.explanation.isEmpty { back += "<div dir=\"rtl\" style=\"text-align:right\">" + html(e.explanation) + "</div>" }
            if !e.notes.isEmpty { back += "<div>" + html(e.notes) + "</div>" }
            func clean(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ") }
            lines.append([clean(front), clean(back), deckTags.joined(separator: " ")].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvField(_ s: String) -> String {
        if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    static func csv(_ entries: [VocabularyEntry]) -> String {
        let header = ["Article", "Word", "Plural", "Part of speech", "Translation", "Example", "Explanation", "Notes", "Page"]
        var rows = [header.joined(separator: ",")]
        for e in entries {
            rows.append([e.article.rawValue, e.word, e.plural, e.partOfSpeech == .none ? "" : e.partOfSpeech.rawValue,
                         e.translation, e.example, e.explanation, e.notes, e.page.map { String($0 + 1) } ?? ""]
                .map(csvField).joined(separator: ","))
        }
        // UTF-8 BOM so Excel/Numbers detect Persian text correctly.
        return "\u{FEFF}" + rows.joined(separator: "\n") + "\n"
    }
}

enum NotesExporter {
    /// Markdown export of everything personal about a document.
    static func markdown(title: String, bookmarks: [BookmarkRecord], pageNotes: [PageNote],
                         annotations: [AnnotationModel], vocabulary: [VocabularyEntry]) -> String {
        var out = "# \(title)\n\n"
        if !bookmarks.isEmpty {
            out += "## Bookmarks\n\n"
            for b in bookmarks.sorted(by: { $0.page < $1.page }) { out += "- p. \(b.page + 1): \(b.name)\n" }
            out += "\n"
        }
        if !pageNotes.isEmpty {
            out += "## Page notes\n\n"
            for n in pageNotes.sorted(by: { $0.page < $1.page }) { out += "### p. \(n.page + 1)\n\n\(n.text)\n\n" }
        }
        let texts = annotations.filter { !$0.plainText.isEmpty }.sorted { ($0.pageIndex, $0.rect.maxY) < ($1.pageIndex, $1.rect.maxY) }
        if !texts.isEmpty {
            out += "## Annotations\n\n"
            for a in texts {
                let label = a.kind == .stickyNote ? "Note" : "Text"
                out += "- **p. \(a.pageIndex + 1)** (\(label)): " + a.plainText.replacingOccurrences(of: "\n", with: " ") + "\n"
            }
            out += "\n"
        }
        if !vocabulary.isEmpty {
            out += "## Vocabulary\n\n| German | Persian | Example |\n|---|---|---|\n"
            for v in vocabulary {
                func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
                out += "| \(cell(v.displayWord)) | \(cell(v.translation)) | \(cell(v.example)) |\n"
            }
        }
        return out
    }
}
