#include "native_process_lifetime.hpp"
#include "platform/macos/native_primitives.hpp"
#include "native_audio_session.hpp"

#include "media/adpcm_audio.hpp"
#include "media/audio_codec_timing.hpp"
#include "media/audio_downmix.hpp"
#include "media/media_codec_facts.hpp"
#include "core_media_codec_facts.hpp"
#include "native_audio_admission.hpp"
#include "native_audio_channel_map.hpp"
#include "native_concurrency_limits.hpp"

#import <AudioToolbox/AudioToolbox.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <limits>
#include <mutex>
#include <optional>
#include <utility>
#include <variant>

namespace wam::macos {
namespace {

enum class FlushStage : std::uint8_t {
  Stop,
  Reset,
  Activate,
};

enum class RetireStage : std::uint8_t {
  StopOutput,
  InvalidateGraph,
  CloseOutput,
  Done,
};

// An admitted exact retirement. Only this pair may be retried, and its stage
// only moves forward.
struct Retirement {
  media::MediaGeneration retired{0};
  media::MediaGeneration invalidation{0};
  RetireStage stage{RetireStage::StopOutput};
};

// A terminal stop or cancel that superseded a reversible seek flush, for the
// generation it was issued against. Only that terminal may be retried.
struct TerminalOverride {
  enum class Kind : std::uint8_t { Stop, Cancel };
  Kind kind{Kind::Stop};
  media::MediaGeneration generation{0};
};

// Pause-driven idling of the output AudioUnit. Stopping is not instantaneous:
// AudioOutputUnitStop revokes admission and stops the device synchronously,
// but a callback already inside the bridge must still drain before the stop
// is Done. Stopping therefore names the interval in which the device is
// already stopped and admission already revoked while that drain completes.
// It exists so that a resume arriving inside that interval cannot mistake a
// Started session for a running output and leave the device stopped forever.
enum class OutputSuspension : std::uint8_t {
  None,
  Stopping,
  Suspended,
};

// Everything the session knows about one generation's audio timeline. The
// active generation's plan is session state; a flush computes the next one and
// installs it whole once the flush is Done.
struct TimelinePlan {
  media::NativeMediaGenerationTimeline timeline{};

  // Codec fact fixed at configure() and carried into every later flush, which
  // does not see the track descriptor again (as are converter's ceiling facts).
  bool audioMayPrecedeStreamOrigin{false};
  NativeAudioGenerationTimeline converter{};
  media::MediaTime decodeStart{};       // first source-proved audio AU D
  media::MediaTime mediaOrigin{};       // first retained source PCM frame A
  media::MediaTime clockPosition{};     // exact visual generation floor T
  std::int64_t floorFrame{0};
  std::uint32_t sampleRate{0};
  // Generation-local frame index of mediaOrigin: the frame the clock's cursor
  // zero names. Equal to floorFrame unless the container declares silence
  // before its audio, in which case the clock starts at the VISUAL floor and
  // the audio floor sits leadInSilenceFrames later.
  std::int64_t originFrame{0};
  std::uint64_t leadInSilenceFrames{0};
  // The same facts in generation-local cursor frames, as the render core takes
  // them. Derived once here so the arithmetic exists in exactly one place.
  media::NativeAudioDeclaredSilence declaredSilence{};
  // Absolute audio frame at which this generation's PRESENTATION must end when
  // the container declares trailing silence (a video tail past the end of the
  // selected audio). Zero means "the audio's own end".
  std::int64_t presentationEndFrame{0};
  // Absolute audio frame at which the container states its audio media ends.
  // Zero unless presentationEndFrame is stated too.
  std::int64_t audioEndFrame{0};
};

// A reversible seek flush in progress: its exact retired/target pair, the
// plan it activates, and how far it has got.
struct FlushLifecycle {
  FlushStage stage{FlushStage::Stop};
  media::MediaGeneration retired{0};
  media::MediaGeneration target{0};
  TimelinePlan plan{};
};

struct CancelLifecycle {
  media::MediaGeneration target{0};
};

// The reversible lifecycle operation that owns the graph, if any.
using SessionLifecycle =
    std::variant<std::monostate, FlushLifecycle, CancelLifecycle>;

// Guards the session-envelope registry below: gRetainedSessions and every
// quarantine slot. Taken only on create(), on the Done-close release, on a
// destructor's quarantine transfer, on the quarantine drain and on
// quarantineFacts(). No render callback, no trySample(), no clock publication
// and no owner-thread steady-state path touches it, so it can never appear on
// the audio hot path.
NativeProcessLifetime<std::mutex> gSessionMutexStorage;
std::mutex& gSessionMutex = gSessionMutexStorage.get();
// Sessions currently charged against the process envelope: every session
// create() admitted whose graph has not yet proved a Done close. A quarantined
// session is still charged -- it still owns its AudioUnit, its converter, its
// PCM ring and the callback contexts the device may still be inside -- so the
// count is live plus quarantined and never exceeds
// kMaximumConcurrentPlayerWindows.
int gRetainedSessions{0};
// One quarantine slot per admissible player window, so every open window's
// graph can be held at once and none is ever dropped for want of a slot. A
// fixed array of empty shared_ptrs: the registry allocates nothing itself and
// cannot grow, whatever a teardown storm does.
using SessionQuarantine = std::array<std::shared_ptr<NativeAudioSessionControl>,
                                     kMaximumConcurrentPlayerWindows>;
NativeProcessLifetime<SessionQuarantine> gSessionQuarantineStorage;
SessionQuarantine& gSessionQuarantine = gSessionQuarantineStorage.get();
std::atomic<std::uint64_t> gRejectedCreates{0};
std::atomic<std::uint64_t> gQuarantineTransfers{0};
std::atomic<std::uint64_t> gQuarantineRecoveries{0};

[[nodiscard]] bool exactFrame(media::MediaTime time,
                              std::uint32_t sampleRate,
                              std::int64_t* result) noexcept {
  const auto frame = media::exactAudioFrameIndex(time, sampleRate);
  if (!frame || result == nullptr) {
    return false;
  }
  *result = *frame;
  return true;
}

// Whether this track's stated duration is an exact whole number of frames,
// and therefore usable as the frame the generation must stop publishing at.
// A Matroska descriptor states the exact decoded sample count by construction;
// another container's duration is its own number, which need not be a whole
// frame count. Such a track simply takes no ceiling instead of failing the
// whole session, and a duration that IS exact is the true end of the track.
[[nodiscard]] bool durationIsExactFrameCount(
    const media::MediaTrackDescriptor& track, std::uint32_t sampleRate) noexcept {
  std::int64_t ceilingFrame = 0;
  return exactFrame(track.duration, sampleRate, &ceilingFrame) &&
         ceilingFrame > 0;
}

[[nodiscard]] bool validDependencies(
    const NativeAudioSessionDependencies& dependencies) noexcept {
  return dependencies.externalLifetime != nullptr &&
         dependencies.hostClock.readTicks != nullptr &&
         dependencies.hostClock.ticksPerSecond != 0 &&
         validNativeAudioUnitCallTable(dependencies.outputCalls) &&
         dependencies.outputWake.pending != nullptr &&
         dependencies.outputWake.signal != nullptr &&
         dependencies.outputWake.pending->is_lock_free();
}

[[nodiscard]] std::optional<TimelinePlan> timelinePlanForRate(
    media::MediaGeneration generation,
    const media::NativeMediaGenerationTimeline& timeline,
    std::uint32_t sampleRate, bool audioMayPrecedeStreamOrigin) noexcept {
  std::int64_t floorFrame = 0;
  std::int64_t decodeFrame = 0;
  if (generation == 0 || timeline.generation != generation ||
      !timeline.requestedTarget.valid() ||
      !timeline.actualDecodeStart.valid() ||
      !timeline.presentationFloor.valid() ||
      !timeline.audioWindow.decodeStart.valid() ||
      !timeline.audioWindow.presentationStart.valid() ||
      !exactFrame(timeline.audioWindow.decodeStart, sampleRate,
                  &decodeFrame) ||
      !exactFrame(timeline.audioWindow.presentationStart, sampleRate,
                  &floorFrame) ||
      (decodeFrame < 0 && !audioMayPrecedeStreamOrigin) ||
      floorFrame < 0) {
    return std::nullopt;
  }

  constexpr media::MediaTime origin{0, 1};
  const auto actualAgainstFloor = media::compareMediaTime(
      timeline.actualDecodeStart, timeline.presentationFloor);
  const auto actualAgainstOrigin =
      media::compareMediaTime(timeline.actualDecodeStart, origin);
  const auto targetAgainstFloor = media::compareMediaTime(
      timeline.requestedTarget, timeline.presentationFloor);
  const auto targetAgainstOrigin =
      media::compareMediaTime(timeline.requestedTarget, origin);
  const auto actualAgainstTarget = media::compareMediaTime(
      timeline.actualDecodeStart, timeline.requestedTarget);
  const auto audioDecodeAgainstFloor = media::compareMediaTime(
      timeline.audioWindow.decodeStart,
      timeline.audioWindow.presentationStart);
  const auto audioDecodeAgainstOrigin = media::compareMediaTime(
      timeline.audioWindow.decodeStart, origin);
  const auto audioDecodeAgainstMediaStart = media::compareMediaTime(
      timeline.audioWindow.decodeStart, timeline.audioWindow.mediaStart);
  if (!actualAgainstFloor ||
      *actualAgainstFloor == media::MediaTimeOrder::Greater ||
      !actualAgainstOrigin ||
      *actualAgainstOrigin == media::MediaTimeOrder::Less ||
      !targetAgainstFloor || !targetAgainstOrigin ||
      *targetAgainstOrigin == media::MediaTimeOrder::Less ||
      !actualAgainstTarget ||
      *actualAgainstTarget == media::MediaTimeOrder::Greater ||
      timeline.startsAtStreamOrigin !=
          (*actualAgainstOrigin == media::MediaTimeOrder::Equal) ||
      !audioDecodeAgainstFloor ||
      *audioDecodeAgainstFloor == media::MediaTimeOrder::Greater ||
      !audioDecodeAgainstOrigin ||
      (*audioDecodeAgainstOrigin == media::MediaTimeOrder::Less &&
       !audioMayPrecedeStreamOrigin) ||
      // An audio window that begins at or before the movie time the audio
      // media begins can only be the stream origin: there is nothing earlier
      // for it to be. mediaStart is the origin for every source that declares
      // no silence before its audio.
      !audioDecodeAgainstMediaStart ||
      timeline.audioWindow.startsAtStreamOrigin !=
          (*audioDecodeAgainstMediaStart !=
           media::MediaTimeOrder::Greater)) {
    return std::nullopt;
  }

  bool trimBeforeFloor = false;
  switch (timeline.mode) {
  case media::MediaSeekMode::Accurate:
    if (*targetAgainstFloor != media::MediaTimeOrder::Equal) {
      return std::nullopt;
    }
    // Audio presentation begins at the requested target, or at the movie time
    // the container says its audio media begins -- whichever is later. The two
    // differ exactly when a leading empty edit declares silence the target
    // falls inside; the span between them is what the render core renders as
    // declared silence, and the equality below still pins the boundary to an
    // exact frame with no rounding.
    if (const auto mediaStartAgainstTarget = media::compareMediaTime(
            timeline.audioWindow.mediaStart, timeline.requestedTarget);
        !mediaStartAgainstTarget) {
      return std::nullopt;
    } else if (const auto expected = media::audioFrameAtOrAfter(
                   *mediaStartAgainstTarget == media::MediaTimeOrder::Greater
                       ? timeline.audioWindow.mediaStart
                       : timeline.requestedTarget,
                   sampleRate);
               !expected ||
               media::compareMediaTime(
                   timeline.audioWindow.presentationStart, *expected) !=
                   media::MediaTimeOrder::Equal) {
      return std::nullopt;
    }
    trimBeforeFloor =
        *audioDecodeAgainstFloor == media::MediaTimeOrder::Less;
    break;
  case media::MediaSeekMode::KeyFrame:
    if (*actualAgainstFloor != media::MediaTimeOrder::Equal ||
        (*audioDecodeAgainstFloor != media::MediaTimeOrder::Equal &&
         !audioMayPrecedeStreamOrigin) ||
        media::compareMediaTime(timeline.audioWindow.presentationStart,
                                timeline.presentationFloor) !=
            media::MediaTimeOrder::Equal) {
      return std::nullopt;
    }
    trimBeforeFloor =
        *audioDecodeAgainstFloor == media::MediaTimeOrder::Less;
    break;
  default:
    return std::nullopt;
  }

  // The clock's origin is the first audio frame boundary at or after the
  // VISUAL floor -- which is exactly what NativeAudioRenderCore::activate()
  // already requires of mediaOrigin at cursor zero, and which equals the
  // converter's presentation floor for every source that declares no silence
  // before its audio. Decoupling the two is the whole of leading-silence
  // support: the clock starts where the picture starts, the converter still
  // publishes its first PCM frame at the audio floor, and the frames between
  // them are the container's declared silence.
  std::int64_t originFrame = 0;
  const auto originBoundary = media::audioFrameAtOrAfter(
      timeline.presentationFloor, sampleRate);
  if (!originBoundary ||
      !exactFrame(*originBoundary, sampleRate, &originFrame) ||
      originFrame < 0 || originFrame > floorFrame) {
    return std::nullopt;
  }

  TimelinePlan result;
  result.converter.presentationFloor = {
      floorFrame, static_cast<std::int32_t>(sampleRate)};
  result.converter.trimBeforeFloor = trimBeforeFloor;
  result.converter.startsAtStreamOrigin =
      timeline.audioWindow.startsAtStreamOrigin;
  result.decodeStart = timeline.audioWindow.decodeStart;
  result.mediaOrigin = {originFrame, static_cast<std::int32_t>(sampleRate)};
  result.clockPosition = timeline.presentationFloor;
  result.floorFrame = floorFrame;
  result.originFrame = originFrame;
  result.leadInSilenceFrames =
      static_cast<std::uint64_t>(floorFrame - originFrame);
  result.declaredSilence.leadInFrames = result.leadInSilenceFrames;
  result.sampleRate = sampleRate;
  return result;
}

// The tail-trim ceiling and the pre-origin allowance are codec facts, so they
// have to survive into every later flush, which never sees the descriptor
// again. Both call sites therefore go through this one function.
[[nodiscard]] std::optional<TimelinePlan> timelinePlanFor(
    media::MediaGeneration generation,
    const media::NativeMediaGenerationTimeline& timeline,
    std::uint32_t sampleRate, bool audioMayPrecedeStreamOrigin,
    bool trimAfterCeiling, media::MediaTime presentationCeiling) noexcept {
  auto plan = timelinePlanForRate(generation, timeline, sampleRate,
                                  audioMayPrecedeStreamOrigin);
  if (!plan) {
    return std::nullopt;
  }
  plan->timeline = timeline;
  plan->audioMayPrecedeStreamOrigin = audioMayPrecedeStreamOrigin;
  if (trimAfterCeiling) {
    // The source states the track's duration as the exact decoded sample
    // count (for Opus, after both trims), so it is the frame the generation
    // must stop publishing at. A track that cannot state it exactly is not admitted
    // natively at all rather than played a few milliseconds long.
    std::int64_t ceilingFrame = 0;
    if (!presentationCeiling.valid() ||
        !exactFrame(presentationCeiling, sampleRate, &ceilingFrame) ||
        ceilingFrame <= plan->floorFrame) {
      return std::nullopt;
    }
    plan->converter.presentationCeiling = presentationCeiling;
    plan->converter.trimAfterCeiling = true;
  }
  // Container-declared TRAILING silence. presentationEnd is the movie time the
  // generation's presentation must reach when the selected audio stops short
  // of the selected video; the frames between the last real PCM frame and it
  // are declared silence, exactly like the leading span. Absent (the default)
  // it stays zero and the generation ends at its own audio end.
  if (timeline.audioWindow.presentationEnd.valid()) {
    std::int64_t endFrame = 0;
    std::int64_t audioEndFrame = 0;
    if (!timeline.audioWindow.audioEnd.valid() ||
        !exactFrame(timeline.audioWindow.presentationEnd, sampleRate,
                    &endFrame) ||
        !exactFrame(timeline.audioWindow.audioEnd, sampleRate,
                    &audioEndFrame) ||
        endFrame < plan->floorFrame || audioEndFrame > endFrame) {
      return std::nullopt;
    }
    plan->presentationEndFrame = endFrame;
    plan->audioEndFrame = audioEndFrame;
    // Cursor space: frame zero of the generation is the clock's media origin.
    // A declared end at or before the origin states no trailing silence for
    // THIS generation (a seek past the audio's end), and is left inert.
    if (endFrame > plan->originFrame) {
      plan->declaredSilence.presentationEndFrame =
          static_cast<std::uint64_t>(endFrame - plan->originFrame);
      plan->declaredSilence.pcmEndFrame =
          audioEndFrame > plan->originFrame
              ? static_cast<std::uint64_t>(audioEndFrame - plan->originFrame)
              : 0;
    }
  }
  return plan;
}

[[nodiscard]] std::optional<TimelinePlan> preflight(
    const media::MediaTrackDescriptor& track,
    media::MediaGeneration generation,
    const media::NativeMediaGenerationTimeline& timeline) noexcept {
  const std::optional<AdmittedAudio> admitted = admitAudioTrack(track);
  if (generation == 0 || timeline.generation != generation || !admitted) {
    return std::nullopt;
  }
  return timelinePlanFor(
      generation, timeline, admitted->sampleRate,
      media::audioCodecPrecedesStreamOrigin(track.codec),
      durationIsExactFrameCount(track, admitted->sampleRate), track.duration);
}


// The gain wire admits VLC-style amplification above unity. The ceiling is
// the render core's own kMaximumGain so the session can never publish a gain
// the core would silently re-clamp, and the fail-safe for a non-finite value
// stays silence. See NativeAudioRenderCore::applyGain for the [-1, 1] sample
// saturation that goes with it.
[[nodiscard]] float normalizedGain(float gain) noexcept {
  return std::isfinite(gain)
             ? std::clamp(gain, media::NativeAudioRenderCore::kMinimumGain,
                          media::NativeAudioRenderCore::kMaximumGain)
             : media::NativeAudioRenderCore::kMinimumGain;
}

[[nodiscard]] bool acceptsAudioControls(
    NativeAudioSessionState state) noexcept {
  switch (state) {
  case NativeAudioSessionState::Fresh:
  case NativeAudioSessionState::Configuring:
  case NativeAudioSessionState::Ready:
  case NativeAudioSessionState::Started:
  case NativeAudioSessionState::Stopping:
  case NativeAudioSessionState::Flushing:
    return true;
  case NativeAudioSessionState::Retiring:
  case NativeAudioSessionState::Cancelling:
  case NativeAudioSessionState::Cancelled:
  case NativeAudioSessionState::Closing:
  case NativeAudioSessionState::Unsupported:
  case NativeAudioSessionState::Failed:
  case NativeAudioSessionState::Closed:
    return false;
  }
  return false;
}

// Every operation that feeds the converter or drains it refuses once the
// session has failed or begun tearing down.
[[nodiscard]] bool acceptsWork(NativeAudioSessionState state) noexcept {
  return state != NativeAudioSessionState::Failed &&
         state != NativeAudioSessionState::Retiring &&
         state != NativeAudioSessionState::Closing &&
         state != NativeAudioSessionState::Closed &&
         state != NativeAudioSessionState::Cancelled;
}

} // namespace

struct NativeAudioSessionControl final {
  NativeAudioSessionControl(
      media::MediaGeneration initialGeneration,
      std::shared_ptr<void> external,
      media::NativeMediaHostClock hostClock,
      NativeAudioUnitCallTable outputCalls,
      NativeAudioOutputWakeSeam outputWake,
      std::unique_ptr<NativeAudioConverterBackend> backend)
      : externalLifetime(std::move(external)),
        hostClock(hostClock),
        outputCalls(outputCalls),
        outputWake(outputWake),
        ring(initialGeneration),
        clock(this->hostClock),
        renderCore(ring, clock, this->hostClock.ticksPerSecond),
        converter(ring, std::move(backend),
                  {[](void* context) noexcept {
                     static_cast<void>(signalNativeAudioOutputWake(
                         static_cast<NativeAudioSessionControl*>(context)
                             ->outputWake));
                   },
                   this}),
        generation(initialGeneration) {}

