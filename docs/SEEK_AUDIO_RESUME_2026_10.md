# Seek audio resume — 2026-10-07

## Status and scope

The native commit handshake allowed the pause power-saving path to stop an output that had just been started and primed. The fix retains that running, silent output until the mandatory post-commit run intent arrives. It also checks the accepted run-command mailbox, closing the interval before the worker transfers that command to `runPending`. Explicit paused intent still permits suspension. No clock math, exact targets, decode ladder, source admission, or named failure reasons changed.

**The requested two-file native audio acceptance cannot be claimed.** The exact supplied `side_cam.mp4` contains no audio track. The MOV has AAC, but this revision's native source refuses it with `LibavformatAudioTimingUnproven: aac`. Neither file supplies the requested native audio callback evidence. A small synthetic native A/V control was used to reproduce and investigate the defect; it is not substituted silently for either requested asset.

No git staging, commits, stash, reset, or checkout. The pre-existing `src/qt/main.cpp` keyboard-skip seam is preserved. All four frozen file patterns remain unchanged.

## Instrumentation

`NativeBenchmarkTelemetry::Event` and its name switch now include:

- `audio_output_start_issued`: immediately before `startUnit()` calls AudioOutputUnitStart; generation and HAL buffer duration.
- `audio_first_render`: first adapter callback after the start, including callbacks that can only output silence.
- `audio_clock_advancing`: first committed callback containing real PCM after the start; actual callback frame duration.
- `run_state_play_applied`: successful unpause reaching the real audio session.
- `fallback_seek_submitted` and `fallback_playback_restart`: GUI mpv request/restart observations. Restart is an engine-level proxy, **not** a hardware-audibility timestamp.

A compile-gated, process-lifetime 8,192-entry mailbox uses one lock-free atomic claim and a release-published slot per event. The owner drains with acquire loads at telemetry checkpoints and finish. No callback allocates, locks, formats JSON, or performs I/O. Overflow fails the telemetry stream closed. The output snapshots the enabled gate before callbacks start. Without the build definition, audio instrumentation and its members are absent. With the definition but telemetry disabled, callbacks take only the disabled branch. The GUI retains existing telemetry identity/owner-thread checks. Audio events carry generation; the measurements use one playback session per process. Do not join generations alone across simultaneous windows.

Serialization order need not equal timestamp order: audio facts are drained after their occurrence. Analyze `monotonic_ns`, not `event_sequence`. All timestamps use the same steady-clock domain. Native `audio_clock_advancing` is the requested real-PCM render boundary; these quiet proofs do not measure acoustic output from speakers. Hardware presentation latency remains outside that boundary.

## Reproduction environment

Workspace `/private/tmp/wam-seek`, branch `seek-audio-resume`; app built only under `/private/tmp/wam-seek-scratch/build`. No network. Media read in place. Free disk was approximately 4.2 GiB initially, rather than the expected 20 GiB.

```sh
cmake -S . -B /private/tmp/wam-seek-scratch/build -G Ninja \
  -DCMAKE_PREFIX_PATH=/opt/homebrew/opt/qt \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3 \
  -DWAM_ENABLE_MACOS_NATIVE_VIDEO=ON -DWAM_ENABLE_AVFORMAT_STAGE=ON \
  -DWAM_ENABLE_AVCODEC_STAGE=OFF -DWAM_NATIVE_BENCHMARK_TELEMETRY=ON \
  -DBUILD_TESTING=ON \
  -DWAM_FFMPEG_LGPL_ROOT=/Users/wesleymaa/Github/wesley-av-media-player/third_party/ffmpeg-lgpl \
  -DWAMKIT_TEST_FIXTURE_DIR=/private/tmp/wam-seek-scratch/fixtures \
  -DWAM_NATIVE_READER_TEST_FIXTURE=/private/tmp/wam-seek-scratch/fixtures/av.mp4
cmake --build /private/tmp/wam-seek-scratch/build --parallel 4
```

The worktree has no pinned FFmpeg installation, so the existing local pinned installation was selected explicitly. Generated fixtures are redirected to scratch. The AudioToolbox HE-AAC fixture encoder fails in the sandbox (`1718449215`); the authorized build completed outside that sandbox. Build logs: `configure.log`, `configure-fixtures.log`, `build-app-before-2.log`, `build-all-3.log`, `build-final.log` in scratch. Installed Homebrew Qt libraries emit deployment-floor warnings (newer than 13.3); this is a local build, not a release portability proof.

Small synthetic controls (no original media copied):

```sh
/opt/homebrew/bin/ffmpeg -v error -y \
  -f lavfi -i testsrc2=size=320x180:rate=30:duration=90 \
  -f lavfi -i sine=frequency=440:sample_rate=48000:duration=90 \
  -c:v libx264 -threads 4 -preset ultrafast -g 225 -bf 2 -pix_fmt yuv420p \
  -c:a aac -b:a 128k /private/tmp/wam-seek-scratch/native-av.mp4
/opt/homebrew/bin/ffmpeg -v error -y \
  -i /private/tmp/wam-seek-scratch/native-av.mp4 \
  -c:v wmv2 -threads 4 -b:v 600k -c:a wmav2 \
  /private/tmp/wam-seek-scratch/fallback.wmv
mkdir -p /private/tmp/wam-seek-scratch/build/WAM.app/Contents/Frameworks
cp /opt/homebrew/lib/libmpv.2.dylib \
  /private/tmp/wam-seek-scratch/build/WAM.app/Contents/Frameworks/WAMMpvFallback.dylib
chmod 755 /private/tmp/wam-seek-scratch/build/WAM.app/Contents/Frameworks/WAMMpvFallback.dylib
```

This stages the local mpv library for development, with its existing Homebrew dependencies; it is not release packaging.

Each measured GUI launch used the scratch `measure.py` runner. It hashes the actual binary and input, generates a run UUID, creates a separate HOME, logs the gate, then launches only the scratch app. It polls every 30 seconds until no compiler/linker process is present and load1 < 8. Each run retains `invocation.json` (exact argv/environment), `gate.jsonl`, `trace.jsonl`, `samples.jsonl`, and `stdout.log`. Later runs also retain `load-during.jsonl`. Only its own launched PID can be terminated on timeout. All runs use:

