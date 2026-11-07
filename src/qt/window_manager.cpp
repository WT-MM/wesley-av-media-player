#include "media/startup_benchmark.hpp"
#include "window_manager.hpp"

#include "player_controller.hpp"
#include "state_store.hpp"
#include "test_seams.hpp"

#if defined(Q_OS_MACOS)
#include "macos_window_chrome.hpp"
#endif
#if defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
#include "platform/macos/native_embedding_support.hpp"
#endif

#include <QFileInfo>
#include <QGuiApplication>
#include <QMetaObject>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickWindow>
#include <QRect>
#include <QScreen>
#include <QVariant>
#include <QVariantMap>
#include <QStyleHints>
#include <QTimer>

#include <algorithm>
#include <utility>
#include <chrono>
#include <cmath>

#if defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
// The window factory's cap and the native resource envelope's cap are two
// statements of one number. Assert they agree rather than letting a future
// edit raise one and silently overrun the other: N windows each hold their own
// audio output slot, audio session slot, video consumer slot and layer
// presentation retains, and every one of those tables is sized from the
// platform constant.
static_assert(wam::qt::kMaximumPlayerWindows ==
                  wam::macos::NativeEmbeddingSupport::maximumWindows,
              "the window cap and the native per-session resource envelope "
              "must be the same number");
#endif

