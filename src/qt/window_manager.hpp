#pragma once

#include "app_settings.hpp"
#include "state_store.hpp"

#include <QList>
#include <QObject>
#include <QPointer>
#include <QString>
#include <QUrl>

#include <cmath>
#include <cstdint>

class QQmlComponent;
class QQmlContext;
class QQmlEngine;
class QQuickWindow;
class QWindow;
class QTimer;

namespace wam::qt {

class MacWindowChrome;
class PlayerController;
class WindowManager;

// Process-wide cap on simultaneously open player windows.
//
// The number itself, and the reasoning behind it, live in
// src/platform/macos/native_concurrency_limits.hpp, because every native
// per-session resource envelope (the audio output slot table, the audio
// session and video consumer quarantine tables, the layer-presentation
// counter) is derived from the same cap and those live in the platform layer
// with no dependency edge to here. window_manager.cpp static_asserts the two
// values equal on macOS, so the window factory and the native envelope cannot
// drift apart. This restatement exists so non-macOS builds -- which have no
// native stack at all -- still have a bound.
inline constexpr int kMaximumPlayerWindows = 16;

// New windows cascade rather than stacking exactly on top of one another, the
// way every document-based macOS app does, so "open three files" produces
// three findable windows instead of one apparent window with two hidden
// behind it. macOS's own cascade step is 20pt at 1x; 40 reads better at the
// sizes a video window actually takes.
inline constexpr int kWindowCascadeStep = 40;

// ---------------------------------------------------------------------------
// Per-file auto-resume bookkeeping.
//
// One tracker per window: two windows can hold two different files at two
// different positions, and each has to persist its own.
// ---------------------------------------------------------------------------
struct ResumeSnapshot {
  QString local_source;
  double position = 0.0;
  double duration = 0.0;
  bool position_observed = false;
};

class ResumeTracker {
public:
  [[nodiscard]] const ResumeSnapshot &snapshot() const { return snapshot_; }
  [[nodiscard]] quint64 generation() const { return generation_; }

  void observePosition(double position) {
    if (std::isfinite(position) && position > 0.0) {
      snapshot_.position = position;
      snapshot_.position_observed = true;
    }
  }

  void observeDuration(double duration) {
    if (std::isfinite(duration) && duration > 0.0)
      snapshot_.duration = duration;
  }

  void commitZeroPosition(quint64 generation) {
    if (generation == generation_) {
      snapshot_.position = 0.0;
      snapshot_.position_observed = true;
    }
  }

  ResumeSnapshot transitionTo(const QString &local_source) {
    ResumeSnapshot previous = snapshot_;
    snapshot_ = ResumeSnapshot{local_source, 0.0, 0.0, false};
    ++generation_;
    return previous;
  }

private:
  ResumeSnapshot snapshot_;
  quint64 generation_ = 0;
};

// ---------------------------------------------------------------------------
// One player window: its own controller, its own native playback session, its
// own window chrome, its own QML context, its own resume tracker.
//
// Destruction order is load-bearing: the QML root (and with it the
// MpvVideoItem, which detaches the render surface) must go first, then the
// chrome bridge (which removes its AppKit event monitor), and only then the
// controller (whose destructor tears the native playback session down).
// ~PlayerWindow deletes them explicitly in that order.
// ---------------------------------------------------------------------------
class PlayerWindow final : public QObject {
  Q_OBJECT

public:
  PlayerWindow(WindowManager &manager, QQmlComponent &component,
               QQmlEngine &engine);
  ~PlayerWindow() override;

  PlayerWindow(const PlayerWindow &) = delete;
  PlayerWindow &operator=(const PlayerWindow &) = delete;

  [[nodiscard]] bool valid() const { return qml_root_ != nullptr; }
  [[nodiscard]] PlayerController *controller() const { return controller_; }
  [[nodiscard]] QQuickWindow *window() const { return window_; }
  [[nodiscard]] QObject *qmlRoot() const { return qml_root_; }

  // True while this window holds no media, or is already opening `source`:
  // the states in which an "open" that would otherwise create a window claims
  // this window instead, so a blank player is never left behind next to the
  // file the user actually asked for. A window opening a different file is
  // taken, so a multi-file open gives each file its own window.
  [[nodiscard]] bool claimableFor(const QUrl &source) const;

  [[nodiscard]] bool open(const QUrl &source);
  void raiseWindow();
  void placeAt(int x, int y, int width, int height);
  void cascadeFrom(const PlayerWindow &previous);

  // Flushes this window's tracked playback position into the shared state
  // store. Called for every window at each persistence checkpoint.
  void rememberTrackedPosition();

private:
  void wireResumeTracking();
  void applyPendingResume();
  void rememberPosition(const ResumeSnapshot &snapshot);

  WindowManager &manager_;
  QQmlContext *context_ = nullptr;
  PlayerController *controller_ = nullptr;
  MacWindowChrome *chrome_ = nullptr;
  QObject *qml_root_ = nullptr;
  QQuickWindow *window_ = nullptr;

