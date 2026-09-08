# Phase 2g — 93/97 native; AVFORMAT ON, AVCODEC OFF

Final shipped candidate `a1c2238a282c6206e2a1aacf15741d501dee6968010f0d5e4aafd9780de379f0`. The 97-file probe reaches **93/97 native**, including all original 84 and nine hardware additions, with **zero regressions and zero abnormal exits**. All six RustDesk recordings and appleads draw native frames at clock **1.0000**. **All 124 tests pass across the final suite and unchanged isolated timeout reruns.** The owner's broader goal of eliminating every fallback is not achieved: four corpus refusals and the software-stage gates remain explicitly deferred.

Apple priority remains VideoToolbox hardware → VideoToolbox software → AudioToolbox → libvpx → libavcodec last. Native fails closed. Captures ran first and every capture, including failed/shifted controls and removed experiments, is retained. Changes remain in the working tree for independent maintainer verification; no commit, staging, stash, reset or checkout was performed. No network or sibling-process/file manipulation was used.

## Thirteen original fallbacks

| File | Codec / pixel format / depth | Primaries / transfer / matrix / range | Coded size; PAR | Final native result |
| --- | --- | --- | --- | --- | --- |
| Screencast from 01-28-2026 04:53:24 PM.mp4 | h264 Main / yuv420p / 8 | bt709 / bt709 / bt709 / tv | 1920×1080; 5127:4912 | Named refusal |
| visual_hand_data_trimmed.mp4 | h264 Main / yuv420p / 8 | bt709 / bt709 / bt709 / tv | 1920×1080; 5127:4912 | Named refusal |
| PXL_20250729_045448421.mp4 | h264 High / yuv420p / 8 | bt709 / bt709 / bt709 / tv | 1280×720; absent (CoreMedia 1:1) | Named refusal |
| IMG_7267.mp4 | hevc Main 10 / yuv420p10le / 10 | bt2020 / arib-std-b67 / bt2020nc / tv | 1920×1080; absent (CoreMedia 1:1) | Named refusal |
| angel_clip2.mp4 | h264 High 10 / yuv420p10le / 10 | bt2020 / arib-std-b67 / bt2020nc / tv | 640×360; 1:1 | Native, 146 drawn |
| angel1_prep.mp4 | h264 High 10 / yuv420p10le / 10 | bt2020 / arib-std-b67 / bt2020nc / tv | 640×720; 1:1 | Native, 145 drawn |
| angel2_prep.mp4 | h264 High 10 / yuv420p10le / 10 | bt2020 / arib-std-b67 / bt2020nc / tv | 640×720; 1:1 | Native, 167 drawn |
| angel2_v.mp4 | h264 High 10 / yuv420p10le / 10 | bt2020 / arib-std-b67 / bt2020nc / tv | 404×720; 1:1 | Native, 158 drawn |
| angel1_v.mp4 | h264 High 10 / yuv420p10le / 10 | bt2020 / arib-std-b67 / bt2020nc / tv | 404×720; 1:1 | Native, 162 drawn |
| angel_combined.mp4 | h264 High 10 / yuv420p10le / 10 | bt2020 / arib-std-b67 / bt2020nc / tv | 640×720; 1:1 | Native, 157 drawn |
| zbot33.mp4 | h264 High 4:4:4 Predictive / yuv444p / 8 | bt709 / bt709 / bt709 / tv | 1194×814; 1:1 | Native, 77 drawn |
| 495_2.mp4 | h264 High 4:4:4 Predictive / yuv444p / 8 | bt709 / bt709 / bt709 / tv | 1222×992; 1:1 | Native, 65 drawn |
| amp6.mp4 | h264 High 4:4:4 Predictive / yuv444p / 8 | smpte170m / bt709 / smpte170m / tv | 638×464; 1:1 | Native, 72 drawn |


