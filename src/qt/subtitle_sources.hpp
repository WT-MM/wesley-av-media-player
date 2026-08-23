#pragma once

#include "media/matroska_subtitles.hpp"
#include "media/subtitle_text.hpp"

#include <QObject>
#include <QString>
#include <QVariantList>

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <thread>
#include <vector>

namespace wam::qt {

// The set of subtitle SOURCES one window can show, and the cue lane that feeds
// the overlay on the native route.
//
// A "source" is anything that can put a line of text over the picture: an
// embedded text track, the whisper-generated caption file, or a file the user
// loaded. They share one id space so the menu, the transport button and the
// test seam can all name a selection with a single integer, whichever engine
// is playing:
//
//     kOffId (-1)   nothing selected
//     1..N          a source, in menu order
//
// The two engines feed the same overlay from opposite ends. On the mpv route
// every source is an mpv track and the text arrives from mpv's `sub-text`
// property, so this object only models the list and the selection. On the
// native route there is no mpv, so this object also OWNS the cues: it loads
// them on a worker thread and answers "what should be on screen at time t".
class SubtitleSources final : public QObject {
  Q_OBJECT

public:
  static constexpr int kOffId = -1;

  enum class Origin : std::uint8_t {
    // A text track inside the media file.
    Embedded,
    // The whisper caption file this player produced for this media.
    Generated,
    // A subtitle file the user loaded.
    External,
  };

  struct Source {
    int id{kOffId};
    QString label;
    QString language;
    Origin origin{Origin::Embedded};
    bool defaultFlag{false};
    bool forcedFlag{false};
    // mpv route: the `sid` to write. Zero when this source is not an mpv track.
    std::int64_t mpvSid{0};
    // Native route: where the cues come from. Exactly one is set.
    std::uint64_t matroskaTrack{0};
    media::subtitles::TextCodec codec{media::subtitles::TextCodec::Unknown};
    std::filesystem::path filePath;

    // Same source, whatever id it currently holds. Ids are positional and are
    // reassigned on every rebuild; identity is not.
    [[nodiscard]] bool matches(const Source &other) const noexcept;
  };

  explicit SubtitleSources(QObject *parent = nullptr);
  ~SubtitleSources() override;

  // Forgets every source, cue and selection. Called when the media changes.
  void clear();

  // Replaces the embedded-track part of the list, keeping any generated or
  // external sources already added for this media (they outlive a route flip).
  void setEmbeddedTracks(std::vector<Source> tracks);

  // Adds a sidecar source and returns its id, or kOffId when it could not be
  // added. `mpvSid` is 0 on the native route.
  int addFileSource(const std::filesystem::path &path, Origin origin,
                    const QString &label, std::int64_t mpvSid);

  [[nodiscard]] const std::vector<Source> &sources() const noexcept {
    return sources_;
  }
  [[nodiscard]] QVariantList toVariantList() const;
  [[nodiscard]] const Source *find(int id) const noexcept;
  // The mpv `sid` currently selected maps back to an id, so an externally
  // driven selection (mpv's own auto-select, a `sub-add … select`) is mirrored
  // rather than fought.
  [[nodiscard]] int idForMpvSid(std::int64_t sid) const noexcept;
  // The id `previous` now has after a rebuild, or kOffId if it is gone.
  [[nodiscard]] int remap(const Source &previous) const noexcept;

  // The container's own opinion, as VLC reads it: a forced track first, then a
  // default track, then nothing. Returns kOffId when the container asserts
  // neither -- which is the common case and is why subtitles start off.
  [[nodiscard]] int containerPreferredId() const noexcept;

  [[nodiscard]] int activeId() const noexcept { return active_id_; }
  // Selects without loading; the caller decides whether cues are needed.
  void setActiveId(int id) noexcept { active_id_ = id; }

  // Last non-Off selection, so the transport button can restore it.
  [[nodiscard]] int lastSelectedId() const noexcept { return last_selected_id_; }
  void noteSelected(int id) noexcept {
    if (id != kOffId)
      last_selected_id_ = id;
  }

  // ---------------------------------------------------------------------
  // Native cue lane. Nothing here touches the playback graph: the load runs
  // on its own thread against its own descriptor, and the lookup is a search
  // in memory driven by the position the transport already publishes.
  // ---------------------------------------------------------------------

  // Starts (or replaces) the background load for `id`. Any load in flight is
  // cancelled and joined first, so at most one worker exists at a time.
  void beginNativeLoad(int id);
  void cancelNativeLoad();
  [[nodiscard]] bool loading() const noexcept { return loading_; }

  // Text for a media time in seconds, or an empty string. Cheap: the previous
  // index is used as a hint, so steady playback costs two comparisons.
  [[nodiscard]] QString textAt(double seconds) noexcept;
  // Drops the cue lookup hint, so the next lookup is a fresh search. Called on
  // a seek; not required for correctness (a wrong hint is always safe) but it
  // keeps the backwards case off the slow path.
  void resetLookupHint() noexcept {
    hint_ = -1;
    cached_text_.clear();
  }
  [[nodiscard]] bool hasCues() const noexcept { return !cues_.empty(); }

  // Load a sidecar file's cues synchronously. Subtitle files are small enough
  // that a worker would only add a race; a media container is not, which is
  // why the embedded path is asynchronous and this one is not.
  bool loadFileCues(const std::filesystem::path &path, QString *error);

signals:
  // The cue set changed (a load finished, or was cleared). The controller
  // re-evaluates the current line on this.
  void cuesChanged();
  void loadingChanged();
  void loadFailed(const QString &reason);

private:
  void applyLoad(std::uint64_t generation,
                 media::matroska::SubtitleTrackLoad load);
  void setLoading(bool loading);

  std::vector<Source> sources_;
  int active_id_{kOffId};
  int last_selected_id_{kOffId};
  int next_id_{1};

  std::vector<media::subtitles::Cue> cues_;
  // Index of the cue last resolved, and its text. The pair is the whole
  // steady-state cost of the lane: a hit is one integer compare and an
  // implicitly-shared QString copy, with no allocation and no UTF-8 decode.
  std::ptrdiff_t hint_{-1};
  QString cached_text_;

  // One worker at a time, always joined before it is replaced or destroyed --
  // a detached thread holding `this` is the one way this lane could outlive
  // its window.
  std::thread worker_;
  std::shared_ptr<std::atomic<bool>> cancel_;
  std::uint64_t generation_{0};
  bool loading_{false};
};

}  // namespace wam::qt
