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
   1080p30+AAC). The Matroska factory reuses a member `scratch` vector
   (workspace pattern: grows to high-water, then allocation-free) and
   copies payload bytes exactly once (demuxer cursors are payload-free by
   design — offsets only). Known deviation: one `std::make_shared`
   storage-token allocation per sample at the CoreMedia boundary, plus
   CM's own CMSampleBuffer/CMBlockBuffer allocations (API-imposed).
   Measured-acceptable today; if a profile ever shows it, the fix is a
   fixed pool of storage tokens, not a redesign.
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
- Do not trust one benchmark size. KNOWN GAP: WAM's benchmarks are
  end-to-end (fps, clock rate, underruns, open latency); the demuxer and
  sample factories have no small/medium/large regime microbenchmarks or
  transition-point sweeps. If you touch their hot loops, add them.
- KNOWN GAP: debug-build performance has never been measured. Slow debug
  builds hide architecture problems; if a debug-path regression appears,
  ask why rather than dismissing it.
- Suspect the instrument before the subject: verify the window is actually
  compositing (occlusion produces clock 1.0000 + frozen draws + late-drops
  at exactly the frame rate — a perfect counterfeit of starvation), verify
  the harness's own overhead, and prefer counters the app publishes over
  screen-scraping.

## Abstraction review test (from the guide, adopted verbatim)

A good abstraction removes real complexity, keeps ownership visible,
preserves or improves performance, has a narrow contract, ships with
tests, and makes the next implementation easier. A bad one hides
allocation or copies, generalizes across different performance needs,
mixes hot and cold data, adds per-element dispatch, slows debug builds, or
exists only to look idiomatic. WAM's `SessionAudioControl` function-table
swap (silent timebase) and `MediaSourcePreparedContext` (backend-neutral
admission) are house examples of the good kind: narrow, visible, measured.
