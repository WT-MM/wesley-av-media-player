# WAM-native WAV ADPCM decoder — 2026-09-22

Candidate: `2f85dbf5ef8e7ccbc70a06e71540bed2675a20ed8986e61d48b60c1edffd01d5`.
Base: `f1ca74afa6c550dab7e546bffada2d430a82b613`, branch
`adpcm-native-decoder`. AVFORMAT ON; AVCODEC OFF. Changes are uncommitted.
[Executable identities and host](verification.json).

## Implementation

`src/media/adpcm_decoder.hpp/.cpp` implements WAV IMA (0x11) and Microsoft
ADPCM (0x02) in neutral C++20. No third-party implementation or decoder library
was introduced. IMA uses low-nibble-first samples and stereo four-byte channel
groups. MS emits sample2 then sample1, uses high-nibble-first signed residuals,
integer prediction divided toward zero, the seven standard coefficient pairs,
and integer delta adaptation. Both saturate to signed 16-bit before exact
Float32 scaling by 1/32768.

The API accepts parsed block bytes, frames, channels and MS coefficients. It
rejects unsupported facts, inconsistent geometry, short/oversized blocks,
insufficient output, invalid channel headers and unrepresentable delta
adaptation by stable names. It never infers a partial block's sample count.
Each block owns fresh predictor history. The standard MS table is shared with
Matroska's existing WAVEFORMATEX validation.

`NativeAudioConverter` now selects `WamAdpcmBackend` for both ADPCM enums,
independent of host availability and the optional libavcodec stage. This is the
shared converter reached by AVFoundation and Matroska. The backend decodes on
the converter worker, retains at most one decoded block, and releases borrowed
packet bytes immediately after decoding. Its vector allocates at configuration,
not per packet or on the audio callback. The maximum WAV block geometry bounds
that vector to 524,252 bytes. Blocks larger than the 4,096-frame output slab are
published incrementally. Reset discards the remaining block output.

The existing rational timeline accounting, mono duplication, publication floor,
ceiling, and ring remain unchanged. ADPCM has zero decoder lead-in and no
codec tail. Container tail padding is still discarded by the existing retained
window. Named decoder failures now survive the backend boundary through a
default virtual diagnostic method; frozen test doubles require no changes.

`audioCodecDecoderProvenOnHost`, its call sites, the
`AdpcmDecoderUnprovenOnHost` refusal, and the older-host integration skip are
removed. Other codec priorities and decoder implementations are unchanged.

AVFoundation omits the MS coefficient cookie for the generated WAV files.
Consequently its admission worker scans bounded RIFF chunks, validates the
actual `fmt` facts against CoreMedia, and rejects a nonstandard coefficient
table before decoding. The scan reads at most 50 bytes at a time and visits at
most 4,096 chunks. It does not modify the immutable CoreMedia format identity.
ADPCM files without these provable WAV facts receive
`AdpcmWaveFormatFactsUnavailable`; see the carriage limitation below.

CMake and the two standalone session/device-recovery test build scripts link
the new neutral implementation. Their test bodies are unchanged.

## Proofs

Measured host: arm64, macOS 26.3.1 (a), build 25D771280a. FFmpeg is only the
offline specimen generator and external sample oracle.

| Proof | Result |
| --- | --- |
| Both codecs × mono/stereo × 44,100/48,000 Hz × WAV/Matroska × targets 0, 2, 100001/100000 seconds | 48 decodes, maximum error **0**, zero chirp lag, exact EOS |
| Additional 64-byte and 8,192-byte Matroska blocks, both codecs | 4 decodes, maximum error **0**, exact EOS; includes output spanning multiple slabs |
| Retained pre-existing lossless/Apple-audio cases | 14 decodes, maximum error **0** |
| Malformed IMA/MS headers | `AdpcmImaHeaderInvalid` / `AdpcmMsHeaderInvalid` |
| Nonstandard WAV MS coefficients | `AdpcmWaveFormatMismatch` at source admission |
| Quiet production retry | Two refused graphs retire; third PCM track renders **88,200** frames |

There are 66 decoded comparisons in the retained receipts, including 58 ADPCM
comparisons. Every comparison enforces maximum error `< 1e-12`, first published
frame `ceil(T*R)`, exact retained frame count, and drained EOS. Fractional seeks
land at frame 44,101 or 48,001. Mono reference widening explicitly duplicates
the channel: FFmpeg's default mono-to-stereo remix attenuates it and is not
WAM's existing representation.

[WAV JSON](wav-proof.json), [WAV log](wav-proof.log),
[Matroska JSON](matroska-proof.json), [Matroska log](matroska-proof.log),
[final-candidate retry receipt](retry-proof.json), [retry log](retry-proof.log).
Receipts include specimen recipes, asset hashes, executable identities and exact
decoder diagnostics. Media remains under `/private/tmp/wam-adpcm-scratch`.

