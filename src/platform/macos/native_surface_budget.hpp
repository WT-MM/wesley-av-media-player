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

// ---------------------------------------------------------------------------
// The byte budget IS derived from the coded ceiling, and is re-derived here
// rather than carried forward, because a surface's size is the ceiling's area
// times the widest admitted pixel format.
//
// 1. Widest admitted decoded surface.
//    NativeVideoConsumer admits Yuv420EightBit and Yuv420TenBit. Eight-bit
//    lands as NV12 (1 byte of luma + 0.5 bytes of chroma per pixel = 1.5);
//    ten-bit lands as P010, which doubles both planes = 3.0. Three bytes per
//    pixel is therefore the worst case a single admitted surface can cost.
//
// 2. IOSurface is charged by IOSurfaceGetAllocSize, not by the naive product.
//    Each plane's row stride is rounded up (256 B on Apple Silicon) and each
//    plane is rounded up to a page. The worst case over the whole admitted
//    envelope is 255 B of stride slack on every luma row and every chroma row
//    (chroma is half height), plus one 16 KiB page rounding per plane. That
//    bound depends only on the ceiling's HEIGHT, so it is derived from it.
//
// 3. The budget must cover kNativeSurfaceBudgetMaximumSurfaces of those.
//
// At the 4096x2320 / 9,502,720 px ceiling:
//    payload   9,502,720 * 3                        =  28,508,160 B
//    slack     (2320 + 1160) * 255 + 2 * 16,384     =     920,168 B
//    surface                                        =  29,428,328 B
//    budget    10 * 29,428,328                      = 294,283,280 B
//    chosen    288 MiB                              = 301,989,888 B
//
// The same arithmetic reproduces the previous 64 MiB value at the previous
// 1920x1080 ceiling -- 10 * (6,220,800 + 445,868) = 66,666,680 B, and 64 MiB
// is the smallest power-of-two MiB figure that covers it -- which is the proof
// that this is the original derivation re-evaluated and not a new rule. 288
// MiB is likewise the smallest 32 MiB step that covers the new figure.
//
// This is a CEILING on concurrently charged surfaces, not an allocation and
// not a steady-state expectation: real playback charges the leases the route
// actually holds (see native_video_consumer.hpp), which at 8-bit 4K is nine
// NV12 surfaces of ~13.6 MiB, about 128 MB, and typically fewer.
// ---------------------------------------------------------------------------
inline constexpr std::uint64_t kNativeSurfaceBudgetWorstCaseSurfacePayloadBytes =
    media::MediaSourceLimits::kHardMaximumCodedPixels * 3ULL;

inline constexpr std::uint64_t kNativeSurfaceBudgetSurfaceAlignmentSlackBytes =
    (static_cast<std::uint64_t>(
         media::MediaSourceLimits::kHardMaximumCodedHeight) +
     static_cast<std::uint64_t>(
         media::MediaSourceLimits::kHardMaximumCodedHeight) /
         2ULL) *
        255ULL +
    2ULL * 16ULL * 1024ULL;

inline constexpr std::uint64_t kNativeSurfaceBudgetWorstCaseSurfaceBytes =
    kNativeSurfaceBudgetWorstCaseSurfacePayloadBytes +
    kNativeSurfaceBudgetSurfaceAlignmentSlackBytes;

inline constexpr std::uint64_t kNativeSurfaceBudgetMaximumBytes =
    288ULL * 1024ULL * 1024ULL;

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
// 4.5 GiB if all sixteen are simultaneously holding a full complement of
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
