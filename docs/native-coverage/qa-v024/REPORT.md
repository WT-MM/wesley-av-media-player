# Corrections for the v0.4.24 independent QA report

The workspace was clean on entry. Its actual base is **bba7060**
(`v0.4.25-1-gbba7060`), with the same reproduced defects; the incoming report
reviewed `b026a48` and v0.4.24. No branch, index or installed application was
changed. The optional phase-2 software stage was not enabled in these launches.

[Executable identities](identity.json) distinguish the QA executable
`89f06305b733e6f390e7d86d848001dbd18eb734bbce3cd4f180d87160f75fdd`,
the currently installed executable (read-only hash inspection, never launched),
and the final measured build. These uncommitted fixes are measured through
`build/WAM.app/Contents/MacOS/WAM`; they are not evidence that an installed or
historical release already contains the fixes.

## Decoded PCM verdict: confirmed silent sample corruption, fixed

The stereo 48 kHz MKA contains two seconds of unsigned 8-bit PCM:
`0.375 + 0.03*sin(2*pi*(200*t+100*t*t))` and
`-0.25 + 0.02*sin(2*pi*(300*t+130*t*t))`.
The production Matroska source, NativeAudioConverter and NativePcmRing capture
interleaved float32 before the device output/mute seam. FFmpeg independently
decodes the same compressed file to stereo float32.

Before the fix, **all 192,000 samples differed by exactly 1.0**. The first WAM
pair was `[-0.625, 0.75]`, versus FFmpeg's `[0.375, -0.25]`.
[Original capture comparison](unsigned-before.json). Counts alone passed:
both paths produced 96,000 stereo frames.

The PCM descriptor now marks Matroska 8-bit integer PCM unsigned, retains signed
integer flags at 16/24/32 bits, and retains the float flag for IEEE PCM.
After correction, all 192,000 samples match exactly ([final capture hashes](audio-final.json)): **max error 0, RMS 0,
chirp lag 0, 96,000 frames**. The mutation restoring the signed flag fails the
sample comparison with max error 1.0; its byte-identical restore passes.
[Failing mutation](u8.mutated.log), [restored proof](u8.restored.log).

## Defects and runtime proofs

| Defect | Correction | Passing reproduction and revert proof |
| --- | --- | --- |
| D2: AAC rate gate inherited by generic Matroska audio timing | Generic exact-rational packet projection is used for descriptor admission, seek planning and cursor timestamps. AAC-specific wrappers retain their codec rate gate; native output policy remains unchanged. | Both retained 32 kHz MKA inputs render **64,000 frames**. PCM and ALAC captures at **8/11.025/12/16/22.05/24/32/44.1/48/96/192 kHz** have exact `2*rate` frame counts and bit-exact samples against FFmpeg. [Reverted timing fails](rates.mutated.log); [all 22 restored captures](rates.restored.log). |
| D1: backend refusal terminated alternate-track selection | Dispatcher retries actual audio configuration before exposing video on automatic multi-track opens. A refused audio graph must finish bounded close before replacement. Source retirement retains the cancellation generation and excludes each rejected track. Matroska and AVFoundation use the same selection order. Explicit requests stay exact and failures include the requested track ID. Single-candidate A/V configuration remains concurrent. | The retained `retry-backend-three.mka` selects playable PCM after two refused 64-byte IMA tracks and renders **88,200 frames**. Runtime dispatcher tests cover exact requests, pending close, and cancellation. [Dispatcher mutation](retry.mutated.log), [actual decoder-retirement mutation](retry-retirement.mutated.log), [source-selection mutation](retry-source.mutated.log) all fail. |
| D3: multiple HE-AAC tracks lost their reason | Descriptor failures retain per-candidate track ID, codec and refusal. Named codec reasons take precedence over generic admission text. | `two-he.mka` starts its refusal with **HeAacSbrDecoderDelayUnproven** and includes both tracks' same specific reason. [Generic-message mutation fails](he-aac.mutated.log); [restored regression](he-aac.restored.log). |
| Progress wiring uncovered by the replacement runtime test | The worker now publishes metrics in both seek-commit branches, which previously continued without publication. | Actual [owner notice/events receipt](wiring-progress.json) reports decoded preroll frames and the retained 4K specimen commits at exactly **30 s**. [Removing publication fails](progress-publication.mutated.log); [restored runtime proof](progress-publication.restored.log). Disabling the owner's progress handling also [fails at runtime](progress.mutated.log). |

