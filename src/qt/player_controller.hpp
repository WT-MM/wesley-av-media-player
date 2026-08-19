#pragma once

#include "caption_service.hpp"
#include "jobs.hpp"
#include "playback_policy.hpp"

#include <QObject>
#include <QPointer>
#include <QString>
#include <QUrl>

#include <cstdint>
#include <memory>
#include <optional>
#include <vector>

class QTimer;
struct mpv_event_end_file;

namespace wam::qt {

class MpvVideoItem;
class NativePlaybackOwner;
class PlayerCore;
class PlayerControllerTestAccess;

} // namespace wam::qt

namespace wam::playback::mpv {
class MpvRuntime;
}

namespace wam::media::native_playback {
struct CommitReady;
struct PreviewFailed;
struct PreviewPresented;
} // namespace wam::media::native_playback

namespace wam::qt {

// QML-facing playback state and commands. All regular libmpv client calls are
// made on this object's (GUI) thread; video rendering remains isolated on Qt
// Quick's render thread in MpvVideoItem.
class PlayerController final : public QObject {
  Q_OBJECT

  Q_PROPERTY(bool available READ available NOTIFY availableChanged)
  Q_PROPERTY(bool hasMedia READ hasMedia NOTIFY hasMediaChanged)
  Q_PROPERTY(QUrl source READ source WRITE setSource NOTIFY sourceChanged)
  Q_PROPERTY(QString mediaTitle READ mediaTitle NOTIFY mediaTitleChanged)
  Q_PROPERTY(bool playing READ playing NOTIFY playingChanged)
  Q_PROPERTY(bool paused READ paused NOTIFY pausedChanged)
  Q_PROPERTY(double position READ position WRITE seekTo NOTIFY positionChanged)
  Q_PROPERTY(double duration READ duration NOTIFY durationChanged)
  Q_PROPERTY(double volume READ volume WRITE setVolume NOTIFY volumeChanged)
  Q_PROPERTY(bool muted READ muted WRITE setMuted NOTIFY mutedChanged)
  Q_PROPERTY(double rate READ rate WRITE setRate NOTIFY rateChanged)
  Q_PROPERTY(bool captionsVisible READ captionsVisible WRITE setCaptionsVisible
                 NOTIFY captionsVisibleChanged)
  Q_PROPERTY(bool preservePitch READ preservePitch WRITE setPreservePitch NOTIFY
                 preservePitchChanged)
  Q_PROPERTY(int appearance READ appearance WRITE setAppearance NOTIFY
                 appearanceChanged)
  Q_PROPERTY(double seekStepSeconds READ seekStepSeconds WRITE
                 setSeekStepSeconds NOTIFY seekStepSecondsChanged)
  // QuickTime-style floating window: when true, the windowed frame is kept
  // hugging the current video's aspect ratio (no letterbox bars). Purely a
  // QML/window-chrome behavior toggle; the controller only stores and
  // persists it. Default on. See qml/Main.qml's re-snap machinery.
  Q_PROPERTY(bool windowHugsVideo READ windowHugsVideo WRITE
                 setWindowHugsVideo NOTIFY windowHugsVideoChanged)
  Q_PROPERTY(double trimIn READ trimIn WRITE setTrimIn NOTIFY trimInChanged)
  Q_PROPERTY(double trimOut READ trimOut WRITE setTrimOut NOTIFY trimOutChanged)
  // Retiming applied to the *exported* file, deliberately independent of the
  // viewing rate above: watching at 2x is a way to review, not an instruction
  // to ship a 2x cut. Both of these belong to the export, are reset per media
  // (see resetTimeline), and are not persisted.
  Q_PROPERTY(double exportSpeed READ exportSpeed WRITE setExportSpeed NOTIFY
                 exportSpeedChanged)
  Q_PROPERTY(bool exportPreservePitch READ exportPreservePitch WRITE
                 setExportPreservePitch NOTIFY exportPreservePitchChanged)
  Q_PROPERTY(bool exporting READ exporting NOTIFY exportingChanged)
  Q_PROPERTY(QString exportStatus READ exportStatus NOTIFY exportStatusChanged)
  Q_PROPERTY(bool captioning READ captioning NOTIFY captioningChanged)
  Q_PROPERTY(
      QString captionStatus READ captionStatus NOTIFY captionStatusChanged)
  Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)
  // Informational playback notices (e.g. "using compatibility playback")
  // that never interrupt the user with a modal surface. Distinct from
  // lastError, which QML still presents as a blocking dialog for genuine
  // failures where playback did not continue.
  Q_PROPERTY(QString lastNotice READ lastNotice NOTIFY lastNoticeChanged)

public:
  explicit PlayerController(QObject *parent = nullptr);
  ~PlayerController() override;

