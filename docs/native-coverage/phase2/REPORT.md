# Phase 2f — AVFORMAT ON; AVCODEC OFF

Apple order remains VideoToolbox hardware → VideoToolbox software → AudioToolbox → libvpx → libavcodec last. Native admission remains fail-closed. Changes are uncommitted; no staging or prohibited Git mutation was performed. Frozen source/contract/audio-test files are byte-identical; SESSION_HANDOFF.md is untouched.

## Display qualification

Captures were performed first, before the long build/measurement work. Both in-process `grab` and composited `videograb` are retained; the QML-only grab excludes AVSampleBufferDisplayLayer and is not a video-color oracle. No failed/black capture was interpreted as color evidence. The temporary color bypass was removed byte-identically before acceptance builds.

| Family | Display result | Final color admission |
| --- | --- | --- |
| Limited ASP / Hi10P / H.264 422 | RMS 2.020 / 2.371 / 2.394; projections within limits | Retained |
| Limited VP9 p0 / p2 | RMS 2.092 / 2.366; exact hardware/software pixel matches | Qualified |
| Full Hi10P / H.264 422 / VP9 p2 | RMS 2.375 / 2.141 / 2.258; range projections 0.1347 / 0.1067 / 0.1277 | Qualified |
| Full 8-bit ASP | RMS 7.956; range projection 1.2506 | `SoftwareColorUnqualified` |
| Full VP9 p0 | Range projection 0.2027; hardware also fails retained threshold | `SoftwareColorUnqualified` |
| PQ software H.264 | RMS 0.387 versus hardware content oracle; HDR projection reference unqualified | `SoftwareColorUnqualified` |
| HLG software H.264 | RMS 77.533 versus hardware content oracle; HDR reference unqualified | `SoftwareColorUnqualified` |

No tolerance changed: RMS ≤6/255 and absolute matrix/range projections ≤0.15. [Full per-family table, controls and direct capture paths](../phase2f/COLOR.md); [retained PNG directory](../phase2f/captures/). The MPEG-4 full-range fixture exposed container-only signaling that bypassed the old codec-record guard. Both Matroska and libavformat now refuse it before descriptor publication with `SoftwareColorUnqualified: MPEG-4 full-range container signaling`.

## Stage decisions

| Stage | Final shipped state | Reason |
| --- | --- | --- |
| Apple VideoToolbox / AudioToolbox and libvpx | Available, existing priority retained | Apple-first route unchanged |
| `WAM_ENABLE_AVFORMAT_STAGE` | ON | Existing demux expansion retained |
| `WAM_ENABLE_AVCODEC_STAGE` | OFF | Incomplete 8-bit full-range/HDR qualification; software cancellation storm is not zero-failure |

The sixteen-window software storm has zero native session failures but **17 preview failures**, 17 submitted/ready/drawn commit chains, one preview draw and **16 → 16 → 1** windows. A live final window means its resident native images are not proof of a post-retirement leak. The matching hardware control has zero session/preview failures, 17 complete commit chains, 16 preview draws and **16 → 16 → 0** windows. Isolated allocator/worker tests preserve the derived reservations, sixteen-worker ceiling, seventeenth refusal and cancellation retirement. No cap or tolerance was increased. [Gate details](../phase2f/STAGES.md).

The retained local package has a lazy native codec closure and no eager native FFmpeg load command. Its complete deployment floor remains 26.0; the native FFmpeg closure itself retains 13.3. Clean-machine 13.3 packaging qualification remains deferred. The final refresh audits 171 Mach-O files with zero external/unresolved dependencies, zero dependency errors, a relocatable closure and no eager native FFmpeg load. The complete 13.3 compatibility gate still fails; the generic audit exit label is not interpreted as a relocation failure. [Final audit](../phase2f/package-audit.json).

## DTS-HD MA

