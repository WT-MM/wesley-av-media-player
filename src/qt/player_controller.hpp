#pragma once

#include "caption_service.hpp"
#include "media/subtitle_text.hpp"
#include "media/native_display_geometry.hpp"
#include "jobs.hpp"
#include "mpv_engine.hpp"
#include "native_engine.hpp"
#include "media/live_caption_feed.hpp"
#include "playback_policy.hpp"
#include "scroll_gesture.hpp"

#include <QObject>
#include <QPointer>
#include <QSize>
#include <QSizeF>
#include <QString>
#include <QUrl>
#include <QVariantList>

#include <cstdint>
#include <memory>
#include <optional>
#include <variant>
#include <vector>

class QTimer;
struct mpv_event_end_file;

namespace wam::qt {

class AppSettings;
class MpvVideoItem;
class NativePlaybackOwner;
class PlayerCore;
#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) || defined(WAM_QT_TEST_SEAMS)
class PlayerControllerTestAccess;
class PlayerCoreTestAccess;
#endif
class SubtitleSources;

} // namespace wam::qt

namespace wam::playback::mpv {
class MpvRuntime;
}

namespace wam::media::native_playback {
struct CommitReady;
struct PreviewFailed;
struct PreviewPresented;
} // namespace wam::media::native_playback

