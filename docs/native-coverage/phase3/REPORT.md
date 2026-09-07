# Phase 3 demux stage — working-tree acceptance report

This is an **opt-in, incomplete phase 3 candidate**, not release acceptance.
The new libavformat source recovers the six retained RustDesk recordings while
keeping HEVC on VideoToolbox hardware. The checked-in phase-2/2b status is still
incomplete: its libavcodec audio backend is not connected to production, and
its release option remains disabled. This change preserves those defaults.
No commit, staging operation or installed-player modification was performed.

Build with both `WAM_ENABLE_AVCODEC_STAGE=ON` and
`WAM_ENABLE_AVFORMAT_STAGE=ON`. The pinned FFmpeg 9.0.1 SDK was rebuilt offline
from the existing archive, SHA-256
`cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635`.
The phase-2 prefix, suffixed dylib names, lazy loader and bundle layout remain.
The added library is `libavformat-wamnative.63.dylib`. Nine demuxers and the
file protocol are enabled; muxers, network protocols, GPL and nonfree are off.
The native closure's three libraries have the macOS 13.3 deployment floor.

## Ownership and limits

`LibavformatCursor` owns one interleaved packet cursor and one file descriptor.
`LibavformatMediaSource` scans that cursor at admission, retains only a bounded
RAP index, and seeks the same cursor to its real first packet. It does not use
`NativeCustomSourceCore` or duplicate payload-free lane cursors. It publishes
the existing descriptor, prepared-context, sample, EOS and generation types.
Demux selection does not alter `VideoDecodeLane` or the audio converter ladder.

| Storage/work | Bound |
| --- | --- |
| Custom AVIO buffer | 64 KiB |
| Packet exposed to WAM | 4 MiB |
| Probe bytes / index configuration | 8 MiB / 4 MiB |
| Read I/O / open or seek I/O budget | 8 MiB / 32 MiB per operation |
| Probe stream/packet limits | 32 streams / 256 probe packets |
| Admission scan | 2 million packets / 16 GiB compressed payload |
| Retained RAPs | 65,536 timestamps |
| Published payload ownership | 32 preallocated storage tokens; one staged head |
| Nonselected interleave walk | 4,096 packets per adapter call |
| ISO top-level scan | 65,536 boxes |

FFmpeg's internal allocation is **not** proven to fit the sum of those
configuration limits. CoreMedia sample and block creation also allocates on
the source worker. WAM storage-token control blocks are preallocated, but a
literal allocation-free adapter-loop acceptance claim is not established.
[Worker measurements](allocation-measurements.json) count 145,397 allocator
calls and five lock calls across 20,772 source packets on the longest RustDesk
file, with zero C++ `new` calls in the measured loop. Cursor-only work counts
62,253 allocator calls and zero locks. Tracking starts after admission and does
not bound the entire private heap. The counter's historical `frames` label means
packets for this harness; its two unused adapter-domain columns are not a
separate adapter measurement. Shared-library interposition is required.
These are qualification blockers, not a measured total-memory promise.

Generation-tagged atomic cancellation rejects stale requests. AVIO checks it,
FFmpeg's interrupt callback checks it, and each bounded scan checks it. Reads
check file identity/size/mtime; preview reopen also checks the original file
identity. Secondary I/O is denied. Blocking filesystem calls are not an
interruptible network-I/O latency proof; BufferedLocal has preflight coverage,
not a retained mounted-filesystem campaign. Remote URLs remain excluded.

PTS/DTS conversion uses checked integer reduction of timestamp × time base.
Unknown PTS stays unknown and cannot be admitted as a fabricated timeline.
Matroska DTS stays unknown because its blocks do not carry DTS. Fragment-tail
inspection hides an incomplete final moof/mdat pair and retains complete
fragments. Missing initialization returns exactly:
`this recording is incomplete: its initialization metadata is missing`.

Accurate video seeks select a preceding indexed RAP, stage its actual packet,
and preserve generation retirement/preroll. Previews reopen one independent
cursor and reuse the production preview decoder stages. Opus accurate seeks
currently preroll from the origin; publication starts at `ceil(T×48000)/48000`.

## Routing before and after

