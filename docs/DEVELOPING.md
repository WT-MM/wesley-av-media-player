# Developing WAM

Everything build-, benchmark-, and release-related lives here; the
[README](../README.md) is the product page.

## Architecture in one paragraph

WAM is a Qt Quick shell. On macOS, playback runs on a native engine:
AVFoundation demux (plus a custom Matroska demuxer for MKV) feeds VideoToolbox
hardware decode, an audio-authoritative clock built on exact rational
arithmetic drives scheduling, and decoded frames are handed to an
`AVSampleBufferDisplayLayer` that WindowServer composites beneath the Qt-drawn
chrome — so during steady playback the app issues zero GPU render passes of
its own. H.264, HEVC (8/10-bit), VP9, and AV1 play natively across MP4, MOV,
and MKV. Anything the native engine declines falls back seamlessly to
libmpv/FFmpeg, which also provides playback on other platforms, broad
container/subtitle/network-stream support, background exports, and — via
whisper.cpp — private, on-device captions. Deeper reading:
[ARCHITECTURE.md](ARCHITECTURE.md), [PRODUCT.md](PRODUCT.md),
[QT_QUICK_MIGRATION.md](QT_QUICK_MIGRATION.md),
[AGENT_PERFORMANCE_PRINCIPLES.md](AGENT_PERFORMANCE_PRINCIPLES.md).

The presentation route is runtime-selectable: the CALayer presenter is the
default; `WAM_PRESENTATION=scenegraph` opts back to the Qt OpenGL route with a
relaunch. The GL route remains a full implementation but retires most
post-seek frames late; the CALayer route is both cheaper and more correct.

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

## Performance policy

1. Playback never round-trips frames through an application-owned CPU buffer.
2. The Qt shell is retained and event-driven; no UI polling loop runs while the
   player is paused or its fade is finished.
3. On the default macOS route, video never enters the Qt scene graph at all:
   decoded frames go straight to a WindowServer-composited layer, and the
   scene graph renders only when chrome is visible.
4. Hardware decode is preferred only when the platform decoder considers the
   path safe.
5. Export and caption work run off the UI/render threads and support bounded
   process-tree cancellation.
6. Persistent blur, full-screen UI layers, and perpetual animation are excluded
   unless measurements justify them.
7. CPU, GPU, memory, power, startup, seek latency, and dropped frames are release
   gates—not assumptions derived from a toolkit choice.

## Measured performance

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

A later same-session paired comparison (absolute levels shift with ambient
load between sessions, so only paired arms are claims) removed a per-frame
pixel-transfer pass the decode session had been forcing on the CALayer route:
coalition CPU fell 18% (to below QuickTime's same-session measurement), energy
fell 18% to a tie with QuickTime, and the decoder helper's memory halved to
27.9 MB — half of QuickTime's own helper. The decoder service now runs the
same threads doing the same work as QuickTime's.

Against VLC 3.0.21 an earlier campaign on the same machine measured WAM at 37%
less CPU and 27% less energy — with the caveat that VLC ships x86_64-only and
runs under Rosetta 2 on this hardware, so part of that gap is translation
overhead rather than engineering; and that campaign predates the CALayer
presentation route, which widened WAM's side of the margin further.

## Benchmarks and harnesses

- `benchmarks/macos/run_suite.py` — telemetry-driven playback suite. Telemetry
  and its test seams require `WAM_NATIVE_BENCHMARK_TELEMETRY=1` plus the
  PREFIXED identity vars `WAM_NATIVE_BENCHMARK_RUN_ID` (lowercase 8-4-4-4-12
  hex), `WAM_NATIVE_BENCHMARK_ASSET_SHA256` and
  `WAM_NATIVE_BENCHMARK_CANDIDATE_ID` (lowercase 64-hex). The bare names
  (`RUN_ID`, …) are never read, and `uuidgen` emits uppercase — either mistake
  silently disables the channel and every `WAM_TEST_*` seam with it.
  `WAM_TEST_REOPEN_SCRIPT` entries are `delayMs@path`, comma-separated,
  delays cumulative.
- `benchmarks/macos/player_resource_trial.py` — cross-player resource trials
  (CPU/GPU/memory/energy) with parked-window geometry.
- `benchmarks/macos/stress_load.py` — calibrated CPU/GPU load generators for
  robustness-under-contention runs.
- `benchmarks/matroska_demuxer_bench.cpp` — multi-size regime benchmark for
  the demuxer (built with the `benchmark` label, excluded from default builds).

Measurement discipline that has actually mattered here: hold launch/priming
discipline constant across arms; keep the display awake (an occluded or
sleeping window counterfeits starvation); treat fixture-green as necessary but
not sufficient (verify against real encoder output); and when a regression
appears, suspect the instrument first.

## Contract surfaces

`tests/native_audio_converter_test.mm`, `tests/native_audio_session_test.*`,
and `src/media/native_media_source.hpp` are frozen contracts — do not modify
them; write new tests alongside instead.
