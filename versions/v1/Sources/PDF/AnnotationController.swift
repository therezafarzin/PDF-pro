import AppKit
import PDFKit
import Combine

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, highlight, underline, strikeThrough, squiggly
    case textBox, stickyNote, ink, pencil, line, arrow, rectangle, ellipse, eraser, vocabulary
    var id: String { rawValue }

    var markupKind: AnnotationKind? {
        switch self {
        case .highlight: return .highlight
        case .underline: return .underline
        case .strikeThrough: return .strikeThrough
        case .squiggly: return .squiggly
        default: return nil
        }
    }
    /// Tools that take over mouse input for the whole page.
    var capturesPage: Bool {
        switch self {
        case .textBox, .stickyNote, .ink, .pencil, .line, .arrow, .rectangle, .ellipse, .eraser: return true
        default: return false
        }
    }
    var title: String {
        switch self {
        case .select: return "Select"
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strikeThrough: return "Strikethrough"
        case .squiggly: return "Squiggly Underline"
        case .textBox: return "Text Box"
        case .stickyNote: return "Sticky Note"
        case .ink: return "Pen"
        case .pencil: return "Pencil"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .eraser: return "Eraser"
        case .vocabulary: return "Vocabulary"
        }
    }
    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikeThrough: return "strikethrough"
        case .squiggly: return "scribble.variable"
        case .textBox: return "textbox"
        case .stickyNote: return "note.text"
        case .ink: return "pencil.tip"
        case .pencil: return "pencil"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .eraser: return "eraser"
        case .vocabulary: return "character.book.closed"
        }
    }
}

enum SaveState: Equatable {
    case saved(Date), saving, failed(String)
}

@MainActor
final class AnnotationController: ObservableObject {
    static let pasteboardType = NSPasteboard.PasteboardType("app.pdfstudy.annotations")

    let store: Store
    private(set) var docID: String
    let undoManager = UndoManager()
    let pageChanged = PassthroughSubject<Int, Never>()   // -1 = every page

    @Published var tool: AnnotationTool = .select {
        didSet { if tool != oldValue { endEditing() } }
    }
    @Published var selection: Set<UUID> = []
    @Published private(set) var revision = 0
    @Published var saveState: SaveState = .saved(Date())
    @Published var editingID: UUID?

    // Tool options
    @Published var markupColor: RGBA = StudyCategory.vocabulary.defaultColor
    @Published var studyCategory: StudyCategory? = .vocabulary
    @Published var stroke: RGBA = RGBA(0.88, 0.22, 0.20)
    @Published var strokeWidth: Double = 2.5
    @Published var shapeFill: RGBA? = nil
    @Published var shapeOpacity: Double = 1
    @Published var newTextPreset: TextStylePreset?
    @Published var textStyles: [TextStylePreset] = []
    @Published var categoryColors: [StudyCategory: RGBA] = [:]

    weak var activeTextView: NSTextView?
    var geometryProvider: ((Int) -> PageGeometry?)?
    var zoomProvider: (() -> CGFloat)?
    var visiblePageProvider: (() -> Int)?
    var requestVocabulary: ((String, Int, String) -> Void)?

    private var byPage: [Int: [AnnotationModel]] = [:]
    private var pendingPersist: Set<UUID> = []
    private var persistTask: Task<Void, Never>?

    init(store: Store, docID: String) {
        self.store = store
        self.docID = docID
        textStyles = store.textStyles()
        newTextPreset = textStyles.first { $0.name == "German Vocabulary" } ?? textStyles.first
        for c in StudyCategory.allCases {
            categoryColors[c] = UserDefaults.standard.string(forKey: "categoryColor.\(c.rawValue)").flatMap { RGBA(hex: $0) } ?? c.defaultColor
        }
        if let c = studyCategory { markupColor = categoryColors[c] ?? c.defaultColor }
        reload()
    }

    func rebind(docID: String) { self.docID = docID }

