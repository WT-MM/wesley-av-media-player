// The software WMV3 stage against the backend contract, and the libavformat
// route that admits WMV3 from ASF.
//
// No WMV3 encoder exists (FFmpeg has none), so the packets are hand-assembled
// Simple-profile 16x16 pictures, each cross-checked against FFmpeg's decoder
// when it was written: an I picture of flat luma 144, one of flat luma 145, a
// P picture whose one macroblock is skipped, and the 1-byte skipped frame.
// The ASF fixture is those packets remuxed by the test ffmpeg from an RCV
// (SMPTE 421M Annex L) file this test writes.

#include "media/media_codec_facts.hpp"
#include "platform/macos/libavformat_media_source.hpp"
#include "platform/macos/software_wmv3_decoder.hpp"
#include "platform/macos/video_decode_lane.hpp"
#include "support/expect.hpp"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <optional>
#include <spawn.h>
#include <string>
#include <sys/wait.h>
#include <vector>

extern char **environ;

namespace {

using namespace wam::macos;
using namespace wam::media;
using Bytes = std::vector<std::uint8_t>;

// STRUCT_C: Simple profile, FASTTX, FASTUVMC, RTM flag; every other tool off.
const Bytes kSequence{0x00, 0x01, 0x80, 0x01};
const Bytes kIntra144{0x00, 0x02, 0x17, 0x80};
const Bytes kIntra145{0x00, 0x02, 0x13, 0xB8, 0x00};
const Bytes kSkippedMacroblockP{0x21, 0x68, 0x00};
const Bytes kSkippedFrame{0x00};

std::span<const std::byte> view(const Bytes &bytes) {
  return std::as_bytes(std::span(bytes));
}

struct Delivered {
  CMTime pts;
  std::uint64_t generation;
  int luma;
  int cb;
};

struct Sink final : DecodedFrameSink {
  std::vector<Delivered> frames;
  std::vector<std::uint64_t> ends, flushes;
  bool backpressure{false};
  FrameEnqueueResult enqueue(FrameLease frame, std::string *) override {
    if (backpressure) {
      return FrameEnqueueResult::Backpressure;
    }
    CVPixelBufferRef buffer = frame.pixelBuffer();
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    const auto *y = static_cast<const std::uint8_t *>(
        CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
    const auto *uv = static_cast<const std::uint8_t *>(
        CVPixelBufferGetBaseAddressOfPlane(buffer, 1));
    frames.push_back({frame.timing().presentationTime, frame.timing().generation,
                      y[CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * 15 + 15],
                      uv[0]});
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return FrameEnqueueResult::Accepted;
  }
  void endOfStream(std::uint64_t generation) override { ends.push_back(generation); }
  void flush(std::uint64_t next) noexcept override { flushes.push_back(next); }
};

CMVideoFormatDescriptionRef makeDescription() {
  CMVideoFormatDescriptionRef description = nullptr;
  CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kWamVideoCodecTypeWmv3, 16,
                                 16, nullptr, &description);
  return description;
}

CMSampleBufferRef makeSample(const Bytes &bytes, CMVideoFormatDescriptionRef format,
                             std::int64_t index, bool key) {
  CMBlockBufferRef block = nullptr;
  CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, bytes.size(),
                                     kCFAllocatorDefault, nullptr, 0, bytes.size(),
                                     0, &block);
  CMBlockBufferReplaceDataBytes(bytes.data(), block, 0, bytes.size());
  CMSampleTimingInfo timing{CMTimeMake(1, 30), CMTimeMake(index, 30), kCMTimeInvalid};
  const std::size_t size = bytes.size();
  CMSampleBufferRef sample = nullptr;
  CMSampleBufferCreateReady(kCFAllocatorDefault, block, format, 1, 1, &timing, 1,
                            &size, &sample);
  CFRelease(block);
  auto entry = static_cast<CFMutableDictionaryRef>(const_cast<void *>(
      CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sample, true), 0)));
  CFDictionarySetValue(entry, kCMSampleAttachmentKey_NotSync,
                       key ? kCFBooleanFalse : kCFBooleanTrue);
  return sample;
}

