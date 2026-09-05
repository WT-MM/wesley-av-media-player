#pragma once

#include "media/live_caption_feed.hpp"
#include "media/native_playback_contract.hpp"
#include "avfoundation_asset_context.hpp"
#include "native_audio_session.hpp"
#include "native_preview_frame_lane.hpp"
#include "native_tracked_video_arbiter.hpp"
#include "native_tracked_video_output.hpp"
#include "native_video_consumer.hpp"

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <variant>

namespace wam::macos {

namespace native_playback = media::native_playback;
struct NativeMediaSessionTestAccess;

// One capacity-one edge shared by AudioUnit, VideoToolbox, the tracked Qt
// output, public commands, and fact-mailbox consumption. Callback-side signal
// is allocation-free, noexcept, and coalesces before waking the one session
// worker. The worker waits without a timer or polling interval.
class NativeMediaSessionWake final {
 public:
  [[nodiscard]] static std::shared_ptr<NativeMediaSessionWake>
  create() noexcept;
  ~NativeMediaSessionWake();

  NativeMediaSessionWake(const NativeMediaSessionWake&) = delete;
  NativeMediaSessionWake& operator=(const NativeMediaSessionWake&) = delete;

  [[nodiscard]] NativeAudioOutputWakeSeam audio() noexcept;
  [[nodiscard]] NativeVideoConsumerWakeSeam video() noexcept;
  [[nodiscard]] NativeTrackedVideoOutputWakeSeam trackedVideo() noexcept;

 private:
  struct Impl;
  explicit NativeMediaSessionWake(std::unique_ptr<Impl> impl) noexcept;
  static void signal(void* context) noexcept;
  void notify() noexcept;
  void wait() noexcept;
  void beginDrain() noexcept;
  void publishVideoDueHostTicks(std::uint64_t hostTicks) noexcept;
  // Arms the host-paced fallback heartbeat used by audio-less generations.
  // On the audio-authoritative route the AudioUnit render callback is the
  // only periodic edge that wakes the worker to draw a frame on time (it
  // consumes videoDueHostTicks through the audio wake seam). A silent
  // generation runs no output unit, so the worker instead waits on its own
  // semaphore with a deadline: the published video due tick when one is
  // armed, otherwise a bounded floor that reproduces the device-period
  // cadence the audio callback used to provide. Passing an unconfigured
  // clock disarms it and restores the untimed wait.
  void setHostPacedDeadlines(NativeMediaHostClock hostClock) noexcept;

  std::unique_ptr<Impl> impl_;

  friend class NativeMediaSession;
  friend struct NativeMediaSessionTestAccess;
};

struct NativeMediaSessionSourceBinding {
  native_playback::SourceKey sourceKey;
  std::filesystem::path localPath;
};

struct NativeMediaSessionDependencies {
  // Retains the GUI output and every opaque dependency supplied in the audio
  // call table. The session additionally retains its shared Wake object.
  std::shared_ptr<void> externalLifetime;
  std::shared_ptr<NativeMediaSessionWake> wake;
  std::shared_ptr<NativeTrackedVideoOutput> videoOutput;
  // Typed, lifecycle-free view of the same tracked presenter. Required so
  // preview frames cannot consume main-video event identities.
  std::shared_ptr<NativeTrackedVideoPreviewPort> previewOutput;
  NativeMediaHostClock hostClock{};
  NativeAudioUnitCallTable audioUnitCalls{};
  std::unique_ptr<NativeAudioConverterBackend> audioConverterBackend;
  // The live closed-caption tap the video consumer feeds; null when no one
  // reads captions.
  std::shared_ptr<media::captions::LiveCaptionFeed> captionFeed;
};

using NativeMediaSessionQueueObservations = bool (*)(
    std::shared_ptr<void> queuedLifetime, void* context) noexcept;

// A controller-owned queued edge. queue must only arrange a later call to
// takeObservations(); it must not synchronously drive Router actions. The
// session passes one owned lifetime ticket into each queue request, allowing
// the queued GUI closure to remain valid even if the session is destroyed
// before it runs. Returning true proves later work accepted that ticket;
// false guarantees no closure owns it, so retained observations remain
// retryable. queue is invoked only after releasing the session state lock. At
// most one accepted request is outstanding until the controller drains the
// observation slots.
struct NativeMediaSessionObservationEdge {
  std::shared_ptr<void> lifetime;
  NativeMediaSessionQueueObservations queue{nullptr};
  void* context{nullptr};
};

// Unforgeable result of the pure exact-position preflight. The controller
// retains this cheap token alongside the Router Prepare action and gives it
// back to prepare(); the session never reconverts the original binary64.
class NativeMediaSessionInitialPosition final {
 public:
  [[nodiscard]] double seconds() const noexcept { return seconds_; }
  [[nodiscard]] media::MediaTime exact() const noexcept { return exact_; }

