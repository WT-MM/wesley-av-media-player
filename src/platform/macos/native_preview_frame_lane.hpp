#pragma once

#include "avfoundation_preview_source.hpp"
#include "media/native_playback_contract.hpp"
#include "native_tracked_video_arbiter.hpp"
#include "video_toolbox_decoder.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <type_traits>

namespace wam::macos {

namespace preview_protocol = media::native_playback;

using NativePreviewFrameLaneWake = void (*)(void* context) noexcept;

struct NativePreviewFrameLaneWakeSeam {
  // Retained until the decoder has synchronously retired every callback.
  std::shared_ptr<void> lifetime;
  NativePreviewFrameLaneWake signal{nullptr};
  void* context{nullptr};
};

struct NativePreviewFrameLaneBinding {
  AVFoundationPreviewBinding source;
  preview_protocol::Generation activePlaybackGeneration{};
  // The exact owner stamp immediately preceding this lane's first preview.
  // Every accepted PreviewFrame must follow it in the same attempt.
  preview_protocol::Stamp acceptedThrough{};
};

// Cheap proof that the command's binary64 target has one exact MediaTime
// representation. The owner obtains it before publishing PreviewFrame and the
// lane never rounds the command through a guessed timescale.
class NativePreviewFrameTarget final {
 public:
  [[nodiscard]] double seconds() const noexcept { return seconds_; }
  [[nodiscard]] media::MediaTime exact() const noexcept { return exact_; }

 private:
  constexpr NativePreviewFrameTarget(double seconds,
                                     media::MediaTime exact) noexcept
      : seconds_(seconds), exact_(exact) {}

  double seconds_{0.0};
  media::MediaTime exact_{};

  friend class NativePreviewFrameLane;
};

enum class NativePreviewFrameRequestStatus : std::uint8_t {
  Accepted,
  Replaced,
  Invalid,
  Stale,
  Closed,
  Failed,
};

enum class NativePreviewFramePumpProgress : std::uint8_t {
  Idle,
  Progress,
  Quiescing,
  Failed,
  Stopped,
};

enum class NativePreviewFrameCancelProgress : std::uint8_t {
  Done,
  Quiescing,
  Stale,
  Failed,
};

struct NativePreviewFrameLaneFacts {
  std::uint64_t activePlaybackGeneration{0};
  std::uint64_t activeEpoch{0};
  std::uint64_t epochHighWater{0};
  NativeTrackedVideoPreviewSequence awaitingDraw{};
  std::size_t pendingCommands{0};
  std::size_t stagedCompressedSamples{0};
  std::size_t sinkFrames{0};
  std::size_t peakSinkFrames{0};
  // At most one decoded lease is retained for exact same-frame resubmission.
  // It aliases the same physical surface rather than acquiring another
  // decoded-surface budget entry.
  std::size_t cachedFrames{0};
  std::size_t peakCachedFrames{0};
  std::uint64_t acceptedRequests{0};
  std::uint64_t replacedRequests{0};
  // Production counts actual VideoToolbox configuration calls. The private
  // decoder-bypass test seam advances the same logical counter so focused
  // tests can prove the rebuild/reuse state machine deterministically.
  std::uint64_t decoderConfigurations{0};
  std::uint64_t decoderReuseRequests{0};
  std::uint64_t cachedFrameReuseRequests{0};
  std::uint64_t sourceSamples{0};
  // Compressed open-GOP leading pictures retired without decode because the
  // random-access sample this preview decode began on presents after them.
  std::uint64_t discardedLeadingPictures{0};
  std::uint64_t decodedFramesDiscarded{0};
  std::uint64_t framesSubmitted{0};
  std::uint64_t framesDrawn{0};
  std::uint64_t staleCompletions{0};
  bool active{false};
  bool cancelling{false};
  bool presentedPending{false};
  bool stopped{false};
  bool failed{false};
  std::string error;
  AVFoundationPreviewSourceFacts source{};
  VideoToolboxDecoderStats decoder{};
};

// Raw owner-thread leaf facts. Source, lane, and decoder byte fields describe
// distinct ownership stages and are not summed here. cachedFrames may alias a
// sink/output lease and therefore remains a count rather than a byte charge.
struct NativePreviewFrameLaneMemoryFacts {
  std::uint64_t sourceCurrentCompressedBytes{0};
  std::uint64_t sourcePeakCompressedBytes{0};
  std::uint64_t laneCurrentCompressedBytes{0};
  std::uint64_t lanePeakCompressedBytes{0};
  std::uint64_t decoderCurrentCompressedBytes{0};
  std::uint64_t decoderPeakCompressedBytes{0};
  std::size_t sinkFrames{0};
  std::size_t cachedFrames{0};
};
static_assert(
    std::is_trivially_copyable_v<NativePreviewFrameLaneMemoryFacts>);

#if defined(WAM_NATIVE_PREVIEW_FRAME_LANE_TESTING)
struct NativePreviewFrameLaneTestAccess;
#endif

// Owner-thread, wake-driven preview graph:
//
//   AVFoundationPreviewSource -> VideoToolboxDecoder -> one-frame sink
//   -> NativeTrackedVideoPreviewPort -> exact compositor FrameDrawn
//
// request(), pump(), cancel(), stop(), takePresented(), and facts() are all
// confined to one owner. Decoder callbacks may only enter the private
// capacity-one sink and signal wake. The lane creates no thread, queue, timer,
// audio state, dispatcher generation, or presenter lifecycle operation.
class NativePreviewFrameLane final {
 public:
  [[nodiscard]] static std::unique_ptr<NativePreviewFrameLane> create(
      NativePreviewFrameLaneBinding binding,
      std::shared_ptr<NativeTrackedVideoPreviewPort> output,
      NativePreviewFrameLaneWakeSeam wake) noexcept;
  [[nodiscard]] static std::optional<NativePreviewFrameTarget>
  preflightTarget(double seconds) noexcept;