namespace wam::qt {
namespace {

// A position is worth resuming only at least this far from both ends; save
// and restore must agree on it.
constexpr double kResumeMarginSeconds = 5.0;

#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY)
class StartupExposureObserver final : public QObject {
public:
  explicit StartupExposureObserver(QQuickWindow *window) : QObject(window) {
    window->installEventFilter(this);
  }
  bool eventFilter(QObject *object, QEvent *event) override {
    if (!seen_ && event->type() == QEvent::Expose &&
        static_cast<QQuickWindow *>(object)->isExposed()) {
      seen_ = true;
      WAM_STARTUP_STAMP(FirstWindowExposed);
    }
    return false;
  }
private:
  bool seen_{false};
};
#endif

QString localStateKey(const QUrl &source) {
  if (!source.isLocalFile())
    return {};
  return QFileInfo(source.toLocalFile()).absoluteFilePath();
}

std::string persistentKey(const QString &local_path) {
  return local_path.toUtf8().toStdString();
}

} // namespace

// ---------------------------------------------------------------------------
// PlayerWindow
// ---------------------------------------------------------------------------

PlayerWindow::PlayerWindow(WindowManager &manager, QQmlComponent &component,
                           QQmlEngine &engine)
    : QObject(&manager), manager_(manager) {
  // One QML context per window. `player` is resolved out of it, so
  // qml/Main.qml works as an N-instance component: each instance sees its
  // own controller.
  context_ = new QQmlContext(engine.rootContext(), this);

  controller_ = new PlayerController(this);
  controller_->bindSettings(manager_.settings());
  controller_->setVolume(manager_.settings().initialVolume());
  context_->setContextProperty(QStringLiteral("player"), controller_);

  qml_root_ = component.create(context_);
  WAM_STARTUP_STAMP(QmlRootLoaded);
  if (qml_root_ == nullptr)
    return;
  qml_root_->setParent(this);
  window_ = qobject_cast<QQuickWindow *>(qml_root_);
#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY)
  if (window_ && media::audioBenchmarkMailbox.enabled.load(std::memory_order_relaxed)) {
    connect(window_, &QQuickWindow::frameSwapped, this, [seen = false]() mutable {
      if (!std::exchange(seen, true)) WAM_STARTUP_STAMP(FirstSceneFrame);
    }, Qt::DirectConnection);
    new StartupExposureObserver(window_);
  }
#endif

#if defined(Q_OS_MACOS)
  if (window_ != nullptr) {
    // The bridge installs the transparent full-size-content titlebar on
    // construction and stays alive for this window's lifetime so Main.qml can
    // drive its fade/aspect-ratio/actual-size calls afterwards.
    chrome_ = new MacWindowChrome(window_, this);
    connect(controller_, &PlayerController::videoDisplaySizeChanged, chrome_, [this] {
      chrome_->setExactVideoDisplaySize(controller_->exactVideoDisplaySize());
    });
    // The chrome cannot exist before the window it wraps, so it arrives as a
    // property set after creation; Main.qml adopts it on the change.
    qml_root_->setProperty("windowChrome", QVariant::fromValue(chrome_));
  }
#endif

  wireResumeTracking();
  connect(controller_, &PlayerController::volumeChanged, this, [this] {
    manager_.settings().rememberVolume(controller_->volume());
  });

  if (window_ != nullptr) {
    connect(window_, &QWindow::activeChanged, this, [this] {
      if (window_ != nullptr && window_->isActive())
        manager_.noteFocused(this);
    });
    // A window close is a full playback teardown, not a hide: the controller's
    // destructor retires the native session. Deferred to the event loop so the
    // teardown never unwinds through AppKit's own close handling.
    connect(window_, &QQuickWindow::closing, this,
            [this](QQuickCloseEvent *) { manager_.noteClosed(this); });
  }
}

PlayerWindow::~PlayerWindow() {
  // Destruction order is load-bearing, and QObject's own child sweep gets it
  // WRONG: it deletes children in the order they were parented, which here is
  // context, controller, root -- tearing the controller down while the QML
  // scene is still bound to it (null-property binding failures on close, and
  // the video item detaching from an already-destroyed controller).
  //
  // The correct order: the QML scene first (so
  // MpvVideoItem detaches its render surface from a live controller), then the
  // chrome bridge (so its AppKit event monitor is removed while its window
  // still exists), and only then the controller, whose destructor retires the
  // native playback session.
  // Retire playback through the ORDINARY stop path first, while the whole
  // scene is still standing. Destroying the QML scene under a live native
  // session also tears it down -- NativePlaybackOwner::detachSurface exists
  // for exactly that -- but that is the emergency boundary: it abandons the
  // session synchronously and surfaces "the native video surface was
  // destroyed during playback" as a user-facing error. Closing a window is a
  // deliberate act, not an emergency, so it takes the door marked stop.
  if (controller_ != nullptr) {
    controller_->beginTeardown();
    controller_->stop();
  }

  delete qml_root_;
  qml_root_ = nullptr;
  window_ = nullptr;
  delete chrome_;
  chrome_ = nullptr;
  delete controller_;
  controller_ = nullptr;
}

bool PlayerWindow::claimableFor(const QUrl &source) const {
  return controller_ != nullptr && controller_->claimableFor(source);
}

bool PlayerWindow::open(const QUrl &source) {
  if (controller_ == nullptr)
    return false;
  return controller_->open(source);
}

void PlayerWindow::raiseWindow() {
  if (window_ == nullptr)
    return;
  window_->show();
#if defined(Q_OS_MACOS)
  // Under the background-launch seam the window must come to the front
  // WITHOUT this process becoming active -- that is the entire point of the
  // seam, and an ordinary raise would steal the keyboard mid-measurement.
  if (const TestSeams *seams = testSeams(); seams != nullptr && seams->background) {
    ::wam::macos_window_chrome::orderFrontWithoutActivating(window_);
    return;
  }
#endif
  window_->raise();
  window_->requestActivate();
}

void PlayerWindow::placeAt(int x, int y, int width, int height) {
  if (window_ == nullptr)
    return;
  window_->setGeometry(x, y, width, height);
}

void PlayerWindow::cascadeFrom(const PlayerWindow &previous) {
  if (window_ == nullptr || previous.window_ == nullptr)
    return;
  const QRect origin = previous.window_->geometry();
  QRect target(origin.x() + kWindowCascadeStep,
               origin.y() + kWindowCascadeStep, window_->width(),
               window_->height());
  // Wrap back toward the screen's top-left before the cascade walks a window
  // off the bottom-right, so the tenth window is still reachable.
  if (const QScreen *screen = window_->screen()) {
    const QRect available = screen->availableGeometry();
    if (target.right() > available.right() ||
        target.bottom() > available.bottom()) {
      target.moveTo(available.x() + kWindowCascadeStep,
                    available.y() + kWindowCascadeStep);
    }
  }
  window_->setGeometry(target);
}

void PlayerWindow::rememberPosition(const ResumeSnapshot &snapshot) {
  if (snapshot.local_source.isEmpty() || !snapshot.position_observed)
    return;
  ::wam::StateStore &store = manager_.stateStore();
  const std::string key = persistentKey(snapshot.local_source);
  if (snapshot.position < kResumeMarginSeconds ||
      (snapshot.duration > 0.0 &&
       snapshot.position >= snapshot.duration - kResumeMarginSeconds)) {
    store.forget(key);
    return;
  }
  store.remember(key, snapshot.position);
}

void PlayerWindow::rememberTrackedPosition() {
  rememberPosition(resume_tracker_.snapshot());
}

void PlayerWindow::applyPendingResume() {
  const QString &tracked_local_source = resume_tracker_.snapshot().local_source;
  if (!resume_pending_ || tracked_local_source.isEmpty() ||
      controller_->duration() <= 0.0)
    return;
  // Wait for the transport to actually be running. Duration and source both
  // arrive while the engine is still starting, and a seek issued into that
  // window replaces the pending start instead of following it, which would
  // park a resumed open on its first frame. The request stays pending until a
  // start it can follow, so a paused open simply keeps its position.
  if (!controller_->playing() || controller_->position() <= 0.0)
    return;

  resume_pending_ = false;
  ::wam::StateStore &store = manager_.stateStore();
  if (resume_position_ < kResumeMarginSeconds ||
      resume_position_ >= controller_->duration() - kResumeMarginSeconds) {
    store.forget(persistentKey(tracked_local_source));
    if (store.dirty())
      manager_.requestCheckpoint();
    return;
  }
  // A remembered position is a decimal that has been through text, and native
  // seeking admits only an exactly representable target. Snapping it is
  // PlayerController::exactNativeSeekTarget's job and only its job; the guard
  // above already holds this value strictly inside the duration.
  controller_->seekTo(resume_position_);
}

void PlayerWindow::wireResumeTracking() {
  connect(controller_, &PlayerController::positionChanged, this, [this] {
    const double position = controller_->position();
    if (position > 0.0) {
      applyPendingResume();
      resume_tracker_.observePosition(position);
      if (!resume_tracker_.snapshot().local_source.isEmpty())
        manager_.requestCheckpoint();
      return;
    }

    // open() resets position and duration before sourceChanged, while stop()
    // emits sourceChanged first. Delay a zero so either ordering can preserve
    // the source being left. A real seek to zero keeps its source and positive
    // duration.
    const quint64 generation = resume_tracker_.generation();
    QTimer::singleShot(0, this, [this, generation] {
      const ResumeSnapshot &snapshot = resume_tracker_.snapshot();
      if (generation != resume_tracker_.generation() ||
          snapshot.local_source.isEmpty() ||
          localStateKey(controller_->source()) != snapshot.local_source ||
          controller_->position() > 0.0 || controller_->duration() <= 0.0)
        return;
      resume_tracker_.commitZeroPosition(generation);
      manager_.requestCheckpoint();
    });
  });

  connect(controller_, &PlayerController::durationChanged, this, [this] {
    resume_tracker_.observeDuration(controller_->duration());
    applyPendingResume();
  });
  connect(controller_, &PlayerController::playingChanged, this,
          [this] { applyPendingResume(); });
  connect(controller_, &PlayerController::sourceChanged, this, [this] {
    ::wam::StateStore &store = manager_.stateStore();
    const ResumeSnapshot previous =
        resume_tracker_.transitionTo(localStateKey(controller_->source()));
    rememberPosition(previous);
    if (store.dirty())
      manager_.requestCheckpoint();
    const QString &tracked_local_source =
        resume_tracker_.snapshot().local_source;
    resume_position_ =
        tracked_local_source.isEmpty()
            ? 0.0
            : store.positionFor(persistentKey(tracked_local_source));
    resume_pending_ = resume_position_ >= kResumeMarginSeconds;
    if (resume_pending_)
      applyPendingResume();
  });
}

// ---------------------------------------------------------------------------
// WindowManager
// ---------------------------------------------------------------------------

WindowManager::WindowManager(QQmlEngine &engine, ::wam::StateStore &store,
                             QObject *parent)
    : QObject(parent), engine_(engine), store_(store), settings_(store) {
  engine.rootContext()->setContextProperty(QStringLiteral("appSettings"),
                                           &settings_);
  connect(&settings_, &AppSettings::edited, this,
          &WindowManager::requestCheckpoint);
  connect(&settings_, &AppSettings::appearanceChanged, this,
          &WindowManager::darkAppearanceChanged);
  component_ = new QQmlComponent(&engine, QStringLiteral("Wam"),
                                 QStringLiteral("Main"), this);
  WAM_STARTUP_STAMP(QmlComponentLoaded);
  checkpoint_timer_ = new QTimer(this);
  checkpoint_timer_->setInterval(
      static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(
                           ::wam::StateCheckpointGate::kInterval)
                           .count()));
  checkpoint_timer_->setSingleShot(true);
  // A precise one-shot is never delivered early, preserving the ten-second
  // minimum between writes without any cost while the timer is inactive.
  checkpoint_timer_->setTimerType(Qt::PreciseTimer);
  connect(checkpoint_timer_, &QTimer::timeout, this, [this] {
    if (checkpoint_.checkpoint([this] { return saveIfDirty(); }))
      checkpoint_timer_->start();
  });
}

