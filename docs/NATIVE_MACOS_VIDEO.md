# Native macOS video path

WAM has a dormant macOS playback foundation built around AVFoundation,
VideoToolbox, IOSurface, and Metal. The code is excluded unless
`WAM_ENABLE_MACOS_NATIVE_VIDEO=ON`. A second option,
`WAM_ENABLE_MACOS_NATIVE_VIDEO_ACTIVATION=ON`, production-compiles the reviewed
coordinator, action runner, session, and Qt OpenGL output together. It still
constructs no PlayerController owner and begins no native attempt, so libmpv
remains the only runtime path. Both options default to `OFF`.

Enable the isolated foundation with:

```sh
cmake -S . -B build-native \
  -DWAM_ENABLE_MACOS_NATIVE_VIDEO=ON \
  -DBUILD_TESTING=ON
cmake --build build-native \
  --target wam wam_native_video_test wam_video_toolbox_decoder_test \
           wam_native_video_pipeline_test \
           wam_native_qt_metal_compositor_test
ctest --test-dir build-native \
  -R 'macos_(native_video|native_video_pipeline|video_toolbox_decoder|native_qt_metal_compositor)' \
  --output-on-failure
```

To compile the dormant production activation seam as well, add
`-DWAM_ENABLE_MACOS_NATIVE_VIDEO_ACTIVATION=ON`. This currently verifies the
component boundary only; it does not change playback selection or register a
second QML video item.

## What exists now

- `FrameLease` retains a `CVPixelBufferRef` and its timeline generation without
  copying pixel memory. Generations make stale post-seek frames rejectable.
- `MetalTextureCache` owns a `CVMetalTextureCacheRef` and imports
  IOSurface-backed BGRA, NV12, and P010 frames as one or two Metal texture
  views. It explicitly rejects non-IOSurface frames instead of hiding a CPU
  copy.
- `MetalFrameLease` keeps both the CoreVideo frame and its texture views alive
  through command encoding.
- `QtMetalVideoItem` is an isolated, non-shipping Qt Quick composition gate. It
  wraps the original IOSurface's NV12/P010 planes on Qt's exact Metal device,
  converts them in one offline-compiled shader pass, and preserves QML z-order
  without a full-frame intermediate. Hardware tests cover non-neutral BT.601
  and BT.709 pixels, full/video range, P010 normalization, chroma siting,
  opacity, two simultaneous items, bounded Qt frame-slot retention, paused
  scene-graph recreation, window migration, and complete resource retirement.
  Unsupported color metadata fails closed. Embedded standard and batchable
  metallibs are inspected at build time to enforce WAM's macOS 13 floor.
- `MetalLayerPresenter` is a standalone component probe. It imports those plane
  views into a two-drawable `CAMetalLayer`, performs one NV12/P010-to-BGRA Metal
  pass (including center/left chroma siting), and retains each lease through GPU
  completion. The display-link callback only coalesces work onto a serial
  presentation queue; it never blocks in `nextDrawable`. Asynchronous command-
  buffer errors are surfaced outside presenter locks. GPU teardown waits at
  most 250 ms off-main and never waits on the AppKit thread; layer removal is
  handed asynchronously to AppKit when necessary.
- `VideoToolboxDecoder` accepts H.264 `avcC` and HEVC `hvcC` format
  configurations plus length-prefixed compressed access units. It creates
  hardware-preferred or hardware-required sessions, admits work against a hard
  in-flight limit before copying packet bytes, caps configuration/access-unit
  inputs at 1 MiB/32 MiB, and requires actual IOSurface output to exactly match
  its requested NV12 or P010 format. The generic presenter can still import BGRA,
  but the bounded decode pipeline does not accept a BGRA substitution.
- Decode requests asynchronous VideoToolbox operation without temporal
  processing; Apple permits temporal mode to retain frames indefinitely before
  end of stream, which is incompatible with finite admission. Callback results
  are normalized by submission sequence, and admission credits remain charged
  until contiguous retirement so out-of-order callbacks cannot bypass the
  memory bound. Strict H.264/HEVC SPS parsing takes a conservative maximum
  presentation reorder depth across the configuration record, PTS output is
  sorted within that declared bound, and streams requiring more than eight
  retained presentation frames are rejected by the dormant native attempt. A
  production runtime selector and atomic fallback are not wired yet.
  Deterministic legal callback-order, completion-gap, B-frame, and pre-EOS
  liveness tests cover the current contract.
- Decoder, frame-sink, and presenter interfaces establish ownership,
  backpressure, flush, and end-of-stream behavior without coupling the demuxer
  to VideoToolbox.
- `BoundedFrameQueue` is the concrete decode-to-display handoff. It rejects
  over-capacity and stale-generation frames, and releases flushed decoder
  surfaces outside its lock. Full-resolution frames therefore have a hard
  application-level bound even if presentation falls behind.
