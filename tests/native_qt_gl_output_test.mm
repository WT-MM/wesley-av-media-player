#include "qt/macos/native_qt_gl_output.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>

#include <QElapsedTimer>
#include <QEventLoop>
#include "accelerated_gl_gate.hpp"
#include <QGuiApplication>
#include <QImage>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSurfaceFormat>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <thread>

namespace {

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

// Returns the value of the LAST evaluation, never re-evaluating after success.
// Several predicates consume a capacity-one mailbox (takeEvent()); a trailing
// re-evaluation would take the event a second time, see an empty mailbox, and
// report the wait as failed exactly when it had succeeded.
template <typename Predicate>
bool spinUntil(Predicate predicate, int timeoutMs = 5000) {
  QElapsedTimer timer;
  timer.start();
  for (;;) {
    if (predicate()) {
      return true;
    }
    if (timer.elapsed() >= timeoutMs) {
      return false;
    }
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
}

void pumpEventsFor(int durationMs) {
  QElapsedTimer timer;
  timer.start();
  while (timer.elapsed() < durationMs) {
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
}

QColor centerPixel(QQuickWindow& window) {
  const QImage image = window.grabWindow();
  WAM_CHECK(!image.isNull());
  return image.pixelColor(image.width() / 2, image.height() / 2);
}

CVPixelBufferRef createSolidNv12(std::uint8_t luma) {
  CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 3, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFDictionaryRef empty = CFDictionaryCreate(
      kCFAllocatorDefault, nullptr, nullptr, 0,
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(attributes, kCVPixelBufferIOSurfacePropertiesKey,
                       empty);
  CFDictionarySetValue(
      attributes, kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey,
      kCFBooleanTrue);
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

  auto* yPlane = static_cast<std::uint8_t*>(
      CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
  auto* uvPlane = static_cast<std::uint8_t*>(
      CVPixelBufferGetBaseAddressOfPlane(buffer, 1));
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

wam::macos::FrameLease makeFrame(std::uint64_t generation,
                                 std::uint8_t luma) {
  CVPixelBufferRef buffer = createSolidNv12(luma);
  WAM_CHECK(buffer != nullptr);
  wam::macos::FrameTiming timing;
  timing.presentationTime = CMTimeMake(0, 600);
  timing.duration = CMTimeMake(20, 600);
  timing.generation = generation;
  wam::macos::FrameLease frame(buffer, timing);
  CVPixelBufferRelease(buffer);
  return frame;
}

// The first flush of a fresh generation may prove render-side invalidation
// synchronously when issued on the GUI thread; the contract only forbids Done
// BEFORE the proof, not an immediate proof.
[[nodiscard]] bool flushStarted(
    wam::macos::NativeTrackedVideoOutputProgress progress) {
  return progress == wam::macos::NativeTrackedVideoOutputProgress::Quiescing ||
         progress == wam::macos::NativeTrackedVideoOutputProgress::Done;
}


void trackedWake(void* context) noexcept {
  static_cast<std::atomic<std::uint64_t>*>(context)->fetch_add(
      1, std::memory_order_release);
}

using wam::macos::NativeQtGlOutput;
using wam::macos::NativeTrackedFrameSequence;
using wam::macos::NativeTrackedVideoCapacity;
using wam::macos::NativeTrackedVideoEventKind;
using wam::macos::NativeTrackedVideoOutputProgress;
using wam::macos::NativeTrackedVideoSubmitStatus;

std::shared_ptr<NativeQtGlOutput> createOutput(
    wam::macos::QtGlVideoItem* item, std::atomic<std::uint64_t>* wakes) {
  std::string error;
  auto output = NativeQtGlOutput::createTracked(item, {trackedWake, wakes},
                                                &error);
  WAM_CHECK_DETAIL(output != nullptr, error);
  return output;
}

std::unique_ptr<wam::macos::QtGlVideoItem> createItem(QQuickWindow& window) {
  auto item = std::make_unique<wam::macos::QtGlVideoItem>();
  item->setParentItem(window.contentItem());
  item->setSize(QSizeF(480, 270));
  return item;
}

void dropItem(std::unique_ptr<wam::macos::QtGlVideoItem>& item) {
  QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
  item->setParentItem(nullptr);
  item.reset();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
}

// Owner-side flush, exactly as the native video consumer drives it: begin,
// then poll until the render thread proves the new generation.
void advanceGeneration(NativeQtGlOutput& output, std::uint64_t retired,
                       std::uint64_t next) {
  WAM_CHECK(flushStarted(output.flushProgress(retired, next)));
  WAM_CHECK(spinUntil([&] {
    return output.flushProgress(retired, next) ==
           NativeTrackedVideoOutputProgress::Done;
  }));
}

wam::macos::NativeTrackedVideoEvent waitForEvent(NativeQtGlOutput& output) {
  std::optional<wam::macos::NativeTrackedVideoEvent> event;
  WAM_CHECK(spinUntil([&] {
    event = output.takeEvent();
    return event.has_value();
  }));
  return *event;
}

void submitAndWaitForDraw(NativeQtGlOutput& output,
                          const wam::macos::FrameLease& frame,
                          std::uint64_t sequence) {
  std::string error;
  WAM_CHECK_DETAIL(output.submit(frame, NativeTrackedFrameSequence{sequence},
                                 &error) ==
                       NativeTrackedVideoSubmitStatus::Accepted,
                   error);
  const auto drawn = waitForEvent(output);
  WAM_CHECK(drawn.kind == NativeTrackedVideoEventKind::FrameDrawn);
  WAM_CHECK(drawn.frameSequence.value == sequence);
}

void closeOutput(NativeQtGlOutput& output, std::uint64_t finalGeneration) {
  WAM_CHECK(spinUntil([&] {
    return output.closeProgress(finalGeneration) ==
           NativeTrackedVideoOutputProgress::Done;
  }));
}

bool isBlack(const QColor& pixel) {
  return pixel.red() <= 4 && pixel.green() <= 4 && pixel.blue() <= 4;
}

// The deferred watchdog exists only to observe presenter progress while an
// admitted frame is outstanding; it must never become a recurring timer.
void verifyDeferredWatchdogIsStrictlyOnDemand(QQuickWindow& window) {
  auto item = createItem(window);
  std::atomic<std::uint64_t> wakes{0};
  auto output = createOutput(item.get(), &wakes);

  const auto idleBaseline = output->deferredWatchdogFactsForTesting();
  pumpEventsFor(175);
  const auto idle = output->deferredWatchdogFactsForTesting();
  WAM_CHECK(idle.armRequests == idleBaseline.armRequests);
  WAM_CHECK(idle.arms == idleBaseline.arms);
  WAM_CHECK(idle.wakes == idleBaseline.wakes);
  WAM_CHECK(!idle.active);
  WAM_CHECK(!idle.armQueued);

  // A frame admitted to a hidden item is never drawn, so presenter
  // observation stays armed while the output itself goes quiet.
  advanceGeneration(*output, 0, 1);
  item->setVisible(false);
  std::string error;
  WAM_CHECK_DETAIL(output->submit(makeFrame(1, 90),
                                  NativeTrackedFrameSequence{1}, &error) ==
                       NativeTrackedVideoSubmitStatus::Accepted,
                   error);
  WAM_CHECK(spinUntil([&] {
    return item->stats().submittedFrames == 1 &&
           !output->observationPollQueuedForTesting();
  }));
  const auto pausedBaseline = output->deferredWatchdogFactsForTesting();
  output->noticeRenderProgressForTesting();
  const auto firstArm = output->deferredWatchdogFactsForTesting();
  WAM_CHECK(firstArm.armRequests == pausedBaseline.armRequests + 1);
  WAM_CHECK(firstArm.arms == pausedBaseline.arms + 1);
  WAM_CHECK(firstArm.wakes == pausedBaseline.wakes);
  WAM_CHECK(firstArm.active);
  WAM_CHECK(firstArm.renderObservationPending);
  WAM_CHECK(spinUntil([&] {
    const auto facts = output->deferredWatchdogFactsForTesting();
    return facts.wakes == pausedBaseline.wakes + 1 && !facts.active &&
           !facts.armQueued && !facts.renderObservationPending;
  }));

  const auto firstSettled = output->deferredWatchdogFactsForTesting();
  pumpEventsFor(175);
  const auto pausedIdle = output->deferredWatchdogFactsForTesting();
  WAM_CHECK(pausedIdle.armRequests == firstSettled.armRequests);
  WAM_CHECK(pausedIdle.arms == firstSettled.arms);
  WAM_CHECK(pausedIdle.wakes == firstSettled.wakes);
  WAM_CHECK(!pausedIdle.active);

  std::thread deferredNotifier(
      [&] { output->noticeRenderProgressForTesting(); });
  deferredNotifier.join();
  WAM_CHECK(spinUntil([&] {
    const auto facts = output->deferredWatchdogFactsForTesting();
    return facts.armRequests == firstSettled.armRequests + 1 &&
           facts.arms == firstSettled.arms + 1 &&
           facts.wakes == firstSettled.wakes + 1 && !facts.active &&
           !facts.armQueued && !facts.renderObservationPending;
  }));
  const auto secondSettled = output->deferredWatchdogFactsForTesting();
  pumpEventsFor(175);
  const auto finalIdle = output->deferredWatchdogFactsForTesting();
  WAM_CHECK(finalIdle.armRequests == secondSettled.armRequests);
  WAM_CHECK(finalIdle.arms == secondSettled.arms);
  WAM_CHECK(finalIdle.wakes == secondSettled.wakes);

  output.reset();
  dropItem(item);
}

void verifyTrackedDrawAndInvalidation(QQuickWindow& window) {
  std::string error;
  auto item = std::make_unique<wam::macos::QtGlVideoItem>();
  item->setParentItem(window.contentItem());
  item->setSize(QSizeF(480, 270));
  std::atomic<std::uint64_t> wakes{0};
  std::atomic<wam::macos::NativeQtGlOutput*> renderProbeOutput{nullptr};
  std::atomic<bool> renderProbeArmed{false};
  std::atomic<std::uint64_t> renderProbeCalls{0};
  std::atomic<wam::macos::NativeTrackedVideoCapacity> renderProbeCapacity{
      wam::macos::NativeTrackedVideoCapacity::Failed};
  // Connect before the adapter so this direct callback deterministically
  // samples the draw mailbox first. The adapter's later afterRendering
  // observer then sees no delta; progress depends on capacity() preserving
  // the wake edge it consumed.
  const QMetaObject::Connection renderProbe = QObject::connect(
      &window, &QQuickWindow::afterRendering, &window,
      [&] {
        if (!renderProbeArmed.load(std::memory_order_acquire)) {
          return;
        }
        if (auto* observed =
                renderProbeOutput.load(std::memory_order_acquire)) {
          renderProbeCapacity.store(observed->capacity(1),
                                    std::memory_order_release);
          renderProbeCalls.fetch_add(1, std::memory_order_release);
        }
      },
      Qt::DirectConnection);
  auto output = wam::macos::NativeQtGlOutput::createTracked(
      item.get(), {trackedWake, &wakes}, &error);
  WAM_CHECK_DETAIL(output != nullptr, error);
  renderProbeOutput.store(output.get(), std::memory_order_release);
  WAM_CHECK(output->capacity(1) ==
            wam::macos::NativeTrackedVideoCapacity::StaleGeneration);

  WAM_CHECK(flushStarted(output->flushProgress(0, 1)));
  WAM_CHECK(spinUntil([&] {
    return output->flushProgress(0, 1) ==
           wam::macos::NativeTrackedVideoOutputProgress::Done;
  }));
  WAM_CHECK(output->capacity(1) ==
            wam::macos::NativeTrackedVideoCapacity::Available);

  auto frame = makeFrame(1, 180);
  wakes.store(0, std::memory_order_release);
  renderProbeCalls.store(0, std::memory_order_release);
  renderProbeArmed.store(true, std::memory_order_release);
  WAM_CHECK(output->submit(
                frame, wam::macos::NativeTrackedFrameSequence{1}, &error) ==
            wam::macos::NativeTrackedVideoSubmitStatus::Accepted);
  WAM_CHECK(output->capacity(1) ==
            wam::macos::NativeTrackedVideoCapacity::Backpressure);
  WAM_CHECK(output->submit(
                frame, wam::macos::NativeTrackedFrameSequence{2}, &error) ==
            wam::macos::NativeTrackedVideoSubmitStatus::Backpressure);
  WAM_CHECK(spinUntil([&] {
    return renderProbeCalls.load(std::memory_order_acquire) != 0 &&
           wakes.load(std::memory_order_acquire) != 0;
  }));
  WAM_CHECK(renderProbeCapacity.load(std::memory_order_acquire) ==
            wam::macos::NativeTrackedVideoCapacity::Backpressure);
  renderProbeArmed.store(false, std::memory_order_release);
  std::optional<wam::macos::NativeTrackedVideoEvent> draw;
  WAM_CHECK(spinUntil([&] {
    draw = output->takeEvent();
    return draw.has_value();
  }));
  WAM_CHECK(draw->kind ==
            wam::macos::NativeTrackedVideoEventKind::FrameDrawn);
  WAM_CHECK(draw->frameSequence.value == 1);
  WAM_CHECK(draw->generation == 1);
  WAM_CHECK(CMTimeCompare(draw->timing.presentationTime,
                          frame.timing().presentationTime) == 0);
  const auto afterDraw = output->facts();
  WAM_CHECK(afterDraw.drawnFrames == 1);
  WAM_CHECK(afterDraw.retainedFrames == 0);
  WAM_CHECK(wakes.load(std::memory_order_acquire) > 0);

  auto second = makeFrame(1, 210);
  WAM_CHECK(output->submit(
                second, wam::macos::NativeTrackedFrameSequence{2}, &error) ==
            wam::macos::NativeTrackedVideoSubmitStatus::Accepted);
  WAM_CHECK(output->flushProgress(1, 2) ==
            wam::macos::NativeTrackedVideoOutputProgress::Quiescing);
  std::optional<wam::macos::NativeTrackedVideoEvent> superseded;
  WAM_CHECK(spinUntil([&] {
    superseded = output->takeEvent();
    return superseded.has_value();
  }));
  WAM_CHECK(superseded->kind ==
            wam::macos::NativeTrackedVideoEventKind::FrameSuperseded);
  WAM_CHECK(superseded->frameSequence.value == 2);
  WAM_CHECK(spinUntil([&] {
    return output->flushProgress(1, 2) ==
           wam::macos::NativeTrackedVideoOutputProgress::Done;
  }));
  WAM_CHECK(output->facts().supersededFrames == 1);

  // Pin a callback before terminal detachment. closeProgress must atomically
  // close the same gate, reject every later entry, and remain Quiescing until
  // this pre-close pin drains; only then may it return Done and let the owner
  // release the raw wake context.
  std::atomic<bool> pinnedEntered{false};
  std::atomic<bool> pinnedRelease{false};
  std::thread pinnedWake([&] {
    output->holdPinnedTrackedWakeForTesting(&pinnedEntered,
                                             &pinnedRelease);
  });
  WAM_CHECK(spinUntil(
      [&] { return pinnedEntered.load(std::memory_order_acquire); }));
  WAM_CHECK(output->closeProgress(3) ==
            wam::macos::NativeTrackedVideoOutputProgress::Quiescing);
  WAM_CHECK(spinUntil([&] {
    const auto progress = output->closeProgress(3);
    WAM_CHECK(progress !=
              wam::macos::NativeTrackedVideoOutputProgress::Done);
    std::atomic<bool> lateEntered{false};
    std::atomic<bool> lateRelease{true};
    std::thread lateWake([&] {
      output->holdPinnedTrackedWakeForTesting(&lateEntered,
                                               &lateRelease);
    });
    lateWake.join();
    return !lateEntered.load(std::memory_order_acquire);
  }));
  pinnedRelease.store(true, std::memory_order_release);
  pinnedWake.join();
  WAM_CHECK(spinUntil([&] {
    return output->closeProgress(3) ==
           wam::macos::NativeTrackedVideoOutputProgress::Done;
  }));
  WAM_CHECK(output->closeProgress(3) ==
            wam::macos::NativeTrackedVideoOutputProgress::Done);
  renderProbeOutput.store(nullptr, std::memory_order_release);
  QObject::disconnect(renderProbe);
  output.reset();
  item->setParentItem(nullptr);
  item.reset();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
}

void verifyTrackedRejectionPrecedesInvalidation(QQuickWindow& window) {
  std::string error;
  auto item = std::make_unique<wam::macos::QtGlVideoItem>();
  item->setParentItem(window.contentItem());
  item->setSize(QSizeF(480, 270));
  std::atomic<std::uint64_t> wakes{0};
  auto output = wam::macos::NativeQtGlOutput::createTracked(
      item.get(), {trackedWake, &wakes}, &error);
  WAM_CHECK_DETAIL(output != nullptr, error);
  WAM_CHECK(flushStarted(output->flushProgress(0, 1)));
  WAM_CHECK(spinUntil([&] {
    return output->flushProgress(0, 1) ==
           wam::macos::NativeTrackedVideoOutputProgress::Done;
  }));

  auto frame = makeFrame(1, 190);
  WAM_CHECK(output->submit(
                frame, wam::macos::NativeTrackedFrameSequence{77}, &error) ==
            wam::macos::NativeTrackedVideoSubmitStatus::Accepted);
  wam::macos::NativeTrackedVideoOutputProgress flushResult =
      wam::macos::NativeTrackedVideoOutputProgress::Failed;
  std::thread flusher([&] { flushResult = output->flushProgress(1, 2); });
  flusher.join();
  WAM_CHECK(flushResult ==
            wam::macos::NativeTrackedVideoOutputProgress::Quiescing);

  // Both facts are present before one owner sample. Although invalidation is
  // also sufficient to supersede frame 77, its exact import rejection must
  // occupy the terminal mailbox first and cannot be overwritten.
  item->publishRenderInvalidationForTesting(2);
  item->publishTrackedRejectionForTesting(
      wam::macos::QtGlFrameIdentity{1, 77}, 1, 1);
  const auto terminal = output->takeEvent();
  WAM_CHECK(terminal.has_value());
  WAM_CHECK(terminal->kind ==
            wam::macos::NativeTrackedVideoEventKind::Failed);
  WAM_CHECK(terminal->frameSequence.value == 77);
  const auto facts = output->facts();
  WAM_CHECK(facts.fatal);
  WAM_CHECK(facts.retainedFrames == 0);
  WAM_CHECK(facts.invalidationPending);

  const auto closeStarted = output->closeProgress(3);
  WAM_CHECK(closeStarted ==
                wam::macos::NativeTrackedVideoOutputProgress::Quiescing ||
            closeStarted ==
                wam::macos::NativeTrackedVideoOutputProgress::Done);
  if (closeStarted !=
      wam::macos::NativeTrackedVideoOutputProgress::Done) {
    item->publishRenderInvalidationForTesting(3);
  }
  WAM_CHECK(spinUntil([&] {
    return output->closeProgress(3) ==
           wam::macos::NativeTrackedVideoOutputProgress::Done;
  }));
  const auto closedFacts = output->facts();
  WAM_CHECK(closedFacts.fatal);
  WAM_CHECK(closedFacts.closed);
  WAM_CHECK(closedFacts.generation == 3);
  WAM_CHECK(closedFacts.retainedFrames == 0);
  WAM_CHECK(!closedFacts.eventPending);
  WAM_CHECK(!closedFacts.invalidationPending);

  output.reset();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
  item->setParentItem(nullptr);
  item.reset();
}

void verifyTrackedFailedFrameStillCloses(QQuickWindow& window) {
  std::string error;
  auto item = std::make_unique<wam::macos::QtGlVideoItem>();
  item->setParentItem(window.contentItem());
  item->setSize(QSizeF(480, 270));
  std::atomic<std::uint64_t> wakes{0};
  auto output = wam::macos::NativeQtGlOutput::createTracked(
      item.get(), {trackedWake, &wakes}, &error);
  WAM_CHECK_DETAIL(output != nullptr, error);
  WAM_CHECK(flushStarted(output->flushProgress(0, 1)));
  item->publishRenderInvalidationForTesting(1);
  WAM_CHECK(output->flushProgress(0, 1) ==
            wam::macos::NativeTrackedVideoOutputProgress::Done);

  auto frame = makeFrame(1, 200);
  WAM_CHECK(output->submit(
                frame, wam::macos::NativeTrackedFrameSequence{91}, &error) ==
            wam::macos::NativeTrackedVideoSubmitStatus::Accepted);
  item->publishTrackedRejectionForTesting(
      wam::macos::QtGlFrameIdentity{1, 91}, 1, 1);
  const auto failed = output->takeEvent();
  WAM_CHECK(failed.has_value());
  WAM_CHECK(failed->kind ==
            wam::macos::NativeTrackedVideoEventKind::Failed);
  WAM_CHECK(failed->frameSequence.value == 91);
  WAM_CHECK(output->facts().fatal);
  WAM_CHECK(output->facts().retainedFrames == 0);

  const auto closeStarted = output->closeProgress(2);
  WAM_CHECK(closeStarted ==
                wam::macos::NativeTrackedVideoOutputProgress::Quiescing ||
            closeStarted ==
                wam::macos::NativeTrackedVideoOutputProgress::Done);
  if (closeStarted !=
      wam::macos::NativeTrackedVideoOutputProgress::Done) {
    item->publishRenderInvalidationForTesting(2);
  }
  WAM_CHECK(output->closeProgress(2) ==
            wam::macos::NativeTrackedVideoOutputProgress::Done);
  const auto closedFacts = output->facts();
  WAM_CHECK(closedFacts.fatal);
  WAM_CHECK(closedFacts.closed);
  WAM_CHECK(closedFacts.generation == 2);
  WAM_CHECK(closedFacts.retainedFrames == 0);
  WAM_CHECK(!closedFacts.eventPending);
  WAM_CHECK(!closedFacts.invalidationPending);

  output.reset();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
  item->setParentItem(nullptr);
  item.reset();
}

// close() from a non-GUI owner followed by dropping the last owner before any
// GUI event is pumped. The queued drain holds only weak State and dies with
// it; the independently owned GUI finalizer must still invalidate the item
// before its lease is released, without depending on deleteLater latency.
void verifyOffThreadCloseAndFinalOwnerDrop(QQuickWindow& window) {
  auto item = createItem(window);
  std::atomic<std::uint64_t> wakes{0};
  auto output = createOutput(item.get(), &wakes);
  advanceGeneration(*output, 0, 1);
  submitAndWaitForDraw(*output, makeFrame(1, 175), 1);
  WAM_CHECK(!isBlack(centerPixel(window)));

  std::thread closer([owned = std::move(output)]() mutable {
    WAM_CHECK(owned->closeProgress(3) ==
              NativeTrackedVideoOutputProgress::Quiescing);
    owned.reset();
  });
  closer.join();
  WAM_CHECK(item->stats().acceptedGeneration == 1);
  WAM_CHECK(spinUntil([&] { return item->stats().acceptedGeneration >= 3; }));
  WAM_CHECK(isBlack(centerPixel(window)));

  // The lease came back with the retired adapter. A replacement inherits the
  // item's generation history, and an owner flush that does not move past it
  // is a controller defect: the item still advances fail closed (nothing of
  // the old timeline can be re-admitted) and the output reports failure.
  auto replacement = createOutput(item.get(), &wakes);
  const std::uint64_t inherited = item->stats().acceptedGeneration;
  WAM_CHECK(replacement->facts().generation == inherited);
  NativeTrackedVideoOutputProgress equalFlush =
      NativeTrackedVideoOutputProgress::Done;
  std::thread equalFlusher(
      [&] { equalFlush = replacement->flushProgress(0, inherited); });
  equalFlusher.join();
  WAM_CHECK(equalFlush == NativeTrackedVideoOutputProgress::Failed);
  WAM_CHECK(spinUntil([&] {
    return item->stats().acceptedGeneration == inherited + 1 &&
           replacement->facts().generation == inherited + 1;
  }));
  WAM_CHECK(replacement->facts().fatal);
  WAM_CHECK(replacement->capacity(inherited + 1) ==
            NativeTrackedVideoCapacity::Failed);
  closeOutput(*replacement, inherited + 2);
  replacement.reset();
  dropItem(item);
}

// Presenter observation stays armed for as long as an admitted frame is
// outstanding: a hidden, paused frame that fails only when exposed much later
// must still be reported, after all transient delivery polling went quiet.
void verifyHiddenLatePresenterFailure(QQuickWindow& window) {
  auto item = createItem(window);
  std::atomic<std::uint64_t> wakes{0};
  auto output = createOutput(item.get(), &wakes);
  advanceGeneration(*output, 0, 1);
  item->setVisible(false);
  std::string error;
  WAM_CHECK_DETAIL(output->submit(makeFrame(1, 160),
                                  NativeTrackedFrameSequence{1}, &error) ==
                       NativeTrackedVideoSubmitStatus::Accepted,
                   error);
  WAM_CHECK(spinUntil([&] {
    return item->stats().submittedFrames == 1 &&
           !output->observationPollQueuedForTesting();
  }));
  WAM_CHECK(item->stats().renderedFrames == 0);
  WAM_CHECK(!output->facts().fatal);

  const std::uint64_t wakesBeforeFailure =
      wakes.load(std::memory_order_acquire);
  item->failAfterRetirementServiceCreationForTesting();
  item->setVisible(true);
  window.requestUpdate();
  WAM_CHECK(spinUntil([&] { return output->facts().fatal; }));
  WAM_CHECK(wakes.load(std::memory_order_acquire) > wakesBeforeFailure);
  WAM_CHECK(output->capacity(1) == NativeTrackedVideoCapacity::Failed);
  WAM_CHECK(output->submit(makeFrame(1, 170), NativeTrackedFrameSequence{2},
                           &error) == NativeTrackedVideoSubmitStatus::Failed);
  WAM_CHECK(error.find("retirement service creation") != std::string::npos);

  output.reset();
  dropItem(item);
}

void verifySchedulingAllocationFailures(QQuickWindow& window) {
  std::string error;

  // A functor-allocation throw before Qt accepted the GUI drain releases the
  // sole admitted frame and fails the submission closed.
  {
    auto item = createItem(window);
    std::atomic<std::uint64_t> wakes{0};
    auto output = createOutput(item.get(), &wakes);
    advanceGeneration(*output, 0, 1);
    const auto before = item->stats().submittedFrames;
    output->throwNextGuiDrainInvokeForTesting();
    WAM_CHECK(output->submit(makeFrame(1, 120), NativeTrackedFrameSequence{1},
                             &error) ==
              NativeTrackedVideoSubmitStatus::Failed);
    const auto facts = output->facts();
    WAM_CHECK(facts.fatal);
    WAM_CHECK(facts.retainedFrames == 0);
    WAM_CHECK(facts.submittedFrames == 0);
    WAM_CHECK(output->submit(makeFrame(1, 130), NativeTrackedFrameSequence{2},
                             &error) ==
              NativeTrackedVideoSubmitStatus::Failed);
    pumpEventsFor(20);
    WAM_CHECK(item->stats().submittedFrames == before);
    output.reset();
    dropItem(item);
  }

  // An unexpected throw after Qt accepted the drain request is caught at the
  // queued QObject boundary; the frame never reaches the item and the output
  // fails closed.
  {
    auto item = createItem(window);
    std::atomic<std::uint64_t> wakes{0};
    auto output = createOutput(item.get(), &wakes);
    advanceGeneration(*output, 0, 1);
    const auto before = item->stats().submittedFrames;
    output->throwInNextAcceptedGuiDrainForTesting();
    WAM_CHECK(output->submit(makeFrame(1, 140), NativeTrackedFrameSequence{1},
                             &error) ==
              NativeTrackedVideoSubmitStatus::Accepted);
    WAM_CHECK(spinUntil([&] { return output->facts().fatal; }));
    WAM_CHECK(output->capacity(1) == NativeTrackedVideoCapacity::Failed);
    WAM_CHECK(item->stats().submittedFrames == before);
    output.reset();
    dropItem(item);
  }

  // A presenter-poll timer allocation failure rolls the poll bit back and
  // fails the output closed instead of stranding retirement polling.
  {
    auto item = createItem(window);
    std::atomic<std::uint64_t> wakes{0};
    auto output = createOutput(item.get(), &wakes);
    output->throwNextObservationPollForTesting();
    WAM_CHECK(flushStarted(output->flushProgress(0, 1)));
    WAM_CHECK(output->facts().fatal);
    WAM_CHECK(!output->observationPollQueuedForTesting());
    WAM_CHECK(output->flushProgress(0, 1) ==
              NativeTrackedVideoOutputProgress::Failed);
    output.reset();
    dropItem(item);
  }
}

// A windowChanged reconnect allocation failure never crosses the Qt signal.
// The output fails closed and refuses further frames.
void verifyWindowReconnectFailure(QQuickWindow& window) {
  std::string error;
  auto item = createItem(window);
  std::atomic<std::uint64_t> wakes{0};
  auto output = createOutput(item.get(), &wakes);
  advanceGeneration(*output, 0, 1);
  output->throwNextWindowObservationConnectForTesting();
  item->setParentItem(nullptr);
  item->setParentItem(window.contentItem());
  WAM_CHECK(spinUntil([&] { return output->facts().fatal; }));
  WAM_CHECK(output->capacity(1) == NativeTrackedVideoCapacity::Failed);
  WAM_CHECK(output->submit(makeFrame(1, 170), NativeTrackedFrameSequence{1},
                           &error) == NativeTrackedVideoSubmitStatus::Failed);
  output.reset();
  dropItem(item);
}

void verifyFinalFlushSchedulingFailures(QQuickWindow& window) {
  std::string error;

  // If both off-thread flush queues fail and finalizer functor construction
  // throws, deferred GuiContext destruction remains the exact GUI-thread flush
  // owner. No exception crosses closeProgress() or the noexcept deleter.
  {
    auto item = createItem(window);
    std::atomic<std::uint64_t> wakes{0};
    auto output = createOutput(item.get(), &wakes);
    output->failNextGuiInvokeForTesting();
    output->throwNextFinalFlushInvokeForTesting();
    std::thread closer([owned = std::move(output)]() mutable {
      (void)owned->closeProgress(1);
      owned.reset();
    });
    closer.join();
    // The flush owner is the GuiContext destructor, reached through
    // deleteLater(). The app runs an exec() loop, which delivers a deferred
    // delete posted at loop level 0; this harness pumps with processEvents()
    // at level 0, which by Qt's rule postpones it forever, so deliver it here.
    WAM_CHECK(spinUntil([&] {
      QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
      return item->stats().acceptedGeneration >= 1;
    }));
    auto replacement = createOutput(item.get(), &wakes);
    replacement.reset();
    dropItem(item);
  }

  // If Qt rejects both final-flush queues and even deferred deletion throws,
  // the complete context is quarantined: the item lease stays held and a
  // replacement adapter is denied rather than risking off-thread destruction
  // or releasing an unflushed retained frame.
  {
    auto item = createItem(window);
    std::atomic<std::uint64_t> wakes{0};
    auto output = createOutput(item.get(), &wakes);
    output->failNextGuiInvokeForTesting();
    output->failNextFinalFlushInvokeForTesting();
    output->throwNextGuiContextDeleteLaterForTesting();
    std::thread closer([owned = std::move(output)]() mutable {
      (void)owned->closeProgress(1);
      owned.reset();
    });
    closer.join();
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    WAM_CHECK(NativeQtGlOutput::createTracked(item.get(),
                                              {trackedWake, &wakes},
                                              &error) == nullptr);
    WAM_CHECK(error.find("already has a live native output") !=
              std::string::npos);
    dropItem(item);
  }
}

// One item admits exactly one live output. A frame is drawn with the exact
// source pixels; flushes reject the previous generation's frames; and an
// output created over a reused item seeds itself from the item's history.
void verifyDrawGenerationsAndReuse(QQuickWindow& window) {
  std::string error;
  auto item = createItem(window);
  std::atomic<std::uint64_t> wakes{0};
  auto output = createOutput(item.get(), &wakes);
  WAM_CHECK(NativeQtGlOutput::createTracked(item.get(), {trackedWake, &wakes},
                                            &error) == nullptr);
  advanceGeneration(*output, 0, 1);
  submitAndWaitForDraw(*output, makeFrame(1, 192), 1);
  const QColor drawnPixel = centerPixel(window);
  WAM_CHECK(drawnPixel.red() > 185);
  WAM_CHECK(std::abs(drawnPixel.red() - drawnPixel.green()) <= 3);
  WAM_CHECK(std::abs(drawnPixel.red() - drawnPixel.blue()) <= 3);
  WAM_CHECK(item->stats().exactSourceIOSurface);
  WAM_CHECK(item->stats().acceleratedContext);

  advanceGeneration(*output, 1, 2);
  WAM_CHECK(isBlack(centerPixel(window)));
  WAM_CHECK(output->submit(makeFrame(1, 200), NativeTrackedFrameSequence{2},
                           &error) ==
            NativeTrackedVideoSubmitStatus::StaleGeneration);
  submitAndWaitForDraw(*output, makeFrame(2, 200), 2);
  WAM_CHECK(output->facts().drawnFrames == 2);

  closeOutput(*output, 3);
  WAM_CHECK(output->submit(makeFrame(3, 128), NativeTrackedFrameSequence{3},
                           &error) == NativeTrackedVideoSubmitStatus::Failed);
  WAM_CHECK(isBlack(centerPixel(window)));
  output.reset();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 20);

  auto reused = createOutput(item.get(), &wakes);
  const std::uint64_t inherited = item->stats().acceptedGeneration;
  WAM_CHECK(reused->facts().generation == inherited);
  advanceGeneration(*reused, 0, inherited + 1);
  submitAndWaitForDraw(*reused, makeFrame(inherited + 1, 180), 1);
  closeOutput(*reused, inherited + 2);
  reused.reset();
  dropItem(item);
}

// A terminal presenter cannot be made apparently healthy by consuming its
// first-wins error during a failed output creation. Both attempts fail; only
// a successful scene-graph recreation clears lastError and permits a new
// output, which consumes the historical event after proving recovery.
void verifyTerminalPresenterRefusesOutput(QQuickWindow& window) {
  std::string error;
  auto recoverableItem = createItem(window);
  recoverableItem->failNextImportForTesting();
  recoverableItem->submitTrackedFrame(makeFrame(0, 140),
                                      wam::macos::QtGlFrameIdentity{1, 1});
  window.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] { return !recoverableItem->stats().lastError.isEmpty(); }));
  WAM_CHECK(recoverableItem->stats().fatalErrorSerial == 0);
  dropItem(recoverableItem);
  window.requestUpdate();
  WAM_CHECK(!window.grabWindow().isNull());

  std::atomic<std::uint64_t> wakes{0};
  auto fatalItem = createItem(window);
  fatalItem->failAfterRetirementServiceCreationForTesting();
  fatalItem->submitTrackedFrame(makeFrame(0, 150),
                                wam::macos::QtGlFrameIdentity{1, 1});
  window.requestUpdate();
  WAM_CHECK(spinUntil([&] {
    const auto stats = fatalItem->stats();
    return stats.fatalErrorSerial == 1 && !stats.lastError.isEmpty();
  }));
  for (int attempt = 0; attempt < 2; ++attempt) {
    WAM_CHECK(NativeQtGlOutput::createTracked(
                  fatalItem.get(), {trackedWake, &wakes}, &error) == nullptr);
    WAM_CHECK(error.find("still terminal") != std::string::npos);
  }
  const auto beforeRecovery = fatalItem->stats();
  fatalItem->setParentItem(nullptr);
  window.requestUpdate();
  WAM_CHECK(!window.grabWindow().isNull());
  fatalItem->setParentItem(window.contentItem());
  fatalItem->setSize(QSizeF(480, 270));
  fatalItem->submitTrackedFrame(makeFrame(0, 170),
                                wam::macos::QtGlFrameIdentity{2, 2});
  window.requestUpdate();
  WAM_CHECK(spinUntil([&] {
    const auto stats = fatalItem->stats();
    return stats.renderedFrames > beforeRecovery.renderedFrames &&
           stats.lastError.isEmpty();
  }));
  auto recovered = createOutput(fatalItem.get(), &wakes);
  closeOutput(*recovered, fatalItem->stats().acceptedGeneration + 1);
  recovered.reset();
  dropItem(fatalItem);
}

}  // namespace

int main(int argc, char** argv) {
  QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
  QSurfaceFormat format;
  format.setRenderableType(QSurfaceFormat::OpenGL);
  format.setProfile(QSurfaceFormat::CoreProfile);
  format.setVersion(3, 2);
  format.setStencilBufferSize(8);
  format.setAlphaBufferSize(8);
  format.setSwapBehavior(QSurfaceFormat::DoubleBuffer);
  QSurfaceFormat::setDefaultFormat(format);
  QGuiApplication application(argc, argv);
  if (const int skip = skipUnlessAcceleratedGl()) return skip;

  QQuickWindow window;
  window.resize(480, 270);
  window.setColor(Qt::black);
  window.setPersistentSceneGraph(false);
  window.setPersistentGraphics(false);
  window.show();
  window.requestUpdate();
  WAM_CHECK(spinUntil([&] { return window.isSceneGraphInitialized(); }));
  WAM_CHECK(window.rendererInterface()->graphicsApi() ==
            QSGRendererInterface::OpenGL);

  verifyDeferredWatchdogIsStrictlyOnDemand(window);
  verifyDrawGenerationsAndReuse(window);
  verifyTerminalPresenterRefusesOutput(window);
  verifyOffThreadCloseAndFinalOwnerDrop(window);
  verifyTrackedDrawAndInvalidation(window);
  verifyTrackedFailedFrameStillCloses(window);
  verifyTrackedRejectionPrecedesInvalidation(window);
  verifyHiddenLatePresenterFailure(window);
  verifySchedulingAllocationFailures(window);
  verifyWindowReconnectFailure(window);
  verifyFinalFlushSchedulingFailures(window);

  std::cout << "native Qt OpenGL tracked output tests passed\n";
  return EXIT_SUCCESS;
}
