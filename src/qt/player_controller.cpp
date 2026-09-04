#include "player_controller.hpp"

#include "mpv_video_item.hpp"
#include "playback_policy.hpp"
#include "player_core_p.hpp"
#include "subtitle_bitmap_provider.hpp"
#include "subtitle_sources.hpp"

#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
#include "native_benchmark_telemetry.hpp"
#include "native_playback_owner.hpp"
#include "platform/macos/native_layer_presentation_state.hpp"
#endif

#include <QByteArray>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#if !defined(Q_OS_MACOS) || !defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
#include <QStorageInfo>
#endif
#include <QThread>
#include <QTimer>

#include <algorithm>
#include <array>
#include <cmath>
#include <cwctype>
#include <exception>
#include <filesystem>
#include <limits>
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

#if defined(Q_OS_MACOS) && !defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
#include <sys/mount.h>
#endif

namespace wam::qt {
namespace {

using ::wam::playback::mpv::MpvApi;

constexpr double kMinimumRate = 0.0625;
constexpr double kMaximumRate = 16.0;
constexpr double kScrubConvergenceToleranceSeconds = 0.050;
constexpr int kScrubSeekTimeoutMs = 750;

// Volume runs past unity into VLC-style amplification. 4.0 is the ABSOLUTE
// ceiling on every route: the native gain stage clamps there (and saturates
// each sample to [-1, 1]), and mpv is started with volume-max=400. How much
// of that ceiling any window may actually reach is the per-installation
// "Maximum volume" preference (maximum_volume_, default 200%), which is
// always inside this range and is what setVolume clamps to.
constexpr double kMinimumVolume = 0.0;
constexpr double kMaximumVolume = ScrollGestureModel::kAbsoluteMaximumVolume;
// The lowest the maximum-volume setting may be put: 100%, i.e. no
// amplification at all. Unity always stays reachable.
constexpr double kMinimumMaximumVolume = ScrollGestureModel::kDetentValue;

// How long after the last wheel delta a pointer-scroll gesture counts as
// settled. It ends the axis lock and commits a timeline sweep. 200 ms is long
// enough to ride out a trackpad momentum tail's own gaps and short enough that
// a deliberate flick commits before the user reaches for anything else.
constexpr int kScrollSettleMs = 200;
constexpr std::uint64_t kCommandReplyNamespaceMask = 3ULL << 62;
constexpr std::uint64_t kOpenCommandReplyNamespace = 1ULL << 63;
constexpr std::uint64_t kRenderRecoveryCommandReplyNamespace = 1ULL << 62;
constexpr std::uint64_t kCommandReplyIdMask = ~kCommandReplyNamespaceMask;
constexpr std::uint64_t kScrubCommandReplyTag =
    kOpenCommandReplyNamespace | (1ULL << 61);
constexpr std::uint64_t kOpenCommandReplyIdMask = (1ULL << 61) - 1ULL;
constexpr std::uint64_t kScrubCommandReplyIdMask = kOpenCommandReplyIdMask;
constexpr std::uint64_t kScrubCommandReplyMask =
    kCommandReplyNamespaceMask | (1ULL << 61);
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
constexpr std::uint64_t kFallbackStopCommandReplyNamespace = 3ULL << 62;
#endif

static_assert((kOpenCommandReplyNamespace & kScrubCommandReplyMask) !=
              kScrubCommandReplyTag);
static_assert((kRenderRecoveryCommandReplyNamespace &
               kCommandReplyNamespaceMask) !=
              (kScrubCommandReplyTag & kCommandReplyNamespaceMask));
static_assert((3ULL << 62) !=
              (kScrubCommandReplyTag & kCommandReplyNamespaceMask));

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

#if !defined(Q_OS_MACOS) || !defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  const QString local_path = source.toLocalFile();
  const QStorageInfo storage(local_path);
  if (storage.isValid() &&
      isRemoteFilesystemType(storage.fileSystemType().toStdString())) {
    return PlaybackSourceClass::BufferedLocal;
  }
#endif

#if defined(Q_OS_MACOS) && !defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
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

struct ReadyMpvClient final {
  const MpvApi *api = nullptr;
  mpv_handle *handle = nullptr;