The six angel files use Apple H.264 High 10 hardware, with ambient payload `002fe9a03d134042` (314 lux; x=15635/50000, y=16450/50000). The exact HLG tuple passes the retained display comparison and all 100 production fixture surfaces retain the payload. The three 4:4:4 files decode **983/983, 903/903 and 263/263** respectively in Apple hardware to explicit `444v`; Apple software creates a session but decodes zero frames with status −8969. Their limited-range 601/709 display tuples are qualified. No unqualified software 4:4:4 admission is added. [Hardware packet/frame receipts](../phase2g/apple-444-probes-unsandboxed.json), [final per-file identities, draws and diagnostics](../phase2g/CORPUS.md).

CoreMedia video edits, source start → target zero (duration): all six angel files start `1024/15360`, with durations 55, 44, 55, 55, 44 and 99 seconds in the table's order; zbot33, 495_2 and amp6 start zero with durations `196600/3000`, `180600/3000` and `52600/3000`. Screencast starts `6000/90000`, duration `491326/1000`; visual_hand starts `352434/90000`, duration `7373/1000`. IMG video starts `321/600`, audio `1476/44100`, both duration 22 seconds. PXL video starts zero and ends `854297/30000`; audio has an empty `192/10000` prefix and source trim `2112/48000`, retained duration `6815160/240000`, target start `192/10000`. [Verbatim CoreMedia segments, full immutable FFprobe facts and metadata](../phase2g/FILES.md).

Remaining refusals:

- **IMG_7267:** `DolbyVisionDisplayOracleProofMissing`. It additionally carries Dolby Vision profile 8/level 4, RPU present, compatibility ID 4 and −90° rotation. An HLG-base-layer comparison does not qualify the complete DV presentation.
- **Both anamorphic files:** `AnamorphicExactRationalDisplaySizeProofMissing`. PAR `5127:4912` gives exact display size `(615240/307) × 1080`, aspect `1709:921`. Frozen integral display fields cannot carry that requested actual size; Proposal 27 is unapplied. No exact aspect/Qt scaling capture is claimed.
- **PXL:** `CoreMediaAudioEditExactTimelineProofMissing`. FFmpeg decodes 1,364,070 frames, first PTS `922/48000`; its timestamp endpoint is `56881/2000`, differing from video by `541/15000` seconds. The CoreMedia retained interval is 1,363,032 samples and ends at target `284157/10000`. Exact PCM/discontinuity/head/tail mapping is unimplemented; no zero-gap or approximate-count proof is claimed.

## Amendment 26 applied

Only `src/media/native_media_source.hpp` changes among the frozen files. The enum appends `Yuv444EightBit`; `MediaVideoFormat` appends `std::uint64_t ambientViewingEnvironmentPayload{0};` and `bool fullRangeVideo{false};` immediately after `ambientViewingEnvironmentPresent`. [Exact frozen-line before/after](../phase2g/amendment26-applied.md), [SHA-256 inventory](../phase2g/frozen-invariants.json).

Admission is limited to 8-bit H.264 4:4:4 limited-range 709/709/709 or 601/709/601 on the direct display route, and exact ambient payload `002fe9a03d134042` on limited-range 2020/HLG/2020-NCL ten-bit 4:2:0. Nearby payloads, full-range variants, HDR 4:4:4, Dolby Vision and scene-graph 4:4:4 remain closed. Matroska range zero inherits coded range and contradictory full-coded 4:4:4 is refused. The padded 4:4:4 surface derives 30,629,888 bytes, below the retained per-surface ceiling; ten surfaces and 384 MiB remain unchanged.

## Display qualification and codec gates

Unchanged tolerances: RMS ≤6 eight-bit RGB units and absolute matrix/range projections ≤0.15. Table passes qualify the measured fixtures, not every metadata combination in a family. [Method, controls and full retained evidence](../phase2g/COLOR.md).

