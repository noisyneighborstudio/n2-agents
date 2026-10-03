# Slice queue

This is the fleet queue for PR #3, now merged with main through a9221bf. Integrate
main into this branch as each main change lands. Fleet readiness requirements are
in `docs/fleet-readiness.md`; the deferred fleet briefs are in `ad27ac9:docs/slices.md`.
No merge to main, publication, installation or machine enrollment without explicit
authorization.

## Gates

Every push runs `.github/workflows/ci.yml`, which runs `scripts/verify.sh`: format,
lint, `scripts/test.sh` and `scripts/smoke.sh`, in that order, and a parallel job
runs `scripts/test-fleet.sh`. Run both locally first.
A slice is complete only after these pass locally and CI passes on its pushed
commit. One commit with a `Slice: <slug>` trailer; remove the entry in that commit.

## Queue

Walkthrough fixes (from the recorded product walkthrough, 2026-10-01). Each is
proved by a check that fails on the old code plus frames captured from the
demo build (`clip.sh` in the walkthrough tooling).

1. **Arrow keys move between cards and rows** (`panel-arrow-keys`).
   Behavior: Up and Down move focus between Fleet cards and Profile rows;
   Return opens (docs/tray-redesign/02-screens.md).
   Proof: AX run: arrows move the focused element; Return opens it.

Fleet slices:

1. **Merge a conflict with an agent, reviewed by another** (`fleet-sync-agent-merge`).
   Behavior: `fleet sync merge <id>` asks an agent with measured headroom for a
   merged version, then an agent from a different lab reviews it (Claude
   never reviews Claude's merge; a harness counts by its model's lab, and an
   unknown lab never qualifies): nothing lost without a stated reason, no
   contradictions or duplicates. Disagreement shows the proposal and the
   concerns; with no other-lab agent available the proposal is marked
   unreviewed. Nothing
   applies until the operator accepts (`--apply`, via the merged resolution). Credential
   files, credential-bearing settings, MCP configuration and binaries are
   refused before anything reaches a model.
   Proof: fake merger and reviewer agents; agree, disagree and no-reviewer
   cases each produce the stated outcome; with only same-lab agents available
   the proposal is unreviewed; a credential file is refused and
   the fake agent's recorded input is empty.
   Scope: CLI only; the panel button is the next slice.

2. **"Merge with Agent" in the panel** (`fleet-sync-agent-merge-ui`).
   Behavior: each text conflict row offers Merge with Agent beside the two
   existing choices; a sheet shows the diff, the review and Accept or Discard.
   Only that row's button disables while agents work; it is disabled with a
   reason when no agent has measured headroom.
   Proof: a Swift test holds the merge read while the rest of the panel renders
   (the AGENTS.md UI rule); accept and discard record the right outcome.

3. **Walk the fleet flows in the native UI** (`fleet-native-flows`).
   Behavior: from the QA app, pair two disposable peers (Settings › Fleet),
   sync (with a held profile shared from Fleet settings), send work (the Send
   Work page), show its result (the Task page) and revoke (the Machine page).
   Proof: packaged acceptance driven through accessibility events with
   disposable homes; each step asserts CLI state, and one negative control
   per step fails.
   Scope: disposable peers only; no live installation or real machines.

4. **Honor Claude usage rejections** (`usage-claude-backoff`).
   Behavior: after a 429 from Claude usage, no reader asks that account again
   until its `Retry-After` has passed; the row stays `rate-limited` with the
   last reading and its time. Evidence: `docs/audits/claude-usage-rate-limit-spike.md`.
   Proof: reader test with the recorded 429 (`Retry-After: 300`): a second
   read inside the window makes no network call and reports `rate-limited`;
   a read after the window calls again. Break the gate once; the test fails.
   Scope: Claude only, one Mac. Codex and peer sharing excluded.

5. **One Claude usage call per account at a time** (`usage-claude-single-flight`).
   Behavior: concurrent readers (tray, loop, dispatch) of one account share
   one provider call, and a reading under 60 s old is served from the journal.
   Proof: two concurrent `usage.py` runs against a held fake provider make one
   call and both print its reading; with the reading aged past 60 s (injected
   clock, no sleeps) the next run calls again.
   Scope: Claude only, one Mac. The 60 s figure is policy, not a measured
   provider window.

6. **Offer skill updates across the fleet** (`fleet-skill-updates`), later.
   Behavior: N2 notices when an installed skill has a newer version at its
   source and offers one action that updates it on every enrolled Mac; the
   Fleet panel shows which Macs are behind.
   Proof: a fixture skill source at v1 on two disposable peers; publish v2;
   the check lists it outdated on both; the update brings both to v2; a peer
   that was offline gets it on reconnect; a declined update stays at v1.
   Scope: skills whose source N2 can identify (starts with a spike on which
   sources carry version data). Claude's account skills (`skills/synced/`)
   and Codex's bundled `skills/.system/` are excluded: their tools update them.

