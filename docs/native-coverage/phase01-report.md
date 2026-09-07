# Native coverage evidence — 2026-09-06

This is an implemented, verified subset of phases 0–1. The complete requested
Apple admission expansion and slow-seek work are **not complete**. No FFmpeg
library was built or linked. All user-frozen files and SESSION_HANDOFF.md remain
unchanged. The interrupted working-tree edits were inspected and continued.

## Apple capability ledger

Host: Apple M3 Max, arm64, macOS 26.3.1 (a), build 25D771280a;
Xcode 26.6. Run the probes outside the filesystem sandbox: its unavailable
codec services produced an incomplete three-ID AudioToolbox registry and false
audio configure failures. The retained registry is the corrected host result.

| Specimen/profile | Actual Apple result | WAM disposition |
| --- | --- | --- |
| ProRes 4444 / 4444 XQ, 320×180, 60 frames | VT hardware and software each decode 60/60; `y416` output | Deferred: separate frozen codec identity and explicit opaque presentation contract required |
| HEVC 4:2:2 10-bit, `hvc1` MOV | VT hardware 60/60, `p422`; VT software 60/60, `x422` | Deferred: frozen 4:2:0 sample-format identity and budget need revision |
| Same HEVC bytes, `hev1` MOV | VT create −12906 in both modes | Carriage-specific limitation; **not** absence of HEVC 4:2:2 hardware |
| VP9 profile 0, MP4 | VT hardware 60/60; forced software create −12906 | Already admitted; host hardware capability verified |
| AV1 Main, MP4 | VT hardware 60/60; forced software create −12906 | Already admitted; host hardware capability verified |
| MJPEG 4:2:0 | VT software 60/60; hardware property false | Existing route preserved |
| MJPEG 4:2:2 / 4:4:4 | VT produces no frames (−12904 / −12910); ImageIO reads first image | Now refused at open by SOF0 chroma name; no bounded ImageIO→presentation adapter proved |
| HE-AAC / HE-AACv2 | ExtAudioFile/AudioToolbox decodes 196,544 frames at 48 kHz, actual tags `aach` / `aacp` | Matroska still refused; timing/content parity not accepted (reference lag −962 frames) |
| ALAC, PCM, Microsoft IMA/MS ADPCM | Apple output bit-exact against reference, exact file-declared counts | Existing MOV/WAV paths retained; Matroska carriage still refused |
| G.711 A-law/µ-law, QuickTime IMA4 | Apple output bit-exact, 192,000 frames | Additional missing frozen codec identities; not mislabeled as linear PCM or Microsoft IMA |

`apple-registered-capabilities.txt` contains every reported AudioToolbox format
ID from this host plus registered VP9/AV1 hardware hints. Registry entries include
transport aliases; they are not individual specimen decode proofs. This run is
not an exhaustive proof for every Apple-registered format, codec profile or
machine. Missing genuine specimens and unmapped identities remain explicit work.

Raw receipts: `apple-video-probes.json`, `apple-audio-probes.json`,
`he-aac-alignment.json`, and `specimens.json` (generator argv, hashes and ffprobe
stream/container facts). Packet/frame counts are decode evidence, not a claimed
pixel-fidelity acceptance for the deferred hardware families.

### CPU and energy scope

Two-second, 320×180, 60-frame offline decodes, one measurement per mode:

| Family | Hardware process CPU / energy | Software process CPU / energy |
| --- | --- | --- |
| HEVC 4:2:2 10-bit (`hvc1`) | 11.428 ms / 31.969 mJ | 15.561 ms / 40.803 mJ |
| ProRes 4444 | 12.280 ms / 35.352 mJ | 13.044 ms / 40.134 mJ |
| ProRes 4444 XQ | 12.674 ms / 35.602 mJ | 17.099 ms / 44.137 mJ |

The XQ and other raw values are in `apple-video-probes.json`. CPU comes from
`getrusage(RUSAGE_SELF)` and energy from `proc_pid_rusage(RUSAGE_INFO_V6)`.
These exclude decoder helpers and are throughput probes, not real-time playback,
coalition energy or statistical hardware-win evidence. **No new hardware decode
family was landed in WAM**, so no end-to-end hardware efficiency win is claimed.
AudioToolbox process-local measurements are retained with the audio receipts.

## Landed behavior and tests

| Change | Proof |
| --- | --- |
| Opus input rates normalized to the 48 kHz output grid | 8/24/48 kHz input specimens each publish 192,000 frames, zero-lag chirps; explicit output 48 kHz passes and 24 kHz refuses; pre-skip/discard checks retained |
| Shared complete-descriptor audio selection | Invalid 88.2 kHz default plus valid 48 kHz AAC chooses track 2 in MOV and MKA; explicit requested-track failure remains exact and closed |
| MJPEG early inspection | 4:2:0 opens; 4:2:2/4:4:4 refuse with `Motion JPEG chroma...`; malformed/truncated/non-SOF0/header cases tested |
| Standalone AAC tail | Explicit target-zero open: 191,488 → 192,000 frames; two-second start retains 96,000 frames; reader extent includes priming edit and converter still owns exact tail trim |
| MP3 LSF LAME delay/padding | 8/22.05/24 kHz: 32,000/88,200/96,000 frames, zero-lag stereo chirps; 32 kHz MPEG-1 remains 128,000; independent count and origin reversions fail |
| Routine admission notice suppressed | Source Unsupported carries an observation-side route-choice fact through unchanged exact retirement; genuine Failed retains its diagnostic and notice; owner wiring has a static guard test |
| Retained offline audio harness | Production source→converter→ring, armed exact initial position, exact first/last publication counts, seek-floor case, channel-specific chirps and lossless controls |