```text
WAM_NATIVE_BENCHMARK_TELEMETRY=1
WAM_TEST_BACKGROUND=1
WAM_TEST_MUTED=1
WAM_TEST_GEOMETRY=480x270+2400+1000
WAM_TEST_QUIT_AFTER_MS=38000
WAM_TEST_WINDOW_SCRIPT=skip:0:10@6000,skip:0:10@5000,skip:0:-10@5000,skip:0:30@5000,skip:0:-30@5000,skip:0:10@5000
```

Window delays accumulate: nominal gesture times are 6, 11, 16, 21, 26, 31 seconds. Commands run from the worktree:

```sh
python3 /private/tmp/wam-seek-scratch/measure.py /Users/wesleymaa/Downloads/side_cam.mp4 before-side-1
python3 /private/tmp/wam-seek-scratch/measure.py /Users/wesleymaa/Downloads/Tairan_He_Talk_Dec_16_2025.mov before-talk
python3 /private/tmp/wam-seek-scratch/measure.py /private/tmp/wam-seek-scratch/native-av.mp4 before-native
python3 /private/tmp/wam-seek-scratch/measure.py /private/tmp/wam-seek-scratch/native-av.mp4 after-native
python3 /private/tmp/wam-seek-scratch/measure.py /private/tmp/wam-seek-scratch/native-av.mp4 after-native-2
python3 /private/tmp/wam-seek-scratch/measure.py /Users/wesleymaa/Downloads/side_cam.mp4 after-side
python3 /private/tmp/wam-seek-scratch/measure.py /private/tmp/wam-seek-scratch/fallback.wmv fallback-wmv
python3 /private/tmp/wam-seek-scratch/measure.py /Users/wesleymaa/Downloads/Tairan_He_Talk_Dec_16_2025.mov fallback-talk
```

`before-side` was a sandbox-denied gate attempt (`ps` unavailable); no app launched. GUI measurements subsequently used authorized unsandboxed execution. The supervisor's baseline remains separate at `baseline-trace.jsonl`; its reported 48/53 ms video commits are not audio measurements.

## Root-cause evidence

The synthetic baseline records two starts for every target generation. First: SeekCommitted → start → paused proof → CommitReady. Second: the worker mistakes the proved landing for an idle user pause, stops the device, and the restored playing intent must start it again. Baseline readiness-to-real-PCM is 55.924–83.925 ms (median 67.254 ms), although callbacks span only 20 ms. Baseline underrun and late-frame counts are zero. This implicates lifecycle serialization, not starvation or decode-to-target, in the post-picture stall.

The guard checks `commitRunStatePending` and `publishedRun` under the same mutex used for command acceptance, after obtaining the live child-operation permit. Stop/retirement ordering and the callback-quiescence requirements are unchanged. The output still stops for generation flush; this change removes the unnecessary **second** stop/start, not that safety barrier.

## Results

Durations below are milliseconds. `ready` = submitted → CommitReady; `resume` = CommitReady → real-PCM callback; `gap` = submitted → real-PCM callback. Each six-skip sequence is +10, +10, −10, +30, −30, +10. The playback-relative targets differ between runs because the clock is correctly frozen during seek latency.

### Native synthetic control

| Skip | Before ready | Before resume | Before gap | After ready | After resume | After gap |
|---|---:|---:|---:|---:|---:|---:|

| 1 | 59.229 | 64.999 | 124.228 | 83.884 | 11.111 | 94.995 |
| 2 | 136.517 | 55.952 | 192.469 | 96.322 | 11.759 | 108.081 |
| 3 | 124.700 | 77.926 | 202.626 | 127.015 | 14.603 | 141.618 |
| 4 | 161.546 | 55.924 | 217.471 | 138.498 | 17.552 | 156.050 |
| 5 | 108.617 | 69.509 | 178.126 | 106.827 | 8.578 | 115.405 |
| 6 | 105.682 | 83.924 | 189.606 | 131.465 | 17.575 | 149.040 |
| Median | 116.659 | 67.254 | 191.038 | 116.921 | 13.181 | 128.511 |
| Max | 161.546 | 83.924 | 217.471 | 138.498 | 17.575 | 156.050 |

The after column is `after-native-2`. All six resume intervals are within the measured HAL buffer duration **20.000 ms**, also equal to the PCM callback quantum. Maximum 1 Hz sampled `audio_underrun_callbacks`, `audio_clock_advanced_underruns`, `discarded_late_frames`, and `audio_retired_late_frames`: **0 / 0 / 0 / 0**, before and after. Starts per committed generation: **2 before, 1 after**. The successful after run's initial load1 was 3.980; load during the run ranged 3.980–16.314. A passing launch gate does not guarantee constant ambient load.

### Retained unsuccessful after run

The first guard-only after run, `after-native`, passed its launch gate (load1 6.258, no compilers) but failed acceptance. Do not exclude it when assessing robustness:

| Skip | Ready | Resume | Gap |
|---|---:|---:|---:|
| 1 | 390.518 | 8.100 | 398.617 |
| 2 | 385.291 | 4.921 | 390.212 |
| 3 | 143.980 | 22.291 | 166.271 |
| 4 | 448.495 | 9.765 | 458.259 |
| 5 | 1691.114 | 5.745 | 1696.859 |
| 6 | 733.012 | 197.480 | 930.492 |

Maximum sampled underrun callbacks **63**, clock-advancing underruns **62**, late video discards **104**, retired-late audio frames **15,552**. Its sixth seek spent ~197 ms between readiness and the applied run command. The extra stop/start was gone, but this run shows that the asynchronous GUI/worker handshake and general scheduling can still exceed one quantum. There is no hard real-time bound, and the repeat success is not proof of one under arbitrary load. No decode or fail-closed policy was weakened to conceal this result.

### Requested side_cam.mp4

