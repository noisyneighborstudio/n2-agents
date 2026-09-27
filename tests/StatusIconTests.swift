import AppKit

@main struct StatusIconTests {
    static func main() {
        for (left, tier) in [(100, StatusIcon.Tier.green), (81, .green), (80, .amber), (50, .amber),
                             (49, .orange), (20, .orange), (19, .red), (0, .red)] {
            precondition(StatusIcon.Tier(remaining: left) == tier, "\(left)% left should be \(tier)")
        }
        // The toast announces a reading once it's a tier worse than before.
        precondition(StatusIcon.Tier.green < .amber && StatusIcon.Tier.amber < .orange && StatusIcon.Tier.orange < .red)
        // Flat bitmaps, not a drawing handler the menu bar re-runs every repaint.
        let icon = StatusIcon(base: NSImage(size: NSSize(width: 64, height: 64))).image(remaining: 40, dark: true)
        let widths = icon.representations.compactMap { ($0 as? NSBitmapImageRep)?.pixelsWide }
        precondition(widths == [22, 44] && icon.representations.count == 2, "icon should be 1x + 2x bitmaps, got \(icon.representations)")
        // A profile needing sign-in puts a yellow warning in the bottom-right corner, and only then.
        let plain = StatusIcon(base: NSImage(size: NSSize(width: 64, height: 64)))
        precondition(!hasWarning(plain.image(remaining: nil, dark: true)))
        precondition(hasWarning(plain.image(remaining: nil, dark: true, attention: true)))
    }

    static func hasWarning(_ icon: NSImage) -> Bool {
        let rep = icon.representations.compactMap { $0 as? NSBitmapImageRep }.first { $0.pixelsWide == 44 }!
        return (22..<44).contains { x in (22..<44).contains { y in
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return c.alphaComponent > 0.5 && c.redComponent > 0.7 && c.greenComponent > 0.5 && c.blueComponent < 0.3
        } }
    }
}