namespace wam::qt {

// Latest snapshot mailbox: at most one queued notification and one pending
// snapshot, irrespective of backend speed. Its lifetime is independent of UI.
class CaptionLiveBridge final : public QObject {
  Q_OBJECT
public:
  struct Snapshot {
    std::shared_ptr<const std::vector<media::subtitles::Cue>> cues;
    bool committed = false;
  };
  std::mutex mutex;
  std::shared_ptr<const Snapshot> latest;
  std::atomic<bool> queued{false};
  // GUI thread only: the generated track was auto-selected once, and the
  // committed SRT replaced the live cues.
  bool selected = false;
  bool committed = false;
  void publish(std::shared_ptr<const Snapshot> value) {
    { std::lock_guard lock(mutex); latest = std::move(value); }
    if (!queued.exchange(true)) emit available();
  }
signals:
  void available();
};

// QML-facing playback state and commands. All regular libmpv client calls are
// made on this object's (GUI) thread; video rendering remains isolated on Qt
// Quick's render thread in MpvVideoItem.
class PlayerController final : public QObject,
                               private NativeEngineHost,
                               private MpvEngineHost {
  Q_OBJECT

  Q_PROPERTY(bool available READ available NOTIFY availableChanged)
  Q_PROPERTY(bool hasMedia READ hasMedia NOTIFY hasMediaChanged)
  Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
  Q_PROPERTY(QUrl source READ source WRITE setSource NOTIFY sourceChanged)
  Q_PROPERTY(QString mediaTitle READ mediaTitle NOTIFY mediaTitleChanged)
  Q_PROPERTY(bool playing READ playing NOTIFY playingChanged)
  Q_PROPERTY(bool paused READ paused NOTIFY pausedChanged)
  Q_PROPERTY(double position READ position WRITE seekTo NOTIFY positionChanged)
  Q_PROPERTY(double duration READ duration NOTIFY durationChanged)
  // The current video's facts, as stated by whichever engine actually
  // demuxed the container: the native route's Prepared event or mpv's
  // dwidth/dheight and video-params/gamma on the compatibility route. They are
  // the only source of video size and HDR in the app; AVFoundation cannot
  // demux Matroska, WebM or MPEG-TS, so no AVURLAsset probe can stand in.
  //
  // videoDisplaySize is the on-screen rectangle in square pixels (pixel
  // aspect, clean aperture and rotation applied), not the coded size. An
  // empty QSize means "not known": audio-only media, no media, or an open
  // that has not stated it yet. videoHdr is true for a PQ or HLG transfer.
  Q_PROPERTY(QSizeF videoDisplaySize READ videoDisplaySize NOTIFY
                 videoDisplaySizeChanged)
  Q_PROPERTY(bool videoHdr READ videoHdr NOTIFY videoDisplaySizeChanged)
  // Normalized level where 1.0 is 100%. The range runs to maximumVolume
  // below: above unity this is VLC-style amplification, which can clip by
  // design (the native gain stage saturates each sample to [-1, 1]; mpv is
  // given volume-max 400).
  Q_PROPERTY(double volume READ volume WRITE setVolume NOTIFY volumeChanged)
  Q_PROPERTY(bool muted READ muted WRITE setMuted NOTIFY mutedChanged)
  Q_PROPERTY(double rate READ rate WRITE setRate NOTIFY rateChanged)
  Q_PROPERTY(bool captionsVisible READ captionsVisible WRITE setCaptionsVisible
                 NOTIFY captionsVisibleChanged)
  // The one line of subtitle text that should be on screen right now, or an
  // empty string. Both engines feed this: the native route from cues this
  // process read out of the container, the compatibility route from mpv's
  // `sub-text` property (mpv keeps decoding and timing subtitles with its own
  // rendering switched off, which is what lets one overlay serve both).
  Q_PROPERTY(QString subtitleText READ subtitleText NOTIFY subtitleTextChanged)
  // The bitmap subtitle overlay (PGS, VobSub). `subtitleBitmapSource` is an
  // image:// URL resolved by SubtitleBitmapProvider; `subtitleBitmapRect` is
  // normalised 0..1 against the SUBTITLE CANVAS the track declares, which is
  // not necessarily the video's coded size, so the overlay maps it onto the
  // video rectangle itself. The three always change together and share a
  // signal.
  Q_PROPERTY(QString subtitleBitmapSource READ subtitleBitmapSource NOTIFY
                 subtitleBitmapChanged)
  // Four scalars rather than one QRectF, for the same reason the crop
  // rectangle is four: QML binds them individually and one signal covers the
  // whole change.
  Q_PROPERTY(double subtitleBitmapX READ subtitleBitmapX NOTIFY
                 subtitleBitmapChanged)
  Q_PROPERTY(double subtitleBitmapY READ subtitleBitmapY NOTIFY
                 subtitleBitmapChanged)
  Q_PROPERTY(double subtitleBitmapWidth READ subtitleBitmapWidth NOTIFY
                 subtitleBitmapChanged)
  Q_PROPERTY(double subtitleBitmapHeight READ subtitleBitmapHeight NOTIFY
                 subtitleBitmapChanged)
  Q_PROPERTY(bool subtitleBitmapVisible READ subtitleBitmapVisible NOTIFY
                 subtitleBitmapChanged)
  // Every selectable subtitle SOURCE for the current media, in menu order:
  // embedded text tracks, then generated captions, then loaded files. Each
  // entry is {id, label, language, origin, isDefault, isForced}; `id` is what
  // selectSubtitleTrack() takes and what activeSubtitleTrack reports.
  Q_PROPERTY(QVariantList subtitleTracks READ subtitleTracks NOTIFY
                 subtitleTracksChanged)
  // The selected source's id, or -1 for Off.
  Q_PROPERTY(int activeSubtitleTrack READ activeSubtitleTrack NOTIFY
                 activeSubtitleTrackChanged)
  // True from the first admitted wheel delta until the gesture settles. The
  // transport's own wheel block stands down while it is true, so a sweep that
  // started over the picture is not killed by the chrome revealing itself
  // under the pointer half way through.
  Q_PROPERTY(bool scrollGestureActive READ scrollGestureActive NOTIFY
                 scrollGestureActiveChanged)
  Q_PROPERTY(double trimIn READ trimIn WRITE setTrimIn NOTIFY trimInChanged)
  Q_PROPERTY(double trimOut READ trimOut WRITE setTrimOut NOTIFY trimOutChanged)
  // Retiming applied to the *exported* file, deliberately independent of the
  // viewing rate above: watching at 2x is a way to review, not an instruction
  // to ship a 2x cut. Both of these belong to the export, are reset per media
  // (see resetTimeline), and are not persisted.
  Q_PROPERTY(double exportSpeed READ exportSpeed WRITE setExportSpeed NOTIFY
                 exportSpeedChanged)
  Q_PROPERTY(bool exportPreservePitch READ exportPreservePitch WRITE
                 setExportPreservePitch NOTIFY exportPreservePitchChanged)
  // ::wam::ExportFormat as an int, because that is the whole of what a QML
  // enum round-trip can carry without registering the C++ type.
  Q_PROPERTY(int exportFormat READ exportFormat WRITE setExportFormat NOTIFY
                 exportFormatChanged)
  // True only when the CHOSEN format can be produced without re-encoding,
  // i.e. MKV at 1x with no crop. Drives the sheet's "fast copy" note.
  Q_PROPERTY(bool exportStreamCopies READ exportStreamCopies NOTIFY
                 exportStreamCopiesChanged)
  // The crop rectangle in normalized source coordinates. Four scalars rather
  // than one QRectF: QML binds them individually anyway, and this keeps the
  // change notifications as coarse as the edit actually is (one signal for
  // the whole rectangle).
  Q_PROPERTY(double cropX READ cropX NOTIFY cropChanged)
  Q_PROPERTY(double cropY READ cropY NOTIFY cropChanged)
  Q_PROPERTY(double cropWidth READ cropWidth NOTIFY cropChanged)
  Q_PROPERTY(double cropHeight READ cropHeight NOTIFY cropChanged)
  Q_PROPERTY(bool cropActive READ cropActive NOTIFY cropChanged)
  Q_PROPERTY(bool exporting READ exporting NOTIFY exportingChanged)
  Q_PROPERTY(QString exportStatus READ exportStatus NOTIFY exportStatusChanged)
  Q_PROPERTY(bool captioning READ captioning NOTIFY captioningChanged)
  Q_PROPERTY(
      QString captionStatus READ captionStatus NOTIFY captionStatusChanged)
  Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)
  // Informational playback notices (e.g. "using compatibility playback")
  // that never interrupt the user with a modal surface. Distinct from
  // lastError, which QML still presents as a blocking dialog for genuine
  // failures where playback did not continue.
  Q_PROPERTY(QString lastNotice READ lastNotice NOTIFY lastNoticeChanged)

public:
  // What one wheel event over the video surface was spent on. Returned as an
  // int through scrollGesture() so QML can reveal the matching chrome.
  enum ScrollGestureOutcome : int {
    ScrollGestureIgnored = 0,
    ScrollGestureVolume = 1,
    ScrollGestureSeek = 2,
  };
  Q_ENUM(ScrollGestureOutcome)

  explicit PlayerController(QObject *parent = nullptr);
  ~PlayerController() override;

  PlayerController(const PlayerController &) = delete;
  PlayerController &operator=(const PlayerController &) = delete;