  PlayerController(const PlayerController &) = delete;
  PlayerController &operator=(const PlayerController &) = delete;

  // Compatibility-router handoff. Provisioning retains an already validated
  // runtime but does not create an mpv handle; initializePlaybackEngine() can
  // consume it only after the router has explicitly selected fallback.
  [[nodiscard]] bool provisionMpvFallbackRuntime(
      std::shared_ptr<const ::wam::playback::mpv::MpvRuntime> runtime);

  [[nodiscard]] bool available() const;
  [[nodiscard]] bool hasMedia() const { return !source_.isEmpty(); }
  [[nodiscard]] QUrl source() const { return source_; }
  [[nodiscard]] QString mediaTitle() const { return media_title_; }
  [[nodiscard]] bool playing() const {
    return !paused_ && !idle_ && !eof_reached_;
  }
  [[nodiscard]] bool paused() const { return paused_; }
  [[nodiscard]] double position() const { return position_; }
  [[nodiscard]] double duration() const { return duration_; }
  // Normalized UI volume. mpv's 0..100 range maps to 0..1 here.
  [[nodiscard]] double volume() const { return volume_; }
  [[nodiscard]] bool muted() const { return muted_; }
  [[nodiscard]] double rate() const { return rate_; }
  [[nodiscard]] bool captionsVisible() const { return captions_visible_; }
  [[nodiscard]] bool preservePitch() const { return preserve_pitch_; }
  // 0 = light (default), 1 = dark, 2 = follow the operating system.
  [[nodiscard]] int appearance() const { return appearance_; }
  // Seconds skipped by the Left/Right arrow shortcuts and the transport's
  // skip buttons. Whole-second values in [1, 60]; default 5.
  [[nodiscard]] double seekStepSeconds() const { return seek_step_seconds_; }
  // See the Q_PROPERTY doc above: purely a persisted preference the QML
  // window chrome reads and reacts to.
  [[nodiscard]] bool windowHugsVideo() const { return window_hugs_video_; }
  [[nodiscard]] double trimIn() const { return trim_in_; }
  [[nodiscard]] double trimOut() const { return trim_out_; }
  [[nodiscard]] double exportSpeed() const { return export_speed_; }
  [[nodiscard]] bool exportPreservePitch() const {
    return export_preserve_pitch_;
  }
  [[nodiscard]] bool exporting() const { return exporting_; }
  [[nodiscard]] QString exportStatus() const { return export_status_; }
  [[nodiscard]] bool captioning() const { return captioning_; }
  [[nodiscard]] QString captionStatus() const { return caption_status_; }
  [[nodiscard]] QString lastError() const { return last_error_; }
  [[nodiscard]] QString lastNotice() const { return last_notice_; }

  void setSource(const QUrl &source);

