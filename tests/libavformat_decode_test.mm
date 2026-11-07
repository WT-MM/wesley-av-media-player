#include "media/media_codec_facts.hpp"
#include "platform/macos/libavformat_media_source.hpp"
#include "platform/macos/video_decode_lane.hpp"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include "support/expect.hpp"
#include <thread>
#include <vector>
using namespace wam::macos;
using namespace wam::media;
struct Sink final : DecodedFrameSink {
  struct Time {
    MediaTime pts, duration;
  };
  std::vector<Time> expected;
  unsigned frames{};
  bool failed{}, ended{};
  FrameEnqueueResult enqueue(FrameLease frame, std::string *) override {
    if (!frame || frames >= expected.size() || frame.timing().generation != 2) {
      failed = true;
      return FrameEnqueueResult::Accepted;
    }
    const auto &want = expected[frames++];
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
  if (argc != 2)
    return 2;
  std::string error;
  LibavformatMediaSource source;
  MediaSourceOpenOptions options;
  options.selection.requireAudio = false;
  REQUIRE(source.armOperation(1));
  auto opened = source.openLocalFile(argv[1], options, 1);
  error = opened.error;
  require(opened.status == MediaSourceOpenStatus::Ready, "open: " + error);
  Sink sink;
  for (;;) {
    auto result = source.readNext(1);
    if (auto *sample = std::get_if<MediaSample>(&result))
      sink.expected.push_back({sample->presentationTime, sample->duration});
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
  const bool configured = decoder.configure(configuration, sink, &error);
  require(configured, "configure: " + error);
  const bool hardware = decoder.stats().usingHardwareAcceleratedDecoder;
  if (track.codec == MediaCodec::Hevc || track.codec == MediaCodec::H264)
    EXPECT(hardware);
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::minutes(5);
  std::uint64_t submitted{};
  for (;;) {
    auto result = source.readNext(2);
    if (auto *sample = std::get_if<MediaSample>(&result)) {
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
        require(submittedResult == VideoDecodeSubmitResult::Backpressure,
                "submit: " + error);
        {
          const auto progress = decoder.drainPresentation(2, &error);
          require(progress != VideoDecodeDrainProgress::Failed, "drain: " + error);
        }
        std::this_thread::sleep_for(std::chrono::microseconds(100));
      }
      {
        const auto progress = decoder.drainPresentation(2, &error);
        require(progress != VideoDecodeDrainProgress::Failed, "drain: " + error);
      }
    } else if (std::holds_alternative<MediaEndOfStream>(result))
      break;
    else {
      if (auto *failure = std::get_if<MediaSourceFailure>(&result))
        error = failure->error;
      fail(("source failure: " + error).c_str());
    }
  }
  auto drain = decoder.beginEndOfStream(2, &error);
  while (drain != VideoDecodeDrainProgress::Done) {
    require(drain != VideoDecodeDrainProgress::Failed, "drain: " + error);
    REQUIRE(std::chrono::steady_clock::now() < deadline);
    drain = decoder.drainEndOfStream(2, &error);
    std::this_thread::sleep_for(std::chrono::microseconds(100));
  }
  EXPECT(!sink.failed);
  EXPECT(sink.ended);
  EXPECT(submitted == sink.frames && submitted == sink.expected.size());
  std::printf("hardware=%d packets=%llu frames=%u exact_pts=%u "
              "exact_duration=%u eos=%d\n",
              hardware, submitted, sink.frames, sink.frames, sink.frames,
              sink.ended);
  decoder.close();
  source.close();
  return failures == 0 ? 0 : 1;
}
