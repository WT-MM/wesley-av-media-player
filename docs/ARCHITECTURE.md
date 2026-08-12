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

`PlayerController` is the QML-facing state/command facade. A small `PlayerCore`
lifetime wrapper exists at launch, but it does not create or initialize libmpv
until the first valid media request. The render context is then created only
when Qt's render thread has a current OpenGL context. An always-live
`MpvVideoItem` completes that handshake before the newest pending `loadfile`
command is released.

Render contexts carry generation tickets. Qt scene-graph teardown invalidates a
ticket before freeing libmpv's context; stale command replies and file events
cannot commit against a replacement generation. WAM retains the authoritative
open request through asynchronous loading. For ordinary A/V media it restores
the exact numeric video track after the replacement renderer is ready, keeping
the existing demuxer, audio, selected tracks, and generated/external subtitles
alive. Video-only or not-yet-stable loads use a guarded full reload that
re-attaches WAM-owned subtitles and restores track selections, position, and
pause before accepting a matching post-reply `PLAYBACK_RESTART`. Redirected
playlist children are tracked by their inserted entry lineage. Stop and newer
opens invalidate all older intent without making the render thread wait on
normal libmpv calls.

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
`WAM_ENABLE_MACOS_NATIVE_VIDEO=ON`. The stricter
`WAM_ENABLE_MACOS_NATIVE_VIDEO_ACTIVATION=ON` option can also compile the
coordinator/session/QtGL activation seam as production code, but no shipping
controller constructs or begins it and the normal libmpv path is unchanged.
The current standalone
`CAMetalLayer` presenter is a component probe, not a qualified Qt compositor.
An isolated `QtMetalVideoItem` gate instead imports the original IOSurface
planes on Qt's Metal device and converts them inside the Qt scene graph, so QML
z-order is preserved without a full-frame intermediate. It is hardware-tested
for color, frame-slot lifetime, scene-graph recreation, and window migration,
but remains a test-only Metal gate; the production-compile seam uses the
separately reviewed Qt OpenGL item and still registers neither item.
Pipeline stop, detach, and destruction transfer their demux/VideoToolbox drain
to a self-owned background retirement slot, so the AppKit thread never joins
those producers. A process-wide admission lease permits at most one native
attempt to prepare, run, or retire; frontend churn therefore cannot accumulate
stuck AVFoundation/VideoToolbox sessions. Asset and track keys load on a private
serial queue; the caller only starts work and polls one generation-tagged
terminal result, so no Apple callback can invoke client code after destruction.
Runtime activation remains blocked on connecting the native pipeline to a Qt
render node, an authoritative audio clock, atomic libmpv fallback, subtitle
behavior, and full-sync/open-GOP seek coverage.
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

Automated coverage includes playback policy and state parsing, process-tree job
cancellation, caption success/failure/cancellation/cleanup, lazy libmpv startup,
render-generation and controller recovery races, and an actual FFmpeg duration
assertion for a trimmed 2× export. The opt-in macOS native build additionally
exercises VideoToolbox decode ordering, IOSurface/Metal import, Qt scene-graph
color/composition/lifetime behavior, and pipeline lifecycle on supported
hardware.
