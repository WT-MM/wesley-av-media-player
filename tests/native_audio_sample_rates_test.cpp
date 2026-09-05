// The native audio sample-rate family, asserted in BOTH directions. The header
// is read by four gates (source admission, session preflight, converter,
// output unit); a family that quietly gained or lost a member would move all
// four at once, and the only test that used to touch it was the frozen
// session test's single "unsupported rate" pin. Membership here is exactly the
// set proven sample-exact end to end (see the header): nothing is admitted on
// the strength of being an integer.

#include "platform/macos/native_audio_sample_rates.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>

#include "support/expect.hpp"

namespace {

using wam::macos::kNativeAudioSampleRates;
using wam::macos::nativeAudioSampleRateSupported;

void testEveryProvenRateIsAdmittedExactly() {
  constexpr std::uint32_t proven[] = {8'000,  11'025, 12'000, 16'000,
                                      22'050, 24'000, 32'000, 44'100,
                                      48'000, 96'000, 192'000};
  static_assert(sizeof(proven) / sizeof(proven[0]) ==
                kNativeAudioSampleRates.size());
  for (const std::uint32_t rate : proven) {
    std::uint32_t exact = 0;
    expect(nativeAudioSampleRateSupported(static_cast<double>(rate), &exact),
           "a proven rate is admitted");
    expect(exact == rate, "the exact integer rate is written back");
    expect(nativeAudioSampleRateSupported(static_cast<double>(rate)),
           "the exact-rate out parameter is optional");
  }
  // The family is stated in ascending order so a reader can find a rate by
  // eye; a future insertion out of order would read as a typo.
  for (std::size_t i = 1; i < kNativeAudioSampleRates.size(); ++i) {
    expect(kNativeAudioSampleRates[i - 1] < kNativeAudioSampleRates[i],
           "the family is stated in ascending order");
  }
}

void testUnprovenRatesStayRefused() {
  // Integral rates that were never proven: 88.2 kHz is pinned unsupported by
  // the frozen converter test; 64 kHz and 7 kHz are the session test's and
  // the ledger's canonical refusals; 176.4 kHz is the 88.2 twin.
  constexpr double refused[] = {7'000.0, 64'000.0, 88'200.0, 176'400.0,
                                384'001.0};
  for (const double rate : refused) {
    std::uint32_t exact = 12345;
    expect(!nativeAudioSampleRateSupported(rate, &exact),
           "an unproven integral rate is refused");
    expect(exact == 12345, "a refusal never writes the out parameter");
  }
  // Non-integral, degenerate and non-finite rates.
  expect(!nativeAudioSampleRateSupported(48'000.5), "non-integral");
  expect(!nativeAudioSampleRateSupported(47'999.999999), "near miss below");
  expect(!nativeAudioSampleRateSupported(0.0), "zero");
  expect(!nativeAudioSampleRateSupported(-48'000.0), "negative");
  expect(!nativeAudioSampleRateSupported(
             std::numeric_limits<double>::quiet_NaN()),
         "NaN");
  expect(!nativeAudioSampleRateSupported(
             std::numeric_limits<double>::infinity()),
         "infinity");
  // Above the neutral contract's hard ceiling nothing is admitted, whatever
  // the family says.
  expect(!nativeAudioSampleRateSupported(
             wam::media::MediaSourceLimits::kHardMaximumAudioSampleRate *
             2.0),
         "above the hard maximum");
}

}  // namespace

int main() {
  testEveryProvenRateIsAdmittedExactly();
  testUnprovenRatesStayRefused();
  if (failures != 0) {
    std::cerr << failures << " failure(s)\n";
    return EXIT_FAILURE;
  }
  std::cout << "native_audio_sample_rates: ok\n";
  return EXIT_SUCCESS;
}
