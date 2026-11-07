#pragma once

#include "core_media_time.hpp"
#include "native_surface_budget.hpp"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurfaceRef.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <string>

namespace wam::macos {

#if defined(WAM_NATIVE_TEST_SEAMS)
struct FrameLeaseTestAccess;
#endif

// Whether a decoded frame can be presented at all: exact timing, a positive
// duration, and an END after the movie origin. Where the frame BEGINS is not
// an output's business. An ISO-BMFF head trim (elst media_time > 0) makes the
// reader walk back to a random-access point, so the picture covering movie
// time zero is stated at a negative stamp whenever the trim does not land on a
// frame boundary, and the consumer submits that frame on purpose because it
// retires by the presentation floor rather than by sign. Every tracked output
// asks this one question, so the rule cannot drift between routes.
[[nodiscard]] inline bool frameTimingPresentable(
    const FrameTiming &timing) noexcept {
  if (timing.generation == 0 || !CMTIME_IS_NUMERIC(timing.presentationTime) ||
      !CMTIME_IS_NUMERIC(timing.duration) ||
      CMTimeCompare(timing.duration, kCMTimeZero) <= 0) {
    return false;
  }
  const CMTime frameEnd =
      CMTimeAdd(timing.presentationTime, timing.duration);
  return CMTIME_IS_NUMERIC(frameEnd) &&
         (frameEnd.flags & kCMTimeFlags_HasBeenRounded) == 0 &&
         CMTimeCompare(frameEnd, kCMTimeZero) > 0;
}

// A cheap, reference-counted lease on a VideoToolbox/CoreVideo output frame.
// CPU-backed buffers retain the borrowed CoreVideo reference directly.
// IOSurface-backed buffers are admitted through NativeSurfaceBudget before
// retaining that reference; a failed admission produces a wholly empty lease.
// Copies clone the existing accounting token and never reacquire by identity.
// No pixel bytes are copied.
class FrameLease final {
public:
  FrameLease() noexcept = default;
  explicit FrameLease(CVPixelBufferRef pixelBuffer,
                      FrameTiming timing = {}) noexcept;
  FrameLease(const FrameLease &other) noexcept;
  FrameLease &operator=(const FrameLease &other) noexcept;
  FrameLease(FrameLease &&other) noexcept;
  FrameLease &operator=(FrameLease &&other) noexcept;
  ~FrameLease();

  [[nodiscard]] explicit operator bool() const noexcept;
  [[nodiscard]] CVPixelBufferRef pixelBuffer() const noexcept;
  [[nodiscard]] IOSurfaceRef ioSurface() const noexcept;
  [[nodiscard]] bool isIOSurfaceBacked() const noexcept;
  [[nodiscard]] OSType pixelFormat() const noexcept;
  [[nodiscard]] std::size_t width() const noexcept;
  [[nodiscard]] std::size_t height() const noexcept;
  [[nodiscard]] const FrameTiming &timing() const noexcept;
  void setDuration(CMTime duration) noexcept { timing_.duration = duration; }

  void reset() noexcept;

  // A copy that owns its own accounting token, or empty when the copy could
  // not be admitted (a copy of an admitted lease can still fail its budget
  // token, and then silently comes out empty).
  [[nodiscard]] std::optional<FrameLease> tryClone() const noexcept {
    FrameLease copy(*this);
    if (!copy || copy.pixelBuffer() != pixelBuffer_) {
      return std::nullopt;
    }
    return copy;
  }

private:
#if defined(WAM_NATIVE_TEST_SEAMS)
  friend struct FrameLeaseTestAccess;
#endif
  void swap(FrameLease &other) noexcept;

  CVPixelBufferRef pixelBuffer_{nullptr};
  FrameTiming timing_{};
  NativeSurfaceBudgetToken surface_budget_token_{};
};

#if defined(WAM_NATIVE_TEST_SEAMS)
// Header-only access keeps every test-only symbol out of shipping objects.
// Tests may inspect the exact token clone used by FrameLease without adding a
// second acquisition path to the production API.
struct FrameLeaseTestAccess {
  [[nodiscard]] static NativeSurfaceBudgetToken &
  surfaceBudgetToken(FrameLease &frame) noexcept {
    return frame.surface_budget_token_;
  }
  [[nodiscard]] static const NativeSurfaceBudgetToken &
  surfaceBudgetToken(const FrameLease &frame) noexcept {
    return frame.surface_budget_token_;
  }
};
#endif

} // namespace wam::macos
