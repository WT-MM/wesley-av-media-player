# Phase 2c decision — OFF; acceptance incomplete

`WAM_ENABLE_AVCODEC_STAGE` and `WAM_ENABLE_AVFORMAT_STAGE` remain **OFF by
default**. Both are ON in the local acceptance build. This run does not complete
production libavcodec audio or mixed-stream demux qualification. No production
C++ behavior was changed; the changes improve test generation, instrumentation
and qualification tools. Do not enable the stages from these results.

Measured executable SHA-256:
`f7a30dab7e16b437a990af1118ed9bcf6453045e2a9bf8ab5f31b7c522003b5e`.
The earlier [phase-2b report](../phase2c/PHASE2B_REPORT.md) is retained.

## Required items, in order

| Item | Outcome and proof |
| --- | --- |
| 1. Production DTS / TrueHD / MLP audio | **FAILED.** Fresh H.264 + DTS/TrueHD/MLP Matroska app trials refuse at `TrackSelection`, followed by `LibavformatAudioTimingUnproven: unmapped codec`. The isolated decoder tests pass; production exact retained counts, zero-lag PCM, `V−A=0`, once-only trims, ceil-audio seeks and TrueHD major-sync preroll remain unimplemented. [App receipts](../phase2c/runtime-audio-results.json). |
| 2. Private heap admission | **PARTIAL.** All five video families measured at 1080p and 4K in a separate decoder-only probe, 32 frames each, zero tracked heap after teardown. Production still uses the 1080p area refusal. Reference-picture versus scratch accounting and an enforced derived reservation remain absent. [Measurements](../phase2c/private-heap-measurements.json). |
| 3. Display color | **METHOD FIXED; current acceptance BLOCKED.** Correct source-primary/transfer and device-ICC conversion makes the retained hardware oracle and three retained software families pass the original tolerances. All twelve fresh limited/full-range captures, including hardware controls, are black and now refuse `DisplayCaptureNoSignal`. Fresh VP9/full-range qualification is not claimed. |
| 4. Resource / sixteen windows | **FAILED.** Allocation and lock call sites are now counted and reconciled. The hardware 16-window seek/close control has zero native failures; the software ASP run has five `video decoder presentation drain failed` failures. Both close all windows and release native FFmpeg images. Surface-leak freedom and 16 software A/V sessions remain unproven. |
| 5. Packaging | **AUDIT FIXED; acceptance FAILED.** The audit reads bundled Mach-O files only, including plugins/tools/transitive libraries. Native FFmpeg files report 13.3, but no examined full app satisfies the requested floor. No relocated full-app playback proof was made. See the artifact-specific floors below. |
| 6. Native/mpv coexistence | **Conservative refusal retained**, as permitted by this directive. The precise cost is described below. No reconciled closure or simultaneous native-software/mpv qualification is claimed. |
| 7. Fixture concurrency | **PASSED.** Unique scratch directory, destination-scoped interprocess lock, complete-file atomic replacement, manifest last, bounded encoder threads, and CTest `RUN_SERIAL`/`RESOURCE_LOCK`. Ten consecutive `ctest -j 8` passes: **124/124 each**, no failed fixture or Not Run dependent. [Logs and times](../phase2c/ctest-parallel.json). |
| 8. Libavformat routes | **FAILED / unchanged.** Mixed A/V still refuses before publication; FLV AAC, ASF WMA, Vorbis and MPEG-PS timing is not newly qualified. Fragmented MP4+AAC, AVI+MP3, RustDesk+audio and mounted-local campaigns are unfinished. Already-proven single-stream routes remain opt-in; removing the mixed guard alone would silently discard a lane in this single-track implementation. |
| 9. Default / final acceptance | **OFF.** Corpus is **84/97**, zero regressions against phase 3's 84/97, with identical asset hashes. The measurement table was rerun. Passing unit/corpus checks do not override the failed production/audio, resource, display and packaging acceptance. [Corpus comparison](../phase2c/corpus-latest-summary.json). |

## Rerun hardware/software measurement table

1280x720, 25 fps, 12 seconds, video only. Every row drew **300/300**, discarded
zero late frames, reported clock rate **1.0000**, exited normally and recorded
no native failure. These are single process-rusage trials including startup
and EOS idle, not whole-system energy or a statistical improvement claim.
The fresh black capture controls prevent a current displayed-color claim.
Software hardware-absence seams are explicitly armed; normal routing remains
Apple first. [Identities and metrics](../phase2c/playback-measurements.json).

| Specimen | Selected step | CPU (% one core) | Process J | Peak footprint MiB |
| --- | --- | ---: | ---: | ---: |
| H.264 8-bit control | VideoToolbox hardware | 6.86 | 0.647 | 448.8 |
| MPEG-4 ASP | libavcodec, Apple refusal | 13.73 | 1.615 | 480.7 |
| Hi10P | VideoToolbox hardware | 7.94 | 1.260 | 455.1 |
| H.264 4:2:2 10-bit | VideoToolbox hardware | 7.65 | 1.272 | 449.2 |
| H.264 8-bit control | VideoToolbox hardware | 7.85 | 1.286 | 451.0 |
| Hi10P | libavcodec, forced absence | 21.52 | 2.066 | 503.0 |
| H.264 4:2:2 10-bit | libavcodec, forced absence | 22.83 | 2.363 | 505.0 |
| VP9 profile 0 | libavcodec, forced absence | 18.34 | 1.775 | 480.0 |
| VP9 profile 2 | libavcodec, forced absence | 19.32 | 1.974 | 490.4 |
| VP9 profile 0 | VideoToolbox hardware | 8.01 | 1.339 | 451.0 |
| VP9 profile 2 | VideoToolbox hardware | 7.89 | 1.264 | 448.8 |

