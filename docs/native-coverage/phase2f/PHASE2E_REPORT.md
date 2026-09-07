# Phase 2e — metrics campaign; demux ON, codec OFF

The maintainer's locked-display ruling is applied. No fresh visual capture was attempted or required for these metrics proofs. The native order remains VideoToolbox hardware → VideoToolbox software → AudioToolbox → libvpx → libavcodec last. This is a partial campaign acceptance with explicit remaining gates, not a claim that every requested shape passed.

## Ordered outcomes

| Item | Final implementation and qualification |
| --- | --- |
| 1. Demux ON for proven shapes | macOS default **ON**, independently of codec OFF. Final shipped corpus **84/97**, zero regressions against 78/97. Six RustDesk hardware decodes: **49,832/49,832 exact PTS and durations**, EOS. Full quiet GUI soak: **49,827 drawn + 5 late + 0 superseded**, running clock **1.0000**. Strict all-frames-drawn gate remains short five. Native lazy closure relocates; complete 13.3 bundle gate remains blocked by local Qt/libvpx's 26.0 floor. [Proof](../phase2e/STEP1.md). |
| 2. Sixteen-window software defect | **FIXED.** A contended nonblocking surface-registry insertion was treated as fatal. The worker now retains its output and returns backpressure. Original five drain failures → **zero** in both software reruns; hardware control zero. Seek/close storm: 19 committed/ready/drawn previews; 18 separate preview-budget failures remain disclosed. Windows retire 16 → 16 → 0; native images unload. [Root cause and tests](../phase2e/SOFTWARE_DRAIN.md). |
| 3. Production audio / amendment 24 | **DTS core, TrueHD and MLP PASS for admitted 48 kHz profiles.** Stereo/5.1 × four exact seek windows × three codecs: **24 cases**, each full retained window **96,000 samples**, zero-frame alignment, max PCM error <2e-6, RMS <2e-7, \|V−A\|=0. First-frame channel roles feed the impulse downmix. Three apps: **50 drawn / 96,000 audio**, zero late/superseded and zero clock-advanced underruns. DTS-HD MA remains unqualified/refused. TrueHD/MLP seek preroll is from the original major sync, with O(target) work. [Details](../phase2e/PRODUCTION_AUDIO.md). |
| 4. Decoder-private admission / amendment 25 | **IMPLEMENTED AND ENFORCED.** Codec/reference/bit-depth/chroma/alignment-derived plane capacity, separate packet/extradata/conversion charges, per-worker allocator domain and process reservations. **16 workers admitted; worker 17 refuses; cancellation retires charges to zero.** Combined software A/V reserves two workers, so eight consume all sixteen. 1920×1088 ASP: **32/32 exact frames**, above the removed blanket gate. Presentation remains ten surfaces / 384 MiB. [Derivation and limits](../phase2e/DECODER_RESERVATIONS.md), [larger-frame proof](../phase2e/above-1080-proof.json). |
| 5. Mixed libavformat A/V | **PARTIAL; qualified shapes ON.** Fragmented MP4 and FLV H.264 + zero-origin 48 kHz AAC: **48 exact video frames / 92,160 samples**, equal 48/25 endpoints, exact seek slices and clean EOS; GUI draws every frame. Six RustDesk + CELT Opus: **49,832 exact frames / 95,290,656 samples**, zero alignment, equal endpoints and exact retained seek counts. AVI MP3, positive-origin FLV AAC, ASF WMA, Vorbis, MPEG-PS timing and Opus SILK/hybrid remain named refusals. [Shapes and evidence](../phase2e/MIXED_AV.md). |
| 6. Coexistence | **BOUNDED POLICY VERIFIED.** Existing `PlaybackFfmpegClosureConflict` remains. Native symbol ownership and final unload pass; fallback is refused while two native leases survive. Cached fallback blocks later native FFmpeg until restart. The real build-app second-window refusal leaves its native neighbor playing. Real cached mpv media decoding is not newly qualified; the local seed has missing FFmpeg-62 dependencies. [Exact cost](../phase2e/COEXISTENCE.md). |
| 7. Per-stage decision | **Demux ON / codec OFF.** Qualified demux shapes stay enabled. The codec stage remains opt-in because VP9 p0/p2, full-range and HDR software color coverage is incomplete. Even opt-in production routing now refuses those families as `SoftwareColorUnqualified`; isolated decoder tests remain available. Retained limited-range SDR ASP, Hi10P and 10-bit 4:2:2 captures keep their qualification. |

