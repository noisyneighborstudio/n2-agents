# 11: Light and dark mode

The prototype is drawn **dark only**. The shipped app must be equally finished
in **both** appearances. It follows the system appearance (`NSApp.effectiveAppearance`)
and never forces one. This file is the light-mode half of the spec.

## Principles

1. **One code path.** Every color is an adaptive `Ink` token (`06-tokens.md`).
   There's no `if colorScheme == .dark` in a view. The only exceptions are the
   shadow and glow values in the table below, and those still live in `Ink`
   / `Motion`, not in views.
2. **Light mode is not inverted dark mode.** Apple's system hues are tuned for
   dark surfaces. Their light counterparts are **darker and less saturated**
   so text holds 4.5:1, which is why `Ink` has separate light values.
3. **Structure by fill, not by border.** In dark, surfaces lift with white
   at low alpha. In light, surfaces are near-opaque white cards on the grey
   glass, separated by a hairline and a soft shadow.
4. **Glass stays glass.** Keep `GlassWindow`'s material for the panel and toasts
   in both appearances. Don't paint an opaque background over it. The pages
   inside the stack get an **opaque** fill that matches the glass tone (see
   below), only so that pushed pages cover each other.

## Surface table

| Element | Dark | Light |
|---|---|---|
| Panel material | existing `GlassWindow` dark material | existing `GlassWindow` light material |
| Page fill (stack pages, opaque) | glass tone sampled, ≈ `#252932` | glass tone sampled, ≈ `#ECECF0` |
| Card / group fill (`Ink.surface`) | white 6% | white 85% |
| Card hairline | none (fill carries it) | black 6%, 0.5 pt, inside the stroke |
| Card shadow | none | `black 6%`, y 1, blur 2 |
| Hover fill (`Ink.hover`) | white 7% | black 5% |
| Pressed fill | white 10% | black 8% |
| Hairline dividers | white 7% | black 8% |
| Ring / bar track (`Ink.track`) | white 10% | black 8% |
| Neutral logo tile | white 9% | black 5% |
| Panel outer edge | 0.5 pt white 16% inner stroke | 0.5 pt black 12% inner stroke |
| Panel shadow | black 55%, y 30, blur 80 | black 18%, y 20, blur 50 |
| Nav back button / links | `Ink.link` (#6AAEFF) | `Ink.link` (#0A4FC2) |

**Page fill:** sample the resolved glass color once per appearance change. Don't
hard-code the hex values above; they're what the prototype shows. If sampling isn't possible,
use `NSColor.windowBackgroundColor`, and flag it in the slice, since the push then
reveals a slight tone step.

## Status and tint

| Element | Dark | Light |
|---|---|---|
| Status inks | `Ink` dark values | `Ink` light values (darker) |
| Tinted tile fill (out, failed, signed out) | ink at 16% / 14% / 14% | ink at 12% / 11% / 11% (×0.8) |
| Logos (`LabMark`) on a neutral tile | white 92% | black 85% |
| Logos on a tinted tile | status ink | status ink (light value) |
| Status badge on the hero tile | ink fill, glyph `#1C1C1E` | ink fill, glyph **white** |
| Badge separator ring | page fill, 3 pt | page fill, 3 pt |
| Chips | white 7% fill, secondary text | black 5% fill, secondary text |

## Buttons

| Element | Dark | Light |
|---|---|---|
| Prominent (Start session, Switch, Sign in) | `Ink.chip` #0A5BD6, white text (6.0:1) | `Ink.chip` #0A4FC2, white text (7.2:1) |
| Bordered (Start anyway) | white 6% fill, white 14% 1 pt stroke | white 70% fill, black 12% 1 pt stroke |
| Action tiles | white 6%, hover 11% | white 70%, hover black 5% over it, 0.5 pt black 6% stroke |
| Icon buttons | 65% label color | 60% label color |
| Suggestion card | `Ink.chip` 12% fill, 0.5 pt at 40% | `Ink.chip` 8% fill, 0.5 pt at 30% |
| Open next best | `Ink.chip` 14% fill, 0.5 pt at 45% | `Ink.chip` 9% fill, 0.5 pt at 32% |
| Focus ring | system | system |

## Toasts

| Element | Dark | Light |
|---|---|---|
| Card glass | `GlassWindow` toast material | same, light variant |
| Card edge | 0.5 pt white 16% | 0.5 pt black 10% |
| Card shadow | black 45%, y 24, blur 60 | black 16%, y 16, blur 40 |
| Out glow (breathing) | amber at 10% ↔ 24% outer glow, 1 pt amber at 35% ↔ 60% | **no outer glow** (it looks muddy on light glass); 1.5 pt amber border that breathes between 45% ↔ 85% |
| Menu bar icon pulse | tier ink (dark value) | tier ink (the **menu bar's** appearance decides, not the app's) |
| Pace tick | white, 1.5 pt ring in the card color | `#1C1C1E`, 1.5 pt ring in the card color |
| Drain bar | tier ink 70% | tier ink 80% |
| Close button | grey 95% circle, white × | white 95% circle, 0.5 pt black 15% stroke, black 70% × |

**The menu bar has its own appearance.** The status item's icon and its pulse
read `statusItem.button.effectiveAppearance`, which can differ from the app's
appearance (for example a dark menu bar over a light wallpaper). Tint the icon
from that appearance, never the app's.

## Mixed appearance edge cases

- **Appearance changes while the panel is open:** everything must re-resolve
  live. That happens for free with adaptive `NSColor`. Verify that the sampled page fill updates too.
- **Increase Contrast** (`accessibilityDisplayShouldIncreaseContrast`): hairlines
  go to 20% (black in light, white in dark), card fills gain a 1 pt stroke, and
  tinted fills double their alpha.
- **Reduce Transparency:** the glass becomes opaque (`GlassWindow` should already
  handle this). Page fill equals the glass fill, so there's no tone step.
- **Wallpaper tinting:** light glass picks up the wallpaper. Contrast is measured
  against `#E6E6EA` (the greyest the glass gets), per the existing `Ink` note.

## How to verify (add these to the checklist runs)

1. Every screen and toast in System Settings → Appearance → Light, then Dark,
   then Auto while switching.
2. Dark menu bar over a light wallpaper (and the reverse). The icon and pulse
   follow the menu bar.
3. Increase Contrast on, then Reduce Transparency on, in each appearance.
4. Grayscale (Accessibility → Display → Color Filters) in each appearance: all
   states stay distinguishable by shape.
5. Record contrast ratios for every `Ink` text color on `#E6E6EA` (light) and
   on the sampled dark page fill (dark), in the `Ink.swift` comments.
