# Final shipped corpus

Candidate `a1c2238a282c6206e2a1aacf15741d501dee6968010f0d5e4aafd9780de379f0`. AVFORMAT ON / AVCODEC OFF. Quiet six-second launches, scratch HOME, muted/background geometry 480×270+2400+1000, all four required identity variables. A success requires native selection, a first-frame event, streamed drawn frames >0, no native failure and exit code zero. Every log and streamed sample is retained.

**93/97 native; zero regressions among the original 84; zero abnormal exits.** The four refused files retain named missing-proof diagnostics. [All identities, results and metrics paths](corpus-registry-final/results.json), [summary](corpus-registry-final/summary.json), [probe](corpus-final.py).

| Original refusal | Final outcome | Streamed drawn frames | Clock 1.0000 |
| --- | --- | ---: | --- |
| warm_bridge_06.mp4 | REFUSED | 0 | not native |
| pine_valley_48.mp4 | REFUSED | 0 | not native |
| green_vista_85.mp4 | REFUSED | 0 | not native |
| lake_summit_29.mp4 | REFUSED | 0 | not native |
| sunny_jetty_60.mp4 | NATIVE_OK | 146 | yes |
| river_street_45.mp4 | NATIVE_OK | 145 | yes |
| pine_creek_47.mp4 | NATIVE_OK | 167 | yes |
| cedar_grove_48.mp4 | NATIVE_OK | 158 | yes |
| cobalt_bay_46.mp4 | NATIVE_OK | 162 | yes |
| green_park_61.mp4 | NATIVE_OK | 157 | yes |
| olive_crossing_24.mp4 | NATIVE_OK | 77 | yes |
| quiet_street_22.mp4 | NATIVE_OK | 65 | yes |
| copper_pier_21.mp4 | NATIVE_OK | 72 | yes |

Exact remaining diagnostics:

- `warm_bridge_06.mp4`: `WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AnamorphicExactRationalDisplaySizeProofMissing; libavformat: LibavformatPresentationMetadataUnsupported"`
- `pine_valley_48.mp4`: `WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AnamorphicExactRationalDisplaySizeProofMissing; libavformat: LibavformatPresentationMetadataUnsupported"`
- `green_vista_85.mp4`: `WAM: native failure stage=steady reason=Decode class=Consumer error="CoreMediaAudioEditExactTimelineProofMissing: input/output timing contains an edit"`
- `lake_summit_29.mp4`: `WAM: native failure stage=open reason=Startup class=UnsupportedSource error="DolbyVisionDisplayOracleProofMissing; libavformat: LibavformatAudioTimingUnproven: aac"`

Six RustDesk recordings and dusk_arch_18:

| File | Drawn frames | Clock |
| --- | ---: | --- |
| dusk_arch_18.mp4 | 139 | 1.0000 |
| misty_mill_52.mp4 | 137 | 1.0000 |
| lake_field_56.mp4 | 143 | 1.0000 |
| west_canyon_55.mp4 | 116 | 1.0000 |
| winter_river_53.mp4 | 158 | 1.0000 |
| lunar_village_54.mp4 | 122 | 1.0000 |
| azure_inlet_51.mp4 | 10 | 1.0000 |

The previous candidate had three shutdown aborts after native draws; those launches were not counted as successes. Their unchanged isolated reruns passed, and the subsequently diagnosed registry lifetime defect was fixed and revert-tested. [Shutdown evidence](SHUTDOWN.md), [earlier complete corpus](corpus-final-complete/results.json), [earlier isolated reruns](shutdown-isolated/results.json). The final corpus above uses the fixed candidate and has no abnormal exit.
