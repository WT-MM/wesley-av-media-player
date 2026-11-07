#pragma once

#include "state_store.hpp"

#include <QObject>

namespace wam::qt {

// The app-level preferences: one value each, persisted in the StateStore and
// live in every window at once. Controllers and QML (as `appSettings`) bind to
// this object; nothing copies a preference from one window to another.
class AppSettings final : public QObject {
  Q_OBJECT

  // 0 = light (default), 1 = dark, 2 = follow the operating system.
  Q_PROPERTY(int appearance READ appearance WRITE setAppearance NOTIFY
                 appearanceChanged)
  // Seconds skipped by the Left/Right arrow shortcuts and the transport's
  // skip buttons.
  Q_PROPERTY(int seekStepSeconds READ seekStepSeconds WRITE setSeekStepSeconds
                 NOTIFY seekStepSecondsChanged)
  Q_PROPERTY(int minimumSeekStepSeconds READ minimumSeekStepSeconds CONSTANT)
  Q_PROPERTY(int maximumSeekStepSeconds READ maximumSeekStepSeconds CONSTANT)
  // QuickTime-style floating window: the windowed frame hugs the video's
  // aspect ratio (no letterbox bars). See qml/Main.qml's re-snap machinery.
  Q_PROPERTY(bool windowHugsVideo READ windowHugsVideo WRITE setWindowHugsVideo
                 NOTIFY windowHugsVideoChanged)
  // LIVE PLAYBACK ONLY: at speeds other than 1x, true keeps the original
  // pitch (time stretching) and false is classic varispeed. Quick Edit's
  // Preserve pitch is a separate, export-scoped choice.
  Q_PROPERTY(bool preservePitch READ preservePitch WRITE setPreservePitch
                 NOTIFY preservePitchChanged)
  // Pointer-scroll gestures over the video surface (vertical = volume,
  // horizontal = timeline sweep).
  Q_PROPERTY(bool scrollGesturesEnabled READ scrollGesturesEnabled WRITE
                 setScrollGesturesEnabled NOTIFY scrollGesturesEnabledChanged)
  // The ceiling any window's volume may be raised to, normalized so 1.0 is
  // 100% (no amplification) and 4.0 is the engines' own gain ceiling.
  Q_PROPERTY(double maximumVolume READ maximumVolume WRITE setMaximumVolume
                 NOTIFY maximumVolumeChanged)

public:
  explicit AppSettings(::wam::StateStore &store, QObject *parent = nullptr);

  [[nodiscard]] int appearance() const;
  [[nodiscard]] int seekStepSeconds() const;
  [[nodiscard]] static constexpr int minimumSeekStepSeconds() {
    return ::wam::kMinimumSeekStepSeconds;
  }
  [[nodiscard]] static constexpr int maximumSeekStepSeconds() {
    return ::wam::kMaximumSeekStepSeconds;
  }
  [[nodiscard]] bool windowHugsVideo() const;
  [[nodiscard]] bool preservePitch() const;
  [[nodiscard]] bool scrollGesturesEnabled() const;
  [[nodiscard]] double maximumVolume() const;

  void setAppearance(int appearance);
  void setSeekStepSeconds(int seconds);
  void setWindowHugsVideo(bool hugsVideo);
  void setPreservePitch(bool preserve);
  void setScrollGesturesEnabled(bool enabled);
  void setMaximumVolume(double maximum);

  // Volume is per window and deliberately not a live setting: each window
  // keeps its own level, and the store records whichever window set one
  // last, boost included. A NEW window starts at that level capped at 100%,
  // so it never blasts at a boost chosen in another window or session.
  [[nodiscard]] double initialVolume() const;
  void rememberVolume(double volume);

signals:
  void appearanceChanged();
  void seekStepSecondsChanged();
  void windowHugsVideoChanged();
  void preservePitchChanged();
  void scrollGesturesEnabledChanged();
  void maximumVolumeChanged();
  // Any persisted value changed; the store needs a checkpoint.
  void edited();

private:
  ::wam::StateStore &store_;
};

} // namespace wam::qt
