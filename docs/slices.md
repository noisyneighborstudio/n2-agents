# Slice queue

This is the active integration queue, on a branch based on main at 0f6ef56.
The fleet branch remains a working integration branch; do not resume its older
queue while these independent deliveries are in progress.

## Queue

1. **Show unavailable usage consistently** (`integration-usage-freshness`).
   Behavior: failed/expired reads cannot show healthy capacity in summaries,
   provider rows or expanded details; retain dated history on command failure,
   but remove absent profiles after a successful authoritative refresh.
   Proof: injected-time production-model tests for row/command failure, expiry,
   repeated failure, recovery and removal; rendering guards and native build.
   Scope: UI freshness, no provider protocol or account migration.
   Budget: 250 changed lines; stop at 500.

2. **Prefer measured eligible capacity** (`integration-usage-ranking`).
   Behavior: automatic CLI/loop selection excludes failed/missing metered reads;
   no-API candidates are explicit fallback, below measured compatible candidates.
   Proof: measured zero and 80% used versus unknown, failed and no-API candidates;
   vary strength, busyness and vendor preferences; no measured candidate control.
   Scope: selection, no account changes or provider calls.
   Budget: 150 changed lines; stop at 300.

3. **Keep Codex window resets independent** (`integration-codex-windows`).
   Behavior: five-hour exhaustion cannot overwrite a measured weekly percentage.
   Proof: 100/30 selects only the short reset, weekly-only exhaustion and denial
   without windows remain unavailable rather than inventing fresh capacity.
   Scope: parser and consumers required for this behavior, no account changes.
   Budget: 200 changed lines; stop at 400.

## Noticed

- Codex window percentages/reset semantics are the next independent integration
  after these review fixes; retain global denial separately from window usage.
- Fleet crash-accounting, archive safety, notifications and provider logout stay
  deferred on PR #3. They do not block independent measurement fixes. No dispatch
  release before archive proof; no unproven credential retirement.
- T3 adapter remains downstream of its actual profile contract, not unrelated
  migration completion. Resume must preserve the original account binding.
