# Slice queue

## Gates

Every push runs `.github/workflows/ci.yml` on macOS 26. Run the same gates locally:

- Formatting: `scripts/check.sh format` checks introduced whitespace errors against the previous commit or `N2_CHECK_BASE`.
- Lint: `scripts/check.sh lint` checks tracked Python syntax with compiler warnings as errors and shell entry-point syntax. It does not claim style or type analysis.
- Tests: `scripts/test.sh`.
- Smoke: `scripts/smoke.sh` runs the real CLI with throwaway profiles and a signed synthetic owner. It needs no provider credentials.

A slice is complete only after these commands pass locally and CI passes on its pushed commit. Use one commit with a `Slice: <slug>` trailer. Remove the completed queue entry in that commit. No merge or deployment.

## Queue

1. **Send saved sessions from the native browser** (`native-session-transfer`). Behavior: the native session browser offers an approved peer and explicit destination directory, invokes the saved-session send command, and displays its success or refusal. Proof: native action tests assert the exact thread/peer/path arguments and surfaced failure; an isolated packaged-app check shows the action and result. Scope: use the verified CLI transfer; no running-process migration or automatic account/grant changes. Planned diff: 300 lines; stop at 600.

2. **Record provider logout without claiming completed retirement** (`migration-provider-logout`). Behavior: an explicit revision-checked migration logout binds its intent and outcome to the original canonical CODEX_HOME, provider version and observed effective storage/backend; it keeps migration pending and distinguishes completed local cleanup from unconfirmed global revocation. Unknown scope or unsupported backend refuses before mutation. Once logout begins, abandonment cannot restore potentially revoked archives as a usable login; fresh sign-in is required. Proof: disposable provider/backend fixtures cover exact route and revision, unsupported scope, success despite unconfirmed revocation, partial deletion, interruption/retry and abandonment. Scope: provider-supported logout only, no custom Keychain deletion, real credential operations, peer completion or owner activation. Prerequisite: establish provider-supported observation equivalent to the logout operation; config/read plus features list has not proved that equivalence, and Bedrock cleanup needs explicit handling. Evidence: `docs/audits/migration-effective-config-spike.md`. Whole brief and source-level fixture: `docs/audits/migration-keychain-retirement-spike.md`. Planned diff: 300 lines; stop at 600.

3. **Verify native fleet outcomes and reconnection** (`native-fleet-outcomes-spike`). Knowledge: establish which existing native flows visibly report task completion, failure, disconnection and reconciliation. Proof: drive disposable fleet fixtures through the real native model/actions, record visible outcomes and identify one bounded missing behavior with its acceptance command. Scope: no real enrollment, provider operations, deployment or new notification framework. Keep final GUI acceptance explicit in `docs/fleet-readiness.md`.

## Noticed

- Existing test suite contains sleep-based checks. New tests must wait on observable events; convert old waits when their behavior enters a slice.
- Security review and live-provider acceptance remain outstanding in `docs/fleet-readiness.md`.

- The Ctrl-C exit timeout in CI 36269470567 remains unresolved. The unchanged full suite and 180 bounded local terminal checks passed. Preserve the assertion; a recurrence needs signal/exit receipts and process-state evidence before a repair. Evidence: `docs/audits/terminal-ci-failure-spike.md`.

- Provider lifetime cleanup `PermissionError` recurred at `scripts/test-codex-rpc.py:607` after both provider-lifetime EOF assertions during owner-auth-status smoke; full regression had passed. A bounded diagnostic spike recorded ten disposable runs: every cleanup group was already absent and killpg returned ESRCH, so the permission-error cause remains unproven. Raw process-group observations are retained in the QA artifact `lifetime-cleanup-recurrence.json`. No error was suppressed and no cleanup code changed. A stable cleanup proof remains required if it recurs again.
