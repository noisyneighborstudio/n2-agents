# Fleet and usage readiness

Work in progress for PR #3, followed by the T3 adapter in PR #26. This checklist supplements the original fleet requirements; unchecked items remain required.

## Usage reliability

- [x] Failed and aged polls do not advertise fresh capacity. Focused production-model regression tests pass.
- [x] Missing measurements do not count as full headroom in loop selection.
- [x] Recognize the observed Claude session, monthly spend and usage-credit rejection messages.
- [ ] Verify credential precedence and account identity for every measured binding.
- [ ] Preserve provider limit buckets, model restrictions, reset times and credit/spend restrictions without conflating them.
- [ ] Share durable, account-scoped usage observations and execution rejections across the fleet.
- [ ] Attribute task tokens to account, model, session and machine, with explicit unknown fields.
- [ ] Make summary gauges and freshness diagnostics unambiguous.

## Fleet completion

- [x] Reverify enrollment and transport: 339 passed, zero failures/skips, live SSH required.
- [x] Reverify profile/configuration/credential sync, conflicts and machine exceptions: 639 checks pass across all 75 sections.
- [ ] Complete provider-specific authentication lifecycle evidence and explicit limitations.
- [x] Reverify managed-tool authorization, replication and safe update deferral, including a barrier test of preparation versus disruptive installation.
- [x] Verify dispatch eligibility, preferences and expected-completion ranking: 97 execution checks and focused preference/prompt/delivery checks pass.
- [x] Verify ordinary dirty and linked-workspace/context handoff and declared deliverable destinations. Nested submodule metadata remains a documented limitation.
- [ ] Verify native and in-app notifications, disconnection handling and reconciliation. Native parser/action tests pass; GUI end-to-end checks remain.
- [ ] Verify complete CLI/native UI flows and source/release packaging.
- [ ] Pass regression suites and native builds on the candidate.
- [ ] Complete independent adversarial and security reviews; fix and recheck findings.
- [ ] Update PR #3's body to reflect the final implementation and evidence, then mark ready.

## T3 adapter, after fleet readiness

- [ ] Bring #26 forward onto the verified fleet branch without rewriting shared history.
- [ ] Implement the adapter design and its acceptance checklist.
- [ ] Run the isolated rejection/recovery experiment and implement any required T3 integration hook.
- [ ] Complete tests, packaging and independent reviews; update #26's evidence and review state.

## Evidence so far

The focused production-model freshness/failure tests and the full regression
suite pass. The fleet execution suite passes all 84 checks after replacing its
host Cursor dependency with a synthetic executable. The original full regression
attempt failed without a diagnostic; the rerun with failure-location reporting
passes, so that first failure has not been attributed to a product defect.

The native release build and full regression suite also pass with the native
Codex reader and structured output. Eleven reader tests pass, including a
synthetic native JSON-RPC process. The native fleet UI parser/action suite passes. Transport passes 339 checks with mandatory live SSH and no skips. Sync passes
635 checks across all 75 sections. No full fleet-completion claim is made yet.

Review fixes now cover credential gating for embedded MCP and TOML escapes,
settings-only QA import, installer admission, portable linked-worktree metadata,
retry request retention, declared deliverable transfer, and peer monitoring
without the original dispatcher. Native parsers now consume actual CLI lifecycle
values and gate execution actions by task role. Focused security tests pass;
independent follow-up found no remaining demonstrated security finding in these
changes. The native tests and release build pass. Final regression checks remain
in progress before this batch is recorded as complete.

The journal now retains successful and failed polls and loop quota/success
outcomes. Approved peers exchange bounded observations with origin validation,
unchanged timestamps and replay deduplication. Twelve reader tests, seven journal
tests, a two-peer exchange test and the full loop regression pass. Independent
security and correctness follow-ups are clear for this journal scope. This does
not yet establish verified account identity or apply shared rejections to
scheduling; token and provider-session fields remain explicitly unknown.

Task telemetry now reads structured provider output. Claude whole-tree model
buckets and narrower main-agent fallback have distinct scopes. Codex cache input
is not double-counted. Session IDs and reported counts reach the journal on
successful and failed turns; account attribution remains the next dependency.
The full loop suite passes with a synthetic Codex JSONL process, including a
journal assertion of 60 total tokens and 30 cached input tokens. Nine journal
tests and focused provider-result parsing checks pass. `agents usage summary`
deduplicates task observations and splits mixed-model buckets without adding
the aggregate again. These tests establish behavior, not live token totals.

Loop selection now consumes structured measurements, retaining all limit buckets
and refusing stale, future-dated or incomplete readings. Focused tests cover
custom windows, explicit restrictions, missing resets and malformed percentages.
The full regression and release loop build pass. Independent correctness and
security reviews are clear after fixing invalid fallback percentages. This does
not yet connect journal rejections to shared scheduling.

Durable execution restrictions now constrain fresh measurements. Independent
rejections survive diagnostic retention; successful invocations must have begun
after the rejection before they establish recovery. Model/route matching,
out-of-order replay, verified cross-peer account matching, explicit reset expiry,
and local enrollment continuity have focused coverage. Outcome identity pinning,
pre-enrollment state transfer and paginated exchange remain required. The full
regression, 17 journal tests, 16 reader tests and release packaging pass. Packaging
used ad-hoc signing and did not install the app. Independent follow-up reviews
are clear after the concurrency and reset fixes.

Fleet usage exchange now uses immutable, recipient-bound snapshots with bounded
pages and atomic receiver publication. A signed transport test transfers 8,106
durable restrictions across two ticks while preserving the receiver's previous
state until completion. Twenty-three journal tests cover cursor replay, page byte
bounds, concurrent staging replacement and snapshot consistency. Independent
correctness and security follow-ups are clear. The full regression, release
packaging and all 635 sync checks across 75 sections pass. Packaging used ad-hoc
signing and did not install the app.

