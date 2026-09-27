# Usage freshness

A reading older than 15 minutes, future-dated, or followed by a failed refresh is
unavailable for capacity display. The resident app expires successful rows every
30 seconds, even if a collector has not returned. Summary, provider row and
expanded details use the same availability rule. History retains its original
timestamp; unavailable details show dated values as text rather than live gauges.

A nonzero collector exit marks prior rows failed and preserves history. A first
failure produces an explicit unavailable row for known profiles. A successful
authoritative empty response removes rows. Mixed known/unknown profiles do not
publish a partial overall percentage or Ready state.

Proof: `sh scripts/test-usage.sh` compiles the actual model and checks injected
expiry times, row/command failures, history, removal, recovery and mixed summaries.
Native typechecking runs in the full suite. This change does not establish account
identity, repair provider window semantics or redesign aggregation of known quotas.
