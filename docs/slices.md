# Slice queue

## Gates

Every push runs `.github/workflows/ci.yml` on macOS 26. Run the same gates locally:

- Formatting: `scripts/check.sh format` checks introduced whitespace errors against the previous commit or `N2_CHECK_BASE`.
- Lint: `scripts/check.sh lint` checks tracked Python syntax with compiler warnings as errors and shell entry-point syntax. It does not claim style or type analysis.
- Tests: `scripts/test.sh`.
- Smoke: `scripts/smoke.sh` runs the real CLI with throwaway profiles and a signed synthetic owner. It needs no provider credentials.

A slice is complete only after these commands pass locally and CI passes on its pushed commit. Use one commit with a `Slice: <slug>` trailer. Remove the completed queue entry in that commit. No merge or deployment.

## Queue

1. **Prepare a migration peer** (`migration-prepare-peer`). Behavior: `agents fleet auth migration-prepare Profile --peer PEER --expected-revision REVISION` installs the coordinator's exact pending barrier on an explicitly consenting peer through the signed fleet channel and reports its durable acknowledgement. Proof: two disposable approved peers with the same stable profile ID; deny before profile-scoped migration consent, then prepare and verify both CLI inventories, launch/sync refusal, unchanged credential bytes, idempotent retry, stale/conflicting migration refusal, wrong-recipient rejection, and unreachable peer left unacknowledged. The prepared peer cannot independently abandon the coordinator's barrier. Scope: consent, barrier, signed acknowledgement, and status only; no credential retirement, keychain access, grant activation, or completion claim. Use existing slot locks and stable profile identity. Reuse public fleet signatures for acknowledgements; do not invent grant IDs to fit the login protocol. Background and observed gap: `docs/audits/ownership-completion-spike.md`. Planned diff: 250 lines; stop at 500.

2. **Cross-machine history spike** (`session-transfer-spike`). Knowledge: determine the minimum provider history needed to resume an owner-bound session on another machine. Proof: record an isolated two-home native resume experiment, its fixture and the required artifacts; turn the result into one implementation brief. Scope: recorded evidence only, no live credentials, deployment, or speculative transfer code.

3. **Native ownership-flow spike** (`native-ownership-flow-spike`). Knowledge: identify the first missing native ownership action from the acceptance checklist. Proof: run existing native ownership parser/action tests, record the exact unsupported user flow, and replace this entry with one vertical implementation brief. Scope: notes and isolated fixtures only; no live enrollment, credential changes, or unrelated UI work.

## Noticed

- Existing test suite contains sleep-based checks. New tests must wait on observable events; convert old waits when their behavior enters a slice.
- Security review and live-provider acceptance remain outstanding in `docs/fleet-readiness.md`.
