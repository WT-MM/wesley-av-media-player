#pragma once

#include "caption_service.hpp"
#include "jobs.hpp"

#include <QObject>
#include <QPointer>
#include <QString>
#include <QUrl>

#include <memory>

class QTimer;

namespace wam::qt {

class MpvVideoItem;
class PlayerCore;

// QML-facing playback state and commands. All regular libmpv client calls are
// made on this object's (GUI) thread; video rendering remains isolated on Qt
// Quick's render thread in MpvVideoItem.
class PlayerController final : public QObject {
  Q_OBJECT

  Q_PROPERTY(bool available READ available CONSTANT)
  Q_PROPERTY(bool hasMedia READ hasMedia NOTIFY hasMediaChanged)
  Q_PROPERTY(QUrl source READ source WRITE setSource NOTIFY sourceChanged)
  Q_PROPERTY(QString mediaTitle READ mediaTitle NOTIFY mediaTitleChanged)
  Q_PROPERTY(bool playing READ playing NOTIFY playingChanged)
  Q_PROPERTY(bool paused READ paused NOTIFY pausedChanged)
  Q_PROPERTY(double position READ position WRITE seekTo NOTIFY positionChanged)
  Q_PROPERTY(double duration READ duration NOTIFY durationChanged)
  Q_PROPERTY(double volume READ volume WRITE setVolume NOTIFY volumeChanged)
  Q_PROPERTY(bool muted READ muted WRITE setMuted NOTIFY mutedChanged)
  Q_PROPERTY(double rate READ rate WRITE setRate NOTIFY rateChanged)
  Q_PROPERTY(bool captionsVisible READ captionsVisible WRITE setCaptionsVisible
                 NOTIFY captionsVisibleChanged)
  Q_PROPERTY(bool preservePitch READ preservePitch WRITE setPreservePitch NOTIFY
                 preservePitchChanged)
  Q_PROPERTY(int appearance READ appearance WRITE setAppearance NOTIFY
                 appearanceChanged)
  Q_PROPERTY(double trimIn READ trimIn WRITE setTrimIn NOTIFY trimInChanged)
  Q_PROPERTY(double trimOut READ trimOut WRITE setTrimOut NOTIFY trimOutChanged)
  Q_PROPERTY(bool exporting READ exporting NOTIFY exportingChanged)
  Q_PROPERTY(QString exportStatus READ exportStatus NOTIFY exportStatusChanged)
  Q_PROPERTY(bool captioning READ captioning NOTIFY captioningChanged)
  Q_PROPERTY(
      QString captionStatus READ captionStatus NOTIFY captionStatusChanged)
  Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)

public:
  explicit PlayerController(QObject *parent = nullptr);
  ~PlayerController() override;

  PlayerController(const PlayerController &) = delete;
  PlayerController &operator=(const PlayerController &) = delete;

  [[nodiscard]] bool available() const;
  [[nodiscard]] bool hasMedia() const { return !source_.isEmpty(); }
  [[nodiscard]] QUrl source() const { return source_; }
  [[nodiscard]] QString mediaTitle() const { return media_title_; }
  [[nodiscard]] bool playing() const {
    return !paused_ && !idle_ && !eof_reached_;
  }
  [[nodiscard]] bool paused() const { return paused_; }
  [[nodiscard]] double position() const { return position_; }
  [[nodiscard]] double duration() const { return duration_; }
  // Normalized UI volume. mpv's 0..100 range maps to 0..1 here.
  [[nodiscard]] double volume() const { return volume_; }
  [[nodiscard]] bool muted() const { return muted_; }
  [[nodiscard]] double rate() const { return rate_; }
  [[nodiscard]] bool captionsVisible() const { return captions_visible_; }
  [[nodiscard]] bool preservePitch() const { return preserve_pitch_; }
  // 0 = light (default), 1 = dark, 2 = follow the operating system.
  [[nodiscard]] int appearance() const { return appearance_; }
  [[nodiscard]] double trimIn() const { return trim_in_; }
  [[nodiscard]] double trimOut() const { return trim_out_; }
  [[nodiscard]] bool exporting() const { return exporting_; }
  [[nodiscard]] QString exportStatus() const { return export_status_; }
  [[nodiscard]] bool captioning() const { return captioning_; }
  [[nodiscard]] QString captionStatus() const { return caption_status_; }
  [[nodiscard]] QString lastError() const { return last_error_; }

  void setSource(const QUrl &source);

