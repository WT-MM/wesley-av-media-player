#include "platform/macos/native_video_presenter.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>

#import <Metal/Metal.h>

#include <atomic>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

void check(bool condition, const char *expression, int line) {
  if (!condition) {
    std::cerr << "CHECK failed at line " << line << ": " << expression << '\n';
    std::exit(EXIT_FAILURE);
  }
}

#define WAM_CHECK(expression)                                                  \
  check(static_cast<bool>(expression), #expression, __LINE__)

struct PixelBufferCreation {
  CVPixelBufferRef buffer{nullptr};
  CVReturn status{kCVReturnError};
};

PixelBufferCreation tryCreateIOSurfacePixelBuffer(OSType format,
                                                  std::size_t width,
                                                  std::size_t height) {
  CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 2, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFDictionaryRef empty = CFDictionaryCreate(
      kCFAllocatorDefault, nullptr, nullptr, 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(attributes, kCVPixelBufferIOSurfacePropertiesKey, empty);
  CFDictionarySetValue(attributes, kCVPixelBufferMetalCompatibilityKey,
                       kCFBooleanTrue);

  PixelBufferCreation creation;
  creation.status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                        format, attributes, &creation.buffer);
  CFRelease(empty);
  CFRelease(attributes);
  return creation;
}

CVPixelBufferRef createRequiredIOSurfacePixelBuffer(OSType format,
                                                    std::size_t width,
                                                    std::size_t height) {
  PixelBufferCreation creation =
      tryCreateIOSurfacePixelBuffer(format, width, height);
  WAM_CHECK(creation.status == kCVReturnSuccess);
  WAM_CHECK(creation.buffer != nullptr);
  return creation.buffer;
}

} // namespace