| Input | Before | Opt-in candidate |
| --- | --- | --- |
| Admitted ordinary MP4/MOV | AVFoundation | AVFoundation |
| Admitted MKV/WebM or TS | WAM demuxer by extension | Same demuxer, selected by bytes |
| RustDesk / refused fragmented MP4 | AVFoundation refusal | AVFoundation inspection → libavformat before publication |
| Incomplete final MP4 fragment | AVFoundation could admit then fail | Bounded box-tail inspection → libavformat before publication |
| AVI, FLV, Ogg, ASF, RM, MPEG-PS | AVFoundation | Signature-selected libavformat |
| Header-stripped MKV | WAM refusal | WAM inspection → libavformat before publication |
| Other refused MKV/TS carriage | WAM refusal | Libavformat admission attempted; codec/timeline gates still apply |
| Incorrect extension | Extension-selected source | Recognized bytes win; extension is a hint |
| Buffered local file | Compatibility route | Libavformat admission allowed; mount performance unqualified |
| Remote URL | Compatibility route | Unchanged |

A successful handoff logs `WAM: native demux stage=Libavformat` and never
publishes a failed native generation. If both stages refuse, the primary
reason is preserved alongside the second reason. Linked Matroska segments
remain refused instead of being silently flattened.

## Measured specimens

The [manifest](specimen-manifest.json) contains generator argv and hashes.
[Bitstream facts](specimen-facts.json) and the [fixture toolchain](fixture-toolchain.json)
record the actual emitted profiles and generator build.
The synthetic video specimens are small 160×96, 25 fps, three-second files.

| Specimen | Route → decoder / refusal | Proof |
| --- | --- | --- |
| Fragmented AVC MP4, video only | AVFoundation preferred; libavformat also independently proven → VT hardware | 75 packets; source seek, context, preview and EOS checks |
| Boundary / mid-moof / mid-mdat truncation | AVFoundation for complete box boundary; libavformat for incomplete fragment → VT hardware AVC | 50 retained packets each; final incomplete fragment trimmed; recovered-tail app run has no native failure |
| Missing initialization | Named refusal above | Exact diagnostic asserted; no prepared context |
| ASP AVI, qpel, no B frames | Libavformat → libavcodec | 75/75 decoded frames, exact PTS/duration, EOS; [receipt](asp-decode.log) |
| Reordered ASP AVI | `LibavformatExactVideoTimelineUnavailable` | Demuxed unknown PTS is preserved; no synthesized PTS |
| Header-stripped MKV | WAM inspection → libavformat → AVC | 75 packets, successful pre-publication handoff, preview/seek checks |
| Ogg Opus, mono | Libavformat → AudioToolbox | Full PCM reference comparison and exact seeks below |
| H.264/AAC FLV | `LibavformatAudioTimingUnproven: aac` | Exact refusal test |
| WMV2/WMA2 ASF | `LibavformatAudioTimingUnproven: wmav2` | Exact refusal test |
| Ogg Vorbis | `LibavformatAudioTimingUnproven: vorbis` | Exact refusal asserted |
| MPEG-2/AC-3 VOB program stream | `LibavformatAudioTimingUnproven: unmapped codec` | Exact refusal asserted; the diagnostic codec-name map does not yet name AC-3 |
| Theora / RealMedia | Demuxer built; no qualified specimen | Theora encoder absent; no real RM decoder proof |

[Opus PCM proof](opus-audio-proof.json): targets 0, 1/7, 1 and 2.999 seconds
produce 144000, 137142, 96000 and 48 retained frames respectively. First frame
indices are 0, 6858, 48000 and 143952. Best alignment lag is zero in all cases;
maximum float error is 7.450580596923828e-8. The reference uses WAM's mono to
dual-mono mapping. Priming and final padding are applied once. This does not
prove mixed-stream `|V−A|=0`; no new mixed A/V route is claimed qualified.

[Differential proof](differential.json): MKV agrees for 75 packets / 50,520
bytes; TS for 75 packets / 51,080 bytes. All 150 packet payloads, PTS, DTS,
durations and key flags agree exactly with the existing WAM demuxers. These
are shared video fixtures, not an audio-carriage differential campaign.

[Full RustDesk decode proof](rustdesk-full-decode.json): all six read-only
3840×2160 HEVC files decoded through the production VideoDecodeLane with
hardware=true and clean EOS. Counts: 987, 20,772, 2,058, 7,242, 3,312 and
15,461 frames: **49,832 total**, each with exact PTS and duration. These files
are video only. The receipt binds every asset and the compiled probe by hash.

