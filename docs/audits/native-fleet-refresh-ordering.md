# Fleet refresh ordering

A slow earlier read could replace a newer successful snapshot, restore old tasks
following a newer failure, or mark a recovered fleet unavailable. Each refresh
now receives an identifier on the main thread. Only the latest request may
publish success or failure, announce notices, or update the attention indicator.
Background callers enter through the main queue. Superseded CLI calls may finish,
but their results have no UI side effects.

## Proof

Run `python3 scripts/test-native-fleet-ordering.py`. The test compiles the exact
production refresh method with FleetModel and a synthetic CLI. It holds the
first read on a semaphore, completes the second, then releases the first.
Tracked queue completion replaces sleeps. Each scenario requires exactly one
publication and attention update, the newer timestamp and task/error state,
and only the announcements appropriate to the newer outcome:

- Older success, newer success: completed task remains visible.
- Older failure, newer success: recovered state stays available.
- Older success, newer failure: failure remains visible without announcements.

The initial refresh enters from a background queue to exercise main-thread
admission. `python3 scripts/test-native-fleet-read.py` retains its 17 sequential
failure, recovery, empty-feed and dispatch-admission checks. Both proofs run in
the full test suite and smoke gate.

Before the repair, the ordering regression failed with `obsolete read published`.
The local negative-control receipt is `/private/tmp/n2-fleet-ordering-negative.log`.
This proves publication order with synthetic reads, not physical-peer transport
or desktop notification delivery. Those acceptance requirements remain open.
