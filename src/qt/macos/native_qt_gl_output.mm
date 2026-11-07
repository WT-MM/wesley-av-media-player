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
#include <string_view>
#include <thread>
#include <utility>

namespace wam::macos {
namespace {

constexpr const char* kOutputLeaseProperty =
    "_wam_native_qt_gl_output_lease";

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
      // The lease may already have been handed back at the exact retirement
      // boundary (see releaseOutputLeaseOnRetirementNoexcept). A successor can
      // then already own the item, so a retired context must not flush it or
      // clear a lease it no longer holds.
      if (leaseHeld_.load(std::memory_order_acquire)) {
        if (QtGlVideoItem* item = item_.data()) {
          // close() may be followed immediately by dropping the last adapter
          // owner on a retirement thread. The normal drain holds only weak
          // State, so this GUI-owned context carries the terminal
          // invalidation independently until destruction.
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
        leaseHeld_.store(false, std::memory_order_release);
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
#if defined(WAM_NATIVE_TEST_SEAMS)
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

#if defined(WAM_NATIVE_TEST_SEAMS)
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

#if defined(WAM_NATIVE_TEST_SEAMS)
    void throwNextDeferredDeletionForTesting() noexcept {
      throwNextDeferredDeletion_.store(true, std::memory_order_release);
    }
#endif

    // Exact lease handoff. The last adapter owner has just been dropped, so
    // this context is retired: no further State exists to arm a drain, a
    // start, or another flush. The QObject itself still has to die through
    // the event loop, but keeping the item's output lease alive until that
    // deferred deletion runs would deny an immediate in-process replacement
    // adapter -- exactly the second open of a reopen. Hand the lease back
    // here instead, and only once every obligation this context still owes
    // the item has been discharged in order:
    //   * off the GUI thread nothing may be handed back, because the
    //     terminal invalidation is still owed and only the destructor (or a
    //     queued finalizer) can apply it on the item's thread;
    //   * on the GUI thread the owed final flush is applied first, so the
    //     item is invalidated before any successor can observe it, and the
    //     lease is released only if that obligation actually cleared.
    // A context that does not release here keeps leaseHeld_ set and stays the
    // lease owner through destruction, so retirement accounting is unchanged.
    void releaseOutputLeaseOnRetirementNoexcept() noexcept {
      if (!leaseHeld_.load(std::memory_order_acquire) || !isGuiThread()) {
        return;
      }
      performRequiredFinalFlushOnGui();
      if (finalFlushRequired_.load(std::memory_order_acquire)) {
        return;
      }
      QtGlVideoItem* item = item_.data();
      if (item != nullptr) {
        try {
          item->setProperty(kOutputLeaseProperty, false);
        } catch (...) {
          return;
        }
      }
      leaseHeld_.store(false, std::memory_order_release);
    }

    void scheduleDeferredDeletionNoexcept() noexcept {
      releaseOutputLeaseOnRetirementNoexcept();
      try {
#if defined(WAM_NATIVE_TEST_SEAMS)
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
#if defined(WAM_NATIVE_TEST_SEAMS)
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
#if defined(WAM_NATIVE_TEST_SEAMS)
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
#if defined(WAM_NATIVE_TEST_SEAMS)
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
#if defined(WAM_NATIVE_TEST_SEAMS)
    std::atomic<std::uint64_t> deferredWatchdogArmRequests_{0};
    std::atomic<std::uint64_t> deferredWatchdogArms_{0};
    std::atomic<std::uint64_t> deferredWatchdogWakes_{0};
#endif
    std::atomic<std::uint64_t> finalFlushGeneration_{0};
    std::atomic<bool> finalFlushRequired_{false};
    // Set at construction because createTracked only publishes a GuiContext
    // after it has taken the item's output lease, and cleared exactly once by
    // whichever of the retirement handoff or the destructor hands it back.
    std::atomic<bool> leaseHeld_{true};
#if defined(WAM_NATIVE_TEST_SEAMS)
    std::atomic<bool> throwNextDeferredDeletion_{false};
#endif
  };

  mutable std::mutex mutex;
  std::shared_ptr<GuiContext> guiContext;
  std::optional<FrameLease> pendingFrame;
  QtGlFrameIdentity pendingFrameIdentity{};
  // A generation flush waiting for the GUI drain. Advance applies only past
  // the GUI's generation; Forced applies even at or below it (a fail-closed
  // flush); Final is close()'s terminal flush.
  struct PendingFlush {
    enum class Kind : std::uint8_t { Advance, Forced, Final };
    std::uint64_t generation;
    Kind kind;
  };
  std::optional<PendingFlush> pendingFlush;
  std::string failureMessage;
  std::uint64_t acceptedGeneration{0};
  std::uint64_t guiAppliedGeneration{0};
  std::uint64_t nextRequestSerial{0};
  std::uint64_t queuedDrainToken{0};
  std::uint64_t observedPresenterFatalSerial{0};
  QtGlRenderProgressToken presenterRenderProgress;
  std::uint64_t observedPresenterDrawSequence{0};
  std::uint64_t observedPresenterInvalidationSequence{0};
  std::uint64_t observedPresenterRejectionSequence{0};
  std::optional<QtGlDrawEvent> observedDraw;
  std::optional<QtGlGenerationInvalidatedEvent> observedInvalidation;
  std::optional<QtGlFrameRejectedEvent> observedRejection;
  // The tracked mailbox, lifecycle and wake seam. Its retirement ledger
  // (tracked.retiredGeneration) is deliberately not seeded from the item:
  // acceptedGeneration inherits the item's cross-adapter history so a
  // successor can never display stale pixels, but the tracked consumer's
  // ledger is per-session and starts its first arm from 0. Comparing an arm
  // against the inherited item history instead would fail the first arm of a
  // second in-process open on a reused item.
  NativeTrackedOutputProtocol tracked;
  std::uint64_t nextTrackedDeliverySequence{0};
  // Coalesces signals between owner calls; each owner entry clears it.
  std::atomic<bool> trackedWakePending{false};
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
  // FrameRejected: the tracked admission path failed (a rejected frame, a
  // refused delivery, an exhausted sequence) but terminal close may still
  // prove invalidation. Failed: a latched failure, which vetoes close.
  enum class Health : std::uint8_t { Live, FrameRejected, Failed };
  Health health{Health::Live};
  bool transientObservation{false};
  bool closed{false};
  std::atomic<bool> observationArmed{false};
  std::atomic<bool> observationPollQueued{false};
  // Set from the render thread when the deferred watchdog could not be armed;
  // the next owner call latches it as a failure under State::mutex.
  std::atomic<bool> deferredSchedulingFailed{false};
#if defined(WAM_NATIVE_TEST_SEAMS)
  std::atomic<bool> failNextGuiInvoke{false};
  std::atomic<bool> throwNextGuiDrainInvoke{false};
  std::atomic<bool> throwInNextAcceptedGuiDrain{false};
  std::atomic<bool> throwNextObservationPoll{false};
  std::atomic<bool> throwNextWindowObservationConnect{false};
  std::atomic<bool> failNextFinalFlushInvoke{false};
  std::atomic<bool> throwNextFinalFlushInvoke{false};
#endif

  void updateObservationArmLocked() noexcept {
    observationArmed.store(
        health != Health::Failed && (!closed || tracked.closing()) &&
            (transientObservation || tracked.frameOutstanding() ||
             tracked.pendingInvalidation()),
        std::memory_order_release);
  }

  void noticeRenderProgressNoexcept() noexcept {
    if (!observationArmed.load(std::memory_order_acquire)) {
      return;
    }
    guiRenderObservationPending.store(true, std::memory_order_release);
    signalTrackedProgressNoexcept();
    if (!observationPollQueued.load(std::memory_order_acquire)) {
      guiContext->requestDeferredWatchdogNoexcept();
    }
  }

  void deferWatchdogSchedulingFailureNoexcept() noexcept {
    deferredSchedulingFailed.store(true, std::memory_order_release);
    signalTrackedProgressNoexcept();
  }

  [[nodiscard]] bool deferredWatchdogWorkOutstandingNoexcept()
      const noexcept {
    return deferredSchedulingFailed.load(std::memory_order_acquire);
  }

  void signalTrackedProgressNoexcept() noexcept {
    if (!tracked.wakeGate.tryPin()) {
      return;
    }
    if (!trackedWakePending.exchange(true, std::memory_order_acq_rel) &&
        tracked.wake.signal != nullptr) {
      tracked.wake.signal(tracked.wake.context);
    }
    tracked.wakeGate.unpin();
  }

  [[nodiscard]] bool publishTrackedFrameEventLocked(
      NativeTrackedVideoEventKind kind) noexcept {
    bool sequenceExhausted = false;
    const bool published = tracked.publish(kind, &sequenceExhausted);
    if (sequenceExhausted) {
      rejectTrackedLocked();
    }
    return published;
  }

  void rejectTrackedLocked() noexcept {
    if (health == Health::Live) {
      health = Health::FrameRejected;
    }
  }

  [[nodiscard]] bool trackedUsableLocked() const noexcept {
    return health == Health::Live && !closed;
  }

  [[nodiscard]] bool trackedGenerationCurrentLocked(
      std::uint64_t generation) const noexcept {
    return generation == acceptedGeneration &&
           generation == guiAppliedGeneration;
  }

  [[nodiscard]] bool trackedInvalidationObservedLocked(
      std::uint64_t generation) const noexcept {
    return observedInvalidation &&
           observedInvalidation->generation >= generation;
  }

  void latchFailureLocked(std::string_view message) noexcept {
    if (health != Health::Failed) {
      const bool rejected = health == Health::FrameRejected;
      health = Health::Failed;
      try {
        failureMessage = message;
      } catch (...) {
        try {
          failureMessage = "native Qt OpenGL output failed";
        } catch (...) {
        }
      }
      if (tracked.frame.valid() || tracked.pendingInvalidation() ||
          rejected) {
        signalTrackedProgressNoexcept();
      }
    }
  }

  void failSchedulingNoexcept(const char* message) noexcept {
    try {
      std::lock_guard lock(mutex);
      if (closed && !tracked.closing()) {
        return;
      }
      latchFailureLocked(message);
      transientObservation = false;
      updateObservationArmLocked();
    } catch (...) {
      // The scheduling path is already unusable. At minimum, disarm the
      // render callback so a secondary exception cannot repeatedly cross a
      // Qt boundary.
      observationArmed.store(false, std::memory_order_release);
    }
  }

  void consumeDeferredSchedulingFailureNoexcept() noexcept {
    if (!deferredSchedulingFailed.load(std::memory_order_acquire)) {
      return;
    }
    try {
      std::lock_guard lock(mutex);
      if (deferredSchedulingFailed.exchange(false,
                                            std::memory_order_acq_rel)) {
        latchFailureLocked(
            "Qt could not queue native video deferred observation");
        transientObservation = false;
        updateObservationArmLocked();
      }
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
#if defined(WAM_NATIVE_TEST_SEAMS)
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
    }
    assignErrorNoexcept(error,
                        "Qt rejected the native video GUI delivery request");
    return false;
  }

  void failAcceptedDrainCallbackOnGui(std::uint64_t token) noexcept {
    try {
      std::lock_guard lock(mutex);
      if (queuedDrainToken != token) {
        return;
      }
      queuedDrainToken = 0;
      pendingFrame.reset();
      pendingFrameIdentity = {};
      pendingFlush.reset();
      latchFailureLocked("native Qt OpenGL GUI delivery callback failed");
      transientObservation = false;
      updateObservationArmLocked();
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
      if (tracked.frame.valid() &&
          draw->deliverySequence == nextTrackedDeliverySequence &&
          draw->frameSequence == tracked.frame.value &&
          draw->generation == tracked.frameGeneration &&
          CMTimeCompare(draw->presentationTime,
                        tracked.frameTiming.presentationTime) == 0 &&
          CMTimeCompare(draw->duration, tracked.frameTiming.duration) == 0) {
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
      if (tracked.frame.valid() &&
          rejection->deliverySequence == nextTrackedDeliverySequence &&
          rejection->frameSequence == tracked.frame.value &&
          rejection->generation == tracked.frameGeneration) {
        rejectTrackedLocked();
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
      const auto pending = tracked.pendingInvalidation();
      if (tracked.frame.valid() && !tracked.event && pending &&
          invalidation->generation >= *pending) {
        signalTracked = publishTrackedFrameEventLocked(
                            NativeTrackedVideoEventKind::FrameSuperseded) ||
                        signalTracked;
      }
      signalTracked = pending.has_value() || signalTracked;
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

  void samplePresenterLocked(QtGlVideoItem* item) {
    const QtGlVideoItemStats presenterStats = item->stats();
    acceptedGeneration =
        std::max(acceptedGeneration, presenterStats.acceptedGeneration);
    guiAppliedGeneration =
        std::max(guiAppliedGeneration, presenterStats.acceptedGeneration);
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
    latchFailureLocked(std::move(message));
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

  [[nodiscard]] bool applyFlushOnGuiLocked(QtGlVideoItem* item,
                                           std::uint64_t generation,
                                           bool completesFinalFlush) noexcept {
    try {
      item->flush(generation);
      if (completesFinalFlush) {
        guiContext->completeFinalFlush();
      }
      samplePresenterLocked(item);
      return true;
    } catch (...) {
      latchFailureLocked(
          "native Qt OpenGL generation invalidation failed");
      return false;
    }
  }

  void observePresenterOnGui() noexcept {
    guiRenderObservationPending.store(false, std::memory_order_release);
    if (!observationArmed.load(std::memory_order_acquire)) {
      return;
    }
    bool pollAgain = false;
    {
      std::lock_guard lock(mutex);
      QtGlVideoItem* item = guiContext->itemOnGui();
      if (item == nullptr) {
        rejectTrackedLocked();
        latchFailureLocked("native Qt OpenGL video item was destroyed");
      } else {
        try {
          samplePresenterLocked(item);
        } catch (...) {
          rejectTrackedLocked();
          latchFailureLocked(
              "native Qt OpenGL presenter telemetry failed");
        }
      }
      if (health == Health::Failed) {
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
      if (health != Health::Live) {
        signalTrackedProgressNoexcept();
      }
    }
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
#if defined(WAM_NATIVE_TEST_SEAMS)
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
    std::lock_guard lock(mutex);
    pendingFrame.reset();
    pendingFrameIdentity = {};
    pendingFlush.reset();
    observationArmed.store(false, std::memory_order_release);
    observationPollQueued.store(false, std::memory_order_release);
    latchFailureLocked("native Qt OpenGL video item was destroyed");
    signalTrackedProgressNoexcept();
  }

  void drainOnGui(std::uint64_t token) {
#if defined(WAM_NATIVE_TEST_SEAMS)
    if (throwInNextAcceptedGuiDrain.exchange(
            false, std::memory_order_acq_rel)) {
      throw std::bad_alloc();
    }
#endif
    bool schedulePoll = false;
    {
      std::lock_guard lock(mutex);
      if (queuedDrainToken != token) {
        return;
      }
      queuedDrainToken = 0;
      const std::optional<PendingFlush> flush = std::exchange(pendingFlush, {});
      std::optional<FrameLease> frame = std::move(pendingFrame);
      pendingFrame.reset();
      const QtGlFrameIdentity frameIdentity = pendingFrameIdentity;
      pendingFrameIdentity = {};

      QtGlVideoItem* item = guiContext->itemOnGui();
      if (item == nullptr) {
        latchFailureLocked("native Qt OpenGL video item was destroyed");
      } else {
        // No Qt/pipeline callback is registered under this mutex. Keeping the
        // short flush+submit pair locked prevents seek/stop from slipping
        // between them, while all QQuickItem calls remain on the GUI thread.
        if (flush && (flush->kind != PendingFlush::Kind::Advance ||
                      flush->generation > guiAppliedGeneration)) {
          if (applyFlushOnGuiLocked(item, flush->generation,
                                    flush->kind == PendingFlush::Kind::Final)) {
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
              transientObservation = true;
              updateObservationArmLocked();
              retirementGracePolls = 1;
              schedulePoll = true;
            } catch (...) {
              latchFailureLocked("native Qt OpenGL frame delivery failed");
            }
          }
        }
        try {
          samplePresenterLocked(item);
        } catch (...) {
          latchFailureLocked("native Qt OpenGL presenter telemetry failed");
        }
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
    state_->tracked.wakeGate.close();
    while (!state_->tracked.wakeGate.drained()) {
      std::this_thread::yield();
    }
    {
      std::lock_guard lock(state_->mutex);
      state_->tracked.wake = {};
    }
    // The last adapter owner has just been dropped, so this adapter is
    // exactly retired: the wake gate is closed and drained, every queued GUI
    // callback holds only weak State and is about to become inert, and no
    // caller can reach this object again. Hand the output lease back at this
    // boundary (see releaseOutputLeaseOnRetirementNoexcept for why not at
    // deferred QObject deletion). Released outside the State mutex: the
    // handoff applies any owed terminal invalidation to the item first, and
    // item calls must not run under it.
    if (state_->guiContext) {
      state_->guiContext->releaseOutputLeaseOnRetirementNoexcept();
    }
  }
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
  state->tracked.wake = wake;
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

bool NativeQtGlOutput::flushImpl(std::uint64_t nextGeneration,
                                 std::string* error) noexcept {
  const std::shared_ptr<State> state = state_;
  state->consumeDeferredSchedulingFailureNoexcept();
  if (error != nullptr) {
    error->clear();
  }
  bool success = true;
  bool schedulePoll = false;
  {
    std::lock_guard lock(state->mutex);
    if (state->closed) {
      assignErrorNoexcept(error, "native Qt OpenGL output is closed");
      return false;
    }
    if ((state->health == State::Health::Failed)) {
      assignErrorNoexcept(error, state->failureMessage);
      success = false;
    }
    const bool forceFailClosed =
        nextGeneration <= state->acceptedGeneration;
    if (forceFailClosed) {
      success = false;
      if (!(state->health == State::Health::Failed)) {
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
    state->transientObservation = true;
    state->updateObservationArmLocked();

    if (state->guiContext->isGuiThread()) {
      // Controller-originated start/seek calls invalidate the retained Qt
      // frame synchronously. No blocking cross-thread invoke is ever used.
      state->pendingFlush.reset();
      QtGlVideoItem* item = state->guiContext->itemOnGui();
      if (item == nullptr) {
        state->latchFailureLocked(
            "native Qt OpenGL video item was destroyed");
        assignErrorNoexcept(error, state->failureMessage);
        success = false;
      } else {
        if (state->applyFlushOnGuiLocked(item, nextGeneration, false)) {
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
      state->pendingFlush = State::PendingFlush{
          nextGeneration, forceFailClosed ? State::PendingFlush::Kind::Forced
                                          : State::PendingFlush::Kind::Advance};
      if (!state->queueDrainLocked(error)) {
        state->latchFailureLocked(
            "Qt rejected the native video generation flush");
        success = false;
      }
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
    state->updateObservationArmLocked();

    if (state->guiContext->isGuiThread()) {
      state->pendingFlush.reset();
      if (QtGlVideoItem* item = state->guiContext->itemOnGui()) {
        // close() is a terminal invalidation, so even an exhausted/equal
        // generation must clear Qt's retained lease. QtGlVideoItem treats the
        // repeated value fail-closed and never reopens that timeline.
        (void)state->applyFlushOnGuiLocked(item, state->acceptedGeneration,
                                           false);
      }
    } else {
      state->guiContext->requireFinalFlush(state->acceptedGeneration);
      state->pendingFlush = State::PendingFlush{
          state->acceptedGeneration, State::PendingFlush::Kind::Final};
      std::string ignoredError;
      if (!state->queueDrainLocked(&ignoredError)) {
        state->latchFailureLocked(
            "Qt rejected the final native video generation flush");
      }
      // Queue this after the ordinary drain. If State survives, that drain
      // applies and disarms the obligation; if State dies, this bounded strong
      // GUI callback becomes the terminal invalidation owner.
      bool finalizerQueued = false;
      try {
        const std::shared_ptr<State::GuiContext> finalizer =
            state->guiContext;
#if defined(WAM_NATIVE_TEST_SEAMS)
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
        state->latchFailureLocked(
            "Qt rejected the final native video flush owner");
      }
    }
  }
}

NativeTrackedVideoCapacity NativeQtGlOutput::capacity(
    std::uint64_t generation) const noexcept {
  const std::shared_ptr<State> state = state_;
  state->trackedWakePending.store(false, std::memory_order_release);
  state->sampleTrackedRenderProgressAndSignalNoexcept();
  std::lock_guard lock(state->mutex);
  return state->tracked.capacity(
      generation, state->trackedGenerationCurrentLocked(generation),
      state->trackedUsableLocked());
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
  if (!frameTimingPresentable(timing)) {
    assignErrorNoexcept(error,
                        "tracked native video timing is invalid");
    return NativeTrackedVideoSubmitStatus::Failed;
  }
  std::optional<FrameLease> clone = frame.tryClone();
  if (!clone) {
    assignErrorNoexcept(
        error, "tracked native video accounting token could not be cloned");
    return NativeTrackedVideoSubmitStatus::Failed;
  }
  FrameLease retained = std::move(*clone);
  NativeTrackedVideoSubmitStatus result =
      NativeTrackedVideoSubmitStatus::Accepted;
  {
    std::lock_guard lock(state->mutex);
    switch (state->tracked.capacity(
        timing.generation,
        state->trackedGenerationCurrentLocked(timing.generation),
        state->trackedUsableLocked())) {
    case NativeTrackedVideoCapacity::Failed:
      assignErrorNoexcept(error, state->failureMessage.empty()
                                    ? "tracked native video output failed"
                                    : state->failureMessage);
      return NativeTrackedVideoSubmitStatus::Failed;
    case NativeTrackedVideoCapacity::StaleGeneration:
      assignErrorNoexcept(error,
                          "tracked native video generation is stale");
      return NativeTrackedVideoSubmitStatus::StaleGeneration;
    case NativeTrackedVideoCapacity::Backpressure:
      return NativeTrackedVideoSubmitStatus::Backpressure;
    case NativeTrackedVideoCapacity::Available:
      break;
    }
    if (!state->tracked.advances(sequence)) {
      state->rejectTrackedLocked();
      state->latchFailureLocked(
          "native video frame sequence repeated or regressed");
      assignErrorNoexcept(error, state->failureMessage);
      result = NativeTrackedVideoSubmitStatus::Failed;
    } else if (state->nextTrackedDeliverySequence ==
               std::numeric_limits<std::uint64_t>::max()) {
      state->rejectTrackedLocked();
      state->latchFailureLocked("native video delivery sequence exhausted");
      assignErrorNoexcept(error, state->failureMessage);
      result = NativeTrackedVideoSubmitStatus::Failed;
    } else {
      ++state->nextTrackedDeliverySequence;
      state->pendingFrame = std::move(retained);
      state->pendingFrameIdentity = QtGlFrameIdentity{
          state->nextTrackedDeliverySequence, sequence.value};
      // The GUI drain runs only after this lock is released, so admitting
      // after a successful queue is not observable as a later admission.
      if (!state->queueDrainLocked(error)) {
        state->pendingFrameIdentity = {};
        state->rejectTrackedLocked();
        state->latchFailureLocked(
            "Qt rejected tracked native video delivery");
        result = NativeTrackedVideoSubmitStatus::Failed;
      } else {
        state->tracked.admit(sequence, timing);
        state->transientObservation = true;
        state->updateObservationArmLocked();
      }
    }
  }
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
    signalTrackedProgress = state->sampleTrackedRenderProgressLocked();
    result = state->tracked.take();
    signalTrackedProgress =
        state->tracked.pendingInvalidation().has_value() ||
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
    const auto step = state->tracked.beginFlush(
        retiredGeneration, nextGeneration, state->trackedUsableLocked());
    if (const auto settled = NativeTrackedOutputProtocol::settled(step)) {
      return *settled;
    }
    if (step == NativeTrackedOutputProtocol::Step::Started) {
      mustApply = true;
      state->transientObservation = true;
      state->updateObservationArmLocked();
    }
  }
  if (mustApply) {
    std::string ignored;
    if (!flushImpl(nextGeneration, &ignored)) {
      std::lock_guard lock(state->mutex);
      state->rejectTrackedLocked();
      return NativeTrackedVideoOutputProgress::Failed;
    }
    if (state->guiContext->isGuiThread()) {
      state->observePresenterOnGui();
    }
  }
  state->sampleTrackedRenderProgressAndSignalNoexcept();
  {
    std::lock_guard lock(state->mutex);
    if (state->tracked.frameOutstanding() ||
        !state->trackedInvalidationObservedLocked(nextGeneration)) {
      state->updateObservationArmLocked();
      return NativeTrackedVideoOutputProgress::Quiescing;
    }
    state->tracked.completeFlush();
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
    // A FrameRejected output is not vetoed here: terminal close must still
    // invalidate the exact final generation and retire every retained lease
    // so the router can safely enter fallback.
    const auto step =
        state->tracked.beginClose(finalGeneration, state->acceptedGeneration);
    if (step == NativeTrackedOutputProtocol::Step::Done) {
      return state->tracked.detachWake()
                 ? NativeTrackedVideoOutputProgress::Done
                 : NativeTrackedVideoOutputProgress::Quiescing;
    }
    if (const auto settled = NativeTrackedOutputProtocol::settled(step)) {
      return *settled;
    }
    if (step == NativeTrackedOutputProtocol::Step::Started) {
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
    if ((state->health == State::Health::Failed) || state->tracked.frameOutstanding() ||
        !state->trackedInvalidationObservedLocked(finalGeneration)) {
      return (state->health == State::Health::Failed)
                 ? NativeTrackedVideoOutputProgress::Failed
                 : NativeTrackedVideoOutputProgress::Quiescing;
    }
    // No render/GUI callback can publish tracked progress after terminal
    // invalidation; detach the external raw wake context before Done.
    if (!state->tracked.detachWake()) {
      state->updateObservationArmLocked();
      return NativeTrackedVideoOutputProgress::Quiescing;
    }
    // A terminal invalidation supersedes any arm/seek flush only after the
    // stronger final-generation render proof above.
    state->tracked.completeClose();
    state->updateObservationArmLocked();
  }
  return NativeTrackedVideoOutputProgress::Done;
}

NativeTrackedVideoOutputFacts NativeQtGlOutput::facts() const noexcept {
  const std::shared_ptr<State> state = state_;
  state->consumeDeferredSchedulingFailureNoexcept();
  state->sampleTrackedRenderProgressAndSignalNoexcept();
  std::lock_guard lock(state->mutex);
  return state->tracked.facts(state->acceptedGeneration,
                              state->tracked.closed(),
                              state->health != State::Health::Live);
}

#if defined(WAM_NATIVE_TEST_SEAMS)
void NativeQtGlOutput::failNextGuiInvokeForTesting() noexcept {
  state_->failNextGuiInvoke.store(true, std::memory_order_release);
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
      !state_->tracked.wakeGate.tryPin()) {
    return;
  }
  entered->store(true, std::memory_order_release);
  while (!release->load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }
  state_->tracked.wakeGate.unpin();
}
#endif

}  // namespace wam::macos
