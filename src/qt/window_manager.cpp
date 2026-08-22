#include "window_manager.hpp"

#include "player_controller.hpp"
#include "state_store.hpp"

#ifndef Q_OS_MACOS
#include "playback/mpv/mpv_runtime.hpp"
#endif

#if defined(Q_OS_MACOS)
#include "macos_window_chrome.hpp"
#endif
#if defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
#include "platform/macos/native_concurrency_limits.hpp"
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
                  wam::macos::kMaximumConcurrentPlayerWindows,
              "the window cap and the native per-session resource envelope "
              "must be the same number");
#endif

namespace wam::qt {
namespace {

QString localStateKey(const QUrl &source) {
  if (!source.isLocalFile())
    return {};
  return QFileInfo(source.toLocalFile()).absoluteFilePath();
}

std::string persistentKey(const QString &local_path) {
  return local_path.toUtf8().toStdString();
}

int appearanceValue(::wam::AppearanceTheme theme) {
  return static_cast<int>(theme);
}

::wam::AppearanceTheme appearanceTheme(int appearance) {
  switch (appearance) {
  case 1:
    return ::wam::AppearanceTheme::Dark;
  case 2:
    return ::wam::AppearanceTheme::System;
  case 0:
  default:
    return ::wam::AppearanceTheme::Light;
  }
}

void applyColorScheme(QStyleHints *style_hints, int appearance) {
  if (!style_hints)
    return;
  switch (appearanceTheme(appearance)) {
  case ::wam::AppearanceTheme::Dark:
    style_hints->setColorScheme(Qt::ColorScheme::Dark);
    break;
  case ::wam::AppearanceTheme::System:
    style_hints->setColorScheme(Qt::ColorScheme::Unknown);
    break;
  case ::wam::AppearanceTheme::Light:
  default:
    style_hints->setColorScheme(Qt::ColorScheme::Light);
    break;
  }
}

// Background-launch and parked-geometry seams. Owned here rather than in
// main.cpp because they now have to apply to every window this process
// creates, not just the one the engine used to load.
bool g_background_launch = false;
bool g_parked_geometry_valid = false;
QRect g_parked_geometry;

} // namespace

// ---------------------------------------------------------------------------
// ResumeTracker
// ---------------------------------------------------------------------------

void ResumeTracker::observePosition(double position) {
  if (std::isfinite(position) && position > 0.0) {
    snapshot_.position = position;
    snapshot_.position_observed = true;
  }
}

void ResumeTracker::observeDuration(double duration) {
  if (std::isfinite(duration) && duration > 0.0)
    snapshot_.duration = duration;
}

void ResumeTracker::commitZeroPosition(quint64 generation) {
  if (generation == generation_) {
    snapshot_.position = 0.0;
    snapshot_.position_observed = true;
  }
}

ResumeSnapshot ResumeTracker::transitionTo(const QString &local_source) {
  ResumeSnapshot previous = snapshot_;
  snapshot_ = ResumeSnapshot{local_source, 0.0, 0.0, false};
  ++generation_;
  return previous;
}

bool verifyResumeTracker() {
  ResumeTracker tracker;

  // Merely opening a source is not evidence that playback reached zero. A
  // second open (or quit/load failure) before mpv reports time-pos must leave
  // any previously persisted resume point untouched.
  tracker.transitionTo(QStringLiteral("/media/unobserved.mp4"));
  const ResumeSnapshot unobserved_snapshot =
      tracker.transitionTo(QStringLiteral("/media/first.mp4"));
  if (unobserved_snapshot.position_observed)
    return false;

  tracker.observeDuration(120.0);
  tracker.observePosition(42.0);

  // PlayerController::open resets the old timeline before sourceChanged.
  tracker.observePosition(0.0);
  tracker.observeDuration(0.0);
  const ResumeSnapshot open_snapshot =
      tracker.transitionTo(QStringLiteral("/media/second.mp4"));
  if (open_snapshot.local_source != QStringLiteral("/media/first.mp4") ||
      open_snapshot.position != 42.0 || open_snapshot.duration != 120.0 ||
      !open_snapshot.position_observed)
    return false;

  tracker.observeDuration(90.0);
  tracker.observePosition(27.0);

  // PlayerController::stop changes source before resetting the timeline.
  const ResumeSnapshot stop_snapshot = tracker.transitionTo({});
  tracker.observePosition(0.0);
  tracker.observeDuration(0.0);
  if (stop_snapshot.local_source != QStringLiteral("/media/second.mp4") ||
      stop_snapshot.position != 27.0 || stop_snapshot.duration != 90.0 ||
      !stop_snapshot.position_observed ||
      !tracker.snapshot().local_source.isEmpty())
    return false;

  // A deliberate seek to the beginning still clears the stable position.
  tracker.transitionTo(QStringLiteral("/media/third.mp4"));
  tracker.observePosition(18.0);
  tracker.commitZeroPosition(tracker.generation());
  return tracker.snapshot().position == 0.0 &&
         tracker.snapshot().position_observed;
}

// ---------------------------------------------------------------------------
// PlayerWindow
// ---------------------------------------------------------------------------

PlayerWindow::PlayerWindow(WindowManager &manager, QQmlComponent &component,
                           QQmlEngine &engine)
    : QObject(&manager), manager_(manager) {
  // One QML context per window. `player` and `windowChrome` are resolved out
  // of it, so qml/Main.qml -- which reads both as bare context properties --
  // needs no change to become an N-instance component: each instance simply
  // sees its own objects.
  context_ = new QQmlContext(engine.rootContext(), this);

  controller_ = new PlayerController(this);
  manager_.seedController(controller_);
  context_->setContextProperty(QStringLiteral("player"), controller_);

  qml_root_ = component.create(context_);
  if (qml_root_ == nullptr)
    return;
  qml_root_->setParent(this);
  window_ = qobject_cast<QQuickWindow *>(qml_root_);

#if defined(Q_OS_MACOS)
  if (window_ != nullptr) {
    // The bridge installs the transparent full-size-content titlebar on
    // construction and stays alive for this window's lifetime so Main.qml can
    // drive its fade/aspect-ratio/actual-size calls afterwards.
    chrome_ = new MacWindowChrome(window_, this);
    context_->setContextProperty(QStringLiteral("windowChrome"), chrome_);
    // The chrome cannot exist before the window it wraps, so it is necessarily
    // published after Component.onCompleted has already run with the name
    // undefined. Main.qml guards every use with `typeof windowChrome`, which
    // is deliberately not a binding dependency, so nothing re-evaluates on its
    // own: this call is what lets the window adopt the bridge (read the real
    // AppKit titlebar height, arm the aspect lock) at the first moment it
    // exists.
    QMetaObject::invokeMethod(qml_root_, "adoptWindowChrome");
  }
#endif

  wireResumeTracking();
  wireSettingsMirror();

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
  // scene is still bound to it. That produced a burst of "cannot read property
  // of null" binding failures on every close and, worse, left the video item
  // detaching from an already-destroyed controller.
  //
  // The correct order is the reverse of construction: the QML scene first (so
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

bool PlayerWindow::claimable() const {
  return controller_ != nullptr && !open_requested_ && !controller_->hasMedia();
}

bool PlayerWindow::open(const QUrl &source) {
  if (controller_ == nullptr)
    return false;
  open_requested_ = true;
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
  if (g_background_launch) {
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
  if (snapshot.position < 5.0 ||
      (snapshot.duration > 0.0 &&
       snapshot.position >= snapshot.duration - 5.0)) {
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
  // window replaces the pending start instead of following it, which left a
  // resumed open parked on its first frame. The request stays pending until a
  // start it can follow, so a paused open simply keeps its position.
  if (!controller_->playing() || controller_->position() <= 0.0)
    return;

  resume_pending_ = false;
  ::wam::StateStore &store = manager_.stateStore();
  if (resume_position_ < 5.0 ||
      resume_position_ >= controller_->duration() - 5.0) {
    store.forget(persistentKey(tracked_local_source));
    if (store.dirty())
      manager_.requestCheckpoint();
    return;
  }
  // Native seeking admits only an exactly representable target, and a
  // remembered position is a decimal that has been through text. Floor it onto
  // a binary grid, which every such value converts to exactly, so the restore
  // seek is never rejected for its last fractional digits. A 1/64 s grid is
  // finer than one video frame at any admitted rate.
  constexpr double kResumeGrid = 64.0;
  const double bounded = std::min(resume_position_, controller_->duration());
  controller_->seekTo(
      std::max(0.0, std::floor(bounded * kResumeGrid) / kResumeGrid));
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
    // Native accurate seek now serves AAC, so the restore seek keeps the
    // native session instead of retiring it and a resumed open plays.
    constexpr bool kAutoResumeEnabled = true;
    resume_pending_ = kAutoResumeEnabled && resume_position_ >= 5.0;
    if (resume_pending_)
      applyPendingResume();
  });
}

void PlayerWindow::wireSettingsMirror() {
  connect(controller_, &PlayerController::appearanceChanged, this,
          [this] { manager_.mirrorAppearance(controller_); });
  connect(controller_, &PlayerController::seekStepSecondsChanged, this,
          [this] { manager_.mirrorSeekStep(controller_); });
  connect(controller_, &PlayerController::windowHugsVideoChanged, this,
          [this] { manager_.mirrorWindowHugsVideo(controller_); });
  connect(controller_, &PlayerController::preservePitchChanged, this,
          [this] { manager_.mirrorPreservePitch(controller_); });
  connect(controller_, &PlayerController::volumeChanged, this,
          [this] { manager_.noteVolumeChanged(controller_); });
}

// ---------------------------------------------------------------------------
// WindowManager
// ---------------------------------------------------------------------------

WindowManager::WindowManager(QQmlEngine &engine, ::wam::StateStore &store,
                             QObject *parent)
    : QObject(parent), engine_(engine), store_(store) {
  component_ = new QQmlComponent(&engine, QStringLiteral("Wam"),
                                 QStringLiteral("Main"), this);
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

  // The saved appearance decides the process-wide colour scheme before any
  // window exists, so the very first window is painted in the right one rather
  // than flashing the default and correcting itself.
  applyColorScheme(QGuiApplication::styleHints(),
                   appearanceValue(store_.state().appearance_theme));
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

void WindowManager::setBackgroundLaunch(bool enabled) {
  g_background_launch = enabled;
}

void WindowManager::setParkedGeometry(int x, int y, int width, int height) {
  g_parked_geometry_valid = width > 0 && height > 0;
  g_parked_geometry = QRect(x, y, width, height);
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

void WindowManager::seedController(PlayerController *controller) const {
  if (controller == nullptr)
    return;
#ifndef Q_OS_MACOS
  // Off macOS there is no native route at all, so every window's controller
  // needs its own compatibility engine handle. libmpv explicitly supports many
  // mpv_create() handles from one loaded library image, and the runtime object
  // being retained here is the immutable, process-lifetime API table -- not a
  // handle -- so N controllers sharing it is exactly its intended use.
  const auto linked_runtime =
      ::wam::playback::mpv::MpvLinkedRuntimeFactory::create();
  if (linked_runtime)
    static_cast<void>(controller->provisionMpvFallbackRuntime(
        linked_runtime.runtime));
#endif
  const ::wam::PersistentState &state = store_.state();
  controller->setAppearance(appearanceValue(state.appearance_theme));
  controller->setVolume(
      static_cast<double>(std::clamp(state.volume, 0, 100)) / 100.0);
  controller->setSeekStepSeconds(
      static_cast<double>(std::clamp(state.seek_step_seconds, 1, 60)));
  controller->setWindowHugsVideo(state.window_hugs_video);
  controller->setPreservePitch(state.preserve_pitch);
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
    if (g_parked_geometry_valid && previous == nullptr) {
      // WAM_TEST_GEOMETRY parks the FIRST window at an exact rectangle. It is
      // applied again on the next event-loop passes because QML's own sizing
      // (windowHugsVideo, the first frame's natural size) settles after this
      // point and would otherwise overwrite it.
      const QRect parked = g_parked_geometry;
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

PlayerWindow *WindowManager::claimableWindow() const {
  // The focused window wins the claim when it is empty: opening a file with a
  // blank window in front of you must fill that window, not appear behind it.
  if (focused_ && focused_->claimable())
    return focused_.data();
  for (PlayerWindow *window : windows_) {
    if (window->claimable())
      return window;
  }
  return nullptr;
}

bool WindowManager::openUrl(const QUrl &source) {
  if (source.isEmpty())
    return false;

  if (PlayerWindow *claim = claimableWindow()) {
    claim->raiseWindow();
    return claim->open(source);
  }

  if (PlayerWindow *fresh = createWindow())
    return fresh->open(source);

  // At the window cap. Rather than silently dropping the open, replace the
  // focused window's media and say so -- the same warm-replacement path a
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

void WindowManager::mirrorAppearance(PlayerController *origin) {
  if (mirroring_ || origin == nullptr)
    return;
  mirroring_ = true;
  const int value = origin->appearance();
  store_.state().appearance_theme = appearanceTheme(value);
  applyColorScheme(QGuiApplication::styleHints(), value);
  for (PlayerWindow *window : windows_) {
    if (window->controller() != origin)
      window->controller()->setAppearance(value);
  }
  mirroring_ = false;
  emit darkAppearanceChanged();
  requestCheckpoint();
}

void WindowManager::mirrorSeekStep(PlayerController *origin) {
  if (mirroring_ || origin == nullptr)
    return;
  mirroring_ = true;
  const double value = origin->seekStepSeconds();
  store_.state().seek_step_seconds =
      std::clamp(static_cast<int>(std::lround(value)), 1, 60);
  for (PlayerWindow *window : windows_) {
    if (window->controller() != origin)
      window->controller()->setSeekStepSeconds(value);
  }
  mirroring_ = false;
  requestCheckpoint();
}

void WindowManager::mirrorWindowHugsVideo(PlayerController *origin) {
  if (mirroring_ || origin == nullptr)
    return;
  mirroring_ = true;
  const bool value = origin->windowHugsVideo();
  store_.state().window_hugs_video = value;
  for (PlayerWindow *window : windows_) {
    if (window->controller() != origin)
      window->controller()->setWindowHugsVideo(value);
  }
  mirroring_ = false;
  requestCheckpoint();
}

void WindowManager::mirrorPreservePitch(PlayerController *origin) {
  if (mirroring_ || origin == nullptr)
    return;
  mirroring_ = true;
  const bool value = origin->preservePitch();
  store_.state().preserve_pitch = value;
  for (PlayerWindow *window : windows_) {
    if (window->controller() != origin)
      window->controller()->setPreservePitch(value);
  }
  mirroring_ = false;
  requestCheckpoint();
}

void WindowManager::noteVolumeChanged(PlayerController *origin) {
  if (origin == nullptr)
    return;
  // Volume is deliberately NOT mirrored. QuickTime gives each window its own
  // level, and muting one video must not mute the others. What is persisted is
  // simply whichever window set it last, which is the value the next fresh
  // window is seeded with.
  store_.state().volume =
      std::clamp(static_cast<int>(std::lround(origin->volume() * 100.0)), 0,
                 100);
  requestCheckpoint();
}

void WindowManager::showPreferences() {
  // Preferences is app-level: one window, one persisted state, and its changes
  // are mirrored live onto every open player. It binds to the focused
  // window's controller through `appHost.focusedController`, so with no window
  // open there would be nothing to bind to -- create one first, which is also
  // the state a user who reaches Preferences from an empty app expects to
  // return to.
  if (windows_.isEmpty())
    (void)createWindow();

  if (preferences_ == nullptr) {
    if (preferences_component_ == nullptr) {
      preferences_component_ = new QQmlComponent(
          &engine_, QStringLiteral("Wam"), QStringLiteral("AppPreferences"),
          this);
    }
    // Initial properties, not a binding: this is the only creation path that
    // has the controller in place before the panel's own controls evaluate.
    preferences_ = preferences_component_->createWithInitialProperties(
        {{QStringLiteral("liveController"),
          QVariant::fromValue(focusedControllerObject())}},
        engine_.rootContext());
    if (preferences_ == nullptr) {
      qWarning() << "WAM could not create the Preferences window:"
                 << preferences_component_->errorString();
      return;
    }
    preferences_->setParent(this);
  }
  QMetaObject::invokeMethod(preferences_, "presentPreferences");
}

void WindowManager::openMedia() {
  // File > Open (and Cmd-O) must produce a NEW window, the way Finder-open and
  // argv do -- unless an empty window is already sitting there to claim it.
  //
  // The dialog is nonetheless hosted by a window that already exists rather
  // than by a window created up front for the result. Creating it first was
  // the obvious implementation and it is wrong: cancelling the dialog would
  // leave a blank player standing there, which is exactly the dead window the
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
  menu_bar_->setParent(this);
  return true;
}

} // namespace wam::qt
