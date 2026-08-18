#include "platform/macos/native_layer_video_output.hpp"

#include "platform/macos/native_layer_presentation_state.hpp"
#include "platform/macos/native_surface_budget.hpp"
#include "platform/macos/native_tracked_video_output.hpp"
#include "platform/macos/native_video_presenter.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

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

void check(bool condition, const char* expression, int line,
           const std::string& detail = {}) {
  if (condition) {
    return;
  }
  std::cerr << "CHECK failed at line " << line << ": " << expression;
  if (!detail.empty()) {
    std::cerr << " (" << detail << ')';
  }
  std::cerr << '\n';
  std::exit(EXIT_FAILURE);
}

#define WAM_CHECK(expression)                                                  \
  check(static_cast<bool>(expression), #expression, __LINE__)
#define WAM_CHECK_DETAIL(expression, detail)                                   \
  check(static_cast<bool>(expression), #expression, __LINE__, (detail))

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

// Exact CMTime identity, not CMTimeCompare equivalence. The contract's timing
// echo claim is bit-for-bit restatement, so a rescaled-but-equal time is a
// failure, not a pass.
[[nodiscard]] bool sameCMTime(CMTime left, CMTime right) noexcept {
  return left.value == right.value && left.timescale == right.timescale &&
         left.flags == right.flags && left.epoch == right.epoch;
}

[[nodiscard]] bool sameTiming(const FrameTiming& left,
                              const FrameTiming& right) noexcept {
  return sameCMTime(left.presentationTime, right.presentationTime) &&
         sameCMTime(left.duration, right.duration) &&
         left.generation == right.generation && left.keyFrame == right.keyFrame;
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
  WAM_CHECK(buffer != nullptr);
  FrameLease frame(buffer, makeTiming(generation, frameIndex));
  CVPixelBufferRelease(buffer);
  WAM_CHECK(static_cast<bool>(frame));
  WAM_CHECK(frame.isIOSurfaceBacked());
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
  WAM_CHECK_DETAIL(output != nullptr, error);
  WAM_CHECK(error.empty());
  return output;
}

// Terminal teardown shared by every case, so no test can leave the
// process-global presentation flag or the surface budget dirty for the next
// one. finalGeneration must be strictly newer than the accepted generation.
void closeAndDrop(std::shared_ptr<NativeLayerVideoOutput> output,
                  std::uint64_t finalGeneration) {
  WAM_CHECK(spinUntil([&] {
    return output->closeProgress(finalGeneration) ==
           NativeTrackedVideoOutputProgress::Done;
  }));
  WAM_CHECK(output->facts().closed);
  output.reset();
  WAM_CHECK(!nativeLayerPresentationActive());
}

// ---------------------------------------------------------------- case 1 + 2

// createTracked(nullptr, ...) builds its own detached layer, publishes the
// presentation flag, and refuses every submit until a generation is armed.
void verifyDetachedConstructionAndActivation() {
  WAM_CHECK(!nativeLayerPresentationActive());
  std::atomic<std::uint64_t> wakes{0};
  auto output = createDetached(&wakes);
  WAM_CHECK(nativeLayerPresentationActive());

  const auto initial = output->facts();
  WAM_CHECK(initial.generation == 0);
  WAM_CHECK(!initial.admittedFrame.valid());
  WAM_CHECK(initial.submittedFrames == 0);
  WAM_CHECK(initial.drawnFrames == 0);
  WAM_CHECK(initial.supersededFrames == 0);
  WAM_CHECK(initial.lastEventSequence == 0);
  WAM_CHECK(initial.retainedFrames == 0);
  WAM_CHECK(!initial.eventPending);
  WAM_CHECK(!initial.invalidationPending);
  WAM_CHECK(!initial.closed);
  WAM_CHECK(!initial.fatal);
  WAM_CHECK(!output->takeEvent().has_value());

  const auto initialHealth = output->health();
  WAM_CHECK(initialHealth.enqueuedFrames == 0);
  WAM_CHECK(initialHealth.drawnFrames == 0);
  WAM_CHECK(initialHealth.supersededByDropFrames == 0);
  WAM_CHECK(initialHealth.flushes == 0);
  WAM_CHECK(initialHealth.metricsLoads == 0);
  WAM_CHECK(initialHealth.peakRetainedLeases == 0);

  // Zero is never a generation, and nothing is accepted before startGeneration.
  WAM_CHECK(output->capacity(0) ==
            NativeTrackedVideoCapacity::StaleGeneration);
  WAM_CHECK(output->capacity(1) ==
            NativeTrackedVideoCapacity::StaleGeneration);
  {
    std::string error;
    auto premature = makeFrame(1, 0, 140);
    WAM_CHECK(output->submit(premature, NativeTrackedFrameSequence{1},
                             &error) ==
              NativeTrackedVideoSubmitStatus::StaleGeneration);
    WAM_CHECK(!error.empty());
  }

  std::string error;
  WAM_CHECK(!output->startGeneration(0, &error));
  WAM_CHECK(!error.empty());
  WAM_CHECK_DETAIL(output->startGeneration(1, &error), error);
  // Repeating a generation is a controller defect, not an idempotent no-op.
  WAM_CHECK(!output->startGeneration(1, &error));
  WAM_CHECK(output->capacity(1) == NativeTrackedVideoCapacity::Available);
  WAM_CHECK(output->capacity(2) ==
            NativeTrackedVideoCapacity::StaleGeneration);
  WAM_CHECK(output->facts().generation == 1);

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
  WAM_CHECK_DETAIL(output->startGeneration(1, &error), error);
  WAM_CHECK(output->capacity(1) == NativeTrackedVideoCapacity::Available);

  const FrameTiming firstTiming = makeTiming(1, 0);
  auto first = makeFrame(1, 0, 160);
  WAM_CHECK(sameTiming(first.timing(), firstTiming));
  WAM_CHECK(output->submit(first, NativeTrackedFrameSequence{1}, &error) ==
            NativeTrackedVideoSubmitStatus::Accepted);
  WAM_CHECK(error.empty());
  WAM_CHECK(wakes.load(std::memory_order_acquire) >= 1);

  const auto admitted = output->facts();
  WAM_CHECK(admitted.generation == 1);
  WAM_CHECK(admitted.admittedFrame.value == 1);
  WAM_CHECK(admitted.submittedFrames == 1);
  WAM_CHECK(admitted.drawnFrames == 1);
  WAM_CHECK(admitted.supersededFrames == 0);
  WAM_CHECK(admitted.lastEventSequence == 1);
  WAM_CHECK(admitted.retainedFrames == 1);
  WAM_CHECK(admitted.eventPending);
  WAM_CHECK(!admitted.invalidationPending);
  WAM_CHECK(!admitted.fatal);

  // Capacity one: the boundary is closed until the terminal fact is consumed.
  WAM_CHECK(output->capacity(1) == NativeTrackedVideoCapacity::Backpressure);
  {
    auto second = makeFrame(1, 1, 170);
    WAM_CHECK(output->submit(second, NativeTrackedFrameSequence{2}, &error) ==
              NativeTrackedVideoSubmitStatus::Backpressure);
  }
  WAM_CHECK(output->facts().submittedFrames == 1);

  const auto drawn = output->takeEvent();
  WAM_CHECK(drawn.has_value());
  WAM_CHECK(drawn->kind == NativeTrackedVideoEventKind::FrameDrawn);
  WAM_CHECK(drawn->eventSequence == 1);
  WAM_CHECK(drawn->frameSequence.value == 1);
  WAM_CHECK(drawn->generation == 1);
  // Bit-for-bit, not merely CMTimeCompare-equal.
  WAM_CHECK(sameTiming(drawn->timing, firstTiming));
  WAM_CHECK(CMTimeCompare(drawn->timing.presentationTime,
                          first.timing().presentationTime) == 0);

  // Exactly one terminal event: never both kinds, never a second copy.
  WAM_CHECK(!output->takeEvent().has_value());
  const auto consumed = output->facts();
  WAM_CHECK(!consumed.admittedFrame.valid());
  WAM_CHECK(!consumed.eventPending);
  WAM_CHECK(consumed.drawnFrames == 1);
  WAM_CHECK(consumed.supersededFrames == 0);
  // The admitted lease outlives its own terminal event by design; it is retired
  // one enqueue later, while the renderer may still be displaying it.
  WAM_CHECK(consumed.retainedFrames == 1);
  WAM_CHECK(output->capacity(1) == NativeTrackedVideoCapacity::Available);

  const FrameTiming secondTiming = makeTiming(1, 1);
  auto second = makeFrame(1, 1, 170);
  WAM_CHECK(output->submit(second, NativeTrackedFrameSequence{2}, &error) ==
            NativeTrackedVideoSubmitStatus::Accepted);
  const auto secondDrawn = output->takeEvent();
  WAM_CHECK(secondDrawn.has_value());
  WAM_CHECK(secondDrawn->kind == NativeTrackedVideoEventKind::FrameDrawn);
  // The event identity is output-owned and strictly increasing; the frame
  // identity is echoed exactly as the caller minted it.
  WAM_CHECK(secondDrawn->eventSequence == drawn->eventSequence + 1);
  WAM_CHECK(secondDrawn->frameSequence.value == 2);
  WAM_CHECK(sameTiming(secondDrawn->timing, secondTiming));
  WAM_CHECK(!sameCMTime(secondTiming.presentationTime,
                        firstTiming.presentationTime));

  // A malformed submission is refused without disturbing the admission state.
  {
    FrameLease empty;
    WAM_CHECK(output->submit(empty, NativeTrackedFrameSequence{3}, &error) ==
              NativeTrackedVideoSubmitStatus::Failed);
    auto valid = makeFrame(1, 2, 180);
    WAM_CHECK(output->submit(valid, NativeTrackedFrameSequence{0}, &error) ==
              NativeTrackedVideoSubmitStatus::Failed);
  }
  WAM_CHECK(!output->facts().fatal);
  WAM_CHECK(output->facts().submittedFrames == 2);

  // No metrics load can have been issued at this submit count, which is what
  // makes "every terminal event is FrameDrawn" a fact and not an assumption.
  const auto health = output->health();
  WAM_CHECK(health.enqueuedFrames == 2);
  WAM_CHECK(health.drawnFrames == 2);
  WAM_CHECK(health.supersededByDropFrames == 0);
  WAM_CHECK(health.metricsLoads == 0);
  WAM_CHECK(health.metricsUnavailable == 0);
  WAM_CHECK(health.peakRetainedLeases ==
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
  WAM_CHECK_DETAIL(output->startGeneration(1, &error), error);

  {
    auto first = makeFrame(1, 0, 150);
    WAM_CHECK(output->submit(first, NativeTrackedFrameSequence{7}, &error) ==
              NativeTrackedVideoSubmitStatus::Accepted);
  }
  const auto drawn = output->takeEvent();
  WAM_CHECK(drawn.has_value());
  WAM_CHECK(drawn->kind == NativeTrackedVideoEventKind::FrameDrawn);
  WAM_CHECK(!output->facts().fatal);

  {
    auto repeated = makeFrame(1, 1, 151);
    WAM_CHECK(output->submit(repeated, NativeTrackedFrameSequence{7},
                             &error) == NativeTrackedVideoSubmitStatus::Failed);
    WAM_CHECK_DETAIL(error.find("sequence") != std::string::npos, error);
  }
  const auto failed = output->facts();
  WAM_CHECK(failed.fatal);
  WAM_CHECK(failed.submittedFrames == 1);
  WAM_CHECK(!failed.eventPending);
  WAM_CHECK(output->capacity(1) == NativeTrackedVideoCapacity::Failed);
  {
    auto later = makeFrame(1, 2, 152);
    WAM_CHECK(output->submit(later, NativeTrackedFrameSequence{9}, &error) ==
              NativeTrackedVideoSubmitStatus::Failed);
  }
  WAM_CHECK(output->flushProgress(1, 2) ==
            NativeTrackedVideoOutputProgress::Failed);
  WAM_CHECK(!output->startGeneration(2, &error));

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
  WAM_CHECK_DETAIL(output->startGeneration(1, &error), error);

  {
    auto admitted = makeFrame(1, 0, 190);
    WAM_CHECK(output->submit(admitted, NativeTrackedFrameSequence{1},
                             &error) == NativeTrackedVideoSubmitStatus::Accepted);
  }
  WAM_CHECK(output->facts().eventPending);
  WAM_CHECK(output->facts().retainedFrames == 1);

  // A next generation that is not strictly newer is a caller defect.
  WAM_CHECK(output->flushProgress(1, 1) ==
            NativeTrackedVideoOutputProgress::Failed);
  WAM_CHECK(output->flushProgress(1, 0) ==
            NativeTrackedVideoOutputProgress::Failed);
  // A retired generation that is not the one actually accepted is refused
  // before any flush is issued.
  WAM_CHECK(output->flushProgress(5, 6) ==
            NativeTrackedVideoOutputProgress::StaleGeneration);
  WAM_CHECK(!output->facts().invalidationPending);

  const std::uint64_t wakesBeforeFlush = wakes.load(std::memory_order_acquire);
  WAM_CHECK(output->flushProgress(1, 2) ==
            NativeTrackedVideoOutputProgress::Quiescing);
  const auto flushing = output->facts();
  WAM_CHECK(flushing.invalidationPending);
  WAM_CHECK(flushing.eventPending);
  // The new generation is armed the instant the flush starts; the old one is
  // dead to submit() from that same instant.
  WAM_CHECK(flushing.generation == 2);
  WAM_CHECK(output->capacity(1) ==
            NativeTrackedVideoCapacity::StaleGeneration);
  WAM_CHECK(output->capacity(2) == NativeTrackedVideoCapacity::Backpressure);
  {
    auto retired = makeFrame(1, 1, 191);
    WAM_CHECK(output->submit(retired, NativeTrackedFrameSequence{2}, &error) ==
              NativeTrackedVideoSubmitStatus::StaleGeneration);
    auto next = makeFrame(2, 0, 192);
    WAM_CHECK(output->submit(next, NativeTrackedFrameSequence{2}, &error) ==
              NativeTrackedVideoSubmitStatus::Backpressure);
  }
  WAM_CHECK(output->facts().submittedFrames == 1);

  // An unconsumed terminal fact is never overwritten by a flush, and the flush
  // cannot report Done while it is outstanding. Repeating the exact pair is
  // legal and must keep reporting Quiescing.
  pumpFor(120);
  WAM_CHECK(output->flushProgress(1, 2) ==
            NativeTrackedVideoOutputProgress::Quiescing);
  // A different pair mid-flush is a controller defect, not a new flush.
  WAM_CHECK(output->flushProgress(1, 3) ==
            NativeTrackedVideoOutputProgress::StaleGeneration);
  WAM_CHECK(output->flushProgress(2, 3) ==
            NativeTrackedVideoOutputProgress::StaleGeneration);

  const auto terminal = output->takeEvent();
  WAM_CHECK(terminal.has_value());
  // The frame was admitted, enqueued, and taken by the renderer before the
  // flush was issued, so its proof stands and echoes the generation it was
  // submitted under, not the generation just armed.
  WAM_CHECK(terminal->kind == NativeTrackedVideoEventKind::FrameDrawn);
  WAM_CHECK(terminal->frameSequence.value == 1);
  WAM_CHECK(terminal->generation == 1);
  WAM_CHECK(sameTiming(terminal->timing, makeTiming(1, 0)));

  WAM_CHECK(spinUntil([&] {
    return output->flushProgress(1, 2) ==
           NativeTrackedVideoOutputProgress::Done;
  }));
  const auto flushed = output->facts();
  WAM_CHECK(flushed.generation == 2);
  WAM_CHECK(!flushed.invalidationPending);
  WAM_CHECK(!flushed.eventPending);
  // A completed renderer flush proves it holds nothing of ours, so both leases
  // are released rather than waiting for a successor enqueue.
  WAM_CHECK(flushed.retainedFrames == 0);
  WAM_CHECK(!flushed.fatal);
  WAM_CHECK(output->health().flushes == 1);
  WAM_CHECK(wakes.load(std::memory_order_acquire) > wakesBeforeFlush);

  // Done is repeatable for the exact pair, and only for that pair.
  WAM_CHECK(output->flushProgress(1, 2) ==
            NativeTrackedVideoOutputProgress::Done);
  WAM_CHECK(output->flushProgress(0, 5) ==
            NativeTrackedVideoOutputProgress::StaleGeneration);
  WAM_CHECK(output->capacity(2) == NativeTrackedVideoCapacity::Available);

  // Frames from the retired generation produce no event on the new one.
  {
    auto retired = makeFrame(1, 2, 193);
    WAM_CHECK(output->submit(retired, NativeTrackedFrameSequence{2}, &error) ==
              NativeTrackedVideoSubmitStatus::StaleGeneration);
  }
  WAM_CHECK(!output->takeEvent().has_value());
  WAM_CHECK(output->facts().submittedFrames == 1);

  // The new generation is fully live: it admits, draws, and echoes its own
  // generation. The caller sequence keeps climbing across the flush boundary.
  {
    auto next = makeFrame(2, 0, 194);
    WAM_CHECK(output->submit(next, NativeTrackedFrameSequence{2}, &error) ==
              NativeTrackedVideoSubmitStatus::Accepted);
  }
  const auto afterFlush = output->takeEvent();
  WAM_CHECK(afterFlush.has_value());
  WAM_CHECK(afterFlush->kind == NativeTrackedVideoEventKind::FrameDrawn);
  WAM_CHECK(afterFlush->frameSequence.value == 2);
  WAM_CHECK(afterFlush->generation == 2);
  WAM_CHECK(afterFlush->eventSequence == terminal->eventSequence + 1);
  WAM_CHECK(output->health().metricsLoads == 0);

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
  WAM_CHECK_DETAIL(output->startGeneration(1, &error), error);

  // Zero is never a final generation, and a final generation must be strictly
  // newer than the accepted one.
  WAM_CHECK(output->closeProgress(0) ==
            NativeTrackedVideoOutputProgress::Failed);
  WAM_CHECK(output->closeProgress(1) ==
            NativeTrackedVideoOutputProgress::Failed);
  WAM_CHECK(!output->facts().invalidationPending);
  WAM_CHECK(!output->facts().closed);

  {
    auto admitted = makeFrame(1, 0, 200);
    WAM_CHECK(output->submit(admitted, NativeTrackedFrameSequence{1},
                             &error) == NativeTrackedVideoSubmitStatus::Accepted);
  }
  WAM_CHECK(output->facts().eventPending);
  WAM_CHECK(output->facts().retainedFrames == 1);
  const std::uint64_t wakesBeforeClose = wakes.load(std::memory_order_acquire);

  WAM_CHECK(output->closeProgress(2) ==
            NativeTrackedVideoOutputProgress::Quiescing);
  const auto closing = output->facts();
  WAM_CHECK(closing.invalidationPending);
  WAM_CHECK(closing.eventPending);
  WAM_CHECK(!closing.closed);

  // Close is a hard gate on admission from the instant it is requested, even
  // before it completes.
  WAM_CHECK(output->capacity(1) == NativeTrackedVideoCapacity::Failed);
  WAM_CHECK(output->capacity(2) == NativeTrackedVideoCapacity::Failed);
  {
    auto rejected = makeFrame(1, 1, 201);
    WAM_CHECK(output->submit(rejected, NativeTrackedFrameSequence{2},
                             &error) == NativeTrackedVideoSubmitStatus::Failed);
  }
  WAM_CHECK(output->flushProgress(1, 2) ==
            NativeTrackedVideoOutputProgress::Failed);
  WAM_CHECK(!output->startGeneration(3, &error));
  // Close is repeatable for one exact final generation, and only that one.
  WAM_CHECK(output->closeProgress(3) ==
            NativeTrackedVideoOutputProgress::StaleGeneration);

  // The pending terminal fact must survive the close request: closing the route
  // may not swallow a proof the owner has not yet consumed. Done cannot be
  // reported while it is outstanding, however long the renderer takes.
  pumpFor(150);
  WAM_CHECK(output->closeProgress(2) ==
            NativeTrackedVideoOutputProgress::Quiescing);
  WAM_CHECK(output->facts().eventPending);
  const auto pending = output->takeEvent();
  WAM_CHECK(pending.has_value());
  WAM_CHECK(pending->kind == NativeTrackedVideoEventKind::FrameDrawn);
  WAM_CHECK(pending->frameSequence.value == 1);
  WAM_CHECK(pending->generation == 1);
  WAM_CHECK(sameTiming(pending->timing, makeTiming(1, 0)));

  WAM_CHECK(spinUntil([&] {
    return output->closeProgress(2) == NativeTrackedVideoOutputProgress::Done;
  }));

  const auto closed = output->facts();
  WAM_CHECK(closed.closed);
  WAM_CHECK(!closed.eventPending);
  WAM_CHECK(!closed.invalidationPending);
  WAM_CHECK(!closed.fatal);
  // Terminal invalidation releases every lease the presenter held.
  WAM_CHECK(closed.retainedFrames == 0);
  WAM_CHECK(closed.drawnFrames == 1);
  WAM_CHECK(closed.supersededFrames == 0);
  // DIVERGENCE FROM THE GL ROUTE, asserted as-is rather than as the sibling's
  // behaviour: NativeQtGlOutput reports facts().generation == the final
  // generation after close (see native_qt_gl_output_test.mm's
  // closedFacts.generation == 3), while the layer output never advances
  // acceptedGeneration during close and still reports the pre-close value.
  WAM_CHECK(closed.generation == 1);

  // The renderer's flush completion is the terminal invalidation proof, and it
  // signals the wake seam on its way through.
  WAM_CHECK(wakes.load(std::memory_order_acquire) > wakesBeforeClose);

  // Done is repeatable for the exact final generation and refuses any other,
  // so a retrying owner cannot be told "not yet" forever or "done" for the
  // wrong generation.
  WAM_CHECK(output->closeProgress(2) ==
            NativeTrackedVideoOutputProgress::Done);
  WAM_CHECK(output->closeProgress(4) ==
            NativeTrackedVideoOutputProgress::StaleGeneration);

  // The wake gate is closed and drained before Done, and the seam is released.
  // Nothing may signal it afterwards; the owner is now free to destroy the raw
  // wake context.
  const std::uint64_t wakesAfterClose = wakes.load(std::memory_order_acquire);
  pumpFor(150);
  WAM_CHECK(wakes.load(std::memory_order_acquire) == wakesAfterClose);

  // Nothing survives the close.
  WAM_CHECK(!output->takeEvent().has_value());
  WAM_CHECK(output->capacity(2) == NativeTrackedVideoCapacity::Failed);
  WAM_CHECK(output->flushProgress(2, 3) ==
            NativeTrackedVideoOutputProgress::Failed);
  {
    auto rejected = makeFrame(1, 2, 202);
    WAM_CHECK(output->submit(rejected, NativeTrackedFrameSequence{5},
                             &error) == NativeTrackedVideoSubmitStatus::Failed);
  }
  // The Qt video item's per-frame update must be restored the moment the route
  // stops presenting, so a libmpv fallback still paints.
  WAM_CHECK(!nativeLayerPresentationActive());

  output.reset();
  WAM_CHECK(!nativeLayerPresentationActive());
}

// closeProgress() overtaking an in-flight flushProgress(). The route can be
// torn down mid-seek, and the terminal invalidation must subsume the
// generation flush rather than deadlocking behind it.
void verifyCloseSupersedesPendingFlush() {
  std::atomic<std::uint64_t> wakes{0};
  auto output = createDetached(&wakes);
  std::string error;
  WAM_CHECK_DETAIL(output->startGeneration(1, &error), error);

  {
    auto admitted = makeFrame(1, 0, 210);
    WAM_CHECK(output->submit(admitted, NativeTrackedFrameSequence{1},
                             &error) == NativeTrackedVideoSubmitStatus::Accepted);
  }
  const auto drawn = output->takeEvent();
  WAM_CHECK(drawn.has_value());
  WAM_CHECK(drawn->kind == NativeTrackedVideoEventKind::FrameDrawn);

  // The renderer may acknowledge this flush before the call even returns, so
  // both outcomes are legal here. Only the close below is asserted exactly.
  const auto flushStarted = output->flushProgress(1, 2);
  WAM_CHECK(flushStarted == NativeTrackedVideoOutputProgress::Quiescing ||
            flushStarted == NativeTrackedVideoOutputProgress::Done);

  const auto closeStarted = output->closeProgress(3);
  WAM_CHECK(closeStarted == NativeTrackedVideoOutputProgress::Quiescing ||
            closeStarted == NativeTrackedVideoOutputProgress::Done);
  WAM_CHECK(spinUntil([&] {
    return output->closeProgress(3) == NativeTrackedVideoOutputProgress::Done;
  }));

  const auto closed = output->facts();
  WAM_CHECK(closed.closed);
  WAM_CHECK(!closed.invalidationPending);
  WAM_CHECK(!closed.eventPending);
  WAM_CHECK(closed.retainedFrames == 0);
  // The superseded flush leaves no residue that could report Done later.
  WAM_CHECK(output->flushProgress(1, 2) ==
            NativeTrackedVideoOutputProgress::Failed);

  output.reset();
  WAM_CHECK(!nativeLayerPresentationActive());
}

// ------------------------------------------------------------------- case 8

// The presenter holds at most kRetainedFrameLeaseCeiling leases in steady
// state, and those leases are really released, not merely uncounted. The
// surface budget is the independent witness: it charges one unique IOSurface
// per live lease process-wide, so its count is a fact about retention that
// facts().retainedFrames cannot fake.
void verifyRetainedLeaseCeilingAndRelease() {
  const auto baseline = NativeSurfaceBudget::stats();
  std::atomic<std::uint64_t> wakes{0};
  auto output = createDetached(&wakes);
  std::string error;
  WAM_CHECK_DETAIL(output->startGeneration(1, &error), error);

  std::uint64_t previousEventSequence = 0;
  constexpr std::uint64_t kFrames = 5;
  for (std::uint64_t index = 1; index <= kFrames; ++index) {
    {
      // The caller's lease is the sole delivery owner until submit returns
      // Accepted, and is dropped immediately afterwards. Everything the budget
      // still charges from here on belongs to the presenter alone.
      auto frame = makeFrame(1, static_cast<std::int64_t>(index - 1),
                             static_cast<std::uint8_t>(120 + index));
      WAM_CHECK(output->submit(frame, NativeTrackedFrameSequence{index},
                               &error) ==
                NativeTrackedVideoSubmitStatus::Accepted);
    }

    const auto event = output->takeEvent();
    WAM_CHECK(event.has_value());
    // Exactly one terminal event per accepted submit, of exactly one kind.
    WAM_CHECK(event->kind == NativeTrackedVideoEventKind::FrameDrawn ||
              event->kind == NativeTrackedVideoEventKind::FrameSuperseded);
    WAM_CHECK(event->frameSequence.value == index);
    WAM_CHECK(event->eventSequence > previousEventSequence);
    previousEventSequence = event->eventSequence;
    WAM_CHECK(!output->takeEvent().has_value());

    const auto facts = output->facts();
    WAM_CHECK(facts.submittedFrames == index);
    WAM_CHECK(facts.drawnFrames + facts.supersededFrames == index);
    // One lease for the admitted frame, one for the predecessor the renderer
    // may still be displaying. Never a third.
    WAM_CHECK(facts.retainedFrames <=
              NativeLayerVideoOutput::kRetainedFrameLeaseCeiling);
    WAM_CHECK(facts.retainedFrames == (index == 1 ? std::size_t{1}
                                                  : std::size_t{2}));
    WAM_CHECK(NativeSurfaceBudget::stats().currentSurfaces ==
              baseline.currentSurfaces + facts.retainedFrames);
  }
  WAM_CHECK(output->health().peakRetainedLeases ==
            NativeLayerVideoOutput::kRetainedFrameLeaseCeiling);
  WAM_CHECK(output->health().enqueuedFrames == kFrames);
  WAM_CHECK(output->health().metricsLoads == 0);

  // A completed flush retires both leases, and the budget must see the
  // IOSurfaces come back.
  WAM_CHECK(spinUntil([&] {
    return output->flushProgress(1, 2) ==
           NativeTrackedVideoOutputProgress::Done;
  }));
  WAM_CHECK(output->facts().retainedFrames == 0);
  WAM_CHECK(NativeSurfaceBudget::stats().currentSurfaces ==
            baseline.currentSurfaces);

  // And so does a close that happens while leases are still held.
  {
    auto frame = makeFrame(2, 0, 220);
    WAM_CHECK(output->submit(frame, NativeTrackedFrameSequence{kFrames + 1},
                             &error) ==
              NativeTrackedVideoSubmitStatus::Accepted);
  }
  WAM_CHECK(output->takeEvent().has_value());
  WAM_CHECK(output->facts().retainedFrames == 1);
  WAM_CHECK(NativeSurfaceBudget::stats().currentSurfaces ==
            baseline.currentSurfaces + 1);

  closeAndDrop(std::move(output), 3);
  WAM_CHECK(NativeSurfaceBudget::stats().currentSurfaces ==
            baseline.currentSurfaces);
  WAM_CHECK(NativeSurfaceBudget::stats().peakSurfaces >=
            baseline.currentSurfaces +
                NativeLayerVideoOutput::kRetainedFrameLeaseCeiling);
}

}  // namespace

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
    verifyDetachedConstructionAndActivation();
    verifyCapacityOneAdmissionAndExactTimingEcho();
    verifySequenceRegressionIsFatalAndStillCloses();
    verifyFlushProgressRetiresGeneration();
    verifyCloseProgressIsTerminal();
    verifyCloseSupersedesPendingFlush();
    verifyRetainedLeaseCeilingAndRelease();
  }

  std::cout << "native layer video output contract tests passed\n";
  return EXIT_SUCCESS;
}