`macos_native_coverage_integration` generates temporary specimens and checks
sample counts, file size, finite PCM, zero-lag channel-specific chirps and lossy
maximum absolute error <0.004. Actual AAC/MP3 error is much smaller; Opus errors
are near float-rounding noise. ALAC/PCM/ADPCM require exact equality. It requires
a fixture FFmpeg with AAC, libmp3lame, libopus, MJPEG and the lossless encoders;
this does not add a runtime FFmpeg library dependency. The CMake test is enabled
when a fixture FFmpeg executable is found.

Reproduce and retain receipts:

```sh
python3 tests/native_coverage_integration.py \
  --audio build/wam_native_coverage_audio_probe \
  --source build/wam_native_coverage_source_probe \
  --ffmpeg /opt/homebrew/bin/ffmpeg \
  --artifacts /private/tmp/wam-native-coverage-repro
build/wam_native_apple_video_probe
build/wam_native_apple_video_probe /path/to/specimen.mov 1
build/wam_native_apple_video_probe /path/to/specimen.mov 2
build/wam_native_apple_audio_probe /path/to/specimen.m4a /private/tmp/apple.f32
```

Ten separate reversion checks were killed, with byte-identical restoration of
each source. `reversion-proofs.json` records target, command, exit code and
restored SHA-256; detailed build/test receipts are in
`/private/tmp/wam-coverage/mutations/`. The notice owner proof is a static wiring
check, not an assertion that a Qt notice was observed in a graphical test.

## Final verification

`cmake --build build --parallel` completed successfully. The full settled
`ctest --output-on-failure` run passed **81/81**, with zero failures. After the
last test-only extension, all three native-coverage tests passed again. Apple
codec tests require access to host codec services; sandbox-only execution can
produce false configuration failures. The earlier disk-churn run had killed
fresh binaries; the complete settled rerun is the reported result.

The requested 97-file corpus remains **78/97 native, zero baseline-native
regressions**. Every launch used the build app, all four telemetry identity
variables, an isolated scratch HOME, background/muted geometry and a six-second
orderly exit. The final app SHA-256 matches the corpus candidate exactly:
`9573d70f6f8b0b79a3e68e4c341d01699600c440129ea17464cc60db28b473e9`.

Corpus telemetry was emitted on stderr. The initial stdout-only classification
was invalid; retained results were corrected from the unchanged captures using
both streams, requiring native selection and a drawn frame, no native failure
or fallback event, and exit code zero. `corpus-results.json` and
`corpus-results.tsv` contain the corrected per-file results. The maintained
`tests/native_coverage_corpus.py` reads both streams.

The AAC and MP3 LSF measured playback runs each completed forward, backward and
near-end seeks (2, 0.5 and 3.5 seconds) without native failure; event receipts are
in `playback-seeks.json`. The offline harness separately checks exact sample
publication at the two-second target. `verification.json` records the frozen
file hashes, build/test results and matching app identity. No frozen file was
changed, and no changes were staged or committed.

## Remaining contract proposals and work

- **PROPOSAL 15 — distinct Apple codec identities.** Append ProRes4444 after
  AdpcmMs in frozen `native_media_source.hpp`; preserve existing values and
  distinguish the two ProRes decode families. Name opaque/alpha-ignored behavior
  explicitly. Further proven G.711 and IMA4 families need their own identities.
- **PROPOSAL 16 — HEVC 4:2:2 output contract/budget.** Append Yuv422TenBit and
  matching consumer/import/color facts. Re-derive worst-case surface bytes:
  `9,502,720×4 + (4096+4096)×255 + 2×16,384 = 40,132,608`;
  ten surfaces need 401,326,080 B. A 384 MiB ceiling (402,653,184 B) covers that;
  the current 288 MiB ceiling does not. Re-prove compressed formats, Metal/GL
  import, chroma mapping and pixel fidelity before admission.
- **PROPOSAL 17 — cancelable slow seeks.** The frozen source contract explicitly
  caps video and audio preroll at 12 seconds; silently ignoring it is not a
  contract-preserving implementation. Add a slow-seek capability distinct from
  resource limits, maintain bounded queues and generation cancellation, and
  replace the fixed seeking watchdog with a progress/cancellation policy.
  Current SparseRandomAccess remains Unsupported, not corruption.
- HE-AAC/v2 Matroska needs decoded-rate/AU and decoder-delay proof; the Apple
  probe has a 962-frame disagreement and WAM's AVFoundation view exposes the
  24 kHz AAC core. No full-bandwidth/sample-exact support is claimed.
- ALAC/PCM/ADPCM Matroska packet/cookie/block framing is still unimplemented;
  their positive Apple decode probes do not prove Matroska carriage. This is
  remaining phase-0 implementation work, not an Apple decoder limitation.
- No ImageIO worker/pool/conversion route, complete Apple-profile enumeration,
  pixel-correct hardware-family acceptance or coalition energy campaign was
  completed. Do not use these receipts to claim universal native coverage.

The pinned library/notice plan and `--verify-runtime` extension design are in
[`ffmpeg-dependency-plan.md`](ffmpeg-dependency-plan.md).
