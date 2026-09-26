# Saved-session transfer

`agents fleet session send THREAD --peer PEER --cwd /destination/project` sends
one saved owner-bound Codex rollout over the existing approved-peer signed carrier.
The destination must already have the uniquely identified N2 profile and a healthy
owner route. The mapped directory must exist. Import creates no profile or grant.

The destination session browser discovers the original thread. Resume retains its
saved owner/account record even after profile account replacement. It explicitly
passes the saved model and mapped directory to the provider. A revoked original
grant refuses execution; another account is never selected as fallback.

## Publication and limits

The importer accepts a bounded JSON envelope containing one public binding, thread,
model, directory and rollout. History is limited to 16 MiB. It validates the first
native session metadata record against the thread and rejects incomplete JSONL,
multiple metadata records, foreign profile identities and conflicting destinations.
These are structural checks, not provider authentication; authorization is still
required at resume. An approved peer is trusted to supply the saved history.

The source reads a stable regular file under its private session home. Native
Codex's 0755 history subdirectories and 0644 rollout files are accepted inside that
0700 home; writable-by-others paths, symlinks and hardlinked source files refuse.
The destination uses a locally derived filename, never a sender-controlled path.

Imports serialize with a nonblocking lock. Private history and model are synced
before publishing the immutable session record. Deterministic staging names allow
retry after interruption on either side of hardlink publication. Identical retry
succeeds; changed history or model does not overwrite an existing session. Divergent
histories require an explicit future merge design. This transfers saved history,
not a running process. No provider credential file or whole home is copied.

## Proof

`python3 scripts/test-fleet-session.py` exercises signed two-root delivery, actual
CLI discovery and resume, preserved model/directory/account after profile rotation,
retired-grant refusal, malformed/missing history, unsafe paths, unapproved peers,
conflicts and interrupted history/model/binding publication. The repository test
and smoke gates both run it. In a discarded checkout, omitting final binding
publication makes the real CLI proof fail. Existing bridge regression tests pass.

Installed Codex 0.157.1 also resumed the imported native rollout from the preceding
spike through this implementation. It returned the same thread, mapped directory
and original synthetic user turn, without creating auth.json. The experiment used
only disposable roots, a synthetic signed SSH carrier and an OS network-deny sandbox.
No model turn was attempted. The recorded local result is
`n2-fleet-qa-artifacts/session-transfer-native-implementation.json`.

That native check proves saved-history compatibility for the installed version.
It does not establish live-provider continuation or two-physical-machine acceptance.
Independent correctness review found and verified the hardlink interruption repair.
The normal local `Sessions.remember` publisher had the same interruption boundary.
Its subsequent repair is recorded in [session-record recovery](session-record-recovery.md);
this importer retains its separate recoverable publisher.

Formatting, lint, the full repository suite and expanded smoke pass locally. An
ad-hoc QA package builds and passes signature verification. Its byte-matched CLI
helpers pass all six transfer tests in disposable state, with the live fleet-QA
selector absent. The package was not installed or launched.
