# Slice queue

## Gates

Every push runs `.github/workflows/ci.yml` on macOS 26. Run the same gates locally:

- Formatting: `scripts/check.sh format` checks introduced whitespace errors against the previous commit or `N2_CHECK_BASE`.
- Lint: `scripts/check.sh lint` checks tracked Python syntax with compiler warnings as errors and shell entry-point syntax. It does not claim style or type analysis.
- Tests: `scripts/test.sh`.
- Smoke: `scripts/smoke.sh` runs the real CLI with throwaway profiles and a signed synthetic owner. It needs no provider credentials.

A slice is complete only after these commands pass locally and CI passes on its pushed commit. Use one commit with a `Slice: <slug>` trailer. Remove the completed queue entry in that commit. No merge or deployment.

## Queue

1. **Terminal cleanup** (`terminal-parent-cleanup`). Behavior: killing the owner bridge also stops its native frontend. Proof: a disposable PTY test kills the bridge and observes frontend exit through process completion. Scope: no protocol expansion or session migration.
2. **Ownership completion spike** (`ownership-completion-spike`). Knowledge: identify the next missing observable migration behavior from the existing acceptance checklist. Proof: run the existing isolated migration CLI tests and record the command, fixture result, and exact uncovered acceptance criterion; replace this entry with one bounded implementation slice. Scope: notes and recorded fixtures only; discard exploratory code. No real credentials, grant retirement, or live enrollment.

3. **Cross-machine history spike** (`session-transfer-spike`). Knowledge: determine the minimum provider history needed to resume an owner-bound session on another machine. Proof: record an isolated two-home native resume experiment, its fixture and the required artifacts; turn the result into one implementation brief. Scope: recorded evidence only, no live credentials, deployment, or speculative transfer code.

## Noticed

- Existing test suite contains sleep-based checks. New tests must wait on observable events; convert old waits when their behavior enters a slice.
- Security review and live-provider acceptance remain outstanding in `docs/fleet-readiness.md`.
