#include "player_controller.hpp"

#include "mpv_video_item.hpp"
#include "playback_policy.hpp"
#include "player_core_p.hpp"

#include <QByteArray>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStorageInfo>
#include <QTimer>

#include <algorithm>
#include <array>
#include <cmath>
#include <cwctype>
#include <exception>
#include <filesystem>
#include <optional>

#ifdef Q_OS_WIN
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

#ifdef Q_OS_MACOS
#include <sys/mount.h>
#endif

namespace wam::qt {
namespace {

constexpr double kMinimumRate = 0.0625;
constexpr double kMaximumRate = 16.0;
constexpr std::uint64_t kCommandReplyNamespaceMask = 3ULL << 62;
constexpr std::uint64_t kOpenCommandReplyNamespace = 1ULL << 63;
constexpr std::uint64_t kRenderRecoveryCommandReplyNamespace = 1ULL << 62;
constexpr std::uint64_t kCommandReplyIdMask = ~kCommandReplyNamespaceMask;

bool nearlyEqual(double left, double right, double epsilon = 0.0005) {
  return std::abs(left - right) <= epsilon;
}

QString sourceArgument(const QUrl &source) {
  if (source.isLocalFile())
    return source.toLocalFile();
  if (source.scheme().isEmpty())
    return source.toString();
  return source.toString(QUrl::FullyEncoded);
}

QUrl displayUrlForSource(const QUrl &source) {
  if (source.isLocalFile() || !source.scheme().isEmpty())
    return source;
  return QUrl::fromLocalFile(QFileInfo(source.toString()).absoluteFilePath());
}

QString sourceIdentity(const QUrl &source) {
  return sourceArgument(displayUrlForSource(source));
}

QUrl urlFromMpvPath(const QString &path) {
  if (path.isEmpty())
    return {};
#ifdef Q_OS_WIN
  // QUrl parses a drive letter as a URL scheme (for example, `C:` becomes
  // scheme `c`). mpv's `path` property uses native paths for local media.
  if (QDir::isAbsolutePath(path) || path.startsWith(QStringLiteral("\\\\")) ||
      path.startsWith(QStringLiteral("//"))) {
    return QUrl::fromLocalFile(path);
  }
#endif
  const QUrl parsed(path);
  if (!parsed.scheme().isEmpty())
    return parsed;
  return QUrl::fromLocalFile(path);
}

QString fallbackTitle(const QUrl &source) {
  if (source.isLocalFile())
    return QFileInfo(source.toLocalFile()).fileName();
  const QString file_name = source.fileName();
  return file_name.isEmpty() ? source.host() : file_name;
}

PlaybackSourceClass playbackSourceClass(const QUrl &source) {
  if (!source.isLocalFile())
    return PlaybackSourceClass::Network;

  const QString local_path = source.toLocalFile();
  const QStorageInfo storage(local_path);
  if (storage.isValid() &&
      isRemoteFilesystemType(storage.fileSystemType().toStdString())) {
    return PlaybackSourceClass::BufferedLocal;
  }

#ifdef Q_OS_MACOS
  struct statfs mount_information{};
  const QByteArray encoded_path = QFile::encodeName(local_path);
  if (::statfs(encoded_path.constData(), &mount_information) == 0 &&
      (mount_information.f_flags & MNT_LOCAL) == 0) {
    return PlaybackSourceClass::BufferedLocal;
  }
#endif

#ifdef Q_OS_WIN
  // A mapped drive can report the server's ordinary on-disk filesystem type,
  // so Windows' drive classification is the authoritative second check.
  const QString root = storage.isValid() ? storage.rootPath()
                                         : QFileInfo(local_path).absolutePath();
  const UINT drive_type = GetDriveTypeW(
      reinterpret_cast<LPCWSTR>(QDir::toNativeSeparators(root).utf16()));
  if (drive_type == DRIVE_REMOTE || drive_type == DRIVE_REMOVABLE ||
      drive_type == DRIVE_CDROM) {
    return PlaybackSourceClass::BufferedLocal;
  }
#endif

  return PlaybackSourceClass::FastLocal;
}

bool setPlaybackProperty(mpv_handle *handle, const char *name,
                         const char *value) {
  const int result = mpv_set_property_string(handle, name, value);
  if (result >= 0)
    return true;
  qWarning().nospace() << "WAM: unable to set playback policy property " << name
                       << '=' << value << ": " << mpv_error_string(result);
  return false;
}

void applyPlaybackBufferPolicy(mpv_handle *handle,
                               PlaybackSourceClass source_class) {
  const PlaybackBufferPolicy policy = playbackBufferPolicy(source_class);
  setPlaybackProperty(handle, "cache", policy.cache_mode);
  setPlaybackProperty(handle, "cache-secs", policy.cache_seconds);
  setPlaybackProperty(handle, "demuxer-readahead-secs",
                      policy.readahead_seconds);
  setPlaybackProperty(handle, "demuxer-max-bytes", policy.forward_bytes);
  setPlaybackProperty(handle, "demuxer-max-back-bytes", policy.backward_bytes);
  setPlaybackProperty(handle, "demuxer-hysteresis-secs",
                      policy.hysteresis_seconds);
}

std::filesystem::path filesystemPath(const QString &path) {
#ifdef _WIN32
  return std::filesystem::path(path.toStdWString());
#else
  const QByteArray encoded = QFile::encodeName(path);
  return std::filesystem::path(encoded.constData());
#endif
}

QString displayPath(const std::filesystem::path &path) {
#ifdef _WIN32
  return QString::fromStdWString(path.wstring());
#else
  return QFile::decodeName(path.string().c_str());
#endif
}

QString fromUtf8(const std::string &text) {
  return QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()));
}

std::optional<std::filesystem::path> localPath(const QUrl &url) {
  if (!url.isLocalFile())
    return std::nullopt;
  const QString path = url.toLocalFile();
  if (path.isEmpty())
    return std::nullopt;
  return filesystemPath(path);
}

bool pathsReferToSameFile(const std::filesystem::path &left,
                          const std::filesystem::path &right) {
  if (left.empty() || right.empty())
    return false;

  std::error_code error;
  if (std::filesystem::equivalent(left, right, error))
    return true;

  error.clear();
  const auto canonical_left = std::filesystem::weakly_canonical(left, error);
  if (error)
    return false;
  error.clear();
  const auto canonical_right = std::filesystem::weakly_canonical(right, error);
  if (error)
    return false;

#ifdef _WIN32
  auto folded_left = canonical_left.native();
  auto folded_right = canonical_right.native();
  std::transform(
      folded_left.begin(), folded_left.end(), folded_left.begin(),
      [](wchar_t value) { return static_cast<wchar_t>(std::towlower(value)); });
  std::transform(
      folded_right.begin(), folded_right.end(), folded_right.begin(),
      [](wchar_t value) { return static_cast<wchar_t>(std::towlower(value)); });
  return folded_left == folded_right;
#else
  return canonical_left == canonical_right;
#endif
}

int sendCommand(mpv_handle *handle,
                const std::initializer_list<QByteArray> &arguments,
                std::uint64_t reply_userdata = 0) {
  if (!handle || arguments.size() == 0)
    return MPV_ERROR_INVALID_PARAMETER;
  std::vector<const char *> argv;
  argv.reserve(arguments.size() + 1);
  for (const QByteArray &argument : arguments)
    argv.push_back(argument.constData());
  argv.push_back(nullptr);
  return mpv_command_async(handle, reply_userdata, argv.data());
}

bool setCoreProperty(mpv_handle *handle, const char *name, mpv_format format,
                     void *value) {
  const int result = mpv_set_property(handle, name, format, value);
  if (result >= 0)
    return true;
  qWarning().nospace() << "WAM: unable to restore media-engine property "
                       << name << ": " << mpv_error_string(result);
  return false;
}

bool setTrackSelection(mpv_handle *handle, const char *name,
                       std::int64_t selection) {
  if (selection < 0)
    return true;
  if (selection == 0) {
    const int result = mpv_set_property_string(handle, name, "no");
    if (result >= 0)
      return true;
    qWarning().nospace() << "WAM: unable to restore media-engine property "
                         << name << "=no: " << mpv_error_string(result);
    return false;
  }
  std::int64_t value = selection;
  return setCoreProperty(handle, name, MPV_FORMAT_INT64, &value);
}

std::int64_t playlistEntryIdAtPosition(mpv_handle *handle,
                                       const char *position_property) {
  std::int64_t playlist_position = -1;
  std::int64_t entry_id = -1;
  if (!handle ||
      mpv_get_property(handle, position_property, MPV_FORMAT_INT64,
                       &playlist_position) < 0 ||
      playlist_position < 0) {
    return -1;
  }
  const QByteArray property =
      QByteArrayLiteral("playlist/") + QByteArray::number(playlist_position) +
      QByteArrayLiteral("/id");
  if (mpv_get_property(handle, property.constData(), MPV_FORMAT_INT64,
                       &entry_id) < 0) {
    return -1;
  }
  return entry_id;
}

std::int64_t currentPlaylistEntryId(mpv_handle *handle) {
  return playlistEntryIdAtPosition(handle, "playlist-pos");
}

std::int64_t playingPlaylistEntryId(mpv_handle *handle) {
  return playlistEntryIdAtPosition(handle, "playlist-playing-pos");
}

std::int64_t playlistEntryCount(mpv_handle *handle) {
  std::int64_t count = 0;
  if (!handle ||
      mpv_get_property(handle, "playlist/count", MPV_FORMAT_INT64, &count) <
          0) {
    return 0;
  }
  return std::max<std::int64_t>(0, count);
}

std::int64_t playlistPositionForEntry(mpv_handle *handle,
                                      std::int64_t entry_id) {
  const std::int64_t count = playlistEntryCount(handle);
  if (entry_id < 0)
    return -1;
  for (std::int64_t index = 0; index < count; ++index) {
    const QByteArray property =
        QByteArrayLiteral("playlist/") + QByteArray::number(index) +
        QByteArrayLiteral("/id");
    std::int64_t candidate_id = -1;
    if (mpv_get_property(handle, property.constData(), MPV_FORMAT_INT64,
                         &candidate_id) >= 0 &&
        candidate_id == entry_id) {
      return index;
    }
  }
  return -1;
}

QUrl playlistEntrySource(mpv_handle *handle, std::int64_t entry_id) {
  const std::int64_t count = playlistEntryCount(handle);
  if (!handle || entry_id < 0) {
    return {};
  }
  for (std::int64_t index = 0; index < count; ++index) {
    const QByteArray prefix =
        QByteArrayLiteral("playlist/") + QByteArray::number(index);
    const QByteArray id_property = prefix + QByteArrayLiteral("/id");
    std::int64_t candidate_id = -1;
    if (mpv_get_property(handle, id_property.constData(), MPV_FORMAT_INT64,
                         &candidate_id) < 0 ||
        candidate_id != entry_id) {
      continue;
    }
    const QByteArray filename_property =
        prefix + QByteArrayLiteral("/filename");
    char *filename =
        mpv_get_property_string(handle, filename_property.constData());
    if (!filename)
      return {};
    const QUrl source = urlFromMpvPath(QString::fromUtf8(filename));
    mpv_free(filename);
    return source;
  }
  return {};
}

std::int64_t currentVideoTrackId(mpv_handle *handle) {
  std::int64_t track_id = -1;
  if (!handle ||
      mpv_get_property(handle, "vid", MPV_FORMAT_INT64, &track_id) < 0 ||
      track_id <= 0) {
    return -1;
  }
  return track_id;
}

std::int64_t currentTrackId(mpv_handle *handle, const char *name) {
  std::int64_t track_id = -1;
  if (!handle ||
      mpv_get_property(handle, name, MPV_FORMAT_INT64, &track_id) < 0 ||
      track_id <= 0) {
    return -1;
  }
  return track_id;
}

std::int64_t currentTrackSelection(mpv_handle *handle, const char *name) {
  if (!handle)
    return -1;
  char *selection = mpv_get_property_string(handle, name);
  if (!selection)
    return -1;
  const QString value = QString::fromUtf8(selection).trimmed();
  mpv_free(selection);
  if (value.compare(QStringLiteral("no"), Qt::CaseInsensitive) == 0)
    return 0;
  bool valid = false;
  const qlonglong numeric = value.toLongLong(&valid);
  return valid && numeric > 0 ? static_cast<std::int64_t>(numeric) : -1;
}

std::optional<bool> currentFileHasTrackType(mpv_handle *handle,
                                            const char *type) {
  std::int64_t count = 0;
  if (!handle ||
      mpv_get_property(handle, "track-list/count", MPV_FORMAT_INT64, &count) <
          0 ||
      count <= 0) {
    return std::nullopt;
  }
  for (std::int64_t index = 0; index < count; ++index) {
    const QByteArray property =
        QByteArrayLiteral("track-list/") + QByteArray::number(index) +
        QByteArrayLiteral("/type");
    char *track_type = mpv_get_property_string(handle, property.constData());
    if (!track_type)
      continue;
    const bool matches = QByteArray(track_type) == type;
    mpv_free(track_type);
    if (matches)
      return true;
  }
  return false;
}

bool readFlag(const mpv_event_property *property, bool fallback) {
  return property && property->format == MPV_FORMAT_FLAG && property->data
             ? *static_cast<int *>(property->data) != 0
             : fallback;
}