  [[nodiscard]] bool available() const;
  [[nodiscard]] bool loading() const {
    return std::holds_alternative<MediaOpening>(media_phase_);
  }
  // Whether an open of `source` may land in this player: it holds nothing,
  // or it is already opening exactly that file. A player opening some other
  // file is taken.
  [[nodiscard]] bool claimableFor(const QUrl &source) const;
  [[nodiscard]] bool hasMedia() const { return !source_.isEmpty(); }
  [[nodiscard]] QUrl source() const override { return source_; }
  [[nodiscard]] QString mediaTitle() const { return media_title_; }
  [[nodiscard]] bool playing() const {
    return !paused_ && !idle_ && !eof_reached_;
  }
  [[nodiscard]] bool paused() const override { return paused_; }
  [[nodiscard]] double position() const override { return position_; }
  [[nodiscard]] double duration() const { return duration_; }
  [[nodiscard]] QSizeF videoDisplaySize() const { return video_display_size_; }
  [[nodiscard]] bool videoHdr() const { return video_hdr_; }
  [[nodiscard]] media::MediaDisplaySize exactVideoDisplaySize() const { return exact_video_display_size_; }
  // Normalized UI volume. mpv's 0..400 range maps to 0..4 here; 1.0 is 100%.
  [[nodiscard]] double volume() const { return volume_; }
  // The ceiling setVolume clamps to, applied from AppSettings::maximumVolume.
  [[nodiscard]] double maximumVolume() const { return maximum_volume_; }
  [[nodiscard]] bool scrollGestureActive() const {
    return !std::holds_alternative<ScrollIdle>(scroll_);
  }
  [[nodiscard]] bool muted() const { return muted_; }
  [[nodiscard]] double rate() const { return rate_; }
  [[nodiscard]] bool captionsVisible() const { return captions_visible_; }
  [[nodiscard]] QString subtitleText() const { return subtitle_text_; }
  [[nodiscard]] QString subtitleBitmapSource() const {
    return subtitle_bitmap_source_;
  }
  [[nodiscard]] double subtitleBitmapX() const { return subtitle_bitmap_x_; }
  [[nodiscard]] double subtitleBitmapY() const { return subtitle_bitmap_y_; }
  [[nodiscard]] double subtitleBitmapWidth() const {
    return subtitle_bitmap_width_;
  }
  [[nodiscard]] double subtitleBitmapHeight() const {
    return subtitle_bitmap_height_;
  }
  [[nodiscard]] bool subtitleBitmapVisible() const {
    return subtitle_bitmap_visible_;
  }
  [[nodiscard]] QVariantList subtitleTracks() const;
  [[nodiscard]] int activeSubtitleTrack() const;
  // The pitch mode the engines apply (AppSettings::preservePitch). Both
  // routes serve both modes mid-playback: native through the stretch stage's
  // pitch offset in cents, the compatibility engine through mpv's
  // audio-pitch-correction.
  [[nodiscard]] bool preservePitch() const { return preserve_pitch_; }
  [[nodiscard]] double trimIn() const { return trim_in_; }
  [[nodiscard]] double trimOut() const { return trim_out_; }
  [[nodiscard]] double exportSpeed() const { return export_speed_; }
  [[nodiscard]] int exportFormat() const;
  [[nodiscard]] bool exportStreamCopies() const;
  [[nodiscard]] double cropX() const { return crop_.x; }
  [[nodiscard]] double cropY() const { return crop_.y; }
  [[nodiscard]] double cropWidth() const { return crop_.width; }
  [[nodiscard]] double cropHeight() const { return crop_.height; }
  [[nodiscard]] bool cropActive() const { return crop_.active(); }
  [[nodiscard]] bool exportPreservePitch() const {
    return export_preserve_pitch_;
  }
  [[nodiscard]] bool exporting() const { return export_.has_value(); }
  [[nodiscard]] QString exportStatus() const { return export_status_; }
  [[nodiscard]] bool captionTranscribing() const {
    const auto status = caption_service_->tryStatus();
    return status && status->stage == ::wam::CaptionStage::Transcribing;
  }
  [[nodiscard]] bool captionTrackCommitted() const {
    return caption_live_bridge_ && caption_live_bridge_->committed;
  }
  [[nodiscard]] bool captioning() const { return caption_job_.has_value(); }
  [[nodiscard]] QString captionStatus() const { return caption_status_; }
  [[nodiscard]] QString lastError() const { return last_error_; }
  [[nodiscard]] QString lastNotice() const { return last_notice_; }

  void setSource(const QUrl &source);

  // Follows the app-level preferences from here on: the pitch mode and the
  // volume ceiling are applied to this window's engines, the seek step and
  // scroll gestures are read from them. Without it those features are off.
  void bindSettings(const AppSettings &settings);

  Q_INVOKABLE bool open(const QUrl &source);
  Q_INVOKABLE void play();
  Q_INVOKABLE void pause();
  Q_INVOKABLE void togglePlayPause();
  Q_INVOKABLE void stop();
  Q_INVOKABLE void beginScrub();
  Q_INVOKABLE void seekTo(double seconds) override;
  Q_INVOKABLE void previewSeekTo(double seconds);
  Q_INVOKABLE void endScrub(double seconds);
  Q_INVOKABLE void seekRelative(double seconds);
  Q_INVOKABLE void skipBackward();
  Q_INVOKABLE void skipForward();
  // One video frame later (direction > 0) or earlier (direction < 0). Pauses
  // first if the transport is running, which is the editor convention for
  // "." / ",". Exactness rules live in stepFrame's definition.
  Q_INVOKABLE void stepFrame(int direction);
  Q_INVOKABLE void toggleMute();
  Q_INVOKABLE void setMuted(bool muted);
  Q_INVOKABLE void setVolume(double volume);
  // Lowering the ceiling below the current level clamps that level down at
  // once and emits volumeClamped() so the window can say so on screen.
  void setMaximumVolume(double maximum);

