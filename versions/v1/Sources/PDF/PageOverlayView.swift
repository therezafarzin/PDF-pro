import AppKit
import PDFKit
import Combine

/// Overlay placed by PDFKit above one page. PDFKit scales/positions it with the page; the inner
/// canvas always works in unscaled "display points" (page size, rotated as shown), so annotation
/// geometry stays exact for any zoom, scroll position, layout or rotation.
@MainActor
final class PageOverlayView: NSView {
    let pageIndex: Int
    let canvas: AnnotationCanvasView
    private let geometry: PageGeometry

    init(pageIndex: Int, geometry: PageGeometry, controller: AnnotationController) {
        self.pageIndex = pageIndex
        self.geometry = geometry
        self.canvas = AnnotationCanvasView(pageIndex: pageIndex, geometry: geometry, controller: controller)
        super.init(frame: CGRect(origin: .zero, size: geometry.displaySize))
        addSubview(canvas)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        canvas.frame = bounds
        canvas.bounds = CGRect(origin: .zero, size: geometry.displaySize)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let c = canvas.convert(local, from: self)
        guard canvas.bounds.contains(c), canvas.shouldCapture(at: c) else { return nil }
        if let e = canvas.editorView, e.frame.contains(c) { return e }
        return canvas
    }

    func refresh() { canvas.needsDisplay = true }
    func teardown() { canvas.teardown() }
}

@MainActor
final class AnnotationCanvasView: NSView, NSTextViewDelegate, NSUserInterfaceValidations {
    let pageIndex: Int
    var geometry: PageGeometry
    private weak var controller: AnnotationController?
    private var cancellables = Set<AnyCancellable>()

    private(set) var editorView: NSTextView?
    private var editorID: UUID?

    private enum Drag {
        case move(start: CGPoint, originals: [AnnotationModel])
        case resize(handle: Int, original: AnnotationModel)
        case create(start: CGPoint)
        case ink
        case erase
    }
    private var drag: Drag?
    private var previewModel: AnnotationModel?
    private var inkDisplayPoints: [CGPoint] = []
    private var erased: Set<UUID> = []
    private var movedDuringDrag = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(pageIndex: Int, geometry: PageGeometry, controller: AnnotationController) {
        self.pageIndex = pageIndex
        self.geometry = geometry
        self.controller = controller
        super.init(frame: CGRect(origin: .zero, size: geometry.displaySize))
        controller.pageChanged
            .filter { [pageIndex] in $0 == pageIndex || $0 == -1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.needsDisplay = true }
            .store(in: &cancellables)
        controller.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncState() }
            .store(in: &cancellables)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func teardown() {
        if editorID != nil { controller?.endEditing() }
        removeEditor()
        cancellables.removeAll()
    }

    private var zoom: CGFloat { max(controller?.zoomProvider?() ?? 1, 0.05) }

    // MARK: State sync

    private func syncState() {
        needsDisplay = true
        guard let c = controller else { return }
        if let id = c.editingID, id != editorID, let m = c.model(id), m.pageIndex == pageIndex { beginEditor(for: m) }
        else if c.editingID == nil, editorID != nil { removeEditor() }
        else if let id = editorID, let m = c.model(id) { positionEditor(for: m) }
    }

    // MARK: Hit testing policy (called by overlay)

    func shouldCapture(at c: CGPoint) -> Bool {
        guard let ctl = controller else { return false }
        if let e = editorView, e.frame.insetBy(dx: -6, dy: -6).contains(c) { return true }
        if ctl.tool.capturesPage { return true }
        let ev = NSApp.currentEvent
        let includeMarkup = ev?.type == .rightMouseDown || ev?.modifierFlags.contains(.command) == true
        let pt = geometry.fromDisplay(c)
        if ctl.selection.count == 1, let m = ctl.selectedModels.first, !m.locked, handleIndex(at: c, model: m) != nil { return true }
        return ctl.topAnnotation(at: pt, page: pageIndex, tolerance: 3 / zoom, includeMarkup: includeMarkup) != nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let ctl = controller else { return }
        ctx.saveGState()
        ctx.concatenate(geometry.pToDisplay)
        for m in ctl.models(onPage: pageIndex) {
            AnnotationRenderer.draw(m, geometry: geometry, in: ctx, drawText: !(m.id == editorID && editorView != nil))
        }
        if let p = previewModel { AnnotationRenderer.draw(p, geometry: geometry, in: ctx) }
        ctx.restoreGState()

        // Selection chrome (display space)
        let accent = NSColor.controlAccentColor
        let lineW = 1.2 / zoom
        for m in ctl.selectedModels where m.pageIndex == pageIndex {
            let r = geometry.toDisplay(m.occupiedRect).insetBy(dx: -2 / zoom, dy: -2 / zoom)
            ctx.saveGState()
            ctx.setStrokeColor(accent.cgColor); ctx.setLineWidth(lineW)
            ctx.setLineDash(phase: 0, lengths: m.locked ? [] : [4 / zoom, 3 / zoom])
            ctx.stroke(r)
            ctx.restoreGState()
            if ctl.selection.count == 1, !m.locked, !m.kind.isMarkup, editorID == nil {
                for (i, hr) in handleRects(for: m).enumerated() {
                    _ = i
                    ctx.setFillColor(NSColor.white.cgColor); ctx.fill(hr)
                    ctx.setStrokeColor(accent.cgColor); ctx.setLineWidth(lineW); ctx.stroke(hr)
                }
            }
        }
    }