    func reload() {
        byPage = Dictionary(grouping: store.annotations(docID: docID), by: { $0.pageIndex })
        for k in byPage.keys { byPage[k]?.sort { $0.zIndex < $1.zIndex } }
        revision += 1
        pageChanged.send(-1)
    }

    // MARK: Queries

    func models(onPage p: Int) -> [AnnotationModel] { byPage[p] ?? [] }
    var all: [AnnotationModel] { byPage.values.flatMap { $0 }.sorted { ($0.pageIndex, $0.zIndex) < ($1.pageIndex, $1.zIndex) } }
    func model(_ id: UUID) -> AnnotationModel? {
        for list in byPage.values { if let m = list.first(where: { $0.id == id }) { return m } }
        return nil
    }
    var selectedModels: [AnnotationModel] { selection.compactMap { model($0) } }

    func topAnnotation(at pagePoint: CGPoint, page: Int, tolerance: CGFloat, includeMarkup: Bool = true) -> AnnotationModel? {
        for m in models(onPage: page).reversed() where includeMarkup || !m.kind.isMarkup {
            if m.hitTest(pagePoint, tolerance: tolerance) { return m }
        }
        return nil
    }

    private func nextZ(page: Int) -> Int { (byPage[page]?.map { $0.zIndex }.max() ?? 0) + 1 }

    // MARK: Core mutation (undoable)

    func commit(add: [AnnotationModel] = [], remove: [UUID] = [], update: [AnnotationModel] = [], name: String) {
        let removed = remove.compactMap { model($0) }
        let old = update.compactMap { model($0.id) }
        mutate(add: add, remove: remove, update: update)
        undoManager.registerUndo(withTarget: self) { t in
            t.commit(add: removed, remove: add.map { $0.id }, update: old, name: name)
        }
        undoManager.setActionName(name)
    }

    private func mutate(add: [AnnotationModel], remove: [UUID], update: [AnnotationModel]) {
        var touched = Set<Int>()
        for id in remove {
            if let m = model(id) {
                byPage[m.pageIndex]?.removeAll { $0.id == id }
                touched.insert(m.pageIndex)
                selection.remove(id)
                if editingID == id { editingID = nil }
            }
        }
        for var m in add {
            m.modifiedAt = Date()
            byPage[m.pageIndex, default: []].append(m)
            byPage[m.pageIndex]?.sort { $0.zIndex < $1.zIndex }
            touched.insert(m.pageIndex)
        }
        for var m in update {
            guard let old = model(m.id) else { continue }
            m.modifiedAt = Date()
            byPage[old.pageIndex]?.removeAll { $0.id == m.id }
            byPage[m.pageIndex, default: []].append(m)
            byPage[m.pageIndex]?.sort { $0.zIndex < $1.zIndex }
            touched.insert(old.pageIndex); touched.insert(m.pageIndex)
        }
        persist(upserts: add + update.compactMap { model($0.id) }, deletes: remove)
        revision += 1
        touched.forEach { pageChanged.send($0) }
    }

    private func persist(upserts: [AnnotationModel], deletes: [UUID]) {
        do {
            if !upserts.isEmpty { try store.saveAnnotations(upserts, docID: docID) }
            if !deletes.isEmpty { try store.deleteAnnotations(ids: deletes) }
            if pendingPersist.isEmpty { saveState = .saved(Date()) }
        } catch {
            saveState = .failed("\(error)")
        }
    }

    // MARK: Interactive (live) changes: in-memory until finished

    func liveReplace(_ models: [AnnotationModel]) {
        var touched = Set<Int>()
        for m in models {
            guard let old = model(m.id), let i = byPage[old.pageIndex]?.firstIndex(where: { $0.id == m.id }) else { continue }
            byPage[old.pageIndex]?[i] = m
            touched.insert(old.pageIndex)
        }
        touched.forEach { pageChanged.send($0) }
    }

    func finishInteraction(old: [AnnotationModel], name: String) {
        let current = old.compactMap { model($0.id) }
        guard current != old else { return }
        persist(upserts: current, deletes: [])
        revision += 1
        undoManager.registerUndo(withTarget: self) { t in t.commit(update: old, name: name) }
        undoManager.setActionName(name)
    }

