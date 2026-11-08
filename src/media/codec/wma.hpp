#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <vector>

namespace wam::media::codec {

// WMA v2's WAVEFORMATEX tag (Microsoft's WAVE_FORMAT_WMAUDIO2).
inline constexpr std::uint16_t kWmaV2FormatTag{0x0161};
inline constexpr std::size_t kWaveFormatExBytes{18};

// A WMA v2 track's codec configuration is its WAVEFORMATEX followed by the
// cbSize bytes of codec data, exactly as ASF's stream properties and
// Matroska's A_MS/ACM CodecPrivate carry it: the decoder needs the byte rate
// and block alignment as well as the codec data.
struct WmaWaveFormat {
  std::uint16_t channels{0};
  std::uint32_t sampleRate{0};
  std::uint32_t averageBytesPerSecond{0};
  std::uint16_t blockAlign{0};
  std::span<const std::byte> codecData{};
};

[[nodiscard]] inline std::vector<std::byte>
buildWmaWaveFormat(const WmaWaveFormat &format) {
  std::vector<std::byte> out(kWaveFormatExBytes + format.codecData.size());
  std::size_t at = 0;
  const auto put = [&](std::uint32_t value, std::size_t bytes) {
    for (std::size_t i = 0; i < bytes; ++i)
      out[at++] = static_cast<std::byte>((value >> (8U * i)) & 0xffU);
  };
  put(kWmaV2FormatTag, 2);
  put(format.channels, 2);
  put(format.sampleRate, 4);
  put(format.averageBytesPerSecond, 4);
  put(format.blockAlign, 2);
  put(0, 2); // wBitsPerSample
  put(static_cast<std::uint32_t>(format.codecData.size()), 2);
  for (const std::byte value : format.codecData) out[at++] = value;
  return out;
}

[[nodiscard]] inline std::optional<WmaWaveFormat>
parseWmaWaveFormat(std::span<const std::byte> bytes) noexcept {
  if (bytes.size() < kWaveFormatExBytes) return std::nullopt;
  const auto get = [&](std::size_t at, std::size_t count) {
    std::uint32_t value = 0;
    for (std::size_t i = 0; i < count; ++i)
      value |= std::to_integer<std::uint32_t>(bytes[at + i]) << (8U * i);
    return value;
  };
  if (get(0, 2) != kWmaV2FormatTag ||
      get(16, 2) != bytes.size() - kWaveFormatExBytes)
    return std::nullopt;
  return WmaWaveFormat{static_cast<std::uint16_t>(get(2, 2)), get(4, 4),
                       get(8, 4), static_cast<std::uint16_t>(get(12, 2)),
                       bytes.subspan(kWaveFormatExBytes)};
}

// Flag 2 of the codec data's flags word: superframes spanning payloads.
[[nodiscard]] inline bool
wmaUsesBitReservoir(std::span<const std::byte> codecData) noexcept {
  return codecData.size() >= 6 &&
         (std::to_integer<unsigned>(codecData[4]) & 2U) != 0;
}

// Frames of a payload's decode that a decoder begun at that payload cannot
// reproduce, in units of the codec frame (2048 samples at 44.1/48 kHz): the
// two frames whose overlap-add has no predecessor, which the decoder drops,
// and on a bit-reservoir stream the frame begun in the previous payload,
// whose head the reset discarded. Measured against the continuous decode at
// random payloads of ffmpeg-made and bit-reservoir streams: every sample
// after these frames is bit-identical.
[[nodiscard]] constexpr std::uint32_t
wmaResetLeadFrames(bool bitReservoir) noexcept {
  return bitReservoir ? 3U : 2U;
}

// One superframe's 4-bit count bounds a payload at 15 frames, and the final
// payload also carries the decoder's end-of-stream overlap frame.
inline constexpr std::uint32_t kWmaMaximumFramesPerPayload{16};

} // namespace wam::media::codec
