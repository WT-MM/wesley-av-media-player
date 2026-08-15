#include "native_qt_gl_output.hpp"

#include <CoreFoundation/CoreFoundation.h>

#include <QCoreApplication>
#include <QMetaObject>
#include <QPointer>
#include <QQuickWindow>
#include <QThread>
#include <QTimer>
#include <QVariant>

#include <algorithm>
#include <atomic>
#include <limits>
#include <mutex>
#include <new>
#include <optional>
#include <thread>
#include <utility>

namespace wam::macos {
namespace {

constexpr const char* kOutputLeaseProperty =
    "_wam_native_qt_gl_output_lease";
constexpr std::uint64_t kTrackedWakeClosedBit = std::uint64_t{1} << 63U;
constexpr std::uint64_t kTrackedWakeEntryMask = kTrackedWakeClosedBit - 1U;

void assignErrorNoexcept(std::string* error, const char* message) noexcept {
  if (error == nullptr) {
    return;
  }
  try {
    *error = message;
  } catch (...) {
  }
}

void assignErrorNoexcept(std::string* error,
                         const std::string& message) noexcept {
  if (error == nullptr) {
    return;
  }
  try {
    *error = message;
  } catch (...) {
  }
}

void invokeFailureNoexcept(NativeScheduledFrameOutput::FailureHandler handler,
                           std::string message) noexcept {
  if (!handler) {
    return;
  }
  try {
    handler(std::move(message));
  } catch (...) {
  }
}

void signalTrackedWakeNoexcept(NativeTrackedVideoOutputWakeSeam wake) noexcept {
  if (wake.signal != nullptr) {
    wake.signal(wake.context);
  }
}

void ignoreTrackedWake(void*) noexcept {}

}  // namespace

struct NativeQtGlOutput::State
    : public std::enable_shared_from_this<NativeQtGlOutput::State> {
  class GuiContext final : public QObject {
   public:
    GuiContext(
        QtGlVideoItem* item, std::weak_ptr<State> state,
        std::shared_ptr<const std::atomic<std::uint64_t>>
            observedPresenterFatalSerial,
        std::shared_ptr<const std::atomic<std::uint64_t>>
            observedPresenterDrawSequence,
        std::shared_ptr<const std::atomic<std::uint64_t>>
            observedPresenterInvalidationSequence,
        std::shared_ptr<const std::atomic<std::uint64_t>>
            observedPresenterRejectionSequence)
        : item_(item),
          state_(std::move(state)),
          guiThread_(item->thread()),
          fatalErrorSerialToken_(item->fatalErrorSerialToken()),
          renderProgressToken_(item->renderProgressToken()),
          observedPresenterFatalSerial_(
              std::move(observedPresenterFatalSerial)),
          observedPresenterDrawSequence_(
              std::move(observedPresenterDrawSequence)),
          observedPresenterInvalidationSequence_(
              std::move(observedPresenterInvalidationSequence)),
          observedPresenterRejectionSequence_(
              std::move(observedPresenterRejectionSequence)) {}

    // Called only after State::guiContext publishes this object. Render-thread
    // signals may fire immediately after setWindow(), so construction itself
    // must not expose a partially published State.
    void arm() {
      QtGlVideoItem* item = item_.data();
      if (item == nullptr) {
        return;
      }
      deferredSchedulingWatchdog_.setInterval(50);
      deferredSchedulingWatchdog_.setSingleShot(true);
      deferredWatchdogConnection_ = QObject::connect(
          &deferredSchedulingWatchdog_, &QTimer::timeout, this,
          [this] { serviceDeferredWatchdogOnGui(); });
      if (!deferredWatchdogConnection_) {
        throw std::bad_alloc();
      }
      CFRunLoopSourceContext sourceContext{};
      sourceContext.info = this;
      sourceContext.perform = &GuiContext::deferredWatchdogArmSourcePerform;
      deferredWatchdogArmSource_ =
          CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &sourceContext);
      guiRunLoop_ = CFRunLoopGetCurrent();
      if (deferredWatchdogArmSource_ == nullptr || guiRunLoop_ == nullptr) {
        throw std::bad_alloc();
      }
      CFRetain(guiRunLoop_);
      CFRunLoopAddSource(guiRunLoop_, deferredWatchdogArmSource_,
                         kCFRunLoopCommonModes);
      if (!CFRunLoopContainsSource(guiRunLoop_, deferredWatchdogArmSource_,
                                   kCFRunLoopCommonModes)) {
        throw std::bad_alloc();
      }
      // The pre-created timer remains inactive at idle. Render callbacks only
      // signal one pre-created run-loop source when no ordinary
      // observation/poll already owns the edge. Signalling is allocation-free
      // and cross-thread safe; hidden or paused output therefore has no
      // recurring 50 ms wakeup and no notification can be lost to a failed Qt
      // functor allocation.
      QObject::connect(
          item, &QQuickItem::windowChanged, this,
          [this](QQuickWindow* window) { setWindow(window); });
      QObject::connect(item, &QObject::destroyed, this,
                       [weakState = state_] {
                         if (auto state = weakState.lock()) {
                           state->itemDestroyedOnGui();
                         }
                       });
      setWindow(item->window());
    }

    ~GuiContext() override {
      try {
        deferredSchedulingWatchdog_.stop();
      } catch (...) {
      }
      if (deferredWatchdogArmSource_ != nullptr) {
        CFRunLoopSourceInvalidate(deferredWatchdogArmSource_);
        CFRelease(deferredWatchdogArmSource_);
        deferredWatchdogArmSource_ = nullptr;
      }
      if (guiRunLoop_ != nullptr) {
        CFRelease(guiRunLoop_);
        guiRunLoop_ = nullptr;
      }
      try {
        if (afterRenderingConnection_) {
          QObject::disconnect(afterRenderingConnection_);
        }
      } catch (...) {
      }
      if (QtGlVideoItem* item = item_.data()) {
        // close() may be followed immediately by dropping the last adapter
        // owner on a retirement thread. The normal drain holds only weak
        // State, so this GUI-owned context carries the terminal invalidation
        // independently until destruction.
        if (finalFlushRequired_.load(std::memory_order_acquire)) {
          try {
            item->flush(finalFlushGeneration_.load(
                std::memory_order_acquire));
          } catch (...) {
          }
        }
        try {
          item->setProperty(kOutputLeaseProperty, false);
        } catch (...) {
        }
      }
    }

    [[nodiscard]] bool isGuiThread() const noexcept {
      return QThread::currentThread() == guiThread_;
    }

    // This accessor is deliberately confined to GUI callbacks. No pipeline,
    // decoder, display-link, or retirement thread reads the QPointer.
    [[nodiscard]] QtGlVideoItem* itemOnGui() const noexcept {
      return item_.data();
    }

    void requestDeferredWatchdogNoexcept() noexcept {
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
      deferredWatchdogArmRequests_.fetch_add(1,
                                             std::memory_order_relaxed);
#endif
      deferredWatchdogWorkPending_.store(true, std::memory_order_release);
      if (deferredWatchdogActive_.load(std::memory_order_acquire)) {
        return;
      }
      if (isGuiThread()) {
        armDeferredWatchdogOnGui();
        return;
      }
      if (deferredWatchdogArmQueued_.exchange(
              true, std::memory_order_acq_rel)) {
        return;
      }
      if (deferredWatchdogArmSource_ != nullptr && guiRunLoop_ != nullptr &&
          CFRunLoopSourceIsValid(deferredWatchdogArmSource_)) {
        CFRunLoopSourceSignal(deferredWatchdogArmSource_);
        CFRunLoopWakeUp(guiRunLoop_);
        return;
      }
      deferredWatchdogArmQueued_.store(false, std::memory_order_release);
      if (auto state = state_.lock()) {
        state->deferWatchdogSchedulingFailureNoexcept();
      }
    }

#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
    [[nodiscard]] NativeQtGlOutputDeferredWatchdogFacts
    deferredWatchdogFactsForTesting() const noexcept {
      return {
          deferredWatchdogArmRequests_.load(std::memory_order_relaxed),
          deferredWatchdogArms_.load(std::memory_order_relaxed),
          deferredWatchdogWakes_.load(std::memory_order_relaxed),
          deferredWatchdogActive_.load(std::memory_order_acquire),
          deferredWatchdogArmQueued_.load(std::memory_order_acquire),
          false};
    }
#endif

    // These methods touch only atomics and are safe on decoder/retirement
    // threads. The QPointer remains strictly GUI-thread confined.
    void requireFinalFlush(std::uint64_t generation) noexcept {
      std::uint64_t observed =
          finalFlushGeneration_.load(std::memory_order_acquire);
      while (observed < generation &&
             !finalFlushGeneration_.compare_exchange_weak(
                 observed, generation, std::memory_order_acq_rel,
                 std::memory_order_acquire)) {
      }
      finalFlushRequired_.store(true, std::memory_order_release);
    }

    void completeFinalFlush() noexcept {
      finalFlushRequired_.store(false, std::memory_order_release);
    }

    void performRequiredFinalFlushOnGui() noexcept {
      if (!isGuiThread() ||
          !finalFlushRequired_.load(std::memory_order_acquire)) {
        return;
      }
      QtGlVideoItem* item = item_.data();
      if (item == nullptr) {
        finalFlushRequired_.store(false, std::memory_order_release);
        return;
      }
      const std::uint64_t generation =
          finalFlushGeneration_.load(std::memory_order_acquire);
      try {
        item->flush(generation);
        // close() is single-shot, but retain the generation comparison so a
        // future monotonic extension cannot accidentally clear a newer
        // obligation after completing an older one.
        if (finalFlushGeneration_.load(std::memory_order_acquire) ==
            generation) {
          finalFlushRequired_.store(false, std::memory_order_release);
        }
      } catch (...) {
      }
    }

#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
    void throwNextDeferredDeletionForTesting() noexcept {
      throwNextDeferredDeletion_.store(true, std::memory_order_release);
    }
#endif

    void scheduleDeferredDeletionNoexcept() noexcept {
      try {
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
        if (throwNextDeferredDeletion_.exchange(
                false, std::memory_order_acq_rel)) {
          throw std::bad_alloc();
        }
#endif
        deleteLater();
      } catch (...) {
        // Synchronous/off-thread QObject destruction would be unsafe,
        // especially while a final-flush obligation is armed. Deliberately
        // quarantine this complete context for the process lifetime. It owns
        // no FrameLease; only the QObject, output-property lease, and final-
        // flush obligation remain, while QtGlVideoItem safely owns any
        // retained frame.
      }
    }

   private:
    static void deferredWatchdogArmSourcePerform(void* context) noexcept {
      auto* self = static_cast<GuiContext*>(context);
      if (self != nullptr) {
        self->armDeferredWatchdogOnGui();
      }
    }

    void armDeferredWatchdogOnGui() noexcept {
      deferredWatchdogArmQueued_.store(false, std::memory_order_release);
      if (!isGuiThread() ||
          deferredWatchdogActive_.load(std::memory_order_acquire) ||
          !deferredWatchdogWorkPending_.exchange(
              false, std::memory_order_acq_rel)) {
        return;
      }
      try {
        deferredWatchdogActive_.store(true, std::memory_order_release);
        deferredSchedulingWatchdog_.start();
        if (!deferredSchedulingWatchdog_.isActive()) {
          deferredWatchdogActive_.store(false,
                                        std::memory_order_release);
          if (auto state = state_.lock()) {
            state->failSchedulingNoexcept(
                "Qt could not arm native video deferred observation");
          }
          return;
        }
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
        deferredWatchdogArms_.fetch_add(1, std::memory_order_relaxed);
#endif
      } catch (...) {
        deferredWatchdogActive_.store(false, std::memory_order_release);
        if (auto state = state_.lock()) {
          state->failSchedulingNoexcept(
              "Qt could not arm native video deferred observation");
        }
      }
    }

    void serviceDeferredWatchdogOnGui() noexcept {
      try {
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
        deferredWatchdogWakes_.fetch_add(1, std::memory_order_relaxed);
#endif
        // Work requested before this timeout is covered by this service. A
        // request racing after this exchange remains set and causes exactly
        // one rearm below.
        deferredWatchdogWorkPending_.store(false,
                                           std::memory_order_release);
        if (auto state = state_.lock()) {
          state->consumeDeferredSchedulingFailureNoexcept();
          if (state->guiRenderObservationPending.load(
                  std::memory_order_acquire)) {
            state->observePresenterOnGui();
          }
          deferredWatchdogActive_.store(false,
                                        std::memory_order_release);
          if (deferredWatchdogWorkPending_.load(
                  std::memory_order_acquire) ||
              state->guiRenderObservationPending.load(
                  std::memory_order_acquire) ||
              state->deferredWatchdogWorkOutstandingNoexcept()) {
            deferredWatchdogWorkPending_.store(
                true, std::memory_order_release);
            armDeferredWatchdogOnGui();
          }
        } else {
          deferredWatchdogActive_.store(false,
                                        std::memory_order_release);
        }
      } catch (...) {
        deferredWatchdogActive_.store(false, std::memory_order_release);
        if (auto state = state_.lock()) {
          state->failSchedulingNoexcept(
              "native video deferred observation failed");
        }
      }
    }

    void setWindow(QQuickWindow* window) noexcept {
      if (window == nullptr) {
        try {
          if (afterRenderingConnection_) {
            QObject::disconnect(afterRenderingConnection_);
            afterRenderingConnection_ = {};
          }
        } catch (...) {
          reportObservationConnectionFailure();
        }
        return;
      }

      try {
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
        if (auto state = state_.lock();
            state && state->throwNextWindowObservationConnect.exchange(
                         false, std::memory_order_acq_rel)) {
          throw std::bad_alloc();
        }
#endif
        // Establish the replacement before disconnecting the old window.
        // If QObject::connect allocates and throws, the previous render-thread
        // observer remains armed until the bridge fails closed below.
        const QMetaObject::Connection replacement = QObject::connect(
            window, &QQuickWindow::afterRendering, this,
            [weakState = state_,
             fatalErrorSerialToken = fatalErrorSerialToken_,
             renderProgressToken = renderProgressToken_,
             observedPresenterFatalSerial =
                 observedPresenterFatalSerial_,
             observedPresenterDrawSequence =
                 observedPresenterDrawSequence_,
             observedPresenterInvalidationSequence =
                 observedPresenterInvalidationSequence_,
             observedPresenterRejectionSequence =
                 observedPresenterRejectionSequence_] {
              try {
                // This direct render-thread callback reads only bounded
                // atomic mailboxes. Normal redraws do not lock State, touch a
                // QObject/QPointer, sample full presenter stats, allocate, or
                // queue GUI work. A newly published draw, rejection,
                // invalidation, or fatal serial queues one coalesced GUI
                // observation.
                const bool fatalChanged =
                    fatalErrorSerialToken.load() !=
                    observedPresenterFatalSerial->load(
                        std::memory_order_acquire);
                const bool drawChanged = renderProgressToken.drawAfter(
                    observedPresenterDrawSequence->load(
                        std::memory_order_acquire)).has_value();
                const bool invalidationChanged =
                    renderProgressToken.invalidationAfter(
                        observedPresenterInvalidationSequence->load(
                            std::memory_order_acquire)).has_value();
                const bool rejectionChanged =
                    renderProgressToken.rejectionAfter(
                        observedPresenterRejectionSequence->load(
                            std::memory_order_acquire)).has_value();
                if (!fatalChanged && !drawChanged && !invalidationChanged &&
                    !rejectionChanged) {
                  return;
                }
                if (auto state = weakState.lock()) {
                  // Allocation-free render callback: publish one capacity-one
                  // owner wake and leave QObject/diagnostic sampling to the
                  // pre-created GUI watchdog. No queued Qt event is created
                  // from the render thread.
                  state->noticeRenderProgressNoexcept();
                }
              } catch (...) {
                // Never unwind through QQuickWindow::afterRendering. All
                // expected work above is noexcept; this is the outer Qt
                // boundary for an injected or future implementation defect.
              }
            },
            Qt::DirectConnection);
        if (!replacement) {
          reportObservationConnectionFailure();
          return;
        }
        if (afterRenderingConnection_) {
          QObject::disconnect(afterRenderingConnection_);
        }
        afterRenderingConnection_ = replacement;
      } catch (...) {
        reportObservationConnectionFailure();
      }
    }

    void reportObservationConnectionFailure() noexcept {
      try {
        if (auto state = state_.lock()) {
          state->failSchedulingNoexcept(
              "Qt could not connect the native video render observer");
        }
      } catch (...) {
      }
    }

    QPointer<QtGlVideoItem> item_;
    std::weak_ptr<State> state_;
    QThread* guiThread_{nullptr};
    QtGlFatalErrorSerialToken fatalErrorSerialToken_;
    QtGlRenderProgressToken renderProgressToken_;
    std::shared_ptr<const std::atomic<std::uint64_t>>
        observedPresenterFatalSerial_;
    std::shared_ptr<const std::atomic<std::uint64_t>>
        observedPresenterDrawSequence_;
    std::shared_ptr<const std::atomic<std::uint64_t>>
        observedPresenterInvalidationSequence_;
    std::shared_ptr<const std::atomic<std::uint64_t>>
        observedPresenterRejectionSequence_;
    QTimer deferredSchedulingWatchdog_;
    QMetaObject::Connection deferredWatchdogConnection_;
    QMetaObject::Connection afterRenderingConnection_;
    CFRunLoopRef guiRunLoop_{nullptr};
    CFRunLoopSourceRef deferredWatchdogArmSource_{nullptr};
    std::atomic<bool> deferredWatchdogWorkPending_{false};
    std::atomic<bool> deferredWatchdogActive_{false};
    std::atomic<bool> deferredWatchdogArmQueued_{false};
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
    std::atomic<std::uint64_t> deferredWatchdogArmRequests_{0};
    std::atomic<std::uint64_t> deferredWatchdogArms_{0};
    std::atomic<std::uint64_t> deferredWatchdogWakes_{0};
#endif
    std::atomic<std::uint64_t> finalFlushGeneration_{0};
    std::atomic<bool> finalFlushRequired_{false};
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
    std::atomic<bool> throwNextDeferredDeletion_{false};
#endif
  };

