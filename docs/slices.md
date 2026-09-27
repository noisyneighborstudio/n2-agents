# Slice queue

This is the active integration queue. Integrate each verified improvement before
starting unrelated work. The older fleet queue remains deferred; reconcile that
branch with current main before resuming its implementation.

## Queue

1. **Verify provider-scoped readouts** (`integration-scoped-readouts`).
   Behavior: applicable provider restrictions and their observation age remain visible.
   Proof: canonical protocol fixtures and isolated package acceptance for selected models.
   Scope: split before implementation if the native-reader dependency inventory exceeds
   250 changed lines; no credential migration.

2. **Prepare one accepted stable promotion** (`integration-stable-candidate`).
   Behavior: one accepted improvement has a reviewable candidate with no unaccepted
   intervening changes. Proof: source SHA, exact-commit gates, continuous artifact
   digest and installed-behavior receipt; separate stable receipts after approval.
   Scope: prepare only; no merge, publish, install or credential changes without
   explicit authorization. No dependency on unrelated fleet completion.

## Noticed

- The tray shows a Codex `limit-reached` slot as usage unknown with no return
  time; the profile summary doesn't count it as out. The loop and CLI skip it.
- The Codex parser still sorts windows into two length classes, so two short
  windows overwrite each other, and it drops additional buckets and credits.
  Fold into `integration-scoped-readouts` or split before starting it.

- Reconciling PR #3 with main after the account-setup and logout hotfixes has
  conflicts in CI/gates, package configuration, the queue, onboarding and provider
  credential handling. Resolve and verify that combination before further fleet
  work. These conflicts do not block the independent usage fixes.

- The inherited full-suite quota fixture asserted eight rejections but failed once
  at scripts/test.sh:682 during freshness validation. The unchanged loop source
  passed in the prior slice. Retain the assertion; investigate a recurrence with
  fixture receipts rather than changing usage-display code to accommodate it.

- Fleet crash-accounting, archive safety, notifications and provider logout stay
  deferred on PR #3. They do not block independent measurement fixes. No dispatch
  release before archive proof; no unproven credential retirement.
- T3 adapter remains downstream of its actual profile contract, not unrelated
  migration completion. Resume must preserve the original account binding.
