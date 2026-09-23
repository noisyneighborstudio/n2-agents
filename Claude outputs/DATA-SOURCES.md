# Data sources

Every element on the panel and the call behind it. Numbering matches the pins in
`images/03-anatomy-data-sources.png`.

All shapes below are read from `agents`, `vendors.sh` and `tray/*.swift` as of
2026-09-18. `agents porcelain` was never executed during this work — verify a live
invocation before trusting the record layouts.

---

| # | Element | Source |
|---|---|---|
| 1 | Active profile badge | `agents porcelain` → the `A` record. Already parsed as `Snapshot.active`. |
| 2 | Profile colour bar | djb2 over the profile name, mod 7, into the palette in `icon-badge.swift`. Reuse that exact function so a profile's colour matches its cloned app icon. |
| 3 | Desktop-running dot | The `P` record's second field (`desktopRunning`), which `isRunning(_:)` derives from `pgrep -f user-data-dir=<dataDir>`. This is the 🟢/⚪️ the menu already prints. |
| 4 | 5h / 7d meters, reset | `agents best` → columns `5H%`, `7D%`, `5H RESETS (UTC)`. Claude only (`vendor_usage claude` = `oauth`). The `note` column is displayed verbatim when it is not `ok`. |
| 5 | Vendor chips | The `P` record's slot map, `<vendor>:active\|ok`. Absent = no slot. Click = `agents use <P> --vendor <v>`. |
| 6 | Dashed chip | The `V` record's `isolation` field = `swap`. |
| 7 | Best-profile button | `pick_best` — lowest 5h, ties to 7d, rows whose note ≠ `ok` skipped. |
| 8 | Recent sessions | `agents sessions <profile> --vendor claude`. Line 1 is `basename(cwd)`, line 2 the first user prompt; both already extracted by `session_meta`. Click resumes with `--start-from-session=<id>`. |
| 9 | Footer | `CFBundleShortVersionString` + `UpdateChannel.selected()` — `stable` or `continuous`, the only two cases the enum defines. |

## Porcelain record shapes

Tab-separated, one record per line. From `Snapshot.parse`:

```
V  <vendor>  <installed 0|1>  <isolation>  <desktop>  <usage>  <label>
P  <name>    <desktopRunning 0|1>  <slots>                 # slots: "claude:active,codex:ok" or "-"
A  <active profile name>
```

`isolation` ∈ `env` | `swap` · `desktop` ∈ `clone` | `launch` | `none` · `usage` ∈ `oauth` | `none`.

Unrecognised tags are skipped rather than fatal — a newer CLI may emit tags this build
predates. Keep that property.

## `agents best` output

```
PROFILE         5H%    7D%  5H RESETS (UTC)    NOTE
Default        62.0   31.0  2026-09-18T18:14
Client           12.0    8.0  2026-09-18T21:40
Client            -      -  -                  stale-token
```

`note` values the panel must handle: `ok`, `no-token`, `stale-token`, `fetch-error`,
`no-usage-api`. Render the note's own wording rather than a generic failure — the CLI
already distinguishes "you never logged in" from "the token expired" from "the network
is down", and that distinction is exactly what tells the user which button to press.

`5H RESETS` is UTC, truncated to 16 characters (`YYYY-MM-DDTHH:MM`). Convert to the
user's local zone before display. The 7-day window has no `resets_at` in `usage_table` —
it reads `resets_at` off `five` only — so the 7d row's reset slot stays empty.

## Fetching — the one thing that must change

`menuNeedsUpdate(_:)` currently calls `snapshot()` synchronously on every open. That is
fine for `porcelain`, which is local and fast. It is **not** fine for `agents best`,
which spawns `/usr/bin/python3`, reads the keychain per profile, and makes one HTTPS
request per profile with a 10-second timeout. Called on the open path it will visibly
hang the popover, and worse on a slow network.

Required shape:

- Keep `porcelain` synchronous on open — it is the source of truth for structure, and
  the existing one-call-per-open cache (`cachedSnapshot`) is correct.
- Move quota to a background refresh with a short TTL. Render whatever is cached
  immediately; show the meters in a loading state only on first ever run.
- Refresh on: panel open (fire-and-forget, update in place when it lands), profile
  switch, and a low-frequency timer.
- Never block `popoverWillShow` on it.
- A failed refresh keeps the previous value and marks it stale rather than blanking it.

## Where the model lives

`Vendors.swift` says it plainly: every rule about what a profile is, which vendors exist,
how each isolates and which is active lives in `vendors.sh` and `agents`; the tray renders
what the CLI reports. The panel does not change that. It adds no new concept — it surfaces
`usage`, `slots` and `sessions`, all of which the CLI already computes. If the panel needs
something the CLI cannot answer, add it to the CLI, not to Swift.
