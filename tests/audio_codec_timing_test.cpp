// The two neutral audio-timing predicates. Neither had ANY test before this
// file, and both are load-bearing: audioCodecPrecedesStreamOrigin relaxes the
// nonnegative-time guards for the codecs that legitimately start early, and
// audioCodecStatesExactDecodedDuration is what lets a generation take an exact
// publication ceiling instead of a container estimate. Getting either wrong is
// silent -- audio that starts in the wrong place, or a clock that free-runs
// past the end of the stream.
//
// Every membership below is asserted in BOTH directions. A predicate that
// simply returned true would pass a one-sided test, and these two predicates
// deliberately have DIFFERENT membership from each other (see the header's own
// note: FLAC states an exact duration but starts at origin; AAC precedes the
// origin but reaches this pipeline from AVFoundation, whose duration is a
// container estimate).

#include "media/audio_codec_timing.hpp"

#include <cstdlib>
#include <iostream>

namespace {

using wam::media::audioCodecPrecedesStreamOrigin;
using wam::media::audioCodecStatesExactDecodedDuration;
using wam::media::matroskaFramesFromNanoseconds;
using wam::media::MediaCodec;

int failures = 0;

void expect(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

void testCodecsThatPrecedeTheStreamOrigin() {
  // Codecs with a real encoder/decoder lead-in.
  expect(audioCodecPrecedesStreamOrigin(MediaCodec::Opus), "Opus pre-skip");
  expect(audioCodecPrecedesStreamOrigin(MediaCodec::Vorbis),
         "Vorbis half-window first packet");
  expect(audioCodecPrecedesStreamOrigin(MediaCodec::Ac3), "AC-3 256-frame delay");
  expect(audioCodecPrecedesStreamOrigin(MediaCodec::Eac3),
         "E-AC-3 256-frame delay");
  expect(audioCodecPrecedesStreamOrigin(MediaCodec::Mp3), "MP3 LAME + 529");
  expect(audioCodecPrecedesStreamOrigin(MediaCodec::Aac), "AAC 1024 priming");

  // And the codecs whose access unit 0 IS media frame 0. FLAC is called out in
  // the header as the deliberate non-member.
  expect(!audioCodecPrecedesStreamOrigin(MediaCodec::Flac),
         "FLAC starts exactly at origin");
  expect(!audioCodecPrecedesStreamOrigin(MediaCodec::Pcm),
         "uncompressed audio starts exactly at origin");
  // ALAC is lossless with no encoder priming: AudioToolbox emits its first
  // decoded frame as media frame 0, measured 0-frame lag against ffmpeg.
  expect(!audioCodecPrecedesStreamOrigin(MediaCodec::Alac),
         "ALAC starts exactly at origin");
  // ADPCM has no decoder lead-in at all -- measured 0 frames by chirp
  // cross-correlation against ffmpeg on both families.
  expect(!audioCodecPrecedesStreamOrigin(MediaCodec::AdpcmIma),
         "IMA ADPCM starts exactly at origin");
  expect(!audioCodecPrecedesStreamOrigin(MediaCodec::AdpcmMs),
         "Microsoft ADPCM starts exactly at origin");
  // A video codec is not an audio codec; the predicate must not say yes.
  expect(!audioCodecPrecedesStreamOrigin(MediaCodec::H264),
         "a video codec never precedes the audio origin");
  expect(!audioCodecPrecedesStreamOrigin(MediaCodec::Unknown),
         "an unknown codec claims nothing");
}

void testCodecsThatStateAnExactDecodedDuration() {
  expect(audioCodecStatesExactDecodedDuration(MediaCodec::Opus), "Opus");
  expect(audioCodecStatesExactDecodedDuration(MediaCodec::Vorbis), "Vorbis");
  expect(audioCodecStatesExactDecodedDuration(MediaCodec::Ac3), "AC-3");
  expect(audioCodecStatesExactDecodedDuration(MediaCodec::Eac3), "E-AC-3");
  expect(audioCodecStatesExactDecodedDuration(MediaCodec::Mp3), "MP3");
  expect(audioCodecStatesExactDecodedDuration(MediaCodec::Flac),
         "FLAC STREAMINFO states the total sample count");
  expect(audioCodecStatesExactDecodedDuration(MediaCodec::Pcm),
         "uncompressed audio states a frame count in its own header");
  // ADPCM: the format is BLOCKED, so the frame count is not simply bytes over
  // block align and the final block is padded -- yet the frames AudioToolbox
  // produces were measured equal to the declared count exactly, on both
  // families at every admitted rate.
  expect(audioCodecStatesExactDecodedDuration(MediaCodec::AdpcmIma),
         "IMA ADPCM decodes to exactly its declared frame count");
  expect(audioCodecStatesExactDecodedDuration(MediaCodec::AdpcmMs),
         "Microsoft ADPCM decodes to exactly its declared frame count");
  // ALAC: an MP4's track duration IS the decoded sample count, because the
  // sample table states the final packet's true length. This membership is
  // what pairs ALAC's tail-shortfall bound with an exact ceiling, so the bound
  // stays a guard rather than becoming a licence to publish past the stream.
  expect(audioCodecStatesExactDecodedDuration(MediaCodec::Alac),
         "ALAC states an exact decoded duration");

  // AAC is the deliberate NON-member, and the header says why: it reaches this
  // pipeline from AVFoundation too, where the duration is the container's
  // estimate rather than a decoded sample count. If this ever flips, the
  // AVFoundation route would take a ceiling it cannot justify.
  expect(!audioCodecStatesExactDecodedDuration(MediaCodec::Aac),
         "AAC does NOT state an exact decoded duration here");
  expect(!audioCodecStatesExactDecodedDuration(MediaCodec::Unknown),
         "an unknown codec states nothing");
}

// The two predicates are genuinely different questions, and the header says so.
// Pin the two codecs that separate them, so a future edit cannot quietly
// collapse one into the other.
void testTheTwoPredicatesAreNotTheSameSet() {
  expect(audioCodecStatesExactDecodedDuration(MediaCodec::Flac) &&
             !audioCodecPrecedesStreamOrigin(MediaCodec::Flac),
         "FLAC is exact-duration but origin-starting");
  expect(audioCodecPrecedesStreamOrigin(MediaCodec::Aac) &&
             !audioCodecStatesExactDecodedDuration(MediaCodec::Aac),
         "AAC precedes the origin but is not exact-duration");
}

void testFrameRecoveryFromNanoseconds() {
  // 1024 frames at 48 kHz is 21,333,333.33 ns; the muxer writes a rounded
  // integer and the exact count must come back.
  const auto rounded = matroskaFramesFromNanoseconds(21'333'333, 48'000, 96'000);
  expect(rounded.has_value() && *rounded == 1024U,
         "a rounded nanosecond duration recovers its exact frame count");

  const auto zero = matroskaFramesFromNanoseconds(0, 48'000, 96'000);
  expect(zero.has_value() && *zero == 0U, "zero nanoseconds is zero frames");

  // Refusals, each for its own stated reason.
  expect(!matroskaFramesFromNanoseconds(-1, 48'000, 96'000).has_value(),
         "a negative duration asks for padding to be added and is refused");
  expect(!matroskaFramesFromNanoseconds(21'333'333, 0, 96'000).has_value(),
         "a zero sample rate is refused");
  expect(!matroskaFramesFromNanoseconds(21'333'333, 48'000, 1'000).has_value(),
         "a result past the caller's ceiling is refused");
  // Half a frame at 48 kHz is ~10,417 ns -- far past the one-nanosecond
  // residual, so it was never a rounded frame count and must not be snapped.
  expect(!matroskaFramesFromNanoseconds(21'328'125, 48'000, 96'000).has_value(),
         "a value that was never a rounded frame count is refused, not snapped");
}

} // namespace

int main() {
  testCodecsThatPrecedeTheStreamOrigin();
  testCodecsThatStateAnExactDecodedDuration();
  testTheTwoPredicatesAreNotTheSameSet();
  testFrameRecoveryFromNanoseconds();
  if (failures != 0) {
    std::cerr << failures << " audio codec timing expectation(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "audio codec timing: all expectations passed\n";
  return EXIT_SUCCESS;
}
