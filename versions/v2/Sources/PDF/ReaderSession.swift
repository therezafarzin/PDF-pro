import AppKit
import PDFKit
import Combine

struct OutlineNode: Identifiable {
    let id = UUID()
    let label: String
    let destination: PDFDestination?
    var children: [OutlineNode]?
}

struct PDFSearchResult: Identifiable {
    let id = UUID()
    let selection: PDFSelection
    let page: Int
    let context: String
}

enum SidebarTab: String, CaseIterable, Identifiable {
    case pages, outline, bookmarks, annotations, notes, vocabulary
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pages: return "Pages"; case .outline: return "Contents"; case .bookmarks: return "Bookmarks"
        case .annotations: return "Annotations"; case .notes: return "Page Note"; case .vocabulary: return "Vocabulary"
        }
    }
    var systemImage: String {
        switch self {
        case .pages: return "square.grid.2x2"; case .outline: return "list.bullet.indent"; case .bookmarks: return "bookmark"
        case .annotations: return "text.bubble"; case .notes: return "note.text"; case .vocabulary: return "character.book.closed"
        }
    }
}

/// Everything about one open document (one tab): the PDF, annotations, reading position, search, study data.
@MainActor
final class ReaderSession: NSObject, ObservableObject, Identifiable, PDFDocumentDelegate {
    enum LoadState: Equatable { case loading, ready, needsPassword, failed(String) }

    var id: String { record.id }
    private(set) var record: DocumentRecord
    private(set) var url: URL
    let store: Store
    let controller: AnnotationController

    @Published var loadState: LoadState = .loading
    @Published private(set) var document: PDFDocument?
    weak var pdfView: StudyPDFView?

    // View state (persisted per document)
    @Published var currentPage = 0
    @Published var scale: CGFloat = 1
    @Published var fitMode = "width"
    @Published var displayMode: PDFDisplayMode = .singlePageContinuous
    @Published var displaysAsBook = false
    @Published var sidebarVisible = true
    @Published var sidebarTab: SidebarTab = .pages
    @Published var inspectorVisible = false
    @Published var readingMode = "normal"
    @Published var rulerVisible = false

    // Study data
    @Published var bookmarks: [BookmarkRecord] = []
    @Published var pageNote = ""
    @Published var vocabulary: [VocabularyEntry] = []
    @Published var readPageCount = 0
    @Published var outline: [OutlineNode] = []
    @Published var vocabularyDraft: VocabularyEntry?
    @Published var errorMessage: String?

    // Search
    @Published var searchVisible = false
    @Published var searchText = ""
    @Published var searchResults: [PDFSearchResult] = []
    @Published var annotationHits: [SearchHit] = []
    @Published var searchIndex = 0
    @Published var isSearching = false

    private var rotations: [Int: Int] = [:]
    private var isRestoring = true
    private var programmaticZoom = false
    private var saveTask: Task<Void, Never>?
    private var dwellTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var noteTask: Task<Void, Never>?
    private var seenKeys = Set<String>()

    init(record: DocumentRecord, url: URL, store: Store) {
        self.record = record
        self.url = url
        self.store = store
        self.controller = AnnotationController(store: store, docID: record.id)
        super.init()
        controller.geometryProvider = { [weak self] i in self?.pdfView?.geometry(forIndex: i) }
        controller.zoomProvider = { [weak self] in self?.pdfView?.scaleFactor ?? 1 }
        controller.visiblePageProvider = { [weak self] in self?.currentPage ?? 0 }
    }

    // MARK: Loading

    func load() {
        loadState = .loading
        guard let doc = PDFDocument(url: url) else {
            loadState = .failed("This file could not be opened. It may be damaged or not a PDF.")
            return
        }
        doc.delegate = self
        finishLoading(doc)
    }

    func unlock(password: String) {
        guard let doc = document else { return }
        if doc.unlock(withPassword: password) { finishLoading(doc) } else { errorMessage = "That password is incorrect." }
    }

    private func finishLoading(_ doc: PDFDocument) {
        document = doc
        if doc.isLocked { loadState = .needsPassword; return }
        guard doc.pageCount > 0 else { loadState = .failed("This PDF has no readable pages."); return }
        if record.pageCount != doc.pageCount {
            record.pageCount = doc.pageCount
            try? store.upsertDocument(record)
        }
        let pos = store.loadPosition(docID: record.id)
        let pref = pos ?? defaultPosition()
        sidebarVisible = pref.sidebarVisible
        sidebarTab = SidebarTab(rawValue: pref.sidebarTab) ?? .pages
        inspectorVisible = pref.inspectorVisible
        readingMode = pref.readingMode
        rotations = pref.rotations
        for (i, r) in rotations { doc.page(at: i)?.rotation = r }
        loadStudyData()
        buildOutline()
        store.markOpened(record.id)
        loadState = .ready
    }