Blocked on a decision:
- `remote-machines` (docs/tray-redesign/08-slices.md S9): peer machines as Fleet
  sections needs a CLI source for profiles held on peers (open question Q1).

Blocked on authorization:
- Per-provider sign-in lifecycle evidence needs live provider accounts
  (readiness: "provider-specific authentication lifecycle").

## Noticed

- Sync still spends about 30 ms of shell forks per address in sync_scope_ok on
  each side (1,500 files: 103 s dry run). Moving scope evaluation into the
  manifest process would remove most of it.

- Open next best can still pick an unmetered slot when nothing metered has
  room: it mirrors the CLI's rotation. The redesign's acceptance list says it
  never should; that is a CLI policy change first.

- Toasts ship without "Notify when back" (open question Q7) and without a
  "Recent warnings" list (Q5). Add them once answered.

- Configure has no "Sign out of {Provider}": the CLI has no per-slot sign-out,
  and provider logout is deferred (below). Add the row with that verb.

- Macs polling the same Claude account share its usage budget. Serving a
  peer's fresh verified reading instead of polling needs an identity-match slice.
  The window behind the ~5-read budget is also unmeasured.

- Default's Claude login lives in two Keychain entries: `agents run` uses the
  path-hashed one, plain `claude` (via ~/.claude -> Default slot) the unscoped
  one. They can hold different accounts; usage measures only the first.

- Muse on one live Mac (three profiles) reads `ok` with no figures: the key
  endpoint reply has no `subs_usage`. The panel shows "check failed".

- Codex /status shows a monthly credit limit on business plans (one profile:
  0 of 3,000) that the reader drops; only `hasCredits` survives.

- Audit finding 5 is still open for ranking: `pick_best` scores a missing
  window as 0 when the other window is measured, and `loop/Slots.swift`
  `headroom` has the same shape. The live panel's "0% used" rows were real
  readings (Claude /usage and Codex /status agree), so no display fix here.

- Token renewal runs `claude -p /usage`, which loads the profile's settings and
  hooks. If a SessionStart hook misbehaves under polling, restrict setting sources.

- test-fleet.sh's two lock-race loops (section 39, about 45s) did not catch
  their bugs when reintroduced on the Mac mini: 0 of 25 trials with the steal
  marker replaced by delete-on-sight, 0 of 8 with the grace reset removed.
  Replace them with deterministic interleavings, or delete them.

- Any same-user process can open `n2agents://reonboard-done` (or `login-done`)
  and make the app treat a running account reset as finished.

- test-fleet-auth-manage.py's SIGINT cancel case allows 5s for exit and failed
  twice (2026-09-28, 2026-09-29) with three test groups running on one Mac; it
  passes alone. Runners share each Mac, so capture exit receipts if it recurs in CI.

- The inherited full-suite quota fixture fails intermittently (main saw it at
  scripts/test.sh:682 and :685). Suspect: tests/fake-loop-agent.sh decrements
  worker-quota-<profile> without a lock, so concurrent chunks on one slot can both
  fail while the counter drops once. Keep the assertion; capture turns on failure.

- Codex setup sign-in runs fleet's owner-aware plan in a terminal; other labs use
  main's in-app session. In-app Codex sign-in needs the plan resolved before the
  session starts.

- Fleet crash-accounting, archive safety, notifications and provider logout stay
  deferred. No dispatch release before archive proof; no unproven credential retirement.
- T3 adapter remains downstream of its actual profile contract. Resume must
  preserve the original account binding.

- Claude fleet denials now recover by evidenced reset; an ordinary parent success cannot establish subagent or spending recovery. Scope-specific successful recovery evidence remains required before claiming complete allowance recovery. See `docs/fleet-readiness.md`.

- Existing test suite contains sleep-based checks. New tests must wait on observable events; convert old waits when their behavior enters a slice.

- The Ctrl-C exit timeout in CI 36269470567 remains unresolved. The unchanged full suite and 180 bounded local terminal checks passed. Preserve the assertion; a recurrence needs signal/exit receipts and process-state evidence before a repair. Evidence: `docs/audits/terminal-ci-failure-spike.md`.

- Default Claude path normalization remains unresolved after the bounded source-mapping spike. Reopen only with new authoritative module mapping; do not repeat the same binary search. See `docs/audits/claude-default-path-spike.md`.
