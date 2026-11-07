#include "platform/macos/native_layer_video_output.hpp"
#include "platform/macos/native_layer_host_view.hpp"
#include "platform/macos/video_quarter_turn.hpp"

#include "platform/macos/native_layer_presentation_state.hpp"
#include "platform/macos/native_surface_budget.hpp"
#include "platform/macos/native_tracked_video_output.hpp"
#include "platform/macos/native_video_presenter.hpp"
#include "support/expect.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <AppKit/AppKit.h>
#include <dlfcn.h>

#include <cmath>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <thread>

// Contract conformance for the CALayer presentation route's
// NativeTrackedVideoOutput (DESIGN.md file-change item #8, modelled on
// tests/native_qt_gl_output_test.mm).
//
// HEADLESS BY CONSTRUCTION. Every case below runs through
// NativeLayerVideoOutput::createTracked(nullptr, ...), which builds its own
// detached AVSampleBufferDisplayLayer. An ASBDL accepts and acknowledges
// enqueues without ever joining a view hierarchy, so no window, no NSApp, and
// no compositing session is required. Nothing in this file grabs pixels or
// asserts anything about photons, which is exactly what the presenter's own
// "DRAW PROOF CLASS" comment says FrameDrawn does and does not mean.
//
// NO UNBOUNDED WAIT. The renderer's flush completion handler is the layer
// route's only asynchronous edge, and it is the sole thing any spin here waits
// on. Every wait is deadline-bounded and fails the test rather than hanging.
//
// WHAT THIS FILE DELIBERATELY DOES NOT COVER, and why:
//
//  * The drop audit (dropDebt -> FrameSuperseded). Drop counts come only from
//    AVVideoPerformanceMetrics via the asynchronous, [SPI]-tagged
//    loadVideoPerformanceMetricsWithCompletionHandler:, which may yield nil and
//    which no test can make report a nonzero numberOfDroppedFrames on demand.
//    Every output instance below stays under kMetricsLoadFrameInterval (30)
//    submits, so no metrics load is ever issued; health().metricsLoads == 0 is
//    asserted to keep that justification mechanical rather than assumed. This
//    is also why every terminal event here is exactly FrameDrawn: with
//    dropDebt pinned at zero the supersede-on-drop branch cannot fire.
//
//  * FrameSuperseded from flushProgress()/closeProgress(). Those two call sites
//    are guarded by `trackedFrame.valid() && !trackedEvent`, and that state is
//    unreachable in this implementation: submit() publishes the terminal event
//    synchronously in the same locked section that admits the frame, and
//    takeEvent() clears the admission and the mailbox together. The branch is
//    therefore dead code for every input this contract permits, and asserting
//    a FrameSuperseded that the code cannot produce would be a false test. What
//    IS asserted instead is the observable consequence: an unconsumed terminal
//    event holds both flushProgress() and closeProgress() at Quiescing.
//
//  * The bit-for-bit PTS/duration restatement *inside* the CMSampleBuffer. The
//    sample buffer is created, enqueued, and released entirely within submit();
//    it is never exposed, and the detached renderer offers no accessor for the
//    sample it took. The observable half of that same guarantee -- the exact
//    timing echoed back in the terminal event -- is asserted field by field
//    (value, timescale, flags, epoch), which is the property a consumer can
//    actually depend on.

namespace {

using namespace wam::macos;

// Detail form built on the shared expect: the failing expression plus context.
#define WAM_CHECK_DETAIL(expression, detail)                                   \
  expect(static_cast<bool>(expression),                                        \
         std::string(WAM_EXPECT_LOCATION_(__LINE__) ": " #expression " (") +   \
             (detail) + ")")
#define WAM_REQUIRE_DETAIL(expression, detail)                                 \
  require(static_cast<bool>(expression),                                       \
          std::string(WAM_EXPECT_LOCATION_(__LINE__) ": " #expression " (") +  \
              (detail) + ")")

// The renderer's flush completion handler may be scheduled on the main run
// loop of a process that otherwise never runs one. Pump it so a headless test
// can never block on a callback it is itself starving, and bound every wait so
// a callback that never arrives fails the test instead of hanging it.
template <typename Predicate>
bool spinUntil(Predicate predicate, int timeoutMs = 5000) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
  for (;;) {
    if (predicate()) {
      return true;
    }
    if (std::chrono::steady_clock::now() >= deadline) {
      return predicate();
    }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.002, true);
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
}

void pumpFor(int durationMs) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(durationMs);
  while (std::chrono::steady_clock::now() < deadline) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.002, true);
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
}

CVPixelBufferRef createSolidNv12(std::uint8_t luma) {
  CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 2, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFDictionaryRef empty = CFDictionaryCreate(
      kCFAllocatorDefault, nullptr, nullptr, 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(attributes, kCVPixelBufferIOSurfacePropertiesKey, empty);
  CFDictionarySetValue(attributes, kCVPixelBufferMetalCompatibilityKey,
                       kCFBooleanTrue);

  CVPixelBufferRef buffer = nullptr;
  const CVReturn status = CVPixelBufferCreate(
      kCFAllocatorDefault, 160, 90,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer);
  CFRelease(empty);
  CFRelease(attributes);
  if (status != kCVReturnSuccess || buffer == nullptr ||
      CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) {
    if (buffer != nullptr) {
      CVPixelBufferRelease(buffer);
    }
    return nullptr;
  }

  auto* yPlane =
      static_cast<std::uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
  auto* uvPlane =
      static_cast<std::uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(buffer, 1));
  for (std::size_t y = 0; y < CVPixelBufferGetHeightOfPlane(buffer, 0); ++y) {
    std::fill_n(yPlane + y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                CVPixelBufferGetWidthOfPlane(buffer, 0), luma);
  }
  for (std::size_t y = 0; y < CVPixelBufferGetHeightOfPlane(buffer, 1); ++y) {
    auto* row = uvPlane + y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
    for (std::size_t x = 0; x < CVPixelBufferGetWidthOfPlane(buffer, 1); ++x) {
      row[x * 2] = 128;
      row[x * 2 + 1] = 128;
    }
  }
  CVPixelBufferUnlockBaseAddress(buffer, 0);
  CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                        kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                        kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey,
                        kCVImageBufferChromaLocation_Center,
                        kCVAttachmentMode_ShouldPropagate);
  return buffer;
}

