# Account setup

First-use onboarding, Finish setup, and the Settings account actions use the
same `ProfileSetup` window and provider sign-in actions. Reset queues the
existing profiles through that window after sign-out. Sign In to Missing
Accounts reads logins fresh and queues only profiles with labs known to be
signed out or left pending by setup. Labs whose login can't be inspected are
skipped rather than guessed.

While a provider is signing in, Reopen cancels its embedded login process and
starts a fresh login for the same profile and provider. Use it when a browser
account switch leaves authorization waiting. Failed sign-ins use the same
action through Try again. Late callbacks from replaced sessions cannot change
the current sign-in. Pending providers stay pending until sign-in completes.
When setup confirms a login landed, the panel re-reads sign-in state and usage
at once instead of waiting for its next open or cached reading to expire.

The embedded console handles Command-V while focused. Paste code also pastes
through SwiftTerm's clipboard action and returns keyboard focus to the prompt.
Press Return to submit. `swift test --filter NativeAuthTests` proves
both input routes reach a real PTY using a synthetic clipboard action.

`sh scripts/test-profile-setup.sh` exercises both first-use and reset entry paths
with a fake host. It verifies restart, cancellation, profile binding, stale
callbacks, failure retry and subsequent progress. It does not claim acceptance
against Anthropic's live browser flow.

Sign-in clears a signed-out slot's leftover credentials before logging in, not
only after a logout. A named Muse slot can keep a keychain reference from an
older backend; Muse's file backend then refuses to save the new login (FM-008).
`python3 tests/ReonboardTests.py` reproduces that failure with a fake `muse`.

The menu bar icon shows a yellow warning triangle while any profile has a lab
known to be signed out or an unfinished setup, the same set Sign In to Missing
Accounts queues. Logins that can't be inspected don't raise it.
