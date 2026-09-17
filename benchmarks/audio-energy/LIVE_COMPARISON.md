# Live local recorder checks — September 9, 2026

User explicitly approved opening the recorder and recording local diagnostic audio.
Voice Memos opened in Lossy mode with its library downloading existing recordings.
No Voice Memos recording was started: cloud sync could violate the local-only
scope, and a request to temporarily disable sync remains pending. QuickTime was
used as a local Apple reference. Existing user recordings were not opened or altered.

## QuickTime Maximum vs WAM Float32

Both used **MacBook Pro Microphone**. QuickTime's saved files were inspected with
ffprobe: **48,000 Hz, mono, Float32 big-endian PCM in AIFF-C**. WAM delivered
48,000 Hz mono Float32 CAF, with no app resampling/remixing, limiting, or detected
timing events. These formats preserve the same numeric sample representation;
there is no demonstrated format-fidelity advantage over QuickTime Maximum.
Sequential ambient captures are not bit-exact acoustic comparisons and do not
establish equivalent upstream processing, noise floor or distortion.

| Run | Steady window | CPU, % of one core | Process-attributed power |
| --- | ---: | ---: | ---: |
| QuickTime Maximum 1 | 29.1 s | 10.72% | 13.81 mW |
| WAM Float32, built-in input 1 | 30.4 s | 3.27% | 6.69 mW |
| QuickTime Maximum 2 | 28.1 s | 10.53% | 14.39 mW |
| WAM Float32, built-in input 2 | about 40 s | 3.31% | 4.30 mW |

QuickTime's recording window/meter was visible; WAM's menu-bar panel was closed.
This compares those actual app configurations, not isolated encoder performance.
The Mac was plugged in, with other apps left running. There were no overlapping
agent builds or synthetic stress tests during these steady windows. Two runs per
app, short windows and differing durations are **exploratory process-overhead
measurements**, not the five-round controlled battery protocol in COMPARISON.md.
Shared capture services, disk/controller energy and whole-system draw are excluded.
A lower process counter does not establish a whole-battery advantage.

QuickTime CPU was sampled using `proc_pid_rusage` and converted from Mach ticks
with the local 125/3 timebase. A local calibration matched `getrusage` CPU seconds
within about two microseconds for a 0.144-second synthetic computation. WAM's
internal benchmark uses `getrusage` directly. The first exploratory sampler file
had its raw ticks mislabeled `cpu_ns`; the figures above apply the verified
conversion. The committed sampler uses `cpu_ticks` and records its timebase.

The first unpinned WAM run is excluded from this comparison: it did not retain
the actual device name, and the system default was observed to be AirPods Pro
(hardware rate reported as 24 kHz). Its delivered capture buffers were 48 kHz,
but we cannot establish which device that earlier run used. This exposed a real reporting gap. The app now records the
actual microphone name, and its benchmark can require an exact device name.
A capture-buffer rate cannot prove what happened upstream in macOS or the device.

Both QuickTime diagnostic takes were deleted after format inspection (72.565 and
64.064 seconds respectively). WAM's successful diagnostic audio is deleted by its
harness. Raw process rows and format-only metadata remain local and gitignored.
No diagnostic recording was uploaded or shared.

## Remaining evidence

Voice Memos comparison awaits the local-only sync decision. Whole-battery testing
requires unplugged, controlled measurements; real screen-off 90-minute endurance
and calibrated acoustic comparisons remain outstanding. User permission to open
WAM is granted; the previous app-launch approval blocker is resolved. Menu-bar
computer control still times out, so a `--show-window` inspection option exposes
the same controls without starting capture.

## Writer-optimized live matrix (earlier ScreenCaptureKit backend)

The sequential matrix pinned the built-in microphone, used five-second warmups
and roughly 40-second steady windows per recording. Every captured arm completed
with zero reported timestamp/format events and sufficient decoded-duration metadata.
These are one run per configuration under the existing plugged-in workload.

| Sources | Format | CPU, % of one core | Process-attributed mW |
| --- | --- | ---: | ---: |
| microphone | float32 | 3.31 | 4.30 |
| system | float32 | 1.49 | 1.76 |
| both | float32 | 4.44 | 6.84 |
| both | pcm16 | 4.94 | 6.74 |
| both | aac64 | 6.74 | 14.93 |

Float32 and PCM16 remain too close to distinguish for process energy here; AAC64
adds some attributed processing cost while greatly reducing storage. These values
exclude shared services and disk power and cannot choose a whole-battery winner.
The previously unmeasured post-fix PCM16/AAC64 live paths now pass. Successful
matrix diagnostic audio was deleted automatically.


