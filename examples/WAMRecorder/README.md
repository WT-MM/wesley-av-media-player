# WAM Recorder

Native macOS menu bar recorder powered by WAMKit. Requires macOS 15 or newer.
Microphone and system audio can be enabled independently. When both are enabled,
they are saved as separate source tracks in a timestamped session folder, preserving
clean originals and avoiding live mixing/echo or an extra encoding pass.

Build using `scripts/build_wam_recorder.sh build-encoding`. The app stays in the
menu bar. Capture begins only after Start recording and the macOS permission prompts.
System capture uses ScreenCaptureKit audio output; no screen video is saved.
Microphone-only mode uses AVFoundation and does not request screen recording access.

## Controls and storage

Select microphone, system audio, or both; choose the microphone device, mono or
stereo per source, 44.1/48 kHz, Float32 PCM, PCM16, ALAC16, or AAC (64/96 kb/s per
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

## Verification and diagnostics

`tests/wam_recorder_writer_test.swift` drives the exact app writer with synthetic
CMSampleBuffers. It covers two sources, 44.1→48 kHz resampling, over-range peaks,
checkpoint rotation, decoded segment lengths, and final tails. Three accelerated
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
