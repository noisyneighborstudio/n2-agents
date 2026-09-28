# Keychain retirement evidence spike

Observed Codex 0.157.1 on 2026-09-26. This is a source-level fake-backend experiment,
not live Keychain or provider acceptance. The [fixture](migration-keychain-retirement-spike.json)
records the pinned upstream revision, source and extracted-method hashes, nine
observations, substitutions and unverified behavior.

## Provider contract and source

[Authentication](https://learn.chatgpt.com/docs/auth) describes file, keyring,
automatic fallback and process-memory storage, with administrator requirements
that can override user configuration. [CLI commands](https://learn.chatgpt.com/docs/developer-commands)
describes logout as clearing stored credentials. These docs do not establish that
a successful logout invalidates every copied token.

The matching upstream release tag points to commit
`36650394c5b38c2990ccf2a3457165ca3e9d9726`. Its
[storage implementation](https://github.com/openai/codex/blob/36650394c5b38c2990ccf2a3457165ca3e9d9726/codex-rs/login/src/auth/storage.rs)
keys direct-Keychain entries by service `Codex Auth` and account
`cli|` plus the first 16 hexadecimal characters of SHA-256 of canonical CODEX_HOME.
Canonicalization falls back to the supplied path if it fails. A symlink to the
same existing directory shares the key; a renamed directory has a different key.
The [backend default](https://github.com/openai/codex/blob/36650394c5b38c2990ccf2a3457165ca3e9d9726/codex-rs/config/src/types.rs)
is direct storage on non-Windows platforms, but the actual
[configuration resolver](https://github.com/openai/codex/blob/36650394c5b38c2990ccf2a3457165ca3e9d9726/codex-rs/core/src/config/auth_keyring.rs)
selects the backend from the effective `SecretAuthStorage` feature, including
managed requirements. Do not infer effective storage from the platform alone.
The encrypted Secrets backend was inspected but not executed. Matching version
strings do not verify the installed binary's provenance.

[Logout](https://github.com/openai/codex/blob/36650394c5b38c2990ccf2a3457165ca3e9d9726/codex-rs/login/src/auth/manager.rs)
clears the selected persistent store and same-process ephemeral state. Ephemeral
mode clears only that process's memory store. The
[revocation code](https://github.com/openai/codex/blob/36650394c5b38c2990ccf2a3457165ca3e9d9726/codex-rs/login/src/auth/revoke.rs)
attempts revocation for managed ChatGPT auth, prefers the refresh token and falls
back to the access token. Failure is logged and does not stop local logout.
The CLI maps successful local cleanup to exit zero. That exit code is insufficient
revocation evidence.

## Recorded observations

The temporary Rust executable used unchanged upstream method bodies for storage,
loading and logout. It substituted an in-memory keyring and failing revocation
function. Auth payloads were generic synthetic JSON; no real auth parser, CLI
configuration loader, HTTP client or OS keyring backend was exercised.

| Selected mode | File left | Direct keyring entry left | Same-process memory left |
| --- | --- | --- | --- |
| file | no | yes | no |
| keyring | no | no | no |
| auto | no | no | no |
| ephemeral | yes | yes | no |

Every case preserved a synthetic copy under another home. This proves storage
scope, not whether a real provider would accept that copy afterward.

Auto preferred keyring data, fell back to a file on load/save failure, and did
not fall back on delete failure. Explicit keyring load failed when the fake store
was unavailable. Failure before deletion retained both stores. Failure injected
after keyring removal retained the file; retry cleared both. The source-level
logout returned success and removed its file despite injected revocation failure.

All nine assertion cases passed. The exploratory runner and executable were
discarded after independent review; only notes, source fingerprints and observations remain.

## Next implementation brief

Add an explicit, revision-checked `migration-logout` step that keeps migration
pending. Bind its receipt to the exact original canonical CODEX_HOME, provider
version and observed effective storage/backend. Unknown scope or unsupported
backend must refuse before mutation. Use the provider-supported logout operation,
not custom OS Keychain deletion or copied credential imports.

Persist operation intent before launching logout. Record success, failure or
interrupted/unknown outcome without storing tokens or claiming global revocation.
File-only or ephemeral cleanup must never count as complete Keychain retirement.
A failed or interrupted attempt remains retryable and fenced. Once logout has
begun, abandonment must not blindly restore a potentially revoked credential
archive as a usable login; report the need for fresh sign-in instead.

Proof uses a disposable fake provider/backend to cover exact route and revision,
unsupported scope, success-with-unconfirmed-revocation, partial deletion,
interruption/retry and abandonment. No real logout runs during implementation.
Peer retirement, effective provider configuration evidence, unmanaged-session
handling, provider revocation evidence, fresh owner enrollment and verified
activation remain required. This bounded step cannot mark migration complete.
