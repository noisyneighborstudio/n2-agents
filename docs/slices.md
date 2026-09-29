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

The menu bar redesign runs first, in the order of `docs/tray-redesign/08-slices.md`.
Every tray slice's proof includes `scripts/panel-snapshot.sh` renders in light
and dark, and `tray/build.sh`.

1. **Configure page** (`configure-page`).
   Behavior: Account / Launch / Files groups with Reveal and Copy icon
   buttons; Copy shows a checkmark and announces "Copied"; Sign out confirms.
   Proof: a test that copy puts the exact path or command on the pasteboard; snapshots.
   Scope: no new CLI verbs.

2. **Suggestion and Switch** (`suggestion-and-switch`).
   Behavior: an out or low slot's page shows "{Provider} has room" per
   `docs/tray-redesign/03-states.md`; Switch pushes the candidate's page with a glyph flight.
   Proof: unit tests on the picker (same profile first; never unmetered, failed,
   stale or signed out; nil when nothing qualifies); Switch never rebinds an account.
   Scope: panel only; toasts come later.

3. **Toast tier ladder** (`toast-tier-ladder`).
   Behavior: usage toasts announce at 50 / 25 / 10 / out, once per tier
   entered, only the worst on a multi-tier jump, in the new card (one toast).
   Proof: unit tests for enter, repeat, recover, re-enter and jump; the pace
   sentence is omitted when the window duration or reset is missing.
   Scope: a single toast; stacking comes after.

4. **Walk the fleet flows in the native UI** (`fleet-native-flows`).
   Behavior: from the QA app, pair two disposable peers, sync (with a held
   profile shared from Fleet settings), send work, show its result and revoke.
   Proof: packaged acceptance driven through accessibility events with
   disposable homes; each step asserts CLI state, and one negative control
   per step fails.
   Scope: disposable peers only; no live installation or real machines.

Blocked on authorization:
- Per-provider sign-in lifecycle evidence needs live provider accounts
  (readiness: "provider-specific authentication lifecycle").

## Noticed

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
