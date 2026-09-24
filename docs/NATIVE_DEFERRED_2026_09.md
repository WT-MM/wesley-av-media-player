# Native deferred work — 2026-09-23

**Status: item 1 qualified; item 2 implemented with its zero-late proof still failing; items 3–5 not started.**

Worktree `/private/tmp/wam-native`, branch `native-deferred`. No commits or index operations; no network. Scratch/build/evidence root: `/private/tmp/wam-native-scratch`. Host dependency SDK reused read-only from `/Users/wesleymaa/Github/wesley-av-media-player/third_party/ffmpeg-lgpl`. This is a development build using Homebrew Qt/libvpx, not macOS 13.3 release qualification.

## Commands and environment

```sh
cmake -S /private/tmp/wam-native -B /private/tmp/wam-native-scratch/build -G Ninja \
  -DCMAKE_PREFIX_PATH=/opt/homebrew/opt/qt -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3 \
  -DWAM_FFMPEG_LGPL_ROOT=/Users/wesleymaa/Github/wesley-av-media-player/third_party/ffmpeg-lgpl \
  -DWAM_ENABLE_MACOS_NATIVE_VIDEO=ON -DWAM_ENABLE_AVFORMAT_STAGE=ON \
  -DWAM_ENABLE_AVCODEC_STAGE=OFF -DWAM_NATIVE_BENCHMARK_TELEMETRY=ON -DBUILD_TESTING=ON
cmake -S . -B /private/tmp/wam-native-scratch/build \
  -DWAM_AVFORMAT_FIXTURES=/private/tmp/wam-native-scratch/fixtures/phase3 \
  -DWAM_MIXED_FIXTURES=/private/tmp/wam-native-scratch/fixtures/phase2e
cmake --build /private/tmp/wam-native-scratch/build --parallel 4
```

Configure succeeded. First sandboxed build failed generating the HE-AAC `aac_at` WAMKit fixture (AudioToolbox unavailable). Automatic approval accepted the host-services build, which succeeded. Logs: `configure.log`, `configure-fixtures.log`, `build.log`, `build-host.log`, `build-amendment{,2,3,4}.log`. The incremental amendment builds succeeded after updating the Matroska test's local rotation record from integer to rational dimensions.

## 1. Amendment 27

The frozen headers have exactly the authorized field/empty-predicate replacements, plus the required include making `MediaRational` visible in `native_playback_contract.hpp`. Frozen audio tests are unchanged.

The exact aperture/SAR geometry supersedes rounded presentation hints for anamorphic sources. Prepared events carry both rationals. The Qt controller retains them separately from its `QSizeF` UI projection. Each native window retains the exact pair for aspect lock, fit and actual size; asynchronous AVFoundation answers cannot overwrite the current prepared geometry. CALayer retains the same rational pair and fits using bounded integer arithmetic. Rounding happens when producing physical pixel dimensions. Non-direct presenters retain the named anamorphic refusal.

No real anamorphic fixture was found in this clone. Synthesized fixture:

```sh
/opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i testsrc2=size=1920x1080:rate=30 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 -t 20 \
  -vf setsar=5127/4912:max=10000 -c:v libx264 -preset ultrafast \
  -threads 2 -pix_fmt yuv420p -c:a aac -b:a 128k \
  /private/tmp/wam-native-scratch/anamorphic.mp4
/opt/homebrew/bin/ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,sample_aspect_ratio,display_aspect_ratio,pix_fmt \
  -of json /private/tmp/wam-native-scratch/anamorphic.mp4
ctest --test-dir /private/tmp/wam-native-scratch/build \
  -R '^(native_rational_display|native_media_source|native_playback_contract|matroska_demuxer|mpegts_demuxer)$' \
  --output-on-failure
python3 scripts/native_deferred_proof.py \
  --asset /private/tmp/wam-native-scratch/anamorphic.mp4 \
  --output /private/tmp/wam-native-scratch/proofs/anamorphic-2
```

The filter's `max=10000` is necessary: ffmpeg's default SAR bound would approximate this fraction. ffprobe confirms 1920×1080, yuv420p, SAR 5127:4912, DAR 1709:921. Five targeted tests passed. The new Objective-C++ test asserts exact descriptor transport, all quarter-turn swaps, reduced aspect, CALayer's retained dimensions and actual layer bounds, the shared Qt/CALayer fit rectangle, and final physical-pixel projection.

Measured GUI runs (12 seconds each):

| Run | Gate load1 | Compiler/linkers | Drawn | Late discards | Audio underruns |
| --- | ---: | ---: | ---: | ---: | ---: |
| anamorphic-1 | 5.1318359375 | 0 | 353 | 0 | 0 |
| anamorphic-2 | 6.35400390625 | 0 | 354 | 0 | 0 |

