#include "native_video_presenter.hpp"

#import <Metal/Metal.h>

#include <deque>
#include <mutex>
#include <stdexcept>
#include <utility>
#include <vector>

namespace wam::macos {
namespace {

void assignError(std::string *error, std::string message) {
  if (error != nullptr) {
    *error = std::move(message);
  }
}

struct PlaneImportDescription {
  MTLPixelFormat format{MTLPixelFormatInvalid};
  std::size_t width{0};
  std::size_t height{0};
  std::size_t sourcePlane{0};
};

std::optional<std::vector<PlaneImportDescription>>
describePlanes(CVPixelBufferRef pixelBuffer, std::string *error) {
  const OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
  const bool planar = CVPixelBufferIsPlanar(pixelBuffer);

  switch (pixelFormat) {
  case kCVPixelFormatType_32BGRA:
    return std::vector<PlaneImportDescription>{
        {MTLPixelFormatBGRA8Unorm, CVPixelBufferGetWidth(pixelBuffer),
         CVPixelBufferGetHeight(pixelBuffer), 0}};

  case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
  case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
    if (!planar || CVPixelBufferGetPlaneCount(pixelBuffer) != 2) {
      assignError(error, "NV12 frame does not expose exactly two planes");
      return std::nullopt;
    }
    return std::vector<PlaneImportDescription>{
        {MTLPixelFormatR8Unorm, CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
         CVPixelBufferGetHeightOfPlane(pixelBuffer, 0), 0},
        {MTLPixelFormatRG8Unorm, CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
         CVPixelBufferGetHeightOfPlane(pixelBuffer, 1), 1}};

  case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
  case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
    if (!planar || CVPixelBufferGetPlaneCount(pixelBuffer) != 2) {
      assignError(error, "P010 frame does not expose exactly two planes");
      return std::nullopt;
    }
    return std::vector<PlaneImportDescription>{
        {MTLPixelFormatR16Unorm, CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
         CVPixelBufferGetHeightOfPlane(pixelBuffer, 0), 0},
        {MTLPixelFormatRG16Unorm, CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
         CVPixelBufferGetHeightOfPlane(pixelBuffer, 1), 1}};

  default:
    assignError(error,
                "unsupported CoreVideo pixel format for zero-copy import: " +
                    std::to_string(pixelFormat));
    return std::nullopt;
  }
}

} // namespace

FrameLease::FrameLease(CVPixelBufferRef pixelBuffer,
                       FrameTiming timing) noexcept
    : pixelBuffer_(pixelBuffer), timing_(timing) {
  if (pixelBuffer_ != nullptr) {
    CVPixelBufferRetain(pixelBuffer_);
  }
}

FrameLease::FrameLease(const FrameLease &other) noexcept
    : FrameLease(other.pixelBuffer_, other.timing_) {}

FrameLease &FrameLease::operator=(const FrameLease &other) noexcept {
  if (this == &other) {
    return *this;
  }
  CVPixelBufferRef replacement = other.pixelBuffer_;
  if (replacement != nullptr) {
    CVPixelBufferRetain(replacement);
  }
  reset();
  pixelBuffer_ = replacement;
  timing_ = other.timing_;
  return *this;
}

FrameLease::FrameLease(FrameLease &&other) noexcept
    : pixelBuffer_(std::exchange(other.pixelBuffer_, nullptr)),
      timing_(other.timing_) {}

FrameLease &FrameLease::operator=(FrameLease &&other) noexcept {
  if (this == &other) {
    return *this;
  }
  reset();
  pixelBuffer_ = std::exchange(other.pixelBuffer_, nullptr);
  timing_ = other.timing_;
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
  if (pixelBuffer_ != nullptr) {
    CVPixelBufferRelease(pixelBuffer_);
    pixelBuffer_ = nullptr;
  }
}

struct MetalFrameLease::Storage {
  FrameLease frame;
  std::vector<CVMetalTextureRef> textures;
  std::vector<MetalPlane> planes;

