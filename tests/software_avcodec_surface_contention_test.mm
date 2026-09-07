#include "platform/macos/software_avcodec_video_decoder.hpp"
#include "platform/macos/native_surface_budget.hpp"
#include "media/video_codec_configuration.hpp"
#include <chrono>
#include <cstdio>
#include <fstream>
#include <thread>
#include <vector>
using namespace wam::macos;
#define REQUIRE(x) do { if (!(x)) { std::fprintf(stderr, "FAIL %d: %s (%s)\n", __LINE__, #x, error.c_str()); return 1; } } while (false)
struct Sink final : DecodedFrameSink {
  unsigned frames{};
  bool exact{true}, ended{};
  FrameEnqueueResult enqueue(FrameLease frame, std::string*) override {
    exact &= frame && frame.timing().generation == 1 &&
        CMTimeCompare(frame.timing().presentationTime, CMTimeMake(0, 1000)) == 0 &&
        CMTimeCompare(frame.timing().duration, CMTimeMake(40, 1000)) == 0;
    ++frames;
    return FrameEnqueueResult::Accepted;
  }
  void endOfStream(std::uint64_t) override { ended = true; }
  void flush(std::uint64_t) noexcept override {}
};
template<class T> T read(std::ifstream& file) {
  T value{}; file.read(reinterpret_cast<char*>(&value), sizeof(value)); return value;
}
int main(int argc, char** argv) {
  std::string error;
  REQUIRE(argc == 2);
  std::ifstream file(argv[1], std::ios::binary);
  const auto extraSize = read<unsigned>(file);
  REQUIRE(read<unsigned>(file) > 0);
  std::vector<std::byte> rawExtra(extraSize);
  file.read(reinterpret_cast<char*>(rawExtra.data()), extraSize);
  std::vector<std::byte> extra(extraSize + wam::media::kMpeg4VisualEsdsOverheadBytes);
  std::size_t esdsSize{};
  wam::media::VideoCodecConfigurationLimits limits;
  limits.admitSoftwareProfiles = true;
  REQUIRE(wam::media::buildMpeg4VisualEsds(rawExtra, extra, &esdsSize, limits));
  const auto size = read<unsigned>(file);
  const auto pts = read<std::int64_t>(file), dts = read<std::int64_t>(file), duration = read<std::int64_t>(file);
  std::vector<std::byte> bytes(size);
  file.read(reinterpret_cast<char*>(bytes.data()), size);
  REQUIRE(file.good());
  CMBlockBufferRef block{};
  CMSampleBufferRef sample{};
  REQUIRE(CMBlockBufferCreateWithMemoryBlock(nullptr, bytes.data(), size, kCFAllocatorNull, nullptr, 0, size, 0, &block) == 0);
  CMSampleTimingInfo timing{CMTimeMake(duration, 1000), CMTimeMake(pts, 1000), CMTimeMake(dts, 1000)};
  const std::size_t byteCount = size;
  REQUIRE(CMSampleBufferCreateReady(nullptr, block, nullptr, 1, 1, &timing, 1, &byteCount, &sample) == 0);
  VideoStreamConfiguration config;
  config.codec = 'mp4v'; config.codedSize = {320, 180}; config.codecConfiguration = extra; config.generation = 1;
  for (bool cancel : {false, true}) {
    Sink sink;
    SoftwareAvcodecVideoDecoder decoder;
    REQUIRE(decoder.configure(config, sink, &error));
    const auto before = NativeSurfaceBudget::stats().rejections;
    REQUIRE(NativeSurfaceBudgetTestAccess::holdInsertionReservation());
    REQUIRE(decoder.submitCMSampleBuffer(sample, 1, &error) == VideoDecodeSubmitResult::Accepted);
    REQUIRE(decoder.beginEndOfStream(1, &error) != VideoDecodeDrainProgress::Failed);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (NativeSurfaceBudget::stats().rejections == before) {
      REQUIRE(std::chrono::steady_clock::now() < deadline);
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    const auto progress = decoder.drainPresentation(1, &error);
    if (cancel) decoder.close();
    NativeSurfaceBudgetTestAccess::releaseInsertionReservation();
    REQUIRE(progress != VideoDecodeDrainProgress::Failed);
    if (!cancel) {
      REQUIRE(decoder.beginEndOfStream(1, &error) != VideoDecodeDrainProgress::Failed);
      while (!sink.ended) {
        REQUIRE(std::chrono::steady_clock::now() < deadline);
        REQUIRE(decoder.drainEndOfStream(1, &error) != VideoDecodeDrainProgress::Failed);
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
      REQUIRE(sink.frames == 1 && sink.exact);
      decoder.close();
    }
    REQUIRE(NativeSurfaceBudget::stats().currentSurfaces == 0);
    REQUIRE(NativeSurfaceBudget::stats().currentBytes == 0);
  }
  CFRelease(sample); CFRelease(block);
  std::puts("PASS insertion contention retains exact frame; cancellation retires every lease");
}
