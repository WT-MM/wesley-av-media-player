# Native deferred work — 2026-09-23

**Prior-round status is preserved below. The `native-deferred-2` follow-up and its current measurements are recorded at the end.**

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


## native-deferred-2 follow-up (2026-09-23)

This follow-up starts from the maintainer commits on `native-deferred-2`.
The previous numbered items above belong to `native-deferred`; the four items
below use the new request's numbering. No network or Git index/history writes.
The shipped codec-stage setting remains OFF. All generated files and logs are
under `/private/tmp/wam-native-scratch`; all GUI commands use this build's app,
isolated HOME, identity-bound telemetry and the existing background/mute/geometry
seams. Each runner logs its compiler/linker inventory and load gate, polling at
30-second intervals. No sibling workspace or process was changed.

### Follow-up 1: fallback startup discard

Cause: `handleOpenCommandReply` synchronously reads mpv's playlist/transport
metadata before the first video frame. The GUI thread waits on the mpv core;
the core waits on its VO; Qt needs the GUI thread to dispatch that first render.
The local libmpv trace proves a 200 ms render timeout, not a harmless pre-roll:
`mpv_render_context_render() not being called or stuck.` The first render occurs
after that timeout. Event tracing localized the GUI stall to COMMAND_REPLY
(event 5), before START_FILE (event 6) was drained. The same dylib's offline
symbolized disassembly identifies the timeout path calling
`vo_increment_drop_count`. No count offset or drop-policy change is justified.

Fix: retain a successful command reply in the existing bounded, identity-bound
OpenAttempt until PLAYBACK_RESTART. Handle either reply/restart ordering, and
retire a matching failed/empty open on END_FILE. Defer FILE_LOADED metadata,
display-size and subtitle reads until that completion. The render node consumes
startup frames without requiring `hasMedia`, since mpv publishes restart only
after presentation. Its old gate alone was not the cause: removing only that
gate still failed. No new polling, thread, render allocation, or counter reset
was added. Temporary trace instrumentation was removed.

Exact build/test commands (stdout/stderr redirected to the named scratch logs):

```sh
cmake --build /private/tmp/wam-native-scratch/build --parallel 4
# build-startup-trace.log: successful 559-step incremental rebuild
cmake --build /private/tmp/wam-native-scratch/build --target WAM --parallel 4
# build-startup-consume.log, build-startup-events.log, build-startup-defer.log
cmake --build /private/tmp/wam-native-scratch/build --target WAM wam_player_controller_lazy_test --parallel 4
# build-startup-final.log
cmake --build /private/tmp/wam-native-scratch/build --target wam_player_core_render_context_permission_test --parallel 4
# build-startup-render-test.log
ctest --test-dir /private/tmp/wam-native-scratch/build -R '^(player_controller_lazy|player_core_render_context_permission|mpv_frame_counters|native_playback_metrics)$' --output-on-failure
# startup-unit.log: 2 passed; offscreen GL test could not access sandboxed macOS services
ctest --test-dir /private/tmp/wam-native-scratch/build -R '^(player_controller_lazy|player_core_render_context_permission|mpv_frame_counters|native_playback_metrics_jsonl)$' --output-on-failure
# startup-unit-host.log: 3/3 passed, 0.45 s (neither metrics name matched a test)
```

The controller regression asserts both command-reply/first-frame event orders,
no premature metadata commit, retained playlist identity, and startup completion.
Host-services execution was automatically approved. The first sandboxed proof
attempt failed at `ps` before launching an app; it is not a GUI measurement.

Every proof command has this exact form:

```sh
python3 scripts/native_deferred_proof.py --asset /private/tmp/wam-native-scratch/ASSET --output /private/tmp/wam-native-scratch/proofs/RUN [OPTIONS]
```

| RUN | ASSET | OPTIONS | Gate load1 | Drawn | VO discards | Decoder discards |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| fallback-startup-trace-host | fallback.wmv | (none) | 6.3662109375 | 309 | 1 | 0 |
| fallback-startup-consume | fallback.wmv | (none) | 5.384765625 | 327 | 1 | 0 |
| fallback-startup-events | fallback.wmv | (none) | 3.5048828125 | 293 | 1 | 0 |
| fallback-startup-defer | fallback.wmv | (none) | 3.74267578125 | 324 | 0 | 0 |
| fallback-startup-final-wmv | fallback.wmv | --seconds 22 | 3.916015625 | 588 | 12 | 0 |
| fallback-startup-final-wmv-2 | fallback.wmv | --seconds 22 | 4.76025390625 | 600 | 0 | 0 |

