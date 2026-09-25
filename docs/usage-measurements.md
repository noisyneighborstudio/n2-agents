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
local task reference and requested Claude model where known. Token totals,
provider-session identity and verified account identity remain unknown. Recorded
rejections do not yet change selection outside the loop’s existing cooldowns. An unknown account identity remains
unknown; recording or replicating an observation does not verify it.
