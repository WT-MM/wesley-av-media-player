# macOS 13.3 media closure qualification — round 3, 2026-09-23

The media closure targets **macOS 13.3**, including BSD-licensed Opus for WebM.
Both macOS H.264 preferences use VideoToolbox with software encoding allowed;
libx264 is only requested on non-Apple builds. The native pipeline, decode
ladder, hot path, and frozen contract/test files were not changed. No network
or Git index/history operations were used.

The maintainer has separately measured the pinned installer Qt 6.11.1
(clang_64) frameworks in the v0.4.34 bundle on this machine: minos **13.0**.
That resolves the installer Qt concern from the previous report. Local
Homebrew Qt remains unsuitable for a 13.3 release and is still expected to
fail the floor gate; it is not substituted for the installer Qt proof.

## Source build

Host: Apple silicon, macOS 26.3.1 (25D771280a); Apple Clang 21, macOS SDK 26.5.
The round-3 offline recipe run took **190 seconds with four build jobs**, entirely
inside the execution sandbox. Its log is `proofs/closure-round3.log` under
`/private/tmp/wam-media-scratch`. The rebuilt prefix is
`/private/tmp/wam-media-scratch/media-closure`; the older repository-local
closure is not used for this round's build, exports or bundle.

| Source | Version | Purpose |
| --- | --- | --- |
| FreeType | 2.13.3 | libass font rasterization |
| FriBidi | 1.0.16 | subtitle bidirectional text |
| HarfBuzz | 11.3.2 | subtitle shaping |
| libass | 0.17.4 | subtitle rendering, CoreText font provider |
| libvpx | 1.17.0 | native VP8 and FFmpeg VP8/VP9 |
| Opus | 1.5.2 | BSD-licensed WebM audio encoder |
| FFmpeg | 9.0.1 | fallback codecs, containers, filters and export tools |
| mpv | 0.36.0 | OpenGL render API, client API 2.1 |

Every archive was verified before extraction against
`third_party/media-source/SHA256SUMS`. The exact source hashes are:

```text
cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635  ffmpeg-9.0.1.tar.xz
0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289  freetype-2.13.3.tar.xz
1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c  fribidi-1.0.16.tar.xz
d58ada9b2d28821245e8bdb8b94a4e2dad01a08c50d57feb027b32e84c9abfb1  harfbuzz-11.3.2.tar.xz
78f1179b838d025e9c26e8fef33f8092f65611444ffa1bfc0cfac6a33511a05a  libass-0.17.4.tar.xz
1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a  libvpx-1.17.0.tar.gz
29abc44f8ebee013bb2f9fe14d80b30db19b534c679056e4851ceadf5a5e8bf6  mpv-0.36.0.tar.gz
65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1  opus-1.5.2.tar.gz
```

`/private/tmp/wam-media-scratch/media-closure/share/wam-media/build-receipt.txt` records source,
recipe and patch hashes, toolchain, duration and installed Mach-O hashes.
`machos.tsv` measures every installed Mach-O (symlinks excluded):

| Installed file | Architecture | Measured minos |
| --- | --- | --- |
| `bin/ffmpeg` | arm64 | 13.3 |
| `bin/ffprobe` | arm64 | 13.3 |
| `lib/libass.9.dylib` | arm64 | 13.3 |
| `lib/libavcodec.63.1.101.dylib` | arm64 | 13.3 |
| `lib/libavdevice.63.1.101.dylib` | arm64 | 13.3 |
| `lib/libavfilter.12.1.101.dylib` | arm64 | 13.3 |
| `lib/libavformat.63.1.101.dylib` | arm64 | 13.3 |
| `lib/libavutil.61.1.101.dylib` | arm64 | 13.3 |
| `lib/libfreetype.6.dylib` | arm64 | 13.3 |
| `lib/libfribidi.0.dylib` | arm64 | 13.3 |
| `lib/libharfbuzz-subset.0.dylib` | arm64 | 13.3 |
| `lib/libharfbuzz.0.dylib` | arm64 | 13.3 |
| `lib/libmpv.2.dylib` | arm64 | 13.3 |
| `lib/libopus.0.dylib` | arm64 | 13.3 |
| `lib/libswresample.7.1.101.dylib` | arm64 | 13.3 |
| `lib/libswscale.10.1.101.dylib` | arm64 | 13.3 |
| `lib/libvpx.12.dylib` | arm64 | 13.3 |

All 17 images require exactly 13.3. The audit also rejected dependency paths
outside the closure prefix or system directories. Absolute prefix install IDs
are intentional: the bundler resolves them and rewrites the copied closure.
libvpx's upstream bare install ID is repaired before FFmpeg/mpv link against it.
All media package build trees are deleted after installation.

