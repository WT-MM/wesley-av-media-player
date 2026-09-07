#include "media/native_seek_progress.hpp"
#include "media/audio_track_admission.hpp"
#include "media/matroska_apple_audio.hpp"
#include "media/media_codec_facts.hpp"
#include "media/mjpeg_admission.hpp"
#include "media/mp3_lame_gapless.hpp"
#include <array>
#include <cstdio>

int main() {
  using namespace wam::media;
  int failures = 0;
  auto check = [&](bool value, const char *name) {
    if (!value) {
      std::fprintf(stderr, "%s\n", name);
      ++failures;
    }
  };
  const std::array<AudioTrackCandidate, 4> candidates{
      {{1, true, false}, {2, true, true}, {3, true, true}, {4, false, true}}};
  std::array<std::size_t, 4> visited{};
  std::size_t count = 0;
  auto result = selectAdmittedAudioTrack(candidates, {}, [&](std::size_t i) {
    visited[count++] = i;
    return i == 0;
  });
  check(result == 0 && count == 3 && visited[0] == 1 && visited[1] == 2 &&
            visited[2] == 0,
        "complete admission retries defaults then remaining tracks");
  count = 0;
  result = selectAdmittedAudioTrack(candidates, 2, [&](std::size_t i) {
    visited[count++] = i;
    return false;
  });
  check(!result && count == 1 && visited[0] == 1,
        "explicit selection fails closed");
  check(!selectAdmittedAudioTrack(candidates, 99,
                                  [](std::size_t) { return true; }),
        "missing explicit track cannot silently select another");
  std::array<std::byte, 21> jpeg{};
  const unsigned raw[]{255, 216, 255, 192, 0, 17, 8, 0, 180, 1, 64,
                       3,   1,   34,  0,   2, 17, 1, 3, 17,  1};
  for (std::size_t i = 0; i < jpeg.size(); ++i)
    jpeg[i] = static_cast<std::byte>(raw[i]);
  check(inspectMjpegHeader(jpeg) == MjpegAdmission::Yuv420,
        "SOF0 420 admitted");
  for (std::size_t n = 0; n < jpeg.size(); ++n)
    check(inspectMjpegHeader(std::span(jpeg).first(n)) ==
              MjpegAdmission::InvalidHeader,
          "truncated SOF0 rejected");
  jpeg[13] = std::byte{0x21};
  check(inspectMjpegHeader(jpeg) == MjpegAdmission::UnsupportedChroma,
        "422 refused by chroma");
  jpeg[13] = std::byte{0x11};
  check(inspectMjpegHeader(jpeg) == MjpegAdmission::UnsupportedChroma,
        "444 refused by chroma");
  jpeg[13] = std::byte{0x22};
  jpeg[3] = std::byte{0xc2};
  check(inspectMjpegHeader(jpeg) == MjpegAdmission::UnsupportedFrame,
        "progressive refused");
  jpeg[3] = std::byte{0xc0};
  jpeg[6] = std::byte{12};
  check(inspectMjpegHeader(jpeg) == MjpegAdmission::UnsupportedFrame,
        "12 bit refused");
  jpeg[6] = std::byte{8};
  jpeg[15] = std::byte{1};
  check(inspectMjpegHeader(jpeg) == MjpegAdmission::InvalidHeader,
        "duplicate component refused");
  for (const auto &fact : kMediaCodecFacts)
    check(fact.requiresMjpegHeaderInspection ==
              (fact.codec == MediaCodec::Mjpeg),
          "only MJPEG requires header inspection");
  std::array<std::byte, 182> mp3{};
  const unsigned header[]{255, 243, 112, 0};
  for (std::size_t i = 0; i < 4; ++i)
    mp3[i] = static_cast<std::byte>(header[i]);
  const unsigned info[]{'I', 'n', 'f', 'o', 0,   0,   0,   1,
                        0,   0,   0,   156, 'L', 'A', 'M', 'E'};
  for (std::size_t i = 0; i < 16; ++i)
    mp3[21 + i] = static_cast<std::byte>(info[i]);
  mp3[54] = std::byte{0x24};
  mp3[55] = std::byte{0x04};
  mp3[56] = std::byte{0x38};
  const auto gapless = inspectMp3LsfGapless(mp3);
  check(gapless && gapless->sampleRate == 22050 &&
            gapless->encoderDelay == 576 && gapless->retainedFrames == 88200,
        "LSF LAME frame count excludes encoder delay and padding");
  for (std::size_t n = 0; n < mp3.size(); ++n)
    check(!inspectMp3LsfGapless(std::span(mp3).first(n)),
          "short MPEG frame cannot prove a LAME tag");
  mp3[1] = std::byte{0xfb};
  check(!inspectMp3LsfGapless(mp3), "MPEG-1 remains container-owned");
  mp3[1] = std::byte{0xf3};
  mp3[28] = std::byte{0};
  check(!inspectMp3LsfGapless(mp3), "Xing frame count must be present");
  mp3[28] = std::byte{1};
  mp3[32] = std::byte{1};
  check(!inspectMp3LsfGapless(mp3), "padding cannot consume the stream");

  const auto pcm = matroska::appleAudioPacketFormat("A_PCM/INT/LIT", {}, 48000, 2, 24);
  check(pcm.codec == MediaCodec::Pcm && pcm.format.bytesPerFrame == 6 &&
            pcm.format.bitsPerChannel == 24, "PCM descriptor preserves packed sample depth");
  check(matroska::appleAudioPacketFormat("A_PCM/FLOAT/IEEE", {}, 48000, 2, 64).codec ==
            MediaCodec::Unknown, "unproved float depth refuses");
  const unsigned cookieRaw[]{0,0,16,0,0,24,40,10,14,2,0,0,0,0,96,4,0,35,40,0,0,0,187,128};
  std::array<std::byte,24> cookie{};
  for (unsigned i=0;i<24;++i) cookie[i]=static_cast<std::byte>(cookieRaw[i]);
  check(matroska::appleAudioPacketFormat("A_ALAC", cookie,48000,2,24).blockFrames==4096,
        "Matroska ALAC private is the bare 24-byte cookie");
  for (unsigned n=0;n<24;++n)
    check(matroska::appleAudioPacketFormat("A_ALAC", std::span(cookie).first(n),48000,2,24).codec==MediaCodec::Unknown,
          "truncated ALAC private refuses");
  const std::array<std::byte,7> alacTail{std::byte{0x20},std::byte{0},std::byte{0x14},std::byte{0},std::byte{0},std::byte{0x1c},std::byte{0}};
  check(matroska::alacPacketFrames(alacTail,4096)==3584,"ALAC explicit tail count is exact");
  check(!isSlowVideoSeek({12,1},{0,1}) && isSlowVideoSeek({577,48},{0,1}) &&
            isSlowVideoSeek({30,1},{0,1}), "fast seek threshold is exact and does not cap admission");
  SeekProgressDeadline deadline;
  for (unsigned i=1;i<40;++i) check(!deadline.expired(0), "seek keeps inactivity grace");
  check(deadline.expired(0), "stalled seek expires");
  check(!deadline.expired(1) && deadline.idleMilliseconds==0, "decode progress resets the deadline");
  return failures != 0;
}