// One distinct IOSurface per frame, so the presenter's own retention is
// separately visible in NativeSurfaceBudget's unique-surface count.
FrameTiming makeTiming(std::uint64_t generation, std::int64_t frameIndex) {
  FrameTiming timing;
  timing.presentationTime = CMTimeMake(1001 * frameIndex, 30000);
  timing.duration = CMTimeMake(1001, 30000);
  timing.generation = generation;
  timing.keyFrame = frameIndex == 0;
  return timing;
}

FrameLease makeFrame(std::uint64_t generation, std::int64_t frameIndex,
                     std::uint8_t luma) {
  CVPixelBufferRef buffer = createSolidNv12(luma);
  REQUIRE(buffer != nullptr);
  FrameLease frame(buffer, makeTiming(generation, frameIndex));
  CVPixelBufferRelease(buffer);
  REQUIRE(static_cast<bool>(frame));
  EXPECT(frame.isIOSurfaceBacked());
  return frame;
}

void trackedWake(void* context) noexcept {
  static_cast<std::atomic<std::uint64_t>*>(context)->fetch_add(
      1, std::memory_order_release);
}

std::shared_ptr<NativeLayerVideoOutput> createDetached(
    std::atomic<std::uint64_t>* wakes) {
  std::string error;
  auto output = NativeLayerVideoOutput::createTracked(
      nullptr, NativeTrackedVideoOutputWakeSeam{trackedWake, wakes}, &error);
  WAM_REQUIRE_DETAIL(output != nullptr, error);
  EXPECT(error.empty());
  return output;
}

// Arms the first generation the way production does: a flush from 0.
void armFirstGeneration(NativeLayerVideoOutput& output) {
  EXPECT(spinUntil([&] {
    return output.flushProgress(0, 1) ==
           NativeTrackedVideoOutputProgress::Done;
  }));
}

// Terminal teardown shared by every case, so no test can leave the
// process-global presentation flag or the surface budget dirty for the next
// one. finalGeneration must be strictly newer than the accepted generation.
void closeAndDrop(std::shared_ptr<NativeLayerVideoOutput> output,
                  std::uint64_t finalGeneration) {
  EXPECT(spinUntil([&] {
    return output->closeProgress(finalGeneration) ==
           NativeTrackedVideoOutputProgress::Done;
  }));
  EXPECT(output->facts().closed);
  output.reset();
  EXPECT(!nativeLayerPresentationActive());
}

// ---------------------------------------------------------------- case 1 + 2

// createTracked(nullptr, ...) builds its own detached layer, publishes the
// presentation flag, and refuses every submit until a generation is armed.
void verifyDetachedConstructionAndActivation() {
  EXPECT(!nativeLayerPresentationActive());
  std::atomic<std::uint64_t> wakes{0};
  auto output = createDetached(&wakes);
  EXPECT(nativeLayerPresentationActive());

  const auto initial = output->facts();
  EXPECT(initial.generation == 0);
  EXPECT(!initial.admittedFrame.valid());
  EXPECT(initial.submittedFrames == 0);
  EXPECT(initial.drawnFrames == 0);
  EXPECT(initial.supersededFrames == 0);
  EXPECT(initial.lastEventSequence == 0);
  EXPECT(initial.retainedFrames == 0);
  EXPECT(!initial.eventPending);
  EXPECT(!initial.invalidationPending);
  EXPECT(!initial.closed);
  EXPECT(!initial.fatal);
  REQUIRE(!output->takeEvent().has_value());

  const auto initialHealth = output->health();
  EXPECT(initialHealth.enqueuedFrames == 0);
  EXPECT(initialHealth.drawnFrames == 0);
  EXPECT(initialHealth.supersededByDropFrames == 0);
  EXPECT(initialHealth.flushes == 0);
  EXPECT(initialHealth.metricsLoads == 0);
  EXPECT(initialHealth.peakRetainedLeases == 0);

  // Zero is never a generation, and nothing is accepted before the first arm.
  EXPECT(output->capacity(0) ==
            NativeTrackedVideoCapacity::StaleGeneration);
  EXPECT(output->capacity(1) ==
            NativeTrackedVideoCapacity::StaleGeneration);
  {
    std::string error;
    auto premature = makeFrame(1, 0, 140);
    EXPECT(output->submit(premature, NativeTrackedFrameSequence{1},
                             &error) ==
              NativeTrackedVideoSubmitStatus::StaleGeneration);
    REQUIRE(!error.empty());
  }

  std::string error;
  EXPECT(output->flushProgress(0, 0) ==
            NativeTrackedVideoOutputProgress::Failed);
  armFirstGeneration(*output);
  // The arm is repeatable for its exact pair only.
  EXPECT(output->flushProgress(0, 1) ==
            NativeTrackedVideoOutputProgress::Done);
  EXPECT(output->flushProgress(0, 2) ==
            NativeTrackedVideoOutputProgress::StaleGeneration);
  EXPECT(output->capacity(1) == NativeTrackedVideoCapacity::Available);
  EXPECT(output->capacity(2) ==
            NativeTrackedVideoCapacity::StaleGeneration);
  EXPECT(output->facts().generation == 1);

  // An armed-but-idle output has nothing to invalidate, so its close needs only
  // the renderer's flush acknowledgment.
  closeAndDrop(std::move(output), 2);
}

// -------------------------------------------------------------- case 2, 3, 4

