#include "native_audio_session.hpp"

#import <AudioToolbox/AudioToolbox.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <limits>
#include <mutex>
#include <numeric>
#include <optional>
#include <utility>

namespace wam::macos {
namespace {

enum class SessionLifecycle : std::uint8_t {
  None,
  Flush,
  Cancel,
};

enum class FlushStage : std::uint8_t {
  Stop,
  Reset,
  Activate,
};

enum class RetireStage : std::uint8_t {
  StopOutput,
  InvalidateGraph,
  CloseOutput,
};

enum class TerminalOverride : std::uint8_t {
  None,
  Stop,
  Cancel,
};

struct TimelinePlan {
  NativeAudioGenerationTimeline converter{};
  media::MediaTime decodeStart{};       // first source-proved audio AU D
  media::MediaTime mediaOrigin{};       // first retained source PCM frame A
  media::MediaTime clockPosition{};     // exact visual generation floor T
  std::int64_t floorFrame{0};
  std::uint32_t sampleRate{0};
};

std::mutex gSessionMutex;
bool gSessionClaimed{false};
std::shared_ptr<NativeAudioSessionControl> gSessionQuarantine;
std::atomic<std::uint64_t> gRejectedCreates{0};
std::atomic<std::uint64_t> gQuarantineTransfers{0};
std::atomic<std::uint64_t> gQuarantineRecoveries{0};

void saturatingIncrement(std::atomic<std::uint64_t>& counter) noexcept {
  const std::uint64_t maximum = std::numeric_limits<std::uint64_t>::max();
  std::uint64_t current = counter.load(std::memory_order_relaxed);
  for (unsigned attempt = 0; attempt != 2 && current != maximum; ++attempt) {
    if (counter.compare_exchange_weak(current, current + 1U,
                                      std::memory_order_relaxed,
                                      std::memory_order_relaxed)) {
      return;
    }
  }
}

void assignError(std::string* error, const char* message) noexcept {
  if (error == nullptr) {
    return;
  }
  try {
    *error = message;
  } catch (...) {
  }
}

[[nodiscard]] std::uint64_t magnitude(std::int64_t value) noexcept {
  return value < 0 ? static_cast<std::uint64_t>(-(value + 1)) + 1U
                   : static_cast<std::uint64_t>(value);
}

[[nodiscard]] bool exactFrame(media::MediaTime time,
                              std::uint32_t sampleRate,
                              std::int64_t* result) noexcept {
  if (!time.valid() || sampleRate == 0 || result == nullptr) {
    return false;
  }
  std::uint64_t numerator = magnitude(time.value);
  std::uint64_t denominator = static_cast<std::uint32_t>(time.timescale);
  std::uint64_t rate = sampleRate;
  const std::uint64_t first = std::gcd(numerator, denominator);
  numerator /= first;
  denominator /= first;
  const std::uint64_t second = std::gcd(rate, denominator);
  rate /= second;
  denominator /= second;
  if (denominator != 1 ||
      (rate != 0 &&
       numerator > std::numeric_limits<std::uint64_t>::max() / rate)) {
    return false;
  }
  const std::uint64_t absolute = numerator * rate;
  if (time.value < 0) {
    constexpr std::uint64_t negativeLimit = std::uint64_t{1} << 63U;
    if (absolute > negativeLimit) {
      return false;
    }
    *result = absolute == negativeLimit
                  ? std::numeric_limits<std::int64_t>::min()
                  : -static_cast<std::int64_t>(absolute);
    return true;
  }
  if (absolute >
      static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
    return false;
  }
  *result = static_cast<std::int64_t>(absolute);
  return true;
}

[[nodiscard]] bool supportedRate(double rate,
                                 std::uint32_t* exactRate) noexcept {
  constexpr std::array<std::uint32_t, 4> supported{
      44'100, 48'000, 96'000, 192'000};
  if (!std::isfinite(rate) || exactRate == nullptr) {
    return false;
  }
  for (const std::uint32_t candidate : supported) {
    if (rate == static_cast<double>(candidate)) {
      *exactRate = candidate;
      return true;
    }
  }
  return false;
}

[[nodiscard]] bool supportedCodec(const media::MediaTrackDescriptor& track)
    noexcept {
  if (!track.audio) {
    return false;
  }
  switch (track.codec) {
  case media::MediaCodec::Aac:
    return track.audio->formatTag == kAudioFormatMPEG4AAC ||
           track.audio->formatTag == kAudioFormatMPEG4AAC_HE ||
           track.audio->formatTag == kAudioFormatMPEG4AAC_HE_V2;
  case media::MediaCodec::Alac:
    return track.audio->formatTag == kAudioFormatAppleLossless;
  case media::MediaCodec::Mp3:
    return track.audio->formatTag == kAudioFormatMPEGLayer3;
  default:
    return false;
  }
}

[[nodiscard]] bool supportedLayout(const media::MediaAudioFormat& audio)
    noexcept {
  if (!audio.channelLayoutPresent) {
    return audio.channelLayoutTag == 0;
  }
  return (audio.channels == 1 &&
          audio.channelLayoutTag == kAudioChannelLayoutTag_Mono) ||
         (audio.channels == 2 &&
          audio.channelLayoutTag == kAudioChannelLayoutTag_Stereo);
}

[[nodiscard]] bool validCallTable(
    const NativeAudioUnitCallTable& calls) noexcept {
  return calls.findNext != nullptr && calls.instanceNew != nullptr &&
         calls.instanceDispose != nullptr && calls.setProperty != nullptr &&
         calls.getProperty != nullptr && calls.initialize != nullptr &&
         calls.uninitialize != nullptr && calls.start != nullptr &&
         calls.stop != nullptr && calls.addPropertyListener != nullptr &&
         calls.removePropertyListener != nullptr &&
         calls.hostClockFrequency != nullptr;
}

[[nodiscard]] bool validDependencies(
    const NativeAudioSessionDependencies& dependencies) noexcept {
  return dependencies.externalLifetime != nullptr &&
         dependencies.hostClock.readTicks != nullptr &&
         dependencies.hostClock.ticksPerSecond != 0 &&
         validCallTable(dependencies.outputCalls) &&
         dependencies.outputWake.pending != nullptr &&
         dependencies.outputWake.signal != nullptr &&
         dependencies.outputWake.pending->is_lock_free();
}

[[nodiscard]] std::optional<TimelinePlan> timelinePlanForRate(
    media::MediaGeneration generation,
    const media::NativeMediaGenerationTimeline& timeline,
    std::uint32_t sampleRate) noexcept {
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
      decodeFrame < 0 ||
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
      *audioDecodeAgainstOrigin == media::MediaTimeOrder::Less ||
      timeline.audioWindow.startsAtStreamOrigin !=
          (*audioDecodeAgainstOrigin == media::MediaTimeOrder::Equal)) {
    return std::nullopt;
  }

