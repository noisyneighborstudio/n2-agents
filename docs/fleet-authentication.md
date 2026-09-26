# Fleet authentication support

This is the current support contract. It supersedes the authentication matrix in
the historical fleet design record. Checked September 26, 2026.

N2 replicates allowed credential files between approved peers after credential
sharing is enabled on both ends. It does not convert a provider credential store
into a fleet-wide login service. A matching profile name never proves a matching
account. See [measurement identity](usage-measurements.md#provider-identity-evidence)
for the evidence attached to quota reads.

## Provider routes

| Provider | N2 support | Verified behavior and limits |
| --- | --- | --- |
| Claude | Partial | Profile-scoped Keychain credentials can be explicitly exported to an isolated file snapshot. In-scope file credentials replicate. The September 25 trial recorded receiving-Mac usage acceptance for five copied profiles. N2 does not continuously watch or update Keychain entries. Native refresh, logout revocation and account changes across live copies are not verified. |
| Codex | Partial | File-backed `auth.json` replicates; the September 25 trial recorded receiving-Mac usage acceptance for five copied profiles. Concurrent file edits become conflicts. Keyring and ephemeral authentication are not exported. OpenAI advises against sharing one managed auth file across concurrent jobs or machines. N2 has no renewal owner; file conflicts cannot coordinate provider refresh. Revocation of copied credentials is unverified. |
| Grok | Partial | Profile `auth.json` replicates. There is no live receiving-machine authentication or refresh evidence in this review. |
| Muse | Partial | Non-Default profiles use the file backend. Default's machine Keychain credential is not exported. There is no live receiving-machine authentication or refresh evidence in this review. |
| Cursor | Partial settings sharing; login export unsupported | Credential-bearing settings and MCP configuration can replicate with explicit opt-in. The CLI uses a machine-wide Keychain login that changing its configuration directory does not isolate. N2 does not export or replace that login. |
| OpenCode | Unsupported | Credentials live outside the isolated configuration slot. N2 refuses credential-sharing opt-in until data-directory isolation exists. |

These tiers apply to N2's current adapter behavior. They do not describe what a
provider might support through a different integration. The recorded live trial
used isolated credential snapshots, not a login-reset, refresh-race or revocation
experiment. Its scope and commands are in [fleet QA evidence](fleet-spike.md).

## Provider documentation versus N2 behavior

Claude documents Keychain storage on macOS, file fallback when Keychain writes
fail, and path-scoped storage under `CLAUDE_CONFIG_DIR`. Its documented credential
precedence includes cloud/gateway routes, environment credentials, helpers and
Anthropic profiles. Consequently, copying `.credentials.json` is insufficient
when another credential source wins. N2's first-party reader rejects detected
overrides; this does not prove the credential a future project-specific launch
will select. [Claude authentication](https://code.claude.com/docs/en/authentication).

Codex documents file, keyring, auto and ephemeral stores, automatic refresh during
use, and copying the file cache to a headless machine. A copied file does not
replace a selected keyring or process-memory credential. Forced login/workspace
restrictions can log out mismatched credentials, so N2 must not apply them as a
read-only identity probe. [Codex authentication](https://learn.chatgpt.com/docs/auth).

The managed-auth automation guide advises against sharing one `auth.json` across
concurrent jobs or machines. Another machine rotating a token can invalidate the
refresh grant. The guide excludes external-token host integrations from its
workflow. [Codex managed-auth automation](https://learn.chatgpt.com/docs/auth/ci-cd-auth).

The [renewal ownership plan](fleet-auth-ownership.md) describes the required host
integration. It is not implemented or a claim of supported concurrent renewal.

N2's merge protocol detects independent credential-file edits and asks for a
resolution. That is a file-level guarantee. It does not establish that a
provider will accept either refresh token after two disconnected machines have
used the same token family. N2 therefore does not promise coordinated refresh
or repair a provider rejection by silently choosing one machine's credential.

## Sign-out, reset and removal

An in-scope credential-file update or deletion follows normal replication,
exceptions and conflict rules. A Keychain-only update is outside that file
protocol. N2 does not promise that a provider logout revokes all remote copies,
or that already-running provider processes drop credentials held in memory.

Disabling sharing or excluding a machine stops future sharing; it does not erase
previously received secrets or revoke them with the provider. Removing a fleet
peer prevents future authenticated fleet access. If existing copies must lose
provider access, revoke or rotate the credential with the provider separately.
This distinction applies even when the fleet peer is offline.

## Current read-only observations

At 08:00 UTC on September 26, both local Claude profiles, Default and ExpoIO,
had expired access tokens. Direct profile requests returned HTTP 401. At 08:01
UTC, the M5 was reachable over SSH, but all five configured Claude profiles
returned `credential-store-unavailable`. No login, refresh, Keychain unlock or
credential replacement was performed. These observations cannot establish a
successful live execution/account binding.

Expired, inaccessible and missing credentials are distinct conditions. None is
reported as full headroom. Authenticating a measurement bearer also does not
prove that an independently launched T3 or N2 process used it; execution binding
remains required for account-attributed outcomes.
