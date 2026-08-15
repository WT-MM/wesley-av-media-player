#pragma once

#include "media/native_media_dispatcher.hpp"
#include "native_media_clock.hpp"
#include "native_tracked_video_output.hpp"
#include "video_toolbox_decoder.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>

namespace wam::macos {

#if defined(WAM_NATIVE_VIDEO_CONSUMER_TESTING)
struct NativeVideoConsumerTestAccess;
#endif

using NativeVideoConsumerWake = void (*)(void* context) noexcept;

// Shared edge notification for decoder callbacks and tracked-output progress.
// signal may run on an Apple, GUI, or render callback. It must be wait-free,
// allocation-free, noexcept, and non-reentrant. The seam and its context must
// outlive retire()/close() Done and every signal already in progress; the
// owner normally points both audio and video at one coalescing dispatcher
// wake.
struct NativeVideoConsumerWakeSeam {
  NativeVideoConsumerWake signal{nullptr};
  void* context{nullptr};
};

using NativeVideoClockSample =
    NativeMediaClockSnapshot (*)(void* context) noexcept;

// Immutable owner-thread view of the audio-authoritative media clock. The
// consumer calls sample only from its dispatcher worker; the seam creates no
// polling thread or timer. context must outlive retire()/close() Done.
// ticksPerSecond is the exact host frequency used by snapshot host-tick
// fields. The seam's owner must also arrange a consumer wake whenever
// authoritative media time advances far enough to revisit a published
// nextDueHostTicks. This consumer never creates a timer to manufacture that
// missing progress edge; supplying it is entirely the seam owner's obligation.
// Native v1 has two owners that discharge it: an audio-authoritative route,
// whose AudioUnit callback consumes the published deadline from the shared
// wake, and an audio-less (silent) route, whose session worker waits on its
// own semaphore with that same deadline (NativeSilentTimebase and
// NativeMediaSessionWake::setHostPacedDeadlines).
struct NativeVideoClockSeam {
  NativeVideoClockSample sample{nullptr};
  void* context{nullptr};
  std::uint64_t ticksPerSecond{0};
  bool progressWakeDriven{false};
};

enum class NativeVideoConsumerArmProgress : std::uint8_t {
  Done,
  Quiescing,
  StaleGeneration,
  Failed,
};

// Owner-progressive handoff of the process-wide decoded-surface budget to the
// private preview decoder. KeyFrameRequired is nonfatal: it means the main
// decoder has been synchronously emptied at the active generation and cannot
// safely resume on an unknown/delta access unit. The gate remains closed.
enum class NativeVideoConsumerPreviewProgress : std::uint8_t {
  Done,
  Progress,
  Quiescing,
  StaleGeneration,
  KeyFrameRequired,
  Failed,
};

enum class NativeVideoConsumerPreviewRelease : std::uint8_t {
  UnknownOrDelta,
  NextSampleIsKeyFrame,
};

enum class NativeVideoConsumerFailure : std::uint8_t {
  None,
  MissingDependency,
  InvalidArm,
  InvalidTrack,
  InvalidTimeline,
  DecoderConfiguration,
  Decoder,
  InvalidSample,
  UnsupportedDiscontinuity,
  InvalidFrameTiming,
  Output,
  SequenceExhausted,
  Lifecycle,
};

struct NativeVideoConsumerFacts {
  media::MediaGeneration generation{0};
  media::MediaGeneration armedGeneration{0};
  NativeTrackedFrameSequence nextFrameSequence{};
  NativeTrackedFrameSequence awaitingDraw{};
  std::uint64_t decodedFrames{0};
  std::uint64_t submittedFrames{0};
  std::uint64_t drawnFrames{0};
  // Output-owned sequence high-water, including an event still pending in the
  // output mailbox. Started uses this as its linearized baseline and
  // VideoDrawProof echoes a later real FrameDrawn in the same domain.
  std::uint64_t lastOutputEventSequence{0};
  std::uint64_t discardedPrerollFrames{0};
  std::uint64_t discardedLateFrames{0};
  // Compressed open-GOP leading pictures retired without decode because the
  // random-access sample this decode began on presents after them.
  std::uint64_t discardedLeadingPictures{0};
  media::MediaTime nextDueMediaTime{};
  std::uint64_t nextDueHostTicks{0};
  std::size_t decodedQueueDepth{0};
  bool configured{false};
  bool endOfStreamBegun{false};
  bool endOfStreamDone{false};
  bool heldFrame{false};
  bool outputBlocked{false};
  bool nextDueKnown{false};
  media::MediaGeneration previewQuiesceGeneration{0};
  media::MediaGeneration previewReleasedGeneration{0};
  bool previewQuiesceStarted{false};
  bool previewQuiesced{false};
  bool previewResumeNeedsKeyFrame{false};
  bool closed{false};
  NativeVideoConsumerFailure failure{NativeVideoConsumerFailure::None};
  VideoToolboxDecoderStats decoder{};
  NativeTrackedVideoOutputFacts output{};
};

struct NativeVideoConsumerQuarantineFacts {
  std::uint64_t rejectedCreates{0};
  std::uint64_t transfers{0};
  std::uint64_t recoveries{0};
  bool quarantined{false};
};

// WAM-owned video route for NativeMediaDispatcher. This object never owns an
// AVAsset/AVAssetReader, thread, dispatch queue, display link, or timer. All
// methods except the immutable wake callbacks are confined to the single
// dispatcher worker.
//
// Ownership is bounded to kMaximumDecodedSurfaceOwnership decoded surfaces
// held by VideoToolbox (in-flight submissions plus retained reorder frames),
// one decoded-queue FrameLease, one scheduler-held FrameLease, and the tracked
// output's one admitted FrameLease. Compressed admission is gated by decoder
// credit and by that decoded-surface bound: presentation state (a frame not
// yet due, or a draw not yet acknowledged) deliberately does not throttle
// decode, so the route is paced by the media clock rather than by the
// display, and a compositor that stops presenting cannot pin the decoder.
//
// The consumer never wraps or invokes the legacy NativeVideoPipeline. The shared output reference is a scene-graph
// lifetime requirement, not a fan-out seam: exactly one consumer may submit
// through a tracked output instance. Native v1 admits one process-wide graph,
// matching WAM's single playback route and NativeAudioSession; a second create
// is rejected until the first graph closes Done or its quarantine is recovered.
// The future NativeMediaSession/playback owner must reject/fallback before
// resource activation unless the selected audio and video durations are exact
// and the audio duration covers the video duration apart from the bounded
// container-artefact shortfall documented in native_video_limits.hpp
// (kMaximumSelectedAudioShortfallMilliseconds). The audio-authoritative clock
// cannot advance a longer video-only tail, and this consumer deliberately
// manufactures neither synthetic silence nor a timer; the tolerated shortfall
// is exactly the tail it may leave unpresented at the end of a file.
class NativeVideoConsumer final : public media::NativeVideoConsumer {
 public:
  // Compressed read-ahead inside the video route is maxInFlight + the decoded
  // queue + the scheduler-held frame. Two in-flight frames left only four
  // frames (~133 ms at 30 fps) of lead, and a reordered H.264 High stream
  // spends more than that on its own decode/reorder latency: measured frames
  // reached the scheduler about 43 ms *after* their presentation interval had
  // closed, so every other frame was retired late once the media clock ran at
  // a true 1.0x. Five in-flight frames restore a positive lead. This value
  // alone does not bound decoded IOSurface ownership: VideoToolbox retains
  // maxInFlight + codecReorderFrames decoded frames, so
  // kMaximumDecodedSurfaceOwnership below is what actually keeps the route
  // inside the process-wide budget (kNativeSurfaceBudgetMaximumSurfaces = 10):
  // at most five decoder-held surfaces, one decoded-queue lease, one
  // scheduler-held lease and the tracked output's one accepted lease.
  static constexpr std::size_t kMaximumDecoderInFlightFrames = 5;
  static constexpr std::size_t kDecodedQueueCapacity = 1;
  // Decoded frames are IOSurfaces charged against the process-wide
  // NativeSurfaceBudget, and VideoToolboxDecoder's own admission credit bounds
  // only decode ownership: it admits maxInFlightFrames + codecReorderFrames
  // retained decoded frames, which for any reordered stream is strictly more
  // than the five decoder-retained surfaces the ownership paragraph above
  // documents. This is the route's own bound on decoded-surface ownership
  // (in-flight decodes plus retained presentation frames), applied on top of
  // decoder credit so the documented accounting actually holds. It is a
  // resource bound, not a presentation gate: refused compressed samples stay
  // in the dispatcher's bounded video lane, so read-ahead is preserved as
  // cheap compressed bytes instead of scarce decoded surfaces.
  static constexpr std::size_t kMaximumDecodedSurfaceOwnership = 5;

