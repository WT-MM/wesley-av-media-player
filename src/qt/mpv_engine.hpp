#pragma once

#include "playback_policy.hpp"
#include "native_playback_metrics.hpp"

#include <QString>
#include <QUrl>

#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <vector>

namespace wam::playback::mpv {
class MpvRuntime;
}

namespace wam::qt {

class PlayerController;
class PlayerCore;

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

  explicit MpvEngine(PlayerController *owner);
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

  void detachOwner();

  std::shared_ptr<PlayerCore> core;
  Lineage lineage;

private:
  PlayerController *owner_;
  std::shared_ptr<const ::wam::playback::mpv::MpvRuntime> runtime_;
  std::shared_ptr<PlayerCore> replacement_;
};

} // namespace wam::qt
