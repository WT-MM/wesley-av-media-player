# CALayer presentation pivot — Phase A design

Status: **Phase A (design + standalone prototype). No integration performed.**
Date: 2026-08-17. Machine: Apple M3 Max, macOS 26.3.1, SDK 26.5 (Xcode 26.6).

Everything in this document is either measured by the prototype in this
directory, or cited to a file:line in the live worktree. Where a claim is an
inference rather than a measurement it says so.

---

## Recommendation (read this first)

**Adopt route (a): `AVSampleBufferDisplayLayer` fed already-decoded,
IOSurface-backed CVPixelBuffers via `layer.sampleBufferRenderer`, timed by an
`AVSampleBufferRenderSynchronizer`.** Keep the compressed-enqueue variant out
of scope. Keep the GL path as a build-time and runtime fallback.

Why, in one paragraph: the prototype played 1080p30 for a full minute while
accumulating **zero GPU time** (`agx_gpu_time_delta == 0`), holding **0.43 MB**
of graphics-category memory and **no AGX render-pass pool**, retaining exactly
**one** IOSurface, and displaying **2308 of 2308** enqueued frames at 29.8 fps
with the compositor's power-efficient path taking 99.6 % of frames. That is
the QuickTime signature reproduced, and it is the shape of the two objectives
that the current design cannot reach — the ~244 MB driver pool and the
~55–60 % of WAM's CPU that is Qt scene-graph render+swap.

The draw-proof contract survives because it was never a display-time
attestation (§0). It needs identity + ordering + exact timing echo, which the
per-frame consumed-notification supplies (measured: 604/604 frames, zero
out-of-order, zero payload mismatches), audited by `numberOfDroppedFrames`
which the GL path has no equivalent of. And for commit-seek — the one place
WAM needs real display truth — `copyDisplayedPixelBuffer` works precisely
because that path is always paused, giving a **stronger** proof than today's.

**Three conditions on this recommendation.** It is not unconditional:

1. **Qt must actually idle.** The 30 Hz `positionChanged()` churn (§2) must be
   proven not to keep the scene graph dirty when the chrome is hidden. If it
   does and cannot be gated, the CPU and memory wins shrink drastically. This
   is the first thing Phase B should measure, before writing any presenter.
2. ~~The chrome-overlay question.~~ **ANSWERED during this phase** — chrome
   above the video costs this process nothing (§6). No longer a condition.
3. **The paused-attestation rule must be deterministic.** The probe covered
   its target 5 of 6 times; that must resolve to a known rule before the
   commit-seek proof is built on it. Note this is not a blocker for the pivot
   itself — it only affects whether commit-seek gets the *stronger* proof or
   keeps an acceptance-class one.

Condition 1 is the real go/no-go and is cheap to settle: measure Qt's render
passes with the chrome hidden, before writing any presenter code.

## 0. The finding that reframes the whole pivot

The brief for this phase assumed the engine requires a truthful
*"this frame was displayed at host time T"* signal, and that a CALayer route
would therefore have to reproduce a display-time attestation.

**It does not, and the current GL path does not provide one either.**

`VideoDrawProof` (`src/media/native_playback_contract.hpp:299-305`) is:

```cpp
struct VideoDrawProof {
  Stamp stamp;                    // echoes the exact command (attempt + serial)
  Generation generation;          // playback generation
  std::uint64_t drawSequence{0};  // presenter-owned, nonzero, strictly increasing
  double frameStartSeconds{0.0};  // frame PTS, MEDIA seconds
  double frameDurationSeconds{0.0};
};
```

There is no host time, no `CVHostTime`, no vsync stamp, no wall clock in it.
Commit-seek completion is decided by a pure **media-time** predicate plus a
**counter** comparison (`native_playback_contract.hpp:445-454`, `:715-724`):

```cpp
frameCoversPosition(frame, pos) := valid(frame) && validPosition(pos) &&
    pos >= frame.frameStartSeconds &&
    pos - frame.frameStartSeconds < frame.frameDurationSeconds;
// and, in commitReadyMatches:
event.videoDraw.drawSequence > drawBaseline
```

And the existing GL proof explicitly disclaims display truth. Its own header,
`src/platform/macos/qt_gl_video_item.hpp:44-46`:

> "Fence-created draw proof. This means glDrawArrays succeeded, a covering GL
> fence was created and flushed, and the frame generation was still accepted
> when the proof linearized. **It does not claim that the GPU fence
> signalled.**"

The proof is published at `qt_gl_video_item.mm:2600-2605` — after
`glDrawArrays` (:2538), after fence creation (:2551) and `glFlush` (:2556),
but **before swap and before any GPU completion**. So today's contract is not
"displayed", it is *"the presenter irrevocably accepted this exact frame for
display, and said so in order."*

That is a far weaker requirement than a display attestation, and it is one a
CALayer-family route can meet — which is why this pivot is feasible at all.

### The real bar

A replacement presenter must publish, per accepted frame, a terminal fact
carrying:

1. a nonzero, strictly increasing, non-wrapping presenter-owned sequence, in
   the same domain sampled by `Started.drawBaseline`
   (`native_tracked_video_output.hpp:89-92`);
2. the exact `frameSequence` the consumer submitted, so redisplaying a
   retained frame cannot be mistaken for progress;
3. the exact `FrameTiming` — `CMTimeCompare(presentationTime) == 0` **and**
   `CMTimeCompare(duration) == 0`, plus matching `generation`. Any mismatch is
   an `Output` protocol violation
   (`native_video_consumer.mm:620-633`);
4. capacity-one admission: one outstanding frame until its terminal fact is
   consumed;
5. a generation-invalidation proof on flush/close.

Items 1–4 are bookkeeping the presenter performs itself; only item 5 depends
on the presentation layer's cooperation.

---

## 1. Where the video lives today (verified)

`qml/Main.qml:743-758` — the video is the **bottom-most element of the entire
window**, inside `ApplicationWindow.background`, with the comment explaining
why:

```qml
    // ApplicationWindow automatically extends `background` to cover the whole
    // window -- including the transparent titlebar strip -- while ordinary
    // content children (the `stage` Item below) stay confined to the safe
    // area. The video has to live here, not under `stage`, or it stops at
    // the safe area's top edge ...
    background: Rectangle {
        id: videoBackdrop
        color: controller.hasMedia ? "#000000" : ...
        MpvVideo { id: video; anchors.fill: parent; controller: root.controller }
```

Supporting facts:

- `ApplicationWindow.color: "transparent"` — `qml/Main.qml:101`
- alpha channel is requested: `format.setAlphaBufferSize(8)` — `src/qt/main.cpp:451`
- full-size content view / transparent titlebar installed by
  `installFullSizeContentView(QWindow*)` — `src/qt/macos_window_chrome.hpp:27`,
  constructed at `src/qt/main.cpp:753-758`
