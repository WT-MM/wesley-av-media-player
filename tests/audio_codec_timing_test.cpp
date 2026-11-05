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
#include "media/aac_packet_timeline.hpp"

#include <cstdlib>
#include <iostream>

#include "support/expect.hpp"

namespace {

using wam::media::audioCodecPrecedesStreamOrigin;
using wam::media::audioCodecStatesExactDecodedDuration;
using wam::media::matroskaFramesFromNanoseconds;
using wam::media::MediaCodec;


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
  using wam::media::projectAacPacketGrid;
  for (unsigned rate : {44100u,48000u}) {
    for (int residual : {-256,-22,0,38,152,256}) {
      const auto t = projectAacPacketGrid({1024*600000LL-2048+residual,static_cast<int>(rate)},-2048,600000,rate);
      expect(t && t->value == 1024*600000LL-2048, "bounded jitter preserves origin and long ordinal grid");
    }
    for (int residual : {-10331,-1104,-1023,-257,257,1024})
      expect(!projectAacPacketGrid({1024*200LL+residual,static_cast<int>(rate)},0,200,rate),
             "drift and missing/overlapping access units fail the original ordinal proof");
    expect(!projectAacPacketGrid({0,static_cast<int>(rate)},INT64_MAX,1,rate),"grid overflow refuses");
  }

  {
    wam::media::AacPacketTimeline piecewise(48000);
    for (const auto [pts,duration] : {std::pair{0,1024}, {1024,1}, {1025,307}, {1332,2764}, {4096,1024}})
      expect(piecewise.append({pts,48000},{duration,48000}), "declared overlaps and gap re-anchor exactly");
    expect(piecewise.finish() && piecewise.packets()[1].duration == 1 &&
        piecewise.packets()[2].duration == 307 && piecewise.packets()[3].duration == 2764,
        "piecewise proof retains trim and silence extents");
    wam::media::AacPacketTimeline drift(48000);
    for (int i=0;i<=256;++i)
      expect(drift.append({i*1025,48000},{1025,48000}), "one-tick jitter remains within segment bound");
    expect(!drift.append({257*1025,48000},{1025,48000}), "cumulative jitter cannot re-anchor away the bound");
    wam::media::AacPacketTimeline fractional(48000);
    expect(fractional.append({0,48000},{1,48000}), "short first packet");
    expect(!fractional.append({1,96000},{1024,48000}), "fractional-frame segment anchor refuses");
  }
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
