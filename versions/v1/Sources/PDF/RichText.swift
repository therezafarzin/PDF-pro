import AppKit

/// Rich-text engine for annotation text.
///
/// Design notes (bidirectional text):
///  * Editing uses a TextKit 1 `NSTextView`, whose Core Text based layout implements the Unicode
///    Bidirectional Algorithm, Arabic/Persian shaping and joining, ZWNJ, caret movement and selection.
///  * Paragraph direction is `.natural` by default: it is derived from the first strong character
///    of each paragraph, exactly like the UBA (rules P2/P3). Users can override per paragraph.
///  * Text is persisted as RTF, which keeps fonts, colours, paragraph direction and Unicode intact.
///  * On-screen display and PDF export render with the same `NSAttributedString.draw(with:)`
///    call, so what is exported is exactly what was edited.
enum RichText {

    // MARK: Encoding

    static func decode(_ content: TextContent?) -> NSAttributedString {
        guard let c = content else { return NSAttributedString(string: "", attributes: defaultAttributes()) }
        if !c.rtf.isEmpty,
           let a = try? NSAttributedString(data: c.rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                           documentAttributes: nil) {
            return a
        }
        return NSAttributedString(string: c.plain, attributes: defaultAttributes())
    }

    static func encode(_ a: NSAttributedString) -> TextContent {
        let range = NSRange(location: 0, length: a.length)
        let data = (try? a.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])) ?? Data()
        return TextContent(rtf: data, plain: a.string)
    }

    // MARK: Attributes

    static func font(family: String, size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        let fm = NSFontManager.shared
        var f = fm.font(withFamily: family, traits: [], weight: 5, size: size) ?? NSFont.systemFont(ofSize: size)
        if bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    static func paragraphStyle(alignment: TextAlignmentOption, direction: BaseDirectionOption,
                               lineSpacing: Double, paragraphSpacing: Double) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        switch alignment {
        case .natural: p.alignment = .natural
        case .left: p.alignment = .left
        case .center: p.alignment = .center
        case .right: p.alignment = .right
        case .justified: p.alignment = .justified
        }
        switch direction {
        case .auto: p.baseWritingDirection = .natural
        case .ltr: p.baseWritingDirection = .leftToRight
        case .rtl: p.baseWritingDirection = .rightToLeft
        }
        p.lineSpacing = CGFloat(lineSpacing)
        p.paragraphSpacing = CGFloat(paragraphSpacing)
        p.lineBreakMode = .byWordWrapping
        return p
    }

    static func defaultAttributes() -> [NSAttributedString.Key: Any] {
        [.font: font(family: "Helvetica Neue", size: 14),
         .foregroundColor: NSColor.black,
         .paragraphStyle: paragraphStyle(alignment: .natural, direction: .auto, lineSpacing: 2, paragraphSpacing: 4)]
    }

    static func attributes(for p: TextStylePreset) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [
            .font: font(family: p.fontFamily, size: CGFloat(p.fontSize), bold: p.bold, italic: p.italic),
            .foregroundColor: p.color.nsColor,
            .paragraphStyle: paragraphStyle(alignment: p.alignment, direction: p.direction,
                                            lineSpacing: p.lineSpacing, paragraphSpacing: p.paragraphSpacing),
        ]
        if p.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if p.strikethrough { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return a
    }

    // MARK: Text view factory

    /// TextKit 1 text view configured for bidirectional rich text editing.
    static func makeTextView(frame: CGRect) -> NSTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(frame.width, 1), height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)

        let tv = NSTextView(frame: frame, textContainer: container)
        tv.isRichText = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = []
        tv.textContainerInset = .zero
        tv.importsGraphics = false
        tv.usesFontPanel = true
        tv.usesRuler = false
        tv.allowsDocumentBackgroundColorChange = false
        tv.baseWritingDirection = .natural
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        return tv
    }

    /// Height required to lay out `attributed` in the given width (no padding).
    static func requiredHeight(for attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attributed.length > 0, width > 1 else { return 0 }
        let r = attributed.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(r.height)
    }
}

