#pragma once

#include "media/native_playback_contract.hpp"

#include <cstdint>
#include <limits>
#include <optional>

namespace wam::media::playback_router {

namespace native = wam::media::native_playback;

struct Tick {
  std::uint64_t value{0};

  friend constexpr bool operator==(Tick, Tick) = default;
};

enum class Route : std::uint8_t {
  NativeEligibleLocal,
  FallbackOnly,
};

struct OpenRequest {
  native::SourceKey sourceKey;
  Route route{Route::FallbackOnly};
  double initialPositionSeconds{0.0};
  bool paused{true};
};

struct PreviewFrameRequest {
  native::GestureId gesture;
  native::RequestId request;
  double targetSeconds{0.0};
};

struct CommitSeekRequest {
  native::GestureId gesture;
  native::RequestId request;
  double targetSeconds{0.0};
  // Exact output sequence sampled before physical CommitSeek issue. A ready
  // fact must contain a strictly newer draw in the target generation.
  std::uint64_t drawBaseline{0};
};

struct TimeoutPolicy {
  // Zero disables the corresponding timeout. Ticks have no implied unit.
  std::uint64_t prepareTicks{0};
  std::uint64_t startTicks{0};
  // NativeSeeking completes only when the session publishes CommitReady, which
  // depends entirely on facts arriving from the session worker exactly as
  // Prepare and Start do. Bounding it is what keeps a commit that never
  // produces its audio-clock and video-draw proofs from parking the route
  // forever with a frozen position and no published failure.
  std::uint64_t seekTicks{0};
  // NativeStopping completes only when the session publishes Stopped, and that
  // proof depends on the video output observing its terminal invalidation. On
  // the Qt path that observation is produced by the render thread, so a window
  // that has stopped compositing (occluded, offscreen, another Space) parks the
  // replacement transaction forever while still showing the retired frame.
  // Bounding it is what turns that silent park into a visible, recoverable
  // failure. Expiry is consumed only through
  // retireStoppingAfterSynchronousTeardown, never through advance(), because
  // releasing this state requires the caller to have destroyed the native graph
  // first.
  std::uint64_t stopTicks{0};
};

struct LineageSeed {
  // Seeds are high-water marks, not identities owned by this router.
  native::AttemptId attemptHighWater;
  native::GenerationHighWater generationHighWater;
};

struct LineageLimits {
  native::AttemptId maximumAttempt{std::numeric_limits<std::uint64_t>::max()};
  native::Serial maximumLiveSerial{native::kMaximumLiveValue};
  native::Generation maximumLiveGeneration{native::kMaximumLiveValue};
};

enum class State : std::uint8_t {
  Idle,
  NativePreparing,
  NativeStarting,
  NativeActive,
  NativeSeeking,
  // Natural EOS retains the native dispatcher, final frame, and generation.
  // Only exact Stop retirement releases that ownership.
  NativeEnded,
  NativeStopping,
  NativeStopFailed,
  FallbackCreating,
  FallbackOpening,
  FallbackActive,
  FallbackStopping,
};

enum class Status : std::uint8_t {
  Applied,
  Ignored,
  Invalid,
  Exhausted,
};

enum class ActionKind : std::uint8_t {
  None,
  NativePrepare,
  NativeStart,
  NativeSetRunState,
  NativePreviewFrame,
  NativeCommitSeek,
  NativeStop,
  CreateFallback,
  OpenFallback,
  SetFallbackRunState,
  StopFallback,
};

// Fallback commands use the same strong attempt/serial and source types as
// the native protocol. They are deliberately router-owned PODs: the core does
// not know whether the eventual fallback implementation is mpv or another
// backend.
struct FallbackCommand {
  native::Stamp stamp;
  native::SourceKey sourceKey;
  bool paused{true};
};

struct Action {
  ActionKind kind{ActionKind::None};
  native::Prepare prepare{};
  native::Start start{};
  native::SetRunState runState{};
  native::PreviewFrame previewFrame{};
  native::CommitSeek commitSeek{};
  native::Stop stop{};
  FallbackCommand fallback{};
};

struct Transition {
  Status status{Status::Ignored};
  std::optional<Action> action;
};

struct FallbackCreated {
  native::Stamp stamp;
};

struct FallbackOpened {
  native::Stamp stamp;
  native::SourceKey sourceKey;
};

struct FallbackStopped {
  native::Stamp stamp;
};

struct FallbackFailed {
  native::Stamp stamp;
};

struct Snapshot {
  State state{State::Idle};
  native::AttemptId attempt;
  native::Serial serial;
  native::SourceKey sourceKey;
  native::Generation generation;
  native::AttemptId attemptHighWater;
  native::GenerationHighWater generationHighWater;
  bool intendedPaused{true};
  bool hasPendingOpen{false};
  // Zero exactly when hasPendingOpen is false. This lets the controller retain
  // only the current and replacement source records without inferring pending
  // identity from actions or attempt lineage.
  native::SourceKey pendingSourceKey;
};

class PlaybackRouter final {
public:
  explicit constexpr PlaybackRouter(TimeoutPolicy timeouts = {},
                                    LineageSeed seed = {},
                                    LineageLimits limits = {}) noexcept
      : timeouts_(timeouts), attemptHighWater_(seed.attemptHighWater),
        generationHighWater_(seed.generationHighWater), limits_(limits) {}

