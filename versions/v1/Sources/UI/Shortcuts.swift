import SwiftUI
import AppKit

enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case openPDF, save, find, findInLibrary, export, print, closeTab, nextTab, previousTab
    case zoomIn, zoomOut, fitPage, fitWidth, actualSize, fullScreen, focusMode
    case toggleSidebar, toggleInspector, singlePage, continuousScroll, twoPage, nightMode, ruler
    case nextPage, previousPage, goToPage, bookmarkPage, rotateRight, rotateLeft
    case selectTool, highlight, underline, strikethrough, squiggly, textBox, stickyNote, pen, rectangle, ellipse, arrow, line, eraser
    case addVocabulary, speak, duplicate, group, bringToFront, sendToBack, lockAnnotation, selectAllAnnotations
    var id: String { rawValue }

    var title: String {
        switch self {
        case .openPDF: return "Open PDF…"; case .save: return "Save Now"; case .find: return "Find in Document"
        case .findInLibrary: return "Search Library"; case .export: return "Export PDF…"; case .print: return "Print…"
        case .closeTab: return "Close Tab"; case .nextTab: return "Next Tab"; case .previousTab: return "Previous Tab"
        case .zoomIn: return "Zoom In"; case .zoomOut: return "Zoom Out"; case .fitPage: return "Fit Page"
        case .fitWidth: return "Fit Width"; case .actualSize: return "Actual Size"; case .fullScreen: return "Full Screen"
        case .focusMode: return "Distraction-Free Mode"; case .toggleSidebar: return "Toggle Sidebar"
        case .toggleInspector: return "Toggle Inspector"; case .singlePage: return "Single Page"
        case .continuousScroll: return "Continuous Scroll"; case .twoPage: return "Two Pages"; case .nightMode: return "Night Mode"
        case .ruler: return "Reading Ruler"; case .nextPage: return "Next Page"; case .previousPage: return "Previous Page"
        case .goToPage: return "Go to Page…"; case .bookmarkPage: return "Bookmark Page"
        case .rotateRight: return "Rotate Right"; case .rotateLeft: return "Rotate Left"
        case .selectTool: return "Select Tool"; case .highlight: return "Highlight"; case .underline: return "Underline"
        case .strikethrough: return "Strikethrough"; case .squiggly: return "Squiggly Underline"
        case .textBox: return "Text Box"; case .stickyNote: return "Sticky Note"; case .pen: return "Pen"
        case .rectangle: return "Rectangle"; case .ellipse: return "Ellipse"; case .arrow: return "Arrow"; case .line: return "Line"
        case .eraser: return "Eraser"; case .addVocabulary: return "Add to Vocabulary"; case .speak: return "Speak Selection"
        case .duplicate: return "Duplicate Annotation"; case .group: return "Group Annotations"
        case .bringToFront: return "Bring to Front"; case .sendToBack: return "Send to Back"
        case .lockAnnotation: return "Lock / Unlock Annotation"; case .selectAllAnnotations: return "Select All Annotations on Page"
        }
    }
}

struct ShortcutBinding: Codable, Equatable {
    var key: String
    var command = false, shift = false, option = false, control = false

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "left": return .leftArrow; case "right": return .rightArrow; case "up": return .upArrow; case "down": return .downArrow
        case "return": return .return; case "escape": return .escape; case "tab": return .tab; case "space": return .space
        case "delete": return .delete
        default: return KeyEquivalent(key.first ?? " ")
        }
    }
    var modifiers: EventModifiers {
        var m: EventModifiers = []
        if command { m.insert(.command) }; if shift { m.insert(.shift) }
        if option { m.insert(.option) }; if control { m.insert(.control) }
        return m
    }
    var display: String {
        let names = ["left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↩", "escape": "⎋", "tab": "⇥", "space": "␣", "delete": "⌫"]
        return (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + (names[key] ?? key.uppercased())
    }
}

@MainActor
final class ShortcutManager: ObservableObject {
    static let shared = ShortcutManager()
    @Published private(set) var overrides: [String: ShortcutBinding?] = [:]
    private let defaultsKey = "customShortcuts.v1"

