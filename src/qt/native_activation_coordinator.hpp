#pragma once

#include <array>
#include <cstdint>
#include <optional>

namespace wam::native_activation {

enum class Phase : std::uint8_t {
  Idle,
  Preparing,
  AwaitRelease,
  Starting,
  Active,
  Seeking,
  EofHeld,
  FallbackStopping,
  FallbackAwaitRenderer,
  FallbackAwaitRestart,
  FallbackActive,
  Failed,
};

enum class FallbackReason : std::uint8_t {
  Unsupported,
  NativeFailure,
  ContextFailure,
  SeekFailure,
  Caption,
  TrackContract,
  PlaylistChange,
  Mismatch,
  MpvFailure,
};

enum class CancelMode : std::uint8_t {
  Stop,
  SupersededByMpvOpen,
};

struct Token {
  std::uint64_t request{0};
  std::uint64_t attempt{0};

  friend bool operator==(Token, Token) = default;
};

struct Transport {
  double position{0.0};
  double rate{1.0};
  bool paused{true};

  friend bool operator==(const Transport &, const Transport &) = default;
};

struct MpvReady {
  std::int64_t entry{-1};
  std::uint64_t sourceKey{0};
  std::int64_t videoId{-1};
  Transport live;
  bool singletonPlaylist{false};
  bool authoritativeAudio{false};
  bool subtitleFree{false};
  bool exactlyOneNonAlbumartVideo{false};
  bool belongsToRequestLineage{false};
};

struct NativeSample {
  bool active{false};
  bool stopping{false};
  bool failed{false};
  std::uint64_t generation{0};
  std::uint64_t acceptedGeneration{0};
  std::uint64_t lastRenderedGeneration{0};
  std::uint64_t acceptedRenderedFrames{0};
  std::uint64_t attemptAcceptedRenderedFrames{0};
};

struct SeekTicket {
  std::uint64_t epoch{0};
  std::uint64_t generation{0};
  std::uint64_t drawBaseline{0};
  double target{0.0};

  friend bool operator==(const SeekTicket &, const SeekTicket &) = default;
};

struct Action {
  enum class Kind : std::uint8_t {
    None,
    ForcePauseMpv,
    RevokeMpvRenderer,
    LoadMpvAudioOnly,
    PrepareNative,
    StartNative,
    SeekNative,
    SeekMpvExact,
    StopNative,
    AllowMpvRenderer,
    SelectMpvVideo,
    RestoreTransport,
    UpdateNativeClock,
    AttachCaption,
    SurfaceError,
  };

  Kind kind{Kind::None};
  Token token;
  std::uint64_t serial{0};
  std::uint64_t epoch{0};
  std::uint64_t value{0};
  std::int64_t videoId{-1};
  std::uint64_t captionId{0};
  Transport transport;

  friend bool operator==(const Action &, const Action &) = default;
};

struct ActionCompletion {
  bool succeeded{true};
  std::uint64_t generation{0};
  std::uint64_t drawBaseline{0};
  std::uint64_t invalidationGeneration{0};
  // RenderLifecycle generation sampled immediately before permission is
  // revoked. This is an arm identity, not a promise that an invalidation
  // callback will be emitted.
  std::uint64_t preRevokeGeneration{0};
  // Exact synchronous transport sampled after ForcePauseMpv. Required for
  // fallback pauses so Select/restart convergence anchors to the stopped
  // audio clock rather than a cadence-delayed time-pos observation.
  std::optional<Transport> liveTransport;
};

struct Snapshot {
  Phase phase{Phase::Idle};
  std::optional<Token> token;
  std::uint64_t sourceKey{0};
  std::optional<std::uint64_t> armedRevocationGeneration;
  std::array<std::uint64_t, 2> ignoredRetiredGenerations{};
  std::uint8_t ignoredRetiredGenerationCount{0};
  Transport desired;
  bool nativePrepared{false};
  bool mpvReady{false};
  bool nativeDrawReady{false};
  bool mpvSeekConverged{false};
  bool fallbackRenderReady{false};
  bool fallbackVideoSelected{false};
  bool fallbackPlaybackRestarted{false};
  bool nativeBurned{false};
  bool terminalAfterStop{false};
  bool cancelPending{false};
  bool nativeRequestIssued{false};
  bool rendererDenied{false};
  bool fallbackRendererInvalidationPending{false};
  bool eofRestorePending{false};
  std::uint64_t preparationGeneration{0};
  std::uint64_t nativeGeneration{0};
  std::uint64_t renderStamp{0};
  std::uint64_t transportEpoch{0};
  std::uint64_t drawBaseline{0};
  std::int64_t entry{-1};
  std::int64_t videoId{-1};
  std::optional<SeekTicket> seek;
  std::optional<std::uint64_t> pendingCaptionId;
  std::optional<Action> pendingAction;
  FallbackReason fallbackReason{FallbackReason::NativeFailure};
};

// Platform-neutral, capacity-one state machine for a future native video
// activation. It starts before any activation-side mutation and never calls
// Qt, mpv, or a platform pipeline. Every external mutation is represented by
// one pending Action which remains observable until its exact serial is
// completed.
class NativeActivationCoordinator final {
public:
  [[nodiscard]] std::optional<Token> begin(std::uint64_t request,
                                           std::uint64_t sourceKey,
                                           Transport desired) noexcept;

