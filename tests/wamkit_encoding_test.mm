#import <AVFoundation/AVFoundation.h>
#include <VideoToolbox/VideoToolbox.h>
#import <WAMKit/WAMKitEncoding.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <vector>
#define CHECK(x)                                                               \
  do {                                                                         \
    if (!(x)) {                                                                \
      fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x);                     \
      exit(1);                                                                 \
    }                                                                          \
  } while (0)
static wam_error_t error;
#define OK(x)                                                                  \
  do {                                                                         \
    auto s = (x);                                                              \
    if (s != WAM_OK) {                                                         \
      fprintf(stderr, "%s: %s %s\n", #x, error.name, error.detail);            \
      exit(1);                                                                 \
    }                                                                          \
  } while (0)

static void audio(NSString *dir) {
  for (unsigned rate : {44100u, 48000u})
    for (unsigned channels : {1u, 2u}) {
      NSString *path = [dir
          stringByAppendingPathComponent:[NSString
                                             stringWithFormat:@"%u-%u.m4a",
                                                              rate, channels]];
      wam_audio_encoder_config_t c{sizeof(c), rate, channels, 1, 0};
      wam_audio_encoder_t e = nullptr;
      CHECK(wam_audio_encoder_create(&c, path.UTF8String, &e, &error) ==
            WAM_REFUSED);
      CHECK(!e && !strcmp(error.name, "HardwareAACEncoderUnavailableOnMacOS"));
      CHECK(![[NSFileManager defaultManager] fileExistsAtPath:path]);
      c.require_hardware = 0;
      OK(wam_audio_encoder_create(&c, path.UTF8String, &e, &error));
      wam_audio_encoder_t duplicate = nullptr;
      CHECK(wam_audio_encoder_create(&c, path.UTF8String, &duplicate, &error) ==
            WAM_REFUSED);
      CHECK(!duplicate);
      float invalid = std::numeric_limits<float>::quiet_NaN();
      std::vector<float> bad(channels, invalid);
      CHECK(wam_audio_encoder_write(e, bad.data(), 1, &error) ==
            WAM_INVALID_ARGUMENT);
      CHECK(wam_audio_encoder_write(e, bad.data(), 4097, &error) ==
            WAM_INVALID_ARGUMENT);
      for (unsigned offset = 0; offset < rate;) {
        unsigned frames = std::min(997u, rate - offset);
        std::vector<float> pcm(frames * channels);
        for (unsigned i = 0; i < frames; i++)
          for (unsigned ch = 0; ch < channels; ch++)
            pcm[i * channels + ch] =
                0.25f *
                std::sin(2 * M_PI * (ch ? 880 : 440) * (offset + i) / rate);
        OK(wam_audio_encoder_write(e, pcm.data(), frames, &error));
        offset += frames;
      }
      OK(wam_audio_encoder_finish(e, &error));
      OK(wam_audio_encoder_finish(e, &error));
      float zero[2]{};
      CHECK(wam_audio_encoder_write(e, zero, 1, &error) == WAM_CLOSED);
      wam_encoder_info_t info{};
      info.struct_size = sizeof(info);
      OK(wam_audio_encoder_copy_info(e, &info));
      CHECK(!info.hardware_accelerated && info.input_frames == rate);
      CHECK(!strcmp(info.implementation, "AudioToolbox software AAC"));
      wam_audio_encoder_release(e);
      NSError *err = nil;
      AVAudioFile *file =
          [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path]
                                        error:&err];
      CHECK(file && !err);
      CHECK(file.processingFormat.channelCount == channels);
      CHECK(file.processingFormat.sampleRate == rate);
      CHECK(std::abs(file.length - int64_t(rate)) <= 1024);
      AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc]
          initWithPCMFormat:file.processingFormat
              frameCapacity:AVAudioFrameCount(file.length)];
      CHECK([file readIntoBuffer:buffer error:&err]);
      CHECK(buffer.frameLength >= rate - 1024);
      for (unsigned ch = 0; ch < channels; ch++) {
        double sum = 0, tone = 0, other = 0;
        for (unsigned i = 4096; i < buffer.frameLength - 4096; i++) {
          float x = buffer.floatChannelData[ch][i];
          CHECK(std::isfinite(x));
          sum += x * x;
          tone += x * std::sin(2 * M_PI * (ch ? 880 : 440) * i / rate);
          other += x * std::sin(2 * M_PI * (ch ? 440 : 880) * i / rate);
        }
        double rms = std::sqrt(sum / (buffer.frameLength - 8192));
        CHECK(rms > 0.14 && rms < 0.21);
        CHECK(std::abs(tone) > 10 * std::abs(other));
      }
      printf("AAC software roundtrip: %u Hz, %u channels, %u decoded frames\n",
             rate, channels, buffer.frameLength);
    }
  wam_audio_encoder_config_t c{sizeof(c), 48000, 1, 0, 0};
  wam_audio_encoder_t handles[4]{};
  for (int i = 0; i < 4; i++) {
    NSString *path = [dir
        stringByAppendingPathComponent:[NSString
                                           stringWithFormat:@"capacity-%d.m4a",
                                                            i]];
    OK(wam_audio_encoder_create(&c, path.UTF8String, &handles[i], &error));
  }
  wam_audio_encoder_t fifth = nullptr;
  NSString *path = [dir stringByAppendingPathComponent:@"capacity-extra.m4a"];
  CHECK(wam_audio_encoder_create(&c, path.UTF8String, &fifth, &error) ==
        WAM_BACKPRESSURE);
  CHECK(!fifth);
  for (auto e : handles)
    wam_audio_encoder_release(e);
  OK(wam_audio_encoder_create(&c, path.UTF8String, &fifth, &error));
  wam_audio_encoder_release(fifth);
  c.sample_rate = 0;
  CHECK(wam_audio_encoder_create(&c, "/tmp/unused.m4a", &fifth, &error) ==
        WAM_INVALID_ARGUMENT);
  CHECK(!fifth);
  puts("Audio refusal, validation, overwrite protection, capacity and reuse "
       "passed");
}
struct Decoded {
  unsigned frames = 0;
  OSStatus error = 0;
  CMTime pts = kCMTimeInvalid;
};
static void decompressed(void *context, void *, OSStatus status,
                         VTDecodeInfoFlags, CVImageBufferRef image, CMTime pts,
                         CMTime) {
  auto *d = static_cast<Decoded *>(context);
  d->error = status;
  if (status || !image)
    return;
  CHECK(CVPixelBufferGetWidth(image) == 128 &&
        CVPixelBufferGetHeight(image) == 96);
  CHECK(CMTimeCompare(pts, CMTimeMake(d->frames, 30)) == 0);
  CHECK(CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly) ==
        kCVReturnSuccess);
  auto *p = static_cast<unsigned char *>(
      CVPixelBufferGetBaseAddressOfPlane(image, 0));
  CHECK(p && std::abs(int(p[0]) - int(40 + d->frames * 4)) <= 5);
  CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
  d->pts = pts;
  ++d->frames;
}
static int video(bool requireHardware) {
  for (unsigned codec :
       {unsigned(WAM_ENCODE_H264), unsigned(WAM_ENCODE_HEVC)}) {
    wam_video_encoder_config_t c{sizeof(c), codec, 128, 96, 1000000, 0};
    wam_video_encoder_t e = nullptr;
    auto status = wam_video_encoder_create(&c, &e, &error);
    if (status != WAM_OK) {
      fprintf(stderr, "hardware codec %u refused: %s %s\n", codec, error.name,
              error.detail);
      return !requireHardware &&
                     !strcmp(error.name, "HardwareVideoEncoderUnavailable")
                 ? 77
                 : 1;
    }
    CVPixelBufferRef pixels = nullptr;
    NSDictionary *attrs =
        @{(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{}};
    CHECK(CVPixelBufferCreate(nullptr, 128, 96,
                              kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                              (__bridge CFDictionaryRef)attrs, &pixels) == 0);
    VTDecompressionSessionRef decoder = nullptr;
    Decoded d;
    for (unsigned i = 0; i < 12; i++) {
      CHECK(CVPixelBufferLockBaseAddress(pixels, 0) == 0);
      for (size_t plane = 0; plane < 2; plane++)
        memset(CVPixelBufferGetBaseAddressOfPlane(pixels, plane),
               plane ? 128 : 40 + i * 4,
               CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) *
                   CVPixelBufferGetHeightOfPlane(pixels, plane));
      CVPixelBufferUnlockBaseAddress(pixels, 0);
      CMSampleBufferRef sample = nullptr;
      OK(wam_video_encoder_encode(e, pixels, {i, 30, 0}, {1, 30, 0}, &sample,
                                  &error));
      CHECK(sample && CMSampleBufferGetNumSamples(sample) == 1 &&
            CMSampleBufferGetTotalSampleSize(sample) > 0);
      CHECK(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample),
                          CMTimeMake(i, 30)) == 0);
      auto format = CMSampleBufferGetFormatDescription(sample);
      CHECK(CMFormatDescriptionGetMediaSubType(format) ==
            (codec == WAM_ENCODE_H264 ? kCMVideoCodecType_H264
                                      : kCMVideoCodecType_HEVC));
      if (!decoder) {
        VTDecompressionOutputCallbackRecord callback{decompressed, &d};
        NSDictionary *output = @{
          (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey :
              @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        };
        CHECK(VTDecompressionSessionCreate(nullptr, format, nullptr,
                                           (__bridge CFDictionaryRef)output,
                                           &callback, &decoder) == 0);
      }
      CHECK(VTDecompressionSessionDecodeFrame(decoder, sample, 0, nullptr,
                                              nullptr) == 0);
      CHECK(VTDecompressionSessionWaitForAsynchronousFrames(decoder) == 0);
      CHECK(d.error == 0);
      CFRelease(sample);
    }
    CHECK(d.frames == 12);
    wam_encoder_info_t info{};
    info.struct_size = sizeof(info);
    OK(wam_video_encoder_copy_info(e, &info));
    CHECK(info.hardware_accelerated && info.input_frames == 12);
    CMSampleBufferRef sample = nullptr;
    CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                          kCVAttachmentMode_ShouldPropagate);
    CHECK(wam_video_encoder_encode(e, pixels, {12, 30, 0}, {1, 30, 0}, &sample,
                                   &error) == WAM_INVALID_ARGUMENT &&
          !sample);
    CHECK(!strcmp(error.name, "UnsupportedVideoEncoderColor"));
    CVBufferRemoveAttachment(pixels, kCVImageBufferTransferFunctionKey);
    CHECK(wam_video_encoder_encode(e, pixels, {0, 30, 0}, {1, 30, 0}, &sample,
                                   &error) == WAM_INVALID_ARGUMENT &&
          !sample);
    CHECK(wam_video_encoder_encode(e, pixels, {12, 30, 0}, {0, 30, 0}, &sample,
                                   &error) == WAM_INVALID_ARGUMENT &&
          !sample);
    CHECK(wam_video_encoder_encode(e, pixels, {INT64_MAX, 1, 0}, {1, 1, 0},
                                   &sample, &error) == WAM_INVALID_ARGUMENT &&
          !sample);
    CHECK(wam_video_encoder_encode(e, pixels, {12, 0, 0}, {1, 30, 0}, &sample,
                                   &error) == WAM_INVALID_ARGUMENT &&
          !sample);
    OK(wam_video_encoder_encode(e, pixels, {12, 30, 0}, {1, 30, 0}, &sample,
                                &error));
    CFRelease(sample);
    VTDecompressionSessionInvalidate(decoder);
    CFRelease(decoder);
    CFRelease(pixels);
    wam_video_encoder_release(e);
    printf("Video codec %u: verified hardware selection, 12 roundtrip frames "
           "with exact PTS and decoded luma\n",
           codec);
  }
  wam_video_encoder_config_t bad{sizeof(bad), 99, 128, 96, 1000000, 0};
  wam_video_encoder_t e = nullptr;
  CHECK(wam_video_encoder_create(&bad, &e, &error) == WAM_INVALID_ARGUMENT &&
        !e);
  bad.codec = WAM_ENCODE_H264;
  bad.width = 4097;
  CHECK(wam_video_encoder_create(&bad, &e, &error) == WAM_INVALID_ARGUMENT &&
        !e);
  return 0;
}
int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc > 1 && !strcmp(argv[1], "video"))
      return video(argc > 2 && !strcmp(argv[2], "--require-hardware"));
    NSString *dir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            [@"wam-encoding-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    CHECK([[NSFileManager defaultManager] createDirectoryAtPath:dir
                                    withIntermediateDirectories:YES
                                                     attributes:nil
                                                          error:nil]);
    audio(dir);
    CHECK([[NSFileManager defaultManager] removeItemAtPath:dir error:nil]);
    return 0;
  }
}
