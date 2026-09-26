# Usage measurements

`agents best` reads provider allowance measurements for the configured profiles.
Percentages are used, not remaining. The 95% selection cutoff is an N2 safety
reserve, not a provider-defined exhaustion threshold.

`agents best --json` emits one JSON object per profile, one per line. Use
`--vendor codex` or another provider to narrow the output. Schema version 1
includes provider, profile, observation time, source, status, identity evidence,
limit windows, restrictions, credit information and the legacy display columns.
Each poll is also retained in a local usage journal, including failures.

Each structured window retains its scope, duration in seconds, percentage and
provider reset value. Reset values are Unix seconds or provider ISO timestamps.
The two legacy columns cannot describe all buckets. A short window with a
different duration is not relabeled as five hours. Provider rejections remain
restrictions even when no percentage window is present.

Codex measurements use `codex app-server` with an explicit `CODEX_HOME`, then
`account/read` and `account/rateLimits/read`. This uses the CLI's configured
credential store and retains the multi-bucket response. No task, login, logout,
credit purchase or earned-reset consumption is requested. An API-key account
has no subscription allowance measurement. A missing account is signed out;
failed reads remain unknown. The existing `N2_CODEX_USAGE_URL` override is kept
for controlled endpoint fixtures and uses file authentication.

Native account information may identify a login without identifying its quota
workspace. The structured identity reports `login-only` with a hashed login in
that case. It must not be treated as a verified workspace/account ID or used to
combine allowances from different workspaces.

Claude measurements use the Keychain entry for the literal profile path that
`agents run` supplies as `CLAUDE_CONFIG_DIR`, with the credentials-file fallback
when that entry is absent. They do not search other profile paths or choose the
token with the latest expiry. Locked or inaccessible credential storage is a
separate status from signed out. Direct credential overrides are reported rather
than using a different account's stored token to measure the requested profile.
This routing change is covered by synthetic tests; it does not establish live
Claude account identity on every machine.

Claude's model-specific weekly windows and overage/spend information remain in
the structured output. Disabled overage alone does not block included allowance.
A model-specific window reaching N2's reserve is marked restricted for generic
selection until a model-aware selector can choose an unaffected model.

The tray stops advertising measurements after 15 minutes or a failed refresh.
The last observation's timestamp remains attached when a refresh fails. Missing
percentages remain unknown. Profile and menu-bar summaries warn about the most
constrained measured allowance; independent account/provider allowances are not
averaged into a pool usable by one task. The next-agent action selects an eligible
slot separately.

## Verification and remaining work

The reader tests cover native JSON-RPC sequencing and profile pinning with a
synthetic process, multiple buckets, arbitrary durations, model-specific limits,
rejection without windows, overage semantics, credential routing and numeric
validation. A live read on September 25 matched Default's 72% weekly use and
ExpoIO's exhausted weekly limit. This validates those Codex observations only.

Account/workspace verification, verified account attribution of execution failures, application
of rejections to scheduling, and task token attribution remain tracked in
[fleet readiness](fleet-readiness.md). Grok, Muse and Cursor still use their
existing collectors; their limitations have not been resolved by this change.

## Primary references

- [Codex app-server authentication and rate limits](https://learn.chatgpt.com/docs/app-server)
- [Claude Code authentication and credential storage](https://code.claude.com/docs/en/authentication)
- [Claude Code usage and failed-read behavior](https://code.claude.com/docs/en/costs)

## Observation history

`agents usage history` returns up to 1,000 recent journal events as JSON. Events
retain their originating machine, provider/profile binding, observation time,
identity evidence, limit buckets and status. A failed poll creates a new failure
event without replacing the preceding successful measurement. Local storage is
`<N2 root>/.usage/events.sqlite`, with owner-only permissions and 30-day retention.

Enrolled peers exchange their own observations during background sync ticks.
The receiving peer checks the authenticated origin and event digest, rejects
malformed batches, and deduplicates replays without renewing their timestamps.
A peer does not re-export somebody else's observations under its own identity.
Matching profile names on different machines remain separate bindings.

The bounded `agents usage record --provider <provider> --profile <profile>
--kind quota-rejected` interface accepts structured JSON on stdin. It rejects
unknown fields, including nested credential fields. The loop records quota rejections and successful turns automatically, with its
local task reference and requested Claude model where known. Verified account attribution of loop outcomes remains open; token and provider-session fields are populated when the provider reports them. Recorded
rejections do not yet change selection outside the loop’s existing cooldowns. An unknown account identity remains
unknown; recording or replicating an observation does not verify it.

## Provider identity evidence

When Codex returns `account/read.workspaceRouting`, N2 retains a hash binding
of the backend origin, selected `chatgptAccountId`, and CLI-reported login. Users
in the same workspace remain separate. Missing routing remains `login-only`;
N2 never substitutes a profile label for a workspace. The local Codex 0.155.1
probe on September 25 returned login-only for both measured profiles. Default
reported 75% weekly use and ExpoIO 100%, so this host has not established live
workspace verification through that field.

Claude identity comes from `claude auth status --json` with the same literal
`CLAUDE_CONFIG_DIR` used for launch and measurement. First-party Claude.ai status
with both login and organization produces an account-binding hash; API-key or
alternate-provider status prevents measuring a different subscription account.
Unavailable or incomplete CLI identity remains explicit. This identifies the
provider CLI's selected account; it does not establish credential portability or
refresh safety across machines.

References: [Codex selected workspace routing](https://github.com/openai/codex/blob/de9e78e3e7caed0fdd75d20ae617faa646dfef3c/codex-rs/app-server/README.md#selected-workspace-routing)
and [Claude authentication status](https://code.claude.com/docs/en/cli-reference).
Synthetic tests cover routing retention, different users/workspaces, absent
routing, literal Claude paths and alternate authentication modes.

Identity and allowance reads are checked for a consistent snapshot. Claude
credentials must remain unchanged across the CLI identity lookup; Codex account
and routing must match before and after the rate-limit read. A changed sample is
unavailable, rather than attributed to either account. The reference above is
pinned to the inspected upstream revision. Local Claude is 2.1.283.

Quota failures no longer consume the planner's four failed-plan attempts. The
integration regression exhausts six profiles before reaching a healthy planner,
and completes the resulting loop.

## Task token attribution

Loop invocations request structured Claude output and Codex JSON Lines. N2
extracts the final agent result for the existing loop protocol and retains the
reported provider-session ID and token counts separately. It records successful,
quota-rejected and other failed turns. Unknown fields remain null.

Claude `modelUsage` supplies whole-tree counts, including subagents, and remains
split by model in history. A top-level `usage` fallback is labeled `main-agent`.
Mixed-model totals have no invented single model; the requested alias is a
separate field. These loop calls start fresh sessions. Resumed-session totals
need a baseline before they can represent new work, so these parsers must not
be used to sum resumed Claude conversations without that accounting.

Codex cached input is a subset of input and is not added again. Claude input
combines uncached, cache-read and cache-creation categories only when all counts
are present. Missing categories leave the combined total unknown.

`agents usage summary` groups retained task observations by provider, verified
account where available, actual model and usage scope. Unverified bindings stay
separate by machine/profile. Repeated observations of a task use its latest
record. The result separates tasks with known totals from tasks with unknown
counts and sums only reported totals. This is token activity, not subscription
headroom or a bill.

Primary references: [Codex non-interactive output](https://learn.chatgpt.com/docs/non-interactive-mode)
and [Claude usage scope](https://code.claude.com/docs/en/agent-sdk/cost-tracking).
