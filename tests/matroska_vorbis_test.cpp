#include "media/matroska_vorbis.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <span>
#include <vector>

#include "support/expect.hpp"

namespace {

using namespace wam::media::matroska;


// The identification header of fixtures/vp8_vorbis.webm, byte for byte as
// ffmpeg muxed it: 2 channels, 44100 Hz (0x0000AC44), packed block sizes 0xBB
// (2048/2048), framing bit set.
constexpr std::array<std::uint8_t, kVorbisIdentificationHeaderBytes>
    kRealIdentificationHeader{
        0x01, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73, 0x00, 0x00, 0x00,
        0x00, 0x02, 0x44, 0xAC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xBB, 0x01};

[[nodiscard]] std::vector<std::byte>
identificationHeader(std::uint8_t channels = 2U, std::uint32_t rate = 44'100U,
                     std::uint8_t packedBlockSizes = 0xBBU,
                     std::uint8_t framing = 0x01U, std::uint32_t version = 0U,
                     std::uint8_t type = 1U, const char *magic = "vorbis") {
  std::vector<std::byte> header(kVorbisIdentificationHeaderBytes,
                                std::byte{0});
  header[0] = static_cast<std::byte>(type);
  for (std::size_t index = 0; index < 6U; ++index) {
    header[index + 1U] =
        static_cast<std::byte>(static_cast<std::uint8_t>(magic[index]));
  }
  for (std::size_t index = 0; index < 4U; ++index) {
    header[7U + index] =
        static_cast<std::byte>((version >> (8U * index)) & 0xFFU);
  }
  header[11] = static_cast<std::byte>(channels);
  for (std::size_t index = 0; index < 4U; ++index) {
    header[12U + index] =
        static_cast<std::byte>((rate >> (8U * index)) & 0xFFU);
  }
  header[28] = static_cast<std::byte>(packedBlockSizes);
  header[29] = static_cast<std::byte>(framing);
  return header;
}

[[nodiscard]] std::vector<std::byte> namedHeader(std::uint8_t type,
                                                 std::size_t size,
                                                 const char *magic = "vorbis") {
  std::vector<std::byte> header(size, std::byte{0x5A});
  header[0] = static_cast<std::byte>(type);
  for (std::size_t index = 0; index < 6U && index + 1U < size; ++index) {
    header[index + 1U] =
        static_cast<std::byte>(static_cast<std::uint8_t>(magic[index]));
  }
  return header;
}

// Packs three headers the way Matroska's A_VORBIS CodecPrivate does: a count
// byte (headers - 1), Xiph-lacing lengths for all but the last, then the
// payloads. The last length is implied by the total size.
[[nodiscard]] std::vector<std::byte>
codecPrivate(std::span<const std::byte> identification,
             std::span<const std::byte> comment,
             std::span<const std::byte> setup, std::uint8_t countByte = 2U) {
  std::vector<std::byte> blob;
  blob.push_back(static_cast<std::byte>(countByte));
  const auto pushLacing = [&blob](std::size_t length) {
    while (length >= 255U) {
      blob.push_back(static_cast<std::byte>(255));
      length -= 255U;
    }
    blob.push_back(static_cast<std::byte>(length));
  };
  pushLacing(identification.size());
  pushLacing(comment.size());
  blob.insert(blob.end(), identification.begin(), identification.end());
  blob.insert(blob.end(), comment.begin(), comment.end());
  blob.insert(blob.end(), setup.begin(), setup.end());
  return blob;
}

[[nodiscard]] std::vector<std::byte> canonicalCodecPrivate() {
  return codecPrivate(identificationHeader(), namedHeader(3U, 16U),
                      namedHeader(5U, 3247U));
}

void testRealFixtureHeader() {
  std::vector<std::byte> identification;
  identification.reserve(kRealIdentificationHeader.size());
  for (const std::uint8_t value : kRealIdentificationHeader) {
    identification.push_back(static_cast<std::byte>(value));
  }
  // The real fixture's lacing prefix is 02 1E 10: two stated lengths, 30 and
  // 16, with the 3247-byte setup header implied.
  const std::vector<std::byte> blob = codecPrivate(
      identification, namedHeader(3U, 16U), namedHeader(5U, 3247U));
  expect(blob.size() == 3296U,
         "the real fixture's CodecPrivate is 3296 bytes");
  expect(static_cast<std::uint8_t>(blob[0]) == 0x02U &&
             static_cast<std::uint8_t>(blob[1]) == 0x1EU &&
             static_cast<std::uint8_t>(blob[2]) == 0x10U,
         "the real fixture's lacing prefix is 02 1E 10");

  const VorbisAdmission admission = parseVorbisCodecPrivate(blob);
  expect(admission.admitted(), "the real ffmpeg CodecPrivate is admitted");
  if (!admission.admitted()) {
    return;
  }
  const VorbisConfiguration &configuration = *admission.configuration;
  expect(configuration.channelCount == 2U, "real header states 2 channels");
  expect(configuration.sampleRate == 44'100U, "real header states 44100 Hz");
  expect(configuration.blockSize0 == 2048U && configuration.blockSize1 == 2048U,
         "real header states 2048/2048 block sizes");
  expect(configuration.samplesPerAccessUnit() == 1024U,
         "2048-frame blocks decode 1024 frames per packet");
  expect(vorbisDecoderLeadInFrames(configuration) == 1024U,
         "the Vorbis decoder lead-in is one access unit");
}

void testCanonicalAdmission() {
  const VorbisAdmission admission =
      parseVorbisCodecPrivate(canonicalCodecPrivate());
  expect(admission.admitted(), "canonical CodecPrivate is admitted");
  expect(admission.error == VorbisAdmissionError::None,
         "canonical CodecPrivate reports no error");
}

void testMalformedInputs() {
  const auto reason = [](std::vector<std::byte> blob) {
    return parseVorbisCodecPrivate(blob).error;
  };

  expect(reason({}) == VorbisAdmissionError::InvalidCodecPrivateSize,
         "an empty CodecPrivate is refused");
  expect(reason(std::vector<std::byte>(32U, std::byte{0})) ==
             VorbisAdmissionError::InvalidCodecPrivateSize,
         "a CodecPrivate shorter than count + lacing + 30 bytes is refused");

  expect(reason(codecPrivate(identificationHeader(), namedHeader(3U, 16U),
                             namedHeader(5U, 64U), 1U)) ==
             VorbisAdmissionError::UnexpectedPacketCount,
         "a packet count other than three is refused");
  expect(reason(codecPrivate(identificationHeader(), namedHeader(3U, 16U),
                             namedHeader(5U, 64U), 3U)) ==
             VorbisAdmissionError::UnexpectedPacketCount,
         "a four-packet CodecPrivate is refused");

  // A lacing run that never terminates: every byte is 255, so the accumulator
  // walks off the end of the blob.
  {
    std::vector<std::byte> blob(200U, std::byte{0xFF});
    blob[0] = std::byte{0x02};
    expect(reason(blob) == VorbisAdmissionError::MalformedLacing,
           "an unterminated 255-run is refused");
  }
  // Lacing that claims more bytes than the blob holds.
  {
    std::vector<std::byte> blob = canonicalCodecPrivate();
    blob[1] = std::byte{0xFE};
    blob[2] = std::byte{0xFE};
    const VorbisAdmissionError error = reason(blob);
    expect(error == VorbisAdmissionError::InvalidIdentificationHeaderSize ||
               error == VorbisAdmissionError::MalformedLacing ||
               error == VorbisAdmissionError::TruncatedHeader,
           "lacing that overruns the blob is refused");
  }
  // Lacing that accounts for the whole blob leaves no setup header.
  {
    const std::vector<std::byte> identification = identificationHeader();
    std::vector<std::byte> blob;
    blob.push_back(std::byte{0x02});
    blob.push_back(static_cast<std::byte>(identification.size()));
    blob.push_back(std::byte{0});
    blob.insert(blob.end(), identification.begin(), identification.end());
    expect(parseVorbisCodecPrivate(blob).error ==
               VorbisAdmissionError::TruncatedHeader,
           "a CodecPrivate with an empty setup header is refused");
  }

  expect(reason(codecPrivate(identificationHeader(), namedHeader(3U, 16U),
                             namedHeader(5U, 64U))) ==
             VorbisAdmissionError::None,
         "a short but well-formed setup header is admitted");

  // Wrong sizes and magics, one deviation at a time.
  {
    std::vector<std::byte> shortIdentification = identificationHeader();
    shortIdentification.pop_back();
    expect(reason(codecPrivate(shortIdentification, namedHeader(3U, 16U),
                               namedHeader(5U, 64U))) ==
               VorbisAdmissionError::InvalidIdentificationHeaderSize,
           "a 29-byte identification header is refused");
  }
  expect(reason(codecPrivate(identificationHeader(2U, 44'100U, 0xBBU, 0x01U,
                                                  0U, 1U, "vorbiZ"),
                             namedHeader(3U, 16U), namedHeader(5U, 64U))) ==
             VorbisAdmissionError::UnexpectedMagic,
         "a misspelled identification magic is refused");
  expect(reason(codecPrivate(identificationHeader(), namedHeader(9U, 16U),
                             namedHeader(5U, 64U))) ==
             VorbisAdmissionError::UnexpectedMagic,
         "a comment header with the wrong type byte is refused");
  expect(reason(codecPrivate(identificationHeader(), namedHeader(3U, 16U),
                             namedHeader(1U, 64U))) ==
             VorbisAdmissionError::UnexpectedMagic,
         "a setup header with the wrong type byte is refused");
  expect(reason(codecPrivate(identificationHeader(), namedHeader(3U, 16U),
                             namedHeader(5U, 64U, "vorbiZ"))) ==
             VorbisAdmissionError::UnexpectedMagic,
         "a setup header with the wrong magic is refused");

  expect(reason(codecPrivate(identificationHeader(2U, 44'100U, 0xBBU, 0x01U,
                                                  1U),
                             namedHeader(3U, 16U), namedHeader(5U, 64U))) ==
             VorbisAdmissionError::UnsupportedVersion,
         "a nonzero Vorbis version is refused");
  expect(reason(codecPrivate(identificationHeader(0U), namedHeader(3U, 16U),
                             namedHeader(5U, 64U))) ==
             VorbisAdmissionError::UnsupportedChannelCount,
         "a zero channel count is refused");
  expect(reason(codecPrivate(identificationHeader(3U), namedHeader(3U, 16U),
                             namedHeader(5U, 64U))) ==
             VorbisAdmissionError::UnsupportedChannelCount,
         "a 3-channel Vorbis track is refused");
  expect(reason(codecPrivate(identificationHeader(2U, 0U), namedHeader(3U, 16U),
                             namedHeader(5U, 64U))) ==
             VorbisAdmissionError::UnsupportedSampleRate,
         "a zero sample rate is refused");
  expect(reason(codecPrivate(identificationHeader(2U, 44'100U, 0xBBU, 0x00U),
                             namedHeader(3U, 16U), namedHeader(5U, 64U))) ==
             VorbisAdmissionError::MissingFramingBit,
         "a cleared framing bit is refused");
}

void testBlockSizeGate() {
  const auto blockSizes = [](std::uint8_t packed) {
    return parseVorbisCodecPrivate(
               codecPrivate(identificationHeader(2U, 44'100U, packed),
                            namedHeader(3U, 16U), namedHeader(5U, 64U)))
        .error;
  };

  // 0xBB = 2048/2048, the shape ffmpeg's native encoder emits.
  expect(blockSizes(0xBBU) == VorbisAdmissionError::None,
         "equal 2048-frame block sizes are admitted");
  // 0x66 = 64/64, the smallest legal pair.
  expect(blockSizes(0x66U) == VorbisAdmissionError::None,
         "equal 64-frame block sizes are admitted");
  // 0xDD = 8192/8192, the largest legal pair.
  expect(blockSizes(0xDDU) == VorbisAdmissionError::None,
         "equal 8192-frame block sizes are admitted");

  // 0xB8 = blocksize0 256, blocksize1 2048 -- exactly what reference libvorbis
  // emits at every quality setting. This is a DELIBERATE refusal, not a parse
  // failure: variable packet durations cannot be placed on this demuxer's
  // constant frames-per-access-unit grid, so the file falls back to mpv.
  expect(blockSizes(0xB8U) == VorbisAdmissionError::VariableBlockSize,
         "libvorbis' 256/2048 block sizes are refused as variable, not "
         "misparsed");

  // 0x55 = 32/32, below the 64-frame floor.
  expect(blockSizes(0x55U) == VorbisAdmissionError::InvalidBlockSize,
         "a 32-frame block size is refused");
  // 0xEE = 16384/16384, above the 8192 ceiling.
  expect(blockSizes(0xEEU) == VorbisAdmissionError::InvalidBlockSize,
         "a 16384-frame block size is refused");
  // 0x8B = blocksize0 2048, blocksize1 256 -- the spec requires bs0 <= bs1.
  expect(blockSizes(0x8BU) == VorbisAdmissionError::InvalidBlockSize,
         "blocksize0 larger than blocksize1 is refused");
}

// The identity the whole Vorbis trim rests on, checked against the numbers
// measured from fixtures/vp8_vorbis.webm and from ffmpeg's own decode of it.
void testTrimArithmetic() {
  constexpr std::uint64_t kPackets = 260U;
  constexpr std::uint64_t kSamplesPerAccessUnit = 1024U;
  constexpr std::uint64_t kDiscardPaddingFrames = 576U;
  constexpr std::uint64_t kFfmpegDecodedFrames = 264'640U;

  // The decoder emits one access unit fewer than the packets declare, because
  // packet zero decodes to no samples.
  constexpr std::uint64_t decoded =
      kPackets * kSamplesPerAccessUnit - kSamplesPerAccessUnit;
  static_assert(decoded == 265'216U,
                "260 packets of 1024 frames decode to 259 * 1024");

  // Head trim is zero: the lead-in and the grid offset are the same one access
  // unit, so they cancel.
  constexpr std::uint64_t headTrim =
      kSamplesPerAccessUnit - kSamplesPerAccessUnit;
  static_assert(headTrim == 0U, "Vorbis owes no head trim");

  constexpr std::uint64_t published = decoded - headTrim - kDiscardPaddingFrames;
  static_assert(published == kFfmpegDecodedFrames,
                "the published frame count is exactly ffmpeg's own decode");
  expect(published == kFfmpegDecodedFrames,
         "260 * 1024 - 1024 - 576 == 264640 frames");
}

void testDiscardPaddingFrames() {
  // The real fixture's DiscardPadding, read from the last BlockGroup.
  const auto frames = vorbisFramesFromNanoseconds(13'061'224, 44'100U);
  expect(frames.has_value() && *frames == 576U,
         "13,061,224 ns resolves to exactly 576 frames at 44.1 kHz");

  // The rate parameter is load-bearing rather than decorative: the very same
  // nanosecond count is refused at 48 kHz, because 13,061,224 ns is a rounded
  // frame count at 44.1 kHz and at no other rate. Reading a 44.1 kHz track's
  // padding on the 48 kHz assumption would have silently mis-trimmed by 51
  // frames; instead it fails closed.
  expect(!vorbisFramesFromNanoseconds(13'061'224, 48'000U).has_value(),
         "a 44.1 kHz padding value is refused when read at 48 kHz");

  // 13,500,000 ns is the 48 kHz shape of the same idea (648 frames), and it is
  // in turn refused at 44.1 kHz.
  const auto at48k = vorbisFramesFromNanoseconds(13'500'000, 48'000U);
  expect(at48k.has_value() && *at48k == 648U,
         "13,500,000 ns resolves to exactly 648 frames at 48 kHz");
  expect(!vorbisFramesFromNanoseconds(13'500'000, 44'100U).has_value(),
         "a 48 kHz padding value is refused when read at 44.1 kHz");

  expect(vorbisFramesFromNanoseconds(0, 44'100U).value_or(1U) == 0U,
         "zero nanoseconds is zero frames");
  expect(!vorbisFramesFromNanoseconds(-1, 44'100U).has_value(),
         "negative padding is refused rather than treated as zero");
  expect(!vorbisFramesFromNanoseconds(13'061'224, 0U).has_value(),
         "a zero sample rate is refused");
  // Beyond one maximal packet.
  expect(!vorbisFramesFromNanoseconds(1'000'000'000, 44'100U).has_value(),
         "a full second of padding exceeds the packet ceiling");

  // A value that was never a rounded frame count is refused, not snapped: one
  // microsecond off 576 frames is ~44 frames' worth of residual.
  expect(!vorbisFramesFromNanoseconds(13'061'224 + 500'000, 44'100U)
              .has_value(),
         "a half-millisecond off-grid padding is refused");
}

} // namespace

int main() {
  static_assert(kVorbisHeaderCount == 3U,
                "a Vorbis CodecPrivate carries exactly three headers");
  static_assert(kMaximumVorbisPacketFrames == kMaximumVorbisBlockSize / 2U,
                "the largest packet is half the largest block");
  static_assert(kVorbisAudioFormatTag == 0x766F7262U,
                "the AudioToolbox Vorbis decoder is registered as 'vorb'");
  static_assert(1'000'000'000U % 44'100U != 0U,
                "one 44.1 kHz frame is not a whole number of nanoseconds, "
                "which is why the tail trim is resolved to the nearest frame "
                "with a bounded residual rather than demanded exact");

  testRealFixtureHeader();
  testCanonicalAdmission();
  testMalformedInputs();
  testBlockSizeGate();
  testTrimArithmetic();
  testDiscardPaddingFrames();

  if (failures != 0) {
    std::cerr << failures << " Matroska Vorbis test(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "Matroska Vorbis CodecPrivate, block-size gate, trim and "
               "discard-padding tests passed\n";
  return EXIT_SUCCESS;
}
