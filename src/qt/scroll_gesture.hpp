#pragma once

#include <cstdint>

// Pointer-scroll gestures over the video surface: vertical scroll modulates
// this window's volume, horizontal scroll sweeps the timeline (VLC/IINA).
//
// The model is deliberately free of every Qt dependency so the normalization,
// axis-lock and detent arithmetic can be unit-tested from a translation unit
// that links no GUI at all. The QML side supplies the raw wheel fields and the
// controller turns the returned step into volume/scrub calls.
//
// WHAT QT DELIVERS ON macOS (measured on Qt 6.11.1; see the notes on each
// field below and scratchpad/scroll_volume_report.md for the raw capture):
//
//   * A trackpad produces a non-null pixelDelta -- NSEvent's scrollingDelta
//     verbatim -- and an angleDelta that is exactly twice it. A real wheel
//     produces a NULL pixelDelta and an angleDelta bounded to +/-120 per
//     notch. So "pixelDelta if non-zero, else angleDelta" is an exact
//     trackpad/wheel discriminator, not a heuristic.
//   * Qt passes AppKit's isDirectionInvertedFromDevice straight through as
//     QWheelEvent::inverted() and does NOT un-invert the deltas. Under the
//     natural-scroll preference the deltas are already flipped and inverted()
//     is true.
//   * A positive delta on either axis scrolls toward the BEGINNING of a
//     document (QQuickFlickable negates it before moving content).
//   * Phases: 0 none (real wheels), 1 begin, 2 update, 3 end, 4 momentum.
//     A finger gesture is 1,2..,3 and is followed by a separate momentum
//     burst 1,4..,3.

namespace wam::qt {

// Mirrors Qt::ScrollPhase without including QtGui.
enum class ScrollPhase : int {
  NoPhase = 0,
  Begin = 1,
  Update = 2,
  End = 3,
  Momentum = 4,
};

enum class ScrollAxis : int {
  None = 0,
  Vertical = 1,
  Horizontal = 2,
};

struct ScrollSample {
  double pixelX = 0.0;
  double pixelY = 0.0;
  double angleX = 0.0;
  double angleY = 0.0;
  bool inverted = false;
  ScrollPhase phase = ScrollPhase::NoPhase;
};

struct ScrollStep {
  ScrollAxis axis = ScrollAxis::None;
  // Volume units, where 1.0 is 100%. Positive raises the level.
  double volumeDelta = 0.0;
  // Seconds along the timeline. Positive moves forward.
  double seekSeconds = 0.0;
};

class ScrollGestureModel {
public:
  // ---- Feel constants. These are the whole "how does it feel" surface; they
  // are public so the unit test and the report can name them exactly.

  // Volume. A comfortable trackpad swipe is ~250 px of pixelDelta, so a full
  // 0 -> 100% sweep is two swipes and 0 -> 200% is four.
  static constexpr double kVolumePerPixel = 1.0 / 500.0;
  // 5% per wheel notch (120 angle units): twenty notches from silence to
  // unity, which is the VLC/IINA feel on a real wheel.
  static constexpr double kVolumePerAngleUnit = 0.05 / 120.0;

  // Seek. Deliberately NOT proportional to duration -- a duration-relative
  // sweep is unusable on a three-hour file and twitchy on a thirty-second
  // one. 0.4 s per wheel notch sits in the middle of VLC's range.
  static constexpr double kSecondsPerAngleUnit = 0.4 / 120.0;
  // Trackpad: 0.02 s per pixel, i.e. a 300 px swipe is 6 s and a hard flick
  // (~1000 px with its momentum tail) is about 20 s.
  static constexpr double kSecondsPerPixel = 0.02;

  // Momentum tails are degressive: the flick's inertia should carry the
  // gesture a little further, not run away with it.
  static constexpr double kMomentumScale = 0.4;

  // Axis lock. Movement is accumulated until one axis passes this much travel
  // (in the sample's own units), then that axis owns the rest of the gesture.
  static constexpr double kAxisLockTravel = 6.0;

  // The 100% detent. Crossing unity parks there until this much further
  // travel has been banked -- about 40 px of trackpad, or 1.6 wheel notches.
  static constexpr double kDetentValue = 1.0;
  static constexpr double kDetentBreakthrough = 0.08;

  static constexpr double kMinimumVolume = 0.0;
  // The DEFAULT ceiling, i.e. the Preferences panel's default "Maximum
  // volume" of 200%. Every caller that knows the window's configured maximum
  // passes it; this is the fallback for one that does not.
  static constexpr double kMaximumVolume = 2.0;
  // The highest ceiling the setting may ever be raised to: the native gain
  // stage's kMaximumGain (4.0, +12 dB -- see
  // src/platform/macos/native_audio_render_core.hpp). Nothing above this is
  // ever sent to an engine, whatever the UI is configured for.
  static constexpr double kAbsoluteMaximumVolume = 4.0;

  // Folds one wheel event into the gesture. Returns the step to apply; an
  // all-zero step means "nothing to do yet" (still deciding the axis, or an
  // empty event).
  [[nodiscard]] ScrollStep accumulate(const ScrollSample &sample) noexcept;

  // Ends the gesture: the next event re-decides the axis. Called when the
  // settle timer fires, when the gesture is disabled, and on teardown.
  void reset() noexcept;

  [[nodiscard]] ScrollAxis lockedAxis() const noexcept { return axis_; }

  // Applies `delta` to `current` with the 100% detent, clamped to
  // [kMinimumVolume, `maximum`]. Stateful: the resistance is charged across
  // successive calls, and a reversal discharges it.
  //
  // `maximum` is the window's configured "Maximum volume" (the Preferences
  // setting, 1.0 .. kAbsoluteMaximumVolume). It is a parameter rather than a
  // constant because it is a live, per-window, user-changeable bound; a
  // non-finite or below-unity value falls back to kMaximumVolume, so unity is
  // always reachable.
  [[nodiscard]] double volumeWithDetent(
      double current, double delta,
      double maximum = kMaximumVolume) noexcept;

  // The magnetic half of the same detent, for a slider drag: any value within
  // one breakthrough of unity snaps to exactly unity. Pure. Clamped only to
  // the ABSOLUTE ceiling -- the slider's own track already enforces the
  // window's configured maximum, and re-applying a default one here would
  // drag a legitimately boosted value back down.
  [[nodiscard]] static double snapVolumeToDetent(double value) noexcept;

private:
  ScrollAxis axis_ = ScrollAxis::None;
  double pending_x_ = 0.0;
  double pending_y_ = 0.0;
  double detent_charge_ = 0.0;
};

}  // namespace wam::qt
