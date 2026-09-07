# Phase 2b final decision — OFF, not release-ready

`WAM_ENABLE_AVCODEC_STAGE` remains **OFF by default**. The local acceptance
build uses ON. This run advances the opt-in stage but does not finish phase 2b.
The maintainer must not enable release builds from these results.

Measured executable SHA-256:
`693dc1f6dbfd763d0f3b2e80797ec1a5c3ce3bdffbc09870637944c29dbf65c1`.
The final rebuild after the aggregate-initializer correction is byte-identical
to the executable used for playback and the corpus. All changes are unstaged;
no commit, add, stash, reset or checkout was performed. The earlier
[phase-2 checkpoint](../phase2/PHASE2_CHECKPOINT.md) is retained as historical evidence.

## Amendments 19–21

All three proposals are ratified, not awaiting permission. Their complete
ratification text, exact frozen-line before/after diffs and implementation
limits are in the append-only local `SESSION_HANDOFF.md` ledger and the
[retained ledger copy](../phase2b/amendments.md).

- **19:** the isolated backend receives neutral raw extradata and a DecodePlan
  with implementation and representation identity. Raw extradata, Apple magic
  cookies and ESDS are distinct. Existing production audio rows are still
  Apple-routed and retain their tag assertion. No DTS/TrueHD/MLP MediaCodec
  enumerators or production admission were added.
- **20:** `finalInputReleased` now means actual end of borrowing; an owned copy
  satisfies it. Apple proves release at its existing input-proc boundary.
  All frozen converter/session test bytes remain unchanged. The isolated
  decoder keeps manual skip handling and takes actual roles from the first
  decoded frame. Production trim/deficit/tail selection and TrueHD major-sync
  seek/ordinal contracts remain unfinished.
- **21:** packet storage, conversion scratch, picture-area admission and worker
  counts are derived and asserted beside the unchanged 10-surface/384-MiB
  presentation ceilings. Private decoder heap admission is **not** established
  by an area cap or observed heap peak. Instrumented counts below do not
  complete this amendment's resource qualification.

The strict audio-session compilation caught one missing default initializer
on the newly appended raw span. Its explicit `{}` correction is recorded as
an amendment-19 continuation; no Apple implementation or frozen test pin was
changed. [Frozen-file hashes](../phase2b/frozen-surface-hashes.json).

## Family proofs and measured costs

The following are 1280×720, 25-fps, 12-second video-only trials. Each drew
300/300 frames, discarded zero late frames, reported clock rate 1.0000,
exited normally and had no native failure. Process sampling includes startup
and EOS idle time. Energy is process rusage energy, **not whole-system energy**;
these single trials do not prove steady-state or energy parity.

| Specimen | Selected step | CPU (% one core) | Process J | Peak footprint MiB | Hardware comparison |
| --- | --- | ---: | ---: | ---: | --- |
| H.264 8-bit control | VideoToolbox hardware | 6.52 | 1.246 | 442.2 | Hardware baseline |
| MPEG-4 ASP | libavcodec after Apple refusal | 14.50 | 1.557 | 474.7 | H.264 control before/after |
| Hi10P | VideoToolbox hardware | 7.14 | 1.236 | 442.0 | Hardware baseline |
| H.264 4:2:2 10-bit | VideoToolbox hardware | 7.03 | 1.292 | 442.4 | Hardware baseline |
| H.264 8-bit control | VideoToolbox hardware | 6.86 | 1.285 | 441.6 | Hardware baseline |
| Hi10P | libavcodec (capability faked absent) | 21.03 | 2.024 | 494.3 | Matched family hardware row |
| H.264 4:2:2 10-bit | libavcodec (capability faked absent) | 22.34 | 2.395 | 502.8 | Matched family hardware row |
| VP9 profile 0 | libavcodec (capability faked absent) | 17.99 | 1.749 | 477.9 | Matched family hardware row |
| VP9 profile 2 | libavcodec (capability faked absent) | 20.05 | 1.836 | 489.0 | Matched family hardware row |
| VP9 profile 0 | VideoToolbox hardware | 6.59 | 1.327 | 446.8 | Hardware baseline |
| VP9 profile 2 | VideoToolbox hardware | 6.80 | 1.254 | 446.7 | Hardware baseline |

