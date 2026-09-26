# Codex renewal ownership

Implementation plan for the authentication-lifecycle requirement in PR #3.
Current N2 execution pins an existing access token. It cannot renew that token.
This plan does not change live profiles or migrate credentials.

## Provider constraints

OpenAI's [managed-auth guide](https://learn.chatgpt.com/docs/auth/ci-cd-auth)
advises against distributing one managed `auth.json` among concurrent jobs or
machines. Provider-side rotation can invalidate a copied refresh grant before
N2 sees any file conflict. The guide recommends built-in Codex refresh rather
than implementing an OAuth refresh endpoint independently.

The [app-server protocol](https://learn.chatgpt.com/docs/app-server) supports
experimental host-supplied access tokens. The host owns renewal and responds to
`account/chatgptAuthTokens/refresh`; the server retries the failed request. The
request includes an optional previous account ID and has an approximately
10-second timeout. These documents establish the interfaces, not a verified N2
broker implementation. Compatibility must be tested against the installed Codex
version.

## Ownership model

N2 will separate the fleet account record from the refreshable login grant. A
profile can refer to one verified provider account while individual grants have
different owners. Profile names, profile UUIDs and credential-file equality do
not prove account identity or independent grants.

For a grant managed by N2, one designated machine retains the refresh credential
in a private, N2-owned store outside replicated profile resources. Its broker
uses Codex's managed authentication to renew under an exclusive local lock. Only
short-lived access tokens go to approved external-token clients over authenticated
fleet transport. Refresh tokens, ID tokens and credential-store files never
appear in broker responses, command arguments, logs, usage events or revision
snapshots. Token responses require a separate secret-bearing transport path;
the ordinary journaled fleet response path must not carry them. Signatures alone
do not provide secrecy. Responses require an encrypted authenticated channel,
a fresh requester nonce, exact request and recipient binding, a short expiry and
replay rejection. Plaintext tokens cannot be spooled to temporary files or logs.

The broker record needs a versioned grant ID, owner machine ID, verified account
hash, profile ID, ownership generation and credential-store mode. The public
record has no secret or token-derived fingerprint. Client requests pin the
record generation, account and requesting machine. The owner checks current
peer approval and account-sharing consent on every request. A machine exception
or revoked peer cannot fetch another token. An already-issued access token
remains valid according to provider policy; N2 cannot promise remote revocation.

There is no automatic owner election. An offline owner leaves clients waiting
for renewal, with an explicit authentication state rather than a quota denial.
Existing valid access tokens may continue. Ownership transfer requires the old
owner to stop and acknowledge release before the new owner activates the grant.
Release is a durable, target-bound, one-use state transition. The old owner must
persist a fenced generation before acknowledging release; restart or rollback
must not reactivate it. A destination can activate only the matching handoff after
private credential persistence. Any grant transfer uses the same confidential
transport rules, and the old owner retires its copy. Until rollback-resistant
fencing is demonstrated, owner transfer must require a fresh provider login.
If that acknowledgement is impossible, establish a fresh provider login rather
than cloning a potentially active refresh grant. Separately authenticated grants
may serve the same verified account, but a copied file must never be labelled
independent merely because it lives on another machine.

## Execution and renewal

A bound runner asks its selected owner for an access token, validates the provider
account in its private app-server and pins the resulting account hash. It never
switches accounts during a turn or resume. Before responding to a refresh
request, it requires the expected account and ownership generation. A missing
previous account ID is not permission to choose an account; the existing binding
remains authoritative.

Concurrent renewal requests on the owner must coalesce. After taking the lock,
the broker rechecks whether another request already renewed the rejected token
generation. Clients identify that generation with an opaque owner-issued handle;
they do not send token fingerprints or refresh credentials.
It refreshes through Codex only if needed, persists the rotated grant atomically,
and publishes a newer token generation after persistence. If renewal fails,
its fixed diagnostic contains no provider response body. Timeouts do not trigger
another owner or a second refresh elsewhere. A timeout or crash after sending a
refresh may leave an unknown provider outcome. This state is distinct from a
definite rejection: reconcile Codex's durable managed store before proceeding,
and never retry using an older saved grant. If the persisted state cannot resolve
the uncertainty, report reauthentication required.

The runner rejects malformed requests, another account, expired responses,
unknown ownership generations and responses arriving after the protocol deadline.
Before giving a renewed token to the execution app-server, authenticate that exact
token against the expected provider backend, workspace and account in an isolated
verification connection. Broker envelope labels and decoded token claims are not
sufficient evidence. The execution server retries immediately after the refresh
response, so terminal-only checks would be too late to prevent work on another
account. This verification must fit within the remaining refresh deadline or the
runner must fail without supplying the token. Post-renewal checks must also
preserve the original account before a terminal receipt can attribute work. Authentication recovery never clears a quota rejection
by itself. Account-bound successful execution or the provider reset remains the
usage journal's recovery evidence.

## Login and reset from any machine

N2 remains the account-management interface on every approved machine. A login
or reset initiated on a non-owner sends an authenticated, consent-checked request
to the owner. The owner creates the provider login challenge and keeps its
correlation state; the requesting machine displays the provider URL or device
code. It never receives a refresh grant merely to display the login flow.
Completion must match that challenge and authenticated provider identity before
N2 publishes a new grant generation. Device-code availability and browser callback
routing require tests against the installed provider client.

Changing the account is an explicit replacement, not renewal of the old binding.
The fleet profile updates only after the replacement has verified successfully.
Existing turns and resumable sessions retain their original account binding;
they may finish with still-valid credentials, or fail with an authentication
state if reset revoked the old grant. They must never receive tokens for the
replacement account. A cancelled or failed login leaves the prior profile intent
intact. If the owner is offline, show the pending login/reset and the owner needed
for completion; do not perform an implicit grant takeover on the requester.

## Migration and compatibility

Existing opted-in credential sync is legacy snapshot sharing. Its diagnostic
must state the provider constraint. Adding the broker must prevent its managed
grant from re-entering ordinary sync, including credential-bearing settings and
previously queued transfers. Existing remote copies cannot be made safe by
changing a metadata flag. Migration needs an explicit inventory of copies,
retirement or provider revocation of the old grant, and creation or enrollment of
the owner grant. Interrupted migration must leave the profile visibly pending,
with old bytes preserved for recovery and no claim of completed ownership.

Keychain-backed login capture needs a provider-supported path and explicit
migration handling. A file-only prototype does not satisfy that requirement.
Unmanaged CLI sessions using legacy copies are outside the broker's lock; N2 must
report that condition rather than claim exclusive ownership. T3 integration must
use the broker-bound route or report an unverified binding.

## Required implementation and evidence

- [ ] Versioned public ownership records and private owner storage, with invalid,
  conflicting, missing and retired states tested.
- [ ] Signed, recipient-bound secret responses that bypass diagnostic persistence;
  replay, wrong-peer, revoked-consent and redaction tests.
- [ ] Built-in Codex renewal under a process-safe owner lock, concurrent-request
  coalescing, atomic persistence and crash/restart tests.
- [ ] Same-account renewal handling in the bound runner, including the server's
  deadline, mid-turn refresh, mismatched account and late-response tests.
- [ ] Migration and sync exclusion, including offline peers, queued transfers,
  old grant copies and interrupted ownership transfer.
- [ ] Login/reset from a non-owner, including challenge correlation, cancellation,
  owner disconnection and account replacement while an existing turn is active.
- [ ] Keychain lifecycle integration and explicit health/repair behavior.
- [ ] Disposable two-machine acceptance covering initial execution, renewal,
  recovery, owner disconnection, peer removal and account switching. A synthetic
  protocol test cannot replace provider acceptance evidence.
- [ ] Native status, scheduling and T3 binding consume the ownership state without
  treating authentication failures as exhausted allowance.

No live renewal or credential migration is authorized by running a read-only
usage audit. Prepare and review the implementation and disposable experiment
before any operation that changes the user's current login state.

## Protocol implementation status

The shared `CodexRPC` connection accepts an optional trusted `renewal_source`
when pinning an external account in ephemeral mode. The source receives the
pinned account ID and a monotonic deadline, and returns only `accessToken` and
`chatgptAccountId`. Its owner record, consent and token-generation state belong
to the broker implementation. This callable is an internal integration point,
not a user-configured command or an assertion that an owner exists.

Before sending the response, the connection uses another ephemeral app-server
to authenticate the supplied token and compare provider/account evidence with
its original binding. Malformed requests or responses, reused rejected tokens,
account mismatch, verification failure and late results disable the connection.
Observed `account/updated` notifications still invalidate the binding. Production
runners do not supply a renewal source yet and retain the existing explicit
renewal failure. No live credential has been renewed by these protocol tests.

The deadline includes inbound queue and buffered-byte age. Backpressure carries
that conservative age to unread pipe data until the reader observes the pipe
empty. This can refuse renewal during a severely delayed stream; it cannot grant
a fresh timeout to a request that was already waiting. The source runs in a
bounded wait. It may complete after the caller times out, but its result is not
sent to the execution server. The broker must own cancellation and reconciliation
of any provider operation it has already started.


## Owner response codec

`fleet-auth-response.py` signs token replies through `ssh-keygen` stdin and
verifies them in memory. The signature namespace is
`n2-agents-auth-response-v1`. The exact request context includes schema version,
owner and recipient fleet fingerprints, a 32-byte random nonce encoded as hex,
grant UUID, ownership-generation UUID, expected account hash and a wall-clock
expiry no more than 30 seconds away. `rejectedTokenGeneration` is explicitly
null for an initial fetch or the opaque UUID returned with a rejected token.
This is signed request context, separate from the ownership generation. The owner
must coalesce known stale generations and reject unknown generations instead of
blindly starting another refresh. A renewal response cannot return the rejected
generation. Both signing and verification enforce that condition. A separate
monotonic deadline bounds local
operations. Replies also carry an opaque token-generation UUID.

Each outstanding request has one verifier. Success and failure both consume it,
including concurrent delivery attempts. Callers must generate a fresh nonce for
every request and cannot recreate a verifier to retry a consumed response. The
codec freezes request context so later caller mutation cannot redirect it.

Secret payloads use memory and subprocess pipes. SSH signature verification
requires temporary files for public signer and signature material; the codec
validates and rebuilds the signature structure before writing those files. It
never sends tokens in process arguments or propagates subprocess diagnostics.

This module authenticates replies and request correlation. It does not encrypt
them, check fleet consent, or prove provider account identity. It must be used
only over an authenticated encrypted carrier, followed by the bound runner's
provider verification. Existing `fleet_call` writes reply files and must not be
used for these messages. The private carrier below replaces that reply path;
the owner service remains to be implemented.

## Token-response carrier

`fleet-auth-transport.py.exchange` now sends a public request context through
`agents _fleet-auth-call`. The private command signs the ordinary fleet request
and streams the reply through the existing pinned SSH carrier. It requires an
approved peer whose key matches the expected owner. The actual carrier refuses
`exec` and bootstrap credentials, including a route edited after initial checks.
After the carrier finishes, approval and the owner key are checked again.

The client bounds reply bytes and total elapsed time, rejects nonzero carrier
exits, and verifies the owner signature before returning a token. Public request
context and signed requests can use temporary files. Reply bytes stay in memory;
carrier stderr is discarded, and failures expose one fixed diagnostic. Timeout
cleanup kills the dedicated local process group, including descendants holding
the reply pipe open. These approval checks are observations, not a lease that
can prevent a later revocation.

The `auth-token` owner handler remains unimplemented. Grant consent, ownership
state, renewal and response signing still need to be connected on the server.
The client transport does not substitute for these checks. The synthetic SSH
fixture exercises real fleet request verification and signed token responses;
it does not establish live provider renewal.

## Private owner grant state

`fleet-auth-owner.py` provides a private store with a process lock per grant.
New grants start with an empty Codex home and remain `pending-login` until the
integration verifies the exact stored access token and supplies its account hash
and credential-file revision. It never imports a legacy profile login. The
production caller must locate this store outside synchronized profile trees.

Each grant records explicit peer consent, its owner and ownership generation,
verified account, token generation and bounded previous-generation history.
Rejecting the current token persists `renewing` before permitting one provider
attempt. Concurrent requests rejecting that same generation then use the
verified replacement. Unknown generations cannot trigger a refresh. A restarted
owner cannot repeat an uncertain attempt; it must independently verify changed,
persisted credentials or require reauthentication. An unchanged access token
cannot complete renewal.

State replacement uses a private temporary file, file sync, atomic rename and
directory sync. Store and grant creation also sync their parent directory entries
before acknowledging success. Persistence errors invalidate the in-memory session. The process
lock has a deadline and is never stolen. Retirement changes the ownership
generation and removes consent. This survives ordinary process restart; it does
not provide rollback-resistant ownership transfer or authorize restoring a grant
from backup.

The store accepts trusted verification results from its caller. It does not
perform provider verification, invoke native refresh, implement login/reset,
serve `auth-token`, or connect production execution to renewal. Those integration
steps remain required. The tests use disposable credentials and synthetic
verification results, including concurrent processes and abrupt process death.

## Native owner integration

`fleet-auth-native.py` connects the locked store to the installed Codex
app-server. A request first checks grant consent, ownership, account and token
generation. When renewal is required, the durable state changes to `renewing`
before starting Codex with the owner's private home and file credential store.
The helper requests `account/read` with `refreshToken: true`, then closes that
process. It does not implement an OAuth endpoint or refresh-token algorithm.

The [official app-server documentation](https://learn.chatgpt.com/docs/app-server)
and Codex 0.157.1's generated `GetAccountParams` schema describe this flag as the
managed token-refresh operation. External token mode ignores the flag. The
owner therefore uses managed file authentication for this operation and a
separate ephemeral process for verification.

After Codex finishes, the helper syncs its credential file and directory. It
passes only the saved access token and account ID to an isolated ephemeral
app-server, reads authenticated allowance/account information, and computes the
same account hash used by N2 measurements. Completion must match the expected
account and exact verified credential revision before a token can be returned.
The environment excludes inherited authentication, endpoint and proxy overrides;
HOME and CODEX_HOME point at the operation's private home.

An explicit reconciliation call verifies a saved result without invoking refresh.
A failed or timed-out renewal remains uncertain until reconciliation succeeds or
reauthentication is required. Errors use fixed messages rather than provider
diagnostics. These methods are internal and require the caller to hold the grant
lock. Fleet approval checks and authenticated request dispatch still belong to
the unimplemented owner endpoint. Login/reset, migration and production runner
wiring also remain required.

Managed renewal runs under a dedicated supervisor that inherits the held grant
lock. If the requesting owner process dies, the supervisor retains that lock
until the native process exits or the original operation deadline expires. It
kills the process group before exiting, so recovery cannot acquire the lock
while the prior native operation remains active. The process-death fixture kills
the owner after credential persistence, confirms recovery is blocked during the
native operation, and then verifies the saved replacement without another refresh.

## Authenticated owner endpoint

The `auth-token` fleet handler now calls `fleet-auth-server.py` with the sender
returned by ordinary fleet signature, addressing, approval and replay checks.
The handler requires an SSH session. Local `exec` delivery is refused; the
client also requires its pinned SSH carrier. SSH session environment is a local
entry-point guard, not an additional authentication mechanism against the local
OS user.

The endpoint binds the request recipient to the authenticated sender and the
owner to its local fleet key. It rechecks roster approval, public-key identity
and revocation before opening `fleet/auth-owners/<grantId>`, outside profile
sync trees. Under the grant lock, the native owner checks grant consent,
ownership generation, expected account and rejected token generation. Replies
are signed and returned in memory. Approval is checked again after signing and
before bytes leave the helper. These checks do not establish a revocation lease.

Secret replies bypass `fleet_ok`, ordinary reply decoding and reply temporary
files. Only the public signed request is spooled by the existing receiver.
Endpoint failures emit a fixed diagnostic. The caller still must verify the
returned token against the provider before using it for execution.

Seven endpoint tests use real fleet envelope signatures with a synthetic SSH
carrier and disposable native provider fixture. They cover initial fetch,
renewal, stale-generation reuse, missing grant consent, wrong account/recipient,
unknown grant, non-SSH delivery and revocation during signing. They do not prove
live provider recovery. Profile-to-grant registration, login/reset, migration
and the production runner connection remain required.

Generic `fleet_call` refuses `auth-token` before creating reply files or dialing.
Both that path and envelope construction require canonical lowercase/hyphen
verbs, preventing newline and shell-escape spellings from bypassing the private
carrier guard. Envelope recipients reject framing characters. The exec carrier
clears inherited SSH session variables before starting its local receiver.

## Public profile-to-grant record

`fleet-auth-binding.py` defines `.n2-owner.json` for a Codex profile slot. Its
schema contains only version, provider, profile UUID, grant UUID, owner fleet
fingerprint, ownership generation, verified account hash and credential-store
mode. It contains no access/refresh/ID tokens, token generations, credential
revisions, token digests or consent lists. The supported store mode is
`owner-file`; keychain migration remains a separate requirement.

An active locked grant can produce the record after provider verification. A
reader requires an exact profile UUID match and a known schema. Publication
requires the caller to hold the same resource lock used by profile sync. Initial
publication requires absence; replacement requires the exact prior byte revision.
Unknown schemas, malformed records, symlinks and nonprivate records are preserved
and refused. Publishing uses a synced private temporary file, atomic replacement
and directory sync.

This record expresses routing intent. It neither authenticates a provider account
nor makes a profile schedulable by itself. The token endpoint and bound runner
must still enforce the pinned account and grant. Registration commands, sync
classification and conflict handling, migration admission and runner consumption
are not wired to this record yet.

Public records support ordinary mode-0755 profile directories owned by the local
user, provided group/other write bits are clear. The record itself remains
mode-0600. Symlink slot directories are refused by this layer; adoption must
resolve and validate the local route before registration. An actual `agents new`
fixture verifies compatibility without changing profile permissions.

## Session-pinned owner client and bound execution

`fleet-auth-client.py` freezes the public record for one execution session and
checks it against the selected profile UUID and expected measured account hash.
Remote owners use the signed private SSH transport; a local owner uses the same
private grant lock and native renewal checks without an SSH hop. Both paths pin
the ownership generation and track the returned token generation. Renewal sends
the generation the execution process rejected, so concurrent fleet clients can
reuse one verified replacement.

The client returns only access-token/account-ID pairs in memory. It rejects an
unexpected account, unchanged generation, expired deadline or changed requester
identity. Failure invalidates the client session, including a timed-out concurrent
request. A later edit to the profile record does not retarget an existing session.
Provider verification remains mandatory in the bound RPC runner for initial and
replacement tokens.

`agents run --bound-account` now forwards its selected root and profile name.
When the slot contains an ownership record, `codex-run.py` requires ready,
nonduplicate profile metadata, validates the record, fetches from the pinned
owner and supplies the renewal callback to its ephemeral execution process.
It never reads legacy `auth.json` on that path. Malformed or dangling ownership
records fail instead of falling back. Slots with neither a record nor an unresolved
ownership conflict retain the legacy execution path until explicit migration.

Synthetic integration tests cover local and remote renewal, record pinning,
wrong-account rejection, timeout races and malformed records. A complete bound
turn and the actual `agents run` command renew through signed fleet dispatch,
preserve the verified account and produce the same usage receipt. These fixtures
leave deliberately invalid legacy credentials untouched. Registration, migration,
owner-backed measurements and general unbound CLI/T3 routes remain required.

Owner-backed usage now resolves the same profile record as bound execution,
fetches from that owner and independently authenticates the exact token/account
before publishing allowance windows. An unavailable owner or mismatched account
produces `owner-unavailable`, unknown identity and no headroom. The journal
retains that status and the native UI labels it `account owner unavailable`.
A legacy usage-URL override cannot bypass an ownership record.

A token may expire while no client is running. During the first pin, a valid
native `account/chatgptAuthTokens/refresh` request with reason `unauthorized` and
the expected workspace triggers one bounded recovery. The client closes that
unbound process, renews its rejected generation through the owner, then pins a
fresh ephemeral process. The expected account hash must verify before any usage
or executable connection is returned. The inbound request's age and original
deadline bound renewal. An invalid request, unusable replacement or second
initial rejection fails; it never loops refresh attempts or starts a turn first.


## Registration and replication

`agents fleet auth register Profile --grant ID` binds a verified active local
grant. It requires ready, unique profile metadata and refuses legacy credential
files and unresolved ownership conflicts. Replacing a record requires its current
`--expected-revision`. `status` reports public state. `allow --peer ID` requires a
currently approved peer; `deny --peer ID` revokes grant consent. An ownership
conflict blocks consent changes until the operator resolves the intended grant.

The public record replicates as a settings resource, with exact profile-ID and
schema validation and private destination permissions. The existing sync
exceptions and conflict rules apply. A slot gate serializes publication with
incoming Codex writes. Managed slots cannot receive or advertise auth/MCP or
credential-bearing payloads through ordinary sync. Removing the record through
a synchronized tombstone is refused; retirement needs explicit lifecycle logic.
Both canonical conflicts and staged resolution records preserve the fence,
including when the local ownership record is absent. Measurement and execution
also refuse those conflicts instead of falling back to legacy credentials.

Configuration revisions now cover the public record under
`n2-profile-routing-v2`; the record does not itself prove authenticated identity.
This registration path expects an already-verified grant. Fresh login/reset,
historical credential inventory, offline-peer migration, keychain capture,
retirement/recovery and general CLI integration remain unfinished.


## Fresh login on the owner

`agents fleet auth login Profile` starts a new Codex device-code login in a new
private owner grant. The JSON challenge contains the provider verification URL,
user code and login ID. Complete that challenge in a browser; the command waits
up to ten minutes by default, with `--timeout SECONDS` bounded to 1–900 seconds.
Provider completion must match the login ID. The persisted credential is then
independently authenticated before publication.

An existing owner record requires its current `--expected-revision`. Replacement
preserves the expected account unless `--replace-account` explicitly permits a
different account. The old grant remains separate for already-bound sessions;
new grants initially permit only the owner, so peers need explicit consent.
Profile/route changes during login cause publication to fail instead of replacing
newer intent. The verified private grant is retained for recovery if publication
fails. Pending or failed logins are not usable grants.

The command currently runs on the designated owner and refuses an implicit
remote-owner takeover. Non-owner initiation and status/cancel transport remain
required. The device flow follows the official app-server documentation at
https://learn.chatgpt.com/docs/app-server and was checked against the installed
Codex-generated LoginAccountParams, LoginAccountResponse and completion schemas.
The synthetic tests do not establish real account device-code availability.


## Owner recovery commands

`agents fleet auth reconcile Profile` is for a designated local grant left in
`renewing` after an interrupted refresh. It verifies the already-persisted
credential against the original account and completes that generation. It never
asks the provider to refresh again. An unchanged or wrong-account credential
cannot become active through reconciliation. The public profile binding stays
unchanged, and the command refuses ownership conflicts or a different owner.

`agents fleet auth grants Profile` lists local grant IDs, account hashes and
states, including pending and abandoned login grants. It reads atomic state
snapshots without taking the human-login lock and never emits credentials,
credential digests or token generations. Invalid grant state is reported as
invalid rather than treated as usable.

`agents fleet auth retire Profile --grant ID` explicitly disables that local
grant and clears its peer consent. A current profile record remains in place and
status reports `retired`, so measurement/execution fail rather than fall back to
legacy credentials. It can also retire an abandoned grant belonging to the same
profile. This is broker retirement, not provider-side revocation; credentials
already held by an unmanaged process may remain usable until provider expiry or
revocation. The command does not delete credential files or claim migration is
complete.


## Remote login message contract

The login-control wire now has a separate SSH signature namespace from token
responses. Each short-lived request binds its owner, requester, nonce, operation
ID, action, profile ID, current grant/ownership generation, account hash, binding
revision and explicit account-replacement permission. Actions are `start`,
`status`, `finish` and `cancel`; repeated polling uses a fresh nonce.

Replies contain only a bounded status, a validated device challenge when needed,
or a completed public replacement binding. A completed replacement must belong
to the same profile and owner, name a new grant, and preserve the original account
unless replacement was explicitly allowed. Unknown fields, including token
fields, are rejected. Each verifier accepts at most one reply. The private
pinned-SSH carrier keeps replies in memory; generic `fleet send auth-login` is
refused before dialing because that path creates response files.

This increment implements the wire and carrier only. The owner endpoint and
operation worker remain unfinished. They must persist requester-bound operation
intent, enforce management consent and current approval, correlate native login
completion, handle disconnect/cancel/expiry, and serialize final publication with
cancellation and the original binding revision. A signed message alone is not
permission to start login, replace an account or publish a binding.
