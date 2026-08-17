#pragma once

#include "media/native_media_source.hpp"

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>

namespace wam::media {

// One result vocabulary is shared by the two typed consumer ports. Accepted
// means an operation completed. Draining means bounded internal progress was
// made and the owner should call step() again. Backpressure always preserves
// dispatcher ownership of the pending event.
enum class NativeMediaConsumeResult : std::uint8_t {
  Accepted,
  Backpressure,
  Draining,
  Drained,
  StaleGeneration,
  Unsupported,
  Failed,
};

// Lifecycle calls are repeatable exact operations. Progress means bounded
// owner-thread work completed and another immediate step is useful;
// Quiescing means completion depends on an explicit consumer wake. Done is the
// only result that permits the dispatcher to publish a seek, cancellation, or
// close commit.
enum class NativeMediaConsumerProgress : std::uint8_t {
  Done,
  Progress,
  Quiescing,
  StaleGeneration,
  Unsupported,
  Failed,
};

// Exact, backend-neutral timeline facts for one consumer generation. The
// dispatcher derives this only from a validated source outcome plus the
// matching open/seek request; consumers never reconstruct it from seconds.
// presentationFloor is the first timestamp eligible for presentation. An
// Accurate generation may decode before that floor, while a KeyFrame
// generation deliberately presents from its actual decode start.
struct NativeMediaGenerationTimeline {
  MediaGeneration generation{0};
  MediaSeekMode mode{MediaSeekMode::Accurate};
  MediaTime requestedTarget{};
  MediaTime actualDecodeStart{};
  MediaTime presentationFloor{};
  // Exact zero of the admitted source presentation timeline only. This is
  // not proof of codec priming, edit-list, or encoded elementary-stream
  // origin; those require separate backend facts before audio may use them.
  bool startsAtStreamOrigin{false};
  // Independently source-proved audio decode/PCM-trim boundaries. This is
  // empty only when the descriptor has no selected audio track.
  MediaAudioGenerationWindow audioWindow{};

  friend constexpr bool operator==(const NativeMediaGenerationTimeline&,
                                   const NativeMediaGenerationTimeline&) =
      default;
};

// Transactional ownership boundary for a compressed sample. A consumer may
// inspect sample() without changing it. It obtains ownership only by calling
// take() exactly once and must then return Accepted. Returning Backpressure,
// or any other non-Accepted result, without leaving the delivery untouched is
// a consumer protocol failure. This makes lossless retry observable without
// exposing a mutable MediaSample reference.
class NativeMediaSampleDelivery final {
 public:
  [[nodiscard]] const MediaSample& sample() const noexcept;
  [[nodiscard]] MediaSample take() noexcept;

  NativeMediaSampleDelivery(const NativeMediaSampleDelivery&) = delete;
  NativeMediaSampleDelivery& operator=(const NativeMediaSampleDelivery&) =
      delete;

 private:
  explicit NativeMediaSampleDelivery(MediaSample& sample) noexcept;

  MediaSample* sample_{nullptr};
  std::uint8_t take_count_{0};

  friend class NativeMediaDispatcher;
};

// The ports are deliberately separate types even though their lifecycle
// shapes match. This prevents an audio session from being wired into the video
// route (or vice versa) while keeping this dispatcher independent of Apple,
// Qt, decoder, and renderer types.
class NativeVideoConsumer {
 public:
  virtual ~NativeVideoConsumer() = default;

