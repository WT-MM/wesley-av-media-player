#define WAM_MPV_RUNTIME_TESTING 1

#include "fakes/mpv_runtime/injected_mpv_runtime.hpp"
#include "qt/player_controller.hpp"
#include "qt/player_core_p.hpp"

#include <QCoreApplication>
#include <QEventLoop>
#include <QTimer>
#include <QUrl>

#include <mpv/client.h>

#include <chrono>
#include <clocale>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <memory>
#include <string_view>
#include <thread>

namespace wam::qt {

// PlayerController grants this test-only accessor friendship. Keeping the
// seam here avoids exposing the private PlayerCore lifetime boundary to QML or
// to shipping code.
class PlayerControllerTestAccess final {
 public:
  static std::shared_ptr<const ::wam::playback::mpv::MpvRuntime> runtime() {
    static const auto injected =
        ::wam::playback::mpv::makeInjectedLinkedMpvRuntime();
    return injected;
  }

  static bool provisionRuntime(PlayerController &controller) {
    return controller.engineReady() || controller.fallback_runtime_ ||
           controller.provisionMpvFallbackRuntime(runtime());
  }

  static std::shared_ptr<PlayerCore> core(const PlayerController &controller) {
    return controller.core_;
  }

  static bool hasReadyApi(const PlayerController &controller) {
    return controller.core_ && controller.core_->readyApi() != nullptr;
  }

  static void drainMpvEvents(PlayerController &controller) {
    controller.drainMpvEvents();
  }

  static RenderTicket makeRendererReady(PlayerController &controller) {
    const auto creating = controller.core_->render_lifecycle_.beginCreation();
    if (!creating)
      return {};
    const auto ready =
        controller.core_->render_lifecycle_.completeCreation(*creating, true);
    return ready.value_or(RenderTicket{});
  }

  static RenderTicket makeRendererFailed(PlayerController &controller) {
    const auto creating = controller.core_->render_lifecycle_.beginCreation();
    if (!creating)
      return {};
    const auto failed =
        controller.core_->render_lifecycle_.completeCreation(*creating, false);
    return failed.value_or(RenderTicket{});
  }

  static RenderTicket invalidateRenderer(PlayerController &controller) {
    return controller.core_->render_lifecycle_.invalidate().value_or(
        RenderTicket{});
  }

  static bool retryRenderer(PlayerController &controller) {
    return controller.core_->render_lifecycle_.retryFailure();
  }

  static void seedOpenAttempt(PlayerController &controller, const QUrl &source,
                              std::uint64_t serial,
                              std::uint64_t attempt_id,
                              RenderTicket ticket) {
    controller.request_serial_ = serial;
    controller.requested_source_ = source;
    controller.pending_source_ = source;
    controller.pending_request_serial_ = serial;
    controller.open_attempt_ =
        PlayerController::OpenAttempt{attempt_id, serial, ticket.stamp, -1};
  }

  static void completeOpenAttempt(PlayerController &controller,
                                  std::uint64_t attempt_id, int error = 0) {
    controller.handleOpenCommandReply((1ULL << 63) | attempt_id, error);
  }

  static void renderInvalidated(PlayerController &controller,
                                RenderTicket retired) {
    controller.handleRenderInvalidated(retired.stamp);
  }

  static void renderFailed(PlayerController &controller, const QString &error,
                           RenderTicket failed) {
    controller.handleRenderInitializationFailure(error, failed.stamp);
  }

  static bool hasPendingOpen(const PlayerController &controller) {
    return !controller.pending_source_.isEmpty() &&
           controller.pending_request_serial_ != 0;
  }

  static QUrl pendingSource(const PlayerController &controller) {
    return controller.pending_source_;
  }

  static std::uint64_t activeAttempt(const PlayerController &controller) {
    return controller.open_attempt_ ? controller.open_attempt_->id : 0;
  }

  static bool hasCommittedOpen(const PlayerController &controller) {
    return controller.committed_open_.has_value();
  }

  static bool hasRenderRecovery(const PlayerController &controller) {
    return controller.render_recovery_.has_value();
  }

  static bool hasStartupPlaybackSync(const PlayerController &controller) {
    return controller.startup_playback_sync_.has_value();
  }

  static bool startupPlaybackSyncQueued(
      const PlayerController &controller) {
    return controller.startup_playback_sync_ &&
           controller.startup_playback_sync_->completion_token != 0;
  }

  static bool startupPlaybackIntendsPause(
      const PlayerController &controller) {
    return controller.startup_playback_sync_ &&
           controller.startup_playback_sync_->intended_paused;
  }

  static bool startupPositionOverridden(
      const PlayerController &controller) {
    return controller.startup_playback_sync_ &&
           controller.startup_playback_sync_->position_overridden;
  }

  static double startupIntendedPosition(
      const PlayerController &controller) {
    return controller.startup_playback_sync_ &&
                   controller.startup_playback_sync_->intended_position
               ? *controller.startup_playback_sync_->intended_position
               : -1.0;
  }

  static bool startupAcceptsLiveState(
      const PlayerController &controller, bool paused, bool idle,
      std::optional<bool> eof_reached) {
    if (!controller.startup_playback_sync_)
      return false;
    return PlayerController::livePlaybackStateMatchesStartupSync(
        *controller.startup_playback_sync_,
        PlayerController::LivePlaybackState{paused, idle, eof_reached,
                                            std::nullopt, std::nullopt});
  }

  static void reconcileStartupPlaybackState(
      PlayerController &controller, bool paused, bool idle,
      std::optional<bool> eof_reached, std::optional<double> position,
      std::optional<double> duration) {
    controller.reconcileStartupPlaybackSync(
        PlayerController::LivePlaybackState{paused, idle, eof_reached,
                                            position, duration});
  }

  static double recoveryPosition(const PlayerController &controller) {
    return controller.render_recovery_ ? controller.render_recovery_->position
                                       : -1.0;
  }

  static bool recoveryPaused(const PlayerController &controller) {
    return controller.render_recovery_ && controller.render_recovery_->paused;
  }

  static bool recoveryPlaybackRestarted(
      const PlayerController &controller) {
    return controller.render_recovery_ &&
           controller.render_recovery_->playback_restarted;
  }

  static bool recoveryCompletionQueued(
      const PlayerController &controller) {
    return controller.render_recovery_ &&
           controller.render_recovery_->completion_token != 0;
  }

  static bool recoveryTransportRestored(
      const PlayerController &controller) {
    return controller.render_recovery_ &&
           controller.render_recovery_->transport_restored;
  }

  static bool recoveryIsVideoReselect(const PlayerController &controller) {
    return controller.render_recovery_ &&
           controller.render_recovery_->mode ==
               PlayerController::RenderRecoveryMode::VideoReselect;
  }

  static bool recoveryIsFullReload(const PlayerController &controller) {
    return controller.render_recovery_ &&
           controller.render_recovery_->mode ==
               PlayerController::RenderRecoveryMode::FullReload;
  }

  static bool recoveryIsNoReselection(const PlayerController &controller) {
    return controller.render_recovery_ &&
           controller.render_recovery_->mode ==
               PlayerController::RenderRecoveryMode::NoReselection;
  }

  static std::size_t recoverySubtitleCount(
      const PlayerController &controller) {
    return controller.render_recovery_
               ? controller.render_recovery_->external_subtitles.size()
               : 0;
  }

  static std::int64_t recoveryAudioTrack(
      const PlayerController &controller) {
    return controller.render_recovery_
               ? controller.render_recovery_->audio_track_id
               : -1;
  }

  static std::int64_t recoveryVideoTrack(
      const PlayerController &controller) {
    return controller.render_recovery_
               ? controller.render_recovery_->video_track_id
               : -1;
  }

  static bool recoveryTrackSnapshotProven(
      const PlayerController &controller) {
    return controller.render_recovery_ &&
           controller.render_recovery_->track_snapshot_proven;
  }

  static std::int64_t recoverySubtitleTrack(
      const PlayerController &controller) {
    return controller.render_recovery_
               ? controller.render_recovery_->subtitle_track_id
               : -1;
  }

  static bool hasRecoveryAttempt(const PlayerController &controller) {
    return controller.render_recovery_attempt_.has_value();
  }

  static bool recoveryAttemptIsVideoReselect(
      const PlayerController &controller) {
    return controller.render_recovery_attempt_ &&
           controller.render_recovery_attempt_->mode ==
               PlayerController::RenderRecoveryMode::VideoReselect;
  }

  static bool recoveryAttemptIsFullReload(
      const PlayerController &controller) {
    return controller.render_recovery_attempt_ &&
           controller.render_recovery_attempt_->mode ==
               PlayerController::RenderRecoveryMode::FullReload;
  }

  static std::uint64_t recoveryAttemptId(
      const PlayerController &controller) {
    return controller.render_recovery_attempt_
               ? controller.render_recovery_attempt_->id
               : 0;
  }

  static void completeRecoveryAttempt(PlayerController &controller,
                                      std::uint64_t attempt_id,
                                      int error = 0) {
    controller.handleRenderRecoveryCommandReply((1ULL << 62) | attempt_id,
                                                error);
  }

  static bool flush(PlayerController &controller, RenderTicket ticket) {
    return controller.flushPendingOpen(ticket.stamp);
  }

  static bool initializeEngine(PlayerController &controller) {
    return provisionRuntime(controller) &&
           controller.initializePlaybackEngine();
  }

  static void seedCommittedMedia(PlayerController &controller,
                                 const QUrl &source,
                                 std::uint64_t serial,
                                 RenderTicket ticket,
                                 std::int64_t playlist_entry_id,
                                 std::int64_t video_track_id,
                                 std::int64_t audio_track_id,
                                 std::int64_t subtitle_track_id,
                                 bool has_audio_track) {
    controller.request_serial_ = serial;
    controller.requested_source_ = source;
    controller.source_ = source;
    controller.pending_source_.clear();
    controller.pending_request_serial_ = 0;
    controller.open_attempt_.reset();
    controller.committed_open_ = PlayerController::OpenAttempt{
        1, serial, ticket.stamp, playlist_entry_id};
    controller.committed_entry_source_ = source;
    controller.committed_playlist_position_ = 0;
    controller.active_event_playlist_entry_id_ = playlist_entry_id;
    controller.selected_video_track_id_ = video_track_id;
    controller.selected_audio_track_id_ = audio_track_id;
    controller.selected_subtitle_track_id_ = subtitle_track_id;
    controller.selected_tracks_playlist_entry_id_ = playlist_entry_id;
    controller.current_file_has_audio_track_ = has_audio_track;
  }

  static void seedAttachedSubtitle(PlayerController &controller,
                                   const std::filesystem::path &path) {
    controller.attached_subtitle_files_.push_back(path);
  }

  static std::size_t attachedSubtitleCount(
      const PlayerController &controller) {
    return controller.attached_subtitle_files_.size();
  }

  static void clearTrackSnapshot(PlayerController &controller) {
    controller.selected_tracks_playlist_entry_id_ = -1;
    controller.current_file_has_audio_track_.reset();
  }

  static void setCommittedEntrySource(PlayerController &controller,
                                      const QUrl &source) {
    controller.committed_entry_source_ = source;
  }

  static QUrl recoveryReloadSource(const PlayerController &controller) {
    return controller.render_recovery_
               ? controller.render_recovery_->reload_source
               : QUrl{};
  }

  static std::int64_t recoveryPlaylistPosition(
      const PlayerController &controller) {
    return controller.render_recovery_
               ? controller.render_recovery_->playlist_position
               : -1;
  }

  static bool recoveryPreservesPlaylistContext(
      const PlayerController &controller) {
    return controller.render_recovery_ &&
           controller.render_recovery_->preserve_playlist_context;
  }

  static void setCommittedPlaylistPosition(PlayerController &controller,
                                           std::int64_t position) {
    controller.committed_playlist_position_ = position;
  }

  static std::uint64_t seedFullReloadAttempt(
      PlayerController &controller, RenderTicket ticket,
      std::int64_t playlist_entry_id, bool restarted_playlist_entry) {
    if (!controller.render_recovery_)
      return 0;
    constexpr std::uint64_t attempt_id = 991;
    controller.render_recovery_attempt_ =
        PlayerController::RenderRecoveryAttempt{
            attempt_id,
            controller.request_serial_,
            ticket.stamp,
            playlist_entry_id,
            controller.render_recovery_->video_track_id,
            PlayerController::RenderRecoveryMode::FullReload,
            playlist_entry_id,
            restarted_playlist_entry};
    return attempt_id;
  }

  static void finishRecoveryForTest(PlayerController &controller,
                                    RenderTicket ticket) {
    if (controller.committed_open_)
      controller.committed_open_->render_stamp = ticket.stamp;
    controller.render_recovery_.reset();
    controller.render_recovery_attempt_.reset();
  }

  static std::int64_t authoritativePlaylistEntry(
      std::int64_t live_entry, std::int64_t captured_start_entry) {
    return PlayerController::authoritativePlaylistEntry(
        live_entry, captured_start_entry);
  }

  static void seedCommittedRecovery(PlayerController &controller,
                                    const QUrl &source,
                                    std::uint64_t serial,
                                    RenderTicket ticket,
                                    std::int64_t playlist_entry_id,
                                    double position, bool paused) {
    seedCommittedMedia(controller, source, serial, ticket, playlist_entry_id,
                       -1, 1, 0, true);
    PlayerController::RenderRecovery recovery;
    recovery.request_serial = serial;
    recovery.position = position;
    recovery.paused = paused;
    recovery.track_snapshot_proven = true;
    recovery.accepted_render_stamp = ticket.stamp;
    controller.render_recovery_ = std::move(recovery);
    controller.position_ = position;
    controller.updatePause(paused);
  }

  static void startFile(PlayerController &controller,
                        std::int64_t playlist_entry_id) {
    controller.handleStartFile(playlist_entry_id);
  }

  static void playbackReady(PlayerController &controller,
                            bool file_loaded = false) {
    controller.handlePlaybackReady(file_loaded);
  }

  static bool hasScrub(const PlayerController &controller) {
    return controller.scrub_seek_.has_value();
  }

  static std::uint64_t scrubCommand(const PlayerController &controller) {
    return controller.scrub_seek_ ? controller.scrub_seek_->command : 0;
  }

  static double scrubTarget(const PlayerController &controller) {
    return controller.scrub_seek_ ? controller.scrub_seek_->target : -1.0;
  }

  static std::optional<double>
  scrubPendingTarget(const PlayerController &controller) {
    return controller.scrub_seek_
               ? controller.scrub_seek_->pending_target
               : std::nullopt;
  }

  static bool scrubIntendsPause(const PlayerController &controller) {
    return controller.scrub_seek_ && controller.scrub_seek_->intended_paused;
  }

  static bool scrubFinal(const PlayerController &controller) {
    return controller.scrub_seek_ && controller.scrub_seek_->final;
  }

  static bool scrubCommandExact(const PlayerController &controller) {
    return controller.scrub_seek_ &&
           controller.scrub_seek_->command_exact;
  }

  static const char *scrubCommandMode(const PlayerController &controller) {
    return PlayerController::scrubSeekMode(scrubCommandExact(controller));
  }

  static QTimer *scrubTimeoutTimer(const PlayerController &controller) {
    return controller.scrub_timeout_timer_;
  }

  static bool scrubTimeoutActive(const PlayerController &controller) {
    return controller.scrub_timeout_timer_ &&
           controller.scrub_timeout_timer_->isActive();
  }