Both exited 0 and retained `display.png`. The final seam reports `width=615240/307 height=1080/1 aspect=1709/921 actual_physical=2004x1080`. Actual-size width quantization is −12/307 pixels. At a 480-pixel fitting width, the exact height is 442080/1709 pixels, rounded to 259; a pixel capture does not represent the unquantized fraction. Each proof directory contains isolated HOME, a fresh hardlinked asset path, environment and identity hashes, raw metrics, gate log, app log and result JSON. The runner checks the compiler/linker inventory and one-minute load every 30 seconds before launch. All launches use the required background/mute/geometry seams and only this build's binary.

## Regression execution

```sh
TMPDIR=/private/tmp/wam-native-scratch/test-tmp \
WAM_TEST_SCRATCH=/private/tmp/wam-native-scratch/test-tmp \
ctest --test-dir /private/tmp/wam-native-scratch/build -LE benchmark --output-on-failure
```

The scratch-only `python-tests` adapter redirects tests' explicitly hardcoded temporary directory to this scratch root, without changing assertions. Generated CTest files use the adapter; the Swift build gets `--stage-package /private/tmp/wam-native-scratch/swift-package-source` to avoid writing the checkout's `build/`. The first full attempt started before `test-tmp` existed, causing temporary-directory failures; its failures are retained in `ctest-amendment.log` and are not a pass. A corrected full rerun follows.

## Remaining work

Item 1 has its exact rational and measured GUI proof. Item 2 counters are implemented, but its required zero-late full-session proof is not met: every measured fallback session reports one startup VO discard. Items 3–5 were not started because the requested strict order requires completing item 2's proof first. No software scheduling fix, sixteen-window storm pass, ASP/VP9 full-range qualification/error-direction result, or three-run longest-fixture late-frame result is claimed.

## Changed files

- `CMakeLists.txt`
- `docs/NATIVE_DEFERRED_2026_09.md`
- `scripts/native_deferred_proof.py`
- `src/media/native_display_geometry.hpp`
- `src/media/native_media_source.cpp`
- `src/media/native_media_source.hpp`
- `src/media/native_playback_contract.hpp`
- `src/platform/macos/avfoundation_media_source.mm`
- `src/platform/macos/native_embedding_support.hpp`
- `src/platform/macos/native_embedding_support.mm`
- `src/platform/macos/native_layer_host_view.hpp`
- `src/platform/macos/native_layer_host_view.mm`
- `src/platform/macos/native_layer_video_output.hpp`
- `src/platform/macos/native_layer_video_output.mm`
- `src/platform/macos/native_presentation_admission.hpp`
- `src/platform/macos/native_tracked_video_arbiter.mm`
- `src/platform/macos/native_tracked_video_output.hpp`
- `src/platform/macos/native_video_consumer.mm`
- `src/playback/mpv/frame_counters.hpp`
- `src/playback/mpv/mpv_api.cpp`
- `src/playback/mpv/mpv_api.hpp`
- `src/playback/mpv/mpv_runtime.cpp`
- `src/playback/mpv/mpv_runtime_linked.cpp`
- `src/qt/macos_window_chrome.hpp`
- `src/qt/macos_window_chrome.mm`
- `src/qt/main.cpp`
- `src/qt/native_playback_metrics.cpp`
- `src/qt/native_playback_metrics.hpp`
- `src/qt/native_playback_owner.mm`
- `src/qt/player_controller.cpp`
- `src/qt/player_controller.hpp`
- `src/qt/player_core.cpp`
- `src/qt/player_core_p.hpp`
- `src/qt/window_manager.cpp`
- `tests/fakes/mpv_runtime/fake_mpv.cpp`
- `tests/fakes/mpv_runtime/injected_mpv_runtime.hpp`
- `tests/matroska_demuxer_test.cpp`
- `tests/mpegts_demuxer_test.cpp`
- `tests/mpv_frame_counters_test.cpp`
- `tests/mpv_runtime_test.cpp`
- `tests/native_media_source_test.cpp`
- `tests/native_playback_contract_test.cpp`
- `tests/native_rational_display_test.mm`
- `tests/native_tracked_video_arbiter_test.mm`
- `tests/player_controller_lazy_test.cpp`

### Amendment validation follow-up

`ctest-amendment-rerun.log`: **134/134 passed**, 128.39 s. This build has 134 non-benchmark tests, rather than assuming the historical count of 130. An additional Qt controller assertion now verifies the retained fraction and shared aspect/fit/actual-size operations.

