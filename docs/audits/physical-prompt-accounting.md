# Physical Codex prompt accounting acceptance

September 27, 2026. Runtime source `e936f91e58e72f122333a8e45e055eff7ff7498f`.
This is synthetic-provider acceptance over physical SSH, not live-provider usage.

`python3 scripts/accept-physical-prompt.py --peer sethwebster@100.88.174.82`
passed from seth-agent to macbook-m5-pro-max-sdw. Actual `agents fleet task run`
created five tasks, each executed once on the M5. The helper did not manufacture
journal events. Signed sync transferred the receiver's original events and IDs.

| Phase | Events | Reported total tokens | Active restrictions | Unconfirmed tasks |
| --- | ---: | ---: | ---: | ---: |
| Success | 2 | 60 | 0 | 0 |
| Quota rejection | 4 | 120 | 1 | 0 |
| Different selected model succeeds | 6 | 180 | 1 | 0 |
| Original selected model recovers | 8 | 240 | 0 | 0 |
| Interrupted turn | 9 | 240 | 0 | 1 |

Every confirmed turn reports 30 cached input tokens within its 60 total tokens.
The interrupted turn retains null counters; the provider process is gone after
cleanup. Signed redelivery of the first task leaves the summary and five-turn
count unchanged. The offline `--skip-exchange` negative control fails at the
missing exchanged-events assertion. CI runs the same driver with `--peer local`.

Only private disposable roots, synthetic credentials, fake Codex/security
executables and the existing strict SSH trust were used. No live profiles,
provider calls, production enrollment or application installation occurred.
The physical driver subsequently gained cleanup-error receipt retention only;
its dispatch and accounting assertions were unchanged. The final driver is also
exercised by the local full test gate. Native UI and OS notification delivery
are outside this proof.

Durable receipts: `/Users/sethwebster/Development/n2-fleet-qa-artifacts/physical-prompt-accounting`.
SHA-256:

- `m5-receipt.json`: `882aa0dc76d15b55798aec1dcf52ae32400741f63429944c6f085df7e68521f6`
- `m5-cli.json`: `5626626ac345af94239a7842ec00845c6a3433e92b1213a6cf811ea0ad71de69`
- `negative-receipt.json`: `ae417bebdc2e8f2714482258c2806af369648b4805d1a9e00beb090e9b9d1396`

Local format, lint, full tests and smoke passed with exit zero. Gate log:
`/private/tmp/n2-physical-prompt-gates.log`. Independent source and receipt
reviews found no actionable issue; all three durable hashes were verified.
