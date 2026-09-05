# Native macOS video path

WAM's shipping macOS playback path is native: AVFoundation, VideoToolbox,
IOSurface, and CoreAnimation, with libmpv as the compatibility fallback for
anything the native path refuses. It is built under
`WAM_ENABLE_MACOS_NATIVE_VIDEO`, which defaults to `ON` on Apple platforms
and is unavailable elsewhere.

## Components

- `src/media/` — platform-neutral contracts and demuxers. The frozen
  `native_media_source.hpp` states the source contract (amendments are
  append-only and recorded in the local session handoff ledger); WAM's own
  Matroska/WebM and MPEG-TS demuxers live beside it.
- `src/platform/macos/avfoundation_media_source.mm`,
  `matroska_media_source.mm`, `mpegts_media_source.mm` — the three container
  backends, each producing CoreMedia sample buffers on the movie timeline.
- `src/platform/macos/video_toolbox_decoder.mm` — VideoToolbox sessions
  (hardware H.264/HEVC/VP9/AV1/ProRes; software MPEG-2, MPEG-4 Part 2, MJPEG)
  plus the libvpx VP8 stage in `software_vp8_decoder.mm`.
- `src/platform/macos/native_video_presenter.*` and
  `native_surface_budget.*` — retained `CVPixelBuffer` frame leases and the
  process-wide surface budget every decoded frame is charged against.
- `src/platform/macos/native_media_session.mm` and the audio session — the
  audio-authoritative exact-rational clock, seek commit, and the dispatcher
  that routes samples between lanes.
- Presentation routes, both implementing `NativeTrackedVideoOutput`:
  `native_layer_video_output.mm` (default; an `AVSampleBufferDisplayLayer`
  composited by the WindowServer with no in-process render pass) and
  `native_qt_gl_output.mm` over `qt_gl_video_item.mm` (opt-in with
  `WAM_PRESENTATION=scenegraph`). The route decision lives in
  `native_layer_presentation_state.hpp`.

## Tests

The native suites run under `ctest` from the build directory. Fixture-backed
tests (`macos_video_toolbox_decoder` and the headless performance gate) need
`test-media/sample-h264.mp4` or the `WAM_NATIVE_VIDEO_TEST_FIXTURE` cache
variable; `WAM_NATIVE_VIDEO_10BIT_TEST_FIXTURE` adds real P010 decode
coverage. GUI-driving checks use the quiet launch seams described in
`docs/DEVELOPING.md`.