    // Handles: 0 TL, 1 T, 2 TR, 3 R, 4 BR, 5 B, 6 BL, 7 L (display space, y down)
    private func handleRects(for m: AnnotationModel) -> [CGRect] {
        let r = geometry.toDisplay(m.occupiedRect)
        let h = 9 / zoom
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                   CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
                   CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
        return pts.map { CGRect(x: $0.x - h / 2, y: $0.y - h / 2, width: h, height: h) }
    }

    private func handleIndex(at c: CGPoint, model m: AnnotationModel) -> Int? {
        guard !m.kind.isMarkup, !(m.kind == .stickyNote && m.collapsed) else { return nil }
        return handleRects(for: m).firstIndex { $0.insetBy(dx: -3 / zoom, dy: -3 / zoom).contains(c) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let ctl = controller else { return }
        let c = convert(event.locationInWindow, from: nil)
        let pt = geometry.fromDisplay(c)
        if editorID != nil, !(editorView?.frame.contains(c) ?? false) { ctl.endEditing() }
        window?.makeFirstResponder(self)
        movedDuringDrag = false

        switch ctl.tool {
        case .select, .highlight, .underline, .strikeThrough, .squiggly, .vocabulary:
            if ctl.selection.count == 1, let m = ctl.selectedModels.first, !m.locked, let h = handleIndex(at: c, model: m) {
                drag = .resize(handle: h, original: m); return
            }
            let includeMarkup = event.modifierFlags.contains(.command)
            if let hit = ctl.topAnnotation(at: pt, page: pageIndex, tolerance: 3 / zoom, includeMarkup: includeMarkup) {
                if event.modifierFlags.contains(.shift) {
                    var s = ctl.selection
                    if s.contains(hit.id) { s.remove(hit.id) } else { s.insert(hit.id) }
                    ctl.select(s)
                } else if !ctl.selection.contains(hit.id) {
                    ctl.select([hit.id])
                }
                if event.clickCount == 2, hit.kind.isTextual, !(hit.kind == .stickyNote && hit.collapsed) { ctl.beginEditing(hit.id); return }
                if event.clickCount == 2, hit.kind == .stickyNote { ctl.toggleSticky(hit.id); return }
                let movable = ctl.selectedModels.filter { !$0.locked }
                drag = movable.isEmpty ? nil : .move(start: pt, originals: movable)
            } else {
                ctl.clearSelection()
            }
        case .textBox, .rectangle, .ellipse, .line, .arrow:
            ctl.clearSelection()
            drag = .create(start: c)
        case .stickyNote:
            ctl.createSticky(page: pageIndex, at: pt, switchToSelect: true)
        case .ink, .pencil:
            ctl.clearSelection()
            inkDisplayPoints = [c]
            drag = .ink
        case .eraser:
            erased = []
            drag = .erase
            eraseAt(pt)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let ctl = controller, let d = drag else { return }
        let c = convert(event.locationInWindow, from: nil)
        let pt = geometry.fromDisplay(c)
        movedDuringDrag = true
        switch d {
        case .move(let start, let originals):
            let dx = pt.x - start.x, dy = pt.y - start.y
            ctl.liveReplace(originals.map { $0.translated(dx: dx, dy: dy) })
        case .resize(let handle, let original):
            ctl.liveReplace([resized(original, handle: handle, to: c)])
        case .create(let start):
            previewModel = makePreview(from: start, to: c, shift: event.modifierFlags.contains(.shift))
            needsDisplay = true
        case .ink:
            inkDisplayPoints.append(c)
            previewModel = inkModel()
            needsDisplay = true
        case .erase:
            eraseAt(pt)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let ctl = controller, let d = drag else { return }
        drag = nil
        let c = convert(event.locationInWindow, from: nil)
        switch d {
        case .move(_, let originals):
            ctl.finishInteraction(old: originals, name: "Move")
            if !movedDuringDrag, originals.count == 1, originals[0].kind == .stickyNote, originals[0].collapsed {
                ctl.toggleSticky(originals[0].id)
            }
        case .resize(_, let original):
            ctl.finishInteraction(old: [original], name: "Resize")
        case .create(let start):
            let tool = ctl.tool
            let moved = hypot(c.x - start.x, c.y - start.y) > 6
            if tool == .textBox {
                var dr = CGRect(x: min(start.x, c.x), y: min(start.y, c.y), width: abs(c.x - start.x), height: abs(c.y - start.y))
                if !moved || dr.width < 30 || dr.height < 20 { dr = CGRect(x: start.x, y: start.y, width: 240, height: 90) }
                ctl.createTextBox(page: pageIndex, rect: geometry.fromDisplay(dr), switchToSelect: true)
            } else if moved, let p = previewModel {
                ctl.addShape(p.kind, page: pageIndex, rect: p.rect, points: p.points)
            }
            previewModel = nil
        case .ink:
            var pts = inkDisplayPoints.map { geometry.fromDisplay($0) }
            pts = GeometryMath.simplify(pts, epsilon: 0.5 / max(zoom, 0.25))
            if pts.count >= 1 {
                let bounds = GeometryMath.boundingRect(of: pts).insetBy(dx: -ctl.strokeWidth, dy: -ctl.strokeWidth)
                ctl.addShape(.ink, page: pageIndex, rect: bounds, points: pts)
            }
            inkDisplayPoints = []; previewModel = nil
        case .erase:
            ctl.finishErase(removed: erasedModels)
            erasedModels = []; erased = []
        }
        needsDisplay = true
    }

    private var erasedModels: [AnnotationModel] = []

    private func eraseAt(_ pt: CGPoint) {
        guard let ctl = controller else { return }
        let hits = ctl.models(onPage: pageIndex).filter { !$0.kind.isTextual && $0.hitTest(pt, tolerance: 5 / zoom) }.map { $0.id }
        let new = Set(hits).subtracting(erased)
        guard !new.isEmpty else { return }
        erasedModels += ctl.eraseLive(new)
        erased.formUnion(new)
    }

    private func resized(_ m: AnnotationModel, handle: Int, to c: CGPoint) -> AnnotationModel {
        var r = geometry.toDisplay(m.occupiedRect)
        let minSize: CGFloat = 14
        switch handle {
        case 0: r = edge(r, left: c.x, top: c.y, minSize: minSize)
        case 1: r = edge(r, top: c.y, minSize: minSize)
        case 2: r = edge(r, right: c.x, top: c.y, minSize: minSize)
        case 3: r = edge(r, right: c.x, minSize: minSize)
        case 4: r = edge(r, right: c.x, bottom: c.y, minSize: minSize)
        case 5: r = edge(r, bottom: c.y, minSize: minSize)
        case 6: r = edge(r, left: c.x, bottom: c.y, minSize: minSize)
        default: r = edge(r, left: c.x, minSize: minSize)
        }
        return m.resized(to: geometry.fromDisplay(r))
    }

    private func edge(_ r: CGRect, left: CGFloat? = nil, right: CGFloat? = nil, top: CGFloat? = nil, bottom: CGFloat? = nil, minSize: CGFloat) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if let l = left { minX = min(l, maxX - minSize) }
        if let rt = right { maxX = max(rt, minX + minSize) }
        if let t = top { minY = min(t, maxY - minSize) }
        if let b = bottom { maxY = max(b, minY + minSize) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func makePreview(from a: CGPoint, to b: CGPoint, shift: Bool) -> AnnotationModel? {
        guard let ctl = controller else { return nil }
        var end = b
        let tool = ctl.tool
        if shift {
            if tool == .line || tool == .arrow {
                let dx = b.x - a.x, dy = b.y - a.y
                let ang = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
                let len = hypot(dx, dy)
                end = CGPoint(x: a.x + len * cos(ang), y: a.y + len * sin(ang))
            } else {
                let side = max(abs(b.x - a.x), abs(b.y - a.y))
                end = CGPoint(x: a.x + (b.x >= a.x ? side : -side), y: a.y + (b.y >= a.y ? side : -side))
            }
        }
        var style = AnnotationStyle()
        style.stroke = ctl.stroke; style.strokeWidth = ctl.strokeWidth; style.opacity = ctl.shapeOpacity
        switch tool {
        case .textBox:
            style.stroke = RGBA(NSColor.controlAccentColor); style.strokeWidth = 1; style.dashed = true; style.opacity = 1
            let r = CGRect(x: min(a.x, end.x), y: min(a.y, end.y), width: abs(end.x - a.x), height: abs(end.y - a.y))
            return AnnotationModel(kind: .rectangle, pageIndex: pageIndex, rect: geometry.fromDisplay(r), style: style)
        case .rectangle, .ellipse:
            style.fill = ctl.shapeFill
            let r = CGRect(x: min(a.x, end.x), y: min(a.y, end.y), width: abs(end.x - a.x), height: abs(end.y - a.y))
            return AnnotationModel(kind: tool == .ellipse ? .ellipse : .rectangle, pageIndex: pageIndex, rect: geometry.fromDisplay(r), style: style)
        case .line, .arrow:
            let p0 = geometry.fromDisplay(a), p1 = geometry.fromDisplay(end)
            return AnnotationModel(kind: tool == .arrow ? .arrow : .line, pageIndex: pageIndex,
                                   rect: GeometryMath.boundingRect(of: [p0, p1]).insetBy(dx: -4, dy: -4), points: [p0, p1], style: style)
        default: return nil
        }
    }

    private func inkModel() -> AnnotationModel? {
        guard let ctl = controller else { return nil }
        var style = AnnotationStyle()
        style.stroke = ctl.stroke
        style.strokeWidth = ctl.tool == .pencil ? max(0.8, ctl.strokeWidth * 0.5) : ctl.strokeWidth
        style.opacity = ctl.tool == .pencil ? 0.85 : ctl.shapeOpacity
        let pts = inkDisplayPoints.map { geometry.fromDisplay($0) }
        return AnnotationModel(kind: .ink, pageIndex: pageIndex, rect: GeometryMath.boundingRect(of: pts), points: pts, style: style)
    }

    // MARK: Keyboard & edit actions

    override func keyDown(with event: NSEvent) {
        guard let ctl = controller else { return super.keyDown(with: event) }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117: ctl.deleteSelection()                       // delete / forward delete
        case 53: ctl.clearSelection(); ctl.tool = .select          // escape
        case 123: ctl.nudge(dx: -step, dy: 0)
        case 124: ctl.nudge(dx: step, dy: 0)
        case 125: ctl.nudge(dx: 0, dy: -step)
        case 126: ctl.nudge(dx: 0, dy: step)
        case 36: if let id = ctl.selection.first { ctl.beginEditing(id) }
        default: super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) { controller?.copySelection() }
    @objc func cut(_ sender: Any?) { controller?.cutSelection() }
    @objc func paste(_ sender: Any?) { controller?.paste(toPage: pageIndex) }
    @objc override func selectAll(_ sender: Any?) { controller?.selectAll(page: pageIndex) }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let ctl = controller else { return false }
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)): return !ctl.selection.isEmpty
        case #selector(paste(_:)): return ctl.canPasteAnnotations || NSPasteboard.general.string(forType: .string) != nil
        case #selector(selectAll(_:)): return true
        default: return true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let ctl = controller else { return nil }
        let c = convert(event.locationInWindow, from: nil)
        let pt = geometry.fromDisplay(c)
        if let hit = ctl.topAnnotation(at: pt, page: pageIndex, tolerance: 3 / zoom), !ctl.selection.contains(hit.id) { ctl.select([hit.id]) }
        guard !ctl.selection.isEmpty else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action); menu.addItem(item)
        }
        if let m = ctl.selectedModels.first, m.kind.isTextual { add("Edit Text") { ctl.beginEditing(m.id) }; add("Fit to Text") { ctl.fitToText() }; menu.addItem(.separator()) }
        if ctl.selectedModels.contains(where: { $0.kind.isMarkup }) {
            for cat in StudyCategory.allCases {
                add("Change to \(cat.title)") {
                    let color = ctl.categoryColors[cat] ?? cat.defaultColor
                    ctl.setStyle { $0.stroke = color }
                }
            }
            menu.addItem(.separator())
        }
        add("Copy") { ctl.copySelection() }
        add("Duplicate") { ctl.duplicateSelection() }
        add("Delete") { ctl.deleteSelection() }
        menu.addItem(.separator())
        add("Bring to Front") { ctl.reorder(.front) }
        add("Send to Back") { ctl.reorder(.back) }
        add(ctl.selectedModels.allSatisfy { $0.locked } ? "Unlock" : "Lock") { ctl.toggleLock() }
        if ctl.selection.count > 1 { add("Group") { ctl.group() } }
        if ctl.selectedModels.contains(where: { $0.groupID != nil }) { add("Ungroup") { ctl.ungroup() } }
        return menu
    }

    // MARK: Inline editor

    private func beginEditor(for m: AnnotationModel) {
        removeEditor()
        guard let ctl = controller else { return }
        if geometry.rotation != 0 {
            // Inline editing needs an unrotated page; use the floating editor instead.
            editorID = m.id
            FloatingTextEditor.shared.show(modelID: m.id, controller: ctl)
            return
        }
        let inner = geometry.toDisplay(m.occupiedRect).insetBy(dx: CGFloat(m.style.padding), dy: CGFloat(m.style.padding))
        let tv = RichText.makeTextView(frame: inner)
        let attr = RichText.decode(m.text)
        tv.textStorage?.setAttributedString(attr)
        if attr.length == 0 {
            tv.typingAttributes = ctl.newTextPreset.map { RichText.attributes(for: $0) } ?? RichText.defaultAttributes()
        } else {
            tv.typingAttributes = attr.attributes(at: attr.length - 1, effectiveRange: nil)
        }
        tv.delegate = self
        tv.insertionPointColor = .black
        addSubview(tv)
        editorView = tv
        editorID = m.id
        ctl.activeTextView = tv
        window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: attr.length, length: 0))
        needsDisplay = true
    }

    private func positionEditor(for m: AnnotationModel) {
        guard let tv = editorView else { return }
        let inner = geometry.toDisplay(m.occupiedRect).insetBy(dx: CGFloat(m.style.padding), dy: CGFloat(m.style.padding))
        if tv.frame != inner { tv.frame = inner }
    }

    private func removeEditor() {
        guard let tv = editorView else {
            if editorID != nil { editorID = nil; FloatingTextEditor.shared.close() }
            return
        }
        controller?.undoManager.removeAllActions(withTarget: tv)
        tv.delegate = nil
        tv.removeFromSuperview()
        editorView = nil
        editorID = nil
        if window?.firstResponder === tv { window?.makeFirstResponder(self) }
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = editorView, let id = editorID, let ctl = controller, let m = ctl.model(id) else { return }
        let needed = RichText.requiredHeight(for: tv.attributedString(), width: tv.frame.width) + CGFloat(m.style.padding) * 2
        ctl.updateText(id: id, attributed: tv.attributedString(), newHeight: needed)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { controller?.endEditing(); return true }
        return false
    }

    func undoManager(for view: NSTextView) -> UndoManager? { controller?.undoManager }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { handler() }
}