// Capacity-one admission, the caller-owned frame identity, the output-owned
// event identity, and the exact timing echo.
void verifyCapacityOneAdmissionAndExactTimingEcho() {
  std::atomic<std::uint64_t> wakes{0};
  auto output = createDetached(&wakes);
  std::string error;
  armFirstGeneration(*output);
  EXPECT(output->capacity(1) == NativeTrackedVideoCapacity::Available);

  const FrameTiming firstTiming = makeTiming(1, 0);
  auto first = makeFrame(1, 0, 160);
  EXPECT(sameFrameTiming(first.timing(), firstTiming));
  EXPECT(output->submit(first, NativeTrackedFrameSequence{1}, &error) ==
            NativeTrackedVideoSubmitStatus::Accepted);
  EXPECT(error.empty());
  EXPECT(wakes.load(std::memory_order_acquire) >= 1);

  const auto admitted = output->facts();
  EXPECT(admitted.generation == 1);
  EXPECT(admitted.admittedFrame.value == 1);
  EXPECT(admitted.submittedFrames == 1);
  EXPECT(admitted.drawnFrames == 1);
  EXPECT(admitted.supersededFrames == 0);
  EXPECT(admitted.lastEventSequence == 1);
  EXPECT(admitted.retainedFrames == 1);
  EXPECT(admitted.eventPending);
  EXPECT(!admitted.invalidationPending);
  EXPECT(!admitted.fatal);

  // Capacity one: the boundary is closed until the terminal fact is consumed.
  EXPECT(output->capacity(1) == NativeTrackedVideoCapacity::Backpressure);
  {
    auto second = makeFrame(1, 1, 170);
    EXPECT(output->submit(second, NativeTrackedFrameSequence{2}, &error) ==
              NativeTrackedVideoSubmitStatus::Backpressure);
  }
  EXPECT(output->facts().submittedFrames == 1);

  const auto drawn = output->takeEvent();
  REQUIRE(drawn.has_value());
  EXPECT(drawn->kind == NativeTrackedVideoEventKind::FrameDrawn);
  EXPECT(drawn->eventSequence == 1);
  EXPECT(drawn->frameSequence.value == 1);
  EXPECT(drawn->generation == 1);
  // Bit-for-bit, not merely CMTimeCompare-equal.
  EXPECT(sameFrameTiming(drawn->timing, firstTiming));
  EXPECT(CMTimeCompare(drawn->timing.presentationTime,
                          first.timing().presentationTime) == 0);

  // Exactly one terminal event: never both kinds, never a second copy.
  REQUIRE(!output->takeEvent().has_value());
  const auto consumed = output->facts();
  EXPECT(!consumed.admittedFrame.valid());
  EXPECT(!consumed.eventPending);
  EXPECT(consumed.drawnFrames == 1);
  EXPECT(consumed.supersededFrames == 0);
  // The capacity credit returns with the terminal event. The lease itself
  // outlives it by design and is retired one enqueue later, while the renderer
  // may still be displaying it (case 8 proves that against the budget).
  EXPECT(consumed.retainedFrames == 0);
  EXPECT(output->capacity(1) == NativeTrackedVideoCapacity::Available);

  const FrameTiming secondTiming = makeTiming(1, 1);
  auto second = makeFrame(1, 1, 170);
  EXPECT(output->submit(second, NativeTrackedFrameSequence{2}, &error) ==
            NativeTrackedVideoSubmitStatus::Accepted);
  const auto secondDrawn = output->takeEvent();
  REQUIRE(secondDrawn.has_value());
  EXPECT(secondDrawn->kind == NativeTrackedVideoEventKind::FrameDrawn);
  // The event identity is output-owned and strictly increasing; the frame
  // identity is echoed exactly as the caller minted it.
  EXPECT(secondDrawn->eventSequence == drawn->eventSequence + 1);
  EXPECT(secondDrawn->frameSequence.value == 2);
  EXPECT(sameFrameTiming(secondDrawn->timing, secondTiming));
  EXPECT(!sameExactCMTime(secondTiming.presentationTime,
                             firstTiming.presentationTime));

  // A malformed submission is refused without disturbing the admission state.
  {
    FrameLease empty;
    EXPECT(output->submit(empty, NativeTrackedFrameSequence{3}, &error) ==
              NativeTrackedVideoSubmitStatus::Failed);
    auto valid = makeFrame(1, 2, 180);
    EXPECT(output->submit(valid, NativeTrackedFrameSequence{0}, &error) ==
              NativeTrackedVideoSubmitStatus::Failed);
  }
  EXPECT(!output->facts().fatal);
  EXPECT(output->facts().submittedFrames == 2);

  // No metrics load can have been issued at this submit count, which is what
  // makes "every terminal event is FrameDrawn" a fact and not an assumption.
  const auto health = output->health();
  EXPECT(health.enqueuedFrames == 2);
  EXPECT(health.drawnFrames == 2);
  EXPECT(health.supersededByDropFrames == 0);
  EXPECT(health.metricsLoads == 0);
  EXPECT(health.metricsUnavailable == 0);
  EXPECT(health.peakRetainedLeases ==
            NativeLayerVideoOutput::kRetainedFrameLeaseCeiling);

  closeAndDrop(std::move(output), 2);
}

// ------------------------------------------------------------------- case 5

// A repeated or regressed caller sequence is a fatal contract breach, and a
// fatally failed presenter must still close.
void verifySequenceRegressionIsFatalAndStillCloses() {
  std::atomic<std::uint64_t> wakes{0};
  auto output = createDetached(&wakes);
  std::string error;
  armFirstGeneration(*output);

  {
    auto first = makeFrame(1, 0, 150);
    EXPECT(output->submit(first, NativeTrackedFrameSequence{7}, &error) ==
              NativeTrackedVideoSubmitStatus::Accepted);
  }
  const auto drawn = output->takeEvent();
  REQUIRE(drawn.has_value());
  EXPECT(drawn->kind == NativeTrackedVideoEventKind::FrameDrawn);
  EXPECT(!output->facts().fatal);

  {
    auto repeated = makeFrame(1, 1, 151);
    EXPECT(output->submit(repeated, NativeTrackedFrameSequence{7},
                             &error) == NativeTrackedVideoSubmitStatus::Failed);
    WAM_CHECK_DETAIL(error.find("sequence") != std::string::npos, error);
  }
  const auto failed = output->facts();
  EXPECT(failed.fatal);
  EXPECT(failed.submittedFrames == 1);
  EXPECT(!failed.eventPending);
  EXPECT(output->capacity(1) == NativeTrackedVideoCapacity::Failed);
  {
    auto later = makeFrame(1, 2, 152);
    EXPECT(output->submit(later, NativeTrackedFrameSequence{9}, &error) ==
              NativeTrackedVideoSubmitStatus::Failed);
  }
  EXPECT(output->flushProgress(1, 2) ==
            NativeTrackedVideoOutputProgress::Failed);

  // Terminal teardown is the one lifecycle operation a latched failure must not
  // block; otherwise a failed route could never be released.
  closeAndDrop(std::move(output), 2);
}

