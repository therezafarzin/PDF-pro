import SwiftUI
import AppKit

/// Design tokens. One corner-radius scale, one spacing scale, scaled by the user's density setting.
enum Theme {
    static let radiusSmall: CGFloat = 6
    static let radius: CGFloat = 10
    static let radiusLarge: CGFloat = 14
    static let sidebarWidth: CGFloat = 264
    static let inspectorWidth: CGFloat = 300
    static let animation = Animation.easeInOut(duration: 0.22)
    static let defaultAccent = Color(red: 0.20, green: 0.33, blue: 0.80)
}

enum Density: String, CaseIterable, Identifiable {
    case compact, regular, comfortable
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scale: CGFloat { switch self { case .compact: return 0.8; case .regular: return 1; case .comfortable: return 1.25 } }
}

private struct DensityKey: EnvironmentKey { static let defaultValue: Density = .regular }
extension EnvironmentValues {
    var density: Density { get { self[DensityKey.self] } set { self[DensityKey.self] = newValue } }
}

extension View {
    func card(padding: CGFloat = 12) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String = ""
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .padding(24).frame(maxWidth: 320).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Modal helpers (NSAlert based so they work from menu commands as well).
@MainActor
enum Prompt {
    static func text(title: String, message: String = "", defaultValue: String = "", okTitle: String = "OK") -> String? {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: okTitle); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func confirm(title: String, message: String, okTitle: String = "OK", destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = message
        alert.alertStyle = destructive ? .warning : .informational
        alert.addButton(withTitle: okTitle); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func error(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = message; alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
