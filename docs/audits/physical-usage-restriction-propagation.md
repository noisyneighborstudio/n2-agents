# Physical usage restriction propagation

September 27, 2026. Source base `a31b7aed2655a84d112653be72907c7dd1f0b4a0`.

## Proof

```sh
python3 scripts/accept-physical-usage.py --peer sethwebster@100.88.174.82
python3 scripts/accept-physical-usage.py --peer sethwebster@100.88.174.82 --skip-exchange
```

The first command exited zero. The negative control exited one at
`received: matching account expected restricted`. Without exchange the receiver
still reports the synthetic matching account as eligible. An earlier fixture
attempt stopped before observations because its hyphenated profile names were
invalid; the retained proof uses valid `LocalName` and `RemoteName` labels.

The M5 originated the rejection and seth-agent pulled it over the existing
trusted SSH route. Six stages passed:

| Stage | Same account, different profile | Different account | Rejections |
| --- | --- | --- | --- |
| Received | restricted | ok | 1 |
| Reopened and replayed | restricted | ok | 1 |
| Success started before rejection | restricted | ok | 1 |
| Success on another model | restricted | ok | 1 |
| Qualifying later success | ok | ok | 0 |
| Recovery replayed | ok | ok | 0 |

Every stage checks the complete original rejection, including ID, origin and
observation time, appears exactly once. Fresh helper processes reopen the journal;
actual CLI sync ticks exercise signed, paginated exchange. Synthetic task IDs,
account hashes and original events are retained in the
[receipt](physical-usage-restriction-propagation.json), which hashes the full
local receipt and CLI transcript plus durable copies under
`/Users/sethwebster/Development/n2-fleet-qa-artifacts/physical-usage-restrictions`. Unknown token totals remain null.

## Boundary

The fixture copies tracked runtime files into private temporary roots, pairs only
disposable peers, and uses the existing SSH key by path. It never reads/copies the
private key or calls a provider. No real profiles, production enrollment, app
installation or deployment occur. Both disposable roots remain for inspection.

Synthetic observations use the production journal API. Eligibility assertions
call its production effective-measurement function; this does not prove a native
UI, scheduler launch, live account identity or current provider headroom. It also
does not replace the existing offline long-retention and 8,106-entry paging tests.
The current transport pulls, so M5 is the origin rather than the receiver.
Independent source security review found no actionable issue. The supervisor
independently checked all six positive receipts and the intended negative failure.

Formatting, lint, the full repository test suite and smoke passed locally.
Logs are `/private/tmp/n2-physical-usage-gates.log` and
`/private/tmp/n2-physical-usage-smoke.log`. This opt-in physical acceptance is not
run by headless CI; CI runs the repository's four standard gates.