  // One wheel event over the video surface. The arguments are the QML
  // WheelEvent's own fields, passed through untouched so the normalization
  // (trackpad pixelDelta vs wheel angleDelta, the natural-scroll `inverted`
  // flag, the dominant-axis lock, the momentum tail) lives in one tested
  // place -- ScrollGestureModel -- rather than in QML.
  //
  // Returns what the gesture did, so the QML side knows which chrome to
  // reveal: 0 nothing, 1 volume, 2 timeline sweep. See ScrollGestureOutcome.
  Q_INVOKABLE int scrollGesture(double pixelDeltaX, double pixelDeltaY,
                                double angleDeltaX, double angleDeltaY,
                                bool inverted, int phase);
  // Ends any live sweep immediately (window closing, media replaced, the
  // preference switched off). Safe to call with no gesture in flight.
  Q_INVOKABLE void settleScrollGesture();
  // The magnetic 100% detent, exposed for the volume sliders so a drag and a
  // scroll snap on exactly the same arithmetic.
  Q_INVOKABLE double snapVolumeToDetent(double volume) const;

  Q_INVOKABLE void setRate(double rate);
  Q_INVOKABLE void toggleCaptions();
  Q_INVOKABLE void setCaptionsVisible(bool visible);
  // Selects a subtitle source by id, or -1 for Off. Idempotent.
  Q_INVOKABLE void selectSubtitleTrack(int id);
  // Adds a subtitle file as a source and selects it.
  Q_INVOKABLE bool loadSubtitleFile(const QUrl &file);
  void setPreservePitch(bool preserve);
  Q_INVOKABLE void setTrimIn(double seconds);
  Q_INVOKABLE void setTrimOut(double seconds);
  Q_INVOKABLE void setExportSpeed(double speed);
  Q_INVOKABLE void setExportPreservePitch(bool preserve);
  Q_INVOKABLE void setExportFormat(int format);
  // The filename extension the current preset will actually produce, dot
  // included (".mp4", ".webm", ...). The Save dialog needs it for its default
  // suffix, its filter and its suggested name, and getting it from here means
  // QML never keeps a second copy of the preset-to-container mapping.
  Q_INVOKABLE QString exportFileSuffix() const;
  // Normalized source coordinates; the rectangle is clamped into the frame
  // and to a workable minimum size on the way in.
  Q_INVOKABLE void setCrop(double x, double y, double width, double height);

  // The live closed-caption tap this window's native session feeds.
  [[nodiscard]] const std::shared_ptr<media::captions::LiveCaptionFeed> &
  captionFeed() const noexcept {
    return caption_feed_;
  }
  Q_INVOKABLE void resetCrop();
  Q_INVOKABLE void exportSelection();
  Q_INVOKABLE void exportSelectionTo(const QUrl &destination);
  Q_INVOKABLE void cancelExport();
  Q_INVOKABLE void generateCaptions();
  Q_INVOKABLE void generateCaptionsTo(const QUrl &destination);
  Q_INVOKABLE void cancelCaptioning();

  // Announces that this controller's window is being torn down, so nothing
  // that happens from here on is worth telling a user about.
  //
  // Closing a window destroys its QML scene, and destroying the scene destroys
  // the video item, which NativePlaybackOwner correctly treats as an emergency
  // surface loss and reports as "the native video surface was destroyed during
  // playback". That report is right in every other circumstance and useless in
  // this one: it names, as a failure, the deliberate act the user just
  // performed, on a window that is about to stop existing. After this call
  // setLastError is a no-op -- the teardown itself is unchanged, only the
  // announcement of it stops.
  void beginTeardown() noexcept { tearing_down_ = true; }

  void setCaptionStatus(const QString &status);

signals:
  void availableChanged();
  void hasMediaChanged();
  void loadingChanged();
  void sourceChanged();
  void mediaTitleChanged();
  void playingChanged();
  void pausedChanged();
  void positionChanged();
  // A seek, scrub or frame step was asked for (by the user or on their
  // behalf), before any engine acted on it.
  void seekRequested();
  void durationChanged();
  void videoDisplaySizeChanged();
  void volumeChanged();
  // The level was pulled down because the maximum-volume setting was lowered
  // under it -- not because anything asked for a new level. qml/Main.qml puts
  // the resulting value on screen in the volume OSD, so a boost silently
  // disappearing always has a visible cause.
  void volumeClamped();
  void scrollGestureActiveChanged();
  void mutedChanged();
  void rateChanged();
  void captionsVisibleChanged();
  void subtitleTextChanged();
  void subtitleBitmapChanged();
  void subtitleTracksChanged();
  void activeSubtitleTrackChanged();
  void trimInChanged();
  void trimOutChanged();
  void exportSpeedChanged();
  void exportPreservePitchChanged();
  void exportFormatChanged();
  void exportStreamCopiesChanged();
  void cropChanged();
  void exportingChanged();
  void exportStatusChanged();
  void captioningChanged();
  void captionStatusChanged();
  void lastErrorChanged();
  void lastNoticeChanged();

  // The QML shell owns platform dialogs/window state. These requests keep the
  // playback core independent of Qt Widgets and native-window assumptions.
  void exportSelectionRequested(double trim_in, double trim_out);
  void generateCaptionsRequested();

private:
  friend class PlayerCore;
  friend class MpvVideoItem;
#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) || defined(WAM_QT_TEST_SEAMS)
  // test_seams.cpp's `nativefail` verb reaches the native engine; the
  // controller and core tests reach the mpv core.
  friend class PlayerControllerTestAccess;
  friend class PlayerCoreTestAccess;
#endif

  using OpenAttempt = MpvEngine::OpenAttempt;
  using RoutedFallbackOpen = MpvEngine::RoutedFallbackOpen;
  using RenderRecoveryMode = MpvEngine::RenderRecoveryMode;
  using RenderRecovery = MpvEngine::RenderRecovery;
  using RenderRecoveryAttempt = MpvEngine::RenderRecoveryAttempt;
  using StartupPlaybackSync = MpvEngine::StartupPlaybackSync;
  using PlaylistEntryRange = MpvEngine::PlaylistEntryRange;