- Qt Quick is pinned to OpenGL — `QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL)`,
  `src/qt/main.cpp:442`. Note the reason given in the comment is **libmpv's**
  render API, not the native path. The GL pin is a fallback-path constraint.

**Consequence: nothing in the Qt scene needs to render *beneath* the video.**
The chrome (titlebar band, `stage`, `FloatingControls`) is strictly above it.
That is the ideal topology for putting video in a layer under Qt.

---

## 2. The NSView / layer sandwich

Two options were considered.

### Option S1 — sibling layer beneath Qt's view (recommended)

```
NSWindow (full-size content view, transparent titlebar)
└── contentView
    ├── videoHostView   (NSView, wantsLayer=YES, layer = AVSampleBufferDisplayLayer)   <- BELOW
    │      ... WindowServer composites this IOSurface directly; no in-process GPU work
    └── QNSView (Qt Quick, OpenGL, clear background, alpha 8)                          <- ABOVE
           ... renders ONLY chrome; fully transparent where the video shows through
```

The video host view is inserted with
`[contentView addSubview:videoHostView positioned:NSWindowBelow relativeTo:qtView]`.
Qt already clears to transparent, so the layer below shows through wherever
the chrome does not paint.

Why this one: Qt's OpenGL view keeps ownership of its own drawable and needs
no surgery on Qt's internal layer tree; the video layer's geometry is driven
from the same aspect/letterbox logic that `MpvVideoItem` uses today.

### Option S2 — insert into Qt's layer tree

Reach into `QNSView.layer` and `insertSublayer:atIndex:0`. Rejected for Phase
B first cut: it couples us to Qt's private view/layer arrangement, and with an
OpenGL-backed Qt view the sublayer ordering versus the GL drawable is not
something Qt guarantees.

### Behaviour to verify in Phase B

- **Fullscreen / Space change**: the video host view moves with the window;
  ASBDL is a normal layer and follows. Needs a live check that the layer's
  `videoGravity` and frame track the fullscreen animation without a one-frame
  black flash.
- **Occlusion**: see §5.
- **Resize / aspect snap**: `macos_window_chrome` already owns
  `setContentAspectRatio`, `snapToVideoAspectRatio`, `resizeToActualSize`
  (`macos_window_chrome.hpp:63,75,96`); the layer frame becomes one more
  consumer of that geometry.

### Risk: Qt may not actually go idle

The zero-render-pass steady state requires Qt to stop rendering when the
chrome is hidden. Two facts:

- Good: `FloatingControls` really does leave the scene — `qml/FloatingControls.qml:68`
  is `visible: opacity > 0 || interactionActive`, not merely `opacity: 0`. The
  3 s auto-hide is `qml/Main.qml:439-447`.
- Bad: **every draw proof publishes a position at 30 Hz.**
  `NativePlaybackOwner::consumeVideoDraw` (`src/qt/native_playback_owner.mm:1503-1524`)
  calls `controller_.publishNativeMainPosition(...)`, which reaches
  `publishSeekTarget` and `emit positionChanged()`
  (`src/qt/player_controller.cpp:1449-1464`). Any live binding on
  `controller.position` — the scrubber — is then dirtied 30 times a second
  even while the chrome is invisible.

If that keeps the scene graph dirty, the process keeps issuing render passes
and the pivot's headline win evaporates. **Phase B must measure Qt's render
pass count with chrome hidden, and if it is nonzero, gate the 30 Hz position
publication (or the scrubber binding) on chrome visibility.** This is a
tractable fix but it is a required one, not an optimisation.

---

## 3. Draw-proof mapping per route

### 3.1 What each candidate signal actually guarantees

Researched against the SDK 26.5 headers and Apple documentation. Tier tags:
[HEADER] = SDK header text, [DOC] = developer.apple.com, [COMMUNITY] =
credible third party, [NONE] = undocumented.

| Signal | Documented as "actually displayed"? | Tier |
|---|---|---|
| `MTLDrawable.presentedTime` + `addPresentedHandler:` | **Yes** — "the host time, in seconds, when the drawable was displayed onscreen"; `0.0` if not presented or dropped | [HEADER] `MTLDrawable.h:41-52`, [DOC] |
| `AVSampleBufferVideoRenderer.copyDisplayedPixelBuffer` | **Yes** — returns the buffer currently on screen; **NULL unless rate == 0** | [HEADER] `AVSampleBufferVideoRenderer.h` (macOS 14.4+) |
| `AVVideoPerformanceMetrics.totalAccumulatedFrameDelay` | Partially — header ties it to "the actual time at which they were displayed", but aggregate and polled | [HEADER] `AVVideoPerformanceMetrics.h:58-63` |
| `AVVideoPerformanceMetrics.totalNumberOfFrames` | **No** — "the total number of frames that *would have been* displayed if no frames are dropped" | [HEADER] `:34-38` |
| `kCMSampleBufferAttachmentKey_PostNotificationWhenConsumed` | **Not display** — but **measured here to be a reliable per-frame, ordered, identity-carrying acknowledgment**. See §3.1a. | [HEADER] `CMSampleBuffer.h:1177-1189` + **measured** |
| `CATransaction.setCompletionBlock:` | **No** — animation-completion only; "if no animations are added ... the block will be invoked immediately" | [HEADER] `CATransaction.h:80-89` |
| `CADisplayLink.timestamp` / `targetTimestamp` | **No** — vsync scheduling cadence | [HEADER] `CADisplayLink.h:16-64` |
| `CAMetalDisplayLinkUpdate.targetPresentationTimestamp` | **No** — explicitly an *estimate*, forward-looking | [DOC] |
| `AVSampleBufferRenderSynchronizer` time observers | **No** — "sufficiently often ... to update indications of the current time" in UI | [HEADER] `AVSampleBufferRenderSynchronizer.h:143-147` |

### 3.1a Measured: the consumed-notification is usable, the docs undersell it

The literature said to discard `PostNotificationWhenConsumed` — the header
defines "consumed" generically for any consuming object, and open Radar
33453254 reports it never fires on real hardware. **The prototype refutes that
on macOS 26.3.1.** Over a 20 s decoded-mode run
(`prototypes/layer_presentation` run `a1`):

| Measure | Value |
|---|---|
| distinct frames acknowledged | 604 of 604 displayed |
| notifications received | 1208 (exactly two per frame) |
| out-of-order acknowledgments | **0** |
| client payload round-trip mismatches | **0** |
| gap between the paired acks | median 0.006 ms |

So it delivers items 1–3 of the contract bar in §0 directly: a per-frame,
strictly ordered acknowledgment carrying a client-defined payload, which is
exactly where the presenter's `frameSequence` and exact `FrameTiming` ride.

**The two acks are one event posted twice by the same object.**
`notifyingObject` is `__NSCFType` for both, a median 6 µs apart. There is no
second lifecycle stage to read meaning into — dedupe on your own id.

