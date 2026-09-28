# Owner-managed authentication status

`agents authed PROFILE` and `agents porcelain` now use the owner binding for
managed Codex slots. An active local grant with matching ownership identity and
unchanged credential revision reports `yes`. Retired and reauthentication-required
grants report `no`. Remote bindings, renewal, pending migration, conflicts,
malformed state, unreadable owners and missing or changed credentials report
`unknown`. An ownership conflict still takes precedence when the binding file
is absent and a legacy credential file remains.

The observation does not contact a provider, refresh credentials or test remote
reachability. A remote binding therefore reports `unknown` both online and offline.
A local `yes` means a verified stored credential is present, not that the provider
currently accepts it or that quota remains. Unmanaged slots retain their existing
credential-file check. Both native snapshot and setup parsers preserve unknown
as an absent boolean, rather than claiming signed-in or signed-out state.

The shared vendor check also feeds existing CLI slot eligibility. Unknown remains
subject to the existing usage/freshness admission checks; this change grants no
usage capacity and does not bypass owner-bound launch validation.

## Proof

`sh scripts/test-owner-auth-status.sh` runs real CLI snapshot and setup checks
against disposable local and remote owners and passes their output through the
production Swift parsers. It covers active/retired/renewing/reauthentication states,
remote and offline owners, malformed and pending records, conflicts without a
binding, missing/changed credentials and unmanaged compatibility. Provider traces
and credential/grant hashes remain unchanged. The baseline active-owner case
failed with `codex no` before the change.

The test runs in full regression and smoke. No live provider credentials or
real fleet configuration are used.

Local formatting, lint and full regression passed. The initial smoke run hit the
previously recorded lifetime-test cleanup permission error after its EOF
assertions. A bounded process-group diagnostic did not reproduce it; the unchanged
smoke rerun passed. The cause remains unresolved in `docs/slices.md`.

The ad-hoc QA app passes signature verification. Its byte-matched bundled helpers
pass all seven status cases and native parser checks in disposable state, with
the live `fleet-qa` selector absent. Nothing was installed or launched.