  // Controller-side ownership for a native pointer gesture. The handle tracks
  // every movement immediately, while native media work is demand-driven: one
  // exact request may be in flight and all later movement coalesces into the
  // single latest desired identity. A real terminal presentation releases the
  // in-flight slot and immediately dispatches that latest desire. Releasing
  // the pointer burns both identities and creates one fresh CommitSeek.
  struct NativeScrubIntent {
    std::uint64_t gesture = 0;
    double origin = 0.0;
    double target = 0.0;
    std::uint64_t latest_preview_request = 0;
    // The one preview request the session is working on; empty while the
    // slot is free.
    std::optional<std::uint64_t> in_flight_preview;
    // False when the native session refused the pointer-down preview handoff
    // for the whole binding -- an audio-only source has no thumbnail to show.
    // The gesture still tracks the drag in the time readout and still commits
    // one exact seek on release; it simply never demands a frame.
    bool preview_available = true;
  };

  struct NativePreviewIntent {
    std::uint64_t gesture = 0;
    std::uint64_t request = 0;
    double target = 0.0;
  };

  struct NativeSeekIntent {
    std::uint64_t gesture = 0;
    std::uint64_t request = 0;
    double target = 0.0;
    double rollback_position = 0.0;
    bool intended_paused = true;
  };

  // The native transport gesture, which owns the logical pause intent until
  // it ends. Scrubbing may still have the previous commit converging under
  // it (a new drag that began before the last release landed); its pause
  // intent is the scrub's. Committing's is the commit's own.
  struct NativeGestureIdle {};
  struct NativeScrubbing {
    NativeScrubIntent scrub;
    std::optional<NativeSeekIntent> converging;
    bool intended_paused = true;
  };
  struct NativeCommitting {
    NativeSeekIntent commit;
  };
  using NativeGesture =
      std::variant<NativeGestureIdle, NativeScrubbing, NativeCommitting>;

  // Frame geometry of the picture on screen, as last proved by a draw.
  struct NativeFrameUnknown {};
  struct NativeAudioOnly {};
  struct NativeFrame {
    double start = 0.0;
    double duration = 0.0;
  };
  using NativeFrameGeometry =
      std::variant<NativeFrameUnknown, NativeAudioOnly, NativeFrame>;

  // A frame step pressed before the frame on screen was proved: the direction
  // to step once THIS settling commit lands. Bound to the commit's identity,
  // so a refused, failed or superseded settle cannot fire it later.
  struct PendingFrameStep {
    std::uint64_t gesture = 0;
    std::uint64_t request = 0;
    int direction = 0;
  };

  enum class NativeSeekTerminal : std::uint8_t {
    None,
    Ready,
    Failed,
  };

  struct NativeSeekSubmissionState {
    std::uint64_t gesture = 0;
    std::uint64_t request = 0;
    double target = 0.0;
    NativeSeekTerminal terminal{NativeSeekTerminal::None};
    NativeSeekSubmissionState *previous = nullptr;
  };

  enum class NativeSeekSubmission : std::uint8_t {
    Accepted,
    Rejected,
    Compatibility,
  };

  enum class NativeSeekDispatch : std::uint8_t {
    Consumed,
    Compatibility,
  };

  enum class NativePreviewSubmission : std::uint8_t {
    Accepted,
    Replaced,
    Stale,
    Rejected,
  };

  using NativeSeekSubmitter = NativeSeekSubmission (*)(
      void *context, const NativeSeekIntent &intent) noexcept;
  using NativePreviewSubmitter = NativePreviewSubmission (*)(
      void *context, const NativePreviewIntent &intent) noexcept;
  using NativePreviewDemandObserver = void (*)(
      void *context, const NativePreviewIntent &intent) noexcept;


