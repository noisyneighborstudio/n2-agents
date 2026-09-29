import SwiftUI

// Every animation constant the panel uses. Views name one of these; none
// carries its own curve or duration.
enum Motion {
    /// Page push/pop, panel height, glyph flights' page, disclosure.
    static let nav = Animation.timingCurve(0.32, 0.72, 0, 1, duration: navDuration)
    static let navDuration = 0.48
    /// A glyph's flight lands just after the page settles.
    static let flightDuration = 0.54
    static func flight(_ i: Int) -> Animation {
        .timingCurve(0.32, 0.72, 0, 1, duration: flightDuration).delay(Double(i) * 0.028)
    }
    static let press = Animation.easeOut(duration: 0.12)
    static let hover = Animation.easeOut(duration: 0.15)
    /// Reduce Motion's stand-in for every move: opacity only.
    static let fade = Animation.easeInOut(duration: 0.2)

    static func nav(reduce: Bool) -> Animation { reduce ? fade : nav }
}

extension View {
    /// An arrow that turns while work runs (Check again, Refresh): the symbol's
    /// own rotate effect from macOS 15, a steady 0.8 s turn before it.
    @ViewBuilder func turning(_ active: Bool) -> some View {
        if #available(macOS 15.0, *) {
            symbolEffect(.rotate, isActive: active)
        } else {
            modifier(Turning(active: active))
        }
    }
}

private struct Turning: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !active || reduceMotion)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8
            content.rotationEffect(.degrees(active && !reduceMotion ? turn * 360 : 0))
        }
    }
}
