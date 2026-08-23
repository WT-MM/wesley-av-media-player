#include "media/audio_downmix.hpp"

#include "media/native_media_source.hpp"

namespace wam::media {

static_assert(kMaximumDownmixSourceChannels ==
                  MediaSourceLimits::kHardMaximumAudioChannels,
              "the downmix workspace bound must track the neutral source "
              "channel limit exactly");

namespace {

struct RoleCoefficients {
  float left{0.0F};
  float right{0.0F};
};

[[nodiscard]] constexpr RoleCoefficients
coefficientsFor(AudioChannelRole role) noexcept {
  switch (role) {
  case AudioChannelRole::Left:
    return {1.0F, 0.0F};
  case AudioChannelRole::Right:
    return {0.0F, 1.0F};
  case AudioChannelRole::Center:
    return {kDownmixCenterCoefficient, kDownmixCenterCoefficient};
  case AudioChannelRole::LowFrequency:
    return {kDownmixLowFrequencyCoefficient, kDownmixLowFrequencyCoefficient};
  case AudioChannelRole::SurroundLeft:
    return {kDownmixSurroundCoefficient, 0.0F};
  case AudioChannelRole::SurroundRight:
    return {0.0F, kDownmixSurroundCoefficient};
  case AudioChannelRole::SurroundCenter:
    return {kDownmixSurroundCenterCoefficient,
            kDownmixSurroundCenterCoefficient};
  case AudioChannelRole::Unmapped:
    break;
  }
  return {0.0F, 0.0F};
}

} // namespace

StereoDownmixMatrix
buildStereoDownmixMatrix(std::span<const AudioChannelRole> roles) noexcept {
  StereoDownmixMatrix matrix;
  if (roles.size() < kStereoDownmixOutputChannels ||
      roles.size() > kMaximumDownmixSourceChannels) {
    return matrix;
  }

  std::uint32_t leftCount = 0;
  std::uint32_t rightCount = 0;
  std::uint32_t centerCount = 0;
  std::uint32_t lfeCount = 0;
  std::uint32_t surroundLeftCount = 0;
  std::uint32_t surroundRightCount = 0;
  std::uint32_t surroundCenterCount = 0;
  for (const AudioChannelRole role : roles) {
    switch (role) {
    case AudioChannelRole::Left:
      ++leftCount;
      break;
    case AudioChannelRole::Right:
      ++rightCount;
      break;
    case AudioChannelRole::Center:
      ++centerCount;
      break;
    case AudioChannelRole::LowFrequency:
      ++lfeCount;
      break;
    case AudioChannelRole::SurroundLeft:
      ++surroundLeftCount;
      break;
    case AudioChannelRole::SurroundRight:
      ++surroundRightCount;
      break;
    case AudioChannelRole::SurroundCenter:
      ++surroundCenterCount;
      break;
    case AudioChannelRole::Unmapped:
      // An unrecognised label. Refuse the whole layout: the alternative is to
      // drop a channel, which is exactly the AudioConverter FLAC behaviour
      // this module exists to avoid.
      return matrix;
    }
  }
  // A layout without one unambiguous front pair is not something this policy
  // can state. Two Ls channels (a 7.1 side/rear pair) are fine and both carry
  // the same coefficient, but they must be balanced or the image would tilt.
  if (leftCount != 1U || rightCount != 1U || centerCount > 1U ||
      lfeCount > 1U || surroundCenterCount > 1U || surroundLeftCount > 2U ||
      surroundRightCount > 2U || surroundLeftCount != surroundRightCount) {
    return matrix;
  }

  for (std::size_t index = 0; index < roles.size(); ++index) {
    const RoleCoefficients coefficients = coefficientsFor(roles[index]);
    matrix.left[index] = coefficients.left;
    matrix.right[index] = coefficients.right;
  }
  matrix.sourceChannels = static_cast<std::uint32_t>(roles.size());
  matrix.valid = true;
  return matrix;
}

void applyStereoDownmix(const StereoDownmixMatrix &matrix,
                        std::span<float> interleaved,
                        std::size_t frameCount) noexcept {
  if (!matrix.valid || frameCount == 0) {
    return;
  }
  const std::size_t sourceChannels = matrix.sourceChannels;
  if (sourceChannels < kStereoDownmixOutputChannels ||
      sourceChannels > kMaximumDownmixSourceChannels) {
    return;
  }
  if (frameCount > interleaved.size() / sourceChannels) {
    return;
  }
  // Copy the coefficient rows into locals so the inner loop reads from two
  // fixed-size arrays the compiler can keep in registers rather than chasing
  // the matrix reference on every sample.
  const std::array<float, kMaximumDownmixSourceChannels> left = matrix.left;
  const std::array<float, kMaximumDownmixSourceChannels> right = matrix.right;

  float *const samples = interleaved.data();
  for (std::size_t frame = 0; frame < frameCount; ++frame) {
    const std::size_t sourceBase = frame * sourceChannels;
    float accumulatedLeft = 0.0F;
    float accumulatedRight = 0.0F;
    for (std::size_t channel = 0; channel < sourceChannels; ++channel) {
      const float value = samples[sourceBase + channel];
      accumulatedLeft += value * left[channel];
      accumulatedRight += value * right[channel];
    }
    // Written only after the whole source frame has been read, and 2*frame
    // <= sourceChannels*frame for every frame while sourceChannels >= 2, so
    // this never clobbers a sample a later frame still needs.
    const std::size_t destinationBase = frame * kStereoDownmixOutputChannels;
    samples[destinationBase] = accumulatedLeft;
    samples[destinationBase + 1U] = accumulatedRight;
  }
}

} // namespace wam::media
