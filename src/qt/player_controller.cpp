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
                const std::initializer_list<QByteArray> &arguments) {
  if (!handle || arguments.size() == 0)
    return MPV_ERROR_INVALID_PARAMETER;
  std::vector<const char *> argv;
  argv.reserve(arguments.size() + 1);
  for (const QByteArray &argument : arguments)
    argv.push_back(argument.constData());
  argv.push_back(nullptr);
  return mpv_command_async(handle, 0, argv.data());
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

} // namespace

PlayerController::PlayerController(QObject *parent)
    : QObject(parent), core_(std::make_shared<PlayerCore>(this)) {
  work_timer_ = new QTimer(this);
  work_timer_->setInterval(100);
  work_timer_->setTimerType(Qt::CoarseTimer);
  connect(work_timer_, &QTimer::timeout, this,
          &PlayerController::pollBackgroundWork);

  if (!available()) {
    setLastError(core_->initializationError());
    return;
  }

  mpv_handle *handle = core_->handle();
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

bool PlayerController::available() const { return core_ && core_->available(); }

void PlayerController::setSource(const QUrl &source) {
  if (source.isEmpty()) {
    stop();
    return;
  }
  open(source);
}

void PlayerController::openFileDialog() { emit openFileDialogRequested(); }

bool PlayerController::open(const QUrl &source) {
  if (!available() || source.isEmpty())
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

  // libmpv's render context must exist before loadfile starts VO playback.
  // The always-live QML video item creates it on Qt's render thread; retain
  // only the newest request until that handshake completes.
  if (!core_->renderingReady()) {
    pending_source_ = source;
    requestVideoUpdate();
    return true;
  }
  pending_source_.clear();

  const QString argument = sourceArgument(source);
  if (argument.isEmpty())
    return false;
  const QByteArray utf8 = argument.toUtf8();
  // Apply the policy synchronously before queueing loadfile. Using properties
  // keeps WAM compatible with both sides of mpv 0.38's loadfile-signature
  // change while still selecting a fresh bounded policy for every open.
  const QUrl display_source = displayUrlForSource(source);
  applyPlaybackBufferPolicy(core_->handle(),
                            playbackSourceClass(display_source));
  const int result =
      sendCommand(core_->handle(), {QByteArrayLiteral("loadfile"), utf8,
                                    QByteArrayLiteral("replace")});
  if (result < 0) {
    setLastError(QStringLiteral("Unable to open media: %1")
                     .arg(QString::fromUtf8(mpv_error_string(result))));
    return false;
  }

  setLastError({});
  updateSource(display_source);
  updateMediaTitle(fallbackTitle(source_));
  if (!nearlyEqual(position_, 0.0)) {
    position_ = 0.0;
    emit positionChanged();
  }
  return true;
}

void PlayerController::play() {
  if (!available())
    return;
  if (eof_reached_ || (duration_ > 0.0 && position_ >= duration_ - 0.05))
    seekTo(0.0);
  updateEof(false);
  int paused = 0;
  mpv_set_property_async(core_->handle(), 0, "pause", MPV_FORMAT_FLAG, &paused);
  updatePause(false);
}

void PlayerController::pause() {
  if (!available())
    return;
  int paused = 1;
  mpv_set_property_async(core_->handle(), 0, "pause", MPV_FORMAT_FLAG, &paused);
  updatePause(true);
}

void PlayerController::togglePlayPause() { playing() ? pause() : play(); }

void PlayerController::stop() {
  pending_source_.clear();
  cancelCaptionsForMediaChange();
  if (available())
    sendCommand(core_->handle(), {QByteArrayLiteral("stop")});
  updatePause(true);
  updateIdle(true);
  updateEof(false);
  updateSource({});
  updateMediaTitle({});
  resetTimeline();
}

void PlayerController::seekTo(double seconds) {
  if (!available() || !std::isfinite(seconds))
    return;
  const double maximum = duration_ > 0.0 ? duration_ : seconds;
  const double target = std::clamp(seconds, 0.0, std::max(0.0, maximum));
  double value = target;
  mpv_set_property_async(core_->handle(), 0, "time-pos", MPV_FORMAT_DOUBLE,
                         &value);
  if (!nearlyEqual(position_, target)) {
    position_ = target;
    emit positionChanged();
  }
}

void PlayerController::previewSeekTo(double seconds) {
  if (!available() || !std::isfinite(seconds))
    return;
  const double maximum = duration_ > 0.0 ? duration_ : seconds;
  const double target = std::clamp(seconds, 0.0, std::max(0.0, maximum));

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
  if (!available() || !std::isfinite(seconds))
    return;
  sendCommand(core_->handle(),
              {QByteArrayLiteral("seek"), QByteArray::number(seconds, 'g', 12),
               QByteArrayLiteral("relative")});
}

void PlayerController::skipBackward() { seekRelative(-5.0); }
void PlayerController::skipForward() { seekRelative(5.0); }

void PlayerController::toggleMute() { setMuted(!muted_); }

void PlayerController::setMuted(bool muted) {
  if (!available())
    return;
  int value = muted ? 1 : 0;
  mpv_set_property_async(core_->handle(), 0, "mute", MPV_FORMAT_FLAG, &value);
  if (muted_ == muted)
    return;
  muted_ = muted;
  emit mutedChanged();
}

void PlayerController::setVolume(double volume) {
  if (!available() || !std::isfinite(volume))
    return;
  const double normalized = std::clamp(volume, 0.0, 1.0);
  double mpv_volume = normalized * 100.0;
  mpv_set_property_async(core_->handle(), 0, "volume", MPV_FORMAT_DOUBLE,
                         &mpv_volume);
  if (nearlyEqual(volume_, normalized))
    return;
  volume_ = normalized;
  emit volumeChanged();
}

void PlayerController::setRate(double rate) {
  if (!available() || !std::isfinite(rate))
    return;
  const double bounded = std::clamp(rate, kMinimumRate, kMaximumRate);
  double value = bounded;
  mpv_set_property_async(core_->handle(), 0, "speed", MPV_FORMAT_DOUBLE,
                         &value);
  if (nearlyEqual(rate_, bounded))
    return;
  rate_ = bounded;
  emit rateChanged();
}

void PlayerController::toggleCaptions() {
  setCaptionsVisible(!captions_visible_);
}

void PlayerController::setCaptionsVisible(bool visible) {
  if (!available())
    return;
  int value = visible ? 1 : 0;
  mpv_set_property_async(core_->handle(), 0, "sub-visibility", MPV_FORMAT_FLAG,
                         &value);
  if (captions_visible_ == visible)
    return;
  captions_visible_ = visible;
  emit captionsVisibleChanged();
}

void PlayerController::toggleFullscreen() { emit fullscreenToggleRequested(); }

void PlayerController::setPreservePitch(bool preserve) {
  if (!available())
    return;
  int value = preserve ? 1 : 0;
  mpv_set_property_async(core_->handle(), 0, "audio-pitch-correction",
                         MPV_FORMAT_FLAG, &value);
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
  if (!available() || subtitle.empty())
    return false;
  const QByteArray path = displayPath(subtitle).toUtf8();
  std::array<const char *, 4> arguments{"sub-add", path.constData(), "select",
                                        nullptr};
  const int result = mpv_command(core_->handle(), arguments.data());
  if (result < 0)
    return false;
  setCaptionsVisible(true);
  return true;
}

void PlayerController::drainMpvEvents() {
  if (!available())
    return;

  while (true) {
    mpv_event *event = mpv_wait_event(core_->handle(), 0.0);
    if (!event || event->event_id == MPV_EVENT_NONE)
      break;

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
        updatePause(readFlag(property, true));
        break;
      case ObservedProperty::Idle:
        updateIdle(readFlag(property, true));
        break;
      case ObservedProperty::Position: {
        const double value = std::max(0.0, readDouble(property, 0.0));
        if (!nearlyEqual(position_, value)) {
          position_ = value;
          emit positionChanged();
        }
        break;
      }
      case ObservedProperty::Duration: {
        const double old_duration = duration_;
        const double value = std::max(0.0, readDouble(property, 0.0));
        if (!nearlyEqual(duration_, value)) {
          duration_ = value;
          emit durationChanged();
        }
        if (trim_out_ <= 0.0 || nearlyEqual(trim_out_, old_duration))
          setTrimOut(value);
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
      case ObservedProperty::Path:
        updateSource(urlFromMpvPath(readString(property)));
        break;
      case ObservedProperty::MediaTitle: {
        QString value = readString(property);
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
        updateEof(readFlag(property, false));
        break;
      }
      continue;
    }

    if (event->event_id == MPV_EVENT_END_FILE) {
      const auto *end = static_cast<mpv_event_end_file *>(event->data);
      if (end && end->reason == MPV_END_FILE_REASON_EOF)
        updateEof(true);
      if (end && end->reason == MPV_END_FILE_REASON_ERROR) {
        setLastError(QStringLiteral("Playback failed: %1")
                         .arg(QString::fromUtf8(mpv_error_string(end->error))));
      }
    }
  }
}

void PlayerController::requestVideoUpdate() {
  if (video_item_)
    video_item_->update();
}

void PlayerController::flushPendingOpen() {
  if (pending_source_.isEmpty() || !core_ || !core_->renderingReady())
    return;
  const QUrl source = pending_source_;
  pending_source_.clear();
  open(source);
}

void PlayerController::attachVideoItem(MpvVideoItem *item) {
  video_item_ = item;
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
  if (had_media != hasMedia())
    emit hasMediaChanged();
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
