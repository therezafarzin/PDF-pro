import SwiftUI
import AppKit

struct LibraryView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var lib = AppState.shared.library
    @State private var tagEditing: DocumentRecord?

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar().frame(width: 220)
            Divider()
            Group {
                switch lib.selection {
                case .home: DashboardView()
                case .vocabulary: VocabularyLibraryView()
                default: DocumentBrowser(tagEditing: $tagEditing)
                }
            }
        }
        .sheet(item: $tagEditing) { TagEditor(record: $0) }
    }
}

// MARK: Sidebar

struct LibrarySidebar: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var lib = AppState.shared.library

    var body: some View {
        List(selection: Binding<SidebarItem?>(get: { lib.selection }, set: { if let v = $0 { lib.selection = v } })) {
            Section {
                Label("Dashboard", systemImage: "square.text.square").tag(SidebarItem.home)
                Label("All Documents", systemImage: "books.vertical").tag(SidebarItem.all)
                Label("Recently Opened", systemImage: "clock").tag(SidebarItem.recent)
                Label("Favorites", systemImage: "star").tag(SidebarItem.favorites)
                Label("Pinned", systemImage: "pin").tag(SidebarItem.pinned)
                Label("Vocabulary", systemImage: "character.book.closed").tag(SidebarItem.vocabulary)
            }
            Section("Collections") {
                OutlineGroup(lib.collections, children: \.children) { node in
                    Label(node.name, systemImage: node.icon).tag(SidebarItem.collection(node.id))
                        .contextMenu {
                            Button("New Sub-Collection…") { newCollection(parent: node.id) }
                            Button("Rename…") {
                                if let n = Prompt.text(title: "Rename Collection", defaultValue: node.name, okTitle: "Rename"), !n.isEmpty { app.store.renameCollection(node.id, name: n); lib.refresh() }
                            }
                            Divider()
                            Button("Delete Collection", role: .destructive) {
                                if Prompt.confirm(title: "Delete “\(node.name)”?", message: "Documents stay in your library.", okTitle: "Delete", destructive: true) {
                                    app.store.deleteCollection(node.id); lib.selection = .all; lib.refresh()
                                }
                            }
                        }
                }
                Button { newCollection(parent: nil) } label: { Label("New Collection", systemImage: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if !lib.tags.isEmpty {
                Section("Tags") {
                    ForEach(lib.tags, id: \.self) { t in Label(t, systemImage: "tag").tag(SidebarItem.tag(t)) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func newCollection(parent: String?) {
        guard let name = Prompt.text(title: parent == nil ? "New Collection" : "New Sub-Collection", message: "For example “German B1” or “Grammar”.", okTitle: "Create"), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        app.store.createCollection(name: name.trimmingCharacters(in: .whitespaces), parentID: parent)
        lib.refresh()
    }
}

// MARK: Browser

struct DocumentBrowser: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var lib = AppState.shared.library
    @Binding var tagEditing: DocumentRecord?

    private var title: String {
        switch lib.selection {
        case .all, .home, .vocabulary: return "All Documents"
        case .recent: return "Recently Opened"
        case .favorites: return "Favorites"
        case .pinned: return "Pinned"
        case .collection(let id): return findName(id, in: lib.collections) ?? "Collection"
        case .tag(let t): return "#\(t)"
        }
    }
    private func findName(_ id: String, in nodes: [CollectionNode]) -> String? {
        for n in nodes { if n.id == id { return n.name }; if let c = n.children, let f = findName(id, in: c) { return f } }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 22, weight: .semibold, design: .serif))
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(lib.fullTextSearch ? "Search inside all indexed PDFs and notes" : "Search library", text: $lib.searchText)
                        .textFieldStyle(.plain).frame(width: 240).onSubmit { lib.runFullTextSearch() }
                    Toggle("Full text", isOn: $lib.fullTextSearch).toggleStyle(.checkbox).font(.caption)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSmall + 2, style: .continuous).fill(Color.primary.opacity(0.06)))
                Menu {
                    Picker("Sort by", selection: $lib.sort) { ForEach(LibrarySort.allCases) { Text($0.title).tag($0) } }
                    Toggle("Ascending", isOn: $lib.ascending)
                } label: { Image(systemName: "arrow.up.arrow.down") }.menuStyle(.borderlessButton).fixedSize()
                Picker("", selection: $lib.gridView) {
                    Image(systemName: "square.grid.2x2").tag(true); Image(systemName: "list.bullet").tag(false)
                }.pickerStyle(.segmented).frame(width: 80).labelsHidden()
                Button { app.openPanel() } label: { Label("Add PDF", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)

            if lib.fullTextSearch && !lib.searchText.isEmpty {
                SearchHitsList(hits: lib.hits)
            } else if lib.visible.isEmpty {
                EmptyStateView(systemImage: "doc.text.magnifyingglass", title: lib.documents.isEmpty ? "Your library is empty" : "Nothing here yet",
                               message: lib.documents.isEmpty ? "Drop PDF files anywhere in this window, or press Add PDF." : "Documents you add to this view will appear here.")
            } else if lib.gridView {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 210), spacing: 22)], spacing: 26) {
                        ForEach(lib.visible) { d in DocumentCard(record: d, tagEditing: $tagEditing) }
                    }.padding(24)
                }
            } else {
                List(lib.visible) { d in DocumentRow(record: d, tagEditing: $tagEditing) }.listStyle(.inset)
            }
        }
        .onChange(of: lib.searchText) { _, _ in if lib.fullTextSearch { lib.runFullTextSearch() } }
        .onChange(of: lib.fullTextSearch) { _, on in
            if on { app.indexer.enqueue(lib.documents) }
            lib.runFullTextSearch()
        }
        .overlay(alignment: .bottom) {
            if let t = app.indexer.activeTitle {
                HStack(spacing: 8) { ProgressView(value: app.indexer.progress).frame(width: 90); Text("Indexing “\(t)”").font(.caption) }
                    .padding(8).background(.regularMaterial, in: Capsule()).padding(10)
            }
        }
    }
}

