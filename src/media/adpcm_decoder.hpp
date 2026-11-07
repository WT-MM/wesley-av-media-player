#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace wam::media {
inline constexpr std::array<std::int16_t, 14> kAdpcmMsCoefficients{
    256, 0, 512, -256, 0, 0, 192, 64, 240, 0, 460, -208, 392, -232};
struct AdpcmFormat {
  std::uint16_t tag{};
  std::uint32_t channels{}, blockBytes{}, blockFrames{};
  std::array<std::int16_t, 14> coefficients{kAdpcmMsCoefficients};
};
// WAV tags 0x11/0x02, one or two channels, complete declared blocks <=65535
// bytes, with frame counts matching their header and payload sizes. Stereo IMA
// payload groups contain four bytes per channel; mono nibbles are sequential.
// IMA indices are 0..88 and reserved header bytes zero; MS predictors are 0..6,
// initial deltas >=16 and coefficients exactly the seven standard pairs.
// Output capacity covers a block of interleaved signed-16 PCM scaled by 2^-15.
// Each block restarts history, has no lead-in or tail, and writes only after
// format, capacity and all channel headers validate. Storage belongs to caller.
[[nodiscard]] const char *validateAdpcmFormat(const AdpcmFormat &) noexcept;
// Parses a WAVEFORMATEX ADPCM record (IMA with cbSize 2, MS with cbSize 32
// and its coefficient table) that must state `rate`, `channels` and 4-bit
// samples. Empty unless validateAdpcmFormat accepts the result. Matroska
// A_MS/ACM CodecPrivate and a WAV `fmt ` chunk carry the same record.
[[nodiscard]] std::optional<AdpcmFormat>
parseAdpcmWaveFormat(std::span<const std::byte> waveFormat, std::uint32_t rate,
                     std::uint32_t channels) noexcept;
[[nodiscard]] const char *decodeAdpcmBlock(const AdpcmFormat &,
                                           std::span<const std::byte>,
                                           std::span<float>) noexcept;
} // namespace wam::media
