# Failed fleet reads preserve historical state

A failed refresh now publishes an unavailable state instead of silently retaining
apparently current data or erasing tasks. It preserves the last successful
snapshot and timestamp. A failed first read shows an error, not enrollment or
endless loading. Recovery replaces the snapshot and clears the failure.

Every command used by `refreshFleet` is required for a successful snapshot:
status, peers, sync status/conflicts/exceptions, tool list/status/deferred,
and task list/notices. Nonzero exits discard the partial pass. Status must
identify a machine or explicitly report uninitialized. Task rows must have the
CLI's seven columns and a recognized state. Empty task feeds remain valid.
Other feed parsers retain their existing schema behavior; this change does not
claim comprehensive malformed-output validation for every feed.

Failed reads do not announce notices. The header labels retained data as last
known state with its successful-read time. Dispatch destinations become empty;
Send and Run It Somewhere Else are disabled and visibly dim. Their action entry
points also refuse before opening a form or starting a command. Historical
result inspection remains available. Successful reads restore destinations.

`python3 scripts/test-native-fleet-read.py` compiles the exact production refresh
method, model, and both action admission prefixes. Seventeen event-driven cases
pass. The old refresh with the new metadata shape failed the publication
assertion before the repair. Both full tests and smoke run this regression.
The fixture uses synthetic CLI replies and tracked real dispatch queues; it does
not invoke a real CLI, provider or fleet. No sleep-based assertion is used.

Four production component renders were inspected: failed first read, retained
running task, retained stranded task and successful recovery. Image/source hashes
are in the [render record](native-fleet-read-failure.json). Artifacts are in
`/Users/sethwebster/Development/n2-fleet-qa-artifacts/native-fleet-read-failure`.
These are component renders, not packaged-app acceptance. The temporary renderer
is discarded after review.

Concurrent refresh ordering, actual macOS notification delivery, physical-peer
acceptance and final packaging remain required. This slice does not close them.
