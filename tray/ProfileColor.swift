import AppKit

// One colour per profile, shared by the cloned app's icon ribbon (icon-badge)
// and the panel's profile bars, so a profile reads the same everywhere. djb2
// over the name: stable across launches and machines. Seven colours means
// collisions (Default and ExpoIO both land on pink) — the name, never the
// colour, is what identifies a profile.
enum ProfileColor {
    static let palette: [NSColor] = [
        NSColor(calibratedRed: 0.20, green: 0.47, blue: 0.96, alpha: 1), // blue
        NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.96, alpha: 1), // purple
        NSColor(calibratedRed: 0.10, green: 0.63, blue: 0.52, alpha: 1), // teal
        NSColor(calibratedRed: 0.91, green: 0.30, blue: 0.47, alpha: 1), // pink
        NSColor(calibratedRed: 0.93, green: 0.58, blue: 0.05, alpha: 1), // amber
        NSColor(calibratedRed: 0.33, green: 0.69, blue: 0.23, alpha: 1), // green
        NSColor(calibratedRed: 0.82, green: 0.22, blue: 0.20, alpha: 1), // red
    ]

    static func of(_ name: String) -> NSColor {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
