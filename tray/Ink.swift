import AppKit
import SwiftUI

// Colour that must read at 4.5:1 in both appearances. Apple's system hues are
// tuned for dark surfaces (amber on a light panel is 1.6:1, green 2.0:1), so
// each has its own light value, measured against #E6E6EA — the greyest the
// glass gets — and its dark value against the dark page fill #252932 and a
// card on it (white 6%, #2F333B). Secondary text is darker than .secondary,
// which is 50% black: 3.9:1 on white.
enum Ink {
    /// 5.8:1 light; 6.5:1 dark (5.8:1 on a card).
    static let secondary = Tone(NSColor.black.withAlphaComponent(0.62), NSColor.white.withAlphaComponent(0.62)).color
    /// Timestamps, "when", keys. The design's 48% / 40% measured 3.5:1 / 3.3:1,
    /// so both are darkened to pass: 4.5:1 light; 4.6:1 dark on a card.
    static let tertiary = Tone(NSColor.black.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0.52)).color
    /// 4.6:1 light; 8.2:1 dark (6.8:1 on a card).
    static let amber = Tone.amber.color
    /// 4.7:1 light; 7.2:1 dark (6.0:1 on a card).
    static let green = Tone.green.color
    /// 5.0:1 light; 10.3:1 dark (8.6:1 on a card).
    static let yellow = Tone.yellow.color
    /// 5.1:1 light; 5.5:1 dark, 4.6:1 on a card (#FF6961 was 4.3:1 there).
    static let red = Tone.red.color
    /// 4.9:1 light; 8.5:1 dark (7.0:1 on a card).
    static let info = Tone.info.color
    /// 5.8:1 light; 6.3:1 dark (5.3:1 on a card).
    static let link = Tone(rgb(0x0A4FC2), rgb(0x6AAEFF)).color
    /// A filled chip: white on it is 7.2:1 light, 6.0:1 dark (on systemBlue, 4.1:1).
    static let chip = Tone.chip.color
    /// Cards and rows sit on this, not on the bare glass, so their text has a
    /// ground that doesn't depend on the wallpaper.
    static let surface = Tone(NSColor.white.withAlphaComponent(0.85), NSColor.white.withAlphaComponent(0.06)).color
    /// Ring and bar tracks. Not text.
    static let track = Tone(NSColor.black.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0.10)).color
    /// Rows and cards under the pointer. Not text.
    static let hover = Tone(NSColor.black.withAlphaComponent(0.05), NSColor.white.withAlphaComponent(0.07)).color

    /// One ink's two values, kept together so it can also be laid down as a
    /// tinted fill that follows the appearance.
    struct Tone {
        let light: NSColor
        let dark: NSColor

        init(_ light: NSColor, _ dark: NSColor) { (self.light, self.dark) = (light, dark) }

        static let amber = Tone(rgb(0x9A5500), rgb(0xFFB340))
        static let green = Tone(rgb(0x1A7431), rgb(0x30D158))
        static let yellow = Tone(rgb(0x7A5C00), rgb(0xFFD60A))
        static let red = Tone(rgb(0xB8261C), rgb(0xFF7369))
        static let info = Tone(rgb(0x006A8E), rgb(0x64D2FF))
        static let chip = Tone(rgb(0x0A4FC2), rgb(0x0A5BD6))

        var color: Color {
            let (light, dark) = (light, dark)
            return Color(nsColor: NSColor(name: nil) { Ink.isDark($0) ? dark : light })
        }

        /// The ink as a fill: `alpha` in dark, 0.8× in light, where the same
        /// wash reads heavier on the pale glass; doubled under Increase Contrast.
        func wash(_ alpha: CGFloat) -> Color {
            let (light, dark) = (light, dark)
            return Color(nsColor: NSColor(name: nil) { appearance in
                let boost: CGFloat = Ink.highContrast(appearance) ? 2 : 1
                return Ink.isDark(appearance) ? dark.withAlphaComponent(min(1, alpha * boost))
                                              : light.withAlphaComponent(min(1, alpha * 0.8 * boost))
            })
        }
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
    }

    static func highContrast(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            .map { $0 == .accessibilityHighContrastAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
    }

    fileprivate static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