 private:
  constexpr NativeMediaSessionInitialPosition(
      double seconds, media::MediaTime exact) noexcept
      : seconds_(seconds), exact_(exact) {}

  double seconds_{0.0};
  media::MediaTime exact_{};

  friend class NativeMediaSession;
};

// The exact rational form of one CommitSeek target. As with preparation, the
// controller performs this allocation-free preflight before publishing the
// command and the worker never reconstructs the source target from seconds.
class NativeMediaSessionCommitTarget final {
 public:
  [[nodiscard]] double seconds() const noexcept { return seconds_; }
  [[nodiscard]] media::MediaTime exact() const noexcept { return exact_; }
  [[nodiscard]] std::uint64_t drawBaseline() const noexcept {
    return drawBaseline_;
  }

 private:
  constexpr NativeMediaSessionCommitTarget(double seconds,
                                            media::MediaTime exact,
                                            std::uint64_t drawBaseline,
                                            media::MediaGeneration
                                                sourceGeneration) noexcept
      : seconds_(seconds), exact_(exact), drawBaseline_(drawBaseline),
        sourceGeneration_(sourceGeneration) {}

  double seconds_{0.0};
  media::MediaTime exact_{};
  std::uint64_t drawBaseline_{0};
  media::MediaGeneration sourceGeneration_{0};

  friend class NativeMediaSession;
};

enum class NativeMediaSessionCommandStatus : std::uint8_t {
  Accepted,
  Ignored,
  Invalid,
  Closed,
  // The command is well formed and the session is live, but this SOURCE can
  // never satisfy it. Distinct from Ignored ("not in this state, ask again")
  // and from Invalid ("the caller got the command wrong"): a caller that
  // receives Unsupported should stop asking for the whole binding. Appended
  // last; nothing switches exhaustively on this enum.
  Unsupported,
};

// Durable acknowledgement for the latest requested SetRunState command that
// was actually issued to NativeAudioSession and completed. If a newer intent
// arrives while an older issue is incomplete, the older issue is superseded
// before completion is observed and never publishes an acknowledgement.
struct NativeMediaSessionRunStateApplied {
  native_playback::SetRunState command{};
};

using NativeMediaSessionFact =
    std::variant<native_playback::Prepared,
                 native_playback::Started,
                 native_playback::Ended,
                 native_playback::Failed,
                 native_playback::Stopped>;

// One atomic controller drain. lifecycle is capacity one and blocks further
// worker lifecycle progress until consumed. Clock and draw proofs are
// independent capacity-one latest-value slots; replacing an older value is
// intentional coalescing, never an inferred proof.
struct NativeMediaSessionObservations {
  std::optional<NativeMediaSessionFact> lifecycle;
  std::optional<NativeMediaSessionRunStateApplied> runStateApplied;
  std::optional<native_playback::AudioClockProof> audioClock;
  std::optional<native_playback::VideoDrawProof> videoDraw;
  std::optional<native_playback::PreviewPresented> previewPresented;
  std::optional<native_playback::PreviewFailed> previewFailed;
  std::optional<native_playback::CommitReady> commitReady;

