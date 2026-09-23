# WAM offline ASR bake-off — 2026-09-22/23

**Status: complete.** All three available engines ran the full matched corpus (320 files × 3 repetitions) on 2026-09-23 between 02:10 and 03:31. Apple SpeechTranscriber (C) halves the word error rate of the shipped f16 Whisper base.en (A) and aligns timestamps three times more tightly; Whisper on Metal finishes a 300 s file about twice as fast end to end and is the only engine available below macOS 26. The CoreML encoder variant (B) gives no wall-clock gain over Metal. Implemented selection: Apple on macOS 26+ when its locale asset is ready, bundled Whisper CPU elsewhere; Metal is an opt-in with a no-progress watchdog and one CPU retry. Do not ship B. Caveats: LibriSpeech read speech, not media audio; energy inferred from CPU time, not metered.

## Environment and inputs

Apple M3 Max (`Mac15,8`), 16 logical CPUs, macOS 26.3.1 (a), build 25D771280a; Xcode's installed Speech Swift interface identifies Swift 6.3.2 and an SDK targeting 26.5. The Apple tool explicitly targets macOS 26.0; B retains WAM's 13.3 deployment target. Approximately 12 GiB disk remained after preparation. No network or GUI was used.

| Corpus stratum | Files | Audio | Reference words | File duration |
|---|---:|---:|---:|---:|
| LibriSpeech test-clean short | 300 | 2,226.045 s | 5,988 | 1.485–33.910 s |
| Same-speaker concatenated long | 20 | 6,089.330 s | 16,305 | 300.215–319.545 s |

Selection seed is 20260922. The fixed manifest contains exact WAV SHA256, source IDs, references and cumulative utterance boundaries. Long files join consecutive numeric chapter/utterance IDs of one speaker without added silence. These are clean read-speech tests, not evidence about movie soundtracks, overlapping dialogue, accents outside the corpus, music or multilingual performance. Short and long selections may overlap and are scored separately.

The shipped f16 model is 147,964,211 bytes, SHA256 `a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002`, matching `scripts/fetch_whisper_model.sh`. The staged source archive checksum matches the pinned build script. B is built from that source with the sole build-script addition `-DWHISPER_COREML="${WAM_WHISPER_COREML:-OFF}"`; default builds remain unchanged.

**Baseline correction:** `src/caption_service.hpp` defaults `use_gpu=false`; `src/qt/player_controller.cpp:3317` explicitly sets it false, and `src/caption_service.cpp` appends `-ng`. The requested A therefore measures a GPU-enabled alternative using the shipped binary, not the current UI default. The source documents a possible Metal hang as the reason for the CPU default. The bake-off does not silently change it.

## Measurements

An em dash means unavailable, not zero. Quiet gate: the harness starts a run only when no compiler/linker/build process is running and the one-minute load average is below `QUIET_LOAD` = max(4, logical CPUs / 2) = 8 on this 16-core host (the first 84 records were taken under the original threshold of 4; the host idles near load 5 with a browser, WindowServer and a remote-desktop agent, which stalled the original gate to about one record per minute). The gate retries every 30 seconds and persists every observation (`quiet.jsonl`); the complete chain recorded 20 waits across 2,883 records (2,880 steady-state plus three tagged first runs). Longer load averages are retained for context.

| Engine | Stratum | Complete files × repeats | WER | Median wall/file | Median RTF | CPU user+sys/file | Peak RSS |
|---|---|---:|---:|---:|---:|---:|---:|
| A: shipped Whisper Metal | short / long | 300 × 3 / 20 × 3 | 5.03% / 4.49% | 0.36 s / 4.22 s | 0.060 / 0.014 | 0.28 s / 5.70 s | 378 / 478 MB |
| B: CoreML encoder + Metal decoder | short / long | 300 × 3 / 20 × 3 | 5.08% / 4.51% | 0.42 s / 4.16 s | 0.070 / 0.014 | 0.31 s / 4.49 s | 391 / 490 MB |
| C: SpeechAnalyzer/Transcriber (client process only; see CPU note) | short / long | 300 × 3 / 20 × 3 | 2.49% / 2.45% | 1.34 s / 7.99 s | 0.230 / 0.026 | 0.03 s / 0.66 s | 18 / 20 MB |
| D: CPU, optional | short / long | not run | — | — | — | — | — |