SHA256 `4fa6b507a45d2b32363d20a688dfc9d513cca164808c24a7ee8eb97c1b566968`. FFprobe (`side-probe.json`) reports a single video stream. Audio start/render/advancing facts and audio sample fields are correctly absent/null, not fabricated zeroes. Baseline video-only submitted → ready: 127.368, 97.284, 130.572, 49.159, 44.163, 46.628 ms; median **73.221**, max **130.572**. Late-frame discard maximum **0**. Native audio median/max and gesture-to-audible: **N/A**.


After video-only submitted → ready: **125.484, 109.803, 125.432, 62.076, 53.016, 35.215 ms**; median **85.940**, max **125.484**. Late-frame discard maximum **0**. Audio quantities remain **N/A**. The final code no longer emits `run_state_play_applied` for the silent timebase; the initial instrumented baseline did, but no audio events were inferred from it.

### Requested MOV

FFprobe (`talk-probe.json`) confirms H.264 plus stereo 48 kHz AAC. Native open returned `LibavformatAudioTimingUnproven: aac`. Native six-skip timing, audio underrun counts and audio-resume acceptance: **not available**. The initial `before-talk` run also discovered the missing development fallback library, subsequently staged as described above. The source ladder and refusal remain unchanged.


### mpv fallback

WMV2/WMA2 synthetic asset, fallback selected, six `seek relative` commands:
**40.796, 41.934, 42.035, 42.726, 43.601, 42.303 ms** submitted → `MPV_EVENT_PLAYBACK_RESTART`; median **42.169**, max **43.601**.

Requested MOV (SHA256 `5b164d795c0ecd92ab626b1c7696763ebea1f822217ff87bb8825505fc278d31`) after the unchanged native refusal:
**52.728, 50.717, 46.906, 44.700, 50.711, 39.588 ms**; median **48.809**, max **52.728**.

Both fallback runs had sampled VO late discards **0** and decoder discards **0**. Native underrun fields are unavailable on mpv. The engine-level restart intervals do not reproduce the native ~67 ms post-picture extra restart; however they are not an audio callback or acoustic proof, so the absence of every audible stall is **not established**. No mpv playback options were changed on this evidence. The test-only mute seam now also sets mpv's initial muted state in the isolated HOME; normal playback preferences are unaffected.

### Scrubber proof and paused-seek limitation

```sh
WAM_TEST_SEEK_SCRIPT='40.5@6,12@42' \
  python3 /private/tmp/wam-seek-scratch/measure.py \
  /private/tmp/wam-seek-scratch/native-av.mp4 scrub-native ''
python3 /private/tmp/wam-seek-scratch/measure.py \
  /private/tmp/wam-seek-scratch/native-av.mp4 paused-native-final \
  'pause:0@3000,skip:0:10@3000,skip:0:-10@5000'
```

Scrubber `CommitReady.target_seconds` exactly equals **40.5** and **12**. Submitted → ready: **158.060 / 163.315 ms**. Ready → PCM: **7.548 / 3.084 ms**. All four sampled native underrun/late counters remain **0**. The proof uses the actual `beginScrub / previewSeekTo / endScrub` test seam, not keyboard seeks.

## Validation setup and remaining limits

The first full non-benchmark suite (`ctest.log`) had two failures: the new Qt include violated the existing native ownership audit, and `native_coverage_wiring` crashed because Qt Labs Platform menus cannot run under the offscreen plugin. Three GL-dependent tests skipped. The architecture failure was fixed by placing the telemetry mailbox in `src/media/native_audio_benchmark.hpp`; the ownership audit was **not** relaxed.

For the final full suite, the production-app wiring harness is copied to scratch with only execution-environment changes: Cocoa for the app, the same compiler/load gate before each launch, and retained artifacts in `wiring-final`. All original assertions remain. The generated build's `CTestTestfile.cmake` points that one test to the copy and permits 1,800 seconds for load-gate waits. Other Qt unit tests remain offscreen to avoid foreground windows. This is a scratch test-run override, not a repository/CMake change. Reconfiguring the build removes that override. Exact harness: `/private/tmp/wam-seek-scratch/native_coverage_wiring_gated.py`; gate: `/private/tmp/wam-seek-scratch/gate.py`.

```sh
# Separate existing scratch directories were created for HOME and TMPDIR.
env HOME=/private/tmp/wam-seek-scratch/ctest-home \
  TMPDIR=/private/tmp/wam-seek-scratch/ctest-tmp/ \
  WAM_TEST_SCRATCH=/private/tmp/wam-seek-scratch/ctest-tmp \
  QT_QPA_PLATFORM=offscreen QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM=1 \
  WAM_NATIVE_BENCHMARK_TELEMETRY=1 WAM_TEST_BACKGROUND=1 WAM_TEST_MUTED=1 \
  WAM_TEST_GEOMETRY=480x270+2400+1000 CMAKE_BUILD_PARALLEL_LEVEL=4 \
  ctest --test-dir /private/tmp/wam-seek-scratch/build \
  -LE benchmark --output-on-failure -j 1
```

Final suite (`ctest-final.log`, `ctest-final-exit.txt`): **exit 0, 0 failures out of 135 selected, 132 passed and 3 skipped, 131.73 seconds**. Skipped: `player_core_render_context_permission`, `macos_native_qt_gl_compositor`, `macos_native_qt_gl_output` (offscreen GL unavailable). The wrapping cleanup subsequently attempted to resume the already-cancelled old runner and reported ProcessLookupError; this happened after CTest had exited 0 and does not change its recorded result. Production wiring receipts and gate logs are retained in `wiring-final`; detailed test output is in `build/Testing/Temporary/LastTest.log`.

Focused tests `wam_native_media_session_test` and `wam_native_benchmark_telemetry_test` passed. New coverage parks the CommitReady handshake over repeated worker wakes and checks that suspension is withheld, then supplies an explicitly paused run state and checks suspension resumes. Telemetry coverage concurrently publishes four event kinds, checks no producer writes the sink, checks owner-thread serialization/generation/quantum, and checks that a disabled mailbox claims no entry.

The initial paused-proof runner was held while the suite ran, then cancelled before launching because its precomputed binary hash predated the final rebuild. Its gate log is retained under `runs/paused-native`; it is not a playback proof.

Acceptance limits:

