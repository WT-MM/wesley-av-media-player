#include "media/audio_codec_timing.hpp"
#include "media/matroska_ac3.hpp"

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


// The first syncframe of scratchpad/fixtures/sw/c_ac3.mkv, byte for byte as
// ffmpeg muxed it: 48 kHz, 192 kbit/s (frmsizecod 20 -> 768 bytes), bsid 8,
// acmod 2 (stereo), no LFE.
constexpr std::array<std::uint8_t, 8> kRealAc3Header{
    0x0B, 0x77, 0xF0, 0x08, 0x14, 0x40, 0x43, 0xE1};
constexpr std::size_t kRealAc3FrameBytes{768};

// The first syncframe of c_eac3.mkv: strmtyp 0, substreamid 0, frmsiz 383
// (-> 768 bytes), fscod 0, numblkscod 3 (six blocks), acmod 2, no LFE.
constexpr std::array<std::uint8_t, 8> kRealEac3Header{
    0x0B, 0x77, 0x01, 0x7F, 0x34, 0x87, 0xC0, 0x00};
constexpr std::size_t kRealEac3FrameBytes{768};

// The first syncframe of ac3mono.mkv: 96 kbit/s (frmsizecod 12 -> 384 bytes),
// acmod 1 (mono).
constexpr std::array<std::uint8_t, 8> kRealAc3MonoHeader{
    0x0B, 0x77, 0xDB, 0xF5, 0x0C, 0x40, 0x2F, 0x84};
