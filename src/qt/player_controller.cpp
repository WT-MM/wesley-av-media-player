#include "player_controller.hpp"
#ifdef Q_OS_MACOS
#include "caption_download_prompt.hpp"
#endif

#include "app_settings.hpp"
#include "mpv_video_item.hpp"
#include "media/native_playback_contract.hpp"
#include "playback_policy.hpp"
#include "test_seams.hpp"
#include "player_core_p.hpp"
#include "subtitle_bitmap_provider.hpp"
#include "subtitle_sources.hpp"

#if defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
#include "qt/native_playback_owner.hpp"
#endif

#include <QByteArray>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStorageInfo>
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

namespace wam::qt {
namespace {

using ::wam::playback::mpv::MpvApi;

using media::native_playback::kMaximumNativeRate;
using media::native_playback::kMinimumNativeRate;
using media::native_playback::kNativeRateGrid;
constexpr double kScrubConvergenceToleranceSeconds = 0.050;
constexpr int kScrubSeekTimeoutMs = 750;

// Volume runs past unity into VLC-style amplification. 4.0 is the ABSOLUTE
// ceiling on every route: the native gain stage clamps there (and saturates
// each sample to [-1, 1]), and mpv is started with volume-max=400. How much
// of that ceiling any window may actually reach is the per-installation
// "Maximum volume" preference (AppSettings::maximumVolume), which is
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

PlayerController::PlayerController(QObject *parent)
    : QObject(parent), mpv_(this) {
#if defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  native_ = std::make_unique<NativePlaybackOwner>(
      *this, static_cast<NativeEngineHost &>(*this));
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
  caption_feed_ = std::make_shared<media::captions::LiveCaptionFeed>();
  subtitles_->setLiveCaptionFeed(caption_feed_);
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
  caption_service_->cancel();
  // Swift teardown and subprocess joins must not block window destruction.
  std::thread([service = std::move(caption_service_)] { service->wait(); }).detach();
  native_.reset();
  mpv_.detachOwner();
}

bool PlayerController::available() const {
  // Native playback remains available even when the optional compatibility
  // engine is dormant or a bundle-local fallback failed to initialize.
  if (native_)
    return true;
  return mpv_.core && !mpv_.core->failed();
}

bool PlayerController::engineReady() const { return mpv_.ready(); }

bool PlayerController::initializePlaybackEngine() {
  if (engineReady())
    return true;
  if (const QString failure = mpv_.provisionRuntime(); !failure.isEmpty()) {
    setLastError(failure);
    return false;
  }
  const bool was_available = available();
  if (!mpv_.initialize()) {
    requested_source_.clear();
    mpv_.lineage = {};
    setLastError(mpv_.core->initializationError());
    if (was_available != available())
      emit availableChanged();
    return false;
  }

  mpv_handle *handle = mpv_.core->handle();
  const MpvApi &api = mpv_.core->api();

  // Restore cached UI settings synchronously before observing properties.
  // This prevents mpv's defaults from briefly overwriting the saved state on
  // the first file open.
  double engine_volume = volume_ * 100.0;
  double engine_rate = rate_;
  int engine_muted = muted_ ? 1 : 0;
  if (const TestSeams *seams = testSeams(); seams != nullptr && seams->muted)
    engine_muted = 1;
  int engine_preserve_pitch = preserve_pitch_ ? 1 : 0;
  mpv_.setCoreProperty("volume", MPV_FORMAT_DOUBLE, &engine_volume);
  mpv_.setCoreProperty("speed", MPV_FORMAT_DOUBLE, &engine_rate);
  mpv_.setCoreProperty("mute", MPV_FORMAT_FLAG, &engine_muted);
  // WAM draws subtitles itself, in one overlay, so that a line looks the same
  // whichever engine is playing -- and so that the native route, which has no
  // mpv at all, is not a second-class surface. mpv's own renderer is therefore
  // pinned off for the life of the handle. It keeps selecting, decoding and
  // TIMING subtitles with this off (verified: `sub-text` updates normally at
  // sub-visibility=no), which is exactly the division of labour wanted: mpv
  // owns the timeline it already understands, WAM owns the pixels.
  int engine_subtitles_hidden = 0;
  mpv_.setCoreProperty("sub-visibility", MPV_FORMAT_FLAG,
                  &engine_subtitles_hidden);
  mpv_.setCoreProperty("audio-pitch-correction", MPV_FORMAT_FLAG,
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
  return true;
}

void PlayerController::setSource(const QUrl &source) {
  if (source.isEmpty()) {
    stop();
    return;
  }
  open(source);
}

bool PlayerController::open(const QUrl &source) {
  if (source.isEmpty())
    return false;
  if (native_) {
    // Burn pointer/preview completion ownership before the owner drains any
    // observations from the retiring source. A late exact presentation from
    // that source must not become visible during the replacement transaction.
    invalidateNativeSeekIntents();
    // Preparing/retiring a previous file can temporarily pause the engine.
    // A user open always carries fresh autoplay intent.
    const bool accepted = native_->open(source, 0.0, false);
    if (accepted) {
      setLastError({});
      setLastNotice({});
      updateLoading(true);
      updateSource(source);
      updateMediaTitle(source.fileName());
    }
    return accepted;
  }

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
  mpv_.lineage.pending_source = source;
  mpv_.lineage.pending_request_serial = request_serial_;
  mpv_.lineage.open_attempt.reset();
  mpv_.lineage.render_recovery.reset();
  mpv_.lineage.render_recovery_attempt.reset();
  mpv_.lineage.startup_playback_sync.reset();
  mpv_.lineage.observed_current_path = false;
  mpv_.lineage.terminal_playlist_entry_id = -1;
  mpv_.lineage.last_error_playlist_entry_id = -1;

  // A renderer setup failure is latched for its generation. An explicit user
  // open arms exactly one fresh generation; ordinary render passes do not.
  static_cast<void>(mpv_.core->retryFailedRenderContext());

  if (const auto ticket = mpv_.core->readyRenderTicket())
    return flushPendingOpen(ticket->stamp);

  requestVideoUpdate();
  return true;
}

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
  mpv_.lineage = {};
}

bool PlayerController::nativeRouteAdmissionAllowed() const noexcept {
  // The native engine serves the advertised pitch-preserved window. A rate
  // outside it routes to the compatibility engine, which has no such bound.
  return ::wam::media::native_playback::routeForRate(rate_) ==
             ::wam::media::native_playback::RateRoute::NativeVersion1 &&
         video_item_;
}

bool PlayerController::beginRoutedFallbackOpen(
    const QUrl &source, std::uint64_t attempt, std::uint64_t serial,
    std::uint64_t source_key, bool paused, PlaybackSourceClass source_class) {
  if (!engineReady() || source.isEmpty() || attempt == 0 || serial == 0 ||
      source_key == 0) {
    setLastError(
        QStringLiteral("Could not open this file."));
    return false;
  }

  if (!mpv_.setPausedNow(paused)) {
    setLastError(QStringLiteral(
        "Could not start playback. Please try again."));
    return false;
  }

  mpv_.core->allowRenderContext();
  mpv_.lineage.pending_source = source;
  mpv_.lineage.pending_request_serial = request_serial_;
  mpv_.lineage.routed_fallback_open =
      RoutedFallbackOpen{attempt, serial, source_key, source_class};
  static_cast<void>(mpv_.core->retryFailedRenderContext());
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
  if (!native_ || !mpv_.lineage.routed_fallback_open)
    return;
  const RoutedFallbackOpen lineage = *mpv_.lineage.routed_fallback_open;
  mpv_.lineage.routed_fallback_open.reset();
  native_->fallbackOpenFailed(lineage.attempt, lineage.serial,
                                       lineage.source_key);
}

bool PlayerController::resetRoutedFallbackCoreAfterRelease(
    const std::shared_ptr<PlayerCore> &expected_core) {
  if (!mpv_.replaceAfterRenderRelease(expected_core))
    return false;
  requestVideoUpdate();
  return true;
}

void PlayerController::play() {
  if (native_) {
    if (nativeRouteActive() && native_scrub_intent_) {
      // A native seek converges while physically paused. Keep play/pause as
      // logical post-seek intent; the owner applies the latest value only after
      // exact CommitReady proof.
      setNativeScrubPauseIntent(false);
      updatePause(false);
      return;
    }
    if (nativeRouteActive() && native_seek_intent_) {
      setNativeScrubPauseIntent(false);
      updatePause(false);
    }
    const auto disposition = native_->setPaused(false);
    if (disposition == NativeEngine::PauseDisposition::NativeHandled ||
        disposition == NativeEngine::PauseDisposition::NotOwned) {
      if (disposition == NativeEngine::PauseDisposition::NativeHandled &&
          atEndForReplay(native_frame_duration_) && !native_seek_intent_) {
        // Native Ended retains its graph. Replay is one ordinary exact seek
        // to zero; CommitReady then restores the retained playing intent.
        updatePause(false);
        seekTo(0.0);
      }
      return;
    }
  }
  if (!engineReady())
    return;
  if (scrub_seek_) {
    scrub_seek_->intended_paused = false;
    updatePause(false);
    return;
  }
  if (eof_reached_ && mpv_.lineage.committed_open &&
      mpv_.lineage.terminal_playlist_entry_id == mpv_.lineage.committed_open->playlist_entry_id) {
    mpv_.lineage.active_event_playlist_entry_id = mpv_.lineage.terminal_playlist_entry_id;
    mpv_.lineage.terminal_playlist_entry_id = -1;
  }
  const double fps = mpv_.doubleProperty("estimated-vf-fps").value_or(0.0);
  if (atEndForReplay(std::isfinite(fps) && fps > 0.0 ? 1.0 / fps : 0.0))
    seekTo(0.0);
  updateEof(false);
  if (mpv_.lineage.render_recovery && mpv_.lineage.render_recovery->request_serial == request_serial_) {
    mpv_.lineage.render_recovery->paused = false;
    mpv_.lineage.render_recovery->transport_restored = false;
  }
  if (mpv_.lineage.startup_playback_sync &&
      mpv_.lineage.startup_playback_sync->request_serial == request_serial_) {
    mpv_.lineage.startup_playback_sync->intended_paused = false;
  }
  int paused = 0;
  mpv_.setPropertyAsync("pause",
                                      MPV_FORMAT_FLAG, &paused);
  updatePause(false);
}

void PlayerController::pause() {
  if (native_) {
    if (nativeRouteActive() && native_scrub_intent_) {
      setNativeScrubPauseIntent(true);
      updatePause(true);
      return;
    }
    if (nativeRouteActive() && native_seek_intent_) {
      setNativeScrubPauseIntent(true);
      updatePause(true);
    }
    const auto disposition = native_->setPaused(true);
    if (disposition == NativeEngine::PauseDisposition::NativeHandled ||
        disposition == NativeEngine::PauseDisposition::NotOwned) {
      return;
    }
  }
  if (!engineReady())
    return;
  if (scrub_seek_) {
    scrub_seek_->intended_paused = true;
    updatePause(true);
    return;
  }
  if (mpv_.lineage.render_recovery && mpv_.lineage.render_recovery->request_serial == request_serial_) {
    if (!mpv_.lineage.render_recovery->paused && !mpv_.lineage.render_recovery->position_overridden) {
      const auto live_position = mpv_.doubleProperty("time-pos");
      if (live_position && std::isfinite(*live_position))
        mpv_.lineage.render_recovery->position = std::max(0.0, *live_position);
    }
    mpv_.lineage.render_recovery->paused = true;
    mpv_.lineage.render_recovery->transport_restored = false;
  }
  if (mpv_.lineage.startup_playback_sync &&
      mpv_.lineage.startup_playback_sync->request_serial == request_serial_) {
    mpv_.lineage.startup_playback_sync->intended_paused = true;
  }
  int paused = 1;
  mpv_.setPropertyAsync("pause",
                                      MPV_FORMAT_FLAG, &paused);
  updatePause(true);
}

bool PlayerController::atEndForReplay(double frame_duration) const noexcept {
  return eof_reached_ ||
         (duration_ > 0.0 &&
          position_ >= duration_ - std::max(0.05, frame_duration));
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
  if (native_) {
    static_cast<void>(native_->stop());
    return;
  }
  finishStopUi(true);
}

void PlayerController::finishStopUi(bool stop_compatibility_engine) {
  updateLoading(false);
  invalidateNativeSeekIntents();
  ++request_serial_;
  if (request_serial_ == 0)
    ++request_serial_;
  requested_source_.clear();
  mpv_.lineage = {};
  cancelCaptionsForMediaChange();
  if (stop_compatibility_engine && engineReady())
    mpv_.sendCommand({QByteArrayLiteral("stop")});
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
  // Floor every native target onto a 1/64 s binary grid (15.6 ms, below one
  // frame at 60 fps, so the handle and the picture stay visually identical),
  // and hold the target strictly below the duration so a drag to the end of
  // the timeline commits instead of being refused.
  //
  // This is the ONLY place a seek target is snapped to that grid. Every native
  // entry point -- pointer drag, timeline click, keyboard, auto-resume, the
  // scripted-seek seam -- reaches it through seekTo/previewSeekTo/endScrub or
  // through the intent factories, so a caller that pre-floors is restating
  // this rule rather than adding one, and would drift from it.
  //
  // The guard is exactly one grid step, which is the whole of what the
  // preflight's strict inequality needs. End of stream overtaking a commit
  // that lands in the last frame is NativeMediaSession's concern
  // (commitRunStatePending), not seek arithmetic, so no wider guard is needed.
  constexpr double kSeekGrid = 64.0;
  const double bounded = boundedSeekTarget(seconds);
  if (!std::isfinite(bounded) || bounded <= 0.0)
    return 0.0;
  double target = std::floor(bounded * kSeekGrid) / kSeekGrid;
  // Strictly inside the limit, on the grid: the largest admissible target is
  // the last grid point below nativeSeekLimit(), never the limit itself.
  const double limit = nativeSeekLimit();
  if (limit > 0.0 && target >= limit)
    target = std::floor((limit - 1.0 / kSeekGrid) * kSeekGrid) / kSeekGrid;
  if (!(target > 0.0))
    return 0.0;
  return target;
}

double PlayerController::nativeSeekLimit() const noexcept {
  // The duration is the right bound only while every selected lane reaches
  // it. A container may let audio outlive the last picture, and a target in
  // that tail has no frame to draw: the session admits targets strictly below
  // its presentable ceiling (NativeMediaSession::seekCeilingSeconds, the
  // selected video track's end), so the snap holds them there too -- a drag to
  // the end of the timeline lands on the last frame instead of being refused.
  // The two bounds are the same rule stated in two places by necessity: the
  // session's is the admission gate, this is the snap that satisfies it.
  if (native_seek_ceiling_ > 0.0 &&
      (duration_ <= 0.0 || native_seek_ceiling_ < duration_))
    return native_seek_ceiling_;
  return duration_;
}

void PlayerController::updateNativeSeekCeiling(double seconds) {
  native_seek_ceiling_ = std::isfinite(seconds) ? std::max(0.0, seconds) : 0.0;
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
  // Same strictly-inside-the-limit rule exactNativeSeekTarget applies, on
  // this grid: the last admissible target is the last grid point below
  // nativeSeekLimit(), never the limit itself.
  const double limit = nativeSeekLimit();
  if (limit > 0.0 && target >= limit) {
    target = std::floor((limit - 1.0 / kFrameStepGrid) * kFrameStepGrid) /
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
  updatePosition(intent.target);

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
    updatePosition(intent.rollback_position);
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
      updatePosition(intent.target);
    } else if (submission_state.terminal == NativeSeekTerminal::Ready) {
      updatePosition(intent.target);
      updateEof(false);
      updateIdle(false);
    } else {
      updatePosition(intent.rollback_position);
    }
    return NativeSeekDispatch::Consumed;
  case NativeSeekSubmission::Rejected:
    updatePosition(intent.rollback_position);
    return NativeSeekDispatch::Consumed;
  case NativeSeekSubmission::Compatibility:
    return NativeSeekDispatch::Compatibility;
  }
  updatePosition(intent.rollback_position);
  return NativeSeekDispatch::Consumed;
}

