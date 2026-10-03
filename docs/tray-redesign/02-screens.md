# 02: Screens

All sizes are in points. The panel is **360 pt wide**, as `Metrics.width` already
is. Side inset is 12 pt for cards and 16 pt for text rows. When this file and the
prototype disagree, this file wins; tell the designer.

Symbol names are SF Symbols. `LabMark` means the provider logo via the existing
`LabMark` view, tinted with the status ink from `03-states.md`.

---

## Shared parts

### Logo tile
| Use | Tile | Logo | Corner | Fill |
|---|---|---|---|---|
| Capacity strip | 22 | 12.5 | 5.5 | status tile fill |
| Profile row | 28 | 16 | 7 | status tile fill |
| Provider hero | 48 | 27 | 12 | status tile fill |
| Suggestion card | 28 | 16 | 7 | neutral tile fill |
| Toast | 22 (inside 44 ring) | 13 | 5.5 | neutral tile fill |

The corner radius is always **25% of the tile side**. The matched-geometry
transition depends on this ratio (`04-motion.md`). Logo size is about 57% of the tile.

### Ring gauge
It shows **remaining**, not used. Stroke starts at 12 o'clock and runs clockwise, with round caps.

| Use | Diameter | Stroke |
|---|---|---|
| Profile row | 18 | 2.5 |
| Toast | 44 | 4 |
| Provider hero | 112 | 8 |

Track is `Ink.track`. The arc is the status ink. At 0% no arc is drawn (a round
cap would draw a dot). Shape variants per state are in `03-states.md`.

### Nav bar (Profile, Provider, Configure)
- Height 44 (Provider / Configure) or 52 (Profile, which also shows the profile
  identity). It is a three-column grid: leading back button, centered title,
  trailing optional button.
- Back button: `chevron.left` 16 pt semibold, then the **parent's name**, in
  `Ink.link` 13 pt, with a 28 pt tall hit area and a hover fill.

---

## Page 1: Fleet (root)

Order, top to bottom:

1. **Header** (52): "Fleet" 15 semibold, then "2 machines · 4 profiles" at 12
   secondary, baseline-aligned. Trailing is `FleetTally`: three symbol+count pairs,
   12 semibold, monospaced digits, 10 pt apart:
   - `checkmark` in `Ink.green`: ready count (ready + unmetered slots)
   - `hourglass` in `Ink.amber`: out count
   - `exclamationmark.triangle` in `Ink.yellow`: attention (check failed + signed out)
   - Hide a pair when its count is 0, except the ready pair, which always shows.
   - Each pair has `.help` and an accessibility label ("9 ready").
2. Hairline, inset 14.
3. **Open next best** (44 tall, 12 inset, radius 11): blue-tinted fill
   (`Ink.chip` at 14%), 0.5 pt blue stroke at 45%.
   - Leading: 24 pt blue circle with `bolt.fill` in white.
   - "Open next best" 13 semibold.
   - Trailing: `LabMark` 14, "Default · 100%" at 12 secondary, then `chevron.right`.
     The logo names the lab; at 360 pt a lab name and a profile don't both fit
     beside the title. VoiceOver still reads "Cursor · Default · 100%".
   - It keeps the existing `NextBestButton` behavior for the `.allMaxed` /
     `.usageUnavailable` / `.nothingSignedIn` cases, re-skinned to this shape.
4. For each machine:
   - **MachineHeader** (30 tall, 8 above): `laptopcomputer` for local,
     `desktopcomputer` for a peer. Then the name at 11.5 semibold ("This Machine"
     for self), a 6 pt status dot (`Ink.green` online, grey offline), status text
     ("online", "synced 1 min ago", "offline"), and on the trailing side
     "3 profiles".
   - **ProfileCard** per profile (336 × 78, radius 12, fill `Ink.surface`,
     8 pt gap between cards):
     - Row 1 (20): 9 pt profile-color dot with a 3 pt halo (color at 20%), then
       the name at 14 semibold. An "Active" capsule appears if active (10.5
       semibold, fill 8%). While labs use different profiles (the header's
       "Mixed"), the capsule names what this profile is active for instead:
       "Active for Codex", or "Active for 5 labs" with the labs on hover; a
       profile active for no lab has none. Then a spacer, a one-line
       **profile note** (below), and `chevron.right` 10.
     - Row 2: **CapacityStrip**. One segment per slotted provider, 54 wide with
       8 between. A segment is a 22 tile with a value to its right (11 semibold,
       monospaced), and below it a 3 pt bar spanning the segment (fill = remaining %).
     - Segment value: `32%` (ready/low), the weekday back (out, e.g. `Fri`),
       `—` (unmetered), `?` (check failed), `off` (signed out).
     - The whole card is one button. Hover raises the fill to 7.5% with a 0.5 pt
       stroke. Press scales to 0.985.
   - **Profile note**, first match wins: "N signed out" (red), "N out · M
     unchecked" (amber), "N running low" (amber), "All ready" (secondary).
5. **Footer** (40, hairline above): "Updated 2 min ago" at 11.5 secondary.
   Trailing are three 28 pt icon buttons: `arrow.clockwise` (refresh, spins while
   refreshing), `plus` (new profile), `slider.horizontal.3` (settings).

