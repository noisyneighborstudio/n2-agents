# Slice queue

## Gates

Every push runs `.github/workflows/ci.yml` on macOS 26. Run the same gates locally:

- Formatting: `scripts/check.sh format` checks introduced whitespace errors against the previous commit or `N2_CHECK_BASE`.
- Lint: `scripts/check.sh lint` checks tracked Python syntax with compiler warnings as errors and shell entry-point syntax. It does not claim style or type analysis.
- Tests: `scripts/test.sh`.
- Smoke: `scripts/smoke.sh` runs the real CLI with throwaway profiles and a signed synthetic owner. It needs no provider credentials.

A slice is complete only after these commands pass locally and CI passes on its pushed commit. Use one commit with a `Slice: <slug>` trailer. Remove the completed queue entry in that commit. No merge or deployment.

## Queue

1. **Inspect account ownership in the native profile** (`native-ownership-status`). Behavior: the Codex profile detail offers Account ownership and displays the existing CLI status, account identity, and owner; failed reads replace stale success with unavailable. Proof: recorded real-CLI fixture through the production parser and rendered detail view; disposable native action fixture verifies the selected profile, retired/missing states, failure replacement, and responsive event-based loading; existing usage tests prove authentication state does not imply capacity. Scope: inspect and refresh status only; no login, credential refresh, registration, migration, or quota-policy changes. Follow `docs/audits/native-ownership-flow-spike.md`. Planned diff: 250 lines; stop at 500.

2. **Archive known local migration copies** (`migration-archive-local`). Behavior: an explicit exact-revision command archives known local credential files and retained credential-bearing sync-conflict payloads outside active/sync paths, preserving a private manifest and keeping migration pending; abandonment restores those bytes before legacy access. Proof: disposable real-CLI file/conflict round trip, interrupted archive and restore retries, stale revision and symlink rejection, no overwrite of intervening files, unchanged recovered bytes, and no secret bytes/fingerprints or retirement/completion claim in public status. Scope: known local filesystem copies only; Keychain, provider revocation, remote archival, activation, and completed ownership remain required later. Follow `docs/audits/migration-retirement-spike.md`. Planned diff: 300 lines; stop at 600.

3. **Cross-machine history spike** (`session-transfer-spike`). Knowledge: determine the minimum provider history needed to resume an owner-bound session on another machine. Proof: record an isolated two-home native resume experiment, its fixture and the required artifacts; turn the result into one implementation brief. Scope: recorded evidence only, no live credentials, deployment, or speculative transfer code.

## Noticed

- Existing test suite contains sleep-based checks. New tests must wait on observable events; convert old waits when their behavior enters a slice.
- Security review and live-provider acceptance remain outstanding in `docs/fleet-readiness.md`.

- Provider lifetime smoke cleanup raised `PermissionError` once at `os.killpg` after the lifetime assertions; the immediate isolated rerun passed. Investigate cleanup process-group lifetime if it recurs; do not suppress permission errors without evidence.
