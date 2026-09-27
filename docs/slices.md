# Slice queue

The active integration queue is on `dougbot/integration-usage-ranking`, based
on main through PRs #30, #31 and #32. Work on the entries below happens in the integration
checkout, not this fleet checkout. Its `docs/slices.md` is authoritative;
these entries mirror it at the time of this queue handoff.

The old fleet queue is deferred: Claude crash accounting, hostile archives,
notification acceptance and provider logout remain acceptance requirements in
docs/fleet-readiness.md. Do not restart those tasks ahead of independent delivery.
Unproven provider logout remains blocked on provider scope evidence, not retries.
The complete deferred briefs are retained in `ad27ac9:docs/slices.md`. In particular,
`loop-claude-crash-usage` still needs proof that loop `error_during_execution`
zero placeholders remain unknown. The dispatched Claude accounting fix does not
satisfy that requirement; retain successful measured-zero and ordinary-failure controls.

## Gates

Every push runs `.github/workflows/ci.yml` on macOS 26. Run the same gates locally:

- Formatting: `scripts/check.sh format` checks introduced whitespace errors against the previous commit or `N2_CHECK_BASE`.
- Lint: `scripts/check.sh lint` checks tracked Python syntax with compiler warnings as errors and shell entry-point syntax. It does not claim style or type analysis.
- Tests: `scripts/test.sh`.
- Smoke: `scripts/smoke.sh` runs the real CLI with throwaway profiles and a signed synthetic owner. It needs no provider credentials.

A slice is complete only after these commands pass locally and CI passes on its pushed commit. Use one commit with a `Slice: <slug>` trailer. Remove the completed queue entry in that commit. No merge or deployment.

## Queue

1. **Keep Codex window resets independent** (`integration-codex-windows`).
   Behavior: five-hour exhaustion cannot overwrite a measured weekly percentage.
   Proof: 100/30 selects only the short reset, weekly-only exhaustion and denial
   without windows remain unavailable rather than inventing fresh capacity.
   Scope: parser and consumers required for this behavior, no account changes.
   Budget: 200 changed lines; stop at 400.

2. **Verify provider-scoped readouts** (`integration-scoped-readouts`).
   Behavior: applicable provider restrictions and their observation age remain visible.
   Proof: canonical protocol fixtures and isolated package acceptance for selected models.
   Scope: split before implementation if the native-reader dependency inventory exceeds
   250 changed lines; no credential migration.

3. **Prepare one accepted stable promotion** (`integration-stable-candidate`).
   Behavior: one accepted improvement has a reviewable candidate with no unaccepted
   intervening changes. Proof: source SHA, exact-commit gates, continuous artifact
   digest and installed-behavior receipt; separate stable receipts after approval.
   Scope: prepare only; no merge, publish, install or credential changes without
   explicit authorization. No dependency on unrelated fleet completion.

## Noticed

- The inherited full-suite quota fixture asserted eight rejections but failed once
  at scripts/test.sh:682 during freshness validation. The unchanged loop source
  passed in the prior slice. Retain the assertion; investigate a recurrence with
  fixture receipts rather than changing usage-display code to accommodate it.

- Fleet crash-accounting, archive safety, notifications and provider logout stay
  deferred on PR #3. They do not block independent measurement fixes. No dispatch
  release before archive proof; no unproven credential retirement.
- T3 adapter remains downstream of its actual profile contract, not unrelated
  migration completion. Resume must preserve the original account binding.

- Claude fleet denials now recover by evidenced reset; an ordinary parent success cannot establish subagent or spending recovery. Scope-specific successful recovery evidence remains required before claiming complete allowance recovery. See `docs/fleet-readiness.md`.

- Existing test suite contains sleep-based checks. New tests must wait on observable events; convert old waits when their behavior enters a slice.

- The Ctrl-C exit timeout in CI 36269470567 remains unresolved. The unchanged full suite and 180 bounded local terminal checks passed. Preserve the assertion; a recurrence needs signal/exit receipts and process-state evidence before a repair. Evidence: `docs/audits/terminal-ci-failure-spike.md`.

- Default Claude path normalization remains unresolved after the bounded source-mapping spike. Reopen only with new authoritative module mapping; do not repeat the same binary search. See `docs/audits/claude-default-path-spike.md`.
