#pragma once

#include "media/native_media_source.hpp"
#include "media/native_playback_contract.hpp"
#include "native_media_clock.hpp"
#include "native_pcm_ring.hpp"

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <span>

namespace wam::macos {

struct NativeAudioRenderCoreTestAccess;

using NativePlaybackRate = media::native_playback::PlaybackRateRatio;

// Seam the render callback uses to obtain time-stretched (pitch-preserved)
// audio at a non-unit rate. It is deliberately a pure function table so the
// core stays testable without CoreAudio and so nothing about AudioUnit
// lifetime leaks into the callback.
//
// CONTRACT, all of it enforced by the core:
//  * render() is called only from the render callback, only after setRate()
//    established the exact rational the core is accounting at, and only with
//    an output frame count the core has already proven is a multiple of the
//    rate denominator.
//  * render() must produce exactly outputFrames interleaved stereo frames and
//    obtain its input solely by calling the pull function registered through
//    configure(). It must not allocate, block, or log.
//  * The core's pull function is hard-budgeted: it serves at most the media
//    frames the core reserved clock time for, and zero-fills anything beyond.
//    A stage that over-pulls therefore corrupts only its own output, never
//    the ring cursor or the published clock.
//  * latencyOutputFrames() is the stage's group delay at the currently set
//    rate, in OUTPUT frames. The core shifts the segment's host endpoints
//    forward by exactly that much so the clock describes when audio is
//    HEARD rather than when it left the ring.
using NativeAudioStretchPull = std::uint32_t (*)(void *context,
                                                 float *interleaved,
                                                 std::uint32_t frames) noexcept;

struct NativeAudioStretchStage {
  void *context{nullptr};
  bool (*configure)(void *context, NativeAudioStretchPull pull,
                    void *pullContext) noexcept {nullptr};
  // Rate and pitch move together, in one call, because they are one decision:
  // the pitch offset a stage applies is a pure function of the rate and the
  // preserve-pitch preference, so no ordering between them can ever be
  // observed. preservePitch true is the historical behaviour (offset zero).
  bool (*setRate)(void *context, std::uint32_t numerator,
                  std::uint32_t denominator,
                  bool preservePitch) noexcept {nullptr};
  std::uint32_t (*latencyOutputFrames)(void *context) noexcept {nullptr};
  bool (*render)(void *context, std::uint32_t outputFrames,
                 float *interleavedOutput) noexcept {nullptr};
  void (*reset)(void *context) noexcept {nullptr};

  [[nodiscard]] constexpr bool usable() const noexcept {
    return context != nullptr && configure != nullptr && setRate != nullptr &&
           latencyOutputFrames != nullptr && render != nullptr &&
           reset != nullptr;
  }
};

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
  // Appended, never inserted: the numeric value of every enumerator above is
  // already carried in telemetry.
  StretchStageFailed,
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
  // The subset of advancedSilentFrames the CONTAINER declared: frames the
  // source states carry no audio media at all. Distinct from the rest of
  // advancedSilentFrames, which is a steady-state underrun the producer still
  // owes and whose wake edge is deliberately coalesced.
  std::uint32_t declaredSilenceFrames{0};
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

// Container-declared silence for one generation, in generation-local frames
// measured from the activation cursor. The container states that no audio
// media exists for these spans, so the renderer owes nothing for them: they
// are neither underruns nor faults, and the clock advances across them at the
// generation's rate exactly as it does across real audio.
struct NativeAudioDeclaredSilence {
  // Frames of declared silence at the HEAD, before any real PCM: an ISO-BMFF
  // leading empty edit. The first real PCM frame lands at cursor
  // streamFrameCursor + leadInFrames, whose media time is the audio
  // presentation floor exactly.
  std::uint64_t leadInFrames{0};
  // Cursor frame at which the container says its audio media ENDS, and the
  // cursor frame at which presentation must end. The span between them is
  // declared TRAILING silence -- a video tail past the end of the selected
  // audio. Both zero means the generation ends at its own audio end.
  //
  // pcmEndFrame exists to separate declared silence from a merely late
  // producer: an exhausted ring proves nothing on its own until the source
  // signals end-of-stream, and on a real file that signal arrives when reads
  // reach the end of the FILE, not the end of the audio track.
  std::uint64_t pcmEndFrame{0};
  std::uint64_t presentationEndFrame{0};
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
  // Container-DECLARED silence: device intervals rendered as zeros because the
  // source states there is no audio media for them (a leading empty edit, or a
  // video tail past the end of the selected audio). These are neither
  // underruns nor faults -- the producer owes nothing for these frames -- so
  // they are counted apart from both silentFrames and underrunCallbacks.
  std::uint64_t declaredSilenceCallbacks{0};
  std::uint64_t declaredSilenceFrames{0};
  std::uint64_t metadataCorrections{0};
  std::uint64_t pauseBoundaries{0};
  std::uint64_t endOfStreamFacts{0};
  // Callbacks that ran through the pitch-preserving stretch stage, and the
  // media frames the stage pulled short of (or over) the exact reservation.
  // A healthy non-unit rate keeps stretchShortfallFrames at zero.
  std::uint64_t stretchedCallbacks{0};
  std::uint64_t stretchShortfallFrames{0};
  std::uint64_t rateChanges{0};
  NativePlaybackRate rate{};
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

