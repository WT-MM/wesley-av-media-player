#include "media/matroska_flac.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <span>
#include <vector>

namespace {

using namespace wam::media::matroska;

int failures = 0;

void expect(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

// The CodecPrivate of scratchpad/fixtures/sw/c_flac.mkv, byte for byte as
// ffmpeg muxed it: 'fLaC', then one metadata block flagged last, type 0,
// length 34, whose STREAMINFO says 4608/4608 block sizes, 44100 Hz, 2
// channels, 24 bits and 264600 total samples.
constexpr std::array<std::uint8_t, 42> kRealCodecPrivate{
    0x66, 0x4C, 0x61, 0x43, 0x80, 0x00, 0x00, 0x22, 0x12, 0x00, 0x12,
    0x00, 0x00, 0x0A, 0x6C, 0x00, 0x1B, 0x3B, 0x0A, 0xC4, 0x43, 0x70,
    0x00, 0x04, 0x09, 0x98, 0x6B, 0x84, 0xA2, 0x62, 0xB1, 0xA7, 0x47,
    0xD9, 0xC4, 0x5B, 0x45, 0x0C, 0xC3, 0x24, 0x87, 0xD2};

[[nodiscard]] std::vector<std::byte> realCodecPrivate() {
  std::vector<std::byte> bytes;
  bytes.reserve(kRealCodecPrivate.size());
  for (const std::uint8_t value : kRealCodecPrivate) {
    bytes.push_back(static_cast<std::byte>(value));
  }
  return bytes;
}

void testRealFixture() {
  const auto bytes = realCodecPrivate();
  const FlacAdmission admission = parseFlacCodecPrivate(bytes);
  expect(admission.admitted(), "real ffmpeg FLAC CodecPrivate is admitted");
  if (!admission.admitted()) {
    return;
  }
  const FlacConfiguration &configuration = *admission.configuration;
  expect(configuration.sampleRate == 44'100U, "STREAMINFO states 44100 Hz");
  expect(configuration.channelCount == 2U, "STREAMINFO states 2 channels");
  expect(configuration.bitsPerSample == 24U, "STREAMINFO states 24 bits");
  expect(configuration.blockSize == 4'608U, "STREAMINFO states 4608 frames");
  // THE number that makes FLAC the one codec here needing no trim arithmetic:
  // it is also exactly ffmpeg's own decoded frame count for this track.
  expect(configuration.totalSamples == 264'600U,
         "STREAMINFO states 264600 total samples, i.e. 6.000000 s at 44.1 kHz");
  expect(configuration.totalSamples * 1U == 6U * 44'100U,
         "264600 samples at 44100 Hz is exactly six seconds");
}

// The cookie is the ISO-BMFF dfLa box Apple's own FLAC parser emits, and its
// exact bytes matter: three plausible repackings are refused by the decoder.
void testMagicCookie() {
  const auto bytes = realCodecPrivate();
  const auto cookie = buildFlacMagicCookie(bytes);
  expect(cookie.has_value(), "a cookie is built from the real CodecPrivate");
  if (!cookie) {
    return;
  }
  const std::span<const std::byte> view = cookie->view();
  expect(view.size() == kFlacMagicCookieBytes, "the cookie is 50 bytes");
  const auto at = [&view](std::size_t index) {
    return std::to_integer<std::uint8_t>(view[index]);
  };
  expect(at(0) == 0x00 && at(1) == 0x00 && at(2) == 0x00 && at(3) == 0x32,
         "the box states its own 50-byte size, big-endian");
  expect(at(4) == 'd' && at(5) == 'f' && at(6) == 'L' && at(7) == 'a',
         "the box type is dfLa");
  expect(at(8) == 0 && at(9) == 0 && at(10) == 0 && at(11) == 0,
         "FullBox version and flags are zero");
  expect(at(12) == 0x80, "STREAMINFO is flagged as the last metadata block");
  expect(at(13) == 0 && at(14) == 0 && at(15) == 0x22,
         "the metadata block length is 34");
  for (std::size_t index = 0; index < kFlacStreamInfoBytes; ++index) {
    if (at(16U + index) != kRealCodecPrivate[8U + index]) {
      expect(false, "the STREAMINFO payload is copied verbatim");
      break;
    }
  }
}

// A CodecPrivate carrying more than STREAMINFO must still produce the same
// fixed 50-byte cookie, with the last-block flag SET even though the file's
// own STREAMINFO header did not carry it. This is what keeps a multi-megabyte
// PICTURE block out of the pipeline's configuration budget.
void testCookieDropsExtraBlocks() {
  std::vector<std::byte> bytes;
  for (std::size_t index = 0; index < 8U + kFlacStreamInfoBytes; ++index) {
    bytes.push_back(static_cast<std::byte>(kRealCodecPrivate[index]));
  }
  bytes[4] = std::byte{0x00}; // STREAMINFO is no longer the last block
  // A 5-byte VORBIS_COMMENT-shaped block, flagged last.
  bytes.push_back(std::byte{0x84});
  bytes.push_back(std::byte{0x00});
  bytes.push_back(std::byte{0x00});
  bytes.push_back(std::byte{0x05});
  for (int index = 0; index < 5; ++index) {
    bytes.push_back(std::byte{0x00});
  }
  const FlacAdmission admission = parseFlacCodecPrivate(bytes);
  expect(admission.admitted(),
         "a CodecPrivate with a trailing metadata block is admitted");
  const auto cookie = buildFlacMagicCookie(bytes);
  expect(cookie.has_value(), "a cookie is built from it");
  if (cookie) {
    expect(cookie->view().size() == kFlacMagicCookieBytes,
           "the cookie stays 50 bytes regardless of the other blocks");
    expect(std::to_integer<std::uint8_t>(cookie->view()[12]) == 0x80,
           "the emitted STREAMINFO header is flagged last even though the "
           "file's was not");
  }
}

void testMalformedInputs() {
  const auto real = realCodecPrivate();
  expect(parseFlacCodecPrivate({}).error ==
             FlacAdmissionError::InvalidCodecPrivateSize,
         "an empty CodecPrivate is refused");
  {
    auto bytes = real;
    bytes.resize(41);
    expect(parseFlacCodecPrivate(bytes).error ==
               FlacAdmissionError::InvalidCodecPrivateSize,
           "a blob too short to hold marker, header and STREAMINFO is refused");
  }
  {
    auto bytes = real;
    bytes[0] = std::byte{'g'};
    expect(parseFlacCodecPrivate(bytes).error ==
               FlacAdmissionError::UnexpectedMagic,
           "a wrong stream marker is refused");
  }
  {
    // The chain must terminate exactly at the end of the blob.
    auto bytes = real;
    bytes.push_back(std::byte{0x00});
    expect(parseFlacCodecPrivate(bytes).error ==
               FlacAdmissionError::MalformedMetadataBlocks,
           "trailing bytes after the last metadata block are refused");
  }
  {
    auto bytes = real;
    bytes[4] = std::byte{0x00}; // never flagged last
    expect(parseFlacCodecPrivate(bytes).error ==
               FlacAdmissionError::MalformedMetadataBlocks,
           "a chain with no last-block flag is refused");
  }
  {
    auto bytes = real;
    bytes[7] = std::byte{0x20}; // STREAMINFO length 32, not 34
    expect(parseFlacCodecPrivate(bytes).error ==
               FlacAdmissionError::MalformedMetadataBlocks,
           "a STREAMINFO of the wrong length is refused");
  }
  {
    auto bytes = real;
    bytes[4] = std::byte{0x81}; // type 1 (PADDING), so no STREAMINFO at all
    expect(parseFlacCodecPrivate(bytes).error ==
               FlacAdmissionError::MissingStreamInfo,
           "a CodecPrivate with no STREAMINFO is refused");
  }
  {
    auto bytes = real;
    // Total samples zero: the encoder did not know the length, so there is no
    // exact duration and no tail to stop at.
    bytes[8U + 13U] = std::byte{0x00};
    bytes[8U + 14U] = std::byte{0x00};
    bytes[8U + 15U] = std::byte{0x00};
    bytes[8U + 16U] = std::byte{0x00};
    bytes[8U + 17U] = std::byte{0x00};
    expect(parseFlacCodecPrivate(bytes).error ==
               FlacAdmissionError::UnknownTotalSamples,
           "a stream with no stated total sample count is refused");
  }
}

void testBlockSizeGate() {
  const auto real = realCodecPrivate();
  {
    // min 256, max 4608: the frames are not all the same length, so the
    // affine ordinal grid cannot place them.
    auto bytes = real;
    bytes[8] = std::byte{0x01};
    bytes[9] = std::byte{0x00};
    expect(parseFlacCodecPrivate(bytes).error ==
               FlacAdmissionError::VariableBlockSize,
           "a variable-block-size FLAC stream is refused, and refused with a "
           "distinct error rather than as a parse failure");
  }
  {
    auto bytes = real;
    bytes[8] = std::byte{0x00};
    bytes[9] = std::byte{0x08}; // 8 frames, below the format's minimum of 16
    bytes[10] = std::byte{0x00};
    bytes[11] = std::byte{0x08};
    expect(parseFlacCodecPrivate(bytes).error ==
               FlacAdmissionError::InvalidBlockSize,
           "a block size below 16 is refused");
  }
}

void testChannelGate() {
  auto bytes = realCodecPrivate();
  // channels - 1 lives in bits 20..22 of the packed field at offset 8 + 10.
  // 0x43 -> 0x45 raises it from 1 (stereo) to 2 (three channels).
  bytes[8U + 12U] = std::byte{0x45};
  expect(parseFlacCodecPrivate(bytes).error ==
             FlacAdmissionError::UnsupportedChannelCount,
         "multichannel FLAC is refused at admission -- the converter drops "
         "centre, LFE and both surrounds rather than downmixing them");
}

} // namespace

int main() {
  static_assert(kFlacMagicCookieBytes == 50U);
  static_assert(kFlacStreamInfoBytes == 34U);

  testRealFixture();
  testMagicCookie();
  testCookieDropsExtraBlocks();
  testMalformedInputs();
  testBlockSizeGate();
  testChannelGate();

  if (failures != 0) {
    std::cerr << failures << " Matroska FLAC test(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "Matroska FLAC STREAMINFO, dfLa cookie and admission gate "
               "tests passed\n";
  return EXIT_SUCCESS;
}
