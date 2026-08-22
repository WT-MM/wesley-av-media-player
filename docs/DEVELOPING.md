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
MKV, and WebM; Opus and (uniform-blocksize) Vorbis audio decode natively via
AudioToolbox, and VP8 decodes through an in-pipeline libvpx stage
(`WAM_ENABLE_SOFTWARE_VP8`, on when libvpx is present — release packaging
must carry libvpx in the pinned closure before enabling it in bundled
builds). Anything the native engine declines falls back seamlessly to
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
scripts/fix_qt_qml_deploy_macos.zsh stage/WAM.app qml
scripts/bundle_macos.zsh \
  stage/WAM.app \
  build/runtime/whisper-cli \
  build/runtime/models/ggml-base.en.bin
```

The `fix_qt_qml_deploy_macos.zsh` step exists because Qt's CMake deployment
installs QML plugin binaries and `qmldir` files with `file(INSTALL)`, which
copies a symlink as a symlink — and Homebrew's `share/qt/qml` is entirely
symlinks into `../Cellar`. Without the repair, the staged app carries about a
hundred dangling links and no QML plugin code at all. The script materializes
them, lets `macdeployqt` finish the deployment those real files then require,
and normalizes any remaining absolute Homebrew reference onto the copy inside
the bundle. It is idempotent and a no-op on a Qt installation whose QML tree is
regular files, which is why `release-macos.yml`'s checksum-pinned Qt SDK never
needed it.

The two whisper scripts are all `build/WAM.app` needs for captions:

```sh
scripts/build_whisper.sh build/runtime/whisper-cli
scripts/fetch_whisper_model.sh build/runtime/models/ggml-base.en.bin
```

FFmpeg needs no script: the build stages it itself. If CMake finds an `ffmpeg`
at configure time (`/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`, then
`PATH`), it copies that binary to `build/runtime/ffmpeg` and re-copies it
whenever the copy goes missing or its source is newer. If no FFmpeg is
installed the build says so and carries on; only video export is affected. The
staged copy is the binary alone and still links its Homebrew/MacPorts dylibs by
absolute path, which is fine on the machine that installed them — building the
relocatable closure a shipped app needs is `scripts/bundle_macos.zsh`'s job.

`build/runtime` is a first-class search location, so captions and export both
work in the development app without bundling anything. WAM resolves every
external tool in one order, most trusted first: the runtime packaged in the app
(`Contents/Resources/tools`, `Contents/Resources/models`), the development
runtime in `build/runtime`, an explicit `WAM_FFMPEG` / `WAM_WHISPER_CLI` /
`WAM_WHISPER_MODEL` override, `/opt/homebrew/bin`, `/usr/local/bin`,
`/opt/local/bin`, and only then `PATH`. PATH comes last on purpose: a GUI
launch goes through LaunchServices and inherits only
`/usr/bin:/bin:/usr/sbin:/sbin`, so a PATH-only lookup cannot see a Homebrew
install and fails for every launch that did not come from a shell.

That local command produces an ad-hoc-signed package — the same kind of
artifact the shipping release path produces today.

`.github/workflows/release.yml` is that path. It triggers on a `v*` tag, builds
on a `macos-14` (Apple silicon) runner against Homebrew dependencies, caches
the checksum-pinned caption engine and model, runs the same
install/repair/bundle sequence as above, asserts that no Mach-O in the finished
app references a library outside the bundle, and publishes the ZIP and its
SHA-256 sidecar to a GitHub Release. The bundle is ad-hoc signed, so the
release notes carry the first-launch instruction (right-click → Open, or
`xattr -d com.apple.quarantine`) and `spctl --assess` rejects the app by
design.

`.github/workflows/release-macos.yml` remains the aspirational path:
a protected `macos-release` environment, checksum-pinned dependencies built for
macOS 13.3, Developer ID signing, Apple notarization, ticket stapling, and a
Gatekeeper assessment. None of the secrets it needs exist yet, so it is
dormant. When a Developer ID certificate and notary key are available it
supersedes `release.yml`; until then it should not be expected to run.

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

Every number above is a **1080p** measurement, and stays one. The native
admission envelope was raised to 4096x2320 on 2026-08-21, so 4K content now
takes the native route and carries proportionally larger decoded surfaces —
every player pays this. Measured on the same machine with the same quiet seams,
`footprint` on the default CALayer route, 3840x2160 HEVC against a matched
1920x1080 HEVC encode of the same source: app footprint 65 MB vs 56 MB, and the
IOSurface reservation 123.4 MB vs 36.5 MB virtual (9.9 MB vs 8.1 MB resident —
the CPU never touches decoded pixels on this route). The AGX render-target pool
is unchanged at 2.4 MB, because the layer route still issues zero render passes
at 4K; the scene-graph route pays 226 MB of it at the same window size.

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
  delays cumulative. See **Quiet launch seams** below for `WAM_TEST_BACKGROUND`,
  `WAM_TEST_GEOMETRY` and `WAM_TEST_MUTED`.
- `benchmarks/macos/player_resource_trial.py` — cross-player resource trials
  (CPU/GPU/memory/energy) with parked-window geometry.
- `benchmarks/macos/stress_load.py` — calibrated CPU/GPU load generators for
  robustness-under-contention runs.
- `benchmarks/matroska_demuxer_bench.cpp` — multi-size regime benchmark for
  the demuxer (built with the `benchmark` label, excluded from default builds).

### Quiet launch seams

Two seams exist so an automated verification round does not take over the
machine it runs on. Both are gated exactly like the other `WAM_TEST_*` seams —
parsed only when `WAM_NATIVE_BENCHMARK_TELEMETRY` is enabled *and* the three
prefixed identity vars validate — so a shipping launch can never observe them.
Truthy values are the telemetry opt-in's own vocabulary (`1`, `true`, `yes`,
`on`, and upper-case forms); anything else, junk included, is off.

- `WAM_TEST_BACKGROUND=1` — launches without ever becoming the frontmost
  application. Two mechanisms, both needed: `main.cpp` sets
  `QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM` before `QGuiApplication`
  (that is the Qt cocoa plugin's own guard on the
  `-[NSApplication activateIgnoringOtherApps:YES]` it performs "to avoid
  launching behind the terminal"), then drops the process to
  `NSApplicationActivationPolicyAccessory` and resigns activation from an
  `NSApplicationDidBecomeActive` observer. The observer is not belt-and-braces:
  measured, the policy change alone let about one launch in two through. The
  app also leaves the Dock and menu bar, which for a test instance is a
  feature.

  **The window stays on screen and composited, deliberately.** An accessory
  app's `makeKeyAndOrderFront:` orders the window only within its own app, so
  it lands wherever the active app's windows leave it — measured at z-index 18
  of 44 on-screen windows, fully covered. That is the occlusion counterfeit
  this document warns about two paragraphs down, so the seam also calls
  `-orderFrontRegardless` and parks the window at `NSFloatingWindowLevel`,
  where no ordinary application window can bury it mid-measurement.

- `WAM_TEST_GEOMETRY="WxH+X+Y"` — parks the window at an exact logical
  rectangle (minimum 64x64), re-applied on the next event-loop pass and again
  at 400 ms so QML's own sizing cannot overwrite it. Needed in practice
  *because* the background seam floats the window above ordinary windows:
  leaving a full-size always-on-top window on someone's screen is not quiet.
  Requires no pointer, no System Events, and no accessibility grant.

- `WAM_TEST_MUTED=1` — silent hardware output with measurement untouched.
  `NativeAudioOutput::render` zeroes the sample buffer *after* the render core
  has filled it and before returning, so callback cadence, every counter, the
  stream frame cursor, the audio-authoritative clock, the underrun/refill wake
  edges and the `OutputIsSilence` flag are all exactly what an unmuted callback
  produces. The gate is snapshotted into a `const bool` at construction, so the
  render callback reads a plain bool and an unmuted process pays one
  never-taken branch. Asserted at the AudioUnit boundary by
  `tests/native_audio_output_test.mm`
  (`testMutedOutputZeroesSamplesAndNothingElse`), which checks both halves:
  samples zero, counters identical to the unmuted control.

  Rejected: the output unit's volume parameter (a device-graph parameter whose
  per-callback cost this code does not control, so "provably does not alter
  callback timing" cannot be claimed); `PlayerController::setVolume(0)` (changes
  the samples the render core produces, and is *persisted* — a muted test run
  would silently zero the user's saved volume); and flagging every callback
  `kAudioUnitRenderAction_OutputIsSilence` (a hint the HAL may act on, and
  `render()` already uses that flag to report a genuinely all-silent slice,
  which a mute must not counterfeit).

**Frontmost still matters for some arms.** These seams are for correctness
rounds — "does playback work, does the seek land, did the window draw" — where
nothing is being claimed about scheduling. Arms that measure compositor health
under kill-priming, or anything whose claim depends on the window getting the
scheduling a foreground app gets, still need a real frontmost launch:
`run_suite.py` asserts frontmost outright for those. Do not reach for
`WAM_TEST_BACKGROUND` to make such an arm quieter; it would change the thing
being measured.

Measurement discipline that has actually mattered here: hold launch/priming
discipline constant across arms; keep the display awake (an occluded or
sleeping window counterfeits starvation); treat fixture-green as necessary but
not sufficient (verify against real encoder output); and when a regression
appears, suspect the instrument first.

One more that cost a session: give each measured run its **own path** to the
asset. The state store keys saved positions by path and auto-resume replays
anything past 5 s, so a second run of the same filename starts mid-clip and can
reach EOF inside the measurement window — which reads as a session that stopped
for no reason. A hardlink under a fresh name is enough.

## Contract surfaces

`tests/native_audio_converter_test.mm`, `tests/native_audio_session_test.*`,
and `src/media/native_media_source.hpp` are frozen contracts — do not modify
them; write new tests alongside instead.