WindowManager::~WindowManager() {
  // Same reasoning as ~PlayerWindow: everything that resolves `appHost` out of
  // the QML root context has to be gone before this object is, or its bindings
  // re-evaluate against a half-destroyed manager on the way out.
  closeAllWindows();
  delete preferences_;
  preferences_ = nullptr;
  delete menu_bar_;
  menu_bar_ = nullptr;
}

void WindowManager::requestCheckpoint() {
  if (checkpoint_.request())
    checkpoint_timer_->start();
}

bool WindowManager::saveIfDirty() {
  for (PlayerWindow *window : windows_)
    window->rememberTrackedPosition();
  return !store_.dirty() || store_.save();
}

void WindowManager::flushPersistence() {
  checkpoint_timer_->stop();
  (void)checkpoint_.flushNow([this] { return saveIfDirty(); });
}

PlayerWindow *WindowManager::createWindow() {
  if (windows_.size() >= kMaximumPlayerWindows)
    return nullptr;

  auto *window = new PlayerWindow(*this, *component_, engine_);
  if (!window->valid()) {
    delete window;
    return nullptr;
  }

  PlayerWindow *previous = last_created_;
  windows_.append(window);
  last_created_ = window;

  if (QQuickWindow *quick = window->window()) {
    const TestSeams *seams = testSeams();
    if (seams != nullptr && seams->geometry &&
        (previous == nullptr || seams->allWindowGeometry)) {
      // Park the first window, or every window for a quiet storm proof. It is
      // applied again on the next event-loop passes because QML's own sizing
      // (windowHugsVideo, the first frame's natural size) settles after this
      // point and would otherwise overwrite it.
      const QRect parked = *seams->geometry;
      const auto apply = [quick, parked] {
        quick->setGeometry(parked);
      };
      apply();
      QTimer::singleShot(0, quick, apply);
      QTimer::singleShot(400, quick, apply);
    } else if (previous != nullptr) {
      window->cascadeFrom(*previous);
    }
  }

  window->raiseWindow();
  noteFocused(window);
  emit windowCountChanged();
  return window;
}

