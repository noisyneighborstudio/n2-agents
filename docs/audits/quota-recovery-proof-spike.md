# Quota-recovery proof spike

CI 36265842431 failed the exact eight-quota count. On the documentation-only
spike commit a14b3b2, push CI 36267617945 failed the capacity retry-event assertion
and PR CI 36267620261 failed the count. No CI scenario state was retained.

## Recorded experiments

The adjacent JSON contains observations from the existing loop executable and
quota fixture in disposable roots. The baseline reached DONE after eight quota
rejections and emitted the expected waiting events.

A controlled slow-journal experiment added 24 million PBKDF2 iterations before
CLI usage journal commands, without changing provider responses or the engine.
Measured overhead was 6.10–6.24 seconds per call. It still reached DONE after
eight rejections, with both per-profile counters at zero, but emitted no capacity
waiting event. This reproduces that assertion failure while preserving successful
recovery. The diagnostic timeout guard was extended for the injected workload.
Journal latency came from CPU work. The driver reused the existing polling
helper; the repair replaces that helper with event-based waiting. No live
credentials, provider calls, or CI reruns were used.

An initial wrapper experiment was bypassed by the engine's canonical CLI path
and did not inject journal latency. It provides no evidence for the hypothesis.
All exploratory code was discarded; the raw state captures remain in the local
QA artifact directory. Only the compact nonsecret evidence is checked in here.

## Explanation and limits

Engine.settle sets a two-second cooldown before synchronously recording usage.
With journal work exceeding that interval, the cooldown can expire before the
next tick. waitForCapacity correctly avoids WAITING if a fresh selection is
already usable. Requiring a waiting event in this short-reset scenario is thus
not a stable proof of automatic recovery.

The exact-count CI failure was not reproduced. Source inspection shows that
slot selection balances busy slots but does not guarantee four worker attempts
on each profile. The shell fixture also updates per-profile counters without a
lock. These are risks to the assertion, not a demonstrated cause of that CI run.

## Repair brief

Keep the repeated-recovery proof with eight failures, but make its synthetic
failure budget global and process-locked so the number does not depend on slot
allocation or concurrent counter updates. Assert budget exhaustion, eight quota
outcomes, DONE, and no automatic pause. Separately drive both profiles into a
future worker-only limit with enough remaining time to observe WAITING, then
observe automatic retry and successful work after its stated reset. A fixture
that only reaches WAITING and is paused for cleanup would not prove recovery.
Wait for persisted state events, not sleeps; a timeout only fails a stuck test.
Retain compact state and budget diagnostics on either failure.
This changes test determinism, not scheduling or quota semantics.

## Implemented proof

The fixture now locks shared and legacy counters with `flock`. The recovery
case consumes a global budget of eight errors and requires eight quota outcomes,
zero remaining errors, DONE, and no automatic pause. A separate two-error case
uses a 30-second reset, observes a persisted WAITING state with a future deadline,
and requires automatic retry and DONE without a resume command. The test waits
for atomic state-file replacement events using kqueue; a timeout fails the test.
Assertion failures retain state and remaining-budget diagnostics in CI output.

The deliberate negative control changes only the discarded controller's WAITING
transition to PAUSED. The new observer must reject that terminal mismatch.
The recorded latency experiment remains evidence for separating the two proofs;
no production quota or scheduler behavior is changed by this repair.