  [[nodiscard]] explicit operator bool() const noexcept {
    return api != nullptr && handle != nullptr;
  }
};

[[nodiscard]] ReadyMpvClient readyMpvClient(PlayerCore *core) noexcept {
  if (!core)
    return {};
  const MpvApi *const api = core->readyApi();
  mpv_handle *const handle = core->handle();
  return api && handle ? ReadyMpvClient{api, handle} : ReadyMpvClient{};
}

[[nodiscard]] QString mpvErrorDetail(PlayerCore *core, int error) {
  const ReadyMpvClient client = readyMpvClient(core);
  if (client) {
    if (const char *const detail = client.api->mpv_error_string(error))
      return QString::fromUtf8(detail);
  }
  return QStringLiteral("media-engine error %1").arg(error);
}

bool setPlaybackProperty(PlayerCore *core, const char *name,
                         const char *value) {
  const ReadyMpvClient client = readyMpvClient(core);
  if (!client)
    return false;
  const int result =
      client.api->mpv_set_property_string(client.handle, name, value);
  if (result >= 0)
    return true;
  qWarning().nospace() << "WAM: unable to set playback policy property " << name
                       << '=' << value << ": "
                       << client.api->mpv_error_string(result);
  return false;
}

void applyPlaybackBufferPolicy(PlayerCore *core,
                               PlaybackSourceClass source_class) {
  const PlaybackBufferPolicy policy = playbackBufferPolicy(source_class);
  setPlaybackProperty(core, "cache", policy.cache_mode);
  setPlaybackProperty(core, "cache-secs", policy.cache_seconds);
  setPlaybackProperty(core, "demuxer-readahead-secs", policy.readahead_seconds);
  setPlaybackProperty(core, "demuxer-max-bytes", policy.forward_bytes);
  setPlaybackProperty(core, "demuxer-max-back-bytes", policy.backward_bytes);
  setPlaybackProperty(core, "demuxer-hysteresis-secs",
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

int sendCommand(PlayerCore *core,
                const std::initializer_list<QByteArray> &arguments,
                std::uint64_t reply_userdata = 0) {
  if (arguments.size() == 0)
    return MPV_ERROR_INVALID_PARAMETER;
  const ReadyMpvClient client = readyMpvClient(core);
  if (!client)
    return MPV_ERROR_INVALID_PARAMETER;
  std::vector<const char *> argv;
  argv.reserve(arguments.size() + 1);
  for (const QByteArray &argument : arguments)
    argv.push_back(argument.constData());
  argv.push_back(nullptr);
  return client.api->mpv_command_async(client.handle, reply_userdata,
                                       argv.data());
}

bool setCoreProperty(PlayerCore *core, const char *name, mpv_format format,
                     void *value) {
  const ReadyMpvClient client = readyMpvClient(core);
  if (!client)
    return false;
  const int result =
      client.api->mpv_set_property(client.handle, name, format, value);
  if (result >= 0)
    return true;
  qWarning().nospace() << "WAM: unable to restore media-engine property "
                       << name << ": " << client.api->mpv_error_string(result);
  return false;
}

// The name one entry of the Subtitles menu carries. VLC-shaped: what the
// container says the track IS, not what index it happens to occupy.
QString subtitleLanguageName(const QString &code) {
  if (code.isEmpty() || code == QStringLiteral("und"))
    return {};
  // QLocale understands both ISO 639-1 and 639-2 codes, which is every form a
  // Matroska Language or an mpv `lang` field arrives in.
  const QLocale locale(code);
  if (locale.language() != QLocale::C &&
      locale.language() != QLocale::AnyLanguage) {
    return QLocale::languageToString(locale.language());
  }
  return code.toUpper();
}

QString subtitleSourceLabel(SubtitleSources::Origin origin,
                            const QString &title, const QString &language,
                            const std::filesystem::path &path,
                            std::int64_t ordinal) {
  switch (origin) {
    case SubtitleSources::Origin::Generated:
      return QStringLiteral("Generated Captions");
    case SubtitleSources::Origin::External: {
      const QString name =
          path.empty() ? QString()
                       : QString::fromStdString(path.filename().string());
      return name.isEmpty() ? QStringLiteral("Loaded Subtitles") : name;
    }
    case SubtitleSources::Origin::Embedded:
      break;
  }
  // A track Name is the only field an author writes for a human to read
  // ("English (SDH)", "Forced Narrative"), so it wins outright when present.
  const QString trimmed = title.trimmed();
  if (!trimmed.isEmpty())
    return trimmed;
  const QString languageName = subtitleLanguageName(language);
  if (!languageName.isEmpty())
    return languageName;
  return QStringLiteral("Track %1").arg(ordinal);
}

bool setTrackSelection(PlayerCore *core, const char *name,
                       std::int64_t selection) {
  if (selection < 0)
    return true;
  const ReadyMpvClient client = readyMpvClient(core);
  if (!client)
    return false;
  if (selection == 0) {
    const int result =
        client.api->mpv_set_property_string(client.handle, name, "no");
    if (result >= 0)
      return true;
    qWarning().nospace() << "WAM: unable to restore media-engine property "
                         << name
                         << "=no: " << client.api->mpv_error_string(result);
    return false;
  }
  std::int64_t value = selection;
  return setCoreProperty(core, name, MPV_FORMAT_INT64, &value);
}

std::int64_t playlistEntryIdAtPosition(PlayerCore *core,
                                       const char *position_property) {
  const ReadyMpvClient client = readyMpvClient(core);
  if (!client)
    return -1;
  std::int64_t playlist_position = -1;
  std::int64_t entry_id = -1;
  if (client.api->mpv_get_property(client.handle, position_property,
                                   MPV_FORMAT_INT64, &playlist_position) < 0 ||
      playlist_position < 0) {
    return -1;
  }
  const QByteArray property = QByteArrayLiteral("playlist/") +
                              QByteArray::number(playlist_position) +
                              QByteArrayLiteral("/id");
  if (client.api->mpv_get_property(client.handle, property.constData(),
                                   MPV_FORMAT_INT64, &entry_id) < 0) {
    return -1;
  }
  return entry_id;
}

std::int64_t currentPlaylistEntryId(PlayerCore *core) {
  return playlistEntryIdAtPosition(core, "playlist-pos");
}

std::int64_t playingPlaylistEntryId(PlayerCore *core) {
  return playlistEntryIdAtPosition(core, "playlist-playing-pos");
}

std::int64_t playlistEntryCount(PlayerCore *core) {
  const ReadyMpvClient client = readyMpvClient(core);
  if (!client)
    return 0;
  std::int64_t count = 0;
  if (client.api->mpv_get_property(client.handle, "playlist/count",
                                   MPV_FORMAT_INT64, &count) < 0) {
    return 0;
  }
  return std::max<std::int64_t>(0, count);
}

std::int64_t playlistPositionForEntry(PlayerCore *core, std::int64_t entry_id) {
  if (entry_id < 0)
    return -1;
  const ReadyMpvClient client = readyMpvClient(core);
  if (!client)
    return -1;
  const std::int64_t count = playlistEntryCount(core);
  for (std::int64_t index = 0; index < count; ++index) {
    const QByteArray property = QByteArrayLiteral("playlist/") +
                                QByteArray::number(index) +
                                QByteArrayLiteral("/id");
    std::int64_t candidate_id = -1;
    if (client.api->mpv_get_property(client.handle, property.constData(),
                                     MPV_FORMAT_INT64, &candidate_id) >= 0 &&
        candidate_id == entry_id) {
      return index;
    }
  }
  return -1;
}

QUrl playlistEntrySource(PlayerCore *core, std::int64_t entry_id) {
  if (entry_id < 0)
    return {};
  const ReadyMpvClient client = readyMpvClient(core);
  if (!client)
    return {};
  const std::int64_t count = playlistEntryCount(core);
  for (std::int64_t index = 0; index < count; ++index) {
    const QByteArray prefix =
        QByteArrayLiteral("playlist/") + QByteArray::number(index);
    const QByteArray id_property = prefix + QByteArrayLiteral("/id");
    std::int64_t candidate_id = -1;
    if (client.api->mpv_get_property(client.handle, id_property.constData(),
                                     MPV_FORMAT_INT64, &candidate_id) < 0 ||
        candidate_id != entry_id) {
      continue;
    }
    const QByteArray filename_property =
        prefix + QByteArrayLiteral("/filename");
    char *filename = client.api->mpv_get_property_string(
        client.handle, filename_property.constData());
    if (!filename)
      return {};
    const QUrl source = urlFromMpvPath(QString::fromUtf8(filename));
    client.api->mpv_free(filename);
    return source;
  }
  return {};
}

std::int64_t currentVideoTrackId(PlayerCore *core) {
  const ReadyMpvClient client = readyMpvClient(core);
  if (!client)
    return -1;
  std::int64_t track_id = -1;
  if (client.api->mpv_get_property(client.handle, "vid", MPV_FORMAT_INT64,
                                   &track_id) < 0 ||
      track_id <= 0) {
    return -1;
  }
  return track_id;
}

std::int64_t currentTrackId(PlayerCore *core, const char *name) {
  const ReadyMpvClient client = readyMpvClient(core);
  if (!client)
    return -1;
  std::int64_t track_id = -1;
  if (client.api->mpv_get_property(client.handle, name, MPV_FORMAT_INT64,
                                   &track_id) < 0 ||
      track_id <= 0) {
    return -1;
  }
  return track_id;
}

std::int64_t currentTrackSelection(PlayerCore *core, const char *name) {
  const ReadyMpvClient client = readyMpvClient(core);
  if (!client)
    return -1;
  char *selection = client.api->mpv_get_property_string(client.handle, name);
  if (!selection)
    return -1;
  const QString value = QString::fromUtf8(selection).trimmed();
  client.api->mpv_free(selection);
  if (value.compare(QStringLiteral("no"), Qt::CaseInsensitive) == 0)
    return 0;
  bool valid = false;
  const qlonglong numeric = value.toLongLong(&valid);
  return valid && numeric > 0 ? static_cast<std::int64_t>(numeric) : -1;
}

// mpv's display rectangle, read as one pair. dwidth/dheight are the picture
// size after the container's aspect ratio and any rotation have been applied,
// which is the size a window should be shaped to -- not the coded size, which
// is wrong for anamorphic video and wrong for a portrait phone clip. An empty
// QSize means mpv has no picture yet (no file, audio-only, or the video chain
// has not been reconfigured), which is exactly the "unknown" the caller wants.
QSize currentVideoDisplaySize(PlayerCore *core) {
  const ReadyMpvClient client = readyMpvClient(core);
  if (!client)
    return {};
  std::int64_t width = 0;
  std::int64_t height = 0;
  if (client.api->mpv_get_property(client.handle, "dwidth", MPV_FORMAT_INT64,
                                   &width) < 0 ||
      client.api->mpv_get_property(client.handle, "dheight", MPV_FORMAT_INT64,
                                   &height) < 0) {
    return {};
  }
  // Bounded on the way in rather than trusted: these become a window size.
  constexpr std::int64_t kMaximumDisplayEdge = 65535;
  if (width <= 0 || height <= 0 || width > kMaximumDisplayEdge ||
      height > kMaximumDisplayEdge) {
    return {};
  }
  return QSize(static_cast<int>(width), static_cast<int>(height));
}

std::optional<bool> currentFileHasTrackType(PlayerCore *core,
                                            const char *type) {
  const ReadyMpvClient client = readyMpvClient(core);
  if (!client)
    return std::nullopt;
  std::int64_t count = 0;
  if (client.api->mpv_get_property(client.handle, "track-list/count",
                                   MPV_FORMAT_INT64, &count) < 0 ||
      count <= 0) {
    return std::nullopt;
  }
  for (std::int64_t index = 0; index < count; ++index) {
    const QByteArray property = QByteArrayLiteral("track-list/") +
                                QByteArray::number(index) +
                                QByteArrayLiteral("/type");
    char *track_type = client.api->mpv_get_property_string(
        client.handle, property.constData());
    if (!track_type)
      continue;
    const bool matches = QByteArray(track_type) == type;
    client.api->mpv_free(track_type);
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
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  native_playback_ = std::make_unique<NativePlaybackOwner>(*this);
  // Playing media is a user-initiated activity even when WAM is not the
  // frontmost application. Track the transport with the platform assertion so
  // the display never idle-sleeps into the screen saver over playing video and
  // so App Nap never throttles an occluded or background playback session. The
  // signal is the single choke point for every transport source: native route,
  // compatibility route, end of file and idle.
  connect(this, &PlayerController::playingChanged, this, [this] {
    // One hold per controller, and the process-wide assertion is a reference
    // count over those holds (see native_playback_owner.mm). Edge-triggering
    // here is what makes each window contribute at most one: with N windows
    // playing, a pause in one must not end the assertion the other N-1 still
    // need, and a bare boolean latch did exactly that.
    const bool holding = playing();
    if (holding == macos_activity_held_)
      return;
    macos_activity_held_ = holding;
    setMacosPlaybackActivityHeld(holding);
  });
#endif
  work_timer_ = new QTimer(this);
  work_timer_->setInterval(100);
  work_timer_->setTimerType(Qt::CoarseTimer);
  connect(work_timer_, &QTimer::timeout, this,
          &PlayerController::pollBackgroundWork);

  // Scrubbing can issue many commands over one pointer gesture. Reusing one
  // timer avoids allocating a lambda/timer event for every command and makes
  // stale timeout ownership explicit when the capacity-one slot is rearmed.
  scrub_timeout_timer_ = new QTimer(this);
  scrub_timeout_timer_->setSingleShot(true);
  scrub_timeout_timer_->setTimerType(Qt::PreciseTimer);
  connect(scrub_timeout_timer_, &QTimer::timeout, this, [this] {
    const std::uint64_t gesture = scrub_timeout_gesture_;
    const std::uint64_t request_serial = scrub_timeout_request_serial_;
    const std::uint64_t command = scrub_timeout_command_;
    cancelScrubTimeout();
    handleScrubTimeout(gesture, request_serial, command);
  });

  // One reused single-shot timer for the whole scroll-gesture lifetime, for
  // the same reason as the scrub timeout above: a momentum tail can restart
  // it a hundred times a second.
  scroll_settle_timer_ = new QTimer(this);
  scroll_settle_timer_->setSingleShot(true);
  scroll_settle_timer_->setTimerType(Qt::PreciseTimer);
  connect(scroll_settle_timer_, &QTimer::timeout, this,
          &PlayerController::settleScrollGesture);

  // The subtitle lane. Parented to this controller, so it is per window like
  // everything else the user can change, and destroyed with it (its destructor
  // cancels and joins any load in flight before anything it captures dies).
  subtitles_ = std::make_unique<SubtitleSources>(this);
  connect(subtitles_.get(), &SubtitleSources::cuesChanged, this,
          [this] { updateSubtitleForPosition(); });
  connect(subtitles_.get(), &SubtitleSources::loadFailed, this,
          [this](const QString &reason) { setLastNotice(reason); });
  // One connection instead of a call at each of the eight sites that move the
  // playhead: every route, every seek and every rate publishes through
  // positionChanged, so this cannot be forgotten by a later change. It costs
  // two comparisons per position update and emits only when the line changes,
  // so it never dirties the scene graph between cue boundaries.
  connect(this, &PlayerController::positionChanged, this,
          [this] { updateSubtitleForPosition(); });
}

PlayerController::~PlayerController() {
  cancelScrubTimeout();
  if (scroll_settle_timer_)
    scroll_settle_timer_->stop();
  scroll_sweep_target_.reset();
  if (work_timer_)
    work_timer_->stop();
  export_job_.cancel();
  export_job_.wait();
  cleanupExportStaging();
  caption_service_.cancel();
  caption_service_.wait();
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  native_playback_.reset();
  if (macos_activity_held_) {
    macos_activity_held_ = false;
    setMacosPlaybackActivityHeld(false);
  }
#endif
  if (core_)
    core_->detachOwner(this);
  core_.reset();
}

bool PlayerController::provisionMpvFallbackRuntime(
    std::shared_ptr<const ::wam::playback::mpv::MpvRuntime> runtime) {
  Q_ASSERT(QThread::currentThread() == thread());
  if (!runtime || !runtime->api().complete() || engineReady() ||
      fallback_runtime_) {
    return false;
  }
  fallback_runtime_ = std::move(runtime);
  return true;
}

bool PlayerController::available() const {
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  // Native playback remains available even when the optional compatibility
  // engine is dormant or a bundle-local fallback failed to initialize.
  return native_playback_ != nullptr;
#else
  return core_ && !core_->failed();
#endif
}

bool PlayerController::engineReady() const { return core_ && core_->ready(); }

bool PlayerController::initializePlaybackEngine() {
  if (engineReady())
    return true;
  if (!core_ || !fallback_runtime_) {
    setLastError(QStringLiteral(
        "The compatibility media engine has not been selected."));
    return false;
  }
  const bool was_available = available();
  if (!core_->initialize(fallback_runtime_)) {
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
  const MpvApi &api = core_->api();

  // Restore cached UI settings synchronously before observing properties.
  // This prevents mpv's defaults from briefly overwriting the saved state on
  // the first file open.
  double engine_volume = volume_ * 100.0;
  double engine_rate = rate_;
  int engine_muted = muted_ ? 1 : 0;
  int engine_preserve_pitch = preserve_pitch_ ? 1 : 0;
  setCoreProperty(core_.get(), "volume", MPV_FORMAT_DOUBLE, &engine_volume);
  setCoreProperty(core_.get(), "speed", MPV_FORMAT_DOUBLE, &engine_rate);
  setCoreProperty(core_.get(), "mute", MPV_FORMAT_FLAG, &engine_muted);
  // WAM draws subtitles itself, in one overlay, so that a line looks the same
  // whichever engine is playing -- and so that the native route, which has no
  // mpv at all, is not a second-class surface. mpv's own renderer is therefore
  // pinned off for the life of the handle. It keeps selecting, decoding and
  // TIMING subtitles with this off (verified: `sub-text` updates normally at
  // sub-visibility=no), which is exactly the division of labour wanted: mpv
  // owns the timeline it already understands, WAM owns the pixels.
  int engine_subtitles_hidden = 0;
  setCoreProperty(core_.get(), "sub-visibility", MPV_FORMAT_FLAG,
                  &engine_subtitles_hidden);
  setCoreProperty(core_.get(), "audio-pitch-correction", MPV_FORMAT_FLAG,
                  &engine_preserve_pitch);

  const auto observe = [&api, handle](ObservedProperty id, const char *name,
                                      mpv_format format) {
    api.mpv_observe_property(handle, static_cast<uint64_t>(id), name, format);
  };
  observe(ObservedProperty::Pause, "pause", MPV_FORMAT_FLAG);
  observe(ObservedProperty::Idle, "idle-active", MPV_FORMAT_FLAG);
  observe(ObservedProperty::Position, "time-pos", MPV_FORMAT_DOUBLE);
  observe(ObservedProperty::Duration, "duration", MPV_FORMAT_DOUBLE);
  observe(ObservedProperty::Volume, "volume", MPV_FORMAT_DOUBLE);
  observe(ObservedProperty::Mute, "mute", MPV_FORMAT_FLAG);
  observe(ObservedProperty::Rate, "speed", MPV_FORMAT_DOUBLE);
  // sub-visibility is deliberately NOT observed: it is pinned off above and is
  // no longer the user's caption switch. captionsVisible now means "a subtitle
  // source is selected", which is app state on both routes.
  observe(ObservedProperty::Path, "path", MPV_FORMAT_STRING);
  observe(ObservedProperty::MediaTitle, "media-title", MPV_FORMAT_STRING);
  observe(ObservedProperty::PreservePitch, "audio-pitch-correction",
          MPV_FORMAT_FLAG);
  observe(ObservedProperty::EofReached, "eof-reached", MPV_FORMAT_FLAG);
  observe(ObservedProperty::VideoTrack, "vid", MPV_FORMAT_STRING);
  observe(ObservedProperty::AudioTrack, "aid", MPV_FORMAT_STRING);
  observe(ObservedProperty::SubtitleTrack, "sid", MPV_FORMAT_STRING);
  observe(ObservedProperty::SubtitleText, "sub-text", MPV_FORMAT_STRING);
  observe(ObservedProperty::TrackListCount, "track-list/count",
          MPV_FORMAT_INT64);
  // Display, not coded: mpv's dwidth/dheight are the picture's on-screen
  // rectangle with the container's aspect ratio and rotation already applied,
  // which is exactly what window geometry needs and exactly what
  // MacWindowChrome's AVURLAsset probe cannot supply for Matroska/WebM/MPEG-TS.
  observe(ObservedProperty::DisplayWidth, "dwidth", MPV_FORMAT_INT64);
  observe(ObservedProperty::DisplayHeight, "dheight", MPV_FORMAT_INT64);
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
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  if (!native_playback_)
    return false;
  // Burn pointer/preview completion ownership before the owner drains any
  // observations from the retiring source. A late exact presentation from
  // that source must not become visible during the replacement transaction.
  invalidateNativeSeekIntents();
  // A blank player follows the existing mpv behavior and starts a newly
  // opened file. Replacements retain the user's current pause intent.
  const bool intended_paused = hasMedia() ? paused_ : false;
  return native_playback_->open(source, 0.0, intended_paused);
#else
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

  finishScrubGesture(true);

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
#endif
}

#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
void PlayerController::prepareRoutedOpenIntent(const QUrl &source) {
  invalidateNativeSeekIntents();
  if (captioning_) {
    const auto incoming = localPath(displayUrlForSource(source));
    if (!incoming || caption_input_.empty() ||
        !pathsReferToSameFile(caption_input_, *incoming)) {
      cancelCaptionsForMediaChange();
    }
  }

  finishScrubGesture(true);
  updateEof(false);
  resetTimeline();

  ++request_serial_;
  if (request_serial_ == 0)
    ++request_serial_;
  requested_source_ = source;
  pending_source_.clear();
  pending_request_serial_ = 0;
  open_attempt_.reset();
  committed_open_.reset();
  committed_entry_source_.clear();
  committed_playlist_position_ = -1;
  render_recovery_.reset();
  render_recovery_attempt_.reset();
  startup_playback_sync_.reset();
  routed_fallback_open_.reset();
  redirect_ranges_.clear();
  observed_current_path_ = false;
  active_event_playlist_entry_id_ = -1;
  terminal_playlist_entry_id_ = -1;
  last_error_playlist_entry_id_ = -1;
  selected_video_track_id_ = -1;
  selected_audio_track_id_ = -1;
  selected_subtitle_track_id_ = -1;
  selected_tracks_playlist_entry_id_ = -1;
  current_file_has_audio_track_.reset();
  attached_subtitle_files_.clear();
}

bool PlayerController::nativeRouteAdmissionAllowed() const noexcept {
  // The native engine now serves the advertised pitch-preserved window, so a
  // non-unit speed no longer routes the file away from it. Anything outside
  // that window still does: the compatibility engine has no such bound.
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  return native_protocol::routeForRate(rate_) ==
             native_protocol::RateRoute::NativeVersion1 &&
         video_item_;
#else
  return rate_ == 1.0 && video_item_;
#endif
}

bool PlayerController::beginRoutedFallbackOpen(
    const QUrl &source, std::uint64_t attempt, std::uint64_t serial,
    std::uint64_t source_key, bool paused, PlaybackSourceClass source_class) {
  if (!engineReady() || source.isEmpty() || attempt == 0 || serial == 0 ||
      source_key == 0) {
    setLastError(
        QStringLiteral("Compatibility playback received an invalid open."));
    return false;
  }

  int paused_flag = paused ? 1 : 0;
  if (core_->api().mpv_set_property(core_->handle(), "pause", MPV_FORMAT_FLAG,
                                    &paused_flag) < 0) {
    setLastError(QStringLiteral(
        "Compatibility playback could not apply the requested transport."));
    return false;
  }

  core_->allowRenderContext();
  pending_source_ = source;
  pending_request_serial_ = request_serial_;
  routed_fallback_open_ =
      RoutedFallbackOpen{attempt, serial, source_key, source_class};
  static_cast<void>(core_->retryFailedRenderContext());
  requestVideoUpdate();

  // Keep router action execution non-reentrant. A pre-existing Ready render
  // ticket can submit the load on this queued GUI turn; otherwise the normal
  // render-ready notification owns submission.
  QPointer<PlayerController> self(this);
  QMetaObject::invokeMethod(
      this,
      [self] {
        if (self)
          self->continuePendingOpen();
      },
      Qt::QueuedConnection);
  return true;
}

void PlayerController::notifyRoutedFallbackOpenFailed() {
  if (!native_playback_ || !routed_fallback_open_)
    return;
  const RoutedFallbackOpen lineage = *routed_fallback_open_;
  routed_fallback_open_.reset();
  native_playback_->fallbackOpenFailed(lineage.attempt, lineage.serial,
                                       lineage.source_key);
}

bool PlayerController::resetRoutedFallbackCoreAfterRelease(
    const std::shared_ptr<PlayerCore> &expected_core) {
  if (!expected_core || core_ != expected_core || !fallback_reset_core_)
    return false;
  if (!expected_core->retireFallbackAfterRenderRelease(this))
    return false;

  core_ = std::move(fallback_reset_core_);
  pending_source_.clear();
  pending_request_serial_ = 0;
  open_attempt_.reset();
  committed_open_.reset();
  committed_entry_source_.clear();
  committed_playlist_position_ = -1;
  render_recovery_.reset();
  render_recovery_attempt_.reset();
  startup_playback_sync_.reset();
  routed_fallback_open_.reset();
  active_event_playlist_entry_id_ = -1;
  terminal_playlist_entry_id_ = -1;
  last_error_playlist_entry_id_ = -1;
  last_reported_render_failure_stamp_ = 0;
  selected_video_track_id_ = -1;
  selected_audio_track_id_ = -1;
  selected_subtitle_track_id_ = -1;
  selected_tracks_playlist_entry_id_ = -1;
  current_file_has_audio_track_.reset();
  attached_subtitle_files_.clear();
  requestVideoUpdate();
  return true;
}
#endif

void PlayerController::play() {
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  if (native_playback_) {
    if (native_playback_->nativeOwnsTransport() && native_scrub_intent_) {
      // A native seek converges while physically paused. Keep play/pause as
      // logical post-seek intent; the owner applies the latest value only after
      // exact CommitReady proof.
      setNativeScrubPauseIntent(false);
      updatePause(false);
      return;
    }
    if (native_playback_->nativeOwnsTransport() && native_seek_intent_) {
      setNativeScrubPauseIntent(false);
      updatePause(false);
    }
    const auto disposition = native_playback_->setPaused(false);
    if (disposition == NativePlaybackOwner::PauseDisposition::NativeHandled ||
        disposition == NativePlaybackOwner::PauseDisposition::NotOwned) {
      if (disposition == NativePlaybackOwner::PauseDisposition::NativeHandled &&
          eof_reached_ && !native_seek_intent_) {
        // Native Ended retains its graph. Replay is one ordinary exact seek
        // to zero; CommitReady then restores the retained playing intent.
        updatePause(false);
        seekTo(0.0);
      }
      return;
    }
  }
#endif
  if (!engineReady())
    return;
  if (scrub_seek_) {
    scrub_seek_->intended_paused = false;
    updatePause(false);
    return;
  }
  if (eof_reached_ && committed_open_ &&
      terminal_playlist_entry_id_ == committed_open_->playlist_entry_id) {
    active_event_playlist_entry_id_ = terminal_playlist_entry_id_;
    terminal_playlist_entry_id_ = -1;
  }
  if (eof_reached_ || (duration_ > 0.0 && position_ >= duration_ - 0.05))
    seekTo(0.0);
  updateEof(false);
  if (render_recovery_ && render_recovery_->request_serial == request_serial_) {
    render_recovery_->paused = false;
    render_recovery_->transport_restored = false;
  }
  if (startup_playback_sync_ &&
      startup_playback_sync_->request_serial == request_serial_) {
    startup_playback_sync_->intended_paused = false;
  }
  int paused = 0;
  core_->api().mpv_set_property_async(core_->handle(), 0, "pause",
                                      MPV_FORMAT_FLAG, &paused);
  updatePause(false);
}

void PlayerController::pause() {
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  if (native_playback_) {
    if (native_playback_->nativeOwnsTransport() && native_scrub_intent_) {
      setNativeScrubPauseIntent(true);
      updatePause(true);
      return;
    }
    if (native_playback_->nativeOwnsTransport() && native_seek_intent_) {
      setNativeScrubPauseIntent(true);
      updatePause(true);
    }
    const auto disposition = native_playback_->setPaused(true);
    if (disposition == NativePlaybackOwner::PauseDisposition::NativeHandled ||
        disposition == NativePlaybackOwner::PauseDisposition::NotOwned) {
      return;
    }
  }
#endif
  if (!engineReady())
    return;
  if (scrub_seek_) {
    scrub_seek_->intended_paused = true;
    updatePause(true);
    return;
  }
  if (render_recovery_ && render_recovery_->request_serial == request_serial_) {
    if (!render_recovery_->paused && !render_recovery_->position_overridden) {
      double live_position = 0.0;
      if (core_->api().mpv_get_property(core_->handle(), "time-pos",
                                        MPV_FORMAT_DOUBLE,
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
  core_->api().mpv_set_property_async(core_->handle(), 0, "pause",
                                      MPV_FORMAT_FLAG, &paused);
  updatePause(true);
}

void PlayerController::togglePlayPause() { playing() ? pause() : play(); }

void PlayerController::stop() {
  // A live scroll sweep owns an open scrub gesture; drop it before the
  // transport goes away rather than committing a seek into a dead session.
  if (scroll_settle_timer_)
    scroll_settle_timer_->stop();
  scroll_model_.reset();
  scroll_sweep_target_.reset();
  if (scroll_gesture_active_) {
    scroll_gesture_active_ = false;
    emit scrollGestureActiveChanged();
  }
  invalidateScrubGesture();
  invalidateNativeSeekIntents();
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  if (native_playback_) {
    static_cast<void>(native_playback_->stop());
    return;
  }
#endif
  finishStopUi(true);
}

void PlayerController::finishStopUi(bool stop_compatibility_engine) {
  invalidateNativeSeekIntents();
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
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  routed_fallback_open_.reset();
#endif
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
  if (stop_compatibility_engine && engineReady())
    sendCommand(core_.get(), {QByteArrayLiteral("stop")});
  updatePause(true);
  updateIdle(true);
  updateEof(false);
  updateSource({});
  updateMediaTitle({});
  resetTimeline();
  requestVideoUpdate();
}

std::optional<std::uint64_t> PlayerController::reserveNativeSeekIdentity(
    std::uint64_t &high_water) noexcept {
  if (high_water == std::numeric_limits<std::uint64_t>::max())
    return std::nullopt;
  ++high_water;
  // Zero is never a live protocol identity. Because the counter never wraps,
  // this is defensive rather than a second allocation attempt.
  if (high_water == 0)
    return std::nullopt;
  return high_water;
}

double PlayerController::boundedSeekTarget(double seconds) const noexcept {
  const double maximum = duration_ > 0.0 ? duration_ : seconds;
  return std::clamp(seconds, 0.0, std::max(0.0, maximum));
}

double PlayerController::exactNativeSeekTarget(double seconds) const noexcept {
  // Both native preflights -- NativeMediaSession::preflightCommitTarget and
  // preflightPreviewTarget -- require media::exactNonnegativeMediaTime, which
  // admits a double only when it is k / 2^n with n <= 30, and additionally
  // require the target to be strictly less than the duration. A pointer drag
  // produces neither: an interpolated timeline position is essentially never
  // dyadic, and the right end of the track is exactly the duration. Both
  // refusals surface as "Native seeking cannot represent this exact target"
  // with no seek at all.
  //
  // Floor every native target onto the same 1/64 s binary grid the resume and
  // scripted-seek paths use (15.6 ms, below one frame at 60 fps, so the
  // handle and the picture stay visually identical), and hold the target
  // strictly below the duration so a drag to the end of the timeline commits
  // instead of being refused.
  //
  // The guard is exactly one grid step, which is the whole of what the
  // preflight's strict inequality needs. It was briefly 1/8 s, to hide a
  // separate defect: a target inside the last frame's presentation interval
  // was accepted and drawn, end of stream then overtook the commit, and the
  // commit's own post-promotion SetRunState was refused by the just-ended
  // session -- retiring the whole native route with "Native playback rejected
  // an internal lifecycle command". That was never a seek-arithmetic problem;
  // it was NativeMediaSession latching Ended inside the commit handshake,
  // before the run command the commit protocol promises. Fixed there
  // (commitRunStatePending), so the last frame is reachable again and the
  // final 1/8 s of every clip is no longer dead to the scrubber.
  constexpr double kSeekGrid = 64.0;
  const double bounded = boundedSeekTarget(seconds);
  if (!std::isfinite(bounded) || bounded <= 0.0)
    return 0.0;
  double target = std::floor(bounded * kSeekGrid) / kSeekGrid;
  // Strictly inside the duration, on the grid: the largest admissible target
  // is the last grid point below duration_, not duration_ itself.
  if (duration_ > 0.0 && target >= duration_)
    target = std::floor((duration_ - 1.0 / kSeekGrid) * kSeekGrid) / kSeekGrid;
  if (!(target > 0.0))
    return 0.0;
  return target;
}

double PlayerController::frameStepSeekTarget(double seconds,
                                             bool round_up) const noexcept {
  // 2^-12 s = 244 us. Dyadic, so media::exactNonnegativeMediaTime reduces it
  // to k/4096 and the commit preflight admits it exactly as it admits the
  // scrubber's k/64; the only thing that changes is the rung. The rounded
  // result sits strictly inside the neighbouring frame's half-open
  // presentation interval whenever that frame lasts longer than one grid
  // step, i.e. for anything below 4096 fps.
  constexpr double kFrameStepGrid = 4096.0;
  const double bounded = boundedSeekTarget(seconds);
  if (!std::isfinite(bounded) || bounded <= 0.0)
    return 0.0;
  // Forward: the smallest grid point at or after the target, which is the
  // next frame's own start when that start is representable and a hair into
  // its interval otherwise. Equality is correct here -- the interval is
  // half-open at the start, so landing exactly on it selects that frame.
  //
  // Backward: the largest grid point STRICTLY BELOW the target. Plain
  // flooring is wrong, and wrong in a way that is easy to miss: whenever a
  // frame's PTS is itself dyadic, floor returns that same instant, accurate
  // seek lands on the frame the user is already looking at, and the step
  // silently does nothing. At 30 fps that is every fifteenth frame (15/30 =
  // 0.5); at 120 fps every fifteenth too. `(ceil(x) - 1)` is the uniform
  // answer: for an integral x it steps one grid point back, and for a
  // non-integral x it is exactly floor(x).
  double target =
      round_up
          ? std::ceil(bounded * kFrameStepGrid) / kFrameStepGrid
          : (std::ceil(bounded * kFrameStepGrid) - 1.0) / kFrameStepGrid;
  // Same strictly-inside-the-duration rule exactNativeSeekTarget applies, on
  // this grid: the last admissible target is the last grid point below the
  // duration, never the duration itself.
  if (duration_ > 0.0 && target >= duration_) {
    target = std::floor((duration_ - 1.0 / kFrameStepGrid) * kFrameStepGrid) /
             kFrameStepGrid;
  }
  if (!(target > 0.0))
    return 0.0;
  return target;
}

bool PlayerController::beginNativeScrubIntent() {
  if (native_scrub_intent_)
    return true;
  const auto gesture = reserveNativeSeekIdentity(next_native_seek_gesture_id_);
  if (!gesture)
    return false;
  const bool intended_paused =
      native_seek_intent_ ? native_seek_intent_->intended_paused : paused_;
  native_scrub_intent_ = NativeScrubIntent{
      *gesture, position_, position_, 0, 0, intended_paused};
  return true;
}

std::optional<PlayerController::NativePreviewIntent>
PlayerController::makeNativePreviewIntent(double seconds) {
  if (!native_scrub_intent_ || !std::isfinite(seconds))
    return std::nullopt;
  const auto request = reserveNativeSeekIdentity(next_native_seek_request_id_);
  if (!request)
    return std::nullopt;
  return NativePreviewIntent{native_scrub_intent_->gesture, *request,
                             exactNativeSeekTarget(seconds)};
}

std::optional<PlayerController::NativePreviewIntent>
PlayerController::makeObservedNativePreviewIntent(
    double seconds, void *context, NativePreviewDemandObserver observer) {
  std::optional<NativePreviewIntent> intent = makeNativePreviewIntent(seconds);
  if (intent && observer != nullptr)
    observer(context, *intent);
  return intent;
}

void PlayerController::dispatchNativePreviewIntent(
    const NativePreviewIntent &intent, void *context,
    NativePreviewSubmitter submitter) {
  if (!native_scrub_intent_ ||
      native_scrub_intent_->gesture != intent.gesture || intent.request == 0 ||
      !std::isfinite(intent.target)) {
    return;
  }

  // Stage both the visible desire and, when idle, its in-flight ownership
  // before publishing the optimistic target. positionChanged handlers may
  // synchronously request another preview; that movement must coalesce behind
  // this exact request instead of recursively issuing another media command.
  NativeScrubIntent &scrub = *native_scrub_intent_;
  scrub.latest_preview_request = intent.request;
  scrub.target = intent.target;
  const bool ownsDispatch = scrub.dispatched_preview_request == 0;
  if (ownsDispatch)
    scrub.dispatched_preview_request = intent.request;
  publishSeekTarget(intent.target);

  // Publishing the optimistic handle is a synchronous Qt boundary. A signal
  // handler may Stop, Commit, or replace the entire gesture before returning;
  // never submit media work for an identity that no longer owns the slot.
  if (!native_scrub_intent_ ||
      native_scrub_intent_->gesture != intent.gesture ||
      native_scrub_intent_->dispatched_preview_request != intent.request) {
    return;
  }
  if (!ownsDispatch)
    return;

  if (submitter == nullptr) {
    if (native_scrub_intent_ &&
        native_scrub_intent_->gesture == intent.gesture &&
        native_scrub_intent_->dispatched_preview_request == intent.request) {
      native_scrub_intent_->dispatched_preview_request = 0;
    }
    return;
  }

  const NativePreviewSubmission submission = submitter(context, intent);
  // The owner may synchronously drain a terminal observation while accepting
  // this command. Such a completion has already released or replaced the
  // slot; never recreate its ownership after returning from client code.
  if (!native_scrub_intent_ ||
      native_scrub_intent_->gesture != intent.gesture ||
      native_scrub_intent_->dispatched_preview_request != intent.request) {
    return;
  }

  switch (submission) {
  case NativePreviewSubmission::Accepted:
  case NativePreviewSubmission::Replaced:
    return;
  case NativePreviewSubmission::Stale:
  case NativePreviewSubmission::Rejected:
    break;
  }

  // Refusal is intentionally non-modal. Release the work slot but retain the
  // newest request as a freshness barrier. If client reentrancy staged a newer
  // desire while this request was being submitted, give that exact latest
  // target one immediate opportunity instead of leaving it stranded.
  native_scrub_intent_->dispatched_preview_request = 0;
  if (native_scrub_intent_->latest_preview_request != intent.request) {
    const NativePreviewIntent latest{
        native_scrub_intent_->gesture,
        native_scrub_intent_->latest_preview_request,
        native_scrub_intent_->target};
    dispatchNativePreviewIntent(latest, context, submitter);
  }
}

std::optional<PlayerController::NativeSeekIntent>
PlayerController::finishNativeScrubIntent(double seconds) {
  if (!native_scrub_intent_)
    return std::nullopt;
  const NativeScrubIntent scrub = *native_scrub_intent_;
  native_scrub_intent_.reset();
  if (!std::isfinite(seconds))
    return std::nullopt;
  const auto request = reserveNativeSeekIdentity(next_native_seek_request_id_);
  if (!request)
    return std::nullopt;
  return NativeSeekIntent{scrub.gesture, *request,
                          exactNativeSeekTarget(seconds), scrub.origin,
                          scrub.intended_paused};
}

std::optional<PlayerController::NativeSeekIntent>
PlayerController::makeNativeSeekIntent(double seconds) {
  if (!std::isfinite(seconds))
    return std::nullopt;
  const auto gesture = reserveNativeSeekIdentity(next_native_seek_gesture_id_);
  if (!gesture)
    return std::nullopt;
  const auto request = reserveNativeSeekIdentity(next_native_seek_request_id_);
  if (!request)
    return std::nullopt;
  const bool intended_paused =
      native_seek_intent_ ? native_seek_intent_->intended_paused : paused_;
  return NativeSeekIntent{*gesture, *request, exactNativeSeekTarget(seconds),
                          position_, intended_paused};
}

std::optional<PlayerController::NativeSeekIntent>
PlayerController::makeNativeExactSeekIntent(double exact_target) {
  if (!std::isfinite(exact_target) || exact_target < 0.0)
    return std::nullopt;
  const auto gesture = reserveNativeSeekIdentity(next_native_seek_gesture_id_);
  if (!gesture)
    return std::nullopt;
  const auto request = reserveNativeSeekIdentity(next_native_seek_request_id_);
  if (!request)
    return std::nullopt;
  // A frame step always lands paused: that is the whole point of the gesture,
  // and it keeps the intent from restoring a running transport underneath the
  // frame the user just asked to look at.
  return NativeSeekIntent{*gesture, *request, exact_target, position_, true};
}

PlayerController::NativeSeekDispatch
PlayerController::dispatchNativeSeekIntent(const NativeSeekIntent &intent,
                                           void *context,
                                           NativeSeekSubmitter submitter) {
  if (submitter == nullptr) {
    publishSeekTarget(intent.rollback_position);
    return NativeSeekDispatch::Consumed;
  }
  NativeSeekSubmissionState submission_state{
      intent.gesture, intent.request, intent.target, NativeSeekTerminal::None,
      native_seek_submission_};
  native_seek_submission_ = &submission_state;
  latest_native_seek_submission_request_ = intent.request;
  const NativeSeekSubmission submission = submitter(context, intent);
  native_seek_submission_ = submission_state.previous;
  const bool superseded =
      latest_native_seek_submission_request_ != intent.request;
  // A synchronous observation drain can reenter seek submission. Once a
  // newer request exists, the older call may neither publish/roll back its
  // target nor fall through to compatibility playback.
  if (superseded)
    return NativeSeekDispatch::Consumed;
  switch (submission) {
  case NativeSeekSubmission::Accepted:
    if (submission_state.terminal == NativeSeekTerminal::None) {
      native_seek_intent_ = intent;
      publishSeekTarget(intent.target);
    } else if (submission_state.terminal == NativeSeekTerminal::Ready) {
      publishSeekTarget(intent.target);
      updateEof(false);
      updateIdle(false);
    } else {
      publishSeekTarget(intent.rollback_position);
    }
    return NativeSeekDispatch::Consumed;
  case NativeSeekSubmission::Rejected:
    publishSeekTarget(intent.rollback_position);
    return NativeSeekDispatch::Consumed;
  case NativeSeekSubmission::Compatibility:
    return NativeSeekDispatch::Compatibility;
  }
  publishSeekTarget(intent.rollback_position);
  return NativeSeekDispatch::Consumed;
}

#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
void PlayerController::dispatchNativePreviewIntent(
    const NativePreviewIntent &intent) {
  const auto submit = [](void *context,
                         const NativePreviewIntent &request) noexcept {
    auto &owner = *static_cast<NativePlaybackOwner *>(context);
    switch (
        owner.previewFrame(request.target, request.gesture, request.request)) {
    case NativePlaybackOwner::PreviewDisposition::Accepted:
      return NativePreviewSubmission::Accepted;
    case NativePlaybackOwner::PreviewDisposition::Replaced:
      return NativePreviewSubmission::Replaced;
    case NativePlaybackOwner::PreviewDisposition::Stale:
      return NativePreviewSubmission::Stale;
    case NativePlaybackOwner::PreviewDisposition::NotOwned:
    case NativePlaybackOwner::PreviewDisposition::Rejected:
      return NativePreviewSubmission::Rejected;
    }
    return NativePreviewSubmission::Rejected;
  };
  dispatchNativePreviewIntent(intent, native_playback_.get(), submit);
}

void PlayerController::nativePreviewPresented(
    const ::wam::media::native_playback::PreviewPresented &presented) {
  const auto submit = [](void *context,
                         const NativePreviewIntent &request) noexcept {
    auto &owner = *static_cast<NativePlaybackOwner *>(context);
    switch (
        owner.previewFrame(request.target, request.gesture, request.request)) {
    case NativePlaybackOwner::PreviewDisposition::Accepted:
      return NativePreviewSubmission::Accepted;
    case NativePlaybackOwner::PreviewDisposition::Replaced:
      return NativePreviewSubmission::Replaced;
    case NativePlaybackOwner::PreviewDisposition::Stale:
      return NativePreviewSubmission::Stale;
    case NativePlaybackOwner::PreviewDisposition::NotOwned:
    case NativePlaybackOwner::PreviewDisposition::Rejected:
      return NativePreviewSubmission::Rejected;
    }
    return NativePreviewSubmission::Rejected;
  };
  static_cast<void>(completeNativePreviewPresented(
      presented.gesture.value, presented.request.value,
      presented.actualPresentationTimeSeconds, native_playback_.get(),
      submit));
}

void PlayerController::nativePreviewFailed(
    const ::wam::media::native_playback::PreviewFailed &failed) {
  const auto submit = [](void *context,
                         const NativePreviewIntent &request) noexcept {
    auto &owner = *static_cast<NativePlaybackOwner *>(context);
    switch (
        owner.previewFrame(request.target, request.gesture, request.request)) {
    case NativePlaybackOwner::PreviewDisposition::Accepted:
      return NativePreviewSubmission::Accepted;
    case NativePlaybackOwner::PreviewDisposition::Replaced:
      return NativePreviewSubmission::Replaced;
    case NativePlaybackOwner::PreviewDisposition::Stale:
      return NativePreviewSubmission::Stale;
    case NativePlaybackOwner::PreviewDisposition::NotOwned:
    case NativePlaybackOwner::PreviewDisposition::Rejected:
      return NativePreviewSubmission::Rejected;
    }
    return NativePreviewSubmission::Rejected;
  };
  static_cast<void>(completeNativePreviewFailed(
      failed.gesture.value, failed.request.value, native_playback_.get(),
      submit));
}

PlayerController::NativeSeekDispatch
PlayerController::dispatchNativeSeekIntent(const NativeSeekIntent &intent) {
  const auto submit = [](void *context,
                         const NativeSeekIntent &request) noexcept {
    auto &owner = *static_cast<NativePlaybackOwner *>(context);
    switch (owner.commitSeek(request.target, request.gesture, request.request,
                             request.intended_paused)) {
    case NativePlaybackOwner::SeekDisposition::NativeHandled:
      return NativeSeekSubmission::Accepted;
    case NativePlaybackOwner::SeekDisposition::NativeRejected:
      return NativeSeekSubmission::Rejected;
    case NativePlaybackOwner::SeekDisposition::NotOwned:
    case NativePlaybackOwner::SeekDisposition::FallbackHandled:
      return NativeSeekSubmission::Compatibility;
    }
    return NativeSeekSubmission::Rejected;
  };
  return dispatchNativeSeekIntent(intent, native_playback_.get(), submit);
}

void PlayerController::nativeCommitReady(
    const ::wam::media::native_playback::CommitReady &ready) {
  if (!acceptNativeCommitReady(ready.gesture.value, ready.request.value,
                               ready.targetSeconds)) {
    return;
  }
  // Every commit lands paused on a proved covering frame, so its embedded
  // draw proof is the authoritative frame geometry for the picture now on
  // screen -- and the one that chains one frame step to the next.
  if (!ready.videoDraw.videoLaneAbsent) {
    publishNativeFrameGeometry(ready.videoDraw.frameStartSeconds,
                               ready.videoDraw.frameDurationSeconds);
  } else {
    publishNativeFrameGeometry(0.0, 0.0);
  }
  updateEof(false);
  updateIdle(false);
}
#endif

bool PlayerController::completeNativePreviewPresented(
    std::uint64_t gesture, std::uint64_t request,
    double actual_presentation_time, void *context,
    NativePreviewSubmitter submitter) {
  if (!native_scrub_intent_ || gesture == 0 || request == 0 ||
      native_scrub_intent_->gesture != gesture ||
      native_scrub_intent_->dispatched_preview_request != request ||
      !std::isfinite(actual_presentation_time)) {
    return false;
  }

  native_scrub_intent_->dispatched_preview_request = 0;
  if (native_scrub_intent_->latest_preview_request == request) {
    publishSeekTarget(boundedSeekTarget(actual_presentation_time));
    return true;
  }

  // The frame really reached the screen and therefore completes the admitted
  // work, but a newer pointer target owns the handle. Do not visually regress
  // it to this older PTS; immediately spend the newly free slot on the single
  // latest desired request instead.
  const NativePreviewIntent latest{
      native_scrub_intent_->gesture,
      native_scrub_intent_->latest_preview_request,
      native_scrub_intent_->target};
  dispatchNativePreviewIntent(latest, context, submitter);
  return true;
}

bool PlayerController::completeNativePreviewFailed(
    std::uint64_t gesture, std::uint64_t request, void *context,
    NativePreviewSubmitter submitter) {
  if (!native_scrub_intent_ || gesture == 0 || request == 0 ||
      native_scrub_intent_->gesture != gesture ||
      native_scrub_intent_->dispatched_preview_request != request) {
    return false;
  }

  native_scrub_intent_->dispatched_preview_request = 0;
  if (native_scrub_intent_->latest_preview_request == request) {
    return true;
  }

  // Failure retires only the exact admitted work. The newest pointer target
  // still owns the visible handle and gets the newly free slot once; no stale
  // PTS or rollback is published at this boundary.
  const NativePreviewIntent latest{
      native_scrub_intent_->gesture,
      native_scrub_intent_->latest_preview_request,
      native_scrub_intent_->target};
  dispatchNativePreviewIntent(latest, context, submitter);
  return true;
}

bool PlayerController::acceptNativeCommitReady(std::uint64_t gesture,
                                               std::uint64_t request,
                                               double target) {
  for (NativeSeekSubmissionState *submission = native_seek_submission_;
       submission != nullptr; submission = submission->previous) {
    if (submission->gesture == gesture && submission->request == request &&
        submission->target == target) {
      submission->terminal = NativeSeekTerminal::Ready;
      return true;
    }
  }
  if (!native_seek_intent_ || native_seek_intent_->gesture != gesture ||
      native_seek_intent_->request != request ||
      native_seek_intent_->target != target) {
    return false;
  }
  native_seek_intent_.reset();
  return true;
}

void PlayerController::nativeCommitFailed(std::uint64_t gesture,
                                          std::uint64_t request) noexcept {
  for (NativeSeekSubmissionState *submission = native_seek_submission_;
       submission != nullptr; submission = submission->previous) {
    if (submission->gesture == gesture && submission->request == request) {
      submission->terminal = NativeSeekTerminal::Failed;
      return;
    }
  }
  if (!native_seek_intent_ || native_seek_intent_->gesture != gesture ||
      native_seek_intent_->request != request) {
    return;
  }
  native_seek_intent_.reset();
}

void PlayerController::setNativeScrubPauseIntent(bool paused) {
  if (native_scrub_intent_) {
    native_scrub_intent_->intended_paused = paused;
  } else if (native_seek_intent_) {
    native_seek_intent_->intended_paused = paused;
  }
}

void PlayerController::invalidateNativeScrubIntent() noexcept {
  native_scrub_intent_.reset();
}

void PlayerController::invalidateNativeSeekIntents() noexcept {
  native_scrub_intent_.reset();
  native_seek_intent_.reset();
  // Frame geometry belongs to one generation's picture. Carrying it across a
  // stop or a new open would let the first "." step relative to the previous
  // file's last frame.
  native_frame_start_ = -1.0;
  native_frame_duration_ = 0.0;
  pending_frame_step_ = 0;
  for (NativeSeekSubmissionState *submission = native_seek_submission_;
       submission != nullptr; submission = submission->previous) {
    submission->terminal = NativeSeekTerminal::Failed;
  }
}

void PlayerController::publishNativeMainPosition(double position) {
  // The native route has no FILE_LOADED. Its first published media time is the
  // earliest honest proof that native -- not the compatibility engine -- ended
  // up owning this file, which is exactly when the Subtitles menu can be built
  // from the container instead of from mpv. Guarded so this is one boolean
  // test per drawn frame after the first.
  if (subtitles_ && (!subtitle_sources_built_ ||
                     subtitle_sources_source_ != source_ ||
                     !subtitle_sources_native_)) {
    refreshSubtitleSources();
  }
  // During a pointer gesture the optimistic target and its exact preview
  // presentation own the visible playhead. Main audio/draw proofs still
  // advance their owner-side high-water marks, but cannot repaint an older
  // transport position over the user's latest target.
  if (native_scrub_intent_)
    return;
  publishSeekTarget(position);
}

void PlayerController::publishSeekTarget(double target) {
  if (!std::isfinite(target) || nearlyEqual(position_, target))
    return;
  position_ = target;
  emit positionChanged();
}

void PlayerController::beginScrub() {
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  if (native_playback_ && native_playback_->nativeOwnsTransport()) {
    if (!beginNativeScrubIntent())
      return;
    const auto disposition = native_playback_->setPaused(true);
    if (disposition == NativePlaybackOwner::PauseDisposition::NativeHandled) {
      // Pointer-down starts the surface-budget handoff before the MouseArea's
      // first immediate motion preview. Refusal stays silent; release still
      // commits one exact seek and restores the captured logical pause intent.
      // A refusal that means "this source has no frame to preview" (audio
      // only) is remembered for the whole gesture, so motion samples publish
      // the time readout without demanding a thumbnail that cannot exist.
      const auto handoff = native_playback_->preparePreviewHandoff();
      if (native_scrub_intent_) {
        native_scrub_intent_->preview_available =
            handoff !=
            NativePlaybackOwner::PreviewHandoffDisposition::Unsupported;
      }
      return;
    }
    invalidateNativeScrubIntent();
    if (disposition != NativePlaybackOwner::PauseDisposition::FallbackHandled) {
      return;
    }
  }
#endif
  if (!engineReady() || scrub_seek_ || render_recovery_ ||
      startup_playback_sync_ || !acceptsPlaybackObservation()) {
    return;
  }

  int live_paused = paused_ ? 1 : 0;
  if (core_->api().mpv_get_property(core_->handle(), "pause", MPV_FORMAT_FLAG,
                                    &live_paused) < 0) {
    return;
  }
  ++next_scrub_gesture_id_;
  if (next_scrub_gesture_id_ == 0)
    ++next_scrub_gesture_id_;
  scrub_seek_ = ScrubSeek{next_scrub_gesture_id_,
                          request_serial_,
                          0,
                          committed_open_->playlist_entry_id,
                          position_,
                          std::nullopt,
                          std::nullopt,
                          live_paused != 0};

  int physically_paused = 1;
  if (core_->api().mpv_set_property(core_->handle(), "pause", MPV_FORMAT_FLAG,
                                    &physically_paused) < 0) {
    scrub_seek_.reset();
    return;
  }
  updatePause(live_paused != 0);
}

void PlayerController::seekTo(double seconds) {
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  if (native_playback_ && native_playback_->nativeOwnsTransport()) {
    // Native accurate seek requires an exactly representable rational target;
    // exactNativeSeekTarget owns that rule for every native entry point, and
    // the intent factories below apply it. Applying it here too keeps the
    // value handed to endScrub identical to the one a direct seek would use.
    if (!std::isfinite(seconds))
      return;
    seconds = exactNativeSeekTarget(seconds);
    if (native_scrub_intent_) {
      endScrub(seconds);
      return;
    }
    if (auto intent = makeNativeSeekIntent(seconds)) {
      if (dispatchNativeSeekIntent(*intent) == NativeSeekDispatch::Consumed)
        return;
    } else {
      return;
    }
  }
#endif
  if (!engineReady() || !std::isfinite(seconds))
    return;
  if (scrub_seek_) {
    endScrub(seconds);
    return;
  }
  const double maximum = duration_ > 0.0 ? duration_ : seconds;
  const double target = std::clamp(seconds, 0.0, std::max(0.0, maximum));
  if (render_recovery_ && render_recovery_->request_serial == request_serial_) {
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
  core_->api().mpv_set_property_async(core_->handle(), 0, "time-pos",
                                      MPV_FORMAT_DOUBLE, &value);
  if (!nearlyEqual(position_, target)) {
    position_ = target;
    emit positionChanged();
  }
}

void PlayerController::previewSeekTo(double seconds) {
#if defined(WAM_MPV_RUNTIME_TESTING)
  if (native_preview_test_submitter_ != nullptr) {
    if (auto intent = makeObservedNativePreviewIntent(
            seconds, native_preview_test_demand_context_,
            native_preview_test_demand_observer_)) {
      dispatchNativePreviewIntent(*intent, native_preview_test_submit_context_,
                                  native_preview_test_submitter_);
    }
    return;
  }
#endif
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  if (native_playback_ && native_playback_->nativeOwnsTransport()) {
    // Audio-only binding: the session refused the preview handoff for this
    // whole gesture at pointer-down. Track the drag in the time readout --
    // that is the entire visible scrub experience for a source with no
    // picture -- and demand nothing. No preview identity is reserved, no
    // demand is published, and no PreviewFailed can follow, so an audio scrub
    // leaves the telemetry stream and the log exactly as clean as no scrub.
    if (native_scrub_intent_ && !native_scrub_intent_->preview_available) {
      if (!std::isfinite(seconds))
        return;
      const double target = exactNativeSeekTarget(seconds);
      native_scrub_intent_->target = target;
      publishSeekTarget(target);
      return;
    }
    const auto observeDemand = [](void *context,
                                  const NativePreviewIntent &intent) noexcept {
      auto &controller = *static_cast<PlayerController *>(context);
      auto &telemetry = NativeBenchmarkTelemetry::instance();
      if (telemetry.enabled()) {
        telemetry.previewDemanded(
            ::wam::media::native_playback::GestureId{intent.gesture},
            ::wam::media::native_playback::RequestId{intent.request},
            intent.target, controller.engineReady());
      }
    };
    if (auto intent =
            makeObservedNativePreviewIntent(seconds, this, observeDemand)) {
      dispatchNativePreviewIntent(*intent);
    }
    return;
  }
#endif
  if (!engineReady() || !std::isfinite(seconds))
    return;
  const double maximum = duration_ > 0.0 ? duration_ : seconds;
  const double target = std::clamp(seconds, 0.0, std::max(0.0, maximum));
  if (!scrub_seek_) {
    // Preview calls belong only to an explicitly owned pointer gesture. If
    // startup or render recovery refused ownership, ignore cadence updates;
    // the release path still performs one ordinary exact seek.
    return;
  }
  if (render_recovery_ && render_recovery_->request_serial == request_serial_) {
    render_recovery_->position = target;
    render_recovery_->transport_restored = false;
    render_recovery_->position_overridden = true;
  }
  if (startup_playback_sync_ &&
      startup_playback_sync_->request_serial == request_serial_) {
    startup_playback_sync_->intended_position = target;
    startup_playback_sync_->position_overridden = true;
  }

  if (scrub_seek_->request_serial != request_serial_) {
    invalidateScrubGesture();
    return;
  }
  if (scrub_seek_->command != 0) {
    scrub_seek_->pending_target = target;
  } else {
    dispatchScrubSeek(target, false);
  }
  if (!nearlyEqual(position_, target)) {
    position_ = target;
    emit positionChanged();
  }
}

void PlayerController::endScrub(double seconds) {
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  if (native_playback_ && native_playback_->nativeOwnsTransport()) {
    std::optional<NativeSeekIntent> intent;
    if (native_scrub_intent_) {
      intent = finishNativeScrubIntent(seconds);
    } else {
      // Timeline keyboard/click seeks intentionally use the same exact commit
      // path even though they do not own a pointer gesture.
      intent = makeNativeSeekIntent(seconds);
    }
    if (intent) {
      if (dispatchNativeSeekIntent(*intent) == NativeSeekDispatch::Consumed)
        return;
    } else {
      return;
    }
  }
#endif
  if (!scrub_seek_) {
    seekTo(seconds);
    return;
  }
  if (!engineReady() || !std::isfinite(seconds) ||
      scrub_seek_->request_serial != request_serial_) {
    finishScrubGesture(true);
    return;
  }
  const double maximum = duration_ > 0.0 ? duration_ : seconds;
  const double target = std::clamp(seconds, 0.0, std::max(0.0, maximum));
  scrub_seek_->final = true;
  scrub_seek_->pending_target = target;
  if (scrub_seek_->command == 0) {
    scrub_seek_->pending_target.reset();
    dispatchScrubSeek(target, true);
  }
  if (!nearlyEqual(position_, target)) {
    position_ = target;
    emit positionChanged();
  }
}

const char *PlayerController::scrubSeekMode(bool exact) {
  return exact ? "absolute+exact" : "absolute+keyframes";
}

void PlayerController::armScrubTimeout(std::uint64_t gesture,
                                       std::uint64_t request_serial,
                                       std::uint64_t command) {
  if (!scrub_timeout_timer_)
    return;
  scrub_timeout_timer_->stop();
  scrub_timeout_gesture_ = gesture;
  scrub_timeout_request_serial_ = request_serial;
  scrub_timeout_command_ = command;
  scrub_timeout_timer_->start(kScrubSeekTimeoutMs);
}

void PlayerController::cancelScrubTimeout() {
  if (scrub_timeout_timer_)
    scrub_timeout_timer_->stop();
  scrub_timeout_gesture_ = 0;
  scrub_timeout_request_serial_ = 0;
  scrub_timeout_command_ = 0;
}

void PlayerController::dispatchScrubSeek(double target, bool exact) {
  if (!scrub_seek_ || !engineReady() || scrub_seek_->command != 0 ||
      scrub_seek_->request_serial != request_serial_ || !committed_open_ ||
      committed_open_->request_serial != request_serial_ ||
      committed_open_->playlist_entry_id != scrub_seek_->playlist_entry_id ||
      active_event_playlist_entry_id_ != scrub_seek_->playlist_entry_id) {
    finishScrubGesture(true);
    return;
  }

  ++next_scrub_command_id_;
  next_scrub_command_id_ &= kScrubCommandReplyIdMask;
  if (next_scrub_command_id_ == 0)
    next_scrub_command_id_ = 1;
  const std::uint64_t command = next_scrub_command_id_;
  const std::uint64_t reply_userdata = kScrubCommandReplyTag | command;

  scrub_seek_->command = command;
  scrub_seek_->target = target;
  scrub_seek_->command_exact = exact;
  scrub_seek_->command_replied = false;
  scrub_seek_->seek_started = false;
  scrub_seek_->playback_restarted = false;
  scrub_seek_->authoritative_position.reset();
  const std::uint64_t gesture = scrub_seek_->gesture;
  const std::uint64_t request_serial = scrub_seek_->request_serial;
  const int result = sendCommand(core_.get(),
                                 {QByteArrayLiteral("seek"),
                                  QByteArray::number(target, 'g', 12),
                                  QByteArray(scrubSeekMode(exact))},
                                 reply_userdata);
  if (result < 0) {
    finishScrubGesture(true);
    return;
  }

  // Command completion alone does not mean a frame was decoded. Keep the
  // capacity-one slot until a post-issuance SEEK and playback restart identify
  // a decoded frame. Exact release commands additionally converge to 50 ms.
  armScrubTimeout(gesture, request_serial, command);
}

void PlayerController::handleScrubTimeout(std::uint64_t gesture,
                                          std::uint64_t request_serial,
                                          std::uint64_t command) {
  if (!scrub_seek_ || scrub_seek_->gesture != gesture ||
      scrub_seek_->request_serial != request_serial ||
      scrub_seek_->command != command) {
    return;
  }
  if (scrub_seek_->command_replied) {
    scrub_seek_->command = 0;
    scrub_seek_->command_replied = false;
    scrub_seek_->seek_started = false;
    scrub_seek_->playback_restarted = false;
    scrub_seek_->authoritative_position.reset();
    scrub_seek_->pending_target.reset();
    // The command reply proves only API execution, not decoder completion.
    // Without a matching restart, issuing the retained final target here
    // could overlap the still-decoding seek. Exit conservatively instead.
    finishScrubGesture(true);
    return;
  }
  if (engineReady() && !scrub_seek_->abort_pending) {
    scrub_seek_->abort_pending = true;
    core_->api().mpv_abort_async_command(core_->handle(),
                                         kScrubCommandReplyTag | command);
  }
}

void PlayerController::handleScrubCommandReply(std::uint64_t reply_userdata,
                                               int error) {
  const std::uint64_t command = reply_userdata & kScrubCommandReplyIdMask;
  if (!scrub_seek_ || scrub_seek_->request_serial != request_serial_ ||
      scrub_seek_->command != command) {
    return;
  }
  if (scrub_seek_->abort_pending) {
    // Abort is best-effort: even its reply cannot prove the old decoder seek
    // stopped. Never launch a retained target over that unproven work.
    finishScrubGesture(true);
    return;
  }
  if (error < 0) {
    cancelScrubTimeout();
    const std::optional<double> pending = scrub_seek_->pending_target;
    const bool final = scrub_seek_->final;
    scrub_seek_->command = 0;
    scrub_seek_->command_exact = false;
    scrub_seek_->command_replied = false;
    scrub_seek_->seek_started = false;
    scrub_seek_->playback_restarted = false;
    scrub_seek_->authoritative_position.reset();
    scrub_seek_->pending_target.reset();
    if (final && pending && !scrub_seek_->replacement_dispatched) {
      scrub_seek_->replacement_dispatched = true;
      dispatchScrubSeek(*pending, true);
      return;
    }
    finishScrubGesture(true);
    return;
  }
  scrub_seek_->command_replied = true;
  maybeCompleteScrubSeek();
}

void PlayerController::handleScrubPlaybackRestart() {
  if (!scrub_seek_ || scrub_seek_->command == 0 || !scrub_seek_->seek_started ||
      scrub_seek_->request_serial != request_serial_ || !committed_open_ ||
      committed_open_->request_serial != request_serial_ ||
      committed_open_->playlist_entry_id != scrub_seek_->playlist_entry_id ||
      active_event_playlist_entry_id_ != scrub_seek_->playlist_entry_id ||
      !engineReady()) {
    return;
  }
  scrub_seek_->playback_restarted = true;
  double live_position = 0.0;
  if (core_->api().mpv_get_property(core_->handle(), "time-pos",
                                    MPV_FORMAT_DOUBLE, &live_position) >= 0 &&
      std::isfinite(live_position)) {
    scrub_seek_->authoritative_position = std::max(0.0, live_position);
  }
  maybeCompleteScrubSeek();
}

void PlayerController::maybeCompleteScrubSeek() {
  if (!scrub_seek_ || !scrub_seek_->command_replied ||
      !scrub_seek_->playback_restarted) {
    return;
  }
  if (!scrub_seek_->authoritative_position ||
      !std::isfinite(*scrub_seek_->authoritative_position)) {
    return;
  }
  if (scrub_seek_->command_exact &&
      std::abs(*scrub_seek_->authoritative_position - scrub_seek_->target) >
          kScrubConvergenceToleranceSeconds) {
    return;
  }

  const bool released = scrub_seek_->final;
  const bool completed_exact = scrub_seek_->command_exact;
  const double completed_target = scrub_seek_->target;
  const std::optional<double> pending = scrub_seek_->pending_target;
  cancelScrubTimeout();
  scrub_seek_->command = 0;
  scrub_seek_->command_exact = false;
  scrub_seek_->command_replied = false;
  scrub_seek_->seek_started = false;
  scrub_seek_->playback_restarted = false;
  scrub_seek_->authoritative_position.reset();
  scrub_seek_->pending_target.reset();
  if (released) {
    const double final_target = pending.value_or(completed_target);
    // An approximate preview that drains after pointer release never counts
    // as the release seek, even if its keyframe happens to equal the target.
    if (!completed_exact || !nearlyEqual(final_target, completed_target)) {
      dispatchScrubSeek(final_target, true);
      return;
    }
    finishScrubGesture(true);
    return;
  }
  if (pending)
    dispatchScrubSeek(*pending, false);
}

void PlayerController::finishScrubGesture(bool restore_transport) {
  if (!scrub_seek_)
    return;
  cancelScrubTimeout();
  const bool intended_paused = scrub_seek_->intended_paused;
  const std::uint64_t active_command = scrub_seek_->command;
  const bool matching_lineage =
      scrub_seek_->request_serial == request_serial_ && committed_open_ &&
      committed_open_->request_serial == request_serial_ &&
      committed_open_->playlist_entry_id == scrub_seek_->playlist_entry_id &&
      active_event_playlist_entry_id_ == scrub_seek_->playlist_entry_id;
  if (active_command != 0 && engineReady()) {
    core_->api().mpv_abort_async_command(
        core_->handle(), kScrubCommandReplyTag | active_command);
  }
  scrub_seek_.reset();
  if (!restore_transport || !matching_lineage || !engineReady())
    return;
  int paused = intended_paused ? 1 : 0;
  if (core_->api().mpv_set_property(core_->handle(), "pause", MPV_FORMAT_FLAG,
                                    &paused) >= 0) {
    updatePause(intended_paused);
  }
}

void PlayerController::invalidateScrubGesture() { finishScrubGesture(false); }

void PlayerController::seekRelative(double seconds) {
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  if (native_playback_ && native_playback_->nativeOwnsTransport()) {
    if (std::isfinite(seconds))
      seekTo(position_ + seconds);
    return;
  }
#endif
  if (!engineReady() || !std::isfinite(seconds))
    return;
  if (scrub_seek_ || render_recovery_) {
    seekTo(position_ + seconds);
    return;
  }
  sendCommand(core_.get(),
              {QByteArrayLiteral("seek"), QByteArray::number(seconds, 'g', 12),
               QByteArrayLiteral("relative")});
}

void PlayerController::skipBackward() { seekRelative(-seek_step_seconds_); }
void PlayerController::skipForward() { seekRelative(seek_step_seconds_); }

void PlayerController::stepFrame(int direction) {
  if (direction == 0 || !hasMedia())
    return;
  const bool forward = direction > 0;

  // Stepping is a paused-transport gesture. Pressing "." while playing pauses
  // first and spends the press on the pause, exactly like every NLE: the
  // alternative -- pause and step in one press -- makes the first frame you
  // land on depend on scheduling latency, which is the one thing frame
  // stepping exists to remove.
  if (playing()) {
    pause();
    return;
  }

#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  if (native_playback_ && native_playback_->nativeOwnsTransport()) {
    // An audio-only generation proves no frame geometry and has nothing to
    // step; say so rather than seeking by a made-up interval.
    if (native_frame_start_ >= 0.0 && native_frame_duration_ <= 0.0)
      return;

    const bool geometry_covers_position =
        native_frame_start_ >= 0.0 && native_frame_duration_ > 0.0 &&
        position_ >= native_frame_start_ &&
        position_ - native_frame_start_ < native_frame_duration_;

    if (!geometry_covers_position) {
      // No proof yet for the frame actually on screen (nothing has been drawn
      // since the last open, or the position moved by a route the draw proof
      // did not narrate). Spend this press on one settling commit at the
      // current position -- which by definition lands on, and proves, the
      // covering frame -- and remember the direction for the proof's arrival.
      pending_frame_step_ = forward ? 1 : -1;
      const double settle = frameStepSeekTarget(position_, false);
      if (auto intent = makeNativeExactSeekIntent(settle)) {
        if (dispatchNativeSeekIntent(*intent) == NativeSeekDispatch::Consumed)
          return;
      }
      pending_frame_step_ = 0;
      return;
    }

    // The exact neighbour, from this frame's own duration -- never a nominal
    // frame interval, so a variable-frame-rate source steps onto its real
    // sample times.
    double raw = 0.0;
    if (forward) {
      raw = native_frame_start_ + native_frame_duration_;
      if (duration_ > 0.0 && raw >= duration_)
        return; // Already on the last frame.
    } else {
      if (native_frame_start_ <= 0.0)
        return; // Already on the first frame.
      raw = native_frame_start_;
    }
    // Forward rounds UP so the target reaches the next frame's interval;
    // backward rounds DOWN so it falls strictly short of this frame's start
    // and therefore inside the previous frame's interval.
    const double target = frameStepSeekTarget(raw, forward);
    if (!forward && !(target < native_frame_start_))
      return;
    pending_frame_step_ = 0;
    if (auto intent = makeNativeExactSeekIntent(target))
      static_cast<void>(dispatchNativeSeekIntent(*intent));
    return;
  }
#endif

  if (!engineReady())
    return;
  // The compatibility route has the operation natively and exactly: mpv's own
  // frame-step / frame-back-step decode by one presented picture, so no PTS
  // arithmetic happens here at all. frame-back-step is the expensive one (mpv
  // re-seeks and re-decodes from the preceding keyframe).
  sendCommand(core_.get(), {forward ? QByteArrayLiteral("frame-step")
                                    : QByteArrayLiteral("frame-back-step")});
}

void PlayerController::publishNativeFrameGeometry(double start_seconds,
                                                  double duration_seconds) {
  if (!std::isfinite(start_seconds) || !std::isfinite(duration_seconds))
    return;
  native_frame_start_ = std::max(0.0, start_seconds);
  native_frame_duration_ = std::max(0.0, duration_seconds);
  if (pending_frame_step_ == 0)
    return;
  // The settling commit above has landed and proved the covering frame; spend
  // the remembered direction now. Clearing first keeps a refused or clamped
  // step from re-arming itself on the proof its own commit publishes.
  const int direction = pending_frame_step_;
  pending_frame_step_ = 0;
  if (native_frame_duration_ <= 0.0)
    return;
  // Deferred, not immediate: this runs inside the owner's observation drain,
  // and dispatching the next commit from underneath it would re-enter the
  // session command path mid-drain. Zero-delay queued is the same idiom the
  // rest of this class uses for exactly that reason.
  QTimer::singleShot(0, this, [this, direction] { stepFrame(direction); });
}

void PlayerController::toggleMute() { setMuted(!muted_); }

void PlayerController::setMuted(bool muted) {
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  const bool native_owned =
      native_playback_ && native_playback_->setMuted(muted);
#else
  constexpr bool native_owned = false;
#endif
  if (!native_owned && engineReady()) {
    int value = muted ? 1 : 0;
    core_->api().mpv_set_property_async(core_->handle(), 0, "mute",
                                        MPV_FORMAT_FLAG, &value);
  }
  if (muted_ == muted)
    return;
  muted_ = muted;
  emit mutedChanged();
}

void PlayerController::setVolume(double volume) {
  if (!std::isfinite(volume))
    return;
  // The configured maximum, never the absolute one: the engine would happily
  // take 4.0, and the whole point of the setting is that this installation
  // has decided it should not.
  const double normalized =
      std::clamp(volume, kMinimumVolume, maximum_volume_);
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  const bool native_owned =
      native_playback_ &&
      native_playback_->setGain(static_cast<float>(normalized));
#else
  constexpr bool native_owned = false;
#endif
  if (!native_owned && engineReady()) {
    double mpv_volume = normalized * 100.0;
    core_->api().mpv_set_property_async(core_->handle(), 0, "volume",
                                        MPV_FORMAT_DOUBLE, &mpv_volume);
  }
  if (nearlyEqual(volume_, normalized))
    return;
  volume_ = normalized;
  emit volumeChanged();
}

void PlayerController::setMaximumVolume(double maximum) {
  if (!std::isfinite(maximum))
    return;
  const double normalized =
      std::clamp(maximum, kMinimumMaximumVolume, kMaximumVolume);
  if (nearlyEqual(maximum_volume_, normalized))
    return;
  maximum_volume_ = normalized;
  emit maximumVolumeChanged();
  // A window sitting above the new ceiling comes down at once rather than
  // staying loud until the next time something touches the level. setVolume
  // re-clamps against the maximum just installed, so the value it lands on is
  // exactly the new ceiling.
  if (volume_ > maximum_volume_) {
    setVolume(maximum_volume_);
    emit volumeClamped();
  }
}

void PlayerController::setScrollGesturesEnabled(bool enabled) {
  if (scroll_gestures_enabled_ == enabled)
    return;
  scroll_gestures_enabled_ = enabled;
  if (!enabled) {
    // Switching the preference off mid-sweep must not leave a scrub gesture
    // open on the native route -- that would hold the window paused with the
    // surface-budget handoff still armed.
    settleScrollGesture();
  }
  emit scrollGesturesEnabledChanged();
}

double PlayerController::snapVolumeToDetent(double volume) const {
  return ScrollGestureModel::snapVolumeToDetent(volume);
}

int PlayerController::scrollGesture(double pixelDeltaX, double pixelDeltaY,
                                    double angleDeltaX, double angleDeltaY,
                                    bool inverted, int phase) {
  if (!scroll_gestures_enabled_ || !hasMedia())
    return ScrollGestureIgnored;

  ScrollSample sample;
  sample.pixelX = pixelDeltaX;
  sample.pixelY = pixelDeltaY;
  sample.angleX = angleDeltaX;
  sample.angleY = angleDeltaY;
  sample.inverted = inverted;
  sample.phase = phase >= static_cast<int>(ScrollPhase::NoPhase) &&
                         phase <= static_cast<int>(ScrollPhase::Momentum)
                     ? static_cast<ScrollPhase>(phase)
                     : ScrollPhase::NoPhase;

  const ScrollStep step = scroll_model_.accumulate(sample);
  if (step.axis == ScrollAxis::None)
    return ScrollGestureIgnored;

  // Any admitted travel re-arms the settle timer: the gesture is over only
  // once the deltas actually stop arriving.
  if (scroll_settle_timer_)
    scroll_settle_timer_->start(kScrollSettleMs);
  if (!scroll_gesture_active_) {
    scroll_gesture_active_ = true;
    emit scrollGestureActiveChanged();
  }

  if (step.axis == ScrollAxis::Vertical) {
    // A vertical gesture cancels any sweep the previous gesture left open,
    // rather than interleaving a volume change into a live scrub.
    if (scroll_sweep_target_)
      commitScrollSweep();
    if (step.volumeDelta == 0.0)
      return ScrollGestureVolume;
    setVolume(scroll_model_.volumeWithDetent(volume_, step.volumeDelta,
                                             maximum_volume_));
    return ScrollGestureVolume;
  }

  if (step.seekSeconds == 0.0)
    return ScrollGestureSeek;

  if (!scroll_sweep_target_) {
    // Open exactly one scrub gesture for the whole sweep. beginScrub is the
    // same entry point the timeline's pointer drag uses, so the sweep gets
    // the native preview handoff, the captured logical pause intent and the
    // depth-1 latest-wins preview coalescing for free -- and previews are
    // never queued behind one another.
    beginScrub();
    scroll_sweep_target_ = position_;
  }
  const double maximum = duration_ > 0.0 ? duration_ : *scroll_sweep_target_;
  scroll_sweep_target_ = std::clamp(*scroll_sweep_target_ + step.seekSeconds,
                                    0.0, std::max(0.0, maximum));
  previewSeekTo(*scroll_sweep_target_);
  return ScrollGestureSeek;
}

void PlayerController::commitScrollSweep() {
  if (!scroll_sweep_target_)
    return;
  const double target = *scroll_sweep_target_;
  scroll_sweep_target_.reset();
  endScrub(target);
}

void PlayerController::settleScrollGesture() {
  if (scroll_settle_timer_)
    scroll_settle_timer_->stop();
  scroll_model_.reset();
  commitScrollSweep();
  if (scroll_gesture_active_) {
    scroll_gesture_active_ = false;
    emit scrollGestureActiveChanged();
  }
}

void PlayerController::setRate(double rate) {
  if (!std::isfinite(rate))
    return;
  const double bounded = std::clamp(rate, kMinimumRate, kMaximumRate);
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  if (native_playback_ && native_playback_->nativeOwnsTransport()) {
    // The native engine serves the advertised pitch-preserved window itself.
    // Only a rate outside that window still needs a refusal, and it gets the
    // non-blocking notice channel rather than a modal error: the speed slider
    // emits on every motion event, and an error dialog per pixel of drag is
    // not feedback, it is a trap.
    if (native_protocol::routeForRate(bounded) !=
        native_protocol::RateRoute::NativeVersion1) {
      setLastNotice(
          QStringLiteral("Native playback supports speeds from 0.25x to 4x."));
      return;
    }
    if (!native_playback_->setRate(bounded)) {
      setLastNotice(
          QStringLiteral("Native playback could not change the speed."));
      return;
    }
    if (nearlyEqual(rate_, bounded))
      return;
    rate_ = bounded;
    emit rateChanged();
    return;
  }
#endif
  if (engineReady()) {
    double value = bounded;
    core_->api().mpv_set_property_async(core_->handle(), 0, "speed",
                                        MPV_FORMAT_DOUBLE, &value);
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
  // The transport's captions button. It is a switch, not a picker: turning
  // subtitles on restores the last source this window showed, and failing
  // that takes the container's own preference, and failing that the first
  // source there is. Turning them off remembers what was showing, so the next
  // press brings back the same track rather than an arbitrary one.
  //
  // captionsVisible is therefore derived state -- "something is selected" --
  // on both routes. It is no longer mpv's sub-visibility flag, which is pinned
  // off because WAM draws the text itself.
  if (!subtitles_)
    return;
  if (!visible) {
    selectSubtitleTrack(SubtitleSources::kOffId);
    return;
  }
  int target = subtitles_->lastSelectedId();
  if (subtitles_->find(target) == nullptr)
    target = subtitles_->containerPreferredId();
  if (target == SubtitleSources::kOffId && !subtitles_->sources().empty())
    target = subtitles_->sources().front().id;
  if (target == SubtitleSources::kOffId) {
    setLastNotice(
        QStringLiteral("This file has no subtitles. Use Subtitles > Load "
                       "Subtitle File to add one."));
    return;
  }
  selectSubtitleTrack(target);
}

// ---------------------------------------------------------------------------
// Subtitles.
//
// One overlay, two feeders. Everything below decides WHICH source is showing
// and WHERE its text comes from; the drawing is qml/Main.qml's single Text
// item bound to subtitleText, so a line looks identical on either route.
// ---------------------------------------------------------------------------

QVariantList PlayerController::subtitleTracks() const {
  return subtitles_ ? subtitles_->toVariantList() : QVariantList{};
}

int PlayerController::activeSubtitleTrack() const {
  return subtitles_ ? subtitles_->activeId() : SubtitleSources::kOffId;
}

bool PlayerController::nativeSubtitleRouteActive() const {
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  return native_playback_ != nullptr && native_playback_->nativeOwnsTransport();
#else
  return false;
#endif
}

void PlayerController::publishSubtitleText(const QString &text) {
  // Emitting only on a real change is what keeps the overlay off the
  // per-frame path: between cue boundaries this is a string compare and
  // nothing else, so the scene graph is never dirtied by a subtitle that has
  // not changed.
  if (subtitle_text_ == text)
    return;
  subtitle_text_ = text;
  emit subtitleTextChanged();
}

void PlayerController::updateSubtitleBitmapForPosition() {
  if (!subtitles_)
    return;
  const bool off = subtitles_->activeId() == SubtitleSources::kOffId;
  const SubtitleSources::BitmapFrame &frame =
      off ? subtitles_->bitmapFrameAt(std::numeric_limits<double>::quiet_NaN())
          : subtitles_->bitmapFrameAt(position_);
  const QString url =
      frame.visible
          ? SubtitleBitmapProvider::urlFor(
                static_cast<quint64>(reinterpret_cast<quintptr>(subtitles_.get())),
                frame.serial)
          : QString();
  // Same discipline as publishSubtitleText: nothing is emitted between cue
  // turnovers, so an unchanged caption never dirties the scene graph.
  if (subtitle_bitmap_visible_ == frame.visible &&
      subtitle_bitmap_source_ == url && subtitle_bitmap_x_ == frame.x &&
      subtitle_bitmap_y_ == frame.y && subtitle_bitmap_width_ == frame.width &&
      subtitle_bitmap_height_ == frame.height)
    return;
  subtitle_bitmap_visible_ = frame.visible;
  subtitle_bitmap_source_ = url;
  subtitle_bitmap_x_ = frame.x;
  subtitle_bitmap_y_ = frame.y;
  subtitle_bitmap_width_ = frame.width;
  subtitle_bitmap_height_ = frame.height;
  emit subtitleBitmapChanged();
}

void PlayerController::updateSubtitleForPosition() {
  if (!subtitles_)
    return;
  // The bitmap overlay is a separate lane and is evaluated first: it is a no-op
  // when the selected track is text, so the text path below is unchanged.
  updateSubtitleBitmapForPosition();
  // On the compatibility route mpv pushes the line through `sub-text`; asking
  // an empty local cue list for it here would immediately blank it again.
  if (!subtitles_->hasCues())
    return;
  if (subtitles_->activeId() == SubtitleSources::kOffId) {
    publishSubtitleText({});
    return;
  }
  publishSubtitleText(subtitles_->textAt(position_));
}

void PlayerController::resetSubtitlesForMediaChange() {
  if (!subtitles_)
    return;
  subtitles_->clear();
  subtitle_sources_built_ = false;
  subtitle_sources_source_.clear();
  publishSubtitleText({});
  emit subtitleTracksChanged();
  emit activeSubtitleTrackChanged();
  if (captions_visible_) {
    captions_visible_ = false;
    emit captionsVisibleChanged();
  }
}

void PlayerController::buildMpvSubtitleSources() {
  std::vector<SubtitleSources::Source> tracks;
  const ReadyMpvClient client = readyMpvClient(core_.get());
  if (!client) {
    subtitles_->setEmbeddedTracks(std::move(tracks));
    return;
  }
  std::int64_t count = 0;
  if (client.api->mpv_get_property(client.handle, "track-list/count",
                                   MPV_FORMAT_INT64, &count) < 0 ||
      count <= 0) {
    subtitles_->setEmbeddedTracks(std::move(tracks));
    return;
  }
  // The flat sub-property idiom, not MPV_FORMAT_NODE: a node read would need
  // mpv_free_node_contents, which is not in the resolved symbol table, and
  // leaking the whole track list on every file open to avoid one loop is not
  // a trade worth making.
  const auto readString = [&client, &count](std::int64_t index,
                                            const char *field) -> QString {
    static_cast<void>(count);
    const QByteArray name = QByteArrayLiteral("track-list/") +
                            QByteArray::number(index) + '/' + field;
    char *value = client.api->mpv_get_property_string(client.handle,
                                                      name.constData());
    if (value == nullptr)
      return {};
    const QString result = QString::fromUtf8(value);
    client.api->mpv_free(value);
    return result;
  };

  for (std::int64_t index = 0; index < count; ++index) {
    if (readString(index, "type") != QStringLiteral("sub"))
      continue;
    bool ok = false;
    const std::int64_t sid = readString(index, "id").toLongLong(&ok);
    if (!ok || sid <= 0)
      continue;
    SubtitleSources::Source source;
    source.mpvSid = sid;
    source.language = readString(index, "lang");
    source.defaultFlag = readString(index, "default") == QStringLiteral("yes");
    source.forcedFlag = readString(index, "forced") == QStringLiteral("yes");
    const bool external =
        readString(index, "external") == QStringLiteral("yes");
    const QString title = readString(index, "title");
    const QString filename = readString(index, "external-filename");
    source.origin = external ? SubtitleSources::Origin::External
                             : SubtitleSources::Origin::Embedded;
    if (external && !filename.isEmpty()) {
      const std::filesystem::path path = std::filesystem::path(
          filename.toStdString());
      source.filePath = path;
      // Recognize this player's own caption output, so the menu says what the
      // user actually did rather than showing them a temp file name. Keyed on
      // the caption outputs specifically, NOT on attached_subtitle_files_:
      // that list holds every `sub-add`ed path including files the user chose,
      // and calling one of those "Generated Captions" is simply false.
      if (std::find(generated_caption_files_.begin(),
                    generated_caption_files_.end(),
                    path) != generated_caption_files_.end()) {
        source.origin = SubtitleSources::Origin::Generated;
      }
    }
    source.label = subtitleSourceLabel(source.origin, title, source.language,
                                       source.filePath, sid);
    tracks.push_back(std::move(source));
  }
  subtitles_->setEmbeddedTracks(std::move(tracks));
}

void PlayerController::buildNativeSubtitleSources() {
  std::vector<SubtitleSources::Source> tracks;
  const auto local = localPath(source_);
  if (local) {
    // Header-only: EBML header, Info and Tracks, stopping at the first
    // Cluster. This runs on every native open and must never become the
    // whole-file walk the demuxer's pre-admission pass was written to avoid;
    // that boundary is pinned by matroska_subtitles_test.
    const auto inventory =
        media::matroska::inspectMatroskaSubtitleTracks(*local);
    std::size_t ordinal = 0;
    for (const auto &track : inventory.tracks) {
      ++ordinal;
      SubtitleSources::Source source;
      source.matroskaTrack = track.number;
      source.codec = track.codec;
      // PGS and VobSub tracks are listed like any other; the loader picks the
      // bitmap lane from this field.
      source.bitmapCodec = track.bitmapCodec;
      source.filePath = *local;
      source.language = QString::fromStdString(track.language);
      source.defaultFlag = track.defaultFlag;
      source.forcedFlag = track.forcedFlag;
      source.label = subtitleSourceLabel(
          SubtitleSources::Origin::Embedded,
          QString::fromStdString(track.name), source.language, {},
          static_cast<std::int64_t>(ordinal));
      tracks.push_back(std::move(source));
    }

    // MP4/MOV timed text (tx3g, "mov_text"). Bounded exactly like the
    // Matroska pass above: it reads the 'moov' box and walks the sample
    // TABLE, never a sample payload, so its cost does not scale with the
    // file. A file is one container or the other, so at most one of these two
    // passes ever finds anything; the other reads a header and declines.
    const auto mp4Inventory = media::mp4::inspectMp4SubtitleTracks(*local);
    for (const auto &track : mp4Inventory.tracks) {
      // A 'clcp' closed-caption TRACK is enumerated by the inspector but is
      // not decodable yet; listing it would put a dead entry in the menu.
      if (track.kind != media::mp4::SubtitleTrackKind::Tx3gText) {
        continue;
      }
      ++ordinal;
      SubtitleSources::Source source;
      source.mp4Track = track.trackId;
      source.filePath = *local;
      source.language = QString::fromStdString(track.language);
      // tkhd's enabled flag is the closest thing MP4 has to Matroska's
      // default flag; a disabled track is listed but not auto-selected.
      source.defaultFlag = false;
      source.forcedFlag = false;
      source.label = subtitleSourceLabel(
          SubtitleSources::Origin::Embedded,
          QString::fromStdString(track.name), source.language, {},
          static_cast<std::int64_t>(ordinal));
      tracks.push_back(std::move(source));
    }
  }
  subtitles_->setEmbeddedTracks(std::move(tracks));
}

void PlayerController::applySubtitleDefaultPolicy() {
  // VLC's rule, and the container's own: show a subtitle track only when the
  // file asserts one should be shown. Anything else would put burned-in-
  // looking text over every foreign film the moment it opens.
  const int preferred = subtitles_->containerPreferredId();
  if (preferred == SubtitleSources::kOffId) {
    subtitles_->setActiveId(SubtitleSources::kOffId);
    return;
  }
  selectSubtitleTrack(preferred);
}

void PlayerController::refreshSubtitleSources() {
  if (!subtitles_ || source_.isEmpty())
    return;
  const bool native = nativeSubtitleRouteActive();
  const bool same_media = subtitle_sources_source_ == source_;
  const bool rebuild_only =
      subtitle_sources_built_ && same_media && subtitle_sources_native_ == native;

  // Capture the SELECTION by identity, not by id: a rebuild renumbers the
  // list, so an id held across it names a different track or none at all.
  const SubtitleSources::Source *previous =
      subtitles_->find(subtitles_->activeId());
  const bool had_selection = previous != nullptr;
  const SubtitleSources::Source previous_source =
      had_selection ? *previous : SubtitleSources::Source{};

  if (native)
    buildNativeSubtitleSources();
  else
    buildMpvSubtitleSources();

  subtitle_sources_source_ = source_;
  subtitle_sources_native_ = native;
  subtitle_sources_built_ = true;
  emit subtitleTracksChanged();

  if (rebuild_only) {
    // A `sub-add` added an entry; the selection the user already made stands
    // unless the source it named is gone.
    const int remapped =
        had_selection ? subtitles_->remap(previous_source)
                      : SubtitleSources::kOffId;
    if (remapped != subtitles_->activeId()) {
      subtitles_->setActiveId(remapped);
      subtitles_->noteSelected(remapped);
      emit activeSubtitleTrackChanged();
    }
    return;
  }
  applySubtitleDefaultPolicy();
  emit activeSubtitleTrackChanged();
}

void PlayerController::selectSubtitleTrack(int id) {
  if (!subtitles_)
    return;
  const SubtitleSources::Source *source = subtitles_->find(id);
  if (source == nullptr)
    id = SubtitleSources::kOffId;

  subtitles_->setActiveId(id);
  subtitles_->noteSelected(id);
  subtitles_->resetLookupHint();

  if (id == SubtitleSources::kOffId) {
    subtitles_->cancelNativeLoad();
    publishSubtitleText({});
  } else if (source->mpvSid > 0) {
    // Compatibility route: mpv owns selection and timing; the overlay is fed
    // by the sub-text observation.
    static_cast<void>(setTrackSelection(core_.get(), "sid", source->mpvSid));
    selected_subtitle_track_id_ = source->mpvSid;
    publishSubtitleText({});
  } else {
    // Native route: this process reads the cues, off the playback graph.
    publishSubtitleText({});
    subtitles_->beginNativeLoad(id);
  }

  if (id == SubtitleSources::kOffId && engineReady()) {
    static_cast<void>(setTrackSelection(core_.get(), "sid", 0));
    selected_subtitle_track_id_ = 0;
  }

  const bool visible = id != SubtitleSources::kOffId;
  if (captions_visible_ != visible) {
    captions_visible_ = visible;
    emit captionsVisibleChanged();
  }
  emit activeSubtitleTrackChanged();
  updateSubtitleForPosition();
}

void PlayerController::openSubtitleFileDialog() {
  emit openSubtitleFileDialogRequested();
}

bool PlayerController::loadSubtitleFile(const QUrl &file) {
  const auto path = localPath(file);
  if (!path) {
    setLastError(QStringLiteral("Only local subtitle files can be loaded."));
    return false;
  }
  return attachSubtitleSource(*path, static_cast<int>(
                                         SubtitleSources::Origin::External),
                              {});
}

bool PlayerController::attachSubtitleSource(const std::filesystem::path &path,
                                            int origin, const QString &label) {
  if (!subtitles_ || path.empty())
    return false;
  const auto kind = static_cast<SubtitleSources::Origin>(origin);
  if (kind == SubtitleSources::Origin::Generated &&
      std::find(generated_caption_files_.begin(),
                generated_caption_files_.end(),
                path) == generated_caption_files_.end()) {
    generated_caption_files_.push_back(path);
  }
  if (!nativeSubtitleRouteActive()) {
    // Compatibility route: hand it to mpv, which then reports it in
    // track-list and times it for us. The TrackListCount observation turns
    // that into a menu entry.
    if (!attachSubtitleFile(path))
      return false;
    refreshSubtitleSources();
    const int id = subtitles_->idForMpvSid(
        currentTrackSelection(core_.get(), "sid"));
    if (id != SubtitleSources::kOffId)
      selectSubtitleTrack(id);
    return true;
  }

  // Native route: there is no mpv, so the file is parsed here and becomes a
  // source alongside the embedded tracks.
  const int id = subtitles_->addFileSource(path, kind, label, 0);
  if (id == SubtitleSources::kOffId) {
    setLastError(QStringLiteral("That subtitle file could not be added."));
    return false;
  }
  emit subtitleTracksChanged();
  QString error;
  if (!subtitles_->loadFileCues(path, &error)) {
    setLastError(error);
    return false;
  }
  selectSubtitleTrack(id);
  return true;
}

void PlayerController::toggleFullscreen() { emit fullscreenToggleRequested(); }

void PlayerController::setPreservePitch(bool preserve) {
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  if (native_playback_ && native_playback_->nativeOwnsTransport()) {
    // The native stretch stage serves both modes: pitch preserved is a zero
    // pitch offset on the time-stretch unit, varispeed is an offset of
    // 1200 * log2(rate) cents on the same unit. Nothing to refuse, and it
    // applies live -- the render callback latches it at its next boundary.
    static_cast<void>(native_playback_->setPreservePitch(preserve));
    if (preserve_pitch_ != preserve) {
      preserve_pitch_ = preserve;
      emit preservePitchChanged();
    }
    return;
  }
#endif
  if (engineReady()) {
    int value = preserve ? 1 : 0;
    core_->api().mpv_set_property_async(
        core_->handle(), 0, "audio-pitch-correction", MPV_FORMAT_FLAG, &value);
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

void PlayerController::setSeekStepSeconds(double seconds) {
  if (!std::isfinite(seconds))
    return;
  const double bounded = std::clamp(seconds, 1.0, 60.0);
  if (nearlyEqual(seek_step_seconds_, bounded))
    return;
  seek_step_seconds_ = bounded;
  emit seekStepSecondsChanged();
}

void PlayerController::setWindowHugsVideo(bool hugsVideo) {
  if (window_hugs_video_ == hugsVideo)
    return;
  window_hugs_video_ = hugsVideo;
  emit windowHugsVideoChanged();
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

void PlayerController::setExportSpeed(double speed) {
  if (!std::isfinite(speed))
    return;
  // The same window buildExportProcess accepts, so a value that arrives here
  // is a value the export can actually run. Quick Edit offers a narrower
  // 0.25x-4x range; this clamp is the backstop, not the UI's rule.
  const double bounded = std::clamp(speed, 0.0625, 16.0);
  if (nearlyEqual(export_speed_, bounded))
    return;
  // Leaving 1x is what makes an MKV "fast copy" illegal, so the copy promise
  // is re-evaluated on every speed change, not only on format changes.
  const bool copied = exportStreamCopies();
  export_speed_ = bounded;
  emit exportSpeedChanged();
  if (copied != exportStreamCopies())
    emit exportStreamCopiesChanged();
}

void PlayerController::setExportPreservePitch(bool preserve) {
  if (export_preserve_pitch_ == preserve)
    return;
  export_preserve_pitch_ = preserve;
  emit exportPreservePitchChanged();
}

int PlayerController::exportFormat() const {
  return static_cast<int>(export_format_);
}

bool PlayerController::exportStreamCopies() const {
  // Asked of the same predicate the export itself will use, with the same
  // inputs, so the sheet can never promise a copy the encoder then declines.
  ::wam::EditOptions probe;
  probe.format = export_format_;
  probe.speed = export_speed_;
  probe.crop = crop_;
  return ::wam::exportUsesStreamCopy(probe);
}

void PlayerController::setExportFormat(int format) {
  if (format < static_cast<int>(::wam::ExportFormat::Mp4H264) ||
      format > static_cast<int>(::wam::ExportFormat::Gif)) {
    return;
  }
  const auto chosen = static_cast<::wam::ExportFormat>(format);
  if (export_format_ == chosen)
    return;
  const bool copied = exportStreamCopies();
  export_format_ = chosen;
  emit exportFormatChanged();
  if (copied != exportStreamCopies())
    emit exportStreamCopiesChanged();
}

QString PlayerController::exportFileSuffix() const {
  return QString::fromLatin1(::wam::exportFormatExtension(export_format_));
}

void PlayerController::setCrop(double x, double y, double width,
                               double height) {
  if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(width) ||
      !std::isfinite(height)) {
    return;
  }
  // The same clamp cropFilter applies, applied here too so the value the UI
  // reads back is the value the export will use -- a rectangle that silently
  // differs between the overlay and the encoder is the one bug this feature
  // must not have.
  ::wam::CropRect bounded;
  bounded.width = std::clamp(width, 0.02, 1.0);
  bounded.height = std::clamp(height, 0.02, 1.0);
  bounded.x = std::clamp(x, 0.0, 1.0 - bounded.width);
  bounded.y = std::clamp(y, 0.0, 1.0 - bounded.height);
  if (nearlyEqual(bounded.x, crop_.x) && nearlyEqual(bounded.y, crop_.y) &&
      nearlyEqual(bounded.width, crop_.width) &&
      nearlyEqual(bounded.height, crop_.height)) {
    return;
  }
  const bool copied = exportStreamCopies();
  crop_ = bounded;
  emit cropChanged();
  if (copied != exportStreamCopies())
    emit exportStreamCopiesChanged();
}

void PlayerController::resetCrop() { setCrop(0.0, 0.0, 1.0, 1.0); }

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
  // The preset decides the container, so it decides the extension -- both for
  // an extensionless choice and for one the dialog's own default suffix
  // already supplied.
  if (output->extension().empty())
    *output += ::wam::exportFormatExtension(export_format_);

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
  // Export retiming is its own decision. Reading rate_ here used to bake the
  // current *viewing* speed into every export, so reviewing a clip at 2x
  // silently shipped a 2x cut; Quick Edit now owns an explicit export speed
  // that starts at 1x, and the live transport no longer reaches this path.
  options.speed = export_speed_;
  options.preserve_pitch = export_preserve_pitch_;
  options.prefer_hardware_encoder = true;
  options.format = export_format_;
  options.crop = crop_;

#ifdef _WIN32
  const auto ffmpeg_search =
      ::wam::executableSearch("FFmpeg", "ffmpeg.exe", nullptr);
#else
  const auto ffmpeg_search =
      ::wam::executableSearch("FFmpeg", "ffmpeg", nullptr);
#endif
  // Resolve before reserving anything: a GUI launch inherits only
  // LaunchServices' minimal PATH, so this is the failure users actually hit,
  // and it must not leave a staging file behind.
  const auto ffmpeg =
      ::wam::resolveTool(ffmpeg_search, ::wam::toolIsExecutable);
  if (ffmpeg.empty()) {
    setLastError(fromUtf8(::wam::toolSearchFailure(ffmpeg_search)));
    return;
  }

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
        } else if (attachSubtitleSource(
                       status.output_srt,
                       static_cast<int>(SubtitleSources::Origin::Generated),
                       QStringLiteral("Generated Captions"))) {
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
  const int result =
      core_->api().mpv_command(core_->handle(), arguments.data());
  if (result < 0)
    return false;
  if (std::find(attached_subtitle_files_.begin(),
                attached_subtitle_files_.end(),
                subtitle) == attached_subtitle_files_.end()) {
    attached_subtitle_files_.push_back(subtitle);
  }
  // Deliberately NOT setCaptionsVisible(true) any more: selecting the source
  // is what turns subtitles on, and doing both would fight over which track
  // the switch restores.
  return true;
}

void PlayerController::drainMpvEvents() {
  if (!engineReady())
    return;

#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  struct NativeDrainScope final {
    NativePlaybackOwner *owner{nullptr};
    explicit NativeDrainScope(NativePlaybackOwner *value) : owner(value) {
      if (owner)
        owner->beginFallbackEventDrain();
    }
    ~NativeDrainScope() {
      if (owner)
        owner->endFallbackEventDrain();
    }
  } native_drain_scope{native_playback_.get()};
#endif

  while (true) {
    mpv_event *event = core_->api().mpv_wait_event(core_->handle(), 0.0);
    if (!event || event->event_id == MPV_EVENT_NONE)
      break;

    if (event->event_id == MPV_EVENT_COMMAND_REPLY) {
      const std::uint64_t reply_namespace =
          event->reply_userdata & kCommandReplyNamespaceMask;
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
      if (native_playback_ &&
          reply_namespace == kFallbackStopCommandReplyNamespace) {
        native_playback_->fallbackStopCommandReply(event->reply_userdata,
                                                   event->error);
        continue;
      }
#endif
      if ((event->reply_userdata & kScrubCommandReplyMask) ==
          kScrubCommandReplyTag) {
        handleScrubCommandReply(event->reply_userdata, event->error);
        continue;
      }
      if (reply_namespace == kOpenCommandReplyNamespace) {
        handleOpenCommandReply(event->reply_userdata, event->error);
        continue;
      }
      if (reply_namespace == kRenderRecoveryCommandReplyNamespace) {
        handleRenderRecoveryCommandReply(event->reply_userdata, event->error);
        continue;
      }
    }

#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
    // A retained compatibility handle is dormant during native playback.
    // Ignore its stale file/property stream, while the exact Stop command
    // reply above and idle observation below remain admitted during fallback
    // retirement.
    if (native_playback_ &&
        !native_playback_->acceptsFallbackPlaybackEvents()) {
      continue;
    }
#endif

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
      handleScrubPlaybackRestart();
      handlePlaybackReady(false);
      continue;
    }

    if (event->event_id == MPV_EVENT_SEEK) {
      if (scrub_seek_ && scrub_seek_->command != 0)
        scrub_seek_->seek_started = true;
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
      case ObservedProperty::Idle: {
        const bool idle = readFlag(property, true);
        applyObservedIdle(idle);
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
        if (native_playback_)
          native_playback_->fallbackIdleChanged(idle);
#endif
        break;
      }
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
            std::clamp(readDouble(property, 100.0) / 100.0, kMinimumVolume,
                       maximum_volume_);
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
      case ObservedProperty::CaptionsVisible:
        // Retained so the enumerator stays exhaustively handled. mpv's
        // sub-visibility is pinned off (WAM draws subtitles itself) and is no
        // longer observed, so this can only be reached by an mpv-side change
        // WAM did not ask for, which must not move the user's selection.
        break;
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
      case ObservedProperty::SubtitleText:
        // The compatibility route's feed into the shared overlay. mpv reports
        // the line with its own markup already resolved, so nothing here has
        // to re-parse ASS or SRT: that work only exists on the native route,
        // where there is no mpv to do it.
        if (subtitles_ && subtitles_->activeId() != SubtitleSources::kOffId)
          publishSubtitleText(readString(property));
        else
          publishSubtitleText({});
        break;
      case ObservedProperty::TrackListCount:
        // A `sub-add` (generated captions, a loaded file) changes the track
        // set without any other signal, so this is how a new source reaches
        // the menu.
        refreshSubtitleSources();
        break;
      case ObservedProperty::DisplayWidth:
      case ObservedProperty::DisplayHeight:
        // Either event means "the picture rectangle may have changed"; both
        // read the whole pair back. See the enum comment: publishing one half
        // of a new size against the surviving half of the old one would hand
        // window geometry an aspect ratio no video ever had.
        applyObservedDisplaySize();
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
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  // On the CALayer presentation route the frame is already on screen: the
  // AVSampleBufferDisplayLayer sitting below Qt's view was handed the decoded
  // IOSurface and WindowServer composites it directly. The Qt video item has
  // nothing to paint, so dirtying the scene here would buy a full scene-graph
  // render+swap per frame for no pixels -- measured at ~30 render passes per
  // second, against zero when the item stops updating and the chrome is hidden.
  // That is the pivot's headline cost, so it is not spent.
  //
  // The route flag is process-wide, but the suppression is NOT: it is only
  // correct for a window whose own playback the native route owns. WAM is a
  // multi-window player, so one window can be playing natively on the layer
  // route while another has fallen back to the compatibility engine and is
  // painting through the scene graph -- and suppressing that window's updates
  // because some OTHER window is on the layer route would freeze its video on
  // its first frame. Both halves of the test are therefore required.
  if (wam::macos::nativeLayerPresentationActive() && native_playback_ &&
      native_playback_->nativeOwnsTransport())
    return;
#endif
  if (video_item_)
    video_item_->update();
}

bool PlayerController::needsRenderContext() const {
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  return engineReady() && native_playback_ &&
         native_playback_->needsFallbackRenderContext() &&
         !requested_source_.isEmpty();
#else
  return engineReady() && !requested_source_.isEmpty();
#endif
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
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
    notifyRoutedFallbackOpenFailed();
#endif
    return false;
  }

  const QUrl display_source = displayUrlForSource(source);
  PlaybackSourceClass source_class = playbackSourceClass(display_source);
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  if (routed_fallback_open_) {
    source_class = routed_fallback_open_->source_class;
  }
#endif
  applyPlaybackBufferPolicy(core_.get(), source_class);
  if (!core_->validateRenderTicket(ticket)) {
    continuePendingOpen();
    return true;
  }

  ++next_open_attempt_id_;
  next_open_attempt_id_ &= kOpenCommandReplyIdMask;
  if (next_open_attempt_id_ == 0)
    next_open_attempt_id_ = 1;
  const std::uint64_t reply_userdata =
      kOpenCommandReplyNamespace | next_open_attempt_id_;
  const QByteArray utf8 = argument.toUtf8();
  const int result = sendCommand(
      core_.get(),
      {QByteArrayLiteral("loadfile"), utf8, QByteArrayLiteral("replace")},
      reply_userdata);
  if (result < 0) {
    // A queueing failure is stable for this request. Leave renderer retries to
    // an explicit subsequent open instead of spinning every frame.
    abandonPendingOpen();
    setLastError(QStringLiteral("Unable to open media: %1")
                     .arg(mpvErrorDetail(core_.get(), result)));
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
    notifyRoutedFallbackOpenFailed();
#endif
    return false;
  }

  open_attempt_ =
      OpenAttempt{next_open_attempt_id_, request_serial, render_stamp};
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
      kRenderRecoveryCommandReplyNamespace | next_render_recovery_attempt_id_;
  int result = MPV_ERROR_INVALID_PARAMETER;
  bool restarted_playlist_entry = false;
  if (render_recovery_->mode == RenderRecoveryMode::VideoReselect) {
    // The ordinary A/V path keeps the current demuxer, audio, subtitle files
    // and track selections alive. Only the exact built-in video track is
    // reselected after render-context teardown deselected the VO.
    const QByteArray track =
        QByteArray::number(render_recovery_->video_track_id);
    result =
        sendCommand(core_.get(),
                    {QByteArrayLiteral("set"), QByteArrayLiteral("vid"), track},
                    reply_userdata);
  } else {
    // With video-only media, deselecting the last A/V track unloads the file
    // despite keep-open. Restart the retained playlist entry in place whenever
    // possible: unlike `loadfile replace`, this preserves redirect children
    // and the remaining sibling continuation. restoreRenderRecovery()
    // re-attaches WAM subtitles and exact selections before transport state.
    const std::int64_t playlist_position = playlistPositionForEntry(
        core_.get(), committed_open_->playlist_entry_id);
    render_recovery_->preserve_playlist_context =
        render_recovery_->preserve_playlist_context ||
        playlistEntryCount(core_.get()) > 1 || !redirect_ranges_.empty();
    if (playlist_position >= 0) {
      render_recovery_->playlist_position = playlist_position;
      const QByteArray position = QByteArray::number(playlist_position);
      result = sendCommand(core_.get(),
                           {QByteArrayLiteral("playlist-play-index"), position},
                           reply_userdata);
      restarted_playlist_entry = result >= 0;
    } else if (!render_recovery_->preserve_playlist_context) {
      // A standalone entry may have been removed by video-only VO teardown.
      // Replacing that one source cannot discard a playlist continuation.
      const QByteArray source =
          sourceArgument(render_recovery_->reload_source).toUtf8();
      if (!source.isEmpty()) {
        result = sendCommand(core_.get(),
                             {QByteArrayLiteral("loadfile"), source,
                              QByteArrayLiteral("replace")},
                             reply_userdata);
      }
    }
  }
  if (result < 0) {
    render_recovery_->accepted_render_stamp = render_stamp;
    committed_open_->render_stamp = render_stamp;
    degradeRenderRecovery(QStringLiteral("Unable to restore video output: %1")
                              .arg(mpvErrorDetail(core_.get(), result)));
    return false;
  }

  render_recovery_attempt_ =
      RenderRecoveryAttempt{next_render_recovery_attempt_id_,
                            request_serial_,
                            render_stamp,
                            committed_open_->playlist_entry_id,
                            render_recovery_->video_track_id,
                            render_recovery_->mode,
                            -1,
                            restarted_playlist_entry};
  setLastError({});

  if (!core_->validateRenderTicket(ticket))
    continuePendingOpen();
  return true;
}

void PlayerController::handleOpenCommandReply(std::uint64_t reply_userdata,
                                              int error) {
  const std::uint64_t attempt_id = reply_userdata & kOpenCommandReplyIdMask;
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
                     .arg(mpvErrorDetail(core_.get(), error)));
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
    notifyRoutedFallbackOpenFailed();
#endif
    return;
  }

  const QUrl loaded_source = pending_source_;
  updateSource(displayUrlForSource(loaded_source));
  updateMediaTitle(fallbackTitle(loaded_source));
  OpenAttempt committed = attempt;
  const std::int64_t current_entry = currentPlaylistEntryId(core_.get());
  committed.playlist_entry_id =
      authoritativePlaylistEntry(current_entry, attempt.playlist_entry_id);
  committed_open_ = committed;
  int live_paused = paused_ ? 1 : 0;
  if (engineReady()) {
    static_cast<void>(core_->api().mpv_get_property(
        core_->handle(), "pause", MPV_FORMAT_FLAG, &live_paused));
  }
  StartupPlaybackSync startup_sync;
  startup_sync.request_serial = committed.request_serial;
  startup_sync.render_stamp = committed.render_stamp;
  startup_sync.playlist_entry_id = committed.playlist_entry_id;
  startup_sync.intended_paused = live_paused != 0;
  startup_playback_sync_ = startup_sync;
  committed_entry_source_ = displayUrlForSource(loaded_source);
  committed_playlist_position_ =
      playlistPositionForEntry(core_.get(), committed.playlist_entry_id);
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
  const std::int64_t video_track = currentVideoTrackId(core_.get());
  if (video_track > 0 && committed.playlist_entry_id >= 0) {
    selected_video_track_id_ = video_track;
    selected_tracks_playlist_entry_id_ = committed.playlist_entry_id;
  }
  pending_source_.clear();
  pending_request_serial_ = 0;
  open_attempt_.reset();
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  if (native_playback_ && routed_fallback_open_) {
    const RoutedFallbackOpen lineage = *routed_fallback_open_;
    routed_fallback_open_.reset();
    native_playback_->fallbackOpenSucceeded(lineage.attempt, lineage.serial,
                                            lineage.source_key);
  }
#endif
}

std::int64_t PlayerController::authoritativePlaylistEntry(
    std::int64_t live_entry, std::int64_t captured_start_entry) {
  return live_entry >= 0 ? live_entry : captured_start_entry;
}

void PlayerController::handleRenderRecoveryCommandReply(
    std::uint64_t reply_userdata, int error) {
  const std::uint64_t attempt_id = reply_userdata & kCommandReplyIdMask;
  if (!render_recovery_attempt_ || render_recovery_attempt_->id != attempt_id) {
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
    degradeRenderRecovery(QStringLiteral("Unable to restore video output: %1")
                              .arg(mpvErrorDetail(core_.get(), error)));
    return;
  }

  if (attempt.mode == RenderRecoveryMode::FullReload) {
    const std::int64_t current_entry = currentPlaylistEntryId(core_.get());
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
    const QUrl live_source = playlistEntrySource(core_.get(), reloaded_entry);
    committed_entry_source_ =
        live_source.isEmpty() ? render_recovery_->reload_source : live_source;
    committed_playlist_position_ =
        playlistPositionForEntry(core_.get(), reloaded_entry);
    if (committed_playlist_position_ < 0 && attempt.restarted_playlist_entry &&
        reloaded_entry == attempt.playlist_entry_id) {
      committed_playlist_position_ = render_recovery_->playlist_position;
    }
    if (!attempt.restarted_playlist_entry)
      redirect_ranges_.clear();
    if (active_event_playlist_entry_id_ != reloaded_entry)
      active_event_playlist_entry_id_ = -1;
  } else if (committed_open_->playlist_entry_id < 0 ||
             attempt.playlist_entry_id != committed_open_->playlist_entry_id) {
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
    const auto distance =
        static_cast<std::uint64_t>(playlist_entry_id - range.first);
    if (distance < range.count)
      return true;
  }
  return false;
}

void PlayerController::handleStartFile(std::int64_t playlist_entry_id) {
  if (scrub_seek_) {
    invalidateScrubGesture();
  }
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
      engineReady() ? playlistPositionForEntry(core_.get(), playlist_entry_id)
                    : -1;
  if (live_playlist_position >= 0 || entry_changed)
    committed_playlist_position_ = live_playlist_position;
  if (entry_changed) {
    committed_entry_source_ =
        engineReady() ? playlistEntrySource(core_.get(), playlist_entry_id)
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
  if (render_recovery_ && render_recovery_->request_serial == request_serial_) {
    if (render_recovery_->accepted_render_stamp != 0 && core_ &&
        core_->validateRenderTicket(
            {render_recovery_->accepted_render_stamp})) {
      committed_open_->render_stamp = render_recovery_->accepted_render_stamp;
    }
    if (render_recovery_attempt_ &&
        render_recovery_attempt_->request_serial == request_serial_ &&
        render_recovery_attempt_->mode == RenderRecoveryMode::VideoReselect) {
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

  invalidateScrubGesture();

  active_event_playlist_entry_id_ = -1;

  const bool expected_video_only_teardown =
      end.reason == MPV_END_FILE_REASON_ERROR &&
      (selected_tracks_playlist_entry_id_ !=
           committed_open_->playlist_entry_id ||
       selected_audio_track_id_ <= 0) &&
      core_ && !core_->validateRenderTicket({committed_open_->render_stamp});
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
    if (end.playlist_insert_id >= 0 && end.playlist_insert_num_entries > 0) {
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
      std::uint64_t adoption_stamp = render_recovery_->accepted_render_stamp;
      if ((!core_ || !core_->validateRenderTicket({adoption_stamp})) && core_) {
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
            render_recovery_->mode != RenderRecoveryMode::NoReselection) {
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
                     .arg(mpvErrorDetail(core_.get(), end.error)));
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
    if (native_playback_)
      native_playback_->fallbackPlaybackFailed();
#endif
  }
}

void PlayerController::handlePlaybackReady(bool file_loaded) {
  if (file_loaded)
    cacheCurrentEntrySource();
  if (file_loaded && last_error_playlist_entry_id_ >= 0 &&
      active_event_playlist_entry_id_ >= 0 &&
      active_event_playlist_entry_id_ != last_error_playlist_entry_id_) {
    last_error_playlist_entry_id_ = -1;
    setLastError({});
  }
  if (render_recovery_) {
    bool matching_lineage = false;
    if (committed_open_ && committed_open_->playlist_entry_id >= 0 &&
        committed_open_->playlist_entry_id == active_event_playlist_entry_id_) {
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
  // FILE_LOADED is the moment mpv's track-list is complete, and it is the one
  // hook that fires on both a first open and every fallback the router takes,
  // so it is where the Subtitles menu learns what this file offers.
  if (file_loaded) {
    refreshSubtitleSources();
    // And the moment the picture's size is knowable, for the same reason: it
    // is the one hook that fires on a first open and on every fallback the
    // router takes. The dwidth/dheight observations usually land just before
    // this, but they land inside the open and can be dropped by the path
    // check above while mpv still has the outgoing file; this is the reliable
    // second look, and updateVideoDisplaySize dedupes so the common case
    // where both agree costs one comparison.
    applyObservedDisplaySize();
  }
  restoreRenderRecovery();
}

bool PlayerController::acceptsPlaybackObservation() const {
  return !requested_source_.isEmpty() && pending_source_.isEmpty() &&
         pending_request_serial_ == 0 && !open_attempt_ && !scrub_seek_ &&
         !render_recovery_ && !startup_playback_sync_ && committed_open_ &&
         committed_open_->request_serial == request_serial_ &&
         committed_open_->playlist_entry_id >= 0 && core_ &&
         core_->validateRenderTicket({committed_open_->render_stamp}) &&
         active_event_playlist_entry_id_ == committed_open_->playlist_entry_id;
}

void PlayerController::applyObservedPause(bool paused) {
  if (acceptsPlaybackObservation())
    updatePause(paused);
}

void PlayerController::applyObservedPosition(double position) {
  if (!std::isfinite(position))
    return;
  const double value = std::max(0.0, position);
  if (scrub_seek_) {
    if (scrub_seek_->playback_restarted)
      scrub_seek_->authoritative_position = value;
    maybeCompleteScrubSeek();
    return;
  }
  if (!acceptsPlaybackObservation())
    return;
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

void PlayerController::applyObservedDisplaySize() {
  if (!core_ || !engineReady())
    return;
  // Deliberately NOT gated on acceptsPlaybackObservation(), which every other
  // observation here does use. Measured: mpv announces dwidth/dheight exactly
  // once per file, during the open, while that gate is still closed -- and it
  // never announces them again, because the value has not changed since. So
  // gating here did not defer the size, it discarded the only announcement
  // there was, and the fallback route stayed at (0, 0) for the whole session,
  // which is the very defect this feeder exists to fix.
  //
  // The hazard the gate guards against -- a previous file's value landing on
  // the current one -- is checked directly instead, and more precisely: the
  // size and the path it belongs to are read from the same mpv instance in
  // the same breath, and the pair is published only if that path is the media
  // this controller has already committed to. A size read while mpv still has
  // the outgoing file loaded therefore cannot be attributed to the incoming
  // one.
  const QSize size = currentVideoDisplaySize(core_.get());
  if (size.isEmpty())
    return;
  char *path = core_->api().mpv_get_property_string(core_->handle(), "path");
  if (!path)
    return;
  const QUrl playing = urlFromMpvPath(QString::fromUtf8(path));
  core_->api().mpv_free(path);
  if (playing.isEmpty() || playing != source_)
    return;
  updateVideoDisplaySize(size.width(), size.height());
}

void PlayerController::updateVideoDisplaySize(int width, int height) {
  // A backend that cannot state a size must not erase one another backend
  // already stated. The single place a size is deliberately forgotten is
  // resetTimeline(), which assigns the member directly for exactly that
  // reason; every other caller is announcing a fact, and "I don't know" is
  // not one. This is what keeps the native route's Prepared answer alive
  // when the compatibility engine is initialized alongside it and reports
  // nothing, and vice versa.
  if (width <= 0 || height <= 0)
    return;
  const QSize value(width, height);
  if (video_display_size_ == value)
    return;
  video_display_size_ = value;
  emit videoDisplaySizeChanged();
}

void PlayerController::applyObservedIdle(bool idle) {
  if (acceptsPlaybackObservation())
    updateIdle(idle);
}

void PlayerController::applyObservedEof(bool eof_reached) {
  if (acceptsPlaybackObservation())
    updateEof(eof_reached);
}

void PlayerController::applyObservedVideoTrack(std::int64_t video_track_id) {
  if (!acceptsPlaybackObservation())
    return;
  selected_video_track_id_ = video_track_id >= 0 ? video_track_id : -1;
  selected_tracks_playlist_entry_id_ = committed_open_->playlist_entry_id;
}

void PlayerController::applyObservedAudioTrack(std::int64_t audio_track_id) {
  if (!acceptsPlaybackObservation())
    return;
  selected_audio_track_id_ = audio_track_id >= 0 ? audio_track_id : -1;
  selected_tracks_playlist_entry_id_ = committed_open_->playlist_entry_id;
}

void PlayerController::applyObservedSubtitleTrack(
    std::int64_t subtitle_track_id) {
  if (!acceptsPlaybackObservation())
    return;
  selected_subtitle_track_id_ = subtitle_track_id >= 0 ? subtitle_track_id : -1;
  selected_tracks_playlist_entry_id_ = committed_open_->playlist_entry_id;
}

void PlayerController::cacheCurrentTrackSelection() {
  if (!core_ || !engineReady() || !committed_open_ ||
      active_event_playlist_entry_id_ < 0 ||
      active_event_playlist_entry_id_ != committed_open_->playlist_entry_id) {
    return;
  }
  selected_video_track_id_ = currentTrackSelection(core_.get(), "vid");
  selected_audio_track_id_ = currentTrackSelection(core_.get(), "aid");
  selected_subtitle_track_id_ = currentTrackSelection(core_.get(), "sid");
  selected_tracks_playlist_entry_id_ = committed_open_->playlist_entry_id;
  current_file_has_audio_track_ = currentFileHasTrackType(core_.get(), "audio");
}

void PlayerController::cacheCurrentEntrySource() {
  if (!core_ || !engineReady() || !committed_open_ ||
      committed_open_->playlist_entry_id < 0 ||
      committed_open_->playlist_entry_id != active_event_playlist_entry_id_) {
    return;
  }
  char *path = core_->api().mpv_get_property_string(core_->handle(), "path");
  if (!path)
    return;
  const QUrl source = urlFromMpvPath(QString::fromUtf8(path));
  core_->api().mpv_free(path);
  if (!source.isEmpty()) {
    committed_entry_source_ = source;
    committed_playlist_position_ = playlistPositionForEntry(
        core_.get(), committed_open_->playlist_entry_id);
  }
}

void PlayerController::restoreRenderRecovery() {
  if (!render_recovery_ || !committed_open_ || !core_ || !engineReady() ||
      render_recovery_->request_serial != request_serial_ ||
      committed_open_->request_serial != request_serial_ ||
      render_recovery_->accepted_render_stamp == 0 ||
      !core_->validateRenderTicket({render_recovery_->accepted_render_stamp}) ||
      committed_open_->playlist_entry_id < 0 ||
      committed_open_->playlist_entry_id != active_event_playlist_entry_id_) {
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
        std::array<const char *, 4> arguments{"sub-add", path.constData(),
                                              select_last ? "select" : "auto",
                                              nullptr};
        if (core_->api().mpv_command(core_->handle(), arguments.data()) < 0) {
          scheduleRenderRecoveryRetry(
              QStringLiteral("Unable to restore external subtitles."));
          return;
        }
        recovery.external_subtitles_restored_count = index + 1;
      }
      recovery.external_subtitles_restored = true;
    }

    if (!recovery.per_file_state_restored) {
      if (!setTrackSelection(core_.get(), "vid", recovery.video_track_id) ||
          !setTrackSelection(core_.get(), "aid", recovery.audio_track_id)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore selected media tracks."));
        return;
      }
      if (recovery.subtitle_track_id == 0 ||
          (recovery.subtitle_track_id > 0 &&
           recovery.external_subtitles.empty())) {
        if (!setTrackSelection(core_.get(), "sid",
                               recovery.subtitle_track_id)) {
          scheduleRenderRecoveryRetry(
              QStringLiteral("Unable to restore the selected subtitle."));
          return;
        }
      }
      // Pinned off: WAM draws subtitles itself on both routes, so a recovered
      // render context must not start compositing mpv's own text under ours.
      int visible = 0;
      if (!setCoreProperty(core_.get(), "sub-visibility", MPV_FORMAT_FLAG,
                           &visible)) {
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
    const auto has_video = currentFileHasTrackType(core_.get(), "video");
    const auto has_audio = currentFileHasTrackType(core_.get(), "audio");
    const auto has_subtitle = currentFileHasTrackType(core_.get(), "sub");
    if (!has_video || !has_audio || !has_subtitle) {
      scheduleRenderRecoveryRetry(
          QStringLiteral("Unable to read the restored media tracks."));
      return;
    }
    std::int64_t video = currentTrackSelection(core_.get(), "vid");
    std::int64_t audio = currentTrackSelection(core_.get(), "aid");
    std::int64_t subtitle = currentTrackSelection(core_.get(), "sid");
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
    const std::int64_t live_entry = playingPlaylistEntryId(core_.get());
    int idle = 1;
    const bool live_video =
        recovery.video_track_id <= 0 ||
        currentTrackSelection(core_.get(), "vid") == recovery.video_track_id;
    if (live_entry != committed_open_->playlist_entry_id ||
        core_->api().mpv_get_property(core_->handle(), "idle-active",
                                      MPV_FORMAT_FLAG, &idle) < 0 ||
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
      if (!setCoreProperty(core_.get(), "pause", MPV_FORMAT_FLAG, &paused)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore the playback state."));
        return;
      }
      recovery.transport_restored = true;
    } else if (recovery.mode == RenderRecoveryMode::VideoReselect &&
               !recovery.paused && !recovery.position_overridden) {
      double live_position = 0.0;
      if (core_->api().mpv_get_property(core_->handle(), "time-pos",
                                        MPV_FORMAT_DOUBLE,
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
      if (!setCoreProperty(core_.get(), "pause", MPV_FORMAT_FLAG, &paused)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore the playback state."));
        return;
      }
      recovery.transport_restored = true;
    } else if (recovery.position > 0.01) {
      double position = recovery.position;
      if (!setCoreProperty(core_.get(), "time-pos", MPV_FORMAT_DOUBLE,
                           &position)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore the playback position."));
        return;
      }
      int paused = recovery.paused ? 1 : 0;
      if (!setCoreProperty(core_.get(), "pause", MPV_FORMAT_FLAG, &paused)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore the playback state."));
        return;
      }
      recovery.transport_restored = true;
    } else {
      int paused = recovery.paused ? 1 : 0;
      if (!setCoreProperty(core_.get(), "pause", MPV_FORMAT_FLAG, &paused)) {
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
  const std::uint64_t completion_token = next_render_recovery_completion_token_;
  const std::uint64_t request_serial = render_recovery_->request_serial;
  const std::uint64_t render_stamp = render_recovery_->accepted_render_stamp;
  const std::int64_t playlist_entry_id = committed_open_->playlist_entry_id;
  render_recovery_->completion_token = completion_token;

  // mpv can enqueue transient pause/idle/eof property changes while replacing
  // video-only media. Keep the recovery gate through the remainder of the
  // current event drain, then discard those transitions and publish one live,
  // coherent transport snapshot before observations are accepted again.
  QTimer::singleShot(0, this,
                     [this, completion_token, request_serial, render_stamp,
                      playlist_entry_id] {
                       finishRenderRecoveryCompletion(
                           completion_token, request_serial, render_stamp,
                           playlist_entry_id);
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
  if (core_->api().mpv_get_property(core_->handle(), "pause", MPV_FORMAT_FLAG,
                                    &paused) < 0 ||
      core_->api().mpv_get_property(core_->handle(), "idle-active",
                                    MPV_FORMAT_FLAG, &idle) < 0) {
    return std::nullopt;
  }

  std::optional<bool> live_eof_reached;
  if (core_->api().mpv_get_property(core_->handle(), "eof-reached",
                                    MPV_FORMAT_FLAG, &eof_reached) >= 0) {
    live_eof_reached = eof_reached != 0;
  }
  std::optional<double> live_position;
  if (core_->api().mpv_get_property(core_->handle(), "time-pos",
                                    MPV_FORMAT_DOUBLE, &position) >= 0 &&
      std::isfinite(position)) {
    live_position = std::max(0.0, position);
  }
  std::optional<double> live_duration;
  if (core_->api().mpv_get_property(core_->handle(), "duration",
                                    MPV_FORMAT_DOUBLE, &duration) >= 0 &&
      std::isfinite(duration)) {
    live_duration = std::max(0.0, duration);
  }

  return LivePlaybackState{paused != 0, idle != 0, live_eof_reached,
                           live_position, live_duration};
}

bool PlayerController::livePlaybackStateMatchesRecovery(
    const RenderRecovery &recovery, const LivePlaybackState &live_state) {
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
  const bool committed_eof = live_state.eof_reached.value_or(eof_reached_);
  const double committed_position =
      live_state.position.value_or(recovery.position);
  const bool position_changed = !nearlyEqual(position_, committed_position);

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
  selected_tracks_playlist_entry_id_ = committed_open_->playlist_entry_id;
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
  const std::uint64_t completion_token = next_startup_playback_sync_token_;
  const std::uint64_t request_serial = startup_playback_sync_->request_serial;
  const std::uint64_t render_stamp = startup_playback_sync_->render_stamp;
  const std::int64_t playlist_entry_id =
      startup_playback_sync_->playlist_entry_id;
  startup_playback_sync_->completion_token = completion_token;

  QTimer::singleShot(0, this,
                     [this, completion_token, request_serial, render_stamp,
                      playlist_entry_id] {
                       finishStartupPlaybackSync(completion_token,
                                                 request_serial, render_stamp,
                                                 playlist_entry_id);
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
      live_state &&
      livePlaybackStateMatchesStartupSync(*startup_playback_sync_, *live_state);
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
  const bool terminal =
      reconciled_state.idle || reconciled_state.eof_reached.value_or(false);
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
  const bool committed_eof = live_state.eof_reached.value_or(eof_reached_);
  const double committed_position =
      startup_sync.position_overridden
          ? startup_sync.intended_position.value_or(position_)
          : live_state.position.value_or(position_);
  const bool position_changed = !nearlyEqual(position_, committed_position);

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
  const std::uint64_t render_stamp = render_recovery_->accepted_render_stamp;
  QTimer::singleShot(kRetryDelaysMs[static_cast<std::size_t>(retry_index)],
                     this, [this, request_serial, render_stamp] {
                       if (!render_recovery_ ||
                           render_recovery_->request_serial != request_serial ||
                           render_recovery_->accepted_render_stamp !=
                               render_stamp) {
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
    static_cast<void>(core_->api().mpv_set_property(core_->handle(), "pause",
                                                    MPV_FORMAT_FLAG, &paused));

    int live_paused = paused;
    if (core_->api().mpv_get_property(core_->handle(), "pause", MPV_FORMAT_FLAG,
                                      &live_paused) >= 0) {
      updatePause(live_paused != 0);
    } else {
      updatePause(recovery.paused);
    }

    int live_idle = 0;
    if (core_->api().mpv_get_property(core_->handle(), "idle-active",
                                      MPV_FORMAT_FLAG, &live_idle) >= 0) {
      updateIdle(live_idle != 0);
    }

    double live_position = 0.0;
    if (core_->api().mpv_get_property(core_->handle(), "time-pos",
                                      MPV_FORMAT_DOUBLE, &live_position) >= 0 &&
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
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  const std::shared_ptr<PlayerCore> notifying_core = core_;
  if (native_playback_)
    native_playback_->fallbackRenderStateChanged();
  if (core_ != notifying_core)
    return;
#endif
  if (requested_source_.isEmpty())
    return;

  if (scrub_seek_ && committed_open_ &&
      committed_open_->render_stamp == retired_render_stamp) {
    invalidateScrubGesture();
  }

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
      committed_open_ && committed_open_->request_serial == request_serial_ &&
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
            (live_state->idle || live_state->eof_reached.value_or(false));
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
      const bool snapshot_proven = cached_tracks_are_current &&
                                   current_file_has_audio_track_.has_value();
      std::int64_t video_track =
          cached_tracks_are_current ? selected_video_track_id_ : -1;
      std::int64_t audio_track =
          cached_tracks_are_current ? selected_audio_track_id_ : -1;
      std::int64_t subtitle_track =
          cached_tracks_are_current ? selected_subtitle_track_id_ : -1;
      if (engineReady()) {
        const std::int64_t current_video = currentTrackId(core_.get(), "vid");
        const std::int64_t current_audio = currentTrackId(core_.get(), "aid");
        const std::int64_t current_subtitle =
            currentTrackId(core_.get(), "sid");
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
      recovery.position = std::max(0.0, startup_position.value_or(position_));
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
            core_.get(), committed_open_->playlist_entry_id);
        if (live_position >= 0)
          recovery.playlist_position = live_position;
        recovery.preserve_playlist_context =
            playlistEntryCount(core_.get()) > 1;
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
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  const bool routed_fallback_failure = routed_fallback_open_.has_value();
  if (routed_fallback_failure)
    abandonPendingOpen();
#endif
  setLastError(error);
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  if (routed_fallback_failure)
    notifyRoutedFallbackOpenFailed();
#endif
}

void PlayerController::attachVideoItem(MpvVideoItem *item) {
  video_item_ = item;
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  if (native_playback_)
    native_playback_->attachSurface(item);
#endif
  if (needsRenderContext())
    requestVideoUpdate();
}

void PlayerController::detachVideoItem(MpvVideoItem *item) {
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  invalidateNativeSeekIntents();
  if (native_playback_)
    native_playback_->detachSurface(item);
#endif
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
  resetSubtitlesForMediaChange();
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
  // The one place a display size is deliberately forgotten (see
  // updateVideoDisplaySize, which refuses to publish an empty one). Every
  // media transition routes through here, so the previous file's aspect
  // cannot outlive it into the next open's window geometry.
  if (!video_display_size_.isEmpty()) {
    video_display_size_ = QSize();
    emit videoDisplaySizeChanged();
  }
  if (!nearlyEqual(trim_in_, 0.0)) {
    trim_in_ = 0.0;
    emit trimInChanged();
  }
  if (!nearlyEqual(trim_out_, 0.0)) {
    trim_out_ = 0.0;
    emit trimOutChanged();
  }
  // Export retiming is a per-file editorial choice, not a preference: a new
  // media is a new edit, so it returns to "no retiming" alongside the trim
  // points it belongs with rather than carrying over silently.
  if (!nearlyEqual(export_speed_, 1.0)) {
    export_speed_ = 1.0;
    emit exportSpeedChanged();
  }
  // Same rule for the crop rectangle, and for the same reason with more
  // force: a rectangle is drawn against one shot's framing and is meaningless
  // -- not merely stale -- over the next file's. The FORMAT deliberately does
  // NOT reset here: "I export WebM" is a standing preference about where the
  // file is going, not a statement about this particular clip.
  if (crop_.active()) {
    crop_ = ::wam::CropRect{};
    emit cropChanged();
    emit exportStreamCopiesChanged();
  }
  if (!export_preserve_pitch_) {
    export_preserve_pitch_ = true;
    emit exportPreservePitchChanged();
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
  // A window on its way out has no user left to tell. See beginTeardown().
  if (tearing_down_)
    return;
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

void PlayerController::setLastNotice(const QString &notice) {
  if (!notice.isEmpty())
    qInfo().noquote() << "WAM:" << notice;
  if (last_notice_ == notice) {
    // Same treatment as setLastError: a repeated notice (e.g. the same
    // fallback text on a second file) still has to re-trigger the toast, not
    // be swallowed as an unchanged property.
    if (!notice.isEmpty())
      emit lastNoticeChanged();
    return;
  }
  last_notice_ = notice;
  emit lastNoticeChanged();
}

} // namespace wam::qt
