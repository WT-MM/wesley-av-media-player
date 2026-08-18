# Phase B working notes

Working notes for the CALayer presentation pivot integration. Date: 2026-08-17.
Nothing here is committed; the coordinator commits.

---

## Environment facts that shape every measurement below

- **The display was asleep at session start.** The first gate run produced
  "WAM: Native playback did not start in time; using compatibility playback"
  and Qt stopped issuing render passes after ~30 frames. A full-screen
  `screencapture` was uniformly black (112 KB for a 3024x1964 screen).
  `caffeinate -u` woke it; the very next run reached native steady state.
  **This is the same symptom AGENT_PERFORMANCE_PRINCIPLES.md records as "no run
  in that session could obtain a compositing window" — the cause is display
  sleep, not the diff.** Hold a `caffeinate -d -u` for the duration of any live
  run.
- **Accessibility permission is NOT granted to the agent shell.**
  `System Events -> count of windows` returns 0 for Terminal, Finder, Chrome,
  Cursor, Slack and WAM alike. Window parking (`player_resource_trial.py`'s
  `park_window`) cannot work in this session, so all runs use the app's default
  1180x720 window rather than the 640x360 parked geometry of the Phase A
  baseline table. **Absolute numbers here are therefore not comparable with that
  table; only same-session A/B deltas are.**
- **Another application repeatedly steals frontmost.** Confirmed directly: an
  activation gate that re-fronted WAM and re-checked every 4 s recorded
  `frontmost` flipping back to "Google Chrome" on all six attempts. This has a
  large consequence, below.
- Machine is **not quiet**: load ~8.5-10.7, `suggestd` 75%, `apfsd` 64%, `bird`
  53%. Data volume 100% full (9.0 GiB free of 1.8 TiB). CPU figures are upper
  bounds.
- `git` is effectively unusable in this worktree: `.git/objects` are being
  re-downloaded by iCloud, and `git diff --stat` on one file timed out at 120 s.
  Verification of edits was done by reading files, not by diffing.
- The worktree carries pre-existing uncommitted work on branch
  `codex/lazy-mpv-init` (matroska demuxer, video codec configuration,
  `native_video_codec_capability.*`). Not mine; left untouched.

---

## STEP 0 — THE GATE: ANSWERED, and it passes

Question (DESIGN.md section 2, section 9 item 1, the stated go/no-go): with
chrome hidden, does the 30 Hz `positionChanged()` churn keep Qt's scene graph
dirty, so the process keeps issuing render passes even if the video item stops
updating?

Method: `QSG_RENDER_TIMING=1` on the shipping build, counting
`qt.scenegraph.time.renderloop` lines in captured stderr in 5 s buckets over a
70 s run of h264-high.mp4. Cursor parked far from the window, window left
unfocused so the chrome is hidden throughout. A/B is a one-line temporary
suppression of `PlayerController::requestVideoUpdate()` — the single seam
through which *both* the native and libmpv routes dirty the video item.

| run | video-item update() | render passes over the 60 s tail | rate |
|---|---|---|---|
| gate2 | shipping (per decoded frame) | 746 -> 2690 = **1944** | **29.9 / s** |
| gate3 | suppressed | 104 -> 104 = **0** | **0.00 / s** |

In gate3 the counter froze at 104 within 10 s of launch and did not advance once
over the following 60 s, while the playback-metrics stream kept emitting
(11 -> 142 rows at 500 ms cadence) — the process was alive and the transport was
running the whole time.

**Answer: Qt DOES go idle. Zero render passes in 60 s of playing with chrome
hidden, once the video item stops dirtying the scene.** The 30 Hz position churn
does not keep the scene graph dirty, and no fix is needed. The reason is
structural and already in the tree: `qml/FloatingControls.qml:164` binds
`mediaPosition: root.visible ? root.player.position : 0`, so the scrubber's
`controller.position` binding is severed while the chrome is invisible.
DESIGN.md section 2 was right that the churn exists and wrong that it reaches a
live binding.

**Consequence: DESIGN.md file-change item #6 (`player_controller.cpp:1449-1464`,
"stop the 30 Hz positionChanged from dirtying the scene while chrome is hidden",
marked "small, mandatory") is NOT needed and was not done.** Condition 1 of
Phase A's recommendation is satisfied.

The probe was reverted after measuring (verified: zero occurrences of
`WAM_GATE_SUPPRESS_VIDEO_UPDATE` remain in the tree).

---

## Design decisions, and where they deviate from DESIGN.md

### 1. No render synchronizer, no control timebase — DEVIATION, deliberate

