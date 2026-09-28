# Packaged allowance and spending details

September 27, 2026. Source base `b4d8028`.

## Proof

```sh
N2_LIMIT_DETAILS=1 python3 scripts/accept-packaged-measurements.py
N2_LIMIT_DETAILS=1 N2_LIMIT_NEGATIVE=1 python3 scripts/accept-packaged-measurements.py
```

Use the existing QA package or build with
`env -u N2_FLEET_QA N2_QA=1 N2_SIGN_IDENTITY=- zsh tray/build.sh`.
The proof requires the already authorized macOS accessibility/window capture.
It checks bundled reader source equality and retains the unchanged native binary
hash. No app is installed. Both the synthetic reader calls and app run with
network denied; a refused loopback connection verifies that boundary.

The positive command exited zero. Four rendered cases passed:

- Codex preserves general 5h/7d and model 7d buckets at 12%, 34% and 98%, a
  model-scoped provider restriction, one known window reset, unknown remaining
  resets and recovery, and credit balance zero. It never invents 100% usage.
- When only Default is restricted, next-best selects Codex Other at 34%.
- Claude shows its 20%, 30% and Opus 98% allowances and scheduling reserve,
  independently of the enabled extra-usage spending-limit note.
- Reducing the included Opus allowance to 40% leaves that spending note visible
  while next-best selects Claude Default at 40%. A spending limit on extra usage
  does not become a fabricated rejection of the included allowance.

AX assertions and window-only OCR captures check visible publication. The
supervisor independently inspected the receipts and screenshots. The
[hashed artifact record](packaged-limit-details.json) points to durable copies
under `n2-fleet-qa-artifacts/packaged-limit-details`.

The negative substituted healthy output for restricted Codex output and exited
one at `missing label: Restricted for new work`. An initial synthetic Claude
reset used the wrong timestamp type and failed before app launch. The corrected
fixture uses a string. Reproducing that preparation failure in a temporary copy
proved the added exit cleanup removes its owned app copy; the spike runner was
discarded. Post-launch cleanup still targets only the unique copied executable.

## Boundary

Codex uses the actual bundled CLI with a synthetic JSON-RPC process. Claude uses
the bundled reader's `main` and normalization with a replaced request callback;
there is no credential lookup or authenticated HTTP response. Its account stays
explicitly unverified. The unchanged UI receives these serialized results through
an allowlist adapter. This does not prove fully unmodified CLI-to-UI integration,
live provider semantics, fleet-wide current capacity or execution on these accounts.

The fixture's empty fleet feed intentionally produces a fleet-unavailable footer;
fleet UI is outside this proof. Notification delivery and live acceptance remain
open. This opt-in GUI command is separate from the four standard headless CI gates.

Formatting, lint, the full repository suite and smoke passed locally; the
combined log is `/private/tmp/n2-limit-details-gates.log`. Independent source
security review found no actionable issue in the final delta.
