#include "platform/macos/video_toolbox_decoder.hpp"
#include "platform/macos/native_video_decode_plan.hpp"
#import <AVFoundation/AVFoundation.h>
#include <chrono>
#include <cstdio>
#include <thread>
#include <vector>
#include <array>
#include <cstring>
using namespace wam::macos;
struct Sink final : DecodedFrameSink {
  unsigned frames{}, ambientFrames{};
  FrameEnqueueResult enqueue(FrameLease frame, std::string*) override {
    ++frames;
    CFTypeRef ambient = CVBufferCopyAttachment(frame.pixelBuffer(), kCVImageBufferAmbientViewingEnvironmentKey, nullptr);
    const std::array<UInt8,8> expected{0x00,0x2f,0xe9,0xa0,0x3d,0x13,0x40,0x42};
    if (ambient && CFGetTypeID(ambient) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)ambient) == 8 &&
        std::memcmp(CFDataGetBytePtr((CFDataRef)ambient), expected.data(), 8) == 0) ++ambientFrames;
    if (ambient) CFRelease(ambient);
    return FrameEnqueueResult::Accepted;
  }
  void endOfStream(std::uint64_t) override {}
  void flush(std::uint64_t) noexcept override {}
};
int main(int argc, char** argv) {
  @autoreleasepool {
    if (argc != 2) return 2;
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(argv[1])] options:nil];
    AVAssetTrack* track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) return 3;
    auto format = (__bridge CMVideoFormatDescriptionRef)track.formatDescriptions.firstObject;
    auto atoms = (CFDictionaryRef)CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
    auto avcc = atoms ? (CFDataRef)CFDictionaryGetValue(atoms, CFSTR("avcC")) : nullptr;
    if (!avcc) return 4;
    std::vector<std::byte> bytes(CFDataGetLength(avcc));
    CFDataGetBytes(avcc, CFRangeMake(0, bytes.size()), reinterpret_cast<UInt8*>(bytes.data()));
    VideoStreamConfiguration config;
    config.codec = kCMVideoCodecType_H264;
    config.codedSize = CMVideoFormatDescriptionGetDimensions(format);
    config.codecConfiguration = bytes; config.requireHardwareDecode = true; config.generation = 1;
    config.colorPrimaries = (CFStringRef)CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_ColorPrimaries);
    config.transferFunction = (CFStringRef)CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_TransferFunction);
    config.ycbcrMatrix = (CFStringRef)CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_YCbCrMatrix);
    config.highDynamicRangeTransfer = config.transferFunction && CFEqual(config.transferFunction, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG);
    if (std::to_integer<unsigned>(bytes[1]) == 244) {
      const auto hardware = nativeVideoDecodePlan(config, true, true, true);
      const auto unavailable = nativeVideoDecodePlan(config, true, true, false);
      if (hardware.implementation != wam::media::DecodeImplementation::VideoToolboxHardware ||
          unavailable.admitted()) {
        std::fprintf(stderr,"444 must use qualified Apple hardware and refuse an unavailable hardware route\n");
        return 13;
      }
    }
    Sink sink;
    VideoToolboxDecoder decoder({3, 8, VideoToolboxOutputInterop::DisplayLayer});
    std::string error;
    if (!decoder.configure(config, sink, &error)) { std::fprintf(stderr,"configure: %s\n",error.c_str()); return 5; }
    AVAssetReader* reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    AVAssetReaderTrackOutput* output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil];
    [reader addOutput:output]; if (![reader startReading]) return 6;
    unsigned packets = 0;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (CMSampleBufferRef sample = [output copyNextSampleBuffer]) {
      if (CMSampleBufferGetTotalSampleSize(sample) == 0) { CFRelease(sample); continue; }
      for (;;) {
        const auto result = decoder.submitCMSampleBuffer(sample, 1, &error);
        if (result == VideoDecodeSubmitResult::Accepted) { ++packets; break; }
        if (result != VideoDecodeSubmitResult::Backpressure || std::chrono::steady_clock::now() > deadline) {
          std::fprintf(stderr,"submit: %s\n",error.c_str()); CFRelease(sample); return 7;
        }
        if (decoder.drainPresentation(1, &error) == VideoDecodeDrainProgress::Failed) { CFRelease(sample); return 8; }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
      CFRelease(sample);
      if (decoder.drainPresentation(1, &error) == VideoDecodeDrainProgress::Failed) return 9;
    }
    if (decoder.beginEndOfStream(1, &error) == VideoDecodeDrainProgress::Failed) return 10;
    for (;;) {
      const auto result = decoder.drainEndOfStream(1, &error);
      if (result == VideoDecodeDrainProgress::Done) break;
      if (result == VideoDecodeDrainProgress::Failed || std::chrono::steady_clock::now() > deadline) return 11;
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    const auto stats = decoder.stats();
    std::printf("packets=%u frames=%u hardware=%d requested=%08x actual=%08x\n",packets,sink.frames,
        stats.usingHardwareAcceleratedDecoder,stats.requestedOutputPixelFormat,stats.actualOutputPixelFormat);
    std::printf("ambient_frames=%u\n", sink.ambientFrames);
    return packets == 100 && sink.frames == packets && stats.usingHardwareAcceleratedDecoder &&
        (!CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_AmbientViewingEnvironment) || sink.ambientFrames == packets) ? 0 : 12;
  }
}
