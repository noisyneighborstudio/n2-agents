import AppKit
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
    /// Things drawing in: the hero ring, once its glyph has landed.
    static let reveal = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.76).delay(0.30)
    /// A page's content arriving, item by item.
    static func stagger(_ i: Int) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: 0.42).delay(0.14 + Double(i) * 0.04)
    }
    static let press = Animation.easeOut(duration: 0.12)
    /// A toast arriving overshoots a little; leaving, it takes the nav curve.
    static func toastIn(reduce: Bool) -> Animation { reduce ? fade : .spring(response: 0.5, dampingFraction: 0.72) }
    static func toastOut(reduce: Bool) -> Animation { reduce ? fade : .timingCurve(0.32, 0.72, 0, 1, duration: 0.42) }
    static let hover = Animation.easeOut(duration: 0.15)
    /// Reduce Motion's stand-in for every move: opacity only.
    static let fade = Animation.easeInOut(duration: 0.2)

    static func nav(reduce: Bool) -> Animation { reduce ? fade : nav }

    /// Reduce Motion, for code that runs outside a view's environment.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
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

extension View {
    /// A symbol swapped for another (copy → checkmark) crossfades in place.
    @ViewBuilder func replacingSymbol() -> some View {
        if #available(macOS 14.0, *) { contentTransition(.symbolEffect(.replace)) } else { self }
    }

    /// Rises 10 pt and fades in as its page arrives, `index` places after the first.
    func staggered(_ index: Int) -> some View { modifier(Staggered(index: index)) }
}

private struct Staggered: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .onAppear { withAnimation(reduceMotion ? Motion.fade : Motion.stagger(index)) { shown = true } }
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