## Applied amendment ledger

The exact frozen-line patches are appended to local, gitignored `SESSION_HANDOFF.md` and mirrored in [amendment 24](../phase2e/amendment24-applied.md) and [amendment 25](../phase2e/amendment25-applied.md). Authorization and application are separate from the qualification outcomes above.

Amendment 24 enum before/after:

```diff
   ProRes4444,
+  Dts,
+  TrueHd,
+  Mlp,
```

The same ledger records every scoped converter/session line: appended wake configuration, representation-aware raw extradata ingress, real software plan selection, first-frame roles, asynchronous wake/drain, retained-window semantics and cancellation. Existing Apple converter/session test files and the session header are [byte-identical to HEAD](../phase2e/frozen-invariants.json).

Amendment 25 software-only frozen lines:

```diff
-// Software staging is private to a bounded decoder worker, separate from
-// presentation leases. The picture-area admission is not a private-heap proof.
-inline constexpr std::uint64_t kNativeSoftwareMaximumPicturePixels = 1920ULL * 1080ULL;
+// Decoder admission uses softwareDecoderReservation plus an enforced private allocator domain.
+inline constexpr std::uint64_t kNativeSoftwareMaximumPicturePixels = media::MediaSourceLimits::kHardMaximumCodedPixels;
```

```diff
 inline constexpr unsigned kNativeSoftwareProcessWorkers = kMaximumConcurrentPlayerWindows;
+// A combined software audio/video session reserves two workers; eight consume all sixteen.
+inline constexpr unsigned kNativeSoftwareCombinedAudioVideoWorkers = 2;
```

The presentation prefix is byte-identical. The local FFmpeg allocation patch, source archive hash, offline recipe and receipts are retained under `third_party/`, `scripts/` and the [source distribution notice](../phase3/SOURCE_DISTRIBUTION.md). The release-specific corresponding-source URL and About/download presentation remain existing release deferrals.

## Final measurements

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

[Normal measurements](../phase2e/measure-shipped.json), [seam measurements](../phase2e/measure-shipped-no-hardware.json). Software hardware-absence qualification remains in the ON-build adapter tests; no new displayed-color evidence is claimed.

The refreshed package has **171 Mach-O files**, a relocatable closure, no eager native FFmpeg load commands and no dependency-audit errors. Native libraries target 13.3; the complete bundle floor is **26.0**. Thus `clean_machine_ready=false`. [Full audit](../phase2e/bundle-final-audit.json), [bundler receipt](../phase2e/bundle-final.txt).


The prescribed final corpus completed **84/97 native**, with **zero regressions against the original 78/97**, on unchanged candidate `fe0701859a9b9aa5341b97ef496235b108ed5df4cb4ae46709b4539fadd9a11d`. All 97 launches were quiet and six seconds. [Summary](../phase2e/corpus-final-summary.json), [all assets, identities and outcomes](../phase2e/corpus-final-results.json).

## Tests and revert proofs

The complete codec-enabled configuration passes **138/138** in **118.04 s**. [CTest](../phase2e/ctest-on.txt). The final shipped ON/OFF configuration passes **111/111** in **106.97 s**. [Shipped CTest](../phase2e/ctest-shipped.txt), [candidate and cache](../phase2e/final-build.json).

Behavioral failures with temporary production reverts, followed by byte-identical restoration and passing tests:

- [CMake stage defaults](../phase2e/stage-revert-proof.json).
- [Surface contention / cancellation](../phase2e/contention-revert-proof.json).
- [Production audio identities, converter and session](../phase2e/audio-revert-proof.json).
- [Private allocator cap and unload](../phase2e/allocator-revert-proof.json), [area admission and reservation retirement](../phase2e/reservation-revert-proof.json).
- [Mixed source, fragmented routing and Opus mode admission](../phase2e/mixed-revert-proof.json).
- [Software color refusal](../phase2e/color-revert-proof.json).

All builds use `cmake --build build --parallel`, with reconfiguration after CMake edits. CTest never overlaps linking. macOS service tests run outside the filesystem sandbox; initial environmental startup failures are retained separately from regression results. GUI proofs launch only the build app, set all four identities plus quiet/background/muted/geometry seams, use scratch HOME, and control only their child PIDs. No network, visual capture, installed-app launch, staging, commit, stash, reset or checkout was used.
