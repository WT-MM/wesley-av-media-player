# Architecture

## Product shell

WAM's shipping UI is Qt Quick/QML. Qt supplies native windows, dialogs,
accessibility, text shaping, high-DPI behavior, focus, and a retained GPU scene
graph. WAM custom-draws only its compact media transport and editor styling.
Light is the default; appearance is persisted as Light, Dark, or System.

Dear ImGui was intentionally retired from the shipping shell. It is fast and
excellent for tools and diagnostics, but WAM would otherwise need to hand-build
consumer-grade accessibility, platform behavior, typography, focus, and input.

## Playback path

`PlayerController` is the QML-facing state/command facade. `PlayerCore` owns the
libmpv client and initializes the libmpv render context only when Qt's render
thread has a current OpenGL context. An always-live `MpvVideoItem` completes
that handshake before a pending `loadfile` command is released.

`MpvVideoItem` injects libmpv rendering through a `QSGRenderNode` directly into
Qt Quick's active full-window target. QML overlays render afterward. This avoids
the full-size texture and composite pass imposed by `QQuickFramebufferObject`,
which Qt now documents as a legacy integration API. Hardware interop remains a
libmpv/driver decision; WAM does not claim every codec/platform path is zero-copy.

libmpv's public high-performance render API currently exposes OpenGL rather than
Metal, Direct3D, or Vulkan targets, so the first Qt release forces Qt Quick to
OpenGL on all platforms. A later native presenter can preserve the QML shell
while importing Metal/D3D/Vulkan images from an FFmpeg/libplacebo boundary.

The default-off macOS experiment lives in
`src/platform/macos/native_video_presenter.*`,
`src/platform/macos/video_toolbox_decoder.*`,
`src/platform/macos/metal_layer_presenter.*`, and
`src/platform/macos/native_video_pipeline.*`. It provides retained
`CVPixelBuffer` frame leases, zero-copy IOSurface-to-Metal plane views, a hard-
bounded decode/presentation handoff, H.264/HEVC VideoToolbox sessions, and
generation-based seek invalidation. It is compiled only with
`WAM_ENABLE_MACOS_NATIVE_VIDEO=ON`; no shipping controller or render node can
select it, and the normal libmpv path is unchanged. The current standalone
`CAMetalLayer` presenter is a component probe, not a qualified Qt compositor.
Runtime activation is also blocked on asynchronous AVAsset key loading,
codec-derived presentation reordering, and off-UI VideoToolbox teardown.
See `docs/NATIVE_MACOS_VIDEO.md` for scope and rollout gates.

## Editing and captions

Edits are descriptions, never mutations of the source. Quick Edit records trim
points, playback/export rate, and pitch policy. `BackgroundJob` launches an
FFmpeg export outside the UI/render threads and terminates the complete process
tree on cancellation.

`CaptionService` extracts mono 16 kHz PCM, invokes whisper.cpp directly, reports
stages, supports cancellation, rejects empty output, atomically replaces stale
SRTs, and always cleans temporary audio. A successful SRT is attached to the
active player and enabled. Caption inference defaults to the reliable CPU path;
platform GPU inference remains opt-in until watchdog-safe.

## State and wakeups

libmpv wake callbacks queue event draining onto the Qt GUI thread. Render update
callbacks coalesce `QQuickItem::update()` requests. When playback, control fade,
export, and captions are inactive, no recurring UI/render timer should remain.
StateStore persists appearance, volume, and local-file resume positions.

## Distribution

Qt deployment runs first. Platform packages then add mpv/FFmpeg dependencies,
FFmpeg CLI, a statically built whisper CLI, and the pinned model. The macOS
bundler preserves Qt frameworks/QML/plugins, rewrites only WAM's media closure,
audits all Mach-O paths, and signs inside-out. Windows deploys Qt/QML before
copying media DLL graphs. Linux packages Qt imports/plugins and the tool/model
payload in an AppImage.

## Performance gates

- Paused/end-of-file CPU and wakeup frequency
- Active CPU/GPU, resident memory, and energy at 1×, 2×, and 4×
- Cold/warm open and random-seek latency
- 4K60 H.264, HEVC, VP9, and AV1 dropped frames and A/V drift
- HDR/color/subtitle correctness on each renderer path
- Export throughput, cancellation, and caption real-time factor
- 1×/2× visual, keyboard, VoiceOver/Narrator/Orca, and clean-machine package tests

Automated coverage currently includes state parsing, job cancellation, caption
success/failure/cancellation/cleanup, and an actual FFmpeg duration assertion
for a trimmed 2× export.