// MARK: - Formatting operations

typealias TextOp = (NSMutableAttributedString, NSRange) -> Void

enum TextOps {
    static func fontFamily(_ family: String) -> TextOp {
        { s, r in
            let fm = NSFontManager.shared
            s.enumerateAttribute(.font, in: r, options: []) { v, sub, _ in
                let old = (v as? NSFont) ?? RichText.font(family: "Helvetica Neue", size: 14)
                let traits = fm.traits(of: old)
                let new = fm.font(withFamily: family, traits: traits, weight: 5, size: old.pointSize)
                    ?? fm.font(withFamily: family, traits: [], weight: 5, size: old.pointSize)
                if let new { s.addAttribute(.font, value: new, range: sub) }
            }
        }
    }

    static func fontSize(_ size: CGFloat) -> TextOp {
        { s, r in
            s.enumerateAttribute(.font, in: r, options: []) { v, sub, _ in
                let old = (v as? NSFont) ?? RichText.font(family: "Helvetica Neue", size: 14)
                if let new = NSFont(descriptor: old.fontDescriptor, size: size) { s.addAttribute(.font, value: new, range: sub) }
            }
        }
    }

    static func trait(_ trait: NSFontTraitMask, on: Bool) -> TextOp {
        { s, r in
            let fm = NSFontManager.shared
            s.enumerateAttribute(.font, in: r, options: []) { v, sub, _ in
                let old = (v as? NSFont) ?? RichText.font(family: "Helvetica Neue", size: 14)
                let new = on ? fm.convert(old, toHaveTrait: trait) : fm.convert(old, toNotHaveTrait: trait)
                s.addAttribute(.font, value: new, range: sub)
            }
        }
    }

    static func color(_ c: NSColor) -> TextOp { { s, r in s.addAttribute(.foregroundColor, value: c, range: r) } }