  [[nodiscard]] bool empty() const noexcept {
    return !lifecycle.has_value() && !runStateApplied.has_value() &&
           !audioClock.has_value() && !videoDraw.has_value() &&
           !previewPresented.has_value() && !previewFailed.has_value() &&
           !commitReady.has_value();
  }
};

enum class NativeMediaSessionOwnershipPhase : std::uint8_t {
  Empty,
  PrearmOwned,
  DispatcherUnobserved,
  DispatcherObserved,
  DirectRetiring,
  DispatcherRetiring,
  Closed,
};

struct NativeMediaSessionFacts {
  NativeMediaSessionOwnershipPhase ownership{
      NativeMediaSessionOwnershipPhase::Empty};
  media::MediaGeneration generation{0};
  media::MediaGeneration generationHighWater{0};
  media::MediaGeneration invalidationGeneration{0};
  bool workerRunning{false};
  bool prepareAccepted{false};
  bool prepared{false};
  bool started{false};
  bool dispatcherObservedVideo{false};
  bool directVideoRetired{false};
  bool directAudioRetired{false};
  bool factPending{false};
  bool stopLatched{false};
  bool stoppedProofPublished{false};
  bool ending{false};
  bool endedProofPublished{false};
  bool liveFailed{false};
  bool previewHandoffPending{false};
  bool previewHandoffReady{false};
  bool previewPending{false};
  bool previewPresentedPending{false};
  bool previewFailedPending{false};
  bool commitPending{false};
  bool commitReadyPending{false};
  native_playback::Stamp requestedRunStateStamp{};
  native_playback::Stamp issuedRunStateStamp{};
  native_playback::Stamp appliedRunStateStamp{};
  bool appliedPaused{true};
  bool observationPending{false};
};

// Diagnostic-only cumulative playback counters for an out-of-band metrics
// stream. Every counter is cumulative since this session was constructed, not
// since process start: a new open builds a new session and restarts them at
// zero. A sampler must therefore treat a decrease as an epoch change rather
// than as a delta.
//
// The counters themselves live on worker-confined children, so metrics() never
// reads them directly. The worker publishes one coherent-enough set of relaxed
// atomic slots once per pass, and only after a first metrics() call arms it;
// while the metrics stream is disabled the worker performs no sampling at all.
// The three "valid" flags separate "genuinely unavailable" (no graph built, or
// nothing published yet) from a real zero, so a sampler can emit null instead
// of inventing a count.
struct NativeMediaSessionMetrics {
  // Identifies the counter epoch: a value assigned once when this session was
  // constructed, constant for its whole life, and issued to no other session
  // in this process or in any earlier one. A change here is exactly the signal
  // that every counter below restarted at zero. It is never 0, so a sampler
  // holding no session can reserve 0 for "no session open".
  std::uint64_t sessionEpoch{0};
  std::uint64_t drawnFrames{0};
  std::uint64_t submittedFrames{0};
  std::uint64_t supersededFrames{0};
  std::uint64_t discardedLateFrames{0};
  std::uint64_t audioUnderrunCallbacks{0};
  std::uint64_t audioClockAdvancedUnderruns{0};
  std::uint64_t audioRetiredLateFrames{0};
  std::uint64_t audioCallbacks{0};
  std::uint64_t audioRenderedFrames{0};
  // The clock's own requested rate, not an achieved rate. A sampler that wants
  // the achieved rate must divide a mediaSeconds delta by a wall-clock delta.
  double mediaSeconds{0.0};
  double clockRate{0.0};
  bool videoValid{false};
  bool audioValid{false};
  bool clockValid{false};
  bool paused{true};
};

// A one-shot native media epoch. Exactly one worker owns exactly one
// AVFoundationMediaSource, NativeAudioSession, NativeVideoConsumer, and
// NativeMediaDispatcher. Public methods only publish fixed commands; source
// I/O, demux, decoder/output lifecycle, and fact production stay serialized
// on that worker. Stop has absolute precedence over all live commands.
class NativeMediaSession final {
 public:
  [[nodiscard]] static std::unique_ptr<NativeMediaSession> create(
      NativeMediaSessionSourceBinding binding,
      NativeMediaSessionDependencies dependencies) noexcept;
  ~NativeMediaSession();

  NativeMediaSession(const NativeMediaSession&) = delete;
  NativeMediaSession& operator=(const NativeMediaSession&) = delete;
  NativeMediaSession(NativeMediaSession&&) = delete;
  NativeMediaSession& operator=(NativeMediaSession&&) = delete;

