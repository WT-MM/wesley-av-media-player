#include "metal_frame_mapper.hpp"
#include "bounded_frame_queue.hpp"
#include "platform/macos/native_surface_budget.hpp"
#include "platform/macos/native_video_presenter.hpp"
#include "support/expect.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>

#import <Metal/Metal.h>

#include <array>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <memory>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

namespace {

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
  REQUIRE(creation.status == kCVReturnSuccess);
  REQUIRE(creation.buffer != nullptr);
  return creation.buffer;
}

void resetSurfaceBudget() {
  EXPECT(wam::macos::NativeSurfaceBudgetTestAccess::reset());
}

void testFrameLeaseSurfaceBudget(wam::macos::FrameTiming timing) {
  using wam::macos::FrameLease;
  using wam::macos::FrameLeaseTestAccess;
  using wam::macos::NativeSurfaceBudget;
  using wam::macos::NativeSurfaceBudgetTestAccess;
  using wam::macos::NativeSurfaceBudgetToken;
  using wam::macos::kNativeSurfaceBudgetProcessMaximumBytes;
  using wam::macos::kNativeSurfaceBudgetProcessMaximumSurfaces;

  resetSurfaceBudget();
  CVPixelBufferRef pixelBuffer = createRequiredIOSurfacePixelBuffer(
      kCVPixelFormatType_32BGRA, 64, 32);
  IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
  REQUIRE(surface != nullptr);
  const std::uint32_t surfaceID =
      static_cast<std::uint32_t>(IOSurfaceGetID(surface));
  const std::uint64_t surfaceBytes =
      static_cast<std::uint64_t>(IOSurfaceGetAllocSize(surface));
  EXPECT(surfaceID != 0);
  EXPECT(surfaceBytes != 0);

  FrameLease original(pixelBuffer, timing);
  CVPixelBufferRelease(pixelBuffer);
  EXPECT(original);
  EXPECT(FrameLeaseTestAccess::surfaceBudgetToken(original));
  EXPECT(FrameLeaseTestAccess::surfaceBudgetToken(original).surfaceID() ==
            surfaceID);
  EXPECT(FrameLeaseTestAccess::surfaceBudgetToken(original).bytes() ==
            surfaceBytes);
  auto stats = NativeSurfaceBudget::stats();
  EXPECT(stats.currentSurfaces == 1);
  EXPECT(stats.currentBytes == surfaceBytes);

  // Every alias clones the existing publication reference. It never charges
  // the same IOSurface a second time.
  FrameLease copied(original);
  FrameLease assigned;
  assigned = original;
  EXPECT(copied);
  EXPECT(assigned);
  EXPECT(copied.pixelBuffer() == original.pixelBuffer());
  EXPECT(assigned.pixelBuffer() == original.pixelBuffer());
  stats = NativeSurfaceBudget::stats();
  EXPECT(stats.currentSurfaces == 1);
  EXPECT(stats.currentBytes == surfaceBytes);

  FrameLease moved(std::move(copied));
  EXPECT(moved);
  EXPECT(!copied);
  EXPECT(copied.pixelBuffer() == nullptr);
  EXPECT(copied.timing().generation == 0);
  EXPECT(!FrameLeaseTestAccess::surfaceBudgetToken(copied));
  FrameLease moveAssigned;
  moveAssigned = std::move(assigned);
  EXPECT(moveAssigned);
  EXPECT(!assigned);
  EXPECT(assigned.pixelBuffer() == nullptr);
  EXPECT(assigned.timing().generation == 0);
  EXPECT(!FrameLeaseTestAccess::surfaceBudgetToken(assigned));

  moved.reset();
  moveAssigned.reset();
  EXPECT(NativeSurfaceBudget::stats().currentSurfaces == 1);
  original.reset();
  EXPECT(NativeSurfaceBudget::stats().currentSurfaces == 0);
  EXPECT(NativeSurfaceBudget::stats().currentBytes == 0);

  // A saturated publication makes the copy constructor fail wholly empty. A
  // copy assignment must provide the stronger guarantee and preserve its
  // unrelated destination lease.
  resetSurfaceBudget();
  CVPixelBufferRef sourceBuffer = createRequiredIOSurfacePixelBuffer(
      kCVPixelFormatType_32BGRA, 48, 24);
  CVPixelBufferRef destinationBuffer = createRequiredIOSurfacePixelBuffer(
      kCVPixelFormatType_32BGRA, 40, 20);
  FrameLease source(sourceBuffer, timing);
  FrameLease destination(destinationBuffer,
                         {CMTimeMake(2, 1), CMTimeMake(1, 1), 19, false});
  CVPixelBufferRelease(sourceBuffer);
  CVPixelBufferRelease(destinationBuffer);
  EXPECT(source);
  EXPECT(destination);
  CVPixelBufferRef preservedDestination = destination.pixelBuffer();
  const std::uint64_t preservedGeneration = destination.timing().generation;
  EXPECT(NativeSurfaceBudgetTestAccess::forceReferenceCount(
      FrameLeaseTestAccess::surfaceBudgetToken(source),
      std::numeric_limits<std::uint32_t>::max()));
  FrameLease failedCopy(source);
  EXPECT(!failedCopy);
  EXPECT(failedCopy.pixelBuffer() == nullptr);
  EXPECT(failedCopy.timing().generation == 0);
  EXPECT(!FrameLeaseTestAccess::surfaceBudgetToken(failedCopy));
  destination = source;
  EXPECT(destination.pixelBuffer() == preservedDestination);
  EXPECT(destination.timing().generation == preservedGeneration);
  EXPECT(NativeSurfaceBudgetTestAccess::forceReferenceCount(
      FrameLeaseTestAccess::surfaceBudgetToken(source), 1));
  source.reset();
  destination.reset();
  EXPECT(NativeSurfaceBudget::stats().currentSurfaces == 0);
  EXPECT(NativeSurfaceBudget::stats().currentBytes == 0);

  // Exercise both hard ceilings without allocating the 64 MiB byte ceiling:
  // accounting-only occupants fill the process budget, then the real
  // IOSurface constructor must fail before retaining the borrowed buffer.
  resetSurfaceBudget();
  CVPixelBufferRef countCandidate = createRequiredIOSurfacePixelBuffer(
      kCVPixelFormatType_32BGRA, 32, 16);
  const std::uint32_t countCandidateID = static_cast<std::uint32_t>(
      IOSurfaceGetID(CVPixelBufferGetIOSurface(countCandidate)));
  std::array<NativeSurfaceBudgetToken,
             static_cast<std::size_t>(kNativeSurfaceBudgetProcessMaximumSurfaces)>
      countOccupants;
  for (std::size_t index = 0; index < countOccupants.size(); ++index) {
    std::uint32_t identity =
        static_cast<std::uint32_t>(0xf0000000U + index);
    if (identity == countCandidateID || identity == 0) {
      identity = static_cast<std::uint32_t>(0xe0000000U + index);
    }
    countOccupants[index] =
        NativeSurfaceBudgetTestAccess::tryAcquire(identity, 1);
    EXPECT(countOccupants[index]);
  }
  FrameLease countDenied(countCandidate, timing);
  EXPECT(!countDenied);
  EXPECT(countDenied.pixelBuffer() == nullptr);
  CVPixelBufferRelease(countCandidate);
  for (NativeSurfaceBudgetToken &token : countOccupants) {
    token.reset();
  }
  EXPECT(NativeSurfaceBudget::stats().currentSurfaces == 0);

  resetSurfaceBudget();
  CVPixelBufferRef byteCandidate = createRequiredIOSurfacePixelBuffer(
      kCVPixelFormatType_32BGRA, 32, 16);
  const std::uint32_t byteCandidateID = static_cast<std::uint32_t>(
      IOSurfaceGetID(CVPixelBufferGetIOSurface(byteCandidate)));
  const std::uint32_t accountingIdentity =
      byteCandidateID == 0xf1000000U ? 0xf1000001U : 0xf1000000U;
  NativeSurfaceBudgetToken byteOccupant =
      NativeSurfaceBudgetTestAccess::tryAcquire(
          accountingIdentity, kNativeSurfaceBudgetProcessMaximumBytes);
  EXPECT(byteOccupant);
  FrameLease byteDenied(byteCandidate, timing);
  EXPECT(!byteDenied);
  EXPECT(byteDenied.pixelBuffer() == nullptr);
  CVPixelBufferRelease(byteCandidate);
  byteOccupant.reset();
  EXPECT(NativeSurfaceBudget::stats().currentSurfaces == 0);
  EXPECT(NativeSurfaceBudget::stats().currentBytes == 0);
}

} // namespace

