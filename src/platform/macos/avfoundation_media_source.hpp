#pragma once

#include "media/native_media_source.hpp"
#include "platform/macos/avfoundation_asset_context.hpp"

#include <CoreMedia/CoreMedia.h>

#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <span>
#include <string>

namespace wam::macos {

// The AVFoundation bridge is split at the lifetime boundary, rather than at
// individual Objective-C calls. One session-scoped immutable AssetContext
// owns the prepared AVURLAsset/tracks; each Generation owns exactly one fresh
// AVAssetReader. Tests inject deterministic generations while MediaSource
// continues to exercise cancellation, staging, merge, payload-lease, and EOS.
enum class AVFoundationGenerationStatus : std::uint8_t {
  Ready,
  Unsupported,
  Cancelled,
  Failed,
};

struct AVFoundationGenerationRequest {
  std::filesystem::path path;
  media::MediaSourceOpenOptions options;
  media::MediaGeneration generation{0};
  std::optional<media::MediaTime> target;
  media::MediaSeekMode seekMode{media::MediaSeekMode::Accurate};
  // Null on cold open. Every later main seek receives the exact context
  // returned by the admitted first generation.
  std::shared_ptr<const AVFoundationAssetContext> assetContext;
};

struct AVFoundationGenerationStart {
  AVFoundationGenerationStatus status{AVFoundationGenerationStatus::Failed};
  media::MediaTime actualDecodeStart{};
  std::shared_ptr<const media::MediaSourceDescriptor> descriptor;
  std::string error;
  std::shared_ptr<const AVFoundationAssetContext> assetContext;
  // Proved by the source owner from its own staged audio head, not by the
  // backend generation. Empty exactly when no audio track is selected or the
  // window is not exactly representable on the declared audio frame grid.
  media::MediaAudioGenerationWindow audioWindow{};
  // Container-declared silence for this generation, read from the selected
  // tracks' edit lists and movie-timeline ranges before any sample is read.
  // declaredAudioMediaStart is the movie time at which audio media begins
  // (the origin unless a leading empty edit says otherwise);
  // declaredPresentationEnd is where presentation must end when the selected
  // video runs past the end of the selected audio, and is invalid otherwise.
  media::MediaTime declaredAudioMediaStart{0, 1};
  media::MediaTime declaredPresentationEnd{};
  // Movie time at which the selected audio media ends. Stated only alongside
  // declaredPresentationEnd.
  media::MediaTime declaredAudioEnd{};
};

enum class AVFoundationSampleReadStatus : std::uint8_t {
  Sample,
  EndOfStream,
  Cancelled,
  Failed,
};

struct AVFoundationCopiedSample {
  // Sample carries Create/Copy ownership. The caller must CFRelease it or
  // transfer that +1 into a media payload lease.
  CMSampleBufferRef sample{nullptr};
  AVFoundationSampleReadStatus status{
      AVFoundationSampleReadStatus::Failed};
  std::string error;
};

class AVFoundationGeneration {
 public:
  virtual ~AVFoundationGeneration() = default;

  [[nodiscard]] virtual media::MediaGeneration generation() const noexcept = 0;
  [[nodiscard]] virtual AVFoundationGenerationStart start() = 0;
  [[nodiscard]] virtual AVFoundationCopiedSample
  copyNextVideoSample() = 0;
  [[nodiscard]] virtual AVFoundationCopiedSample
  copyNextAudioSample() = 0;
  virtual void cancel() noexcept = 0;
};

class AVFoundationBackend {
 public:
  virtual ~AVFoundationBackend() = default;

  // Construction must be bounded and nonblocking. Asset loading and reader
  // creation belong to Generation::start(), after the operation generation is
  // visible to exact-match cancellation.
  [[nodiscard]] virtual std::shared_ptr<AVFoundationGeneration>
  makeGeneration(AVFoundationGenerationRequest request) = 0;
};

class AVFoundationMediaSource final : public media::MediaSource {
 public:
  AVFoundationMediaSource();
  explicit AVFoundationMediaSource(
      std::shared_ptr<AVFoundationBackend> backend);
  ~AVFoundationMediaSource() override;

  AVFoundationMediaSource(const AVFoundationMediaSource&) = delete;
  AVFoundationMediaSource& operator=(const AVFoundationMediaSource&) = delete;

  [[nodiscard]] bool
  armOperation(media::MediaGeneration generation) noexcept override;
  [[nodiscard]] media::MediaSourceOpenOutcome openLocalFile(
      const std::filesystem::path& path,
      const media::MediaSourceOpenOptions& options,
      media::MediaGeneration generation) override;
  [[nodiscard]] media::MediaSourceSeekOutcome seek(
      const media::MediaSourceSeekRequest& request) override;
  [[nodiscard]] media::MediaSourceReadResult
  readNext(media::MediaGeneration expectedGeneration) override;
  void requestCancel(media::MediaGeneration generation) noexcept override;
  void close() noexcept override;
  [[nodiscard]] media::MediaSourceStats stats() const noexcept override;