int main() {
  std::string error;

  // Run the platform-independent ownership and queue coverage first. A machine
  // without an exposed Metal device should skip only the texture-import half.
  constexpr std::size_t cpuWidth = 32;
  constexpr std::size_t cpuHeight = 16;
  constexpr std::size_t cpuBytesPerRow = cpuWidth * 4;
  std::vector<std::byte> cpuPixelStorage(cpuBytesPerRow * cpuHeight);
  CVPixelBufferRef pixelBuffer = nullptr;
  const CVReturn cpuBufferResult = CVPixelBufferCreateWithBytes(
      kCFAllocatorDefault, cpuWidth, cpuHeight, kCVPixelFormatType_32BGRA,
      cpuPixelStorage.data(), cpuBytesPerRow, nullptr, nullptr, nullptr,
      &pixelBuffer);
  WAM_CHECK(cpuBufferResult == kCVReturnSuccess);
  WAM_CHECK(pixelBuffer != nullptr);
  wam::macos::FrameTiming timing{CMTimeMake(1001, 24000),
                                 CMTimeMake(1001, 24000), 4, true};
  wam::macos::FrameLease frame(pixelBuffer, timing);
  CVPixelBufferRelease(pixelBuffer);

  WAM_CHECK(frame);
  WAM_CHECK(!frame.isIOSurfaceBacked());
  WAM_CHECK(frame.ioSurface() == nullptr);
  WAM_CHECK(frame.width() == cpuWidth);
  WAM_CHECK(frame.height() == cpuHeight);
  WAM_CHECK(frame.pixelFormat() == kCVPixelFormatType_32BGRA);
  WAM_CHECK(frame.timing().generation == 4);

  // Copies retain only the CoreVideo object; pixel memory is not duplicated.
  wam::macos::FrameLease copied = frame;
  frame.reset();
  WAM_CHECK(copied);
  WAM_CHECK(copied.width() == cpuWidth);

  // The decode-to-display handoff has a hard frame bound and rejects stale
  // generations, so seeks and a slow display cannot grow memory indefinitely.
  wam::macos::BoundedFrameQueue queue(2, 4);
  WAM_CHECK(queue.capacity() == 2);
  WAM_CHECK(queue.enqueue(copied, &error) ==
            wam::macos::FrameEnqueueResult::Accepted);
  WAM_CHECK(queue.enqueue(copied, &error) ==
            wam::macos::FrameEnqueueResult::Accepted);
  WAM_CHECK(queue.size() == 2);
  WAM_CHECK(queue.enqueue(copied, &error) ==
            wam::macos::FrameEnqueueResult::Backpressure);
  WAM_CHECK(error == "decoded-frame queue is full");
  auto dequeued = queue.tryTake();
  WAM_CHECK(dequeued.has_value());
  WAM_CHECK(queue.size() == 1);
  queue.endOfStream(4);
  WAM_CHECK(queue.enqueue(copied, &error) ==
            wam::macos::FrameEnqueueResult::Rejected);
  WAM_CHECK(error == "cannot enqueue after end of stream");
  WAM_CHECK(!queue.reachedEndOfStream());
  WAM_CHECK(queue.tryTake().has_value());
  WAM_CHECK(queue.reachedEndOfStream());
  queue.flush(5);
  WAM_CHECK(queue.generation() == 5);
  WAM_CHECK(!queue.reachedEndOfStream());
  WAM_CHECK(queue.enqueue(copied, &error) ==
            wam::macos::FrameEnqueueResult::Rejected);
  WAM_CHECK(error == "rejecting a stale decoded-frame generation");

  // Independently establish genuine device absence. Once a device exists,
  // MetalTextureCache::create() returning null is an implementation failure,
  // not a reason to skip the test.
  id<MTLDevice> systemDevice = MTLCreateSystemDefaultDevice();
  if (systemDevice == nil) {
    std::cerr << "SKIP: Metal is unavailable on this Mac; "
                 "frame and bounded-queue coverage passed\n";
    return 77;
  }

  auto cache = wam::macos::MetalTextureCache::create(nullptr, &error);
  WAM_CHECK(cache != nullptr);
  WAM_CHECK(error.empty());
  WAM_CHECK(cache->nativeDevice() != nullptr);

  auto hiddenCopy = cache->importFrame(copied, &error);
  WAM_CHECK(!hiddenCopy.has_value());
  WAM_CHECK(error ==
            "frame is not IOSurface-backed; refusing a hidden copy path");

  CVPixelBufferRef nv12Buffer = createRequiredIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 128, 64);
  wam::macos::FrameLease nv12Frame(nv12Buffer, timing);
  CVPixelBufferRelease(nv12Buffer);
  WAM_CHECK(nv12Frame.isIOSurfaceBacked());

  auto imported = cache->importFrame(nv12Frame, &error);
  WAM_CHECK(imported.has_value());
  WAM_CHECK(error.empty());
  WAM_CHECK(imported->planeCount() == 2);
  WAM_CHECK(imported->plane(0).width == 128);
  WAM_CHECK(imported->plane(0).height == 64);
  WAM_CHECK(imported->plane(0).metalPixelFormat ==
            static_cast<std::uint64_t>(MTLPixelFormatR8Unorm));
  WAM_CHECK(imported->plane(1).width == 64);
  WAM_CHECK(imported->plane(1).height == 32);
  WAM_CHECK(imported->plane(1).metalPixelFormat ==
            static_cast<std::uint64_t>(MTLPixelFormatRG8Unorm));
  WAM_CHECK(imported->nativeTexture(0) != nullptr);
  WAM_CHECK(imported->nativeTexture(1) != nullptr);

  CVPixelBufferRef bgraBuffer =
      createRequiredIOSurfacePixelBuffer(kCVPixelFormatType_32BGRA, 96, 48);
  wam::macos::FrameLease bgraFrame(bgraBuffer);
  CVPixelBufferRelease(bgraBuffer);
  auto bgraImport = cache->importFrame(bgraFrame, &error);
  WAM_CHECK(bgraImport.has_value());
  WAM_CHECK(error.empty());
  WAM_CHECK(bgraImport->planeCount() == 1);
  WAM_CHECK(bgraImport->plane(0).width == 96);
  WAM_CHECK(bgraImport->plane(0).height == 48);
  WAM_CHECK(bgraImport->plane(0).metalPixelFormat ==
            static_cast<std::uint64_t>(MTLPixelFormatBGRA8Unorm));
  WAM_CHECK(bgraImport->nativeTexture(0) != nullptr);

  // P010 allocation is not exposed on every supported Mac/virtual runner. If
  // CoreVideo creates it, both 10-bit Metal plane imports are mandatory.
  PixelBufferCreation p010Creation = tryCreateIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 128, 64);
  bool p010Covered = false;
  if (p010Creation.status == kCVReturnSuccess &&
      p010Creation.buffer != nullptr) {
    wam::macos::FrameLease p010Frame(p010Creation.buffer);
    CVPixelBufferRelease(p010Creation.buffer);
    auto p010Import = cache->importFrame(p010Frame, &error);
    WAM_CHECK(p010Import.has_value());
    WAM_CHECK(error.empty());
    WAM_CHECK(p010Import->planeCount() == 2);
    WAM_CHECK(p010Import->plane(0).width == 128);
    WAM_CHECK(p010Import->plane(0).height == 64);
    WAM_CHECK(p010Import->plane(0).metalPixelFormat ==
              static_cast<std::uint64_t>(MTLPixelFormatR16Unorm));
    WAM_CHECK(p010Import->plane(1).width == 64);
    WAM_CHECK(p010Import->plane(1).height == 32);
    WAM_CHECK(p010Import->plane(1).metalPixelFormat ==
              static_cast<std::uint64_t>(MTLPixelFormatRG16Unorm));
    WAM_CHECK(p010Import->nativeTexture(0) != nullptr);
    WAM_CHECK(p010Import->nativeTexture(1) != nullptr);
    p010Covered = true;
  } else {
    if (p010Creation.buffer != nullptr) {
      CVPixelBufferRelease(p010Creation.buffer);
    }
    std::cout << "P010 import coverage unavailable (CoreVideo status "
              << p010Creation.status << ")\n";
  }

  // Exercise the cache's production concurrency shape: render imports can
  // race memory-pressure flush requests, but all CoreVideo cache calls must be
  // serialized internally.
  std::atomic<bool> concurrentCacheAccessPassed{true};
  std::vector<std::thread> workers;
  for (int worker = 0; worker < 4; ++worker) {
    workers.emplace_back([&, worker] {
      for (int iteration = 0; iteration < 16; ++iteration) {
        std::string threadError;
        auto threadImport = cache->importFrame(nv12Frame, &threadError);
        if (!threadImport || !threadError.empty() ||
            threadImport->nativeTexture(0) == nullptr ||
            threadImport->nativeTexture(1) == nullptr) {
          concurrentCacheAccessPassed.store(false, std::memory_order_relaxed);
          return;
        }
        if ((iteration + worker) % 5 == 0) {
          cache->flush();
        }
      }
    });
  }
  for (std::thread &worker : workers) {
    worker.join();
  }
  WAM_CHECK(concurrentCacheAccessPassed.load(std::memory_order_relaxed));

  CVPixelBufferRef unsupportedBuffer = createRequiredIOSurfacePixelBuffer(
      kCVPixelFormatType_OneComponent8, 16, 16);
  wam::macos::FrameLease unsupported(unsupportedBuffer);
  CVPixelBufferRelease(unsupportedBuffer);
  auto rejected = cache->importFrame(unsupported, &error);
  WAM_CHECK(!rejected.has_value());
  WAM_CHECK(error.find("unsupported CoreVideo pixel format") !=
            std::string::npos);

  // Existing leases must remain usable after a serialized cache flush.
  cache->flush();
  WAM_CHECK(imported->nativeTexture(0) != nullptr);

  wam::macos::MetalFrameLease moved = std::move(*imported);
  WAM_CHECK(moved);
  WAM_CHECK(!static_cast<bool>(*imported));
  WAM_CHECK(moved.frame().timing().generation == 4);

  std::cout << "native macOS frame/queue and NV12/BGRA import coverage passed";
  if (p010Covered) {
    std::cout << "; P010 import coverage passed";
  }
  std::cout << '\n';
  return 0;
}
