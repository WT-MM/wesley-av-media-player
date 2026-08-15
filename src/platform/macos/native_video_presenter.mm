#include "native_video_presenter.hpp"

#include <deque>
#include <mutex>
#include <stdexcept>
#include <utility>

namespace wam::macos {
namespace {

void assignError(std::string *error, std::string message) {
  if (error != nullptr) {
    *error = std::move(message);
  }
}

} // namespace

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

struct BoundedFrameQueue::Impl {
  explicit Impl(std::size_t queueCapacity, std::uint64_t initialGeneration)
      : capacity(queueCapacity), generation(initialGeneration) {}

  const std::size_t capacity;
  std::uint64_t generation;
  bool endOfStream{false};
  mutable std::mutex mutex;
  std::deque<FrameLease> frames;
};

BoundedFrameQueue::BoundedFrameQueue(std::size_t capacity,
                                     std::uint64_t initialGeneration) {
  if (capacity == 0) {
    throw std::invalid_argument(
        "frame queue capacity must be greater than zero");
  }
  impl_ = std::make_unique<Impl>(capacity, initialGeneration);
}

BoundedFrameQueue::~BoundedFrameQueue() = default;

FrameEnqueueResult BoundedFrameQueue::enqueue(FrameLease frame,
                                              std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  if (!frame) {
    assignError(error, "cannot enqueue an empty frame lease");
    return FrameEnqueueResult::Rejected;
  }

  std::lock_guard lock(impl_->mutex);
  if (frame.timing().generation != impl_->generation) {
    assignError(error, "rejecting a stale decoded-frame generation");
    return FrameEnqueueResult::Rejected;
  }
  if (impl_->endOfStream) {
    assignError(error, "cannot enqueue after end of stream");
    return FrameEnqueueResult::Rejected;
  }
  if (impl_->frames.size() >= impl_->capacity) {
    assignError(error, "decoded-frame queue is full");
    return FrameEnqueueResult::Backpressure;
  }
  impl_->frames.push_back(std::move(frame));
  return FrameEnqueueResult::Accepted;
}

void BoundedFrameQueue::endOfStream(std::uint64_t generation) {
  std::lock_guard lock(impl_->mutex);
  if (generation == impl_->generation) {
    impl_->endOfStream = true;
  }
}

void BoundedFrameQueue::flush(std::uint64_t nextGeneration) noexcept {
  std::deque<FrameLease> retired;
  {
    std::lock_guard lock(impl_->mutex);
    retired.swap(impl_->frames);
    impl_->generation = nextGeneration;
    impl_->endOfStream = false;
  }
  // Release potentially expensive decoder surfaces outside the queue lock.
}

std::optional<FrameLease> BoundedFrameQueue::tryTake() {
  std::lock_guard lock(impl_->mutex);
  if (impl_->frames.empty()) {
    return std::nullopt;
  }
  FrameLease frame = std::move(impl_->frames.front());
  impl_->frames.pop_front();
  return frame;
}

std::size_t BoundedFrameQueue::size() const noexcept {
  std::lock_guard lock(impl_->mutex);
  return impl_->frames.size();
}

std::size_t BoundedFrameQueue::capacity() const noexcept {
  return impl_->capacity;
}

std::uint64_t BoundedFrameQueue::generation() const noexcept {
  std::lock_guard lock(impl_->mutex);
  return impl_->generation;
}

bool BoundedFrameQueue::reachedEndOfStream() const noexcept {
  std::lock_guard lock(impl_->mutex);
  return impl_->endOfStream && impl_->frames.empty();
}

} // namespace wam::macos