  ~NativePreviewFrameLane();
  NativePreviewFrameLane(const NativePreviewFrameLane&) = delete;
  NativePreviewFrameLane& operator=(const NativePreviewFrameLane&) = delete;

  [[nodiscard]] NativePreviewFrameRequestStatus request(
      preview_protocol::PreviewFrame command,
      NativePreviewFrameTarget target) noexcept;
  // Cancels only the exact currently retained command. A stale command is
  // inert. An already submitted frame remains Quiescing until its real typed
  // terminal event is consumed; no draw or supersession is fabricated.
  [[nodiscard]] NativePreviewFrameCancelProgress cancel(
      const preview_protocol::PreviewFrame& command) noexcept;
  [[nodiscard]] NativePreviewFramePumpProgress pump() noexcept;
  [[nodiscard]] std::optional<preview_protocol::PreviewPresented>
  takePresented() noexcept;
  // Terminal for this lane and repeatable only with its exact active playback
  // generation. The main video facade alone owns generation flush/close.
  [[nodiscard]] NativePreviewFrameCancelProgress stop(
      preview_protocol::Generation activePlaybackGeneration) noexcept;
  [[nodiscard]] NativePreviewFrameLaneFacts facts() const noexcept;
  [[nodiscard]] NativePreviewFrameLaneMemoryFacts memoryFacts()
      const noexcept;

 private:
  struct Impl;
  explicit NativePreviewFrameLane(std::unique_ptr<Impl> impl) noexcept;
  std::unique_ptr<Impl> impl_;

#if defined(WAM_NATIVE_PREVIEW_FRAME_LANE_TESTING)
  friend struct NativePreviewFrameLaneTestAccess;
#endif
};

#if defined(WAM_NATIVE_PREVIEW_FRAME_LANE_TESTING)
// Shipping objects contain neither this factory nor the synthetic-frame seam.
struct NativePreviewFrameLaneTestAccess {
  [[nodiscard]] static std::unique_ptr<NativePreviewFrameLane> create(
      NativePreviewFrameLaneBinding binding,
      std::shared_ptr<NativeTrackedVideoPreviewPort> output,
      NativePreviewFrameLaneWakeSeam wake,
      std::unique_ptr<AVFoundationPreviewSource> source) noexcept;
  [[nodiscard]] static bool injectDecodedFrame(
      NativePreviewFrameLane& lane, FrameLease frame) noexcept;
  static void endDecodedStream(NativePreviewFrameLane& lane) noexcept;
  static void failNextRetainedFrameClone(
      NativePreviewFrameLane& lane) noexcept;
  static void setNextEpoch(NativePreviewFrameLane& lane,
                           std::uint64_t nextEpoch) noexcept;
};
#endif

}  // namespace wam::macos
