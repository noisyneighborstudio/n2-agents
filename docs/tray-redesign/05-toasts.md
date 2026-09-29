# 05: Usage warning toasts

The toast replaces `QuotaToastView`. `QuotaToast` (the class) keeps owning the
window, the announce-once bookkeeping and VoiceOver announcements. Its tier
logic changes as described below.

## Tier ladder (remaining % of the binding window, per profile × provider)

```swift
enum UsageTier: Int, Comparable {
    case half = 1     // left <= 50
    case quarter      // left <= 25
    case low          // left <= 10
    case out          // left == 0, or note .restricted
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}
```

- The id is `"{profile}|{vendor}"`. Announce **once per tier entered**, the same
  as the existing `announced` dictionary. A reading that recovers above a tier
  clears it, so dipping again re-announces.
- Jumping several tiers at once (for example 60 → 8) announces **only the worst**
  tier, not each step.
- Only `.ok` / `.restricted` readings with a fresh value produce
  tiers. Stale, failed and unmetered readings never toast.
- `quiet: true` (panel open) records the tier without showing a toast, as today.

| Tier | Accent ink | Title | Sub-line | Extra | Dismissal |
|---|---|---|---|---|---|
| half | `Ink.info` | "{Provider} · half left" | Pace sentence (below) | none | Auto after **5.2 s**, with a 2 pt drain bar at the bottom |
| quarter | `Ink.yellow` | "{Provider} · 25% left" | Pace sentence | Pace bar | Auto after **8 s** |
| low | `Ink.amber` | "{Provider} · 10% left" | "About {duration} of work left at this pace." | Pace bar + suggestion row | Stays until dismissed or clicked |
| out | `Ink.amber` | "{Provider} is out" | "Back {day} at {time} · in {countdown}" | Suggestion row + buttons "Start anyway" / "Notify when back" | Stays; breathing glow on its border |

When more than one profile holds this provider, the title gets the profile:
"{Provider} in {Profile} · 25% left". Tier numbers in titles are the tier
thresholds, but the ring shows the **actual** remaining value.

### Pace sentence and pace bar (quarter / low)
- It needs the window start and reset (`Usage.Window.durationSeconds` + `resets`).
  **If either is missing, omit the pace sentence and the pace bar.** Don't estimate.
- `elapsed = 1 - (reset - now) / duration`
- `burnRate = used / elapsed` (per window)
- `exhaustAt = now + (left / used) × (now - windowStart)`
- Sentence:
  - If `exhaustAt >= reset`: "At this pace it lasts until the reset, {clockTime(reset)}."
  - Else: "You're ahead of pace. At this rate it runs out {clockTime(exhaustAt)}."
  - For low: "About {duration} of work left at this pace." (`Duration.formatted(.units(allowed: [.hours, .minutes], width: .wide))`)
- Pace bar: 6 pt tall, radius 3, track `Ink.track`, fill = used % in the accent
  ink. A white 2 × 12 tick at `elapsed` sits under it. Its labels (11 secondary)
  read "{used}% used" on the left and "{elapsed}% of the week gone" on the right.

## Layout (one card)
- 360 wide, radius 18, `GlassWindow(.toast(anchor:))` with the existing glass
  material. Padding is 14 on the sides, 14 on top and 12 on the bottom.
- Row: a 44 ring with a 22 logo tile inside, then a column holding the title (14
  semibold) with a trailing "now" (11.5 tertiary), and the sub-line below it (12.5
  secondary, max 2 lines).
- Pace bar block and suggestion row are indented 56 to align with the text.
- Suggestion row: 40 tall, radius 11, blue at 14% with a 0.5 pt stroke. It holds
  the logo tile, "**Cursor** · 100% left" and a **Switch** capsule.
- Out buttons: a 2-column grid, 30 tall, radius 9, 8% fill, holding `terminal`
  "Start anyway" and `bell` "Notify when back".
- Close button: an 18 pt circle at the top-left, visible **on hover only**
  (VoiceOver always exposes it).
- Clicking the card body opens the panel **pushed straight to that Provider
  page**. Clicking a button runs its action and dismisses.

## Stack (several toasts at once)
- Use **one window** hosting a `ToastStack`, never one window per toast.
- Newest on top. Behind it:
  - Depth 1: `offset y +12`, `scale 0.95`, opacity 0.8.
  - Depth 2: `+24`, `0.90`, opacity 0.5.
  - Depth 3 and beyond: hidden, but still counted.
- Collapsed, the cards behind take the **front card's height**, with their
  content hidden, so they peek evenly.
- **Hovering the stack fans it out.** Each card sits at its real height with 10
  gaps, and the window grows with `Motion.nav`. Leaving the stack collapses it.
- Auto-dismiss timers **pause while the stack is hovered**.
- At most 4 live toasts. A 5th drops the oldest auto-dismissing one first, and
  otherwise the oldest.

## Motion
- **Arrive:** it emerges from the menu bar icon. It starts at `scale 0.32,
  offset y -38, blur 8, opacity 0` with anchor top-center, and animates to
  identity with `Motion.toastIn` (a slight overshoot).
- **Icon pulse:** at the same moment the status item draws an expanding ring in
  the tier ink (scale 0.6 → 2.6, opacity 0.9 → 0, 0.9 s). The out tier fires
  it twice, 0.22 s apart.
- **Ring sweep:** from the previously announced remaining to the new one (M4), delay 0.28 s.
- **Pace bar fill:** scaleX 0 → 1, `Motion.reveal`, delay 0.3 s.
- **Drain bar (half):** linear scaleX 1 → 0 over the auto-dismiss duration.
- **Breathing glow (out):** the border glow alternates between two intensities,
  2.4 s ease-in-out, forever. Reduce Motion turns it off and uses a static glow.
- **Dismiss:** the card shrinks back into the icon (`scale 0.3, offset y -72,
  opacity 0`, 0.42 s nav curve), and the cards behind move up one depth.
- **Reduce Motion:** 0.2 s fade in and out, with no pulse, no sweep and no scale.

## Accessibility
- Post `.announcementRequested` with high priority: "{title}. {sub-line}".
- The window never takes focus (it doesn't today; keep it that way).
- The toast stack is reachable via the panel's "Recent warnings" (see Q5), because
  toasts that auto-dismiss can't be reached by keyboard in time.