[Identity-bound playback measurements](../phase2b/playback-measurements.json).
Apple hardware stays first in normal operation. Runtime capability queries
report AV1=true and VP9=true after supplemental registration; both VP9
profiles also decode all 300 frames in their actual hardware trials. Software
AV1 remains unavailable: the supplied FFmpeg build has no software AV1
implementation, and no pinned dav1d/libaom source was supplied. The installed
CLI's dav1d decoder is not a source-qualified native dependency.

Software VP9 admission now reaches the Matroska sample builder, native video
consumer and decode lane when hardware capability is absent. Tests fake that
absence deterministically and decode real profile-0/profile-2 packets through
the production lane. Hi10P and 4:2:2 tests also use the production lane with
hardware absent. Each video adapter test compares all decoded pixels to
ffmpeg, exercises backpressure, drain, reset and generation retirement.

Forward/backward/near-EOF software-video seeks complete at requested targets
7, 1 and the existing quantized 11.390625 seconds for Hi10P, 4:2:2 and both VP9
profiles. The displayed frame interval contains the target (for example,
11.36–11.40 at near EOF), rather than relabeling its start as the target.
[Seek events](../phase2b/seek-events.json). These are video-only proofs;
`|V−A|=0` and sample-exact audio seeks are not proven.

| Audio specimen | Isolated backend proof | Production with video |
| --- | --- | --- |
| DTS core stereo, 2 s | 96,256 elementary decoded frames; zero-offset PCM within 2e-6 of ffmpeg, EOS and reset | Refused at Matroska TrackSelection; the 256-frame container tail is not an end-to-end publication proof |
| DTS core 5.1 impulses, 1 s | 48,128 elementary decoded frames; every channel compared, then existing downmix compared to ffmpeg stereo within 2e-6 | Not routed; retained container count of 48,000 is not proven |
| TrueHD stereo, 2 s | 96,000 frames, bit-exact PCM, zero offset, EOS/reset | Refused at Matroska TrackSelection |
| TrueHD 5.1 impulses, 1 s | 48,000 frames, bit-exact native-width PCM; existing downmix within 2e-6 | Not routed; major-sync seek/preroll and ordinal timing unproven |
| MLP stereo, 2 s | 96,000 frames, bit-exact PCM, EOS/reset | Refused at Matroska TrackSelection |
| DTS-HD MA / genuine 7.1 | No valid retained specimen | Not admitted |

The installed `dca` encoder's experimental switch enables DTS core encoding;
it does not implement DTS-HD MA. Its only private option is ADPCM and its
channel layouts stop at 5.1. The available TrueHD encoder also stops at 5.1.
[Encoder/source evidence](../phase2b/dependency-capabilities.json). These limits
cannot be represented as successful HD-MA/7.1 tests. Audio CPU/energy beside
hardware and A/V publication measurements remain absent because production
routing is not implemented; short isolated tests are not substitutes.

## Resource and allocation qualification

One decoder thread per worker, four owned packet slots, 16 workers process-wide.
Actual thread count was 1 before, 17 during and 1 after teardown. Sixteen
workers open; worker seventeen refuses
`AvcodecWorkerBudgetExceeded`; closing the workers restores the initial thread
count and unloads the native closure. This is not a sixteen-window A/V stress
proof. Sixteen windows with two software lanes can exceed that process cap.
[Thread receipt](../phase2b/worker-budget.txt).

Derived packet storage: 16,777,472 bytes per worker including padding,
268,439,552 bytes at sixteen workers. Video-packet plus audio-conversion scratch
is 4,325,376 bytes per session. Presentation ceilings remain 10 surfaces and
384 MiB per session. The software picture cap remains 1920×1080 pixels.

The dyld interposer covers malloc/calloc/realloc/posix_memalign/free, C++ new,
pthread mutex/try-lock/rwlock and os_unfair_lock calls. A fixed 65,536-entry
allocation table per observed worker reports no overflow. An initial inert
interposer was rejected; the retained probe aborts if a decoded run observes
no allocator activity. Counts include worker startup/drain and library calls,
so division by decoded frames is an amortized lifetime count, not a claim of
steady-state count. Worker lock totals include worker-control synchronization;
these measurements do not isolate all WAM owner-loop lock calls.