- No native audio proof is possible for the supplied video-only MP4; the supplied MOV is refused by the unchanged native ladder. The requested all-12 native-audio acceptance is **not met**.
- A successful native control repeat meets the 20 ms quantum and zero-underrun/zero-late requirements; a retained earlier run does not. An absolute one-quantum bound under arbitrary scheduling load is **not established**.
- mpv restart timing is a proxy. Its real hardware callback/audibility gap and native-style underrun counts are unavailable; no unsupported fallback fix was made.
- Quiet seams intentionally mute all measurements. They prove callback behavior, not subjective listening or acoustic latency.
- GL-dependent tests cannot be counted as passed when offscreen mode skips them.

## Files changed

Authored changes:

- `src/media/native_audio_benchmark.hpp` — shared, compile-gated render-safe event mailbox.
- `src/platform/macos/native_audio_output.hpp` — latched telemetry enable and first-callback flags.
- `src/platform/macos/native_audio_output.mm` — start, first-render, first-real-PCM stamps and quantum durations.
- `src/platform/macos/native_media_session.hpp` — optional pause-suspend test seam.
- `src/platform/macos/native_media_session.mm` — commit-handshake suspension guard, playing-intent stamp, test seam wiring.
- `src/qt/native_benchmark_telemetry.hpp` — event vocabulary and owner drain declarations.
- `src/qt/native_benchmark_telemetry.cpp` — names, timestamp-preserving mailbox drain, optional quantum JSON field, fallback observations.
- `src/qt/player_controller.cpp` — compile-gated fallback seek/restart observations and quiet mpv test mute.
- `tests/native_benchmark_telemetry_test.cpp` — disabled and concurrent mailbox publication coverage.
- `tests/native_media_session_test.mm` — paused landing versus explicit user-pause regression.
- `docs/SEEK_AUDIO_RESUME_2026_10.md` — this report.

`src/qt/main.cpp` was already modified on entry with the supervisor's `skip:<index>:<seconds>` seam; that diff is preserved, not authored here. No frozen files changed. No commits or staging were performed.


Read-only media inspection commands:

```sh
/opt/homebrew/bin/ffprobe -v error \
  -show_entries stream=index,codec_name,codec_type,sample_rate,time_base,start_time \
  -show_entries format=duration -of json /Users/wesleymaa/Downloads/side_cam.mp4
/opt/homebrew/bin/ffprobe -v error \
  -show_entries stream=index,codec_name,codec_type,sample_rate,time_base,start_time \
  -show_entries format=duration -of json /Users/wesleymaa/Downloads/Tairan_He_Talk_Dec_16_2025.mov
python3 /private/tmp/wam-seek-scratch/analyze.py before-side-1 before-native after-native after-native-2 after-side scrub-native
python3 /private/tmp/wam-seek-scratch/analyze-fallback.py fallback-wmv fallback-talk
```

The passing `wamkit_device_recovery` test also compiles the audio output/session sources **without** `WAM_NATIVE_BENCHMARK_TELEMETRY`, exercising the compile-out path with strict warning flags. Final app SHA256: `72cd8b5cf86c3ff04d1bed20421951271438a59c72298abc91f99d2bf9c6f997`.


## Final GUI gate outcome

The final-binary paused run did **not** launch. The fresh command was:

```sh
python3 /private/tmp/wam-seek-scratch/measure.py \
  /private/tmp/wam-seek-scratch/native-av.mp4 paused-native-final \
  'pause:0@3000,skip:0:10@3000,skip:0:-10@5000'
# Queued with &&, therefore never reached after cancellation:
python3 /private/tmp/wam-seek-scratch/measure.py \
  /private/tmp/wam-seek-scratch/native-av.mp4 after-native-final
```

The retained gate contains **23 failed observations**, minimum load1 **9.244**, maximum **42.331**, no compiler/linker at those observations, and **zero passes**. Recorded wall-clock timestamp span: **84.90 minutes**, including a long gap between observations; this is not a claim of uninterrupted 30-second sampling during that gap. The waiting runner was cancelled by its exact owned PID 87122; no app PID existed. Receipt: `runs/paused-native-final/cancelled.json`.

Consequently, **the live paused-seek/no-burst proof and the additional final-binary six-skip repeat remain unverified**. The passing earlier six-skip and scrubber measurements used the same handshake fix before the mailbox's namespace/location change; their exact candidate hashes remain in each invocation/trace. Final-binary production wiring passed under the gated Cocoa test, including the exact slow seek. Unit tests cover paused behavior, but are not represented as the missing live paused proof. No gate was bypassed and no acceptance result was invented.

## Round 2 — keep the native output unit running (2026-10-07)

Worktree `/private/tmp/wam-seek`, branch `seek-round-2`; parent binary preserved as
`/private/tmp/wam-seek-scratch/build/WAM.app/Contents/MacOS/WAM-round2-before`.
This round is **blocked and incomplete** at item 1 live acceptance. The candidate
is implemented and unit-tested; no round-2 GUI acceptance is claimed.

### Item 1 implementation and safety proof

The remaining physical restart originated in `NativeAudioSession::flush()`.
It called `NativeAudioOutput::stop()` before resetting the PCM ring, converter,
and clock. The post-SeekCommitted `start()` therefore issued a hardware start.

The candidate instead calls `quiesceForSeek()`: close render admission, drain
entered callbacks using the existing bridge/epoch barrier, and leave HAL running.
Callbacks under the closed bridge emit silence. Only after that barrier completes
may the owner reset the ring, converter, and paused clock. The subsequent
`start()` reopens admission on the retained unit, without AudioOutputUnitStart.
Terminal stop, close, explicit idle-pause suspension, and device recovery retain
physical-stop behavior. This does not remove already queued hardware latency or
claim acoustic measurements.

Start telemetry now lives immediately at `startUnit()`, and the new
`audio_output_stop_issued` event lives at `stopUnit()`. Thus events count actual
call attempts, including failed attempts, rather than logical generation starts.
First-render/first-real-PCM instrumentation is rearmed for each logical start.
No allocation, lock, I/O, or new unbounded operation was added to the render path.