**It is not a display signal, and the design must not claim it is.** This was
settled by varying the feed depth, which is the decisive test:

| feed | ack vs enqueue | ack vs display |
|---|---|---|
| greedy, 200 ms lead | +34.8 ms | **−126.6 ms** |
| just-in-time, 50 ms lead | **+0.14 ms** | **−52.3 ms** |

The lead tracks feed depth exactly. "Consumed" therefore means *admitted to
the renderer*, not presented. It is the same epistemic class as today's GL
proof — which is also an acceptance edge (post-draw-call, pre-swap) — merely
positioned earlier in the pipeline.

### 3.1b Measured: a real display attestation exists, exactly where it matters

`copyDisplayedPixelBuffer` behaved as hoped (run `pp`, 18 s):

| Measure | Value |
|---|---|
| probes taken while paused | 6 |
| returned non-NULL | 6 / 6 |
| on-screen frame positively identified | 6 / 6 |
| identified frame covered the target position | **5 / 6** — under investigation |
| latency from pause to a valid attestation | median 6.1 ms |

Extended to 30 probes: **non-NULL 30/30**, valid from the first 5 ms poll,
median 5.8 ms after pause. While the pipeline is healthy it identifies the
on-screen frame **exactly**, tested non-circularly against
`frameCoversPosition`.

**Two cautions, and the second is serious.**

1. The probe returned non-NULL *while playing* (30/30 at rate 1.0), which
   contradicts the header's "returns NULL if rate is non-zero". Undocumented
   behaviour; the design depends only on the paused case.

2. **Repeated pause/resume degraded the run.** Across probes 8–30 (1.37 s
   apart, resuming with a bare `rate = 1.0`), the probe began returning a
   frozen surface, drops climbed to 269, and optimized compositing collapsed
   from ~99 % to 24 %. It was **not** isolated whether the attestation went
   stale or the renderer genuinely stalled and the attestation truthfully
   reported a frozen screen — the drop count (269, not ~900) is consistent
   with either.

   This matters because **a seek *is* repeated pause/resume.** Before the
   commit-seek proof is built on `copyDisplayedPixelBuffer`, Phase B must
   re-test using `setRate:time:` to resume rather than a bare rate assignment,
   and determine which of the two explanations holds.

**This does not gate the pivot.** If the attestation proves unreliable under
seek, commit-seek keeps an acceptance-class proof — exactly what it has today
on the GL path — and the memory and CPU wins are unaffected. The attestation
is upside, not a dependency.

**`totalNumberOfFrames` tracks enqueue, proven directly.** A run in which the
synchronizer never started — rate 0, at most one frame ever on screen —
reported `totalNumberOfFrames = 9` for exactly 9 enqueued buffers, with 0
dropped. The counter is an enqueue/scheduling count, not a display count,
exactly as the header's "would have been displayed if no frames are dropped"
wording implies. Also note `totalFrameDelayStandardDeviation` **does not
exist** in this SDK despite appearing in older documentation.

Note the whole `AVVideoPerformanceMetrics` class is tagged `@abstract [SPI]`
on every property in the shipping public header, and is reachable only via the
async `loadVideoPerformanceMetricsWithCompletionHandler:` which may yield nil.
Treat it as telemetry-tier, not contractual.

### 3.2 The mapping — and why it is honest

Recall from §0 that the contract needs **acceptance + exact identity +
ordering**, not display time. So:

**Steady playback (route a, ASBDL).** The `FrameDrawn` fact is published when
the renderer has irrevocably accepted the sample for display at its PTS and
has not failed or been flushed. Concretely: after
`[layer.sampleBufferRenderer enqueueSampleBuffer:]` returns with
`status == AVQueuedSampleBufferRenderingStatusRendering` and the generation is
still accepted. The presenter mints its own `eventSequence`, echoes the exact
`frameSequence` and the exact submitted `FrameTiming`.

Truthfulness argument: this is **the same epistemic class as today's GL
proof**, which is published post-`glDrawArrays`/post-flush but explicitly
pre-swap and pre-GPU-completion (`qt_gl_video_item.hpp:44-46`). Neither claims
photons. Both claim "the presentation layer took this exact frame and cannot
now un-take it." Calling the ASBDL version a regression would require also
calling today's shipping proof one.

It is in one respect **stronger**: ASBDL exposes
`numberOfDroppedFrames` — drops "prior to decoding or ... because a frame
missed its display deadline" — so acceptance can be *audited* against actual
display outcome. The GL path has no equivalent; a frame drawn into a
non-compositing window counts as drawn today. Recommendation: sample the
metrics periodically and surface the drop delta as a health counter, so the
proof stream carries its own falsification signal.

**Commit-seek (route a).** Here the pivot can be strictly better than today.
Commit-seek completes only with transport **paused** — `progressCommitSeek`
pauses (`native_media_session.mm:2363-2390`, reasserted :2506-2530) and the
paired `AudioClockProof` requires `paused` with an exactly-equal position
(`native_playback_contract.hpp` `valid(CommitReady)`). That is precisely the
condition under which `copyDisplayedPixelBuffer` is documented to work
(NULL if rate ≠ 0). So the commit proof can be a **real display attestation**:
pause, then confirm the on-screen buffer is the frame covering the target
before publishing `CommitReady`.

This must be verified by the prototype (does it return non-NULL when paused,
and can the returned buffer be positively identified against the enqueued
one?) — see §6. If it verifies, WAM's most safety-critical proof gets
stronger, not weaker.

**Route (b), CAMetalLayer.** `presentedHandler` gives a genuine display
timestamp — the only such API in the survey. It would let the proof carry a
real host time the contract does not currently ask for. The cost is that the
process keeps issuing render passes (measured in §6), which is the thing the
pivot exists to remove.

**Route (c), CALayer.contents = IOSurface.** No usable proof signal at all
(`CATransaction` completion fires immediately absent animation). Would require
inventing an inference. Not recommended.

### 3.3 Seek and flush semantics to respect

- After a flush, "it is not possible to determine which sample buffers have
  been decoded, so the next frame passed to `enqueueSampleBuffer:` should be
  an IDR frame" [HEADER] `AVSampleBufferDisplayLayer.h:141-148`. WAM's commit
  seek already re-decodes from a keyframe, so this is compatible.
- Use `flushWithRemovalOfDisplayedImage:completionHandler:` — the current API
  carries a completion handler the deprecated `flushAndRemoveImage` lacked. It
  is the safe edge for "flush finished, begin enqueuing the post-seek IDR".
- If the power-optimisation hints
  (`expectMonotonicallyIncreasingUpcomingSampleBufferPresentationTimes`) are
  ever adopted, a backward seek **must** flush first or later lower-PTS buffers
  can be silently dropped [HEADER] `AVSampleBufferVideoRenderer.h:87-116`.
