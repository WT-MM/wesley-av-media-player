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


namespace wam::qt {
namespace {

using ::wam::playback::mpv::MpvApi;

using media::native_playback::kMaximumNativeRate;
using media::native_playback::kMinimumNativeRate;
using media::native_playback::kNativeRateGrid;

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


std::filesystem::path filesystemPath(const QString &path) {
#ifdef _WIN32
  return std::filesystem::path(path.toStdWString());
#else
  const QByteArray encoded = QFile::encodeName(path);
  return std::filesystem::path(encoded.constData());
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

} // namespace

PlayerController::PlayerController(QObject *parent)
    : QObject(parent), mpv_(this, static_cast<MpvEngineHost &>(*this)) {
#if defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  native_ = std::make_unique<NativePlaybackOwner>(
      *this, static_cast<NativeEngineHost &>(*this));
#endif
  work_timer_ = new QTimer(this);
  work_timer_->setInterval(100);
  work_timer_->setTimerType(Qt::CoarseTimer);
  connect(work_timer_, &QTimer::timeout, this,
          &PlayerController::pollBackgroundWork);

  // One reused single-shot timer for the whole scroll-gesture lifetime, for
  // the same reason as MpvEngine's scrub timeout: a momentum tail can restart
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
  if (scroll_settle_timer_)
    scroll_settle_timer_->stop();
  if (work_timer_)
    work_timer_->stop();
  export_job_.cancel();
  export_job_.wait();
  if (export_)
    ::wam::removeExportStagingFile(export_->staging);
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
    mpv_.startNewLineage();
    setLastError(mpv_.core->initializationError());
    if (was_available != available())
      emit availableChanged();
    return false;
  }

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

  mpv_.observeProperties();
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
  // A live scroll sweep belongs to the media being replaced; its settle must
  // not seek the next file to the old target.
  cancelScrollGesture();
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
      setMediaPhase(MediaOpening{source});
      updateSource(source);
      updateMediaTitle(source.fileName());
    }
    return accepted;
  }

  const QString argument = sourceArgument(source);
  if (argument.isEmpty() || !initializePlaybackEngine())
    return false;

  // A render context is generation-bound: Qt can tear it down while libmpv's
  // asynchronous loadfile command is queued. Keep the newest intent until a
  // command reply confirms that the same renderer generation is still live.
  beginMediaTransaction(source);
  mpv_.finishScrubGesture(true);
  updateEof(false);
  resetTimeline();
  return mpv_.beginOpen(source);
}

void PlayerController::prepareRoutedOpenIntent(const QUrl &source) {
  beginMediaTransaction(source);
  mpv_.finishScrubGesture(true);
  updateEof(false);
  resetTimeline();
  mpv_.startNewLineage();
}

void PlayerController::beginMediaTransaction(const QUrl &source) {
  invalidateNativeSeekIntents();
  cancelCaptionsForMediaChange(source.isEmpty() ? QUrl()
                                               : displayUrlForSource(source));
  ++request_serial_;
  if (request_serial_ == 0)
    ++request_serial_;
  requested_source_ = source;
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

  mpv_.beginRoutedOpen(source, {attempt, serial, source_key, source_class});

  // Keep router action execution non-reentrant. A pre-existing Ready render
  // ticket can submit the load on this queued GUI turn; otherwise the normal
  // render-ready notification owns submission.
  QPointer<PlayerController> self(this);
  QMetaObject::invokeMethod(
      this,
      [self] {
        if (self)
          self->mpv_.continuePendingOpen();
      },
      Qt::QueuedConnection);
  return true;
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
    if (nativeRouteActive()) {
      if (std::holds_alternative<NativeScrubbing>(native_gesture_)) {
        // A native seek converges while physically paused. Keep play/pause
        // as logical post-seek intent; the owner applies the latest value
        // only after exact CommitReady proof.
        setNativeScrubPauseIntent(false);
        updatePause(false);
        return;
      }
      if (std::holds_alternative<NativeCommitting>(native_gesture_)) {
        setNativeScrubPauseIntent(false);
        updatePause(false);
      }
    }
    const auto disposition = native_->setPaused(false);
    if (disposition == NativeEngine::PauseDisposition::NativeHandled ||
        disposition == NativeEngine::PauseDisposition::NotOwned) {
      if (disposition == NativeEngine::PauseDisposition::NativeHandled &&
          atEndForReplay(nativeFrameDuration()) && nativeCommit() == nullptr) {
        // Native Ended retains its graph. Replay is one ordinary exact seek
        // to zero; CommitReady then restores the retained playing intent.
        updatePause(false);
        seekTo(0.0);
      }
      return;
    }
  }
  if (engineReady())
    mpv_.play();
}

