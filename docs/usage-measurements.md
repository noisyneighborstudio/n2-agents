# Usage measurements

`agents best` reads provider allowance measurements for the configured profiles.
Percentages are used, not remaining. The 95% selection cutoff is an N2 safety
reserve, not a provider-defined exhaustion threshold.

`agents best --json` emits one JSON object per profile, one per line. Use
`--vendor codex` or another provider to narrow the output. Schema version 1
includes provider, profile, observation time, source, status, identity evidence,
limit windows, restrictions, credit information and the legacy display columns.
This is an inspection format; it is not yet a replicated fleet usage ledger.

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

Account/workspace verification, durable account-scoped observations, propagation
of execution failures and task token attribution remain tracked in
[fleet readiness](fleet-readiness.md). Grok, Muse and Cursor still use their
existing collectors; their limitations have not been resolved by this change.

## Primary references

- [Codex app-server authentication and rate limits](https://learn.chatgpt.com/docs/app-server)
- [Claude Code authentication and credential storage](https://code.claude.com/docs/en/authentication)
- [Claude Code usage and failed-read behavior](https://code.claude.com/docs/en/costs)
