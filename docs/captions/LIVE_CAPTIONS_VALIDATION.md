# Live captions validation — 2026-09-23

Working tree: `/private/tmp/wam-asr`, branch `live-captions`. Maintainer commits;
no index, commit, stash, reset or checkout operations were performed. No network
was used. All repository edits are under `src/`, `tests/`, and `docs/`; all scratch
artifacts are under `/private/tmp/wam-asr-scratch`. Frozen files and the native
video/audio pipeline, decode ladder, bake-off tools and sibling repositories are
unchanged.

## Implementation and decisions

- Both backends publish worker-side segment snapshots. Live state keeps the
  latest 512 ordered segments, each capped at 4,096 bytes on a UTF-8 boundary.
  Half-open time ranges replace overlapping volatile text; overlapping late
  revisions cannot change a final range. Apple retains full final text for SRT.
- A request-owned Qt mailbox holds one pending snapshot and coalesces queued
  signal notifications. Its receiver uses a try-lock and queued retry, never
  waits for the producer, and rejects retired bridges/media identities. UI status
  polling also uses a try-lock and skips a busy publication rather than waiting. The
  existing selectable subtitle source and QML plain-text overlay render the
  live cues. User Off/track selections are respected after initial selection.
- After atomic SRT commit, the service worker reads/parses the file. A queued
  snapshot swaps the same source's cues and label from Live Captions to Generated
  Captions without clearing the line or creating a duplicate track. Committed
  tracks retain normal subtitle bounds (65,536 cues / 8 MiB text; 16 MiB input
  cap), allowing seeks through the complete file. No final-file I/O or worker
  join was added to the UI path; the previous completion-time join was removed.
- Whisper stdout and stderr have separate pipes. A bounded incremental stdout
  line reader handles fragmented reads, CRLF and EOF without newline. Complete
  timestamp/text records feed both live events and the existing caption-time
  watchdog. Stderr cannot advance its watermark. The Whisper argv builder is
  unchanged, including Metal default and single CPU retry on a watchdog timeout.
- Apple expires the prepared analyzer, module, result reader and locale
  reservation after **30 seconds idle**. A new query cancels the timer and waits
  off-main for any in-progress eviction before preparing again. Failure paths
  that never reach transcription also retire their backend off-main. A generation
  guard rejects a cancelled timer that already returned from sleep but has not
  yet reached its actor hop, protecting newly admitted requests. A real
  production-deadline test proves re-preparation, without a shortened test timer.

## Build and automated checks

Exact application build command, repeated during implementation (all succeeded):

```sh
cmake --build /private/tmp/wam-asr-scratch/gui-stage --parallel 4
```

Logs: `live-build.log`, `live-build-final.log`, `live-build-3.log` through
`live-build-11.log` in the scratch root. Host Homebrew Qt emits newer-macOS linkage
warnings; no claim is made about those binaries running on macOS 13.

```sh
TMPDIR=/private/tmp/wam-asr-scratch ctest \
  --test-dir /private/tmp/wam-asr-scratch/gui-stage \
  -R '^(caption_|player_controller_lazy|subtitle_text|wamkit_abi|wamkit_headers)' \
  --output-on-failure
```

**7/7 passed, 8.58 seconds** on the final build, receipt
`live-checks-complete.log`. The preceding atomic-phase and idle-generation builds
also passed in 8.48 / 9.07 seconds (`live-checks-transcribing.log`,
`live-checks-release.log`). Earlier expanded runs passed in 12.00 and 9.09
seconds (`live-checks.log`, `live-checks-final.log`). Earlier focused subsets
also passed (`live-unit.log`, `live-unit-final.log`). Coverage includes:

- Synthetic Whisper stdout split between a timestamp and text, CRLF, EOF without
  newline, ordered live delivery before commit, and timestamp-shaped stderr
  rejection. Existing argv, watchdog/process-group retry, cancellation and
  atomic destination preservation tests pass.
- Volatile replacement, final revision rejection, stale backend generations,
  consent/fallback, and a 601-segment fixture retaining exactly the latest 512.
- Worker publication is queued to the UI; 1,000 publications enqueue one
  notification. Live-to-committed replacement preserves the source id, creates
  one source, and honors Off/media clearing. Existing subtitle parser tests pass.