  mutable std::mutex mutex;
  std::shared_ptr<GuiContext> guiContext;
  std::optional<FrameLease> pendingFrame;
  QtGlFrameIdentity pendingFrameIdentity{};
  std::optional<std::uint64_t> pendingFlush;
  StartAppliedHandler pendingStartApplied;
  std::uint64_t pendingStartRequestedGeneration{0};
  bool forcePendingFlush{false};
  bool pendingFinalFlush{false};
  FailureHandler failureHandler;
  std::string failureMessage;
  std::uint64_t acceptedGeneration{0};
  std::uint64_t guiAppliedGeneration{0};
  std::uint64_t nextRequestSerial{0};
  std::uint64_t queuedDrainToken{0};
  std::uint64_t dispatchedFrames{0};
  std::uint64_t deliveredFrames{0};
  std::uint64_t coalescedFrames{0};
  std::uint64_t staleFrames{0};
  std::uint64_t rejectedFrames{0};
  std::uint64_t actuallyRenderedFrames{0};
  std::uint64_t presenterAcceptedRenderedFrames{0};
  std::uint64_t attemptAcceptedRenderedFrames{0};
  std::uint64_t attemptAcceptedRenderedBaseline{0};
  std::uint64_t lastRenderedGeneration{0};
  std::uint64_t fatalErrorSerial{0};
  std::uint64_t presenterRenderedBaseline{0};
  std::uint64_t observedPresenterFatalSerial{0};
  QtGlRenderProgressToken presenterRenderProgress;
  std::uint64_t observedPresenterDrawSequence{0};
  std::uint64_t observedPresenterInvalidationSequence{0};
  std::uint64_t observedPresenterRejectionSequence{0};
  std::optional<QtGlDrawEvent> observedDraw;
  std::optional<QtGlGenerationInvalidatedEvent> observedInvalidation;
  std::optional<QtGlFrameRejectedEvent> observedRejection;
  NativeTrackedVideoOutputWakeSeam trackedWake{};
  std::optional<NativeTrackedVideoEvent> trackedEvent;
  NativeTrackedFrameSequence trackedFrame{};
  NativeTrackedFrameSequence lastTrackedFrame{};
  FrameTiming trackedTiming{};
  std::uint64_t trackedGeneration{0};
  std::uint64_t nextTrackedDeliverySequence{0};
  std::uint64_t nextTrackedEventSequence{0};
  std::uint64_t trackedSubmittedFrames{0};
  std::uint64_t trackedDrawnFrames{0};
  std::uint64_t trackedSupersededFrames{0};
  std::uint64_t trackedFlushRetiredGeneration{0};
  std::uint64_t trackedFlushNextGeneration{0};
  std::uint64_t trackedCloseGeneration{0};
  bool trackedFlushPending{false};
  bool trackedClosePending{false};
  bool trackedFlushDone{false};
  bool trackedCloseDone{false};
  bool trackedFatal{false};
  std::atomic<bool> trackedMode{true};
  std::atomic<bool> trackedWakePending{false};
  // One atomic linearizes callback pinning with terminal detachment. A signal
  // CAS-increments only while the high closed bit is clear; close atomically
  // sets that bit and can clear the raw seam only after the low count drains.
  std::atomic<std::uint64_t> trackedWakeGate{0};
  std::atomic<bool> guiRenderObservationPending{false};
  std::shared_ptr<std::atomic<std::uint64_t>>
      observedPresenterFatalSerialAtomic{
          std::make_shared<std::atomic<std::uint64_t>>(0)};
  std::shared_ptr<std::atomic<std::uint64_t>>
      observedPresenterDrawSequenceAtomic{
          std::make_shared<std::atomic<std::uint64_t>>(0)};
  std::shared_ptr<std::atomic<std::uint64_t>>
      observedPresenterInvalidationSequenceAtomic{
          std::make_shared<std::atomic<std::uint64_t>>(0)};
  std::shared_ptr<std::atomic<std::uint64_t>>
      observedPresenterRejectionSequenceAtomic{
          std::make_shared<std::atomic<std::uint64_t>>(0)};
  std::size_t presenterPendingRetirements{0};
  unsigned retirementGracePolls{0};
  bool failureLatched{false};
  bool failureDelivered{false};
  bool failureHandlerActive{false};
  bool attemptBaselinePending{false};
  bool attemptBaselineApplied{false};
  bool transientObservation{false};
  bool closed{false};
  std::atomic<bool> observationArmed{false};
  std::atomic<bool> observationQueued{false};
  std::atomic<bool> observationPollQueued{false};
  enum class DeferredSchedulingFailure : std::uint8_t {
    None,
    ImmediateObservation,
    DeferredWatchdog,
  };
  std::atomic<DeferredSchedulingFailure> deferredSchedulingFailure{
      DeferredSchedulingFailure::None};
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
  std::atomic<bool> failNextFailureNotificationCopy{false};
  std::atomic<bool> failNextGuiInvoke{false};
  std::atomic<unsigned> throwImmediateObservationInvokes{0};
  std::atomic<bool> throwNextGuiDrainInvoke{false};
  std::atomic<bool> throwInNextAcceptedGuiDrain{false};
  std::atomic<bool> throwNextObservationPoll{false};
  std::atomic<bool> throwNextWindowObservationConnect{false};
  std::atomic<bool> failNextFinalFlushInvoke{false};
  std::atomic<bool> throwNextFinalFlushInvoke{false};
#endif