constexpr std::size_t kRealAc3MonoFrameBytes{384};

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
  const auto ac3 = frameOf(kRealAc3Header, kRealAc3FrameBytes);
  const Ac3Admission admission = parseAc3Syncframe(ac3, false);
  expect(admission.admitted(), "real ffmpeg AC-3 syncframe is admitted");
  if (admission.admitted()) {
    const Ac3Configuration &configuration = *admission.configuration;
    expect(configuration.sampleRate == 48'000U, "AC-3 fscod 0 is 48 kHz");
    expect(configuration.channelCount == 2U, "AC-3 acmod 2 is stereo");
    expect(configuration.samplesPerAccessUnit == kAc3SamplesPerAccessUnit,
           "AC-3 decodes 1536 frames per syncframe");
    expect(configuration.syncframeBytes == kRealAc3FrameBytes,
           "frmsizecod 20 at 48 kHz is 768 bytes");
    expect(!configuration.enhanced, "bsid 8 is legacy AC-3");
  }

  const auto eac3 = frameOf(kRealEac3Header, kRealEac3FrameBytes);
  const Ac3Admission enhanced = parseAc3Syncframe(eac3, true);
  expect(enhanced.admitted(), "real ffmpeg E-AC-3 syncframe is admitted");
  if (enhanced.admitted()) {
    const Ac3Configuration &configuration = *enhanced.configuration;
    expect(configuration.sampleRate == 48'000U, "E-AC-3 fscod 0 is 48 kHz");
    expect(configuration.channelCount == 2U, "E-AC-3 acmod 2 is stereo");
    expect(configuration.samplesPerAccessUnit == kAc3SamplesPerAccessUnit,
           "E-AC-3 numblkscod 3 is six blocks of 256 frames");
    expect(configuration.syncframeBytes == kRealEac3FrameBytes,
           "frmsiz 383 is 768 bytes");
    expect(configuration.enhanced, "bsid 16 is E-AC-3");
  }

  const auto mono = frameOf(kRealAc3MonoHeader, kRealAc3MonoFrameBytes);
  const Ac3Admission monoAdmission = parseAc3Syncframe(mono, false);
  expect(monoAdmission.admitted(), "real ffmpeg mono AC-3 is admitted");
  if (monoAdmission.admitted()) {
    expect(monoAdmission.configuration->channelCount == 1U,
           "AC-3 acmod 1 is mono");
    expect(monoAdmission.configuration->syncframeBytes ==
               kRealAc3MonoFrameBytes,
           "frmsizecod 12 at 48 kHz is 384 bytes");
  }
}

// The CodecID and the bitstream must agree. This is the one gate that cannot
// be derived from the bytes alone, because a mislabelled mux is still a valid
// bitstream of the other flavour.
void testCodecIdAgreement() {
  const auto ac3 = frameOf(kRealAc3Header, kRealAc3FrameBytes);
  const auto eac3 = frameOf(kRealEac3Header, kRealEac3FrameBytes);
  expect(parseAc3Syncframe(ac3, true).error ==
             Ac3AdmissionError::CodecIdMismatch,
         "an AC-3 bitstream in an A_EAC3 track is refused");
  expect(parseAc3Syncframe(eac3, false).error ==
             Ac3AdmissionError::CodecIdMismatch,
         "an E-AC-3 bitstream in an A_AC3 track is refused");
}

void testMalformedInputs() {
  expect(parseAc3Syncframe({}, false).error ==
             Ac3AdmissionError::TruncatedSyncframe,
         "an empty frame is refused");
  {
    auto frame = frameOf(kRealAc3Header, kRealAc3FrameBytes);
    frame.resize(kAc3MinimumSyncframeBytes - 1U);
    expect(parseAc3Syncframe(frame, false).error ==
               Ac3AdmissionError::TruncatedSyncframe,
           "a frame shorter than the header is refused");
  }
  {
    auto frame = frameOf(kRealAc3Header, kRealAc3FrameBytes);
    frame[1] = std::byte{0x78};
    expect(parseAc3Syncframe(frame, false).error ==
               Ac3AdmissionError::UnexpectedSyncword,
           "a corrupt syncword is refused");
  }
  {
    // bsid 9 and 10 are the unused alternate bit stream syntax.
    auto frame = frameOf(kRealAc3Header, kRealAc3FrameBytes);
    frame[5] = std::byte{0x48}; // bsid 9
    expect(parseAc3Syncframe(frame, false).error ==
               Ac3AdmissionError::UnsupportedBitStreamIdentification,
           "bsid 9 is refused");
    frame[5] = std::byte{0x50}; // bsid 10
    expect(parseAc3Syncframe(frame, false).error ==
               Ac3AdmissionError::UnsupportedBitStreamIdentification,
           "bsid 10 is refused");
  }
  {
    // fscod 3 is reserved in AC-3.
    auto frame = frameOf(kRealAc3Header, kRealAc3FrameBytes);
    frame[4] = std::byte{0xD4};
    expect(parseAc3Syncframe(frame, false).error ==
               Ac3AdmissionError::ReservedSampleRate,
           "AC-3 fscod 3 is refused");
  }
  {
    // frmsizecod 38..63 is beyond the bit rate table.
    auto frame = frameOf(kRealAc3Header, kRealAc3FrameBytes);
    frame[4] = std::byte{0x3F};
    expect(parseAc3Syncframe(frame, false).error ==
               Ac3AdmissionError::UnsupportedBitRateCode,
           "an out-of-range frmsizecod is refused");
  }
  {
    // The Block must hold exactly one syncframe.
    auto frame = frameOf(kRealAc3Header, kRealAc3FrameBytes + 1U);
    expect(parseAc3Syncframe(frame, false).error ==
               Ac3AdmissionError::FrameSizeMismatch,
           "a Block longer than its syncframe is refused");
    auto shortFrame = frameOf(kRealAc3Header, kRealAc3FrameBytes - 1U);
    expect(parseAc3Syncframe(shortFrame, false).error ==
               Ac3AdmissionError::FrameSizeMismatch,
           "a Block shorter than its syncframe is refused");
  }
}

void testChannelGate() {
  // acmod 7 is 3/2 -- five full-bandwidth channels -- and the trailing bit
  // here sets lfeon, so this is the 5.1 case. It is now ADMITTED: the player
  // decodes all six channels and folds them to stereo itself with exact
  // BS.775 coefficients, because Apple's own AC-3 downmix was measured to be
  // a normalised Lt/Rt matrix at -10.70 dB with both surrounds folded into
  // both outputs.
  auto frame = frameOf(kRealAc3Header, kRealAc3FrameBytes);
  frame[6] = std::byte{0xE1};
  {
    const Ac3Admission admission = parseAc3Syncframe(frame, false);
    expect(admission.admitted(), "5.1 AC-3 is admitted");
    expect(admission.admitted() && admission.configuration->channelCount == 6U,
           "5.1 AC-3 states six channels");
  }
  // acmod 0 is 1+1: two independent programs, not a stereo pair, and the one
  // arrangement with no defined stereo fold.
  frame[6] = std::byte{0x03};
  expect(parseAc3Syncframe(frame, false).error ==
             Ac3AdmissionError::UnsupportedChannelConfiguration,
         "AC-3 dual mono (acmod 0) is refused");
  // Stereo with the LFE flag set: three channels, the LFE excluded by the
  // downmix policy rather than by admission.
  frame[6] = std::byte{0x47};
  {
    const Ac3Admission admission = parseAc3Syncframe(frame, false);
    expect(admission.admitted(), "stereo plus LFE is admitted");
    expect(admission.admitted() && admission.configuration->channelCount == 3U,
           "stereo plus LFE states three channels");
  }
}

void testEnhancedGates() {
  {
    // numblkscod 0/1/2 are 1, 2 and 3 blocks: a variable access-unit duration
    // the affine ordinal grid cannot represent.
    auto frame = frameOf(kRealEac3Header, kRealEac3FrameBytes);
    for (const std::uint8_t numblkscod : {0x04U, 0x14U, 0x24U}) {
      frame[4] = static_cast<std::byte>(numblkscod);
      expect(parseAc3Syncframe(frame, true).error ==
                 Ac3AdmissionError::UnsupportedBlockCount,
             "E-AC-3 with fewer than six blocks is refused");
    }
  }
  {
    // strmtyp 1 is a dependent substream: the channels beyond the independent
    // stream's own program.
    auto frame = frameOf(kRealEac3Header, kRealEac3FrameBytes);
    frame[2] = std::byte{0x41};
    expect(parseAc3Syncframe(frame, true).error ==
               Ac3AdmissionError::UnsupportedSubstream,
           "an E-AC-3 dependent substream is refused");
    frame[2] = std::byte{0x09}; // substreamid 1
    expect(parseAc3Syncframe(frame, true).error ==
               Ac3AdmissionError::UnsupportedSubstream,
           "a non-zero E-AC-3 substream id is refused");
  }
  {
    // fscod 3 selects a halved rate through fscod2.
    auto frame = frameOf(kRealEac3Header, kRealEac3FrameBytes);
    frame[4] = std::byte{0xF4};
    expect(parseAc3Syncframe(frame, true).error ==
               Ac3AdmissionError::ReservedSampleRate,
           "E-AC-3 half sample rates are refused");
  }
}

void testPerPacketMatch() {
  const auto ac3 = frameOf(kRealAc3Header, kRealAc3FrameBytes);
  const Ac3Admission admission = parseAc3Syncframe(ac3, false);
  expect(admission.admitted(), "fixture admitted for the match test");
  if (!admission.admitted()) {
    return;
  }
  const Ac3Configuration &configuration = *admission.configuration;
  expect(ac3SyncframeMatches(std::span<const std::byte>(ac3).first(
                                 kAc3MinimumSyncframeBytes),
                             kRealAc3FrameBytes, configuration, false),
         "the admitting frame matches itself from its header alone");
  {
    // A mid-stream change of channel mode: stereo -> mono.
    auto frame = ac3;
    frame[6] = std::byte{0x2F};
    expect(!ac3SyncframeMatches(
               std::span<const std::byte>(frame).first(
                   kAc3MinimumSyncframeBytes),
               kRealAc3FrameBytes, configuration, false),
           "a mid-stream channel mode change is rejected");
  }
  {
    // A Block whose length disagrees with its own header.
    expect(!ac3SyncframeMatches(std::span<const std::byte>(ac3).first(
                                    kAc3MinimumSyncframeBytes),
                                kRealAc3FrameBytes + 2U, configuration, false),
           "a Block that does not hold exactly one syncframe is rejected");
  }
}

// The trim identity, stated as the arithmetic the demuxer performs.
void testTrimArithmetic() {
  // scratchpad/fixtures/sw/c_ac3.mkv: 188 packets, CodecDelay 256 frames, no
  // DiscardPadding, and the 32 frames AudioToolbox never flushes.
  constexpr std::uint64_t kPackets = 188;
  constexpr std::uint64_t kDecoded = kPackets * kAc3SamplesPerAccessUnit;
  static_assert(kDecoded == 288'768U);
  static_assert(kDecoded - kAc3DecoderDelayFrames == 288'512U,
                "ffmpeg's own decode of the same track is 288512 frames");
  static_assert(kDecoded - kAc3DecoderDelayFrames -
                        kAc3DecoderTailShortfallFrames ==
                    288'480U,
                "what AudioToolbox can actually render is 32 frames less, "
                "and that is the number the track's duration states");
  // 288480 / 48000 = 6.01 s exactly, which is what mkv_probe reports.
  static_assert(288'480U * 100U == 601U * 48'000U);

  // The head trim is provably zero because the container states exactly the
  // decoder delay: 5,333,333 ns at 48 kHz is 256 frames.
  const auto delay = wam::media::matroskaFramesFromNanoseconds(
      5'333'333, 48'000U, kAc3SamplesPerAccessUnit - 1U);
  expect(delay.has_value() && *delay == kAc3DecoderDelayFrames,
         "ffmpeg's AC-3 CodecDelay is exactly the 256-frame decoder delay");
  expect(kAc3DecoderDelayFrames >= *delay &&
             *delay - kAc3DecoderDelayFrames == 0U,
         "the head trim AC-3 owes after AudioToolbox's own drop is zero");

  // A stated delay that is not a rounded frame count at this rate is refused
  // rather than snapped.
  expect(!wam::media::matroskaFramesFromNanoseconds(5'333'000, 48'000U,
                                                    kAc3SamplesPerAccessUnit),
         "a delay that was never a rounded frame count is refused");
}

} // namespace

int main() {
  static_assert(kAc3SamplesPerAccessUnit == 1'536U);
  static_assert(kAc3DecoderDelayFrames == 256U);
  static_assert(kAc3DecoderTailShortfallFrames == 32U);

  testRealFixtures();
  testCodecIdAgreement();
  testMalformedInputs();
  testChannelGate();
  testEnhancedGates();
  testPerPacketMatch();
  testTrimArithmetic();

  if (failures != 0) {
    std::cerr << failures << " Matroska AC-3 test(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "Matroska AC-3 / E-AC-3 syncframe, channel gate, per-packet "
               "match and trim tests passed\n";
  return EXIT_SUCCESS;
}