- Framework ABI and C/Objective-C/Swift header checks pass.

## Apple service: three files, RSS, idle eviction

```sh
mkdir -p /private/tmp/wam-asr-scratch/live-home /private/tmp/wam-asr-scratch/live-service
HOME=/private/tmp/wam-asr-scratch/live-home TMPDIR=/private/tmp/wam-asr-scratch \
  /private/tmp/wam-asr-scratch/gui-stage/wam_caption_proof \
  /private/tmp/wam-asr-scratch/audio/7176-92135-0014.wav \
  /private/tmp/wam-asr-scratch/live-service \
  /private/tmp/wam-asr-scratch/audio/7176-92135-0021.wav \
  /private/tmp/wam-asr-scratch/audio/7176-92135-0025.wav
```

Final receipt: `live-service/release.log` (generation-safe idle timer). Ordinary OS access was necessary to see
already installed Speech assets. An initial sandboxed attempt could not see them
and failed fallback model discovery; it performed no download. The first ordinary
OS run is preserved in `live-service/run.log`; its three-file RSS was 9,224,192 →
20,250,624 bytes and its idle RSS was 20,103,168 bytes.

| Final run measurement | Result |
|---|---:|
| RSS before first file | 9,224,192 bytes |
| RSS after file 1 | 19,693,568 bytes |
| RSS after file 2 | 19,939,328 bytes |
| RSS after file 3 | 20,348,928 bytes |
| Total growth | **11,124,736 bytes (10.609375 MiB)** |
| Growth after file 1 | **655,360 bytes (0.625 MiB)** |
| RSS after 32-second idle wait | 20,201,472 bytes |
| Released during idle | 147,456 bytes |
| File 1 / 2 / 3 time | 2.13411 / 0.175286 / 0.675677 s |
| Prepare count per file | 1 / 0 / 0 |
| Next request after idle | success, prepare count 1 |
| Cancel call / teardown | 0.0005 / 0.990875 ms |
| Old destination / reuse after cancel | preserved / passed |

These are resident bytes from `mach_task_basic_info` for the service test process,
not peak RSS and not Apple-managed external Speech processes. **Most growth remains
resident after eviction.** This short check does not establish whether that retained
memory is allocator/framework caching or a leak, nor does it prove multi-hour
stability. No growth was subtracted or hidden. The analyzer release/reprepare is
proven separately by the production timer and preparation-count assertion.

## GUI proof protocol

`tests/caption_gui_proof.py` starts playback, requests captions at 1,000 ms, and
checks the actual QML `subtitleText` item's effective visibility and text across
two presented overlay frames. It records first-live time while the job is still
running and committed-track time. The final proof reads an atomic service
transcription-phase flag, not the UI status timer, to require that inference
has not finished when the live text is observed. Track changes request a proof-only overlay
frame because identical committed text otherwise correctly produces no Qt redraw.
The production QML styling and native render path are unchanged.

Each trial supplies `WAM_TEST_BACKGROUND=1`, `WAM_TEST_MUTED=1`,
`WAM_TEST_GEOMETRY=480x270+2400+1000`, a new isolated HOME, an eight-second quit,
and a unique telemetry run id. The harness verifies native telemetry's PID,
run id, executable hash and asset hash against its launched child, retains the
reported process-start identity, and records that identity beside an exclusive per-child metrics file. Raw
playback samples do not embed those identity fields; their association is made by
this exclusive launch/receipt, not by pretending the sample schema contains them.
All usable samples must have zero late-frame discards and audio underruns. The
existing UI timer threshold remains **<250 ms**, with >400 samples per trial.

Before **each** GUI launch, the harness logs `ps -axo pid=,comm=` compiler/linker
matches and `os.getloadavg()[0]`; it polls every 30 seconds until there are no
compiler/linker processes and one-minute load is below 8. Only its own children
are waited on or terminated. All GUI binaries are in the named build tree.

Final measurements and command receipts follow below.

## Failed attempts retained

- `live-gui-apple`: first live 2,359 ms; both playback counters zero. The original
  proof required a committed redraw even when text did not change and therefore
  lacked its committed-screen receipt. Fixed the proof-only frame request; no
  production animation/redraw policy was added.
