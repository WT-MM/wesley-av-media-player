# Performance principles for agents working on WAM

Distilled from the C++ performance guide for AI agents
(https://cpp-guide-for-agents.irrotational.com/) and audited against this
codebase on 2026-08-17. WAM already embodies most of these; this document
names them so future changes preserve them deliberately rather than by
imitation, and records where we measurably fall short.

## The core stance

Every byte moved, every allocation, every branch, every lookup, and every
algorithmic pass in a hot path is intentional. Make work visible, then
benchmark it. Never rely on the compiler to erase a bad data structure, a
convenience container, string traffic, or dynamic dispatch. Language choice
does not rescue bad architecture — the guide's case study is a native path
that was slower than Python until the architecture was fixed (3381 ms →
16.5 ms by removing avoidable work, not by tuning).

## WAM's hot paths (treat every line in these as performance-sensitive)

1. **Audio render callback** (`native_audio_render_core.cpp`, driven from
   `native_audio_output.mm`): real-time thread. Audited: zero allocations,
   zero strings, atomics + 128-bit exact rational arithmetic with carried
   remainders. KEEP IT THAT WAY — nothing that can take a lock, allocate,
   or touch a string may enter this file's render path.
2. **Dispatcher step loop** (`native_media_dispatcher.cpp`): per-sample
   cadence. Bounded fixed-storage lanes (24-event FIFO, byte-capped);
   strings only on terminal error paths (cold — acceptable).
3. **Sample factories** (`avfoundation_media_source.mm`,
   `matroska_media_source.mm`): per-AU/per-frame cadence (~77/s at
   1080p30+AAC). Demuxer cursors are payload-free by design — offsets only —
   so the factory is the only place payload bytes are moved. The Matroska
   factory creates the CMBlockBuffer first and has `copyRanges` `pread`
   straight into its memory: one copy, no scratch vector. AVFoundation has
   one framework-internal copy and no WAM-side copy.

   This paragraph has now been wrong in BOTH directions, so the history is
   recorded once and the numbers replace the reasoning. It first claimed
   the factory "copies payload bytes exactly once" while it in fact copied
   twice (`readAt` into a member `scratch` vector, then
   `CMBlockBufferReplaceDataBytes` into the block). The 2026-08-17 audit
   deleted the second copy and asserted, unmeasured, that this was a ~30%
   staging win. MEASURED 2026-08-17 live on the layer route (h264-high.mkv,
   1080p30 + AAC, mean 32,628 B per video sample), all three staging paths
   compiled into one binary and selected at runtime, run back-to-back:

   | run position | staging path | CM alloc | payload copy | total |
   | --- | --- | --- | --- | --- |
   | 1 (cold cache) | direct write | 4.7 µs | 392 µs | 397 µs |
   | 2 | scratch + `ReplaceDataBytes` | 9.7 µs | 59 µs | 69 µs |
   | 3 | direct write + page pre-touch | 6.7 µs | 17 µs | 24 µs |
   | 1 (cold cache) | direct write + page pre-touch | 4.3 µs | 51 µs | 56 µs |
   | 2 | scratch + `ReplaceDataBytes` | 4.5 µs | 12.9 µs | 17.5 µs |
   | 3 | direct write | 2.6 µs | 15.6 µs | 18.4 µs |

   READ THE POSITION COLUMN, NOT THE PATH COLUMN. The first three rows ran
   in one order and the last three in the reverse order, and in BOTH orders
   the slowest arm is whichever one ran first. The variable that moves this
   number by 20x is whether the clip's pages are already resident, which no
   staging path controls; once the file is warm all three arms land within
   12.9–18.4 µs of each other. The "30% duplicate-memcpy win" was never
   measured and is not there to find — at 30 fps the entire spread between
   the warm arms is under 0.2 ms/s. VERDICT: the current one-copy path
   stays, not because it is faster but because it is simpler and provably
   not slower. Anyone re-measuring this MUST alternate the run order or
   they will rediscover the page cache and name it something else.

   Remaining deviation: one `std::make_shared` storage-token allocation per
   sample, plus CM's own CMSampleBuffer/CMBlockBuffer allocations
   (API-imposed). The token is a FIXED ~48–64 B control block, not
   payload-scaled, and is one of roughly six allocations per frame.
   Measuring it in isolation costs ~71 ns against ~21 ns for a pooled
   alternative: ~4 µs/s at the 77 samples/s production cadence, against a
   pool that would have to keep every token alive until CoreMedia
   asynchronously releases the block that borrows it. VERDICT:
   measured-acceptable, and the pool is explicitly NOT worth its lifetime
   hazard.
4. **Demuxer cursors** (`matroska_demuxer.cpp`): capacity-one, payload-free,
   fixed 24-byte/16-byte index entries with `static_assert` layout
   contracts, hard caps (65,536 clusters/cues ≈ 2.5 MiB worst case).
   This is the guide's hot/cold split executed exactly: hot records carry
   offsets and ticks; names/messages live in cold outcome structs.
5. **Presentation scheduling** (`native_video_consumer.mm`,
   `native_media_clock.cpp`): exact rationals end to end; never compare
   through doubles in admission logic (the 0.6x clock bug came from
   demanding bit-exact doubles — the fix was a bounded invariant, not
   looser floats).

## Rules derived from the guide, binding for new WAM work

- **Hot/cold separation**: hot records are POD or near-POD (memcpy-safe);
  provenance, names, and messages live in cold side structures reached by
  index/ID, never carried in per-sample records.
- **Workspaces over per-item allocation**: no allocation in loops that run
  per-sample, per-frame, per-callback, per-slab, or per-cluster. Reuse a
  member scratch buffer; reset counts, never free capacity mid-stream.
- **No strings in hot paths**: identity is numeric (generations, serials,
  source keys, ticks). Strings appear only in cold error/diagnostic paths
  and UI formatting after the work completes.
- **Bounded everything**: every queue, lane, ring, and index has a hard cap
  chosen from arithmetic (bytes, not vibes) and asserted. A new unbounded
  buffer is a design smell — the deadlock and stall history of this
  codebase is a catalog of what unbounded-or-zero-headroom does.
- **Exact rational time**: media time is `{value, timescale}` integers
  through every comparison; convert to double only at UI/diagnostic edges.
  Quantization tolerance, where physically required (CoreAudio host
  ticks), is an explicit bounded invariant with a comment deriving the
  bound.
- **Algorithm before micro-optimization**: when a phase is hot, first ask
  whether it can be removed, batched, or reordered (the pipeline
  decoupling and read-ahead-lane fixes were algorithmic-shape changes;
  no amount of loop tuning would have fixed them).
- **Dispatch at the top, not in the loop**: backend/codec selection happens
  once per open (`buildGraph`), never per sample.

## Measurement discipline (what "done" means here)

- Every performance-sensitive change ships with: correctness tests, the
  measured target before/after, and — for pipeline changes — a live-app
  verification (telemetry chain + rate/underrun counters), because this
  project has repeatedly proven fixture-green ≠ world-correct (the
  demuxer passed a 2,832-line mutation-tested suite and still rejected
  every real FFmpeg mux on seven envelope details).
- Record rejected attempts with the reasons; attempted-and-reverted is
  architecture data (see SESSION_HANDOFF's attempted-and-reverted logs —
  three separate convincing-but-artifact regression tables were caught
  only because harness liveness was itself verified).
- Do not trust one benchmark size. GAP CLOSED 2026-08-17 for the demuxer:
  `benchmarks/matroska_demuxer_bench.cpp` (target
  `wam_matroska_demuxer_bench`, `EXCLUDE_FROM_ALL`, ctest label `benchmark`)
  sweeps prepare, planGeneration, cursor readNext, and copyRanges across
  small/medium/large/transition regimes on synthetic in-memory documents,
  and prices the CoreMedia staging token. Baselines and the regressions it
  found are in the table below; re-run it before and after any change to
  those loops. STILL OPEN: the sample factories themselves
  (`matroska_media_source.mm`, `avfoundation_media_source.mm`) have no
  regime benchmark, because they are Objective-C++ against CoreMedia with
  no testing seam that admits a synthetic sample. Adding that seam is the
  next benchmark increment, and the cheapest path is already scoped: a
  `matroska_media_source_testing` namespace behind a
  `WAM_MATROSKA_MEDIA_SOURCE_TESTING` compile definition exposing
  `buildCompressedSampleBuffer` (already pure and injectable), plus an open
  overload taking a `SeekableByteReader` — the demuxer already publishes
  that injectable `prepareMatroska`; the media source simply never calls
  it.
- GAP CLOSED 2026-08-17: debug-build performance is now measured. Debug/
  Release ratios on the demuxer are 1.0x (copyRanges >= 64 KiB, memcpy
  bound), 5.0-5.5x (planGeneration, small copyRanges), and 9.8x (prepare,
  whose EBML `Visitor` is a real virtual call per element when nothing
  inlines). Nothing is pathological. NOTE FOR FUTURE MEASURERS: the
  demuxer *test suite* runs 20.1x slower in Debug (0.16 s -> 3.22 s), which
  looks pathological and is not the product -- since every product phase
  measures <= 9.8x, the excess is necessarily the fixture builders, which
  append EBML documents one `push_back` at a time through a libc++ that
  does not inline in Debug. Time the benchmark, not the suite.
- A live-app verdict needs a window that is actually frontmost, and getting
  one is harder than it looks from a headless agent session. Recorded
  2026-08-17 so the next agent does not spend the time again: launching the
  binary directly leaves the window buried behind whatever the user has open,
  and `System Events`-based activation is silently ignored without
  Accessibility permission — it returns success and changes nothing. What
  works is `osascript -e 'tell application "WAM" to activate'`, which goes
  through LaunchServices. ALWAYS confirm afterwards by reading back
  `name of first process whose frontmost is true`; do not assume the
  activation took. And when a native run does fall back, run the same clip
  against a control binary with your changes reverted before concluding
  anything — on this machine a fully reverted build fell back identically,
  which is the only reason the fallback was correctly attributed to the
  environment rather than to the diff.
- GAP CLOSED 2026-08-17: a native failure now names its own class. The
  user-facing text comes from `protocol::FailureReason`, a deliberately tiny
  vocabulary — every terminal dispatcher failure collapses onto `Protocol`
  (open-status `Failed`) or `Decode` (a `Failed` step) — so a field report
  said only "Native playback rejected an internal command" and named neither
  the seam that refused nor why. `native_media_session.mm`'s
  `logNativeFailure()` now writes exactly one always-on stderr line per
  terminal failure, in the form
  `WAM: native failure stage=<open|open/graph|open/arm|open/transfer|open/descriptor|open/context|start|start/audio|steady> reason=<FailureReason> class=<NativeMediaDispatcherFailure> error="<refusing seam's own text>"`.
  The class name comes from `nativeMediaDispatcherFailureName()` and the text
  from `NativeMediaDispatcher::failureMessage()`, which retains whatever the
  source, validator or consumer wrote into the `std::string* error` out-params
  that the dispatcher previously passed `nullptr` for. It is deliberately not
  env-gated (one line per terminal failure, a handful per session lifetime)
  and deliberately not part of `stats()`, so the per-step POD copy stays
  allocation free. This is what made the 2026-08-17 Matroska `FileChanged`
  defect a one-reproduction diagnosis instead of a bisect: the first stormed
  run printed
  `stage=steady reason=Decode class=SourceRead error="Matroska file changed (FileChanged)"`,
  which named the file, the predicate and the mechanism at once. Grep for
  `WAM: native failure` in any plain stderr capture.
- Suspect the instrument before the subject: verify the window is actually
  compositing (occlusion produces clock 1.0000 + frozen draws + late-drops
  at exactly the frame rate — a perfect counterfeit of starvation), verify
  the harness's own overhead, and prefer counters the app publishes over
  screen-scraping.

## Demuxer regime baselines (2026-08-17, Release, M3 Max)

Produced by `wam_matroska_demuxer_bench`. These are the numbers a change to
`matroska_demuxer.cpp` must not regress. Synthetic in-memory documents unless
a row says "real file".

MEASURE ON A QUIET MACHINE. These were taken with nothing else building; the
same binary measured 30-50% slower with a four-way `cmake --build` running
alongside, which is larger than most of the deltas below. Compare like with
like, back to back, or you will "discover" regressions that are your own
build.

| phase | regime | ns/op |
| --- | --- | --- |
| prepare | 64 clusters | 44,816 |
| prepare | 1k clusters | 637,977 |
| prepare | 8k clusters | 5,179,567 |
| prepare | 65,536 clusters | 43,081,000 |
| planGeneration | 64 / 1k / 8k / 65,536 cues, any target | 1,214 – 1,512 |
| cursor readNext (video) | 64 clusters x 1 block | 1,145 |
| cursor readNext (video) | 1k clusters x 1 block | 1,141 |
| cursor readNext (video) | 64 clusters x 25 blocks | 703 |
| cursor readNext (video) | 8k clusters x 1 block | 1,148 |
| cursor readNext (AAC) | 64 clusters x 25 blocks | 2,248 |
| copyRanges (memory) | 1 KiB / 64 KiB / 1 MiB | 23 / 694 / 13,603 |
| copyRanges (real file) | 1 KiB / 64 KiB / 1 MiB | 930 / 2,316 / 34,804 |

DO NOT USE THE `copyRanges (real file)` ROW TO PREDICT PRODUCTION. Corrected
2026-08-17 against live measurement: that row's file is small and already
resident, so it prices a warm page-cache hit. In the player, a 32 KiB video
access unit out of a 71 MB clip measured 392 µs on the first pass and 13–18 µs
once warm — 170x the benchmark figure at the cold end. The benchmark measures
the copy loop; production is dominated by page residency, which the benchmark
deliberately holds constant. Both numbers are honest and they answer different
questions.
| staging token (make_shared) | 384 B / 8 KiB / 256 KiB | 47 / 168 / 1,653 |
| staging token (pooled) | 8 KiB | 14 |

`prepare` is flat at ~1.04e6 clusters/s across three orders of magnitude —
there is no transition point and no superlinear term, and the entire fixed
cost of an open (including `CollectedDocument`'s two worst-case `reserve`
calls, 3.7 MiB + 7.3 MiB) is bounded by 2.6 µs at the 64-cluster regime.
Those reserves are lazy mappings, never touched pages; measured-acceptable.

Three regressions the sweep found and fixed, all in `matroska_demuxer.cpp`:

1. **planGeneration scanned the Cue index linearly** with a gcd reduction and
   an exact rational compare per Cue passed, so seek cost was set by *where
   in the file the user seeks*: 1.8 µs landing on the first Cue, 545 µs on
   the last Cue of a 65,536-Cue index — 307x, on every seek. Now a binary
   search over the (already strictly-increasing) Cue ticks: flat 1.8–2.2 µs
   everywhere, 270x faster at the far end. This is the guide's "algorithm
   before micro-optimization" rule catching a real one.
2. **`CapturedBlockVisitor` was constructed per parsed Block.** It carries
   `std::array<FrameRange, 256>` = 4 KiB that a fresh instance zero-fills, to
   describe a Block holding one frame (video) or four (laced AAC). Worst case
   was the seek path, where a `planGeneration` audio scan walks up to 8,192
   Clusters. Now a reused workspace with a `reset()` that clears one bool.
   readNext improved 3–15% depending on regime.
3. **`copyRanges` checked file identity twice per 64 KiB chunk**, so a
   local-file copy cost 3 `fstat` + 1 `pread` per chunk — 49 syscalls to move
   1 MiB, and 1,801 ns to move 1 KiB (0.53 GiB/s against 27 GiB/s from
   memory). Identity now brackets the whole copy, which is the same
   guarantee — a mid-copy substitution is still caught before the function
   returns true; per-chunk checking only abandoned a doomed copy sooner.
   1 KiB −24%, 1 MiB −20% (14.8 → 18.5 GiB/s).

Also fixed at open time: the Cue-gap check converted both ends of every gap
(two gcd reductions per Cue where one suffices, carried forward now) and
cross-multiplied through `long double`, which is plain binary64 on arm64 — a
timescale near the int32 ceiling put both sides past a 53-bit mantissa, so
the bound was decided by rounding. Now exact `__int128` against an integer
nanosecond bound, with the magnitude argument in a comment.

## The A/V merge key is decode order, not presentation order (2026-08-17)

Recorded here because it presented as a performance defect, was chased as one,
and was not one.

SYMPTOM: on the layer route, `h264-high.mkv` drew 18.1 fps with 543 late
frames and `hevc-main.mkv` drew 8.6 fps with 930 late frames, while
`vp9-aac.mkv`, `av1-aac.mkv` and every MP4 were clean at 30 fps.
`drawn == submitted` and `superseded == 0`: the scheduler was retiring frames
before they were ever submitted.

ROOT CAUSE: `matroska_media_source.mm` merges its staged video and audio heads
by comparing one timestamp from each, and used the video sample's
PRESENTATION time as that key. Matroska carries no DTS and its cursor emits in
storage order, which is DECODE order. For a stream with B-frames those two
orders are different orders — storage 0, 3, 1, 2 presents as 0, 1, 2, 3 — so
keying the merge on presentation time made the merge hold each B-frame until
the audio lane had advanced past the following P-frame's timestamp. The B-frames
were then handed downstream after the audio clock had already passed their own
presentation time, and `scheduleHeld()` correctly discarded them as late:
`pts + duration <= clock`. `avfoundation_media_source.mm` never had the defect
because MP4 carries a DTS and it keys on `dts.valid() ? dts : pts` — the DTS
*is* the decode-order key. The fix gives the Matroska video lane the same lead
by construction (`kVideoMergeLeadNanoseconds`, bounded by reorder depth x frame
duration on one side and by the dispatcher's video read-ahead caps on the
other).

| clip | merge key | fps | drawn | late |
| --- | --- | --- | --- | --- |
| h264-high.mkv | presentation time | 18.13 | 834 | 543 |
| h264-high.mkv | decode-order lead | 30.01 | 1385 | 0 |
| hevc-main.mkv | presentation time | 8.62 | 375 | 930 |
| hevc-main.mkv | decode-order lead | 30.02 | 1083 | 0 |

WHAT THIS COST, AND THE LESSON THAT IS ACTUALLY WORTH THE WORDS: the symptom
correlated beautifully with bitrate. Late frames rose monotonically with bytes
per compressed frame across the whole corpus (vp9 11.3 KB clean, av1 25.8 KB
clean, h264 32.6 KB late, hevc 41.4 KB worst), which is exactly the shape a
per-sample staging cost makes, and the staging path had just been rewritten.
It was a coincidence of which clips happened to carry B-frames. Three
measurements killed it:

- **a dose-response null** — three staging paths in one binary, selected at
  runtime so no rebuild separated the arms: staging latency moved 17x
  (397 µs → 69 µs → 24 µs per sample) and the late-frame rate did not move at
  all (12.10 → 12.28 → 12.26 late/s);
- **an inversion** — `hevc-main.mkv` had the CHEAPEST staging of the reordered
  clips (209 µs) and the WORST lateness (21.5 late/s), while clean
  `av1-aac.mkv` had MORE expensive staging (263 µs) and 0.05 late/s;
- **a discriminator** — `h264-silent.mkv` has B-frames and is clean at 0 late,
  because it has no audio track and therefore no merge to lose.

Correlation with the obvious scalar is not a mechanism, and "the thing that
changed most recently" is not a diagnosis. Vary the suspect at runtime and
watch whether the symptom follows.

## UNVERIFIED LIVE — read before trusting the 2026-08-17 slice

Everything in that slice is green on the required ctest regex, the five known
GL failures are unchanged, and the demuxer work is measured by the benchmark
above. What was NOT established at the time was live playback health, because
no run in that session could obtain a compositing window (see the activation
note above): a control build with the changes reverted fell back identically,
so the diff was exonerated, but "does not cause the fallback" is not "verified
playing".

PARTIALLY CLOSED 2026-08-17 (later session, layer route). Live compositing runs
were obtained by launching detached with `open -n -g --env ... --stderr ...`
against `build/WAM.app` and letting `WAM_TEST_QUIT_AFTER_MS` end the run — a
SIGTERM produces an empty telemetry stream, so a killed run is an unusable run.
Under that harness the whole corpus plays: h264-high.mkv, hevc-main.mkv,
vp9-aac.mkv, av1-aac.mkv, h264-silent.mkv and h264-high.mp4 all reach 30 fps
with 0 late frames and 0 audio underruns once the merge-key defect above is
fixed. Still NOT verified live: the reorder cap lowered from 8 to 4, because no
clip in the corpus exceeds `has_b_frames=2` and none of these runs exercised
the refusal path.

The one change that most needs a live run is the reorder cap lowered from 8 to
4 in `native_video_consumer.mm`, because it is the only change that can refuse
content that previously played. Bounding evidence, short of a live run: every
clip in `.cache/benchmarks/media/adhoc-native-1080p` (h264-high, hevc-main,
h264-44k, h264-silent, both MKVs, hevc-main10) reports `has_b_frames=2`, half
the new cap. A stream above 4 now falls back loudly rather than overrunning
the surface budget, which is the intended trade — but confirm it on a real
window before treating the slice as done.

## Consciously accepted (2026-08-17 full-pipeline audit)

Every item below was measured or arithmetically bounded, found real, and
deliberately left alone. They are recorded so the next agent does not
re-discover them and "fix" them at a cost. Do not change these without a
measurement that contradicts the number given.

**Real-time audio render callback** — audited transitively (ring, clock,
conversions, host-tick reader) and found fully clean: no allocation, no lock,
no string, no unbounded structure on the callback path. Six observations, each
under 0.05% of the callback budget: a unity-gain pass that could be skipped; a
second 4 KiB gain pass (fusing it into the ring is *worse* by the abstraction
test — it would mix two performance regimes in one structure); by-value 112 B
input records (inlined, and the immutability is what makes the contract
provable); a hoistable slack multiply; and six `__udivti3` calls per callback,
which are simply the price of exact 128-bit rational time.

**Dispatcher** — the lane slot variant is 320 B because of a cold
`MediaFormatChanged` alternative that `routePending` unconditionally rejects:
~10 KiB (65%) of dead lane storage, 120 cache lines against 42 on a walk that
only happens at cold lifecycle transitions. This is a genuine hot/cold
violation with a contained fix (a lane-only variant), left unchased because
its measured cost today is zero. `std::visit` compiles to a seven-entry
function-pointer table just to read `.generation` (~2.3k cycles/s); a
`switch (index())` removes it for free if that code is ever touched anyway.
The per-sample defensive `clampMediaSourceLimits` at a shared public boundary
is idempotent and stays. MAINTENANCE NOTE (zero performance content):
`routePending` triplicates the same 24-line lane-queue block for Sample,
Discontinuity and EndOfStream — refactor-with-care territory, because that is
exactly the ordering logic the lanes exist to protect.

**Decoder and GL** — `decoder.stats()` takes two mutexes twice per access unit
plus a third for `takeLastError` (~9 µs/s); coherence across
inFlight/retained/accepts structurally requires the lock, and the accepted path
allocates nothing. `wideGcd` costs ~0.015% of a core. `RawGlState` makes 44
calls that `QSGRenderNode::changedStates()` says are redundant — KEPT as
defense-in-depth (and note that 19 of them are *not* redundant: StateFlags has
no flag for program, VAO, texture-unit or sampler bindings). The remaining
doubles in the clock and presentation scheduler were audited and are clean;
the only lossy comparison found is fixed (see the `setDueHint` note in code).

**Sample factories** — the storage token is measured-acceptable for the
reasons corrected above. The indirect call in the AVFoundation staging path,
the linear `findMediaTrack` scans (linear IS correct at n <= 64), and the
defensive re-clamp at the shared public boundary all stay.

**Demuxer** — `CollectedDocument` reserves worst-case cluster and cue vectors
(3.7 MiB + 7.3 MiB) on every open regardless of file size. Measured: the
entire fixed cost of `prepare` at the 64-cluster regime is bounded by 2.6 µs,
because those reserves are lazy mappings whose pages are never touched.
`MatroskaCursorReadResult` is a ~4.2 KiB variant because its sample
alternative carries the 256-entry worst-case lace array, so every `readNext`
moves 4.2 KiB to deliver ~48 useful bytes: 323 KiB/s at the production sample
cadence, which is noise. The lever, if the cadence ever rises by orders of
magnitude, is shrinking the array in the *record* (the parser's cap must
stay). The AAC branch of `readNext` computes a duration through
`timeFromNanosecondsUnsigned` whose value is discarded — only its
nullopt-ness is used as a guard — and then computes the real duration with a
second, independent gcd. Genuinely redundant, measured below this benchmark's
noise floor (< 1.5% of a 3.3 µs sample), left alone.

**Attempted and reverted** — dropping the `{}` member initialiser on the two
256-entry `FrameRange` arrays (`MatroskaCompressedSample::frames` and
`CapturedBlockVisitor::frames`) to skip 4 KiB of zero-fill per sample measured
NEUTRAL: readNext moved 1716 -> 1732 / 1072 -> 1090 ns, inside noise. Reverted
rather than kept, because it put indeterminate values in a public record for
no measured gain. The stores were recovered a better way instead — the visitor
is now a per-cursor member, so the fill happens once per generation rather
than once per sample, which measured a real 2-16% depending on regime.

## Abstraction review test (from the guide, adopted verbatim)

A good abstraction removes real complexity, keeps ownership visible,
preserves or improves performance, has a narrow contract, ships with
tests, and makes the next implementation easier. A bad one hides
allocation or copies, generalizes across different performance needs,
mixes hot and cold data, adds per-element dispatch, slows debug builds, or
exists only to look idiomatic. WAM's `SessionAudioControl` function-table
swap (silent timebase) and `MediaSourcePreparedContext` (backend-neutral
admission) are house examples of the good kind: narrow, visible, measured.