struct SearchHitsList: View {
    @EnvironmentObject var app: AppState
    let hits: [SearchHit]
    var body: some View {
        if hits.isEmpty {
            EmptyStateView(systemImage: "magnifyingglass", title: "No matches", message: "Documents are indexed in the background after you add or open them.")
        } else {
            List(hits) { h in
                Button {
                    if let r = app.store.document(id: h.docID) {
                        app.open(record: r)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { app.activeSession?.goTo(page: h.page) }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(h.docTitle).font(.headline); Spacer(); Text("p. \(h.page + 1)").foregroundStyle(.secondary).font(.caption.monospacedDigit())
                            Text(h.scope.rawValue).font(.caption2).padding(.horizontal, 5).background(Capsule().fill(Color.accentColor.opacity(0.15))) }
                        Text(h.snippet.replacingOccurrences(of: "⟦", with: "").replacingOccurrences(of: "⟧", with: "")).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }.buttonStyle(.plain)
            }.listStyle(.inset)
        }
    }
}

// MARK: Cards

struct DocumentCard: View {
    @EnvironmentObject var app: AppState
    let record: DocumentRecord
    @Binding var tagEditing: DocumentRecord?
    @State private var image: NSImage?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                    else { Rectangle().fill(Color.primary.opacity(0.06)).overlay(Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.tertiary)) }
                }
                .frame(height: 220).frame(maxWidth: .infinity).clipped()
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(hover ? 0.22 : 0.12), radius: hover ? 12 : 6, y: hover ? 6 : 3)
                HStack(spacing: 4) {
                    if record.isPinned { Image(systemName: "pin.fill") }
                    if record.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                }.font(.caption).padding(6).background(.regularMaterial, in: Capsule()).padding(8).opacity(record.isPinned || record.isFavorite ? 1 : 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                ProgressView(value: record.progress).progressViewStyle(.linear).tint(.accentColor)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .scaleEffect(hover ? 1.015 : 1).animation(Theme.animation, value: hover)
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { app.open(record: record) }
        .contextMenu { DocumentMenu(record: record, tagEditing: $tagEditing) }
        .task(id: record.id) { image = await ThumbnailService.shared.thumbnail(for: record) }
    }

    private var subtitle: String {
        "\(record.pagesRead) of \(record.pageCount) pages · \(Int(record.progress * 100))%"
    }
}

struct DocumentRow: View {
    @EnvironmentObject var app: AppState
    let record: DocumentRecord
    @Binding var tagEditing: DocumentRecord?
    var body: some View {
        HStack {
            Image(systemName: record.isFavorite ? "star.fill" : "doc.text").foregroundStyle(record.isFavorite ? .yellow : .secondary).frame(width: 22)
            VStack(alignment: .leading) {
                Text(record.title).font(.system(size: 13, weight: .medium))
                Text(record.tags.map { "#\($0)" }.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView(value: record.progress).frame(width: 80)
            Text(ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file)).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            Text(record.lastOpenedAt?.formatted(date: .abbreviated, time: .omitted) ?? "—").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
        }
        .contentShape(Rectangle()).onTapGesture(count: 2) { app.open(record: record) }
        .contextMenu { DocumentMenu(record: record, tagEditing: $tagEditing) }
    }
}

struct DocumentMenu: View {
    @EnvironmentObject var app: AppState
    let record: DocumentRecord
    @Binding var tagEditing: DocumentRecord?
    var body: some View {
        let lib = app.library
        Button("Open") { app.open(record: record) }
        Divider()
        Button(record.isFavorite ? "Remove from Favorites" : "Add to Favorites") { lib.toggleFavorite(record) }
        Button(record.isPinned ? "Unpin" : "Pin") { lib.togglePinned(record) }
        Menu("Add to Collection") {
            let current = app.store.collectionIDs(for: record.id)
            ForEach(flatten(lib.collections), id: \.id) { c in
                Button { current.contains(c.id) ? app.store.remove(document: record.id, fromCollection: c.id) : app.store.add(document: record.id, toCollection: c.id); lib.refresh() } label: {
                    Text((current.contains(c.id) ? "✓ " : "") + c.name)
                }
            }
            if lib.collections.isEmpty { Text("No collections yet") }
        }
        Button("Edit Tags…") { tagEditing = record }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([FileAccess.resolve(record)?.url ?? record.url]) }
        Button("Re-index Text") { app.store.clearPDFIndex(docID: record.id); app.store.setIndexed(record.id, nil); lib.refresh(); app.indexer.enqueue([app.store.document(id: record.id) ?? record]) }
        Button("Remove from Library", role: .destructive) {
            if Prompt.confirm(title: "Remove “\(record.title)”?", message: "The PDF file is not deleted. Its annotations, notes and vocabulary links are removed from the library.", okTitle: "Remove", destructive: true) {
                app.store.removeDocument(record.id); ThumbnailService.shared.invalidate(record.id); lib.refresh()
            }
        }
    }
    private func flatten(_ nodes: [CollectionNode]) -> [CollectionNode] { nodes.flatMap { [$0] + flatten($0.children ?? []) } }
}

