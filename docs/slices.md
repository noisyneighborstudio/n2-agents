# Slice queue

## Gates

Every push runs `.github/workflows/ci.yml` on macOS 26. Run the same gates locally:

- Formatting: `scripts/check.sh format` checks introduced whitespace errors against the previous commit or `N2_CHECK_BASE`.
- Lint: `scripts/check.sh lint` checks tracked Python syntax with compiler warnings as errors and shell entry-point syntax. It does not claim style or type analysis.
- Tests: `scripts/test.sh`.
- Smoke: `scripts/smoke.sh` runs the real CLI with throwaway profiles and a signed synthetic owner. It needs no provider credentials.

A slice is complete only after these commands pass locally and CI passes on its pushed commit. Use one commit with a `Slice: <slug>` trailer. Remove the completed queue entry in that commit. No merge or deployment.

## Queue

1. **Send one saved owner-bound session to a peer** (`session-transfer`). Behavior: `agents fleet session send THREAD --peer PEER --cwd PATH` sends a stable bounded snapshot over the existing approved-peer signed carrier; the destination's session browser discovers it and resume retains the original account and selected model at the explicitly mapped directory. Proof: signed two-root transfer followed by real CLI discovery/resume; missing history, malformed/symlinked payload, wrong binding, conflicting destination and interrupted import are refused without a resumable partial session; revoked ownership never falls back. Scope: one saved native rollout, public binding and model selection only; no credentials, whole-home copying, running-process migration, divergent-history merge or live-provider acceptance. Use `docs/audits/session-transfer-spike.md` and its native fixture. Planned diff: 300 lines; stop at 600.

2. **Native account sign-in flow spike** (`native-account-signin-spike`). Knowledge: establish how the existing native Sign in again action routes an owner-managed Codex profile and what its confirmation must say. Proof: inspect the actual action/CLI path with disposable owner bindings, record local-owner and remote-owner outcomes, and replace this entry with one executable native-flow brief. Scope: read-only routing inspection and synthetic fixtures; no real sign-in, reset, credential refresh, or live owner changes.

3. **Establish Keychain retirement requirements** (`migration-keychain-retirement-spike`). Knowledge: identify the provider-supported operation and credential-store scope needed to retire a legacy Keychain login before owner activation. Proof: inspect provider source/documentation and exercise storage selection and logout against a disposable fake credential backend; record removal scope, copied-grant validity or uncertainty, and interruption/recovery requirements; replace the spike with one bounded implementation brief. Scope: no real Keychain access, credentials, login, revocation, or activation. Peer retirement, unmanaged-session evidence, fresh owner enrollment and verified completion remain required.

## Noticed

- Existing test suite contains sleep-based checks. New tests must wait on observable events; convert old waits when their behavior enters a slice.
- Security review and live-provider acceptance remain outstanding in `docs/fleet-readiness.md`.

- The Ctrl-C exit timeout in CI 36269470567 remains unresolved. The unchanged full suite and 180 bounded local terminal checks passed. Preserve the assertion; a recurrence needs signal/exit receipts and process-state evidence before a repair. Evidence: `docs/audits/terminal-ci-failure-spike.md`.

- Provider lifetime smoke cleanup raised `PermissionError` once at `os.killpg` after the lifetime assertions; the immediate isolated rerun passed. Investigate cleanup process-group lifetime if it recurs; do not suppress permission errors without evidence.
