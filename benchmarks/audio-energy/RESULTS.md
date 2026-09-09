# M3 Max recording energy results — 2026-09-09

**Under the workload present during combined microphone/system recording, the
Mac averaged approximately 25.7 W. The resulting full-charge runtime projection
is about 2 hours 16 minutes, or 2 hours 2 minutes with a 10% reserve.** This is a
conditional projection from a short measurement, not a battery endurance test.

Host: 14-inch MacBook Pro, Mac15,8, M3 Max (16 CPU cores), 64 GB, macOS 26.3.1.
No other user applications were closed, no brightness change was made, and no
fixed background workload was imposed. These results describe that environment.

## Codec comparison

Three accepted 30-second real-time runs per scheme; two lanes, 48 kHz mono +
stereo; utility QoS; identical precomputed source and 4096-frame batching.
Values include the common pacing/source loop, creation, and finalization.

| Scheme | Median process power estimate | Run range | CPU, % of one core | 90-minute storage, both lanes |
| --- | ---: | ---: | ---: | ---: |
| Baseline, no file | 0.148 mW | 0.114–0.214 | 0.056% | — |
| Float32 PCM/CAF | **0.561 mW** | 0.412–0.895 | 0.297% | **3.11 GB** |
| PCM16/CAF | 0.683 mW | 0.558–0.697 | 0.256% | 1.56 GB |
| ALAC16/M4A | 4.026 mW | 3.267–4.372 | 1.397% | Content-dependent |
| AAC 64 kb/s/channel | 6.415 mW | 5.992–9.837 | 2.435% | About 0.13 GB + container overhead |
| AAC 96 kb/s/channel | 6.285 mW | 6.159–7.522 | 2.452% | About 0.19 GB + container overhead |

Float32 is the default because it had the lowest median attributed encoder
energy. **Float32 and PCM16 are a near tie: their ranges overlap, and no
battery-level advantage between them is established.** PCM16 is available to
halve storage. The two AAC settings are also indistinguishable at this precision;
the slightly lower AAC96 median is not evidence that raising bitrate saves power.

These are kernel-attributed process-energy estimates, not whole-system power or
SSD/controller power. Codec overhead is tiny compared with the measured laptop
load. AAC's 90-minute process-energy estimate is around 0.010 Wh; changing codecs
cannot plausibly recover the tens of Wh needed for another 90-minute session
under the observed workload. Audio quality was not perceptually benchmarked.

One AAC64 run experienced a long sleep interruption (roughly eight minutes wall
time for 30 seconds of audio); it is excluded. A replacement 30-second run is
included, and the harness now holds an idle-sleep assertion. Raw rows are retained
locally under `results/`, including the rejected measurement. The replacement
also encountered scheduler delays, retained in its deadline counters; the table
shows the full observed range, not a selected best run.

## Actual capture path

The native app recorded real inputs for roughly 40 seconds after a five-second
warmup, then finalized and deleted the diagnostic audio. Idle intervals bracketed
capture. These measurements include the app's conversion/writing/callback work,
but process attribution does not include all work in shared macOS services.

| Mode, Float32 output | App process power estimate | App CPU, % of one core |
| --- | ---: | ---: |
| Idle menu bar app | 0.003–0.008 mW | 0.002–0.003% |
| Microphone only | 4.36 mW | 4.26% |
| System audio only | 2.74 mW | 1.86% |
| Microphone + system | **8.58 mW** | **5.05%** |

The combined window had 20 discharging battery samples, approximately 23.4–26.8 W,
mean 25.74 W. The immediately preceding idle window averaged about 25.98 W.
That negative apparent delta is background/telemetry noise, **not evidence that
recording reduces power**. This run cannot resolve the recorder's incremental
whole-laptop draw. Microphone-only overlapped a charging interval and has no
valid discharge-based whole-system figure. System-only averaged 20.78 W in its
own window; do not interpret the difference from combined mode as microphone cost,
since unrelated workload was not held constant. Gauge samples update more slowly
than the sampler, so 20 rows are not 20 independent observations.

During charge transitions, the registry's SystemLoad field was sometimes stale
or negative. Runtime calculations use only non-AC, negative-current samples and
compute watts as `−Amperage × Voltage / 1,000,000`. Charging samples are excluded.

## Battery budget

[Apple specifies 72.4 Wh](https://support.apple.com/en-au/117736) for this model.
The gauge reported about 5,040 mAh full-charge capacity versus 6,249 mAh design:
roughly 81%. Scaling design energy by that ratio gives an approximate **58.4 Wh**
current full-charge energy. This is an aging-adjusted estimate, not a direct
calorimetric capacity measurement.

- Full-charge projection: `58.4 Wh / 25.74 W = 2.27 h` (about 2 h 16 min).
- With 10% reserve: `52.6 Wh / 25.74 W = 2.04 h` (about 2 h 2 min).
- One 90-minute session at this load: about **38.6 Wh**. Start around **76% or more**
  to retain approximately 10% at the end, subject to workload/temperature changes.
- Two 90-minute sessions with reserve require average whole-Mac draw at or below
  **17.5 W**. Three require about **11.7 W** or less. Otherwise use external power.

These are concrete planning numbers for the observed workload, not guarantees.
Display, networking, other apps, temperature, battery calibration, and capture
permissions/device behavior can change runtime. No 4.5-hour unplugged endurance
run was performed. The app's selected source/codec options remain available so
storage and input needs can be changed without rebuilding.

## Reliability and remaining validation

- All **7 WAMKit/recorder CTests pass**, including C/Objective-C/Swift imports,
  hardware video, legacy audio, all five recorder formats, and checkpoint recovery.
- The exact recorder writer passed **three accelerated 90-minute, two-source
  sessions**, each with **36 playable five-minute checkpoints** and correct decoded
  lengths/tails. Peak writer-test RSS across the sessions was **14.73, 14.95, and
  15.00 MiB**. This is writer memory, not the entire SwiftUI application's footprint.
- Microphone 44.1→48 kHz conversion, stereo system input, and repeated sessions
  share the production writer. Float32 preserves finite over-range peaks; integer
  and compressed options clamp with Accelerate before encoding.
- The live run found an over-range input failure on the subsequent PCM16 arm.
  It was fixed and regression-tested across all formats, including deliberately
  over-range input. **The live PCM16/AAC arms and post-fix live repetition remain
  unmeasured.** Reported live values above are the successful pre-fix Float32 arms.
- Abrupt process exit leaves both completed five-minute source checkpoints
  independently playable. The unfinished checkpoint is not promised recoverable.
- The app builds and passes strict ad-hoc signature verification. Interactive UI
  inspection is pending the requested approval after computer-control review
  rejected opening the locally built software. The already-running diagnostic
  process supplied the successful live results above before it exited.

See [method and reproduction](README.md), [app guide](../../examples/WAMRecorder/README.md),
and [WAMKit encoding contract](../../docs/wamkit/ENCODING.md). Raw battery/capture
telemetry is local and gitignored; only aggregate measurements are included here.
