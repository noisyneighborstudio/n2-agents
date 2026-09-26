# Credential retirement evidence spike

Observed 2026-09-26 against `d6dad7eaeb82ac9eec6e0fe674eee69ac6d04cdc`.
Scope: disposable inventory fixtures and canonical documentation. No provider
request, real credential, login, logout, revocation, or Keychain access occurred.

## Proof and observations

The recorded [fixture](migration-retirement-spike.json) contains four temporary
profiles configured for file, keyring, auto, and ephemeral storage. Only the file
case contains synthetic top-level credentials; every case contains two synthetic
retained sync-conflict copies. An inline exploratory runner reused the existing
migration test fixture, invoked the real `migration-begin` command, checked every
credential byte remained unchanged, and recorded its inventory output. The runner
was discarded; no exploratory production code was added.

All four results remain pending with incomplete inventory, uninspected Keychain,
unconfirmed revocation, and unknown unmanaged processes. Missing `auth.json` in
three cases did not establish credential absence. The declared storage settings
are fixture inputs, not evidence of effective provider configuration or actual
Keychain contents. Conflict snapshots remain credential-bearing candidates even
when the active file is absent.

## Provider evidence

[Authentication](https://learn.chatgpt.com/docs/auth) documents file, OS-keyring,
automatic fallback, and process-memory credential storage. Administrative policy
can constrain storage. A file-only scan cannot establish a complete inventory.

[Automation guidance](https://learn.chatgpt.com/docs/auth/ci-cd-auth) requires
serialized use of refreshable credentials and warns that another machine may
rotate the token first. Restoring an old seed is not a recovery guarantee.

[CLI commands](https://learn.chatgpt.com/docs/developer-commands) describes logout
as removal of stored credentials. These inspected pages do not establish that
logout revokes every copied refresh/access token. Treat global revocation as
unconfirmed until supported evidence exists, not as a consequence of local logout.

## Decision and next slice

Prepared barriers and recovery receipts establish coordination, not retirement.
The next observable step is explicit, recoverable archival of known local file
copies outside active and sync paths while the migration remains pending. Include
retained conflict payloads, reject ambiguous/symlinked inputs, and retain an exact
private manifest. Recovery must restore archived bytes before allowing legacy
access, without overwriting intervening files. Public evidence contains no secret
bytes or token fingerprints. Archival must never report provider revocation or
completed ownership.

Completion still requires peer retirement evidence, provider-supported Keychain
handling, unmanaged-session/revocation evidence, fresh owner activation, and a
verified final transition. Those requirements remain in the ownership contract;
this staged archival step does not replace them. No current fixture permits a
completed-ownership claim.