| Engine | First-caption latency, long | Model load | First-observed CoreML load/specialization | Steady CoreML load | Long-form timestamp alignment |
|---|---:|---:|---:|---:|---:|
| A | 0.61 s (short 0.34 s) | 0.07 s | n/a | n/a | boundary median 1.100 s |
| B | 0.65 s (short 0.39 s) | 0.07 s | 0.03 s (already specialized) | 0.02 s | boundary median 1.075 s |
| C | 1.12 s (short 1.14 s) | prepareToAnalyze 0.99 s per process (median; bimodal 1 s / 3 s) | n/a | n/a | boundary median 0.350 s |

All accepted steady-state timing values require three process invocations per file. Tables use the median across files of their three-run medians; WER is corpus-weighted, not a mean of file percentages. Raw records retain each file and each repetition. End-to-end process wall time includes startup, inference and SRT writing but excludes corpus preparation/audio extraction; WAM's user-visible caption delay would also include extraction. CPU seconds/RSS come from `/usr/bin/time -l`. For C they would exclude some system speech-service resource consumption, so cross-engine CPU comparisons are incomplete.

The first invocation is separately tagged `first`, on a long file. B's upstream loading/loaded interval includes model specialization if any; the supplied `.mlmodelc` is already compiled, and that interval cannot isolate compiler work from other CoreML initialization. Existing OS caches are not deleted, so even a completed first invocation would be a first-observed measurement, not a guaranteed factory-cold measurement. The upstream ggml model-load timer is separately captured and is not total readiness latency.

Timestamp analysis retains both nearest-boundary distance and text-anchored start error with matched-boundary coverage. A segment that begins mid-utterance must not be judged inaccurate merely because it is far from the nearest file boundary. Text anchors require at least three consecutive matching words; only segment starts aligned to the first reference word of an utterance yield a boundary error. These corpus boundaries include natural leading silence and are not precise acoustic word onsets.

## Apple availability and precision findings

The compiled Swift tool successfully probes the local framework outside the sandbox. `SpeechTranscriber.isAvailable` is true; its canonical en-US locale is `en_US`. `installedLocales` lists en_US and eight other English variants, **but `AssetInventory.status(forModules:)` returns `supported`, not `installed`, for the actual time-indexed progressive transcriber module**. The offline tool exits 78 before analysis and never calls a download API. Installed locale enumeration alone is therefore insufficient readiness evidence. Inside the sandbox the same probe reports no installed locales and `unsupported`; that result is retained as an environment limitation rather than a hardware finding.

At first use the app should resolve an equivalent supported locale, inspect module-specific inventory status, reserve the locale, obtain `AssetInventory.assetInstallationRequest(supporting:)`, and if non-nil use `downloadAndInstall()` with its progress and error handling. It should recheck readiness and call `prepareToAnalyze`; neither a locale list nor an OS version is enough. That installation cannot be completed in this offline run. Do not promise an immediate first-use Apple path on a machine without the asset. The SDK's on-device API availability is macOS 26.0; there is no SpeechAnalyzer fallback on macOS 13.3–15.

The requirement “f16 everywhere” needs a precise qualification. No model was quantized: Whisper uses the shipped f16 weights and the staged CoreML metadata reports `storagePrecision: Float16`. That same metadata reports `computePrecision: Mixed (Float16, Float32, Int32)` and Float32 input/output; upstream CoreML glue copies float buffers. It would be false to label this strictly f16 arithmetic throughout. Apple's model weights/precision are opaque through the public Speech API, so C cannot be certified as f16. Upstream `src/coreml/whisper-encoder.mm` sets `MLComputeUnitsAll`; CoreML may schedule on ANE, GPU or CPU, and successful model loading alone does not prove ANE use.