  Q_INVOKABLE void openFileDialog();
  Q_INVOKABLE bool open(const QUrl &source);
  Q_INVOKABLE void play();
  Q_INVOKABLE void pause();
  Q_INVOKABLE void togglePlayPause();
  Q_INVOKABLE void stop();
  Q_INVOKABLE void beginScrub();
  Q_INVOKABLE void seekTo(double seconds);
  Q_INVOKABLE void previewSeekTo(double seconds);
  Q_INVOKABLE void endScrub(double seconds);
  Q_INVOKABLE void seekRelative(double seconds);
  Q_INVOKABLE void skipBackward();
  Q_INVOKABLE void skipForward();
  Q_INVOKABLE void toggleMute();
  Q_INVOKABLE void setMuted(bool muted);
  Q_INVOKABLE void setVolume(double volume);
  Q_INVOKABLE void setRate(double rate);
  Q_INVOKABLE void toggleCaptions();
  Q_INVOKABLE void setCaptionsVisible(bool visible);
  Q_INVOKABLE void toggleFullscreen();
  Q_INVOKABLE void setPreservePitch(bool preserve);
  Q_INVOKABLE void setAppearance(int appearance);
  Q_INVOKABLE void setSeekStepSeconds(double seconds);
  Q_INVOKABLE void setWindowHugsVideo(bool hugsVideo);
  Q_INVOKABLE void setTrimIn(double seconds);
  Q_INVOKABLE void setTrimOut(double seconds);
  Q_INVOKABLE void setExportSpeed(double speed);
  Q_INVOKABLE void setExportPreservePitch(bool preserve);
  Q_INVOKABLE void exportSelection();
  Q_INVOKABLE void exportSelectionTo(const QUrl &destination);
  Q_INVOKABLE void cancelExport();
  Q_INVOKABLE void generateCaptions();
  Q_INVOKABLE void generateCaptionsTo(const QUrl &destination);
  Q_INVOKABLE void cancelCaptioning();

  // Job/caption adapters can drive these while remaining independent of QML.
  void setExporting(bool exporting);
  void setCaptioning(bool captioning);
  void setCaptionStatus(const QString &status);

signals:
  void availableChanged();
  void hasMediaChanged();
  void sourceChanged();
  void mediaTitleChanged();
  void playingChanged();
  void pausedChanged();
  void positionChanged();
  void durationChanged();
  void volumeChanged();
  void mutedChanged();
  void rateChanged();
  void captionsVisibleChanged();
  void preservePitchChanged();
  void appearanceChanged();
  void seekStepSecondsChanged();
  void windowHugsVideoChanged();
  void trimInChanged();
  void trimOutChanged();
  void exportSpeedChanged();
  void exportPreservePitchChanged();
  void exportingChanged();
  void exportStatusChanged();
  void captioningChanged();
  void captionStatusChanged();
  void lastErrorChanged();
  void lastNoticeChanged();

  // The QML shell owns platform dialogs/window state. These requests keep the
  // playback core independent of Qt Widgets and native-window assumptions.
  void openFileDialogRequested();
  void fullscreenToggleRequested();
  void exportSelectionRequested(double trim_in, double trim_out);
  void generateCaptionsRequested();
  void cancelCaptioningRequested();

private:
  friend class PlayerCore;
  friend class MpvVideoItem;
  friend class NativePlaybackOwner;
  friend class PlayerControllerTestAccess;

  struct OpenAttempt {
    std::uint64_t id = 0;
    std::uint64_t request_serial = 0;
    std::uint64_t render_stamp = 0;
    std::int64_t playlist_entry_id = -1;
  };

#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  struct RoutedFallbackOpen {
    std::uint64_t attempt = 0;
    std::uint64_t serial = 0;
    std::uint64_t source_key = 0;
    PlaybackSourceClass source_class{PlaybackSourceClass::Network};
  };