  void updateObservationArmLocked() noexcept {
    observationArmed.store(
        !failureLatched && (!closed || trackedClosePending) &&
            (failureHandlerActive || transientObservation ||
             (trackedMode.load(std::memory_order_relaxed) &&
              (trackedFrame.valid() || trackedEvent.has_value())) ||
             trackedFlushPending || trackedClosePending),
        std::memory_order_release);
  }

  void noticeRenderProgressNoexcept() noexcept {
    if (!observationArmed.load(std::memory_order_acquire)) {
      return;
    }
    guiRenderObservationPending.store(true, std::memory_order_release);
    signalTrackedProgressNoexcept();
    if (!observationQueued.load(std::memory_order_acquire) &&
        !observationPollQueued.load(std::memory_order_acquire)) {
      guiContext->requestDeferredWatchdogNoexcept();
    }
  }

  void deferWatchdogSchedulingFailureNoexcept() noexcept {
    DeferredSchedulingFailure expected = DeferredSchedulingFailure::None;
    (void)deferredSchedulingFailure.compare_exchange_strong(
        expected, DeferredSchedulingFailure::DeferredWatchdog,
        std::memory_order_acq_rel, std::memory_order_acquire);
    signalTrackedProgressNoexcept();
  }

  [[nodiscard]] bool deferredWatchdogWorkOutstandingNoexcept()
      const noexcept {
    return deferredSchedulingFailure.load(std::memory_order_acquire) !=
           DeferredSchedulingFailure::None;
  }

  [[nodiscard]] bool tryPinTrackedWakeNoexcept() noexcept {
    std::uint64_t gate = trackedWakeGate.load(std::memory_order_acquire);
    for (;;) {
      if ((gate & kTrackedWakeClosedBit) != 0 ||
          (gate & kTrackedWakeEntryMask) == kTrackedWakeEntryMask) {
        return false;
      }
      if (trackedWakeGate.compare_exchange_weak(
              gate, gate + 1, std::memory_order_acq_rel,
              std::memory_order_acquire)) {
        return true;
      }
    }
  }

  void unpinTrackedWakeNoexcept() noexcept {
    trackedWakeGate.fetch_sub(1, std::memory_order_release);
  }

  void signalTrackedProgressNoexcept() noexcept {
    if (!tryPinTrackedWakeNoexcept()) {
      return;
    }
    if (trackedMode.load(std::memory_order_acquire) &&
        !trackedWakePending.exchange(true, std::memory_order_acq_rel)) {
      signalTrackedWakeNoexcept(trackedWake);
    }
    unpinTrackedWakeNoexcept();
  }

  void closeTrackedWakeGateNoexcept() noexcept {
    trackedWakeGate.fetch_or(kTrackedWakeClosedBit,
                             std::memory_order_acq_rel);
  }

  [[nodiscard]] bool trackedWakeGateDrainedNoexcept() const noexcept {
    return (trackedWakeGate.load(std::memory_order_acquire) &
            kTrackedWakeEntryMask) == 0;
  }

  [[nodiscard]] bool nextTrackedEventSequenceLocked(
      std::uint64_t* sequence) noexcept {
    if (nextTrackedEventSequence ==
        std::numeric_limits<std::uint64_t>::max()) {
      trackedFatal = true;
      return false;
    }
    *sequence = ++nextTrackedEventSequence;
    return true;
  }

  [[nodiscard]] bool publishTrackedFrameEventLocked(
      NativeTrackedVideoEventKind kind) noexcept {
    if (!trackedFrame.valid() || trackedEvent) {
      return false;
    }
    std::uint64_t sequence = 0;
    if (!nextTrackedEventSequenceLocked(&sequence)) {
      return false;
    }
    trackedEvent.emplace(NativeTrackedVideoEvent{
        kind, sequence, trackedFrame, trackedGeneration, trackedTiming});
    if (kind == NativeTrackedVideoEventKind::FrameDrawn) {
      ++trackedDrawnFrames;
    } else if (kind == NativeTrackedVideoEventKind::FrameSuperseded) {
      ++trackedSupersededFrames;
    }
    return true;
  }

  [[nodiscard]] bool trackedInvalidationObservedLocked(
      std::uint64_t generation) const noexcept {
    return observedInvalidation &&
           observedInvalidation->generation >= generation;
  }

  void queueImmediateObservation() noexcept {
    if (!observationArmed.load(std::memory_order_acquire) ||
        observationQueued.exchange(true, std::memory_order_acq_rel)) {
      return;
    }
    for (unsigned attempt = 0; attempt != 2; ++attempt) {
      bool queued = false;
      try {
        const std::weak_ptr<State> weakState = weak_from_this();
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
        unsigned remaining =
            throwImmediateObservationInvokes.load(std::memory_order_acquire);
        while (remaining != 0 &&
               !throwImmediateObservationInvokes.compare_exchange_weak(
                   remaining, remaining - 1, std::memory_order_acq_rel,
                   std::memory_order_acquire)) {
        }
        if (remaining != 0) {
          throw std::bad_alloc();
        }
#endif
        queued = QMetaObject::invokeMethod(
            guiContext.get(),
            [weakState] {
              try {
                if (auto retained = weakState.lock()) {
                  retained->observationQueued.store(
                      false, std::memory_order_release);
                  retained->observePresenterOnGui();
                }
              } catch (...) {
              }
            },
            Qt::QueuedConnection);
      } catch (...) {
        queued = false;
      }
      if (queued) {
        return;
      }
      // Keep ownership of the coalescing bit across the one bounded retry.
      // Publishing false between attempts would let another afterRendering
      // callback queue a competing observation.
      if (attempt == 0 && observationArmed.load(std::memory_order_acquire)) {
        continue;
      }
      break;
    }
    // Both bounded attempts failed. This method can run inside
    // QQuickWindow::afterRendering, so terminal publication remains atomics-
    // only; the next public/controller call consumes it under State::mutex.
    observationQueued.store(false, std::memory_order_release);
    DeferredSchedulingFailure expected = DeferredSchedulingFailure::None;
    (void)deferredSchedulingFailure.compare_exchange_strong(
        expected, DeferredSchedulingFailure::ImmediateObservation,
        std::memory_order_acq_rel, std::memory_order_acquire);
    observationArmed.store(false, std::memory_order_release);
    guiContext->requestDeferredWatchdogNoexcept();
  }

  [[nodiscard]] std::pair<FailureHandler, std::string>
  takeFailureNotificationLocked() noexcept {
    if (!failureLatched || failureDelivered || !failureHandler) {
      return {};
    }
    try {
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
      if (failNextFailureNotificationCopy.exchange(
              false, std::memory_order_acq_rel)) {
        throw std::bad_alloc();
      }
#endif
      std::pair<FailureHandler, std::string> result{
          failureHandler, failureMessage};
      failureDelivered = true;
      return result;
    } catch (...) {
      return {};
    }
  }

  [[nodiscard]] std::pair<FailureHandler, std::string> latchFailureLocked(
      std::string message) noexcept {
    if (!failureLatched) {
      failureLatched = true;
      try {
        failureMessage = std::move(message);
      } catch (...) {
        try {
          failureMessage = "native Qt OpenGL output failed";
        } catch (...) {
        }
      }
      if (fatalErrorSerial != std::numeric_limits<std::uint64_t>::max()) {
        ++fatalErrorSerial;
      }
      if (trackedFrame.valid() || trackedFlushPending ||
          trackedClosePending || trackedFatal) {
        signalTrackedProgressNoexcept();
      }
    }
    return takeFailureNotificationLocked();
  }

