import AppKit
import SwiftUI

/// A lab's logo, drawn as a template so it takes the ink around it (amber
/// when signed out, red when maxed). Logos are bundled per lab id in
/// Resources/logos; a lab added without one shows its two-letter monogram.
struct LabMark: View {
    let vendor: Vendor
    var size: CGFloat = 11

    var body: some View {
        if let logo = Self.logo(vendor.id) {
            Image(nsImage: logo).renderingMode(.template).resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit).frame(width: size, height: size)
        } else {
            Text(verbatim: vendor.monogram).font(.system(size: max(8.5, size * 0.62), weight: .semibold))
                .tracking(0.2).lineLimit(1)
        }
    }

    private static var logos: [String: NSImage?] = [:]

    private static func logo(_ id: String) -> NSImage? {
        if let cached = logos[id] { return cached }
        let image = Bundle.main.url(forResource: id, withExtension: "pdf", subdirectory: "logos")
            .flatMap(NSImage.init(contentsOf:))
        image?.isTemplate = true
        logos[id] = image
        return image
    }
}

/// A lab's logo on its tile. Everything is drawn from the size the tile is
/// given — the corner is always 25% of the side and the logo 57% — so a tile
/// keeps its shape at every size, including mid-flight between two sizes.
/// A tile with no status is neutral (the suggestion card, the toast);
/// StatusInk gives slots their status fill and ink.
struct LogoTile: View {
    let vendor: Vendor
    var fill: Color = Ink.tile
    var ink: Color = Ink.logo

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            LabMark(vendor: vendor, size: side * 0.57)
                .foregroundStyle(ink)
                .frame(width: g.size.width, height: g.size.height)
                .background(RoundedRectangle(cornerRadius: side * 0.25).fill(fill))
        }
        .accessibilityHidden(true)
    }
}
