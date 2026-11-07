#include "app_settings.hpp"

#include "scroll_gesture.hpp"

#include <QGuiApplication>
#include <QStyleHints>

#include <algorithm>
#include <cmath>

namespace wam::qt {

static_assert(::wam::kUnityVolumePercent ==
              ScrollGestureModel::kDetentValue * 100.0);
static_assert(::wam::kMaximumVolumePercent ==
              ScrollGestureModel::kAbsoluteMaximumVolume * 100.0);

namespace {

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

void applyColorScheme(::wam::AppearanceTheme theme) {
  QStyleHints *style_hints = QGuiApplication::styleHints();
  if (!style_hints)
    return;
  switch (theme) {
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

int percent(double normalized) {
  return static_cast<int>(std::lround(normalized * 100.0));
}

} // namespace

AppSettings::AppSettings(::wam::StateStore &store, QObject *parent)
    : QObject(parent), store_(store) {
  // The saved appearance decides the process-wide colour scheme before any
  // window exists, so the very first window is painted in the right one rather
  // than flashing the default and correcting itself.
  applyColorScheme(store_.state().appearance_theme);
}

int AppSettings::appearance() const {
  return static_cast<int>(store_.state().appearance_theme);
}

int AppSettings::seekStepSeconds() const {
  return store_.state().seek_step_seconds;
}

bool AppSettings::windowHugsVideo() const {
  return store_.state().window_hugs_video;
}

bool AppSettings::preservePitch() const {
  return store_.state().preserve_pitch;
}

bool AppSettings::scrollGesturesEnabled() const {
  return store_.state().scroll_gestures;
}

double AppSettings::maximumVolume() const {
  return store_.state().maximum_volume / 100.0;
}

void AppSettings::setAppearance(int appearance) {
  const ::wam::AppearanceTheme theme = appearanceTheme(appearance);
  if (store_.state().appearance_theme == theme)
    return;
  store_.state().appearance_theme = theme;
  applyColorScheme(theme);
  emit appearanceChanged();
  emit edited();
}

void AppSettings::setSeekStepSeconds(int seconds) {
  const int bounded =
      std::clamp(seconds, ::wam::kMinimumSeekStepSeconds,
                 ::wam::kMaximumSeekStepSeconds);
  if (store_.state().seek_step_seconds == bounded)
    return;
  store_.state().seek_step_seconds = bounded;
  emit seekStepSecondsChanged();
  emit edited();
}

void AppSettings::setWindowHugsVideo(bool hugsVideo) {
  if (store_.state().window_hugs_video == hugsVideo)
    return;
  store_.state().window_hugs_video = hugsVideo;
  emit windowHugsVideoChanged();
  emit edited();
}

void AppSettings::setPreservePitch(bool preserve) {
  if (store_.state().preserve_pitch == preserve)
    return;
  store_.state().preserve_pitch = preserve;
  emit preservePitchChanged();
  emit edited();
}

void AppSettings::setScrollGesturesEnabled(bool enabled) {
  if (store_.state().scroll_gestures == enabled)
    return;
  store_.state().scroll_gestures = enabled;
  emit scrollGesturesEnabledChanged();
  emit edited();
}

void AppSettings::setMaximumVolume(double maximum) {
  if (!std::isfinite(maximum))
    return;
  const int bounded = std::clamp(percent(maximum), ::wam::kUnityVolumePercent,
                                 ::wam::kMaximumVolumePercent);
  if (store_.state().maximum_volume == bounded)
    return;
  store_.state().maximum_volume = bounded;
  emit maximumVolumeChanged();
  emit edited();
}

double AppSettings::initialVolume() const {
  return std::clamp(store_.state().volume, 0, ::wam::kUnityVolumePercent) /
         100.0;
}

void AppSettings::rememberVolume(double volume) {
  if (!std::isfinite(volume))
    return;
  store_.state().volume =
      std::clamp(percent(volume), 0, ::wam::kMaximumVolumePercent);
  emit edited();
}

} // namespace wam::qt
