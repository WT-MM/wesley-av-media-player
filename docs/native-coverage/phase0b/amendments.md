## 2026-09-06 phase 0b — ratified amendments 15–17

AMENDMENT 15 (RATIFIED): append `ProRes4444` after `AdpcmMs` as a distinct decode-family identity for ProRes 4444 and 4444 XQ. VideoToolbox hardware is required. Presentation is opaque; alpha is ignored, not composited.

AMENDMENT 16 (RATIFIED): admit 8-bit and 10-bit biplanar 4:2:2 decoded surfaces on the display-layer route. SceneGraph422Unsupported refuses the shader route. Ten worst-case surfaces require 401,326,080 bytes; the ceiling is exactly 384 MiB (402,653,184 bytes). The 4:2:0 arithmetic and retention counts remain unchanged.

AMENDMENT 17 (RATIFIED): the existing 12-second preroll constants retain their names and values as fast-seek thresholds. Longer seeks stream through the same bounded retention budgets, report progress, and may be superseded by a newer generation. SparseRandomAccess denotes no usable random-access points.

Exact before/after of touched frozen lines (`-` before, `+` after; unchanged lines omitted):

```diff
--- src/media/native_media_source.hpp BEFORE
+++ src/media/native_media_source.hpp AFTER
@@ -196,0 +197 @@
+  ProRes4444,
@@ -245,0 +247,2 @@
+  Yuv422EightBit,
+  Yuv422TenBit,
@@ -657,0 +661,2 @@
+  // Fast-seek thresholds; longer preroll is streamed with bounded retention
+  // and may be superseded by a newer generation. These are not admission caps.
@@ -691 +696 @@
-  // An integer bound keeps source/dispatcher frame-budget proofs exact.
+  // The integer fast-seek threshold keeps frame-domain comparisons exact.
```