A successful internal retry publishes no Prepared/Started/sample from the
refused track. Pending audio teardown refuses the open while retaining its graph
for terminal retirement; it does not proceed with another live graph. At most
64 track candidates can be attempted. No frozen interface or frozen audio test
was edited; [four byte-identity checks](frozen-files.json) pass.

## Evidence hygiene

- The EBML fixture writer widens size VINTs at the finite-size boundary, including
  the reserved all-ones value. A nested Audio/TrackEntry/Tracks fixture verifies
  growth; the original fixed-width writer [fails](ebml.mutated.log).
- Explicit Opus 48 kHz output passes decoded-sample comparison. Explicit 24/96
  kHz output must return **OpusOutputSampleRateUnsupported**. A generic failure
  no longer satisfies the negative test; [removing attribution fails](opus.mutated.log).
- `native_coverage_wiring_test.py` reads **runtime app events, PCM counters and
  actual PlayerController notice signals**, not production source text. The
  notice trace is benchmark-gated. Restoring native admission notices
  [fails the runtime test](notice.mutated.log).
- The local fallback dylib has a pre-existing missing FFmpeg dependency. The
  routine-route test permits only that separately named loading error and still
  requires no native admission notice. It does not claim successful compatibility
  playback. Native retry and seek tests require no fallback or native failure.
- The [report template](../REPORT-TEMPLATE.md) records shipped and measured
  executable SHA-256 values. App launch receipts retain argv, PID, all four
  benchmark identity variables, scratch HOME, geometry and metrics; executable
  bytes are checked before and after each run. Offline audio receipts identify
  both probe executables and every compared asset hash.
- The previously missing [ctest](../phase0b/ctest-final.log),
  [corpus](../phase0b/corpus.log), and
  [30-second audio-origin](../phase0b/slow-audio-origin30.restored.log) logs are
  regenerated measurements of this correction candidate. They do not recreate
  lost historical measurements. Scoped ignore exceptions keep these receipts
  eligible for staging by the maintainer.

[All eleven executed mutation/restore receipts](revert-proofs.json) record
nonzero mutated exits, zero restored exits, and equal before/after source hashes.
The [reusable procedure](../../../tests/native_coverage_revert.py) always restores
in a `finally` block and builds before testing each binary.

## Final verification

The restored build passed `cmake --build build --parallel`. Its executable SHA-256 is
`acd79b81617bd844ee89c49632a5cbb4edb971ccfe9052d7f197d5ac1df40354`.
Full **ctest: 92/92 passed in 123.00 seconds**, with no reruns and no overlapping
build/link operation; [regenerated final log](../phase0b/ctest-final.log).

The [six same-executable QA reruns](gui-reproductions.json) include both 32 kHz
WAV/M4A controls. All expected counts and refusals pass. The [final audio
receipt](audio-final.json) additionally verifies byte-identical float32 captures
and reference segments for all **38 lossless captures**.

Final quiet six-second corpus: **78/97 native**, baseline **78/97**,
**zero regressions**. [Summary](corpus-summary.json), [per-file results](corpus-results.json),
[regenerated log](../phase0b/corpus.log), and [retained raw launch/telemetry/metrics archive](corpus-raw.json.gz).
All 97 runs used the same final executable hash. [Verification summary](verification.json).

## Limits and deferrals

No amendment is needed. No codec identities, sample-rate policy, frozen contract,
per-sample allocation/locking rule or retention ceiling changed. Output capture
proves converter/ring PCM, not device resampling or acoustic output.

HE-AAC delay recovery, iTunSMPB/odd AAC priming variants, maximum surface-pool
occupancy, sustained high-entropy 4K retention, normalized presentation color,
and historical performance comparisons remain outside these fixes. The report
does not upgrade earlier helper-only pixel-request or pool-arithmetic checks
into runtime presentation/saturation proofs. Re-run the applicable campaign on
packaged/shipped bytes before asserting release equivalence.
