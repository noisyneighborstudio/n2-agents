import AppKit
import SwiftUI

// The panel animates a resize under a mask. Closing it mid-resize strands the
// animation's cleanup; the mask must still be gone once it reopens, or the
// masked part is invisible and clicks there fall through to the app beneath.
@main struct GlassWindowTests {
    final class Height: ObservableObject { @Published var value: CGFloat = 100 }
    struct Box: View {
        @ObservedObject var height: Height
        var body: some View { Color.gray.frame(width: 200, height: height.value) }
    }

    /// Runs the loop until the window reaches the state; the deadline only
    /// fails a stuck test.
    static func settle(_ what: String, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !done() {
            precondition(Date() < deadline, "timed out waiting for \(what)")
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    static func main() {
        GlassWindow.reduceMotion = { false }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "T"
        let height = Height()
        let panel = GlassWindow(rootView: Box(height: height), behavior: .transient(anchor: item.button!))
        let mask = { panel.contentView?.subviews.first?.layer?.mask }

        panel.present()
        settle("the panel to open") { panel.hasShadow && panel.frame.height == 100 }
        height.value = 300
        settle("the resize to start") { mask() != nil }
        panel.dismiss()
        settle("the panel to close") { !panel.isVisible }
        panel.present()
        settle("the panel to reopen") { panel.hasShadow && panel.frame.height == 300 }
        precondition(mask() == nil, "a resize cut short by closing left its mask on the reopened panel")
        NSStatusBar.system.removeStatusItem(item)
    }
}