  void requestVideoUpdate() override;
  [[nodiscard]] static std::optional<std::uint64_t>
  reserveNativeSeekIdentity(std::uint64_t &high_water) noexcept;
  [[nodiscard]] double boundedSeekTarget(double seconds) const noexcept;
  // The bound every native target is held strictly below. See the definition.
  [[nodiscard]] double nativeSeekLimit() const noexcept;
  // boundedSeekTarget restated for the native route, which admits only a
  // target that is both exactly representable as a rational media time and
  // strictly inside the duration. See the definition for the exactness rule.
  [[nodiscard]] double exactNativeSeekTarget(double seconds) const noexcept;
  // Frame stepping needs a FINER dyadic rung than exactNativeSeekTarget's
  // 1/64 s scrubber grid: one 1/64 step is 15.6 ms, which is coarser than a
  // frame above 64 fps and -- fatally for a forward step -- flooring
  // `frameStart + frameDuration` back onto that grid lands inside the frame
  // you were already on, so the step would do nothing. The preflight rule is
  // not the 1/64 grid; media::exactNonnegativeMediaTime admits any k/2^n with
  // n <= 30, so a 2^-12 s (0.244 ms) grid is equally representable and is
  // exact for anything up to 4096 fps. `round_up` picks the ceiling (forward
  // step, which must reach the NEXT frame's interval) or the floor (backward
  // step, which must fall strictly short of the current frame's start).
  [[nodiscard]] double frameStepSeekTarget(double seconds,
                                           bool round_up) const noexcept;
  // makeNativeSeekIntent restated for a target the caller has already snapped
  // onto its own admissible grid. Reusing makeNativeSeekIntent would re-floor
  // a frame-step target onto the coarse 1/64 scrubber grid and undo it.
  [[nodiscard]] std::optional<NativeSeekIntent>
  makeNativeExactSeekIntent(double exact_target);
  // Closes a live timeline sweep with exactly one commit. A no-op when no
  // sweep is open.
  void commitScrollSweep();
  [[nodiscard]] bool beginNativeScrubIntent();
  [[nodiscard]] std::optional<NativePreviewIntent>
  makeNativePreviewIntent(double seconds);
  [[nodiscard]] std::optional<NativePreviewIntent>
  makeObservedNativePreviewIntent(double seconds, void *context,
                                  NativePreviewDemandObserver observer);
  void dispatchNativePreviewIntent(const NativePreviewIntent &intent,
                                   void *context,
                                   NativePreviewSubmitter submitter);
  [[nodiscard]] std::optional<NativeSeekIntent>
  finishNativeScrubIntent(double seconds);
  [[nodiscard]] std::optional<NativeSeekIntent>
  makeNativeSeekIntent(double seconds);
  [[nodiscard]] NativeSeekDispatch
  dispatchNativeSeekIntent(const NativeSeekIntent &intent, void *context,
                           NativeSeekSubmitter submitter);
  // The production NativePreviewSubmitter: `context` is the NativeEngine
  // and the mapping from its PreviewDisposition to NativePreviewSubmission is
  // stated here once, for the demand, presented and failed entry points alike.
  [[nodiscard]] static NativePreviewSubmission
  submitNativePreviewFrame(void *context,
                           const NativePreviewIntent &intent) noexcept;
  void dispatchNativePreviewIntent(const NativePreviewIntent &intent);
  void nativePreviewPresented(
      const ::wam::media::native_playback::PreviewPresented &presented) override;
  void nativePreviewFailed(
      const ::wam::media::native_playback::PreviewFailed &failed) override;
  [[nodiscard]] NativeSeekDispatch
  dispatchNativeSeekIntent(const NativeSeekIntent &intent);
  void
  nativeCommitReady(const ::wam::media::native_playback::CommitReady &ready) override;
  [[nodiscard]] bool completeNativePreviewPresented(
      std::uint64_t gesture, std::uint64_t request,
      double actual_presentation_time, void *context,
      NativePreviewSubmitter submitter);
  [[nodiscard]] bool completeNativePreviewFailed(
      std::uint64_t gesture, std::uint64_t request, void *context,
      NativePreviewSubmitter submitter);
  [[nodiscard]] bool acceptNativeCommitReady(std::uint64_t gesture,
                                             std::uint64_t request,
                                             double target);
  void nativeCommitFailed(std::uint64_t gesture,
                          std::uint64_t request) noexcept override;
  void setNativeScrubPauseIntent(bool paused);
  [[nodiscard]] NativeScrubIntent *nativeScrub() noexcept;
  [[nodiscard]] const NativeSeekIntent *nativeCommit() const noexcept;
  // The logical pause intent: the gesture's while one is live, else the
  // transport's.
  [[nodiscard]] bool nativeIntendedPaused() const noexcept;
  // An accepted commit becomes the live one (under a scrub, the converging
  // one). Ready or Failed for that identity retires it.
  void adoptNativeCommit(const NativeSeekIntent &intent);
  [[nodiscard]] bool retireNativeCommit(std::uint64_t gesture,
                                        std::uint64_t request,
                                        const double *target) noexcept;
  // True when (gesture, request) is the preview occupying the slot.
  [[nodiscard]] bool ownsNativePreview(std::uint64_t gesture,
                                       std::uint64_t request) noexcept;
  // Frees the slot after a terminal preview and spends it once on the newest
  // desire if that is not the request that just finished.
  void releaseNativePreviewSlot(std::uint64_t request, void *context,
                                NativePreviewSubmitter submitter);
  [[nodiscard]] static NativeSeekSubmission
  submitNativeCommit(void *context, const NativeSeekIntent &intent) noexcept;
  void stepNativeFrame(bool forward, void *context,
                       NativeSeekSubmitter submitter);
  [[nodiscard]] double nativeFrameDuration() const noexcept;
  // A native scrub or seek owns the logical pause intent until it commits.
  // Play at the end, or within one frame of it (never less than 50 ms),
  // replays from the start. `frame_duration` is the playing engine's own
  // frame duration, 0 when it knows none.
  [[nodiscard]] bool atEndForReplay(double frame_duration) const noexcept override;
  [[nodiscard]] bool nativeSeekInFlight() const noexcept override {
    return !std::holds_alternative<NativeGestureIdle>(native_gesture_);
  }
  void invalidateNativeScrubIntent() noexcept;
  void invalidateNativeSeekIntents() noexcept;
  void publishNativeMainPosition(double position) override;
  // The exact geometry of the frame currently on screen, as proved by the
  // native route's VideoDrawProof (every drawn frame, and every commit's
  // embedded draw proof). This is the ONLY per-sample timing the GUI layer
  // ever sees -- no frame rate exists anywhere in the contract -- and it is
  // what makes frame stepping exact under VFR: the next frame's PTS is this
  // frame's start plus this frame's own duration, never a nominal interval.
  void publishNativeFrameGeometry(double start_seconds,
                                  double duration_seconds) override;
  void updatePosition(double position) override;
  // --- subtitles -------------------------------------------------------
  // Rebuilds the source list for the current media from whichever engine owns
  // it. Idempotent and cheap to call again; it does nothing when the route and
  // the media have not changed since the last successful build.
  void refreshSubtitleSources() override;
  void buildMpvSubtitleSources();
  void buildNativeSubtitleSources();
  void applySubtitleDefaultPolicy();
  void publishSubtitleText(const QString &text);
  // Re-evaluates the on-screen line for the current position. Only the native
  // route needs this; on the compatibility route mpv pushes the text instead.
  void updateSubtitleForPosition();
  void updateSubtitleBitmapForPosition();
  void resetSubtitlesForMediaChange();
  // The one statement of "the native engine owns this window's transport
  // right now", null check included. Route admission (whether an open MAY go
  // native) is a different question and lives in nativeRouteAdmissionAllowed.
  [[nodiscard]] bool nativeRouteActive() const;
  // Adds a sidecar subtitle file on whichever route is live and selects it.
  bool attachSubtitleSource(const std::filesystem::path &path, int origin,
                            const QString &label);
  [[nodiscard]] bool engineReady() const override;
  [[nodiscard]] std::uint64_t requestSerial() const override {
    return request_serial_;
  }
  [[nodiscard]] QUrl requestedSource() const override {
    return requested_source_;
  }
  [[nodiscard]] bool eofReached() const override { return eof_reached_; }
  [[nodiscard]] MpvTransportChange
  assignTransport(const MpvTransport &transport) override;
  void publishTransport(const MpvTransportChange &change) override;
  void applyObservedVolume(double volume) override;
  void applyObservedMute(bool muted) override;
  void applyObservedRate(double rate) override;
  void applyObservedPreservePitch(bool preserve) override { preserve_pitch_ = preserve; }
  void applyObservedSubtitleText(const QString &text) override;
  void setRequestedSource(const QUrl &source) override {
    requested_source_ = source;
  }
  [[nodiscard]] NativeEngine *nativeEngine() const override { return native_.get(); }
  [[nodiscard]] MpvEngine &mpvEngine() noexcept override { return mpv_; }
  [[nodiscard]] bool needsRenderContext() const;
  bool initializePlaybackEngine() override;
  void prepareRoutedOpenIntent(const QUrl &source) override;
  [[nodiscard]] bool nativeRouteAdmissionAllowed() const noexcept override;
  [[nodiscard]] bool
  beginRoutedFallbackOpen(const QUrl &source, std::uint64_t attempt,
                          std::uint64_t serial, std::uint64_t source_key,
                          bool paused, PlaybackSourceClass source_class) override;
  [[nodiscard]] bool resetRoutedFallbackCoreAfterRelease(
      const std::shared_ptr<PlayerCore> &expected_core) override;
  void finishStopUi(bool stop_compatibility_engine) override;
  void attachVideoItem(MpvVideoItem *item);
  void detachVideoItem(MpvVideoItem *item);
  [[nodiscard]] std::shared_ptr<PlayerCore> coreForRendering() const;

