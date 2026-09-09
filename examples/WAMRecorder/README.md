# WAM Recorder

Native macOS menu bar recorder powered by WAMKit. Requires macOS 15 or newer.
Microphone and system audio can be enabled independently. When both are enabled,
they are saved as separate source tracks in a timestamped session folder, preserving
clean originals and avoiding live mixing/echo or an extra encoding pass.

Build using `scripts/build_wam_recorder.sh build-encoding`. The app stays in the
menu bar. Capture begins only after Start recording and the macOS permission prompts.
System capture uses a private Core Audio process tap; it does not require a display or capture screen video.
Microphone-only mode uses AVFoundation and does not request screen recording access.

## Controls and storage

Select microphone, system audio, or both; choose the microphone device, mono or
stereo per source, preserved capture rate or fixed 44.1/48 kHz, Float32 PCM, PCM16, ALAC16, or AAC (64/96 kb/s per
channel), and a save folder. Settings persist. Recording settings are locked
while a session is running; Stop and save finalizes the current files.

Float32 PCM is the measured lowest-median-energy encoder and the default.
At 48 kHz with mono mic + stereo system, budget **3.11 GB per 90 minutes**;
PCM16 uses **1.56 GB** and has nearly the same encoder energy cost. Compressed
formats save space. These figures are decimal GB and exclude tiny metadata overhead.
Float32 preserves finite over-range peaks. Other formats use Accelerate's vector
clipping before WAMKit conversion, so loud captured audio cannot abort a recording
because of the integer encoder's amplitude range.

The default checkpoint interval is five minutes; 15 and 90 minutes are available.
Each completed checkpoint is flushed, closed, synchronized to disk, and marked
completed in an atomically updated `session.json`. That manifest contains source
names, file order, frame counts, format, and host-clock offsets. Both tracks stay
separate; source discontinuities start new files rather than silently joining a
gap. No live mixing or echo cancellation is performed. Use the offsets when
assembling tracks in an editor. There is no automatic consolidation/export UI yet.

Recording prevents idle system sleep without keeping the display lit. Closing
the lid, forced sleep, revoked permissions, disconnected audio devices, or full
disk can still interrupt capture; the app finalizes what it can and shows the
error. Finished checkpoints remain usable. The active checkpoint may require
recovery after process kill/power loss; this is not a claim of crash-proof storage.
A ten-second rolling manifest update describes active files but does not mark
them complete. Disk space is checked while writing, with a 256 MB stop threshold.

## Preserving and inspecting audio

Choose **Preserve captured rate** to avoid resampling in the app. Microphone audio
retains the rate delivered by AVFoundation; system audio retains the tap’s reported rate.
This does not promise that the device or macOS performed no earlier processing.
PCM supports integer rates from 8–192 kHz. AAC/ALAC currently support only
44.1/48 kHz and report an actionable error for other captured rates.

Matching Float32 input goes directly to WAMKit without conversion or an extra
sample copy. Mono planar Float32 is also eligible; other layouts/conversions use
a reusable conversion buffer. Channels remain explicitly configured: choosing
mono for stereo input still performs a channel conversion. Fixed-rate settings
continue to work and existing settings are preserved.

After stopping, **Report** opens `Recording report.txt` with actual rates,
channels, actual microphone and system clock device names, frame counts, timing offsets, resampling/remixing flags, peak magnitudes
before encoder limiting, and whether samples were limited. The same information
is in `session.json`. Finite peaks above full scale are preserved in Float32;
other formats limit these peaks, PCM16/ALAC16 quantize to 16 bits, and AAC is lossy.
No claim of better microphone hardware or fidelity than Voice Memos follows from
file size or the report alone.

Timestamp gaps or overlaps exceeding two input frames start a new file and are
logged, as are capture-format changes. Audio is not silently stretched or padded
to hide a discontinuity. The report is produced at normal finalization; after a
crash, use the existing checkpoint manifest to inspect completed files.

## Verification and diagnostics

