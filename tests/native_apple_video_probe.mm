#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <ImageIO/ImageIO.h>
#import <VideoToolbox/VideoToolbox.h>
#include <atomic>
#include <cstdio>
#include <libproc.h>
#include <sys/resource.h>
#include <unistd.h>
struct Output {
  std::atomic<int> count{0};
  std::atomic<OSStatus> error{0};
  std::atomic<OSType> pixel{0};
  std::atomic<CVPixelBufferRef> first{nullptr};
};
static void decoded(void *p, void *, OSStatus e, VTDecodeInfoFlags,
                    CVImageBufferRef b, CMTime, CMTime) {
  auto &o = *static_cast<Output *>(p);
  if (e)
    o.error = e;
  if (b) {
    CVPixelBufferRef empty = nullptr;
    if (o.first.compare_exchange_strong(empty, b)) CVPixelBufferRetain(b);
    ++o.count;
    o.pixel = CVPixelBufferGetPixelFormatType(b);
  }
}
int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc == 1) {
      UInt32 n = 0;
      AudioFormatGetPropertyInfo(kAudioFormatProperty_DecodeFormatIDs, 0,
                                 nullptr, &n);
      OSType ids[256]{};
      if (n <= sizeof(ids) &&
          AudioFormatGetProperty(kAudioFormatProperty_DecodeFormatIDs, 0,
                                 nullptr, &n, ids) == 0)
        for (unsigned i = 0; i < n / 4; ++i)
          printf("AT format=%08x\n", ids[i]);
      for (OSType c : {kCMVideoCodecType_H264, kCMVideoCodecType_HEVC,
                       kCMVideoCodecType_AppleProRes4444,
                       kCMVideoCodecType_AppleProRes4444XQ,
                       kCMVideoCodecType_VP9, kCMVideoCodecType_AV1}) {
        VTRegisterSupplementalVideoDecoderIfAvailable(c);
        printf("HW codec=%08x verdict=%d\n", c, VTIsHardwareDecodeSupported(c));
      }
      return 0;
    }
    AVURLAsset *a =
        [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(argv[1])]
                            options:nil];
    AVAssetTrack *t = [a tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!t)
      return 2;
    CMFormatDescriptionRef f =
        (__bridge CMFormatDescriptionRef)t.formatDescriptions.firstObject;
    OSType codec = CMFormatDescriptionGetMediaSubType(f);
    VTRegisterSupplementalVideoDecoderIfAvailable(codec);
    NSDictionary *spec =
        argc > 2 && atoi(argv[2]) == 1 ? @{
          (id)
          kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder :
              @YES
        }
        : argc > 2 && atoi(argv[2]) == 2 ? @{
            (id)
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder :
                @NO
          }
                                         : nil;
    NSDictionary *dest = argc > 3 && strtoul(argv[3], nullptr, 16) != 0 ? @{
      (id)kCVPixelBufferPixelFormatTypeKey :
          @((OSType)strtoul(argv[3], nullptr, 16))
    }
                                  : nil;
    Output output;
    VTDecompressionOutputCallbackRecord cb{decoded, &output};
    VTDecompressionSessionRef s = nullptr;
    auto e =
        VTDecompressionSessionCreate(nullptr, f, (__bridge CFDictionaryRef)spec,
                                     (__bridge CFDictionaryRef)dest, &cb, &s);
    printf("codec=%08x create=%d ", codec, e);
    if (e) {
      puts("");
      return 1;
    }
    CFTypeRef hw = nullptr;
    VTSessionCopyProperty(
        s, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
        nullptr, &hw);
    printf("using_hw=%d ", hw == kCFBooleanTrue);
    if (hw)
      CFRelease(hw);
    AVAssetReader *r = [AVAssetReader assetReaderWithAsset:a error:nil];
    AVAssetReaderTrackOutput *o =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:t
                                                   outputSettings:nil];
    [r addOutput:o];
    [r startReading];
    rusage before{}, after{};
    getrusage(RUSAGE_SELF, &before);
    rusage_info_v6 rb{}, ra{};
    int eb = proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&rb);
    int packets = 0, imageio = 0;
    while (CMSampleBufferRef b = [o copyNextSampleBuffer]) {
      if (CMSampleBufferGetTotalSampleSize(b)) {
        ++packets;
        e = VTDecompressionSessionDecodeFrame(s, b, 0, nullptr, nullptr);
        if (e)
          output.error = e;
        if (codec == 'jpeg' && packets == 1) {
          CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(b);
          size_t n = CMBlockBufferGetDataLength(bb);
          NSMutableData *d = [NSMutableData dataWithLength:n];
          CMBlockBufferCopyDataBytes(bb, 0, n, d.mutableBytes);
          CGImageSourceRef is =
              CGImageSourceCreateWithData((__bridge CFDataRef)d, nullptr);
          if (is) {
            CGImageRef im = CGImageSourceCreateImageAtIndex(is, 0, nullptr);
            imageio = im != nullptr;
            if (im)
              CGImageRelease(im);
            CFRelease(is);
          }
        }
      }
      CFRelease(b);
    }
    VTDecompressionSessionFinishDelayedFrames(s);
    VTDecompressionSessionWaitForAsynchronousFrames(s);
    if (argc > 4 && output.first.load()) {
      CVPixelBufferRef source = output.first.load(), rgb = nullptr;
      VTPixelTransferSessionRef transfer = nullptr;
      const auto width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source);
      OSStatus grab = CVPixelBufferCreate(nullptr, width, height,
          kCVPixelFormatType_32BGRA, nullptr, &rgb);
      if (!grab) grab = VTPixelTransferSessionCreate(nullptr, &transfer);
      if (!grab) grab = VTPixelTransferSessionTransferImage(transfer, source, rgb);
      if (!grab && CVPixelBufferLockBaseAddress(rgb, kCVPixelBufferLock_ReadOnly) == 0) {
        FILE* file = fopen(argv[4], "wb");
        if (file) {
          const auto* data = static_cast<const unsigned char*>(CVPixelBufferGetBaseAddress(rgb));
          for (size_t y = 0; y < height; ++y)
            fwrite(data + y * CVPixelBufferGetBytesPerRow(rgb), 4, width, file);
          fclose(file);
        } else grab = -1;
        CVPixelBufferUnlockBaseAddress(rgb, kCVPixelBufferLock_ReadOnly);
      }
      printf("grab=%d width=%zu height=%zu ", grab, width, height);
      if (transfer) CFRelease(transfer);
      if (rgb) CVPixelBufferRelease(rgb);
    }
    if (output.first.load()) CVPixelBufferRelease(output.first.load());
    getrusage(RUSAGE_SELF, &after);
    int ea = proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&ra);
    auto us = [](timeval t) {
      return (long long)t.tv_sec * 1000000 + t.tv_usec;
    };
    printf("packets=%d frames=%d error=%d pixel=%08x imageio=%d cpu_us=%lld "
           "energy_status=%d/%d energy_nj=%llu\n",
           packets, output.count.load(), output.error.load(), output.pixel.load(), imageio,
           us(after.ru_utime) + us(after.ru_stime) - us(before.ru_utime) -
               us(before.ru_stime),
           eb, ea, ra.ri_energy_nj - rb.ri_energy_nj);
    VTDecompressionSessionInvalidate(s);
    CFRelease(s);
    return packets > 0 && output.count == packets && output.error == 0 ? 0 : 1;
  }
}
