#pragma once

#include "media/native_media_source.hpp"
#include "platform/macos/mpegts_asset_context.hpp"

#include <filesystem>
#include <memory>

namespace wam::macos {

// macOS media source backed by the neutral MPEG-2 Transport Stream demuxer.
//
// The split mirrors the AVFoundation bridge and the Matroska bridge at the same
// lifetime boundary: one session-scoped immutable MpegTsAssetContext owns the
// prepared asset and its built index, and each generation owns exactly one pair
// of payload-free cursors plus the two CoreMedia format descriptions built from
// the admitted descriptor.
//
// Two things make this source structurally different from its Matroska sibling,
// and both are consequences of the same container fact:
//
//  1. **Transport Stream carries a real DTS**, so the A/V merge keys on the
//     actual decode timestamp -- the AVFoundation shape -- and this source has
//     NO synthetic `kVideoMergeLeadNanoseconds` ordering lead. Copying that
//     constant across would reintroduce, in the opposite direction, the exact
//     defect it was invented to work around for a container that has no DTS.
//  2. **Transport Stream states no per-frame audio timeline.** A PES header
//     carries a 90 kHz timestamp, and 90 kHz does not divide a 44.1 kHz frame
//     grid, so the container's own stamp is a rounded value that cannot be
//     published verbatim to a converter which requires exact frame-grid
//     contiguity. The source anchors on the first PES timestamp and then
//     advances an exact frame ordinal, validating every later PES against it.
class MpegTsMediaSource final : public media::MediaSource {
 public:
  MpegTsMediaSource();
  ~MpegTsMediaSource() override;

  MpegTsMediaSource(const MpegTsMediaSource&) = delete;
  MpegTsMediaSource& operator=(const MpegTsMediaSource&) = delete;

  [[nodiscard]] bool
  armOperation(media::MediaGeneration generation) noexcept override;
  [[nodiscard]] media::MediaSourceOpenOutcome openLocalFile(
      const std::filesystem::path& path,
      const media::MediaSourceOpenOptions& options,
      media::MediaGeneration generation) override;
  [[nodiscard]] media::MediaSourceSeekOutcome
  seek(const media::MediaSourceSeekRequest& request) override;
  [[nodiscard]] media::MediaSourceReadResult
  readNext(media::MediaGeneration expectedGeneration) override;
  void requestCancel(media::MediaGeneration generation) noexcept override;
  void close() noexcept override;
  [[nodiscard]] media::MediaSourceStats stats() const noexcept override;

  // Owner-thread snapshot. Non-null only after a successful Ready admission;
  // retaining it keeps the immutable prepared asset alive after source close.
  [[nodiscard]] std::shared_ptr<const MpegTsAssetContext>
  assetContext() const noexcept;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace wam::macos
