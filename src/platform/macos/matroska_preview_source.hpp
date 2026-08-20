#pragma once

#include "platform/macos/native_preview_source.hpp"

#include <memory>

namespace wam::macos {

// Matroska implementation of the neutral scrub preview pull source.
//
// It needs strictly less machinery than the AVFoundation one, because the
// container already carries the index the other backend has to reconstruct:
// `MatroskaPreparedAsset::planGeneration(target, Accurate)` is const, cursor
// free, and returns an `actualDecodeStart` that is a Cue -- a random access
// point by construction. There is therefore no analogue of the AVFoundation
// full-sync back-walk; begin() is one plan plus one makeVideoCursor(), and the
// first sample a cursor emits is already the keyframe the decode starts on.
//
// The prepared asset is immutable and re-verifies file identity at every entry
// point, so a preview cursor is entirely independent of the main source's
// playback cursors: the two share only const state and the asset's own
// retained descriptor. Nothing here mutates the context beyond its two
// cumulative cursor counters, which are exactly the facts the neutral
// readersCreated/readersStarted pair reports.
//
// Every sample is published with an invalid decode timestamp, exactly as the
// main Matroska source does, so the preview decode is submission ordered.
class MatroskaPreviewSource final : public NativePreviewSource {
 public:
  // Requires a binding whose assetContext is a live MatroskaAssetContext:
  // there is no cold-load path here, because admitting a Matroska file is the
  // main source's bounded, cancellable job and preview must never repeat it.
  [[nodiscard]] static std::unique_ptr<MatroskaPreviewSource> create(
      NativePreviewBinding binding) noexcept;
  ~MatroskaPreviewSource() override;

  [[nodiscard]] NativePreviewBeginOutcome
  begin(NativePreviewRequest request) noexcept override;
  [[nodiscard]] bool advanceTarget(std::uint64_t expectedEpoch,
                                   media::MediaTime target) noexcept override;
  [[nodiscard]] NativePreviewReadResult
  readNext(std::uint64_t expectedEpoch) noexcept override;
  void requestCancel(std::uint64_t epoch) noexcept override;
  void close() noexcept override;
  [[nodiscard]] NativePreviewSourceFacts facts() const noexcept override;
  [[nodiscard]] NativePreviewSourceMemoryFacts memoryFacts()
      const noexcept override;

 private:
  struct Impl;
  explicit MatroskaPreviewSource(std::unique_ptr<Impl> impl) noexcept;
  std::unique_ptr<Impl> impl_;
};

}  // namespace wam::macos