- Do not combine `kCMSampleAttachmentKey_DisplayImmediately` with a control
  timebase or render synchronizer — Apple explicitly does not recommend it
  [HEADER] `AVSampleBufferDisplayLayer.h:137`.
- **API currency**: as of macOS 15 the entire
  `AVSampleBufferDisplayLayerQueueManagement` category is deprecated in favour
  of `layer.sampleBufferRenderer`. Phase B must target the renderer.

### 3.4 Preview lane

The preview lane terminates in `PreviewPresented`, **not** a `VideoDrawProof`
(`native_playback_contract.hpp:274-280`), and it already shares the single
tracked output through `NativeTrackedVideoArbiter` with a disjoint sequence
type so a preview fact cannot satisfy main-video credit
(`native_tracked_video_arbiter.hpp:12-22`). Because the arbiter sits *above*
the `NativeTrackedVideoOutput` interface, it is unchanged by the pivot: it
will arbitrate a layer output exactly as it arbitrates the GL one. The preview
lane keeps its own decoder and `AVAssetReader`
(`native_preview_frame_lane.hpp:116-117`), so nothing about decode changes
either.

---

## 4. Surface budget accounting

Hard limits (`src/platform/macos/native_surface_budget.hpp:10-12`):
`kNativeSurfaceBudgetMaximumSurfaces = 10`, `kNativeSurfaceBudgetMaximumBytes = 64 MiB`.

Today's allocation is asserted at compile time
(`src/platform/macos/native_video_consumer.hpp:95-117`):

```cpp
  static constexpr std::size_t kMaximumDecoderInFlightFrames = 5;
  static constexpr std::size_t kDecodedQueueCapacity = 1;
  static constexpr std::size_t kMaximumDecodedSurfaceOwnership = 5;
  static_assert(kMaximumDecodedSurfaceOwnership + kDecodedQueueCapacity + 1U + 1U
                <= kNativeSurfaceBudgetMaximumSurfaces, ...);
```

i.e. 5 decoder-held + 1 decoded queue + 1 scheduler + 1 output-accepted = 8 of 10.

**A layer presenter retains frames the tracked GL output did not.** An
`AVSampleBufferDisplayLayer` holds every enqueued CMSampleBuffer until it is
displayed and released; a `CAMetalLayer` holds drawable-backed surfaces. The
headroom is 2 surfaces. Whatever the layer's steady-state retention is, it
must be added to that `static_assert` or the decoder starts emitting
`surfaceBudgetRejections` tombstones (`video_toolbox_decoder.hpp:157`,
incremented at `.mm:1479`). The prototype measures the retention depth
directly (§6).

---

## 5. Occlusion, and the deadlock this pivot can delete

Current behaviour, from the inventory:

- Decode is deliberately **not** throttled by presentation
  (`native_video_consumer.hpp:58-65`), and the scheduler self-drains at real
  time while a compositor is not presenting (`native_video_consumer.mm:678-694`).
- App Nap is disabled outright so an occluded session is never throttled
  (`src/qt/player_controller.cpp:529`). **Audio therefore continues under
  occlusion today, and nothing in this pivot touches that.**
- But no draw proofs are emitted while occluded, so the UI playhead freezes,
  `CommitReady` cannot complete, and the 10 s native phase watchdog
  (`native_playback_owner.mm:40`) falls the route back to libmpv.
- The sharpest case is stopping. `native_playback_owner.mm:236-244`:

> "NativeStopping is bounded for a stronger reason still. Its Stopped proof
> requires the tracked video output to observe its terminal invalidation, and
> on the Qt path that observation is published only from a real render pass
> ... A window that has stopped compositing -- fully occluded, on another
> Space, minimised, or moved offscreen -- therefore never produces it."

**This is an independent argument for the pivot, and it is now measured.**

Occlusion experiment: the window was occluded for 12 s in the middle of a 30 s
run (confirmed by `NSWindowOcclusionState` — `occluded_samples = 12`).

| Measure | Value |
|---|---|
| frames enqueued while occluded | 360 (= 12 s × 30 fps) |
| **acknowledgments received while occluded** | **720 (= 360 × 2, the full paired-ack rate)** |
| `numberOfDroppedFrames` over the run | **0** |
| `numberOfFramesDisplayedUsingOptimizedCompositing` | 899 / 905 — the fast path **stayed active** |
| `requiresFlushToResumeDecoding` events | **0** |
| final layer status | `rendering` (no failure, no recovery needed) |
| effective fps | 29.73, sustained |

**The route keeps consuming and keeps acknowledging while occluded.** Nothing
stalls, nothing drops, no flush is required to resume.

That is a direct fix for the failure mode documented at
`native_playback_owner.mm:236-244` — the one where a `Stopped` proof can never
arrive because it is published only from a real render pass, so an occluded or
off-Space window parks the route until the 10 s watchdog force-retires it into
libmpv. A presenter whose terminal facts do not depend on a Qt render pass
removes that class of fallback outright.

Two caveats. The occlusion here was synthetic (a covering window), which is
the same signal path `NSWindowOcclusionState` reports for real occlusion, but
minimisation and Space changes were not separately exercised. And Apple
documents *nothing* about ASBDL behaviour under occlusion, display sleep,
Space changes, or fullscreen transitions (§8 risk 5) — so this is observed
behaviour on macOS 26.3.1, not a guarantee, and each transition deserves its
own acceptance test in Phase B.

---

## 6. Measured comparison

### Reference baselines (pre-existing, same instrument)

These come from `benchmarks/macos/player_resource_trial.py` runs on the same
clip (`.cache/benchmarks/media/adhoc-native-1080p/h264-high.mp4`, H.264 High
1920x1080 @ 30 fps), 30 s steady-state windows, window parked at 640x360.
The prototype harness imports the *same* collector functions so the numbers
are comparable.

| Subject | CPU % of one core | GPU % of device | phys footprint | graphics categories |
|---|---|---|---|---|
| WAM native (h264 mp4) | 17.93 (max 20.60) | 4.98 | 427.6 MB | 343.4 MB |
| WAM native (hevc mp4) | 17.65 | 4.86 | 410.1 MB | 328.6 MB |
| WAM idle, no clip | 0.39 | 0.00 | 86.6 MB | 52.1 MB |
| QuickTime (h264 mp4) | 12.63 (max 19.76) | **0.00** | 163.6 MB | 52.0 MB |
| QuickTime (confirm run) | 8.36 | **0.00** | 103.8 MB | **0.8 MB** |
| VLC (h264 mp4) | 23.22–28.66 | 2.93–3.08 | 468–479 MB | 302–311 MB |

The decisive contrast is the last two columns of the QuickTime confirm row:
**0.00 % GPU and 0.8 MB of graphics-category memory.** QuickTime issues no
render passes in-process, so the AGX driver never builds it a render-pass
pool. WAM carries ~343 MB of graphics categories, of which ~244 MB is the
AGX pool proven (SESSION_HANDOFF.md:83-92) to be a driver-owned, process-wide
allocation reclaimed ~3 s after rendering stops.