  [[nodiscard]] Transition open(const OpenRequest &request, Tick now) noexcept;
  [[nodiscard]] Transition stop(Tick now) noexcept;
  [[nodiscard]] Transition cancel(Tick now) noexcept;
  // Emergency GUI-surface teardown only. The caller must first synchronously
  // destroy the one-shot native resource graph. This drops pending work and
  // returns the pure router to Idle without fabricating a Stopped proof;
  // lineage high-water marks remain burned.
  [[nodiscard]] Transition abandonNativeAfterSynchronousRetirement(
      Tick now) noexcept;
  // Bounded escape from NativeStopping when the exact Stopped proof can no
  // longer arrive. Applies only after the armed stop deadline expires, and the
  // caller must first synchronously destroy the one-shot native resource graph
  // exactly as abandonNativeAfterSynchronousRetirement requires. No Stopped
  // proof is fabricated: the stop invalidation generation is already burned, so
  // this only releases the retired lineage and routes the queued replacement,
  // which is what an occluded window would otherwise wait for forever.
  [[nodiscard]] Transition
  retireStoppingAfterSynchronousTeardown(Tick now) noexcept;
  [[nodiscard]] Transition setPaused(bool paused, Tick now) noexcept;
  // Retains the intended playback rate and, when a native
  // generation is already active, re-issues the run state carrying it. Rates
  // outside the advertised window are refused here rather than folded into a
  // command the native engine would then have to reject.
  [[nodiscard]] Transition setRate(double rate, Tick now) noexcept;
  // Retains the live "Preserve pitch at other speeds" preference and, when a
  // native generation is already active, re-issues the run state carrying it.
  // Always accepted: at the unit rate it applies nothing, and at every other
  // rate the audio stage serves both settings.
  [[nodiscard]] Transition setPreservePitch(bool preserve, Tick now) noexcept;
  [[nodiscard]] Transition previewFrame(const PreviewFrameRequest &request,
                                        Tick now) noexcept;
  [[nodiscard]] Transition commitSeek(const CommitSeekRequest &request,
                                      Tick now) noexcept;
  [[nodiscard]] Transition advance(Tick now) noexcept;

  [[nodiscard]] Transition onNativePrepared(const native::Prepared &event,
                                            Tick now) noexcept;
  [[nodiscard]] Transition
  onNativeUnsupported(const native::UnsupportedSource &event,
                      Tick now) noexcept;
  [[nodiscard]] Transition onNativeStarted(const native::Started &event,
                                           Tick now) noexcept;
  [[nodiscard]] Transition onNativeEnded(const native::Ended &event,
                                         Tick now) noexcept;
  [[nodiscard]] Transition onNativeCommitReady(const native::CommitReady &event,
                                               Tick now) noexcept;
  [[nodiscard]] Transition onNativeFailed(const native::Failed &event,
                                          Tick now) noexcept;
  [[nodiscard]] Transition onNativeStopped(const native::Stopped &event,
                                           Tick now) noexcept;