  static std::uint64_t scrubTimeoutCommand(
      const PlayerController &controller) {
    return controller.scrub_timeout_command_;
  }

  static bool scrubTimeoutOwnsActiveCommand(
      const PlayerController &controller) {
    return controller.scrub_seek_ && controller.scrub_timeout_timer_ &&
           controller.scrub_timeout_timer_->isActive() &&
           controller.scrub_timeout_gesture_ ==
               controller.scrub_seek_->gesture &&
           controller.scrub_timeout_request_serial_ ==
               controller.scrub_seek_->request_serial &&
           controller.scrub_timeout_command_ ==
               controller.scrub_seek_->command;
  }

  static bool scrubSeekStarted(const PlayerController &controller) {
    return controller.scrub_seek_ && controller.scrub_seek_->seek_started;
  }

  static bool scrubAbortPending(const PlayerController &controller) {
    return controller.scrub_seek_ && controller.scrub_seek_->abort_pending;
  }

  static void scrubCommandReply(PlayerController &controller,
                                std::uint64_t command, int error = 0) {
    controller.handleScrubCommandReply((1ULL << 63) | (1ULL << 61) |
                                           command,
                                       error);
  }

  static void scrubSeekStarted(PlayerController &controller) {
    if (controller.scrub_seek_)
      controller.scrub_seek_->seek_started = true;
  }

  static void scrubRestart(PlayerController &controller,
                           double authoritative_position) {
    if (!controller.scrub_seek_)
      return;
    controller.scrub_seek_->authoritative_position =
        authoritative_position;
    controller.scrub_seek_->playback_restarted = true;
    controller.maybeCompleteScrubSeek();
  }

  static void scrubPlaybackRestart(PlayerController &controller) {
    controller.handleScrubPlaybackRestart();
  }

  static void scrubObservedPosition(PlayerController &controller,
                                    double position) {
    controller.applyObservedPosition(position);
  }

  static void scrubTimeout(PlayerController &controller,
                           std::uint64_t command) {
    if (!controller.scrub_seek_)
      return;
    if (controller.scrub_timeout_gesture_ ==
            controller.scrub_seek_->gesture &&
        controller.scrub_timeout_request_serial_ ==
            controller.scrub_seek_->request_serial &&
        controller.scrub_timeout_command_ == command) {
      controller.cancelScrubTimeout();
    }
    controller.handleScrubTimeout(controller.scrub_seek_->gesture,
                                  controller.scrub_seek_->request_serial,
                                  command);
  }

  static void scrubFinish(PlayerController &controller,
                          bool restore_transport) {
    controller.finishScrubGesture(restore_transport);
  }

  static bool beginNativeScrub(PlayerController &controller) {
    return controller.beginNativeScrubIntent();
  }

  static bool previewNativeScrub(PlayerController &controller,
                                 double target) {
    auto intent = controller.makeNativePreviewIntent(target);
    if (!intent)
      return false;
    controller.dispatchNativePreviewIntent(
        *intent, nullptr,
        [](void *, const PlayerController::NativePreviewIntent &) noexcept {
          return PlayerController::NativePreviewSubmission::Accepted;
        });
    return true;
  }

  struct NativePreviewProbe {
    PlayerController::NativePreviewSubmission result{
        PlayerController::NativePreviewSubmission::Accepted};
    unsigned submissions{0};
    std::vector<std::uint64_t> requests;
    std::vector<double> targets;
    PlayerController *reenterController{nullptr};
    double reenterTarget{0.0};
    bool reentered{false};
    PlayerController *presentController{nullptr};
    bool presentDuringSubmit{false};
    double presentedActual{0.0};
    bool presentedDuringSubmitAccepted{false};
    PlayerController *failController{nullptr};
    bool failDuringSubmit{false};
    bool failedDuringSubmitAccepted{false};
    std::uint64_t *eventSequence{nullptr};
    std::vector<std::uint64_t> submittedAt;
  };

  struct NativePreviewDemandProbe {
    std::uint64_t eventSequence{0};
    std::vector<std::uint64_t> requests;
    std::vector<double> targets;
    std::vector<std::uint64_t> observedAt;
  };

  static void observeNativePreviewDemand(
      void *context,
      const PlayerController::NativePreviewIntent &request) noexcept {
    auto &capture = *static_cast<NativePreviewDemandProbe *>(context);
    capture.requests.push_back(request.request);
    capture.targets.push_back(request.target);
    capture.observedAt.push_back(++capture.eventSequence);
  }

  static PlayerController::NativePreviewSubmission submitNativePreviewProbe(
      void *context,
      const PlayerController::NativePreviewIntent &request) noexcept {
    auto &capture = *static_cast<NativePreviewProbe *>(context);
    ++capture.submissions;
    capture.requests.push_back(request.request);
    capture.targets.push_back(request.target);
    if (capture.eventSequence != nullptr)
      capture.submittedAt.push_back(++*capture.eventSequence);
    if (capture.reenterController != nullptr && !capture.reentered) {
      capture.reentered = true;
      static_cast<void>(submitNativePreview(*capture.reenterController,
                                            capture.reenterTarget, capture));
    }
    if (capture.presentDuringSubmit && capture.presentController != nullptr) {
      capture.presentDuringSubmit = false;
      capture.presentedDuringSubmitAccepted =
          capture.presentController->completeNativePreviewPresented(
              request.gesture, request.request, capture.presentedActual,
              &capture, &submitNativePreviewProbe);
    }
    if (capture.failDuringSubmit && capture.failController != nullptr) {
      capture.failDuringSubmit = false;
      capture.failedDuringSubmitAccepted =
          capture.failController->completeNativePreviewFailed(
              request.gesture, request.request, &capture,
              &submitNativePreviewProbe);
    }
    return capture.result;
  }

  static void installPublicNativePreviewSeam(
      PlayerController &controller, NativePreviewProbe &submissions,
      NativePreviewDemandProbe &demands) {
    controller.native_preview_test_submit_context_ = &submissions;
    controller.native_preview_test_submitter_ = &submitNativePreviewProbe;
    controller.native_preview_test_demand_context_ = &demands;
    controller.native_preview_test_demand_observer_ =
        &observeNativePreviewDemand;
    submissions.eventSequence = &demands.eventSequence;
  }

  static void clearPublicNativePreviewSeam(PlayerController &controller) {
    controller.native_preview_test_submit_context_ = nullptr;
    controller.native_preview_test_submitter_ = nullptr;
    controller.native_preview_test_demand_context_ = nullptr;
    controller.native_preview_test_demand_observer_ = nullptr;
  }

  static bool submitNativePreview(PlayerController &controller, double target,
                                  NativePreviewProbe &probe) {
    auto intent = controller.makeNativePreviewIntent(target);
    if (!intent)
      return false;
    controller.dispatchNativePreviewIntent(*intent, &probe,
                                           &submitNativePreviewProbe);
    return true;
  }

  static void rejectNativePreview(NativePreviewProbe &probe) {
    probe.result = PlayerController::NativePreviewSubmission::Rejected;
  }

  static void acceptNativePreview(NativePreviewProbe &probe) {
    probe.result = PlayerController::NativePreviewSubmission::Accepted;
  }

  static void replaceNativePreview(NativePreviewProbe &probe) {
    probe.result = PlayerController::NativePreviewSubmission::Replaced;
  }

  static void staleNativePreview(NativePreviewProbe &probe) {
    probe.result = PlayerController::NativePreviewSubmission::Stale;
  }

  static bool presentNativePreview(PlayerController &controller,
                                   std::uint64_t gesture,
                                   std::uint64_t request,
                                   double actual,
                                   NativePreviewProbe *probe = nullptr) {
    return controller.completeNativePreviewPresented(
        gesture, request, actual, probe,
        probe != nullptr ? &submitNativePreviewProbe : nullptr);
  }

  static bool failNativePreview(PlayerController &controller,
                                std::uint64_t gesture,
                                std::uint64_t request,
                                NativePreviewProbe *probe = nullptr) {
    return controller.completeNativePreviewFailed(
        gesture, request, probe,
        probe != nullptr ? &submitNativePreviewProbe : nullptr);
  }

  static void publishNativeMainPosition(PlayerController &controller,
                                        double position) {
    controller.publishNativeMainPosition(position);
  }

  static std::uint64_t nativePreviewRequest(
      const PlayerController &controller) {
    return controller.native_scrub_intent_
               ? controller.native_scrub_intent_->latest_preview_request
               : 0;
  }

  static std::uint64_t nativeDispatchedPreviewRequest(
      const PlayerController &controller) {
    return controller.native_scrub_intent_
               ? controller.native_scrub_intent_->dispatched_preview_request
               : 0;
  }

  static bool endNativeScrub(PlayerController &controller, double target) {
    auto intent = controller.finishNativeScrubIntent(target);
    if (!intent)
      return false;
    return controller.dispatchNativeSeekIntent(
               *intent, &controller,
               [](void *, const PlayerController::NativeSeekIntent &) noexcept {
                 return PlayerController::NativeSeekSubmission::Accepted;
               }) == PlayerController::NativeSeekDispatch::Consumed;
  }

  static bool stageNativeSeek(PlayerController &controller, double target) {
    auto intent = controller.makeNativeSeekIntent(target);
    if (!intent)
      return false;
    return controller.dispatchNativeSeekIntent(
               *intent, &controller,
               [](void *, const PlayerController::NativeSeekIntent &) noexcept {
                 return PlayerController::NativeSeekSubmission::Accepted;
               }) == PlayerController::NativeSeekDispatch::Consumed;
  }

  struct NativeSeekProbe {
    PlayerController::NativeSeekSubmission result{
        PlayerController::NativeSeekSubmission::Accepted};
    unsigned submissions{0};
    std::uint64_t gesture{0};
    std::uint64_t request{0};
    double target{0.0};
    bool intended_paused{true};
    bool complete_during_submit{false};
    bool fail_during_submit{false};
    PlayerController *controller{nullptr};
    bool nest_during_submit{false};
    double nested_target{0.0};
    NativeSeekProbe *nested_probe{nullptr};
  };

  static void rejectNativeSubmission(NativeSeekProbe &probe) {
    probe.result = PlayerController::NativeSeekSubmission::Rejected;
  }

  static void useCompatibilitySubmission(NativeSeekProbe &probe) {
    probe.result = PlayerController::NativeSeekSubmission::Compatibility;
  }

  static void completeNativeSubmissionSynchronously(
      NativeSeekProbe &probe, PlayerController &controller) {
    probe.controller = &controller;
    probe.complete_during_submit = true;
  }

  static void failNativeSubmissionSynchronously(
      NativeSeekProbe &probe, PlayerController &controller) {
    probe.controller = &controller;
    probe.fail_during_submit = true;
  }

  static void nestNativeSubmissionSynchronously(
      NativeSeekProbe &probe, PlayerController &controller,
      double target, NativeSeekProbe &nested_probe) {
    probe.controller = &controller;
    probe.nest_during_submit = true;
    probe.nested_target = target;
    probe.nested_probe = &nested_probe;
  }

  static bool submitNativeSeek(PlayerController &controller, double target,
                               NativeSeekProbe &probe) {
    auto intent = controller.makeNativeSeekIntent(target);
    if (!intent)
      return false;
    return controller.dispatchNativeSeekIntent(
               *intent, &probe,
               [](void *context,
                  const PlayerController::NativeSeekIntent &request) noexcept {
                 auto &capture =
                     *static_cast<NativeSeekProbe *>(context);
                 ++capture.submissions;
                 capture.gesture = request.gesture;
                 capture.request = request.request;
                 capture.target = request.target;
                 capture.intended_paused = request.intended_paused;
                 if (capture.complete_during_submit && capture.controller) {
                   static_cast<void>(
                       capture.controller->acceptNativeCommitReady(
                           request.gesture, request.request, request.target));
                 }
                 if (capture.fail_during_submit && capture.controller) {
                   capture.controller->nativeCommitFailed(
                       request.gesture, request.request);
                 }
                 if (capture.nest_during_submit && capture.controller &&
                     capture.nested_probe) {
                   PlayerControllerTestAccess::submitNativeSeek(
                       *capture.controller, capture.nested_target,
                       *capture.nested_probe);
                 }
                 return capture.result;
               }) == PlayerController::NativeSeekDispatch::Consumed;
  }

  static bool routesNativeSeekToCompatibility(PlayerController &controller,
                                               double target,
                                               NativeSeekProbe &probe) {
    auto intent = controller.makeNativeSeekIntent(target);
    if (!intent)
      return false;
    return controller.dispatchNativeSeekIntent(
               *intent, &probe,
               [](void *context,
                  const PlayerController::NativeSeekIntent &request) noexcept {
                 auto &capture = *static_cast<NativeSeekProbe *>(context);
                 ++capture.submissions;
                 capture.gesture = request.gesture;
                 capture.request = request.request;
                 capture.target = request.target;
                 capture.intended_paused = request.intended_paused;
                 return capture.result;
               }) == PlayerController::NativeSeekDispatch::Compatibility;
  }

  static bool finishNativeScrub(PlayerController &controller, double target,
                                NativeSeekProbe &probe) {
    auto intent = controller.finishNativeScrubIntent(target);
    if (!intent)
      return false;
    return controller.dispatchNativeSeekIntent(
               *intent, &probe,
               [](void *context,
                  const PlayerController::NativeSeekIntent &request) noexcept {
                 auto &capture =
                     *static_cast<NativeSeekProbe *>(context);
                 ++capture.submissions;
                 capture.gesture = request.gesture;
                 capture.request = request.request;
                 capture.target = request.target;
                 capture.intended_paused = request.intended_paused;
                 if (capture.complete_during_submit && capture.controller) {
                   static_cast<void>(
                       capture.controller->acceptNativeCommitReady(
                           request.gesture, request.request, request.target));
                 }
                 if (capture.fail_during_submit && capture.controller) {
                   capture.controller->nativeCommitFailed(
                       request.gesture, request.request);
                 }
                 return capture.result;
               }) == PlayerController::NativeSeekDispatch::Consumed;
  }

  static bool completeNativeSeek(PlayerController &controller,
                                 std::uint64_t gesture,
                                 std::uint64_t request, double target) {
    return controller.acceptNativeCommitReady(gesture, request, target);
  }

  static void failNativeSeek(PlayerController &controller,
                             std::uint64_t gesture,
                             std::uint64_t request) {
    controller.nativeCommitFailed(gesture, request);
  }

  static bool hasNativeScrub(const PlayerController &controller) {
    return controller.native_scrub_intent_.has_value();
  }

  static bool hasNativeSeek(const PlayerController &controller) {
    return controller.native_seek_intent_.has_value();
  }

  static std::uint64_t nativeScrubGesture(
      const PlayerController &controller) {
    return controller.native_scrub_intent_
               ? controller.native_scrub_intent_->gesture
               : 0;
  }

  static std::uint64_t nativeSeekGesture(const PlayerController &controller) {
    return controller.native_seek_intent_
               ? controller.native_seek_intent_->gesture
               : 0;
  }

  static std::uint64_t nativeSeekRequest(const PlayerController &controller) {
    return controller.native_seek_intent_
               ? controller.native_seek_intent_->request
               : 0;
  }

  static double nativeScrubTarget(const PlayerController &controller) {
    return controller.native_scrub_intent_
               ? controller.native_scrub_intent_->target
               : -1.0;
  }