  ~Storage() {
    for (CVMetalTextureRef texture : textures) {
      if (texture != nullptr) {
        CFRelease(texture);
      }
    }
  }
};

MetalFrameLease::MetalFrameLease() noexcept = default;
MetalFrameLease::MetalFrameLease(std::unique_ptr<Storage> storage) noexcept
    : storage_(std::move(storage)) {}
MetalFrameLease::MetalFrameLease(MetalFrameLease &&other) noexcept = default;
MetalFrameLease &
MetalFrameLease::operator=(MetalFrameLease &&other) noexcept = default;
MetalFrameLease::~MetalFrameLease() = default;

MetalFrameLease::operator bool() const noexcept {
  return storage_ != nullptr && !storage_->textures.empty();
}

const FrameLease &MetalFrameLease::frame() const noexcept {
  static const FrameLease empty;
  return storage_ == nullptr ? empty : storage_->frame;
}

std::size_t MetalFrameLease::planeCount() const noexcept {
  return storage_ == nullptr ? 0 : storage_->planes.size();
}

const MetalPlane &MetalFrameLease::plane(std::size_t index) const {
  if (storage_ == nullptr || index >= storage_->planes.size()) {
    throw std::out_of_range("Metal frame plane index out of range");
  }
  return storage_->planes[index];
}

void *MetalFrameLease::nativeTexture(std::size_t index) const noexcept {
  if (storage_ == nullptr || index >= storage_->textures.size()) {
    return nullptr;
  }
  return (__bridge void *)CVMetalTextureGetTexture(storage_->textures[index]);
}

struct MetalTextureCache::Impl {
  __strong id<MTLDevice> device{nil};
  CVMetalTextureCacheRef cache{nullptr};
  // CoreVideo does not promise that cache mutation and flush are safe to race.
  // Keep one lock per cache and hold it across every plane of a frame so a
  // concurrent memory-pressure flush cannot split a multi-plane import.
  std::mutex cacheMutex;

  ~Impl() {
    if (cache != nullptr) {
      CFRelease(cache);
    }
  }
};

MetalTextureCache::MetalTextureCache(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}
MetalTextureCache::~MetalTextureCache() = default;

std::unique_ptr<MetalTextureCache>
MetalTextureCache::create(void *nativeMetalDevice, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  auto impl = std::make_unique<Impl>();
  if (nativeMetalDevice != nullptr) {
    impl->device = (__bridge id<MTLDevice>)nativeMetalDevice;
  } else {
    impl->device = MTLCreateSystemDefaultDevice();
  }
  if (impl->device == nil) {
    assignError(error, "Metal is unavailable on this Mac");
    return nullptr;
  }

  const CVReturn result = CVMetalTextureCacheCreate(
      kCFAllocatorDefault, nullptr, impl->device, nullptr, &impl->cache);
  if (result != kCVReturnSuccess || impl->cache == nullptr) {
    assignError(error,
                "CVMetalTextureCacheCreate failed: " + std::to_string(result));
    return nullptr;
  }
  return std::unique_ptr<MetalTextureCache>(
      new MetalTextureCache(std::move(impl)));
}

void *MetalTextureCache::nativeDevice() const noexcept {
  return impl_ == nullptr ? nullptr : (__bridge void *)impl_->device;
}

std::optional<MetalFrameLease>
MetalTextureCache::importFrame(const FrameLease &frame, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  if (impl_ == nullptr || impl_->cache == nullptr) {
    assignError(error, "Metal texture cache is not initialized");
    return std::nullopt;
  }
  if (!frame) {
    assignError(error, "cannot import an empty frame lease");
    return std::nullopt;
  }
  if (!frame.isIOSurfaceBacked()) {
    assignError(error,
                "frame is not IOSurface-backed; refusing a hidden copy path");
    return std::nullopt;
  }

  auto descriptions = describePlanes(frame.pixelBuffer(), error);
  if (!descriptions) {
    return std::nullopt;
  }

  auto storage = std::make_unique<MetalFrameLease::Storage>();
  storage->frame = frame;
  storage->textures.reserve(descriptions->size());
  storage->planes.reserve(descriptions->size());

  std::lock_guard cacheLock(impl_->cacheMutex);
  for (const PlaneImportDescription &description : *descriptions) {
    CVMetalTextureRef texture = nullptr;
    const CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, impl_->cache, frame.pixelBuffer(), nullptr,
        description.format, description.width, description.height,
        description.sourcePlane, &texture);
    if (result != kCVReturnSuccess || texture == nullptr ||
        CVMetalTextureGetTexture(texture) == nil) {
      if (texture != nullptr) {
        CFRelease(texture);
      }
      assignError(error, "zero-copy Metal plane import failed: " +
                             std::to_string(result));
      return std::nullopt;
    }

    storage->textures.push_back(texture);
    storage->planes.push_back({description.width, description.height,
                               description.sourcePlane,
                               static_cast<std::uint64_t>(description.format)});
  }

  return MetalFrameLease(std::move(storage));
}

void MetalTextureCache::flush() noexcept {
  if (impl_ != nullptr && impl_->cache != nullptr) {
    std::lock_guard cacheLock(impl_->cacheMutex);
    CVMetalTextureCacheFlush(impl_->cache, 0);
  }
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
