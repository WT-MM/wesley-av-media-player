#pragma once

#include "media/native_media_dispatcher.hpp"
#include "native_audio_converter.hpp"
#include "native_audio_output.hpp"
#include "native_media_clock.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace wam::macos {

// All opaque pointers in hostClock, outputCalls, and outputWake are borrowed
// from externalLifetime. Keeping one mandatory shared lifetime token makes a
// quiescing session safe to recover even after its original UI owner is gone.
// The token must own outputWake.pending as well as every referenced context.
struct NativeAudioSessionDependencies {
  std::shared_ptr<void> externalLifetime;
  NativeMediaHostClock hostClock{};
  NativeAudioUnitCallTable outputCalls{};
  NativeAudioOutputWakeSeam outputWake{};
  std::unique_ptr<NativeAudioConverterBackend> converterBackend;
};

enum class NativeAudioSessionProgress : std::uint8_t {
  Done,
  WaitingForData,
  Quiescing,
  Invalid,
  Failed,
};

enum class NativeAudioSessionState : std::uint8_t {
  Fresh,
  Configuring,
  Ready,
  Started,
  Stopping,
  Flushing,
  Retiring,
  Cancelling,
  Cancelled,
  Closing,
  Unsupported,
  Failed,
  Closed,
};

enum class NativeAudioSessionFailure : std::uint8_t {
  None,
  InvalidDependency,
  OutputUnavailable,
  ConverterConfiguration,
  ClockActivation,
  OutputConfiguration,
  Converter,
  Output,
  Discontinuity,
  ConsumerProtocol,
  RingTransition,
  ClockTransition,
  OutputActivation,
  TerminalPublication,
};

struct NativeAudioSessionQuarantineFacts {
  std::uint64_t rejectedCreates{0};
  std::uint64_t transfers{0};
  std::uint64_t recoveries{0};
  bool claimed{false};
  bool quarantined{false};
};

// Side-effect-free owner-thread composition of exact logical payload ownership
// at the two audio leaves. generation is the session control generation;
// converterGeneration and ringGeneration preserve each raw leaf generation so
// a stopped/quiescing transition can be reported without inventing coherence.
// generationCoherent means the ring matches the session and every leaf which
// currently owns bytes matches it; an empty converter's retired tag is inert.
// Current values remain exact even when false. Each HWM is independently diagnostic
// since its leaf's latest generation/phase reset and must never be summed with
// another HWM or treated as a concurrent aggregate. Fixed converter arrays,
// ring capacity, AudioUnit/framework objects, and allocator overhead are not
// represented here.
struct NativeAudioSessionMemoryFacts {
  media::MediaGeneration generation{0};
  media::MediaGeneration converterGeneration{0};
  media::MediaGeneration ringGeneration{0};
  std::size_t converterRetainedPayloadBytes{0};
  std::size_t peakConverterRetainedPayloadBytes{0};
  std::size_t ringUnreadPcmBytes{0};
  std::size_t peakRingUnreadPcmBytes{0};
  bool generationCoherent{false};
};

struct NativeAudioSessionFacts {
  NativeAudioSessionState state{NativeAudioSessionState::Fresh};
  NativeAudioSessionFailure failure{NativeAudioSessionFailure::None};
  media::MediaGeneration generation{0};
  media::MediaTrackId track{0};
  std::uint32_t sampleRate{0};
  std::int64_t presentationFloorFrame{0};
  media::MediaGeneration ringGeneration{0};
  std::size_t queuedSlabs{0};
  bool resourceEntered{false};
  bool configured{false};
  bool requestedPaused{true};
  // Normalized owner requests and the exact pair most recently published to
  // the render core's lock-free callback controls. "Applied" means callback-
  // visible, not that the render core's bounded gain ramp has completed.
  float requestedGain{1.0F};
  float appliedGain{1.0F};
  bool requestedMuted{false};
  bool appliedMuted{false};
  std::uint64_t controlRevision{0};
  std::uint64_t appliedControlRevision{0};
  bool endOfStreamRequested{false};
  bool converterDrained{false};
  bool terminalPublished{false};
  bool terminalObserved{false};
  media::MediaGeneration clockGeneration{0};
  bool clockValid{false};
  media::MediaGeneration highestExposedGeneration{0};
  media::MediaGeneration retiredGeneration{0};
  media::MediaGeneration invalidationGeneration{0};
  bool retireDone{false};
  bool closeDone{false};
  // True once suspendOutputForPause() has proved a Done stop of the output
  // AudioUnit for a settled pause. The generation, stream cursor, ring and
  // clock are unchanged while it is set; only the device is idle.
  bool outputSuspended{false};
  NativeAudioSessionMemoryFacts memory{};
  NativeAudioConverterStats converter{};
  NativeAudioOutputFacts output{};
};