PlayerWindow *WindowManager::claimableWindow(const QUrl &source) const {
  // The focused window wins the claim when it is empty: opening a file with a
  // blank window in front of you must fill that window, not appear behind it.
  if (focused_ && focused_->claimableFor(source))
    return focused_.data();
  for (PlayerWindow *window : windows_) {
    if (window->claimableFor(source))
      return window;
  }
  return nullptr;
}

bool WindowManager::openUrl(const QUrl &source) {
  if (source.isEmpty())
    return false;

  if (PlayerWindow *claim = claimableWindow(source)) {
    claim->raiseWindow();
    return claim->open(source);
  }

  if (PlayerWindow *fresh = createWindow())
    return fresh->open(source);

  // At the window cap. Rather than silently dropping the open, replace the
  // focused window's media -- the same warm-replacement path a
  // drag-and-drop onto that window takes.
  if (PlayerWindow *focused = focusedPlayerWindow())
    return focused->open(source);
  return false;
}

void WindowManager::noteFocused(PlayerWindow *window) {
  if (focused_.data() == window)
    return;
  focused_ = window;
  emit focusChanged();
}

void WindowManager::noteClosed(PlayerWindow *window) {
  if (tearing_down_ || window == nullptr)
    return;
  const qsizetype index = windows_.indexOf(window);
  if (index < 0)
    return;

  // Persist what this window was watching before its tracker goes away with
  // it: a close is exactly when a resume point is worth the most.
  window->rememberTrackedPosition();
  if (store_.dirty())
    requestCheckpoint();

  windows_.removeAt(index);
  if (last_created_ == window)
    last_created_ = windows_.isEmpty() ? nullptr : windows_.constLast();
  if (focused_.data() == window) {
    focused_ = windows_.isEmpty() ? nullptr : windows_.constLast();
    emit focusChanged();
  }
  // Deleted through the event loop, never synchronously from inside the
  // window's own closing signal: the destructor tears the QML scene, the
  // chrome bridge and the native playback session down, none of which may
  // unwind through AppKit's in-progress close.
  window->deleteLater();
  emit windowCountChanged();
}

