# Actual fleet prompt attribution spike

September 27, 2026. Source `613d01ca8ff2f997a9fb3008f76507a50d1da646`.
Labeled spike: retained evidence and an integration brief, no production change.

## Observed behavior

Two approved disposable peers exchanged real signed `task-start` messages through
`fleet_call` and `fleet_handle_task_start`. Each payload specified Codex prompt
mode, a synthetic task and context. The receiver's synthetic executable recorded
its configuration, task ID, cwd and output directory, emitted session/model/token
JSON and wrote a deliverable. Both tasks reached `completed`, exit zero.

| Case | Active profile at dispatch | Change while preparing | Invoked config | Usage task events |
| --- | --- | --- | --- | --- |
| Control `1111aaaa` | Before | none | Before/codex | 0 |
| Switch `2222bbbb` | Before | use After | After/codex | 0 |

Neither task created a usage journal. Raw stdout contains 50 input, 30 cached input
and 10 output tokens, session ID and fixture model. Context, cwd and deliverable
paths remain correct. The control demonstrates that the preparation hold alone
does not change the selected configuration.

Only the copied `fleet-exec.sh` was instrumented: immediately after publishing
`preparing`, it waited on a per-task FIFO. The controller observed a ready receipt,
optionally ran `agents use After --vendor codex`, then released the FIFO. The
barrier had a 60-second failure guard and no sleep. Account/configuration selection
and provider invocation stayed unchanged. The supervisor independently compared
the source change and inspected raw outputs, deliverables and task metadata.

The [recorded fixture](fleet-prompt-attribution-spike.json) hashes durable raw
receipts under `n2-fleet-qa-artifacts/fleet-prompt-attribution-spike`. Exploratory
controller, provider/barrier code and copied runtime were discarded after review.
Only fixtures and notes enter the repository.

## Interpretation and limits

`exec_invoke_prompt` reads the active profile at invocation and directly calls
`codex exec -` or `claude --print`. `exec_run_local` records fleet lifecycle but
not provider usage. The synthetic provider emitted JSON even though the invocation
did not request `--json`; this proves N2 did not consume supplied telemetry, not
that the real CLI returns that format by default. A configuration-path change
alone does not prove an authenticated account change. No live credentials,
provider calls, production enrollment, app installation or deployment occurred.

## Smallest vertical integration

Freeze the receiver-selected profile/config and verified expected account before
preparation, under the existing fleet task ID. Invoke the existing `codex-run.py`
through that saved binding. It accepts config, expected account, owner root and
profile name, takes the prompt on stdin, verifies identity before a turn, and emits
`n2.account.binding` with session/model/counters after a verified terminal outcome.
It does not journal by itself; loop terminal journaling lives in `loop/Slots.swift`.
The fleet integration must own start and terminal journal records with its task ID.
Journal origin is the executing receiver; the existing task dispatch origin remains
the sender. Do not attribute worker token use to the dispatcher.

The next slice's fail-first proof must exercise signed dispatch, not a separately
invoked runner. Hold preparation, switch the active profile, and require the saved
binding. Replace the selected account and require refusal before any turn. For a
successful fixture require one task with 60 total and 30 cached tokens, with no
cache double count, correct account/model/session/origin, stdin/context/cwd and
deliverables. Missing binding receipts or interrupted execution must leave usage
unconfirmed with null counts rather than success or zero. Keep exit status and
process cleanup intact. Do not infer account identity from emitted text.

Codex prompt integration is the next bounded implementation. Claude, generic shell
attribution and physical-M5 task acceptance are subsequent work, not waived.

## Validation

Formatting, lint, the full test suite and smoke passed in one gate chain, exit
zero. Local log: `/private/tmp/n2-prompt-spike-gates.log`. The independent
reviewer checked all nine retained artifact hashes and the integration brief.