    func eraseLive(_ ids: Set<UUID>) -> [AnnotationModel] {
        var removed: [AnnotationModel] = []
        var touched = Set<Int>()
        for id in ids {
            if let m = model(id) { removed.append(m); byPage[m.pageIndex]?.removeAll { $0.id == id }; touched.insert(m.pageIndex); selection.remove(id) }
        }
        touched.forEach { pageChanged.send($0) }
        return removed
    }

    func finishErase(removed: [AnnotationModel]) {
        guard !removed.isEmpty else { return }
        persist(upserts: [], deletes: removed.map { $0.id })
        revision += 1
        undoManager.registerUndo(withTarget: self) { t in t.commit(add: removed, name: "Erase") }
        undoManager.setActionName("Erase")
    }

    // MARK: Creation

    func addMarkup(_ kind: AnnotationKind, from selection: PDFSelection, document: PDFDocument) {
        var perPage: [Int: [CGRect]] = [:]
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let idx = document.index(for: page)
                let r = line.bounds(for: page)
                if r.width > 0.5, r.height > 0.5 { perPage[idx, default: []].append(r) }
            }
        }
        var newModels: [AnnotationModel] = []
        var toRemove: [UUID] = []
        for (idx, quads) in perPage.sorted(by: { $0.key < $1.key }) {
            // Marking text that is already marked toggles the mark off (same color) or recolors it,
            // instead of stacking duplicates that are impossible to peel off one by one.
            let existing = models(onPage: idx).filter { $0.kind == kind }
            let existingQuads = existing.flatMap { $0.quads }
            if !existing.isEmpty, quads.allSatisfy({ MarkupMath.isCovered($0, by: existingQuads) }) {
                let touching = existing.filter { e in e.quads.contains { eq in quads.contains { MarkupMath.overlapFraction(of: $0, with: eq) > 0.2 } } }
                toRemove += touching.map { $0.id }
                if touching.allSatisfy({ $0.style.stroke == markupColor }) { continue }
            }
            var style = AnnotationStyle()
            style.stroke = markupColor
            style.opacity = kind == .highlight ? 0.38 : 1
            style.strokeWidth = 1.3
            newModels.append(AnnotationModel(kind: kind, pageIndex: idx, rect: GeometryMath.union(quads), quads: quads,
                                          style: style, zIndex: nextZ(page: idx), category: studyCategory))
        }
        if newModels.isEmpty && toRemove.isEmpty { return }
        let name = newModels.isEmpty ? "Remove \(kind == .highlight ? "Highlight" : "Markup")" : "Add \(kind == .highlight ? "Highlight" : "Markup")"
        commit(add: newModels, remove: toRemove, name: name)
    }

    func setStudyCategory(_ c: StudyCategory?) {
        studyCategory = c
        if let c { markupColor = categoryColors[c] ?? c.defaultColor }
    }

    @discardableResult
    func createTextBox(page: Int, rect: CGRect, text: NSAttributedString? = nil, startEditing: Bool = true,
                       switchToSelect: Bool = false) -> AnnotationModel {
        // Switch tools BEFORE creating: changing the tool ends editing, which deletes empty boxes.
        if switchToSelect { tool = .select }
        var style = newTextPreset?.box ?? AnnotationStyle()
        if newTextPreset == nil { style.fill = RGBA(1, 1, 1, 0.9); style.stroke = RGBA(0.6, 0.6, 0.6); style.strokeWidth = 0.75; style.cornerRadius = 6 }
        var content: TextContent? = nil
        if let t = text { content = RichText.encode(t) }
        let m = AnnotationModel(kind: .textBox, pageIndex: page, rect: rect, style: style, text: content, zIndex: nextZ(page: page))
        commit(add: [m], name: "Add Text Box")
        selection = [m.id]
        if startEditing { editingID = m.id }
        return m
    }

    func createSticky(page: Int, at topLeftPage: CGPoint, switchToSelect: Bool = false) {
        if switchToSelect { tool = .select }
        var style = AnnotationStyle()
        style.fill = RGBA(1, 0.93, 0.55); style.stroke = RGBA(0.75, 0.6, 0.1); style.strokeWidth = 1; style.cornerRadius = 6; style.padding = 8
        let rect = CGRect(x: topLeftPage.x, y: topLeftPage.y - 120, width: 200, height: 120)
        let m = AnnotationModel(kind: .stickyNote, pageIndex: page, rect: rect, style: style, zIndex: nextZ(page: page))
        commit(add: [m], name: "Add Sticky Note")
        selection = [m.id]; editingID = m.id
    }

    func addShape(_ kind: AnnotationKind, page: Int, rect: CGRect, points: [CGPoint]) {
        var style = AnnotationStyle()
        style.stroke = stroke; style.strokeWidth = strokeWidth; style.opacity = shapeOpacity
        if kind == .rectangle || kind == .ellipse { style.fill = shapeFill }
        let m = AnnotationModel(kind: kind, pageIndex: page, rect: rect, points: points, style: style, zIndex: nextZ(page: page))
        commit(add: [m], name: "Add \(kind.rawValue.capitalized)")
    }

    // MARK: Selection & editing

    func select(_ ids: Set<UUID>, expandGroups: Bool = true) {
        var result = ids
        if expandGroups {
            let groups = Set(ids.compactMap { model($0)?.groupID })
            for m in all where m.groupID != nil && groups.contains(m.groupID!) { result.insert(m.id) }
        }
        selection = result
    }
    func selectAll(page: Int) { selection = Set(models(onPage: page).map { $0.id }) }
    func clearSelection() { if !selection.isEmpty { selection = [] } }

    func beginEditing(_ id: UUID) {
        guard let m = model(id), m.kind.isTextual, !m.locked else { return }
        selection = [id]; editingID = id
    }

    func endEditing() {
        flushPending()
        if let id = editingID, let m = model(id), m.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Remove abandoned empty boxes without leaving clutter.
            mutate(add: [], remove: [id], update: [])
        }
        editingID = nil
        activeTextView = nil
    }

    /// Called from the text editor on every change. Updated in memory immediately, persisted shortly after.
    func updateText(id: UUID, attributed: NSAttributedString, newHeight: CGFloat? = nil) {
        guard var m = model(id), let i = byPage[m.pageIndex]?.firstIndex(where: { $0.id == id }) else { return }
        m.text = RichText.encode(attributed)
        if let h = newHeight, h > m.rect.height {
            m.rect = CGRect(x: m.rect.minX, y: m.rect.maxY - h, width: m.rect.width, height: h)
        }
        m.modifiedAt = Date()
        byPage[m.pageIndex]?[i] = m
        pendingPersist.insert(id)
        saveState = .saving
        revision += 1
        pageChanged.send(m.pageIndex)
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { self?.flushPending() }
        }
    }

    func flushPending() {
        persistTask?.cancel()
        let models = pendingPersist.compactMap { model($0) }
        pendingPersist.removeAll()
        persist(upserts: models, deletes: [])
        if models.isEmpty, case .saving = saveState { saveState = .saved(Date()) }
    }

    // MARK: Editing commands

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection.filter { model($0)?.locked == false }
        guard !ids.isEmpty else { NSSound.beep(); return }
        commit(remove: Array(ids), name: "Delete")
    }

    func delete(ids: [UUID]) { commit(remove: ids, name: "Delete") }

    func duplicateSelection() {
        var groupMap: [UUID: UUID] = [:]
        let copies = selectedModels.map { m -> AnnotationModel in
            var c = m.translated(dx: 14, dy: -14)
            c.id = UUID(); c.zIndex = nextZ(page: m.pageIndex); c.locked = false; c.createdAt = Date()
            if let g = m.groupID { c.groupID = groupMap[g] ?? { let n = UUID(); groupMap[g] = n; return n }() }
            return c
        }
        guard !copies.isEmpty else { return }
        commit(add: copies, name: "Duplicate")
        selection = Set(copies.map { $0.id })
    }

    func copySelection() {
        let models = selectedModels
        guard !models.isEmpty, let data = try? JSONEncoder().encode(models) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.pasteboardType)
        let plain = models.map { $0.plainText }.filter { !$0.isEmpty }.joined(separator: "\n")
        if !plain.isEmpty { pb.setString(plain, forType: .string) }
    }

    var canPasteAnnotations: Bool { NSPasteboard.general.data(forType: Self.pasteboardType) != nil }

    func paste(toPage page: Int) {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: Self.pasteboardType), let models = try? JSONDecoder().decode([AnnotationModel].self, from: data) {
            var groupMap: [UUID: UUID] = [:]
            let copies = models.map { m -> AnnotationModel in
                var c = m.translated(dx: 16, dy: -16)
                c.id = UUID(); c.pageIndex = page; c.zIndex = nextZ(page: page); c.locked = false
                if let g = m.groupID { c.groupID = groupMap[g] ?? { let n = UUID(); groupMap[g] = n; return n }() }
                return c
            }
            commit(add: copies, name: "Paste")
            selection = Set(copies.map { $0.id })
        } else if let text = pb.string(forType: .string), !text.isEmpty, let g = geometryProvider?(page) {
            let attrs = newTextPreset.map { RichText.attributes(for: $0) } ?? RichText.defaultAttributes()
            let r = CGRect(x: g.box.minX + 40, y: g.box.maxY - 140, width: 260, height: 90)
            createTextBox(page: page, rect: r, text: NSAttributedString(string: text, attributes: attrs), startEditing: false)
        }
    }

    func cutSelection() { copySelection(); deleteSelection() }

    func nudge(dx: CGFloat, dy: CGFloat) {
        let old = selectedModels.filter { !$0.locked }
        guard !old.isEmpty else { return }
        commit(update: old.map { $0.translated(dx: dx, dy: dy) }, name: "Move")
    }

    func group() {
        let models = selectedModels
        guard models.count > 1 else { return }
        let gid = UUID()
        commit(update: models.map { var m = $0; m.groupID = gid; return m }, name: "Group")
    }
    func ungroup() {
        commit(update: selectedModels.filter { $0.groupID != nil }.map { var m = $0; m.groupID = nil; return m }, name: "Ungroup")
    }

    func toggleLock() {
        let models = selectedModels
        guard !models.isEmpty else { return }
        let lock = !models.allSatisfy { $0.locked }
        commit(update: models.map { var m = $0; m.locked = lock; return m }, name: lock ? "Lock" : "Unlock")
    }

    enum Order { case front, back, forward, backward }
    func reorder(_ order: Order) {
        var updates: [AnnotationModel] = []
        let pages = Set(selectedModels.map { $0.pageIndex })
        for p in pages {
            var list = models(onPage: p)
            let ids = Set(selection)
            let selected = list.filter { ids.contains($0.id) }
            switch order {
            case .front: list = list.filter { !ids.contains($0.id) } + selected
            case .back: list = selected + list.filter { !ids.contains($0.id) }
            case .forward, .backward:
                var arr = list
                let step = order == .forward ? 1 : -1
                let idxs = arr.indices.filter { ids.contains(arr[$0].id) }
                for i in (order == .forward ? idxs.reversed() : idxs) {
                    let j = i + step
                    if arr.indices.contains(j), !ids.contains(arr[j].id) { arr.swapAt(i, j) }
                }
                list = arr
            }
            for (z, var m) in list.enumerated() where m.zIndex != z { m.zIndex = z; updates.append(m) }
        }
        if !updates.isEmpty { commit(update: updates, name: "Arrange") }
    }

    func setStyle(_ change: (inout AnnotationStyle) -> Void) {
        let updated = selectedModels.filter { !$0.locked }.map { m -> AnnotationModel in var c = m; change(&c.style); return c }
        guard !updated.isEmpty else { return }
        commit(update: updated, name: "Change Style")
    }

    /// Applies a text operation to the active editor selection, or to all text of the selected boxes.
    func formatText(_ op: TextOp, paragraph: Bool = false) {
        if let tv = activeTextView, editingID != nil {
            tv.applyOp(op, paragraph: paragraph)
            tv.window?.makeFirstResponder(tv)
            return
        }
        let updated = selectedModels.filter { $0.kind.isTextual && !$0.locked }.map { m -> AnnotationModel in
            let a = NSMutableAttributedString(attributedString: RichText.decode(m.text))
            op(a, NSRange(location: 0, length: a.length))
            var c = m; c.text = RichText.encode(a); return c
        }
        if !updated.isEmpty { commit(update: updated, name: "Format Text") }
    }

    func applyPreset(_ preset: TextStylePreset) {
        newTextPreset = preset
        formatText(TextOps.preset(preset))
        let boxes = selectedModels.filter { $0.kind.isTextual && !$0.locked }.map { m -> AnnotationModel in
            var c = m; c.style = preset.box; return c
        }
        if !boxes.isEmpty && editingID == nil { commit(update: boxes, name: "Apply Style") }
        else if let id = editingID, var m = model(id) { m.style = preset.box; commit(update: [m], name: "Apply Style") }
    }

    func fitToText() {
        let updated = selectedModels.filter { $0.kind.isTextual && !$0.locked }.map { m -> AnnotationModel in
            var c = m
            let h = RichText.requiredHeight(for: RichText.decode(m.text), width: m.rect.width - CGFloat(m.style.padding) * 2) + CGFloat(m.style.padding) * 2
            if h > 0 { c.rect = CGRect(x: m.rect.minX, y: m.rect.maxY - h, width: m.rect.width, height: h) }
            return c
        }
        if !updated.isEmpty { commit(update: updated, name: "Fit to Text") }
    }

    func toggleSticky(_ id: UUID) {
        guard var m = model(id), m.kind == .stickyNote else { return }
        m.collapsed.toggle()
        commit(update: [m], name: m.collapsed ? "Collapse Note" : "Expand Note")
    }

    /// Find & replace inside annotation text, preserving formatting. Returns replacement count.
    @discardableResult
    func replaceText(find: String, with replacement: String, caseSensitive: Bool = false) -> Int {
        guard !find.isEmpty else { return 0 }
        var count = 0
        var updated: [AnnotationModel] = []
        for m in all where m.kind.isTextual && !m.locked && !m.plainText.isEmpty {
            let a = NSMutableAttributedString(attributedString: RichText.decode(m.text))
            var searchRange = NSRange(location: 0, length: a.length)
            var local = 0
            let opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            var ranges: [NSRange] = []
            while searchRange.length > 0 {
                let r = (a.string as NSString).range(of: find, options: opts, range: searchRange)
                if r.location == NSNotFound { break }
                ranges.append(r)
                searchRange = NSRange(location: r.upperBound, length: a.length - r.upperBound)
            }
            for r in ranges.reversed() { a.replaceCharacters(in: r, with: replacement); local += 1 }
            if local > 0 { var c = m; c.text = RichText.encode(a); updated.append(c); count += local }
        }
        if !updated.isEmpty { commit(update: updated, name: "Replace Text") }
        return count
    }

    // MARK: Undo / snapshots

    func undo() { flushPending(); undoManager.undo() }
    func redo() { undoManager.redo() }

    func createSnapshot(label: String) { store.saveSnapshot(docID: docID, label: label, models: all) }

    func restore(_ models: [AnnotationModel]) {
        createSnapshot(label: "Before restore")
        commit(add: models, remove: all.map { $0.id }, name: "Restore Version")
    }

    func clearAllAfterEmbedding() {
        let ids = all.map { $0.id }
        mutate(add: [], remove: ids, update: [])
        undoManager.removeAllActions()
    }
}
