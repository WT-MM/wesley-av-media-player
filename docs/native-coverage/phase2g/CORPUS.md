# Final shipped corpus

Candidate `a1c2238a282c6206e2a1aacf15741d501dee6968010f0d5e4aafd9780de379f0`. AVFORMAT ON / AVCODEC OFF. Quiet six-second launches, scratch HOME, muted/background geometry 480×270+2400+1000, all four required identity variables. A success requires native selection, a first-frame event, streamed drawn frames >0, no native failure and exit code zero. Every log and streamed sample is retained.

**93/97 native; zero regressions among the original 84; zero abnormal exits.** The four refused files retain named missing-proof diagnostics. [All identities, results and metrics paths](corpus-registry-final/results.json), [summary](corpus-registry-final/summary.json), [probe](corpus-final.py).

| Original refusal | Final outcome | Streamed drawn frames | Clock 1.0000 |
| --- | --- | ---: | --- |
| Screencast from 01-28-2026 04:53:24 PM.mp4 | REFUSED | 0 | not native |
| visual_hand_data_trimmed.mp4 | REFUSED | 0 | not native |
| PXL_20250729_045448421.mp4 | REFUSED | 0 | not native |
| IMG_7267.mp4 | REFUSED | 0 | not native |
| angel_clip2.mp4 | NATIVE_OK | 146 | yes |
| angel1_prep.mp4 | NATIVE_OK | 145 | yes |
| angel2_prep.mp4 | NATIVE_OK | 167 | yes |
| angel2_v.mp4 | NATIVE_OK | 158 | yes |
| angel1_v.mp4 | NATIVE_OK | 162 | yes |
| angel_combined.mp4 | NATIVE_OK | 157 | yes |
| zbot33.mp4 | NATIVE_OK | 77 | yes |
| 495_2.mp4 | NATIVE_OK | 65 | yes |
| amp6.mp4 | NATIVE_OK | 72 | yes |

Exact remaining diagnostics:

- `Screencast from 01-28-2026 04:53:24 PM.mp4`: `WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AnamorphicExactRationalDisplaySizeProofMissing; libavformat: LibavformatPresentationMetadataUnsupported"`
- `visual_hand_data_trimmed.mp4`: `WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AnamorphicExactRationalDisplaySizeProofMissing; libavformat: LibavformatPresentationMetadataUnsupported"`
- `PXL_20250729_045448421.mp4`: `WAM: native failure stage=steady reason=Decode class=Consumer error="CoreMediaAudioEditExactTimelineProofMissing: input/output timing contains an edit"`
- `IMG_7267.mp4`: `WAM: native failure stage=open reason=Startup class=UnsupportedSource error="DolbyVisionDisplayOracleProofMissing; libavformat: LibavformatAudioTimingUnproven: aac"`

Six RustDesk recordings and appleads:

| File | Drawn frames | Clock |
| --- | ---: | --- |
| appleads.mp4 | 139 | 1.0000 |
| outgoing_175981962_20260208203414622_display0_h265.mp4 | 137 | 1.0000 |
| outgoing_175981962_20260208220322285_display0_h265.mp4 | 143 | 1.0000 |
| outgoing_175981962_20260208215604603_display0_h265.mp4 | 116 | 1.0000 |
| outgoing_175981962_20260208205646393_display0_h265.mp4 | 158 | 1.0000 |
| outgoing_175981962_20260208210701843_display0_h265.mp4 | 122 | 1.0000 |
| outgoing_175981962_20260127121923093_display0_h265.mp4 | 10 | 1.0000 |

The previous candidate had three shutdown aborts after native draws; those launches were not counted as successes. Their unchanged isolated reruns passed, and the subsequently diagnosed registry lifetime defect was fixed and revert-tested. [Shutdown evidence](SHUTDOWN.md), [earlier complete corpus](corpus-final-complete/results.json), [earlier isolated reruns](shutdown-isolated/results.json). The final corpus above uses the fixed candidate and has no abnormal exit.