  static double nativeSeekTarget(const PlayerController &controller) {
    return controller.native_seek_intent_
               ? controller.native_seek_intent_->target
               : -1.0;
  }

  static bool nativeIntendsPause(const PlayerController &controller) {
    if (controller.native_scrub_intent_)
      return controller.native_scrub_intent_->intended_paused;
    return controller.native_seek_intent_ &&
           controller.native_seek_intent_->intended_paused;
  }

  static void setNativePauseIntent(PlayerController &controller, bool paused) {
    controller.setNativeScrubPauseIntent(paused);
  }

  static void invalidateNativeSeek(PlayerController &controller) {
    controller.invalidateNativeSeekIntents();
  }

  static void exhaustNativeGestureIds(PlayerController &controller) {
    controller.next_native_seek_gesture_id_ =
        std::numeric_limits<std::uint64_t>::max();
  }

  static void exhaustNativeRequestIds(PlayerController &controller) {
    controller.next_native_seek_request_id_ =
        std::numeric_limits<std::uint64_t>::max();
  }

  static void setCachedPlaybackState(PlayerController &controller,
                                     double position, bool paused) {
    controller.position_ = position;
    controller.updatePause(paused);
  }

  static void setDuration(PlayerController &controller, double duration) {
    controller.updateDuration(duration);
  }

  static void setCachedTransportState(PlayerController &controller,
                                      double position, bool paused,
                                      bool idle, bool eof_reached) {
    controller.position_ = position;
    controller.paused_ = paused;
    controller.idle_ = idle;
    controller.eof_reached_ = eof_reached;
  }

  static void queueRecoveryCompletion(PlayerController &controller) {
    if (!controller.render_recovery_)
      return;
    controller.render_recovery_->transport_restored = true;
    controller.queueRenderRecoveryCompletion();
  }

  static void finishQueuedRecoveryCompletion(PlayerController &controller) {
    if (!controller.render_recovery_ || !controller.committed_open_)
      return;
    controller.finishRenderRecoveryCompletion(
        controller.render_recovery_->completion_token,
        controller.render_recovery_->request_serial,
        controller.render_recovery_->accepted_render_stamp,
        controller.committed_open_->playlist_entry_id);
  }

  static void commitRecoveryState(PlayerController &controller,
                                  bool paused, bool idle,
                                  bool eof_reached,
                                  std::optional<double> position,
                                  std::optional<double> duration =
                                      std::nullopt) {
    if (!controller.render_recovery_)
      return;
    const PlayerController::RenderRecovery recovery =
        *controller.render_recovery_;
    controller.commitRenderRecovery(
        recovery, PlayerController::LivePlaybackState{
                      paused, idle, eof_reached, position, duration});
  }

  static void commitStartupPlaybackState(
      PlayerController &controller, bool paused, bool idle,
      std::optional<bool> eof_reached, std::optional<double> position,
      std::optional<double> duration) {
    controller.commitStartupPlaybackSync(
        PlayerController::LivePlaybackState{paused, idle, eof_reached,
                                            position, duration});
  }

  static bool livePlaybackPositionAvailable(
      const PlayerController &controller) {
    const auto state = controller.readLivePlaybackState();
    return state && state->position.has_value();
  }

  static bool livePlaybackEofAvailable(
      const PlayerController &controller) {
    const auto state = controller.readLivePlaybackState();
    return state && state->eof_reached.has_value();
  }

  static bool recoveryAcceptsLiveState(
      const PlayerController &controller, bool paused, bool idle,
      bool eof_reached) {
    if (!controller.render_recovery_)
      return false;
    return PlayerController::livePlaybackStateMatchesRecovery(
        *controller.render_recovery_,
        PlayerController::LivePlaybackState{paused, idle, eof_reached,
                                            std::nullopt, std::nullopt});
  }

  static void applyObservedPlaybackState(PlayerController &controller,
                                         double position, bool paused) {
    controller.applyObservedPosition(position);
    controller.applyObservedPause(paused);
  }

  static void applyObservedTimeline(PlayerController &controller,
                                    double position, double duration,
                                    bool paused, bool idle, bool eof) {
    controller.applyObservedPosition(position);
    controller.applyObservedDuration(duration);
    controller.applyObservedPause(paused);
    controller.applyObservedIdle(idle);
    controller.applyObservedEof(eof);
  }

  static bool idle(const PlayerController &controller) {
    return controller.idle_;
  }

  static bool eof(const PlayerController &controller) {
    return controller.eof_reached_;
  }

  static std::int64_t committedEntry(const PlayerController &controller) {
    return controller.committed_open_
               ? controller.committed_open_->playlist_entry_id
               : -1;
  }

  static std::uint64_t committedRenderStamp(
      const PlayerController &controller) {
    return controller.committed_open_
               ? controller.committed_open_->render_stamp
               : 0;
  }

  static void finishRecoveryWithLiveSnapshot(PlayerController &controller,
                                             std::int64_t video,
                                             std::int64_t audio,
                                             std::int64_t subtitle,
                                             bool has_audio_track) {
    if (!controller.render_recovery_ || !controller.committed_open_)
      return;
    controller.render_recovery_->video_track_id = video;
    controller.render_recovery_->audio_track_id = audio;
    controller.render_recovery_->subtitle_track_id = subtitle;
    controller.render_recovery_->file_has_audio_track = has_audio_track;
    controller.render_recovery_->track_snapshot_proven = true;
    controller.selected_video_track_id_ = video;
    controller.selected_audio_track_id_ = audio;
    controller.selected_subtitle_track_id_ = subtitle;
    controller.selected_tracks_playlist_entry_id_ =
        controller.committed_open_->playlist_entry_id;
    controller.current_file_has_audio_track_ = has_audio_track;
    if (const auto ready = controller.core_->readyRenderTicket())
      controller.render_recovery_->accepted_render_stamp = ready->stamp;
    controller.committed_open_->render_stamp =
        controller.render_recovery_->accepted_render_stamp;
    controller.render_recovery_.reset();
  }

  static void exhaustRecoveryRetry(PlayerController &controller,
                                   const QString &error) {
    if (!controller.render_recovery_)
      return;
    controller.render_recovery_->restore_retry_count = 3;
    controller.scheduleRenderRecoveryRetry(error);
  }

  static std::int64_t activeEntry(const PlayerController &controller) {
    return controller.active_event_playlist_entry_id_;
  }

  static void seedPendingReplacement(PlayerController &controller,
                                     const QUrl &source,
                                     std::uint64_t serial) {
    controller.request_serial_ = serial;
    controller.requested_source_ = source;
    controller.pending_source_ = source;
    controller.pending_request_serial_ = serial;
  }

  static void endFile(PlayerController &controller, int reason,
                      std::int64_t playlist_entry_id, int error = 0,
                      std::int64_t insert_id = -1,
                      int insert_count = 0) {
    mpv_event_end_file end{};
    end.reason = static_cast<mpv_end_file_reason>(reason);
    end.error = error;
    end.playlist_entry_id = playlist_entry_id;
    end.playlist_insert_id = insert_id;
    end.playlist_insert_num_entries = insert_count;
    controller.handleEndFile(end);
  }

};

}  // namespace wam::qt

namespace {

int failures = 0;

void expect(bool condition, const char *message) {
  if (condition)
    return;
  std::cerr << "FAIL: " << message << '\n';
  ++failures;
}

bool nearlyEqual(double left, double right, double epsilon = 0.0005) {
  return std::abs(left - right) <= epsilon;
}

template <typename Predicate>
bool processEventsUntil(
    Predicate predicate,
    std::chrono::milliseconds timeout = std::chrono::milliseconds(2000)) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (std::chrono::steady_clock::now() < deadline) {
    QCoreApplication::processEvents(QEventLoop::AllEvents);
    if (predicate())
      return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  QCoreApplication::processEvents(QEventLoop::AllEvents);
  return predicate();
}

double readDouble(mpv_handle *handle, const char *name) {
  double value = 0.0;
  const int result = mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value);
  expect(result >= 0, name);
  return value;
}

bool readFlag(mpv_handle *handle, const char *name) {
  int value = 0;
  const int result = mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value);
  expect(result >= 0, name);
  return value != 0;
}

}  // namespace

