# Native saved-session transfer

The Codex session row's overflow and context menus offer **Send to Machine…**.
The action reads approved peers, asks for an explicit absolute destination
path, and calls the existing signed `agents fleet session send` command.
Confirmation copies saved history; it does not move a running process or copy
workspace files. The destination must already have the directory and account
binding needed by the existing CLI importer.

The UI shows success only for a matching saved-thread receipt. It displays the
canonical path returned by the destination. A failed command or invalid receipt
shows an unconfirmed outcome, allowing for a reply lost after delivery. The CLI
continues to enforce peer approval and original-account preservation. Cancellation
before dispatch sends nothing. Once dispatched, the operation runs to its receipt;
there is no promise of cancelling an in-flight transfer. Duplicate UI requests
are refused while one is pending.

## Proof

- `sh scripts/test-native-session-transfer.sh` compiles the production action with
  warnings as errors. Event-based checks cover literal arguments, approved peers,
  user/task cancellation before dispatch, unavailable peers, duplicate requests,
  background execution, refusal and matching/canonical-path receipts.
- The same command drives the production coordinator through the real CLI and
  signed disposable peers. It verifies discovery, resume on the original account,
  later account replacement, an unapproved sender, and a destination symlink
  containing spaces and shell punctuation. No provider credentials are used.
- The command is included in full regression and smoke. The full app typecheck
  and package include the new component; both session menus use the same action.

The ad-hoc signed QA package passed deep/strict signature verification with the
live fleet-QA selector absent. Its actual session overflow menu opened the native
confirmation. A missing destination produced an actionable refusal; a valid
path produced the success dialog. Direct destination inspection verified the
original binding, canonical path and selected model. The fixture used temporary
homes, synthetic providers and a signed local carrier with network denied, not
physical machines or a live provider. Screenshots and source/binary fingerprints
are retained in the sibling QA artifact directory `native-transfer-preview`.
The test app and disposable fleet were removed after verification. Independent
review reconstructed the test bundle identity/signature from the retained QA
package and matched the recorded executable SHA-256 exactly.

A discarded source copy that bypassed confirmation compiled successfully and
then failed the native cancellation assertion. The restored focused gate passed.
Independent correctness review found no remaining demonstrated issue. Final
formatting, lint, full regression and smoke passed with the final refusal wording
and the separately committed lifetime-test cleanup repair. This slice does not
complete fleet authentication retirement, notification/reconnection acceptance
or live-provider verification.
