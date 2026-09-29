# 06: Tokens

Machine-readable copy: `tokens.json`. Colors go in `Ink.swift` as adaptive
colors, like the existing ones. **Measure each new light value against `#E6E6EA`
(the greyest the glass gets) and write the ratio in a comment.** If a value
misses 4.5:1 for text, darken it; don't ship it.

## Color

| Token | Dark | Light | Use | Status |
|---|---|---|---|---|
| `Ink.green` | `#30D158` | `#1A7431` | ready ≥ 50, tally ready | exists |
| `Ink.yellow` | `#FFD60A` | `#7A5C00` (≈5.0:1) | ready 20–49, check failed, attention tally | **new** |
| `Ink.amber` | `#FFB340` | `#9A5500` | low, out | exists (prototype used `#FF9F0A`; use Ink) |
| `Ink.red` | `#FF7369` | `#B8261C` | signed out, destructive | exists; dark lightened from `#FF6961`, which is 4.3:1 on a card |
| `Ink.info` | `#64D2FF` | `#006A8E` (≈4.9:1) | half-tier toast | **new** |
| `Ink.link` | `#6AAEFF` | `#0A4FC2` | back buttons, links | exists |
| `Ink.chip` | `#0A5BD6` | `#0A4FC2` | prominent button fill, Switch | exists |
| `Ink.secondary` | white 62% | black 62% | sub-lines, labels | exists |
| `Ink.tertiary` | white 52% | black 55% | "when", timestamps, keys | **new**; darkened from 40% / 48%, which measured 3.3:1 / 3.5:1 |
| `Ink.surface` | white 6% | white 85% | cards, groups | exists |
| `Ink.track` | white 10% | black 8% | ring and bar tracks | **new** |
| hover fill | white 7% | black 5% | rows, cards | **new**, `Ink.hover` |

Tinted fills (tile backgrounds, capsules, suggestion card) are the status ink at
the percentage given in `02-screens.md`. In light mode, multiply that alpha
by 0.8.

Profile colors come from the existing `ProfileColor.of(name)`. Don't hard-code
them. (The prototype's pink, blue, purple and orange are placeholders.)

## Type (SF Pro, system)

| Role | Size | Weight | Notes |
|---|---|---|---|
| Page title | 15 | semibold (650) | tracking -0.01em |
| Hero headline | 17 | semibold | tracking -0.015em |
| Row name | 14 | medium | |
| Card name | 14 | semibold | |
| Body / button | 13–13.5 | regular / semibold | |
| Sub-line | 12.5–13 | regular | `Ink.secondary` |
| Meta / chips | 11.5–12 | regular | |
| Section header | 11 | semibold | uppercase, `Ink.tertiary` |
| Numbers | any | — | always `.monospacedDigit()` |
| Paths, commands, ids | 11–12 | regular | `.monospaced()` (SF Mono) |

Dynamic Type doesn't apply to menu bar extras on macOS. Don't add scaling.

## Spacing and radii

| Token | Value |
|---|---|
| Panel width | 360 |
| Card inset | 12 |
| Text inset | 16 |
| Card gap | 8 |
| Card radius | 12 |
| Group radius | 10 |
| Row button radius | 8 |
| Primary button radius | 9 |
| Toast radius | 18 |
| Panel radius | existing `GlassWindow` value |
| Tile radius | 25% of side |
| Hairline | 1 px at 7% |
