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

1. **Walk the fleet flows in the native UI** (`fleet-native-flows`).
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

- Fleet panel reads have no timeout. A newer read correctly replaces an older
  one, but a CLI read that hangs keeps its process, so a hang stacks one per
  poll. Bound each read (kill after a limit) and report it as a read error.

- Any same-user process can open `n2agents://reonboard-done` (or `login-done`)
  and make the app treat a running account reset as finished.

- CI's verify job takes about 24 of its 30 minutes. Split it or raise the limit
  before it starts timing out.

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