  // Volume boost. Unity is 1.0; the ceiling is VLC-style amplification, and
  // above unity the stage can and will clip -- that is the deal the user
  // makes by asking for more than the mix contains. The clipping is an exact
  // per-sample saturation to [-1, 1] applied in applyGain(), never a
  // renormalization, so the loudness of quiet material rises linearly and
  // only material that was already near full scale is affected. 4.0 is
  // +12 dB -- the practical top of the "this movie is mastered quiet" range
  // (mpv precedent); the UI's own maximum-volume setting decides how much of
  // this ceiling any window may actually reach.
  static constexpr float kMinimumGain = 0.0F;
  static constexpr float kMaximumGain = 4.0F;
  static constexpr float kSampleCeiling = 1.0F;

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
  // `declared` states CONTAINER-DECLARED silence for this generation. Those
  // frames are rendered as zeros, publish media time exactly like rendered
  // ones, and consume nothing from the ring. A default-constructed value --
  // what every source that declares no silence passes -- reduces every
  // expression that reads it to the prior arithmetic verbatim.
  [[nodiscard]] bool activate(
      std::uint64_t generation, std::uint64_t streamFrameCursor,
      media::MediaTime mediaOrigin, media::MediaTime pausedClockPosition,
      std::uint32_t sampleRate,
      NativeAudioDeclaredSilence declared = {}) noexcept;
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

  // Installs the pitch-preserving stretch stage. Called by the serialized
  // owner exactly once, and the stage must outlive the core. It is safe while
  // the render callback is running: the stage table is written first and then
  // published through a release store that the callback acquires, so a
  // callback either sees no stage at all or sees a fully written one. It must
  // be safe there, because the rate that first needs a stage arrives with the
  // run-state command, which is issued after callbacks are already admitted.
  // Without a stage the core admits only the unit rate.
  [[nodiscard]] bool attachStretchStage(
      NativeAudioStretchStage stage) noexcept;

  // Publishes a requested exact rational playback rate. Lock-free and safe
  // from the serialized owner thread while the render callback runs: the
  // callback latches it at a callback boundary, which is the only place the
  // stage's rate and the core's frame accounting can change together. The
  // unit rate is always admitted; anything else requires an attached stage.
  [[nodiscard]] bool setRate(NativePlaybackRate rate) noexcept;
  [[nodiscard]] NativePlaybackRate requestedRate() const noexcept;

