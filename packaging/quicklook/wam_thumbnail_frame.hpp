#pragma once

// Container-agnostic "give me one early keyframe as a CGImage" entry point.
//
// This is the whole of WAMThumbnail.appex's decode work, deliberately split
// out of the Objective-C provider so it can be driven from a plain command
// line. A QuickLook extension is close to untestable in place -- it runs in a
// system-launched sandboxed process, its stderr goes nowhere a test can read,
// and the only observable is whether Finder eventually shows a picture -- so
// the pipeline that can actually be wrong lives here instead.
//
// Qt-free by contract, and links nothing outside wam_native_core, the two
// sample builders, and system frameworks. See packaging/quicklook/README.md.

#include <CoreGraphics/CoreGraphics.h>

#include <filesystem>
#include <string>

namespace wam::quicklook {

struct ThumbnailFrame {
  // +1 reference on success; the caller must CGImageRelease it.
  CGImageRef image{nullptr};
  // Display size after pixel aspect and rotation, for aspect-correct drawing.
  // Falls back to the CGImage's own size when the container says nothing.
  CGSize displaySize{0, 0};
};

// Decodes one keyframe roughly a tenth of the way into `path`.
//
// Bounded by construction: a single wall-clock deadline backs the cancellation
// token every demuxer entry point already accepts, the frame ceiling is 4K,
// exactly one access unit is decoded, and nothing is ever written to disk.
// Returns false with a human-readable `error` on any failure -- the caller
// must then reply with an error so the system falls back to its generic icon.
[[nodiscard]] bool copyKeyframeImage(const std::filesystem::path& path,
                                     ThumbnailFrame* out, std::string* error);

}  // namespace wam::quicklook
