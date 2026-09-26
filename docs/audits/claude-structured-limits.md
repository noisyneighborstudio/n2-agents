# Current Claude allowance response

The sanitized September 26 response in `tests/fixtures/claude-usage-current.json`
contains session usage of 1%, weekly usage of 56%, and a model-scoped weekly
allowance of 0%. Its separate product-share breakdown attributes 99% to Claude
Code. That percentage is not quota utilization.

The reader excludes `seven_day_breakdown` from allowance windows and retains
structured session, weekly, and model-scoped limits, including entries marked
`is_active: false`. Duplicate or conflicting limits and unsupported structures
produce unknown usage rather than advertised capacity. Legacy windows still work.
Only the observed `normal` severity is recognized; an unfamiliar severity remains
unknown until its semantics are established. No authentication behavior changes.

Canonical guidance explains shared Claude usage and variable limits:
- https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work
- https://support.claude.com/en/articles/9797557-usage-limit-best-practices

Those pages do not document this exact response schema. The checked-in provider
fixture supplies the wire-format evidence; tests do not establish every future
provider response shape.

Proof: `sh scripts/test-usage.sh` passes the actual reader output to the native
usage parser. It checks 56% displayed usage and three allowance windows, then
changes only the model allowance to 100% and checks native exhaustion and the
CLI reserve gate. Malformed percentages yield `fetch-error`. The focused reader
case also runs in `scripts/smoke.sh`.