PlayerController::NativePreviewSubmission
PlayerController::submitNativePreviewFrame(
    void *context, const NativePreviewIntent &intent) noexcept {
  auto &owner = *static_cast<NativeEngine *>(context);
  switch (owner.previewFrame(intent.target, intent.gesture, intent.request)) {
  case NativeEngine::PreviewDisposition::Accepted:
    return NativePreviewSubmission::Accepted;
  case NativeEngine::PreviewDisposition::Replaced:
    return NativePreviewSubmission::Replaced;
  case NativeEngine::PreviewDisposition::Stale:
    return NativePreviewSubmission::Stale;
  case NativeEngine::PreviewDisposition::NotOwned:
  case NativeEngine::PreviewDisposition::Rejected:
    return NativePreviewSubmission::Rejected;
  }
  return NativePreviewSubmission::Rejected;
}

void PlayerController::dispatchNativePreviewIntent(
    const NativePreviewIntent &intent) {
  dispatchNativePreviewIntent(intent, native_.get(),
                              &submitNativePreviewFrame);
}

void PlayerController::nativePreviewPresented(
    const ::wam::media::native_playback::PreviewPresented &presented) {
  static_cast<void>(completeNativePreviewPresented(
      presented.gesture.value, presented.request.value,
      presented.actualPresentationTimeSeconds, native_.get(),
      &submitNativePreviewFrame));
}

void PlayerController::nativePreviewFailed(
    const ::wam::media::native_playback::PreviewFailed &failed) {
  static_cast<void>(completeNativePreviewFailed(
      failed.gesture.value, failed.request.value, native_.get(),
      &submitNativePreviewFrame));
}

PlayerController::NativeSeekDispatch
PlayerController::dispatchNativeSeekIntent(const NativeSeekIntent &intent) {
  const auto submit = [](void *context,
                         const NativeSeekIntent &request) noexcept {
    auto &owner = *static_cast<NativeEngine *>(context);
    switch (owner.commitSeek(request.target, request.gesture, request.request,
                             request.intended_paused)) {
    case NativeEngine::SeekDisposition::NativeHandled:
      return NativeSeekSubmission::Accepted;
    case NativeEngine::SeekDisposition::NativeRejected:
      return NativeSeekSubmission::Rejected;
    case NativeEngine::SeekDisposition::NotOwned:
    case NativeEngine::SeekDisposition::FallbackHandled:
      return NativeSeekSubmission::Compatibility;
    }
    return NativeSeekSubmission::Rejected;
  };
  return dispatchNativeSeekIntent(intent, native_.get(), submit);
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
    updatePosition(boundedSeekTarget(actual_presentation_time));
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
  updatePosition(position);
}

void PlayerController::updatePosition(double position) {
  if (!std::isfinite(position) || nearlyEqual(position_, position))
    return;
  position_ = position;
  emit positionChanged();
}

void PlayerController::beginScrub() {
  if (nativeRouteActive()) {
    if (!beginNativeScrubIntent())
      return;
    const auto disposition = native_->setPaused(true);
    if (disposition == NativeEngine::PauseDisposition::NativeHandled) {
      // Pointer-down starts the surface-budget handoff before the MouseArea's
      // first immediate motion preview. Refusal stays silent; release still
      // commits one exact seek and restores the captured logical pause intent.
      // A refusal that means "this source has no frame to preview" (audio
      // only) is remembered for the whole gesture, so motion samples publish
      // the time readout without demanding a thumbnail that cannot exist.
      const auto handoff = native_->preparePreviewHandoff();
      if (native_scrub_intent_) {
        native_scrub_intent_->preview_available =
            handoff !=
            NativeEngine::PreviewHandoffDisposition::Unsupported;
      }
      return;
    }
    invalidateNativeScrubIntent();
    if (disposition != NativeEngine::PauseDisposition::FallbackHandled) {
      return;
    }
  }
  if (!engineReady() || scrub_seek_ || mpv_.lineage.render_recovery ||
      mpv_.lineage.startup_playback_sync || !acceptsPlaybackObservation()) {
    return;
  }

  const std::optional<bool> live_paused = mpv_.flagProperty("pause");
  if (!live_paused)
    return;
  ++next_scrub_gesture_id_;
  if (next_scrub_gesture_id_ == 0)
    ++next_scrub_gesture_id_;
  scrub_seek_ = ScrubSeek{next_scrub_gesture_id_,
                          request_serial_,
                          0,
                          mpv_.lineage.committed_open->playlist_entry_id,
                          position_,
                          std::nullopt,
                          std::nullopt,
                          *live_paused};

  if (!mpv_.setPausedNow(true)) {
    scrub_seek_.reset();
    return;
  }
  updatePause(*live_paused);
}

