#include "native_media_session.hpp"

#include "avfoundation_media_source.hpp"
#include "matroska_media_source.hpp"
#include "native_silent_timebase.hpp"
#include "native_video_limits.hpp"

#include "media/native_media_dispatcher.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dispatch/dispatch.h>
#include <string>
#include <limits>
#include <mutex>
#include <new>
#include <thread>
#include <utility>

namespace wam::macos {
namespace {

using media::MediaGeneration;
namespace protocol = media::native_playback;

[[nodiscard]] const char* failureReasonName(
    protocol::FailureReason reason) noexcept {
  switch (reason) {
  case protocol::FailureReason::Preparation:
    return "Preparation";
  case protocol::FailureReason::Startup:
    return "Startup";
  case protocol::FailureReason::Clock:
    return "Clock";
  case protocol::FailureReason::Decode:
    return "Decode";
  case protocol::FailureReason::AudioOutput:
    return "AudioOutput";
  case protocol::FailureReason::VideoOutput:
    return "VideoOutput";
  case protocol::FailureReason::Preview:
    return "Preview";
  case protocol::FailureReason::CommitSeek:
    return "CommitSeek";
  case protocol::FailureReason::Stop:
    return "Stop";
  case protocol::FailureReason::Protocol:
    return "Protocol";
  }
  return "Unknown";
}

// One always-on stderr line per terminal native failure.
//
// The user-visible text is chosen from protocol::FailureReason, which is a
// deliberately small vocabulary: every terminal dispatcher failure collapses
// onto Protocol (open-status Failed) or Decode (a Failed step), so a field
// report says only "Native playback rejected an internal command" and names
// neither the seam that refused nor why. This line restores the three facts
// that a single reproduction then makes fully diagnostic: which stage of the
// session ran (open/start/steady), which NativeMediaDispatcherFailure class
// actually fired, and the refusing seam's own error text.
//
// It is one line per terminal failure -- a session publishes at most a
// handful in its whole lifetime -- so it is not env-gated. stderr is used
// directly rather than Qt logging because this layer owns no Qt dependency,
// and a plain stderr capture of the process is exactly where it must appear.
void logNativeFailure(const char* stage, protocol::FailureReason reason,
                      const media::NativeMediaDispatcher* dispatcher) noexcept {
  try {
    const char* failureClass = "NoDispatcher";
    std::string message;
    bool dispatcherFailed = false;
    if (dispatcher != nullptr) {
      const media::NativeMediaDispatcherFailure failure =
          dispatcher->stats().failure;
      dispatcherFailed = failure != media::NativeMediaDispatcherFailure::None;
      failureClass = media::nativeMediaDispatcherFailureName(failure);
      message = dispatcher->failureMessage();
    }
    // An empty error field is the one thing this line must never print: it
    // costs a reproduction to learn what a single word would have said. The
    // dispatcher now names the refusing step itself, so the remaining empty
    // cases are the ones where the dispatcher is not the failing party at
    // all -- it was never created, or it never failed and the session did.
    // Say which, rather than say nothing.
    if (message.empty()) {
      if (dispatcher == nullptr) {
        message = "no dispatcher was created for this session";
      } else if (!dispatcherFailed) {
        message =
            "the session failed while the dispatcher reported no failure";
      } else {
        message = "the failing seam published no reason";
      }
    }
    // Keep the record one grep-able line: control characters and quotes in a
    // backend's text must not be able to forge a second line or unbalance the
    // quoted field.
    for (char& character : message) {
      if (character == '"') {
        character = '\'';
      } else if (static_cast<unsigned char>(character) < 0x20U) {
        character = ' ';
      }
    }
    std::fprintf(stderr,
                 "WAM: native failure stage=%s reason=%s class=%s error=\"%s\"\n",
                 stage, failureReasonName(reason), failureClass,
                 message.c_str());
    std::fflush(stderr);
  } catch (...) {
    // A diagnostic must never be able to fail a playback path.
  }
}

[[nodiscard]] bool validLocalBinding(
    const NativeMediaSessionSourceBinding& binding) noexcept {
  try {
    return protocol::valid(binding.sourceKey) &&
           binding.localPath.is_absolute() && !binding.localPath.empty();
  } catch (...) {
    return false;
  }
}

// Extension-only container routing for backend selection. This states which
// demuxer is even capable of the container, never whether the media is
// admissible: the selected source owns that decision and reports Unsupported
// through the one existing fallback route. `.mka` is deliberately included so
// an audio-only Matroska reaches the Matroska source and is rejected there for
// having no video track, rather than being handed to a backend that cannot
// parse the container at all.
[[nodiscard]] bool matroskaLocalContainer(
    const std::filesystem::path& path) noexcept {
  try {
    std::string extension = path.extension().string();
    if (extension.empty() || extension.front() != '.') {
      return false;
    }
    for (char& character : extension) {
      if (character >= 'A' && character <= 'Z') {
        character = static_cast<char>(character - 'A' + 'a');
      }
    }
    return extension == ".mkv" || extension == ".mk3d" ||
           extension == ".mka" || extension == ".webm";
  } catch (...) {
    return false;
  }
}


[[nodiscard]] std::optional<media::MediaTime>
exactFrameTime(CMTime time) noexcept {
  if (!CMTIME_IS_NUMERIC(time) || time.timescale <= 0 || time.epoch != 0 ||
      (time.flags & kCMTimeFlags_HasBeenRounded) != 0) {
    return std::nullopt;
  }
  return media::MediaTime{time.value, time.timescale};
}

[[nodiscard]] const media::MediaTrackDescriptor* selectedTrack(
    const media::MediaSourceDescriptor& descriptor,
    std::optional<media::MediaTrackId> selected) noexcept {
  return selected ? media::findMediaTrack(descriptor, *selected) : nullptr;
}

[[nodiscard]] bool nativeV1Descriptor(
    const media::MediaSourceDescriptor& descriptor) noexcept {
  const media::MediaTrackDescriptor* video =
      selectedTrack(descriptor, descriptor.selectedVideo);
  if (video == nullptr || !video->duration.valid() ||
      video->duration.value < 0) {
    return false;
  }
  const media::MediaTrackDescriptor* audio =
      selectedTrack(descriptor, descriptor.selectedAudio);
  if (audio == nullptr) {
    // Audio-less (silent) source. There is no audio timeline to cover the
    // video one because the clock is not audio-authoritative for this
    // generation: NativeSilentTimebase publishes media time from the host
    // clock instead. A descriptor that names a selected audio track it cannot
    // resolve is still a hard protocol fault.
    return !descriptor.selectedAudio.has_value();
  }
  if (!audio->duration.valid() || audio->duration.value < 0) {
    return false;
  }
  // One shared rule with NativeVideoConsumer::selectedTrackDurationsSupported:
  // an audio-authoritative clock must cover the video timeline apart from a
  // bounded container-artefact shortfall. See native_video_limits.hpp.
  return native_video_limits::acceptsSelectedTrackDurations(audio->duration,
                                                            video->duration);
}

[[nodiscard]] double descriptorDurationSeconds(
    const media::MediaSourceDescriptor& descriptor) noexcept {
  return media::mediaTimeSeconds(descriptor.duration).value_or(0.0);
}

// Intercepts AVFoundation's immutable Ready descriptor before Dispatcher can
// configure either port. Native v1's exact selected A/V and duration relation
// are therefore a pure admission decision: a rejected source never reaches a
// consumer configure() call.
struct NativeMediaSessionCancellation final {
  std::atomic<MediaGeneration> generation{0};
};

class NativeV1AdmissionSource final : public media::MediaSource {
 public:
  explicit NativeV1AdmissionSource(
      std::unique_ptr<media::MediaSource> source,
      std::shared_ptr<NativeMediaSessionCancellation> cancellation) noexcept
      : source_(std::move(source)),
        cancellation_(std::move(cancellation)) {}

  bool armOperation(MediaGeneration generation) noexcept override {
    if (source_ == nullptr || generation == 0) {
      return false;
    }
    if (cancellation_->generation.load(std::memory_order_acquire) ==
        generation) {
      return false;
    }
    if (!source_->armOperation(generation)) {
      return false;
    }
    armedGeneration_.store(generation, std::memory_order_release);
    if (cancellation_->generation.load(std::memory_order_acquire) ==
        generation) {
      source_->requestCancel(generation);
    }
    return true;
  }

  media::MediaSourceOpenOutcome openLocalFile(
      const std::filesystem::path& path,
      const media::MediaSourceOpenOptions& options,
      MediaGeneration generation) override {
    media::MediaSourceOpenOutcome result =
        source_->openLocalFile(path, options, generation);
    if (result.status == media::MediaSourceOpenStatus::Ready &&
        (result.descriptor == nullptr ||
         !nativeV1Descriptor(*result.descriptor))) {
      source_->close();
      result.status = media::MediaSourceOpenStatus::Unsupported;
      result.descriptor.reset();
      result.error = "native v1 requires a selected video track and, when the "
                     "source carries audio, an audio duration that covers the "
                     "video duration apart from a bounded container-artefact "
                     "shortfall";
    }
    return result;
  }

  media::MediaSourceSeekOutcome seek(
      const media::MediaSourceSeekRequest& request) override {
    return source_->seek(request);
  }

  media::MediaSourceReadResult readNext(
      MediaGeneration generation) override {
    return source_->readNext(generation);
  }

  void requestCancel(MediaGeneration generation) noexcept override {
    cancellation_->generation.store(generation, std::memory_order_release);
    source_->requestCancel(generation);
  }

  void close() noexcept override {
    if (source_ != nullptr) {
      source_->close();
    }
  }

  media::MediaSourceStats stats() const noexcept override {
    return source_ == nullptr ? media::MediaSourceStats{} : source_->stats();
  }