Additional combined-source checks passed for ALAC16 and AAC96 (30-second steady
windows, with the inspection-window option enabled). Both completed with zero
reported timing events, no limiting, and correctly identified built-in microphone.
Their attributed process readings were 7.48 mW / 5.37% CPU and 13.75 mW / 7.91% CPU,
respectively. These UI-option runs are functionality checks, not matched codec
energy comparisons. All five audio formats have now completed short live capture.

Validation before the Core Audio replacement: all 7 CTests pass (24.72 seconds), the 3 comparison-analysis tests
pass, and the rebuilt app passes strict ad-hoc signature verification. Computer
control still times out when selecting WAM, even with the inspection window;
interactive UI verification remains incomplete. The diagnostic processes exited
and successful diagnostic audio was removed. No 90-minute real-time or unplugged
battery run is claimed.


## Display-independent system capture

An attempted unplugged 180-second bracket exposed a functional gap: ScreenCaptureKit
returned no displays and system-audio startup failed. Two earlier idle-only attempts
were rejected by overly strict timer-lateness thresholds. No completed battery block
resulted. The benchmark now uses actual monotonic elapsed time, tolerates bounded
idle timer coalescing, and rejects suspend/counter failures. The Mac subsequently
reported external AC power, preventing a valid discharge comparison.

The system backend now uses a private Core Audio process tap with a physical output
clock. An initial tap-only aggregate stalled in AudioDeviceStart; the clocked version
completed. A read-only ScreenCaptureKit query still returned **zero displays**.
The successful stereo Float32 run contained 1,734,144 frames (~36.1 seconds), zero
detected timing events, and no app resampling/remixing/limiting. Its 30.7-second steady
window measured 2.09% of one core / 2.45 mW process-attributed power. This is one
functional run under the existing workload, not evidence of an energy win over the
old backend.

A six-second quiet synthetic tone played during that run was recovered at 997 Hz
in the left channel and 1499 Hz in the right. Across central tone seconds the
expected channel amplitudes were approximately 0.0098–0.0108, consistent with the
0.05 source amplitude and 0.2 playback volume. Other system audio was also present;
this verifies signal capture and channel placement, not calibrated audio fidelity.
The diagnostic audio was deleted after analysis; only numeric metrics remain local.

The backend checks tap/clock rates, copies borrowed buffers into owned storage,
bounds queued buffers, and stops/saves on output-route or tap-format changes and
missing callbacks. Tests overwrite the original callback memory and verify intact
mono/stereo planar/interleaved samples and host timestamps, plus rejection of
partial frames, null pointers, oversized callbacks, and missing host timestamps.
These tests use synthetic memory and do not request capture permission.


### Final Core Audio combined-source checks

All five formats completed another short live run using the final backend, the
built-in microphone, and the current AirPods Pro output as the private aggregate’s
clock. Each steady window was about 30.5 seconds after a five-second warmup. These
sequential, single-run checks confirm functionality; background audio/workload was
not standardized, so they do not establish codec or backend energy rankings.

| Sources | Format | CPU, % of one core | Process-attributed mW |
| --- | --- | ---: | ---: |
| both | Float32 | 5.98 | 5.98 |
| both | PCM16 | 6.67 | 6.30 |
| both | ALAC16 | 5.80 | 7.88 |
| both | AAC64/channel | 8.42 | 11.73 |
| both | AAC96/channel | 8.55 | 12.60 |

All delivered 48 kHz mono microphone and stereo system audio, with zero detected
timing events, no app resampling/remixing/limiting, completed manifests, and sufficient
captured duration. All generated audio was deleted automatically after validation.


A separate mono system-only Float32 run also passed: 1,733,120 frames, no timing
events, and no microphone lane. Its 30.6-second steady window used 3.29% of one
core / 2.46 mW attributed process power. This verifies the mono tap configuration,
not the exclusion of every possible upstream macOS audio transformation.


A silent-tap diagnostic restricted capture to the recorder’s own non-playing
process, leaving other playback untouched. It completed 1,733,120 zero-valued
stereo frames with no timing events across a roughly 36-second take. Silence
therefore continued through the callback watchdog in this test; this is a short
edge-case check, not a long-duration stability result.


Final validation after the backend changes: all seven CTests pass (21.95 seconds),
all three battery-analysis tests pass, the reference sampler compiles, and the app
passes strict ad-hoc signature verification. The Core Audio stereo/mono/silence
smoke tests and five-format combined-source matrix completed, and their diagnostic
audio was removed. UI interaction, live route-disconnect recovery, the controlled
Voice Memos comparison, and real 90-minute endurance remain unverified.
