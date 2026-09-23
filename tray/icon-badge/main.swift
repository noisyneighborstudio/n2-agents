import AppKit

// icon-badge <in.icns> <out.png> <label>
// Renders the base icon at 1024px with a colored ribbon carrying the label.
// Color comes from ProfileColor, so the ribbon matches the tray panel.

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: icon-badge <in.icns> <out.png> <label>\n".data(using: .utf8)!)
    exit(2)
}
let inputPath = args[1], outputPath = args[2], label = args[3]

guard let base = NSImage(contentsOfFile: inputPath) else {
    FileHandle.standardError.write("icon-badge: cannot read \(inputPath)\n".data(using: .utf8)!)
    exit(3)
}

let size: CGFloat = 1024
let canvas = NSImage(size: NSSize(width: size, height: size))
canvas.lockFocus()

base.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
          from: .zero, operation: .sourceOver, fraction: 1.0)

let color = ProfileColor.of(label).withAlphaComponent(0.94)

let ribbonHeight = size * 0.26
let ribbon = NSRect(x: size * 0.055, y: size * 0.04, width: size * 0.89, height: ribbonHeight)
let radius = ribbonHeight * 0.32
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowBlurRadius = size * 0.012
shadow.shadowOffset = NSSize(width: 0, height: -size * 0.006)
shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
shadow.set()
color.setFill()
NSBezierPath(roundedRect: ribbon, xRadius: radius, yRadius: radius).fill()
NSGraphicsContext.current?.restoreGraphicsState()

let text = label.uppercased() as NSString
var fontSize = size * 0.155
var attrs: [NSAttributedString.Key: Any] = [:]
var textSize = NSSize.zero
while true {
    attrs = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
        .foregroundColor: NSColor.white,
    ]
    textSize = text.size(withAttributes: attrs)
    if textSize.width <= ribbon.width * 0.86 || fontSize <= size * 0.05 { break }
    fontSize *= 0.92
}
text.draw(at: NSPoint(x: ribbon.midX - textSize.width / 2, y: ribbon.midY - textSize.height / 2),
          withAttributes: attrs)

canvas.unlockFocus()
guard let tiff = canvas.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    exit(4)
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
} catch {
    FileHandle.standardError.write("icon-badge: write failed: \(error)\n".data(using: .utf8)!)
    exit(5)
}