double readDouble(const mpv_event_property *property, double fallback) {
  if (!property || property->format != MPV_FORMAT_DOUBLE || !property->data)
    return fallback;
  const double value = *static_cast<double *>(property->data);
  return std::isfinite(value) ? value : fallback;
}

QString readString(const mpv_event_property *property) {
  if (!property || property->format != MPV_FORMAT_STRING || !property->data)
    return {};
  const char *value = *static_cast<char **>(property->data);
  return value ? QString::fromUtf8(value) : QString{};
}

std::int64_t readTrackSelection(const mpv_event_property *property) {
  const QString value = readString(property).trimmed();
  if (value.compare(QStringLiteral("no"), Qt::CaseInsensitive) == 0)
    return 0;
  bool valid = false;
  const qlonglong numeric = value.toLongLong(&valid);
  return valid && numeric > 0 ? static_cast<std::int64_t>(numeric) : -1;
}

} // namespace

PlayerController::PlayerController(QObject *parent)
    : QObject(parent), core_(std::make_shared<PlayerCore>(this)) {
  work_timer_ = new QTimer(this);
  work_timer_->setInterval(100);
  work_timer_->setTimerType(Qt::CoarseTimer);
  connect(work_timer_, &QTimer::timeout, this,
          &PlayerController::pollBackgroundWork);
}

PlayerController::~PlayerController() {
  if (work_timer_)
    work_timer_->stop();
  export_job_.cancel();
  export_job_.wait();
  cleanupExportStaging();
  caption_service_.cancel();
  caption_service_.wait();
  if (core_)
    core_->detachOwner(this);
  core_.reset();
}

bool PlayerController::available() const { return core_ && !core_->failed(); }

bool PlayerController::engineReady() const {
  return core_ && core_->ready();
}

bool PlayerController::initializePlaybackEngine() {
  if (engineReady())
    return true;
  const bool was_available = available();
  if (!core_ || !core_->initialize()) {
    requested_source_.clear();
    pending_source_.clear();
    committed_entry_source_.clear();
    committed_playlist_position_ = -1;
    pending_request_serial_ = 0;
    open_attempt_.reset();
    committed_open_.reset();
    render_recovery_.reset();
    render_recovery_attempt_.reset();
    startup_playback_sync_.reset();
    redirect_ranges_.clear();
    active_event_playlist_entry_id_ = -1;
    selected_video_track_id_ = -1;
    selected_audio_track_id_ = -1;
    selected_subtitle_track_id_ = -1;
    selected_tracks_playlist_entry_id_ = -1;
    current_file_has_audio_track_.reset();
    attached_subtitle_files_.clear();
    setLastError(core_ ? core_->initializationError()
                       : QStringLiteral("Unable to create the media engine."));
    if (was_available != available())
      emit availableChanged();
    return false;
  }

  mpv_handle *handle = core_->handle();

  // Restore cached UI settings synchronously before observing properties.
  // This prevents mpv's defaults from briefly overwriting the saved state on
  // the first file open.
  double engine_volume = volume_ * 100.0;
  double engine_rate = rate_;
  int engine_muted = muted_ ? 1 : 0;
  int engine_captions = captions_visible_ ? 1 : 0;
  int engine_preserve_pitch = preserve_pitch_ ? 1 : 0;
  setCoreProperty(handle, "volume", MPV_FORMAT_DOUBLE, &engine_volume);
  setCoreProperty(handle, "speed", MPV_FORMAT_DOUBLE, &engine_rate);
  setCoreProperty(handle, "mute", MPV_FORMAT_FLAG, &engine_muted);
  setCoreProperty(handle, "sub-visibility", MPV_FORMAT_FLAG,
                  &engine_captions);
  setCoreProperty(handle, "audio-pitch-correction", MPV_FORMAT_FLAG,
                  &engine_preserve_pitch);

  const auto observe = [handle](ObservedProperty id, const char *name,
                                mpv_format format) {
    mpv_observe_property(handle, static_cast<uint64_t>(id), name, format);
  };
  observe(ObservedProperty::Pause, "pause", MPV_FORMAT_FLAG);
  observe(ObservedProperty::Idle, "idle-active", MPV_FORMAT_FLAG);
  observe(ObservedProperty::Position, "time-pos", MPV_FORMAT_DOUBLE);
  observe(ObservedProperty::Duration, "duration", MPV_FORMAT_DOUBLE);
  observe(ObservedProperty::Volume, "volume", MPV_FORMAT_DOUBLE);
  observe(ObservedProperty::Mute, "mute", MPV_FORMAT_FLAG);
  observe(ObservedProperty::Rate, "speed", MPV_FORMAT_DOUBLE);
  observe(ObservedProperty::CaptionsVisible, "sub-visibility", MPV_FORMAT_FLAG);
  observe(ObservedProperty::Path, "path", MPV_FORMAT_STRING);
  observe(ObservedProperty::MediaTitle, "media-title", MPV_FORMAT_STRING);
  observe(ObservedProperty::PreservePitch, "audio-pitch-correction",
          MPV_FORMAT_FLAG);
  observe(ObservedProperty::EofReached, "eof-reached", MPV_FORMAT_FLAG);
  observe(ObservedProperty::VideoTrack, "vid", MPV_FORMAT_STRING);
  observe(ObservedProperty::AudioTrack, "aid", MPV_FORMAT_STRING);
  observe(ObservedProperty::SubtitleTrack, "sid", MPV_FORMAT_STRING);
  return true;
}

void PlayerController::setSource(const QUrl &source) {
  if (source.isEmpty()) {
    stop();
    return;
  }
  open(source);
}

void PlayerController::openFileDialog() { emit openFileDialogRequested(); }

bool PlayerController::open(const QUrl &source) {
  if (source.isEmpty())
    return false;
  const QString argument = sourceArgument(source);
  if (argument.isEmpty() || !initializePlaybackEngine())
    return false;

  if (captioning_) {
    const auto incoming = localPath(displayUrlForSource(source));
    if (!incoming || caption_input_.empty() ||
        !pathsReferToSameFile(caption_input_, *incoming)) {
      cancelCaptionsForMediaChange();
    }
  }

  updateEof(false);
  resetTimeline();

  // A render context is generation-bound: Qt can tear it down while libmpv's
  // asynchronous loadfile command is queued. Keep the newest intent until a
  // command reply confirms that the same renderer generation is still live.
  ++request_serial_;
  if (request_serial_ == 0)
    ++request_serial_;
  requested_source_ = source;
  pending_source_ = source;
  pending_request_serial_ = request_serial_;
  open_attempt_.reset();
  render_recovery_.reset();
  render_recovery_attempt_.reset();
  startup_playback_sync_.reset();
  observed_current_path_ = false;
  terminal_playlist_entry_id_ = -1;
  last_error_playlist_entry_id_ = -1;

  // A renderer setup failure is latched for its generation. An explicit user
  // open arms exactly one fresh generation; ordinary render passes do not.
  static_cast<void>(core_->retryFailedRenderContext());

  if (const auto ticket = core_->readyRenderTicket())
    return flushPendingOpen(ticket->stamp);

  requestVideoUpdate();
  return true;
}

void PlayerController::play() {
  if (!engineReady())
    return;
  if (eof_reached_ && committed_open_ &&
      terminal_playlist_entry_id_ ==
          committed_open_->playlist_entry_id) {
    active_event_playlist_entry_id_ = terminal_playlist_entry_id_;
    terminal_playlist_entry_id_ = -1;
  }
  if (eof_reached_ || (duration_ > 0.0 && position_ >= duration_ - 0.05))
    seekTo(0.0);
  updateEof(false);
  if (render_recovery_ &&
      render_recovery_->request_serial == request_serial_) {
    render_recovery_->paused = false;
    render_recovery_->transport_restored = false;
  }
  if (startup_playback_sync_ &&
      startup_playback_sync_->request_serial == request_serial_) {
    startup_playback_sync_->intended_paused = false;
  }
  int paused = 0;
  mpv_set_property_async(core_->handle(), 0, "pause", MPV_FORMAT_FLAG, &paused);
  updatePause(false);
}

void PlayerController::pause() {
  if (!engineReady())
    return;
  if (render_recovery_ &&
      render_recovery_->request_serial == request_serial_) {
    if (!render_recovery_->paused &&
        !render_recovery_->position_overridden) {
      double live_position = 0.0;
      if (mpv_get_property(core_->handle(), "time-pos", MPV_FORMAT_DOUBLE,
                           &live_position) >= 0 &&
          std::isfinite(live_position)) {
        render_recovery_->position = std::max(0.0, live_position);
      }
    }
    render_recovery_->paused = true;
    render_recovery_->transport_restored = false;
  }
  if (startup_playback_sync_ &&
      startup_playback_sync_->request_serial == request_serial_) {
    startup_playback_sync_->intended_paused = true;
  }
  int paused = 1;
  mpv_set_property_async(core_->handle(), 0, "pause", MPV_FORMAT_FLAG, &paused);
  updatePause(true);
}

void PlayerController::togglePlayPause() { playing() ? pause() : play(); }

void PlayerController::stop() {
  ++request_serial_;
  if (request_serial_ == 0)
    ++request_serial_;
  requested_source_.clear();
  pending_source_.clear();
  pending_request_serial_ = 0;
  open_attempt_.reset();
  committed_open_.reset();
  committed_entry_source_.clear();
  committed_playlist_position_ = -1;
  render_recovery_.reset();
  render_recovery_attempt_.reset();
  startup_playback_sync_.reset();
  redirect_ranges_.clear();
  active_event_playlist_entry_id_ = -1;
  terminal_playlist_entry_id_ = -1;
  last_error_playlist_entry_id_ = -1;
  selected_video_track_id_ = -1;
  selected_audio_track_id_ = -1;
  selected_subtitle_track_id_ = -1;
  selected_tracks_playlist_entry_id_ = -1;
  current_file_has_audio_track_.reset();
  attached_subtitle_files_.clear();
  observed_current_path_ = false;
  cancelCaptionsForMediaChange();
  if (engineReady())
    sendCommand(core_->handle(), {QByteArrayLiteral("stop")});
  updatePause(true);
  updateIdle(true);
  updateEof(false);
  updateSource({});
  updateMediaTitle({});
  resetTimeline();
  requestVideoUpdate();
}

void PlayerController::seekTo(double seconds) {
  if (!engineReady() || !std::isfinite(seconds))
    return;
  const double maximum = duration_ > 0.0 ? duration_ : seconds;
  const double target = std::clamp(seconds, 0.0, std::max(0.0, maximum));
  if (render_recovery_ &&
      render_recovery_->request_serial == request_serial_) {
    render_recovery_->position = target;
    render_recovery_->transport_restored = false;
    render_recovery_->position_overridden = true;
  }
  if (startup_playback_sync_ &&
      startup_playback_sync_->request_serial == request_serial_) {
    startup_playback_sync_->intended_position = target;
    startup_playback_sync_->position_overridden = true;
  }
  double value = target;
  mpv_set_property_async(core_->handle(), 0, "time-pos", MPV_FORMAT_DOUBLE,
                         &value);
  if (!nearlyEqual(position_, target)) {
    position_ = target;
    emit positionChanged();
  }
}

void PlayerController::previewSeekTo(double seconds) {
  if (!engineReady() || !std::isfinite(seconds))
    return;
  const double maximum = duration_ > 0.0 ? duration_ : seconds;
  const double target = std::clamp(seconds, 0.0, std::max(0.0, maximum));
  if (render_recovery_ &&
      render_recovery_->request_serial == request_serial_) {
    render_recovery_->position = target;
    render_recovery_->transport_restored = false;
    render_recovery_->position_overridden = true;
  }
  if (startup_playback_sync_ &&
      startup_playback_sync_->request_serial == request_serial_) {
    startup_playback_sync_->intended_position = target;
    startup_playback_sync_->position_overridden = true;
  }

  // Timeline dragging favors cheap keyframe previews. The release path uses
  // seekTo(), which performs the exact final seek once per gesture.
  sendCommand(core_->handle(),
              {QByteArrayLiteral("seek"), QByteArray::number(target, 'g', 12),
               QByteArrayLiteral("absolute+keyframes")});
  if (!nearlyEqual(position_, target)) {
    position_ = target;
    emit positionChanged();
  }
}

void PlayerController::seekRelative(double seconds) {
  if (!engineReady() || !std::isfinite(seconds))
    return;
  if (render_recovery_) {
    seekTo(position_ + seconds);
    return;
  }
  sendCommand(core_->handle(),
              {QByteArrayLiteral("seek"), QByteArray::number(seconds, 'g', 12),
               QByteArrayLiteral("relative")});
}

void PlayerController::skipBackward() { seekRelative(-5.0); }
void PlayerController::skipForward() { seekRelative(5.0); }

void PlayerController::toggleMute() { setMuted(!muted_); }

void PlayerController::setMuted(bool muted) {
  if (engineReady()) {
    int value = muted ? 1 : 0;
    mpv_set_property_async(core_->handle(), 0, "mute", MPV_FORMAT_FLAG,
                           &value);
  }
  if (muted_ == muted)
    return;
  muted_ = muted;
  emit mutedChanged();
}

void PlayerController::setVolume(double volume) {
  if (!std::isfinite(volume))
    return;
  const double normalized = std::clamp(volume, 0.0, 1.0);
  if (engineReady()) {
    double mpv_volume = normalized * 100.0;
    mpv_set_property_async(core_->handle(), 0, "volume", MPV_FORMAT_DOUBLE,
                           &mpv_volume);
  }
  if (nearlyEqual(volume_, normalized))
    return;
  volume_ = normalized;
  emit volumeChanged();
}

