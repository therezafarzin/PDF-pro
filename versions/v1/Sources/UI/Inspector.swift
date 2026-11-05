import SwiftUI
import AppKit

struct InspectorView: View {
    @ObservedObject var session: ReaderSession
    @ObservedObject var controller: AnnotationController
    @State private var editingStyle: TextStylePreset?

    private var selected: [AnnotationModel] { controller.selectedModels }
    private var hasText: Bool { selected.contains { $0.kind.isTextual } }
    private var first: AnnotationModel? { selected.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                toolSection
                if !selected.isEmpty {
                    if hasText { textSection; boxSection }
                    else if let f = first, !f.kind.isMarkup { strokeSection }
                    else if first?.kind.isMarkup == true { markupSection }
                    arrangeSection
                }
                stylesSection
            }.padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .sheet(item: $editingStyle) { preset in
            TextStyleEditor(preset: preset) { saved in
                controller.store.saveTextStyle(saved); controller.textStyles = controller.store.textStyles(); editingStyle = nil
            } onCancel: { editingStyle = nil }
        }
    }

    // MARK: Tool options

    @ViewBuilder private var toolSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: controller.tool.title)
            if controller.tool.markupKind != nil || controller.tool == .vocabulary {
                HStack(spacing: 6) {
                    ForEach(StudyCategory.allCases) { c in
                        Button { controller.setStudyCategory(c) } label: {
                            VStack(spacing: 3) {
                                Circle().fill((controller.categoryColors[c] ?? c.defaultColor).color).frame(width: 22, height: 22)
                                    .overlay(Circle().stroke(controller.studyCategory == c ? Color.primary : Color.clear, lineWidth: 2))
                                Text(c.title).font(.system(size: 9)).lineLimit(1)
                            }
                        }.buttonStyle(.plain).help(c.title)
                    }
                }
                ColorPicker("Custom color", selection: Binding(get: { controller.markupColor.color }, set: { controller.markupColor = RGBA($0); controller.studyCategory = nil }))
            } else if controller.tool == .select && selected.isEmpty {
                Text("Select an annotation to edit it, or choose a tool in the toolbar. Hold ⌘ and click a highlight to select it.").font(.caption).foregroundStyle(.secondary)
            } else if [.ink, .pencil, .line, .arrow, .rectangle, .ellipse].contains(controller.tool) {
                ColorPicker("Stroke", selection: Binding(get: { controller.stroke.color }, set: { controller.stroke = RGBA($0) }))
                CommitSlider(title: "Width", value: Binding(get: { controller.strokeWidth }, set: { controller.strokeWidth = $0 }), range: 0.5...16, format: "%.1f pt")
                if controller.tool == .rectangle || controller.tool == .ellipse {
                    Toggle("Fill", isOn: Binding(get: { controller.shapeFill != nil }, set: { controller.shapeFill = $0 ? controller.stroke.with(alpha: 0.25) : nil }))
                    if controller.shapeFill != nil {
                        ColorPicker("Fill color", selection: Binding(get: { (controller.shapeFill ?? .clear).color }, set: { controller.shapeFill = RGBA($0) }))
                    }
                }
                CommitSlider(title: "Opacity", value: Binding(get: { controller.shapeOpacity }, set: { controller.shapeOpacity = $0 }), range: 0.1...1, format: "%.0f%%", scale: 100)
            } else if controller.tool == .textBox {
                Text("Click or drag on a page to place a text box. Double-click a box to edit it.").font(.caption).foregroundStyle(.secondary)
                Picker("New boxes use", selection: Binding(get: { controller.newTextPreset?.id ?? "" }, set: { id in controller.newTextPreset = controller.textStyles.first { $0.id == id } })) {
                    Text("Plain").tag(""); ForEach(controller.textStyles) { Text($0.name).tag($0.id) }
                }
            } else if controller.tool == .eraser {
                Text("Drag over (or click) highlights, pen strokes, shapes and lines to erase them. Text boxes: select and press Delete. Tip: marking already-marked text with the same tool toggles it off.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Text

    private let favoriteFamilies = ["Helvetica Neue", "Georgia", "Palatino", "Times New Roman", "Avenir Next", "Menlo",
                                    "Geeza Pro", "Noto Naskh Arabic", "Al Nile", "Damascus", "Baghdad", "Farah", "KufiStandard GK", "Nadeem", "DecoType Naskh"]
    private var families: [String] {
        let all = Set(NSFontManager.shared.availableFontFamilies)
        let fav = favoriteFamilies.filter { all.contains($0) }
        return fav + NSFontManager.shared.availableFontFamilies.filter { !fav.contains($0) }
    }

    private var currentFont: NSFont? {
        guard let m = first, m.kind.isTextual else { return nil }
        let a = RichText.decode(m.text)
        return a.length > 0 ? a.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
    }

    @ViewBuilder private var textSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Text")
            Picker("Font", selection: Binding(get: { currentFont?.familyName ?? "Helvetica Neue" }, set: { controller.formatText(TextOps.fontFamily($0)) })) {
                ForEach(families, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Stepper(value: Binding(get: { Double(currentFont?.pointSize ?? 14) }, set: { controller.formatText(TextOps.fontSize(CGFloat($0))) }), in: 6...96, step: 1) {
                    Text("Size \(Int(currentFont?.pointSize ?? 14))")
                }
                ColorPicker("", selection: Binding(get: { Color.black }, set: { controller.formatText(TextOps.color(NSColor($0))) })).labelsHidden().help("Text color")
            }
            HStack(spacing: 4) {
                fmt("bold", "Bold") { toggleTrait(.boldFontMask) }
                fmt("italic", "Italic") { toggleTrait(.italicFontMask) }
                fmt("underline", "Underline") { controller.formatText(TextOps.underline(true)) }
                fmt("strikethrough", "Strikethrough") { controller.formatText(TextOps.strikethrough(true)) }
                Divider().frame(height: 16)
                fmt("list.bullet", "Bulleted list") { controller.formatText(TextOps.toggleList(.bullet), paragraph: true) }
                fmt("list.number", "Numbered list") { controller.formatText(TextOps.toggleList(.numbered), paragraph: true) }
            }
            Text("Alignment").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                fmt("text.alignleft", "Left") { controller.formatText(TextOps.alignment(.left), paragraph: true) }
                fmt("text.aligncenter", "Center") { controller.formatText(TextOps.alignment(.center), paragraph: true) }
                fmt("text.alignright", "Right") { controller.formatText(TextOps.alignment(.right), paragraph: true) }
                fmt("text.justify", "Justify") { controller.formatText(TextOps.alignment(.justified), paragraph: true) }
                fmt("arrow.left.and.right", "Natural (follows text direction)") { controller.formatText(TextOps.alignment(.natural), paragraph: true) }
            }
            Text("Paragraph direction").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding<BaseDirectionOption>(get: { .auto }, set: { controller.formatText(TextOps.direction($0), paragraph: true) })) {
                Text("Auto").tag(BaseDirectionOption.auto); Text("LTR").tag(BaseDirectionOption.ltr); Text("RTL").tag(BaseDirectionOption.rtl)
            }.pickerStyle(.segmented).labelsHidden()
            Text("Auto follows the first strong letter, like the Unicode bidi algorithm. Mixed Persian/German text inside one paragraph is laid out correctly either way.").font(.caption2).foregroundStyle(.tertiary)
            CommitSlider(title: "Line spacing", value: Binding(get: { 2 }, set: { controller.formatText(TextOps.lineSpacing(CGFloat($0)), paragraph: true) }), range: 0...20, format: "%.0f pt")
            CommitSlider(title: "Paragraph spacing", value: Binding(get: { 4 }, set: { controller.formatText(TextOps.paragraphSpacing(CGFloat($0)), paragraph: true) }), range: 0...30, format: "%.0f pt")
            Button("Fonts…") { NSFontManager.shared.orderFrontFontPanel(nil) }.controlSize(.small)
        }
    }

    private func toggleTrait(_ t: NSFontTraitMask) {
        var on = true
        if let tv = controller.activeTextView, controller.editingID != nil {
            on = !TextOps.hasTrait(t, in: tv.attributedString(), range: tv.selectedRange(), typing: tv.typingAttributes)
        } else if let f = currentFont { on = !NSFontManager.shared.traits(of: f).contains(t) }
        controller.formatText(TextOps.trait(t, on: on))
    }

    private func fmt(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 24, height: 22) }.buttonStyle(.bordered).controlSize(.small).help(help)
    }

    // MARK: Box / stroke

    private func styleBinding<T>(_ kp: WritableKeyPath<AnnotationStyle, T>, default d: T) -> Binding<T> {
        Binding(get: { first?.style[keyPath: kp] ?? d }, set: { v in controller.setStyle { $0[keyPath: kp] = v } })
    }

    @ViewBuilder private var boxSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Box")
            Toggle("Background", isOn: Binding(get: { first?.style.fill != nil }, set: { on in controller.setStyle { $0.fill = on ? RGBA(1, 1, 1, 0.9) : nil } }))
            if first?.style.fill != nil {
                ColorPicker("Background color", selection: Binding(get: { (first?.style.fill ?? .white).color }, set: { c in controller.setStyle { $0.fill = RGBA(c) } }))
            }
            ColorPicker("Border color", selection: Binding(get: { (first?.style.stroke ?? .black).color }, set: { c in controller.setStyle { $0.stroke = RGBA(c) } }))
            CommitSlider(title: "Border width", value: styleBinding(\.strokeWidth, default: 1), range: 0...8, format: "%.1f pt")
            CommitSlider(title: "Corner radius", value: styleBinding(\.cornerRadius, default: 0), range: 0...30, format: "%.0f pt")
            CommitSlider(title: "Padding", value: styleBinding(\.padding, default: 6), range: 0...30, format: "%.0f pt")
            CommitSlider(title: "Opacity", value: styleBinding(\.opacity, default: 1), range: 0.05...1, format: "%.0f%%", scale: 100)
            Button("Fit Box to Text") { controller.fitToText() }.controlSize(.small)
        }
    }

    @ViewBuilder private var strokeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Appearance")
            ColorPicker("Stroke", selection: Binding(get: { (first?.style.stroke ?? .black).color }, set: { c in controller.setStyle { $0.stroke = RGBA(c) } }))
            CommitSlider(title: "Width", value: styleBinding(\.strokeWidth, default: 2), range: 0.5...16, format: "%.1f pt")
            CommitSlider(title: "Opacity", value: styleBinding(\.opacity, default: 1), range: 0.1...1, format: "%.0f%%", scale: 100)
            Toggle("Dashed", isOn: styleBinding(\.dashed, default: false))
            if first?.kind == .rectangle || first?.kind == .ellipse {
                Toggle("Fill", isOn: Binding(get: { first?.style.fill != nil }, set: { on in controller.setStyle { $0.fill = on ? $0.stroke.with(alpha: 0.25) : nil } }))
            }
        }
    }

    @ViewBuilder private var markupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Markup")
            ColorPicker("Color", selection: Binding(get: { (first?.style.stroke ?? .black).color }, set: { c in controller.setStyle { $0.stroke = RGBA(c) } }))
            CommitSlider(title: "Opacity", value: styleBinding(\.opacity, default: 0.4), range: 0.1...1, format: "%.0f%%", scale: 100)
        }
    }

    @ViewBuilder private var arrangeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Arrange")
            HStack(spacing: 4) {
                fmt("square.3.layers.3d.top.filled", "Bring to Front") { controller.reorder(.front) }
                fmt("square.3.layers.3d.bottom.filled", "Send to Back") { controller.reorder(.back) }
                fmt("plus.square.on.square", "Duplicate") { controller.duplicateSelection() }
                fmt(selected.allSatisfy { $0.locked } ? "lock.open" : "lock", "Lock / Unlock") { controller.toggleLock() }
                fmt("trash", "Delete") { controller.deleteSelection() }
            }
            HStack(spacing: 4) {
                Button("Group") { controller.group() }.disabled(selected.count < 2)
                Button("Ungroup") { controller.ungroup() }.disabled(!selected.contains { $0.groupID != nil })
            }.controlSize(.small)
        }
    }

    // MARK: Reusable styles

    @ViewBuilder private var stylesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { SectionHeader(title: "Text Styles"); Spacer()
                Button { editingStyle = TextStylePreset(name: "New Style", fontFamily: "Helvetica Neue", fontSize: 14, sort: controller.textStyles.count) } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
            }
            ForEach(controller.textStyles) { p in
                HStack {
                    Button { controller.applyPreset(p) } label: {
                        HStack {
                            RoundedRectangle(cornerRadius: 3).fill((p.box.fill ?? .white).color).frame(width: 16, height: 16)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(p.box.stroke.color.opacity(p.box.strokeWidth > 0 ? 1 : 0.2)))
                            Text(p.name).font(.system(size: 12.5, weight: controller.newTextPreset?.id == p.id ? .semibold : .regular)); Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Menu {
                        Button("Edit…") { editingStyle = p }
                        Button("Duplicate") { var c = p; c.id = UUID().uuidString; c.name += " Copy"; controller.store.saveTextStyle(c); controller.textStyles = controller.store.textStyles() }
                        Button("Delete", role: .destructive) { controller.store.deleteTextStyle(p.id); controller.textStyles = controller.store.textStyles() }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
            Text("Click a style to apply it to the selected text box, or to the text you are editing. It also becomes the default for new text boxes.").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// Slider that commits once when released (keeps undo history and the database tidy).
struct CommitSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var scale: Double = 1
    @State private var local: Double = 0
    @State private var dragging = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title).font(.caption).foregroundStyle(.secondary); Spacer()
                Text(String(format: format, (dragging ? local : value) * scale)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            Slider(value: Binding(get: { dragging ? local : value }, set: { local = $0 }), in: range) { editing in
                if editing { local = value; dragging = true } else { value = local; dragging = false }
            }.controlSize(.small)
        }
    }
}

struct TextStyleEditor: View {
    @State var preset: TextStylePreset
    let onSave: (TextStylePreset) -> Void
    let onCancel: () -> Void
    private var families: [String] { NSFontManager.shared.availableFontFamilies }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Text Style").font(.headline)
            Form {
                TextField("Name", text: $preset.name)
                Picker("Font", selection: $preset.fontFamily) { ForEach(families, id: \.self) { Text($0).tag($0) } }
                Stepper("Size: \(Int(preset.fontSize))", value: $preset.fontSize, in: 6...96)
                HStack { Toggle("Bold", isOn: $preset.bold); Toggle("Italic", isOn: $preset.italic); Toggle("Underline", isOn: $preset.underline); Toggle("Strike", isOn: $preset.strikethrough) }
                ColorPicker("Text color", selection: Binding(get: { preset.color.color }, set: { preset.color = RGBA($0) }))
                Picker("Alignment", selection: $preset.alignment) { ForEach(TextAlignmentOption.allCases) { Text($0.title).tag($0) } }
                Picker("Direction", selection: $preset.direction) { ForEach(BaseDirectionOption.allCases) { Text($0.title).tag($0) } }
                Stepper("Line spacing: \(Int(preset.lineSpacing))", value: $preset.lineSpacing, in: 0...20)
                Stepper("Paragraph spacing: \(Int(preset.paragraphSpacing))", value: $preset.paragraphSpacing, in: 0...30)
                Toggle("Background", isOn: Binding(get: { preset.box.fill != nil }, set: { preset.box.fill = $0 ? RGBA(1, 1, 1, 0.9) : nil }))
                if preset.box.fill != nil { ColorPicker("Background color", selection: Binding(get: { (preset.box.fill ?? .white).color }, set: { preset.box.fill = RGBA($0) })) }
                ColorPicker("Border color", selection: Binding(get: { preset.box.stroke.color }, set: { preset.box.stroke = RGBA($0) }))
                Stepper("Border width: \(String(format: "%.1f", preset.box.strokeWidth))", value: $preset.box.strokeWidth, in: 0...8, step: 0.5)
                Stepper("Corner radius: \(Int(preset.box.cornerRadius))", value: $preset.box.cornerRadius, in: 0...30)
            }
            HStack { Spacer(); Button("Cancel", action: onCancel); Button("Save") { onSave(preset) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 440)
    }
}
