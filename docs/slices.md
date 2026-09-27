# Slice queue

This is the active integration queue, on a branch based on main at 0f6ef56.
The fleet branch remains a working integration branch; do not resume its older
queue while these independent deliveries are in progress.

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