`tests/wam_recorder_writer_test.swift` drives the exact app writer with synthetic
CMSampleBuffers. It covers two sources, 44.1→48 kHz resampling, over-range peaks,
checkpoint rotation, decoded segment lengths, and final tails. Bit-for-bit Float32
checks cover 16/44.1/48/96 kHz, mono/stereo, planar/interleaved input and over-range
peaks. Format changes, 50 ms gaps, and 20 ms overlaps are explicitly tested. Three accelerated
90-minute sessions each produce 36 playable checkpoints. This is full-duration
content validation, not an elapsed 4.5-hour live-capture/battery soak.

The app's opt-in `--benchmark-output /absolute/experiment-folder` mode performs
bounded idle, mic, system, both, PCM16, and AAC runs. It requests normal macOS
permissions, removes its diagnostic audio after each successful run, and retains
metrics. Failed diagnostics may retain an interrupted session for inspection.
Do not enable diagnostic mode for an actual recording you want to keep.

The build is ad-hoc signed for local use. The copied WAMKit dependency closure
includes the decoder framework's notices and corresponding source. This machine's
local libvpx requires macOS 26 even though capture APIs require only macOS 15;
older-macOS distribution, Developer ID signing, and notarization are not qualified.

[Measured power and battery-life projection](../../benchmarks/audio-energy/RESULTS.md)
includes codec comparisons, source modes, uncertainty, and the remaining live
validation. Reproduce writer checks with `scripts/test_wam_recorder.sh build-encoding`;
append `--long` for three accelerated 90-minute sessions.

For one bracketed profile, add `--benchmark-mode microphone --benchmark-scheme
float32 --benchmark-seconds 180` to diagnostic mode. It measures idle/capture/idle
with five-second warmups, fixed 48 kHz and mono mic/stereo system settings, retaining
your selected microphone. Supported modes are microphone/system/both; schemes
are float32/pcm16/alac/aac64/aac96; window length is 30–5400 seconds. Use at least
180 seconds and five independent blocks for whole-battery comparison. Interrupted
windows are rejected. See [comparison protocol](../../benchmarks/audio-energy/COMPARISON.md).

Add `--benchmark-device-name 'MacBook Pro Microphone'` to select that exact input
for a diagnostic. Ambiguous or disconnected names fail explicitly. The actual
microphone name is now included in the session report and diagnostic results;
recording the configured default alone is insufficient when AirPods or continuity
microphones can become the system default. Device/OS processing may precede the
format observed by this app.

`--show-window` opens the same recorder panel in a regular window for accessibility
inspection on hosts that cannot automate menu-bar extras. It never starts recording.

## Audio-only system capture

The process tap excludes this app, keeps normal playback unmuted, and uses a private
aggregate with the current output device as its clock. The app does not set the
system’s default input/output or alter an existing aggregate. Physical input channels
are excluded; microphone capture remains independently controlled by AVFoundation.
A tap-only aggregate stalled during development on this Mac; adding the physical
output clock resolved startup. Clock/tap rate mismatches fail explicitly rather than
writing samples with the wrong duration.

The HAL callback copies borrowed samples into owned memory, with at most eight
pending buffers. Conversion, encoding, and file writing run on the separate writer
queue. Invalid layouts, a full queue, changed output route/format, or more than five
seconds without callbacks stop and finalize the session. Output-device changes
currently require a new recording; automatic route recovery is not implemented.

Short local tests verified stereo test-tone capture while ScreenCaptureKit reported
zero displays. This removes that display dependency; it does not permit recording
during system sleep or establish 90-minute screen-off endurance. The underlying API
is documented in [Apple’s Core Audio tap sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).

Diagnostic-only flags: `--benchmark-capture-only` skips idle brackets,
`--benchmark-system-channels 1|2` selects the system track layout, and
`--benchmark-retain-audio` keeps the generated test take for local inspection.
Capture-only results are functional/process checks and cannot feed the bracketed
battery comparison. Retained diagnostic audio must be removed after analysis.

`--benchmark-silent-tap` (only honored in benchmark mode) restricts the tap to
this diagnostic process to verify silent-buffer continuity without pausing other
playback. Its report labels the diagnostic source, and the harness requires zero
system-track peak. It does not represent a normal system recording.