void PlayerController::seekTo(double seconds) {
  if (nativeRouteActive()) {
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
  if (!engineReady() || !std::isfinite(seconds))
    return;
  if (scrub_seek_) {
    endScrub(seconds);
    return;
  }
  const double target = boundedSeekTarget(seconds);
  if (mpv_.lineage.render_recovery && mpv_.lineage.render_recovery->request_serial == request_serial_) {
    mpv_.lineage.render_recovery->position = target;
    mpv_.lineage.render_recovery->transport_restored = false;
    mpv_.lineage.render_recovery->position_overridden = true;
  }
  if (mpv_.lineage.startup_playback_sync &&
      mpv_.lineage.startup_playback_sync->request_serial == request_serial_) {
    mpv_.lineage.startup_playback_sync->intended_position = target;
    mpv_.lineage.startup_playback_sync->position_overridden = true;
  }
  double value = target;
  mpv_.setPropertyAsync("time-pos",
                                      MPV_FORMAT_DOUBLE, &value);
  updatePosition(target);
}

void PlayerController::previewSeekTo(double seconds) {
#if defined(WAM_QT_TEST_SEAMS)
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
  if (nativeRouteActive()) {
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
      updatePosition(target);
      return;
    }
    const auto observeDemand = [](void *context,
                                  const NativePreviewIntent &intent) noexcept {
      auto &controller = *static_cast<PlayerController *>(context);
      controller.native_->notePreviewDemanded(intent.gesture, intent.request,
                                              intent.target,
                                              controller.engineReady());
    };
    if (auto intent =
            makeObservedNativePreviewIntent(seconds, this, observeDemand)) {
      dispatchNativePreviewIntent(*intent);
    }
    return;
  }
  if (!engineReady() || !std::isfinite(seconds))
    return;
  const double target = boundedSeekTarget(seconds);
  if (!scrub_seek_) {
    // Preview calls belong only to an explicitly owned pointer gesture. If
    // startup or render recovery refused ownership, ignore cadence updates;
    // the release path still performs one ordinary exact seek.
    return;
  }
  if (mpv_.lineage.render_recovery && mpv_.lineage.render_recovery->request_serial == request_serial_) {
    mpv_.lineage.render_recovery->position = target;
    mpv_.lineage.render_recovery->transport_restored = false;
    mpv_.lineage.render_recovery->position_overridden = true;
  }
  if (mpv_.lineage.startup_playback_sync &&
      mpv_.lineage.startup_playback_sync->request_serial == request_serial_) {
    mpv_.lineage.startup_playback_sync->intended_position = target;
    mpv_.lineage.startup_playback_sync->position_overridden = true;
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
  updatePosition(target);
}

void PlayerController::endScrub(double seconds) {
  if (nativeRouteActive()) {
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
  if (!scrub_seek_) {
    seekTo(seconds);
    return;
  }
  if (!engineReady() || !std::isfinite(seconds) ||
      scrub_seek_->request_serial != request_serial_) {
    finishScrubGesture(true);
    return;
  }
  const double target = boundedSeekTarget(seconds);
  scrub_seek_->final = true;
  scrub_seek_->pending_target = target;
  if (scrub_seek_->command == 0) {
    scrub_seek_->pending_target.reset();
    dispatchScrubSeek(target, true);
  }
  updatePosition(target);
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
      scrub_seek_->request_serial != request_serial_ || !mpv_.lineage.committed_open ||
      mpv_.lineage.committed_open->request_serial != request_serial_ ||
      mpv_.lineage.committed_open->playlist_entry_id != scrub_seek_->playlist_entry_id ||
      mpv_.lineage.active_event_playlist_entry_id != scrub_seek_->playlist_entry_id) {
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
  const int result = mpv_.sendCommand({QByteArrayLiteral("seek"),
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
    mpv_.abortCommand(mpvReplyUserdata(MpvReply::Scrub, command));
  }
}

void PlayerController::handleScrubCommandReply(std::uint64_t command,
                                               int error) {
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
      scrub_seek_->request_serial != request_serial_ || !mpv_.lineage.committed_open ||
      mpv_.lineage.committed_open->request_serial != request_serial_ ||
      mpv_.lineage.committed_open->playlist_entry_id != scrub_seek_->playlist_entry_id ||
      mpv_.lineage.active_event_playlist_entry_id != scrub_seek_->playlist_entry_id ||
      !engineReady()) {
    return;
  }
  scrub_seek_->playback_restarted = true;
  const auto live_position = mpv_.doubleProperty("time-pos");
  if (live_position && std::isfinite(*live_position))
    scrub_seek_->authoritative_position = std::max(0.0, *live_position);
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
      scrub_seek_->request_serial == request_serial_ && mpv_.lineage.committed_open &&
      mpv_.lineage.committed_open->request_serial == request_serial_ &&
      mpv_.lineage.committed_open->playlist_entry_id == scrub_seek_->playlist_entry_id &&
      mpv_.lineage.active_event_playlist_entry_id == scrub_seek_->playlist_entry_id;
  if (active_command != 0 && engineReady()) {
    mpv_.abortCommand(mpvReplyUserdata(MpvReply::Scrub, active_command));
  }
  scrub_seek_.reset();
  if (!restore_transport || !matching_lineage || !engineReady())
    return;
  if (mpv_.setPausedNow(intended_paused))
    updatePause(intended_paused);
}

void PlayerController::invalidateScrubGesture() { finishScrubGesture(false); }

void PlayerController::seekRelative(double seconds) {
  if (nativeRouteActive()) {
    if (std::isfinite(seconds))
      seekTo(position_ + seconds);
    return;
  }
  if (!engineReady() || !std::isfinite(seconds))
    return;
  if (scrub_seek_ || mpv_.lineage.render_recovery || position_ + seconds < 0.0 ||
      (duration_ > 0.0 && position_ + seconds >= duration_)) {
    seekTo(duration_ > 0.0 ? std::clamp(position_ + seconds, 0.0,
        std::max(0.0, duration_ - 0.001)) : position_ + seconds);
    return;
  }
  if (native_)
    native_->noteFallbackSeek(true);
  mpv_.sendCommand({QByteArrayLiteral("seek"), QByteArray::number(seconds, 'g', 12),
               QByteArrayLiteral("relative+exact")});
}

void PlayerController::skipBackward() {
  if (settings_)
    seekRelative(-settings_->seekStepSeconds());
}

void PlayerController::skipForward() {
  if (settings_)
    seekRelative(settings_->seekStepSeconds());
}

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

  if (nativeRouteActive()) {
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

  if (!engineReady())
    return;
  // The compatibility route has the operation natively and exactly: mpv's own
  // frame-step / frame-back-step decode by one presented picture, so no PTS
  // arithmetic happens here at all. frame-back-step is the expensive one (mpv
  // re-seeks and re-decodes from the preceding keyframe).
  mpv_.sendCommand({forward ? QByteArrayLiteral("frame-step")
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
  const bool native_owned = native_ && native_->setMuted(muted);
  if (!native_owned && engineReady()) {
    int value = muted ? 1 : 0;
    mpv_.setPropertyAsync("mute",
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
  setMuted(false);
  // The configured maximum, never the absolute one: the engine would happily
  // take 4.0, and the whole point of the setting is that this installation
  // has decided it should not.
  const double normalized =
      std::clamp(volume, kMinimumVolume, maximum_volume_);
  const bool native_owned =
      native_ && native_->setGain(static_cast<float>(normalized));
  if (!native_owned && engineReady()) {
    double mpv_volume = normalized * 100.0;
    mpv_.setPropertyAsync("volume",
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
  // A window sitting above the new ceiling comes down at once rather than
  // staying loud until the next time something touches the level. setVolume
  // re-clamps against the maximum just installed, so the value it lands on is
  // exactly the new ceiling.
  if (volume_ > maximum_volume_) {
    setVolume(maximum_volume_);
    emit volumeClamped();
  }
}

void PlayerController::bindSettings(const AppSettings &settings) {
  settings_ = &settings;
  setPreservePitch(settings.preservePitch());
  setMaximumVolume(settings.maximumVolume());
  connect(&settings, &AppSettings::preservePitchChanged, this,
          [this] { setPreservePitch(settings_->preservePitch()); });
  connect(&settings, &AppSettings::maximumVolumeChanged, this,
          [this] { setMaximumVolume(settings_->maximumVolume()); });
  connect(&settings, &AppSettings::scrollGesturesEnabledChanged, this, [this] {
    // Switching the preference off mid-sweep must not leave a scrub gesture
    // open on the native route -- that would hold the window paused with the
    // surface-budget handoff still armed.
    if (!settings_->scrollGesturesEnabled())
      settleScrollGesture();
  });
}

double PlayerController::snapVolumeToDetent(double volume) const {
  return ScrollGestureModel::snapVolumeToDetent(volume);
}

int PlayerController::scrollGesture(double pixelDeltaX, double pixelDeltaY,
                                    double angleDeltaX, double angleDeltaY,
                                    bool inverted, int phase) {
  if (!settings_ || !settings_->scrollGesturesEnabled() || !hasMedia())
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
  const double bounded = std::round(std::clamp(rate, kMinimumNativeRate, kMaximumNativeRate) * kNativeRateGrid) / kNativeRateGrid;
  if (nativeRouteActive()) {
    if (!native_->setRate(bounded)) {
      setLastNotice(
          QStringLiteral("Could not change playback speed."));
      return;
    }
    if (nearlyEqual(rate_, bounded))
      return;
    rate_ = bounded;
    emit rateChanged();
    return;
  }
  if (engineReady()) {
    double value = bounded;
    mpv_.setPropertyAsync("speed",
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
  // on both routes. It is not mpv's sub-visibility flag, which is pinned off
  // because WAM draws the text itself.
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

bool PlayerController::nativeRouteActive() const {
  return native_ && native_->nativeOwnsTransport();
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
  const bool off = subtitles_->activeId() == SubtitleSources::kOffId ||
                   subtitles_->activeIsGenerated();
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
  // Closed captions are read live out of the stream, so the source that
  // lists them can only appear once a caption byte has gone by. It is added
  // here, on the position tick, the first time the feed reports one.
  if (caption_feed_ && nativeRouteActive() &&
      caption_feed_->sawCaptions() && !subtitles_->hasClosedCaptionsSource()) {
    subtitles_->addClosedCaptionsSource();
    emit subtitleTracksChanged();
  }
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
  caption_live_bridge_.reset();
  if (!subtitles_)
    return;
  if (caption_feed_)
    caption_feed_->clear();
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
  const std::int64_t count = mpv_.intProperty("track-list/count").value_or(0);
  if (count <= 0) {
    subtitles_->setEmbeddedTracks(std::move(tracks));
    return;
  }
  // The flat sub-property idiom, not MPV_FORMAT_NODE: a node read would need
  // mpv_free_node_contents, which is not in the resolved symbol table, and
  // leaking the whole track list on every file open to avoid one loop is not
  // a trade worth making.
  const auto readString = [this](std::int64_t index,
                                 const char *field) -> QString {
    const QByteArray name = QByteArrayLiteral("track-list/") +
                            QByteArray::number(index) + '/' + field;
    return mpv_.stringProperty(name.constData()).value_or(QString());
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
      // the caption outputs specifically, NOT on mpv_.lineage.attached_subtitle_files:
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
      // default flag, but it is not used as one: every MP4 text track is
      // listed and none is auto-selected.
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
  if (mpv_.lineage.open_attempt) return; // refreshed after first-frame startup completion
  if (!subtitles_ || source_.isEmpty())
    return;
  const bool native = nativeRouteActive();
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
  } else if (source->generatedCues) {
    // Both playback routes use the same in-memory generated track.
  } else if (source->mpvSid > 0) {
    // Compatibility route: mpv owns selection and timing; the overlay is fed
    // by the sub-text observation.
    static_cast<void>(mpv_.setTrackSelection("sid", source->mpvSid));
    mpv_.lineage.selected_subtitle_track_id = source->mpvSid;
    publishSubtitleText({});
  } else {
    // Native route: this process reads the cues, off the playback graph.
    publishSubtitleText({});
    subtitles_->beginNativeLoad(id);
  }

  if (id == SubtitleSources::kOffId && engineReady()) {
    static_cast<void>(mpv_.setTrackSelection("sid", 0));
    mpv_.lineage.selected_subtitle_track_id = 0;
  }

  const bool visible = id != SubtitleSources::kOffId;
  if (captions_visible_ != visible) {
    captions_visible_ = visible;
    emit captionsVisibleChanged();
  }
  emit activeSubtitleTrackChanged();
  updateSubtitleForPosition();
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
  if (!nativeRouteActive()) {
    // Compatibility route: hand it to mpv, which then reports it in
    // track-list and times it for us. The TrackListCount observation turns
    // that into a menu entry.
    if (!attachSubtitleFile(path))
      return false;
    refreshSubtitleSources();
    const int id = subtitles_->idForMpvSid(
        mpv_.currentTrackSelection("sid"));
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

void PlayerController::setPreservePitch(bool preserve) {
  if (nativeRouteActive()) {
    // The native stretch stage serves both modes: pitch preserved is a zero
    // pitch offset on the time-stretch unit, varispeed is an offset of
    // 1200 * log2(rate) cents on the same unit. Nothing to refuse, and it
    // applies live -- the render callback latches it at its next boundary.
    static_cast<void>(native_->setPreservePitch(preserve));
    preserve_pitch_ = preserve;
    return;
  }
  if (engineReady()) {
    int value = preserve ? 1 : 0;
    mpv_.setPropertyAsync("audio-pitch-correction", MPV_FORMAT_FLAG, &value);
  }
  preserve_pitch_ = preserve;
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
  // Export retiming is its own decision: Quick Edit owns an explicit export
  // speed that starts at 1x, and the live viewing rate (rate_) never reaches
  // this path, so reviewing a clip at 2x does not ship a 2x cut.
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
  if (captioning_) {
    setLastError(QStringLiteral("Another caption task is already running."));
    return;
  }
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
  if (captioning_) {
    setLastError(QStringLiteral("Another caption task is already running."));
    return;
  }

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
  request.options.overwrite = true;
  const TestSeams *const seams = testSeams();
  if (seams != nullptr && seams->captionMetrics && seams->captionEngineWhisper)
    request.options.prefer_apple = false;
  auto bridge = std::shared_ptr<CaptionLiveBridge>(new CaptionLiveBridge,
      [](CaptionLiveBridge* p) { p->deleteLater(); });
  caption_live_bridge_ = bridge;
  caption_live_selected_ = false;
  caption_track_committed_ = false;
  const QUrl media = source_;
  connect(bridge.get(), &CaptionLiveBridge::available, this,
      [this, weak=std::weak_ptr<CaptionLiveBridge>(bridge), media, path=*output] {
    const auto bridge = weak.lock();
    if (!bridge) return;
    if (caption_live_bridge_ != bridge || source_ != media) return;
    // Never wait on a backend mutex from the UI. Retry on a queued turn if
    // publication owns it; queued remains set so producers stay coalesced.
    std::unique_lock lock(bridge->mutex, std::try_to_lock);
    if (!lock.owns_lock()) { QMetaObject::invokeMethod(bridge.get(), "available", Qt::QueuedConnection); return; }
    auto snapshot = bridge->latest;
    bridge->queued.store(false);
    lock.unlock();
    if (!snapshot || !subtitles_) return;
    const int id = subtitles_->updateGenerated(path, snapshot->cues, snapshot->committed);
    if (!caption_live_selected_) {
      caption_live_selected_ = true;
      selectSubtitleTrack(id);
    }
    caption_track_committed_ = snapshot->committed;
    emit subtitleTracksChanged();
    updateSubtitleForPosition();
    if (snapshot->committed && testSeams() != nullptr && testSeams()->captionMetrics)
      qInfo() << "caption-track: committed";
  }, Qt::QueuedConnection);
  request.live_segments = [bridge](std::vector<::wam::CaptionSegment> segments) {
    auto cues = std::make_shared<std::vector<media::subtitles::Cue>>();
    for (const auto& segment : segments)
      cues->push_back({static_cast<std::int64_t>(segment.start*1e9),
                      static_cast<std::int64_t>(segment.end*1e9), segment.text});
    bridge->publish(std::make_shared<CaptionLiveBridge::Snapshot>(CaptionLiveBridge::Snapshot{cues,false}));
  };
  request.committed = [bridge](const std::filesystem::path& path) {
    QFile file(QString::fromStdString(path.string()));
    if (!file.open(QIODevice::ReadOnly) || file.size() > 16*1024*1024)
      throw std::runtime_error("Could not read committed captions");
    const auto bytes = file.readAll();
    auto parsed = media::subtitles::parseSubRip(std::string_view(bytes.constData(),bytes.size()));
    if (parsed.cues.empty()) throw std::runtime_error("Committed captions contain no cues");
    media::subtitles::finalizeCues(&parsed.cues, false);
    auto cues = std::make_shared<const std::vector<media::subtitles::Cue>>(std::move(parsed.cues));
    bridge->publish(std::make_shared<CaptionLiveBridge::Snapshot>(CaptionLiveBridge::Snapshot{cues,true}));
  };

  if (!caption_service_->start(std::move(request))) {
    const ::wam::CaptionStatus status = caption_service_->tryStatus().value_or(::wam::CaptionStatus{});
    const QString error = fromUtf8(status.error);
    setLastError(
        error.isEmpty()
            ? QStringLiteral("Another caption task is already running.")
            : error);
    return;
  }

  setLastError({});
  caption_download_prompted_ = false;
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
  caption_cancel_reason_ = QStringLiteral("Caption generation cancelled.");
  caption_service_->cancel();
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
    const auto snapshot = caption_service_->tryStatus();
    if (!snapshot) return;
    const ::wam::CaptionStatus& status = *snapshot;
    if (status.needs_download_consent && !caption_download_prompted_) {
      caption_download_prompted_ = true;
#ifdef Q_OS_MACOS
      QPointer<PlayerController> controller(this);
      ::wam::showCaptionDownloadPrompt(status.download_locale, [controller](bool consent) {
        if (controller) controller->caption_service_->respondToDownload(consent);
      });
#else
      caption_service_->respondToDownload(false);
#endif
    }
    const QString message = fromUtf8(status.message);
    if (!message.isEmpty())
      setCaptionStatus(message);

    if (status.finished) {
      caption_completion_pending_ = false;
      setCaptioning(false);
      if (status.succeeded) {
        const auto current_input = localPath(source_);
        if (!current_input || caption_input_.empty() ||
            !pathsReferToSameFile(caption_input_, *current_input)) {
          setCaptionStatus(QStringLiteral(
              "Captions saved, but not attached because the media changed."));
        } else {
          setCaptionStatus(QStringLiteral("Captions generated and enabled."));
          setLastError({});
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
      if (!status.succeeded) {
        caption_live_bridge_.reset();
        if (subtitles_ && subtitles_->activeIsGenerated()) selectSubtitleTrack(SubtitleSources::kOffId);
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
      mpv_.commandNow(arguments.data());
  if (result < 0)
    return false;
  if (std::find(mpv_.lineage.attached_subtitle_files.begin(),
                mpv_.lineage.attached_subtitle_files.end(),
                subtitle) == mpv_.lineage.attached_subtitle_files.end()) {
    mpv_.lineage.attached_subtitle_files.push_back(subtitle);
  }
  // Deliberately NOT setCaptionsVisible(true): selecting the source
  // is what turns subtitles on, and doing both would fight over which track
  // the switch restores.
  return true;
}

void PlayerController::drainMpvEvents() {
  if (!engineReady())
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
  } native_drain_scope{native_.get()};

  while (true) {
    mpv_event *event = mpv_.core->api().mpv_wait_event(mpv_.core->handle(), 0.0);
    if (!event || event->event_id == MPV_EVENT_NONE)
      break;

    if (event->event_id == MPV_EVENT_COMMAND_REPLY) {
      const MpvReplyTag reply = parseMpvReply(event->reply_userdata);
      if (native_ && reply.kind == MpvReply::FallbackStop) {
        native_->fallbackStopCommandReply(reply.id, event->error);
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
    if (native_ &&
        !native_->acceptsFallbackPlaybackEvents()) {
      continue;
    }

    if (event->event_id == MPV_EVENT_START_FILE) {
      mpv_.core->beginFallbackMetricsEpoch();
      const auto *start = static_cast<mpv_event_start_file *>(event->data);
      handleStartFile(start ? start->playlist_entry_id : -1);
      continue;
    }

    if (event->event_id == MPV_EVENT_FILE_LOADED) {
      handlePlaybackReady(true);
      continue;
    }

    if (event->event_id == MPV_EVENT_PLAYBACK_RESTART) {
      if (native_)
        native_->noteFallbackSeek(false);
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
        if (native_)
          native_->fallbackIdleChanged(idle);
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
      case ObservedProperty::Path: {
        const QUrl observed_source = urlFromMpvPath(readString(property));
        // requested_source_ is authoritative across asynchronous replacement.
        // Ignore empty transition values and paths from an older request; Stop
        // clears the visible source synchronously itself.
        if (requested_source_.isEmpty() || observed_source.isEmpty())
          break;
        if (mpv_.lineage.pending_source.isEmpty() && mpv_.lineage.committed_open &&
            mpv_.lineage.committed_open->request_serial == request_serial_ &&
            mpv_.lineage.committed_open->playlist_entry_id >= 0 &&
            mpv_.lineage.committed_open->playlist_entry_id ==
                mpv_.lineage.active_event_playlist_entry_id) {
          mpv_.lineage.committed_entry_source = observed_source;
        }
        if (sourceIdentity(observed_source) !=
            sourceIdentity(requested_source_)) {
          break;
        }
        mpv_.lineage.observed_current_path = true;
        updateSource(observed_source);
        break;
      }
      case ObservedProperty::MediaTitle: {
        QString value = readString(property);
        if (!mpv_.lineage.observed_current_path && !value.isEmpty())
          break;
        if (value.isEmpty())
          value = fallbackTitle(source_);
        updateMediaTitle(value);
        break;
      }
      case ObservedProperty::PreservePitch: {
        preserve_pitch_ = readFlag(property, true);
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
        if (subtitles_ && subtitles_->activeIsGenerated()) break;
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
        if (mpv_.lineage.open_attempt && mpv_.lineage.open_attempt->reply_ready &&
            mpv_.lineage.open_attempt->playlist_entry_id == end->playlist_entry_id)
          handleOpenCommandReply(mpv_.lineage.open_attempt->id, 0);
        handleEndFile(*end);
      }
    }
  }
}

void PlayerController::requestVideoUpdate() {
  // On the CALayer presentation route the frame is already on screen: the
  // AVSampleBufferDisplayLayer sitting below Qt's view was handed the decoded
  // IOSurface and WindowServer composites it directly. The Qt video item has
  // nothing to paint, so dirtying the scene here would buy a full scene-graph
  // render+swap per frame for no pixels -- measured at ~30 render passes per
  // second, against zero when the item stops updating and the chrome is hidden.
  //
  // The route flag is process-wide, but the suppression is NOT: it is only
  // correct for a window whose own playback the native route owns. WAM is a
  // multi-window player, so one window can be playing natively on the layer
  // route while another has fallen back to the compatibility engine and is
  // painting through the scene graph -- and suppressing that window's updates
  // because some OTHER window is on the layer route would freeze its video on
  // its first frame. Both halves of the test are therefore required.
  if (native_ && native_->presentsOutsideScene())
    return;
  if (video_item_)
    video_item_->update();
}

bool PlayerController::needsRenderContext() const {
  return engineReady() &&
         (!native_ || native_->needsFallbackRenderContext()) &&
         !requested_source_.isEmpty();
}

void PlayerController::continuePendingOpen() {
  if (mpv_.core) {
    if (const auto ticket = mpv_.core->readyRenderTicket()) {
      static_cast<void>(flushPendingOpen(ticket->stamp));
      return;
    }
  }
  requestVideoUpdate();
}

bool PlayerController::flushPendingOpen(std::uint64_t render_stamp) {
  if (!mpv_.core || !engineReady())
    return true;

  if (mpv_.lineage.pending_source.isEmpty() || mpv_.lineage.pending_request_serial == 0) {
    if (!mpv_.lineage.render_recovery && mpv_.lineage.committed_open &&
        mpv_.lineage.committed_open->request_serial == request_serial_ &&
        mpv_.lineage.committed_open->render_stamp == 0 &&
        mpv_.core->validateRenderTicket({render_stamp})) {
      mpv_.lineage.committed_open->render_stamp = render_stamp;
    }
    return flushRenderRecovery(render_stamp);
  }

  const RenderTicket ticket{render_stamp};
  if (!mpv_.core->validateRenderTicket(ticket))
    return true;

  if (mpv_.lineage.open_attempt &&
      mpv_.lineage.open_attempt->request_serial == mpv_.lineage.pending_request_serial &&
      mpv_.lineage.open_attempt->render_stamp == render_stamp) {
    return true;
  }

  const QUrl source = mpv_.lineage.pending_source;
  const std::uint64_t request_serial = mpv_.lineage.pending_request_serial;
  const QString argument = sourceArgument(source);
  if (argument.isEmpty()) {
    abandonPendingOpen();
    setLastError(QStringLiteral("Unable to open an empty media location."));
    notifyRoutedFallbackOpenFailed();
    return false;
  }

  const PlaybackSourceClass source_class =
      mpv_.lineage.routed_fallback_open
          ? mpv_.lineage.routed_fallback_open->source_class
          : playbackSourceClass(displayUrlForSource(source));
  mpv_.applyPlaybackBufferPolicy(source_class);
  if (!mpv_.core->validateRenderTicket(ticket)) {
    continuePendingOpen();
    return true;
  }

  const std::uint64_t reply_userdata = mpvReplyUserdata(
      MpvReply::Open, nextMpvReplyId(MpvReply::Open, next_open_attempt_id_));
  const QByteArray utf8 = argument.toUtf8();
  const int result = mpv_.sendCommand({QByteArrayLiteral("loadfile"), utf8, QByteArrayLiteral("replace")},
      reply_userdata);
  if (result < 0) {
    // A queueing failure is stable for this request. Leave renderer retries to
    // an explicit subsequent open instead of spinning every frame.
    abandonPendingOpen();
    setLastError(QStringLiteral("Unable to open media: %1")
                     .arg(mpv_.mpvErrorDetail(result)));
    notifyRoutedFallbackOpenFailed();
    return false;
  }

  mpv_.lineage.open_attempt =
      OpenAttempt{next_open_attempt_id_, request_serial, render_stamp};
  setLastError({});

  // Do not clear mpv_.lineage.pending_source here. mpv_command_async only queues work;
  // the matching command reply is the first point where execution is known.
  if (!mpv_.core->validateRenderTicket(ticket))
    continuePendingOpen();
  return true;
}

bool PlayerController::flushRenderRecovery(std::uint64_t render_stamp) {
  if (!mpv_.lineage.render_recovery || !mpv_.lineage.committed_open || !mpv_.core || !engineReady() ||
      mpv_.lineage.render_recovery->request_serial != request_serial_ ||
      mpv_.lineage.committed_open->request_serial != request_serial_) {
    return true;
  }

  const RenderTicket ticket{render_stamp};
  if (!mpv_.core->validateRenderTicket(ticket))
    return true;

  if (mpv_.lineage.render_recovery->accepted_render_stamp == render_stamp)
    return true;
  if (mpv_.lineage.render_recovery_attempt &&
      mpv_.lineage.render_recovery_attempt->request_serial == request_serial_ &&
      mpv_.lineage.render_recovery_attempt->render_stamp == render_stamp) {
    return true;
  }
  if (mpv_.lineage.render_recovery->command_failed)
    return false;

  if (mpv_.lineage.render_recovery->mode == RenderRecoveryMode::NoReselection) {
    mpv_.lineage.render_recovery->accepted_render_stamp = render_stamp;
    mpv_.lineage.committed_open->render_stamp = render_stamp;
    restoreRenderRecovery();
    return true;
  }

  if (mpv_.lineage.render_recovery->mode == RenderRecoveryMode::VideoReselect &&
      (mpv_.lineage.render_recovery->video_track_id <= 0 ||
       mpv_.lineage.committed_open->playlist_entry_id < 0)) {
    mpv_.lineage.render_recovery->accepted_render_stamp = render_stamp;
    mpv_.lineage.committed_open->render_stamp = render_stamp;
    degradeRenderRecovery(QStringLiteral(
        "Unable to restore video output without changing media state."));
    return false;
  }

  const std::uint64_t reply_userdata = mpvReplyUserdata(
      MpvReply::RenderRecovery,
      nextMpvReplyId(MpvReply::RenderRecovery, next_render_recovery_attempt_id_));
  int result = MPV_ERROR_INVALID_PARAMETER;
  bool restarted_playlist_entry = false;
  if (mpv_.lineage.render_recovery->mode == RenderRecoveryMode::VideoReselect) {
    // The ordinary A/V path keeps the current demuxer, audio, subtitle files
    // and track selections alive. Only the exact built-in video track is
    // reselected after render-context teardown deselected the VO.
    const QByteArray track =
        QByteArray::number(mpv_.lineage.render_recovery->video_track_id);
    result =
        mpv_.sendCommand({QByteArrayLiteral("set"), QByteArrayLiteral("vid"), track},
                    reply_userdata);
  } else {
    // With video-only media, deselecting the last A/V track unloads the file
    // despite keep-open. Restart the retained playlist entry in place whenever
    // possible: unlike `loadfile replace`, this preserves redirect children
    // and the remaining sibling continuation. restoreRenderRecovery()
    // re-attaches WAM subtitles and exact selections before transport state.
    const std::int64_t playlist_position = mpv_.playlistPositionForEntry(mpv_.lineage.committed_open->playlist_entry_id);
    mpv_.lineage.render_recovery->preserve_playlist_context =
        mpv_.lineage.render_recovery->preserve_playlist_context ||
        mpv_.playlistEntryCount() > 1 || !mpv_.lineage.redirect_ranges.empty();
    if (playlist_position >= 0) {
      mpv_.lineage.render_recovery->playlist_position = playlist_position;
      const QByteArray position = QByteArray::number(playlist_position);
      result = mpv_.sendCommand({QByteArrayLiteral("playlist-play-index"), position},
                           reply_userdata);
      restarted_playlist_entry = result >= 0;
    } else if (!mpv_.lineage.render_recovery->preserve_playlist_context) {
      // A standalone entry may have been removed by video-only VO teardown.
      // Replacing that one source cannot discard a playlist continuation.
      const QByteArray source =
          sourceArgument(mpv_.lineage.render_recovery->reload_source).toUtf8();
      if (!source.isEmpty()) {
        result = mpv_.sendCommand({QByteArrayLiteral("loadfile"), source,
                              QByteArrayLiteral("replace")},
                             reply_userdata);
      }
    }
  }
  if (result < 0) {
    mpv_.lineage.render_recovery->accepted_render_stamp = render_stamp;
    mpv_.lineage.committed_open->render_stamp = render_stamp;
    degradeRenderRecovery(QStringLiteral("Unable to restore video output: %1")
                              .arg(mpv_.mpvErrorDetail(result)));
    return false;
  }

  mpv_.lineage.render_recovery_attempt =
      RenderRecoveryAttempt{next_render_recovery_attempt_id_,
                            request_serial_,
                            render_stamp,
                            mpv_.lineage.committed_open->playlist_entry_id,
                            mpv_.lineage.render_recovery->video_track_id,
                            mpv_.lineage.render_recovery->mode,
                            -1,
                            restarted_playlist_entry};
  setLastError({});

  if (!mpv_.core->validateRenderTicket(ticket))
    continuePendingOpen();
  return true;
}

void PlayerController::observeOpenCommandReply(std::uint64_t attempt_id,
                                               int error) {
  if (error >= 0 && mpv_.lineage.open_attempt &&
      mpv_.lineage.open_attempt->id == attempt_id &&
      !mpv_.lineage.open_attempt->playback_restarted) {
    // Metadata reads in handleOpenCommandReply are synchronous. Before the
    // first frame they can wait on mpv's VO while Qt needs this GUI thread to
    // dispatch rendering. Retain one reply in the existing attempt, then read
    // metadata after PLAYBACK_RESTART (also emitted for paused/audio opens).
    mpv_.lineage.open_attempt->reply_ready = true;
    return;
  }
  const bool loaded = mpv_.lineage.open_attempt && mpv_.lineage.open_attempt->file_loaded;
  const bool restarted = mpv_.lineage.open_attempt && mpv_.lineage.open_attempt->playback_restarted;
  handleOpenCommandReply(attempt_id, error);
  if (error >= 0 && !mpv_.lineage.open_attempt && restarted) {
    if (loaded) handlePlaybackReady(true);
    handlePlaybackReady(false);
  }
}

void PlayerController::handleOpenCommandReply(std::uint64_t attempt_id,
                                              int error) {
  if (!mpv_.lineage.open_attempt || mpv_.lineage.open_attempt->id != attempt_id)
    return;

  const OpenAttempt attempt = *mpv_.lineage.open_attempt;
  const bool current_request =
      attempt.request_serial == request_serial_ &&
      attempt.request_serial == mpv_.lineage.pending_request_serial &&
      !mpv_.lineage.pending_source.isEmpty();
  const bool current_renderer =
      mpv_.core && mpv_.core->validateRenderTicket({attempt.render_stamp});

  if (!current_request) {
    mpv_.lineage.open_attempt.reset();
    return;
  }

  if (!current_renderer) {
    // A later Ready notification submits this same authoritative intent in
    // the replacement generation. Old-generation replies are harmless.
    mpv_.lineage.open_attempt.reset();
    continuePendingOpen();
    return;
  }

  if (error < 0) {
    abandonPendingOpen();
    setLastError(QStringLiteral("Unable to open media: %1")
                     .arg(mpv_.mpvErrorDetail(error)));
    notifyRoutedFallbackOpenFailed();
    return;
  }

  const QUrl loaded_source = mpv_.lineage.pending_source;
  updateSource(displayUrlForSource(loaded_source));
  updateMediaTitle(fallbackTitle(loaded_source));
  OpenAttempt committed = attempt;
  const std::int64_t current_entry = mpv_.currentPlaylistEntryId();
  committed.playlist_entry_id =
      authoritativePlaylistEntry(current_entry, attempt.playlist_entry_id);
  mpv_.lineage.committed_open = committed;
  const bool live_paused = mpv_.flagProperty("pause").value_or(paused_);
  StartupPlaybackSync startup_sync;
  startup_sync.request_serial = committed.request_serial;
  startup_sync.render_stamp = committed.render_stamp;
  startup_sync.playlist_entry_id = committed.playlist_entry_id;
  startup_sync.intended_paused = live_paused;
  mpv_.lineage.startup_playback_sync = startup_sync;
  mpv_.lineage.committed_entry_source = displayUrlForSource(loaded_source);
  mpv_.lineage.committed_playlist_position =
      mpv_.playlistPositionForEntry(committed.playlist_entry_id);
  mpv_.lineage.terminal_playlist_entry_id = -1;
  mpv_.lineage.redirect_ranges.clear();
  mpv_.lineage.render_recovery_attempt.reset();
  mpv_.lineage.render_recovery.reset();
  mpv_.lineage.attached_subtitle_files.clear();
  mpv_.lineage.current_file_has_audio_track.reset();
  mpv_.lineage.selected_video_track_id = -1;
  mpv_.lineage.selected_audio_track_id = -1;
  mpv_.lineage.selected_subtitle_track_id = -1;
  mpv_.lineage.selected_tracks_playlist_entry_id = -1;
  if (mpv_.lineage.active_event_playlist_entry_id != committed.playlist_entry_id)
    mpv_.lineage.active_event_playlist_entry_id = -1;
  const std::int64_t video_track = mpv_.currentTrackId("vid");
  if (video_track > 0 && committed.playlist_entry_id >= 0) {
    mpv_.lineage.selected_video_track_id = video_track;
    mpv_.lineage.selected_tracks_playlist_entry_id = committed.playlist_entry_id;
  }
  mpv_.lineage.pending_source.clear();
  mpv_.lineage.pending_request_serial = 0;
  mpv_.lineage.open_attempt.reset();
  if (native_ && mpv_.lineage.routed_fallback_open) {
    const RoutedFallbackOpen lineage = *mpv_.lineage.routed_fallback_open;
    mpv_.lineage.routed_fallback_open.reset();
    native_->fallbackOpenSucceeded(lineage.attempt, lineage.serial,
                                            lineage.source_key);
  }
}

std::int64_t PlayerController::authoritativePlaylistEntry(
    std::int64_t live_entry, std::int64_t captured_start_entry) {
  return live_entry >= 0 ? live_entry : captured_start_entry;
}

void PlayerController::handleRenderRecoveryCommandReply(
    std::uint64_t attempt_id, int error) {
  if (!mpv_.lineage.render_recovery_attempt || mpv_.lineage.render_recovery_attempt->id != attempt_id) {
    return;
  }

  const RenderRecoveryAttempt attempt = *mpv_.lineage.render_recovery_attempt;
  const bool current_request =
      mpv_.lineage.render_recovery && mpv_.lineage.committed_open &&
      attempt.request_serial == request_serial_ &&
      mpv_.lineage.render_recovery->request_serial == request_serial_ &&
      mpv_.lineage.committed_open->request_serial == request_serial_;
  const bool current_renderer =
      mpv_.core && mpv_.core->validateRenderTicket({attempt.render_stamp});
  mpv_.lineage.render_recovery_attempt.reset();

  if (!current_request)
    return;
  if (!current_renderer) {
    continuePendingOpen();
    return;
  }
  if (error < 0) {
    mpv_.lineage.render_recovery->accepted_render_stamp = attempt.render_stamp;
    mpv_.lineage.committed_open->render_stamp = attempt.render_stamp;
    degradeRenderRecovery(QStringLiteral("Unable to restore video output: %1")
                              .arg(mpv_.mpvErrorDetail(error)));
    return;
  }

  if (attempt.mode == RenderRecoveryMode::FullReload) {
    const std::int64_t current_entry = mpv_.currentPlaylistEntryId();
    const std::int64_t reloaded_entry = authoritativePlaylistEntry(
        current_entry, attempt.started_playlist_entry_id);
    if (reloaded_entry < 0) {
      mpv_.lineage.render_recovery->accepted_render_stamp = attempt.render_stamp;
      mpv_.lineage.committed_open->render_stamp = attempt.render_stamp;
      degradeRenderRecovery(QStringLiteral(
          "Unable to identify the reloaded video playlist entry."));
      return;
    }
    mpv_.lineage.committed_open->playlist_entry_id = reloaded_entry;
    const QUrl live_source = mpv_.playlistEntrySource(reloaded_entry);
    mpv_.lineage.committed_entry_source =
        live_source.isEmpty() ? mpv_.lineage.render_recovery->reload_source : live_source;
    mpv_.lineage.committed_playlist_position =
        mpv_.playlistPositionForEntry(reloaded_entry);
    if (mpv_.lineage.committed_playlist_position < 0 && attempt.restarted_playlist_entry &&
        reloaded_entry == attempt.playlist_entry_id) {
      mpv_.lineage.committed_playlist_position = mpv_.lineage.render_recovery->playlist_position;
    }
    if (!attempt.restarted_playlist_entry)
      mpv_.lineage.redirect_ranges.clear();
    if (mpv_.lineage.active_event_playlist_entry_id != reloaded_entry)
      mpv_.lineage.active_event_playlist_entry_id = -1;
  } else if (mpv_.lineage.committed_open->playlist_entry_id < 0 ||
             attempt.playlist_entry_id != mpv_.lineage.committed_open->playlist_entry_id) {
    return;
  }

  mpv_.lineage.render_recovery->accepted_render_stamp = attempt.render_stamp;
  mpv_.lineage.committed_open->render_stamp = attempt.render_stamp;
  setLastError({});
  restoreRenderRecovery();
}

bool PlayerController::playlistEntryBelongsToCurrentLineage(
    std::int64_t playlist_entry_id) const {
  if (playlist_entry_id < 0 || !mpv_.lineage.committed_open ||
      mpv_.lineage.committed_open->request_serial != request_serial_ ||
      mpv_.lineage.committed_open->playlist_entry_id < 0) {
    return false;
  }
  if (playlist_entry_id == mpv_.lineage.committed_open->playlist_entry_id)
    return true;
  for (const PlaylistEntryRange &range : mpv_.lineage.redirect_ranges) {
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
    mpv_.lineage.active_event_playlist_entry_id = -1;
    return;
  }
  if (mpv_.lineage.render_recovery_attempt &&
      mpv_.lineage.render_recovery_attempt->request_serial == request_serial_ &&
      mpv_.lineage.render_recovery_attempt->mode == RenderRecoveryMode::FullReload) {
    mpv_.lineage.render_recovery_attempt->started_playlist_entry_id = playlist_entry_id;
    mpv_.lineage.active_event_playlist_entry_id = playlist_entry_id;
    mpv_.lineage.terminal_playlist_entry_id = -1;
    return;
  }

  if (mpv_.lineage.open_attempt && mpv_.lineage.open_attempt->request_serial == request_serial_ &&
      mpv_.lineage.open_attempt->request_serial == mpv_.lineage.pending_request_serial) {
    mpv_.lineage.open_attempt->playlist_entry_id = playlist_entry_id;
    mpv_.lineage.active_event_playlist_entry_id = playlist_entry_id;
    mpv_.lineage.terminal_playlist_entry_id = -1;
    return;
  }

  const bool initial_start_without_committed_entry =
      mpv_.lineage.startup_playback_sync && mpv_.lineage.committed_open &&
      mpv_.lineage.startup_playback_sync->request_serial == request_serial_ &&
      mpv_.lineage.committed_open->request_serial == request_serial_ &&
      mpv_.lineage.committed_open->playlist_entry_id < 0 &&
      mpv_.lineage.startup_playback_sync->playlist_entry_id < 0;
  if (!mpv_.lineage.pending_source.isEmpty() ||
      (!initial_start_without_committed_entry &&
       !playlistEntryBelongsToCurrentLineage(playlist_entry_id))) {
    mpv_.lineage.active_event_playlist_entry_id = -1;
    return;
  }

  // A redirect child becomes the concrete current entry. Retain all accepted
  // ranges so a sibling or a nested redirect child can be promoted later.
  const bool entry_changed =
      mpv_.lineage.committed_open->playlist_entry_id != playlist_entry_id;
  mpv_.lineage.committed_open->playlist_entry_id = playlist_entry_id;
  if (mpv_.lineage.startup_playback_sync &&
      mpv_.lineage.startup_playback_sync->request_serial == request_serial_) {
    mpv_.lineage.startup_playback_sync->playlist_entry_id = playlist_entry_id;
    mpv_.lineage.startup_playback_sync->completion_token = 0;
    mpv_.lineage.startup_playback_sync->retry_count = 0;
  }
  const std::int64_t live_playlist_position =
      engineReady() ? mpv_.playlistPositionForEntry(playlist_entry_id)
                    : -1;
  if (live_playlist_position >= 0 || entry_changed)
    mpv_.lineage.committed_playlist_position = live_playlist_position;
  if (entry_changed) {
    mpv_.lineage.committed_entry_source =
        engineReady() ? mpv_.playlistEntrySource(playlist_entry_id)
                      : QUrl{};
  }
  mpv_.lineage.active_event_playlist_entry_id = playlist_entry_id;
  mpv_.lineage.terminal_playlist_entry_id = -1;
  updateEof(false);
  if (!mpv_.lineage.render_recovery && mpv_.lineage.committed_open->render_stamp == 0) {
    RenderRecovery adoption;
    adoption.request_serial = request_serial_;
    adoption.mode = RenderRecoveryMode::NoReselection;
    if (mpv_.core) {
      if (const auto ready = mpv_.core->readyRenderTicket()) {
        adoption.accepted_render_stamp = ready->stamp;
        mpv_.lineage.committed_open->render_stamp = ready->stamp;
      }
    }
    mpv_.lineage.render_recovery = std::move(adoption);
  }
  if (mpv_.lineage.render_recovery && mpv_.lineage.render_recovery->request_serial == request_serial_) {
    if (mpv_.lineage.render_recovery->accepted_render_stamp != 0 && mpv_.core &&
        mpv_.core->validateRenderTicket(
            {mpv_.lineage.render_recovery->accepted_render_stamp})) {
      mpv_.lineage.committed_open->render_stamp = mpv_.lineage.render_recovery->accepted_render_stamp;
    }
    if (mpv_.lineage.render_recovery_attempt &&
        mpv_.lineage.render_recovery_attempt->request_serial == request_serial_ &&
        mpv_.lineage.render_recovery_attempt->mode == RenderRecoveryMode::VideoReselect) {
      mpv_.lineage.render_recovery_attempt->playlist_entry_id = playlist_entry_id;
    }
  }
  if (entry_changed) {
    resetTimeline();
    mpv_.lineage.observed_current_path = false;
    updateMediaTitle({});
    mpv_.lineage.selected_video_track_id = -1;
    mpv_.lineage.selected_audio_track_id = -1;
    mpv_.lineage.selected_subtitle_track_id = -1;
    mpv_.lineage.selected_tracks_playlist_entry_id = -1;
    mpv_.lineage.current_file_has_audio_track.reset();
    if (mpv_.lineage.render_recovery) {
      mpv_.lineage.render_recovery->position = 0.0;
      mpv_.lineage.render_recovery->position_overridden = false;
      mpv_.lineage.render_recovery->file_loaded = false;
      mpv_.lineage.render_recovery->playback_restarted = false;
      mpv_.lineage.render_recovery->track_snapshot_proven = false;
      mpv_.lineage.render_recovery->transport_restored = false;
      mpv_.lineage.render_recovery->completion_token = 0;
      mpv_.lineage.render_recovery->restore_retry_count = 0;
      mpv_.lineage.render_recovery->restore_retry_queued = false;
      mpv_.lineage.render_recovery->restore_failure.clear();
    }
  }
}

void PlayerController::handleEndFile(const mpv_event_end_file &end) {
  const bool startup_entry =
      mpv_.lineage.startup_playback_sync && mpv_.lineage.committed_open &&
      mpv_.lineage.startup_playback_sync->request_serial == request_serial_ &&
      mpv_.lineage.startup_playback_sync->playlist_entry_id == end.playlist_entry_id;
  const bool current_entry =
      end.playlist_entry_id >= 0 && mpv_.lineage.committed_open &&
      mpv_.lineage.committed_open->request_serial == request_serial_ &&
      mpv_.lineage.committed_open->playlist_entry_id == end.playlist_entry_id &&
      (mpv_.lineage.active_event_playlist_entry_id == end.playlist_entry_id ||
       startup_entry);
  if (!current_entry)
    return;

  invalidateScrubGesture();

  mpv_.lineage.active_event_playlist_entry_id = -1;

  const bool expected_video_only_teardown =
      end.reason == MPV_END_FILE_REASON_ERROR &&
      (mpv_.lineage.selected_tracks_playlist_entry_id !=
           mpv_.lineage.committed_open->playlist_entry_id ||
       mpv_.lineage.selected_audio_track_id <= 0) &&
      mpv_.core && !mpv_.core->validateRenderTicket({mpv_.lineage.committed_open->render_stamp});
  if (expected_video_only_teardown)
    return;

  // A video-only full reload first stops the retained old entry. That stop is
  // part of recovery, not a terminal event for the user's current request.
  if (mpv_.lineage.render_recovery_attempt &&
      mpv_.lineage.render_recovery_attempt->mode == RenderRecoveryMode::FullReload &&
      mpv_.lineage.render_recovery_attempt->playlist_entry_id == end.playlist_entry_id) {
    return;
  }

  if (end.reason == MPV_END_FILE_REASON_ERROR && mpv_.lineage.render_recovery &&
      mpv_.lineage.render_recovery->mode == RenderRecoveryMode::VideoReselect) {
    // A successful `set vid` reply is not sufficient proof that the VO lived:
    // libmpv can report success and then asynchronously unload the entry.
    // Preserve the captured per-file state and escalate this one recovery to
    // the guarded full-reload path.
    mpv_.lineage.render_recovery->mode = RenderRecoveryMode::FullReload;
    mpv_.lineage.render_recovery->accepted_render_stamp = 0;
    mpv_.lineage.render_recovery->command_failed = false;
    mpv_.lineage.render_recovery->file_loaded = false;
    mpv_.lineage.render_recovery->playback_restarted = false;
    mpv_.lineage.render_recovery->external_subtitles_restored = false;
    mpv_.lineage.render_recovery->external_subtitles_restored_count = 0;
    mpv_.lineage.render_recovery->per_file_state_restored = false;
    mpv_.lineage.render_recovery->transport_restored = false;
    mpv_.lineage.render_recovery->completion_token = 0;
    mpv_.lineage.render_recovery_attempt.reset();
    mpv_.lineage.committed_open->render_stamp = 0;
    continuePendingOpen();
    return;
  }

  if (end.reason == MPV_END_FILE_REASON_REDIRECT) {
    if (end.playlist_insert_id >= 0 && end.playlist_insert_num_entries > 0) {
      mpv_.lineage.redirect_ranges.push_back(PlaylistEntryRange{
          end.playlist_insert_id,
          static_cast<std::uint64_t>(end.playlist_insert_num_entries)});
    }
    return;
  }
  if (end.reason == MPV_END_FILE_REASON_EOF) {
    mpv_.lineage.startup_playback_sync.reset();
    if (mpv_.lineage.render_recovery) {
      // EOF terminates this entry's transport/track recovery, but not the
      // replacement render generation: a redirect sibling may start next.
      // Carry only generation adoption so the sibling establishes a fresh
      // FILE_LOADED track snapshot instead of replaying the old child.
      std::uint64_t adoption_stamp = mpv_.lineage.render_recovery->accepted_render_stamp;
      if ((!mpv_.core || !mpv_.core->validateRenderTicket({adoption_stamp})) && mpv_.core) {
        if (const auto ready = mpv_.core->readyRenderTicket())
          adoption_stamp = ready->stamp;
        else
          adoption_stamp = 0;
      }
      RenderRecovery adoption;
      adoption.request_serial = request_serial_;
      adoption.paused = paused_;
      adoption.mode = RenderRecoveryMode::NoReselection;
      adoption.accepted_render_stamp = adoption_stamp;
      mpv_.lineage.render_recovery = std::move(adoption);
      mpv_.lineage.render_recovery_attempt.reset();
      mpv_.lineage.committed_open->render_stamp = adoption_stamp;
      updateEof(true);
      if (adoption_stamp == 0)
        continuePendingOpen();
      const std::uint64_t terminal_serial = request_serial_;
      const std::int64_t terminal_entry = end.playlist_entry_id;
      QTimer::singleShot(0, this, [this, terminal_serial, terminal_entry] {
        if (!mpv_.lineage.render_recovery || request_serial_ != terminal_serial ||
            !mpv_.lineage.committed_open ||
            mpv_.lineage.committed_open->playlist_entry_id != terminal_entry ||
            mpv_.lineage.active_event_playlist_entry_id >= 0 || !eof_reached_ ||
            mpv_.lineage.render_recovery->mode != RenderRecoveryMode::NoReselection) {
          return;
        }
        const std::uint64_t adoption_stamp =
            mpv_.lineage.render_recovery->accepted_render_stamp;
        mpv_.lineage.render_recovery.reset();
        mpv_.lineage.render_recovery_attempt.reset();
        mpv_.lineage.committed_open->render_stamp = adoption_stamp;
        mpv_.lineage.terminal_playlist_entry_id = terminal_entry;
      });
      return;
    }
    mpv_.lineage.render_recovery.reset();
    mpv_.lineage.render_recovery_attempt.reset();
    mpv_.lineage.terminal_playlist_entry_id = end.playlist_entry_id;
    updateEof(true);
    return;
  }
  if (end.reason == MPV_END_FILE_REASON_ERROR) {
    mpv_.lineage.startup_playback_sync.reset();
    mpv_.lineage.render_recovery.reset();
    mpv_.lineage.render_recovery_attempt.reset();
    updatePause(true);
    updateIdle(true);
    updateEof(false);
    resetTimeline();
    updateLoading(false);
    updateSource({});
    updateMediaTitle({});
    requested_source_.clear();
    mpv_.lineage.committed_open.reset();
    mpv_.lineage.last_error_playlist_entry_id = end.playlist_entry_id;
    QString failure = QStringLiteral("Could not open this file: %1")
                          .arg(mpv_.mpvErrorDetail(end.error));
    if (native_)
      failure = native_->playbackFailureText(failure);
    setLastError(failure);
    if (native_)
      native_->fallbackPlaybackFailed();
  }
}

void PlayerController::handlePlaybackReady(bool file_loaded) {
  if (!file_loaded) updateLoading(false);
  if (mpv_.lineage.open_attempt) {
    if (file_loaded) mpv_.lineage.open_attempt->file_loaded = true;
    else mpv_.lineage.open_attempt->playback_restarted = true;
    if (file_loaded || !mpv_.lineage.open_attempt->reply_ready) return;
    const auto attempt = *mpv_.lineage.open_attempt;
    handleOpenCommandReply(attempt.id, 0);
    if (attempt.file_loaded) handlePlaybackReady(true);
  }
  if (file_loaded)
    cacheCurrentEntrySource();
  if (file_loaded && mpv_.lineage.last_error_playlist_entry_id >= 0 &&
      mpv_.lineage.active_event_playlist_entry_id >= 0 &&
      mpv_.lineage.active_event_playlist_entry_id != mpv_.lineage.last_error_playlist_entry_id) {
    mpv_.lineage.last_error_playlist_entry_id = -1;
    setLastError({});
  }
  if (mpv_.lineage.render_recovery) {
    bool matching_lineage = false;
    if (mpv_.lineage.committed_open && mpv_.lineage.committed_open->playlist_entry_id >= 0 &&
        mpv_.lineage.committed_open->playlist_entry_id == mpv_.lineage.active_event_playlist_entry_id) {
      matching_lineage = true;
    }
    if (mpv_.lineage.render_recovery_attempt &&
        mpv_.lineage.render_recovery_attempt->mode == RenderRecoveryMode::FullReload &&
        mpv_.lineage.render_recovery_attempt->started_playlist_entry_id >= 0 &&
        mpv_.lineage.render_recovery_attempt->started_playlist_entry_id ==
            mpv_.lineage.active_event_playlist_entry_id) {
      matching_lineage = true;
    }
    if (matching_lineage) {
      if (file_loaded)
        mpv_.lineage.render_recovery->file_loaded = true;
      else if (mpv_.lineage.render_recovery->accepted_render_stamp != 0 &&
               !mpv_.lineage.render_recovery_attempt && mpv_.core &&
               mpv_.core->validateRenderTicket(
                   {mpv_.lineage.render_recovery->accepted_render_stamp}))
        mpv_.lineage.render_recovery->playback_restarted = true;
    }
  } else if (mpv_.lineage.startup_playback_sync && mpv_.lineage.committed_open &&
             mpv_.lineage.startup_playback_sync->request_serial == request_serial_ &&
             mpv_.lineage.startup_playback_sync->playlist_entry_id >= 0 &&
             mpv_.lineage.startup_playback_sync->playlist_entry_id ==
                 mpv_.lineage.active_event_playlist_entry_id &&
             mpv_.lineage.committed_open->playlist_entry_id ==
                 mpv_.lineage.active_event_playlist_entry_id) {
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
    // check in applyObservedVideoFacts while mpv still has the outgoing file;
    // this is the reliable second look, and updateVideoFacts dedupes so
    // the common case where both agree costs one comparison.
    applyObservedVideoFacts();
  }
  restoreRenderRecovery();
}

bool PlayerController::acceptsPlaybackObservation() const {
  return !requested_source_.isEmpty() && mpv_.lineage.pending_source.isEmpty() &&
         mpv_.lineage.pending_request_serial == 0 && !mpv_.lineage.open_attempt && !scrub_seek_ &&
         !mpv_.lineage.render_recovery && !mpv_.lineage.startup_playback_sync && mpv_.lineage.committed_open &&
         mpv_.lineage.committed_open->request_serial == request_serial_ &&
         mpv_.lineage.committed_open->playlist_entry_id >= 0 && mpv_.core &&
         mpv_.core->validateRenderTicket({mpv_.lineage.committed_open->render_stamp}) &&
         mpv_.lineage.active_event_playlist_entry_id == mpv_.lineage.committed_open->playlist_entry_id;
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
  updatePosition(value);
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

void PlayerController::applyObservedVideoFacts() {
  if (!mpv_.core || !engineReady() || mpv_.lineage.open_attempt)
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
  const QSize size = mpv_.currentVideoDisplaySize();
  if (size.isEmpty())
    return;
  const QString gamma = mpv_.stringProperty("video-params/gamma").value_or(QString());
  const bool hdr = gamma == QLatin1String("pq") || gamma == QLatin1String("hlg");
  const auto path = mpv_.stringProperty("path");
  if (!path)
    return;
  const QUrl playing = urlFromMpvPath(*path);
  if (playing.isEmpty() || playing != source_)
    return;
  updateVideoFacts({size.width(), 1}, {size.height(), 1}, hdr);
}

void PlayerController::updateVideoFacts(media::MediaRational width,
                                        media::MediaRational height, bool hdr) {
  // A backend that cannot state a size must not erase one another backend
  // already stated. The single place a size is deliberately forgotten is
  // resetTimeline(), which assigns the member directly for exactly that
  // reason; every other caller is announcing a fact, and "I don't know" is
  // not one. This is what keeps the native route's Prepared answer alive
  // when the compatibility engine is initialized alongside it and reports
  // nothing, and vice versa.
  if (width.numerator <= 0 || height.numerator <= 0 || !width.denominator || !height.denominator)
    return;
  exact_video_display_size_ = {width, height};
  const QSizeF value(media::displayScalar(width), media::displayScalar(height));
  if (video_display_size_ == value && video_hdr_ == hdr)
    return;
  video_display_size_ = value;
  video_hdr_ = hdr;
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
  mpv_.lineage.selected_video_track_id = video_track_id >= 0 ? video_track_id : -1;
  mpv_.lineage.selected_tracks_playlist_entry_id = mpv_.lineage.committed_open->playlist_entry_id;
}

void PlayerController::applyObservedAudioTrack(std::int64_t audio_track_id) {
  if (!acceptsPlaybackObservation())
    return;
  mpv_.lineage.selected_audio_track_id = audio_track_id >= 0 ? audio_track_id : -1;
  mpv_.lineage.selected_tracks_playlist_entry_id = mpv_.lineage.committed_open->playlist_entry_id;
}

void PlayerController::applyObservedSubtitleTrack(
    std::int64_t subtitle_track_id) {
  if (!acceptsPlaybackObservation())
    return;
  mpv_.lineage.selected_subtitle_track_id = subtitle_track_id >= 0 ? subtitle_track_id : -1;
  mpv_.lineage.selected_tracks_playlist_entry_id = mpv_.lineage.committed_open->playlist_entry_id;
}

void PlayerController::cacheCurrentTrackSelection() {
  if (!mpv_.core || !engineReady() || !mpv_.lineage.committed_open ||
      mpv_.lineage.active_event_playlist_entry_id < 0 ||
      mpv_.lineage.active_event_playlist_entry_id != mpv_.lineage.committed_open->playlist_entry_id) {
    return;
  }
  mpv_.lineage.selected_video_track_id = mpv_.currentTrackSelection("vid");
  mpv_.lineage.selected_audio_track_id = mpv_.currentTrackSelection("aid");
  mpv_.lineage.selected_subtitle_track_id = mpv_.currentTrackSelection("sid");
  mpv_.lineage.selected_tracks_playlist_entry_id = mpv_.lineage.committed_open->playlist_entry_id;
  mpv_.lineage.current_file_has_audio_track = mpv_.currentFileHasTrackType("audio");
}

void PlayerController::cacheCurrentEntrySource() {
  if (!mpv_.core || !engineReady() || !mpv_.lineage.committed_open ||
      mpv_.lineage.committed_open->playlist_entry_id < 0 ||
      mpv_.lineage.committed_open->playlist_entry_id != mpv_.lineage.active_event_playlist_entry_id) {
    return;
  }
  const auto path = mpv_.stringProperty("path");
  if (!path)
    return;
  const QUrl source = urlFromMpvPath(*path);
  if (!source.isEmpty()) {
    mpv_.lineage.committed_entry_source = source;
    mpv_.lineage.committed_playlist_position = mpv_.playlistPositionForEntry(mpv_.lineage.committed_open->playlist_entry_id);
  }
}

void PlayerController::restoreRenderRecovery() {
  if (!mpv_.lineage.render_recovery || !mpv_.lineage.committed_open || !mpv_.core || !engineReady() ||
      mpv_.lineage.render_recovery->request_serial != request_serial_ ||
      mpv_.lineage.committed_open->request_serial != request_serial_ ||
      mpv_.lineage.render_recovery->accepted_render_stamp == 0 ||
      !mpv_.core->validateRenderTicket({mpv_.lineage.render_recovery->accepted_render_stamp}) ||
      mpv_.lineage.committed_open->playlist_entry_id < 0 ||
      mpv_.lineage.committed_open->playlist_entry_id != mpv_.lineage.active_event_playlist_entry_id) {
    return;
  }

  RenderRecovery &recovery = *mpv_.lineage.render_recovery;
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
        if (mpv_.commandNow(arguments.data()) < 0) {
          scheduleRenderRecoveryRetry(
              QStringLiteral("Unable to restore external subtitles."));
          return;
        }
        recovery.external_subtitles_restored_count = index + 1;
      }
      recovery.external_subtitles_restored = true;
    }

    if (!recovery.per_file_state_restored) {
      if (!mpv_.setTrackSelection("vid", recovery.video_track_id) ||
          !mpv_.setTrackSelection("aid", recovery.audio_track_id)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore selected media tracks."));
        return;
      }
      if (recovery.subtitle_track_id == 0 ||
          (recovery.subtitle_track_id > 0 &&
           recovery.external_subtitles.empty())) {
        if (!mpv_.setTrackSelection("sid",
                               recovery.subtitle_track_id)) {
          scheduleRenderRecoveryRetry(
              QStringLiteral("Unable to restore the selected subtitle."));
          return;
        }
      }
      // Pinned off: WAM draws subtitles itself on both routes, so a recovered
      // render context must not start compositing mpv's own text under ours.
      int visible = 0;
      if (!mpv_.setCoreProperty("sub-visibility", MPV_FORMAT_FLAG,
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
    const auto has_video = mpv_.currentFileHasTrackType("video");
    const auto has_audio = mpv_.currentFileHasTrackType("audio");
    const auto has_subtitle = mpv_.currentFileHasTrackType("sub");
    if (!has_video || !has_audio || !has_subtitle) {
      scheduleRenderRecoveryRetry(
          QStringLiteral("Unable to read the restored media tracks."));
      return;
    }
    std::int64_t video = mpv_.currentTrackSelection("vid");
    std::int64_t audio = mpv_.currentTrackSelection("aid");
    std::int64_t subtitle = mpv_.currentTrackSelection("sid");
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
    const std::int64_t live_entry = mpv_.playingPlaylistEntryId();
    const bool live_video =
        recovery.video_track_id <= 0 ||
        mpv_.currentTrackSelection("vid") == recovery.video_track_id;
    if (live_entry != mpv_.lineage.committed_open->playlist_entry_id ||
        mpv_.flagProperty("idle-active").value_or(true) || !live_video) {
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
      if (!mpv_.setCoreProperty("pause", MPV_FORMAT_FLAG, &paused)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore the playback state."));
        return;
      }
      recovery.transport_restored = true;
    } else if (recovery.mode == RenderRecoveryMode::VideoReselect &&
               !recovery.paused && !recovery.position_overridden) {
      const auto live_position = mpv_.doubleProperty("time-pos");
      if (!live_position || !std::isfinite(*live_position)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to sample the live playback position."));
        return;
      }
      recovery.position = std::max(0.0, *live_position);
      updatePosition(recovery.position);
      int paused = 0;
      if (!mpv_.setCoreProperty("pause", MPV_FORMAT_FLAG, &paused)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore the playback state."));
        return;
      }
      recovery.transport_restored = true;
    } else if (recovery.position > 0.01) {
      double position = recovery.position;
      if (!mpv_.setCoreProperty("time-pos", MPV_FORMAT_DOUBLE,
                           &position)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore the playback position."));
        return;
      }
      int paused = recovery.paused ? 1 : 0;
      if (!mpv_.setCoreProperty("pause", MPV_FORMAT_FLAG, &paused)) {
        scheduleRenderRecoveryRetry(
            QStringLiteral("Unable to restore the playback state."));
        return;
      }
      recovery.transport_restored = true;
    } else {
      int paused = recovery.paused ? 1 : 0;
      if (!mpv_.setCoreProperty("pause", MPV_FORMAT_FLAG, &paused)) {
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
  if (!mpv_.lineage.render_recovery || !mpv_.lineage.committed_open || !mpv_.core ||
      mpv_.lineage.render_recovery->completion_token != 0 ||
      !mpv_.lineage.render_recovery->transport_restored) {
    return;
  }

  ++next_render_recovery_completion_token_;
  if (next_render_recovery_completion_token_ == 0)
    ++next_render_recovery_completion_token_;
  const std::uint64_t completion_token = next_render_recovery_completion_token_;
  const std::uint64_t request_serial = mpv_.lineage.render_recovery->request_serial;
  const std::uint64_t render_stamp = mpv_.lineage.render_recovery->accepted_render_stamp;
  const std::int64_t playlist_entry_id = mpv_.lineage.committed_open->playlist_entry_id;
  mpv_.lineage.render_recovery->completion_token = completion_token;

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
    return mpv_.lineage.render_recovery && mpv_.lineage.committed_open && mpv_.core &&
           mpv_.lineage.render_recovery->completion_token == completion_token &&
           mpv_.lineage.render_recovery->request_serial == request_serial &&
           mpv_.lineage.render_recovery->accepted_render_stamp == render_stamp &&
           mpv_.lineage.committed_open->request_serial == request_serial &&
           mpv_.lineage.committed_open->render_stamp == render_stamp &&
           mpv_.lineage.committed_open->playlist_entry_id == playlist_entry_id &&
           mpv_.lineage.active_event_playlist_entry_id == playlist_entry_id &&
           mpv_.core->validateRenderTicket({render_stamp});
  };

  if (!completion_is_current())
    return;

  // Property events already queued by the synchronous restore writes must
  // remain gated. A later EOF, Open, Stop or renderer invalidation mutates the
  // identity checked below and wins over this completion.
  drainMpvEvents();
  if (!completion_is_current())
    return;

  mpv_.lineage.render_recovery->completion_token = 0;
  if (!mpv_.lineage.render_recovery->transport_restored) {
    restoreRenderRecovery();
    return;
  }

  const auto live_state = readLivePlaybackState();
  if (!live_state ||
      !livePlaybackStateMatchesRecovery(*mpv_.lineage.render_recovery, *live_state)) {
    scheduleRenderRecoveryRetry(
        QStringLiteral("Unable to refresh the restored playback state."));
    return;
  }

  const RenderRecovery captured = *mpv_.lineage.render_recovery;
  commitRenderRecovery(captured, *live_state);
}

std::optional<PlayerController::LivePlaybackState>
PlayerController::readLivePlaybackState() const {
  if (!mpv_.core || !engineReady())
    return std::nullopt;

  const auto paused = mpv_.flagProperty("pause");
  const auto idle = mpv_.flagProperty("idle-active");
  if (!paused || !idle)
    return std::nullopt;
  const auto nonnegative = [](std::optional<double> value) -> std::optional<double> {
    if (!value || !std::isfinite(*value))
      return std::nullopt;
    return std::max(0.0, *value);
  };
  return LivePlaybackState{*paused, *idle, mpv_.flagProperty("eof-reached"),
                           nonnegative(mpv_.doubleProperty("time-pos")),
                           nonnegative(mpv_.doubleProperty("duration"))};
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
  if (!mpv_.lineage.render_recovery || !mpv_.lineage.committed_open)
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
  mpv_.lineage.selected_video_track_id = recovery.video_track_id;
  mpv_.lineage.selected_audio_track_id = recovery.audio_track_id;
  mpv_.lineage.selected_subtitle_track_id = recovery.subtitle_track_id;
  mpv_.lineage.selected_tracks_playlist_entry_id = mpv_.lineage.committed_open->playlist_entry_id;
  mpv_.lineage.current_file_has_audio_track = recovery.file_has_audio_track;
  mpv_.lineage.render_recovery.reset();
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
  if (!mpv_.lineage.startup_playback_sync || !mpv_.lineage.committed_open || !mpv_.core ||
      mpv_.lineage.startup_playback_sync->completion_token != 0 ||
      mpv_.lineage.startup_playback_sync->request_serial != request_serial_ ||
      mpv_.lineage.startup_playback_sync->playlist_entry_id < 0 ||
      mpv_.lineage.startup_playback_sync->playlist_entry_id !=
          mpv_.lineage.active_event_playlist_entry_id) {
    return;
  }

  ++next_startup_playback_sync_token_;
  if (next_startup_playback_sync_token_ == 0)
    ++next_startup_playback_sync_token_;
  const std::uint64_t completion_token = next_startup_playback_sync_token_;
  const std::uint64_t request_serial = mpv_.lineage.startup_playback_sync->request_serial;
  const std::uint64_t render_stamp = mpv_.lineage.startup_playback_sync->render_stamp;
  const std::int64_t playlist_entry_id =
      mpv_.lineage.startup_playback_sync->playlist_entry_id;
  mpv_.lineage.startup_playback_sync->completion_token = completion_token;

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
    return mpv_.lineage.startup_playback_sync && mpv_.lineage.committed_open && mpv_.core &&
           mpv_.lineage.startup_playback_sync->completion_token == completion_token &&
           mpv_.lineage.startup_playback_sync->request_serial == request_serial &&
           mpv_.lineage.startup_playback_sync->render_stamp == render_stamp &&
           mpv_.lineage.startup_playback_sync->playlist_entry_id == playlist_entry_id &&
           mpv_.lineage.committed_open->request_serial == request_serial &&
           mpv_.lineage.committed_open->render_stamp == render_stamp &&
           mpv_.lineage.committed_open->playlist_entry_id == playlist_entry_id &&
           mpv_.lineage.active_event_playlist_entry_id == playlist_entry_id &&
           mpv_.core->validateRenderTicket({render_stamp});
  };

  if (!completion_is_current())
    return;

  // The one-shot pause/idle transitions for a new file may precede START_FILE.
  // Drain them while startup synchronization still gates observations, then
  // publish a single authoritative snapshot from the live engine.
  drainMpvEvents();
  if (!completion_is_current())
    return;

  mpv_.lineage.startup_playback_sync->completion_token = 0;
  const auto live_state = readLivePlaybackState();
  const bool live_state_matches =
      live_state &&
      livePlaybackStateMatchesStartupSync(*mpv_.lineage.startup_playback_sync, *live_state);
  if (!live_state_matches) {
    if (mpv_.lineage.startup_playback_sync->retry_count < 3) {
      constexpr std::array<int, 3> kRetryDelaysMs{0, 16, 50};
      const int retry_index = mpv_.lineage.startup_playback_sync->retry_count++;
      QTimer::singleShot(
          kRetryDelaysMs[static_cast<std::size_t>(retry_index)], this,
          [this, request_serial, render_stamp, playlist_entry_id] {
            if (!mpv_.lineage.startup_playback_sync || !mpv_.lineage.committed_open ||
                mpv_.lineage.startup_playback_sync->request_serial != request_serial ||
                mpv_.lineage.startup_playback_sync->render_stamp != render_stamp ||
                mpv_.lineage.startup_playback_sync->playlist_entry_id !=
                    playlist_entry_id ||
                mpv_.lineage.committed_open->request_serial != request_serial ||
                mpv_.lineage.committed_open->render_stamp != render_stamp ||
                mpv_.lineage.committed_open->playlist_entry_id != playlist_entry_id) {
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

    mpv_.lineage.startup_playback_sync.reset();
    setLastError(
        QStringLiteral("Unable to synchronize the initial playback state."));
    return;
  }

  commitStartupPlaybackSync(*live_state);
}

void PlayerController::reconcileStartupPlaybackSync(
    const LivePlaybackState &live_state) {
  if (!mpv_.lineage.startup_playback_sync)
    return;

  LivePlaybackState reconciled_state = live_state;
  const bool terminal =
      reconciled_state.idle || reconciled_state.eof_reached.value_or(false);
  if (!terminal)
    reconciled_state.paused = mpv_.lineage.startup_playback_sync->intended_paused;
  commitStartupPlaybackSync(reconciled_state);
}

void PlayerController::commitStartupPlaybackSync(
    const LivePlaybackState &live_state) {
  if (!mpv_.lineage.startup_playback_sync || !mpv_.lineage.committed_open)
    return;

  const StartupPlaybackSync startup_sync = *mpv_.lineage.startup_playback_sync;
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
  mpv_.lineage.startup_playback_sync.reset();
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
  if (!mpv_.lineage.render_recovery || !mpv_.core)
    return;
  mpv_.lineage.render_recovery->restore_failure = error;
  if (mpv_.lineage.render_recovery->restore_retry_queued)
    return;
  if (mpv_.lineage.render_recovery->restore_retry_count >= 3) {
    degradeRenderRecovery(error);
    return;
  }

  constexpr std::array<int, 3> kRetryDelaysMs{0, 16, 50};
  const int retry_index = mpv_.lineage.render_recovery->restore_retry_count++;
  mpv_.lineage.render_recovery->restore_retry_queued = true;
  const std::uint64_t request_serial = mpv_.lineage.render_recovery->request_serial;
  const std::uint64_t render_stamp = mpv_.lineage.render_recovery->accepted_render_stamp;
  QTimer::singleShot(kRetryDelaysMs[static_cast<std::size_t>(retry_index)],
                     this, [this, request_serial, render_stamp] {
                       if (!mpv_.lineage.render_recovery ||
                           mpv_.lineage.render_recovery->request_serial != request_serial ||
                           mpv_.lineage.render_recovery->accepted_render_stamp !=
                               render_stamp) {
                         return;
                       }
                       mpv_.lineage.render_recovery->restore_retry_queued = false;
                       restoreRenderRecovery();
                     });
}

void PlayerController::degradeRenderRecovery(const QString &error) {
  if (!mpv_.lineage.render_recovery)
    return;
  const RenderRecovery recovery = *mpv_.lineage.render_recovery;
  mpv_.lineage.render_recovery.reset();
  mpv_.lineage.render_recovery_attempt.reset();

  if (mpv_.core && engineReady()) {
    static_cast<void>(mpv_.setPausedNow(recovery.paused));
    if (const auto live = readLivePlaybackState()) {
      updatePause(live->paused);
      updateIdle(live->idle);
      if (live->position)
        updatePosition(*live->position);
    } else {
      updatePause(recovery.paused);
    }
    cacheCurrentTrackSelection();
  }
  setLastError(error);
}

void PlayerController::abandonPendingOpen() {
  requested_source_ = source_;
  mpv_.lineage.observed_current_path = !source_.isEmpty();
  mpv_.lineage.pending_source.clear();
  mpv_.lineage.pending_request_serial = 0;
  mpv_.lineage.open_attempt.reset();
  mpv_.lineage.render_recovery.reset();
  mpv_.lineage.render_recovery_attempt.reset();
  if (mpv_.lineage.committed_open && !requested_source_.isEmpty()) {
    // The previous source remains authoritative when a replacement command
    // could not be accepted. Associate it with the now-current request serial
    // so a later scene-graph loss still recovers that visible media.
    mpv_.lineage.committed_open->request_serial = request_serial_;
  } else {
    mpv_.lineage.committed_open.reset();
  }
  requestVideoUpdate();
}

void PlayerController::handleRenderInvalidated(
    std::uint64_t retired_render_stamp) {
  const std::shared_ptr<PlayerCore> notifying_core = mpv_.core;
  if (native_)
    native_->fallbackRenderStateChanged();
  if (mpv_.core != notifying_core)
    return;
  if (requested_source_.isEmpty())
    return;

  if (scrub_seek_ && mpv_.lineage.committed_open &&
      mpv_.lineage.committed_open->render_stamp == retired_render_stamp) {
    invalidateScrubGesture();
  }

  bool needs_retry = false;
  if (mpv_.lineage.open_attempt &&
      mpv_.lineage.open_attempt->request_serial == mpv_.lineage.pending_request_serial &&
      mpv_.lineage.open_attempt->render_stamp == retired_render_stamp) {
    // The command reply may still arrive, but it belongs to the retired
    // generation. Keeping the source pending lets the next Ready ticket
    // supersede it without waiting or taking the render lock.
    mpv_.lineage.open_attempt.reset();
    needs_retry = true;
  }

  const bool retired_recovery_attempt =
      mpv_.lineage.render_recovery_attempt &&
      mpv_.lineage.render_recovery_attempt->request_serial == request_serial_ &&
      mpv_.lineage.render_recovery_attempt->render_stamp == retired_render_stamp;
  const bool retired_committed_output =
      mpv_.lineage.committed_open && mpv_.lineage.committed_open->request_serial == request_serial_ &&
      mpv_.lineage.committed_open->render_stamp == retired_render_stamp;

  if (retired_recovery_attempt || retired_committed_output) {
    std::optional<bool> startup_paused_intent;
    std::optional<double> startup_position;
    bool startup_terminal_state = false;
    if (mpv_.lineage.startup_playback_sync &&
        mpv_.lineage.startup_playback_sync->request_serial == request_serial_ &&
        mpv_.lineage.startup_playback_sync->render_stamp == retired_render_stamp) {
      // Startup deliberately gates the controller's default pause/timeline
      // cache. Transfer its engine-derived/user-updated intent before render
      // recovery takes ownership, and sample a newer live position when one is
      // still available during teardown.
      const StartupPlaybackSync startup_sync = *mpv_.lineage.startup_playback_sync;
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
      mpv_.lineage.startup_playback_sync.reset();
    }

    if (!mpv_.lineage.render_recovery ||
        mpv_.lineage.render_recovery->request_serial != request_serial_) {
      const bool cached_tracks_are_current =
          mpv_.lineage.committed_open && mpv_.lineage.committed_open->playlist_entry_id >= 0 &&
          mpv_.lineage.selected_tracks_playlist_entry_id ==
              mpv_.lineage.committed_open->playlist_entry_id;
      const bool snapshot_proven = cached_tracks_are_current &&
                                   mpv_.lineage.current_file_has_audio_track.has_value();
      std::int64_t video_track =
          cached_tracks_are_current ? mpv_.lineage.selected_video_track_id : -1;
      std::int64_t audio_track =
          cached_tracks_are_current ? mpv_.lineage.selected_audio_track_id : -1;
      std::int64_t subtitle_track =
          cached_tracks_are_current ? mpv_.lineage.selected_subtitle_track_id : -1;
      if (engineReady()) {
        const std::int64_t current_video = mpv_.currentTrackId("vid");
        const std::int64_t current_audio = mpv_.currentTrackId("aid");
        const std::int64_t current_subtitle =
            mpv_.currentTrackId("sid");
        if (current_video > 0)
          video_track = current_video;
        if (current_audio > 0)
          audio_track = current_audio;
        if (current_subtitle > 0)
          subtitle_track = current_subtitle;
      }

      const bool has_audio_track =
          mpv_.lineage.current_file_has_audio_track.value_or(audio_track > 0);
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
      recovery.external_subtitles = mpv_.lineage.attached_subtitle_files;
      recovery.reload_source = mpv_.lineage.committed_entry_source;
      recovery.playlist_position = mpv_.lineage.committed_playlist_position;
      if (engineReady() && mpv_.lineage.committed_open) {
        const std::int64_t live_position = mpv_.playlistPositionForEntry(mpv_.lineage.committed_open->playlist_entry_id);
        if (live_position >= 0)
          recovery.playlist_position = live_position;
        recovery.preserve_playlist_context =
            mpv_.playlistEntryCount() > 1;
      }
      recovery.preserve_playlist_context =
          recovery.preserve_playlist_context || !mpv_.lineage.redirect_ranges.empty();
      mpv_.lineage.render_recovery = std::move(recovery);
    } else {
      mpv_.lineage.render_recovery->accepted_render_stamp = 0;
      mpv_.lineage.render_recovery->command_failed = false;
      mpv_.lineage.render_recovery->file_loaded = false;
      mpv_.lineage.render_recovery->playback_restarted = false;
      mpv_.lineage.render_recovery->external_subtitles_restored = false;
      mpv_.lineage.render_recovery->external_subtitles_restored_count = 0;
      mpv_.lineage.render_recovery->per_file_state_restored = false;
      mpv_.lineage.render_recovery->transport_restored = false;
      mpv_.lineage.render_recovery->completion_token = 0;
      mpv_.lineage.render_recovery->restore_retry_count = 0;
      mpv_.lineage.render_recovery->restore_retry_queued = false;
      mpv_.lineage.render_recovery->restore_failure.clear();
    }

    mpv_.lineage.render_recovery_attempt.reset();
    if (mpv_.lineage.committed_open)
      mpv_.lineage.committed_open->render_stamp = 0;
    needs_retry = true;
  }

  if (needs_retry)
    continuePendingOpen();
}

void PlayerController::handleRenderInitializationFailure(
    const QString &error, std::uint64_t render_stamp) {
  if (!mpv_.core || (mpv_.lineage.pending_source.isEmpty() && !mpv_.lineage.render_recovery) ||
      !mpv_.core->renderFailureIsCurrent({render_stamp}) ||
      render_stamp == mpv_.lineage.last_reported_render_failure_stamp) {
    return;
  }
  mpv_.lineage.last_reported_render_failure_stamp = render_stamp;
  const bool routed_fallback_failure = mpv_.lineage.routed_fallback_open.has_value();
  if (routed_fallback_failure)
    abandonPendingOpen();
  setLastError(error);
  if (routed_fallback_failure)
    notifyRoutedFallbackOpenFailed();
}

void PlayerController::attachVideoItem(MpvVideoItem *item) {
  video_item_ = item;
  if (native_)
    native_->attachSurface(item);
  if (needsRenderContext())
    requestVideoUpdate();
}

void PlayerController::detachVideoItem(MpvVideoItem *item) {
  invalidateNativeSeekIntents();
  if (native_)
    native_->detachSurface(item);
  if (video_item_ == item)
    video_item_.clear();
}

std::shared_ptr<PlayerCore> PlayerController::coreForRendering() const {
  return mpv_.core;
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

void PlayerController::updateLoading(bool loading) {
  if (loading_ == loading) return;
  loading_ = loading;
  emit loadingChanged();
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
  updatePosition(0.0);
  if (!nearlyEqual(duration_, 0.0)) {
    duration_ = 0.0;
    emit durationChanged();
  }
  native_seek_ceiling_ = 0.0;
  // The one place a display size is deliberately forgotten (see
  // updateVideoFacts, which refuses to publish an empty one). Every
  // media transition routes through here, so the previous file's aspect
  // cannot outlive it into the next open's window geometry.
  if (!video_display_size_.isEmpty() || video_hdr_) {
    video_display_size_ = QSizeF();
    exact_video_display_size_ = {};
    video_hdr_ = false;
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
  caption_service_->cancel();
  setCaptionStatus(QStringLiteral("Stopping caption generation…"));
}

void PlayerController::setLastError(const QString &error) {
  // A window on its way out has no user left to tell. See beginTeardown().
  if (tearing_down_)
    return;
  if (!error.isEmpty()) {
    qWarning().noquote() << "WAM:" << error;
    if (loading_) {
      updateLoading(false);
      updateSource({});
      updateMediaTitle({});
      resetTimeline();
      updatePause(true);
      updateIdle(true);
    }
  }
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
