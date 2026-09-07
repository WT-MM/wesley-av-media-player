# Final shipped measurements

| Specimen / mode | Shipped outcome | CPU % one core | Process J | Peak MiB | Drawn / late / superseded |
| --- | --- | ---: | ---: | ---: | ---: |
| H.264 8-bit | VideoToolbox hardware | 7.61 | 1.342 | 460.0 | 300 / 0 / 0 |
| MPEG-4 ASP | Refused: codec configuration | 2.77 | 1.238 | 469.4 | — |
| H.264 Hi10P | Refused: SPS/reorder admission | 2.83 | 1.247 | 471.9 | — |
| H.264 4:2:2 10-bit | Refused: SPS/reorder admission | 2.78 | 1.245 | 474.1 | — |
| VP9 p0 | VideoToolbox hardware | 7.75 | 1.284 | 459.8 | 300 / 0 / 0 |
| VP9 p2 | VideoToolbox hardware | 7.71 | 1.265 | 453.6 | 300 / 0 / 0 |
| H.264 8-bit / no-hardware seam | VideoToolbox hardware | 7.88 | 1.329 | 453.7 | 300 / 0 / 0 |
| H.264 Hi10P / no-hardware seam | Refused: SPS/reorder admission | 2.79 | 1.241 | 473.2 | — |
| H.264 4:2:2 10-bit / no-hardware seam | Refused: SPS/reorder admission | 2.73 | 1.252 | 472.6 | — |
| VP9 p0 / no-hardware seam | VideoToolbox hardware | 7.91 | 1.253 | 454.0 | 300 / 0 / 0 |
| VP9 p2 / no-hardware seam | VideoToolbox hardware | 7.67 | 1.276 | 454.6 | 300 / 0 / 0 |

All eleven runs use the same shipped candidate and 14-second quiet launches. Successful video-only playback has clock **1.0000**, 300 drawn, zero late and zero superseded frames. Refusal rows measure startup/error-window cost, not software decoding. The no-hardware seam is consumed by the opt-in plan; in the OFF build it does **not** remove the existing hardware path, so those rows are not software-fallback proofs.

[Normal measurements](measure-shipped.json), [seam measurements](measure-shipped-no-hardware.json). Software hardware-absence qualification remains in the ON-build adapter tests; no new displayed-color evidence is claimed.

The refreshed package has **171 Mach-O files**, a relocatable closure, no eager native FFmpeg load commands and no dependency-audit errors. Native libraries target 13.3; the complete bundle floor is **26.0**. Thus `clean_machine_ready=false`. [Full audit](bundle-final-audit.json), [bundler receipt](bundle-final.txt).