#endif

  enum class RenderRecoveryMode {
    NoReselection,
    VideoReselect,
    FullReload,
  };

  struct RenderRecovery {
    std::uint64_t request_serial = 0;
    double position = 0.0;
    bool paused = true;
    RenderRecoveryMode mode = RenderRecoveryMode::NoReselection;
    std::int64_t video_track_id = -1;
    std::int64_t audio_track_id = -1;
    std::int64_t subtitle_track_id = -1;
    bool file_has_audio_track = false;
    bool track_snapshot_proven = false;
    std::vector<std::filesystem::path> external_subtitles;
    QUrl reload_source;
    std::int64_t playlist_position = -1;
    bool preserve_playlist_context = false;
    std::uint64_t accepted_render_stamp = 0;
    bool command_failed = false;
    bool file_loaded = false;
    bool playback_restarted = false;
    bool external_subtitles_restored = false;
    std::size_t external_subtitles_restored_count = 0;
    bool per_file_state_restored = false;
    bool transport_restored = false;
    bool position_overridden = false;
    std::uint64_t completion_token = 0;
    int restore_retry_count = 0;
    bool restore_retry_queued = false;
    QString restore_failure;
  };

  struct RenderRecoveryAttempt {
    std::uint64_t id = 0;
    std::uint64_t request_serial = 0;
    std::uint64_t render_stamp = 0;
    std::int64_t playlist_entry_id = -1;
    std::int64_t video_track_id = -1;
    RenderRecoveryMode mode = RenderRecoveryMode::NoReselection;
    std::int64_t started_playlist_entry_id = -1;
    bool restarted_playlist_entry = false;
  };

  struct LivePlaybackState {
    bool paused = true;
    bool idle = true;
    std::optional<bool> eof_reached;
    std::optional<double> position;
    std::optional<double> duration;
  };

  struct StartupPlaybackSync {
    std::uint64_t request_serial = 0;
    std::uint64_t render_stamp = 0;
    std::int64_t playlist_entry_id = -1;
    bool intended_paused = false;
    std::optional<double> intended_position;
    bool position_overridden = false;
    std::uint64_t completion_token = 0;
    int retry_count = 0;
  };

  struct PlaylistEntryRange {
    std::int64_t first = -1;
    std::uint64_t count = 0;
  };

  struct ScrubSeek {
    std::uint64_t gesture = 0;
    std::uint64_t request_serial = 0;
    std::uint64_t command = 0;
    std::int64_t playlist_entry_id = -1;
    double target = 0.0;
    std::optional<double> pending_target;
    std::optional<double> authoritative_position;
    bool intended_paused = true;
    // final records that pointer ownership has been released. command_exact
    // records the precision of the currently issued capacity-one command;
    // those states intentionally differ while an approximate preview is
    // draining after release.
    bool final = false;
    bool command_exact = false;
    bool command_replied = false;
    bool seek_started = false;
    bool playback_restarted = false;
    bool replacement_dispatched = false;
    bool abort_pending = false;
  };

  // Controller-side ownership for a native pointer gesture. The handle tracks
  // every movement immediately, while native media work is demand-driven: one
  // exact request may be in flight and all later movement coalesces into the
  // single latest desired identity. A real terminal presentation releases the
  // in-flight slot and immediately dispatches that latest desire. Releasing
  // the pointer burns both identities and creates one fresh CommitSeek.
  struct NativeScrubIntent {
    std::uint64_t gesture = 0;
    double origin = 0.0;
    double target = 0.0;
    std::uint64_t latest_preview_request = 0;
    std::uint64_t dispatched_preview_request = 0;
    bool intended_paused = true;
  };

  struct NativePreviewIntent {
    std::uint64_t gesture = 0;
    std::uint64_t request = 0;
    double target = 0.0;
  };

  struct NativeSeekIntent {
    std::uint64_t gesture = 0;
    std::uint64_t request = 0;
    double target = 0.0;
    double rollback_position = 0.0;
    bool intended_paused = true;
  };

  enum class NativeSeekTerminal : std::uint8_t {
    None,
    Ready,
    Failed,
  };

  struct NativeSeekSubmissionState {
    std::uint64_t gesture = 0;
    std::uint64_t request = 0;
    double target = 0.0;
    NativeSeekTerminal terminal{NativeSeekTerminal::None};
    NativeSeekSubmissionState *previous = nullptr;
  };

  enum class NativeSeekSubmission : std::uint8_t {
    Accepted,
    Rejected,
    Compatibility,
  };

  enum class NativeSeekDispatch : std::uint8_t {
    Consumed,
    Compatibility,
  };

  enum class NativePreviewSubmission : std::uint8_t {
    Accepted,
    Replaced,
    Stale,
    Rejected,
  };

  using NativeSeekSubmitter = NativeSeekSubmission (*)(
      void *context, const NativeSeekIntent &intent) noexcept;
  using NativePreviewSubmitter = NativePreviewSubmission (*)(
      void *context, const NativePreviewIntent &intent) noexcept;
  using NativePreviewDemandObserver = void (*)(
      void *context, const NativePreviewIntent &intent) noexcept;

  enum class ObservedProperty : uint64_t {
    Pause = 1,
    Idle,
    Position,
    Duration,
    Volume,
    Mute,
    Rate,
    CaptionsVisible,
    Path,
    MediaTitle,
    PreservePitch,
    EofReached,
    VideoTrack,
    AudioTrack,
    SubtitleTrack,
  };

  void drainMpvEvents();
  void requestVideoUpdate();
  void handleRenderInitializationFailure(const QString &error,
                                         std::uint64_t render_stamp);
  void handleRenderInvalidated(std::uint64_t retired_render_stamp);
  void handleOpenCommandReply(std::uint64_t reply_userdata, int error);
  void handleRenderRecoveryCommandReply(std::uint64_t reply_userdata,
                                        int error);
  void handleScrubCommandReply(std::uint64_t reply_userdata, int error);
  void handleScrubPlaybackRestart();
  void dispatchScrubSeek(double target, bool exact);
  void maybeCompleteScrubSeek();
  [[nodiscard]] static const char *scrubSeekMode(bool exact);
  void armScrubTimeout(std::uint64_t gesture, std::uint64_t request_serial,
                       std::uint64_t command);
  void cancelScrubTimeout();
  void handleScrubTimeout(std::uint64_t gesture, std::uint64_t request_serial,
                          std::uint64_t command);
  void finishScrubGesture(bool restore_transport);
  void invalidateScrubGesture();
  [[nodiscard]] static std::optional<std::uint64_t>
  reserveNativeSeekIdentity(std::uint64_t &high_water) noexcept;
  [[nodiscard]] double boundedSeekTarget(double seconds) const noexcept;
  [[nodiscard]] bool beginNativeScrubIntent();
  [[nodiscard]] std::optional<NativePreviewIntent>
  makeNativePreviewIntent(double seconds);
  [[nodiscard]] std::optional<NativePreviewIntent>
  makeObservedNativePreviewIntent(double seconds, void *context,
                                  NativePreviewDemandObserver observer);
  void dispatchNativePreviewIntent(const NativePreviewIntent &intent,
                                   void *context,
                                   NativePreviewSubmitter submitter);
  [[nodiscard]] std::optional<NativeSeekIntent>
  finishNativeScrubIntent(double seconds);
  [[nodiscard]] std::optional<NativeSeekIntent>
  makeNativeSeekIntent(double seconds);
  [[nodiscard]] NativeSeekDispatch
  dispatchNativeSeekIntent(const NativeSeekIntent &intent, void *context,
                           NativeSeekSubmitter submitter);
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  void dispatchNativePreviewIntent(const NativePreviewIntent &intent);
  void nativePreviewPresented(
      const ::wam::media::native_playback::PreviewPresented &presented);
  void nativePreviewFailed(
      const ::wam::media::native_playback::PreviewFailed &failed);
  [[nodiscard]] NativeSeekDispatch
  dispatchNativeSeekIntent(const NativeSeekIntent &intent);
  void
  nativeCommitReady(const ::wam::media::native_playback::CommitReady &ready);
