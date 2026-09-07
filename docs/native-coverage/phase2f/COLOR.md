# Display qualification

The temporary codec-ON capture candidate bypassed only VideoDecodeLane's color guard. That bypass was removed byte-identically before the acceptance build. The source defaults were never changed. Every launch used the build app, isolated scratch HOME, all four identities, background/mute and 480x270+2400+1000 geometry. Both QML `grab` and composited `videograb` are retained: `grab` excludes the AVSampleBufferDisplayLayer and cannot qualify its video.

Hardware candidate: `fe0701859a9b9aa5341b97ef496235b108ed5df4cb4ae46709b4539fadd9a11d`. Temporary software capture candidate: `67999ffe77c1ebabe22a5b77310722a98046002545230856ee1a02acaff4e0a2`.

The corrected phase-2c method is unchanged: source BT.709 inversion, source SMPTE-C to linear BT.709 primaries, sRGB transfer; display ICC to sRGB; flat-patch mask. Limits remain absolute matrix/range projection ≤0.15 and RMS ≤6/255. Admission requires real native video, not an error-window image. Earlier sandbox launches aborted before window-service access; their logs are retained. No black image or refused decoder is treated as a color measurement.

| Software family | RMS /255 | Matrix projection | Range projection | Decision |
| --- | ---: | ---: | ---: | --- |
| [ASP limited](captures/paired-software/limited-asp/display.png) | 2.020 | −0.0035 | −0.0408 | Retain admission |
| [H.264 Hi10P limited](captures/paired-software/limited-hi10p/display.png) | 2.371 | 0.0017 | −0.0454 | Retain admission |
| [H.264 4:2:2 10-bit limited](captures/paired-software/limited-h264422/display.png) | 2.394 | 0.0045 | −0.0446 | Retain admission |
| [VP9 p0 limited](captures/paired-software/limited-vp9/display.png) | 2.092 | −0.0021 | −0.0441 | Admit |
| [VP9 p2 limited](captures/paired-software/limited-vp9p2/display.png) | 2.366 | 0.0021 | −0.0458 | Admit |
| [H.264 Hi10P full](captures/paired-software/full-hi10p/display.png) | 2.375 | −0.0333 | 0.1347 | Admit |
| [H.264 4:2:2 10-bit full](captures/paired-software/full-h264422/display.png) | 2.141 | −0.0331 | 0.1067 | Admit |
| [VP9 p2 full](captures/paired-software/full-vp9p2/display.png) | 2.258 | −0.0330 | 0.1277 | Admit |
| [ASP 8-bit full](captures/paired-software/full-asp/display.png) | 7.956 | −0.1007 | 1.2506 | Keep `SoftwareColorUnqualified` |
| [VP9 p0 full](captures/paired-software/full-vp9/display.png) | 2.208 | −0.0182 | 0.2027 | Keep `SoftwareColorUnqualified`; hardware also exceeds range projection |
| [H.264 PQ software](captures/paired-software/h264-smpte2084/display.png) | 0.387 vs HEVC hardware content oracle | Unqualified | Unqualified | Keep `SoftwareColorUnqualified`: HDR projection reference absent |
| [H.264 HLG software](captures/paired-software/h264-arib-std-b67/display.png) | 77.533 vs HEVC hardware content oracle | Unqualified | Unqualified | Keep `SoftwareColorUnqualified`: displayed mismatch and HDR projection reference absent |

VP9 limited p0/p2 and full p2 software/hardware display pixels match exactly. Full-range Hi10P/422 match the passing VP9 p2 hardware content oracle at RMS 0.182/255 (different encodings of the same bars). The 8-bit full-range H.264 control has degenerate wrong-range references and is not an acceptance oracle. Its Apple software route remains outside the libavcodec color gate.

PQ/HLG fixtures explicitly set frame and bitstream primaries/transfer/matrix, verified in `hdr-facts.json`. Earlier HDR attempts lost transfer/primaries tags; those captures are retained under `paired-hardware` but excluded. The valid HEVC hardware controls are under `paired-hdr-hardware`. The SDR reference transform is not applied to HDR. PQ pixel proximity alone does not prove HDR luminance or matrix/range correctness; HLG's large mismatch is an observation, not an attribution to a specific conversion step.

Evidence: [software projections](software-sdr-projections.json), [hardware limited](oracle-sdr.json), [hardware full](oracle-full.json), [paired pixels](paired-rms.json), [full 10-bit content oracle](full10-hardware-comparison.json), [capture manifest](capture-manifest.json). PNGs, original logs, metrics and generated fixtures are retained under [captures](captures/). `capture-command.py` and `analyze-command.py` preserve scratch commands; they are campaign receipts, not general test entry points. The generic projection tool's exploratory error-UI rows are excluded from this table.

The full-range ASP capture exposed a separate admission gap: its range was present only in Matroska Colour, while VideoDecodeLane inspected the MPEG-4 configuration record. Container range therefore bypassed the original guard. Matroska now refuses before publishing a descriptor, and libavformat carries the range fact into the same cold admission predicate. Both use `SoftwareColorUnqualified: MPEG-4 full-range container signaling`. The retained full-range fixture exercises the real libavformat source; a synthetic Matroska regression pins the same named refusal. No frozen descriptor or playback contract was widened.
