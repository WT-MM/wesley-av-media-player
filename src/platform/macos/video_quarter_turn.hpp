#pragma once

#include "media/native_media_source.hpp"

#include <CoreGraphics/CoreGraphics.h>

#include <cmath>
#include <optional>

// The one statement of what a presentable rotation is, shared by admission,
// the rebind proofs, the consumer and the layer geometry so the four cannot
// drift apart.
namespace wam::macos {

// The quarter turn a track matrix states, classified on the LINEAR part only.
// A portrait track legitimately carries a translation (tx equal to the coded
// height) that re-homes the rotated frame, so tx/ty are not part of the
// classification. Exact comparison rather than a tolerance: every muxer
// writes these as small exact integers, and a matrix merely NEAR a quarter
// turn is a shear this player would render wrong. Mirrors (negative
// determinant), shears and arbitrary angles are nullopt.
//
//     0 deg    a= 1 b= 0 c= 0 d= 1
//    90 deg    a= 0 b= 1 c=-1 d= 0     +x -> +y   (clockwise on screen)
//   180 deg    a=-1 b= 0 c= 0 d=-1
//   270 deg    a= 0 b=-1 c= 1 d= 0
[[nodiscard]] inline std::optional<int> quarterTurnDegrees(
    CGAffineTransform transform) noexcept {
  if (!std::isfinite(transform.a) || !std::isfinite(transform.b) ||
      !std::isfinite(transform.c) || !std::isfinite(transform.d) ||
      !std::isfinite(transform.tx) || !std::isfinite(transform.ty)) {
    return std::nullopt;
  }
  struct Turn {
    double a, b, c, d;
    int degrees;
  };
  constexpr Turn kTurns[]{{1.0, 0.0, 0.0, 1.0, 0},
                          {0.0, 1.0, -1.0, 0.0, 90},
                          {-1.0, 0.0, 0.0, -1.0, 180},
                          {0.0, -1.0, 1.0, 0.0, 270}};
  for (const Turn& turn : kTurns) {
    if (transform.a == turn.a && transform.b == turn.b &&
        transform.c == turn.c && transform.d == turn.d) {
      return turn.degrees;
    }
  }
  return std::nullopt;
}

// `degrees` normalised into [0, 360), or nullopt unless it is a quarter turn.
[[nodiscard]] inline std::optional<int> normalizedQuarterTurn(
    int degrees) noexcept {
  const int normalized = ((degrees % 360) + 360) % 360;
  if (normalized == 0 || normalized == 90 || normalized == 180 ||
      normalized == 270) {
    return normalized;
  }
  return std::nullopt;
}

// A descriptor states its rotation twice -- as an angle and as the
// identityTransform flag -- and the two must agree. A quarter turn is
// presentable; a descriptor whose two statements disagree is a corrupted fact
// rather than a rotated file, and is refused as one.
[[nodiscard]] inline bool quarterTurnRotationAdmitted(
    const media::MediaVideoFormat& video) noexcept {
  const std::optional<int> rotation =
      normalizedQuarterTurn(video.rotationDegrees);
  return rotation && video.identityTransform == (*rotation == 0);
}

}  // namespace wam::macos
