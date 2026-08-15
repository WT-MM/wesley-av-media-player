#include "native_video_presenter.hpp"

#import <Metal/Metal.h>

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
  if (!storage->frame) {
    assignError(error,
                "could not clone decoded-surface accounting token for Metal "
                "import");
    return std::nullopt;
  }
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

} // namespace wam::macos