Pre-enrollment observations now transfer with their original IDs, origins and
timestamps. Snapshot schema 2 records the approved sender's ownership assertion
for its previous local UUID, atomically with complete publication. Signed
three-peer tests verify enrollment, single token attribution and later recovery.
Twenty-six journal tests pass, and independent correctness and security reviews
are clear. Full regression, release packaging and all 635 sync checks across 75
sections pass. Packaging used ad-hoc signing without installation.

Claude identity evidence was corrected after inspecting provider-distributed
Claude Code 2.1.283 and running `claude auth status --json` with fabricated
credentials and account metadata in a temporary HOME/config directory. It exited
0 with `loggedIn: true` and echoed the synthetic email and organization. No real
credentials or model invocation were used. The command's identity is now only a
login hint, never a verified account used for cross-machine restriction matching.
The [canonical CLI documentation](https://code.claude.com/docs/en/cli-reference)
describes authentication status, but does not promise a server-validated identity
response. Authenticated account evidence remains required before launch binding.

Authenticated Claude measurement identity now comes from the provider client's
OAuth profile endpoint, using the same captured bearer as the allowance read.
Stable account and organization IDs are hashed; no raw profile data is retained.
A failed profile lookup cannot create verified identity, redirects are refused,
and credential changes during the read invalidate the sample. Twenty-three reader
tests and 26 journal tests pass. Live September 26 probes found HTTP 401 for both
local Claude profiles' expired tokens; the M5's five configured Claude profiles
returned credential-store-unavailable over SSH. Those probes establish current
unavailability, not a successful live identity attribution. Launch binding remains
required, and no login, refresh, Keychain unlock or app installation was performed.

The full regression suite passes with the authenticated measurement reader.
Independent correctness and security reviews report no actionable findings in
this change. Successful live authenticated identity and launch attribution are
not claimed by those synthetic checks.

Provider lifecycle diagnostics now distinguish receiving-Mac snapshot acceptance
from unverified refresh coordination and revocation. The current contract is in
[fleet authentication](fleet-authentication.md). Cursor preserves opted-in MCP
and settings sharing while explicitly excluding its machine-wide login. All 639
sync checks across 75 sections pass, including a two-peer Cursor MCP regression.
Independent correctness and security reviews are clear for this correction.

Execution readiness now passes 97 checks, including requirements and preference
filtering before completion-time ranking, explicit pins, observer monitoring,
no automatic retry, and recovery of a missed completion. The disconnection test
uses a release barrier instead of a six-second task: the previous fixture could
finish before links were cut. It now blocks the worker's return notification too,
proves the dispatcher remains unreachable after worker completion, and requires
reconciliation to recover the result. Independent reviews are clear. The native
parser/action suite also passes; native GUI end-to-end verification remains open.

The native usage panel now reads structured observations, including every limit
bucket, verified measurement account, restriction reset and credit/spend evidence.
Provider restrictions contribute zero runnable headroom without inventing a
utilization percentage. Unknown readings have a Refresh action instead of a
false signed-out or exhausted label. Model tests cover restricted/healthy and
restricted/unknown combinations, malformed data, missing timestamps and resets,
and model-specific limits. The full regression suite and focused usage suites
pass. Independent correctness and security reviews are clear for this scope.
The actual SwiftUI detail component was rendered at 360 points and visually
inspected with synthetic evidence. The QA app package builds and validates with
ad-hoc signing; it was not installed. This component check does not complete the
remaining native fleet notification and end-to-end GUI acceptance checks.

Numeric usage at N2's 95% reserve now stays distinct from a provider rejection.
The structured feed and journal retain the measured percentage and no invented
restriction; legacy TSV emits `local-reserve` so all CLI selectors still exclude
that slot. Loop selection names the reserve separately. A provider rejection no
longer fabricates 100% utilization in legacy columns. Present but unreadable
limit buckets make the reading unavailable, including malformed falsey container
values. All 27 reader tests, focused slot tests and the full regression suite
pass; independent follow-up reviews are clear. The QA app package builds and
validates with ad-hoc signing, without installation.

A fresh local Codex 0.157.1 read on September 26 at 08:47 UTC returned verified,
distinct measurement identities: Default at 1% weekly usage, ExpoIO at 100% with
an explicit provider restriction. The sanitized observations are in
[the local Codex audit](audits/usage-2026-09-26-local-codex.json). No model turn was
started. This is local measurement evidence, not a new M4/M5 account comparison
or proof of the identity used by an execution process.

The installed Codex CLI's generated experimental schema includes
`GetAccountResponse.workspaceRouting`, thread/turn `approvalsReviewer`, and
external-token authentication. The ordinary schema omits the experimental
routing field. The [official app-server documentation](https://learn.chatgpt.com/docs/app-server)
describes externally supplied tokens and host-owned refresh; this is a possible
binding mechanism, not an implemented N2 launch receipt. At that stage, the loop
executed a separate CLI process after measurement. Claude's
[documented authentication precedence](https://code.claude.com/docs/en/authentication)
also permits project/settings and environment credentials to change the route.
Execution identity must therefore remain explicitly unverified until the launch
path itself establishes and preserves the account binding.

The Codex allowance reader now uses a shared provider-native stdio client, which
can retain one connection through a future launch operation. It rejects account
changes during the read and an allowance response naming a different account.
Read and write deadlines, message bounds and process-group cleanup have 11 real
subprocess fixtures, including an exited server with a TERM-ignoring descendant
holding its pipes. The 27 reader tests, full regression, native UI contract suite
and QA packaging pass. A synthetic read from the built app confirms the bundled
reader loads its bundled RPC helper. Independent follow-up reviews are clear.
The QA build was not installed. A live read through the refactored client kept
both local Codex identities verified, with Default at 2% weekly and ExpoIO at
100% with a provider restriction. This change establishes the shared connection
code. The subsequent account-bound launch below replaces the separate launch
for verified Codex file-credential slots; other providers still need binding.

The shared client now has explicit external-token pinning and account validation.
A failed pin disables further requests. Once bound, login/logout replacement is
refused; an observed account change or renewal request immediately invalidates
the connection. Seventeen subprocess tests cover these cases, including raw-send
attempts, unsupported mode and invalid credentials. The full regression suite
passes, and independent correctness/security follow-ups are clear. QA packaging
and a synthetic pin/validate through the bundled client pass with ad-hoc signing
and no app installation.

An isolated Codex 0.157.1 experiment used the existing Default access token only
for account/allowance reads. It selected the same verified account, created no
`auth.json` in the disposable home and left the canonical credential file bytes
unchanged. No model turn was started. Sanitized evidence is in
[the external-auth audit](audits/codex-external-auth-2026-09-26.json). The public
[app-server documentation](https://learn.chatgpt.com/docs/app-server) describes
host-supplied tokens and host-owned renewal, while the installed experimental
schema still labels the mode internal/unstable. This is tested capability for
that version, not a stable compatibility promise.

This helper pins authentication only. The execution owner must enforce home
isolation, validate project/provider routing and the selected profile revision,
handle renewal for the same account, and bind session/token outcomes to the
result. A notification not yet consumed cannot prevent an already-sent request.
The subsequent bound-turn implementation connects this helper to the loop for
verified Codex file-credential slots. Broader execution coverage remains open. No merge, installation or deployment was performed.


Codex measurements now check effective provider configuration before and after
reading allowance. A saved ChatGPT login does not supply headroom for a custom
provider. Custom OpenAI/ChatGPT endpoints, inherited `OPENAI_BASE_URL`, reserved
provider overrides and providers that do not require OpenAI authentication
return `no-usage-api`. Malformed configuration and a route change during the
read fail closed. Unsupported endpoint routing is not evidence of exhaustion.

The [native routing audit](audits/codex-provider-routing-2026-09-26.json) exercised
Codex 0.157.1 with disposable homes and synthetic configuration, without
credentials or model turns. User-level provider and endpoint overrides were
visible through `config/read` and excluded by the production reader. Project
provider overrides were ignored, matching the current
[official configuration documentation](https://learn.chatgpt.com/docs/config-file/config-advanced).
This corrects an earlier assumption that current Codex permits project-local
provider redirection. Claude's documented precedence is separate. The selected
execution process and its command-line overrides still require launch binding.
The guard checks the measurement process; it does not establish an execution
receipt or support quota accounting for custom gateways.

Focused verification passes all 21 protocol and 27 reader tests, with scoped
correctness and security reviews clear. The EOF fixture now allows interpreter
startup under build load while retaining the closed-stream error requirement,
process/reader cleanup checks and bounded completion assertion. A fresh normal
Default external-auth allowance read still verified its account and left the
canonical credential file unchanged. These checks did not execute a model turn.
The final full regression suite also passes.


Verified Codex slots now use one account-bound native connection for execution.
The loop carries the measured account hash into `agents run --bound-account`,
which reads the selected file credential, creates a private execution home and
pins external authentication with ephemeral credential storage. A different
account or unsupported binding fails without launching through the legacy path.
The selected configuration, `AGENTS.md`, `AGENTS.override.md` and managed config
are copied privately; rules, skills and plugins retain their selected resource
paths. Authentication storage, sessions and the whole home are never linked.

The native thread must return the expected provider, working directory,
`on-request` approvals, `auto_review` reviewer and workspace-write sandbox before
any turn starts. Auth transitions and host approval requests fail closed. A
terminal result is checked against the same process's account and route, then
returns a session/account receipt and reported thread token totals. Model reroutes
leave model attribution unknown. The loop requires exactly one matching receipt
before accepting a successful bound turn; unbound provider output cannot claim
one. Journal restrictions and token observations now carry this verified account.
Missing token counts remain unknown. Non-Codex and unverified legacy executions
remain unverified; they are not promoted using a cached measurement.

Execution servers share the loop's tracked process group. The owner records a
group marker before server admission, cleans descendants after wrapper exit and
removes the private configuration home. Planner groups are persisted too. A
close-on-exec planner lock and cancellation checks prevent a live draft pause
from retrying another profile. Recovery can stop work after parent death using
the state record or group marker; interrupted drafts still need a valid plan and
approval before execution can resume.

Verification includes nine subprocess runner tests, the 21 protocol tests,
Swift launch-to-journal tests and three actual planner-process fixtures. These
cover wrong account selection, permissions/provider mismatch, renewal requests,
rejected host interaction, malformed counts, missing/duplicate/mismatched
receipts, wrapper SIGKILL, parent SIGKILL, marker-only recovery and live pause
with a second healthy profile. Scoped correctness and security reviews are
clear. The [native preflight audit](audits/codex-bound-preflight-2026-09-26.json)
used Codex 0.157.1 and reached the production bound-thread checks with the expected
account and approval/sandbox settings. It intercepted `turn/start` before sending
it, made no model turn, created no isolated auth file and left the canonical
credential file unchanged. Synthetic counts do not prove live token accuracy.

Remaining before readiness: same-account token renewal, keychain-only credential
capture, complete resource parity including MCP authentication/hook trust,
broader live lifecycle evidence, native denial reset propagation, stable fleet profile/revision bindings,
Claude execution binding, and the other fleet acceptance items above. A live
canonical-home authentication probe was rejected by automatic approval review
because it might mutate persistent account state. The implementation and
successful native preflight use an isolated home instead; no canonical-home
mutation or credential refresh was performed. PR #26 remains subsequent work.


Final regression and ad-hoc QA packaging pass for the bound-turn implementation.
The built app's bundled helper completed a synthetic bound turn and returned the
expected account receipt and token counts; its helper bytes match source. The
app was not installed.

Two controlled live checks now complement the fixtures. The
[Default turn](audits/codex-bound-live-2026-09-26.json) completed with the expected
fixed response on its verified account. Codex reported 14,696 input tokens,
including 12,160 cached input tokens, and 11 output tokens, totaling 14,707. Only
user and agent message items were observed. The
[ExpoIO rejection](audits/codex-bound-restriction-2026-09-26.json) was attempted
only after a fresh explicit restriction, then returned `usageLimitExceeded` on
a different verified account. It reported no token totals, which remain unknown.
Both checks used empty isolated homes and in-memory tokens, left canonical
credential bytes unchanged and created no isolated auth file. These establish
live success and rejection attribution through the native connection, not full
fleet or T3 integration, resource parity, refresh behavior, or an independent
reconciliation against provider billing. Rejection reset propagation still needs
work; no reset time was invented for the native rejection.


### Native quota reset evidence

The bound runner now retains an explicit retry time from a terminal native
`usageLimitExceeded` or `rateLimitExceeded` error. It converts a complete relative
seconds/minutes/hours expression at receipt time, or a timezone-qualified ISO
timestamp, into UTC in the verified execution receipt and sanitized failure message. The
loop records only the receipt timestamp with the verified account rejection,
including explicit unknown. Conflicting model text cannot supply a reset. Raw error messages and
additional details are never copied into the journal. Ambiguous local dates,
compound expressions, multiple retry instructions, expired values and implausibly
distant dates remain unknown.

The [official app-server documentation](https://learn.chatgpt.com/docs/app-server)
and the installed Codex 0.157.1 `TurnError` schema expose error text and error
classification, but no typed rejection reset field. Account `resetsAt` values
belong to individual quota windows. This implementation deliberately does not
infer which window caused a rejection or use a rolling-window reset to clear a
credit/spend restriction. This is conservative compatibility parsing, not a
provider guarantee about error-message formatting. A fresh percentage poll still
cannot clear a durable rejection.

Subprocess fixtures cover explicit and ambiguous resets, redaction and account
receipts. The Swift integration drives the real runner through `runTurn` and
checks the retained journal timestamp. These are deterministic fixtures; the
previous live ExpoIO rejection remains reset-unknown, and live recovery is still
an acceptance item.

The final full regression suite and ad-hoc QA build pass. The packaged helper
passes the reset fixture and matches the source. Scoped correctness and security
reviews are clear after fixing malformed timezone normalization and model-text
reset precedence. No credentials were changed and no app was installed.


### Stable profile identity

The [profile identity contract](profile-bindings.md) adds persistent opaque IDs
and `agents profiles --json`. Named profiles carry their IDs through the signed
sync protocol; Default remains machine-local. Missing, legacy, invalid,
conflicting and duplicate metadata remain explicit. These IDs are not provider
account verification. Scoped routing revisions now describe the N2 binding
inputs; runtime account verification and adapter binding remain open.

Initialization is explicit for existing legacy markers. Ordinary upgrade/sync
preserves legacy bytes until one machine initializes and propagates the agreed
replacement. Live markers precede child resources, and the receiver rejects
child-first transfers until metadata exists. Deletion markers follow child
removals. Disposable signed-peer tests cover clean replication, legacy upgrade,
interrupted child-first recovery, distinct Default identities, duplicate IDs,
concurrent initialization, malformed payloads and same-name identity conflicts.

The six metadata tests pass, including retention of a pending conflict when a
validated child write fails. All 639 sync checks across 75 sections pass after
updating adopted-storage fixtures to retain identity and direct responder
fixtures to provide metadata. The CLI regression suite, ad-hoc QA build and
packaged signed-peer/recovery probes pass. Scoped correctness/security reviews
are clear. No live profile metadata was migrated and no app was installed.

The [managed-auth concurrency audit](audits/codex-auth-concurrency-2026-09-26.md)
adds a canonical provider constraint to the remaining authentication work:
file-conflict handling does not prove safe concurrent renewal of one copied
Codex login across machines. Renewal ownership remains unimplemented.


### Profile routing revisions

`agents profiles --json` now supplies a revision of N2's profile routing inputs.
It records literal provider environment values, configured and resolved paths,
and the working directory needed for relative bindings. Repeated samples must
agree on profile metadata, machine identity and routes before a revision is
published. Missing or conflicting identities withhold it. Account identity stays
unknown until separately verified in the provider execution process.

Eight routing tests cover stable reads, symlink changes, Default fallback, XDG
paths, missing routes, metadata and machine drift, wrong roots, rename behavior
and equality with an actual relative-path launch. Scoped correctness and security
reviews are clear. The ad-hoc QA build and packaged CLI snapshot/symlink checks
pass, with packaged helper bytes matching the source. The contract explicitly
excludes credential and provider-config contents from this routing revision.
The full regression suite passes with both metadata and routing tests included.


### Renewal ownership plan

The CLI now states the canonical constraint on concurrent managed-auth copies
instead of describing file conflict detection as refresh coordination. The
[renewal ownership plan](fleet-auth-ownership.md) separates fleet account identity
from refreshable grants and specifies one owner, secret-response transport,
same-account execution renewal, migration and provider acceptance evidence.
These remain implementation requirements. No live grant has been migrated or
renewed by this work. A disposable enrolled CLI check confirms the new
provider-concurrency diagnostic; shell syntax and diff checks pass.

### Bound renewal protocol

The shared Codex connection now has a trusted owner-source integration point.
It authenticates each replacement access token in a separate ephemeral native
connection before replying to the execution server. Wrong-account, malformed,
replayed, unchanged-token and late responses invalidate the binding. Incoming
request age survives buffering and queue backpressure. Production runners do
not supply this source yet, so the broker and ownership lifecycle remain required.

Thirty-one subprocess protocol tests pass, including a saturated queue with more
than 128 notifications and repeated stalls shorter than 100 milliseconds.
Twelve bound-runner tests pass, including same-account
mid-turn renewal with session/token continuity and rejection of a changed account
after renewal. The QA build and packaged mid-turn fixture pass; packaged helper
bytes match the source. These are synthetic protocol tests, not live grant
renewal or complete fleet authentication evidence. The full regression suite
passes, and independent correctness/security review is clear after both
backpressure deadline fixes. The short-stall regression also fails against the
previous implementation, confirming that it detects the reported defect.


### Owner response authentication

A private response codec now signs and verifies owner token replies without
spooling secret payloads. It binds the owner, recipient, nonce, grant, ownership
generation, expected account and expiry; concurrent replay accepts at most one
response. Ten tests use real disposable Ed25519 keys and synthetic tokens to
cover tampering, wrong bindings, deadlines, replay and secret-file/argument
exclusion. Scoped correctness and security reviews are clear. The encrypted
carrier, consent enforcement and owner service remain required; the ordinary
fleet reply path still uses temporary files and is unsuitable for tokens.
The QA build passes; its packaged codec matches source bytes and passes all ten
real-key tests. No live credentials were used or changed.

### In-memory owner-response transport

The private token carrier now uses approved, pinned SSH peers while retaining
public request signing. It never uses the ordinary reply-file decoder. Bounded
reply bytes stay in memory until owner/context verification succeeds. Nonzero
carrier exit, revocation, wrong key, malformed output and timeout reject the
response. A final-use guard prevents route edits from selecting `exec` or
bootstrap credentials after admission.

Seven disposable transport tests cover signed framing, SSH options, response
persistence, route changes, revocation, failed and oversized carriers, timeouts,
inherited output pipes and wrong recipients. Independent correctness/security
reviews are clear after the carrier race fix. The owner endpoint, grant consent,
renewal and production runner connection remain unimplemented.

The owner request now includes an explicit rejected token generation, separate
from ownership generation. Initial fetch uses null; renewal names the opaque
generation the client rejected. Twelve codec tests include missing, malformed
and tampered generation fields and reject a signed stale-generation response. This supplies correlation for the future owner's
coalescing logic; it does not implement that logic.

The full fleet run passes with live SSH required: 339 transport checks, zero
failures or skips; 639 sync checks across all 75 sections; 97 execution checks;
and native UI parser/action checks. The final QA package matches the source and
passes all 19 codec/transport tests. Scoped reviews are clear after rejecting
stale-generation responses. No live provider credential was used or renewed.

### Private owner grant state

The internal owner store now serializes grant operations across processes and
persists `renewing` before allowing a native provider attempt. Requests rejecting
a known older generation reuse the replacement; unknown generations cannot
rotate the grant. Activation and renewal completion require an account check
bound to the exact credential-file revision. Retirement fences old bindings
across ordinary restart, without claiming rollback-resistant transfer.

Fifteen disposable state tests cover process concurrency, crash recovery,
consent, account and ownership mismatches, private-file validation, changed
credentials and persistence failure. Eight competing processes produce one
simulated provider attempt and receive the same replacement generation. These
fixtures do not authenticate to a provider. Native verification/refresh,
login/reset, migration, the owner endpoint and the production runner connection
remain required before this can renew real fleet credentials.

Scoped correctness and security review is clear after fixing parent-directory
persistence during store/grant creation. All 15 owner tests pass from source and
from the ad-hoc QA package, with helper byte parity verified. The adjacent 12
codec and seven transport tests also pass. No app was installed and no live
credential was read or renewed for this state-layer verification.

### Native owner renewal and verification

The owner adapter now invokes Codex's managed `account/read` refresh operation
inside the private grant home. It closes that process, syncs the saved credential,
then independently verifies the exact access token in an ephemeral app-server.
Only the same verified account and credential revision can activate a replacement
generation. Inherited authentication, endpoint and proxy variables are excluded.

Eight synthetic subprocess tests cover activation, renewal, stale requests,
account mismatch, failed verification, uncertain persisted outcomes, unchanged
tokens, wrong provider, timeouts and actual owner SIGKILL. The managed process's
supervisor retains the grant lock after owner death until completion or the
original deadline, preventing reconciliation alongside an orphaned refresh.
These fixtures do not establish live provider renewal. Login/reset, migration,
the authenticated owner endpoint and production runner wiring remain required.

Scoped correctness/security review is clear after fixing lock lifetime across
owner death. All eight native tests pass against source and packaged helpers,
with byte parity verified. The 31 existing protocol tests, 12 bound-runner tests
and 15 grant-state tests pass. The ad-hoc QA build succeeds and was not installed.

### Authenticated owner endpoint

The signed fleet `auth-token` handler now enforces sender/recipient and owner
identity, current peer approval/key/revocation, grant consent, ownership generation
and expected account. It invokes the native owner under the grant lock and signs
the token response in memory. Non-SSH delivery is refused; token replies bypass
the ordinary reply-file path. Approval is rechecked after signing.

Seven synthetic endpoint tests pass through real signed fleet dispatch for fetch,
renewal and stale-generation reuse. They also cover consent/account/recipient
mismatch, unknown grants, non-SSH delivery and revocation during signing. No live
provider credentials are involved. Profile-to-grant registration, login/reset,
migration and production execution integration remain required.

Scoped correctness/security review is clear after rejecting token verbs in the
generic spooling client and rejecting malformed verb/header spellings. Seven
endpoint and seven transport tests pass. The final QA build passes; all seven
endpoint tests pass with packaged helper byte parity. That packaged fixture
omits only the QA root-redirection marker to retain disposable peer roots.
The complete fleet regression is running separately and is not claimed complete
for this checkpoint.

### Public ownership record contract

`fleet-auth-binding.py` now defines a credential-free profile-to-grant record
with exact profile, owner, grant, ownership-generation and account bindings.
Only an active locked grant can produce it. Replacement requires the expected
prior revision while the caller holds the shared sync resource lock. Unknown
schemas and conflicting bytes remain untouched. The record expresses routing
intent, not provider verification or scheduling eligibility.

Five tests pass from source and packaged helpers, including an actual CLI-created
mode-0755 profile, private record permissions, stale replacement revisions,
unknown schemas, duplicate fields, profile mismatches and retired grants. The
ad-hoc QA build passes and helper/CLI byte parity is verified. Registration,
replication/conflict handling, migration and runner consumption remain unwired.

The previously running broad fleet regression has completed successfully with
live SSH required: 339 transport checks with no failures or skips, 639 sync
checks across all 75 sections, 97 execution checks and native UI checks. Final
endpoint framing guards additionally passed the focused source/package endpoint
suite after they were added during that broad run. This is checkpoint evidence,
not a claim that the final PR candidate has completed acceptance. Scoped reviews
of the public binding module are clear after the profile-directory fix.

### Owner-backed bound execution

The session client now freezes a public ownership record, pins the measured
account and tracks one token-generation chain. Remote fetch/renewal uses signed
private fleet transport; local owners use the same private grant lock and native
renewal path. Failures invalidate the session instead of selecting another grant.
The existing RPC verification authenticates every token before execution.

`agents run --bound-account` forwards its root and selected profile. A present
ownership record requires ready, nonduplicate profile metadata and the expected
account. That route ignores legacy credentials and supplies the pinned renewal
callback. Invalid records fail without a legacy fallback. Profiles without a
record retain their existing route until explicit migration.

Seven integration tests pass from source and packaged helpers, including the
actual bound CLI and a full mid-turn renewal through signed dispatch with an
unchanged account/usage receipt. Tests preserve deliberately invalid legacy
credentials, reject account mismatch and malformed records, and cover a timeout
race. The 31 protocol and 12 existing bound-runner tests also pass. The ad-hoc QA
build and helper/CLI byte parity pass; packaged fixtures omit the QA root marker
and use disposable HOME/profile roots. Registration, migration, owner-backed
measurement and general unbound CLI/T3 routes remain required.

Owner-backed measurement is now connected to the same resolver and token client
as bound execution. Fourteen integration tests cover both flows, including
initial token expiry after idle time, exactly one renewal followed by reuse,
failed replacement verification without a refresh loop, and zero model turns
when a replacement authenticates to the wrong account. Denied owner access,
wrong bindings and URL overrides expose no headroom. The journal and native UI
retain an explicit owner-unavailable state; a native regression prevents that
state from retaining an earlier healthy capacity gauge.

Initial recovery handles only a valid native unauthorized-refresh request. It
closes the unbound process and independently authenticates a replacement under
the original deadline before publishing usage or starting execution. Registration,
migration, general unbound CLI/T3 routes and live provider acceptance remain
required. These tests use synthetic providers and disposable fleet identities.

The combined execution/measurement checkpoint passes all 14 integration tests
from source and packaged helpers with byte parity. The consolidated usage suite
passes native freshness/restriction/failure checks, 31 RPC tests, 12 legacy bound
runner tests, actual loop launch/journal/crash/cancellation checks, 27 usage
reader tests, 26 journal tests, signed paginated exchange of 8,106 restrictions,
enrollment identity continuity and task/slot parsing. The QA build passes.
Independent correctness/security reviews are clear after the initial-expiry fix.
No app was installed and no live provider renewal was performed.


### Local registration and owner-aware routing revisions

`agents fleet auth register Profile --grant ID` publishes an already-active,
verified local grant under the profile metadata and binding resource locks.
Existing records require `--expected-revision`; unresolved binding conflicts,
duplicate profile IDs and known legacy credential files refuse registration.
`status`, `allow --peer ID` and `deny --peer ID` expose public state and explicit
consent. Allowing a peer requires current fleet approval; denying a revoked peer
remains possible. This command does not create a login or perform migration.

Routing inventory now includes the validated public owner binding and its
revision under `n2-profile-routing-v2`. Changing the grant or ownership generation
changes the configuration revision. Invalid, conflicting and dangling owner
records suppress the configuration revision. A binding is routing intent, so the
inventory still reports account identity as unknown until provider verification.
Neither credentials nor a provider process are needed to read this inventory.

Nine registration/sync tests cover publication, revision checks, credential and
conflict refusal, consent enforcement, serialization against a pending slot
writer, and real signed replication followed by authenticated owner fetch.
Nine routing tests cover owner changes alongside existing route/path stability.
Public records replicate as settings and arrive private with validated profile
identity. Registration and incoming Codex writes share a per-slot gate; managed
slots reject auth/MCP and credential-bearing payloads even with auth sharing on.
Ordinary record tombstones are refused. Pending ownership conflicts block
routing, measurement, execution and credential sync even without a local record.

These gates do not establish that historical credential copies have been
removed. Migration inventory, offline peer handling, fresh login/reset, explicit
retirement and general CLI routing remain required before readiness.


The registration increment also passes 15 owner-client tests, 27 usage-reader
and 12 legacy runner regressions. Registration, routing and client tests pass
against staged packaged resources. The staging omits the QA-root selector and
uses private fixture HOME directories; the actual packaged helper bytes match
source. No app is installed and no live login grant is changed by these tests.
Scoped correctness and security reviews found canonical and staged ownership
conflict gaps; both are fixed and regression-tested.

The broad sync regression completed with 639 passing checks across all 75
sections. That run began before the final staged-conflict guard was added;
focused source and packaged tests verify that final guard and its consumers.


### Fresh local owner login

The local `agents fleet auth login` path now creates an empty private grant,
shows the native device-code challenge, correlates completion, independently
verifies the saved account, and publishes through normal registration locks and
revision checks. Replacement requires the old revision and retains the old
account unless `--replace-account` explicitly permits changing it. Existing
grants remain separate for bound sessions. A remote-owner binding is refused
rather than taken over locally. No shared profile credential file is imported.

Twelve native-owner tests and fifteen registration/login tests cover successful
login, bad challenge/completion, timeout/cancellation, changed-account refusal,
explicit replacement, profile changes during login and remote-owner refusal.
Fifteen client regressions still pass. A correctness review found orphan
publication after cancellation; process-group cleanup and SIGINT/SIGTERM
regressions fix it, and the reviewer independently reproduced the successful fix.
The separate security review remains outstanding: automatic approval review
rejected that reviewer's read-only checkout access as outside its recognized
scope, even after the active goal and PR checkout mapping were supplied.

Non-owner challenge/status/cancel transport, lifecycle repair, migration and live
provider acceptance remain required. Failed publication retains the verified
private grant for explicit recovery; it does not overwrite newer profile intent.

The final ad-hoc QA package passes all 42 native-owner, registration/login and
client tests against staged packaged resources with private fixture HOME roots.
The QA selector is omitted from staging; helper byte parity is verified. The app
is not installed, and the tests use synthetic providers rather than live grants.


### Local owner recovery and retirement

`agents fleet auth reconcile Profile` verifies a saved uncertain renewal without
issuing another refresh. `grants Profile` reports pending/abandoned local grants
without waiting for an active login lock or exposing credentials. `retire Profile
--grant ID` disables an explicit grant belonging to that profile, clears consent,
and preserves the public owner fence. Status recognizes broker retirement.
Retirement does not claim provider revocation or removal of historical copies.

All 19 registration/login/recovery tests pass from source and staged packaged
helpers, including saved-result recovery, wrong-account rejection, retired token
refusal, pending inventory, unrelated-file tolerance and wrong-profile refusal.
The ad-hoc QA package and helper parity pass; no app is installed. Correctness
review is clear. The independent security-review gate remains outstanding from
the prior automatic approval rejection. Remote orchestration, migration, broader
execution routing and full fleet/provider acceptance remain required.


### Remote login wire and private carrier

Remote login messages now bind the operation/action/profile and current owner
intent, use a separate signature namespace, and travel through the pinned private
carrier without reply spooling. Nine new wire/transport tests pass, including
real signatures, wrong-request refusal, account-replacement checks, namespace
separation and generic-carrier refusal. Existing token response and transport
regressions pass, and correctness review is clear. The owner endpoint and
operation worker are not implemented by this increment; remote login is not yet
usable. The independent security-review gate remains outstanding.

The ad-hoc QA package passes all 28 login-wire/token-response/token-transport
tests with helper byte parity and private fixture HOME roots. Seven endpoint and
fifteen owner-client source regressions also pass. Packaged staging omits the QA
root selector, and no app or live credential change is performed.


### Remote owner login implementation

The owner endpoint, persistent worker and CLI now implement remote login with
separate management consent, explicit finish/publication, cancellation, expiry,
same-account access continuity and ordinary public-binding sync. Nine disposable
remote-login tests pass. They include the real CLI from requester to owner and
back, signed lock-contention responses, continued login during renewal contention,
revocation, stale intent, cancellation and truthful pending-sync reporting.
Nine wire tests and nineteen management tests also pass from source.

The correctness review found that a two-second grant-lock timeout was being
mistaken for revocation. Workers now retry contention at initial/final
authorization and during monitoring; the endpoint returns signed `busy` for
retryable contention. Revocation still stops the worker. This checkpoint does
not establish live-provider acceptance, restart coverage, or the
outstanding independent security-review gate. PR #3 remains draft and PR #26
remains design-only.

The ad-hoc QA bundle passes the same 37 remote-login, wire and management
tests using byte-matched bundled helpers and disposable fixture homes. The first
packaged staging attempt omitted the synthetic provider fixture; correcting the
test staging allowed all checks to run. No app was installed or deployed.


### Migration inventory and local pending state

The CLI now inventories top-level credential-file presence, retained sync conflict
copies and unobserved peer copies without opening credential contents. It reports
keychain, unmanaged processes and revocation as unknown. A durable local pending
marker preserves legacy files while blocking N2 Codex launches, login, bound
execution, measurements, routing admission and credential-bearing sync writes.
Five integration tests cover these paths, repeat initiation, corrupt/dangling
markers, retained conflicts and existing-owner refusal. This is an incomplete
migration workflow: fleet acknowledgements, retirement/archive, keychain handling
and completion/repair are still required, and no live profile has been migrated.

Validation for this checkpoint: all 5 migration, 9 routing, 27 usage-reader,
19 account-management and 26 usage-journal tests pass. The ad-hoc QA bundle
builds and passes the 5 migration tests with matching helper bytes and disposable
homes. Shell syntax and diff checks pass. No live credential changes, installation
or deployment occurred.


### Explicit migration abandonment

A pending migration now has a revision-checked abandonment command with explicit
legacy-access acknowledgement. It preserves credentials and a private atomic
history record, reports `legacy-unmanaged`, and refuses newer state or owner
intent. Eight migration tests pass, including interruption before and after
barrier removal and idempotent retry. Successful migration completion, malformed
state repair, peer acknowledgement, keychain handling and retirement remain
unfinished. No live migration or abandonment was performed.

The ad-hoc QA bundle passes all eight migration tests with byte-matched helpers
and disposable homes. Nineteen existing account-management tests also pass from
source. Syntax and diff checks pass; nothing was installed or deployed.


### Native summary coverage and authentication explanations

The native summary previously omitted unreadable provider slots, so a healthy
sibling could leave a positive summary gauge while another account was unknown.
It now withholds positive overall/profile gauges when measurement coverage is
incomplete and reports how many provider readings are unavailable. A known
restriction still produces a zero-capacity warning, qualified as applying to at
least one provider. Healthy measured accounts remain eligible for next-agent
selection. Per-provider low-capacity notices remain available.

The native parser recognizes `migration-pending` explicitly. Rows, provider
badges and expanded details explain migration and owner-authentication failures;
stale timestamps no longer hide the failure explanation. Icon tooltips refresh
coverage text even when the icon image itself is unchanged.

Production-model Swift tests cover partial coverage, healthy scheduling alongside
an unavailable account, known restrictions alongside unknown readings, and the
new migration state. The native release/QA bundle builds. An offscreen render of
the production details view with synthetic owner and migration failures was
inspected at 340-point width; text wraps without clipping. This is visual fixture
evidence, not the remaining live fleet GUI acceptance.


### Shared owner-bound frontend bridge

Ordinary fresh Codex TUI and app-server launches for owner-managed profiles now
use the owner client through an account-bound relay. The terminal connects over
a private Unix socket; token fetching and renewal stay on the existing private
authentication path. Direct unsupported owner-profile subcommands refuse implicit
unmanaged fallback. Fourteen bridge tests, five WebSocket framing tests, 31 RPC
tests and the bound-loop launch/journal/cancellation regressions pass. The complete
repository suite passes for checkpoint `0b000be`. Successful renewal yields back
to frontend input, and account verification preserves unrelated provider
notifications and approvals before admitting another execution. Three regressions
exercise these paths through the real RPC implementation. Independent correctness
review verified both message-handling fixes. The QA app builds successfully,
and its byte-matched helpers pass all 14 bridge and 5 WebSocket tests under a
disposable home directory. No installation or deployment was performed.

The first full-suite attempt found four owner-client fixture failures caused by
an inherited legacy usage endpoint. The fixture now explicitly clears that
endpoint except in its override-rejection test; all 15 owner-client tests pass.

Persistent session resume/history, frontend usage receipts, concurrent turns,
compatibility and process-lifetime acceptance, and live native TUI/provider tests
remain open. The implementation is not yet ready for deployment or a complete
interactive-route claim. PR #26 remains design-only.


### Frontend turn accounting

Owner-bound frontend turns now record sanitized execution receipts in the same
account-scoped journal as loop outcomes. Cumulative thread counters are differenced
at turn boundaries; missing counters and unknown baselines remain unknown.
Cached input is not added to total tokens. Model rerouting clears model attribution,
and an explicit requested model is retained separately from verified model data.
Quota failures create durable restrictions with only unambiguous reset evidence.
No prompts, outputs, credentials or raw provider errors enter these receipts.

Completion is correlated to the acknowledged turn, including notifications that
arrive before its acknowledgement. Account verification drains late notifications
before publishing a completed receipt. A disconnected or unverified execution
records unknown identity/counts and cannot establish successful recovery. Hard-kill
recovery and durable session history remain unfinished.

Twenty-four bridge tests pass, including an actual CLI/signed synthetic-owner
three-turn run that records 180 tokens and transfers its quota rejection to a peer
journal. All 26 journal, 7 owner-server and 15 owner-client tests pass. The QA app
builds, and its byte-matched helpers pass all 24 bridge tests under a disposable
home directory. Review found and fixed persistent model-override tracking so a later
success clears the matching model-specific rejection. Rejected, unacknowledged
turn requests preserve the previous selection and baseline; independent review
verified both fixes. Live-provider acceptance
and final security review remain open.


### Durable unfinished frontend invocations

The frontend commits an `execution-started` event before dispatching a turn. Its
`execution-unconfirmed` state means no terminal outcome has been recorded; it
does not claim that the process is still running or that execution failed. All
token counts remain unknown. A final receipt uses the same task identifier and
takes precedence in summaries, including equal timestamps and out-of-order peer
exchange. Summary groups expose `unconfirmedTasks` separately. Start events
cannot carry token totals or quota/recovery assertions and never clear durable
restrictions.

A subprocess SIGKILL test reopens the database and confirms that the unfinished
invocation remains visible while the prior quota restriction remains active.
Peer-import tests cover unfinished records, replay and final-receipt precedence.
All 25 bridge and 28 journal tests pass from source and byte-matched QA
packaging in disposable homes. Independent correctness review found no actionable
gaps in the delta. The full repository suite is still running for this candidate. Persistent session resume and provider process
cleanup after a killed frontend remain separate unfinished requirements. Fleet
peers must run a journal version that understands the new event kind; an older
peer rejects the unsupported batch rather than silently discarding these events.


A native Codex 0.157.1 TUI probe reached the private owner bridge and attempted
account bootstrap. It stopped because the synthetic provider account response
lacks the required `planType` field. This is a fixture-contract gap; the probe
does not establish native TUI acceptance or a production bridge defect.


### Concurrent loop process descriptors

The full suite exposed a real pause/concurrency defect: one slow worker finished
before the second worker launched. POSIX-spawned agents inherited unrelated
Foundation pipe writers, preventing synchronous Git reads from reaching EOF until
the worker exited. A deterministic reproduction and independent review confirmed
the mechanism. Both spawn paths now use `POSIX_SPAWN_CLOEXEC_DEFAULT` with explicit
standard-stream file actions. Foreground and detached turn tests and detached
controller tests prove unrelated inheritable descriptors are closed. The bound
worker suite and full repository suite pass with this fix; the pause assertion
remains unchanged and now prints worker outcomes if it fails.

The temporary checkout and logs disappeared during a runtime interruption. The
pushed work was restored at `/Users/sethwebster/Development/n2-agents-fleet-ready`.
The interrupted diagnostic run has no claimed result. Subsequent verification
logs and native compatibility artifacts use durable storage.