  // timeline is immutable for the exact generation. Implementations that
  // retain it beyond this call copy the small POD value.
  [[nodiscard]] virtual NativeMediaConsumeResult configure(
      const MediaTrackDescriptor& track, MediaGeneration generation,
      const NativeMediaGenerationTimeline& timeline, std::string* error) = 0;
  [[nodiscard]] virtual NativeMediaConsumeResult capacity(
      MediaGeneration generation) = 0;
  [[nodiscard]] virtual NativeMediaConsumeResult trySample(
      NativeMediaSampleDelivery& delivery, std::string* error) = 0;
  [[nodiscard]] virtual NativeMediaConsumeResult discontinuity(
      const MediaDiscontinuity& discontinuity, std::string* error) = 0;
  [[nodiscard]] virtual NativeMediaConsumeResult endOfStream(
      const MediaEndOfStream& end, std::string* error) = 0;
  [[nodiscard]] virtual NativeMediaConsumerProgress drain(
      MediaGeneration generation, std::string* error) = 0;

  [[nodiscard]] virtual NativeMediaConsumerProgress cancel(
      MediaGeneration generation) noexcept = 0;
  // Called only after the source has successfully installed nextGeneration.
  // Repeated calls with the same exact pair and timeline resume one operation.
  // No route may admit nextGeneration until it returns Done.
  [[nodiscard]] virtual NativeMediaConsumerProgress flush(
      MediaGeneration retiredGeneration,
      MediaGeneration nextGeneration,
      const NativeMediaGenerationTimeline& timeline) noexcept = 0;
  // Exact terminal retirement is distinct from emergency close. The first
  // accepted pair owns the retirement operation; only that exact pair may be
  // retried. retiredGeneration is this port's highest installed or otherwise
  // exposed generation and may be zero when the port was never configured.
  [[nodiscard]] virtual NativeMediaConsumerProgress retire(
      MediaGeneration retiredGeneration,
      MediaGeneration invalidationGeneration) noexcept = 0;
  [[nodiscard]] virtual NativeMediaConsumerProgress close() noexcept = 0;
};

class NativeAudioConsumer {
 public:
  virtual ~NativeAudioConsumer() = default;

  // See NativeVideoConsumer::configure() for timeline lifetime.
  [[nodiscard]] virtual NativeMediaConsumeResult configure(
      const MediaTrackDescriptor& track, MediaGeneration generation,
      const NativeMediaGenerationTimeline& timeline, std::string* error) = 0;
  [[nodiscard]] virtual NativeMediaConsumeResult capacity(
      MediaGeneration generation) = 0;
  [[nodiscard]] virtual NativeMediaConsumeResult trySample(
      NativeMediaSampleDelivery& delivery, std::string* error) = 0;
  [[nodiscard]] virtual NativeMediaConsumeResult discontinuity(
      const MediaDiscontinuity& discontinuity, std::string* error) = 0;
  [[nodiscard]] virtual NativeMediaConsumeResult endOfStream(
      const MediaEndOfStream& end, std::string* error) = 0;
  [[nodiscard]] virtual NativeMediaConsumerProgress drain(
      MediaGeneration generation, std::string* error) = 0;

