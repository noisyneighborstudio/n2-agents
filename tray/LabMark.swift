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
            Text(verbatim: vendor.monogram).font(.system(size: 8.5, weight: .semibold)).tracking(0.2).lineLimit(1)
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