DESIGN.md's headline recommendation says ASBDL "timed by an
`AVSampleBufferRenderSynchronizer`". The presenter does **not** attach one, and
attaches no `controlTimebase` either. Every enqueued sample carries
`kCMSampleAttachmentKey_DisplayImmediately`.

Reason: WAM's clock is audio-authoritative and `NativeVideoConsumer` already
releases each frame at its exact due host time. A synchronizer would install a
*second* clock in a system whose entire correctness argument rests on there
being one. Manual enqueue ("we enqueue when due, the layer shows it now") keeps
the engine's clock authority intact, which is what the Phase B brief asks for.

This is safe specifically *because* neither a timebase nor a synchronizer is
present: `AVSampleBufferDisplayLayer.h:137` only warns against combining
`DisplayImmediately` **with** one of those. And `DisplayImmediately` is not
optional here — Phase A measured the trap directly (DESIGN.md section 3.1b: a
run where the synchronizer never started reported `totalNumberOfFrames = 9` for
9 enqueues with at most one frame ever on screen). With a nil timebase and no
`DisplayImmediately`, frames queue and never display.

Exact PTS and duration are still restated bit-for-bit into the CMSampleBuffer
from `FrameTiming`, so the sample the renderer holds and the proof's timing echo
can never disagree.

### 2. The drop audit is folded into the proof stream, not reported beside it

The brief requires that a dropped frame must not produce a drawn proof. Two SDK
facts constrain how:

- `numberOfDroppedFrames` lives on `AVVideoPerformanceMetrics`, reachable **only**
  through the async `loadVideoPerformanceMetricsWithCompletionHandler:` on
  `AVSampleBufferVideoRenderer`, which may yield nil, and every property is
  `[SPI]`-tagged. There is no synchronous read. (Verified in the SDK 26.5
  headers this session.)
- The proof must be published inside `submit()` to preserve capacity-one flow —
  withholding a frame's terminal event until the *next* frame is enqueued would
  deadlock the boundary, because the consumer cannot submit N+1 until N's event
  is consumed.

So the audit is a **debt**: a metrics load every 30 enqueues (~1 s at 30 fps)
computes the drop delta and accrues it; each subsequent admitted frame settles
one unit by terminating **FrameSuperseded instead of FrameDrawn**. Published
FrameDrawn counts therefore never exceed frames actually displayed, which is the
property the audit exists to guarantee. `FrameSuperseded` is the contract's own
"the only non-failure way an accepted tracked delivery can terminate without a
draw", so this uses the existing vocabulary rather than inventing one.

Flush-induced drops are re-baselined away rather than charged to the newly armed
generation — DESIGN.md section 6 measured a single mid-run flush producing 157
drops of 783, and charging those forward would superseded-starve a fresh
timeline.

Honest limitation: the debt arrives up to ~1 s late, so the correction is exact
in aggregate but not frame-aligned. In every live run this session the debt
never fired at all (`superseded_delta = 0` everywhere, i.e. zero measured drops).
**That means the drop-audit path is implemented but has not been exercised by a
real drop.**

### 3. Lease retirement and the surface budget — truthful, with the arithmetic

The presenter holds **two** FrameLeases in steady state: the admitted frame, and
its predecessor, retired only one enqueue later. Releasing the predecessor at
enqueue time would leave a live IOSurface that the renderer still owns and this
process has stopped charging against `NativeSurfaceBudget` — the decoder pool
would then grow behind the budget's back. Phase A measured renderer retention at
max 1 (median 1) in decoded mode, so one retirement slot covers it.

`native_video_consumer.hpp` now carries
`kMaximumTrackedOutputSurfaceOwnership = 2` with the per-implementation
derivation in comments (GL = 1, layer = 2), and the `static_assert` reads
**5 decoder + 1 decoded queue + 1 scheduler + 2 output = 9 <= 10**, one surface
of headroom. A second `static_assert` in `native_layer_video_output.mm` pins the
presenter's own `kRetainedFrameLeaseCeiling` to that budget input so the two
cannot drift.

`macos_native_surface_budget` and `macos_native_video_consumer` both pass.
**Not yet verified live**: no run sampled `NativeSurfaceBudget::stats()` peak
surfaces during layer playback, so the "9 of 10" is asserted arithmetic plus
Phase A's retention measurement, not an in-app observation.

### 4. Flush/close semantics

