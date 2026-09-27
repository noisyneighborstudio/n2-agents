# Packaged measurement freshness acceptance

The ad-hoc QA package passes an offline native measurement proof:

```sh
env -u N2_FLEET_QA N2_QA=1 N2_SIGN_IDENTITY=- zsh tray/build.sh
python3 scripts/accept-packaged-measurements.py
```

This opt-in command requires existing macOS accessibility and window-capture
permission. It is not run by headless CI. Repository gates still run separately.

## What the command proves

The package's unchanged `agents`, `usage.py`, `usage-store.py` and `codex-rpc.py`
match the checkout before the test adapter is installed. The bundled CLI reads
account and allowance messages from a synthetic Codex protocol peer. Healthy
responses produce two verified, distinct account hashes; missing windows and
provider errors produce `fetch-error`. A denied-network sandbox covers these
calls and the disposable native app. A connection attempt proves that denial.

The unchanged native binary then consumes those serialized CLI results through
an allowlisted fixture adapter. This is not a claim that the app's entire
unmodified CLI path ran. A retained-response fixture changes only `observedAt`
to January 1, 2020 UTC to exercise aging without changing the system clock.

Actual window assertions and captures show:

- Healthy Default and Other account details have different identifiers and
  respective 12% and 34% readings.
- Failed refreshes and missing windows show `Usage unavailable`, preserve the
  original observation time, and remove next-best selection.
- Aged observations show their original 2019/2020 local date, `stale reading`,
  and unavailable capacity without a percentage gauge.

Each unavailable case starts from a visibly healthy state. Accessibility waits
observe publication; screenshot receipts additionally require Vision-recognized
state text so an unfinished render cannot count as evidence. Screenshots capture
only the unique disposable app's window. The empty synthetic fleet feed is
outside this measurement proof and visibly reports fleet state unavailable.

## Negative controls and boundaries

`N2_MEASUREMENT_NEGATIVE=1 python3 scripts/accept-packaged-measurements.py`
substitutes healthy output for a failed refresh and must exit nonzero. It fails
waiting for the missing failure label. The copied app is removed afterward.
The rendered-image guard also rejects a healthy capture as failure evidence.
An initially blank-looking batched preview was valid when reopened individually;
it is not recorded as a product rendering failure or a negative control.

The command uses an isolated home/root, restricted PATH, synthetic security and
provider executables, a unique QA bundle identifier, and no registered URL
handler. Refresh events target the copied app explicitly. It installs nothing,
reads no real credentials, and makes no live provider calls. Source security
review found no actionable issue; independent correctness review reran the GUI
proof successfully after the state-publication race was repaired.

[Receipt and hashes](packaged-measurement-freshness.json) identify the source,
native binary, four CLI files and captured artifacts. Durable PNG, accessibility
and OCR receipts are under
`/Users/sethwebster/Development/n2-fleet-qa-artifacts/packaged-measurements`.
This closes the stated offline package proof, not current fleet headroom,
notification delivery, live provider acceptance or historical T3 attribution.
