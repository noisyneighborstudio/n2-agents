# Slice queue

## Gates

Every push runs `.github/workflows/ci.yml` on macOS 26. Run the same gates locally:

- Formatting: `scripts/check.sh format` checks introduced whitespace errors against the previous commit or `N2_CHECK_BASE`.
- Lint: `scripts/check.sh lint` checks tracked Python syntax with compiler warnings as errors and shell entry-point syntax. It does not claim style or type analysis.
- Tests: `scripts/test.sh`.
- Smoke: `scripts/smoke.sh` runs the real CLI with throwaway profiles and a signed synthetic owner. It needs no provider credentials.

A slice is complete only after these commands pass locally and CI passes on its pushed commit. Use one commit with a `Slice: <slug>` trailer. Remove the completed queue entry in that commit. No merge or deployment.

## Queue

1. **Route native sign-in through the configured account owner** (`native-owner-signin`). Behavior: the native sign-in action, including Fix and Configure, reads the selected profile's public route asynchronously, explains same-account owner sign-in, and launches `agents fleet auth login PROFILE --expected-revision REVISION` for a registered owner. Invalid/conflicting/pending/failed reads never fall back; explicitly unmanaged slots retain legacy login. Owner flows confirm even when the caller assumed a signed-out slot; cancellation launches nothing. Proof: native action/confirmation tests plus generated-command execution against disposable local and remote owner fixtures, including consent, stale revision and successful synthetic completion; verify the packaged confirmation view. Scope: use existing owner login, preserve old session grants, no automatic remote permission, account replacement or live login. Keep setup from using the rejected legacy command for an existing owner-managed slot. Whole brief and fixture: `docs/audits/native-signin-route-spike.md`. Planned diff: 300 lines; stop at 600.

2. **Establish Keychain retirement requirements** (`migration-keychain-retirement-spike`). Knowledge: identify the provider-supported operation and credential-store scope needed to retire a legacy Keychain login before owner activation. Proof: inspect provider source/documentation and exercise storage selection and logout against a disposable fake credential backend; record removal scope, copied-grant validity or uncertainty, and interruption/recovery requirements; replace the spike with one bounded implementation brief. Scope: no real Keychain access, credentials, login, revocation, or activation. Peer retirement, unmanaged-session evidence, fresh owner enrollment and verified completion remain required.

3. **Send saved sessions from the native browser** (`native-session-transfer`). Behavior: the native session browser offers an approved peer and explicit destination directory, invokes the saved-session send command, and displays its success or refusal. Proof: native action tests assert the exact thread/peer/path arguments and surfaced failure; an isolated packaged-app check shows the action and result. Scope: use the verified CLI transfer; no running-process migration or automatic account/grant changes. Planned diff: 300 lines; stop at 600.

## Noticed

- `vendor_authed` checks only local `auth.json` for Codex, so an owner-managed slot is reported signed out even when its owner grant is active. The native sign-in routing slice must not claim to fix this separate authentication-state reporting gap; queue a bounded owner-aware snapshot/setup-status proof after it.

- Existing test suite contains sleep-based checks. New tests must wait on observable events; convert old waits when their behavior enters a slice.
- Security review and live-provider acceptance remain outstanding in `docs/fleet-readiness.md`.

- The Ctrl-C exit timeout in CI 36269470567 remains unresolved. The unchanged full suite and 180 bounded local terminal checks passed. Preserve the assertion; a recurrence needs signal/exit receipts and process-state evidence before a repair. Evidence: `docs/audits/terminal-ci-failure-spike.md`.

- Provider lifetime smoke cleanup raised `PermissionError` once at `os.killpg` after the lifetime assertions; the immediate isolated rerun passed. Investigate cleanup process-group lifetime if it recurs; do not suppress permission errors without evidence.
