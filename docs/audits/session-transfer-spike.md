# Native saved-session transfer spike

Observed with installed Codex 0.157.1 against N2 commit cfdc596. The native
app-server ran in separate disposable HOME/CODEX_HOME directories under an OS
sandbox denying all network access. No real credentials were present or copied.
The model provider pointed at an unused loopback port and required no OpenAI auth.

## Recorded proof

The destination first rejected resume because it had no rollout for the thread.
Copying one `sessions/.../rollout-*.jsonl` file then let it resume the same thread,
return the original user turn, and accept an explicitly remapped working directory.
Both resume and a subsequent full-history read contained the synthetic marker.
No database, WAL, configuration, installation identity, logs, skills, or credential
file was transferred. The destination did not create `auth.json`.

The source turn did not complete within the 20-second observation guard with
network denied. Teardown interrupted it and persisted `turn_aborted`; that saved
history was used for the successful transfer. This is not a successful model turn
or proof of live continuation. An earlier injection-only experiment resumed but
returned no visible turn history, so it was not used as continuity evidence. The
first request also exposed the installed version's `read-only` sandbox spelling;
the rejected `readOnly` request changed no thread state.

The adjacent JSON records the cases and observed rollout record types. Raw
synthetic responses remain in the local QA artifacts directory. Exploratory
programs are discarded. No transfer implementation is landed by this spike.

## Provider contract and N2 requirements

The [official app-server documentation](https://learn.chatgpt.com/docs/app-server)
defines resume by saved thread ID and describes persisted JSONL rollout logs.
Its thread-list operation normally scans logs to repair database metadata. These
docs do not promise a complete cross-machine export format; rollout-only sufficiency
here is experimental evidence for the recorded case and version.

N2 separately requires its immutable thread-to-owner record, selected-model
sidecar, and explicit working-directory mapping. `Sessions.home` derives the local
home from the full binding and local directory. Copying a provider rollout alone
cannot create that binding or authorize access to the original owner's grant.
No credential or entire provider-home copy belongs in a session transfer.

## Next implementation brief

Add one explicit saved-session send through the approved-peer signed carrier.
Capture a bounded, stable snapshot of the selected rollout plus its original
owner/account record and selected model. The destination explicitly maps cwd,
validates the binding, rejects a conflicting existing thread, and atomically
publishes private history before the N2 session browser exposes it. Interrupted
imports must not leave a resumable partial session. Resume remains bound to the
original grant; a revoked or unavailable owner must never trigger account fallback.

Prove this with a signed two-root transfer followed by actual CLI discovery and
resume under the existing synthetic owner, plus refusal and interrupted-import
cases. Preserve this native fixture as evidence for the transferred artifacts.
Exclude live process migration, credential transfer, automatic grant creation,
merging divergent histories, and live-provider acceptance. Those exclusions do
not replace the remaining fleet acceptance requirements.
