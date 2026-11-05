Fixed on branch `fix-audio-2`, committed as `e0d1621` (Matroska planning) and `235c927` (piecewise AAC proof and rendering). No push or PR. Frozen contracts and frozen tests are unchanged.

All 16 requested specimens, including u088, finish the final quiet sweep **native, every submitted seek drawn, no native-to-fallback transitions**. Final full CTest: **136 passed, 0 failed, 0 skipped**, 52.33 seconds, using `ctest --test-dir build -LE benchmark --output-on-failure -j4`. The requested Release build and dev-bundle libmpv copy completed.

The shared AAC proof now retains exact segment anchors, packet identities and presentation extents. The 256-frame residual bound still applies within each segment; ordinary quantization cannot continually re-anchor cumulative drift. Both AVFoundation and libavformat reuse the open-time proof on seeks. AudioToolbox still decodes 1,024 frames per packet; a bounded PCM mapping queue trims overlapping tails and emits declared gaps as silence. Seek preroll backs off actual packets as well as elapsed time. Non-frame-exact anchors, nonmonotonic timestamps, overflow and unproved timing remain open-time refusals.

Pre-#19 inspection showed that AVFoundation restated compressed durations to their natural decoded length and only snapped one-tick timestamp residuals. The converter required contiguous packets and rejected nonzero trim/silence-fill attachments. It could begin a seek inside an already-shifted region, explaining successful seek sweeps, but did not implement interior overlap trimming. Restoring admission alone would therefore leave failures when playback crossed an artifact.

- **u053:** six duration-1 packets and other short extents break the single grid (minimum residual −7,968 frames). Piecewise trimming restores native playback. A separate AVFoundation range issue omitted two tail AUs when its explicit asset-duration range ended before the audio table; the reader now includes the proved audio tail while publication retains its exact ceiling.
- **u069:** duration-1 and duration-307 overlaps account for 1,740 trimmed frames; a duration-2,144 extent also declares 1,120 silence frames. The clock follows both edits rather than stretching the original grid.
- **u030:** duration-1/943 packets shift the grid by −1,104 frames, followed by a short final extent. All edits are frame-exact at 44.1 kHz and now play natively.
- **u060:** repeated 941/1,107/858 and related extents contain both overlaps and gaps, with minimum residual −10,331 frames. They are exact piecewise edits at 44.1 kHz, not unbounded jitter; the complete decode now drains exactly.
- **u092:** the first AAC AU is at 20 ms, nearest ordinal 1. Planning now clamps preroll to that first present ordinal, declares the exact 20 ms leading silence, and moves the PCM publication floor accordingly. The old search allowed 8,192 clusters while looking for absent ordinal 0; the baseline watchdog selected fallback 10,506 ms after open. A scan now stops at the first later or invalid audio block instead of walking to the file tail. The watchdog threshold is unchanged.

Full-length native audio probes additionally crossed every packet in the four MP4 regressions. Each reported `exact=1 drained=1`, with no error; output was discarded rather than retained as media:

| Specimen | Rate | Decoded frames | Published frames | Trimmed frames | Inserted silence frames |
|---|---:|---:|---:|---:|---:|
| u053.mp4 | 48,000 | 94,280,704 | 94,272,736 | 7,968 | 0 |
| u069.mp4 | 48,000 | 99,986,432 | 99,985,812 | 1,740 | 1,120 |
| u030.mp4 | 44,100 | 4,368,384 | 4,366,924 | 1,460 | 0 |
| u060.mp4 | 44,100 | 122,937,344 | 122,927,013 | 1,417,087 | 1,406,756 |

Before, from a fresh build of `21a4fa3`:

```text
u053.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples; libavformat: AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples"
u069.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples; libavformat: AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples"
u092.mkv fallback@open seeks=0/0 open_to_picture_ms=-1 failure=
u030.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples; libavformat: AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples"
u060.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples; libavformat: AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples"
u002.mkv native seeks=5/5 open_to_picture_ms=759 failure=
u018.mkv native seeks=5/5 open_to_picture_ms=597 failure=
u011.mp4 native seeks=5/5 open_to_picture_ms=170 failure=
u024.mp4 native seeks=5/5 open_to_picture_ms=239 failure=
u032.mp4 native seeks=5/5 open_to_picture_ms=517 failure=
u045.mp4 native seeks=5/5 open_to_picture_ms=1394 failure=
u012.mp4 native seeks=5/5 open_to_picture_ms=323 failure=
u004.mp4 native seeks=5/5 open_to_picture_ms=166 failure=
u005.mp4 native seeks=5/5 open_to_picture_ms=272 failure=
u071.mkv native seeks=5/5 open_to_picture_ms=865 failure=
u088.mp4 native seeks=5/5 open_to_picture_ms=1088 failure=
```

