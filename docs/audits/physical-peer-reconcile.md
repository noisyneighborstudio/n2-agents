# Physical task reconciliation acceptance

A signed SSH task from seth-agent to macbook-m5-pro-max-sdw completed while
its disposable dispatcher route was unavailable. Explicit reconciliation
recovered completed state with exactly one task and one command execution.
The retained JSON contains the CLI receipts and tested fleet-exec.sh hash.

The first physical attempt exposed a transport lifetime bug: dispatch retained
its SSH connection while the background worker waited on its release FIFO.
Releasing the worker allowed dispatch to return. The task launcher now redirects
all request descriptors before background execution. Worker diagnostics go to
its own worker.log; existing task stdout/stderr remain in out/.

Proof commands, from the checkout:

```sh
python3 scripts/test-physical-reconcile.py --peer local
python3 scripts/test-physical-reconcile.py --peer sethwebster@100.88.174.82 --artifacts /private/tmp/n2-physical-reconcile-evidence
```

Both passed. The offline fixture models pipe EOF and runs in tests and smoke;
it does not claim SSH authentication or physical-machine acceptance.
The physical run used the previously trusted SSH host key and existing login.
Only temporary homes, signing identities and synthetic shell work were used.
A refused port on the fixture route interrupted transport without changing the
machine's SSH service or network. Completion announcements could not reach the
dispatcher, so completed state required the explicit reconcile command.

Negative controls: `--keep-request-streams --peer local` restores the original
launch only in the copied fixture and fails the dispatch timeout guard.
`--skip-reconcile` failed the dispatcher-completed assertion on the M5 run.
A plain exec-carrier negative control missed the descriptor defect; it was
replaced by the pipe fixture before adding the gate.

Cleanup releases only the fixture FIFO and awaits terminal task metadata.
A worker timeout bounds controller loss. Terminal metadata is not proof that
all announcement processes have exited. Disposable roots remain for inspection.
This proves CLI recovery, not native rendering, OS banners, provider execution,
usage accounting, or real fleet enrollment. Those acceptance requirements remain.