 private:
  std::unique_ptr<media::MediaSource> source_;
  std::shared_ptr<NativeMediaSessionCancellation> cancellation_;
  std::atomic<MediaGeneration> armedGeneration_{0};
};

struct NativeMediaSessionChildLifetime final {
  struct ClockControl {
    NativeMediaClockSnapshot snapshot{};
  };
  std::shared_ptr<void> caller;
  std::shared_ptr<NativeMediaSessionWake> wake;
  std::shared_ptr<ClockControl> clock;
};

struct SessionVideoControl {
  void* context{nullptr};
  NativeVideoConsumerArmProgress (*arm)(
      void*, MediaGeneration) noexcept{nullptr};
  MediaGeneration (*highestExposed)(void*) noexcept{nullptr};
  std::uint64_t (*lastOutputEventSequence)(void*) noexcept{nullptr};
  std::uint64_t (*nextDueHostTicks)(void*) noexcept{nullptr};
  std::optional<NativeTrackedVideoEvent> (*takeOutputEvent)(
      void*) noexcept{nullptr};
  NativeVideoConsumerPreviewProgress (*quiesceForPreview)(
      void*, MediaGeneration) noexcept{nullptr};
  // Diagnostic-only, optional. Left null by the test graph seam, which has no
  // NativeVideoConsumer to sample; publishMetrics() then reports the video
  // counters as unavailable rather than as zero.
  bool (*metrics)(void*, NativeMediaSessionMetrics*) noexcept{nullptr};
};

struct SessionAudioControl {
  void* context{nullptr};
  NativeAudioSessionProgress (*start)(void*) noexcept{nullptr};
  NativeAudioSessionProgress (*setPaused)(void*, bool) noexcept{nullptr};
  NativeAudioSessionProgress (*setGain)(void*, float) noexcept{nullptr};
  NativeAudioSessionProgress (*setMuted)(void*, bool) noexcept{nullptr};
  NativeAudioSessionProgress (*stop)(void*) noexcept{nullptr};
  NativeMediaClockSnapshot (*clock)(void*) noexcept{nullptr};
  MediaGeneration (*highestExposed)(void*) noexcept{nullptr};
  // Diagnostic-only, optional; see SessionVideoControl::metrics.
  bool (*metrics)(void*, NativeMediaSessionMetrics*) noexcept{nullptr};
  // Optional wake-rate lever: stops the output device for a settled pause.
  // Deliberately last so a route that owns no AudioUnit -- the silent
  // timebase -- keeps its existing aggregate initializer and leaves this
  // null, which progressAudioSuspend() reads as "nothing to idle".
  NativeAudioSessionProgress (*suspendForPause)(void*) noexcept{nullptr};
  // Optional playback rate, applied as an exact rational together with the
  // live preserve-pitch preference (true = time-stretched, false =
  // varispeed). A route that leaves this null is served only at the unit
  // rate, where the preference has nothing to apply.
  NativeAudioSessionProgress (*setRate)(void*, NativePlaybackRate,
                                        bool) noexcept{nullptr};
};

// Paired-measurement seam for the pause-suspend lever. Read once per process.
// Setting WAM_AUDIO_PAUSE_SUSPEND=0 keeps the output AudioUnit running through
// a pause exactly as it did before this change, so a baseline arm and a
// treatment arm can be taken from ONE binary. Rebuilding between arms would
// confound the treatment with every other difference two builds can carry, on
// a machine whose ambient load and default audio device both drift. Any other
// value (including unset) enables the lever, so the shipped default is the
// treatment.
[[nodiscard]] bool pauseSuspendEnabled() noexcept {
  static const bool enabled = [] {
    const char* value = std::getenv("WAM_AUDIO_PAUSE_SUSPEND");
    return value == nullptr || std::strcmp(value, "0") != 0;
  }();
  return enabled;
}

// Rebinds the session's transport/clock authority onto a host-clock timebase
// for an audio-less generation. metrics is deliberately left null: a silent
// generation has no render callback, so the audio counters are genuinely
// unavailable rather than zero, and publishMetrics() already reports that.
[[nodiscard]] SessionAudioControl silentTimebaseControl(
    NativeSilentTimebase* timebase) noexcept {
  return SessionAudioControl{
      timebase,
      [](void* context) noexcept {
        return static_cast<NativeSilentTimebase*>(context)->start();
      },
      [](void* context, bool paused) noexcept {
        return static_cast<NativeSilentTimebase*>(context)->setPaused(paused);
      },
      [](void* context, float gain) noexcept {
        return static_cast<NativeSilentTimebase*>(context)->setGain(gain);
      },
      [](void* context, bool muted) noexcept {
        return static_cast<NativeSilentTimebase*>(context)->setMuted(muted);
      },
      [](void* context) noexcept {
        return static_cast<NativeSilentTimebase*>(context)->stop();
      },
      [](void* context) noexcept {
        return static_cast<NativeSilentTimebase*>(context)->visibleClock();
      },
      [](void* context) noexcept {
        return static_cast<NativeSilentTimebase*>(context)
            ->highestExposedGeneration();
      },
      nullptr,
      // No AudioUnit to idle on this route ...
      nullptr,
      // ... but rate is real here: it scales the host-clock slope directly.
      // Pitch is not: a silent generation has no audio to shift, so the
      // preference is accepted and ignored rather than refused.
      [](void* context, NativePlaybackRate rate, bool) noexcept {
        return static_cast<NativeSilentTimebase*>(context)->setRate(rate);
      }};
}

struct SessionPreviewControl {
  void* context{nullptr};
  NativePreviewFrameRequestStatus (*request)(
      void*, protocol::PreviewFrame, NativePreviewFrameTarget) noexcept{
      nullptr};
  NativePreviewFramePumpProgress (*pump)(void*) noexcept{nullptr};
  std::optional<protocol::PreviewPresented> (*takePresented)(
      void*) noexcept{nullptr};
  NativePreviewFrameCancelProgress (*stop)(
      void*, protocol::Generation) noexcept{nullptr};
};

}  // namespace

struct NativeMediaSessionWake::Impl final {
  // AudioOutput owns outputPending's false->true transition before invoking
  // signal(). workerPending is a distinct capacity-one edge; sharing the same
  // atomic would suppress every audio callback wake.
  std::atomic<bool> outputPending{false};
  std::atomic<bool> workerPending{false};
  std::atomic<std::uint64_t> videoDueHostTicks{0};
  dispatch_semaphore_t semaphore{dispatch_semaphore_create(0)};
  // Audio-less heartbeat. Both fields are written and read exclusively on the
  // session worker thread (armed from progressPrepare, consumed by wait()),
  // so they need no synchronization of their own.
  bool hostPaced{false};
  NativeMediaHostClock hostPacedClock{};
#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
  std::atomic<std::uint64_t> consumedTokens{0};
  std::atomic<std::uint64_t> consumeBarrierTarget{0};
  std::atomic<std::atomic<bool>*> consumeBarrierEntered{nullptr};
  std::atomic<std::atomic<bool>*> consumeBarrierRelease{nullptr};
  std::atomic<bool> consumeBarrierConsumed{false};
#endif
};

NativeMediaSessionWake::NativeMediaSessionWake(
    std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

NativeMediaSessionWake::~NativeMediaSessionWake() = default;

std::shared_ptr<NativeMediaSessionWake>
NativeMediaSessionWake::create() noexcept {
  try {
    return std::shared_ptr<NativeMediaSessionWake>(
        new NativeMediaSessionWake(std::make_unique<Impl>()));
  } catch (...) {
    return {};
  }
}

void NativeMediaSessionWake::signal(void* context) noexcept {
  if (context != nullptr) {
    static_cast<NativeMediaSessionWake*>(context)->notify();
  }
}

void NativeMediaSessionWake::notify() noexcept {
  if (impl_ == nullptr) {
    return;
  }
  if (!impl_->workerPending.exchange(true, std::memory_order_acq_rel)) {
    dispatch_semaphore_signal(impl_->semaphore);
  }
}

namespace {

// Bounded floor for the audio-less heartbeat. It matches the ordinary
// CoreAudio device period this route replaces, so an armed silent generation
// pays no more worker wakes than the AudioUnit callback used to deliver, and a
// video due tick that lands sooner still wins.
constexpr std::uint64_t kHostPacedFloorNanos = 10ULL * 1000ULL * 1000ULL;

[[nodiscard]] dispatch_time_t hostPacedDeadline(
    bool hostPaced, NativeMediaHostClock hostClock,
    std::atomic<std::uint64_t>* dueSlot) noexcept {
  if (!hostPaced || hostClock.readTicks == nullptr ||
      hostClock.ticksPerSecond == 0 || dueSlot == nullptr) {
    return DISPATCH_TIME_FOREVER;
  }
  std::uint64_t nanos = kHostPacedFloorNanos;
  std::uint64_t due = dueSlot->load(std::memory_order_acquire);
  if (due != 0) {
    const std::uint64_t now = hostClock.readTicks(hostClock.context);
    if (due <= now) {
      // Consume the deadline exactly once, mirroring the audio wake seam's
      // compare-exchange. Without this a due tick that has already passed
      // makes every later wait expire instantly and the worker spins.
      static_cast<void>(dueSlot->compare_exchange_strong(
          due, 0, std::memory_order_acq_rel, std::memory_order_relaxed));
      nanos = 0;
    } else {
      // A far-future due tick would overflow a 64-bit nanosecond product, so
      // the exact conversion is done in 128 bits and then clamped to the
      // floor.
      const auto exact = static_cast<__uint128_t>(due - now) *
                         static_cast<__uint128_t>(1000000000ULL) /
                         static_cast<__uint128_t>(hostClock.ticksPerSecond);
      nanos = exact >= static_cast<__uint128_t>(kHostPacedFloorNanos)
                  ? kHostPacedFloorNanos
                  : static_cast<std::uint64_t>(exact);
    }
  }
  return dispatch_time(DISPATCH_TIME_NOW, static_cast<std::int64_t>(nanos));
}

}  // namespace

void NativeMediaSessionWake::setHostPacedDeadlines(
    NativeMediaHostClock hostClock) noexcept {
  if (impl_ == nullptr) {
    return;
  }
  impl_->hostPacedClock = hostClock;
  impl_->hostPaced =
      hostClock.readTicks != nullptr && hostClock.ticksPerSecond != 0;
}

void NativeMediaSessionWake::wait() noexcept {
  if (impl_ == nullptr) {
    return;
  }
  // An expired deadline leaves the semaphore untouched, so a notification that
  // races the timeout is not lost: its token stays queued and is consumed by
  // the next wait, costing at most one redundant worker pass. Every worker
  // pass is idempotent, which is what makes the timed wait safe here.
  static_cast<void>(dispatch_semaphore_wait(
      impl_->semaphore,
      hostPacedDeadline(impl_->hostPaced, impl_->hostPacedClock,
                        &impl_->videoDueHostTicks)));
#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
  const std::uint64_t token =
      impl_->consumedTokens.fetch_add(1, std::memory_order_acq_rel) + 1;
  const std::uint64_t target =
      impl_->consumeBarrierTarget.load(std::memory_order_acquire);
  std::atomic<bool>* const entered =
      impl_->consumeBarrierEntered.load(std::memory_order_acquire);
  std::atomic<bool>* const release =
      impl_->consumeBarrierRelease.load(std::memory_order_acquire);
  if (target != 0 && token >= target && entered != nullptr &&
      release != nullptr &&
      !impl_->consumeBarrierConsumed.exchange(true,
                                               std::memory_order_acq_rel)) {
    entered->store(true, std::memory_order_release);
    while (!release->load(std::memory_order_acquire)) {
      std::this_thread::yield();
    }
  }
#endif
  // The consumed token covers all publications before these exchanges. A
  // notification before the outer exchange is acquire-absorbed into this
  // drain; one after it observes false and owns a token for the next drain.
  beginDrain();
}

void NativeMediaSessionWake::beginDrain() noexcept {
  if (impl_ != nullptr) {
    // Clear the outer gate first, then acquire-consume the AudioUnit gate. An
    // AudioUnit publication racing between them is absorbed into this owner
    // drain by the second exchange; one after both clears signals a follow-up.
    static_cast<void>(
        impl_->workerPending.exchange(false, std::memory_order_acq_rel));
    static_cast<void>(
        impl_->outputPending.exchange(false, std::memory_order_acq_rel));
  }
}

NativeAudioOutputWakeSeam NativeMediaSessionWake::audio() noexcept {
  return impl_ == nullptr
             ? NativeAudioOutputWakeSeam{}
             : NativeAudioOutputWakeSeam{&impl_->outputPending, &signal, this,
                                         &impl_->videoDueHostTicks};
}

void NativeMediaSessionWake::publishVideoDueHostTicks(
    std::uint64_t hostTicks) noexcept {
  if (impl_ != nullptr) {
    impl_->videoDueHostTicks.store(hostTicks, std::memory_order_release);
  }
}

NativeVideoConsumerWakeSeam NativeMediaSessionWake::video() noexcept {
  return impl_ == nullptr ? NativeVideoConsumerWakeSeam{}
                          : NativeVideoConsumerWakeSeam{&signal, this};
}

NativeTrackedVideoOutputWakeSeam
NativeMediaSessionWake::trackedVideo() noexcept {
  return impl_ == nullptr ? NativeTrackedVideoOutputWakeSeam{}
                          : NativeTrackedVideoOutputWakeSeam{&signal, this};
}

namespace {

// Seeds the process's session epoch sequence. An epoch has to separate counter
// resets across processes as well as within one, because the metrics file is
// opened in append mode and a harness may deliberately point several runs at a
// single file; a sequence restarting at 1 every launch would hand consecutive
// runs the same epochs and so prove nothing about the run boundary that resets
// the counters. Seeding from the wall clock starts each run above every epoch
// an earlier run on this machine could have issued, while leaving the within-
// run sequence a plain +1 step. The value is never 0, so a sampler holding no
// session keeps 0 for "no session open".
std::uint64_t sessionEpochSeed() noexcept {
  const auto since =
      std::chrono::system_clock::now().time_since_epoch();
  const auto nanoseconds =
      std::chrono::duration_cast<std::chrono::nanoseconds>(since).count();
  return nanoseconds > 0 ? static_cast<std::uint64_t>(nanoseconds) : 1;
}

// Read once per session construction and never again, so it costs nothing on
// any hot path, and the seed is not even sampled in a process that never opens
// a session.
std::uint64_t allocateSessionEpoch() noexcept {
  static std::atomic<std::uint64_t> next{sessionEpochSeed()};
  return next.fetch_add(1, std::memory_order_relaxed);
}

}  // namespace

struct NativeMediaSession::Impl final {
  explicit Impl(NativeMediaSessionSourceBinding sourceBinding,
                NativeMediaSessionDependencies sourceDependencies)
      : binding(std::move(sourceBinding)),
        dependencies(std::move(sourceDependencies)) {
    auto clock =
        std::make_shared<NativeMediaSessionChildLifetime::ClockControl>();
    childLifetime = std::make_shared<NativeMediaSessionChildLifetime>(
        NativeMediaSessionChildLifetime{dependencies.externalLifetime,
                                        dependencies.wake,
                                        std::move(clock)});
    cancellation = std::make_shared<NativeMediaSessionCancellation>();
  }

  ~Impl() { shutdown(); }

  static NativeMediaClockSnapshot sampleCachedClock(void* context) noexcept {
    return static_cast<NativeMediaSessionChildLifetime::ClockControl*>(context)
        ->snapshot;
  }

  void shutdown() noexcept {
    MediaGeneration cancel = 0;
    {
      std::lock_guard lock(mutex);
      exitRequested = true;
      if (publishedPrepare.has_value()) {
        cancel = std::max(publishedPrepare->command.reservedGeneration.value,
                          generationHighWater);
      }
      cancellation->generation.store(cancel, std::memory_order_release);
      if (dispatcherObserver != nullptr && cancel != 0) {
        dispatcherObserver->requestCancel(cancel);
      }
    }
    dependencies.wake->publishVideoDueHostTicks(0);
    dependencies.wake->notify();
    if (worker.joinable()) {
      worker.join();
    }
  }

  [[nodiscard]] bool observationsPresentLocked() const noexcept {
    return factMailbox.has_value() || runStateAppliedSlot.has_value() ||
           audioClockSlot.has_value() || videoDrawSlot.has_value() ||
           previewPresentedSlot.has_value() || previewFailedSlot.has_value() ||
           commitReadySlot.has_value();
  }

  void queueObservations() noexcept {
    NativeMediaSessionQueueObservations queue = nullptr;
    std::shared_ptr<void> lifetime;
    void* context = nullptr;
    std::uint64_t queueSerial = 0;
    {
      std::lock_guard lock(mutex);
      if (!observationsPresentLocked() || observationQueued ||
          observationEdge.queue == nullptr ||
          observationEdge.lifetime == nullptr) {
        return;
      }
      observationQueued = true;
      ++nextObservationQueueSerial;
      if (nextObservationQueueSerial == 0) {
        ++nextObservationQueueSerial;
      }
      queuedObservationQueueSerial = nextObservationQueueSerial;
      queueSerial = queuedObservationQueueSerial;
      queue = observationEdge.queue;
      lifetime = observationEdge.lifetime;
      context = observationEdge.context;
    }
    // The edge is deliberately invoked after releasing mutex. Its contract is
    // queue-only, and this remains safe even if a faulty seam re-enters the
    // public drain synchronously.
    if (queue(std::move(lifetime), context)) {
      return;
    }

    bool scheduleRetry = false;
    {
      std::lock_guard lock(mutex);
      if (observationQueued && queuedObservationQueueSerial == queueSerial) {
        observationQueued = false;
        queuedObservationQueueSerial = 0;
        if (!observationRetryWakeUsed) {
          observationRetryWakeUsed = true;
          scheduleRetry = true;
        }
      }
    }
    if (scheduleRetry) {
      dependencies.wake->notify();
    }
  }

  [[nodiscard]] bool publishLifecycle(
      NativeMediaSessionFact fact) noexcept {
    bool inserted = false;
    {
      std::lock_guard lock(mutex);
      // Stop owns the mailbox once latched. Only its exact terminal Failed or
      // Stopped fact may cross this boundary; late live failures cannot hide
      // the retirement proof.
      if (publishedStop.has_value() &&
          !std::holds_alternative<protocol::Stopped>(fact) &&
          !(std::holds_alternative<protocol::Failed>(fact) &&
            std::get<protocol::Failed>(fact).stamp ==
                publishedStop->stamp &&
            std::get<protocol::Failed>(fact).reason ==
                protocol::FailureReason::Stop)) {
        return false;
      }
      if (factMailbox.has_value()) {
        return false;
      }
      factMailbox.emplace(std::move(fact));
      inserted = true;
    }
    if (inserted) {
      queueObservations();
    }
    return inserted;
  }

  [[nodiscard]] bool publishFailure(
      protocol::FailureReason reason,
      std::optional<protocol::Stamp> exactStamp = std::nullopt) noexcept {
    bool inserted = false;
    {
      std::lock_guard lock(mutex);
#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
      // This barrier deliberately runs while holding the same lock used by
      // public command admission. It makes the failure stamp and the terminal
      // public latch one linearized transaction in the race test below.
      if (reason == protocol::FailureReason::Decode &&
          failureLatchEntered != nullptr && failureLatchRelease != nullptr) {
        failureLatchEntered->store(true, std::memory_order_release);
        while (!failureLatchRelease->load(std::memory_order_acquire)) {
          std::this_thread::yield();
        }
      }
#endif
      protocol::Stamp stamp = exactStamp.value_or(latestAcceptedStamp);
      if (publishedStop.has_value()) {
        if (reason != protocol::FailureReason::Stop) {
          return false;
        }
        stamp = publishedStop->stamp;
      } else if (reason == protocol::FailureReason::Stop || publicEnded) {
        return false;
      }
      if (reason != protocol::FailureReason::Stop && publicLiveFailed) {
        return false;
      }
      if (!protocol::valid(protocol::Failed{stamp, reason})) {
        return false;
      }
      if (reason != protocol::FailureReason::Stop) {
        liveFailed = true;
        publicLiveFailed = true;
        publishedStart.reset();
        publishedRun.reset();
        publishedGain.reset();
        publishedMuted.reset();
        startPending = false;
        runPending = false;
        gainPending = false;
        mutedPending = false;
        audioProofPending.reset();
        runStateAppliedSlot.reset();
        audioClockSlot.reset();
        videoDrawSlot.reset();
        previewPresentedSlot.reset();
        previewFailedSlot.reset();
        commitReadySlot.reset();
        publishedPreviewHandoff.reset();
        publishedPreview.reset();
        publicPreviewHandoffPending = false;
        publicPreviewHandoffReady = false;
        publicPreviewHandoffFailed = false;
        publicPreviewPending = false;
        publishedCommit.reset();
        publicCommitPending = false;
        // A live failure supersedes an open commit handshake; nothing will
        // answer it, and ending must not stay suppressed behind it.
        commitRunStatePending = false;
      }
      if (factMailbox.has_value()) {
        pendingFailure = protocol::Failed{stamp, reason};
      } else {
        factMailbox.emplace(protocol::Failed{stamp, reason});
        inserted = true;
      }
    }
    dependencies.wake->publishVideoDueHostTicks(0);
    if (inserted) {
      queueObservations();
    }
    return true;
  }

  void publishPendingFailure() noexcept {
    bool inserted = false;
    {
      std::lock_guard lock(mutex);
      if (!pendingFailure.has_value() || factMailbox.has_value() ||
          publishedStop.has_value()) {
        return;
      }
      factMailbox.emplace(*pendingFailure);
      pendingFailure.reset();
      inserted = true;
    }
    if (inserted) {
      queueObservations();
    }
  }

  void publishAudioClock(protocol::AudioClockProof proof) noexcept {
    {
      std::lock_guard lock(mutex);
      if (publishedStop.has_value() || endedPublished || publicEnding ||
          proof.stamp != publicRequestedRunStamp ||
          proof.stamp != publicAppliedRunStamp) {
        return;
      }
      audioClockSlot = proof;
    }
    queueObservations();
  }

  void publishVideoDraw(protocol::VideoDrawProof proof) noexcept {
    {
      std::lock_guard lock(mutex);
      if (publishedStop.has_value() || publicEnding || publicEnded ||
          proof.stamp != publicRequestedRunStamp ||
          proof.stamp != publicAppliedRunStamp) {
        return;
      }
      videoDrawSlot = proof;
    }
    queueObservations();
  }

  [[nodiscard]] bool publishCommitReady(
      const protocol::CommitSeek& command, std::uint64_t drawBaseline,
      const protocol::AudioClockProof& audioClock,
      const protocol::VideoDrawProof& videoDraw) noexcept {
    const protocol::CommitReady ready{
        command.stamp, command.targetGeneration, command.gesture,
        command.request, command.targetSeconds, audioClock, videoDraw};
    if (!protocol::commitReadyMatches(command, drawBaseline, ready)) {
      return false;
    }
    {
      std::lock_guard lock(mutex);
      if (publishedStop.has_value() || publicEnding || publicEnded ||
          publicLiveFailed || !publicCommitPending ||
          generationHighWater != command.targetGeneration.value ||
          commitReadySlot.has_value()) {
        return false;
      }
      publicActiveGeneration = command.targetGeneration.value;
      requestedRunStamp = command.stamp;
      issuedRunStamp = command.stamp;
      appliedRunStamp = command.stamp;
      publicRequestedRunStamp = command.stamp;
      publicIssuedRunStamp = command.stamp;
      publicAppliedRunStamp = command.stamp;
      appliedPaused = true;
      publicAppliedPaused = true;
      publicCommitPending = false;
      commitRunStatePending = true;
      publishedStart.reset();
      startPending = false;
      publicStartAccepted = true;
      commitReadySlot = ready;
    }
    queueObservations();
    return true;
  }

  [[nodiscard]] bool publishStopped() noexcept {
    {
      std::lock_guard lock(mutex);
      if (factMailbox.has_value()) {
        return false;
      }
      stoppedPublished = true;
      publicOwnership = ownership;
      publicPrepared = preparedPublished;
      publicStarted = startedPublished;
      publicDispatcherObservedVideo = dispatcherObservedVideo;
      publicDirectVideoRetired = directVideoRetired;
      publicDirectAudioRetired = directAudioRetired;
      publicStopped = true;
      publicEnding = endingLatched;
      publicEnded = endedPublished;
      publicLiveFailed = liveFailed;
      publicAppliedPaused = appliedPaused;
      factMailbox.emplace(protocol::Stopped{
          stopCommand.stamp, stopCommand.invalidationGeneration});
    }
    queueObservations();
    return true;
  }

  [[nodiscard]] bool factBlocked() const noexcept {
    std::lock_guard lock(mutex);
    return factMailbox.has_value() && !publishedStop.has_value();
  }

  [[nodiscard]] bool stopPublished() const noexcept {
    std::lock_guard lock(mutex);
    return publishedStop.has_value();
  }

  [[nodiscard]] bool commitPublished() const noexcept {
    std::lock_guard lock(mutex);
    return publicCommitPending;
  }

  // Linearization permit for every live child mutation. Public Stop and the
  // worker contend on the same mutex: Stop accepted first makes the issue
  // impossible; a permit acquired first proves the child issue preceded Stop
  // even if the child call itself later quiesces or blocks.
  [[nodiscard]] bool beginLiveIssue(
      const protocol::SetRunState* runIssue = nullptr,
      bool allowEnding = false, bool allowCommit = false) noexcept {
#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
    if (liveIssueBarrierEntered != nullptr &&
        liveIssueBarrierRelease != nullptr &&
        !liveIssueBarrierConsumed.exchange(true,
                                           std::memory_order_acq_rel)) {
      liveIssueBarrierEntered->store(true, std::memory_order_release);
      while (!liveIssueBarrierRelease->load(std::memory_order_acquire)) {
        std::this_thread::yield();
      }
    }
#endif
    std::lock_guard lock(mutex);
    if (liveIssueActive || exitRequested || publishedStop.has_value() ||
        liveFailed || (!allowEnding && (publicEnding || publicEnded)) ||
        (publicCommitPending && !allowCommit)) {
      return false;
    }
    liveIssueActive = true;
    if (runIssue != nullptr) {
      issuedRunStamp = runIssue->stamp;
      publicIssuedRunStamp = issuedRunStamp;
    }
    return true;
  }

  void endLiveIssue() noexcept {
    std::lock_guard lock(mutex);
    liveIssueActive = false;
  }

  void publishWorkerFacts() noexcept {
    std::lock_guard lock(mutex);
    publicOwnership = ownership;
    publicPrepared = preparedPublished;
    publicStarted = startedPublished;
    publicDispatcherObservedVideo = dispatcherObservedVideo;
    publicDirectVideoRetired = directVideoRetired;
    publicDirectAudioRetired = directAudioRetired;
    publicStopped = stoppedPublished;
    publicEnding = endingLatched;
    publicEnded = endedPublished;
    publicLiveFailed = liveFailed;
    publicAppliedPaused = appliedPaused;
  }

  void publishVideoDueHint() noexcept {
    std::uint64_t due = 0;
    if (!stopLatched && !liveFailed && !endingLatched && !endedPublished &&
        !commitPending && !previewActivity && !previewPending &&
        videoControl.context != nullptr &&
        videoControl.nextDueHostTicks != nullptr) {
      due = videoControl.nextDueHostTicks(videoControl.context);
    }
    dependencies.wake->publishVideoDueHostTicks(due);
  }

  // Public methods publish POD commands under mutex. Only this worker copies
  // them into the unsynchronised owner fields below; callbacks and the public
  // threads never read or write worker state directly.
  void acceptPublishedCommands() noexcept {
#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
    bool previewPulled = false;
#endif
    {
      std::lock_guard lock(mutex);
    if (publishedStop.has_value()) {
      if (!stopLatched) {
        stopCommand = *publishedStop;
        stopLatched = true;
        publishedStart.reset();
        publishedRun.reset();
        publishedGain.reset();
        publishedMuted.reset();
        startPending = false;
        runPending = false;
        gainPending = false;
        mutedPending = false;
        audioProofPending.reset();
        retainedVideoEvent.reset();
        publishedPreviewHandoff.reset();
        publishedPreview.reset();
        previewHandoffPending = false;
        previewHandoffReady = false;
        previewHandoffFailed = false;
        previewPending = false;
        previewIssued = false;
        previewTarget.reset();
        publishedCommit.reset();
        commitPending = false;
        commitAudioStarted = false;
        commitSourcePaused = false;
        commitTargetPaused = false;
        commitTimebaseActivated = false;
        commitIssued = false;
        commitCommitted = false;
        commitAudioProof.reset();
        commitVideoProof.reset();
        pendingFailure.reset();
      }
      return;
    }
    if (publishedPrepare.has_value() && !preparePending) {
      prepareCommand = publishedPrepare->command;
      reservedGeneration = prepareCommand.reservedGeneration.value;
      initialPosition = publishedPrepare->initialPosition;
      preparePending = true;
    }
    if (publishedStart.has_value() && !startPending) {
      startCommand = *publishedStart;
      publishedStart.reset();
      startPending = true;
    }
    if (publishedRun.has_value() &&
        (!runPending ||
         protocol::follows(runCommand.stamp, publishedRun->stamp))) {
      runCommand = *publishedRun;
      publishedRun.reset();
      runPending = true;
      requestedRunStamp = runCommand.stamp;
      publicRequestedRunStamp = requestedRunStamp;
    }
    if (publishedPreviewHandoff.has_value() && !previewHandoffReady &&
        !previewHandoffFailed) {
      previewLaneAcceptedThrough = *publishedPreviewHandoff;
      publishedPreviewHandoff.reset();
      previewHandoffPending = true;
    }
    if (publishedPreview.has_value()) {
      previewCommand = publishedPreview->command;
      previewTarget.emplace(std::move(publishedPreview->target));
      if (previewControl.request == nullptr) {
        previewLaneAcceptedThrough = publishedPreview->acceptedThrough;
      }
      publishedPreview.reset();
      previewPending = true;
      previewIssued = false;
#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
      previewPulled = true;
#endif
    }
    if (publishedCommit.has_value() && !commitPending) {
      commitCommand = publishedCommit->command;
      commitTarget = publishedCommit->target;
      commitDrawBaseline = publishedCommit->drawBaseline;
      commitAudioStarted = false;
      commitSourcePaused = false;
      commitTargetPaused = false;
      commitTimebaseActivated = false;
      if (publishedCommit->reviveFromEnded) {
        endingLatched = false;
        endedPublished = false;
        dispatcherExhausted = false;
        endingStamp = {};
      }
      publishedCommit.reset();
      commitPending = true;
      commitIssued = false;
      commitCommitted = false;
      commitAudioProof.reset();
      commitVideoProof.reset();
      retainedVideoEvent.reset();
      publishedPreviewHandoff.reset();
      previewHandoffPending = false;
      previewHandoffReady = false;
      previewHandoffFailed = false;
      previewPending = false;
      previewIssued = false;
      previewTarget.reset();
    }
    if (publishedGain.has_value()) {
      requestedGain = *publishedGain;
      publishedGain.reset();
      gainPending = true;
    }
    if (publishedMuted.has_value()) {
      requestedMuted = *publishedMuted;
      publishedMuted.reset();
      mutedPending = true;
    }
    }
#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
    if (previewPulled) {
      std::atomic<bool>* const entered =
          previewPullBarrierEntered.load(std::memory_order_acquire);
      std::atomic<bool>* const release =
          previewPullBarrierRelease.load(std::memory_order_acquire);
      if (entered != nullptr && release != nullptr &&
          !previewPullBarrierConsumed.exchange(true,
                                                std::memory_order_acq_rel)) {
        entered->store(true, std::memory_order_release);
        while (!release->load(std::memory_order_acquire)) {
          std::this_thread::yield();
        }
      }
    }
#endif
  }

  [[nodiscard]] bool buildGraph() noexcept {
    if (videoObserver != nullptr || audioObserver != nullptr || dispatcher) {
      return true;
    }
#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
    if (testFactory != nullptr) {
      NativeMediaSessionTestGraph graph = testFactory(testFactoryContext);
      if (graph.source == nullptr || graph.video == nullptr ||
          graph.audio == nullptr || graph.videoControl.arm == nullptr ||
          graph.videoControl.highestExposed == nullptr ||
          graph.videoControl.lastOutputEventSequence == nullptr ||
          graph.videoControl.nextDueHostTicks == nullptr ||
          graph.videoControl.takeOutputEvent == nullptr ||
          graph.videoControl.quiesceForPreview == nullptr ||
          graph.audioControl.start == nullptr ||
          graph.audioControl.setPaused == nullptr ||
          graph.audioControl.setGain == nullptr ||
          graph.audioControl.setMuted == nullptr ||
          graph.audioControl.stop == nullptr ||
          graph.audioControl.clock == nullptr ||
          graph.audioControl.highestExposed == nullptr ||
          graph.previewControl.request == nullptr ||
          graph.previewControl.pump == nullptr ||
          graph.previewControl.takePresented == nullptr ||
          graph.previewControl.stop == nullptr) {
        return false;
      }
      videoControl = {graph.videoControl.context,
                      graph.videoControl.arm,
                      graph.videoControl.highestExposed,
                      graph.videoControl.lastOutputEventSequence,
                      graph.videoControl.nextDueHostTicks,
                      graph.videoControl.takeOutputEvent,
                      graph.videoControl.quiesceForPreview};
      audioControl = {graph.audioControl.context,
                      graph.audioControl.start,
                      graph.audioControl.setPaused,
                      graph.audioControl.setGain,
                      graph.audioControl.setMuted,
                      graph.audioControl.stop,
                      graph.audioControl.clock,
                      graph.audioControl.highestExposed};
      previewControl = {graph.previewControl.context,
                        graph.previewControl.request,
                        graph.previewControl.pump,
                        graph.previewControl.takePresented,
                        graph.previewControl.stop};
      assetContextSnapshot = std::move(graph.assetContext);
      previewBindingObserver = graph.observePreviewBinding;
      previewBindingObserverContext = graph.previewBindingObserverContext;
      sourceOwned = std::make_unique<NativeV1AdmissionSource>(
          std::move(graph.source), cancellation);
      videoOwned = std::move(graph.video);
      audioOwned = std::move(graph.audio);
      videoObserver = videoOwned.get();
      audioObserver = audioOwned.get();
      audioConsumerControl = audioControl;
      return true;
    }
    return false;
#else
    std::unique_ptr<media::MediaSource> source;
    std::unique_ptr<NativeAudioSession> audio;
    std::unique_ptr<NativeVideoConsumer> video;
    try {
      // Container routing. AVFoundation cannot demux Matroska at all, so a
      // Matroska/WebM local file is admitted through the neutral Matroska
      // demuxer instead. Selection is by container only: the Matroska source
      // still applies its own exact codec envelope and reports Unsupported for
      // anything outside it (VP9, subtitle-only, audio-only, ...), which keeps
      // the existing fallback path as the single rejection route.
      std::unique_ptr<media::MediaSource> backendSource;
      if (matroskaLocalContainer(binding.localPath)) {
        backendSource = std::make_unique<MatroskaMediaSource>();
      } else {
        backendSource = std::make_unique<AVFoundationMediaSource>();
      }
      source = std::make_unique<NativeV1AdmissionSource>(
          std::move(backendSource), cancellation);
      NativeAudioSessionDependencies audioDependencies;
      audioDependencies.externalLifetime = childLifetime;
      audioDependencies.hostClock = dependencies.hostClock;
      audioDependencies.outputCalls = dependencies.audioUnitCalls;
      audioDependencies.outputWake = dependencies.wake->audio();
      audioDependencies.converterBackend =
          std::move(dependencies.audioConverterBackend);
      audio = NativeAudioSession::create(reservedGeneration,
                                         std::move(audioDependencies));
      const NativeVideoClockSeam clock{
          &sampleCachedClock, childLifetime->clock.get(),
          dependencies.hostClock.ticksPerSecond,
          true};
      video = NativeVideoConsumer::create(
          childLifetime, clock, dependencies.videoOutput,
          dependencies.wake->video());
    } catch (...) {
      return false;
    }
    if (source == nullptr || audio == nullptr || video == nullptr) {
      return false;
    }
    videoControl = {
        video.get(),
        [](void* context, MediaGeneration value) noexcept {
          return static_cast<NativeVideoConsumer*>(context)
              ->armFirstGeneration(value);
        },
        [](void* context) noexcept {
          const NativeVideoConsumerFacts facts =
              static_cast<NativeVideoConsumer*>(context)->facts();
          return std::max({facts.generation, facts.armedGeneration,
                           facts.output.generation,
                           facts.decoder.generation});
        },
        [](void* context) noexcept {
          return static_cast<NativeVideoConsumer*>(context)
              ->facts()
              .lastOutputEventSequence;
        },
        [](void* context) noexcept {
          return static_cast<NativeVideoConsumer*>(context)
              ->nextDueHostTicks();
        },
        [](void* context) noexcept {
          return static_cast<NativeVideoConsumer*>(context)
              ->takeOutputEvent();
        },
        [](void* context, MediaGeneration generation) noexcept {
          return static_cast<NativeVideoConsumer*>(context)
              ->quiesceForPreview(generation);
        },
        // Worker-thread only, exactly like every other entry in this table.
        // NativeVideoConsumer::facts() is an owner-serialized read, so the
        // metrics stream must never call it from the GUI thread; the worker
        // copies the result into the Impl's atomic publication slots instead.
        [](void* context, NativeMediaSessionMetrics* out) noexcept {
          const NativeVideoConsumerFacts facts =
              static_cast<NativeVideoConsumer*>(context)->facts();
          out->drawnFrames = facts.output.drawnFrames;
          out->submittedFrames = facts.output.submittedFrames;
          out->supersededFrames = facts.output.supersededFrames;
          out->discardedLateFrames = facts.discardedLateFrames;
          return true;
        }};
    audioControl = {
        audio.get(),
        [](void* context) noexcept {
          return static_cast<NativeAudioSession*>(context)->start();
        },
        [](void* context, bool paused) noexcept {
          return static_cast<NativeAudioSession*>(context)->setPaused(paused);
        },
        [](void* context, float gain) noexcept {
          return static_cast<NativeAudioSession*>(context)->setGain(gain);
        },
        [](void* context, bool muted) noexcept {
          return static_cast<NativeAudioSession*>(context)->setMuted(muted);
        },
        [](void* context) noexcept {
          return static_cast<NativeAudioSession*>(context)->stop();
        },
        [](void* context) noexcept {
          return static_cast<NativeAudioSession*>(context)->visibleClock();
        },
        [](void* context) noexcept {
          return static_cast<NativeAudioSession*>(context)
              ->facts()
              .highestExposedGeneration;
        },
        // renderStats() reads only relaxed callback-owned atomics, so it is
        // the one audio accessor that would also be safe off-worker. It is
        // still called here so the whole published set comes from one worker
        // pass and no other thread ever touches NativeAudioSession.
        [](void* context, NativeMediaSessionMetrics* out) noexcept {
          const NativeAudioRenderStats stats =
              static_cast<NativeAudioSession*>(context)->renderStats();
          out->audioUnderrunCallbacks = stats.underrunCallbacks;
          out->audioClockAdvancedUnderruns = stats.clockAdvancedUnderruns;
          out->audioRetiredLateFrames = stats.retiredLateFrames;
          out->audioCallbacks = stats.callbacks;
          out->audioRenderedFrames = stats.renderedFrames;
          return true;
        },
        [](void* context) noexcept {
          return static_cast<NativeAudioSession*>(context)
              ->suspendOutputForPause();
        },
        [](void* context, NativePlaybackRate rate,
           bool preservePitch) noexcept {
          return static_cast<NativeAudioSession*>(context)->setRate(
              rate, preservePitch);
        }};
    sourceOwned = std::move(source);
    videoOwned = std::move(video);
    audioOwned = std::move(audio);
    videoObserver = videoOwned.get();
    audioObserver = audioOwned.get();
    audioConsumerControl = audioControl;
    return true;
#endif
  }

  [[nodiscard]] bool transferToDispatcher() noexcept {
    if (dispatcher != nullptr || sourceOwned == nullptr ||
        videoOwned == nullptr || audioOwned == nullptr) {
      return dispatcher != nullptr;
    }
    try {
      dispatcher = std::make_unique<media::NativeMediaDispatcher>(
          std::move(sourceOwned), std::move(videoOwned),
          std::move(audioOwned));
    } catch (...) {
      return false;
    }
    // Typed observers are non-owning and are dereferenced only while this
    // dispatcher remains retained. shutdown() joins the worker before the
    // dispatcher (and therefore either observed port) is destroyed.
    ownership = NativeMediaSessionOwnershipPhase::DispatcherUnobserved;
    {
      std::lock_guard lock(mutex);
      dispatcherObserver = dispatcher.get();
    }
    return true;
  }

  [[nodiscard]] bool ensurePreviewLane() noexcept {
#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
    if (previewControl.request != nullptr &&
        previewBindingObserver == nullptr) {
      return previewControl.pump != nullptr &&
             previewControl.takePresented != nullptr &&
             previewControl.stop != nullptr;
    }
#endif
    if (descriptorSnapshot == nullptr || dependencies.previewOutput == nullptr ||
        !protocol::validLive(previewLaneAcceptedThrough) ||
        activeGeneration == 0) {
      return false;
    }
    // Every backend that admitted a main generation can also be previewed:
    // the binding carries the neutral prepared context, and
    // createNativePreviewSource() selects the reader from its backendKind().
    // A context this build cannot preview yields a null source below, and the
    // scrub lane simply stays inactive without disturbing main playback.
    NativePreviewBinding sourceBinding{
        binding.localPath, descriptorSnapshot, {}, assetContextSnapshot};
#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
    if (previewBindingObserver != nullptr &&
        !previewBindingObserver(previewBindingObserverContext,
                                sourceBinding)) {
      return false;
    }
#endif
    if (previewControl.request != nullptr) {
      return previewControl.pump != nullptr &&
             previewControl.takePresented != nullptr &&
             previewControl.stop != nullptr;
    }
    if (assetContextSnapshot == nullptr) {
      return false;
    }
    auto previewSource = createNativePreviewSource(sourceBinding);
    if (previewSource == nullptr) {
      return false;
    }
    const NativeTrackedVideoOutputWakeSeam edge =
        dependencies.wake->trackedVideo();
    NativePreviewFrameLaneBinding laneBinding{
        std::move(sourceBinding),
        protocol::Generation{activeGeneration}, previewLaneAcceptedThrough};
    previewLane = NativePreviewFrameLane::create(
        std::move(laneBinding), dependencies.previewOutput,
        NativePreviewFrameLaneWakeSeam{childLifetime, edge.signal,
                                       edge.context},
        std::move(previewSource));
    if (previewLane == nullptr) {
      return false;
    }
    previewControl = {
        previewLane.get(),
        [](void* context, protocol::PreviewFrame command,
           NativePreviewFrameTarget target) noexcept {
          return static_cast<NativePreviewFrameLane*>(context)->request(
              command, std::move(target));
        },
        [](void* context) noexcept {
          return static_cast<NativePreviewFrameLane*>(context)->pump();
        },
        [](void* context) noexcept {
          return static_cast<NativePreviewFrameLane*>(context)
              ->takePresented();
        },
        [](void* context, protocol::Generation generation) noexcept {
          return static_cast<NativePreviewFrameLane*>(context)->stop(
              generation);
        }};
    return true;
  }

  [[nodiscard]] NativePreviewFrameCancelProgress
  stopPreviewLaneForTerminal() noexcept {
    if (previewControl.context == nullptr) {
      previewActivity = false;
      previewHandoffPending = false;
      previewHandoffReady = false;
      previewHandoffFailed = false;
      previewMainQuiesced = false;
      return NativePreviewFrameCancelProgress::Done;
    }
    const NativePreviewFrameCancelProgress progress = previewControl.stop(
        previewControl.context, protocol::Generation{activeGeneration});
    if (progress == NativePreviewFrameCancelProgress::Quiescing) {
      return progress;
    }
    if (progress != NativePreviewFrameCancelProgress::Done) {
      return progress;
    }
    previewActivity = false;
    previewHandoffPending = false;
    previewHandoffReady = false;
    previewHandoffFailed = false;
    previewMainQuiesced = false;
#if !defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
    previewControl = {};
    previewLane.reset();
#endif
    return NativePreviewFrameCancelProgress::Done;
  }

  [[nodiscard]] bool previewTerminalLocked(
      bool allowPublishedEnded = false) const noexcept {
    // publicEnding remains latched together with publicEnded. Only that fully
    // published state is reusable: the preceding audio-stop/drain interval is
    // still terminal to preview, as are Stop, Commit, and live failure.
    const bool endingIsTerminal =
        (publicEnding || publicEnded) &&
        !(allowPublishedEnded && publicEnded);
    return exitRequested || publishedStop.has_value() ||
           publicCommitPending || publicLiveFailed || endingIsTerminal;
  }

  // Caller owns mutex. Preview child completion and its public result must be
  // one transaction with Stop/Commit admission; otherwise a terminal command
  // can clear these facts only for a late child failure to resurrect them.
  [[nodiscard]] bool failPreviewHandoffLocked() noexcept {
    bool publishedFailure = false;
    if (publicPreviewPending && latestPreview.has_value()) {
      const protocol::PreviewFrame &command = *latestPreview;
      const protocol::PreviewFailed failed{
          command.stamp, command.generation, command.gesture, command.request,
          command.targetSeconds};
      if (protocol::valid(failed)) {
        previewFailedSlot = failed;
        publishedFailure = true;
      }
    }
    previewHandoffPending = false;
    previewHandoffReady = false;
    previewHandoffFailed = true;
    previewPending = false;
    previewIssued = false;
    previewTarget.reset();
    // Once quiescence has begun, keep normal dispatcher admission closed.
    // Commit's generation flush or exact Stop retirement is the only safe
    // recovery when the preview graph itself cannot finish the handoff.
    previewActivity = true;
    publishedPreviewHandoff.reset();
    publishedPreview.reset();
    previewPresentedSlot.reset();
    publicPreviewHandoffPending = false;
    publicPreviewHandoffReady = false;
    publicPreviewHandoffFailed = true;
    publicPreviewPending = false;
    return publishedFailure;
  }

  void failPreviewHandoff() noexcept {
    bool publishedFailure = false;
    {
      std::lock_guard lock(mutex);
      if (!previewTerminalLocked(endedPublished)) {
        publishedFailure = failPreviewHandoffLocked();
      }
    }
    if (publishedFailure) {
      queueObservations();
    }
  }

  enum class PreviewChildCompletionPoint : std::uint8_t {
    Quiesce,
    Construction,
    Request,
    Pump,
    TakePresented,
  };

#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
  void waitPreviewCompletionBarrier(
      PreviewChildCompletionPoint point) noexcept {
    NativeMediaSessionTestPreviewCompletionPoint expected =
        NativeMediaSessionTestPreviewCompletionPoint::None;
    switch (point) {
    case PreviewChildCompletionPoint::Quiesce:
      expected = NativeMediaSessionTestPreviewCompletionPoint::Quiesce;
      break;
    case PreviewChildCompletionPoint::Construction:
      expected = NativeMediaSessionTestPreviewCompletionPoint::Construction;
      break;
    case PreviewChildCompletionPoint::Request:
      expected = NativeMediaSessionTestPreviewCompletionPoint::Request;
      break;
    case PreviewChildCompletionPoint::Pump:
      expected = NativeMediaSessionTestPreviewCompletionPoint::Pump;
      break;
    case PreviewChildCompletionPoint::TakePresented:
      expected = NativeMediaSessionTestPreviewCompletionPoint::TakePresented;
      break;
    }
    if (previewCompletionBarrierPoint.load(std::memory_order_acquire) !=
        expected) {
      return;
    }
    std::atomic<bool>* const entered =
        previewCompletionBarrierEntered.load(std::memory_order_acquire);
    std::atomic<bool>* const release =
        previewCompletionBarrierRelease.load(std::memory_order_acquire);
    if (entered == nullptr || release == nullptr ||
        previewCompletionBarrierConsumed.exchange(
            true, std::memory_order_acq_rel)) {
      return;
    }
    entered->store(true, std::memory_order_release);
    while (!release->load(std::memory_order_acquire)) {
      std::this_thread::yield();
    }
  }
#endif

  // The child call returns while its live-issue permit is still held. This
  // transaction then releases the permit, observes any public Stop/Commit,
  // and commits the child result under the same mutex. Consequently a public
  // terminal accepted during the child call or its deterministic test barrier
  // can never be overwritten by a late success, failure, or presentation.
  template <typename Commit>
  [[nodiscard]] bool completePreviewChild(
      PreviewChildCompletionPoint point, bool allowPublishedEnded,
      Commit&& commit) noexcept {
#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
    waitPreviewCompletionBarrier(point);
#else
    static_cast<void>(point);
#endif
    bool terminalWon = false;
    {
      std::lock_guard lock(mutex);
      liveIssueActive = false;
      terminalWon = previewTerminalLocked(allowPublishedEnded);
      if (!terminalWon) {
        std::forward<Commit>(commit)();
      }
    }
    if (terminalWon) {
      acceptPublishedCommands();
    }
    return !terminalWon;
  }

  void progressPreview() noexcept {
    if ((!previewHandoffPending && !previewPending) || stopLatched ||
        liveFailed || commitPending || previewHandoffFailed ||
        videoControl.quiesceForPreview == nullptr) {
      return;
    }
    previewActivity = true;
    // Dispatcher Exhausted is published only after both selected consumers
    // report EOS drained; Ended follows only after audio Stop Done. The main
    // video lane therefore owns no decoder/scheduler/output credit here and
    // must not be asked to enter its pre-EOS quiesce contract again.
    const bool previewFromPublishedEnd = endedPublished;
    if (previewFromPublishedEnd) {
      previewMainQuiesced = true;
    }
    if (!previewMainQuiesced) {
      if (!beginLiveIssue(nullptr, previewFromPublishedEnd)) {
        acceptPublishedCommands();
        return;
      }
      const NativeVideoConsumerPreviewProgress progress =
          videoControl.quiesceForPreview(videoControl.context,
                                         activeGeneration);
      bool continuePreview = true;
      bool requestWake = false;
      bool previewFailurePublished = false;
      if (!completePreviewChild(
              PreviewChildCompletionPoint::Quiesce,
              previewFromPublishedEnd, [&] {
                switch (progress) {
                case NativeVideoConsumerPreviewProgress::Done:
                  previewMainQuiesced = true;
                  break;
                case NativeVideoConsumerPreviewProgress::Progress:
                  requestWake = true;
                  continuePreview = false;
                  break;
                case NativeVideoConsumerPreviewProgress::Quiescing:
                  continuePreview = false;
                  break;
                case NativeVideoConsumerPreviewProgress::StaleGeneration:
                case NativeVideoConsumerPreviewProgress::KeyFrameRequired:
                case NativeVideoConsumerPreviewProgress::Failed:
                  previewFailurePublished = failPreviewHandoffLocked();
                  continuePreview = false;
                  break;
                }
              })) {
        return;
      }
      if (previewFailurePublished) {
        queueObservations();
      }
      if (requestWake) {
        dependencies.wake->notify();
      }
      if (!continuePreview) {
        return;
      }
    }
    if (!beginLiveIssue(nullptr, previewFromPublishedEnd)) {
      acceptPublishedCommands();
      return;
    }
    const bool laneReady = ensurePreviewLane();
#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
    if (std::atomic<bool>* const entered =
            previewConstructionBarrierEntered.load(
                std::memory_order_acquire)) {
      std::atomic<bool>* const release =
          previewConstructionBarrierRelease.load(std::memory_order_acquire);
      if (release != nullptr &&
          !previewConstructionBarrierConsumed.exchange(
              true, std::memory_order_acq_rel)) {
        entered->store(true, std::memory_order_release);
        while (!release->load(std::memory_order_acquire)) {
          std::this_thread::yield();
        }
      }
    }
#endif
    bool constructionFailed = false;
    bool constructionFailurePublished = false;
    if (!completePreviewChild(
            PreviewChildCompletionPoint::Construction,
            previewFromPublishedEnd, [&] {
              if (!laneReady) {
                constructionFailurePublished = failPreviewHandoffLocked();
                constructionFailed = true;
              } else if (!previewHandoffReady) {
                previewHandoffPending = false;
                previewHandoffReady = true;
                publicPreviewHandoffPending = false;
                publicPreviewHandoffReady = true;
              }
            })) {
      return;
    }
    if (constructionFailurePublished) {
      queueObservations();
    }
    if (constructionFailed) {
      return;
    }
    if (!previewPending) {
      return;
    }
    if (!previewIssued) {
      if (!previewTarget.has_value()) {
        failPreviewHandoff();
        return;
      }
      // The live-issue permit linearizes this child mutation against public
      // Stop/Commit admission. A terminal command accepted after the permit
      // owns the immediately following cleanup, never a second preview issue.
      if (!beginLiveIssue(nullptr, previewFromPublishedEnd, false)) {
        acceptPublishedCommands();
        return;
      }
      const NativePreviewFrameRequestStatus status = previewControl.request(
          previewControl.context, previewCommand,
          std::move(*previewTarget));
      bool requestFailed = false;
      bool requestFailurePublished = false;
      if (!completePreviewChild(
              PreviewChildCompletionPoint::Request,
              previewFromPublishedEnd, [&] {
                previewTarget.reset();
                if (status != NativePreviewFrameRequestStatus::Accepted &&
                    status != NativePreviewFrameRequestStatus::Replaced) {
                  requestFailurePublished = failPreviewHandoffLocked();
                  requestFailed = true;
                } else {
                  previewIssued = true;
                  previewActivity = true;
                }
              })) {
        return;
      }
      if (requestFailurePublished) {
        queueObservations();
      }
      if (requestFailed) {
        return;
      }
    }
    for (unsigned count = 0; count != 32; ++count) {
      if (!beginLiveIssue(nullptr, previewFromPublishedEnd)) {
        acceptPublishedCommands();
        return;
      }
      const NativePreviewFramePumpProgress progress =
          previewControl.pump(previewControl.context);
      bool pumpFailed = false;
      bool pumpFailurePublished = false;
      if (!completePreviewChild(
              PreviewChildCompletionPoint::Pump,
              previewFromPublishedEnd, [&] {
                if (progress == NativePreviewFramePumpProgress::Failed ||
                    progress == NativePreviewFramePumpProgress::Stopped) {
                  pumpFailurePublished = failPreviewHandoffLocked();
                  pumpFailed = true;
                }
              })) {
        return;
      }
      if (pumpFailurePublished) {
        queueObservations();
      }
      if (pumpFailed) {
        return;
      }
      if (!beginLiveIssue(nullptr, previewFromPublishedEnd)) {
        acceptPublishedCommands();
        return;
      }
      std::optional<protocol::PreviewPresented> presented =
          previewControl.takePresented(previewControl.context);
      bool tookPresentation = false;
      bool publish = false;
      bool invalidPresentation = false;
      bool presentationFailurePublished = false;
      if (!completePreviewChild(
              PreviewChildCompletionPoint::TakePresented,
              previewFromPublishedEnd, [&] {
                if (!presented.has_value()) {
                  return;
                }
                tookPresentation = true;
                if (latestPreview.has_value() &&
                    protocol::previewPresentedMatches(*latestPreview,
                                                      *presented)) {
                  previewPresentedSlot = *presented;
                  publicPreviewPending = false;
                  publish = true;
                } else if (!publishedPreview.has_value()) {
                  invalidPresentation = true;
                  presentationFailurePublished = failPreviewHandoffLocked();
                }
                previewPending = false;
                previewIssued = false;
              })) {
        return;
      }
      if (presentationFailurePublished) {
        queueObservations();
      }
      if (tookPresentation) {
        if (publish) {
          queueObservations();
        }
        if (invalidPresentation) {
          return;
        }
        // A newer preview can be accepted while the just-completed request is
        // being pumped. Pull it before returning so its already-coalesced wake
        // cannot be lost behind completion of the superseded presentation.
        acceptPublishedCommands();
        if (previewPending) {
          dependencies.wake->notify();
        }
        return;
      }
      if (progress == NativePreviewFramePumpProgress::Progress) {
        continue;
      }
      if (progress == NativePreviewFramePumpProgress::Idle) {
        return;
      }
      return;
    }
    dependencies.wake->notify();
  }

  [[nodiscard]] bool directRetire() noexcept {
    ownership = NativeMediaSessionOwnershipPhase::DirectRetiring;
    if (!directVideoRetired) {
      if (directVideoRetiredGeneration == 0) {
        directVideoRetiredGeneration =
            videoControl.highestExposed(videoControl.context);
      }
      const auto progress =
          videoObserver->retire(directVideoRetiredGeneration,
                                stopCommand.invalidationGeneration.value);
      if (progress == media::NativeMediaConsumerProgress::Done) {
        directVideoRetired = true;
      } else if (progress == media::NativeMediaConsumerProgress::Progress) {
        dependencies.wake->notify();
        return false;
      } else if (progress ==
                 media::NativeMediaConsumerProgress::Quiescing) {
        return false;
      } else {
        stopFailed = true;
        return false;
      }
    }
    if (!directAudioRetired) {
      if (directAudioRetiredGeneration == 0) {
        // Never audioControl here: an audio-less generation has rebound that
        // table to the silent timebase, whose generation is not the audio
        // consumer's exposure high water.
        directAudioRetiredGeneration = audioConsumerControl.highestExposed(
            audioConsumerControl.context);
      }
      const auto progress =
          audioObserver->retire(directAudioRetiredGeneration,
                                stopCommand.invalidationGeneration.value);
      if (progress == media::NativeMediaConsumerProgress::Done) {
        directAudioRetired = true;
      } else if (progress == media::NativeMediaConsumerProgress::Progress) {
        dependencies.wake->notify();
        return false;
      } else if (progress ==
                 media::NativeMediaConsumerProgress::Quiescing) {
        return false;
      } else {
        stopFailed = true;
        return false;
      }
    }
    if (dispatcher != nullptr) {
      const MediaGeneration current = dispatcher->stats().generation;
      const auto closed = dispatcher->close(current);
      if (closed.status ==
          media::NativeMediaDispatcherLifecycleStatus::Pending) {
        if (dispatcher->stats().lastWait ==
            media::NativeMediaDispatcherWait::CallAgain) {
          dependencies.wake->notify();
        }
        return false;
      }
      if (closed.status != media::NativeMediaDispatcherLifecycleStatus::Done) {
        stopFailed = true;
        return false;
      }
    }
    return true;
  }

  [[nodiscard]] bool retireObserved() noexcept {
    ownership = NativeMediaSessionOwnershipPhase::DispatcherRetiring;
    const auto result = dispatcher->retire(
        dispatcher->stats().generation,
        stopCommand.invalidationGeneration.value);
    if (result.status == media::NativeMediaDispatcherLifecycleStatus::Done) {
      return true;
    }
    if (result.status ==
            media::NativeMediaDispatcherLifecycleStatus::Pending &&
        dispatcher->stats().lastWait ==
            media::NativeMediaDispatcherWait::CallAgain) {
      dependencies.wake->notify();
    }
    if (result.status !=
        media::NativeMediaDispatcherLifecycleStatus::Pending) {
      stopFailed = true;
    }
    return false;
  }

  void progressStop() noexcept {
    // A published Stop failure is terminal: the router has already moved to
    // NativeStopFailed and no further port progress can change the outcome.
    // Re-entering retirement afterwards is not merely useless, it is a live
    // spin: every retirement pass observes the tracked video output, and an
    // output with a close still pending re-signals this worker's wake on each
    // observation, so wait() would never block again.
    if (!stopLatched || stoppedPublished || stopFailurePublished) {
      return;
    }
    const NativePreviewFrameCancelProgress previewStopped =
        stopPreviewLaneForTerminal();
    if (previewStopped == NativePreviewFrameCancelProgress::Quiescing) {
      return;
    }
    if (previewStopped != NativePreviewFrameCancelProgress::Done) {
      stopFailed = true;
    }
    bool done = false;
    if (ownership == NativeMediaSessionOwnershipPhase::PrearmOwned ||
        ownership ==
            NativeMediaSessionOwnershipPhase::DispatcherUnobserved ||
        ownership == NativeMediaSessionOwnershipPhase::DirectRetiring) {
      if (videoObserver == nullptr || audioObserver == nullptr) {
        stopFailed = true;
      } else {
        done = directRetire();
      }
    } else if (ownership ==
                   NativeMediaSessionOwnershipPhase::DispatcherObserved ||
               ownership ==
                   NativeMediaSessionOwnershipPhase::DispatcherRetiring) {
      done = dispatcher != nullptr && retireObserved();
    } else if (ownership == NativeMediaSessionOwnershipPhase::Empty) {
      done = true;
    }
    if (stopFailed) {
      if (stopFailurePublished) {
        return;
      }
      stopFailurePublished = true;
      publishWorkerFacts();
      static_cast<void>(publishFailure(protocol::FailureReason::Stop,
                                       stopCommand.stamp));
      return;
    }
    if (done) {
      ownership = NativeMediaSessionOwnershipPhase::Closed;
      static_cast<void>(publishStopped());
    }
  }

  void progressPrepare() noexcept {
    if (stopLatched || preparedPublished || prepareFailed) {
      return;
    }
    if (!beginLiveIssue()) {
      acceptPublishedCommands();
      return;
    }
    const bool graphBuilt = buildGraph();
    endLiveIssue();
    if (!graphBuilt) {
      prepareFailed = true;
      logNativeFailure("open/graph", protocol::FailureReason::Preparation,
                       dispatcher.get());
      static_cast<void>(publishFailure(protocol::FailureReason::Preparation,
                                       prepareCommand.stamp));
      return;
    }
    // From this point both concrete ports exist and exact retirement owns
    // them, even if Stop won during factory construction before video prearm.
    ownership = NativeMediaSessionOwnershipPhase::PrearmOwned;
    if (stopPublished()) {
      acceptPublishedCommands();
      return;
    }
    if (!beginLiveIssue()) {
      acceptPublishedCommands();
      return;
    }
    const NativeVideoConsumerArmProgress armed =
        videoControl.arm(videoControl.context, reservedGeneration);
    endLiveIssue();
    switch (armed) {
    case NativeVideoConsumerArmProgress::Quiescing:
      return;
    case NativeVideoConsumerArmProgress::Done:
      break;
    case NativeVideoConsumerArmProgress::StaleGeneration:
case NativeVideoConsumerArmProgress::Failed:
      prepareFailed = true;
      logNativeFailure("open/arm", protocol::FailureReason::Startup,
                       dispatcher.get());
      static_cast<void>(publishFailure(protocol::FailureReason::Startup));
      return;
    }
    if (stopPublished()) {
      acceptPublishedCommands();
      return;
    }
    if (stopLatched) {
      return;
    }
    if (!beginLiveIssue()) {
      acceptPublishedCommands();
      return;
    }
    const bool transferred = transferToDispatcher();
    endLiveIssue();
if (!transferred) {
      prepareFailed = true;
      logNativeFailure("open/transfer", protocol::FailureReason::Startup,
                       dispatcher.get());
      static_cast<void>(publishFailure(protocol::FailureReason::Startup));
      return;
    }
    if (stopPublished()) {
      acceptPublishedCommands();
      return;
    }
    media::MediaSourceOpenOptions options;
    options.selection.requireVideo = true;
    // Audio is optional. A source with no audio track at all is admitted and
    // driven by NativeSilentTimebase; a source that carries audio the backend
    // cannot select still fails its own admission, so relaxing this flag does
    // not silently drop a real audio track.
    options.selection.requireAudio = false;
    options.initialPosition = media::MediaSourceInitialPosition{
        initialPosition, media::MediaSeekMode::Accurate};
    if (!beginLiveIssue()) {
      acceptPublishedCommands();
      return;
    }
    const auto opened = dispatcher->openLocalFile(
        binding.localPath, options, reservedGeneration);
    endLiveIssue();
    dispatcherObservedVideo =
        dispatcher->stats().videoExposedGeneration != 0;
    if (dispatcherObservedVideo) {
      ownership = NativeMediaSessionOwnershipPhase::DispatcherObserved;
    }
    if (stopPublished()) {
      acceptPublishedCommands();
      return;
    }
    if (opened.status != media::NativeMediaDispatcherOpenStatus::Ready) {
      // Output prearm already exposed reservedGeneration. Therefore even a
      // source-level Unsupported result is a Startup failure requiring exact
      // Stop; UnsupportedSource would be a false generation-free proof.
prepareFailed = true;
      {
        const auto reason =
            opened.status == media::NativeMediaDispatcherOpenStatus::Failed
                ? protocol::FailureReason::Protocol
                : protocol::FailureReason::Startup;
        logNativeFailure("open", reason, dispatcher.get());
        static_cast<void>(publishFailure(reason));
      }
      return;
    }
    const auto descriptor = dispatcher->descriptor();
if (descriptor == nullptr || !nativeV1Descriptor(*descriptor)) {
      prepareFailed = true;
      logNativeFailure("open/descriptor", protocol::FailureReason::Protocol,
                       dispatcher.get());
      static_cast<void>(publishFailure(protocol::FailureReason::Protocol));
      return;
    }
#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
    if (assetContextSnapshot != nullptr &&
        (assetContextSnapshot->descriptor().get() != descriptor.get() ||
         !assetContextSnapshot->matchesPreviewBinding(binding.localPath,
                                                      descriptor))) {
      prepareFailed = true;
      static_cast<void>(publishFailure(protocol::FailureReason::Protocol));
      return;
    }
#else
    // Backend-neutral admission proof. The dispatcher republishes the exact
    // immutable context the source admitted at Ready, so the session no longer
    // needs a concrete AVFoundation observer to state this identity and the
    // same check covers a Matroska generation unchanged.
    std::shared_ptr<const media::MediaSourcePreparedContext>
        admittedAssetContext = dispatcher->preparedContext();
    if (admittedAssetContext == nullptr ||
        admittedAssetContext->descriptor().get() != descriptor.get() ||
        !admittedAssetContext->matchesPreviewBinding(binding.localPath,
                                                     descriptor)) {
      prepareFailed = true;
      logNativeFailure("open/context", protocol::FailureReason::Protocol,
                       dispatcher.get());
      static_cast<void>(publishFailure(protocol::FailureReason::Protocol));
      return;
    }
    assetContextSnapshot = std::move(admittedAssetContext);
#endif
    descriptorSnapshot = descriptor;
    // Bind the generation's timebase before anything can publish Prepared.
    // From here the Start / SetRunState / CommitSeek / Ended chains address
    // whichever authority this generation owns, with no further branching.
    if (!descriptor->selectedAudio.has_value()) {
      if (silentTimebase == nullptr) {
        silentTimebase = NativeSilentTimebase::create(dependencies.hostClock);
      }
      if (silentTimebase == nullptr ||
          !silentTimebase->activate(reservedGeneration,
                                    prepareCommand.initialPositionSeconds)) {
        prepareFailed = true;
        static_cast<void>(publishFailure(protocol::FailureReason::Clock));
        return;
      }
      audioControl = silentTimebaseControl(silentTimebase.get());
      // The audio render callback was the only periodic edge that woke this
      // worker to draw a frame on time. With no output unit, the worker's own
      // wait carries that deadline instead.
      dependencies.wake->setHostPacedDeadlines(dependencies.hostClock);
    }
    bool committed = false;
    {
      std::lock_guard lock(mutex);
      if (!publishedStop.has_value() && !publicLiveFailed &&
          !publicCommitPending &&
          !factMailbox.has_value()) {
        activeGeneration = reservedGeneration;
        preparedPublished = true;
        publicPrepared = true;
        publicDurationSeconds = descriptorDurationSeconds(*descriptor);
        publicOwnership = ownership;
        publicDispatcherObservedVideo = dispatcherObservedVideo;
        factMailbox.emplace(protocol::Prepared{
            prepareCommand.stamp, prepareCommand.sourceKey,
            {descriptorDurationSeconds(*descriptor),
             descriptor->selectedAudio.has_value(), true},
            prepareCommand.reservedGeneration});
        committed = true;
      }
    }
    if (committed) {
      queueObservations();
    } else {
      acceptPublishedCommands();
    }
  }

  void progressStart() noexcept {
    if (stopLatched || !preparedPublished || startedPublished ||
        !startPending || startCommand.preparedGeneration.value !=
                             reservedGeneration) {
      return;
    }
if (audioControl.start == nullptr) {
      logNativeFailure("start", protocol::FailureReason::Startup,
                       dispatcher.get());
      static_cast<void>(publishFailure(protocol::FailureReason::Startup));
      startPending = false;
      return;
    }
    if (!beginLiveIssue()) {
      acceptPublishedCommands();
      return;
    }
    const NativeAudioSessionProgress result =
        audioControl.start(audioControl.context);
    endLiveIssue();
    if (stopPublished()) {
      acceptPublishedCommands();
      return;
    }
    if (result == NativeAudioSessionProgress::Quiescing ||
        result == NativeAudioSessionProgress::WaitingForData) {
      return;
    }
if (result != NativeAudioSessionProgress::Done) {
      logNativeFailure("start/audio", protocol::FailureReason::Startup,
                       dispatcher.get());
      static_cast<void>(publishFailure(protocol::FailureReason::Startup));
      startPending = false;
      return;
    }
    // facts() includes any output event already published but not yet
    // consumed, so this baseline is linearized against render publication.
    if (!beginLiveIssue()) {
      acceptPublishedCommands();
      return;
    }
    const std::uint64_t drawBaseline =
        videoControl.lastOutputEventSequence(videoControl.context);
    endLiveIssue();
    bool committed = false;
    {
      std::lock_guard lock(mutex);
      if (!publishedStop.has_value() && !publicLiveFailed &&
          !publicCommitPending &&
          !factMailbox.has_value()) {
        startedDrawBaseline = drawBaseline;
        publicLastOutputEventSequence = drawBaseline;
        startedPublished = true;
        startPending = false;
        publicStarted = true;
        factMailbox.emplace(protocol::Started{
            startCommand.stamp, startCommand.preparedGeneration,
            drawBaseline});
        committed = true;
      }
    }
    if (committed) {
      queueObservations();
    } else {
      acceptPublishedCommands();
    }
  }

  void progressRunState() noexcept {
    if (stopLatched || endingLatched || endedPublished || liveFailed ||
        !startedPublished || !runPending ||
        audioControl.setPaused == nullptr) {
      return;
    }
    for (unsigned issueCount = 0; issueCount != 32; ++issueCount) {
      const protocol::SetRunState issued = runCommand;
      if (!beginLiveIssue(&issued)) {
        acceptPublishedCommands();
        return;
      }
      // Rate is a soft control, exactly like gain: it is snapped onto the
      // exact admission grid and published to the audio route, and a refusal
      // (no time-stretch unit on this machine) leaves the previous rate in
      // force rather than failing the transport. The clock's own authority is
      // unaffected either way -- it derives its rate from the intervals the
      // render callback publishes, not from this command. The live
      // preserve-pitch preference rides on the same command because it is
      // part of the same decision, and it is equally soft.
      if (audioControl.setRate != nullptr) {
        static_cast<void>(audioControl.setRate(
            audioControl.context, protocol::nativeRateRatio(issued.rate),
            issued.preservePitch));
      }
      const NativeAudioSessionProgress result = audioControl.setPaused(
          audioControl.context, issued.paused);
      endLiveIssue();
      bool superseded = false;
      bool acknowledgementInserted = false;
      bool failed = false;
      {
        std::lock_guard lock(mutex);
        if (publishedStop.has_value()) {
          return;
        }
        if (publishedRun.has_value() &&
            protocol::follows(issued.stamp, publishedRun->stamp)) {
          runCommand = *publishedRun;
          publishedRun.reset();
          requestedRunStamp = runCommand.stamp;
          publicRequestedRunStamp = requestedRunStamp;
          superseded = true;
        } else if (result == NativeAudioSessionProgress::Done) {
          appliedRunStamp = issued.stamp;
          appliedPaused = issued.paused;
          publicAppliedRunStamp = appliedRunStamp;
          publicAppliedPaused = appliedPaused;
          runPending = false;
          if (!dispatcherExhausted) {
            runStateAppliedSlot =
                NativeMediaSessionRunStateApplied{issued};
            acknowledgementInserted = true;
          }
          if (issued.paused) {
            audioProofPending = issued;
          } else {
            audioProofPending.reset();
          }
        } else if (result != NativeAudioSessionProgress::Quiescing &&
                   result != NativeAudioSessionProgress::WaitingForData) {
          failed = true;
        }
      }
      if (superseded) {
        continue;
      }
      if (failed) {
        static_cast<void>(
            publishFailure(protocol::FailureReason::AudioOutput));
        return;
      }
      if (result == NativeAudioSessionProgress::Quiescing ||
          result == NativeAudioSessionProgress::WaitingForData) {
        return;
      }
      if (acknowledgementInserted) {
        queueObservations();
      }
      return;
    }
    dependencies.wake->notify();
  }

  void progressAudioClockProof() noexcept {
    if (!audioProofPending.has_value() || stopLatched || endingLatched ||
        audioControl.clock == nullptr) {
      return;
    }
    const protocol::SetRunState command = *audioProofPending;
    if (!command.paused || command.stamp != appliedRunStamp ||
        command.generation.value != activeGeneration) {
      audioProofPending.reset();
      return;
    }
    {
      std::lock_guard lock(mutex);
      if (publishedStop.has_value() || publicEnding || publicEnded ||
          requestedRunStamp != appliedRunStamp ||
          publicRequestedRunStamp != appliedRunStamp) {
        return;
      }
    }
    if (!beginLiveIssue()) {
      return;
    }
    const NativeMediaClockSnapshot clock =
        audioControl.clock(audioControl.context);
    endLiveIssue();
    const protocol::AudioClockProof proof{
        command.stamp,
        command.generation,
        protocol::AudioClockAnchorId{clock.publicationSerial},
        clock.mediaSeconds,
        true,
        clock.rate};
    // protocol::valid(proof) is what now decides the rate: it admits exactly
    // the advertised pitch-preserved window and nothing else. Pinning the
    // literal unit rate here would have refused every proof the moment the
    // engine gained a rate at all, and a paused clock reports the DECLARED
    // rate, which is the playback rate.
    if (!clock.publicationCurrent || !clock.valid || clock.running ||
        clock.generation != command.generation.value ||
        !protocol::valid(proof)) {
      return;
    }
    audioProofPending.reset();
    publishAudioClock(proof);
  }

  // Idles the output AudioUnit once a pause has fully settled. Every render
  // callback is a real-time-thread wake, and a paused callback does nothing
  // but memset zeroes, so a paused session was paying ~47 wakes/s forever to
  // produce silence. NativeAudioSession::suspendOutputForPause() stops the
  // device without touching generation, stream cursor, ring or clock;
  // setPaused(false) restarts it on exactly the retained PCM.
  //
  // Deliberately not done inside setPaused(true). Measured on this machine's
  // built-in output at a 1024-frame period, AudioOutputUnitStop blocks its
  // caller for ~16 ms and AudioOutputUnitStart for ~11 ms; that is free once
  // per user-initiated pause and is not free per committed scrub position,
  // where progressCommitSeek() pauses, seeks, starts and re-pauses the output
  // for every target. So the gate below is a full "nothing else wants the
  // output" proof:
  //
  //   startedPublished        - the output is actually running to begin with
  //   !runPending             - the applied run state is settled, not in
  //                             flight, so this cannot race a resume
  //   appliedPaused           - that settled state is paused
  //   !audioProofPending      - the paused clock proof has already been
  //                             published, which means the render callback's
  //                             own pause boundary already froze the clock.
  //                             That is what makes the stop exactly
  //                             clock-neutral: settleStopped()'s clock.pause()
  //                             then takes NativeMediaClock's already-paused
  //                             early return and moves nothing.
  //   !commitPending / preview- a seek commit or a preview handoff starts the
  //                             output again within milliseconds
  //   !endingLatched/!ended   - progressEnded() owns the stop on that path and
  //                             already performs it before publishing Ended
  //
  // Quiescing and Invalid are both benign: the output re-arms the wake seam
  // before returning Quiescing, so the exiting callback brings the worker
  // straight back here, and Invalid only means the precondition moved.
  void progressAudioSuspend() noexcept {
    if (!pauseSuspendEnabled() ||
        audioControl.suspendForPause == nullptr || !startedPublished ||
        stopLatched || liveFailed || endingLatched || endedPublished ||
        commitPending || previewPending || previewActivity ||
        previewHandoffPending || runPending || !appliedPaused ||
        audioProofPending.has_value()) {
      return;
    }
    if (!beginLiveIssue()) {
      return;
    }
    const NativeAudioSessionProgress progress =
        audioControl.suspendForPause(audioControl.context);
    endLiveIssue();
    if (stopPublished()) {
      acceptPublishedCommands();
      return;
    }
    if (progress == NativeAudioSessionProgress::Failed) {
      static_cast<void>(publishFailure(protocol::FailureReason::AudioOutput));
    }
  }

  void progressAudioControls() noexcept {
    if (stopLatched || endingLatched || endedPublished || liveFailed ||
        audioControl.context == nullptr) {
      return;
    }
    if (gainPending) {
      if (!beginLiveIssue()) {
        acceptPublishedCommands();
        return;
      }
      const NativeAudioSessionProgress result =
          audioControl.setGain(audioControl.context, requestedGain);
      endLiveIssue();
      if (stopPublished()) {
        acceptPublishedCommands();
        return;
      }
      if (result == NativeAudioSessionProgress::Done) {
        gainPending = false;
      } else if (result != NativeAudioSessionProgress::Quiescing &&
                 result != NativeAudioSessionProgress::WaitingForData) {
        static_cast<void>(
            publishFailure(protocol::FailureReason::AudioOutput));
        return;
      }
    }
    if (mutedPending && !liveFailed && !endingLatched) {
      if (!beginLiveIssue()) {
        acceptPublishedCommands();
        return;
      }
      const NativeAudioSessionProgress result =
          audioControl.setMuted(audioControl.context, requestedMuted);
      endLiveIssue();
      if (stopPublished()) {
        acceptPublishedCommands();
        return;
      }
      if (result == NativeAudioSessionProgress::Done) {
        mutedPending = false;
      } else if (result != NativeAudioSessionProgress::Quiescing &&
                 result != NativeAudioSessionProgress::WaitingForData) {
        static_cast<void>(
            publishFailure(protocol::FailureReason::AudioOutput));
      }
    }
  }

  void progressCommitSeek() noexcept {
    if (!commitPending || stopLatched || liveFailed || dispatcher == nullptr ||
        audioControl.start == nullptr || audioControl.setPaused == nullptr ||
        audioControl.clock == nullptr) {
      return;
    }

    const NativePreviewFrameCancelProgress previewStopped =
        stopPreviewLaneForTerminal();
    if (previewStopped == NativePreviewFrameCancelProgress::Quiescing) {
      return;
    }
    if (previewStopped != NativePreviewFrameCancelProgress::Done) {
        static_cast<void>(publishFailure(protocol::FailureReason::CommitSeek,
                                       commitCommand.stamp));
      return;
    }

    // Pause the retired generation before source/consumer seek. Pointer
    // scrubs normally arrive already paused, while direct seeks and Starting
    // reentrancy still need this explicit physical barrier.
    if (!commitSourcePaused) {
      if (!beginLiveIssue(nullptr, false, true)) {
        acceptPublishedCommands();
        return;
      }
      const NativeAudioSessionProgress paused =
          audioControl.setPaused(audioControl.context, true);
      endLiveIssue();
      if (stopPublished()) {
        acceptPublishedCommands();
        return;
      }
      if (paused == NativeAudioSessionProgress::Quiescing ||
          paused == NativeAudioSessionProgress::WaitingForData) {
        return;
      }
      if (paused != NativeAudioSessionProgress::Done) {
        static_cast<void>(publishFailure(protocol::FailureReason::CommitSeek,
                                         commitCommand.stamp));
        return;
      }
      commitSourcePaused = true;
    }

    if (!commitIssued) {
      if (!beginLiveIssue(nullptr, false, true)) {
        acceptPublishedCommands();
        return;
      }
      const media::NativeMediaDispatcherSeekOutcome sought = dispatcher->seek(
          {commitCommand.targetGeneration.value, commitTarget,
           media::MediaSeekMode::Accurate});
      endLiveIssue();
      if (stopPublished()) {
        acceptPublishedCommands();
        return;
      }
      if (sought.status == media::NativeMediaDispatcherSeekStatus::Failed ||
          sought.status == media::NativeMediaDispatcherSeekStatus::Rejected) {
        static_cast<void>(publishFailure(protocol::FailureReason::CommitSeek,
                                         commitCommand.stamp));
        return;
      }
      commitIssued = true;
      dispatcherExhausted = false;
      if (sought.status == media::NativeMediaDispatcherSeekStatus::Accepted) {
        commitCommitted = true;
      } else if (dispatcher->stats().lastWait ==
                 media::NativeMediaDispatcherWait::CallAgain) {
        dependencies.wake->notify();
      }
    }

    if (!commitCommitted) {
      if (!beginLiveIssue(nullptr, false, true)) {
        acceptPublishedCommands();
        return;
      }
      dispatcher->setSeekSettleReadAhead(false);
      const media::NativeMediaDispatcherStep step = dispatcher->step();
      endLiveIssue();
      publishVideoDueHint();
      if (stopPublished()) {
        acceptPublishedCommands();
        return;
      }
      if (step.action == media::NativeMediaDispatcherAction::SeekCommitted) {
        commitCommitted = true;
      } else if (step.state == media::NativeMediaDispatcherState::Failed ||
                 step.action == media::NativeMediaDispatcherAction::Failed) {
        static_cast<void>(publishFailure(protocol::FailureReason::CommitSeek,
                                         commitCommand.stamp));
        return;
      } else {
        if (step.wait == media::NativeMediaDispatcherWait::CallAgain) {
          dependencies.wake->notify();
        }
        return;
      }
    }

    activeGeneration = commitCommand.targetGeneration.value;
    // An audio-less generation has no consumer for the dispatcher to flush, so
    // nothing has moved its timebase onto the committed generation. Do that
    // here, at the same point the dispatcher's flush would have reactivated
    // NativeAudioSession, and land it paused at the exact binary64 target the
    // controller published so refreshClockForCommit() matches bit for bit.
    if (silentTimebase != nullptr && !commitTimebaseActivated) {
      if (!silentTimebase->activate(commitCommand.targetGeneration.value,
                                    commitCommand.targetSeconds)) {
        static_cast<void>(publishFailure(protocol::FailureReason::CommitSeek,
                                         commitCommand.stamp));
        return;
      }
      commitTimebaseActivated = true;
    }
    // Dispatcher seek flushes NativeAudioSession and leaves the target
    // generation activated but Ready (output stopped). Start must therefore
    // follow SeekCommitted for every commit, not only replay from Ended.
    if (!commitAudioStarted) {
      if (!beginLiveIssue(nullptr, false, true)) {
        acceptPublishedCommands();
        return;
      }
      const NativeAudioSessionProgress started =
          audioControl.start(audioControl.context);
      endLiveIssue();
      if (stopPublished()) {
        acceptPublishedCommands();
        return;
      }
      if (started == NativeAudioSessionProgress::Quiescing ||
          started == NativeAudioSessionProgress::WaitingForData) {
        return;
      }
      if (started != NativeAudioSessionProgress::Done) {
        static_cast<void>(publishFailure(protocol::FailureReason::CommitSeek,
                                         commitCommand.stamp));
        return;
      }
      {
        std::lock_guard lock(mutex);
        if (publishedStop.has_value()) {
          return;
        }
        startedPublished = true;
        publicStarted = true;
        publicStartAccepted = true;
        publishedStart.reset();
        startPending = false;
        startedDrawBaseline = commitDrawBaseline;
        commitAudioStarted = true;
      }
    }
    // Reassert the target-generation pause after Start. NativeAudioSession
    // starts with the flush-retained paused intent; this call makes that clock
    // state an explicit completed child mutation before readiness proofs.
    if (!commitTargetPaused) {
      if (!beginLiveIssue(nullptr, false, true)) {
        acceptPublishedCommands();
        return;
      }
      const NativeAudioSessionProgress paused =
          audioControl.setPaused(audioControl.context, true);
      endLiveIssue();
      if (stopPublished()) {
        acceptPublishedCommands();
        return;
      }
      if (paused == NativeAudioSessionProgress::Quiescing ||
          paused == NativeAudioSessionProgress::WaitingForData) {
        return;
      }
      if (paused != NativeAudioSessionProgress::Done) {
        static_cast<void>(publishFailure(protocol::FailureReason::CommitSeek,
                                         commitCommand.stamp));
        return;
      }
      commitTargetPaused = true;
    }
    refreshClockForCommit();
    captureCommitProofs();
    if (!commitVideoProof.has_value()) {
      if (!beginLiveIssue(nullptr, false, true)) {
        acceptPublishedCommands();
        return;
      }
      // The audio route is now paused at the target with a primed ring and
      // only this loop's video draw can release it, so a full audio buffer can
      // no longer mean "the pipeline is ahead". Name the window for the
      // dispatcher: audio backpressure must stop closing the merged read while
      // the video decoder still needs access units to emit the covering frame.
      dispatcher->setSeekSettleReadAhead(true);
      const media::NativeMediaDispatcherStep step = dispatcher->step();
      endLiveIssue();
      publishVideoDueHint();
      if (stopPublished()) {
        acceptPublishedCommands();
        return;
      }
      if (step.state == media::NativeMediaDispatcherState::Failed ||
          step.action == media::NativeMediaDispatcherAction::Failed) {
        static_cast<void>(publishFailure(protocol::FailureReason::CommitSeek,
                                         commitCommand.stamp));
        return;
      }
      captureCommitProofs();
      if (!commitVideoProof.has_value() &&
          step.wait == media::NativeMediaDispatcherWait::CallAgain) {
        dependencies.wake->notify();
      }
    }
    if (commitAudioProof.has_value() && commitVideoProof.has_value() &&
        publishCommitReady(commitCommand, commitDrawBaseline,
                           *commitAudioProof, *commitVideoProof)) {
      commitPending = false;
      commitAudioStarted = false;
      commitSourcePaused = false;
      commitTargetPaused = false;
      commitTimebaseActivated = false;
      commitIssued = false;
      commitCommitted = false;
      commitAudioProof.reset();
      commitVideoProof.reset();
    }
  }

  void refreshClockForCommit() noexcept {
    if (!commitCommitted || commitAudioProof.has_value()) {
      return;
    }
    if (!beginLiveIssue(nullptr, false, true)) {
      return;
    }
    const NativeMediaClockSnapshot clock =
        audioControl.clock(audioControl.context);
    endLiveIssue();
    const protocol::AudioClockProof proof{
        commitCommand.stamp, commitCommand.targetGeneration,
        protocol::AudioClockAnchorId{clock.publicationSerial},
        clock.mediaSeconds, true, clock.rate};
    if (clock.publicationCurrent && clock.valid && !clock.running &&
        clock.generation == commitCommand.targetGeneration.value &&
        clock.mediaSeconds == commitCommand.targetSeconds &&
        protocol::valid(proof)) {
      childLifetime->clock->snapshot = clock;
      commitAudioProof = proof;
    }
  }

  void captureCommitProofs() noexcept {
    if (!commitCommitted || commitVideoProof.has_value() ||
        videoControl.takeOutputEvent == nullptr) {
      return;
    }
    if (!beginLiveIssue(nullptr, false, true)) {
      return;
    }
    const std::optional<NativeTrackedVideoEvent> event =
        videoControl.takeOutputEvent(videoControl.context);
    endLiveIssue();
    if (!event.has_value() ||
        event->kind != NativeTrackedVideoEventKind::FrameDrawn ||
        event->eventSequence == 0 ||
        event->eventSequence <= commitDrawBaseline ||
        event->generation != commitCommand.targetGeneration.value ||
        event->timing.generation != commitCommand.targetGeneration.value) {
      return;
    }
    const auto presentation = exactFrameTime(event->timing.presentationTime);
    const auto duration = exactFrameTime(event->timing.duration);
    if (!presentation.has_value() || !duration.has_value()) {
      return;
    }
    const auto presentationSeconds = media::mediaTimeSeconds(*presentation);
    const auto durationSeconds = media::mediaTimeSeconds(*duration);
    if (!presentationSeconds.has_value() || !durationSeconds.has_value()) {
      return;
    }
    const protocol::VideoDrawProof proof{
        commitCommand.stamp, commitCommand.targetGeneration,
        event->eventSequence, *presentationSeconds, *durationSeconds};
    if (!protocol::valid(proof) ||
        !protocol::frameCoversPosition(proof, commitCommand.targetSeconds)) {
      return;
    }
    {
      std::lock_guard lock(mutex);
      publicLastOutputEventSequence =
          std::max(publicLastOutputEventSequence, event->eventSequence);
    }
    lastVideoDrawProofSequence = event->eventSequence;
    commitVideoProof = proof;
  }

  void captureVideoDrawProof() noexcept {
    if (stopLatched || endingLatched || endedPublished || liveFailed ||
        videoControl.takeOutputEvent == nullptr) {
      return;
    }
    if (!retainedVideoEvent.has_value()) {
      if (!beginLiveIssue()) {
        return;
      }
      retainedVideoEvent =
          videoControl.takeOutputEvent(videoControl.context);
      endLiveIssue();
    }
    const std::optional<NativeTrackedVideoEvent>& event = retainedVideoEvent;
    if (!event.has_value() ||
        event->eventSequence == 0) {
      return;
    }
    if (event->kind != NativeTrackedVideoEventKind::FrameDrawn ||
        event->eventSequence <= startedDrawBaseline ||
        event->eventSequence <= lastVideoDrawProofSequence ||
        event->generation != activeGeneration) {
      retainedVideoEvent.reset();
      return;
    }
    {
      std::lock_guard lock(mutex);
      if (!startedPublished || !protocol::validLive(appliedRunStamp) ||
          requestedRunStamp != appliedRunStamp ||
          publicRequestedRunStamp != appliedRunStamp ||
          publishedStop.has_value() || publicEnding || publicEnded) {
        return;
      }
    }
    const auto presentation = exactFrameTime(event->timing.presentationTime);
    const auto duration = exactFrameTime(event->timing.duration);
    if (!presentation.has_value() || !duration.has_value() ||
        event->timing.generation != activeGeneration) {
      retainedVideoEvent.reset();
      return;
    }
    const auto presentationSeconds = media::mediaTimeSeconds(*presentation);
    const auto durationSeconds = media::mediaTimeSeconds(*duration);
    if (!presentationSeconds.has_value() || !durationSeconds.has_value()) {
      retainedVideoEvent.reset();
      return;
    }
    const protocol::VideoDrawProof proof{
        appliedRunStamp,
        protocol::Generation{activeGeneration},
        event->eventSequence,
        *presentationSeconds,
        *durationSeconds};
    if (!protocol::valid(proof)) {
      retainedVideoEvent.reset();
      return;
    }
    lastVideoDrawProofSequence = event->eventSequence;
    {
      std::lock_guard lock(mutex);
      publicLastOutputEventSequence =
          std::max(publicLastOutputEventSequence, event->eventSequence);
    }
    retainedVideoEvent.reset();
    publishVideoDraw(proof);
  }

  [[nodiscard]] bool publishEnded(double finalPositionSeconds) noexcept {
    {
      std::lock_guard lock(mutex);
      if (publishedStop.has_value() || liveFailed || endedPublished ||
          !protocol::validPosition(finalPositionSeconds)) {
        return false;
      }
      if (factMailbox.has_value()) {
        return false;
      }
      endedPublished = true;
      publicEnding = true;
      publicEnded = true;
      runStateAppliedSlot.reset();
      audioClockSlot.reset();
      videoDrawSlot.reset();
      factMailbox.emplace(protocol::Ended{
          endingStamp, protocol::Generation{activeGeneration},
          finalPositionSeconds});
    }
    queueObservations();
    return true;
  }

  // Exhaustion closes live admission before any further proof capture. The
  // stamp remains mutex-owned so a late SetRunState accepted while audio Stop
  // is quiescing can atomically replace it without racing the worker.
  [[nodiscard]] bool latchEnding() noexcept {
    std::lock_guard lock(mutex);
    if (!dispatcherExhausted || endingLatched || endedPublished ||
        liveFailed || publishedStop.has_value() || publicCommitPending ||
        commitRunStatePending || !startedPublished ||
        !protocol::validLive(latestAcceptedStamp)) {
      return endingLatched;
    }
    endingStamp = latestAcceptedStamp;
    endingLatched = true;
    publicEnding = true;
    dependencies.wake->publishVideoDueHostTicks(0);
    publishedRun.reset();
    publishedGain.reset();
    publishedMuted.reset();
    runPending = false;
    gainPending = false;
    mutedPending = false;
    audioProofPending.reset();
    retainedVideoEvent.reset();
    runStateAppliedSlot.reset();
    audioClockSlot.reset();
    videoDrawSlot.reset();
    return true;
  }

  void progressEnded() noexcept {
    if (!dispatcherExhausted || endedPublished || liveFailed || stopLatched ||
        !startedPublished || audioControl.stop == nullptr ||
        audioControl.clock == nullptr) {
      return;
    }
    if (!endingLatched && !latchEnding()) {
      return;
    }
    if (!beginLiveIssue(nullptr, true)) {
      return;
    }
    const NativeAudioSessionProgress stopped =
        audioControl.stop(audioControl.context);
    endLiveIssue();
    if (stopPublished()) {
      acceptPublishedCommands();
      return;
    }
    if (stopped == NativeAudioSessionProgress::Quiescing ||
        stopped == NativeAudioSessionProgress::WaitingForData) {
      return;
    }
    if (stopped != NativeAudioSessionProgress::Done) {
      static_cast<void>(publishFailure(protocol::FailureReason::AudioOutput));
      return;
    }
    if (!beginLiveIssue(nullptr, true)) {
      return;
    }
    const NativeMediaClockSnapshot clock =
        audioControl.clock(audioControl.context);
    endLiveIssue();
    if (stopPublished()) {
      acceptPublishedCommands();
      return;
    }
    if (!clock.publicationCurrent || !clock.valid || clock.running ||
        clock.generation != activeGeneration ||
        protocol::routeForRate(clock.rate) !=
            protocol::RateRoute::NativeVersion1 ||
        !protocol::validPosition(clock.mediaSeconds)) {
      static_cast<void>(publishFailure(protocol::FailureReason::Clock));
      return;
    }
    static_cast<void>(publishEnded(clock.mediaSeconds));
  }

  // Out-of-band diagnostic publication. Runs only after a metrics() caller has
  // armed it, so a build with no metrics stream attached pays exactly one
  // relaxed atomic load per worker pass and never samples a child at all.
  //
  // Every counter it publishes is worker-confined at its source: the video
  // consumer's facts() is owner-serialized and the cached clock snapshot is
  // plain memory that refreshClock() writes. Sampling them here and storing
  // relaxed atomics is what lets a GUI sampler read them without a data race.
  // The individual slots are not published as one transaction; a reader can
  // observe a video counter from this pass beside an audio counter from the
  // previous one. That is deliberate and harmless for a rate metric whose
  // window is orders of magnitude longer than a worker pass.
  void publishMetrics() noexcept {
    if (!metricsArmed.load(std::memory_order_relaxed)) {
      return;
    }
    NativeMediaSessionMetrics sampled;
    if (videoControl.metrics != nullptr && videoControl.context != nullptr &&
        videoControl.metrics(videoControl.context, &sampled)) {
      metricsDrawnFrames.store(sampled.drawnFrames, std::memory_order_relaxed);
      metricsSubmittedFrames.store(sampled.submittedFrames,
                                   std::memory_order_relaxed);
      metricsSupersededFrames.store(sampled.supersededFrames,
                                    std::memory_order_relaxed);
      metricsDiscardedLateFrames.store(sampled.discardedLateFrames,
                                       std::memory_order_relaxed);
      metricsVideoValid.store(true, std::memory_order_relaxed);
    }
    if (audioControl.metrics != nullptr && audioControl.context != nullptr &&
        audioControl.metrics(audioControl.context, &sampled)) {
      metricsAudioUnderrunCallbacks.store(sampled.audioUnderrunCallbacks,
                                          std::memory_order_relaxed);
      metricsAudioClockAdvancedUnderruns.store(
          sampled.audioClockAdvancedUnderruns, std::memory_order_relaxed);
      metricsAudioRetiredLateFrames.store(sampled.audioRetiredLateFrames,
                                          std::memory_order_relaxed);
      metricsAudioCallbacks.store(sampled.audioCallbacks,
                                  std::memory_order_relaxed);
      metricsAudioRenderedFrames.store(sampled.audioRenderedFrames,
                                       std::memory_order_relaxed);
      metricsAudioValid.store(true, std::memory_order_relaxed);
    }
    // The cached snapshot is the same value the video consumer schedules
    // against, so it needs no second live clock sample and no live-issue
    // permit. refreshClock() only replaces it with a publicationCurrent
    // sample, so a stale value here is always a real earlier observation.
    const NativeMediaClockSnapshot clock = childLifetime->clock->snapshot;
    if (clock.valid) {
      std::uint64_t mediaSecondsBits = 0;
      std::uint64_t rateBits = 0;
      static_assert(sizeof(mediaSecondsBits) == sizeof(clock.mediaSeconds));
      std::memcpy(&mediaSecondsBits, &clock.mediaSeconds,
                  sizeof(mediaSecondsBits));
      std::memcpy(&rateBits, &clock.rate, sizeof(rateBits));
      metricsMediaSecondsBits.store(mediaSecondsBits,
                                    std::memory_order_relaxed);
      metricsClockRateBits.store(rateBits, std::memory_order_relaxed);
      metricsClockValid.store(true, std::memory_order_relaxed);
    }
  }

  void refreshClock() noexcept {
    if (audioControl.clock != nullptr && dispatcherObservedVideo) {
      if (!beginLiveIssue()) {
        return;
      }
      const NativeMediaClockSnapshot sampled =
          audioControl.clock(audioControl.context);
      endLiveIssue();
      if (stopPublished()) {
        return;
      }
      if (sampled.publicationCurrent) {
        childLifetime->clock->snapshot = sampled;
      }
    }
  }

#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
  struct WorkerAutoreleasePoolProbe final {
    explicit WorkerAutoreleasePoolProbe(Impl* owner) noexcept : owner(owner) {
      owner->workerAutoreleasePoolsEntered.fetch_add(1,
                                                     std::memory_order_acq_rel);
      const std::uint64_t active =
          owner->workerAutoreleasePoolsActive.fetch_add(
              1, std::memory_order_acq_rel) +
          1;
      std::uint64_t peak =
          owner->workerAutoreleasePoolsPeak.load(std::memory_order_acquire);
      while (peak < active &&
             !owner->workerAutoreleasePoolsPeak.compare_exchange_weak(
                 peak, active, std::memory_order_acq_rel,
                 std::memory_order_acquire)) {
      }
    }

    ~WorkerAutoreleasePoolProbe() {
      owner->workerAutoreleasePoolsActive.fetch_sub(1,
                                                    std::memory_order_acq_rel);
      owner->workerAutoreleasePoolsDrained.fetch_add(1,
                                                     std::memory_order_release);
    }

    Impl* owner;
  };
#endif

  // Arms the audio-less heartbeat only for the states that actually need a
  // periodic edge, so a silent generation that is paused, ended, stopped or
  // failed sleeps exactly as an audio-authoritative one does once its output
  // unit has stopped. Evaluated on the worker immediately before it blocks,
  // so it always describes the state the previous pass left behind.
  void syncHostPacedDeadlines() noexcept {
    if (silentTimebase == nullptr) {
      return;
    }
    const bool active = !endedPublished && !stopLatched && !liveFailed &&
                        !endingLatched &&
                        (commitPending || previewPending || !appliedPaused);
    dependencies.wake->setHostPacedDeadlines(
        active ? dependencies.hostClock : NativeMediaHostClock{});
  }

  void work() noexcept {
    while (true) {
      syncHostPacedDeadlines();
      dependencies.wake->wait();
      // std::thread has no run-loop-owned autorelease boundary. Establish one
      // only after a wake is consumed and drain it before the worker blocks
      // again, bounding Foundation/AVFoundation temporaries to one pass.
      @autoreleasepool {
#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
        WorkerAutoreleasePoolProbe workerAutoreleasePoolProbe{this};
#endif
        {
          std::lock_guard lock(mutex);
          if (exitRequested) {
            break;
          }
        }
        acceptPublishedCommands();
        // A rejected GUI enqueue retains its observations. Retry once through
        // the existing event-driven wake, then again only when real session
        // work wakes this worker; never poll or invoke the controller inline.
        queueObservations();
#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
        if (commandDrainBarrierEntered != nullptr &&
            commandDrainBarrierRelease != nullptr &&
            !commandDrainBarrierConsumed.exchange(true,
                                                  std::memory_order_acq_rel)) {
          commandDrainBarrierEntered->store(true, std::memory_order_release);
          while (!commandDrainBarrierRelease->load(std::memory_order_acquire)) {
            std::this_thread::yield();
          }
        }
#endif
        publishPendingFailure();
        if (factBlocked()) {
          continue;
        }
        if (stopLatched) {
          progressStop();
          continue;
        }
        if (liveFailed) {
          continue;
        }
        if (commitPending) {
          progressCommitSeek();
          if (stopLatched) {
            progressStop();
          }
          continue;
        }
        refreshClock();
        publishMetrics();
        if (preparePending) {
          progressPrepare();
        }
        if (stopLatched) {
          progressStop();
          continue;
        }
        if (factBlocked()) {
          continue;
        }
        if (commitPending) {
          progressCommitSeek();
          continue;
        }
        progressAudioControls();
        if (liveFailed) {
          continue;
        }
        // beginScrub publishes its physical pause immediately before the
        // identity-free handoff. Apply that pending run command first so main
        // video never relinquishes surfaces while the authoritative audio clock
        // is still advancing. A quiescing audio mutation owns the next wake.
        if (previewHandoffPending && runPending) {
          progressRunState();
          if (liveFailed || runPending) {
            continue;
          }
        }
        progressPreview();
        if (liveFailed) {
          continue;
        }
        if (dispatcher != nullptr && preparedPublished &&
            !dispatcherExhausted && !previewActivity && !previewPending) {
          bool callAgain = false;
          bool terminalFailure = false;
          for (unsigned stepCount = 0; stepCount != 32; ++stepCount) {
            if (!beginLiveIssue()) {
              acceptPublishedCommands();
              break;
            }
            dispatcher->setSeekSettleReadAhead(false);
            const auto step = dispatcher->step();
            endLiveIssue();
            if (stopPublished()) {
              acceptPublishedCommands();
              break;
            }
            if (step.state == media::NativeMediaDispatcherState::Failed ||
                step.action == media::NativeMediaDispatcherAction::Failed) {
              terminalFailure = true;
              break;
            }
            if (step.state == media::NativeMediaDispatcherState::Exhausted ||
                step.action == media::NativeMediaDispatcherAction::Exhausted) {
              dispatcherExhausted = true;
              static_cast<void>(latchEnding());
              callAgain = false;
              break;
            }
            captureVideoDrawProof();
            callAgain =
                step.wait == media::NativeMediaDispatcherWait::CallAgain;
            if (!callAgain) {
              break;
            }
          }
          if (callAgain) {
            dependencies.wake->notify();
          }
          if (terminalFailure && !dispatcherFailurePublished) {
            dispatcherFailurePublished = true;
#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
            if (failureDetectionEntered != nullptr &&
                failureDetectionRelease != nullptr) {
              failureDetectionEntered->store(true, std::memory_order_release);
              while (
                  !failureDetectionRelease->load(std::memory_order_acquire)) {
                std::this_thread::yield();
              }
            }
#endif
            // Admission, stamp capture and the public terminal latch are one
            // mutex transaction inside publishFailure().
            logNativeFailure("steady", protocol::FailureReason::Decode,
                             dispatcher.get());
            static_cast<void>(publishFailure(protocol::FailureReason::Decode));
            continue;
          }
        }
        if (liveFailed) {
          continue;
        }
        publishVideoDueHint();
        progressStart();
        if (factBlocked()) {
          continue;
        }
        if (dispatcherExhausted) {
          static_cast<void>(latchEnding());
        }
        progressRunState();
        progressAudioClockProof();
        captureVideoDrawProof();
        progressEnded();
        progressAudioSuspend();
      }
    }
  }

  NativeMediaSessionSourceBinding binding;
  NativeMediaSessionDependencies dependencies;
  std::shared_ptr<NativeMediaSessionChildLifetime> childLifetime;
  std::shared_ptr<NativeMediaSessionCancellation> cancellation;
  mutable std::mutex mutex;
  std::thread worker;
  std::optional<NativeMediaSessionFact> factMailbox;
  std::optional<protocol::Failed> pendingFailure;
  std::optional<NativeMediaSessionRunStateApplied> runStateAppliedSlot;
  std::optional<protocol::AudioClockProof> audioClockSlot;
  std::optional<protocol::VideoDrawProof> videoDrawSlot;
  std::optional<protocol::PreviewPresented> previewPresentedSlot;
  std::optional<protocol::PreviewFailed> previewFailedSlot;
  std::optional<protocol::CommitReady> commitReadySlot;
  NativeMediaSessionObservationEdge observationEdge{};
  bool observationQueued{false};
  bool observationRetryWakeUsed{false};
  std::uint64_t nextObservationQueueSerial{0};
  std::uint64_t queuedObservationQueueSerial{0};
  struct PublishedPrepare {
    protocol::Prepare command{};
    media::MediaTime initialPosition{};
  };
  struct PublishedCommit {
    protocol::CommitSeek command{};
    media::MediaTime target{};
    std::uint64_t drawBaseline{0};
    bool reviveFromEnded{false};
  };
  struct PublishedPreview {
    protocol::PreviewFrame command{};
    NativePreviewFrameTarget target;
    protocol::Stamp acceptedThrough{};
  };
  std::optional<PublishedPrepare> publishedPrepare;
  std::optional<protocol::Start> publishedStart;
  std::optional<protocol::SetRunState> publishedRun;
  std::optional<PublishedCommit> publishedCommit;
  std::optional<protocol::Stamp> publishedPreviewHandoff;
  std::optional<PublishedPreview> publishedPreview;
  std::optional<protocol::PreviewFrame> latestPreview;
  std::optional<float> publishedGain;
  std::optional<bool> publishedMuted;
  std::optional<protocol::Stop> publishedStop;
  protocol::Stamp latestAcceptedStamp{};
  MediaGeneration publicActiveGeneration{0};
  MediaGeneration generationHighWater{0};
  std::uint64_t publicLastOutputEventSequence{0};
  double publicDurationSeconds{0.0};
  media::NativeMediaDispatcher* dispatcherObserver{nullptr};
  NativeMediaSessionOwnershipPhase publicOwnership{
      NativeMediaSessionOwnershipPhase::Empty};
  protocol::Stamp publicRequestedRunStamp{};
  protocol::Stamp publicIssuedRunStamp{};
  protocol::Stamp publicAppliedRunStamp{};
  bool publicPrepared{false};
  bool publicStarted{false};
  bool publicDispatcherObservedVideo{false};
  bool publicDirectVideoRetired{false};
  bool publicDirectAudioRetired{false};
  bool publicStopped{false};
  bool publicEnding{false};
  bool publicEnded{false};
  bool publicLiveFailed{false};
  bool publicCommitPending{false};
  // A CommitReady has been published and the promoted generation's
  // authoritative SetRunState has not arrived yet. The commit protocol
  // guarantees that command -- the Router issues it synchronously from
  // onNativeCommitReady -- and setRunState() already refuses a run command
  // that arrives before the CommitReady is taken, so the handshake is not
  // complete when publicCommitPending clears; it is complete when the run
  // command lands. Ending must not latch inside that window: it would capture
  // the CommitSeek stamp as endingStamp while the Router has already reserved
  // a newer serial for the run command, so the Ended fact would be dropped by
  // endedMatches, and the run command itself would be refused with Ignored and
  // retire the whole native route.
  bool commitRunStatePending{false};
  bool publicPreviewHandoffPending{false};
  bool publicPreviewHandoffReady{false};
  bool publicPreviewHandoffFailed{false};
  bool publicPreviewPending{false};
  bool publicAppliedPaused{true};
  bool publicStartAccepted{false};
  std::unique_ptr<media::MediaSource> sourceOwned;
  std::unique_ptr<media::NativeVideoConsumer> videoOwned;
  std::unique_ptr<media::NativeAudioConsumer> audioOwned;
  std::unique_ptr<media::NativeMediaDispatcher> dispatcher;
  std::unique_ptr<NativePreviewFrameLane> previewLane;
  // Valid from graph construction through dispatcher destruction only.
  media::NativeVideoConsumer* videoObserver{nullptr};
  media::NativeAudioConsumer* audioObserver{nullptr};
  std::shared_ptr<const media::MediaSourceDescriptor> descriptorSnapshot;
  // Neutral backend identity. Native v1 admits more than one demux backend
  // (AVFoundation and Matroska), so the session holds the contract's prepared
  // context rather than one backend's concrete asset context. The preview lane
  // is still AVFoundation-only and recovers its concrete type by cast below.
  std::shared_ptr<const media::MediaSourcePreparedContext> assetContextSnapshot;
#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
  bool (*previewBindingObserver)(
      void*, const NativePreviewBinding&) noexcept{nullptr};
  void* previewBindingObserverContext{nullptr};
#endif
  SessionVideoControl videoControl{};
  // Transport and clock authority for the active generation. For an ordinary
  // A/V generation this addresses the NativeAudioSession below; for an
  // audio-less one progressPrepare rebinds it to silentTimebase, which
  // publishes the same proofs from the host clock. Nothing else about the
  // Start / SetRunState / CommitSeek / Ended chains changes.
  SessionAudioControl audioControl{};
  // The unswapped binding to the audio *consumer*. Retirement must pair
  // audioObserver->retire() with that consumer's own highest exposed
  // generation, never with a timebase generation, so this copy is captured at
  // graph construction and is never rebound.
  SessionAudioControl audioConsumerControl{};
  // Present only while the active generation has no selected audio track.
  std::unique_ptr<NativeSilentTimebase> silentTimebase;
  SessionPreviewControl previewControl{};
  // Names this session's counter epoch. Assigned once at construction and
  // immutable thereafter, so metrics() may read it from any thread without
  // synchronisation, and it is the only metrics field already valid before the
  // worker has published anything.
  const std::uint64_t sessionEpoch{allocateSessionEpoch()};
  // Out-of-band diagnostic publication slots. The worker is the only writer;
  // metrics() is the only reader and may run on any thread. These deliberately
  // sit outside `mutex` so an idle metrics sampler never contends with command
  // admission, and outside the worker's unsynchronised owner fields so no
  // existing single-threaded invariant is weakened. metricsArmed is written
  // only by metrics(); until it is set the worker skips publishMetrics()
  // entirely, which is what keeps a metrics-free run bit-for-bit unchanged.
  std::atomic<bool> metricsArmed{false};
  std::atomic<bool> metricsVideoValid{false};
  std::atomic<bool> metricsAudioValid{false};
  std::atomic<bool> metricsClockValid{false};
  std::atomic<std::uint64_t> metricsDrawnFrames{0};
  std::atomic<std::uint64_t> metricsSubmittedFrames{0};
  std::atomic<std::uint64_t> metricsSupersededFrames{0};
  std::atomic<std::uint64_t> metricsDiscardedLateFrames{0};
  std::atomic<std::uint64_t> metricsAudioUnderrunCallbacks{0};
  std::atomic<std::uint64_t> metricsAudioClockAdvancedUnderruns{0};
  std::atomic<std::uint64_t> metricsAudioRetiredLateFrames{0};
  std::atomic<std::uint64_t> metricsAudioCallbacks{0};
  std::atomic<std::uint64_t> metricsAudioRenderedFrames{0};
  std::atomic<std::uint64_t> metricsMediaSecondsBits{0};
  std::atomic<std::uint64_t> metricsClockRateBits{0};
  protocol::Prepare prepareCommand{};
  protocol::Start startCommand{};
  protocol::SetRunState runCommand{};
  protocol::CommitSeek commitCommand{};
  protocol::PreviewFrame previewCommand{};
  protocol::Stop stopCommand{};
  media::MediaTime initialPosition{};
  media::MediaTime commitTarget{};
  std::optional<NativePreviewFrameTarget> previewTarget;
  MediaGeneration reservedGeneration{0};
  MediaGeneration activeGeneration{0};
  NativeMediaSessionOwnershipPhase ownership{
      NativeMediaSessionOwnershipPhase::Empty};
  bool preparePending{false};
  bool prepareFailed{false};
  bool preparedPublished{false};
  bool startPending{false};
  bool startedPublished{false};
  bool runPending{false};
  bool commitPending{false};
  bool commitAudioStarted{false};
  bool commitSourcePaused{false};
  bool commitTargetPaused{false};
  // Audio-less only: the silent timebase's quiescent transition onto the
  // target generation, performed once per commit between SeekCommitted and
  // the transport start.
  bool commitTimebaseActivated{false};
  bool commitIssued{false};
  bool commitCommitted{false};
  bool previewHandoffPending{false};
  bool previewHandoffReady{false};
  bool previewHandoffFailed{false};
  bool previewPending{false};
  bool previewIssued{false};
  bool previewActivity{false};
  bool previewMainQuiesced{false};
  bool gainPending{false};
  bool mutedPending{false};
  bool stopLatched{false};
  bool stopFailed{false};
  bool stopFailurePublished{false};
  bool dispatcherFailurePublished{false};
  bool liveFailed{false};
  bool stoppedPublished{false};
  bool endingLatched{false};
  bool endedPublished{false};
  bool dispatcherExhausted{false};
  bool dispatcherObservedVideo{false};
  bool directVideoRetired{false};
  bool directAudioRetired{false};
  // NativeMediaConsumer::retire() is an exact operation: the first accepted
  // (retiredGeneration, invalidationGeneration) pair owns the retirement and
  // only that pair may be retried. The very first pass installs the
  // invalidation generation into the decoder, the frame sink and the tracked
  // output, so the port's "highest exposed" generation legitimately advances
  // while the operation is still Quiescing. Recomputing the retired half on
  // every pass would therefore hand the port a different pair and be rejected
  // as StaleGeneration. Latch each half once and replay it verbatim.
  MediaGeneration directVideoRetiredGeneration{0};
  MediaGeneration directAudioRetiredGeneration{0};
  protocol::Stamp requestedRunStamp{};
  protocol::Stamp issuedRunStamp{};
  protocol::Stamp appliedRunStamp{};
  protocol::Stamp endingStamp{};
  std::optional<protocol::SetRunState> audioProofPending;
  std::optional<protocol::AudioClockProof> commitAudioProof;
  std::optional<protocol::VideoDrawProof> commitVideoProof;
  std::optional<NativeTrackedVideoEvent> retainedVideoEvent;
  std::uint64_t startedDrawBaseline{0};
  std::uint64_t commitDrawBaseline{0};
  std::uint64_t lastVideoDrawProofSequence{0};
  float requestedGain{1.0F};
  bool requestedMuted{false};
  bool appliedPaused{true};
  protocol::Stamp previewLaneAcceptedThrough{};
  bool liveIssueActive{false};
  bool exitRequested{false};
#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
  NativeMediaSessionTestGraphFactory testFactory{nullptr};
  void* testFactoryContext{nullptr};
  std::atomic<bool>* failureLatchEntered{nullptr};
  std::atomic<bool>* failureLatchRelease{nullptr};
  std::atomic<bool>* failureDetectionEntered{nullptr};
  std::atomic<bool>* failureDetectionRelease{nullptr};
  std::atomic<bool>* liveIssueBarrierEntered{nullptr};
  std::atomic<bool>* liveIssueBarrierRelease{nullptr};
  std::atomic<bool> liveIssueBarrierConsumed{false};
  std::atomic<bool>* commandDrainBarrierEntered{nullptr};
  std::atomic<bool>* commandDrainBarrierRelease{nullptr};
  std::atomic<bool> commandDrainBarrierConsumed{false};
  std::atomic<std::atomic<bool>*> previewPullBarrierEntered{nullptr};
  std::atomic<std::atomic<bool>*> previewPullBarrierRelease{nullptr};
  std::atomic<bool> previewPullBarrierConsumed{false};
  std::atomic<std::atomic<bool>*> previewConstructionBarrierEntered{nullptr};
  std::atomic<std::atomic<bool>*> previewConstructionBarrierRelease{nullptr};
  std::atomic<bool> previewConstructionBarrierConsumed{false};
  std::atomic<NativeMediaSessionTestPreviewCompletionPoint>
      previewCompletionBarrierPoint{
          NativeMediaSessionTestPreviewCompletionPoint::None};
  std::atomic<std::atomic<bool>*> previewCompletionBarrierEntered{nullptr};
  std::atomic<std::atomic<bool>*> previewCompletionBarrierRelease{nullptr};
  std::atomic<bool> previewCompletionBarrierConsumed{false};
  std::atomic<std::uint64_t> workerAutoreleasePoolsEntered{0};
  std::atomic<std::uint64_t> workerAutoreleasePoolsDrained{0};
  std::atomic<std::uint64_t> workerAutoreleasePoolsActive{0};
  std::atomic<std::uint64_t> workerAutoreleasePoolsPeak{0};
#endif
};

NativeMediaSession::NativeMediaSession(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

std::unique_ptr<NativeMediaSession> NativeMediaSession::create(
    NativeMediaSessionSourceBinding binding,
    NativeMediaSessionDependencies dependencies) noexcept {
  if (!validLocalBinding(binding) || dependencies.externalLifetime == nullptr ||
      dependencies.wake == nullptr || dependencies.videoOutput == nullptr ||
      dependencies.previewOutput == nullptr ||
      dependencies.hostClock.readTicks == nullptr ||
      dependencies.hostClock.ticksPerSecond == 0) {
    return {};
  }
  try {
    auto impl = std::make_unique<Impl>(std::move(binding),
                                      std::move(dependencies));
    auto result = std::unique_ptr<NativeMediaSession>(
        new NativeMediaSession(std::move(impl)));
    result->impl_->worker =
        std::thread([owner = result->impl_.get()] { owner->work(); });
    return result;
  } catch (...) {
    return {};
  }
}

NativeMediaSession::~NativeMediaSession() = default;

std::optional<NativeMediaSessionInitialPosition>
NativeMediaSession::preflightInitialPosition(double seconds) noexcept {
  const auto exact = media::exactNonnegativeMediaTime(seconds);
  if (!exact.has_value()) {
    return std::nullopt;
  }
  return NativeMediaSessionInitialPosition{seconds, *exact};
}

std::optional<NativeMediaSessionCommitTarget>
NativeMediaSession::preflightCommitTarget(double seconds) noexcept {
  const auto exact = media::exactNonnegativeMediaTime(seconds);
  if (impl_ == nullptr || !exact.has_value()) {
    return std::nullopt;
  }
  std::lock_guard lock(impl_->mutex);
  if (impl_->exitRequested || impl_->publishedStop.has_value() ||
      impl_->publicLiveFailed ||
      (impl_->publicEnding && !impl_->publicEnded) ||
      !impl_->publicPrepared ||
      impl_->publicCommitPending || impl_->commitReadySlot.has_value() ||
      impl_->publicActiveGeneration == 0 ||
      impl_->publicLastOutputEventSequence ==
          std::numeric_limits<std::uint64_t>::max() ||
      !(seconds < impl_->publicDurationSeconds)) {
    return std::nullopt;
  }
  return NativeMediaSessionCommitTarget{
      seconds, *exact, impl_->publicLastOutputEventSequence,
      impl_->publicActiveGeneration};
}

std::optional<NativePreviewFrameTarget>
NativeMediaSession::preflightPreviewTarget(double seconds) noexcept {
  if (impl_ == nullptr) {
    return std::nullopt;
  }
  std::optional<NativePreviewFrameTarget> target =
      NativePreviewFrameLane::preflightTarget(seconds);
  if (!target.has_value()) {
    return std::nullopt;
  }
  std::lock_guard lock(impl_->mutex);
  if (impl_->exitRequested || impl_->publishedStop.has_value() ||
      impl_->publicLiveFailed ||
      (impl_->publicEnding && !impl_->publicEnded) ||
      impl_->publicCommitPending || impl_->publicPreviewHandoffFailed ||
      !impl_->publicPrepared ||
      impl_->publicActiveGeneration == 0 ||
      !(seconds < impl_->publicDurationSeconds)) {
    return std::nullopt;
  }
  return target;
}

bool NativeMediaSession::bindObservationEdge(
    NativeMediaSessionObservationEdge edge) noexcept {
  if (impl_ == nullptr || edge.lifetime == nullptr || edge.queue == nullptr) {
    return false;
  }
  std::lock_guard lock(impl_->mutex);
  if (impl_->exitRequested || impl_->publishedPrepare.has_value() ||
      impl_->observationEdge.lifetime != nullptr ||
      impl_->observationEdge.queue != nullptr) {
    return false;
  }
  impl_->observationEdge = std::move(edge);
  return true;
}

NativeMediaSessionCommandStatus NativeMediaSession::prepare(
    protocol::Prepare command,
    NativeMediaSessionInitialPosition initialPositionToken) noexcept {
  if (impl_ == nullptr || !protocol::valid(command) ||
      command.sourceKey != impl_->binding.sourceKey) {
    return NativeMediaSessionCommandStatus::Invalid;
  }
  if (command.initialPositionSeconds != initialPositionToken.seconds() ||
      !initialPositionToken.exact().valid() ||
      initialPositionToken.exact().value < 0) {
    return NativeMediaSessionCommandStatus::Invalid;
  }
  {
    std::lock_guard lock(impl_->mutex);
    if (impl_->exitRequested) {
      return NativeMediaSessionCommandStatus::Closed;
    }
    if (impl_->observationEdge.lifetime == nullptr ||
        impl_->observationEdge.queue == nullptr) {
      return NativeMediaSessionCommandStatus::Invalid;
    }
    if (impl_->publishedStop.has_value()) {
      return NativeMediaSessionCommandStatus::Ignored;
    }
    if (impl_->publicLiveFailed || impl_->publicEnding ||
        impl_->publicEnded) {
      return NativeMediaSessionCommandStatus::Ignored;
    }
    if (impl_->publishedPrepare.has_value()) {
      return command.stamp == impl_->publishedPrepare->command.stamp
                 ? NativeMediaSessionCommandStatus::Ignored
                 : NativeMediaSessionCommandStatus::Invalid;
    }
    impl_->publishedPrepare.emplace(
        Impl::PublishedPrepare{command, initialPositionToken.exact()});
    impl_->previewPresentedSlot.reset();
    impl_->previewFailedSlot.reset();
    impl_->publicActiveGeneration = command.reservedGeneration.value;
    impl_->generationHighWater = command.reservedGeneration.value;
    impl_->latestAcceptedStamp = command.stamp;
  }
  impl_->dependencies.wake->notify();
  return NativeMediaSessionCommandStatus::Accepted;
}

NativeMediaSessionCommandStatus NativeMediaSession::start(
    protocol::Start command) noexcept {
  if (impl_ == nullptr || !protocol::valid(command)) {
    return NativeMediaSessionCommandStatus::Invalid;
  }
  {
    std::lock_guard lock(impl_->mutex);
    if (impl_->publishedStop.has_value()) {
      return NativeMediaSessionCommandStatus::Ignored;
    }
    if (impl_->publicLiveFailed || impl_->publicEnding ||
        impl_->publicEnded) {
      return NativeMediaSessionCommandStatus::Ignored;
    }
    // A durationChanged reentrant seek may advance the Router from
    // NativeStarting to NativeSeeking before its already-created Start action
    // returns to the owner. Admit that exact older Start as a subordinate
    // physical-start request without rolling back the accepted commit stamp.
    if (impl_->publicCommitPending && impl_->publishedPrepare.has_value() &&
        command.preparedGeneration ==
            impl_->publishedPrepare->command.reservedGeneration &&
        protocol::sameAttempt(command.stamp, impl_->latestAcceptedStamp) &&
        command.stamp.serial.value < impl_->latestAcceptedStamp.serial.value) {
      if (!impl_->publicStartAccepted) {
        impl_->publicStartAccepted = true;
        if (!impl_->publicStarted) {
          impl_->publishedStart = command;
        }
      }
      return NativeMediaSessionCommandStatus::Accepted;
    }
    if (!impl_->publicPrepared || impl_->publicStartAccepted ||
        !impl_->publishedPrepare.has_value() ||
        command.preparedGeneration !=
            impl_->publishedPrepare->command.reservedGeneration ||
        !protocol::follows(impl_->latestAcceptedStamp, command.stamp)) {
      return NativeMediaSessionCommandStatus::Invalid;
    }
    impl_->publishedStart = command;
    impl_->publicStartAccepted = true;
    impl_->latestAcceptedStamp = command.stamp;
  }
  impl_->dependencies.wake->notify();
  return NativeMediaSessionCommandStatus::Accepted;
}

NativeMediaSessionCommandStatus NativeMediaSession::setRunState(
    protocol::SetRunState command) noexcept {
  if (impl_ == nullptr || !protocol::valid(command)) {
    return NativeMediaSessionCommandStatus::Invalid;
  }
  {
    std::lock_guard lock(impl_->mutex);
    if (impl_->publishedStop.has_value()) {
      return NativeMediaSessionCommandStatus::Ignored;
    }
    if (impl_->publicLiveFailed || impl_->publicEnded) {
      return NativeMediaSessionCommandStatus::Ignored;
    }
    if (impl_->publicCommitPending || impl_->commitReadySlot.has_value()) {
      return NativeMediaSessionCommandStatus::Invalid;
    }
    if (impl_->publicEnding) {
      if (!impl_->publishedPrepare.has_value() ||
          !protocol::runStateFollows(impl_->latestAcceptedStamp,
                                     protocol::Generation{
                                         impl_->publicActiveGeneration},
                                     command)) {
        return NativeMediaSessionCommandStatus::Invalid;
      }
      impl_->runStateAppliedSlot.reset();
      impl_->audioClockSlot.reset();
      impl_->videoDrawSlot.reset();
      impl_->latestAcceptedStamp = command.stamp;
      impl_->endingStamp = command.stamp;
      impl_->publicRequestedRunStamp = command.stamp;
      impl_->commitRunStatePending = false;
      return NativeMediaSessionCommandStatus::Accepted;
    }
    // A child issue that already owns the live permit linearized before this
    // request. The next intent is still accepted and will supersede its
    // completion proof; an Ended latch cannot begin until the permit closes.
    if (!impl_->publicStarted || !impl_->publishedPrepare.has_value() ||
        !protocol::runStateFollows(impl_->latestAcceptedStamp,
                                   protocol::Generation{
                                       impl_->publicActiveGeneration},
                                   command)) {
      return NativeMediaSessionCommandStatus::Invalid;
    }
    // Capacity one stores the latest same-generation intent. A newer serial
    // may replace a not-yet-consumed run command; the worker still applies at
    // most one command per wake.
    impl_->runStateAppliedSlot.reset();
    impl_->audioClockSlot.reset();
    impl_->videoDrawSlot.reset();
    impl_->observationRetryWakeUsed = false;
    impl_->publishedRun = command;
    impl_->publicRequestedRunStamp = command.stamp;
    impl_->latestAcceptedStamp = command.stamp;
    // The commit handshake is complete: endingStamp captured from here on is
    // the stamp the Router is actually waiting on.
    impl_->commitRunStatePending = false;
  }
  if (command.paused) {
    impl_->dependencies.wake->publishVideoDueHostTicks(0);
  }
  impl_->dependencies.wake->notify();
  return NativeMediaSessionCommandStatus::Accepted;
}

NativeMediaSessionCommandStatus
NativeMediaSession::preparePreviewHandoff() noexcept {
  if (impl_ == nullptr) {
    return NativeMediaSessionCommandStatus::Invalid;
  }
  {
    std::lock_guard lock(impl_->mutex);
    if (impl_->exitRequested) {
      return NativeMediaSessionCommandStatus::Closed;
    }
    if (impl_->publishedStop.has_value() || impl_->publicLiveFailed ||
        (impl_->publicEnding && !impl_->publicEnded) ||
        impl_->publicCommitPending) {
      return NativeMediaSessionCommandStatus::Ignored;
    }
    if (!impl_->publicPrepared || impl_->publicActiveGeneration == 0 ||
        !protocol::validLive(impl_->latestAcceptedStamp) ||
        impl_->publicPreviewHandoffFailed) {
      return NativeMediaSessionCommandStatus::Invalid;
    }
    if (impl_->publicPreviewHandoffPending ||
        impl_->publicPreviewHandoffReady || impl_->publicPreviewPending) {
      return NativeMediaSessionCommandStatus::Ignored;
    }
    impl_->publishedPreviewHandoff = impl_->latestAcceptedStamp;
    impl_->publicPreviewHandoffPending = true;
  }
  impl_->dependencies.wake->publishVideoDueHostTicks(0);
  impl_->dependencies.wake->notify();
  return NativeMediaSessionCommandStatus::Accepted;
}

NativeMediaSessionCommandStatus NativeMediaSession::commitSeek(
    protocol::CommitSeek command,
    NativeMediaSessionCommitTarget targetToken) noexcept {
  if (impl_ == nullptr || !protocol::valid(command) ||
      command.targetSeconds != targetToken.seconds() ||
      !targetToken.exact().valid() || targetToken.exact().value < 0) {
    return NativeMediaSessionCommandStatus::Invalid;
  }
  {
    std::lock_guard lock(impl_->mutex);
    if (impl_->exitRequested) {
      return NativeMediaSessionCommandStatus::Closed;
    }
    if (impl_->publishedStop.has_value() || impl_->publicLiveFailed ||
        (impl_->publicEnding && !impl_->publicEnded)) {
      return NativeMediaSessionCommandStatus::Ignored;
    }
    if (!impl_->publicPrepared || !impl_->publishedPrepare.has_value() ||
        impl_->publicCommitPending || impl_->commitReadySlot.has_value() ||
        command.sourceGeneration.value != targetToken.sourceGeneration_ ||
        targetToken.sourceGeneration_ != impl_->publicActiveGeneration ||
        !(impl_->latestPreview.has_value()
              ? protocol::commitFollowsLatestPreview(
                    impl_->latestAcceptedStamp,
                    protocol::Generation{impl_->publicActiveGeneration},
                    *impl_->latestPreview,
                    protocol::GenerationHighWater{impl_->generationHighWater},
                    command)
              : protocol::commitFollows(
                    impl_->latestAcceptedStamp,
                    protocol::Generation{impl_->publicActiveGeneration},
                    protocol::GenerationHighWater{impl_->generationHighWater},
                    command))) {
      return NativeMediaSessionCommandStatus::Invalid;
    }
    const bool reviveFromEnded = impl_->publicEnded;
    impl_->publishedCommit = Impl::PublishedCommit{
        command, targetToken.exact(), targetToken.drawBaseline(),
        reviveFromEnded};
    impl_->generationHighWater = command.targetGeneration.value;
    impl_->publicCommitPending = true;
    impl_->publishedPreviewHandoff.reset();
    impl_->publicPreviewHandoffPending = false;
    impl_->publicPreviewHandoffReady = false;
    impl_->publicPreviewHandoffFailed = false;
    impl_->publicPreviewPending = false;
    impl_->publishedPreview.reset();
    impl_->previewPresentedSlot.reset();
    impl_->previewFailedSlot.reset();
    impl_->latestPreview.reset();
    if (reviveFromEnded) {
      impl_->publicEnding = false;
      impl_->publicEnded = false;
    }
    impl_->runStateAppliedSlot.reset();
    impl_->audioClockSlot.reset();
    impl_->videoDrawSlot.reset();
    impl_->commitReadySlot.reset();
    // A newer commit supersedes any handshake the previous one left open.
    impl_->commitRunStatePending = false;
    impl_->observationRetryWakeUsed = false;
    impl_->latestAcceptedStamp = command.stamp;
  }
  impl_->dependencies.wake->publishVideoDueHostTicks(0);
  impl_->dependencies.wake->notify();
  return NativeMediaSessionCommandStatus::Accepted;
}

NativePreviewFrameRequestStatus NativeMediaSession::previewFrame(
    protocol::PreviewFrame command,
    NativePreviewFrameTarget target) noexcept {
  if (impl_ == nullptr || !protocol::valid(command) ||
      command.targetSeconds != target.seconds() || !target.exact().valid()) {
    return NativePreviewFrameRequestStatus::Invalid;
  }
  NativePreviewFrameRequestStatus result =
      NativePreviewFrameRequestStatus::Accepted;
  {
    std::lock_guard lock(impl_->mutex);
    if (impl_->exitRequested) {
      return NativePreviewFrameRequestStatus::Closed;
    }
    if (impl_->publishedStop.has_value() || impl_->publicLiveFailed ||
        (impl_->publicEnding && !impl_->publicEnded) ||
        impl_->publicCommitPending) {
      return NativePreviewFrameRequestStatus::Closed;
    }
    if (impl_->publicPreviewHandoffFailed) {
      return NativePreviewFrameRequestStatus::Failed;
    }
    if (!impl_->publicPrepared ||
        command.generation.value != impl_->publicActiveGeneration ||
        !(command.targetSeconds < impl_->publicDurationSeconds)) {
      return NativePreviewFrameRequestStatus::Invalid;
    }
    if (!protocol::previewFollows(
            impl_->latestAcceptedStamp,
            protocol::Generation{impl_->publicActiveGeneration}, command)) {
      return NativePreviewFrameRequestStatus::Stale;
    }
    if (impl_->latestPreview.has_value()) {
      if (!protocol::previewSupersedes(*impl_->latestPreview, command)) {
        return NativePreviewFrameRequestStatus::Stale;
      }
      result = NativePreviewFrameRequestStatus::Replaced;
    }
    impl_->publishedPreview.emplace(
        Impl::PublishedPreview{command, std::move(target),
                               impl_->latestAcceptedStamp});
    impl_->latestPreview = command;
    impl_->latestAcceptedStamp = command.stamp;
    impl_->previewPresentedSlot.reset();
    impl_->previewFailedSlot.reset();
    impl_->publicPreviewPending = true;
    impl_->observationRetryWakeUsed = false;
  }
  impl_->dependencies.wake->publishVideoDueHostTicks(0);
  impl_->dependencies.wake->notify();
  return result;
}

NativeMediaSessionCommandStatus NativeMediaSession::setGain(
    float gain) noexcept {
  if (impl_ == nullptr) {
    return NativeMediaSessionCommandStatus::Invalid;
  }
  {
    std::lock_guard lock(impl_->mutex);
    if (impl_->exitRequested) {
      return NativeMediaSessionCommandStatus::Closed;
    }
    if (impl_->publishedStop.has_value() || impl_->publicEnding ||
        impl_->publicEnded || impl_->publicLiveFailed) {
      return NativeMediaSessionCommandStatus::Ignored;
    }
    impl_->publishedGain = gain;
  }
  impl_->dependencies.wake->notify();
  return NativeMediaSessionCommandStatus::Accepted;
}

NativeMediaSessionCommandStatus NativeMediaSession::setMuted(
    bool muted) noexcept {
  if (impl_ == nullptr) {
    return NativeMediaSessionCommandStatus::Invalid;
  }
  {
    std::lock_guard lock(impl_->mutex);
    if (impl_->exitRequested) {
      return NativeMediaSessionCommandStatus::Closed;
    }
    if (impl_->publishedStop.has_value() || impl_->publicEnding ||
        impl_->publicEnded || impl_->publicLiveFailed) {
      return NativeMediaSessionCommandStatus::Ignored;
    }
    impl_->publishedMuted = muted;
  }
  impl_->dependencies.wake->notify();
  return NativeMediaSessionCommandStatus::Accepted;
}

NativeMediaSessionCommandStatus NativeMediaSession::stop(
    protocol::Stop command) noexcept {
  if (impl_ == nullptr || !protocol::valid(command)) {
    return NativeMediaSessionCommandStatus::Invalid;
  }
  {
    std::lock_guard lock(impl_->mutex);
    if (impl_->publishedStop.has_value()) {
      return command.stamp == impl_->publishedStop->stamp &&
                     command.invalidationGeneration ==
                         impl_->publishedStop->invalidationGeneration
                 ? NativeMediaSessionCommandStatus::Ignored
                 : NativeMediaSessionCommandStatus::Invalid;
    }
    const MediaGeneration reserved =
        impl_->publishedPrepare.has_value()
            ? impl_->publishedPrepare->command.reservedGeneration.value
            : 0;
    if (reserved == 0 ||
        !protocol::stopFollows(
            impl_->latestAcceptedStamp,
            protocol::GenerationHighWater{impl_->generationHighWater},
            command)) {
      return NativeMediaSessionCommandStatus::Invalid;
    }
    // If true, that mutation already linearized before this Stop. Nothing can
    // begin a second live issue until the permit holder returns and clears it.
    impl_->publishedStop = command;
    const MediaGeneration cancellationGeneration =
        std::max(reserved, impl_->generationHighWater);
    impl_->cancellation->generation.store(cancellationGeneration,
                                          std::memory_order_release);
    impl_->publishedStart.reset();
    impl_->publishedRun.reset();
    impl_->publishedGain.reset();
    impl_->publishedMuted.reset();
    impl_->publishedPreviewHandoff.reset();
    impl_->publishedPreview.reset();
    impl_->publishedCommit.reset();
    // This latch closes cancel-before-source-arm: if the worker has not yet
    // built the source, it observes Stop before arm; if it is blocked in open,
    // requestCancel sees the dispatcher's published exact operation slot.
    if (impl_->dispatcherObserver != nullptr) {
      impl_->dispatcherObserver->requestCancel(cancellationGeneration);
    }
    impl_->latestAcceptedStamp = command.stamp;
    impl_->factMailbox.reset();
    impl_->pendingFailure.reset();
    impl_->runStateAppliedSlot.reset();
    impl_->audioClockSlot.reset();
    impl_->videoDrawSlot.reset();
    impl_->previewPresentedSlot.reset();
    impl_->previewFailedSlot.reset();
    impl_->commitReadySlot.reset();
    impl_->publicCommitPending = false;
    // Retirement supersedes an open commit handshake; nothing will answer it.
    impl_->commitRunStatePending = false;
    impl_->publicPreviewHandoffPending = false;
    impl_->publicPreviewHandoffReady = false;
    impl_->publicPreviewHandoffFailed = false;
    impl_->publicPreviewPending = false;
    impl_->observationRetryWakeUsed = false;
  }
  impl_->dependencies.wake->publishVideoDueHostTicks(0);
  impl_->dependencies.wake->notify();
  return NativeMediaSessionCommandStatus::Accepted;
}

NativeMediaSessionObservations
NativeMediaSession::takeObservations() noexcept {
  NativeMediaSessionObservations result;
  if (impl_ == nullptr) {
    return result;
  }
  {
    std::lock_guard lock(impl_->mutex);
    result.lifecycle = std::move(impl_->factMailbox);
    result.runStateApplied = std::move(impl_->runStateAppliedSlot);
    result.audioClock = std::move(impl_->audioClockSlot);
    result.videoDraw = std::move(impl_->videoDrawSlot);
    result.previewPresented = std::move(impl_->previewPresentedSlot);
    result.previewFailed = std::move(impl_->previewFailedSlot);
    result.commitReady = std::move(impl_->commitReadySlot);
    impl_->factMailbox.reset();
    impl_->runStateAppliedSlot.reset();
    impl_->audioClockSlot.reset();
    impl_->videoDrawSlot.reset();
    impl_->previewPresentedSlot.reset();
    impl_->previewFailedSlot.reset();
    impl_->commitReadySlot.reset();
    impl_->observationQueued = false;
    impl_->observationRetryWakeUsed = false;
    impl_->queuedObservationQueueSerial = 0;
  }
  impl_->dependencies.wake->notify();
  return result;
}

NativeMediaSessionFacts NativeMediaSession::facts() const noexcept {
  NativeMediaSessionFacts result;
  if (impl_ == nullptr) {
    result.ownership = NativeMediaSessionOwnershipPhase::Closed;
    return result;
  }
  std::lock_guard lock(impl_->mutex);
  result.ownership = impl_->publicOwnership;
  result.generation = impl_->publicActiveGeneration;
  result.generationHighWater = impl_->generationHighWater;
  result.invalidationGeneration =
      impl_->publishedStop.has_value()
          ? impl_->publishedStop->invalidationGeneration.value
          : 0;
  result.workerRunning = impl_->worker.joinable() && !impl_->exitRequested;
  result.prepareAccepted = impl_->publishedPrepare.has_value();
  result.prepared = impl_->publicPrepared;
  result.started = impl_->publicStarted;
  result.dispatcherObservedVideo = impl_->publicDispatcherObservedVideo;
  result.directVideoRetired = impl_->publicDirectVideoRetired;
  result.directAudioRetired = impl_->publicDirectAudioRetired;
  result.factPending = impl_->factMailbox.has_value();
  result.stopLatched = impl_->publishedStop.has_value();
  result.stoppedProofPublished = impl_->publicStopped;
  result.ending = impl_->publicEnding;
  result.endedProofPublished = impl_->publicEnded;
  result.liveFailed = impl_->publicLiveFailed;
  result.previewHandoffPending = impl_->publicPreviewHandoffPending;
  result.previewHandoffReady = impl_->publicPreviewHandoffReady;
  result.previewPending = impl_->publicPreviewPending;
  result.previewPresentedPending = impl_->previewPresentedSlot.has_value();
  result.previewFailedPending = impl_->previewFailedSlot.has_value();
  result.commitPending = impl_->publicCommitPending;
  result.commitReadyPending = impl_->commitReadySlot.has_value();
  result.requestedRunStateStamp = impl_->publicRequestedRunStamp;
  result.issuedRunStateStamp = impl_->publicIssuedRunStamp;
  result.appliedRunStateStamp = impl_->publicAppliedRunStamp;
  result.appliedPaused = impl_->publicAppliedPaused;
  result.observationPending = impl_->observationsPresentLocked();
  return result;
}

NativeMediaSessionMetrics NativeMediaSession::metrics() const noexcept {
  NativeMediaSessionMetrics result;
  if (impl_ == nullptr) {
    return result;
  }
  // Arming is idempotent and deliberately performed by the reader: the session
  // has no knowledge of whether a metrics stream exists, and this keeps the
  // worker's sampling cost strictly opt-in. The first call after arming can
  // therefore legitimately report every group as unavailable.
  impl_->metricsArmed.store(true, std::memory_order_relaxed);
  // Always reported, even on that first unavailable-everything call: it names
  // the epoch the counters will belong to, not a counter of its own.
  result.sessionEpoch = impl_->sessionEpoch;
  result.videoValid = impl_->metricsVideoValid.load(std::memory_order_relaxed);
  if (result.videoValid) {
    result.drawnFrames =
        impl_->metricsDrawnFrames.load(std::memory_order_relaxed);
    result.submittedFrames =
        impl_->metricsSubmittedFrames.load(std::memory_order_relaxed);
    result.supersededFrames =
        impl_->metricsSupersededFrames.load(std::memory_order_relaxed);
    result.discardedLateFrames =
        impl_->metricsDiscardedLateFrames.load(std::memory_order_relaxed);
  }
  result.audioValid = impl_->metricsAudioValid.load(std::memory_order_relaxed);
  if (result.audioValid) {
    result.audioUnderrunCallbacks =
        impl_->metricsAudioUnderrunCallbacks.load(std::memory_order_relaxed);
    result.audioClockAdvancedUnderruns =
        impl_->metricsAudioClockAdvancedUnderruns.load(
            std::memory_order_relaxed);
    result.audioRetiredLateFrames =
        impl_->metricsAudioRetiredLateFrames.load(std::memory_order_relaxed);
    result.audioCallbacks =
        impl_->metricsAudioCallbacks.load(std::memory_order_relaxed);
    result.audioRenderedFrames =
        impl_->metricsAudioRenderedFrames.load(std::memory_order_relaxed);
  }
  result.clockValid = impl_->metricsClockValid.load(std::memory_order_relaxed);
  if (result.clockValid) {
    const std::uint64_t mediaSecondsBits =
        impl_->metricsMediaSecondsBits.load(std::memory_order_relaxed);
    const std::uint64_t rateBits =
        impl_->metricsClockRateBits.load(std::memory_order_relaxed);
    std::memcpy(&result.mediaSeconds, &mediaSecondsBits,
                sizeof(result.mediaSeconds));
    std::memcpy(&result.clockRate, &rateBits, sizeof(result.clockRate));
  }
  {
    std::lock_guard lock(impl_->mutex);
    result.paused = impl_->publicAppliedPaused;
  }
  return result;
}

#if defined(WAM_NATIVE_MEDIA_SESSION_TESTING)
void NativeMediaSessionTestAccess::installGraphFactory(
    NativeMediaSession& session,
    NativeMediaSessionTestGraphFactory factory,
    void* context) noexcept {
  if (session.impl_ == nullptr) {
    return;
  }
  std::lock_guard lock(session.impl_->mutex);
  if (!session.impl_->publishedPrepare.has_value() &&
      session.impl_->publicOwnership ==
          NativeMediaSessionOwnershipPhase::Empty) {
    session.impl_->testFactory = factory;
    session.impl_->testFactoryContext = context;
  }
}

void NativeMediaSessionTestAccess::installFailureLatchBarrier(
    NativeMediaSession& session,
    std::atomic<bool>* entered,
    std::atomic<bool>* release) noexcept {
  if (session.impl_ == nullptr) {
    return;
  }
  std::lock_guard lock(session.impl_->mutex);
  session.impl_->failureLatchEntered = entered;
  session.impl_->failureLatchRelease = release;
}

void NativeMediaSessionTestAccess::installFailureDetectionBarrier(
    NativeMediaSession& session,
    std::atomic<bool>* entered,
    std::atomic<bool>* release) noexcept {
  if (session.impl_ == nullptr) {
    return;
  }
  std::lock_guard lock(session.impl_->mutex);
  session.impl_->failureDetectionEntered = entered;
  session.impl_->failureDetectionRelease = release;
}

void NativeMediaSessionTestAccess::installLiveIssueBarrier(
    NativeMediaSession& session,
    std::atomic<bool>* entered,
    std::atomic<bool>* release) noexcept {
  if (session.impl_ == nullptr) {
    return;
  }
  std::lock_guard lock(session.impl_->mutex);
  session.impl_->liveIssueBarrierEntered = entered;
  session.impl_->liveIssueBarrierRelease = release;
  session.impl_->liveIssueBarrierConsumed.store(false,
                                                 std::memory_order_release);
}

void NativeMediaSessionTestAccess::installCommandDrainBarrier(
    NativeMediaSession& session,
    std::atomic<bool>* entered,
    std::atomic<bool>* release) noexcept {
  if (session.impl_ == nullptr || entered == nullptr || release == nullptr) {
    return;
  }
  std::lock_guard lock(session.impl_->mutex);
  session.impl_->commandDrainBarrierEntered = entered;
  session.impl_->commandDrainBarrierRelease = release;
  session.impl_->commandDrainBarrierConsumed.store(
      false, std::memory_order_release);
}

void NativeMediaSessionTestAccess::installPreviewPullBarrier(
    NativeMediaSession& session,
    std::atomic<bool>* entered,
    std::atomic<bool>* release) noexcept {
  if (session.impl_ == nullptr || entered == nullptr || release == nullptr) {
    return;
  }
  session.impl_->previewPullBarrierEntered.store(entered,
                                                  std::memory_order_release);
  session.impl_->previewPullBarrierRelease.store(release,
                                                  std::memory_order_release);
  session.impl_->previewPullBarrierConsumed.store(false,
                                                   std::memory_order_release);
}

void NativeMediaSessionTestAccess::installPreviewConstructionBarrier(
    NativeMediaSession& session,
    std::atomic<bool>* entered,
    std::atomic<bool>* release) noexcept {
  if (session.impl_ == nullptr || entered == nullptr || release == nullptr) {
    return;
  }
  session.impl_->previewConstructionBarrierEntered.store(
      entered, std::memory_order_release);
  session.impl_->previewConstructionBarrierRelease.store(
      release, std::memory_order_release);
  session.impl_->previewConstructionBarrierConsumed.store(
      false, std::memory_order_release);
}

void NativeMediaSessionTestAccess::installPreviewCompletionBarrier(
    NativeMediaSession& session,
    NativeMediaSessionTestPreviewCompletionPoint point,
    std::atomic<bool>* entered,
    std::atomic<bool>* release) noexcept {
  if (session.impl_ == nullptr ||
      point == NativeMediaSessionTestPreviewCompletionPoint::None ||
      entered == nullptr || release == nullptr) {
    return;
  }
  session.impl_->previewCompletionBarrierEntered.store(
      entered, std::memory_order_release);
  session.impl_->previewCompletionBarrierRelease.store(
      release, std::memory_order_release);
  session.impl_->previewCompletionBarrierConsumed.store(
      false, std::memory_order_release);
  session.impl_->previewCompletionBarrierPoint.store(
      point, std::memory_order_release);
}

void NativeMediaSessionTestAccess::installWakeConsumeBarrier(
    NativeMediaSessionWake& wake,
    std::atomic<bool>* entered,
    std::atomic<bool>* release) noexcept {
  if (wake.impl_ == nullptr || entered == nullptr || release == nullptr) {
    return;
  }
  wake.impl_->consumeBarrierEntered.store(entered,
                                          std::memory_order_release);
  wake.impl_->consumeBarrierRelease.store(release,
                                          std::memory_order_release);
  wake.impl_->consumeBarrierConsumed.store(false,
                                            std::memory_order_release);
  const std::uint64_t current =
      wake.impl_->consumedTokens.load(std::memory_order_acquire);
  wake.impl_->consumeBarrierTarget.store(current + 1,
                                         std::memory_order_release);
}

std::uint64_t NativeMediaSessionTestAccess::videoDueHostTicks(
    const NativeMediaSessionWake& wake) noexcept {
  return wake.impl_ == nullptr
             ? 0
             : wake.impl_->videoDueHostTicks.load(
                   std::memory_order_acquire);
}

NativeMediaSessionTestWorkerPoolFacts
NativeMediaSessionTestAccess::workerPoolFacts(
    const NativeMediaSession& session) noexcept {
  if (session.impl_ == nullptr) {
    return {};
  }
  NativeMediaSessionTestWorkerPoolFacts result;
  result.entered = session.impl_->workerAutoreleasePoolsEntered.load(
      std::memory_order_acquire);
  result.drained = session.impl_->workerAutoreleasePoolsDrained.load(
      std::memory_order_acquire);
  result.active = session.impl_->workerAutoreleasePoolsActive.load(
      std::memory_order_acquire);
  result.peakActive = session.impl_->workerAutoreleasePoolsPeak.load(
      std::memory_order_acquire);
  return result;
}
#endif

}  // namespace wam::macos