`sudo -n powermetrics` returned **“a password is required.”** ANE/GPU power could not be metered. CPU user+sys is the requested proxy, not joules or a defensible energy winner. CPU-only inference is not inherently the energy floor; slower execution can consume more total energy even with lower instantaneous power.

**Asset status resolved (2026-09-23).** After `AssetInventory.assetInstallationRequest(supporting:)` + `downloadAndInstall()` completed in a separate process, `AssetInventory.status(forModules:)` still reported `supported` for the same module while `SpeechTranscriber.installedLocales` listed `en_US`; transcription then succeeded. The tool therefore treats the locale as ready when `status == .installed` **or** `installedLocales` contains it, and reserves the locale first. An app must not gate on `status(forModules:)` alone.

**Per-process prepare.** `prepareToAnalyze` costs a median 1.02 s per process (n = 961; 639 runs near 1 s, 252 near 3 s, max 10.8 s). It is not caused by the reservation: a variant without `AssetInventory.reserve` measured the same 0.99–1.02 s over six interleaved runs. A caption service that keeps one analyzer alive pays it once.

## Packaging and criterion decisions

| Candidate | Measured engine size | Additional model payload | Minimum intended macOS | Qualification |
|---|---:|---:|---|---|
| A / D | 3,235,552 bytes | 147,964,211 bytes | 13.3 | Shared shipped executable and model |
| B | 3,230,600 bytes | Same model + 41,259,062 bytes CoreML encoder | 13.3 | Built deployment target; oldest-OS runtime untested |
| C benchmark tool | 91,888 bytes | OS-managed asset, size unknown | 26.0 | Tool size is not final integration size; fallback still required |

| Criterion | Winner / conclusion |
|---|---|
| Accuracy | **C.** Corpus-weighted WER short/long: C 2.49% / 2.45%; A 5.03% / 4.49%; B 5.08% / 4.51% (A and B share weights; the difference is decoder nondeterminism). |
| Speed | **A/B for throughput.** 300 s file end to end: A 4.22 s, B 4.16 s, C 7.99 s of which about 1.0 s is per-process prepare; all exceed 35× real time. Short files: A 0.36 s vs C 1.34 s, dominated by C's prepare. |
| First-caption latency | **A for a cold process; equal once warm.** Long files: A 0.61 s, B 0.65 s, C 1.12 s, of which prepare is 0.99 s; C's first partial arrives about 0.1 s after prepare, and a long-lived analyzer pays prepare once per session. |
| Energy | **C by CPU proxy, unmetered.** CPU user+sys per 300 s file: A 5.70 s, B 4.49 s, C 0.66 s in the client; no speech daemon (`corespeechd`, `localspeechrecognition`, `axassetsd`) accrued CPU time during a C run, consistent with Neural Engine execution (`aned` present). `powermetrics` needs root, so joules were not measured. |
| Incremental application bundle | C adds only a Swift adapter (91,888-byte tool as a bound); A/B need the 148 MB model already shipped; B adds a 41 MB encoder for no measured gain. |
| Total offline deployment payload | A smallest among complete engines (shipped model, no download); C relies on the OS-managed asset, which was `supported` but not installed on this machine until an explicit `downloadAndInstall`. |
| Minimum macOS | A/B run at 13.3; C requires 26.0, so A remains mandatory as the fallback. |

Apple's claim tested: **competitive accuracy holds and exceeds** (half the WER of Whisper base.en on clean read speech, with tighter timestamps); **faster does not hold end to end** against Whisper base.en on Metal for batch transcription of a file (about half the throughput), although C does its work with almost no attributable CPU. Read speech is not media audio: a representative movie/podcast corpus remains a promotion gate, as does a controlled cold-cache prepare measurement.

