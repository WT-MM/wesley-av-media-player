#include <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#include <VideoToolbox/VideoToolbox.h>
#include <WAMKit/WAMKitEncoding.h>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <memory>
#include <new>

namespace {
std::atomic<unsigned> encoders{0};
bool admit() {
  unsigned n = encoders.load();
  while (n < 4)
    if (encoders.compare_exchange_weak(n, n + 1))
      return true;
  return false;
}
wam_status_t fail(wam_error_t *e, wam_status_t status, const char *name,
                  OSStatus os = 0) {
  if (e) {
    *e = {};
    e->struct_size = sizeof(*e);
    e->code = WAM_REASON_NATIVE_DETAIL;
    snprintf(e->name, sizeof(e->name), "%s", name);
    snprintf(e->detail, sizeof(e->detail), "%s (OSStatus %d)", name, int(os));
  }
  return status;
}
void clear(wam_error_t *e) {
  if (e) {
    *e = {};
    e->struct_size = sizeof(*e);
  }
}
CMTime time(wam_time_t t) { return CMTimeMake(t.value, t.timescale); }
bool matchesAttachment(CVPixelBufferRef pixels, CFStringRef key,
                       CFStringRef expected) {
  CFTypeRef value = CVBufferCopyAttachment(pixels, key, nullptr);
  const bool matches = !value || CFEqual(value, expected);
  if (value)
    CFRelease(value);
  return matches;
}
bool valid(wam_time_t t) {
  return t.timescale > 0 && t.value >= 0 && !t.reserved;
}
} // namespace
struct wam_video_encoder {
  VTCompressionSessionRef session = nullptr;
  uint32_t width = 0, height = 0;
  uint64_t inputFrames = 0;
  uint32_t codec = 0;
  CMSampleBufferRef output = nullptr;
  OSStatus callbackStatus = noErr;
  CMTime end = kCMTimeInvalid;
  bool failed = false;
  ~wam_video_encoder() {
    if (session) {
      VTCompressionSessionInvalidate(session);
      CFRelease(session);
    }
    if (output)
      CFRelease(output);
    --encoders;
  }
};
struct wam_audio_encoder {
  ExtAudioFileRef file = nullptr;
  uint32_t channels = 0;
  uint64_t inputFrames = 0;
  bool failed = false;
  ~wam_audio_encoder() {
    if (file)
      ExtAudioFileDispose(file);
    --encoders;
  }
};
namespace {
void compressed(void *context, void *, OSStatus status, VTEncodeInfoFlags flags,
                CMSampleBufferRef sample) {
  auto *e = static_cast<wam_video_encoder *>(context);
  if (status || (flags & kVTEncodeInfo_FrameDropped) || !sample ||
      !CMSampleBufferDataIsReady(sample)) {
    e->callbackStatus = status ? status : kVTVideoEncoderMalfunctionErr;
    return;
  }
  if (e->output) {
    e->callbackStatus = kVTVideoEncoderMalfunctionErr;
    return;
  }
  e->output = (CMSampleBufferRef)CFRetain(sample);
}
} // namespace
wam_status_t wam_video_encoder_create(const wam_video_encoder_config_t *c,
                                      wam_video_encoder_t *out,
                                      wam_error_t *error) {
  clear(error);
  if (out)
    *out = nullptr;
  if (!c || !out || c->struct_size != sizeof(*c) || c->reserved ||
      (c->codec != WAM_ENCODE_H264 && c->codec != WAM_ENCODE_HEVC) ||
      c->width < 16 || c->height < 16 || c->width > 4096 || c->height > 4096 ||
      (c->width & 1) || (c->height & 1) ||
      uint64_t(c->width) * c->height > 4096 * 2160 || c->bitrate < 100000 ||
      c->bitrate > 100000000)
    return fail(error, WAM_INVALID_ARGUMENT,
                "InvalidVideoEncoderConfiguration");
  if (!admit())
    return fail(error, WAM_BACKPRESSURE, "EncoderCapacityExceeded");
  std::unique_ptr<wam_video_encoder> e(new (std::nothrow) wam_video_encoder);
  if (!e) {
    --encoders;
    return fail(error, WAM_REFUSED, "EncoderAllocationFailed");
  }
  e->codec = c->codec;
  e->width = c->width;
  e->height = c->height;
  @autoreleasepool {
    NSDictionary *spec = @{
      (__bridge NSString *)
      kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder : @YES
    };
    NSDictionary *attributes = @{
      (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey :
          @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      (__bridge NSString *)kCVPixelBufferWidthKey : @(c->width),
      (__bridge NSString *)kCVPixelBufferHeightKey : @(c->height),
      (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{}
    };
    OSStatus s = VTCompressionSessionCreate(
        nullptr, c->width, c->height,
        c->codec == WAM_ENCODE_H264 ? kCMVideoCodecType_H264
                                    : kCMVideoCodecType_HEVC,
        (__bridge CFDictionaryRef)spec, (__bridge CFDictionaryRef)attributes,
        nullptr, compressed, e.get(), &e->session);
    if (s)
      return fail(error, WAM_REFUSED, "HardwareVideoEncoderUnavailable", s);
    NSDictionary *properties = @{
      (__bridge NSString *)kVTCompressionPropertyKey_RealTime : @YES,
      (__bridge NSString *)kVTCompressionPropertyKey_AllowFrameReordering : @NO,
      (__bridge NSString *)
      kVTCompressionPropertyKey_AverageBitRate : @(c->bitrate),
      (__bridge NSString *)kVTCompressionPropertyKey_ProfileLevel :
          (__bridge NSString *)(c->codec == WAM_ENCODE_H264
                                    ? kVTProfileLevel_H264_Main_AutoLevel
                                    : kVTProfileLevel_HEVC_Main_AutoLevel),
      (__bridge NSString *)kVTCompressionPropertyKey_ColorPrimaries :
          (__bridge NSString *)kCVImageBufferColorPrimaries_ITU_R_709_2,
      (__bridge NSString *)kVTCompressionPropertyKey_TransferFunction :
          (__bridge NSString *)kCVImageBufferTransferFunction_ITU_R_709_2,
      (__bridge NSString *)kVTCompressionPropertyKey_YCbCrMatrix :
          (__bridge NSString *)kCVImageBufferYCbCrMatrix_ITU_R_709_2
    };
    s = VTSessionSetProperties(e->session,
                               (__bridge CFDictionaryRef)properties);
    if (!s)
      s = VTCompressionSessionPrepareToEncodeFrames(e->session);
    if (s)
      return fail(error, WAM_REFUSED, "VideoEncoderConfigurationUnsupported",
                  s);
    CFTypeRef hardware = nullptr;
    s = VTSessionCopyProperty(
        e->session,
        kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, nullptr,
        &hardware);
    bool verified = !s && hardware && CFEqual(hardware, kCFBooleanTrue);
    if (hardware)
      CFRelease(hardware);
    if (!verified)
      return fail(error, WAM_REFUSED, "HardwareVideoEncoderNotVerified", s);
  }
  *out = e.release();
  return WAM_OK;
}
wam_status_t wam_video_encoder_encode(wam_video_encoder_t e,
                                      CVPixelBufferRef pixels, wam_time_t pts,
                                      wam_time_t duration,
                                      CMSampleBufferRef *out,
                                      wam_error_t *error) {
  clear(error);
  if (out)
    *out = nullptr;
  if (!e || !out || !pixels || !valid(pts) || !valid(duration) ||
      !duration.value || CVPixelBufferGetWidth(pixels) != e->width ||
      CVPixelBufferGetHeight(pixels) != e->height ||
      CVPixelBufferGetPixelFormatType(pixels) !=
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    return fail(error, WAM_INVALID_ARGUMENT, "InvalidVideoEncoderInput");
  if (e->failed)
    return fail(error, WAM_CLOSED, "VideoEncoderFailed");
  if (!matchesAttachment(pixels, kCVImageBufferColorPrimariesKey,
                         kCVImageBufferColorPrimaries_ITU_R_709_2) ||
      !matchesAttachment(pixels, kCVImageBufferTransferFunctionKey,
                         kCVImageBufferTransferFunction_ITU_R_709_2) ||
      !matchesAttachment(pixels, kCVImageBufferYCbCrMatrixKey,
                         kCVImageBufferYCbCrMatrix_ITU_R_709_2))
    return fail(error, WAM_INVALID_ARGUMENT, "UnsupportedVideoEncoderColor");
  CMTime next = CMTimeAdd(time(pts), time(duration));
  if (!CMTIME_IS_NUMERIC(next) || (next.flags & kCMTimeFlags_HasBeenRounded) ||
      CMTimeCompare(next, time(pts)) <= 0 ||
      (CMTIME_IS_VALID(e->end) && CMTimeCompare(time(pts), e->end) < 0))
    return fail(error, WAM_INVALID_ARGUMENT, "InvalidVideoEncoderTimeline");
  OSStatus s = VTCompressionSessionEncodeFrame(
      e->session, pixels, time(pts), time(duration), nullptr, nullptr, nullptr);
  if (!s)
    s = VTCompressionSessionCompleteFrames(e->session, kCMTimeInvalid);
  if (s || e->callbackStatus || !e->output) {
    e->failed = true;
    return fail(error, WAM_REFUSED, "VideoEncodeFailed",
                s ? s : e->callbackStatus);
  }
  ++e->inputFrames;
  e->end = next;
  *out = e->output;
  e->output = nullptr;
  return WAM_OK;
}
void wam_video_encoder_release(wam_video_encoder_t e) { delete e; }
wam_status_t wam_audio_encoder_create(const wam_audio_encoder_config_t *c,
                                      const char *path,
                                      wam_audio_encoder_t *out,
                                      wam_error_t *error) {
  clear(error);
  if (out)
    *out = nullptr;
  if (!c || !path || path[0] != '/' || !out || c->struct_size != sizeof(*c) ||
      c->reserved || c->require_hardware > 1 ||
      (c->sample_rate != 44100 && c->sample_rate != 48000) ||
      (c->channels != 1 && c->channels != 2))
    return fail(error, WAM_INVALID_ARGUMENT,
                "InvalidAudioEncoderConfiguration");
  if (c->require_hardware)
    return fail(error, WAM_REFUSED, "HardwareAACEncoderUnavailableOnMacOS");
  if (!admit())
    return fail(error, WAM_BACKPRESSURE, "EncoderCapacityExceeded");
  std::unique_ptr<wam_audio_encoder> e(new (std::nothrow) wam_audio_encoder);
  if (!e) {
    --encoders;
    return fail(error, WAM_REFUSED, "EncoderAllocationFailed");
  }
  e->channels = c->channels;
  @autoreleasepool {
    NSString *string = [NSString stringWithUTF8String:path];
    if (!string)
      return fail(error, WAM_INVALID_ARGUMENT, "InvalidOutputPath");
    NSURL *url = [NSURL fileURLWithPath:string];
    AudioStreamBasicDescription output{};
    output.mSampleRate = c->sample_rate;
    output.mFormatID = kAudioFormatMPEG4AAC;
    output.mChannelsPerFrame = c->channels;
    UInt32 size = sizeof(output);
    OSStatus s = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0,
                                        nullptr, &size, &output);
    if (s)
      return fail(error, WAM_REFUSED, "AACEncoderUnavailable", s);
    s = ExtAudioFileCreateWithURL((__bridge CFURLRef)url, kAudioFileM4AType,
                                  &output, nullptr, 0, &e->file);
    if (s)
      return fail(error, WAM_REFUSED, "AudioOutputFileCreationFailed", s);
    // AudioFormat.h exposes the symbolic name only on iOS. 'appl' is the
    // AudioComponent manufacturer returned by macOS's AAC encoder enumeration.
    UInt32 manufacturer = 0x6170706c;
    s = ExtAudioFileSetProperty(e->file,
                                kExtAudioFileProperty_CodecManufacturer,
                                sizeof(manufacturer), &manufacturer);
    AudioStreamBasicDescription input{};
    input.mSampleRate = c->sample_rate;
    input.mFormatID = kAudioFormatLinearPCM;
    input.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    input.mBytesPerPacket = input.mBytesPerFrame = c->channels * sizeof(float);
    input.mFramesPerPacket = 1;
    input.mChannelsPerFrame = c->channels;
    input.mBitsPerChannel = 32;
    if (!s)
      s = ExtAudioFileSetProperty(e->file,
                                  kExtAudioFileProperty_ClientDataFormat,
                                  sizeof(input), &input);
    if (s)
      return fail(error, WAM_REFUSED, "AACEncoderConfigurationFailed", s);
  }
  *out = e.release();
  return WAM_OK;
}
wam_status_t wam_audio_encoder_write(wam_audio_encoder_t e,
                                     const float *samples, uint32_t frames,
                                     wam_error_t *error) {
  clear(error);
  if (!e || !samples || !frames || frames > 4096)
    return fail(error, WAM_INVALID_ARGUMENT, "InvalidAudioEncoderInput");
  if (e->failed || !e->file)
    return fail(error, WAM_CLOSED, "AudioEncoderClosed");
  for (size_t i = 0; i < size_t(frames) * e->channels; ++i)
    if (!std::isfinite(samples[i]) || std::fabs(samples[i]) > 1.0f)
      return fail(error, WAM_INVALID_ARGUMENT, "InvalidPCMSample");
  AudioBufferList buffers{};
  buffers.mNumberBuffers = 1;
  buffers.mBuffers[0] = {e->channels,
                         UInt32(frames * e->channels * sizeof(float)),
                         const_cast<float *>(samples)};
  OSStatus s = ExtAudioFileWrite(e->file, frames, &buffers);
  if (s) {
    e->failed = true;
    return fail(error, WAM_REFUSED, "AudioEncodeFailed", s);
  }
  e->inputFrames += frames;
  return WAM_OK;
}
wam_status_t wam_audio_encoder_finish(wam_audio_encoder_t e,
                                      wam_error_t *error) {
  clear(error);
  if (!e)
    return fail(error, WAM_INVALID_ARGUMENT, "InvalidAudioEncoder");
  if (e->failed)
    return fail(error, WAM_CLOSED, "AudioEncoderFailed");
  if (!e->file)
    return WAM_OK;
  OSStatus s = ExtAudioFileDispose(e->file);
  e->file = nullptr;
  if (s) {
    e->failed = true;
    return fail(error, WAM_REFUSED, "AudioEncoderFinalizationFailed", s);
  }
  return WAM_OK;
}
void wam_audio_encoder_release(wam_audio_encoder_t e) { delete e; }

wam_status_t wam_video_encoder_copy_info(wam_video_encoder_t e,
                                         wam_encoder_info_t *info) {
  if (!e || !info || info->struct_size != sizeof(*info))
    return WAM_INVALID_ARGUMENT;
  *info = {};
  info->struct_size = sizeof(*info);
  info->hardware_accelerated = 1;
  info->input_frames = e->inputFrames;
  snprintf(info->implementation, sizeof(info->implementation),
           "VideoToolbox hardware %s",
           e->codec == WAM_ENCODE_H264 ? "H.264" : "HEVC");
  return WAM_OK;
}
wam_status_t wam_audio_encoder_copy_info(wam_audio_encoder_t e,
                                         wam_encoder_info_t *info) {
  if (!e || !info || info->struct_size != sizeof(*info))
    return WAM_INVALID_ARGUMENT;
  *info = {};
  info->struct_size = sizeof(*info);
  info->hardware_accelerated = 0;
  info->input_frames = e->inputFrames;
  snprintf(info->implementation, sizeof(info->implementation),
           "AudioToolbox software AAC");
  return WAM_OK;
}