| 320×180 video / native-rate audio | Frames | Worker alloc/frame | Worker lock/frame | Video/audio handler C++ new | Handler alloc/frame incl. frameworks |
| --- | ---: | ---: | ---: | ---: | ---: |
| asp | 50 | 18.180 | 22.180 | 0 | 3.020 |
| hi10p | 50 | 26.760 | 18.140 | 0 | 3.020 |
| h264422 | 50 | 26.760 | 18.140 | 0 | 3.020 |
| vp9 | 50 | 21.880 | 10.100 | 0 | 3.020 |
| vp9p2 | 50 | 21.880 | 10.100 | 0 | 3.020 |
| dts | 188 | 15.553 | 5.335 | 0 | 0.000 |
| truehd | 2400 | 9.037 | 2.000 | 0 | 0.000 |
| dts51 | 94 | 20.234 | 14.670 | 0 | 0.000 |
| truehd51 | 1200 | 9.069 | 2.001 | 0 | 0.000 |

Video handler framework lock counts are roughly 19–21/frame; audio handler
allocation and lock counts are zero. These include CoreVideo pool/attachment
operations and must not be called zero-allocation/zero-lock call trees merely
because C++ new is zero. Complete WAM adapter-loop attribution remains open.
[Raw counts and tracked heap](../phase2b/allocation-measurements.json).

1080p, ten-frame decoder-only trials measured 13,914,368 bytes peak tracked
heap for ASP and 39,784,272 for Hi10P, with zero tracked heap remaining after
teardown. This excludes the owner-allocated packet slots, stack, mapped code,
VM allocations outside the intercepted APIs, and presentation surfaces.
DTS stereo/5.1 measured 119,824/128,784 bytes; TrueHD stereo/5.1
22,288/23,024 bytes. Audio measurements are resolution-independent isolated
backend results, not 1080p/4K A/V session measurements.

Both 4K decoder probes refuse `AvcodecSoftwareReferenceBudgetExceeded`.
The software video adapter now checks that cap before prewarming presentation
surfaces. No 4K software decode or private-memory bound is claimed.
[Dimension receipts](../phase2b/resource-dimensions.json).

## Lazy loading and closure limits

The app has no FFmpeg load commands or unresolved FFmpeg symbols. Cold native
playback does not resolve the API table. A worker acquires a cold-path runtime
lease that loads bundle-relative libavutil/libavcodec with RTLD_LOCAL and binds
an explicit typed API table. The final worker joins, destroys its AV objects,
and releases its lease before both libraries are unloaded and the table cleared.
No SDK/Homebrew search fallback exists for this native stage.

Missing files refuse `DecoderStageNotBuilt`; corrupt files, ABI/configuration/
license/symbol mismatches and external symlinks refuse `DecoderUnavailable`.
Standalone and bundle-layout relocated loader tests pass, including missing,
corrupt and external-symlink cases. These are loader tests, not relocated full
GUI application acceptance. `--verify-runtime` reports presence, full versions
63.1.101/61.1.101, LGPL configuration, required decoders and hardware hints.
[Runtime tests](../phase2b/runtime-relocation.json).

A real app vmmap at hardware playback shows **zero FFmpeg images**; ASP shows
only the two native Frameworks images. Both playback loaders serialize closure
inspection/loading. Concurrent native/mpv FFmpeg images are refused with
`DecoderUnavailable: PlaybackFfmpegClosureConflict`. This is conservative
exclusion, not a reconciled single ABI/configuration for simultaneous native
and compatibility windows. The cached mpv runtime is process-lifetime.
The local mpv fallback additionally fails to load its missing
`/opt/homebrew/opt/ffmpeg/lib/libavcodec.62.dylib` dependency.
[App observations](../phase2b/runtime-app.json),
[app loads](../phase2b/app-load-commands.txt),
[mpv loads](../phase2b/mpv-load-commands.txt).

## Display-route color and packaging

