# Usage binding and attribution audit

Source inspected: `71f0ac8e8a18a47bdf634e077be37db960959960`.
This is an evidence audit, not whole-fleet acceptance. The accompanying
[observations](usage-binding-attribution-2026-09-27.json) contain sanitized reads
of existing journals and synthetic credential-store results. No provider poll,
login, refresh, key minting or credential migration was performed.

## Provider contracts

The [Codex app-server docs](https://learn.chatgpt.com/docs/app-server) distinguish
allowance windows from token activity. `rateLimitsByLimitId` carries multiple
metered buckets; `usedPercent` measures consumption, duration is in minutes, and
reset timestamps are seconds. Workspace credits and earned reset credits are
separate. `account/usage/read` is service activity, not a task receipt. The reader
preserves bucket windows and reached-limit restrictions; these fields cannot
prove which account an unrelated T3 process used.

[Claude authentication](https://code.claude.com/docs/en/authentication) gives
cloud providers, environment credentials and helpers precedence over subscription
login. Measuring the configured subscription does not establish the effective
credential in every project execution context. Current route checks reject
known conflicting sources, but all-binding precedence acceptance remains open.

[Claude cost tracking](https://code.claude.com/docs/en/agent-sdk/cost-tracking)
distinguishes main-agent `usage` from whole-tree `modelUsage`. The latter can
include restored session spend. N2's loop uses fresh `-p` invocations in
`loop/Slots.swift`, so its invocation-tree aggregation has that limited scope.
This audit does not establish resumed Claude task accounting or billing parity.

## Evidence matrix

| Requirement | Evidence inspected and rerun | Conclusion and next proof |
| --- | --- | --- |
| Codex allowance buckets and identity | 28 reader tests; native RPC account/rate-limit sequencing; retained September 26 live and rejection receipts | Structured reader and two live account receipts are proven. New physical-fleet capacity is not. Collect timestamped provider observations under the authorized lifecycle before calling fleet headroom current. |
| Claude measured identity | Reader fixtures validate same-bearer profile and usage reads, route conflicts and unavailable identity | Authenticated measurement is distinct from execution identity. Test effective launch precedence under project settings before claiming every binding matches. |
| Account-bound Codex task attribution | 12 runner tests, 34 RPC tests, bound agent-run journal proof, five binding tests | Verified account/session receipt checks, renewal, missing/duplicate/mismatched receipts and rerouted-model unknowns pass. Retained live turn reports 14,707 total tokens. This is not provider billing reconciliation. |
| Claude task token scope | `UsageAttribution.swift`, sole production caller `AgentRun.swift`, fresh-session arguments in `Slots.swift` | Per-model fresh invocation totals include subagents; fallback is main-agent only. Account remains unknown. Resumed Claude and external T3 runs are outside this proof. |
| Machine and account aggregation | 28 journal tests, including same-name isolation, task deduplication, mixed models and cross-profile verified restrictions | Unknown account routes stay separate. Missing counts remain unknown. Model buckets are not added again to aggregate totals. Thirty-day retained task data is not all-time provider consumption. |
| Signed fleet exchange | `sh scripts/test-usage-fleet.sh` passes real disposable signed peers | Replay preserves origin/time, all 8,106 restrictions publish across bounded pages, and pre-enrollment attribution/recovery survives enrollment. This is synthetic peer evidence, not current M4/M5 collection. |
| Cursor and Muse read failures | Synthetic security command returns 44 versus unexpected 36, empty disposable config | Both cases return `no-token`. This conflates missing credentials with an unreadable store. Next slice must preserve an unavailable status and prove that no capacity becomes eligible. The synthetic exit does not establish an OS-specific error mapping. |
| Other provider identity | `usage.py` collectors and default unknown identity | Grok, Muse and Cursor do not establish verified account equality. Grok billing can renew credentials; Muse's collector mints a key. Neither was invoked as a read-only audit. Unsupported quota remains unknown. |
| Current physical-fleet readings | Read-only SQLite on seth-agent; checked canonical M4/M5 roots plus M5 QA root | Local observations are about 17 hours old. Checked M4/M5 roots have no journal. Custom roots were not searched exhaustively. Current fleet headroom remains unproven. |

## What the current observations say

At 2026-09-27 01:51 UTC the local journal retained Codex Default at 2% used and
ExpoIO at 100%, with different verified account hashes. Their ages were 60,882
and 60,881 seconds. Those are historical observations, not available capacity.
The `Default` label alone cannot identify the M4 failure's account. Existing
incident evidence does not include a verified account receipt for that failure.

The journal audit used SQLite read-only mode and query-only connections. It read
up to 10,000 recent events and retained only the latest measurement per origin,
provider and profile. Absence here means absence at the checked journal path,
not proof that the machine had no app, alternate root or provider history.

## Reproduction and acceptance boundary

Focused commands completed successfully against the source commit:

- `python3 scripts/test-usage-reader.py -v`: 28 tests.
- `python3 scripts/test-usage-store.py -v`: 28 tests.
- `python3 scripts/test-codex-rpc.py -v`: 34 tests.
- `python3 scripts/test-codex-run.py -v`: 12 tests.
- `python3 scripts/test-fleet-auth-binding.py -v`: five tests.
- `sh scripts/test-bound-agent-run.sh`: receipt validation and journal outcomes.
- `sh scripts/test-usage-fleet.sh`: signed replication and enrollment continuity.

The JSON records the synthetic status observation, not a permanent regression
suite. The repair slice must add that regression before changing the collector.
No live-provider acceptance, independent security review, final packaging,
native notification acceptance or PR readiness checkbox is closed by this audit.
