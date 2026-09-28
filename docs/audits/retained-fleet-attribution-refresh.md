# Retained fleet evidence and the running M5 app

Collection on September 27, 2026 at approximately 06:27 UTC used existing SSH
routes and SQLite `mode=ro` with `PRAGMA query_only=ON`. Each database read used
one transaction. No provider was polled, no account was opened, and no credential
contents were read. See the [sanitized receipt](retained-fleet-attribution-refresh.json).

## Coverage

| Machine and root | Result |
| --- | --- |
| seth-agent, `~/.n2-agents` | Six measurement events, no task events. Latest Codex Default and ExpoIO observations are about 21.5 hours old. |
| M4, `~/.n2-agents` | No journal at the checked path. |
| M5, `~/.n2-agents` | No journal at the checked path. |
| M5, `~/.n2-agents-qa` | No journal at the checked path. |

The local observations retain exactly the timestamps in the earlier September
27 audit. Default reported 2% used; ExpoIO reported 100% and a reached-limit
restriction. Both contain verified account hashes, and those hashes differ.
These are historical readings. Neither proves current headroom, nor identifies
the account used by the failed M4 T3 session. Missing journals do not imply zero
usage or absence of an app; other roots were not searched exhaustively.

## Installed M5 source differs from this PR

The running M5 process points to `/Applications/N2 Agents.app`. Its plist reports
version `1.4.1-continuous.1`, build `54`, bundle `dev.sethwebster.n2agents`, without
the fleet-QA selector. The bundle has no `usage.py`, `usage-store.py`, or
`codex-rpc.py` resource. Its bundled `agents` has SHA-256
`4b6dc117b9a836cf69c6e7cb21bb6aa2cac6d0d203023bc990d8eacd60d7c1d5`.

Static inspection of that exact source found:

- `usage_table` embeds the old provider readers and emits percentage rows. It
  does not record the journal inspected above.
- `claude_creds` searches multiple service paths and a credentials file, then
  selects the candidate with greatest expiry. It omits the Keychain account
  selector. This predates the credential-precedence repairs in this PR.
- `pick_best` converts missing quota columns to zero when the row status is
  `ok`. It cannot
  establish fresh account-bound fleet capacity from those rows.

The source was copied for inspection and never executed. Its behavior is not a
new live measurement. This deployment difference explains why checking the new
journal cannot recover the running app's readings. It does not establish the
original incident's account or prove that the installed app caused that failure.
No app was replaced, restarted, installed or deployed.

## Collector proof and next action

The temporary collector validated event digests and agreement between indexed
columns and event bodies. A disposable SQLite fixture proved three observations
of one task become one latest task, unknown tokens stay null, original times
stay unchanged, and the main database hash remains unchanged. A write attempt
against that disposable read-only connection was refused. Corrupting only its
timestamp column made collection fail, the deliberate negative control.

The live snapshot contained no task events, so synthetic deduplication is not
claimed as observed task attribution on these machines. Repeating these same
journal reads cannot supply fresh capacity. The next proof must address the
installed measurement path or collect provider observations under an authorized
lifecycle, then distinguish that evidence from this PR's isolated tests.
