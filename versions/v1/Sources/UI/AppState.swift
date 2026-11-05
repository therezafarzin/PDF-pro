import SwiftUI
import AppKit
import PDFKit
import Combine
import UniformTypeIdentifiers

enum TabSelection: Hashable { case library, session(String) }

enum SidebarItem: Hashable {
    case home, all, recent, favorites, pinned, vocabulary
    case collection(String), tag(String)
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case lastOpened, name, dateAdded, fileModified, size, progress
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lastOpened: return "Date Opened"; case .name: return "Name"; case .dateAdded: return "Date Added"
        case .fileModified: return "Date Modified"; case .size: return "Size"; case .progress: return "Progress"
        }
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    let store: Store
    @Published var documents: [DocumentRecord] = []
    @Published var collections: [CollectionNode] = []
    @Published var tags: [String] = []
    @Published var selection: SidebarItem = .home
    @Published var searchText = ""
    @Published var fullTextSearch = false
    @Published var sort: LibrarySort = .lastOpened
    @Published var ascending = false
    @Published var gridView = true
    @Published var hits: [SearchHit] = []
    @Published var allVocabulary: [VocabularyEntry] = []

    init(store: Store) { self.store = store; refresh() }

    func refresh() {
        documents = store.allDocuments()
        collections = store.collectionTree()
        tags = store.allTags()
        allVocabulary = store.vocabulary()
    }

    var visible: [DocumentRecord] {
        var list = documents
        switch selection {
        case .home, .all, .vocabulary: break
        case .recent: list = list.filter { $0.lastOpenedAt != nil }
        case .favorites: list = list.filter { $0.isFavorite }
        case .pinned: list = list.filter { $0.isPinned }
        case .collection(let id):
            let ids = store.documentIDs(inCollection: id); list = list.filter { ids.contains($0.id) }
        case .tag(let t): list = list.filter { $0.tags.contains(t) }
        }
        let q = TextNormalizer.fold(searchText.trimmingCharacters(in: .whitespaces))
        if !q.isEmpty && !fullTextSearch {
            list = list.filter { TextNormalizer.fold($0.title).contains(q) || $0.tags.contains { TextNormalizer.fold($0).contains(q) } }
        }
        list.sort { a, b in
            let result: Bool
            switch sort {
            case .name: result = a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .dateAdded: result = a.addedAt < b.addedAt
            case .fileModified: result = (a.fileModifiedAt ?? .distantPast) < (b.fileModifiedAt ?? .distantPast)
            case .size: result = a.fileSize < b.fileSize
            case .progress: result = a.progress < b.progress
            case .lastOpened: result = (a.lastOpenedAt ?? .distantPast) < (b.lastOpenedAt ?? .distantPast)
            }
            // pinned first, always
            if a.isPinned != b.isPinned { return a.isPinned }
            return ascending ? result : !result
        }
        return list
    }

    var continueReading: [DocumentRecord] {
        documents.filter { $0.lastOpenedAt != nil }.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
    }

    func runFullTextSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard fullTextSearch, !q.isEmpty else { hits = []; return }
        hits = store.searchPDF(q) + store.searchUser(q)
    }

    func toggleFavorite(_ d: DocumentRecord) { store.setFavorite(d.id, !d.isFavorite); refresh() }
    func togglePinned(_ d: DocumentRecord) { store.setPinned(d.id, !d.isPinned); refresh() }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let store: Store
    let backups = BackupManager()
    let library: LibraryModel
    let indexer: PDFTextIndexer

    @Published var sessions: [ReaderSession] = []
    @Published var activeTab: TabSelection = .library
    @Published var focusMode = false
    @Published var notice: String?
    @Published var exportRequest: ReaderSession?
    @Published var versionsRequest: ReaderSession?
    @Published var startupMessage: String?

    private var backupTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init() {
        var message: String?
        var s: Store
        do { s = try Store() } catch {
            // Never lose data silently: fall back to an in-memory store and tell the user.
            message = "The library database could not be opened (\(error)). Changes in this session will not be saved. Backups are in Application Support/PDF Study/Backups."
            s = try! Store(inMemory: true)
        }
        store = s
        library = LibraryModel(store: s)
        indexer = PDFTextIndexer(store: s)
        startupMessage = message

        let crashed = s.value(for: "clean_exit") == "0"
        s.setValue("0", for: "clean_exit")
        if crashed {
            startupMessage = (startupMessage ?? "") + "PDF Study did not quit normally last time. All annotations were saved continuously and your open documents have been restored."
            _ = try? backups.backup(s, label: "post-crash")
        }
        library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        indexer.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        _ = try? backups.backup(s, label: "launch")
        let minutes = max(UserDefaults.standard.integer(forKey: "backupIntervalMinutes"), 5)
        backupTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sessions.forEach { $0.controller.flushPending(); $0.savePositionNow() }
                _ = try? self.backups.backup(self.store, label: "auto")
            }
        }
    }

    var activeSession: ReaderSession? {
        if case .session(let id) = activeTab { return sessions.first { $0.id == id } }
        return nil
    }

    // MARK: Opening

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose PDF files to open"
        if panel.runModal() == .OK { panel.urls.forEach { open(url: $0) } }
    }

    func open(url: URL) {
        if let s = sessions.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { activeTab = .session(s.id); return }
        Task {
            do {
                let record = try await DocumentService.register(url: url, store: store)
                present(record: record, url: url)
            } catch {
                Prompt.error("Could not open “\(url.lastPathComponent)”", "\(error.localizedDescription)")
            }
        }
    }

    func open(record: DocumentRecord) {
        if let s = sessions.first(where: { $0.id == record.id }) { activeTab = .session(s.id); return }
        guard let resolved = FileAccess.resolve(record) else {
            if Prompt.confirm(title: "“\(record.title)” can’t be found", message: "The file was moved or deleted. You can locate it again; your notes and reading position are kept.", okTitle: "Locate…") {
                relocate(record)
            }
            return
        }
        FileAccess.begin(resolved.url)
        if resolved.moved || resolved.bookmark != nil {
            var r = record; r.path = resolved.url.path; r.bookmark = resolved.bookmark ?? r.bookmark
            try? store.upsertDocument(r)
        }
        present(record: store.document(id: record.id) ?? record, url: resolved.url)
    }

    private func relocate(_ record: DocumentRecord) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]; panel.message = "Locate “\(record.title)”"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let fp = try? DocumentFingerprint.compute(url: url), fp != record.id,
               !Prompt.confirm(title: "This looks like a different file", message: "Its contents differ from the original. Open it anyway? Notes will stay with the original entry only if you continue.", okTitle: "Open Anyway") { return }
            var r = record; r.path = url.path; r.bookmark = FileAccess.makeBookmark(for: url)
            try? store.upsertDocument(r)
            open(url: url)
        }
    }

    private func present(record: DocumentRecord, url: URL) {
        if let s = sessions.first(where: { $0.id == record.id }) { activeTab = .session(s.id); return }
        let session = ReaderSession(record: record, url: url, store: store)
        session.load()
        sessions.append(session)
        activeTab = .session(session.id)
        library.refresh()
        indexer.enqueue([record])
        persistSession()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func close(_ session: ReaderSession) {
        session.close()
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions.remove(at: i)
            if activeTab == .session(session.id) {
                activeTab = sessions.isEmpty ? .library : .session(sessions[min(i, sessions.count - 1)].id)
            }
        }
        library.refresh()
        persistSession()
    }

    func closeActive() { if let s = activeSession { close(s) } }

    func cycleTab(_ delta: Int) {
        let tabs: [TabSelection] = [.library] + sessions.map { .session($0.id) }
        guard let i = tabs.firstIndex(of: activeTab) else { return }
        activeTab = tabs[(i + delta + tabs.count) % tabs.count]
    }

    // MARK: Session restore / persistence

    private struct SavedSession: Codable { var ids: [String]; var active: String? }

    func persistSession() {
        let s = SavedSession(ids: sessions.map { $0.id }, active: activeSession?.id)
        if let d = try? JSONEncoder().encode(s) { store.setValue(String(decoding: d, as: UTF8.self), for: "session") }
    }

    func restoreSession() {
        guard UserDefaults.standard.object(forKey: "reopenDocuments") as? Bool ?? true,
              let json = store.value(for: "session"), let data = json.data(using: .utf8),
              let saved = try? JSONDecoder().decode(SavedSession.self, from: data) else { return }
        for id in saved.ids { if let r = store.document(id: id) { open(record: r) } }
        if let a = saved.active, sessions.contains(where: { $0.id == a }) { activeTab = .session(a) }
    }

    /// Explicit "Save": flush everything, record a restore point, and write a backup.
    func saveNow() {
        for s in sessions { s.controller.endEditingKeepingSelection(); s.controller.flushPending(); s.flushPageNote(); s.savePositionNow() }
        activeSession?.controller.createSnapshot(label: "Manual save")
        _ = try? backups.backup(store, label: "manual")
        notice = "All changes saved"
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); notice = nil }
    }

    func prepareForTermination() {
        persistSession()
        for s in sessions { s.flushPageNote(); s.close() }
        _ = try? backups.backup(store, label: "quit")
        store.setValue("1", for: "clean_exit")
        store.db.checkpoint()
    }
}

extension AnnotationController {
    /// Flush text edits without leaving edit mode (used by Save).
    func endEditingKeepingSelection() { flushPending() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in urls.filter { $0.pathExtension.lowercased() == "pdf" }.forEach { AppState.shared.open(url: $0) } }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppState.shared.prepareForTermination() }
        return .terminateNow
    }
}
