**Resource nonregression is not established.** These six GUI-quiet diagnostic measurements used the identity-verified phase-2f sampler. Values are historical → measured; CPU is percent of one core, energy is process joules. They precede the final diagnostic snapshot-ordering correction and do not certify final release performance.

| Hardware row | CPU % | Process J | Peak MiB |
| --- | ---: | ---: | ---: |
| baseline | 5.02 → 4.82 | 1.319 → 1.658 | 446.8 → 453.9 |
| vp9 | 5.82 → 4.87 | 1.017 → 1.755 | 448.9 → 453.8 |
| vp9p2 | 5.02 → 4.72 | 1.347 → 1.700 | 448.7 → 453.3 |
| baseline / no-HW seam | 4.64 → 4.71 | 1.771 → 1.674 | 449.6 → 454.1 |
| vp9 / no-HW seam | 5.10 → 4.68 | 1.151 → 1.762 | 448.9 → 454.4 |
| vp9p2 / no-HW seam | 4.86 → 4.70 | 1.618 → 1.770 | 448.8 → 452.3 |

Five rows drew 300/300; the last drew 296 with four late frames. Higher energy or memory observations are retained, not normalized away.

Raw identities, usage, streamed metrics and unsuccessful attempts are retained in [receipts](receipts.tar.gz), with [hashes](receipt-manifest.json).
