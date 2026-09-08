**Acceptance not achieved. Diagnostic changes and evidence are ready; no validated playback fix is claimed.** Exact-rational clocks, tolerances and frame-retirement policy remain unchanged. Frozen files are [hash-verified unchanged](frozen.json); nothing was staged or committed.

The [per-frame attribution table](ATTRIBUTION.md) and [raw ledger](attribution-ledger.json.gz) account for **all 541 recorded late frames**, matching the retained aggregate counters. Reported ring loss was zero.

| Frames | Attribution / qualification | Evidence |
| --- | --- | --- |
| 1 | Worker starvation: timed deadline-wait overshoot | RustDesk 3 replay, frame 44: observation 49.308 ms after deadline; wait returned after interval expiry. Scheduling subcause unresolved. |
| 3 | Preceding submission crossed interval end | Mixed frame 950, RustDesk 1 replay frame 41, VP9p2 resource frame 139: preceding submission intervals 50.215 / 54.725 / 94.394 ms. Blocking versus descheduling unresolved. |
| 5 | Unresolved worker/output delay | Mixed frames 2/310, RustDesk 4 replay frame 42, appleads frame 34, VP9p2 resource frame 152: decoded and leased before deadline. |
| 2 | Unresolved subsequent delay | VP9p2 resource frames 140–141 had no individually scheduled deadline. |
| 112 | Excluded: sibling GUI overlap | Exact identities and overlap snapshots retained; only owned players were stopped. |
| 418 | Unqualified busy-host observations | Complete six-file run; no sibling GUI overlap, but a [load snapshot](ps-load-corrected.json) recorded one renderer at 558.7% CPU plus competing load. |
| Historical 5 / 14 / 8 | Unresolved aggregates | Exact frame identities and missing timing evidence cannot be recovered. |

RustDesk indices are zero-based. Every recorded frame, including excluded observations, has its own table row and retained evidence.

**Instrumentation and tests:** bounded SPSC rings carry worker observations to `WAM_PLAYBACK_METRICS_PATH`; diagnostic deadline operations add no allocation or locking. Compilation defaults OFF and runtime collection requires `WAM_NATIVE_BENCHMARK_TELEMETRY=1`. [Field semantics and limitations](TRACE_FORMAT.md) document timestamps, queue/pool scope, refresh references and null fields. Live fragment provenance remains incomplete; offline maps establish zero ISO fragments in the six MP4s and eleven clusters in the mixed Matroska.

No playback-fix revert proof is claimed. Diagnostic [emission](trace-mutation.json) and [refresh forwarding](forward-mutation.json) each have **0/1/0** fixed/removed/restored proofs. Ring, JSON and concurrent refresh-consistency checks pass. Release/OFF object checks found no trace symbols in the three checked translation units.

**Soaks:** **0/3 required all-drawn proofs achieved.** The completed busy-host run was **49,414 drawn + 418 late + 0 superseded = 49,832**, clock **1.0000**. Other attempts were blocked or interrupted by overlap. The final mixed campaign completed **0/3**, with twelve blocked preflights. Earlier full GUI-quiet mixed runs on different diagnostic revisions were **986/1/0, 985/2/0, 987/0/0**, all clock 1.0000 with zero clock-advancing underruns.

**Final replays and ctest:** all seven files selected native playback and exited successfully, drawing **19, 218, 227, 219, 216, 198, 226** frames with zero late/superseded and clock 1.0000. The required build passed. All **121 tests passed across the final full run and isolated rerun**; packaging timed out twice at its unchanged 120-second limit, then passed alone in 93.06 seconds. Both final Qt GL tests passed.

**Resource nonregression remains unmet.** [All six historical → measured rows](MEASUREMENTS.md) retain higher energy/memory observations. Five rows drew 300/300; the last drew 296 with four late frames. These diagnostic measurements precede the final snapshot-ordering correction and do not certify final release performance.

**Inherent bound:** none established. These delays do not prove any frame inherently unavoidable.

**PROPOSAL 1, not implemented:** telemetry-only segment/fragment provenance on `MediaSample` in frozen `src/media/native_media_source.hpp`, carried to frame timing, to replace live null boundary data. This is a proposed contract route, not the only possible design.

**Deferrals:** exclusive quiet measurements, complete causal attribution, smallest playback fixes with failing revert tests, three all-drawn soaks, zero-late mixed repeats and final resource nonregression. The maintainer must verify independently before committing. [Raw receipts](receipts.tar.gz), [hashes](receipt-manifest.json), [trial summaries](trial-summary.json.gz) and [verification identities](verification-identities.json) preserve failures as well as successes.
