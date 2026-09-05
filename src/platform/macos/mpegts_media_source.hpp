#pragma once

#include "media/native_media_source.hpp"
#include "platform/macos/mpegts_asset_context.hpp"

#include <CoreMedia/CoreMedia.h>

#include <filesystem>
#include <memory>
#include <optional>
#include <string>

namespace wam::macos {

// The MPEG-TS side of the shared custom-source core
// (`native_custom_source_core.hpp`). Every rule stated here is a place where
// this container deliberately differs from the Matroska twin; the core reads
// them by name so a change to one container cannot silently move the other.
struct MpegTsSourceTraits {
  static constexpr const char* kName = "mpeg-ts";
  // A transport stream with no video elementary stream is refused: the video
  // cursor is always requested and the demuxer's refusal is the source's own.
  static constexpr bool kVideoRequired = true;

  using AssetContext = MpegTsAssetContext;
  using PreparedAsset = media::mpegts::MpegTsPreparedAsset;
  using Cursor = media::mpegts::MpegTsCursor;
  using CompressedSample = media::mpegts::MpegTsCompressedSample;
  using CursorReadResult = media::mpegts::MpegTsCursorReadResult;
  using CursorEnd = media::mpegts::MpegTsCursorEnd;
  using CursorCancelled = media::mpegts::MpegTsCursorCancelled;
  using CursorFailure = media::mpegts::MpegTsCursorFailure;
  using DemuxStatus = media::mpegts::MpegTsDemuxStatus;
  using DemuxError = media::mpegts::MpegTsDemuxError;
  using Plan = media::mpegts::MpegTsGenerationPlan;
  using PrepareOutcome = media::mpegts::MpegTsPrepareOutcome;
  using PlanOutcome = media::mpegts::MpegTsPlanOutcome;
  using CancellationToken = media::mpegts::CancellationToken;

  [[nodiscard]] static PrepareOutcome prepare(
      const std::filesystem::path& path,
      const media::MediaSourceOpenOptions& options,
      CancellationToken cancellation) noexcept;
  [[nodiscard]] static std::shared_ptr<const AssetContext> adoptContext(
      const std::filesystem::path& path,
      const media::MediaSourceOpenOptions& options,
      std::shared_ptr<const PreparedAsset> asset) noexcept;
  static void noteCursorCreationAttempt(const AssetContext& context) noexcept;
  static void noteCursorStarted(const AssetContext& context) noexcept;
  // The first video access unit's exact time, or empty when the asset states
  // none.
  [[nodiscard]] static std::optional<media::MediaTime> videoOrigin(
      const PreparedAsset& asset) noexcept;
  [[nodiscard]] static CMVideoFormatDescriptionRef
  createVideoFormatDescription(const media::MediaTrackDescriptor& track) noexcept;
  [[nodiscard]] static std::string demuxErrorMessage(const char* what,
                                                     DemuxError error);
  // THE MERGE KEY: `dts.valid() ? dts : pts`, the AVFoundation shape. A PES
  // header states an explicit decode timestamp, so the two lanes are ordered
  // by the times the decoders will actually consume them and there is NO
  // synthetic ordering lead here. Copying Matroska's
  // kVideoMergeLeadNanoseconds across would pull the video lane a quarter
  // second ahead of a decode order that is already correct, inflating the
  // video read-ahead and starving the audio lane for no reason at all.
  [[nodiscard]] static media::MediaTime mergeOrderKey(
      const media::MediaSample& sample) noexcept;
};

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
