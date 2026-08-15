#pragma once

#include "media/native_media_source.hpp"
#include "native_media_clock.hpp"
#include "native_pcm_ring.hpp"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <span>

namespace wam::macos {

struct NativeAudioRenderCoreTestAccess;

// Exact callback metadata supplied by the platform adapter. streamFrameStart
// is the generation-local media cursor. Host endpoints use the exact rational
// endpoint(N) = firstHostTicks +
// floor((hostTickRemainderAtStart + hostTickNumeratorPerFrame * N) /
//       hostTickDenominator).
// The adapter owns full hardware-callback carry; the core uses this immutable
// rational to derive an exact playable-prefix endpoint. SampleTime additionally
// proves integral callback-frame continuity.
struct NativeAudioRenderInput {
  enum class Timing : std::uint8_t {
    HostTicks,
    SampleTime,
  };

  std::uint64_t generation{0};
  std::uint64_t streamFrameStart{0};
  std::uint64_t firstHostTicks{0};
  std::uint64_t endHostTicks{0};
  __uint128_t hostTickNumeratorPerFrame{0};
  __uint128_t hostTickDenominator{0};
  __uint128_t hostTickRemainderAtStart{0};
  std::int64_t firstSampleTime{0};
  std::int64_t endSampleTime{0};
  std::uint32_t sampleRate{0};
  std::uint32_t frameCount{0};
  Timing timing{Timing::HostTicks};
};

enum class NativeAudioRenderFailure : std::uint8_t {
  None,
  InvalidInput,
  ReentrantCallback,
  ResumeRejected,
  RingContractViolation,
  ClockCommitFailed,
};

struct NativeAudioRenderResult {
  std::uint32_t pcmFrames{0};
  std::uint32_t silentFrames{0};
  // Frames of generation-local media time published as elapsed across a real
  // device interval the producer could not fill. The platform adapter must
  // advance its stream frame cursor by pcmFrames + advancedSilentFrames so the
  // next callback still describes the exact media position the clock has
  // already published.
  std::uint32_t advancedSilentFrames{0};
  // Exact consumer-side lower bound captured from the same ring preflight as
  // this render. A concurrent producer may only make the real value larger.
  // This is an observation of remaining playable audio, not a producer
  // admission fact: the producer publishes whole slabs, so queuedRingSlabs()
  // rather than any frame threshold decides when it may publish again.
  std::uint32_t bufferedPcmFramesAfter{0};
  NativeMediaSegmentAdmission admission{
      NativeMediaSegmentAdmission::Invalid};
  NativeAudioRenderFailure failure{NativeAudioRenderFailure::None};
  bool pauseBoundary{false};
  bool endOfStream{false};
  bool committed{false};
  bool continuous{false};
  bool bufferedPcmFramesKnown{false};
};

struct NativeAudioRenderStats {
  std::uint64_t callbacks{0};
  std::uint64_t renderedFrames{0};
  std::uint64_t silentFrames{0};
  std::uint64_t rejectedCallbacks{0};
  std::uint64_t underrunCallbacks{0};
  // Underruns whose elapsed device interval was published as media time
  // instead of freezing the clock, and the frames later retired unplayed.
  std::uint64_t clockAdvancedUnderruns{0};
  std::uint64_t retiredLateFrames{0};
  std::uint64_t metadataCorrections{0};
  std::uint64_t pauseBoundaries{0};
  std::uint64_t endOfStreamFacts{0};
  NativeAudioRenderFailure failure{NativeAudioRenderFailure::None};
};

// A durable one-shot observation that the render callback reached the exact
// configured terminal boundary. Generation zero means no terminal has been
// observed. The generation tag lets an owner reject a fact sampled across a
// quiescent flush/activation transition without relying on callback timing.
struct NativeAudioTerminalObservation {
  std::uint64_t generation{0};