  ResumeTracker resume_tracker_;
  double resume_position_ = 0.0;
  bool resume_pending_ = false;
};

// ---------------------------------------------------------------------------
// The window factory and everything that is app-level rather than per-window:
// the state store and the app-level settings backed by it, the single desktop
// menu bar, the single Preferences window, and focus routing.
// ---------------------------------------------------------------------------
class WindowManager final : public QObject {
  Q_OBJECT

  // The focused window's controller and QML root. The desktop menu bar binds
  // to these, so Playback/View act on whichever window the user is looking at
  // while Preferences/About/Quit stay app-level. Both are null when no window
  // is open, which the menu items guard on.
  Q_PROPERTY(QObject *focusedController READ focusedControllerObject NOTIFY
                 focusChanged)
  Q_PROPERTY(QObject *focusedWindow READ focusedWindowObject NOTIFY focusChanged)
  Q_PROPERTY(int windowCount READ windowCount NOTIFY windowCountChanged)
  Q_PROPERTY(
      bool darkAppearance READ darkAppearance NOTIFY darkAppearanceChanged)

public:
  WindowManager(QQmlEngine &engine, ::wam::StateStore &store,
                QObject *parent = nullptr);
  ~WindowManager() override;

  WindowManager(const WindowManager &) = delete;
  WindowManager &operator=(const WindowManager &) = delete;

  [[nodiscard]] ::wam::StateStore &stateStore() { return store_; }

  // Installs the one desktop menu bar (qml/AppMenu.qml). It belongs to the
  // application rather than to any window, so it survives the last window
  // closing -- which is exactly the macOS convention this player follows.
  [[nodiscard]] bool createMenuBar();

  // Stops the checkpoint timer and writes any pending state immediately.
  void flushPersistence();

  // Creates, shows and focuses a fresh window. Returns nullptr only when the
  // window cap is reached or QML instantiation failed.
  PlayerWindow *createWindow();

  // The one entry point every "open this file" gesture funnels through --
  // Finder/LaunchServices relay, argv, and the File > Open dialog. Claims an
  // empty window if there is one, otherwise creates a window.
  Q_INVOKABLE bool openUrl(const QUrl &source);

  [[nodiscard]] int windowCount() const {
    return static_cast<int>(windows_.size());
  }
  [[nodiscard]] const QList<PlayerWindow *> &windows() const {
    return windows_;
  }
  [[nodiscard]] PlayerWindow *focusedPlayerWindow() const;
  [[nodiscard]] QObject *focusedControllerObject() const;
  [[nodiscard]] QObject *focusedWindowObject() const;
  [[nodiscard]] bool darkAppearance() const;

  // The window an "open" would claim rather than displace, or nullptr.
  [[nodiscard]] PlayerWindow *claimableWindow(const QUrl &source) const;

  void noteFocused(PlayerWindow *window);
  void noteClosed(PlayerWindow *window);
  void requestCheckpoint();

  [[nodiscard]] AppSettings &settings() { return settings_; }
  [[nodiscard]] const AppSettings &settings() const { return settings_; }

  // Writes every window's tracked position into the store, then saves it if
  // anything is dirty. This is the persistence checkpoint body.
  bool saveIfDirty();

  // Tears every window down in an orderly way. Called from aboutToQuit so a
  // Cmd-Q with N playing windows retires N native sessions rather than
  // abandoning them at process exit.
  void closeAllWindows();

  // QML-facing, from qml/Main.qml and the desktop menu bar.
  Q_INVOKABLE void showPreferences();
  Q_INVOKABLE void openMedia();
  // The "h" macro and the View menu's Hide and Pause All: pause every window's
  // playback, then hide the whole application. Unhiding restores the windows
  // exactly as they were, still paused -- nothing ever resumes on its own.
  Q_INVOKABLE void hideAndPauseAll();
  // Pause-only half, also run when macOS hides the app for any other reason
  // (Cmd-H, Hide Others, the Dock menu), so the system gesture and the WAM
  // gesture are indistinguishable.
  Q_INVOKABLE void pauseAll();

signals:
  void focusChanged();
  void windowCountChanged();
  void darkAppearanceChanged();

private:
  QQmlEngine &engine_;
  ::wam::StateStore &store_;
  AppSettings settings_;
  QQmlComponent *component_ = nullptr;
  QTimer *checkpoint_timer_ = nullptr;
  ::wam::StateCheckpointGate checkpoint_;
  QObject *menu_bar_ = nullptr;

public:
  // The app-level menu bar object, for the WAM_TEST_WINDOW_SCRIPT `menu` verb.
  // Reading the real menu's item titles and check marks is how a scripted
  // round proves the native menu was actually built -- the alternative, a
  // screenshot, cannot see a menu bar that is set to auto-hide.
  [[nodiscard]] QObject *menuBarObject() const noexcept { return menu_bar_; }

private:
  QWindow *preferences_ = nullptr;
  QList<PlayerWindow *> windows_;
  QPointer<PlayerWindow> focused_;
  PlayerWindow *last_created_ = nullptr;
  bool tearing_down_ = false;
};

} // namespace wam::qt