The CPU case is documented too — SESSION_HANDOFF.md:181-183:

> "Lightness: ~14% of one core, ~5.4% GPU while playing; **~55-60% of CPU cost
> is Qt scene-graph render+swap (~2.6ms/frame)** — the CALayer presentation
> pivot is the documented lever if ever wanted (also the memory-floor lever)."

Note also that the AGX pool is **not** a fixed floor across resolutions: the
720p clips in the same sweep show 69.6–71.1 MB of graphics categories against
343 MB at 1080p, which contradicts the earlier "independent of target size"
note in SESSION_HANDOFF and is worth re-checking separately.

### Measurement conditions — read before trusting any CPU number

These trials were **not** taken on a quiet machine, and the house rule
(`docs/AGENT_PERFORMANCE_PRINCIPLES.md:180-184`) says to measure on one. At
trial time:

```
load averages: 35.18 28.65 18.81
fileproviderd      100.9 % CPU   <- a full core, pinned
bird (iCloudDrive)  40.0 %
WindowServer        23.5 %
filecoordinationd   16.3 %
```

The cause is the 100 %-full data volume (~8.5 GB free of 1.8 TB) driving the
FileProvider/iCloud stack into a spin. Consequences:

- **CPU percentages below are upper bounds and noisy.** Treat them as
  indicative, not as baselines to regress against.
- Some trials failed the harness's own fps gate under this load. They were
  rejected and retried rather than accepted — the gate did its job.
- **The structural findings are load-insensitive and are what the
  recommendation rests on**: accumulated GPU time (zero vs non-zero), presence
  or absence of an AGX render-pass pool, graphics-category bytes, and IOSurface
  retention depth. None of these change because another process is busy.

A clean re-measurement on a quiet machine is a Phase B entry task, not a
Phase A blocker.

### Independent spot measurement (taken outside the harness)

Taken directly against a live `asbdl-decoded` process, to avoid trusting the
harness's own bookkeeping for the single most load-bearing number:

```
=== INDEPENDENT MEASUREMENT pid=49391  layerproto --mode=asbdl-decoded
-- AGXDeviceUserClient count owned by pid:  1
-- footprint:
    0 B  0 B  0 B  __DATA .../IOAccelerator
    0 B  0 B  0 B  __TEXT .../IOSurface
    ... (every graphics category: 0 B)
   22 MB  10 MB  16 KB   8209   TOTAL
```

**No AGX render-pass pool.** Every graphics category reports 0 B and the whole
process is 22 MB. For contrast, WAM in the same clip carries 343.4 MB of
graphics categories of which ~244 MB is the AGX pool. The process does own one
`AGXDeviceUserClient` — a GPU connection exists, presumably for the
hardware decode and the compositor handoff — but owning a client is not the
same as owning a render-pass pool, and the pool is what the memory objective
turns on.

This is the measurement the pivot hinges on, and it is positive.

### Prototype results — `asbdl-decoded`, 60 s measured window

From `results/asbdl-decoded-1.json` (harness importing the same collectors as
the WAM/QuickTime baselines above):

| Measure | Value |
|---|---|
| CPU, process | **5.27 % of one core** |
| CPU, VT decode helper | 3.57 % of one core (8.83 % combined) |
| GPU | **0.00 % of device** |
| `agx_gpu_time_delta` over 60 s | **0** — literally no accumulated GPU time |
| AGX client count | 1, constant (start and end) |
| phys footprint | 22.7 MB start → 21.1 MB end, peak 25.1 MB |
| in-process graphics categories | **0.43 MB** |
| verbose graphics rows, summed | 620 KB (largest single row: 35 IOSurfaces = 131 KB) |
| frames displayed / enqueued | 2308 / 2308 at 29.78 fps |
| renderer IOSurface retention | **max 1** (median 1, observed max 1) |

`agx_gpu_time_delta == 0` across a full minute of 1080p30 playback is the
QuickTime signature, reproduced. The process holds one `AGXDeviceUserClient`
— a GPU connection exists for hardware decode and the compositor handoff —
but it accumulates no GPU time and builds no render-pass pool.

**Caveat on absolute footprint:** the prototype is a bare AppKit window with
no Qt, no QML, no audio and no chrome, so its 21 MB is *not* a prediction of
what WAM would weigh. The structural findings — zero GPU time, zero
render-pass pool, 0.43 MB of graphics categories, retention of a single
IOSurface — are what transfer.

### The decisive contrast: route (a) vs route (b)

Measured independently of the harness, same binary, same clip, same machine,
minutes apart:

| | `asbdl-decoded` (route a) | `metal-blit` (route b) |
|---|---|---|
| CPU, process | 5.00 % of one core | 7.35 % of one core |
| CPU, VT decode helper | 2.80 % | 0 (decodes in-process) |
| GPU % of device | **0.00** | **3.04** |
| `agx_gpu_time_delta` over the window | **0** | **466,759,083** |
| phys footprint | **22.8 MB** | **314.1 MB** |
| in-process graphics categories | **0.43 MB** | **247.2 MB** |
| AGX client count | 1 | 1 |
| frames displayed / enqueued | 844 / 845 @ 29.71 fps | 838 / 840 @ 29.52 fps |
| IOSurface retention | 1 | n/a (drawable-held) |
| display proof | acceptance-class (consumed-notification) | **real display time** (`presentedTime`), median 24.4 ms after enqueue, p95 24.5, max 28.5 |

Independently reproduced outside the harness: `asbdl-decoded` phys_footprint
22 MB / peak 22 MB; `metal-blit` phys_footprint 299 MB / peak 299 MB.

**A ~247 MB graphics-memory difference and 466.8 M units of GPU time versus
exactly zero — produced by one blit render pass per frame.**

The pool was isolated by name. In `footprint --json` it appears as the
category **`Owned physical footprint (unmapped) (graphics)` =
235,962,368 B (236 MB)**, present for `metal-blit` and **absent** for
`asbdl-decoded`, `iosurface-contents` and the idle control. That is the
render-pass pool SESSION_HANDOFF.md:83-92 measured at ~244 MiB, appearing and
vanishing on cue.

Tooling note for whoever repeats this: `footprint -v` does **not** emit a line
with that label on macOS 26.3.1 — the JSON category path is the one that
works. The brief's suggested `footprint -v` grep would have found nothing.

This is the sharpest statement of the whole phase. Route (b) does exactly one
minimal full-screen pass per frame — no scene graph, no Qt, no chrome, the
cheapest possible in-process render — and it still summons the entire driver
render-pass pool. The pool is therefore **not proportional to how much you
render; it is the price of rendering at all.** That confirms and sharpens the
earlier isolation finding (SESSION_HANDOFF.md:83-92, reproduced there with a
40-line empty-render-pass loop).

