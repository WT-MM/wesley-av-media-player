# Final shipped measurements

Fourteen-second quiet launches; AVFORMAT ON / AVCODEC OFF. CPU is percentage of one core; process energy is the sampler's process-J reading, not whole-machine energy. Native-refused rows may run the repaired bundled mpv fallback, so their costs must not be attributed to native software decoding. The OFF build does not consume the no-hardware seam.

| Specimen | CPU % | Process J | Peak MiB | Native drawn / late / superseded |
| --- | ---: | ---: | ---: | --- |
| baseline | 5.02 | 1.319 | 446.8 | 300 / 0 / 0 |
| asp | 9.61 | 3.324 | 517.3 | Native refused |
| hi10p | 7.50 | 2.693 | 495.3 | Native refused |
| h264422 | 8.79 | 1.922 | 493.5 | Native refused |
| vp9 | 5.82 | 1.017 | 448.9 | 300 / 0 / 0 |
| vp9p2 | 5.02 | 1.347 | 448.7 | 300 / 0 / 0 |
| baseline / no-HW seam | 4.64 | 1.771 | 449.6 | 300 / 0 / 0 |
| hi10p / no-HW seam | 8.50 | 2.224 | 494.9 | Native refused |
| h264422 / no-HW seam | 7.42 | 2.333 | 496.0 | Native refused |
| vp9 / no-HW seam | 5.10 | 1.151 | 448.9 | 300 / 0 / 0 |
| vp9p2 / no-HW seam | 4.86 | 1.618 | 448.8 | 300 / 0 / 0 |

Candidate `fbe7928d2adfa6f8ac086dabbe4034b09ab00ec61cc11c79fbf07d36990438f4`. Raw identities, logs, usage and streamed metrics are retained under `measurements-final/`. Sampler SHA-256 `8bdfb68e431544f2933f778c73a1f7fbdb3bfff453dc39e960d63efb658c5772`. Earlier `measurements/` files are intermediate pre-deadline/coexistence trials and are superseded by this table. These measurements do not assert an energy improvement over earlier campaigns.