```diff
--- src/platform/macos/native_surface_budget.hpp BEFORE
+++ src/platform/macos/native_surface_budget.hpp AFTER
@@ -29,56 +29,15 @@
-// ---------------------------------------------------------------------------
-// The byte budget IS derived from the coded ceiling, and is re-derived here
-// rather than carried forward, because a surface's size is the ceiling's area
-// times the widest admitted pixel format.
-//
-// 1. Widest admitted decoded surface.
-//    NativeVideoConsumer admits Yuv420EightBit and Yuv420TenBit. Eight-bit
-//    lands as NV12 (1 byte of luma + 0.5 bytes of chroma per pixel = 1.5);
-//    ten-bit lands as P010, which doubles both planes = 3.0. Three bytes per
-//    pixel is therefore the worst case a single admitted surface can cost.
-//
-// 2. IOSurface is charged by IOSurfaceGetAllocSize, not by the naive product.
-//    Each plane's row stride is rounded up (256 B on Apple Silicon) and each
-//    plane is rounded up to a page. The worst case over the whole admitted
-//    envelope is 255 B of stride slack on every luma row and every chroma row
-//    (chroma is half height), plus one 16 KiB page rounding per plane. That
-//    bound depends only on the surface's ROW COUNT, so it is derived from the
-//    tallest surface the envelope admits.
-//
-//    Amendment 8 moved that number. The envelope is orientation-agnostic now,
-//    so the tallest admissible surface is no longer 2320 rows: a portrait
-//    2320x4096 frame is inside the rectangle rule and inside the pixel
-//    budget, and it has 4096 luma rows. The tallest admissible surface is
-//    therefore the LONGEST-axis bound, kHardMaximumCodedWidth. The payload
-//    term does not move -- it is a pure function of the unchanged pixel count
-//    -- so only the slack is re-derived, and it is re-derived here rather
-//    than carried forward.
-//
-// 3. The budget must cover kNativeSurfaceBudgetMaximumSurfaces of those.
-//
-// At the amendment-8 rectangle ceiling (longest axis 4096, shortest 2320,
-// 9,502,720 px), whose worst case for slack is the transposed 2320x4096:
-//    payload   9,502,720 * 3                        =  28,508,160 B
-//    slack     (4096 + 2048) * 255 + 2 * 16,384     =   1,599,488 B
-//    surface                                        =  30,107,648 B
-//    complement 10 * 30,107,648                     = 301,076,480 B
-//    chosen    288 MiB                              = 301,989,888 B
-//
-// 288 MiB still covers the complement, with 913,408 B to spare, and is still
-// within one worst-case surface of it (11 * 30,107,648 = 331,184,128 B), so
-// both bracketing asserts below survive the amendment and the chosen figure
-// did not have to move. For the record, the pre-amendment slack was
-// (2320 + 1160) * 255 + 32,768 = 920,168 B, for a 29,428,328 B surface and a
-// 294,283,280 B complement.
-//
-// The same arithmetic reproduces the previous 64 MiB value at the previous
-// 1920x1080 ceiling -- 10 * (6,220,800 + 445,868) = 66,666,680 B, and 64 MiB
-// is the smallest power-of-two MiB figure that covers it -- which is the proof
-// that this is the original derivation re-evaluated and not a new rule. 288
-// MiB is likewise the smallest 32 MiB step that covers the new figure.
-//
-// This is a CEILING on concurrently charged surfaces, not an allocation and
-// not a steady-state expectation: real playback charges the leases the route
-// actually holds (see native_video_consumer.hpp), which at 8-bit 4K is nine
-// NV12 surfaces of ~13.6 MiB, about 128 MB, and typically fewer.
-// ---------------------------------------------------------------------------
+// Surface payload and alignment bounds at 9,502,720 pixels and 4096 rows:
+// 4:2:0 8-bit:  9,502,720 * 3/2 = 14,254,080 bytes.
+// 4:2:0 10-bit: 9,502,720 * 3   = 28,508,160 bytes.
+// 4:2:0 slack: (4096 + 2048) * 255 + 2 * 16,384 = 1,599,488 bytes.
+// 4:2:0 10-bit surface: 30,107,648 bytes; ten: 301,076,480 bytes.
+// 4:2:2 8-bit:  9,502,720 * 2   = 19,005,440 bytes.
+// 4:2:2 10-bit: 9,502,720 * 4   = 38,010,880 bytes.
+// 4:2:2 slack: (4096 + 4096) * 255 + 2 * 16,384 = 2,121,728 bytes.
+// 4:2:2 10-bit surface: 40,132,608 bytes; ten: 401,326,080 bytes.
+// 384 MiB = 402,653,184 bytes; headroom = 1,327,104 bytes.
+// Opaque ProRes 4444 uses packed RGB10 with two unused bits: 4 bytes/pixel,
+// one plane. Its 38,010,880 + 4096*255 + 16,384 = 39,071,744 bytes
+// fit below the 4:2:2 bound without subsampling or an alpha plane.
+// Packed and lossless-compressed surfaces must fit the padded surface bound;
+// each lease is charged by IOSurfaceGetAllocSize before publication.
@@ -105 +64 @@
-inline constexpr std::uint64_t kNativeSurfaceBudgetWorstCaseSurfaceBytes =
+inline constexpr std::uint64_t kNativeSurfaceBudget420SurfaceBytes =
@@ -108,0 +68,20 @@
+inline constexpr std::uint64_t kNativeSurfaceBudget422PayloadBytes =
+    media::MediaSourceLimits::kHardMaximumCodedPixels * 4ULL;
+inline constexpr std::uint64_t kNativeSurfaceBudget422AlignmentSlackBytes =
+    2ULL * kNativeSurfaceBudgetWorstCaseSurfaceRows * 255ULL +
+    2ULL * 16ULL * 1024ULL;
+inline constexpr std::uint64_t kNativeSurfaceBudgetWorstCaseSurfaceBytes =
+    kNativeSurfaceBudget422PayloadBytes + kNativeSurfaceBudget422AlignmentSlackBytes;
+
+static_assert(kNativeSurfaceBudgetWorstCaseSurfacePayloadBytes == 28'508'160);
+static_assert(kNativeSurfaceBudgetSurfaceAlignmentSlackBytes == 1'599'488);
+static_assert(kNativeSurfaceBudget420SurfaceBytes == 30'107'648);
+static_assert(kNativeSurfaceBudget422PayloadBytes == 38'010'880);
+static_assert(kNativeSurfaceBudget422AlignmentSlackBytes == 2'121'728);
+static_assert(kNativeSurfaceBudgetWorstCaseSurfaceBytes == 40'132'608);
+static_assert(kNativeSurfaceBudget422PayloadBytes +
+                  kNativeSurfaceBudgetWorstCaseSurfaceRows * 255ULL + 16'384ULL == 39'071'744);
+static_assert(39'071'744 <= kNativeSurfaceBudgetWorstCaseSurfaceBytes);
+static_assert(kNativeSurfaceBudgetMaximumSurfaces *
+                  kNativeSurfaceBudgetWorstCaseSurfaceBytes == 401'326'080);
+
@@ -110 +89 @@
-    288ULL * 1024ULL * 1024ULL;
+    384ULL * 1024ULL * 1024ULL;
@@ -143 +122 @@
-// 4.5 GiB if all sixteen are simultaneously holding a full complement of
+// 6 GiB if all sixteen are simultaneously holding a full complement of
```

No changes to native_playback_contract.hpp, tests/native_audio_converter_test.mm, or tests/native_audio_session_test.mm.