void PlayerController::setRate(double rate) {
  if (!std::isfinite(rate))
    return;
  const double bounded = std::clamp(rate, kMinimumRate, kMaximumRate);
  if (engineReady()) {
    double value = bounded;
    mpv_set_property_async(core_->handle(), 0, "speed", MPV_FORMAT_DOUBLE,
                           &value);
  }
  if (nearlyEqual(rate_, bounded))
    return;
  rate_ = bounded;
  emit rateChanged();
}

void PlayerController::toggleCaptions() {
  setCaptionsVisible(!captions_visible_);
}

void PlayerController::setCaptionsVisible(bool visible) {
  if (engineReady()) {
    int value = visible ? 1 : 0;
    mpv_set_property_async(core_->handle(), 0, "sub-visibility",
                           MPV_FORMAT_FLAG, &value);
  }
  if (captions_visible_ == visible)
    return;
  captions_visible_ = visible;
  emit captionsVisibleChanged();
}

void PlayerController::toggleFullscreen() { emit fullscreenToggleRequested(); }

void PlayerController::setPreservePitch(bool preserve) {
  if (engineReady()) {
    int value = preserve ? 1 : 0;
    mpv_set_property_async(core_->handle(), 0, "audio-pitch-correction",
                           MPV_FORMAT_FLAG, &value);
  }
  if (preserve_pitch_ == preserve)
    return;
  preserve_pitch_ = preserve;
  emit preservePitchChanged();
}

void PlayerController::setAppearance(int appearance) {
  const int bounded = std::clamp(appearance, 0, 2);
  if (appearance_ == bounded)
    return;
  appearance_ = bounded;
  emit appearanceChanged();
}

void PlayerController::setTrimIn(double seconds) {
  if (!std::isfinite(seconds))
    return;
  double maximum = duration_ > 0.0 ? duration_ : std::max(seconds, trim_out_);
  if (trim_out_ > 0.0)
    maximum = std::min(maximum, trim_out_);
  const double bounded = std::clamp(seconds, 0.0, std::max(0.0, maximum));
  if (nearlyEqual(trim_in_, bounded))
    return;
  trim_in_ = bounded;
  emit trimInChanged();
}

void PlayerController::setTrimOut(double seconds) {
  if (!std::isfinite(seconds))
    return;
  const double maximum =
      duration_ > 0.0 ? duration_ : std::max(seconds, trim_in_);
  const double bounded =
      std::clamp(seconds, trim_in_, std::max(trim_in_, maximum));
  if (nearlyEqual(trim_out_, bounded))
    return;
  trim_out_ = bounded;
  emit trimOutChanged();
}

void PlayerController::exportSelection() {
  if (!hasMedia()) {
    setLastError(QStringLiteral("Open media before exporting a selection."));
    return;
  }
  if (captioning_) {
    setLastError(QStringLiteral(
        "Wait for caption generation to finish before exporting."));
    return;
  }
  if (exporting_)
    return;
  emit exportSelectionRequested(trim_in_, trim_out_);
}

void PlayerController::exportSelectionTo(const QUrl &destination) {
  if (destination.isEmpty())
    return;
  if (!hasMedia()) {
    setLastError(QStringLiteral("Open media before exporting a selection."));
    return;
  }
  if (captioning_) {
    setLastError(QStringLiteral(
        "Wait for caption generation to finish before exporting."));
    return;
  }
  if (exporting_)
    return;

  const auto input = localPath(source_);
  auto output = localPath(destination);
  if (!input) {
    setLastError(QStringLiteral(
        "Save network media locally before exporting an edited copy."));
    return;
  }
  if (!output) {
    setLastError(QStringLiteral("Choose a local file for the video export."));
    return;
  }
  if (output->extension().empty())
    *output += ".mp4";

  std::error_code path_error;
  if (!std::filesystem::is_regular_file(*input, path_error)) {
    setLastError(QStringLiteral(
        "The source media is no longer available as a readable local file."));
    return;
  }
  if (pathsReferToSameFile(*input, *output)) {
    setLastError(QStringLiteral("Choose a different filename so the original "
                                "media is not overwritten."));
    return;
  }
  const QFileInfo output_info(displayPath(*output));
  if (!QDir(output_info.absolutePath()).exists()) {
    setLastError(QStringLiteral("The selected export folder does not exist."));
    return;
  }

  ::wam::EditOptions options;
  options.input = *input;
  options.in_seconds = trim_in_;
  options.out_seconds = trim_out_;
  options.speed = rate_;
  options.preserve_pitch = preserve_pitch_;
  options.prefer_hardware_encoder = true;

#ifdef _WIN32
  const auto ffmpeg = ::wam::findBundledTool("ffmpeg.exe", nullptr);
#else
  const auto ffmpeg = ::wam::findBundledTool("ffmpeg", nullptr);
#endif

  std::string staging_error;
  export_staging_ = ::wam::reserveExportStagingFile(*output, &staging_error);
  if (export_staging_.empty()) {
    setLastError(
        staging_error.empty()
            ? QStringLiteral("Could not reserve a safe temporary export file.")
            : QStringLiteral("Could not prepare the export: %1")
                  .arg(fromUtf8(staging_error)));
    return;
  }
  export_output_ = *output;
  options.output = export_staging_;

  try {
    export_job_.reset();
    const bool started = export_job_.start(
        "Video export", ::wam::buildExportProcess(ffmpeg, options));
    if (!started) {
      cleanupExportStaging();
      export_output_.clear();
      setLastError(QStringLiteral("Another video export is already running."));
      return;
    }
  } catch (const std::exception &exception) {
    cleanupExportStaging();
    export_output_.clear();
    setLastError(QStringLiteral("Could not start the video export: %1")
                     .arg(QString::fromUtf8(exception.what())));
    return;
  }

  setLastError({});
  export_cancel_requested_ = false;
  setExportStatus(QStringLiteral("Exporting in the background…"));
  export_completion_pending_ = true;
  setExporting(true);
  startWorkPolling();
}

void PlayerController::cancelExport() {
  if (!exporting_)
    return;
  export_cancel_requested_ = true;
  export_job_.cancel();
  setExportStatus(QStringLiteral("Cancelling export…"));
}

void PlayerController::generateCaptions() {
  if (!hasMedia()) {
    setLastError(
        QStringLiteral("Open local media before generating captions."));
    return;
  }
  if (exporting_) {
    setLastError(QStringLiteral(
        "Wait for the video export to finish before captioning."));
    return;
  }
  if (captioning_)
    return;
  emit generateCaptionsRequested();
}

void PlayerController::generateCaptionsTo(const QUrl &destination) {
  if (destination.isEmpty())
    return;
  if (!hasMedia()) {
    setLastError(
        QStringLiteral("Open local media before generating captions."));
    return;
  }
  if (exporting_) {
    setLastError(QStringLiteral(
        "Wait for the video export to finish before captioning."));
    return;
  }
  if (captioning_)
    return;

  const auto input = localPath(source_);
  const auto output = localPath(destination);
  if (!input) {
    setLastError(QStringLiteral(
        "Save network media locally before generating captions."));
    return;
  }
  if (!output) {
    setLastError(QStringLiteral("Choose a local file for the captions."));
    return;
  }

  ::wam::CaptionRequest request;
  request.input = *input;
  request.output_srt = *output;
  request.tools = ::wam::findCaptionTools(nullptr);
  request.options.use_gpu = false;
  request.options.overwrite = true;

  if (!caption_service_.start(std::move(request))) {
    const ::wam::CaptionStatus status = caption_service_.status();
    const QString error = fromUtf8(status.error);
    setLastError(
        error.isEmpty()
            ? QStringLiteral("Another caption task is already running.")
            : error);
    return;
  }

  setLastError({});
  caption_input_ = *input;
  caption_cancel_reason_.clear();
  caption_completion_pending_ = true;
  setCaptionStatus(QStringLiteral("Preparing on-device captions…"));
  setCaptioning(true);
  startWorkPolling();
}

void PlayerController::cancelCaptioning() {
  if (!captioning_)
    return;
  emit cancelCaptioningRequested();
  caption_cancel_reason_ = QStringLiteral("Caption generation cancelled.");
  caption_service_.cancel();
  setCaptionStatus(QStringLiteral("Cancelling caption generation…"));
}

void PlayerController::setExporting(bool exporting) {
  if (exporting_ == exporting)
    return;
  exporting_ = exporting;
  emit exportingChanged();
}

void PlayerController::setCaptioning(bool captioning) {
  if (captioning_ == captioning)
    return;
  captioning_ = captioning;
  emit captioningChanged();
}

void PlayerController::setCaptionStatus(const QString &status) {
  if (caption_status_ == status)
    return;
  caption_status_ = status;
  emit captionStatusChanged();
}

void PlayerController::setExportStatus(const QString &status) {
  if (export_status_ == status)
    return;
  export_status_ = status;
  emit exportStatusChanged();
}

void PlayerController::cleanupExportStaging() noexcept {
  ::wam::removeExportStagingFile(export_staging_);
  export_staging_.clear();
}

void PlayerController::startWorkPolling() {
  if (work_timer_ && !work_timer_->isActive())
    work_timer_->start();
}

void PlayerController::pollBackgroundWork() {
  if (export_completion_pending_ && export_job_.finished()) {
    const bool succeeded = export_job_.succeeded();
    const int exit_code = export_job_.exitCode();
    export_job_.wait();
    export_completion_pending_ = false;
    setExporting(false);
    export_job_.reset();
    if (export_cancel_requested_) {
      cleanupExportStaging();
      setExportStatus(QStringLiteral("Export cancelled."));
    } else if (succeeded) {
      std::string commit_error;
      if (::wam::commitExportStagingFile(export_staging_, export_output_,
                                         &commit_error)) {
        const QString filename =
            QFileInfo(displayPath(export_output_)).fileName();
        setExportStatus(filename.isEmpty()
                            ? QStringLiteral("Export complete.")
                            : QStringLiteral("Saved %1").arg(filename));
        setLastError({});
        export_staging_.clear();
      } else {
        cleanupExportStaging();
        setExportStatus(QStringLiteral("Export failed."));
        setLastError(
            commit_error.empty()
                ? QStringLiteral("The encoded video could not be safely saved. "
                                 "The existing "
                                 "destination was left unchanged.")
                : QStringLiteral(
                      "The encoded video could not be safely saved: %1. The "
                      "existing destination was left unchanged.")
                      .arg(fromUtf8(commit_error)));
      }
    } else {
      cleanupExportStaging();
      setExportStatus(QStringLiteral("Export failed."));
      setLastError(
          QStringLiteral(
              "Video export failed (media tool exit code %1). Check that the "
              "destination is writable and the source contains playable media.")
              .arg(exit_code));
    }
    export_cancel_requested_ = false;
    export_output_.clear();
  }

  if (caption_completion_pending_) {
    const ::wam::CaptionStatus status = caption_service_.status();
    const QString message = fromUtf8(status.message);
    if (!message.isEmpty())
      setCaptionStatus(message);

    if (status.finished) {
      caption_service_.wait();
      caption_completion_pending_ = false;
      setCaptioning(false);
      if (status.succeeded) {
        const auto current_input = localPath(source_);
        if (!current_input || caption_input_.empty() ||
            !pathsReferToSameFile(caption_input_, *current_input)) {
          setCaptionStatus(QStringLiteral(
              "Captions saved, but not attached because the media changed."));
        } else if (attachSubtitleFile(status.output_srt)) {
          setCaptionStatus(QStringLiteral("Captions generated and enabled."));
          setLastError({});
        } else {
          setCaptionStatus(
              QStringLiteral("Captions were saved but could not be attached."));
          setLastError(QStringLiteral("The caption file was created, but the "
                                      "player could not attach it."));
        }
      } else if (status.cancelled) {
        setCaptionStatus(caption_cancel_reason_.isEmpty()
                             ? QStringLiteral("Caption generation cancelled.")
                             : caption_cancel_reason_);
      } else {
        const QString error = fromUtf8(status.error);
        setCaptionStatus(QStringLiteral("Caption generation failed."));
        setLastError(error.isEmpty()
                         ? QStringLiteral("Caption generation failed.")
                         : error);
      }
      caption_input_.clear();
      caption_cancel_reason_.clear();
    }
  }

  if (!export_completion_pending_ && !caption_completion_pending_ &&
      work_timer_) {
    work_timer_->stop();
  }
}

bool PlayerController::attachSubtitleFile(
    const std::filesystem::path &subtitle) {
  if (!engineReady() || subtitle.empty())
    return false;
  const QByteArray path = displayPath(subtitle).toUtf8();
  std::array<const char *, 4> arguments{"sub-add", path.constData(), "select",
                                        nullptr};
  const int result = mpv_command(core_->handle(), arguments.data());
  if (result < 0)
    return false;
  if (std::find(attached_subtitle_files_.begin(),
                attached_subtitle_files_.end(), subtitle) ==
      attached_subtitle_files_.end()) {
    attached_subtitle_files_.push_back(subtitle);
  }
  setCaptionsVisible(true);
  return true;
}