Round 2 failed because sandbox-denied `sysctl kern.argmax` left libtool's
`max_cmd_len` empty (`proofs/opus-sandbox-sysctl-failure.log`). The recipe now
exports `lt_cv_sys_max_cmd_len=262144` and explicitly passes it to **every
autotools configure** (libass and Opus). Both generated libtool scripts are
grepped for `max_cmd_len=262144` before linking. Retained evidence is
`share/wam-media/{libass-0.17.4,opus-1.5.2}-libtool-max-cmd-len.txt`;
`opus-1.5.2.log` records the cached configure result, successful shared-library
link and installation. No sandbox escape or retry loop was used. The updated
receipt records the cache value, recipe hash and all 17 installed image hashes.

The recipe's `nm` check verifies all 24 symbols listed by WAM's
`src/playback/mpv/mpv_api.cpp`; a direct call returns client API 2.1. Evidence:
`share/wam-media/mpv-symbols.txt` and `mpv-api.txt`. FFmpeg's configuration is
LGPL (GPL, version3, nonfree and autodetection disabled), with its built-in
codec/container/parser/filter sets, libvpx, libopus, VideoToolbox, AudioToolbox,
SecureTransport and zlib enabled; ffmpeg and ffprobe are built. Evidence:
`share/wam-media/ffmpeg-buildconf.txt`, `config.h`, `config_components.h`, and
`proofs/round3-ffmpeg-encoders.txt`, and
`proofs/ffmpeg-{decoders,muxers,filters}-round3.txt`. Raw `otool -l` output is
in `proofs/closure-otool-round3.txt` under that scratch root.

mpv 0.36 predates FFmpeg 9. The recipe applies
`scripts/media-patches/mpv-0.36-ffmpeg9.patch`: Objective-C compiler setup with
Swift disabled, AV_PROFILE names, codec supported-configuration queries,
codec context destruction/recreation, const write callbacks, AVStream side
data migration and the channel-layout option enum. This patch changes only
the extracted dependency source. mpv is libmpv-only, LGPL, with libplacebo,
Lua, JavaScript, VapourSynth, rubberband, libbluray, libarchive and other
optional host packages disabled. The required GL/Cocoa/CoreAudio paths are on.

## WAM and tests

Build directory: `/private/tmp/wam-media-scratch/build`.
`CMAKE_PREFIX_PATH` contains the closure and local Qt; `PKG_CONFIG_PATH` and
`PKG_CONFIG_LIBDIR` contain only the closure's pkg-config directory. The cache
confirms mpv headers/test linkage and libvpx resolve there. Configuration:

```text
CMAKE_BUILD_TYPE=Release
CMAKE_OSX_DEPLOYMENT_TARGET=13.3
WAM_ENABLE_MACOS_NATIVE_VIDEO=ON
WAM_ENABLE_SOFTWARE_VP8=ON
WAM_ENABLE_AVFORMAT_STAGE=ON
WAM_ENABLE_AVCODEC_STAGE=OFF
BUILD_TESTING=ON
WAM_NATIVE_BENCHMARK_TELEMETRY=ON
WAM_DEV_FFMPEG_EXECUTABLE=<closure>/bin/ffmpeg
```

The separate, existing WAM-patched native FFmpeg SDK remains in
`third_party/ffmpeg-lgpl`. GPL fixture generation uses the existing Homebrew
test tool; **export tests use the rebuilt closure's ffmpeg and ffprobe** via
`WAM_EXPORT_FFMPEG_EXECUTABLE` and `WAM_EXPORT_FFPROBE_EXECUTABLE`.
Cached pkg-config results were cleared; mpv headers/test linkage and libvpx
resolve to the rebuilt scratch closure. The full build used `--parallel 4`.
A WAMKit packaging invocation initially misparsed an otool header as a library
path; a single retry succeeded without source changes. Evidence:
`proofs/{configure-round3,build-round3,build-round3-retry}.log`.

**Round 3: 107/131 tests passed; 24 failed**, 58.28 seconds with `ctest -j4`,
entirely inside the sandbox. Evidence: `proofs/ctest-round3.log`,
`ctest-round3.xml`, `ctest-round3-exit.txt`. This supersedes the prior round's
130/130 result, which was obtained outside the sandbox and is historical only.
The failures include VideoToolbox session creation (-12908 encode, -12911
decode), unavailable AudioToolbox components, IOSurface allocation, Qt with no
accessible screens/XPC services, and Swift's nested sandbox denial. Some tests
only report downstream assertion failures; this run does not establish that
all 24 are environmental rather than regressions. No native code was changed
to suppress or bypass them. The full failed-test list is in the log and XML.