void PlayerController::pause() {
  if (native_) {
    if (nativeRouteActive()) {
      if (std::holds_alternative<NativeScrubbing>(native_gesture_)) {
        setNativeScrubPauseIntent(true);
        updatePause(true);
        return;
      }
      if (std::holds_alternative<NativeCommitting>(native_gesture_)) {
        setNativeScrubPauseIntent(true);
        updatePause(true);
      }
    }
    const auto disposition = native_->setPaused(true);
    if (disposition == NativeEngine::PauseDisposition::NativeHandled ||
        disposition == NativeEngine::PauseDisposition::NotOwned) {
      return;
    }
  }
  if (engineReady())
    mpv_.pause();
}

bool PlayerController::atEndForReplay(double frame_duration) const noexcept {
  return eof_reached_ ||
         (duration_ > 0.0 &&
          position_ >= duration_ - std::max(0.05, frame_duration));
}

void PlayerController::togglePlayPause() { playing() ? pause() : play(); }

void PlayerController::stop() {
  cancelScrollGesture();
  mpv_.invalidateScrubGesture();
  invalidateNativeSeekIntents();
  if (native_) {
    static_cast<void>(native_->stop());
    return;
  }
  finishStopUi(true);
}

void PlayerController::finishStopUi(bool stop_compatibility_engine) {
  if (loading())
    setMediaPhase(MediaLoaded{});
  beginMediaTransaction({});
  mpv_.startNewLineage();
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
  // that lands in the last frame is NativeMediaSession's concern (its commit
  // handshake state), not seek arithmetic, so no wider guard is needed.
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
  if (std::holds_alternative<NativeScrubbing>(native_gesture_))
    return true;
  const auto gesture = reserveNativeSeekIdentity(next_native_seek_gesture_id_);
  if (!gesture)
    return false;
  const NativeScrubIntent scrub{*gesture, position_, position_, 0, {}, true};
  if (auto *committing = std::get_if<NativeCommitting>(&native_gesture_)) {
    const NativeSeekIntent converging = committing->commit;
    native_gesture_ =
        NativeScrubbing{scrub, converging, converging.intended_paused};
  } else {
    native_gesture_ = NativeScrubbing{scrub, std::nullopt, paused_};
  }
  return true;
}

PlayerController::NativeScrubIntent *PlayerController::nativeScrub() noexcept {
  auto *scrubbing = std::get_if<NativeScrubbing>(&native_gesture_);
  return scrubbing != nullptr ? &scrubbing->scrub : nullptr;
}

const PlayerController::NativeSeekIntent *
PlayerController::nativeCommit() const noexcept {
  if (const auto *committing = std::get_if<NativeCommitting>(&native_gesture_))
    return &committing->commit;
  if (const auto *scrubbing = std::get_if<NativeScrubbing>(&native_gesture_))
    return scrubbing->converging ? &*scrubbing->converging : nullptr;
  return nullptr;
}

bool PlayerController::nativeIntendedPaused() const noexcept {
  if (const auto *scrubbing = std::get_if<NativeScrubbing>(&native_gesture_))
    return scrubbing->intended_paused;
  if (const auto *committing = std::get_if<NativeCommitting>(&native_gesture_))
    return committing->commit.intended_paused;
  return paused_;
}

void PlayerController::adoptNativeCommit(const NativeSeekIntent &intent) {
  if (auto *scrubbing = std::get_if<NativeScrubbing>(&native_gesture_)) {
    scrubbing->converging = intent;
    return;
  }
  native_gesture_ = NativeCommitting{intent};
}

bool PlayerController::retireNativeCommit(std::uint64_t gesture,
                                          std::uint64_t request,
                                          const double *target) noexcept {
  const NativeSeekIntent *commit = nativeCommit();
  if (commit == nullptr || commit->gesture != gesture ||
      commit->request != request ||
      (target != nullptr && commit->target != *target)) {
    return false;
  }
  if (auto *scrubbing = std::get_if<NativeScrubbing>(&native_gesture_))
    scrubbing->converging.reset();
  else
    native_gesture_ = NativeGestureIdle{};
  return true;
}

bool PlayerController::ownsNativePreview(std::uint64_t gesture,
                                         std::uint64_t request) noexcept {
  const NativeScrubIntent *scrub = nativeScrub();
  return scrub != nullptr && request != 0 && scrub->gesture == gesture &&
         scrub->in_flight_preview == request;
}

