# Blocking settings reads

CI 36271390482 failed the old 750 ms assertion after five simulated reads took
758.9 ms. The paired PR run 36271392571 passed the same head. Elapsed time
alone does not establish serialization.

A disposable probe called the real loader with a DispatchGroup barrier requiring
all five reads to enter before any returned. The two-second timeout only reported
failure. The default executor passed all five reads. With
`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, four reads timed out before the fifth
entered. No subprocess, live profile or provider was used. The adjacent fixture
records the output; exploratory source and binary were discarded.

Blocking `Task.detached` work can consume the cooperative executor's available
workers. This experiment demonstrates that failure mode, not the historical CI
runner's exact scheduling. Use a dispatch queue for blocking CLI calls and resume
the async caller through a checked continuation. Preserve indexed result order.

The regression must use entry/release receipts, assert reads are off the main
thread, and pass with the constrained executor. A discarded serial loader must
fail it. A timeout is only a stuck-test guard; do not infer concurrency from total
elapsed time or relax the old performance threshold.

The new event proof failed on the original loader under the constrained executor
with `reads did not all start before release`. It also failed on a discarded
serial dispatch-loader variant at the same assertion. The repaired loader passes
under that constraint. Independent correctness review found no issues. Formatting, lint, full local tests and smoke passed. Exact-head CI remains
required before calling the slice complete.
