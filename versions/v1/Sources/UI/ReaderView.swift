import SwiftUI
import PDFKit

struct ReaderPDFView: NSViewRepresentable {
    @ObservedObject var session: ReaderSession
    func makeNSView(context: Context) -> StudyPDFView {
        let v = StudyPDFView(frame: .zero)
        session.attach(v)
        return v
    }
    func updateNSView(_ nsView: StudyPDFView, context: Context) {
        nsView.backgroundColor = session.readingMode == "sepia"
            ? NSColor(srgbRed: 0.93, green: 0.89, blue: 0.80, alpha: 1)
            : NSColor.underPageBackgroundColor
    }
}

struct ReaderView: View {
    @ObservedObject var session: ReaderSession
    @EnvironmentObject var app: AppState
    @State private var password = ""

    var body: some View {
        switch session.loadState {
        case .loading: ProgressView("Opening…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let msg):
            VStack(spacing: 14) {
                EmptyStateView(systemImage: "exclamationmark.triangle", title: "Can’t open this document", message: msg)
                Button("Close Tab") { app.close(session) }
            }
        case .needsPassword:
            VStack(spacing: 12) {
                Image(systemName: "lock.doc").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                Text("This PDF is password protected").font(.headline)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder).frame(width: 240).onSubmit { session.unlock(password: password) }
                if let e = session.errorMessage { Text(e).foregroundStyle(.red).font(.caption) }
                Button("Unlock") { session.unlock(password: password) }.buttonStyle(.borderedProminent)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready: content
        }
    }

    private var content: some View {
        HStack(spacing: 0) {
            if session.sidebarVisible && !app.focusMode {
                SidebarView(session: session).frame(width: Theme.sidebarWidth).transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            VStack(spacing: 0) {
                if session.searchVisible && !app.focusMode { SearchPanel(session: session); Divider() }
                ZStack {
                    ReaderPDFView(session: session)
                        .modifier(ReadingModeEffect(mode: session.readingMode))
                    if session.rulerVisible { ReadingRuler() }
                }
                if !app.focusMode { StatusBar(session: session) }
            }
            if session.inspectorVisible && !app.focusMode {
                Divider()
                InspectorView(session: session, controller: session.controller).frame(width: Theme.inspectorWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Theme.animation, value: session.sidebarVisible)
        .animation(Theme.animation, value: session.inspectorVisible)
        .sheet(item: $session.vocabularyDraft) { entry in
            VocabularyEditor(entry: entry, isNew: true) { session.saveVocabulary($0); session.controller.tool = .select }
                onCancel: { session.vocabularyDraft = nil; session.controller.tool = .select }
        }
        .onDisappear { session.flushPageNote() }
    }
}

struct ReadingModeEffect: ViewModifier {
    let mode: String
    func body(content: Content) -> some View {
        switch mode {
        case "night": content.colorInvert().hueRotation(.degrees(180)).brightness(-0.05)
        case "sepia": content.colorMultiply(Color(red: 1, green: 0.95, blue: 0.84))
        default: content
        }
    }
}

struct ReadingRuler: View {
    @State private var y: CGFloat = 200
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // dim above & below a clear band that follows the pointer
                VStack(spacing: 0) {
                    Color.black.opacity(0.30).frame(height: max(0, y - 23))
                    Color.clear.frame(height: 46)
                    Color.black.opacity(0.30)
                }
            }
            .allowsHitTesting(false)
            .frame(width: geo.size.width, height: geo.size.height)
            .background(MouseTracker { p in y = min(max(geo.size.height - p.y, 0), geo.size.height) })
        }
    }
}

struct MouseTracker: NSViewRepresentable {
    let onMove: (CGPoint) -> Void
    func makeNSView(context: Context) -> NSView { let v = TrackView(); v.onMove = onMove; return v }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? TrackView)?.onMove = onMove }
    final class TrackView: NSView {
        var onMove: ((CGPoint) -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in
                guard let self, e.window === self.window else { return e }
                self.onMove?(self.convert(e.locationInWindow, from: nil)); return e
            }
            window?.acceptsMouseMovedEvents = true
        }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct StatusBar: View {
    @ObservedObject var session: ReaderSession
    @ObservedObject var controller: AnnotationController
    init(session: ReaderSession) { self.session = session; self.controller = session.controller }
    var body: some View {
        HStack(spacing: 14) {
            Text("Page \(session.currentPage + 1) of \(session.document?.pageCount ?? 0)").monospacedDigit()
            Text("\(session.readPageCount) read").foregroundStyle(.secondary)
            ProgressView(value: Double(session.readPageCount), total: Double(max(session.document?.pageCount ?? 1, 1))).frame(width: 90)
            Spacer()
            switch controller.saveState {
            case .saved(let d): Label("Saved \(d.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            case .saving: Label("Saving…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
            case .failed(let m): Label("Not saved: \(m)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).help(m)
            }
            Text("\(controller.all.count) annotations").foregroundStyle(.secondary)
        }
        .font(.system(size: 11)).padding(.horizontal, 14).padding(.vertical, 5)
        .background(.bar).overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Annotation toolbar

struct ToolButton: View {
    let tool: AnnotationTool
    @ObservedObject var controller: AnnotationController
    var body: some View {
        Button { controller.tool = controller.tool == tool && tool != .select ? .select : tool } label: {
            Image(systemName: tool.systemImage).frame(width: 22, height: 20)
                .foregroundStyle(controller.tool == tool ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(controller.tool == tool ? Color.accentColor : .clear))
        }
        .help(tool.title)
    }
}

struct AnnotationToolbar: View {
    @ObservedObject var session: ReaderSession
    @ObservedObject var controller: AnnotationController
    init(session: ReaderSession) { self.session = session; self.controller = session.controller }

    var body: some View {
        HStack(spacing: 2) {
            ToolButton(tool: .select, controller: controller)
            Divider().frame(height: 16)
            ToolButton(tool: .highlight, controller: controller)
            Menu {
                ForEach(StudyCategory.allCases) { c in
                    Button { controller.setStudyCategory(c); controller.tool = .highlight } label: {
                        Label(c.title, systemImage: controller.studyCategory == c ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
                Divider()
                Text("Custom colors: Inspector")
            } label: {
                Circle().fill(controller.markupColor.color).frame(width: 11, height: 11).overlay(Circle().stroke(Color.primary.opacity(0.3)))
            }.menuStyle(.borderlessButton).fixedSize().help("Highlight category & color")
            ToolButton(tool: .underline, controller: controller)
            ToolButton(tool: .strikeThrough, controller: controller)
            ToolButton(tool: .squiggly, controller: controller)
            Divider().frame(height: 16)
            ToolButton(tool: .textBox, controller: controller)
            ToolButton(tool: .stickyNote, controller: controller)
            Menu {
                ForEach([AnnotationTool.ink, .pencil, .eraser], id: \.self) { t in Button { controller.tool = t } label: { Label(t.title, systemImage: t.systemImage) } }
            } label: { Image(systemName: [AnnotationTool.ink, .pencil, .eraser].contains(controller.tool) ? controller.tool.systemImage : "pencil.tip") }
                .menuStyle(.borderlessButton).fixedSize().help("Draw")
            Menu {
                ForEach([AnnotationTool.rectangle, .ellipse, .line, .arrow], id: \.self) { t in Button { controller.tool = t } label: { Label(t.title, systemImage: t.systemImage) } }
            } label: { Image(systemName: [AnnotationTool.rectangle, .ellipse, .line, .arrow].contains(controller.tool) ? controller.tool.systemImage : "square.on.circle") }
                .menuStyle(.borderlessButton).fixedSize().help("Shapes")
            Divider().frame(height: 16)
            Button { controller.undo() } label: { Image(systemName: "arrow.uturn.backward") }.help("Undo")
            Button { controller.redo() } label: { Image(systemName: "arrow.uturn.forward") }.help("Redo")
        }
    }
}

// MARK: - Search

struct SearchPanel: View {
    @ObservedObject var session: ReaderSession
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in document, notes and annotations", text: $session.searchText)
                    .textFieldStyle(.plain).focused($focused).onSubmit { if session.searchResults.isEmpty { session.runSearch() } else { session.nextResult() } }
                    .onChange(of: session.searchText) { _, _ in session.runSearch() }
                if session.isSearching { ProgressView().controlSize(.small) }
                Text(session.searchResults.isEmpty ? "No results" : "\(session.searchIndex + 1) of \(session.searchResults.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { session.previousResult() } label: { Image(systemName: "chevron.up") }.disabled(session.searchResults.isEmpty)
                Button { session.nextResult() } label: { Image(systemName: "chevron.down") }.disabled(session.searchResults.isEmpty)
                Button { session.closeSearch() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            if !session.searchResults.isEmpty || !session.annotationHits.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(session.searchResults.prefix(200).enumerated()), id: \.element.id) { i, r in
                            Button { session.focusResult(i) } label: {
                                HStack { Text("p. \(r.page + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                                    Text(r.context).lineLimit(1).font(.callout); Spacer() }
                                .padding(.horizontal, 14).padding(.vertical, 4).background(i == session.searchIndex ? Color.accentColor.opacity(0.14) : .clear).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        if !session.annotationHits.isEmpty {
                            Text("In your notes").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 8)
                            ForEach(session.annotationHits) { h in
                                Button { session.goTo(page: h.page) } label: {
                                    HStack { Text("p. \(h.page + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                                        Text(h.snippet.replacingOccurrences(of: "⟦", with: "").replacingOccurrences(of: "⟧", with: "")).lineLimit(1).font(.callout)
                                        Spacer(); Text(h.scope.rawValue).font(.caption2).foregroundStyle(.tertiary) }
                                    .padding(.horizontal, 14).padding(.vertical, 4).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.frame(maxHeight: 190)
            }
        }
        .background(.bar)
        .onAppear { focused = true }
    }
}
