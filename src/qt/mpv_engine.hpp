#pragma once

#include "playback_policy.hpp"
#include "native_playback_metrics.hpp"

#include <QByteArray>
#include <QSize>
#include <QString>
#include <QUrl>

#include <mpv/client.h>

#include <cmath>
#include <cstdint>
#include <filesystem>
#include <initializer_list>
#include <memory>
#include <optional>
#include <vector>

namespace wam::playback::mpv {
class MpvRuntime;
}

class QTimer;

namespace wam::qt {

class PlayerController;
class PlayerControllerTestAccess;
class PlayerCore;

struct MpvTransport {
  bool paused = true;
  bool idle = true;
  bool eof_reached = false;
  double position = 0.0;
};

struct MpvTransportChange {
  bool paused_changed = false;
  bool position_changed = false;
  bool was_playing = false;
};

// What MpvEngine may do to its PlayerController: read the controller's
// request lineage and publish what the compatibility engine observed. This is
// the engine's whole surface toward the controller.
class MpvEngineHost {
public:
  // The authoritative open intent: the serial of the latest request and its
  // source (empty after a stop).
  [[nodiscard]] virtual std::uint64_t requestSerial() const = 0;
  [[nodiscard]] virtual QUrl requestedSource() const = 0;

  [[nodiscard]] virtual bool paused() const = 0;
  [[nodiscard]] virtual double position() const = 0;
  [[nodiscard]] virtual bool eofReached() const = 0;

  virtual void updatePause(bool paused) = 0;
  virtual void updateIdle(bool idle) = 0;
  virtual void updateEof(bool eof_reached) = 0;
  virtual void updateDuration(double duration) = 0;
  virtual void updatePosition(double position) = 0;
  virtual void setLastError(const QString &error) = 0;
  // A transport snapshot assigned in one step while the engine still gates
  // observations, then announced: no signal handler sees half of it.
  [[nodiscard]] virtual MpvTransportChange
  assignTransport(const MpvTransport &transport) = 0;
  virtual void publishTransport(const MpvTransportChange &change) = 0;
  // Tells the native router the fallback render state moved.
  virtual void fallbackRenderStateChanged() = 0;

  [[nodiscard]] virtual QUrl source() const = 0;
  virtual void setRequestedSource(const QUrl &source) = 0;
  virtual void updateLoading(bool loading) = 0;
  virtual void updateSource(const QUrl &source) = 0;
  virtual void updateMediaTitle(const QString &title) = 0;
  // Forgets the previous file's timeline (position, duration, size, trims).
  virtual void resetTimeline() = 0;
  virtual void refreshSubtitleSources() = 0;
  virtual void requestVideoUpdate() = 0;

  // The native router's half of a routed fallback open, and how a fallback
  // failure is worded and reported to it. No-ops without a native engine.
  [[nodiscard]] virtual bool hasNativeEngine() const = 0;
  virtual void fallbackOpenSucceeded(std::uint64_t attempt, std::uint64_t serial,
                                     std::uint64_t source_key) = 0;
  virtual void fallbackOpenFailed(std::uint64_t attempt, std::uint64_t serial,
                                  std::uint64_t source_key) = 0;
  [[nodiscard]] virtual QString
  playbackFailureText(const QString &fallback) const = 0;
  virtual void fallbackPlaybackFailed() = 0;

