# Claude store errors and cached credentials

## Proof

Nine synthetic cases compose the exact synchronous Keychain reader, fallback
combiner and OAuth accessor extracted from provider-distributed Claude Code
2.1.283. The fixture records binary/function hashes and source offsets. The
clock, cache, command, file store and mode flags are synthetic. No provider
process, real credentials, Keychain query, renewal or network request ran.

| Cache and read | Provider accessor selection |
| --- | --- |
| Empty cache, successful read | Keychain |
| Empty cache, simulated command error, timeout or malformed JSON | File |
| Stale cache, simulated read failure | Cached credential |
| Fresh cache, changed backing store | Cached credential; no command |
| Stale cache, successful read | Newly read Keychain credential |

Labels 1/36/44 denote synthetic thrown command errors. The real command wrapper
was not exercised, so these cases do not establish its handling of exit codes.
Mode flags and plaintext transformation were stubbed; alternate and asynchronous
strict readers are outside this proof.

N2's actual credential reader was separately exercised with a disposable file
and mocked security results. Success selected Keychain; exits 1/44 selected the
file; exit 36 reported unavailable; malformed JSON reported fetch-error. Timeout
raised to an outer collector boundary not exercised in this spike. The fixture
records the N2 source hash. These results justify no broader error-policy change.

Independent review verified all three provider function hashes and reran all
nine composition cases. Exploratory runner code was discarded after review;
canonical excerpts, synthetic observations and notes were retained.

## Consequence for fleet and T3 binding

A standalone measurement of current stored credentials cannot establish the
cached credential of an already-running external provider process. The account
used by that process needs independent runtime evidence. A shared profile label,
symlink or current file content cannot supply that evidence.

This does not identify the cached account in the historical M4 incident or prove
which credential a later HTTP request used. Existing managed-provider binding
and the T3 adapter still need their own end-to-end account/rejection evidence.
The cache observation is a limitation to preserve, not a reason to mark those
requirements complete or to change measured account identity.