To honor the scratch and sandbox constraints, generated CTest invocations use
scratch-local Python adapters for hard-coded temporary directories. Swift uses
a scratch-local package, four jobs, and retains sandboxing (the existing
helper's `--disable-sandbox` was removed in the scratch copy). That test fails
with `sandbox-exec: sandbox_apply: Operation not permitted`; no escape was
attempted. Harness evidence: `proofs/ctest-harness-round3.json`,
`run_python_test_round3.py`, `build_wamkit_swift_round3.py` under the scratch
root. These adapters do not change test assertions. The final export-test
change was rebuilt and the three affected CTests rerun in
`proofs/export-final-round3.log`.

## Bundle

Stage: `/private/tmp/wam-media-scratch/stage/WAM.app`.
Round 3 installed the rebuilt app into this local stage. Homebrew Qt's
macdeployqt repeatedly reported dangling QML plugins; that install attempt
was interrupted, then the existing `fix_qt_qml_deploy_macos.zsh` completed
successfully. Apple's tools were first in PATH. Evidence:
`proofs/install-round3.log`, `proofs/qt-repair-round3.log`.

The bundler was run with **`WAM_MACOS_RELEASE_FLOOR=13.3`**, explicit rebuilt
scratch-closure ffmpeg/libmpv paths, and the existing scratch caption CLI/model.
**It failed as expected:** local Homebrew
`PlugIns/platforminputcontexts/libqtvirtualkeyboardplugin.dylib` requires
**macOS 26.0**, exceeding 13.3. The transaction rejected replacement of the
local stage. Evidence: `proofs/bundle-floor-13.3-round3.log` and
`bundle-floor-13.3-round3-exit.txt`. The gate was not relaxed and no development
bundle without the floor was produced in round 3. This stage is not a
qualified release artifact; no new signature/runtime-verification pass is
claimed after the rejected transaction.

Homebrew QtCore's previous measured minos is 14.0. The pinned installer
Qt 6.11.1 frameworks were separately measured by the maintainer at **13.0**
in v0.4.34, resolving that dependency concern. The release workflow retains
the actual bundled-slice floor gate.

The caption runtime was reused without downloads or launching the installed
app. Its existing proof records whisper minos 13.3, CLI SHA-256
`895f431ce3f8eda4e2fffb95e2264c726ecd4fad172e56da4d19ea21be61cd82`,
and pinned model SHA-256
`a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002`.
Evidence: `proofs/whisper-otool.txt`, `whisper-hashes.txt`, `model-verify.log`.

The earlier round's development-only bundle audit (148 Mach-O images,
maximum minos/LSMinimumSystemVersion 26.0, no Homebrew load paths,
ad-hoc signature/runtime verification) is retained in
`proofs/{bundle-local.log,bundle-audit.json,bundle-otool.txt,codesign.log,verify-runtime.log}`.
Those historical passes must not be attributed to the round-3 stage.

## Playback and export

The playback/render measurements below are retained from round 1; they were
not rerun in round 3 and do not qualify the newly rebuilt stage.

Every app replay used a fresh scratch HOME and hardlinked asset path, an
identity-bound lowercase UUID and SHA-256 values, background/muted seams,
`480x270+2400+1000`, and an eight-second quit timer. Only launched child PIDs
were controlled. The staged executable SHA-256 was
`680ad5d71adc9c84e9dc67d58a8553d84b15ab9e788755c500a3fe5cef34bc66`.
The reproducible local runner is `/private/tmp/wam-media-scratch/replay.py`.

Both synthesized ten-second MPEG-4 ASP/AVI and WMV2/WMV files selected the
bundled fallback and exited normally. Audio was synthesized as silence.
Evidence: `proofs/fallback/{0,1}/{log.txt,metrics.jsonl,environment.json,result.json}`,
`proofs/fallback/results.json`, and `proofs/fallback-assets.sha256`.

The requested positive fallback `drawn_frames` metric is **unavailable by
current design**: `NativePlaybackOwner::samplePlaybackMetrics` emits null
counters when there is no native session. No replacement/estimated count was
invented, and the prohibited playback code was not modified. For an additional
real-render proof, a headless CGL probe loaded the **staged**
`WAMMpvFallback.dylib`, rendered into an FBO and read back changing pixels:

| Bundled-engine asset | Rendered frames | Pixel changes | Final media time |
| --- | --- | --- | --- |
| MPEG-4 ASP / AVI | 30 | 28 | 1.066667 s |
| WMV2 / WMV | 30 | 28 | 1.043000 s |

Evidence: `proofs/render-results.json` and `proofs/render-fallback-*.log`.
Probe source: `/private/tmp/wam-media-scratch/render-probe.c`; executable:
`build/render-host/MacOS/media-render-probe` under the scratch root. This proves
real rendering by the bundled engine; it does not substitute for a WAM window
frame counter. mpv 0.36 also logs harmless unsupported newer optional UI/script
settings from WAM; those features are disabled in this build.

