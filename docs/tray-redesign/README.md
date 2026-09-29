# N2 Agents: menu bar popover redesign handoff

Kept as received, except where an implemented slice corrected it (the note
mapping in `03-states.md`, the `tertiary` and dark `red` values in
`06-tokens.md`); those tables describe the shipped code.

Decisions the handoff left open, as built:
- **Page fill.** A live glass view can't be sampled, and `windowBackgroundColor`
  is pure white in light mode (white cards vanish on it), so `Ink.page` is the
  glass's measured tone: `#ECECF0` light, `#252932` dark.
- **Fleet-managed tools**, which `12-whole-popover.md` doesn't place, live in
  Settings › Fleet with pairing, kept-local items and the activity feed.
- **Send Session and Send Work** report their outcome on their page; a
  session's transfer still re-reads the approved Macs and matches by identity.
- **Strip bars** of out, failed and signed-out slots are a tinted track with no
  fill: a full bar would read as full capacity in grayscale.
- **Out with no known return**: the hero reads "Out of allowance" and drops
  its sub-line and countdown.
- **Move session** lists this slot's recent sessions; each offers the other
  profiles holding the lab and, for Codex, Send to Machine. **Switch account**
  is sign-in with confirmation.
- **Profile note** adds "{n} check failed" when checks failed and nothing is
  out, rather than "All ready".

**Read this file first, all the way through, before writing any code.**

The design canvas and its HTML prototype (source of truth for look and
motion) travel with the handoff package, not this repository:
- `Popover — live prototype`: click through Fleet → Profile → Provider → Configure.
- `Usage warning toasts — live prototype`: press **Play the week**.
- `Taxonomy`, `Motion spec` and `Status vocabulary` are static boards.

The prototype is HTML. **Do not port its code.** It exists to show layout, copy
and motion. Build natively in SwiftUI in `tray/`, following these documents.

---

## What changes, in one paragraph

Today the panel expands profiles in place, and one expanded card shows raw
telemetry, launch buttons and file-path rows all on one surface. The redesign
makes it a **push-navigation stack of four pages**: Fleet → Profile → Provider
→ Configure. Each page answers one question. Raw telemetry moves into a
collapsed **Diagnostics** disclosure. Launch actions are ranked, and the
recommended one is the most prominent. Every provider is drawn with its **real
logo**. Usage warnings become a **four-step toast ladder** that stacks under
the menu bar icon.

## The hierarchy (do not change it)

```
Machine        section header on the Fleet page ("This Machine", then peers)
 └─ Profile    card with a capacity strip (every provider's logo and what's left)
     └─ Provider   row on the Profile page → Provider detail page
         └─ Configure   pushed page (Account / Launch / Files)
            Diagnostics collapsed disclosure on the Provider page
```

## Files in this package

| File | What it is | When to read it |
|---|---|---|
| `01-architecture.md` | Navigation model, state, mapping to existing types, what to delete | Before touching code |
| `02-screens.md` | Pixel spec for every page: sizes, spacing, order, behavior | While building each page |
| `03-states.md` | Status vocabulary: `Usage.Note` / `ProfileState` mapped to glyph, ink, label and action | Before any status UI |
| `04-motion.md` | Every animation with SwiftUI code, curves, durations and Reduce Motion | While building transitions |
| `05-toasts.md` | Usage warning toast ladder, tier logic and stack behavior | When building toasts |
| `06-tokens.md` + `tokens.json` | Colors (light and dark), type, spacing, radii | Always open |
| `07-copy.md` | Every user-visible string and formatting rule, i18n | While writing any `Text` |
| `08-slices.md` | The build order as vertical slices, each with its proof (per `AGENTS.md`) | To plan the work |
| `09-acceptance.md` | A pass/fail checklist the reviewer runs | Before you say "done" |
| `10-open-questions.md` | Decisions not yet made. Do not guess; ask. | Before starting |
| `12-whole-popover.md` | Every section of the old panel given a home: app header, Recent, Other Macs, Tasks, banners, and the Machine, Task, Send Work and Send Session pages | Supersedes the Fleet page's title and footer in `02-screens.md` |
| `11-appearance.md` | **Light and dark mode**: surfaces, buttons, toasts, menu bar appearance, Increase Contrast / Reduce Transparency | Before styling anything. The prototype is dark only |

## Non-negotiables (a violation fails review)

1. **Real provider logos only.** Use `LabMark` (template-rendered PDFs from
   `tray/logos/`). Tint them with the status ink. Never draw monograms or letters
   when a logo exists. The two-letter monogram is only the fallback `LabMark`
   already has for a lab with no logo.
2. **SF Symbols for every other icon**, including menu items (see project memory:
   "if a symbol exists for it, use it"). Symbol names are listed in `02-screens.md`.
3. **Colors come from `Ink`.** Never use a raw hex in a view. The prototype's hex
   values are dark-mode only. `06-tokens.md` gives the light values, and each must
   hold 4.5:1 for text (3:1 for glyphs). New inks go in `Ink.swift` with
   their measured contrast in a comment, as the existing ones have.
4. **Status shape before color.** Each state has a distinct glyph shape
   (`03-states.md`), and color only reinforces it. The UI must read correctly in grayscale.
5. **One curve for navigation.** Use `.timingCurve(0.32, 0.72, 0, 1, duration: 0.48)`
   everywhere a page moves. Do not tune the curve per screen.
6. **Reduce Motion replaces motion with a 0.2 s crossfade.** It doesn't remove
   feedback, and it doesn't leave transitions snapping without any feedback.
7. **Never advertise capacity you don't know.** An unmetered, stale or failed
   reading is never suggested as "has room". It never counts toward "Open next best",
   and it never shows a percentage. (Repository invariant in `AGENTS.md`.)
8. **Switch never rebinds an account.** "Switch" starts a *new* session in the
   suggested provider/profile. Resumed work keeps its original account binding.
9. **Unknown means omitted, not "unknown".** If a reset time or recovery time is
   unknown, the line is not rendered. "Restriction reset unknown" and "Recovery
   time unknown" are deleted from the product.
10. **Every string is localizable** (`String(localized:)`, `.formatted()` for
    dates, numbers and percents). No string concatenation that assumes English
    word order. See `07-copy.md`.
11. **Light and dark are both first-class.** The prototype shows dark only.
    Build light from `11-appearance.md`, and follow the system appearance.
    The menu bar icon follows the menu bar's own appearance.
12. **The CLI stays the behavior authority.** The view reads `PanelModel` and
    calls back through `PanelActions`. No view decides fleet or quota policy.

## Build order

Follow `08-slices.md` in order, one slice per commit, each with its proof.
Don't start slice N+1 until slice N is green in CI.