The [delivery corpus](corpus/summary.json) is **84/97 native**, baseline 78/97,
with **zero regressions**. All six gains are RustDesk. The measured executable
SHA-256 is `0ce0b2b8f7dfa45ce79706dc30eecab2dcc1567d3b1e2cdc69af4bfb0b77a2c0`.
These six-second corpus trials prove native selection and first-frame draw;
the separate full-decode campaign proves all RustDesk frames through EOS.

[Final RustDesk seek trials](rustdesk-seek-summary.json) produce 12 committed
seeks, 12 ready events and 12 committed-frame draws without native failures.
The 360 ms scripted gestures produced eight preview-frame draws across four
files; two trials committed before a preview draw was recorded. The
[headless preview proof](preview-decode.json) checks exact interval coverage,
including hardware HEVC at 20 seconds and software ASP at 0.5 seconds.
The ASP app trial also records real software preview-frame draws. This does
not claim a complete paused/backward/long-GOP performance campaign.

The final [per-container app receipts](delivery-specimens) distinguish native
video, native audio and named refusal. Opus renders exactly 144,000 frames;
RustDesk contains no audio, so A/V offset is not applicable to those files.
The [reproducibility check](fixture-determinism.json) regenerates all 15
specimens twice with identical hashes using bitexact muxing.

[Runtime verification](verify-runtime.json) passes on the delivery build.
The [scratch bundle audit](bundle-audit-final.json) and
[deep signature check](bundle-signature.txt) pass. The packaging transaction
audited 171 Mach-O files; the final executable was refreshed with the same
bundle-relative dependency paths and signed again. The native FFmpeg dylibs
remain at macOS 13.3, while the current local Qt/libvpx closure raises the full
bundle minimum to **macOS 26.0**. This is not a 13.3 release artifact.
Qt deployment required repairing copied Homebrew QML/plugin symlinks in the
scratch bundle. A fresh local mpv seed replaced its stale fallback seed.
The developer build's existing fallback still references missing FFmpeg .62;
its refused specimens therefore remain named refusals. No scratch/installed
app executable was launched: GUI proofs used only build/WAM.app.

## Verification and amendments

The complete [ctest run](ctest-final.txt) passed **121/121**, 112.41 seconds.
The build finished before ctest. An earlier run exposed a routing diagnostic
regression; preserving the first refusal fixed it. An isolated environmental
SIGKILL was rerun successfully. A later external DTS fixture encoder SIGBUS
was followed by a fully green rerun; no production decoder change was made
to mask that generator failure.

[Fourteen isolated mutants](revert-proofs.json) fail their behavioral assertions:
removing the stage, fragment recovery, missing-init diagnostic, exact PTS,
unknown Matroska DTS, preceding-RAP seek, matching cancellation, preview
binding, payload retention, file growth, preview file identity, preview decoder-stage
selection, early fragment-recovery routing, and
pre-publication header-stripping handoff. Mutants were compiled
under /private/tmp without temporarily editing the working tree. This is not
an exhaustive mutation proof of every new branch.

SESSION_HANDOFF's append-only ledger records amendment 22 (append Libavformat
to MediaSourceBackendKind, PROPOSAL 3) and amendment 23 (demux-worker scope,
PROPOSAL 7). No other frozen source/test was edited. Existing configuration
kinds suffice: avcC/hvcC, an ESDS wrapper for MPEG-4 Visual, and the existing
Opus AudioMagicCookie seam. No arbitrary AVCodecID becomes a WAM codec enum.

## Remaining acceptance work

Mixed A/V, Vorbis variable-block timing, WMA/RealMedia/MPEG-PS codec ingress,
reordered AVI with absent PTS, private demux heap accounting, allocation-free
sample ingress, mounted-local cancellation/performance, and the full seek/
preview presentation matrix remain unqualified. Release remains disabled.
The source refuses mixed A/V before decoding; WMA2, Vorbis and AC-3 are not
silently dropped. Unsupported inputs still enter the existing compatibility
admission path, which logs named native refusals. Removing that protocol and
its fallback runtime is deferred. The phase-2 audio-routing and source-distribution/license blockers still
apply. No new proposal silently broadens timeline or presentation semantics.
