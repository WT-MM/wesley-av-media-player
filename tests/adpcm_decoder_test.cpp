#include "media/adpcm_decoder.hpp"
#include <algorithm>
#include <array>
#include <cstdlib>
#include <iostream>
#include <vector>
using namespace wam::media;
void check(bool b) {
  if (!b) {
    std::cerr << "ADPCM assertion failed\n";
    std::exit(1);
  }
}
void put(std::vector<std::byte> &b, unsigned p, int n) {
  b[p] = std::byte(n & 255);
  b[p + 1] = std::byte((n >> 8) & 255);
}
int main() {
  for (unsigned channels : {1U, 2U}) {
    AdpcmFormat f{17, channels, 8 * channels, 9};
    std::vector<std::byte> b(f.blockBytes);
    std::vector<float> out(f.blockFrames * channels);
    for (unsigned c = 0; c < channels; ++c) {
      put(b, 4 * c, c ? -100 : 100);
      for (unsigned i = 0; i < 4; ++i)
        b[4 * channels + 4 * c + i] = std::byte(c ? 0x99 : 0x11);
    }
    // Index zero stays zero for magnitude one. step=7, difference=
    // floor(7/8)+floor(7/4)=1; low nibble precedes high nibble.
    check(!decodeAdpcmBlock(f, b, out));
    for (unsigned i = 0; i < 9; ++i)
      for (unsigned c = 0; c < channels; ++c)
        check(out[i * channels + c] ==
              float(c ? -100 - int(i) : 100 + int(i)) / 32768);
    auto first = out;
    // From predictor 0/index 0, codes 1,2,3,4,5,6,7,8 use steps
    // 7,7,7,7,9,13,23,50 and deltas 1,3,4,7,12,20,41,-6.
    for (unsigned c = 0; c < channels; ++c) {
      put(b, 4 * c, 0);
      for (unsigned i = 0; i < 4; ++i)
        b[4 * channels + 4 * c + i] =
            std::byte((2 * i + 1) | ((2 * i + 2) << 4));
    }
    check(!decodeAdpcmBlock(f, b, out));
    constexpr int ramp[]{0, 1, 4, 8, 15, 27, 47, 88, 82};
    for (unsigned i = 0; i < 9; ++i)
      for (unsigned c = 0; c < channels; ++c)
        check(out[i * channels + c] == float(ramp[i]) / 32768);
    first = out;
    check(!decodeAdpcmBlock(f, b, out) &&
          first == out); // final block has fresh history
    for (unsigned c = 0; c < channels; ++c) {
      put(b, 4 * c, 32760);
      b[4 * c + 2] = std::byte{88};
    }
    check(!decodeAdpcmBlock(f, b, out));
    check(out[channels] == 32767.0F / 32768);
    b[2] = std::byte{89};
    std::fill(out.begin(), out.end(), 42);
    check(decodeAdpcmBlock(f, b, out) != nullptr && out[0] == 42);
    b[2] = std::byte{0};
    b[3] = std::byte{1};
    check(decodeAdpcmBlock(f, b, out) != nullptr);
    b[3] = std::byte{0};
    check(decodeAdpcmBlock(f, std::span(b).first(b.size() - 1), out) !=
          nullptr);
    b.push_back(std::byte{0});
    check(decodeAdpcmBlock(f, b, out) != nullptr);
    b.pop_back();
    check(decodeAdpcmBlock(f, b, std::span(out).first(1)) != nullptr);
    ++f.blockFrames;
    check(validateAdpcmFormat(f) != nullptr);
    for (unsigned predictor = 0; predictor < 7; ++predictor) {
      f = {2, channels, 9 * channels, 6};
      b.assign(f.blockBytes, std::byte{});
      out.resize(6 * channels);
      for (unsigned c = 0; c < channels; ++c) {
        b[c] = std::byte(predictor);
        put(b, channels + 2 * c, 16);
        put(b, 3 * channels + 2 * c, c ? -101 : 101);
        put(b, 5 * channels + 2 * c, c ? 203 : -203);
      }
      for (unsigned i = 7 * channels; i < b.size(); ++i)
        b[i] = std::byte{0x7f};
      check(!decodeAdpcmBlock(f, b, out));
      // MS emits sample2, sample1, then high/low signed residuals. Prediction
      // divides the coefficient dot product toward zero before residual
      // addition.
      for (unsigned c = 0; c < channels; ++c) {
        int older = c ? 203 : -203, newer = c ? -101 : 101, d = 16;
        check(out[c] == float(older) / 32768 &&
              out[channels + c] == float(newer) / 32768);
        for (unsigned frame = 2; frame < 6; ++frame) {
          const bool high = ((frame - 2) * channels + c) % 2 == 0;
          int sample = (newer * kAdpcmMsCoefficients[2 * predictor] +
                        older * kAdpcmMsCoefficients[2 * predictor + 1]) /
                           256 +
                       (high ? 7 : -1) * d;
          sample = std::clamp(sample, -32768, 32767);
          older = newer;
          newer = sample;
          d = std::max(16, d * (high ? 614 : 230) / 256);
          check(out[frame * channels + c] == float(sample) / 32768);
        }
      }
      first = out;
      check(!decodeAdpcmBlock(f, b, out) && first == out);
      b[0] = std::byte{7};
      check(decodeAdpcmBlock(f, b, out) != nullptr);
      b[0] = std::byte{0};
      put(b, channels, 0);
      check(decodeAdpcmBlock(f, b, out) != nullptr);
      f.coefficients[0] = 255;
      check(validateAdpcmFormat(f) != nullptr);
    }
  }
  {
    AdpcmFormat f{17, 1, 5, 3};
    std::array<std::byte, 5> b{std::byte{0}, std::byte{0}, std::byte{0},
                               std::byte{0}, std::byte{0x11}};
    std::array<float, 3> out{};
    check(!decodeAdpcmBlock(f, b, out));
    check(out[0] == 0 && out[1] == 1.0F / 32768 && out[2] == 2.0F / 32768);
  }
  check(validateAdpcmFormat({17, 3, 24, 9}) != nullptr);
  std::cout << "ADPCM known answers and refusals passed\n";
}
