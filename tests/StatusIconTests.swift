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
        let warned = plain.image(remaining: nil, dark: true, attention: true)
        precondition(hasWarning(warned))
        // Drawn at the symbol's proportions, not stretched to a square: an
        // equilateral triangle stands 0.87 of its width.
        let box = yellow(warned)
        let ratio = Double(box.height) / Double(box.width)
        precondition((0.78...0.95).contains(ratio), "warning triangle is \(box.width)x\(box.height) px, ratio \(ratio)")
    }

    static func isYellow(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
        return c.alphaComponent > 0.5 && c.redComponent > 0.7 && c.greenComponent > 0.5 && c.blueComponent < 0.3
    }

    static func rep2x(_ icon: NSImage) -> NSBitmapImageRep {
        icon.representations.compactMap { $0 as? NSBitmapImageRep }.first { $0.pixelsWide == 44 }!
    }

    static func hasWarning(_ icon: NSImage) -> Bool {
        let rep = rep2x(icon)
        return (22..<44).contains { x in (22..<44).contains { y in isYellow(rep, x, y) } }
    }

    /// The bounding box of the warning's yellow, in 2x pixels.
    static func yellow(_ icon: NSImage) -> (width: Int, height: Int) {
        let rep = rep2x(icon)
        let points = (0..<44).flatMap { x in (0..<44).filter { y in isYellow(rep, x, y) }.map { (x, $0) } }
        let xs = points.map(\.0), ys = points.map(\.1)
        return (xs.max()! - xs.min()! + 1, ys.max()! - ys.min()! + 1)
    }
}
