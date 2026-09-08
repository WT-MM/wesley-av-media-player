# Phase 2g display qualification

Retained tolerances: RMS ≤ 6 eight-bit RGB units and absolute matrix/range projection ≤ 0.15. Captures are ICC-converted to sRGB. Flat patch interiors exclude boundaries. Every capture, including failed controls and superseded experiments, is retained in [captures](captures/). Production captures use the direct CALayer display route; Qt grabs alone are not display proof. Hardware and software oracle fixtures carry the same content and explicit descriptors. Detailed numerical receipts accompany this table.

| Family | RMS | Matrix projection | Range projection | Verdict / capture |
| --- | ---: | ---: | ---: | --- |
| Apple H.264 4:4:4 8-bit 601 limited | 0.0242 | 0.000034 | 0.000019 | Pass [capture](captures/corrected-hardware/444-601/display.png) |
| Apple H.264 4:4:4 8-bit 709 limited | 0.0215 | -0.000017 | 0.000016 | Pass [capture](captures/corrected-hardware/444-709/display.png) |
| Apple H.264 HLG 2020 limited | 0.0771 | -0.000097 | -0.000228 | Pass [capture](captures/corrected-hardware/hlg-h264/display.png) |
| Apple HLG with exact ambient payload | 0.3681 | 0.021374 | -0.015268 | Pass [capture](captures/corrected-hardware/hlg-h264-ambient/display.png) |
| Software H.264 PQ 2020 limited 10-bit 420 | 0.5147 | 0.042568 | -0.005161 | Pass [capture](captures/software/pq-h264/display.png) |
| Software H.264 HLG 2020 limited 10-bit 420 | 2.1391 | -0.083126 | 0.128465 | Pass [capture](captures/software/hlg-h264/display.png) |
| Software ASP limited 8-bit | 2.0198 | -0.003474 | -0.040821 | Pass [isolated capture](captures/software-limited-asp-retry/display.png) |
| Software Hi10P limited | 2.3713 | 0.001662 | -0.045358 | Pass [capture](captures/software/limited-hi10p/display.png) |
| Software 422 limited | 2.3939 | 0.004533 | -0.044583 | Pass [capture](captures/software/limited-h264422/display.png) |
| Software VP9 profile 0 limited | 2.0921 | -0.002075 | -0.044093 | Pass [capture](captures/software/limited-vp9/display.png) |
| Software VP9 profile 2 limited | 2.3660 | 0.002096 | -0.045846 | Pass [capture](captures/software/limited-vp9p2/display.png) |
| Software Hi10P full | 2.3746 | -0.033269 | 0.134710 | Pass [capture](captures/software/full-hi10p/display.png) |
| Software 422 full | 2.1414 | -0.033125 | 0.106739 | Pass [capture](captures/software/full-h264422/display.png) |
| Software VP9 profile 2 full | 2.2581 | -0.033001 | 0.127746 | Pass [capture](captures/software/full-vp9p2/display.png) |
| Software ASP full 8-bit | 7.9559 | -0.100667 | 1.250584 | Refused [capture](captures/software/full-asp/display.png) |
| Software VP9 profile 0 full 8-bit | 2.2080 | -0.018241 | 0.202728 | Refused [capture](captures/software/full-vp9/display.png) |
| Dolby Vision; other software HDR tuples | — | — | — | No matching display oracle qualification |

Vivid-off previously set the display layer to Standard dynamic range and disabled extended range. It now requests extended range, then applies Automatic after the legacy setter. No exposure filter is installed. Hardware HEVC PQ/HLG supplies the HDR oracle with matching wrong-matrix and wrong-range controls. The ambient qualification admits only payload `002fe9a03d134042` on the 2020/HLG/2020-NCL ten-bit 420 tuple. A production decoder fixture verifies that all 100 decoded surfaces retain the exact payload. Dolby Vision remains independently refused.

Full-range ASP loses the container range fact: MPEG-4 VOL has no matching range field, while the software adapter derives its range from codec configuration. A temporary full-range surface correction reduced RMS from 7.9559 to 2.1466 but left range projection 0.19835, still outside tolerance. Two bounded integer normalization experiments also failed (ASP/VP9 projections 0.21655/0.22052 and 0.16628/0.17012). All experimental pixel transformations were removed byte-identically. No approximate compensation ships.

Full-range VP9 profile 0 hardware and software captures have identical RGB pixels and the same 0.2027275 range projection against the retained independent reference. This localizes the remaining discrepancy to the shared full-range display/reference treatment, not a software-only expansion. It does not waive the reference tolerance. The codec gate stays closed.

The initial 709 oracle was invalid because an implicit FFmpeg matrix conversion changed source samples. The corrected explicitly tagged hardware controls preserve decoded YUV samples and pass both matrix/range projections. Shifted and no-signal captures are retained but excluded; their isolated replacements are identified in receipts. The direct FFmpeg 709 exploratory reference also failed its matrix projection and is not substituted for the owner's hardware oracle.

The final software admission predicate remains unchanged and refuses HDR: the passing PQ/HLG fixtures do not prove transport of every mastering/ambient payload through the software adapter. The provisional narrow HDR predicate was tested and then removed on this review finding. Table passes describe measured fixtures, not blanket admission of their family.
