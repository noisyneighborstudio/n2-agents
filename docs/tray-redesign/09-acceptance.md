# 09: Acceptance checklist

The reviewer runs this list. Every box must be checked, in **both light and dark**
appearance, unless marked otherwise. Attach evidence (a screenshot or recording
per section).

## Structure
- [ ] The panel opens on **Fleet**. The order is header, Open next best, machine
      sections, footer.
- [ ] Hierarchy is Machine → Profile → Provider → Configure. No page skips a level.
- [ ] The back button always names the parent ("‹ Default", "‹ Codex").
- [ ] Esc and ⌘[ pop, and Esc at the root closes the panel.
- [ ] There's no accordion expansion anywhere.

## Glance
- [ ] Every profile card shows every slotted provider's logo, a value and a bar, without scrolling horizontally.
- [ ] The tally in the Fleet header matches the sum of the cards.
- [ ] Every value reads as remaining (e.g. "32% left"). "Used" appears only in chips and Diagnostics.
- [ ] Unmetered, stale, failed and signed-out slots **never show a percentage**.
- [ ] Open next best never picks an unmetered, stale, failed or signed-out slot.

## Status
- [ ] All seven `SlotStatus` states are distinguishable in **grayscale** (take the screenshot with Color Filters → Grayscale).
- [ ] Every `Usage.Note` case maps as in `03-states.md`. The switch has no `default`.
- [ ] The words "unknown" / "Restriction reset unknown" / "Recovery time unknown" appear nowhere.
- [ ] Text contrast is at least 4.5:1 for every ink on the lightest glass (`#E6E6EA`) and on the dark panel. Record the ratios.

## Provider page
- [ ] Exactly one prominent action is visible, and it matches the table in `03-states.md`.
- [ ] Out: the suggestion card is shown when a candidate exists, and "Start anyway" is bordered.
- [ ] Out with no candidate: there's no suggestion card, and "Start anyway" is prominent.
- [ ] Diagnostics is collapsed by default. Opening it grows the panel smoothly, and Copy report copies all shown keys.
- [ ] The terminal menu lists installed terminals, checkmarks the current one, and the choice persists.
- [ ] "Open app" is hidden when there's no desktop app.

## Configure
- [ ] There are no rows named "Copy …". Paths and commands are values with Reveal/Copy icon buttons.
- [ ] Copy shows a checkmark for 1.4 s and VoiceOver announces "Copied".
- [ ] Sign out asks for confirmation.

## Logos and icons
- [ ] Every provider glyph is its real logo via `LabMark`, tinted by status.
- [ ] Every other icon is an SF Symbol, including menu items. There are no emoji and no custom-drawn icons for which a symbol exists.
- [ ] Tile corner radius is 25% of the side at every size.

## Motion (record at 60 fps)
- [ ] Push/pop uses the nav curve (0.48 s). The outgoing page moves to −30% and fades.
- [ ] The strip → rows flight fans out per provider, and back returns each logo to its own segment.
- [ ] Row → hero flight: the glyph lands and **then** the ring draws.
- [ ] Switch: the glyph flies from the suggestion card to the hero, and the content restaggers.
- [ ] Interrupting a push with a pop reverses smoothly. There's no jump and no queue.
- [ ] Reduce Motion: every transition is a 0.2 s crossfade, with no flight, no scale, no pulse and no breathing glow.
- [ ] No dropped frames during push on a base-model Apple Silicon Mac (Instruments → Animation Hitches: none over 1 frame).

## Toasts
- [ ] 50 / 25 / 10 / out each announce once per tier entered. Recovery clears the tier, and dipping again re-announces.
- [ ] A jump across tiers announces only the worst one.
- [ ] Stale, failed and unmetered readings never toast.
- [ ] Half auto-dismisses at 5.2 s with a drain bar. Quarter dismisses at 8 s. Low and out stay.
- [ ] Hovering the stack fans it out and pauses timers. Leaving collapses it.
- [ ] Clicking a toast opens the panel pushed to that Provider page.
- [ ] The pace sentence and bar are omitted when the window duration or reset is missing.
- [ ] VoiceOver announces "{title}. {subline}" and the toast never takes focus.
- [ ] The menu bar icon keeps a colored dot after a quarter-or-worse toast is dismissed, until the panel is opened.

## Appearance (see `11-appearance.md`)
- [ ] Every page and toast has been checked in Light, Dark, and Auto while switching live. Nothing needs a reopen to update.
- [ ] A dark menu bar over a light wallpaper (and the reverse): the status icon and pulse follow the menu bar's appearance.
- [ ] Light mode: cards have a hairline and a soft shadow, and the out toast has a breathing border, not a glow.
- [ ] The hero status badge glyph is dark in dark mode and white in light mode.
- [ ] Increase Contrast: hairlines at 20%, and cards get a stroke. Reduce Transparency: no tone step on push.
- [ ] There's no `colorScheme` branching in view code (grep `colorScheme ==`).

## i18n
- [ ] Running under the pseudo-language (`-AppleLanguages "(en-XA)"`, or the double-length pseudolanguage) shows no clipping on any page or toast.
- [ ] No string concatenation of sentence fragments (grep for `+ "` in views).
- [ ] Every date, duration and percent uses `.formatted`.

## Gates
- [ ] `scripts/check.sh format`, `scripts/check.sh lint`, `scripts/test.sh`, and `tray/build.sh` pass locally.
- [ ] CI is green on the exact pushed commit.
