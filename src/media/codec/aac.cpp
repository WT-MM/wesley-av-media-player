#include "media/codec/aac.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <limits>

namespace wam::media::codec {
namespace {

constexpr std::uint32_t kAacLcAudioObjectType{2};
constexpr std::uint32_t kSbrAudioObjectType{5};
constexpr std::uint32_t kSyncExtensionType{0x2B7};
constexpr std::uint32_t kSamplingFrequencyIndex48000{3};
constexpr std::uint32_t kSamplingFrequencyIndex44100{4};

class BitReader final {
public:
  explicit BitReader(std::span<const std::byte> bytes) noexcept
      : bytes_(bytes) {}

  [[nodiscard]] bool read(std::size_t count, std::uint32_t *value) noexcept {
    if (value == nullptr || count > 32 || count > remaining()) {
      return false;
    }
    std::uint32_t result = 0;
    for (std::size_t index = 0; index < count; ++index) {
      const std::size_t byteIndex = bitOffset_ / 8U;
      const std::size_t bitInByte = 7U - (bitOffset_ % 8U);
      const auto byte = std::to_integer<std::uint8_t>(bytes_[byteIndex]);
      result = static_cast<std::uint32_t>((result << 1U) |
                                          ((byte >> bitInByte) & 1U));
      ++bitOffset_;
    }
    *value = result;
    return true;
  }

