# N2 Agents — status panel handoff

Design handoff for replacing the N2 Agents `NSMenu` with an `NSPopover` status panel.
Written to be read by an agent working in the `n2-agents` repo.

## Read in this order

1. `SPEC.md` — what the panel is, every element, every state, every string.
2. `DATA-SOURCES.md` — where each value comes from. Nothing on screen needs a field
   the tray would have to invent; two of them need work the tray does not do today.
3. `TOKENS.json` — measured geometry, type ramp and colours, machine readable.
4. `images/` — renders of the four design boards plus the audit of the current menu.

## What this replaces

The current `menuNeedsUpdate(_:)` in `tray/main.swift` rebuilds a flat `NSMenu` on every
open: three profile rows with a submenu each, then six ungrouped maintenance items, then
version and Quit. `images/05-audit-current-menu.png` marks ten specific problems with it.

The panel keeps every capability that menu has and adds the three a menu structurally
cannot hold:

- **Quota.** `agents best` already queries the OAuth usage endpoint per profile, and
  `agents run --best` exists because "which identity still has quota" is the real daily
  question. A menu cannot draw two meters per profile; the panel leads with them.
- **The vendor matrix.** A profile holds one slot per lab. In the menu that is six
  submenu rows per profile; in the panel it is a row of chips you can click.
- **Session context.** `session_meta` already extracts `cwd` and the first user prompt.
  A menu row can show one line; the panel shows both.

## Provenance — what is verified and what is not

Built by reading `tray/main.swift`, `tray/Vendors.swift`, `tray/UpdateChannel.swift`,
`tray/icon-badge.swift`, `agents` and `vendors.sh` at the state of the working tree on
2026-09-18. Field names, enum cases, CLI flags and the `V`/`P`/`A` porcelain record
shapes are quoted from that source.

Not verified:

- **`agents porcelain` was never executed.** Record shapes come from `Snapshot.parse`,
  not from live output. Check a real invocation before parsing against this doc.
- **All sample values are invented** — `62%`, `2:14 PM`, `1h 12m`, the session names.
  They are shaped like real output; they are not real output.
- **The renders use a Helvetica-metric substitute, not SF Pro.** SF was unavailable in
  the machine that produced `images/`. Text will run slightly narrower on a real Mac.
  Every geometry number in `TOKENS.json` was measured programmatically off the built
  layout, so those are exact; only the glyph shapes in the PNGs are approximate.

## Three findings worth acting on regardless of this design

1. **`Default` and `Client` hash to the same colour.** `icon-badge.swift` uses djb2 mod 7
   over a seven-colour palette, so collisions are common — and the colour is load-bearing,
   since it also lands on the cloned app icons. Salt the hash, or reserve one colour for
   `Default`.
2. **The status item uses a coloured `.icns` at 18 pt.** Status items should be template
   images so they invert with the menu bar and dim correctly when the app is inactive.
3. **`agents best` makes a network call per profile.** In a menu that never mattered
   because nothing called it on open. In the panel it must be cached and refreshed off the
   open path, or the popover blocks on `urlopen` behind a 10-second timeout. See
   `DATA-SOURCES.md` § Fetching.

## Open decisions

These were judgement calls, not requirements. Each is cheap to reverse.

- **Reset time is absolute (`resets 2:14 PM`), not relative (`resets in 1h 48m`).**
  Absolute needs no timer and cannot go stale while the popover is open; relative answers
  "can I wait this out" more directly. One string change either way.
- **Only the 5-hour window shows a reset.** `usage_table` reads `resets_at` off `five` and
  never off `seven`, so the 7-day row's trailing slot is deliberately empty.
- **A `Settings…` destination is assumed to exist.** The app has no preferences window
  today. If one is not coming, the gear button should open the existing shortcut/channel
  items in a small menu instead.
- **"Recent sessions" is scoped to Claude Code.** Codex also has readable sessions
  (`vendor_sessions codex` = `sessions`); the section could carry a vendor switch.

## `source/`

The Design artifact's own files — `canvas.json` plus one `.dc.html` per board. They render
only inside Claude Design; they are here so the design can be reopened and edited, not so
it can be built from. Build from `SPEC.md` and `TOKENS.json`.