  [[nodiscard]] bool
  consumeExpectedRevocationGeneration(std::uint64_t retiredGeneration) noexcept;

  [[nodiscard]] Action nativePrepared(Token token,
                                      std::uint64_t generation) noexcept;
  [[nodiscard]] Action nativeUnsupported(Token token) noexcept;
  [[nodiscard]] Action nativeFailed(Token token) noexcept;
  [[nodiscard]] Action mpvLoadFailed(Token token) noexcept;
  [[nodiscard]] Action mpvEndFileError(Token token,
                                       std::int64_t entry) noexcept;
  [[nodiscard]] Action mpvReady(Token token, MpvReady ready) noexcept;
  [[nodiscard]] Action
  evaluateRelease(Token token, bool renderAllowed, bool renderBusy,
                  bool lifecycleEmpty,
                  std::uint64_t lifecycleGeneration) noexcept;
  [[nodiscard]] Action sampleNative(Token token, NativeSample sample) noexcept;

  [[nodiscard]] Action setDesiredPause(Token token, bool paused) noexcept;
  [[nodiscard]] Action setDesiredRate(Token token, double rate) noexcept;
  // The caller snapshots transportEpoch before requesting an authoritative
  // live value. A queued pre-seek observation cannot reanchor a newer epoch.
  [[nodiscard]] Action observeLiveTransport(Token token, std::uint64_t epoch,
                                            std::int64_t entry,
                                            Transport live) noexcept;
  [[nodiscard]] Action requestSeek(Token token, double target) noexcept;
  [[nodiscard]] Action playbackRestart(Token token, std::uint64_t epoch,
                                       std::int64_t entry,
                                       double livePosition) noexcept;

  [[nodiscard]] Action requestCaption(Token token,
                                      std::uint64_t captionId) noexcept;
  [[nodiscard]] Action eof(Token token, std::int64_t entry,
                           double finalPosition) noexcept;
  [[nodiscard]] Action beginFallback(Token token,
                                     FallbackReason reason) noexcept;
  [[nodiscard]] Action fallbackRenderReady(Token token,
                                           std::uint64_t renderStamp) noexcept;
  [[nodiscard]] Action
  fallbackRendererInvalidated(Token token, std::uint64_t retiredStamp) noexcept;
  [[nodiscard]] Action fallbackPlaybackRestart(Token token,
                                               std::uint64_t renderStamp,
                                               std::int64_t entry,
                                               double livePosition) noexcept;

  [[nodiscard]] std::optional<Action> nextAction() const noexcept;
  [[nodiscard]] Action completeAction(std::uint64_t serial,
                                      ActionCompletion completion) noexcept;

  [[nodiscard]] Action cancelForStopOrOpen(CancelMode mode) noexcept;
  [[nodiscard]] Snapshot snapshot() const noexcept;

private:
  enum class RestorePurpose : std::uint8_t {
    None,
    Startup,
    Seek,
    Eof,
    Fallback,
  };

  enum class ForcePausePurpose : std::uint8_t {
    None,
    Startup,
    Seek,
    Fallback,
    FallbackRendererLoss,
    Terminal,
  };