All launch gates had zero compiler/linker processes; the trace-host gate first
waited for the build. All apps exited 0. The first final WMV run had **zero
startup drops**, then twelve drops between media times 2.843 and 3.843 seconds,
around capture and overlapping an offscreen graphics unit-test invocation. It
is retained as a failed all-session zero-drop proof; causality of those later
drops is not asserted. The isolated rerun played all **600 frames**, through EOF,
with **zero startup or later VO drops and zero decoder drops**. Its capture,
metrics, environment, hashes and result are retained in its proof directory.
The traced fixed run completed first-frame restart at 0.105 s without the timeout.

Fallback audio underruns remain **unavailable (null)**. The installed libmpv
0.41.0 manual exposes frame and decoder-drop counters, but no cumulative AO
underrun count. `demuxer-cache-state/underrun` is packet starvation, not an audio
output underrun count, and is not substituted. Audio clock advances in the A/V
trials; no zero-underrun claim is made for fallback.

Additional final-code item-1 proofs, using the same exact command form:

| RUN | ASSET | OPTIONS | Gate load1 | Drawn | VO discards | Decoder discards |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| fallback-startup-final-asp | fallback-asp.avi | --seconds 22 | 4.39697265625 | 600 | 0 | 0 |
| fallback-startup-final-paused | fallback.wmv | --prime-paused | 3.7822265625 | 349 | 0 | 0 |

Both exited 0 with captures and no compiler/linker at launch. ASP also completed
its entire 600-frame file. The paused-start script is the pre-existing
`pause:0@0,play:0@1500` sequence; this is not a claim that the window remained
paused for the whole trial. Follow-up item 1 is accepted before starting item 2.

### Follow-up 2: bounded software preview scheduling

The software preview handoff had flushed then immediately reopened the playback
worker, retaining all sixteen slots. It now suspends that software worker during
preview, keeps the same-generation sink/output lineage, and resumes at the
existing key-frame/commit boundary. Other decoder implementations retain their
existing flush behavior. A suspended decoder reports quiescence rather than a
false drain failure. Its awaiting-key-frame fact now describes its actual state.

The libavcodec admission path has a fixed FIFO of 32 waiting configurations
(two waves of the sixteen-worker ceiling). Waiting configurations create no
threads or packet/conversion workspaces. The unchanged sixteen-worker and
process-byte limits apply when a FIFO entry starts. Readiness uses the existing
wake callback; no UI polling is added. Closing a queued decoder removes its
identity before any admission can start it; closing a running decoder joins it
and retires its byte reservation before admitting the next entry. A full queue
still refuses with `AvcodecWorkerBudgetExceeded`. The unit test exercises 16
active + 32 waiting jobs, FIFO progress, queue overflow, queued cancellation,
and complete retirement to zero active/queued workers and zero reserved bytes.

The warm build was temporarily configured with AVCODEC_STAGE=ON for these
software-only proofs; this is not a change to the shipped default. An existing
ON-only main.cpp call lacked its capability declaration. It now goes through
NativeEmbeddingSupport, preserving the audited Qt/native boundary. The same
host API exposes numeric worker facts to the admitted test `report` seam.

Exact commands (logs under the scratch root):

