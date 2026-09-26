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