// ------------------------------------------------------------------- case 6

// flushProgress(): Quiescing until the terminal fact is consumed and the
// renderer acknowledges its flush, then Done, then the retired generation is
// refused while the new one is live.
void verifyFlushProgressRetiresGeneration() {
  std::atomic<std::uint64_t> wakes{0};
  auto output = createDetached(&wakes);
  std::string error;
  armFirstGeneration(*output);

  {
    auto admitted = makeFrame(1, 0, 190);
    EXPECT(output->submit(admitted, NativeTrackedFrameSequence{1},
                             &error) == NativeTrackedVideoSubmitStatus::Accepted);
  }
  EXPECT(output->facts().eventPending);
  EXPECT(output->facts().retainedFrames == 1);

  // A next generation that is not strictly newer is a caller defect.
  EXPECT(output->flushProgress(1, 1) ==
            NativeTrackedVideoOutputProgress::Failed);
  EXPECT(output->flushProgress(1, 0) ==
            NativeTrackedVideoOutputProgress::Failed);
  // A retired generation that is not the one actually accepted is refused
  // before any flush is issued.
  EXPECT(output->flushProgress(5, 6) ==
            NativeTrackedVideoOutputProgress::StaleGeneration);
  EXPECT(!output->facts().invalidationPending);

  const std::uint64_t wakesBeforeFlush = wakes.load(std::memory_order_acquire);
  EXPECT(output->flushProgress(1, 2) ==
            NativeTrackedVideoOutputProgress::Quiescing);
  const auto flushing = output->facts();
  EXPECT(flushing.invalidationPending);
  EXPECT(flushing.eventPending);
  // The new generation is armed the instant the flush starts; the old one is
  // dead to submit() from that same instant.
  EXPECT(flushing.generation == 2);
  EXPECT(output->capacity(1) ==
            NativeTrackedVideoCapacity::StaleGeneration);
  EXPECT(output->capacity(2) == NativeTrackedVideoCapacity::Backpressure);
  {
    auto retired = makeFrame(1, 1, 191);
    EXPECT(output->submit(retired, NativeTrackedFrameSequence{2}, &error) ==
              NativeTrackedVideoSubmitStatus::StaleGeneration);
    auto next = makeFrame(2, 0, 192);
    EXPECT(output->submit(next, NativeTrackedFrameSequence{2}, &error) ==
              NativeTrackedVideoSubmitStatus::Backpressure);
  }
  EXPECT(output->facts().submittedFrames == 1);

  // An unconsumed terminal fact is never overwritten by a flush, and the flush
  // cannot report Done while it is outstanding. Repeating the exact pair is
  // legal and must keep reporting Quiescing.
  pumpFor(120);
  EXPECT(output->flushProgress(1, 2) ==
            NativeTrackedVideoOutputProgress::Quiescing);
  // A different pair mid-flush is a controller defect, not a new flush.
  EXPECT(output->flushProgress(1, 3) ==
            NativeTrackedVideoOutputProgress::StaleGeneration);
  EXPECT(output->flushProgress(2, 3) ==
            NativeTrackedVideoOutputProgress::StaleGeneration);

  const auto terminal = output->takeEvent();
  REQUIRE(terminal.has_value());
  // The frame was admitted, enqueued, and taken by the renderer before the
  // flush was issued, so its proof stands and echoes the generation it was
  // submitted under, not the generation just armed.
  EXPECT(terminal->kind == NativeTrackedVideoEventKind::FrameDrawn);
  EXPECT(terminal->frameSequence.value == 1);
  EXPECT(terminal->generation == 1);
  EXPECT(sameFrameTiming(terminal->timing, makeTiming(1, 0)));

  EXPECT(spinUntil([&] {
    return output->flushProgress(1, 2) ==
           NativeTrackedVideoOutputProgress::Done;
  }));
  const auto flushed = output->facts();
  EXPECT(flushed.generation == 2);
  EXPECT(!flushed.invalidationPending);
  EXPECT(!flushed.eventPending);
  // A completed renderer flush proves it holds nothing of ours, so both leases
  // are released rather than waiting for a successor enqueue.
  EXPECT(flushed.retainedFrames == 0);
  EXPECT(!flushed.fatal);
  EXPECT(output->health().flushes == 2);
  EXPECT(wakes.load(std::memory_order_acquire) > wakesBeforeFlush);

  // Done is repeatable for the exact pair, and only for that pair.
  EXPECT(output->flushProgress(1, 2) ==
            NativeTrackedVideoOutputProgress::Done);
  EXPECT(output->flushProgress(0, 5) ==
            NativeTrackedVideoOutputProgress::StaleGeneration);
  EXPECT(output->capacity(2) == NativeTrackedVideoCapacity::Available);

  // Frames from the retired generation produce no event on the new one.
  {
    auto retired = makeFrame(1, 2, 193);
    EXPECT(output->submit(retired, NativeTrackedFrameSequence{2}, &error) ==
              NativeTrackedVideoSubmitStatus::StaleGeneration);
  }
  REQUIRE(!output->takeEvent().has_value());
  EXPECT(output->facts().submittedFrames == 1);

  // The new generation is fully live: it admits, draws, and echoes its own
  // generation. The caller sequence keeps climbing across the flush boundary.
  {
    auto next = makeFrame(2, 0, 194);
    EXPECT(output->submit(next, NativeTrackedFrameSequence{2}, &error) ==
              NativeTrackedVideoSubmitStatus::Accepted);
  }
  const auto afterFlush = output->takeEvent();
  REQUIRE(afterFlush.has_value());
  EXPECT(afterFlush->kind == NativeTrackedVideoEventKind::FrameDrawn);
  EXPECT(afterFlush->frameSequence.value == 2);
  EXPECT(afterFlush->generation == 2);
  EXPECT(afterFlush->eventSequence == terminal->eventSequence + 1);
  EXPECT(output->health().metricsLoads == 0);

  closeAndDrop(std::move(output), 3);
}