  [[nodiscard]] constexpr bool observed() const noexcept {
    return generation != 0;
  }
};

// Allocation-, lock-, wait-, string-, and log-free callback core. One render
// callback owns render(); one producer owns NativePcmRing::publish(). Control
// methods may change atomics concurrently, except activate(), which is a
// quiescent generation transition performed while accepting is false.
class NativeAudioRenderCore final {
public:
  static constexpr std::uint32_t kGainRampFrames = 128;

  NativeAudioRenderCore(NativePcmRing &ring,
                        NativeMediaClock &clock,
                        std::uint64_t hostTicksPerSecond) noexcept;

  NativeAudioRenderCore(const NativeAudioRenderCore &) = delete;
  NativeAudioRenderCore &operator=(const NativeAudioRenderCore &) = delete;
  NativeAudioRenderCore(NativeAudioRenderCore &&) = delete;
  NativeAudioRenderCore &operator=(NativeAudioRenderCore &&) = delete;

  // Exact composition proof for the platform adapter. This checks both the
  // render core's immutable constructor frequency and the media clock's
  // authoritative host seam so duplicate configuration cannot drift.
  [[nodiscard]] bool compatibleHostTicksPerSecond(
      std::uint64_t hostTicksPerSecond) const noexcept;

  // Resets generation-local callback state and captures the authoritative
  // paused clock exposed until the first segment commits. mediaOrigin is the
  // exact media position of generation-local frame zero; streamFrameCursor is
  // an independent ring/output cursor. Every clock interval is derived from
  // mediaOrigin + frame/sampleRate with checked integer arithmetic. The ring
  // and clock must already carry this exact generation. pausedClockPosition
  // is the exact generation commit position exposed before the first PCM
  // segment. At cursor zero, mediaOrigin may instead be its first audio-frame
  // boundary at or after pausedClockPosition; that first source frame is not
  // relabelled and therefore begins a discontinuous clock segment.
  // This quiescent transition happens before accepting callbacks and before
  // any observer may call visibleClock(); cached snapshot publication is not
  // designed to race activate().
  [[nodiscard]] bool activate(std::uint64_t generation,
                              std::uint64_t streamFrameCursor,
                              media::MediaTime mediaOrigin,
                              media::MediaTime pausedClockPosition,
                              std::uint32_t sampleRate) noexcept;
  void setAccepting(bool accepting) noexcept;
  void setPaused(bool paused) noexcept;
  // Quiescent owner transition after the platform output has returned an
  // exact Done stop. The caller first requests paused=true, revokes callback
  // admission, stops the output, and pauses the authoritative clock. This
  // reconciles the callback-local running fact without consuming queued PCM or
  // changing generation/cursor state, so a later callback must establish a
  // fresh runAtHostTicks anchor. False means one of those proofs was absent.
  [[nodiscard]] bool settlePausedAfterStop(
      std::uint64_t generation) noexcept;
  void setGain(float gain) noexcept;
  void setMuted(bool muted) noexcept;

  // Marks the exact generation-local frame after the final decoded PCM frame.
  // The boundary is immutable until clearTerminal() or activate(). EOF is a
  // one-shot fact only when a valid callback begins exactly at this boundary
  // after the final playable interval committed. An ordinary zero-fill,
  // underrun, or callback beyond the boundary never implies EOF.
  [[nodiscard]] bool publishTerminalFrame(
      std::uint64_t generation, std::uint64_t terminalFrame) noexcept;

  // Quiescent producer/control operation: callback admission and PCM
  // publication for this generation must already be stopped. The compare-
  // exchange reset cannot erase an observation from a newer generation.
  void clearTerminal(std::uint64_t generation) noexcept;

  [[nodiscard]] NativeAudioTerminalObservation
  terminalObservation() const noexcept;

  [[nodiscard]] NativeAudioRenderResult
  render(NativeAudioRenderInput input,
         std::span<float> interleavedStereoOutput) noexcept;