  [[nodiscard]] virtual NativeMediaConsumerProgress cancel(
      MediaGeneration generation) noexcept = 0;
  [[nodiscard]] virtual NativeMediaConsumerProgress flush(
      MediaGeneration retiredGeneration,
      MediaGeneration nextGeneration,
      const NativeMediaGenerationTimeline& timeline) noexcept = 0;
  [[nodiscard]] virtual NativeMediaConsumerProgress retire(
      MediaGeneration retiredGeneration,
      MediaGeneration invalidationGeneration) noexcept = 0;
  [[nodiscard]] virtual NativeMediaConsumerProgress close() noexcept = 0;
};

// Every lifecycle method above must be idempotent for its exact arguments.
// Consumer destruction must also remain memory-safe after any lifecycle
// result, including Quiescing: a callback-owning implementation is responsible
// for retaining/quarantining its opaque control until callbacks are gone. The
// dispatcher's observable close proof still requires explicit Done from both
// ports; its destructor never upgrades Quiescing to Done.

enum class NativeMediaDispatcherState : std::uint8_t {
  Fresh,
  Ready,
  Draining,
  Exhausted,
  Seeking,
  Cancelling,
  Closing,
  Retiring,
  Unsupported,
  Cancelled,
  Failed,
  Closed,
};

enum class NativeMediaDispatcherFailure : std::uint8_t {
  None,
  MissingDependency,
  InvalidOpenRequest,
  SourceOpen,
  InvalidDescriptor,
  InvalidTimeline,
  ConsumerConfiguration,
  ConsumerProtocol,
  SourceRead,
  InvalidSample,
  InvalidEvent,
  FormatChanged,
  Consumer,
  Seek,
  Flush,
};

// Stable diagnostic name for a terminal dispatcher failure. Every terminal
// failure the session can publish collapses onto one of a handful of generic
// protocol-level FailureReason values, so the exact class that actually fired
// is otherwise unobservable from a stderr capture. Never returns nullptr.
[[nodiscard]] const char* nativeMediaDispatcherFailureName(
    NativeMediaDispatcherFailure failure) noexcept;

enum class NativeMediaPendingKind : std::uint8_t {
  None,
  VideoSample,
  AudioSample,
  VideoDiscontinuity,
  AudioDiscontinuity,
  VideoEndOfStream,
  AudioEndOfStream,
};

enum class NativeMediaDispatcherAction : std::uint8_t {
  Idle,
  VideoSample,
  AudioSample,
  VideoDiscontinuity,
  AudioDiscontinuity,
  VideoEndOfStream,
  AudioEndOfStream,
  AudioProgress,
  VideoProgress,
  SourceExhausted,
  BlockedAudio,
  BlockedVideo,
  SeekQuiescing,
  SeekCommitted,
  CancelQuiescing,
  CloseQuiescing,
  RetireQuiescing,
  Exhausted,
  Cancelled,
  Failed,
  Closed,
};

// No dispatcher method polls or schedules a timer. CallAgain means the last
// bounded operation made progress. AudioConsumer/VideoConsumer mean the owner
// must arrange a capacity notification from that consumer. Command means the
// machine is quiescent but can still accept an owner command such as seek.
enum class NativeMediaDispatcherWait : std::uint8_t {
  CallAgain,
  AudioConsumer,
  VideoConsumer,
  Consumers,
  Command,
  Terminal,
};

struct NativeMediaDispatcherStep {
  NativeMediaDispatcherAction action{NativeMediaDispatcherAction::Idle};
  NativeMediaDispatcherWait wait{NativeMediaDispatcherWait::Command};
  NativeMediaDispatcherState state{NativeMediaDispatcherState::Fresh};
  NativeMediaDispatcherFailure failure{NativeMediaDispatcherFailure::None};
  MediaGeneration generation{0};
  MediaTrackId track{0};
};

enum class NativeMediaDispatcherOpenStatus : std::uint8_t {
  Rejected,
  Ready,
  Unsupported,
  Cancelled,
  Failed,
};

struct NativeMediaDispatcherOpenOutcome {
  NativeMediaDispatcherOpenStatus status{
      NativeMediaDispatcherOpenStatus::Rejected};
  MediaGeneration generation{0};
  MediaTime actualDecodeStart{};
  NativeMediaGenerationTimeline timeline{};
};

enum class NativeMediaDispatcherSeekStatus : std::uint8_t {
  Rejected,
  Pending,
  Accepted,
  Failed,
};

struct NativeMediaDispatcherSeekOutcome {
  NativeMediaDispatcherSeekStatus status{
      NativeMediaDispatcherSeekStatus::Rejected};
  MediaGeneration generation{0};
  MediaTime actualDecodeStart{};
  NativeMediaGenerationTimeline timeline{};
};

enum class NativeMediaDispatcherLifecycleStatus : std::uint8_t {
  Rejected,
  Pending,
  Done,
  Failed,
};

struct NativeMediaDispatcherLifecycleOutcome {
  NativeMediaDispatcherLifecycleStatus status{
      NativeMediaDispatcherLifecycleStatus::Rejected};
  MediaGeneration generation{0};
};

enum class NativeMediaDispatcherLifecycleKind : std::uint8_t {
  None,
  Seek,
  Cancel,
  Close,
  Retire,
  FailureCancel,
  FailureClose,
};

struct NativeMediaDispatcherStats {
  NativeMediaDispatcherState state{NativeMediaDispatcherState::Fresh};
  NativeMediaDispatcherFailure failure{NativeMediaDispatcherFailure::None};
  NativeMediaDispatcherAction lastAction{NativeMediaDispatcherAction::Idle};
  NativeMediaDispatcherWait lastWait{NativeMediaDispatcherWait::Command};
  NativeMediaPendingKind pending{NativeMediaPendingKind::None};
  NativeMediaDispatcherLifecycleKind lifecycle{
      NativeMediaDispatcherLifecycleKind::None};
  MediaGeneration generation{0};
  MediaGeneration operationGeneration{0};
  MediaGeneration consumerGeneration{0};
  // Exact owner of the retained source result, including marker-only results.
  // Zero means there is no pending result. For a sample, pendingPayloadBytes is
  // its logical compressed payload length; the dispatcher owns that exact
  // lease until it transfers to a consumer or clears the pending result.
  MediaGeneration pendingGeneration{0};
  MediaTrackId selectedVideo{0};
  MediaTrackId selectedAudio{0};
  std::size_t pendingPayloadBytes{0};
  // Lifetime diagnostic high-water only. Never sum it with source/consumer
  // high-waters; only synchronized current ownership transitions establish a
  // concurrent aggregate peak.
  std::size_t peakPendingPayloadBytes{0};
  bool videoConfigured{false};
  bool audioConfigured{false};
  bool videoEndOfStream{false};
  bool audioEndOfStream{false};
  bool videoDrained{false};
  bool audioDrained{false};
  bool sourceExhausted{false};
  bool lifecycleVideoDone{true};
  bool lifecycleAudioDone{true};
  MediaGeneration lifecycleRetiredGeneration{0};
  MediaGeneration lifecycleTargetGeneration{0};
  MediaGeneration videoExposedGeneration{0};
  MediaGeneration audioExposedGeneration{0};
  MediaGeneration retirementExpectedGeneration{0};
  MediaGeneration retirementInvalidationGeneration{0};
  std::uint64_t openAttempts{0};
  std::uint64_t sourceReads{0};
  std::uint64_t videoSamples{0};
  std::uint64_t audioSamples{0};
  std::uint64_t videoDiscontinuities{0};
  std::uint64_t audioDiscontinuities{0};
  std::uint64_t videoEndMarkers{0};
  std::uint64_t audioEndMarkers{0};
  std::uint64_t videoBackpressure{0};
  std::uint64_t audioBackpressure{0};
  std::uint64_t consumerProgress{0};
  std::uint64_t acceptedSeeks{0};
};

// Deterministic single-owner demux/dispatch core. It creates no timer,
// callback, or queue, and no thread outlives the call that made it: the only
// thread this class ever creates is the open-time audio configure worker
// described below, which is always joined inside openLocalFile(). Exactly one
// MediaSource is opened once, and read admission is per lane rather than
// global.
//
// Parallel open-time configuration. VTDecompressionSessionCreate and
// AudioUnitInitialize are independent and both IPC-bound, so configuring the
// two ports one after the other charged every open the sum of their latencies.
// openLocalFile() therefore configures audio on one worker thread while it
// configures video on the owner thread, and joins that worker before it
// decides any verdict. Both ports are marked configured and stamped with the
// exact generation on the owner thread before either configure() runs, so the
// old exposure invariant holds unchanged in intent: a port is accounted from
// the moment it can be called, never merely from the moment it succeeds. The
// worker mutates no dispatcher state, so the join is the single owner-thread
// transition that the staged/pending generation facts can observe; there is no
// half-exposed state to sample. When video configure fails after audio
// configure succeeded, audio is already accounted as configured at the exact
// generation, and the ordinary FailureCancel and retire() machinery retires it
// exactly once at that generation -- configured ports are always retired
// ports, whichever port lost.
//
// Lane admission. MediaSource::readNext() is a single merged pull, so the
// dispatcher cannot ask for one track: it must own storage for whatever the
// next event turns out to be. The audio lane keeps the original capacity-one
// rule: an audio consumer that reports Backpressure retains the sole pending
// event and closes the read gate, because a full audio buffer already means
// the pipeline is ahead. The video lane instead owns a bounded read-ahead
// queue: a video consumer that reports Backpressure defers its event into that
// queue and the gate stays open, so audio source reads continue while video is
// at capacity. This is the structural break in the old cycle "video full ->
// no reads -> PCM ring empties -> audio-owned clock freezes -> video can never
// become due -> video stays full". The queue is bounded by both an event count
// and a soft payload high-water; the video lane also stops reading ahead once
// its end-of-stream marker is queued, so a later MediaSourceExhausted can
// never be observed before both lanes have ended.
//
// Seek-settle read-ahead. The audio capacity-one rule rests on "a full audio
// buffer means the pipeline is ahead", which holds whenever the audio output
// is running. It is false in exactly one window: an exact seek commit holds
// the audio-owned clock paused at the target with a deliberately primed PCM
// ring, and releases it only once video draws the frame covering that target.
// There the full ring is the commit's own goal state, so it can never retire a
// slab on its own, and closing the merged read on it starves the video decoder
// of the compressed access units its bounded reorder window still needs to
// emit that very frame -- a silent deadlock whose visibility depends only on
// how many access units past the target the stream's GOP structure requires.
// setSeekSettleReadAhead() lets the session name that window. While it is set,
// a refused audio event goes into a bounded audio read-ahead lane exactly the
// way video's does and the gate stays open; outside it the audio lane is never
// written and capacity-one is unchanged. A lane already holding events always
// drains in order ahead of a new read, whether or not the window is still on.
//
// seek() is deliberately source-first: the old pending sample and old
// consumer generation remain intact while source.seek() may block. Only an
// exact successful new source outcome enters the non-observable commit phase
// that flushes both consumers, releases the old pending event, and publishes
// the new generation. A failed source seek burns the attempted generation and
// fails closed without pretending the old source is recoverable.
class NativeMediaDispatcher final {
 public:
  // Bounded video-lane read-ahead held while the video consumer is at
  // capacity. The count covers roughly 0.8 s of 30 fps video, which is far
  // more than any presentation hiccup this pipeline produces, and the byte
  // high-water keeps a pathological bitrate from turning that count into an
  // unbounded lease. The byte value is a read-admission high-water, not a hard
  // ceiling: the event that crosses it is still stored, so the worst-case
  // retained payload is that value plus one maximum video sample.
  static constexpr std::size_t kLaneReadAheadEvents = 24;
  static constexpr std::size_t kVideoReadAheadPayloadBytes =
      4U * 1024U * 1024U;
  // Seek-settle audio read-ahead high-water. Compressed audio access units are
  // small, so the event count is the binding bound here; the byte value only
  // keeps a pathological bitrate from turning that count into a large lease.
  static constexpr std::size_t kAudioReadAheadPayloadBytes = 512U * 1024U;