  Q_INVOKABLE void openFileDialog();
  Q_INVOKABLE bool open(const QUrl &source);
  Q_INVOKABLE void play();
  Q_INVOKABLE void pause();
  Q_INVOKABLE void togglePlayPause();
  Q_INVOKABLE void stop();
  Q_INVOKABLE void seekTo(double seconds);
  Q_INVOKABLE void previewSeekTo(double seconds);
  Q_INVOKABLE void seekRelative(double seconds);
  Q_INVOKABLE void skipBackward();
  Q_INVOKABLE void skipForward();
  Q_INVOKABLE void toggleMute();
  Q_INVOKABLE void setMuted(bool muted);
  Q_INVOKABLE void setVolume(double volume);
  Q_INVOKABLE void setRate(double rate);
  Q_INVOKABLE void toggleCaptions();
  Q_INVOKABLE void setCaptionsVisible(bool visible);
  Q_INVOKABLE void toggleFullscreen();
  Q_INVOKABLE void setPreservePitch(bool preserve);
  Q_INVOKABLE void setAppearance(int appearance);
  Q_INVOKABLE void setTrimIn(double seconds);
  Q_INVOKABLE void setTrimOut(double seconds);
  Q_INVOKABLE void exportSelection();
  Q_INVOKABLE void exportSelectionTo(const QUrl &destination);
  Q_INVOKABLE void cancelExport();
  Q_INVOKABLE void generateCaptions();
  Q_INVOKABLE void generateCaptionsTo(const QUrl &destination);
  Q_INVOKABLE void cancelCaptioning();

  // Job/caption adapters can drive these while remaining independent of QML.
  void setExporting(bool exporting);
  void setCaptioning(bool captioning);
  void setCaptionStatus(const QString &status);

signals:
  void hasMediaChanged();
  void sourceChanged();
  void mediaTitleChanged();
  void playingChanged();
  void pausedChanged();
  void positionChanged();
  void durationChanged();
  void volumeChanged();
  void mutedChanged();
  void rateChanged();
  void captionsVisibleChanged();
  void preservePitchChanged();
  void appearanceChanged();
  void trimInChanged();
  void trimOutChanged();
  void exportingChanged();
  void exportStatusChanged();
  void captioningChanged();
  void captionStatusChanged();
  void lastErrorChanged();

  // The QML shell owns platform dialogs/window state. These requests keep the
  // playback core independent of Qt Widgets and native-window assumptions.
  void openFileDialogRequested();
  void fullscreenToggleRequested();
  void exportSelectionRequested(double trim_in, double trim_out);
  void generateCaptionsRequested();
  void cancelCaptioningRequested();

private:
  friend class PlayerCore;
  friend class MpvVideoItem;

  enum class ObservedProperty : uint64_t {
    Pause = 1,
    Idle,
    Position,
    Duration,
    Volume,
    Mute,
    Rate,
    CaptionsVisible,
    Path,
    MediaTitle,
    PreservePitch,
    EofReached,
  };

  void drainMpvEvents();
  void requestVideoUpdate();
  void flushPendingOpen();
  void attachVideoItem(MpvVideoItem *item);
  void detachVideoItem(MpvVideoItem *item);
  [[nodiscard]] std::shared_ptr<PlayerCore> coreForRendering() const;

  void updatePause(bool paused);
  void updateIdle(bool idle);
  void updateEof(bool eof_reached);
  void updateSource(const QUrl &source);
  void updateMediaTitle(const QString &title);
  void resetTimeline();
  void cancelCaptionsForMediaChange();
  void setLastError(const QString &error);
  void setExportStatus(const QString &status);
  void cleanupExportStaging() noexcept;
  void startWorkPolling();
  void pollBackgroundWork();
  bool attachSubtitleFile(const std::filesystem::path &subtitle);

  std::shared_ptr<PlayerCore> core_;
  QPointer<MpvVideoItem> video_item_;
  QTimer *work_timer_ = nullptr;

  ::wam::BackgroundJob export_job_;
  ::wam::CaptionService caption_service_;

  QUrl source_;
  QUrl pending_source_;
  QString media_title_;
  int appearance_ = 0;
  QString last_error_;
  QString export_status_;
  QString caption_status_;
  QString caption_cancel_reason_;
  std::filesystem::path export_output_;
  std::filesystem::path export_staging_;
  std::filesystem::path caption_input_;
  bool paused_ = true;
  bool idle_ = true;
  bool eof_reached_ = false;
  bool muted_ = false;
  bool captions_visible_ = true;
  bool preserve_pitch_ = true;
  double position_ = 0.0;
  double duration_ = 0.0;
  double volume_ = 1.0;
  double rate_ = 1.0;
  double trim_in_ = 0.0;
  double trim_out_ = 0.0;
  bool exporting_ = false;
  bool captioning_ = false;
  bool export_cancel_requested_ = false;
  bool export_completion_pending_ = false;
  bool caption_completion_pending_ = false;
};

} // namespace wam::qt