VideoStreamConfiguration configuration(const Bytes &sequence, std::uint64_t generation) {
  VideoStreamConfiguration result;
  result.codec = kWamVideoCodecTypeWmv3;
  result.codedSize = {16, 16};
  result.codecConfiguration = view(sequence);
  result.generation = generation;
  return result;
}

// Submits one sample and hands its frame to the sink.
VideoDecodeSubmitResult submit(SoftwareWmv3Decoder &decoder,
                               CMVideoFormatDescriptionRef format, const Bytes &bytes,
                               std::int64_t index, bool key, std::uint64_t generation,
                               std::string *error = nullptr) {
  CMSampleBufferRef sample = makeSample(bytes, format, index, key);
  const auto result = decoder.submitCMSampleBuffer(sample, generation, error);
  CFRelease(sample);
  if (result == VideoDecodeSubmitResult::Accepted) {
    EXPECT(decoder.drainPresentation(generation, nullptr) ==
           VideoDecodeDrainProgress::Progress);
  }
  return result;
}

void testSequenceAdmission() {
  REQUIRE(SoftwareWmv3Decoder::available());
  EXPECT(SoftwareWmv3Decoder::supportsSequence(view(kSequence)));
  // Each refusal flips one STRUCT_C field the library does not implement.
  const Bytes advanced{0xC0, 0x01, 0x80, 0x01};   // PROFILE = 3
  const Bytes loopFilter{0x00, 0x09, 0x80, 0x01}; // LOOPFILTER
  const Bytes multires{0x00, 0x03, 0x80, 0x01};   // MULTIRES
  const Bytes rangeRed{0x00, 0x01, 0x80, 0x81};   // RANGERED
  const Bytes bFrames{0x00, 0x01, 0x80, 0x11};    // MAXBFRAMES = 1
  for (const Bytes *refused : {&advanced, &loopFilter, &multires, &rangeRed, &bFrames}) {
    EXPECT(!SoftwareWmv3Decoder::supportsSequence(view(*refused)));
    Sink sink;
    SoftwareWmv3Decoder decoder;
    std::string error;
    EXPECT(!decoder.configure(configuration(*refused, 1), sink, &error));
    EXPECT(!error.empty());
  }
  EXPECT(!SoftwareWmv3Decoder::supportsSequence(view(kSequence).first(3)));
}

