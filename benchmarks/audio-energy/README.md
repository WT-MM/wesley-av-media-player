# Audio recording energy benchmark

This benchmark compares WAMKit Float32 PCM/CAF, PCM16/CAF, ALAC16/M4A, and AAC at
64 or 96 kb/s **per channel**. Every arm uses the same 48 kHz mono + stereo lanes,
4096-frame batches, precomputed deterministic voice-like harmonics/noise, and
utility QoS. The baseline executes the same source/batch/pacing loop without a
file writer. No physical microphone or system audio is used by this codec test.

`proc_pid_rusage(RUSAGE_INFO_V6).ri_energy_nj` supplies the kernel's attributed
process-energy estimate. Divide its delta by elapsed seconds for average mW.
CPU time comes from `getrusage`; file size, wakeups, sampled footprint, and maximum
write time are recorded separately. This is not a physical power-meter reading,
SSD energy measurement, or attribution of shared macOS capture services.

Three 30-second real-time rounds use a fixed counterbalanced ordering. Reject
wall-time outliers (e.g. sleep) rather than dividing by an inflated elapsed time.
The harness holds an idle-sleep assertion, but lid/forced sleep can still interrupt
it. Keep the Mac awake and repeat interrupted runs. Startup/finalization are
included. Short file sizes include container overhead and are not clean bitrate
measurements. ALAC size depends on content; no perceptual quality comparison is
claimed from this synthetic signal.

Build WAMKit first, then:

```sh
xcrun clang++ -std=c++20 -fobjc-arc -O3 -Isrc/wamkit/include \
  benchmarks/audio-energy/bench.mm -Fbuild-encoding/src/wamkit \
  -framework WAMKit -framework Foundation -framework IOKit \
  -Wl,-rpath,"$PWD/build-encoding/src/wamkit" -o build-encoding/audio-energy-bench
python3 benchmarks/audio-energy/run.py --bench build-encoding/audio-energy-bench \
  --output /absolute/new-experiment --seconds 30 --rounds 3
```

`--fast --seconds 5400` tests 90 minutes of encoded content as fast as possible;
its wall-time power is **not recording power** and must not be used as a battery
life estimate. The runner removes only media files it generated, retaining JSON.
Use a fresh output directory. Codecs require normal macOS media-service access.

`battery_sample.py` records only selected battery/power fields through `ioreg`.
Raw results are local and gitignored. During charging transitions the registry's
SystemLoad can be stale or negative. For battery runtime, restrict to discharging
samples and use `−Amperage × Voltage / 10^6` watts; exclude charging intervals.
Do not conflate system draw under unrelated user activity with the recorder's
incremental cost. The recorder's bounded diagnostic mode separately records
real microphone/system/combined capture windows so battery samples can be aligned
by timestamps. An adjacent idle comparison below telemetry noise cannot prove a
power saving.

For this Mac15,8, Apple specifies a 72.4 Wh design battery. The current full-charge
energy estimate is `72.4 × AppleRawMaxCapacity / DesignCapacity`; this approximation
accounts for battery aging, not voltage-curve or temperature calibration. Runtime
is `estimated full-charge Wh / measured system W`. A 10% reserve multiplies usable
energy by 0.9. Report a conditional estimate, never a guaranteed battery lifetime.

Sources: [Apple model identification](https://support.apple.com/en-gb/108052),
[14-inch M3 Pro/Max battery specification](https://support.apple.com/en-au/117736),
local macOS SDK `sys/resource.h` and `powermetrics --help` (estimated power caveats).

## Writer optimization regression benchmark

`writer_bench.swift` feeds 300 seconds of precomputed mono Float32 CMSampleBuffers
through the production writer in 1024-frame callbacks. Signal generation is outside
timing; creation/finalization and quality reporting are inside. This is accelerated
throughput/CPU testing, not real-time energy or battery testing. Matching 48 kHz and
44.1→48 kHz conversion are measured separately. The harness verifies frame counts
and removes only its generated temporary directory.

To reproduce old/new binaries (from the repository root):

```sh
git show e8f60fd:examples/WAMRecorder/RecordingWriter.swift > /tmp/wam-writer-before.swift
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 \
  -module-cache-path build-encoding/recorder-modules -F build-encoding/src/wamkit \
  -framework WAMKit -framework AVFoundation -framework Accelerate \
  -Xlinker -rpath -Xlinker "$PWD/build-encoding/src/wamkit" \
  /tmp/wam-writer-before.swift benchmarks/audio-energy/writer_bench.swift \
  -o build-encoding/writer-bench-before
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 \
  -module-cache-path build-encoding/recorder-modules -F build-encoding/src/wamkit \
  -framework WAMKit -framework AVFoundation -framework Accelerate \
  -Xlinker -rpath -Xlinker "$PWD/build-encoding/src/wamkit" \
  examples/WAMRecorder/RecordingWriter.swift benchmarks/audio-energy/writer_bench.swift \
  -o build-encoding/writer-bench-after
python3 benchmarks/audio-energy/compare_writer.py \
  --before build-encoding/writer-bench-before --after build-encoding/writer-bench-after \
  --output /absolute/new-writer-comparison.jsonl
```

Six rounds per input rate alternate before/after order. Build first; do not compile
while measuring. CPU placement, thermal state and background load can change the
absolute values even when process CPU time is used. Report both medians and ranges.
For actual whole-battery and fidelity comparison with Voice Memos, follow
[COMPARISON.md](COMPARISON.md). Run its analysis tests with
`python3 -m unittest discover -s benchmarks/audio-energy -p 'test_compare_capture.py'`.
