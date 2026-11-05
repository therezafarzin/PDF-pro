import SwiftUI
import AppKit
import PDFKit

struct PageThumbView: View {
    let item: PageItem
    let docs: [PDFDocument]
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let size = item.blankSize {
                Rectangle().fill(Color.white)
                    .aspectRatio(size.width / max(size.height, 1), contentMode: .fit)
                    .overlay(Text("Blank").font(.caption).foregroundStyle(.gray))
                    .shadow(radius: 1)
            } else if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).shadow(radius: 1)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .rotationEffect(.degrees(Double(item.rotation)))
        .animation(Theme.animation, value: item.rotation)
        .frame(width: 120, height: 150)
        .clipped()
        .task(id: item.id) {
            guard item.blankSize == nil, docs.indices.contains(item.source), let page = docs[item.source].page(at: item.page) else { return }
            image = page.thumbnail(of: CGSize(width: 240, height: 300), for: .cropBox)
        }
    }
}

/// Page organiser: reorder (drag), rotate, delete, duplicate, insert blank pages or pages from other PDFs.
/// Works on a plan; the original file is never modified. The result is saved as a new PDF.
struct PageEditorSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let url: URL?
    @State private var sources: [PDFDocument] = []
    @State private var sourceURL: URL?
    @State private var plan = PageEditPlan(pageCount: 0)
    @State private var selection: Set<UUID> = []
    @State private var anchor: UUID?
    @State private var errorText: String?
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ToolIcon(kind: .editPages, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Pages").font(.headline)
                    Text(sourceURL?.lastPathComponent ?? "Choose a PDF to begin").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !sources.isEmpty { Text("\(plan.items.count) pages").font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
            }.padding(14)
            Divider()
            if sources.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Button("Choose PDF…") { choose() }.buttonStyle(.borderedProminent)
                    if let e = errorText { Text(e).foregroundStyle(.red).font(.caption) }
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else {
                toolbar.padding(.horizontal, 14).padding(.vertical, 8)
                Divider()
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                        ForEach(Array(plan.items.enumerated()), id: \.element.id) { index, item in cell(index, item) }
                    }.padding(14)
                }
            }
            Divider()
            HStack {
                Text("Your annotations stay with the original document. Reordering pages in a copy does not move them.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let e = errorText, !sources.isEmpty { Text(e).font(.caption).foregroundStyle(.red) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Copy…") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(sources.isEmpty || !plan.isModified || saving)
            }.padding(14)
        }
        .frame(minWidth: 860, idealWidth: 940, minHeight: 620, idealHeight: 700)
        .onAppear { if let url, sources.isEmpty { load(url) } }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { plan.undo(); prune() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!plan.canUndo).help("Undo")
            Button { plan.redo(); prune() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!plan.canRedo).help("Redo")
            Divider().frame(height: 18)
            Button { plan.rotate(selection, by: -90) } label: { Label("Rotate Left", systemImage: "rotate.left") }.disabled(selection.isEmpty)
            Button { plan.rotate(selection, by: 90) } label: { Label("Rotate Right", systemImage: "rotate.right") }.disabled(selection.isEmpty)
            Button { plan.duplicate(selection) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }.disabled(selection.isEmpty)
            Button(role: .destructive) {
                if !plan.delete(selection) { NSSound.beep() }; prune()
            } label: { Label("Delete", systemImage: "trash") }.disabled(selection.isEmpty).keyboardShortcut(.delete, modifiers: [])
            Divider().frame(height: 18)
            Button { insertBlank() } label: { Label("Blank Page", systemImage: "doc.badge.plus") }
            Button { insertFromPDF() } label: { Label("Insert PDF…", systemImage: "doc.on.doc") }
            Divider().frame(height: 18)
            Button { selection = Set(plan.items.map { $0.id }) } label: { Text("Select All") }.keyboardShortcut("a", modifiers: .command)
            Button { plan.reverse() } label: { Text("Reverse Order") }
            Spacer()
        }.labelStyle(.titleAndIcon).controlSize(.small)
    }

    // MARK: Grid cell

    private func cell(_ index: Int, _ item: PageItem) -> some View {
        let selected = selection.contains(item.id)
        return VStack(spacing: 4) {
            PageThumbView(item: item, docs: sources)
            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor.opacity(0.2) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { click(item) }
        .draggable(item.id.uuidString)
        .dropDestination(for: String.self) { strings, _ in
            guard let s = strings.first, let id = UUID(uuidString: s) else { return false }
            let ids = selection.contains(id) ? selection : [id]
            plan.move(ids, to: index)
            return true
        }
    }

    private func click(_ item: PageItem) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let a = anchor,
           let ia = plan.items.firstIndex(where: { $0.id == a }), let ib = plan.items.firstIndex(where: { $0.id == item.id }) {
            selection = Set(plan.items[min(ia, ib)...max(ia, ib)].map { $0.id })
        } else if flags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            anchor = item.id
        } else {
            selection = [item.id]; anchor = item.id
        }
    }

    private func prune() { selection = selection.intersection(Set(plan.items.map { $0.id })) }

    // MARK: Actions

    private func choose() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK, let u = panel.url { load(u) }
    }

    private func load(_ u: URL) {
        errorText = nil
        FileAccess.begin(u)
        guard let doc = PDFDocument(url: u) else { errorText = "This file could not be opened."; return }
        if doc.isLocked {
            guard let pw = Prompt.text(title: "Password required", message: "Enter the password for “\(u.lastPathComponent)”.", okTitle: "Unlock"), doc.unlock(withPassword: pw) else {
                errorText = "The PDF is locked."; return
            }
        }
        guard doc.pageCount > 0 else { errorText = "This PDF has no pages."; return }
        sources = [doc]; sourceURL = u; plan = PageEditPlan(pageCount: doc.pageCount); selection = []
    }

    private func blankSize() -> CGSize {
        if let p = sources.first?.page(at: 0) { return PageGeometry(box: p.bounds(for: .cropBox), rotation: p.rotation).displaySize }
        return CGSize(width: 595, height: 842)
    }

    private func lastSelected() -> UUID? {
        plan.items.last(where: { selection.contains($0.id) })?.id
    }

    private func insertBlank() { plan.insertBlank(after: lastSelected(), size: blankSize()) }

    private func insertFromPDF() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let u = panel.url else { return }
        FileAccess.begin(u)
        guard let doc = PDFDocument(url: u), !doc.isLocked, doc.pageCount > 0 else { errorText = "That PDF can’t be inserted (unreadable or locked)."; return }
        sources.append(doc)
        plan.insertPages(source: sources.count - 1, pages: Array(0..<doc.pageCount), after: lastSelected())
    }

    private func save() {
        guard let src = sourceURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = OutputFolder.current ?? src.deletingLastPathComponent()
        panel.nameFieldStringValue = src.deletingPathExtension().lastPathComponent + " – edited.pdf"
        guard panel.runModal() == .OK, let out = panel.url else { return }
        if out.standardizedFileURL == src.standardizedFileURL {
            Prompt.error("Choose a different name", "Replacing the original would detach its annotations and bookmarks. Save a copy instead.")
            return
        }
        saving = true
        do {
            try PDFTools.savePages(plan: plan, sources: sources, output: out)
            saving = false
            NSWorkspace.shared.activateFileViewerSelecting([out])
            app.open(url: out)
            dismiss()
        } catch { saving = false; errorText = error.localizedDescription }
    }
}