  // Publishes the live "Preserve pitch at other speeds" preference. Latched at
  // the same callback boundary as the rate, and for the same reason: the stage
  // must never disagree with the rational the core is accounting at. It never
  // fails and never requires a stage -- with no stage, or at the unit rate,
  // there is nothing to apply, because the pitch offset of rate 1 is zero
  // cents. Rate 1.0 is therefore bit-identical whatever this is set to.
  void setPreservePitch(bool preserve) noexcept;
  [[nodiscard]] bool preservePitch() const noexcept;

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
  // Exact host-tick duration of `outputFrames` device frames on this
  // callback's immutable rational, used both for segment endpoints and for
  // the stretch stage's group-delay shift.
  [[nodiscard]] static bool hostTicksForOutputFrames(
      NativeAudioRenderInput input, std::uint64_t outputFrames,
      std::uint64_t *ticks) noexcept;
  // Serves one stretch-stage pull out of the ring under the hard media-frame
  // budget the callback reserved clock time for.
  static std::uint32_t stretchPull(void *context, float *interleaved,
                                   std::uint32_t frames) noexcept;
  // The continuity rule, stated once for every segment the callback publishes.
  // A segment abuts its predecessor only in ALL the domains the device
  // reports: the heard host-tick endpoint, the stream frame cursor, and the
  // device's own sample time whenever it supplies one. The sample-time arm is
  // not optional -- the live path selects Timing::SampleTime whenever CoreAudio
  // offers a sample time, and a device discontinuity there can leave the host
  // ticks arithmetically adjacent -- so a clock-advanced underrun interval and
  // a rendered interval can never disagree about the same boundary.
  [[nodiscard]] bool isContinuous(const NativeAudioRenderInput &input,
                                  std::uint64_t heardFirstHostTicks)
      const noexcept;
  // The refusal epilogue, stated once: name the failure on the result, latch it
  // stickily, mark the next interval discontinuous because this one published
  // no boundary, and count the rejected callback. Silencing the output stays
  // with the caller, which is the only party that knows how much of the buffer
  // it has already written.
  NativeAudioRenderResult &refuse(NativeAudioRenderResult &result,
                                  NativeAudioRenderFailure failure) noexcept;
  // One callback's coverage split in MEDIA order into declared-silence head,
  // real PCM, and declared-silence tail, all exact on the callback's immutable
  // rational. A pure function of the input, the rate, the ring occupancy and
  // the container's declared spans: it reads no member the callback mutates and
  // writes none.
  struct PrefixSplit {
    std::uint64_t outputFrames{0};
    std::uint64_t prefixFrames{0};
    std::uint64_t silencePrefixFrames{0};
    std::uint64_t pcmShareFrames{0};
    std::uint64_t silenceSuffixFrames{0};
    std::uint64_t declaredSilenceFrames{0};
  };
  [[nodiscard]] PrefixSplit computePrefixSplit(
      NativeAudioRenderInput input, NativePlaybackRate rate,
      std::uint64_t readableFrames, std::uint64_t fullOutputFrames,
      bool terminalCurrent, std::uint64_t terminalFrame) const noexcept;

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
  // Packed numerator<<32 | denominator. One 64-bit atomic keeps the pair
  // indivisible, so the callback can never latch half of a rate change.
  std::atomic<std::uint64_t> requested_rate_{
      (std::uint64_t{1} << 32U) | 1U};
  // Independent of the rate, so it needs no packing: a callback that latches
  // one without the other simply applies the pair it reads, and both are
  // idempotent. Default true is the behaviour every route already had.
  std::atomic<bool> requested_preserve_pitch_{true};
  // Release/acquire publication of stretch_. False means the callback must
  // not read that table at all, which is also what pins it to the unit rate.
  std::atomic<bool> stretch_installed_{false};

  alignas(128) std::atomic_flag callback_gate_ = ATOMIC_FLAG_INIT;
  std::uint64_t activation_cursor_frame_{0};
  std::uint64_t cursor_frame_{0};
  std::uint64_t segment_serial_{0};
  // Frames already accounted for as elapsed media time but still queued in the
  // ring. They are retired without playback at the next opportunity: playing
  // them would put audio behind the clock that already passed them.
  std::uint64_t pending_late_frames_{0};
  // Generation-local cursor frame at which real PCM begins. Equal to
  // activation_cursor_frame_ (no declared lead-in silence) for every source
  // that does not declare silence before its audio.
  std::uint64_t lead_in_end_frame_{0};
  // Cursor frames at which the container says real audio ends and presentation
  // ends. Both zero unless the source declares trailing silence.
  std::uint64_t declared_pcm_end_frame_{0};
  std::uint64_t declared_end_frame_{0};
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
  // Callback-local stretch state. active_rate_ is the rational every media
  // frame since the last rate boundary was accounted at; stretch_latency_
  // is the stage's group delay in output frames at that rate.
  NativeAudioStretchStage stretch_{};
  NativePlaybackRate active_rate_{};
  bool active_preserve_pitch_{true};
  std::uint32_t stretch_latency_output_frames_{0};
  // Hard pull budget for the current callback, and what the stage took.
  std::uint32_t pull_budget_frames_{0};
  std::uint32_t pull_taken_frames_{0};
  // Declared-silence media frames the stage must be served, in media order,
  // before (prefix) and after (suffix) the real PCM this callback covers. The
  // stage sees one continuous media stream across the boundary, so a rate
  // change inside declared silence stretches across it exactly as it does
  // across any other media, and the ring is never over-pulled.
  std::uint32_t pull_silence_prefix_{0};
  std::uint32_t pull_silence_suffix_{0};
  std::uint32_t pull_ring_taken_{0};
  bool pull_ring_failed_{false};
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
  std::atomic<std::uint64_t> declared_silence_callbacks_{0};
  std::atomic<std::uint64_t> declared_silence_frames_{0};
  std::atomic<std::uint64_t> metadata_corrections_{0};
  std::atomic<std::uint64_t> pause_boundaries_{0};
  std::atomic<std::uint64_t> eof_facts_{0};
  std::atomic<std::uint64_t> stretched_callbacks_{0};
  std::atomic<std::uint64_t> stretch_shortfall_frames_{0};
  std::atomic<std::uint64_t> rate_changes_{0};

  TestHook after_preflight_hook_{nullptr};
  void *after_preflight_context_{nullptr};
  bool fail_next_commit_{false};

  friend struct NativeAudioRenderCoreTestAccess;
};

} // namespace wam::macos
