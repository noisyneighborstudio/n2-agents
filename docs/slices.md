# Slice queue

## Gates

Every push runs `.github/workflows/ci.yml` on macOS 26. Run the same gates locally:

- Formatting: `scripts/check.sh format` checks introduced whitespace errors against the previous commit or `N2_CHECK_BASE`.
- Lint: `scripts/check.sh lint` checks tracked Python syntax with compiler warnings as errors and shell entry-point syntax. It does not claim style or type analysis.
- Tests: `scripts/test.sh`.
- Smoke: `scripts/smoke.sh` runs the real CLI with throwaway profiles and a signed synthetic owner. It needs no provider credentials.

A slice is complete only after these commands pass locally and CI passes on its pushed commit. Use one commit with a `Slice: <slug>` trailer. Remove the completed queue entry in that commit. No merge or deployment.

## Queue

1. **Provider cleanup** (`provider-parent-cleanup`). Behavior: killing an RPC caller stops its provider and stubborn descendants. Proof: `python3 scripts/test-codex-rpc.py ParentLifetimeTests` after a real caller SIGKILL; existing protocol tests must still pass. Scope: provider process group only, no terminal frontend lifecycle or migration. Pending implementation is parked outside the checkout.
2. **Terminal cleanup** (`terminal-parent-cleanup`). Behavior: killing the owner bridge also stops its native frontend. Proof: a disposable PTY test kills the bridge and observes frontend exit through process completion. Scope: no protocol expansion or session migration.
3. **Ownership completion spike** (`ownership-completion-spike`). Knowledge: identify the next missing observable migration behavior from the existing acceptance checklist. Proof: run the existing isolated migration CLI tests and record the command, fixture result, and exact uncovered acceptance criterion; replace this entry with one bounded implementation slice. Scope: notes and recorded fixtures only; discard exploratory code. No real credentials, grant retirement, or live enrollment.

## Noticed

- Existing test suite contains sleep-based checks. New tests must wait on observable events; convert old waits when their behavior enters a slice.
- Security review and live-provider acceptance remain outstanding in `docs/fleet-readiness.md`.
- Cross-machine history transfer remains required; define its slice after local discovery and cleanup.
- Process-cleanup WIP is preserved in `/Users/sethwebster/Development/n2-fleet-qa-artifacts/parked-process-cleanup`. Its inherited-pipe regression needs to expect prompt EOF from the new supervisor; it is not verified or committed.