All seven requested native replays passed, without fallback:

| Asset | Drawn frames | Sampled clock rate |
| --- | --- | --- |
| `outgoing_175981962_20260127121923093_display0_h265.mp4` | 19 | 1.0000 |
| `outgoing_175981962_20260208203414622_display0_h265.mp4` | 208 | 1.0000 |
| `outgoing_175981962_20260208205646393_display0_h265.mp4` | 219 | 1.0000 |
| `outgoing_175981962_20260208210701843_display0_h265.mp4` | 191 | 1.0000 |
| `outgoing_175981962_20260208215604603_display0_h265.mp4` | 187 | 1.0000 |
| `outgoing_175981962_20260208220322285_display0_h265.mp4` | 198 | 1.0000 |
| `appleads.mp4` | 234 | 1.0000 |

Full per-run identities, raw telemetry and metrics:
`proofs/native/{0..6}/{log.txt,metrics.jsonl,environment.json,result.json}` and
`proofs/native/results.json` under `/private/tmp/wam-media-scratch`.

Round-3 export proofs use the actual `wam_export_integration_test` and the
rebuilt **closure** ffmpeg/ffprobe. The all-presets path now attempts every
preset independently, so one unavailable platform encoder cannot prevent
WebM/GIF coverage; `--preset=NAME` also permits an isolated proof. Failures
remain failures and produce a nonzero exit status.

| Export path | Round-3 result |
| --- | --- |
| WebmVp9 | **PASS**: VP9 + Opus, 2.066 s; isolated test exit 0 |
| Gif | **PASS**: GIF, 2.000 s; isolated test exit 0 |
| Mp4Hevc | FAIL: VideoToolbox compression session -12908 |
| MkvCopy re-encode | FAIL: VideoToolbox compression session -12908 |
| Mp4H264, software preference | FAIL: VideoToolbox compression session -12908 |
| Mp4H264, hardware preference | FAIL: VideoToolbox compression session -12908 |

The duration target is 2.0 ± 0.12 seconds. WebM evidence:
`proofs/webm-round3.log`, `webm-round3-exit.txt`; GIF evidence is
`proofs/gif-round3.log`, `gif-round3-exit.txt`. Every preset and the original
transaction/duration test are recorded in `proofs/export-final-round3.log`.
The latter cannot reach its duration assertion because VideoToolbox fails at
encoder creation. This is **not an all-presets pass**. The prior round's
hardware export success belongs to the earlier, unsandboxed execution context.

CTest `jobs` **passes** the runnable Apple regression guard: both H.264
preferences must produce the expected `h264_videotoolbox -allow_sw 1` argv and
must not request libx264. Encoder inventory confirms libopus and libvpx-vp9,
with no libx264. `-allow_sw 1` permits software encoding; it does not prove that
VideoToolbox selected software for any particular encode.

## Release workflow and deferrals

`release.yml` retains macos-15 and Qt 6.11.1's installer. Homebrew installs build
tools only. The media cache key covers the recipe, compatibility patch, mpv
API requirements, manifest; a cache miss fetches the pinned archives, verifies them, and builds.
CMake gets closure prefix/pkg-config paths and an explicit development ffmpeg;
the bundler gets explicit ffmpeg and libmpv paths. The native demux SDK cache
is retained. `WAM_MACOS_RELEASE_FLOOR=13.3` now enforces the requested floor.
The complete diff is saved locally as `proofs/release-workflow.diff`.

`build.yml` is unchanged: macos-15 still supports its Homebrew development
bottles, CMake obtains libvpx and mpv headers through pkg-config, and its
existing fixtures require libx264/libx265/libopus. It is not a 13.3 release
qualification lane. The new release workflow was syntax-checked, not remotely
executed (network prohibited).

Before shipping:

1. Complete the fallback frame-counter telemetry design and its measured
   WAM-window proof. Existing native counters cannot report fallback frames;
   the standalone render probe is not a substitute for that metric.
2. Run qualification on a real macOS 13.3 machine, including regression
   coverage of the mpv/FFmpeg compatibility patch beyond the two fallback
   samples. Deployment load commands do not prove every SDK API's behavior
   on that OS. This also requires a passing full CTest run and successful
   HEVC, MKV re-encode and both H.264 export preferences: round 3 could not
   obtain those proofs under the mandated sandbox (24/131 tests failed).
   The local Homebrew-Qt stage remains non-release; installer Qt 6.11.1
   minos 13.0 is already resolved by the maintainer's measurement.

Scratch contains the complete evidence and rebuilt closure. Package build
trees and the obsolete Opus inspection tree were removed after installation.
All working-tree changes remain uncommitted and unstaged.