#endif
  [[nodiscard]] bool completeNativePreviewPresented(
      std::uint64_t gesture, std::uint64_t request,
      double actual_presentation_time, void *context,
      NativePreviewSubmitter submitter);
  [[nodiscard]] bool completeNativePreviewFailed(
      std::uint64_t gesture, std::uint64_t request, void *context,
      NativePreviewSubmitter submitter);
  [[nodiscard]] bool acceptNativeCommitReady(std::uint64_t gesture,
                                             std::uint64_t request,
                                             double target);
  void nativeCommitFailed(std::uint64_t gesture,
                          std::uint64_t request) noexcept;
  void setNativeScrubPauseIntent(bool paused);
  void invalidateNativeScrubIntent() noexcept;
  void invalidateNativeSeekIntents() noexcept;
  void publishNativeMainPosition(double position);
  void publishSeekTarget(double target);
  void handleStartFile(std::int64_t playlist_entry_id);
  void handleEndFile(const mpv_event_end_file &end);
  void handlePlaybackReady(bool file_loaded);
  void restoreRenderRecovery();
  void queueRenderRecoveryCompletion();
  void finishRenderRecoveryCompletion(std::uint64_t completion_token,
                                      std::uint64_t request_serial,
                                      std::uint64_t render_stamp,
                                      std::int64_t playlist_entry_id);
  [[nodiscard]] std::optional<LivePlaybackState> readLivePlaybackState() const;
  [[nodiscard]] static bool
  livePlaybackStateMatchesRecovery(const RenderRecovery &recovery,
                                   const LivePlaybackState &live_state);
  [[nodiscard]] static bool
  livePlaybackStateMatchesStartupSync(const StartupPlaybackSync &startup_sync,
                                      const LivePlaybackState &live_state);
  void commitRenderRecovery(const RenderRecovery &recovery,
                            const LivePlaybackState &live_state);
  void queueStartupPlaybackSync();
  void finishStartupPlaybackSync(std::uint64_t completion_token,
                                 std::uint64_t request_serial,
                                 std::uint64_t render_stamp,
                                 std::int64_t playlist_entry_id);
  void reconcileStartupPlaybackSync(const LivePlaybackState &live_state);
  void commitStartupPlaybackSync(const LivePlaybackState &live_state);
  void scheduleRenderRecoveryRetry(const QString &error);
  void degradeRenderRecovery(const QString &error);
  void applyObservedPause(bool paused);
  void applyObservedPosition(double position);
  void applyObservedDuration(double duration);
  void applyObservedIdle(bool idle);
  void applyObservedEof(bool eof_reached);
  void applyObservedVideoTrack(std::int64_t video_track_id);
  void applyObservedAudioTrack(std::int64_t audio_track_id);
  void applyObservedSubtitleTrack(std::int64_t subtitle_track_id);
  void cacheCurrentTrackSelection();
  void cacheCurrentEntrySource();
  [[nodiscard]] static std::int64_t
  authoritativePlaylistEntry(std::int64_t live_entry,
                             std::int64_t captured_start_entry);
  [[nodiscard]] bool acceptsPlaybackObservation() const;
  [[nodiscard]] bool
  playlistEntryBelongsToCurrentLineage(std::int64_t playlist_entry_id) const;
  [[nodiscard]] bool engineReady() const;
  [[nodiscard]] bool needsRenderContext() const;
  bool initializePlaybackEngine();
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  void prepareRoutedOpenIntent(const QUrl &source);
  [[nodiscard]] bool nativeRouteAdmissionAllowed() const noexcept;
  [[nodiscard]] bool
  beginRoutedFallbackOpen(const QUrl &source, std::uint64_t attempt,
                          std::uint64_t serial, std::uint64_t source_key,
                          bool paused, PlaybackSourceClass source_class);
  void notifyRoutedFallbackOpenFailed();
  [[nodiscard]] bool resetRoutedFallbackCoreAfterRelease(
      const std::shared_ptr<PlayerCore> &expected_core);
