# Native owner-managed sign-in route spike

The native shared `AppDelegate.signIn` action builds `agents login PROFILE --vendor
codex`. Its confirmed path says the current login will be removed. Setup also
builds its command through `loginCommand`.

Codex currently has no `vendor_account` label, so its confirmed "Sign in again"
account row is absent. Its local-file authentication check sees no auth.json for
an owner-managed slot, exposing "Fix → Sign in" with `confirm: false` instead.
That button reaches the same rejected CLI route. The fix must handle this real
entry point and offer an owner-specific confirmation even when the caller assumed
the slot was signed out. Do not depend on a Codex account label to expose recovery.

`cmd_login` attempts ordinary vendor logout/login. `exec_vendor` rejects these
commands for an owner-managed Codex profile before invoking the provider. A
successful owner login instead uses `agents fleet auth login PROFILE
--expected-revision REVISION`. This operation preserves the old grant for existing
sessions and requires the same account unless account replacement is explicitly
requested. A remote owner also requires its existing sign-in-management consent.
The native action currently never reaches this operation.

## Recorded proof

The adjacent JSON records two disposable cases, local owner and remote owner.
Both actual `agents login Work --vendor codex` invocations returned exit code 1
with an owner-managed refusal. Binding and private grant files stayed byte-identical.
The synthetic provider trace contained no login/logout call. The fixtures used
isolated roots, temporary fleet identities and the repository's synthetic owner;
no real credentials or provider login were used. The exploratory program ran from
stdin and was discarded. The source revision is recorded in the fixture; subsequent
session-recovery changes do not alter the inspected sign-in paths.

## Next implementation brief

On the native sign-in action, asynchronously read `agents profiles --json`
for the selected Codex slot. Require a unique matching profile and supported public
owner-route shape. A registered owner binding supplies the owner identity and
revision for a confirmation and the command above. Keep the same account by default;
do not add `--replace-account`. Preserve the revision observed for confirmation so
an intervening binding change refuses. Missing, conflicting, migration-pending,
invalid or failed reads must not fall back to ordinary provider logout/login.
An explicitly unmanaged slot retains the existing legacy flow. Other vendors retain
their existing commands.

The owner confirmation should say that sign-in runs on the configured account owner
and keeps the same account; it must not promise removal of the current login.
Continue showing challenges and errors in the terminal and refresh the panel after
completion. Both Fix and Configure entry points must support owner recovery.
Canceling the owner confirmation must launch nothing. Profile setup must not
silently reuse the rejected command for an already owner-managed slot.

Prove the complete action with native routing/confirmation tests for local and remote
owners, unmanaged slots, malformed/pending/conflicting routes, stale revision and
cancellation. Run the generated command against disposable local and remote owner
fixtures to demonstrate the existing sign-in-management consent gate and successful
synthetic challenge/completion, without real credentials. Verify the packaged native
confirmation view and command integration. This slice does not redesign owner login,
change accounts, grant remote permission automatically, or perform live acceptance.
