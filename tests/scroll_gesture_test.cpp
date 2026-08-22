// Unit tests for the pointer-scroll gesture model: delta normalization
// (trackpad vs wheel, natural-scroll inversion), dominant-axis locking, the
// momentum tail, and the 100% volume detent.
//
// The model links no Qt at all, which is the whole point of it being a
// separate translation unit: every number the gesture feels like is decided
// here and proved here.

#include "qt/scroll_gesture.hpp"

#include <cmath>
#include <cstdio>
#include <string>

namespace {

int failures = 0;

void expect(bool condition, const char *message) {
  if (condition)
    return;
  ++failures;
  std::fprintf(stderr, "FAIL: %s\n", message);
}

void expectNear(double actual, double expected, double tolerance,
                const char *message) {
  if (std::abs(actual - expected) <= tolerance)
    return;
  ++failures;
  std::fprintf(stderr, "FAIL: %s (actual %.9f, expected %.9f)\n", message,
               actual, expected);
}

using wam::qt::ScrollAxis;
using wam::qt::ScrollGestureModel;
using wam::qt::ScrollPhase;
using wam::qt::ScrollSample;
using wam::qt::ScrollStep;

ScrollSample trackpad(double dx, double dy, bool inverted,
                      ScrollPhase phase = ScrollPhase::Update) {
  ScrollSample sample;
  sample.pixelX = dx;
  sample.pixelY = dy;
  // Qt's cocoa plugin fills angleDelta with exactly twice the pixel delta for
  // precise devices; reproduce that so the tests exercise the real shape and
  // prove that pixelDelta wins.
  sample.angleX = dx * 2.0;
  sample.angleY = dy * 2.0;
  sample.inverted = inverted;
  sample.phase = phase;
  return sample;
}

ScrollSample wheel(double notchesX, double notchesY, bool inverted) {
  ScrollSample sample;
  sample.angleX = notchesX * 120.0;
  sample.angleY = notchesY * 120.0;
  sample.inverted = inverted;
  sample.phase = ScrollPhase::NoPhase;
  return sample;
}

// -- normalization ---------------------------------------------------------

void testVerticalTrackpadRaisesVolumeOnPhysicalUp() {
  // Natural scrolling OFF: a wheel/finger movement away from the user is a
  // positive dy and must raise the volume.
  ScrollGestureModel plain;
  const ScrollStep up = plain.accumulate(trackpad(0.0, 100.0, false));
  expect(up.axis == ScrollAxis::Vertical, "vertical travel locks the Y axis");
  expectNear(up.volumeDelta, 100.0 * ScrollGestureModel::kVolumePerPixel, 1e-12,
             "natural-off up raises volume");
  expectNear(up.seekSeconds, 0.0, 0.0, "a vertical gesture never seeks");

  ScrollGestureModel plainDown;
  const ScrollStep down = plainDown.accumulate(trackpad(0.0, -100.0, false));
  expectNear(down.volumeDelta, -100.0 * ScrollGestureModel::kVolumePerPixel,
             1e-12, "natural-off down lowers volume");

  // Natural scrolling ON: AppKit has already flipped dy and reports it
  // through `inverted`, so the SAME physical gesture arrives with the
  // opposite sign and must still raise the volume.
  ScrollGestureModel natural;
  const ScrollStep naturalUp = natural.accumulate(trackpad(0.0, -100.0, true));
  expectNear(naturalUp.volumeDelta, 100.0 * ScrollGestureModel::kVolumePerPixel,
             1e-12, "natural-on physical up raises volume identically");

  ScrollGestureModel naturalDown;
  const ScrollStep naturalDownStep =
      naturalDown.accumulate(trackpad(0.0, 100.0, true));
  expectNear(naturalDownStep.volumeDelta,
             -100.0 * ScrollGestureModel::kVolumePerPixel, 1e-12,
             "natural-on physical down lowers volume identically");
}

void testWheelNotchesUseTheAngleFallback() {
  ScrollGestureModel model;
  const ScrollStep step = model.accumulate(wheel(0.0, 1.0, false));
  expect(step.axis == ScrollAxis::Vertical, "a wheel notch locks the Y axis");
  expectNear(step.volumeDelta, 0.05, 1e-12,
             "one wheel notch is five percent of volume");

  ScrollGestureModel twenty;
  double total = 0.0;
  for (int i = 0; i < 20; ++i)
    total += twenty.accumulate(wheel(0.0, 1.0, false)).volumeDelta;
  expectNear(total, 1.0, 1e-12, "twenty notches sweep silence to unity");
}

void testPixelDeltaWinsOverAngleDelta() {
  // A trackpad sample carries both; the pixel value must be the one used, or
  // the gesture would be twice as fast as designed.
  ScrollGestureModel model;
  const ScrollStep step = model.accumulate(trackpad(0.0, 60.0, false));
  expectNear(step.volumeDelta, 60.0 * ScrollGestureModel::kVolumePerPixel,
             1e-12, "pixelDelta is preferred over the doubled angleDelta");
}

void testFullSweepIsACoupleOfSwipes() {
  // The stated feel target: 0 -> 100% in about two comfortable swipes.
  const double swipePixels = 250.0;
  const double perSwipe = swipePixels * ScrollGestureModel::kVolumePerPixel;
  expectNear(perSwipe, 0.5, 1e-12, "a 250 px swipe is half the 0-100% range");
  expectNear(2.0 / perSwipe, 4.0, 1e-12,
             "0 -> 200% is four swipes with the boost range");
}

void testHorizontalSeeksForwardOnScrollRight() {
  // Qt: a positive delta scrolls toward the BEGINNING of a document, so
  // forward is the negation, and there is deliberately no `inverted`
  // compensation on this axis.
  ScrollGestureModel model;
  const ScrollStep forward = model.accumulate(trackpad(-100.0, 0.0, false));
  expect(forward.axis == ScrollAxis::Horizontal,
         "horizontal travel locks the X axis");
  expectNear(forward.seekSeconds, 100.0 * ScrollGestureModel::kSecondsPerPixel,
             1e-12, "scrolling right seeks forward");
  expectNear(forward.volumeDelta, 0.0, 0.0,
             "a horizontal gesture never changes volume");

  ScrollGestureModel back;
  expectNear(back.accumulate(trackpad(100.0, 0.0, false)).seekSeconds,
             -100.0 * ScrollGestureModel::kSecondsPerPixel, 1e-12,
             "scrolling left seeks backward");

  ScrollGestureModel naturalForward;
  expectNear(naturalForward.accumulate(trackpad(-100.0, 0.0, true)).seekSeconds,
             100.0 * ScrollGestureModel::kSecondsPerPixel, 1e-12,
             "the timeline sweeps the same way under natural scrolling");
}

void testSeekSensitivityIsDurationIndependent() {
  ScrollGestureModel notch;
  expectNear(notch.accumulate(wheel(-1.0, 0.0, false)).seekSeconds, 0.4, 1e-12,
             "one horizontal wheel notch is 0.4 s regardless of duration");
  ScrollGestureModel swipe;
  expectNear(swipe.accumulate(trackpad(-300.0, 0.0, false)).seekSeconds, 6.0,
             1e-12, "a 300 px swipe is six seconds");
}

// -- axis lock -------------------------------------------------------------

void testDominantAxisWinsAndHoldsForTheGesture() {
  ScrollGestureModel model;
  // A diagonal that is mostly vertical locks vertical...
  const ScrollStep first = model.accumulate(trackpad(4.0, 40.0, false));
  expect(first.axis == ScrollAxis::Vertical,
         "the dominant axis of the first admitted travel wins");
  // ...and a later strongly horizontal sample inside the SAME gesture is
  // still spent on volume, never on the timeline.
  const ScrollStep second = model.accumulate(trackpad(-80.0, 1.0, false));
  expect(second.axis == ScrollAxis::Vertical, "the lock holds for the gesture");
  expectNear(second.seekSeconds, 0.0, 0.0,
             "a locked vertical gesture never leaks into a seek");
  expectNear(second.volumeDelta, 1.0 * ScrollGestureModel::kVolumePerPixel,
             1e-12, "the locked axis keeps using its own component");
}

void testSubThresholdTravelIsHeldThenSpent() {
  ScrollGestureModel model;
  const ScrollStep tiny = model.accumulate(trackpad(0.0, 2.0, false));
  expect(tiny.axis == ScrollAxis::None && tiny.volumeDelta == 0.0,
         "travel below the lock threshold decides nothing yet");
  const ScrollStep second = model.accumulate(trackpad(0.0, 3.0, false));
  expect(second.axis == ScrollAxis::None,
         "still undecided one pixel short of the threshold");
  const ScrollStep third = model.accumulate(trackpad(0.0, 3.0, false));
  expect(third.axis == ScrollAxis::Vertical, "the threshold locks the axis");
  // 2 + 3 + 3: none of the user's movement is thrown away.
  expectNear(third.volumeDelta, 8.0 * ScrollGestureModel::kVolumePerPixel,
             1e-12, "the travel spent deciding is not discarded");
}

void testBeginPhaseStartsAFreshGesture() {
  ScrollGestureModel model;
  static_cast<void>(model.accumulate(trackpad(0.0, 40.0, false)));
  expect(model.lockedAxis() == ScrollAxis::Vertical, "locked vertical");
  const ScrollStep next =
      model.accumulate(trackpad(-40.0, 0.0, false, ScrollPhase::Begin));
  expect(next.axis == ScrollAxis::Horizontal,
         "a begin phase re-evaluates the axis");
}

void testResetReEvaluatesTheAxis() {
  ScrollGestureModel model;
  static_cast<void>(model.accumulate(trackpad(-40.0, 0.0, false)));
  expect(model.lockedAxis() == ScrollAxis::Horizontal, "locked horizontal");
  model.reset();
  expect(model.lockedAxis() == ScrollAxis::None, "reset releases the lock");
  const ScrollStep next = model.accumulate(trackpad(0.0, 40.0, false));
  expect(next.axis == ScrollAxis::Vertical,
         "the settled gesture re-decides on the next travel");
}

void testMomentumIsDegressive() {
  ScrollGestureModel model;
  const ScrollStep drag = model.accumulate(trackpad(0.0, 100.0, false));
  const ScrollStep tail =
      model.accumulate(trackpad(0.0, 100.0, false, ScrollPhase::Momentum));
  expectNear(tail.volumeDelta, drag.volumeDelta * 0.4, 1e-12,
             "the momentum tail is scaled down");
  expect(tail.axis == ScrollAxis::Vertical,
         "momentum stays on the gesture's locked axis");
}

void testNonFiniteAndEmptySamplesAreInert() {
  ScrollGestureModel model;
  ScrollSample bad;
  bad.pixelY = std::nan("");
  const ScrollStep step = model.accumulate(bad);
  expect(step.axis == ScrollAxis::None && step.volumeDelta == 0.0 &&
             step.seekSeconds == 0.0,
         "a non-finite sample is refused whole");
  const ScrollStep empty = model.accumulate(ScrollSample{});
  expect(empty.axis == ScrollAxis::None, "an empty sample decides nothing");
}

// -- detent ----------------------------------------------------------------

void testDetentParksOnUnityThenReleases() {
  ScrollGestureModel model;
  // 0.95 + 0.10 would be 1.05; the notch takes it.
  const double parked = model.volumeWithDetent(0.95, 0.10);
  expectNear(parked, 1.0, 0.0, "crossing unity parks exactly on unity");
  // Banked overshoot 0.05, still under the 0.08 breakthrough.
  const double held = model.volumeWithDetent(parked, 0.02);
  expectNear(held, 1.0, 0.0, "the notch resists until the charge is paid");
  // 0.05 + 0.02 + 0.04 = 0.11; 0.03 past the 0.08 breakthrough.
  const double released = model.volumeWithDetent(held, 0.04);
  expectNear(released, 1.03, 1e-12, "the excess over the breakthrough is kept");
}

void testDetentBreaksThroughInOneBigDelta() {
  ScrollGestureModel model;
  // A single fast flick must not need a second event to get past unity.
  const double released = model.volumeWithDetent(0.9, 0.5);
  expectNear(released, 1.0 + (0.4 - ScrollGestureModel::kDetentBreakthrough),
             1e-12, "a big single delta clears the notch in one step");
}

void testDetentWorksDownwardAndDischargesOnReversal() {
  ScrollGestureModel model;
  const double parked = model.volumeWithDetent(1.05, -0.10);
  expectNear(parked, 1.0, 0.0, "descending onto unity parks there too");
  // Reversing discharges: pushing back up must not be helped by the downward
  // charge already banked.
  const double up = model.volumeWithDetent(parked, 0.02);
  expectNear(up, 1.0, 0.0, "a reversal discharges rather than releasing");
  const double stillParked = model.volumeWithDetent(up, 0.03);
  expectNear(stillParked, 1.0, 0.0, "and re-charges from zero");
  const double free = model.volumeWithDetent(stillParked, 0.06);
  expectNear(free, 1.0 + (0.11 - ScrollGestureModel::kDetentBreakthrough),
             1e-12, "then breaks through upward on its own charge");
}

void testDetentIsIgnoredAwayFromUnity() {
  ScrollGestureModel model;
  expectNear(model.volumeWithDetent(0.20, 0.10), 0.30, 1e-12,
             "movement well below unity is unimpeded");
  expectNear(model.volumeWithDetent(1.50, 0.10), 1.60, 1e-12,
             "movement well above unity is unimpeded");
}

void testDetentClampsToTheBoostRange() {
  ScrollGestureModel model;
  expectNear(model.volumeWithDetent(1.95, 0.50), 2.0, 0.0,
             "the boost ceiling is 200%");
  expectNear(model.volumeWithDetent(0.05, -0.50), 0.0, 0.0,
             "the floor is silence");
  expectNear(model.volumeWithDetent(0.5, std::nan("")), 0.5, 0.0,
             "a non-finite delta leaves the level alone");
}

void testMagneticSnapForSliderDrags() {
  expectNear(ScrollGestureModel::snapVolumeToDetent(1.03), 1.0, 0.0,
             "a drag just above unity snaps to unity");
  expectNear(ScrollGestureModel::snapVolumeToDetent(0.95), 1.0, 0.0,
             "a drag just below unity snaps to unity");
  expectNear(ScrollGestureModel::snapVolumeToDetent(1.20), 1.20, 1e-12,
             "a drag outside the window keeps its value");
  expectNear(ScrollGestureModel::snapVolumeToDetent(2.40), 2.0, 0.0,
             "the snap clamps to the ceiling");
  expectNear(ScrollGestureModel::snapVolumeToDetent(-1.0), 0.0, 0.0,
             "the snap clamps to the floor");
}

}  // namespace

int main() {
  testVerticalTrackpadRaisesVolumeOnPhysicalUp();
  testWheelNotchesUseTheAngleFallback();
  testPixelDeltaWinsOverAngleDelta();
  testFullSweepIsACoupleOfSwipes();
  testHorizontalSeeksForwardOnScrollRight();
  testSeekSensitivityIsDurationIndependent();
  testDominantAxisWinsAndHoldsForTheGesture();
  testSubThresholdTravelIsHeldThenSpent();
  testBeginPhaseStartsAFreshGesture();
  testResetReEvaluatesTheAxis();
  testMomentumIsDegressive();
  testNonFiniteAndEmptySamplesAreInert();
  testDetentParksOnUnityThenReleases();
  testDetentBreaksThroughInOneBigDelta();
  testDetentWorksDownwardAndDischargesOnReversal();
  testDetentIsIgnoredAwayFromUnity();
  testDetentClampsToTheBoostRange();
  testMagneticSnapForSliderDrags();

  if (failures != 0) {
    std::fprintf(stderr, "scroll_gesture_test: %d failure(s)\n", failures);
    return 1;
  }
  std::printf("scroll_gesture_test: all checks passed\n");
  return 0;
}
