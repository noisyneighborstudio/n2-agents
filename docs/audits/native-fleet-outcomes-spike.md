# Native fleet outcomes spike

Source: `d670567e81471a2eb237e2c58c30251f919f5225`. Recorded inputs,
event receipts and source/image hashes are in the adjacent JSON fixture.
Screenshots remain in the sibling QA artifacts directory
`native-fleet-outcomes-spike`. No production source changed in this spike.

## Observed behavior

The unchanged `FleetView.swift` and `FleetModel.swift` rendered at 400 points
with a disposable model and no-op actions. The completion and reconciled
fixtures show `finished`, a result button and a completion activity row.
The failed fixture shows `failed` and a failure activity row. Disconnection
shows `unreachable`, the warning that work may still be running, and an
explicit retry button. All four screenshots were visually inspected.

These are component renders with recorded synthetic rows, not screenshots of
live task execution or a packaged-app interaction. Reconciled completion is
visually equivalent to ordinary completion. The CLI reconciliation behavior
has separate existing coverage; this spike does not replace that coverage.

The disconnected fixture also labels its task `1 running` in the heading.
That overstates the known state. Track the wording separately from the action
repair below.

## Confirmed action gap

The exact `fleetReconcileTasks` method from `FleetControl.swift` and `runCLI`
method from `main.swift` were compiled in a disposable AppDelegate shell.
The shell replaced only alert/refresh endpoints with receipt recording. Its
CLI was a local shell fixture that announced startup through a FIFO and
blocked on a separate release FIFO. It did not read a real fleet or provider.

The action ran on the main thread with another main-queue event already queued.
A background observer received the CLI startup receipt, recorded whether that
main event had run, and released the CLI. The observed sequence was:

1. CLI started; main event had not run.
2. Refresh requested.
3. Action returned.
4. Main event ran.

The UI thread stays occupied while reconciliation waits for the CLI. A discarded
control moved the command to a background queue and returned its result to the
main queue. The action and main event then completed before CLI release, and
refresh followed. Both runs used event receipts; the process timeout was only
a stuck-run guard. This control is evidence for a bounded repair, not shipped code.

## Next proof

Make **Check in** keep the UI responsive while reconciliation waits. Hold a
synthetic command open, require a main-thread receipt before releasing it, and
verify success refreshes fleet state. A nonzero result must show a failure and
refresh; malformed or absent output must not invent completed tasks. Compile
and exercise the production action, then prove the packaged button follows it.
Keep this slice under 200 added/changed lines, stopping at 400.

Desktop notification permission/delivery, real disconnected-peer reconciliation,
and the complete packaged fleet flow remain required by `fleet-readiness.md`.
A source-read suspicion that failed status reads retain stale UI is not yet a
runtime finding; investigate it in the later full refresh-flow acceptance.
