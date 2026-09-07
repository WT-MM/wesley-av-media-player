#include "media/audio_track_admission.hpp"
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
  return failures != 0;
}
