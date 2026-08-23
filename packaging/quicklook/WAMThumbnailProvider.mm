// WAM QuickLook thumbnail provider -- the Objective-C shim only.
//
// Principal class for WAMThumbnail.appex (NSExtensionPrincipalClass in
// packaging/quicklook/Info.plist). Everything that can actually go wrong --
// demux, keyframe selection, VideoToolbox -- lives in wam_thumbnail_frame.mm
// so it can be driven by wam_quicklook_thumbnail_frame_test from a plain
// command line. This file does UTI-to-URL plumbing, aspect-fitting, and
// CoreGraphics ownership, and nothing else.

#import <Foundation/Foundation.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <os/log.h>

#include <algorithm>
#include <filesystem>
#include <string>

#include "wam_thumbnail_frame.hpp"

namespace {

// A thumbnail extension is a system-launched sandboxed process: its stderr
// goes nowhere, and a failure is indistinguishable from "macOS has no
// thumbnail for this" -- both show the generic icon. Every outcome is
// therefore logged, so `log stream --predicate 'subsystem ==
// "com.wesleymaa.wam.quicklook"'` can tell a refused container from a decode
// that never ran.
os_log_t ThumbnailLog() {
  static os_log_t log;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    log = os_log_create("com.wesleymaa.wam.quicklook", "thumbnail");
  });
  return log;
}

// Aspect-preserving destination rect for an image of `imageSize` inside
// `bounds`.
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
    // covering the whole file. Do not try to open anything else, and never
    // write anywhere: this provider opens O_RDONLY and creates no file.
    const char *fsPath = request.fileURL.fileSystemRepresentation;
    if (fsPath == nullptr) {
      handler(nil, [NSError errorWithDomain:NSCocoaErrorDomain
                                       code:NSFileReadInvalidFileNameError
                                   userInfo:nil]);
      return;
    }

    std::string failure;
    wam::quicklook::ThumbnailFrame decoded{};
    const bool ok =
        wam::quicklook::copyKeyframeImage(std::filesystem::path{fsPath}, &decoded, &failure);

    if (!ok || decoded.image == nullptr) {
      // Reply with an error -- NOT an empty/placeholder drawing. An error lets
      // the system fall back to the generic icon; a blank reply caches a blank
      // thumbnail. Note the cache is sticky: `qlmanage -r cache` is required to
      // clear a bad result during development.
      if (failure.empty()) {
        failure = "thumbnail unavailable";
      }
      os_log_error(ThumbnailLog(), "no thumbnail for %{public}s: %{public}s",
                   fsPath, failure.c_str());
      handler(nil,
              [NSError errorWithDomain:@"com.wesleymaa.wam.quicklook"
                                  code:1
                              userInfo:@{
                                NSLocalizedDescriptionKey :
                                    [NSString stringWithUTF8String:failure.c_str()]
                              }]);
      return;
    }

    // Transfer the +1 CGImage into ARC so the drawing block's capture keeps it
    // alive for exactly as long as the reply does. A block does not retain a
    // bare CGImageRef, so releasing here -- as a create-rule reading would
    // suggest -- would leave the block drawing a freed image.
    id boxedImage = (__bridge_transfer id)decoded.image;

    CGSize contextSize = request.maximumSize;
    if (contextSize.width < 1 || contextSize.height < 1) {
      contextSize = CGSizeMake(512, 512);
    }
    CGSize imageSize = decoded.displaySize;
    if (imageSize.width < 1 || imageSize.height < 1) {
      imageSize = CGSizeMake(CGImageGetWidth((__bridge CGImageRef)boxedImage),
                             CGImageGetHeight((__bridge CGImageRef)boxedImage));
    }
    const CGRect destination = FittedRect(imageSize, contextSize);

    QLThumbnailReply *reply = [QLThumbnailReply
        replyWithContextSize:contextSize
                drawingBlock:^BOOL(CGContextRef ctx) {
                  CGContextDrawImage(ctx, destination,
                                     (__bridge CGImageRef)boxedImage);
                  return YES;
                }];

    os_log(ThumbnailLog(),
           "thumbnail for %{public}s: %.0fx%.0f into %.0fx%.0f", fsPath,
           imageSize.width, imageSize.height, contextSize.width,
           contextSize.height);
    handler(reply, nil);
  }
}

@end