    static func underline(_ on: Bool) -> TextOp {
        { s, r in
            if on { s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r) }
            else { s.removeAttribute(.underlineStyle, range: r) }
        }
    }
    static func strikethrough(_ on: Bool) -> TextOp {
        { s, r in
            if on { s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r) }
            else { s.removeAttribute(.strikethroughStyle, range: r) }
        }
    }

    private static func modifyParagraphs(_ s: NSMutableAttributedString, _ r: NSRange, _ body: (NSMutableParagraphStyle) -> Void) {
        let full = (s.string as NSString).paragraphRange(for: r)
        s.enumerateAttribute(.paragraphStyle, in: full, options: []) { v, sub, _ in
            let p = ((v as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            body(p)
            s.addAttribute(.paragraphStyle, value: p, range: sub)
        }
    }

    static func alignment(_ a: TextAlignmentOption) -> TextOp {
        { s, r in
            modifyParagraphs(s, r) { p in
                switch a {
                case .natural: p.alignment = .natural
                case .left: p.alignment = .left
                case .center: p.alignment = .center
                case .right: p.alignment = .right
                case .justified: p.alignment = .justified
                }
            }
        }
    }

    /// Sets the *paragraph base direction* (not just alignment). `.auto` returns to UBA first-strong detection.
    static func direction(_ d: BaseDirectionOption) -> TextOp {
        { s, r in
            modifyParagraphs(s, r) { p in
                switch d {
                case .auto: p.baseWritingDirection = .natural
                case .ltr: p.baseWritingDirection = .leftToRight
                case .rtl: p.baseWritingDirection = .rightToLeft
                }
            }
        }
    }

    static func lineSpacing(_ v: CGFloat) -> TextOp { { s, r in modifyParagraphs(s, r) { $0.lineSpacing = v } } }
    static func paragraphSpacing(_ v: CGFloat) -> TextOp { { s, r in modifyParagraphs(s, r) { $0.paragraphSpacing = v } } }

    /// Replaces character and paragraph formatting with a reusable style.
    static func preset(_ p: TextStylePreset) -> TextOp {
        { s, r in
            let attrs = RichText.attributes(for: p)
            s.removeAttribute(.underlineStyle, range: r)
            s.removeAttribute(.strikethroughStyle, range: r)
            s.addAttributes(attrs, range: r)
        }
    }

    enum ListKind { case bullet, numbered }

    /// Toggles bullet / numbered list markers on the selected paragraphs (hanging indent included).
    static func toggleList(_ kind: ListKind) -> TextOp {
        { s, r in
            let ns = s.string as NSString
            let full = ns.paragraphRange(for: r)
            var paragraphs: [NSRange] = []
            ns.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in paragraphs.append(range) }
            if paragraphs.isEmpty { paragraphs = [NSRange(location: full.location, length: 0)] }

            func marker(_ i: Int) -> String { kind == .bullet ? "•\u{00A0}" : "\(i + 1).\u{00A0}" }
            func existingMarkerLength(_ range: NSRange) -> Int {
                let text = ns.substring(with: range)
                if text.hasPrefix("•\u{00A0}") { return 2 }
                if let dot = text.firstIndex(of: "."), text[text.startIndex..<dot].allSatisfy({ $0.isNumber }), !text[text.startIndex..<dot].isEmpty,
                   text[text.index(after: dot)...].hasPrefix("\u{00A0}") {
                    return text.distance(from: text.startIndex, to: dot) + 2
                }
                return 0
            }
            let allMarked = paragraphs.allSatisfy { existingMarkerLength($0) > 0 }
            for (i, range) in paragraphs.enumerated().reversed() {
                let len = existingMarkerLength(range)
                if allMarked {
                    s.deleteCharacters(in: NSRange(location: range.location, length: len))
                } else {
                    if len > 0 { s.deleteCharacters(in: NSRange(location: range.location, length: len)) }
                    let attrs = range.location < s.length ? s.attributes(at: range.location, effectiveRange: nil) : RichText.defaultAttributes()
                    s.insert(NSAttributedString(string: marker(i), attributes: attrs), at: range.location)
                }
            }
            // hanging indent
            let newFull = NSRange(location: full.location, length: max(0, s.length - full.location))
            let indent: CGFloat = allMarked ? 0 : 16
            s.enumerateAttribute(.paragraphStyle, in: newFull, options: []) { v, sub, _ in
                let p = ((v as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                p.headIndent = indent
                p.firstLineHeadIndent = 0
                s.addAttribute(.paragraphStyle, value: p, range: sub)
            }
        }
    }

    // MARK: State queries

    static func hasTrait(_ trait: NSFontTraitMask, in s: NSAttributedString, range: NSRange, typing: [NSAttributedString.Key: Any]) -> Bool {
        let font: NSFont?
        if range.length > 0, range.location < s.length {
            font = s.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        } else {
            font = typing[.font] as? NSFont
        }
        guard let f = font else { return false }
        return NSFontManager.shared.traits(of: f).contains(trait)
    }
}

// MARK: - Applying ops to a live text view

extension NSTextView {
    /// Applies an operation to the selection (or to the typing attributes when the selection is empty).
    func applyOp(_ op: TextOp, paragraph: Bool = false) {
        guard let storage = textStorage else { return }
        var range = selectedRange()
        if paragraph { range = (storage.string as NSString).paragraphRange(for: range) }
        if range.length == 0 {
            let probe = NSMutableAttributedString(string: " ", attributes: typingAttributes)
            op(probe, NSRange(location: 0, length: 1))
            if probe.length > 0 { typingAttributes = probe.attributes(at: 0, effectiveRange: nil) }
            return
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        op(storage, range)
        storage.endEditing()
        didChangeText()
    }
}