void PlayerController::drainMpvEvents() {
  if (!engineReady())
    return;

  while (true) {
    mpv_event *event = mpv_wait_event(core_->handle(), 0.0);
    if (!event || event->event_id == MPV_EVENT_NONE)
      break;

    if (event->event_id == MPV_EVENT_COMMAND_REPLY) {
      const std::uint64_t reply_namespace =
          event->reply_userdata & kCommandReplyNamespaceMask;
      if (reply_namespace == kOpenCommandReplyNamespace) {
        handleOpenCommandReply(event->reply_userdata, event->error);
        continue;
      }
      if (reply_namespace == kRenderRecoveryCommandReplyNamespace) {
        handleRenderRecoveryCommandReply(event->reply_userdata, event->error);
        continue;
      }
    }

    if (event->event_id == MPV_EVENT_START_FILE) {
      const auto *start = static_cast<mpv_event_start_file *>(event->data);
      handleStartFile(start ? start->playlist_entry_id : -1);
      continue;
    }

    if (event->event_id == MPV_EVENT_FILE_LOADED) {
      handlePlaybackReady(true);
      continue;
    }

    if (event->event_id == MPV_EVENT_PLAYBACK_RESTART) {
      handlePlaybackReady(false);
      continue;
    }

    if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
      const auto *message = static_cast<mpv_event_log_message *>(event->data);
      if (message && message->text) {
        qWarning().noquote().nospace()
            << "WAM media engine [" << (message->prefix ? message->prefix : "")
            << "]: " << QString::fromUtf8(message->text).trimmed();
      }
      continue;
    }

    if (event->event_id == MPV_EVENT_PROPERTY_CHANGE) {
      auto *property = static_cast<mpv_event_property *>(event->data);
      if (!property)
        continue;
      const auto id = static_cast<ObservedProperty>(event->reply_userdata);
      switch (id) {
      case ObservedProperty::Pause:
        applyObservedPause(readFlag(property, true));
        break;
      case ObservedProperty::Idle:
        applyObservedIdle(readFlag(property, true));
        break;
      case ObservedProperty::Position: {
        // mpv reports an unavailable property with no data while replacing a
        // file or video output. Preserve the last real timestamp so renderer
        // recovery can resume instead of silently falling back to zero.
        if (property->format != MPV_FORMAT_DOUBLE || !property->data)
          break;
        applyObservedPosition(readDouble(property, 0.0));
        break;
      }
      case ObservedProperty::Duration: {
        if (property->format != MPV_FORMAT_DOUBLE || !property->data)
          break;
        applyObservedDuration(readDouble(property, 0.0));
        break;
      }
      case ObservedProperty::Volume: {
        const double value =
            std::clamp(readDouble(property, 100.0) / 100.0, 0.0, 1.0);
        if (!nearlyEqual(volume_, value)) {
          volume_ = value;
          emit volumeChanged();
        }
        break;
      }
      case ObservedProperty::Mute: {
        const bool value = readFlag(property, false);
        if (muted_ != value) {
          muted_ = value;
          emit mutedChanged();
        }
        break;
      }
      case ObservedProperty::Rate: {
        const double value = readDouble(property, 1.0);
        if (!nearlyEqual(rate_, value)) {
          rate_ = value;
          emit rateChanged();
        }
        break;
      }
      case ObservedProperty::CaptionsVisible: {
        const bool value = readFlag(property, true);
        if (captions_visible_ != value) {
          captions_visible_ = value;
          emit captionsVisibleChanged();
        }
        break;
      }
      case ObservedProperty::Path: {
        const QUrl observed_source = urlFromMpvPath(readString(property));
        // requested_source_ is authoritative across asynchronous replacement.
        // Ignore empty transition values and paths from an older request; Stop
        // clears the visible source synchronously itself.
        if (requested_source_.isEmpty() || observed_source.isEmpty())
          break;
        if (pending_source_.isEmpty() && committed_open_ &&
            committed_open_->request_serial == request_serial_ &&
            committed_open_->playlist_entry_id >= 0 &&
            committed_open_->playlist_entry_id ==
                active_event_playlist_entry_id_) {
          committed_entry_source_ = observed_source;
        }
        if (sourceIdentity(observed_source) !=
            sourceIdentity(requested_source_)) {
          break;
        }
        observed_current_path_ = true;
        updateSource(observed_source);
        break;
      }
      case ObservedProperty::MediaTitle: {
        QString value = readString(property);
        if (!observed_current_path_ && !value.isEmpty())
          break;
        if (value.isEmpty())
          value = fallbackTitle(source_);
        updateMediaTitle(value);
        break;
      }
      case ObservedProperty::PreservePitch: {
        const bool value = readFlag(property, true);
        if (preserve_pitch_ != value) {
          preserve_pitch_ = value;
          emit preservePitchChanged();
        }
        break;
      }
      case ObservedProperty::EofReached:
        applyObservedEof(readFlag(property, false));
        break;
      case ObservedProperty::VideoTrack:
        applyObservedVideoTrack(readTrackSelection(property));
        break;
      case ObservedProperty::AudioTrack:
        applyObservedAudioTrack(readTrackSelection(property));
        break;
      case ObservedProperty::SubtitleTrack:
        applyObservedSubtitleTrack(readTrackSelection(property));
        break;
      }
      continue;
    }

    if (event->event_id == MPV_EVENT_END_FILE) {
      const auto *end = static_cast<mpv_event_end_file *>(event->data);
      if (end)
        handleEndFile(*end);
    }
  }
}

void PlayerController::requestVideoUpdate() {
  if (video_item_)
    video_item_->update();
}

bool PlayerController::needsRenderContext() const {
  return engineReady() && !requested_source_.isEmpty();
}

void PlayerController::continuePendingOpen() {
  if (core_) {
    if (const auto ticket = core_->readyRenderTicket()) {
      static_cast<void>(flushPendingOpen(ticket->stamp));
      return;
    }
  }
  requestVideoUpdate();
}

bool PlayerController::flushPendingOpen(std::uint64_t render_stamp) {
  if (!core_ || !engineReady())
    return true;

  if (pending_source_.isEmpty() || pending_request_serial_ == 0) {
    if (!render_recovery_ && committed_open_ &&
        committed_open_->request_serial == request_serial_ &&
        committed_open_->render_stamp == 0 &&
        core_->validateRenderTicket({render_stamp})) {
      committed_open_->render_stamp = render_stamp;
    }
    return flushRenderRecovery(render_stamp);
  }

  const RenderTicket ticket{render_stamp};
  if (!core_->validateRenderTicket(ticket))
    return true;

  if (open_attempt_ &&
      open_attempt_->request_serial == pending_request_serial_ &&
      open_attempt_->render_stamp == render_stamp) {
    return true;
  }

  const QUrl source = pending_source_;
  const std::uint64_t request_serial = pending_request_serial_;
  const QString argument = sourceArgument(source);
  if (argument.isEmpty()) {
    abandonPendingOpen();
    setLastError(QStringLiteral("Unable to open an empty media location."));
    return false;
  }

  const QUrl display_source = displayUrlForSource(source);
  applyPlaybackBufferPolicy(core_->handle(),
                            playbackSourceClass(display_source));
  if (!core_->validateRenderTicket(ticket)) {
    continuePendingOpen();
    return true;
  }

  ++next_open_attempt_id_;
  next_open_attempt_id_ &= kCommandReplyIdMask;
  if (next_open_attempt_id_ == 0)
    next_open_attempt_id_ = 1;
  const std::uint64_t reply_userdata =
      kOpenCommandReplyNamespace | next_open_attempt_id_;
  const QByteArray utf8 = argument.toUtf8();
  const int result = sendCommand(
      core_->handle(),
      {QByteArrayLiteral("loadfile"), utf8, QByteArrayLiteral("replace")},
      reply_userdata);
  if (result < 0) {
    // A queueing failure is stable for this request. Leave renderer retries to
    // an explicit subsequent open instead of spinning every frame.
    abandonPendingOpen();
    setLastError(QStringLiteral("Unable to open media: %1")
                     .arg(QString::fromUtf8(mpv_error_string(result))));
    return false;
  }

  open_attempt_ = OpenAttempt{next_open_attempt_id_, request_serial,
                              render_stamp};
  setLastError({});

  // Do not clear pending_source_ here. mpv_command_async only queues work;
  // the matching command reply is the first point where execution is known.
  if (!core_->validateRenderTicket(ticket))
    continuePendingOpen();
  return true;
}

bool PlayerController::flushRenderRecovery(std::uint64_t render_stamp) {
  if (!render_recovery_ || !committed_open_ || !core_ || !engineReady() ||
      render_recovery_->request_serial != request_serial_ ||
      committed_open_->request_serial != request_serial_) {
    return true;
  }

  const RenderTicket ticket{render_stamp};
  if (!core_->validateRenderTicket(ticket))
    return true;

  if (render_recovery_->accepted_render_stamp == render_stamp)
    return true;
  if (render_recovery_attempt_ &&
      render_recovery_attempt_->request_serial == request_serial_ &&
      render_recovery_attempt_->render_stamp == render_stamp) {
    return true;
  }
  if (render_recovery_->command_failed)
    return false;

  if (render_recovery_->mode == RenderRecoveryMode::NoReselection) {
    render_recovery_->accepted_render_stamp = render_stamp;
    committed_open_->render_stamp = render_stamp;
    restoreRenderRecovery();
    return true;
  }

  if (render_recovery_->mode == RenderRecoveryMode::VideoReselect &&
      (render_recovery_->video_track_id <= 0 ||
       committed_open_->playlist_entry_id < 0)) {
    render_recovery_->accepted_render_stamp = render_stamp;
    committed_open_->render_stamp = render_stamp;
    degradeRenderRecovery(QStringLiteral(
        "Unable to restore video output without changing media state."));
    return false;
  }

  ++next_render_recovery_attempt_id_;
  next_render_recovery_attempt_id_ &= kCommandReplyIdMask;
  if (next_render_recovery_attempt_id_ == 0)
    next_render_recovery_attempt_id_ = 1;
  const std::uint64_t reply_userdata =
      kRenderRecoveryCommandReplyNamespace |
      next_render_recovery_attempt_id_;
  int result = MPV_ERROR_INVALID_PARAMETER;
  bool restarted_playlist_entry = false;
  if (render_recovery_->mode == RenderRecoveryMode::VideoReselect) {
    // The ordinary A/V path keeps the current demuxer, audio, subtitle files
    // and track selections alive. Only the exact built-in video track is
    // reselected after render-context teardown deselected the VO.
    const QByteArray track =
        QByteArray::number(render_recovery_->video_track_id);
    result = sendCommand(
        core_->handle(),
        {QByteArrayLiteral("set"), QByteArrayLiteral("vid"), track},
        reply_userdata);
  } else {
    // With video-only media, deselecting the last A/V track unloads the file
    // despite keep-open. Restart the retained playlist entry in place whenever
    // possible: unlike `loadfile replace`, this preserves redirect children
    // and the remaining sibling continuation. restoreRenderRecovery()
    // re-attaches WAM subtitles and exact selections before transport state.
    const std::int64_t playlist_position = playlistPositionForEntry(
        core_->handle(), committed_open_->playlist_entry_id);
    render_recovery_->preserve_playlist_context =
        render_recovery_->preserve_playlist_context ||
        playlistEntryCount(core_->handle()) > 1 || !redirect_ranges_.empty();
    if (playlist_position >= 0) {
      render_recovery_->playlist_position = playlist_position;
      const QByteArray position = QByteArray::number(playlist_position);
      result = sendCommand(
          core_->handle(),
          {QByteArrayLiteral("playlist-play-index"), position},
          reply_userdata);
      restarted_playlist_entry = result >= 0;
    } else if (!render_recovery_->preserve_playlist_context) {
      // A standalone entry may have been removed by video-only VO teardown.
      // Replacing that one source cannot discard a playlist continuation.
      const QByteArray source =
          sourceArgument(render_recovery_->reload_source).toUtf8();
      if (!source.isEmpty()) {
        result = sendCommand(
            core_->handle(),
            {QByteArrayLiteral("loadfile"), source,
             QByteArrayLiteral("replace")},
            reply_userdata);
      }
    }
  }
  if (result < 0) {
    render_recovery_->accepted_render_stamp = render_stamp;
    committed_open_->render_stamp = render_stamp;
    degradeRenderRecovery(
        QStringLiteral("Unable to restore video output: %1")
            .arg(QString::fromUtf8(mpv_error_string(result))));
    return false;
  }

  render_recovery_attempt_ = RenderRecoveryAttempt{
      next_render_recovery_attempt_id_, request_serial_, render_stamp,
      committed_open_->playlist_entry_id,
      render_recovery_->video_track_id, render_recovery_->mode, -1,
      restarted_playlist_entry};
  setLastError({});

  if (!core_->validateRenderTicket(ticket))
    continuePendingOpen();
  return true;
}

