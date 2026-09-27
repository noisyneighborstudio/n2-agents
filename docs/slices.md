# Slice queue

## Gates

Every push runs `.github/workflows/ci.yml` on macOS 26. Run the same gates locally:

- Formatting: `scripts/check.sh format` checks introduced whitespace errors against the previous commit or `N2_CHECK_BASE`.
- Lint: `scripts/check.sh lint` checks tracked Python syntax with compiler warnings as errors and shell entry-point syntax. It does not claim style or type analysis.
- Tests: `scripts/test.sh`.
- Smoke: `scripts/smoke.sh` runs the real CLI with throwaway profiles and a signed synthetic owner. It needs no provider credentials.

A slice is complete only after these commands pass locally and CI passes on its pushed commit. Use one commit with a `Slice: <slug>` trailer. Remove the completed queue entry in that commit. No merge or deployment.

## Queue

1. **Retain unknown shell task attribution** (`fleet-shell-task-attribution`). Behavior: shell dispatch retains explicit unknown provider usage without changing command/stdout behavior. Proof: signed disposable success/failure/interruption and spoofed provider JSON produce no guessed account/model/token counts. Scope: declared vendor remains a routing label only, no arbitrary stdout interpretation or live commands. Planned diff: 150 lines; stop at 300.

2. **Keep Claude loop crash usage unknown** (`loop-claude-crash-usage`). Behavior: a Claude loop result with `error_during_execution` cannot publish zero placeholders as measured usage; session/error text remain available. Proof: extend `tests/TaskUsageTests.swift` and loop journal regression for crash counters, with successful measured zero and ordinary failed-result totals as controls; `sh scripts/test-usage.sh` and full gates pass. Baseline synthetic parser proof already exits 1; fixture is `/private/tmp/n2-claude-crash-counter-proof.swift`. Scope: no new provider calls, changed quota policy or changes to the dispatched Claude adapter. Planned diff: 100 lines; stop at 200.

3. **Verify hostile archive refusal** (`fleet-hostile-archives`). Behavior: task admission, output delivery and result fetch reject archives that escape their destination, without changing outside files. Proof: signed disposable cases for absolute/parent traversal members, escaping symlink and hardlink targets, link-then-file ordering and an existing destination symlink; outside sentinels remain unchanged, ordinary archives still transfer, and a disabled guard makes the proof fail. Scope: no live peer data, general archive-library replacement or unrelated transport changes. If a discovered fix cannot fit, retain the failing fixture and split before implementation. Planned diff: 250 lines; stop at 500.

4. **Verify authorized native notification delivery** (`native-notification-delivery-acceptance`). Behavior: prove production notification submission and desktop delivery under an authorized disposable bundle. Proof: record authorization, submission and delivery receipts for completed/failed/disconnected notices, foreground and background, with visible banner evidence; preserve unavailable delivery explicitly. Scope: no real profiles, enrollment or production installation. Requires notification permission for the disposable bundle; the initial no-permission probe does not satisfy this acceptance. Planned retained diff: 150 lines; stop at 300.

5. **Record provider logout without claiming completed retirement** (`migration-provider-logout`). Behavior: an explicit revision-checked migration logout binds its intent and outcome to the original canonical CODEX_HOME, provider version and observed effective storage/backend; it keeps migration pending and distinguishes completed local cleanup from unconfirmed global revocation. Unknown scope or unsupported backend refuses before mutation. Once logout begins, abandonment cannot restore potentially revoked archives as a usable login; fresh sign-in is required. Proof: disposable provider/backend fixtures cover exact route and revision, unsupported scope, success despite unconfirmed revocation, partial deletion, interruption/retry and abandonment. Scope: provider-supported logout only, no custom Keychain deletion, real credential operations, peer completion or owner activation. Prerequisite unavailable in examined provider interfaces: establish a same-operation scope receipt before implementation. Explicit CLI overrides and same-process RPC do not supply it. Do not repeat those approaches; see `docs/audits/migration-logout-observation-spike.md`. Evidence: `docs/audits/migration-effective-config-spike.md`. Whole brief and source-level fixture: `docs/audits/migration-keychain-retirement-spike.md`. Planned diff: 300 lines; stop at 600.

## Noticed

- Claude fleet denials now recover by evidenced reset; an ordinary parent success cannot establish subagent or spending recovery. Scope-specific successful recovery evidence remains required before claiming complete allowance recovery. See `docs/fleet-readiness.md`.



- Existing test suite contains sleep-based checks. New tests must wait on observable events; convert old waits when their behavior enters a slice.

- The Ctrl-C exit timeout in CI 36269470567 remains unresolved. The unchanged full suite and 180 bounded local terminal checks passed. Preserve the assertion; a recurrence needs signal/exit receipts and process-state evidence before a repair. Evidence: `docs/audits/terminal-ci-failure-spike.md`.


- Default Claude path normalization remains unresolved after the bounded source-mapping spike. Reopen only with new authoritative module mapping; do not repeat the same binary search. See `docs/audits/claude-default-path-spike.md`.
