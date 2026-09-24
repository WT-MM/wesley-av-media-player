# Caption engines

`CaptionService` owns validation, FFmpeg extraction to 16 kHz mono PCM, temporary
files, output verification and the same-directory atomic SRT commit. No playback
or decode code participates in engine selection. Backend operations and teardown
run off the UI thread. Only one request is admitted per service; cancel requests
an atomic stop without waiting. The Qt controller retires its service off-main.

## Selection and consent

The pure `selectCaptionEngine` policy chooses Apple Speech when available and
ready; otherwise it chooses bundled Whisper. Translation requests use Whisper.
The default Apple locale is en-US, matching the shipped English model and the
bake-off; explicit languages resolve with `supportedLocale(equivalentTo:)`.
`auto` remains Whisper's detection option on fallback, not Apple language detection.

Reserve the resolved locale before inspecting readiness. An asset is ready when
`AssetInventory.status(forModules:) == .installed` **or**
`SpeechTranscriber.installedLocales.contains(resolvedLocale)`. This OR is required:
the inventory can still report `supported` after another process installed it.
The download size is unknown, not zero.

An unready supported locale prompts once per service lifetime. The native sheet
names the language and a one-time on-device download, with **Download language**
and **Use Whisper** choices. Only an affirmative response enables
`assetInstallationRequest(supporting:)` and `downloadAndInstall()`. Its progress
appears in the existing caption status UI. Decline or preparation/download failure
uses Whisper; cancellation cancels the job, preserving the existing destination.
There is no automatic download at launch, during a readiness query, or in tests.
Closing and reopening the window creates a new service and permits another prompt.

Whisper runs on Metal by default. Engine D in `asr-evidence.json` measured the
CPU path (`-ng`) at 24.8 s per 300 s file against 4.2 s on Metal, 314 s of CPU
against 5.7 s, and a 2.2 s first caption against 0.6 s, at equal accuracy. The
documented Metal hang is bounded by the caption-time watchdog: a stalled Metal
process group is killed and the file is retried once on CPU. A caller can opt out
with `CaptionOptions::use_gpu=false`; there is deliberately no new GUI preference.
The argv otherwise remains unchanged. CoreML is not packaged.

## Isolation and progress

`CaptionBackend` exposes readiness, asynchronous prepare/start, progress and timed
segment revisions, nonblocking cancel, and off-main finish. Whisper stays in an
isolated subprocess. A bounded incremental reader consumes whisper-cli stdout's per-segment
`[hh:mm:ss.mmm --> hh:mm:ss.mmm] text` lines, without changing argv. It handles
fragmented reads, CRLF, and an unterminated last line; ignores malformed,
backward and duplicate ranges; and discards overlong lines (8 KiB). Stderr is
separately drained for diagnostics and cannot advance the watchdog. Accepted
segments drive both live captions and the watchdog's caption-time watermark.
Final output still comes from its staged SRT.

Metal execution has a 30-second deadline without an advancing caption timestamp.
Arbitrary diagnostic chatter does not reset it. Timeout sends TERM and then KILL
to the verified process group, clears the staging file, and retries **once** with
CPU. Cancellation does not retry. The group leader remains unreaped until the
last group signal, protecting PGID identity. If a kernel/driver defers SIGKILL,
a detached reaper waits for that already-signalled child; the caption worker
continues rather than blocking indefinitely in waitpid. This cannot force an
uninterruptible kernel operation to release resources immediately.

The Apple adapter reads pull-based one-second Int16 PCM chunks; Float32 input is
not supported by the streaming module even though the file convenience API
accepts it through conversion. Finalization uses the last sample returned by
`analyzeSequence`, not the file's exclusive end. `start(inputAudioFile:)` returning
does not mean its results have been delivered.

The analyzer is retained for warm reuse and `prepareToAnalyze` is paid once per
successful session. After 30 seconds idle following transcription, an actor-owned
cancellable timer releases the analyzer, result reader, module and locale reservation.
A new query cancels the timer and awaits any eviction already underway, then
reserves and prepares on demand. A timer generation guard also rejects cancellation
that arrived after sleep but before the actor hop. Failed/cancelled requests retire the backend
on the service worker, including failures before transcription could arm the timer.
This is an idle policy, not a system memory-pressure observer. **Implementation deviation:** the transcriber module is replaced
between independent files while the prepared analyzer remains alive. On this
macOS 26.3.1 machine, retaining the same transcriber changed a repeated file's
correct first sentence into “that... should be granted first…” and other corrupt
text. Resetting context, calling `cancelAnalysis`, setting the same module again,
and inserting two seconds of silence did not fix it. A fresh module installed
with `setModules` did; it does not call prepare again. Replacing the module closes the completed result sequence; the
adapter awaits that reader before signalling completion, so late final results
cannot cross a request boundary. The integration proof
compares the two complete SRTs, not just exit status or file size.

Volatile segments replace overlapping volatile time ranges; final segments remain
stable. ABI events carry generation, media times, UTF-8 text and finality. Payloads
are copied synchronously off-main. Live snapshots retain at most 512 recent
segments, with 4 KiB per segment on UTF-8 boundaries. Final ranges reject
conflicting late revisions and duplicate retry output; adjacent ranges are
half-open. Backend final text is retained for SRT output.

