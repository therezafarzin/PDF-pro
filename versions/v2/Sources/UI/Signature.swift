import SwiftUI
import AppKit

/// Free-hand capture surface for drawing a signature with the mouse or trackpad.
final class SignaturePadNSView: NSView {
    var strokes: [[CGPoint]] = [] { didSet { needsDisplay = true } }
    var onChange: (([[CGPoint]]) -> Void)?
    private var current: [CGPoint] = []
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        current = [convert(event.locationInWindow, from: nil)]
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        current.append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if !current.isEmpty { strokes.append(current); onChange?(strokes) }
        current = []
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        NSColor(white: 0.8, alpha: 1).setStroke()
        let base = NSBezierPath(); base.move(to: NSPoint(x: 20, y: bounds.height * 0.72)); base.line(to: NSPoint(x: bounds.width - 20, y: bounds.height * 0.72))
        base.lineWidth = 1; base.stroke()
        NSColor.black.setStroke()
        for s in strokes + [current] where !s.isEmpty {
            let path = NSBezierPath()
            path.lineWidth = 2.4; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: s[0])
            if s.count == 1 { path.line(to: NSPoint(x: s[0].x + 0.1, y: s[0].y)) }
            for p in s.dropFirst() { path.line(to: p) }
            path.stroke()
        }
    }
}

struct SignaturePad: NSViewRepresentable {
    @Binding var strokes: [[CGPoint]]
    func makeNSView(context: Context) -> SignaturePadNSView {
        let v = SignaturePadNSView()
        v.onChange = { strokes = $0 }
        return v
    }
    func updateNSView(_ v: SignaturePadNSView, context: Context) {
        if v.strokes != strokes { v.strokes = strokes }
    }
}

struct SignatureShape: Shape {
    let strokes: [[CGPoint]]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for s in strokes {
            guard let f = s.first else { continue }
            func map(_ q: CGPoint) -> CGPoint { CGPoint(x: rect.minX + q.x * rect.width, y: rect.minY + q.y * rect.height) }
            p.move(to: map(f))
            if s.count == 1 { p.addLine(to: CGPoint(x: map(f).x + 0.1, y: map(f).y)) }
            for q in s.dropFirst() { p.addLine(to: map(q)) }
        }
        return p
    }
}

/// Offline signature: draw once, keep it, place it on the current page as grouped pen strokes.
/// This is a visual signature, not a certificate-based digital signature.
struct SignatureSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var saved: [SavedSignature] = []
    @State private var strokes: [[CGPoint]] = []
    @State private var selectedID: UUID?
    @State private var name = ""
    @State private var width = 170.0
    @State private var lineWidth = 2.0
    @State private var color: Color = .black

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ToolIcon(kind: .sign, size: 36)
                VStack(alignment: .leading, spacing: 2) { Text("Sign").font(.headline); Text("Offline signature placed on the page you are reading").font(.caption).foregroundStyle(.secondary) }
            }
            SectionHeader(title: "Saved signatures")
            if saved.isEmpty {
                Text("None yet. Draw one below and save it.").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(saved) { s in
                            VStack(spacing: 4) {
                                SignatureShape(strokes: s.strokes).stroke(Color.black, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                                    .aspectRatio(CGFloat(max(s.aspect, 0.2)), contentMode: .fit).frame(width: 120, height: 50).padding(8)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedID == s.id ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selectedID == s.id ? 2 : 1))
                                Text(s.name).font(.caption).lineLimit(1)
                            }
                            .onTapGesture { selectedID = s.id }
                            .contextMenu { Button("Delete", role: .destructive) { delete(s) } }
                        }
                    }.padding(2)
                }
            }
            SectionHeader(title: "Draw a new signature")
            SignaturePad(strokes: $strokes).frame(height: 130)
            HStack {
                TextField("Name (optional)", text: $name).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("Clear") { strokes = [] }.disabled(strokes.isEmpty)
                Button("Save Signature") { saveNew() }.disabled(SignatureMath.normalize(strokes) == nil)
                Spacer()
            }
            Divider()
            HStack(spacing: 18) {
                ColorPicker("Ink", selection: $color).fixedSize()
                CommitSlider(title: "Width on page", value: $width, range: 60...320, format: "%.0f pt")
                CommitSlider(title: "Pen thickness", value: $lineWidth, range: 0.8...5, format: "%.1f pt")
            }
            HStack {
                Text("Placed in the lower middle of the current page. Move it with the mouse; its strokes move together.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Place on Page \((app.activeSession?.currentPage ?? 0) + 1)") { place() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(selectedID == nil || app.activeSession == nil)
            }
        }
        .padding(20).frame(width: 600)
        .onAppear { saved = app.store.signatures(); selectedID = saved.first?.id }
    }

    private func saveNew() {
        guard let n = SignatureMath.normalize(strokes) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let sig = SavedSignature(name: trimmed.isEmpty ? "Signature \(saved.count + 1)" : trimmed, strokes: n.strokes, aspect: n.aspect)
        saved.append(sig)
        app.store.saveSignatures(saved)
        selectedID = sig.id; strokes = []; name = ""
    }

    private func delete(_ s: SavedSignature) {
        saved.removeAll { $0.id == s.id }
        app.store.saveSignatures(saved)
        if selectedID == s.id { selectedID = saved.first?.id }
    }

    private func place() {
        guard let session = app.activeSession, let sig = saved.first(where: { $0.id == selectedID }),
              let g = session.pdfView?.geometry(forIndex: session.currentPage) else { return }
        let center = CGPoint(x: g.box.midX, y: g.box.minY + g.box.height * 0.25)
        session.controller.addSignature(sig, page: session.currentPage, center: center, width: CGFloat(width), color: RGBA(color), lineWidth: lineWidth)
        dismiss()
    }
}
