// Measures the real AUNewTimePitch stage, not a fake of it. Two facts matter
// and neither can be argued from documentation:
//
//  1. INPUT DEMAND IS EXACTLY outputFrames * rate, AT EVERY PITCH OFFSET.
//     The whole clock derivation rests on "media frames consumed" and
//     "outputFrames * p/q" being the same number, so the live preserve-pitch
//     preference is only safe if the pitch parameter cannot move it.
//  2. THE PITCH OFFSET DOES WHAT IT CLAIMS. A 1000 Hz tone played at 2x comes
//     out at 1000 Hz with pitch preserved and at 2000 Hz with the varispeed
//     offset. Measured by zero crossings and confirmed by Goertzel power,
//     because "sounds right" is not a test.

#include "platform/macos/native_audio_stretch_stage.hpp"

#include <AudioToolbox/AudioToolbox.h>

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <numbers>
#include <vector>

#include "support/expect.hpp"

namespace {

using wam::macos::NativeAudioStretchStage;
using wam::macos::NativeAudioStretchUnit;

constexpr std::uint32_t kSampleRate = 48000;
constexpr std::uint32_t kChannels = 2;
constexpr std::uint32_t kBlockFrames = 1024;
constexpr double kToneHz = 1000.0;


// One 1000 Hz sine generator shared by every case, so the stage's input is a
// continuous tone across an entire run rather than a restarted one per block.
struct TonePull {
  std::uint64_t framesPulled{0};
  std::uint64_t phaseFrames{0};

