# Fleet profile sync QA spike

Based on current main (`436b861`), with transport and replication recovered from
PR #3 and its unpublished sync hardening. Task dispatch is outside this spike.

## Run alongside the primary app

Build with `N2_QA=1 N2_FLEET_QA=1 ./tray/build.sh`. Copy the resulting bundle to
`~/Applications/N2-Fleet-QA.app` on each participating Mac. Keep that path: SSH
routes use it without depending on the primary CLI or login-shell PATH.

The QA bundle has a separate bundle identifier, disables updates and the global
shortcut, and does not install CLI shims. Its bundled CLI detects a `fleet-qa`
marker and uses `~/.n2-agents-qa`. Profile switching, login/logout, agent launch,
profile creation/deletion, adoption, transcript transfer and shim installation
are disabled in this bundle. Primary application files and profile symlinks are
not replaced. This is an isolated sync trial, not continuous mirroring from the
primary profiles into QA.

Open **Settings → Fleet profile sync** in the QA app. Settings, skills, MCP and
credentials have separate local switches. Credentials also require opting in
each provider on both participating machines. An MCP configuration can contain
credentials, so its provider must also be opted in. Category settings and peer
exceptions are local policy; they do not automatically change another Mac's
sharing choices.

The UI provides import, sync now, background sync, peer status and conflict
resolution. Import copies missing files from existing local profiles into QA;
it never replaces existing QA files. The CLI equivalent is:

```sh
qa="$HOME/Applications/N2-Fleet-QA.app/Contents/Resources/agents"
"$qa" fleet init --machine "$(hostname -s)"
"$qa" fleet sync import-local --credentials
"$qa" fleet sync auth enable codex
"$qa" fleet sync auth enable claude
"$qa" fleet sync auth enable grok
"$qa" fleet sync auth enable muse
"$qa" fleet sync categories skills on
"$qa" fleet sync categories auth off
"$qa" fleet sync service install --interval 60
```

Imports include allowlisted settings, skills, instructions, hooks, commands,
MCP files and credential files. Session histories, caches, archived skills (`.trash`), dependency trees and
desktop browser profiles are excluded. Linked files escaping a slot and linked subdirectories
are not imported. Adopted vendor-slot symlinks are followed into their source
slot, but QA stores independent copies, not symlinks back to production.

## Enrollment

SSH Remote Login and pre-existing SSH access are required for the first hop.
Use Tailscale DNS names as the SSH addresses. No host verification is disabled.

1. Run `fleet init` on each Mac and obtain the joining Mac's `fleet id`.
2. On an already enrolled Mac, run `fleet invite --peer <joining-id>` and
   `fleet id --host-key`. Transfer the one-use code and public host key through
   the already authenticated management connection.
3. On the joining Mac, run `fleet pair --to <tailnet-name> --user <user>
   --code <code> --host-key '<line>'`. Set `N2_FLEET_SELF_ADDRESS` to its tailnet
   DNS name if its local hostname differs. Codes bound to that exact identity
   constitute approval; unbound requests remain pending for approval.
4. Repeat for the other peer pairs. Check `fleet peers` from every Mac.

Enrollment adds tagged, restricted QA fleet-key entries to `~/.ssh/authorized_keys`.
Those entries only run the fleet responder. Each Mac retains its own identity,
roster, pinned host keys and sync state. There is no required central Mac.

## Conflict handling and scope

The first pass combines missing profiles and nonconflicting resources. Different
existing versions of the same resource become conflicts. There is no automatic
"newest wins" policy, including for credentials. The Settings panel offers
**Keep this Mac’s version** and **Use peer’s version** for each conflict.
The CLI also supports `fleet sync conflicts`, `show`, and `resolve`.

Disabling a category withholds it; it does not delete the other Mac's copy.
Re-enabling catches up or raises a conflict when both copies changed. Sync
includes profile existence, so deleting an established QA profile can propagate;
unsynced local files block destructive profile removal.

