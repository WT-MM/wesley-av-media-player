#include "platform/macos/video_toolbox_decoder.hpp"

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include <sys/mman.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <mutex>
#include <span>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

void check(bool condition, const char *expression, int line,
           const std::string &detail = {}) {
  if (!condition) {
    std::cerr << "CHECK failed at line " << line << ": " << expression;
    if (!detail.empty()) {
      std::cerr << " (" << detail << ')';
    }
    std::cerr << '\n';
    std::exit(EXIT_FAILURE);
  }
}

#define WAM_CHECK(expression)                                                  \
  check(static_cast<bool>(expression), #expression, __LINE__)
#define WAM_CHECK_DETAIL(expression, detail)                                   \
  check(static_cast<bool>(expression), #expression, __LINE__, (detail))

struct OwnedPacket {
  std::vector<std::byte> bytes;
  CMTime presentationTime{kCMTimeInvalid};
  CMTime decodeTime{kCMTimeInvalid};
  CMTime duration{kCMTimeInvalid};
  bool keyFrame{false};
};

struct DemuxedVideo {
  CMVideoCodecType codec{0};
  CMVideoDimensions dimensions{0, 0};
  std::vector<std::byte> configuration;
  std::vector<OwnedPacket> packets;
};

bool sampleIsKeyFrame(CMSampleBufferRef sample) {
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(sample, false);
  if (attachments == nullptr || CFArrayGetCount(attachments) == 0) {
    return true;
  }
  auto attachment =
      static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
  auto notSync = static_cast<CFBooleanRef>(
      CFDictionaryGetValue(attachment, kCMSampleAttachmentKey_NotSync));
  return notSync == nullptr || !CFBooleanGetValue(notSync);
}

DemuxedVideo readCompressedH264(const char *path) {
  NSString *filePath = [NSString stringWithUTF8String:path];
  NSURL *url = [NSURL fileURLWithPath:filePath];
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  NSArray<AVAssetTrack *> *tracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
#pragma clang diagnostic pop
  WAM_CHECK(tracks.count > 0);
  AVAssetTrack *track = tracks.firstObject;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  NSArray *formatDescriptions = track.formatDescriptions;
#pragma clang diagnostic pop
  WAM_CHECK(formatDescriptions.count > 0);
  CMVideoFormatDescriptionRef sourceFormat =
      (__bridge CMVideoFormatDescriptionRef)formatDescriptions.firstObject;
  WAM_CHECK(sourceFormat != nullptr);

  DemuxedVideo video;
  video.codec = CMFormatDescriptionGetMediaSubType(sourceFormat);
  video.dimensions = CMVideoFormatDescriptionGetDimensions(sourceFormat);
  CFDictionaryRef extensions = CMFormatDescriptionGetExtensions(sourceFormat);
  auto atoms = static_cast<CFDictionaryRef>(CFDictionaryGetValue(
      extensions,
      kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms));
  const CFStringRef atomName =
      video.codec == kCMVideoCodecType_H264 ? CFSTR("avcC") : CFSTR("hvcC");
  auto atom = static_cast<CFDataRef>(CFDictionaryGetValue(atoms, atomName));
  WAM_CHECK(atom != nullptr);
  const CFIndex configurationLength = CFDataGetLength(atom);
  video.configuration.resize(static_cast<std::size_t>(configurationLength));
  std::memcpy(video.configuration.data(), CFDataGetBytePtr(atom),
              video.configuration.size());

  NSError *readerError = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset
                                                         error:&readerError];
  WAM_CHECK_DETAIL(
      reader != nil,
      readerError == nil
          ? std::string("unknown AVAssetReader error")
          : std::string(readerError.localizedDescription.UTF8String));
  AVAssetReaderTrackOutput *output =
      [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:nil];
  output.alwaysCopiesSampleData = NO;
  WAM_CHECK([reader canAddOutput:output]);
  [reader addOutput:output];
  WAM_CHECK([reader startReading]);

  for (std::size_t readAttempt = 0;
       readAttempt < 64 && video.packets.size() < 24; ++readAttempt) {
    CMSampleBufferRef sample = [output copyNextSampleBuffer];
    if (sample == nullptr) {
      break;
    }

    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    // AVAssetReader may emit format/discontinuity samples without media data.
    if (block == nullptr || CMBlockBufferGetDataLength(block) == 0) {
      CFRelease(sample);
      continue;
    }
    OwnedPacket packet;
    packet.bytes.resize(CMBlockBufferGetDataLength(block));
    const OSStatus copyStatus = CMBlockBufferCopyDataBytes(
        block, 0, packet.bytes.size(), packet.bytes.data());
    WAM_CHECK(copyStatus == noErr);
    packet.presentationTime = CMSampleBufferGetPresentationTimeStamp(sample);
    packet.decodeTime = CMSampleBufferGetDecodeTimeStamp(sample);
    packet.duration = CMSampleBufferGetDuration(sample);
    packet.keyFrame = sampleIsKeyFrame(sample);
    video.packets.push_back(std::move(packet));
    CFRelease(sample);
  }

  WAM_CHECK(reader.status == AVAssetReaderStatusReading ||
            reader.status == AVAssetReaderStatusCompleted);
  WAM_CHECK(video.codec == kCMVideoCodecType_H264);
  WAM_CHECK(video.dimensions.width > 0 && video.dimensions.height > 0);
  WAM_CHECK(!video.configuration.empty());
  WAM_CHECK(video.packets.size() >= 3);
  return video;
}

wam::macos::VideoStreamConfiguration
streamConfiguration(const DemuxedVideo &video, std::uint64_t generation,
                    bool requireHardware) {
  return {video.codec,
          video.dimensions,
          std::span<const std::byte>(video.configuration),
          true,
          requireHardware,
          generation};
}

wam::macos::CompressedVideoPacket packetView(const OwnedPacket &packet,
                                             std::uint64_t generation) {
  return {std::span<const std::byte>(packet.bytes),
          packet.presentationTime,
          packet.decodeTime,
          packet.duration,
          generation,
          packet.keyFrame,
          false};
}

wam::macos::CompressedVideoPacket endOfStream(std::uint64_t generation) {
  wam::macos::CompressedVideoPacket packet;
  packet.generation = generation;
  packet.endOfStream = true;
  return packet;
}

std::size_t firstKeyFrame(const DemuxedVideo &video) {
  for (std::size_t index = 0; index < video.packets.size(); ++index) {
    if (video.packets[index].keyFrame) {
      return index;
    }
  }
  return video.packets.size();
}

bool earlier(CMTime left, CMTime right) {
  return CMTIME_IS_VALID(left) && CMTIME_IS_VALID(right) &&
         CMTimeCompare(left, right) < 0;
}

void testConfigurationByteBound(const DemuxedVideo &video) {
  constexpr std::uint64_t generation = 5;
  constexpr std::size_t oversizedConfigurationBytes = 1024ULL * 1024ULL + 1ULL;
  void *inaccessibleBytes =
      mmap(nullptr, oversizedConfigurationBytes, PROT_NONE,
           MAP_PRIVATE | MAP_ANON, -1, 0);
  WAM_CHECK(inaccessibleBytes != MAP_FAILED);

  wam::macos::BoundedFrameQueue queue(1, generation);
  wam::macos::VideoToolboxDecoder decoder;
  auto configuration = streamConfiguration(video, generation, false);
  configuration.codecConfiguration = std::span<const std::byte>(
      static_cast<const std::byte *>(inaccessibleBytes),
      oversizedConfigurationBytes);
  std::string error;
  WAM_CHECK(!decoder.configure(configuration, queue, &error));
  WAM_CHECK(!error.empty());
  WAM_CHECK(munmap(inaccessibleBytes, oversizedConfigurationBytes) == 0);
}

void testBFramePresentationOrderAndMetalImport(const DemuxedVideo &video,
                                               std::size_t keyIndex,
                                               bool requireHardware) {
  constexpr std::uint64_t generation = 40;
  const std::size_t packetCount = video.packets.size() - keyIndex;
  WAM_CHECK(packetCount >= 3);

  bool decodeOrderDiffersFromPresentationOrder = false;
  for (std::size_t index = keyIndex + 1; index < video.packets.size();
       ++index) {
    decodeOrderDiffersFromPresentationOrder |=
        earlier(video.packets[index].presentationTime,
                video.packets[index - 1].presentationTime);
  }
  WAM_CHECK_DETAIL(decodeOrderDiffersFromPresentationOrder,
                   "H.264 fixture must contain B-frame PTS reordering");

  wam::macos::BoundedFrameQueue queue(packetCount + 1, generation);
  wam::macos::VideoToolboxDecoder decoder({packetCount + 1});
  std::string error;
  WAM_CHECK_DETAIL(
      decoder.configure(streamConfiguration(video, generation, requireHardware),
                        queue, &error),
      error);

  for (std::size_t index = keyIndex; index < video.packets.size(); ++index) {
    WAM_CHECK_DETAIL(
        decoder.submit(packetView(video.packets[index], generation), &error) ==
            wam::macos::VideoDecodeSubmitResult::Accepted,
        error);
  }
  WAM_CHECK_DETAIL(decoder.submit(endOfStream(generation), &error) ==
                       wam::macos::VideoDecodeSubmitResult::Accepted,
                   error);

  const wam::macos::VideoToolboxDecoderStats stats = decoder.stats();
  WAM_CHECK(stats.submittedFrames == packetCount);
  WAM_CHECK(stats.deliveredFrames == packetCount);
  WAM_CHECK(stats.droppedFrames == 0);
  WAM_CHECK(stats.outOfOrderDrops == 0);
  WAM_CHECK(stats.requestedOutputPixelFormat ==
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
  WAM_CHECK(stats.actualOutputPixelFormat ==
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);

  auto metalCache = wam::macos::MetalTextureCache::create(nullptr, &error);
  WAM_CHECK_DETAIL(metalCache != nullptr, error);

  std::vector<CMTime> outputTimes;
  outputTimes.reserve(packetCount);
  while (auto frame = queue.tryTake()) {
    WAM_CHECK(frame->isIOSurfaceBacked());
    WAM_CHECK(frame->pixelFormat() == stats.actualOutputPixelFormat);
    WAM_CHECK(CMTIME_IS_VALID(frame->timing().presentationTime));
    WAM_CHECK(CMTIME_IS_VALID(frame->timing().duration));
    if (!outputTimes.empty()) {
      WAM_CHECK(!earlier(frame->timing().presentationTime, outputTimes.back()));
    }
    outputTimes.push_back(frame->timing().presentationTime);

    auto metalFrame = metalCache->importFrame(*frame, &error);
    WAM_CHECK_DETAIL(metalFrame.has_value(), error);
    WAM_CHECK(metalFrame->planeCount() == 2);
    WAM_CHECK(metalFrame->nativeTexture(0) != nullptr);
    WAM_CHECK(metalFrame->nativeTexture(1) != nullptr);
  }
  WAM_CHECK(outputTimes.size() == packetCount);

  std::vector<CMTime> expectedTimes;
  expectedTimes.reserve(packetCount);
  for (std::size_t index = keyIndex; index < video.packets.size(); ++index) {
    expectedTimes.push_back(video.packets[index].presentationTime);
  }
  std::sort(expectedTimes.begin(), expectedTimes.end(),
            [](CMTime left, CMTime right) { return earlier(left, right); });
  for (std::size_t index = 0; index < expectedTimes.size(); ++index) {
    WAM_CHECK(CMTimeCompare(outputTimes[index], expectedTimes[index]) == 0);
  }
  WAM_CHECK(queue.reachedEndOfStream());
  decoder.close();
}

void testSinkBackpressureIsRecoverable(const DemuxedVideo &video,
                                       std::size_t keyIndex,
                                       bool requireHardware) {
  constexpr std::uint64_t firstGeneration = 50;
  constexpr std::uint64_t secondGeneration = 51;
  wam::macos::BoundedFrameQueue queue(1, firstGeneration);
  wam::macos::VideoToolboxDecoder decoder({video.packets.size() + 1});
  std::string error;
  WAM_CHECK_DETAIL(decoder.configure(streamConfiguration(video, firstGeneration,
                                                         requireHardware),
                                     queue, &error),
                   error);
  for (std::size_t index = keyIndex; index < video.packets.size(); ++index) {
    WAM_CHECK_DETAIL(
        decoder.submit(packetView(video.packets[index], firstGeneration),
                       &error) == wam::macos::VideoDecodeSubmitResult::Accepted,
        error);
  }
  WAM_CHECK_DETAIL(decoder.submit(endOfStream(firstGeneration), &error) ==
                       wam::macos::VideoDecodeSubmitResult::Accepted,
                   error);
  WAM_CHECK(decoder.stats().sinkBackpressureDrops > 0);
  WAM_CHECK(decoder.stats().droppedFrames ==
            decoder.stats().sinkBackpressureDrops);
  WAM_CHECK(!decoder.takeLastError().has_value());

  decoder.flush(secondGeneration);
  WAM_CHECK_DETAIL(
      decoder.submit(packetView(video.packets[keyIndex], secondGeneration),
                     &error) == wam::macos::VideoDecodeSubmitResult::Accepted,
      error);
  WAM_CHECK_DETAIL(decoder.submit(endOfStream(secondGeneration), &error) ==
                       wam::macos::VideoDecodeSubmitResult::Accepted,
                   error);
  WAM_CHECK(queue.tryTake().has_value());
  WAM_CHECK(!decoder.takeLastError().has_value());
  decoder.close();
}

void testAdmissionBeforeCopy(const DemuxedVideo &video, std::size_t keyIndex,
                             bool requireHardware) {
  constexpr std::uint64_t generation = 6;
  wam::macos::BoundedFrameQueue queue(2, generation);
  wam::macos::VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = 1;
  wam::macos::VideoToolboxDecoder decoder(options);
  std::string error;
  WAM_CHECK_DETAIL(
      decoder.configure(streamConfiguration(video, generation, requireHardware),
                        queue, &error),
      error);

  // The test-only source build can reserve the decoder's one real admission
  // slot without depending on whether VideoToolbox invokes callbacks inline.
  WAM_CHECK_DETAIL(
      wam::macos::VideoToolboxDecoderTestAccess::occupyInFlightCapacity(
          decoder, &error),
      error);
  WAM_CHECK(decoder.stats().inFlightFrames == 1);

  wam::macos::CompressedVideoPacket guardedPacket =
      packetView(video.packets[keyIndex], generation);
  const long pageSize = sysconf(_SC_PAGESIZE);
  WAM_CHECK(pageSize > 0);
  void *inaccessibleBytes = mmap(nullptr, static_cast<std::size_t>(pageSize),
                                 PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
  WAM_CHECK(inaccessibleBytes != MAP_FAILED);
  guardedPacket.bytes = std::span<const std::byte>(
      static_cast<const std::byte *>(inaccessibleBytes),
      static_cast<std::size_t>(pageSize));
  WAM_CHECK(decoder.submit(guardedPacket, &error) ==
            wam::macos::VideoDecodeSubmitResult::Backpressure);
  WAM_CHECK(munmap(inaccessibleBytes, static_cast<std::size_t>(pageSize)) == 0);
  WAM_CHECK(error.empty());
  WAM_CHECK(decoder.stats().inFlightFrames == 1);
  WAM_CHECK(decoder.stats().backpressuredSubmissions == 1);
  WAM_CHECK(!decoder.takeLastError().has_value());

  WAM_CHECK_DETAIL(
      wam::macos::VideoToolboxDecoderTestAccess::releaseInFlightCapacity(
          decoder, &error),
      error);
  WAM_CHECK(decoder.stats().inFlightFrames == 0);

  // A media-controlled packet larger than the decoder contract must reject
  // before touching or copying its payload. PROT_NONE turns that ordering into
  // a deterministic safety assertion without allocating 32 MiB of resident RAM.
  constexpr std::size_t oversizedPacketBytes =
      32ULL * 1024ULL * 1024ULL + 1ULL;
  void *oversizedBytes = mmap(nullptr, oversizedPacketBytes, PROT_NONE,
                              MAP_PRIVATE | MAP_ANON, -1, 0);
  WAM_CHECK(oversizedBytes != MAP_FAILED);
  auto oversizedPacket = packetView(video.packets[keyIndex], generation);
  oversizedPacket.bytes = std::span<const std::byte>(
      static_cast<const std::byte *>(oversizedBytes), oversizedPacketBytes);
  WAM_CHECK(decoder.submit(oversizedPacket, &error) ==
            wam::macos::VideoDecodeSubmitResult::Rejected);
  WAM_CHECK(error.find("32 MiB") != std::string::npos);
  WAM_CHECK(munmap(oversizedBytes, oversizedPacketBytes) == 0);

  // Removing the synthetic reservation must leave the real decode lifecycle
  // usable; this catches a seam that accidentally poisons production state.
  WAM_CHECK_DETAIL(
      decoder.submit(packetView(video.packets[keyIndex], generation), &error) ==
          wam::macos::VideoDecodeSubmitResult::Accepted,
      error);
  WAM_CHECK_DETAIL(decoder.submit(endOfStream(generation), &error) ==
                       wam::macos::VideoDecodeSubmitResult::Accepted,
                   error);
  WAM_CHECK(decoder.stats().submittedFrames == 1);
  WAM_CHECK(decoder.stats().inFlightFrames == 0);
  WAM_CHECK(queue.tryTake().has_value());
  decoder.close();
}

class GatedSink final : public wam::macos::DecodedFrameSink {
public:
  GatedSink(std::atomic<bool> &submissionActive, std::uint64_t generation)
      : submissionActive_(submissionActive), queue_(4, generation) {}

  wam::macos::FrameEnqueueResult enqueue(wam::macos::FrameLease frame,
                                         std::string *error) override {
    {
      std::unique_lock lock(mutex_);
      callbackEntered_ = true;
      callbackOverlappedSubmit_ =
          submissionActive_.load(std::memory_order_acquire);
      condition_.notify_all();
      condition_.wait(lock, [this] { return released_; });
    }
    return queue_.enqueue(std::move(frame), error);
  }

  void endOfStream(std::uint64_t generation) override {
    queue_.endOfStream(generation);
  }

  void flush(std::uint64_t nextGeneration) noexcept override {
    queue_.flush(nextGeneration);
  }

  bool waitForCallback() {
    std::unique_lock lock(mutex_);
    return condition_.wait_for(lock, std::chrono::seconds(5),
                               [this] { return callbackEntered_; });
  }

  bool callbackOverlappedSubmit() {
    std::lock_guard lock(mutex_);
    return callbackOverlappedSubmit_;
  }

  void release() {
    std::lock_guard lock(mutex_);
    released_ = true;
    condition_.notify_all();
  }

  std::optional<wam::macos::FrameLease> tryTake() { return queue_.tryTake(); }

private:
  std::atomic<bool> &submissionActive_;
  wam::macos::BoundedFrameQueue queue_;
  std::mutex mutex_;
  std::condition_variable condition_;
  bool callbackEntered_{false};
  bool callbackOverlappedSubmit_{false};
  bool released_{false};
};

void testCallbackScheduling(const DemuxedVideo &video, std::size_t keyIndex,
                            bool requireHardware,
                            bool allowAsynchronousDecode) {
  constexpr std::uint64_t generation = 7;
  std::atomic<bool> submissionActive{false};
  GatedSink sink(submissionActive, generation);
  wam::macos::VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = 1;
  options.enableAsynchronousDecompression = allowAsynchronousDecode;
  // This test controls presentation ordering itself. Disabling temporal
  // processing prevents a decoder from legally retaining the first packet
  // indefinitely while preserving the production default everywhere else.
  options.enableTemporalProcessing = false;
  wam::macos::VideoToolboxDecoder decoder(options);
  std::string configurationError;
  WAM_CHECK_DETAIL(
      decoder.configure(streamConfiguration(video, generation, requireHardware),
                        sink, &configurationError),
      configurationError);

  const std::size_t deliveryIndex = keyIndex + 1;
  WAM_CHECK(deliveryIndex < video.packets.size());

  struct SubmissionResults {
    wam::macos::VideoDecodeSubmitResult first{
        wam::macos::VideoDecodeSubmitResult::Rejected};
    wam::macos::VideoDecodeSubmitResult second{
        wam::macos::VideoDecodeSubmitResult::Rejected};
    std::string error;
  } results;

  std::thread submitter([&] {
    @autoreleasepool {
      auto trackedSubmit = [&](const wam::macos::CompressedVideoPacket &packet) {
        submissionActive.store(true, std::memory_order_release);
        const auto result = decoder.submit(packet, &results.error);
        submissionActive.store(false, std::memory_order_release);
        return result;
      };

      results.first =
          trackedSubmit(packetView(video.packets[keyIndex], generation));
      if (results.first != wam::macos::VideoDecodeSubmitResult::Accepted) {
        return;
      }

      // With temporal processing disabled the first output callback cannot be
      // retained indefinitely. Waiting for it here makes the second accepted
      // packet the sole in-flight frame, regardless of decoder speed.
      const auto callbackDeadline =
          std::chrono::steady_clock::now() + std::chrono::seconds(5);
      while (decoder.stats().inFlightFrames != 0 &&
             std::chrono::steady_clock::now() < callbackDeadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
      if (decoder.stats().inFlightFrames != 0) {
        results.error = "first non-temporal callback did not complete";
        return;
      }
      results.second =
          trackedSubmit(packetView(video.packets[deliveryIndex], generation));
    }
  });

  const bool callbackArrived = sink.waitForCallback();
  const bool callbackOverlappedSubmit =
      callbackArrived && sink.callbackOverlappedSubmit();

  // Always release before joining: a conforming decoder may invoke the output
  // handler inline, in which case submitter owns operationMutex until enqueue()
  // returns. The former main-thread wait was the Intel CI deadlock.
  sink.release();
  submitter.join();
  WAM_CHECK_DETAIL(callbackArrived, "decoded-frame callback did not arrive");
  WAM_CHECK_DETAIL(
      results.first == wam::macos::VideoDecodeSubmitResult::Accepted,
      results.error);
  WAM_CHECK_DETAIL(
      results.second == wam::macos::VideoDecodeSubmitResult::Accepted,
      results.error);
  if (!allowAsynchronousDecode) {
    WAM_CHECK_DETAIL(
        callbackOverlappedSubmit,
        "synchronous VideoToolbox mode returned before its output callback");
  }
  WAM_CHECK(!decoder.takeLastError().has_value());

  std::string error;
  WAM_CHECK_DETAIL(decoder.submit(endOfStream(generation), &error) ==
                       wam::macos::VideoDecodeSubmitResult::Accepted,
                   error);
  WAM_CHECK(decoder.stats().inFlightFrames == 0);
  auto frame = sink.tryTake();
  WAM_CHECK(frame.has_value());
  WAM_CHECK(frame->isIOSurfaceBacked());
  WAM_CHECK(frame->timing().generation == generation);
  decoder.close();
  decoder.close();
  WAM_CHECK(!decoder.stats().configured);
}

void testLifecycleAndGeneration(const DemuxedVideo &video, std::size_t keyIndex,
                                bool requireHardware) {
  constexpr std::uint64_t firstGeneration = 20;
  constexpr std::uint64_t secondGeneration = 21;
  wam::macos::BoundedFrameQueue queue(8, firstGeneration);
  wam::macos::VideoToolboxDecoder decoder({4});
  std::string error;
  WAM_CHECK_DETAIL(decoder.configure(streamConfiguration(video, firstGeneration,
                                                         requireHardware),
                                     queue, &error),
                   error);
  WAM_CHECK(decoder.stats().configured);
  if (requireHardware) {
    WAM_CHECK(decoder.stats().usingHardwareAcceleratedDecoder);
  }
  WAM_CHECK_DETAIL(
      decoder.submit(packetView(video.packets[keyIndex], firstGeneration),
                     &error) == wam::macos::VideoDecodeSubmitResult::Accepted,
      error);
  WAM_CHECK_DETAIL(decoder.submit(endOfStream(firstGeneration), &error) ==
                       wam::macos::VideoDecodeSubmitResult::Accepted,
                   error);
  auto firstFrame = queue.tryTake();
  WAM_CHECK(firstFrame.has_value());
  WAM_CHECK(firstFrame->isIOSurfaceBacked());
  WAM_CHECK(firstFrame->timing().generation == firstGeneration);

  decoder.flush(secondGeneration);
  WAM_CHECK(queue.generation() == secondGeneration);
  WAM_CHECK(decoder.stats().generation == secondGeneration);
  WAM_CHECK(decoder.stats().awaitingKeyFrame);
  WAM_CHECK(decoder.submit(packetView(video.packets[keyIndex], firstGeneration),
                           &error) ==
            wam::macos::VideoDecodeSubmitResult::Rejected);
  WAM_CHECK(error == "compressed packet belongs to a stale generation");

  std::size_t nonKeyIndex = keyIndex + 1;
  while (nonKeyIndex < video.packets.size() &&
         video.packets[nonKeyIndex].keyFrame) {
    ++nonKeyIndex;
  }
  WAM_CHECK(nonKeyIndex < video.packets.size());
  WAM_CHECK(
      decoder.submit(packetView(video.packets[nonKeyIndex], secondGeneration),
                     &error) == wam::macos::VideoDecodeSubmitResult::Rejected);
  WAM_CHECK(error == "decoder requires a key frame after configure or flush");

  WAM_CHECK_DETAIL(
      decoder.submit(packetView(video.packets[keyIndex], secondGeneration),
                     &error) == wam::macos::VideoDecodeSubmitResult::Accepted,
      error);
  WAM_CHECK_DETAIL(decoder.submit(endOfStream(secondGeneration), &error) ==
                       wam::macos::VideoDecodeSubmitResult::Accepted,
                   error);
  auto secondFrame = queue.tryTake();
  WAM_CHECK(secondFrame.has_value());
  WAM_CHECK(secondFrame->isIOSurfaceBacked());
  WAM_CHECK(secondFrame->timing().generation == secondGeneration);
  WAM_CHECK(decoder.stats().inFlightFrames == 0);
  WAM_CHECK(!decoder.takeLastError().has_value());

  decoder.close();
  WAM_CHECK(!decoder.stats().configured);
  WAM_CHECK(
      decoder.submit(packetView(video.packets[keyIndex], secondGeneration),
                     &error) == wam::macos::VideoDecodeSubmitResult::Rejected);
  WAM_CHECK(error == "VideoToolbox decoder is not configured");
}

void testHevcConfiguration(bool requireHardware) {
  // Valid Main-profile hvcC containing VPS/SPS/PPS (the optional SEI array was
  // removed from the source configuration record).
  static const std::uint8_t hvcC[] = {
      0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x96, 0xf0, 0x00, 0xfc, 0xfd, 0xf8, 0xf8, 0x00, 0x00, 0x0f, 0x03, 0xa0,
      0x00, 0x01, 0x00, 0x18, 0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x01, 0x60,
      0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00,
      0x96, 0x95, 0x98, 0x09, 0xa1, 0x00, 0x01, 0x00, 0x2f, 0x42, 0x01, 0x01,
      0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00,
      0x03, 0x00, 0x96, 0xa0, 0x01, 0xe0, 0x20, 0x02, 0x1c, 0x59, 0x65, 0x66,
      0x92, 0x4c, 0xaf, 0xff, 0x04, 0x38, 0x03, 0x59, 0x01, 0x00, 0x00, 0x03,
      0x00, 0x01, 0x00, 0x00, 0x03, 0x00, 0x18, 0x08, 0xa2, 0x00, 0x01, 0x00,
      0x07, 0x44, 0x01, 0xc1, 0x72, 0xb4, 0x62, 0x40};

  constexpr std::uint64_t generation = 30;
  wam::macos::BoundedFrameQueue queue(2, generation);
  wam::macos::VideoToolboxDecoder decoder({2});
  wam::macos::VideoStreamConfiguration configuration;
  configuration.codec = kCMVideoCodecType_HEVC;
  configuration.codedSize = {3840, 2160};
  configuration.codecConfiguration = std::span<const std::byte>(
      reinterpret_cast<const std::byte *>(hvcC), sizeof(hvcC));
  configuration.preferHardwareDecode = true;
  configuration.requireHardwareDecode = requireHardware;
  configuration.generation = generation;
  std::string error;
  WAM_CHECK_DETAIL(decoder.configure(configuration, queue, &error), error);
  WAM_CHECK(decoder.stats().configured);
  if (requireHardware) {
    WAM_CHECK(decoder.stats().usingHardwareAcceleratedDecoder);
  }
  decoder.close();
  WAM_CHECK(!decoder.stats().configured);
}

} // namespace

int main(int argc, char **argv) {
  if (argc != 2) {
    std::cerr << "usage: wam_video_toolbox_decoder_test sample-h264.mp4\n";
    return EXIT_FAILURE;
  }

  DemuxedVideo video = readCompressedH264(argv[1]);
  const std::size_t keyIndex = firstKeyFrame(video);
  WAM_CHECK(keyIndex < video.packets.size());

  const bool h264Hardware = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264);
  const bool hevcHardware = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
  testConfigurationByteBound(video);
  testAdmissionBeforeCopy(video, keyIndex, h264Hardware);
  testCallbackScheduling(video, keyIndex, h264Hardware, true);
  testCallbackScheduling(video, keyIndex, h264Hardware, false);
  testLifecycleAndGeneration(video, keyIndex, h264Hardware);
  testBFramePresentationOrderAndMetalImport(video, keyIndex, h264Hardware);
  testSinkBackpressureIsRecoverable(video, keyIndex, h264Hardware);
  testHevcConfiguration(hevcHardware);

  std::cout << "VideoToolbox H.264 B-frame ordering, zero-copy Metal import, "
               "HEVC configuration, bounded backpressure, flush, and shutdown "
               "passed\n";
  return EXIT_SUCCESS;
}