Actual composited captures were obtained through the in-process `videograb`
seam alongside `grab`; the latter alone captures only the Qt scene on this
route. Pause/position reports bracket each capture. ASP, Hi10P and 4:2:2 SD
bars all select libavcodec under the armed hardware-absence seam.

The SD-lane projection statistic was applied against ffmpeg correct,
wrong-matrix and wrong-range references. It does **not pass** the probe's
stated |projection|≤0.15/RMS≤6 criteria: encoded-image RMS is about 20.5/255,
with projections around 0.62–0.65 and 1.12–1.14. Actual Apple
hardware controls reproduce the same discrepancy in the flat-patch statistics.
The display capture carries the DELL S2725HS ICC profile; conversion to sRGB
alone does not make the reference comparison pass. Thus the reference's full
color-management projection remains unresolved, rather than proving a
software-specific matrix/range defect. Full-range display variants and final
color acceptance are still outstanding. No tolerance was relaxed to pass.
[Software projections](../phase2b/display-projections.json),
[hardware controls](../phase2b/display-hardware-projections.json),
[captures](../phase2b/display/).

CMake automatically copies both native dylibs and the license/configuration/
source-distribution notices into the build bundle. Packaging scripts detect
its stage manifest instead of relying on eager FFmpeg load commands.
Both new native Mach-O libraries have minos 13.3. The whole built app is
**not clean-machine relocatable**: it still loads external Homebrew Qt/libvpx,
and the actual installed libvpx and several Qt components declare minos 26.0.
That floor is real dependency metadata, not an anomaly cured by rewriting
load commands. Rebuilding/replacing those dependencies for 13.3 needs matching
source or qualified binary inputs absent from this run. The automated audit
fails with `NativeBundleNotRelocatable`; no relocated full-app playback or
minimum-OS success is claimed. [Audit](../phase2b/packaging-audit.json).

The exact FFmpeg source archive, SHA-256, offline build/replacement procedure
and remaining distribution requirements are documented in
[SOURCE_DISTRIBUTION](../phase2b/SOURCE_DISTRIBUTION.md), also copied into the
bundle. A release-specific corresponding-source URL, About/licenses UI and
download-page presentation remain unfinished.

## Final validation and deferrals

The required `cmake --build build --parallel` completed successfully. Final
`ctest --output-on-failure` from `build/` passed **99/99**, zero failures, in
119.84 seconds. The earlier strict audio-session compile failure was fixed
with the ledgered default initializer; its isolated retry and the complete
final suite passed. No tests ran concurrently with application linking.
[Build log](../phase2b/build.txt), [final CTest log](../phase2b/ctest-final.txt).

Eighteen behavior reversions/mutations were detected: twelve inherited
codec/pixel/ownership cases, four new lease/worker/representation/layout cases,
and two whole-app VP9 ingress reversions. Each was restored byte-for-byte and
its baseline passed again. The two ingress proofs rebuild the real app and
observe no-hardware playback fail under the old gate, then pass after restore.
[Inherited receipts](../phase2b/inherited-mutation-proofs.json),
[new receipts](../phase2b/new-mutation-proofs.json),
[production ingress receipts](../phase2b/production-ingress-revert-proofs.json).
This is still not a complete full-patch rollback proof for every new behavior;
all runtime replacement, color, resource and packaging branches are not covered.

The final quiet six-second corpus is **78/97 native, zero regressions** versus
the phase-2/phase-0b baseline, on the identical final executable.
[Corpus summary](../phase2b/corpus-summary.json),
[per-file identities/results](../phase2b/corpus-results.json).

Release remains OFF for explicit unmet acceptance: production audio routing
and exact once-only trims; TrueHD ordinal/major-sync seeks and |V−A|=0;
genuine DTS-HD MA/7.1 specimens; pinned software AV1; decoder-private byte
admission and full adapter allocation/lock attribution; sixteen-window A/V
stress; accepted display-color references and full-range variants; reconciled
mpv/native dependency closure; clean-machine full-bundle relocation and 13.3
floor; complete source/license presentation; and complete behavior rollback
coverage. No remaining proposal needs re-ratification.