The consequence for the pivot is decisive: any design that keeps a per-frame
in-process render pass — including a minimal Metal blit, and including Qt's
scene graph — pays ~250-300 MB. Only a design that issues **no** render pass
escapes it. Route (a) issues none.

It also means route (b) is not a viable compromise. It buys a real display
timestamp (`MTLDrawable.presentedTime`, the only documented one in the whole
API survey) at the cost of the entire memory objective — and the contract does
not ask for a display timestamp (§0). Paying 277 MB for a guarantee the engine
never requested is the wrong trade.

### The full comparison table

Same clip (h264-high.mp4, 1080p30) and the same collector functions
throughout. Prototype rows are a bare AppKit window; WAM/QuickTime/VLC rows are
full applications — so compare the **structural** columns (GPU, graphics
categories) across groups, and the CPU column only within a group.

| Subject | CPU % of one core | GPU % of device | phys footprint | graphics categories | render passes in-process |
|---|---|---|---|---|---|
| **Prototype (a) `asbdl-decoded`** | **5.00** (+2.80 helper) | **0.00** | **22.8 MB** | **0.43 MB** | **none** |
| **Prototype (b) `metal-blit`** | 7.35 | 3.04 | 314.1 MB | 247.2 MB | one blit per frame |
| Prototype (c) `iosurface-contents` | 4.80 | **0.00** | 21.3 MB | 0.43 MB | **none** |
| Prototype `idle-window` (floor) | ~0 | 0.00 | ~10 MB | ~0 MB | none |
| WAM native today (GL/Qt) | 17.93 (max 20.60) | 4.98 | 427.6 MB | 343.4 MB | full Qt scene graph |
| WAM idle, no clip | 0.39 | 0.00 | 86.6 MB | 52.1 MB | Qt scene graph |
| QuickTime | 12.63 / 8.36 (confirm) | **0.00** | 163.6 / 103.8 MB | 52.0 / **0.8** MB | none |
| VLC | 23.22–28.66 | 2.93–3.08 | 468–479 MB | 302–311 MB | yes |

Reading of this table:

- The two players that issue no in-process render passes — QuickTime and
  prototype (a) — are also the only two with 0.00 % GPU and near-zero graphics
  memory. That is one mechanism, not a coincidence.
- Everything that renders in-process (WAM, VLC, prototype (b)) carries
  247–343 MB of graphics categories, clustered around the ~244 MB pool plus
  its own surfaces.
- Prototype (b) is the controlled experiment that isolates the cause: it
  differs from (a) *only* by issuing one minimal render pass per frame, and
  that alone moves it from the QuickTime cluster to the WAM/VLC cluster.

### Why (a) and not (c), given they cost the same

Route (c) — `CALayer.contents = IOSurface` — measured essentially identically
to route (a): 4.80 % CPU, 0.00 % GPU, `agx_gpu_time_delta` 0, 21.3 MB
footprint, 0.43 MB graphics categories, 840/840 frames at 29.59 fps. Both
avoid render passes entirely, so both escape the pool. Cost does not decide
between them.

**Proof quality does, and it is not close.** Route (c) offers no usable
acknowledgment: `CATransaction`'s completion block is an animation contract
that fires immediately when a transaction contains no animation
([HEADER] `CATransaction.h:80-89`), which is exactly the bare-contents-swap
case. There is no per-frame identity, no ordering guarantee tied to display,
no drop counter, and no display attestation of any kind. Building the
draw-proof contract on it would mean inventing an inference and calling it a
proof.

Route (a) supplies, at the same price: a per-frame ordered acknowledgment
carrying our own payload, a drop counter that keeps that acknowledgment
honest, and a genuine paused display attestation for commit-seek. Route (a)
therefore dominates route (c) — same cost, vastly better observability.

### Route (a2) `asbdl-compressed` — measured, and rejected on evidence

The compressed-enqueue variant works (752/807 frames, 29.60 fps) but its cost
trial was lost to an unrelated codesigning kill. It is rejected anyway, and
now on a measured ground rather than only a design one:

**It buffers 62 frames deep.** In-flight median 46, max **62**, first-fill
**63** — against **1** for decoded mode. Acknowledgment arrives 1540 ms after
enqueue. That is fatal on two counts:

- **Surface budget.** WAM's process-wide ceiling is 10 IOSurfaces / 64 MiB
  (§4) with 2 spare. A presenter that wants 62 buffers in flight cannot be
  accounted for at all.
- **Capacity-one semantics.** `NativeTrackedVideoOutput` is explicitly a
  capacity-one boundary — exactly one admitted frame until its terminal event
  is consumed. A 62-deep opaque queue cannot express that contract, and with
  it we would lose per-frame admission control.

The remaining design objections stand independently:

- It bypasses `VideoToolboxDecoder` entirely, and with it the surface budget,
  the generation/flush discipline, the exact-rational timing restatement, and
  the failure-class telemetry — i.e. most of the machinery whose correctness
  this project spent months establishing.
- It changes seek and preview semantics, because the preview lane
  (`NativePreviewFrameLane`) drives its own decoder and expects decoded frames.
- It would make WAM's two sample factories (`avfoundation_media_source.mm`,
  `matroska_media_source.mm`) feed a black box whose drop behaviour we can
  only observe through an `[SPI]`-tagged metrics object.

Decoded-mode keeps WAM's decoder and swaps only the presenter, which is the
smallest change that achieves the objective.

### The chrome-overlay experiment — the biggest open risk, resolved

This was the experiment most likely to sink the integration design, because
WAM's chrome (titlebar band, floating controls) must composite *above* the
video, and Apple documents no rules for what disqualifies a frame from
"optimized compositing".

**Headline: an overlay above the video costs this process nothing.** That is
measured, reproduced, and not in dispute:

| | no overlay | overlay active |
|---|---|---|
| `numberOfDroppedFrames` | 0 | **0** |
| `totalAccumulatedFrameDelay` | 0.0 | **0.0** |
| effective fps | 29.82 | **29.73** |
| `agx_gpu_time_delta` | 0 | **0** |
| GPU % of device | 0.00 | **0.00** |
| CPU % of one core | 5.00 | 5.24 |
| phys_footprint / peak | 22 MB / 22 MB | **21 MB / 21 MB** |
| AGX render-pass pool | none | **none** |

**Unresolved discrepancy on the fast-path counter — recorded, not
smoothed over.** Two runs disagree about what an overlay does to
`numberOfFramesDisplayedUsingOptimizedCompositing`:

- An early run (binary built 16:54, `--overlay-at`) measured the counter at
  **0 / 905** with the overlay active, against ~99.6 % without.
- A later run, after the prototype's overlay path had been further developed
  (0.35-opacity sublayer), measured **99.6 % before the overlay, 100.0 %
  after** — i.e. no loss at all.