  [[nodiscard]] std::pair<FailureHandler, std::string> latchFailureLocked(
      const char* message) noexcept {
    if (!failureLatched) {
      failureLatched = true;
      try {
        failureMessage = message;
      } catch (...) {
        try {
          failureMessage = "native Qt OpenGL output failed";
        } catch (...) {
        }
      }
      if (fatalErrorSerial != std::numeric_limits<std::uint64_t>::max()) {
        ++fatalErrorSerial;
      }
      if (trackedFrame.valid() || trackedFlushPending ||
          trackedClosePending || trackedFatal) {
        signalTrackedProgressNoexcept();
      }
    }
    return takeFailureNotificationLocked();
  }

  void failSchedulingNoexcept(const char* message) noexcept {
    std::pair<FailureHandler, std::string> notify;
    try {
      {
        std::lock_guard lock(mutex);
        if (closed && !trackedClosePending) {
          return;
        }
        notify = latchFailureLocked(message);
        transientObservation = false;
        updateObservationArmLocked();
      }
      invokeFailureNoexcept(std::move(notify.first),
                            std::move(notify.second));
    } catch (...) {
      // The scheduling path is already unusable. At minimum, disarm the
      // render callback so a secondary exception cannot repeatedly cross a
      // Qt boundary.
      observationArmed.store(false, std::memory_order_release);
    }
  }

  [[nodiscard]] std::pair<FailureHandler, std::string>
  consumeDeferredSchedulingFailureLocked() noexcept {
    switch (deferredSchedulingFailure.exchange(
        DeferredSchedulingFailure::None, std::memory_order_acq_rel)) {
      case DeferredSchedulingFailure::None:
        return {};
      case DeferredSchedulingFailure::ImmediateObservation: {
        auto notify = latchFailureLocked(
            "Qt could not queue native video presenter observation");
        transientObservation = false;
        updateObservationArmLocked();
        return notify;
      }
      case DeferredSchedulingFailure::DeferredWatchdog: {
        auto notify = latchFailureLocked(
            "Qt could not queue native video deferred observation");
        transientObservation = false;
        updateObservationArmLocked();
        return notify;
      }
    }
    auto notify = latchFailureLocked(
        "native Qt OpenGL observation scheduling failed");
    transientObservation = false;
    updateObservationArmLocked();
    return notify;
  }

  void consumeDeferredSchedulingFailureNoexcept() noexcept {
    if (deferredSchedulingFailure.load(std::memory_order_acquire) ==
        DeferredSchedulingFailure::None) {
      return;
    }
    std::pair<FailureHandler, std::string> notify;
    try {
      {
        std::lock_guard lock(mutex);
        notify = consumeDeferredSchedulingFailureLocked();
      }
      invokeFailureNoexcept(std::move(notify.first),
                            std::move(notify.second));
    } catch (...) {
      observationArmed.store(false, std::memory_order_release);
    }
  }

  [[nodiscard]] bool queueDrainLocked(std::string* error) noexcept {
    if (queuedDrainToken != 0) {
      return true;
    }
    ++nextRequestSerial;
    if (nextRequestSerial == 0) {
      ++nextRequestSerial;
    }
    const std::uint64_t token = nextRequestSerial;
    queuedDrainToken = token;
    bool queued = false;
    try {
      const std::weak_ptr<State> weakState = weak_from_this();
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
      if (throwNextGuiDrainInvoke.exchange(false,
                                           std::memory_order_acq_rel)) {
        throw std::bad_alloc();
      }
      if (failNextGuiInvoke.exchange(false, std::memory_order_acq_rel)) {
        queued = false;
      } else
#endif
      {
      queued = QMetaObject::invokeMethod(
          guiContext.get(),
          [weakState, token] {
            if (auto state = weakState.lock()) {
              try {
                state->drainOnGui(token);
              } catch (...) {
                state->failAcceptedDrainCallbackOnGui(token);
              }
            }
          },
          Qt::QueuedConnection);
      }
    } catch (...) {
      queued = false;
    }
    if (queued) {
      return true;
    }
    // No callback owns this token, so it is safe to clear only that token and
    // release the sole pending lease. A newer request can never be erased.
    if (queuedDrainToken == token) {
      queuedDrainToken = 0;
      pendingFrame.reset();
      pendingFrameIdentity = {};
      pendingFlush.reset();
      pendingStartApplied = {};
      pendingStartRequestedGeneration = 0;
      forcePendingFlush = false;
      pendingFinalFlush = false;
    }
    assignErrorNoexcept(error,
                        "Qt rejected the native video GUI delivery request");
    return false;
  }

  void failAcceptedDrainCallbackOnGui(std::uint64_t token) noexcept {
    std::pair<FailureHandler, std::string> notify;
    try {
      {
        std::lock_guard lock(mutex);
        if (queuedDrainToken != token) {
          return;
        }
        queuedDrainToken = 0;
        pendingFrame.reset();
        pendingFrameIdentity = {};
        pendingFlush.reset();
        pendingStartApplied = {};
        pendingStartRequestedGeneration = 0;
        forcePendingFlush = false;
        pendingFinalFlush = false;
        notify = latchFailureLocked(
            "native Qt OpenGL GUI delivery callback failed");
        transientObservation = false;
        updateObservationArmLocked();
      }
      invokeFailureNoexcept(std::move(notify.first),
                            std::move(notify.second));
    } catch (...) {
      observationArmed.store(false, std::memory_order_release);
    }
  }

  [[nodiscard]] bool sampleTrackedRenderProgressLocked() noexcept {
    bool signalTracked = false;
    if (const auto draw = presenterRenderProgress.drawAfter(
            observedPresenterDrawSequence)) {
      observedDraw = *draw;
      observedPresenterDrawSequence = draw->drawSequence;
      observedPresenterDrawSequenceAtomic->store(
          draw->drawSequence, std::memory_order_release);
      if (trackedFrame.valid() &&
          draw->deliverySequence == nextTrackedDeliverySequence &&
          draw->frameSequence == trackedFrame.value &&
          draw->generation == trackedGeneration &&
          CMTimeCompare(draw->presentationTime,
                        trackedTiming.presentationTime) == 0 &&
          CMTimeCompare(draw->duration, trackedTiming.duration) == 0) {
        signalTracked = publishTrackedFrameEventLocked(
            NativeTrackedVideoEventKind::FrameDrawn);
      }
    }
    // A frame-specific rejection is terminal and must win over a concurrently
    // published generation invalidation. Otherwise Superseded could occupy
    // the capacity-one mailbox first and permanently hide the exact failure.
    if (const auto rejection = presenterRenderProgress.rejectionAfter(
            observedPresenterRejectionSequence)) {
      observedRejection = *rejection;
      observedPresenterRejectionSequence = rejection->eventSequence;
      observedPresenterRejectionSequenceAtomic->store(
          rejection->eventSequence, std::memory_order_release);
      if (trackedFrame.valid() &&
          rejection->deliverySequence == nextTrackedDeliverySequence &&
          rejection->frameSequence == trackedFrame.value &&
          rejection->generation == trackedGeneration) {
        trackedFatal = true;
        (void)publishTrackedFrameEventLocked(
            NativeTrackedVideoEventKind::Failed);
        signalTracked = true;
      }
    }
    if (const auto invalidation = presenterRenderProgress.invalidationAfter(
            observedPresenterInvalidationSequence)) {
      observedInvalidation = *invalidation;
      observedPresenterInvalidationSequence =
          invalidation->eventSequence;
      observedPresenterInvalidationSequenceAtomic->store(
          invalidation->eventSequence, std::memory_order_release);
      if (trackedFrame.valid() && !trackedEvent &&
          (trackedFlushPending || trackedClosePending) &&
          invalidation->generation >=
              (trackedClosePending ? trackedCloseGeneration
                                   : trackedFlushNextGeneration)) {
        signalTracked = publishTrackedFrameEventLocked(
                            NativeTrackedVideoEventKind::FrameSuperseded) ||
                        signalTracked;
      }
      signalTracked = trackedFlushPending || trackedClosePending ||
                      signalTracked;
    }
    return signalTracked;
  }

  // Public owner calls can race between a render mailbox publication and
  // QQuickWindow::afterRendering. If the owner consumes the atomic delta
  // first, it must emit the coalesced edge itself; afterRendering will then
  // correctly see no remaining delta. Never invoke the external wake while
  // State::mutex is held.
  void sampleTrackedRenderProgressAndSignalNoexcept() noexcept {
    bool signalTracked = false;
    {
      std::lock_guard lock(mutex);
      signalTracked = sampleTrackedRenderProgressLocked();
    }
    if (signalTracked) {
      signalTrackedProgressNoexcept();
    }
  }

  void samplePresenterLocked(QtGlVideoItem* item,
                             std::pair<FailureHandler, std::string>* notify) {
    const QtGlVideoItemStats presenterStats = item->stats();
    acceptedGeneration =
        std::max(acceptedGeneration, presenterStats.acceptedGeneration);
    guiAppliedGeneration =
        std::max(guiAppliedGeneration, presenterStats.acceptedGeneration);
    actuallyRenderedFrames =
        presenterStats.renderedFrames >= presenterRenderedBaseline
            ? presenterStats.renderedFrames - presenterRenderedBaseline
            : 0;
    presenterAcceptedRenderedFrames =
        presenterStats.acceptedRenderedFrames;
    attemptAcceptedRenderedFrames =
        attemptBaselineApplied &&
                presenterAcceptedRenderedFrames >=
                    attemptAcceptedRenderedBaseline
            ? presenterAcceptedRenderedFrames -
                  attemptAcceptedRenderedBaseline
            : 0;
    lastRenderedGeneration = presenterStats.lastRenderedGeneration;
    presenterPendingRetirements = presenterStats.pendingRetirements;
    const bool signalTracked = sampleTrackedRenderProgressLocked();
    if (presenterStats.fatalErrorSerial == observedPresenterFatalSerial) {
      if (signalTracked) {
        signalTrackedProgressNoexcept();
      }
      return;
    }
    std::string message = "native Qt OpenGL presenter failed";
    if (auto presenterError = item->takeFatalError()) {
      try {
        message = presenterError->toStdString();
      } catch (...) {
      }
    } else if (!presenterStats.lastError.isEmpty()) {
      try {
        message = presenterStats.lastError.toStdString();
      } catch (...) {
      }
    }
    *notify = latchFailureLocked(std::move(message));
    // Publish only after the GUI thread sampled the coherent presenter state
    // and consumed its reason. A render arriving meanwhile may queue one
    // redundant coalesced observation, but it can never suppress a failure.
    observedPresenterFatalSerial = presenterStats.fatalErrorSerial;
    observedPresenterFatalSerialAtomic->store(
        presenterStats.fatalErrorSerial, std::memory_order_release);
    if (signalTracked) {
      signalTrackedProgressNoexcept();
    }
  }