  // Event handling still on the controller.
  virtual void drainMpvEvents() = 0;
  virtual void applyObservedVideoFacts() = 0;

protected:
  ~MpvEngineHost() = default;
};

[[nodiscard]] inline bool nearlyEqual(double left, double right,
                                      double epsilon = 0.0005) {
  return std::abs(left - right) <= epsilon;
}

// How a source is handed to mpv's loadfile, and the URL it is shown as.
[[nodiscard]] QString sourceArgument(const QUrl &source);
[[nodiscard]] QUrl displayUrlForSource(const QUrl &source);
[[nodiscard]] QString sourceIdentity(const QUrl &source);
[[nodiscard]] QString displayPath(const std::filesystem::path &path);
// The title shown for a source mpv has not named.
[[nodiscard]] QString fallbackTitle(const QUrl &source);
// Probes a local mount synchronously: only for builds with no native engine,
// whose open preflight classifies off the GUI thread instead.
[[nodiscard]] PlaybackSourceClass playbackSourceClass(const QUrl &source);

// mpv's `path` (and playlist filename) as a URL: local paths become file URLs.
[[nodiscard]] QUrl urlFromMpvPath(const QString &path);
// mpv's vid/aid/sid text as a selection: 0 for "no", the track id, or -1 when
// it states neither.
[[nodiscard]] std::int64_t parseTrackSelection(const QString &text);

// mpv echoes a command's 64-bit reply_userdata back with its reply. The top
// bits name the protocol that issued the command and the rest is that
// protocol's command id, so a reply can never be taken for another
// protocol's. Every asynchronous command this window issues is tagged here.
enum class MpvReply : std::uint8_t {
  Untagged,
  Open,
  Scrub,
  RenderRecovery,
  FallbackStop,
};

struct MpvReplyTag {
  MpvReply kind = MpvReply::Untagged;
  std::uint64_t id = 0;
};

[[nodiscard]] constexpr std::uint64_t mpvReplyIdMask(MpvReply kind) noexcept {
  return kind == MpvReply::Open || kind == MpvReply::Scrub
             ? (1ULL << 61) - 1ULL
             : (1ULL << 62) - 1ULL;
}

[[nodiscard]] constexpr std::uint64_t mpvReplyTagBits(MpvReply kind) noexcept {
  switch (kind) {
  case MpvReply::Open:
    return 1ULL << 63;
  case MpvReply::Scrub:
    return (1ULL << 63) | (1ULL << 61);
  case MpvReply::RenderRecovery:
    return 1ULL << 62;
  case MpvReply::FallbackStop:
    return 3ULL << 62;
  case MpvReply::Untagged:
    break;
  }
  return 0;
}

[[nodiscard]] constexpr std::uint64_t mpvReplyUserdata(MpvReply kind,
                                                       std::uint64_t id) noexcept {
  return mpvReplyTagBits(kind) | (id & mpvReplyIdMask(kind));
}

[[nodiscard]] constexpr MpvReplyTag parseMpvReply(std::uint64_t userdata) noexcept {
  for (const MpvReply kind : {MpvReply::Open, MpvReply::Scrub,
                              MpvReply::RenderRecovery, MpvReply::FallbackStop}) {
    const std::uint64_t mask = mpvReplyIdMask(kind);
    if ((userdata & ~mask) == mpvReplyTagBits(kind))
      return {kind, userdata & mask};
  }
  return {MpvReply::Untagged, userdata};
}

// Advances `counter` to the next nonzero id `kind` can carry and returns it.
[[nodiscard]] constexpr std::uint64_t nextMpvReplyId(MpvReply kind,
                                                     std::uint64_t &counter) noexcept {
  counter = (counter + 1) & mpvReplyIdMask(kind);
  if (counter == 0)
    counter = 1;
  return counter;
}

static_assert([] {
  for (const MpvReply kind : {MpvReply::Open, MpvReply::Scrub,
                              MpvReply::RenderRecovery, MpvReply::FallbackStop}) {
    for (const std::uint64_t id : {1ULL, mpvReplyIdMask(kind)}) {
      const MpvReplyTag tag = parseMpvReply(mpvReplyUserdata(kind, id));
      if (tag.kind != kind || tag.id != id)
        return false;
    }
  }
  return parseMpvReply(0).kind == MpvReply::Untagged;
}());

// The compatibility (libmpv) engine of one window: its PlayerCore, the
// runtime it is provisioned with, and the state of the file lineage it is
// playing. PlayerController drives it; on macOS the playback router also
// commands it through the typed operations below, so nothing outside this
// class touches the mpv handle of a router-owned stop or pause.
class MpvEngine final {
public:
  struct OpenAttempt {
    std::uint64_t id = 0;
    std::uint64_t request_serial = 0;
    std::uint64_t render_stamp = 0;
    std::int64_t playlist_entry_id = -1;
    bool reply_ready = false;
    bool file_loaded = false;
    bool playback_restarted = false;
  };

  // The router's identity for an open it handed to this engine.
  struct RoutedFallbackOpen {
    std::uint64_t attempt = 0;
    std::uint64_t serial = 0;
    std::uint64_t source_key = 0;
    PlaybackSourceClass source_class{PlaybackSourceClass::Network};
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

    // Three restarts, each clearing exactly the progress its event voids.
    // A second render-context loss: re-run the restore from the top, with
    // the captured position and its override kept.
    void restartForNewRenderContext();
    // A video reselect whose entry then failed: reload the file instead,
    // keeping the captured per-file state and the retry budget.
    void escalateToFullReload();
    // The reload started a different playlist entry (a redirect child):
    // its position and track snapshot are no longer this recovery's.
    void restartForNewPlaylistEntry();
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

