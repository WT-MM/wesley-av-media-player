# Native coverage — phase 0b, 2026-09-06

The [v0.4.24 QA correction report](qa-v024/REPORT.md) supersedes the unsigned
8-bit PCM and generic Matroska rate claims below. Historical phase-0b JSON
receipts remain measurements of their recorded candidate, not of QA's
v0.4.24 executable. The three previously missing `.log` receipts are regenerated
for the QA correction candidate and identify that candidate explicitly.
New campaigns use the [report template](REPORT-TEMPLATE.md), recording both
shipped and measured executable SHA-256 values.

Phase 0b adds hardware ProRes 4444/XQ and HEVC 4:2:2 presentation,
Matroska Apple audio carriage, and bounded, supersedable long-GOP seeks.
HE-AAC/v2 and HEVC 4:4:4 remain explicitly refused for the reasons below.
The [phase 0/1 report](phase01-report.md) is preserved as historical evidence;
its statements that no amendments or new hardware families were implemented
apply to that earlier run.

Host: Apple M3 Max, arm64, macOS 26.3.1 (a), build 25D771280a, Xcode 26.6.
Apple codec-service proofs ran outside the filesystem sandbox. No FFmpeg
library was added or linked. FFmpeg is the offline generator/reference only.

## Family results

| Family / carriage | Production route | Specimen and proof |
| --- | --- | --- |
| ProRes 4444 / XQ, MOV (`ap4h` / `ap4x`) | Required VT hardware → display layer; opaque packed RGB10 (`w30r`), alpha ignored | 320×180, 30 frames per fidelity specimen; both 30/30 hardware, RGB max error 1/255, RMS 0.36262/255 against ffmpeg; final built-app native selection and first-frame draw |
| HEVC Main 4:2:2 10, `hvc1` MOV | Required VT hardware → explicit `x422` → display layer | 320×180, 30/30; RGB max error 3/255, RMS 1.15484/255; final app native selection and first-frame draw |
| Matroska ALAC | Matroska demuxer → AudioToolbox | Bare 24-byte CodecPrivate, explicit ALAC final-packet count; 192,000 frames at zero, 96,000 at 2 s; bit-exact stereo float output and zero-frame chirp lag |
| Matroska PCM integer / float | Matroska demuxer → AudioToolbox PCM conversion | `A_PCM/INT/LIT` s16 and `A_PCM/FLOAT/IEEE` f32; same exact counts, bit-exact samples and zero lag |
| Matroska IMA / MS ADPCM | `A_MS/ACM` WAVEFORMATEX → AudioToolbox | Block size, samples/block and standard MS coefficients validated; exact DiscardPadding; same exact counts, bit-exact samples and zero lag |
| HE-AAC / HE-AACv2, MP4 and Matroska | Named native refusal; compatibility route remains available | `HeAacSbrDecoderDelayUnproven`; reproduced 962-frame SBR offset at 48 kHz, no full-length zero-offset proof |
| VP9 profile 2, 10-bit MP4 | VT hardware → display layer | 30/30 hardware in retained profile test; final app native selection and first-frame draw. Actual reader/descriptor/hardware gates supersede AVFoundation's false `playable` hint for VP9 |
| AV1 Main 10-bit MP4 | Existing VT hardware route verified | 30/30 hardware; final app native selection and first-frame draw |
| HEVC 4:4:4 10-bit, `hvc1` MP4 | Native refusal: `Hevc444SurfaceContractUnsupported` | Hardware **does** decode 30/30 (`p444`); software decodes too. No authorized coded 4:4:4 surface identity or validated production output contract was added |