void testDecodeContract() {
  CMVideoFormatDescriptionRef format = makeDescription();
  REQUIRE(format != nullptr);
  Sink sink;
  SoftwareWmv3Decoder decoder;
  std::string error;
  REQUIRE(decoder.configure(configuration(kSequence, 1), sink, &error));
  EXPECT(sink.flushes == std::vector<std::uint64_t>{1});
  EXPECT(decoder.stats().awaitingKeyFrame);
  EXPECT(!decoder.stats().usingHardwareAcceleratedDecoder);
  EXPECT(decoder.stats().codecReorderFrames == 0);

  // Key-frame gating: nothing decodes before the first sync sample.
  EXPECT(submit(decoder, format, kSkippedMacroblockP, 0, false, 1, &error) ==
         VideoDecodeSubmitResult::Rejected);
  EXPECT(decoder.takeLastError().has_value());
  EXPECT(!decoder.takeLastError().has_value());

  EXPECT(submit(decoder, format, kIntra144, 0, true, 1) == VideoDecodeSubmitResult::Accepted);
  EXPECT(submit(decoder, format, kSkippedMacroblockP, 1, false, 1) ==
         VideoDecodeSubmitResult::Accepted);
  // A skipped frame repeats the previous picture with its own timing.
  EXPECT(submit(decoder, format, kSkippedFrame, 2, false, 1) ==
         VideoDecodeSubmitResult::Accepted);
  EXPECT(submit(decoder, format, kIntra145, 3, true, 1) == VideoDecodeSubmitResult::Accepted);
  REQUIRE(sink.frames.size() == 4);
  const int luma[] = {144, 144, 144, 145};
  for (std::size_t i = 0; i < 4; ++i) {
    EXPECT(sink.frames[i].luma == luma[i]);
    EXPECT(sink.frames[i].cb == 144);
    EXPECT(sink.frames[i].generation == 1);
    EXPECT(CMTimeCompare(sink.frames[i].pts, CMTimeMake(std::int64_t(i), 30)) == 0);
  }

  // One converted frame at most: a second submission waits for the drain.
  sink.backpressure = true;
  CMSampleBufferRef held = makeSample(kSkippedFrame, format, 4, false);
  EXPECT(decoder.submitCMSampleBuffer(held, 1, nullptr) == VideoDecodeSubmitResult::Accepted);
  EXPECT(decoder.submitCMSampleBuffer(held, 1, nullptr) == VideoDecodeSubmitResult::Backpressure);
  EXPECT(!decoder.stats().acceptsCompressedSample);
  EXPECT(decoder.drainPresentation(1, nullptr) == VideoDecodeDrainProgress::Quiescing);
  CFRelease(held);

  // Flush retires the pending frame and re-arms the key-frame gate; a sync
  // sample that is not an I picture is refused rather than decoded against
  // the retired reference.
  decoder.flush(2);
  sink.backpressure = false;
  EXPECT(sink.flushes.back() == 2);
  EXPECT(decoder.stats().awaitingKeyFrame);
  EXPECT(decoder.drainPresentation(2, nullptr) == VideoDecodeDrainProgress::Quiescing);
  EXPECT(submit(decoder, format, kIntra144, 0, true, 1) == VideoDecodeSubmitResult::Rejected);
  EXPECT(submit(decoder, format, kSkippedFrame, 0, true, 2) == VideoDecodeSubmitResult::Rejected);
  EXPECT(submit(decoder, format, kIntra145, 10, true, 2) == VideoDecodeSubmitResult::Accepted);
  EXPECT(sink.frames.back().luma == 145 && sink.frames.back().generation == 2);

  // EOS: idempotent, delivers the pending tail frame before the end marker.
  sink.backpressure = true;
  CMSampleBufferRef tail = makeSample(kSkippedFrame, format, 11, false);
  EXPECT(decoder.submitCMSampleBuffer(tail, 2, nullptr) == VideoDecodeSubmitResult::Accepted);
  CFRelease(tail);
  EXPECT(decoder.beginEndOfStream(2, nullptr) == VideoDecodeDrainProgress::Progress);
  EXPECT(decoder.beginEndOfStream(2, nullptr) == VideoDecodeDrainProgress::Quiescing);
  EXPECT(decoder.drainEndOfStream(2, nullptr) == VideoDecodeDrainProgress::Quiescing);
  sink.backpressure = false;
  EXPECT(decoder.drainEndOfStream(2, nullptr) == VideoDecodeDrainProgress::Progress);
  EXPECT(decoder.drainEndOfStream(2, nullptr) == VideoDecodeDrainProgress::Done);
  EXPECT(decoder.beginEndOfStream(2, nullptr) == VideoDecodeDrainProgress::Done);
  EXPECT(sink.ends == std::vector<std::uint64_t>{2});
  EXPECT(sink.frames.back().luma == 145);
  EXPECT(submit(decoder, format, kIntra144, 12, true, 2) == VideoDecodeSubmitResult::Rejected);

  // Retirement: the first pair is immutable and close/flush are inert after.
  EXPECT(decoder.retire(1, 3) == VideoDecoderRetireProgress::StaleGeneration);
  EXPECT(decoder.retire(2, 3) == VideoDecoderRetireProgress::Done);
  EXPECT(decoder.retire(2, 3) == VideoDecoderRetireProgress::Done);
  EXPECT(decoder.retire(2, 4) == VideoDecoderRetireProgress::StaleGeneration);
  EXPECT(sink.flushes.back() == 3);
  const auto flushes = sink.flushes.size();
  decoder.flush(9);
  decoder.close();
  EXPECT(sink.flushes.size() == flushes);
  EXPECT(!decoder.configure(configuration(kSequence, 5), sink, nullptr));
  CFRelease(format);
}

