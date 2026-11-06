#pragma once

#include "platform/macos/native_preview_source.hpp"

#include <memory>

namespace wam::macos {

// MPEG-TS scrub preview: NativePreviewSourceCore over the main source's
// MpegTsSourceTraits.
//
// What differs from Matroska is only the accuracy of the landing, and it
// differs because the containers differ: a Matroska plan lands on a Cue, an
// exact index entry, while a transport stream has no index at all and the plan
// bisects a PCR table built at open and then scans forward for the nearest
// random access point at or before the target. The scrub therefore lands
// within one GOP of the requested position rather than on it. A PES header
// carries an explicit DTS, so the preview decode follows the stream's own
// decode order.
//
// Requires a binding whose assetContext is a live MpegTsAssetContext.
[[nodiscard]] std::unique_ptr<NativePreviewSource> createMpegTsPreviewSource(
    NativePreviewBinding binding) noexcept;

}  // namespace wam::macos
