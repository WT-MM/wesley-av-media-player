#include "mpv_engine.hpp"

#include "media/startup_benchmark.hpp"
#include "player_controller.hpp"
#include "player_core_p.hpp"
#include "playback/mpv/mpv_runtime.hpp"

#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QFileInfo>
#include <QStorageInfo>
#include <QTimer>

#include <algorithm>
#include <new>
#include <vector>

#ifdef Q_OS_WIN
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace wam::qt {
namespace {

constexpr double kScrubConvergenceToleranceSeconds = 0.050;
constexpr int kScrubSeekTimeoutMs = 750;

using ::wam::playback::mpv::MpvApi;

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
  return parseTrackSelection(readString(property));
}

} // namespace

std::int64_t parseTrackSelection(const QString &text) {
  const QString value = text.trimmed();
  if (value.compare(QStringLiteral("no"), Qt::CaseInsensitive) == 0)
    return 0;
  bool valid = false;
  const qlonglong numeric = value.toLongLong(&valid);
  return valid && numeric > 0 ? static_cast<std::int64_t>(numeric) : -1;
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

QString displayPath(const std::filesystem::path &path) {
#ifdef _WIN32
  return QString::fromStdWString(path.wstring());
#else
  return QFile::decodeName(path.string().c_str());
#endif
}

QString fallbackTitle(const QUrl &source) {
  if (source.isLocalFile())
    return QFileInfo(source.toLocalFile()).fileName();
  const QString file_name = source.fileName();
  return file_name.isEmpty() ? source.host() : file_name;
}

// The classification of an open no router classified. Probing a mount is a
// blocking filesystem call, and on an unresponsive network share it blocks
// for as long as the kernel's mount timeout, so a routed open never asks here:
// NativeOpenPreflight classifies it off the GUI thread and flushPendingOpen
// uses that answer (RoutedFallbackOpen::source_class). Only a build with no
// native engine has no such worker edge and answers synchronously.
PlaybackSourceClass playbackSourceClass(const QUrl &source) {
  if (!source.isLocalFile())
    return PlaybackSourceClass::Network;

  const QString local_path = source.toLocalFile();
  const QStorageInfo storage(local_path);
  if (storage.isValid() &&
      isRemoteFilesystemType(storage.fileSystemType().toStdString())) {
    return PlaybackSourceClass::BufferedLocal;
  }

#if defined(Q_OS_WIN)
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


MpvEngine::MpvEngine(PlayerController *owner, MpvEngineHost &host)
    : core(std::make_shared<PlayerCore>(owner)), owner_(owner), host_(host) {
  // Scrubbing can issue many commands over one pointer gesture. Reusing one
  // timer avoids allocating a lambda/timer event for every command and makes
  // stale timeout ownership explicit when the capacity-one slot is rearmed.
  scrub_timeout_timer_ = new QTimer(owner);
  scrub_timeout_timer_->setSingleShot(true);
  scrub_timeout_timer_->setTimerType(Qt::PreciseTimer);
  QObject::connect(scrub_timeout_timer_, &QTimer::timeout, owner, [this] {
    const std::uint64_t gesture = scrub_timeout_gesture_;
    const std::uint64_t request_serial = scrub_timeout_request_serial_;
    const std::uint64_t command = scrub_timeout_command_;
    cancelScrubTimeout();
    handleScrubTimeout(gesture, request_serial, command);
  });
}

MpvEngine::~MpvEngine() {
  if (scrub_timeout_timer_)
    scrub_timeout_timer_->stop();
}

bool MpvEngine::ready() const { return core && core->ready(); }

bool MpvEngine::provision(
    std::shared_ptr<const ::wam::playback::mpv::MpvRuntime> runtime) {
  if (!runtime || !runtime->api().complete() || ready() || runtime_)
    return false;
  runtime_ = std::move(runtime);
  return true;
}

QString MpvEngine::provisionRuntime() {
  if (runtime_)
    return {};
  WAM_STARTUP_STAMP(FallbackLoadBegin);
#if defined(__APPLE__)
  auto loaded = ::wam::playback::mpv::MpvRuntime::load(
      QCoreApplication::applicationDirPath());
#else
  // libmpv supports many mpv_create() handles from one library image, and
  // the runtime is the immutable, process-lifetime API table -- not a
  // handle -- so every window sharing it is its intended use.
  auto loaded = ::wam::playback::mpv::MpvLinkedRuntimeFactory::create();
#endif
  WAM_STARTUP_STAMP(FallbackLoadEnd);
  if (!loaded || !provision(loaded.runtime)) {
    return loaded.detail.isEmpty()
               ? QStringLiteral(
                     "A playback component is missing. Reinstall WAM to restore it.")
               : loaded.detail;
  }
  return {};
}

bool MpvEngine::initialize() {
  WAM_STARTUP_STAMP(FallbackInitializeBegin);
  const bool initialized = core->initialize(runtime_);
  WAM_STARTUP_STAMP(FallbackInitializeEnd);
  return initialized;
}

bool MpvEngine::reserveReplacement() {
  if (replacement_)
    return true;
  try {
    replacement_ = std::make_shared<PlayerCore>(owner_);
  } catch (...) {
    return false;
  }
  return true;
}

bool MpvEngine::replaceAfterRenderRelease(
    const std::shared_ptr<PlayerCore> &expected) {
  if (!expected || core != expected || !replacement_)
    return false;
  if (!expected->retireFallbackAfterRenderRelease(owner_))
    return false;
  core = std::move(replacement_);
  lineage = {};
  return true;
}

bool MpvEngine::setPausedNow(bool paused) {
  if (!ready())
    return false;
  int flag = paused ? 1 : 0;
  return core->api().mpv_set_property(core->handle(), "pause",
                                      MPV_FORMAT_FLAG, &flag) >= 0;
}

bool MpvEngine::submitStop(std::uint64_t reply_userdata) {
  if (!ready())
    return false;
  const char *arguments[] = {"stop", nullptr};
  return core->api().mpv_command_async(core->handle(), reply_userdata,
                                       arguments) >= 0;
}

bool MpvEngine::idle() const {
  int idle = 0;
  return ready() &&
         core->api().mpv_get_property(core->handle(), "idle-active",
                                      MPV_FORMAT_FLAG, &idle) >= 0 &&
         idle != 0;
}

void MpvEngine::revokeRendering() {
  core->revokeRenderContext();
  if (!core->renderContextBusy() &&
      RenderLifecycle::phase(core->renderLifecycleSnapshot()) ==
          RenderPhase::Failed) {
    static_cast<void>(core->retryFailedRenderContext());
  }
}

bool MpvEngine::renderingReleased() const {
  return core && !core->renderContextBusy() &&
         RenderLifecycle::phase(core->renderLifecycleSnapshot()) ==
             RenderPhase::Empty;
}

NativePlaybackMetricsSample MpvEngine::metrics() const {
  return core ? core->fallbackMetrics() : NativePlaybackMetricsSample{};
}

QString MpvEngine::mpvErrorDetail(int error) const {
  const ReadyMpvClient client = readyMpvClient(core.get());
  if (client) {
    if (const char *const detail = client.api->mpv_error_string(error))
      return QString::fromUtf8(detail);
  }
  return QStringLiteral("media-engine error %1").arg(error);
}

bool MpvEngine::setPlaybackProperty(const char *name,
                         const char *value) {
  const ReadyMpvClient client = readyMpvClient(core.get());
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

void MpvEngine::applyPlaybackBufferPolicy(PlaybackSourceClass source_class) {
  const PlaybackBufferPolicy policy = playbackBufferPolicy(source_class);
  setPlaybackProperty("cache", policy.cache_mode);
  setPlaybackProperty("cache-secs", policy.cache_seconds);
  setPlaybackProperty("demuxer-readahead-secs", policy.readahead_seconds);
  setPlaybackProperty("demuxer-max-bytes", policy.forward_bytes);
  setPlaybackProperty("demuxer-max-back-bytes", policy.backward_bytes);
  setPlaybackProperty("demuxer-hysteresis-secs",
                      policy.hysteresis_seconds);
}

int MpvEngine::sendCommand(const std::initializer_list<QByteArray> &arguments,
                std::uint64_t reply_userdata) {
  if (arguments.size() == 0)
    return MPV_ERROR_INVALID_PARAMETER;
  const ReadyMpvClient client = readyMpvClient(core.get());
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

bool MpvEngine::setCoreProperty(const char *name, mpv_format format,
                     void *value) {
  const ReadyMpvClient client = readyMpvClient(core.get());
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

bool MpvEngine::setTrackSelection(const char *name,
                       std::int64_t selection) {
  if (selection < 0)
    return true;
  const ReadyMpvClient client = readyMpvClient(core.get());
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
  return setCoreProperty(name, MPV_FORMAT_INT64, &value);
}

std::int64_t MpvEngine::playlistEntryIdAtPosition(const char *position_property) const {
  const ReadyMpvClient client = readyMpvClient(core.get());
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

std::int64_t MpvEngine::currentPlaylistEntryId() const {
  return playlistEntryIdAtPosition("playlist-pos");
}

std::int64_t MpvEngine::playingPlaylistEntryId() const {
  return playlistEntryIdAtPosition("playlist-playing-pos");
}

std::int64_t MpvEngine::playlistEntryCount() const {
  const ReadyMpvClient client = readyMpvClient(core.get());
  if (!client)
    return 0;
  std::int64_t count = 0;
  if (client.api->mpv_get_property(client.handle, "playlist/count",
                                   MPV_FORMAT_INT64, &count) < 0) {
    return 0;
  }
  return std::max<std::int64_t>(0, count);
}

std::int64_t MpvEngine::playlistPositionForEntry(std::int64_t entry_id) const {
  if (entry_id < 0)
    return -1;
  const ReadyMpvClient client = readyMpvClient(core.get());
  if (!client)
    return -1;
  const std::int64_t count = playlistEntryCount();
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

QUrl MpvEngine::playlistEntrySource(std::int64_t entry_id) const {
  const std::int64_t index = playlistPositionForEntry(entry_id);
  if (index < 0)
    return {};
  const ReadyMpvClient client = readyMpvClient(core.get());
  const QByteArray filename_property = QByteArrayLiteral("playlist/") +
                                       QByteArray::number(index) +
                                       QByteArrayLiteral("/filename");
  char *filename = client.api->mpv_get_property_string(
      client.handle, filename_property.constData());
  if (!filename)
    return {};
  const QUrl source = urlFromMpvPath(QString::fromUtf8(filename));
  client.api->mpv_free(filename);
  return source;
}

std::int64_t MpvEngine::currentTrackId(const char *name) const {
  const ReadyMpvClient client = readyMpvClient(core.get());
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

std::int64_t MpvEngine::currentTrackSelection(const char *name) const {
  const ReadyMpvClient client = readyMpvClient(core.get());
  if (!client)
    return -1;
  char *selection = client.api->mpv_get_property_string(client.handle, name);
  if (!selection)
    return -1;
  const QString value = QString::fromUtf8(selection);
  client.api->mpv_free(selection);
  return parseTrackSelection(value);
}

// mpv's display rectangle, read as one pair. dwidth/dheight are the picture
// size after the container's aspect ratio and any rotation have been applied,
// which is the size a window should be shaped to -- not the coded size, which
// is wrong for anamorphic video and wrong for a portrait phone clip. An empty
// QSize means mpv has no picture yet (no file, audio-only, or the video chain
// has not been reconfigured), which is exactly the "unknown" the caller wants.
QSize MpvEngine::currentVideoDisplaySize() const {
  const ReadyMpvClient client = readyMpvClient(core.get());
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

std::optional<bool> MpvEngine::currentFileHasTrackType(const char *type) const {
  const ReadyMpvClient client = readyMpvClient(core.get());
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

std::optional<std::int64_t> MpvEngine::intProperty(const char *name) const {
  const ReadyMpvClient client = readyMpvClient(core.get());
  std::int64_t value = 0;
  if (!client ||
      client.api->mpv_get_property(client.handle, name, MPV_FORMAT_INT64, &value) < 0)
    return std::nullopt;
  return value;
}

std::optional<double> MpvEngine::doubleProperty(const char *name) const {
  const ReadyMpvClient client = readyMpvClient(core.get());
  double value = 0.0;
  if (!client ||
      client.api->mpv_get_property(client.handle, name, MPV_FORMAT_DOUBLE, &value) < 0)
    return std::nullopt;
  return value;
}

std::optional<bool> MpvEngine::flagProperty(const char *name) const {
  const ReadyMpvClient client = readyMpvClient(core.get());
  int value = 0;
  if (!client ||
      client.api->mpv_get_property(client.handle, name, MPV_FORMAT_FLAG, &value) < 0)
    return std::nullopt;
  return value != 0;
}

std::optional<QString> MpvEngine::stringProperty(const char *name) const {
  const ReadyMpvClient client = readyMpvClient(core.get());
  char *value = client ? client.api->mpv_get_property_string(client.handle, name)
                       : nullptr;
  if (value == nullptr)
    return std::nullopt;
  QString result = QString::fromUtf8(value);
  client.api->mpv_free(value);
  return result;
}

void MpvEngine::setPropertyAsync(const char *name, mpv_format format,
                                 void *value) {
  if (const ReadyMpvClient client = readyMpvClient(core.get()))
    client.api->mpv_set_property_async(client.handle, 0, name, format, value);
}

int MpvEngine::commandNow(const char **arguments) {
  const ReadyMpvClient client = readyMpvClient(core.get());
  return client ? client.api->mpv_command(client.handle, arguments)
                : MPV_ERROR_INVALID_PARAMETER;
}

void MpvEngine::abortCommand(std::uint64_t reply_userdata) {
  if (const ReadyMpvClient client = readyMpvClient(core.get()))
    client.api->mpv_abort_async_command(client.handle, reply_userdata);
}

const char *MpvEngine::scrubSeekMode(bool exact) {
  return exact ? "absolute+exact" : "absolute+keyframes";
}

void MpvEngine::armScrubTimeout(std::uint64_t gesture,
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

void MpvEngine::cancelScrubTimeout() {
  if (scrub_timeout_timer_)
    scrub_timeout_timer_->stop();
  scrub_timeout_gesture_ = 0;
  scrub_timeout_request_serial_ = 0;
  scrub_timeout_command_ = 0;
}

void MpvEngine::dispatchScrubSeek(double target, bool exact) {
  if (!scrub_seek_ || !ready() || scrub_seek_->command != 0 ||
      scrub_seek_->request_serial != host_.requestSerial() || !lineage.committed_open ||
      lineage.committed_open->request_serial != host_.requestSerial() ||
      lineage.committed_open->playlist_entry_id != scrub_seek_->playlist_entry_id ||
      lineage.active_event_playlist_entry_id != scrub_seek_->playlist_entry_id) {
    finishScrubGesture(true);
    return;
  }

  const std::uint64_t command =
      nextMpvReplyId(MpvReply::Scrub, next_scrub_command_id_);
  const std::uint64_t reply_userdata = mpvReplyUserdata(MpvReply::Scrub, command);

  scrub_seek_->command = command;
  scrub_seek_->target = target;
  scrub_seek_->command_exact = exact;
  scrub_seek_->command_replied = false;
  scrub_seek_->seek_started = false;
  scrub_seek_->playback_restarted = false;
  scrub_seek_->authoritative_position.reset();
  const std::uint64_t gesture = scrub_seek_->gesture;
  const std::uint64_t request_serial = scrub_seek_->request_serial;
  const int result = sendCommand({QByteArrayLiteral("seek"),
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

void MpvEngine::handleScrubTimeout(std::uint64_t gesture,
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
  if (ready() && !scrub_seek_->abort_pending) {
    scrub_seek_->abort_pending = true;
    abortCommand(mpvReplyUserdata(MpvReply::Scrub, command));
  }
}

void MpvEngine::handleScrubCommandReply(std::uint64_t command,
                                               int error) {
  if (!scrub_seek_ || scrub_seek_->request_serial != host_.requestSerial() ||
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

void MpvEngine::handleScrubPlaybackRestart() {
  if (!scrub_seek_ || scrub_seek_->command == 0 || !scrub_seek_->seek_started ||
      scrub_seek_->request_serial != host_.requestSerial() || !lineage.committed_open ||
      lineage.committed_open->request_serial != host_.requestSerial() ||
      lineage.committed_open->playlist_entry_id != scrub_seek_->playlist_entry_id ||
      lineage.active_event_playlist_entry_id != scrub_seek_->playlist_entry_id ||
      !ready()) {
    return;
  }
  scrub_seek_->playback_restarted = true;
  const auto live_position = doubleProperty("time-pos");
  if (live_position && std::isfinite(*live_position))
    scrub_seek_->authoritative_position = std::max(0.0, *live_position);
  maybeCompleteScrubSeek();
}

void MpvEngine::maybeCompleteScrubSeek() {
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

void MpvEngine::finishScrubGesture(bool restore_transport) {
  if (!scrub_seek_)
    return;
  cancelScrubTimeout();
  const bool intended_paused = scrub_seek_->intended_paused;
  const std::uint64_t active_command = scrub_seek_->command;
  const bool matching_lineage =
      scrub_seek_->request_serial == host_.requestSerial() && lineage.committed_open &&
      lineage.committed_open->request_serial == host_.requestSerial() &&
      lineage.committed_open->playlist_entry_id == scrub_seek_->playlist_entry_id &&
      lineage.active_event_playlist_entry_id == scrub_seek_->playlist_entry_id;
  if (active_command != 0 && ready()) {
    abortCommand(mpvReplyUserdata(MpvReply::Scrub, active_command));
  }
  scrub_seek_.reset();
  if (!restore_transport || !matching_lineage || !ready())
    return;
  if (setPausedNow(intended_paused))
    host_.updatePause(intended_paused);
}

void MpvEngine::invalidateScrubGesture() { finishScrubGesture(false); }

bool MpvEngine::acceptsPlaybackObservation() const {
  return !host_.requestedSource().isEmpty() && lineage.pending_source.isEmpty() &&
         lineage.pending_request_serial == 0 && !lineage.open_attempt && !scrub_seek_ &&
         !lineage.render_recovery && !lineage.startup_playback_sync && lineage.committed_open &&
         lineage.committed_open->request_serial == host_.requestSerial() &&
         lineage.committed_open->playlist_entry_id >= 0 && core &&
         core->validateRenderTicket({lineage.committed_open->render_stamp}) &&
         lineage.active_event_playlist_entry_id == lineage.committed_open->playlist_entry_id;
}

void MpvEngine::beginScrub(double position) {
  if (!ready() || scrub_seek_ || lineage.render_recovery ||
      lineage.startup_playback_sync || !acceptsPlaybackObservation()) {
    return;
  }

  const std::optional<bool> live_paused = flagProperty("pause");
  if (!live_paused)
    return;
  ++next_scrub_gesture_id_;
  if (next_scrub_gesture_id_ == 0)
    ++next_scrub_gesture_id_;
  scrub_seek_ = ScrubSeek{next_scrub_gesture_id_,
                          host_.requestSerial(),
                          0,
                          lineage.committed_open->playlist_entry_id,
                          position,
                          std::nullopt,
                          std::nullopt,
                          *live_paused};

  if (!setPausedNow(true)) {
    scrub_seek_.reset();
    return;
  }
  host_.updatePause(*live_paused);
}

void MpvEngine::previewScrub(double target) {
  if (!scrub_seek_) {
    // Preview calls belong only to an explicitly owned pointer gesture. If
    // startup or render recovery refused ownership, ignore cadence updates;
    // the release path still performs one ordinary exact seek.
    return;
  }
  const std::uint64_t request_serial = host_.requestSerial();
  if (lineage.render_recovery && lineage.render_recovery->request_serial == request_serial) {
    lineage.render_recovery->position = target;
    lineage.render_recovery->transport_restored = false;
    lineage.render_recovery->position_overridden = true;
  }
  if (lineage.startup_playback_sync &&
      lineage.startup_playback_sync->request_serial == request_serial) {
    lineage.startup_playback_sync->intended_position = target;
    lineage.startup_playback_sync->position_overridden = true;
  }

  if (scrub_seek_->request_serial != request_serial) {
    invalidateScrubGesture();
    return;
  }
  if (scrub_seek_->command != 0) {
    scrub_seek_->pending_target = target;
  } else {
    dispatchScrubSeek(target, false);
  }
  host_.updatePosition(target);
}

bool MpvEngine::endScrub(double target, bool valid) {
  if (!scrub_seek_)
    return false;
  if (!ready() || !valid ||
      scrub_seek_->request_serial != host_.requestSerial()) {
    finishScrubGesture(true);
    return true;
  }
  scrub_seek_->final = true;
  scrub_seek_->pending_target = target;
  if (scrub_seek_->command == 0) {
    scrub_seek_->pending_target.reset();
    dispatchScrubSeek(target, true);
  }
  host_.updatePosition(target);
  return true;
}

void MpvEngine::setScrubIntendedPaused(bool paused) {
  if (scrub_seek_)
    scrub_seek_->intended_paused = paused;
}

void MpvEngine::noteSeekStarted() {
  if (scrub_seek_ && scrub_seek_->command != 0)
    scrub_seek_->seek_started = true;
}

bool MpvEngine::observeScrubPosition(double position) {
  if (!scrub_seek_)
    return false;
  if (scrub_seek_->playback_restarted)
    scrub_seek_->authoritative_position = position;
  maybeCompleteScrubSeek();
  return true;
}

bool MpvEngine::flushRenderRecovery(std::uint64_t render_stamp) {
  if (!lineage.render_recovery || !lineage.committed_open || !core || !ready() ||
      lineage.render_recovery->request_serial != host_.requestSerial() ||
      lineage.committed_open->request_serial != host_.requestSerial()) {
    return true;
  }

  const RenderTicket ticket{render_stamp};
  if (!core->validateRenderTicket(ticket))
    return true;

  if (lineage.render_recovery->accepted_render_stamp == render_stamp)
    return true;
  if (lineage.render_recovery_attempt &&
      lineage.render_recovery_attempt->request_serial == host_.requestSerial() &&
      lineage.render_recovery_attempt->render_stamp == render_stamp) {
    return true;
  }
  if (lineage.render_recovery->command_failed)
    return false;

  if (lineage.render_recovery->mode == RenderRecoveryMode::NoReselection) {
    lineage.render_recovery->accepted_render_stamp = render_stamp;
    lineage.committed_open->render_stamp = render_stamp;
    restoreRenderRecovery();
    return true;
  }

  if (lineage.render_recovery->mode == RenderRecoveryMode::VideoReselect &&
      (lineage.render_recovery->video_track_id <= 0 ||
       lineage.committed_open->playlist_entry_id < 0)) {
    lineage.render_recovery->accepted_render_stamp = render_stamp;
    lineage.committed_open->render_stamp = render_stamp;
    degradeRenderRecovery(QStringLiteral(
        "Unable to restore video output without changing media state."));
    return false;
  }

  const std::uint64_t reply_userdata = mpvReplyUserdata(
      MpvReply::RenderRecovery,
      nextMpvReplyId(MpvReply::RenderRecovery, next_render_recovery_attempt_id_));
  int result = MPV_ERROR_INVALID_PARAMETER;
  bool restarted_playlist_entry = false;
  if (lineage.render_recovery->mode == RenderRecoveryMode::VideoReselect) {
    // The ordinary A/V path keeps the current demuxer, audio, subtitle files
    // and track selections alive. Only the exact built-in video track is
    // reselected after render-context teardown deselected the VO.
    const QByteArray track =
        QByteArray::number(lineage.render_recovery->video_track_id);
    result =
        sendCommand({QByteArrayLiteral("set"), QByteArrayLiteral("vid"), track},
                    reply_userdata);
  } else {
    // With video-only media, deselecting the last A/V track unloads the file
    // despite keep-open. Restart the retained playlist entry in place whenever
    // possible: unlike `loadfile replace`, this preserves redirect children
    // and the remaining sibling continuation. restoreRenderRecovery()
    // re-attaches WAM subtitles and exact selections before transport state.
    const std::int64_t playlist_position = playlistPositionForEntry(lineage.committed_open->playlist_entry_id);
    lineage.render_recovery->preserve_playlist_context =
        lineage.render_recovery->preserve_playlist_context ||
        playlistEntryCount() > 1 || !lineage.redirect_ranges.empty();
    if (playlist_position >= 0) {
      lineage.render_recovery->playlist_position = playlist_position;
      const QByteArray position = QByteArray::number(playlist_position);
      result = sendCommand({QByteArrayLiteral("playlist-play-index"), position},
                           reply_userdata);
      restarted_playlist_entry = result >= 0;
    } else if (!lineage.render_recovery->preserve_playlist_context) {
      // A standalone entry may have been removed by video-only VO teardown.
      // Replacing that one source cannot discard a playlist continuation.
      const QByteArray source =
          sourceArgument(lineage.render_recovery->reload_source).toUtf8();
      if (!source.isEmpty()) {
        result = sendCommand({QByteArrayLiteral("loadfile"), source,
                              QByteArrayLiteral("replace")},
                             reply_userdata);
      }
    }
  }
  if (result < 0) {
    lineage.render_recovery->accepted_render_stamp = render_stamp;
    lineage.committed_open->render_stamp = render_stamp;
    degradeRenderRecovery(QStringLiteral("Unable to restore video output: %1")
                              .arg(mpvErrorDetail(result)));
    return false;
  }

  lineage.render_recovery_attempt =
      RenderRecoveryAttempt{next_render_recovery_attempt_id_,
                            host_.requestSerial(),
                            render_stamp,
                            lineage.committed_open->playlist_entry_id,
                            lineage.render_recovery->video_track_id,
                            lineage.render_recovery->mode,
                            -1,
                            restarted_playlist_entry};
  host_.setLastError({});

  if (!core->validateRenderTicket(ticket))
    continuePendingOpen();
  return true;
}

void MpvEngine::handleRenderRecoveryCommandReply(
    std::uint64_t attempt_id, int error) {
  if (!lineage.render_recovery_attempt || lineage.render_recovery_attempt->id != attempt_id) {
    return;
  }

  const RenderRecoveryAttempt attempt = *lineage.render_recovery_attempt;
  const bool current_request =
      lineage.render_recovery && lineage.committed_open &&
      attempt.request_serial == host_.requestSerial() &&
      lineage.render_recovery->request_serial == host_.requestSerial() &&
      lineage.committed_open->request_serial == host_.requestSerial();
  const bool current_renderer =
      core && core->validateRenderTicket({attempt.render_stamp});
  lineage.render_recovery_attempt.reset();

  if (!current_request)
    return;
  if (!current_renderer) {
    continuePendingOpen();
    return;
  }
  if (error < 0) {
    lineage.render_recovery->accepted_render_stamp = attempt.render_stamp;
    lineage.committed_open->render_stamp = attempt.render_stamp;
    degradeRenderRecovery(QStringLiteral("Unable to restore video output: %1")
                              .arg(mpvErrorDetail(error)));
    return;
  }

  if (attempt.mode == RenderRecoveryMode::FullReload) {
    const std::int64_t current_entry = currentPlaylistEntryId();
    const std::int64_t reloaded_entry = authoritativePlaylistEntry(
        current_entry, attempt.started_playlist_entry_id);
    if (reloaded_entry < 0) {
      lineage.render_recovery->accepted_render_stamp = attempt.render_stamp;
      lineage.committed_open->render_stamp = attempt.render_stamp;
      degradeRenderRecovery(QStringLiteral(
          "Unable to identify the reloaded video playlist entry."));
      return;
    }
    lineage.committed_open->playlist_entry_id = reloaded_entry;
    const QUrl live_source = playlistEntrySource(reloaded_entry);
    lineage.committed_entry_source =
        live_source.isEmpty() ? lineage.render_recovery->reload_source : live_source;
    lineage.committed_playlist_position =
        playlistPositionForEntry(reloaded_entry);
    if (lineage.committed_playlist_position < 0 && attempt.restarted_playlist_entry &&
        reloaded_entry == attempt.playlist_entry_id) {
      lineage.committed_playlist_position = lineage.render_recovery->playlist_position;
    }
    if (!attempt.restarted_playlist_entry)
      lineage.redirect_ranges.clear();
    if (lineage.active_event_playlist_entry_id != reloaded_entry)
      lineage.active_event_playlist_entry_id = -1;
  } else if (lineage.committed_open->playlist_entry_id < 0 ||
             attempt.playlist_entry_id != lineage.committed_open->playlist_entry_id) {
    return;
  }

  lineage.render_recovery->accepted_render_stamp = attempt.render_stamp;
  lineage.committed_open->render_stamp = attempt.render_stamp;
  host_.setLastError({});
  restoreRenderRecovery();
}

void MpvEngine::restoreRenderRecovery() {
  if (!lineage.render_recovery || !lineage.committed_open || !core || !ready() ||
      lineage.render_recovery->request_serial != host_.requestSerial() ||
      lineage.committed_open->request_serial != host_.requestSerial() ||
      lineage.render_recovery->accepted_render_stamp == 0 ||
      !core->validateRenderTicket({lineage.render_recovery->accepted_render_stamp}) ||
      lineage.committed_open->playlist_entry_id < 0 ||
      lineage.committed_open->playlist_entry_id != lineage.active_event_playlist_entry_id) {
    return;
  }

  RenderRecovery &recovery = *lineage.render_recovery;
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
        if (commandNow(arguments.data()) < 0) {
          scheduleRenderRecoveryRetry(
              QStringLiteral("Unable to restore external subtitles."));
          return;
        }
        recovery.external_subtitles_restored_count = index + 1;
      }
      recovery.external_subtitles_restored = true;
    }

    if (!recovery.per_file_state_restored) {
      if (!setTrackSelection("vid", recovery.video_track_id) ||
          !setTrackSelection("aid", recovery.audio_track_id)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore selected media tracks."));
        return;
      }
      if (recovery.subtitle_track_id == 0 ||
          (recovery.subtitle_track_id > 0 &&
           recovery.external_subtitles.empty())) {
        if (!setTrackSelection("sid",
                               recovery.subtitle_track_id)) {
          scheduleRenderRecoveryRetry(
              QStringLiteral("Unable to restore the selected subtitle."));
          return;
        }
      }
      // Pinned off: WAM draws subtitles itself on both routes, so a recovered
      // render context must not start compositing mpv's own text under ours.
      int visible = 0;
      if (!setCoreProperty("sub-visibility", MPV_FORMAT_FLAG,
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
    const auto has_video = currentFileHasTrackType("video");
    const auto has_audio = currentFileHasTrackType("audio");
    const auto has_subtitle = currentFileHasTrackType("sub");
    if (!has_video || !has_audio || !has_subtitle) {
      scheduleRenderRecoveryRetry(
          QStringLiteral("Unable to read the restored media tracks."));
      return;
    }
    std::int64_t video = currentTrackSelection("vid");
    std::int64_t audio = currentTrackSelection("aid");
    std::int64_t subtitle = currentTrackSelection("sid");
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
    const std::int64_t live_entry = playingPlaylistEntryId();
    const bool live_video =
        recovery.video_track_id <= 0 ||
        currentTrackSelection("vid") == recovery.video_track_id;
    if (live_entry != lineage.committed_open->playlist_entry_id ||
        flagProperty("idle-active").value_or(true) || !live_video) {
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
      if (!setCoreProperty("pause", MPV_FORMAT_FLAG, &paused)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore the playback state."));
        return;
      }
      recovery.transport_restored = true;
    } else if (recovery.mode == RenderRecoveryMode::VideoReselect &&
               !recovery.paused && !recovery.position_overridden) {
      const auto live_position = doubleProperty("time-pos");
      if (!live_position || !std::isfinite(*live_position)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to sample the live playback position."));
        return;
      }
      recovery.position = std::max(0.0, *live_position);
      host_.updatePosition(recovery.position);
      int paused = 0;
      if (!setCoreProperty("pause", MPV_FORMAT_FLAG, &paused)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore the playback state."));
        return;
      }
      recovery.transport_restored = true;
    } else if (recovery.position > 0.01) {
      double position = recovery.position;
      if (!setCoreProperty("time-pos", MPV_FORMAT_DOUBLE,
                           &position)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore the playback position."));
        return;
      }
      int paused = recovery.paused ? 1 : 0;
      if (!setCoreProperty("pause", MPV_FORMAT_FLAG, &paused)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore the playback state."));
        return;
      }
      recovery.transport_restored = true;
    } else {
      int paused = recovery.paused ? 1 : 0;
      if (!setCoreProperty("pause", MPV_FORMAT_FLAG, &paused)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore the playback state."));
        return;
      }
      recovery.transport_restored = true;
    }
  }

  queueRenderRecoveryCompletion();
}

void MpvEngine::queueRenderRecoveryCompletion() {
  if (!lineage.render_recovery || !lineage.committed_open || !core ||
      lineage.render_recovery->completion_token != 0 ||
      !lineage.render_recovery->transport_restored) {
    return;
  }

  ++next_render_recovery_completion_token_;
  if (next_render_recovery_completion_token_ == 0)
    ++next_render_recovery_completion_token_;
  const std::uint64_t completion_token = next_render_recovery_completion_token_;
  const std::uint64_t request_serial = lineage.render_recovery->request_serial;
  const std::uint64_t render_stamp = lineage.render_recovery->accepted_render_stamp;
  const std::int64_t playlist_entry_id = lineage.committed_open->playlist_entry_id;
  lineage.render_recovery->completion_token = completion_token;

  // mpv can enqueue transient pause/idle/eof property changes while replacing
  // video-only media. Keep the recovery gate through the remainder of the
  // current event drain, then discard those transitions and publish one live,
  // coherent transport snapshot before observations are accepted again.
  QTimer::singleShot(0, owner_,
                     [this, completion_token, request_serial, render_stamp,
                      playlist_entry_id] {
                       finishRenderRecoveryCompletion(
                           completion_token, request_serial, render_stamp,
                           playlist_entry_id);
                     });
}

void MpvEngine::finishRenderRecoveryCompletion(
    std::uint64_t completion_token, std::uint64_t request_serial,
    std::uint64_t render_stamp, std::int64_t playlist_entry_id) {
  const auto completion_is_current = [this, completion_token, request_serial,
                                      render_stamp, playlist_entry_id] {
    return lineage.render_recovery && lineage.committed_open && core &&
           lineage.render_recovery->completion_token == completion_token &&
           lineage.render_recovery->request_serial == request_serial &&
           lineage.render_recovery->accepted_render_stamp == render_stamp &&
           lineage.committed_open->request_serial == request_serial &&
           lineage.committed_open->render_stamp == render_stamp &&
           lineage.committed_open->playlist_entry_id == playlist_entry_id &&
           lineage.active_event_playlist_entry_id == playlist_entry_id &&
           core->validateRenderTicket({render_stamp});
  };

  if (!completion_is_current())
    return;

  // Property events already queued by the synchronous restore writes must
  // remain gated. A later EOF, Open, Stop or renderer invalidation mutates the
  // identity checked below and wins over this completion.
  drainMpvEvents();
  if (!completion_is_current())
    return;

  lineage.render_recovery->completion_token = 0;
  if (!lineage.render_recovery->transport_restored) {
    restoreRenderRecovery();
    return;
  }

  const auto live_state = readLivePlaybackState();
  if (!live_state ||
      !livePlaybackStateMatchesRecovery(*lineage.render_recovery, *live_state)) {
    scheduleRenderRecoveryRetry(
        QStringLiteral("Unable to refresh the restored playback state."));
    return;
  }

  const RenderRecovery captured = *lineage.render_recovery;
  commitRenderRecovery(captured, *live_state);
}

std::optional<MpvEngine::LivePlaybackState>
MpvEngine::readLivePlaybackState() const {
  if (!core || !ready())
    return std::nullopt;

  const auto paused = flagProperty("pause");
  const auto idle = flagProperty("idle-active");
  if (!paused || !idle)
    return std::nullopt;
  const auto nonnegative = [](std::optional<double> value) -> std::optional<double> {
    if (!value || !std::isfinite(*value))
      return std::nullopt;
    return std::max(0.0, *value);
  };
  return LivePlaybackState{*paused, *idle, flagProperty("eof-reached"),
                           nonnegative(doubleProperty("time-pos")),
                           nonnegative(doubleProperty("duration"))};
}

bool MpvEngine::livePlaybackStateMatchesRecovery(
    const RenderRecovery &recovery, const LivePlaybackState &live_state) {
  // Reaching EOF can make mpv pause itself before END_FILE is observable.
  // Likewise, an idle engine is already terminal. Both live terminal states
  // must win over the captured play intent instead of resurrecting playback.
  return live_state.eof_reached.value_or(false) || live_state.idle ||
         live_state.paused == recovery.paused;
}

bool MpvEngine::livePlaybackStateMatchesStartupSync(
    const StartupPlaybackSync &startup_sync,
    const LivePlaybackState &live_state) {
  return live_state.eof_reached.value_or(false) || live_state.idle ||
         live_state.paused == startup_sync.intended_paused;
}

void MpvEngine::commitRenderRecovery(
    const RenderRecovery &recovery, const LivePlaybackState &live_state) {
  if (!lineage.render_recovery || !lineage.committed_open)
    return;

  // Assign the complete transport snapshot while recovery still gates mpv
  // observations. Clearing the gate is the final state mutation, so every
  // signal handler observes one internally consistent post-recovery state.
  const MpvTransportChange change = host_.assignTransport(
      {live_state.paused, live_state.idle,
       live_state.eof_reached.value_or(host_.eofReached()),
       live_state.position.value_or(recovery.position)});
  lineage.selected_video_track_id = recovery.video_track_id;
  lineage.selected_audio_track_id = recovery.audio_track_id;
  lineage.selected_subtitle_track_id = recovery.subtitle_track_id;
  lineage.selected_tracks_playlist_entry_id = lineage.committed_open->playlist_entry_id;
  lineage.current_file_has_audio_track = recovery.file_has_audio_track;
  lineage.render_recovery.reset();
  if (live_state.duration)
    host_.updateDuration(*live_state.duration);

  host_.publishTransport(change);
}

void MpvEngine::queueStartupPlaybackSync() {
  if (!lineage.startup_playback_sync || !lineage.committed_open || !core ||
      lineage.startup_playback_sync->completion_token != 0 ||
      lineage.startup_playback_sync->request_serial != host_.requestSerial() ||
      lineage.startup_playback_sync->playlist_entry_id < 0 ||
      lineage.startup_playback_sync->playlist_entry_id !=
          lineage.active_event_playlist_entry_id) {
    return;
  }

  ++next_startup_playback_sync_token_;
  if (next_startup_playback_sync_token_ == 0)
    ++next_startup_playback_sync_token_;
  const std::uint64_t completion_token = next_startup_playback_sync_token_;
  const std::uint64_t request_serial = lineage.startup_playback_sync->request_serial;
  const std::uint64_t render_stamp = lineage.startup_playback_sync->render_stamp;
  const std::int64_t playlist_entry_id =
      lineage.startup_playback_sync->playlist_entry_id;
  lineage.startup_playback_sync->completion_token = completion_token;

  QTimer::singleShot(0, owner_,
                     [this, completion_token, request_serial, render_stamp,
                      playlist_entry_id] {
                       finishStartupPlaybackSync(completion_token,
                                                 request_serial, render_stamp,
                                                 playlist_entry_id);
                     });
}

void MpvEngine::finishStartupPlaybackSync(
    std::uint64_t completion_token, std::uint64_t request_serial,
    std::uint64_t render_stamp, std::int64_t playlist_entry_id) {
  const auto completion_is_current = [this, completion_token, request_serial,
                                      render_stamp, playlist_entry_id] {
    return lineage.startup_playback_sync && lineage.committed_open && core &&
           lineage.startup_playback_sync->completion_token == completion_token &&
           lineage.startup_playback_sync->request_serial == request_serial &&
           lineage.startup_playback_sync->render_stamp == render_stamp &&
           lineage.startup_playback_sync->playlist_entry_id == playlist_entry_id &&
           lineage.committed_open->request_serial == request_serial &&
           lineage.committed_open->render_stamp == render_stamp &&
           lineage.committed_open->playlist_entry_id == playlist_entry_id &&
           lineage.active_event_playlist_entry_id == playlist_entry_id &&
           core->validateRenderTicket({render_stamp});
  };

  if (!completion_is_current())
    return;

  // The one-shot pause/idle transitions for a new file may precede START_FILE.
  // Drain them while startup synchronization still gates observations, then
  // publish a single authoritative snapshot from the live engine.
  drainMpvEvents();
  if (!completion_is_current())
    return;

  lineage.startup_playback_sync->completion_token = 0;
  const auto live_state = readLivePlaybackState();
  const bool live_state_matches =
      live_state &&
      livePlaybackStateMatchesStartupSync(*lineage.startup_playback_sync, *live_state);
  if (!live_state_matches) {
    if (lineage.startup_playback_sync->retry_count < 3) {
      constexpr std::array<int, 3> kRetryDelaysMs{0, 16, 50};
      const int retry_index = lineage.startup_playback_sync->retry_count++;
      QTimer::singleShot(
          kRetryDelaysMs[static_cast<std::size_t>(retry_index)], owner_,
          [this, request_serial, render_stamp, playlist_entry_id] {
            if (!lineage.startup_playback_sync || !lineage.committed_open ||
                lineage.startup_playback_sync->request_serial != request_serial ||
                lineage.startup_playback_sync->render_stamp != render_stamp ||
                lineage.startup_playback_sync->playlist_entry_id !=
                    playlist_entry_id ||
                lineage.committed_open->request_serial != request_serial ||
                lineage.committed_open->render_stamp != render_stamp ||
                lineage.committed_open->playlist_entry_id != playlist_entry_id) {
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

    lineage.startup_playback_sync.reset();
    host_.setLastError(
        QStringLiteral("Unable to synchronize the initial playback state."));
    return;
  }

  commitStartupPlaybackSync(*live_state);
}

void MpvEngine::reconcileStartupPlaybackSync(
    const LivePlaybackState &live_state) {
  if (!lineage.startup_playback_sync)
    return;

  LivePlaybackState reconciled_state = live_state;
  const bool terminal =
      reconciled_state.idle || reconciled_state.eof_reached.value_or(false);
  if (!terminal)
    reconciled_state.paused = lineage.startup_playback_sync->intended_paused;
  commitStartupPlaybackSync(reconciled_state);
}

void MpvEngine::commitStartupPlaybackSync(
    const LivePlaybackState &live_state) {
  if (!lineage.startup_playback_sync || !lineage.committed_open)
    return;

  const StartupPlaybackSync startup_sync = *lineage.startup_playback_sync;
  const MpvTransportChange change = host_.assignTransport(
      {live_state.paused, live_state.idle,
       live_state.eof_reached.value_or(host_.eofReached()),
       startup_sync.position_overridden
           ? startup_sync.intended_position.value_or(host_.position())
           : live_state.position.value_or(host_.position())});
  lineage.startup_playback_sync.reset();
  cacheCurrentTrackSelection();
  if (live_state.duration)
    host_.updateDuration(*live_state.duration);

  host_.publishTransport(change);
}

void MpvEngine::scheduleRenderRecoveryRetry(const QString &error) {
  if (!lineage.render_recovery || !core)
    return;
  lineage.render_recovery->restore_failure = error;
  if (lineage.render_recovery->restore_retry_queued)
    return;
  if (lineage.render_recovery->restore_retry_count >= 3) {
    degradeRenderRecovery(error);
    return;
  }

  constexpr std::array<int, 3> kRetryDelaysMs{0, 16, 50};
  const int retry_index = lineage.render_recovery->restore_retry_count++;
  lineage.render_recovery->restore_retry_queued = true;
  const std::uint64_t request_serial = lineage.render_recovery->request_serial;
  const std::uint64_t render_stamp = lineage.render_recovery->accepted_render_stamp;
  QTimer::singleShot(kRetryDelaysMs[static_cast<std::size_t>(retry_index)],
                     owner_, [this, request_serial, render_stamp] {
                       if (!lineage.render_recovery ||
                           lineage.render_recovery->request_serial != request_serial ||
                           lineage.render_recovery->accepted_render_stamp !=
                               render_stamp) {
                         return;
                       }
                       lineage.render_recovery->restore_retry_queued = false;
                       restoreRenderRecovery();
                     });
}

void MpvEngine::degradeRenderRecovery(const QString &error) {
  if (!lineage.render_recovery)
    return;
  const RenderRecovery recovery = *lineage.render_recovery;
  lineage.render_recovery.reset();
  lineage.render_recovery_attempt.reset();

  if (core && ready()) {
    static_cast<void>(setPausedNow(recovery.paused));
    if (const auto live = readLivePlaybackState()) {
      host_.updatePause(live->paused);
      host_.updateIdle(live->idle);
      if (live->position)
        host_.updatePosition(*live->position);
    } else {
      host_.updatePause(recovery.paused);
    }
    cacheCurrentTrackSelection();
  }
  host_.setLastError(error);
}

void MpvEngine::handleRenderInvalidated(
    std::uint64_t retired_render_stamp) {
  const std::shared_ptr<PlayerCore> notifying_core = core;
  if (NativeEngine *native = host_.nativeEngine())
    native->fallbackRenderStateChanged();
  if (core != notifying_core)
    return;
  if (host_.requestedSource().isEmpty())
    return;

  if (scrubbing() && lineage.committed_open &&
      lineage.committed_open->render_stamp == retired_render_stamp) {
    invalidateScrubGesture();
  }

  bool needs_retry = false;
  if (lineage.open_attempt &&
      lineage.open_attempt->request_serial == lineage.pending_request_serial &&
      lineage.open_attempt->render_stamp == retired_render_stamp) {
    // The command reply may still arrive, but it belongs to the retired
    // generation. Keeping the source pending lets the next Ready ticket
    // supersede it without waiting or taking the render lock.
    lineage.open_attempt.reset();
    needs_retry = true;
  }

  const bool retired_recovery_attempt =
      lineage.render_recovery_attempt &&
      lineage.render_recovery_attempt->request_serial == host_.requestSerial() &&
      lineage.render_recovery_attempt->render_stamp == retired_render_stamp;
  const bool retired_committed_output =
      lineage.committed_open && lineage.committed_open->request_serial == host_.requestSerial() &&
      lineage.committed_open->render_stamp == retired_render_stamp;

  if (retired_recovery_attempt || retired_committed_output) {
    std::optional<bool> startup_paused_intent;
    std::optional<double> startup_position;
    bool startup_terminal_state = false;
    if (lineage.startup_playback_sync &&
        lineage.startup_playback_sync->request_serial == host_.requestSerial() &&
        lineage.startup_playback_sync->render_stamp == retired_render_stamp) {
      // Startup deliberately gates the controller's default pause/timeline
      // cache. Transfer its engine-derived/user-updated intent before render
      // recovery takes ownership, and sample a newer live position when one is
      // still available during teardown.
      const StartupPlaybackSync startup_sync = *lineage.startup_playback_sync;
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
        host_.updateIdle(live_state->idle);
        if (live_state->eof_reached)
          host_.updateEof(*live_state->eof_reached);
        if (live_state->duration)
          host_.updateDuration(*live_state->duration);
      }
      lineage.startup_playback_sync.reset();
    }

    if (!lineage.render_recovery ||
        lineage.render_recovery->request_serial != host_.requestSerial()) {
      const bool cached_tracks_are_current =
          lineage.committed_open && lineage.committed_open->playlist_entry_id >= 0 &&
          lineage.selected_tracks_playlist_entry_id ==
              lineage.committed_open->playlist_entry_id;
      const bool snapshot_proven = cached_tracks_are_current &&
                                   lineage.current_file_has_audio_track.has_value();
      std::int64_t video_track =
          cached_tracks_are_current ? lineage.selected_video_track_id : -1;
      std::int64_t audio_track =
          cached_tracks_are_current ? lineage.selected_audio_track_id : -1;
      std::int64_t subtitle_track =
          cached_tracks_are_current ? lineage.selected_subtitle_track_id : -1;
      if (ready()) {
        const std::int64_t current_video = currentTrackId("vid");
        const std::int64_t current_audio = currentTrackId("aid");
        const std::int64_t current_subtitle =
            currentTrackId("sid");
        if (current_video > 0)
          video_track = current_video;
        if (current_audio > 0)
          audio_track = current_audio;
        if (current_subtitle > 0)
          subtitle_track = current_subtitle;
      }

      const bool has_audio_track =
          lineage.current_file_has_audio_track.value_or(audio_track > 0);
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
      recovery.request_serial = host_.requestSerial();
      recovery.position = std::max(0.0, startup_position.value_or(host_.position()));
      recovery.paused = startup_paused_intent.value_or(host_.paused());
      recovery.mode = mode;
      recovery.video_track_id = video_track;
      recovery.audio_track_id = audio_track;
      recovery.subtitle_track_id = subtitle_track;
      recovery.file_has_audio_track = has_audio_track;
      recovery.track_snapshot_proven = snapshot_proven;
      recovery.external_subtitles = lineage.attached_subtitle_files;
      recovery.reload_source = lineage.committed_entry_source;
      recovery.playlist_position = lineage.committed_playlist_position;
      if (ready() && lineage.committed_open) {
        const std::int64_t live_position = playlistPositionForEntry(lineage.committed_open->playlist_entry_id);
        if (live_position >= 0)
          recovery.playlist_position = live_position;
        recovery.preserve_playlist_context =
            playlistEntryCount() > 1;
      }
      recovery.preserve_playlist_context =
          recovery.preserve_playlist_context || !lineage.redirect_ranges.empty();
      lineage.render_recovery = std::move(recovery);
    } else {
      lineage.render_recovery->restartForNewRenderContext();
    }

    lineage.render_recovery_attempt.reset();
    if (lineage.committed_open)
      lineage.committed_open->render_stamp = 0;
    needs_retry = true;
  }

  if (needs_retry)
    continuePendingOpen();
}

void MpvEngine::handleRenderInitializationFailure(
    const QString &error, std::uint64_t render_stamp) {
  if (!core || (lineage.pending_source.isEmpty() && !lineage.render_recovery) ||
      !core->renderFailureIsCurrent({render_stamp}) ||
      render_stamp == lineage.last_reported_render_failure_stamp) {
    return;
  }
  lineage.last_reported_render_failure_stamp = render_stamp;
  const bool routed_fallback_failure = lineage.routed_fallback_open.has_value();
  if (routed_fallback_failure)
    abandonPendingOpen();
  host_.setLastError(error);
  if (routed_fallback_failure)
    notifyRoutedFallbackOpenFailed();
}

std::int64_t MpvEngine::authoritativePlaylistEntry(
    std::int64_t live_entry, std::int64_t captured_start_entry) {
  return live_entry >= 0 ? live_entry : captured_start_entry;
}

void MpvEngine::continuePendingOpen() {
  if (core) {
    if (const auto ticket = core->readyRenderTicket()) {
      static_cast<void>(flushPendingOpen(ticket->stamp));
      return;
    }
  }
  host_.requestVideoUpdate();
}

bool MpvEngine::flushPendingOpen(std::uint64_t render_stamp) {
  if (!core || !ready())
    return true;

  if (lineage.pending_source.isEmpty() || lineage.pending_request_serial == 0) {
    if (!lineage.render_recovery && lineage.committed_open &&
        lineage.committed_open->request_serial == host_.requestSerial() &&
        lineage.committed_open->render_stamp == 0 &&
        core->validateRenderTicket({render_stamp})) {
      lineage.committed_open->render_stamp = render_stamp;
    }
    return flushRenderRecovery(render_stamp);
  }

  const RenderTicket ticket{render_stamp};
  if (!core->validateRenderTicket(ticket))
    return true;

  if (lineage.open_attempt &&
      lineage.open_attempt->request_serial == lineage.pending_request_serial &&
      lineage.open_attempt->render_stamp == render_stamp) {
    return true;
  }

  const QUrl source = lineage.pending_source;
  const std::uint64_t request_serial = lineage.pending_request_serial;
  const QString argument = sourceArgument(source);
  if (argument.isEmpty()) {
    abandonPendingOpen();
    host_.setLastError(QStringLiteral("Unable to open an empty media location."));
    notifyRoutedFallbackOpenFailed();
    return false;
  }

  const PlaybackSourceClass source_class =
      lineage.routed_fallback_open
          ? lineage.routed_fallback_open->source_class
          : playbackSourceClass(displayUrlForSource(source));
  applyPlaybackBufferPolicy(source_class);
  if (!core->validateRenderTicket(ticket)) {
    continuePendingOpen();
    return true;
  }

  const std::uint64_t reply_userdata = mpvReplyUserdata(
      MpvReply::Open, nextMpvReplyId(MpvReply::Open, next_open_attempt_id_));
  const QByteArray utf8 = argument.toUtf8();
  const int result = sendCommand({QByteArrayLiteral("loadfile"), utf8, QByteArrayLiteral("replace")},
      reply_userdata);
  if (result < 0) {
    // A queueing failure is stable for this request. Leave renderer retries to
    // an explicit subsequent open instead of spinning every frame.
    abandonPendingOpen();
    host_.setLastError(QStringLiteral("Unable to open media: %1")
                     .arg(mpvErrorDetail(result)));
    notifyRoutedFallbackOpenFailed();
    return false;
  }

  lineage.open_attempt =
      OpenAttempt{next_open_attempt_id_, request_serial, render_stamp};
  host_.setLastError({});

  // Do not clear lineage.pending_source here. mpv_command_async only queues work;
  // the matching command reply is the first point where execution is known.
  if (!core->validateRenderTicket(ticket))
    continuePendingOpen();
  return true;
}

void MpvEngine::observeOpenCommandReply(std::uint64_t attempt_id,
                                               int error) {
  if (error >= 0 && lineage.open_attempt &&
      lineage.open_attempt->id == attempt_id &&
      !lineage.open_attempt->playback_restarted) {
    // Metadata reads in handleOpenCommandReply are synchronous. Before the
    // first frame they can wait on mpv's VO while Qt needs this GUI thread to
    // dispatch rendering. Retain one reply in the existing attempt, then read
    // metadata after PLAYBACK_RESTART (also emitted for paused/audio opens).
    lineage.open_attempt->reply_ready = true;
    return;
  }
  const bool loaded = lineage.open_attempt && lineage.open_attempt->file_loaded;
  const bool restarted = lineage.open_attempt && lineage.open_attempt->playback_restarted;
  handleOpenCommandReply(attempt_id, error);
  if (error >= 0 && !lineage.open_attempt && restarted) {
    if (loaded) handlePlaybackReady(true);
    handlePlaybackReady(false);
  }
}

void MpvEngine::handleOpenCommandReply(std::uint64_t attempt_id,
                                              int error) {
  if (!lineage.open_attempt || lineage.open_attempt->id != attempt_id)
    return;

  const OpenAttempt attempt = *lineage.open_attempt;
  const bool current_request =
      attempt.request_serial == host_.requestSerial() &&
      attempt.request_serial == lineage.pending_request_serial &&
      !lineage.pending_source.isEmpty();
  const bool current_renderer =
      core && core->validateRenderTicket({attempt.render_stamp});

  if (!current_request) {
    lineage.open_attempt.reset();
    return;
  }

  if (!current_renderer) {
    // A later Ready notification submits this same authoritative intent in
    // the replacement generation. Old-generation replies are harmless.
    lineage.open_attempt.reset();
    continuePendingOpen();
    return;
  }

  if (error < 0) {
    abandonPendingOpen();
    host_.setLastError(QStringLiteral("Unable to open media: %1")
                     .arg(mpvErrorDetail(error)));
    notifyRoutedFallbackOpenFailed();
    return;
  }

  const QUrl loaded_source = lineage.pending_source;
  host_.updateSource(displayUrlForSource(loaded_source));
  host_.updateMediaTitle(fallbackTitle(loaded_source));
  OpenAttempt committed = attempt;
  const std::int64_t current_entry = currentPlaylistEntryId();
  committed.playlist_entry_id =
      authoritativePlaylistEntry(current_entry, attempt.playlist_entry_id);
  lineage.committed_open = committed;
  const bool live_paused = flagProperty("pause").value_or(host_.paused());
  StartupPlaybackSync startup_sync;
  startup_sync.request_serial = committed.request_serial;
  startup_sync.render_stamp = committed.render_stamp;
  startup_sync.playlist_entry_id = committed.playlist_entry_id;
  startup_sync.intended_paused = live_paused;
  lineage.startup_playback_sync = startup_sync;
  lineage.committed_entry_source = displayUrlForSource(loaded_source);
  lineage.committed_playlist_position =
      playlistPositionForEntry(committed.playlist_entry_id);
  lineage.terminal_playlist_entry_id = -1;
  lineage.redirect_ranges.clear();
  lineage.render_recovery_attempt.reset();
  lineage.render_recovery.reset();
  lineage.attached_subtitle_files.clear();
  lineage.current_file_has_audio_track.reset();
  lineage.selected_video_track_id = -1;
  lineage.selected_audio_track_id = -1;
  lineage.selected_subtitle_track_id = -1;
  lineage.selected_tracks_playlist_entry_id = -1;
  if (lineage.active_event_playlist_entry_id != committed.playlist_entry_id)
    lineage.active_event_playlist_entry_id = -1;
  const std::int64_t video_track = currentTrackId("vid");
  if (video_track > 0 && committed.playlist_entry_id >= 0) {
    lineage.selected_video_track_id = video_track;
    lineage.selected_tracks_playlist_entry_id = committed.playlist_entry_id;
  }
  lineage.pending_source.clear();
  lineage.pending_request_serial = 0;
  lineage.open_attempt.reset();
  if (lineage.routed_fallback_open) {
    const RoutedFallbackOpen routed = *lineage.routed_fallback_open;
    lineage.routed_fallback_open.reset();
    if (NativeEngine *native = host_.nativeEngine())
      native->fallbackOpenSucceeded(routed.attempt, routed.serial,
                                routed.source_key);
  }
}

bool MpvEngine::playlistEntryBelongsToCurrentLineage(
    std::int64_t playlist_entry_id) const {
  if (playlist_entry_id < 0 || !lineage.committed_open ||
      lineage.committed_open->request_serial != host_.requestSerial() ||
      lineage.committed_open->playlist_entry_id < 0) {
    return false;
  }
  if (playlist_entry_id == lineage.committed_open->playlist_entry_id)
    return true;
  for (const PlaylistEntryRange &range : lineage.redirect_ranges) {
    if (range.first < 0 || playlist_entry_id < range.first)
      continue;
    const auto distance =
        static_cast<std::uint64_t>(playlist_entry_id - range.first);
    if (distance < range.count)
      return true;
  }
  return false;
}

void MpvEngine::handleStartFile(std::int64_t playlist_entry_id) {
  if (scrubbing()) {
    invalidateScrubGesture();
  }
  if (playlist_entry_id < 0) {
    lineage.active_event_playlist_entry_id = -1;
    return;
  }
  if (lineage.render_recovery_attempt &&
      lineage.render_recovery_attempt->request_serial == host_.requestSerial() &&
      lineage.render_recovery_attempt->mode == RenderRecoveryMode::FullReload) {
    lineage.render_recovery_attempt->started_playlist_entry_id = playlist_entry_id;
    lineage.active_event_playlist_entry_id = playlist_entry_id;
    lineage.terminal_playlist_entry_id = -1;
    return;
  }

  if (lineage.open_attempt && lineage.open_attempt->request_serial == host_.requestSerial() &&
      lineage.open_attempt->request_serial == lineage.pending_request_serial) {
    lineage.open_attempt->playlist_entry_id = playlist_entry_id;
    lineage.active_event_playlist_entry_id = playlist_entry_id;
    lineage.terminal_playlist_entry_id = -1;
    return;
  }

  const bool initial_start_without_committed_entry =
      lineage.startup_playback_sync && lineage.committed_open &&
      lineage.startup_playback_sync->request_serial == host_.requestSerial() &&
      lineage.committed_open->request_serial == host_.requestSerial() &&
      lineage.committed_open->playlist_entry_id < 0 &&
      lineage.startup_playback_sync->playlist_entry_id < 0;
  if (!lineage.pending_source.isEmpty() ||
      (!initial_start_without_committed_entry &&
       !playlistEntryBelongsToCurrentLineage(playlist_entry_id))) {
    lineage.active_event_playlist_entry_id = -1;
    return;
  }

  // A redirect child becomes the concrete current entry. Retain all accepted
  // ranges so a sibling or a nested redirect child can be promoted later.
  const bool entry_changed =
      lineage.committed_open->playlist_entry_id != playlist_entry_id;
  lineage.committed_open->playlist_entry_id = playlist_entry_id;
  if (lineage.startup_playback_sync &&
      lineage.startup_playback_sync->request_serial == host_.requestSerial()) {
    lineage.startup_playback_sync->playlist_entry_id = playlist_entry_id;
    lineage.startup_playback_sync->completion_token = 0;
    lineage.startup_playback_sync->retry_count = 0;
  }
  const std::int64_t live_playlist_position =
      ready() ? playlistPositionForEntry(playlist_entry_id)
                    : -1;
  if (live_playlist_position >= 0 || entry_changed)
    lineage.committed_playlist_position = live_playlist_position;
  if (entry_changed) {
    lineage.committed_entry_source =
        ready() ? playlistEntrySource(playlist_entry_id)
                      : QUrl{};
  }
  lineage.active_event_playlist_entry_id = playlist_entry_id;
  lineage.terminal_playlist_entry_id = -1;
  host_.updateEof(false);
  if (!lineage.render_recovery && lineage.committed_open->render_stamp == 0) {
    RenderRecovery adoption;
    adoption.request_serial = host_.requestSerial();
    adoption.mode = RenderRecoveryMode::NoReselection;
    if (core) {
      if (const auto ready = core->readyRenderTicket()) {
        adoption.accepted_render_stamp = ready->stamp;
        lineage.committed_open->render_stamp = ready->stamp;
      }
    }
    lineage.render_recovery = std::move(adoption);
  }
  if (lineage.render_recovery && lineage.render_recovery->request_serial == host_.requestSerial()) {
    if (lineage.render_recovery->accepted_render_stamp != 0 && core &&
        core->validateRenderTicket(
            {lineage.render_recovery->accepted_render_stamp})) {
      lineage.committed_open->render_stamp = lineage.render_recovery->accepted_render_stamp;
    }
    if (lineage.render_recovery_attempt &&
        lineage.render_recovery_attempt->request_serial == host_.requestSerial() &&
        lineage.render_recovery_attempt->mode == RenderRecoveryMode::VideoReselect) {
      lineage.render_recovery_attempt->playlist_entry_id = playlist_entry_id;
    }
  }
  if (entry_changed) {
    host_.resetTimeline();
    lineage.observed_current_path = false;
    host_.updateMediaTitle({});
    lineage.selected_video_track_id = -1;
    lineage.selected_audio_track_id = -1;
    lineage.selected_subtitle_track_id = -1;
    lineage.selected_tracks_playlist_entry_id = -1;
    lineage.current_file_has_audio_track.reset();
    if (lineage.render_recovery)
      lineage.render_recovery->restartForNewPlaylistEntry();
  }
}

void MpvEngine::handleEndFile(const mpv_event_end_file &end) {
  const bool startup_entry =
      lineage.startup_playback_sync && lineage.committed_open &&
      lineage.startup_playback_sync->request_serial == host_.requestSerial() &&
      lineage.startup_playback_sync->playlist_entry_id == end.playlist_entry_id;
  const bool current_entry =
      end.playlist_entry_id >= 0 && lineage.committed_open &&
      lineage.committed_open->request_serial == host_.requestSerial() &&
      lineage.committed_open->playlist_entry_id == end.playlist_entry_id &&
      (lineage.active_event_playlist_entry_id == end.playlist_entry_id ||
       startup_entry);
  if (!current_entry)
    return;

  invalidateScrubGesture();

  lineage.active_event_playlist_entry_id = -1;

  const bool expected_video_only_teardown =
      end.reason == MPV_END_FILE_REASON_ERROR &&
      (lineage.selected_tracks_playlist_entry_id !=
           lineage.committed_open->playlist_entry_id ||
       lineage.selected_audio_track_id <= 0) &&
      core && !core->validateRenderTicket({lineage.committed_open->render_stamp});
  if (expected_video_only_teardown)
    return;

  // A video-only full reload first stops the retained old entry. That stop is
  // part of recovery, not a terminal event for the user's current request.
  if (lineage.render_recovery_attempt &&
      lineage.render_recovery_attempt->mode == RenderRecoveryMode::FullReload &&
      lineage.render_recovery_attempt->playlist_entry_id == end.playlist_entry_id) {
    return;
  }

  if (end.reason == MPV_END_FILE_REASON_ERROR && lineage.render_recovery &&
      lineage.render_recovery->mode == RenderRecoveryMode::VideoReselect) {
    // A successful `set vid` reply is not sufficient proof that the VO lived:
    // libmpv can report success and then asynchronously unload the entry.
    // Preserve the captured per-file state and escalate this one recovery to
    // the guarded full-reload path.
    lineage.render_recovery->escalateToFullReload();
    lineage.render_recovery_attempt.reset();
    lineage.committed_open->render_stamp = 0;
    continuePendingOpen();
    return;
  }

  if (end.reason == MPV_END_FILE_REASON_REDIRECT) {
    if (end.playlist_insert_id >= 0 && end.playlist_insert_num_entries > 0) {
      lineage.redirect_ranges.push_back(PlaylistEntryRange{
          end.playlist_insert_id,
          static_cast<std::uint64_t>(end.playlist_insert_num_entries)});
    }
    return;
  }
  if (end.reason == MPV_END_FILE_REASON_EOF) {
    lineage.startup_playback_sync.reset();
    if (lineage.render_recovery) {
      // EOF terminates this entry's transport/track recovery, but not the
      // replacement render generation: a redirect sibling may start next.
      // Carry only generation adoption so the sibling establishes a fresh
      // FILE_LOADED track snapshot instead of replaying the old child.
      std::uint64_t adoption_stamp = lineage.render_recovery->accepted_render_stamp;
      if ((!core || !core->validateRenderTicket({adoption_stamp})) && core) {
        if (const auto ready = core->readyRenderTicket())
          adoption_stamp = ready->stamp;
        else
          adoption_stamp = 0;
      }
      RenderRecovery adoption;
      adoption.request_serial = host_.requestSerial();
      adoption.paused = host_.paused();
      adoption.mode = RenderRecoveryMode::NoReselection;
      adoption.accepted_render_stamp = adoption_stamp;
      lineage.render_recovery = std::move(adoption);
      lineage.render_recovery_attempt.reset();
      lineage.committed_open->render_stamp = adoption_stamp;
      host_.updateEof(true);
      if (adoption_stamp == 0)
        continuePendingOpen();
      const std::uint64_t terminal_serial = host_.requestSerial();
      const std::int64_t terminal_entry = end.playlist_entry_id;
      QTimer::singleShot(0, owner_, [this, terminal_serial, terminal_entry] {
        if (!lineage.render_recovery || host_.requestSerial() != terminal_serial ||
            !lineage.committed_open ||
            lineage.committed_open->playlist_entry_id != terminal_entry ||
            lineage.active_event_playlist_entry_id >= 0 || !host_.eofReached() ||
            lineage.render_recovery->mode != RenderRecoveryMode::NoReselection) {
          return;
        }
        const std::uint64_t adoption_stamp =
            lineage.render_recovery->accepted_render_stamp;
        lineage.render_recovery.reset();
        lineage.render_recovery_attempt.reset();
        lineage.committed_open->render_stamp = adoption_stamp;
        lineage.terminal_playlist_entry_id = terminal_entry;
      });
      return;
    }
    lineage.render_recovery.reset();
    lineage.render_recovery_attempt.reset();
    lineage.terminal_playlist_entry_id = end.playlist_entry_id;
    host_.updateEof(true);
    return;
  }
  if (end.reason == MPV_END_FILE_REASON_ERROR) {
    lineage.startup_playback_sync.reset();
    lineage.render_recovery.reset();
    lineage.render_recovery_attempt.reset();
    host_.updatePause(true);
    host_.updateIdle(true);
    host_.updateEof(false);
    host_.resetTimeline();
    host_.updateLoading(false);
    host_.updateSource({});
    host_.updateMediaTitle({});
    host_.setRequestedSource({});
    lineage.committed_open.reset();
    lineage.last_error_playlist_entry_id = end.playlist_entry_id;
    QString failure = QStringLiteral("Could not open this file: %1")
                          .arg(mpvErrorDetail(end.error));
    NativeEngine *native = host_.nativeEngine();
    host_.setLastError(native ? native->playbackFailureText(failure) : failure);
    if (native)
      native->fallbackPlaybackFailed();
  }
}

void MpvEngine::handlePlaybackReady(bool file_loaded) {
  if (!file_loaded) host_.updateLoading(false);
  if (lineage.open_attempt) {
    if (file_loaded) lineage.open_attempt->file_loaded = true;
    else lineage.open_attempt->playback_restarted = true;
    if (file_loaded || !lineage.open_attempt->reply_ready) return;
    const auto attempt = *lineage.open_attempt;
    handleOpenCommandReply(attempt.id, 0);
    if (attempt.file_loaded) handlePlaybackReady(true);
  }
  if (file_loaded)
    cacheCurrentEntrySource();
  if (file_loaded && lineage.last_error_playlist_entry_id >= 0 &&
      lineage.active_event_playlist_entry_id >= 0 &&
      lineage.active_event_playlist_entry_id != lineage.last_error_playlist_entry_id) {
    lineage.last_error_playlist_entry_id = -1;
    host_.setLastError({});
  }
  if (lineage.render_recovery) {
    bool matching_lineage = false;
    if (lineage.committed_open && lineage.committed_open->playlist_entry_id >= 0 &&
        lineage.committed_open->playlist_entry_id == lineage.active_event_playlist_entry_id) {
      matching_lineage = true;
    }
    if (lineage.render_recovery_attempt &&
        lineage.render_recovery_attempt->mode == RenderRecoveryMode::FullReload &&
        lineage.render_recovery_attempt->started_playlist_entry_id >= 0 &&
        lineage.render_recovery_attempt->started_playlist_entry_id ==
            lineage.active_event_playlist_entry_id) {
      matching_lineage = true;
    }
    if (matching_lineage) {
      if (file_loaded)
        lineage.render_recovery->file_loaded = true;
      else if (lineage.render_recovery->accepted_render_stamp != 0 &&
               !lineage.render_recovery_attempt && core &&
               core->validateRenderTicket(
                   {lineage.render_recovery->accepted_render_stamp}))
        lineage.render_recovery->playback_restarted = true;
    }
  } else if (lineage.startup_playback_sync && lineage.committed_open &&
             lineage.startup_playback_sync->request_serial == host_.requestSerial() &&
             lineage.startup_playback_sync->playlist_entry_id >= 0 &&
             lineage.startup_playback_sync->playlist_entry_id ==
                 lineage.active_event_playlist_entry_id &&
             lineage.committed_open->playlist_entry_id ==
                 lineage.active_event_playlist_entry_id) {
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
    host_.refreshSubtitleSources();
    // And the moment the picture's size is knowable, for the same reason: it
    // is the one hook that fires on a first open and on every fallback the
    // router takes. The dwidth/dheight observations usually land just before
    // this, but they land inside the open and can be dropped by the path
    // check in applyObservedVideoFacts while mpv still has the outgoing file;
    // this is the reliable second look, and updateVideoFacts dedupes so
    // the common case where both agree costs one comparison.
    applyObservedVideoFacts();
  }
  restoreRenderRecovery();
}

void MpvEngine::abandonPendingOpen() {
  host_.setRequestedSource(host_.source());
  lineage.observed_current_path = !host_.source().isEmpty();
  lineage.pending_source.clear();
  lineage.pending_request_serial = 0;
  lineage.open_attempt.reset();
  lineage.render_recovery.reset();
  lineage.render_recovery_attempt.reset();
  if (lineage.committed_open && !host_.requestedSource().isEmpty()) {
    // The previous source remains authoritative when a replacement command
    // could not be accepted. Associate it with the now-current request serial
    // so a later scene-graph loss still recovers that visible media.
    lineage.committed_open->request_serial = host_.requestSerial();
  } else {
    lineage.committed_open.reset();
  }
  host_.requestVideoUpdate();
}

void MpvEngine::cacheCurrentTrackSelection() {
  if (!core || !ready() || !lineage.committed_open ||
      lineage.active_event_playlist_entry_id < 0 ||
      lineage.active_event_playlist_entry_id != lineage.committed_open->playlist_entry_id) {
    return;
  }
  lineage.selected_video_track_id = currentTrackSelection("vid");
  lineage.selected_audio_track_id = currentTrackSelection("aid");
  lineage.selected_subtitle_track_id = currentTrackSelection("sid");
  lineage.selected_tracks_playlist_entry_id = lineage.committed_open->playlist_entry_id;
  lineage.current_file_has_audio_track = currentFileHasTrackType("audio");
}

void MpvEngine::cacheCurrentEntrySource() {
  if (!core || !ready() || !lineage.committed_open ||
      lineage.committed_open->playlist_entry_id < 0 ||
      lineage.committed_open->playlist_entry_id != lineage.active_event_playlist_entry_id) {
    return;
  }
  const auto path = stringProperty("path");
  if (!path)
    return;
  const QUrl source = urlFromMpvPath(*path);
  if (!source.isEmpty()) {
    lineage.committed_entry_source = source;
    lineage.committed_playlist_position = playlistPositionForEntry(lineage.committed_open->playlist_entry_id);
  }
}

void MpvEngine::notifyRoutedFallbackOpenFailed() {
  NativeEngine *native = host_.nativeEngine();
  if (!native || !lineage.routed_fallback_open)
    return;
  const RoutedFallbackOpen routed = *lineage.routed_fallback_open;
  lineage.routed_fallback_open.reset();
  native->fallbackOpenFailed(routed.attempt, routed.serial, routed.source_key);
}

void MpvEngine::RenderRecovery::restartForNewRenderContext() {
  accepted_render_stamp = 0;
  command_failed = false;
  file_loaded = false;
  playback_restarted = false;
  external_subtitles_restored = false;
  external_subtitles_restored_count = 0;
  per_file_state_restored = false;
  transport_restored = false;
  completion_token = 0;
  restore_retry_count = 0;
  restore_retry_queued = false;
  restore_failure.clear();
}

void MpvEngine::RenderRecovery::escalateToFullReload() {
  mode = RenderRecoveryMode::FullReload;
  accepted_render_stamp = 0;
  command_failed = false;
  file_loaded = false;
  playback_restarted = false;
  external_subtitles_restored = false;
  external_subtitles_restored_count = 0;
  per_file_state_restored = false;
  transport_restored = false;
  completion_token = 0;
}

void MpvEngine::RenderRecovery::restartForNewPlaylistEntry() {
  position = 0.0;
  position_overridden = false;
  file_loaded = false;
  playback_restarted = false;
  track_snapshot_proven = false;
  transport_restored = false;
  completion_token = 0;
  restore_retry_count = 0;
  restore_retry_queued = false;
  restore_failure.clear();
}

void MpvEngine::observeProperties() {
  mpv_handle *handle = core->handle();
  const MpvApi &api = core->api();
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
  // not the user's caption switch. captionsVisible means "a subtitle source is
  // selected", which is app state on both routes.
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
  observe(ObservedProperty::DisplayWidth, "dwidth", MPV_FORMAT_INT64);
  observe(ObservedProperty::DisplayHeight, "dheight", MPV_FORMAT_INT64);
  observe(ObservedProperty::VideoGamma, "video-params/gamma", MPV_FORMAT_STRING);
}

void MpvEngine::drainMpvEvents() {
  if (!ready())
    return;

  struct NativeDrainScope final {
    NativeEngine *owner{nullptr};
    explicit NativeDrainScope(NativeEngine *value) : owner(value) {
      if (owner)
        owner->beginFallbackEventDrain();
    }
    ~NativeDrainScope() {
      if (owner)
        owner->endFallbackEventDrain();
    }
  } native_drain_scope{host_.nativeEngine()};

  NativeEngine *const native = host_.nativeEngine();
  while (true) {
    mpv_event *event = core->api().mpv_wait_event(core->handle(), 0.0);
    if (!event || event->event_id == MPV_EVENT_NONE)
      break;

    if (event->event_id == MPV_EVENT_COMMAND_REPLY) {
      const MpvReplyTag reply = parseMpvReply(event->reply_userdata);
      if (native && reply.kind == MpvReply::FallbackStop) {
        native->fallbackStopCommandReply(reply.id, event->error);
        continue;
      }
      if (reply.kind == MpvReply::Scrub) {
        handleScrubCommandReply(reply.id, event->error);
        continue;
      }
      if (reply.kind == MpvReply::Open) {
        observeOpenCommandReply(reply.id, event->error);
        continue;
      }
      if (reply.kind == MpvReply::RenderRecovery) {
        handleRenderRecoveryCommandReply(reply.id, event->error);
        continue;
      }
    }

    // A retained compatibility handle is dormant during native playback.
    // Ignore its stale file/property stream, while the exact Stop command
    // reply above and idle observation below remain admitted during fallback
    // retirement.
    if (native &&
        !native->acceptsFallbackPlaybackEvents()) {
      continue;
    }

    if (event->event_id == MPV_EVENT_START_FILE) {
      core->beginFallbackMetricsEpoch();
      const auto *start = static_cast<mpv_event_start_file *>(event->data);
      handleStartFile(start ? start->playlist_entry_id : -1);
      continue;
    }

    if (event->event_id == MPV_EVENT_FILE_LOADED) {
      handlePlaybackReady(true);
      continue;
    }

    if (event->event_id == MPV_EVENT_PLAYBACK_RESTART) {
      if (native)
        native->noteFallbackSeek(false);
      handleScrubPlaybackRestart();
      handlePlaybackReady(false);
      continue;
    }

    if (event->event_id == MPV_EVENT_SEEK) {
      noteSeekStarted();
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
        if (native)
          native->fallbackIdleChanged(idle);
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
      case ObservedProperty::Volume:
        host_.applyObservedVolume(readDouble(property, 100.0) / 100.0);
        break;
      case ObservedProperty::Mute:
        host_.applyObservedMute(readFlag(property, false));
        break;
      case ObservedProperty::Rate:
        host_.applyObservedRate(readDouble(property, 1.0));
        break;
      case ObservedProperty::Path: {
        const QUrl observed_source = urlFromMpvPath(readString(property));
        // host_.requestedSource() is authoritative across asynchronous replacement.
        // Ignore empty transition values and paths from an older request; Stop
        // clears the visible source synchronously itself.
        if (host_.requestedSource().isEmpty() || observed_source.isEmpty())
          break;
        if (lineage.pending_source.isEmpty() && lineage.committed_open &&
            lineage.committed_open->request_serial == host_.requestSerial() &&
            lineage.committed_open->playlist_entry_id >= 0 &&
            lineage.committed_open->playlist_entry_id ==
                lineage.active_event_playlist_entry_id) {
          lineage.committed_entry_source = observed_source;
        }
        if (sourceIdentity(observed_source) !=
            sourceIdentity(host_.requestedSource())) {
          break;
        }
        lineage.observed_current_path = true;
        host_.updateSource(observed_source);
        break;
      }
      case ObservedProperty::MediaTitle: {
        QString value = readString(property);
        if (!lineage.observed_current_path && !value.isEmpty())
          break;
        if (value.isEmpty())
          value = fallbackTitle(host_.source());
        host_.updateMediaTitle(value);
        break;
      }
      case ObservedProperty::PreservePitch:
        host_.applyObservedPreservePitch(readFlag(property, true));
        break;
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
        host_.applyObservedSubtitleText(readString(property));
        break;
      case ObservedProperty::TrackListCount:
        // A `sub-add` (generated captions, a loaded file) changes the track
        // set without any other signal, so this is how a new source reaches
        // the menu.
        host_.refreshSubtitleSources();
        break;
      case ObservedProperty::DisplayWidth:
      case ObservedProperty::DisplayHeight:
      case ObservedProperty::VideoGamma:
        // Any of them means "the picture may have changed"; each reads all
        // three back (see the enum comment).
        applyObservedVideoFacts();
        break;
      }
      continue;
    }

    if (event->event_id == MPV_EVENT_END_FILE) {
      const auto *end = static_cast<mpv_event_end_file *>(event->data);
      if (end) {
        // Failed/empty opens may end without PLAYBACK_RESTART. Retire their
        // accepted command using the matching START_FILE identity as well.
        if (lineage.open_attempt && lineage.open_attempt->reply_ready &&
            lineage.open_attempt->playlist_entry_id == end->playlist_entry_id)
          handleOpenCommandReply(lineage.open_attempt->id, 0);
        handleEndFile(*end);
      }
    }
  }
}

void MpvEngine::applyObservedPause(bool paused) {
  if (acceptsPlaybackObservation())
    host_.updatePause(paused);
}

void MpvEngine::applyObservedPosition(double position) {
  if (!std::isfinite(position))
    return;
  const double value = std::max(0.0, position);
  if (observeScrubPosition(value))
    return;
  if (!acceptsPlaybackObservation())
    return;
  host_.updatePosition(value);
}

void MpvEngine::applyObservedDuration(double duration) {
  if (!acceptsPlaybackObservation() || !std::isfinite(duration))
    return;
  host_.updateDuration(duration);
}

void MpvEngine::applyObservedVideoFacts() {
  if (!core || !ready() || lineage.open_attempt)
    return;
  // Deliberately NOT gated on acceptsPlaybackObservation(), which every other
  // observation here does use. mpv announces dwidth/dheight once per file,
  // during the open, while that gate is still closed, and never again unless
  // the value changes. Gating here would discard the only announcement there
  // is and leave the fallback route's size at (0, 0) for the whole session.
  //
  // The hazard the gate guards against -- a previous file's value landing on
  // the current one -- is checked directly instead, and more precisely: the
  // size and the path it belongs to are read from the same mpv instance in
  // the same breath, and the pair is published only if that path is the media
  // this controller has already committed to. A size read while mpv still has
  // the outgoing file loaded therefore cannot be attributed to the incoming
  // one.
  const QSize size = currentVideoDisplaySize();
  if (size.isEmpty())
    return;
  const QString gamma = stringProperty("video-params/gamma").value_or(QString());
  const bool hdr = gamma == QLatin1String("pq") || gamma == QLatin1String("hlg");
  const auto path = stringProperty("path");
  if (!path)
    return;
  const QUrl playing = urlFromMpvPath(*path);
  if (playing.isEmpty() || playing != host_.source())
    return;
  host_.updateVideoFacts({size.width(), 1}, {size.height(), 1}, hdr);
}

void MpvEngine::applyObservedIdle(bool idle) {
  if (acceptsPlaybackObservation())
    host_.updateIdle(idle);
}

void MpvEngine::applyObservedEof(bool eof_reached) {
  if (acceptsPlaybackObservation())
    host_.updateEof(eof_reached);
}

void MpvEngine::applyObservedVideoTrack(std::int64_t video_track_id) {
  if (!acceptsPlaybackObservation())
    return;
  lineage.selected_video_track_id = video_track_id >= 0 ? video_track_id : -1;
  lineage.selected_tracks_playlist_entry_id = lineage.committed_open->playlist_entry_id;
}

void MpvEngine::applyObservedAudioTrack(std::int64_t audio_track_id) {
  if (!acceptsPlaybackObservation())
    return;
  lineage.selected_audio_track_id = audio_track_id >= 0 ? audio_track_id : -1;
  lineage.selected_tracks_playlist_entry_id = lineage.committed_open->playlist_entry_id;
}

void MpvEngine::applyObservedSubtitleTrack(
    std::int64_t subtitle_track_id) {
  if (!acceptsPlaybackObservation())
    return;
  lineage.selected_subtitle_track_id = subtitle_track_id >= 0 ? subtitle_track_id : -1;
  lineage.selected_tracks_playlist_entry_id = lineage.committed_open->playlist_entry_id;
}

void MpvEngine::detachOwner() {
  if (core)
    core->detachOwner(owner_);
  core.reset();
}

} // namespace wam::qt
