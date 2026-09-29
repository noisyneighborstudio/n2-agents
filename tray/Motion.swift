import SwiftUI

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
