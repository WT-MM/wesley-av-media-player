#pragma once

#include "media/codec/aac.hpp"
#include "media/native_media_source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace wam::media::matroska {

using codec::kAacLcSamplesPerAccessUnit;

// Every access-unit timestamp is reconstructed from this immutable origin and
// ordinal. No helper advances a previously rounded timestamp, so long streams
// cannot accumulate quantization drift.
struct AacFrameGridPosition {
  MediaTime origin{};
  std::uint64_t accessUnitOrdinal{0};
  std::uint32_t sampleRate{0};
  // Defaults to AAC-LC. Opus reuses this grid with its own packet duration
  // (and a nonzero origin of -CodecDelay).
  std::uint32_t samplesPerAccessUnit{kAacLcSamplesPerAccessUnit};
};

// Packet timing accepts positive rates within the source ceiling; codec and
// native output admission remain separate from exact-rational projection.
[[nodiscard]] std::optional<MediaTime>
audioPacketGridTime(AacFrameGridPosition position) noexcept;

// Matroska ticks are timestampScaleNanoseconds / 1e9 seconds. Quantization is
// exact round-to-nearest, ties-to-even for both positive and negative times.
[[nodiscard]] std::optional<std::int64_t>
nearestMatroskaTick(AacFrameGridPosition position,
                    std::uint64_t timestampScaleNanoseconds) noexcept;

struct AacTickGridProjection {
  std::uint64_t accessUnitOrdinal{0};
  MediaTime exactPresentationTime{};
  std::int64_t quantizedGridTick{0};
  std::int64_t signedTickResidual{0};
  bool exactTickMatch{false};

  friend constexpr bool operator==(const AacTickGridProjection &,
                                   const AacTickGridProjection &) = default;
};

// Projects an observed Matroska tick onto the nearest nonnegative access-unit
// ordinal. The inverse calculation operates on the exact tick and origin
// rationals and rounds the ordinal once, ties-to-even. A result is returned
// only when every 128-bit intermediate, the ordinal, its exact grid time, the
// re-quantized tick, and the signed residual are representable.
[[nodiscard]] std::optional<AacTickGridProjection>
nearestAudioPacketForMatroskaTick(
    std::int64_t observedTick, MediaTime origin, std::uint32_t sampleRate,
    std::uint64_t timestampScaleNanoseconds,
    std::uint32_t samplesPerPacket) noexcept;

} // namespace wam::media::matroska
