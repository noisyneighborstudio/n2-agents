# 03: Status vocabulary

One closed vocabulary, implemented once in `tray/StatusInk.swift` and used by
every surface: strip, row, hero, toast and menu bar icon. **No view computes
status on its own.**

```swift
enum SlotStatus: Equatable {
    case ready(left: Int)          // left >= 20
    case low(left: Int)            // 1...19
    case out(back: Date?)          // 0% left, or restricted / rate-limited
    case unmetered                 // provider has no usage API
    case checkFailed               // last probe errored; we don't know
    case signedOut                 // no usable credentials
    case checking                  // a probe is in flight and nothing is known yet
}
```

## Mapping from `Usage.Note` (every case must be handled; the switch has no `default:`)

| `Usage.Note` | `SlotStatus` | Notes |
|---|---|---|
| `.ok` | `.ready` / `.low` / `.out` by remaining % of the binding window | Binding window = the one with the least remaining |
| `.restricted` | `.out(back:)` | `back` = `Usage.maxedUntil` if known, else `nil` |
| `.noUsageAPI` | `.unmetered` | |
| `.fetchError`, `.rateLimited`, `.expired` | `.checkFailed` | `.rateLimited` is a 429 from the usage probe, not an exhausted allowance. `.expired` is the tray's own mark for a stale `ok` reading (the CLI never sends it). Stale readings must never show a % |
| `.noToken`, `.staleToken` | `.signedOut` | `.staleToken` is a rejected (401/403) or expired credential |
| `.sharedLogin` | Status of the Default profile's slot for that lab | Diagnostics shows "Shared login (Default)" |
| `.credentialOverride`, `.credentialStoreUnavailable`, `.ownerUnavailable`, `.migrationPending` | **Open question Q2**. Until it's decided: `.checkFailed`, with the raw note in Diagnostics | Do not invent copy |

## The table every surface reads

| Status | Ring shape | Ink (`Ink.*`) | Tile fill | Row label | Strip value | Hero headline | Primary action |
|---|---|---|---|---|---|---|---|
| ready ≥ 50 | arc, remaining | `green` | neutral | `68% left` + day | `68%` | "68% left this week" / "Full allowance left" (100) | Start session (prominent) |
| ready 20–49 | arc | `yellow` | neutral | `32% left` + day | `32%` | "32% left this week" | Start session (prominent) |
| low 1–19 | arc | `amber` | neutral | `12% left` + day | `12%` | "12% left this week" | Start session (prominent) + suggestion card |
| out | full amber track, `clock` hand glyph, no arc | `amber` | amber at 16% | `Back` + day | day, e.g. `Fri` | "Out until Friday" | Suggestion card is primary; "Start anyway" bordered |
| unmetered | dashed track (2 on, 3.2 off), no arc | `secondary` | neutral at 6% | `Not metered` | `—` | "Usage isn't metered" | Start session (prominent) |
| check failed | yellow track, no arc; `exclamationmark` badge | `yellow` | yellow at 14% | `Check failed` + retry button | `?` | "Couldn't read usage" | Start session (prominent) + "Check again" |
| signed out | red track, `xmark` | `red` | red at 14% | `Signed out` | `off` | "Not signed in" | Sign in… (prominent) |
| checking | track only, with the existing `Sweep` shimmer | `secondary` | neutral | `Checking…` | `…` | previous headline, dimmed | unchanged |

"This week" / "this month" come from `Usage.longWindow` (`7d` / `mo`).

## Hero sub-line (one sentence, no unknowns)

- ready/low: "Resets {clockTime(reset)}". Monthly: "Monthly · resets {date}".
- out: "Back {weekday, month day} at {time}". If `back == nil`, **omit the sub-line**.
- unmetered: "{Provider} doesn't report quota. Start freely."
- check failed: "The last check failed. You can still start a session."
- signed out: "Sign in to start sessions and read usage."

## Chips (at most 3, in this order)

| Condition | Chip |
|---|---|
| ready/low | `clock` "7-day window" / "Monthly window" |
| ready/low, used > 0 | `gauge.with.needle` "{used}% used" |
| out because rate limited / restricted | `gauge.with.needle` "Rate limited" / "Restricted" |
| credits reported and 0 | `bolt` "0 credits" |
| unmetered | `info.circle` "No quota API" |
| check failed | `info.circle` "Check failed" |
| signed out | `info.circle` "No credentials" |

## Suggestion rules ("{Provider} has room")

Shown on the Provider page when the status is `.out` or `.low`, and in the 10%
and out toasts.

1. Candidates: slots whose status is `.ready` **with a fresh reading** (not
   stale, not checking). Never `.unmetered`, `.checkFailed` or `.signedOut`.
2. Prefer the **same profile**. Among the candidates, pick the most remaining,
   and break ties by the soonest reset.
3. If there's none in the profile, use the fleet-wide `NextBest` if it's a `.slot`. The card then
   reads "{Provider} in {Profile} has room".
4. If there's none at all, **don't show the card**. The primary button becomes
   prominent "Start anyway", and the hero shows the countdown.
5. **Switch** starts a new session in the candidate (`actions.openSession`)
   and never touches the current session's account binding. In the panel it
   first navigates to the candidate's Provider page (the matched glyph flies
   from the card to the hero, see `04-motion.md`). A second tap on the now-prominent
   Start button opens it.

## Menu bar icon

The existing `StatusIcon` ring shows the **worst** slot in the active profile,
using the same inks. After a toast at the quarter tier or worse is dismissed, a
6 pt dot in that ink stays at the icon's top-right until the panel is opened.
