# Slice queue

## Gates

Every push runs `.github/workflows/ci.yml` on macOS 26. Run the same gates locally:

- Formatting: `scripts/check.sh format` checks introduced whitespace errors against the previous commit or `N2_CHECK_BASE`.
- Lint: `scripts/check.sh lint` checks tracked Python syntax with compiler warnings as errors and shell entry-point syntax. It does not claim style or type analysis.
- Tests: `scripts/test.sh`.
- Smoke: `scripts/smoke.sh` runs the real CLI with throwaway profiles and a signed synthetic owner. It needs no provider credentials.

A slice is complete only after these commands pass locally and CI passes on its pushed commit. Use one commit with a `Slice: <slug>` trailer. Remove the completed queue entry in that commit. No merge or deployment.

## Queue

1. **Verify authorized native notification delivery** (`native-notification-delivery-acceptance`). Behavior: prove production notification submission and desktop delivery under an authorized disposable bundle. Proof: record authorization, submission and delivery receipts for completed/failed/disconnected notices, foreground and background, with visible banner evidence; preserve unavailable delivery explicitly. Scope: no real profiles, enrollment or production installation. Requires notification permission for the disposable bundle; the initial no-permission probe does not satisfy this acceptance. Planned retained diff: 150 lines; stop at 300.

2. **Record provider logout without claiming completed retirement** (`migration-provider-logout`). Behavior: an explicit revision-checked migration logout binds its intent and outcome to the original canonical CODEX_HOME, provider version and observed effective storage/backend; it keeps migration pending and distinguishes completed local cleanup from unconfirmed global revocation. Unknown scope or unsupported backend refuses before mutation. Once logout begins, abandonment cannot restore potentially revoked archives as a usable login; fresh sign-in is required. Proof: disposable provider/backend fixtures cover exact route and revision, unsupported scope, success despite unconfirmed revocation, partial deletion, interruption/retry and abandonment. Scope: provider-supported logout only, no custom Keychain deletion, real credential operations, peer completion or owner activation. Prerequisite unavailable in examined provider interfaces: establish a same-operation scope receipt before implementation. Explicit CLI overrides and same-process RPC do not supply it. Do not repeat those approaches; see `docs/audits/migration-logout-observation-spike.md`. Evidence: `docs/audits/migration-effective-config-spike.md`. Whole brief and source-level fixture: `docs/audits/migration-keychain-retirement-spike.md`. Planned diff: 300 lines; stop at 600.

3. **Admit a task ID once under concurrent delivery** (`task-admission-race`). Behavior: two authenticated concurrent deliveries for the same task launch at most one command and preserve one valid task record. Proof: `python3 scripts/test-task-admission-race.py` uses signed fixture requests with distinct nonces and an event barrier at admission; old code must duplicate execution, fixed code must yield one launch plus a consistent duplicate reply. Include failed initialization and retry. Scope: task admission only, no provider jobs, real peers or scheduler redesign. Planned diff: 200 lines; stop at 400.

4. **Preserve disruptive-update consent across replication** (`tool-disruption-approval`). Behavior: removing a replicated tool's disruptive flag cannot reuse local approval to install during active work. Proof: `sh scripts/test-tool-disruption-approval.sh` approves an isolated disruptive installer, records active work, changes only classification/version via replication, and verifies bulk and single-tool paths refuse or defer until new consent. Old code must execute the synthetic marker; fixed code must preserve it absent. Scope: approval identity/local classification only, no live installers or tool-format redesign. Planned diff: 150 lines; stop at 300.

## Noticed


- Existing test suite contains sleep-based checks. New tests must wait on observable events; convert old waits when their behavior enters a slice.
- Security review and live-provider acceptance remain outstanding in `docs/fleet-readiness.md`.

- The Ctrl-C exit timeout in CI 36269470567 remains unresolved. The unchanged full suite and 180 bounded local terminal checks passed. Preserve the assertion; a recurrence needs signal/exit receipts and process-state evidence before a repair. Evidence: `docs/audits/terminal-ci-failure-spike.md`.

- Provider lifetime teardown was repaired after its third PermissionError recurrence. Both EOF assertions had already passed before an unnecessary group signal failed. The test now skips that signal only after both lifetime proofs; failure paths retain emergency cleanup. The new injected-EPERM regression failed against the old teardown and passes with the repair. All 34 RPC tests pass. The OS-level cause of EPERM remains unproven; no production signal handling changed. Prior diagnostic observations remain in `lifetime-cleanup-recurrence.json`.

- Default Claude path normalization remains unresolved after the bounded source-mapping spike. Reopen only with new authoritative module mapping; do not repeat the same binary search. See `docs/audits/claude-default-path-spike.md`.