```sh
cmake -S . -B /private/tmp/wam-native-scratch/build -DWAM_ENABLE_AVCODEC_STAGE=ON
# configure-software-proof.log
cmake --build /private/tmp/wam-native-scratch/build --target WAM wam_avcodec_worker_test wam_software_avcodec_video_test --parallel 4
# build-software-scheduler.log: failed on the pre-existing ON-only missing declaration
cmake --build /private/tmp/wam-native-scratch/build --target WAM wam_avcodec_admission_queue_test --parallel 4
# build-software-scheduler2.log, build-software-scheduler3.log,
# build-software-storm-geometry.log: succeeded
ctest --test-dir /private/tmp/wam-native-scratch/build -R '^avcodec_admission_queue$' --output-on-failure
# scheduler-unit.log, scheduler-unit-final.log, scheduler-unit-final2.log: 1/1 passed
python3 tests/wamkit_dogfooding_test.py
# passed; audit unchanged
/opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=320x180:rate=25 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 40 -c:v mpeg4 -bf 2 -q:v 4 -threads 2 -c:a pcm_s16le /private/tmp/wam-native-scratch/software-storm.mkv
python3 scripts/native_software_storm_proof.py --asset /private/tmp/wam-native-scratch/software-storm.mkv --output /private/tmp/wam-native-scratch/proofs/software-storm-1
python3 scripts/native_software_storm_proof.py --asset /private/tmp/wam-native-scratch/software-storm.mkv --output /private/tmp/wam-native-scratch/proofs/software-storm-2
python3 scripts/native_software_storm_proof.py --asset /private/tmp/wam-native-scratch/software-storm.mkv --output /private/tmp/wam-native-scratch/proofs/software-storm-3
python3 scripts/native_software_storm_proof.py --asset /private/tmp/wam-native-scratch/software-storm.mkv --output /private/tmp/wam-native-scratch/proofs/software-storm-4
```

The runner derives from the retained phase-2g storm and adds the mandatory gate,
identity assertions, per-session drawn checks, exact preview-completion counts,
worker-budget facts, geometry assertions and closed-process image inventory.
Run 1 completed 41/41 admitted previews and all sixteen playback sessions, but
is **diagnostic only**: the old geometry seam parked only the first window and
the later windows cascaded to ordinary screen positions. Its result was marked
failed after inspecting the actual geometry. The new explicit
`WAM_TEST_ALL_WINDOW_GEOMETRY=1` applies the admitted parked rectangle to every
window. The original first-window-only behavior remains the default for other
harnesses. All acceptance runs require 32 reported rectangles (two reports ×
sixteen windows) to equal `480x270+2400+1000`.

Accepted storm results (all exit 0, no compiler/linker at launch):

| Run | Gate load1 | Started / drawn sessions | Preview demanded / admitted / drawn / failed | Commit submitted / ready / drawn | Peak workers | Retired workers / queued / bytes |
| --- | ---: | --- | --- | --- | ---: | --- |
| software-storm-2 | 2.4580078125 | 16 / 16 | 105 / 41 / 41 / 0 | 19 / 19 / 19 | 16 | 0 / 0 / 0 |
| software-storm-3 | 4.35546875 | 16 / 16 | 105 / 41 / 41 / 0 | 19 / 19 / 19 | 16 | 0 / 0 / 0 |
| software-storm-4 | 4.73583984375 | 16 / 16 | 105 / 41 / 41 / 0 | 19 / 19 / 19 | 16 | 0 / 0 / 0 |

All 41 dispatched/admitted previews complete in every run. The 105 pointer
demands include normal upstream coalescing; they are not 105 decoder jobs.
Active reported reservation: 488,668,640 bytes. Closed reports show zero windows,
zero workers/queue/reservation, and `vmmap` shows no native codec/util images.
All 32 geometry observations per run match the requested rectangle. There are
no fallback selections or session failures. Queue waiting/cancellation under
actual saturation is separately exercised by the admission unit test; the
handoff storms themselves report zero queued jobs at their report checkpoints.
Follow-up item 2 is accepted before starting item 3.

The existing `avcodec_worker_budget` test was updated to expect worker 17 to
queue without creating a seventeenth thread, then cancel and unload. Exact
follow-up commands: `cmake --build /private/tmp/wam-native-scratch/build --target
wam_avcodec_worker_budget_test wam_avcodec_admission_queue_test --parallel 4`
(`build-software-budget-test.log`), then `ctest --test-dir
/private/tmp/wam-native-scratch/build -R '^avcodec_(admission_queue|worker_budget)$'
--output-on-failure` (`scheduler-budget-tests.log`): **2/2 passed, 0.50 s**.

### Follow-up 3: full-range 8-bit ASP/VP9

