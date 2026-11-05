import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            StudySettings().tabItem { Label("Study", systemImage: "graduationcap") }
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "command") }
            DataSettings().tabItem { Label("Data", systemImage: "externaldrive") }
        }.frame(width: 620, height: 520)
    }
}

struct GeneralSettings: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accentHex") private var accentHex = "#3354CC"
    @AppStorage("density") private var density = Density.regular.rawValue
    @AppStorage("reopenDocuments") private var reopen = true
    @AppStorage("defaultFitMode") private var fit = "width"
    @AppStorage("defaultDisplayMode") private var display = 1

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) { Text("Automatic").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }.pickerStyle(.segmented)
            ColorPicker("Accent color", selection: Binding(get: { RGBA(hex: accentHex)?.color ?? Theme.defaultAccent }, set: { accentHex = RGBA($0).hex }))
            Button("Reset accent color") { accentHex = "#3354CC" }.controlSize(.small)
            Picker("Interface density", selection: $density) { ForEach(Density.allCases) { Text($0.title).tag($0.rawValue) } }.pickerStyle(.segmented)
            Divider()
            Toggle("Reopen documents when the app starts", isOn: $reopen)
            Picker("New documents open with", selection: $fit) { Text("Fit width").tag("width"); Text("Fit page").tag("page") }
            Picker("Default layout", selection: $display) { Text("Single page").tag(0); Text("Continuous").tag(1); Text("Two pages").tag(2); Text("Two pages, continuous").tag(3) }
        }.formStyle(.grouped).padding()
    }
}

struct StudySettings: View {
    var body: some View {
        Form {
            Section("Study highlight colors") {
                ForEach(StudyCategory.allCases) { c in StudyColorRow(category: c) }
                Text("New highlights use the color of the selected category. Existing highlights keep their color.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Backups") {
                Stepper("Back up every \(max(UserDefaults.standard.integer(forKey: "backupIntervalMinutes"), 15)) minutes", value: Binding(
                    get: { max(UserDefaults.standard.integer(forKey: "backupIntervalMinutes"), 15) }, set: { UserDefaults.standard.set($0, forKey: "backupIntervalMinutes") }), in: 5...120, step: 5)
                Text("Applies after the next launch.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding()
    }
}

struct StudyColorRow: View {
    let category: StudyCategory
    @State private var color: Color = .yellow
    var body: some View {
        ColorPicker(category.title, selection: Binding(get: { color }, set: { color = $0; UserDefaults.standard.set(RGBA($0).hex, forKey: "categoryColor.\(category.rawValue)") }))
            .onAppear { color = (UserDefaults.standard.string(forKey: "categoryColor.\(category.rawValue)").flatMap { RGBA(hex: $0) } ?? category.defaultColor).color }
    }
}

struct ShortcutSettings: View {
    @EnvironmentObject var shortcuts: ShortcutManager
    @State private var recording: ShortcutAction?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            List(ShortcutAction.allCases) { a in
                HStack {
                    Text(a.title)
                    Spacer()
                    if recording == a {
                        ShortcutRecorder { b in
                            if let other = shortcuts.conflict(for: b, excluding: a) { message = "\(b.display) is already used by “\(other.title)”." }
                            else { shortcuts.set(a, b); message = nil }
                            recording = nil
                        } onCancel: { recording = nil }.frame(width: 120, height: 22)
                    } else {
                        Button(shortcuts.binding(a)?.display ?? "None") { recording = a }.buttonStyle(.bordered).controlSize(.small).frame(minWidth: 90)
                    }
                    Button { shortcuts.set(a, nil) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Remove shortcut")
                    Button { shortcuts.reset(a) } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.borderless).help("Restore default")
                }
            }
            HStack {
                if let m = message { Text(m).foregroundStyle(.red).font(.caption) }
                Spacer()
                Text("Changes apply to the menus immediately after reopening a menu.").font(.caption).foregroundStyle(.secondary)
                Button("Restore All Defaults") { shortcuts.resetAll() }
            }.padding(10)
        }
    }
}

struct DataSettings: View {
    @EnvironmentObject var app: AppState
    @State private var backups: [URL] = []
    var body: some View {
        Form {
            Section("Privacy") {
                Label("All documents, annotations and notes stay on this Mac. The app makes no network connections, needs no account and collects no telemetry.", systemImage: "lock.shield").font(.callout)
            }
            Section("Library database") {
                LabeledContent("Location") { Text(Store.defaultDirectory().path).font(.caption).textSelection(.enabled) }
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Store.defaultDirectory()]) }
                    Button("Back Up Now") { _ = try? app.backups.backup(app.store, label: "manual"); backups = app.backups.list() }
                }
            }
            Section("Backups (\(backups.count))") {
                ForEach(backups.prefix(6), id: \.self) { Text($0.lastPathComponent).font(.caption.monospaced()) }
                Text("To restore, quit the app and replace library.sqlite with a backup file.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding().onAppear { backups = app.backups.list() }
    }
}