The commit proof loop now consumes up to 32 immediately runnable dispatcher steps
per worker pass, matching normal playback's budget, rather than waking the worker
for every packet. Blocking waits still yield. Every step retains the live-operation
permit and stop check. The existing covering-frame, generation, exact-target,
draw-sequence and paused-clock proofs are unchanged for both skips and scrubs.
This is a scheduling optimization, not a relaxation of seek precision; a measured
submitted-to-CommitReady improvement is still pending.

New output tests prove that seek quiescence keeps fake HAL running, callbacks
emit silence without allocating or publishing clock changes, generation 2 lands
at exactly 10 seconds paused, logical unpause renders its PCM, the transition
issues zero hardware starts/stops, and terminal stop still stops HAL. The stale
callback/restart epoch race test also runs with HAL retained, proving that an
entered old callback must drain before admission reopens. Existing frozen
`native_audio_session_test` and playback-contract tests pass without edits.

### Device observation

A read-only CoreAudio probe queried the default output using
`AudioObjectGetPropertyData`, output scope for latency/safety offset and global
scope for nominal rate/buffer frames. Unsandboxed result:

```text
device=112 name=Wesley’s AirPods Pro rate=48000
latency_frames=7680 safety_frames=0 buffer_frames=512
latency_ms=160.000 safety_ms=0.000 buffer_ms=10.667 sum_ms=170.667
```

This is an observed device snapshot, not the supervisor's earlier 16,384-frame
snapshot and not necessarily the AudioUnit client callback quantum. The sandbox
could not obtain a valid device; only the unsandboxed result is used. Probe source
and output: `/private/tmp/wam-seek-scratch/device_latency.cpp` and
`round2-device.txt`. Exact build/read commands:

```sh
xcrun clang++ /private/tmp/wam-seek-scratch/device_latency.cpp \
  -framework CoreAudio -framework CoreFoundation \
  -o /private/tmp/wam-seek-scratch/build/device_latency
/private/tmp/wam-seek-scratch/build/device_latency \
  > /private/tmp/wam-seek-scratch/round2-device.txt
cmake --build /private/tmp/wam-seek-scratch/build --parallel 4
```

### Validation and outstanding measured proof

Focused CTest selection: 4/4 passed in 1.22 seconds (`round2-focused.log`):
`native_audio_render_core`, `macos_native_audio_output`,
`macos_native_media_session`, `macos_native_benchmark_telemetry`.
Additional selection: 5/5 passed in 14.51 seconds (`round2-contract-tests.log`):
`native_playback_contract`, `native_media_dispatcher`,
`macos_native_audio_session`, `native_stage_defaults`, `wamkit_device_recovery`.
The last test also compiles the output implementation with telemetry disabled.

```sh
env QT_QPA_PLATFORM=offscreen ctest \
  --test-dir /private/tmp/wam-seek-scratch/build \
  -R 'macos_native_audio_output$|macos_native_media_session$|native_benchmark_telemetry|native_audio_render_core|native_ownership' \
  --output-on-failure

env HOME=/private/tmp/wam-seek-scratch/ctest-home \
  TMPDIR=/private/tmp/wam-seek-scratch/ctest-tmp/ \
  WAM_TEST_SCRATCH=/private/tmp/wam-seek-scratch/ctest-tmp \
  QT_QPA_PLATFORM=offscreen QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM=1 \
  WAM_TEST_BACKGROUND=1 WAM_TEST_MUTED=1 \
  WAM_TEST_GEOMETRY=480x270+2400+1000 \
  ctest --test-dir /private/tmp/wam-seek-scratch/build \
  -R 'macos_native_audio_session$|native_media_dispatcher$|native_playback_contract$|wamkit_device_recovery$|native_stage_defaults$' \
  --output-on-failure -j 1

python3 /private/tmp/wam-seek-scratch/gate.py \
  /private/tmp/wam-seek-scratch/runs/round2-before-gate.jsonl && \
/private/tmp/wam-seek-scratch/run_skips.zsh \
  /private/tmp/wam-seek-scratch/build/WAM.app/Contents/MacOS/WAM-round2-before \
  /private/tmp/wam-seek-scratch/native-av.mp4 round2-before \
  'skip:0:10@6000,skip:0:10@5000,skip:0:-10@5000,skip:0:30@5000,skip:0:-30@5000,skip:0:10@5000'
```

The initial gate was cancelled by its exact owned PID 91674 before any app
launched, then requeued against the preserved parent binary so rebuilding could
not change the queued baseline. No gate has been bypassed. Item 1 still requires
six-skip before/after, scrubber and paused-seek GUI proofs. Items 2 and 3 remain
untouched while that priority-ordered acceptance is pending; no AAC timing
admission or mpv options have been changed.

Round-2 files changed:

- `src/media/native_audio_benchmark.hpp` — append hardware-stop event.
- `src/platform/macos/native_audio_output.hpp` — seek-quiescence API and logical-state documentation.
- `src/platform/macos/native_audio_output.mm` — retain HAL across seek quiescence; actual-call telemetry.
- `src/platform/macos/native_audio_session.mm` — use seek quiescence in flush.
- `src/platform/macos/native_media_session.mm` — bounded commit-proof work batching.
- `src/qt/native_benchmark_telemetry.hpp` — hardware-stop event vocabulary.
- `src/qt/native_benchmark_telemetry.cpp` — serialize hardware-stop events.
- `tests/native_audio_output_test.mm` — retained-HAL lifecycle, silence/clock and callback-race proofs.
- `tests/native_benchmark_telemetry_test.cpp` — concurrent publication includes the hardware-stop event.
- `docs/SEEK_AUDIO_RESUME_2026_10.md` — round-2 record.

### Final round-2 outcome and limits

The gate was stopped by its verified owned PID **91957**, with **29 failed
observations, zero passes**, spanning **841.765 seconds (14.03 minutes)**.
Load1 minimum **19.960**, maximum **98.391**. The gate polled at 30-second
intervals; the first runner was replaced as described above. No baseline or
candidate GUI process launched. Receipt:
`/private/tmp/wam-seek-scratch/runs/round2-gate-cancelled.json`.
No pending measured runner remains.

