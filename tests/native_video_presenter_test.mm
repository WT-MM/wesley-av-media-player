#define WAM_NATIVE_FRAME_LEASE_TESTING 1
#define WAM_NATIVE_SURFACE_BUDGET_TESTING 1
#define WAM_METAL_LAYER_PRESENTER_TESTING 1
// Compile the accounting implementation and presenter exception seams into
// this focused test translation unit so neither test-only API exists in
// wam_macos_native_video. The static linker consequently extracts only the
// frame/texture-cache implementation from that production archive; the
// link/symbol check in local validation guards against duplicate definitions.
#include "platform/macos/native_surface_budget.mm"
#include "platform/macos/metal_layer_presenter.mm"

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

void resetSurfaceBudget() {
  WAM_CHECK(wam::macos::NativeSurfaceBudgetTestAccess::reset());
}

void testFrameLeaseSurfaceBudget(wam::macos::FrameTiming timing) {
  using wam::macos::FrameLease;
  using wam::macos::FrameLeaseTestAccess;
  using wam::macos::NativeSurfaceBudget;
  using wam::macos::NativeSurfaceBudgetTestAccess;
  using wam::macos::NativeSurfaceBudgetToken;
  using wam::macos::kNativeSurfaceBudgetMaximumBytes;
  using wam::macos::kNativeSurfaceBudgetMaximumSurfaces;

  resetSurfaceBudget();
  CVPixelBufferRef pixelBuffer = createRequiredIOSurfacePixelBuffer(
      kCVPixelFormatType_32BGRA, 64, 32);
  IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
  WAM_CHECK(surface != nullptr);
  const std::uint32_t surfaceID =
      static_cast<std::uint32_t>(IOSurfaceGetID(surface));
  const std::uint64_t surfaceBytes =
      static_cast<std::uint64_t>(IOSurfaceGetAllocSize(surface));
  WAM_CHECK(surfaceID != 0);
  WAM_CHECK(surfaceBytes != 0);

  FrameLease original(pixelBuffer, timing);
  CVPixelBufferRelease(pixelBuffer);
  WAM_CHECK(original);
  WAM_CHECK(FrameLeaseTestAccess::surfaceBudgetToken(original));
  WAM_CHECK(FrameLeaseTestAccess::surfaceBudgetToken(original).surfaceID() ==
            surfaceID);
  WAM_CHECK(FrameLeaseTestAccess::surfaceBudgetToken(original).bytes() ==
            surfaceBytes);
  auto stats = NativeSurfaceBudget::stats();
  WAM_CHECK(stats.currentSurfaces == 1);
  WAM_CHECK(stats.currentBytes == surfaceBytes);

  // Every alias clones the existing publication reference. It never charges
  // the same IOSurface a second time.
  FrameLease copied(original);
  FrameLease assigned;
  assigned = original;
  WAM_CHECK(copied);
  WAM_CHECK(assigned);
  WAM_CHECK(copied.pixelBuffer() == original.pixelBuffer());
  WAM_CHECK(assigned.pixelBuffer() == original.pixelBuffer());
  stats = NativeSurfaceBudget::stats();
  WAM_CHECK(stats.currentSurfaces == 1);
  WAM_CHECK(stats.currentBytes == surfaceBytes);

  FrameLease moved(std::move(copied));
  WAM_CHECK(moved);
  WAM_CHECK(!copied);
  WAM_CHECK(copied.pixelBuffer() == nullptr);
  WAM_CHECK(copied.timing().generation == 0);
  WAM_CHECK(!FrameLeaseTestAccess::surfaceBudgetToken(copied));
  FrameLease moveAssigned;
  moveAssigned = std::move(assigned);
  WAM_CHECK(moveAssigned);
  WAM_CHECK(!assigned);
  WAM_CHECK(assigned.pixelBuffer() == nullptr);
  WAM_CHECK(assigned.timing().generation == 0);
  WAM_CHECK(!FrameLeaseTestAccess::surfaceBudgetToken(assigned));

  moved.reset();
  moveAssigned.reset();
  WAM_CHECK(NativeSurfaceBudget::stats().currentSurfaces == 1);
  original.reset();
  WAM_CHECK(NativeSurfaceBudget::stats().currentSurfaces == 0);
  WAM_CHECK(NativeSurfaceBudget::stats().currentBytes == 0);

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
  WAM_CHECK(source);
  WAM_CHECK(destination);
  CVPixelBufferRef preservedDestination = destination.pixelBuffer();
  const std::uint64_t preservedGeneration = destination.timing().generation;
  WAM_CHECK(NativeSurfaceBudgetTestAccess::forceReferenceCount(
      FrameLeaseTestAccess::surfaceBudgetToken(source),
      std::numeric_limits<std::uint32_t>::max()));
  FrameLease failedCopy(source);
  WAM_CHECK(!failedCopy);
  WAM_CHECK(failedCopy.pixelBuffer() == nullptr);
  WAM_CHECK(failedCopy.timing().generation == 0);
  WAM_CHECK(!FrameLeaseTestAccess::surfaceBudgetToken(failedCopy));
  destination = source;
  WAM_CHECK(destination.pixelBuffer() == preservedDestination);
  WAM_CHECK(destination.timing().generation == preservedGeneration);
  WAM_CHECK(NativeSurfaceBudgetTestAccess::forceReferenceCount(
      FrameLeaseTestAccess::surfaceBudgetToken(source), 1));
  source.reset();
  destination.reset();
  WAM_CHECK(NativeSurfaceBudget::stats().currentSurfaces == 0);
  WAM_CHECK(NativeSurfaceBudget::stats().currentBytes == 0);

  // Exercise both hard ceilings without allocating the 64 MiB byte ceiling:
  // accounting-only occupants fill the process budget, then the real
  // IOSurface constructor must fail before retaining the borrowed buffer.
  resetSurfaceBudget();
  CVPixelBufferRef countCandidate = createRequiredIOSurfacePixelBuffer(
      kCVPixelFormatType_32BGRA, 32, 16);
  const std::uint32_t countCandidateID = static_cast<std::uint32_t>(
      IOSurfaceGetID(CVPixelBufferGetIOSurface(countCandidate)));
  std::array<NativeSurfaceBudgetToken,
             static_cast<std::size_t>(kNativeSurfaceBudgetMaximumSurfaces)>
      countOccupants;
  for (std::size_t index = 0; index < countOccupants.size(); ++index) {
    std::uint32_t identity =
        static_cast<std::uint32_t>(0xf0000000U + index);
    if (identity == countCandidateID || identity == 0) {
      identity = static_cast<std::uint32_t>(0xe0000000U + index);
    }
    countOccupants[index] =
        NativeSurfaceBudgetTestAccess::tryAcquire(identity, 1);
    WAM_CHECK(countOccupants[index]);
  }
  FrameLease countDenied(countCandidate, timing);
  WAM_CHECK(!countDenied);
  WAM_CHECK(countDenied.pixelBuffer() == nullptr);
  CVPixelBufferRelease(countCandidate);
  for (NativeSurfaceBudgetToken &token : countOccupants) {
    token.reset();
  }
  WAM_CHECK(NativeSurfaceBudget::stats().currentSurfaces == 0);

  resetSurfaceBudget();
  CVPixelBufferRef byteCandidate = createRequiredIOSurfacePixelBuffer(
      kCVPixelFormatType_32BGRA, 32, 16);
  const std::uint32_t byteCandidateID = static_cast<std::uint32_t>(
      IOSurfaceGetID(CVPixelBufferGetIOSurface(byteCandidate)));
  const std::uint32_t accountingIdentity =
      byteCandidateID == 0xf1000000U ? 0xf1000001U : 0xf1000000U;
  NativeSurfaceBudgetToken byteOccupant =
      NativeSurfaceBudgetTestAccess::tryAcquire(
          accountingIdentity, kNativeSurfaceBudgetMaximumBytes);
  WAM_CHECK(byteOccupant);
  FrameLease byteDenied(byteCandidate, timing);
  WAM_CHECK(!byteDenied);
  WAM_CHECK(byteDenied.pixelBuffer() == nullptr);
  CVPixelBufferRelease(byteCandidate);
  byteOccupant.reset();
  WAM_CHECK(NativeSurfaceBudget::stats().currentSurfaces == 0);
  WAM_CHECK(NativeSurfaceBudget::stats().currentBytes == 0);
}

} // namespace

