// WAM QuickLook thumbnail provider -- SKELETON.
//
// INERT: not referenced by CMakeLists.txt, not compiled, not shipped.
// See packaging/quicklook/README.md.
//
// Principal class for WAMThumbnail.appex (NSExtensionPrincipalClass in
// packaging/quicklook/Info.plist). Generates a Finder thumbnail for containers
// macOS cannot demux -- .mkv / .webm today, .ts behind a second branch.
//
// HARD CONSTRAINT: this translation unit and everything it links must be
// Qt-free. The appex may link wam_native_core and the Matroska/VideoToolbox
// pieces of wam_macos_native_video_core; it must never link wam_app or any
// Qt target. CMakeLists.txt:1362-1397 (wam_matroska_preview_source_test) is
// the existing proof that this source set links without Qt.
//
// Build shape (when wired up):
//   -e _NSExtensionMain
//   -framework Foundation -framework CoreGraphics -framework CoreMedia
//   -framework CoreVideo  -framework VideoToolbox -framework QuickLookThumbnailing
//   -Wl,-rpath,@loader_path/../../../../Frameworks   // 4 levels; verified
//   -Wl,-ObjC  (or -force_load) so WAMThumbnailProvider survives dead-stripping

#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <VideoToolbox/VideoToolbox.h>

#include <chrono>
#include <filesystem>
#include <memory>
#include <string>

// TODO(wire-up): these are the real headers. All verified Qt-free.
// #include "media/matroska_demuxer.hpp"
// #include "media/native_media_source.hpp"
// #include "platform/macos/matroska_sample_builder.hpp"
// #include "platform/macos/video_toolbox_decoder.hpp"

namespace {

// Hard ceiling for the whole request. Finder shows the generic icon until we
// reply, so a slow provider reads as a broken one. No kill was observed at a
// 40 s stall on the QLThumbnailGenerator path, but that is the API's patience,
// not the user's.
constexpr std::chrono::milliseconds kThumbnailBudget{3000};

// Never render frame 0: the first frame of a real encode is very often black or
// a fade-in. Land a few seconds in, on a Cue (a random access point by
// construction), clamped back toward 0 for clips shorter than this.
constexpr std::chrono::seconds kPreferredOffset{5};

// Aspect-preserving destination rect for `image` inside `bounds`.
CGRect FittedRect(CGSize imageSize, CGSize bounds) {
  if (imageSize.width <= 0 || imageSize.height <= 0) {
    return CGRectMake(0, 0, bounds.width, bounds.height);
  }
  const CGFloat scale = std::min(bounds.width / imageSize.width,
                                 bounds.height / imageSize.height);
  const CGFloat w = imageSize.width * scale;
  const CGFloat h = imageSize.height * scale;
  return CGRectMake((bounds.width - w) * 0.5, (bounds.height - h) * 0.5, w, h);
}

// Decodes one early keyframe from `path` into a retained CGImage.
// Returns nullptr on any failure; `error` receives a human-readable reason.
//
// The caller must CGImageRelease() a non-null result.
CGImageRef CopyKeyframeImage(const std::filesystem::path& path,
                             std::string* error) {
  (void)path;
  if (error) *error = "not implemented";

  // TODO(wire-up) 1. PREPARE
  //   The experiment proved this exact syscall pattern works inside the appex
  //   sandbox: open(O_RDONLY|O_CLOEXEC) plus pread at offset 0 and at EOF, on a
  //   90 MB file, with only com.apple.security.app-sandbox.
  //
  //   media::MediaSourceOpenOptions options{};   // video-only track selection
  //   media::matroska::CancellationToken cancellation = /* budget-backed */;
  //   auto outcome = media::matroska::prepareMatroskaLocalFile(
  //       path, options, cancellation);
  //   if (outcome.status != Ready || !outcome.asset) { *error = outcome.message; return nullptr; }
  //   const auto& asset = *outcome.asset;

  // TODO(wire-up) 2. TARGET + 3. PLAN
  //   planGeneration() is const and cursor-free, and its actualDecodeStart is
  //   already a keyframe -- there is no back-walk to write here.
  //
  //   const auto target = ClampToDuration(kPreferredOffset, asset);
  //   auto planned = asset.planGeneration(target, media::MediaSeekMode::Accurate,
  //                                       cancellation);
  //   if (!planned.plan) { *error = "no random access point"; return nullptr; }

  // TODO(wire-up) 4. READ ONE KEYFRAME
  //   Samples are payload-free frame ranges; the first sample a cursor emits is
  //   the keyframe the plan starts on.
  //
  //   auto cursor = asset.makeVideoCursor(*planned.plan);
  //   auto read = cursor->readNext(cancellation);
  //   auto* sample = std::get_if<MatroskaCompressedSample>(&read);
  //   if (!sample || !sample->keyFrame) { *error = "no keyframe"; return nullptr; }

  // TODO(wire-up) 5. BUILD CMSampleBuffer
  //   The configuration record must reach CoreMedia verbatim -- re-emitting an
  //   avcC/hvcC atom changes bytes the decoder compares.
  //
  //   CMVideoFormatDescriptionRef format =
  //       wam::macos::createMatroskaVideoFormatDescription(videoTrack);
  //   wam::macos::MatroskaSampleBuildInputs inputs{
  //       .asset = &asset, .cancellation = cancellation,
  //       .format = format, .video = true};
  //   wam::macos::MatroskaScopedSampleBuffer built;
  //   if (wam::macos::buildMatroskaCompressedSampleBuffer(
  //           inputs, *sample, &built, error) != Ok) return nullptr;

  // TODO(wire-up) 6. DECODE
  //   Metal interop, NOT DisplayLayer: we must read pixels back in-process, and
  //   the DisplayLayer contract stops pinning an uncompressed pixel format
  //   (video_toolbox_decoder.hpp:54-63). A lossless compressed surface cannot
  //   be sampled by the CPU.
  //
  //   wam::macos::VideoToolboxDecoder decoder{/* Metal interop */};
  //   if (!decoder.configure(streamConfiguration, error)) return nullptr;
  //   decoder.submitCMSampleBuffer(built.get(), /*generation=*/0, error);
  //   // drain until the single frame lands, honouring kThumbnailBudget
  //   CVPixelBufferRef pixels = /* decoded surface */;

  // TODO(wire-up) 7. CVPixelBuffer -> CGImage
  //   CGImageRef image = nullptr;
  //   VTCreateCGImageFromCVPixelBuffer(pixels, nullptr, &image);
  //   // Fallback for pixel formats VT declines: render via CIContext.
  //   // Apply the track's display aspect here if it differs from coded size.
  //   return image;

  return nullptr;
}

}  // namespace