void PlayerController::handleOpenCommandReply(std::uint64_t reply_userdata,
                                               int error) {
  const std::uint64_t attempt_id =
      reply_userdata & kCommandReplyIdMask;
  if (!open_attempt_ || open_attempt_->id != attempt_id)
    return;

  const OpenAttempt attempt = *open_attempt_;
  const bool current_request =
      attempt.request_serial == request_serial_ &&
      attempt.request_serial == pending_request_serial_ &&
      !pending_source_.isEmpty();
  const bool current_renderer =
      core_ && core_->validateRenderTicket({attempt.render_stamp});

  if (!current_request) {
    open_attempt_.reset();
    return;
  }

  if (!current_renderer) {
    // A later Ready notification submits this same authoritative intent in
    // the replacement generation. Old-generation replies are harmless.
    open_attempt_.reset();
    continuePendingOpen();
    return;
  }

  if (error < 0) {
    abandonPendingOpen();
    setLastError(QStringLiteral("Unable to open media: %1")
                     .arg(QString::fromUtf8(mpv_error_string(error))));
    return;
  }

  const QUrl loaded_source = pending_source_;
  updateSource(displayUrlForSource(loaded_source));
  updateMediaTitle(fallbackTitle(loaded_source));
  OpenAttempt committed = attempt;
  const std::int64_t current_entry = currentPlaylistEntryId(core_->handle());
  committed.playlist_entry_id = authoritativePlaylistEntry(
      current_entry, attempt.playlist_entry_id);
  committed_open_ = committed;
  int live_paused = paused_ ? 1 : 0;
  if (engineReady()) {
    static_cast<void>(mpv_get_property(core_->handle(), "pause",
                                       MPV_FORMAT_FLAG, &live_paused));
  }
  StartupPlaybackSync startup_sync;
  startup_sync.request_serial = committed.request_serial;
  startup_sync.render_stamp = committed.render_stamp;
  startup_sync.playlist_entry_id = committed.playlist_entry_id;
  startup_sync.intended_paused = live_paused != 0;
  startup_playback_sync_ = startup_sync;
  committed_entry_source_ = displayUrlForSource(loaded_source);
  committed_playlist_position_ = playlistPositionForEntry(
      core_->handle(), committed.playlist_entry_id);
  terminal_playlist_entry_id_ = -1;
  redirect_ranges_.clear();
  render_recovery_attempt_.reset();
  render_recovery_.reset();
  attached_subtitle_files_.clear();
  current_file_has_audio_track_.reset();
  selected_video_track_id_ = -1;
  selected_audio_track_id_ = -1;
  selected_subtitle_track_id_ = -1;
  selected_tracks_playlist_entry_id_ = -1;
  if (active_event_playlist_entry_id_ != committed.playlist_entry_id)
    active_event_playlist_entry_id_ = -1;
  const std::int64_t video_track = currentVideoTrackId(core_->handle());
  if (video_track > 0 && committed.playlist_entry_id >= 0) {
    selected_video_track_id_ = video_track;
    selected_tracks_playlist_entry_id_ = committed.playlist_entry_id;
  }
  pending_source_.clear();
  pending_request_serial_ = 0;
  open_attempt_.reset();
}

std::int64_t PlayerController::authoritativePlaylistEntry(
    std::int64_t live_entry, std::int64_t captured_start_entry) {
  return live_entry >= 0 ? live_entry : captured_start_entry;
}

void PlayerController::handleRenderRecoveryCommandReply(
    std::uint64_t reply_userdata, int error) {
  const std::uint64_t attempt_id =
      reply_userdata & kCommandReplyIdMask;
  if (!render_recovery_attempt_ ||
      render_recovery_attempt_->id != attempt_id) {
    return;
  }

  const RenderRecoveryAttempt attempt = *render_recovery_attempt_;
  const bool current_request =
      render_recovery_ && committed_open_ &&
      attempt.request_serial == request_serial_ &&
      render_recovery_->request_serial == request_serial_ &&
      committed_open_->request_serial == request_serial_;
  const bool current_renderer =
      core_ && core_->validateRenderTicket({attempt.render_stamp});
  render_recovery_attempt_.reset();

  if (!current_request)
    return;
  if (!current_renderer) {
    continuePendingOpen();
    return;
  }
  if (error < 0) {
    render_recovery_->accepted_render_stamp = attempt.render_stamp;
    committed_open_->render_stamp = attempt.render_stamp;
    degradeRenderRecovery(
        QStringLiteral("Unable to restore video output: %1")
            .arg(QString::fromUtf8(mpv_error_string(error))));
    return;
  }

  if (attempt.mode == RenderRecoveryMode::FullReload) {
    const std::int64_t current_entry =
        currentPlaylistEntryId(core_->handle());
    const std::int64_t reloaded_entry = authoritativePlaylistEntry(
        current_entry, attempt.started_playlist_entry_id);
    if (reloaded_entry < 0) {
      render_recovery_->accepted_render_stamp = attempt.render_stamp;
      committed_open_->render_stamp = attempt.render_stamp;
      degradeRenderRecovery(QStringLiteral(
          "Unable to identify the reloaded video playlist entry."));
      return;
    }
    committed_open_->playlist_entry_id = reloaded_entry;
    const QUrl live_source =
        playlistEntrySource(core_->handle(), reloaded_entry);
    committed_entry_source_ = live_source.isEmpty()
                                  ? render_recovery_->reload_source
                                  : live_source;
    committed_playlist_position_ =
        playlistPositionForEntry(core_->handle(), reloaded_entry);
    if (committed_playlist_position_ < 0 &&
        attempt.restarted_playlist_entry &&
        reloaded_entry == attempt.playlist_entry_id) {
      committed_playlist_position_ = render_recovery_->playlist_position;
    }
    if (!attempt.restarted_playlist_entry)
      redirect_ranges_.clear();
    if (active_event_playlist_entry_id_ != reloaded_entry)
      active_event_playlist_entry_id_ = -1;
  } else if (committed_open_->playlist_entry_id < 0 ||
             attempt.playlist_entry_id !=
                 committed_open_->playlist_entry_id) {
    return;
  }

  render_recovery_->accepted_render_stamp = attempt.render_stamp;
  committed_open_->render_stamp = attempt.render_stamp;
  setLastError({});
  restoreRenderRecovery();
}

bool PlayerController::playlistEntryBelongsToCurrentLineage(
    std::int64_t playlist_entry_id) const {
  if (playlist_entry_id < 0 || !committed_open_ ||
      committed_open_->request_serial != request_serial_ ||
      committed_open_->playlist_entry_id < 0) {
    return false;
  }
  if (playlist_entry_id == committed_open_->playlist_entry_id)
    return true;
  for (const PlaylistEntryRange &range : redirect_ranges_) {
    if (range.first < 0 || playlist_entry_id < range.first)
      continue;
    const auto distance = static_cast<std::uint64_t>(playlist_entry_id -
                                                     range.first);
    if (distance < range.count)
      return true;
  }
  return false;
}

void PlayerController::handleStartFile(std::int64_t playlist_entry_id) {
  if (playlist_entry_id < 0) {
    active_event_playlist_entry_id_ = -1;
    return;
  }
  if (render_recovery_attempt_ &&
      render_recovery_attempt_->request_serial == request_serial_ &&
      render_recovery_attempt_->mode == RenderRecoveryMode::FullReload) {
    render_recovery_attempt_->started_playlist_entry_id = playlist_entry_id;
    active_event_playlist_entry_id_ = playlist_entry_id;
    terminal_playlist_entry_id_ = -1;
    return;
  }

  if (open_attempt_ && open_attempt_->request_serial == request_serial_ &&
      open_attempt_->request_serial == pending_request_serial_) {
    open_attempt_->playlist_entry_id = playlist_entry_id;
    active_event_playlist_entry_id_ = playlist_entry_id;
    terminal_playlist_entry_id_ = -1;
    return;
  }

  const bool initial_start_without_committed_entry =
      startup_playback_sync_ && committed_open_ &&
      startup_playback_sync_->request_serial == request_serial_ &&
      committed_open_->request_serial == request_serial_ &&
      committed_open_->playlist_entry_id < 0 &&
      startup_playback_sync_->playlist_entry_id < 0;
  if (!pending_source_.isEmpty() ||
      (!initial_start_without_committed_entry &&
       !playlistEntryBelongsToCurrentLineage(playlist_entry_id))) {
    active_event_playlist_entry_id_ = -1;
    return;
  }

  // A redirect child becomes the concrete current entry. Retain all accepted
  // ranges so a sibling or a nested redirect child can be promoted later.
  const bool entry_changed =
      committed_open_->playlist_entry_id != playlist_entry_id;
  committed_open_->playlist_entry_id = playlist_entry_id;
  if (startup_playback_sync_ &&
      startup_playback_sync_->request_serial == request_serial_) {
    startup_playback_sync_->playlist_entry_id = playlist_entry_id;
    startup_playback_sync_->completion_token = 0;
    startup_playback_sync_->retry_count = 0;
  }
  const std::int64_t live_playlist_position =
      engineReady()
          ? playlistPositionForEntry(core_->handle(), playlist_entry_id)
          : -1;
  if (live_playlist_position >= 0 || entry_changed)
    committed_playlist_position_ = live_playlist_position;
  if (entry_changed) {
    committed_entry_source_ =
        engineReady()
            ? playlistEntrySource(core_->handle(), playlist_entry_id)
            : QUrl{};
  }
  active_event_playlist_entry_id_ = playlist_entry_id;
  terminal_playlist_entry_id_ = -1;
  updateEof(false);
  if (!render_recovery_ && committed_open_->render_stamp == 0) {
    RenderRecovery adoption;
    adoption.request_serial = request_serial_;
    adoption.mode = RenderRecoveryMode::NoReselection;
    if (core_) {
      if (const auto ready = core_->readyRenderTicket()) {
        adoption.accepted_render_stamp = ready->stamp;
        committed_open_->render_stamp = ready->stamp;
      }
    }
    render_recovery_ = std::move(adoption);
  }
  if (render_recovery_ &&
      render_recovery_->request_serial == request_serial_) {
    if (render_recovery_->accepted_render_stamp != 0 && core_ &&
        core_->validateRenderTicket(
            {render_recovery_->accepted_render_stamp})) {
      committed_open_->render_stamp =
          render_recovery_->accepted_render_stamp;
    }
    if (render_recovery_attempt_ &&
        render_recovery_attempt_->request_serial == request_serial_ &&
        render_recovery_attempt_->mode ==
            RenderRecoveryMode::VideoReselect) {
      render_recovery_attempt_->playlist_entry_id = playlist_entry_id;
    }
  }
  if (entry_changed) {
    resetTimeline();
    observed_current_path_ = false;
    updateMediaTitle({});
    selected_video_track_id_ = -1;
    selected_audio_track_id_ = -1;
    selected_subtitle_track_id_ = -1;
    selected_tracks_playlist_entry_id_ = -1;
    current_file_has_audio_track_.reset();
    if (render_recovery_) {
      render_recovery_->position = 0.0;
      render_recovery_->position_overridden = false;
      render_recovery_->file_loaded = false;
      render_recovery_->playback_restarted = false;
      render_recovery_->track_snapshot_proven = false;
      render_recovery_->transport_restored = false;
      render_recovery_->completion_token = 0;
      render_recovery_->restore_retry_count = 0;
      render_recovery_->restore_retry_queued = false;
      render_recovery_->restore_failure.clear();
    }
  }
}