int main(int argc, char **argv) {
  const bool surfaceBudgetOnly =
      argc == 2 && std::string_view(argv[1]) == "--surface-budget-only";
  WAM_CHECK(argc == 1 || surfaceBudgetOnly);
  static_assert(noexcept(std::declval<wam::macos::MetalLayerPresenter&>()
                             .present(
                                 std::declval<const wam::macos::FrameLease&>(),
                                 nullptr)));
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

  // CPU-backed copies retain only the CoreVideo object; pixel memory is not
  // duplicated and no IOSurface accounting token is required.
  wam::macos::FrameLease copied = frame;
  frame.reset();
  WAM_CHECK(copied);
  WAM_CHECK(copied.width() == cpuWidth);

  testFrameLeaseSurfaceBudget(timing);

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

  // The exact accounting state machine is deterministic even on Macs/runners
  // that expose no Metal device. These seams execute the same reservation,
  // ticket, abort-guard, and group ownership types used by present().
  const auto requireAccountingFault =
      [](wam::macos::MetalLayerPresenterFaultPoint point,
         bool reachesSubmission) {
        const auto outcome =
            wam::macos::MetalLayerPresenterTestAccess::exerciseAccountingFault(
                point);
        WAM_CHECK(outcome.exceptionCaught);
        WAM_CHECK(outcome.groupIdle);
        WAM_CHECK(!wam::macos::MetalLayerPresenterTestAccess::faultPending());
        WAM_CHECK(outcome.statistics.inFlightFrames == 0);
        WAM_CHECK(outcome.statistics.completedFrames == 0);
        WAM_CHECK(outcome.statistics.submittedFrames ==
                  (reachesSubmission ? 1 : 0));
        WAM_CHECK(outcome.statistics.failedFrames ==
                  (reachesSubmission ? 1 : 0));
      };
  requireAccountingFault(
      wam::macos::MetalLayerPresenterFaultPoint::CompletionGroupAllocation,
      false);
  requireAccountingFault(
      wam::macos::MetalLayerPresenterFaultPoint::ErrorAssignment, false);
  requireAccountingFault(
      wam::macos::MetalLayerPresenterFaultPoint::TextureImport, false);
  requireAccountingFault(
      wam::macos::MetalLayerPresenterFaultPoint::FrameLeaseAllocation, false);
  requireAccountingFault(
      wam::macos::MetalLayerPresenterFaultPoint::FailureHandlerCopy, false);
  requireAccountingFault(
      wam::macos::MetalLayerPresenterFaultPoint::CompletionTicketAllocation,
      false);
  requireAccountingFault(
      wam::macos::MetalLayerPresenterFaultPoint::CompletionHandlerInstallation,
      false);
  requireAccountingFault(
      wam::macos::MetalLayerPresenterFaultPoint::CommandBufferCommit, true);
  std::cout << "Metal presenter exception-accounting coverage passed\n";

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

  // Metal import must treat a failed FrameLease token clone as an atomic
  // failure; it cannot return textures without retaining their source frame.
  WAM_CHECK(wam::macos::NativeSurfaceBudgetTestAccess::forceReferenceCount(
      wam::macos::FrameLeaseTestAccess::surfaceBudgetToken(nv12Frame),
      std::numeric_limits<std::uint32_t>::max()));
  auto failedBudgetImport = cache->importFrame(nv12Frame, &error);
  WAM_CHECK(!failedBudgetImport.has_value());
  WAM_CHECK(error ==
            "could not clone decoded-surface accounting token for Metal "
            "import");
  WAM_CHECK(wam::macos::NativeSurfaceBudgetTestAccess::forceReferenceCount(
      wam::macos::FrameLeaseTestAccess::surfaceBudgetToken(nv12Frame), 1));

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

  if (surfaceBudgetOnly) {
    std::cout << "native FrameLease surface-budget and Metal-import checks "
                 "passed\n";
    return EXIT_SUCCESS;
  }

  // Every potentially allocating stage in present() must fail closed without
  // leaking either an in-flight slot or a dispatch-group enter. This presenter
  // is deliberately offscreen: CAMetalLayer still supplies bounded drawables,
  // while the test launches no GUI and never waits on the render thread.
  auto presenter = wam::macos::MetalLayerPresenter::create(&error);
  WAM_CHECK(presenter != nullptr);
  WAM_CHECK(error.empty());
  NSView* presenterHost =
      [[NSView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 320.0, 180.0)];
  WAM_CHECK(presenter->attachToView((__bridge void*)presenterHost, &error));
  WAM_CHECK(error.empty());
  presenter->setVisible(true);
  const auto failureLifetime = std::make_shared<int>(1);
  presenter->setFailureHandler(
      failureLifetime, [](std::string) { WAM_CHECK(false); });

  const auto requireInjectedFailure =
      [&](wam::macos::MetalLayerPresenterFaultPoint point,
          bool reachesSubmission, bool platformException) {
        const wam::macos::MetalLayerPresenterStats before =
            presenter->stats();
        wam::macos::MetalLayerPresenterTestAccess::failNext(point);
        error = "stale diagnostic";
        wam::macos::MetalPresentResult result =
            wam::macos::MetalPresentResult::Presented;
        @autoreleasepool {
          result = presenter->present(bgraFrame, &error);
        }
        WAM_CHECK(result == wam::macos::MetalPresentResult::Failed);
        WAM_CHECK(!wam::macos::MetalLayerPresenterTestAccess::faultPending());
        const std::string expectedError =
            platformException
                ? "Metal presenter rejected a frame after a platform failure"
                : "Metal presenter rejected a frame after an internal failure";
        if (error != expectedError) {
          std::cerr << "unexpected Metal fault diagnostic for point "
                    << static_cast<int>(point) << ": expected '"
                    << expectedError << "', got '" << error << "'\n";
        }
        WAM_CHECK(error == expectedError);
        const wam::macos::MetalLayerPresenterStats after = presenter->stats();
        WAM_CHECK(after.inFlightFrames == before.inFlightFrames);
        WAM_CHECK(after.completedFrames == before.completedFrames);
        WAM_CHECK(after.submittedFrames ==
                  before.submittedFrames + (reachesSubmission ? 1 : 0));
        WAM_CHECK(after.failedFrames ==
                  before.failedFrames + (reachesSubmission ? 1 : 0));
        WAM_CHECK(
            wam::macos::MetalLayerPresenterTestAccess::completionGroupIdle(
                *presenter));
      };

  // Error construction itself can fail before any frame reservation exists.
  wam::macos::MetalLayerPresenterTestAccess::failNext(
      wam::macos::MetalLayerPresenterFaultPoint::ErrorAssignment);
  error = "stale diagnostic";
  WAM_CHECK(presenter->present({}, &error) ==
            wam::macos::MetalPresentResult::Failed);
  WAM_CHECK(!wam::macos::MetalLayerPresenterTestAccess::faultPending());
  WAM_CHECK(error ==
            "Metal presenter rejected a frame after an internal failure");
  WAM_CHECK(presenter->stats().inFlightFrames == 0);
  WAM_CHECK(
      wam::macos::MetalLayerPresenterTestAccess::completionGroupIdle(
          *presenter));

  requireInjectedFailure(
      wam::macos::MetalLayerPresenterFaultPoint::TextureImport, false, false);
  requireInjectedFailure(
      wam::macos::MetalLayerPresenterFaultPoint::FrameLeaseAllocation, false,
      false);
  requireInjectedFailure(
      wam::macos::MetalLayerPresenterFaultPoint::FailureHandlerCopy, false,
      false);
  requireInjectedFailure(
      wam::macos::MetalLayerPresenterFaultPoint::CompletionTicketAllocation,
      false, false);
  requireInjectedFailure(
      wam::macos::MetalLayerPresenterFaultPoint::CompletionHandlerInstallation,
      false, true);
  requireInjectedFailure(
      wam::macos::MetalLayerPresenterFaultPoint::CommandBufferCommit, true,
      true);
  presenter->detach();

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