  [[nodiscard]] static std::unique_ptr<NativeVideoConsumer> create(
      std::shared_ptr<void> externalLifetime,
      NativeVideoClockSeam clock,
      std::shared_ptr<NativeTrackedVideoOutput> output,
      NativeVideoConsumerWakeSeam wake,
      std::string* error = nullptr) noexcept;
  ~NativeVideoConsumer() override;

  [[nodiscard]] static std::unique_ptr<NativeVideoConsumer>
  recoverQuarantined() noexcept;
  [[nodiscard]] static NativeVideoConsumerQuarantineFacts
  quarantineFacts() noexcept;
  [[nodiscard]] static bool selectedTrackDurationsSupported(
      media::MediaTime audioDuration,
      media::MediaTime videoDuration) noexcept;

  NativeVideoConsumer(const NativeVideoConsumer&) = delete;
  NativeVideoConsumer& operator=(const NativeVideoConsumer&) = delete;
  NativeVideoConsumer(NativeVideoConsumer&&) = delete;
  NativeVideoConsumer& operator=(NativeVideoConsumer&&) = delete;

  // Before MediaSource is opened, the playback owner repeatedly calls this
  // with Prepare.reservedGeneration until Done. It applies the blank/output
  // generation asynchronously without forcing dispatcher configure() to
  // support Quiescing. A Done arm is consumed exactly once by configure().
  [[nodiscard]] NativeVideoConsumerArmProgress armFirstGeneration(
      media::MediaGeneration generation) noexcept;