// MARK: - Floating editor (used for rotated pages; also a "floating note editor")

@MainActor
final class FloatingTextEditor: NSObject, NSTextViewDelegate, NSWindowDelegate {
    static let shared = FloatingTextEditor()
    private var panel: NSPanel?
    private var textView: NSTextView?
    private var modelID: UUID?
    private weak var controller: AnnotationController?

    func show(modelID: UUID, controller: AnnotationController) {
        close()
        guard let m = controller.model(modelID) else { return }
        self.modelID = modelID; self.controller = controller
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Edit Text"
        panel.isFloatingPanel = true
        panel.delegate = self
        let scroll = NSScrollView(frame: panel.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let tv = RichText.makeTextView(frame: scroll.bounds)
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textStorage?.setAttributedString(RichText.decode(m.text))
        tv.delegate = self
        scroll.documentView = tv
        panel.contentView?.addSubview(scroll)
        panel.center(); panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(tv)
        self.panel = panel; self.textView = tv
        controller.activeTextView = tv
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textView, let id = modelID, let c = controller, let m = c.model(id) else { return }
        let h = RichText.requiredHeight(for: tv.attributedString(), width: m.rect.width - CGFloat(m.style.padding) * 2) + CGFloat(m.style.padding) * 2
        c.updateText(id: id, attributed: tv.attributedString(), newHeight: h)
    }

    func windowWillClose(_ notification: Notification) { controller?.endEditing(); panel = nil; textView = nil }
    func close() { panel?.close() }
}
