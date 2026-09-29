# 08: Slices (build order)

Follow the repo's `AGENTS.md`: vertical slices of a few hundred lines each,
**one commit per slice** with a `Slice: <slug>` trailer, gates green locally and
in CI before the next slice. Copy these into `docs/slices.md` a few at a time.
Don't paste all of them.

Every slice's proof includes:
- the gates: `scripts/check.sh format`, `scripts/check.sh lint`, `scripts/test.sh`, and `tray/build.sh`;
- a screen capture of the behavior, in light **and** dark;
- the behavior again with Reduce Motion on, when the slice has motion.

---

### S1 `status-vocabulary`
- **Behavior:** Existing rows and strips draw status through the new `SlotStatus` /
  `StatusInk`. Unmetered readings get a dashed ring, and failed checks show `?`.
  "Restriction reset unknown" and "Recovery time unknown" are gone.
- **Proof:** unit tests covering every `Usage.Note` → `SlotStatus` case
  (exhaustive switch, no `default`), and the stale and unmetered cases never
  yielding a percentage. Screenshot of each state.
- **Scope:** no navigation changes, no new pages.

### S2 `real-logos-everywhere`
- **Behavior:** Every provider glyph uses `LabMark` inside the 25%-radius tile,
  tinted by status ink.
- **Proof:** grep shows no monogram rendering outside `LabMark`'s fallback.
  Screenshot.
- **Scope:** tiles only.

### S3 `page-stack-fleet-profile`
- **Behavior:** The panel opens on Fleet (a "This Machine" section plus
  profile cards with capacity strips). Tapping a card pushes the Profile page,
  and the strip logos fly into the rows. Back reverses it. The accordion is gone.
- **Proof:** a screen recording of push/pop, and the same with Reduce Motion (crossfade). Esc / ⌘[ pop.
- **Scope:** the Provider page stays the old expanded slot content until S4.

### S4 `provider-page`
- **Behavior:** Tapping a row pushes the Provider page with the hero, chips,
  primary split button, tiles and Configure/Diagnostics rows. The glyph flies from
  row to hero, the ring draws in, and the content staggers in.
- **Proof:** recording of each status's Provider page. Diagnostics shows the raw
  note for a restricted slot.
- **Scope:** Configure can push a placeholder page until S5.

### S5 `configure-page`
- **Behavior:** Account / Launch / Files with Reveal and Copy icon buttons. Copy
  shows a checkmark and posts a VoiceOver "Copied". Sign out asks for confirmation.
- **Proof:** a test that copy puts the exact path or command on the pasteboard,
  plus a recording.

### S6 `suggestion-and-switch`
- **Behavior:** Out and low slots show "{Provider} has room" per the rules in
  `03-states.md`. Switch navigates to the candidate with a glyph flight.
- **Proof:** unit tests on the suggestion picker: prefers the same profile,
  never picks unmetered / failed / stale / signed-out, returns nil when nothing
  qualifies. A test that Switch doesn't change the current session's account binding.

### S7 `toast-tier-ladder`
- **Behavior:** Toasts announce at 50 / 25 / 10 / out, once per tier entered,
  with the worst tier only on multi-tier jumps. New card design, but a single toast
  for now.
- **Proof:** unit tests for the tier transitions (enter, repeat, recover, re-enter,
  jump). The pace sentence is omitted when the window duration is missing.

### S8 `toast-stack`
- **Behavior:** Several toasts stack in one window, fan out on hover, and pause
  timers while hovered. Arrival from the icon, a pulse, ring sweep, and dismissal
  back into the icon.
- **Proof:** a recording of "Play the week" reproduced with a debug menu item
  that injects the four tiers. Reduce Motion recording.

### S9 `remote-machines` (blocked on Q1)
- **Behavior:** Peer machines appear as sections with their profiles.
- **Proof:** fleet suite `sh scripts/test-fleet.sh`, plus a screenshot with a
  synthetic peer.
