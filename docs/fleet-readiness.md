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
- [x] Reverify profile/configuration/credential sync, conflicts and machine exceptions: 635 checks pass across all 75 sections.
- [ ] Complete provider-specific authentication lifecycle evidence and explicit limitations.
- [x] Reverify managed-tool authorization, replication and safe update deferral, including a barrier test of preparation versus disruptive installation.
- [ ] Complete dispatch eligibility, preferences and expected-completion ranking.
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
