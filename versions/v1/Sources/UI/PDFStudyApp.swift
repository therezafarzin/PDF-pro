import SwiftUI
import AppKit

@main
struct PDFStudyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppState.shared
    @StateObject private var shortcuts = ShortcutManager.shared
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accentHex") private var accentHex = "#3354CC"
    @AppStorage("density") private var densityRaw = Density.regular.rawValue

    var body: some Scene {
        Window("PDF Study", id: "main") {
            RootView()
                .environmentObject(app)
                .environmentObject(shortcuts)
                .environment(\.density, Density(rawValue: densityRaw) ?? .regular)
                .tint(RGBA(hex: accentHex)?.color ?? Theme.defaultAccent)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear { applyAppearance(); app.restoreSession() }
                .onChange(of: appearance) { _, _ in applyAppearance() }
                .onOpenURL { app.open(url: $0) }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands(app: app, shortcuts: shortcuts) }

        Settings {
            SettingsView().environmentObject(app).environmentObject(shortcuts)
        }
    }

    private func applyAppearance() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var app: AppState
    @ObservedObject var shortcuts: ShortcutManager

    private var session: ReaderSession? { app.activeSession }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open PDF…") { app.openPanel() }.appShortcut(.openPDF)
            Menu("Open Recent") {
                ForEach(app.library.continueReading.prefix(12)) { d in Button(d.title) { app.open(record: d) } }
            }
            Divider()
            Button("Close Tab") { app.closeActive() }.appShortcut(.closeTab).disabled(session == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Now") { app.saveNow() }.appShortcut(.save)
            Button("Export PDF…") { app.exportRequest = session }.appShortcut(.export).disabled(session == nil)
            Button("Version History…") { app.versionsRequest = session }.disabled(session == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { session?.printAnnotated() }.appShortcut(.print).disabled(session == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { undoOrSystem(redo: false) }.keyboardShortcut("z")
            Button("Redo") { undoOrSystem(redo: true) }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Document") { if let s = session { s.searchVisible = true } }.appShortcut(.find).disabled(session == nil)
            Button("Search Library") { app.activeTab = .library; app.library.fullTextSearch = true }.appShortcut(.findInLibrary)
            Divider()
            Button("Duplicate Annotation") { session?.controller.duplicateSelection() }.appShortcut(.duplicate)
            Button("Select All Annotations on Page") { session.map { $0.controller.selectAll(page: $0.currentPage) } }.appShortcut(.selectAllAnnotations)
            Button("Group") { session?.controller.group() }.appShortcut(.group)
            Button("Bring to Front") { session?.controller.reorder(.front) }.appShortcut(.bringToFront)
            Button("Send to Back") { session?.controller.reorder(.back) }.appShortcut(.sendToBack)
            Button("Lock / Unlock") { session?.controller.toggleLock() }.appShortcut(.lockAnnotation)
        }
        CommandGroup(replacing: .toolbar) {
            Button("Toggle Sidebar") { withAnimation(Theme.animation) { session?.sidebarVisible.toggle() } }.appShortcut(.toggleSidebar)
            Button("Toggle Inspector") { withAnimation(Theme.animation) { session?.inspectorVisible.toggle() } }.appShortcut(.toggleInspector)
            Divider()
            Button("Zoom In") { session?.zoomIn() }.appShortcut(.zoomIn)
            Button("Zoom Out") { session?.zoomOut() }.appShortcut(.zoomOut)
            Button("Actual Size") { session?.actualSize() }.appShortcut(.actualSize)
            Button("Fit Page") { session?.fitPage() }.appShortcut(.fitPage)
            Button("Fit Width") { session?.fitWidth() }.appShortcut(.fitWidth)
            Divider()
            Button("Single Page") { session?.setDisplay(mode: .singlePage) }.appShortcut(.singlePage)
            Button("Continuous Scroll") { session?.setDisplay(mode: .singlePageContinuous) }.appShortcut(.continuousScroll)
            Button("Two Pages") { session?.setDisplay(mode: .twoUpContinuous) }.appShortcut(.twoPage)
            Divider()
            Button("Night Mode") { session?.setReadingMode(session?.readingMode == "night" ? "normal" : "night") }.appShortcut(.nightMode)
            Button("Reading Ruler") { session?.rulerVisible.toggle() }.appShortcut(.ruler)
            Button("Distraction-Free Mode") { withAnimation(Theme.animation) { app.focusMode.toggle() } }.appShortcut(.focusMode)
            Button("Enter Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }.appShortcut(.fullScreen)
        }
        CommandMenu("Navigate") {
            Button("Next Page") { session?.nextPage() }.appShortcut(.nextPage)
            Button("Previous Page") { session?.previousPage() }.appShortcut(.previousPage)
            Button("Go to Page…") {
                if let s = session, let t = Prompt.text(title: "Go to Page", message: "Page number (1–\(s.document?.pageCount ?? 1))"), let n = Int(t) { s.goTo(page: n - 1) }
            }.appShortcut(.goToPage)
            Divider()
            Button("Rotate Right") { session?.rotate(by: 90, allPages: false) }.appShortcut(.rotateRight)
            Button("Rotate Left") { session?.rotate(by: -90, allPages: false) }.appShortcut(.rotateLeft)
            Divider()
            Button("Next Tab") { app.cycleTab(1) }.appShortcut(.nextTab)
            Button("Previous Tab") { app.cycleTab(-1) }.appShortcut(.previousTab)
            Button("Library") { app.activeTab = .library }
        }
        CommandMenu("Tools") {
            tool("Select", .select, .selectTool)
            Divider()
            tool("Highlight", .highlight, .highlight)
            tool("Underline", .underline, .underline)
            tool("Strikethrough", .strikeThrough, .strikethrough)
            tool("Squiggly Underline", .squiggly, .squiggly)
            Divider()
            tool("Text Box", .textBox, .textBox)
            tool("Sticky Note", .stickyNote, .stickyNote)
            tool("Pen", .ink, .pen)
            tool("Rectangle", .rectangle, .rectangle)
            tool("Ellipse", .ellipse, .ellipse)
            tool("Arrow", .arrow, .arrow)
            tool("Line", .line, .line)
            tool("Eraser", .eraser, .eraser)
        }
        CommandMenu("Study") {
            Button("Add Selection to Vocabulary") { session?.controller.tool = .vocabulary }.appShortcut(.addVocabulary).disabled(session == nil)
            Button("Speak Selection (German)") {
                if let t = session?.pdfView?.currentSelection?.string { Speaker.shared.speakGerman(t) }
            }.appShortcut(.speak).disabled(session == nil)
            Button("Bookmark This Page") { session?.addBookmark(name: nil) }.appShortcut(.bookmarkPage).disabled(session == nil)
            Divider()
            Button("Dashboard") { app.activeTab = .library; app.library.selection = .home }
        }
    }

    private func tool(_ title: String, _ tool: AnnotationTool, _ action: ShortcutAction) -> some View {
        Button(title) { session?.controller.tool = tool }.appShortcut(action).disabled(session == nil)
    }

    /// Cmd+Z goes to the annotation undo stack when a document is active.
    private func undoOrSystem(redo: Bool) {
        if let s = session { redo ? s.controller.redo() : s.controller.undo() }
        else { NSApp.sendAction(Selector(redo ? "redo:" : "undo:"), to: nil, from: nil) }
    }
}
