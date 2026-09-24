# Caption engine implementation report — 2026-09-23

Branch: `caption-service`. No commit or index operation was performed.

## Decisions and deviations

- Select ready Apple Speech on macOS 26+, with bundled Whisper as fallback.
  Translation requests remain on Whisper; Apple's default locale is en-US.
  `asr-evidence.json` was checked again at the end: its summary contains A/B/C,
  **no D**. CPU (`-ng`) remains the default for reliability, not a CPU timing claim.
- Keep Whisper subprocess isolation and its exact argument construction. Metal
  opt-in is protected by advancing-caption-time detection, verified process-group
  TERM/KILL, and one CPU retry. A deferred reaper prevents a driver-stuck child
  from blocking the caption worker after KILL. No CoreML encoder is shipped.
- Keep validation, complete PCM extraction, same-directory staging, non-empty
  output checks, overwrite protection and atomic commit in CaptionService.
  Publish terminal status only after request-local workers and files are cleaned
  up. Retire the Qt controller's service off-main.
- The C++ backend contract exposes readiness, asynchronous prepare/start,
  progress/segment revisions, cancel and finish. The versioned C ABI carries
  borrowed strings and an opaque handle; callbacks copy payloads off-main.
  Recent UI segments are bounded at 512; final export text remains in the backend.
- Resolve the equivalent locale, reserve it, then accept inventory `.installed`
  **or** installed-locale membership. Prompt once per service before a one-time
  language download, name the language, and report unknown size honestly. Decline
  and installation/preparation failure use Whisper. Cancellation preserves the
  existing destination. No download was executed in this run.
- **Deviation from the requested persistent transcriber:** keep the analyzer and
  its preparation, but replace its module between files. Real repeated-file
  testing exposed corrupt text with a retained transcriber. Context reset,
  `cancelAnalysis`, same-module replacement and silence padding did not fix it;
  a fresh module on the prepared analyzer did. Removing the completed module
  closes its result sequence, giving an awaitable drain barrier before SRT commit.
  Prepare is still called only once per successful analyzer session.
- The file convenience API returns before results finish. Streaming also requires
  Int16 PCM (the module rejected Float32). The adapter uses bounded one-second
  chunks and finalizes through `analyzeSequence`'s returned last sample. Initial
  prototype probes that blocked on an exclusive file-end timestamp were stopped;
  only their own launched processes were controlled.
- SDK capability is compile-probed. The SDK-disabled build uses an asynchronous
  unavailable stub. The adapter targets macOS 13.3, weak-links Speech, and guards
  macOS 26 APIs. WAMKit exports and packages the new header. The Swift host builder
  gained an optional package staging path and a four-job limit so the offline
  package check could run wholly in scratch.

## Commands and outcomes

All build commands used at most four jobs. Scratch/stage paths below contain the
logs, binaries and proof artifacts. These are local paths, not committed fixtures.

### Application, framework, and unit checks

```sh
cmake -S . -B /private/tmp/wam-asr-scratch/gui-stage -G Ninja \
  -DWAM_BUILD_WAMKIT=ON -DWAMKIT_BUILD_HOST=OFF \
  -DWAM_ENABLE_AVFORMAT_STAGE=OFF -DWAM_ENABLE_AVCODEC_STAGE=OFF \
  -DWAM_ENABLE_SOFTWARE_VP8=OFF -DWAM_NATIVE_BENCHMARK_TELEMETRY=ON \
  -DCMAKE_BUILD_TYPE=Release
cmake --build /private/tmp/wam-asr-scratch/gui-stage --parallel 4 \
  --target wam WAMKit wam_caption_test wam_caption_backend_test \
  wam_caption_flow_test wam_caption_proof
ctest --test-dir /private/tmp/wam-asr-scratch/gui-stage \
  -R '^(caption_|wamkit_abi|wamkit_headers)' --output-on-failure
```

Passed: `caption_service`, `caption_backend`, `caption_flow`, `wamkit_abi`,
`wamkit_headers` (5/5). The service test includes a TERM-ignoring descendant,
watchdog CPU retry, default/GPU argv assertions, and cleanup-before-terminal
publication. The flow test covers ready/unavailable selection, consent, decline,
ask-once, failed install, cancelled download, stale events and volatile revisions.
The WAMKit export set is exactly 29 symbols; C11, Objective-C and Swift imports pass.

Host Homebrew Qt emits newer-OS linkage warnings. This is a macOS 26 local proof
build, not evidence that those particular Homebrew Qt binaries run on macOS 13.

