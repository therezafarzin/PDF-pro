import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var app: AppState
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if !app.focusMode { TabBarView() }
            ZStack {
                LibraryView().opacity(app.activeTab == .library ? 1 : 0).allowsHitTesting(app.activeTab == .library)
                ForEach(app.sessions) { s in
                    ReaderView(session: s)
                        .opacity(app.activeTab == .session(s.id) ? 1 : 0)
                        .allowsHitTesting(app.activeTab == .session(s.id))
                }
            }
            .overlay(alignment: .top) { NoticeBanner() }
            .overlay(alignment: .topTrailing) { if app.focusMode { FocusExitButton() } }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.pathExtension.lowercased() == "pdf" { Task { @MainActor in app.open(url: url) } }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Theme.radiusLarge).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.06)).padding(8).allowsHitTesting(false)
            }
        }
        .toolbar(id: "main") { MainToolbar() }
        .sheet(item: $app.exportRequest) { ExportSheet(session: $0) }
        .sheet(item: $app.versionsRequest) { VersionsSheet(session: $0) }
        .sheet(item: $app.toolRequest) { ToolHost(request: $0) }
        .alert("PDF Study", isPresented: Binding(get: { app.startupMessage != nil }, set: { if !$0 { app.startupMessage = nil } })) {
            Button("OK") { app.startupMessage = nil }
        } message: { Text(app.startupMessage ?? "") }
    }
}

struct NoticeBanner: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        if let n = app.notice {
            Label(n, systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule()).shadow(radius: 6, y: 2).padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct FocusExitButton: View {
    @EnvironmentObject var app: AppState
    @State private var hover = false
    var body: some View {
        Button { withAnimation(Theme.animation) { app.focusMode = false } } label: {
            Label("Exit Focus", systemImage: "arrow.down.right.and.arrow.up.left").labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless).padding(10).background(.regularMaterial, in: Circle()).padding(12)
        .opacity(hover ? 1 : 0.15).onHover { hover = $0 }.help("Exit distraction-free mode")
    }
}

// MARK: - Tabs

struct TabBarView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.density) private var density

    var body: some View {
        HStack(spacing: 4) {
            TabChip(title: "Library", systemImage: "books.vertical", active: app.activeTab == .library, closable: false) { app.activeTab = .library } close: {}
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(app.sessions) { s in
                        TabChip(title: s.record.title, systemImage: "doc.text", active: app.activeTab == .session(s.id), closable: true) {
                            app.activeTab = .session(s.id); app.persistSession()
                        } close: { app.close(s) }
                    }
                }
            }
            Button { app.openPanel() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).help("Open PDF")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 5 * density.scale)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct TabChip: View {
    let title: String, systemImage: String, active: Bool, closable: Bool
    let select: () -> Void, close: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 11)).foregroundStyle(active ? Color.accentColor : .secondary)
            Text(title).font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1).frame(maxWidth: 180)
            if closable {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.borderless).opacity(hover || active ? 0.8 : 0)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSmall + 1, style: .continuous)
            .fill(active ? Color.accentColor.opacity(0.14) : (hover ? Color.primary.opacity(0.06) : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hover = $0 }
        .animation(Theme.animation, value: active)
    }
}

// MARK: - Toolbar

struct MainToolbar: CustomizableToolbarContent {
    @EnvironmentObject var app: AppState

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "sidebar", placement: .navigation) { ReaderOnly { SidebarToggle(session: $0) } }
        ToolbarItem(id: "pages", placement: .navigation) { ReaderOnly { PageControls(session: $0) } }
        ToolbarItem(id: "zoom", placement: .principal) { ReaderOnly { ZoomControls(session: $0) } }
        ToolbarItem(id: "tools", placement: .principal) { ReaderOnly { AnnotationToolbar(session: $0) } }
        ToolbarItem(id: "view", placement: .primaryAction) { ReaderOnly { ViewMenu(session: $0) } }
        ToolbarItem(id: "study", placement: .primaryAction) { ReaderOnly { StudyControls(session: $0) } }
        ToolbarItem(id: "search", placement: .primaryAction) { ReaderOnly { SearchToggle(session: $0) } }
        ToolbarItem(id: "inspector", placement: .primaryAction) { ReaderOnly { InspectorToggle(session: $0) } }
    }
}

struct ReaderOnly<Content: View>: View {
    @EnvironmentObject var app: AppState
    let content: (ReaderSession) -> Content
    init(@ViewBuilder _ content: @escaping (ReaderSession) -> Content) { self.content = content }
    var body: some View {
        if let s = app.activeSession, !app.focusMode, s.loadState == .ready { content(s) }
    }
}