The internal VideoStreamConfiguration now carries an optional container-resolved
range. Playback and preview both supply it; isolated codec-record callers keep
their prior bitstream-derived default. The libavcodec adapter uses that fact to
choose the full-range CVPixelBuffer format, retaining sample bytes without
normalization. Libavformat now retains explicit versus unspecified range before
publishing MediaVideoFormat. Matroska already retained it. Full-range ASP and
VP9 profile 0 SDR are admitted by the software color predicate after the proof
below. Apple's MPEG-4 Simple Profile full-range path retains its existing named
refusal; HDR/Dolby Vision and other unqualified tuples remain gated. Frozen
headers were not modified.

The comparison is phase 2g's **hardware-oracle** projection, ported from
`analyze-444-hardware-fixed.py`: ICC-converted sRGB, flat patch interiors,
RMS ≤6/255, absolute matrix/range projection ≤0.15. The oracle is native
VideoToolbox hardware VP9 profile 0; the two observations are native libavcodec
ASP and forced-software VP9. Wrong-matrix and wrong-range hardware controls
carry exactly the same decoded YUV bytes as the correct control and ASP's first
frame: SHA-256 `701e6e060259b7da38c3cb92dc81170b0326db6ca5dc7ecc82a38c3172a86fc1`.
Thus metadata controls do not accidentally re-encode different colors. The
full-range ASP is Advanced Simple Profile with B frames; VP9 is explicitly
profile 0, and both declare `color_range=pc`.

Exact commands:

```sh
python3 scripts/native_full_range_proof.py --root /private/tmp/wam-native-scratch/proofs/full-range --phase generate
cmake --build /private/tmp/wam-native-scratch/build --target WAM wam_software_color_qualification_test wam_libavformat_source_test wam_matroska_demuxer_test --parallel 4
ctest --test-dir /private/tmp/wam-native-scratch/build -R '^(software_color_qualification|libavformat_mpeg4_full_range|matroska_demuxer)$' --output-on-failure
python3 scripts/native_full_range_proof.py --root /private/tmp/wam-native-scratch/proofs/full-range --phase capture
python3 scripts/native_full_range_proof.py --root /private/tmp/wam-native-scratch/proofs/full-range --phase analyze
```

Generation expands to the exact ffmpeg/ffprobe argv arrays retained in
`proofs/full-range/commands.json`; `full-range-generate.log` and
`specimens.json` retain profile/range and encoded/decoded hashes. It uses
`smptebars=size=640x360:rate=25`, `scale=in_range=tv:out_range=pc`, MPEG-4
`-bf 2 -q:v 1`, then lossless VP9 `-profile:v 0 -lossless 1` with the decoded
ASP frame as input. Correct/matrix controls use `-color_range pc`; the deliberately
wrong-range control uses `tv`. Each encoder/filter is limited to one thread.
Build logs: `build-fullrange.log`, `build-fullrange2.log`. Targeted tests:
**3/3 passed, 0.96 s**, including retained range in both demuxers and preserved
Simple Profile/HDR refusals (`fullrange-unit.log`).

| Capture | Gate load1 | Proven decoder | Exit |
| --- | ---: | --- | ---: |
| hardware-correct | 4.80712890625 | VideoToolboxHardware | 0 |
| hardware-matrix | 4.67626953125 | VideoToolboxHardware | 0 |
| hardware-range | 4.3818359375 | VideoToolboxHardware | 0 |
| software-vp9 | 7.8818359375 | Libavcodec | 0 |
| software-asp | 7.33056640625 | Libavcodec | 0 |

Every compiler/linker inventory was empty. The software-VP9 gate first observed
load 8.83251953125 and waited 30 s. Each capture retains isolated HOME,
identity-bound events, metrics, environment and a 480×270 actual composited
CALayer image. No fallback or native failure occurred. The ASP image was also
visually inspected: color bars fill the video rectangle, without error UI.

| Observation | Pixels | RMS /255 | Wrong-matrix projection | Wrong-range projection |
| --- | ---: | ---: | ---: | ---: |
| ASP full 8-bit | 91,441 | 0.04370534297656112 | +0.00010964848765823997 | −0.000016357728109618783 |
| VP9 profile 0 full 8-bit | 91,441 | 0 | 0 | 0 |