| Requested result | Before | Round-2 candidate |
|---|---|---|
| Hardware starts/stops per playing seek | Parent source: one stop/start; round-1 live trace: one start | Unit lifecycle: **0 starts, 0 stops**; six-skip live count **unverified** |
| Submitted → CommitReady | Prior round control median **116.921 ms**, max **138.498 ms** (historical, not a fresh paired baseline) | **Unmeasured**; bounded batching implemented |
| CommitReady → real PCM | Prior round passing control **8.578–17.575 ms**, 20 ms quantum | **Unmeasured** |
| Zero underruns / late discards | Prior round passing control zero | **Unverified live** |
| Exact scrubber / paused no-burst | Prior round exact scrubber targets; paused live proof absent | Clock/silence unit proof passes; **live proof absent** |
| QuickTime AAC native admission | Refused per supervisor/parent report | **Unchanged**, item 2 not begun because item 1 has no live proof |
| Forced-fallback qt-rec.mov proxy | Supervisor reports roughly 25 ms | **Not independently measured**, item 3 not begun |

The broad suite command below selected **134 tests**: **130 passed, 3 skipped,
1 failed**, **109.82 seconds**. The failure was `caption_service`, reporting
`GPU descendant not started`. Its focused retry passed in **3.91 seconds**
without code changes. The three skips were the existing offscreen GL tests.
Production GUI `native_coverage_wiring` was explicitly excluded because it too
requires the load gate. Thus this is **not a passing full-ctest claim**.

```sh
env HOME=/private/tmp/wam-seek-scratch/ctest-home   TMPDIR=/private/tmp/wam-seek-scratch/ctest-tmp/   WAM_TEST_SCRATCH=/private/tmp/wam-seek-scratch/ctest-tmp   QT_QPA_PLATFORM=offscreen QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM=1   WAM_NATIVE_BENCHMARK_TELEMETRY=1 WAM_TEST_BACKGROUND=1 WAM_TEST_MUTED=1   WAM_TEST_GEOMETRY=480x270+2400+1000 CMAKE_BUILD_PARALLEL_LEVEL=4   ctest --test-dir /private/tmp/wam-seek-scratch/build   -LE benchmark -E '^native_coverage_wiring$' --output-on-failure -j 1

env HOME=/private/tmp/wam-seek-scratch/ctest-home   TMPDIR=/private/tmp/wam-seek-scratch/ctest-tmp/   WAM_TEST_SCRATCH=/private/tmp/wam-seek-scratch/ctest-tmp   QT_QPA_PLATFORM=offscreen   ctest --test-dir /private/tmp/wam-seek-scratch/build   -R '^caption_service$' --output-on-failure

cmake --build /private/tmp/wam-seek-scratch/build --parallel 4
env QT_QPA_PLATFORM=offscreen ctest   --test-dir /private/tmp/wam-seek-scratch/build   -R 'macos_native_audio_output$|macos_native_benchmark_telemetry$'   --output-on-failure
```

Logs in scratch: `round2-ctest-without-wiring.log`, `round2-caption-retry.log`,
`round2-build-final.log`, `round2-final-focused.log`. Final focused checks:
**2/2 passed in 0.59 seconds** after adding hardware-stop serialization coverage.
The final build completed successfully. Frozen-file diff is empty;
`git diff --check` passes. No staging, commits, stash, reset, checkout, network,
media copies, decode-ladder changes, or AAC admission changes occurred.

Final candidate SHA256: `d6f0b67e5b6452c2aeb90130744412e972b1afa9d77c85d65a5a5fea8b9ec6cd`.

## Round 3 — prove QuickTime AAC timing (2026-10-07)

The round-2 output-unit retention and commit batching changes present on entry
are preserved. This round changes source admission/timing only; no render-thread,
output-unit lifecycle, decode-ladder order, frozen file, or mpv option changes.
The maintainer owns commits; no staging or git history operations were performed.

### Why this MOV was refused

A `.mov` suffix does not select a special decoder. ISO-BMFF signatures initially
select AVFoundation (`media_container_probe.hpp`). The unchanged routed source
sends fragmented ISO-BMFF, incomplete-tail recovery, and non-local mounts directly
to libavformat. `qt-rec.mov` contains `moof` fragments, so
`requiresExactDemuxTimeline()` selects libavformat. The ordinary synthetic
`native-av.mp4` stays on AVFoundation. AVFoundation can open the MOV directly in
an offline source probe, but that does not change the production route.

Libavformat already admits the H.264/AAC codec/container combination, but its
AAC packet validator assumed origin **0/48000** and disallowed priming skips.
Its first-packet residual check returned `LibavformatAudioTimingUnproven: aac`.
Removing only that check would incorrectly place sound on the movie timeline.

The supplied MOV is not a literal 2112-frame `elst`: its audio `elst` contains
one rate-one entry with media time **64**, no empty leading edit. FFprobe and
the pinned cursor expose its first AAC packet at **−64/48000**, skip **64**.
CoreMedia independently reports one nonempty segment starting at **2112/48000**,
output target **0**, and first compressed-buffer `TrimDurationAtStart`
**2176/48000**. The second batch has input **93184/48000**, output
**91008/48000**: displacement **−2176/48000**. Thus the demux timestamps need an
additional **−2112/48000 = −44 ms** shift. Neither a guessed 64-frame trim nor
blindly applying a second 2112-frame shift to ordinary MOV is correct.

### Bounded admission proof

A worker-only CoreMedia witness now admits two tested forms: demux origin/skip
**−2112/2112** with CoreMedia trim **2112**, and **−64/64** with CoreMedia trim
**2176**. Both require exactly one nonempty, rate-one CoreMedia segment with
source start **2112/48000** and target zero. Track identity uses the actual
container track ID, not an assumed stream index. The first compressed packet
must match CoreMedia's first packet byte-for-byte, the first media PTS must be
zero, and a subsequent compressed batch must independently state the same exact
input-to-output displacement. Rounded, missing, other-priming, empty-prefix,
retimed, or multi-edit shapes remain refused by the same named reason.

