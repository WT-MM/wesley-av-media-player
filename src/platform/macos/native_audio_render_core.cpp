#include "native_audio_render_core.hpp"

#include <algorithm>
#include <bit>
#include <cmath>
#include <limits>
#include <type_traits>

namespace wam::macos {
namespace {

constexpr std::uint64_t kMaximumExactDoubleInteger =
    std::uint64_t{1} << 53U;

// Debt below one producer admission unit is left alone: it is finer than the
// granularity at which PCM is published at all, and retiring it would cost a
// real discontinuity to buy back less than one slab of alignment.
constexpr std::uint64_t kLateFrameResyncThreshold =
    static_cast<std::uint64_t>(NativePcmRing::kFramesPerSlab);

// Playable audio that late-frame retirement may never take. The producer can
// only republish once the consumer retires a slab and its wake round trip
// completes, and that round trip is a DURATION, not a frame count: the same
// number of frames is 8.8% more time at 44.1 kHz than at 48 kHz, and a device
// running a sample-rate converter pulls a non-integral number of stream frames
// per callback, so the frame budget between two publications is not even
// constant within one rate. Retirement that is allowed to strip the ring down
// to exactly the frames this callback needs therefore manufactures the next
// underrun, which advances the clock, which grows the debt, which retires more
// freshly produced audio -- a self-sustaining starvation loop rather than the
// one-shot resync the retirement is meant to be. Reserving a rate-scaled floor
// keeps catch-up strictly to audio the producer is already far enough ahead to
// spare. The floor is capped at one admission unit so it can never exceed what
// the ring itself can hold at the highest admitted rates.
constexpr std::uint64_t kLateFrameRetentionMilliseconds = 40;

[[nodiscard]] constexpr std::uint64_t lateFrameRetentionFloor(
    std::uint32_t sampleRate) noexcept {
  const std::uint64_t scaled = static_cast<std::uint64_t>(sampleRate) *
                               kLateFrameRetentionMilliseconds / 1000U;
  return std::min<std::uint64_t>(
      scaled, static_cast<std::uint64_t>(NativePcmRing::kFramesPerSlab));
}

static_assert(std::atomic<bool>::is_always_lock_free);
static_assert(std::atomic<std::uint8_t>::is_always_lock_free);
static_assert(std::atomic<std::uint32_t>::is_always_lock_free);
static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
static_assert(std::is_trivially_copyable_v<NativeAudioRenderInput>);
static_assert(std::is_trivially_copyable_v<NativeAudioRenderResult>);
static_assert(std::is_trivially_copyable_v<NativeAudioRenderStats>);
static_assert(std::is_trivially_copyable_v<NativeAudioTerminalObservation>);

class CallbackGateGuard final {
public:
  explicit CallbackGateGuard(std::atomic_flag &gate) noexcept : gate_(gate) {}
  ~CallbackGateGuard() { gate_.clear(std::memory_order_release); }