    static func b(_ key: String, _ mods: String = "c") -> ShortcutBinding {
        ShortcutBinding(key: key, command: mods.contains("c"), shift: mods.contains("s"), option: mods.contains("o"), control: mods.contains("k"))
    }

    static let defaults: [ShortcutAction: ShortcutBinding] = [
        .openPDF: b("o"), .save: b("s"), .find: b("f"), .findInLibrary: b("f", "co"), .export: b("e", "cs"), .print: b("p"),
        .closeTab: b("w"), .nextTab: b("]", "cs"), .previousTab: b("[", "cs"),
        .zoomIn: b("="), .zoomOut: b("-"), .fitPage: b("0"), .fitWidth: b("9"), .actualSize: b("1"),
        .fullScreen: b("f", "cs"), .focusMode: b("." , "cs"),
        .toggleSidebar: b("s", "ck"), .toggleInspector: b("i", "co"),
        .singlePage: b("1", "co"), .continuousScroll: b("2", "co"), .twoPage: b("3", "co"), .nightMode: b("n", "co"), .ruler: b("r", "co"),
        .nextPage: b("right", "co"), .previousPage: b("left", "co"), .goToPage: b("g"), .bookmarkPage: b("d"),
        .rotateRight: b("r"), .rotateLeft: b("r", "ck"),
        .selectTool: b("k", "co"), .highlight: b("h", "cs"), .underline: b("u", "cs"), .strikethrough: b("x", "cs"),
        .squiggly: b("u", "co"), .textBox: b("t", "cs"), .stickyNote: b("n", "cs"), .pen: b("d", "cs"),
        .rectangle: b("r", "cs"), .ellipse: b("c", "cs"), .arrow: b("a", "cs"), .line: b("l", "cs"), .eraser: b("e", "co"),
        .addVocabulary: b("y", "cs"), .speak: b("k", "cs"),
        .duplicate: b("d", "co"), .group: b("g", "cs"), .bringToFront: b("]", "co"), .sendToBack: b("[", "co"),
        .lockAnnotation: b("l", "co"), .selectAllAnnotations: b("a", "co"),
    ]

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let dict = try? JSONDecoder().decode([String: ShortcutBinding?].self, from: data) { overrides = dict }
    }

    func binding(_ a: ShortcutAction) -> ShortcutBinding? {
        if let o = overrides[a.rawValue] { return o }        // explicit override (may be nil = removed)
        return Self.defaults[a]
    }
    func set(_ a: ShortcutAction, _ b: ShortcutBinding?) { overrides[a.rawValue] = .some(b); persist() }
    func reset(_ a: ShortcutAction) { overrides.removeValue(forKey: a.rawValue); persist() }
    func resetAll() { overrides = [:]; persist() }
    private func persist() {
        if let d = try? JSONEncoder().encode(overrides) { UserDefaults.standard.set(d, forKey: defaultsKey) }
    }
    func conflict(for b: ShortcutBinding, excluding a: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != a && binding($0) == b }
    }
}

extension View {
    @ViewBuilder func appShortcut(_ a: ShortcutAction) -> some View {
        if let b = ShortcutManager.shared.binding(a) { self.keyboardShortcut(b.keyEquivalent, modifiers: b.modifiers) } else { self }
    }
}

/// Click, then press the desired key combination.
struct ShortcutRecorder: NSViewRepresentable {
    var onRecord: (ShortcutBinding) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView(); v.onRecord = onRecord; v.onCancel = onCancel
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ nsView: RecorderView, context: Context) {}

    final class RecorderView: NSView {
        var onRecord: ((ShortcutBinding) -> Void)?
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onCancel?(); return }
            let codes: [UInt16: String] = [123: "left", 124: "right", 125: "down", 126: "up", 36: "return", 48: "tab", 49: "space", 51: "delete"]
            let key = codes[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "").lowercased()
            guard !key.isEmpty else { return }
            let f = event.modifierFlags
            onRecord?(ShortcutBinding(key: key, command: f.contains(.command), shift: f.contains(.shift), option: f.contains(.option), control: f.contains(.control)))
        }
        override func draw(_ dirtyRect: NSRect) {
            let s = NSAttributedString(string: "Press shortcut…", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            s.draw(at: NSPoint(x: 4, y: 3))
        }
    }
}