void PlayerController::handleEndFile(const mpv_event_end_file &end) {
  const bool startup_entry =
      startup_playback_sync_ && committed_open_ &&
      startup_playback_sync_->request_serial == request_serial_ &&
      startup_playback_sync_->playlist_entry_id == end.playlist_entry_id;
  const bool current_entry =
      end.playlist_entry_id >= 0 && committed_open_ &&
      committed_open_->request_serial == request_serial_ &&
      committed_open_->playlist_entry_id == end.playlist_entry_id &&
      (active_event_playlist_entry_id_ == end.playlist_entry_id ||
       startup_entry);
  if (!current_entry)
    return;

  active_event_playlist_entry_id_ = -1;

  const bool expected_video_only_teardown =
      end.reason == MPV_END_FILE_REASON_ERROR &&
      (selected_tracks_playlist_entry_id_ !=
           committed_open_->playlist_entry_id ||
       selected_audio_track_id_ <= 0) &&
      core_ &&
      !core_->validateRenderTicket({committed_open_->render_stamp});
  if (expected_video_only_teardown)
    return;

  // A video-only full reload first stops the retained old entry. That stop is
  // part of recovery, not a terminal event for the user's current request.
  if (render_recovery_attempt_ &&
      render_recovery_attempt_->mode == RenderRecoveryMode::FullReload &&
      render_recovery_attempt_->playlist_entry_id == end.playlist_entry_id) {
    return;
  }

  if (end.reason == MPV_END_FILE_REASON_ERROR && render_recovery_ &&
      render_recovery_->mode == RenderRecoveryMode::VideoReselect) {
    // A successful `set vid` reply is not sufficient proof that the VO lived:
    // libmpv can report success and then asynchronously unload the entry.
    // Preserve the captured per-file state and escalate this one recovery to
    // the guarded full-reload path.
    render_recovery_->mode = RenderRecoveryMode::FullReload;
    render_recovery_->accepted_render_stamp = 0;
    render_recovery_->command_failed = false;
    render_recovery_->file_loaded = false;
    render_recovery_->playback_restarted = false;
    render_recovery_->external_subtitles_restored = false;
    render_recovery_->external_subtitles_restored_count = 0;
    render_recovery_->per_file_state_restored = false;
    render_recovery_->transport_restored = false;
    render_recovery_->completion_token = 0;
    render_recovery_attempt_.reset();
    committed_open_->render_stamp = 0;
    continuePendingOpen();
    return;
  }

  if (end.reason == MPV_END_FILE_REASON_REDIRECT) {
    if (end.playlist_insert_id >= 0 &&
        end.playlist_insert_num_entries > 0) {
      redirect_ranges_.push_back(PlaylistEntryRange{
          end.playlist_insert_id,
          static_cast<std::uint64_t>(end.playlist_insert_num_entries)});
    }
    return;
  }
  if (end.reason == MPV_END_FILE_REASON_EOF) {
    startup_playback_sync_.reset();
    if (render_recovery_) {
      // EOF terminates this entry's transport/track recovery, but not the
      // replacement render generation: a redirect sibling may start next.
      // Carry only generation adoption so the sibling establishes a fresh
      // FILE_LOADED track snapshot instead of replaying the old child.
      std::uint64_t adoption_stamp =
          render_recovery_->accepted_render_stamp;
      if ((!core_ ||
           !core_->validateRenderTicket({adoption_stamp})) && core_) {
        if (const auto ready = core_->readyRenderTicket())
          adoption_stamp = ready->stamp;
        else
          adoption_stamp = 0;
      }
      RenderRecovery adoption;
      adoption.request_serial = request_serial_;
      adoption.paused = paused_;
      adoption.mode = RenderRecoveryMode::NoReselection;
      adoption.accepted_render_stamp = adoption_stamp;
      render_recovery_ = std::move(adoption);
      render_recovery_attempt_.reset();
      committed_open_->render_stamp = adoption_stamp;
      updateEof(true);
      if (adoption_stamp == 0)
        continuePendingOpen();
      const std::uint64_t terminal_serial = request_serial_;
      const std::int64_t terminal_entry = end.playlist_entry_id;
      QTimer::singleShot(0, this, [this, terminal_serial, terminal_entry] {
        if (!render_recovery_ || request_serial_ != terminal_serial ||
            !committed_open_ ||
            committed_open_->playlist_entry_id != terminal_entry ||
            active_event_playlist_entry_id_ >= 0 || !eof_reached_ ||
            render_recovery_->mode !=
                RenderRecoveryMode::NoReselection) {
          return;
        }
        const std::uint64_t adoption_stamp =
            render_recovery_->accepted_render_stamp;
        render_recovery_.reset();
        render_recovery_attempt_.reset();
        committed_open_->render_stamp = adoption_stamp;
        terminal_playlist_entry_id_ = terminal_entry;
      });
      return;
    }
    render_recovery_.reset();
    render_recovery_attempt_.reset();
    terminal_playlist_entry_id_ = end.playlist_entry_id;
    updateEof(true);
    return;
  }
  if (end.reason == MPV_END_FILE_REASON_ERROR) {
    startup_playback_sync_.reset();
    render_recovery_.reset();
    render_recovery_attempt_.reset();
    updatePause(true);
    updateIdle(true);
    updateEof(false);
    resetTimeline();
    last_error_playlist_entry_id_ = end.playlist_entry_id;
    setLastError(QStringLiteral("Playback failed: %1")
                     .arg(QString::fromUtf8(mpv_error_string(end.error))));
  }
}

void PlayerController::handlePlaybackReady(bool file_loaded) {
  if (file_loaded)
    cacheCurrentEntrySource();
  if (file_loaded && last_error_playlist_entry_id_ >= 0 &&
      active_event_playlist_entry_id_ >= 0 &&
      active_event_playlist_entry_id_ !=
          last_error_playlist_entry_id_) {
    last_error_playlist_entry_id_ = -1;
    setLastError({});
  }
  if (render_recovery_) {
    bool matching_lineage = false;
    if (committed_open_ && committed_open_->playlist_entry_id >= 0 &&
        committed_open_->playlist_entry_id ==
            active_event_playlist_entry_id_) {
      matching_lineage = true;
    }
    if (render_recovery_attempt_ &&
        render_recovery_attempt_->mode == RenderRecoveryMode::FullReload &&
        render_recovery_attempt_->started_playlist_entry_id >= 0 &&
        render_recovery_attempt_->started_playlist_entry_id ==
            active_event_playlist_entry_id_) {
      matching_lineage = true;
    }
    if (matching_lineage) {
      if (file_loaded)
        render_recovery_->file_loaded = true;
      else if (render_recovery_->accepted_render_stamp != 0 &&
               !render_recovery_attempt_ && core_ &&
               core_->validateRenderTicket(
                   {render_recovery_->accepted_render_stamp}))
        render_recovery_->playback_restarted = true;
    }
  } else if (startup_playback_sync_ && committed_open_ &&
             startup_playback_sync_->request_serial == request_serial_ &&
             startup_playback_sync_->playlist_entry_id >= 0 &&
             startup_playback_sync_->playlist_entry_id ==
                 active_event_playlist_entry_id_ &&
             committed_open_->playlist_entry_id ==
                 active_event_playlist_entry_id_) {
    if (file_loaded)
      cacheCurrentTrackSelection();
    else
      queueStartupPlaybackSync();
  } else if (file_loaded && acceptsPlaybackObservation()) {
    cacheCurrentTrackSelection();
  }
  restoreRenderRecovery();
}

bool PlayerController::acceptsPlaybackObservation() const {
  return !requested_source_.isEmpty() && pending_source_.isEmpty() &&
         pending_request_serial_ == 0 && !open_attempt_ &&
         !render_recovery_ && !startup_playback_sync_ && committed_open_ &&
         committed_open_->request_serial == request_serial_ &&
         committed_open_->playlist_entry_id >= 0 &&
         core_ &&
         core_->validateRenderTicket({committed_open_->render_stamp}) &&
         active_event_playlist_entry_id_ ==
             committed_open_->playlist_entry_id;
}

void PlayerController::applyObservedPause(bool paused) {
  if (acceptsPlaybackObservation())
    updatePause(paused);
}

void PlayerController::applyObservedPosition(double position) {
  if (!acceptsPlaybackObservation() || !std::isfinite(position))
    return;
  const double value = std::max(0.0, position);
  if (!nearlyEqual(position_, value)) {
    position_ = value;
    emit positionChanged();
  }
}

void PlayerController::applyObservedDuration(double duration) {
  if (!acceptsPlaybackObservation() || !std::isfinite(duration))
    return;
  updateDuration(duration);
}

void PlayerController::updateDuration(double duration) {
  if (!std::isfinite(duration))
    return;
  const double old_duration = duration_;
  const double value = std::max(0.0, duration);
  if (!nearlyEqual(duration_, value)) {
    duration_ = value;
    emit durationChanged();
  }
  if (trim_out_ <= 0.0 || nearlyEqual(trim_out_, old_duration))
    setTrimOut(value);
}

void PlayerController::applyObservedIdle(bool idle) {
  if (acceptsPlaybackObservation())
    updateIdle(idle);
}

void PlayerController::applyObservedEof(bool eof_reached) {
  if (acceptsPlaybackObservation())
    updateEof(eof_reached);
}

void PlayerController::applyObservedVideoTrack(
    std::int64_t video_track_id) {
  if (!acceptsPlaybackObservation())
    return;
  selected_video_track_id_ = video_track_id >= 0 ? video_track_id : -1;
  selected_tracks_playlist_entry_id_ =
      committed_open_->playlist_entry_id;
}

void PlayerController::applyObservedAudioTrack(
    std::int64_t audio_track_id) {
  if (!acceptsPlaybackObservation())
    return;
  selected_audio_track_id_ = audio_track_id >= 0 ? audio_track_id : -1;
  selected_tracks_playlist_entry_id_ =
      committed_open_->playlist_entry_id;
}

void PlayerController::applyObservedSubtitleTrack(
    std::int64_t subtitle_track_id) {
  if (!acceptsPlaybackObservation())
    return;
  selected_subtitle_track_id_ =
      subtitle_track_id >= 0 ? subtitle_track_id : -1;
  selected_tracks_playlist_entry_id_ =
      committed_open_->playlist_entry_id;
}

void PlayerController::cacheCurrentTrackSelection() {
  if (!core_ || !engineReady() || !committed_open_ ||
      active_event_playlist_entry_id_ < 0 ||
      active_event_playlist_entry_id_ !=
          committed_open_->playlist_entry_id) {
    return;
  }
  selected_video_track_id_ =
      currentTrackSelection(core_->handle(), "vid");
  selected_audio_track_id_ =
      currentTrackSelection(core_->handle(), "aid");
  selected_subtitle_track_id_ =
      currentTrackSelection(core_->handle(), "sid");
  selected_tracks_playlist_entry_id_ =
      committed_open_->playlist_entry_id;
  current_file_has_audio_track_ =
      currentFileHasTrackType(core_->handle(), "audio");
}

void PlayerController::cacheCurrentEntrySource() {
  if (!core_ || !engineReady() || !committed_open_ ||
      committed_open_->playlist_entry_id < 0 ||
      committed_open_->playlist_entry_id !=
          active_event_playlist_entry_id_) {
    return;
  }
  char *path = mpv_get_property_string(core_->handle(), "path");
  if (!path)
    return;
  const QUrl source = urlFromMpvPath(QString::fromUtf8(path));
  mpv_free(path);
  if (!source.isEmpty()) {
    committed_entry_source_ = source;
    committed_playlist_position_ = playlistPositionForEntry(
        core_->handle(), committed_open_->playlist_entry_id);
  }
}

void PlayerController::restoreRenderRecovery() {
  if (!render_recovery_ || !committed_open_ || !core_ || !engineReady() ||
      render_recovery_->request_serial != request_serial_ ||
      committed_open_->request_serial != request_serial_ ||
      render_recovery_->accepted_render_stamp == 0 ||
      !core_->validateRenderTicket(
          {render_recovery_->accepted_render_stamp}) ||
      committed_open_->playlist_entry_id < 0 ||
      committed_open_->playlist_entry_id !=
          active_event_playlist_entry_id_) {
    return;
  }

  RenderRecovery &recovery = *render_recovery_;
  if (recovery.mode == RenderRecoveryMode::FullReload) {
    if (!recovery.file_loaded)
      return;

    if (!recovery.external_subtitles_restored) {
      for (std::size_t index = recovery.external_subtitles_restored_count;
           index < recovery.external_subtitles.size(); ++index) {
        const QByteArray path =
            displayPath(recovery.external_subtitles[index]).toUtf8();
        const bool select_last =
            recovery.subtitle_track_id > 0 &&
            index + 1 == recovery.external_subtitles.size();
        std::array<const char *, 4> arguments{
            "sub-add", path.constData(), select_last ? "select" : "auto",
            nullptr};
        if (mpv_command(core_->handle(), arguments.data()) < 0) {
          scheduleRenderRecoveryRetry(
              QStringLiteral("Unable to restore external subtitles."));
          return;
        }
        recovery.external_subtitles_restored_count = index + 1;
      }
      recovery.external_subtitles_restored = true;
    }

    if (!recovery.per_file_state_restored) {
      if (!setTrackSelection(core_->handle(), "vid",
                             recovery.video_track_id) ||
          !setTrackSelection(core_->handle(), "aid",
                             recovery.audio_track_id)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore selected media tracks."));
        return;
      }
      if (recovery.subtitle_track_id == 0 ||
          (recovery.subtitle_track_id > 0 &&
           recovery.external_subtitles.empty())) {
        if (!setTrackSelection(core_->handle(), "sid",
                               recovery.subtitle_track_id)) {
          scheduleRenderRecoveryRetry(
              QStringLiteral("Unable to restore the selected subtitle."));
          return;
        }
      }
      int visible = captions_visible_ ? 1 : 0;
      if (!setCoreProperty(core_->handle(), "sub-visibility",
                           MPV_FORMAT_FLAG, &visible)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore subtitle visibility."));
        return;
      }
      recovery.per_file_state_restored = true;
    }
  }

  if (!recovery.track_snapshot_proven) {
    if (!recovery.file_loaded ||
        (recovery.mode != RenderRecoveryMode::NoReselection &&
         !recovery.playback_restarted))
      return;
    const auto has_video =
        currentFileHasTrackType(core_->handle(), "video");
    const auto has_audio =
        currentFileHasTrackType(core_->handle(), "audio");
    const auto has_subtitle =
        currentFileHasTrackType(core_->handle(), "sub");
    if (!has_video || !has_audio || !has_subtitle) {
      scheduleRenderRecoveryRetry(
          QStringLiteral("Unable to read the restored media tracks."));
      return;
    }
    std::int64_t video = currentTrackSelection(core_->handle(), "vid");
    std::int64_t audio = currentTrackSelection(core_->handle(), "aid");
    std::int64_t subtitle = currentTrackSelection(core_->handle(), "sid");
    if ((*has_video && video < 0) || (*has_audio && audio < 0) ||
        (*has_subtitle && subtitle < 0)) {
      scheduleRenderRecoveryRetry(
          QStringLiteral("Restored media tracks are not ready."));
      return;
    }
    if (!*has_video && video < 0)
      video = 0;
    if (!*has_audio && audio < 0)
      audio = 0;
    if (!*has_subtitle && subtitle < 0)
      subtitle = 0;
    recovery.video_track_id = video;
    recovery.audio_track_id = audio;
    recovery.subtitle_track_id = subtitle;
    recovery.file_has_audio_track = *has_audio;
    recovery.track_snapshot_proven = true;
  }

  if (recovery.mode != RenderRecoveryMode::NoReselection) {
    if (!recovery.playback_restarted)
      return;
    const std::int64_t live_entry =
        playingPlaylistEntryId(core_->handle());
    int idle = 1;
    const bool live_video =
        recovery.video_track_id <= 0 ||
        currentTrackSelection(core_->handle(), "vid") ==
            recovery.video_track_id;
    if (live_entry != committed_open_->playlist_entry_id ||
        mpv_get_property(core_->handle(), "idle-active", MPV_FORMAT_FLAG,
                         &idle) < 0 ||
        idle != 0 || !live_video) {
      scheduleRenderRecoveryRetry(
          QStringLiteral("Restored video output did not become ready."));
      return;
    }
  }

  if (!recovery.transport_restored) {
    if (recovery.mode == RenderRecoveryMode::NoReselection) {
      // Audio-only playback never stopped when the visual renderer vanished.
      // Re-apply only the latest pause intent; adopting the generation must
      // never rewind continuously playing audio.
      int paused = recovery.paused ? 1 : 0;
      if (!setCoreProperty(core_->handle(), "pause", MPV_FORMAT_FLAG,
                           &paused)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore the playback state."));
        return;
      }
      recovery.transport_restored = true;
    } else if (recovery.mode == RenderRecoveryMode::VideoReselect &&
               !recovery.paused && !recovery.position_overridden) {
      double live_position = 0.0;
      if (mpv_get_property(core_->handle(), "time-pos", MPV_FORMAT_DOUBLE,
                           &live_position) < 0 ||
          !std::isfinite(live_position)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to sample the live playback position."));
        return;
      }
      recovery.position = std::max(0.0, live_position);
      if (!nearlyEqual(position_, recovery.position)) {
        position_ = recovery.position;
        emit positionChanged();
      }
      int paused = 0;
      if (!setCoreProperty(core_->handle(), "pause", MPV_FORMAT_FLAG,
                           &paused)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore the playback state."));
        return;
      }
      recovery.transport_restored = true;
    } else if (recovery.position > 0.01) {
      double position = recovery.position;
      if (!setCoreProperty(core_->handle(), "time-pos", MPV_FORMAT_DOUBLE,
                           &position)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore the playback position."));
        return;
      }
      int paused = recovery.paused ? 1 : 0;
      if (!setCoreProperty(core_->handle(), "pause", MPV_FORMAT_FLAG,
                           &paused)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore the playback state."));
        return;
      }
      recovery.transport_restored = true;
    } else {
      int paused = recovery.paused ? 1 : 0;
      if (!setCoreProperty(core_->handle(), "pause", MPV_FORMAT_FLAG,
                           &paused)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore the playback state."));
        return;
      }
      recovery.transport_restored = true;
    }
  }

  queueRenderRecoveryCompletion();
}

