import Foundation

enum TextDirection { case ltr, rtl, neutral }

/// Text utilities for German + Persian/Arabic study material.
enum TextNormalizer {

    // MARK: Direction

    private static func isRTLScalar(_ v: UInt32) -> Bool {
        (0x0590...0x08FF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v)
    }

    /// Direction of the first strong character, like the Unicode Bidirectional Algorithm's rule P2/P3.
    static func dominantDirection(of s: String) -> TextDirection {
        for u in s.unicodeScalars {
            if isRTLScalar(u.value) { return (u.properties.isAlphabetic || u.properties.numericType == nil) ? .rtl : .neutral }
            if u.properties.isAlphabetic { return .ltr }
        }
        return .neutral
    }

    static func containsRTL(_ s: String) -> Bool { s.unicodeScalars.contains { isRTLScalar($0.value) } }
    static func containsLTRLetters(_ s: String) -> Bool {
        s.unicodeScalars.contains { !isRTLScalar($0.value) && $0.properties.isAlphabetic }
    }
    static func isMixedDirection(_ s: String) -> Bool { containsRTL(s) && containsLTRLetters(s) }

    // MARK: Normalisation

    private static let persianDigits = Array("۰۱۲۳۴۵۶۷۸۹")
    private static let arabicDigits = Array("٠١٢٣٤٥٦٧٨٩")
    private static let bidiControls: Set<UInt32> = [0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x061C]

    /// Form used for the full-text index and queries. Keeps case/umlauts (the FTS tokenizer
    /// removes those itself) but unifies things the tokenizer cannot: ß, Arabic/Persian letter
    /// variants, digits, diacritics, ZWNJ and bidi control characters.
    static func indexForm(_ input: String) -> String {
        var out = String.UnicodeScalarView()
        let s = input.precomposedStringWithCompatibilityMapping
        for u in s.unicodeScalars {
            let v = u.value
            switch v {
            case 0x0643: out.append(Unicode.Scalar(0x06A9)!)             // ك -> ک
            case 0x064A, 0x0649: out.append(Unicode.Scalar(0x06CC)!)     // ي ى -> ی
            case 0x06C0: out.append(Unicode.Scalar(0x0647)!)             // ۀ -> ه
            case 0x0640: continue                                        // tatweel
            case 0x064B...0x065F, 0x0670: continue                       // harakat
            case 0x200C: out.append(" ")                                 // ZWNJ -> space
            case 0x200D: continue                                        // ZWJ
            case _ where bidiControls.contains(v): continue
            case 0x00DF: out.append("s"); out.append("s")                // ß -> ss
            case 0x1E9E: out.append("S"); out.append("S")
            case 0x06F0...0x06F9: out.append(Unicode.Scalar(UInt8(48 + v - 0x06F0)))
            case 0x0660...0x0669: out.append(Unicode.Scalar(UInt8(48 + v - 0x0660)))
            default: out.append(u)
            }
        }
        return String(out)
    }

    /// Case/diacritic-insensitive form for in-memory matching.
    static func fold(_ s: String) -> String {
        indexForm(s).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                             locale: Locale(identifier: "en_US_POSIX"))
    }

    static func tokens(_ s: String) -> [String] {
        var result: [String] = []
        var cur = String.UnicodeScalarView()
        for u in indexForm(s).unicodeScalars {
            if u.properties.isAlphabetic || u.properties.numericType != nil || u.properties.generalCategory == .nonspacingMark {
                cur.append(u)
            } else if !cur.isEmpty {
                result.append(String(cur)); cur = String.UnicodeScalarView()
            }
        }
        if !cur.isEmpty { result.append(String(cur)) }
        return result
    }

    /// FTS5 MATCH expression: all tokens must occur; the last token is a prefix match.
    static func ftsQuery(_ s: String) -> String? {
        let toks = tokens(s).map { $0.replacingOccurrences(of: "\"", with: "") }.filter { !$0.isEmpty }
        guard !toks.isEmpty else { return nil }
        var parts = toks.map { "\"\($0)\"" }
        parts[parts.count - 1] += " *"
        return parts.joined(separator: " ")
    }

    /// Spelling variants to feed PDFKit's exact-match find (it is not diacritic/ligature aware).
    static func pdfFindVariants(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var set: [String] = [q]
        func add(_ s: String) { if !set.contains(s) { set.append(s) } }
        add(q.replacingOccurrences(of: "ß", with: "ss"))
        add(q.replacingOccurrences(of: "ss", with: "ß"))
        add(q.replacingOccurrences(of: "ae", with: "ä").replacingOccurrences(of: "oe", with: "ö").replacingOccurrences(of: "ue", with: "ü"))
        // Persian/Arabic letter variants
        add(q.replacingOccurrences(of: "ی", with: "ي").replacingOccurrences(of: "ک", with: "ك"))
        add(q.replacingOccurrences(of: "ي", with: "ی").replacingOccurrences(of: "ك", with: "ک"))
        // ZWNJ handling
        add(q.replacingOccurrences(of: "\u{200C}", with: ""))
        add(q.replacingOccurrences(of: "\u{200C}", with: " "))
        add(q.replacingOccurrences(of: " ", with: "\u{200C}"))
        // digits
        let toWestern = q.map { c -> Character in
            if let i = persianDigits.firstIndex(of: c) { return Character(String(i)) }
            if let i = arabicDigits.firstIndex(of: c) { return Character(String(i)) }
            return c
        }
        add(String(toWestern))
        let toPersian = q.map { c -> Character in
            if let d = c.wholeNumberValue, c.isASCII { return persianDigits[d] }
            return c
        }
        add(String(toPersian))
        return Array(set.prefix(8))
    }

    /// Returns the sentence/paragraph range containing `location` in `text`.
    static func enclosingRange(in text: String, around location: Int, paragraph: Bool) -> NSRange {
        let ns = text as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let loc = max(0, min(location, ns.length - 1))
        var found = NSRange(location: loc, length: 0)
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: paragraph ? .byParagraphs : .bySentences) { _, range, _, stop in
            if NSLocationInRange(loc, range) { found = range; stop.pointee = true }
        }
        return found
    }
}