Positive matrix projection points toward interpreting these 601 samples as 709;
positive range projection points toward treating full-range samples as limited
and expanding them. ASP's minute negative range component points away from
that expansion, not toward the lost-range defect. Control energies are
19,507,793 (matrix) and 13,632,700 (range), so neither direction is degenerate.
Both pass the unchanged tolerances (`projection.json`). This is the requested
hardware-oracle qualification, not a claim that the historical independent
FFmpeg RGB reference discrepancy has been repaired. No approximate pixel
compensation ships. The software stage remains an opt-in build capability;
the shipped OFF configuration is restored for final regression and item 4.
Follow-up item 3 is accepted before item 4.

### Final shipped regression (before item 4)

Restored and built the shipped configuration successfully (692 Ninja steps):

```sh
cmake -S . -B /private/tmp/wam-native-scratch/build -DWAM_ENABLE_MACOS_NATIVE_VIDEO=ON -DWAM_ENABLE_AVFORMAT_STAGE=ON -DWAM_ENABLE_AVCODEC_STAGE=OFF -DBUILD_TESTING=ON
cmake --build /private/tmp/wam-native-scratch/build --parallel 4
TMPDIR=/private/tmp/wam-native-scratch/test-tmp WAM_TEST_SCRATCH=/private/tmp/wam-native-scratch/test-tmp ctest --test-dir /private/tmp/wam-native-scratch/build -LE benchmark --output-on-failure
TMPDIR=/private/tmp/wam-native-scratch/test-tmp WAM_TEST_SCRATCH=/private/tmp/wam-native-scratch/test-tmp ctest --test-dir /private/tmp/wam-native-scratch/build -R '^caption_service$' --output-on-failure
```

Logs: scratch `configure-shipped-final.log`, `build-shipped-final.log`,
`ctest-shipped-final.log`, `ctest-caption-retry.log`. Full suite: **134/135
passed**, 155.56 s; `caption_service` failed with “GPU descendant not started”
(150 ms fake-GPU watchdog). The isolated unchanged retry **passed 1/1**, 3.81 s.
This is a timing-sensitive failed first attempt, not a clean first-pass suite.
All changed-feature tests passed. No caption code or test was modified.

As in the previous round, generated scratch CTest files use scratch
`python-tests` instead of `/opt/anaconda3/bin/python3[.12]`, retaining Python
semantics while redirecting temporary files and gating identity-bound GUI
launches. The generated Swift invocation appends `--stage-package
/private/tmp/wam-native-scratch/swift-package-source`. No repository test
registration was changed for this adaptation. `ctest-gate.jsonl` records a
30-second compiler wait before GUI launch. Frozen headers/audio tests have no
Git diff; `git diff --check` passed. No Git writes were performed.

### Follow-up item 4 — full A/V rerun, measurement only

No code changed for this item. Inventoried workspace `tests/fixtures`,
`test-media`, `docs` and scratch media using `rg --files`, deduplicated file
identities, and queried `ffprobe -v error -show_entries
format=duration:stream=codec_type,codec_name,duration -of json PATH`.
Scratch `late-fixture-inventory.json` and `late-doc-fixture-inventory.json`
retain the inventory. The longest shipped-native A/V fixture is
`build/mpegts-fixtures-v1/L_video.ts` (format 20.021334 s, H.264 20 s / 600
frames, AAC 19.84 s). The longer 40 s ASP storm and 20.086 s WMV fixtures need
fallback with the restored codec-OFF build. Retained docs media are 4 s.

Exact sequential commands (after all own builds/tests finished):

```sh
python3 scripts/native_deferred_proof.py --asset /private/tmp/wam-native-scratch/build/mpegts-fixtures-v1/L_video.ts --seconds 23 --output /private/tmp/wam-native-scratch/proofs/late-native-1
python3 scripts/native_deferred_proof.py --asset /private/tmp/wam-native-scratch/build/mpegts-fixtures-v1/L_video.ts --seconds 23 --output /private/tmp/wam-native-scratch/proofs/late-native-2
python3 scripts/native_deferred_proof.py --asset /private/tmp/wam-native-scratch/build/mpegts-fixtures-v1/L_video.ts --seconds 23 --output /private/tmp/wam-native-scratch/proofs/late-native-3
python3 /private/tmp/wam-native-scratch/analyze-late.py
```