- VideoToolbox submission has its own hard in-flight bound. Seek flush advances
  the generation before draining callbacks, invalidates the codec session, and
  requires a new key frame. The decoder's low-level `close()` still waits for
  Apple callbacks, but `NativeVideoPipeline` moves the decoder and its sink as
  one ownership unit to a private serial retirement queue before calling it.
  `stop()`, `detach()`, and frontend destruction therefore never join the demux
  worker, drain a dispatch queue, call `cancelReading`, or wait for VideoToolbox
  on their caller. A retired sink remains alive until `close()` completes, and
  final source/display-link destruction occurs only after every producer is
  stopped and the presentation queue is drained.
- `NativeVideoPipeline` uses `AVAssetReaderTrackOutput` with nil output settings
  and `alwaysCopiesSampleData=NO`, so AVFoundation supplies the original
  length-prefixed compressed access units. It keeps one compressed sample at a
  time, feeds the hardware-required decoder, and exposes a cheap clock update
  boundary intended for a future authoritative audio clock. Asynchronous
  decode/presentation failures atomically deactivate the attempt and latch a
  message for `takeLastError()`; the pipeline never invokes arbitrary client
  code from demux, decode, render, or post-destruction stacks. Each frontend has
  exactly one retirement slot, and a process-wide admission lease allows only
  one native attempt to prepare, run, or retire. Constructing fresh frontends
  therefore cannot accumulate stuck VideoToolbox sessions. Once
  `stats().stopping` clears, the same frontend can prepare a fresh generation.
  Destruction upgrades an already queued normal stop to final shutdown without
  racing the retirement task's transition back to idle.
- Container suffixes are routing hints only. MP4/M4V/MOV use the current
  AVFoundation compressed-sample route; AVI and MPEG transport streams are
  probe candidates whose actual contents still must pass every AVFoundation,
  codec, hardware, color, and memory gate. MKV/Matroska, WebM, Ogg, and FLV are
  modeled as requiring a future external compressed-sample demux bridge and
  remain on libmpv today. This fail-closed suffix gate can conservatively send
  renamed but otherwise readable media to libmpv; no suffix can make media
  eligible without passing the content, demux, and codec gates. The codec
  gate separately accepts only 4:2:0 H.264/HEVC with matching 8-bit
  components, plus exact 10-bit 4:2:0 HEVC; VP9, AV1, ProRes, 12-bit, 4:2:2,
  and 4:4:4 remain unsupported by this native path.
- `prepareLocalFileAsync()` performs no AVFoundation property access or
  filesystem inspection on its caller. An accepted request is moved to a
  private serial preparation queue, loads the asset's `playable`,
  `hasProtectedContent`, `duration`, and `tracks` keys asynchronously, verifies
  every key reached `Loaded`, then asynchronously loads and verifies the chosen
  track's `formatDescriptions` and `preferredTransform` before calling any
  getter. Before publishing `Ready`, it also creates a throwaway
  `AVAssetReaderTrackOutput` with nil settings and synchronously extracts one
  bounded expected-codec compressed sample on that private queue. This proves
  more than playability, but it does not yet prove length-prefixed NAL framing
  or complete decode/presentation. Start and the first accepted draw remain the
  authoritative native-activation proof. The probe reader is confined to the
  preparation queue; stop is observed after a synchronous sample copy returns,
  and the process-wide admission lease bounds a wedged importer to one attempt.
  `takePrepareResult()` consumes exactly one terminal
  `Ready`, `Unsupported`, or `Failed` outcome; only `Ready` carries the exact
  nonzero decoded-frame generation. Callers must consume it before a
  new request can be admitted, so results cannot be overwritten or accumulate.
  No client callback can run from an AVFoundation, decode, teardown, or post-
  destruction stack. Stop/destruction logically cancels the request and asks
  AVFoundation to cancel loading from the preparation queue. If a framework
  load is already in flight, the process-wide admission lease remains held
  until its completion acknowledges cancellation, bounding even a wedged load
  to one self-owned attempt.
- macOS CI generates a deterministic H.264 stream with B frames, compiles the
  default-off native targets, and checks real decode order, returned timing,
  actual pixel format, IOSurface backing, and Metal plane import.

The isolated pipeline accepts only readable local, unprotected files with one
progressive SDR H.264/HEVC video track, at least one audio track, one stable
format description, BT.709 primaries/transfer with a BT.709 or BT.601 matrix
(or absent metadata under the current SD/HD inference), square pixels, an uncropped
aperture, identity rotation, and at most 2,073,600 coded pixels (the current
1920x1080 surface budget). It rejects
video-only/silent media because no independent video master clock exists yet,
and rejects embedded subtitle, text, or closed-caption tracks because no native
compositor exists. It also rejects a seek requiring more than 12 seconds of
hidden key-frame preroll instead of unexpectedly decoding a long file from zero.
Network media, containers that cannot yield AVFoundation compressed samples,
other codecs, multi-video media, interlacing,
HDR/PQ/HLG, Dolby Vision, ICC/log/gamma/wide-gamut metadata, alpha, unsupported
chroma siting, rotation, non-square pixels, and cropped apertures remain on
libmpv.

