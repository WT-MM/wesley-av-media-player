#pragma once

#include "media/native_media_source.hpp"
#include "platform/macos/matroska_asset_context.hpp"

#include <filesystem>
#include <memory>

namespace wam::macos {

// macOS media source backed by the neutral Matroska demuxer.
//
// The split mirrors the AVFoundation bridge at the same lifetime boundary: one
// session-scoped immutable MatroskaAssetContext owns the prepared asset and its
// index, and each generation owns exactly one pair of payload-free cursors plus
// the two CoreMedia format descriptions built from the admitted descriptor.
//
// The demuxer deliberately never invents a decode timestamp, so every sample
// this source publishes carries an invalid decodeTime and a CMSampleBuffer with
// kCMTimeInvalid as its decode stamp. VideoToolbox then decodes in submission
// order, which is exactly the storage order the cursors emit in.
class MatroskaMediaSource final : public media::MediaSource {
 public:
  MatroskaMediaSource();
  ~MatroskaMediaSource() override;

  MatroskaMediaSource(const MatroskaMediaSource&) = delete;
  MatroskaMediaSource& operator=(const MatroskaMediaSource&) = delete;

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
  [[nodiscard]] std::shared_ptr<const MatroskaAssetContext>
  assetContext() const noexcept;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace wam::macos