Each proof uses isolated HOME, `WAM_TEST_BACKGROUND=1 WAM_TEST_MUTED=1
WAM_TEST_GEOMETRY=480x270+2400+1000`, benchmark RUN_ID/ASSET_SHA256/CANDIDATE_ID,
and the existing 30 s poll gate. All accepted gates had no compiler/linker:

| Run | Gate load1 | Drawn | Late discards | Audio underrun callbacks | Clock-advancing underruns | Final media seconds |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 2.439453125 | 599 | 1 | 1 | 0 | 20.020189375 |
| 2 | 3.423828125 | 599 | 1 | 1 | 0 | 20.020101750 |
| 3 | 7.5419921875 | 599 | 1 | 1 | 0 | 20.020065958 |

Run 3 first observed load 9.2822265625, waited 30 s, then passed. All app
processes exited 0. The existing runner returns **1** for each because its
`zero_late_proof` predicate is false; these are valid nonzero measurements,
not zero-late acceptance. All runs rendered 961,024 audio frames across
1,003 callbacks, retired 0 late audio frames, and had 0 superseded video
frames. The single video discard was present at the first native sample
(media 0.1000395 / 1.158952583 / 0.261263792 s); the audio counter became 1
only at the final ~20.020 s sample. Neither counter is excluded or relabeled.
The cause of this native startup discard and endpoint underrun remains
unresolved; item 4 authorizes measurement only.

`analyze-late.py` verifies every benchmark record's run ID, process ID, asset
hash and current candidate hash, native selection with route proof, first
frame, no fallback/libmpv initialization, app exit, full-duration progress
and rendered audio. Results are in `late-native-summary.json`; raw logs,
metrics, environments, gates and captures remain under each proof directory.
Asset SHA256: `597f2a7727b1e571664f8fabe3cf5d4f0586d475b752a6dbeb2df2b6f70e3a67`.
Candidate SHA256: `12a9e3d87c1f5f8d1f296712df7da5b069fc90a9519003affccafb426553b6b2`.

### Follow-up completion and remaining limits

Items 1–3 have accepted measured proofs; item 4's three requested measurements
are complete. Fallback audio underruns remain **unavailable**, native reruns
retain the above nonzero counters, and the historical independent RGB-reference
range discrepancy is not claimed repaired. Hardware-oracle full-range SDR
qualification passes for ASP/VP9 only; Simple Profile full range and HDR stay
fail-closed. Shipped codec OFF is restored. This developer-host proof is not
macOS 13.3 deployment qualification. No commits, index changes, frozen-file
changes, or changes to the sibling workspace were made.

Every repository file changed in this follow-up (new files included):

- `CMakeLists.txt`
- `docs/NATIVE_DEFERRED_2026_09.md`
- `scripts/native_full_range_proof.py`
- `scripts/native_software_storm_proof.py`
- `src/media/avcodec/decode_worker.cpp`
- `src/media/avcodec/decode_worker.hpp`
- `src/media/libavformat_cursor.cpp`
- `src/media/libavformat_cursor.hpp`
- `src/media/matroska_demuxer.cpp`
- `src/media/software_color_qualification.hpp`
- `src/platform/macos/libavformat_media_source.mm`
- `src/platform/macos/native_embedding_support.hpp`
- `src/platform/macos/native_embedding_support.mm`
- `src/platform/macos/native_preview_frame_lane.mm`
- `src/platform/macos/native_video_consumer.mm`
- `src/platform/macos/native_video_presenter.hpp`
- `src/platform/macos/software_avcodec_video_decoder.hpp`
- `src/platform/macos/software_avcodec_video_decoder.mm`
- `src/platform/macos/video_decode_lane.hpp`
- `src/qt/main.cpp`
- `src/qt/mpv_video_item.cpp`
- `src/qt/player_controller.cpp`
- `src/qt/player_controller.hpp`
- `src/qt/window_manager.cpp`
- `src/qt/window_manager.hpp`
- `tests/avcodec_admission_queue_test.cpp`
- `tests/avcodec_worker_budget_test.cpp`
- `tests/libavformat_source_test.mm`
- `tests/matroska_demuxer_test.cpp`
- `tests/player_controller_lazy_test.cpp`
- `tests/software_color_qualification_test.cpp`