## Decoder-private observations and adapter attribution

The standalone `avcodec_private_heap_probe.cpp` deliberately measures beyond
production admission. It uses the same pinned lazy-loaded decoder, one decoder
thread, 32 decoded frames, and records the encoded stream facts and hashes.
H.264 variants request 16 references. These are synthetic stress observations,
not proof that those profiles pass every production admission predicate.
The caller's packet archive, mapped code, stacks, VM allocations outside the
intercepted APIs, and presentation surfaces are excluded. Decoder reference
pictures and scratch are still combined; no admission ceiling is inferred by
rounding the observations.

| Family | 1080p tracked peak bytes | 4K tracked peak bytes | Tracked bytes after teardown |
| --- | ---: | ---: | ---: |
| MPEG-4 ASP | 13,911,104 | 52,366,688 | 0 / 0 |
| Hi10P | 129,776,768 | 511,116,416 | 0 / 0 |
| H.264 4:2:2 10-bit | 165,444,736 | 653,182,080 | 0 / 0 |
| VP9 profile 0 | 14,217,664 | 56,291,776 | 0 / 0 |
| VP9 profile 2 | 26,823,104 | 106,523,072 | 0 / 0 |

Production `AvcodecSoftwareReferenceBudgetExceeded` remains an area-derived
refusal. The H.264 reference stress peaks exceed the old ten-frame observations
substantially; ASP/VP9 4K peaks can be lower than H.264 1080p peaks. This is
evidence against treating picture area alone as private-byte admission.
[Unapplied proposal 25](../phase2c/amendments-proposed.md) states the missing
reference/scratch reservation work without inventing a budget from a peak.

The allocator probe now records immediate calling image/symbol, domain, kind
and count, with a fixed 512-entry call-site table. It aborts on attribution
failure/overflow and reconciles every observed allocation/lock with its domain
total. It is test instrumentation and changes measurement overhead; the GUI
CPU/energy table uses the app without that interposer.

For each 50-frame video pass, adapter allocations remain 151 (3.02/frame).
H.264/ASP have 1,053 first-pass locks (21.06/frame); VP9 has 953 (19.06/frame).
All adapter C++ new counts are zero. The immediate allocation callers are
Apple `_malloc_type_calloc_outlined` (101) and `_malloc_type_malloc_outlined`
(50), rather than direct WAM allocator call sites. Locks identify CoreVideo
IOSurface wiring, backing retain/lock/unlock, attachment mutation and IOSurface
bridged-value cleanup; three first-pass calls are C++ guard/crypto initialization.
Audio handlers again record zero allocations and locks.

WAM's inspected receive/copy/attachment loop has no explicit allocator or
mutex acquisition. The allocator wrappers do not provide a complete initiating
stack, so this report does not upgrade that observation to a complete
transitive ownership audit. Framework calls occur on the bounded decode worker,
not the audio callback or presentation scheduler, under amendment 18. Full
owner-loop attribution remains open. [All call sites](../phase2c/allocation-measurements.json).

The real 16-window test opens every window on the same identity-bound asset,
issues seek/scroll cancellation storms, then closes windows in reverse order.
Hardware has zero failures; ASP has five steady-state decode failures. Both
report window counts 16, 16, 0 and normal process exit. ASP's two native FFmpeg
images are present during playback and absent after close. This proves closure
release for this run, not complete surface accounting or successful software
stress. [Hardware receipt](../phase2c/multiwindow-hardware-result.json),
[software receipt](../phase2c/multiwindow-software-result.json). The lower-level cause of the generic presentation-drain failures is
unresolved; it is not asserted to be the worker cap without evidence.

## Color method and current capture limitation

The old comparison treated FFmpeg `scale` RGB output as display/sRGB RGB.
That output still has the source SMPTE-C primaries and nonlinear BT.709 signal.
Converting only the grab's DELL ICC profile to sRGB leaves the reference in a
different color space. The corrected method inverts the BT.709 transfer,
converts linear SMPTE-C primaries to BT.709/sRGB primaries with D65 white,
then applies the sRGB transfer. Correct and deliberately wrong matrix/range
references go through that same conversion; the grab goes from device ICC to
sRGB. Flat-patch masks exclude chroma boundaries. Neither tolerance moved:
absolute projection <=0.15 and RMS <=6/255.

