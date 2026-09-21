import AppKit
import SwiftUI

// Colour that must read at 4.5:1 in both appearances. Apple's system hues are
// tuned for dark surfaces (amber on a light panel is 1.6:1, green 2.0:1), so
// each has its own light value, measured against white through #E6E6EA — the
// greyest the glass gets. Secondary text is darker than .secondary, which is
// 50% black: 3.9:1 on white.
enum Ink {
    static let secondary = adaptive(NSColor.black.withAlphaComponent(0.62), NSColor.white.withAlphaComponent(0.62))
    static let amber = adaptive(rgb(0x9A5500), rgb(0xFFB340))
    static let green = adaptive(rgb(0x1A7431), rgb(0x30D158))
    static let red = adaptive(rgb(0xB8261C), rgb(0xFF6961))
    static let link = adaptive(rgb(0x0A4FC2), rgb(0x6AAEFF))
    /// A filled chip: white on it is 7.2:1 light, 6.0:1 dark (on systemBlue, 4.1:1).
    static let chip = adaptive(rgb(0x0A4FC2), rgb(0x0A5BD6))
    /// Cards and rows sit on this, not on the bare glass, so their text has a
    /// ground that doesn't depend on the wallpaper.
    static let surface = adaptive(NSColor.white.withAlphaComponent(0.85), NSColor.white.withAlphaComponent(0.06))

    private static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
