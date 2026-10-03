import AppKit
import SwiftUI

// The glass follows its content's height with the top edge held still. Two
// ways that went wrong in the recorded walkthrough, each checked here on the
// real GlassWindow:
// 1. Content that grows lays out for a moment in the old, shorter window. It
//    must stay pinned to the top there, not be centred (the page dropped,
//    opening a band of bare glass above it, then snapped back).
// 2. A second resize while the first is still revealing must start its reveal
//    from the top edge of the new window, not from the old window's path.

final class Box: ObservableObject {
    @Published var height: CGFloat = 100
    var tops: [CGFloat] = []
}

struct Probe: View {
    @ObservedObject var box: Box
    var body: some View {
        VStack(spacing: 0) {
            Color.red.frame(height: 20)
            Color.blue.frame(height: box.height)
        }
        .frame(width: 300)
        // Fires on every size change, carrying where the content's top was laid out.
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { box.tops.append($0.minY) }
    }
}

var failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print((ok ? "ok " : "FAIL ") + name + (ok ? "" : " — " + detail()))
    if !ok { failed += 1 }
}

func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

/// Spins until `done` holds, failing after `limit` seconds.
func until(_ limit: Double, _ done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(limit)
    while !done() && Date() < end { spin(0.01) }
    return done()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let box = Box()
let window = GlassWindow(rootView: Probe(box: box), behavior: .floating)
window.present()
check("the window settles at the content's height", until(3) { abs(window.frame.height - 120) < 1 },
      "height \(window.frame.height)")

// 1. Grow, and record where the top strip is laid out on every pass until the window has caught up.
box.tops.removeAll()
withAnimation(.linear(duration: 0.3)) { box.height = 700 }
check("the window grows to the content", until(3) { abs(window.frame.height - 720) < 1 },
      "height \(window.frame.height)")
_ = until(3) { window.contentView?.subviews.first?.layer?.mask == nil }
check("growing content is laid out pinned to the top on every pass",
      !box.tops.isEmpty && box.tops.allSatisfy { abs($0) < 0.5 }, "tops \(box.tops)")

// 2. Grow, then grow again while the first reveal is still running (Send
//    Work: "Asking the fleet…", then the plan) — each into a taller window.
//    Under Reduce Motion the window snaps instead, and there is no reveal.
if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
    print("skip reveal checks: Reduce Motion is on")
} else {
    box.height = 100
    check("the window shrinks back", until(3) { abs(window.frame.height - 120) < 1 && window.contentView?.subviews.first?.layer?.mask == nil })
    let surface = window.contentView?.subviews.first?.layer
    box.height = 250
    check("a reveal is running mid-resize",
          until(1) { abs(window.frame.height - 270) < 1 && (surface?.mask as? CAShapeLayer)?.animation(forKey: "reveal") != nil })
    box.height = 400
    check("the second resize starts its own reveal, in the taller window",
          until(1) { abs(window.frame.height - 420) < 1 && (surface?.mask as? CAShapeLayer)?.animation(forKey: "reveal") != nil })
    if let layer = surface, let mask = layer.mask as? CAShapeLayer,
       let reveal = mask.animation(forKey: "reveal") as? CABasicAnimation, let from = reveal.fromValue {
        let box = (from as! CGPath).boundingBox
        let top = layer.contentsAreFlipped() ? box.minY : layer.bounds.height - box.maxY
        check("a retargeted reveal starts at the window's top edge", abs(top) < 0.5,
              "starts \(top) pt below the top (window \(layer.bounds.height), path \(box))")
    }
    check("the window settles at the final height", until(3) { abs(window.frame.height - 420) < 1 && surface?.mask == nil },
          "height \(window.frame.height)")
}

print(failed == 0 ? "ALL PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