  // Pure, resource-free admission used by the controller before choosing the
  // native route. The exact returned rational is the value prepare() passes to
  // the source; no second conversion or rounded timescale is permitted.
  [[nodiscard]] static std::optional<NativeMediaSessionInitialPosition>
  preflightInitialPosition(double seconds) noexcept;
  // Reserves a session-owned physical draw baseline before the Router creates
  // CommitSeek. The returned token is bound to the then-active generation;
  // commitSeek() rejects it after any intervening generation change.
  [[nodiscard]] std::optional<NativeMediaSessionCommitTarget>
  preflightCommitTarget(double seconds) noexcept;
  [[nodiscard]] std::optional<NativePreviewFrameTarget>
  preflightPreviewTarget(double seconds) noexcept;

  // Must be bound exactly once before Prepare. The edge is retained and
  // capacity-one; no controller polling is needed to discover observations.
  [[nodiscard]] bool bindObservationEdge(
      NativeMediaSessionObservationEdge edge) noexcept;

  [[nodiscard]] NativeMediaSessionCommandStatus
  prepare(native_playback::Prepare command,
          NativeMediaSessionInitialPosition initialPosition) noexcept;
  [[nodiscard]] NativeMediaSessionCommandStatus
  start(native_playback::Start command) noexcept;
  [[nodiscard]] NativeMediaSessionCommandStatus
  setRunState(native_playback::SetRunState command) noexcept;
  // Begins the surface-budget handoff and constructs the video-only preview
  // lane before the first pointer-motion command arrives. A fully published
  // Ended graph is also eligible: its main decoder is already drained, so the
  // handoff skips a redundant consumer quiesce while retaining the exact
  // generation for replay. This command has no protocol identity of its own,
  // does not change playback generation, and never publishes an observation.
  [[nodiscard]] NativeMediaSessionCommandStatus
  preparePreviewHandoff() noexcept;
  [[nodiscard]] NativeMediaSessionCommandStatus
  commitSeek(native_playback::CommitSeek command,
             NativeMediaSessionCommitTarget target) noexcept;
  [[nodiscard]] NativePreviewFrameRequestStatus previewFrame(
      native_playback::PreviewFrame command,
      NativePreviewFrameTarget target) noexcept;
  [[nodiscard]] NativeMediaSessionCommandStatus setGain(float gain) noexcept;
  [[nodiscard]] NativeMediaSessionCommandStatus setMuted(bool muted) noexcept;
  [[nodiscard]] NativeMediaSessionCommandStatus
  stop(native_playback::Stop command) noexcept;

  [[nodiscard]] NativeMediaSessionObservations takeObservations() noexcept;
  [[nodiscard]] NativeMediaSessionFacts facts() const noexcept;
  // Diagnostic sampler for an out-of-band metrics stream. Safe to call from
  // any thread. The first call arms worker-side publication; until the worker
  // has completed one pass afterwards the returned validity flags are false.
  [[nodiscard]] NativeMediaSessionMetrics metrics() const noexcept;