  [[nodiscard]] bool applyFlushOnGuiLocked(
      QtGlVideoItem* item, std::uint64_t generation,
      bool completesFinalFlush,
      std::pair<FailureHandler, std::string>* notify) noexcept {
    try {
      item->flush(generation);
      if (completesFinalFlush) {
        guiContext->completeFinalFlush();
      }
      samplePresenterLocked(item, notify);
      return true;
    } catch (...) {
      *notify = latchFailureLocked(
          "native Qt OpenGL generation invalidation failed");
      return false;
    }
  }

  void observePresenterOnGui() noexcept {
    guiRenderObservationPending.store(false, std::memory_order_release);
    if (!observationArmed.load(std::memory_order_acquire)) {
      return;
    }
    std::pair<FailureHandler, std::string> notify;
    bool pollAgain = false;
    {
      std::lock_guard lock(mutex);
      QtGlVideoItem* item = guiContext->itemOnGui();
      if (item == nullptr) {
        trackedFatal = true;
        notify = latchFailureLocked(
            "native Qt OpenGL video item was destroyed");
      } else {
        try {
          samplePresenterLocked(item, &notify);
        } catch (...) {
          trackedFatal = true;
          notify = latchFailureLocked(
              "native Qt OpenGL presenter telemetry failed");
        }
      }
      if (failureLatched) {
        transientObservation = false;
      } else if (presenterPendingRetirements != 0) {
        transientObservation = true;
        retirementGracePolls = 1;
        pollAgain = true;
      } else if (retirementGracePolls != 0) {
        --retirementGracePolls;
        pollAgain = true;
      } else {
        transientObservation = false;
      }
      updateObservationArmLocked();
      if (trackedFatal) {
        signalTrackedProgressNoexcept();
      }
    }
    invokeFailureNoexcept(std::move(notify.first),
                          std::move(notify.second));
    if (pollAgain) {
      scheduleObservationPollOnGui();
    }
  }

  void scheduleObservationPollOnGui() noexcept {
    if (!observationArmed.load(std::memory_order_acquire) ||
        observationPollQueued.exchange(true, std::memory_order_acq_rel)) {
      return;
    }
    try {
      const std::weak_ptr<State> weakState = weak_from_this();
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
      if (throwNextObservationPoll.exchange(false,
                                             std::memory_order_acq_rel)) {
        throw std::bad_alloc();
      }
#endif
      QTimer::singleShot(50, guiContext.get(), [weakState] {
        try {
          if (auto state = weakState.lock()) {
            state->observationPollQueued.store(
                false, std::memory_order_release);
            state->observePresenterOnGui();
          }
        } catch (...) {
        }
      });
    } catch (...) {
      observationPollQueued.store(false, std::memory_order_release);
      failSchedulingNoexcept(
          "Qt could not queue native video presenter polling");
    }
  }

  void itemDestroyedOnGui() noexcept {
    std::pair<FailureHandler, std::string> notify;
    {
      std::lock_guard lock(mutex);
      pendingFrame.reset();
      pendingFrameIdentity = {};
      pendingFlush.reset();
      pendingStartApplied = {};
      pendingStartRequestedGeneration = 0;
      forcePendingFlush = false;
      pendingFinalFlush = false;
      observationArmed.store(false, std::memory_order_release);
      observationPollQueued.store(false, std::memory_order_release);
      notify =
          latchFailureLocked("native Qt OpenGL video item was destroyed");
      trackedFatal = true;
      signalTrackedProgressNoexcept();
    }
    invokeFailureNoexcept(std::move(notify.first),
                          std::move(notify.second));
  }

  void drainOnGui(std::uint64_t token) {
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
    if (throwInNextAcceptedGuiDrain.exchange(
            false, std::memory_order_acq_rel)) {
      throw std::bad_alloc();
    }
#endif
    std::pair<FailureHandler, std::string> notify;
    StartAppliedHandler startApplied;
    std::optional<NativeScheduledFrameStartAck> startAck;
    bool schedulePoll = false;
    {
      std::lock_guard lock(mutex);
      if (queuedDrainToken != token) {
        return;
      }
      queuedDrainToken = 0;
      std::optional<std::uint64_t> flushGeneration = pendingFlush;
      pendingFlush.reset();
      startApplied = std::move(pendingStartApplied);
      const std::uint64_t startRequestedGeneration =
          pendingStartRequestedGeneration;
      pendingStartRequestedGeneration = 0;
      const bool forceFlush = forcePendingFlush;
      forcePendingFlush = false;
      const bool finalFlush = pendingFinalFlush;
      pendingFinalFlush = false;
      std::optional<FrameLease> frame = std::move(pendingFrame);
      pendingFrame.reset();
      const QtGlFrameIdentity frameIdentity = pendingFrameIdentity;
      pendingFrameIdentity = {};

      QtGlVideoItem* item = guiContext->itemOnGui();
      if (item == nullptr) {
        notify = latchFailureLocked(
            "native Qt OpenGL video item was destroyed");
      } else {
        // No Qt/pipeline callback is registered under this mutex. Keeping the
        // short flush+submit pair locked prevents seek/stop from slipping
        // between them, while all QQuickItem calls remain on the GUI thread.
        if (flushGeneration &&
            (forceFlush || startApplied ||
             *flushGeneration > guiAppliedGeneration)) {
          if (applyFlushOnGuiLocked(item, *flushGeneration, finalFlush,
                                    &notify)) {
            if (startApplied &&
                startRequestedGeneration == *flushGeneration) {
              attemptAcceptedRenderedBaseline =
                  presenterAcceptedRenderedFrames;
              attemptAcceptedRenderedFrames = 0;
              attemptBaselinePending = false;
              attemptBaselineApplied = true;
              startAck.emplace(NativeScheduledFrameStartAck{
                  startRequestedGeneration, acceptedGeneration,
                  presenterAcceptedRenderedFrames});
            }
            transientObservation = true;
            updateObservationArmLocked();
            retirementGracePolls = 1;
            schedulePoll = true;
          }
        }
        if (frame) {
          const std::uint64_t frameGeneration = frame->timing().generation;
          if (!closed && frameGeneration == acceptedGeneration &&
              frameGeneration == guiAppliedGeneration) {
            try {
              item->submitTrackedFrame(std::move(*frame), frameIdentity);
              ++deliveredFrames;
              transientObservation = true;
              updateObservationArmLocked();
              retirementGracePolls = 1;
              schedulePoll = true;
            } catch (...) {
              notify = latchFailureLocked(
                  "native Qt OpenGL frame delivery failed");
            }
          } else {
            ++staleFrames;
          }
        }
        try {
          samplePresenterLocked(item, &notify);
        } catch (...) {
          notify = latchFailureLocked(
              "native Qt OpenGL presenter telemetry failed");
        }
      }
    }
    invokeFailureNoexcept(std::move(notify.first),
                          std::move(notify.second));
    if (startApplied && startAck) {
      try {
        startApplied(*startAck);
      } catch (...) {
      }
    }
    if (schedulePoll) {
      scheduleObservationPollOnGui();
    }
  }
};

NativeQtGlOutput::NativeQtGlOutput(std::shared_ptr<State> state) noexcept
    : state_(std::move(state)) {}

NativeQtGlOutput::~NativeQtGlOutput() {
  // Disable future raw wake entry before detaching the immutable seam. A wake
  // callback is contractually wait-free, so premature destruction may wait
  // only for an already-entered callback; the render thread never waits here.
  if (state_) {
    state_->closeTrackedWakeGateNoexcept();
    while (!state_->trackedWakeGateDrainedNoexcept()) {
      std::this_thread::yield();
    }
    std::lock_guard lock(state_->mutex);
    state_->trackedWake = {};
  }
}

std::shared_ptr<NativeQtGlOutput> NativeQtGlOutput::create(
    QtGlVideoItem* item, std::string* error) {
  auto output = createTracked(
      item, NativeTrackedVideoOutputWakeSeam{ignoreTrackedWake, nullptr},
      error);
  if (output) {
    std::lock_guard lock(output->state_->mutex);
    output->state_->trackedMode.store(false, std::memory_order_release);
  }
  return output;
}