struct NativeAudioSessionControl;
#if defined(WAM_NATIVE_AUDIO_SESSION_TESTING)
struct NativeAudioSessionTestAccess;
#endif

// One serialized owner composes the bounded decoder/ring/render/output graph.
// It creates no thread, queue, or timer. Producer progress is driven by the
// dispatcher's bounded step() calls; consumer progress is driven by the
// injected capacity-one output wake. All methods are serialized owner-thread
// operations and must not overlap. A UI owner publishes its sampled
// visibleClock() result through its own thread-safe state boundary.
//
// Native capability rejection is possible only during the pure configure()
// preflight, before an AudioConverter or AudioUnit resource is entered. Once
// resourceEntered is true, every fault fails closed; Router-authorized
// retire() or emergency close() may then tear the epoch down. A destructor
// that cannot prove a Done close transfers the complete graph to one
// process-wide, discoverable quarantine slot.
class NativeAudioSession final : public media::NativeAudioConsumer {
 public:
  [[nodiscard]] static std::unique_ptr<NativeAudioSession> create(
      media::MediaGeneration initialGeneration,
      NativeAudioSessionDependencies dependencies) noexcept;
  ~NativeAudioSession() override;

  NativeAudioSession(const NativeAudioSession&) = delete;
  NativeAudioSession& operator=(const NativeAudioSession&) = delete;
  NativeAudioSession(NativeAudioSession&&) = delete;
  NativeAudioSession& operator=(NativeAudioSession&&) = delete;

  // Returns ownership of the sole quarantined graph, if present. The caller
  // repeatedly invokes close() after each injected wake until Done. Releasing
  // a still-quiescing recovered owner returns the same graph to quarantine.
  [[nodiscard]] static std::unique_ptr<NativeAudioSession>
  recoverQuarantined() noexcept;
  [[nodiscard]] static NativeAudioSessionQuarantineFacts
  quarantineFacts() noexcept;

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
  // Router-authorized terminal proof. The first valid pair is latched and
  // permanently supersedes Flush; only that exact pair can make progress or
  // observe Done. retiredGeneration is zero only when configure() was never
  // called, otherwise it is the highest configure/flush generation exposed
  // to the Router. Done proves an empty invalidation-tagged ring, an invalid
  // clock publication at the same generation when the clock was activated,
  // no converter lease, and a detached/quiescent output.
  [[nodiscard]] media::NativeMediaConsumerProgress retire(
      media::MediaGeneration retiredGeneration,
      media::MediaGeneration invalidationGeneration) noexcept override;
  // Emergency/quarantine teardown only; this never creates retirement proof.
  [[nodiscard]] media::NativeMediaConsumerProgress close() noexcept override;