  CallbackGateGuard(const CallbackGateGuard &) = delete;
  CallbackGateGuard &operator=(const CallbackGateGuard &) = delete;

private:
  std::atomic_flag &gate_;
};

[[nodiscard]] constexpr bool acceptedWithoutPcm(
    NativeMediaSegmentReservation reservation) noexcept {
  return reservation.accepted() && !reservation.requiresPcm();
}

[[nodiscard]] bool exactPositionAtFrame(
    media::MediaTime position, media::MediaTime origin,
    std::uint64_t frame, std::uint32_t sampleRate) noexcept {
  if (!position.valid() || !origin.valid() || sampleRate == 0) {
    return false;
  }
  using Wide = __int128_t;
  const Wide originNumerator =
      static_cast<Wide>(origin.value) * static_cast<Wide>(sampleRate) +
      static_cast<Wide>(frame) * static_cast<Wide>(origin.timescale);
  const Wide left = static_cast<Wide>(position.value) *
                    static_cast<Wide>(origin.timescale) *
                    static_cast<Wide>(sampleRate);
  const Wide right = originNumerator *
                     static_cast<Wide>(position.timescale);
  return left == right;
}

} // namespace

NativeAudioRenderCore::NativeAudioRenderCore(
    NativePcmRing &ring, NativeMediaClock &clock,
    std::uint64_t hostTicksPerSecond) noexcept
    : ring_(ring), clock_(clock),
      host_ticks_per_second_(hostTicksPerSecond) {
  target_gain_bits_.store(floatBits(1.0F), std::memory_order_relaxed);
}

bool NativeAudioRenderCore::compatibleHostTicksPerSecond(
    std::uint64_t hostTicksPerSecond) const noexcept {
  return hostTicksPerSecond != 0 &&
         hostTicksPerSecond == host_ticks_per_second_ &&
         hostTicksPerSecond == clock_.ticksPerSecond();
}

void NativeAudioRenderCore::saturatingAdd(
    std::atomic<std::uint64_t> &counter, std::uint64_t amount) noexcept {
  const std::uint64_t current = counter.load(std::memory_order_relaxed);
  const std::uint64_t maximum = std::numeric_limits<std::uint64_t>::max();
  counter.store(amount > maximum - current ? maximum : current + amount,
                std::memory_order_relaxed);
}

std::uint32_t NativeAudioRenderCore::floatBits(float value) noexcept {
  return std::bit_cast<std::uint32_t>(value);
}

float NativeAudioRenderCore::bitsFloat(std::uint32_t value) noexcept {
  return std::bit_cast<float>(value);
}

bool NativeAudioRenderCore::activate(
    std::uint64_t generation, std::uint64_t streamFrameCursor,
    media::MediaTime mediaOrigin, media::MediaTime pausedClockPosition,
    std::uint32_t sampleRate) noexcept {
  if (accepting_.load(std::memory_order_acquire) || generation == 0 ||
      sampleRate == 0 ||
      !compatibleHostTicksPerSecond(host_ticks_per_second_) ||
      streamFrameCursor > kMaximumExactDoubleInteger ||
      !mediaOrigin.valid() ||
      !pausedClockPosition.valid() || pausedClockPosition.value < 0 ||
      ring_.generation() != generation) {
    return false;
  }

  const auto cursorMediaSeconds = media::mediaTimeSecondsAtFrame(
      mediaOrigin, streamFrameCursor, sampleRate);
  const auto pausedMediaSeconds =
      media::mediaTimeSeconds(pausedClockPosition);
  if (!cursorMediaSeconds || !pausedMediaSeconds) {
    return false;
  }

  const auto originsOrder =
      media::compareMediaTime(mediaOrigin, pausedClockPosition);
  if (!originsOrder) {
    return false;
  }
  if (streamFrameCursor == 0) {
    if (*originsOrder != media::MediaTimeOrder::Equal) {
      const auto firstBoundary =
          media::audioFrameAtOrAfter(pausedClockPosition, sampleRate);
      if (!firstBoundary ||
          media::compareMediaTime(mediaOrigin, *firstBoundary) !=
              media::MediaTimeOrder::Equal) {
        return false;
      }
    }
  } else if (!exactPositionAtFrame(pausedClockPosition, mediaOrigin,
                                   streamFrameCursor, sampleRate)) {
    return false;
  }

  const NativeMediaClockSnapshot paused = clock_.sample();
  if (!paused.publicationCurrent || !paused.valid || paused.running ||
      paused.generation != generation ||
      paused.mediaSeconds != *pausedMediaSeconds) {
    return false;
  }

  activation_cursor_frame_ = streamFrameCursor;
  cursor_frame_ = streamFrameCursor;
  segment_serial_ = 0;
  pending_late_frames_ = 0;
  prior_end_host_ticks_ = 0;
  prior_end_frame_ = streamFrameCursor;
  prior_end_sample_time_ = 0;
  active_sample_rate_ = sampleRate;
  media_origin_ = mediaOrigin;
  applied_gain_ = 0.0F;
  ramp_target_ = 0.0F;
  ramp_frames_remaining_ = 0;
  running_ = false;
  next_discontinuous_ = true;
  prior_sample_time_valid_ = false;
  pause_fact_published_ = false;
  // A generation transition is the one place the stretch stage must forget
  // everything: whatever it still holds belongs to the media position the
  // seek just left. The rate itself is a session preference and survives.
  pull_budget_frames_ = 0;
  pull_taken_frames_ = 0;
  pull_ring_failed_ = false;
  active_rate_ = NativePlaybackRate{};
  stretch_latency_output_frames_ = 0;
  if (stretch_installed_.load(std::memory_order_acquire)) {
    stretch_.reset(stretch_.context);
  }
  cached_paused_clock_ = paused;
  first_segment_committed_.store(false, std::memory_order_release);
  terminal_observed_generation_.store(0, std::memory_order_release);
  terminal_published_.store(false, std::memory_order_release);
  terminal_generation_.store(0, std::memory_order_relaxed);
  terminal_frame_.store(0, std::memory_order_relaxed);
  failure_.store(static_cast<std::uint8_t>(NativeAudioRenderFailure::None),
                 std::memory_order_release);
  fail_next_commit_ = false;
  control_generation_.store(generation, std::memory_order_release);
  return true;
}

void NativeAudioRenderCore::setAccepting(bool accepting) noexcept {
  accepting_.store(accepting, std::memory_order_release);
}

void NativeAudioRenderCore::setPaused(bool paused) noexcept {
  paused_.store(paused, std::memory_order_release);
}

bool NativeAudioRenderCore::settlePausedAfterStop(
    std::uint64_t generation) noexcept {
  if (accepting_.load(std::memory_order_acquire) ||
      !paused_.load(std::memory_order_acquire) || generation == 0 ||
      generation != control_generation_.load(std::memory_order_acquire) ||
      callback_gate_.test_and_set(std::memory_order_acquire)) {
    return false;
  }
  const NativeMediaClockSnapshot paused = clock_.sample();
  if (!paused.publicationCurrent || !paused.valid || paused.running ||
      paused.generation != generation) {
    callback_gate_.clear(std::memory_order_release);
    return false;
  }
  running_ = false;
  next_discontinuous_ = true;
  prior_sample_time_valid_ = false;
  pause_fact_published_ = true;
  callback_gate_.clear(std::memory_order_release);
  return true;
}

void NativeAudioRenderCore::setGain(float gain) noexcept {
  const float bounded = std::isfinite(gain)
                            ? std::clamp(gain, 0.0F, 1.0F)
                            : 0.0F;
  target_gain_bits_.store(floatBits(bounded), std::memory_order_release);
}

void NativeAudioRenderCore::setMuted(bool muted) noexcept {
  muted_.store(muted, std::memory_order_release);
}

bool NativeAudioRenderCore::attachStretchStage(
    NativeAudioStretchStage stage) noexcept {
  if (!stage.usable() ||
      stretch_installed_.load(std::memory_order_acquire)) {
    return false;
  }
  if (!stage.configure(stage.context, &NativeAudioRenderCore::stretchPull,
                       this)) {
    return false;
  }
  stretch_ = stage;
  // The release here pairs with every acquire below. A callback that observes
  // the flag observes the whole table; one that does not stays at the unit
  // rate, which needs no stage.
  stretch_installed_.store(true, std::memory_order_release);
  return true;
}

bool NativeAudioRenderCore::setRate(NativePlaybackRate rate) noexcept {
  if (!rate.valid()) {
    return false;
  }
  if (!rate.unity() && !stretch_installed_.load(std::memory_order_acquire)) {
    // Without a stretch stage the only honest answer is refusal: there is
    // nothing in the path that can retime the audio at all.
    return false;
  }
  requested_rate_.store((static_cast<std::uint64_t>(rate.numerator) << 32U) |
                            static_cast<std::uint64_t>(rate.denominator),
                        std::memory_order_release);
  return true;
}

void NativeAudioRenderCore::setPreservePitch(bool preserve) noexcept {
  requested_preserve_pitch_.store(preserve, std::memory_order_release);
}

bool NativeAudioRenderCore::preservePitch() const noexcept {
  return requested_preserve_pitch_.load(std::memory_order_acquire);
}

NativePlaybackRate NativeAudioRenderCore::requestedRate() const noexcept {
  const std::uint64_t packed =
      requested_rate_.load(std::memory_order_acquire);
  return NativePlaybackRate{static_cast<std::uint32_t>(packed >> 32U),
                            static_cast<std::uint32_t>(packed)};
}

std::uint32_t NativeAudioRenderCore::stretchPull(
    void *context, float *interleaved, std::uint32_t frames) noexcept {
  auto *core = static_cast<NativeAudioRenderCore *>(context);
  if (core == nullptr || interleaved == nullptr || frames == 0) {
    return 0;
  }
  // Hard budget. The callback reserved clock time for exactly
  // pull_budget_frames_ media frames; a stage that asks for more gets
  // silence rather than an over-drained ring, so the frame cursor and the
  // published clock stay exact whatever the stage does.
  const std::uint32_t remaining =
      core->pull_budget_frames_ - core->pull_taken_frames_;
  const std::uint32_t wanted = std::min(frames, remaining);
  const std::size_t samples =
      static_cast<std::size_t>(wanted) * NativePcmRing::kChannels;
  if (wanted != 0) {
    const std::uint64_t generation =
        core->control_generation_.load(std::memory_order_relaxed);
    const NativePcmRing::ConsumeResult consumed = core->ring_.consume(
        generation, std::span<float>(interleaved, samples));
    if (consumed.invalidInput || consumed.staleConsumer ||
        consumed.pcmFrames != wanted || consumed.silentFrames != 0) {
      core->pull_ring_failed_ = true;
      std::fill_n(interleaved,
                  static_cast<std::size_t>(frames) * NativePcmRing::kChannels,
                  0.0F);
      return 0;
    }
    core->pull_taken_frames_ += wanted;
  }
  if (wanted < frames) {
    std::fill_n(interleaved + samples,
                (static_cast<std::size_t>(frames) - wanted) *
                    NativePcmRing::kChannels,
                0.0F);
  }
  return wanted;
}

bool NativeAudioRenderCore::hostTicksForOutputFrames(
    NativeAudioRenderInput input, std::uint64_t outputFrames,
    std::uint64_t *ticks) noexcept {
  if (ticks == nullptr || input.hostTickNumeratorPerFrame == 0 ||
      input.hostTickDenominator == 0) {
    return false;
  }
  if (outputFrames == 0) {
    *ticks = 0;
    return true;
  }
  constexpr __uint128_t maximum = ~static_cast<__uint128_t>(0);
  if (input.hostTickNumeratorPerFrame >
      maximum / static_cast<__uint128_t>(outputFrames)) {
    return false;
  }
  const __uint128_t total = input.hostTickNumeratorPerFrame *
                            static_cast<__uint128_t>(outputFrames) /
                            input.hostTickDenominator;
  if (total > std::numeric_limits<std::uint64_t>::max()) {
    return false;
  }
  *ticks = static_cast<std::uint64_t>(total);
  return true;
}

bool NativeAudioRenderCore::publishTerminalFrame(
    std::uint64_t generation, std::uint64_t terminalFrame) noexcept {
  if (generation == 0 ||
      generation != control_generation_.load(std::memory_order_acquire) ||
      terminalFrame > kMaximumExactDoubleInteger ||
      terminal_published_.load(std::memory_order_acquire)) {
    return false;
  }
  terminal_frame_.store(terminalFrame, std::memory_order_relaxed);
  terminal_generation_.store(generation, std::memory_order_relaxed);
  terminal_published_.store(true, std::memory_order_release);
  return true;
}

void NativeAudioRenderCore::clearTerminal(
    std::uint64_t generation) noexcept {
  if (generation != 0 &&
      generation == control_generation_.load(std::memory_order_acquire)) {
    terminal_published_.store(false, std::memory_order_release);
    terminal_generation_.store(0, std::memory_order_relaxed);
    terminal_frame_.store(0, std::memory_order_relaxed);
    std::uint64_t observed = generation;
    static_cast<void>(terminal_observed_generation_.compare_exchange_strong(
        observed, 0, std::memory_order_acq_rel, std::memory_order_acquire));
  }
}

NativeAudioTerminalObservation
NativeAudioRenderCore::terminalObservation() const noexcept {
  return {terminal_observed_generation_.load(std::memory_order_acquire)};
}

bool NativeAudioRenderCore::hostEndpoint(
    NativeAudioRenderInput input, std::uint32_t frameCount,
    std::uint64_t *endHostTicks) noexcept {
  if (endHostTicks == nullptr || frameCount == 0 ||
      input.hostTickNumeratorPerFrame == 0 ||
      input.hostTickDenominator == 0 ||
      input.hostTickRemainderAtStart >= input.hostTickDenominator) {
    return false;
  }

  constexpr __uint128_t maximum = ~static_cast<__uint128_t>(0);
  if (input.hostTickNumeratorPerFrame >
      maximum / static_cast<__uint128_t>(frameCount)) {
    return false;
  }
  const __uint128_t frameNumerator =
      input.hostTickNumeratorPerFrame *
      static_cast<__uint128_t>(frameCount);
  if (input.hostTickRemainderAtStart > maximum - frameNumerator) {
    return false;
  }
  const __uint128_t duration =
      (input.hostTickRemainderAtStart + frameNumerator) /
      input.hostTickDenominator;
  if (duration == 0 ||
      duration > std::numeric_limits<std::uint64_t>::max() -
                     input.firstHostTicks) {
    return false;
  }
  *endHostTicks =
      input.firstHostTicks + static_cast<std::uint64_t>(duration);
  return true;
}

void NativeAudioRenderCore::zero(std::span<float> output) noexcept {
  std::fill_n(output.begin(),
              std::min(output.size(), NativePcmRing::kSamplesPerSlab),
              0.0F);
}

void NativeAudioRenderCore::applyGain(
    std::span<float> output, std::size_t frameCount) noexcept {
  const float requested = muted_.load(std::memory_order_acquire)
                              ? 0.0F
                              : bitsFloat(target_gain_bits_.load(
                                    std::memory_order_acquire));
  if (requested != ramp_target_) {
    ramp_target_ = requested;
    ramp_frames_remaining_ = kGainRampFrames;
  }

  for (std::size_t frame = 0; frame < frameCount; ++frame) {
    if (ramp_frames_remaining_ != 0) {
      applied_gain_ +=
          (ramp_target_ - applied_gain_) /
          static_cast<float>(ramp_frames_remaining_);
      --ramp_frames_remaining_;
    } else {
      applied_gain_ = ramp_target_;
    }
    output[frame * NativePcmRing::kChannels] *= applied_gain_;
    output[frame * NativePcmRing::kChannels + 1U] *= applied_gain_;
  }
}

void NativeAudioRenderCore::latchFailure(
    NativeAudioRenderFailure failure) noexcept {
  if (failure == NativeAudioRenderFailure::None) {
    return;
  }
  std::uint8_t expected =
      static_cast<std::uint8_t>(NativeAudioRenderFailure::None);
  static_cast<void>(failure_.compare_exchange_strong(
      expected, static_cast<std::uint8_t>(failure),
      std::memory_order_acq_rel, std::memory_order_acquire));
}

bool NativeAudioRenderCore::timingRange(
    NativeAudioRenderInput input, std::uint64_t *firstHostTicks,
    std::uint64_t *endHostTicks) const noexcept {
  if (firstHostTicks == nullptr || endHostTicks == nullptr ||
      input.sampleRate == 0 || host_ticks_per_second_ == 0 ||
      !hostEndpoint(input, input.frameCount, endHostTicks) ||
      *endHostTicks != input.endHostTicks) {
    return false;
  }

  switch (input.timing) {
  case NativeAudioRenderInput::Timing::HostTicks:
    *firstHostTicks = input.firstHostTicks;
    return true;

  case NativeAudioRenderInput::Timing::SampleTime: {
    const __int128 sample_delta =
        static_cast<__int128>(input.endSampleTime) -
        static_cast<__int128>(input.firstSampleTime);
    if (sample_delta != static_cast<__int128>(input.frameCount)) {
      return false;
    }
    *firstHostTicks = input.firstHostTicks;
    return true;
  }
  }
  return false;
}

NativeAudioRenderResult NativeAudioRenderCore::render(
    NativeAudioRenderInput input,
    std::span<float> interleavedStereoOutput) noexcept {
  NativeAudioRenderResult result;
  const std::size_t boundedFrames =
      std::min<std::size_t>(input.frameCount,
                            NativePcmRing::kFramesPerSlab);
  const auto silenceAll = [&]() noexcept {
    zero(interleavedStereoOutput);
    result.silentFrames = static_cast<std::uint32_t>(boundedFrames);
    saturatingAdd(silent_frames_, boundedFrames);
  };

  if (callback_gate_.test_and_set(std::memory_order_acquire)) {
    silenceAll();
    result.failure = NativeAudioRenderFailure::ReentrantCallback;
    latchFailure(result.failure);
    saturatingAdd(rejected_callbacks_, 1);
    return result;
  }
  CallbackGateGuard gate(callback_gate_);
  saturatingAdd(callbacks_, 1);
  const bool validShape =
      input.generation != 0 && input.frameCount != 0 &&
      input.frameCount <= NativePcmRing::kFramesPerSlab &&
      input.sampleRate != 0 &&
      interleavedStereoOutput.size() ==
          static_cast<std::size_t>(input.frameCount) *
              NativePcmRing::kChannels;
  std::uint64_t first_host_ticks = 0;
  std::uint64_t callback_end_host_ticks = 0;
  if (!validShape ||
      !timingRange(input, &first_host_ticks, &callback_end_host_ticks) ||
      input.streamFrameStart > kMaximumExactDoubleInteger ||
      input.frameCount >
          kMaximumExactDoubleInteger - input.streamFrameStart) {
    silenceAll();
    result.failure = NativeAudioRenderFailure::InvalidInput;
    latchFailure(result.failure);
    saturatingAdd(rejected_callbacks_, 1);
    return result;
  }

  const std::uint64_t generation =
      control_generation_.load(std::memory_order_acquire);
  if (!accepting_.load(std::memory_order_acquire) ||
      input.generation != generation || input.sampleRate != active_sample_rate_ ||
      input.streamFrameStart != cursor_frame_) {
    silenceAll();
    result.admission = input.generation == generation
                           ? NativeMediaSegmentAdmission::Invalid
                           : NativeMediaSegmentAdmission::Stale;
    next_discontinuous_ = true;
    prior_sample_time_valid_ = false;
    saturatingAdd(rejected_callbacks_, 1);
    return result;
  }

  const NativeAudioRenderFailure latched = failure();
  if (latched != NativeAudioRenderFailure::None) {
    silenceAll();
    result.failure = latched;
    next_discontinuous_ = true;
    prior_sample_time_valid_ = false;
    saturatingAdd(rejected_callbacks_, 1);
    return result;
  }

  if (paused_.load(std::memory_order_acquire)) {
    silenceAll();
    if (!pause_fact_published_) {
      if (running_ && !clock_.pause(generation)) {
        result.failure = NativeAudioRenderFailure::ClockCommitFailed;
        latchFailure(result.failure);
        next_discontinuous_ = true;
        prior_sample_time_valid_ = false;
        saturatingAdd(rejected_callbacks_, 1);
        return result;
      }
      running_ = false;
      pause_fact_published_ = true;
      result.pauseBoundary = true;
      saturatingAdd(pause_boundaries_, 1);
    }
    next_discontinuous_ = true;
    prior_sample_time_valid_ = false;
    return result;
  }
  pause_fact_published_ = false;

  // Rate boundary. A rate change is latched here and nowhere else: this is
  // the only instant at which the stage's stretch factor and the core's
  // media-frame accounting can move together, so the exact rational every
  // frame below is accounted at is fixed for the whole callback. It lands
  // like a small seek -- the stage's group delay changes with the rate, so
  // the interval that follows is deliberately discontinuous, which is the
  // same shape the clock already absorbs across a seek or a pause.
  {
    const NativePlaybackRate requested = requestedRate();
    const bool requestedPreservePitch =
        requested_preserve_pitch_.load(std::memory_order_acquire);
    const bool stretchAvailable =
        stretch_installed_.load(std::memory_order_acquire);
    const bool rateChanged = requested != active_rate_;
    const bool pitchChanged = requestedPreservePitch != active_preserve_pitch_;
    if ((rateChanged || pitchChanged) && requested.valid() &&
        (requested.unity() || stretchAvailable)) {
      if (!requested.unity() &&
          !stretch_.setRate(stretch_.context, requested.numerator,
                            requested.denominator, requestedPreservePitch)) {
        silenceAll();
        result.failure = NativeAudioRenderFailure::StretchStageFailed;
        latchFailure(result.failure);
        saturatingAdd(rejected_callbacks_, 1);
        return result;
      }
      active_rate_ = requested;
      // Latched even at the unit rate, where nothing is applied: the pitch
      // offset of rate 1 is zero cents, so a toggle at 1x is a pure
      // bookkeeping update that leaves this callback -- and its output --
      // exactly as it was.
      active_preserve_pitch_ = requestedPreservePitch;
      if (rateChanged) {
        // Group delay is a function of the rate alone, so only a rate change
        // moves the endpoint shift and only a rate change is a discontinuity.
        // A pitch-only change consumes the same frames on the same schedule.
        stretch_latency_output_frames_ =
            requested.unity() ? 0U
                              : stretch_.latencyOutputFrames(stretch_.context);
        next_discontinuous_ = true;
        prior_sample_time_valid_ = false;
        saturatingAdd(rate_changes_, 1);
      }
    }
  }
  const NativePlaybackRate rate = active_rate_;
  const std::uint64_t rateNumerator = rate.numerator;
  const std::uint64_t rateDenominator = rate.denominator;

  // Group-delay shift. Audio leaving the ring in this callback is HEARD
  // stretch_latency_output_frames_ output frames later, so every host
  // endpoint this callback publishes is moved forward by exactly that much.
  // The shift is constant for a given rate, so it cancels out of the
  // adjacency proof (prior end == this start) and out of the coalescing
  // identities; only a rate change moves it, and that boundary is already
  // marked discontinuous above. At the unit rate it is exactly zero and
  // every expression below reduces to the pre-rate arithmetic verbatim.
  std::uint64_t latency_ticks = 0;
  if (stretch_latency_output_frames_ != 0 &&
      !hostTicksForOutputFrames(input, stretch_latency_output_frames_,
                                &latency_ticks)) {
    silenceAll();
    result.failure = NativeAudioRenderFailure::InvalidInput;
    latchFailure(result.failure);
    next_discontinuous_ = true;
    prior_sample_time_valid_ = false;
    saturatingAdd(rejected_callbacks_, 1);
    return result;
  }
  if (latency_ticks >
          std::numeric_limits<std::uint64_t>::max() - first_host_ticks ||
      latency_ticks > std::numeric_limits<std::uint64_t>::max() -
                          callback_end_host_ticks) {
    silenceAll();
    result.failure = NativeAudioRenderFailure::InvalidInput;
    latchFailure(result.failure);
    next_discontinuous_ = true;
    prior_sample_time_valid_ = false;
    saturatingAdd(rejected_callbacks_, 1);
    return result;
  }
  const std::uint64_t heard_first_host_ticks =
      first_host_ticks + latency_ticks;
  const std::uint64_t heard_callback_end_host_ticks =
      callback_end_host_ticks + latency_ticks;

  // Media frames this callback would advance if the ring were full. Exact:
  // the denominator divides the device period, so there is no residual to
  // carry and no rounding for the stage to disagree with.
  const std::uint64_t full_output_frames =
      static_cast<std::uint64_t>(input.frameCount) -
      static_cast<std::uint64_t>(input.frameCount) % rateDenominator;
  const std::uint64_t full_media_frames =
      full_output_frames * rateNumerator / rateDenominator;

  // Capture the terminal publication exactly once per callback. A later
  // publication belongs to the next callback and cannot inconsistently alter
  // prefix clamping after this callback has passed the EOF decision.
  const bool terminalPublished =
      terminal_published_.load(std::memory_order_acquire);
  const std::uint64_t terminalGeneration =
      terminalPublished
          ? terminal_generation_.load(std::memory_order_relaxed)
          : 0;
  const std::uint64_t terminalFrame =
      terminalPublished ? terminal_frame_.load(std::memory_order_relaxed) : 0;
  const bool terminalCurrent =
      terminalPublished && terminalGeneration == generation;
  if (terminalCurrent && input.streamFrameStart > terminalFrame) {
    silenceAll();
    result.failure = NativeAudioRenderFailure::InvalidInput;
    latchFailure(result.failure);
    next_discontinuous_ = true;
    prior_sample_time_valid_ = false;
    saturatingAdd(rejected_callbacks_, 1);
    return result;
  }
  if (terminalCurrent && input.streamFrameStart == terminalFrame) {
    silenceAll();
    if (heard_first_host_ticks < prior_end_host_ticks_) {
      result.admission = NativeMediaSegmentAdmission::Invalid;
      next_discontinuous_ = true;
      prior_sample_time_valid_ = false;
      saturatingAdd(rejected_callbacks_, 1);
      return result;
    }

    const bool committedPlayableBoundary =
        first_segment_committed_.load(std::memory_order_acquire) &&
        prior_end_frame_ == terminalFrame;
    const bool emptyGenerationBoundary =
        !first_segment_committed_.load(std::memory_order_relaxed) &&
        terminalFrame == activation_cursor_frame_;
    if (!committedPlayableBoundary && !emptyGenerationBoundary) {
      result.admission = NativeMediaSegmentAdmission::Invalid;
      next_discontinuous_ = true;
      prior_sample_time_valid_ = false;
      saturatingAdd(rejected_callbacks_, 1);
      return result;
    }

    std::uint64_t observed = 0;
    if (terminal_observed_generation_.compare_exchange_strong(
            observed, generation, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
      result.endOfStream = true;
      saturatingAdd(eof_facts_, 1);
    } else if (observed != generation) {
      result.failure = NativeAudioRenderFailure::InvalidInput;
      latchFailure(result.failure);
      saturatingAdd(rejected_callbacks_, 1);
    }
    next_discontinuous_ = true;
    prior_sample_time_valid_ = false;
    return result;
  }

  NativePcmRing::ReadableFramesResult readable =
      ring_.readableFrames(generation);
  if (pending_late_frames_ >= kLateFrameResyncThreshold &&
      !readable.staleConsumer && readable.frames > full_media_frames) {
    // Resync. Audio the published clock has already passed is retired rather
    // than played: playing it would silently re-introduce exactly the drift
    // that advancing through the underrun refused, leaving every later frame
    // behind its own timestamp, and behind video, for the rest of the
    // generation.
    //
    // Three deliberate bounds. Retirement waits until the debt reaches one
    // producer admission unit, because a debt below that is smaller than the
    // granularity at which the producer publishes at all and is not worth a
    // discontinuity. Catch-up comes only out of surplus, never out of the
    // frames this callback itself needs, so a producer that has only partially
    // recovered still renders its short prefix instead of being starved again.
    // And the surplus is measured above a rate-scaled retention floor, so a
    // producer that has only just caught up keeps the refill headroom it needs
    // to reach its next publication instead of having it retired out from
    // under it.
    // Every quantity here is MEDIA frames, so the frames this callback needs
    // is its rate-scaled demand, not its output frame count.
    const std::uint64_t reserved =
        full_media_frames + lateFrameRetentionFloor(input.sampleRate);
    const std::size_t surplus =
        readable.frames > reserved
            ? static_cast<std::size_t>(readable.frames - reserved)
            : 0U;
    const std::size_t requested = static_cast<std::size_t>(
        std::min<std::uint64_t>(pending_late_frames_, surplus));
    const std::size_t retired = ring_.discard(generation, requested);
    pending_late_frames_ -= retired;
    readable.frames -= retired;
    saturatingAdd(retired_late_frames_, retired);
  }
  if (after_preflight_hook_ != nullptr) {
    after_preflight_hook_(after_preflight_context_);
  }
  const NativeAudioRenderFailure failureAfterHook = failure();
  if (failureAfterHook != NativeAudioRenderFailure::None) {
    silenceAll();
    result.failure = failureAfterHook;
    next_discontinuous_ = true;
    prior_sample_time_valid_ = false;
    saturatingAdd(rejected_callbacks_, 1);
    return result;
  }
  if (readable.staleConsumer) {
    silenceAll();
    result.admission = NativeMediaSegmentAdmission::Stale;
    next_discontinuous_ = true;
    prior_sample_time_valid_ = false;
    saturatingAdd(rejected_callbacks_, 1);
    return result;
  }
  result.bufferedPcmFramesAfter = static_cast<std::uint32_t>(
      std::min<std::size_t>(readable.frames,
                            std::numeric_limits<std::uint32_t>::max()));
  result.bufferedPcmFramesKnown = true;

  // Output frames this callback will actually fill with real audio, and the
  // media frames they consume. `outputFrames` is always a multiple of the
  // rate denominator, so `prefixFrames = outputFrames * p / q` is exact and
  // the stretch stage's own rounding has nothing to disagree with. At the
  // unit rate the pair collapses to the historical
  // `min(frameCount, readable)` verbatim.
  const auto mediaLimitedOutput =
      [rateNumerator, rateDenominator](std::uint64_t mediaFrames) noexcept {
        const std::uint64_t candidate =
            mediaFrames / rateNumerator * rateDenominator +
            mediaFrames % rateNumerator * rateDenominator / rateNumerator;
        return candidate - candidate % rateDenominator;
      };
  std::uint64_t outputFrames = std::min<std::uint64_t>(
      full_output_frames, mediaLimitedOutput(readable.frames));
  if (terminalCurrent && terminalFrame > input.streamFrameStart) {
    outputFrames = std::min<std::uint64_t>(
        outputFrames,
        mediaLimitedOutput(terminalFrame - input.streamFrameStart));
  }
  const std::size_t prefixFrames = static_cast<std::size_t>(
      outputFrames * rateNumerator / rateDenominator);

  if (outputFrames == 0 || prefixFrames == 0) {
    silenceAll();
    saturatingAdd(underrun_callbacks_, 1);
    result.admission = NativeMediaSegmentAdmission::Backpressure;
    // Clock resilience. A steady-state underrun is a producer that was late,
    // not time standing still: the device really did consume this interval.
    // Publishing it as elapsed media time keeps the audio-owned clock moving,
    // which is what lets the video route retire frames it can no longer
    // present and lets the dispatcher's read gate reopen. Freezing the clock
    // here is what turned a transient underrun into a whole-pipeline deadlock.
    //
    // This is deliberately confined to steady-state playback: it requires a
    // running generation that has already committed a real PCM segment, so it
    // can never manufacture the first segment of a generation and cannot touch
    // the exact seek/EOF generation-start boundaries.
    const std::uint64_t silenceEndFrame =
        input.streamFrameStart + full_media_frames;
    const auto silenceStart = media::mediaTimeSecondsAtFrame(
        media_origin_, input.streamFrameStart, input.sampleRate);
    const auto silenceEnd = media::mediaTimeSecondsAtFrame(
        media_origin_, silenceEndFrame, input.sampleRate);
    if (running_ && !terminalCurrent && full_media_frames != 0 &&
        first_segment_committed_.load(std::memory_order_acquire) &&
        segment_serial_ != std::numeric_limits<std::uint64_t>::max() &&
        silenceStart && silenceEnd && *silenceEnd > *silenceStart &&
        heard_callback_end_host_ticks > heard_first_host_ticks &&
        pending_late_frames_ <=
            std::numeric_limits<std::uint64_t>::max() - full_media_frames) {
      NativeMediaSegment segment;
      segment.serial = segment_serial_ + 1U;
      segment.firstHostTicks = heard_first_host_ticks;
      segment.endHostTicks = heard_callback_end_host_ticks;
      segment.mediaStart = *silenceStart;
      segment.mediaEnd = *silenceEnd;
      segment.continuity =
          (!next_discontinuous_ &&
           prior_end_host_ticks_ == heard_first_host_ticks &&
           prior_end_frame_ == input.streamFrameStart)
              ? NativeMediaSegmentContinuity::Continuous
              : NativeMediaSegmentContinuity::Discontinuous;
      const NativeMediaSegmentAdmission admission =
          clock_.observeSegment(generation, segment);
      if (nativeMediaSegmentAccepted(admission)) {
        result.admission = admission;
        result.committed = true;
        result.continuous =
            segment.continuity == NativeMediaSegmentContinuity::Continuous;
        result.advancedSilentFrames =
            static_cast<std::uint32_t>(full_media_frames);
        segment_serial_ = segment.serial;
        cursor_frame_ = silenceEndFrame;
        prior_end_host_ticks_ = heard_callback_end_host_ticks;
        prior_end_frame_ = silenceEndFrame;
        prior_end_sample_time_ = input.endSampleTime;
        prior_sample_time_valid_ =
            input.timing == NativeAudioRenderInput::Timing::SampleTime;
        next_discontinuous_ = false;
        pending_late_frames_ += full_media_frames;
        saturatingAdd(clock_advanced_underruns_, 1);
        return result;
      }
    }
    next_discontinuous_ = true;
    prior_sample_time_valid_ = false;
    return result;
  }

  // The host span an interval covers is the span of the OUTPUT frames the
  // device will play, never the media frames they were stretched from. That
  // separation is the whole of rate support in the clock domain: the same
  // exact rational endpoint machinery, evaluated at outputFrames rather than
  // at prefixFrames, makes the interval's derived rate exactly p/q.
  std::uint64_t outputEndHostTicks = 0;
  const bool endpointUsable =
      outputFrames <= std::numeric_limits<std::uint32_t>::max() &&
      prefixFrames <= std::numeric_limits<std::uint32_t>::max() &&
      hostEndpoint(input, static_cast<std::uint32_t>(outputFrames),
                   &outputEndHostTicks) &&
      outputEndHostTicks <=
          std::numeric_limits<std::uint64_t>::max() - latency_ticks;
  const std::uint64_t segmentEndHostTicks =
      endpointUsable ? outputEndHostTicks + latency_ticks : 0;
  if (!endpointUsable ||
      segmentEndHostTicks > heard_callback_end_host_ticks ||
      segment_serial_ == std::numeric_limits<std::uint64_t>::max()) {
    silenceAll();
    result.failure = NativeAudioRenderFailure::InvalidInput;
    latchFailure(result.failure);
    next_discontinuous_ = true;
    prior_sample_time_valid_ = false;
    saturatingAdd(rejected_callbacks_, 1);
    return result;
  }

  const std::uint64_t endFrame =
      input.streamFrameStart + static_cast<std::uint64_t>(prefixFrames);
  const auto mediaStart = media::mediaTimeSecondsAtFrame(
      media_origin_, input.streamFrameStart, input.sampleRate);
  const auto mediaEnd = media::mediaTimeSecondsAtFrame(
      media_origin_, endFrame, input.sampleRate);
  if (!mediaStart || !mediaEnd || !(*mediaEnd > *mediaStart)) {
    silenceAll();
    result.failure = NativeAudioRenderFailure::InvalidInput;
    latchFailure(result.failure);
    next_discontinuous_ = true;
    prior_sample_time_valid_ = false;
    saturatingAdd(rejected_callbacks_, 1);
    return result;
  }

  if (!running_) {
    // The resume anchor carries the exact rational as its double. It is only
    // the unbounded fallback slope -- every published interval derives its
    // own rate from endpoints that are exact by construction -- but it must
    // still name the right speed for the instant before the first interval
    // of this run lands.
    if (!clock_.runAtHostTicks(generation, heard_first_host_ticks,
                               rate.toDouble())) {
      silenceAll();
      result.failure = NativeAudioRenderFailure::ResumeRejected;
      latchFailure(result.failure);
      next_discontinuous_ = true;
      prior_sample_time_valid_ = false;
      saturatingAdd(rejected_callbacks_, 1);
      return result;
    }
    running_ = true;
  }

  const bool continuous =
      !next_discontinuous_ &&
      prior_end_host_ticks_ == heard_first_host_ticks &&
      prior_end_frame_ == input.streamFrameStart &&
      ((input.timing == NativeAudioRenderInput::Timing::HostTicks &&
        !prior_sample_time_valid_) ||
       (input.timing == NativeAudioRenderInput::Timing::SampleTime &&
        prior_sample_time_valid_ &&
        prior_end_sample_time_ == input.firstSampleTime));
  NativeMediaSegment segment;
  segment.serial = segment_serial_ + 1U;
  segment.firstHostTicks = heard_first_host_ticks;
  segment.endHostTicks = segmentEndHostTicks;
  segment.mediaStart = *mediaStart;
  segment.mediaEnd = *mediaEnd;
  segment.continuity = continuous
                           ? NativeMediaSegmentContinuity::Continuous
                           : NativeMediaSegmentContinuity::Discontinuous;

  const NativeMediaSegmentReservation reservation =
      clock_.reserveSegment(generation, segment);
  result.admission = reservation.admission;
  if (!reservation.accepted()) {
    silenceAll();
    next_discontinuous_ = true;
    prior_sample_time_valid_ = false;
    saturatingAdd(rejected_callbacks_, 1);
    return result;
  }

  if (acceptedWithoutPcm(reservation)) {
    bool committed = false;
    if (fail_next_commit_) {
      fail_next_commit_ = false;
      static_cast<void>(clock_.cancelSegment(reservation));
    } else {
      committed = clock_.commitSegment(reservation);
    }
    if (!committed) {
      silenceAll();
      result.failure = NativeAudioRenderFailure::ClockCommitFailed;
      latchFailure(result.failure);
      next_discontinuous_ = true;
      prior_sample_time_valid_ = false;
      saturatingAdd(rejected_callbacks_, 1);
      return result;
    }
    result.committed = true;
    segment_serial_ = segment.serial;
    zero(interleavedStereoOutput);
    result.silentFrames = input.frameCount;
    saturatingAdd(silent_frames_, input.frameCount);
    saturatingAdd(metadata_corrections_, 1);
    next_discontinuous_ = true;
    prior_sample_time_valid_ = false;
    return result;
  }

  const std::size_t outputSamples =
      static_cast<std::size_t>(outputFrames) * NativePcmRing::kChannels;
  if (rate.unity()) {
    const NativePcmRing::ConsumeResult consumed = ring_.consume(
        generation, interleavedStereoOutput.first(outputSamples));
    if (consumed.invalidInput || consumed.staleConsumer || consumed.underrun ||
        consumed.pcmFrames != prefixFrames || consumed.silentFrames != 0) {
      static_cast<void>(clock_.cancelSegment(reservation));
      zero(interleavedStereoOutput);
      result.silentFrames = input.frameCount;
      result.failure = NativeAudioRenderFailure::RingContractViolation;
      latchFailure(result.failure);
      next_discontinuous_ = true;
      prior_sample_time_valid_ = false;
      saturatingAdd(silent_frames_, input.frameCount);
      saturatingAdd(rejected_callbacks_, 1);
      return result;
    }
  } else {
    // The stage pulls its own input through stretchPull(), which is budgeted
    // at exactly the media frames this reservation covers. Whatever the stage
    // asks for, the ring can therefore drain by at most that much, so the
    // frame cursor stays exactly where the committed interval says it is.
    pull_budget_frames_ = static_cast<std::uint32_t>(prefixFrames);
    pull_taken_frames_ = 0;
    pull_ring_failed_ = false;
    const bool rendered = stretch_.render(
        stretch_.context, static_cast<std::uint32_t>(outputFrames),
        interleavedStereoOutput.data());
    const std::uint32_t taken = pull_taken_frames_;
    const bool ringFailed = pull_ring_failed_;
    pull_budget_frames_ = 0;
    pull_taken_frames_ = 0;
    if (!rendered || ringFailed) {
      static_cast<void>(clock_.cancelSegment(reservation));
      zero(interleavedStereoOutput);
      result.silentFrames = input.frameCount;
      result.failure = ringFailed
                           ? NativeAudioRenderFailure::RingContractViolation
                           : NativeAudioRenderFailure::StretchStageFailed;
      latchFailure(result.failure);
      next_discontinuous_ = true;
      prior_sample_time_valid_ = false;
      saturatingAdd(silent_frames_, input.frameCount);
      saturatingAdd(rejected_callbacks_, 1);
      return result;
    }
    if (taken < prefixFrames) {
      // A stage that under-pulled produced audio for less media than the
      // interval about to commit describes. Retiring the difference is the
      // only way to keep the cursor and the clock agreeing; the alternative
      // is a permanent offset between them. Measured stages never take this
      // branch, so it is counted rather than tolerated silently.
      const std::size_t shortfall =
          static_cast<std::size_t>(prefixFrames) - taken;
      static_cast<void>(ring_.discard(generation, shortfall));
      saturatingAdd(stretch_shortfall_frames_, shortfall);
    }
    saturatingAdd(stretched_callbacks_, 1);
  }

  bool committed = false;
  if (fail_next_commit_) {
    fail_next_commit_ = false;
    static_cast<void>(clock_.cancelSegment(reservation));
  } else {
    committed = clock_.commitSegment(reservation);
  }
  if (!committed) {
    zero(interleavedStereoOutput);
    result.silentFrames = input.frameCount;
    result.failure = NativeAudioRenderFailure::ClockCommitFailed;
    latchFailure(result.failure);
    next_discontinuous_ = true;
    prior_sample_time_valid_ = false;
    saturatingAdd(silent_frames_, input.frameCount);
    saturatingAdd(rejected_callbacks_, 1);
    return result;
  }

  segment_serial_ = segment.serial;
  cursor_frame_ = endFrame;
  prior_end_host_ticks_ = segmentEndHostTicks;
  prior_end_frame_ = endFrame;
  prior_end_sample_time_ = input.endSampleTime;
  prior_sample_time_valid_ =
      input.timing == NativeAudioRenderInput::Timing::SampleTime;
  first_segment_committed_.store(true, std::memory_order_release);
  result.committed = true;
  result.continuous = continuous;
  // pcmFrames is what the platform adapter advances its cursor by, and that
  // cursor is the MEDIA cursor -- so it is the media frames retired, not the
  // device frames emitted. The two differ by exactly the rate.
  result.pcmFrames = static_cast<std::uint32_t>(prefixFrames);
  result.bufferedPcmFramesAfter -= result.pcmFrames;
  applyGain(interleavedStereoOutput.first(outputSamples),
            static_cast<std::size_t>(outputFrames));
  const std::size_t tailFrames =
      input.frameCount - static_cast<std::size_t>(outputFrames);
  if (tailFrames != 0) {
    zero(interleavedStereoOutput.subspan(outputSamples));
    result.silentFrames = static_cast<std::uint32_t>(tailFrames);
    saturatingAdd(silent_frames_, tailFrames);
    saturatingAdd(underrun_callbacks_, 1);
    next_discontinuous_ = true;
    prior_sample_time_valid_ = false;
  } else {
    next_discontinuous_ = false;
  }
  saturatingAdd(rendered_frames_, prefixFrames);
  return result;
}


NativeMediaClockSnapshot NativeAudioRenderCore::visibleClock() const noexcept {
  if (!first_segment_committed_.load(std::memory_order_acquire)) {
    return cached_paused_clock_;
  }
  return clock_.sample();
}

NativeAudioRenderStats NativeAudioRenderCore::stats() const noexcept {
  NativeAudioRenderStats result;
  result.callbacks = callbacks_.load(std::memory_order_relaxed);
  result.renderedFrames = rendered_frames_.load(std::memory_order_relaxed);
  result.silentFrames = silent_frames_.load(std::memory_order_relaxed);
  result.rejectedCallbacks =
      rejected_callbacks_.load(std::memory_order_relaxed);
  result.underrunCallbacks =
      underrun_callbacks_.load(std::memory_order_relaxed);
  result.clockAdvancedUnderruns =
      clock_advanced_underruns_.load(std::memory_order_relaxed);
  result.retiredLateFrames =
      retired_late_frames_.load(std::memory_order_relaxed);
  result.metadataCorrections =
      metadata_corrections_.load(std::memory_order_relaxed);
  result.pauseBoundaries = pause_boundaries_.load(std::memory_order_relaxed);
  result.endOfStreamFacts = eof_facts_.load(std::memory_order_relaxed);
  result.stretchedCallbacks =
      stretched_callbacks_.load(std::memory_order_relaxed);
  result.stretchShortfallFrames =
      stretch_shortfall_frames_.load(std::memory_order_relaxed);
  result.rateChanges = rate_changes_.load(std::memory_order_relaxed);
  result.rate = requestedRate();
  result.failure = failure();
  return result;
}

NativeAudioRenderFailure NativeAudioRenderCore::failure() const noexcept {
  return static_cast<NativeAudioRenderFailure>(
      failure_.load(std::memory_order_acquire));
}

std::size_t NativeAudioRenderCore::queuedRingSlabs() const noexcept {
  return ring_.queuedSlabs();
}

} // namespace wam::macos
