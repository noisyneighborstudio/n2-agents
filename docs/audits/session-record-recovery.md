# Interrupted local session-record recovery

A process killed after linking its completed immutable binding but before removing
the temporary `.pending-*` name left the record with two hardlinks. Strict private
file reads then rejected it indefinitely, hiding the otherwise saved session.

Record publication and reads now share a per-thread kernel file lock. Discovery
and explicit resume remove a temporary alias only when the private regular record
has exactly two links and exactly one `.pending-*` file names the same inode.
Unrecognized links still refuse. Cleanup and record directories are synced before
success. A killed writer releases its kernel lock automatically; another thread's
record uses a different lock. Existing bindings cannot be replaced by a new account.
The transfer importer's separate recovery protocol is unchanged.

The proof is:

```
python3 scripts/test-fleet-auth-bridge.py BridgeIntegrationTests.test_killed_record_publisher_recovers_in_discovery_and_resume BridgeIntegrationTests.test_record_recovery_refuses_unrecognized_hardlinks
```

The first test creates provider history through the actual CLI, injects SIGKILL
immediately after the binding's hardlink publication, confirms two links remain,
and then discovers and resumes the session through the CLI. It also checks that
a conflicting account cannot replace the recovered binding. The second test
verifies that an unrelated hardlink is preserved and refused. The original code
fails the SIGKILL proof at CLI discovery in a discarded checkout. Smoke includes
both checks. These tests use disposable profiles and a synthetic signed owner.

Independent correctness review found no remaining issues. Formatting, lint, the
full repository suite and expanded smoke pass locally. The ad-hoc QA package
builds and verifies its signature; its byte-matched helpers pass all 15 session
integration tests and six transfer tests in disposable state. The live fleet-QA
selector is absent, and the package was not installed or launched.