  // Worst-case retained read-ahead payload. The byte values above are read-
  // ADMISSION high-waters, not ceilings: the event that crosses one is still
  // stored, so one maximum sample may land on top of it. Spelling that out as
  // a constant and asserting it matters because admission checks bytes
  // (laneHasReadAheadRoom) but the lane writers enforce only the event count.
  // The structural cap is therefore 24 x 8 MiB = 192 MiB of video payload --
  // sixteen times the figure this header advertises -- held down only by an
  // unchecked ordering invariant. These asserts pin the advertised number so a
  // future change to either limit has to confront the real bound.
  static constexpr std::size_t kMaximumRetainedVideoReadAheadBytes =
      kVideoReadAheadPayloadBytes +
      MediaSourceLimits::kHardMaximumVideoSampleBytes;
  static constexpr std::size_t kMaximumRetainedAudioReadAheadBytes =
      kAudioReadAheadPayloadBytes +
      MediaSourceLimits::kHardMaximumAudioSampleBytes;
  static_assert(kMaximumRetainedVideoReadAheadBytes <= 12U * 1024U * 1024U,
                "retained video read-ahead exceeds its documented 12 MiB");
  static_assert(kMaximumRetainedAudioReadAheadBytes <= 1024U * 1024U,
                "retained audio read-ahead exceeds its documented 1 MiB");
  static_assert(kLaneReadAheadEvents != 0,
                "a zero-length lane makes read admission unreachable");