  [[nodiscard]] Transition onFallbackCreated(FallbackCreated event,
                                             Tick now) noexcept;
  [[nodiscard]] Transition onFallbackOpened(FallbackOpened event,
                                            Tick now) noexcept;
  [[nodiscard]] Transition onFallbackStopped(FallbackStopped event,
                                             Tick now) noexcept;
  [[nodiscard]] Transition onFallbackFailed(FallbackFailed event,
                                            Tick now) noexcept;

  [[nodiscard]] constexpr Snapshot snapshot() const noexcept {
    return {state_,
            attempt_,
            serial_,
            sourceKey_,
            generation_,
            attemptHighWater_,
            generationHighWater_,
            intendedPaused_,
            pending_.has_value(),
            pending_ ? pending_->request.sourceKey : native::SourceKey{}};
  }

private:
  struct PendingOpen {
    OpenRequest request;
    native::AttemptId attempt;
  };

  [[nodiscard]] bool acceptTick(Tick now) noexcept;
  [[nodiscard]] bool reserveAttempt(native::AttemptId &attempt) noexcept;
  [[nodiscard]] bool reserveLiveSerial(native::Serial &serial) noexcept;
  [[nodiscard]] bool reserveLiveGeneration(
      native::Generation &generation,
      native::GenerationHighWater &previousHighWater) noexcept;
  [[nodiscard]] bool
  reserveStopGeneration(native::Generation &generation) noexcept;
  [[nodiscard]] Tick deadline(Tick now, std::uint64_t duration) const noexcept;
  [[nodiscard]] bool deadlineExpired(Tick now) const noexcept;

  [[nodiscard]] Transition beginOpen(PendingOpen pending, Tick now) noexcept;
  [[nodiscard]] Transition beginFallback(PendingOpen pending) noexcept;
  [[nodiscard]] Transition beginNativeStop(bool fallbackCurrent,
                                           Tick now) noexcept;
  [[nodiscard]] Transition beginFallbackStop(Tick now) noexcept;
  [[nodiscard]] Transition routeAfterStop(Tick now) noexcept;
  [[nodiscard]] bool queueFallbackForCurrent() noexcept;
  void clearCurrent() noexcept;

  TimeoutPolicy timeouts_{};
  State state_{State::Idle};
  native::AttemptId attemptHighWater_{};
  native::GenerationHighWater generationHighWater_{};
  LineageLimits limits_{};
  native::AttemptId attempt_{};
  native::Serial serial_{};
  native::SourceKey sourceKey_{};
  native::Generation generation_{};
  native::Prepare prepare_{};
  // Emplaced once for a native Prepare and destroyed before another attempt.
  // The protocol state is deliberately noncopyable and nonmovable.
  std::optional<native::PrepareOutcomeState> prepareOutcome_;
  native::Start start_{};
  native::PreviewFrame latestPreview_{};
  native::CommitSeek commitSeek_{};
  std::uint64_t commitDrawBaseline_{0};
  native::Stop stop_{};
  std::optional<PendingOpen> pending_;
  // A fallback attempt can exhaust only after native resources already
  // require exact Stop. Retain that result until Stopped proves retirement.
  bool fallbackReservationExhausted_{false};
  double initialPositionSeconds_{0.0};
  bool intendedPaused_{true};
  // The rate every SetRunState this router emits carries. It is a session
  // intent, not per-generation state: it survives seeks and warm replacement
  // exactly the way the paused intent does, matching the compatibility
  // engine, which also keeps its speed across an open.
  double intendedRate_{native::kVersion1Rate};
  // Retained on exactly the same terms as intendedRate_, and carried by the
  // same command, because at the audio stage the two are one decision.
  bool intendedPreservePitch_{true};
  Tick lastTick_{};
  Tick deadline_{};
  bool deadlineArmed_{false};
};

} // namespace wam::media::playback_router