// ------------------------------------------------------------------- case 7

// closeProgress(): the least-exercised path on the layer route. Terminal
// invalidation is proved by the renderer's own
// flushWithRemovalOfDisplayedImage:YES completion, the wake gate is closed and
// drained before the seam is released, and Done is repeatable for exactly one
// final generation.
void verifyCloseProgressIsTerminal() {
  std::atomic<std::uint64_t> wakes{0};
  auto output = createDetached(&wakes);
  std::string error;
  armFirstGeneration(*output);

  // Zero is never a final generation, and a final generation must be strictly
  // newer than the accepted one.
  EXPECT(output->closeProgress(0) ==
            NativeTrackedVideoOutputProgress::Failed);
  EXPECT(output->closeProgress(1) ==
            NativeTrackedVideoOutputProgress::Failed);
  EXPECT(!output->facts().invalidationPending);
  EXPECT(!output->facts().closed);

  {
    auto admitted = makeFrame(1, 0, 200);
    EXPECT(output->submit(admitted, NativeTrackedFrameSequence{1},
                             &error) == NativeTrackedVideoSubmitStatus::Accepted);
  }
  EXPECT(output->facts().eventPending);
  EXPECT(output->facts().retainedFrames == 1);
  const std::uint64_t wakesBeforeClose = wakes.load(std::memory_order_acquire);

  EXPECT(output->closeProgress(2) ==
            NativeTrackedVideoOutputProgress::Quiescing);
  const auto closing = output->facts();
  EXPECT(closing.invalidationPending);
  EXPECT(closing.eventPending);
  EXPECT(!closing.closed);

  // Close is a hard gate on admission from the instant it is requested, even
  // before it completes.
  EXPECT(output->capacity(1) == NativeTrackedVideoCapacity::Failed);
  EXPECT(output->capacity(2) == NativeTrackedVideoCapacity::Failed);
  {
    auto rejected = makeFrame(1, 1, 201);
    EXPECT(output->submit(rejected, NativeTrackedFrameSequence{2},
                             &error) == NativeTrackedVideoSubmitStatus::Failed);
  }
  EXPECT(output->flushProgress(1, 2) ==
            NativeTrackedVideoOutputProgress::Failed);
  EXPECT(output->flushProgress(2, 3) ==
            NativeTrackedVideoOutputProgress::Failed);
  // Close is repeatable for one exact final generation, and only that one.
  EXPECT(output->closeProgress(3) ==
            NativeTrackedVideoOutputProgress::StaleGeneration);

  // The pending terminal fact must survive the close request: closing the route
  // may not swallow a proof the owner has not yet consumed. Done cannot be
  // reported while it is outstanding, however long the renderer takes.
  pumpFor(150);
  EXPECT(output->closeProgress(2) ==
            NativeTrackedVideoOutputProgress::Quiescing);
  EXPECT(output->facts().eventPending);
  const auto pending = output->takeEvent();
  REQUIRE(pending.has_value());
  EXPECT(pending->kind == NativeTrackedVideoEventKind::FrameDrawn);
  EXPECT(pending->frameSequence.value == 1);
  EXPECT(pending->generation == 1);
  EXPECT(sameFrameTiming(pending->timing, makeTiming(1, 0)));

  EXPECT(spinUntil([&] {
    return output->closeProgress(2) == NativeTrackedVideoOutputProgress::Done;
  }));

  const auto closed = output->facts();
  EXPECT(closed.closed);
  EXPECT(!closed.eventPending);
  EXPECT(!closed.invalidationPending);
  EXPECT(!closed.fatal);
  // Terminal invalidation releases every lease the presenter held.
  EXPECT(closed.retainedFrames == 0);
  EXPECT(closed.drawnFrames == 1);
  EXPECT(closed.supersededFrames == 0);
  // NativeVideoConsumer::retire() gates terminal retirement on
  // `outputFacts.generation == invalidationGeneration`, so an output that did
  // not advance acceptedGeneration during close could never retire ("Native
  // playback could not retire safely" on a warm file replacement).
  // closeProgress() moves the output onto the invalidation generation exactly
  // as flushProgress() moves it onto the flush target, and exactly as
  // NativeQtGlOutput does.
  EXPECT(closed.generation == 2);

  // Restate that as the exact predicate the owner applies, so a future change
  // to any single fact here fails at the boundary that actually consumes them
  // rather than only at whichever one this test happened to spell out. This is
  // the conjunction in NativeVideoConsumer::retire()'s post-close gate.
  EXPECT(!(closed.fatal || !closed.closed ||
              closed.generation != 2 || closed.admittedFrame.valid() ||
              closed.retainedFrames != 0 || closed.invalidationPending));

  // The renderer's flush completion is the terminal invalidation proof, and it
  // signals the wake seam on its way through.
  EXPECT(wakes.load(std::memory_order_acquire) > wakesBeforeClose);

  // Done is repeatable for the exact final generation and refuses any other,
  // so a retrying owner cannot be told "not yet" forever or "done" for the
  // wrong generation.
  EXPECT(output->closeProgress(2) ==
            NativeTrackedVideoOutputProgress::Done);
  EXPECT(output->closeProgress(4) ==
            NativeTrackedVideoOutputProgress::StaleGeneration);

  // The wake gate is closed and drained before Done, and the seam is released.
  // Nothing may signal it afterwards; the owner is now free to destroy the raw
  // wake context.
  const std::uint64_t wakesAfterClose = wakes.load(std::memory_order_acquire);
  pumpFor(150);
  EXPECT(wakes.load(std::memory_order_acquire) == wakesAfterClose);

  // Nothing survives the close.
  REQUIRE(!output->takeEvent().has_value());
  EXPECT(output->capacity(2) == NativeTrackedVideoCapacity::Failed);
  EXPECT(output->flushProgress(2, 3) ==
            NativeTrackedVideoOutputProgress::Failed);
  {
    auto rejected = makeFrame(1, 2, 202);
    EXPECT(output->submit(rejected, NativeTrackedFrameSequence{5},
                             &error) == NativeTrackedVideoSubmitStatus::Failed);
  }
  // The Qt video item's per-frame update must be restored the moment the route
  // stops presenting, so a libmpv fallback still paints.
  EXPECT(!nativeLayerPresentationActive());

  output.reset();
  EXPECT(!nativeLayerPresentationActive());
}

