#include "media/matroska_opus.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <optional>
#include <span>

namespace {

using namespace wam::media::matroska;

int failures = 0;

void expect(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

// One OpusHead identification header, family 0, built field by field so every
// rejection case differs from the canonical bytes in exactly one place.
[[nodiscard]] constexpr std::array<std::byte, kOpusIdentificationHeaderBytes>
opusHead(std::uint8_t version = 1U, std::uint8_t channelCount = 2U,
         std::uint16_t preSkipFrames = 312U,
         std::uint32_t inputSampleRate = 48'000U,
         std::uint16_t outputGain = 0U, std::uint8_t mappingFamily = 0U,
         const char *magic = "OpusHead") noexcept {
  std::array<std::byte, kOpusIdentificationHeaderBytes> header{};
  for (std::size_t index = 0; index < 8U; ++index) {
    header[index] = static_cast<std::byte>(
        static_cast<std::uint8_t>(magic[index]));
  }
  header[8] = static_cast<std::byte>(version);
  header[9] = static_cast<std::byte>(channelCount);
  header[10] = static_cast<std::byte>(preSkipFrames & 0xFFU);
  header[11] = static_cast<std::byte>((preSkipFrames >> 8U) & 0xFFU);
  header[12] = static_cast<std::byte>(inputSampleRate & 0xFFU);
  header[13] = static_cast<std::byte>((inputSampleRate >> 8U) & 0xFFU);
  header[14] = static_cast<std::byte>((inputSampleRate >> 16U) & 0xFFU);
  header[15] = static_cast<std::byte>((inputSampleRate >> 24U) & 0xFFU);
  header[16] = static_cast<std::byte>(outputGain & 0xFFU);
  header[17] = static_cast<std::byte>((outputGain >> 8U) & 0xFFU);
  header[18] = static_cast<std::byte>(mappingFamily);
  return header;
}

void expectRejected(std::span<const std::byte> header,
                    OpusAdmissionError expectedError, const char *message) {
  const OpusAdmission result = parseOpusIdentificationHeader(header);
  expect(!result.admitted() && !result.configuration.has_value() &&
             result.error == expectedError,
         message);
}

void testCanonicalAdmission() {
  // The exact 19 bytes every ffmpeg Matroska Opus mux writes as CodecPrivate.
  constexpr std::array<std::byte, kOpusIdentificationHeaderBytes> ffmpeg{
      std::byte{0x4F}, std::byte{0x70}, std::byte{0x75}, std::byte{0x73},
      std::byte{0x48}, std::byte{0x65}, std::byte{0x61}, std::byte{0x64},
      std::byte{0x01}, std::byte{0x02}, std::byte{0x38}, std::byte{0x01},
      std::byte{0x80}, std::byte{0xBB}, std::byte{0x00}, std::byte{0x00},
      std::byte{0x00}, std::byte{0x00}, std::byte{0x00}};
  static_assert(ffmpeg == opusHead(),
                "the field builder reproduces the canonical ffmpeg header");

  const auto admitted = parseOpusIdentificationHeader(ffmpeg);
  expect(admitted.admitted(),
         "canonical 19-byte ffmpeg OpusHead is admitted");
  if (admitted.configuration) {
    expect(admitted.configuration->preSkipFrames == 312U,
           "little-endian pre-skip 312 is decoded exactly");
    expect(admitted.configuration->channelCount == 2U,
           "stereo channel count is retained");
    expect(admitted.configuration->inputSampleRate == 48'000U,
           "little-endian 48 kHz input rate is decoded exactly");
    expect(*admitted.configuration ==
               OpusConfiguration{312U, 2U, 48'000U},
           "no field outside the decoded three is invented");
  }

  const auto mono = parseOpusIdentificationHeader(opusHead(1U, 1U));
  expect(mono.admitted() && mono.configuration->channelCount == 1U &&
             mono.configuration->preSkipFrames == 312U &&
             mono.configuration->inputSampleRate == 48'000U,
         "mono OpusHead is admitted with channel count one");

  // inputSampleRate is informational; a non-48 kHz encoder input is still a
  // perfectly ordinary stream and must survive admission verbatim.
  const auto input441 =
      parseOpusIdentificationHeader(opusHead(1U, 2U, 312U, 44'100U));
  expect(input441.admitted() &&
             input441.configuration->inputSampleRate == 44'100U,
         "non-48 kHz encoder input rate is retained without normalization");

  // Both ends of the admitted pre-skip window.
  const auto minimumPreSkip =
      parseOpusIdentificationHeader(opusHead(1U, 2U, 120U));
  expect(minimumPreSkip.admitted() &&
             minimumPreSkip.configuration->preSkipFrames == 120U,
         "pre-skip exactly at the decoder delay is admitted");
  const auto maximumPreSkip =
      parseOpusIdentificationHeader(opusHead(1U, 2U, 3'840U));
  expect(maximumPreSkip.admitted() &&
             maximumPreSkip.configuration->preSkipFrames == 3'840U,
         "pre-skip exactly at the 80 ms ceiling is admitted");
}

void testAdmissionRejectionReasons() {
  constexpr std::array<std::byte, 0> empty{};
  constexpr std::array<std::byte, 18> eighteen{};
  constexpr std::array<std::byte, 20> twenty{};
  expectRejected(empty, OpusAdmissionError::InvalidHeaderSize,
                 "empty CodecPrivate is rejected on size");
  expectRejected(eighteen, OpusAdmissionError::InvalidHeaderSize,
                 "an 18-byte header is rejected on size");
  expectRejected(twenty, OpusAdmissionError::InvalidHeaderSize,
                 "a 20-byte header (mapping table) is rejected on size");

  expectRejected(opusHead(1U, 2U, 312U, 48'000U, 0U, 0U, "OpusHeaD"),
                 OpusAdmissionError::UnexpectedMagic,
                 "a single-case near miss in the magic is rejected");
  expectRejected(opusHead(1U, 2U, 312U, 48'000U, 0U, 0U, "opushead"),
                 OpusAdmissionError::UnexpectedMagic,
                 "lowercase magic is rejected");
  expectRejected(opusHead(1U, 2U, 312U, 48'000U, 0U, 0U, "OpusTags"),
                 OpusAdmissionError::UnexpectedMagic,
                 "the comment header magic is rejected");

  expectRejected(opusHead(0U), OpusAdmissionError::UnsupportedVersion,
                 "version 0 is rejected");
  expectRejected(opusHead(2U), OpusAdmissionError::UnsupportedVersion,
                 "version 2 is rejected");

  expectRejected(opusHead(1U, 0U), OpusAdmissionError::UnsupportedChannelCount,
                 "zero channels is rejected");
  expectRejected(opusHead(1U, 3U), OpusAdmissionError::UnsupportedChannelCount,
                 "three channels is rejected");

  expectRejected(opusHead(1U, 2U, 119U),
                 OpusAdmissionError::PreSkipBelowDecoderDelay,
                 "pre-skip one below the decoder delay is rejected");
  expectRejected(opusHead(1U, 2U, 0U),
                 OpusAdmissionError::PreSkipBelowDecoderDelay,
                 "zero pre-skip is rejected");

  expectRejected(opusHead(1U, 2U, 3'841U),
                 OpusAdmissionError::PreSkipExceedsMaximum,
                 "pre-skip one above the ceiling is rejected");
  expectRejected(opusHead(1U, 2U, 65'535U),
                 OpusAdmissionError::PreSkipExceedsMaximum,
                 "a saturated 16-bit pre-skip is rejected");

  // Output gain is a signed Q7.8 dB value; both signs must be refused.
  expectRejected(opusHead(1U, 2U, 312U, 48'000U, 0x0100U),
                 OpusAdmissionError::NonzeroOutputGain,
                 "positive Q7.8 output gain is rejected");
  expectRejected(opusHead(1U, 2U, 312U, 48'000U, 0xFF00U),
                 OpusAdmissionError::NonzeroOutputGain,
                 "negative Q7.8 output gain is rejected");
  expectRejected(opusHead(1U, 2U, 312U, 48'000U, 0x0001U),
                 OpusAdmissionError::NonzeroOutputGain,
                 "a single fractional gain bit is rejected");

  expectRejected(opusHead(1U, 2U, 312U, 48'000U, 0U, 1U),
                 OpusAdmissionError::UnsupportedChannelMappingFamily,
                 "mapping family 1 is rejected");
  expectRejected(opusHead(1U, 2U, 312U, 48'000U, 0U, 255U),
                 OpusAdmissionError::UnsupportedChannelMappingFamily,
                 "mapping family 255 is rejected");
}

void testAdmissionFieldOrder() {
  // Each of these headers would fail two checks; admission must report the
  // earlier field so the diagnostic names the first thing actually wrong.
  expectRejected(opusHead(1U, 2U, 312U, 48'000U, 0U, 1U, "NotOpus!"),
                 OpusAdmissionError::UnexpectedMagic,
                 "bad magic outranks a bad mapping family");
  expectRejected(opusHead(0U, 3U), OpusAdmissionError::UnsupportedVersion,
                 "bad version outranks a bad channel count");
  expectRejected(opusHead(1U, 0U, 0U),
                 OpusAdmissionError::UnsupportedChannelCount,
                 "bad channel count outranks a below-delay pre-skip");
  expectRejected(opusHead(1U, 2U, 65'535U, 48'000U, 0x0100U),
                 OpusAdmissionError::PreSkipExceedsMaximum,
                 "an out-of-range pre-skip outranks a nonzero output gain");
  expectRejected(opusHead(1U, 2U, 312U, 48'000U, 0x0100U, 1U),
                 OpusAdmissionError::NonzeroOutputGain,
                 "a nonzero output gain outranks a bad mapping family");
  // Size is checked before anything else, so a header that is otherwise
  // perfectly canonical but one byte short still reports the size.
  constexpr auto canonical = opusHead();
  expectRejected(std::span<const std::byte>(canonical).first(18U),
                 OpusAdmissionError::InvalidHeaderSize,
                 "size outranks every field check");
}

void testHeadTrimArithmetic() {
  // Headline case: pre-skip 312 is what every ffmpeg Opus mux writes, and
  // AudioToolbox has already eaten kOpusDecoderDelayFrames of it, so the trim
  // the pipeline still owes is 312 - 120 = 192 frames.
  static_assert(opusHeadTrimFrames(OpusConfiguration{312U, 2U, 48'000U}) ==
                    192U,
                "the ffmpeg pre-skip of 312 leaves exactly 192 frames to trim");
  static_assert(opusHeadTrimFrames(OpusConfiguration{120U, 2U, 48'000U}) == 0U,
                "a pre-skip equal to the decoder delay owes no further trim");
  static_assert(opusHeadTrimFrames(OpusConfiguration{121U, 2U, 48'000U}) == 1U,
                "one frame above the decoder delay owes exactly one frame");
  static_assert(opusHeadTrimFrames(OpusConfiguration{3'840U, 1U, 48'000U}) ==
                    3'720U,
                "the largest admitted pre-skip owes 3840 - 120 frames");
  static_assert(!opusHeadTrimFrames(OpusConfiguration{119U, 2U, 48'000U})
                     .has_value(),
                "a pre-skip below the decoder delay yields no trim at all");
  static_assert(
      !opusHeadTrimFrames(OpusConfiguration{0U, 2U, 48'000U}).has_value(),
      "a zero pre-skip yields no trim at all");

  const auto ffmpegTrim = opusHeadTrimFrames({312U, 2U, 48'000U});
  expect(ffmpegTrim == 192U,
         "runtime head trim for the canonical ffmpeg pre-skip is 192 frames");
  const auto boundaryTrim = opusHeadTrimFrames({120U, 2U, 48'000U});
  expect(boundaryTrim == 0U,
         "runtime head trim at the decoder delay boundary is zero");
  // Constructed directly: admission would already have rejected a pre-skip
  // this small, so this only proves the helper fails closed on a forged
  // configuration rather than underflowing to a huge unsigned trim.
  const OpusConfiguration forged{119U, 2U, 48'000U};
  expect(!opusHeadTrimFrames(forged).has_value(),
         "a forged sub-delay pre-skip yields nullopt, never an underflow");

  // The trim is monotone and never exceeds the admitted pre-skip window.
  for (std::uint32_t preSkip = kOpusDecoderDelayFrames; preSkip <= 3'840U;
       ++preSkip) {
    const auto trim = opusHeadTrimFrames(
        {static_cast<std::uint16_t>(preSkip), 2U, 48'000U});
    expect(trim && *trim == preSkip - kOpusDecoderDelayFrames,
           "head trim is exactly pre-skip minus the decoder delay throughout");
  }
  for (std::uint32_t preSkip = 0; preSkip < kOpusDecoderDelayFrames;
       ++preSkip) {
    expect(!opusHeadTrimFrames({static_cast<std::uint16_t>(preSkip), 2U,
                                48'000U})
                .has_value(),
           "every sub-delay pre-skip yields nullopt");
  }
}

// RFC 6716 section 3.1 table 2, re-derived here as frame durations rather than
// copied as frame counts: configs 0-11 are SILK-only NB/MB/WB at 10/20/40/60
// ms, 12-15 are Hybrid SWB/FB at 10/20 ms, and 16-31 are CELT-only
// NB/WB/SWB/FB at 2.5/5/10/20 ms. Tenths of a millisecond keep 2.5 ms exact.
constexpr std::array<std::uint16_t, 32> kConfigurationTenthMilliseconds{
    100, 200, 400, 600, // 0-3   SILK-only NB
    100, 200, 400, 600, // 4-7   SILK-only MB
    100, 200, 400, 600, // 8-11  SILK-only WB
    100, 200,           // 12-13 Hybrid SWB
    100, 200,           // 14-15 Hybrid FB
    25,  50,  100, 200, // 16-19 CELT-only NB
    25,  50,  100, 200, // 20-23 CELT-only WB
    25,  50,  100, 200, // 24-27 CELT-only SWB
    25,  50,  100, 200  // 28-31 CELT-only FB
};

[[nodiscard]] constexpr std::uint32_t
expectedConfigurationFrames(std::size_t configuration) noexcept {
  return static_cast<std::uint32_t>(
             kConfigurationTenthMilliseconds[configuration]) *
         kOpusOutputSampleRate / 10'000U;
}

// TOC byte: five configuration bits, one stereo bit, two frame-count code bits.
[[nodiscard]] constexpr std::byte tocByte(std::uint8_t configuration,
                                          bool stereo,
                                          std::uint8_t frameCountCode) noexcept {
  return static_cast<std::byte>(
      static_cast<std::uint8_t>((configuration & 0x1FU) << 3U) |
      static_cast<std::uint8_t>(stereo ? 0x04U : 0x00U) |
      static_cast<std::uint8_t>(frameCountCode & 0x03U));
}

void testPacketFrameCountCodesZeroToTwo() {
  // At 48 kHz, 2.5/5/10/20/40/60 ms are 120/240/480/960/1920/2880 frames.
  static_assert(expectedConfigurationFrames(16) == 120U);
  static_assert(expectedConfigurationFrames(17) == 240U);
  static_assert(expectedConfigurationFrames(0) == 480U);
  static_assert(expectedConfigurationFrames(1) == 960U);
  static_assert(expectedConfigurationFrames(2) == 1'920U);
  static_assert(expectedConfigurationFrames(3) == 2'880U);

  for (std::uint8_t configuration = 0; configuration < 32U; ++configuration) {
    const std::uint32_t single = expectedConfigurationFrames(configuration);
    for (const bool stereo : {false, true}) {
      const std::array<std::byte, 1> code0{tocByte(configuration, stereo, 0U)};
      expect(opusPacketFrameCount(code0) == single,
             "frame-count code 0 yields exactly one frame of the config");

      const std::array<std::byte, 1> code1{tocByte(configuration, stereo, 1U)};
      expect(opusPacketFrameCount(code1) == 2U * single,
             "frame-count code 1 doubles the configuration frame count");
      const std::array<std::byte, 1> code2{tocByte(configuration, stereo, 2U)};
      expect(opusPacketFrameCount(code2) == 2U * single,
             "frame-count code 2 doubles the configuration frame count");
    }
  }

  // Spot-checked absolutes so the loop above cannot pass vacuously.
  constexpr std::array<std::byte, 1> silkNb60{tocByte(3U, true, 0U)};
  expect(opusPacketFrameCount(silkNb60) == 2'880U,
         "config 3 is a 60 ms SILK NB packet of 2880 frames");
  constexpr std::array<std::byte, 1> celtFb2p5{tocByte(28U, false, 0U)};
  expect(opusPacketFrameCount(celtFb2p5) == 120U,
         "config 28 is a 2.5 ms CELT FB packet of 120 frames");
  constexpr std::array<std::byte, 1> silkNb60Doubled{tocByte(3U, true, 1U)};
  expect(opusPacketFrameCount(silkNb60Doubled) == 5'760U,
         "two 60 ms frames are exactly the 120 ms packet ceiling");
}

void testPacketFrameCountCodeThree() {
  // Code 3 reads the frame count from the low six bits of byte 1.
  constexpr std::array<std::byte, 2> celtNb48{tocByte(16U, false, 3U),
                                              std::byte{48}};
  expect(opusPacketFrameCount(celtNb48) == 5'760U,
         "48 frames of 2.5 ms is the admitted 120 ms ceiling");
  constexpr std::array<std::byte, 2> celtNb49{tocByte(16U, false, 3U),
                                              std::byte{49}};
  expect(!opusPacketFrameCount(celtNb49).has_value(),
         "49 frames of 2.5 ms exceeds 120 ms and is refused");
  constexpr std::array<std::byte, 2> celtNb1{tocByte(16U, false, 3U),
                                             std::byte{1}};
  expect(opusPacketFrameCount(celtNb1) == 120U,
         "a code-3 count of one is a single 2.5 ms frame");

  constexpr std::array<std::byte, 2> silkNb60Twice{tocByte(3U, true, 3U),
                                                   std::byte{2}};
  expect(opusPacketFrameCount(silkNb60Twice) == 5'760U,
         "two 60 ms frames under code 3 are exactly 120 ms and admitted");
  constexpr std::array<std::byte, 2> silkNb60Thrice{tocByte(3U, true, 3U),
                                                    std::byte{3}};
  expect(!opusPacketFrameCount(silkNb60Thrice).has_value(),
         "three 60 ms frames are 180 ms and are refused");

  constexpr std::array<std::byte, 2> zeroCount{tocByte(16U, false, 3U),
                                               std::byte{0}};
  expect(!opusPacketFrameCount(zeroCount).has_value(),
         "a code-3 frame count of zero is refused");
  constexpr std::array<std::byte, 1> truncated{tocByte(16U, false, 3U)};
  expect(!opusPacketFrameCount(truncated).has_value(),
         "code 3 with no second byte is refused rather than read past the end");
  constexpr std::array<std::byte, 0> emptyPacket{};
  expect(!opusPacketFrameCount(emptyPacket).has_value(),
         "an empty packet has no TOC byte and is refused");

  // Byte 1's two high bits are the VBR and padding flags; the frame count is
  // only the low six, so setting them must not change the answer.
  for (std::uint8_t count = 1U; count <= 63U; ++count) {
    const std::array<std::byte, 2> plain{tocByte(16U, false, 3U),
                                         static_cast<std::byte>(count)};
    const std::array<std::byte, 2> flagged{
        tocByte(16U, false, 3U),
        static_cast<std::byte>(static_cast<std::uint8_t>(0xC0U | count))};
    expect(opusPacketFrameCount(plain) == opusPacketFrameCount(flagged),
           "the VBR and padding flags above the count bits are ignored");
    const auto parsed = opusPacketFrameCount(plain);
    const std::uint32_t product = static_cast<std::uint32_t>(count) * 120U;
    if (product <= kMaximumOpusPacketFrames) {
      expect(parsed == product,
             "a code-3 count within the ceiling multiplies out exactly");
    } else {
      expect(!parsed.has_value(),
             "a code-3 count beyond the ceiling is refused, never wrapped");
    }
  }
  // A flags-only byte still decodes to a zero count and is refused.
  constexpr std::array<std::byte, 2> flagsOnly{tocByte(16U, false, 3U),
                                               std::byte{0xC0}};
  expect(!opusPacketFrameCount(flagsOnly).has_value(),
         "high flag bits alone do not manufacture a nonzero frame count");

  // Nothing anywhere in the code-3 space may exceed the 120 ms ceiling.
  for (std::uint8_t configuration = 0; configuration < 32U; ++configuration) {
    for (std::uint8_t count = 0; count < 64U; ++count) {
      const std::array<std::byte, 2> packet{tocByte(configuration, false, 3U),
                                            static_cast<std::byte>(count)};
      const auto parsed = opusPacketFrameCount(packet);
      const std::uint32_t product =
          static_cast<std::uint32_t>(count) *
          expectedConfigurationFrames(configuration);
      if (count != 0U && product <= kMaximumOpusPacketFrames) {
        expect(parsed == product, "every admitted code-3 packet is exact");
      } else {
        expect(!parsed.has_value(),
               "no code-3 packet above 120 ms or with a zero count is "
               "admitted");
      }
      expect(!parsed || *parsed <= kMaximumOpusPacketFrames,
             "no packet frame count exceeds the 120 ms ceiling");
    }
  }
}

void testDiscardPaddingFrames() {
  // Headline case: 13,500,000 ns is the DiscardPadding every ffmpeg Opus mux
  // writes on the final block, and it is exactly 648 frames at 48 kHz.
  expect(opusFramesFromNanoseconds(13'500'000) == 648U,
         "the canonical ffmpeg DiscardPadding of 13.5 ms is 648 frames");

  expect(opusFramesFromNanoseconds(0) == 0U,
         "zero DiscardPadding trims nothing");
  expect(opusFramesFromNanoseconds(1'000'000) == 48U,
         "one millisecond is exactly 48 frames");
  expect(opusFramesFromNanoseconds(120'000'000) == 5'760U,
         "the 120 ms ceiling is admitted as exactly 5760 frames");
  expect(!opusFramesFromNanoseconds(120'020'833).has_value(),
         "one frame past the 120 ms ceiling is refused");
  expect(!opusFramesFromNanoseconds(120'062'500).has_value(),
         "an exact multiple past the ceiling is still refused");

  // Nanoseconds cannot express every frame count: gcd(48000, 1e9) = 16000, so
  // only multiples of THREE frames land on an integer nanosecond. Demanding an
  // exact multiple would reject two thirds of real files, so a stated value is
  // resolved to the nearest whole frame -- unique, because one nanosecond is
  // 1/20833 of a frame -- with the residual bounded at one nanosecond.
  expect(opusFramesFromNanoseconds(62'500) == 3U,
         "3 frames is exactly representable and resolves exactly");
  expect(opusFramesFromNanoseconds(20'833) == 1U,
         "the muxer's rounded-down single frame resolves back to 1");
  expect(opusFramesFromNanoseconds(20'834) == 1U,
         "the muxer's rounded-up single frame also resolves back to 1");
  expect(opusFramesFromNanoseconds(41'667) == 2U,
         "two frames, which no integer nanosecond expresses exactly");
  // Measured on a real file: a 4.0007 s ffmpeg clip carries 614 frames of
  // DiscardPadding, written as 12,791,667 ns -- not a multiple of 3 frames.
  expect(opusFramesFromNanoseconds(12'791'667) == 614U,
         "a real non-multiple-of-three padding resolves to its exact frame "
         "count");

  // The residual bound is what keeps this exact rather than merely tolerant:
  // a value more than one nanosecond from any frame boundary was never a
  // rounded frame count and is refused outright.
  expect(opusFramesFromNanoseconds(13'500'001) == 648U,
         "one nanosecond off a frame boundary is still that frame count");
  expect(!opusFramesFromNanoseconds(13'500'002).has_value(),
         "two nanoseconds off a frame boundary is refused, not snapped");
  expect(!opusFramesFromNanoseconds(10'000).has_value(),
         "a value halfway between two frames is refused");
  // A nanosecond is 1/20833 of a frame, so it IS the zero frame boundary to
  // within the residual bound and resolves to zero rather than being refused.
  expect(opusFramesFromNanoseconds(1) == 0U,
         "a single nanosecond resolves to zero frames");
  expect(!opusFramesFromNanoseconds(2).has_value(),
         "two nanoseconds is past the residual bound around zero");

  expect(!opusFramesFromNanoseconds(-1).has_value(),
         "a small negative DiscardPadding is refused");
  expect(!opusFramesFromNanoseconds(-13'500'000).has_value(),
         "a negative padding asking for added silence is refused");
  expect(!opusFramesFromNanoseconds(std::numeric_limits<std::int64_t>::min())
              .has_value(),
         "INT64_MIN is refused without negating into overflow");

  // A naive nanoseconds * 48000 would wrap here; the magnitude is bounded
  // BEFORE the product is formed, so the result is nullopt and no unsigned
  // overflow occurs.
  expect(!opusFramesFromNanoseconds(std::numeric_limits<std::int64_t>::max())
              .has_value(),
         "INT64_MAX is refused rather than wrapping to a plausible count");
  expect(!opusFramesFromNanoseconds(1'000'000'000'000'000).has_value(),
         "a nanosecond value far past any packet is refused");

  // Exhaustive round trip over the whole admitted window: every frame count
  // the muxer could state, written the way a muxer writes it (rounded to the
  // nearest nanosecond, either direction), must come back as itself.
  for (std::uint32_t frames = 0; frames <= kMaximumOpusPacketFrames; ++frames) {
    const std::uint64_t product =
        static_cast<std::uint64_t>(frames) * 1'000'000'000U;
    const auto down =
        static_cast<std::int64_t>(product / kOpusOutputSampleRate);
    const auto up = static_cast<std::int64_t>(
        (product + kOpusOutputSampleRate - 1U) / kOpusOutputSampleRate);
    expect(opusFramesFromNanoseconds(down) == frames,
           "a rounded-down frame count round-trips exactly");
    expect(opusFramesFromNanoseconds(up) == frames,
           "a rounded-up frame count round-trips exactly");
    if (down > 1) {
      expect(!opusFramesFromNanoseconds(down - 2).has_value(),
             "two nanoseconds below a frame boundary is refused");
    }
  }
}

} // namespace

int main() {
  static_assert(kOpusIdentificationHeaderBytes == 19U);
  static_assert(kOpusOutputSampleRate == 48'000U);
  static_assert(kOpusDecoderDelayFrames == 120U);
  static_assert(kMaximumOpusPacketFrames == 5'760U);
  static_assert(kMaximumOpusFramesPerPacket == 48U);

  // The bounded head-trim and tail-trim arithmetic, proven at compile time.
  static_assert(opusHeadTrimFrames(OpusConfiguration{312U, 2U, 48'000U}) ==
                    312U - kOpusDecoderDelayFrames,
                "312 - 120 = 192 frames of head trim");
  static_assert(kMaximumOpusPacketFrames ==
                    kMaximumOpusFramesPerPacket * (kOpusOutputSampleRate / 400U),
                "48 frames of 2.5 ms is exactly the 120 ms packet ceiling");
  static_assert(std::uint64_t{kMaximumOpusPacketFrames} * 1'000'000'000U /
                        kOpusOutputSampleRate ==
                    120'000'000U,
                "the tail-trim ceiling is exactly 120 ms of nanoseconds");
  static_assert(1'000'000'000U % kOpusOutputSampleRate != 0U,
                "one 48 kHz frame is not a whole number of nanoseconds, which "
                "is why the tail trim is resolved to the nearest frame with a "
                "bounded residual rather than demanded exact");

  testCanonicalAdmission();
  testAdmissionRejectionReasons();
  testAdmissionFieldOrder();
  testHeadTrimArithmetic();
  testPacketFrameCountCodesZeroToTwo();
  testPacketFrameCountCodeThree();
  testDiscardPaddingFrames();

  if (failures != 0) {
    std::cerr << failures << " Matroska Opus test(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "Matroska Opus admission, head-trim, packet-duration, and "
               "discard-padding tests passed\n";
  return EXIT_SUCCESS;
}
