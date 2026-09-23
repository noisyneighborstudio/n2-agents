import AppKit

// The menu bar icon doubles as a gauge for quota left across every profile:
// the art drains from the top down as it's spent, and a glowing border takes
// the tier's colour. With nothing read yet it's the plain icon.
enum StatusIcon {
    /// Ordered best to worst, so a lower reading compares greater.
    enum Tier: Comparable {
        case green, amber, orange, red

        init(remaining: Int) {
            self = remaining < 20 ? .red : remaining < 50 ? .orange : remaining <= 80 ? .amber : .green
        }

        // Fixed, not Ink's adaptive values: a glow is a signal, not text, and
        // the menu bar's own tint shifts with the wallpaper anyway.
        var color: NSColor {
            switch self {
            case .green: return .systemGreen
            case .amber: return NSColor(srgbRed: 1, green: 0.78, blue: 0.2, alpha: 1)
            case .orange: return .systemOrange
            case .red: return .systemRed
            }
        }
    }

    /// 2 pt wider than the art, so the glow has room to bloom.
    static let size = NSSize(width: 22, height: 22)
    /// The art's rounded square within its canvas (100 px in on 1024) and
    /// its corner radius, as fractions of the canvas and the square.
    private static let artInset: CGFloat = 100 / 1024
    private static let artRadius: CGFloat = 0.22
    /// What's left of the drained part: enough to still read as the icon.
    private static let drainedAlpha: CGFloat = 0.3

    static func image(base: NSImage, remaining: Int?) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            let art = rect.insetBy(dx: 1, dy: 1)
            guard let remaining else {
                base.draw(in: art)
                return true
            }
            let square = art.insetBy(dx: art.width * artInset, dy: art.height * artInset)
            let level = CGFloat(min(max(remaining, 0), 100)) / 100

            base.draw(in: art, from: .zero, operation: .sourceOver, fraction: drainedAlpha)
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width,
                   height: square.minY - rect.minY + square.height * level).clip()
            base.draw(in: art)
            NSGraphicsContext.restoreGraphicsState()

            let color = Tier(remaining: remaining).color
            let glow = NSShadow()
            glow.shadowColor = color
            glow.shadowBlurRadius = 3
            glow.shadowOffset = .zero
            NSGraphicsContext.saveGraphicsState()
            glow.set()
            color.setStroke()
            let radius = square.width * artRadius
            let border = NSBezierPath(roundedRect: square.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            border.lineWidth = 1
            border.stroke()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }
}
