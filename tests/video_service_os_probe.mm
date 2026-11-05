// Diagnostic only: a minimal Apple-framework reproducer, with no WAM or Qt.
// Usage: wam_video_service_os_probe generated-h264.mp4 [window]
// "window" deliberately reproduces the macOS 26 helper leak. Use the client
// PID printed here to identify its service; never clean up helpers by name.
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

@interface ProbeGLContext : NSOpenGLContext @end
@implementation ProbeGLContext
- (void)dealloc { std::fprintf(stderr, "OpenGL context deallocated\n"); }
@end

namespace {
std::atomic<unsigned> frames{0};
void output(void*, void*, OSStatus status, VTDecodeInfoFlags, CVImageBufferRef image,
            CMTime, CMTime) {
  if (status == noErr && image) ++frames;
}
void require(bool ok, const char* step) {
  if (!ok) { std::fprintf(stderr, "failed: %s\n", step); std::exit(1); }
}
}
int main(int argc, char** argv) {
  require(argc == 2 || argc == 3, "usage: fixture.mp4 [window]");
  std::fprintf(stderr, "client_pid=%d\n", getpid());
  @autoreleasepool {
    NSWindow* window = nil;
    NSOpenGLContext* context = nil;
    if (argc == 3) {
      [NSApplication sharedApplication];
      [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
      window = [[NSWindow alloc] initWithContentRect:NSMakeRect(2400, 1000, 160, 90)
          styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
      window.releasedWhenClosed = NO;
      NSOpenGLPixelFormatAttribute attributes[] = {
        NSOpenGLPFAAccelerated, NSOpenGLPFAOpenGLProfile,
        NSOpenGLProfileVersion3_2Core, NSOpenGLPFADoubleBuffer, 0};
      NSOpenGLPixelFormat* format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
      context = [[ProbeGLContext alloc] initWithFormat:format shareContext:nil];
      require(context != nil, "OpenGL context");
      [context setView:window.contentView];
      [window orderBack:nil]; // Never activate the probe.
    }
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:
        [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]] options:nil];
    AVAssetTrack* track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    require(track != nil, "video track");
    NSError* error = nil;
    AVAssetReader* reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    AVAssetReaderTrackOutput* samples = [[AVAssetReaderTrackOutput alloc]
        initWithTrack:track outputSettings:nil];
    [reader addOutput:samples];
    require([reader startReading], "reader start");
    CMSampleBufferRef sample = [samples copyNextSampleBuffer];
    // AVAssetReader can return an initial timeline marker with no format.
    while (sample && !CMSampleBufferGetFormatDescription(sample)) {
      CFRelease(sample);
      sample = [samples copyNextSampleBuffer];
    }
    require(sample != nullptr, "compressed sample");
    NSDictionary* specification = @{
        (id)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: @YES};
    NSDictionary* attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    VTDecompressionSessionRef decoder = nullptr;
    VTDecompressionOutputCallbackRecord callback{output, nullptr};
    require(VTDecompressionSessionCreate(nullptr, CMSampleBufferGetFormatDescription(sample),
        (__bridge CFDictionaryRef)specification, (__bridge CFDictionaryRef)attributes,
        &callback, &decoder) == noErr, "decoder create");
    do {
      if (CMSampleBufferGetFormatDescription(sample))
        require(VTDecompressionSessionDecodeFrame(decoder, sample,
            kVTDecodeFrame_EnableAsynchronousDecompression, nullptr, nullptr) == noErr, "decode");
      CFRelease(sample);
      sample = [samples copyNextSampleBuffer];
    } while (sample);
    require(VTDecompressionSessionFinishDelayedFrames(decoder) == noErr, "finish delayed");
    require(VTDecompressionSessionWaitForAsynchronousFrames(decoder) == noErr, "wait frames");
    VTDecompressionSessionInvalidate(decoder);
    CFRelease(decoder);
    [reader cancelReading];
    require(frames > 0, "actual decoded frames");
    std::fprintf(stderr, "decoder invalidated/released; frames=%u\n", frames.load());
    [NSOpenGLContext clearCurrentContext];
    [context setView:nil];
    [context clearDrawable];
    context = nil;
    [window close];
  }
  std::fprintf(stderr, "autorelease pool drained; returning from main\n");
}
