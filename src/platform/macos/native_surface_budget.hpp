#pragma once

#include <CoreVideo/CoreVideo.h>

#include <cstddef>
#include <cstdint>

namespace wam::macos {

inline constexpr std::uint64_t kNativeSurfaceBudgetMaximumSurfaces = 10;
inline constexpr std::uint64_t kNativeSurfaceBudgetMaximumBytes =
    64ULL * 1024ULL * 1024ULL;

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