std::shared_ptr<NativeQtGlOutput> NativeQtGlOutput::createTracked(
    QtGlVideoItem* item, NativeTrackedVideoOutputWakeSeam wake,
    std::string* error) {
  if (error != nullptr) {
    error->clear();
  }
  if (item == nullptr) {
    if (error != nullptr) {
      *error = "a Qt OpenGL video item is required";
    }
    return nullptr;
  }
  if (wake.signal == nullptr) {
    if (error != nullptr) {
      *error = "a tracked native video wake signal is required";
    }
    return nullptr;
  }
  if (QCoreApplication::instance() == nullptr ||
      QThread::currentThread() != item->thread()) {
    if (error != nullptr) {
      *error = "native Qt OpenGL output must be created on the item's GUI "
               "thread";
    }
    return nullptr;
  }
  if (item->property(kOutputLeaseProperty).toBool()) {
    if (error != nullptr) {
      *error = "the Qt OpenGL video item already has a live native output";
    }
    return nullptr;
  }

  auto state = std::make_shared<State>();
  state->trackedWake = wake;
  QtGlVideoItemStats baseline = item->stats();
  if (baseline.fatalErrorSerial != 0 && !baseline.lastError.isEmpty()) {
    if (error != nullptr) {
      *error = "native Qt OpenGL item is still terminal: " +
               baseline.lastError.toStdString();
    }
    return nullptr;
  }
  if (baseline.fatalErrorSerial != 0) {
    // A cleared lastError is the presenter's recovery acknowledgement after
    // scene-graph recreation. Only then consume the historical first-wins
    // event so a later fatal can increment the serial and be observed.
    (void)item->takeFatalError();
  }
  const QtGlVideoItemStats confirmed = item->stats();
  if (!confirmed.lastError.isEmpty() ||
      confirmed.fatalErrorSerial != baseline.fatalErrorSerial) {
    if (error != nullptr) {
      *error = "native Qt OpenGL item became terminal during output "
               "creation";
    }
    return nullptr;
  }
  baseline = confirmed;
  item->setProperty(kOutputLeaseProperty, true);
  state->acceptedGeneration = baseline.acceptedGeneration;
  state->guiAppliedGeneration = baseline.acceptedGeneration;
  state->presenterRenderedBaseline = baseline.renderedFrames;
  state->presenterAcceptedRenderedFrames =
      baseline.acceptedRenderedFrames;
  state->observedPresenterFatalSerial = baseline.fatalErrorSerial;
  state->observedPresenterFatalSerialAtomic->store(
      baseline.fatalErrorSerial, std::memory_order_release);
  state->presenterRenderProgress = item->renderProgressToken();
  state->observedPresenterDrawSequence = baseline.lastDrawSequence;
  state->observedPresenterDrawSequenceAtomic->store(
      baseline.lastDrawSequence, std::memory_order_release);
  state->observedPresenterInvalidationSequence =
      baseline.renderInvalidationSequence;
  state->observedPresenterInvalidationSequenceAtomic->store(
      baseline.renderInvalidationSequence, std::memory_order_release);
  state->observedPresenterRejectionSequence =
      baseline.renderRejectionSequence;
  state->observedPresenterRejectionSequenceAtomic->store(
      baseline.renderRejectionSequence, std::memory_order_release);
  auto deleter = [](State::GuiContext* context) noexcept {
    // Always defer destruction, including on the GUI thread. An arbitrary
    // output callback may drop the last State while Qt is delivering an event
    // to this context; synchronous QObject deletion would invalidate the
    // active receiver stack. deleteLater() also marshals foreign-thread final
    // release back to the context's GUI thread.
    context->scheduleDeferredDeletionNoexcept();
  };
  try {
    state->guiContext = std::shared_ptr<State::GuiContext>(
        new State::GuiContext(
            item, state, state->observedPresenterFatalSerialAtomic,
            state->observedPresenterDrawSequenceAtomic,
            state->observedPresenterInvalidationSequenceAtomic,
            state->observedPresenterRejectionSequenceAtomic),
        deleter);
    state->guiContext->arm();
  } catch (...) {
    item->setProperty(kOutputLeaseProperty, false);
    throw;
  }
  return std::shared_ptr<NativeQtGlOutput>(
      new NativeQtGlOutput(std::move(state)));
}

NativeScheduledFrameDispatchResult NativeQtGlOutput::dispatch(
    FrameLease frame, std::string* error) noexcept {
  const std::shared_ptr<State> state = state_;
  state->consumeDeferredSchedulingFailureNoexcept();
  if (error != nullptr) {
    error->clear();
  }
  if (!frame) {
    assignErrorNoexcept(error, "native Qt OpenGL output received no frame");
    return NativeScheduledFrameDispatchResult::Rejected;
  }

  std::pair<FailureHandler, std::string> notify;
  NativeScheduledFrameDispatchResult result =
      NativeScheduledFrameDispatchResult::Dispatched;
  {
    std::lock_guard lock(state->mutex);
    if (state->trackedMode.load(std::memory_order_acquire)) {
      ++state->rejectedFrames;
      assignErrorNoexcept(
          error, "legacy native video dispatch is disabled in tracked mode");
      return NativeScheduledFrameDispatchResult::Rejected;
    }
    if (state->closed) {
      ++state->rejectedFrames;
      assignErrorNoexcept(error, "native Qt OpenGL output is closed");
      return NativeScheduledFrameDispatchResult::Rejected;
    }
    if (state->failureLatched) {
      ++state->rejectedFrames;
      assignErrorNoexcept(error, state->failureMessage);
      return NativeScheduledFrameDispatchResult::Failed;
    }
    if (frame.timing().generation != state->acceptedGeneration) {
      ++state->staleFrames;
      assignErrorNoexcept(error,
                          "native Qt OpenGL frame generation is stale");
      return NativeScheduledFrameDispatchResult::Rejected;
    }
    const bool coalesced = state->pendingFrame.has_value();
    state->pendingFrame = std::move(frame);
    if (!state->queueDrainLocked(error)) {
      ++state->rejectedFrames;
      notify = state->latchFailureLocked(
          "Qt rejected the native video GUI delivery request");
      result = NativeScheduledFrameDispatchResult::Failed;
    } else {
      ++state->dispatchedFrames;
      if (coalesced) {
        ++state->coalescedFrames;
      }
    }
  }
  invokeFailureNoexcept(std::move(notify.first),
                        std::move(notify.second));
  return result;
}

bool NativeQtGlOutput::startGeneration(
    std::uint64_t generation, StartAppliedHandler applied,
    std::string* error) noexcept {
  if (!applied) {
    assignErrorNoexcept(error,
                        "native Qt OpenGL startup requires an applied callback");
    return false;
  }
  return flushImpl(generation, std::move(applied), error);
}

bool NativeQtGlOutput::flush(std::uint64_t nextGeneration,
                             std::string* error) noexcept {
  return flushImpl(nextGeneration, {}, error);
}

bool NativeQtGlOutput::flushImpl(std::uint64_t nextGeneration,
                                 StartAppliedHandler startApplied,
                                 std::string* error) noexcept {
  // Arbitrary failure/start callbacks below may release the last public
  // NativeQtGlOutput owner. Keep State alive independently and never
  // dereference this again after that first callback boundary.
  const std::shared_ptr<State> state = state_;
  state->consumeDeferredSchedulingFailureNoexcept();
  if (error != nullptr) {
    error->clear();
  }
  std::pair<FailureHandler, std::string> notify;
  std::optional<NativeScheduledFrameStartAck> startAck;
  bool success = true;
  bool schedulePoll = false;
  {
    std::lock_guard lock(state->mutex);
    if (state->closed) {
      assignErrorNoexcept(error, "native Qt OpenGL output is closed");
      return false;
    }
    if (state->failureLatched) {
      assignErrorNoexcept(error, state->failureMessage);
      success = false;
    }
    if (startApplied && state->pendingStartApplied) {
      assignErrorNoexcept(error,
                          "native Qt OpenGL startup flush is already pending");
      return false;
    }
    const bool forceFailClosed =
        nextGeneration <= state->acceptedGeneration;
    if (forceFailClosed) {
      success = false;
      if (!state->failureLatched) {
        assignErrorNoexcept(
            error, nextGeneration < state->acceptedGeneration
                       ? "native Qt OpenGL flush generation regressed"
                       : "native Qt OpenGL generation was already flushed");
      }
    } else {
      state->acceptedGeneration = nextGeneration;
    }
    if (forceFailClosed && state->acceptedGeneration ==
                               std::numeric_limits<std::uint64_t>::max()) {
      state->closed = true;
    }
    state->pendingFrame.reset();
    state->pendingFrameIdentity = {};
    if (!startApplied) {
      // A seek/stop supersedes a not-yet-applied startup request. Its callback
      // must never publish Running after the newer invalidation was admitted.
      state->pendingStartApplied = {};
      state->pendingStartRequestedGeneration = 0;
    }
    state->transientObservation = true;
    state->updateObservationArmLocked();
    if (!success && startApplied) {
      startApplied = {};
    }

    if (state->guiContext->isGuiThread()) {
      // Controller-originated start/seek calls invalidate the retained Qt
      // frame synchronously. No blocking cross-thread invoke is ever used.
      state->pendingFlush.reset();
      state->forcePendingFlush = false;
      QtGlVideoItem* item = state->guiContext->itemOnGui();
      if (item == nullptr) {
        notify = state->latchFailureLocked(
            "native Qt OpenGL video item was destroyed");
        assignErrorNoexcept(error, state->failureMessage);
        success = false;
      } else {
        if (state->applyFlushOnGuiLocked(item, nextGeneration, false,
                                          &notify)) {
          if (startApplied) {
            state->attemptAcceptedRenderedBaseline =
                state->presenterAcceptedRenderedFrames;
            state->attemptAcceptedRenderedFrames = 0;
            state->attemptBaselinePending = false;
            state->attemptBaselineApplied = true;
            startAck.emplace(NativeScheduledFrameStartAck{
                nextGeneration, state->acceptedGeneration,
                state->presenterAcceptedRenderedFrames});
          }
          state->updateObservationArmLocked();
          state->retirementGracePolls = 1;
          schedulePoll = true;
          if (forceFailClosed && state->acceptedGeneration ==
                                     std::numeric_limits<std::uint64_t>::max()) {
            state->closed = true;
          }
        } else {
          assignErrorNoexcept(error, state->failureMessage);
          success = false;
        }
      }
    } else {
      state->pendingFlush = nextGeneration;
      state->forcePendingFlush = forceFailClosed;
      if (startApplied) {
        state->pendingStartRequestedGeneration = nextGeneration;
        state->pendingStartApplied = std::move(startApplied);
      }
      if (!state->queueDrainLocked(error)) {
        notify = state->latchFailureLocked(
            "Qt rejected the native video generation flush");
        success = false;
      }
    }
  }
  invokeFailureNoexcept(std::move(notify.first),
                        std::move(notify.second));
  if (startApplied && startAck) {
    try {
      startApplied(*startAck);
    } catch (...) {
    }
  }
  if (schedulePoll) {
    state->scheduleObservationPollOnGui();
  }
  return success;
}