- `live-gui-apple-final`: baseline had only null playback counters and a 306,250 ms
  maximum UI timer gap. Rejected before the caption trial; no smoothness claim is
  made for that launch. The cause of the long pause was not established.
- `live-gui-apple-verified`: first live 3,084 ms, committed 3,534 ms; zero late-frame
  discards and audio underruns. Caption UI maximum gap **330 ms** failed the 250 ms
  threshold (baseline 111 ms). This variability remains part of the evidence.
- `live-gui-whisper`: selected scratch `build/bin/whisper-cli`, later found to have
  `WHISPER_COREML=ON`. It reached transcription but produced no SRT in eight seconds;
  shutdown cancelled it. This was not accepted as a Metal-only proof.
- Building the separate Metal-only CLI initially failed because installed ccache
  references missing `libfmt.11.dylib`. Reconfigured with `GGML_CCACHE=OFF`; no
  system package or network change was made.

## Remaining limits

Extraction still precedes transcription. Full-file backend export memory is not
limited to the live window. There is no system memory-pressure observer, multi-hour
memory proof, Windows runtime execution, pre-26 macOS execution, fresh Speech asset
installation, movie/podcast accuracy study or metered-power measurement in this
change. The GUI measurements are short local checks and retain failed attempts;
they are not statistical guarantees against scheduling spikes on other workloads.

## Offline Whisper runtime and service commands

The existing scratch CLI was CoreML-enabled. A separate Metal-only static CLI
was built from the already present source, without changing that source or argv:

```sh
cmake -S /private/tmp/wam-asr-scratch/whisper \
  -B /private/tmp/wam-asr-scratch/gui-stage/proof-whisper -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_COREML=OFF -DWHISPER_CURL=OFF -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF -DGGML_METAL=ON -DGGML_CCACHE=OFF
cmake --build /private/tmp/wam-asr-scratch/gui-stage/proof-whisper \
  --parallel 4 --target whisper-cli
```

The initial configure omitted only `-DGGML_CCACHE=OFF`; its build failed as
recorded above. Final configure/build logs are `live-whisper-configure-final.log`
and `live-whisper-build-final.log` (48 build steps, success).

```sh
mkdir -p /private/tmp/wam-asr-scratch/live-whisper-service
HOME=/private/tmp/wam-asr-scratch/live-whisper-cli-home \
TMPDIR=/private/tmp/wam-asr-scratch WAM_CAPTION_PROOF_WHISPER=1 \
WAM_WHISPER_CLI=/private/tmp/wam-asr-scratch/gui-stage/proof-whisper/bin/whisper-cli \
WAM_WHISPER_MODEL=/private/tmp/wam-asr-scratch/models/ggml-base.en.bin \
  /private/tmp/wam-asr-scratch/gui-stage/wam_caption_proof \
  /private/tmp/wam-asr-scratch/audio/7176-92135-0014.wav \
  /private/tmp/wam-asr-scratch/live-whisper-service
```

Passed three identical SRT comparisons and three live-segment results each;
0.475152 / 0.442941 / 0.441279 s. Parent RSS 9,224,192 → 9,912,320 bytes
(+688,128 bytes); this excludes the separate Whisper process. Receipt:
`live-whisper-service/run.log`.

Two bounded standalone CLI diagnostics used exactly:

```sh
/private/tmp/wam-asr-scratch/gui-stage/proof-whisper/bin/whisper-cli \
  -m /private/tmp/wam-asr-scratch/models/ggml-base.en.bin \
  -f /private/tmp/wam-asr-scratch/audio/7176-92135-0014.wav \
  -t 16 -osrt -of /private/tmp/wam-asr-scratch/live-whisper-diagnostic -l auto
HOME=/private/tmp/wam-asr-scratch/live-whisper-cli-home \
TMPDIR=/private/tmp/wam-asr-scratch \
  /private/tmp/wam-asr-scratch/gui-stage/proof-whisper/bin/whisper-cli \
  -m /private/tmp/wam-asr-scratch/models/ggml-base.en.bin \
  -f /private/tmp/wam-asr-scratch/audio/7176-92135-0014.wav \
  -t 16 -osrt -of /private/tmp/wam-asr-scratch/live-whisper-isolated -l auto
```

