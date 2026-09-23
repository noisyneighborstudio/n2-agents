# The panel — specification

360 pt wide `NSPopover`, anchored to the status item. Height is content-driven:
**588 pt with three profiles** and grows with the profile count. Both appearances are
specified; see `TOKENS.json` for the colour sets.

Reference renders: `images/01-panel-default.png` (default state, both appearances),
`images/02-panel-states.png` (four states), `images/04-metrics.png` (redlines).

---

## 1. Shell

- `NSVisualEffectView`, popover material, 12 pt corner radius, 1 pt border.
- Sections are separated by 1 pt hairlines at 10% white (9% black in light). No shadows
  between sections, no inset card shadows.
- Side padding is 12 pt throughout, so the content column is **334 pt**.
- Right-click on the status item keeps a minimal `NSMenu`: About, Settings…, Quit ⌘Q.
  The panel is the left-click surface; ⌘Q must keep working when the panel has focus.

## 2. Header — 44 pt

`[app icon 18] N2 Agents ······ Active [dot 7] Default [gear 24]`

- App icon at 18×18, 4 pt radius.
- Title 13 pt semibold.
- `Active` label 11 pt secondary, then the active profile's colour dot and its name at
  11.5 pt. This is the "who am I right now" answer and must never be truncated — if the
  profile name is long, truncate the name with a tail ellipsis, never the word `Active`.
- Gear is a 24 pt icon button, `aria`-equivalent label "Settings". Opens preferences.

## 3. Profiles section

Label row: `PROFILES` 11 pt semibold caps, tracking +0.05em, with the count right-aligned.

### 3.1 Profile card — 334 × 98 pt

9 pt radius, 8 pt vertical / 9 pt horizontal padding, 7 pt between its three rows,
8 pt between cards. The active profile's card takes the accent tint and accent border;
all others take the neutral card fill.

**Row 1 — identity, 18 pt**

`[colour bar 3×18] Name ······ [status dot 6] Desktop running`

- Colour bar uses the profile's hashed colour (§ `DATA-SOURCES.md` 2).
- Trailing status is a word, not an emoji: `Desktop running` / `Desktop idle`, or
  `1 version behind` in amber, or `Rebuilding…`.

**Row 2 — quota, 29 pt (two 11 pt rows, 7 pt apart)**

```
5h  ▓▓▓▓▓░░░░░  62%   resets 2:14 PM
7d  ▓▓░░░░░░░░  31%
```

- Label column 15 pt, value column 26 pt right-aligned, reset column 84 pt right-aligned.
  The reset column is reserved on both rows so the two tracks stay the same length.
- Track 4 pt tall, 2 pt radius. Fill colour by threshold: under 50% ok, 50–80% warn,
  over 80% high.
- **Colour is never the only signal** — every bar is paired with its number.
- When the profile has no readable quota, row 2 collapses to a single line carrying the
  note verbatim plus an action button:
  `Claude quota unavailable — token expired   [Log In]`

**Row 3 — vendor chips, 19 pt**

Chips 17 pt tall, 4 pt radius, 4 pt apart, in `N2_VENDORS` order.

- **Filled** — this profile is active for that lab (`slots[v] == "active"`).
- **Outlined** — this profile has a slot for that lab (`slots[v] == "ok"`).
- **Absent** — no slot. Do not render a disabled chip.
- **Dashed** — the vendor's `isolation` is `swap` (Gemini today). Clicking it is a global
  side effect, so it confirms first, matching the CLI's `--switch` rule.

### 3.2 Interactions

- Click a card → make that profile active for every vendor (`agents use <P>`).
- Click a chip → switch that one lab (`agents use <P> --vendor <v>`).
- Select a chip → the card expands with that vendor's actions
  (`images/02-panel-states.png`, state 1):
  `Open in <terminal> ▾` · `Log In…` · `Copy command  claude-client ⧉`
  and for Claude only: `Claude Desktop  clone current ›` · `Transfer session…`