int main(int argc, char **argv) {
  QCoreApplication app(argc, argv);
  expect(std::setlocale(LC_NUMERIC, "C") != nullptr,
         "LC_NUMERIC can be restored for libmpv");

  {
    wam::qt::PlayerController controller;
    const auto core = wam::qt::PlayerControllerTestAccess::core(controller);

    expect(controller.available(), "a dormant controller remains available");
    expect(!controller.hasMedia(), "a blank controller has no media");
    expect(core != nullptr, "a blank controller owns its lifetime wrapper");
    expect(core && core->handle() == nullptr,
           "a blank controller has no libmpv handle");
    expect(core && !core->ready() && !core->failed(),
           "a blank controller remains dormant");

    controller.setVolume(0.37);
    controller.setRate(1.75);
    controller.setMuted(true);
    controller.setCaptionsVisible(false);
    controller.setPreservePitch(false);

    expect(nearlyEqual(controller.volume(), 0.37),
           "volume is cached while dormant");
    expect(nearlyEqual(controller.rate(), 1.75),
           "speed is cached while dormant");
    expect(controller.muted(), "mute is cached while dormant");
    expect(!controller.captionsVisible(),
           "caption visibility is cached while dormant");
    expect(!controller.preservePitch(),
           "pitch preservation is cached while dormant");

    controller.play();
    controller.pause();
    controller.seekTo(12.5);
    controller.stop();
    expect(!controller.open(QUrl{}), "an empty open request is rejected");

    expect(core->handle() == nullptr,
           "transport and invalid open commands do not initialize libmpv");
    expect(!core->ready() && !core->failed(),
           "transport commands leave the engine dormant");
    expect(nearlyEqual(controller.volume(), 0.37),
           "dormant transport preserves cached volume");
    expect(nearlyEqual(controller.rate(), 1.75),
           "dormant transport preserves cached speed");
    expect(controller.muted(), "dormant transport preserves cached mute");
    expect(!controller.captionsVisible(),
           "dormant transport preserves cached captions");
    expect(!controller.preservePitch(),
           "dormant transport preserves cached pitch correction");

    expect(wam::qt::PlayerControllerTestAccess::provisionRuntime(controller),
           "the fallback router can provision an injected runtime lazily");

    // This URL deliberately has no renderer and is never loaded: open() must
    // initialize libmpv, restore settings, then retain the request until the
    // render handshake. The test therefore performs no media or network I/O.
    expect(controller.open(QUrl(QStringLiteral("wam-test://lazy/player"))),
           "the first valid open initializes the playback engine");
    expect(controller.available(),
           "the initialized playback engine remains available");
    expect(core->ready(), "the playback engine becomes ready on first open");
    mpv_handle *handle = core->handle();
    expect(handle != nullptr, "first open creates a libmpv handle");

    if (handle) {
      // Exercise the controller's normal property-event path before checking
      // either side of the restored state.
      wam::qt::PlayerControllerTestAccess::drainMpvEvents(controller);
      expect(nearlyEqual(readDouble(handle, "volume"), 37.0),
             "cached volume is restored to libmpv");
      expect(nearlyEqual(readDouble(handle, "speed"), 1.75),
             "cached speed is restored to libmpv");
      expect(readFlag(handle, "mute"), "cached mute is restored to libmpv");
      expect(!readFlag(handle, "sub-visibility"),
             "cached caption visibility is restored to libmpv");
      expect(!readFlag(handle, "audio-pitch-correction"),
             "cached pitch correction is restored to libmpv");
    }

    expect(nearlyEqual(controller.volume(), 0.37),
           "initial property events preserve cached volume");
    expect(nearlyEqual(controller.rate(), 1.75),
           "initial property events preserve cached speed");
    expect(controller.muted(), "initial property events preserve cached mute");
    expect(!controller.captionsVisible(),
           "initial property events preserve cached captions");
    expect(!controller.preservePitch(),
           "initial property events preserve cached pitch correction");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    const QUrl source(QStringLiteral("wam-test://startup/autoplay"));
    wam::qt::PlayerController controller;
    expect(Access::initializeEngine(controller),
           "startup synchronization has a live libmpv client");
    const auto ready = Access::makeRendererReady(controller);
    Access::seedOpenAttempt(controller, source, 101, 701, ready);

    // Reproduce libmpv's real initial ordering: the only pause/idle/duration
    // observations can precede both authoritative START_FILE and open commit.
    Access::applyObservedTimeline(controller, 9.0, 180.0, false, false,
                                  false);
    Access::completeOpenAttempt(controller, 701);
    expect(Access::hasStartupPlaybackSync(controller) &&
               Access::committedEntry(controller) == -1,
           "COMMAND_REPLY installs startup gating before START_FILE identity");
    Access::applyObservedTimeline(controller, 10.0, 180.0, false, false,
                                  false);
    Access::startFile(controller, 501);
    expect(Access::hasStartupPlaybackSync(controller) &&
               Access::committedEntry(controller) == 501 &&
               controller.paused() && nearlyEqual(controller.duration(), 0.0),
           "START_FILE promotes the initially unknown synchronized entry");
    Access::applyObservedTimeline(controller, 11.0, 180.0, false, false,
                                  false);
    expect(controller.paused() && nearlyEqual(controller.duration(), 0.0),
           "startup observations remain gated until matching readiness");
    Access::playbackReady(controller, true);
    Access::playbackReady(controller, false);
    expect(Access::startupPlaybackSyncQueued(controller),
           "matching PLAYBACK_RESTART queues startup state completion");

    Access::commitStartupPlaybackState(controller, false, false, false, 18.0,
                                       180.0);
    expect(!Access::hasStartupPlaybackSync(controller) &&
               controller.playing() && !controller.paused() &&
               !Access::idle(controller) && !Access::eof(controller) &&
               nearlyEqual(controller.position(), 18.0) &&
               nearlyEqual(controller.duration(), 180.0) &&
               nearlyEqual(controller.trimOut(), 180.0),
           "startup completion publishes autoplay timeline and duration");

    wam::qt::PlayerController paused_controller;
    expect(Access::initializeEngine(paused_controller),
           "paused startup has a live libmpv client");
    mpv_handle *paused_handle = Access::core(paused_controller)->handle();
    int paused = 1;
    expect(paused_handle &&
               mpv_set_property(paused_handle, "pause", MPV_FORMAT_FLAG,
                                &paused) >= 0,
           "paused startup establishes an intentional engine pause");
    const auto paused_ready = Access::makeRendererReady(paused_controller);
    Access::seedOpenAttempt(paused_controller, source, 102, 702,
                            paused_ready);
    Access::startFile(paused_controller, 502);
    Access::completeOpenAttempt(paused_controller, 702);
    Access::playbackReady(paused_controller);
    Access::commitStartupPlaybackState(paused_controller, true, false, false,
                                       4.0, 60.0);
    expect(paused_controller.paused() &&
               !paused_controller.playing() &&
               !Access::idle(paused_controller) &&
               nearlyEqual(paused_controller.duration(), 60.0),
           "intentional paused startup remains paused after synchronization");

    wam::qt::PlayerController intent_controller;
    expect(Access::initializeEngine(intent_controller),
           "startup intent race has a live libmpv client");
    const auto intent_ready = Access::makeRendererReady(intent_controller);
    Access::seedOpenAttempt(intent_controller, source, 103, 703,
                            intent_ready);
    Access::startFile(intent_controller, 503);
    Access::completeOpenAttempt(intent_controller, 703);
    Access::playbackReady(intent_controller);
    intent_controller.pause();
    expect(Access::startupPlaybackSyncQueued(intent_controller) &&
               Access::startupPlaybackIntendsPause(intent_controller) &&
               !Access::startupAcceptsLiveState(intent_controller, false,
                                                false, false) &&
               Access::startupAcceptsLiveState(intent_controller, true,
                                               false, false) &&
               Access::startupAcceptsLiveState(intent_controller, false,
                                               false, true),
           "queued startup completion preserves newer Pause and terminal EOF");
    intent_controller.play();
    expect(!Access::startupPlaybackIntendsPause(intent_controller) &&
               !Access::startupAcceptsLiveState(intent_controller, true,
                                                false, false) &&
               Access::startupAcceptsLiveState(intent_controller, false,
                                               false, false),
           "queued startup completion also preserves newer Play intent");
    intent_controller.seekTo(42.0);
    expect(Access::startupPositionOverridden(intent_controller) &&
               nearlyEqual(Access::startupIntendedPosition(intent_controller),
                           42.0),
           "startup synchronization records a newer user seek target");
    Access::commitStartupPlaybackState(intent_controller, false, false, false,
                                       3.0, 120.0);
    expect(nearlyEqual(intent_controller.position(), 42.0) &&
               intent_controller.playing(),
           "startup completion cannot overwrite a queued user seek");

    wam::qt::PlayerController exhausted_controller;
    expect(Access::initializeEngine(exhausted_controller),
           "startup retry exhaustion has a live libmpv client");
    const auto exhausted_ready =
        Access::makeRendererReady(exhausted_controller);
    Access::seedOpenAttempt(exhausted_controller, source, 107, 707,
                            exhausted_ready);
    Access::startFile(exhausted_controller, 507);
    Access::completeOpenAttempt(exhausted_controller, 707);
    Access::playbackReady(exhausted_controller);
    exhausted_controller.pause();
    exhausted_controller.seekTo(48.0);
    Access::reconcileStartupPlaybackState(
        exhausted_controller, false, false, false, 7.0, 180.0);
    expect(!Access::hasStartupPlaybackSync(exhausted_controller) &&
               exhausted_controller.paused() &&
               !Access::idle(exhausted_controller) &&
               nearlyEqual(exhausted_controller.position(), 48.0) &&
               nearlyEqual(exhausted_controller.duration(), 180.0) &&
               nearlyEqual(exhausted_controller.trimOut(), 180.0) &&
               !exhausted_controller.playing(),
           "retry exhaustion keeps Pause/seek intent while publishing live "
           "idle and duration");

    wam::qt::PlayerController terminal_controller;
    expect(Access::initializeEngine(terminal_controller),
           "terminal startup has a live libmpv client");
    const auto terminal_ready = Access::makeRendererReady(terminal_controller);
    Access::seedOpenAttempt(terminal_controller, source, 104, 704,
                            terminal_ready);
    Access::startFile(terminal_controller, 504);
    Access::completeOpenAttempt(terminal_controller, 704);
    expect(Access::hasStartupPlaybackSync(terminal_controller),
           "terminal startup begins with a live synchronization gate");
    Access::endFile(terminal_controller, MPV_END_FILE_REASON_EOF, 504);
    expect(!Access::hasStartupPlaybackSync(terminal_controller) &&
               Access::eof(terminal_controller) &&
               !terminal_controller.playing(),
           "END_FILE before PLAYBACK_RESTART clears startup synchronization");

    wam::qt::PlayerController invalidation_controller;
    expect(Access::initializeEngine(invalidation_controller),
           "startup invalidation has a live libmpv client");
    mpv_handle *invalidation_handle =
        Access::core(invalidation_controller)->handle();
    paused = 0;
    expect(invalidation_handle &&
               mpv_set_property(invalidation_handle, "pause",
                                MPV_FORMAT_FLAG, &paused) >= 0,
           "startup invalidation establishes playing engine intent");
    const auto invalidation_ready =
        Access::makeRendererReady(invalidation_controller);
    Access::seedOpenAttempt(invalidation_controller, source, 105, 705,
                            invalidation_ready);
    Access::startFile(invalidation_controller, 505);
    Access::completeOpenAttempt(invalidation_controller, 705);
    invalidation_controller.seekTo(37.0);
    expect(invalidation_controller.paused() &&
               Access::hasStartupPlaybackSync(invalidation_controller),
           "startup cache remains gated before immediate invalidation");
    const auto retired = Access::invalidateRenderer(invalidation_controller);
    Access::renderInvalidated(invalidation_controller, retired);
    expect(!Access::hasStartupPlaybackSync(invalidation_controller) &&
               Access::hasRenderRecovery(invalidation_controller) &&
               !Access::recoveryPaused(invalidation_controller) &&
               nearlyEqual(Access::recoveryPosition(invalidation_controller),
                           37.0) &&
               Access::committedRenderStamp(invalidation_controller) == 0,
           "render recovery inherits startup play/seek intent and retires gate");

    wam::qt::PlayerController terminal_invalidation_controller;
    expect(Access::initializeEngine(terminal_invalidation_controller),
           "terminal startup invalidation has a live libmpv client");
    const auto terminal_invalidation_ready =
        Access::makeRendererReady(terminal_invalidation_controller);
    Access::seedOpenAttempt(terminal_invalidation_controller, source, 106, 706,
                            terminal_invalidation_ready);
    Access::startFile(terminal_invalidation_controller, 506);
    Access::completeOpenAttempt(terminal_invalidation_controller, 706);
    const auto terminal_retired =
        Access::invalidateRenderer(terminal_invalidation_controller);
    Access::renderInvalidated(terminal_invalidation_controller,
                              terminal_retired);
    expect(!Access::hasStartupPlaybackSync(terminal_invalidation_controller) &&
               Access::hasRenderRecovery(terminal_invalidation_controller) &&
               Access::recoveryPaused(terminal_invalidation_controller) &&
               Access::recoveryIsFullReload(
                   terminal_invalidation_controller),
           "terminal startup reloads only in the live paused state");
    const auto terminal_replacement =
        Access::makeRendererReady(terminal_invalidation_controller);
    const auto terminal_attempt = Access::seedFullReloadAttempt(
        terminal_invalidation_controller, terminal_replacement, 506, false);
    Access::completeRecoveryAttempt(terminal_invalidation_controller,
                                    terminal_attempt);
    expect(Access::hasRenderRecovery(terminal_invalidation_controller) &&
               Access::recoveryPaused(terminal_invalidation_controller) &&
               Access::committedRenderStamp(terminal_invalidation_controller) ==
                   terminal_replacement.stamp,
           "terminal full reload binds the replacement without autoplay");
    Access::commitRecoveryState(terminal_invalidation_controller, true, false,
                                true, 0.0, 12.0);
    expect(!Access::hasRenderRecovery(terminal_invalidation_controller) &&
               terminal_invalidation_controller.paused() &&
               Access::eof(terminal_invalidation_controller) &&
               nearlyEqual(terminal_invalidation_controller.duration(),
                           12.0) &&
               nearlyEqual(terminal_invalidation_controller.trimOut(), 12.0) &&
               !terminal_invalidation_controller.playing(),
           "terminal replacement completes on a paused, restartable frame");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    Access::setCachedTransportState(controller, 10.0, false, false, false);
    Access::setDuration(controller, 100.0);
    expect(Access::beginNativeScrub(controller),
           "preview-failure fixture owns one gesture");
    const std::uint64_t gesture = Access::nativeScrubGesture(controller);
    Access::NativePreviewProbe previews;
    expect(Access::submitNativePreview(controller, 20.0, previews),
           "preview-failure A dispatches");
    const std::uint64_t request_a = Access::nativePreviewRequest(controller);
    expect(Access::submitNativePreview(controller, 30.0, previews),
           "preview-failure B coalesces");
    const std::uint64_t request_b = Access::nativePreviewRequest(controller);
    expect(Access::submitNativePreview(controller, 40.0, previews),
           "preview-failure C replaces pending B");
    const std::uint64_t request_c = Access::nativePreviewRequest(controller);

    expect(!Access::failNativePreview(controller, gesture, request_b,
                                      &previews) &&
               previews.submissions == 1 &&
               Access::nativeDispatchedPreviewRequest(controller) == request_a &&
               nearlyEqual(controller.position(), 40.0),
           "failure for never-dispatched B is stale and cannot move the handle");
    expect(Access::failNativePreview(controller, gesture, request_a,
                                    &previews) &&
               previews.submissions == 2 &&
               previews.requests.back() == request_c &&
               Access::nativeDispatchedPreviewRequest(controller) == request_c &&
               nearlyEqual(controller.position(), 40.0),
           "exact A failure frees one slot and dispatches only latest C");
    expect(Access::failNativePreview(controller, gesture, request_c,
                                    &previews) &&
               previews.submissions == 2 &&
               Access::nativeDispatchedPreviewRequest(controller) == 0 &&
               nearlyEqual(controller.position(), 40.0),
           "latest C failure clears demand without retry or PTS regression");
    expect(Access::submitNativePreview(controller, 50.0, previews) &&
               previews.submissions == 3 &&
               Access::nativeDispatchedPreviewRequest(controller) ==
                   previews.requests.back() &&
               nearlyEqual(controller.position(), 50.0),
           "the next pointer move reuses the idle slot after latest failure");
    Access::invalidateNativeSeek(controller);
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    Access::setCachedTransportState(controller, 10.0, false, false, false);
    Access::setDuration(controller, 100.0);
    expect(Access::beginNativeScrub(controller),
           "failed-lane retry fixture owns one gesture");
    const std::uint64_t gesture = Access::nativeScrubGesture(controller);
    Access::NativePreviewProbe previews;
    expect(Access::submitNativePreview(controller, 20.0, previews),
           "failed-lane retry A dispatches");
    const std::uint64_t request_a = Access::nativePreviewRequest(controller);
    expect(Access::submitNativePreview(controller, 30.0, previews),
           "failed-lane retry B coalesces");
    Access::rejectNativePreview(previews);
    expect(Access::failNativePreview(controller, gesture, request_a,
                                    &previews) &&
               previews.submissions == 2 &&
               nearlyEqual(previews.targets.back(), 30.0) &&
               Access::nativeDispatchedPreviewRequest(controller) == 0 &&
               nearlyEqual(controller.position(), 30.0),
           "A failure attempts latest B once and synchronous refusal leaves "
           "the slot idle without moving the handle");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    const QUrl source(QStringLiteral("wam-test://tickets/current"));
    expect(Access::initializeEngine(controller),
           "A/V recovery has a live libmpv client");
    const auto ready = Access::makeRendererReady(controller);
    expect(ready.stamp != 0, "a synthetic renderer generation becomes Ready");
    Access::seedCommittedMedia(controller, source, 11, ready, 177, 1, 2, 3,
                               true);

    Access::setCachedPlaybackState(controller, 84.25, true);

    const auto retired = Access::invalidateRenderer(controller);
    expect(retired == ready, "renderer teardown retires the committed ticket");
    Access::applyObservedPlaybackState(controller, 0.0, false);
    expect(controller.paused(),
           "retired-renderer pause events cannot erase paused recovery");
    expect(nearlyEqual(controller.position(), 84.25),
           "retired-renderer position events cannot erase seek recovery");
    Access::renderInvalidated(controller, retired);
    expect(!Access::hasPendingOpen(controller),
           "ordinary A/V recovery never queues a replacement loadfile");
    expect(Access::hasCommittedOpen(controller) &&
               Access::committedEntry(controller) == 177,
           "ordinary A/V recovery retains the committed playlist entry");
    expect(Access::hasRenderRecovery(controller),
           "renderer recovery preserves playback state");
    expect(Access::recoveryIsVideoReselect(controller),
           "an active audio track selects the state-preserving vid path");

    const auto replacement = Access::makeRendererReady(controller);
    expect(Access::flush(controller, replacement),
           "the replacement generation accepts an asynchronous vid request");
    expect(Access::hasRecoveryAttempt(controller) &&
               Access::recoveryAttemptIsVideoReselect(controller),
           "A/V recovery queues only exact numeric video reselection");
    const auto recovery_attempt = Access::recoveryAttemptId(controller);
    Access::playbackReady(controller);
    expect(!Access::recoveryPlaybackRestarted(controller),
           "a restart predating the command reply is rejected as stale");
    Access::completeRecoveryAttempt(controller, recovery_attempt);
    expect(Access::hasRenderRecovery(controller),
           "a set-property reply alone cannot consume recovery");
    expect(Access::committedEntry(controller) == 177,
           "video reselection preserves subtitle and track-bearing entry");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    Access::setCachedTransportState(controller, 0.0, false, false, false);
    Access::setDuration(controller, 1000.0);
    expect(Access::beginNativeScrub(controller),
           "failure replacement stress owns one native gesture");
    const std::uint64_t gesture = Access::nativeScrubGesture(controller);
    Access::NativePreviewProbe previews;
    expect(Access::submitNativePreview(controller, 1.0, previews),
           "failure replacement stress dispatches A");
    const std::uint64_t first = Access::nativePreviewRequest(controller);
    for (unsigned index = 2; index <= 512; ++index) {
      expect(Access::submitNativePreview(controller, index, previews),
             "failure replacement stress retains latest movement");
    }
    const std::uint64_t latest = Access::nativePreviewRequest(controller);
    expect(previews.submissions == 1 &&
               Access::failNativePreview(controller, gesture, first,
                                         &previews) &&
               previews.submissions == 2 && previews.requests.back() == latest &&
               Access::nativeDispatchedPreviewRequest(controller) == latest &&
               nearlyEqual(controller.position(), 512.0),
           "A failure after 512 movements dispatches exactly the 512th desire");
    expect(Access::failNativePreview(controller, gesture, latest, &previews) &&
               previews.submissions == 2 &&
               Access::nativeDispatchedPreviewRequest(controller) == 0 &&
               nearlyEqual(controller.position(), 512.0),
           "latest failure ends stress demand without recursive retry");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    expect(Access::initializeEngine(controller),
           "recovery barrier can initialize libmpv without loading media");
    const auto ready = Access::makeRendererReady(controller);
    mpv_handle *handle = Access::core(controller)->handle();
    expect(handle != nullptr, "recovery barrier has a live libmpv handle");
    if (handle) {
      const QUrl source(QStringLiteral("wam-test://tickets/recovery-barrier"));
      int pause = 0;
      expect(mpv_set_property(handle, "pause", MPV_FORMAT_FLAG, &pause) >= 0,
             "idle libmpv accepts the recovery pause baseline");
      Access::seedCommittedRecovery(controller, source, 61, ready, 902, 0.0,
                                    true);

      Access::startFile(controller, 901);
      Access::playbackReady(controller);
      expect(Access::hasRenderRecovery(controller),
             "a stale FILE_LOADED cannot consume current recovery");
      expect(!readFlag(handle, "pause"),
             "a stale FILE_LOADED cannot alter current pause state");

      Access::startFile(controller, 902);
      Access::playbackReady(controller);
      expect(Access::hasRenderRecovery(controller) &&
                 Access::recoveryCompletionQueued(controller),
             "the matching FILE_LOADED queues a gated transport refresh");
      expect(readFlag(handle, "pause"),
             "the matching FILE_LOADED restores pause synchronously");
      expect(!Access::livePlaybackPositionAvailable(controller),
             "idle/nonseekable playback may legitimately omit time-pos");
      expect(!Access::livePlaybackEofAvailable(controller),
             "idle playback may legitimately omit eof-reached");
      Access::finishQueuedRecoveryCompletion(controller);
      expect(!Access::hasRenderRecovery(controller),
             "queued completion consumes recovery without time-pos");
      expect(controller.lastError().isEmpty(),
             "unavailable time-pos is not a recovery error");
      expect(controller.paused() && Access::idle(controller),
             "queued completion publishes live paused/idle state");
      expect(!Access::eof(controller),
             "unavailable live EOF preserves the cached non-EOF state");
      expect(nearlyEqual(controller.position(), 0.0),
             "queued completion preserves captured position without time-pos");

      pause = 0;
      expect(mpv_set_property(handle, "pause", MPV_FORMAT_FLAG, &pause) >= 0,
             "idle libmpv resets the failure-path pause baseline");
      Access::seedCommittedRecovery(controller, source, 62, ready, 903, 84.25,
                                    true);
      Access::startFile(controller, 903);
      expect(Access::hasRenderRecovery(controller),
             "recovery remains authoritative until matching readiness");
      expect(!readFlag(handle, "pause"),
             "pending readiness cannot alter pause state");

      controller.play();
      controller.seekTo(42.0);
      expect(!Access::recoveryPaused(controller),
             "play during recovery supersedes the captured pause state");
      expect(nearlyEqual(Access::recoveryPosition(controller), 42.0),
             "seek during recovery supersedes the captured position");
      controller.pause();
      expect(Access::recoveryPaused(controller),
             "pause during recovery becomes the state restored at readiness");
    }
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    const auto ready = Access::makeRendererReady(controller);
    const QUrl source(
        QStringLiteral("wam-test://tickets/coherent-recovery-commit"));
    Access::seedCommittedRecovery(controller, source, 63, ready, 904, 93.0,
                                  false);

    // Model the transient reload observations that previously survived the
    // recovery gate and left QML showing Play while libmpv was advancing.
    Access::setCachedTransportState(controller, 93.0, true, true, true);
    int paused_changes = 0;
    int playing_changes = 0;
    bool signal_state_was_coherent = true;
    QObject::connect(&controller, &wam::qt::PlayerController::pausedChanged,
                     &controller, [&] {
                       ++paused_changes;
                       signal_state_was_coherent =
                           signal_state_was_coherent &&
                           !Access::hasRenderRecovery(controller) &&
                           !controller.paused() && controller.playing() &&
                           nearlyEqual(controller.position(), 114.0);
                     });
    QObject::connect(&controller, &wam::qt::PlayerController::playingChanged,
                     &controller, [&] { ++playing_changes; });

    Access::queueRecoveryCompletion(controller);
    expect(Access::hasRenderRecovery(controller) &&
               Access::recoveryCompletionQueued(controller),
           "successful recovery keeps observations gated until its queued "
           "transport refresh");
    Access::applyObservedTimeline(controller, 1.0, 2.0, false, false, false);
    expect(controller.paused() && Access::idle(controller) &&
               Access::eof(controller) &&
               nearlyEqual(controller.position(), 93.0),
           "same-drain reload observations remain gated before completion");

    Access::commitRecoveryState(controller, false, false, false, 114.0);
    expect(!Access::hasRenderRecovery(controller) && controller.playing() &&
               !controller.paused() && !Access::idle(controller) &&
               !Access::eof(controller) &&
               nearlyEqual(controller.position(), 114.0),
           "unpaused recovery publishes the sampled live transport state");
    expect(paused_changes == 1 && playing_changes == 1 &&
               signal_state_was_coherent,
           "recovery completion emits one coherent playing transition");

    wam::qt::PlayerController paused_controller;
    const auto paused_ready = Access::makeRendererReady(paused_controller);
    Access::seedCommittedRecovery(paused_controller, source, 64, paused_ready,
                                  905, 84.0, true);
    Access::setCachedTransportState(paused_controller, 83.0, false, false,
                                    false);
    Access::queueRecoveryCompletion(paused_controller);
    Access::commitRecoveryState(paused_controller, true, false, false, 84.0);
    expect(!Access::hasRenderRecovery(paused_controller) &&
               paused_controller.paused() &&
               !paused_controller.playing() &&
               !Access::idle(paused_controller) &&
               !Access::eof(paused_controller) &&
               nearlyEqual(paused_controller.position(), 84.0),
           "paused recovery remains paused while refreshing idle/eof/position");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    const QUrl source(QStringLiteral("wam-test://tickets/completion-races"));

    wam::qt::PlayerController terminal_controller;
    const auto terminal_ready =
        Access::makeRendererReady(terminal_controller);
    Access::seedCommittedRecovery(terminal_controller, source, 66,
                                  terminal_ready, 906, 119.0, false);
    expect(!Access::recoveryAcceptsLiveState(terminal_controller, true, false,
                                             false) &&
               Access::recoveryAcceptsLiveState(terminal_controller, true,
                                                false, true) &&
               Access::recoveryAcceptsLiveState(terminal_controller, true,
                                                true, false),
           "only live EOF/idle may override an unpaused recovery intent");
    Access::queueRecoveryCompletion(terminal_controller);
    Access::endFile(terminal_controller, MPV_END_FILE_REASON_EOF, 906);
    Access::finishQueuedRecoveryCompletion(terminal_controller);
    QCoreApplication::processEvents(QEventLoop::AllEvents);
    QCoreApplication::processEvents(QEventLoop::AllEvents);
    expect(!Access::hasRenderRecovery(terminal_controller) &&
               Access::eof(terminal_controller) &&
               !terminal_controller.playing(),
           "natural EOF supersedes an already queued recovery completion");

    wam::qt::PlayerController mutation_controller;
    expect(Access::initializeEngine(mutation_controller),
           "transport-race recovery has a live libmpv client");
    const auto mutation_ready = Access::makeRendererReady(mutation_controller);
    Access::seedCommittedRecovery(mutation_controller, source, 67,
                                  mutation_ready, 907, 31.0, false);
    Access::queueRecoveryCompletion(mutation_controller);
    mutation_controller.pause();
    mutation_controller.play();
    mutation_controller.seekTo(42.0);
    mutation_controller.pause();
    expect(Access::recoveryCompletionQueued(mutation_controller) &&
               Access::recoveryPaused(mutation_controller) &&
               !Access::recoveryTransportRestored(mutation_controller) &&
               nearlyEqual(Access::recoveryPosition(mutation_controller),
                           42.0),
           "play/pause/seek after queueing supersede captured transport");
    const bool latest_transport_settled = processEventsUntil([&] {
      // libmpv property writes complete asynchronously, and recovery completion
      // itself advances through zero-delay Qt timers. Pump both boundaries
      // before asserting the final user intent; their relative latency differs
      // across libmpv backends and operating systems.
      Access::drainMpvEvents(mutation_controller);
      return !Access::hasRenderRecovery(mutation_controller) &&
             mutation_controller.paused() &&
             nearlyEqual(mutation_controller.position(), 42.0);
    });
    expect(latest_transport_settled,
           "queued user transport settles within the bounded event drain");
    expect(!Access::hasRenderRecovery(mutation_controller),
           "new user intent completes the queued recovery");
    expect(mutation_controller.paused(),
           "newest queued user pause remains authoritative");
    expect(nearlyEqual(mutation_controller.position(), 42.0),
           "newest queued user seek remains authoritative");
    expect(mutation_controller.lastError().isEmpty(),
           "queued user transport changes do not create a recovery error");

    wam::qt::PlayerController invalidation_controller;
    const auto invalidation_ready =
        Access::makeRendererReady(invalidation_controller);
    Access::seedCommittedRecovery(invalidation_controller, source, 68,
                                  invalidation_ready, 908, 51.0, false);
    Access::queueRecoveryCompletion(invalidation_controller);
    const auto retired = Access::invalidateRenderer(invalidation_controller);
    Access::renderInvalidated(invalidation_controller, retired);
    expect(Access::hasRenderRecovery(invalidation_controller) &&
               !Access::recoveryCompletionQueued(invalidation_controller) &&
               Access::committedRenderStamp(invalidation_controller) == 0,
           "a second invalidation retires an already queued completion token");
    Access::finishQueuedRecoveryCompletion(invalidation_controller);
    expect(Access::hasRenderRecovery(invalidation_controller) &&
               Access::committedRenderStamp(invalidation_controller) == 0,
           "the retired completion cannot ungate the next render generation");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    const auto ready = Access::makeRendererReady(controller);
    const QUrl source(QStringLiteral("wam-test://tickets/retry-exhaustion"));
    Access::seedCommittedRecovery(controller, source, 65, ready, 965, 0.0,
                                  true);
    Access::exhaustRecoveryRetry(
        controller, QStringLiteral("Unable to restore selected tracks."));
    expect(!Access::hasRenderRecovery(controller) &&
               !controller.lastError().isEmpty() &&
               !Access::hasReadyApi(controller) &&
               Access::core(controller)->handle() == nullptr,
           "bounded restore retry exhaustion degrades without resolving a "
           "dormant mpv table");
    Access::applyObservedTimeline(controller, 5.0, 25.0, false, false,
                                  false);
    expect(!controller.paused() && nearlyEqual(controller.position(), 5.0) &&
               nearlyEqual(controller.duration(), 25.0),
           "degraded recovery accepts live observations again");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    expect(Access::initializeEngine(controller),
           "video-only recovery has a live libmpv client");
    const auto ready = Access::makeRendererReady(controller);
    const QUrl source(QStringLiteral("wam-test://tickets/video-only"));
    const QUrl replacement_source(
        QStringLiteral("wam-test://tickets/replacement"));
    Access::seedCommittedMedia(controller, source, 71, ready, 177, 1, 0, 0,
                               false);
    Access::seedAttachedSubtitle(
        controller, std::filesystem::path("/tmp/wam-generated.srt"));

    const auto retired = Access::invalidateRenderer(controller);
    Access::endFile(controller, MPV_END_FILE_REASON_ERROR, 177,
                    MPV_ERROR_LOADING_FAILED);
    expect(controller.lastError().isEmpty(),
           "video-only VO error before invalidation is deferred");
    Access::renderInvalidated(controller, retired);
    expect(Access::recoveryIsFullReload(controller),
           "video-only media selects the guarded full-reload fallback");
    expect(Access::recoverySubtitleCount(controller) == 1,
           "video-only fallback snapshots WAM subtitle attachments");
    expect(Access::recoveryAudioTrack(controller) == 0 &&
               Access::recoverySubtitleTrack(controller) == 0,
           "full reload preserves explicit aid=no and sid=no selections");
    expect(!Access::hasPendingOpen(controller) &&
               Access::committedEntry(controller) == 177,
           "fallback intent retains the committed entry until accepted");

    const auto replacement = Access::makeRendererReady(controller);
    expect(Access::flush(controller, replacement),
           "video-only fallback queues against the replacement generation");
    expect(Access::hasRecoveryAttempt(controller) &&
               Access::recoveryAttemptIsFullReload(controller),
           "only confirmed video-only recovery queues loadfile");
    const std::uint64_t stale_attempt =
        Access::recoveryAttemptId(controller);
    Access::startFile(controller, 188);
    Access::endFile(controller, MPV_END_FILE_REASON_ERROR, 177,
                    MPV_ERROR_LOADING_FAILED);
    expect(controller.lastError().isEmpty() &&
               Access::activeEntry(controller) == 188,
           "a stale old-entry error cannot poison a started fallback");

    expect(controller.open(replacement_source),
           "a newer user open supersedes video-only recovery");
    expect(Access::attachedSubtitleCount(controller) == 1,
           "a pending replacement retains rollback subtitle state");
    Access::completeRecoveryAttempt(controller, stale_attempt);
    expect(Access::hasPendingOpen(controller) &&
               Access::pendingSource(controller) == replacement_source,
           "a stale fallback reply cannot clear a newer Open");
    controller.stop();
    Access::completeRecoveryAttempt(controller, stale_attempt);
    expect(!Access::hasPendingOpen(controller) &&
               !Access::hasRenderRecovery(controller) &&
               Access::attachedSubtitleCount(controller) == 0,
           "Stop clears fallback, subtitle snapshot and stale replies");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    expect(Access::initializeEngine(controller),
           "audio-only recovery has a live libmpv client");
    const auto ready = Access::makeRendererReady(controller);
    const QUrl source(QStringLiteral("wam-test://tickets/audio-only"));
    Access::seedCommittedMedia(controller, source, 72, ready, 272, 0, 2, 0,
                               true);
    Access::setCachedPlaybackState(controller, 10.0, false);
    const auto retired = Access::invalidateRenderer(controller);
    Access::renderInvalidated(controller, retired);
    expect(Access::recoveryIsNoReselection(controller),
           "audio-only media requires no video-track operation");
    const auto replacement = Access::makeRendererReady(controller);
    expect(Access::flush(controller, replacement),
           "audio-only recovery accepts a replacement renderer");
    expect(!Access::hasRecoveryAttempt(controller),
           "audio-only recovery queues neither vid nor loadfile");
    expect(Access::hasRenderRecovery(controller) &&
               Access::recoveryCompletionQueued(controller),
           "audio-only adoption keeps observations gated through completion");
    Access::commitRecoveryState(controller, false, false, false, 10.0);
    expect(!Access::hasRenderRecovery(controller) &&
               nearlyEqual(controller.position(), 10.0),
           "unpaused audio-only adoption never seeks to its old timestamp");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    const auto ready = Access::makeRendererReady(controller);
    const QUrl source(QStringLiteral("wam-test://tickets/pre-file-loaded"));
    Access::seedCommittedMedia(controller, source, 73, ready, 373, 1, 2, 0,
                               true);
    Access::clearTrackSnapshot(controller);
    const auto retired = Access::invalidateRenderer(controller);
    Access::renderInvalidated(controller, retired);
    expect(Access::recoveryIsFullReload(controller),
           "invalidation before FILE_LOADED uses the safe reload path");
    expect(!Access::recoveryTrackSnapshotProven(controller),
           "the pre-FILE_LOADED placeholder is explicitly unproven");

    const auto replacement = Access::makeRendererReady(controller);
    Access::finishRecoveryWithLiveSnapshot(controller, 1, 2, 0, true);
    const auto retired_again = Access::invalidateRenderer(controller);
    expect(retired_again == replacement,
           "the successfully recovered renderer can invalidate again");
    Access::renderInvalidated(controller, retired_again);
    expect(Access::recoveryIsVideoReselect(controller) &&
               Access::recoveryTrackSnapshotProven(controller),
           "a second invalidation uses the proven live A/V snapshot");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    expect(Access::authoritativePlaylistEntry(202, 101) == 202,
           "B's live playlist entry outranks a queued START_FILE from A");
    expect(Access::authoritativePlaylistEntry(-1, 202) == 202,
           "captured START_FILE remains the fallback before live position");
    expect(Access::authoritativePlaylistEntry(303, 202) == 303,
           "a retried FullReload reply rejects its stale-generation START");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    const auto ready = Access::makeRendererReady(controller);
    const QUrl playlist(QStringLiteral("wam-test://playlist/root"));
    const QUrl promoted_child(
        QStringLiteral("wam-test://playlist/promoted-child"));
    Access::seedCommittedMedia(controller, playlist, 75, ready, 10, 1, 0, 0,
                               false);
    Access::endFile(controller, MPV_END_FILE_REASON_REDIRECT, 10, 0, 100, 3);
    Access::startFile(controller, 101);
    Access::setCommittedEntrySource(controller, promoted_child);
    Access::setCommittedPlaylistPosition(controller, 1);
    Access::clearTrackSnapshot(controller);
    const auto retired = Access::invalidateRenderer(controller);
    Access::renderInvalidated(controller, retired);
    expect(Access::recoveryIsFullReload(controller) &&
               Access::recoveryReloadSource(controller) == promoted_child &&
               Access::recoveryReloadSource(controller) != playlist &&
               Access::recoveryPlaylistPosition(controller) == 1 &&
               Access::recoveryPreservesPlaylistContext(controller),
           "promoted-child FullReload retains the exact child playlist index");

    const auto replacement = Access::makeRendererReady(controller);
    const std::uint64_t recovery_attempt = Access::seedFullReloadAttempt(
        controller, replacement, 101, true);
    Access::completeRecoveryAttempt(controller, recovery_attempt);
    expect(Access::committedEntry(controller) == 101 &&
               Access::recoveryPlaylistPosition(controller) == 1,
           "playlist-play-index recovery resumes promoted child N");

    Access::finishRecoveryForTest(controller, replacement);
    Access::endFile(controller, MPV_END_FILE_REASON_EOF, 101);
    Access::startFile(controller, 102);
    expect(Access::committedEntry(controller) == 102 &&
               Access::activeEntry(controller) == 102 &&
               !Access::eof(controller),
           "promoted child N keeps its playlist continuation to sibling N+1");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    expect(Access::initializeEngine(controller),
           "EOF recovery lineage has a live libmpv client");
    const auto ready = Access::makeRendererReady(controller);
    const QUrl source(QStringLiteral("wam-test://tickets/eof-recovery"));
    Access::seedCommittedMedia(controller, source, 79, ready, 10, 1, 2, 0,
                               true);
    Access::setCachedPlaybackState(controller, 30.0, false);
    Access::endFile(controller, MPV_END_FILE_REASON_REDIRECT, 10, 0, 100, 2);
    Access::startFile(controller, 100);

    const auto retired = Access::invalidateRenderer(controller);
    Access::renderInvalidated(controller, retired);
    Access::endFile(controller, MPV_END_FILE_REASON_EOF, 100);
    expect(Access::hasRenderRecovery(controller) &&
               Access::recoveryIsNoReselection(controller) &&
               Access::recoveryVideoTrack(controller) == -1 &&
               Access::committedRenderStamp(controller) == 0,
           "EOF keeps only neutral generation adoption while renderer waits");

    Access::startFile(controller, 101);
    expect(Access::hasRenderRecovery(controller) &&
               Access::committedEntry(controller) == 101 &&
               !Access::recoveryTrackSnapshotProven(controller),
           "an accepted sibling starts with a fresh unproven snapshot");
    const auto replacement = Access::makeRendererReady(controller);
    expect(Access::flush(controller, replacement) &&
               Access::committedRenderStamp(controller) == replacement.stamp,
           "the sibling binds to the accepted replacement renderer");
    Access::applyObservedTimeline(controller, 9.0, 90.0, true, true, true);
    expect(!controller.paused() && nearlyEqual(controller.position(), 0.0) &&
               nearlyEqual(controller.duration(), 0.0) &&
               !Access::eof(controller),
           "sibling observations remain gated until its fresh snapshot");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    const auto ready = Access::makeRendererReady(controller);
    const QUrl source(QStringLiteral("wam-test://tickets/redirect"));
    Access::seedCommittedMedia(controller, source, 81, ready, 10, 1, 2, 0,
                               true);

    Access::endFile(controller, MPV_END_FILE_REASON_REDIRECT, 10, 0, 100, 3);
    Access::startFile(controller, 101);
    expect(Access::committedEntry(controller) == 101,
           "a child inside an inserted redirect range is promoted");
    Access::endFile(controller, MPV_END_FILE_REASON_REDIRECT, 101, 0, 200,
                    2);
    Access::startFile(controller, 201);
    expect(Access::committedEntry(controller) == 201,
           "a nested redirect child is promoted through retained lineage");

    Access::startFile(controller, 999);
    expect(Access::activeEntry(controller) == -1 &&
               Access::committedEntry(controller) == 201,
           "an unknown START_FILE cannot enter current lineage");
    Access::startFile(controller, 201);
    Access::endFile(controller, MPV_END_FILE_REASON_EOF, 201);
    expect(Access::eof(controller),
           "EOF from a promoted redirect child reaches current playback");

    Access::startFile(controller, 200);
    expect(!Access::eof(controller) &&
               Access::committedEntry(controller) == 200,
           "the next accepted redirect sibling clears prior-child EOF");
    Access::applyObservedTimeline(controller, 5.0, 50.0, false, false,
                                  false);
    Access::endFile(controller, MPV_END_FILE_REASON_ERROR, 200,
                    MPV_ERROR_LOADING_FAILED);
    expect(!controller.lastError().isEmpty() && controller.paused() &&
               Access::idle(controller) &&
               nearlyEqual(controller.position(), 0.0) &&
               nearlyEqual(controller.duration(), 0.0),
           "a child error synchronously publishes terminal playback state");

    wam::qt::PlayerController unknown_controller;
    const auto unknown_ready = Access::makeRendererReady(unknown_controller);
    Access::seedCommittedMedia(unknown_controller, source, 82, unknown_ready,
                               -1, 1, 2, 0, true);
    Access::startFile(unknown_controller, 500);
    expect(Access::activeEntry(unknown_controller) == -1 &&
               Access::committedEntry(unknown_controller) == -1,
           "an unknown committed ID is never treated as a wildcard");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    const auto ready = Access::makeRendererReady(controller);
    const QUrl source_a(QStringLiteral("wam-test://observations/a"));
    const QUrl source_b(QStringLiteral("wam-test://observations/b"));
    Access::seedCommittedMedia(controller, source_a, 91, ready, 901, 1, 2,
                               0, true);
    Access::applyObservedTimeline(controller, 10.0, 50.0, false, false,
                                  false);
    expect(!controller.paused() && nearlyEqual(controller.position(), 10.0) &&
               nearlyEqual(controller.duration(), 50.0) &&
               !Access::idle(controller) && !Access::eof(controller),
           "current-entry observations establish the playback baseline");

    Access::seedPendingReplacement(controller, source_b, 92);
    Access::applyObservedTimeline(controller, 1.0, 2.0, true, true, true);
    expect(!controller.paused() && nearlyEqual(controller.position(), 10.0) &&
               nearlyEqual(controller.duration(), 50.0) &&
               !Access::idle(controller) && !Access::eof(controller),
           "old-entry observations are suppressed while replacement waits");

    controller.stop();
    Access::applyObservedTimeline(controller, 9.0, 90.0, false, false, true);
    expect(controller.paused() && nearlyEqual(controller.position(), 0.0) &&
               nearlyEqual(controller.duration(), 0.0) &&
               Access::idle(controller) && !Access::eof(controller),
           "late pause/time/duration/idle/eof observations cannot undo Stop");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    const QUrl source(QStringLiteral("wam-test://tickets/before-reply"));
    const auto ready = Access::makeRendererReady(controller);
    Access::seedOpenAttempt(controller, source, 21, 2, ready);
    const auto retired = Access::invalidateRenderer(controller);
    Access::renderInvalidated(controller, retired);
    expect(Access::hasPendingOpen(controller),
           "invalidation before a reply preserves the pending request");
    expect(Access::activeAttempt(controller) == 0,
           "invalidation retires the old-generation active attempt");
    Access::completeOpenAttempt(controller, 2);
    expect(Access::hasPendingOpen(controller),
           "a stale old-generation reply cannot clear pending intent");
    expect(controller.source().isEmpty(),
           "a stale old-generation reply cannot publish ghost media");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    const QUrl source(QStringLiteral("wam-test://tickets/stop"));
    const auto ready = Access::makeRendererReady(controller);
    Access::seedOpenAttempt(controller, source, 31, 3, ready);
    Access::completeOpenAttempt(controller, 3);
    const auto retired = Access::invalidateRenderer(controller);
    controller.stop();
    Access::renderInvalidated(controller, retired);
    expect(!Access::hasPendingOpen(controller),
           "a queued invalidation cannot resurrect media after Stop");
    expect(!Access::hasRenderRecovery(controller),
           "Stop clears queued renderer recovery state");
    expect(controller.source().isEmpty(),
           "Stop keeps the visible source empty after stale callbacks");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    const auto ready = Access::makeRendererReady(controller);
    const QUrl source_a(QStringLiteral("wam-test://tickets/a"));
    const QUrl source_b(QStringLiteral("wam-test://tickets/b"));
    Access::seedOpenAttempt(controller, source_a, 41, 4, ready);
    Access::seedOpenAttempt(controller, source_b, 42, 5, ready);
    Access::completeOpenAttempt(controller, 4);
    expect(Access::hasPendingOpen(controller),
           "a stale A reply cannot clear the newer B request");
    expect(Access::pendingSource(controller) == source_b,
           "the newer B source remains authoritative");
    expect(Access::activeAttempt(controller) == 5,
           "the newer B attempt remains active after a stale A reply");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    const auto ready = Access::makeRendererReady(controller);
    const QUrl source(QStringLiteral("wam-test://tickets/error"));
    Access::seedOpenAttempt(controller, source, 45, 8, ready);
    Access::completeOpenAttempt(controller, 8, MPV_ERROR_LOADING_FAILED);
    expect(!Access::hasPendingOpen(controller),
           "a current command failure terminates that pending attempt");
    expect(controller.source().isEmpty() && !controller.hasMedia(),
           "a failed command cannot publish ghost media");
    expect(!Access::hasReadyApi(controller) &&
               Access::core(controller)->handle() == nullptr &&
               !controller.lastError().isEmpty(),
           "a synthetic dormant failure reports a stable fallback detail "
           "without resolving libmpv");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    const QUrl source(QStringLiteral("wam-test://tickets/failure"));
    int error_notifications = 0;
    QObject::connect(&controller, &wam::qt::PlayerController::lastErrorChanged,
                     [&error_notifications] { ++error_notifications; });
    const auto failed = Access::makeRendererFailed(controller);
    Access::seedOpenAttempt(controller, source, 51, 6, failed);
    Access::renderFailed(controller, QStringLiteral("renderer failed"),
                         failed);
    Access::renderFailed(controller, QStringLiteral("renderer failed"),
                         failed);
    expect(error_notifications == 1,
           "one failed renderer generation reports exactly one error");
    expect(Access::retryRenderer(controller),
           "an explicit retry advances a failed renderer generation");
    const auto failed_again = Access::makeRendererFailed(controller);
    Access::renderFailed(controller, QStringLiteral("renderer failed again"),
                         failed_again);
    expect(error_notifications == 2,
           "a new failed generation may report one new error");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    expect(Access::initializeEngine(controller),
           "scrubbing tests have a live libmpv client");
    const auto ready = Access::makeRendererReady(controller);
    const QUrl source(QStringLiteral("wam-test://scrub/capacity-one"));
    Access::seedCommittedMedia(controller, source, 101, ready, 1001, 1, 2,
                               0, true);
    Access::setCachedTransportState(controller, 10.0, false, false, false);
    int playing = 0;
    mpv_set_property(Access::core(controller)->handle(), "pause",
                     MPV_FORMAT_FLAG, &playing);

    controller.beginScrub();
    expect(Access::hasScrub(controller) && !controller.paused(),
           "beginScrub captures playing intent while physically pausing");
    QTimer *const scrub_timer = Access::scrubTimeoutTimer(controller);
    expect(scrub_timer && scrub_timer->isSingleShot() &&
               !Access::scrubTimeoutActive(controller),
           "one dormant single-shot timer is owned for the scrub gesture");
    Access::applyObservedPlaybackState(controller, 11.0, true);
    expect(!controller.paused() && nearlyEqual(controller.position(), 10.0),
           "physical pause and decoder position observations stay hidden");

    controller.previewSeekTo(20.0);
    const std::uint64_t first = Access::scrubCommand(controller);
    expect(std::string_view(Access::scrubCommandMode(controller)) ==
                   "absolute+keyframes" &&
               !Access::scrubCommandExact(controller),
           "pointer movement issues an approximate keyframe seek");
    expect(Access::scrubTimeoutTimer(controller) == scrub_timer &&
               Access::scrubTimeoutOwnsActiveCommand(controller) &&
               Access::scrubTimeoutCommand(controller) == first,
           "the reusable watchdog is armed to the full command identity");
    controller.previewSeekTo(30.0);
    controller.previewSeekTo(40.0);
    expect(first != 0 && Access::scrubCommand(controller) == first &&
               Access::scrubPendingTarget(controller) &&
               nearlyEqual(*Access::scrubPendingTarget(controller), 40.0),
           "preview traffic is capacity-one with one latest pending target");

    Access::scrubCommandReply(controller, first + 99);
    Access::scrubPlaybackRestart(controller);
    Access::scrubTimeout(controller, first + 99);
    expect(Access::scrubCommand(controller) == first &&
               Access::scrubTimeoutActive(controller) &&
               Access::scrubTimeoutCommand(controller) == first,
           "stale replies and restarts before SEEK cannot retire a flight");
    Access::scrubSeekStarted(controller);
    Access::scrubCommandReply(controller, first);
    expect(Access::scrubTimeoutActive(controller),
           "a successful command reply keeps the decoded-frame watchdog");
    Access::scrubRestart(controller, 7.0);
    const std::uint64_t second = Access::scrubCommand(controller);
    expect(second != 0 && second != first &&
               nearlyEqual(Access::scrubTarget(controller), 40.0) &&
               std::string_view(Access::scrubCommandMode(controller)) ==
                   "absolute+keyframes" &&
               Access::scrubTimeoutTimer(controller) == scrub_timer &&
               Access::scrubTimeoutOwnsActiveCommand(controller) &&
               Access::scrubTimeoutCommand(controller) == second,
           "an approximate restart at any finite position dispatches only "
           "the latest preview and rearms the same timer");

    controller.endScrub(55.0);
    expect(Access::scrubFinal(controller) &&
               Access::scrubPendingTarget(controller) &&
               nearlyEqual(*Access::scrubPendingTarget(controller), 55.0),
           "release during a preview retains its exact final target");
    Access::scrubSeekStarted(controller);
    Access::scrubRestart(controller, 40.0);
    expect(Access::scrubCommand(controller) == second,
           "restart before command reply waits without stacking work");
    Access::scrubCommandReply(controller, second);
    const std::uint64_t final = Access::scrubCommand(controller);
    expect(final != 0 && final != second &&
               nearlyEqual(Access::scrubTarget(controller), 55.0) &&
               Access::scrubCommandExact(controller) &&
               std::string_view(Access::scrubCommandMode(controller)) ==
                   "absolute+exact" &&
               Access::scrubTimeoutTimer(controller) == scrub_timer &&
               Access::scrubTimeoutOwnsActiveCommand(controller) &&
               Access::scrubTimeoutCommand(controller) == final,
           "release target becomes the one final exact command on the same "
           "watchdog");
    Access::scrubSeekStarted(controller);
    Access::scrubCommandReply(controller, final);
    Access::scrubRestart(controller, 54.0);
    expect(Access::hasScrub(controller) &&
               Access::scrubTimeoutOwnsActiveCommand(controller),
           "an early restart keeps its watchdog while exact convergence "
           "remains outside 50 ms");
    Access::scrubObservedPosition(controller, 55.0);
    expect(!Access::hasScrub(controller) && !controller.paused() &&
               !Access::scrubTimeoutActive(controller) &&
               Access::scrubTimeoutCommand(controller) == 0,
           "later exact position convergence restores play intent and "
           "cancels the reusable watchdog");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    expect(Access::initializeEngine(controller),
           "scrub failure tests have a live libmpv client");
    const auto ready = Access::makeRendererReady(controller);
    const QUrl source(QStringLiteral("wam-test://scrub/fail-safe"));
    Access::seedCommittedMedia(controller, source, 102, ready, 1002, 1, 2,
                               0, true);
    Access::setCachedTransportState(controller, 5.0, true, false, false);
    int paused = 1;
    mpv_set_property(Access::core(controller)->handle(), "pause",
                     MPV_FORMAT_FLAG, &paused);

    controller.beginScrub();
    controller.previewSeekTo(-5.0);
    const std::uint64_t preview = Access::scrubCommand(controller);
    expect(nearlyEqual(Access::scrubTarget(controller), 0.0),
           "preview targets clamp to the current timeline");
    controller.play();
    controller.pause();
    controller.play();
    expect(!Access::scrubIntendsPause(controller),
           "play and pause update only post-gesture intent");
    controller.endScrub(500.0);
    Access::scrubCommandReply(controller, preview, MPV_ERROR_COMMAND);
    const std::uint64_t final = Access::scrubCommand(controller);
    expect(final != 0 && final != preview &&
               nearlyEqual(Access::scrubTarget(controller), 500.0),
           "a failed preview still dispatches the retained final target");
    Access::scrubTimeout(controller, final);
    expect(Access::hasScrub(controller) &&
               Access::scrubAbortPending(controller) &&
               !Access::scrubTimeoutActive(controller),
           "timeout requests abort while retaining capacity-one ownership");
    Access::scrubCommandReply(controller, final, MPV_ERROR_COMMAND);
    expect(!Access::hasScrub(controller),
           "the exact abort reply exits after the one final replacement");

    controller.beginScrub();
    controller.previewSeekTo(8.0);
    expect(Access::hasScrub(controller),
           "a new scrub can begin after timeout cleanup");
    controller.stop();
    expect(!Access::hasScrub(controller) && controller.paused(),
           "Stop burns scrub identity without a late transport restore");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    expect(Access::initializeEngine(controller),
           "scrub lifecycle tests have a live libmpv client");
    auto ready = Access::makeRendererReady(controller);
    const QUrl source(QStringLiteral("wam-test://scrub/lifecycle"));
    Access::seedCommittedMedia(controller, source, 103, ready, 1003, 1, 2,
                               0, true);
    Access::setCachedTransportState(controller, 6.0, true, false, false);
    int paused = 1;
    mpv_set_property(Access::core(controller)->handle(), "pause",
                     MPV_FORMAT_FLAG, &paused);
    controller.beginScrub();
    controller.previewSeekTo(12.0);
    const std::uint64_t first = Access::scrubCommand(controller);
    Access::scrubSeekStarted(controller);
    Access::scrubCommandReply(controller, first);
    Access::scrubRestart(controller, 12.0);
    controller.endScrub(13.0);
    const std::uint64_t final = Access::scrubCommand(controller);
    expect(Access::scrubCommandExact(controller) &&
               std::string_view(Access::scrubCommandMode(controller)) ==
                   "absolute+exact",
           "release after a drained preview still dispatches an exact seek");
    Access::scrubSeekStarted(controller);
    Access::scrubCommandReply(controller, final);
    Access::scrubRestart(controller, 13.0);
    expect(!Access::hasScrub(controller) && controller.paused(),
           "successful final seek restores an initially paused player");

    controller.beginScrub();
    controller.previewSeekTo(14.0);
    const std::uint64_t retired = Access::scrubCommand(controller);
    const auto retired_render = Access::invalidateRenderer(controller);
    Access::renderInvalidated(controller, retired_render);
    expect(!Access::hasScrub(controller) &&
               !Access::scrubTimeoutActive(controller),
           "renderer invalidation burns scrub ownership and its watchdog");
    Access::scrubCommandReply(controller, retired);
    expect(!Access::hasScrub(controller),
           "a stale reply cannot resurrect invalidated scrub ownership");

    ready = Access::makeRendererReady(controller);
    Access::finishRecoveryForTest(controller, ready);
    Access::seedCommittedMedia(controller, source, 103, ready, 1003, 1, 2,
                               0, true);
    controller.beginScrub();
    controller.previewSeekTo(14.5);
    const std::uint64_t timed_out = Access::scrubCommand(controller);
    controller.endScrub(14.75);
    Access::scrubTimeout(controller, timed_out);
    expect(Access::scrubAbortPending(controller) &&
               Access::scrubCommand(controller) == timed_out,
           "timeout cannot publish a replacement before abort completion");
    Access::scrubSeekStarted(controller);
    Access::scrubRestart(controller, 14.5);
    expect(Access::scrubCommand(controller) == timed_out,
           "late seek events cannot retire a timed-out command");
    Access::scrubCommandReply(controller, timed_out);
    expect(!Access::hasScrub(controller),
           "timed-out success reply exits without an overlapping replacement");
    Access::scrubSeekStarted(controller);
    Access::scrubPlaybackRestart(controller);
    expect(!Access::hasScrub(controller),
           "late events from a timed-out seek remain inert after cleanup");

    controller.beginScrub();
    controller.previewSeekTo(14.9);
    const std::uint64_t reply_first = Access::scrubCommand(controller);
    controller.endScrub(15.1);
    Access::scrubCommandReply(controller, reply_first);
    expect(Access::scrubTimeoutActive(controller) &&
               Access::scrubTimeoutCommand(controller) == reply_first,
           "reply-before-restart keeps its original timeout identity armed");
    Access::scrubTimeout(controller, reply_first);
    expect(!Access::hasScrub(controller) &&
               !Access::scrubTimeoutActive(controller),
           "reply-first timeout drops pending final instead of overlapping "
           "an unproven decoder seek");

    controller.beginScrub();
    controller.previewSeekTo(15.0);
    Access::endFile(controller, MPV_END_FILE_REASON_EOF, 1003);
    expect(!Access::hasScrub(controller),
           "terminal EOF burns scrub ownership without restoring playback");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    Access::setCachedTransportState(controller, 10.0, false, false, false);
    Access::setDuration(controller, 100.0);

    expect(Access::beginNativeScrub(controller) &&
               Access::hasNativeScrub(controller) &&
               Access::nativeScrubGesture(controller) != 0 &&
               !Access::nativeIntendsPause(controller),
           "native scrub captures one nonzero gesture and playing intent");
    const std::uint64_t gesture = Access::nativeScrubGesture(controller);
    expect(Access::beginNativeScrub(controller) &&
               Access::nativeScrubGesture(controller) == gesture,
           "duplicate begin is idempotent within one native pointer gesture");

    expect(Access::previewNativeScrub(controller, -5.0) &&
               nearlyEqual(Access::nativeScrubTarget(controller), 0.0) &&
               nearlyEqual(controller.position(), 0.0) &&
               !Access::hasNativeSeek(controller),
           "native preview clamps and moves the visible playhead without an "
           "exact request");
    expect(Access::previewNativeScrub(controller, 30.0) &&
               Access::previewNativeScrub(controller, 40.0) &&
               nearlyEqual(Access::nativeScrubTarget(controller), 40.0) &&
               nearlyEqual(controller.position(), 40.0),
           "native preview traffic retains only the latest visual target");
    Access::setNativePauseIntent(controller, true);
    expect(Access::nativeIntendsPause(controller),
           "play/pause changes replace only native post-gesture intent");

    expect(Access::endNativeScrub(controller, 55.0) &&
               !Access::hasNativeScrub(controller) &&
               Access::hasNativeSeek(controller) &&
               Access::nativeSeekGesture(controller) == gesture &&
               Access::nativeSeekRequest(controller) != 0 &&
               nearlyEqual(Access::nativeSeekTarget(controller), 55.0) &&
               nearlyEqual(controller.position(), 55.0) &&
               Access::nativeIntendsPause(controller),
           "native release creates one exact identity at the final target and "
           "retains pause intent");
    const std::uint64_t first_request = Access::nativeSeekRequest(controller);
    expect(Access::stageNativeSeek(controller, 500.0) &&
               Access::nativeSeekGesture(controller) != gesture &&
               Access::nativeSeekRequest(controller) > first_request &&
               nearlyEqual(Access::nativeSeekTarget(controller), 100.0) &&
               nearlyEqual(controller.position(), 100.0),
           "ordinary native seeks use fresh identities and clamp to duration");
    expect(!Access::previewNativeScrub(
               controller, std::numeric_limits<double>::quiet_NaN()) &&
               controller.lastError().isEmpty(),
           "invalid or unowned native preview stays silent instead of opening "
           "an error dialog");
    Access::invalidateNativeSeek(controller);
    expect(!Access::hasNativeScrub(controller) &&
               !Access::hasNativeSeek(controller),
           "native Stop/open invalidation burns both gesture and exact intent");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    Access::setCachedTransportState(controller, 10.0, false, false, false);
    Access::setDuration(controller, 100.0);
    expect(Access::beginNativeScrub(controller),
           "preview identity fixture owns one native gesture");
    const std::uint64_t gesture = Access::nativeScrubGesture(controller);

    Access::NativePreviewProbe previews;
    Access::NativePreviewDemandProbe demands;
    Access::installPublicNativePreviewSeam(controller, previews, demands);
    controller.previewSeekTo(20.0);
    const std::uint64_t request_a = Access::nativePreviewRequest(controller);
    expect(request_a != 0 && previews.submissions == 1,
           "public A demand is admitted immediately");
    controller.previewSeekTo(30.0);
    const std::uint64_t request_b = Access::nativePreviewRequest(controller);
    controller.previewSeekTo(40.0);
    const std::uint64_t request_c = Access::nativePreviewRequest(controller);
    expect(previews.submissions == 1 && previews.requests.size() == 1 &&
               previews.requests[0] == request_a && request_a < request_b &&
               request_b < request_c &&
               demands.requests ==
                   std::vector<std::uint64_t>{request_a, request_b, request_c} &&
               demands.targets == std::vector<double>{20.0, 30.0, 40.0} &&
               demands.observedAt ==
                   std::vector<std::uint64_t>{1, 3, 4} &&
               previews.submittedAt == std::vector<std::uint64_t>{2} &&
               Access::nativeDispatchedPreviewRequest(controller) ==
                   request_a &&
               nearlyEqual(controller.position(), 40.0),
           "public A/B/C records each exact demand before pacing, publishes "
           "optimistic C, and submits only A while native work is in flight");
    Access::publishNativeMainPosition(controller, 10.25);
    Access::publishNativeMainPosition(controller, 10.5);
    expect(nearlyEqual(controller.position(), 40.0),
           "paused audio clock and main-video draw drains advance privately "
           "without repainting over optimistic C");
    expect(!Access::presentNativePreview(controller, gesture, request_b,
                                         29.9, &previews) &&
               nearlyEqual(controller.position(), 40.0),
           "a coalesced request that was never dispatched cannot publish");
    expect(Access::presentNativePreview(controller, gesture, request_a, 19.9,
                                        &previews) &&
               previews.submissions == 2 && previews.requests.size() == 2 &&
               previews.requests[1] == request_c &&
               previews.submittedAt ==
                   std::vector<std::uint64_t>{2, 5} &&
               Access::nativeDispatchedPreviewRequest(controller) ==
                   request_c &&
               nearlyEqual(controller.position(), 40.0),
           "A's real draw makes progress without regressing the C handle and "
           "dispatches only previously timestamped demand C; B stays demand-only");
    expect(Access::presentNativePreview(controller, gesture, request_c,
                                        39.875, &previews) &&
               nearlyEqual(controller.position(), 39.875),
           "the exact latest C presentation publishes its actual PTS");
    Access::clearPublicNativePreviewSeam(controller);

    Access::NativeSeekProbe commit;
    expect(Access::finishNativeScrub(controller, 42.0, commit) &&
               commit.submissions == 1 && commit.gesture == gesture &&
               commit.request > request_c &&
               nearlyEqual(commit.target, 42.0) &&
               !commit.intended_paused &&
               !Access::presentNativePreview(controller, gesture,
                                             request_c, 39.9, &previews) &&
               nearlyEqual(controller.position(), 42.0),
           "release burns preview completion, submits one fresh final commit, "
           "and keeps the captured playing intent");
    Access::invalidateNativeSeek(controller);

    Access::setCachedTransportState(controller, 42.0, true, false, false);
    expect(Access::beginNativeScrub(controller),
           "paused preview fixture owns a new gesture");
    const std::uint64_t paused_gesture =
        Access::nativeScrubGesture(controller);
    Access::NativePreviewProbe rejected;
    Access::rejectNativePreview(rejected);
    expect(Access::submitNativePreview(controller, 50.0, rejected) &&
               rejected.submissions == 1 &&
               Access::nativeDispatchedPreviewRequest(controller) == 0 &&
               controller.lastError().isEmpty() &&
               nearlyEqual(controller.position(), 50.0),
           "preview refusal is quiet, releases demand, and retains the "
           "optimistic pointer target");
    Access::acceptNativePreview(rejected);
    expect(Access::submitNativePreview(controller, 60.0, rejected) &&
               rejected.submissions == 2 &&
               Access::nativeDispatchedPreviewRequest(controller) ==
                   rejected.requests[1] &&
               nearlyEqual(controller.position(), 60.0),
           "the next pointer target can issue after synchronous refusal");
    Access::invalidateNativeSeek(controller);
    expect(!Access::presentNativePreview(controller, paused_gesture,
                                         rejected.requests[1], 59.9,
                                         &rejected) &&
               nearlyEqual(controller.position(), 60.0),
           "Stop/open cancellation makes an otherwise exact presentation stale");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    Access::setCachedTransportState(controller, 0.0, false, false, false);
    Access::setDuration(controller, 1000.0);
    expect(Access::beginNativeScrub(controller),
           "replacement stress owns one native gesture");
    const std::uint64_t gesture = Access::nativeScrubGesture(controller);
    Access::NativePreviewProbe previews;
    expect(Access::submitNativePreview(controller, 1.0, previews),
           "replacement stress dispatches its first request");
    const std::uint64_t first = Access::nativePreviewRequest(controller);
    for (unsigned index = 2; index <= 512; ++index) {
      expect(Access::submitNativePreview(controller, index, previews),
             "replacement stress retains each finite desired target");
    }
    const std::uint64_t latest = Access::nativePreviewRequest(controller);
    expect(previews.submissions == 1 && latest > first &&
               nearlyEqual(controller.position(), 512.0),
           "512 movements retain bounded backend demand and an immediate "
           "latest handle");
    expect(Access::presentNativePreview(controller, gesture, first, 0.875,
                                        &previews) &&
               previews.submissions == 2 && previews.requests.back() == latest &&
               nearlyEqual(controller.position(), 512.0),
           "first completion dispatches only the 512th target");
    expect(Access::presentNativePreview(controller, gesture, latest, 511.875,
                                        &previews) &&
               previews.submissions == 2 &&
               nearlyEqual(controller.position(), 511.875),
           "latest completion publishes without an intermediate command storm");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    Access::setCachedTransportState(controller, 10.0, false, false, false);
    Access::setDuration(controller, 100.0);
    expect(Access::beginNativeScrub(controller),
           "release cancellation fixture owns a gesture");
    const std::uint64_t gesture = Access::nativeScrubGesture(controller);
    Access::NativePreviewProbe previews;
    expect(Access::submitNativePreview(controller, 20.0, previews),
           "release fixture dispatches A");
    const std::uint64_t request_a = Access::nativePreviewRequest(controller);
    expect(Access::submitNativePreview(controller, 30.0, previews),
           "release fixture coalesces B");
    Access::NativeSeekProbe commit;
    expect(Access::finishNativeScrub(controller, 32.0, commit) &&
               !Access::presentNativePreview(controller, gesture, request_a,
                                             19.9, &previews) &&
               !Access::failNativePreview(controller, gesture, request_a,
                                          &previews) &&
               previews.submissions == 1 &&
               nearlyEqual(controller.position(), 32.0),
           "release burns both preview terminals and A cannot dispatch B");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    Access::setCachedTransportState(controller, 10.0, false, false, false);
    Access::setDuration(controller, 100.0);
    expect(Access::beginNativeScrub(controller),
           "reentrant preview fixture owns a gesture");
    const std::uint64_t gesture = Access::nativeScrubGesture(controller);
    Access::NativePreviewProbe previews;
    previews.reenterController = &controller;
    previews.reenterTarget = 30.0;
    expect(Access::submitNativePreview(controller, 20.0, previews) &&
               previews.submissions == 1 && previews.reentered &&
               nearlyEqual(controller.position(), 30.0),
           "synchronous submitter reentry coalesces instead of recursively "
           "issuing media work");
    const std::uint64_t request_a = previews.requests.front();
    const std::uint64_t request_b = Access::nativePreviewRequest(controller);
    expect(request_b > request_a &&
               Access::presentNativePreview(controller, gesture, request_a,
                                            19.9, &previews) &&
               previews.submissions == 2 && previews.requests.back() == request_b &&
               nearlyEqual(controller.position(), 30.0),
           "reentrant latest desire dispatches once after A completes");
    expect(Access::presentNativePreview(controller, gesture, request_b, 29.9,
                                        &previews) &&
               nearlyEqual(controller.position(), 29.9),
           "reentrant follow-up publishes only its own exact presentation");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    Access::setCachedTransportState(controller, 10.0, false, false, false);
    Access::setDuration(controller, 100.0);
    expect(Access::beginNativeScrub(controller),
           "synchronous failure fixture owns a gesture");

    Access::NativePreviewProbe immediate;
    immediate.failController = &controller;
    immediate.failDuringSubmit = true;
    expect(Access::submitNativePreview(controller, 20.0, immediate) &&
               immediate.submissions == 1 &&
               immediate.failedDuringSubmitAccepted &&
               Access::nativeDispatchedPreviewRequest(controller) == 0 &&
               nearlyEqual(controller.position(), 20.0),
           "failure during submit retires A without the outer Accepted result "
           "restoring its slot");
    Access::invalidateNativeSeek(controller);

    expect(Access::beginNativeScrub(controller),
           "reentrant failure fixture owns a fresh gesture");
    const std::uint64_t gesture = Access::nativeScrubGesture(controller);
    Access::NativePreviewProbe reentrant;
    reentrant.reenterController = &controller;
    reentrant.reenterTarget = 40.0;
    reentrant.failController = &controller;
    reentrant.failDuringSubmit = true;
    expect(Access::submitNativePreview(controller, 30.0, reentrant) &&
               reentrant.reentered && reentrant.failedDuringSubmitAccepted &&
               reentrant.submissions == 2 && reentrant.requests.size() == 2 &&
               reentrant.requests[1] > reentrant.requests[0] &&
               Access::nativeDispatchedPreviewRequest(controller) ==
                   reentrant.requests[1] &&
               nearlyEqual(controller.position(), 40.0),
           "submitter reentry stages B before A failure and dispatches B once");
    expect(Access::failNativePreview(controller, gesture,
                                    reentrant.requests[1], &reentrant) &&
               Access::nativeDispatchedPreviewRequest(controller) == 0,
           "reentrant follow-up failure retires the exact B slot");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    Access::setCachedTransportState(controller, 10.0, false, false, false);
    Access::setDuration(controller, 100.0);
    expect(Access::beginNativeScrub(controller),
           "position-signal Stop fixture owns a gesture");

    Access::NativePreviewProbe retired;
    bool stopped = false;
    QMetaObject::Connection stop_connection;
    stop_connection = QObject::connect(
        &controller, &wam::qt::PlayerController::positionChanged, &controller,
        [&] {
          QObject::disconnect(stop_connection);
          stopped = true;
          Access::invalidateNativeSeek(controller);
        });
    expect(Access::submitNativePreview(controller, 20.0, retired) && stopped &&
               retired.submissions == 0 &&
               !Access::hasNativeScrub(controller),
           "a synchronous positionChanged Stop prevents the retired preview "
           "from reaching the backend");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    Access::setCachedTransportState(controller, 10.0, false, false, false);
    Access::setDuration(controller, 100.0);
    expect(Access::beginNativeScrub(controller),
           "position-signal Commit fixture owns a gesture");

    Access::NativePreviewProbe retired;
    Access::NativeSeekProbe commit;
    bool committed = false;
    QMetaObject::Connection commit_connection;
    commit_connection = QObject::connect(
        &controller, &wam::qt::PlayerController::positionChanged, &controller,
        [&] {
          QObject::disconnect(commit_connection);
          committed = Access::finishNativeScrub(controller, 25.0, commit);
        });
    expect(Access::submitNativePreview(controller, 20.0, retired) &&
               committed && retired.submissions == 0 &&
               commit.submissions == 1 && Access::hasNativeSeek(controller) &&
               !Access::hasNativeScrub(controller) &&
               nearlyEqual(controller.position(), 25.0),
           "a synchronous positionChanged Commit burns the preview identity "
           "before native preview submission");
    Access::invalidateNativeSeek(controller);
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    Access::setCachedTransportState(controller, 10.0, false, false, false);
    Access::setDuration(controller, 100.0);
    expect(Access::beginNativeScrub(controller),
           "position-signal replacement fixture owns gesture A");
    const std::uint64_t gesture_a = Access::nativeScrubGesture(controller);

    Access::NativePreviewProbe retired;
    Access::NativePreviewProbe replacement;
    Access::NativeSeekProbe commit;
    bool replaced = false;
    QMetaObject::Connection replacement_connection;
    replacement_connection = QObject::connect(
        &controller, &wam::qt::PlayerController::positionChanged, &controller,
        [&] {
          QObject::disconnect(replacement_connection);
          const bool committed =
              Access::finishNativeScrub(controller, 25.0, commit);
          const bool began = Access::beginNativeScrub(controller);
          const bool previewed =
              Access::submitNativePreview(controller, 40.0, replacement);
          replaced = committed && began && previewed;
        });
    expect(Access::submitNativePreview(controller, 20.0, retired) && replaced &&
               retired.submissions == 0 && commit.submissions == 1 &&
               replacement.submissions == 1 &&
               Access::nativeScrubGesture(controller) != gesture_a &&
               Access::nativeDispatchedPreviewRequest(controller) ==
                   replacement.requests.front() &&
               nearlyEqual(controller.position(), 40.0),
           "Commit followed by a new gesture submits only the replacement "
           "preview after positionChanged reentry");
    Access::invalidateNativeSeek(controller);
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    Access::setCachedTransportState(controller, 10.0, false, false, false);
    Access::setDuration(controller, 100.0);
    expect(Access::beginNativeScrub(controller),
           "preview outcome fixture owns a gesture");
    const std::uint64_t gesture = Access::nativeScrubGesture(controller);

    Access::NativePreviewProbe outcomes;
    Access::replaceNativePreview(outcomes);
    expect(Access::submitNativePreview(controller, 20.0, outcomes) &&
               outcomes.submissions == 1 &&
               Access::nativeDispatchedPreviewRequest(controller) ==
                   outcomes.requests.back() &&
               Access::presentNativePreview(
                   controller, gesture, outcomes.requests.back(), 19.75,
                   &outcomes),
           "a synchronous Replaced disposition retains ownership until its "
           "exact presentation");

    Access::staleNativePreview(outcomes);
    expect(Access::submitNativePreview(controller, 30.0, outcomes) &&
               outcomes.submissions == 2 &&
               Access::nativeDispatchedPreviewRequest(controller) == 0,
           "a synchronous Stale disposition releases the work slot");

    Access::acceptNativePreview(outcomes);
    expect(Access::submitNativePreview(controller, 40.0, outcomes),
           "a later request can reuse the slot after Stale");
    const std::uint64_t finite_request = outcomes.requests.back();
    expect(!Access::presentNativePreview(
               controller, gesture, finite_request,
               std::numeric_limits<double>::quiet_NaN(), &outcomes) &&
               !Access::presentNativePreview(
                   controller, gesture, finite_request,
                   std::numeric_limits<double>::infinity(), &outcomes) &&
               Access::nativeDispatchedPreviewRequest(controller) ==
                   finite_request &&
               Access::presentNativePreview(controller, gesture,
                                            finite_request, 39.75, &outcomes),
           "non-finite presentation facts are ignored without consuming the "
           "valid in-flight identity");

    Access::NativePreviewProbe synchronous;
    synchronous.presentController = &controller;
    synchronous.presentDuringSubmit = true;
    synchronous.presentedActual = 49.75;
    expect(Access::submitNativePreview(controller, 50.0, synchronous) &&
               synchronous.submissions == 1 &&
               synchronous.presentedDuringSubmitAccepted &&
               Access::nativeDispatchedPreviewRequest(controller) == 0 &&
               nearlyEqual(controller.position(), 49.75),
           "Presented during submission is consumed once without restoring "
           "the retired work slot");
    Access::invalidateNativeSeek(controller);
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController exhausted_gesture;
    Access::exhaustNativeGestureIds(exhausted_gesture);
    expect(!Access::beginNativeScrub(exhausted_gesture) &&
               !Access::hasNativeScrub(exhausted_gesture),
           "native gesture identity exhaustion never wraps to a live value");

    wam::qt::PlayerController exhausted_request;
    expect(Access::beginNativeScrub(exhausted_request),
           "request exhaustion fixture first owns a gesture");
    Access::exhaustNativeRequestIds(exhausted_request);
    expect(!Access::endNativeScrub(exhausted_request, 1.0) &&
               !Access::hasNativeScrub(exhausted_request) &&
               !Access::hasNativeSeek(exhausted_request),
           "native request identity exhaustion releases gesture without "
           "forging a commit");
  }

  {
    using Access = wam::qt::PlayerControllerTestAccess;
    wam::qt::PlayerController controller;
    Access::setCachedTransportState(controller, 12.0, false, false, false);
    Access::setDuration(controller, 100.0);

    Access::NativeSeekProbe release;
    expect(Access::beginNativeScrub(controller),
           "native dispatch fixture owns one pointer gesture");
    const std::uint64_t release_gesture =
        Access::nativeScrubGesture(controller);
    expect(Access::previewNativeScrub(controller, 25.0) &&
               Access::finishNativeScrub(controller, 30.0, release) &&
               release.submissions == 1 &&
               release.gesture == release_gesture && release.request != 0 &&
               nearlyEqual(release.target, 30.0) &&
               !release.intended_paused && Access::hasNativeSeek(controller),
           "native release submits one exact command with the gesture, "
           "request, target, and captured play intent");
    expect(!Access::completeNativeSeek(controller, release.gesture,
                                       release.request + 1,
                                       release.target) &&
               Access::hasNativeSeek(controller),
           "a stale CommitReady identity cannot clear an accepted seek");
    expect(Access::completeNativeSeek(controller, release.gesture,
                                      release.request, release.target) &&
               !Access::hasNativeSeek(controller),
           "only exact CommitReady identity clears controller ownership");

    Access::NativeSeekProbe rejected;
    Access::rejectNativeSubmission(rejected);
    expect(Access::submitNativeSeek(controller, 45.0, rejected) &&
               rejected.submissions == 1 &&
               !Access::hasNativeSeek(controller) &&
               nearlyEqual(controller.position(), 30.0),
           "a synchronous native refusal is consumed without staging a "
           "false seek or leaving the optimistic playhead behind");

    Access::NativeSeekProbe compatibility;
    Access::useCompatibilitySubmission(compatibility);
    expect(Access::routesNativeSeekToCompatibility(controller, 50.0,
                                                    compatibility) &&
               compatibility.submissions == 1 &&
               !Access::hasNativeSeek(controller) &&
               nearlyEqual(controller.position(), 30.0),
           "a compatibility disposition falls through without claiming "
           "native ownership or publishing an unsubmitted target");

    Access::NativeSeekProbe immediate_ready;
    Access::completeNativeSubmissionSynchronously(immediate_ready,
                                                  controller);
    expect(Access::submitNativeSeek(controller, 60.0, immediate_ready) &&
               immediate_ready.submissions == 1 &&
               !Access::hasNativeSeek(controller) &&
               nearlyEqual(controller.position(), 60.0),
           "CommitReady during submission is retained without a staging "
           "race or permanently owned seek");

    Access::NativeSeekProbe immediate_failure;
    Access::failNativeSubmissionSynchronously(immediate_failure, controller);
    expect(Access::submitNativeSeek(controller, 70.0, immediate_failure) &&
               immediate_failure.submissions == 1 &&
               !Access::hasNativeSeek(controller) &&
               nearlyEqual(controller.position(), 60.0),
           "failure during submission cannot be overwritten by late local "
           "intent staging");

    Access::NativeSeekProbe later_failure;
    expect(Access::submitNativeSeek(controller, 80.0, later_failure) &&
               Access::hasNativeSeek(controller),
           "an accepted native command remains owned until a terminal fact");
    Access::failNativeSeek(controller, later_failure.gesture,
                           later_failure.request + 1);
    expect(Access::hasNativeSeek(controller),
           "a stale failure identity cannot clear an accepted native seek");
    Access::failNativeSeek(controller, later_failure.gesture,
                           later_failure.request);
    expect(!Access::hasNativeSeek(controller),
           "the exact failure identity clears controller ownership");

    Access::NativeSeekProbe nested;
    Access::NativeSeekProbe outer;
    Access::rejectNativeSubmission(outer);
    Access::nestNativeSubmissionSynchronously(outer, controller, 95.0,
                                              nested);
    expect(Access::submitNativeSeek(controller, 90.0, outer) &&
               outer.submissions == 1 && nested.submissions == 1 &&
               Access::hasNativeSeek(controller) &&
               Access::nativeSeekGesture(controller) == nested.gesture &&
               Access::nativeSeekRequest(controller) == nested.request &&
               nearlyEqual(Access::nativeSeekTarget(controller), 95.0) &&
               nearlyEqual(controller.position(), 95.0),
           "a reentrant accepted seek supersedes the outer refusal without "
           "rollback or compatibility fallthrough");
    Access::failNativeSeek(controller, nested.gesture, nested.request);
  }

  // Any wakeup posted during initialization is context-bound to the destroyed
  // controller and must be discarded safely.
  app.processEvents(QEventLoop::AllEvents);

  if (failures == 0)
    std::cout << "lazy player controller tests passed\n";
  return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
