import AppKit
// make-icon <art.png> <out.png> — place full-bleed art into a macOS app-icon tile.
//   swiftc -O scripts/make-icon.swift -o /tmp/make-icon \
//     && /tmp/make-icon tray/icon-art.png tray/n2agents.png
// tray/icon-art.png is the raw generated art (gen-image, openai/gpt-image-1,
// opaque 1024x1024); tray/build.sh turns tray/n2agents.png into the .icns.
// Apple's 1024 grid: the tile is 824x824, inset 100, with a soft drop shadow.
// The outline is a superellipse (continuous curvature), which is what the
// system icons use — a plain rounded rect has visibly abrupt shoulders.
let a = CommandLine.arguments
let art = NSImage(contentsOfFile: a[1])!
let S = 1024.0, tile = 824.0, inset = (S - tile) / 2

func squircle(_ r: NSRect, n: Double = 5.0, steps: Int = 720) -> NSBezierPath {
    let p = NSBezierPath()
    let cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + rx * copysign(pow(abs(c), 2 / n), c)
        let y = cy + ry * copysign(pow(abs(s), 2 / n), s)
        i == 0 ? p.move(to: NSPoint(x: x, y: y)) : p.line(to: NSPoint(x: x, y: y))
    }
    p.close()
    return p
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current!.imageInterpolation = .high
let body = NSRect(x: inset, y: inset, width: tile, height: tile)
let path = squircle(body)

// Shadow pass: Apple's template uses a ~28pt blur, 12pt downward offset.
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow()
sh.shadowBlurRadius = 28; sh.shadowOffset = NSSize(width: 0, height: -12)
sh.shadowColor = NSColor(white: 0, alpha: 0.35); sh.set()
NSColor.black.setFill(); path.fill()
NSGraphicsContext.restoreGraphicsState()

// Art, clipped to the tile.
NSGraphicsContext.saveGraphicsState()
path.addClip()
art.draw(in: body, from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

// Hairline inner stroke so the tile edge holds against a dark Dock.
NSColor(white: 1, alpha: 0.08).setStroke(); path.lineWidth = 2; path.stroke()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