## Page 2: Profile

1. Nav bar (52): back chevron, then profile dot and name (15 semibold) as one
   back button. Trailing is the profile note.
2. Hairline.
3. One **row per provider** (44 pitch, 40 button, radius 8, 8 inset):
   - 28 logo tile, name at 14 medium (flexible), 18 ring (shape per state), then
     a label at 12.5 (min width 88) followed by a tertiary "when" (`Fri`,
     `Oct 21`), then `chevron.right` 10.
   - Check failed row: no chevron. A 28 pt circular **Check again** button
     (`arrow.clockwise`, yellow at 14% fill) sits outside the row button.
     Tapping it spins the icon until the check resolves.
4. No footer.

## Page 3: Provider (detail)

1. Nav bar (44): back "‹ {Profile}", title "{Provider}" 13 semibold, trailing
   `slider.horizontal.3` (pushes Configure).
2. **Hero**, centered, 12 below the nav:
   - 112 ring with a 48 logo tile at its center. A 20 pt status badge sits at
     the bottom-right of the tile (out = `hourglass`, check failed =
     `exclamationmark`, signed out = `xmark`), with a 3 pt ring in the panel color.
   - Headline 17 semibold, 14 below. Sub 13 secondary, centered, 28 side inset.
   - Out only: countdown capsule "in 3d 10h" (`clock`, amber at 14% fill, 24 tall).
   - Check failed only: "Check again" capsule button (spins while checking).
   - Chips row (22 tall, radius 6, 7% fill, 11.5 secondary, symbol + text):
     one to three chips. Content is in `03-states.md`.
3. **Suggestion card** (out and low states only, and only when a suggestion
   exists per `03-states.md`): 16 inset, radius 12, blue at 12% with a 0.5 pt
   blue stroke. It holds a 28 tile, "{Provider} has room" 13 semibold, a
   "{n}% left · resets {day}" sub, and a **Switch** capsule button (blue, white
   text, 28 tall).
4. **Primary split button** (36 tall, radius 9, 14 below):
   - Label: terminal symbol, then "Start session", then "in {Terminal}" at 60%.
   - The ▾ half opens a menu: header "Open in", then terminals with a checkmark
     on the current one. Picking one persists as the preferred terminal.
   - **Prominent** (filled `Ink.chip`, white text) when the state is ready, low,
     unmetered or check failed. **Bordered** (6% fill, 1 pt 14% stroke) when out, where it
     reads "Start anyway". Signed out: "Sign in…" with `key`, prominent, and no ▾.
5. **Action tiles**, a 3-column grid with 8 gaps (58 tall, radius 10, 6% fill,
   18 symbol above an 11.5 label):
   - `macwindow` "Open app" (hidden when there's no desktop app; the others widen)
   - `arrow.left.arrow.right` "Switch account"
   - `arrow.right.doc.on.clipboard` "Move session" (Transfer session)
6. **Grouped list** (radius 10, 5% fill, 14 inset, 16 bottom):
   - Row `slider.horizontal.3` "Configure" with the command in mono at 12
     tertiary and a chevron. It pushes Configure.
   - Row `info.circle` "Diagnostics" with "checked 2:02 AM" and a chevron that
     rotates 90° when open. It toggles the disclosure.
   - **Disclosure:** a key/value table (22 pt rows, key 11.5 tertiary, value mono
     11.5 at 75%), then two small buttons, `doc.on.doc` "Copy report" (turns into a
     green `checkmark` for 1.4 s) and `arrow.clockwise` "Check now".
   - Diagnostics keys (show only the ones present): Account, Observed, Signal (raw
     note), Window, Used, Resets, Credits.

## Page 4: Configure

Section headers are 11 semibold tertiary uppercase ("ACCOUNT", "LAUNCH",
"FILES"), with 16 above and 6 below. Groups have radius 10 and a 5% fill.

- **ACCOUNT:** `person.crop.circle` "Usage account" with the id in mono below,
  trailing "Owned by {Profile}" and a chevron. It opens the existing
  account-ownership flow.
- **LAUNCH:**
  - `terminal` "Terminal", with a trailing pop-up button showing the current terminal and `chevron.up.chevron.down`.
  - `chevron.left.forwardslash.chevron.right` "Command", with the mono value and a copy icon button.
- **FILES:** `folder` "Config" and "App data". The path sits below in mono 11,
  middle-truncated. Trailing are two 28 icon buttons: `arrow.up.forward.square`
  (Reveal in Finder) and `doc.on.doc` (Copy).
  - After a copy, the icon becomes a green `checkmark` for 1.4 s and VoiceOver announces "Copied".
- A last group holds `key` "Sign in again…" (link ink) and
  `rectangle.portrait.and.arrow.right` "Sign out of {Provider}" (red ink,
  with a confirmation alert).

## Hit targets and focus

- Every control is a real `Button` with an accessibility label. Icon-only
  buttons carry `.help` and `.accessibilityLabel`.
- Visual size can be 28, but the hit area is at least 28 × 28 in the panel
  (the macOS menu-extra convention). Keyboard focus rings are the system's.
- Tab order follows reading order. Arrow keys move between rows on the Fleet and
  Profile pages, and Return activates.
