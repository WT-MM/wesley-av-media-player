// audioCodecPrecedesStreamOrigin relaxes the nonnegative-time guards for the
// codecs that legitimately start early; getting it wrong is silent audio that
// starts in the wrong place. Membership is asserted in both directions, so a
// predicate that simply returned true fails.

#include "media/audio_codec_timing.hpp"
#include "media/aac_packet_timeline.hpp"

#include <cstdlib>
#include <iostream>

#include "support/expect.hpp"

namespace {

using wam::media::audioCodecPrecedesStreamOrigin;
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
    expect(drift.append({257*1025,48000},{1025,48000}), "cumulative drift re-anchors beyond bound");
    expect(drift.packets()[255].duration == 1024 && drift.packets()[256].duration == 1281,
           "one edit accounts for the entire cumulative drift");
    wam::media::AacPacketTimeline jitter(44100);
    for (int i=0;i<1000;++i)
      expect(jitter.append({i*1024+(i%2 ? -10 : 0),44100},{i%2 ? 1034 : 1014,44100}),
             "alternating jitter is admitted");
    for (const auto& packet : jitter.packets())
      expect(packet.duration == 1024, "jitter never trims or inserts silence");
    wam::media::AacPacketTimeline spanning(48000);
    for (const auto [pts,duration] : {std::pair{0,911}, {911,1}, {912,1024}})
      expect(spanning.append({pts,48000},{duration,48000}), "overlap spanning projected packet tails");
    expect(spanning.packets()[0].duration == 911 && spanning.packets()[1].duration == 1 &&
           spanning.packets()[2].start == 912, "single shift trims exactly 1136 frames across two AUs");
    wam::media::AacPacketTimeline fractional(48000);
    expect(fractional.append({0,48000},{1,48000}), "short first packet");
    expect(!fractional.append({1,96000},{1024,48000}), "fractional-frame segment anchor refuses");
  }
  testCodecsThatPrecedeTheStreamOrigin();
  testFrameRecoveryFromNanoseconds();
  if (failures != 0) {
    std::cerr << failures << " audio codec timing expectation(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "audio codec timing: all expectations passed\n";
  return EXIT_SUCCESS;
}