  NativeMediaDispatcher(std::unique_ptr<MediaSource> source,
                        std::unique_ptr<NativeVideoConsumer> video,
                        std::unique_ptr<NativeAudioConsumer> audio) noexcept;
  ~NativeMediaDispatcher();

  NativeMediaDispatcher(const NativeMediaDispatcher&) = delete;
  NativeMediaDispatcher& operator=(const NativeMediaDispatcher&) = delete;
  NativeMediaDispatcher(NativeMediaDispatcher&&) = delete;
  NativeMediaDispatcher& operator=(NativeMediaDispatcher&&) = delete;

  [[nodiscard]] NativeMediaDispatcherOpenOutcome openLocalFile(
      const std::filesystem::path& path,
      const MediaSourceOpenOptions& options,
      MediaGeneration generation) noexcept;
  [[nodiscard]] NativeMediaDispatcherStep step() noexcept;
  [[nodiscard]] NativeMediaDispatcherSeekOutcome seek(
      const MediaSourceSeekRequest& request) noexcept;

  // Prompt forwarding seam for an owner whose source call is armed or
  // blocked. Every nonzero generation is forwarded to MediaSource, including
  // while armOperation() has committed its exact slot but the dispatcher has
  // not yet published operationGeneration. MediaSource is the sole authority
  // that makes stale and future generations inert. Object destruction must
  // not race this call.
  void requestCancel(MediaGeneration generation) noexcept;
  // Owner-thread cancellation also retires the two consumer generations and
  // releases the single pending event. Stale/future generations are inert.
  [[nodiscard]] NativeMediaDispatcherLifecycleOutcome cancel(
      MediaGeneration generation) noexcept;
  // Public close is exact-generation. A Fresh dispatcher closes with zero.
  [[nodiscard]] NativeMediaDispatcherLifecycleOutcome close(
      MediaGeneration generation) noexcept;
  // Exact owner-visible terminal retirement. expectedGeneration names the
  // currently published dispatcher generation. invalidationGeneration must
  // be strictly newer than every generation the source, dispatcher, or either
  // consumer could have observed, including a pending seek target. A valid
  // first call cancels/closes the source and releases pending source data
  // before either consumer is asked to retire. Exact retries resume the same
  // pair; every other pair is inert.
  //
  // The exposure proof covers only generations exposed by this dispatcher
  // through configure()/flush(). A composition that pre-arms a concrete port
  // before handing it to the dispatcher must retire that pre-arm through an
  // explicit session-owned seam; it must not treat this outcome as proof for
  // that unobservable generation.
  [[nodiscard]] NativeMediaDispatcherLifecycleOutcome retire(
      MediaGeneration expectedGeneration,
      MediaGeneration invalidationGeneration) noexcept;

