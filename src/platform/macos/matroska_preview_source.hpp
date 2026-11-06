#pragma once

#include "platform/macos/native_preview_source.hpp"

#include <memory>

namespace wam::macos {

// Matroska scrub preview: NativePreviewSourceCore over the main source's
// MatroskaSourceTraits. A plan lands on a Cue, an exact index entry, and every
// sample is published with an invalid decode timestamp exactly as the main
// source does, so the preview decode is submission ordered.
//
// Requires a binding whose assetContext is a live MatroskaAssetContext.
[[nodiscard]] std::unique_ptr<NativePreviewSource> createMatroskaPreviewSource(
    NativePreviewBinding binding) noexcept;

}  // namespace wam::macos