@interface WAMThumbnailProvider : QLThumbnailProvider
@end

@implementation WAMThumbnailProvider

- (void)provideThumbnailForFileRequest:(QLFileThumbnailRequest *)request
                     completionHandler:
                         (void (^)(QLThumbnailReply *_Nullable,
                                   NSError *_Nullable))handler {
  @autoreleasepool {
    // QuickLook grants a read-only sandbox extension for exactly this URL,
    // covering the whole file. Do not try to open anything else.
    const char *fsPath = request.fileURL.fileSystemRepresentation;
    if (fsPath == nullptr) {
      handler(nil, [NSError errorWithDomain:NSCocoaErrorDomain
                                       code:NSFileReadInvalidFileNameError
                                   userInfo:nil]);
      return;
    }

    std::string failure;
    CGImageRef image =
        CopyKeyframeImage(std::filesystem::path{fsPath}, &failure);

    if (image == nullptr) {
      // Reply with an error -- NOT an empty/placeholder drawing. An error lets
      // the system fall back to the generic icon; a blank reply caches a blank
      // thumbnail. Note the cache is sticky: `qlmanage -r cache` is required to
      // clear a bad result during development.
      handler(nil,
              [NSError errorWithDomain:@"com.wesleymaa.wam.quicklook"
                                  code:1
                              userInfo:@{
                                NSLocalizedDescriptionKey :
                                    [NSString stringWithUTF8String:failure.c_str()]
                              }]);
      return;
    }

    CGSize contextSize = request.maximumSize;
    if (contextSize.width < 1 || contextSize.height < 1) {
      contextSize = CGSizeMake(512, 512);
    }
    const CGSize imageSize =
        CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image));

    QLThumbnailReply *reply = [QLThumbnailReply
        replyWithContextSize:contextSize
                drawingBlock:^BOOL(CGContextRef ctx) {
                  CGContextDrawImage(ctx, FittedRect(imageSize, contextSize),
                                     image);
                  return YES;
                }];

    // The drawing block retains `image` via the block capture; balance the
    // create-rule reference from CopyKeyframeImage once the reply owns it.
    // TODO(wire-up): confirm block lifetime here -- if the block can outlive
    // this scope, transfer ownership explicitly rather than releasing now.
    CGImageRelease(image);

    handler(reply, nil);
  }
}

@end
