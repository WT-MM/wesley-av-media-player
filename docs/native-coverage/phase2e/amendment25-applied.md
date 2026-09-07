
### Amendment 25 — allocator reservation application

Replaced the software-only area gate with coded-envelope geometry plus derived, allocator-enforced private byte admission. The presentation block is byte-identical. Combined software audio/video uses two of sixteen worker slots. Acceptance pending allocator, cancellation and production tests.

```diff
--- a/src/platform/macos/native_surface_budget.hpp
+++ b/src/platform/macos/native_surface_budget.hpp
@@ -150,9 +150,8 @@
               "the process byte pool must stay within one window's headroom "
               "of the complement it exists to bound");
 
-// Software staging is private to a bounded decoder worker, separate from
-// presentation leases. The picture-area admission is not a private-heap proof.
-inline constexpr std::uint64_t kNativeSoftwareMaximumPicturePixels = 1920ULL * 1080ULL;
+// Decoder admission uses softwareDecoderReservation plus an enforced private allocator domain.
+inline constexpr std::uint64_t kNativeSoftwareMaximumPicturePixels = media::MediaSourceLimits::kHardMaximumCodedPixels;
 inline constexpr std::size_t kNativeSoftwarePacketSlots = 4;
 inline constexpr std::size_t kNativeSoftwarePacketBytes = 4U * 1024U * 1024U;
 inline constexpr std::size_t kNativeSoftwarePacketPaddingBytes = 64;
@@ -160,6 +159,8 @@
     kNativeSoftwarePacketSlots * (kNativeSoftwarePacketBytes + kNativeSoftwarePacketPaddingBytes);
 inline constexpr unsigned kNativeSoftwareDecoderThreads = 1;
 inline constexpr unsigned kNativeSoftwareProcessWorkers = kMaximumConcurrentPlayerWindows;
+// A combined software audio/video session reserves two workers; eight consume all sixteen.
+inline constexpr unsigned kNativeSoftwareCombinedAudioVideoWorkers = 2;
 inline constexpr std::size_t kNativeSoftwareAudioConversionScratchBytes = 4096U * 8U * sizeof(float);
 inline constexpr std::size_t kNativeSoftwareSessionConversionScratchBytes =
     kNativeSoftwarePacketBytes + kNativeSoftwareAudioConversionScratchBytes;
```

Application verification: allocator cap, cross-thread/late free, lazy unload, sixteen-worker admission, cancellation retirement, above-1080 geometry and software soak checks pass. Temporary cap/area/retirement/TLS regressions fail their tests; restores are byte-identical. Presentation budget bytes remain unchanged. See DECODER_RESERVATIONS.md and the final phase-2 report.