void WindowManager::closeAllWindows() {
  tearing_down_ = true;
  const QList<PlayerWindow *> doomed = windows_;
  windows_.clear();
  focused_ = nullptr;
  last_created_ = nullptr;
  for (PlayerWindow *window : doomed) {
    window->rememberTrackedPosition();
    // Synchronous on the quit path: aboutToQuit is the last moment the event
    // loop will run a deleteLater, so the teardown has to happen here for the
    // native sessions to retire rather than be abandoned at process exit.
    delete window;
  }
  emit windowCountChanged();
}

PlayerWindow *WindowManager::focusedPlayerWindow() const {
  if (focused_)
    return focused_.data();
  return windows_.isEmpty() ? nullptr : windows_.constLast();
}

QObject *WindowManager::focusedControllerObject() const {
  PlayerWindow *window = focusedPlayerWindow();
  return window == nullptr ? nullptr
                           : static_cast<QObject *>(window->controller());
}

QObject *WindowManager::focusedWindowObject() const {
  PlayerWindow *window = focusedPlayerWindow();
  return window == nullptr ? nullptr : window->qmlRoot();
}

bool WindowManager::darkAppearance() const {
  return QGuiApplication::styleHints() != nullptr &&
         QGuiApplication::styleHints()->colorScheme() == Qt::ColorScheme::Dark;
}

void WindowManager::showPreferences() {
  // Preferences is app-level: one window bound to AppSettings, which every
  // open player follows live. Reaching it from an empty app also opens a
  // player window, which is the state the user expects to return to.
  if (windows_.isEmpty())
    (void)createWindow();

  if (preferences_ == nullptr) {
    QQmlComponent component(&engine_, QStringLiteral("Wam"),
                            QStringLiteral("PreferencesWindow"));
    preferences_ = qobject_cast<QWindow *>(component.create(engine_.rootContext()));
    if (preferences_ == nullptr) {
      qWarning() << "WAM could not create the Preferences window:"
                 << component.errorString();
      return;
    }
  }
  preferences_->show();
  preferences_->raise();
  preferences_->requestActivate();
}

void WindowManager::openMedia() {
  // File > Open (and Cmd-O) must produce a NEW window, the way Finder-open and
  // argv do -- unless an empty window is already sitting there to claim it.
  //
  // The dialog is nonetheless hosted by a window that already exists rather
  // than by a window created up front for the result: cancelling the dialog
  // would leave such a window as a blank player, which is exactly the dead window the
  // empty-claim rule exists to avoid. The QML side therefore delivers the
  // chosen file back through openUrl(), which decides between claiming and
  // creating at the moment there is actually a file to put somewhere.
  PlayerWindow *window = focusedPlayerWindow();
  if (window == nullptr)
    window = createWindow();
  if (window == nullptr || window->qmlRoot() == nullptr)
    return;
  QMetaObject::invokeMethod(window->qmlRoot(), "openMediaInNewWindow");
}

void WindowManager::pauseAll() {
  for (PlayerWindow *window : windows_) {
    if (window->controller() != nullptr)
      window->controller()->pause();
  }
}

void WindowManager::hideAndPauseAll() {
  pauseAll();
#if defined(Q_OS_MACOS)
  ::wam::macos_window_chrome::hideApplication();
#endif
}

bool WindowManager::createMenuBar() {
  if (menu_bar_ != nullptr)
    return true;
  QQmlComponent component(&engine_, QStringLiteral("Wam"),
                          QStringLiteral("AppMenu"));
  menu_bar_ = component.create(engine_.rootContext());
  if (menu_bar_ == nullptr) {
    qWarning() << "WAM could not install its menu bar:"
               << component.errorString();
    return false;
  }
  WAM_STARTUP_STAMP(MenuLoaded);
  menu_bar_->setParent(this);
  return true;
}

} // namespace wam::qt
