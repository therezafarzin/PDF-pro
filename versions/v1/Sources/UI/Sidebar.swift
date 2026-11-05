import SwiftUI
import PDFKit

struct SidebarView: View {
    @ObservedObject var session: ReaderSession
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $session.sidebarTab) {
                ForEach(SidebarTab.allCases) { t in Image(systemName: t.systemImage).help(t.title).tag(t) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            Divider()
            Group {
                switch session.sidebarTab {
                case .pages: ThumbnailsView(session: session)
                case .outline: OutlineSidebar(session: session)
                case .bookmarks: BookmarksSidebar(session: session)
                case .annotations: AnnotationsSidebar(session: session, controller: session.controller)
                case .notes: PageNoteSidebar(session: session)
                case .vocabulary: VocabularySidebar(session: session)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .onChange(of: session.sidebarTab) { _, _ in session.scheduleSave() }
    }
}

struct ThumbnailsView: NSViewRepresentable {
    @ObservedObject var session: ReaderSession
    func makeNSView(context: Context) -> PDFThumbnailView {
        let v = PDFThumbnailView()
        v.thumbnailSize = CGSize(width: 120, height: 160)
        v.maximumNumberOfColumns = 1
        v.backgroundColor = .clear
        v.pdfView = session.pdfView
        return v
    }
    func updateNSView(_ v: PDFThumbnailView, context: Context) {
        if v.pdfView == nil || v.pdfView !== session.pdfView { v.pdfView = session.pdfView }
    }
}

struct OutlineSidebar: View {
    @ObservedObject var session: ReaderSession
    var body: some View {
        if session.outline.isEmpty {
            EmptyStateView(systemImage: "list.bullet.indent", title: "No table of contents", message: "This PDF does not include an outline. Use bookmarks to mark your own sections.")
        } else {
            List(session.outline, children: \.children) { node in
                Button { if let d = node.destination { session.go(to: d) } } label: { Text(node.label).lineLimit(2) }.buttonStyle(.plain)
            }.listStyle(.sidebar)
        }
    }
}

struct BookmarksSidebar: View {
    @ObservedObject var session: ReaderSession
    var body: some View {
        VStack(spacing: 0) {
            Button {
                if let n = Prompt.text(title: "New Bookmark", message: "Name for page \(session.currentPage + 1)", defaultValue: "Page \(session.currentPage + 1)", okTitle: "Add") { session.addBookmark(name: n) }
            } label: { Label("Bookmark Page \(session.currentPage + 1)", systemImage: "bookmark.fill").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).padding(10)
            if session.bookmarks.isEmpty {
                EmptyStateView(systemImage: "bookmark", title: "No bookmarks", message: "Bookmark important pages and give them your own names.")
            } else {
                List(session.bookmarks) { b in
                    Button { session.goTo(page: b.page) } label: {
                        HStack { Image(systemName: "bookmark.fill").foregroundStyle(Color.accentColor); Text(b.name).lineLimit(2); Spacer(); Text("\(b.page + 1)").monospacedDigit().foregroundStyle(.secondary) }
                    }.buttonStyle(.plain)
                    .contextMenu {
                        Button("Rename…") { if let n = Prompt.text(title: "Rename Bookmark", defaultValue: b.name, okTitle: "Rename") { session.renameBookmark(b, to: n) } }
                        Button("Delete", role: .destructive) { session.deleteBookmark(b) }
                    }
                }.listStyle(.sidebar)
            }
        }
    }
}

struct PageNoteSidebar: View {
    @ObservedObject var session: ReaderSession
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Note for page \(session.currentPage + 1)")
                Spacer()
                Button { session.toggleRead(page: session.currentPage) } label: { Label("Mark read", systemImage: "checkmark.circle") }.buttonStyle(.borderless).controlSize(.small)
            }
            TextEditor(text: Binding(get: { session.pageNote }, set: { session.updatePageNote($0) }))
                .font(.system(size: 13)).scrollContentBackground(.hidden).padding(8)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Color.primary.opacity(0.08)))
                .frame(minHeight: 140)
            Text("Notes are saved automatically and are searchable. Persian and German text can be mixed freely.").font(.caption).foregroundStyle(.secondary)
            Divider()
            SectionHeader(title: "All page notes")
            let notes = session.store.pageNotes(docID: session.id)
            if notes.isEmpty { Text("None yet").foregroundStyle(.tertiary).font(.callout) }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(notes, id: \.page) { n in
                        Button { session.goTo(page: n.page) } label: {
                            HStack(alignment: .top) { Text("p. \(n.page + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                                Text(n.text).lineLimit(2).font(.callout).multilineTextAlignment(.leading); Spacer() }
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.padding(12).onChange(of: session.currentPage) { _, _ in session.loadPageNote() }
    }
}

struct AnnotationsSidebar: View {
    @ObservedObject var session: ReaderSession
    @ObservedObject var controller: AnnotationController
    @State private var query = ""
    @State private var replacement = ""
    @State private var showReplace = false
    @State private var kindFilter: String = "all"

    private var items: [AnnotationModel] {
        let q = TextNormalizer.fold(query)
        return controller.all.filter { m in
            (kindFilter == "all" || (kindFilter == "markup" && m.kind.isMarkup) || (kindFilter == "text" && m.kind.isTextual) || (kindFilter == "drawing" && m.kind.isStroked))
            && (q.isEmpty || TextNormalizer.fold(m.plainText).contains(q))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search annotations", text: $query).textFieldStyle(.plain) }
                    .padding(7).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
                Picker("", selection: $kindFilter) { Text("All").tag("all"); Text("Text").tag("text"); Text("Markup").tag("markup"); Text("Drawing").tag("drawing") }
                    .pickerStyle(.segmented).labelsHidden()
                DisclosureGroup("Find & Replace in text boxes", isExpanded: $showReplace) {
                    HStack { TextField("Replace with", text: $replacement).textFieldStyle(.roundedBorder)
                        Button("Replace All") {
                            let n = controller.replaceText(find: query, with: replacement)
                            AppState.shared.notice = n == 0 ? "No matches" : "Replaced \(n) occurrence\(n == 1 ? "" : "s")"
                            Task { try? await Task.sleep(nanoseconds: 2_000_000_000); AppState.shared.notice = nil }
                        }.disabled(query.isEmpty) }
                }.font(.caption)
            }.padding(10)
            Divider()
            if items.isEmpty {
                EmptyStateView(systemImage: "text.bubble", title: "No annotations", message: "Highlights, text boxes and drawings you add appear here.")
            } else {
                List(items) { m in
                    Button { session.reveal(m) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: icon(m)).foregroundStyle(m.kind.isMarkup ? m.style.stroke.color : Color.accentColor).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.plainText.isEmpty ? label(m) : m.plainText).lineLimit(2).font(.callout)
                                Text("Page \(m.pageIndex + 1)" + (m.category.map { " · \($0.title)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if m.locked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.buttonStyle(.plain)
                    .listRowBackground(controller.selection.contains(m.id) ? Color.accentColor.opacity(0.14) : Color.clear)
                    .contextMenu { Button("Delete", role: .destructive) { controller.delete(ids: [m.id]) } }
                }.listStyle(.sidebar)
            }
        }
    }
    private func icon(_ m: AnnotationModel) -> String {
        switch m.kind {
        case .textBox: return "textbox"; case .stickyNote: return "note.text"; case .highlight: return "highlighter"
        case .underline: return "underline"; case .strikeThrough: return "strikethrough"; case .squiggly: return "scribble.variable"
        case .rectangle: return "rectangle"; case .ellipse: return "circle"; case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"; case .ink: return "pencil.tip"
        }
    }
    private func label(_ m: AnnotationModel) -> String { m.kind.rawValue.capitalized }
}

struct VocabularySidebar: View {
    @ObservedObject var session: ReaderSession
    @State private var editing: VocabularyEntry?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { session.vocabularyDraft = VocabularyEntry(docID: session.id, page: session.currentPage) } label: { Label("New Entry", systemImage: "plus") }
                Spacer()
                Menu {
                    Button("Anki (TSV)…") { VocabularyExportUI.save(session.vocabulary, kind: .anki, name: session.record.title) }
                    Button("CSV…") { VocabularyExportUI.save(session.vocabulary, kind: .csv, name: session.record.title) }
                } label: { Image(systemName: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize().disabled(session.vocabulary.isEmpty)
            }.padding(10)
            Divider()
            if session.vocabulary.isEmpty {
                EmptyStateView(systemImage: "character.book.closed", title: "No vocabulary yet", message: "Choose the Vocabulary tool, then select a German word in the text.")
            } else {
                List(session.vocabulary) { v in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(v.displayWord).font(.system(size: 13, weight: .semibold)); if v.needsReview { Image(systemName: "flag.fill").foregroundStyle(.orange).font(.caption) }; Spacer()
                            if let p = v.page { Text("p. \(p + 1)").font(.caption).foregroundStyle(.secondary) } }
                        Text(v.translation).font(.callout)
                    }
                    .contentShape(Rectangle()).onTapGesture { editing = v }
                    .contextMenu {
                        Button("Go to Page") { if let p = v.page { session.goTo(page: p) } }
                        Button("Speak") { Speaker.shared.speakGerman(v.displayWord) }
                        Button("Delete", role: .destructive) { session.deleteVocabulary(v) }
                    }
                }.listStyle(.sidebar)
            }
        }
        .sheet(item: $editing) { e in
            VocabularyEditor(entry: e, isNew: false) { session.saveVocabulary($0); editing = nil } onCancel: { editing = nil }
        }
    }
}