  bool trimBeforeFloor = false;
  switch (timeline.mode) {
  case media::MediaSeekMode::Accurate:
    if (*targetAgainstFloor != media::MediaTimeOrder::Equal) {
      return std::nullopt;
    }
    if (const auto expected =
            media::audioFrameAtOrAfter(timeline.requestedTarget, sampleRate);
        !expected ||
        media::compareMediaTime(timeline.audioWindow.presentationStart,
                                *expected) !=
            media::MediaTimeOrder::Equal) {
      return std::nullopt;
    }
    trimBeforeFloor =
        *audioDecodeAgainstFloor == media::MediaTimeOrder::Less;
    break;
  case media::MediaSeekMode::KeyFrame:
    if (*actualAgainstFloor != media::MediaTimeOrder::Equal ||
        *audioDecodeAgainstFloor != media::MediaTimeOrder::Equal ||
        media::compareMediaTime(timeline.audioWindow.presentationStart,
                                timeline.presentationFloor) !=
            media::MediaTimeOrder::Equal) {
      return std::nullopt;
    }
    break;
  default:
    return std::nullopt;
  }

  TimelinePlan result;
  result.converter.presentationFloor = {
      floorFrame, static_cast<std::int32_t>(sampleRate)};
  result.converter.trimBeforeFloor = trimBeforeFloor;
  result.converter.startsAtStreamOrigin =
      timeline.audioWindow.startsAtStreamOrigin;
  result.decodeStart = timeline.audioWindow.decodeStart;
  result.mediaOrigin = result.converter.presentationFloor;
  result.clockPosition = timeline.presentationFloor;
  result.floorFrame = floorFrame;
  result.sampleRate = sampleRate;
  return result;
}

[[nodiscard]] std::optional<TimelinePlan> preflight(
    const media::MediaTrackDescriptor& track,
    media::MediaGeneration generation,
    const media::NativeMediaGenerationTimeline& timeline) noexcept {
  std::uint32_t sampleRate = 0;
  if (generation == 0 || timeline.generation != generation ||
      track.id == 0 || track.kind != media::MediaTrackKind::Audio ||
      !track.audio || !supportedCodec(track) ||
      (track.audio->channels != 1 && track.audio->channels != 2) ||
      !track.audio->interleaved || track.audio->framesPerPacket == 0 ||
      !supportedLayout(*track.audio) ||
      !supportedRate(track.audio->sampleRate, &sampleRate) ||
      track.codecConfiguration.size() >
          media::MediaSourceLimits::kHardMaximumCodecConfigurationBytes ||
      (!track.codecConfiguration.empty() &&
       track.codecConfigurationKind !=
           media::MediaCodecConfigurationKind::AudioMagicCookie) ||
      (track.codecConfiguration.empty() &&
       track.codecConfigurationKind !=
           media::MediaCodecConfigurationKind::None)) {
    return std::nullopt;
  }
  return timelinePlanForRate(generation, timeline, sampleRate);
}

[[nodiscard]] bool sameTimeline(
    const media::NativeMediaGenerationTimeline& lhs,
    const media::NativeMediaGenerationTimeline& rhs) noexcept {
  return lhs == rhs;
}

[[nodiscard]] float normalizedGain(float gain) noexcept {
  return std::isfinite(gain) ? std::clamp(gain, 0.0F, 1.0F) : 0.0F;
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

void advanceControlRevision(std::uint64_t& revision) noexcept {
  if (revision != std::numeric_limits<std::uint64_t>::max()) {
    ++revision;
  }
}

} // namespace

struct NativeAudioSessionControl final {
  NativeAudioSessionControl(
      media::MediaGeneration initialGeneration,
      std::shared_ptr<void> external,
      NativeMediaHostClock hostClock,
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
        converter(ring, std::move(backend)),
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
  const NativeMediaHostClock hostClock;
  const NativeAudioUnitCallTable outputCalls;
  const NativeAudioOutputWakeSeam outputWake;
  NativePcmRing ring;
  NativeMediaClock clock;
  NativeAudioRenderCore renderCore;
  NativeAudioConverter converter;
  std::shared_ptr<NativeAudioOutput> output;

  NativeAudioSessionState state{NativeAudioSessionState::Fresh};
  NativeAudioSessionFailure failure{NativeAudioSessionFailure::None};
  SessionLifecycle lifecycle{SessionLifecycle::None};
  FlushStage flushStage{FlushStage::Stop};
  RetireStage retireStage{RetireStage::StopOutput};
  media::MediaGeneration generation{0};
  media::MediaGeneration highestExposedGeneration{0};
  media::MediaGeneration lifecycleRetired{0};
  media::MediaGeneration lifecycleTarget{0};
  media::MediaGeneration cancelledGeneration{0};
  media::MediaGeneration completedFlushRetired{0};
  media::MediaGeneration completedFlushTarget{0};
  media::MediaTrackId track{0};
  std::uint32_t sampleRate{0};
  std::int64_t presentationFloorFrame{0};
  media::MediaTime mediaOrigin{};
  media::MediaTime audioDecodeStart{};
  media::NativeMediaGenerationTimeline timeline{};
  media::NativeMediaGenerationTimeline lifecycleTimeline{};
  NativeAudioGenerationTimeline converterTimeline{};
  TimelinePlan lifecyclePlan{};
  bool claimHeld{true};
  bool resourceEntered{false};
  bool configured{false};
  bool firstAudioSampleAccepted{false};
  bool requestedPaused{true};
  float requestedGain{1.0F};
  float appliedGain{1.0F};
  bool requestedMuted{false};
  bool appliedMuted{false};
  std::uint64_t controlRevision{0};
  std::uint64_t appliedControlRevision{0};
  bool endOfStreamRequested{false};
  bool terminalPublished{false};
  bool clockActivated{false};
  bool retireRequested{false};
  bool retireDone{false};
  media::MediaGeneration retireRetiredGeneration{0};
  media::MediaGeneration retireInvalidationGeneration{0};
  bool closeDone{false};
  TerminalOverride terminalOverride{TerminalOverride::None};
  media::MediaGeneration terminalOverrideGeneration{0};
#if defined(WAM_NATIVE_AUDIO_SESSION_TESTING)
  bool forceCloseQuiescing{false};
#endif
};




#if defined(WAM_NATIVE_AUDIO_SESSION_TESTING)
struct NativeAudioRenderCoreTestAccess {
  static void setAfterPreflightHook(
      NativeAudioRenderCore& core,
      NativeAudioRenderCore::TestHook hook,
      void* context) noexcept {
    core.after_preflight_hook_ = hook;
    core.after_preflight_context_ = context;
  }
};

NativeAudioSubmitResult NativeAudioSessionTestAccess::occupyConverter(
    NativeAudioSession& session, media::MediaSample&& sample) noexcept {
  try {
    return session.control_->converter.submit(std::move(sample), nullptr);
  } catch (...) {
    return NativeAudioSubmitResult::Failed;
  }
}

void NativeAudioSessionTestAccess::setAfterRenderPreflightHook(
    NativeAudioSession& session, CallbackHook hook,
    void* context) noexcept {
  NativeAudioRenderCoreTestAccess::setAfterPreflightHook(
      session.control_->renderCore, hook, context);
}

void NativeAudioSessionTestAccess::stageFlushAfterStop(
    NativeAudioSession& session,
    media::MediaGeneration retiredGeneration,
    media::MediaGeneration nextGeneration,
    media::NativeMediaGenerationTimeline timeline,
    NativeAudioGenerationTimeline converterTimeline,
    media::MediaTime mediaOrigin,
    std::int64_t floorFrame) noexcept {
  NativeAudioSessionControl& control = *session.control_;
  control.lifecycle = SessionLifecycle::Flush;
  control.flushStage = FlushStage::Reset;
  control.lifecycleRetired = retiredGeneration;
  control.lifecycleTarget = nextGeneration;
  control.highestExposedGeneration = nextGeneration;
  control.lifecycleTimeline = timeline;
  control.lifecyclePlan = {converterTimeline, timeline.audioWindow.decodeStart,
                           mediaOrigin,
                           timeline.presentationFloor, floorFrame,
                           control.sampleRate};
  control.requestedPaused = true;
  control.renderCore.setPaused(true);
  control.state = NativeAudioSessionState::Flushing;
}

void NativeAudioSessionTestAccess::forceCloseQuiescing(
    NativeAudioSession& session, bool enabled) noexcept {
  session.control_->forceCloseQuiescing = enabled;
}
#endif

namespace {

void releaseClaim(NativeAudioSessionControl& control) noexcept {
  std::lock_guard<std::mutex> lock(gSessionMutex);
  if (!control.claimHeld) {
    return;
  }
  if (gSessionQuarantine.get() == &control) {
    gSessionQuarantine.reset();
  }
  control.claimHeld = false;
  gSessionClaimed = false;
}

void quarantine(
    const std::shared_ptr<NativeAudioSessionControl>& control) noexcept {
  if (control == nullptr || !control->claimHeld || control->closeDone) {
    return;
  }
  std::lock_guard<std::mutex> lock(gSessionMutex);
  if (gSessionQuarantine == nullptr) {
    gSessionQuarantine = control;
    saturatingIncrement(gQuarantineTransfers);
  }
}

[[nodiscard]] bool outputFailed(NativeAudioSessionControl& control) noexcept {
  if (control.output != nullptr && control.output->facts().fatal) {
    control.latch(NativeAudioSessionFailure::Output);
    return true;
  }
  if (control.renderCore.failure() != NativeAudioRenderFailure::None) {
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

[[nodiscard]] bool verifyPublishedOrigin(
    NativeAudioSessionControl& control) noexcept {
  const NativeAudioConverterStats stats = control.converter.stats();
  if (stats.publishedPcmFrames == 0) {
    return true;
  }
  if (!stats.firstPublishedFrameKnown ||
      stats.firstPublishedFrame != control.presentationFloorFrame) {
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
    if (!control.renderCore.publishTerminalFrame(
            control.generation, stats.publishedPcmFrames)) {
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

[[nodiscard]] media::NativeMediaConsumeResult mapPumpForCapacity(
    NativeAudioSessionControl& control,
    NativeAudioPumpResult result) noexcept {
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
    return media::NativeMediaConsumeResult::Accepted;
  case NativeAudioPumpResult::StaleGeneration:
    return media::NativeMediaConsumeResult::StaleGeneration;
  case NativeAudioPumpResult::Drained:
    control.latch(NativeAudioSessionFailure::ConsumerProtocol);
    return media::NativeMediaConsumeResult::Failed;
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
    return NativeAudioSessionProgress::Invalid;
  case NativeAudioOutputProgress::Failed:
    control.latch(failure);
    return NativeAudioSessionProgress::Failed;
  }
  control.latch(failure);
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

} // namespace

NativeAudioSession::NativeAudioSession(
    std::shared_ptr<NativeAudioSessionControl> control) noexcept
    : control_(std::move(control)) {}

std::unique_ptr<NativeAudioSession> NativeAudioSession::create(
    media::MediaGeneration initialGeneration,
    NativeAudioSessionDependencies dependencies) noexcept {
  if (initialGeneration == 0 || !validDependencies(dependencies)) {
    saturatingIncrement(gRejectedCreates);
    return {};
  }
  {
    std::lock_guard<std::mutex> lock(gSessionMutex);
    if (gSessionClaimed || gSessionQuarantine != nullptr) {
      saturatingIncrement(gRejectedCreates);
      return {};
    }
    gSessionClaimed = true;
  }

  try {
    auto control = std::make_shared<NativeAudioSessionControl>(
        initialGeneration, std::move(dependencies.externalLifetime),
        dependencies.hostClock, dependencies.outputCalls,
        dependencies.outputWake, std::move(dependencies.converterBackend));
    return std::unique_ptr<NativeAudioSession>(
        new NativeAudioSession(std::move(control)));
  } catch (...) {
    std::lock_guard<std::mutex> lock(gSessionMutex);
    gSessionClaimed = false;
    saturatingIncrement(gRejectedCreates);
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

std::unique_ptr<NativeAudioSession>
NativeAudioSession::recoverQuarantined() noexcept {
  std::lock_guard<std::mutex> lock(gSessionMutex);
  if (gSessionQuarantine == nullptr) {
    return {};
  }
  try {
    auto recovered = std::unique_ptr<NativeAudioSession>(
        new NativeAudioSession(gSessionQuarantine));
    gSessionQuarantine.reset();
    saturatingIncrement(gQuarantineRecoveries);
    return recovered;
  } catch (...) {
    return {};
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
  result.claimed = gSessionClaimed;
  result.quarantined = gSessionQuarantine != nullptr;
  return result;
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
  const auto clockSeconds = media::mediaTimeSeconds(plan->clockPosition);
  if (!clockSeconds ||
      !control.clock.anchor(generation, *clockSeconds, 1.0, false)) {
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
  control.appliedGain = control.requestedGain;
  control.appliedMuted = control.requestedMuted;
  control.appliedControlRevision = control.controlRevision;
  const NativeAudioOutputProgress outputConfigured =
      control.output->configure({generation, 0, plan->mediaOrigin,
                                 control.hostClock.ticksPerSecond,
                                 plan->sampleRate,
                                 plan->clockPosition});
  if (outputConfigured != NativeAudioOutputProgress::Done) {
    control.latch(NativeAudioSessionFailure::OutputConfiguration);
    assignError(error, "native audio output configuration failed");
    return media::NativeMediaConsumeResult::Failed;
  }

  control.track = track.id;
  control.sampleRate = plan->sampleRate;
  control.presentationFloorFrame = plan->floorFrame;
  control.mediaOrigin = plan->mediaOrigin;
  control.audioDecodeStart = plan->decodeStart;
  control.firstAudioSampleAccepted = false;
  control.timeline = timeline;
  control.converterTimeline = plan->converter;
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
  if (!control.configured ||
      control.state == NativeAudioSessionState::Failed ||
      control.state == NativeAudioSessionState::Retiring ||
      control.state == NativeAudioSessionState::Closing ||
      control.state == NativeAudioSessionState::Closed ||
      control.state == NativeAudioSessionState::Cancelled ||
      outputFailed(control)) {
    return media::NativeMediaConsumeResult::Failed;
  }
  if (control.endOfStreamRequested) {
    return terminalObserved(control)
               ? media::NativeMediaConsumeResult::Drained
               : media::NativeMediaConsumeResult::Backpressure;
  }
  return mapPumpForCapacity(control, control.converter.pump(nullptr));
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
  if (!control.configured ||
      control.endOfStreamRequested ||
      control.state == NativeAudioSessionState::Failed ||
      control.state == NativeAudioSessionState::Retiring ||
      control.state == NativeAudioSessionState::Closing ||
      control.state == NativeAudioSessionState::Closed ||
      control.state == NativeAudioSessionState::Cancelled ||
      outputFailed(control)) {
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
                              control.audioDecodeStart) !=
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
  if (control.retireRequested) {
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
  const NativeAudioPumpResult result =
      control.converter.endOfStream(end.generation, error);
  switch (result) {
  case NativeAudioPumpResult::Published:
    return verifyPublishedOrigin(control)
               ? media::NativeMediaConsumeResult::Draining
               : media::NativeMediaConsumeResult::Failed;
  case NativeAudioPumpResult::Progress:
    return media::NativeMediaConsumeResult::Draining;
  case NativeAudioPumpResult::Backpressure:
    return media::NativeMediaConsumeResult::Backpressure;
  case NativeAudioPumpResult::Drained:
    if (!publishTerminal(control)) {
      return media::NativeMediaConsumeResult::Failed;
    }
    return terminalObserved(control)
               ? media::NativeMediaConsumeResult::Drained
               : media::NativeMediaConsumeResult::Draining;
  case NativeAudioPumpResult::StaleGeneration:
    return media::NativeMediaConsumeResult::StaleGeneration;
  case NativeAudioPumpResult::NeedsInput:
  case NativeAudioPumpResult::NotConfigured:
  case NativeAudioPumpResult::Failed:
    control.latch(NativeAudioSessionFailure::Converter);
    return media::NativeMediaConsumeResult::Failed;
  }
  control.latch(NativeAudioSessionFailure::ConsumerProtocol);
  return media::NativeMediaConsumeResult::Failed;
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
  if (!control.configured ||
      control.state == NativeAudioSessionState::Failed ||
      control.state == NativeAudioSessionState::Retiring ||
      control.state == NativeAudioSessionState::Closing ||
      control.state == NativeAudioSessionState::Closed ||
      control.state == NativeAudioSessionState::Cancelled ||
      outputFailed(control)) {
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
  if (control.state == NativeAudioSessionState::Started) {
    return NativeAudioSessionProgress::Done;
  }
  if (control.state != NativeAudioSessionState::Ready ||
      control.output == nullptr) {
    return NativeAudioSessionProgress::Invalid;
  }
  if (outputFailed(control)) {
    return NativeAudioSessionProgress::Failed;
  }
  const NativePcmRing::ReadableFramesResult readable =
      control.ring.readableFrames(control.generation);
  if (!control.requestedPaused && readable.frames == 0 &&
      !control.terminalPublished) {
    return NativeAudioSessionProgress::WaitingForData;
  }
  control.renderCore.setPaused(control.requestedPaused);
  const NativeAudioSessionProgress result = mapOutputProgress(
      control, control.output->start(), NativeAudioSessionFailure::Output);
  if (result == NativeAudioSessionProgress::Done) {
    control.state = NativeAudioSessionState::Started;
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
  control.requestedPaused = paused;
  control.renderCore.setPaused(paused);
  if (paused && control.state == NativeAudioSessionState::Ready &&
      !control.clock.pause(control.generation)) {
    control.latch(NativeAudioSessionFailure::ClockTransition);
    return NativeAudioSessionProgress::Failed;
  }
  return NativeAudioSessionProgress::Done;
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
  advanceControlRevision(control.controlRevision);
  control.renderCore.setGain(control.requestedGain);
  control.appliedGain = control.requestedGain;
  control.appliedMuted = control.requestedMuted;
  control.appliedControlRevision = control.controlRevision;
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
  advanceControlRevision(control.controlRevision);
  control.renderCore.setMuted(control.requestedMuted);
  control.appliedGain = control.requestedGain;
  control.appliedMuted = control.requestedMuted;
  control.appliedControlRevision = control.controlRevision;
  return NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress NativeAudioSession::stop() noexcept {
  if (control_ == nullptr) {
    return NativeAudioSessionProgress::Invalid;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);
  if (control.retireRequested) {
    return NativeAudioSessionProgress::Invalid;
  }
  if (control.terminalOverride == TerminalOverride::Stop) {
    if (control.terminalOverrideGeneration != control.generation) {
      return NativeAudioSessionProgress::Invalid;
    }
    if (control.closeDone || control.state == NativeAudioSessionState::Closed) {
      return NativeAudioSessionProgress::Done;
    }
    switch (close()) {
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
  }
  if (control.lifecycle == SessionLifecycle::Flush ||
      control.state == NativeAudioSessionState::Flushing) {
    control.terminalOverride = TerminalOverride::Stop;
    control.terminalOverrideGeneration = control.generation;
    switch (close()) {
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
  if (control.retireRequested) {
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
      sameTimeline(control.timeline, timeline) &&
      control.generation == nextGeneration) {
    return media::NativeMediaConsumerProgress::Done;
  }
  if (control.lifecycle == SessionLifecycle::Flush) {
    if (control.lifecycleRetired != retiredGeneration ||
        control.lifecycleTarget != nextGeneration ||
        !sameTimeline(control.lifecycleTimeline, timeline)) {
      return media::NativeMediaConsumerProgress::StaleGeneration;
    }
  } else {
    if (control.lifecycle != SessionLifecycle::None ||
        !control.configured ||
        control.state == NativeAudioSessionState::Failed ||
        retiredGeneration != control.generation || nextGeneration == 0 ||
        nextGeneration <= retiredGeneration) {
      return retiredGeneration != control.generation
                 ? media::NativeMediaConsumerProgress::StaleGeneration
                 : media::NativeMediaConsumerProgress::Failed;
    }
    const std::optional<TimelinePlan> plan =
        timelinePlanForRate(nextGeneration, timeline, control.sampleRate);
    if (!plan) {
      control.latch(NativeAudioSessionFailure::ClockTransition);
      return media::NativeMediaConsumerProgress::Failed;
    }
    control.lifecyclePlan = *plan;
    control.lifecycle = SessionLifecycle::Flush;
    control.flushStage = FlushStage::Stop;
    control.lifecycleRetired = retiredGeneration;
    control.lifecycleTarget = nextGeneration;
    control.lifecycleTimeline = timeline;
    control.firstAudioSampleAccepted = false;
    control.requestedPaused = true;
    control.renderCore.setPaused(true);
    control.state = NativeAudioSessionState::Flushing;
  }

  if (control.flushStage == FlushStage::Stop) {
    const NativeAudioSessionProgress stopped = mapOutputProgress(
        control, control.output->stop(), NativeAudioSessionFailure::Output);
    if (stopped != NativeAudioSessionProgress::Done) {
      return mapLifecycleProgress(stopped);
    }
    if (!settleStopped(control, control.lifecycleRetired)) {
      return media::NativeMediaConsumerProgress::Failed;
    }
    control.flushStage = FlushStage::Reset;
  }

  if (control.flushStage == FlushStage::Reset) {
    const auto clockSeconds =
        media::mediaTimeSeconds(control.lifecyclePlan.clockPosition);
    if (!clockSeconds || !control.ring.flush(control.lifecycleTarget)) {
      control.latch(NativeAudioSessionFailure::RingTransition);
      return media::NativeMediaConsumerProgress::Failed;
    }
    if (!control.clock.seek(control.lifecycleRetired,
                            control.lifecycleTarget, *clockSeconds)) {
      control.latch(NativeAudioSessionFailure::ClockTransition);
      return media::NativeMediaConsumerProgress::Failed;
    }
    if (!control.converter.flush(control.lifecycleTarget,
                                 control.lifecyclePlan.converter)) {
      control.latch(NativeAudioSessionFailure::Converter);
      return media::NativeMediaConsumerProgress::Failed;
    }
    control.renderCore.setPaused(true);
    control.flushStage = FlushStage::Activate;
  }

  const NativeAudioSessionProgress activated = mapOutputProgress(
      control,
      control.output->activate(control.lifecycleTarget, 0,
                               control.lifecyclePlan.mediaOrigin,
                               control.lifecyclePlan.clockPosition),
      NativeAudioSessionFailure::OutputActivation);
  if (activated != NativeAudioSessionProgress::Done) {
    return mapLifecycleProgress(activated);
  }

  control.completedFlushRetired = control.lifecycleRetired;
  control.completedFlushTarget = control.lifecycleTarget;
  control.generation = control.lifecycleTarget;
  control.timeline = control.lifecycleTimeline;
  control.converterTimeline = control.lifecyclePlan.converter;
  control.mediaOrigin = control.lifecyclePlan.mediaOrigin;
  control.audioDecodeStart = control.lifecyclePlan.decodeStart;
  control.firstAudioSampleAccepted = false;
  control.presentationFloorFrame = control.lifecyclePlan.floorFrame;
  control.endOfStreamRequested = false;
  control.terminalPublished = false;
  control.lifecycle = SessionLifecycle::None;
  control.lifecycleRetired = 0;
  control.lifecycleTarget = 0;
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
  if (control.retireRequested) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (generation != control.generation) {
    return media::NativeMediaConsumerProgress::StaleGeneration;
  }
  if (control.terminalOverride == TerminalOverride::Cancel) {
    if (generation != control.terminalOverrideGeneration) {
      return media::NativeMediaConsumerProgress::StaleGeneration;
    }
    return close();
  }
  if (control.lifecycle == SessionLifecycle::Flush ||
      control.state == NativeAudioSessionState::Flushing) {
    // A terminal cancellation supersedes a reversible seek flush. The graph
    // may already be split across retired/target generations, so the only
    // exact result is fail-closed teardown, never resuming Reset/Activate.
    control.terminalOverride = TerminalOverride::Cancel;
    control.terminalOverrideGeneration = generation;
    return close();
  }
  if (control.state == NativeAudioSessionState::Cancelled &&
      control.cancelledGeneration == generation) {
    return media::NativeMediaConsumerProgress::Done;
  }
  if (control.lifecycle != SessionLifecycle::None &&
      control.lifecycle != SessionLifecycle::Cancel) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (control.state == NativeAudioSessionState::Failed ||
      control.state == NativeAudioSessionState::Closing ||
      control.state == NativeAudioSessionState::Closed) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  control.lifecycle = SessionLifecycle::Cancel;
  control.lifecycleTarget = generation;
  control.requestedPaused = true;
  control.renderCore.setPaused(true);
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
    control.audioDecodeStart = {};
    control.cancelledGeneration = generation;
    control.lifecycle = SessionLifecycle::None;
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

  if (control.retireRequested) {
    if (retiredGeneration != control.retireRetiredGeneration ||
        invalidationGeneration != control.retireInvalidationGeneration) {
      return media::NativeMediaConsumerProgress::StaleGeneration;
    }
    if (control.retireDone) {
      return media::NativeMediaConsumerProgress::Done;
    }
  } else {
    if (retiredGeneration != control.highestExposedGeneration) {
      return media::NativeMediaConsumerProgress::StaleGeneration;
    }
    const NativeAudioConverterStats converter = control.converter.stats();
    const NativeAudioOutputFacts output =
        control.output != nullptr ? control.output->facts()
                                  : NativeAudioOutputFacts{};
    const NativeMediaClockSnapshot clock = control.clock.sample();
    media::MediaGeneration highestInstalled = control.ring.generation();
    highestInstalled = std::max(highestInstalled, control.generation);
    highestInstalled = std::max(highestInstalled, converter.generation);
    highestInstalled = std::max(highestInstalled, output.generation);
    highestInstalled = std::max(highestInstalled, clock.generation);
    highestInstalled =
        std::max(highestInstalled, control.lifecycleTarget);
    if (invalidationGeneration == 0 ||
        invalidationGeneration <= retiredGeneration ||
        invalidationGeneration <= highestInstalled) {
      return media::NativeMediaConsumerProgress::Failed;
    }
    control.retireRequested = true;
    control.retireRetiredGeneration = retiredGeneration;
    control.retireInvalidationGeneration = invalidationGeneration;
    control.retireStage = RetireStage::StopOutput;
    control.lifecycle = SessionLifecycle::None;
    control.lifecycleRetired = 0;
    control.lifecycleTarget = 0;
    control.terminalOverride = TerminalOverride::None;
    control.terminalOverrideGeneration = 0;
    control.requestedPaused = true;
    control.renderCore.setPaused(true);
    control.state = NativeAudioSessionState::Retiring;
  }

  if (control.retireStage == RetireStage::StopOutput) {
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
        control.latch(NativeAudioSessionFailure::Output);
        control.state = NativeAudioSessionState::Retiring;
        const NativeAudioOutputProgress closed = control.output->close();
        if (closed == NativeAudioOutputProgress::Quiescing) {
          return media::NativeMediaConsumerProgress::Quiescing;
        }
        if (closed != NativeAudioOutputProgress::Done) {
          return media::NativeMediaConsumerProgress::Progress;
        }
      }
    }

    if (control.clockActivated) {
      NativeMediaClockSnapshot clock = control.clock.sample();
      if (!clock.publicationCurrent || !clock.valid ||
          clock.generation == 0 ||
          !control.clock.pause(clock.generation)) {
        control.latch(NativeAudioSessionFailure::ClockTransition);
        control.state = NativeAudioSessionState::Retiring;
        return media::NativeMediaConsumerProgress::Failed;
      }
      clock = control.clock.sample();
      if (!clock.publicationCurrent || !clock.valid || clock.running) {
        control.latch(NativeAudioSessionFailure::ClockTransition);
        control.state = NativeAudioSessionState::Retiring;
        return media::NativeMediaConsumerProgress::Failed;
      }
      if (control.output != nullptr) {
        const NativeAudioOutputFacts output = control.output->facts();
        if (output.activated && output.generation == clock.generation &&
            !control.renderCore.settlePausedAfterStop(clock.generation)) {
          control.latch(NativeAudioSessionFailure::ClockTransition);
          control.state = NativeAudioSessionState::Retiring;
          return media::NativeMediaConsumerProgress::Failed;
        }
      }
    }
    control.retireStage = RetireStage::InvalidateGraph;
  }

  if (control.retireStage == RetireStage::InvalidateGraph) {
    const media::MediaGeneration invalidation =
        control.retireInvalidationGeneration;
    const media::MediaGeneration ringGeneration = control.ring.generation();
    if (ringGeneration != invalidation &&
        !control.ring.flush(invalidation)) {
      control.latch(NativeAudioSessionFailure::RingTransition);
      control.state = NativeAudioSessionState::Retiring;
      return media::NativeMediaConsumerProgress::Failed;
    }

    if (control.clockActivated) {
      const NativeMediaClockSnapshot clock = control.clock.sample();
      if (clock.generation != invalidation) {
        if (!clock.valid || clock.generation == 0 ||
            !control.clock.stop(clock.generation, invalidation)) {
          control.latch(NativeAudioSessionFailure::ClockTransition);
          control.state = NativeAudioSessionState::Retiring;
          return media::NativeMediaConsumerProgress::Failed;
        }
      }
      const NativeMediaClockSnapshot invalid = control.clock.sample();
      if (!invalid.publicationCurrent || invalid.valid || invalid.running ||
          invalid.generation != invalidation) {
        control.latch(NativeAudioSessionFailure::ClockTransition);
        control.state = NativeAudioSessionState::Retiring;
        return media::NativeMediaConsumerProgress::Failed;
      }
    }

    control.renderCore.clearTerminal(control.generation);
    control.converter.close();
    const NativeAudioConverterStats converter = control.converter.stats();
    if (converter.configured || converter.samplePrepared ||
        converter.sampleRetained) {
      control.latch(NativeAudioSessionFailure::Converter);
      control.state = NativeAudioSessionState::Retiring;
      return media::NativeMediaConsumerProgress::Failed;
    }
    control.endOfStreamRequested = false;
    control.terminalPublished = false;
    control.retireStage = RetireStage::CloseOutput;
  }

  if (control.output != nullptr) {
    const NativeAudioOutputProgress closed = control.output->close();
    if (closed == NativeAudioOutputProgress::Quiescing) {
      return media::NativeMediaConsumerProgress::Quiescing;
    }
    if (closed != NativeAudioOutputProgress::Done) {
      control.latch(NativeAudioSessionFailure::Output);
      control.state = NativeAudioSessionState::Retiring;
      return media::NativeMediaConsumerProgress::Progress;
    }
    const NativeAudioOutputFacts output = control.output->facts();
    if (output.configured || output.started || !output.stopped ||
        !output.callbackQuiescent ||
        output.state != NativeAudioOutputState::Closed) {
      control.latch(NativeAudioSessionFailure::Output);
      control.state = NativeAudioSessionState::Retiring;
      return media::NativeMediaConsumerProgress::Progress;
    }
  }

  const media::MediaGeneration invalidation =
      control.retireInvalidationGeneration;
  const NativeAudioConverterStats converter = control.converter.stats();
  if (control.ring.generation() != invalidation ||
      control.ring.queuedSlabs() != 0 || converter.configured ||
      converter.samplePrepared || converter.sampleRetained) {
    control.latch(NativeAudioSessionFailure::ConsumerProtocol);
    control.state = NativeAudioSessionState::Retiring;
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (control.clockActivated) {
    const NativeMediaClockSnapshot clock = control.clock.sample();
    if (!clock.publicationCurrent || clock.valid || clock.running ||
        clock.generation != invalidation) {
      control.latch(NativeAudioSessionFailure::ClockTransition);
      control.state = NativeAudioSessionState::Retiring;
      return media::NativeMediaConsumerProgress::Failed;
    }
  }

  control.output.reset();
  control.generation = invalidation;
  control.configured = false;
  control.firstAudioSampleAccepted = false;
  control.audioDecodeStart = {};
  control.retireDone = true;
  control.state = NativeAudioSessionState::Closed;
  releaseClaim(control);
  return media::NativeMediaConsumerProgress::Done;
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
       !control.retireDone)) {
    return media::NativeMediaConsumerProgress::Done;
  }
  control.state = NativeAudioSessionState::Closing;
  // Close has absolute precedence over every reversible operation. An older
  // quiescing flush/cancel can never resume Reset/Activate after this point.
  control.lifecycle = SessionLifecycle::None;
  control.lifecycleRetired = 0;
  control.lifecycleTarget = 0;
  control.requestedPaused = true;
  control.renderCore.setPaused(true);
#if defined(WAM_NATIVE_AUDIO_SESSION_TESTING)
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
  control.audioDecodeStart = {};
  control.closeDone = true;
  control.lifecycle = SessionLifecycle::None;
  control.state = NativeAudioSessionState::Closed;
  releaseClaim(control);
  return media::NativeMediaConsumerProgress::Done;
}

NativeMediaClockSnapshot NativeAudioSession::visibleClock() const noexcept {
  if (control_ == nullptr) {
    return {};
  }
  if (control_->retireRequested && control_->clockActivated) {
    return control_->clock.sample();
  }
  if (!control_->configured) {
    return {};
  }
  return control_->renderCore.visibleClock();
}

NativeAudioRenderStats NativeAudioSession::renderStats() const noexcept {
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
  result.sampleRate = control.sampleRate;
  result.presentationFloorFrame = control.presentationFloorFrame;
  const NativePcmRing::Stats ring = control.ring.stats();
  result.ringGeneration = ring.generation;
  result.queuedSlabs = ring.queuedSlabs;
  result.resourceEntered = control.resourceEntered;
  result.configured = control.configured;
  result.requestedPaused = control.requestedPaused;
  result.requestedGain = control.requestedGain;
  result.appliedGain = control.appliedGain;
  result.requestedMuted = control.requestedMuted;
  result.appliedMuted = control.appliedMuted;
  result.controlRevision = control.controlRevision;
  result.appliedControlRevision = control.appliedControlRevision;
  result.endOfStreamRequested = control.endOfStreamRequested;
  result.terminalPublished = control.terminalPublished;
  result.terminalObserved = terminalObserved(control);
  const NativeMediaClockSnapshot clock = control.clock.sample();
  result.clockGeneration = clock.generation;
  result.clockValid = clock.valid;
  result.highestExposedGeneration = control.highestExposedGeneration;
  result.retiredGeneration = control.retireRetiredGeneration;
  result.invalidationGeneration = control.retireInvalidationGeneration;
  result.retireDone = control.retireDone;
  result.closeDone = control.closeDone;
  result.converter = control.converter.stats();
  result.converterDrained = result.converter.drained;
  result.memory.generation = control.generation;
  result.memory.converterGeneration = result.converter.generation;
  result.memory.ringGeneration = ring.generation;
  result.memory.converterRetainedPayloadBytes =
      result.converter.retainedPayloadBytes;
  result.memory.peakConverterRetainedPayloadBytes =
      result.converter.peakRetainedPayloadBytes;
  result.memory.ringUnreadPcmBytes = ring.unreadPcmBytes;
  result.memory.peakRingUnreadPcmBytes = ring.peakUnreadPcmBytes;
  result.memory.generationCoherent =
      result.memory.ringGeneration == result.memory.generation &&
      (result.memory.converterRetainedPayloadBytes == 0 ||
       result.memory.converterGeneration == result.memory.generation);
  if (control.output != nullptr) {
    result.output = control.output->facts();
  }
  return result;
}

bool NativeAudioSession::resetMemoryHighWater(
    media::MediaGeneration expectedGeneration) noexcept {
  if (control_ == nullptr || expectedGeneration == 0) {
    return false;
  }
  NativeAudioSessionControl& control = *control_;
  if (!control.configured ||
      control.state != NativeAudioSessionState::Ready ||
      control.generation != expectedGeneration || control.output == nullptr) {
    return false;
  }
  const NativeAudioConverterStats converter = control.converter.stats();
  const NativePcmRing::Stats ring = control.ring.stats();
  const NativeAudioOutputFacts output = control.output->facts();
  if (converter.generation != expectedGeneration ||
      ring.generation != expectedGeneration || output.started ||
      !output.stopped || !output.callbackQuiescent) {
    return false;
  }

  // Both generation checks were preflighted under the serialized stopped-owner
  // contract, so the two noexcept leaf resets cannot partially fail.
  const bool converterReset =
      control.converter.resetRetainedPayloadByteHighWater(expectedGeneration);
  const bool ringReset =
      control.ring.resetUnreadPcmByteHighWater(expectedGeneration);
  return converterReset && ringReset;
}

} // namespace wam::macos