void PlayerController::queueRenderRecoveryCompletion() {
  if (!render_recovery_ || !committed_open_ || !core_ ||
      render_recovery_->completion_token != 0 ||
      !render_recovery_->transport_restored) {
    return;
  }

  ++next_render_recovery_completion_token_;
  if (next_render_recovery_completion_token_ == 0)
    ++next_render_recovery_completion_token_;
  const std::uint64_t completion_token =
      next_render_recovery_completion_token_;
  const std::uint64_t request_serial = render_recovery_->request_serial;
  const std::uint64_t render_stamp =
      render_recovery_->accepted_render_stamp;
  const std::int64_t playlist_entry_id =
      committed_open_->playlist_entry_id;
  render_recovery_->completion_token = completion_token;

  // mpv can enqueue transient pause/idle/eof property changes while replacing
  // video-only media. Keep the recovery gate through the remainder of the
  // current event drain, then discard those transitions and publish one live,
  // coherent transport snapshot before observations are accepted again.
  QTimer::singleShot(
      0, this,
      [this, completion_token, request_serial, render_stamp,
       playlist_entry_id] {
        finishRenderRecoveryCompletion(completion_token, request_serial,
                                       render_stamp, playlist_entry_id);
      });
}

void PlayerController::finishRenderRecoveryCompletion(
    std::uint64_t completion_token, std::uint64_t request_serial,
    std::uint64_t render_stamp, std::int64_t playlist_entry_id) {
  const auto completion_is_current = [this, completion_token, request_serial,
                                      render_stamp, playlist_entry_id] {
    return render_recovery_ && committed_open_ && core_ &&
           render_recovery_->completion_token == completion_token &&
           render_recovery_->request_serial == request_serial &&
           render_recovery_->accepted_render_stamp == render_stamp &&
           committed_open_->request_serial == request_serial &&
           committed_open_->render_stamp == render_stamp &&
           committed_open_->playlist_entry_id == playlist_entry_id &&
           active_event_playlist_entry_id_ == playlist_entry_id &&
           core_->validateRenderTicket({render_stamp});
  };

  if (!completion_is_current())
    return;

  // Property events already queued by the synchronous restore writes must
  // remain gated. A later EOF, Open, Stop or renderer invalidation mutates the
  // identity checked below and wins over this completion.
  drainMpvEvents();
  if (!completion_is_current())
    return;

  render_recovery_->completion_token = 0;
  if (!render_recovery_->transport_restored) {
    restoreRenderRecovery();
    return;
  }

  const auto live_state = readLivePlaybackState();
  if (!live_state ||
      !livePlaybackStateMatchesRecovery(*render_recovery_, *live_state)) {
    scheduleRenderRecoveryRetry(
        QStringLiteral("Unable to refresh the restored playback state."));
    return;
  }

  const RenderRecovery captured = *render_recovery_;
  commitRenderRecovery(captured, *live_state);
}

std::optional<PlayerController::LivePlaybackState>
PlayerController::readLivePlaybackState() const {
  if (!core_ || !engineReady())
    return std::nullopt;

  int paused = 1;
  int idle = 1;
  int eof_reached = 0;
  double position = 0.0;
  double duration = 0.0;
  if (mpv_get_property(core_->handle(), "pause", MPV_FORMAT_FLAG,
                       &paused) < 0 ||
      mpv_get_property(core_->handle(), "idle-active", MPV_FORMAT_FLAG,
                       &idle) < 0) {
    return std::nullopt;
  }

  std::optional<bool> live_eof_reached;
  if (mpv_get_property(core_->handle(), "eof-reached", MPV_FORMAT_FLAG,
                       &eof_reached) >= 0) {
    live_eof_reached = eof_reached != 0;
  }
  std::optional<double> live_position;
  if (mpv_get_property(core_->handle(), "time-pos", MPV_FORMAT_DOUBLE,
                       &position) >= 0 &&
      std::isfinite(position)) {
    live_position = std::max(0.0, position);
  }
  std::optional<double> live_duration;
  if (mpv_get_property(core_->handle(), "duration", MPV_FORMAT_DOUBLE,
                       &duration) >= 0 &&
      std::isfinite(duration)) {
    live_duration = std::max(0.0, duration);
  }

  return LivePlaybackState{paused != 0, idle != 0, live_eof_reached,
                           live_position, live_duration};
}

bool PlayerController::livePlaybackStateMatchesRecovery(
    const RenderRecovery &recovery,
    const LivePlaybackState &live_state) {
  // Reaching EOF can make mpv pause itself before END_FILE is observable.
  // Likewise, an idle engine is already terminal. Both live terminal states
  // must win over the captured play intent instead of resurrecting playback.
  return live_state.eof_reached.value_or(false) || live_state.idle ||
         live_state.paused == recovery.paused;
}

bool PlayerController::livePlaybackStateMatchesStartupSync(
    const StartupPlaybackSync &startup_sync,
    const LivePlaybackState &live_state) {
  return live_state.eof_reached.value_or(false) || live_state.idle ||
         live_state.paused == startup_sync.intended_paused;
}

void PlayerController::commitRenderRecovery(
    const RenderRecovery &recovery, const LivePlaybackState &live_state) {
  if (!render_recovery_ || !committed_open_)
    return;

  const bool was_playing = playing();
  const bool pause_changed = paused_ != live_state.paused;
  const bool committed_eof =
      live_state.eof_reached.value_or(eof_reached_);
  const double committed_position =
      live_state.position.value_or(recovery.position);
  const bool position_changed =
      !nearlyEqual(position_, committed_position);

  // Assign the complete transport snapshot while recovery still gates mpv
  // observations. Clearing the gate is the final state mutation, so every
  // signal handler observes one internally consistent post-recovery state.
  paused_ = live_state.paused;
  idle_ = live_state.idle;
  eof_reached_ = committed_eof;
  position_ = committed_position;
  selected_video_track_id_ = recovery.video_track_id;
  selected_audio_track_id_ = recovery.audio_track_id;
  selected_subtitle_track_id_ = recovery.subtitle_track_id;
  selected_tracks_playlist_entry_id_ =
      committed_open_->playlist_entry_id;
  current_file_has_audio_track_ = recovery.file_has_audio_track;
  render_recovery_.reset();
  if (live_state.duration)
    updateDuration(*live_state.duration);

  if (pause_changed)
    emit pausedChanged();
  if (position_changed)
    emit positionChanged();
  if (was_playing != playing())
    emit playingChanged();
}

void PlayerController::queueStartupPlaybackSync() {
  if (!startup_playback_sync_ || !committed_open_ || !core_ ||
      startup_playback_sync_->completion_token != 0 ||
      startup_playback_sync_->request_serial != request_serial_ ||
      startup_playback_sync_->playlist_entry_id < 0 ||
      startup_playback_sync_->playlist_entry_id !=
          active_event_playlist_entry_id_) {
    return;
  }

  ++next_startup_playback_sync_token_;
  if (next_startup_playback_sync_token_ == 0)
    ++next_startup_playback_sync_token_;
  const std::uint64_t completion_token =
      next_startup_playback_sync_token_;
  const std::uint64_t request_serial =
      startup_playback_sync_->request_serial;
  const std::uint64_t render_stamp = startup_playback_sync_->render_stamp;
  const std::int64_t playlist_entry_id =
      startup_playback_sync_->playlist_entry_id;
  startup_playback_sync_->completion_token = completion_token;

  QTimer::singleShot(
      0, this,
      [this, completion_token, request_serial, render_stamp,
       playlist_entry_id] {
        finishStartupPlaybackSync(completion_token, request_serial,
                                  render_stamp, playlist_entry_id);
      });
}

void PlayerController::finishStartupPlaybackSync(
    std::uint64_t completion_token, std::uint64_t request_serial,
    std::uint64_t render_stamp, std::int64_t playlist_entry_id) {
  const auto completion_is_current = [this, completion_token, request_serial,
                                      render_stamp, playlist_entry_id] {
    return startup_playback_sync_ && committed_open_ && core_ &&
           startup_playback_sync_->completion_token == completion_token &&
           startup_playback_sync_->request_serial == request_serial &&
           startup_playback_sync_->render_stamp == render_stamp &&
           startup_playback_sync_->playlist_entry_id == playlist_entry_id &&
           committed_open_->request_serial == request_serial &&
           committed_open_->render_stamp == render_stamp &&
           committed_open_->playlist_entry_id == playlist_entry_id &&
           active_event_playlist_entry_id_ == playlist_entry_id &&
           core_->validateRenderTicket({render_stamp});
  };

  if (!completion_is_current())
    return;

  // The one-shot pause/idle transitions for a new file may precede START_FILE.
  // Drain them while startup synchronization still gates observations, then
  // publish a single authoritative snapshot from the live engine.
  drainMpvEvents();
  if (!completion_is_current())
    return;

  startup_playback_sync_->completion_token = 0;
  const auto live_state = readLivePlaybackState();
  const bool live_state_matches =
      live_state && livePlaybackStateMatchesStartupSync(
                        *startup_playback_sync_, *live_state);
  if (!live_state_matches) {
    if (startup_playback_sync_->retry_count < 3) {
      constexpr std::array<int, 3> kRetryDelaysMs{0, 16, 50};
      const int retry_index = startup_playback_sync_->retry_count++;
      QTimer::singleShot(
          kRetryDelaysMs[static_cast<std::size_t>(retry_index)], this,
          [this, request_serial, render_stamp, playlist_entry_id] {
            if (!startup_playback_sync_ || !committed_open_ ||
                startup_playback_sync_->request_serial != request_serial ||
                startup_playback_sync_->render_stamp != render_stamp ||
                startup_playback_sync_->playlist_entry_id !=
                    playlist_entry_id ||
                committed_open_->request_serial != request_serial ||
                committed_open_->render_stamp != render_stamp ||
                committed_open_->playlist_entry_id != playlist_entry_id) {
              return;
            }
            queueStartupPlaybackSync();
          });
      return;
    }

    // pause is set asynchronously. If it is the only value still lagging
    // after the bounded retries, keep the user's synchronous transport intent
    // while retaining the authoritative live idle/timeline snapshot. Dropping
    // that snapshot would lose one-shot startup observations and recreate the
    // stale Play button/duration=0 state this gate exists to prevent.
    if (live_state) {
      reconcileStartupPlaybackSync(*live_state);
      return;
    }

    startup_playback_sync_.reset();
    setLastError(
        QStringLiteral("Unable to synchronize the initial playback state."));
    return;
  }

  commitStartupPlaybackSync(*live_state);
}

void PlayerController::reconcileStartupPlaybackSync(
    const LivePlaybackState &live_state) {
  if (!startup_playback_sync_)
    return;

  LivePlaybackState reconciled_state = live_state;
  const bool terminal = reconciled_state.idle ||
                        reconciled_state.eof_reached.value_or(false);
  if (!terminal)
    reconciled_state.paused = startup_playback_sync_->intended_paused;
  commitStartupPlaybackSync(reconciled_state);
}

