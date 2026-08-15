#pragma once

#include "media/native_media_source.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <variant>

namespace wam::media {

// Preview epochs are private cancellation identities. Keeping the type
// distinct prevents a preview request from being routed into the playback
// dispatcher even though encoded MediaSample retains a uint64_t generation
// field for existing decoder validation.
struct MediaPreviewEpoch {
  std::uint64_t value{0};

  [[nodiscard]] constexpr bool valid() const noexcept { return value != 0; }
  friend constexpr bool operator==(MediaPreviewEpoch, MediaPreviewEpoch) =
      default;
};

// Preview owns no second path, selection, limits, or descriptor identity.
// Every such fact is read from this exact main-source prepared context.
struct MediaPreviewBinding {
  std::shared_ptr<const MediaSourcePreparedContext> preparedContext;
};

struct MediaPreviewRequest {
  MediaPreviewEpoch epoch{};
  MediaTime target{};
};

enum class MediaPreviewBeginStatus : std::uint8_t {
  Rejected,
  Ready,
  Unsupported,
  Cancelled,
  Failed,
};

struct MediaPreviewBeginOutcome {
  MediaPreviewBeginStatus status{MediaPreviewBeginStatus::Rejected};
  MediaPreviewEpoch epoch{};
  MediaTime actualDecodeStart{};
  std::string error;
};

struct MediaPreviewEndOfStream {
  MediaPreviewEpoch epoch{};
};

struct MediaPreviewCancelled {
  MediaPreviewEpoch epoch{};
};

struct MediaPreviewFailure {
  MediaPreviewEpoch epoch{};
  std::string error;
};

using MediaPreviewReadResult =
    std::variant<MediaSample, MediaDiscontinuity, MediaPreviewEndOfStream,
                 MediaPreviewCancelled, MediaPreviewFailure>;

struct MediaPreviewSourceFacts {
  MediaPreviewEpoch operationEpoch{};
  MediaPreviewEpoch activeEpoch{};
  MediaPreviewEpoch epochHighWater{};
  MediaTime target{};
  MediaTime actualDecodeStart{};
  // A preview source has one selected-video cursor and at most one retained
  // compressed head. It owns no audio cursor or decoded-frame queue.
  std::size_t stagedVideoHeads{0};
  std::size_t peakStagedVideoHeads{0};
  std::size_t stagedPayloadBytes{0};
  std::size_t peakStagedPayloadBytes{0};
  std::uint64_t samplesEmitted{0};
  std::uint64_t forwardRetargets{0};
  bool open{false};
  bool cancelled{false};
};

[[nodiscard]] bool validateMediaPreviewBinding(
    const MediaPreviewBinding& binding,
    std::string* error = nullptr) noexcept;
[[nodiscard]] bool mediaPreviewBindingMatchesBackend(
    const MediaPreviewBinding& binding,
    MediaSourceBackendKind backendKind) noexcept;
[[nodiscard]] bool validateMediaPreviewRequest(
    const MediaPreviewBinding& binding, MediaPreviewRequest request,
    std::string* error = nullptr) noexcept;
[[nodiscard]] bool validateMediaPreviewSample(
    const MediaSample& sample, const MediaPreviewBinding& binding,
    MediaPreviewEpoch expectedEpoch,
    std::string* error = nullptr) noexcept;
[[nodiscard]] bool validateMediaPreviewDiscontinuity(
    const MediaDiscontinuity& discontinuity,
    const MediaPreviewBinding& binding, MediaPreviewEpoch expectedEpoch,
    std::string* error = nullptr) noexcept;

// Single-owner, video-only preview pull boundary. Construction is resource
// cold: no file descriptor, asset, demux cursor, decoder, or sample head may
// exist until begin() accepts an exact epoch. begin(), advanceTarget(),
// readNext(), close(), and facts() are owner-confined; requestCancel() is
// prompt, noexcept, and may run concurrently with blocking backend work.
//
// A valid newer begin publishes its cancellation slot before blocking and
// retires any older cursor before creating the replacement. A successful
// begin may retain at most one selected-video sample head as its admission
// proof. readNext() transfers that head without speculative replacement.
class MediaPreviewSource {
 public:
  virtual ~MediaPreviewSource() = default;

  // The exact binding context is stable for this object's complete lifetime,
  // including after close(). Closing releases operational resources only.
  [[nodiscard]] virtual std::shared_ptr<const MediaSourcePreparedContext>
  preparedContext() const noexcept = 0;
  [[nodiscard]] virtual MediaPreviewBeginOutcome
  begin(MediaPreviewRequest request) noexcept = 0;
  // Reuses the active cursor only for a backend-supported nondecreasing
  // target. It never changes the epoch or allocates a second sample head.
  [[nodiscard]] virtual bool advanceTarget(
      MediaPreviewEpoch expectedEpoch, MediaTime target) noexcept = 0;
  [[nodiscard]] virtual MediaPreviewReadResult
  readNext(MediaPreviewEpoch expectedEpoch) noexcept = 0;
  // Stale and future epochs are inert.
  virtual void requestCancel(MediaPreviewEpoch epoch) noexcept = 0;
  virtual void close() noexcept = 0;
  [[nodiscard]] virtual MediaPreviewSourceFacts facts() const noexcept = 0;
};

// Backend-owned, allocation/resource-free factory object. Concrete factory
// construction must only install immutable code/configuration references.
// createMainSource()/createPreviewSource() may allocate one cold source
// object, but must not open a file or create an asset/cursor/reader. The first
// resource acquisition belongs to MediaSource::openLocalFile() or
// MediaPreviewSource::begin(), after the exact cancellation identity exists.
class MediaBackendFactory {
 public:
  virtual ~MediaBackendFactory() = default;

  [[nodiscard]] virtual MediaSourceBackendKind
  backendKind() const noexcept = 0;
  [[nodiscard]] virtual std::unique_ptr<MediaSource>
  createMainSource() const noexcept = 0;
  // Returns null unless binding is valid and its exact context kind equals
  // backendKind(). The returned source retains that exact context pointer.
  [[nodiscard]] virtual std::unique_ptr<MediaPreviewSource>
  createPreviewSource(MediaPreviewBinding binding) const noexcept = 0;
};

}  // namespace wam::media
