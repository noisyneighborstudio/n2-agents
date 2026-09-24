import AppKit

// The menu bar icon doubles as a gauge for quota left across every profile:
// the art drains from the top down as it's spent, and a glowing border takes
// the tier's colour. With nothing read yet it's the plain icon.
struct StatusIcon {
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

    let base: NSImage
    /// The art's foreground — hub, spokes, nodes — without its dark ground:
    /// what's left standing above the level once the ground has drained.
    private let glyph: NSImage

    init(base: NSImage) {
        self.base = base
        glyph = Self.glyph(of: base)
    }

    /// Rendered once into flat 1x and 2x bitmaps: a lazily drawn image
    /// re-runs its handler on every menu bar repaint, and this one is costly.
    func image(remaining: Int?, dark: Bool) -> NSImage {
        let image = NSImage(size: Self.size)
        for scale in [1, 2] {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(Self.size.width) * scale,
                                       pixelsHigh: Int(Self.size.height) * scale, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            // Sized in points, so the context scales drawing and glow alike.
            rep.size = Self.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw(remaining: remaining, dark: dark, in: NSRect(origin: .zero, size: Self.size))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        return image
    }

    /// The dark ground is the gauge's liquid: full colour below the level,
    /// and above it only the foreground's outline, in the menu bar's ink.
    private func draw(remaining: Int?, dark: Bool, in rect: NSRect) {
        let art = rect.insetBy(dx: 1, dy: 1)
        guard let remaining else {
            base.draw(in: art)
            return
        }
        let square = art.insetBy(dx: art.width * Self.artInset, dy: art.height * Self.artInset)
        let level = square.minY + square.height * CGFloat(min(max(remaining, 0), 100)) / 100
        let (full, drained) = rect.divided(atDistance: level - rect.minY, from: .minYEdge)

        NSGraphicsContext.saveGraphicsState()
        full.clip()
        base.draw(in: art)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        drained.clip()
        glyph.draw(in: art)
        (dark ? NSColor.white : NSColor.black).setFill()
        drained.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()

        let color = Tier(remaining: remaining).color
        let glow = NSShadow()
        glow.shadowColor = color
        glow.shadowBlurRadius = 3
        glow.shadowOffset = .zero
        NSGraphicsContext.saveGraphicsState()
        glow.set()
        color.setStroke()
        let radius = square.width * Self.artRadius
        let border = NSBezierPath(roundedRect: square.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Lifts the foreground off the ground by brightness: the ground peaks
    /// near 15% and the dimmest node near 75%. The ramp starts past the hub's
    /// halo, which in solid ink would smudge.
    private static func glyph(of base: NSImage) -> NSImage {
        let px = 128
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        base.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let data = rep.bitmapData!
        for y in 0..<px {
            for x in 0..<px {
                let p = data + y * rep.bytesPerRow + x * 4
                let bright = Double(max(p[0], p[1], p[2])) / 255
                let a = UInt8(255 * min(max((bright - 0.45) / 0.25, 0), 1))
                (p[0], p[1], p[2], p[3]) = (a, a, a, a)   // premultiplied white
            }
        }
        let image = NSImage(size: NSSize(width: px, height: px))
        image.addRepresentation(rep)
        return image
    }
}
