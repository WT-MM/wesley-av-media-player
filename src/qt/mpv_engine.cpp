#include "mpv_engine.hpp"

#include "media/startup_benchmark.hpp"
#include "player_core_p.hpp"
#include "playback/mpv/mpv_runtime.hpp"

#include <QCoreApplication>
#include <QDebug>
#include <QDir>

#include <algorithm>
#include <new>
#include <vector>

namespace wam::qt {
namespace {

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

} // namespace

std::int64_t parseTrackSelection(const QString &text) {
  const QString value = text.trimmed();
  if (value.compare(QStringLiteral("no"), Qt::CaseInsensitive) == 0)
    return 0;
  bool valid = false;
  const qlonglong numeric = value.toLongLong(&valid);
  return valid && numeric > 0 ? static_cast<std::int64_t>(numeric) : -1;
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


MpvEngine::MpvEngine(PlayerController *owner)
    : core(std::make_shared<PlayerCore>(owner)), owner_(owner) {}

MpvEngine::~MpvEngine() = default;

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

void MpvEngine::detachOwner() {
  if (core)
    core->detachOwner(owner_);
  core.reset();
}

} // namespace wam::qt