// closeProgress() overtaking an in-flight flushProgress(). The route can be
// torn down mid-seek, and the terminal invalidation must subsume the
// generation flush rather than deadlocking behind it.
void verifyCloseSupersedesPendingFlush() {
  std::atomic<std::uint64_t> wakes{0};
  auto output = createDetached(&wakes);
  std::string error;
  armFirstGeneration(*output);

  {
    auto admitted = makeFrame(1, 0, 210);
    EXPECT(output->submit(admitted, NativeTrackedFrameSequence{1},
                             &error) == NativeTrackedVideoSubmitStatus::Accepted);
  }
  const auto drawn = output->takeEvent();
  REQUIRE(drawn.has_value());
  EXPECT(drawn->kind == NativeTrackedVideoEventKind::FrameDrawn);

  // The renderer may acknowledge this flush before the call even returns, so
  // both outcomes are legal here. Only the close below is asserted exactly.
  const auto flushStarted = output->flushProgress(1, 2);
  EXPECT(flushStarted == NativeTrackedVideoOutputProgress::Quiescing ||
            flushStarted == NativeTrackedVideoOutputProgress::Done);

  const auto closeStarted = output->closeProgress(3);
  EXPECT(closeStarted == NativeTrackedVideoOutputProgress::Quiescing ||
            closeStarted == NativeTrackedVideoOutputProgress::Done);
  EXPECT(spinUntil([&] {
    return output->closeProgress(3) == NativeTrackedVideoOutputProgress::Done;
  }));

  const auto closed = output->facts();
  EXPECT(closed.closed);
  EXPECT(!closed.invalidationPending);
  EXPECT(!closed.eventPending);
  EXPECT(closed.retainedFrames == 0);
  // The superseded flush leaves no residue that could report Done later.
  EXPECT(output->flushProgress(1, 2) ==
            NativeTrackedVideoOutputProgress::Failed);

  output.reset();
  EXPECT(!nativeLayerPresentationActive());
}

// ------------------------------------------------------------------- case 8

// The presenter holds at most kRetainedFrameLeaseCeiling leases in steady
// state, and those leases are really released, not merely uncounted. The
// surface budget is the independent witness: it charges one unique IOSurface
// per live lease process-wide, so its count is the fact about retention.
void verifyRetainedLeaseCeilingAndRelease() {
  const auto baseline = NativeSurfaceBudget::stats();
  std::atomic<std::uint64_t> wakes{0};
  auto output = createDetached(&wakes);
  std::string error;
  armFirstGeneration(*output);

  std::uint64_t previousEventSequence = 0;
  constexpr std::uint64_t kFrames = 5;
  for (std::uint64_t index = 1; index <= kFrames; ++index) {
    {
      // The caller's lease is the sole delivery owner until submit returns
      // Accepted, and is dropped immediately afterwards. Everything the budget
      // still charges from here on belongs to the presenter alone.
      auto frame = makeFrame(1, static_cast<std::int64_t>(index - 1),
                             static_cast<std::uint8_t>(120 + index));
      EXPECT(output->submit(frame, NativeTrackedFrameSequence{index},
                               &error) ==
                NativeTrackedVideoSubmitStatus::Accepted);
    }

    const auto event = output->takeEvent();
    REQUIRE(event.has_value());
    // Exactly one terminal event per accepted submit, of exactly one kind.
    EXPECT(event->kind == NativeTrackedVideoEventKind::FrameDrawn ||
              event->kind == NativeTrackedVideoEventKind::FrameSuperseded);
    EXPECT(event->frameSequence.value == index);
    EXPECT(event->eventSequence > previousEventSequence);
    previousEventSequence = event->eventSequence;
    REQUIRE(!output->takeEvent().has_value());

    const auto facts = output->facts();
    EXPECT(facts.submittedFrames == index);
    EXPECT(facts.drawnFrames + facts.supersededFrames == index);
    // One lease for the latest frame, one for the predecessor the renderer
    // may still be displaying. Never a third.
    const std::size_t leases = index == 1 ? 1U : 2U;
    EXPECT(leases <= NativeLayerVideoOutput::kRetainedFrameLeaseCeiling);
    EXPECT(facts.retainedFrames == 0);
    EXPECT(NativeSurfaceBudget::stats().currentSurfaces ==
              baseline.currentSurfaces + leases);
  }
  EXPECT(output->health().peakRetainedLeases ==
            NativeLayerVideoOutput::kRetainedFrameLeaseCeiling);
  EXPECT(output->health().enqueuedFrames == kFrames);
  EXPECT(output->health().metricsLoads == 0);

  // A completed flush retires both leases, and the budget must see the
  // IOSurfaces come back.
  EXPECT(spinUntil([&] {
    return output->flushProgress(1, 2) ==
           NativeTrackedVideoOutputProgress::Done;
  }));
  EXPECT(output->facts().retainedFrames == 0);
  EXPECT(NativeSurfaceBudget::stats().currentSurfaces ==
            baseline.currentSurfaces);

  // And so does a close that happens while leases are still held.
  {
    auto frame = makeFrame(2, 0, 220);
    EXPECT(output->submit(frame, NativeTrackedFrameSequence{kFrames + 1},
                             &error) ==
              NativeTrackedVideoSubmitStatus::Accepted);
  }
  REQUIRE(output->takeEvent().has_value());
  EXPECT(output->facts().retainedFrames == 0);
  EXPECT(NativeSurfaceBudget::stats().currentSurfaces ==
            baseline.currentSurfaces + 1);

  closeAndDrop(std::move(output), 3);
  EXPECT(NativeSurfaceBudget::stats().currentSurfaces ==
            baseline.currentSurfaces);
  EXPECT(NativeSurfaceBudget::stats().peakSurfaces >=
            baseline.currentSurfaces +
                NativeLayerVideoOutput::kRetainedFrameLeaseCeiling);
}