void PlayerController::commitStartupPlaybackSync(
    const LivePlaybackState &live_state) {
  if (!startup_playback_sync_ || !committed_open_)
    return;

  const StartupPlaybackSync startup_sync = *startup_playback_sync_;
  const bool was_playing = playing();
  const bool pause_changed = paused_ != live_state.paused;
  const bool committed_eof =
      live_state.eof_reached.value_or(eof_reached_);
  const double committed_position =
      startup_sync.position_overridden
          ? startup_sync.intended_position.value_or(position_)
          : live_state.position.value_or(position_);
  const bool position_changed =
      !nearlyEqual(position_, committed_position);

  paused_ = live_state.paused;
  idle_ = live_state.idle;
  eof_reached_ = committed_eof;
  position_ = committed_position;
  startup_playback_sync_.reset();
  cacheCurrentTrackSelection();
  if (live_state.duration)
    updateDuration(*live_state.duration);

  if (pause_changed)
    emit pausedChanged();
  if (position_changed)
    emit positionChanged();
  if (was_playing != playing())
    emit playingChanged();
}

void PlayerController::scheduleRenderRecoveryRetry(const QString &error) {
  if (!render_recovery_ || !core_)
    return;
  render_recovery_->restore_failure = error;
  if (render_recovery_->restore_retry_queued)
    return;
  if (render_recovery_->restore_retry_count >= 3) {
    degradeRenderRecovery(error);
    return;
  }

  constexpr std::array<int, 3> kRetryDelaysMs{0, 16, 50};
  const int retry_index = render_recovery_->restore_retry_count++;
  render_recovery_->restore_retry_queued = true;
  const std::uint64_t request_serial = render_recovery_->request_serial;
  const std::uint64_t render_stamp =
      render_recovery_->accepted_render_stamp;
  QTimer::singleShot(
      kRetryDelaysMs[static_cast<std::size_t>(retry_index)], this,
      [this, request_serial, render_stamp] {
        if (!render_recovery_ ||
            render_recovery_->request_serial != request_serial ||
            render_recovery_->accepted_render_stamp != render_stamp) {
          return;
        }
        render_recovery_->restore_retry_queued = false;
        restoreRenderRecovery();
      });
}

void PlayerController::degradeRenderRecovery(const QString &error) {
  if (!render_recovery_)
    return;
  const RenderRecovery recovery = *render_recovery_;
  render_recovery_.reset();
  render_recovery_attempt_.reset();

  if (core_ && engineReady()) {
    int paused = recovery.paused ? 1 : 0;
    static_cast<void>(
        mpv_set_property(core_->handle(), "pause", MPV_FORMAT_FLAG, &paused));

    int live_paused = paused;
    if (mpv_get_property(core_->handle(), "pause", MPV_FORMAT_FLAG,
                         &live_paused) >= 0) {
      updatePause(live_paused != 0);
    } else {
      updatePause(recovery.paused);
    }

    int live_idle = 0;
    if (mpv_get_property(core_->handle(), "idle-active", MPV_FORMAT_FLAG,
                         &live_idle) >= 0) {
      updateIdle(live_idle != 0);
    }

    double live_position = 0.0;
    if (mpv_get_property(core_->handle(), "time-pos", MPV_FORMAT_DOUBLE,
                         &live_position) >= 0 &&
        std::isfinite(live_position)) {
      const double value = std::max(0.0, live_position);
      if (!nearlyEqual(position_, value)) {
        position_ = value;
        emit positionChanged();
      }
    }
    cacheCurrentTrackSelection();
  }
  setLastError(error);
}

void PlayerController::abandonPendingOpen() {
  requested_source_ = source_;
  observed_current_path_ = !source_.isEmpty();
  pending_source_.clear();
  pending_request_serial_ = 0;
  open_attempt_.reset();
  render_recovery_.reset();
  render_recovery_attempt_.reset();
  if (committed_open_ && !requested_source_.isEmpty()) {
    // The previous source remains authoritative when a replacement command
    // could not be accepted. Associate it with the now-current request serial
    // so a later scene-graph loss still recovers that visible media.
    committed_open_->request_serial = request_serial_;
  } else {
    committed_open_.reset();
  }
  requestVideoUpdate();
}

void PlayerController::handleRenderInvalidated(
    std::uint64_t retired_render_stamp) {
  if (requested_source_.isEmpty())
    return;

  bool needs_retry = false;
  if (open_attempt_ &&
      open_attempt_->request_serial == pending_request_serial_ &&
      open_attempt_->render_stamp == retired_render_stamp) {
    // The command reply may still arrive, but it belongs to the retired
    // generation. Keeping the source pending lets the next Ready ticket
    // supersede it without waiting or taking the render lock.
    open_attempt_.reset();
    needs_retry = true;
  }

  const bool retired_recovery_attempt =
      render_recovery_attempt_ &&
      render_recovery_attempt_->request_serial == request_serial_ &&
      render_recovery_attempt_->render_stamp == retired_render_stamp;
  const bool retired_committed_output =
      committed_open_ &&
      committed_open_->request_serial == request_serial_ &&
      committed_open_->render_stamp == retired_render_stamp;

  if (retired_recovery_attempt || retired_committed_output) {
    std::optional<bool> startup_paused_intent;
    std::optional<double> startup_position;
    bool startup_terminal_state = false;
    if (startup_playback_sync_ &&
        startup_playback_sync_->request_serial == request_serial_ &&
        startup_playback_sync_->render_stamp == retired_render_stamp) {
      // Startup deliberately gates the controller's default pause/timeline
      // cache. Transfer its engine-derived/user-updated intent before render
      // recovery takes ownership, and sample a newer live position when one is
      // still available during teardown.
      const StartupPlaybackSync startup_sync = *startup_playback_sync_;
      startup_paused_intent = startup_sync.intended_paused;
      if (startup_sync.position_overridden)
        startup_position = startup_sync.intended_position;
      if (const auto live_state = readLivePlaybackState()) {
        startup_terminal_state =
            !startup_sync.position_overridden &&
            (live_state->idle ||
             live_state->eof_reached.value_or(false));
        if (!startup_sync.position_overridden)
          startup_position = live_state->position;
        if (startup_terminal_state)
          startup_paused_intent = true;
        updateIdle(live_state->idle);
        if (live_state->eof_reached)
          updateEof(*live_state->eof_reached);
        if (live_state->duration)
          updateDuration(*live_state->duration);
      }
      startup_playback_sync_.reset();
    }

    if (!render_recovery_ ||
        render_recovery_->request_serial != request_serial_) {
      const bool cached_tracks_are_current =
          committed_open_ && committed_open_->playlist_entry_id >= 0 &&
          selected_tracks_playlist_entry_id_ ==
              committed_open_->playlist_entry_id;
      const bool snapshot_proven =
          cached_tracks_are_current &&
          current_file_has_audio_track_.has_value();
      std::int64_t video_track =
          cached_tracks_are_current ? selected_video_track_id_ : -1;
      std::int64_t audio_track =
          cached_tracks_are_current ? selected_audio_track_id_ : -1;
      std::int64_t subtitle_track =
          cached_tracks_are_current ? selected_subtitle_track_id_ : -1;
      if (engineReady()) {
        const std::int64_t current_video =
            currentTrackId(core_->handle(), "vid");
        const std::int64_t current_audio =
            currentTrackId(core_->handle(), "aid");
        const std::int64_t current_subtitle =
            currentTrackId(core_->handle(), "sid");
        if (current_video > 0)
          video_track = current_video;
        if (current_audio > 0)
          audio_track = current_audio;
        if (current_subtitle > 0)
          subtitle_track = current_subtitle;
      }

      const bool has_audio_track =
          current_file_has_audio_track_.value_or(audio_track > 0);
      RenderRecoveryMode mode = snapshot_proven
                                    ? RenderRecoveryMode::NoReselection
                                    : RenderRecoveryMode::FullReload;
      if (snapshot_proven && video_track > 0) {
        // A selected audio track keeps the file alive while the VO is
        // reselected. Merely having an audio track is not enough when aid=no.
        mode = has_audio_track && audio_track > 0
                   ? RenderRecoveryMode::VideoReselect
                   : RenderRecoveryMode::FullReload;
      }
      RenderRecovery recovery;
      recovery.request_serial = request_serial_;
      recovery.position = std::max(
          0.0, startup_position.value_or(position_));
      recovery.paused = startup_paused_intent.value_or(paused_);
      recovery.mode = mode;
      recovery.video_track_id = video_track;
      recovery.audio_track_id = audio_track;
      recovery.subtitle_track_id = subtitle_track;
      recovery.file_has_audio_track = has_audio_track;
      recovery.track_snapshot_proven = snapshot_proven;
      recovery.external_subtitles = attached_subtitle_files_;
      recovery.reload_source = committed_entry_source_;
      recovery.playlist_position = committed_playlist_position_;
      if (engineReady() && committed_open_) {
        const std::int64_t live_position = playlistPositionForEntry(
            core_->handle(), committed_open_->playlist_entry_id);
        if (live_position >= 0)
          recovery.playlist_position = live_position;
        recovery.preserve_playlist_context =
            playlistEntryCount(core_->handle()) > 1;
      }
      recovery.preserve_playlist_context =
          recovery.preserve_playlist_context || !redirect_ranges_.empty();
      render_recovery_ = std::move(recovery);
    } else {
      render_recovery_->accepted_render_stamp = 0;
      render_recovery_->command_failed = false;
      render_recovery_->file_loaded = false;
      render_recovery_->playback_restarted = false;
      render_recovery_->external_subtitles_restored = false;
      render_recovery_->external_subtitles_restored_count = 0;
      render_recovery_->per_file_state_restored = false;
      render_recovery_->transport_restored = false;
      render_recovery_->completion_token = 0;
      render_recovery_->restore_retry_count = 0;
      render_recovery_->restore_retry_queued = false;
      render_recovery_->restore_failure.clear();
    }

    render_recovery_attempt_.reset();
    if (committed_open_)
      committed_open_->render_stamp = 0;
    needs_retry = true;
  }

  if (needs_retry)
    continuePendingOpen();
}

void PlayerController::handleRenderInitializationFailure(
    const QString &error, std::uint64_t render_stamp) {
  if (!core_ || (pending_source_.isEmpty() && !render_recovery_) ||
      !core_->renderFailureIsCurrent({render_stamp}) ||
      render_stamp == last_reported_render_failure_stamp_) {
    return;
  }
  last_reported_render_failure_stamp_ = render_stamp;
  setLastError(error);
}

void PlayerController::attachVideoItem(MpvVideoItem *item) {
  video_item_ = item;
  if (needsRenderContext())
    requestVideoUpdate();
}

void PlayerController::detachVideoItem(MpvVideoItem *item) {
  if (video_item_ == item)
    video_item_.clear();
}

std::shared_ptr<PlayerCore> PlayerController::coreForRendering() const {
  return core_;
}

void PlayerController::updatePause(bool paused) {
  const bool was_playing = playing();
  if (paused_ != paused) {
    paused_ = paused;
    emit pausedChanged();
  }
  if (was_playing != playing())
    emit playingChanged();
}

void PlayerController::updateIdle(bool idle) {
  const bool was_playing = playing();
  if (idle_ == idle)
    return;
  idle_ = idle;
  if (was_playing != playing())
    emit playingChanged();
}

void PlayerController::updateEof(bool eof_reached) {
  const bool was_playing = playing();
  if (eof_reached_ == eof_reached)
    return;
  eof_reached_ = eof_reached;
  if (was_playing != playing())
    emit playingChanged();
}

void PlayerController::updateSource(const QUrl &source) {
  if (captioning_) {
    const auto current = localPath(source);
    if (!current || caption_input_.empty() ||
        !pathsReferToSameFile(caption_input_, *current)) {
      cancelCaptionsForMediaChange();
    }
  }

  const bool had_media = hasMedia();
  if (source_ == source)
    return;
  source_ = source;
  emit sourceChanged();
  if (had_media != hasMedia()) {
    emit hasMediaChanged();
    requestVideoUpdate();
  }
}

void PlayerController::updateMediaTitle(const QString &title) {
  if (media_title_ == title)
    return;
  media_title_ = title;
  emit mediaTitleChanged();
}

void PlayerController::resetTimeline() {
  if (!nearlyEqual(position_, 0.0)) {
    position_ = 0.0;
    emit positionChanged();
  }
  if (!nearlyEqual(duration_, 0.0)) {
    duration_ = 0.0;
    emit durationChanged();
  }
  if (!nearlyEqual(trim_in_, 0.0)) {
    trim_in_ = 0.0;
    emit trimInChanged();
  }
  if (!nearlyEqual(trim_out_, 0.0)) {
    trim_out_ = 0.0;
    emit trimOutChanged();
  }
}

void PlayerController::cancelCaptionsForMediaChange() {
  if (!captioning_)
    return;
  caption_cancel_reason_ =
      QStringLiteral("Caption generation stopped because the media changed.");
  caption_service_.cancel();
  setCaptionStatus(QStringLiteral("Stopping caption generation…"));
}

void PlayerController::setLastError(const QString &error) {
  if (!error.isEmpty())
    qWarning().noquote() << "WAM:" << error;
  if (last_error_ == error) {
    // Error dialogs are action feedback, not merely state reflection. Emit
    // again so retrying an invalid operation never fails silently.
    if (!error.isEmpty())
      emit lastErrorChanged();
    return;
  }
  last_error_ = error;
  emit lastErrorChanged();
}

} // namespace wam::qt
