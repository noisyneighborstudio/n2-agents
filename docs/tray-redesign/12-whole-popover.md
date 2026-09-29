# 12: The whole popover

The first pass redesigned the profile/provider part. This pass puts **every**
section of today's panel into the same taxonomy. Nothing new was invented for the
taxonomy itself. Each section got a layer (glance / decide / act / configure /
diagnose) and a home.

Homes, in order of preference:
1. **Root section**: only when it answers "can I use it now?" or "does something need me?".
2. **Banner on root**: only for a pending decision that another Mac is waiting on.
3. **Filtered view on an existing page**: the same component, scoped to the
   page's profile, provider or machine.
4. **Pushed page**: for deciding and acting on one thing.
5. **Settings window**: for managing. The popover never manages.

## Where each section went

| # | Today's section | What it showed | Layer | Now lives |
|---|---|---|---|---|
| 1 | Header | N2 Agents · Active ● Default · gear | Glance + act | **Root › App header.** Identity, then the Active switch on a second line (menu: per-profile, plus per-lab submenu); the tally; the gear. Per-lab activation also appears as "Use on This Mac" on Configure. |
| 2 | Open next best | Codex · N2 · 0% used | Act | **Root**, unchanged position. It says what's **left** ("100%"), from this Mac's slots only. |
| 3 | Profiles (5) | cards, notes "1 of 5 out", "1 needs sign-in · 0% used", "Usage unknown", blue active outline | Glance | **Root › This Machine.** "5 profiles" and `+` on the machine header. Notes come from the closed vocabulary ("1 out", "1 signed out", "1 check failed"). Active is a capsule, not a color. Setup is a banner on the Profile page. |
| 4 | Recent sessions | 2 cards: title, profile chip, logo, age, "…", path, branch, prompt; expand | Glance + act | **Root › This Machine › Recent** (2 newest). Filtered to the profile on Profile, and to profile + lab on Provider. **Sessions window** for all, with Profile / Provider filters. **Send Session** is a pushed page. |
| 5 | Fleet | "macbook… · 1/1 online", machine rows, "this Mac" tag, Enroll over Tailscale, Pair over SSH | Glance | **Root › machine headers.** This Machine carries its sync word, and **Other Macs** rows push the **Machine page**. Enroll and Pair become "Add a Mac…" in the `+` menu, which opens Settings pairing. |
| 6 | Shared profile | "nothing shared yet", Sync Now, Sign-in Sharing | Manage | **Settings › Fleet › Sync & Sharing.** Root shows only the conflict **banner** and the sync word. Check In sits on the Machine page. |
| 7 | Tasks | task card "failed", chips, Show Result, blue "Send Work to Another Mac…" | Glance → decide → act | **Root › Tasks** (≤3 rows, status shape) → **Task page** (hero, ranked actions, timeline, diagnostics). Send Work becomes a header link and pushes the **Send Work page**. Not answering becomes a **banner**. |
| 8 | Fleet activity | "Task started on … · 2:37 AM", Check in | History | **Task page › Timeline** and **Machine page › Recent activity**. The full feed moves to **Settings › Fleet › Activity**. Not on root. |
| 9 | Footer | 1.5.0 (79), flask, check-circle, Report a Bug, Quit | Chrome | **Root › Footer.** Version + channel glyph. The status glyph appears only when there's something to do (Update Available capsule, failed ⚠). Refresh + "Updated …", plus ladybug and power icon buttons. |

## The root, top to bottom

```
App header        N2 Agents / Active ● Default ⌄            ✓9 ⧗1 ⚠2  ⚙
Banners           (only when another Mac waits on you)
Open next best    ⚡ Open next best                Codex · N2 · 100% ›
This Machine      💻 This Machine ● in sync            5 profiles  +
  profile cards   Default [Active] ……… 1 out ›  (capacity strip)
  Recent          ⟲ Recent                                        ⤢
  session cards   Start/configure UI redesign                now …
Other Macs        🖥 Other Macs                           1 of 1 online
  peer rows       mac-mini ● 1 task running                         ›
Tasks             ✈ Tasks  1 running · 1 failed            Send Work…
  task rows       kc-before  on macbook… · 2:37 AM       ⊗ Failed ›
Footer            ↻ Updated 2 min ago           1.5.0 (79) ⚗  🐞  ⏻
```

(The glyphs above are shorthand for this sketch only. The app uses SF Symbols
and `LabMark`.)

## Decisions made in this pass (flag disagreement before building)

- **The root's title is the app, not "Fleet".** The machine sections carry the fleet.
- **Peer profiles aren't on root.** They can't be launched from this Mac (Q8), so
  they sit one level down, on the Machine page. Root stays one screen for one Mac.
- **Send Work is not prominent.** The root's one prominent action is Open next best.
- **Up to date shows nothing.** The check-circle is removed, and the footer only speaks up
  when there's an update or a failure.
- **Activity isn't a root section.** It's history, not a decision. Its durable
  half already drives the banners and task rows.
- **The composer and Send Session are pushed pages**, not modal alerts. Drafts live
  on the model, so dismissing the panel loses nothing.
- **"Needs sign-in" is spelled "signed out"** and "usage unknown" is spelled "check
  failed", so the popover uses one vocabulary everywhere.
