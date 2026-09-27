# Automatic usage ranking

Measured eligible candidates precede unmeasured candidates. Loop strength,
busyness and vendor preferences apply within that class. Explicit exclusions,
sign-in failures, cooldowns and the local 95% reserve still apply.

Missing, malformed or failed measurements from a metered provider are ineligible.
A failed collector command cannot turn that provider into a no-usage-API slot.
Genuine no-API providers remain fallback when no measured eligible candidate is
available. CLI and tray label this selection unmeasured; no percentage is invented.
Explicit manual selection is unchanged.

Proof: `python3 scripts/test-usage-ranking.py` runs the real CLI with disposable
profiles and a local synthetic quota server. Loop and native-model tests cover
competing preferences, failed collection and the no-measured-candidate fallback.