void testLaneSelectsWmv3() {
  Sink sink;
  VideoDecodeLane lane;
  std::string error;
  REQUIRE(lane.configure(configuration(kSequence, 1), sink, &error));
  EXPECT(!lane.stats().usingHardwareAcceleratedDecoder);
  EXPECT(lane.stats().configured);
  lane.close();
  const Bytes bFrames{0x00, 0x01, 0x80, 0x11};
  EXPECT(!lane.configure(configuration(bFrames, 2), sink, &error));
}

bool run(const std::string &program, std::vector<std::string> arguments) {
  std::vector<char *> argv{const_cast<char *>(program.c_str())};
  for (auto &argument : arguments) argv.push_back(argument.data());
  argv.push_back(nullptr);
  pid_t child = 0;
  int status = 0;
  return posix_spawn(&child, program.c_str(), nullptr, nullptr, argv.data(), environ) == 0 &&
         waitpid(child, &status, 0) == child && WIFEXITED(status) &&
         WEXITSTATUS(status) == 0;
}

// An RCV file (421M Annex L) with millisecond timestamps, remuxed to ASF.
std::filesystem::path makeAsf(const std::string &ffmpeg, const std::filesystem::path &directory,
                              const char *name, const Bytes &sequence) {
  struct Frame { const Bytes *bytes; bool key; std::uint32_t ms; };
  const Frame frames[] = {{&kIntra144, true, 0},     {&kSkippedMacroblockP, false, 33},
                          {&kSkippedFrame, false, 67}, {&kSkippedMacroblockP, false, 100},
                          {&kIntra145, true, 133},   {&kSkippedFrame, false, 167}};
  Bytes rcv;
  auto le32 = [&rcv](std::uint32_t v) {
    for (int i = 0; i < 4; ++i) rcv.push_back(std::uint8_t(v >> (8 * i)));
  };
  le32(std::size(frames) | 0xC5000000U);
  le32(4);
  rcv.insert(rcv.end(), sequence.begin(), sequence.end());
  le32(16); le32(16); le32(0xC); le32(0); le32(0);
  le32(0xFFFFFFFFU); // timestamps in milliseconds
  for (const Frame &frame : frames) {
    le32(std::uint32_t(frame.bytes->size()) | (frame.key ? 0x80000000U : 0));
    le32(frame.ms);
    rcv.insert(rcv.end(), frame.bytes->begin(), frame.bytes->end());
  }
  const auto source = directory / (std::string(name) + ".rcv");
  const auto output = directory / (std::string(name) + ".wmv");
  std::ofstream(source, std::ios::binary).write(reinterpret_cast<const char *>(rcv.data()),
                                                std::streamsize(rcv.size()));
  require(run(ffmpeg, {"-v", "error", "-y", "-i", source.string(), "-c", "copy", output.string()}),
          "ffmpeg could not remux the RCV fixture to ASF");
  return output;
}

