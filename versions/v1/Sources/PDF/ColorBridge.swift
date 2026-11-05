import AppKit
import SwiftUI

extension RGBA {
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? NSColor.black.usingColorSpace(.sRGB)!
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }
    init(_ color: Color) { self.init(NSColor(color)) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var cgColor: CGColor { nsColor.cgColor }
    var color: Color { Color(nsColor: nsColor) }
}

extension Color {
    init(rgba: RGBA) { self = rgba.color }
}