### 3.3 Best-profile action — 30 pt, full width

`⚡ Open Claude Code in best profile ······ Client · 12%`

Names its pick before you commit, which `--best` on the CLI cannot. Hidden entirely when
no profile has a readable quota — never guess a winner.

## 4. Recent sessions

Label row `RECENT SESSIONS` with the vendor name right-aligned. Rows are 40 pt, 7 pt
radius, two lines:

```
● n2-agents                                    2m
  make the porcelain parser tolerate unknown tags
```

Leading dot is the owning profile's colour. Line 2 is the first user prompt, truncated
with a tail ellipsis. Clicking resumes via `--start-from-session`.

## 5. Footer — 31 pt

`0.0.0 · Stable · up to date ······ Report a Bug  Quit`

Version, channel and update state fused into one line — in the current menu these sit in
three different places.

## 6. States

`images/02-panel-states.png`.

| State | Trigger | Treatment |
|---|---|---|
| Vendor selected | chip click | card expands with that lab's actions |
| Clone drift | `isStale(profile)` true for any profile | amber banner above the profiles list: `Claude 0.7.4 — rebuilding 1 of 2 clones  [Details]`; drifting card shows `1 version behind` and `Waiting — clone is in use  [Rebuild Now]`; in-flight card shows a determinate bar |
| Degraded | `claudeAppPath == nil`, or `usage_table` note ≠ `ok` | amber banner `Claude Desktop not found — CLI profiles still work  [Locate…] [Download…]`; per-card notes carry the CLI's own wording; best-profile action hidden |
| First run | no profiles | hub glyph, `No profiles yet`, one line explaining a profile, `New Profile…`, and `Your current logins stay put as "Default".` |

## 7. Status item

Replace the coloured 18 pt `.icns` with a **template image** so it inverts with the menu
bar and dims when inactive. The existing badge mark (hub and six spokes) works as a
monochrome template; keep the colour version for the app and clone icons.

## 8. Copy

Every user-facing string. Sentence case, no emoji, no trailing colons.

| Context | String |
|---|---|
| Header | `Active` |
| Section labels | `PROFILES`, `RECENT SESSIONS` |
| Profile status | `Desktop running`, `Desktop idle`, `1 version behind`, `Rebuilding…`, `Waiting — clone is in use` |
| Quota | `5h`, `7d`, `resets 2:14 PM` |
| Quota errors | `Claude quota unavailable — token expired`, `Quota check failed — offline` |
| Buttons | `Log In`, `Retry`, `Rebuild Now`, `Details`, `Locate…`, `Download…`, `New Profile…` |
| Best action | `Open Claude Code in best profile` |
| Vendor actions | `Open in <terminal>`, `Log In…`, `Copy command`, `Claude Desktop`, `Transfer session…` |
| Drift banner | `Claude <version> — rebuilding <n> of <m> clones` |
| Missing desktop | `Claude Desktop not found — CLI profiles still work` |
| Degraded note | `Ranking is unavailable while any profile is unreadable — "best" is hidden rather than guessed.` |
| First run | `No profiles yet` / `A profile is one identity holding a slot per lab — Claude, Codex, Grok and the rest move together when you switch.` / `Your current logins stay put as "Default".` |
| Footer | `0.0.0 · Stable · up to date`, `Report a Bug`, `Quit` |

Two strings the current menu should lose either way: `Re-patch Claude Desktop Clones` and
`Auto-repatch Claude Desktop Clones` differ by five characters and sit adjacent; and
`Copy Command:  <cmd>` puts a value inside a label behind a double space.

## 9. Accessibility

- Control heights here are macOS pointer metrics (17–40 pt), deliberately not the 44 pt
  touch target. Do not "fix" them upward.
- Body text `#ECECEE`, secondary at 64% white — 5.2:1 on the card fill. Keep secondary at
  or above 62% white; the AppKit default of 55% fails.
- Every meter is paired with its number, so the panel survives without colour.
- Icon-only controls (gear, session open) need accessibility labels.
