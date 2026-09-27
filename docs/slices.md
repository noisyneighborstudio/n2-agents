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

2. **Verify Claude Keychain account selection** (`claude-keychain-selector-spike`). Knowledge: establish the provider's account selector and storage-path normalization in N2's measured route. Proof: pinned installed-provider functions and synthetic duplicate-service/account plus decomposed-path fixtures; compare N2's actual command arguments and record uncertainty before repair. Scope: no real Keychain, credentials, provider requests or alternate authentication backend. Planned retained diff: 100 lines; stop at 200.

3. **Record provider logout without claiming completed retirement** (`migration-provider-logout`). Behavior: an explicit revision-checked migration logout binds its intent and outcome to the original canonical CODEX_HOME, provider version and observed effective storage/backend; it keeps migration pending and distinguishes completed local cleanup from unconfirmed global revocation. Unknown scope or unsupported backend refuses before mutation. Once logout begins, abandonment cannot restore potentially revoked archives as a usable login; fresh sign-in is required. Proof: disposable provider/backend fixtures cover exact route and revision, unsupported scope, success despite unconfirmed revocation, partial deletion, interruption/retry and abandonment. Scope: provider-supported logout only, no custom Keychain deletion, real credential operations, peer completion or owner activation. Prerequisite unavailable in examined provider interfaces: establish a same-operation scope receipt before implementation. Explicit CLI overrides and same-process RPC do not supply it. Do not repeat those approaches; see `docs/audits/migration-logout-observation-spike.md`. Evidence: `docs/audits/migration-effective-config-spike.md`. Whole brief and source-level fixture: `docs/audits/migration-keychain-retirement-spike.md`. Planned diff: 300 lines; stop at 600.

## Noticed

- Physical-peer reconciliation remains open; model tests and component renders do not prove it. Keep this in final native acceptance, as recorded in `docs/audits/native-refresh-acceptance.md`.

- Existing test suite contains sleep-based checks. New tests must wait on observable events; convert old waits when their behavior enters a slice.
- Security review and live-provider acceptance remain outstanding in `docs/fleet-readiness.md`.

- The Ctrl-C exit timeout in CI 36269470567 remains unresolved. The unchanged full suite and 180 bounded local terminal checks passed. Preserve the assertion; a recurrence needs signal/exit receipts and process-state evidence before a repair. Evidence: `docs/audits/terminal-ci-failure-spike.md`.

- Provider lifetime teardown was repaired after its third PermissionError recurrence. Both EOF assertions had already passed before an unnecessary group signal failed. The test now skips that signal only after both lifetime proofs; failure paths retain emergency cleanup. The new injected-EPERM regression failed against the old teardown and passes with the repair. All 34 RPC tests pass. The OS-level cause of EPERM remains unproven; no production signal handling changed. Prior diagnostic observations remain in `lifetime-cleanup-recurrence.json`.

- Claude nonzero-exit fallback, malformed data and cached credential precedence remain unverified beyond the recorded primary-object rule. Queue a bounded audit after account-selector evidence; do not infer universal behavior from one accessor.
