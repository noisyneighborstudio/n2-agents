# Native refresh and notification evidence

The exact `refreshFleet` method from `tray/FleetControl.swift`, compiled with
production `FleetModel.swift`, reproduces two misleading refresh outcomes.
This is a sequential, synthetic boundary test. No real CLI, packaged app,
provider account or physical peer was used.

## Runtime proof

A disposable AppDelegate provides fixed CLI responses and counters for announce
and attention endpoints. A wrapper tracks actual global/main dispatch blocks
with a DispatchGroup, including nested main-queue publication. Each observation
runs after those blocks drain. The main RunLoop remains active. There are no
sleep-based assertions; a 15-second timeout only guards a stuck process.

The [fixture](native-refresh-acceptance.json) records source hashes and results.
Independent review reran the executable and confirmed all four observations.

| Read | Published task state | Total publications | Result |
| --- | --- | --- | --- |
| Successful initial read | running | 1 | Baseline |
| Status command exits nonzero | running | 1 | Retains old snapshot with no failure publication |
| Status succeeds, task list exits nonzero with empty output | empty | 2 | Replaces known task list with an empty list |
| Successful recovery | done | 3 | Restores current task state |

The initial command-line observer used `dispatchMain` and failed its main-thread
assertion. It was corrected to use `RunLoop.main.run` before recording the
passing results. This was a fixture correction, not a production change.

## Visual check

Production `FleetSection` and `FleetModel` rendered the recorded task-state
projections at 360 points. A minimal observable model supplies the fleet value;
actions are no-ops. All four images were inspected. Initial and failed-status
states look the same, with the task labeled running and no failed-read message.
The task-list failure removes the task row. Recovery shows finished and result
actions. These component renders do not establish full packaged interaction or
concurrent refresh ordering.

Images, their hashes and the model-check log are retained under
`/Users/sethwebster/Development/n2-fleet-qa-artifacts/native-refresh-acceptance`.
The repository fixture retains hashes; the exploratory code is discarded after
review.

## Notification and physical-peer boundary

Existing `tests/native/fleet-model-checks.swift` passes against production
FleetModel. It covers silent adoption on first read, a notice after an empty
launch, repeat/shrinking-feed deduplication, feed order and independent machines.
Those checks establish the announce-once decision only.

The refresh probe's announcement endpoint is a counter. It does not call
UNUserNotificationCenter. macOS authorization, submission failures, actual banner
delivery, suppression and real disconnected-peer reconciliation remain unproven
by this audit. In-panel activity and successful model tests do not close them.
Full packaging/regression, independent security and live-provider acceptance
remain required in `fleet-readiness.md`.

## Next repair

A failed required read must publish an explicit failure state, preserve the last
successful task snapshot as historical data, and avoid presenting retained peer
reachability as current dispatch eligibility. A failed first read must show an
error rather than endless loading or a false first-run enrollment prompt.
Successful recovery replaces the snapshot and clears the failure. Prove each
transition through the production refresh method and rendered fleet section.
Keep notification delivery and concurrent refresh ordering explicit; neither is
proved by this sequential fixture.
