#include "media/audio_codec_timing.hpp"
#include "media/matroska_mpeg_audio.hpp"

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

// The first frame header of scratchpad/fixtures/sw/c_mp3.mkv, byte for byte as
// LAME produced it: MPEG-1 Layer III, 192 kbit/s, 44.1 kHz, no padding, joint
// stereo -> 626 bytes.
constexpr std::array<std::uint8_t, 4> kReal44kHeader{0xFF, 0xFB, 0xB0, 0x64};
constexpr std::size_t kReal44kFrameBytes{626};

// The first frame header of mp48.mkv: the same at 48 kHz -> 576 bytes.
constexpr std::array<std::uint8_t, 4> kReal48kHeader{0xFF, 0xFB, 0xB4, 0x64};
constexpr std::size_t kReal48kFrameBytes{576};

[[nodiscard]] std::vector<std::byte> frameOf(std::span<const std::uint8_t> head,
                                             std::size_t totalBytes) {
  std::vector<std::byte> frame(totalBytes, std::byte{0});
  for (std::size_t index = 0; index < head.size() && index < totalBytes;
       ++index) {
    frame[index] = static_cast<std::byte>(head[index]);
  }
  return frame;
}

void testRealFixtures() {
  const auto frame = frameOf(kReal44kHeader, kReal44kFrameBytes);
  const MpegAudioAdmission admission = parseMpegAudioFrameHeader(frame);
  expect(admission.admitted(), "real LAME 44.1 kHz frame is admitted");
  if (admission.admitted()) {
    const MpegAudioConfiguration &configuration = *admission.configuration;
    expect(configuration.sampleRate == 44'100U, "44.1 kHz is read back");
    expect(configuration.channelCount == 2U, "joint stereo is two channels");
    expect(configuration.samplesPerAccessUnit ==
               kMpegLayer3SamplesPerAccessUnit,
           "MPEG-1 Layer III decodes 1152 frames per access unit");
    // 144 * 192000 / 44100 = 626.9..., truncated to 626 with no padding bit.
    expect(configuration.frameBytes == kReal44kFrameBytes,
           "192 kbit/s at 44.1 kHz with no padding is 626 bytes");
  }

  const auto frame48 = frameOf(kReal48kHeader, kReal48kFrameBytes);
  const MpegAudioAdmission admission48 = parseMpegAudioFrameHeader(frame48);
  expect(admission48.admitted(), "real LAME 48 kHz frame is admitted");
  if (admission48.admitted()) {
    expect(admission48.configuration->sampleRate == 48'000U,
           "48 kHz is read back");
    expect(admission48.configuration->frameBytes == kReal48kFrameBytes,
           "192 kbit/s at 48 kHz is exactly 576 bytes");
  }
}

void testMonoAndPadding() {
  {
    // Channel mode 3 is single channel.
    auto frame = frameOf(kReal44kHeader, kReal44kFrameBytes);
    frame[3] = std::byte{0xC4};
    const auto admission = parseMpegAudioFrameHeader(frame);
    expect(admission.admitted() && admission.configuration->channelCount == 1U,
           "channel mode 3 is mono");
  }
  {
    // The padding bit adds exactly one byte, which is why a 44.1 kHz stream
    // alternates between two legal frame lengths.
    auto frame = frameOf(kReal44kHeader, kReal44kFrameBytes + 1U);
    frame[2] = std::byte{0xB2};
    const auto admission = parseMpegAudioFrameHeader(frame);
    expect(admission.admitted() &&
               admission.configuration->frameBytes == kReal44kFrameBytes + 1U,
           "the padding bit lengthens the frame by one byte");
  }
}

void testMalformedInputs() {
  expect(parseMpegAudioFrameHeader({}).error ==
             MpegAudioAdmissionError::TruncatedFrameHeader,
         "an empty frame is refused");
  {
    auto frame = frameOf(kReal44kHeader, 3U);
    expect(parseMpegAudioFrameHeader(frame).error ==
               MpegAudioAdmissionError::TruncatedFrameHeader,
           "a frame shorter than the 4-byte header is refused");
  }
  {
    auto frame = frameOf(kReal44kHeader, kReal44kFrameBytes);
    frame[1] = std::byte{0xC3};
    expect(parseMpegAudioFrameHeader(frame).error ==
               MpegAudioAdmissionError::UnexpectedSyncword,
           "a broken sync word is refused");
  }
  {
    // MPEG-2 and MPEG-2.5 Layer III decode 576 frames per access unit, and the
    // 529-frame decoder lead-in was measured on MPEG-1 only.
    auto frame = frameOf(kReal44kHeader, kReal44kFrameBytes);
    frame[1] = std::byte{0xF3}; // version 2
    expect(parseMpegAudioFrameHeader(frame).error ==
               MpegAudioAdmissionError::UnsupportedVersion,
           "MPEG-2 Layer III is refused");
    frame[1] = std::byte{0xE3}; // version 2.5
    expect(parseMpegAudioFrameHeader(frame).error ==
               MpegAudioAdmissionError::UnsupportedVersion,
           "MPEG-2.5 Layer III is refused");
  }
  {
    auto frame = frameOf(kReal44kHeader, kReal44kFrameBytes);
    frame[1] = std::byte{0xFD}; // Layer II
    expect(parseMpegAudioFrameHeader(frame).error ==
               MpegAudioAdmissionError::UnsupportedLayer,
           "Layer II is refused");
    frame[1] = std::byte{0xFF}; // Layer I
    expect(parseMpegAudioFrameHeader(frame).error ==
               MpegAudioAdmissionError::UnsupportedLayer,
           "Layer I is refused");
  }
  {
    auto frame = frameOf(kReal44kHeader, kReal44kFrameBytes);
    frame[2] = std::byte{0x00}; // bit rate index 0 -- free format
    expect(parseMpegAudioFrameHeader(frame).error ==
               MpegAudioAdmissionError::UnsupportedBitRateIndex,
           "free-format MP3 is refused: nothing states the frame length");
    frame[2] = std::byte{0xF0}; // bit rate index 15 -- reserved
    expect(parseMpegAudioFrameHeader(frame).error ==
               MpegAudioAdmissionError::UnsupportedBitRateIndex,
           "the reserved bit rate index is refused");
  }
  {
    auto frame = frameOf(kReal44kHeader, kReal44kFrameBytes);
    frame[2] = std::byte{0xBC}; // sampling frequency index 3 -- reserved
    expect(parseMpegAudioFrameHeader(frame).error ==
               MpegAudioAdmissionError::ReservedSampleRate,
           "the reserved sampling frequency is refused");
  }
  {
    auto frame = frameOf(kReal44kHeader, kReal44kFrameBytes + 3U);
    expect(parseMpegAudioFrameHeader(frame).error ==
               MpegAudioAdmissionError::FrameSizeMismatch,
           "a Block that does not hold exactly one frame is refused");
  }
}

void testPerPacketMatch() {
  const auto frame = frameOf(kReal44kHeader, kReal44kFrameBytes);
  const auto admission = parseMpegAudioFrameHeader(frame);
  expect(admission.admitted(), "fixture admitted for the match test");
  if (!admission.admitted()) {
    return;
  }
  const MpegAudioConfiguration &configuration = *admission.configuration;
  const std::span<const std::byte> header =
      std::span<const std::byte>(frame).first(kMpegAudioFrameHeaderBytes);
  expect(mpegAudioFrameMatches(header, kReal44kFrameBytes, configuration),
         "the admitting frame matches itself");
  {
    // A variable-bit-rate stream changes frame LENGTH without changing the
    // access unit's duration, so it must keep matching.
    auto other = frameOf(kReal44kHeader, kReal44kFrameBytes);
    other[2] = std::byte{0x90}; // 128 kbit/s -> 417 bytes
    const auto vbr = parseMpegAudioFrameHeader(frameOf(
        std::array<std::uint8_t, 4>{0xFF, 0xFB, 0x90, 0x64}, 417U));
    expect(vbr.admitted(), "a 128 kbit/s frame parses");
    expect(mpegAudioFrameMatches(
               std::span<const std::byte>(other).first(
                   kMpegAudioFrameHeaderBytes),
               417U, configuration),
           "a bit-rate change is accepted -- it does not move the grid");
  }
  {
    auto other = frameOf(kReal44kHeader, kReal44kFrameBytes);
    other[3] = std::byte{0xC4}; // mono
    expect(!mpegAudioFrameMatches(
               std::span<const std::byte>(other).first(
                   kMpegAudioFrameHeaderBytes),
               kReal44kFrameBytes, configuration),
           "a mid-stream channel mode change is rejected");
  }
  {
    auto other = frameOf(kReal48kHeader, kReal48kFrameBytes);
    expect(!mpegAudioFrameMatches(
               std::span<const std::byte>(other).first(
                   kMpegAudioFrameHeaderBytes),
               kReal48kFrameBytes, configuration),
           "a mid-stream sample rate change is rejected");
  }
}

// The trim identity, stated as the arithmetic the demuxer performs.
void testTrimArithmetic() {
  // scratchpad/fixtures/sw/c_mp3.mkv: 231 packets, CodecDelay 25,056,689 ns,
  // DiscardPadding 9,229,025 ns, both at 44.1 kHz.
  constexpr std::uint64_t kPackets = 231;
  constexpr std::uint64_t kDecoded = kPackets * kMpegLayer3SamplesPerAccessUnit;
  static_assert(kDecoded == 266'112U);

  const auto delay = wam::media::matroskaFramesFromNanoseconds(
      25'056'689, 44'100U, kMpegLayer3SamplesPerAccessUnit - 1U);
  expect(delay.has_value() && *delay == 1'105U,
         "ffmpeg's MP3 CodecDelay is 1105 frames -- the 576-frame LAME "
         "encoder delay plus the 529-frame decoder delay");
  const auto discard = wam::media::matroskaFramesFromNanoseconds(
      9'229'025, 44'100U, kMpegLayer3SamplesPerAccessUnit - 1U);
  expect(discard.has_value() && *discard == 407U,
         "the final Block's DiscardPadding is 407 frames");
  if (!delay || !discard) {
    return;
  }
  expect(*delay > kMpegLayer3DecoderDelayFrames &&
             *delay - kMpegLayer3DecoderDelayFrames == 576U,
         "the head trim MP3 owes after AudioToolbox's own 529-frame drop is "
         "the 576-frame encoder delay");
  const std::uint64_t published = kDecoded - *delay - *discard;
  expect(published == 264'600U,
         "231*1152 - 1105 - 407 = 264600, which is exactly ffmpeg's own "
         "decoded frame count and exactly 6.000000 s at 44.1 kHz");
  expect(published == 6U * 44'100U, "264600 frames is six seconds exactly");

  // 1105 - 529 = 576 must be non-negative for every admitted track, which is
  // why a CodecDelay below the decoder's own delay is refused.
  static_assert(kMpegLayer3DecoderDelayFrames == 529U);
}

} // namespace

int main() {
  static_assert(kMpegLayer3SamplesPerAccessUnit == 1'152U);

  testRealFixtures();
  testMonoAndPadding();
  testMalformedInputs();
  testPerPacketMatch();
  testTrimArithmetic();

  if (failures != 0) {
    std::cerr << failures << " Matroska MPEG audio test(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "Matroska MPEG-1 Layer III header, admission gate, per-packet "
               "match and trim tests passed\n";
  return EXIT_SUCCESS;
}
