#include "media/media_codec_facts.hpp"
#include "platform/macos/libavformat_media_source.hpp"
#include "platform/macos/video_decode_lane.hpp"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <thread>
#include <vector>
using namespace wam::macos;
using namespace wam::media;
#define REQUIRE(x)                                                             \
  do {                                                                         \
    if (!(x)) {                                                                \
      std::fprintf(stderr, "FAIL %d: %s error=%s\n", __LINE__, #x,             \
                   error.c_str());                                             \
      return 1;                                                                \
    }                                                                          \
  } while (false)
struct Sink final : DecodedFrameSink {
  struct Time {
    MediaTime pts, duration;
  };
  std::vector<Time> expected;
  unsigned frames{};
  bool failed{}, ended{};
  FILE* timestamps{};
  FrameEnqueueResult enqueue(FrameLease frame, std::string *) override {
    if (!frame || frames >= expected.size() || frame.timing().generation != 2) {
      failed = true;
      return FrameEnqueueResult::Accepted;
    }
    const auto &want = expected[frames++];
    if(timestamps)std::fprintf(timestamps,"%lld/%d %lld/%d\n",frame.timing().presentationTime.value,frame.timing().presentationTime.timescale,frame.timing().duration.value,frame.timing().duration.timescale);
    failed |=
        CMTimeCompare(frame.timing().presentationTime,
                      CMTimeMake(want.pts.value, want.pts.timescale)) != 0;
    failed |= CMTimeCompare(frame.timing().duration,
                            CMTimeMake(want.duration.value,
                                       want.duration.timescale)) != 0;
    return FrameEnqueueResult::Accepted;
  }
  void endOfStream(std::uint64_t generation) override {
    ended = generation == 2;
  }
  void flush(std::uint64_t) noexcept override {
    frames = 0;
    ended = false;
  }
};
int main(int argc, char **argv) {
  if (argc != 2 && argc != 3)
    return 2;
  std::string error;
  LibavformatMediaSource source;
  MediaSourceOpenOptions options;
  options.selection.requireAudio = false;
  REQUIRE(source.armOperation(1));
  auto opened = source.openLocalFile(argv[1], options, 1);
  error = opened.error;
  REQUIRE(opened.status == MediaSourceOpenStatus::Ready);
  Sink sink;
  if(argc==3)sink.timestamps=std::fopen(argv[2],"w");
  for (;;) {
    auto result = source.readNext(1);
    if (auto *sample = std::get_if<MediaSample>(&result)) {
      if(sample->kind==MediaSampleKind::EncodedVideo)
        sink.expected.push_back({sample->presentationTime, sample->duration});
    }
    else if (std::holds_alternative<MediaSourceExhausted>(result))
      break;
    else
      REQUIRE(std::holds_alternative<MediaEndOfStream>(result));
  }
  std::sort(sink.expected.begin(), sink.expected.end(),
            [](const auto &a, const auto &b) {
              return compareMediaTime(a.pts, b.pts) == MediaTimeOrder::Less;
            });
  REQUIRE(source.armOperation(2));
  REQUIRE(source.seek({2, {0, 1}, MediaSeekMode::Accurate}).accepted);
  const auto &track = opened.descriptor->tracks.front();
  VideoStreamConfiguration configuration;
  configuration.generation = 2;
  configuration.codec = mediaCodecFacts(track.codec).coreMediaType;
  configuration.codedSize = {
      static_cast<std::int32_t>(track.video->codedWidth),
      static_cast<std::int32_t>(track.video->codedHeight)};
  configuration.codecConfiguration = track.codecConfiguration;
  configuration.requireHardwareDecode =
      track.codec == MediaCodec::Hevc || track.codec == MediaCodec::H264;
  VideoDecodeLane decoder;
  REQUIRE(decoder.configure(configuration, sink, &error));
  const bool hardware = decoder.stats().usingHardwareAcceleratedDecoder;
  if (track.codec == MediaCodec::Hevc || track.codec == MediaCodec::H264)
    REQUIRE(hardware);
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::minutes(5);
  std::uint64_t submitted{};
  for (;;) {
    auto result = source.readNext(2);
    if (auto *sample = std::get_if<MediaSample>(&result)) {
      if(sample->kind!=MediaSampleKind::EncodedVideo)continue;
      const auto payload =
          sample->payload
              .borrowNative<NativePayloadKind::CoreMediaSampleBuffer>();
      REQUIRE(payload);
      auto buffer = static_cast<CMSampleBufferRef>(
          const_cast<void *>(payload->opaqueAddress()));
      for (;;) {
        REQUIRE(std::chrono::steady_clock::now() < deadline);
        const auto submittedResult =
            decoder.submitCMSampleBuffer(buffer, 2, &error);
        if (submittedResult == VideoDecodeSubmitResult::Accepted) {
          ++submitted;
          break;
        }
        REQUIRE(submittedResult == VideoDecodeSubmitResult::Backpressure);
        REQUIRE(decoder.drainPresentation(2, &error) !=
                VideoDecodeDrainProgress::Failed);
        std::this_thread::sleep_for(std::chrono::microseconds(100));
      }
      REQUIRE(decoder.drainPresentation(2, &error) !=
              VideoDecodeDrainProgress::Failed);
    } else if (auto* eos=std::get_if<MediaEndOfStream>(&result)) {
      if(eos->track==track.id)break;
    }
    else {
      if (auto *failure = std::get_if<MediaSourceFailure>(&result))
        error = failure->error;
      REQUIRE(false);
    }
  }
  auto drain = decoder.beginEndOfStream(2, &error);
  while (drain != VideoDecodeDrainProgress::Done) {
    REQUIRE(drain != VideoDecodeDrainProgress::Failed);
    REQUIRE(std::chrono::steady_clock::now() < deadline);
    drain = decoder.drainEndOfStream(2, &error);
    std::this_thread::sleep_for(std::chrono::microseconds(100));
  }
  REQUIRE(!sink.failed);
  REQUIRE(sink.ended);
  REQUIRE(submitted == sink.frames && submitted == sink.expected.size());
  std::printf("hardware=%d packets=%llu frames=%u exact_pts=%u "
              "exact_duration=%u eos=%d\n",
              hardware, submitted, sink.frames, sink.frames, sink.frames,
              sink.ended);
  if(sink.timestamps)std::fclose(sink.timestamps);
  decoder.close();
  source.close();
  return 0;
}
