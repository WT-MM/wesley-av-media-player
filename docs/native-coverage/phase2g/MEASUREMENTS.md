# Final shipped resource measurements

Fourteen-second quiet launches on candidate `a1c2238a282c6206e2a1aacf15741d501dee6968010f0d5e4aafd9780de379f0`; AVFORMAT ON / AVCODEC OFF. CPU is percentage of one core. Energy is the sampler's process-J reading, not whole-machine energy. Peak footprint is divided by 2²⁰. These measurements do not assert an energy improvement. Native-refused ASP runs the bundled fallback and its costs are not native software-decoder costs.

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

The OFF build does not consume the no-hardware seam. Those five rows still exercise the shipped hardware-capable path and must not be presented as software measurements. Hi10P and H.264 422 now reach Apple hardware in the shipped OFF configuration. [Normal raw measurements](measurements-registry-final/normal/results.json), [seam raw measurements](measurements-registry-final/no-hardware-seam/results.json).

Sampler SHA-256 `b5aed62be541d08351e685d393b967e0aff7775442df3a7f52200dff4a781781`. All launch identities, process usage, logs and streamed metrics are retained under `measurements-registry-final/`.
