#pragma once

#include "media/native_media_source.hpp"
#include "media/audio_track_admission.hpp"
#include "platform/macos/matroska_asset_context.hpp"

#include <CoreMedia/CoreMedia.h>

#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>

namespace wam::macos {

// The Matroska side of the shared custom-source core
// (`native_custom_source_core.hpp`). Every rule stated here is a place where
// this container deliberately differs from the MPEG-TS twin; the core reads
// them by name so a change to one container cannot silently move the other.
struct MatroskaSourceTraits {
  static constexpr const char* kName = "matroska";
  // A Matroska with no video track is the music-file route and stays admitted:
  // the video cursor exists only for a selected video track.
  static constexpr bool kVideoRequired = false;

  using AssetContext = MatroskaAssetContext;
  using PreparedAsset = media::matroska::MatroskaPreparedAsset;
  using Cursor = media::matroska::MatroskaCursor;
  using CompressedSample = media::matroska::MatroskaCompressedSample;
  using CursorReadResult = media::matroska::MatroskaCursorReadResult;
  using CursorEnd = media::matroska::MatroskaCursorEnd;
  using CursorCancelled = media::matroska::MatroskaCursorCancelled;
  using CursorFailure = media::matroska::MatroskaCursorFailure;
  using DemuxStatus = media::matroska::MatroskaDemuxStatus;
  using DemuxError = media::matroska::MatroskaDemuxError;
  using Plan = media::matroska::MatroskaGenerationPlan;
  using PrepareOutcome = media::matroska::MatroskaPrepareOutcome;
  using PlanOutcome = media::matroska::MatroskaPlanOutcome;
  using CancellationToken = media::matroska::CancellationToken;

  // How far ahead of its own presentation time a video sample sorts in the
  // A/V merge. Matroska carries no decode timestamp, and the cursor emits in
  // storage order, which is DECODE order -- so for a stream with B-frames the
  // emission order and the presentation order are not the same order. Keying
  // the merge on the presentation time sorts every B-frame BEHIND audio that
  // has already played past it, and the frame reaches the presentation
  // scheduler after its interval has closed. This constant reconstructs the
  // lead that a DTS-bearing container hands the merge for free.
  //
  // The bound: the displacement between decode order and presentation order
  // is at most (reorder depth) x (frame duration). The consumer refuses any
  // stream above a reorder depth of 4, and at the lowest frame rate this
  // player admits a frame is well under 42 ms, so 4 x 42 ms = 168 ms is the
  // worst case; 250 ms clears it with margin. The cost of the lead is bounded
  // in the other direction by the dispatcher's video read-ahead budget: 250 ms
  // is 7.5 frames at 30 fps against a 24-event lane, and 312 KiB at 10 Mbit/s
  // against a 4 MiB high-water mark, so a leading video lane cannot overrun
  // either cap.
  static constexpr std::int64_t kVideoMergeLeadNanoseconds{250'000'000};

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
  // The first Cue's exact tick, or empty for a Cue-less asset.
  [[nodiscard]] static std::optional<media::MediaTime> videoOrigin(
      const PreparedAsset& asset) noexcept;
  [[nodiscard]] static CMVideoFormatDescriptionRef
  createVideoFormatDescription(const media::MediaTrackDescriptor& track) noexcept;
  [[nodiscard]] static std::string demuxErrorMessage(const char* what,
                                                     DemuxError error);
  // Video sorts on a key that leads its presentation time by
  // kVideoMergeLeadNanoseconds (exact, rounded UP in the timestamp's own
  // timescale so the key never lands short of the reorder window); audio
  // sorts on its exact presentation time. The key is an ordering key only and
  // is never published as a timestamp.
  [[nodiscard]] static media::MediaTime mergeOrderKey(
      const media::MediaSample& sample) noexcept;
};

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
class MatroskaMediaSource final : public media::MediaSource, public media::AudioTrackRetrySource {
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
  media::MediaSourceOpenOutcome retryAudioTrack(
      const std::filesystem::path&, const media::MediaSourceOpenOptions&,
      media::MediaGeneration, media::MediaTrackId rejected) override;
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
  media::AudioTrackRejections rejectedAudio_;
};

}  // namespace wam::macos