#endif
  void finishStopUi(bool stop_compatibility_engine);
  bool flushPendingOpen(std::uint64_t render_stamp);
  bool flushRenderRecovery(std::uint64_t render_stamp);
  void continuePendingOpen();
  void abandonPendingOpen();
  void attachVideoItem(MpvVideoItem *item);
  void detachVideoItem(MpvVideoItem *item);
  [[nodiscard]] std::shared_ptr<PlayerCore> coreForRendering() const;

  void updatePause(bool paused);
  void updateIdle(bool idle);
  void updateEof(bool eof_reached);
  void updateDuration(double duration);
  void updateSource(const QUrl &source);
  void updateMediaTitle(const QString &title);
  void resetTimeline();
  void cancelCaptionsForMediaChange();
  void setLastError(const QString &error);
  // Non-blocking counterpart to setLastError: fallback-continuation notices
  // (native playback degraded to compatibility playback, or a seek could not
  // be served natively) where playback kept going and a modal dialog would
  // be pure interruption. QML surfaces this as a transient toast.
  void setLastNotice(const QString &notice);
  void setExportStatus(const QString &status);
  void cleanupExportStaging() noexcept;
  void startWorkPolling();
  void pollBackgroundWork();
  bool attachSubtitleFile(const std::filesystem::path &subtitle);

  std::shared_ptr<PlayerCore> core_;
  std::shared_ptr<const ::wam::playback::mpv::MpvRuntime> fallback_runtime_;
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  std::shared_ptr<PlayerCore> fallback_reset_core_;
  std::unique_ptr<NativePlaybackOwner> native_playback_;
  std::optional<RoutedFallbackOpen> routed_fallback_open_;
