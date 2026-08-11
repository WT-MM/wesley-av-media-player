# Native macOS video path

WAM has a compile-tested foundation for a native macOS playback path built
around VideoToolbox, IOSurface, and Metal. It is deliberately default-off and
does not replace or modify the shipping libmpv renderer yet.

Enable the isolated foundation with:

```sh
cmake -S . -B build-native \
  -DWAM_ENABLE_MACOS_NATIVE_VIDEO=ON \
  -DBUILD_TESTING=ON
cmake --build build-native \
  --target wam_native_video_test wam_video_toolbox_decoder_test
ctest --test-dir build-native \
  -R 'macos_(native_video|video_toolbox_decoder)' --output-on-failure
```

## What exists now

- `FrameLease` retains a `CVPixelBufferRef` and its timeline generation without
  copying pixel memory. Generations make stale post-seek frames rejectable.
- `MetalTextureCache` owns a `CVMetalTextureCacheRef` and imports
  IOSurface-backed BGRA, NV12, and P010 frames as one or two Metal texture
  views. It explicitly rejects non-IOSurface frames instead of hiding a CPU
  copy.
- `MetalFrameLease` keeps both the CoreVideo frame and its texture views alive
  through command encoding.
- `VideoToolboxDecoder` accepts H.264 `avcC` and HEVC `hvcC` format
  configurations plus length-prefixed compressed access units. It creates
  hardware-preferred or hardware-required sessions, admits work against a hard
  in-flight limit before copying packet bytes, and requests only presenter-
  supported IOSurface/Metal NV12 or P010 output.
- Decode uses VideoToolbox temporal processing and its returned presentation
  timestamp/duration. A small bounded reorder stage converts B-frame callback
  order to monotonic display order and explicitly drains delayed frames at end
  of stream. Saturation is counted as an intentional drop/backpressure outcome,
  not a sticky fatal decoder error.
- Decoder, frame-sink, and presenter interfaces establish ownership,
  backpressure, flush, and end-of-stream behavior without coupling the demuxer
  to VideoToolbox.
- `BoundedFrameQueue` is the concrete decode-to-display handoff. It rejects
  over-capacity and stale-generation frames, and releases flushed decoder
  surfaces outside its lock. Full-resolution frames therefore have a hard
  application-level bound even if presentation falls behind.
- VideoToolbox submission has its own hard in-flight bound. Seek flush advances
  the generation before draining callbacks, invalidates the codec session, and
  requires a new key frame. Shutdown waits for all callbacks and invalidates the
  session before releasing either the sink or format description.
- macOS CI generates a deterministic H.264 stream with B frames, compiles the
  default-off native targets, and checks real decode order, returned timing,
  actual pixel format, IOSurface backing, and Metal plane import.

The isolated path now decodes real H.264 packets and validates HEVC session
configuration, but it does not yet own production demuxing, schedule frames to
an audio/display clock, run a YCbCr shader, composite subtitles, or present
through `CAMetalLayer`. It is therefore not yet a user-selectable playback
backend and should not be used for headline player benchmarks.

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

There is no CPU pixel readback, format conversion, or full-resolution
intermediate texture between decode output and Metal. A bounded presentation
queue (normally two or three frame leases) will prevent decoded frames from
accumulating. The renderer can allocate its small shader resources once and
reuse them, avoiding the large multipass OpenGL/libplacebo framebuffer graph
measured in the current path.

## Integration sequence

1. Add the production demux/audio-clock boundary that supplies `avcC`/`hvcC`
   configuration and length-prefixed access units to `VideoToolboxDecoder`.
2. Add a `CAMetalLayer` presenter implementing `VideoPresentationBackend`, a
   display-link clock, NV12/P010 color conversion, HDR metadata propagation,
   and explicit frame-drop policy.
3. Put demuxed H.264 and HEVC behind a runtime experiment switch. Preserve
   libmpv fallback for unsupported codecs, containers, subtitles, filters, and
   software decode.
4. Gate rollout on CPU, peak/current footprint, energy, seek latency, dropped
   frames, A/V drift, HDR/color, subtitle, and sleep/wake tests.

Codec reimplementation is intentionally independent of this boundary. A custom
decoder can later implement `VideoDecodeBackend`; it should earn adoption with
bit-exact conformance, fuzzing, and corpus benchmarks rather than being required
to remove the current presentation overhead.