The Qt adapter coalesces snapshots in a latest-value mailbox and delivers only a
queued signal to the owning controller. The UI uses a try-lock and queues a retry
rather than waiting for the publisher. Caption status polling also uses a
try-lock and skips a busy publication. The mailbox and queued notifications are
bounded even if the UI cannot keep up. A request-scoped bridge and source URL
reject stale delivery after media changes; destruction disconnects the receiver.
A selectable **Live Captions** source feeds the existing plain-text QML subtitle
overlay on both playback routes. Turning captions off or choosing another track
is respected. After atomic SRT commit, the worker parses that file using the
existing bounded subtitle parser (65,536 cues / 8 MiB text; input capped at 16 MiB).
One UI turn replaces the same source's cues and renames it **Generated Captions**,
without clearing the displayed line or adding another source. Committed cues use
the normal full-track bounds so seeking remains possible; the 512-segment bound
applies to the running live job. The native video/audio path is uninvolved.
Cancel cancels analysis and result tasks, calls `cancelAndFinishNow`, and awaits
teardown off-main. A cancelled service session is rebuilt for the next request.

## Build and ABI

`src/wamkit/CaptionBackend.cmake` typechecks a SpeechAnalyzer SDK probe. A compiler
or SDK without the API builds `caption_stub.cpp`; `WAM_ENABLE_APPLE_CAPTIONS=OFF`
exercises that configuration explicitly. Swift declarations have macOS 26 guards,
the adapter targets the application's macOS deployment floor, and Speech is weak
linked. The versioned C ABI is `WAMCaption.h`, included in the WAMKit framework.
Its opaque handle and borrowed callback payloads expose no Swift async or C++
ownership. Calls require serialized operations; release follows FINISHED and
must not occur inside a callback. The app and framework link the same adapter.

## Runnable checks

Use an out-of-tree scratch build; no model fetching is needed for unit tests:

```sh
cmake -S . -B /private/tmp/wam-asr-scratch/stage -G Ninja \
  -DWAM_BUILD_APP=OFF -DWAM_BUILD_WAMKIT=OFF \
  -DWAM_ENABLE_MACOS_NATIVE_VIDEO=OFF -DWAM_ENABLE_AVFORMAT_STAGE=OFF \
  -DWAM_ENABLE_AVCODEC_STAGE=OFF -DWAM_ENABLE_SOFTWARE_VP8=OFF \
  -DCMAKE_BUILD_TYPE=Release
cmake --build /private/tmp/wam-asr-scratch/stage --parallel 4 \
  --target wam_caption_test wam_caption_backend_test wam_caption_flow_test wam_caption_proof
ctest --test-dir /private/tmp/wam-asr-scratch/stage -R 'caption_' --output-on-failure
```

Repeat in `no-speech-stage` with `-DWAM_ENABLE_APPLE_CAPTIONS=OFF`; the extra
`caption_sdk_absent` test queries the actual stub and proves Whisper selection.
The flow fixture supplies a fake C ABI to cover consent, decline, install failure,
cancellation, stale generations and volatile replacement without network access.
`caption_service` covers original commit/validation behavior and a simulated
hung Metal process with a TERM-ignoring descendant and successful CPU retry.

`wam_caption_proof WAV OUTPUT_DIRECTORY` is an opt-in real-file test: two identical
SRTs across warm reuse, cancellation while results arrive, destination preservation,
and reuse after cancellation. It never consents to a download. Speech assets may
be hidden by a development sandbox, so run with ordinary OS access to an already
installed locale. Tests do not remove assets or simulate an install by changing
OS inventory.

`tests/caption_gui_proof.py --engine apple --app STAGED_WAM --asset LOCAL_VIDEO --output SCRATCH`
runs paired baseline/caption trials using identity-bound native telemetry, muted
background windows at `480x270+2400+1000`, and isolated HOME directories. It retains
playback samples, UI timer gaps, status messages, executable/input hashes, and
child PIDs. It starts captioning through the actual controller during playback. Repeat with
`--engine whisper` to force the default Metal Whisper path. Before each trial the
harness logs compiler/linker processes and one-minute load, polling every 30 seconds
until none are building and load is below 8. It verifies the telemetry header's PID,
run ID and executable/input hashes, and retains that identity alongside the exclusive
per-child playback metrics file. The QML text item must be visible and unchanged
across two presented overlay frames before first-live/committed receipts are logged.
First-live additionally requires the service's atomic transcription flag, so a
lagging UI completion timer cannot turn already-finished inference into a live pass.
The proof requests an overlay frame on a track change; unchanged text otherwise
correctly produces no scene-graph work. See `LIVE_CAPTIONS_VALIDATION.md` for receipts.

The bake-off remains in `tools/asr-bench/README.md`. Run its documented build,
prepare, run and summarize commands against the fixed manifest; use
`python3 tools/asr-bench/test_bench.py` for its five self-tests. The harness and
corpus were not changed for this implementation. See
`CAPTION_ENGINE_VALIDATION.md` for this run's exact commands and outcomes.

## Remaining limits

No actual pre-26 OS was available; SDK-disabled selection, the 13.3 load command,
weak linkage and framework imports were checked here. The installed asset was
preserved: actual download success/failure/cancel behavior is covered by fixtures,
not a destructive fresh-install test. Extraction still completes before analysis
and uses the existing extraction progress plateau. Live segments are overlaid before commit and prepared Apple sessions have idle
eviction. There is no system memory-pressure observer. Movie/podcast accuracy,
controlled cold-cache tests, multi-hour memory growth and metered power remain
outside the LibriSpeech bake-off evidence.