The second nominal-resolution capture showed 258 fully illuminated rows. This was not an exact physical-pixel proof: the capture downsamples Retina output. Inspection also found CALayer's automatic aspect fit and centered subpixel origin as additional geometry boundaries. The final correction uses `AVLayerVideoGravityResize` after exact fitting and aligns the origin to physical pixel edges. `layer-final-unit-host.log`: **3/3 passed**, including actual CALayer bounds/position. The sandboxed attempt could not allocate its test IOSurface; it is retained separately as `layer-final-unit.log` and is not claimed as passing.


The physical-resolution capture opt-in is `WAM_TEST_CAPTURE_PHYSICAL=1`; the default existing capture behavior stays nominal-resolution. Runs 4–6 captured 960×540 but still showed 518 picture rows. These were **not accepted as the final rational-layer proof**. Inspection found the missing `NativeTrackedVideoArbiter` forwarding method: the live output wrapper had inherited the base method instead of delivering the rational pair to CALayer. The fix forwards it, defaults unsupported fractional geometry to refusal, and adds an arbiter regression assertion. Capture telemetry now reads both the Qt controller's retained rational and the actual layer's retained rational/bounds/position/backing scale. All intermediate app runs had zero late discards and zero audio underruns; their retained results are diagnostic, not substitutes for the final layer proof.

### Item 1 accepted proof

Final command: `python3 scripts/native_deferred_proof.py --asset /private/tmp/wam-native-scratch/anamorphic.mp4 --output /private/tmp/wam-native-scratch/proofs/anamorphic-7`.

Gate: load1 **3.212890625**, zero compiler/linker processes. Exit **0**, **356 drawn**, **0 late discards**, **0 audio underrun callbacks**, **0 clock-advanced underruns**. Exact controller and live CALayer geometry both **615240/307 × 1080/1**; reduced aspect **1709/921**. Live layer bounds **480 × 258.5**, position **240,134.75**, scale **2**. Physical capture **960×540**, picture rows **12–528 inclusive = 517 pixels**, matching the exact 960 × 884160/1709 fit quantized to **960×517**. Fit-height rounding error **−607/1709 pixel**. `proofs/anamorphic-7/geometry.json` records the pixel measurement separately from rational metadata.

`geometry-final-unit.log`: **3/3 passed** (`player_controller_lazy`, `macos_native_tracked_video_arbiter`, `native_rational_display`). The earlier targeted geometry suite was **5/5**, and the full regression checkpoint was **134/134**. The final full regression below covers all subsequent changes. Intermediate builds/logs through `build-amendment12.log` retain the failed arbiter-test constructor compile and its correction; no failed attempt is counted as proof.

## 2. Fallback counters

Implementation complete; zero-late acceptance proof **not met**. `PlayerCore` counts only successful new-frame renders using `MPV_RENDER_PARAM_NEXT_FRAME_INFO`; redraws, repeats and render failures do not increment drawn counts. The fixed-size atomic counter adds no allocations to rendering and is active only when the metrics path is configured. File-start events reset the counter epoch under the existing render mutex. `mpv_render_context_get_info` is resolved/verified alongside the existing API table; lazy fallback loading stays intact.

The same `playback_sample` record now reports `backend=mpv`, real `drawn_frames`/`submitted_frames`, `discarded_late_frames` from mpv's `frame-drop-count`, and separate `decoder_discarded_frames` from `decoder-frame-drop-count`. Supersession and audio counters remain null when mpv does not expose the corresponding native facts. The counter is a successful new-video-frame GL render count, not an fps×time estimate. No claim of per-frame WindowServer scanout timestamps is made.

The development fallback dylib was copied locally into this build, not loaded from another WAM executable:

```sh
cp /opt/homebrew/opt/mpv/lib/libmpv.2.dylib \
  /private/tmp/wam-native-scratch/build/WAM.app/Contents/Frameworks/WAMMpvFallback.dylib
```

This is the host mpv development library, not a newly qualified pinned 13.3 closure. The native decode ladder and shipped codec-stage OFF setting are unchanged.

Fixture commands (all local, no downloads):

```sh
/opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=30 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 20 -c:v wmv2 -threads 1 -c:a wmav2 /private/tmp/wam-native-scratch/fallback.wmv
/opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=15 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 20 -c:v wmv2 -threads 1 -c:a wmav2 /private/tmp/wam-native-scratch/fallback-15fps.wmv
/opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -y -i /private/tmp/wam-native-scratch/fallback-15fps.wmv -map 0:v:0 -c copy /private/tmp/wam-native-scratch/fallback-video-only.wmv
/opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=1 -t 20 -c:v wmv2 -threads 1 /private/tmp/wam-native-scratch/fallback-1fps.wmv
/opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=30 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 20 -c:v mpeg4 -bf 2 -q:v 4 -threads 1 -c:a pcm_s16le /private/tmp/wam-native-scratch/fallback-asp.avi
```