  // Temporarily releases only main-decoder/scheduler surface ownership. The
  // exact active generation and tracked-output lifecycle stay unchanged.
  // The first valid call immediately gates dispatcher-facing admission,
  // synchronously retires decoder/sink/held frames at the same generation,
  // then waits for any already accepted tracked draw to publish its real
  // terminal event. Done proves the main output retains no frame.
  [[nodiscard]] NativeVideoConsumerPreviewProgress quiesceForPreview(
      media::MediaGeneration generation) noexcept;
  // A same-generation VideoToolbox flush necessarily requires a fresh key
  // frame. UnknownOrDelta therefore leaves the admission gate closed and
  // returns KeyFrameRequired. Normal seek flush or terminal retirement may
  // supersede a quiesce without calling this method.
  [[nodiscard]] NativeVideoConsumerPreviewProgress releasePreviewQuiesce(
      media::MediaGeneration generation,
      NativeVideoConsumerPreviewRelease release) noexcept;

  [[nodiscard]] media::NativeMediaConsumeResult configure(
      const media::MediaTrackDescriptor& track,
      media::MediaGeneration generation,
      const media::NativeMediaGenerationTimeline& timeline,
      std::string* error) override;
  [[nodiscard]] media::NativeMediaConsumeResult capacity(
      media::MediaGeneration generation) override;
  [[nodiscard]] media::NativeMediaConsumeResult trySample(
      media::NativeMediaSampleDelivery& delivery,
      std::string* error) override;
  [[nodiscard]] media::NativeMediaConsumeResult discontinuity(
      const media::MediaDiscontinuity& discontinuity,
      std::string* error) override;
  [[nodiscard]] media::NativeMediaConsumeResult endOfStream(
      const media::MediaEndOfStream& end,
      std::string* error) override;
  [[nodiscard]] media::NativeMediaConsumerProgress drain(
      media::MediaGeneration generation,
      std::string* error) override;
  [[nodiscard]] media::NativeMediaConsumerProgress cancel(
      media::MediaGeneration generation) noexcept override;
  [[nodiscard]] media::NativeMediaConsumerProgress flush(
      media::MediaGeneration retiredGeneration,
      media::MediaGeneration nextGeneration,
      const media::NativeMediaGenerationTimeline& timeline) noexcept override;
  // Exact Router/session retirement. retiredGeneration must equal the highest
  // generation exposed by the consumer, including a Quiescing pre-arm or seek
  // target. invalidationGeneration is supplied by the owner, must be strictly
  // newer than every consumer/decoder/output generation, and is forwarded
  // unchanged to each terminal dependency. The first valid pair is immutable.
  [[nodiscard]] media::NativeMediaConsumerProgress retire(
      media::MediaGeneration retiredGeneration,
      media::MediaGeneration invalidationGeneration) noexcept override;
  // Emergency/destructor teardown only. Router-visible retirement must use
  // retire() so no layer invents a terminal generation.
  [[nodiscard]] media::NativeMediaConsumerProgress close() noexcept override;

  [[nodiscard]] std::optional<NativeTrackedVideoEvent>
  takeOutputEvent() noexcept;
  [[nodiscard]] NativeVideoConsumerFacts facts() const noexcept;

 private:
  class Sink;
  struct Impl;

  explicit NativeVideoConsumer(std::unique_ptr<Impl> impl) noexcept;
  [[nodiscard]] static std::unique_ptr<Impl>& quarantineSlot() noexcept;
  std::unique_ptr<Impl> impl_;

#if defined(WAM_NATIVE_VIDEO_CONSUMER_TESTING)
  friend struct NativeVideoConsumerTestAccess;
#endif
};

#if defined(WAM_NATIVE_VIDEO_CONSUMER_TESTING)
// Fixture-free access to the owner-thread scheduler only. It never creates or
// replaces the production decoder and is absent from shipping objects.
struct NativeVideoConsumerTestAccess {
  [[nodiscard]] static bool installSchedulerGeneration(
      NativeVideoConsumer& consumer,
      const media::NativeMediaGenerationTimeline& timeline) noexcept;
  [[nodiscard]] static bool injectDecodedFrame(
      NativeVideoConsumer& consumer, FrameLease frame) noexcept;
  [[nodiscard]] static bool pumpScheduler(
      NativeVideoConsumer& consumer) noexcept;
  [[nodiscard]] static std::optional<media::MediaTime> checkedIntervalEnd(
      media::MediaTime presentation,
      media::MediaTime duration) noexcept;
  [[nodiscard]] static std::optional<media::MediaTimeOrder> compareToClock(
      media::MediaTime time, double clockSeconds) noexcept;
  // Exact open-GOP leading-picture predicate: true only for a non-key access
  // unit that presents strictly before the random-access sample this decode
  // began on.
  [[nodiscard]] static bool precedesGenerationStart(
      media::MediaTime presentation, bool keyFrame,
      const std::optional<media::MediaTime>& generationStart) noexcept;
};
#endif

}  // namespace wam::macos