The proof reads two compressed CoreMedia batches at open, bounds its copied
packet to 64 KiB, and never decodes PCM in production. The existing bounded full
libavformat scan still checks every packet's contiguous sample grid. Demux
origin and presented origin are stored separately: seeks use the demux origin;
materialized audio uses the proved presentation origin. The scanned endpoint
must also equal CoreMedia's segment duration minus any extra trim beyond the
2112-frame segment start. The supplied MOV ends at **4569984/48000 = 95.208 s**.
All of this runs on the source worker. The callback remains allocation-free and
lock-free. Short files without the second timing witness fail closed.

### Offline proof

`tests/libavformat_aac_oracle.mm` obtains independent float PCM from
AVAssetReader on its edited output timeline and checks every output buffer's
exact contiguous PTS. The production libavformat source, AudioToolbox converter,
and PCM ring are exercised through the existing mixed-audio probe. The test
keeps the existing mixed-AAC limits (**maximum < 0.002, RMS < 0.0001**), with no
fitted time shift. Every comparison below is stronger: **maximum = RMS = 0**,
bit-identical PCM and exact first-frame index.

| Asset | Target | First frame | Retained frames |
|---|---:|---:|---:|
| Generated ordinary Apple AAC MOV | 0 | 0 | 192512 |
| Same | 1/7 | 6858 | 185654 |
| Same | 1 | 48000 | 144512 |
| Same | 12029/3000 | 192464 | 48 |
| Supplied `qt-rec.mov` | 0 | 0 | 4569984 |
| Same | 1/7 | 6858 | 4563126 |
| Same | 1 | 48000 | 4521984 |
| Same | 95207/1000 | 4569936 | 48 |

The supplied file's SHA256 is
`7d873fb9528b52d42bdd1faa19bc18c700203ef19380a262356fc33b9f74e37e`.
It has initial digital silence; the comparison covers the entire recording,
including **5,797,888 nonzero interleaved samples** (peak magnitude **1.0401**),
not just the silent head. Rational-target cases are cold-open accurate targets;
they are not represented as live GUI skip measurements.

The existing routed audio probe independently reports
`WAM: native demux stage=Libavformat`, `frames=4569984 first=0 decoded=4572160
trim=2176 exact=1 drained=1 error=`. This proves native source selection and
full decode without mpv in that headless path. A GUI `native_selected` telemetry
event still requires the measured GUI gate; it is not fabricated from this log.

Commands (cwd `/private/tmp/wam-seek`; local Apple decode proofs run unsandboxed):

```sh
cmake --build /private/tmp/wam-seek-scratch/build --parallel 4
python3 tests/libavformat_aac_timing_proof.py \
  --probe /private/tmp/wam-seek-scratch/build/wam_libavformat_mixed_audio_probe \
  --oracle /private/tmp/wam-seek-scratch/build/wam_libavformat_aac_oracle \
  --ffmpeg /opt/homebrew/bin/ffmpeg \
  --scratch /private/tmp/wam-seek-scratch \
  --output /private/tmp/wam-seek-scratch/round3-aac-proof.json \
  --asset /private/tmp/wam-seek-scratch/qt-rec.mov \
  > /private/tmp/wam-seek-scratch/round3-aac-proof.log 2>&1
/private/tmp/wam-seek-scratch/build/wam_native_coverage_audio_probe \
  /private/tmp/wam-seek-scratch/qt-rec.mov \
  /private/tmp/wam-seek-scratch/qt-routed.f32 0 \
  > /private/tmp/wam-seek-scratch/round3-routed.log 2>&1
```

The Python proof records its exact FFmpeg fixture-generation argv. It creates
only small synthetic media and temporary decoded PCM under scratch; original
media are read in place. Negative synthetic variants cover unproved priming,
retiming, leading empty edits, and an endpoint inconsistent with the packet grid.
No network was used. Initial Apple PCM decoding failed in the sandbox; the
unsandboxed oracle succeeded. Initial experimental build errors (Apple/FFmpeg
`AVMediaType` collision and helper source registration) were corrected by
putting the CoreMedia witness in its own Objective-C++ translation unit.

### Test commands, gate policy, and scope of acceptance

The full suite includes the benchmark (unlike the prior round's `-LE benchmark`
selection). Its executable is excluded from the default build, so it was built
explicitly:

```sh
cmake --build /private/tmp/wam-seek-scratch/build \
  --target wam_matroska_demuxer_bench --parallel 4
env HOME=/private/tmp/wam-seek-scratch/ctest-home \
  TMPDIR=/private/tmp/wam-seek-scratch/ctest-tmp/ \
  WAM_TEST_SCRATCH=/private/tmp/wam-seek-scratch/ctest-tmp \
  QT_QPA_PLATFORM=offscreen QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM=1 \
  WAM_NATIVE_BENCHMARK_TELEMETRY=1 WAM_TEST_BACKGROUND=1 WAM_TEST_MUTED=1 \
  WAM_TEST_GEOMETRY=480x270+2400+1000 CMAKE_BUILD_PARALLEL_LEVEL=4 \
  ctest --test-dir /private/tmp/wam-seek-scratch/build \
  --output-on-failure -j 1 \
  > /private/tmp/wam-seek-scratch/round3-ctest-final.log 2>&1
```

The scratch-only production wiring harness is
`/private/tmp/wam-seek-scratch/native_coverage_wiring_round3.py`, preserving the
repository's assertions and quiet seams, with Cocoa instead of offscreen for
its actual app. Each launch uses `round3-gate.py`, which records compiler/linker
processes and one-minute load every 30 seconds, up to three observations.
No pass means exit **77** before launching. The generated scratch
`CTestTestfile.cmake` points the wiring test to that copy and sets
`SKIP_RETURN_CODE 77`, timeout 1800. This is explicitly an environmental skip,
not a passing production-wiring assertion. Reconfiguring removes the override.
All other tests retain their normal offscreen environment.

The first full run (`round3-ctest.log`) had **137 selected, 131 passed,
4 skipped, 2 failed/not run**, **172.13 s**. The benchmark was initially absent.
The new endpoint test initially expected a valid *shortened* edit to fail; the
source correctly retained a shortened interval. The regression now uses an edit
extending past available media and gets the named refusal. These initial
results are retained, not presented as acceptance. The final run follows the
completed endpoint guard and corrected regression.