  [[nodiscard]] std::shared_ptr<const MediaSourceDescriptor>
  descriptor() const noexcept;
  // Exact immutable backend identity admitted by Ready. This pointer remains
  // stable across every accepted seek and is released with the descriptor at
  // terminal close/retirement.
  [[nodiscard]] std::shared_ptr<const MediaSourcePreparedContext>
  preparedContext() const noexcept;
  // The last fully published consumer generation. During a quiescing seek,
  // this deliberately remains the retired generation; the candidate timeline
  // is returned by seek() and retained privately for exact flush retries.
  [[nodiscard]] std::optional<NativeMediaGenerationTimeline>
  timeline() const noexcept;
  // All methods, including stats(), are serialized on the dispatcher owner.
  // Reentrant consumer callbacks and arbitrary cross-thread polling are not a
  // coherent memory checkpoint. The session worker publishes this POD through
  // its own synchronization boundary for external telemetry.
  [[nodiscard]] NativeMediaDispatcherStats stats() const noexcept;

  // Diagnostic-only. The error text produced by whichever port, source or
  // validator refused the operation that drove this dispatcher terminal. Empty
  // when the refusing seam produced no text. Deliberately kept out of stats()
  // so the hot per-step POD copy stays allocation free; read it only on a
  // failure path. Serialized on the dispatcher owner like every other method.
  [[nodiscard]] const std::string& failureMessage() const noexcept;