void testLibavformatRoute(const std::string &ffmpeg, const std::filesystem::path &directory) {
  std::filesystem::create_directories(directory);
  MediaSourceOpenOptions options;
  options.selection.requireAudio = false;
  {
    LibavformatMediaSource refused;
    REQUIRE(refused.armOperation(1));
    const auto opened = refused.openLocalFile(
        makeAsf(ffmpeg, directory, "wmv3-bframes", Bytes{0x00, 0x01, 0x80, 0x11}), options, 1);
    EXPECT(opened.status == MediaSourceOpenStatus::Unsupported);
    EXPECT(opened.error == "LibavformatWmv3SequenceNotAdmitted");
  }
  LibavformatMediaSource source;
  REQUIRE(source.armOperation(1));
  const auto opened = source.openLocalFile(makeAsf(ffmpeg, directory, "wmv3", kSequence), options, 1);
  require(opened.status == MediaSourceOpenStatus::Ready, "open: " + opened.error);
  const MediaTrackDescriptor &track = opened.descriptor->tracks.front();
  EXPECT(track.codec == MediaCodec::Wmv3);
  EXPECT(track.video->sampleFormat == MediaVideoSampleFormat::Yuv420EightBit);
  EXPECT(track.codecConfiguration.size() == 4);
  // ASF states presentation times only: each frame lasts until the next, the
  // last until the stream end the header states (200 ms).
  EXPECT(compareMediaTime(opened.descriptor->duration, MediaTime{200, 1000}) ==
         MediaTimeOrder::Equal);
  const std::int64_t pts[] = {0, 33, 67, 100, 133, 167}, duration[] = {33, 34, 33, 33, 34, 33};
  std::size_t index = 0;
  for (;;) {
    auto result = source.readNext(1);
    auto *sample = std::get_if<MediaSample>(&result);
    if (!sample) {
      EXPECT(std::holds_alternative<MediaEndOfStream>(result));
      break;
    }
    REQUIRE(index < 6);
    EXPECT(compareMediaTime(sample->presentationTime, {pts[index], 1000}) == MediaTimeOrder::Equal);
    EXPECT(compareMediaTime(sample->duration, {duration[index], 1000}) == MediaTimeOrder::Equal);
    EXPECT(sample->keyFrame == (index == 0 || index == 4));
    ++index;
  }
  EXPECT(index == 6);

  // An accurate seek lands on the second key frame and decodes through the
  // lane: the skipped frame after it repeats luma 145.
  REQUIRE(source.armOperation(2));
  REQUIRE(source.seek({2, {170, 1000}, MediaSeekMode::Accurate}).accepted);
  Sink sink;
  VideoDecodeLane lane;
  VideoStreamConfiguration config = configuration(kSequence, 2);
  config.codecConfiguration = track.codecConfiguration;
  config.codec = mediaCodecFacts(track.codec).coreMediaType;
  std::string error;
  REQUIRE(lane.configure(config, sink, &error));
  for (;;) {
    auto result = source.readNext(2);
    auto *sample = std::get_if<MediaSample>(&result);
    if (!sample) break;
    const auto payload = sample->payload.borrowNative<NativePayloadKind::CoreMediaSampleBuffer>();
    REQUIRE(payload);
    auto buffer = static_cast<CMSampleBufferRef>(const_cast<void *>(payload->opaqueAddress()));
    require(lane.submitCMSampleBuffer(buffer, 2, &error) == VideoDecodeSubmitResult::Accepted,
            "submit: " + error);
    EXPECT(lane.drainPresentation(2, nullptr) == VideoDecodeDrainProgress::Progress);
  }
  REQUIRE(sink.frames.size() == 2);
  EXPECT(CMTimeCompare(sink.frames[0].pts, CMTimeMake(133, 1000)) == 0);
  EXPECT(CMTimeCompare(sink.frames[1].pts, CMTimeMake(167, 1000)) == 0);
  EXPECT(sink.frames[0].luma == 145 && sink.frames[1].luma == 145);
  lane.close();
  source.close();
}

} // namespace

int main(int argc, char **argv) {
  testSequenceAdmission();
  testDecodeContract();
  testLaneSelectsWmv3();
  if (argc == 3) {
    testLibavformatRoute(argv[1], argv[2]);
  }
  if (failures == 0) {
    std::cout << "software WMV3 stage: ok\n";
  }
  return failures == 0 ? 0 : 1;
}