// A frame that BEGINS before the movie origin but ENDS after it is the frame
// visible at time zero, and this route must present it.
//
// An ISO-BMFF head trim (elst media_time > 0) makes the reader walk back to a
// RAP, so when the trim does not land exactly on a frame boundary the picture
// covering movie time zero carries a NEGATIVE movie stamp. The consumer models
// this deliberately -- it retires by the presentation floor, not by sign, and
// submits the straddling frame, so this output must not reject a negative
// presentation time outright (the scene-graph route has no sign check either).
//
// The contract proved here: a straddling frame is ACCEPTED, a frame that ends
// at or before the origin is still REFUSED (it is genuinely never visible), and
// the echoed terminal timing is the frame's own unmodified timing -- the clamp
// applies only to the buffer handed to the renderer, never to the accounting
// the draw proof is matched against.
void verifyStraddlingFrameIsPresentedAndEchoedExactly() {
  const auto baseline = NativeSurfaceBudget::stats();
  std::atomic<std::uint64_t> wakes{0};
  auto output = createDetached(&wakes);
  std::string error;
  armFirstGeneration(*output);
  EXPECT(output->capacity(1) == NativeTrackedVideoCapacity::Available);

  // Ends exactly at the origin: never visible, still refused.
  {
    FrameTiming timing;
    timing.presentationTime = CMTimeMake(-1001, 30000);
    timing.duration = CMTimeMake(1001, 30000);
    timing.generation = 1;
    timing.keyFrame = true;
    CVPixelBufferRef buffer = createSolidNv12(90);
    REQUIRE(buffer != nullptr);
    FrameLease before(buffer, timing);
    CVPixelBufferRelease(buffer);
    error.clear();
    EXPECT(output->submit(before, NativeTrackedFrameSequence{1}, &error) ==
              NativeTrackedVideoSubmitStatus::Failed);
    REQUIRE(!error.empty());
  }

  // Straddles the origin: accepted, and echoed with its own exact timing.
  FrameTiming straddling;
  straddling.presentationTime = CMTimeMake(-500, 30000);
  straddling.duration = CMTimeMake(1001, 30000);
  straddling.generation = 1;
  straddling.keyFrame = true;
  {
    CVPixelBufferRef buffer = createSolidNv12(120);
    REQUIRE(buffer != nullptr);
    FrameLease frame(buffer, straddling);
    CVPixelBufferRelease(buffer);
    REQUIRE(static_cast<bool>(frame));
    error.clear();
    WAM_CHECK_DETAIL(
        output->submit(frame, NativeTrackedFrameSequence{2}, &error) ==
            NativeTrackedVideoSubmitStatus::Accepted,
        error);
  }
  const auto event = output->takeEvent();
  REQUIRE(event.has_value());
  if (event) {
    EXPECT(event->kind == NativeTrackedVideoEventKind::FrameDrawn);
    // The negative stamp survives into the accounting unmodified.
    EXPECT(CMTimeCompare(event->timing.presentationTime,
                            straddling.presentationTime) == 0);
    EXPECT(CMTimeCompare(event->timing.duration, straddling.duration) == 0);
  }

  closeAndDrop(std::move(output), 2);
  EXPECT(NativeSurfaceBudget::stats().currentSurfaces ==
            baseline.currentSurfaces);
}

