#include "platform/macos/native_qt_gl_output.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>

#include <QElapsedTimer>
#include <QEventLoop>
#include <QGuiApplication>
#include <QImage>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSurfaceFormat>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <functional>
#include <future>
#include <iostream>
#include <memory>
#include <mutex>
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

template <typename Predicate>
bool spinUntil(Predicate predicate, int timeoutMs = 5000) {
  QElapsedTimer timer;
  timer.start();
  while (!predicate() && timer.elapsed() < timeoutMs) {
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  return predicate();
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

void trackedWake(void* context) noexcept {
  static_cast<std::atomic<std::uint64_t>*>(context)->fetch_add(
      1, std::memory_order_release);
}

void verifyDeferredWatchdogIsStrictlyOnDemand(QQuickWindow& window) {
  std::string error;
  auto item = std::make_unique<wam::macos::QtGlVideoItem>();
  item->setParentItem(window.contentItem());
  item->setSize(QSizeF(480, 270));
  item->setVisible(false);
  auto output = wam::macos::NativeQtGlOutput::create(item.get(), &error);
  WAM_CHECK_DETAIL(output != nullptr, error);

  const auto idleBaseline = output->deferredWatchdogFactsForTesting();
  pumpEventsFor(175);
  const auto idle = output->deferredWatchdogFactsForTesting();
  WAM_CHECK(idle.armRequests == idleBaseline.armRequests);
  WAM_CHECK(idle.arms == idleBaseline.arms);
  WAM_CHECK(idle.wakes == idleBaseline.wakes);
  WAM_CHECK(!idle.active);
  WAM_CHECK(!idle.armQueued);

  output->setFailureHandler([](std::string) {});
  WAM_CHECK(spinUntil(
      [&] { return !output->immediateObservationQueuedForTesting(); }));
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

  output->close(1);
  output.reset();
  item->setParentItem(nullptr);
  item.reset();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
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

  WAM_CHECK(output->flushProgress(0, 1) ==
            wam::macos::NativeTrackedVideoOutputProgress::Quiescing);
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
  WAM_CHECK(output->flushProgress(0, 1) ==
            wam::macos::NativeTrackedVideoOutputProgress::Quiescing);
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
  WAM_CHECK(output->flushProgress(0, 1) ==
            wam::macos::NativeTrackedVideoOutputProgress::Quiescing);
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

std::optional<wam::macos::NativeVideoPrepareOutcome> waitForPreparation(
    wam::macos::NativeVideoPipeline& pipeline) {
  std::optional<wam::macos::NativeVideoPrepareOutcome> outcome;
  const bool ready = spinUntil(
      [&] {
        if (outcome.has_value()) {
          return true;
        }
        outcome = pipeline.takePrepareResult();
        return outcome.has_value();
      },
      8000);
  if (ready && outcome.has_value()) {
    if (outcome->result == wam::macos::NativeVideoPrepareResult::Ready) {
      WAM_CHECK(outcome->generation != 0);
      WAM_CHECK(outcome->generation == pipeline.stats().generation);
    } else {
      // Preparation request sequencing is intentionally private. A terminal
      // outcome that cannot be started must never leak its request ordinal as
      // a decoded-frame/output generation.
      WAM_CHECK(outcome->generation == 0);
    }
  }
  return ready ? std::move(outcome) : std::nullopt;
}

class FailWhileArmingOutput final
    : public wam::macos::NativeScheduledFrameOutput {
 public:
  wam::macos::NativeScheduledFrameDispatchResult dispatch(
      wam::macos::FrameLease, std::string*) noexcept override {
    std::lock_guard lock(mutex_);
    ++unexpectedDispatches_;
    return wam::macos::NativeScheduledFrameDispatchResult::Failed;
  }

  bool flush(std::uint64_t generation, std::string*) noexcept override {
    std::lock_guard lock(mutex_);
    generation_ = std::max(generation_, generation);
    return true;
  }

  bool startGeneration(
      std::uint64_t generation, StartAppliedHandler applied,
      std::string* error) noexcept override {
    if (!flush(generation, error)) {
      return false;
    }
    if (applied) {
      try {
        applied(wam::macos::NativeScheduledFrameStartAck{
            generation, generation, 0});
      } catch (...) {
      }
    }
    return true;
  }

  void close(std::uint64_t generation) noexcept override {
    std::lock_guard lock(mutex_);
    generation_ = std::max(generation_, generation);
    closed_ = true;
  }

  void setFailureHandler(FailureHandler handler) noexcept override {
    FailureHandler notify;
    {
      std::lock_guard lock(mutex_);
      handler_ = std::move(handler);
      if (handler_ && !injected_) {
        injected_ = true;
        notify = handler_;
      }
    }
    if (notify) {
      notify("injected failure while arming native output");
    }
  }

  wam::macos::NativeScheduledFrameOutputStats stats()
      const noexcept override {
    std::lock_guard lock(mutex_);
    wam::macos::NativeScheduledFrameOutputStats result;
    result.closed = closed_;
    result.acceptedGeneration = generation_;
    result.rejectedFrames = unexpectedDispatches_;
    return result;
  }

 private:
  mutable std::mutex mutex_;
  FailureHandler handler_;
  std::uint64_t generation_{0};
  std::uint64_t unexpectedDispatches_{0};
  bool injected_{false};
  bool closed_{false};
};

class FailAfterFirstDispatchOutput final
    : public wam::macos::NativeScheduledFrameOutput {
 public:
  explicit FailAfterFirstDispatchOutput(
      std::shared_ptr<wam::macos::NativeScheduledFrameOutput> wrapped)
      : wrapped_(std::move(wrapped)) {}

  wam::macos::NativeScheduledFrameDispatchResult dispatch(
      wam::macos::FrameLease frame, std::string* error) noexcept override {
    const auto result = wrapped_->dispatch(std::move(frame), error);
    if (result == wam::macos::NativeScheduledFrameDispatchResult::Dispatched) {
      failNow();
    }
    return result;
  }

  void failNow() noexcept {
    FailureHandler notify;
    {
      std::lock_guard lock(mutex_);
      if (!injected_ && handler_) {
        injected_ = true;
        try {
          notify = handler_;
        } catch (...) {
        }
      }
    }
    if (notify) {
      try {
        notify("injected failure after first scheduled dispatch");
      } catch (...) {
      }
    }
  }

  bool flush(std::uint64_t generation, std::string* error) noexcept override {
    return wrapped_->flush(generation, error);
  }

  bool startGeneration(
      std::uint64_t generation, StartAppliedHandler applied,
      std::string* error) noexcept override {
    return wrapped_->startGeneration(generation, std::move(applied), error);
  }

  void close(std::uint64_t generation) noexcept override {
    wrapped_->close(generation);
  }

  void setFailureHandler(FailureHandler handler) noexcept override {
    std::lock_guard lock(mutex_);
    try {
      handler_ = std::move(handler);
    } catch (...) {
      handler_ = {};
    }
  }

  wam::macos::NativeScheduledFrameOutputStats stats()
      const noexcept override {
    return wrapped_->stats();
  }

 private:
  std::shared_ptr<wam::macos::NativeScheduledFrameOutput> wrapped_;
  mutable std::mutex mutex_;
  FailureHandler handler_;
  bool injected_{false};
};

class RetainedStartAckOutput final
    : public wam::macos::NativeScheduledFrameOutput {
 public:
  wam::macos::NativeScheduledFrameDispatchResult dispatch(
      wam::macos::FrameLease, std::string*) noexcept override {
    std::lock_guard lock(mutex_);
    ++unexpectedDispatches_;
    return wam::macos::NativeScheduledFrameDispatchResult::Dispatched;
  }

  bool startGeneration(
      std::uint64_t generation, StartAppliedHandler applied,
      std::string*) noexcept override {
    std::lock_guard lock(mutex_);
    generation_ = std::max(generation_, generation);
    retainedGeneration_ = generation;
    retainedApplied_ = std::move(applied);
    return true;
  }

  bool flush(std::uint64_t generation, std::string*) noexcept override {
    std::lock_guard lock(mutex_);
    generation_ = std::max(generation_, generation);
    // Deliberately retain the old callback. The pipeline, not this adversarial
    // fake, must reject it after stop advances the lifecycle/generation.
    return true;
  }

  void close(std::uint64_t generation) noexcept override {
    std::lock_guard lock(mutex_);
    generation_ = std::max(generation_, generation);
    closed_ = true;
  }

  void setFailureHandler(FailureHandler handler) noexcept override {
    std::lock_guard lock(mutex_);
    handler_ = std::move(handler);
  }

  wam::macos::NativeScheduledFrameOutputStats stats()
      const noexcept override {
    std::lock_guard lock(mutex_);
    wam::macos::NativeScheduledFrameOutputStats result;
    result.closed = closed_;
    result.acceptedGeneration = generation_;
    result.dispatchedFrames = unexpectedDispatches_;
    return result;
  }

  void fireRetainedAck() noexcept {
    StartAppliedHandler applied;
    std::uint64_t generation = 0;
    try {
      std::lock_guard lock(mutex_);
      applied = retainedApplied_;
      generation = retainedGeneration_;
    } catch (...) {
      return;
    }
    if (applied) {
      try {
        applied(wam::macos::NativeScheduledFrameStartAck{
            generation, generation, 0});
      } catch (...) {
      }
    }
  }

 private:
  mutable std::mutex mutex_;
  FailureHandler handler_;
  StartAppliedHandler retainedApplied_;
  std::uint64_t generation_{0};
  std::uint64_t retainedGeneration_{0};
  std::uint64_t unexpectedDispatches_{0};
  bool closed_{false};
};

class RejectCurrentFrameOutput final
    : public wam::macos::NativeScheduledFrameOutput {
 public:
  explicit RejectCurrentFrameOutput(
      std::shared_ptr<wam::macos::NativeScheduledFrameOutput> wrapped)
      : wrapped_(std::move(wrapped)) {}

  wam::macos::NativeScheduledFrameDispatchResult dispatch(
      wam::macos::FrameLease, std::string* error) noexcept override {
    rejections_.fetch_add(1, std::memory_order_relaxed);
    if (error != nullptr) {
      try {
        *error = "injected current-generation output rejection";
      } catch (...) {
      }
    }
    return wam::macos::NativeScheduledFrameDispatchResult::Rejected;
  }

  bool startGeneration(
      std::uint64_t generation, StartAppliedHandler applied,
      std::string* error) noexcept override {
    return wrapped_->startGeneration(generation, std::move(applied), error);
  }

  bool flush(std::uint64_t generation, std::string* error) noexcept override {
    return wrapped_->flush(generation, error);
  }

  void close(std::uint64_t generation) noexcept override {
    wrapped_->close(generation);
  }

  void setFailureHandler(FailureHandler handler) noexcept override {
    wrapped_->setFailureHandler(std::move(handler));
  }

  wam::macos::NativeScheduledFrameOutputStats stats()
      const noexcept override {
    return wrapped_->stats();
  }

  [[nodiscard]] std::uint64_t rejections() const noexcept {
    return rejections_.load(std::memory_order_relaxed);
  }

 private:
  std::shared_ptr<wam::macos::NativeScheduledFrameOutput> wrapped_;
  std::atomic<std::uint64_t> rejections_{0};
};

void verifyFailureDuringPreparedStart(const std::filesystem::path& fixture) {
  std::string error;
  auto output = std::make_shared<FailWhileArmingOutput>();
  auto pipeline =
      wam::macos::NativeVideoPipeline::createForQtOpenGL(output, &error);
  WAM_CHECK_DETAIL(pipeline != nullptr, error);
  WAM_CHECK_DETAIL(pipeline->prepareLocalFileAsync(fixture, 0.0, &error),
                   error);
  auto outcome = waitForPreparation(*pipeline);
  WAM_CHECK(outcome.has_value());
  WAM_CHECK_DETAIL(
      outcome->result == wam::macos::NativeVideoPrepareResult::Ready,
      outcome->error);
  const auto prepared = pipeline->stats();
  WAM_CHECK(prepared.prepared);
  WAM_CHECK(!prepared.active);
  WAM_CHECK(prepared.compressedSamplesSubmitted == 0);
  WAM_CHECK(prepared.displayLinkTicks == 0);

  const auto generation = pipeline->startPrepared(&error);
  WAM_CHECK(!generation.has_value());
  WAM_CHECK(!pipeline->active());
  WAM_CHECK_DETAIL(error.find("arming") != std::string::npos, error);
  WAM_CHECK(pipeline->stats().compressedSamplesSubmitted == 0);
  WAM_CHECK(output->stats().rejectedFrames == 0);
  WAM_CHECK(spinUntil([&] { return !pipeline->stats().stopping; }, 8000));
}

void verifyOffThreadFlushAndFinalOwnerDrop(QQuickWindow& window) {
  std::string error;
  auto item = std::make_unique<wam::macos::QtGlVideoItem>();
  item->setParentItem(window.contentItem());
  item->setSize(QSizeF(480, 270));
  auto output = wam::macos::NativeQtGlOutput::create(item.get(), &error);
  WAM_CHECK_DETAIL(output != nullptr, error);
  output->setFailureHandler([](std::string) {});
  WAM_CHECK(output->flush(1, &error));
  WAM_CHECK(output->dispatch(makeFrame(1, 175), &error) ==
            wam::macos::NativeScheduledFrameDispatchResult::Dispatched);
  WAM_CHECK(spinUntil([&] {
    return output->stats().lastRenderedGeneration == 1;
  }));

  // Equal-generation invalidation from a non-GUI controller thread is
  // fail-closed. Qt advances internally, and the bridge must resample that
  // exact generation rather than retaining its old bookkeeping value.
  bool equalFlushResult = true;
  std::string equalFlushError;
  std::thread equalFlusher([&] {
    equalFlushResult = output->flush(1, &equalFlushError);
  });
  equalFlusher.join();
  WAM_CHECK(!equalFlushResult);
  WAM_CHECK(spinUntil([&] {
    return item->stats().acceptedGeneration == 2 &&
           output->stats().acceptedGeneration == 2;
  }));
  const QColor equalFlushPixel = centerPixel(window);
  WAM_CHECK(equalFlushPixel.red() <= 4 && equalFlushPixel.green() <= 4 &&
            equalFlushPixel.blue() <= 4);
  WAM_CHECK(output->dispatch(makeFrame(1, 235), &error) ==
            wam::macos::NativeScheduledFrameDispatchResult::Rejected);

  WAM_CHECK(output->dispatch(makeFrame(2, 185), &error) ==
            wam::macos::NativeScheduledFrameDispatchResult::Dispatched);
  WAM_CHECK(spinUntil([&] {
    return output->stats().lastRenderedGeneration == 2;
  }));

  // No GUI event is pumped between off-thread close and dropping the last
  // adapter owner. The queued drain's weak State is intentionally gone; the
  // independently owned strong GUI finalizer must still flush before releasing
  // the item lease; correctness cannot depend on deleteLater latency.
  std::thread closer(
      [owned = std::move(output)]() mutable {
        owned->close(3);
        owned.reset();
      });
  closer.join();
  WAM_CHECK(item->stats().acceptedGeneration == 2);
  WAM_CHECK(spinUntil([&] {
    return item->stats().acceptedGeneration >= 3;
  }));
  const QColor closePixel = centerPixel(window);
  WAM_CHECK(closePixel.red() <= 4 && closePixel.green() <= 4 &&
            closePixel.blue() <= 4);

  auto replacement =
      wam::macos::NativeQtGlOutput::create(item.get(), &error);
  WAM_CHECK_DETAIL(replacement != nullptr, error);
  const std::uint64_t replacementGeneration =
      replacement->stats().acceptedGeneration;
  replacement->close(replacementGeneration + 1);
  replacement.reset();
  item->setParentItem(nullptr);
  item.reset();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
}

void verifyOffThreadStartAcknowledgment(QQuickWindow& window) {
  std::string error;
  auto item = std::make_unique<wam::macos::QtGlVideoItem>();
  item->setParentItem(window.contentItem());
  item->setSize(QSizeF(480, 270));
  auto output = wam::macos::NativeQtGlOutput::create(item.get(), &error);
  WAM_CHECK_DETAIL(output != nullptr, error);
  output->setFailureHandler([](std::string) {});
  WAM_CHECK(output->flush(1, &error));
  WAM_CHECK(output->dispatch(makeFrame(1, 145), &error) ==
            wam::macos::NativeScheduledFrameDispatchResult::Dispatched);
  WAM_CHECK(spinUntil([&] {
    return output->stats().lastRenderedGeneration == 1 &&
           item->stats().acceptedRenderedFrames > 0;
  }));

  // A fresh handler epoch marks the next applied start flush as the exact
  // attempt baseline. Calling startGeneration off-GUI advances only logical
  // admission; neither Qt's generation nor the callback changes until the GUI
  // drain linearizes item->flush against presenter draw completion.
  output->setFailureHandler({});
  output->setFailureHandler([](std::string) {});
  std::atomic<unsigned> acknowledgmentCount{0};
  std::mutex acknowledgmentMutex;
  wam::macos::NativeScheduledFrameStartAck acknowledgment;
  bool startAccepted = false;
  std::string startError;
  std::thread starter([&] {
    startAccepted = output->startGeneration(
        2,
        [&](wam::macos::NativeScheduledFrameStartAck value) {
          {
            std::lock_guard lock(acknowledgmentMutex);
            acknowledgment = value;
          }
          acknowledgmentCount.fetch_add(1, std::memory_order_release);
        },
        &startError);
  });
  starter.join();
  WAM_CHECK_DETAIL(startAccepted, startError);
  WAM_CHECK(output->stats().acceptedGeneration == 2);
  WAM_CHECK(item->stats().acceptedGeneration == 1);
  WAM_CHECK(acknowledgmentCount.load(std::memory_order_acquire) == 0);
  WAM_CHECK(output->stats().attemptAcceptedRenderedFrames == 0);

  WAM_CHECK(spinUntil([&] {
    return acknowledgmentCount.load(std::memory_order_acquire) == 1 &&
           item->stats().acceptedGeneration == 2;
  }));
  {
    std::lock_guard lock(acknowledgmentMutex);
    WAM_CHECK(acknowledgment.requestedGeneration == 2);
    WAM_CHECK(acknowledgment.acceptedGeneration == 2);
    WAM_CHECK(acknowledgment.acceptedRenderedFrames ==
              item->stats().acceptedRenderedFrames);
  }
  WAM_CHECK(output->stats().attemptAcceptedRenderedFrames == 0);
  WAM_CHECK(output->dispatch(makeFrame(2, 195), &error) ==
            wam::macos::NativeScheduledFrameDispatchResult::Dispatched);
  WAM_CHECK(spinUntil([&] {
    const auto stats = output->stats();
    return stats.lastRenderedGeneration == 2 &&
           stats.attemptAcceptedRenderedFrames >= 1;
  }));
  WAM_CHECK(acknowledgmentCount.load(std::memory_order_acquire) == 1);

  output->close(3);
  output.reset();
  item->setParentItem(nullptr);
  item.reset();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
}

void verifySameGenerationStartStillAcknowledges(QQuickWindow& window) {
  std::string error;
  auto item = std::make_unique<wam::macos::QtGlVideoItem>();
  item->setParentItem(window.contentItem());
  item->setSize(QSizeF(480, 270));
  auto output = wam::macos::NativeQtGlOutput::create(item.get(), &error);
  WAM_CHECK_DETAIL(output != nullptr, error);

  // setFailureHandler queues a presenter observation before the worker queues
  // startGeneration's drain. Advance Qt independently to the requested value;
  // that first observation makes bridge guiAppliedGeneration equal pendingGen.
  // Startup must still force a flush and produce one acknowledgment (whose
  // advanced actual generation makes a pipeline fail closed), never strand
  // Starting by silently dropping the callback.
  output->setFailureHandler([](std::string) {});
  std::atomic<unsigned> acknowledgmentCount{0};
  wam::macos::NativeScheduledFrameStartAck acknowledgment;
  std::mutex acknowledgmentMutex;
  bool accepted = false;
  std::thread starter([&] {
    accepted = output->startGeneration(
        1,
        [&](wam::macos::NativeScheduledFrameStartAck value) {
          {
            std::lock_guard lock(acknowledgmentMutex);
            acknowledgment = value;
          }
          acknowledgmentCount.fetch_add(1, std::memory_order_release);
        },
        &error);
  });
  starter.join();
  WAM_CHECK(accepted);
  item->flush(1);
  WAM_CHECK(spinUntil([&] {
    return acknowledgmentCount.load(std::memory_order_acquire) == 1;
  }));
  {
    std::lock_guard lock(acknowledgmentMutex);
    WAM_CHECK(acknowledgment.requestedGeneration == 1);
    WAM_CHECK(acknowledgment.acceptedGeneration == 2);
  }
  WAM_CHECK(output->stats().acceptedGeneration == 2);
  pumpEventsFor(50);
  WAM_CHECK(acknowledgmentCount.load(std::memory_order_acquire) == 1);

  output->close(3);
  output.reset();
  item->setParentItem(nullptr);
  item.reset();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
}

void verifyHiddenLatePresenterFailure(QQuickWindow& window) {
  std::string error;
  auto item = std::make_unique<wam::macos::QtGlVideoItem>();
  item->setVisible(false);
  item->setParentItem(window.contentItem());
  item->setSize(QSizeF(480, 270));
  auto output = wam::macos::NativeQtGlOutput::create(item.get(), &error);
  WAM_CHECK_DETAIL(output != nullptr, error);

  std::atomic<unsigned> failureCount{0};
  std::mutex failureMutex;
  std::string failureMessage;
  output->setFailureHandler([&](std::string message) {
    {
      std::lock_guard lock(failureMutex);
      failureMessage = std::move(message);
    }
    failureCount.fetch_add(1, std::memory_order_release);
  });
  WAM_CHECK(output->flush(1, &error));
  WAM_CHECK(output->dispatch(makeFrame(1, 160), &error) ==
            wam::macos::NativeScheduledFrameDispatchResult::Dispatched);
  WAM_CHECK(spinUntil([&] {
    return output->stats().deliveredFrames == 1;
  }));
  WAM_CHECK(item->stats().renderedFrames == 0);
  pumpEventsFor(250);
  WAM_CHECK(failureCount.load(std::memory_order_acquire) == 0);

  // The observer must stay armed for the handler's entire active lifetime.
  // This terminal failure occurs only when a hidden/paused retained frame is
  // exposed much later, after all transient delivery polling has gone quiet.
  item->failAfterRetirementServiceCreationForTesting();
  item->setVisible(true);
  window.requestUpdate();
  WAM_CHECK(spinUntil([&] {
    return failureCount.load(std::memory_order_acquire) == 1 &&
           output->stats().fatalErrorSerial == 1;
  }));
  {
    std::lock_guard lock(failureMutex);
    WAM_CHECK(failureMessage.find("retirement service creation") !=
              std::string::npos);
  }
  for (int repeat = 0; repeat < 3; ++repeat) {
    window.requestUpdate();
    WAM_CHECK(!window.grabWindow().isNull());
  }
  WAM_CHECK(failureCount.load(std::memory_order_acquire) == 1);

  output->close(output->stats().acceptedGeneration + 1);
  output.reset();
  item->setParentItem(nullptr);
  item.reset();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
}

void verifyFailureNotificationCopyRetries(QQuickWindow& window) {
  std::string error;
  auto item = std::make_unique<wam::macos::QtGlVideoItem>();
  item->setParentItem(window.contentItem());
  item->setSize(QSizeF(480, 270));
  auto output = wam::macos::NativeQtGlOutput::create(item.get(), &error);
  WAM_CHECK_DETAIL(output != nullptr, error);
  std::atomic<unsigned> notifications{0};
  auto handler = [&](std::string) {
    notifications.fetch_add(1, std::memory_order_release);
  };
  output->setFailureHandler(handler);
  output->failNextFailureNotificationCopyForTesting();
  item->failAfterRetirementServiceCreationForTesting();
  item->submitFrame(makeFrame(0, 155));
  window.requestUpdate();
  WAM_CHECK(spinUntil([&] {
    return output->stats().fatalErrorSerial == 1;
  }));
  WAM_CHECK(notifications.load(std::memory_order_acquire) == 0);

  // The first simulated allocation failure must not publish "delivered" or
  // permanently disarm the terminal signal. Reinstalling a handler retries
  // the already-latched first-wins message exactly once.
  output->setFailureHandler(handler);
  WAM_CHECK(spinUntil([&] {
    return notifications.load(std::memory_order_acquire) == 1;
  }));
  pumpEventsFor(50);
  WAM_CHECK(notifications.load(std::memory_order_acquire) == 1);
  auto terminalPipeline =
      wam::macos::NativeVideoPipeline::createForQtOpenGL(output, &error);
  WAM_CHECK(terminalPipeline == nullptr);
  WAM_CHECK(error.find("terminal") != std::string::npos);

  output->close(output->stats().acceptedGeneration + 1);
  output.reset();
  item->setParentItem(nullptr);
  item.reset();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
}

void verifySchedulingAllocationFailures(QQuickWindow& window) {
  std::string error;

  // A functor-allocation throw before an accepted GUI drain rolls back the
  // exact token and sole pending frame, returns a terminal dispatch result,
  // and leaves no phantom queued delivery.
  {
    auto item = std::make_unique<wam::macos::QtGlVideoItem>();
    item->setParentItem(window.contentItem());
    item->setSize(QSizeF(480, 270));
    auto output = wam::macos::NativeQtGlOutput::create(item.get(), &error);
    WAM_CHECK_DETAIL(output != nullptr, error);
    std::atomic<unsigned> failures{0};
    output->setFailureHandler([&](std::string) {
      failures.fetch_add(1, std::memory_order_release);
    });
    pumpEventsFor(20);
    output->throwNextGuiDrainInvokeForTesting();
    WAM_CHECK(output->dispatch(makeFrame(0, 120), &error) ==
              wam::macos::NativeScheduledFrameDispatchResult::Failed);
    WAM_CHECK(!output->stats().deliveryQueued);
    WAM_CHECK(output->stats().deliveredFrames == 0);
    WAM_CHECK(failures.load(std::memory_order_acquire) == 1);
    WAM_CHECK(output->dispatch(makeFrame(0, 130), &error) ==
              wam::macos::NativeScheduledFrameDispatchResult::Failed);
    WAM_CHECK(failures.load(std::memory_order_acquire) == 1);
    output->close(1);
    output.reset();
    item->setParentItem(nullptr);
    item.reset();
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
  }

  // An unexpected throw after Qt accepted the drain request is caught at the
  // queued QObject boundary. Its exact token and frame are retired before the
  // fixed first-wins failure is delivered.
  {
    auto item = std::make_unique<wam::macos::QtGlVideoItem>();
    item->setParentItem(window.contentItem());
    item->setSize(QSizeF(480, 270));
    auto output = wam::macos::NativeQtGlOutput::create(item.get(), &error);
    WAM_CHECK_DETAIL(output != nullptr, error);
    std::atomic<unsigned> failures{0};
    output->setFailureHandler([&](std::string) {
      failures.fetch_add(1, std::memory_order_release);
    });
    pumpEventsFor(20);
    output->throwInNextAcceptedGuiDrainForTesting();
    WAM_CHECK(output->dispatch(makeFrame(0, 140), &error) ==
              wam::macos::NativeScheduledFrameDispatchResult::Dispatched);
    WAM_CHECK(spinUntil([&] {
      return failures.load(std::memory_order_acquire) == 1;
    }));
    WAM_CHECK(!output->stats().deliveryQueued);
    WAM_CHECK(output->stats().deliveredFrames == 0);
    output->close(1);
    output.reset();
    item->setParentItem(nullptr);
    item.reset();
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
  }

  // The immediate render observer retries one allocation failure without
  // letting any exception or user callback cross afterRendering.
  {
    auto item = std::make_unique<wam::macos::QtGlVideoItem>();
    item->setParentItem(window.contentItem());
    item->setSize(QSizeF(480, 270));
    auto output = wam::macos::NativeQtGlOutput::create(item.get(), &error);
    WAM_CHECK_DETAIL(output != nullptr, error);
    std::atomic<unsigned> failures{0};
    output->throwNextImmediateObservationInvokeForTesting();
    output->setFailureHandler([&](std::string) {
      failures.fetch_add(1, std::memory_order_release);
    });
    WAM_CHECK(spinUntil(
        [&] { return !output->immediateObservationQueuedForTesting(); }));
    const auto retryFacts = output->deferredWatchdogFactsForTesting();
    WAM_CHECK(retryFacts.arms == 0);
    WAM_CHECK(retryFacts.wakes == 0);
    item->failAfterRetirementServiceCreationForTesting();
    item->submitFrame(makeFrame(0, 150));
    window.requestUpdate();
    WAM_CHECK(spinUntil([&] {
      return failures.load(std::memory_order_acquire) == 1;
    }));
    WAM_CHECK(!output->immediateObservationQueuedForTesting());
    WAM_CHECK(output->stats().fatalErrorSerial == 1);
    output->close(1);
    output.reset();
    item->setParentItem(nullptr);
    item.reset();
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
  }

  // If both bounded immediate-observation attempts throw, the fixed terminal
  // marker arms exactly one pre-created watchdog cycle. It delivers once and
  // returns to a truly idle state instead of leaving a 50 ms repeating timer.
  {
    auto item = std::make_unique<wam::macos::QtGlVideoItem>();
    item->setParentItem(window.contentItem());
    item->setSize(QSizeF(480, 270));
    auto output = wam::macos::NativeQtGlOutput::create(item.get(), &error);
    WAM_CHECK_DETAIL(output != nullptr, error);
    std::atomic<unsigned> failures{0};
    const auto before = output->deferredWatchdogFactsForTesting();
    output->throwNextTwoImmediateObservationInvokesForTesting();
    output->setFailureHandler([&](std::string) {
      failures.fetch_add(1, std::memory_order_release);
    });
    WAM_CHECK(spinUntil([&] {
      return failures.load(std::memory_order_acquire) == 1;
    }));
    const auto settled = output->deferredWatchdogFactsForTesting();
    WAM_CHECK(settled.armRequests == before.armRequests + 1);
    WAM_CHECK(settled.arms == before.arms + 1);
    WAM_CHECK(settled.wakes == before.wakes + 1);
    WAM_CHECK(!settled.active);
    WAM_CHECK(!settled.armQueued);
    WAM_CHECK(!settled.renderObservationPending);
    pumpEventsFor(125);
    const auto idle = output->deferredWatchdogFactsForTesting();
    WAM_CHECK(idle.armRequests == settled.armRequests);
    WAM_CHECK(idle.arms == settled.arms);
    WAM_CHECK(idle.wakes == settled.wakes);
    const auto terminalStats = output->stats();
    WAM_CHECK(terminalStats.fatalErrorSerial == 1);
    (void)output->stats();
    WAM_CHECK(failures.load(std::memory_order_acquire) == 1);
    output->close(1);
    output.reset();
    item->setParentItem(nullptr);
    item.reset();
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
  }

  // Timer allocation failure rolls the poll bit back and terminalizes the
  // bridge exactly once instead of stranding transient retirement polling.
  {
    auto item = std::make_unique<wam::macos::QtGlVideoItem>();
    item->setParentItem(window.contentItem());
    item->setSize(QSizeF(480, 270));
    auto output = wam::macos::NativeQtGlOutput::create(item.get(), &error);
    WAM_CHECK_DETAIL(output != nullptr, error);
    std::atomic<unsigned> failures{0};
    output->setFailureHandler([&](std::string) {
      failures.fetch_add(1, std::memory_order_release);
    });
    pumpEventsFor(20);
    output->throwNextObservationPollForTesting();
    WAM_CHECK(output->flush(1, &error));
    WAM_CHECK(failures.load(std::memory_order_acquire) == 1);
    WAM_CHECK(!output->observationPollQueuedForTesting());
    WAM_CHECK(output->stats().fatalErrorSerial == 1);
    output->close(2);
    output.reset();
    item->setParentItem(nullptr);
    item.reset();
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
  }
}

void verifyCallbackSelfReleaseAndWindowReconnect(QQuickWindow& window) {
  std::string error;

  // Failure delivery may release the final public output owner from inside a
  // GuiContext-owned queued callback. State survives the callback tail and
  // QObject destruction remains deferred until Qt unwinds event delivery.
  {
    auto item = std::make_unique<wam::macos::QtGlVideoItem>();
    item->setParentItem(window.contentItem());
    item->setSize(QSizeF(480, 270));
    auto output = wam::macos::NativeQtGlOutput::create(item.get(), &error);
    WAM_CHECK_DETAIL(output != nullptr, error);
    std::atomic<unsigned> failures{0};
    output->setFailureHandler([&](std::string) {
      failures.fetch_add(1, std::memory_order_release);
      output.reset();
    });
    pumpEventsFor(20);
    output->throwInNextAcceptedGuiDrainForTesting();
    WAM_CHECK(output->dispatch(makeFrame(0, 165), &error) ==
              wam::macos::NativeScheduledFrameDispatchResult::Dispatched);
    WAM_CHECK(spinUntil([&] {
      return failures.load(std::memory_order_acquire) == 1 && !output;
    }));
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    auto replacement =
        wam::macos::NativeQtGlOutput::create(item.get(), &error);
    WAM_CHECK_DETAIL(replacement != nullptr, error);
    replacement->close(1);
    replacement.reset();
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    item->setParentItem(nullptr);
    item.reset();
  }

  // The applied-start callback can likewise release the final public owner
  // from an accepted queued drain. State and GuiContext remain valid until the
  // callback unwinds, and a replacement is possible only after deferred
  // QObject deletion clears the item lease.
  {
    auto item = std::make_unique<wam::macos::QtGlVideoItem>();
    item->setParentItem(window.contentItem());
    item->setSize(QSizeF(480, 270));
    auto output = wam::macos::NativeQtGlOutput::create(item.get(), &error);
    WAM_CHECK_DETAIL(output != nullptr, error);
    std::atomic<unsigned> acknowledgments{0};
    bool accepted = false;
    std::thread starter([&] {
      accepted = output->startGeneration(
          1,
          [&](wam::macos::NativeScheduledFrameStartAck) {
            acknowledgments.fetch_add(1, std::memory_order_release);
            output.reset();
          },
          &error);
    });
    starter.join();
    WAM_CHECK_DETAIL(accepted, error);
    WAM_CHECK(spinUntil([&] {
      return acknowledgments.load(std::memory_order_acquire) == 1 &&
             !output;
    }));
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    auto replacement =
        wam::macos::NativeQtGlOutput::create(item.get(), &error);
    WAM_CHECK_DETAIL(replacement != nullptr, error);
    replacement->close(2);
    replacement.reset();
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    item->setParentItem(nullptr);
    item.reset();
  }

  // A windowChanged reconnect allocation failure never crosses the Qt signal.
  // The output terminalizes and keeps the existing observer/lease fail closed.
  {
    auto item = std::make_unique<wam::macos::QtGlVideoItem>();
    item->setParentItem(window.contentItem());
    item->setSize(QSizeF(480, 270));
    auto output = wam::macos::NativeQtGlOutput::create(item.get(), &error);
    WAM_CHECK_DETAIL(output != nullptr, error);
    std::atomic<unsigned> failures{0};
    output->setFailureHandler([&](std::string) {
      failures.fetch_add(1, std::memory_order_release);
    });
    pumpEventsFor(20);
    output->throwNextWindowObservationConnectForTesting();
    item->setParentItem(nullptr);
    item->setParentItem(window.contentItem());
    WAM_CHECK(spinUntil([&] {
      return failures.load(std::memory_order_acquire) == 1;
    }));
    WAM_CHECK(output->stats().fatalErrorSerial == 1);
    WAM_CHECK(output->dispatch(makeFrame(0, 170), &error) ==
              wam::macos::NativeScheduledFrameDispatchResult::Failed);
    output->close(1);
    output.reset();
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    item->setParentItem(nullptr);
    item.reset();
  }
}

void verifyFinalFlushSchedulingFailures(QQuickWindow& window) {
  std::string error;

  // If both off-thread flush queues fail and finalizer functor construction
  // throws, deferred GuiContext destruction remains the exact GUI-thread flush
  // owner. No exception crosses close() or the noexcept custom deleter.
  {
    auto item = std::make_unique<wam::macos::QtGlVideoItem>();
    item->setParentItem(window.contentItem());
    item->setSize(QSizeF(480, 270));
    auto output = wam::macos::NativeQtGlOutput::create(item.get(), &error);
    WAM_CHECK_DETAIL(output != nullptr, error);
    output->failNextGuiInvokeForTesting();
    output->throwNextFinalFlushInvokeForTesting();
    std::thread closer([owned = std::move(output)]() mutable {
      owned->close(1);
      owned.reset();
    });
    closer.join();
    WAM_CHECK(spinUntil([&] {
      return item->stats().acceptedGeneration >= 1;
    }));
    auto replacement =
        wam::macos::NativeQtGlOutput::create(item.get(), &error);
    WAM_CHECK_DETAIL(replacement != nullptr, error);
    replacement->close(item->stats().acceptedGeneration + 1);
    replacement.reset();
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    item->setParentItem(nullptr);
    item.reset();
  }

  // If Qt rejects both final-flush queues and even deferred deletion throws,
  // the complete context is quarantined: the item lease stays true and a
  // replacement adapter is denied rather than risking off-thread destruction
  // or releasing an unflushed retained frame.
  {
    auto item = std::make_unique<wam::macos::QtGlVideoItem>();
    item->setParentItem(window.contentItem());
    item->setSize(QSizeF(480, 270));
    auto output = wam::macos::NativeQtGlOutput::create(item.get(), &error);
    WAM_CHECK_DETAIL(output != nullptr, error);
    output->failNextGuiInvokeForTesting();
    output->failNextFinalFlushInvokeForTesting();
    output->throwNextGuiContextDeleteLaterForTesting();
    std::thread closer([owned = std::move(output)]() mutable {
      owned->close(1);
      owned.reset();
    });
    closer.join();
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    WAM_CHECK(wam::macos::NativeQtGlOutput::create(item.get(), &error) ==
              nullptr);
    WAM_CHECK(error.find("already has a live native output") !=
              std::string::npos);
    item->setParentItem(nullptr);
    item.reset();
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
  }
}

void verifyFailureAfterWorkerCreation(
    QQuickWindow& window, const std::filesystem::path& fixture) {
  std::string error;
  auto item = std::make_unique<wam::macos::QtGlVideoItem>();
  item->setParentItem(window.contentItem());
  item->setSize(QSizeF(480, 270));
  auto bridge = wam::macos::NativeQtGlOutput::create(item.get(), &error);
  WAM_CHECK_DETAIL(bridge != nullptr, error);
  auto controlled = std::make_shared<FailAfterFirstDispatchOutput>(bridge);
  auto pipeline =
      wam::macos::NativeVideoPipeline::createForQtOpenGL(controlled, &error);
  WAM_CHECK_DETAIL(pipeline != nullptr, error);
  WAM_CHECK_DETAIL(pipeline->prepareLocalFileAsync(fixture, 0.0, &error),
                   error);
  auto outcome = waitForPreparation(*pipeline);
  WAM_CHECK(outcome.has_value());
  WAM_CHECK_DETAIL(
      outcome->result == wam::macos::NativeVideoPrepareResult::Ready,
      outcome->error);
  const std::uint64_t preparedGeneration = pipeline->stats().generation;

  std::promise<void> releasePromise;
  auto entered = std::make_shared<std::atomic<bool>>(false);
  wam::macos::NativeVideoPipelineTestAccess::
      setStartPreparedPostWorkerBarrier(
          *pipeline, releasePromise.get_future().share(), entered);
  const auto admittedGeneration = pipeline->startPrepared(&error);
  WAM_CHECK_DETAIL(admittedGeneration.has_value(), error);
  WAM_CHECK(*admittedGeneration == preparedGeneration);
  WAM_CHECK(spinUntil([&] {
    return entered->load(std::memory_order_acquire);
  }, 10000));
  WAM_CHECK(!pipeline->active());
  WAM_CHECK(controlled->stats().dispatchedFrames == 0);

  // Starting is deliberately non-presenting. Inject a terminal output failure
  // after the worker object exists but before Running, then release the test
  // barrier. The failed attempt must advance and flush its generation before
  // retirement; no decoded frame can escape the inert Starting state.
  controlled->failNow();
  releasePromise.set_value();
  WAM_CHECK(spinUntil([&] {
    const auto stats = pipeline->stats();
    return !stats.active && stats.generation == preparedGeneration + 1;
  }, 10000));
  const std::uint64_t invalidatedGeneration = pipeline->stats().generation;
  WAM_CHECK(invalidatedGeneration == preparedGeneration + 1);
  WAM_CHECK(spinUntil([&] {
    return bridge->stats().acceptedGeneration == invalidatedGeneration &&
           item->stats().acceptedGeneration == invalidatedGeneration;
  }, 10000));
  WAM_CHECK(controlled->stats().dispatchedFrames == 0);
  const QColor failedStartPixel = centerPixel(window);
  WAM_CHECK(failedStartPixel.red() <= 4 && failedStartPixel.green() <= 4 &&
            failedStartPixel.blue() <= 4);
  WAM_CHECK(bridge->dispatch(makeFrame(preparedGeneration, 240), &error) ==
            wam::macos::NativeScheduledFrameDispatchResult::Rejected);
  auto failure = pipeline->takeLastError();
  WAM_CHECK(failure.has_value());
  WAM_CHECK(failure->find("injected") != std::string::npos);
  WAM_CHECK(spinUntil([&] { return !pipeline->stats().stopping; }, 10000));

  pipeline.reset();
  bridge.reset();
  controlled.reset();
  item->setParentItem(nullptr);
  item.reset();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
}

void verifyStaleStartAcknowledgmentAfterStop(
    const std::filesystem::path& fixture) {
  std::string error;
  auto output = std::make_shared<RetainedStartAckOutput>();
  auto pipeline =
      wam::macos::NativeVideoPipeline::createForQtOpenGL(output, &error);
  WAM_CHECK_DETAIL(pipeline != nullptr, error);
  WAM_CHECK_DETAIL(pipeline->prepareLocalFileAsync(fixture, 0.0, &error),
                   error);
  auto outcome = waitForPreparation(*pipeline);
  WAM_CHECK(outcome.has_value());
  WAM_CHECK_DETAIL(
      outcome->result == wam::macos::NativeVideoPrepareResult::Ready,
      outcome->error);

  const auto startingGeneration = pipeline->startPrepared(&error);
  WAM_CHECK_DETAIL(startingGeneration.has_value(), error);
  WAM_CHECK(!pipeline->active());
  const auto startingStats = pipeline->stats();
  WAM_CHECK(startingStats.compressedSamplesSubmitted == 0);
  WAM_CHECK(startingStats.dispatchedFrames == 0);
  WAM_CHECK(startingStats.displayLinkTicks == 0);
  WAM_CHECK(!pipeline->seek(1.0).has_value());
  WAM_CHECK(output->stats().acceptedGeneration == *startingGeneration);

  const std::uint64_t stoppedGeneration = pipeline->stop();
  WAM_CHECK(stoppedGeneration == *startingGeneration + 1);
  WAM_CHECK(output->stats().acceptedGeneration == stoppedGeneration);
  output->fireRetainedAck();
  WAM_CHECK(spinUntil([&] { return !pipeline->stats().stopping; }, 10000));
  pumpEventsFor(100);
  const auto stoppedStats = pipeline->stats();
  WAM_CHECK(!stoppedStats.active);
  WAM_CHECK(stoppedStats.generation == stoppedGeneration);
  WAM_CHECK(stoppedStats.compressedSamplesSubmitted == 0);
  WAM_CHECK(stoppedStats.dispatchedFrames == 0);
  WAM_CHECK(stoppedStats.displayLinkTicks == 0);
  WAM_CHECK(output->stats().dispatchedFrames == 0);

  pipeline.reset();
  WAM_CHECK(output->stats().closed);
}

void verifyDirectSchedulerFailureRetires(
    QQuickWindow& window, const std::filesystem::path& fixture) {
  std::string error;
  auto item = std::make_unique<wam::macos::QtGlVideoItem>();
  item->setParentItem(window.contentItem());
  item->setSize(QSizeF(480, 270));
  auto bridge = wam::macos::NativeQtGlOutput::create(item.get(), &error);
  WAM_CHECK_DETAIL(bridge != nullptr, error);
  auto rejecting = std::make_shared<RejectCurrentFrameOutput>(bridge);
  auto pipeline =
      wam::macos::NativeVideoPipeline::createForQtOpenGL(rejecting, &error);
  WAM_CHECK_DETAIL(pipeline != nullptr, error);
  WAM_CHECK_DETAIL(pipeline->prepareLocalFileAsync(fixture, 0.0, &error),
                   error);
  auto outcome = waitForPreparation(*pipeline);
  WAM_CHECK(outcome.has_value());
  WAM_CHECK_DETAIL(
      outcome->result == wam::macos::NativeVideoPrepareResult::Ready,
      outcome->error);
  const auto generation = pipeline->startPrepared(&error);
  WAM_CHECK_DETAIL(generation.has_value(), error);
  // This unpaused clock forces the Running acknowledgment to start the real
  // display link. The injected current-generation Rejected result reports
  // through the pipeline itself, never through the output failure handler.
  std::atomic<bool> updateClock{true};
  std::thread clockUpdater([&] {
    while (updateClock.load(std::memory_order_acquire)) {
      pipeline->updateAudioClock(1.0, false, 1.0);
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  });
  const bool failureRetired = spinUntil([&] {
    const auto stats = pipeline->stats();
    return rejecting->rejections() == 1 && !stats.active &&
           stats.generation == *generation + 1;
  }, 10000);
  const auto failureCheckpoint = pipeline->stats();
  WAM_CHECK_DETAIL(
      failureRetired,
      "rejections=" + std::to_string(rejecting->rejections()) +
          " active=" + std::to_string(failureCheckpoint.active) +
          " generation=" + std::to_string(failureCheckpoint.generation) +
          " expected=" + std::to_string(*generation + 1) +
          " stopping=" + std::to_string(failureCheckpoint.stopping) +
          " ticks=" +
          std::to_string(failureCheckpoint.displayLinkTicks));
  const std::uint64_t invalidatedGeneration = pipeline->stats().generation;
  WAM_CHECK(spinUntil([&] {
    return bridge->stats().acceptedGeneration == invalidatedGeneration &&
           item->stats().acceptedGeneration == invalidatedGeneration &&
           !pipeline->stats().stopping;
  }, 10000));
  const auto retiredStats = pipeline->stats();
  WAM_CHECK(retiredStats.dispatchedFrames == 0);
  WAM_CHECK(rejecting->rejections() == 1);
  auto failure = pipeline->takeLastError();
  WAM_CHECK(failure.has_value());
  WAM_CHECK(failure->find("injected current-generation") !=
            std::string::npos);
  const std::uint64_t stoppedTicks = retiredStats.displayLinkTicks;
  pumpEventsFor(250);
  WAM_CHECK(pipeline->stats().displayLinkTicks == stoppedTicks);
  updateClock.store(false, std::memory_order_release);
  clockUpdater.join();
  const QColor retiredPixel = centerPixel(window);
  WAM_CHECK(retiredPixel.red() <= 4 && retiredPixel.green() <= 4 &&
            retiredPixel.blue() <= 4);
  WAM_CHECK(bridge->dispatch(makeFrame(*generation, 230), &error) ==
            wam::macos::NativeScheduledFrameDispatchResult::Rejected);

  pipeline.reset();
  bridge.reset();
  rejecting.reset();
  item->setParentItem(nullptr);
  item.reset();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::cerr << "usage: native_qt_gl_output_test "
                 "<h264-or-hevc-file|--watchdog-only>\n";
    return EXIT_FAILURE;
  }
  const bool watchdogOnly = std::string(argv[1]) == "--watchdog-only";

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

  const std::filesystem::path fixture =
      watchdogOnly ? std::filesystem::path{} : std::filesystem::path(argv[1]);
  if (!watchdogOnly) {
    verifyFailureDuringPreparedStart(fixture);
  }

  QQuickWindow window;
  window.resize(480, 270);
  window.setColor(Qt::black);
  window.setPersistentSceneGraph(false);
  window.setPersistentGraphics(false);
  auto item = std::make_unique<wam::macos::QtGlVideoItem>();
  item->setParentItem(window.contentItem());
  item->setSize(QSizeF(480, 270));
  window.show();
  window.requestUpdate();
  WAM_CHECK(spinUntil([&] { return window.isSceneGraphInitialized(); }));
  WAM_CHECK(window.rendererInterface()->graphicsApi() ==
            QSGRendererInterface::OpenGL);
  verifyDeferredWatchdogIsStrictlyOnDemand(window);
  if (watchdogOnly) {
    std::cout << "native Qt OpenGL deferred watchdog checks passed\n";
    return EXIT_SUCCESS;
  }

  std::string error;
  auto output = wam::macos::NativeQtGlOutput::create(item.get(), &error);
  WAM_CHECK_DETAIL(output != nullptr, error);
  output->setFailureHandler([](std::string) {});
  WAM_CHECK(output->flush(1, &error));

  for (std::uint8_t luma : {64, 128, 192}) {
    WAM_CHECK(output->dispatch(makeFrame(1, luma), &error) ==
              wam::macos::NativeScheduledFrameDispatchResult::Dispatched);
  }
  const auto coalesced = output->stats();
  WAM_CHECK(coalesced.dispatchedFrames == 3);
  WAM_CHECK(coalesced.coalescedFrames == 2);
  WAM_CHECK(coalesced.deliveredFrames == 0);
  WAM_CHECK(coalesced.deliveryQueued);
  WAM_CHECK(spinUntil([&] {
    const auto stats = output->stats();
    return stats.deliveredFrames == 1 &&
           stats.actuallyRenderedFrames >= 1 &&
           stats.lastRenderedGeneration == 1;
  }));
  const QColor newestPixel = centerPixel(window);
  WAM_CHECK(newestPixel.red() > 185);
  WAM_CHECK(std::abs(newestPixel.red() - newestPixel.green()) <= 3);
  WAM_CHECK(std::abs(newestPixel.red() - newestPixel.blue()) <= 3);
  WAM_CHECK(item->stats().exactSourceIOSurface);
  WAM_CHECK(item->stats().acceleratedContext);

  WAM_CHECK(output->flush(2, &error));
  WAM_CHECK(output->dispatch(makeFrame(1, 200), &error) ==
            wam::macos::NativeScheduledFrameDispatchResult::Rejected);
  WAM_CHECK(output->dispatch(makeFrame(2, 200), &error) ==
            wam::macos::NativeScheduledFrameDispatchResult::Dispatched);
  WAM_CHECK(spinUntil([&] {
    const auto stats = output->stats();
    return stats.deliveredFrames == 2 &&
           stats.lastRenderedGeneration == 2;
  }));
  WAM_CHECK(output->stats().staleFrames >= 1);

  // Equal/lower generations are a controller defect, but still have to clear
  // Qt's already-retained lease. The item advances fail-closed and the bridge
  // resynchronizes its exact generation instead of displaying stale pixels.
  const std::uint64_t deliveredBeforeRejectedFlush =
      output->stats().deliveredFrames;
  WAM_CHECK(!output->flush(2, &error));
  WAM_CHECK(spinUntil([&] {
    return item->stats().acceptedGeneration == 3;
  }));
  WAM_CHECK(output->stats().acceptedGeneration == 3);
  const QColor clearedPixel = centerPixel(window);
  WAM_CHECK(clearedPixel.red() <= 4 && clearedPixel.green() <= 4 &&
            clearedPixel.blue() <= 4);
  WAM_CHECK(output->dispatch(makeFrame(2, 235), &error) ==
            wam::macos::NativeScheduledFrameDispatchResult::Rejected);
  WAM_CHECK(output->stats().deliveredFrames == deliveredBeforeRejectedFlush);

  // A live item permits exactly one adapter. After that adapter is destroyed,
  // a replacement seeds itself from the item's exact accepted generation.
  output->close(4);
  WAM_CHECK(output->dispatch(makeFrame(4, 128), &error) ==
            wam::macos::NativeScheduledFrameDispatchResult::Rejected);
  WAM_CHECK(wam::macos::NativeQtGlOutput::create(item.get(), &error) ==
            nullptr);
  output.reset();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
  auto reusedOutput =
      wam::macos::NativeQtGlOutput::create(item.get(), &error);
  WAM_CHECK_DETAIL(reusedOutput != nullptr, error);
  reusedOutput->setFailureHandler([](std::string) {});
  const std::uint64_t reusedGeneration = item->stats().acceptedGeneration;
  WAM_CHECK(reusedOutput->stats().acceptedGeneration == reusedGeneration);
  WAM_CHECK(reusedOutput->dispatch(makeFrame(reusedGeneration, 180), &error) ==
            wam::macos::NativeScheduledFrameDispatchResult::Dispatched);
  WAM_CHECK(spinUntil([&] {
    return reusedOutput->stats().deliveredFrames == 1 &&
           reusedOutput->stats().lastRenderedGeneration == reusedGeneration;
  }));
  reusedOutput->close(reusedGeneration + 1);
  reusedOutput.reset();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
  item->setParentItem(nullptr);
  item.reset();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 20);

  // A terminal presenter cannot be made apparently healthy by consuming its
  // first-wins error during a failed adapter creation. Both attempts fail;
  // only a successful scene-graph recreation clears lastError and permits a
  // new adapter, which consumes the historical event after proving recovery.
  auto recoverableItem = std::make_unique<wam::macos::QtGlVideoItem>();
  recoverableItem->setParentItem(window.contentItem());
  recoverableItem->setSize(QSizeF(480, 270));
  recoverableItem->failNextImportForTesting();
  recoverableItem->submitFrame(makeFrame(0, 140));
  window.requestUpdate();
  WAM_CHECK(spinUntil([&] {
    const auto stats = recoverableItem->stats();
    return !stats.lastError.isEmpty();
  }));
  WAM_CHECK(recoverableItem->stats().fatalErrorSerial == 0);
  recoverableItem->setParentItem(nullptr);
  recoverableItem.reset();
  window.requestUpdate();
  WAM_CHECK(!window.grabWindow().isNull());

  auto fatalItem = std::make_unique<wam::macos::QtGlVideoItem>();
  fatalItem->setParentItem(window.contentItem());
  fatalItem->setSize(QSizeF(480, 270));
  fatalItem->failAfterRetirementServiceCreationForTesting();
  fatalItem->submitFrame(makeFrame(0, 150));
  window.requestUpdate();
  WAM_CHECK(spinUntil([&] {
    const auto stats = fatalItem->stats();
    return stats.fatalErrorSerial == 1 && !stats.lastError.isEmpty();
  }));
  WAM_CHECK(wam::macos::NativeQtGlOutput::create(fatalItem.get(), &error) ==
            nullptr);
  WAM_CHECK(wam::macos::NativeQtGlOutput::create(fatalItem.get(), &error) ==
            nullptr);
  const auto beforeRecovery = fatalItem->stats();
  fatalItem->setParentItem(nullptr);
  window.requestUpdate();
  WAM_CHECK(!window.grabWindow().isNull());
  fatalItem->setParentItem(window.contentItem());
  fatalItem->setSize(QSizeF(480, 270));
  fatalItem->submitFrame(makeFrame(0, 170));
  window.requestUpdate();
  WAM_CHECK(spinUntil([&] {
    const auto stats = fatalItem->stats();
    return stats.renderedFrames > beforeRecovery.renderedFrames &&
           stats.lastError.isEmpty();
  }));
  auto recoveredOutput =
      wam::macos::NativeQtGlOutput::create(fatalItem.get(), &error);
  WAM_CHECK_DETAIL(recoveredOutput != nullptr, error);
  recoveredOutput->close(fatalItem->stats().acceptedGeneration + 1);
  recoveredOutput.reset();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
  fatalItem->setParentItem(nullptr);
  fatalItem.reset();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 20);

  verifyOffThreadFlushAndFinalOwnerDrop(window);
  verifyTrackedDrawAndInvalidation(window);
  verifyTrackedFailedFrameStillCloses(window);
  verifyTrackedRejectionPrecedesInvalidation(window);
  verifyOffThreadStartAcknowledgment(window);
  verifySameGenerationStartStillAcknowledges(window);
  verifyHiddenLatePresenterFailure(window);
  verifyFailureNotificationCopyRetries(window);
  verifySchedulingAllocationFailures(window);
  verifyCallbackSelfReleaseAndWindowReconnect(window);
  verifyFinalFlushSchedulingFailures(window);
  verifyFailureAfterWorkerCreation(window, fixture);
  verifyStaleStartAcknowledgmentAfterStop(fixture);
  verifyDirectSchedulerFailureRetires(window, fixture);

  auto pipelineItem = std::make_unique<wam::macos::QtGlVideoItem>();
  pipelineItem->setParentItem(window.contentItem());
  pipelineItem->setSize(QSizeF(480, 270));
  auto pipelineOutput =
      wam::macos::NativeQtGlOutput::create(pipelineItem.get(), &error);
  WAM_CHECK_DETAIL(pipelineOutput != nullptr, error);
  auto pipeline = wam::macos::NativeVideoPipeline::createForQtOpenGL(
      pipelineOutput, &error);
  WAM_CHECK_DETAIL(pipeline != nullptr, error);
  WAM_CHECK_DETAIL(pipeline->prepareLocalFileAsync(fixture, 0.0, &error),
                   error);
  auto preparedOutcome = waitForPreparation(*pipeline);
  WAM_CHECK(preparedOutcome.has_value());
  if (preparedOutcome->result ==
          wam::macos::NativeVideoPrepareResult::Unsupported &&
      !VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)) {
    std::cout << "SKIP: hardware H.264 VideoToolbox decode unavailable\n";
    return 77;
  }
  WAM_CHECK_DETAIL(
      preparedOutcome->result == wam::macos::NativeVideoPrepareResult::Ready,
      preparedOutcome->error);
  const auto beforeStart = pipeline->stats();
  WAM_CHECK(beforeStart.outputMode ==
            wam::macos::NativeVideoOutputMode::QtOpenGL);
  WAM_CHECK(beforeStart.prepared);
  WAM_CHECK(!beforeStart.active);
  WAM_CHECK(beforeStart.compressedSamplesRead == 0);
  WAM_CHECK(beforeStart.compressedSamplesSubmitted == 0);
  WAM_CHECK(beforeStart.scheduledFrames == 0);
  WAM_CHECK(beforeStart.dispatchedFrames == 0);
  WAM_CHECK(beforeStart.displayLinkTicks == 0);
  WAM_CHECK(beforeStart.decoder.outputInterop ==
            wam::macos::VideoToolboxOutputInterop::OpenGL);
  WAM_CHECK(preparedOutcome->generation == beforeStart.generation);

  const auto firstGeneration = pipeline->startPrepared(&error);
  WAM_CHECK_DETAIL(firstGeneration.has_value(), error);
  WAM_CHECK(*firstGeneration == preparedOutcome->generation);
  WAM_CHECK(pipelineOutput->stats().acceptedGeneration == *firstGeneration);
  pipeline->updateAudioClock(0.0, true, 1.0);
  WAM_CHECK(spinUntil([&] {
    const auto stats = pipeline->stats();
    return stats.active && stats.hardwareDecode &&
           stats.dispatchedFrames >= 1 &&
           stats.actuallyRenderedFrames >= 1 &&
           stats.scheduledOutput.lastRenderedGeneration == *firstGeneration;
  }, 10000));

  const auto seekGeneration = pipeline->seek(2.017);
  WAM_CHECK(seekGeneration.has_value());
  WAM_CHECK(*seekGeneration == *firstGeneration + 1);
  WAM_CHECK(pipelineOutput->stats().acceptedGeneration == *seekGeneration);
  pipeline->updateAudioClock(2.017, true, 1.0);
  WAM_CHECK(spinUntil([&] {
    const auto stats = pipeline->stats();
    return stats.scheduledOutput.lastRenderedGeneration == *seekGeneration &&
           stats.dispatchedFrames >= 2;
  }, 10000));
  const auto afterSeek = pipeline->stats();
  WAM_CHECK(afterSeek.dispatchedFrames ==
            afterSeek.scheduledOutput.dispatchedFrames);
  WAM_CHECK(afterSeek.presentedFrames == 0);

  const std::uint64_t stoppedGeneration = pipeline->stop();
  WAM_CHECK(stoppedGeneration == *seekGeneration + 1);
  WAM_CHECK(pipelineOutput->stats().acceptedGeneration == stoppedGeneration);
  const std::uint64_t firstOutputStoppedGeneration =
      pipelineOutput->stats().acceptedGeneration;
  WAM_CHECK(!pipeline->active());
  WAM_CHECK(spinUntil([&] { return !pipeline->stats().stopping; }, 10000));

  // Reuse the same pipeline/output for a second preparation. Adapter totals
  // remain lifetime counters, while top-level render passes restart at zero
  // for the new preparation epoch.
  WAM_CHECK_DETAIL(pipeline->prepareLocalFileAsync(fixture, 0.0, &error),
                   error);
  auto secondOutcome = waitForPreparation(*pipeline);
  WAM_CHECK(secondOutcome.has_value());
  WAM_CHECK_DETAIL(
      secondOutcome->result == wam::macos::NativeVideoPrepareResult::Ready,
      secondOutcome->error);
  const auto secondPrepared = pipeline->stats();
  WAM_CHECK(secondOutcome->generation == secondPrepared.generation);
  WAM_CHECK(secondOutcome->generation > *firstGeneration);
  WAM_CHECK(secondOutcome->generation > stoppedGeneration);
  WAM_CHECK(secondOutcome->generation > firstOutputStoppedGeneration);
  WAM_CHECK(pipelineOutput->stats().acceptedGeneration ==
            firstOutputStoppedGeneration);
  WAM_CHECK(secondPrepared.actuallyRenderedFrames == 0);
  WAM_CHECK(secondPrepared.scheduledOutput.actuallyRenderedFrames > 0);
  WAM_CHECK(secondPrepared.compressedSamplesSubmitted == 0);
  const auto secondGeneration = pipeline->startPrepared(&error);
  WAM_CHECK_DETAIL(secondGeneration.has_value(), error);
  WAM_CHECK(*secondGeneration == secondOutcome->generation);
  WAM_CHECK(pipeline->stats().generation == *secondGeneration);
  WAM_CHECK(pipelineOutput->stats().acceptedGeneration == *secondGeneration);
  pipeline->updateAudioClock(0.0, true, 1.0);
  WAM_CHECK(spinUntil([&] {
    const auto stats = pipeline->stats();
    return stats.active && stats.dispatchedFrames >= 1 &&
           stats.actuallyRenderedFrames >= 1 &&
           stats.scheduledOutput.lastRenderedGeneration == *secondGeneration;
  }, 10000));
  pipelineOutput->failNextGuiInvokeForTesting();
  std::uint64_t secondStoppedGeneration = 0;
  std::thread failedQueueStopper([&] {
    secondStoppedGeneration = pipeline->stop();
  });
  failedQueueStopper.join();
  WAM_CHECK(secondStoppedGeneration == *secondGeneration + 1);
  WAM_CHECK(pipelineOutput->stats().closed);
  WAM_CHECK(spinUntil([&] {
    return pipelineItem->stats().acceptedGeneration >=
           secondStoppedGeneration;
  }));
  const QColor failedQueueStopPixel = centerPixel(window);
  WAM_CHECK(failedQueueStopPixel.red() <= 4 &&
            failedQueueStopPixel.green() <= 4 &&
            failedQueueStopPixel.blue() <= 4);
  WAM_CHECK(spinUntil([&] { return !pipeline->stats().stopping; }, 10000));
  pipeline.reset();
  WAM_CHECK(pipelineOutput->stats().closed);

  pipelineItem->setParentItem(nullptr);
  pipelineItem.reset();
  pipelineOutput.reset();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
  std::cout << "native Qt OpenGL scheduled output tests passed\n";
  return EXIT_SUCCESS;
}
