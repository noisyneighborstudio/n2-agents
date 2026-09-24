import AppKit

// One colour per profile, for the panel's profile bars. djb2 over the name:
// stable across launches and machines. Pink belongs to Default alone; any
// other name that hashes onto it re-hashes over the other six, so the panel
// never shows Default's colour on a second card.
enum ProfileColor {
    static let palette: [NSColor] = [
        NSColor(calibratedRed: 0.20, green: 0.47, blue: 0.96, alpha: 1), // blue
        NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.96, alpha: 1), // purple
        NSColor(calibratedRed: 0.10, green: 0.63, blue: 0.52, alpha: 1), // teal
        NSColor(calibratedRed: 0.91, green: 0.30, blue: 0.47, alpha: 1), // pink — Default's
        NSColor(calibratedRed: 0.93, green: 0.58, blue: 0.05, alpha: 1), // amber
        NSColor(calibratedRed: 0.33, green: 0.69, blue: 0.23, alpha: 1), // green
        NSColor(calibratedRed: 0.82, green: 0.22, blue: 0.20, alpha: 1), // red
    ]
    private static let defaultIndex = 3

    static func of(_ name: String) -> NSColor {
        if name == "Default" { return palette[defaultIndex] }
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        let index = Int(hash % UInt64(palette.count))
        guard index == defaultIndex else { return palette[index] }
        let others = palette.indices.filter { $0 != defaultIndex }
        return palette[others[Int((hash / UInt64(palette.count)) % UInt64(others.count))]]
    }
}
