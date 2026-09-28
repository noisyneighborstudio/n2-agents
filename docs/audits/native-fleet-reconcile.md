# Responsive native reconciliation

The native **Check in** action runs `fleet task reconcile` on a background queue.
Its result returns to the main queue. A nonzero result shows the existing refusal
alert, then fleet state refreshes; success refreshes without an alert. The action
does not infer task completion from command output.

## Proof

`python3 scripts/test-native-reconcile.py` compiles the exact production
reconciliation and CLI bridge methods in a disposable test shell. A synthetic
CLI announces startup through one FIFO and waits on another. Only a main-thread
receipt can release it. Both empty-output success and nonzero refusal complete;
the tests require one refresh and error-before-refresh ordering on the main
thread. Against the old synchronous method, the timeout guard failed because
the main thread could not release the command. The test is included in full
regression and smoke. It uses no sleeps or real provider/fleet state.

A uniquely identified ad-hoc QA package used temporary HOME/CFFIXED_USER_HOME
and N2_ROOT, a synthetic bundled CLI, and denied network access. Clicking its
actual Check in button started the held command. The actual Settings button
opened its window while the command was still held and task state was unchanged.
After release, the panel displayed the task as finished. A second invocation
returned exit 1 and displayed `Couldn't reconcile tasks` / `fixture refusal`.
Screenshots were visually inspected. Their evidence and source/binary hashes
are retained in the sibling QA artifact directory `native-reconcile`.

The initial disposable copy expanded framework symlinks and could not be signed.
A new copy preserving symlinks passed deep/strict signature verification. The
source QA package also passed. No live fleet-QA selector was included. The test
app was terminated and removed after verification. No app was installed.

This proves the repaired button's responsiveness and result presentation with a
synthetic CLI. Physical-peer reconciliation, desktop-banner delivery and complete
fleet acceptance remain required by `docs/fleet-readiness.md`.

Independent correctness review found no remaining issue in the action or focused
proof. Final formatting, lint, full regression and smoke passed locally.
