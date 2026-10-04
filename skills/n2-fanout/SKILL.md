---
name: n2-fanout
description: Fan a large coding goal out across every N2 Agents profile and lab with quota left (Claude, Codex, Muse), in small reviewed slices, until its definition of done holds. Use when the user asks to build, fix or migrate something too big for one session, or to "fan out", "split the work", "use all my accounts" or "use the loop".
---

# Fan work out with `agents loop`

The N2 Agents loop does the orchestration: it plans the goal into chunks of
about fifteen minutes with a definition of done, gives each chunk to the slot
(profile and lab) best placed for it by strength and quota left, spreads work
so no slot carries more than its share, has another lab review every chunk
before merging, and finishes only when a verifier and a sign-off from two
different labs agree every criterion holds on the final commit.

Your job is to be the user's hands: state the goal, answer what you can, bring
the plan to the user, start it once they approve, and report until it ends.
Never do the chunks yourself and never edit the run's worktrees.

## 1. Plan

The run starts from the repository's current commit, so commit or stash
first; uncommitted changes are not part of the run. Agree a budget with the
user: the total agent time across every agent (`45m`, `2h`, `6h`). Then:

```sh
agents loop plan "<goal, with everything the user said that matters>" \
  --budget 2h --cwd <repo> --json [--file <spec.md>]…
```

stdout is one JSON object: `run`, `goal`, `criteria`, `verificationCommands`,
`chunks` (each with `effort`), `questions` and `blocker`. Progress goes to
stderr. Planning takes a few minutes.

## 2. Answer the planner's questions

For each entry in `questions`: if the user already settled it, answer for
them; otherwise ask the user, showing the options and the recommended one.

```sh
agents loop answer <run> <question-id> "<answer or option number>" --json
```

When `blocker` asks for it (an answer differs from the recommendation), draft
again; new questions may appear, so repeat until `blocker` is `null`:

```sh
agents loop replan <run> --json
```

## 3. Get the user's approval

Show the user the criteria (what done means), the verification commands and
the chunks with their efforts, and the budget. Start only when the user says
so. To change the plan, edit `~/.n2-agents/loops/<run>/plan.json` and pass it
to approve.

```sh
agents loop approve <run> [--plan <edited plan.json>] [--budget 3h]
```

`approve` refuses, naming the next command, while any question is open.

## 4. Follow it

```sh
agents loop wait <run> --json     # blocks until a merge, repair, wait, pause or DONE
agents loop status <run>          # readable: criteria, chunks, who did the work
```

Run `wait` again after each answer; it returns `status` (RUNNING, WAITING,
PAUSED or DONE), `reason` and the new `events`. Tell the user when chunks
merge or a repair starts, not on every return. If `controllerRunning` is
false while RUNNING, `agents loop resume <run>`.

- `WAITING`: every usable slot is out of quota until `retryAt`. It resumes on
  its own; say when.
- `PAUSED`: read `reason`. Budget spent: ask the user for more, then
  `agents loop resume <run> --budget <new total>`. A question from the
  supervisor: answer it if the user already settled it, otherwise ask them,
  then `agents loop answer <run> "<decision>"`, which records it for every
  later worker and reviewer and resumes. A failure that keeps repeating:
  bring it to the user, then `agents loop resume <run>`.
- To stop: `agents loop pause <run>`. Work so far is kept.

## 5. Report

At `DONE`, the result is on branch `n2/loop-<run>` in the repository, and
`~/.n2-agents/loops/<run>/DONE.md` holds the evidence for every criterion
and who did the work, per slot and per lab. Give the user the branch, the
criteria with their evidence, and the table. Merging, pushing or opening a
pull request is the user's call.
