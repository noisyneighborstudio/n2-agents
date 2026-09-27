# Slice queue

## Gates

Every push runs `.github/workflows/ci.yml` on macOS 26. Run the same gates locally:

- Formatting: `scripts/check.sh format` checks introduced whitespace errors against the previous commit or `N2_CHECK_BASE`.
- Lint: `scripts/check.sh lint` checks tracked Python syntax with compiler warnings as errors and shell entry-point syntax. It does not claim style or type analysis.
- Tests: `scripts/test.sh`.
- Smoke: `scripts/smoke.sh` runs the real CLI with throwaway profiles and a signed synthetic owner. It needs no provider credentials.

A slice is complete only after these commands pass locally and CI passes on its pushed commit. Use one commit with a `Slice: <slug>` trailer. Remove the completed queue entry in that commit. No merge or deployment.

## Queue

1. **Distinguish unreadable credential stores from missing logins** (`usage-credential-store-status`). Behavior: Cursor and Muse preserve a credential-store-unavailable result for unexpected store failures; only an absent item is no-token. Neither case advertises capacity. Proof: isolated collector fixtures exercise absent item, unexpected nonzero exit, command failure and valid token; reader-to-selection proof confirms unavailable rows are ineligible. Scope: no real Keychain calls, provider requests or changes to successful usage parsing. Evidence: `docs/audits/usage-binding-attribution-2026-09-27.json`. Planned diff: 150 lines; stop at 300.

2. **Record provider logout without claiming completed retirement** (`migration-provider-logout`). Behavior: an explicit revision-checked migration logout binds its intent and outcome to the original canonical CODEX_HOME, provider version and observed effective storage/backend; it keeps migration pending and distinguishes completed local cleanup from unconfirmed global revocation. Unknown scope or unsupported backend refuses before mutation. Once logout begins, abandonment cannot restore potentially revoked archives as a usable login; fresh sign-in is required. Proof: disposable provider/backend fixtures cover exact route and revision, unsupported scope, success despite unconfirmed revocation, partial deletion, interruption/retry and abandonment. Scope: provider-supported logout only, no custom Keychain deletion, real credential operations, peer completion or owner activation. Prerequisite: establish provider-supported observation equivalent to the logout operation; config/read plus features list has not proved that equivalence, and Bedrock cleanup needs explicit handling. Evidence: `docs/audits/migration-effective-config-spike.md`. Whole brief and source-level fixture: `docs/audits/migration-keychain-retirement-spike.md`. Planned diff: 300 lines; stop at 600.

3. **Audit native refresh and notification acceptance** (`native-refresh-notification-acceptance`). Knowledge: establish visible behavior after failed fleet reads and recovery, and distinguish delivered desktop banners from in-panel activity. Proof: use disposable native state and recorded event receipts to exercise failed reads, retained/stale display and recovery; record which banner and physical-peer checks have direct evidence and which remain unavailable. Scope: evidence only; do not convert the source-read stale-display suspicion into a defect claim without reproduction, and do not treat component renders as full packaged or live-peer acceptance. Keep final packaging/regression, independent security review, live-provider acceptance and PR readiness explicit in `docs/fleet-readiness.md`.

## Noticed

- Existing test suite contains sleep-based checks. New tests must wait on observable events; convert old waits when their behavior enters a slice.
- Security review and live-provider acceptance remain outstanding in `docs/fleet-readiness.md`.

- The Ctrl-C exit timeout in CI 36269470567 remains unresolved. The unchanged full suite and 180 bounded local terminal checks passed. Preserve the assertion; a recurrence needs signal/exit receipts and process-state evidence before a repair. Evidence: `docs/audits/terminal-ci-failure-spike.md`.

- Provider lifetime teardown was repaired after its third PermissionError recurrence. Both EOF assertions had already passed before an unnecessary group signal failed. The test now skips that signal only after both lifetime proofs; failure paths retain emergency cleanup. The new injected-EPERM regression failed against the old teardown and passes with the repair. All 34 RPC tests pass. The OS-level cause of EPERM remains unproven; no production signal handling changed. Prior diagnostic observations remain in `lifetime-cleanup-recurrence.json`.