| Family | RMS | Matrix projection | Range projection | Verdict / capture |
| --- | ---: | ---: | ---: | --- |
| Apple H.264 4:4:4 8-bit 601 limited | 0.0242 | 0.000034 | 0.000019 | Pass [capture](../phase2g/captures/corrected-hardware/444-601/display.png) |
| Apple H.264 4:4:4 8-bit 709 limited | 0.0215 | -0.000017 | 0.000016 | Pass [capture](../phase2g/captures/corrected-hardware/444-709/display.png) |
| Apple H.264 HLG 2020 limited | 0.0771 | -0.000097 | -0.000228 | Pass [capture](../phase2g/captures/corrected-hardware/hlg-h264/display.png) |
| Apple HLG with exact ambient payload | 0.3681 | 0.021374 | -0.015268 | Pass [capture](../phase2g/captures/corrected-hardware/hlg-h264-ambient/display.png) |
| Software H.264 PQ 2020 limited 10-bit 420 | 0.5147 | 0.042568 | -0.005161 | Pass [capture](../phase2g/captures/software/pq-h264/display.png) |
| Software H.264 HLG 2020 limited 10-bit 420 | 2.1391 | -0.083126 | 0.128465 | Pass [capture](../phase2g/captures/software/hlg-h264/display.png) |
| Software ASP limited 8-bit | 2.0198 | -0.003474 | -0.040821 | Pass [isolated capture](../phase2g/captures/software-limited-asp-retry/display.png) |
| Software Hi10P limited | 2.3713 | 0.001662 | -0.045358 | Pass [capture](../phase2g/captures/software/limited-hi10p/display.png) |
| Software 422 limited | 2.3939 | 0.004533 | -0.044583 | Pass [capture](../phase2g/captures/software/limited-h264422/display.png) |
| Software VP9 profile 0 limited | 2.0921 | -0.002075 | -0.044093 | Pass [capture](../phase2g/captures/software/limited-vp9/display.png) |
| Software VP9 profile 2 limited | 2.3660 | 0.002096 | -0.045846 | Pass [capture](../phase2g/captures/software/limited-vp9p2/display.png) |
| Software Hi10P full | 2.3746 | -0.033269 | 0.134710 | Pass [capture](../phase2g/captures/software/full-hi10p/display.png) |
| Software 422 full | 2.1414 | -0.033125 | 0.106739 | Pass [capture](../phase2g/captures/software/full-h264422/display.png) |
| Software VP9 profile 2 full | 2.2581 | -0.033001 | 0.127746 | Pass [capture](../phase2g/captures/software/full-vp9p2/display.png) |
| Software ASP full 8-bit | 7.9559 | -0.100667 | 1.250584 | Refused [capture](../phase2g/captures/software/full-asp/display.png) |
| Software VP9 profile 0 full 8-bit | 2.2080 | -0.018241 | 0.202728 | Refused [capture](../phase2g/captures/software/full-vp9/display.png) |
| Dolby Vision; other software HDR tuples | — | — | — | No matching display oracle qualification |

Vivid-off now enables extended range before applying Automatic dynamic range, fixing the display-layer setting that crushed HDR. Hardware HEVC PQ/HLG provides matching-content display oracles. Known software PQ/HLG fixtures pass; the software HDR predicate remains unchanged and closed because mastering/ambient payload transport is not fully proved.

Full-range ASP loses a container-only range fact when the software adapter derives range from MPEG-4 VOL. Correcting the surface flag alone improves RMS to 2.1466 but still fails range projection at 0.19835. Integer normalization trials also fail; all were removed byte-identically. Full-range VP9 p0 hardware and software captures have identical RGB and the same 0.2027275 projection: the unresolved discrepancy is shared display/reference treatment, not demonstrated software-only expansion. No tolerance was relaxed and no approximate pixel correction ships.

The three fully started sixteen-window software storms have **16 / 17 / 17 preview failures**. A bounded-worker trace identifies `AvcodecWorkerBudgetExceeded`: sixteen playback workers fill the process ceiling and independent preview workers cannot acquire capacity. All three retire **16 → 16 → 0** windows and unload the native images. The first also has one commit-seek drain failure; the other two have none. No zero-failure storm or scheduling fix is claimed. [Raw storm summaries](../phase2g/storm-final-summary.json). The temporary trace was removed byte-identically; resource caps and derived reservations were not increased.