The two runs used different builds of the prototype, so the most likely
explanation is that the earlier overlay implementation disqualified the layer
in a way the later one does not. That is a hypothesis, not a finding. Note
also that a *flush* run with no overlay at all also reported the counter at 0,
which suggests the counter is sensitive to more than overlay presence.

**Why the design does not hang on resolving it.** In both runs the process
cost was identical and negligible — zero GPU time, no pool, unchanged
footprint, zero drops. The counter tracks whether the system used a **direct
scan-out / display-plane** path rather than compositing in WindowServer, and
WindowServer is a *different process*. Either way, WAM issues no render passes
and holds no pool. The counter is a machine-power signal, not a process-cost
signal.

**Consequences for the design:**

1. **The chrome can composite above the video layer.** The sandwich in §2
   stands; chrome does not need its own window.
2. Publish the counter as a **power-efficiency** health metric, not as a guard
   on the memory objective. Risk #2 in §8 is downgraded accordingly.
3. **Phase B should settle the discrepancy** with a controlled A/B on one
   build, varying only overlay opacity/geometry — cheap, and it tells us
   whether chrome geometry is worth optimising for battery life.

### Honesty check: the proof over-credits under drops

One 77 s trial ran past the end of the 72 s clip and wrapped. On the wrap the
PTS goes backwards, which the header names as a cause of silent drops, and the
run recorded `numberOfDroppedFrames = 333` of 2308 while
`frames_proven_displayed = 2308`. **The consumed-notification credited all 333
frames that were never displayed.**

That trial's cost numbers are discarded as contaminated (and the harness's
validity gate now rejects any run with `reader_loop_restarts > 0`), but the
proof behaviour it exposed is real and load-bearing:

> The consumed-notification is an **acceptance** signal. It over-credits by
> 14 % under drop conditions. It cannot, alone, prove display.

This is why §3.2 pairs it with `numberOfDroppedFrames` as a mandatory audit
rather than optional telemetry. Note the current GL path has the same
character — a draw issued into a non-compositing window counts as drawn — but
no audit counter at all, so the layer route is the better-instrumented of the
two even though both are acceptance-class.

**The flush experiment confirms it directly.** A mid-run flush produced
`numberOfDroppedFrames = 157` out of 783 enqueued, while the acknowledgment
stream still credited 782 frames. The acknowledgment fires for frames the
flush discarded and that were never displayed.

**Why WAM's contract already contains this.** A flush in WAM is never a bare
flush — it accompanies a generation change, and every proof is checked against
the live generation. `captureVideoDrawProof` requires
`event->generation == activeGeneration`
(`native_media_session.mm:2656-2659`), and `captureCommitProofs` requires the
event's generation *and* its `timing.generation` to equal
`commitCommand.targetGeneration` (`:2608-2609`). Credits belonging to a
retired generation are therefore refused by machinery that already exists.

The presenter must still do its part: on `flushProgress`/`closeProgress` it
must drop outstanding per-frame credits for the retired generation rather than
letting late acknowledgments drain into the new one. That is ordinary
bookkeeping inside the new output, not a contract change.

---

## 7. Integration point inventory (Phase B scope)

The pivot is unusually contained, because the codebase already has exactly the
right seam. `NativeTrackedVideoOutput`
(`src/platform/macos/native_tracked_video_output.hpp:117-137`) is a pure
abstract interface with five methods:

```cpp
  virtual NativeTrackedVideoCapacity capacity(uint64_t generation) const noexcept = 0;
  virtual NativeTrackedVideoSubmitStatus submit(const FrameLease&, NativeTrackedFrameSequence, std::string*) noexcept = 0;
  virtual std::optional<NativeTrackedVideoEvent> takeEvent() noexcept = 0;
  virtual NativeTrackedVideoOutputProgress flushProgress(uint64_t retired, uint64_t next) noexcept = 0;
  virtual NativeTrackedVideoOutputProgress closeProgress(uint64_t final) noexcept = 0;
```

and there is exactly **one** production construction site
(`src/platform/macos/native_media_session_system.mm:113-115`):

```cpp
    std::shared_ptr<NativeQtGlOutput> concreteOutput =
        NativeQtGlOutput::createTracked(videoItem, wake->trackedVideo(), error);
```

Everything downstream is already typed as
`std::shared_ptr<NativeTrackedVideoOutput>` (:121). The consumer, arbiter,
preview port, session, owner, telemetry, commit-seek machinery and watchdogs
are **unchanged** by the pivot — they consume `NativeTrackedVideoEvent`, not
GL.

The interface is also already substitutable in tests:
`tests/native_video_consumer_test.mm:54` defines
`class FakeOutput final : public NativeTrackedVideoOutput`, and
`native_media_session_test.mm` / `native_tracked_video_arbiter_test.mm` use
the same contract. A new implementation inherits that coverage.

### Files that change

| # | File | Change | Est. |
|---|---|---|---|
| 1 | `src/platform/macos/native_layer_video_output.{hpp,mm}` (new) | Implements `NativeTrackedVideoOutput` over the chosen layer. Owns the sequence minting, capacity-one admission, exact-timing echo, terminal mailbox (lift the `QtGlRenderProgressState` seqlock, `qt_gl_video_item.mm:76-157`, which is presenter-agnostic). | large — the bulk of the work |
| 2 | `src/platform/macos/native_layer_host_view.{hpp,mm}` (new) | NSView + layer installed below Qt's view; geometry, videoGravity, visibility, fullscreen/Space handling. | medium |
| 3 | `src/platform/macos/native_media_session_system.mm:113-115` | Select layer output vs GL output. | ~20 lines |
| 4 | `src/platform/macos/native_video_consumer.hpp:95-117` | Surface-budget `static_assert` must absorb the layer's retention depth (§4). | small but load-bearing |
| 5 | `src/qt/main.cpp:442` + `src/qt/mpv_video_item.cpp:115` | The GL item must still exist for the libmpv fallback; the native path stops creating/uses it as a geometry-only placeholder. | medium |
| 6 | `src/qt/player_controller.cpp:1449-1464` | Stop the 30 Hz `positionChanged()` from dirtying the scene while chrome is hidden (§2). Without this the pivot's headline win does not materialise. | small, mandatory |
| 7 | `qml/Main.qml:743-758` | `MpvVideo` becomes a transparent hole on the native route. | small |
| 8 | `tests/native_layer_video_output_test.mm` (new) | Contract conformance, modelled on `tests/native_qt_gl_output_test.mm`. | medium |
| 9 | `src/platform/macos/native_tracked_video_output.hpp:65-70` | The prose defining `FrameDrawn` as "its real Qt render pass completed" must be restated in presenter-neutral terms. | doc only |

**The decoder needs no change.** `VideoToolboxDecoder` already requests
IOSurface-backed, Metal-compatible output unconditionally
(`video_toolbox_decoder.mm:2123-2126`):