 private:
  struct Impl;
  explicit NativeMediaSession(std::unique_ptr<Impl> impl) noexcept;
  std::unique_ptr<Impl> impl_;
  friend struct NativeMediaSessionTestAccess;
};

#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
// Deterministic fixture seam. Production create() always constructs the four
// concrete owners above lazily on the worker after pure path/time preflight.
// Tests may replace the graph while exercising the identical worker,
// cancellation latch, ownership phases, retirement barrier, and fact mailbox.
struct NativeMediaSessionTestVideoControl {
  void* context{nullptr};
  NativeVideoConsumerArmProgress (*arm)(
      void* context, media::MediaGeneration generation) noexcept{nullptr};
  media::MediaGeneration (*highestExposed)(void* context) noexcept{nullptr};
  std::uint64_t (*lastOutputEventSequence)(void* context) noexcept{nullptr};
  std::uint64_t (*nextDueHostTicks)(void* context) noexcept{nullptr};
  std::optional<NativeTrackedVideoEvent> (*takeOutputEvent)(
      void* context) noexcept{nullptr};
  NativeVideoConsumerPreviewProgress (*quiesceForPreview)(
      void* context, media::MediaGeneration generation) noexcept{nullptr};
};

struct NativeMediaSessionTestAudioControl {
  void* context{nullptr};
  NativeAudioSessionProgress (*start)(void* context) noexcept{nullptr};
  NativeAudioSessionProgress (*setPaused)(void* context,
                                          bool paused) noexcept{nullptr};
  NativeAudioSessionProgress (*setGain)(void* context,
                                        float gain) noexcept{nullptr};
  NativeAudioSessionProgress (*setMuted)(void* context,
                                         bool muted) noexcept{nullptr};
  NativeAudioSessionProgress (*stop)(void* context) noexcept{nullptr};
  NativeMediaClockSnapshot (*clock)(void* context) noexcept{nullptr};
  media::MediaGeneration (*highestExposed)(void* context) noexcept{nullptr};
};

struct NativeMediaSessionTestPreviewControl {
  void* context{nullptr};
  NativePreviewFrameRequestStatus (*request)(
      void* context, native_playback::PreviewFrame command,
      NativePreviewFrameTarget target) noexcept{nullptr};
  NativePreviewFramePumpProgress (*pump)(void* context) noexcept{nullptr};
  std::optional<native_playback::PreviewPresented> (*takePresented)(
      void* context) noexcept{nullptr};
  NativePreviewFrameCancelProgress (*stop)(
      void* context,
      native_playback::Generation activeGeneration) noexcept{nullptr};
};

struct NativeMediaSessionTestGraph {
  std::unique_ptr<media::MediaSource> source;
  std::unique_ptr<media::NativeVideoConsumer> video;
  std::unique_ptr<media::NativeAudioConsumer> audio;
  NativeMediaSessionTestVideoControl videoControl;
  NativeMediaSessionTestAudioControl audioControl;
  NativeMediaSessionTestPreviewControl previewControl;
  // Optional production-wiring seam. When supplied, the session validates
  // this exact main-source context after Ready and exposes the immutable
  // preview binding to the observer before using the injected lane control.
  std::shared_ptr<const AVFoundationAssetContext> assetContext;
  bool (*observePreviewBinding)(
      void* context,
      const NativePreviewBinding& binding) noexcept{nullptr};
  void* previewBindingObserverContext{nullptr};
};

enum class NativeMediaSessionTestPreviewCompletionPoint : std::uint8_t {
  None,
  Quiesce,
  Construction,
  Request,
  Pump,
  TakePresented,
};

struct NativeMediaSessionTestWorkerPoolFacts {
  std::uint64_t entered{0};
  std::uint64_t drained{0};
  std::uint64_t active{0};
  std::uint64_t peakActive{0};
};

using NativeMediaSessionTestGraphFactory =
    NativeMediaSessionTestGraph (*)(void* context);

struct NativeMediaSessionTestAccess {
  static void installGraphFactory(
      NativeMediaSession& session,
      NativeMediaSessionTestGraphFactory factory,
      void* context) noexcept;
  static void installFailureLatchBarrier(
      NativeMediaSession& session,
      std::atomic<bool>* entered,
      std::atomic<bool>* release) noexcept;
  static void installFailureDetectionBarrier(
      NativeMediaSession& session,
      std::atomic<bool>* entered,
      std::atomic<bool>* release) noexcept;
  static void installLiveIssueBarrier(
      NativeMediaSession& session,
      std::atomic<bool>* entered,
      std::atomic<bool>* release) noexcept;
  static void installCommandDrainBarrier(
      NativeMediaSession& session,
      std::atomic<bool>* entered,
      std::atomic<bool>* release) noexcept;
  static void installPreviewPullBarrier(
      NativeMediaSession& session,
      std::atomic<bool>* entered,
      std::atomic<bool>* release) noexcept;
  static void installPreviewConstructionBarrier(
      NativeMediaSession& session,
      std::atomic<bool>* entered,
      std::atomic<bool>* release) noexcept;
  static void installPreviewCompletionBarrier(
      NativeMediaSession& session,
      NativeMediaSessionTestPreviewCompletionPoint point,
      std::atomic<bool>* entered,
      std::atomic<bool>* release) noexcept;
  static void installWakeConsumeBarrier(
      NativeMediaSessionWake& wake,
      std::atomic<bool>* entered,
      std::atomic<bool>* release) noexcept;
  [[nodiscard]] static std::uint64_t videoDueHostTicks(
      const NativeMediaSessionWake& wake) noexcept;
  [[nodiscard]] static NativeMediaSessionTestWorkerPoolFacts workerPoolFacts(
      const NativeMediaSession& session) noexcept;
};
#endif

}  // namespace wam::macos