    private func defaultPosition() -> ReadingPosition {
        var p = ReadingPosition()
        let d = UserDefaults.standard
        p.fitMode = d.string(forKey: "defaultFitMode") ?? "width"
        p.displayMode = d.object(forKey: "defaultDisplayMode") as? Int ?? PDFDisplayMode.singlePageContinuous.rawValue
        return p
    }

    // MARK: View attachment & position restore

    func attach(_ view: StudyPDFView) {
        pdfView = view
        view.controller = controller
        view.document = document
        view.onAddVocabulary = { [weak self] sel in self?.beginVocabulary(from: sel) }
        view.onAddBookmark = { [weak self] in self?.addBookmark(name: nil) }
        view.onSpeak = { Speaker.shared.speakGerman($0) }
        installObservers(view)
        restorePosition()
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }   // lets the thumbnail sidebar bind to the view
    }

    private func installObservers(_ view: StudyPDFView) {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pageDidChange() }
            },
            nc.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scale = view.scaleFactor
                    if !self.programmaticZoom && !self.isRestoring { self.fitMode = "custom" }
                    self.scheduleSave()
                }
            },
            nc.addObserver(forName: .PDFViewDisplayModeChanged, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleSave() }
            },
            nc.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.fitMode != "custom" { self?.applyFit() } }
            },
        ]
        view.postsFrameChangedNotifications = true
        if let clip = findScrollView(in: view)?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleSave() }
            })
        }
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView { return s }
        for sub in view.subviews { if let s = findScrollView(in: sub) { return s } }
        return nil
    }

    /// Restores display mode, zoom and the exact top-left reading point.
    /// Two passes: PDFKit finishes layout asynchronously, so the destination is re-applied once more.
    func restorePosition() {
        guard let view = pdfView, let doc = document else { return }
        isRestoring = true
        let pos = store.loadPosition(docID: record.id) ?? defaultPosition()
        view.displayMode = PDFDisplayMode(rawValue: pos.displayMode) ?? .singlePageContinuous
        view.displaysAsBook = pos.displaysAsBook
        displayMode = view.displayMode; displaysAsBook = pos.displaysAsBook
        fitMode = pos.fitMode
        programmaticZoom = true
        if fitMode == "custom" { view.scaleFactor = CGFloat(pos.scale) } else { applyFit() }
        programmaticZoom = false
        scale = view.scaleFactor

        let pageIndex = min(max(pos.pageIndex, 0), doc.pageCount - 1)
        func jump() {
            guard let page = doc.page(at: pageIndex) else { return }
            view.go(to: PDFDestination(page: page, at: CGPoint(x: pos.pointX, y: pos.pointY)))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { jump() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            jump()
            self?.currentPage = pageIndex
            self?.pageDidChange(initial: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.isRestoring = false }
        }
    }

    func capturePosition() -> ReadingPosition? {
        guard let view = pdfView, let doc = document, let dest = view.currentDestination, let page = dest.page else { return nil }
        var p = ReadingPosition()
        p.pageIndex = doc.index(for: page)
        p.pointX = dest.point.x; p.pointY = dest.point.y
        p.scale = Double(view.scaleFactor)
        p.fitMode = fitMode
        p.displayMode = view.displayMode.rawValue
        p.displaysAsBook = view.displaysAsBook
        p.sidebarVisible = sidebarVisible; p.sidebarTab = sidebarTab.rawValue
        p.inspectorVisible = inspectorVisible; p.readingMode = readingMode
        p.lastSelectedPage = currentPage
        p.rotations = rotations
        p.updatedAt = Date()
        return p
    }

    func scheduleSave() {
        guard !isRestoring else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !Task.isCancelled { self?.savePositionNow() }
        }
    }

    func savePositionNow() {
        guard !isRestoring, loadState == .ready, let p = capturePosition() else { return }
        store.savePosition(p, docID: record.id)
    }

    /// Called when the tab is closed or the app quits.
    func close() {
        isRestoring = false
        savePositionNow()
        controller.endEditing()
        controller.flushPending()
        controller.createSnapshot(label: "Session end")
        saveTask?.cancel(); dwellTask?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        document?.cancelFindString()
        FileAccess.end(url)
        pdfView?.document = nil
    }

    // MARK: Paging

    private func pageDidChange(initial: Bool = false) {
        guard let view = pdfView, let doc = document, let page = view.currentPage else { return }
        let idx = doc.index(for: page)
        if idx != currentPage || initial { currentPage = idx; loadPageNote() }
        scheduleSave()
        dwellTask?.cancel()
        let docID = record.id
        dwellTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.store.markPageRead(docID: docID, page: idx)
            self.store.recordVisit(docID: docID, page: idx)
            self.readPageCount = self.store.readPages(docID: docID).count
        }
    }

    func goTo(page index: Int) {
        guard let doc = document, let page = doc.page(at: min(max(index, 0), doc.pageCount - 1)) else { return }
        pdfView?.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .cropBox).maxY)))
    }
    func nextPage() { pdfView?.goToNextPage(nil) }
    func previousPage() { pdfView?.goToPreviousPage(nil) }
    func firstPage() { goTo(page: 0) }
    func lastPage() { goTo(page: (document?.pageCount ?? 1) - 1) }
    func go(to destination: PDFDestination) { pdfView?.go(to: destination) }

    func reveal(_ m: AnnotationModel) {
        guard let page = document?.page(at: m.pageIndex) else { return }
        pdfView?.go(to: m.occupiedRect.insetBy(dx: -40, dy: -60), on: page)
        controller.select([m.id])
    }

    // MARK: Zoom & layout

    private func setScale(_ s: CGFloat) {
        programmaticZoom = true
        pdfView?.scaleFactor = min(max(s, 0.1), 8)
        programmaticZoom = false
        scale = pdfView?.scaleFactor ?? s
    }

    func zoomIn() { fitMode = "custom"; setScale((pdfView?.scaleFactor ?? 1) * 1.15); scheduleSave() }
    func zoomOut() { fitMode = "custom"; setScale((pdfView?.scaleFactor ?? 1) / 1.15); scheduleSave() }
    func setZoom(percent: Double) { fitMode = "custom"; setScale(CGFloat(percent / 100)); scheduleSave() }
    func actualSize() { setZoom(percent: 100) }
    func fitWidth() { fitMode = "width"; applyFit(); scheduleSave() }
    func fitPage() { fitMode = "page"; applyFit(); scheduleSave() }

    func applyFit() {
        guard let view = pdfView, let doc = document, let page = view.currentPage ?? doc.page(at: 0) else { return }
        let g = PageGeometry(box: page.bounds(for: .cropBox), rotation: page.rotation)
        let across: CGFloat = (view.displayMode == .twoUp || view.displayMode == .twoUpContinuous) ? 2 : 1
        let margin: CGFloat = 24
        let availW = max(view.bounds.width - margin * 2, 50)
        let availH = max(view.bounds.height - margin * 2, 50)
        let sw = availW / (g.displaySize.width * across)
        let sh = availH / g.displaySize.height
        setScale(fitMode == "page" ? min(sw, sh) : sw)
    }

    func setDisplay(mode: PDFDisplayMode, book: Bool? = nil) {
        guard let view = pdfView else { return }
        let dest = view.currentDestination
        view.displayMode = mode
        if let b = book { view.displaysAsBook = b }
        displayMode = mode; displaysAsBook = view.displaysAsBook
        if fitMode != "custom" { applyFit() }
        if let dest { view.go(to: dest) }
        scheduleSave()
    }

    func rotate(by degrees: Int, allPages: Bool) {
        guard let doc = document, let view = pdfView else { return }
        let targets = allPages ? Array(0..<doc.pageCount) : [currentPage]
        for i in targets {
            guard let p = doc.page(at: i) else { continue }
            p.rotation = ((p.rotation + degrees) % 360 + 360) % 360
            rotations[i] = p.rotation == 0 ? nil : p.rotation
        }
        view.rebuildOverlays()
        if fitMode != "custom" { applyFit() }
        scheduleSave()
    }

    func setReadingMode(_ mode: String) { readingMode = mode; scheduleSave() }

    // MARK: Outline

    private func buildOutline() {
        guard let root = document?.outlineRoot else { outline = []; return }
        func nodes(_ o: PDFOutline) -> [OutlineNode] {
            (0..<o.numberOfChildren).compactMap { i in
                guard let c = o.child(at: i) else { return nil }
                let kids = nodes(c)
                return OutlineNode(label: c.label ?? "Untitled", destination: c.destination, children: kids.isEmpty ? nil : kids)
            }
        }
        outline = nodes(root)
    }

    // MARK: Study data

    private func loadStudyData() {
        bookmarks = store.bookmarks(docID: record.id)
        vocabulary = store.vocabulary(docID: record.id)
        readPageCount = store.readPages(docID: record.id).count
        loadPageNote()
    }

    func addBookmark(name: String?) {
        let n = (name?.isEmpty == false ? name! : nil) ?? "Page \(currentPage + 1)"
        _ = store.addBookmark(docID: record.id, page: currentPage, name: n)
        bookmarks = store.bookmarks(docID: record.id)
    }
    func renameBookmark(_ b: BookmarkRecord, to name: String) { store.renameBookmark(b.id, name: name); bookmarks = store.bookmarks(docID: record.id) }
    func deleteBookmark(_ b: BookmarkRecord) { store.deleteBookmark(b.id); bookmarks = store.bookmarks(docID: record.id) }
    var currentPageBookmarked: Bool { bookmarks.contains { $0.page == currentPage } }

    func loadPageNote() { pageNote = store.pageNote(docID: record.id, page: currentPage)?.text ?? "" }
    func updatePageNote(_ text: String) {
        pageNote = text
        let page = currentPage, docID = record.id
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !Task.isCancelled { self?.store.savePageNote(docID: docID, page: page, text: text) }
        }
    }
    func flushPageNote() { noteTask?.cancel(); store.savePageNote(docID: record.id, page: currentPage, text: pageNote) }

    func toggleRead(page: Int) {
        let read = store.readPages(docID: record.id)
        if read.contains(page) { store.unmarkPageRead(docID: record.id, page: page) } else { store.markPageRead(docID: record.id, page: page) }
        readPageCount = store.readPages(docID: record.id).count
    }

    func beginVocabulary(from selection: PDFSelection) {
        var word = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let page = selection.pages.first.flatMap { document?.index(for: $0) } ?? currentPage
        var entry = VocabularyEntry(docID: record.id, page: page)
        let parts = word.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, let art = GermanArticle(rawValue: parts[0].lowercased()), art != .none { entry.article = art; word = parts[1] }
        entry.word = word
        if let p = selection.pages.first, let text = p.string, let r = (text as NSString).range(of: selection.string ?? "", options: []).nilIfNotFound {
            let sr = TextNormalizer.enclosingRange(in: text, around: r.location, paragraph: false)
            entry.example = (text as NSString).substring(with: sr).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        vocabularyDraft = entry
    }

    func saveVocabulary(_ entry: VocabularyEntry) {
        store.saveVocabulary(entry)
        vocabulary = store.vocabulary(docID: record.id)
        vocabularyDraft = nil
    }
    func deleteVocabulary(_ entry: VocabularyEntry) { store.deleteVocabulary(entry.id); vocabulary = store.vocabulary(docID: record.id) }

    // MARK: Search

    func runSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        document?.cancelFindString()
        searchResults = []; seenKeys = []; searchIndex = 0
        pdfView?.highlightedSelections = nil
        annotationHits = q.isEmpty ? [] : store.searchUser(q, docID: record.id)
        guard !q.isEmpty, let doc = document else { isSearching = false; return }
        isSearching = true
        doc.delegate = self
        doc.beginFindStrings(TextNormalizer.pdfFindVariants(q), withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    nonisolated func didMatchString(_ instance: PDFSelection) {
        MainActor.assumeIsolated {
            guard searchResults.count < 3000, let page = instance.pages.first, let doc = document else { return }
            let idx = doc.index(for: page)
            let b = instance.bounds(for: page)
            let key = "\(idx):\(Int(b.minX)):\(Int(b.minY))"
            guard seenKeys.insert(key).inserted else { return }
            let ctx = (instance.copy() as? PDFSelection) ?? instance
            ctx.extend(atStart: 24); ctx.extend(atEnd: 36)
            let text = (ctx.string ?? "").replacingOccurrences(of: "\n", with: " ")
            instance.color = NSColor.systemYellow.withAlphaComponent(0.6)
            searchResults.append(PDFSearchResult(selection: instance, page: idx, context: text))
            searchResults.sort { $0.page < $1.page }
            pdfView?.highlightedSelections = searchResults.map { $0.selection }
            if searchResults.count == 1 { focusResult(0) }
        }
    }

    nonisolated func documentDidEndDocumentFind(_ notification: Notification) {
        MainActor.assumeIsolated { isSearching = false }
    }

    func focusResult(_ i: Int) {
        guard searchResults.indices.contains(i) else { return }
        searchIndex = i
        let sel = searchResults[i].selection
        pdfView?.setCurrentSelection(sel, animate: true)
        pdfView?.go(to: sel)
    }
    func nextResult() { if !searchResults.isEmpty { focusResult((searchIndex + 1) % searchResults.count) } }
    func previousResult() { if !searchResults.isEmpty { focusResult((searchIndex - 1 + searchResults.count) % searchResults.count) } }
    func closeSearch() {
        searchVisible = false
        document?.cancelFindString()
        pdfView?.highlightedSelections = nil
    }
}

private extension NSRange {
    var nilIfNotFound: NSRange? { location == NSNotFound ? nil : self }
}
