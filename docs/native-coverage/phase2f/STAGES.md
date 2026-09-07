# Stage decision

VideoToolbox hardware → VideoToolbox software → AudioToolbox → libvpx → libavcodec last remains the routing order. Demux defaults ON; codec defaults OFF. The phase-2f SDR color widening affects only the opt-in codec stage.

Codec ON is not authorized by the measured gates:

- Eight-bit full-range ASP fails RMS/range projection, and full-range VP9 p0 exceeds the retained range-projection tolerance (including its hardware control). PQ lacks a validated HDR projection reference; HLG has a large displayed mismatch. Exact per-family values and captures are in [COLOR.md](COLOR.md).
- The sixteen-window software run has zero native session failures but **17 preview failures**, **17 committed/ready/drawn seek chains**, and one preview draw. Its final window report is **16 → 16 → 1**, with native images still present at the 11-second inventory. This does not prove a leak after all leases retire: a window remained alive. It also does not satisfy the required zero-failure cancellation gate. The matching hardware control has zero session/preview failures, 17 committed/ready/drawn seek chains, 16 preview draws and **16 → 16 → 0** windows. No resource cap was increased or failure suppressed.
- The scratch package retains **171 Mach-O files**, zero dependency errors, zero external/unresolved dependencies, no eager native FFmpeg loads, and a relocatable closure. Native FFmpeg libraries retain their 13.3 minimum. The complete package floor is 26.0, so clean-machine 13.3 qualification remains blocked. The development bundle's absolute Homebrew dependencies are separately recorded and are not treated as a packaged artifact.

The allocator/worker tests pass the existing sixteen-worker ceiling, refusal of worker seventeen and cancellation retirement. Those isolated results do not turn the failed GUI preview storm into a zero-failure pass. The final OFF build completes all eleven resource trials and the prescribed corpus at **84/97 native, zero regressions**. All 112 shipped tests pass across the full suite and the unchanged GL-output rerun. See [measurements](MEASUREMENTS.md), [corpus summary](corpus-final-summary.json) and [test receipts](TESTS.md).
