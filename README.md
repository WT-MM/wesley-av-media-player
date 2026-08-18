# WAM

**Wesley's Audiovisual Media Player** combines a minimal desktop player with
the lightweight editing tasks that usually require opening a separate editor.

WAM uses a Qt Quick shell. On macOS, playback runs on a native engine:
AVFoundation demux (plus a custom Matroska demuxer for MKV) feeds VideoToolbox
hardware decode, an audio-authoritative clock built on exact rational
arithmetic drives scheduling, and decoded frames are handed directly to an
`AVSampleBufferDisplayLayer` that WindowServer composites beneath the Qt-drawn
chrome — so during steady playback the app performs zero GPU render passes of
its own. H.264, HEVC (8/10-bit), VP9, and AV1 play natively across MP4, MOV,
and MKV. Anything the native engine declines falls back seamlessly to
libmpv/FFmpeg, which also provides playback on other platforms, broad
container/subtitle/network-stream support, background exports, and — via
whisper.cpp — private, on-device captions.

## Current product surface

- Edge-to-edge video under a QuickTime-style dark translucent title band and
  floating transport, both fading out while watching (with hover-pin), cursor
  hidden alongside
- Aspect-proportional window resize with exact snap; double-click the video or
  title bar to expand to the largest screen fit; optional "window hugs video"
  letterbox toggle
- Playback continues when the window is unfocused, occluded, or backgrounded,
  and the app stays open at end of video
- Local files, URLs, drag/drop, hardware decoding with safe software fallback,
  subtitles, audio-only media, and the formats supported by the packaged mpv/
  FFmpeg build
- Space play/pause, Left/Right seek with a configurable step, timeline
  scrubbing, volume, mute, fullscreen, caption visibility, and 0.25–4×
  playback; settings live in the native menu bar
- Pitch-preserved playback speed by default
- Closable Quick Edit sheet with IN/OUT trim, retimed MP4 export, caption
  generation, and appearance controls
- Cancellable local SRT generation; completed captions are verified, attached,
  and enabled
- Standalone macOS packaging and native Windows/Linux package workflows with
  Qt, mpv/FFmpeg, whisper.cpp, and the caption model included

The older ImGui prototype remains in `src/main.cpp` as migration reference but
is not part of the WAM 0.3.1 executable.

## Build on macOS

Requirements are CMake, Qt 6.9 or later, mpv, FFmpeg, and pkg-config. The release
workflow pins Qt 6.11.1.

```sh
brew install cmake ninja qt mpv ffmpeg pkg-config
cmake -S . -B build -G Ninja \
  -DCMAKE_PREFIX_PATH=/opt/homebrew/opt/qt \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3 \
  -DWAM_ENABLE_MACOS_NATIVE_VIDEO=ON \
  -DBUILD_TESTING=ON
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

The development app is `build/WAM.app`. Build the local caption runtime, install
Qt into a staging app, then add WAM's media dependencies:

```sh
scripts/build_whisper.sh build/runtime/whisper-cli
scripts/fetch_whisper_model.sh build/runtime/models/ggml-base.en.bin
cmake --install build --prefix stage
scripts/bundle_macos.zsh \
  stage/WAM.app \
  build/runtime/whisper-cli \
  build/runtime/models/ggml-base.en.bin
```

That local command produces an ad-hoc-signed development package. Public macOS
artifacts are built only by `.github/workflows/release-macos.yml`, which uses a
protected `macos-release` environment, checksum-pinned dependencies built for
macOS 13.3, Developer ID signing, Apple notarization, ticket stapling, and a
Gatekeeper assessment. The workflow publishes only the post-staple ZIP and its
SHA-256 sidecar. It never runs for pull requests.

The protected environment supplies checksum-pinned per-architecture Qt SDK and
media closure archives, the full Developer ID Application authority and team
ID, the base64 PKCS#12 certificate and password, App Store Connect notary key ID
and issuer ID, and the base64 notary API key. Release credentials are imported
into an ephemeral CI keychain and removed in an unconditional cleanup step;
they must not be placed in the repository or local build files.

## Controls

| Action | Control |
| --- | --- |
| Open media | Command/Ctrl+O, click the empty player, or drop a file |
| Play/pause | Space |
| Seek (configurable step) | Left/Right |
| Scrub | Timeline |
| Mute and volume | Transport controls |
| Cycle common speeds | `1×` transport control |
| Fit window to screen | Double-click video or title bar |
| Fullscreen | F |
| Quick Edit | E or pencil control |
| Close Quick Edit | Escape or close control |

## Performance policy

1. Playback never round-trips frames through an application-owned CPU buffer.
2. The Qt shell is retained and event-driven; no UI polling loop runs while the
   player is paused or its fade is finished.
3. Video draws into the current scene target, avoiding a 7.9 MiB 1080p or
   31.6 MiB 4K RGBA intermediate before driver buffering.
4. Hardware decode is preferred only when libmpv considers the path safe.
5. Export and caption work run off the UI/render threads and support bounded
   process-tree cancellation.
6. Persistent blur, full-screen UI layers, and perpetual animation are excluded
   unless measurements justify them.
7. CPU, GPU, memory, power, startup, seek latency, and dropped frames are release
   gates—not assumptions derived from a toolkit choice.

## Measured performance (macOS)

Measured 2026-08-18 on an Apple M3 Max (64 GB, macOS 26.3.1): 1080p30 H.264
playback, 60 s steady-state window, every player freshly launched with
identical discipline and parked at the same 640×360 window, machine idle and
display awake, playback health verified from telemetry (30.00 fps drawn, zero
late frames, clock rate 1.0000) for each arm.

| | WAM (default, CALayer) | WAM (`WAM_PRESENTATION=scenegraph`) | QuickTime Player |
| --- | --- | --- | --- |
| CPU, app + decoder services (mean) | **13.2%** | 17.7% | 13.3% |
| CPU, app process alone | **7.6%** | 13.1% | 10.5% |
| GPU (share of device) | **0.0000%** | 4.40% | 0.0000% |
| Energy impact (`top` POWER) | 10.3 | 13.4 | 9.8 |
| Memory, app-attributable | 140.6 MB | 138.5 MB | 111.2 MB |

On the default route the video layer is composited by WindowServer directly
from decoder output, so WAM issues zero GPU render passes during chrome-hidden
playback — the same property that makes QuickTime cheap — while WAM's own
process runs lighter than QuickTime's. The MKV repeat reproduces the table
(QuickTime cannot open Matroska at all). Seeks on the default route retire
zero late frames; playback holds 30 fps at clock 1.0000 while fully occluded
and under saturated CPU/GPU load. Warm open is 61 ms median, ≤ 73 ms p95.

Against VLC 3.0.21 an earlier campaign on the same machine measured WAM at 37%
less CPU and 27% less energy — with the caveat that VLC ships x86_64-only and
runs under Rosetta 2 on this hardware, so part of that gap is translation
overhead rather than engineering; and that campaign predates the CALayer
presentation route, which widened WAM's side of the margin further.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
[docs/PRODUCT.md](docs/PRODUCT.md), and
[docs/QT_QUICK_MIGRATION.md](docs/QT_QUICK_MIGRATION.md). The current measured
smoke baseline is recorded in [docs/PERFORMANCE.md](docs/PERFORMANCE.md).