## Implemented caption architecture

`CaptionService` now selects a backend below its existing validation, extraction,
staging, verification and atomic commit transaction. `CaptionBackend` supplies
readiness, asynchronous preparation and transcription, timed final/volatile
segments, progress, cancellation and off-main finish. Whisper preserves its
subprocess argv and CPU default. Its optional Metal path has a timestamp-progress
watchdog, verified process-group teardown and one CPU retry. There is no engine D
measurement in `asr-evidence.json`; CPU remains the reliability default, not a
measured speed or energy winner.

The availability-gated Swift adapter is exposed through the opaque, versioned
`WAMCaption.h` C ABI at WAMKit. The build probes SDK support and otherwise compiles
a tested unavailable stub. Speech is weak-linked and all new API use is guarded
for macOS 26. Readiness reserves the supported equivalent locale and accepts
inventory `installed` OR membership in `installedLocales`. An unready asset prompts
once per service for a named, one-time on-device language download of unknown
size. Only explicit consent starts OS installation; decline or failure uses
Whisper. Progress and cancellation use the existing caption flow.

One prepared analyzer is retained across successful requests. **A correctness
finding changes the proposed module lifetime:** on macOS 26.3.1, reusing the same
transcriber corrupts the first sentence of a repeated file. Context resets,
same-module resets and silence padding did not fix it. Replacing the transcriber
module between files while retaining the analyzer did, without another call to
prepare. The real-file proof compares complete cold/warm SRTs. This deviation and
its reproduction are documented in [CAPTION_ENGINES.md](CAPTION_ENGINES.md).

Streaming input is bounded Int16 PCM in one-second chunks. Finalization uses the
last sample returned by `analyzeSequence`; progress comes from result audio time.
Volatile ranges replace earlier volatile results. Generation-filtered callbacks
copy payloads off-main into a bounded recent-segment status snapshot. Final text
is written only to the service's staging SRT. Cancellation cancels the feeding and
result tasks, calls `cancelAndFinishNow`, and awaits cleanup off-main. Window
teardown retires CaptionService on a worker, leaving the playback path untouched.

### Validation and remaining gaps

Policy, consent/fallback, cancellation, revisions, generation isolation, staging,
SDK absence, process-group watchdog retry, C/Objective-C/Swift framework imports,
and real-file warm reuse have runnable checks. A paired quiet GUI proof captures
native playback and UI responsiveness with captioning active. Exact commands,
results and changed files are in
[CAPTION_ENGINE_VALIDATION.md](CAPTION_ENGINE_VALIDATION.md).

Remaining gaps: no physical older-OS run, no actual asset download test (the
installed locale was preserved), no multi-hour memory-growth or idle-eviction
policy, no streaming extraction, and no rendering partial captions over playback
before the final commit. Whisper interim events still parse CLI timestamps rather
than a structured callback API. The persistent-transcriber proposal is not shipped
because of the reproduced corruption; the analyzer/model preparation is retained.
Movie/podcast accuracy, controlled cold-cache preparation and authorized power
metering remain promotion work; LibriSpeech and CPU proxies do not settle those.

## Artifacts and reproduction

Harness: `tools/asr-bench/README.md`, `bench.py`, `apple-transcribe.swift`, `build.sh`, `test_bench.py`. Five self-tests pass. Built tools: `/private/tmp/wam-asr-scratch/whisper-coreml` and `/private/tmp/wam-asr-scratch/apple-transcribe`. Corpus manifest, raw runs, model metadata, build logs, asset probe, gate history and provenance hashes are under `/private/tmp/wam-asr-scratch`; use `bench.py summarize` to derive the numeric summary after accepted runs exist. The original bake-off changed only its allowed harness/documentation paths and made no commit or index update. Caption service implementation and validation followed on `caption-service`; see the implementation report linked above.