### SDK absence / fallback

```sh
cmake -S . -B /private/tmp/wam-asr-scratch/no-speech-stage -G Ninja \
  -DWAM_BUILD_APP=OFF -DWAM_BUILD_WAMKIT=OFF \
  -DWAM_ENABLE_MACOS_NATIVE_VIDEO=OFF -DWAM_ENABLE_AVFORMAT_STAGE=OFF \
  -DWAM_ENABLE_AVCODEC_STAGE=OFF -DWAM_ENABLE_SOFTWARE_VP8=OFF \
  -DWAM_ENABLE_APPLE_CAPTIONS=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build /private/tmp/wam-asr-scratch/no-speech-stage --parallel 4 \
  --target wam_caption_test wam_caption_backend_test wam_caption_flow_test
ctest --test-dir /private/tmp/wam-asr-scratch/no-speech-stage \
  -R '^caption_' --output-on-failure
```

Passed 4/4, including `caption_sdk_absent`, which queries the actual unavailable
stub. This proves build/selection degradation without relying on a missing asset
on the current machine. It does not substitute for an actual older-OS launch.

### ABI, linkage, and Swift host package

```sh
python3 tests/wamkit_abi_test.py \
  /private/tmp/wam-asr-scratch/gui-stage/src/wamkit/WAMKit.framework/WAMKit \
  src/wamkit/exports.txt
WAM_TEST_SCRATCH=/private/tmp/wam-asr-scratch \
  python3 tests/wamkit_header_test.py \
  /private/tmp/wam-asr-scratch/gui-stage/src/wamkit/WAMKit.framework
TMPDIR=/private/tmp/wam-asr-scratch python3 scripts/build_wamkit_swift.py \
  --framework /private/tmp/wam-asr-scratch/gui-stage/src/wamkit/WAMKit.framework \
  --build /private/tmp/wam-asr-scratch/gui-stage \
  --stage-package /private/tmp/wam-asr-scratch/swift-package-stage
otool -l /private/tmp/wam-asr-scratch/gui-stage/wam_caption_proof
nm -m /private/tmp/wam-asr-scratch/gui-stage/wam_caption_proof | xcrun swift-demangle
```

Passed. The offline Swift host product built and its staged app passed codesign
verification. The caption proof binary has `minos 13.3`; Speech has
`LC_LOAD_WEAK_DYLIB`, and SpeechAnalyzer/SpeechTranscriber imports are weak external
symbols. The first framework header check caught a missing packaged header; adding
the header to both the target sources and public-header list fixed it. Header-test
scratch is now configurable and CTest places it under its build directory.

### Real SpeechAnalyzer service proof

```sh
mkdir -p /private/tmp/wam-asr-scratch/proof-home /private/tmp/wam-asr-scratch/caption-proof
env WAM_TEST_BACKGROUND=1 WAM_TEST_MUTED=1 \
  WAM_TEST_GEOMETRY=480x270+2400+1000 \
  HOME=/private/tmp/wam-asr-scratch/proof-home \
  /private/tmp/wam-asr-scratch/gui-stage/wam_caption_proof \
  /private/tmp/wam-asr-scratch/audio/7176-92135-0014.wav \
  /private/tmp/wam-asr-scratch/caption-proof
```

Run with ordinary OS access because the development sandbox hides the installed
Speech asset. No download was requested or performed. The two SRTs are identical,
contain two final segments, and use file-relative timestamps on both requests.
The SRT SHA256 is `4fb7b4e90cd35f29f219ca9c0dd84a0b68d170acc9ce8e34ad82ee57a6c68f1a`.
The final measured timings and cancellation receipt are recorded below. These are
integration checks, not another quiet-gated corpus benchmark.

### Quiet GUI proof

```sh
/opt/homebrew/bin/ffmpeg -hide_banner -loglevel error \
  -f lavfi -i color=c=black:s=320x180:r=30 \
  -i /private/tmp/wam-asr-scratch/audio/7176-92135-0014.wav \
  -shortest -c:v libx264 -threads 2 -pix_fmt yuv420p -c:a aac -y \
  /private/tmp/wam-asr-scratch/caption-proof/video.mp4
python3 tests/caption_gui_proof.py \
  --app /private/tmp/wam-asr-scratch/gui-stage/WAM.app/Contents/MacOS/WAM \
  --asset /private/tmp/wam-asr-scratch/caption-proof/video.mp4 \
  --output /private/tmp/wam-asr-scratch/caption-gui-final
```

