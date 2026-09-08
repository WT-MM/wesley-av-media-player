# Phase 2g retained work log

Initial clone had no build directory. Local offline configuration uses AVFORMAT ON / AVCODEC OFF. Initial sandbox build could not copy WAMKit dependencies; the identical unrestricted build passed. Initial sandbox Apple probes returned -12911; isolated unrestricted probes decoded all three 4:4:4 files in hardware and none in Apple software. These environmental probes are not codec refusals.

Every capture is retained in `/private/tmp/wam-phase2g/captures`. Exploratory candidates bypassed metadata admission only for qualification. That broad bypass is removed in the current working tree; the measured ambient payload is checked exactly, and Dolby Vision remains closed.

Nine hardware additions: six H.264 Hi10P ambient-HLG angel files and three 8-bit H.264 4:4:4 files. Both 4:4:4 hardware-control comparisons pass. The first BT.709 oracle had different decoded samples due to an implicit FFmpeg conversion; its captures are excluded and retained. Corrected controls use setparams before encoding and match source sample values.

Final decisions and acceptance results are in [the phase report](../phase2/REPORT.md). The codec gate stays OFF: the measured full-range failures and software preview capacity failures are retained. Provisional software HDR admission and pixel-normalization experiments were removed. The two anamorphic files remain behind Proposal 27; the PXL edit mapping remains unimplemented. Final corpus verification additionally exposed a global-registry shutdown lifetime defect, fixed with deterministic revert proofs in [SHUTDOWN.md](SHUTDOWN.md).
