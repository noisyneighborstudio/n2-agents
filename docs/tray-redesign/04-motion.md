# 04: Motion

Put every constant in `tray/Motion.swift`. **No inline animation values in views.**

```swift
import SwiftUI

enum Motion {
    /// Page push/pop, panel height, matched glyph flights, disclosure.
    static let nav = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.48)
    /// Glyph flight is slightly longer so it lands after the page settles.
    static let flight = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.54)
    /// Things drawing in: rings, pace bars, staggered content.
    static let reveal = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.76)
    static let press = Animation.easeOut(duration: 0.12)
    /// Toast arrival: overshoots slightly.
    static let toastIn = Animation.spring(response: 0.5, dampingFraction: 0.72)
    static let fade = Animation.easeInOut(duration: 0.2)   // Reduce Motion replacement

    static func stagger(_ i: Int) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: 0.42).delay(0.14 + Double(i) * 0.04)
    }
}

extension View {
    /// Pick the motion, or the crossfade under Reduce Motion.
    func motion(_ a: Animation, reduce: Bool) -> Animation { reduce ? Motion.fade : a }
}
```

Always read `@Environment(\.accessibilityReduceMotion)`. Under Reduce Motion,
**every** entry below becomes `Motion.fade` with opacity only: no offset, no
scale, and no matched-geometry flight (drop `matchedGeometryEffect` by giving
the destination a different id).

---

## M1. Press
- Rows, cards and tiles scale to 0.985 (tiles 0.96) with `Motion.press` on
  press, and return on release. The action commits **on release**, so dragging
  off cancels.
- Hover: the fill goes to 7% white (dark) or 5% black (light) over 0.15 s.
- Implement it once as `PressableStyle: ButtonStyle`, replacing `RowButtonStyle`'s press.

## M2. Page push / pop
- Incoming page: `.transition(.move(edge: .trailing))`, above the outgoing page.
- Outgoing page: `offset(x: -108)` (30% of 360) and `opacity(0)`.
- Panel window height animates to the new page's height, all in one
  `withAnimation(Motion.nav)` transaction.
- Pages have an **opaque** background (the glass surface color). The incoming page
  covers the outgoing one; they never show through each other.
- Interruptible: a pop mid-push reverses from the current position. Since both
  directions go through the same `withAnimation`, SwiftUI does this for free.
  Don't queue navigations.

## M3. Matched glyph (the signature move)
There are three variants, all built with `matchedGeometryEffect` and one namespace
owned by `PageStack`.

| From | To | Id |
|---|---|---|
| Strip tile (22) in a profile card | Row tile (28) on the Profile page | `glyph-{profile}-{vendor}` |
| Row tile (28) | Hero tile (48) on the Provider page | `glyph-{profile}-{vendor}` |
| Suggestion card tile (28) | Hero tile (48) | `glyph-{profile}-{vendor}` of the **candidate** |

Rules:
- The tile's corner radius is always 25% of its side, so the shape never changes in flight.
- The logo inside scales with the tile; don't animate it separately.
- `isSource`: the visible page's tile is the source. Set
  `properties: .frame`, `anchor: .topLeading`.
- **Strip → rows fan out:** each provider's flight is delayed `i × 0.028 s`,
  with the `Motion.flight` curve. Back reverses it with the same delays.
- The hero **ring does not fly**. It draws in (M4) after the glyph lands.
- The existing `SlotID.mono` / `SlotID.gauge` namespaces in `PanelView.swift`
  do the strip→row half of this today. Reuse the mechanism, rename the ids to
  the table above, and delete the gauge flight: the row ring draws in instead.

## M4. Ring draw
- When a hero or toast ring appears, animate `trim(from: 0, to: remaining)` from
  0 with `Motion.reveal`, **delayed until the glyph lands** (0.30 s after the push starts).
- Toast rings sweep from the **previously announced** remaining to the new
  one (for example 50 → 25), not from 0.
- The number text doesn't count up. It is static. Only the ring moves.

## M5. Content stagger (Provider page)
- Items in order: headline, sub, capsule, chips, suggestion card, primary
  button, tiles, grouped list. Each starts at `opacity 0, offset y +10` and
  animates with `Motion.stagger(i)`.
- It runs on push **and** when the subject changes via Switch.

## M6. Diagnostics disclosure
- Animate the height from 0 to the content height with `Motion.nav`, with contents
  fading in over 0.3 s. The chevron rotates to 90° with the same curve.
- The panel's window height grows in the same transaction.

## M7. Terminal menu
- Use a native `NSMenu` pop-up (the existing `popUp(_:)` helper). Don't build
  a custom SwiftUI popover. The system handles its animation.

## M8. Copy feedback
- The icon crossfades from `doc.on.doc` to a green `checkmark` (0.15 s), holds 1.4 s,
  then crossfades back. Use `.contentTransition(.symbolEffect(.replace))`.

## M9. Check again
- `arrow.clockwise` uses `.symbolEffect(.rotate, isActive: checking)` (macOS 15+;
  fall back to a linear 0.8 s rotation). When the check resolves, the row
  status crossfades to its new state.

## M10. Toast motion
See `05-toasts.md` § Motion.

## Timing summary

| Id | Duration | Curve |
|---|---|---|
| press | 0.12 | easeOut |
| push/pop, panel height, disclosure | 0.48 | (0.32, 0.72, 0, 1) |
| glyph flight | 0.54 (+0.028 × i) | (0.32, 0.72, 0, 1) |
| ring draw | 0.76 (delay 0.30) | (0.22, 1, 0.36, 1) |
| stagger | 0.42 (delay 0.14 + 0.04 × i) | (0.22, 1, 0.36, 1) |
| toast in | spring 0.5 / 0.72 | spring |
| toast out | 0.42 | (0.32, 0.72, 0, 1) |
| Reduce Motion | 0.20 | easeInOut, opacity only |