  // Everything that belongs to the file this engine is playing or about to
  // play. A new routed open, a stop, a failed initialization and a core
  // replacement all start a new lineage with `lineage = {}`.
  struct Lineage {
    QUrl pending_source;
    std::uint64_t pending_request_serial = 0;
    std::optional<OpenAttempt> open_attempt;
    std::optional<OpenAttempt> committed_open;
    QUrl committed_entry_source;
    std::int64_t committed_playlist_position = -1;
    std::optional<RenderRecovery> render_recovery;
    std::optional<RenderRecoveryAttempt> render_recovery_attempt;
    std::optional<StartupPlaybackSync> startup_playback_sync;
    std::optional<RoutedFallbackOpen> routed_fallback_open;
    std::vector<PlaylistEntryRange> redirect_ranges;
    bool observed_current_path = false;
    std::int64_t active_event_playlist_entry_id = -1;
    std::int64_t terminal_playlist_entry_id = -1;
    std::int64_t last_error_playlist_entry_id = -1;
    std::uint64_t last_reported_render_failure_stamp = 0;
    std::int64_t selected_video_track_id = -1;
    std::int64_t selected_audio_track_id = -1;
    std::int64_t selected_subtitle_track_id = -1;
    std::int64_t selected_tracks_playlist_entry_id = -1;
    std::optional<bool> current_file_has_audio_track;
    std::vector<std::filesystem::path> attached_subtitle_files;
  };

  MpvEngine(PlayerController *owner, MpvEngineHost &host);
  ~MpvEngine();

  MpvEngine(const MpvEngine &) = delete;
  MpvEngine &operator=(const MpvEngine &) = delete;

  [[nodiscard]] bool ready() const;

  // Provisioning retains an already validated runtime but creates no mpv
  // handle; initialize() consumes it. provisionRuntime() loads this
  // platform's runtime (the validated bundled fallback on Apple, the linked
  // libmpv elsewhere) unless one is already provisioned, and returns the
  // user-facing failure, or an empty string.
  [[nodiscard]] bool provision(
      std::shared_ptr<const ::wam::playback::mpv::MpvRuntime> runtime);
  [[nodiscard]] bool provisioned() const noexcept { return runtime_ != nullptr; }
  [[nodiscard]] QString provisionRuntime();
  [[nodiscard]] bool initialize();

  // Reserves the replacement core a terminal retirement swaps in, so
  // retirement needs no allocation once a handle exists. False when the
  // allocation failed.
  [[nodiscard]] bool reserveReplacement();
  // GUI-thread terminal recovery, admitted only once rendering has released
  // `expected` (the current core): retires it, installs the reserved
  // replacement and starts a new lineage.
  [[nodiscard]] bool replaceAfterRenderRelease(
      const std::shared_ptr<PlayerCore> &expected);

  // Synchronous commands for the playback router.
  [[nodiscard]] bool setPausedNow(bool paused);
  [[nodiscard]] bool submitStop(std::uint64_t reply_userdata);
  [[nodiscard]] bool idle() const;
  // Revokes rendering permission (re-arming a failed generation so the
  // revocation can complete) ahead of a stop.
  void revokeRendering();
  // True once no render context is busy and the lifecycle is Empty.
  [[nodiscard]] bool renderingReleased() const;
  [[nodiscard]] NativePlaybackMetricsSample metrics() const;

  // The one way to talk to the mpv handle. Every call is a no-op (or empty
  // answer) until the core is ready; setters warn on failure.
  [[nodiscard]] QString mpvErrorDetail(int error) const;
  [[nodiscard]] std::optional<std::int64_t> intProperty(const char *name) const;
  [[nodiscard]] std::optional<double> doubleProperty(const char *name) const;
  [[nodiscard]] std::optional<bool> flagProperty(const char *name) const;
  [[nodiscard]] std::optional<QString> stringProperty(const char *name) const;
  bool setCoreProperty(const char *name, mpv_format format, void *value);
  void setPropertyAsync(const char *name, mpv_format format, void *value);
  // Synchronous command; returns mpv's status.
  int commandNow(const char **arguments);
  void abortCommand(std::uint64_t reply_userdata);
  bool setPlaybackProperty(const char *name, const char *value);
  void applyPlaybackBufferPolicy(PlaybackSourceClass source_class);
  // A track selection: 0 deselects, a negative value leaves it alone.
  bool setTrackSelection(const char *name, std::int64_t selection);
  int sendCommand(const std::initializer_list<QByteArray> &arguments,
                  std::uint64_t reply_userdata = 0);

  [[nodiscard]] std::int64_t playlistEntryIdAtPosition(
      const char *position_property) const;
  [[nodiscard]] std::int64_t currentPlaylistEntryId() const;
  [[nodiscard]] std::int64_t playingPlaylistEntryId() const;
  [[nodiscard]] std::int64_t playlistEntryCount() const;
  [[nodiscard]] std::int64_t playlistPositionForEntry(std::int64_t entry_id) const;
  [[nodiscard]] QUrl playlistEntrySource(std::int64_t entry_id) const;
  // vid/aid/sid as a positive track id, or -1.
  [[nodiscard]] std::int64_t currentTrackId(const char *name) const;
  // parseTrackSelection of the live vid/aid/sid.
  [[nodiscard]] std::int64_t currentTrackSelection(const char *name) const;
  [[nodiscard]] QSize currentVideoDisplaySize() const;
  [[nodiscard]] std::optional<bool> currentFileHasTrackType(const char *type) const;

