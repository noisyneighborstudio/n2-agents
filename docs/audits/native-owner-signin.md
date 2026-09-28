# Native owner sign-in

Fix, Configure and setup now read the selected Codex profile's public route off
of the UI thread. A registered binding produces an owner confirmation and
`agents fleet auth login PROFILE --expected-revision REVISION`. The confirmation
is required even when the caller considered the slot signed out. It explains
same-account sign-in, retained session accounts and remote management permission.
No account replacement or permission grant is added.

Malformed, conflicting, pending or failed reads refuse the action. Explicitly
unmanaged slots and other vendors retain their existing login commands. Copying
a setup command resolves the same route without starting login. Setup receives
completion after failed terminal commands and when confirmation is cancelled or
the route cannot be read; it checks authentication separately.

## Proof

- `sh scripts/test-native-signin.sh` checks command selection, invalid bindings,
  confirmation, cancellation, stale responses, copying and terminal completion.
  Its CLI integration executes the generated command against disposable local
  and remote owners, checks stale revision and consent refusals, observes a
  synthetic challenge, and verifies completion without changing the account or
  retiring the original session grant.
- The proof runs in the full test gate and smoke gate. A discarded source copy
  with owner confirmation disabled fails the cancellation assertion.
- `sh scripts/render-native-signin.sh /tmp/n2-signin.png` captures the production
  confirmation view using a synthetic owner. This optional GUI proof requires
  window capture access and makes no provider calls.

The rendering spike found that an unshown alert bitmap omitted its text and that
an early window capture caught the opening animation at 28 by 36 pixels. A
synchronous AppKit lifecycle, window-update receipt and disabled test animation
produced a readable capture. The renderer has bounded event/capture waits and
terminates its disposable process. The exploratory source was discarded.
Apple documents `layout()` as immediate layout and `runModal()` as the modal
presentation operation: [NSAlert](https://developer.apple.com/documentation/AppKit/NSAlert).

The reviewer withdrew a proposed same-row start/copy race after inspecting the
setup UI: Copy is available in the failed state, not while signing in.

The ad-hoc QA app passes signature verification. Its byte-matched bundled CLI
and owner helpers pass the same native-generated local and remote command tests
in a disposable root, with the live `fleet-qa` selector absent. A separate
user-openable preview uses private HOME/state and fake provider executables.
Nothing was installed or launched as part of package verification.

These checks use synthetic providers. They do not prove live-provider acceptance
or fix the separate owner-managed authentication-status reporting gap.
