// Drives the QuickLook appex's decode path from a plain command line.
//
// A QuickLook extension is close to untestable in place: it runs in a
// system-launched sandboxed process, its stderr goes nowhere a test can read,
// and the only observable is whether Finder eventually shows a picture. This
// harness exercises exactly the code the appex runs -- same sources, same link
// set -- so a demux or VideoToolbox failure is a readable error instead of a
// silent fall back to the generic icon.
//
// With no arguments it is a self-check that passes trivially (there are no
// checked-in Matroska/transport-stream fixtures small enough to keep in the
// tree), which is what lets it sit in ctest. Given paths it decodes each one
// and, with -o DIR, writes the frames out as PNG for eyeballing.
//
//   wam_quicklook_thumbnail_frame_test [-o OUTDIR] FILE...

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>

#include "packaging/quicklook/wam_thumbnail_frame.hpp"

namespace {

bool WritePng(CGImageRef image, const std::filesystem::path& path) {
  NSURL* url = [NSURL fileURLWithPath:@(path.c_str())];
  CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
      (__bridge CFURLRef)url, CFSTR("public.png"), 1, nullptr);
  if (destination == nullptr) {
    return false;
  }
  CGImageDestinationAddImage(destination, image, nullptr);
  const bool ok = CGImageDestinationFinalize(destination);
  CFRelease(destination);
  return ok;
}

}  // namespace

int main(int argc, char** argv) {
  @autoreleasepool {
    std::filesystem::path outputDirectory;
    std::vector<std::filesystem::path> inputs;
    for (int i = 1; i < argc; ++i) {
      const std::string argument{argv[i]};
      if (argument == "-o" && i + 1 < argc) {
        outputDirectory = argv[++i];
        continue;
      }
      inputs.emplace_back(argument);
    }

    if (inputs.empty()) {
      // No fixture was named. Prove the entry point refuses a nonexistent path
      // cleanly rather than crashing or hanging, which is the one thing worth
      // asserting without media in the tree.
      wam::quicklook::ThumbnailFrame frame{};
      std::string error;
      const bool ok = wam::quicklook::copyKeyframeImage(
          "/nonexistent/wam-quicklook-self-check.mkv", &frame, &error);
      if (ok || frame.image != nullptr) {
        std::fprintf(stderr, "a missing file must not produce a frame\n");
        return 1;
      }
      if (error.empty()) {
        std::fprintf(stderr, "a failure must carry a reason\n");
        return 1;
      }
      std::printf("self-check ok (%s)\n", error.c_str());
      return 0;
    }

    int failures = 0;
    for (const auto& input : inputs) {
      wam::quicklook::ThumbnailFrame frame{};
      std::string error;
      const auto started = std::chrono::steady_clock::now();
      const bool ok = wam::quicklook::copyKeyframeImage(input, &frame, &error);
      const auto elapsed =
          std::chrono::duration_cast<std::chrono::milliseconds>(
              std::chrono::steady_clock::now() - started);

      if (!ok || frame.image == nullptr) {
        std::printf("FAIL  %7lld ms  %s  (%s)\n",
                    static_cast<long long>(elapsed.count()),
                    input.filename().c_str(), error.c_str());
        ++failures;
        continue;
      }

      std::printf("ok    %7lld ms  %s  %zux%zu coded, %.0fx%.0f display\n",
                  static_cast<long long>(elapsed.count()),
                  input.filename().c_str(), CGImageGetWidth(frame.image),
                  CGImageGetHeight(frame.image), frame.displaySize.width,
                  frame.displaySize.height);

      if (!outputDirectory.empty()) {
        std::filesystem::path out =
            outputDirectory / (input.filename().string() + ".png");
        if (!WritePng(frame.image, out)) {
          std::fprintf(stderr, "could not write %s\n", out.c_str());
          ++failures;
        }
      }
      CGImageRelease(frame.image);
    }
    return failures == 0 ? 0 : 1;
  }
}
