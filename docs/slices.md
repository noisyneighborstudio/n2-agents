# Slice queue

This is the fleet queue for PR #3, now merged with main through a9221bf. Integrate
main into this branch as each main change lands. Fleet readiness requirements are
in `docs/fleet-readiness.md`; the deferred fleet briefs are in `ad27ac9:docs/slices.md`.
No merge to main, publication, installation or machine enrollment without explicit
authorization.

## Gates

Every push runs `.github/workflows/ci.yml`, which runs `scripts/verify.sh`: format,
lint, `scripts/test.sh` and `scripts/smoke.sh`, in that order, and a parallel job
runs `scripts/test-fleet.sh`. Run both locally first.
A slice is complete only after these pass locally and CI passes on its pushed
commit. One commit with a `Slice: <slug>` trailer; remove the entry in that commit.

## Queue

The whole-popover pass (`docs/tray-redesign/12-whole-popover.md`) runs first.
Each slice's proof includes `scripts/panel-snapshot.sh` renders in light and
dark, and `tray/build.sh`.

1. **Recent sessions** (`recent-sessions`).
   Behavior: Recent (two newest) under This Machine; filtered to the profile
   on its page and to profile + lab on the Provider page; the sessions window
   filters by profile and lab; Send Session is a pushed page, not an alert.
   Proof: snapshots; a test of the filters.
   Scope: session transfer rules unchanged.

2. **Other Macs and the Machine page** (`other-macs`).
   Behavior: Other Macs rows (reach, task summary) push a Machine page with
   identity, transport, its tasks and recent activity, Check In and Remove;
   a Mac waiting for approval, a sync conflict and a task not answering are
   banners on root.
   Proof: snapshots over a fixture fleet; the native-ui wiring checks.
   Scope: peer profiles stay off root (Q1, Q8).

3. **Tasks and the Task page** (`tasks-page`).
   Behavior: Root › Tasks (three rows, status shape, "Send Work…" link) pushes
   a Task page: hero, ranked actions, timeline, diagnostics.
   Proof: snapshots per task state.

4. **Send Work page** (`send-work-page`).
   Behavior: the composer is a pushed page whose draft lives on the model, and
   it shows the CLI's plan before Send.
   Proof: a test that the draft survives the panel closing; snapshots.

5. **Settings › Fleet** (`settings-fleet`).
   Behavior: Sync & Sharing (with exceptions and conflicts), pairing (Create
   identity, Add a Mac), managed tools and the full Activity feed live in
   Settings; the popover no longer manages.
   Proof: the settings probe; snapshots.

6. **Walk the fleet flows in the native UI** (`fleet-native-flows`).
   Behavior: from the QA app, pair two disposable peers, sync (with a held
   profile shared from Fleet settings), send work, show its result and revoke.
   Proof: packaged acceptance driven through accessibility events with
   disposable homes; each step asserts CLI state, and one negative control
   per step fails.
   Scope: disposable peers only; no live installation or real machines.

Blocked on a decision:
- `remote-machines` (docs/tray-redesign/08-slices.md S9): peer machines as Fleet
  sections needs a CLI source for profiles held on peers (open question Q1).

Blocked on authorization:
- Per-provider sign-in lifecycle evidence needs live provider accounts
  (readiness: "provider-specific authentication lifecycle").

## Noticed

- The menu bar icon still gauges the lowest measured slot across every
  profile; the redesign wants the worst slot of the active profile in the
  status inks (docs/tray-redesign/03-states.md). No slice owns it yet.

- Arrow keys don't yet move between Fleet cards or Profile rows (Tab and
  Return do). docs/tray-redesign/02-screens.md asks for it.

- Open next best can still pick an unmetered slot when nothing metered has
  room: it mirrors the CLI's rotation. The redesign's acceptance list says it
  never should; that is a CLI policy change first.

- Toasts ship without "Notify when back" (open question Q7) and without a
  "Recent warnings" list (Q5). Add them once answered.

- Configure has no "Sign out of {Provider}": the CLI has no per-slot sign-out,
  and provider logout is deferred (below). Add the row with that verb.

- Live proof of fleet-gui-session-exec is still owed: after release, dispatch
  a one-word Claude prompt task between two enrolled Macs over ssh and show
  "ok" (it answered "Not logged in" before). Needs two Macs on the new build.

- test-fleet.sh's two lock-race loops (section 39, about 45s) did not catch
  their bugs when reintroduced on the Mac mini: 0 of 25 trials with the steal
  marker replaced by delete-on-sight, 0 of 8 with the grace reset removed.
  Replace them with deterministic interleavings, or delete them.

- Any same-user process can open `n2agents://reonboard-done` (or `login-done`)
  and make the app treat a running account reset as finished.

- test-fleet-auth-manage.py's SIGINT cancel case allows 5s for exit and failed
  once with three test groups running on one Mac; it passes alone. Runners share
  each Mac, so capture exit receipts if it recurs in CI.

- The inherited full-suite quota fixture fails intermittently (main saw it at
  scripts/test.sh:682 and :685). Suspect: tests/fake-loop-agent.sh decrements
  worker-quota-<profile> without a lock, so concurrent chunks on one slot can both
  fail while the counter drops once. Keep the assertion; capture turns on failure.

- Codex setup sign-in runs fleet's owner-aware plan in a terminal; other labs use
  main's in-app session. In-app Codex sign-in needs the plan resolved before the
  session starts.

- Fleet crash-accounting, archive safety, notifications and provider logout stay
  deferred. No dispatch release before archive proof; no unproven credential retirement.
- T3 adapter remains downstream of its actual profile contract. Resume must
  preserve the original account binding.

- Claude fleet denials now recover by evidenced reset; an ordinary parent success cannot establish subagent or spending recovery. Scope-specific successful recovery evidence remains required before claiming complete allowance recovery. See `docs/fleet-readiness.md`.

- Existing test suite contains sleep-based checks. New tests must wait on observable events; convert old waits when their behavior enters a slice.

- The Ctrl-C exit timeout in CI 36269470567 remains unresolved. The unchanged full suite and 180 bounded local terminal checks passed. Preserve the assertion; a recurrence needs signal/exit receipts and process-state evidence before a repair. Evidence: `docs/audits/terminal-ci-failure-spike.md`.

- Default Claude path normalization remains unresolved after the bounded source-mapping spike. Reopen only with new authoritative module mapping; do not repeat the same binary search. See `docs/audits/claude-default-path-spike.md`.