int main(int argc, char **argv) {
  const bool surfaceBudgetOnly =
      argc == 2 && std::string_view(argv[1]) == "--surface-budget-only";
  EXPECT(argc == 1 || surfaceBudgetOnly);
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
  EXPECT(cpuBufferResult == kCVReturnSuccess);
  EXPECT(pixelBuffer != nullptr);
  wam::macos::FrameTiming timing{CMTimeMake(1001, 24000),
                                 CMTimeMake(1001, 24000), 4, true};
  wam::macos::FrameLease frame(pixelBuffer, timing);
  CVPixelBufferRelease(pixelBuffer);

  EXPECT(frame);
  EXPECT(!frame.isIOSurfaceBacked());
  EXPECT(frame.ioSurface() == nullptr);
  EXPECT(frame.width() == cpuWidth);
  EXPECT(frame.height() == cpuHeight);
  EXPECT(frame.pixelFormat() == kCVPixelFormatType_32BGRA);
  EXPECT(frame.timing().generation == 4);

  // CPU-backed copies retain only the CoreVideo object; pixel memory is not
  // duplicated and no IOSurface accounting token is required.
  wam::macos::FrameLease copied = frame;
  frame.reset();
  EXPECT(copied);
  EXPECT(copied.width() == cpuWidth);

  testFrameLeaseSurfaceBudget(timing);

  // The decode-to-display handoff has a hard frame bound and rejects stale
  // generations, so seeks and a slow display cannot grow memory indefinitely.
  wam::test::BoundedFrameQueue queue(2, 4);
  EXPECT(queue.capacity() == 2);
  EXPECT(queue.enqueue(copied, &error) ==
            wam::macos::FrameEnqueueResult::Accepted);
  EXPECT(queue.enqueue(copied, &error) ==
            wam::macos::FrameEnqueueResult::Accepted);
  EXPECT(queue.size() == 2);
  EXPECT(queue.enqueue(copied, &error) ==
            wam::macos::FrameEnqueueResult::Backpressure);
  EXPECT(error == "decoded-frame queue is full");
  auto dequeued = queue.tryTake();
  REQUIRE(dequeued.has_value());
  EXPECT(queue.size() == 1);
  queue.endOfStream(4);
  EXPECT(queue.enqueue(copied, &error) ==
            wam::macos::FrameEnqueueResult::Rejected);
  EXPECT(error == "cannot enqueue after end of stream");
  EXPECT(!queue.reachedEndOfStream());
  EXPECT(queue.tryTake().has_value());
  EXPECT(queue.reachedEndOfStream());
  queue.flush(5);
  EXPECT(queue.generation() == 5);
  EXPECT(!queue.reachedEndOfStream());
  EXPECT(queue.enqueue(copied, &error) ==
            wam::macos::FrameEnqueueResult::Rejected);
  EXPECT(error == "rejecting a stale decoded-frame generation");

  // Independently establish genuine device absence. Once a device exists,
  // MetalTextureCache::create() returning null is an implementation failure,
  // not a reason to skip the test.
  id<MTLDevice> systemDevice = MTLCreateSystemDefaultDevice();
  if (systemDevice == nil) {
    std::cerr << "SKIP: Metal is unavailable on this Mac; "
                 "frame and bounded-queue coverage passed\n";
    return failures == 0 ? 77 : 1;
  }

  auto cache = wam::macos::MetalTextureCache::create(nullptr, &error);
  REQUIRE(cache != nullptr);
  EXPECT(error.empty());
  EXPECT(cache->nativeDevice() != nullptr);

  auto hiddenCopy = cache->importFrame(copied, &error);
  EXPECT(!hiddenCopy.has_value());
  EXPECT(error ==
            "frame is not IOSurface-backed; refusing a hidden copy path");

  CVPixelBufferRef nv12Buffer = createRequiredIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 128, 64);
  wam::macos::FrameLease nv12Frame(nv12Buffer, timing);
  CVPixelBufferRelease(nv12Buffer);
  EXPECT(nv12Frame.isIOSurfaceBacked());

  // Metal import must treat a failed FrameLease token clone as an atomic
  // failure; it cannot return textures without retaining their source frame.
  EXPECT(wam::macos::NativeSurfaceBudgetTestAccess::forceReferenceCount(
      wam::macos::FrameLeaseTestAccess::surfaceBudgetToken(nv12Frame),
      std::numeric_limits<std::uint32_t>::max()));
  auto failedBudgetImport = cache->importFrame(nv12Frame, &error);
  EXPECT(!failedBudgetImport.has_value());
  EXPECT(error ==
            "could not clone decoded-surface accounting token for Metal "
            "import");
  EXPECT(wam::macos::NativeSurfaceBudgetTestAccess::forceReferenceCount(
      wam::macos::FrameLeaseTestAccess::surfaceBudgetToken(nv12Frame), 1));

  auto imported = cache->importFrame(nv12Frame, &error);
  REQUIRE(imported.has_value());
  EXPECT(error.empty());
  EXPECT(imported->planeCount() == 2);
  EXPECT(imported->plane(0).width == 128);
  EXPECT(imported->plane(0).height == 64);
  EXPECT(imported->plane(0).metalPixelFormat ==
            static_cast<std::uint64_t>(MTLPixelFormatR8Unorm));
  EXPECT(imported->plane(1).width == 64);
  EXPECT(imported->plane(1).height == 32);
  EXPECT(imported->plane(1).metalPixelFormat ==
            static_cast<std::uint64_t>(MTLPixelFormatRG8Unorm));
  EXPECT(imported->nativeTexture(0) != nullptr);
  EXPECT(imported->nativeTexture(1) != nullptr);

  CVPixelBufferRef bgraBuffer =
      createRequiredIOSurfacePixelBuffer(kCVPixelFormatType_32BGRA, 96, 48);
  wam::macos::FrameLease bgraFrame(bgraBuffer);
  CVPixelBufferRelease(bgraBuffer);
  auto bgraImport = cache->importFrame(bgraFrame, &error);
  REQUIRE(bgraImport.has_value());
  EXPECT(error.empty());
  EXPECT(bgraImport->planeCount() == 1);
  EXPECT(bgraImport->plane(0).width == 96);
  EXPECT(bgraImport->plane(0).height == 48);
  EXPECT(bgraImport->plane(0).metalPixelFormat ==
            static_cast<std::uint64_t>(MTLPixelFormatBGRA8Unorm));
  EXPECT(bgraImport->nativeTexture(0) != nullptr);

  if (surfaceBudgetOnly) {
    std::cout << "native FrameLease surface-budget and Metal-import checks "
                 "passed\n";
    return failures == 0 ? 0 : 1;
  }

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
    REQUIRE(p010Import.has_value());
    EXPECT(error.empty());
    EXPECT(p010Import->planeCount() == 2);
    EXPECT(p010Import->plane(0).width == 128);
    EXPECT(p010Import->plane(0).height == 64);
    EXPECT(p010Import->plane(0).metalPixelFormat ==
              static_cast<std::uint64_t>(MTLPixelFormatR16Unorm));
    EXPECT(p010Import->plane(1).width == 64);
    EXPECT(p010Import->plane(1).height == 32);
    EXPECT(p010Import->plane(1).metalPixelFormat ==
              static_cast<std::uint64_t>(MTLPixelFormatRG16Unorm));
    EXPECT(p010Import->nativeTexture(0) != nullptr);
    EXPECT(p010Import->nativeTexture(1) != nullptr);
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
  EXPECT(concurrentCacheAccessPassed.load(std::memory_order_relaxed));

  CVPixelBufferRef unsupportedBuffer = createRequiredIOSurfacePixelBuffer(
      kCVPixelFormatType_OneComponent8, 16, 16);
  wam::macos::FrameLease unsupported(unsupportedBuffer);
  CVPixelBufferRelease(unsupportedBuffer);
  auto rejected = cache->importFrame(unsupported, &error);
  EXPECT(!rejected.has_value());
  EXPECT(error.find("unsupported CoreVideo pixel format") !=
            std::string::npos);

  // Existing leases must remain usable after a serialized cache flush.
  cache->flush();
  EXPECT(imported->nativeTexture(0) != nullptr);

  wam::macos::MetalFrameLease moved = std::move(*imported);
  EXPECT(moved);
  EXPECT(!static_cast<bool>(*imported));
  EXPECT(moved.frame().timing().generation == 4);

  std::cout << "native macOS frame/queue and NV12/BGRA import coverage passed";
  if (p010Covered) {
    std::cout << "; P010 import coverage passed";
  }
  std::cout << '\n';
  return failures == 0 ? 0 : 1;
}