  [[nodiscard]] std::size_t remaining() const noexcept {
    return bytes_.size() * 8U - bitOffset_;
  }


private:
  std::span<const std::byte> bytes_;
  std::size_t bitOffset_{0};
};

[[nodiscard]] AacLcAdmission rejected(AacLcAdmissionError error) noexcept {
  return {error, std::nullopt};
}


} // namespace

namespace {
std::atomic<AacSbrDetector> installedDetector{nullptr};
} // namespace

void installAacSbrDetector(AacSbrDetector detector) noexcept {
  installedDetector.store(detector, std::memory_order_release);
}

std::optional<std::array<std::byte, 2>>
aacLcAudioSpecificConfig(std::uint32_t sampleRate, std::uint32_t channels) noexcept {
  std::uint32_t index = 0;
  while (index < 13 && aacSampleRateForIndex(static_cast<std::uint8_t>(index)) != sampleRate) {
    ++index;
  }
  const std::uint32_t configuration =
      channels >= 1 && channels <= 6 ? channels : channels == 8 ? 7U : 0U;
  if (index == 13 || configuration == 0) {
    return std::nullopt;
  }
  return std::array<std::byte, 2>{
      static_cast<std::byte>((kAacLcAudioObjectType << 3U) | (index >> 1U)),
      static_cast<std::byte>(((index & 1U) << 7U) | (configuration << 3U))};
}

void AacImplicitSbrCheck::reset(std::span<const std::byte> audioSpecificConfig,
                                std::uint32_t coreSampleRate) {
  config_.assign(audioSpecificConfig.begin(), audioSpecificConfig.end());
  coreSampleRate_ = coreSampleRate;
  units_.clear();
  unitEnds_.clear();
  decided_ = false;
}

const char* AacImplicitSbrCheck::add(std::span<const std::byte> accessUnit) {
  if (decided_) {
    return nullptr;
  }
  units_.insert(units_.end(), accessUnit.begin(), accessUnit.end());
  unitEnds_.push_back(units_.size());
  decided_ = unitEnds_.size() >= kAacSbrScanAccessUnits;
  std::vector<std::span<const std::byte>> units;
  std::size_t begin = 0;
  for (const std::size_t end : unitEnds_) {
    units.emplace_back(units_.data() + begin, end - begin);
    begin = end;
  }
  const AacSbrDetector detector =
      installedDetector.load(std::memory_order_acquire);
  const AacSbrDetection verdict =
      detector ? detector(config_, units) : AacSbrDetection::Unavailable;
  if (verdict == AacSbrDetection::Absent) {
    return nullptr;
  }
  decided_ = true;
  return verdict == AacSbrDetection::Present ||
                 coreSampleRate_ <= kAacImplicitSbrMaximumCoreRate
             ? kHeAacDecoderDelayRefusal
             : nullptr;
}

AacLcAdmission
parseAacLcAudioSpecificConfig(std::span<const std::byte> bytes) noexcept {
  if (bytes.size() != 2U && bytes.size() != 5U) {
    return rejected(AacLcAdmissionError::InvalidAudioSpecificConfigSize);
  }

  BitReader reader(bytes);
  std::uint32_t value = 0;
  if (!reader.read(5, &value) || value != kAacLcAudioObjectType) {
    return rejected(AacLcAdmissionError::UnsupportedAudioObjectType);
  }

  if (!reader.read(4, &value)) {
    return rejected(AacLcAdmissionError::InvalidAudioSpecificConfigSize);
  }
  if (value == 15U) {
    return rejected(AacLcAdmissionError::ExplicitSamplingFrequency);
  }
  std::uint32_t sampleRate = 0;
  if (value == kSamplingFrequencyIndex48000) {
    sampleRate = 48'000U;
  } else if (value == kSamplingFrequencyIndex44100) {
    sampleRate = 44'100U;
  } else {
    return rejected(AacLcAdmissionError::UnsupportedSamplingFrequency);
  }

  if (!reader.read(4, &value)) {
    return rejected(AacLcAdmissionError::InvalidAudioSpecificConfigSize);
  }
  if (value == 0U) {
    return rejected(AacLcAdmissionError::ProgramConfigElement);
  }
  // ISO/IEC 14496-3 Table 1.19: channelConfiguration 1..6 name 1, 2, 3, 4, 5
  // and 6 channels respectively, so the index IS the count over that range.
  // Configuration 7 is the only other defined value and it means EIGHT
  // channels in the front-wide 3/4.1 arrangement whose two extra channels are
  // front-left-of-centre and front-right-of-centre. Those two labels have no
  // measured downmix coefficient in this player, so 7 is a named deferral
  // rather than an admission with a guessed matrix -- and it is not the
  // arrangement movie 7.1 uses in any case (that needs a program config
  // element, which is refused above).
  if (value > 6U) {
    return rejected(AacLcAdmissionError::UnsupportedChannelConfiguration);
  }
  const auto channelCount = static_cast<std::uint8_t>(value);

  if (!reader.read(1, &value)) {
    return rejected(AacLcAdmissionError::InvalidAudioSpecificConfigSize);
  }
  if (value != 0U) {
    return rejected(AacLcAdmissionError::UnsupportedFrameLength);
  }
  if (!reader.read(1, &value)) {
    return rejected(AacLcAdmissionError::InvalidAudioSpecificConfigSize);
  }
  if (value != 0U) {
    return rejected(AacLcAdmissionError::CoreCoderDependency);
  }
  if (!reader.read(1, &value)) {
    return rejected(AacLcAdmissionError::InvalidAudioSpecificConfigSize);
  }
  if (value != 0U) {
    return rejected(AacLcAdmissionError::UnsupportedExtensionFlag);
  }

  const bool hasSyncExtension = bytes.size() == 5U;
  if (hasSyncExtension) {
    if (!reader.read(11, &value) || value != kSyncExtensionType) {
      return rejected(AacLcAdmissionError::InvalidSyncExtension);
    }
    if (!reader.read(5, &value) || value != kSbrAudioObjectType) {
      return rejected(AacLcAdmissionError::UnsupportedExtensionAudioObjectType);
    }
    if (!reader.read(1, &value)) {
      return rejected(AacLcAdmissionError::InvalidAudioSpecificConfigSize);
    }
    if (value != 0U) {
      return rejected(AacLcAdmissionError::SbrPresent);
    }
    if (!reader.read(reader.remaining(), &value) || value != 0U) {
      return rejected(AacLcAdmissionError::NonzeroTrailingBits);
    }
  }

  if (reader.remaining() != 0U) {
    return rejected(AacLcAdmissionError::NonzeroTrailingBits);
  }

  AacLcConfiguration configuration;
  std::copy(bytes.begin(), bytes.end(),
            configuration.audioSpecificConfig.begin());
  configuration.audioSpecificConfigSize =
      static_cast<std::uint8_t>(bytes.size());
  configuration.sampleRate = sampleRate;
  configuration.channelCount = channelCount;
  configuration.ffmpegSyncExtensionPresent = hasSyncExtension;
  return {AacLcAdmissionError::None, configuration};
}

std::optional<AacLcEsDescriptorCookie>
buildAacLcEsDescriptorCookie(const AacLcConfiguration &configuration) noexcept {
  const std::size_t configSize = configuration.audioSpecificConfigSize;
  if (configSize > configuration.audioSpecificConfig.size()) {
    return std::nullopt;
  }
  const auto reparsed = parseAacLcAudioSpecificConfig(
      {configuration.audioSpecificConfig.data(), configSize});
  if (!reparsed.admitted() || *reparsed.configuration != configuration) {
    return std::nullopt;
  }

  AacLcEsDescriptorCookie cookie;
  std::size_t offset = 0;
  const auto append = [&cookie, &offset](std::uint8_t value) noexcept {
    if (offset >= cookie.bytes.size()) {
      return false;
    }
    cookie.bytes[offset++] = static_cast<std::byte>(value);
    return true;
  };
  const auto appendExpandableLength = [&append](std::uint32_t value) noexcept {
    if (value > 0x0FFF'FFFFU) {
      return false;
    }
    return append(
               static_cast<std::uint8_t>(0x80U | ((value >> 21U) & 0x7FU))) &&
           append(
               static_cast<std::uint8_t>(0x80U | ((value >> 14U) & 0x7FU))) &&
           append(static_cast<std::uint8_t>(0x80U | ((value >> 7U) & 0x7FU))) &&
           append(static_cast<std::uint8_t>(value & 0x7FU));
  };

  const auto descriptorBytes = static_cast<std::uint32_t>(configSize);
  if (!append(0x03U) || !appendExpandableLength(32U + descriptorBytes) ||
      !append(0x00U) || !append(0x01U) || !append(0x00U) || !append(0x04U) ||
      !appendExpandableLength(18U + descriptorBytes) || !append(0x40U) ||
      !append(0x15U) || !append(0x00U) || !append(0x00U) || !append(0x00U) ||
      !append(0x00U) || !append(0x00U) || !append(0x00U) || !append(0x00U) ||
      !append(0x00U) || !append(0x00U) || !append(0x00U) || !append(0x00U) ||
      !append(0x05U) || !appendExpandableLength(descriptorBytes)) {
    return std::nullopt;
  }
  for (std::size_t index = 0; index < configSize; ++index) {
    if (!append(std::to_integer<std::uint8_t>(
            configuration.audioSpecificConfig[index]))) {
      return std::nullopt;
    }
  }
  if (!append(0x06U) || !appendExpandableLength(1U) || !append(0x02U)) {
    return std::nullopt;
  }

  const std::size_t expectedSize = 37U + configSize;
  if (offset != expectedSize || offset > cookie.bytes.size() ||
      offset > std::numeric_limits<std::uint8_t>::max()) {
    return std::nullopt;
  }
  cookie.size = static_cast<std::uint8_t>(offset);
  return cookie;
}

} // namespace wam::media::codec