  void updatePause(bool paused) override;
  void updateIdle(bool idle) override;
  void updateLoading(bool loading) override;
  void updateEof(bool eof_reached) override;
  void updateDuration(double duration) override;
  // The native route's presentable ceiling (NativeMediaSession::
  // seekCeilingSeconds); 0 while no native session is prepared. Read only by
  // the native target snap, never shown: the timeline keeps the real duration.
  void updateNativeSeekCeiling(double seconds) override;
  // Publishes the video facts from whichever engine demuxed the container.
  // Both callers -- NativePlaybackOwner's Prepared arm and the mpv
  // observation -- go through here so the dedupe and the "an empty size never
  // overwrites a known one" rule are stated once. A backend with no picture
  // states nothing, HDR included. resetTimeline() is the one place the facts
  // are deliberately forgotten.
  void updateVideoFacts(media::MediaRational width, media::MediaRational height,
                        bool hdr) override;
  void updateSource(const QUrl &source) override;
  void updateMediaTitle(const QString &title) override;
  void resetTimeline() override;
  // Cancels a caption job unless `incoming` is the file it is captioning.
  void cancelCaptionsForMediaChange(const QUrl &incoming);
  // The engines' error report. During Opening an error IS the open failing
  // (failOpen); otherwise it is only shown.
  void setLastError(const QString &error) override;
  // Empties the player after its open failed, then shows why.
  void failOpen(const QString &error);
  // An error about a user action (a subtitle file, an export). Never changes
  // what the player holds.
  void showError(const QString &error);
  // Burns the previous media's gesture, captions and timeline and stamps a
  // new request serial for `source` (empty on stop).
  void beginMediaTransaction(const QUrl &source);
  // Non-blocking counterpart to setLastError: fallback-continuation notices
  // (native playback degraded to compatibility playback, or a seek could not
  // be served natively) where playback kept going and a modal dialog would
  // be pure interruption. QML surfaces this as a transient toast.
  void setLastNotice(const QString &notice) override;
  void setExportStatus(const QString &status);
  void beginExportJob(std::filesystem::path output,
                      std::filesystem::path staging);
  // Ends the export job, removing its staging file unless it was committed.
  void endExportJob() noexcept;
  void beginCaptionJob(std::filesystem::path input);
  void endCaptionJob();
  void startWorkPolling();
  void pollBackgroundWork();

  MpvEngine mpv_;
  // Null when this build has no native engine.
  std::unique_ptr<NativeEngine> native_;
  QPointer<MpvVideoItem> video_item_;
  const AppSettings *settings_ = nullptr;
  QTimer *work_timer_ = nullptr;
  // Pointer-scroll gestures. The model owns the axis lock and the detent; the
  // timer owns "the gesture has settled", which is what both releases the
  // axis lock and commits a timeline sweep. A wheel stream has no release
  // event a scrub could hang off -- momentum keeps arriving after the fingers
  // have left and a real wheel has no phases at all -- so settling is the
  // only honest gesture boundary.
  QTimer *scroll_settle_timer_ = nullptr;
  ScrollGestureModel scroll_model_;
  // The scroll gesture: idle, active until it settles, or a live timeline
  // sweep (one open scrub gesture and the latest target swept to).
  struct ScrollIdle {};
  struct ScrollActive {};
  struct ScrollSweep {
    double target = 0.0;
  };
  std::variant<ScrollIdle, ScrollActive, ScrollSweep> scroll_;
  // Ends the gesture without committing a sweep: the media it was sweeping
  // is going away.
  void cancelScrollGesture();
  void setScrollState(std::variant<ScrollIdle, ScrollActive, ScrollSweep> state);