  // Names the exact-seek commit window in which the audio route is paused at
  // the target with a primed ring and only a video draw can release it. See
  // the seek-settle note above the class. Idempotent; clearing it never
  // discards an already-deferred audio event.
  void setSeekSettleReadAhead(bool enabled) noexcept;

 private:
  enum class PendingLaneHead : std::uint8_t { None, Video, Audio };

  // Fixed-storage FIFO. No dispatcher path allocates for read-ahead.
  struct ReadAheadLane {
    std::array<std::optional<MediaSourceReadResult>, kLaneReadAheadEvents>
        events{};
    std::size_t head{0};
    std::size_t size{0};
    std::size_t payloadBytes{0};
    // Latched once this lane's end-of-stream marker is queued. Read-ahead for
    // the lane stops there so a later MediaSourceExhausted can never be
    // observed before both lanes have actually ended.
    bool ended{false};
  };

  [[nodiscard]] NativeMediaDispatcherStep routePending() noexcept;
  // True only while the session-named seek-settle window is open and the audio
  // read-ahead lane still has room. The single predicate that decides whether
  // audio backpressure defers into a lane or keeps capacity-one semantics.
  [[nodiscard]] bool seekSettleAudioLaneOpen() const noexcept;
  [[nodiscard]] NativeMediaDispatcherStep deferBlockedLaneEvent(
      bool isVideo, MediaTrackId track) noexcept;
  [[nodiscard]] NativeMediaDispatcherStep maintainAudio() noexcept;
  [[nodiscard]] NativeMediaDispatcherStep maintainVideo() noexcept;
  // Video-lane progress that remains available while a refused audio event is
  // the head-of-line blocker. Returns Idle when the video route can make no
  // progress at all; the caller then parks on the blocked audio consumer.
  [[nodiscard]] NativeMediaDispatcherStep
  advanceVideoWhileAudioBlocked() noexcept;
  [[nodiscard]] NativeMediaDispatcherStep checkReadCapacity() noexcept;
  [[nodiscard]] NativeMediaDispatcherStep advanceLifecycle() noexcept;
  [[nodiscard]] NativeMediaDispatcherStep makeStep(
      NativeMediaDispatcherAction action, NativeMediaDispatcherWait wait,
      MediaTrackId track = 0) noexcept;
  [[nodiscard]] NativeMediaDispatcherStep failStep(
      NativeMediaDispatcherFailure failure) noexcept;
  void fail(NativeMediaDispatcherFailure failure,
            MediaGeneration sourceGeneration = 0) noexcept;
  void beginLifecycle(NativeMediaDispatcherLifecycleKind kind,
                      MediaGeneration retiredGeneration,
                      MediaGeneration targetGeneration) noexcept;
  void beginFailureLifecycle(NativeMediaDispatcherLifecycleKind kind,
                             MediaGeneration sourceGeneration) noexcept;
  void forceClose() noexcept;
  void resetGenerationFacts() noexcept;
  [[nodiscard]] bool allSelectedEnded() const noexcept;
  [[nodiscard]] bool allSelectedDrained() const noexcept;
  [[nodiscard]] NativeMediaPendingKind pendingKind() const noexcept;
  void installPending(MediaSourceReadResult&& result);
  void clearPending() noexcept;
  // Releases every retained source event, including the deferred video lane.
  // Lifecycle transitions use this; a routed-and-accepted event uses
  // clearPending() so the deferred lane survives.
  void releaseRetainedEvents() noexcept;
  [[nodiscard]] bool laneHasReadAheadRoom(const ReadAheadLane& lane,
                                          std::size_t payloadHighWater)
      const noexcept;
  // Moves the retained pending event to the front of its lane queue. Only an
  // event that lane's consumer refused reaches this, and such an event is
  // always the oldest un-routed event of that lane.
  void deferPendingIntoLane(ReadAheadLane& lane) noexcept;
  // Appends a validated event that arrived while older events of the same lane
  // are still queued. The consumer is deliberately not called: per-lane order
  // is preserved by draining the queue head first.
  [[nodiscard]] bool queuePendingIntoLane(ReadAheadLane& lane) noexcept;
  [[nodiscard]] bool takeLaneHead(ReadAheadLane& lane,
                                  PendingLaneHead head) noexcept;
  [[nodiscard]] static NativeMediaPendingKind eventPendingKind(
      const MediaSourceReadResult& event, MediaTrackId selectedVideo) noexcept;
  [[nodiscard]] MediaGeneration highestExposedGeneration() const noexcept;