`tests/adpcm_decoder_test.cpp` uses synthesized blocks and written-out reference
arithmetic, not FFmpeg answers. It checks independent stereo channels, IMA step
changes and clipping, all seven MS predictors including negative division,
first/last samples, fresh block histories, mono non-grouped payload, geometry,
coefficient, capacity and malformed-header refusals. The standalone strict
warning build and AddressSanitizer/UndefinedBehaviorSanitizer run pass.
[Sanitizer output](sanitizers.log).

GUI measurement used only `build/WAM.app`, lowercase UUID/64-hex identity
values, `WAM_NATIVE_BENCHMARK_TELEMETRY=1`, muted/background operation,
`480x270+2400+1000` geometry, scratch HOME and only the launched PID. The retry
fixture now changes the two IMA descriptors to invalid partial stereo groups:
64-byte IMA, previously refused by AudioToolbox, is now supported and can no
longer serve as an intentionally failing decoder graph.

## Rollback controls

[Complete receipts](revert-receipts.json) retain substitutions, commands,
exit codes, diagnostics, and pre/post restoration SHA-256 values.

Seven completed control groups produce eight expected failing assertions and
pass again after byte-identical restoration:

1. Remove IMA decoder capability: synthesized answers fail.
2. Remove MS decoder capability: synthesized answers fail.
3. Remove IMA reserved-header validation: malformed-input assertion fails.
4. Remove MS minimum-delta validation: malformed-input assertion fails.
5. Restore AudioToolbox routing: both named malformed-packet ownership tests fail.
6. Remove the WAV coefficient admission check: the custom table is admitted,
   failing the refusal assertion.
7. Restore the old retry fixture: WAM successfully plays its first ADPCM track,
   failing the third-track frame-count assertion.

The new algorithm has no previous neutral implementation to restore; groups
1–4 are capability/validation removal controls, not claims of an older neutral
algorithm. The routing and source controls are actual restoration of prior
behavior. A supplementary route rollback also fails the 64-byte IMA decode;
64-byte MS continues to work in AudioToolbox on this host and is explicitly
recorded as a non-discriminating control, not a successful negative proof.

One initial source restore had identical source bytes but a stale object because
make missed a same-second timestamp change. Its restored assertion failed;
that attempt is retained. Repeating with a timestamp-separated restoration and
rebuild passes. All source files and final binaries were restored/rebuilt
before the final campaign. Old-host gate rollback cannot fail on macOS 26;
actual macOS 13–15 execution remains deferred rather than simulated.

## Build and ctest

`cmake --build build --parallel` passes. [Final build log](build.log).
The existing `wam_matroska_demuxer_bench` target is excluded from the default
build and was also built explicitly before full ctest
([build receipt](build-benchmark.log)).

The first suite exposed missing standalone-script linkage to the new decoder
and the unbuilt benchmark: [initial log](ctest-initial.log). Both script link
lists were fixed and the benchmark built. Initial sandboxed fixture generation
could not access Apple's HE-AAC encoder, and app packaging could not copy its
signed bundle contents. Authorized service/signing access resolved those
build failures; no network or dependency installation was used.

The final full suite passes **130/130**, with zero failures, in **186.48 s**:
[ctest-final.log](ctest-final.log).

Reproduction from this configured checkout:

```sh
cmake --build build --parallel
cmake --build build --target wam_matroska_demuxer_bench --parallel
cd build
TMPDIR=/private/tmp/wam-adpcm-scratch WAM_TEST_SCRATCH=/private/tmp/wam-adpcm-scratch ctest --output-on-failure
```

## Frozen files, limits and deferrals

All four frozen paths/globs are byte-identical to HEAD:
[frozen SHA-256 inventory](frozen.json). No frozen-contract change or numbered
proposal was necessary. No git add, commit, stash, reset or checkout was used.
The sibling workspace was not accessed.

- **Older-host execution:** no macOS 13.3/14/15 host was available. The production
  route has no OS gate or AudioToolbox ADPCM call, but bit-exact runtime receipts
  on those hosts are still required for a cross-host campaign.
- **ADPCM MP4 carriage:** the shared AVFoundation converter selection is updated,
  but no independently qualified MP4 ADPCM specimen was available. Local FFmpeg
  refuses MS ADPCM MP4 muxing ([diagnostic](mp4-carriage.log)). Non-WAV
  AVFoundation carriage without provable format facts is named-refused;
  this report does not claim to have expanded that carriage.
- Custom MS coefficient tables, incomplete blocks, malformed headers and
  unrepresentable adaptation remain deliberately refused. QuickTime IMA4 is a
  different codec and is outside this change.
- No energy/CPU improvement, packaging-floor requalification, or exhaustive
  malicious-input fuzz campaign is claimed.