### Round-3 files authored

- `src/media/libavformat_cursor.hpp`, `src/media/libavformat_cursor.cpp` — expose container track identity to the witness.
- `src/platform/macos/libavformat_aac_timing.hpp`, `src/platform/macos/libavformat_aac_timing.mm` — bounded CoreMedia priming/edit witness and exact endpoint.
- `src/platform/macos/libavformat_media_source.mm` — separate demux/presentation origins, admit only witnessed priming, verify endpoint.
- `src/wamkit/NativeTargets.cmake` — compile the witness with the libavformat backend.
- `tests/libavformat_aac_oracle.mm` — independent AVAssetReader PCM/timestamp oracle.
- `tests/libavformat_aac_timing_proof.py` — retained PCM/first-frame comparisons and named-refusal fixtures.
- `CMakeLists.txt` — oracle target and `libavformat_aac_timing` CTest registration.
- `docs/SEEK_AUDIO_RESUME_2026_10.md` — round-3 report appended to the pre-existing round-2 changes.

The other dirty files listed in the round-2 section were dirty on entry and
were not edited in round 3. Frozen-file diff remains empty. Candidate app SHA256:
`0ef11491aab3d2ac4cdebaee6e12d6d89700b0de4e62b6906e006ab3022395d4`.

### Final validation and gate outcome

Final full CTest: **exit 0, 137 selected, 133 passed, 4 skipped, 0 failures,
178.75 s**. `libavformat_aac_timing` passed in **0.49 s**; the benchmark passed
in **0.90 s**. The four skips are `player_core_render_context_permission`,
`macos_native_qt_gl_compositor`, `macos_native_qt_gl_output` (offscreen GL), and
`native_coverage_wiring` (load gate). This is a successful full CTest execution
with explicit environmental gaps, not 137 passing assertions. Logs:
`round3-final-build.log`, `round3-ctest-final.log`, `round3-ctest-final-exit.txt`.
The final external AAC receipt also records both probe binary hashes. A separate
check of the valid shortened synthetic edit retained **192412** frames, also
bit-identical to the Apple oracle.

All GUI gates had no compiler/linker processes and no passing observations:

| Gate | Observations | Load1 min–max |
|---|---:|---:|
| Initial native proof | 3 | 39.033–46.798 |
| First full-suite wiring | 3 | 15.795–21.520 |
| Final full-suite wiring | 3 | 18.869–23.638 |
| Final post-suite native/fallback gate | 3 | 17.452–19.596 |

Each row covers three observations approximately 30 seconds apart, rather than
claiming uninterrupted polling between these separate windows. **No measured GUI
app launched.** Final gate command, exit **77**:

```sh
python3 /private/tmp/wam-seek-scratch/round3-gate.py \
  /private/tmp/wam-seek-scratch/runs/round3-final-gate.jsonl
```

Initial observations are in `runs/round3-native-gate.jsonl`; wiring observations
are under `wiring-round3/notice-*/gate.jsonl`. The intended gated native launch
was the existing scratch runner with the final scratch binary and original media:

```sh
# NOT EXECUTED: the prerequisite gate did not pass.
/private/tmp/wam-seek-scratch/run_skips.zsh \
  /private/tmp/wam-seek-scratch/build/WAM.app/Contents/MacOS/WAM \
  /private/tmp/wam-seek-scratch/qt-rec.mov round3-native \
  'skip:0:10@6000,skip:0:10@5000,skip:0:-10@5000,skip:0:30@5000,skip:0:-30@5000,skip:0:10@5000'
```

Consequently the GUI `native_selected`/absence-of-fallback event, live skip
latencies, hardware start/stop counts on this MOV, underrun/late counts, paused
no-burst proof, and subjective AirPods smoothness remain **unverified**. The
round-2 output-retention implementation still awaits the supervisor's live
acceptance. No runner or app launched by this round remains pending.

### Item 2 — fallback proxy and its limits

A fresh, quiet, gated WAM forced-fallback run on `qt-rec.mov` was not possible.
However, the supervisor's **pre-existing** scratch `mpv.log` explicitly names
that same path and contains three +10-second playing seeks. Read-only analysis
pairs each `Run command: seek` timestamp with the next `playback restart complete`:

| Submitted (s) | Engine restart (s) | Proxy (ms) |
|---:|---:|---:|
| 3.438 | 3.462 | 24 |
| 6.470 | 6.501 | 31 |
| 9.507 | 9.537 | 30 |

Historical median **30 ms**, maximum **31 ms**, at the log's millisecond precision.
This is standalone mpv engine evidence, not a new WAM fallback acceptance run;
its executable hash and launch gate receipt are not available. The engine reports
CoreAudio **48000 Hz**, device latency **170666666 ns = 170.667 ms**, device
buffer **16384 samples**, and soft buffer **16384 samples**. Its latency components
are **7680 + 512 + 0 frames**. These observations explain why an engine restart
in tens of milliseconds is not proof that Bluetooth sound has resumed.
The supervisor reports that mpv's AO reset internally stops/starts its CoreAudio
unit; these log timestamps do not independently timestamp those HAL calls.
Do not add the latency and restart values and call the sum a measured acoustic gap.

The existing `mpv2.log` used `--audio-buffer=0.05`. Its one playing seek is
**18 ms**; later **20 / 31 ms** restarts are explicitly **paused**, so they are
not playing audio-resume measurements. It still reports the same **170.667 ms**
device latency and **16384-sample** buffers. Different runs and paused cases do
not establish a controlled audible win. **No mpv options were changed.**

Exact read-only analysis command and retained receipt:

```sh
python3 /private/tmp/wam-seek-scratch/round3_analyze_existing_fallback.py \
  > /private/tmp/wam-seek-scratch/round3-existing-fallback-analysis.log
# JSON: /private/tmp/wam-seek-scratch/round3-existing-fallback-analysis.json
```

Files still outside the admitted AAC shapes therefore retain fallback behavior;
this round proves their named refusal, not an improvement to fallback acoustic
latency. Fresh WAM seek → restart and device/acoustic timestamps remain gaps.
