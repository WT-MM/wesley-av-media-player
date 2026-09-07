#pragma once
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace wam::media {
struct Mp3LameGapless {
  std::uint32_t sampleRate{0};
  std::uint32_t encoderDelay{0};
  std::uint64_t retainedFrames{0};
};

// MPEG-2/2.5 Layer III Xing/Info frames carry a LAME-layout delay/padding
// pair. MPEG-1 timing remains owned by the container adapter.
[[nodiscard]] inline std::optional<Mp3LameGapless>
inspectMp3LsfGapless(std::span<const std::byte> bytes) noexcept {
  auto u = [&](std::size_t i) {
    return std::to_integer<std::uint32_t>(bytes[i]);
  };
  auto be32 = [&](std::size_t i) {
    return u(i) << 24U | u(i + 1) << 16U | u(i + 2) << 8U | u(i + 3);
  };
  if (bytes.size() < 4 || u(0) != 255 || (u(1) & 0xe0U) != 0xe0U ||
      (u(1) & 6U) != 2U)
    return {};
  const auto version = (u(1) >> 3U) & 3U;
  const auto rateIndex = (u(2) >> 2U) & 3U;
  const auto bitRateIndex = u(2) >> 4U;
  if ((version != 0 && version != 2) || rateIndex == 3 || bitRateIndex == 0 ||
      bitRateIndex == 15)
    return {};
  constexpr std::uint32_t rates[]{44100, 48000, 32000};
  constexpr std::uint32_t bitrates[]{0,  8,  16, 24,  32,  40,  48, 56,
                                     64, 80, 96, 112, 128, 144, 160};
  const auto rate = rates[rateIndex] / (version == 2 ? 2U : 4U);
  const auto frameBytes =
      72000U * bitrates[bitRateIndex] / rate + ((u(2) >> 1U) & 1U);
  if (bytes.size() < frameBytes)
    return {};
  std::size_t offset =
      4U + ((u(3) >> 6U) == 3 ? 9U : 17U) + ((u(1) & 1U) ? 0U : 2U);
  if (offset + 8 > frameBytes ||
      (be32(offset) != 0x58696e67U && be32(offset) != 0x496e666fU))
    return {};
  const auto flags = be32(offset + 4);
  offset += 8;
  if ((flags & 1U) == 0 || (flags & ~15U) != 0 || offset + 4 > frameBytes)
    return {};
  const auto frames = be32(offset);
  offset += 4;
  if (flags & 2U)
    offset += 4;
  if (flags & 4U)
    offset += 100;
  if (flags & 8U)
    offset += 4;
  if (offset + 24 > frameBytes ||
      (be32(offset) != 0x4c414d45U && be32(offset) != 0x4c617663U))
    return {};
  const auto delay = (u(offset + 21) << 4U) | (u(offset + 22) >> 4U);
  const auto padding = ((u(offset + 22) & 15U) << 8U) | u(offset + 23);
  const auto total = static_cast<std::uint64_t>(frames) * 576U;
  if (frames == 0 || delay == 0 || total <= delay + padding)
    return {};
  return Mp3LameGapless{rate, delay, total - delay - padding};
}
} // namespace wam::media
