import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - Shared building blocks

enum OutputFolder {
    static var current: URL? {
        let p = UserDefaults.standard.string(forKey: "tools.outputDir") ?? ""
        return p.isEmpty ? nil : URL(fileURLWithPath: p, isDirectory: true)
    }
}

struct ToolSheet<Content: View>: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let kind: ToolKind
    @ObservedObject var runner: ToolRunner
    let canRun: Bool
    let runTitle: String
    let onRun: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ToolIcon(kind: kind, size: 36)
                VStack(alignment: .leading, spacing: 2) { Text(kind.title).font(.headline); Text(kind.subtitle).font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content() }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(runner.running)
            Divider()
            footer.padding(14)
        }
        .frame(width: 580, height: 580)
        .onDisappear { runner.cancel() }
    }

    @ViewBuilder private var footer: some View {
        if runner.running {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: runner.progress)
                Text(runner.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack { Spacer(); Button("Cancel") { runner.cancel() } }
            }
        } else if runner.finished {
            VStack(alignment: .leading, spacing: 8) {
                if let e = runner.errorMessage {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                } else {
                    Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                }
                ForEach(Array(runner.notes.enumerated()), id: \.offset) { _, n in Text(n).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    if !runner.outputs.isEmpty {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(runner.outputs.prefix(50))) }
                        if let pdf = runner.outputs.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
                            Button("Open in PDF Study") { app.open(url: pdf); dismiss() }
                        }
                    }
                    Spacer()
                    if runner.errorMessage != nil { Button("Back") { runner.reset() } }
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        } else {
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(runTitle) { onRun() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canRun)
            }
        }
    }
}

struct OutputFolderRow: View {
    @AppStorage("tools.outputDir") private var path = ""
    var body: some View {
        HStack {
            Text("Save results").foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { path.isEmpty ? "next" : "folder" }, set: { v in
                if v == "next" { path = "" } else { choose() }
            })) {
                Text("Next to the original file").tag("next")
                Text(path.isEmpty ? "In a folder…" : "In “\((path as NSString).lastPathComponent)”").tag("folder")
            }.labelsHidden().fixedSize()
            if !path.isEmpty { Button("Change…") { choose() }.buttonStyle(.link) }
        }
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

struct LanguageSelector: View {
    @Binding var selected: Set<String>
    private let supported = OCRLayer.supportedLanguages()