`flushWithRemovalOfDisplayedImage:completionHandler:` (the current API, not the
deprecated `flushAndRemoveImage`). Seek flushes pass `NO` so the last frame stays
on screen and the window does not flash black between the flush and the post-seek
IDR; terminal close passes `YES`. The completion handler is the layer route's
terminal invalidation proof, replacing the GL route's "observed from a real Qt
render pass" — which is precisely the dependency that made an occluded window
unable to ever produce a `Stopped` proof.

An admitted frame at flush/close time is terminated `FrameSuperseded` before the
flush is issued.

**Not yet verified live**: no seek was performed in any run, so
`flushProgress()`/`closeProgress()` have never executed against a real renderer.
This is the largest untested area of the presenter.

### 5. Host view

Option S1 from DESIGN.md section 2, as recommended: a layer-*hosted* NSView
(layer assigned before `wantsLayer`, `layerContentsRedrawPolicy` Never,
autoresizing mask tracking the content view) inserted with
`addSubview:positioned:NSWindowBelow relativeTo:` Qt's view.
`videoGravity = resizeAspect` letterboxes inside the layer, so the existing
`macos_window_chrome` geometry code needs no changes at all — the layer is just
one more thing that follows the content view. Implicit layer animations on
bounds/position are disabled so a live drag-resize cannot lag the window edge.

The Qt view handle comes from the video item's own window
(`videoItem->window()->winId()`), so **`main.cpp`'s window plumbing was not
touched** for the sandwich.

---

## Files changed

| file | change |
|---|---|
| `src/platform/macos/native_layer_video_output.{hpp,mm}` | **new** — the presenter |
| `src/platform/macos/native_layer_host_view.{hpp,mm}` | **new** — NSView + ASBDL below Qt |
| `src/platform/macos/native_layer_presentation_state.hpp` | **new** — header-only active flag |
| `src/platform/macos/native_media_session_system.mm` | route selection at the single construction site; host view retained in the session lifetime |
| `src/platform/macos/native_video_consumer.hpp` | surface-budget input + `static_assert` arithmetic |
| `src/qt/player_controller.cpp` | `requestVideoUpdate()` no-ops while the layer route presents |
| `src/qt/main.cpp` | `layerPresentation` context property |
| `qml/Main.qml` | `videoBackdrop` becomes transparent on the layer route |
| `CMakeLists.txt` | new sources + AVFoundation/QuartzCore on `wam_macos_native_qt_tracked` |

Toggle: `WAM_PRESENTATION=layer|scenegraph`, **default `scenegraph`**. The layer
route is opt-in until the unverified items below are closed. The GL path remains
a full implementation and is also the automatic fallback if the host view or the
layer cannot be created, or on macOS < 14.

---

## Measured results

### The mechanism works: Qt goes idle in the real app

Same session, same clip, back to back, both runs confirmed frontmost at the
start of the window:

| | layer | scenegraph |
|---|---|---|
| Qt render passes, whole run | **24** | 362 |
| `agx_gpu_time` delta over 35 s | **0** | 30,016,750 |
| GPU % of device | **0.00** | 0.11 |
| `Owned physical footprint (unmapped) (graphics)` | 4.13 MB | 2.88 MB |
| drawn fps | **30.00** | 0.841 |
| discarded late frames | **0** | 1006 |
| CPU mean | 8.90 % | 4.19 % |
| footprint total / graphics categories | 152.1 / 106.9 MB | 150.6 / 105.6 MB |

**The render-pass and GPU-time columns are the pivot's thesis, and they hold:**
24 render passes across an entire run versus 362, and literally zero accumulated
GPU time versus 30 M units. Neither run shows the ~236 MB AGX render-pass pool
signature.

### The payoff CPU/memory comparison is NOT valid, and this row is why

The scenegraph arm drew **0.841 fps with 1006 late frames** — 29.2 late/s,
exactly the content frame rate. That is the counterfeit
AGENT_PERFORMANCE_PRINCIPLES.md warns about verbatim: "occlusion produces clock
1.0000 + frozen draws + late-drops at exactly the frame rate — a perfect
counterfeit of starvation". A drawing-verification gate then confirmed the cause
directly: WAM lost frontmost to Google Chrome on all six re-activation attempts.