  ::wam::BackgroundJob export_job_;
  std::shared_ptr<::wam::CaptionService> caption_service_ = std::make_shared<::wam::CaptionService>();
  // The live generated track of the latest caption request. It outlives the
  // job on success, so the committed cues keep arriving after it ends.
  std::shared_ptr<CaptionLiveBridge> caption_live_bridge_;
  std::unique_ptr<SubtitleSources> subtitles_;
  // The live closed-caption tap the native video consumer feeds for this
  // window. Owned here so it outlives any one session; handed to the session
  // at creation.
  std::shared_ptr<media::captions::LiveCaptionFeed> caption_feed_;
  QString subtitle_text_;
  QString subtitle_bitmap_source_;
  double subtitle_bitmap_x_{0.0};
  double subtitle_bitmap_y_{0.0};
  double subtitle_bitmap_width_{0.0};
  double subtitle_bitmap_height_{0.0};
  bool subtitle_bitmap_visible_{false};
  // The source the subtitle list was last built for, and under which engine;
  // empty until built for this media. A route flip (native admission refused
  // mid-open) must rebuild the list from the engine that actually ended up
  // playing.
  struct SubtitleListStamp {
    QUrl source;
    bool native = false;
  };
  std::optional<SubtitleListStamp> subtitle_list_built_;

  // What the player holds. Empty <=> source_ is empty. Opening is the
  // native route's open in flight, carrying the URL the user asked for (the
  // compatibility route goes straight from Empty to Loaded when mpv reports
  // the path).
  struct MediaEmpty {};
  struct MediaOpening {
    QUrl requested;
  };
  struct MediaLoaded {};
  using MediaPhase = std::variant<MediaEmpty, MediaOpening, MediaLoaded>;
  MediaPhase media_phase_;
  void setMediaPhase(MediaPhase phase);
  QUrl source_;
  // requested_source_ is the authoritative GUI intent. source_ mirrors mpv's
  // observed path and can briefly clear during asynchronous replacement.
  QUrl requested_source_;
  QString media_title_;
  QString last_error_;
  QString last_notice_;
  QString export_status_;
  QString caption_status_;

  bool paused_ = true;
  bool idle_ = true;
  bool eof_reached_ = false;
  bool muted_ = false;
  bool captions_visible_ = true;
  bool preserve_pitch_ = true;
  double position_ = 0.0;
  double duration_ = 0.0;
  double native_seek_ceiling_ = 0.0;
  QSizeF video_display_size_;
  media::MediaDisplaySize exact_video_display_size_;
  bool video_hdr_ = false;
  double volume_ = 1.0;
  double maximum_volume_ = 2.0;
  double rate_ = 1.0;
  double trim_in_ = 0.0;
  double trim_out_ = 0.0;
  double export_speed_ = 1.0;
  bool export_preserve_pitch_ = true;
  ::wam::ExportFormat export_format_ = ::wam::ExportFormat::Mp4H264;
  // Per window, and reset on every media change: a rectangle drawn over one
  // shot means nothing over the next file's framing.
  ::wam::CropRect crop_{};
  // A running export: where it lands, the reserved staging file it encodes
  // into, and whether the user cancelled it.
  struct ExportJob {
    std::filesystem::path output;
    std::filesystem::path staging;
    bool cancel_requested = false;
  };
  std::optional<ExportJob> export_;
  // A running caption request: its input, why it is being cancelled (empty
  // until cancelled), and whether its download prompt was already shown.
  struct CaptionJob {
    std::filesystem::path input;
    QString cancel_reason;
    bool download_prompted = false;
  };
  std::optional<CaptionJob> caption_job_;
  // See beginTeardown(): silences user-facing errors once this controller's
  // window is on its way out.
  bool tearing_down_ = false;
  std::uint64_t request_serial_ = 0;
  std::uint64_t next_native_seek_gesture_id_ = 0;
  std::uint64_t next_native_seek_request_id_ = 0;
  // The subset of MpvEngine's attached subtitle files this player GENERATED,
  // so the Subtitles menu can name them honestly. A file the user loaded is
  // not a generated caption.
  std::vector<std::filesystem::path> generated_caption_files_;
  NativeGesture native_gesture_;
  // The overlay of synchronous commitSeek calls currently on the C++ stack
  // (innermost first). A terminal observation drained during submission is
  // recorded here because the commit is not live yet.
  NativeSeekSubmissionState *native_seek_submission_ = nullptr;
  std::uint64_t latest_native_seek_submission_request_ = 0;
  NativeFrameGeometry native_frame_;
  std::optional<PendingFrameStep> pending_frame_step_;
#if defined(WAM_QT_TEST_SEAMS)
  // The controller-only test target deliberately excludes the platform owner.
  // This seam lets it exercise the public previewSeekTo boundary while keeping
  // production object layout and dispatch unchanged.
  void *native_preview_test_submit_context_ = nullptr;
  NativePreviewSubmitter native_preview_test_submitter_ = nullptr;
  void *native_preview_test_demand_context_ = nullptr;
  NativePreviewDemandObserver native_preview_test_demand_observer_ = nullptr;
#endif
};

} // namespace wam::qt