    static func defaultSelection() -> Set<String> {
        let s = Set(OCRLayer.supportedLanguages())
        return Set(["de-DE", "en-US", "fa-IR"].filter { s.contains($0) })
    }
    static func ordered(_ set: Set<String>) -> [String] {
        set.sorted { a, b in (a == "de-DE" ? 0 : 1, a) < (b == "de-DE" ? 0 : 1, b) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recognition languages").font(.caption).foregroundStyle(.secondary)
            if supported.isEmpty {
                Text("Languages are detected automatically.").font(.callout)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(supported, id: \.self) { id in
                        Toggle(Locale.current.localizedString(forIdentifier: id) ?? id, isOn: Binding(
                            get: { selected.contains(id) },
                            set: { on in if on { selected.insert(id) } else { selected.remove(id) } })).toggleStyle(.checkbox)
                    }
                }
                if !supported.contains(where: { $0.hasPrefix("fa") }) {
                    Text("This macOS version’s text recognizer does not list Persian; Persian text may be recognized poorly. German and English work.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ToolFileList: View {
    @EnvironmentObject var app: AppState
    @Binding var inputs: [ToolInput]
    var allowImages = false
    var showPages = false
    var reorderable = false
    @State private var info: [UUID: String] = [:]
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { addFiles() } label: { Label("Add Files…", systemImage: "plus") }
                Menu("From Library") {
                    ForEach(app.library.documents) { d in
                        Button(d.title) { add([FileAccess.resolve(d)?.url ?? d.url]) }
                    }
                }.fixedSize().disabled(app.library.documents.isEmpty)
                Spacer()
                if !inputs.isEmpty { Button("Clear") { inputs = [] }.buttonStyle(.link) }
            }
            if inputs.isEmpty {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(targeted ? Color.accentColor : Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .frame(height: 84)
                    .overlay(Text(allowImages ? "Drop PDFs or images here" : "Drop PDF files here").foregroundStyle(.secondary))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(inputs.enumerated()), id: \.element.id) { i, input in
                        row(i, input)
                        if i < inputs.count - 1 { Divider() }
                    }
                }.card(padding: 0)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in add([url]) } }
                }
            }
            return true
        }
        .onAppear { for i in inputs { computeInfo(i) } }
    }

    private func row(_ i: Int, _ input: ToolInput) -> some View {
        HStack(spacing: 8) {
            Image(systemName: input.isImage ? "photo" : "doc.text").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(input.url.lastPathComponent).lineLimit(1).font(.callout)
                Text(info[input.id] ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if showPages && !input.isImage {
                TextField("all pages", text: $inputs[i].pages).textFieldStyle(.roundedBorder).frame(width: 110).help("Pages to use, like 1-3, 8")
            }
            if reorderable {
                Button { inputs.swapAt(i, i - 1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(i == 0)
                Button { inputs.swapAt(i, i + 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(i == inputs.count - 1)
            }
            Button { inputs.remove(at: i) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
        }.padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = allowImages ? [.pdf, .image] : [.pdf]
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func add(_ urls: [URL]) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ext == "pdf" || (allowImages && ToolInput.imageExtensions.contains(ext)) else { continue }
            guard !inputs.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { continue }
            let input = ToolInput(url: url)
            inputs.append(input)
            computeInfo(input)
        }
    }

    private func computeInfo(_ input: ToolInput) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: input.url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let s = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        if input.isImage { info[input.id] = "Image · \(s)"; return }
        FileAccess.begin(input.url)
        if let d = PDFDocument(url: input.url) {
            info[input.id] = d.isLocked ? "Password protected · \(s)" : "\(d.pageCount) page\(d.pageCount == 1 ? "" : "s") · \(s)"
        } else { info[input.id] = "Cannot be read" }
    }
}

// MARK: - Combine

struct CombineSheet: View {
    @StateObject private var runner = ToolRunner()
    @State private var inputs: [ToolInput]
    @State private var fitA4 = true
    @State private var bookmarks = true
    init(urls: [URL]) { _inputs = State(initialValue: urls.map { ToolInput(url: $0) }) }

    var body: some View {
        ToolSheet(kind: .combine, runner: runner, canRun: !inputs.isEmpty, runTitle: "Combine…", onRun: run) {
            ToolFileList(inputs: $inputs, allowImages: true, showPages: true, reorderable: true)
            Toggle("Fit images to A4 pages", isOn: $fitA4)
            Toggle("Add a bookmark for each file (keeps each file’s own table of contents inside it)", isOn: $bookmarks)
            Text("Use the page field to take only some pages of a file. Order in the list = order in the result.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func run() {
        let first = inputs.first?.url
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = OutputFolder.current ?? first?.deletingLastPathComponent()
        panel.nameFieldStringValue = (first?.deletingPathExtension().lastPathComponent ?? "Combined") + " – combined.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if inputs.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            Prompt.error("Choose a different name", "The result can’t replace one of the files being combined.")
            return
        }
        let list = inputs, a4 = fitA4, bm = bookmarks
        runner.run { r in try await PDFTools.combine(inputs: list, fitImagesToA4: a4, bookmarks: bm, output: url, runner: r) }
    }
}

// MARK: - Split

struct SplitSheet: View {
    enum Choice: String, CaseIterable, Identifiable {
        case every, single, startAt, ranges, bookmarks
        var id: String { rawValue }
        var title: String {
            switch self {
            case .every: return "Every N pages"; case .single: return "One file per page"
            case .startAt: return "Start a new file at pages…"; case .ranges: return "Page ranges (one file each)…"
            case .bookmarks: return "Top-level bookmarks (chapters)"
            }
        }
    }
    @StateObject private var runner = ToolRunner()
    @State private var inputs: [ToolInput]
    @State private var choice: Choice = .every
    @State private var n = 10
    @State private var startText = ""
    @State private var rangeText = ""
    init(urls: [URL]) { _inputs = State(initialValue: urls.map { ToolInput(url: $0) }) }

    private var strategy: SplitStrategy {
        switch choice {
        case .every: return .everyN(n)
        case .single: return .singlePages
        case .startAt: return .startingAt(startText)
        case .ranges: return .ranges(rangeText)
        case .bookmarks: return .topLevelBookmarks
        }
    }
    private var ready: Bool {
        guard !inputs.isEmpty else { return false }
        switch choice {
        case .startAt: return !startText.trimmingCharacters(in: .whitespaces).isEmpty
        case .ranges: return !rangeText.trimmingCharacters(in: .whitespaces).isEmpty
        default: return true
        }
    }

    var body: some View {
        ToolSheet(kind: .split, runner: runner, canRun: ready, runTitle: "Split", onRun: {
            let list = inputs, s = strategy
            runner.run { r in try await PDFTools.split(inputs: list, strategy: s, outputDir: OutputFolder.current, runner: r) }
        }) {
            ToolFileList(inputs: $inputs)
            Picker("Split", selection: $choice) { ForEach(Choice.allCases) { Text($0.title).tag($0) } }.pickerStyle(.radioGroup)
            switch choice {
            case .every: Stepper("Pages per file: \(n)", value: $n, in: 1...2000)
            case .startAt: TextField("e.g. 10, 25, 40  (a new file starts on each of these pages)", text: $startText).textFieldStyle(.roundedBorder)
            case .ranges: TextField("e.g. 1-5, 8, 10-12", text: $rangeText).textFieldStyle(.roundedBorder)
            case .bookmarks: Text("Each top-level entry of the table of contents starts a new file named after it.").font(.caption).foregroundStyle(.secondary)
            case .single: EmptyView()
            }
            OutputFolderRow()
            Text("Files are written to a new “… – split” folder; the original is not changed. Each part keeps the matching bookmarks.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Optimize

struct OptimizeSheet: View {
    @StateObject private var runner = ToolRunner()
    @State private var inputs: [ToolInput]
    @State private var preset: OptimizePreset = .balanced
    @State private var dpi = 110.0
    @State private var quality = 0.6
    @State private var searchable = true
    @State private var languages = LanguageSelector.defaultSelection()
    init(urls: [URL]) { _inputs = State(initialValue: urls.map { ToolInput(url: $0) }) }

    var body: some View {
        ToolSheet(kind: .optimize, runner: runner, canRun: !inputs.isEmpty, runTitle: "Optimize", onRun: {
            let list = inputs, p = preset, d = Int(dpi), q = quality, s = searchable, l = LanguageSelector.ordered(languages)
            runner.run { r in try await PDFTools.optimize(inputs: list, preset: p, dpi: d, quality: q, keepSearchable: s, languages: l, outputDir: OutputFolder.current, runner: r) }
        }) {
            ToolFileList(inputs: $inputs)
            ForEach(OptimizePreset.allCases) { p in
                Button { preset = p } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: preset == p ? "largecircle.fill.circle" : "circle").foregroundStyle(preset == p ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) { Text(p.title).font(.callout.weight(.semibold)); Text(p.detail).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if preset == .strong {
                CommitSlider(title: "Resolution", value: $dpi, range: 72...200, format: "%.0f dpi")
                CommitSlider(title: "JPEG quality", value: $quality, range: 0.2...0.95, format: "%.0f%%", scale: 100)
                Toggle("Keep text searchable (runs OCR, slower)", isOn: $searchable)
                if searchable { LanguageSelector(selected: $languages) }
            }
            OutputFolderRow()
            Text("Results are saved as “… – optimized.pdf”. If a result would not be smaller, it is discarded and your file stays as is.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Convert

struct ConvertSheet: View {
    @StateObject private var runner = ToolRunner()
    @EnvironmentObject var app: AppState
    @State private var inputs: [ToolInput]
    @State private var options = ConvertOptions()
    @State private var dpi = 150.0
    @State private var languages = LanguageSelector.defaultSelection()
    init(urls: [URL]) { _inputs = State(initialValue: urls.map { ToolInput(url: $0) }) }

    var body: some View {
        ToolSheet(kind: .convert, runner: runner, canRun: !inputs.isEmpty, runTitle: "Convert", onRun: {
            var o = options; o.dpi = Int(dpi); o.languages = LanguageSelector.ordered(languages)
            let list = inputs, store = app.store
            runner.run { r in try await PDFTools.convert(inputs: list, options: o, outputDir: OutputFolder.current, store: store, runner: r) }
        }) {
            ToolFileList(inputs: $inputs, showPages: true)
            Picker("Convert to", selection: $options.format) { ForEach(ConvertFormat.allCases) { Text($0.title).tag($0) } }
            if options.format.isImage {
                CommitSlider(title: "Resolution", value: $dpi, range: 72...600, format: "%.0f dpi")
                if options.format == .jpeg { CommitSlider(title: "JPEG quality", value: $options.jpegQuality, range: 0.3...1, format: "%.0f%%", scale: 100) }
                Toggle("Include my annotations", isOn: $options.includeAnnotations)
                Toggle("Put images in a new folder", isOn: $options.subfolder)
            } else {
                Toggle("Add page markers", isOn: $options.pageMarkers)
                Toggle("Recognize text on pages without any (OCR)", isOn: $options.ocrWhenNoText)
                if options.ocrWhenNoText { LanguageSelector(selected: $languages) }
                Text("Text is taken from the PDF’s text layer. Right-to-left (Persian/Arabic) text depends on how the PDF stores it and can come out in visual order.").font(.caption).foregroundStyle(.secondary)
            }
            OutputFolderRow()
            Text("Word, Excel and PowerPoint output is not offered: it cannot be produced reliably without a conversion service.").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - OCR

struct OCRSheet: View {
    @StateObject private var runner = ToolRunner()
    @State private var inputs: [ToolInput]
    @State private var languages = LanguageSelector.defaultSelection()
    @State private var skipText = true
    @State private var dpi = 250.0
    init(urls: [URL]) { _inputs = State(initialValue: urls.map { ToolInput(url: $0) }) }

    var body: some View {
        ToolSheet(kind: .ocr, runner: runner, canRun: !inputs.isEmpty, runTitle: "Recognize Text", onRun: {
            let list = inputs, l = LanguageSelector.ordered(languages), s = skipText, d = Int(dpi)
            runner.run { r in try await PDFTools.ocr(inputs: list, languages: l, skipPagesWithText: s, dpi: d, outputDir: OutputFolder.current, runner: r) }
        }) {
            ToolFileList(inputs: $inputs)
            LanguageSelector(selected: $languages)
            Toggle("Skip pages that already contain text", isOn: $skipText)
            CommitSlider(title: "Scan resolution used for recognition", value: $dpi, range: 150...400, format: "%.0f dpi")
            OutputFolderRow()
            Text("Creates “… – OCR.pdf”: the pages look exactly the same, with an invisible text layer so you can search and select text. Runs on this Mac with Apple’s Vision framework; nothing is uploaded.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
