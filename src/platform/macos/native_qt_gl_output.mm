#include "native_qt_gl_output.hpp"

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

}  // namespace

struct NativeQtGlOutput::State
    : public std::enable_shared_from_this<NativeQtGlOutput::State> {
  class GuiContext final : public QObject {
   public:
    GuiContext(
        QtGlVideoItem* item, std::weak_ptr<State> state,
        std::shared_ptr<const std::atomic<std::uint64_t>>
            observedPresenterFatalSerial)
        : item_(item),
          state_(std::move(state)),
          guiThread_(item->thread()),
          fatalErrorSerialToken_(item->fatalErrorSerialToken()),
          observedPresenterFatalSerial_(
              std::move(observedPresenterFatalSerial)) {}

    // Called only after State::guiContext publishes this object. Render-thread
    // signals may fire immediately after setWindow(), so construction itself
    // must not expose a partially published State.
    void arm() {
      QtGlVideoItem* item = item_.data();
      if (item == nullptr) {
        return;
      }
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
      if (afterRenderingConnection_) {
        QObject::disconnect(afterRenderingConnection_);
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

   private:
    void setWindow(QQuickWindow* window) {
      if (afterRenderingConnection_) {
        QObject::disconnect(afterRenderingConnection_);
        afterRenderingConnection_ = {};
      }
      if (window == nullptr) {
        return;
      }
      afterRenderingConnection_ = QObject::connect(
          window, &QQuickWindow::afterRendering, this,
          [weakState = state_,
           fatalErrorSerialToken = fatalErrorSerialToken_,
           observedPresenterFatalSerial =
               observedPresenterFatalSerial_] {
            // This direct render-thread callback deliberately performs only
            // two acquire loads on shared atomic telemetry. Normal frames do
            // not lock State, touch a QObject/QPointer, sample full presenter
            // stats, allocate, or queue work on the GUI thread.
            if (fatalErrorSerialToken.load() ==
                observedPresenterFatalSerial->load(
                    std::memory_order_acquire)) {
              return;
            }
            if (auto state = weakState.lock()) {
              state->queueImmediateObservation();
            }
          },
          Qt::DirectConnection);
    }

    QPointer<QtGlVideoItem> item_;
    std::weak_ptr<State> state_;
    QThread* guiThread_{nullptr};
    QtGlFatalErrorSerialToken fatalErrorSerialToken_;
    std::shared_ptr<const std::atomic<std::uint64_t>>
        observedPresenterFatalSerial_;
    QMetaObject::Connection afterRenderingConnection_;
    std::atomic<std::uint64_t> finalFlushGeneration_{0};
    std::atomic<bool> finalFlushRequired_{false};
  };

  mutable std::mutex mutex;
  std::shared_ptr<GuiContext> guiContext;
  std::optional<FrameLease> pendingFrame;
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
  std::shared_ptr<std::atomic<std::uint64_t>>
      observedPresenterFatalSerialAtomic{
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
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
  std::atomic<bool> failNextFailureNotificationCopy{false};
  std::atomic<bool> failNextGuiInvoke{false};
#endif

  void updateObservationArmLocked() noexcept {
    observationArmed.store(
        !failureLatched && !closed &&
            (failureHandlerActive || transientObservation),
        std::memory_order_release);
  }

  void queueImmediateObservation() noexcept {
    if (!observationArmed.load(std::memory_order_acquire) ||
        observationQueued.exchange(true, std::memory_order_acq_rel)) {
      return;
    }
    const std::weak_ptr<State> weakState = weak_from_this();
    const bool queued = QMetaObject::invokeMethod(
        guiContext.get(),
        [weakState] {
          if (auto retained = weakState.lock()) {
            retained->observationQueued.store(false,
                                               std::memory_order_release);
            retained->observePresenterOnGui();
          }
        },
        Qt::QueuedConnection);
    if (!queued) {
      observationQueued.store(false, std::memory_order_release);
    }
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
    }
    return takeFailureNotificationLocked();
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
    const std::weak_ptr<State> weakState = weak_from_this();
    bool queued = false;
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
    if (!failNextGuiInvoke.exchange(false, std::memory_order_acq_rel))
#endif
    {
      queued = QMetaObject::invokeMethod(
          guiContext.get(),
          [weakState, token] {
            if (auto state = weakState.lock()) {
              state->drainOnGui(token);
            }
          },
          Qt::QueuedConnection);
    }
    if (queued) {
      return true;
    }
    // No callback owns this token, so it is safe to clear only that token and
    // release the sole pending lease. A newer request can never be erased.
    if (queuedDrainToken == token) {
      queuedDrainToken = 0;
      pendingFrame.reset();
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
    if (presenterStats.fatalErrorSerial == observedPresenterFatalSerial) {
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
    if (!observationArmed.load(std::memory_order_acquire)) {
      return;
    }
    std::pair<FailureHandler, std::string> notify;
    bool pollAgain = false;
    {
      std::lock_guard lock(mutex);
      QtGlVideoItem* item = guiContext->itemOnGui();
      if (item == nullptr) {
        notify = latchFailureLocked(
            "native Qt OpenGL video item was destroyed");
      } else {
        try {
          samplePresenterLocked(item, &notify);
        } catch (...) {
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
    const std::weak_ptr<State> weakState = weak_from_this();
    QTimer::singleShot(50, guiContext.get(), [weakState] {
      if (auto state = weakState.lock()) {
        state->observationPollQueued.store(false,
                                           std::memory_order_release);
        state->observePresenterOnGui();
      }
    });
  }

  void itemDestroyedOnGui() noexcept {
    std::pair<FailureHandler, std::string> notify;
    {
      std::lock_guard lock(mutex);
      pendingFrame.reset();
      pendingFlush.reset();
      pendingStartApplied = {};
      pendingStartRequestedGeneration = 0;
      forcePendingFlush = false;
      pendingFinalFlush = false;
      observationArmed.store(false, std::memory_order_release);
      observationPollQueued.store(false, std::memory_order_release);
      notify =
          latchFailureLocked("native Qt OpenGL video item was destroyed");
    }
    invokeFailureNoexcept(std::move(notify.first),
                          std::move(notify.second));
  }

  void drainOnGui(std::uint64_t token) noexcept {
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
              item->submitFrame(std::move(*frame));
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

NativeQtGlOutput::~NativeQtGlOutput() = default;

std::shared_ptr<NativeQtGlOutput> NativeQtGlOutput::create(
    QtGlVideoItem* item, std::string* error) {
  if (error != nullptr) {
    error->clear();
  }
  if (item == nullptr) {
    if (error != nullptr) {
      *error = "a Qt OpenGL video item is required";
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
  QThread* const itemThread = item->thread();
  auto deleter = [itemThread](State::GuiContext* context) noexcept {
    if (QThread::currentThread() == itemThread) {
      delete context;
      return;
    }
    // deleteLater() is thread-safe and ensures QObject/QPointer destruction
    // remains on the GUI thread when retirement releases the last owner.
    context->deleteLater();
  };
  try {
    state->guiContext = std::shared_ptr<State::GuiContext>(
        new State::GuiContext(
            item, state, state->observedPresenterFatalSerialAtomic),
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
    std::lock_guard lock(state_->mutex);
    if (state_->closed) {
      ++state_->rejectedFrames;
      assignErrorNoexcept(error, "native Qt OpenGL output is closed");
      return NativeScheduledFrameDispatchResult::Rejected;
    }
    if (state_->failureLatched) {
      ++state_->rejectedFrames;
      assignErrorNoexcept(error, state_->failureMessage);
      return NativeScheduledFrameDispatchResult::Failed;
    }
    if (frame.timing().generation != state_->acceptedGeneration) {
      ++state_->staleFrames;
      assignErrorNoexcept(error,
                          "native Qt OpenGL frame generation is stale");
      return NativeScheduledFrameDispatchResult::Rejected;
    }
    const bool coalesced = state_->pendingFrame.has_value();
    state_->pendingFrame = std::move(frame);
    if (!state_->queueDrainLocked(error)) {
      ++state_->rejectedFrames;
      notify = state_->latchFailureLocked(
          "Qt rejected the native video GUI delivery request");
      result = NativeScheduledFrameDispatchResult::Failed;
    } else {
      ++state_->dispatchedFrames;
      if (coalesced) {
        ++state_->coalescedFrames;
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
  if (error != nullptr) {
    error->clear();
  }
  std::pair<FailureHandler, std::string> notify;
  std::optional<NativeScheduledFrameStartAck> startAck;
  bool success = true;
  bool schedulePoll = false;
  {
    std::lock_guard lock(state_->mutex);
    if (state_->closed) {
      assignErrorNoexcept(error, "native Qt OpenGL output is closed");
      return false;
    }
    if (state_->failureLatched) {
      assignErrorNoexcept(error, state_->failureMessage);
      success = false;
    }
    if (startApplied && state_->pendingStartApplied) {
      assignErrorNoexcept(error,
                          "native Qt OpenGL startup flush is already pending");
      return false;
    }
    const bool forceFailClosed =
        nextGeneration <= state_->acceptedGeneration;
    if (forceFailClosed) {
      success = false;
      if (!state_->failureLatched) {
        assignErrorNoexcept(
            error, nextGeneration < state_->acceptedGeneration
                       ? "native Qt OpenGL flush generation regressed"
                       : "native Qt OpenGL generation was already flushed");
      }
    } else {
      state_->acceptedGeneration = nextGeneration;
    }
    if (forceFailClosed && state_->acceptedGeneration ==
                               std::numeric_limits<std::uint64_t>::max()) {
      state_->closed = true;
    }
    state_->pendingFrame.reset();
    if (!startApplied) {
      // A seek/stop supersedes a not-yet-applied startup request. Its callback
      // must never publish Running after the newer invalidation was admitted.
      state_->pendingStartApplied = {};
      state_->pendingStartRequestedGeneration = 0;
    }
    state_->transientObservation = true;
    state_->updateObservationArmLocked();
    if (!success && startApplied) {
      startApplied = {};
    }

    if (state_->guiContext->isGuiThread()) {
      // Controller-originated start/seek calls invalidate the retained Qt
      // frame synchronously. No blocking cross-thread invoke is ever used.
      state_->pendingFlush.reset();
      state_->forcePendingFlush = false;
      QtGlVideoItem* item = state_->guiContext->itemOnGui();
      if (item == nullptr) {
        notify = state_->latchFailureLocked(
            "native Qt OpenGL video item was destroyed");
        assignErrorNoexcept(error, state_->failureMessage);
        success = false;
      } else {
        if (state_->applyFlushOnGuiLocked(item, nextGeneration, false,
                                          &notify)) {
          if (startApplied) {
            state_->attemptAcceptedRenderedBaseline =
                state_->presenterAcceptedRenderedFrames;
            state_->attemptAcceptedRenderedFrames = 0;
            state_->attemptBaselinePending = false;
            state_->attemptBaselineApplied = true;
            startAck.emplace(NativeScheduledFrameStartAck{
                nextGeneration, state_->acceptedGeneration,
                state_->presenterAcceptedRenderedFrames});
          }
          state_->updateObservationArmLocked();
          state_->retirementGracePolls = 1;
          schedulePoll = true;
          if (forceFailClosed && state_->acceptedGeneration ==
                                     std::numeric_limits<std::uint64_t>::max()) {
            state_->closed = true;
          }
        } else {
          assignErrorNoexcept(error, state_->failureMessage);
          success = false;
        }
      }
    } else {
      state_->pendingFlush = nextGeneration;
      state_->forcePendingFlush = forceFailClosed;
      if (startApplied) {
        state_->pendingStartRequestedGeneration = nextGeneration;
        state_->pendingStartApplied = std::move(startApplied);
      }
      if (!state_->queueDrainLocked(error)) {
        notify = state_->latchFailureLocked(
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
    state_->scheduleObservationPollOnGui();
  }
  return success;
}

void NativeQtGlOutput::close(std::uint64_t finalGeneration) noexcept {
  std::pair<FailureHandler, std::string> notify;
  {
    std::lock_guard lock(state_->mutex);
    if (state_->closed) {
      return;
    }
    state_->closed = true;
    state_->acceptedGeneration =
        std::max(state_->acceptedGeneration, finalGeneration);
    state_->pendingFrame.reset();
    state_->pendingStartApplied = {};
    state_->pendingStartRequestedGeneration = 0;
    state_->observationArmed.store(false, std::memory_order_release);

    if (state_->guiContext->isGuiThread()) {
      state_->pendingFlush.reset();
      state_->forcePendingFlush = false;
      if (QtGlVideoItem* item = state_->guiContext->itemOnGui()) {
        // close() is a terminal invalidation, so even an exhausted/equal
        // generation must clear Qt's retained lease. QtGlVideoItem treats the
        // repeated value fail-closed and never reopens that timeline.
        (void)state_->applyFlushOnGuiLocked(
            item, state_->acceptedGeneration, false, &notify);
      }
    } else {
      state_->guiContext->requireFinalFlush(state_->acceptedGeneration);
      state_->pendingFlush = state_->acceptedGeneration;
      state_->forcePendingFlush = true;
      state_->pendingFinalFlush = true;
      std::string ignoredError;
      if (!state_->queueDrainLocked(&ignoredError)) {
        notify = state_->latchFailureLocked(
            "Qt rejected the final native video generation flush");
      }
      // Queue this after the ordinary drain. If State survives, that drain
      // applies and disarms the obligation; if State dies, this bounded strong
      // GUI callback becomes the terminal invalidation owner.
      try {
        const std::shared_ptr<State::GuiContext> finalizer =
            state_->guiContext;
        (void)QMetaObject::invokeMethod(
            finalizer.get(),
            [finalizer] { finalizer->performRequiredFinalFlushOnGui(); },
            Qt::QueuedConnection);
      } catch (...) {
        // The destructor remains a fail-closed fallback with the obligation
        // still armed.
      }
    }
  }
  invokeFailureNoexcept(std::move(notify.first),
                        std::move(notify.second));
}

void NativeQtGlOutput::setFailureHandler(FailureHandler handler) noexcept {
  std::pair<FailureHandler, std::string> notify;
  bool sampleImmediately = false;
  {
    std::lock_guard lock(state_->mutex);
    const bool wasActive = state_->failureHandlerActive;
    try {
      state_->failureHandler = std::move(handler);
    } catch (...) {
      state_->failureHandler = {};
    }
    state_->failureHandlerActive = static_cast<bool>(state_->failureHandler);
    if (!wasActive && state_->failureHandlerActive) {
      // The next startGeneration GUI application establishes the exact
      // presenter-side baseline for this attempt. Old redraws before that
      // linearization can never inflate the new attempt.
      state_->attemptBaselinePending = true;
      state_->attemptBaselineApplied = false;
      state_->attemptAcceptedRenderedBaseline =
          state_->presenterAcceptedRenderedFrames;
      state_->attemptAcceptedRenderedFrames = 0;
    }
    state_->updateObservationArmLocked();
    sampleImmediately = state_->failureHandlerActive &&
                        !state_->failureLatched && !state_->closed;
    state_->failureDelivered = false;
    notify = state_->takeFailureNotificationLocked();
  }
  invokeFailureNoexcept(std::move(notify.first),
                        std::move(notify.second));
  if (sampleImmediately) {
    state_->queueImmediateObservation();
  }
}

NativeScheduledFrameOutputStats NativeQtGlOutput::stats() const noexcept {
  std::lock_guard lock(state_->mutex);
  NativeScheduledFrameOutputStats result;
  result.closed = state_->closed;
  result.deliveryQueued = state_->queuedDrainToken != 0;
  result.acceptedGeneration = state_->acceptedGeneration;
  result.dispatchedFrames = state_->dispatchedFrames;
  result.deliveredFrames = state_->deliveredFrames;
  result.coalescedFrames = state_->coalescedFrames;
  result.staleFrames = state_->staleFrames;
  result.rejectedFrames = state_->rejectedFrames;
  result.actuallyRenderedFrames = state_->actuallyRenderedFrames;
  result.acceptedRenderedFrames =
      state_->presenterAcceptedRenderedFrames;
  result.attemptAcceptedRenderedFrames =
      state_->attemptAcceptedRenderedFrames;
  result.lastRenderedGeneration = state_->lastRenderedGeneration;
  result.fatalErrorSerial = state_->fatalErrorSerial;
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
#endif

}  // namespace wam::macos