  std::unique_ptr<MediaSource> source_;
  std::unique_ptr<NativeVideoConsumer> video_;
  std::unique_ptr<NativeAudioConsumer> audio_;
  std::shared_ptr<const MediaSourceDescriptor> descriptor_;
  std::shared_ptr<const MediaSourcePreparedContext> prepared_context_;
  std::optional<MediaSourceReadResult> pending_;
  MediaGeneration pending_generation_{0};
  std::size_t pending_payload_bytes_{0};
  std::size_t peak_pending_payload_bytes_{0};
  ReadAheadLane video_lane_{};
  // Written only inside the seek-settle window named by
  // setSeekSettleReadAhead(); empty in every other state, which is what keeps
  // the audio capacity-one rule intact for ordinary playback.
  ReadAheadLane audio_lane_{};
  // Names the lane whose head was taken into pending_. That event is older
  // than everything still queued behind it, so it is the one event that may be
  // offered to its consumer while its lane queue is non-empty.
  PendingLaneHead pending_lane_head_{PendingLaneHead::None};
  // Last observed per-lane capacity admission, published by
  // checkReadCapacity() so step() can prefer draining a lane over reading.
  bool video_capacity_open_{false};
  bool audio_capacity_open_{false};
  bool seek_settle_read_ahead_{false};
  std::optional<NativeMediaGenerationTimeline> timeline_;
  std::optional<NativeMediaGenerationTimeline> lifecycle_timeline_;
  MediaSourceLimits limits_{};
  NativeMediaDispatcherStats stats_{};
  // Diagnostic text for the current terminal failure. Written only on failure
  // paths on the dispatcher owner thread; cleared when a new open begins.
  std::string failure_message_{};
  MediaGeneration consumer_generation_{0};
  MediaGeneration video_exposed_generation_{0};
  MediaGeneration audio_exposed_generation_{0};
  MediaGeneration lifecycle_video_retired_generation_{0};
  MediaGeneration lifecycle_audio_retired_generation_{0};
  MediaGeneration retirement_expected_generation_{0};
  MediaGeneration retirement_invalidation_generation_{0};
  std::atomic<MediaGeneration> operation_generation_{0};
};

}  // namespace wam::media