  void detachOwner();

  // --- Observation gate -------------------------------------------------
  // True when an mpv property event describes the committed file of the
  // current request, with no open, scrub, recovery or startup sync in flight.
  [[nodiscard]] bool acceptsPlaybackObservation() const;

  // --- Scrub (pointer gesture on this engine) ----------------------------
  // A capacity-one seek pipeline: keyframe previews while dragging, one exact
  // seek on release, then the captured pause intent is restored.
  [[nodiscard]] bool scrubbing() const noexcept { return scrub_seek_.has_value(); }
  void beginScrub(double position);
  void previewScrub(double target);
  // False when no gesture is open (the caller seeks instead). `valid` false
  // ends the gesture without a seek.
  [[nodiscard]] bool endScrub(double target, bool valid);
  void setScrubIntendedPaused(bool paused);
  void noteSeekStarted();
  // Feeds an observed time-pos to an open gesture; false when none is open.
  [[nodiscard]] bool observeScrubPosition(double position);
  void handleScrubCommandReply(std::uint64_t command, int error);
  void handleScrubPlaybackRestart();
  void finishScrubGesture(bool restore_transport);
  void invalidateScrubGesture();

  // --- Open lineage ------------------------------------------------------
  // A pending open is flushed as one loadfile once rendering is ready; its
  // reply, START_FILE/END_FILE and FILE_LOADED/PLAYBACK_RESTART commit it.
  void continuePendingOpen();
  bool flushPendingOpen(std::uint64_t render_stamp);
  // Each takes the command id parseMpvReply extracted for its protocol.
  void observeOpenCommandReply(std::uint64_t attempt_id, int error);
  void handleOpenCommandReply(std::uint64_t attempt_id, int error);
  [[nodiscard]] bool
  playlistEntryBelongsToCurrentLineage(std::int64_t playlist_entry_id) const;
  void handleStartFile(std::int64_t playlist_entry_id);
  void handleEndFile(const mpv_event_end_file &end);
  void handlePlaybackReady(bool file_loaded);
  void abandonPendingOpen();
  void cacheCurrentTrackSelection();
  void cacheCurrentEntrySource();
  void notifyRoutedFallbackOpenFailed();

  // --- Render recovery and startup sync --------------------------------
  // A lost render context reloads (or reselects) the committed file and
  // restores its per-file state and transport before observations resume.
  struct LivePlaybackState {
    bool paused = true;
    bool idle = true;
    std::optional<bool> eof_reached;
    std::optional<double> position;
    std::optional<double> duration;
  };
  bool flushRenderRecovery(std::uint64_t render_stamp);
  void handleRenderRecoveryCommandReply(std::uint64_t attempt_id, int error);
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
  void handleRenderInvalidated(std::uint64_t retired_render_stamp);
  void handleRenderInitializationFailure(const QString &error,
                                         std::uint64_t render_stamp);
  [[nodiscard]] static std::int64_t
  authoritativePlaylistEntry(std::int64_t live_entry,
                             std::int64_t captured_start_entry);

  std::shared_ptr<PlayerCore> core;
  Lineage lineage;

private:
  friend class PlayerControllerTestAccess;

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

  void dispatchScrubSeek(double target, bool exact);
  void maybeCompleteScrubSeek();
  [[nodiscard]] static const char *scrubSeekMode(bool exact);
  void armScrubTimeout(std::uint64_t gesture, std::uint64_t request_serial,
                       std::uint64_t command);
  void cancelScrubTimeout();
  void handleScrubTimeout(std::uint64_t gesture, std::uint64_t request_serial,
                          std::uint64_t command);

  PlayerController *owner_;
  MpvEngineHost &host_;
  std::optional<ScrubSeek> scrub_seek_;
  std::uint64_t next_scrub_gesture_id_ = 0;
  std::uint64_t next_scrub_command_id_ = 0;
  std::uint64_t next_open_attempt_id_ = 0;
  std::uint64_t next_render_recovery_attempt_id_ = 0;
  std::uint64_t next_render_recovery_completion_token_ = 0;
  std::uint64_t next_startup_playback_sync_token_ = 0;
  QTimer *scrub_timeout_timer_ = nullptr;
  std::uint64_t scrub_timeout_gesture_ = 0;
  std::uint64_t scrub_timeout_request_serial_ = 0;
  std::uint64_t scrub_timeout_command_ = 0;
  std::shared_ptr<const ::wam::playback::mpv::MpvRuntime> runtime_;
  std::shared_ptr<PlayerCore> replacement_;
};

} // namespace wam::qt