On the retained hardware H.264 control, corrected RMS is 2.455/255, matrix
projection 0.0022 and range projection -0.0549. The retained software ASP,
Hi10P and 4:2:2 observations have RMS 2.351, 2.489 and 2.500, with both
projections inside the original limits. Reverting the method makes the
hardware-oracle regression test fail; byte-identical restoration passes.
[Hardware](../phase2c/color-hardware-corrected.json),
[software](../phase2c/color-software-corrected.json).

Fresh captures use the current candidate and the required geometry. All are
black, including the known-good hardware control; `saved=1` alone was not
liveness. The measurement now reports `DisplayCaptureNoSignal` before a color
verdict. A request for an onscreen-position exception remains unanswered; the
required geometry was preserved. No software family is declared color-broken
from an invalid hardware control, and no fresh full-range/VP9 pass is claimed.
[Limited-range attempts](../phase2c/display-limited-runs.json),
[full-range attempts](../phase2c/display-full-runs.json).

## Packaging and coexistence

`native_avcodec_packaging_audit.py` inventories every contained Mach-O,
including lazy libraries, Qt plugins and bundled tools. It checks all parsed
macOS deployment versions and never invokes otool on external dependencies or
escaping symlinks. A bundled high-floor plugin, missing native library, missing
notice, eager FFmpeg load and escaping symlink are covered by real compiled
Mach-O tests. External load references are reported as references, not read as
shipped payload. Rpath entries not resolved by the static search remain
unqualified; they are not presented as a runtime-loader failure proof.

- The three native FFmpeg bundle files have minos 13.3.
- The developer build still references external libraries and its six-file
  Mach-O inventory is not a complete relocatable closure.
- The retained phase-3 scratch app has 171 Mach-O files, including Qt files
  with minos 26.0.
- A read-only audit of the current `/Applications/WAM.app` finds 168 Mach-O
  files, Qt libraries/tools with minos 14.0, and no native stage. This is not
  evidence for a 13.3 full app, nor the measured stage-ON candidate.

[Developer bundle](../phase2c/build-closure-audit.json),
[phase-3 scratch bundle](../phase2c/shipped-closure-audit.json),
[current installed copy](../phase2c/installed-closure-audit.json).
No minimum was inferred from a Homebrew input or rewritten to conceal it.
Full-app relocation remains unproven. Item 5's relocated GUI launch would also
need an explicit exception to hard rule 7's build-executable-only restriction;
no scratch or installed app was launched.

The native/mpv exclusion remains `PlaybackFfmpegClosureConflict`. While a
native decoder/demux lease is active, compatibility loading is refused. Once
all native leases close, mpv can load if its own closure is valid. Once the
cached mpv runtime loads, its process-lifetime images prevent subsequent
native libavcodec AND libavformat sessions until app restart. Pure Apple
AVFoundation/Matroska/TS sessions do not need that native FFmpeg lease and are
not excluded by this closure rule. Thus a hardware-decoded RustDesk stream
using libavformat still conflicts, whereas hardware AVFoundation playback
does not. The local fallback seed also retains its pre-existing missing
FFmpeg .62 dependency. Distinct native install names do not by themselves
prove safe symbol/ABI coexistence.

Fresh vmmap controls show zero FFmpeg images for ordinary hardware playback,
and only the two bundle-native images for software ASP. The conservative
refusal is the allowed item-6 decision, rather than an unresolved requirement
to force two incompatible closures into one process.

## Validation, unchanged contracts, and remaining work

Ten consecutive parallel suites passed 124/124, 40.5–47.9 seconds each. The
initial sandbox-only attempt could not access macOS media/window services;
the authorized unsandboxed sequence is fully green. Final delivery verification
after the temporary reversions passed **124/124 in 38.93 seconds**. The required
`cmake --build build --parallel` and post-CMake reconfiguration completed first.
The delivery executable is byte-identical to the corpus/measurement candidate.
[Final CTest](../phase2c/ctest-delivery-final.log),
[final build](../phase2c/build-delivery-final.log).

Six implementation/policy revert proofs cover fixture publication, generated
CTest serialization, packaging audit, hardware color comparison and allocation
attribution, plus the six-family full-range/hardware-oracle launch policy.
Every original was restored byte-identically; the checks fail
with the old behavior and pass after restoration. Measurement-only campaign
harness additions are not claims of production behavior rollback coverage.
[Revert receipts](../phase2c/revert-proofs.json).

All supplied frozen contract/converter/session hashes and SESSION_HANDOFF.md
are unchanged. No amendment was applied. [Hashes](../phase2c/frozen-surface-hashes.json).
[Proposals 24–25](../phase2c/amendments-proposed.md) cover the new production-audio
identity/converter changes and private admission. They are scope proposals,
not completed implementation or ratification. No Git mutation command or
network access was used. The maintainer owns review and commit.
[Reproduction commands](../phase2c/REPRODUCE.md).

Remaining acceptance is substantive: production audio and all its exact A/V,
trim, ordinal and seek proofs; decoder-private reference/scratch bounds tied
to admission; successful software 16-window storms and surface accounting;
valid fresh display captures; a 13.3 full app plus relocation playback; mixed
libavformat audio/video and mounted-local qualification; and default enablement
only after those pass. The earlier unavailable DTS-HD MA/7.1 specimen and
software AV1/source-distribution limitations are not silently claimed solved.
