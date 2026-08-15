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
    if (first_host_ticks < prior_end_host_ticks_) {
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
      !readable.staleConsumer && readable.frames > input.frameCount) {
    // Resync. Audio the published clock has already passed is retired rather
    // than played: playing it would silently re-introduce exactly the drift
    // that advancing through the underrun refused, leaving every later frame
    // behind its own timestamp, and behind video, for the rest of the
    // generation.
    //
    // Two deliberate bounds. Retirement waits until the debt reaches one
    // producer admission unit, because a debt below that is smaller than the
    // granularity at which the producer publishes at all and is not worth a
    // discontinuity. And catch-up comes only out of surplus, never out of the
    // frames this callback itself needs, so a producer that has only partially
    // recovered still renders its short prefix instead of being starved again.
    const std::size_t surplus = readable.frames - input.frameCount;
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

  std::size_t prefixFrames =
      std::min<std::size_t>(input.frameCount, readable.frames);
  if (terminalCurrent) {
    if (terminalFrame > input.streamFrameStart) {
      prefixFrames = std::min<std::size_t>(
          prefixFrames,
          static_cast<std::size_t>(terminalFrame - input.streamFrameStart));
    }
  }

  if (prefixFrames == 0) {
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
        input.streamFrameStart + input.frameCount;
    const auto silenceStart = media::mediaTimeSecondsAtFrame(
        media_origin_, input.streamFrameStart, input.sampleRate);
    const auto silenceEnd = media::mediaTimeSecondsAtFrame(
        media_origin_, silenceEndFrame, input.sampleRate);
    if (running_ && !terminalCurrent &&
        first_segment_committed_.load(std::memory_order_acquire) &&
        segment_serial_ != std::numeric_limits<std::uint64_t>::max() &&
        silenceStart && silenceEnd && *silenceEnd > *silenceStart &&
        callback_end_host_ticks > first_host_ticks &&
        pending_late_frames_ <=
            std::numeric_limits<std::uint64_t>::max() - input.frameCount) {
      NativeMediaSegment segment;
      segment.serial = segment_serial_ + 1U;
      segment.firstHostTicks = first_host_ticks;
      segment.endHostTicks = callback_end_host_ticks;
      segment.mediaStart = *silenceStart;
      segment.mediaEnd = *silenceEnd;
      segment.continuity =
          (!next_discontinuous_ && prior_end_host_ticks_ == first_host_ticks &&
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
        result.advancedSilentFrames = input.frameCount;
        segment_serial_ = segment.serial;
        cursor_frame_ = silenceEndFrame;
        prior_end_host_ticks_ = callback_end_host_ticks;
        prior_end_frame_ = silenceEndFrame;
        prior_end_sample_time_ = input.endSampleTime;
        prior_sample_time_valid_ =
            input.timing == NativeAudioRenderInput::Timing::SampleTime;
        next_discontinuous_ = false;
        pending_late_frames_ += input.frameCount;
        saturatingAdd(clock_advanced_underruns_, 1);
        return result;
      }
    }
    next_discontinuous_ = true;
    prior_sample_time_valid_ = false;
    return result;
  }

  std::uint64_t segmentEndHostTicks = 0;
  if (prefixFrames > std::numeric_limits<std::uint32_t>::max() ||
      !hostEndpoint(input, static_cast<std::uint32_t>(prefixFrames),
                    &segmentEndHostTicks) ||
      segmentEndHostTicks > callback_end_host_ticks ||
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
    if (!clock_.runAtHostTicks(generation, first_host_ticks, 1.0)) {
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
      !next_discontinuous_ && prior_end_host_ticks_ == first_host_ticks &&
      prior_end_frame_ == input.streamFrameStart &&
      ((input.timing == NativeAudioRenderInput::Timing::HostTicks &&
        !prior_sample_time_valid_) ||
       (input.timing == NativeAudioRenderInput::Timing::SampleTime &&
        prior_sample_time_valid_ &&
        prior_end_sample_time_ == input.firstSampleTime));
  NativeMediaSegment segment;
  segment.serial = segment_serial_ + 1U;
  segment.firstHostTicks = first_host_ticks;
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

  const std::size_t prefixSamples =
      prefixFrames * NativePcmRing::kChannels;
  const NativePcmRing::ConsumeResult consumed = ring_.consume(
      generation, interleavedStereoOutput.first(prefixSamples));
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
  result.pcmFrames = static_cast<std::uint32_t>(prefixFrames);
  result.bufferedPcmFramesAfter -= result.pcmFrames;
  applyGain(interleavedStereoOutput.first(prefixSamples), prefixFrames);
  const std::size_t tailFrames = input.frameCount - prefixFrames;
  if (tailFrames != 0) {
    zero(interleavedStereoOutput.subspan(prefixSamples));
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