  // Owner-thread snapshot. Non-null only after a successful Ready admission;
  // retaining it keeps the immutable asset/tracks alive after source close.
  [[nodiscard]] std::shared_ptr<const AVFoundationAssetContext>
  assetContext() const noexcept;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#if defined(WAM_AVFOUNDATION_MEDIA_SOURCE_TESTING)
namespace avfoundation_media_source_testing {

// The production metadata loader uses this same bounded batch primitive.  The
// test seam supplies deterministic completion edges without requiring a media
// fixture or relying on scheduler-duration assertions.
struct ConcurrentMetadataLoadRequest {
  std::function<void(std::function<void()>)> issue;
  std::function<bool(std::string*)> validate;
};

enum class ConcurrentMetadataLoadWake : std::uint8_t {
  None,
  AllCompleted,
  CancellationEdge,
};

struct ConcurrentMetadataLoadObservation {
  std::size_t issued{0};
  std::size_t validated{0};
  ConcurrentMetadataLoadWake wake{ConcurrentMetadataLoadWake::None};
};

class ConcurrentMetadataLoadCancellation final {
 public:
  ConcurrentMetadataLoadCancellation();
  ~ConcurrentMetadataLoadCancellation();

  ConcurrentMetadataLoadCancellation(
      const ConcurrentMetadataLoadCancellation&) = delete;
  ConcurrentMetadataLoadCancellation& operator=(
      const ConcurrentMetadataLoadCancellation&) = delete;

  void cancel() noexcept;

 private:
  struct Impl;
  std::shared_ptr<Impl> impl_;

  friend bool waitForConcurrentMetadataLoads(
      std::span<const ConcurrentMetadataLoadRequest> requests,
      ConcurrentMetadataLoadCancellation& cancellation,
      ConcurrentMetadataLoadObservation* observation,
      std::string* error);
};

[[nodiscard]] bool waitForConcurrentMetadataLoads(
    std::span<const ConcurrentMetadataLoadRequest> requests,
    ConcurrentMetadataLoadCancellation& cancellation,
    ConcurrentMetadataLoadObservation* observation,
    std::string* error);

// Deterministic entry points for validating CoreMedia descriptor extraction
// without a media fixture or a second AVAssetReader.
[[nodiscard]] bool validAudioChannelLayoutForTesting(
    const AudioChannelLayout* layout, std::size_t layoutSize,
    std::uint32_t channels) noexcept;
void resetInspectedAudioChannelLayoutSizeForTesting() noexcept;
[[nodiscard]] std::size_t
inspectedAudioChannelLayoutSizeForTesting() noexcept;
[[nodiscard]] bool sampleFormatMatchesTrackForTesting(
    CMSampleBufferRef sample,
    const media::MediaTrackDescriptor& track) noexcept;
// True exactly for the payload-free CoreMedia buffers of a track output's
// terminal marker tail: untimed decoder-control markers and the edit list's
// empty-media terminator. The backend drops them instead of publishing them;
// timed zero-sample discontinuity markers must stay false.
[[nodiscard]] bool mediaFreeMarkerForTesting(CMSampleBufferRef sample) noexcept;
// Restates a compressed audio sample's per-access-unit durations on the
// codec's own ordinal packet grid, returning how many entries were restated.
// A container that folded an edit's end trim into the final access unit is
// republished at the frame count that unit's own packet decodes to. Only ever
// lengthens a short unit up to that exact extent; a unit already stated in
// full, a non-positive duration, and a stream without a fixed packet frame
// count are all left untouched.
[[nodiscard]] std::size_t restateCompressedAudioPacketDurationsForTesting(
    CMSampleBufferRef sample, CMSampleTimingInfo* timing,
    std::size_t entries) noexcept;
[[nodiscard]] std::optional<media::MediaTrackDescriptor>
inspectVideoFormat(CMVideoFormatDescriptionRef format,
                   media::MediaTrackId trackId, media::MediaTime duration,
                   const media::MediaSourceLimits& limits,
                   std::string* error);
[[nodiscard]] std::optional<media::MediaTrackDescriptor>
inspectAudioFormat(CMAudioFormatDescriptionRef format,
                   media::MediaTrackId trackId, media::MediaTime duration,
                   const media::MediaSourceLimits& limits,
                   std::string* error);
[[nodiscard]] bool preservesLegacyNativeAdmission(
    const media::MediaSourceDescriptor& descriptor,
    std::string* error);
[[nodiscard]] bool preservesZeroBasedTrackTimeline(
    CMTimeRange trackRange, std::string* error);
[[nodiscard]] std::optional<CMTimeRange>
exactReaderTimeRange(CMTime duration, CMTime decodeStart);
[[nodiscard]] std::optional<bool> accurateVideoDecodeOnly(
    CMTime presentationTime, CMTime duration, media::MediaTime target,
    std::string* error);

}  // namespace avfoundation_media_source_testing
#endif

}  // namespace wam::macos