  // Hides a speculative first resume until a segment has committed. Observers
  // may race render(), but begin only after the quiescent activate() contract.
  [[nodiscard]] NativeMediaClockSnapshot visibleClock() const noexcept;
  [[nodiscard]] NativeAudioRenderStats stats() const noexcept;
  [[nodiscard]] NativeAudioRenderFailure failure() const noexcept;
  // Bounded, allocation-free observation of the ring's queued slab count. A
  // slab is the producer's exact admission unit, so a drop in this count is
  // the exact edge on which the producer may publish again. The render
  // callback reads it after consuming; a concurrent producer can only make the
  // real value larger, so the observed drop is never spurious.
  [[nodiscard]] std::size_t queuedRingSlabs() const noexcept;

private:
  using TestHook = void (*)(void *context) noexcept;

  static void saturatingAdd(std::atomic<std::uint64_t> &counter,
                            std::uint64_t amount) noexcept;
  static std::uint32_t floatBits(float value) noexcept;
  static float bitsFloat(std::uint32_t value) noexcept;
  [[nodiscard]] static bool hostEndpoint(
      NativeAudioRenderInput input, std::uint32_t frameCount,
      std::uint64_t *endHostTicks) noexcept;
  void zero(std::span<float> output) noexcept;
  void applyGain(std::span<float> output, std::size_t frameCount) noexcept;
  void latchFailure(NativeAudioRenderFailure failure) noexcept;
  [[nodiscard]] bool timingRange(NativeAudioRenderInput input,
                                 std::uint64_t *firstHostTicks,
                                 std::uint64_t *endHostTicks) const noexcept;

  NativePcmRing &ring_;
  NativeMediaClock &clock_;
  const std::uint64_t host_ticks_per_second_;

  alignas(128) std::atomic<bool> accepting_{false};
  std::atomic<bool> paused_{true};
  std::atomic<std::uint64_t> control_generation_{0};
  std::atomic<std::uint64_t> terminal_generation_{0};
  std::atomic<std::uint64_t> terminal_frame_{0};
  std::atomic<bool> terminal_published_{false};
  std::atomic<std::uint64_t> terminal_observed_generation_{0};
  std::atomic<std::uint32_t> target_gain_bits_{0};
  std::atomic<bool> muted_{false};

  alignas(128) std::atomic_flag callback_gate_ = ATOMIC_FLAG_INIT;
  std::uint64_t activation_cursor_frame_{0};
  std::uint64_t cursor_frame_{0};
  std::uint64_t segment_serial_{0};
  // Frames already accounted for as elapsed media time but still queued in the
  // ring. They are retired without playback at the next opportunity: playing
  // them would put audio behind the clock that already passed them.
  std::uint64_t pending_late_frames_{0};
  std::uint64_t prior_end_host_ticks_{0};
  std::uint64_t prior_end_frame_{0};
  std::int64_t prior_end_sample_time_{0};
  std::uint32_t active_sample_rate_{0};
  media::MediaTime media_origin_{};
  float applied_gain_{0.0F};
  float ramp_target_{0.0F};
  std::uint32_t ramp_frames_remaining_{0};
  bool running_{false};
  bool next_discontinuous_{true};
  bool prior_sample_time_valid_{false};
  bool pause_fact_published_{false};
  std::atomic<bool> first_segment_committed_{false};
  NativeMediaClockSnapshot cached_paused_clock_{};

  alignas(128) std::atomic<std::uint8_t> failure_{0};
  std::atomic<std::uint64_t> callbacks_{0};
  std::atomic<std::uint64_t> rendered_frames_{0};
  std::atomic<std::uint64_t> silent_frames_{0};
  std::atomic<std::uint64_t> rejected_callbacks_{0};
  std::atomic<std::uint64_t> underrun_callbacks_{0};
  std::atomic<std::uint64_t> clock_advanced_underruns_{0};
  std::atomic<std::uint64_t> retired_late_frames_{0};
  std::atomic<std::uint64_t> metadata_corrections_{0};
  std::atomic<std::uint64_t> pause_boundaries_{0};
  std::atomic<std::uint64_t> eof_facts_{0};

  TestHook after_preflight_hook_{nullptr};
  void *after_preflight_context_{nullptr};
  bool fail_next_commit_{false};

  friend struct NativeAudioRenderCoreTestAccess;
};

} // namespace wam::macos
