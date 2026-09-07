#pragma once
#include "media/media_codec_facts.hpp"
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace wam::media {
// A coarse container tick may use either adjacent integer; codec ordinals retain exact sample time.
[[nodiscard]] inline bool softwareAudioTickAdmitted(std::int64_t tick, std::uint64_t ordinal,
    std::uint32_t frames, std::uint64_t scale) noexcept {
  if(tick<0 || !scale || !frames)return false;
  const unsigned __int128 numerator=static_cast<unsigned __int128>(ordinal)*frames*1'000'000'000;
  const unsigned __int128 denominator=static_cast<unsigned __int128>(48000)*scale;
  return static_cast<unsigned __int128>(tick)>=numerator/denominator &&
         static_cast<unsigned __int128>(tick)<=(numerator+denominator-1)/denominator;
}
struct SoftwareAudioPacketFacts {
  std::uint32_t frames{};
  bool majorSync{};
  std::uint16_t inputTiming{};
};
// DTS core is 16-bit big endian; extension payloads require separate profile qualification.
// TrueHD/MLP at 48 kHz carry 40 samples and a wrapping 16-bit input ordinal.
[[nodiscard]] inline std::optional<SoftwareAudioPacketFacts>
inspectSoftwareAudioPacket(MediaCodec codec, std::span<const std::byte> header,
                           std::uint64_t packetBytes) noexcept {
  if (header.size() < 10 || packetBytes < header.size()) return {};
  const auto byte = [&](unsigned i) { return std::to_integer<unsigned>(header[i]); };
  if (codec == MediaCodec::Dts) {
    if (byte(0) != 0x7f || byte(1) != 0xfe || byte(2) != 0x80 || byte(3) != 1) return {};
    const unsigned frames = ((((byte(4) & 1U) << 6U) | (byte(5) >> 2U)) + 1U) * 32U;
    const unsigned bytes = (((byte(5) & 3U) << 12U) | (byte(6) << 4U) | (byte(7) >> 4U)) + 1U;
    const unsigned rateCode = (byte(8) >> 2U) & 15U;
    if ((byte(4) & 0x7cU) != 0x7cU || bytes != packetBytes || rateCode != 13U || frames != 512U) return {};
    return SoftwareAudioPacketFacts{frames, true, 0};
  }
  if (codec != MediaCodec::TrueHd && codec != MediaCodec::Mlp) return {};
  if ((((byte(0) & 15U) << 8U) | byte(1)) * 2U != packetBytes) return {};
  const bool major = byte(4) == 0xf8 && byte(5) == 0x72 && byte(6) == 0x6f;
  if (major && (header.size() < 32 || byte(7) != (codec == MediaCodec::TrueHd ? 0xbaU : 0xbbU) ||
                (byte(codec == MediaCodec::TrueHd ? 8 : 9) >> 4U) != 0)) return {};
  return SoftwareAudioPacketFacts{40, major, static_cast<std::uint16_t>((byte(2) << 8U) | byte(3))};
}
}
