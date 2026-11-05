import AppKit
import PDFKit

/// PDFView with per-page annotation overlays, text-selection markup, and a study context menu.
@MainActor
final class StudyPDFView: PDFView, PDFPageOverlayViewProvider {
    weak var controller: AnnotationController?
    var onAddVocabulary: ((PDFSelection) -> Void)?
    var onAddBookmark: (() -> Void)?
    var onSpeak: ((String) -> Void)?
    private var mouseUpMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }

    private func commonInit() {
        pageOverlayViewProvider = self
        autoScales = false
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        displaysPageBreaks = true
        pageBreakMargins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        minScaleFactor = 0.1
        maxScaleFactor = 8
        interpolationQuality = .high
        // PDFKit's internal document view receives mouse events, so selection-based markup is
        // applied from a local event monitor after the mouse is released.
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let p = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(p) { DispatchQueue.main.async { self.applySelectionTool() } }
            return event
        }
    }

    deinit { if let m = mouseUpMonitor { NSEvent.removeMonitor(m) } }

    private func applySelectionTool() {
        guard let ctl = controller, let doc = document, let sel = currentSelection,
              let text = sel.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let kind = ctl.tool.markupKind {
            ctl.addMarkup(kind, from: sel, document: doc)
            clearSelection()
        } else if ctl.tool == .vocabulary {
            onAddVocabulary?(sel)
        }
    }

    // MARK: Overlay provider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        guard let doc = document, let ctl = controller, let g = geometry(for: page) else { return nil }
        return PageOverlayView(pageIndex: doc.index(for: page), geometry: g, controller: ctl)
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: NSView, for page: PDFPage) {
        (overlayView as? PageOverlayView)?.refresh()
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        (overlayView as? PageOverlayView)?.teardown()
    }

    func geometry(for page: PDFPage) -> PageGeometry? {
        PageGeometry(box: page.bounds(for: .cropBox), rotation: page.rotation)
    }

    func geometry(forIndex i: Int) -> PageGeometry? {
        guard let page = document?.page(at: i) else { return nil }
        return geometry(for: page)
    }

    /// Refreshes overlays after a page rotation (rotation changes the overlay's geometry).
    func rebuildOverlays() {
        let doc = document
        let dest = currentDestination
        document = nil
        document = doc
        if let dest { go(to: dest) }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let hasSelection = !(currentSelection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasSelection, let sel = currentSelection, let doc = document, let ctl = controller {
            for (title, kind) in [("Highlight", AnnotationKind.highlight), ("Underline", .underline), ("Strikethrough", .strikeThrough), ("Squiggly Underline", .squiggly)] {
                menu.addItem(ClosureMenuItem(title: title) { [weak self] in ctl.addMarkup(kind, from: sel, document: doc); self?.clearSelection() })
            }
            let cat = NSMenuItem(title: "Highlight as", action: nil, keyEquivalent: ""); let sub = NSMenu()
            for c in StudyCategory.allCases {
                sub.addItem(ClosureMenuItem(title: c.title) { [weak self] in
                    ctl.setStudyCategory(c); ctl.addMarkup(.highlight, from: sel, document: doc); self?.clearSelection()
                })
            }
            cat.submenu = sub; menu.addItem(cat)
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Add to Vocabulary…") { [weak self] in self?.onAddVocabulary?(sel) })
            menu.addItem(ClosureMenuItem(title: "Speak (German)") { [weak self] in self?.onSpeak?(sel.string ?? "") })
            menu.addItem(ClosureMenuItem(title: "Expand to Sentence") { [weak self] in self?.expandSelection(paragraph: false) })
            menu.addItem(ClosureMenuItem(title: "Expand to Paragraph") { [weak self] in self?.expandSelection(paragraph: true) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Copy") { [weak self] in self?.copy(nil) })
            menu.addItem(.separator())
        }
        let p = convert(event.locationInWindow, from: nil)
        if let page = page(for: p, nearest: false), let ctl = controller, let doc = document {
            let pagePoint = convert(p, to: page)
            let idx = doc.index(for: page)
            menu.addItem(ClosureMenuItem(title: "Add Text Box Here") {
                ctl.createTextBox(page: idx, rect: CGRect(x: pagePoint.x, y: pagePoint.y - 90, width: 240, height: 90))
            })
            menu.addItem(ClosureMenuItem(title: "Add Sticky Note Here") { ctl.createSticky(page: idx, at: pagePoint) })
            if ctl.canPasteAnnotations { menu.addItem(ClosureMenuItem(title: "Paste") { ctl.paste(toPage: idx) }) }
        }
        menu.addItem(ClosureMenuItem(title: "Bookmark This Page") { [weak self] in self?.onAddBookmark?() })
        return menu
    }

    /// Expands the current selection to the enclosing sentence or paragraph (for "highlight whole sentence").
    func expandSelection(paragraph: Bool) {
        guard let sel = currentSelection, let page = sel.pages.first, let text = page.string else { return }
        let ns = text as NSString
        let selString = (sel.string ?? "")
        let r = ns.range(of: selString)
        guard r.location != NSNotFound else { return }
        let range = TextNormalizer.enclosingRange(in: text, around: r.location, paragraph: paragraph)
        let end = TextNormalizer.enclosingRange(in: text, around: max(r.upperBound - 1, r.location), paragraph: paragraph)
        let union = NSUnionRange(range, end)
        if let expanded = page.selection(for: union) { setCurrentSelection(expanded, animate: false) }
    }
}
