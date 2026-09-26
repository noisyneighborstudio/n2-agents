# T3 Code adapter

Status: design for a draft child PR of [fleet management #3](https://github.com/noisyneighborstudio/n2-agents/pull/3). No adapter is implemented by this change.

Refs [fleet requirements #1](https://github.com/noisyneighborstudio/n2-agents/issues/1). Read the [current fleet QA scope](fleet-spike.md) before implementation; the older [fleet design record](fleet-design.md) includes work that is not part of the current QA spike.

## Problem and outcome

N2 Agents is the canonical source of fleet accounts. T3 Code should consume those accounts on the machine running its server. A profile named Default in both applications is insufficient evidence that they use the same account.

The September 25 audit found a concrete mismatch. A T3 Codex session on the M4 exhausted the account represented by N2's ExpoIO profile, while the user watched N2's Default profile on the M5. The matching display names concealed different accounts. The Claude incident also exposed ambiguous credential routing and incomplete historical measurements; its exact M5 reading and credential source could not be reconstructed. The adapter must make future incidents attributable without guessing from names or session folders.

The intended result is that T3 uses an explicit N2 profile, N2 can identify the account actually used by each task, and fleet availability incorporates observed provider rejections. Allowances belong to provider accounts and relevant limit buckets; running the same account on another machine does not create more capacity.

## Ownership and scope

N2 owns shared profile identity, credential lifecycle, machine eligibility, usage observations and scheduling policy. The adapter translates that state into T3 configuration and reports execution observations back to N2. It must not create a second account registry or scheduler.

The first implementation targets Claude and Codex on macOS. It runs beside the T3 server on each participating machine, including when the UI connects remotely. T3 remains responsible for its conversations, approvals and workspace UI.

This design does not select a fork or promise transparent failover. First establish verified profile binding through stock T3's supported configuration. Then test the execution hooks needed for attribution and recovery. A small T3 patch is acceptable if those hooks cannot preserve correctness through supported configuration or wrappers.

## Profile binding contract

Each managed binding needs the following conceptual fields. These are requirements for the shared N2 contract, not claims that #3 already exposes this schema.

| Field | Meaning |
| --- | --- |
| N2 profile ID | Stable across machines and display-name changes |
| Provider and account identity | Verified account and organization where available, separate from profile name |
| Machine ID | The enrolled machine running the T3 server |
| T3 environment and provider instance ID | The exact configuration destination and generated instance |
| Local credential route | Explicit provider home or supported credential reference on that machine |
| Configuration revision | The N2 revision used to generate the binding |
| Verification state and time | Verified, unknown, conflicting or unavailable, with observation source |

Account identity must come from supported provider identity mechanisms where available. Hashing a credential, comparing token expiry or inspecting a session directory does not establish account identity. If identity cannot be verified, record unknown and exclude the binding from automatic selection. Diagnostics may explain how to verify or repair it; they must not substitute a guessed identity.

Resolve local paths on the destination machine. Shared state contains stable identities and intent, not a copied absolute path from another Mac. Credentials remain subject to N2 enrollment, sharing policy and provider portability support. T3 settings and adapter logs must never contain token values.

## Configuration reconciliation

The proposed reconciler generates explicitly managed T3 provider instances from eligible N2 profiles. Preserve unrelated instances, model choices, launch arguments and user settings. Use stable generated IDs, with display names free to change. Keep ownership metadata in an adapter manifest unless T3 explicitly supports that metadata in its schema.

A preview must show additions, changes, removals and conflicts before the first opt-in. Once enabled, routine nonconflicting reconciliation is automatic within that authorization. A user edit to an owned field is drift to explain and resolve, not permission to overwrite it silently. Removing a profile must prevent new launches while retaining enough binding history to explain existing sessions.

Read and validate the installed T3 version and configuration schema. Read-modify-write must detect concurrent edits, use atomic replacement, and leave malformed or unsupported configuration untouched. Do not edit T3's SQLite state to manufacture provider bindings. Verify when T3 loads configuration; if a restart is required, report it and defer interruption of active work. File modification alone is not proof that a running server adopted the binding.

Rollback removes only adapter-owned configuration that still matches what the adapter wrote. Preserve subsequent user edits. Backups and diagnostics follow local file permissions and must not expose secrets contained in unrelated settings.

## Provider routes to validate

T3 exposes provider binary and home configuration. Its current Codex documentation describes an account-specific shadow home that keeps separate authentication while sharing session state from a base CODEX_HOME. These are candidate integration points, not proof of compatibility with every installed T3 release.

For Claude, generate an explicit home route and verify that the launched process resolves the intended identity. Account for path-dependent Keychain lookup and file fallback. A symlink target or matching folder name alone is not sufficient verification.

For Codex, validate whether an explicit isolated home or the documented shadow home is appropriate for the requested session behavior. Shadow-home authentication requires a compatible credential store. Do not copy an entire CLI home to move accounts; credentials and session state have different ownership and transfer rules.

Stable symlinks may be an implementation detail after verification. Switching a global symlink to select an account for concurrent tasks is not an acceptable binding mechanism.

## Execution observations and availability

A managed launch must record the binding, verified account identity, machine, provider, requested model and resulting session identity when available. Pin that binding for the active session. A process restart or resume must not silently select another account.

If wrappers are needed, they must preserve the provider protocol, arguments, stdin/stdout, signals and exit status. Version, discovery and capability probes must not allocate work or rotate accounts. The adapter must not add permission-bypass options or weaken T3's approval behavior.

Report provider limit events to N2 with account identity, source, observation time, affected bucket or model, reset time and rejection reason where supplied. An observed rejection must influence availability even when an older successful poll showed headroom. Preserve uncertainty when scope or reset is unknown. Recovery requires an applicable reset or newer evidence under N2's availability policy.

Keep provider allowance measurements separate from task token attribution. Neither missing measurements nor failed polls imply unused capacity. Deduplicate observations across peers and preserve source timestamps so replayed events do not appear fresh. Core measurement fixes belong to N2's usage work; this adapter consumes that contract and contributes execution evidence.

## Recovery experiment before choosing a T3 fork

Use disposable profiles, a disposable T3 environment and a controlled provider test process:

1. Reconcile one N2 profile into T3 and verify the selected process identity.
2. Start a task and capture its account, machine and session binding.
3. Inject a quota rejection while a prior usage observation still shows headroom.
4. Verify that N2 marks the applicable account restriction and attributes it to the task.
5. Exercise resume and an explicitly selected alternative account through supported T3 behavior. Determine which session state survives and whether any operation repeats.

Record the exact T3 and provider versions, evidence and unsupported cases. Synthetic tests establish adapter behavior, not live provider authentication. Live authentication checks require separate evidence.

If stock T3 cannot expose the required lifecycle or preserve approvals and session state, document the missing hook and compare a narrow patch with a protocol wrapper. Keep account and scheduling policy in N2 in either case. Automatic cross-provider or cross-machine continuation is later work requiring explicit context and workspace transfer, side-effect handling and compatibility checks. An unreachable worker remains unknown; it does not trigger a duplicate task elsewhere.

## Acceptance criteria

All boxes remain open until implementation and evidence exist.

- [ ] The same N2 profile maps to the same verified provider account on two isolated fleet peers, despite different local paths and display names.
- [ ] A T3 Default instance bound to a different account is detected and explained; matching labels never establish identity.
- [ ] Only eligible profiles are generated, respecting machine exceptions, enrollment and credential-sharing policy.
- [ ] Preview, opt-in, reconciliation, drift handling and rollback preserve unrelated settings and concurrent user edits.
- [ ] Unknown T3 schemas, malformed settings and unsupported credential stores fail without destructive writes or guessed bindings.
- [ ] The running T3 server's selected provider instance and launched process use the intended binding; a required restart is visible and does not interrupt active work automatically.
- [ ] Claude credential precedence and Codex isolated/shadow-home behavior are tested with explicit identity evidence and supported version boundaries.
- [ ] Rename, removal, sign-out and credential rotation preserve session attribution and prevent unintended account changes.
- [ ] Launch, resume and any wrapper preserve protocol behavior, approvals, signals and exit status; capability probes do not allocate tasks.
- [ ] A quota rejection overrides conflicting older availability for its applicable scope and appears on another connected peer without double-counting allowance.
- [ ] Unknown or stale readings remain visibly unknown or stale, including during disconnection and after event replay.
- [ ] Task usage identifies provider, account, model, machine and session where supported, with missing fields explicitly reported.
- [ ] The recovery experiment establishes supported resume behavior without duplicate side effects; remaining gaps determine whether a T3 patch is needed.
- [ ] CLI diagnostics and native UI expose binding health and actionable repair steps; packaged installs contain required adapter resources.
- [ ] Behavioral tests use isolated settings, synthetic credentials and controlled provider processes. Live checks are reported separately and secrets never appear in fixtures or output.

## Implementation sequence and open decisions

First agree the shared identity and observation contracts with #3, including stable IDs, revision/conflict behavior and the boundary between profile identity and provider account identity. Then implement preview and configuration reconciliation, followed by process-binding verification and execution observations. Run the recovery experiment before expanding into automatic account selection or a maintained T3 patch.

Still to verify: installed-version support, settings reload behavior, safe concurrent settings updates, supported provider identity endpoints, Claude credential precedence, Codex credential-store compatibility, and T3 session hooks. None of these investigations changes the commitment that N2 is the fleet authority.

## Primary references

- [T3 settings contracts](https://github.com/pingdotgg/t3code/blob/main/packages/contracts/src/settings.ts)
- [T3 Codex provider documentation](https://github.com/pingdotgg/t3code/blob/main/docs/user/providers-codex.md)
- [T3 installation and provider configuration](https://github.com/pingdotgg/t3code/blob/main/docs/user/install.md)
- [Claude Code authentication](https://code.claude.com/docs/en/authentication)
- [Claude Code costs and limits](https://code.claude.com/docs/en/costs)
- [Codex authentication](https://learn.chatgpt.com/docs/auth)
- [Codex app-server account and rate-limit interfaces](https://learn.chatgpt.com/docs/app-server)

These links describe upstream behavior and may change. Pin source revisions and record installed versions when implementing the adapter.
