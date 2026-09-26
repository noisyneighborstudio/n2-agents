# Terminal CI failure investigation

PR run 36269470567, head 69863c3d7fb0f3a31d5ba32dd0b2a5d8582e3ee4,
passed both quota recovery proofs and later failed two terminal lifecycle tests.
The paired push run 36269467858 passed. Neither run was restarted.

- `test_bridge_sigkill_stops_frontend_attached_to_pty` reached its cleanup
  block after the frontend lifetime pipe closed, the supervisor exit event
  arrived, and terminal modes matched. Cleanup `killpg` raised PermissionError.
  This does not establish why Darwin rejected that signal.
- `test_supervisor_preserves_terminal_sigint_and_frontend_exit_code` observed
  frontend readiness, sent SIGINT to the group, then timed out waiting five
  seconds for the supervisor. The log lacks frontend signal/exit receipts and
  process state, so it does not distinguish failed signal delivery, delayed
  exit, or a stuck supervisor.

## Bounded local experiments

At local head f2da5be, an unchanged TerminalLifetimeTests suite was run 30 times
per interpreter with fail-fast enabled. Each run used disposable PTYs and
synthetic frontends, without provider credentials or network calls.

| Interpreter | Checks | Result | Duration |
| --- | --- | --- | --- |
| Python 3.9.1 | 90 | Passed | 11.356 seconds |
| Python 3.14.3, Homebrew first in PATH | 90 | Passed | 11.703 seconds |

CI used Python 3.14.7. The minor version family matches the second experiment,
but these results do not reproduce or explain either CI failure. The ad hoc
experiment driver was passed on stdin and was not retained as product code.
The unchanged full suite also passed under Homebrew Python 3.14.3. Passing
repetitions do not establish a cause for the separate Ctrl-C timeout.

## Deterministic cleanup reproduction

A disposable Python child started in its own session and blocked on stdin. The
parent registered a kqueue NOTE_EXIT event, closed stdin, and observed exit
before calling wait. Sending SIGKILL to that exited, unreaped process group
raised PermissionError with errno 1. The parent then reaped its child. No sleeps,
provider calls, or existing user processes were involved. This establishes that the
cleanup exception can occur without a surviving frontend; it does not prove
the exact process state on the failed CI runner.

The test now skips group cleanup after both frontend EOF and the supervisor
exit event. Earlier failures still trigger cleanup and unexpected permission
errors remain visible. Production signal behavior and timeout guards are
unchanged. The separate Ctrl-C timeout remains unresolved.

## Repair proof

With `os.killpg` patched to raise the recorded PermissionError, the original
terminal SIGKILL test failed in cleanup after its lifecycle assertions passed.
The temporary candidate tracked the supervisor exit receipt and skipped that
signal after both exits were confirmed. The same injected-error proof passed
with zero group-signal calls. All three TerminalLifetimeTests also passed against
the candidate. The active full-suite source was left unchanged for its baseline
experiment. No production code or timeout was changed.

Independent correctness review found no issues: both exit receipts justify
skipping the signal, and all lifecycle and terminal-restoration assertions remain.
The changed source passes focused terminal tests, formatting, lint, the full
repository test suite and smoke. Full tests and smoke used Homebrew Python
3.14.3. Exact-head CI remains required; the separate Ctrl-C timeout is not
claimed repaired.
