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

The embedded console handles Command-V while focused. Paste code also pastes
through SwiftTerm's clipboard action and returns keyboard focus to the prompt.
Press Return to submit. `swift test -c release --filter NativeAuthTests` proves
both input routes reach a real PTY using a synthetic clipboard action.

`sh scripts/test-profile-setup.sh` exercises both first-use and reset entry paths
with a fake host. It verifies restart, cancellation, profile binding, stale
callbacks, failure retry and subsequent progress. It does not claim acceptance
against Anthropic's live browser flow.
