## 2026-09-07 phase 2b — ratified amendments 19–21 (partial implementation; release OFF)

AMENDMENT 19 (PROPOSAL 2 — decode plan and configuration), RATIFIED by the maintainer in the phase-2b directive: neutral extradata ingress without an Apple format tag; decode-implementation identity carried in the DecodePlan; raw extradata vs Apple magic cookie vs ESDS distinguished; the "every audio codec has an AudioToolbox tag" assertion preserved only for Apple-routed rows.

Applied to the isolated backend configuration: DecodePlan carries implementation and representation; raw extradata has its own ingress span and needs no Apple tag. Existing production audio rows are all Apple-routed, so their tag assertion stays byte-identical. No new MediaCodec identity or production audio admission is claimed. Exact frozen lines touched:

```diff
--- src/platform/macos/native_audio_converter.hpp BEFORE
+++ src/platform/macos/native_audio_converter.hpp AFTER
@@ -3,0 +4 @@
+#include "media/native_decode_plan.hpp"
@@ -27,0 +29,4 @@
+  media::DecodePlan decodePlan{.implementation = media::DecodeImplementation::AudioToolbox,
+                              .configurationRepresentation = media::DecodeConfigurationRepresentation::AppleMagicCookie};
+  // Raw decoder bytes are distinct from AudioToolbox cookies and ESDS wrappers.
+  std::span<const std::byte> rawExtradata;
```

AMENDMENT 20 (PROPOSAL 4 — audio backend timing and packet release), RATIFIED by the maintainer in the phase-2b directive: lead-in, deficit, reset and tail semantics selected by decoder implementation and stream configuration (libavcodec uses manual skip handling; every container/codec trim assigned exactly once — never libavcodec auto-trim plus a WAM trim); `finalInputReleased` restated as actual end of borrowing (owned packet copies satisfy it) with all Apple test behaviour preserved byte-for-byte; actual channel layout taken from the first decoded frame before downmix publication; TrueHD's 40-sample units get exact ordinal timing despite coarse Matroska timestamps, with major-sync seek/preroll proof.

Applied packet-release wording below. The isolated backend retains manual-skip decoding and first-decoded-frame layout, now exercised with real 5.1 impulses through the existing downmix. Production trim ownership, TrueHD Matroska ordinal timing and major-sync seeks remain unimplemented/unaccepted. No frozen converter/session test pin changed; all those test bytes are unchanged.

```diff
--- src/platform/macos/native_audio_converter.hpp BEFORE
+++ src/platform/macos/native_audio_converter.hpp AFTER
@@ -44,3 +44,3 @@
-  // True only when the input proc was invoked after the final nonempty packet
-  // handoff. At that documented callback boundary, the wrapper may reuse the
-  // prior byte and packet-description storage.
+  // True only when the backend no longer borrows the final input bytes or
+  // packet descriptions. An owned copy satisfies this; AudioToolbox proves it
+  // at the input-proc invocation after the final nonempty handoff.
```

AMENDMENT 21 (PROPOSAL 6 — resource budgets), RATIFIED by the maintainer in the phase-2b directive: private software-reference-picture, packet, conversion-scratch and decoder-thread budgets stated beside the existing presentation budget in native_surface_budget.hpp's style (derived, asserted); third-party allocation/synchronization on the bounded workers MEASURED (instrumented count per decoded frame, reported) and admission tied to the budget; the presentation pool ceilings (10 surfaces, 384 MiB) unchanged.

Applied derived packet, conversion-scratch, picture-area and thread constants below; production workers consume these constants. Actual heap/lock instrumentation is retained under phase2b. The picture-area cap is NOT a decoder-private byte bound, and heap admission is not yet qualified. Sixteen workers are a process cap, not proof of sixteen simultaneous audio+video software windows. Presentation constants and token behavior are unchanged.

```diff
--- src/platform/macos/native_surface_budget.hpp BEFORE
+++ src/platform/macos/native_surface_budget.hpp AFTER
@@ -152,0 +153,20 @@
+// Software staging is private to a bounded decoder worker, separate from
+// presentation leases. The picture-area admission is not a private-heap proof.
+inline constexpr std::uint64_t kNativeSoftwareMaximumPicturePixels = 1920ULL * 1080ULL;
+inline constexpr std::size_t kNativeSoftwarePacketSlots = 4;
+inline constexpr std::size_t kNativeSoftwarePacketBytes = 4U * 1024U * 1024U;
+inline constexpr std::size_t kNativeSoftwarePacketPaddingBytes = 64;
+inline constexpr std::size_t kNativeSoftwareWorkerPacketStorageBytes =
+    kNativeSoftwarePacketSlots * (kNativeSoftwarePacketBytes + kNativeSoftwarePacketPaddingBytes);
+inline constexpr unsigned kNativeSoftwareDecoderThreads = 1;
+inline constexpr unsigned kNativeSoftwareProcessWorkers = kMaximumConcurrentPlayerWindows;
+inline constexpr std::size_t kNativeSoftwareAudioConversionScratchBytes = 4096U * 8U * sizeof(float);
+inline constexpr std::size_t kNativeSoftwareSessionConversionScratchBytes =
+    kNativeSoftwarePacketBytes + kNativeSoftwareAudioConversionScratchBytes;
+inline constexpr std::size_t kNativeSoftwareProcessPacketStorageBytes =
+    kNativeSoftwareProcessWorkers * kNativeSoftwareWorkerPacketStorageBytes;
+static_assert(kNativeSoftwareWorkerPacketStorageBytes == 16'777'472);
+static_assert(kNativeSoftwareSessionConversionScratchBytes == 4'325'376);
+static_assert(kNativeSoftwareProcessPacketStorageBytes == 268'439'552);
+static_assert(kNativeSoftwareProcessWorkers * kNativeSoftwareDecoderThreads == 16);
+
```

No changes to native_media_source.hpp, native_playback_contract.hpp, tests/native_audio_converter_test.mm or tests/native_audio_session_test*. All changes remain unstaged; the maintainer owns the commit. Phase 2b does not authorize release enablement while its acceptance failures remain.

### Amendment 19 continuation — strict aggregate initialization

The strict `macos_native_audio_session` test compilation found a missing-field-initializer warning in unchanged Apple configuration code. Give the newly appended raw ingress an explicit empty default; existing aggregates keep their original behavior. No frozen test or Apple converter implementation line changes.

```diff
--- src/platform/macos/native_audio_converter.hpp BEFORE
+++ src/platform/macos/native_audio_converter.hpp AFTER
-  std::span<const std::byte> rawExtradata;
+  std::span<const std::byte> rawExtradata{};
```
