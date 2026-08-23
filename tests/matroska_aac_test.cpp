#include "media/matroska_aac.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <span>

namespace {

using wam::media::MediaTime;
using namespace wam::media::matroska;

int failures = 0;

void expect(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

template <std::size_t Size>
[[nodiscard]] constexpr std::array<std::byte, Size>
bytes(const std::array<std::uint8_t, Size> &values) noexcept {
  std::array<std::byte, Size> result{};
  for (std::size_t index = 0; index < Size; ++index) {
    result[index] = static_cast<std::byte>(values[index]);
  }
  return result;
}

[[nodiscard]] constexpr std::array<std::byte, 2>
twoByteAsc(std::uint8_t audioObjectType, std::uint8_t samplingFrequencyIndex,
           std::uint8_t channelConfiguration, std::uint8_t flags = 0) noexcept {
  const std::uint16_t packed = static_cast<std::uint16_t>(
      (static_cast<std::uint16_t>(audioObjectType & 0x1FU) << 11U) |
      (static_cast<std::uint16_t>(samplingFrequencyIndex & 0x0FU) << 7U) |
      (static_cast<std::uint16_t>(channelConfiguration & 0x0FU) << 3U) |
      static_cast<std::uint16_t>(flags & 0x07U));
  return {static_cast<std::byte>((packed >> 8U) & 0xFFU),
          static_cast<std::byte>(packed & 0xFFU)};
}

void expectRejected(std::span<const std::byte> asc,
                    AacLcAdmissionError expectedError, const char *message) {
  const AacLcAdmission result = parseAacLcAudioSpecificConfig(asc);
  expect(!result.admitted() && !result.configuration.has_value() &&
             result.error == expectedError,
         message);
}

void testCanonicalAdmission() {
  const auto stereo48 = twoByteAsc(2, 3, 2);
  const auto admitted48 = parseAacLcAudioSpecificConfig(stereo48);
  expect(admitted48.admitted(), "48 kHz stereo AAC-LC is admitted");
  if (admitted48.configuration) {
    expect(admitted48.configuration->sampleRate == 48'000U,
           "48 kHz sampling index is decoded exactly");
    expect(admitted48.configuration->channelCount == 2U,
           "stereo channel configuration is retained");
    expect(admitted48.configuration->audioSpecificConfigSize == 2U &&
               admitted48.configuration->audioSpecificConfig[0] ==
                   std::byte{0x11} &&
               admitted48.configuration->audioSpecificConfig[1] ==
                   std::byte{0x90},
           "canonical 0x1190 bytes are retained exactly");
    expect(!admitted48.configuration->ffmpegSyncExtensionPresent,
           "canonical ASC has no sync extension");
  }

  const auto mono48 = parseAacLcAudioSpecificConfig(twoByteAsc(2, 3, 1));
  expect(mono48.admitted() && mono48.configuration->sampleRate == 48'000U &&
             mono48.configuration->channelCount == 1U,
         "48 kHz mono AAC-LC is admitted");
  const auto stereo441 = parseAacLcAudioSpecificConfig(twoByteAsc(2, 4, 2));
  expect(stereo441.admitted() &&
             stereo441.configuration->sampleRate == 44'100U &&
             stereo441.configuration->channelCount == 2U,
         "44.1 kHz stereo AAC-LC is admitted");
  const auto mono441 = parseAacLcAudioSpecificConfig(twoByteAsc(2, 4, 1));
  expect(mono441.admitted() && mono441.configuration->sampleRate == 44'100U &&
             mono441.configuration->channelCount == 1U,
         "44.1 kHz mono AAC-LC is admitted");

  constexpr auto ffmpeg =
      bytes<5>(std::array<std::uint8_t, 5>{0x11, 0x90, 0x56, 0xE5, 0x00});
  const auto admittedFfmpeg = parseAacLcAudioSpecificConfig(ffmpeg);
  expect(admittedFfmpeg.admitted(),
         "FFmpeg five-byte AAC-LC ASC with absent SBR is admitted");
  if (admittedFfmpeg.configuration) {
    expect(admittedFfmpeg.configuration->sampleRate == 48'000U &&
               admittedFfmpeg.configuration->channelCount == 2U &&
               admittedFfmpeg.configuration->audioSpecificConfigSize == 5U &&
               admittedFfmpeg.configuration->ffmpegSyncExtensionPresent,
           "FFmpeg sync-extension admission retains exact derived fields");
    expect(admittedFfmpeg.configuration->audioSpecificConfig == ffmpeg,
           "FFmpeg ASC bytes are retained without normalization");
  }
}

void testMalformedAdmissionCorpus() {
  constexpr std::array<std::byte, 0> empty{};
  constexpr std::array one{std::byte{0x11}};
  constexpr std::array three{std::byte{0x11}, std::byte{0x90}, std::byte{0x00}};
  constexpr std::array four{std::byte{0x11}, std::byte{0x90}, std::byte{0x00},
                            std::byte{0x00}};
  constexpr std::array six{std::byte{0x11}, std::byte{0x90}, std::byte{0x56},
                           std::byte{0xE5}, std::byte{0x00}, std::byte{0x00}};
  for (const auto malformed :
       {std::span<const std::byte>(empty), std::span<const std::byte>(one),
        std::span<const std::byte>(three), std::span<const std::byte>(four),
        std::span<const std::byte>(six)}) {
    expectRejected(malformed,
                   AacLcAdmissionError::InvalidAudioSpecificConfigSize,
                   "ASC sizes other than two or five bytes are rejected");
  }

  expectRejected(twoByteAsc(5, 3, 2),
                 AacLcAdmissionError::UnsupportedAudioObjectType,
                 "initial SBR audio object type is rejected");
  expectRejected(twoByteAsc(29, 3, 2),
                 AacLcAdmissionError::UnsupportedAudioObjectType,
                 "initial PS audio object type is rejected");
  expectRejected(twoByteAsc(17, 3, 2),
                 AacLcAdmissionError::UnsupportedAudioObjectType,
                 "ER AAC-LC audio object type is rejected");
  expectRejected(twoByteAsc(2, 15, 2),
                 AacLcAdmissionError::ExplicitSamplingFrequency,
                 "explicit sampling frequency is rejected before payload read");
  expectRejected(twoByteAsc(2, 2, 2),
                 AacLcAdmissionError::UnsupportedSamplingFrequency,
                 "unsupported indexed sampling frequency is rejected");
  expectRejected(twoByteAsc(2, 3, 0), AacLcAdmissionError::ProgramConfigElement,
                 "PCE channel configuration is rejected");
  // channelConfiguration 3..6 (3.0, 4.0, 5.0 and 5.1) are now ADMITTED: the
  // player decodes the full layout and folds it to stereo itself with exact
  // BS.775 coefficients. Configuration 7 is the only remaining refusal -- it
  // is the eight-channel front-wide 3/4.1 arrangement whose front-of-centre
  // channels have no measured downmix coefficient.
  expect(parseAacLcAudioSpecificConfig(twoByteAsc(2, 3, 6)).admitted(),
         "5.1 channel configuration is admitted");
  expectRejected(twoByteAsc(2, 3, 7),
                 AacLcAdmissionError::UnsupportedChannelConfiguration,
                 "the front-wide eight-channel configuration is rejected");
  expectRejected(twoByteAsc(2, 3, 2, 0b100),
                 AacLcAdmissionError::UnsupportedFrameLength,
                 "960-sample frameLengthFlag is rejected");
  expectRejected(twoByteAsc(2, 3, 2, 0b010),
                 AacLcAdmissionError::CoreCoderDependency,
                 "dependsOnCoreCoder is rejected");
  expectRejected(twoByteAsc(2, 3, 2, 0b001),
                 AacLcAdmissionError::UnsupportedExtensionFlag,
                 "GASpecificConfig extensionFlag is rejected");

  constexpr auto wrongSync =
      bytes<5>(std::array<std::uint8_t, 5>{0x11, 0x90, 0x00, 0x00, 0x00});
  expectRejected(wrongSync, AacLcAdmissionError::InvalidSyncExtension,
                 "unrecognized five-byte tail is rejected");
  constexpr auto wrongExtensionAot =
      bytes<5>(std::array<std::uint8_t, 5>{0x11, 0x90, 0x56, 0xE4, 0x00});
  expectRejected(wrongExtensionAot,
                 AacLcAdmissionError::UnsupportedExtensionAudioObjectType,
                 "sync extension must name SBR audio object type five");
  constexpr auto sbrPresent =
      bytes<5>(std::array<std::uint8_t, 5>{0x11, 0x90, 0x56, 0xE5, 0x80});
  expectRejected(sbrPresent, AacLcAdmissionError::SbrPresent,
                 "SBR-present sync extension is rejected");
  constexpr auto nonzeroTail =
      bytes<5>(std::array<std::uint8_t, 5>{0x11, 0x90, 0x56, 0xE5, 0x01});
  expectRejected(nonzeroTail, AacLcAdmissionError::NonzeroTrailingBits,
                 "unexplained nonzero trailing bits are rejected");

  std::size_t admittedTwoByteForms = 0;
  for (std::uint32_t packed = 0; packed <= 0xFFFFU; ++packed) {
    const std::array candidate{static_cast<std::byte>((packed >> 8U) & 0xFFU),
                               static_cast<std::byte>(packed & 0xFFU)};
    const auto result = parseAacLcAudioSpecificConfig(candidate);
    if (!result.admitted()) {
      continue;
    }
    ++admittedTwoByteForms;
    // AOT 2, sampling index 3 (48 kHz) or 4 (44.1 kHz), channel
    // configuration 1..6, and all three trailing GASpecificConfig flags zero:
    // 0x1000 | (index << 7) | (configuration << 3).
    const std::uint32_t samplingIndex = (packed >> 7U) & 0x0FU;
    const std::uint32_t channelConfiguration = (packed >> 3U) & 0x0FU;
    expect((packed >> 11U) == 2U && (packed & 0x07U) == 0U &&
               (samplingIndex == 3U || samplingIndex == 4U) &&
               channelConfiguration >= 1U && channelConfiguration <= 6U,
           "exhaustive two-byte corpus admits no form outside the contract");
  }
  expect(admittedTwoByteForms == 12U,
         "exhaustive two-byte corpus admits exactly 44.1/48 kHz, one to six "
         "channels");
}

void testEsDescriptorGoldenAndRevalidation() {
  constexpr auto stereo48 = bytes<2>(std::array<std::uint8_t, 2>{0x11, 0x90});
  const auto admission = parseAacLcAudioSpecificConfig(stereo48);
  expect(admission.admitted(), "golden ASC is admitted before cookie build");
  if (!admission.configuration) {
    return;
  }
  const auto cookie = buildAacLcEsDescriptorCookie(*admission.configuration);
  expect(cookie.has_value(), "admitted ASC builds an ES descriptor cookie");
  constexpr auto golden = bytes<39>(std::array<std::uint8_t, 39>{
      0x03, 0x80, 0x80, 0x80, 0x22, 0x00, 0x01, 0x00, 0x04, 0x80,
      0x80, 0x80, 0x14, 0x40, 0x15, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x80, 0x80, 0x80,
      0x02, 0x11, 0x90, 0x06, 0x80, 0x80, 0x80, 0x01, 0x02});
  expect(cookie && cookie->size == golden.size() &&
             std::equal(cookie->view().begin(), cookie->view().end(),
                        golden.begin(), golden.end()),
         "0x1190 builds the exact 39-byte four-byte-expandable cookie");

  constexpr auto ffmpeg =
      bytes<5>(std::array<std::uint8_t, 5>{0x11, 0x90, 0x56, 0xE5, 0x00});
  const auto ffmpegAdmission = parseAacLcAudioSpecificConfig(ffmpeg);
  const auto ffmpegCookie =
      ffmpegAdmission.configuration
          ? buildAacLcEsDescriptorCookie(*ffmpegAdmission.configuration)
          : std::nullopt;
  expect(ffmpegCookie && ffmpegCookie->size == 42U,
         "five-byte ASC builds within the fixed 42-byte maximum");
  if (ffmpegCookie) {
    constexpr auto ffmpegGolden = bytes<42>(std::array<std::uint8_t, 42>{
        0x03, 0x80, 0x80, 0x80, 0x25, 0x00, 0x01, 0x00, 0x04, 0x80, 0x80,
        0x80, 0x17, 0x40, 0x15, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x05, 0x80, 0x80, 0x80, 0x05, 0x11, 0x90,
        0x56, 0xE5, 0x00, 0x06, 0x80, 0x80, 0x80, 0x01, 0x02});
    expect(std::equal(ffmpegCookie->view().begin(), ffmpegCookie->view().end(),
                      ffmpegGolden.begin(), ffmpegGolden.end()),
           "five-byte cookie matches the exact bounded ES descriptor grammar");
  }

  auto forged = *admission.configuration;
  forged.sampleRate = 44'100U;
  expect(!buildAacLcEsDescriptorCookie(forged).has_value(),
         "builder rejects a forged derived sample rate");
  forged = *admission.configuration;
  forged.channelCount = 1U;
  expect(!buildAacLcEsDescriptorCookie(forged).has_value(),
         "builder rejects a forged derived channel count");
  forged = *admission.configuration;
  forged.ffmpegSyncExtensionPresent = true;
  expect(!buildAacLcEsDescriptorCookie(forged).has_value(),
         "builder rejects a forged sync-extension flag");
  forged = *admission.configuration;
  forged.audioSpecificConfig[4] = std::byte{0x01};
  expect(!buildAacLcEsDescriptorCookie(forged).has_value(),
         "builder rejects noncanonical bytes outside the retained ASC");
  forged = *admission.configuration;
  forged.audioSpecificConfigSize = 6U;
  expect(!buildAacLcEsDescriptorCookie(forged).has_value(),
         "builder rejects a forged ASC size before forming a span");
}

void testExactAacFrameGrid() {
  const auto first48 = aacAccessUnitGridTime({MediaTime{0, 1}, 1, 48'000U});
  expect(first48 == MediaTime{8, 375},
         "48 kHz ordinal one is exactly 1024/48000 seconds");
  const auto third48 = aacAccessUnitGridTime({MediaTime{0, 1}, 3, 48'000U});
  expect(third48 == MediaTime{8, 125},
         "48 kHz ordinal three is reduced without incremental rounding");
  const auto offset48 = aacAccessUnitGridTime({MediaTime{1, 10}, 1, 48'000U});
  expect(offset48 == MediaTime{91, 750},
         "nonzero origin combines exactly with the AAC frame grid");
  const auto negative48 = aacAccessUnitGridTime({MediaTime{-1, 2}, 1, 48'000U});
  expect(negative48 == MediaTime{-359, 750},
         "negative origin remains an exact rational");

  constexpr std::uint64_t longOrdinal = (std::uint64_t{1} << 32U) + 17U;
  const auto long441 =
      aacAccessUnitGridTime({MediaTime{0, 1}, longOrdinal, 44'100U});
  expect(long441 == MediaTime{52'357'696'768LL, 525},
         "44.1 kHz grid stays exact beyond 32-bit access-unit ordinals");

  expect(!aacAccessUnitGridTime({MediaTime{0, 0}, 1, 48'000U}),
         "invalid origin time is rejected");
  expect(!aacAccessUnitGridTime({MediaTime{0, 1}, 1, 32'000U}),
         "unsupported grid sample rate is rejected");
  expect(!aacAccessUnitGridTime(
             {MediaTime{std::numeric_limits<std::int64_t>::max(), 1},
              std::numeric_limits<std::uint64_t>::max(), 44'100U}),
         "unrepresentable exact grid timestamp fails closed");
}

void testTiesEvenQuantizationAndGapProof() {
  constexpr std::uint64_t millisecondTicks{1'000'000U};
  expect(nearestMatroskaTick({MediaTime{0, 1}, 1, 48'000U}, millisecondTicks) ==
             21,
         "48 kHz first frame rounds down to the nearest millisecond tick");
  expect(nearestMatroskaTick({MediaTime{0, 1}, 2, 48'000U}, millisecondTicks) ==
             43,
         "48 kHz second frame rounds up to the nearest millisecond tick");
  expect(nearestMatroskaTick({MediaTime{0, 1}, 3, 48'000U}, millisecondTicks) ==
             64,
         "exact millisecond tick remains unchanged");
  expect(nearestMatroskaTick({MediaTime{0, 1}, 1'000'000U, 44'100U},
                             millisecondTicks) == 23'219'955,
         "long 44.1 kHz quantization derives from the ordinal without drift");

  constexpr std::uint64_t oneSecondTicks{1'000'000'000U};
  expect(nearestMatroskaTick({MediaTime{1, 2}, 0, 48'000U}, oneSecondTicks) ==
             0,
         "positive half tie rounds to even zero");
  expect(nearestMatroskaTick({MediaTime{3, 2}, 0, 48'000U}, oneSecondTicks) ==
             2,
         "positive one-and-a-half tie rounds to even two");
  expect(nearestMatroskaTick({MediaTime{-1, 2}, 0, 48'000U}, oneSecondTicks) ==
             0,
         "negative half tie rounds to even zero");
  expect(nearestMatroskaTick({MediaTime{-3, 2}, 0, 48'000U}, oneSecondTicks) ==
             -2,
         "negative one-and-a-half tie rounds to even minus two");

  constexpr AacFrameGridPosition ordinal100{MediaTime{0, 1}, 100, 48'000U};
  constexpr AacFrameGridPosition ordinal101{MediaTime{0, 1}, 101, 48'000U};
  const auto tick100 = nearestMatroskaTick(ordinal100, millisecondTicks);
  const auto tick101 = nearestMatroskaTick(ordinal101, millisecondTicks);
  expect(tick100 == 2'133 && tick101 == 2'155,
         "adjacent grid ticks are reconstructed deterministically");
  expect(tick100 && matroskaTickMatchesAacAccessUnit(*tick100, ordinal100,
                                                     millisecondTicks),
         "observed tick proves its exact access-unit ordinal");
  expect(tick101 && !matroskaTickMatchesAacAccessUnit(*tick101, ordinal100,
                                                      millisecondTicks),
         "a skipped access unit is detected as a tick/grid gap");

  expect(!nearestMatroskaTick({MediaTime{0, 1}, 0, 48'000U}, 0U),
         "zero Matroska timestamp scale is rejected");
  expect(
      !matroskaTickMatchesAacAccessUnit(0, {MediaTime{0, 1}, 0, 48'000U}, 0U),
      "tick proof fails closed for an invalid scale");
  expect(
      !nearestMatroskaTick(
          {MediaTime{std::numeric_limits<std::int64_t>::max(), 1}, 0, 48'000U},
          1U),
      "positive tick overflow is rejected");
  expect(
      !nearestMatroskaTick(
          {MediaTime{std::numeric_limits<std::int64_t>::min(), 1}, 0, 48'000U},
          1U),
      "negative tick overflow is rejected");
  expect(
      nearestMatroskaTick(
          {MediaTime{std::numeric_limits<std::int64_t>::max(), 1}, 0, 48'000U},
          oneSecondTicks) == std::numeric_limits<std::int64_t>::max(),
      "largest representable positive tick is preserved");
  expect(
      nearestMatroskaTick(
          {MediaTime{std::numeric_limits<std::int64_t>::min(), 1}, 0, 48'000U},
          oneSecondTicks) == std::numeric_limits<std::int64_t>::min(),
      "largest representable negative magnitude is preserved");
}

void testInverseTickProjection() {
  constexpr std::uint64_t millisecondTicks{1'000'000U};
  const auto exact48 = nearestAacAccessUnitForMatroskaTick(
      2'133, MediaTime{0, 1}, 48'000U, millisecondTicks);
  expect(exact48 && exact48->accessUnitOrdinal == 100U &&
             exact48->exactPresentationTime == MediaTime{32, 15} &&
             exact48->quantizedGridTick == 2'133 &&
             exact48->signedTickResidual == 0 && exact48->exactTickMatch,
         "48 kHz tick projects to ordinal 100 and its exact grid PTS");

  const auto positiveResidual = nearestAacAccessUnitForMatroskaTick(
      2'134, MediaTime{0, 1}, 48'000U, millisecondTicks);
  expect(positiveResidual && positiveResidual->accessUnitOrdinal == 100U &&
             positiveResidual->quantizedGridTick == 2'133 &&
             positiveResidual->signedTickResidual == 1 &&
             !positiveResidual->exactTickMatch,
         "inverse reports a positive tick residual without tolerance");
  const auto negativeResidual = nearestAacAccessUnitForMatroskaTick(
      2'132, MediaTime{0, 1}, 48'000U, millisecondTicks);
  expect(negativeResidual && negativeResidual->accessUnitOrdinal == 100U &&
             negativeResidual->quantizedGridTick == 2'133 &&
             negativeResidual->signedTickResidual == -1 &&
             !negativeResidual->exactTickMatch,
         "inverse reports a negative tick residual without tolerance");

  const auto negativeTick = nearestAacAccessUnitForMatroskaTick(
      -787, MediaTime{-1, 1}, 48'000U, millisecondTicks);
  expect(
      negativeTick && negativeTick->accessUnitOrdinal == 10U &&
          negativeTick->exactPresentationTime == MediaTime{-59, 75} &&
          negativeTick->quantizedGridTick == -787 &&
          negativeTick->signedTickResidual == 0 && negativeTick->exactTickMatch,
      "negative observed tick projects exactly relative to a negative origin");

  const auto long441 = nearestAacAccessUnitForMatroskaTick(
      23'219'955, MediaTime{0, 1}, 44'100U, millisecondTicks);
  expect(long441 && long441->accessUnitOrdinal == 1'000'000U &&
             long441->exactPresentationTime == MediaTime{10'240'000, 441} &&
             long441->quantizedGridTick == 23'219'955 &&
             long441->exactTickMatch,
         "long 44.1 kHz tick round-trips without scanning from ordinal zero");

  // Use rational origins to place observed tick zero at exact half-access-unit
  // boundaries. This proves inverse ordinal rounding independently of the
  // later Matroska tick re-quantization.
  constexpr std::uint64_t oneSecondTicks{1'000'000'000U};
  const auto positiveHalfEvenZero = nearestAacAccessUnitForMatroskaTick(
      0, MediaTime{-4, 375}, 48'000U, oneSecondTicks);
  expect(positiveHalfEvenZero &&
             positiveHalfEvenZero->accessUnitOrdinal == 0U &&
             positiveHalfEvenZero->exactTickMatch,
         "positive ordinal half tie chooses even zero");
  const auto positiveHalfEvenTwo = nearestAacAccessUnitForMatroskaTick(
      0, MediaTime{-4, 125}, 48'000U, oneSecondTicks);
  expect(positiveHalfEvenTwo && positiveHalfEvenTwo->accessUnitOrdinal == 2U &&
             positiveHalfEvenTwo->exactPresentationTime == MediaTime{4, 375} &&
             positiveHalfEvenTwo->exactTickMatch,
         "positive one-and-a-half ordinal tie chooses even two");
  const auto negativeHalfEvenZero = nearestAacAccessUnitForMatroskaTick(
      0, MediaTime{4, 375}, 48'000U, oneSecondTicks);
  expect(negativeHalfEvenZero &&
             negativeHalfEvenZero->accessUnitOrdinal == 0U &&
             negativeHalfEvenZero->exactTickMatch,
         "negative ordinal half tie chooses even zero");
  expect(!nearestAacAccessUnitForMatroskaTick(0, MediaTime{4, 125}, 48'000U,
                                              oneSecondTicks),
         "negative one-and-a-half tie rejects an unrepresentable ordinal");
  const auto half441 = nearestAacAccessUnitForMatroskaTick(
      0, MediaTime{-128, 11'025}, 44'100U, oneSecondTicks);
  expect(half441 && half441->accessUnitOrdinal == 0U && half441->exactTickMatch,
         "44.1 kHz half-access-unit tie also chooses even zero");

  // Forward/inverse agreement across representative signed origins, rates,
  // and long ordinals. Coarser timestamp scales may map multiple grid points
  // to one tick, so these cases use the normal 1 ms Matroska scale where the
  // AAC access-unit interval remains uniquely distinguishable.
  constexpr std::array<AacFrameGridPosition, 6> roundTrips{
      AacFrameGridPosition{MediaTime{0, 1}, 0, 48'000U},
      AacFrameGridPosition{MediaTime{0, 1}, 1, 48'000U},
      AacFrameGridPosition{MediaTime{1, 10}, 10'000, 48'000U},
      AacFrameGridPosition{MediaTime{-1, 1}, 10, 48'000U},
      AacFrameGridPosition{MediaTime{0, 1}, 1, 44'100U},
      AacFrameGridPosition{MediaTime{7, 13}, 1'000'000, 44'100U}};
  for (const AacFrameGridPosition grid : roundTrips) {
    const auto tick = nearestMatroskaTick(grid, millisecondTicks);
    const auto projection =
        tick ? nearestAacAccessUnitForMatroskaTick(
                   *tick, grid.origin, grid.sampleRate, millisecondTicks)
             : std::nullopt;
    expect(
        tick && projection &&
            projection->accessUnitOrdinal == grid.accessUnitOrdinal &&
            projection->exactPresentationTime == aacAccessUnitGridTime(grid) &&
            projection->quantizedGridTick == *tick &&
            projection->signedTickResidual == 0 && projection->exactTickMatch,
        "forward tick quantization and inverse ordinal projection agree");
  }

  expect(!nearestAacAccessUnitForMatroskaTick(0, MediaTime{0, 0}, 48'000U,
                                              millisecondTicks),
         "inverse rejects an invalid origin rational");
  expect(!nearestAacAccessUnitForMatroskaTick(0, MediaTime{0, 1}, 32'000U,
                                              millisecondTicks),
         "inverse rejects an unsupported sample rate");
  expect(!nearestAacAccessUnitForMatroskaTick(0, MediaTime{0, 1}, 48'000U, 0U),
         "inverse rejects a zero timestamp scale");
  expect(!nearestAacAccessUnitForMatroskaTick(-12, MediaTime{0, 1}, 48'000U,
                                              millisecondTicks),
         "inverse rejects a genuinely negative nearest ordinal");
  expect(!nearestAacAccessUnitForMatroskaTick(
             std::numeric_limits<std::int64_t>::max(), MediaTime{0, 1}, 48'000U,
             oneSecondTicks),
         "inverse rejects an ordinal beyond uint64");
  expect(!nearestAacAccessUnitForMatroskaTick(
             std::numeric_limits<std::int64_t>::max(),
             MediaTime{std::numeric_limits<std::int64_t>::min(),
                       std::numeric_limits<std::int32_t>::max()},
             48'000U, std::numeric_limits<std::uint64_t>::max()),
         "inverse fails closed when an exact 128-bit cross-product overflows");
}

void testGridRoundTripStress() {
  constexpr std::array<std::uint32_t, 2> sampleRates{44'100U, 48'000U};
  constexpr std::array<std::uint64_t, 2> tickScales{1'000U, 1'000'000U};
  constexpr std::array<MediaTime, 2> origins{MediaTime{-12'345, 1'000},
                                             MediaTime{7, 13}};
  for (std::size_t rateIndex = 0; rateIndex < sampleRates.size(); ++rateIndex) {
    for (const std::uint64_t tickScale : tickScales) {
      for (std::uint64_t ordinal = 0; ordinal < 20'000U; ++ordinal) {
        const AacFrameGridPosition grid{origins[rateIndex], ordinal,
                                        sampleRates[rateIndex]};
        const auto tick = nearestMatroskaTick(grid, tickScale);
        const auto projection =
            tick ? nearestAacAccessUnitForMatroskaTick(
                       *tick, grid.origin, grid.sampleRate, tickScale)
                 : std::nullopt;
        expect(tick && projection && projection->accessUnitOrdinal == ordinal &&
                   projection->exactPresentationTime ==
                       aacAccessUnitGridTime(grid) &&
                   projection->quantizedGridTick == *tick &&
                   projection->signedTickResidual == 0 &&
                   projection->exactTickMatch,
               "80,000 exact forward/inverse grid points round-trip");
      }
    }
  }
}

} // namespace

int main() {
  static_assert(kAacLcMaximumAudioSpecificConfigBytes == 5U);
  static_assert(kAacLcMaximumEsDescriptorCookieBytes == 42U);
  static_assert(kAacLcSamplesPerAccessUnit == 1024U);

  testCanonicalAdmission();
  testMalformedAdmissionCorpus();
  testEsDescriptorGoldenAndRevalidation();
  testExactAacFrameGrid();
  testTiesEvenQuantizationAndGapProof();
  testInverseTickProjection();
  testGridRoundTripStress();

  if (failures != 0) {
    std::cerr << failures << " Matroska AAC test(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "Matroska AAC-LC admission, ES descriptor, and exact frame-grid "
               "tests passed\n";
  return EXIT_SUCCESS;
}