struct SidebarToggle: View {
    @ObservedObject var session: ReaderSession
    var body: some View {
        Button { withAnimation(Theme.animation) { session.sidebarVisible.toggle() } } label: { Image(systemName: "sidebar.leading") }
            .help("Toggle Sidebar")
    }
}

struct InspectorToggle: View {
    @ObservedObject var session: ReaderSession
    var body: some View {
        Button { withAnimation(Theme.animation) { session.inspectorVisible.toggle() } } label: { Image(systemName: "sidebar.trailing") }
            .help("Toggle Inspector")
    }
}

struct SearchToggle: View {
    @ObservedObject var session: ReaderSession
    var body: some View {
        Button { session.searchVisible.toggle() } label: { Image(systemName: "magnifyingglass") }.help("Find in Document")
    }
}

struct PageControls: View {
    @ObservedObject var session: ReaderSession
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 4) {
            Button { session.previousPage() } label: { Image(systemName: "chevron.up") }.help("Previous Page")
            TextField("", text: $text)
                .multilineTextAlignment(.center).frame(width: 44).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { if let n = Int(text) { session.goTo(page: n - 1) }; focused = false }
                .onChange(of: session.currentPage) { _, p in if !focused { text = String(p + 1) } }
                .onAppear { text = String(session.currentPage + 1) }
            Text("/ \(session.document?.pageCount ?? 0)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Button { session.nextPage() } label: { Image(systemName: "chevron.down") }.help("Next Page")
        }
    }
}

struct ZoomControls: View {
    @ObservedObject var session: ReaderSession
    var body: some View {
        HStack(spacing: 2) {
            Button { session.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom Out")
            Menu {
                ForEach([50, 75, 100, 125, 135, 150, 200, 300], id: \.self) { p in Button("\(p)%") { session.setZoom(percent: Double(p)) } }
                Divider()
                Button("Fit Width") { session.fitWidth() }
                Button("Fit Page") { session.fitPage() }
            } label: {
                Text(session.fitMode == "width" ? "Fit Width" : session.fitMode == "page" ? "Fit Page" : "\(Int((session.scale * 100).rounded()))%")
                    .font(.callout.monospacedDigit()).frame(minWidth: 62)
            }
            .menuStyle(.borderlessButton).fixedSize()
            Button { session.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom In")
        }
    }
}

struct ViewMenu: View {
    @ObservedObject var session: ReaderSession
    @EnvironmentObject var app: AppState
    var body: some View {
        Menu {
            Section("Layout") {
                Button("Single Page") { session.setDisplay(mode: .singlePage) }
                Button("Continuous Scroll") { session.setDisplay(mode: .singlePageContinuous) }
                Button("Two Pages") { session.setDisplay(mode: .twoUp) }
                Button("Two Pages, Continuous") { session.setDisplay(mode: .twoUpContinuous) }
                Toggle("Book Layout (cover alone)", isOn: Binding(get: { session.displaysAsBook }, set: { session.setDisplay(mode: session.displayMode, book: $0) }))
            }
            Section("Rotate") {
                Button("Rotate Page Right") { session.rotate(by: 90, allPages: false) }
                Button("Rotate Page Left") { session.rotate(by: -90, allPages: false) }
                Button("Rotate All Pages Right") { session.rotate(by: 90, allPages: true) }
            }
            Section("Reading") {
                Picker("Reading Mode", selection: Binding(get: { session.readingMode }, set: { session.setReadingMode($0) })) {
                    Text("Normal").tag("normal"); Text("Sepia").tag("sepia"); Text("Night").tag("night")
                }
                Toggle("Reading Ruler", isOn: $session.rulerVisible)
                Button("Distraction-Free Mode") { withAnimation(Theme.animation) { app.focusMode = true } }
                Button("Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
            }
        } label: { Image(systemName: "textformat.size") }
        .help("View Options")
    }
}

struct StudyControls: View {
    @ObservedObject var session: ReaderSession
    var body: some View {
        HStack(spacing: 2) {
            Button { session.addBookmark(name: nil) } label: { Image(systemName: session.currentPageBookmarked ? "bookmark.fill" : "bookmark") }
                .help("Bookmark This Page")
            Button { session.controller.tool = .vocabulary } label: {
                Image(systemName: "character.book.closed").foregroundStyle(session.controller.tool == .vocabulary ? Color.accentColor : .primary)
            }.help("Vocabulary: select a word to add it")
            Button { if let t = session.pdfView?.currentSelection?.string { Speaker.shared.speakGerman(t) } } label: { Image(systemName: "speaker.wave.2") }
                .help("Speak Selection (German)")
        }
    }
}
