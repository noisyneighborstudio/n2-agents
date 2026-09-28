# Native ownership-flow spike

At `817345314ab7f757d9424068c327f30313bf43aa`, the native fleet panel cannot
show which machine owns a profile's account or whether its grant is retired.
`FleetControl.refreshFleet` reads status, peers, sync, conflicts, exceptions,
tools, tasks, and notices. Neither it nor `FleetSettingsLoader.commands` calls
`fleet auth status`. `FleetSyncSettings` renders provider-level credential-sync
support rather than profile-level ownership. `PanelModel` can explain migration
pending, but does not expose an ownership inspection action.

## Evidence

`env -u N2_AGENTS_ROOT -u N2_FLEET_QA sh scripts/test-native-ui.sh` passes all
existing native model/action checks. Those checks cover enrollment, sync,
dispatch, notices, and task actions; their success does not prove ownership UI.

The adjacent JSON records actual `agents fleet auth status Work` responses from
disposable roots with generated identities and synthetic credentials. Before
registration, status exits 1 with a generic diagnostic and no JSON. Registration
produces `active` with public account, owner, and grant identifiers. Retirement
preserves the binding and changes status to `retired`. No provider request or
real credential change was made. The exploratory capture code was discarded.

`fleet-auth-manage.py:status` also reports remote-owner, migration-pending,
migration-invalid, conflicting, and binding-mismatch. Remote-owner describes
local binding metadata; it does not probe the owner or prove runnable capacity.
The UI must preserve command failure and unknown states, and must not interpret
an active authentication grant as available model quota.

## Next slice

Add an Account ownership action to native Codex profile details. It reads the
existing status command off the main thread and shows the profile, owner machine
or identity, account identity, and state. A missing or unreadable binding shows
unavailable with the command diagnostic. Failed refresh clears previous success.
Opening this view does not register, migrate, refresh credentials, or log in.

Proof: pass recorded CLI responses through the production native parser and
render the actual detail view. Exercise the native action through a disposable
command fixture and assert the requested profile, retired/missing state, error
replacement, and event-based responsiveness. Active means authentication state,
never quota headroom. Existing usage eligibility behavior must remain covered.
Later slices still owe login/reset, migration/repair actions, owner disconnection,
and the complete native fleet acceptance requirements.

## Implemented status view

The native Codex profile now offers Account ownership under Configure. Opening
it reads `agents fleet auth status` for that exact profile in a background task.
It displays the owner identity, account fingerprint, and authentication state;
it never alters the usage reading or starts authentication. A failed refresh
clears earlier account details, and a late result cannot replace a newer profile.

`sh scripts/test-account-ownership.sh` checks recorded active/retired responses,
missing and malformed status, command arguments, background loading, immediate
stale-result replacement, and out-of-order completion using event barriers.
An optional PNG path renders the production detail component for visual review.
The smoke gate runs the same proof; removing stale-result clearing in a discarded
copy must make that gate fail. This is component and action testing, not completed
live fleet GUI acceptance or proof of owner reachability.
