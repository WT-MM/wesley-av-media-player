# Recorder comparison protocol

No Voice Memos head-to-head recording has been measured yet. Opening the local
recorder for live tests is pending explicit approval after computer-control review
blocked it. Synthetic results must not be presented as battery or product superiority.
The earlier under-1-percentage-point incremental battery estimate is unverified.

## What would establish an advantage

Compare microphone-only WAM against Voice Memos using the same physical input,
channel count, capture rate where configurable, repeatable acoustic stimulus,
output quality mode, screen state, brightness, power mode, and background workload.
Record actual Voice Memos settings and inspect exported files: do not assume that
its default mode is lossless, mono, a particular rate, or unprocessed. Keep playback
processing separate from file analysis. Do not change cloud sync or other user
settings without authorization. If sync is enabled, disclose it as a confound.

First run short recording/export checks. Then run at least five independent
counterbalanced rounds: alternate which app is measured first. Each profile has
180 seconds idle, 180 seconds steady recording, 180 seconds idle, with startup and
finalization excluded from those steady windows and measured separately. Keep both
apps open in the same state for baseline measurements. Do not run compilers or
other benchmarks during measurement. Sample unplugged battery telemetry every two
seconds with `battery_sample.py`; do not infer whole-system watts from process energy.

For WAM, use its opt-in diagnostic arguments:

```
--benchmark-output /absolute/fresh-block-directory
--benchmark-mode microphone --benchmark-scheme float32 --benchmark-seconds 180
```

This pins 48 kHz and mono microphone, uses the selected microphone device, brackets
capture with idle, and deletes successful diagnostic audio. It rejects timing or
capture discontinuities. Use ordinary recording for the short fidelity export
comparison so the test files survive analysis; delete only diagnostic files that
we created. Actual input formats are in the receipt/report. Inspect Voice Memos
through its UI; never read unrelated recordings. A recorder app's own idle state
and a system idle reference are different: match them explicitly.

Record epoch window boundaries in a JSON list:

```json
[{"profile":"wam-float32", "round":0,
  "idle_before":[1000,1180], "recording":[1200,1380], "idle_after":[1400,1580]}]
```

These are illustrative timestamps, not results. Use the WAM result's `start_unix`
and `wall_seconds`; collect equivalent boundaries around Voice Memos through UI
control. All windows must be non-overlapping. Give matched app blocks the same
round number. Feed real windows and telemetry to:

```sh
python3 benchmarks/audio-energy/compare_capture.py \
  --battery /absolute/battery.jsonl --windows /absolute/windows.json \
  --capacity-wh 58.4
```

The analyzer rejects charging/unknown power states, insufficient coverage, stale
telemetry, overlapping windows, and fewer than five independent blocks per profile.
It time-weights discharge power and interpolates each bracketed idle baseline.
Bootstrap intervals resample entire blocks, not repeated gauge rows. Paired app
differences use matching rounds. A zero-crossing interval is unresolved, not proof
of savings. Gauge calibration, uncontrolled workloads and systematic error remain
outside those intervals. Check that any apparent advantage exceeds those errors.
The capacity argument is an aging-adjusted estimate; use a current measurement.

## Fidelity acceptance

The synthetic writer tests compare decoded Float32 samples bit for bit, including
above-full-scale values, source rates, channels, frame count and timing events.
They prove preservation from CMSampleBuffer input to file on the tested paths.
They do not prove what happened in the microphone, ADC, macOS capture processing,
or a competing app. PCM16/ALAC16 are 16-bit representations, not lossless arbitrary
Float32. AAC requires a separate lossy-quality comparison.

For the acoustic comparison, play a repeatable speech/tone/noise stimulus from
an external source in a fixed position, including quiet passages and near-peak
signals. Sequential acoustic captures cannot be bit-exact: room noise and clock
drift differ. Inspect decoded sample format, missing time, clipping, frequency
response, noise floor and distortion after alignment. Do not use amplitude
normalization to hide clipping or gain differences. For an exact digital-input
comparison use an already-authorized loopback device with identical routing; do
not install a driver merely to complete a benchmark.

## Endurance acceptance

Run the selected profile for a real 90 minutes with display off and lid open;
verify segment continuity, decoded duration, final tail, memory growth, storage,
and energy. Repeat for three sessions to test the actual target workload. Exercise
stop, device disconnect and forced sleep separately; interrupted recordings must
be reported honestly. Until this is complete, do not claim battery superiority,
closed-lid support, or proven multi-session reliability.