So the scenegraph arm was **not compositing**, its 4.19 % CPU is artificially low
(it wasn't rendering), and its AGX pool never formed. **Comparing 8.90 % against
4.19 % would be comparing a working presenter against a stalled one.** The CPU
and footprint targets from Phase A (CPU materially below 12 %, footprint
< 200 MB, graphics pool ~0) are therefore **not established** by this session.
What is established is the structural half: zero render passes, zero GPU time,
no pool.

This needs a re-run on a machine where WAM can hold frontmost, at the parked
640x360 geometry, with Accessibility granted.

### Clip families on the layer route (step 4a)

~22 s each, layer route, one launch per clip:

| clip | drawn fps | late | superseded | clock | underruns |
|---|---|---|---|---|---|
| h264-high.mp4 | 29.95 | 0 | 0 | 1.000000 | 0 |
| **h264-high.mkv** | **18.56** | **223** | 0 | 1.000000 | 0 |
| hevc-main.mp4 | 30.05 | 0 | 0 | 1.000000 | 0 |
| h264-44k.mp4 | 30.00 | 0 | 0 | 0.999575 | 0 |
| h264-silent.mp4 | 30.00 | 0 | 0 | 1.000000 | n/a |
| vp9-aac.mkv | 30.00 | 0 | 0 | 1.000000 | 0 |
| av1-aac.mkv | 30.00 | 0 | 0 | 1.000000 | 0 |

Six of seven are clean, with `drawn == submitted` and zero superseded
everywhere. No `WAM: native failure` line in any run; no fallback.

**h264-high.mkv is an outlier and is probably not a presentation defect**:
`drawn == submitted` and `superseded == 0`, so the presenter accepted and
acknowledged every frame it was handed — the 223 late frames were retired by the
scheduler *before* reaching the output, i.e. upstream in demux/decode. The other
two Matroska clips are clean at 30 fps, so it is specific to this file. Note the
Matroska demuxer is one of the files carrying another session's uncommitted
changes.

### Seeks and the commit chain (step 4b) — VERIFIED on the layer route

Driven through `WAM_TEST_SEEK_SCRIPT`, which replays real scrubber gestures
(`beginScrub` / `previewSeekTo` / `endScrub`) so both the preview lane and the
exact commit are exercised, and which works on a non-frontmost window. The
telemetry stream needs all four identity variables to emit
(`WAM_NATIVE_BENCHMARK_TELEMETRY` + `RUN_ID` + `ASSET_SHA256` + `CANDIDATE_ID`);
with only the first it is silently inert, which cost one wasted run.

**h264-high.mp4, 3 seeks** (`40.5@6,12@14,30@20`):

| jump | superseded | late |
|---|---|---|
| 6.02 -> 40.59 (forward) | 0 | 0 |
| 40.59 -> 12.16 (**backward**) | 0 | 0 |
| 20.01 -> 30.45 (forward) | 0 | 0 |

Telemetry phases: 3 x `commit_seek_submitted` -> 3 x `commit_ready` ->
**3 x `commit_frame_drawn`**. Run ended at media 56.95 s with
`drawn == submitted == 1234`, 0 superseded, **0 late**, 0 underruns, and no
`WAM: native failure` line.

**hevc-main.mkv, 2 seeks** (`35@6,10@13`): forward 6.14 -> 35.07 and
**backward** 35.07 -> 10.22, **2 x `commit_frame_drawn`**, 0 superseded.

So `flushProgress()` — including the generation change, the
`flushWithRemovalOfDisplayedImage:NO` completion-handler invalidation proof, and
the backward-seek case DESIGN.md flags as requiring a flush first — works, and
`commit_frame_drawn` still fires on the acceptance-class proof exactly as the
contract requires.

### An upstream lateness finding on H.264/HEVC-in-Matroska

Three Matroska runs show heavy late-frame retirement that the MP4s do not:

| clip | drawn fps | late |
|---|---|---|
| h264-high.mkv | 18.56 | 223 |
| hevc-main.mkv (seek run) | — | 819 |
| vp9-aac.mkv | 30.00 | **0** |
| av1-aac.mkv | 30.00 | **0** |
| every MP4 tested | ~30.00 | **0** |

**This is upstream of the presenter, not a layer-route defect.** In every one of
these runs `drawn == submitted` and `superseded == 0`: the output accepted and
acknowledged every frame it was handed. The late frames were retired by the
scheduler *before* reaching the output, i.e. in demux/decode pacing. The clean
within-route contrast is decisive — the same presenter, same session, delivers
0 late on h264-high.mp4 across 57 s and three seeks.

Note the Matroska demuxer is one of the files carrying another session's
uncommitted changes, and that VP9/AV1 Matroska is clean while H.264/HEVC
Matroska is not. Not diagnosed further; flagged for the queue. It could not be
A/B'd against the GL route because the GL route cannot be kept compositing in
this environment, and a non-compositing GL window produces late-drops at exactly
the frame rate — the same signature, from a different cause.

### Tests

`ctest -R` on the required regex plus the four named suites: **13/13 pass**,
including `macos_native_surface_budget`, `macos_native_video_consumer`,
`macos_native_tracked_video_arbiter`, `macos_native_media_session`.

Full suite, run serially with nothing else active: **exactly 5 genuine
failures** — `macos_native_video`, `macos_native_qt_gl_compositor`,
`macos_native_video_pipeline`, `macos_native_qt_gl_output`,
`macos_video_toolbox_decoder`. **The 5 known GL-area failures, unchanged, and no
others.**

The same run also reported 17 tests as "Subprocess killed". Those are
environmental, not regressions: re-running a sample of them
(`jobs`, `state_store`, `caption_service`, `native_playback_contract`,
`player_controller_lazy`) individually gives **5/5 pass**. Phase A hit the same
class of interference ("an unrelated codesigning kill", DESIGN.md section on
route a2). Do not read a full-suite run on this machine without re-checking
killed tests individually.

---

## Pre-existing defect observed (not introduced here)

Two runs on the **GL route** ended the native phase early with:

```
WAM: native failure stage=steady reason=Decode class=Consumer error=""
WAM: Native decoding failed; using compatibility playback.
```

- Not EOF (h264-high.mp4 is ~72 s; the failure lands at ~50 s of media).
- Not the start watchdog — that prints "Native playback did not start in time".
- The **`error=""` is empty**: the consumer refused without writing its
  `std::string* error` out-param, so the one diagnostic the failure line exists
  to carry is missing on this path. `class=Consumer` names the seam but not the
  reason. Worth fixing on its own.
- Prime suspect, already on the record: AGENT_PERFORMANCE_PRINCIPLES.md's
  "UNVERIFIED LIVE" section flags the **reorder cap lowered from 8 to 4 in
  `native_video_consumer.mm`** as "the only change that can refuse content that
  previously played", never verified on a real window. Not confirmed — no
  control build was run.

It did not reproduce on the layer route within the windows measured (the longest
layer run reached media 42 s without a failure), but the layer runs were shorter,
so this is **not** evidence that the layer route is immune.

---

## What is NOT verified (honest inventory)

1. **The payoff CPU/footprint targets** — see above; the control arm was not
   compositing.
2. **`closeProgress()`** has not been separately verified: every run was
   terminated with `pkill` or the quit timer rather than a clean EOF or a
   route teardown, so the terminal-invalidation path
   (`flushWithRemovalOfDisplayedImage:YES`, wake-gate drain, `Closed`) is
   code-reviewed but not exercised. `flushProgress()` **is** verified — see the
   seek section.
3. ~~EOF~~ **VERIFIED**: h264-silent-short.mp4 (8.0 s) played to media 7.97 s
   with `drawn == submitted == 240` (30.0 fps exactly), 0 superseded, 0 late, no
   `WAM: native failure` line and no fallback; the route then held at end of
   stream for the remaining ~22 s of the run without incident.
4. **Deliberate occlusion test** (cover the window 10 s mid-playback). Partly
   observed by accident — the layer route sustained 29.95 fps while Chrome was
   frontmost and covering it, which is the predicted behaviour — but not run as
   a controlled test.
5. **Chrome interaction / region screenshots** over the layer, and aspect snap /
   hugs-video / fit-to-screen / actual-size programmatic resize exactness. These
   need Accessibility, which this session does not have.
6. **Benchmark-harness compatibility** (`run_suite`-style telemetry launch).
7. **The drop audit never fired** — zero measured drops in every run, so the
   FrameSuperseded-on-drop path is code-reviewed but not exercised.
8. **No contract test** for the layer output yet
   (`tests/native_layer_video_output_test.mm`, DESIGN.md item #8). The presenter
   is testable headlessly — an `AVSampleBufferDisplayLayer` accepts and
   acknowledges enqueues without ever joining a view hierarchy, which is why
   `createTracked(nullptr, ...)` builds its own detached layer.
9. **Surface budget peak** not observed live.

## Attempted and reverted

- `PlayerController::requestVideoUpdate()` gate probe
  (`WAM_GATE_SUPPRESS_VIDEO_UPDATE`) — measurement only for STEP 0; reverted.
- First payoff harness windowed the metrics stream by `time.monotonic_ns()`.
  The metrics carry their own monotonic clock with a **different epoch**
  (211,297 s vs 172,494 s at the same instant), so every sample was filtered out
  and both arms reported "0 drawing samples". Fixed by windowing inside the
  stream's own clock. Recorded because the failure mode looked like "playback
  produced nothing" rather than "the filter is wrong".
