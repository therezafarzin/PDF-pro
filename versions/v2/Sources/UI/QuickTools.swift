import SwiftUI
import AppKit
import PDFKit

enum ToolKind: String, CaseIterable, Identifiable {
    case convert, combine, split, optimize, editPages, ocr, sign
    var id: String { rawValue }

    var title: String {
        switch self {
        case .convert: return "Batch Convert"
        case .combine: return "Combine Files"
        case .split: return "Batch Split"
        case .optimize: return "Optimize PDF"
        case .editPages: return "Edit Pages"
        case .ocr: return "OCR PDF"
        case .sign: return "Sign"
        }
    }
    var subtitle: String {
        switch self {
        case .convert: return "PDF to images, plain text, RTF or HTML"
        case .combine: return "Merge PDFs and images into one file"
        case .split: return "Cut PDFs by pages, ranges or chapters"
        case .optimize: return "Make PDF files smaller"
        case .editPages: return "Reorder, rotate, delete and insert pages"
        case .ocr: return "Make scanned PDFs searchable"
        case .sign: return "Draw a signature and place it on a page"
        }
    }
    var systemImage: String {
        switch self {
        case .convert: return "arrow.triangle.2.circlepath"
        case .combine: return "square.on.square"
        case .split: return "scissors"
        case .optimize: return "arrow.down.right.and.arrow.up.left"
        case .editPages: return "rectangle.3.group"
        case .ocr: return "text.viewfinder"
        case .sign: return "signature"
        }
    }
    var colors: [Color] {
        switch self {
        case .convert: return [Color(red: 0.36, green: 0.78, blue: 0.48), Color(red: 0.20, green: 0.60, blue: 0.40)]
        case .combine: return [Color(red: 0.36, green: 0.58, blue: 1.0), Color(red: 0.20, green: 0.38, blue: 0.92)]
        case .split: return [Color(red: 0.40, green: 0.80, blue: 0.55), Color(red: 0.22, green: 0.55, blue: 0.38)]
        case .optimize: return [Color(red: 0.40, green: 0.72, blue: 0.62), Color(red: 0.24, green: 0.55, blue: 0.50)]
        case .editPages: return [Color(red: 1.0, green: 0.66, blue: 0.28), Color(red: 0.95, green: 0.48, blue: 0.16)]
        case .ocr: return [Color(red: 0.34, green: 0.72, blue: 0.62), Color(red: 0.18, green: 0.52, blue: 0.46)]
        case .sign: return [Color(red: 0.72, green: 0.42, blue: 0.98), Color(red: 0.52, green: 0.28, blue: 0.88)]
        }
    }
}

struct ToolRequest: Identifiable {
    let id = UUID()
    let kind: ToolKind
    var urls: [URL] = []
}

struct ToolIcon: View {
    let kind: ToolKind
    var size: CGFloat = 40
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: kind.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Image(systemName: kind.systemImage).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: kind.colors[1].opacity(0.35), radius: 4, y: 2)
    }
}

// MARK: - Panel (same structure as the reference: title, layout / customize / sort buttons, two-column tool list)

struct QuickToolsPanel: View {
    @EnvironmentObject var app: AppState
    @AppStorage("quickTools.layout") private var layout = "list"
    @AppStorage("quickTools.sort") private var sort = "default"
    @AppStorage("quickTools.hidden") private var hiddenRaw = ""
    @State private var showCustomize = false

    private var hidden: Set<String> { Set(hiddenRaw.split(separator: ",").map(String.init)) }