  // start() opens output admission only after at least one exact PCM frame is
  // prebuffered, or after an empty generation has published its terminal. A
  // paused start may open immediately because it cannot consume the ring.
  [[nodiscard]] NativeAudioSessionProgress start() noexcept;
  [[nodiscard]] NativeAudioSessionProgress
  setPaused(bool paused) noexcept;
  // Owner-thread controls are accepted before configure and throughout a
  // live/reversible lifecycle. Gain uses the render core's fail-safe policy:
  // finite values are clamped to [0, 1], while non-finite values become zero.
  // Mute is independent and never overwrites the cached gain. Terminal
  // teardown states reject both calls without changing the cached request or
  // callback-visible control revision.
  [[nodiscard]] NativeAudioSessionProgress setGain(float gain) noexcept;
  [[nodiscard]] NativeAudioSessionProgress setMuted(bool muted) noexcept;
  // Stops the output AudioUnit for a pause that has already settled, so a
  // paused session pays no periodic real-time wake at all. Every render
  // callback is such a wake, and a paused callback does nothing but memset
  // zeroes: it never advances the stream cursor, never commits a segment,
  // never touches the ring and never touches the gain ramp. Stopping the
  // device therefore removes work, not state.
  //
  // Legal only from Started with requestedPaused true, no lifecycle in
  // flight, and an authoritative clock that is already paused at this
  // generation. That last precondition is what keeps the transition exactly
  // clock-neutral: the render callback's own pause boundary has already
  // published the paused position, so the clock.pause() inside the stop
  // settlement takes NativeMediaClock's already-paused early return and
  // cannot move it. Anything else returns Invalid and changes nothing.
  //
  // Done leaves the session in Ready with the output stopped and still
  // activated at the same generation and stream cursor, so setPaused(false)
  // — or an explicit start() — resumes on exactly the retained PCM. Quiescing
  // means a callback was still in flight; the output has already re-armed the
  // wake seam and the owner must retry. The suspend owns the output from its
  // first stop attempt until that Done proof: start(), setPaused() and stop()
  // all drive an in-flight suspend to completion before doing anything else,
  // because the AudioUnit is physically stopped and admission revoked from
  // the first attempt onward.
  [[nodiscard]] NativeAudioSessionProgress suspendOutputForPause() noexcept;
  [[nodiscard]] NativeAudioSessionProgress stop() noexcept;
  [[nodiscard]] NativeMediaClockSnapshot visibleClock() const noexcept;
  // Diagnostic-only view of the render callback's cumulative counters. Every
  // field is a plain relaxed atomic owned by the callback, so this read is
  // allocation-, lock- and wait-free and may race render() exactly like
  // visibleClock(). It exists so an owner can sample underrun/late-frame
  // facts without adding any work to the real-time callback itself.
  [[nodiscard]] NativeAudioRenderStats renderStats() const noexcept;
  [[nodiscard]] NativeAudioSessionFacts facts() const noexcept;
  // Exact Ready + stopped/quiescent owner-thread phase boundary. Success resets only
  // the two diagnostic leaf HWMs, seeding each from its current ownership.
  // It never changes live ownership or creates an aggregate memory fact.
  [[nodiscard]] bool resetMemoryHighWater(
      media::MediaGeneration expectedGeneration) noexcept;

 private:
  explicit NativeAudioSession(
      std::shared_ptr<NativeAudioSessionControl> control) noexcept;

  std::shared_ptr<NativeAudioSessionControl> control_;

#if defined(WAM_NATIVE_AUDIO_SESSION_TESTING)
  friend struct NativeAudioSessionTestAccess;
#endif
};

#if defined(WAM_NATIVE_AUDIO_SESSION_TESTING)
// Source-only deterministic lifecycle seam used by the focused injected test.
// Production code must not bypass flush() through this type.
struct NativeAudioSessionTestAccess {
  using CallbackHook = void (*)(void* context) noexcept;

  [[nodiscard]] static NativeAudioSubmitResult occupyConverter(
      NativeAudioSession& session, media::MediaSample&& sample) noexcept;
  static void setAfterRenderPreflightHook(
      NativeAudioSession& session, CallbackHook hook,
      void* context) noexcept;
  static void stageFlushAfterStop(
      NativeAudioSession& session,
      media::MediaGeneration retiredGeneration,
      media::MediaGeneration nextGeneration,
      media::NativeMediaGenerationTimeline timeline,
      NativeAudioGenerationTimeline converterTimeline,
      media::MediaTime mediaOrigin,
      std::int64_t floorFrame) noexcept;
  static void forceCloseQuiescing(
      NativeAudioSession& session, bool enabled) noexcept;
};
#endif

} // namespace wam::macos