  void latch(NativeAudioSessionFailure value) noexcept {
    if (failure == NativeAudioSessionFailure::None) {
      failure = value;
    }
    if (state != NativeAudioSessionState::Retiring &&
        state != NativeAudioSessionState::Closing &&
        state != NativeAudioSessionState::Closed) {
      state = NativeAudioSessionState::Failed;
    }
  }

  // Destruction order is intentional: output, converter, render core, clock,
  // and ring are destroyed before the external callback lifetime token.
  std::shared_ptr<void> externalLifetime;
  const media::NativeMediaHostClock hostClock;
  const NativeAudioUnitCallTable outputCalls;
  const NativeAudioOutputWakeSeam outputWake;
  media::NativePcmRing ring;
  media::NativeMediaClock clock;
  media::NativeAudioRenderCore renderCore;
  NativeAudioConverter converter;
  std::shared_ptr<NativeAudioOutput> output;

  NativeAudioSessionState state{NativeAudioSessionState::Fresh};
  NativeAudioSessionFailure failure{NativeAudioSessionFailure::None};
  SessionLifecycle lifecycle;
  OutputSuspension outputSuspension{OutputSuspension::None};
  media::MediaGeneration generation{0};
  media::MediaGeneration highestExposedGeneration{0};
  media::MediaGeneration cancelledGeneration{0};
  media::MediaGeneration completedFlushRetired{0};
  media::MediaGeneration completedFlushTarget{0};
  media::MediaTrackId track{0};
  TimelinePlan active{};
  // Set when a StreamFormat notification froze a graph that was running, so
  // the reconciliation knows to start the output again once the device proves
  // unchanged. Cleared as soon as that restart is Done, or when the owner
  // takes the session somewhere the restart no longer applies.
  bool deviceChangeResumePending{false};
  std::uint64_t deviceChangeRecoveries{0};
  // Owned by publishFailureText(); NativeAudioSession::failureText() hands out
  // a reference to it, so it is never cleared once set.
  std::string failureText;
  bool claimHeld{true};
  bool resourceEntered{false};
  bool configured{false};
  bool firstAudioSampleAccepted{false};
  bool requestedPaused{true};
  float requestedGain{1.0F};
  bool requestedMuted{false};
  media::NativePlaybackRate requestedRate{};
  bool requestedPreservePitch{true};
  std::uint64_t controlRevision{0};
  bool endOfStreamRequested{false};
  bool terminalPublished{false};
  bool clockActivated{false};
  std::optional<Retirement> retirement;
  bool closeDone{false};
  std::optional<TerminalOverride> terminalOverride;
#if defined(WAM_NATIVE_TEST_SEAMS)
  bool forceCloseQuiescing{false};
#endif
};




#if defined(WAM_NATIVE_TEST_SEAMS)
std::unique_ptr<NativeAudioSession>
NativeAudioSessionTestAccess::recoverQuarantined() noexcept {
  std::lock_guard<std::mutex> lock(gSessionMutex);
  for (std::shared_ptr<NativeAudioSessionControl>& slot : gSessionQuarantine) {
    if (slot == nullptr) {
      continue;
    }
    try {
      auto recovered =
          std::unique_ptr<NativeAudioSession>(new NativeAudioSession(slot));
      slot.reset();
      saturatingAdd(gQuarantineRecoveries, 1);
      return recovered;
    } catch (...) {
      return {};
    }
  }
  return {};
}

NativeAudioSubmitResult NativeAudioSessionTestAccess::occupyConverter(
    NativeAudioSession& session, media::MediaSample&& sample) noexcept {
  try {
    NativeAudioConverter& converter = session.control_->converter;
    NativeAudioPrepareOutcome outcome = converter.prepare(sample, nullptr);
    if (outcome.result != NativeAudioSubmitResult::Accepted) {
      return outcome.result;
    }
    return converter.commitPrepared(std::move(outcome.prepared),
                                    std::move(sample))
               ? NativeAudioSubmitResult::Accepted
               : NativeAudioSubmitResult::Failed;
  } catch (...) {
    return NativeAudioSubmitResult::Failed;
  }
}

void NativeAudioSessionTestAccess::setAfterRenderPreflightHook(
    NativeAudioSession& session, CallbackHook hook,
    void* context) noexcept {
  media::NativeAudioRenderCoreTestAccess::setAfterPreflightHook(
      session.control_->renderCore, hook, context);
}

bool NativeAudioSessionTestAccess::stageFlushAfterStop(
    NativeAudioSession& session,
    media::MediaGeneration retiredGeneration,
    media::MediaGeneration nextGeneration,
    const media::NativeMediaGenerationTimeline& timeline) noexcept {
  NativeAudioSessionControl& control = *session.control_;
  const std::optional<TimelinePlan> plan = timelinePlanFor(
      nextGeneration, timeline, control.active.sampleRate,
      control.active.audioMayPrecedeStreamOrigin,
      control.active.converter.trimAfterCeiling,
      control.active.converter.presentationCeiling);
  if (!plan) {
    return false;
  }
  control.lifecycle = FlushLifecycle{FlushStage::Reset, retiredGeneration,
                                     nextGeneration, *plan};
  control.highestExposedGeneration = nextGeneration;
  control.requestedPaused = true;
  control.renderCore.setPaused(true);
  control.state = NativeAudioSessionState::Flushing;
  return true;
}

void NativeAudioSessionTestAccess::forceCloseQuiescing(
    NativeAudioSession& session, bool enabled) noexcept {
  session.control_->forceCloseQuiescing = enabled;
}
#endif

namespace {

// Gives one session's slot in the process envelope back, after that session
// proved a Done close. claimHeld makes this single-shot per graph, which the
// count depends on: a second release would invent a slot and let N + 1
// sessions live at once. A session that closes Done while
// sitting in quarantine also vacates its slot here -- the registry only holds
// graphs that still owe a Done close.
void releaseClaim(NativeAudioSessionControl& control) noexcept {
  std::lock_guard<std::mutex> lock(gSessionMutex);
  if (!control.claimHeld) {
    return;
  }
  for (std::shared_ptr<NativeAudioSessionControl>& slot : gSessionQuarantine) {
    if (slot.get() == &control) {
      slot.reset();
      break;
    }
  }
  control.claimHeld = false;
  --gRetainedSessions;
}

// Moves a graph whose owner could not prove a Done close into the registry, so
// a device callback still inside the bridge keeps a live graph under it. The
// envelope count is deliberately unchanged: the graph is still charged, it has
// only swapped a NativeAudioSession owner for the registry until the drain in
// create() drives it to Done.
void quarantine(
    const std::shared_ptr<NativeAudioSessionControl>& control) noexcept {
  if (control == nullptr || !control->claimHeld || control->closeDone) {
    return;
  }
  std::lock_guard<std::mutex> lock(gSessionMutex);
  // A free slot always exists here: quarantined graphs are a subset of the
  // gRetainedSessions charged against the envelope, and this graph still holds
  // its own claim (claimHeld above) while not yet occupying a slot, so at most
  // kMaximumConcurrentPlayerWindows - 1 slots can be taken.
  for (std::shared_ptr<NativeAudioSessionControl>& slot : gSessionQuarantine) {
    if (slot == nullptr) {
      slot = control;
      saturatingAdd(gQuarantineTransfers, 1);
      return;
    }
  }
}

[[nodiscard]] const char* renderFailureName(
    media::NativeAudioRenderFailure failure) noexcept {
  switch (failure) {
  case media::NativeAudioRenderFailure::None: return "None";
  case media::NativeAudioRenderFailure::InvalidInput: return "InvalidInput";
  case media::NativeAudioRenderFailure::ReentrantCallback:
    return "ReentrantCallback";
  case media::NativeAudioRenderFailure::ResumeRejected: return "ResumeRejected";
  case media::NativeAudioRenderFailure::RingContractViolation:
    return "RingContractViolation";
  case media::NativeAudioRenderFailure::ClockCommitFailed:
    return "ClockCommitFailed";
  case media::NativeAudioRenderFailure::StretchStageFailed:
    return "StretchStageFailed";
  }
  return "Unknown";
}

[[nodiscard]] const char* sessionFailureName(
    NativeAudioSessionFailure failure) noexcept {
  switch (failure) {
  case NativeAudioSessionFailure::None: return "None";
  case NativeAudioSessionFailure::InvalidDependency:
    return "InvalidDependency";
  case NativeAudioSessionFailure::OutputUnavailable:
    return "OutputUnavailable";
  case NativeAudioSessionFailure::ConverterConfiguration:
    return "ConverterConfiguration";
  case NativeAudioSessionFailure::ClockActivation: return "ClockActivation";
  case NativeAudioSessionFailure::OutputConfiguration:
    return "OutputConfiguration";
  case NativeAudioSessionFailure::Converter: return "Converter";
  case NativeAudioSessionFailure::Output: return "Output";
  case NativeAudioSessionFailure::Discontinuity: return "Discontinuity";
  case NativeAudioSessionFailure::ConsumerProtocol: return "ConsumerProtocol";
  case NativeAudioSessionFailure::RingTransition: return "RingTransition";
  case NativeAudioSessionFailure::ClockTransition: return "ClockTransition";
  case NativeAudioSessionFailure::OutputActivation:
    return "OutputActivation";
  case NativeAudioSessionFailure::TerminalPublication:
    return "TerminalPublication";
  }
  return "Unknown";
}

// Names the gate that actually refused, for every audio result that would
// otherwise reach the dispatcher's failure line carrying nothing. The two
// leaves that can fail without an error out-parameter are the output
// AudioUnit and the render core, and only this session can see either, so it
// is the only place the text can be composed at all. Cached in the control
// block so failureText() can hand out a stable reference.
void publishFailureText(NativeAudioSessionControl& control,
                        std::string* error) noexcept {
  try {
    const NativeAudioOutputFailure outputFailure =
        control.output != nullptr ? control.output->facts().failure
                                  : NativeAudioOutputFailure::None;
    const media::NativeAudioRenderFailure renderFailure = control.renderCore.failure();
    if (outputFailure != NativeAudioOutputFailure::None) {
      control.failureText =
          std::string("audio output: ") + nativeAudioOutputFailureName(outputFailure) +
          " (osStatus " +
          std::to_string(
              static_cast<long long>(control.output->facts().osStatus)) +
          ")";
    } else if (renderFailure != media::NativeAudioRenderFailure::None) {
      control.failureText =
          std::string("audio render core: ") + renderFailureName(renderFailure);
    } else if (control.failure != NativeAudioSessionFailure::None) {
      control.failureText =
          std::string("audio session: ") + sessionFailureName(control.failure);
    } else {
      return;
    }
    if (error != nullptr && error->empty()) {
      *error = control.failureText;
    }
  } catch (...) {
    // A diagnostic string must never change the failure already decided.
  }
}

[[nodiscard]] const char* outputStateName(
    NativeAudioOutputState state) noexcept {
  switch (state) {
  case NativeAudioOutputState::Closed: return "Closed";
  case NativeAudioOutputState::Configuring: return "Configuring";
  case NativeAudioOutputState::Stopped: return "Stopped";
  case NativeAudioOutputState::Starting: return "Starting";
  case NativeAudioOutputState::Started: return "Started";
  case NativeAudioOutputState::Stopping: return "Stopping";
  case NativeAudioOutputState::Detaching: return "Detaching";
  }
  return "Unknown";
}

// An output refusal (Invalid) latches no output failure, so
// publishFailureText() alone would name only the session's generic Output
// latch. Name the output state and any pending device notification instead:
// those are the two facts that say why the transition was refused.
void publishOutputRefusalText(NativeAudioSessionControl& control) noexcept {
  try {
    if (control.output == nullptr ||
        control.output->facts().failure != NativeAudioOutputFailure::None) {
      publishFailureText(control, nullptr);
      return;
    }
    const NativeAudioOutputFacts facts = control.output->facts();
    control.failureText =
        std::string("audio output refused the transition in state ") +
        outputStateName(facts.state) +
        (facts.deviceChangePending ? " with a device notification pending"
                                   : "");
  } catch (...) {
  }
}

[[nodiscard]] bool retirementDone(
    const NativeAudioSessionControl& control) noexcept {
  return control.retirement && control.retirement->stage == RetireStage::Done;
}

[[nodiscard]] bool outputFailed(NativeAudioSessionControl& control) noexcept {
  if (control.output != nullptr && control.output->facts().fatal) {
    control.latch(NativeAudioSessionFailure::Output);
    return true;
  }
  if (control.renderCore.failure() != media::NativeAudioRenderFailure::None) {
    control.latch(NativeAudioSessionFailure::Output);
    return true;
  }
  return false;
}

void clearOutputWake(NativeAudioSessionControl& control) noexcept {
  control.outputWake.pending->store(false, std::memory_order_release);
}

[[nodiscard]] bool settleStopped(
    NativeAudioSessionControl& control,
    media::MediaGeneration generation) noexcept {
  if (!control.clock.pause(generation) ||
      !control.renderCore.settlePausedAfterStop(generation)) {
    control.latch(NativeAudioSessionFailure::ClockTransition);
    return false;
  }
  return true;
}

// The start-admission rule: a running output that cannot be fed would
// underrun on its very first callback, so it opens only over prebuffered PCM
// or a generation whose terminal is already published.
[[nodiscard]] bool canStartOutput(NativeAudioSessionControl& control) noexcept {
  return control.ring.readableFrames(control.generation).frames != 0 ||
         control.terminalPublished;
}

// The tail of every output suspension (pause and device recovery alike), once
// the output has proved a Done stop: settle the callback-local running fact
// and leave the session Ready over the idle device.
[[nodiscard]] bool finishSuspend(NativeAudioSessionControl& control) noexcept {
  if (!settleStopped(control, control.generation)) {
    return false;
  }
  control.outputSuspension = OutputSuspension::Suspended;
  control.state = NativeAudioSessionState::Ready;
  return true;
}

[[nodiscard]] bool verifyPublishedOrigin(
    NativeAudioSessionControl& control) noexcept {
  const NativeAudioConverterStats stats = control.converter.stats();
  if (stats.publishedPcmFrames == 0) {
    return true;
  }
  if (!stats.firstPublishedFrameKnown ||
      stats.firstPublishedFrame != control.active.floorFrame) {
    control.latch(NativeAudioSessionFailure::Converter);
    return false;
  }
  return true;
}

[[nodiscard]] bool publishTerminal(
    NativeAudioSessionControl& control) noexcept {
  const NativeAudioConverterStats stats = control.converter.stats();
  if (!stats.drained || !verifyPublishedOrigin(control)) {
    if (!stats.drained) {
      control.latch(NativeAudioSessionFailure::ConsumerProtocol);
    }
    return false;
  }
  if (!control.terminalPublished) {
    // The generation's terminal is the frame after its last PRESENTED frame.
    // Real PCM occupies [leadInSilenceFrames, leadInSilenceFrames +
    // publishedPcmFrames); container-declared silence may precede it, and may
    // follow it when the source states a presentation end past the audio's own
    // end. Both spans are cursor frames the clock passes, so both belong in
    // the terminal. With no declared silence this is publishedPcmFrames
    // verbatim.
    const TimelinePlan& plan = control.active;
    std::uint64_t terminalFrame =
        plan.leadInSilenceFrames + stats.publishedPcmFrames;
    if (plan.presentationEndFrame > plan.originFrame) {
      const auto declaredEnd = static_cast<std::uint64_t>(
          plan.presentationEndFrame - plan.originFrame);
      if (declaredEnd > terminalFrame) {
        terminalFrame = declaredEnd;
      }
    }
    if (!control.renderCore.publishTerminalFrame(control.generation,
                                                 terminalFrame)) {
      control.latch(NativeAudioSessionFailure::TerminalPublication);
      return false;
    }
    control.terminalPublished = true;
  }
  return true;
}

[[nodiscard]] bool terminalObserved(
    const NativeAudioSessionControl& control) noexcept {
  return control.terminalPublished &&
         control.renderCore.terminalObservation().generation ==
             control.generation;
}

// One converter pump outcome as a consumer result. capacity() and
// endOfStream() differ only where end of stream changes the meaning: once
// requested, a converter asking for input is a converter fault and a drained
// one publishes the generation's terminal; before it, both are protocol facts.
[[nodiscard]] media::NativeMediaConsumeResult mapPumpForConsume(
    NativeAudioSessionControl& control, NativeAudioPumpResult result,
    bool endOfStream) noexcept {
  switch (result) {
  case NativeAudioPumpResult::Published:
    return verifyPublishedOrigin(control)
               ? media::NativeMediaConsumeResult::Draining
               : media::NativeMediaConsumeResult::Failed;
  case NativeAudioPumpResult::Progress:
    return media::NativeMediaConsumeResult::Draining;
  case NativeAudioPumpResult::Backpressure:
    return media::NativeMediaConsumeResult::Backpressure;
  case NativeAudioPumpResult::NeedsInput:
    if (!endOfStream) {
      return media::NativeMediaConsumeResult::Accepted;
    }
    control.latch(NativeAudioSessionFailure::Converter);
    return media::NativeMediaConsumeResult::Failed;
  case NativeAudioPumpResult::StaleGeneration:
    return media::NativeMediaConsumeResult::StaleGeneration;
  case NativeAudioPumpResult::Drained:
    if (!endOfStream) {
      control.latch(NativeAudioSessionFailure::ConsumerProtocol);
      return media::NativeMediaConsumeResult::Failed;
    }
    if (!publishTerminal(control)) {
      return media::NativeMediaConsumeResult::Failed;
    }
    return terminalObserved(control)
               ? media::NativeMediaConsumeResult::Drained
               : media::NativeMediaConsumeResult::Draining;
  case NativeAudioPumpResult::NotConfigured:
  case NativeAudioPumpResult::Failed:
    control.latch(NativeAudioSessionFailure::Converter);
    return media::NativeMediaConsumeResult::Failed;
  }
  control.latch(NativeAudioSessionFailure::ConsumerProtocol);
  return media::NativeMediaConsumeResult::Failed;
}

[[nodiscard]] media::NativeMediaConsumerProgress mapPumpForDrain(
    NativeAudioSessionControl& control,
    NativeAudioPumpResult result) noexcept {
  switch (result) {
  case NativeAudioPumpResult::Published:
    return verifyPublishedOrigin(control)
               ? media::NativeMediaConsumerProgress::Progress
               : media::NativeMediaConsumerProgress::Failed;
  case NativeAudioPumpResult::Progress:
    return media::NativeMediaConsumerProgress::Progress;
  case NativeAudioPumpResult::Backpressure:
    return media::NativeMediaConsumerProgress::Quiescing;
  case NativeAudioPumpResult::NeedsInput:
    return media::NativeMediaConsumerProgress::Done;
  case NativeAudioPumpResult::StaleGeneration:
    return media::NativeMediaConsumerProgress::StaleGeneration;
  case NativeAudioPumpResult::Drained:
    if (!control.endOfStreamRequested || !publishTerminal(control)) {
      return media::NativeMediaConsumerProgress::Failed;
    }
    return terminalObserved(control)
               ? media::NativeMediaConsumerProgress::Done
               : media::NativeMediaConsumerProgress::Quiescing;
  case NativeAudioPumpResult::NotConfigured:
  case NativeAudioPumpResult::Failed:
    control.latch(NativeAudioSessionFailure::Converter);
    return media::NativeMediaConsumerProgress::Failed;
  }
  control.latch(NativeAudioSessionFailure::ConsumerProtocol);
  return media::NativeMediaConsumerProgress::Failed;
}

[[nodiscard]] NativeAudioSessionProgress mapOutputProgress(
    NativeAudioSessionControl& control,
    NativeAudioOutputProgress progress,
    NativeAudioSessionFailure failure) noexcept {
  switch (progress) {
  case NativeAudioOutputProgress::Done:
    return NativeAudioSessionProgress::Done;
  case NativeAudioOutputProgress::Quiescing:
    return NativeAudioSessionProgress::Quiescing;
  case NativeAudioOutputProgress::Invalid:
    control.latch(failure);
    publishOutputRefusalText(control);
    return NativeAudioSessionProgress::Invalid;
  case NativeAudioOutputProgress::Failed:
    control.latch(failure);
    publishFailureText(control, nullptr);
    return NativeAudioSessionProgress::Failed;
  }
  control.latch(failure);
  publishFailureText(control, nullptr);
  return NativeAudioSessionProgress::Failed;
}

// Drives an already-begun pause suspend to its Done stop proof. From the
// first stop attempt onward the AudioUnit is stopped and render admission is
// revoked, so no owner operation may treat the output as running until this
// returns Done: the only thing still outstanding is the drain of a callback
// that entered before admission closed. settleStopped() needs that drain,
// because settlePausedAfterStop() takes the render core's callback gate.
[[nodiscard]] NativeAudioSessionProgress completeOutputSuspend(
    NativeAudioSessionControl& control) noexcept {
  const NativeAudioSessionProgress stopped = mapOutputProgress(
      control, control.output->stop(), NativeAudioSessionFailure::Output);
  if (stopped != NativeAudioSessionProgress::Done) {
    return stopped;
  }
  return finishSuspend(control) ? NativeAudioSessionProgress::Done
                                : NativeAudioSessionProgress::Failed;
}

// Outcome of one reconciliation pass over an outstanding StreamFormat
// notification. Idle means there was nothing to do.
enum class DeviceReconcile : std::uint8_t {
  Idle,
  Progressed,
  Failed,
};

// The owner-thread half of the StreamFormat listener, so a notification does
// not by itself end native audio. The listener revoked render
// admission without knowing whether the device actually changed; this decides.
//
// A rate that really moved fails closed, exactly as start()'s own revalidation
// does. An unchanged rate is recovered with the same sequence as the
// pause-suspend lever: freeze the graph, take the output to a proved stop, then
// start it again. The sequence is not incidental. A device that stops under a running
// graph must not leave the authoritative clock free-running across the silent
// gap, and settlePausedAfterStop() is what reconciles the callback-local
// running fact and forces the next callback to establish a fresh host-tick
// anchor. Doing anything cheaper would resume audio against a clock that had
// advanced while nothing was rendering.
[[nodiscard]] DeviceReconcile reconcileOutputDeviceChange(
    NativeAudioSessionControl& control) noexcept {
  if (control.output == nullptr) {
    return DeviceReconcile::Idle;
  }
  const NativeAudioOutputFacts facts = control.output->facts();
  if (facts.fatal) {
    // Already latched by something else; outputFailed() owns the report.
    return DeviceReconcile::Idle;
  }
  if (!facts.deviceChangePending && !control.deviceChangeResumePending) {
    return DeviceReconcile::Idle;
  }
  // Teardown owns the output outright once any of these is in flight, and a
  // retiring/closing session has no interest in resuming a device.
  if (control.retirement.has_value() || control.closeDone ||
      !std::holds_alternative<std::monostate>(control.lifecycle) ||
      control.terminalOverride.has_value() ||
      (control.state != NativeAudioSessionState::Started &&
       control.state != NativeAudioSessionState::Ready)) {
    control.deviceChangeResumePending = false;
    return DeviceReconcile::Idle;
  }

  if (facts.deviceChangePending) {
    if (control.state == NativeAudioSessionState::Started &&
        control.outputSuspension == OutputSuspension::None) {
      // The device went out from under a running graph. Freeze it the way a
      // pause suspend does, and remember that this freeze was not the user's
      // idea so the resume below can undo it.
      control.deviceChangeResumePending = true;
      control.renderCore.setPaused(true);
      if (!control.clock.pause(control.generation)) {
        control.latch(NativeAudioSessionFailure::ClockTransition);
        return DeviceReconcile::Failed;
      }
      control.outputSuspension = OutputSuspension::Stopping;
    }
    const NativeAudioOutputProgress reconciled =
        control.output->reconcileDeviceChange();
    if (reconciled == NativeAudioOutputProgress::Quiescing) {
      return DeviceReconcile::Progressed;
    }
    if (reconciled != NativeAudioOutputProgress::Done) {
      control.latch(NativeAudioSessionFailure::Output);
      return DeviceReconcile::Failed;
    }
    // reconcileDeviceChange() proved a Done stop; finish the suspend
    // bookkeeping so the session and the output agree the device is idle.
    if (control.outputSuspension == OutputSuspension::Stopping &&
        !finishSuspend(control)) {
      return DeviceReconcile::Failed;
    }
    return DeviceReconcile::Progressed;
  }

  // The device is valid again. Resume only a freeze this reconciliation
  // caused: a user pause that happened to overlap it keeps the device idle.
  if (!control.deviceChangeResumePending) {
    return DeviceReconcile::Idle;
  }
  if (control.outputSuspension != OutputSuspension::Suspended ||
      control.requestedPaused) {
    control.deviceChangeResumePending = false;
    return DeviceReconcile::Idle;
  }
  if (!canStartOutput(control)) {
    return DeviceReconcile::Progressed;
  }
  control.renderCore.setPaused(false);
  const NativeAudioSessionProgress started = mapOutputProgress(
      control, control.output->start(), NativeAudioSessionFailure::Output);
  if (started == NativeAudioSessionProgress::Failed ||
      started == NativeAudioSessionProgress::Invalid) {
    return DeviceReconcile::Failed;
  }
  if (started != NativeAudioSessionProgress::Done) {
    return DeviceReconcile::Progressed;
  }
  control.outputSuspension = OutputSuspension::None;
  control.state = NativeAudioSessionState::Started;
  control.deviceChangeResumePending = false;
  saturatingIncrement(control.deviceChangeRecoveries);
  // Always on, and one grep-able line: a recovery that leaves no trace would
  // make device-change problems invisible. Bounded: one line per notification, and notifications are rare.
  std::fprintf(stderr,
               "WAM: audio device republished its format; native audio "
               "recovered (notifications=%llu recoveries=%llu)\n",
               static_cast<unsigned long long>(
                   control.output->facts().deviceChangeSerial),
               static_cast<unsigned long long>(control.deviceChangeRecoveries));
  std::fflush(stderr);
  return DeviceReconcile::Progressed;
}

// drain() is where a StreamFormat notification is normally decided, but one
// can land after the last drain() pass -- between a seek's activation and the
// commit's start, or inside the output's own start. Its revoked admission
// makes the output refuse to start, so an owner start decides it first.
// nullopt: no notification is outstanding and the caller starts the output.
[[nodiscard]] std::optional<NativeAudioSessionProgress>
reconcileBeforeOutputStart(NativeAudioSessionControl& control) noexcept {
  switch (reconcileOutputDeviceChange(control)) {
  case DeviceReconcile::Idle:
    return std::nullopt;
  case DeviceReconcile::Progressed:
    if (control.state == NativeAudioSessionState::Started) {
      return NativeAudioSessionProgress::Done;
    }
    if (control.output->facts().deviceChangePending) {
      return NativeAudioSessionProgress::Quiescing;
    }
    return std::nullopt;
  case DeviceReconcile::Failed:
    return NativeAudioSessionProgress::Failed;
  }
  return NativeAudioSessionProgress::Failed;
}

// close() progress in the session's own vocabulary, for stop().
[[nodiscard]] NativeAudioSessionProgress
sessionProgress(media::NativeMediaConsumerProgress progress) noexcept {
  switch (progress) {
  case media::NativeMediaConsumerProgress::Done:
    return NativeAudioSessionProgress::Done;
  case media::NativeMediaConsumerProgress::Quiescing:
  case media::NativeMediaConsumerProgress::Progress:
    return NativeAudioSessionProgress::Quiescing;
  case media::NativeMediaConsumerProgress::StaleGeneration:
  case media::NativeMediaConsumerProgress::Unsupported:
  case media::NativeMediaConsumerProgress::Failed:
    return NativeAudioSessionProgress::Failed;
  }
  return NativeAudioSessionProgress::Failed;
}

[[nodiscard]] media::NativeMediaConsumerProgress mapLifecycleProgress(
    NativeAudioSessionProgress progress) noexcept {
  switch (progress) {
  case NativeAudioSessionProgress::Done:
    return media::NativeMediaConsumerProgress::Done;
  case NativeAudioSessionProgress::Quiescing:
  case NativeAudioSessionProgress::WaitingForData:
    return media::NativeMediaConsumerProgress::Quiescing;
  case NativeAudioSessionProgress::Invalid:
  case NativeAudioSessionProgress::Failed:
    return media::NativeMediaConsumerProgress::Failed;
  }
  return media::NativeMediaConsumerProgress::Failed;
}

// A retire phase either yields the progress the caller must report or nothing,
// which means the phase completed and retire may proceed to the next one.
using RetireStep = std::optional<media::NativeMediaConsumerProgress>;

// The retire failure rule, stated once. Retiring is a state latch() leaves
// alone, but retire cannot assume it is already there: the testing seam
// NativeAudioSessionTestAccess::stageFlushAfterStop writes Flushing with no
// retire guard, so the state is re-asserted rather than inferred.
[[nodiscard]] media::NativeMediaConsumerProgress
failRetire(NativeAudioSessionControl& control,
           NativeAudioSessionFailure failure,
           media::NativeMediaConsumerProgress progress) noexcept {
  control.latch(failure);
  control.state = NativeAudioSessionState::Retiring;
  return progress;
}

[[nodiscard]] bool
clockPausable(const media::NativeMediaClockSnapshot& clock) noexcept {
  return clock.publicationCurrent && clock.valid && clock.generation != 0;
}

[[nodiscard]] bool clockPaused(const media::NativeMediaClockSnapshot& clock) noexcept {
  return clock.publicationCurrent && clock.valid && !clock.running;
}

// The clock a completed invalidation must show. Retire proves this twice --
// once where it performs the stop and once in its final audit -- so it is
// stated once and the two proofs cannot drift apart.
[[nodiscard]] bool
clockInvalidatedTo(const media::NativeMediaClockSnapshot& clock,
                   media::MediaGeneration invalidation) noexcept {
  return clock.publicationCurrent && !clock.valid && !clock.running &&
         clock.generation == invalidation;
}

[[nodiscard]] bool
converterRetired(const NativeAudioConverterStats& converter) noexcept {
  return !converter.configured && !converter.samplePrepared &&
         !converter.sampleRetained;
}

[[nodiscard]] bool
outputClosedCleanly(const NativeAudioOutputFacts& output) noexcept {
  return !output.configured && !output.started && output.stopped &&
         output.callbackQuiescent &&
         output.state == NativeAudioOutputState::Closed;
}

// Admission: a retire is legal only for the generation the graph last exposed,
// and only towards an invalidation generation strictly above every generation
// any part of the graph still holds. Admitting it parks the session -- paused,
// no lifecycle, no terminal override -- before any irreversible step runs.
[[nodiscard]] RetireStep
beginRetire(NativeAudioSessionControl& control,
            media::MediaGeneration retiredGeneration,
            media::MediaGeneration invalidationGeneration) noexcept {
  if (retiredGeneration != control.highestExposedGeneration) {
    return media::NativeMediaConsumerProgress::StaleGeneration;
  }
  const NativeAudioConverterStats converter = control.converter.stats();
  const NativeAudioOutputFacts output = control.output != nullptr
                                            ? control.output->facts()
                                            : NativeAudioOutputFacts{};
  const media::NativeMediaClockSnapshot clock = control.clock.sample();
  media::MediaGeneration highestInstalled = control.ring.generation();
  highestInstalled = std::max(highestInstalled, control.generation);
  highestInstalled = std::max(highestInstalled, converter.generation);
  highestInstalled = std::max(highestInstalled, output.generation);
  highestInstalled = std::max(highestInstalled, clock.generation);
  if (const auto* flush = std::get_if<FlushLifecycle>(&control.lifecycle)) {
    highestInstalled = std::max(highestInstalled, flush->target);
  } else if (const auto* cancel =
                 std::get_if<CancelLifecycle>(&control.lifecycle)) {
    highestInstalled = std::max(highestInstalled, cancel->target);
  }
  if (invalidationGeneration == 0 ||
      invalidationGeneration <= retiredGeneration ||
      invalidationGeneration <= highestInstalled) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  control.retirement = Retirement{retiredGeneration, invalidationGeneration,
                                  RetireStage::StopOutput};
  control.lifecycle = std::monostate{};
  control.terminalOverride.reset();
  control.requestedPaused = true;
  control.renderCore.setPaused(true);
  control.outputSuspension = OutputSuspension::None;
  control.state = NativeAudioSessionState::Retiring;
  return std::nullopt;
}

// Retire phase 1: stop the device and park the clock.
[[nodiscard]] RetireStep
retireStopOutput(NativeAudioSessionControl& control) noexcept {
  if (control.retirement->stage != RetireStage::StopOutput) {
    return std::nullopt;
  }
  if (control.output != nullptr) {
    const NativeAudioOutputProgress stopped = control.output->stop();
    if (stopped == NativeAudioOutputProgress::Quiescing) {
      return media::NativeMediaConsumerProgress::Quiescing;
    }
    if (stopped != NativeAudioOutputProgress::Done) {
      // A partially configured output can be in Detaching, where stop() is
      // intentionally invalid but close() remains the only legal progress
      // operation. Lower-layer failure may also have completed part of its
      // close sequence, so keep the exact pair retryable rather than
      // claiming an irreversible terminal failure.
      const media::NativeMediaConsumerProgress refusal =
          failRetire(control, NativeAudioSessionFailure::Output,
                     media::NativeMediaConsumerProgress::Progress);
      const NativeAudioOutputProgress closed = control.output->close();
      if (closed == NativeAudioOutputProgress::Quiescing) {
        return media::NativeMediaConsumerProgress::Quiescing;
      }
      if (closed != NativeAudioOutputProgress::Done) {
        return refusal;
      }
    }
  }

  if (control.clockActivated) {
    media::NativeMediaClockSnapshot clock = control.clock.sample();
    if (!clockPausable(clock) || !control.clock.pause(clock.generation)) {
      return failRetire(control, NativeAudioSessionFailure::ClockTransition,
                        media::NativeMediaConsumerProgress::Failed);
    }
    clock = control.clock.sample();
    if (!clockPaused(clock)) {
      return failRetire(control, NativeAudioSessionFailure::ClockTransition,
                        media::NativeMediaConsumerProgress::Failed);
    }
    if (control.output != nullptr) {
      const NativeAudioOutputFacts output = control.output->facts();
      if (output.activated && output.generation == clock.generation &&
          !control.renderCore.settlePausedAfterStop(clock.generation)) {
        return failRetire(control, NativeAudioSessionFailure::ClockTransition,
                          media::NativeMediaConsumerProgress::Failed);
      }
    }
  }
  control.retirement->stage = RetireStage::InvalidateGraph;
  return std::nullopt;
}

// Retire phase 2: move the ring and clock to the invalidation generation and
// give up the converter.
[[nodiscard]] RetireStep
retireInvalidateGraph(NativeAudioSessionControl& control) noexcept {
  if (control.retirement->stage != RetireStage::InvalidateGraph) {
    return std::nullopt;
  }
  const media::MediaGeneration invalidation =
      control.retirement->invalidation;
  if (control.ring.generation() != invalidation &&
      !control.ring.flush(invalidation)) {
    return failRetire(control, NativeAudioSessionFailure::RingTransition,
                      media::NativeMediaConsumerProgress::Failed);
  }

  if (control.clockActivated) {
    const media::NativeMediaClockSnapshot clock = control.clock.sample();
    if (clock.generation != invalidation &&
        (!clock.valid || clock.generation == 0 ||
         !control.clock.stop(clock.generation, invalidation))) {
      return failRetire(control, NativeAudioSessionFailure::ClockTransition,
                        media::NativeMediaConsumerProgress::Failed);
    }
    if (!clockInvalidatedTo(control.clock.sample(), invalidation)) {
      return failRetire(control, NativeAudioSessionFailure::ClockTransition,
                        media::NativeMediaConsumerProgress::Failed);
    }
  }

  control.renderCore.clearTerminal(control.generation);
  control.converter.close();
  if (!converterRetired(control.converter.stats())) {
    return failRetire(control, NativeAudioSessionFailure::Converter,
                      media::NativeMediaConsumerProgress::Failed);
  }
  control.endOfStreamRequested = false;
  control.terminalPublished = false;
  // Nothing compares CloseOutput, and that IS its effect: both stage guards
  // above fail once it is set, so a retry re-runs only the close-and-audit
  // tail, which is the only part of retire that is idempotent.
  control.retirement->stage = RetireStage::CloseOutput;
  return std::nullopt;
}

// Retire phase 3: close the device and prove it closed.
[[nodiscard]] RetireStep
retireCloseOutput(NativeAudioSessionControl& control) noexcept {
  if (control.output == nullptr) {
    return std::nullopt;
  }
  const NativeAudioOutputProgress closed = control.output->close();
  if (closed == NativeAudioOutputProgress::Quiescing) {
    return media::NativeMediaConsumerProgress::Quiescing;
  }
  if (closed != NativeAudioOutputProgress::Done ||
      !outputClosedCleanly(control.output->facts())) {
    return failRetire(control, NativeAudioSessionFailure::Output,
                      media::NativeMediaConsumerProgress::Progress);
  }
  return std::nullopt;
}

// Retire phase 4: the audit that admits Done. Nothing here may make progress;
// it only proves the graph holds nothing from the retired generation.
[[nodiscard]] RetireStep
retireAuditQuiesced(NativeAudioSessionControl& control) noexcept {
  const media::MediaGeneration invalidation =
      control.retirement->invalidation;
  if (control.ring.generation() != invalidation ||
      control.ring.queuedSlabs() != 0 ||
      !converterRetired(control.converter.stats())) {
    return failRetire(control, NativeAudioSessionFailure::ConsumerProtocol,
                      media::NativeMediaConsumerProgress::Failed);
  }
  if (control.clockActivated &&
      !clockInvalidatedTo(control.clock.sample(), invalidation)) {
    return failRetire(control, NativeAudioSessionFailure::ClockTransition,
                      media::NativeMediaConsumerProgress::Failed);
  }
  return std::nullopt;
}

} // namespace

NativeAudioSession::NativeAudioSession(
    std::shared_ptr<NativeAudioSessionControl> control) noexcept
    : control_(std::move(control)) {}

std::unique_ptr<NativeAudioSession> NativeAudioSession::create(
    media::MediaGeneration initialGeneration,
    NativeAudioSessionDependencies dependencies) noexcept {
  if (initialGeneration == 0 || !validDependencies(dependencies)) {
    saturatingAdd(gRejectedCreates, 1);
    return {};
  }
  drainQuarantine();
  {
    std::lock_guard<std::mutex> lock(gSessionMutex);
    // The envelope is full when N sessions are already charged against it,
    // live or quarantined. Refuse quietly: an N+1'th AudioUnit graph would
    // overrun the per-process resource accounting that
    // kMaximumConcurrentPlayerWindows exists to bound, and the owner is meant
    // to report "no more windows" rather than retry.
    if (gRetainedSessions >= kMaximumConcurrentPlayerWindows) {
      saturatingAdd(gRejectedCreates, 1);
      return {};
    }
    ++gRetainedSessions;
  }

  try {
    auto control = std::make_shared<NativeAudioSessionControl>(
        initialGeneration, std::move(dependencies.externalLifetime),
        dependencies.hostClock, dependencies.outputCalls,
        dependencies.outputWake, std::move(dependencies.converterBackend));
    return std::unique_ptr<NativeAudioSession>(
        new NativeAudioSession(std::move(control)));
  } catch (...) {
    // No control block exists, so nothing is charged: hand the reserved slot
    // straight back instead of leaving a permanent hole in the envelope.
    std::lock_guard<std::mutex> lock(gSessionMutex);
    --gRetainedSessions;
    saturatingAdd(gRejectedCreates, 1);
    return {};
  }
}

NativeAudioSession::~NativeAudioSession() {
  if (control_ == nullptr) {
    return;
  }
  if (close() != media::NativeMediaConsumerProgress::Done) {
    quarantine(control_);
  }
  control_.reset();
}

// A graph is quarantined because a device callback was still inside it when
// its owner let go. Once that callback has exited, nothing else would ever
// finish its close, and it would hold its envelope slot for the life of the
// process. So each create() takes every quarantined graph out of the registry
// and gives it one close attempt as a fresh owner; one still quiescing goes
// straight back (the registry is empty while this runs, so it always fits).
// The envelope count is unchanged throughout: the charge stays until a graph
// proves a Done close.
void NativeAudioSession::drainQuarantine() noexcept {
  SessionQuarantine held;
  {
    std::lock_guard<std::mutex> lock(gSessionMutex);
    held.swap(gSessionQuarantine);
  }
  for (std::shared_ptr<NativeAudioSessionControl>& control : held) {
    if (control != nullptr) {
      saturatingAdd(gQuarantineRecoveries, 1);
      NativeAudioSession owner(std::move(control));
    }
  }
}

NativeAudioSessionQuarantineFacts
NativeAudioSession::quarantineFacts() noexcept {
  NativeAudioSessionQuarantineFacts result;
  result.rejectedCreates = gRejectedCreates.load(std::memory_order_relaxed);
  result.transfers =
      gQuarantineTransfers.load(std::memory_order_relaxed);
  result.recoveries =
      gQuarantineRecoveries.load(std::memory_order_relaxed);
  std::lock_guard<std::mutex> lock(gSessionMutex);
  // claimed means "the envelope is holding at least one session"; quarantined
  // means "at least one slot is occupied", i.e. there is still a graph the
  // owner must drive to Done.
  // Neither reports occupancy, because callers act by looping recovery rather
  // than by counting.
  result.claimed = gRetainedSessions != 0;
  result.quarantined =
      std::any_of(gSessionQuarantine.begin(), gSessionQuarantine.end(),
                  [](const std::shared_ptr<NativeAudioSessionControl>& slot) {
                    return slot != nullptr;
                  });
  return result;
}

bool NativeAudioSession::resetRejectedConfiguration(
    media::MediaGeneration generation) noexcept {
  if (!control_ || control_->generation != generation || control_->configured ||
      (control_->state != NativeAudioSessionState::Failed &&
       control_->state != NativeAudioSessionState::Unsupported)) return false;
  NativeAudioSessionDependencies dependencies;
  dependencies.externalLifetime = control_->externalLifetime;
  dependencies.hostClock = control_->hostClock;
  dependencies.outputCalls = control_->outputCalls;
  dependencies.outputWake = control_->outputWake;
  const auto gain = control_->requestedGain;
  const auto muted = control_->requestedMuted;
  const auto rate = control_->requestedRate;
  const auto preservePitch = control_->requestedPreservePitch;
  // No successful configure, sample submission or output start precedes this
  // replacement. A quiescing close keeps its graph for terminal retirement.
  if (close() != media::NativeMediaConsumerProgress::Done) return false;
  auto replacement = create(generation, std::move(dependencies));
  if (!replacement) return false;
  control_.swap(replacement->control_);
  static_cast<void>(setGain(gain));
  static_cast<void>(setMuted(muted));
  static_cast<void>(setRate(rate, preservePitch));
  return true;
}

media::NativeMediaConsumeResult NativeAudioSession::configure(
    const media::MediaTrackDescriptor& track,
    media::MediaGeneration generation,
    const media::NativeMediaGenerationTimeline& timeline,
    std::string* error) {
  if (control_ == nullptr) {
    assignError(error, "native audio session is unavailable");
    return media::NativeMediaConsumeResult::Failed;
  }
  NativeAudioSessionControl& control = *control_;
  if (generation != control.generation) {
    return media::NativeMediaConsumeResult::StaleGeneration;
  }
  if (control.state != NativeAudioSessionState::Fresh) {
    assignError(error, "native audio session configure is not fresh");
    return media::NativeMediaConsumeResult::Failed;
  }
  // A configure call exposes its generation even when pure preflight rejects
  // it or a later resource step fails. Router retirement must name that exact
  // generation; a never-called port alone retains exposure zero.
  control.highestExposedGeneration = generation;

  const std::optional<TimelinePlan> plan =
      preflight(track, generation, timeline);
  if (!plan) {
    control.state = NativeAudioSessionState::Unsupported;
    assignError(error, "audio track or timeline is outside native v1");
    return media::NativeMediaConsumeResult::Unsupported;
  }

  control.state = NativeAudioSessionState::Configuring;
  control.resourceEntered = true;
  clearOutputWake(control);
  control.output = NativeAudioOutput::create(
      control.renderCore, control.outputCalls, control.outputWake);
  if (control.output == nullptr) {
    control.latch(NativeAudioSessionFailure::OutputUnavailable);
    assignError(error, "native audio output is unavailable");
    return media::NativeMediaConsumeResult::Failed;
  }

  if (!control.converter.configure(track, generation, plan->converter,
                                   error)) {
    control.latch(NativeAudioSessionFailure::ConverterConfiguration);
    return media::NativeMediaConsumeResult::Failed;
  }
  if (!control.clock.anchor(generation, plan->clockPosition, {}, false)) {
    control.latch(NativeAudioSessionFailure::ClockActivation);
    assignError(error, "native audio clock activation failed");
    return media::NativeMediaConsumeResult::Failed;
  }
  control.clockActivated = true;

  control.renderCore.setPaused(true);
  // The callback controls already exist in Fresh. Re-publish the cached pair
  // at the resource boundary so configure can never replace a preflight UI
  // request with hard-coded defaults. This is not a new owner request and
  // therefore does not mint a control revision.
  control.renderCore.setGain(control.requestedGain);
  control.renderCore.setMuted(control.requestedMuted);
  const NativeAudioOutputProgress outputConfigured =
      control.output->configure({generation, 0, plan->mediaOrigin,
                                 control.hostClock.ticksPerSecond,
                                 plan->sampleRate,
                                 plan->clockPosition,
                                 plan->declaredSilence});
  // The stream rate is known only from here on, so a cached non-unit rate can
  // only now be turned into a real stretch stage. A refusal drops back to the
  // unit rate rather than failing the whole configure: playing at 1x is a
  // better outcome than not playing.
  if (outputConfigured == NativeAudioOutputProgress::Done) {
    // The preference is republished unconditionally, exactly like the cached
    // gain/mute pair: it cannot fail, and at the unit rate it applies nothing.
    control.output->setPreservePitch(control.requestedPreservePitch);
    if (!control.requestedRate.unity() &&
        !control.output->setRate(control.requestedRate)) {
      control.requestedRate = media::NativePlaybackRate{};
    }
  }
  if (outputConfigured != NativeAudioOutputProgress::Done) {
    control.latch(NativeAudioSessionFailure::OutputConfiguration);
    assignError(error, "native audio output configuration failed");
    return media::NativeMediaConsumeResult::Failed;
  }

  control.track = track.id;
  control.active = *plan;
  control.firstAudioSampleAccepted = false;
  control.configured = true;
  control.requestedPaused = true;
  control.state = NativeAudioSessionState::Ready;
  return media::NativeMediaConsumeResult::Accepted;
}

media::NativeMediaConsumeResult NativeAudioSession::capacity(
    media::MediaGeneration generation) {
  if (control_ == nullptr) {
    return media::NativeMediaConsumeResult::Failed;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);
  if (generation != control.generation) {
    return media::NativeMediaConsumeResult::StaleGeneration;
  }
  if (!control.configured || !acceptsWork(control.state) ||
      outputFailed(control)) {
    return media::NativeMediaConsumeResult::Failed;
  }
  if (control.endOfStreamRequested) {
    return terminalObserved(control)
               ? media::NativeMediaConsumeResult::Drained
               : media::NativeMediaConsumeResult::Backpressure;
  }
  return mapPumpForConsume(control, control.converter.pump(nullptr), false);
}

media::NativeMediaConsumeResult NativeAudioSession::trySample(
    media::NativeMediaSampleDelivery& delivery,
    std::string* error) {
  if (control_ == nullptr) {
    return media::NativeMediaConsumeResult::Failed;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);
  const media::MediaSample& sample = delivery.sample();
  if (sample.generation != control.generation) {
    return media::NativeMediaConsumeResult::StaleGeneration;
  }
  if (!control.configured || control.endOfStreamRequested ||
      !acceptsWork(control.state) || outputFailed(control)) {
    assignError(error, "native audio session is not accepting samples");
    return media::NativeMediaConsumeResult::Failed;
  }

  if (sample.track != control.track ||
      sample.kind != media::MediaSampleKind::EncodedAudio) {
    control.latch(NativeAudioSessionFailure::Converter);
    assignError(error, "sample is not for the configured audio track");
    return media::NativeMediaConsumeResult::Failed;
  }
  if (!control.firstAudioSampleAccepted &&
      media::compareMediaTime(sample.presentationTime,
                              control.active.decodeStart) !=
          media::MediaTimeOrder::Equal) {
    control.latch(NativeAudioSessionFailure::ConsumerProtocol);
    assignError(error,
                "first audio sample does not match source-proved decode start");
    return media::NativeMediaConsumeResult::Failed;
  }

  NativeAudioPrepareOutcome prepared = control.converter.prepare(sample, error);
  switch (prepared.result) {
  case NativeAudioSubmitResult::Backpressure:
    return media::NativeMediaConsumeResult::Backpressure;
  case NativeAudioSubmitResult::StaleGeneration:
    return media::NativeMediaConsumeResult::StaleGeneration;
  case NativeAudioSubmitResult::Invalid:
  case NativeAudioSubmitResult::Failed:
    control.latch(NativeAudioSessionFailure::Converter);
    return media::NativeMediaConsumeResult::Failed;
  case NativeAudioSubmitResult::Accepted:
    break;
  }

  media::MediaSample owned = delivery.take();
  if (!control.converter.commitPrepared(std::move(prepared.prepared),
                                        std::move(owned))) {
    control.latch(NativeAudioSessionFailure::ConsumerProtocol);
    return media::NativeMediaConsumeResult::Accepted;
  }
  control.firstAudioSampleAccepted = true;
  const NativeAudioPumpResult pumped = control.converter.pump(error);
  if (pumped == NativeAudioPumpResult::Published) {
    static_cast<void>(verifyPublishedOrigin(control));
  } else if (pumped == NativeAudioPumpResult::Failed ||
             pumped == NativeAudioPumpResult::NotConfigured) {
    control.latch(NativeAudioSessionFailure::Converter);
  } else if (pumped == NativeAudioPumpResult::StaleGeneration) {
    control.latch(NativeAudioSessionFailure::ConsumerProtocol);
  }
  return media::NativeMediaConsumeResult::Accepted;
}

media::NativeMediaConsumeResult NativeAudioSession::discontinuity(
    const media::MediaDiscontinuity& discontinuity,
    std::string* error) {
  if (control_ == nullptr) {
    return media::NativeMediaConsumeResult::Failed;
  }
  NativeAudioSessionControl& control = *control_;
  if (control.retirement.has_value()) {
    return media::NativeMediaConsumeResult::Failed;
  }
  if (discontinuity.generation != control.generation) {
    return media::NativeMediaConsumeResult::StaleGeneration;
  }
  control.latch(NativeAudioSessionFailure::Discontinuity);
  assignError(error, "audio discontinuities are outside native v1");
  return media::NativeMediaConsumeResult::Failed;
}

media::NativeMediaConsumeResult NativeAudioSession::endOfStream(
    const media::MediaEndOfStream& end,
    std::string* error) {
  if (control_ == nullptr) {
    return media::NativeMediaConsumeResult::Failed;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);
  if (end.generation != control.generation) {
    return media::NativeMediaConsumeResult::StaleGeneration;
  }
  if (!control.configured ||
      end.track != control.track ||
      control.state == NativeAudioSessionState::Failed ||
      control.state == NativeAudioSessionState::Retiring ||
      outputFailed(control)) {
    control.latch(NativeAudioSessionFailure::ConsumerProtocol);
    return media::NativeMediaConsumeResult::Failed;
  }
  control.endOfStreamRequested = true;
  return mapPumpForConsume(
      control, control.converter.endOfStream(end.generation, error), true);
}

media::NativeMediaConsumerProgress NativeAudioSession::drain(
    media::MediaGeneration generation,
    std::string* error) {
  if (control_ == nullptr) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);
  if (generation != control.generation) {
    return media::NativeMediaConsumerProgress::StaleGeneration;
  }
  if (!control.configured || !acceptsWork(control.state)) {
    publishFailureText(control, error);
    return media::NativeMediaConsumerProgress::Failed;
  }
  // The dispatcher pumps drain() on every wake, and the StreamFormat listener
  // signals exactly that wake, so this is the seam where an outstanding device
  // notification is decided. It runs before outputFailed() because it is what
  // decides whether there is a failure at all.
  switch (reconcileOutputDeviceChange(control)) {
  case DeviceReconcile::Idle:
    break;
  case DeviceReconcile::Progressed:
    return media::NativeMediaConsumerProgress::Progress;
  case DeviceReconcile::Failed:
    publishFailureText(control, error);
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (outputFailed(control)) {
    publishFailureText(control, error);
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (terminalObserved(control)) {
    return media::NativeMediaConsumerProgress::Done;
  }
  return mapPumpForDrain(control, control.converter.pump(error));
}

NativeAudioSessionProgress NativeAudioSession::start() noexcept {
  if (control_ == nullptr) {
    return NativeAudioSessionProgress::Invalid;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);
  if (control.state == NativeAudioSessionState::Started &&
      control.outputSuspension == OutputSuspension::None) {
    return NativeAudioSessionProgress::Done;
  }
  // A suspend that has begun already stopped the device; finish its proof
  // before reopening admission, or start() would reopen over an unsettled
  // callback-local running fact. This runs before the state gate below
  // because a suspend in flight still reports Started.
  if (control.outputSuspension == OutputSuspension::Stopping &&
      control.output != nullptr) {
    const NativeAudioSessionProgress settled = completeOutputSuspend(control);
    if (settled != NativeAudioSessionProgress::Done) {
      return settled;
    }
  }
  if (control.state != NativeAudioSessionState::Ready ||
      control.output == nullptr) {
    return NativeAudioSessionProgress::Invalid;
  }
  if (const auto decided = reconcileBeforeOutputStart(control)) {
    return *decided;
  }
  if (outputFailed(control)) {
    return NativeAudioSessionProgress::Failed;
  }
  if (!control.requestedPaused && !canStartOutput(control)) {
    return NativeAudioSessionProgress::WaitingForData;
  }
  control.renderCore.setPaused(control.requestedPaused);
  const NativeAudioSessionProgress result = mapOutputProgress(
      control, control.output->start(), NativeAudioSessionFailure::Output);
  if (result == NativeAudioSessionProgress::Done) {
    control.state = NativeAudioSessionState::Started;
    control.outputSuspension = OutputSuspension::None;
  }
  return result;
}

NativeAudioSessionProgress
NativeAudioSession::setPaused(bool paused) noexcept {
  if (control_ == nullptr) {
    return NativeAudioSessionProgress::Invalid;
  }
  NativeAudioSessionControl& control = *control_;
  if ((control.state != NativeAudioSessionState::Ready &&
       control.state != NativeAudioSessionState::Started)) {
    return NativeAudioSessionProgress::Invalid;
  }
  if (outputFailed(control)) {
    return NativeAudioSessionProgress::Failed;
  }
  // A suspend that has begun owns the output until it is Done, in either
  // direction: the device is already stopped and admission already revoked,
  // so a resume that skipped this would unpause a render core that can never
  // be entered again.
  if (control.outputSuspension == OutputSuspension::Stopping &&
      control.output != nullptr) {
    const NativeAudioSessionProgress settled = completeOutputSuspend(control);
    if (settled != NativeAudioSessionProgress::Done) {
      return settled;
    }
  }
  control.requestedPaused = paused;
  control.renderCore.setPaused(paused);
  if (paused) {
    // Ready covers both a never-started output and a suspended one. In the
    // suspended case the clock is already paused, so this is the idempotent
    // early return in NativeMediaClock::pause().
    if (control.state == NativeAudioSessionState::Ready &&
        !control.clock.pause(control.generation)) {
      control.latch(NativeAudioSessionFailure::ClockTransition);
      return NativeAudioSessionProgress::Failed;
    }
    return NativeAudioSessionProgress::Done;
  }
  if (control.outputSuspension == OutputSuspension::Suspended) {
    if (control.output == nullptr) {
      control.latch(NativeAudioSessionFailure::Output);
      return NativeAudioSessionProgress::Failed;
    }
    if (const auto decided = reconcileBeforeOutputStart(control)) {
      return *decided;
    }
    // The suspend never flushed the ring, so this holds immediately for any
    // pause that did not empty it.
    if (!canStartOutput(control)) {
      return NativeAudioSessionProgress::WaitingForData;
    }
    const NativeAudioSessionProgress started = mapOutputProgress(
        control, control.output->start(), NativeAudioSessionFailure::Output);
    if (started != NativeAudioSessionProgress::Done) {
      return started;
    }
    control.outputSuspension = OutputSuspension::None;
    control.state = NativeAudioSessionState::Started;
  }
  return NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress
NativeAudioSession::suspendOutputForPause() noexcept {
  if (control_ == nullptr) {
    return NativeAudioSessionProgress::Invalid;
  }
  NativeAudioSessionControl& control = *control_;
  if (control.outputSuspension == OutputSuspension::Suspended) {
    return NativeAudioSessionProgress::Done;
  }
  if (control.output == nullptr || !control.requestedPaused ||
      control.retirement.has_value() ||
      !std::holds_alternative<std::monostate>(control.lifecycle) ||
      control.terminalOverride.has_value() ||
      control.state != NativeAudioSessionState::Started) {
    return NativeAudioSessionProgress::Invalid;
  }
  if (outputFailed(control)) {
    return NativeAudioSessionProgress::Failed;
  }
  // The pause must already be settled on the authoritative clock. The render
  // callback's own pause boundary is what publishes that, and it is the whole
  // reason this transition cannot move the playhead: with the clock already
  // paused, the clock.pause() inside settleStopped() takes NativeMediaClock's
  // !running early return, publishing nothing and moving nothing. Suspending
  // before the boundary would be equally exact but would freeze the clock up
  // to one device period earlier than an in-place pause does.
  const media::NativeMediaClockSnapshot clock = control.clock.sample();
  if (!clockPaused(clock) || clock.generation != control.generation) {
    return NativeAudioSessionProgress::Invalid;
  }
  control.outputSuspension = OutputSuspension::Stopping;
  return completeOutputSuspend(control);
}

NativeAudioSessionProgress NativeAudioSession::setGain(float gain) noexcept {
  if (control_ == nullptr) {
    return NativeAudioSessionProgress::Invalid;
  }
  NativeAudioSessionControl& control = *control_;
  if (!acceptsAudioControls(control.state)) {
    return NativeAudioSessionProgress::Invalid;
  }

  control.requestedGain = normalizedGain(gain);
  saturatingIncrement(control.controlRevision);
  control.renderCore.setGain(control.requestedGain);
  return NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress NativeAudioSession::setRate(
    media::NativePlaybackRate rate, bool preservePitch) noexcept {
  if (control_ == nullptr || !rate.valid()) {
    return NativeAudioSessionProgress::Invalid;
  }
  NativeAudioSessionControl& control = *control_;
  if (!acceptsAudioControls(control.state)) {
    return NativeAudioSessionProgress::Invalid;
  }
  // Before configure there is no output to create a stretch unit against, so
  // the request is merely cached; configure re-publishes it exactly the way
  // it re-publishes the cached gain/mute pair.
  // Pitch is published first and cached unconditionally: it cannot fail, and
  // doing it first means the callback never latches the new rate while the
  // old preference is still in force. A refused rate therefore leaves the
  // previous rate running at the newly requested pitch behaviour, which is
  // the only combination that is true of what the engine is doing.
  control.requestedPreservePitch = preservePitch;
  if (control.output != nullptr) {
    control.output->setPreservePitch(preservePitch);
    if (!control.output->setRate(rate)) {
      return NativeAudioSessionProgress::Invalid;
    }
  }
  control.requestedRate = rate;
  saturatingIncrement(control.controlRevision);
  return NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress NativeAudioSession::setMuted(bool muted) noexcept {
  if (control_ == nullptr) {
    return NativeAudioSessionProgress::Invalid;
  }
  NativeAudioSessionControl& control = *control_;
  if (!acceptsAudioControls(control.state)) {
    return NativeAudioSessionProgress::Invalid;
  }

  control.requestedMuted = muted;
  saturatingIncrement(control.controlRevision);
  control.renderCore.setMuted(control.requestedMuted);
  return NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress NativeAudioSession::stop() noexcept {
  if (control_ == nullptr) {
    return NativeAudioSessionProgress::Invalid;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);
  if (control.retirement.has_value()) {
    return NativeAudioSessionProgress::Invalid;
  }
  if (control.terminalOverride &&
      control.terminalOverride->kind == TerminalOverride::Kind::Stop) {
    if (control.terminalOverride->generation != control.generation) {
      return NativeAudioSessionProgress::Invalid;
    }
    if (control.closeDone || control.state == NativeAudioSessionState::Closed) {
      return NativeAudioSessionProgress::Done;
    }
    return sessionProgress(close());
  }
  // state Flushing is only ever written together with lifecycle Flush, and
  // latch() may overwrite it with Failed, so the lifecycle is the fact.
  if (std::holds_alternative<FlushLifecycle>(control.lifecycle)) {
    control.terminalOverride =
        TerminalOverride{TerminalOverride::Kind::Stop, control.generation};
    return sessionProgress(close());
  }
  if (control.state == NativeAudioSessionState::Cancelled) {
    return NativeAudioSessionProgress::Done;
  }
  if ((control.state != NativeAudioSessionState::Ready &&
       control.state != NativeAudioSessionState::Started &&
       control.state != NativeAudioSessionState::Stopping) ||
      control.output == nullptr) {
    return NativeAudioSessionProgress::Invalid;
  }
  control.requestedPaused = true;
  control.renderCore.setPaused(true);
  control.state = NativeAudioSessionState::Stopping;
  const NativeAudioSessionProgress result = mapOutputProgress(
      control, control.output->stop(), NativeAudioSessionFailure::Output);
  if (result == NativeAudioSessionProgress::Done) {
    if (!settleStopped(control, control.generation)) {
      return NativeAudioSessionProgress::Failed;
    }
    control.state = NativeAudioSessionState::Ready;
    // An owner-requested stop supersedes a pause suspend: the resume path
    // back from here is the owner's own start(), not setPaused(false).
    control.outputSuspension = OutputSuspension::None;
  }
  return result;
}

media::NativeMediaConsumerProgress NativeAudioSession::flush(
    media::MediaGeneration retiredGeneration,
    media::MediaGeneration nextGeneration,
    const media::NativeMediaGenerationTimeline& timeline) noexcept {
  if (control_ == nullptr) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);
  if (control.retirement.has_value()) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (nextGeneration != 0 && nextGeneration > retiredGeneration &&
      nextGeneration > control.highestExposedGeneration) {
    // flush() itself exposes the target before returning any outcome.
    control.highestExposedGeneration = nextGeneration;
  }
  if (control.state == NativeAudioSessionState::Closing ||
      control.state == NativeAudioSessionState::Closed ||
      control.state == NativeAudioSessionState::Stopping ||
      control.state == NativeAudioSessionState::Cancelling ||
      control.state == NativeAudioSessionState::Cancelled) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (control.completedFlushRetired == retiredGeneration &&
      control.completedFlushTarget == nextGeneration &&
      control.active.timeline == timeline &&
      control.generation == nextGeneration) {
    return media::NativeMediaConsumerProgress::Done;
  }
  if (const auto* pending = std::get_if<FlushLifecycle>(&control.lifecycle)) {
    if (pending->retired != retiredGeneration ||
        pending->target != nextGeneration ||
        pending->plan.timeline != timeline) {
      return media::NativeMediaConsumerProgress::StaleGeneration;
    }
  } else {
    if (!std::holds_alternative<std::monostate>(control.lifecycle) ||
        !control.configured ||
        control.state == NativeAudioSessionState::Failed ||
        retiredGeneration != control.generation || nextGeneration == 0 ||
        nextGeneration <= retiredGeneration) {
      return retiredGeneration != control.generation
                 ? media::NativeMediaConsumerProgress::StaleGeneration
                 : media::NativeMediaConsumerProgress::Failed;
    }
    const std::optional<TimelinePlan> plan = timelinePlanFor(
        nextGeneration, timeline, control.active.sampleRate,
        control.active.audioMayPrecedeStreamOrigin,
        control.active.converter.trimAfterCeiling,
        control.active.converter.presentationCeiling);
    if (!plan) {
      control.latch(NativeAudioSessionFailure::ClockTransition);
      return media::NativeMediaConsumerProgress::Failed;
    }
    control.lifecycle = FlushLifecycle{FlushStage::Stop, retiredGeneration,
                                       nextGeneration, *plan};
    control.firstAudioSampleAccepted = false;
    control.requestedPaused = true;
    control.renderCore.setPaused(true);
    // The flush owns render admission from here: it quiesces, re-anchors and
    // re-activates it, so a pause suspend can no longer be the thing that
    // resumes it.
    control.outputSuspension = OutputSuspension::None;
    control.state = NativeAudioSessionState::Flushing;
  }

  FlushLifecycle& flush = std::get<FlushLifecycle>(control.lifecycle);
  if (flush.stage == FlushStage::Stop) {
    const NativeAudioSessionProgress stopped = mapOutputProgress(
        control, control.output->quiesceForSeek(), NativeAudioSessionFailure::Output);
    if (stopped != NativeAudioSessionProgress::Done) {
      return mapLifecycleProgress(stopped);
    }
    if (!settleStopped(control, flush.retired)) {
      return media::NativeMediaConsumerProgress::Failed;
    }
    flush.stage = FlushStage::Reset;
  }

  if (flush.stage == FlushStage::Reset) {
    if (!control.ring.flush(flush.target)) {
      control.latch(NativeAudioSessionFailure::RingTransition);
      return media::NativeMediaConsumerProgress::Failed;
    }
    if (!control.clock.seek(flush.retired,
                            flush.target,
                            flush.plan.clockPosition)) {
      control.latch(NativeAudioSessionFailure::ClockTransition);
      return media::NativeMediaConsumerProgress::Failed;
    }
    if (!control.converter.flush(flush.target,
                                 flush.plan.converter)) {
      control.latch(NativeAudioSessionFailure::Converter);
      return media::NativeMediaConsumerProgress::Failed;
    }
    control.renderCore.setPaused(true);
    flush.stage = FlushStage::Activate;
  }

  const NativeAudioSessionProgress activated = mapOutputProgress(
      control,
      control.output->activate(flush.target, 0,
                               flush.plan.mediaOrigin,
                               flush.plan.clockPosition,
                               flush.plan.declaredSilence),
      NativeAudioSessionFailure::OutputActivation);
  if (activated != NativeAudioSessionProgress::Done) {
    return mapLifecycleProgress(activated);
  }

  control.completedFlushRetired = flush.retired;
  control.completedFlushTarget = flush.target;
  control.generation = flush.target;
  control.active = flush.plan;
  control.firstAudioSampleAccepted = false;
  control.endOfStreamRequested = false;
  control.terminalPublished = false;
  control.lifecycle = std::monostate{};
  control.state = NativeAudioSessionState::Ready;
  return media::NativeMediaConsumerProgress::Done;
}

media::NativeMediaConsumerProgress NativeAudioSession::cancel(
    media::MediaGeneration generation) noexcept {
  if (control_ == nullptr) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);
  if (control.retirement.has_value()) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (generation != control.generation) {
    return media::NativeMediaConsumerProgress::StaleGeneration;
  }
  if (control.terminalOverride &&
      control.terminalOverride->kind == TerminalOverride::Kind::Cancel) {
    if (generation != control.terminalOverride->generation) {
      return media::NativeMediaConsumerProgress::StaleGeneration;
    }
    return close();
  }
  if (std::holds_alternative<FlushLifecycle>(control.lifecycle)) {
    // A terminal cancellation supersedes a reversible seek flush. The graph
    // may already be split across retired/target generations, so the only
    // exact result is fail-closed teardown, never resuming Reset/Activate.
    control.terminalOverride =
        TerminalOverride{TerminalOverride::Kind::Cancel, generation};
    return close();
  }
  if (control.state == NativeAudioSessionState::Cancelled &&
      control.cancelledGeneration == generation) {
    return media::NativeMediaConsumerProgress::Done;
  }
  if (std::holds_alternative<FlushLifecycle>(control.lifecycle)) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (control.state == NativeAudioSessionState::Failed ||
      control.state == NativeAudioSessionState::Closing ||
      control.state == NativeAudioSessionState::Closed) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  control.lifecycle = CancelLifecycle{generation};
  control.requestedPaused = true;
  control.renderCore.setPaused(true);
  control.outputSuspension = OutputSuspension::None;
  control.state = NativeAudioSessionState::Cancelling;
  const NativeAudioSessionProgress stopped = mapOutputProgress(
      control, control.output->stop(), NativeAudioSessionFailure::Output);
  if (stopped != NativeAudioSessionProgress::Done) {
    return mapLifecycleProgress(stopped);
  }
  if (!settleStopped(control, generation)) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  control.converter.cancel(generation);
  if (control.converter.stats().configured) {
    control.renderCore.clearTerminal(generation);
    control.endOfStreamRequested = false;
    control.terminalPublished = false;
    control.firstAudioSampleAccepted = false;
    control.active.decodeStart = {};
    control.cancelledGeneration = generation;
    control.lifecycle = std::monostate{};
    control.state = NativeAudioSessionState::Cancelled;
    return media::NativeMediaConsumerProgress::Done;
  }
  control.latch(NativeAudioSessionFailure::Converter);
  return media::NativeMediaConsumerProgress::Failed;
}

media::NativeMediaConsumerProgress NativeAudioSession::retire(
    media::MediaGeneration retiredGeneration,
    media::MediaGeneration invalidationGeneration) noexcept {
  if (control_ == nullptr) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);

  if (control.retirement.has_value()) {
    if (retiredGeneration != control.retirement->retired ||
        invalidationGeneration != control.retirement->invalidation) {
      return media::NativeMediaConsumerProgress::StaleGeneration;
    }
    if (control.retirement->stage == RetireStage::Done) {
      return media::NativeMediaConsumerProgress::Done;
    }
  } else if (const RetireStep admission =
                 beginRetire(control, retiredGeneration,
                             invalidationGeneration)) {
    return *admission;
  }

  if (const RetireStep step = retireStopOutput(control)) {
    return *step;
  }
  if (const RetireStep step = retireInvalidateGraph(control)) {
    return *step;
  }
  if (const RetireStep step = retireCloseOutput(control)) {
    return *step;
  }
  if (const RetireStep step = retireAuditQuiesced(control)) {
    return *step;
  }

  const media::MediaGeneration invalidation =
      control.retirement->invalidation;
  control.output.reset();
  control.generation = invalidation;
  control.configured = false;
  control.firstAudioSampleAccepted = false;
  control.active.decodeStart = {};
  control.retirement->stage = RetireStage::Done;
  control.state = NativeAudioSessionState::Closed;
  releaseClaim(control);
  return media::NativeMediaConsumerProgress::Done;
}

const std::string& NativeAudioSession::failureText() const noexcept {
  static const std::string none;
  return control_ == nullptr ? none : control_->failureText;
}

media::NativeMediaConsumerProgress NativeAudioSession::close() noexcept {
  if (control_ == nullptr) {
    return media::NativeMediaConsumerProgress::Done;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);
  // Emergency close remains memory-safe but never mints or completes Router
  // retirement proof. If an exact retirement is already latched, keep its
  // public pair/facts intact while performing the same quarantine-safe tear
  // down.
  if (control.closeDone ||
      (control.state == NativeAudioSessionState::Closed &&
       !retirementDone(control))) {
    return media::NativeMediaConsumerProgress::Done;
  }
  control.state = NativeAudioSessionState::Closing;
  // Close has absolute precedence over every reversible operation. An older
  // quiescing flush/cancel can never resume Reset/Activate after this point.
  control.lifecycle = std::monostate{};
  control.requestedPaused = true;
  control.renderCore.setPaused(true);
  control.outputSuspension = OutputSuspension::None;
#if defined(WAM_NATIVE_TEST_SEAMS)
  if (control.forceCloseQuiescing) {
    return media::NativeMediaConsumerProgress::Quiescing;
  }
#endif
  if (control.output != nullptr) {
    const NativeAudioSessionProgress closed = mapOutputProgress(
        control, control.output->close(), NativeAudioSessionFailure::Output);
    if (closed != NativeAudioSessionProgress::Done) {
      control.state = NativeAudioSessionState::Closing;
      return mapLifecycleProgress(closed);
    }
  }
  if (control.configured) {
    static_cast<void>(settleStopped(control, control.generation));
  }
  control.converter.close();
  control.output.reset();
  control.configured = false;
  control.firstAudioSampleAccepted = false;
  control.active.decodeStart = {};
  control.closeDone = true;
  control.lifecycle = std::monostate{};
  control.state = NativeAudioSessionState::Closed;
  releaseClaim(control);
  return media::NativeMediaConsumerProgress::Done;
}

media::NativeMediaClockSnapshot NativeAudioSession::visibleClock() const noexcept {
  if (control_ == nullptr) {
    return {};
  }
  if (control_->retirement.has_value() && control_->clockActivated) {
    return control_->clock.sample();
  }
  if (!control_->configured) {
    return {};
  }
  return control_->renderCore.visibleClock();
}

media::NativeAudioRenderStats NativeAudioSession::renderStats() const noexcept {
  if (control_ == nullptr) {
    return {};
  }
  return control_->renderCore.stats();
}

NativeAudioSessionFacts NativeAudioSession::facts() const noexcept {
  NativeAudioSessionFacts result;
  if (control_ == nullptr) {
    result.state = NativeAudioSessionState::Closed;
    result.closeDone = true;
    return result;
  }
  const NativeAudioSessionControl& control = *control_;
  result.state = control.state;
  result.failure = control.failure;
  result.generation = control.generation;
  result.track = control.track;
  result.sampleRate = control.active.sampleRate;
  result.presentationFloorFrame = control.active.floorFrame;
  const media::NativePcmRing::Stats ring = control.ring.stats();
  result.ringGeneration = ring.generation;
  result.queuedSlabs = ring.queuedSlabs;
  result.resourceEntered = control.resourceEntered;
  result.configured = control.configured;
  result.requestedPaused = control.requestedPaused;
  result.requestedGain = control.requestedGain;
  result.requestedMuted = control.requestedMuted;
  result.controlRevision = control.controlRevision;
  result.endOfStreamRequested = control.endOfStreamRequested;
  result.terminalPublished = control.terminalPublished;
  result.terminalObserved = terminalObserved(control);
  const media::NativeMediaClockSnapshot clock = control.clock.sample();
  result.clockGeneration = clock.generation;
  result.clockValid = clock.valid;
  result.highestExposedGeneration = control.highestExposedGeneration;
  result.retiredGeneration =
      control.retirement ? control.retirement->retired : 0;
  result.invalidationGeneration =
      control.retirement ? control.retirement->invalidation : 0;
  result.retireDone = retirementDone(control);
  result.closeDone = control.closeDone;
  result.outputSuspended =
      control.outputSuspension == OutputSuspension::Suspended;
  result.converter = control.converter.stats();
  if (control.output != nullptr) {
    result.output = control.output->facts();
  }
  return result;
}

} // namespace wam::macos