void NativeQtGlOutput::close(std::uint64_t finalGeneration) noexcept {
  const std::shared_ptr<State> state = state_;
  state->consumeDeferredSchedulingFailureNoexcept();
  std::pair<FailureHandler, std::string> notify;
  {
    std::lock_guard lock(state->mutex);
    if (state->closed) {
      return;
    }
    state->closed = true;
    state->acceptedGeneration =
        std::max(state->acceptedGeneration, finalGeneration);
    state->pendingFrame.reset();
    state->pendingFrameIdentity = {};
    state->pendingStartApplied = {};
    state->pendingStartRequestedGeneration = 0;
    state->updateObservationArmLocked();

    if (state->guiContext->isGuiThread()) {
      state->pendingFlush.reset();
      state->forcePendingFlush = false;
      if (QtGlVideoItem* item = state->guiContext->itemOnGui()) {
        // close() is a terminal invalidation, so even an exhausted/equal
        // generation must clear Qt's retained lease. QtGlVideoItem treats the
        // repeated value fail-closed and never reopens that timeline.
        (void)state->applyFlushOnGuiLocked(
            item, state->acceptedGeneration, false, &notify);
      }
    } else {
      state->guiContext->requireFinalFlush(state->acceptedGeneration);
      state->pendingFlush = state->acceptedGeneration;
      state->forcePendingFlush = true;
      state->pendingFinalFlush = true;
      std::string ignoredError;
      if (!state->queueDrainLocked(&ignoredError)) {
        notify = state->latchFailureLocked(
            "Qt rejected the final native video generation flush");
      }
      // Queue this after the ordinary drain. If State survives, that drain
      // applies and disarms the obligation; if State dies, this bounded strong
      // GUI callback becomes the terminal invalidation owner.
      bool finalizerQueued = false;
      try {
        const std::shared_ptr<State::GuiContext> finalizer =
            state->guiContext;
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
        if (state->throwNextFinalFlushInvoke.exchange(
                false, std::memory_order_acq_rel)) {
          throw std::bad_alloc();
        }
        if (!state->failNextFinalFlushInvoke.exchange(
                false, std::memory_order_acq_rel))
#endif
        {
          finalizerQueued = QMetaObject::invokeMethod(
              finalizer.get(),
              [finalizer] { finalizer->performRequiredFinalFlushOnGui(); },
              Qt::QueuedConnection);
        }
      } catch (...) {
        finalizerQueued = false;
      }
      if (!finalizerQueued) {
        auto finalizerNotify = state->latchFailureLocked(
            "Qt rejected the final native video flush owner");
        if (!notify.first) {
          notify = std::move(finalizerNotify);
        }
      }
    }
  }
  invokeFailureNoexcept(std::move(notify.first),
                        std::move(notify.second));
}

void NativeQtGlOutput::setFailureHandler(FailureHandler handler) noexcept {
  // The installed or already-latched handler is arbitrary and may release the
  // last public output owner while this call is delivering it.
  const std::shared_ptr<State> state = state_;
  std::pair<FailureHandler, std::string> notify;
  bool sampleImmediately = false;
  {
    std::lock_guard lock(state->mutex);
    const bool wasActive = state->failureHandlerActive;
    try {
      state->failureHandler = std::move(handler);
    } catch (...) {
      state->failureHandler = {};
    }
    state->failureHandlerActive = static_cast<bool>(state->failureHandler);
    state->failureDelivered = false;
    notify = state->consumeDeferredSchedulingFailureLocked();
    if (!wasActive && state->failureHandlerActive) {
      // The next startGeneration GUI application establishes the exact
      // presenter-side baseline for this attempt. Old redraws before that
      // linearization can never inflate the new attempt.
      state->attemptBaselinePending = true;
      state->attemptBaselineApplied = false;
      state->attemptAcceptedRenderedBaseline =
          state->presenterAcceptedRenderedFrames;
      state->attemptAcceptedRenderedFrames = 0;
    }
    state->updateObservationArmLocked();
    sampleImmediately = state->failureHandlerActive &&
                        !state->failureLatched && !state->closed;
    if (!notify.first) {
      notify = state->takeFailureNotificationLocked();
    }
  }
  invokeFailureNoexcept(std::move(notify.first),
                        std::move(notify.second));
  if (sampleImmediately) {
    state->queueImmediateObservation();
  }
}

NativeScheduledFrameOutputStats NativeQtGlOutput::stats() const noexcept {
  const std::shared_ptr<State> state = state_;
  state->consumeDeferredSchedulingFailureNoexcept();
  std::lock_guard lock(state->mutex);
  NativeScheduledFrameOutputStats result;
  result.closed = state->closed;
  result.deliveryQueued = state->queuedDrainToken != 0;
  result.acceptedGeneration = state->acceptedGeneration;
  result.dispatchedFrames = state->dispatchedFrames;
  result.deliveredFrames = state->deliveredFrames;
  result.coalescedFrames = state->coalescedFrames;
  result.staleFrames = state->staleFrames;
  result.rejectedFrames = state->rejectedFrames;
  result.actuallyRenderedFrames = state->actuallyRenderedFrames;
  result.acceptedRenderedFrames =
      state->presenterAcceptedRenderedFrames;
  result.attemptAcceptedRenderedFrames =
      state->attemptAcceptedRenderedFrames;
  result.lastRenderedGeneration = state->lastRenderedGeneration;
  result.fatalErrorSerial = state->fatalErrorSerial;
  return result;
}

NativeTrackedVideoCapacity NativeQtGlOutput::capacity(
    std::uint64_t generation) const noexcept {
  const std::shared_ptr<State> state = state_;
  state->trackedWakePending.store(false, std::memory_order_release);
  state->sampleTrackedRenderProgressAndSignalNoexcept();
  std::lock_guard lock(state->mutex);
  if (!state->trackedMode.load(std::memory_order_acquire)) {
    return NativeTrackedVideoCapacity::Failed;
  }
  if (state->failureLatched || state->trackedFatal) {
    return NativeTrackedVideoCapacity::Failed;
  }
  if (state->closed || state->trackedClosePending) {
    return NativeTrackedVideoCapacity::Failed;
  }
  if (generation != state->acceptedGeneration ||
      generation != state->guiAppliedGeneration) {
    return NativeTrackedVideoCapacity::StaleGeneration;
  }
  return state->trackedFrame.valid() || state->trackedEvent ||
                 state->trackedFlushPending
             ? NativeTrackedVideoCapacity::Backpressure
             : NativeTrackedVideoCapacity::Available;
}

NativeTrackedVideoSubmitStatus NativeQtGlOutput::submit(
    const FrameLease& frame, NativeTrackedFrameSequence sequence,
    std::string* error) noexcept {
  const std::shared_ptr<State> state = state_;
  state->trackedWakePending.store(false, std::memory_order_release);
  state->consumeDeferredSchedulingFailureNoexcept();
  state->sampleTrackedRenderProgressAndSignalNoexcept();
  if (error != nullptr) {
    error->clear();
  }
  if (!frame || !sequence.valid()) {
    assignErrorNoexcept(error,
                        "tracked native video submission is invalid");
    return NativeTrackedVideoSubmitStatus::Failed;
  }
  const FrameTiming& timing = frame.timing();
  if (timing.generation == 0 ||
      !CMTIME_IS_NUMERIC(timing.presentationTime) ||
      !CMTIME_IS_NUMERIC(timing.duration) ||
      CMTimeCompare(timing.presentationTime, kCMTimeZero) < 0 ||
      CMTimeCompare(timing.duration, kCMTimeZero) <= 0) {
    assignErrorNoexcept(error,
                        "tracked native video timing is invalid");
    return NativeTrackedVideoSubmitStatus::Failed;
  }
  FrameLease retained(frame);
  if (!retained || retained.pixelBuffer() != frame.pixelBuffer()) {
    assignErrorNoexcept(
        error, "tracked native video accounting token could not be cloned");
    return NativeTrackedVideoSubmitStatus::Failed;
  }
  std::pair<FailureHandler, std::string> notify;
  NativeTrackedVideoSubmitStatus result =
      NativeTrackedVideoSubmitStatus::Accepted;
  {
    std::lock_guard lock(state->mutex);
    if (!state->trackedMode.load(std::memory_order_acquire) ||
        state->failureLatched ||
        state->trackedFatal || state->closed) {
      assignErrorNoexcept(error, state->failureMessage.empty()
                                    ? "tracked native video output failed"
                                    : state->failureMessage);
      return NativeTrackedVideoSubmitStatus::Failed;
    }
    if (frame.timing().generation != state->acceptedGeneration ||
        frame.timing().generation != state->guiAppliedGeneration) {
      assignErrorNoexcept(error,
                          "tracked native video generation is stale");
      return NativeTrackedVideoSubmitStatus::StaleGeneration;
    }
    if (state->trackedFrame.valid() || state->trackedEvent ||
        state->trackedFlushPending || state->trackedClosePending) {
      return NativeTrackedVideoSubmitStatus::Backpressure;
    }
    if (state->lastTrackedFrame.valid() &&
        sequence.value <= state->lastTrackedFrame.value) {
      state->trackedFatal = true;
      notify = state->latchFailureLocked(
          "native video frame sequence repeated or regressed");
      assignErrorNoexcept(error, state->failureMessage);
      result = NativeTrackedVideoSubmitStatus::Failed;
    } else if (state->nextTrackedDeliverySequence ==
               std::numeric_limits<std::uint64_t>::max()) {
      state->trackedFatal = true;
      notify = state->latchFailureLocked(
          "native video delivery sequence exhausted");
      assignErrorNoexcept(error, state->failureMessage);
      result = NativeTrackedVideoSubmitStatus::Failed;
    } else {
      ++state->nextTrackedDeliverySequence;
      state->trackedFrame = sequence;
      state->lastTrackedFrame = sequence;
      state->trackedTiming = frame.timing();
      state->trackedGeneration = frame.timing().generation;
      state->pendingFrame = std::move(retained);
      state->pendingFrameIdentity = QtGlFrameIdentity{
          state->nextTrackedDeliverySequence, sequence.value};
      if (!state->queueDrainLocked(error)) {
        state->trackedFrame = {};
        state->trackedTiming = {};
        state->trackedGeneration = 0;
        state->pendingFrameIdentity = {};
        state->trackedFatal = true;
        notify = state->latchFailureLocked(
            "Qt rejected tracked native video delivery");
        result = NativeTrackedVideoSubmitStatus::Failed;
      } else {
        ++state->trackedSubmittedFrames;
        state->transientObservation = true;
        state->updateObservationArmLocked();
      }
    }
  }
  invokeFailureNoexcept(std::move(notify.first),
                        std::move(notify.second));
  return result;
}

std::optional<NativeTrackedVideoEvent> NativeQtGlOutput::takeEvent()
    noexcept {
  const std::shared_ptr<State> state = state_;
  state->trackedWakePending.store(false, std::memory_order_release);
  state->consumeDeferredSchedulingFailureNoexcept();
  std::optional<NativeTrackedVideoEvent> result;
  bool signalTrackedProgress = false;
  {
    std::lock_guard lock(state->mutex);
    if (!state->trackedMode.load(std::memory_order_acquire)) {
      return std::nullopt;
    }
    signalTrackedProgress = state->sampleTrackedRenderProgressLocked();
    result = std::move(state->trackedEvent);
    state->trackedEvent.reset();
    if (result && result->frameSequence.valid()) {
      state->trackedFrame = {};
      state->trackedTiming = {};
      state->trackedGeneration = 0;
    }
    signalTrackedProgress = state->trackedFlushPending ||
                            state->trackedClosePending ||
                            signalTrackedProgress;
    state->updateObservationArmLocked();
  }
  if (signalTrackedProgress) {
    state->signalTrackedProgressNoexcept();
  }
  return result;
}

