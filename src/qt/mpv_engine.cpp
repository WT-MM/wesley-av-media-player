#include "mpv_engine.hpp"

#include "media/startup_benchmark.hpp"
#include "player_controller.hpp"
#include "player_core_p.hpp"
#include "playback/mpv/mpv_runtime.hpp"

#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QTimer>

#include <algorithm>
#include <new>
#include <vector>

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

void MpvEngine::detachOwner() {
  if (core)
    core->detachOwner(owner_);
  core.reset();
}

} // namespace wam::qt