Compressed specimens are retained locally under `test-media/native-phase0b/`
(about 10 MB, covered by the repository's existing media ignore rules).
[Specimen hashes](phase0b/retained-specimens.json), generator argv and diagnostics
are in the [video](phase0b/video-proof.json), [audio](phase0b/audio-proof.json),
and [HE-AAC refusal](phase0b/he-aac-refusals.json) receipts. The integration tests
regenerate their own specimens under `/private/tmp`; they do not depend on
ignored local media. The original run validated descriptors for 8/24/32-bit packed integer
layouts without full decoded specimens. QA subsequently confirmed and fixed an
8-bit signedness defect; the correction report contains decoded sample proof.
Float64, nonstandard MS coefficients, discontinuous packet grids and unsupported
packet sizes remain closed.

### Pixel and alpha proof limits

The fidelity probe grabs the first decoded surface in-process and uses
VTPixelTransfer to read opaque BGRA, compared with ffmpeg's first-frame RGB.
The generated ProRes alpha plane is fully opaque, so its reference is also the
opaque composite over black. Production selects `w30r`, which has no alpha
plane; it ignores alpha rather than compositing it. These results are pixel
comparisons with stated conversion tolerances, **not byte-exact RGB** or a proof
of transparent-alpha compositing or preservation of all 12 coded bits.

ProRes 4444 is refused on the scene-graph route by
`SceneGraphProRes4444OpaqueUnsupported`; PQ/HLG packed-RGB presentation is refused
by `ProRes4444OpaqueRgbHdrUnsupported`. Both 4:2:2 surface depths are refused on
the scene-graph route by `SceneGraph422Unsupported`. No shader was widened.
The earlier ProRes 422 route retains its existing output conversion.

An unpinned `p422` readback did not establish color parity. Production therefore
pins the verified `x422` request and refuses `p422` as a mismatched output.
The app's window-script `grab` captures its Qt window, but not the separate
AVSampleBufferDisplayLayer image. Those grabs establish neither compositor
pixel parity nor display color accuracy. [App telemetry](phase0b/gui-proof.json) separately proves
native selection, successful presentation and no fallback for these specimens.

## CPU and energy

Five paired offline decodes per mode, alternating order; 2-second, 320×180,
60-frame specimens. Medians, with capture disabled during measurement:

| Family | VT hardware CPU / energy | Forced VT software CPU / energy |
| --- | --- | --- |
| ProRes 4444, `w30r` | 11.839 ms / 35.088 mJ | 14.574 ms / 41.567 mJ |
| ProRes 4444 XQ, `w30r` | 11.841 ms / 33.945 mJ | 15.135 ms / 40.567 mJ |
| HEVC 4:2:2 10, `x422` | 10.381 ms / 30.239 mJ | 12.029 ms / 35.385 mJ |
| VP9 profile 2, 10-bit | 9.779 ms / 28.531 mJ | No Apple software decoder: create −12906 |
| AV1 Main 10-bit | 10.144 ms / 29.322 mJ | No Apple software decoder: create −12906 |
| HEVC 4:4:4 10, probe only | 10.284 ms / 30.172 mJ | 12.190 ms / 35.579 mJ |

[Raw samples, exact asset hashes and decoder hardware-property proofs](phase0b/performance.json).
CPU is `getrusage(RUSAGE_SELF)`; energy is `proc_pid_rusage(RUSAGE_INFO_V6)`.
These exclude framework helpers, display/compositor costs and compatibility
player overhead. They are process-local throughput measurements, not system
power, coalition energy, or an end-to-end hardware-efficiency acceptance.
Matroska audio uses the Apple software/conversion path; no audio hardware
acceleration or new hardware-versus-software energy comparison is claimed.
Earlier Apple audio process measurements remain in
[the phase 0/1 receipts](apple-audio-probes.json).

## HE-AAC delay ownership

For both HE-AAC variants, Apple and ffmpeg produce 196,544 frames at 48 kHz.
The best correlation is `Apple[i] ≈ reference[i + 962]` (the previous report's
lag convention called this −962). The doubled-rate SBR signature is 962 frames,
not a container edit or an extra 1024-frame AAC-LC packet.

Shifting the overlapping region aligns it closely, but the ffmpeg reference has
nonzero samples in the missing leading region and Apple's final 962 frames are
zero. Merely changing timestamps, trimming again, or inserting silence cannot
establish exact full-length identity. The ExtAudioFile evidence does not prove
how to recover that head through the production AudioConverter API while
assigning the implicit decoder delay exactly once. Consequently no speculative
second trim or fabricated padding was introduced. MP4 format-list inspection
and Matroska explicit/implicit SBR signaling produce the named refusal.
[Offset evidence](phase0b/he-aac-delay.json) and [overlap/head/tail measurements](phase0b/he-aac-overlap.json); four container/profile refusal
regressions are part of the integration suite. HE-AAC admission remains deferred.

## Bounded, cancelable slow seeks

The existing 12-second values are fast-seek thresholds, not admission ceilings.
Source, preview, dispatcher and converter no longer reject solely for longer
preroll. Matroska admits sparse but usable random-access indexes;
`SparseRandomAccess` now denotes the absence of usable random-access points.
Existing index-scan budgets and all sample, ring and frame-retention limits stay
in force. Decode/discard proceeds incrementally; no preroll-sized buffer is built.

The session accepts a newer seek while awaiting the old seek's presentation
proof, burns a fresh generation, and retires the older work at its worker
checkpoint. Old draw proofs cannot promote the newer target. The owner polls
preroll progress every 250 ms and reports decoded-frame progress for slow seeks;
its 10-second watchdog now measures inactivity rather than total decode time.

Proofs:

- A synthesized 40-second single-GOP H.264 file opens and previews target 30 s
  from random-access point zero in the production-source integration test.
- A 3840×2160, 40-second single-GOP file lands at exactly 30 s in the final app:
  commit submitted → commit-ready/frame-drawn in **1.272 seconds**. A 640×360
  version lands in 148 ms. The 4K specimen is only 44 KB.
- A deterministic session regression holds that same 30-second preroll pending,
  accepts a newer 3-second seek, rejects the older generation's draw proof and
  publishes only the newer commit readiness.
- A bounded PCM regression starts decoding at zero, discards exactly 1,440,000
  frames, and publishes exactly 96,000 frames from target 30 s, bit-identical to
  ffmpeg with zero chirp lag ([restored converter receipt](phase0b/slow-audio-origin30.restored.log)).

## Amendments and budget

The maintainer's exact ratification text and every touched frozen line's
before/after are recorded in the local, gitignored `SESSION_HANDOFF.md` ledger.
[An exact copy of that ledger section](phase0b/amendments.md) is retained here.
The only changes to frozen `native_media_source.hpp` are the appended codec and
sample-format enum values and the threshold comments. The other three frozen
files remain byte-identical to HEAD.

The surface-budget header preserves 4:2:0 payload 28,508,160 bytes, slack
1,599,488 bytes and padded surface 30,107,648 bytes. For 4:2:2, the payload is
38,010,880 bytes and slack 2,121,728 bytes: **40,132,608 per surface**, ten requiring
**401,326,080 bytes**. The **384 MiB = 402,653,184-byte** ceiling leaves 1,327,104
bytes. Opaque single-plane RGB10 fits below that bound. The ten-surface count
and derived 16-window process count are unchanged. Every original budget
assertion remains, with explicit exact-number assertions added for both families.

## Historical verification

- Reconfigured after CMake changes; `cmake --build build --parallel` passes.
- The original campaign reported **82/82** for both full runs, with the final
  run taking 94.43 s. Its original log was missing. The [regenerated log](phase0b/ctest-final.log)
  instead records **92/92** for the QA correction candidate. No ctest run
  overlapped our linker.
- **19 temporary-revert groups**, **29 test failures** and one compile-time
  budget-invariant failure; each original working-tree file was restored
  byte-for-byte and the passing test repeated. [Receipts](phase0b/revert-proofs.json)
  and [executed procedure](phase0b/revert-proofs.py). Some historical groups
  pinned helpers or source text; the correction report separately identifies
  runtime proofs. That procedure records this
  campaign's scratch paths and skips groups already present in its results file;
  use a fresh results file for a new campaign. A failed decoder-harness
  invocation without its required mode was corrected before counting that proof.
- Reverts cover both AVFoundation new families and long seek, shared HEVC parsing,
  all five Matroska audio specimens, PCM sample construction/counts, HE-AAC named
  refusals, slow audio trimming, dispatcher/preview admission, router/session
  supersession, packed-RGB requests, scene-graph refusals, progress and budget.
- Final quiet corpus: **78/97 native**, baseline **78/97**, **zero regressions**.
  [Per-file results](phase0b/corpus-results.json), [TSV](phase0b/corpus-results.tsv),
  [regenerated campaign log](phase0b/corpus.log). The original campaign used the candidate hash
  recorded in [verification](phase0b/verification.json), all four identity
  variables, scratch HOME, muted/background geometry and a six-second dwell.
- No git staging, commits, stash, reset or checkout. The maintainer owns acceptance.

## Remaining work

HE-AAC/v2 exact decoder-delay ownership; HEVC 4:4:4 coded/output authorization and
pixel proof; ProRes `V_PRORES` Matroska sample-description wiring; transparent
alpha/compositor proof; HDR packed-RGB proof; true end-to-end CPU/energy comparison
against compatibility playback. ProRes MP4 carriage was not independently
specimen-tested. The prior G.711/QuickTime IMA4 identity gaps and unsupported
`hev1` HEVC 4:2:2 carriage remain deferred. This is not an exhaustive proof for
all Apple-registered formats, profiles, operating systems or machines.