```objc
    CFDictionarySetValue(imageAttributes, kCVPixelBufferIOSurfacePropertiesKey, emptyIOSurfaceProperties);
    CFDictionarySetValue(imageAttributes, kCVPixelBufferMetalCompatibilityKey, kCFBooleanTrue);
```

IOSurface backing is the *one* hard, documented requirement ASBDL places on
CVPixelBuffer-wrapped sample buffers
([HEADER] `AVSampleBufferDisplayLayer.h:133-135`), and it is already
satisfied. The only decoder-adjacent edit is that
`VideoToolboxOutputInterop::OpenGL` stops being requested on the native route
(`video_toolbox_decoder.mm:2127-2132`), which merely drops one compatibility
flag.

Not changed: `native_video_consumer.*`, `native_tracked_video_arbiter.*`,
`native_media_session.*`, `native_playback_owner.*`,
`native_benchmark_telemetry.*`, `native_playback_contract.hpp`, the preview
lane, the decoder, both sample factories, the audio path.

### Reusable scaffolding already in the tree

- `src/platform/macos/metal_layer_presenter.{hpp,mm}` (972 lines) — a working
  `CAMetalLayer` presenter with `attachToView(void* NSView)`, `resize`,
  `setVisible`, `present(const FrameLease&)` returning
  `MetalPresentResult{Presented, Backpressure, DrawableUnavailable, Failed}`.
  It emits no draw proof today, but it is route (b) already built.
- `MetalTextureCache` / `MetalFrameLease` — `native_video_presenter.hpp:86-146`.
- `QtGlRenderProgressState` seqlock — `qt_gl_video_item.mm:76-157`.

---

## 8. Risks and fallback

### Fallback plan

The GL path stays. It is not deleted in Phase B:

- `NativeQtGlOutput` remains a full implementation of
  `NativeTrackedVideoOutput`; the layer output is a sibling, selected at the
  single factory site (`native_media_session_system.mm:113-115`).
- Selection is both **build-time** (`WAM_ENABLE_LAYER_PRESENTATION`) and
  **runtime** (env override, mirroring the existing
  `WAM_NATIVE_BENCHMARK_TELEMETRY` pattern), so a field problem is a relaunch
  away from the known-good path rather than a rebuild.
- The libmpv fallback route is untouched and still needs Qt on OpenGL
  (`src/qt/main.cpp:442`), which is an independent reason the GL scene graph
  cannot be removed anyway.

### Risks, worst first

1. **Qt does not actually go idle.** If the 30 Hz `positionChanged()` churn
   (§2) keeps the scene graph dirty, the process keeps issuing render passes,
   the AGX pool is never reclaimed, and the pivot buys little. *Mitigation:*
   measure render-pass count with chrome hidden as the very first Phase B
   task; gate position publication on chrome visibility. *Severity:* high,
   *tractability:* high. This is the single item that most determines whether
   Phase B is worth starting.

2. ~~**The "optimized compositing" fast path is conditional.**~~
   **DOWNGRADED — measured.** An overlay above the video does take the counter
   to zero, but costs this process nothing: zero GPU time, no pool, unchanged
   footprint, zero drops (see §6). The counter tracks a *system* direct
   scan-out path, and losing it moves compositing to WindowServer, out of
   process. *Residual risk:* a modest machine-wide power cost while chrome is
   visible, which the 3 s auto-hide bounds. *Mitigation:* publish the counter
   as a power-efficiency health metric, not as a guard on the memory
   objective.

3. **`AVVideoPerformanceMetrics` is `[SPI]`-tagged on every property** in the
   shipping public header. It is the only source of drop truth, and it may be
   restricted or changed. *Mitigation:* the proof stream must remain valid
   without it; use it as an audit, never as the proof itself.

4. **Surface budget overrun.** The renderer retains enqueued frames; headroom
   is 2 of 10 surfaces (§4). If retention exceeds that, the decoder starts
   emitting budget-denial tombstones — which will look like a decode fault,
   not a presentation one. *Mitigation:* measure retention (§6), then encode
   it in the `static_assert` so the failure is a compile error rather than a
   field symptom.

5. **Environmental behaviour is a documentation void.** Nothing citable
   describes ASBDL behaviour across occlusion, display sleep, Space changes,
   fullscreen transitions, or mixed-refresh external displays. *Mitigation:*
   this is exactly what the existing benchmark/stress harness is for; treat
   each as a live acceptance test in Phase B rather than a design assumption.

6. **Added presentation latency.** The moonlight-qt project moved off ASBDL to
   a Metal renderer specifically because ASBDL appeared to buffer extra frames
   on macOS [COMMUNITY]. WAM is not latency-critical the way game streaming
   is, but A/V sync is: there is already a known 45 ms edit-list offset item in
   the queue, and this must not compound it. *Mitigation:* measure A/V sync
   after integration; `totalAccumulatedFrameDelay` gives a direct read.

7. **Deprecated-API drift.** The queue-management category is already
   deprecated; targeting `sampleBufferRenderer` from the start avoids taking
   on debt at birth.

## 9. What Phase A did not settle

Listed so Phase B starts from an honest inventory rather than rediscovering
these.

| # | Open question | Why it matters | Cost to settle |
|---|---|---|---|
| 1 | Does Qt actually stop rendering when the chrome is hidden, given the 30 Hz `positionChanged()` churn? | **Determines whether the pivot delivers.** If Qt keeps the scene graph dirty, the pool never goes away. | Low — instrument render passes on the current build, no presenter needed |
| 2 | `copyDisplayedPixelBuffer` degradation under repeated pause/resume — stale attestation, or a truthfully-reported renderer stall? | Seek *is* repeated pause/resume. Blocks using it as the commit-seek proof (not the pivot). | Low — re-test with `setRate:time:` resume |
| 3 | The overlay / optimized-compositing discrepancy (0 % vs 100 % across two builds) | Machine power only; process cost is unaffected either way | Low — A/B on one build |
| 4 | Behaviour across minimise, Space change, fullscreen transition, display sleep, mixed-refresh external displays | Undocumented by Apple (§8 risk 5); occlusion is measured, these are not | Medium — live acceptance tests |
| 5 | Clean cost numbers on a quiet machine | All CPU figures here were taken under load average 23–58 | Low — re-run when the disk is not full |
| 6 | HEVC and 10-bit (P010) cross-check | Only H.264 8-bit was exercised | Low — same harness, different clip |
| 7 | A/V sync after integration | ASBDL may add presentation latency [COMMUNITY]; there is already a known 45 ms edit-list offset item | Medium — needs integration |

None of items 2–7 gates the go/no-go. **Item 1 does**, and it should be
answered before any presenter code is written.

### What would make me abandon the pivot

If the prototype shows ASBDL decoded-mode still allocating an AGX render-pass
pool and drawing meaningful GPU time, the memory and CPU case collapses and
only the occlusion-deadlock fix (§5) remains — which is real but not worth a
presentation rewrite on its own.
