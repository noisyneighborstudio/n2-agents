# How work happens: small, verified slices

Move fast by never being far from something that works.

1. **Slices are vertical.** A slice delivers one observable behavior, end to end:
   something a user, a client, or a test can see working. Layers built on their
   own ("add the types", "add the database layer", "add the API") are not slices.
2. **Proof first.** Every slice states its proof before any code exists: a test,
   or a command and the output it should produce. A slice is done when its proof
   passes, the gates pass locally, and CI is green on the push.
3. **One sitting.** A slice is about a few hundred lines of diff and one commit,
   and it fits in one session. If it won't fit, split it before you start, not
   halfway through.
4. **The main branch is always green.** Run the gates before pushing. If CI goes
   red on main, push a revert commit immediately, then fix it on top. Never
   force-push.
5. **Stop rule.** Stop if the same failure survives three attempts, or if the
   slice grows to twice its planned size. Commit nothing broken. Record what you
   learned under **Noticed**, then report. Don't loop: an agent in a loop always
   believes it's one fix away.
6. **Spikes produce knowledge, not code.** When behavior is unknown (an external
   API, a wire format, a library's edge cases), run a labeled spike. Keep its
   recorded fixtures and notes, discard its code, and build against the fixtures,
   so later slices are deterministic and testable offline.
7. **One commit records the slice.** The slice's commit also removes it from the
   queue, and it ends with a `Slice: <slug>` trailer. `git log --grep '^Slice:'`
   is the done list. There are no follow-up "check off" commits.
8. **Docs move with code.** A slice that changes a decision updates the docs in
   the same commit. Docs never trail the code.
9. **Nothing speculative.** Don't land code the slice's proof doesn't exercise:
   no unused abstractions, no "for later" fields, no new module or dependency
   before a slice needs it. Anything worth doing outside the slice goes under
   **Noticed**.

## The slice queue

`docs/slices.md` holds:

- **Queue:** the next 3–5 slices, in order. Each entry is complete enough to be
  the implementer's whole brief:
  - *Behavior:* what will be observably different.
  - *Proof:* the tests or commands that demonstrate it.
  - *Scope:* what is deliberately excluded.
- **Noticed:** things seen during a slice that belong to none. Each item moves
  into the queue or gets deleted. Nothing sits there for long.

Keep it short. The code, its tests, and the commit history are the record, and
the queue is meant to be thrown away.

## Roles

- **The implementer** takes the first slice in the queue and does exactly that
  slice. It builds the slice, proves it, commits, pushes, and reports.
- **The supervisor** checks the report's evidence without taking it on trust,
  re-plans the queue after every slice, and sorts **Noticed**.
- **The implementer's report** is short and gives evidence the supervisor can
  check with one command:
  - the commit hash;
  - the CI run ID for that commit;
  - the tests or commands that prove the behavior;
  - anything added to **Noticed**.

## Gates

Every gate runs locally and in `.github/workflows/ci.yml` on every push.
Run commands from the repository root on macOS 26 with its Xcode SDK.

- Formatting check: `scripts/check.sh format`.
  This checks introduced whitespace errors against `HEAD^`; set `N2_CHECK_BASE`
  to compare against a different base when needed.
- Lint with warnings as errors: `scripts/check.sh lint`.
  This compiles tracked Python sources with compiler warnings treated as errors
  and checks the CLI and gate shell scripts for syntax errors. It does not claim
  style or type analysis.
- Tests: `scripts/test.sh`.
- Smoke run: `scripts/smoke.sh` starts the real CLI against throwaway state and
  a signed synthetic owner. It checks session discovery, resume, transport descendant cleanup, provider caller-lifetime cleanup, and terminal frontend cleanup without
  live provider credentials. Extend it when a slice adds observable behavior.

CI must be green on the exact pushed commit before reporting a slice complete.

## Testing rules

- Tests wait on events, signals, or receipts, never on sleeps. A timeout is only
  a guard that fails a stuck test.
- A check that can't fail proves nothing. When adding a smoke check or a CI gate,
  break it once on purpose and confirm it goes red. Restore the source and prove
  it passes before committing. Never push the deliberate break.

## Repository invariants

- Preserve existing work. Keep unrelated changes outside the active slice.
- Use `git dougbot` for agent-authored Git writes and `dougbot-agent` for GitHub
  writes. Verify the identity before writing; stop if the bot is unavailable.
- Do not merge, deploy, install into the user's live app, enroll real machines,
  or change real profile credentials without explicit authorization.
- N2 Agents is the canonical account source. Resumed work retains its original
  account binding; it must never silently switch to a replacement account.
- Unknown or stale usage must not advertise fresh capacity. Never treat
  synthetic-provider tests as live-provider acceptance.
- Development and tests use isolated homes, profiles, and peers. Packaged tests
  must not activate the live `fleet-qa` root selector.