// The one presentability rule every tracked output asks: exact timing, a
// positive duration, and an END after the origin. Sign of the start is not
// part of it.
void verifyFrameTimingPresentableRule() {
  FrameTiming timing;
  timing.generation = 1;
  timing.duration = CMTimeMake(1001, 30000);

  timing.presentationTime = CMTimeMake(-500, 30000);
  EXPECT(frameTimingPresentable(timing));
  timing.presentationTime = CMTimeMake(0, 30000);
  EXPECT(frameTimingPresentable(timing));
  timing.presentationTime = CMTimeMake(-1001, 30000);
  EXPECT(!frameTimingPresentable(timing));
  timing.presentationTime = CMTimeMake(-2000, 30000);
  EXPECT(!frameTimingPresentable(timing));

  timing.presentationTime = CMTimeMake(500, 30000);
  timing.duration = CMTimeMake(0, 30000);
  EXPECT(!frameTimingPresentable(timing));
  timing.duration = kCMTimeInvalid;
  EXPECT(!frameTimingPresentable(timing));
  timing.duration = CMTimeMake(1001, 30000);
  timing.generation = 0;
  EXPECT(!frameTimingPresentable(timing));
  timing.generation = 1;
  // A start and a duration on incommensurable timescales round when added;
  // a rounded end is not an exact end and is refused.
  timing.presentationTime = CMTimeMake(-1, 1'000'000'007);
  timing.duration = CMTimeMake(1, 30000);
  EXPECT(!frameTimingPresentable(timing));
}

// The one rotation classifier: the four exact matrices on the linear part,
// translation ignored; mirrors, shears, near-misses and non-finite matrices
// refused. Then the layer setter round-trips through the same rule.
void verifyQuarterTurnClassifierAndLayerRotation() {
  EXPECT(quarterTurnDegrees(CGAffineTransformIdentity) == 0);
  EXPECT(quarterTurnDegrees(CGAffineTransformMake(0, 1, -1, 0, 1080, 0)) ==
            90);
  EXPECT(quarterTurnDegrees(CGAffineTransformMake(-1, 0, 0, -1, 1920,
                                                     1080)) == 180);
  EXPECT(quarterTurnDegrees(CGAffineTransformMake(0, -1, 1, 0, 0, 1920)) ==
            270);
  // A horizontal mirror has a negative determinant and is not a turn.
  EXPECT(!quarterTurnDegrees(CGAffineTransformMake(-1, 0, 0, 1, 0, 0)));
  // A matrix merely near a quarter turn is a shear, refused exactly.
  EXPECT(!quarterTurnDegrees(
      CGAffineTransformMake(0.0001, 1, -1, 0, 0, 0)));
  EXPECT(!quarterTurnDegrees(CGAffineTransformMakeRotation(0.5)));
  EXPECT(!quarterTurnDegrees(
      CGAffineTransformMake(1, 0, 0, 1, std::nan(""), 0)));

  EXPECT(normalizedQuarterTurn(-90) == 270);
  EXPECT(normalizedQuarterTurn(450) == 90);
  EXPECT(normalizedQuarterTurn(360) == 0);
  EXPECT(!normalizedQuarterTurn(45));

  wam::media::MediaVideoFormat video;
  video.rotationDegrees = 90;
  video.identityTransform = false;
  EXPECT(quarterTurnRotationAdmitted(video));
  video.identityTransform = true;
  EXPECT(!quarterTurnRotationAdmitted(video));
  video.rotationDegrees = 0;
  EXPECT(quarterTurnRotationAdmitted(video));
  video.identityTransform = false;
  EXPECT(!quarterTurnRotationAdmitted(video));
  video.rotationDegrees = 30;
  EXPECT(!quarterTurnRotationAdmitted(video));

  CALayer* layer = [CALayer layer];
  void* handle = (__bridge void*)layer;
  EXPECT(nativeLayerPresentationRotation(handle) == 0);
  EXPECT(setNativeLayerPresentationRotation(handle, 90));
  EXPECT(nativeLayerPresentationRotation(handle) == 90);
  EXPECT(setNativeLayerPresentationRotation(handle, -90));
  EXPECT(nativeLayerPresentationRotation(handle) == 270);
  // A refused angle leaves the previous rotation in place.
  EXPECT(!setNativeLayerPresentationRotation(handle, 45));
  EXPECT(nativeLayerPresentationRotation(handle) == 270);
  EXPECT(setNativeLayerPresentationRotation(handle, 360));
  EXPECT(nativeLayerPresentationRotation(handle) == 0);
  REQUIRE(!setNativeLayerPresentationRotation(nullptr, 90));
}

}  // namespace

void verifyAutomaticDynamicRange() {
  if (@available(macOS 26.0, *)) {
    [NSApplication sharedApplication];
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,320,180)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    std::string error;
    auto host = wam::macos::NativeLayerHostView::create((__bridge void*)window.contentView, &error);
    WAM_REQUIRE_DETAIL(host != nullptr, error);
    CALayer* layer = (__bridge CALayer*)host->displayLayer();
    void* symbol = dlsym(RTLD_DEFAULT, "CADynamicRangeAutomatic");
    REQUIRE(symbol != nullptr);
    NSString* automatic = (__bridge NSString*)*static_cast<void**>(symbol);
    EXPECT([[layer valueForKey:@"preferredDynamicRange"] isEqual:automatic]);
    EXPECT(layer.filters.count == 0);
    host->detach();
    [window close];
  }
}

// Geometry arrives on the session worker while the main queue lays out the
// same layer. Replacing a nonatomic associated NSValue can free it between
// objc_getAssociatedObject and the reader's retain.
void verifyConcurrentDisplayMetadata() {
  CALayer* layer = [CALayer layer];
  void* handle = (__bridge void*)layer;
  const wam::media::MediaDisplaySize size{{640, 1}, {360, 1}};
  EXPECT(setNativeLayerPresentationDisplaySize(handle, size));
  std::atomic<bool> finished{false};
  std::thread writer([&] {
    for (int i = 0; i < 20000; ++i) {
      @autoreleasepool {
        EXPECT(setNativeLayerPresentationDisplaySize(handle, size));
      }
    }
    finished.store(true, std::memory_order_release);
  });
  while (!finished.load(std::memory_order_acquire)) {
    @autoreleasepool {
      EXPECT(nativeLayerPresentationDisplaySize(handle) == size);
    }
  }
  writer.join();
}

int main() {
  if (@available(macOS 14.0, *)) {
  } else {
    // createTracked refuses below macOS 14 by design: there is no
    // sampleBufferRenderer, and the deprecated queue-management category is the
    // only alternative. Nothing here is testable on such a system.
    std::cout << "SKIP: layer presentation requires macOS 14 or newer\n";
    return 77;
  }

  @autoreleasepool {
    verifyConcurrentDisplayMetadata();
    verifyAutomaticDynamicRange();
    verifyDetachedConstructionAndActivation();
    verifyCapacityOneAdmissionAndExactTimingEcho();
    verifySequenceRegressionIsFatalAndStillCloses();
    verifyFlushProgressRetiresGeneration();
    verifyCloseProgressIsTerminal();
    verifyCloseSupersedesPendingFlush();
    verifyRetainedLeaseCeilingAndRelease();
    verifyStraddlingFrameIsPresentedAndEchoedExactly();
    verifyFrameTimingPresentableRule();
    verifyQuarterTurnClassifierAndLayerRotation();
  }

  if (failures != 0) {
    return EXIT_FAILURE;
  }
  std::cout << "native layer video output contract tests passed\n";
  return EXIT_SUCCESS;
}
