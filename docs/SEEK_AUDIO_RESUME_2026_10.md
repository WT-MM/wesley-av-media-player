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
