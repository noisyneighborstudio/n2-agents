# 01: Architecture

## Navigation model

The panel becomes a **stack of pages**, not an accordion.

```swift
enum PanelRoute: Hashable {
    case fleet                                   // root, always at the bottom
    case profile(String)                         // profile name
    case provider(profile: String, vendor: String)
    case configure(profile: String, vendor: String)
}
```

- Hold it on `PanelModel` as `@Published var path: [PanelRoute] = []`. An empty
  path means Fleet. It replaces `model.expanded` (the accordion's open profile).
- **Do not use `NavigationStack`.** It brings its own chrome, toolbar and push
  animation, and those clash with the glass panel and the matched geometry
  transitions. Build a small `PageStack` view:
  - Render the **top two** routes only: the current page and the one beneath it.
  - The current page's transition is `.move(edge: .trailing)` on push. The page
    beneath gets `offset(x: -0.3 * width)` and `opacity(0)`. All of it runs
    inside `withAnimation(Motion.nav)`.
  - Popping reverses the same animation.
- **Panel height** follows the current page's content height. Reuse the
  existing `ContentHeight` preference key / `FittingScroll`, and animate the
  window height with `Motion.nav`. The panel keeps a single window; there's
  never a second one.
- **Back:** each page's leading nav button pops. <kbd>⌘[</kbd> and
  <kbd>Esc</kbd> pop too. At the root, Esc closes the panel, as it does today.
- **Reopening the panel** restores the last path if it was open less than 60 s
  ago; otherwise it resets to Fleet. (Open question Q4 confirms the window.)

## Pages and their existing sources

| Page | Built from (existing) | New pieces |
|---|---|---|
| Fleet | `PanelHeader`, `NextBestButton`, `ProfilesSection`, `CapacityStrip`, `CapacitySegment`, `PanelFooter` | `MachineHeader`, `FleetTally` |
| Profile | `SlotRow` (collapsed form), `Gauge` | `ProfileNavBar` |
| Provider | `SlotActions`, `OpenButton`, `UsageDetailsView` (contents only), `Chip` | `ProviderHero`, `SuggestionCard`, `ActionTiles`, `DiagnosticsDisclosure` |
| Configure | account ownership (`AccountOwnership.swift`), copy command / folder actions from `SlotActions` | `ConfigureSection` rows with Reveal/Copy icon buttons |
| Toast | `QuotaToast`, `GlassWindow(.toast)` | `ToastStack`, `UsageToastCard`, tier ladder (`05-toasts.md`) |

## Data needed per page (all read from `PanelModel` / `PanelData`)

- **Fleet:** machines → profiles → slots with `Usage` per `(profile, vendor)`,
  `ProfileState` per profile, `NextBest`, and the last refresh time.
- **Profile:** the profile's slotted vendors in table order (`data.slotted`),
  plus each slot's `Usage` and signed-in state.
- **Provider:** that slot's `Usage` (both windows, resets, note), account id,
  observed time, credits (if the CLI reports them), terminals list, desktop
  availability (`hasDesktop`), and the suggestion (rules in `03-states.md`).
- **Configure:** account ownership, launch command (e.g. `codex-default`),
  config folder path, app data folder path, and the preferred terminal.

**Machines:** local profiles come from `PanelData.profiles`. Profiles held on
peers are **not in `PanelData` today**. See `10-open-questions.md` Q1. Until a CLI
source exists, the Fleet page shows only the "This Machine" section, and its
header is still drawn so the layout doesn't change later.

## What to delete

- The accordion: `model.expanded` and the in-place expansion inside `ProfileCard`.
- "START" / "CONFIGURE" section labels inside a slot.
- Rows named "Copy command", "Copy config folder" and "Copy … data folder"
  (they become values with icon buttons on Configure).
- Rendering of "Restriction reset unknown" / "Recovery time unknown".
- The raw `codex: rate_limit_reached` / `credit balance` lines outside Diagnostics.
- `meterColor(_:)` in `PanelView.swift`, replaced by `StatusInk.for(_:)` (`03-states.md`).

Flag any file that becomes unused in the slice's commit message, and remove it
in that slice.

## Module layout (new files)

```
tray/Motion.swift          // Motion.nav, Motion.reveal, Motion.press; reduce-motion helpers
tray/PageStack.swift       // PanelRoute stack container
tray/FleetPage.swift
tray/ProfilePage.swift
tray/ProviderPage.swift
tray/ConfigurePage.swift
tray/StatusInk.swift       // closed status vocabulary → glyph / ink / label / action
tray/ToastStack.swift      // replaces QuotaToastView; QuotaToast keeps window + tier logic
```

`PanelView.swift` shrinks to the root container, header and footer. Keep every
file under about 500 lines.
