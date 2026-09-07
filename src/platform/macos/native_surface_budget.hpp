#pragma once

#include "media/native_media_source.hpp"
#include "native_concurrency_limits.hpp"

#include <CoreVideo/CoreVideo.h>

#include <cstddef>
#include <cstdint>

namespace wam::macos {

// A COUNT, not a size: how many distinct decoded IOSurfaces ONE native
// playback session may hold at one instant. Nothing about it moves with the
// coded ceiling -- the lease ledgers in native_video_consumer.hpp are the same
// ledgers at any resolution -- so this value is unchanged by the 4K-class
// revision.
//
// This was the whole process's allowance until WAM became a multi-window
// player. It could not stay that: a second window's session legitimately wants
// its own complement, and sharing one ten-surface pool between two sessions
// starved the second one -- measured, a second 1080p window drew 4.6 fps
// against the first window's 30 while both reported healthy clocks, because
// the pool ran out and the route simply could not lease a surface to decode
// into. The per-session complement is unchanged; what changed is that the
// PROCESS pool is now N of them. See the process constants below.
inline constexpr std::uint64_t kNativeSurfaceBudgetMaximumSurfaces = 10;

// Surface payload and alignment bounds at 9,502,720 pixels and 4096 rows:
// 4:2:0 8-bit:  9,502,720 * 3/2 = 14,254,080 bytes.
// 4:2:0 10-bit: 9,502,720 * 3   = 28,508,160 bytes.
// 4:2:0 slack: (4096 + 2048) * 255 + 2 * 16,384 = 1,599,488 bytes.
// 4:2:0 10-bit surface: 30,107,648 bytes; ten: 301,076,480 bytes.
// 4:2:2 8-bit:  9,502,720 * 2   = 19,005,440 bytes.
// 4:2:2 10-bit: 9,502,720 * 4   = 38,010,880 bytes.
// 4:2:2 slack: (4096 + 4096) * 255 + 2 * 16,384 = 2,121,728 bytes.
// 4:2:2 10-bit surface: 40,132,608 bytes; ten: 401,326,080 bytes.
// 384 MiB = 402,653,184 bytes; headroom = 1,327,104 bytes.
// Opaque ProRes 4444 uses packed RGB10 with two unused bits: 4 bytes/pixel,
// one plane. Its 38,010,880 + 4096*255 + 16,384 = 39,071,744 bytes
// fit below the 4:2:2 bound without subsampling or an alpha plane.
// Packed and lossless-compressed surfaces must fit the padded surface bound;
// each lease is charged by IOSurfaceGetAllocSize before publication.
inline constexpr std::uint64_t kNativeSurfaceBudgetWorstCaseSurfacePayloadBytes =
    media::MediaSourceLimits::kHardMaximumCodedPixels * 3ULL;

// The tallest surface the envelope admits. Under the amendment-8 rectangle
// rule either dimension may carry the longest axis, so this is the
// LONGEST-axis bound and not the field named "Height" -- a transposed
// 2320x4096 frame is admissible and has 4096 luma rows. Deriving this from
// kHardMaximumCodedHeight (as it did when only landscape shapes existed)
// would now under-derive the slack by 679,320 B per surface and quietly make
// the byte budget too small for the very shapes the amendment admits.
inline constexpr std::uint64_t kNativeSurfaceBudgetWorstCaseSurfaceRows =
    static_cast<std::uint64_t>(
        media::MediaSourceLimits::kHardMaximumCodedWidth);

inline constexpr std::uint64_t kNativeSurfaceBudgetSurfaceAlignmentSlackBytes =
    (kNativeSurfaceBudgetWorstCaseSurfaceRows +
     kNativeSurfaceBudgetWorstCaseSurfaceRows / 2ULL) *
        255ULL +
    2ULL * 16ULL * 1024ULL;

inline constexpr std::uint64_t kNativeSurfaceBudget420SurfaceBytes =
    kNativeSurfaceBudgetWorstCaseSurfacePayloadBytes +
    kNativeSurfaceBudgetSurfaceAlignmentSlackBytes;

inline constexpr std::uint64_t kNativeSurfaceBudget422PayloadBytes =
    media::MediaSourceLimits::kHardMaximumCodedPixels * 4ULL;
inline constexpr std::uint64_t kNativeSurfaceBudget422AlignmentSlackBytes =
    2ULL * kNativeSurfaceBudgetWorstCaseSurfaceRows * 255ULL +
    2ULL * 16ULL * 1024ULL;
inline constexpr std::uint64_t kNativeSurfaceBudgetWorstCaseSurfaceBytes =
    kNativeSurfaceBudget422PayloadBytes + kNativeSurfaceBudget422AlignmentSlackBytes;

static_assert(kNativeSurfaceBudgetWorstCaseSurfacePayloadBytes == 28'508'160);
static_assert(kNativeSurfaceBudgetSurfaceAlignmentSlackBytes == 1'599'488);
static_assert(kNativeSurfaceBudget420SurfaceBytes == 30'107'648);
static_assert(kNativeSurfaceBudget422PayloadBytes == 38'010'880);
static_assert(kNativeSurfaceBudget422AlignmentSlackBytes == 2'121'728);
static_assert(kNativeSurfaceBudgetWorstCaseSurfaceBytes == 40'132'608);
static_assert(kNativeSurfaceBudget422PayloadBytes +
                  kNativeSurfaceBudgetWorstCaseSurfaceRows * 255ULL + 16'384ULL == 39'071'744);
static_assert(39'071'744 <= kNativeSurfaceBudgetWorstCaseSurfaceBytes);
static_assert(kNativeSurfaceBudgetMaximumSurfaces *
                  kNativeSurfaceBudgetWorstCaseSurfaceBytes == 401'326'080);

inline constexpr std::uint64_t kNativeSurfaceBudgetMaximumBytes =
    384ULL * 1024ULL * 1024ULL;

// The per-session budget must be able to hold a full complement of worst-case
// surfaces. Without this the surface COUNT stays the binding constraint on
// paper while bytes silently become the binding constraint in fact, and the
// route starts refusing surfaces mid-playback instead of at admission.
static_assert(kNativeSurfaceBudgetMaximumBytes >=
                  kNativeSurfaceBudgetMaximumSurfaces *
                      kNativeSurfaceBudgetWorstCaseSurfaceBytes,
              "the per-session byte budget must cover a full complement of "
              "surfaces at the v1 coded ceiling, or the surface count stops "
              "being the binding constraint");
// Not grossly oversized either: a ceiling nobody can reach stops being a
// budget. One extra worst-case surface of headroom is the whole allowance.
static_assert(kNativeSurfaceBudgetMaximumBytes <
                  (kNativeSurfaceBudgetMaximumSurfaces + 1ULL) *
                      kNativeSurfaceBudgetWorstCaseSurfaceBytes,
              "the per-session byte budget must stay within one worst-case "
              "surface of the complement it exists to bound");

// ---------------------------------------------------------------------------
// The PROCESS pool: N windows cost N budgets, and that is stated rather than
// discovered.
//
// The ledger in native_surface_budget.mm is one shared, lock-free account for
// the whole process, and it stays that way -- it is the thing that makes the
// total honest. What multiplies is its size, DERIVED from the per-session
// complement and the window cap, never bumped independently. Each session's
// own lease ledgers (native_video_consumer.hpp) still bound it to the
// per-session complement above, so the shared pool cannot be monopolised by
// one window; the pool exists to bound the sum.
//
// The byte figure is a CEILING, not an allocation: 16 windows only reach
// 6 GiB if all sixteen are simultaneously holding a full complement of
// 4K ten-bit surfaces. Real playback charges the leases the route actually
// holds -- about 128 MB per 4K session, far less at 1080p -- so the honest
// statement of the cost is "each open video costs its own budget", which is
// exactly what a user opening sixteen videos is asking for.
// ---------------------------------------------------------------------------
inline constexpr std::uint64_t kNativeSurfaceBudgetProcessMaximumSurfaces =
    kNativeSurfaceBudgetMaximumSurfaces *
    static_cast<std::uint64_t>(kMaximumConcurrentPlayerWindows);

inline constexpr std::uint64_t kNativeSurfaceBudgetProcessMaximumBytes =
    kNativeSurfaceBudgetMaximumBytes *
    static_cast<std::uint64_t>(kMaximumConcurrentPlayerWindows);

static_assert(kNativeSurfaceBudgetProcessMaximumSurfaces ==
                  kNativeSurfaceBudgetMaximumSurfaces * 16ULL,
              "the process surface pool must be exactly the window cap's "
              "worth of per-session complements");
static_assert(kNativeSurfaceBudgetProcessMaximumBytes >=
                  kNativeSurfaceBudgetProcessMaximumSurfaces *
                      kNativeSurfaceBudgetWorstCaseSurfaceBytes,
              "the process byte pool must cover every window's full "
              "complement at the v1 coded ceiling");
static_assert(kNativeSurfaceBudgetProcessMaximumBytes <
                  (kNativeSurfaceBudgetProcessMaximumSurfaces +
                   static_cast<std::uint64_t>(
                       kMaximumConcurrentPlayerWindows)) *
                      kNativeSurfaceBudgetWorstCaseSurfaceBytes,
              "the process byte pool must stay within one window's headroom "
              "of the complement it exists to bound");

// Decoder admission uses softwareDecoderReservation plus an enforced private allocator domain.
inline constexpr std::uint64_t kNativeSoftwareMaximumPicturePixels = media::MediaSourceLimits::kHardMaximumCodedPixels;
inline constexpr std::size_t kNativeSoftwarePacketSlots = 4;
inline constexpr std::size_t kNativeSoftwarePacketBytes = 4U * 1024U * 1024U;
inline constexpr std::size_t kNativeSoftwarePacketPaddingBytes = 64;
inline constexpr std::size_t kNativeSoftwareWorkerPacketStorageBytes =
    kNativeSoftwarePacketSlots * (kNativeSoftwarePacketBytes + kNativeSoftwarePacketPaddingBytes);
inline constexpr unsigned kNativeSoftwareDecoderThreads = 1;
inline constexpr unsigned kNativeSoftwareProcessWorkers = kMaximumConcurrentPlayerWindows;
// A combined software audio/video session reserves two workers; eight consume all sixteen.
inline constexpr unsigned kNativeSoftwareCombinedAudioVideoWorkers = 2;
inline constexpr std::size_t kNativeSoftwareAudioConversionScratchBytes = 4096U * 8U * sizeof(float);
inline constexpr std::size_t kNativeSoftwareSessionConversionScratchBytes =
    kNativeSoftwarePacketBytes + kNativeSoftwareAudioConversionScratchBytes;
inline constexpr std::size_t kNativeSoftwareProcessPacketStorageBytes =
    kNativeSoftwareProcessWorkers * kNativeSoftwareWorkerPacketStorageBytes;
static_assert(kNativeSoftwareWorkerPacketStorageBytes == 16'777'472);
static_assert(kNativeSoftwareSessionConversionScratchBytes == 4'325'376);
static_assert(kNativeSoftwareProcessPacketStorageBytes == 268'439'552);
static_assert(kNativeSoftwareProcessWorkers * kNativeSoftwareDecoderThreads == 16);

struct NativeSurfaceBudgetStats {
  std::uint64_t currentSurfaces{0};
  std::uint64_t peakSurfaces{0};
  std::uint64_t currentBytes{0};
  std::uint64_t peakBytes{0};
  std::uint64_t rejections{0};
};

class NativeSurfaceBudget;

#if defined(WAM_NATIVE_SURFACE_BUDGET_TESTING)
struct NativeSurfaceBudgetTestAccess;

enum class NativeSurfaceBudgetTestInterleavePoint : std::uint8_t {
  BeforeRetainCompareExchange,
  BeforeMismatchedRetainRelease,
};

using NativeSurfaceBudgetTestInterleaveHook = void (*)(
    NativeSurfaceBudgetTestInterleavePoint point, void *context) noexcept;
#endif

// A process-wide accounting claim on one decoded IOSurface. Tokens are cheap
// value types: aliases of the same IOSurface share one unique-surface/byte
// charge, while every token owns one reference on that immutable publication.
// This is an accounting token, not an IOSurface retain; the owning decoded
// frame must keep its CVPixelBuffer/IOSurface alive for at least as long as all
// corresponding budget tokens.
//
// Copying is lock-free and noexcept. In the practically unreachable case
// that a record's reference count is saturated, or under sustained hostile
// atomic contention, the copy fails closed and produces an empty token.
class NativeSurfaceBudgetToken final {
public:
  NativeSurfaceBudgetToken() noexcept = default;
  ~NativeSurfaceBudgetToken() noexcept;

  NativeSurfaceBudgetToken(const NativeSurfaceBudgetToken &other) noexcept;
  NativeSurfaceBudgetToken &
  operator=(const NativeSurfaceBudgetToken &other) noexcept;
  NativeSurfaceBudgetToken(NativeSurfaceBudgetToken &&other) noexcept;
  NativeSurfaceBudgetToken &
  operator=(NativeSurfaceBudgetToken &&other) noexcept;

  [[nodiscard]] explicit operator bool() const noexcept {
    return record_ != nullptr;
  }
  [[nodiscard]] std::uint32_t surfaceID() const noexcept {
    return surface_id_;
  }
  [[nodiscard]] std::uint64_t bytes() const noexcept { return bytes_; }

  void reset() noexcept;

private:
  friend class NativeSurfaceBudget;
#if defined(WAM_NATIVE_SURFACE_BUDGET_TESTING)
  friend struct NativeSurfaceBudgetTestAccess;
#endif

  NativeSurfaceBudgetToken(void *record, std::uint64_t publication,
                           std::uint32_t surfaceID,
                           std::uint64_t bytes) noexcept;
  void retain(const NativeSurfaceBudgetToken &source) noexcept;

  void *record_{nullptr};
  std::uint64_t publication_{0};
  std::uint32_t surface_id_{0};
  std::uint64_t bytes_{0};
};

class NativeSurfaceBudget final {
public:
  // Returns an empty token when the pixel buffer is not IOSurface-backed, its
  // identity/size is invalid, either hard budget would be exceeded, or a
  // bounded nonblocking accounting operation cannot complete safely.
  [[nodiscard]] static NativeSurfaceBudgetToken
  tryAcquire(CVPixelBufferRef pixelBuffer) noexcept;

  // Atomically sampled counters. Concurrent callers can observe values from
  // slightly different instants, but every individual field is bounded and
  // never wraps.
  [[nodiscard]] static NativeSurfaceBudgetStats stats() noexcept;

private:
#if defined(WAM_NATIVE_SURFACE_BUDGET_TESTING)
  friend struct NativeSurfaceBudgetTestAccess;
#endif
  [[nodiscard]] static NativeSurfaceBudgetToken
  tryAcquireIdentity(std::uint32_t surfaceID, std::uint64_t bytes) noexcept;
};

#if defined(WAM_NATIVE_SURFACE_BUDGET_TESTING)
// Deterministic accounting-only seams. reset(), forceNextPublication(), and
// forceReferenceCount() require process quiescence: tests must not call them
// while any unrelated token or accounting operation is live.
struct NativeSurfaceBudgetTestAccess {
  [[nodiscard]] static NativeSurfaceBudgetToken
  tryAcquire(std::uint32_t surfaceID, std::uint64_t bytes) noexcept;
  [[nodiscard]] static bool reset() noexcept;
  [[nodiscard]] static bool holdInsertionReservation() noexcept;
  static void releaseInsertionReservation() noexcept;
  [[nodiscard]] static bool
  forceReferenceCount(NativeSurfaceBudgetToken &token,
                      std::uint32_t referenceCount) noexcept;
  [[nodiscard]] static bool
  forceNextPublication(std::uint64_t publication) noexcept;
  static void setInterleaveHook(
      NativeSurfaceBudgetTestInterleaveHook hook,
      void *context) noexcept;
};
#endif

} // namespace wam::macos
