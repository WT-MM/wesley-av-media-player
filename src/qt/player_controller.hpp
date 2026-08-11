#pragma once

#include "caption_service.hpp"
#include "jobs.hpp"

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
class PlayerCore;
class PlayerControllerTestAccess;

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
  Q_PROPERTY(double trimIn READ trimIn WRITE setTrimIn NOTIFY trimInChanged)
  Q_PROPERTY(double trimOut READ trimOut WRITE setTrimOut NOTIFY trimOutChanged)
  Q_PROPERTY(bool exporting READ exporting NOTIFY exportingChanged)
  Q_PROPERTY(QString exportStatus READ exportStatus NOTIFY exportStatusChanged)
  Q_PROPERTY(bool captioning READ captioning NOTIFY captioningChanged)
  Q_PROPERTY(
      QString captionStatus READ captionStatus NOTIFY captionStatusChanged)
  Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)

public:
  explicit PlayerController(QObject *parent = nullptr);
  ~PlayerController() override;

  PlayerController(const PlayerController &) = delete;
  PlayerController &operator=(const PlayerController &) = delete;

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
  [[nodiscard]] double trimIn() const { return trim_in_; }
  [[nodiscard]] double trimOut() const { return trim_out_; }
  [[nodiscard]] bool exporting() const { return exporting_; }
  [[nodiscard]] QString exportStatus() const { return export_status_; }
  [[nodiscard]] bool captioning() const { return captioning_; }
  [[nodiscard]] QString captionStatus() const { return caption_status_; }
  [[nodiscard]] QString lastError() const { return last_error_; }

  void setSource(const QUrl &source);

  Q_INVOKABLE void openFileDialog();
  Q_INVOKABLE bool open(const QUrl &source);
  Q_INVOKABLE void play();
  Q_INVOKABLE void pause();
  Q_INVOKABLE void togglePlayPause();
  Q_INVOKABLE void stop();
  Q_INVOKABLE void seekTo(double seconds);
  Q_INVOKABLE void previewSeekTo(double seconds);
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
  Q_INVOKABLE void setTrimIn(double seconds);
  Q_INVOKABLE void setTrimOut(double seconds);
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
  void trimInChanged();
  void trimOutChanged();
  void exportingChanged();
  void exportStatusChanged();
  void captioningChanged();
  void captionStatusChanged();
  void lastErrorChanged();

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
  friend class PlayerControllerTestAccess;

  struct OpenAttempt {
    std::uint64_t id = 0;
    std::uint64_t request_serial = 0;
    std::uint64_t render_stamp = 0;
    std::int64_t playlist_entry_id = -1;
  };

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
  void handleStartFile(std::int64_t playlist_entry_id);
  void handleEndFile(const mpv_event_end_file &end);
  void handlePlaybackReady(bool file_loaded);
  void restoreRenderRecovery();
  void queueRenderRecoveryCompletion();
  void finishRenderRecoveryCompletion(std::uint64_t completion_token,
                                      std::uint64_t request_serial,
                                      std::uint64_t render_stamp,
                                      std::int64_t playlist_entry_id);
  [[nodiscard]] std::optional<LivePlaybackState>
  readLivePlaybackState() const;
  [[nodiscard]] static bool livePlaybackStateMatchesRecovery(
      const RenderRecovery &recovery,
      const LivePlaybackState &live_state);
  [[nodiscard]] static bool livePlaybackStateMatchesStartupSync(
      const StartupPlaybackSync &startup_sync,
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
  [[nodiscard]] static std::int64_t authoritativePlaylistEntry(
      std::int64_t live_entry, std::int64_t captured_start_entry);
  [[nodiscard]] bool acceptsPlaybackObservation() const;
  [[nodiscard]] bool playlistEntryBelongsToCurrentLineage(
      std::int64_t playlist_entry_id) const;
  [[nodiscard]] bool engineReady() const;
  [[nodiscard]] bool needsRenderContext() const;
  bool initializePlaybackEngine();
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
  void setExportStatus(const QString &status);
  void cleanupExportStaging() noexcept;
  void startWorkPolling();
  void pollBackgroundWork();
  bool attachSubtitleFile(const std::filesystem::path &subtitle);

  std::shared_ptr<PlayerCore> core_;
  QPointer<MpvVideoItem> video_item_;
  QTimer *work_timer_ = nullptr;

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
  QString last_error_;
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
};

} // namespace wam::qt