NativeTrackedVideoOutputProgress NativeQtGlOutput::flushProgress(
    std::uint64_t retiredGeneration,
    std::uint64_t nextGeneration) noexcept {
  const std::shared_ptr<State> state = state_;
  state->trackedWakePending.store(false, std::memory_order_release);
  state->consumeDeferredSchedulingFailureNoexcept();
  state->sampleTrackedRenderProgressAndSignalNoexcept();
  bool mustApply = false;
  {
    std::lock_guard lock(state->mutex);
    if (!state->trackedMode.load(std::memory_order_acquire) ||
        state->failureLatched ||
        state->trackedFatal || state->closed ||
        nextGeneration == 0 || nextGeneration <= retiredGeneration) {
      return NativeTrackedVideoOutputProgress::Failed;
    }
    if (state->trackedFlushDone &&
        state->trackedFlushRetiredGeneration == retiredGeneration &&
        state->trackedFlushNextGeneration == nextGeneration) {
      return NativeTrackedVideoOutputProgress::Done;
    }
    if (state->trackedFlushPending) {
      if (state->trackedFlushRetiredGeneration != retiredGeneration ||
          state->trackedFlushNextGeneration != nextGeneration) {
        return NativeTrackedVideoOutputProgress::StaleGeneration;
      }
    } else {
      if (retiredGeneration != state->acceptedGeneration) {
        return NativeTrackedVideoOutputProgress::StaleGeneration;
      }
      state->trackedFlushPending = true;
      state->trackedFlushDone = false;
      state->trackedFlushRetiredGeneration = retiredGeneration;
      state->trackedFlushNextGeneration = nextGeneration;
      mustApply = true;
      state->transientObservation = true;
      state->updateObservationArmLocked();
    }
  }
  if (mustApply) {
    std::string ignored;
    if (!flushImpl(nextGeneration, {}, &ignored)) {
      std::lock_guard lock(state->mutex);
      state->trackedFatal = true;
      return NativeTrackedVideoOutputProgress::Failed;
    }
    if (state->guiContext->isGuiThread()) {
      state->observePresenterOnGui();
    }
  }
  state->sampleTrackedRenderProgressAndSignalNoexcept();
  {
    std::lock_guard lock(state->mutex);
    if (state->trackedFrame.valid() || state->trackedEvent ||
        !state->trackedInvalidationObservedLocked(nextGeneration)) {
      state->updateObservationArmLocked();
      return NativeTrackedVideoOutputProgress::Quiescing;
    }
    state->trackedFlushPending = false;
    state->trackedFlushDone = true;
    state->updateObservationArmLocked();
  }
  return NativeTrackedVideoOutputProgress::Done;
}

NativeTrackedVideoOutputProgress NativeQtGlOutput::closeProgress(
    std::uint64_t finalGeneration) noexcept {
  const std::shared_ptr<State> state = state_;
  state->trackedWakePending.store(false, std::memory_order_release);
  state->consumeDeferredSchedulingFailureNoexcept();
  state->sampleTrackedRenderProgressAndSignalNoexcept();
  bool mustApply = false;
  {
    std::lock_guard lock(state->mutex);
    if (!state->trackedMode.load(std::memory_order_acquire)) {
      return NativeTrackedVideoOutputProgress::Failed;
    }
    if (state->trackedCloseDone) {
      if (state->trackedCloseGeneration != finalGeneration) {
        return NativeTrackedVideoOutputProgress::StaleGeneration;
      }
      state->closeTrackedWakeGateNoexcept();
      if (!state->trackedWakeGateDrainedNoexcept()) {
        return NativeTrackedVideoOutputProgress::Quiescing;
      }
      state->trackedWake = {};
      return NativeTrackedVideoOutputProgress::Done;
    }
    // trackedFatal is historical admission failure, not a teardown veto.
    // Terminal close must still invalidate the exact final generation and
    // retire every retained lease so the router can safely enter fallback.
    if (finalGeneration == 0 ||
        (!state->trackedClosePending &&
         finalGeneration <= state->acceptedGeneration)) {
      return NativeTrackedVideoOutputProgress::Failed;
    }
    if (state->trackedClosePending) {
      if (state->trackedCloseGeneration != finalGeneration) {
        return NativeTrackedVideoOutputProgress::StaleGeneration;
      }
    } else {
      state->trackedClosePending = true;
      state->trackedCloseDone = false;
      state->trackedCloseGeneration = finalGeneration;
      mustApply = true;
      state->transientObservation = true;
      state->updateObservationArmLocked();
    }
  }
  if (mustApply) {
    close(finalGeneration);
    if (state->guiContext->isGuiThread()) {
      state->observePresenterOnGui();
    }
  }
  state->sampleTrackedRenderProgressAndSignalNoexcept();
  {
    std::lock_guard lock(state->mutex);
    if (state->failureLatched || state->trackedFrame.valid() ||
        state->trackedEvent ||
        !state->trackedInvalidationObservedLocked(finalGeneration)) {
      return state->failureLatched
                 ? NativeTrackedVideoOutputProgress::Failed
                 : NativeTrackedVideoOutputProgress::Quiescing;
    }
    // No render/GUI callback can publish tracked progress after terminal
    // invalidation; detach the external raw wake context before Done.
    state->closeTrackedWakeGateNoexcept();
    if (!state->trackedWakeGateDrainedNoexcept()) {
      state->updateObservationArmLocked();
      return NativeTrackedVideoOutputProgress::Quiescing;
    }
    state->trackedWake = {};
    // A terminal invalidation supersedes any arm/seek flush only after the
    // stronger final-generation render proof above. Keep trackedFatal as a
    // historical diagnostic, but leave no lifecycle work outstanding.
    state->trackedFlushPending = false;
    state->trackedFlushDone = false;
    state->trackedFlushRetiredGeneration = 0;
    state->trackedFlushNextGeneration = 0;
    state->trackedClosePending = false;
    state->trackedCloseDone = true;
    state->updateObservationArmLocked();
  }
  return NativeTrackedVideoOutputProgress::Done;
}

NativeTrackedVideoOutputFacts NativeQtGlOutput::facts() const noexcept {
  const std::shared_ptr<State> state = state_;
  state->consumeDeferredSchedulingFailureNoexcept();
  state->sampleTrackedRenderProgressAndSignalNoexcept();
  std::lock_guard lock(state->mutex);
  NativeTrackedVideoOutputFacts result;
  if (!state->trackedMode.load(std::memory_order_acquire)) {
    result.fatal = true;
    return result;
  }
  result.generation = state->acceptedGeneration;
  result.admittedFrame = state->trackedFrame;
  result.submittedFrames = state->trackedSubmittedFrames;
  result.drawnFrames = state->trackedDrawnFrames;
  result.supersededFrames = state->trackedSupersededFrames;
  result.lastEventSequence = state->nextTrackedEventSequence;
  result.retainedFrames = state->trackedFrame.valid() ? 1U : 0U;
  result.eventPending = state->trackedEvent.has_value();
  result.invalidationPending =
      state->trackedFlushPending || state->trackedClosePending;
  result.closed = state->closed;
  result.fatal = state->failureLatched || state->trackedFatal;
  return result;
}

#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
void NativeQtGlOutput::failNextFailureNotificationCopyForTesting() noexcept {
  state_->failNextFailureNotificationCopy.store(
      true, std::memory_order_release);
}


void NativeQtGlOutput::failNextGuiInvokeForTesting() noexcept {
  state_->failNextGuiInvoke.store(true, std::memory_order_release);
}

void NativeQtGlOutput::throwNextImmediateObservationInvokeForTesting()
    noexcept {
  state_->throwImmediateObservationInvokes.store(1,
                                                  std::memory_order_release);
}

void NativeQtGlOutput::throwNextTwoImmediateObservationInvokesForTesting()
    noexcept {
  state_->throwImmediateObservationInvokes.store(2,
                                                  std::memory_order_release);
}

void NativeQtGlOutput::throwNextGuiDrainInvokeForTesting() noexcept {
  state_->throwNextGuiDrainInvoke.store(true, std::memory_order_release);
}

void NativeQtGlOutput::throwInNextAcceptedGuiDrainForTesting() noexcept {
  state_->throwInNextAcceptedGuiDrain.store(true,
                                            std::memory_order_release);
}

void NativeQtGlOutput::throwNextObservationPollForTesting() noexcept {
  state_->throwNextObservationPoll.store(true, std::memory_order_release);
}

void NativeQtGlOutput::throwNextWindowObservationConnectForTesting()
    noexcept {
  state_->throwNextWindowObservationConnect.store(
      true, std::memory_order_release);
}

void NativeQtGlOutput::failNextFinalFlushInvokeForTesting() noexcept {
  state_->failNextFinalFlushInvoke.store(true, std::memory_order_release);
}

void NativeQtGlOutput::throwNextFinalFlushInvokeForTesting() noexcept {
  state_->throwNextFinalFlushInvoke.store(true, std::memory_order_release);
}

void NativeQtGlOutput::throwNextGuiContextDeleteLaterForTesting() noexcept {
  state_->guiContext->throwNextDeferredDeletionForTesting();
}

bool NativeQtGlOutput::immediateObservationQueuedForTesting()
    const noexcept {
  return state_->observationQueued.load(std::memory_order_acquire);
}

bool NativeQtGlOutput::observationPollQueuedForTesting() const noexcept {
  return state_->observationPollQueued.load(std::memory_order_acquire);
}

NativeQtGlOutputDeferredWatchdogFacts
NativeQtGlOutput::deferredWatchdogFactsForTesting() const noexcept {
  NativeQtGlOutputDeferredWatchdogFacts result =
      state_->guiContext->deferredWatchdogFactsForTesting();
  result.renderObservationPending =
      state_->guiRenderObservationPending.load(std::memory_order_acquire);
  return result;
}

void NativeQtGlOutput::noticeRenderProgressForTesting() noexcept {
  state_->noticeRenderProgressNoexcept();
}

void NativeQtGlOutput::holdPinnedTrackedWakeForTesting(
    std::atomic<bool>* entered, std::atomic<bool>* release) noexcept {
  if (entered == nullptr || release == nullptr ||
      !state_->tryPinTrackedWakeNoexcept()) {
    return;
  }
  entered->store(true, std::memory_order_release);
  while (!release->load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }
  state_->unpinTrackedWakeNoexcept();
}
#endif

}  // namespace wam::macos