After, from the committed final binary:

```text
u053.mp4 native seeks=5/5 open_to_picture_ms=162 failure=
u069.mp4 native seeks=5/5 open_to_picture_ms=361 failure=
u092.mkv native seeks=5/5 open_to_picture_ms=1051 failure=
u030.mp4 native seeks=4/4 open_to_picture_ms=273 failure=
u060.mp4 native seeks=5/5 open_to_picture_ms=194 failure=
u002.mkv native seeks=5/5 open_to_picture_ms=788 failure=
u018.mkv native seeks=5/5 open_to_picture_ms=458 failure=
u011.mp4 native seeks=5/5 open_to_picture_ms=300 failure=
u024.mp4 native seeks=5/5 open_to_picture_ms=251 failure=
u032.mp4 native seeks=5/5 open_to_picture_ms=569 failure=
u045.mp4 native seeks=5/5 open_to_picture_ms=1815 failure=
u012.mp4 native seeks=5/5 open_to_picture_ms=176 failure=
u004.mp4 native seeks=5/5 open_to_picture_ms=163 failure=
u005.mp4 native seeks=5/5 open_to_picture_ms=276 failure=
u071.mkv native seeks=5/5 open_to_picture_ms=903 failure=
u088.mp4 native seeks=5/5 open_to_picture_ms=986 failure=
```

The sweep's u030 run submitted four seeks and drew all four. An isolated repeat on the same final binary completed all five:

```text
u030.mp4 native seeks=5/5 open_to_picture_ms=259 failure=
```

The blank u092 baseline failure field is the harness's literal output: the watchdog message was “Native playback did not start in time; using compatibility playback.” It fired before the planner's later named failure could surface.

Open-time measurements show that u045 and u088 use libavformat's full packet walk. The final run breaks down as follows (milliseconds; read and witness time are included in scan time):

| Specimen | Open→picture | Native preparation | Cursor open | Packet scan | Packet reads | AAC witness | Generation setup | Outside libavformat open |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| u045.mp4 | 1815 | 1665.6 | 17.928 | 1559.019 | 1530.864 | 6.854 | 13.739 | 224.4 |
| u088.mp4 | 986 | 884.9 | 15.183 | 736.569 | 713.563 | 2.170 | 11.403 | 222.3 |

u045 scans 303,229 packets / 4,774,389,932 payload bytes; u088 scans 297,370 packets / 3,567,613,656 bytes. The cursor already exposes zero-copy packet views. Most cost is packet reading, not the shared AAC arithmetic. The scan also validates packet limits, corruption/configuration side data, video timing and the RAP index. I retained these checks rather than substitute a weaker AAC-only scan. No systematic open-speed improvement is claimed: these are individual runs with cache/load variation. The full demux scan remains the principal startup cost for these two files.

Added runnable coverage:

- `audio_codec_timing`: exact overlap/gap extents, segment anchoring, cumulative one-tick drift refusal, and fractional-frame anchor refusal.
- `matroska_demuxer`: leading nonzero AAC ordinal with exact silence/publication floor, and a missing interior ordinal that fails in fewer than 200 reads despite 100 available clusters.
- `libavformat_aac_timing`: generated AAC payloads with rewritten sample tables; independent expected PCM assembled from the unedited Apple oracle by trimming tails and inserting zeros. Both demux routes are tested at seeks before, inside and after overlaps/gaps, including a gap longer than one second and packet-count preroll. A generated shorter-video/longer-audio case checks reader-tail inclusion. No specimen bytes or excerpts were committed.

The first full-suite attempt exposed signed-conversion warnings in the standalone strict builds, which were fixed, and the existing intermittent caption-service child-start failure. Two subsequent complete suite runs passed; the final result above is from the reviewed binary. No requested specimen remains unresolved. Unsupported timing remains fail-closed; the expensive full libavformat admission scan is retained with its measured cost.

Report copies: [report.md](/private/tmp/wam-audio/report.md) and [wam-audio-report.md](/private/tmp/wam-audio-report.md).

Receipts: `/private/tmp/wam-probe-codex/main.txt`, `final.txt`, `ctest-verified.log`, the per-specimen `final/` telemetry, and `full-u*.log`. Final executable SHA-256: `283443dcb4df5323c6ab99da16ff7782cb60be505fc3f21cb80bfb42f9794020`.
