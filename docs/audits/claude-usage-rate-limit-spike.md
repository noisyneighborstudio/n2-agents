# Claude usage rate-limit spike

Question: what does `GET /api/oauth/usage` limit on, and what does it tell a
caller? The endpoint is undocumented; this is one observation, on 2026-09-29,
from one Mac with five signed-in Claude profiles. Evidence:
[claude-usage-rate-limit-spike.json](claude-usage-rate-limit-spike.json).

## Findings

- The budget is small. On an idle account, four reads 0.25 s apart succeeded
  and the fifth, two seconds in, returned 429 `rate_limit_error` with
  `Retry-After: 300`. The window length behind that budget is not measured.
- The limit is per account (or token), not per IP. During the rejection a
  different account on the same Mac read normally.
- It is per endpoint. `/api/oauth/profile` with the same token kept returning
  200, so identity reads do not spend the usage budget.
- The penalty is fixed. Polling every 20 s during it did not extend it:
  `Retry-After` counted down on each reply and the first read after 300 s
  succeeded (303 s after the rejection).
- Successful replies carry no rate-limit headers. A caller cannot pace itself
  from them; the only signal is the 429 and its `Retry-After`.
- `claude -p /usage` on the rejected route still printed figures. Claude Code
  either reads another way or has a separate budget. Not investigated: it would
  mean imitating the provider's client.

## Earlier evidence

A three-minute CLI poll running beside the app's own refresh produced 18
rejections across four accounts in 33 minutes, and none on
Default. The app's own refresh (about one read per account every six minutes)
has produced none in the retained journal.

## Consequences

Every local reader goes through `usage.py` and shares the usage journal, so
that is where to gate calls: per account, honoring `Retry-After`, and serving a
recent reading instead of calling again. Peers polling the same account on other
Macs spend the same budget; sharing verified readings between peers is a later
step. Caching identity would not save budget.