## Credentials: what this spike proves

Credential bytes replicate only after explicit category/provider choices.
Tests use synthetic values, and the live trial uses isolated copies. Replication
alone is not evidence that a provider accepts copied authentication on another
Mac, nor that concurrent token refresh is safe.

- Codex, Grok and non-Default Muse profiles use file credentials that can be copied.
- Claude import can read the profile-path-specific Keychain entry and export a
  snapshot into the QA slot's `.credentials.json`. The primary Keychain entry
  is never changed. This is a snapshot, not continuous Keychain synchronization.
- Cursor's CLI login is machine-wide in Keychain. This spike does not replace it.
- OpenCode credentials remain outside its isolated configuration slot; auth
  opt-in is refused until that isolation is implemented.
- Default Muse's Keychain login is not exported.

Live validation on 2026-09-25: the Mac mini successfully queried read-only usage
endpoints using five copied Codex profiles and five copied Claude profiles; one
Claude profile reported no token. This verifies those credential snapshots were
accepted on a receiving Mac. No login reset or token refresh was performed.

No claim is made that every provider has working cross-machine sign-in. The
provider controls report `partial`, `unsupported` or `unverified` accordingly.

## Stop the trial

On each Mac, run `"$qa" fleet sync service uninstall` and quit only the QA app.
To remove trust, use `fleet revoke --propagate <peer-id>` and verify the tagged
QA SSH grants are removed. Keep QA profiles until their results are no longer
needed. Removing the app alone does not uninstall its background job.

## Verification

```sh
./scripts/test.sh
sh scripts/test-fleet-spike.sh
python3 scripts/test-fleet-manifest.py
N2_FLEET_SUITES=transport N2_FLEET_REQUIRE_LIVE_SSH=1 sh scripts/test-fleet.sh
sh scripts/test-sync.sh
N2_QA=1 N2_FLEET_QA=1 ./tray/build.sh
```

The focused spike test covers category disable/re-enable in both directions,
synthetic credentials and skills, QA import isolation, reserved fleet state,
profile command guards, and enrollment's reverse-direction host-key alias.

## Initial live rollout

The MacBook, `seth-webster-m4` and `seths-mac-mini` run the QA bundle at the path
above, with all three peer pairs enrolled. `sethwebster-expo` was offline and
could not be installed or enrolled. Background jobs use
`com.n2agents.fleet-sync-qa` with a 60-second scheduling interval; a large pass
can take several minutes, and launchd does not overlap instances of that job.

For the initial large skills tree, missing allowlisted QA files were bulk-seeded
over existing authenticated SSH connections. Existing files were not replaced;
the normal signed sync protocol reconciles subsequent changes and presents
conflicts. This initial copy is not used as evidence of automatic replication.
The separate `FleetSyncProbe` profile was delivered automatically to the Mac mini;
a normal signed `sync-put` request also verified delivery to the M4 while its
initial reconciliation was still running. The synthetic file matched on all
three machines. This distinguishes the automatic check from the explicit check.

Final candidate verification on 2026-09-25:

- Current-main regression suite: passed.
- Transport: 338 passed, 0 failed, 0 skipped, with live SSH required.
- Sync: 637 passed, 0 failed across all 75 sections.
- Focused spike checks: category switches, credential withholding/re-enable,
  isolated import, command guards and reverse enrollment pins passed.
- Fast manifest equivalence: binary files, symlink containment, cycles, excluded
  caches and credentials matched the original shell scanner.
- Signed QA build: passed. Installed runtime hashes matched source on all three
  online Macs; each QA background service reported loaded.
- Read-only live auth: five Codex and five Claude QA profiles accepted on the
  Mac mini; one Claude profile had no token.

Initial reconciliation remains asynchronous. Existing differences are preserved
as conflicts for the operator; these checks do not assert that all existing
skill/configuration conflicts have been resolved. Primary app processes remained
running throughout the rollout.