std::optional<PlayerController::NativePreviewIntent>
PlayerController::makeNativePreviewIntent(double seconds) {
  const NativeScrubIntent *scrub = nativeScrub();
  if (scrub == nullptr || !std::isfinite(seconds))
    return std::nullopt;
  const std::uint64_t gesture = scrub->gesture;
  const auto request = reserveNativeSeekIdentity(next_native_seek_request_id_);
  if (!request)
    return std::nullopt;
  return NativePreviewIntent{gesture, *request,
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
  NativeScrubIntent *scrub = nativeScrub();
  if (scrub == nullptr || scrub->gesture != intent.gesture ||
      intent.request == 0 || !std::isfinite(intent.target)) {
    return;
  }

  // Stage both the visible desire and, when idle, its in-flight ownership
  // before publishing the optimistic target. positionChanged handlers may
  // synchronously request another preview; that movement must coalesce behind
  // this exact request instead of recursively issuing another media command.
  scrub->latest_preview_request = intent.request;
  scrub->target = intent.target;
  const bool ownsDispatch = !scrub->in_flight_preview;
  if (ownsDispatch)
    scrub->in_flight_preview = intent.request;
  updatePosition(intent.target);

  // Publishing the optimistic handle is a synchronous Qt boundary. A signal
  // handler may Stop, Commit, or replace the entire gesture before returning;
  // never submit media work for an identity that no longer owns the slot.
  if (!ownsNativePreview(intent.gesture, intent.request) || !ownsDispatch)
    return;

  if (submitter == nullptr) {
    nativeScrub()->in_flight_preview.reset();
    return;
  }

  const NativePreviewSubmission submission = submitter(context, intent);
  // The owner may synchronously drain a terminal observation while accepting
  // this command. Such a completion has already released or replaced the
  // slot; never recreate its ownership after returning from client code.
  if (!ownsNativePreview(intent.gesture, intent.request))
    return;

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
  releaseNativePreviewSlot(intent.request, context, submitter);
}

void PlayerController::releaseNativePreviewSlot(
    std::uint64_t request, void *context, NativePreviewSubmitter submitter) {
  NativeScrubIntent &scrub = *nativeScrub();
  scrub.in_flight_preview.reset();
  if (scrub.latest_preview_request == request)
    return;
  const NativePreviewIntent latest{scrub.gesture, scrub.latest_preview_request,
                                   scrub.target};
  dispatchNativePreviewIntent(latest, context, submitter);
}

std::optional<PlayerController::NativeSeekIntent>
PlayerController::finishNativeScrubIntent(double seconds) {
  auto *scrubbing = std::get_if<NativeScrubbing>(&native_gesture_);
  if (scrubbing == nullptr)
    return std::nullopt;
  const NativeScrubIntent scrub = scrubbing->scrub;
  const bool intended_paused = scrubbing->intended_paused;
  invalidateNativeScrubIntent();
  if (!std::isfinite(seconds))
    return std::nullopt;
  const auto request = reserveNativeSeekIdentity(next_native_seek_request_id_);
  if (!request)
    return std::nullopt;
  return NativeSeekIntent{scrub.gesture, *request,
                          exactNativeSeekTarget(seconds), scrub.origin,
                          intended_paused};
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
  return NativeSeekIntent{*gesture, *request, exactNativeSeekTarget(seconds),
                          position_, nativeIntendedPaused()};
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
      adoptNativeCommit(intent);
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

PlayerController::NativeSeekSubmission
PlayerController::submitNativeCommit(void *context,
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
}

PlayerController::NativeSeekDispatch
PlayerController::dispatchNativeSeekIntent(const NativeSeekIntent &intent) {
  return dispatchNativeSeekIntent(intent, native_.get(), &submitNativeCommit);
}

void PlayerController::nativeCommitReady(
    const ::wam::media::native_playback::CommitReady &ready) {
  if (!acceptNativeCommitReady(ready.gesture.value, ready.request.value,
                               ready.targetSeconds)) {
    return;
  }
  std::optional<PendingFrameStep> step;
  if (pending_frame_step_ &&
      pending_frame_step_->gesture == ready.gesture.value &&
      pending_frame_step_->request == ready.request.value) {
    step.swap(pending_frame_step_);
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
  // A settling commit for a frame step has landed and proved the covering
  // frame; spend the remembered direction now. Deferred, not immediate: this
  // runs inside the owner's observation drain, and dispatching the next
  // commit from underneath it would re-enter the session command path
  // mid-drain. Zero-delay queued is the same idiom the rest of this class
  // uses for exactly that reason.
  if (step && std::holds_alternative<NativeFrame>(native_frame_)) {
    const int direction = step->direction;
    QTimer::singleShot(0, this, [this, direction] { stepFrame(direction); });
  }
}

bool PlayerController::completeNativePreviewPresented(
    std::uint64_t gesture, std::uint64_t request,
    double actual_presentation_time, void *context,
    NativePreviewSubmitter submitter) {
  if (!ownsNativePreview(gesture, request) ||
      !std::isfinite(actual_presentation_time)) {
    return false;
  }
  // The frame really reached the screen and therefore completes the admitted
  // work. When a newer pointer target owns the handle, do not visually regress
  // it to this older PTS; the release spends the newly free slot on the
  // single latest desired request instead.
  if (nativeScrub()->latest_preview_request == request)
    updatePosition(boundedSeekTarget(actual_presentation_time));
  releaseNativePreviewSlot(request, context, submitter);
  return true;
}

bool PlayerController::completeNativePreviewFailed(
    std::uint64_t gesture, std::uint64_t request, void *context,
    NativePreviewSubmitter submitter) {
  if (!ownsNativePreview(gesture, request))
    return false;
  // Failure retires only the exact admitted work. The newest pointer target
  // still owns the visible handle and gets the newly free slot once; no stale
  // PTS or rollback is published at this boundary.
  releaseNativePreviewSlot(request, context, submitter);
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
  return retireNativeCommit(gesture, request, &target);
}

void PlayerController::nativeCommitFailed(std::uint64_t gesture,
                                          std::uint64_t request) noexcept {
  if (pending_frame_step_ && pending_frame_step_->gesture == gesture &&
      pending_frame_step_->request == request) {
    pending_frame_step_.reset();
  }
  for (NativeSeekSubmissionState *submission = native_seek_submission_;
       submission != nullptr; submission = submission->previous) {
    if (submission->gesture == gesture && submission->request == request) {
      submission->terminal = NativeSeekTerminal::Failed;
      return;
    }
  }
  static_cast<void>(retireNativeCommit(gesture, request, nullptr));
}

void PlayerController::setNativeScrubPauseIntent(bool paused) {
  if (auto *scrubbing = std::get_if<NativeScrubbing>(&native_gesture_))
    scrubbing->intended_paused = paused;
  else if (auto *committing = std::get_if<NativeCommitting>(&native_gesture_))
    committing->commit.intended_paused = paused;
}

void PlayerController::invalidateNativeScrubIntent() noexcept {
  auto *scrubbing = std::get_if<NativeScrubbing>(&native_gesture_);
  if (scrubbing == nullptr)
    return;
  if (!scrubbing->converging) {
    native_gesture_ = NativeGestureIdle{};
    return;
  }
  NativeSeekIntent converging = *scrubbing->converging;
  converging.intended_paused = scrubbing->intended_paused;
  native_gesture_ = NativeCommitting{converging};
}

void PlayerController::invalidateNativeSeekIntents() noexcept {
  native_gesture_ = NativeGestureIdle{};
  // Frame geometry belongs to one generation's picture. Carrying it across a
  // stop or a new open would let the first "." step relative to the previous
  // file's last frame.
  native_frame_ = NativeFrameUnknown{};
  pending_frame_step_.reset();
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
  if (subtitles_ && !(subtitle_list_built_ &&
                       subtitle_list_built_->source == source_ &&
                       subtitle_list_built_->native)) {
    refreshSubtitleSources();
  }
  // During a pointer gesture the optimistic target and its exact preview
  // presentation own the visible playhead. Main audio/draw proofs still
  // advance their owner-side high-water marks, but cannot repaint an older
  // transport position over the user's latest target.
  if (std::holds_alternative<NativeScrubbing>(native_gesture_))
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
  emit seekRequested();
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
      if (NativeScrubIntent *scrub = nativeScrub()) {
        scrub->preview_available =
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
  mpv_.beginScrub(position_);
}

void PlayerController::seekTo(double seconds) {
  emit seekRequested();
  if (nativeRouteActive()) {
    // Native accurate seek requires an exactly representable rational target;
    // exactNativeSeekTarget owns that rule for every native entry point, and
    // the intent factories below apply it. Applying it here too keeps the
    // value handed to endScrub identical to the one a direct seek would use.
    if (!std::isfinite(seconds))
      return;
    seconds = exactNativeSeekTarget(seconds);
    if (std::holds_alternative<NativeScrubbing>(native_gesture_)) {
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
  if (mpv_.scrubbing()) {
    endScrub(seconds);
    return;
  }
  mpv_.seek(boundedSeekTarget(seconds));
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
    if (NativeScrubIntent *scrub = nativeScrub();
        scrub != nullptr && !scrub->preview_available) {
      if (!std::isfinite(seconds))
        return;
      const double target = exactNativeSeekTarget(seconds);
      scrub->target = target;
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
  mpv_.previewScrub(boundedSeekTarget(seconds));
}

void PlayerController::endScrub(double seconds) {
  emit seekRequested();
  if (nativeRouteActive()) {
    std::optional<NativeSeekIntent> intent;
    if (std::holds_alternative<NativeScrubbing>(native_gesture_)) {
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
  const bool valid = std::isfinite(seconds);
  if (!mpv_.endScrub(valid ? boundedSeekTarget(seconds) : 0.0, valid))
    seekTo(seconds);
}

void PlayerController::seekRelative(double seconds) {
  emit seekRequested();
  if (nativeRouteActive()) {
    if (std::isfinite(seconds))
      seekTo(position_ + seconds);
    return;
  }
  if (!engineReady() || !std::isfinite(seconds))
    return;
  if (mpv_.scrubbing() || mpv_.recovering() || position_ + seconds < 0.0 ||
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
  emit seekRequested();
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
    stepNativeFrame(forward, native_.get(), &submitNativeCommit);
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

void PlayerController::stepNativeFrame(bool forward, void *context,
                                       NativeSeekSubmitter submitter) {
  // An audio-only generation proves no frame geometry and has nothing to
  // step; say so rather than seeking by a made-up interval.
  if (std::holds_alternative<NativeAudioOnly>(native_frame_))
    return;

  const NativeFrame *frame = std::get_if<NativeFrame>(&native_frame_);
  if (frame == nullptr || position_ < frame->start ||
      position_ - frame->start >= frame->duration) {
    // No proof yet for the frame actually on screen (nothing has been drawn
    // since the last open, or the position moved by a route the draw proof
    // did not narrate). Spend this press on one settling commit at the
    // current position -- which by definition lands on, and proves, the
    // covering frame -- and remember the direction for that commit's Ready.
    auto intent = makeNativeExactSeekIntent(frameStepSeekTarget(position_, false));
    if (!intent)
      return;
    pending_frame_step_ =
        PendingFrameStep{intent->gesture, intent->request, forward ? 1 : -1};
    static_cast<void>(dispatchNativeSeekIntent(*intent, context, submitter));
    // Only a commit that is still converging keeps the step: a refusal, a
    // failure or a compatibility hand-off has nothing left to land.
    const NativeSeekIntent *live = nativeCommit();
    if (live == nullptr || live->gesture != intent->gesture ||
        live->request != intent->request) {
      pending_frame_step_.reset();
    }
    return;
  }

  // The exact neighbour, from this frame's own duration -- never a nominal
  // frame interval, so a variable-frame-rate source steps onto its real
  // sample times.
  double raw = 0.0;
  if (forward) {
    raw = frame->start + frame->duration;
    if (duration_ > 0.0 && raw >= duration_)
      return; // Already on the last frame.
  } else {
    if (frame->start <= 0.0)
      return; // Already on the first frame.
    raw = frame->start;
  }
  // Forward rounds UP so the target reaches the next frame's interval;
  // backward rounds DOWN so it falls strictly short of this frame's start
  // and therefore inside the previous frame's interval.
  const double target = frameStepSeekTarget(raw, forward);
  if (!forward && !(target < frame->start))
    return;
  pending_frame_step_.reset();
  if (auto intent = makeNativeExactSeekIntent(target))
    static_cast<void>(dispatchNativeSeekIntent(*intent, context, submitter));
}

double PlayerController::nativeFrameDuration() const noexcept {
  const auto *frame = std::get_if<NativeFrame>(&native_frame_);
  return frame != nullptr ? frame->duration : 0.0;
}

void PlayerController::publishNativeFrameGeometry(double start_seconds,
                                                  double duration_seconds) {
  if (!std::isfinite(start_seconds) || !std::isfinite(duration_seconds))
    return;
  if (duration_seconds > 0.0)
    native_frame_ = NativeFrame{std::max(0.0, start_seconds), duration_seconds};
  else
    native_frame_ = NativeAudioOnly{};
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
  if (std::holds_alternative<ScrollIdle>(scroll_))
    setScrollState(ScrollActive{});

  if (step.axis == ScrollAxis::Vertical) {
    // A vertical gesture commits any sweep the previous gesture left open,
    // rather than interleaving a volume change into a live scrub.
    commitScrollSweep();
    if (step.volumeDelta == 0.0)
      return ScrollGestureVolume;
    setVolume(scroll_model_.volumeWithDetent(volume_, step.volumeDelta,
                                             maximum_volume_));
    return ScrollGestureVolume;
  }

  if (step.seekSeconds == 0.0)
    return ScrollGestureSeek;

  auto *sweep = std::get_if<ScrollSweep>(&scroll_);
  if (sweep == nullptr) {
    // Open exactly one scrub gesture for the whole sweep. beginScrub is the
    // same entry point the timeline's pointer drag uses, so the sweep gets
    // the native preview handoff, the captured logical pause intent and the
    // depth-1 latest-wins preview coalescing for free -- and previews are
    // never queued behind one another.
    beginScrub();
    scroll_ = ScrollSweep{position_};
    sweep = &std::get<ScrollSweep>(scroll_);
  }
  const double maximum = duration_ > 0.0 ? duration_ : sweep->target;
  sweep->target = std::clamp(sweep->target + step.seekSeconds, 0.0,
                             std::max(0.0, maximum));
  previewSeekTo(sweep->target);
  return ScrollGestureSeek;
}

void PlayerController::commitScrollSweep() {
  const auto *sweep = std::get_if<ScrollSweep>(&scroll_);
  if (sweep == nullptr)
    return;
  const double target = sweep->target;
  scroll_ = ScrollActive{};
  endScrub(target);
}

void PlayerController::settleScrollGesture() {
  if (scroll_settle_timer_)
    scroll_settle_timer_->stop();
  scroll_model_.reset();
  commitScrollSweep();
  setScrollState(ScrollIdle{});
}

void PlayerController::cancelScrollGesture() {
  if (scroll_settle_timer_)
    scroll_settle_timer_->stop();
  scroll_model_.reset();
  setScrollState(ScrollIdle{});
}

void PlayerController::setScrollState(
    std::variant<ScrollIdle, ScrollActive, ScrollSweep> state) {
  const bool was_active = scrollGestureActive();
  scroll_ = state;
  if (was_active != scrollGestureActive())
    emit scrollGestureActiveChanged();
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
  subtitle_list_built_.reset();
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
      // the caption outputs specifically, NOT on the engine's attached files:
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
  if (mpv_.opening()) return; // refreshed after first-frame startup completion
  if (!subtitles_ || source_.isEmpty())
    return;
  const bool native = nativeRouteActive();
  const bool same_media =
      subtitle_list_built_ && subtitle_list_built_->source == source_;
  const bool rebuild_only = same_media && subtitle_list_built_->native == native;

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

  subtitle_list_built_ = SubtitleListStamp{source_, native};
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
    mpv_.selectSubtitleTrack(source->mpvSid);
    publishSubtitleText({});
  } else {
    // Native route: this process reads the cues, off the playback graph.
    publishSubtitleText({});
    subtitles_->beginNativeLoad(id);
  }

  if (id == SubtitleSources::kOffId && engineReady()) {
    mpv_.selectSubtitleTrack(0);
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
    showError(QStringLiteral("Only local subtitle files can be loaded."));
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
    if (!mpv_.attachSubtitleFile(path))
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
    showError(QStringLiteral("That subtitle file could not be added."));
    return false;
  }
  emit subtitleTracksChanged();
  QString error;
  if (!subtitles_->loadFileCues(path, &error)) {
    showError(error);
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
    showError(QStringLiteral("Open media before exporting a selection."));
    return;
  }
  if (captioning()) {
    showError(QStringLiteral(
        "Wait for caption generation to finish before exporting."));
    return;
  }
  if (exporting())
    return;
  emit exportSelectionRequested(trim_in_, trim_out_);
}

void PlayerController::exportSelectionTo(const QUrl &destination) {
  if (destination.isEmpty())
    return;
  if (!hasMedia()) {
    showError(QStringLiteral("Open media before exporting a selection."));
    return;
  }
  if (captioning()) {
    showError(QStringLiteral(
        "Wait for caption generation to finish before exporting."));
    return;
  }
  if (exporting())
    return;

  const auto input = localPath(source_);
  auto output = localPath(destination);
  if (!input) {
    showError(QStringLiteral(
        "Save network media locally before exporting an edited copy."));
    return;
  }
  if (!output) {
    showError(QStringLiteral("Choose a local file for the video export."));
    return;
  }
  // The preset decides the container, so it decides the extension -- both for
  // an extensionless choice and for one the dialog's own default suffix
  // already supplied.
  if (output->extension().empty())
    *output += ::wam::exportFormatExtension(export_format_);

  std::error_code path_error;
  if (!std::filesystem::is_regular_file(*input, path_error)) {
    showError(QStringLiteral(
        "The source media is no longer available as a readable local file."));
    return;
  }
  if (pathsReferToSameFile(*input, *output)) {
    showError(QStringLiteral("Choose a different filename so the original "
                                "media is not overwritten."));
    return;
  }
  const QFileInfo output_info(displayPath(*output));
  if (!QDir(output_info.absolutePath()).exists()) {
    showError(QStringLiteral("The selected export folder does not exist."));
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
    showError(fromUtf8(::wam::toolSearchFailure(ffmpeg_search)));
    return;
  }

  std::string staging_error;
  auto staging = ::wam::reserveExportStagingFile(*output, &staging_error);
  if (staging.empty()) {
    showError(
        staging_error.empty()
            ? QStringLiteral("Could not reserve a safe temporary export file.")
            : QStringLiteral("Could not prepare the export: %1")
                  .arg(fromUtf8(staging_error)));
    return;
  }
  options.output = staging;

  try {
    export_job_.reset();
    const bool started = export_job_.start(
        "Video export", ::wam::buildExportProcess(ffmpeg, options));
    if (!started) {
      ::wam::removeExportStagingFile(staging);
      showError(QStringLiteral("Another video export is already running."));
      return;
    }
  } catch (const std::exception &exception) {
    ::wam::removeExportStagingFile(staging);
    showError(QStringLiteral("Could not start the video export: %1")
                     .arg(QString::fromUtf8(exception.what())));
    return;
  }

  showError({});
  setExportStatus(QStringLiteral("Exporting in the background…"));
  beginExportJob(*output, std::move(staging));
  startWorkPolling();
}

void PlayerController::cancelExport() {
  if (!export_)
    return;
  export_->cancel_requested = true;
  export_job_.cancel();
  setExportStatus(QStringLiteral("Cancelling export…"));
}

void PlayerController::generateCaptions() {
  if (!hasMedia()) {
    showError(
        QStringLiteral("Open local media before generating captions."));
    return;
  }
  if (exporting()) {
    showError(QStringLiteral(
        "Wait for the video export to finish before captioning."));
    return;
  }
  if (captioning()) {
    showError(QStringLiteral("Another caption task is already running."));
    return;
  }
  emit generateCaptionsRequested();
}

void PlayerController::generateCaptionsTo(const QUrl &destination) {
  if (destination.isEmpty())
    return;
  if (!hasMedia()) {
    showError(
        QStringLiteral("Open local media before generating captions."));
    return;
  }
  if (exporting()) {
    showError(QStringLiteral(
        "Wait for the video export to finish before captioning."));
    return;
  }
  if (captioning()) {
    showError(QStringLiteral("Another caption task is already running."));
    return;
  }

  const auto input = localPath(source_);
  const auto output = localPath(destination);
  if (!input) {
    showError(QStringLiteral(
        "Save network media locally before generating captions."));
    return;
  }
  if (!output) {
    showError(QStringLiteral("Choose a local file for the captions."));
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
    if (!bridge->selected) {
      bridge->selected = true;
      selectSubtitleTrack(id);
    }
    bridge->committed = snapshot->committed;
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
    showError(
        error.isEmpty()
            ? QStringLiteral("Another caption task is already running.")
            : error);
    return;
  }

  showError({});
  setCaptionStatus(QStringLiteral("Preparing on-device captions…"));
  beginCaptionJob(*input);
  startWorkPolling();
}

void PlayerController::cancelCaptioning() {
  if (!caption_job_)
    return;
  caption_job_->cancel_reason = QStringLiteral("Caption generation cancelled.");
  caption_service_->cancel();
  setCaptionStatus(QStringLiteral("Cancelling caption generation…"));
}

void PlayerController::beginExportJob(std::filesystem::path output,
                                      std::filesystem::path staging) {
  export_ = ExportJob{std::move(output), std::move(staging)};
  emit exportingChanged();
}

void PlayerController::endExportJob() noexcept {
  if (!export_)
    return;
  ::wam::removeExportStagingFile(export_->staging);
  export_.reset();
  emit exportingChanged();
}

void PlayerController::beginCaptionJob(std::filesystem::path input) {
  caption_job_ = CaptionJob{std::move(input)};
  emit captioningChanged();
}

void PlayerController::endCaptionJob() {
  caption_job_.reset();
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

void PlayerController::startWorkPolling() {
  if (work_timer_ && !work_timer_->isActive())
    work_timer_->start();
}

void PlayerController::pollBackgroundWork() {
  if (export_ && export_job_.finished()) {
    const bool succeeded = export_job_.succeeded();
    const int exit_code = export_job_.exitCode();
    export_job_.wait();
    export_job_.reset();
    ExportJob job = *export_;
    if (job.cancel_requested) {
      endExportJob();
      setExportStatus(QStringLiteral("Export cancelled."));
    } else if (succeeded) {
      std::string commit_error;
      if (::wam::commitExportStagingFile(job.staging, job.output,
                                         &commit_error)) {
        // Committed: the staging name no longer exists to remove.
        export_->staging.clear();
        endExportJob();
        const QString filename =
            QFileInfo(displayPath(job.output)).fileName();
        setExportStatus(filename.isEmpty()
                            ? QStringLiteral("Export complete.")
                            : QStringLiteral("Saved %1").arg(filename));
        showError({});
      } else {
        endExportJob();
        setExportStatus(QStringLiteral("Export failed."));
        showError(
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
      endExportJob();
      setExportStatus(QStringLiteral("Export failed."));
      showError(
          QStringLiteral(
              "Video export failed (media tool exit code %1). Check that the "
              "destination is writable and the source contains playable media.")
              .arg(exit_code));
    }
  }

  if (caption_job_) {
    const auto snapshot = caption_service_->tryStatus();
    if (!snapshot) return;
    const ::wam::CaptionStatus& status = *snapshot;
    if (status.needsDownloadConsent() && !caption_job_->download_prompted) {
      caption_job_->download_prompted = true;
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

    if (status.finished()) {
      const CaptionJob job = *caption_job_;
      endCaptionJob();
      if (status.succeeded()) {
        const auto current_input = localPath(source_);
        if (!current_input || job.input.empty() ||
            !pathsReferToSameFile(job.input, *current_input)) {
          setCaptionStatus(QStringLiteral(
              "Captions saved, but not attached because the media changed."));
        } else {
          setCaptionStatus(QStringLiteral("Captions generated and enabled."));
          showError({});
        }
      } else if (status.cancelled()) {
        setCaptionStatus(job.cancel_reason.isEmpty()
                             ? QStringLiteral("Caption generation cancelled.")
                             : job.cancel_reason);
      } else {
        const QString error = fromUtf8(status.error);
        setCaptionStatus(QStringLiteral("Caption generation failed."));
        showError(error.isEmpty()
                         ? QStringLiteral("Caption generation failed.")
                         : error);
      }
      if (!status.succeeded()) {
        caption_live_bridge_.reset();
        if (subtitles_ && subtitles_->activeIsGenerated()) selectSubtitleTrack(SubtitleSources::kOffId);
      }
    }
  }

  if (!export_ && !caption_job_ && work_timer_) {
    work_timer_->stop();
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

MpvTransportChange
PlayerController::assignTransport(const MpvTransport &transport) {
  const MpvTransportChange change{paused_ != transport.paused,
                                  !nearlyEqual(position_, transport.position),
                                  playing()};
  paused_ = transport.paused;
  idle_ = transport.idle;
  eof_reached_ = transport.eof_reached;
  position_ = transport.position;
  return change;
}

void PlayerController::publishTransport(const MpvTransportChange &change) {
  if (change.paused_changed)
    emit pausedChanged();
  if (change.position_changed)
    emit positionChanged();
  if (change.was_playing != playing())
    emit playingChanged();
}

void PlayerController::applyObservedVolume(double volume) {
  const double value = std::clamp(volume, kMinimumVolume, maximum_volume_);
  if (!nearlyEqual(volume_, value)) {
    volume_ = value;
    emit volumeChanged();
  }
}

void PlayerController::applyObservedMute(bool muted) {
  if (muted_ != muted) {
    muted_ = muted;
    emit mutedChanged();
  }
}

void PlayerController::applyObservedRate(double rate) {
  if (!nearlyEqual(rate_, rate)) {
    rate_ = rate;
    emit rateChanged();
  }
}

void PlayerController::applyObservedSubtitleText(const QString &text) {
  // The compatibility route's feed into the shared overlay. mpv reports the
  // line with its own markup already resolved, so nothing here has to
  // re-parse ASS or SRT: that work only exists on the native route.
  if (subtitles_ && subtitles_->activeIsGenerated())
    return;
  if (subtitles_ && subtitles_->activeId() != SubtitleSources::kOffId)
    publishSubtitleText(text);
  else
    publishSubtitleText({});
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
  // Only the end of an open is reported; the start is open() itself.
  if (!loading && this->loading())
    setMediaPhase(MediaLoaded{});
}

void PlayerController::setMediaPhase(MediaPhase phase) {
  const bool was_loading = loading();
  media_phase_ = std::move(phase);
  if (was_loading != loading())
    emit loadingChanged();
}

bool PlayerController::claimableFor(const QUrl &source) const {
  if (std::holds_alternative<MediaEmpty>(media_phase_))
    return true;
  if (const auto *opening = std::get_if<MediaOpening>(&media_phase_))
    return opening->requested == source;
  return false;
}

void PlayerController::updateSource(const QUrl &source) {
  cancelCaptionsForMediaChange(source);

  const bool had_media = hasMedia();
  if (source_ == source)
    return;
  source_ = source;
  if (source_.isEmpty())
    setMediaPhase(MediaEmpty{});
  else if (std::holds_alternative<MediaEmpty>(media_phase_))
    setMediaPhase(MediaLoaded{});
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

void PlayerController::cancelCaptionsForMediaChange(const QUrl &incoming) {
  if (!caption_job_)
    return;
  const auto path = localPath(incoming);
  if (path && !caption_job_->input.empty() &&
      pathsReferToSameFile(caption_job_->input, *path))
    return;
  caption_job_->cancel_reason =
      QStringLiteral("Caption generation stopped because the media changed.");
  caption_service_->cancel();
  setCaptionStatus(QStringLiteral("Stopping caption generation…"));
}

void PlayerController::setLastError(const QString &error) {
  // A window on its way out has no user left to tell. See beginTeardown().
  if (tearing_down_)
    return;
  if (!error.isEmpty() && loading()) {
    failOpen(error);
    return;
  }
  showError(error);
}

void PlayerController::failOpen(const QString &error) {
  if (tearing_down_)
    return;
  updateSource({});
  updateMediaTitle({});
  resetTimeline();
  updatePause(true);
  updateIdle(true);
  showError(error);
}

void PlayerController::showError(const QString &error) {
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