Both exited zero under a Python subprocess wrapper with a 35-second deadline;
PIDs 35187 and 35505. Stdout/stderr receipts use the corresponding output prefix.
A later gated diagnostic GUI pair also passed (Whisper live 463 ms, committed
471 ms; baseline/caption UI gaps 121/103 ms; all A/V counters zero). It recorded
one `ps -axo pid=,ppid=,command=` snapshot after transcription started, proving
child 35905 belonged to GUI 35901 and used the intended CLI/model and unchanged
argv. Receipt: `live-gui-whisper-diagnostic`, with
`live-gui-whisper-children.txt`. The earlier Metal-only pair
`live-gui-whisper-metal` still failed to finish captions in eight seconds, despite
baseline/caption UI gaps 107/121 ms and zero A/V counters. The intermittent slow
GUI transcription was not reproduced by the standalone service check; no claim
is made that the warm successful rerun explains or eliminates that failure.

A further Apple pair `live-gui-apple-pass` passed with live/committed 1,601/2,073 ms,
baseline/caption UI gaps 118/144 ms, and zero A/V counters. The final source change
after these pairs suppresses a prior bitmap subtitle when a generated text track
is selected; final-binary pairs are recorded below.

## Final streaming fixture and exact GUI commands

The final fixture is 90 seconds, giving Whisper multiple analysis chunks. This
avoids treating an eight-millisecond handoff on a 16-second file as sufficient
proof that text was displayed during inference. The source is pre-existing local
speech; nothing in the protected assets directory was read or modified.

```sh
/opt/homebrew/bin/ffmpeg -hide_banner -loglevel error \
  -f lavfi -i color=c=black:s=320x180:r=30 \
  -i /private/tmp/wam-asr-scratch/audio/long-121.wav -t 90 \
  -c:v libx264 -threads 2 -pix_fmt yuv420p -c:a aac -y \
  /private/tmp/wam-asr-scratch/live-90s.mp4
python3 tests/caption_gui_proof.py --engine apple \
  --app /private/tmp/wam-asr-scratch/gui-stage/WAM.app/Contents/MacOS/WAM \
  --asset /private/tmp/wam-asr-scratch/live-90s.mp4 \
  --output /private/tmp/wam-asr-scratch/live-release-apple
WAM_WHISPER_CLI=/private/tmp/wam-asr-scratch/gui-stage/proof-whisper/bin/whisper-cli \
WAM_WHISPER_MODEL=/private/tmp/wam-asr-scratch/models/ggml-base.en.bin \
  python3 tests/caption_gui_proof.py --engine whisper \
  --app /private/tmp/wam-asr-scratch/gui-stage/WAM.app/Contents/MacOS/WAM \
  --asset /private/tmp/wam-asr-scratch/live-90s.mp4 \
  --output /private/tmp/wam-asr-scratch/live-release-whisper
```

Each command's stdout/stderr was redirected to the same scratch output prefix
plus `.log`. Per-trial raw logs, metrics, isolated homes, gate records and
`results.json` are retained under each output directory. All GUI proofs used
ordinary OS access, because installed Speech assets are hidden by the development
sandbox. No download consent was given and no download took place.

Earlier GUI commands were exactly the same script/app options with the following
engine, asset and output substitutions (the original short fixture is
`/private/tmp/wam-asr-scratch/caption-proof/video.mp4`):

| Engine | Asset | Scratch output suffix | CLI override |
|---|---|---|---|
| apple | original short | live-gui-apple | none |
| apple | original short | live-gui-apple-final | none |
| apple | original short | live-gui-apple-verified | none |
| whisper | original short | live-gui-whisper | `/private/tmp/wam-asr-scratch/build/bin/whisper-cli` |
| whisper | original short | live-gui-whisper-metal | final Metal-only CLI above |
| whisper | original short | live-gui-whisper-diagnostic | final Metal-only CLI above |
| apple | original short | live-gui-apple-pass | none |
| apple | original short | live-final-apple | none |

