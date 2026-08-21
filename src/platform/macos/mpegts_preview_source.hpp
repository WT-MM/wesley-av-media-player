#pragma once

#include "platform/macos/native_preview_source.hpp"

#include <memory>

namespace wam::macos {

// MPEG-TS implementation of the neutral scrub preview pull source, and the
// third implementation of that seam after AVFoundation and Matroska.
//
// It needs the same machinery as the Matroska one and for the same reason:
// `MpegTsPreparedAsset::planGeneration(target, Accurate)` is const and cursor
// free, and it returns an `actualDecodeStart` that the demuxer has already
// proved is decodable from a cold decoder. There is therefore no analogue of
// the AVFoundation full-sync back-walk; begin() is one plan plus one
// makeVideoCursor(), and the first sample a cursor emits is already the picture
// the decode starts on.
//
// What differs from Matroska is only the accuracy of the landing, and it
// differs because the containers differ: a Matroska plan lands on a Cue, which
// is an exact index entry, while a transport stream has no index at all and the
// plan bisects a PCR table built at open and then scans forward for the nearest
// random access point at or before the target. The scrub therefore lands within
// one GOP of the requested position rather than on it.
//
// The prepared asset is immutable and re-verifies file identity at every entry
// point, so a preview cursor is entirely independent of the main source's
// playback cursors: the two share only const state and the asset's own retained
// descriptor.
class MpegTsPreviewSource final : public NativePreviewSource {
 public:
  // Requires a binding whose assetContext is a live MpegTsAssetContext: there
  // is no cold-load path here, because admitting a transport stream is the main
  // source's bounded, cancellable job and preview must never repeat it behind a
  // scrub gesture.
  [[nodiscard]] static std::unique_ptr<MpegTsPreviewSource> create(
      NativePreviewBinding binding) noexcept;
  ~MpegTsPreviewSource() override;

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
  explicit MpegTsPreviewSource(std::unique_ptr<Impl> impl) noexcept;
  std::unique_ptr<Impl> impl_;
};

}  // namespace wam::macos