An initial ASP fixture command used `-bf 0`; it was replaced with the command above before the measured ASP replay. The file's native refusal forces fallback without changing routing policy. Both WMV2 and ASP sessions produced retained WAM-window captures and `fallback_selected` identity-bound route records. Expected native refusal diagnostics on these specimens are not suppressed.

Each measured command is `python3 scripts/native_deferred_proof.py --asset /private/tmp/wam-native-scratch/ASSET --output /private/tmp/wam-native-scratch/proofs/RUN`, using the exact asset/run arguments in the table below. `fallback-5` additionally passed `--prime-paused`, issuing `pause:0@0,play:0@1500` before the ordinary capture/report script.

| Run | ASSET | Gate load1 | Drawn | VO late/discard count | Decoder discards |
| --- | --- | ---: | ---: | ---: | ---: |
| fallback-1 | fallback.wmv | 7.5703125 | 336 | 1 | 0 |
| fallback-2 | fallback-15fps.wmv | 5.91748046875 | 170 | 1 | 0 |
| fallback-3 | fallback-video-only.wmv | 7.57568359375 | 173 | 1 | 0 |
| fallback-4 | fallback-1fps.wmv | 4.3642578125 | 12 | 1 | 0 |
| fallback-5 | fallback.wmv | 3.44921875 | 314 | 1 | 0 |
| fallback-empty-trial | fallback.wmv | 2.3232421875 | 345 | 1 | 0 |
| fallback-asp | fallback-asp.avi | 2.46142578125 | 298 | 1 | 0 |

All compiler/linker gate inventories were empty at launch; all child apps exited 0. Audio underrun counts are **unavailable (null)** on fallback, not zero. Every first observed fallback sample already had VO discard count 1, and the count never increased afterward. Thus the observed interval has late-counter delta 0, but **the full session does not have zero cumulative late/discarded frames**. No offset, reset-after-startup, or drop-policy change was used to manufacture a zero.

The `fallback-empty-trial` temporarily skipped rendering an empty context before the first image. It did not remove the initial discard and was reverted by restoring the two saved PlayerCore files from scratch, then rebuilding (`build-fallback-trial-reverted.log`). Its code is not in the final diff. The cause of the single startup VO discard is unresolved; it is not established as an environmental limitation or proven harmless initialization bookkeeping.

`fallback-unit.log`: **4/4 passed**: controller, render-context ownership, widest telemetry JSON, and the new frame-counter test. The latter verifies rejection of redraw/repeat/failed renders and epoch reset. The proof runner now exits nonzero when the required zero-late condition is unmet and records `zero_late_proof`; historical result JSON was re-derived from retained raw samples so unavailable fields remain null.


Fallback dylib SHA-256: `f701babc6b30630ce0e59243dcafce6dc8d6380024c18c231da15b2ed524d162`. Complete run identities and candidate/asset hashes: `proofs/summary.json` in scratch. Frozen-contract equality checks: `frozen-check.json`, all true.


### Final regression command

```sh
TMPDIR=/private/tmp/wam-native-scratch/test-tmp WAM_TEST_SCRATCH=/private/tmp/wam-native-scratch/test-tmp ctest --test-dir /private/tmp/wam-native-scratch/build -LE benchmark --output-on-failure
```

`ctest-final.log` passed 134/135 tests: the dogfooding audit rejected a direct Qt include of the native layer host. The diagnostic now goes through `NativeEmbeddingSupport`, preserving the existing architectural boundary; the audit was not relaxed. `build-boundary-fix.log` records the successful rebuild. `ctest-final-rerun.log`: **135/135 passed, zero failures, 127.59 seconds**, including `wamkit_dogfooding`. The command redirected stdout/stderr with `> /private/tmp/wam-native-scratch/ctest-final-rerun.log 2>&1`. `git diff --check` also passed. The final boundary change only relocates the geometry diagnostic API; the accepted picture geometry and counter implementations are unchanged. The scratch adapter also gates each measured GUI launch inside the existing regression harness and logs `ctest-gate.jsonl`. The earlier full green checkpoint did not yet have per-launch gating inside that existing CTest harness; it is a regression checkpoint, not the accepted quiet-seam measurement proof. Direct item proofs always used the gate. No compiler/linker or other user's process was terminated.

Final inventory: **45 changed files** (including this report and six new files). Frozen header checks match the authorized replacements and required include; frozen audio tests remain byte-identical. No changes implement items 3–5.