#endif
  QPointer<MpvVideoItem> video_item_;
  QTimer *work_timer_ = nullptr;
  QTimer *scrub_timeout_timer_ = nullptr;

  ::wam::BackgroundJob export_job_;
  ::wam::CaptionService caption_service_;

  QUrl source_;
  // requested_source_ is the authoritative GUI intent. source_ mirrors mpv's
  // observed path and can briefly clear during asynchronous replacement.
  QUrl requested_source_;
  QUrl pending_source_;
  QUrl committed_entry_source_;
  std::int64_t committed_playlist_position_ = -1;
  QString media_title_;
  int appearance_ = 0;
  double seek_step_seconds_ = 5.0;
  bool window_hugs_video_ = true;
  QString last_error_;
  QString last_notice_;
  QString export_status_;
  QString caption_status_;
  QString caption_cancel_reason_;
  std::filesystem::path export_output_;
  std::filesystem::path export_staging_;
  std::filesystem::path caption_input_;
  bool paused_ = true;
  bool idle_ = true;
  bool eof_reached_ = false;
  bool muted_ = false;
  bool captions_visible_ = true;
  bool preserve_pitch_ = true;
  double position_ = 0.0;
  double duration_ = 0.0;
  double volume_ = 1.0;
  double rate_ = 1.0;
  double trim_in_ = 0.0;
  double trim_out_ = 0.0;
  double export_speed_ = 1.0;
  bool export_preserve_pitch_ = true;
  bool exporting_ = false;
  bool captioning_ = false;
  bool export_cancel_requested_ = false;
  bool export_completion_pending_ = false;
  bool caption_completion_pending_ = false;
  bool observed_current_path_ = false;
  std::uint64_t request_serial_ = 0;
  std::uint64_t pending_request_serial_ = 0;
  std::uint64_t next_open_attempt_id_ = 0;
  std::uint64_t next_render_recovery_attempt_id_ = 0;
  std::uint64_t next_scrub_gesture_id_ = 0;
  std::uint64_t next_scrub_command_id_ = 0;
  std::uint64_t next_native_seek_gesture_id_ = 0;
  std::uint64_t next_native_seek_request_id_ = 0;
  std::uint64_t scrub_timeout_gesture_ = 0;
  std::uint64_t scrub_timeout_request_serial_ = 0;
  std::uint64_t scrub_timeout_command_ = 0;
  std::uint64_t next_render_recovery_completion_token_ = 0;
  std::uint64_t next_startup_playback_sync_token_ = 0;
  std::uint64_t last_reported_render_failure_stamp_ = 0;
  std::int64_t active_event_playlist_entry_id_ = -1;
  std::int64_t terminal_playlist_entry_id_ = -1;
  std::int64_t last_error_playlist_entry_id_ = -1;
  std::int64_t selected_video_track_id_ = -1;
  std::int64_t selected_audio_track_id_ = -1;
  std::int64_t selected_subtitle_track_id_ = -1;
  std::int64_t selected_tracks_playlist_entry_id_ = -1;
  std::optional<bool> current_file_has_audio_track_;
  std::vector<std::filesystem::path> attached_subtitle_files_;
  std::vector<PlaylistEntryRange> redirect_ranges_;
  std::optional<OpenAttempt> open_attempt_;
  std::optional<OpenAttempt> committed_open_;
  std::optional<RenderRecovery> render_recovery_;
  std::optional<RenderRecoveryAttempt> render_recovery_attempt_;
  std::optional<StartupPlaybackSync> startup_playback_sync_;
  std::optional<ScrubSeek> scrub_seek_;
  std::optional<NativeScrubIntent> native_scrub_intent_;
  std::optional<NativeSeekIntent> native_seek_intent_;
  NativeSeekSubmissionState *native_seek_submission_ = nullptr;
  std::uint64_t latest_native_seek_submission_request_ = 0;
#if defined(WAM_MPV_RUNTIME_TESTING)
  // The controller-only test target deliberately excludes the platform owner.
  // This seam lets it exercise the public previewSeekTo boundary while keeping
  // production object layout and dispatch unchanged.
  void *native_preview_test_submit_context_ = nullptr;
  NativePreviewSubmitter native_preview_test_submitter_ = nullptr;
  void *native_preview_test_demand_context_ = nullptr;
  NativePreviewDemandObserver native_preview_test_demand_observer_ = nullptr;
#endif
};

} // namespace wam::qt