struct TagEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let record: DocumentRecord
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tags for “\(record.title)”").font(.headline)
            TextField("grammar, B2, exam", text: $text).textFieldStyle(.roundedBorder)
            Text("Separate tags with commas.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") {
                app.store.setTags(text.split(separator: ",").map { String($0) }, for: record.id); app.library.refresh(); dismiss()
            }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 380).onAppear { text = record.tags.joined(separator: ", ") }
    }
}

// MARK: Dashboard

struct DashboardView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var lib = AppState.shared.library
    @State private var tagEditing: DocumentRecord?
    @State private var recent: [(docID: String, title: String, page: Int, date: Date)] = []
    @State private var bookmarks: [BookmarkRecord] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Study Dashboard").font(.system(size: 28, weight: .semibold, design: .serif))
                    Text(summary).foregroundStyle(.secondary)
                }
                if lib.documents.isEmpty {
                    EmptyStateView(systemImage: "books.vertical", title: "Welcome to PDF Study", message: "Add a German textbook to begin. Drop a PDF into this window or press ⌘O.")
                    HStack { Spacer(); Button("Open PDF…") { app.openPanel() }.buttonStyle(.borderedProminent).controlSize(.large); Spacer() }
                } else {
                    section("Continue Reading") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 20) {
                                ForEach(lib.continueReading.prefix(8)) { d in DocumentCard(record: d, tagEditing: $tagEditing).frame(width: 170) }
                            }.padding(.vertical, 10).padding(.horizontal, 4)
                        }
                    }
                    if !recent.isEmpty {
                        section("Recently Studied Pages") {
                            VStack(spacing: 0) {
                                ForEach(Array(recent.enumerated()), id: \.offset) { _, r in
                                    Button { openPage(r.docID, r.page) } label: {
                                        HStack { Image(systemName: "doc.text").foregroundStyle(.secondary); Text(r.title).lineLimit(1); Spacer()
                                            Text("p. \(r.page + 1)").monospacedDigit().foregroundStyle(.secondary)
                                            Text(r.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.tertiary).frame(width: 110, alignment: .trailing) }
                                        .padding(.vertical, 7).padding(.horizontal, 12).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    Divider()
                                }
                            }.card(padding: 0)
                        }
                    }
                    let favs = lib.documents.filter { $0.isFavorite }
                    if !favs.isEmpty {
                        section("Favorites") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], spacing: 18) { ForEach(favs) { DocumentCard(record: $0, tagEditing: $tagEditing) } }
                        }
                    }
                    if !bookmarks.isEmpty {
                        section("Important Bookmarks") {
                            VStack(spacing: 0) {
                                ForEach(bookmarks.prefix(10)) { b in
                                    Button { openPage(b.docID, b.page) } label: {
                                        HStack { Image(systemName: "bookmark.fill").foregroundStyle(Color.accentColor); Text(b.name); Spacer()
                                            Text(lib.documents.first { $0.id == b.docID }?.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            Text("p. \(b.page + 1)").monospacedDigit().foregroundStyle(.secondary) }
                                        .padding(.vertical, 7).padding(.horizontal, 12).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    Divider()
                                }
                            }.card(padding: 0)
                        }
                    }
                }
            }.padding(28)
        }
        .sheet(item: $tagEditing) { TagEditor(record: $0) }
        .onAppear(perform: reload)
        .onChange(of: lib.documents.count) { _, _ in reload() }
        .onChange(of: app.activeTab) { _, _ in reload() }
    }

    private func reload() { recent = app.store.recentPages(); bookmarks = app.store.bookmarks(docID: nil).sorted { $0.createdAt > $1.createdAt } }

    private var summary: String {
        let read = lib.documents.reduce(0) { $0 + $1.pagesRead }
        let review = lib.allVocabulary.filter { $0.needsReview }.count
        return "\(lib.documents.count) documents · \(read) pages read · \(lib.allVocabulary.count) vocabulary entries" + (review > 0 ? " · \(review) to review" : "")
    }

    private func openPage(_ docID: String, _ page: Int) {
        guard let r = app.store.document(id: docID) else { return }
        app.open(record: r)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { app.activeSession?.goTo(page: page) }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { SectionHeader(title: title); content() }
    }
}
