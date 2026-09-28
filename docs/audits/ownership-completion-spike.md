# Ownership completion spike

Source: `cd7d292d0658bd5b6ea0c540e76f76b1f73dae45`.
Recorded observations: [sanitized fixture result](ownership-completion-spike.json).

## Proof

`python3 scripts/test-fleet-auth-migration.py` passes all eight tests. These
exercise inventory, local barriers, malformed state, explicit abandonment,
interrupted rollback, and refusal to migrate an already registered profile.

A disposable `ManageTests` fixture supplied two approved peers. Both received
`Work` with the same stable profile ID and synthetic credential files. Through
the actual CLI, `migration-begin Work` on the coordinator returned
`migration-pending`. `migration-status Work` on the second peer still returned
`inventory-only`; its marker was absent and its synthetic file was unchanged.
Registration on the pending coordinator failed. `migration-complete` was not a
supported command. No live credentials, keychain, provider calls, or real peers
were involved. Exploratory code was discarded; the sanitized observations remain.

The initial probe used owner `status` on the unregistered peer, which is not an
inventory command and returned unavailable. Repeating with `migration-status`
established the peer's state. This does not prove legacy execution occurred.

## Required next behavior

The acceptance contract in `docs/fleet-auth-ownership.md` requires migration and
sync exclusion across offline peers, queued transfers, and old grant copies.
A local marker cannot satisfy that contract. The next vertical slice is explicit
peer preparation: a consenting peer accepts the coordinator's exact pending
migration through the signed fleet channel, installs the barrier under the same
slot locks as sync, and returns a recipient-bound acknowledgement. The CLI must
show that peer prepared, while still reporting migration incomplete.

Use stable profile identity, not its display name. Preserve credential bytes and
all unknown keychain/embedded-copy/revocation evidence. Refuse stale revisions,
conflicting migration IDs, missing consent, and wrong recipients. A prepared
peer must not independently abandon the coordinator's marker. An offline or
unreachable peer stays unacknowledged. Acknowledgement proves the managed barrier,
not retirement of credentials or termination of unmanaged sessions.

Later slices still need grant retirement/revocation, keychain handling, fresh
owner-grant activation, verified completion, and recovery. Do not replace those
requirements with a flag or declare ownership complete after peer preparation.

## Existing transport boundary

`fleet_serve` verifies the sender's signed request before dispatch. Generic
`fleet_call` replies use an `OK`/base64 wrapper, not a durable signed migration
receipt. Reuse the fleet envelope/signature machinery for the public receipt and
bind it to the exact request, recipient, profile, migration ID, and revision.
The login-response schema and login consent require an existing owner grant;
they cannot represent legacy migration without inventing grant fields. Migration
consent must instead be explicit and scoped to the stable profile and coordinator.
