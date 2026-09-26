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
account verification, and configuration revisions and adapter binding remain
open.

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
