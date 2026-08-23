#include "media/audio_downmix.hpp"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <span>
#include <vector>

namespace {

using namespace wam::media;

int failures = 0;

void expect(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

void expectNear(float actual, float expected, float tolerance,
                const char *message) {
  if (!(std::fabs(actual - expected) <= tolerance)) {
    std::cerr << "FAIL: " << message << " (expected " << expected << ", got "
              << actual << ")\n";
    ++failures;
  }
}

// The exact orders AudioToolbox was MEASURED to emit for the four codecs this
// player admits, one identical 5.1 tone fixture through each decoder. Index 1
// is the centre channel for AC-3 and the left channel for AAC, and index 3 is
// LFE for FLAC but left surround for the other three -- which is why every
// lookup in the shipping code goes through the label rather than the index.
constexpr std::array<AudioChannelRole, 6> kAacFiveOne{
    AudioChannelRole::Center,       AudioChannelRole::Left,
    AudioChannelRole::Right,        AudioChannelRole::SurroundLeft,
    AudioChannelRole::SurroundRight, AudioChannelRole::LowFrequency};

constexpr std::array<AudioChannelRole, 6> kAc3FiveOne{
    AudioChannelRole::Left,         AudioChannelRole::Center,
    AudioChannelRole::Right,        AudioChannelRole::SurroundLeft,
    AudioChannelRole::SurroundRight, AudioChannelRole::LowFrequency};

constexpr std::array<AudioChannelRole, 6> kFlacFiveOne{
    AudioChannelRole::Left,         AudioChannelRole::Right,
    AudioChannelRole::Center,       AudioChannelRole::LowFrequency,
    AudioChannelRole::SurroundLeft, AudioChannelRole::SurroundRight};

constexpr std::array<AudioChannelRole, 8> kFlacSevenOne{
    AudioChannelRole::Left,          AudioChannelRole::Right,
    AudioChannelRole::Center,        AudioChannelRole::LowFrequency,
    AudioChannelRole::SurroundLeft,  AudioChannelRole::SurroundRight,
    AudioChannelRole::SurroundLeft,  AudioChannelRole::SurroundRight};

constexpr float kTolerance = 1e-6F;
constexpr float kSqrtHalf = 0.70710678F;

// Drives ONE source channel with a unit impulse of amplitude 1 and reads the
// resulting stereo pair. This is the per-channel tone proof reduced to its
// exact arithmetic core: with a single nonzero input the two outputs ARE the
// two coefficients.
struct StereoPair {
  float left{0.0F};
  float right{0.0F};
};

[[nodiscard]] StereoPair driveOneChannel(const StereoDownmixMatrix &matrix,
                                         std::size_t channel) {
  const std::size_t channels = matrix.sourceChannels;
  std::vector<float> buffer(channels * 4U, 0.0F);
  // Frame 2 of 4, so an in-place fold that ran backwards or overwrote its own
  // input would corrupt the answer instead of silently agreeing.
  buffer[2U * channels + channel] = 1.0F;
  applyStereoDownmix(matrix, buffer, 4U);
  return {buffer[2U * kStereoDownmixOutputChannels],
          buffer[2U * kStereoDownmixOutputChannels + 1U]};
}

void expectRoleCoefficients(const StereoDownmixMatrix &matrix,
                            std::span<const AudioChannelRole> roles,
                            const char *what) {
  for (std::size_t index = 0; index < roles.size(); ++index) {
    const StereoPair measured = driveOneChannel(matrix, index);
    float wantedLeft = 0.0F;
    float wantedRight = 0.0F;
    switch (roles[index]) {
    case AudioChannelRole::Left:
      wantedLeft = 1.0F;
      break;
    case AudioChannelRole::Right:
      wantedRight = 1.0F;
      break;
    case AudioChannelRole::Center:
      wantedLeft = kSqrtHalf;
      wantedRight = kSqrtHalf;
      break;
    case AudioChannelRole::LowFrequency:
      break;
    case AudioChannelRole::SurroundLeft:
      wantedLeft = kSqrtHalf;
      break;
    case AudioChannelRole::SurroundRight:
      wantedRight = kSqrtHalf;
      break;
    case AudioChannelRole::SurroundCenter:
      wantedLeft = 0.5F;
      wantedRight = 0.5F;
      break;
    case AudioChannelRole::Unmapped:
      break;
    }
    expectNear(measured.left, wantedLeft, kTolerance, what);
    expectNear(measured.right, wantedRight, kTolerance, what);
  }
}

void testCoefficientsPerCodecLayout() {
  struct Case {
    const char *name;
    std::span<const AudioChannelRole> roles;
  };
  const std::array<Case, 4> cases{
      Case{"AAC-LC 5.1 (C L R Ls Rs LFE)", kAacFiveOne},
      Case{"AC-3/E-AC-3 5.1 (L C R Ls Rs LFE)", kAc3FiveOne},
      Case{"FLAC 5.1 (L R C LFE Ls Rs)", kFlacFiveOne},
      Case{"FLAC 7.1 (L R C LFE Rls Rrs Ls Rs)", kFlacSevenOne}};
  for (const Case &entry : cases) {
    const StereoDownmixMatrix matrix = buildStereoDownmixMatrix(entry.roles);
    expect(matrix.admitted(), entry.name);
    if (!matrix.admitted()) {
      continue;
    }
    expect(matrix.sourceChannels == entry.roles.size(),
           "matrix width equals the reported layout width");
    expectRoleCoefficients(matrix, entry.roles, entry.name);
  }
}

// The whole point of label mapping: the SAME dialogue channel must land in the
// same place for every codec even though it sits at a different index in each.
void testCentreLandsEquallyWhateverTheIndex() {
  const std::array<std::pair<std::span<const AudioChannelRole>, std::size_t>, 3>
      centres{std::pair<std::span<const AudioChannelRole>, std::size_t>{
                  kAacFiveOne, 0U},
              {kAc3FiveOne, 1U},
              {kFlacFiveOne, 2U}};
  for (const auto &entry : centres) {
    const StereoDownmixMatrix matrix = buildStereoDownmixMatrix(entry.first);
    expect(matrix.admitted(), "5.1 layout admitted");
    if (!matrix.admitted()) {
      continue;
    }
    const StereoPair pair = driveOneChannel(matrix, entry.second);
    expectNear(pair.left, kSqrtHalf, kTolerance,
               "centre reaches left at -3.01 dB");
    expectNear(pair.right, kSqrtHalf, kTolerance,
               "centre reaches right at -3.01 dB");
    expectNear(pair.left, pair.right, 0.0F,
               "centre is exactly equal in both outputs");
  }
}

void testLowFrequencyIsExcluded() {
  const std::array<std::pair<std::span<const AudioChannelRole>, std::size_t>, 3>
      lfes{std::pair<std::span<const AudioChannelRole>, std::size_t>{
               kAacFiveOne, 5U},
           {kAc3FiveOne, 5U},
           {kFlacFiveOne, 3U}};
  for (const auto &entry : lfes) {
    const StereoDownmixMatrix matrix = buildStereoDownmixMatrix(entry.first);
    if (!matrix.admitted()) {
      continue;
    }
    const StereoPair pair = driveOneChannel(matrix, entry.second);
    expectNear(pair.left, 0.0F, 0.0F, "LFE contributes exactly nothing to L");
    expectNear(pair.right, 0.0F, 0.0F, "LFE contributes exactly nothing to R");
  }
  expect(kDownmixLowFrequencyCoefficient == 0.0F,
         "the LFE policy constant is exactly zero");
}

void testSurroundsStayOnTheirOwnSide() {
  const StereoDownmixMatrix matrix = buildStereoDownmixMatrix(kAc3FiveOne);
  expect(matrix.admitted(), "AC-3 5.1 admitted");
  if (!matrix.admitted()) {
    return;
  }
  const StereoPair leftSurround = driveOneChannel(matrix, 3U);
  expectNear(leftSurround.left, kSqrtHalf, kTolerance, "Ls reaches left");
  expectNear(leftSurround.right, 0.0F, 0.0F, "Ls reaches right not at all");
  const StereoPair rightSurround = driveOneChannel(matrix, 4U);
  expectNear(rightSurround.left, 0.0F, 0.0F, "Rs reaches left not at all");
  expectNear(rightSurround.right, kSqrtHalf, kTolerance, "Rs reaches right");
}

// ffmpeg's own value for a lone rear-centre channel, measured on a 6.1
// fixture: slev * (1/sqrt2) = 0.5 into both outputs.
void testSurroundCentreSplitsEqually() {
  const std::array<AudioChannelRole, 4> threeOne{
      AudioChannelRole::Left, AudioChannelRole::Center, AudioChannelRole::Right,
      AudioChannelRole::SurroundCenter};
  const StereoDownmixMatrix matrix = buildStereoDownmixMatrix(threeOne);
  expect(matrix.admitted(), "AC-3 3/1 layout admitted");
  if (!matrix.admitted()) {
    return;
  }
  const StereoPair pair = driveOneChannel(matrix, 3U);
  expectNear(pair.left, 0.5F, kTolerance, "Cs reaches left at -6.02 dB");
  expectNear(pair.right, 0.5F, kTolerance, "Cs reaches right at -6.02 dB");
}

// The mpv/ffmpeg reference: all six channels driven together, unnormalised.
// A source frame of all ones yields 1 + 1/sqrt2 + 1/sqrt2 = 2.414214 per side,
// which is the row sum the NORMALISED variant would have divided by. Asserting
// the un-divided value is what pins WAM to mpv's level rather than to
// ffmpeg's 7.655 dB quieter integer path.
void testNoNormalisationIsApplied() {
  const StereoDownmixMatrix matrix = buildStereoDownmixMatrix(kAc3FiveOne);
  expect(matrix.admitted(), "AC-3 5.1 admitted");
  if (!matrix.admitted()) {
    return;
  }
  std::vector<float> buffer(6U, 1.0F);
  applyStereoDownmix(matrix, buffer, 1U);
  const float expected = 1.0F + kSqrtHalf + kSqrtHalf;
  expectNear(buffer[0], expected, 1e-5F, "unnormalised row sum on left");
  expectNear(buffer[1], expected, 1e-5F, "unnormalised row sum on right");
  expect(buffer[0] > 1.0F,
         "the reference matrix deliberately can exceed full scale");
}

// A downmix is a WIDTH reduction. It must consume exactly frameCount source
// frames and produce exactly frameCount stereo frames, touching nothing past
// them.
void testFrameCountInvariance() {
  const StereoDownmixMatrix matrix = buildStereoDownmixMatrix(kFlacFiveOne);
  expect(matrix.admitted(), "FLAC 5.1 admitted");
  if (!matrix.admitted()) {
    return;
  }
  constexpr std::size_t kFrames = 64;
  constexpr std::size_t kChannels = 6;
  std::vector<float> buffer(kFrames * kChannels, 0.0F);
  for (std::size_t frame = 0; frame < kFrames; ++frame) {
    // Distinct value in L (index 0) per frame, silence elsewhere: the fold
    // must reproduce the ramp in order and in place.
    buffer[frame * kChannels] = static_cast<float>(frame + 1U);
  }
  const float sentinel = -12345.0F;
  buffer.push_back(sentinel);
  applyStereoDownmix(matrix, buffer, kFrames);
  for (std::size_t frame = 0; frame < kFrames; ++frame) {
    expectNear(buffer[frame * kStereoDownmixOutputChannels],
               static_cast<float>(frame + 1U), kTolerance,
               "in-place fold preserves frame order");
    expectNear(buffer[frame * kStereoDownmixOutputChannels + 1U], 0.0F, 0.0F,
               "left-only content stays left");
  }
  expect(buffer.back() == sentinel,
         "the fold writes nothing past the frames it was given");
}

void testStereoAndMonoAreNeverFolded() {
  // Stereo is a legal role list, but the converter never builds a matrix for
  // it: this asserts the arithmetic would be an identity even if it did, so a
  // stereo regression cannot hide behind a nontrivial matrix.
  const std::array<AudioChannelRole, 2> stereo{AudioChannelRole::Left,
                                               AudioChannelRole::Right};
  const StereoDownmixMatrix matrix = buildStereoDownmixMatrix(stereo);
  expect(matrix.admitted(), "a plain stereo role list is admissible");
  if (matrix.admitted()) {
    std::vector<float> buffer{0.25F, -0.5F, 0.75F, -1.0F};
    const std::vector<float> before = buffer;
    applyStereoDownmix(matrix, buffer, 2U);
    expect(buffer == before, "the stereo matrix is a bit-exact identity");
  }
  // Mono has no admissible fold at all: the converter widens it instead.
  const std::array<AudioChannelRole, 1> mono{AudioChannelRole::Left};
  expect(!buildStereoDownmixMatrix(mono).admitted(),
         "a one-channel layout is not a downmix");
}

void testInadmissibleLayoutsAreRefusedNotGuessed() {
  const std::array<AudioChannelRole, 6> unmapped{
      AudioChannelRole::Left,         AudioChannelRole::Right,
      AudioChannelRole::Center,       AudioChannelRole::Unmapped,
      AudioChannelRole::SurroundLeft, AudioChannelRole::SurroundRight};
  expect(!buildStereoDownmixMatrix(unmapped).admitted(),
         "an unrecognised channel label refuses the whole layout");

  const std::array<AudioChannelRole, 3> noRight{
      AudioChannelRole::Left, AudioChannelRole::Center,
      AudioChannelRole::Left};
  expect(!buildStereoDownmixMatrix(noRight).admitted(),
         "a layout without exactly one right channel is refused");

  const std::array<AudioChannelRole, 5> lopsided{
      AudioChannelRole::Left,         AudioChannelRole::Right,
      AudioChannelRole::Center,       AudioChannelRole::SurroundLeft,
      AudioChannelRole::SurroundLeft};
  expect(!buildStereoDownmixMatrix(lopsided).admitted(),
         "unbalanced surrounds are refused rather than tilted");

  const std::array<AudioChannelRole, 6> twoCentres{
      AudioChannelRole::Left,         AudioChannelRole::Right,
      AudioChannelRole::Center,       AudioChannelRole::Center,
      AudioChannelRole::SurroundLeft, AudioChannelRole::SurroundRight};
  expect(!buildStereoDownmixMatrix(twoCentres).admitted(),
         "a duplicated centre is refused");

  const std::array<AudioChannelRole, 9> tooWide{
      AudioChannelRole::Left,          AudioChannelRole::Right,
      AudioChannelRole::Center,        AudioChannelRole::LowFrequency,
      AudioChannelRole::SurroundLeft,  AudioChannelRole::SurroundRight,
      AudioChannelRole::SurroundLeft,  AudioChannelRole::SurroundRight,
      AudioChannelRole::SurroundCenter};
  expect(!buildStereoDownmixMatrix(tooWide).admitted(),
         "a layout wider than the hard channel limit is refused");

  expect(!buildStereoDownmixMatrix({}).admitted(),
         "an empty role list is refused");
}

void testApplyIsInertOnAnInvalidMatrix() {
  const StereoDownmixMatrix invalid;
  std::vector<float> buffer{1.0F, 2.0F, 3.0F, 4.0F, 5.0F, 6.0F};
  const std::vector<float> before = buffer;
  applyStereoDownmix(invalid, buffer, 1U);
  expect(buffer == before, "an invalid matrix folds nothing");

  const StereoDownmixMatrix matrix = buildStereoDownmixMatrix(kAacFiveOne);
  std::vector<float> tooSmall(6U, 1.0F);
  const std::vector<float> smallBefore = tooSmall;
  // Two frames of six channels need twelve samples; the buffer holds six.
  applyStereoDownmix(matrix, tooSmall, 2U);
  expect(tooSmall == smallBefore,
         "a frame count the buffer cannot hold folds nothing");
}

} // namespace

int main() {
  testCoefficientsPerCodecLayout();
  testCentreLandsEquallyWhateverTheIndex();
  testLowFrequencyIsExcluded();
  testSurroundsStayOnTheirOwnSide();
  testSurroundCentreSplitsEqually();
  testNoNormalisationIsApplied();
  testFrameCountInvariance();
  testStereoAndMonoAreNeverFolded();
  testInadmissibleLayoutsAreRefusedNotGuessed();
  testApplyIsInertOnAnInvalidMatrix();
  if (failures != 0) {
    std::cerr << failures << " audio downmix expectation(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "audio downmix: all expectations passed\n";
  return EXIT_SUCCESS;
}