    private var tools: [ToolKind] {
        let visible = ToolKind.allCases.filter { !hidden.contains($0.rawValue) }
        switch sort {
        case "name": return visible.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        case "usage":
            let order = Dictionary(uniqueKeysWithValues: ToolKind.allCases.enumerated().map { ($1, $0) })
            return visible.sorted { x, y in
                let ux = app.usage(of: x), uy = app.usage(of: y)
                return ux != uy ? ux > uy : (order[x] ?? 0) < (order[y] ?? 0)
            }
        default: return visible
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Quick Tools").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button { layout = layout == "list" ? "grid" : "list" } label: {
                    Image(systemName: layout == "list" ? "circle.grid.3x3.fill" : "list.bullet").frame(width: 28, height: 28)
                }.buttonStyle(.borderless).help(layout == "list" ? "Show as grid" : "Show as list")
                Button { showCustomize.toggle() } label: { Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28) }
                    .buttonStyle(.borderless).help("Choose which tools are shown")
                    .popover(isPresented: $showCustomize, arrowEdge: .bottom) { customizeView }
                Menu {
                    Picker("Sort", selection: $sort) {
                        Text("Default order").tag("default"); Text("Name").tag("name"); Text("Most used").tag("usage")
                    }.pickerStyle(.inline)
                } label: { Image(systemName: "arrow.down.to.line").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).fixedSize().help("Sort tools")
            }
            if tools.isEmpty {
                Text("All tools are hidden. Use the slider button to show them again.").font(.callout).foregroundStyle(.secondary)
            } else if layout == "list" {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 6) {
                    ForEach(tools) { ToolTile(kind: $0, vertical: false) }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                    ForEach(tools) { ToolTile(kind: $0, vertical: true) }
                }
            }
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous).stroke(Color.primary.opacity(0.07)))
    }

    private var customizeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Show tools").font(.headline)
            ForEach(ToolKind.allCases) { k in
                Toggle(isOn: Binding(get: { !hidden.contains(k.rawValue) }, set: { on in
                    var h = hidden
                    if on { h.remove(k.rawValue) } else { h.insert(k.rawValue) }
                    hiddenRaw = h.sorted().joined(separator: ",")
                })) { Label(k.title, systemImage: k.systemImage) }
            }
            Divider()
            Button("Show all") { hiddenRaw = "" }.buttonStyle(.link)
        }.padding(14).frame(width: 220)
    }
}

struct ToolTile: View {
    @EnvironmentObject var app: AppState
    let kind: ToolKind
    let vertical: Bool
    @State private var hover = false

    var body: some View {
        Button { app.openTool(kind) } label: {
            Group {
                if vertical {
                    VStack(spacing: 10) {
                        ToolIcon(kind: kind, size: 46)
                        Text(kind.title).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2)
                    }.frame(maxWidth: .infinity).padding(.vertical, 14)
                } else {
                    HStack(spacing: 14) {
                        ToolIcon(kind: kind, size: 40)
                        Text(kind.title).font(.system(size: 15, weight: .semibold))
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.radius + 2, style: .continuous).fill(hover ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(kind.subtitle)
        .animation(Theme.animation, value: hover)
    }
}

struct QuickToolsPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Quick Tools").font(.system(size: 28, weight: .semibold, design: .serif))
                Text("Everything runs on this Mac. Your original files are never changed; results are saved as new files.").foregroundStyle(.secondary)
                QuickToolsPanel()
            }.padding(28)
        }
    }
}

// MARK: - Host

struct ToolHost: View {
    @EnvironmentObject var app: AppState
    let request: ToolRequest
    var body: some View {
        switch request.kind {
        case .combine: CombineSheet(urls: request.urls)
        case .split: SplitSheet(urls: request.urls)
        case .optimize: OptimizeSheet(urls: request.urls)
        case .convert: ConvertSheet(urls: request.urls)
        case .ocr: OCRSheet(urls: request.urls)
        case .editPages: PageEditorSheet(url: request.urls.first)
        case .sign: SignatureSheet()
        }
    }
}

extension AppState {
    func usage(of kind: ToolKind) -> Int { UserDefaults.standard.integer(forKey: "toolUsage.\(kind.rawValue)") }

    /// Opens a tool. With no explicit files, tools that work on one document use the document being read.
    func openTool(_ kind: ToolKind, urls: [URL]? = nil) {
        var list = urls ?? []
        if urls == nil, let s = activeSession, kind != .combine, kind != .sign { list = [s.url] }
        if kind == .sign && activeSession == nil {
            Prompt.error("Open a document first", "Signatures are placed on the page you are reading. Open a PDF, then choose Sign.")
            return
        }
        UserDefaults.standard.set(usage(of: kind) + 1, forKey: "toolUsage.\(kind.rawValue)")
        toolRequest = ToolRequest(kind: kind, urls: list)
    }
}