Read-only ffprobe search over Movies and Downloads inspected **845 candidates: 734 probeable, 111 malformed/fragment failures, zero DTS tracks found**. No HD-MA admission is made. Core-plus-extension and extension-only packet shapes remain refused before descriptor publication; a trailing-byte-acceptance mutant fails the existing test. The named opt-in refusal is `SoftwareAudioPacketTimelineUnqualified`; shipped software audio remains `SoftwareAudioStageNotBuilt`. [Search inventory, refusal proof and exact admission requirements](../phase2f/DTS_HD_MA.md).

## Late frames

The historical full RustDesk run remains **49,832 = 49,827 drawn + 5 late**. These were mid-playback, not seek or first-frame losses; three fall in a shared host-second across concurrent players. Packet intervals include 7/9 ms, but one-second aggregate telemetry cannot determine each frame's exact scheduler/decode/output-credit delay. The five are not relabeled inherent or drawn.

A verified mixed-route limitation is fixed: video deadlines now wake independently of audio callbacks while retaining the audio clock and silent-only heartbeat. The 987-frame mixed remux improves in isolated repeats from **968 drawn + 19 late** to **979 drawn + 8 late**, with exactly **1,995,408 audio frames**, zero clock-advancing underruns and clock approximately 1.0000. This does not erase the historical 14 mixed late frames or establish an inherent residual bound. Exact historical attribution/all-drawn remains deferred. [Metrics and revert proof](../phase2f/LATE_FRAMES.md).

## Coexistence

Fixed. The observed conflict was WAM's blanket image-name exclusion. TWOLEVEL native imports target the suffixed utility image; real native/mpv symbols resolve to distinct images and independent `av_log` levels. Native table resolution now uses `RTLD_LOCAL | RTLD_FIRST`; both old loader exclusions are removed while validation and leases remain.

Real fallback-first → native software ASP and native-first → fallback both pass in one process, with both closures in vmmap and native progress after fallback-window closure: **43 → 142** and **45 → 184** drawn frames respectively. The local retained packaged closure repaired the stale development fallback seed for these proofs. mpv remains cached for process lifetime, so dual-closure memory remains a cost; the native admission ban is gone. [Symbol checks, image maps, measured sequences and both revert proofs](../phase2f/COEXISTENCE.md).

## Final validation

Final shipped executable SHA-256: `fbe7928d2adfa6f8ac086dabbe4034b09ab00ec61cc11c79fbf07d36990438f4`.

Final OFF CTest: all **112/112** pass across the full suite (111/112, 207.36 s) and the unchanged GL-output rerun (1/1, 3.24 s). [Full log](../phase2f/ctest-shipped-final.txt), [rerun](../phase2f/ctest-shipped-final-rerun.txt). All eleven resource launches exit 0; every successful native row draws 300 frames with zero late/superseded frames. [Final CPU / process J / peak MiB table](../phase2f/MEASUREMENTS.md). The prescribed quiet six-second corpus rerun finishes **84/97 native, zero regressions against phase 2e's 84/97**. Each native result requires native route/first-frame events, exit 0, no native failure and **drawn_frames > 0 in streamed metrics**. [Final summary](../phase2f/corpus-final-summary.json), [all 97 results](../phase2f/corpus-final-results.json), [retained logs/metrics](../phase2f/corpus-final/).

All 139 opt-in tests passed across the complete suite and unchanged reruns; the first complete pass was 137/139. Original probe and GL render-wait failures are retained. Every behavior change has a fixed/reverted/restored failure proof; the existing DTS guard also has a 0/7/0 mutation proof. [Test details and receipts](../phase2f/TESTS.md).

Proposals: none; no frozen-file change is needed by this patch. Deferrals: failed/unqualified color families, zero-failure sixteen-window software storm, real HD-MA specimen/proof, individual historical late-frame attribution and all-drawn residual work, and complete 13.3 deployment qualification. Previous final report: [phase-2e history](../phase2f/PHASE2E_REPORT.md).
