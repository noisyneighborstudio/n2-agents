# Slice queue

## Gates

Every push runs `.github/workflows/ci.yml` on macOS 26. Run the same gates locally:

- Formatting: `scripts/check.sh format` checks introduced whitespace errors against the previous commit or `N2_CHECK_BASE`.
- Lint: `scripts/check.sh lint` checks tracked Python syntax with compiler warnings as errors and shell entry-point syntax. It does not claim style or type analysis.
- Tests: `scripts/test.sh`.
- Smoke: `scripts/smoke.sh` runs the real CLI with throwaway profiles and a signed synthetic owner. It needs no provider credentials.

A slice is complete only after these commands pass locally and CI passes on its pushed commit. Use one commit with a `Slice: <slug>` trailer. Remove the completed queue entry in that commit. No merge or deployment.

## Queue

1. **Recover interrupted native thread-record publication** (`session-record-recovery`). Behavior: an ordinary native thread start interrupted between publishing its immutable binding and removing the temporary link can recover without permanently hiding the session. Proof: inject interruption at the actual `Sessions.remember` link boundary, retry, and discover/resume the original binding; conflicting bindings still refuse. Scope: the existing local record publisher only. The transfer importer now handles its equivalent boundary. Planned diff: 200 lines; stop at 400.

2. **Native account sign-in flow spike** (`native-account-signin-spike`). Knowledge: establish how the existing native Sign in again action routes an owner-managed Codex profile and what its confirmation must say. Proof: inspect the actual action/CLI path with disposable owner bindings, record local-owner and remote-owner outcomes, and replace this entry with one executable native-flow brief. Scope: read-only routing inspection and synthetic fixtures; no real sign-in, reset, credential refresh, or live owner changes.

3. **Establish Keychain retirement requirements** (`migration-keychain-retirement-spike`). Knowledge: identify the provider-supported operation and credential-store scope needed to retire a legacy Keychain login before owner activation. Proof: inspect provider source/documentation and exercise storage selection and logout against a disposable fake credential backend; record removal scope, copied-grant validity or uncertainty, and interruption/recovery requirements; replace the spike with one bounded implementation brief. Scope: no real Keychain access, credentials, login, revocation, or activation. Peer retirement, unmanaged-session evidence, fresh owner enrollment and verified completion remain required.

4. **Send saved sessions from the native browser** (`native-session-transfer`). Behavior: the native session browser offers an approved peer and explicit destination directory, invokes the saved-session send command, and displays its success or refusal. Proof: native action tests assert the exact thread/peer/path arguments and surfaced failure; an isolated packaged-app check shows the action and result. Scope: use the verified CLI transfer; no running-process migration or automatic account/grant changes. Planned diff: 300 lines; stop at 600.

## Noticed

- Existing test suite contains sleep-based checks. New tests must wait on observable events; convert old waits when their behavior enters a slice.
- Security review and live-provider acceptance remain outstanding in `docs/fleet-readiness.md`.

- The Ctrl-C exit timeout in CI 36269470567 remains unresolved. The unchanged full suite and 180 bounded local terminal checks passed. Preserve the assertion; a recurrence needs signal/exit receipts and process-state evidence before a repair. Evidence: `docs/audits/terminal-ci-failure-spike.md`.

- Provider lifetime smoke cleanup raised `PermissionError` once at `os.killpg` after the lifetime assertions; the immediate isolated rerun passed. Investigate cleanup process-group lifetime if it recurs; do not suppress permission errors without evidence.