**AVCODEC stays OFF.** Full-range ASP and VP9 p0 fail color qualification; unmeasured software HDR metadata stays closed; three zero-failure storms are absent; the full package fails the macOS 13.3 floor. The codec closure is lazy, no eager native-FFmpeg load command is present, all notices exist, no external/unresolved dependency remains and deep strict signing passes. However 164 bundled images exceed the deployment floor. [Final packaging audit and reproduction limits](../phase2g/PACKAGING.md). Hi10P and H.264 422 can now reach Apple hardware with AVCODEC OFF.

## Final resource table

Fourteen-second quiet launches, CPU as percentage of one core, sampler process joules and peak MiB. Native-refused ASP costs include bundled fallback. The OFF build ignores the no-hardware seam, so those rows are still shipped hardware-capable runs, not software measurements. No energy-improvement claim is made.

| Specimen | CPU % | Process J | Peak MiB | Native drawn / late / superseded |
| --- | ---: | ---: | ---: | --- |
| baseline | 9.37 | 0.630 | 454.0 | 299 / 1 / 0 |
| asp | 15.83 | 1.521 | 517.9 | Native refused; fallback |
| hi10p | 9.93 | 0.666 | 453.8 | 295 / 5 / 0 |
| h264422 | 8.84 | 0.666 | 458.6 | 287 / 13 / 0 |
| vp9 | 8.83 | 0.682 | 460.6 | 268 / 8 / 0 |
| vp9p2 | 9.91 | 0.683 | 454.2 | 300 / 0 / 0 |
| baseline / no-HW seam | 9.75 | 0.673 | 454.5 | 300 / 0 / 0 |
| hi10p / no-HW seam | 7.27 | 0.839 | 452.3 | 300 / 0 / 0 |
| h264422 / no-HW seam | 6.21 | 1.688 | 455.0 | 300 / 0 / 0 |
| vp9 / no-HW seam | 5.46 | 1.984 | 452.0 | 300 / 0 / 0 |
| vp9p2 / no-HW seam | 5.37 | 1.186 | 452.0 | 300 / 0 / 0 |

[Identities, sampler hash, raw usage and streamed metrics](../phase2g/MEASUREMENTS.md).

## Tests, shutdown and remaining work

`cmake --build build --parallel` passes. The final full suite is 122/124 in 399.06 s; packaging and Matroska timed out. Their unchanged isolated reruns pass in 54.58 and 3.36 s, so all 124 tests pass across those runs. The prior pre-registry candidate also has a clean 122/122 full run. No timeout or expectation was relaxed. [Build/test logs and 14 behavior-group revert receipts](../phase2g/TESTS.md).

The prior corpus exposed three aborts after native drawing. PID-matched crash reports showed audio/video global registry mutex destruction racing deferred retirement. Fixed in-place process-lifetime registry storage preserves bounded slots and explicit retirement without a GUI wait or allocation. Both new production-registry exit tests fail with the old registries and pass after byte-identical restoration. The final 97-file corpus has zero abnormal exits. [Crash reports and shutdown proof](../phase2g/SHUTDOWN.md).

DTS specimen inventory remains empty; no DTS-HD MA profile is admitted. Named `SoftwareAudioPacketTimelineUnqualified` (opt-in) and `SoftwareAudioStageNotBuilt` (shipped) boundaries remain. Core-plus-extension and extension-only packets are rejected; the trailing-byte mutant fails and restoration passes. [Timestamped inventory and exact remaining MA requirements](../phase2g/DTS_HD_MA.md).

**Unapplied Proposal 27** replaces the frozen integral `MediaDisplaySize` and `PreparedDescriptor` display fields with exact rationals. Its exact before/after is retained in [PROPOSALS.md](../phase2g/PROPOSALS.md). Further deferred work is PXL rational PCM edit mapping, DV display proof, bounded preview capacity handoff, full-range/HDR metadata qualification, macOS 13.3 dependency packaging and a real DTS-HD MA specimen. No frozen geometry/timeline amendment beyond 26 was applied.

The preceding phase-2f report is preserved [here](../phase2g/PHASE2F_REPORT.md); the amendment ledger through 25 remains in the existing README and phase-2e receipts. The maintainer verifies this uncommitted candidate independently before committing.
