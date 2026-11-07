#include "media/native_late_frame_trace.hpp"
#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) && WAM_NATIVE_BENCHMARK_TELEMETRY
#include <mach/mach_time.h>
#endif
#include "native_video_presenter.hpp"

#include <utility>

namespace wam::macos {

FrameLease::FrameLease(CVPixelBufferRef pixelBuffer,
                       FrameTiming timing) noexcept {
  if (pixelBuffer == nullptr) {
    return;
  }

  NativeSurfaceBudgetToken surfaceBudgetToken;
  if (CVPixelBufferGetIOSurface(pixelBuffer) != nullptr) {
    surfaceBudgetToken = NativeSurfaceBudget::tryAcquire(pixelBuffer);
    if (!surfaceBudgetToken) {
      return;
    }
  }

  // The borrowed reference is valid for the duration of construction. Acquire
  // accounting first, then establish the retained frame lifetime that every
  // nonempty token requires.
  CVPixelBufferRetain(pixelBuffer);
  pixelBuffer_ = pixelBuffer;
  timing_ = timing;
#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) && WAM_NATIVE_BENCHMARK_TELEMETRY
  if (media::late_trace::enabled) timing_.surfaceLeaseHostTicks = mach_absolute_time();
#endif
  surface_budget_token_ = std::move(surfaceBudgetToken);
}

FrameLease::FrameLease(const FrameLease &other) noexcept {
  if (!other) {
    return;
  }

  NativeSurfaceBudgetToken surfaceBudgetToken(other.surface_budget_token_);
  if (other.isIOSurfaceBacked() && !surfaceBudgetToken) {
    // Copying may fail closed when the accounting publication is saturated or
    // contended. Never retain a budgeted buffer without its cloned token.
    return;
  }

  CVPixelBufferRetain(other.pixelBuffer_);
  pixelBuffer_ = other.pixelBuffer_;
  timing_ = other.timing_;
  surface_budget_token_ = std::move(surfaceBudgetToken);
}

FrameLease &FrameLease::operator=(const FrameLease &other) noexcept {
  if (this == &other) {
    return *this;
  }

  FrameLease replacement(other);
  if (other && !replacement) {
    // Preserve the destination when an IOSurface token cannot be cloned.
    return *this;
  }
  swap(replacement);
  return *this;
}

FrameLease::FrameLease(FrameLease &&other) noexcept
    : pixelBuffer_(std::exchange(other.pixelBuffer_, nullptr)),
      timing_(std::exchange(other.timing_, FrameTiming{})),
      surface_budget_token_(std::move(other.surface_budget_token_)) {}

FrameLease &FrameLease::operator=(FrameLease &&other) noexcept {
  if (this == &other) {
    return *this;
  }
  reset();
  // Move the token while the source still owns its pixel-buffer lifetime.
  surface_budget_token_ = std::move(other.surface_budget_token_);
  pixelBuffer_ = std::exchange(other.pixelBuffer_, nullptr);
  timing_ = std::exchange(other.timing_, FrameTiming{});
  return *this;
}

FrameLease::~FrameLease() { reset(); }

FrameLease::operator bool() const noexcept { return pixelBuffer_ != nullptr; }

CVPixelBufferRef FrameLease::pixelBuffer() const noexcept {
  return pixelBuffer_;
}

IOSurfaceRef FrameLease::ioSurface() const noexcept {
  return pixelBuffer_ == nullptr ? nullptr
                                 : CVPixelBufferGetIOSurface(pixelBuffer_);
}

bool FrameLease::isIOSurfaceBacked() const noexcept {
  return ioSurface() != nullptr;
}

OSType FrameLease::pixelFormat() const noexcept {
  return pixelBuffer_ == nullptr
             ? 0
             : CVPixelBufferGetPixelFormatType(pixelBuffer_);
}

std::size_t FrameLease::width() const noexcept {
  return pixelBuffer_ == nullptr ? 0 : CVPixelBufferGetWidth(pixelBuffer_);
}

std::size_t FrameLease::height() const noexcept {
  return pixelBuffer_ == nullptr ? 0 : CVPixelBufferGetHeight(pixelBuffer_);
}

const FrameTiming &FrameLease::timing() const noexcept { return timing_; }

void FrameLease::reset() noexcept {
  // NativeSurfaceBudget requires every token to be released while its owning
  // CVPixelBuffer/IOSurface is still alive. Do not reverse these two steps.
  surface_budget_token_.reset();
  if (pixelBuffer_ != nullptr) {
    CVPixelBufferRelease(pixelBuffer_);
    pixelBuffer_ = nullptr;
  }
  timing_ = {};
}

void FrameLease::swap(FrameLease &other) noexcept {
  using std::swap;
  swap(pixelBuffer_, other.pixelBuffer_);
  swap(timing_, other.timing_);
  swap(surface_budget_token_, other.surface_budget_token_);
}

} // namespace wam::macos