  [[nodiscard]] bool matches(Token token) const noexcept;
  [[nodiscard]] bool nativeOwnedPhase() const noexcept;
  [[nodiscard]] bool validTransport(const Transport &value) const noexcept;
  [[nodiscard]] bool validInitialMpv(const MpvReady &value) const noexcept;
  [[nodiscard]] bool validFallbackMpv(const MpvReady &value) const noexcept;
  [[nodiscard]] bool exactDraw(const NativeSample &sample,
                               std::uint64_t generation,
                               std::uint64_t baseline) const noexcept;
  [[nodiscard]] Action none() const noexcept;
  [[nodiscard]] Action publish(Action::Kind kind, std::uint64_t epoch = 0,
                               std::uint64_t value = 0,
                               std::int64_t videoId = -1,
                               std::uint64_t captionId = 0,
                               Transport transport = {}) noexcept;
  [[nodiscard]] Action surfaceError(FallbackReason reason) noexcept;
  [[nodiscard]] Action maybeConvergePreparation() noexcept;
  [[nodiscard]] Action maybeSelectFallbackVideo() noexcept;
  [[nodiscard]] Action maybeConvergeFallbackRestart() noexcept;
  [[nodiscard]] Action maybeConvergeSeek() noexcept;
  [[nodiscard]] Action failCurrentAction() noexcept;
  [[nodiscard]] Action beginTerminalStop(FallbackReason reason,
                                         bool forcePause) noexcept;
  [[nodiscard]] Action
  continueDeferredTransition(const Action &completed) noexcept;
  [[nodiscard]] Action publishClockUpdate() noexcept;
  [[nodiscard]] Action finishStop(const ActionCompletion &completion) noexcept;
  [[nodiscard]] Action finishAllow() noexcept;
  void armRevocationGeneration(std::uint64_t generation) noexcept;
  void retainIgnoredRetiredGeneration(std::uint64_t generation) noexcept;
  [[nodiscard]] std::uint64_t nextNonzero(std::uint64_t &value) noexcept;
  void resetAttemptState() noexcept;

  Phase phase_{Phase::Idle};
  std::optional<Token> token_;
  std::uint64_t next_attempt_{0};
  std::uint64_t next_action_serial_{0};
  std::uint64_t source_key_{0};
  std::optional<std::uint64_t> armed_revocation_generation_;
  std::array<std::uint64_t, 2> ignored_retired_generations_{};
  std::uint8_t ignored_retired_generation_count_{0};
  Transport desired_;
  bool native_prepared_{false};
  bool mpv_ready_{false};
  bool native_draw_ready_{false};
  bool mpv_seek_converged_{false};
  bool fallback_render_ready_{false};
  bool fallback_video_selected_{false};
  bool fallback_playback_restarted_{false};
  bool native_burned_{false};
  bool start_accepted_{false};
  bool mpv_seek_action_complete_{false};
  bool mpv_seek_action_issued_{false};
  bool terminal_after_stop_{false};
  bool terminal_pause_required_{false};
  bool cancel_pending_{false};
  bool native_request_issued_{false};
  bool renderer_denied_{false};
  bool fallback_transition_pending_{false};
  bool fallback_renderer_invalidation_pending_{false};
  bool eof_restore_pending_{false};
  std::optional<FallbackReason> deferred_surface_error_;
  bool caption_surface_error_{false};
  bool clock_update_dirty_{false};
  std::uint64_t preparation_generation_{0};
  std::uint64_t native_generation_{0};
  std::uint64_t render_stamp_{0};
  std::array<std::uint64_t, 2> retired_render_stamps_{};
  std::uint8_t retired_render_stamp_count_{0};
  std::uint64_t transport_epoch_{0};
  std::uint64_t draw_baseline_{0};
  std::int64_t entry_{-1};
  std::int64_t video_id_{-1};
  std::optional<MpvReady> initial_mpv_;
  std::optional<MpvReady> fallback_mpv_;
  std::optional<SeekTicket> seek_;
  std::optional<std::uint64_t> pending_caption_id_;
  std::optional<Action> pending_action_;
  RestorePurpose restore_purpose_{RestorePurpose::None};
  ForcePausePurpose force_pause_purpose_{ForcePausePurpose::None};
  CancelMode cancel_mode_{CancelMode::Stop};
  FallbackReason fallback_reason_{FallbackReason::NativeFailure};
};

} // namespace wam::native_activation
