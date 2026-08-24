#include "scroll_gesture.hpp"

#include <algorithm>
#include <cmath>

namespace wam::qt {
namespace {

[[nodiscard]] bool finite(double value) noexcept {
  return std::isfinite(value);
}

// The caller's ceiling, sanitized. A non-finite or below-unity maximum falls
// back to the default one rather than trapping the level under 100%: the
// Preferences setting's own floor IS 100%, so unity always remains reachable.
[[nodiscard]] double clampVolume(double value, double maximum) noexcept {
  const double ceiling =
      std::isfinite(maximum) && maximum >= ScrollGestureModel::kDetentValue
          ? maximum
          : ScrollGestureModel::kMaximumVolume;
  return std::clamp(value, ScrollGestureModel::kMinimumVolume, ceiling);
}

}  // namespace

void ScrollGestureModel::reset() noexcept {
  axis_ = ScrollAxis::None;
  pending_x_ = 0.0;
  pending_y_ = 0.0;
  detent_charge_ = 0.0;
}

ScrollStep ScrollGestureModel::accumulate(const ScrollSample &sample) noexcept {
  // A begin phase is unambiguously a new gesture, so the axis is re-decided
  // there. Everything else (a real wheel reports no phase at all) is ended by
  // the caller's settle timer, which calls reset().
  if (sample.phase == ScrollPhase::Begin)
    reset();

  if (!finite(sample.pixelX) || !finite(sample.pixelY) ||
      !finite(sample.angleX) || !finite(sample.angleY)) {
    return {};
  }

  // Prefer the precise delta. On macOS a trackpad fills pixelDelta with
  // NSEvent's own scrollingDelta and a real wheel leaves it null, so this is
  // an exact device discriminator and not a guess.
  const bool precise = sample.pixelX != 0.0 || sample.pixelY != 0.0;
  double dx = precise ? sample.pixelX : sample.angleX;
  double dy = precise ? sample.pixelY : sample.angleY;
  if (dx == 0.0 && dy == 0.0)
    return {};

  // Axis lock: accumulate until one axis has travelled far enough to be the
  // obvious intent, then that axis owns the gesture until it is reset. VLC
  // does the same, and without it a two-finger swipe that drifts by a few
  // degrees changes the volume in the middle of a timeline sweep.
  if (axis_ == ScrollAxis::None) {
    pending_x_ += dx;
    pending_y_ += dy;
    const double travelX = std::abs(pending_x_);
    const double travelY = std::abs(pending_y_);
    if (std::max(travelX, travelY) < kAxisLockTravel)
      return {};
    axis_ = travelY >= travelX ? ScrollAxis::Vertical : ScrollAxis::Horizontal;
    // The travel spent deciding is not discarded -- it is the first part of
    // the user's movement and it belongs to the gesture.
    dx = pending_x_;
    dy = pending_y_;
    pending_x_ = 0.0;
    pending_y_ = 0.0;
  }

  const double scale =
      sample.phase == ScrollPhase::Momentum ? kMomentumScale : 1.0;

  ScrollStep step;
  step.axis = axis_;
  if (axis_ == ScrollAxis::Vertical) {
    // Device-physical: AppKit has already applied the natural-scroll
    // preference to dy and reports it through `inverted`. Undoing it here is
    // what makes a physical upward gesture raise the volume under both
    // settings, which is the VLC/IINA convention.
    const double physicalUp = sample.inverted ? -dy : dy;
    const double perUnit = precise ? kVolumePerPixel : kVolumePerAngleUnit;
    step.volumeDelta = physicalUp * perUnit * scale;
  } else {
    // Document-direction: a positive delta scrolls toward the beginning of a
    // document everywhere in Qt, so forward is the negation. Deliberately no
    // `inverted` compensation -- a timeline is a horizontal document and must
    // sweep the same way every other horizontally scrollable surface on the
    // machine does.
    const double perUnit = precise ? kSecondsPerPixel : kSecondsPerAngleUnit;
    step.seekSeconds = -dx * perUnit * scale;
  }
  return step;
}

double ScrollGestureModel::volumeWithDetent(double current, double delta,
                                            double maximum) noexcept {
  if (!finite(current))
    current = kDetentValue;
  current = clampVolume(current, maximum);
  if (!finite(delta) || delta == 0.0)
    return current;

  const double raw = current + delta;
  const bool parked = current == kDetentValue;
  const bool crosses = (current < kDetentValue && raw > kDetentValue) ||
                       (current > kDetentValue && raw < kDetentValue);

  if (!parked && !crosses) {
    detent_charge_ = 0.0;
    return clampVolume(raw, maximum);
  }

  // A reversal discharges the resistance: pushing back down off the notch
  // must not be helped along by the charge built up pushing up into it.
  if ((delta > 0.0 && detent_charge_ < 0.0) ||
      (delta < 0.0 && detent_charge_ > 0.0)) {
    detent_charge_ = 0.0;
  }

  detent_charge_ += crosses ? (raw - kDetentValue) : delta;
  if (std::abs(detent_charge_) <= kDetentBreakthrough)
    return kDetentValue;

  const double released =
      detent_charge_ - std::copysign(kDetentBreakthrough, detent_charge_);
  detent_charge_ = 0.0;
  return clampVolume(kDetentValue + released, maximum);
}

double ScrollGestureModel::snapVolumeToDetent(double value) noexcept {
  if (!finite(value))
    return kDetentValue;
  // This is the MAGNETIC half of the detent, asked only about a value a
  // slider already produced inside its own 0..maximum track -- so the only
  // ceiling it can honestly apply is the ABSOLUTE one (the engine's gain
  // ceiling), not the window's currently configured maximum, which it is not
  // told and which the slider has already enforced. Clamping to the default
  // 200% here would silently drag a 350% slider back to 200%.
  const double bounded = clampVolume(value, kAbsoluteMaximumVolume);
  if (std::abs(bounded - kDetentValue) < kDetentBreakthrough)
    return kDetentValue;
  return bounded;
}

}  // namespace wam::qt