Both Whisper overrides used the same `WAM_WHISPER_MODEL` above. The diagnostic
wrapper additionally recorded one child process snapshot; it did not change
caption argv or the quiet gate. `live-final-apple` passed on the prior build with
live/committed 1,904/2,355 ms; the final longer-fixture proof adds the stricter
atomic transcription-phase assertion.

Final SHA256 identities:

- App: `1a9c889b5595902aef17fe2efffce3c7b75359235f794b4320839070913622a0`
- 90-second video: `dc77d26cc52054b9ab79bb9b8f59ed72975cd3c6f4e6c98bd0f371584194e57a`
- Metal-only CLI: `7196a62c6bca3bdb4427e543d44c9d1e1806adb5d5059a8f0ecb5c37f21de4af`
- Model: `a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002`

The earlier atomic-phase 90-second-fixture pairs are preserved as `live-90-apple`
and `live-90-whisper`: live/committed times 1,504/3,296 ms and 561/1,082 ms,
caption UI gaps 104/97 ms, zero A/V counters. The final pairs below repeat after
the idle-timer generation guard and nonblocking UI status polling.

## Final measured results

Both final harness commands exited **0**. Live receipts require the backend still
transcribing; committed receipts come from the same selected source after its cue
swap. The one-source/no-blank intermediate state is also covered by the Qt source
replacement test. Whisper's displayed text was identical across its handoff.

| Measurement | Apple baseline | Apple captions | Whisper baseline | Whisper captions |
|---|---:|---:|---:|---:|
| First live on screen (ms) | — | 1956 | — | 596 |
| Committed on screen (ms) | — | 3758 | — | 1126 |
| Maximum UI gap (ms) | 114 | 109 | 124 | 118 |
| UI samples | 787 | 827 | 747 | 744 |
| Launched GUI PID | 39507 | 39734 | 40303 | 40323 |
| Exit code | 0 | 0 | 0 | 0 |
| Late-frame discards | 0 | 0 | 0 | 0 |
| Audio underruns | 0 | 0 | 0 | 0 |
| Clock rate | 1 | 1 | 1 | 1 |

Apple/Whisper committed SRT sizes: **1,213 / 1,468 bytes**. Gate load averages
were **3.4761 / 3.2847** for Apple baseline/captions and **3.7700 / 3.7881** for
Whisper baseline/captions, with **zero compiler/linker processes** at all four
launches. The final Apple caption trial also waited one 30-second poll for
compiler processes to disappear. Earlier gates above 8 waited in 30-second increments; their records
are retained rather than omitted.

These passing final receipts do not erase the earlier 330 ms Apple UI gap,
invalid baseline, or incomplete eight-second Whisper attempts described above.
The test demonstrates the requested local streaming and handoff behavior under
its measured conditions; it does not establish cold-cache or workload-wide
performance guarantees.

## Final audit and changed files

```sh
git branch --show-current
git diff --check
git diff --name-only -- src/media/native_media_source.hpp \
  src/media/native_playback_contract.hpp tests/native_audio_converter_test.mm \
  'tests/native_audio_session_test*'
git status --short
```

Branch is `live-captions`; whitespace check passes; frozen-file diff is empty.
Every changed file is listed below. No source under `src/media/`, no native
pipeline or hot-path file, and no `CMakeLists.txt` was changed.

- `docs/captions/CAPTION_ENGINES.md`
- `docs/captions/CAPTION_ENGINE_VALIDATION.md`
- `docs/captions/LIVE_CAPTIONS_VALIDATION.md`
- `src/caption_backend.hpp`
- `src/caption_service.cpp`
- `src/caption_service.hpp`
- `src/qt/main.cpp`
- `src/qt/player_controller.cpp`
- `src/qt/player_controller.hpp`
- `src/qt/subtitle_sources.cpp`
- `src/qt/subtitle_sources.hpp`
- `src/wamkit/apple_caption.swift`
- `tests/caption_backend_test.cpp`
- `tests/caption_engine_proof.cpp`
- `tests/caption_flow_test.cpp`
- `tests/caption_gui_proof.py`
- `tests/caption_service_test.cpp`
- `tests/player_controller_lazy_test.cpp`