Passed paired baseline/caption trials. The script supplies all three required
quiet seams, an isolated HOME per trial, identity-bound telemetry, and an orderly
8-second quit. It starts the actual controller's caption flow during playback.
Both trials had zero discarded late frames and zero audio underruns, with clock
rate 1. Apple captions were atomically saved and enabled (331-byte SRT). The
receipt in `caption-gui-final/results.json` retains executable/input hashes,
launched PIDs, status messages, heartbeat measurements and native playback samples.

### Other checks

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tools/asr-bench/test_bench.py
python3 tests/wamkit_dogfooding_test.py
git diff --check
git diff --name-only -- src/media/native_media_source.hpp \
  src/media/native_playback_contract.hpp tests/native_audio_converter_test.mm \
  'tests/native_audio_session_test*'
```

Bake-off self-tests passed 5/5. The native boundary audit passed. Diff whitespace
check passed; the frozen-file diff is empty. No native pipeline/decode/hot-path
source, recorder repository, bake-off source, media scratch repository or ports
repository was edited. Existing Apple assets were preserved.

## Remaining gaps

Actual pre-26 OS execution and fresh OS-asset installation are untested here;
SDK-disabled behavior and download control flow are tested. A transcriber cannot
be retained unchanged across independent files on this tested OS without the
reproduced text corruption; only the analyzer/preparation is retained. Extraction
still precedes analysis. The live-captions follow-up now overlays interim segments,
reads Whisper's per-segment stdout stream, and evicts Apple analyzers after 30
seconds idle; see `LIVE_CAPTIONS_VALIDATION.md`. Three-file RSS growth is measured
there, including retained growth after idle, but there is no multi-hour memory-growth
proof or system memory-pressure observer. Movie/podcast accuracy and metered power remain
outside this implementation's evidence.

## Measured receipts

Real-file service proof (16.02 s input): cold **2.42652 s**, warm **0.634729 s**;
identical SRTs. Cancel call **0.000417 ms**, teardown **10.7416 ms**, old destination
preserved, and reuse after cancellation passed. Receipt:
`/private/tmp/wam-asr-scratch/caption-proof/run.log`.

Final fresh-HOME GUI pair (same staged executable and input):

| Measurement | Baseline | Captioning |
|---|---:|---:|
| Maximum UI timer gap | 120 ms | 128 ms |
| UI timer samples | 801 | 747 |
| Discarded late frames | 0 | 0 |
| Audio underrun callbacks | 0 | 0 |
| Clock rate | 1 | 1 |
| Process exit | 0 | 0 |

App SHA256: `c861b60ec07fb3dc0c38d2f37a6a3b428f64237b62eec097da1678a719f6d9ed`. Video SHA256:
`75c28c4094c77e7120894f7b0e1b8d2d071d019cfbbfcfa2e2ec50f3c9f5c3f7`. Only launched PIDs 50586 and 50613
were controlled in this pair. The harness clears its previous output files and
creates a fresh HOME per trial, preventing stale SRTs or saved playback positions
from passing a rerun. This is a short smoothness regression check, not statistical
proof of performance on every machine or driver.

## Files changed

- `CMakeLists.txt`
- `docs/captions/ASR_BAKEOFF.md`
- `docs/captions/CAPTION_ENGINES.md`
- `docs/captions/CAPTION_ENGINE_VALIDATION.md`
- `scripts/build_wamkit_swift.py`
- `src/apple_caption_backend.hpp`
- `src/caption_backend.hpp`
- `src/caption_service.cpp`
- `src/caption_service.hpp`
- `src/qt/caption_download_prompt.hpp`
- `src/qt/caption_download_prompt.mm`
- `src/qt/main.cpp`
- `src/qt/player_controller.cpp`
- `src/qt/player_controller.hpp`
- `src/wamkit/CMakeLists.txt`
- `src/wamkit/CaptionBackend.cmake`
- `src/wamkit/apple_caption.swift`
- `src/wamkit/caption_stub.cpp`
- `src/wamkit/exports.txt`
- `src/wamkit/include/WAMKit/WAMCaption.h`
- `src/wamkit/include/WAMKit/WAMKit.h`
- `tests/caption_backend_test.cpp`
- `tests/caption_engine_proof.cpp`
- `tests/caption_flow_test.cpp`
- `tests/caption_gui_proof.py`
- `tests/caption_service_test.cpp`
- `tests/wamkit_header_test.py`