There is no production runtime selector. A real Qt-window experiment inserted
the `CAMetalLayer` beneath Qt's host layer but produced a blank playing surface,
so that composition design is explicitly rejected for activation. Subtitles,
generated captions, mpv OSD, and controls also need a proven compositor before
native video may suppress libmpv video.

## Why this is the CPU and memory path

The intended steady-state route is:

```text
compressed packet
  -> VideoToolbox hardware decoder
  -> IOSurface-backed CVPixelBuffer
  -> CVMetalTexture plane views
  -> Metal YCbCr/color shader
  -> drawable
```

There is no CPU pixel readback, CPU format conversion, or full-resolution
intermediate texture between decode output and Metal. The decoder rejects any
actual output format other than its requested NV12/P010 choice, so BGRA cannot
silently invalidate this pipeline calculation. The current hard bounds
are three queued frames, two submitted VideoToolbox frames, eight reorder
leases, two pipeline scheduling leases, and two GPU submissions. At the 1080p
eligibility ceiling, the standalone presenter also caps its drawable raster at
1920x1080 even on a larger/Retina host. Those 17 decoded leases plus two BGRA
drawables account for about 66 MiB with NV12 or 117 MiB with P010. Decoder
admission can additionally retain two compressed sample copies of up to 32 MiB
each, and a non-contiguous AVFoundation sample can require a transient 32 MiB
pipeline scratch buffer. Thus the directly bounded decoded/drawable/compressed
storage can approach roughly 162 MiB for NV12 or 213 MiB for P010 before the
AVFoundation-owned current sample. VideoToolbox's private pool and
framework/Qt/libmpv allocations are also additional, so this is not a complete
process-memory ceiling. Normal paused prebuffering stops at a queue high-water
mark of two.

The checked-in B-frame fixture exercises real hardware decode, a generation-
safe non-frame-aligned seek, video-only rejection, queue/in-flight bounds,
prompt return while asset loading is held, cancellation during held asset-key
loading, physical `cancelLoading` dispatch and admission retention until
callback acknowledgement, successful delayed loading, exception rollback after
partial resource transfer, stop during configured-but-uncommitted preparation,
destruction during held track-key loading, asynchronous detach/stop, restart after
retirement, process-wide contention, the normal-stop-to-final-destruction
upgrade, and active frontend destruction. Test-only background barriers and a
one-shot failure injection make the slow/cancel/destruction/rollback branches
deterministic without changing a production build. Those timings remain test
diagnostics only, not steady-state playback or comparative benchmark evidence.
No memory or performance improvement is claimed until complete WAM + framework
process measurements beat the controlled baseline.

## Integration sequence

1. Replace the rejected host-layer composition with an integrated Qt scene-
   graph Metal item: wrap the IOSurface-backed Y/UV `MTLTexture` planes through
   `QNativeInterface::QSGMetalTexture::fromNative`, retain their frame leases
   through GPU consumption, and convert/color in one offline-cross-compiled
   `qsb` `QSGMaterialShader` pass. This preserves QML z-order without a full-
   frame intermediate. The isolated gate invokes `qsb --metallib` through the
   exact Xcode Metal toolchain, propagates WAM's macOS 13 deployment floor, and
   inspects standard and batchable bytecode variants instead of trusting tool
   exit status. Create and prewarm the Metal pipeline once during media
   preparation. The current R/RG native-plane wrappers work under pinned Qt
   6.11.1 hardware tests but exceed Qt's documented RGBA-only native-texture
   contract, so both architectures must remain gated on pixel tests.
2. Resolve Qt's process-wide graphics API before selecting that path. The
   existing libmpv fallback requires OpenGL, so safe choices include startup
   preflight/relaunch, a fallback decoder that also feeds Metal, or a macOS-
   native shell. A per-file switch must not strand unsupported media.
3. Ensure eligible native media never initializes libmpv's OpenGL render
   context. The controlled headless probe attributed about 129.8 MB of settled
   live heap and roughly 406.6 MiB of transient unmapped graphics allocations
   to the current libmpv/OpenGL path; retaining it would erase much of the
   intended memory benefit. libmpv may still own demux/audio only after a
   matching file-load generation is authoritative.
4. Add subtitle/caption/OSD composition, track-selection parity, a video-only
   master clock, broader profile/level/chroma coverage, and full-sync/open-GOP
   seek validation. Asset and track inspection is now cancellable, asynchronous,
   generation-tagged, and safe to initiate from the UI thread; integration must
   poll and match its terminal result to the still-current file-load generation
   before committing selection or fallback.
5. Gate rollout on CPU, peak/current footprint, energy, seek latency, dropped
   frames, A/V drift, HDR/color, subtitle, and sleep/wake tests.

Codec reimplementation is intentionally independent of this boundary. A custom
decoder can later implement `VideoDecodeBackend`; it should earn adoption with
bit-exact conformance, fuzzing, and corpus benchmarks rather than being required
to remove the current presentation overhead.
