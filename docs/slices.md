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

1. **Independent adversarial and security review** (`fleet-security-review`).
   Behavior: reviewed findings are fixed or recorded with evidence.
   Proof: review report against the candidate SHA; fixes each carry their own proof.
   Scope: the merged fleet diff against main.

## Noticed

- CI's verify job takes about 24 of its 30 minutes. Split it or raise the limit
  before it starts timing out.

- The tray has no view of profiles held for review after joining; the CLI's
  `agents fleet sync review` / `share` are the only surface.

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
