#include "media/adpcm_decoder.hpp"
#include <algorithm>

namespace wam::media {
namespace {
constexpr int steps[]{
    7,     8,     9,     10,    11,    12,    13,    14,    16,    17,
    19,    21,    23,    25,    28,    31,    34,    37,    41,    45,
    50,    55,    60,    66,    73,    80,    88,    97,    107,   118,
    130,   143,   157,   173,   190,   209,   230,   253,   279,   307,
    337,   371,   408,   449,   494,   544,   598,   658,   724,   796,
    876,   963,   1060,  1166,  1282,  1411,  1552,  1707,  1878,  2066,
    2272,  2499,  2749,  3024,  3327,  3660,  4026,  4428,  4871,  5358,
    5894,  6484,  7132,  7845,  8630,  9493,  10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767};
constexpr int indices[]{-1, -1, -1, -1, 2, 4, 6, 8};
constexpr int adaptation[]{230, 230, 230, 230, 307, 409, 512, 614,
                           768, 614, 512, 409, 307, 230, 230, 230};
int byte(std::span<const std::byte> b, std::size_t p) {
  return std::to_integer<int>(b[p]);
}
int word(std::span<const std::byte> b, std::size_t p) {
  return byte(b, p) | byte(b, p + 1) * 256;
}
int signedWord(std::span<const std::byte> b, std::size_t p) {
  const int n = word(b, p);
  return n < 32768 ? n : n - 65536;
}
int clip(std::int64_t n) {
  return static_cast<int>(std::clamp<std::int64_t>(n, -32768, 32767));
}
} // namespace
const char *validateAdpcmFormat(const AdpcmFormat &f) noexcept {
  if ((f.tag != 17 && f.tag != 2) || f.channels < 1 || f.channels > 2 ||
      f.blockBytes > 65535)
    return "AdpcmFormatUnsupported";
  const auto header = (f.tag == 17 ? 4U : 7U) * f.channels;
  if (f.blockBytes < header ||
      (f.tag == 17 && f.channels == 2 && (f.blockBytes - header) % 8) ||
      f.blockFrames !=
          (f.tag == 17 ? 1U : 2U) + (f.blockBytes - header) * 2 / f.channels)
    return "AdpcmBlockGeometryInvalid";
  if (f.tag == 2 && f.coefficients != kAdpcmMsCoefficients)
    return "AdpcmCoefficientsUnsupported";
  return nullptr;
}
const char *decodeAdpcmBlock(const AdpcmFormat &f, std::span<const std::byte> b,
                             std::span<float> out) noexcept {
  if (auto e = validateAdpcmFormat(f))
    return e;
  if (b.size() != f.blockBytes)
    return "AdpcmBlockSizeMismatch";
  if (out.size() < static_cast<std::size_t>(f.blockFrames) * f.channels)
    return "AdpcmOutputCapacityInsufficient";
  int current[2]{}, previous[2]{}, index[2]{}, predictor[2]{};
  std::int64_t delta[2]{};
  for (unsigned c = 0; c < f.channels; ++c) {
    if (f.tag == 17) {
      current[c] = signedWord(b, 4 * c);
      index[c] = byte(b, 4 * c + 2);
      if (index[c] > 88 || byte(b, 4 * c + 3) != 0)
        return "AdpcmImaHeaderInvalid";
    } else {
      predictor[c] = byte(b, c);
      delta[c] = word(b, f.channels + 2 * c);
      current[c] = signedWord(b, 3 * f.channels + 2 * c);
      previous[c] = signedWord(b, 5 * f.channels + 2 * c);
      if (predictor[c] > 6 || delta[c] < 16)
        return "AdpcmMsHeaderInvalid";
    }
  }
  auto emit = [&](unsigned frame, unsigned c, int n) {
    out[static_cast<std::size_t>(frame) * f.channels + c] =
        static_cast<float>(n) * (1.0F / 32768.0F);
  };
  for (unsigned c = 0; c < f.channels; ++c) {
    emit(0, c, f.tag == 17 ? current[c] : previous[c]);
    if (f.tag == 2)
      emit(1, c, current[c]);
  }
  for (unsigned frame = f.tag == 17 ? 1 : 2; frame < f.blockFrames; ++frame) {
    for (unsigned c = 0; c < f.channels; ++c) {
      int n;
      if (f.tag == 17) {
        const auto sample = frame - 1;
        n = (byte(b, 4 * f.channels + (sample / 8) * 4 * f.channels + 4 * c +
                         (sample % 8) / 2) >>
             (4 * (sample % 2))) &
            15;
        const int step = steps[index[c]];
        const int difference = step / 8 + ((n & 1) ? step / 4 : 0) +
                               ((n & 2) ? step / 2 : 0) + ((n & 4) ? step : 0);
        current[c] = clip(current[c] + ((n & 8) ? -difference : difference));
        index[c] = std::clamp(index[c] + indices[n & 7], 0, 88);
      } else {
        const auto sample = (frame - 2) * f.channels + c;
        n = (byte(b, 7 * f.channels + sample / 2) >> (sample % 2 ? 0 : 4)) & 15;
        const auto p = static_cast<std::size_t>(predictor[c]) * 2;
        const auto prediction =
            (static_cast<std::int64_t>(current[c]) * f.coefficients[p] +
             static_cast<std::int64_t>(previous[c]) * f.coefficients[p + 1]) /
            256;
        previous[c] = current[c];
        current[c] = clip(prediction + (n < 8 ? n : n - 16) * delta[c]);
        // Refuse unrepresentable adaptation instead of wrapping or guessing.
        if (delta[c] > INT64_MAX / 768)
          return "AdpcmDeltaOverflow";
        delta[c] = std::max<std::int64_t>(delta[c] * adaptation[n] / 256, 16);
      }
      emit(frame, c, current[c]);
    }
  }
  return nullptr;
}
} // namespace wam::media
