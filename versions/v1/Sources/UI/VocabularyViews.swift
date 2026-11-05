import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit

struct VocabularyEditor: View {
    @State var entry: VocabularyEntry
    let isNew: Bool
    let onSave: (VocabularyEntry) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Vocabulary Entry" : "Edit Vocabulary Entry").font(.headline)
            Form {
                Section {
                    HStack {
                        Picker("Article", selection: $entry.article) { ForEach(GermanArticle.allCases) { Text($0.title).tag($0) } }.frame(width: 150)
                        TextField("German word or phrase", text: $entry.word)
                    }
                    Picker("Part of speech", selection: $entry.partOfSpeech) { ForEach(PartOfSpeech.allCases) { Text($0.title).tag($0) } }
                    TextField("Plural form", text: $entry.plural)
                }
                Section {
                    TextField("Persian translation", text: $entry.translation, axis: .vertical).lineLimit(1...3)
                    TextField("German example sentence", text: $entry.example, axis: .vertical).lineLimit(2...4)
                    TextField("Persian explanation", text: $entry.explanation, axis: .vertical).lineLimit(2...4)
                    TextField("Personal notes", text: $entry.notes, axis: .vertical).lineLimit(2...4)
                    Toggle("Mark for review", isOn: $entry.needsReview)
                }
            }.formStyle(.grouped)
            HStack {
                Button { Speaker.shared.speakGerman(entry.displayWord) } label: { Label("Speak", systemImage: "speaker.wave.2") }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(entry) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(entry.word.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(20).frame(width: 520)
    }
}

enum VocabularyExportUI {
    enum Kind { case anki, csv }
    @MainActor static func save(_ entries: [VocabularyEntry], kind: Kind, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + (kind == .anki ? " – Anki.txt" : " – Vocabulary.csv")
        panel.allowedContentTypes = [kind == .anki ? .plainText : .commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = kind == .anki ? VocabularyExporter.ankiTSV(entries) : VocabularyExporter.csv(entries)
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { Prompt.error("Export failed", error.localizedDescription) }
    }
}

struct VocabularyLibraryView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var lib = AppState.shared.library
    @State private var query = ""
    @State private var editing: VocabularyEntry?
    @State private var reviewOnly = false

    private var filtered: [VocabularyEntry] {
        let q = TextNormalizer.fold(query)
        return lib.allVocabulary.filter { (!reviewOnly || $0.needsReview) && (q.isEmpty || TextNormalizer.fold([$0.word, $0.translation, $0.example].joined(separator: " ")).contains(q)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Vocabulary").font(.system(size: 22, weight: .semibold, design: .serif))
                Spacer()
                TextField("Search words and translations", text: $query).textFieldStyle(.roundedBorder).frame(width: 260)
                Toggle("To review", isOn: $reviewOnly).toggleStyle(.checkbox)
                Menu {
                    Button("Anki (TSV)…") { VocabularyExportUI.save(filtered, kind: .anki, name: "Vocabulary") }
                    Button("CSV…") { VocabularyExportUI.save(filtered, kind: .csv, name: "Vocabulary") }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize().disabled(filtered.isEmpty)
            }.padding(.horizontal, 24).padding(.vertical, 16)
            if filtered.isEmpty {
                EmptyStateView(systemImage: "character.book.closed", title: "No vocabulary entries", message: "Open a PDF, choose the Vocabulary tool (⌘⇧Y) and select a German word.")
            } else {
                List(filtered) { v in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(v.displayWord).font(.system(size: 14, weight: .semibold)); if v.partOfSpeech != .none { Text(v.partOfSpeech.rawValue).font(.caption).foregroundStyle(.secondary) } }
                            if !v.example.isEmpty { Text(v.example).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer()
                        Text(v.translation).font(.system(size: 14))
                        if v.needsReview { Image(systemName: "flag.fill").foregroundStyle(.orange) }
                    }
                    .contentShape(Rectangle()).onTapGesture(count: 2) { editing = v }
                    .contextMenu {
                        Button("Edit…") { editing = v }
                        Button("Delete", role: .destructive) { app.store.deleteVocabulary(v.id); lib.refresh() }
                    }
                }.listStyle(.inset)
            }
        }
        .sheet(item: $editing) { e in
            VocabularyEditor(entry: e, isNew: false) { app.store.saveVocabulary($0); lib.refresh(); editing = nil } onCancel: { editing = nil }
        }
    }
}

// MARK: - Export sheet, versions, printing

struct ExportSheet: View {
    @ObservedObject var session: ReaderSession
    @Environment(\.dismiss) private var dismiss
    @State private var mode: ExportMode = .flattened
    @State private var range = "all"
    @State private var customRange = ""
    @State private var progress: Double?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export PDF").font(.headline)
            Picker("Annotations", selection: $mode) { ForEach(ExportMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.radioGroup)
            Text(mode == .flattened
                 ? "Annotations are drawn into the pages. Mixed Persian/German text looks identical in Preview and every other viewer."
                 : mode == .standardAnnotations
                 ? "Annotations stay editable in other apps. Rich text boxes are written as plain text boxes, so mixed-direction layout depends on the viewer."
                 : "Only the original pages are exported.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Picker("Pages", selection: $range) { Text("All pages").tag("all"); Text("Current page").tag("current"); Text("Page range").tag("custom") }.pickerStyle(.radioGroup)
            if range == "custom" { TextField("e.g. 1-5, 8, 10-12", text: $customRange).textFieldStyle(.roundedBorder) }
            if let p = progress { ProgressView(value: p) }
            if let e = error { Text(e).foregroundStyle(.red).font(.caption) }
            HStack {
                Menu("Export Notes…") {
                    Button("Notes as Markdown…") { exportNotes() }
                }.fixedSize()
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export…") { run() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(progress != nil)
            }
        }.padding(20).frame(width: 480)
    }