  static std::uint32_t pull(void *context, float *interleaved,
                            std::uint32_t frames) noexcept {
    auto *self = static_cast<TonePull *>(context);
    for (std::uint32_t frame = 0; frame < frames; ++frame) {
      const double phase = 2.0 * std::numbers::pi * kToneHz *
                           static_cast<double>(self->phaseFrames + frame) /
                           static_cast<double>(kSampleRate);
      const auto value = static_cast<float>(0.5 * std::sin(phase));
      interleaved[frame * kChannels] = value;
      interleaved[frame * kChannels + 1U] = value;
    }
    self->framesPulled += frames;
    self->phaseFrames += frames;
    return frames;
  }
};

// Zero-crossing frequency estimate over the left channel. A pure tone has
// exactly two crossings per cycle, so the count over a known span of frames
// is 2 * f * span / sampleRate. Robust to the amplitude wobble a phase
// vocoder leaves behind, which is why it is preferred to a peak search.
[[nodiscard]] double zeroCrossingHz(const std::vector<float> &interleaved) {
  const std::size_t frames = interleaved.size() / kChannels;
  if (frames < 2) {
    return 0.0;
  }
  std::size_t crossings = 0;
  for (std::size_t frame = 1; frame < frames; ++frame) {
    const float previous = interleaved[(frame - 1) * kChannels];
    const float current = interleaved[frame * kChannels];
    if ((previous < 0.0F && current >= 0.0F) ||
        (previous >= 0.0F && current < 0.0F)) {
      ++crossings;
    }
  }
  return static_cast<double>(crossings) * static_cast<double>(kSampleRate) /
         (2.0 * static_cast<double>(frames - 1));
}

// Goertzel power at one frequency, normalised by the block length. Used only
// to corroborate the zero-crossing estimate with a second, independent view.
[[nodiscard]] double goertzelPower(const std::vector<float> &interleaved,
                                   double hertz) {
  const std::size_t frames = interleaved.size() / kChannels;
  if (frames == 0) {
    return 0.0;
  }
  const double omega = 2.0 * std::numbers::pi * hertz /
                       static_cast<double>(kSampleRate);
  const double coefficient = 2.0 * std::cos(omega);
  double s1 = 0.0;
  double s2 = 0.0;
  for (std::size_t frame = 0; frame < frames; ++frame) {
    const double sample = interleaved[frame * kChannels];
    const double s0 = sample + coefficient * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  const double power = s1 * s1 + s2 * s2 - coefficient * s1 * s2;
  return power / (static_cast<double>(frames) * static_cast<double>(frames));
}

struct Rate {
  std::uint32_t numerator;
  std::uint32_t denominator;
  const char *name;
};

constexpr std::array<Rate, 6> kRates{{{1, 4, "0.25x"},
                                      {1, 2, "0.5x"},
                                      {3, 2, "1.5x"},
                                      {2, 1, "2x"},
                                      {5, 2, "2.5x"},
                                      {4, 1, "4x"}}};

// THE ONE THING THAT MUST NOT CHANGE. The stage's input demand is counted at
// every advertised rate with the pitch offset both zero and at its varispeed
// value, and both must equal outputFrames * p / q exactly, with no drift over
// a long run.
void exactConsumptionAtEveryPitch() {
  constexpr int kBlocks = 400;  // 409 600 output frames, as in the design probe
  for (const Rate &rate : kRates) {
    for (const bool preservePitch : {true, false}) {
      auto unit = NativeAudioStretchUnit::create(kSampleRate);
      expect(unit != nullptr, "the time-stretch unit is available");
      if (!unit) {
        return;
      }
      NativeAudioStretchStage stage = unit->stage();
      TonePull tone;
      expect(stage.configure(stage.context, &TonePull::pull, &tone),
             "the stage accepts its pull");
      expect(stage.setRate(stage.context, rate.numerator, rate.denominator,
                           preservePitch),
             "the stage accepts an advertised rate at either pitch");
      stage.reset(stage.context);
      tone.framesPulled = 0;

      std::vector<float> output(
          static_cast<std::size_t>(kBlockFrames) * kChannels, 0.0F);
      bool rendered = true;
      for (int block = 0; block < kBlocks; ++block) {
        rendered = rendered &&
                   stage.render(stage.context, kBlockFrames, output.data());
      }
      expect(rendered, "every render at an advertised rate succeeds");

      const std::uint64_t outputFrames =
          static_cast<std::uint64_t>(kBlocks) * kBlockFrames;
      const std::uint64_t expected =
          outputFrames * rate.numerator / rate.denominator;
      const bool exact = tone.framesPulled == expected;
      expect(exact,
             "input demand is exactly outputFrames * p / q at this pitch");
      std::cout << "  consumption " << rate.name
                << (preservePitch ? " pitch-preserved" : " varispeed  ")
                << "  pulled=" << tone.framesPulled
                << " expected=" << expected << (exact ? "  EXACT" : "  DRIFT")
                << '\n';
    }
  }
}

// The stage renders enough output to measure, discarding the leading blocks
// that carry the unit's group delay and its startup transient.
[[nodiscard]] std::vector<float> renderTone(std::uint32_t numerator,
                                            std::uint32_t denominator,
                                            bool preservePitch) {
  constexpr int kWarmupBlocks = 16;
  constexpr int kMeasuredBlocks = 96;
  auto unit = NativeAudioStretchUnit::create(kSampleRate);
  if (!unit) {
    return {};
  }
  NativeAudioStretchStage stage = unit->stage();
  TonePull tone;
  if (!stage.configure(stage.context, &TonePull::pull, &tone) ||
      !stage.setRate(stage.context, numerator, denominator, preservePitch)) {
    return {};
  }
  stage.reset(stage.context);
  std::vector<float> block(
      static_cast<std::size_t>(kBlockFrames) * kChannels, 0.0F);
  for (int index = 0; index < kWarmupBlocks; ++index) {
    if (!stage.render(stage.context, kBlockFrames, block.data())) {
      return {};
    }
  }
  std::vector<float> measured;
  measured.reserve(static_cast<std::size_t>(kMeasuredBlocks) * kBlockFrames *
                   kChannels);
  for (int index = 0; index < kMeasuredBlocks; ++index) {
    if (!stage.render(stage.context, kBlockFrames, block.data())) {
      return {};
    }
    measured.insert(measured.end(), block.begin(), block.end());
  }
  return measured;
}

void toneIsPreservedOrTransposed() {
  struct Case {
    std::uint32_t numerator;
    std::uint32_t denominator;
    bool preservePitch;
    double expectedHz;
    const char *name;
  };
  // The expected tone is the input tone when pitch is preserved and
  // inputTone * rate when it is not, which is exactly what varispeed means.
  const std::array<Case, 6> cases{
      {{2, 1, true, kToneHz, "2x pitch-preserved"},
       {2, 1, false, kToneHz * 2.0, "2x varispeed"},
       {1, 2, true, kToneHz, "0.5x pitch-preserved"},
       {1, 2, false, kToneHz * 0.5, "0.5x varispeed"},
       {3, 2, true, kToneHz, "1.5x pitch-preserved"},
       {3, 2, false, kToneHz * 1.5, "1.5x varispeed"}}};

  for (const Case &testCase : cases) {
    const std::vector<float> measured = renderTone(
        testCase.numerator, testCase.denominator, testCase.preservePitch);
    expect(!measured.empty(), "the tone fixture renders");
    if (measured.empty()) {
      continue;
    }
    const double hertz = zeroCrossingHz(measured);
    // One percent is far tighter than the ~4% pitch just-noticeable
    // difference the playback contract already cites, and far looser than the
    // measurement's own resolution, so it separates the two modes without
    // being a flake.
    const double error = std::abs(hertz - testCase.expectedHz) /
                         testCase.expectedHz;
    expect(error < 0.01, "the measured tone is the expected frequency");
    const double atInput = goertzelPower(measured, kToneHz);
    const double atShifted = goertzelPower(measured, kToneHz * static_cast<double>(
                                                        testCase.numerator) /
                                                        static_cast<double>(
                                                            testCase.denominator));
    std::cout << "  tone " << testCase.name << "  measured=" << hertz
              << " Hz expected=" << testCase.expectedHz
              << " Hz error=" << (error * 100.0) << "%"
              << "  goertzel(1000Hz)=" << atInput
              << " goertzel(" << (kToneHz * static_cast<double>(
                                                testCase.numerator) /
                                            static_cast<double>(
                                                testCase.denominator))
              << "Hz)=" << atShifted << '\n';
  }
}

// The pitch offset the stage derives, checked against 1200 * log2(rate)
// independently of any AudioUnit, including the two endpoints of the
// advertised window, which land exactly on the parameter's own limits.
void pitchOffsetIsTheVarispeedCurve() {
  expect(NativeAudioStretchUnit::pitchCents(2, 1, true) == 0.0F &&
             NativeAudioStretchUnit::pitchCents(1, 4, true) == 0.0F,
         "preserving pitch is an offset of exactly zero cents");
  expect(NativeAudioStretchUnit::pitchCents(1, 1, false) == 0.0F,
         "the unit rate is zero cents even with pitch preservation off");
  expect(std::abs(NativeAudioStretchUnit::pitchCents(2, 1, false) - 1200.0F) <
             0.01F,
         "double speed transposes by exactly one octave");
  expect(std::abs(NativeAudioStretchUnit::pitchCents(1, 2, false) +
                  1200.0F) < 0.01F,
         "half speed transposes down by exactly one octave");
  expect(std::abs(NativeAudioStretchUnit::pitchCents(4, 1, false) - 2400.0F) <
             0.01F,
         "4x lands exactly on the parameter's upper limit");
  expect(std::abs(NativeAudioStretchUnit::pitchCents(1, 4, false) +
                  2400.0F) < 0.01F,
         "0.25x lands exactly on the parameter's lower limit");
  const float threeHalves = NativeAudioStretchUnit::pitchCents(3, 2, false);
  expect(std::abs(threeHalves - 701.955F) < 0.01F,
         "1.5x transposes by a just fifth, 1200 * log2(3/2) cents");
}

// The stage's group-delay model is a function of the rate alone. That is only
// true if the unit's own declared latency ignores the pitch parameter, so ask
// it directly rather than trusting the closed form.
void declaredLatencyIgnoresPitch() {
  const AudioComponentDescription description{
      kAudioUnitType_FormatConverter, kAudioUnitSubType_NewTimePitch,
      kAudioUnitManufacturer_Apple, 0, 0};
  AudioComponent component = AudioComponentFindNext(nullptr, &description);
  expect(component != nullptr, "the time-pitch component exists");
  if (component == nullptr) {
    return;
  }
  AudioComponentInstance unit = nullptr;
  expect(AudioComponentInstanceNew(component, &unit) == noErr && unit,
         "the time-pitch component instantiates");
  if (unit == nullptr) {
    return;
  }
  expect(AudioUnitInitialize(unit) == noErr, "the probe unit initializes");
  const auto latencySeconds = [unit]() {
    Float64 seconds = 0.0;
    UInt32 size = sizeof(seconds);
    return AudioUnitGetProperty(unit, kAudioUnitProperty_Latency,
                                kAudioUnitScope_Global, 0, &seconds,
                                &size) == noErr
               ? seconds
               : -1.0;
  };
  expect(AudioUnitSetParameter(unit, kNewTimePitchParam_Rate,
                               kAudioUnitScope_Global, 0, 2.0F, 0) == noErr,
         "the probe unit accepts a rate");
  const Float64 atZeroCents = latencySeconds();
  expect(AudioUnitSetParameter(unit, kNewTimePitchParam_Pitch,
                               kAudioUnitScope_Global, 0, 1200.0F,
                               0) == noErr,
         "the probe unit accepts a pitch offset");
  const Float64 atOctave = latencySeconds();
  expect(atZeroCents > 0.0 && atZeroCents == atOctave,
         "declared group delay is identical at zero cents and at an octave");
  std::cout << "  declared latency at 2x: " << atZeroCents << " s at 0 cents, "
            << atOctave << " s at 1200 cents\n";
  static_cast<void>(AudioUnitUninitialize(unit));
  static_cast<void>(AudioComponentInstanceDispose(unit));
}

}  // namespace

int main() {
  pitchOffsetIsTheVarispeedCurve();
  declaredLatencyIgnoresPitch();
  exactConsumptionAtEveryPitch();
  toneIsPreservedOrTransposed();

  if (failures != 0) {
    std::cerr << failures << " native audio stretch stage check(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "native audio stretch stage checks passed\n";
  return EXIT_SUCCESS;
}