    private func pages() -> [Int]? {
        guard let doc = session.document else { return nil }
        switch range {
        case "current": return [session.currentPage]
        case "custom":
            guard let p = PageRangeParser.parse(customRange, pageCount: doc.pageCount) else { error = "Enter pages between 1 and \(doc.pageCount), like 1-5, 8."; return nil }
            return p
        default: return Array(0..<doc.pageCount)
        }
    }

    private func run() {
        error = nil
        guard let doc = session.document, let pages = pages() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = session.url.deletingPathExtension().lastPathComponent + (mode == .plain ? "" : " – annotated") + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.controller.flushPending()
        progress = 0
        Task {
            do {
                try await PDFExporter.export(document: doc, annotations: session.controller.all, pages: pages, mode: mode, to: url) { progress = $0 }
                progress = nil
                NSWorkspace.shared.activateFileViewerSelecting([url])
                dismiss()
            } catch { progress = nil; self.error = error.localizedDescription }
        }
    }

    private func exportNotes() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = session.record.title + " – Notes.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let md = NotesExporter.markdown(title: session.record.title, bookmarks: session.bookmarks, pageNotes: session.store.pageNotes(docID: session.id),
                                        annotations: session.controller.all, vocabulary: session.vocabulary)
        do { try md.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
    }
}

struct VersionsSheet: View {
    @ObservedObject var session: ReaderSession
    @Environment(\.dismiss) private var dismiss
    @State private var items: [VersionSnapshot] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Version History").font(.headline)
            Text("Restore points of your annotations are saved when you close a document, press Save, and before any restore. Restoring is undoable.").font(.caption).foregroundStyle(.secondary)
            if items.isEmpty { Text("No versions yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80) }
            List(items) { v in
                HStack {
                    VStack(alignment: .leading) { Text(v.createdAt.formatted(date: .abbreviated, time: .shortened)); Text("\(v.label) · \(v.count) annotations").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Restore") {
                        if Prompt.confirm(title: "Restore this version?", message: "Current annotations are replaced (a restore point is saved first and the change can be undone).", okTitle: "Restore"),
                           let models = session.store.snapshotModels(id: v.id) { session.controller.restore(models); dismiss() }
                    }
                }
            }.frame(height: 240)
            HStack {
                Button("Embed Annotations in Original PDF…") { dismiss(); DispatchQueue.main.async { session.embedInOriginal() } }
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 480).onAppear { items = session.store.snapshots(docID: session.id) }
    }
}

extension ReaderSession {
    func printAnnotated() {
        guard let doc = document else { return }
        controller.flushPending()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("print-\(UUID().uuidString).pdf")
        Task {
            do {
                try await PDFExporter.export(document: doc, annotations: controller.all, pages: nil, mode: .flattened, to: tmp)
                guard let out = PDFDocument(url: tmp) else { return }
                let info = NSPrintInfo.shared.copy() as! NSPrintInfo
                out.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true)?.run()
                try? FileManager.default.removeItem(at: tmp)
            } catch { Prompt.error("Could not print", error.localizedDescription) }
        }
    }

    /// Option 1 from the spec: write annotations into the original PDF (with a safety copy).
    func embedInOriginal() {
        guard let doc = document else { return }
        guard Prompt.confirm(title: "Embed annotations in the original PDF?",
                             message: "A copy of the original file is stored first. Annotations become standard PDF annotations (editable in Preview and other apps); the app’s own rich-text layer for this document is cleared, but a version snapshot is kept. Text boxes lose rich formatting and may not lay out mixed Persian/German text identically in other viewers. Export keeps full fidelity.",
                             okTitle: "Embed", destructive: true) else { return }
        controller.flushPending()
        controller.createSnapshot(label: "Before embedding")
        do {
            let backup = try PDFExporter.embedInOriginal(document: doc, annotations: controller.all, originalURL: url)
            let newID = try DocumentFingerprint.compute(url: url)
            let old = record.id
            try store.rekeyDocument(from: old, to: newID)
            controller.rebind(docID: newID)
            controller.clearAllAfterEmbedding()
            AppState.shared.notice = "Embedded. Original saved to “\(backup.lastPathComponent)”"
            AppState.shared.close(self)
            AppState.shared.open(url: url)
        } catch { Prompt.error("Could not embed annotations", error.localizedDescription) }
    }
}
