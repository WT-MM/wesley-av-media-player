#include "qt/subtitle_sources.hpp"

#include "qt/subtitle_bitmap_provider.hpp"

#include <QFile>
#include <QFileInfo>
#include <QMetaObject>
#include <QVariantMap>

#include <algorithm>
#include <cmath>
#include <limits>
#include <utility>

namespace wam::qt {
namespace {

constexpr std::int64_t kNanosecondsPerSecond = 1'000'000'000;

// A subtitle file the user points at. Bounded so a mistaken pick (a video, a
// disk image) is refused instead of read into memory.
constexpr qint64 kMaximumSubtitleFileBytes = 16LL * 1024LL * 1024LL;

QString originName(SubtitleSources::Origin origin) {
  switch (origin) {
    case SubtitleSources::Origin::Embedded:
      return QStringLiteral("embedded");
    case SubtitleSources::Origin::Generated:
      return QStringLiteral("generated");
    case SubtitleSources::Origin::External:
      return QStringLiteral("external");
  }
  return QStringLiteral("embedded");
}

// Makes every source's menu label unique within one media's list.
//
// A label is built from the track's own Name, then its language, then its
// ordinal (subtitleSourceLabel in player_controller.cpp). Two same-language
// tracks with no Name -- an extremely common shape; the file that produced
// this defect carries two English SRT tracks, neither named -- therefore both
// render as exactly "English", and the menu offers the user two identical rows
// with nothing to choose between and no way to tell which one the container
// prefers.
//
// The rule, applied only to labels that actually collide so a lone "English"
// stays "English":
//
//   1. the container's own opinion first, because it is both the most useful
//      distinction and the one the user is being asked about: a forced track
//      becomes "… (Forced)", a default-flagged one "… (Default)";
//   2. anything still ambiguous after that -- neither flagged, both flagged,
//      or an author who literally named a track "English (Default)" -- gets a
//      position, which always separates them.
//
// Both passes decide from a snapshot taken BEFORE they mutate anything, so the
// outcome does not depend on the order labels happen to be rewritten in.
void disambiguateSourceLabels(std::vector<SubtitleSources::Source> &sources) {
  const auto collides = [&sources](std::size_t index) {
    for (std::size_t other = 0; other < sources.size(); ++other) {
      if (other != index && sources[other].label == sources[index].label)
        return true;
    }
    return false;
  };
  std::vector<bool> ambiguous(sources.size(), false);
  for (std::size_t index = 0; index < sources.size(); ++index)
    ambiguous[index] = collides(index);
  for (std::size_t index = 0; index < sources.size(); ++index) {
    // Forced/default are container facts about an embedded track; they mean
    // nothing for a generated caption file or one the user loaded.
    if (!ambiguous[index] ||
        sources[index].origin != SubtitleSources::Origin::Embedded)
      continue;
    if (sources[index].forcedFlag)
      sources[index].label += QStringLiteral(" (Forced)");
    else if (sources[index].defaultFlag)
      sources[index].label += QStringLiteral(" (Default)");
  }
  for (std::size_t index = 0; index < sources.size(); ++index)
    ambiguous[index] = collides(index);
  for (std::size_t index = 0; index < sources.size(); ++index) {
    if (!ambiguous[index])
      continue;
    const int position = static_cast<int>(index) + 1;
    sources[index].label +=
        sources[index].origin == SubtitleSources::Origin::Embedded
            ? QStringLiteral(" (Track %1)").arg(position)
            : QStringLiteral(" (%1)").arg(position);
  }
}

}  // namespace

SubtitleSources::SubtitleSources(QObject *parent) : QObject(parent) {}

SubtitleSources::~SubtitleSources() {
  cancelNativeLoad();
  // The image store is process-wide; a window that goes away must not leave
  // its last caption's pixels retained in it.
  SubtitleBitmapStore::instance().forget(
      static_cast<quint64>(reinterpret_cast<quintptr>(this)));
}

void SubtitleSources::clear() {
  cancelNativeLoad();
  sources_.clear();
  active_id_ = kOffId;
  last_selected_id_ = kOffId;
  next_id_ = 1;
  if (!cues_.empty() || !bitmap_.cues.empty()) {
    cues_.clear();
    clearBitmapCues();
    resetLookupHint();
    emit cuesChanged();
  }
  resetLookupHint();
}

void SubtitleSources::setEmbeddedTracks(std::vector<Source> tracks) {
  // Keep the sidecar sources: a route flip (native -> mpv fallback) rebuilds
  // the embedded list, and losing the captions the user just generated because
  // of it would be a bug they would rightly not forgive.
  //
  // But keep them only if the incoming list does not already have them. On the
  // compatibility route a `sub-add`ed file IS an mpv track, so it comes back in
  // track-list and carrying the old copy forward listed it twice.
  std::vector<Source> kept;
  for (const Source &source : sources_) {
    if (source.origin == Origin::Embedded)
      continue;
    const bool already = std::any_of(
        tracks.begin(), tracks.end(), [&source](const Source &candidate) {
          return !candidate.filePath.empty() &&
                 candidate.filePath == source.filePath;
        });
    if (!already)
      kept.push_back(source);
  }
  sources_ = std::move(tracks);
  for (Source &source : kept)
    sources_.push_back(std::move(source));
  // Ids are the menu's own 1..N ordering, reassigned on every rebuild rather
  // than handed out from a running counter. A running counter made the ids
  // depend on how many times the list happened to be rebuilt -- so the same
  // track was id 1 on a native open and id 2 after a fallback flip, and any
  // id held across that (a scripted selection, a menu item mid-rebuild) named
  // the wrong track or nothing. The caller re-resolves its selection through
  // matches() after this, which is what makes renumbering safe.
  // Before the ids, because Source::matches() compares the label: a selection
  // held across a rebuild must be re-resolved against the same label it was
  // stored with, and the disambiguation is deterministic for a given list.
  disambiguateSourceLabels(sources_);
  next_id_ = 1;
  for (Source &source : sources_)
    source.id = next_id_++;
}

bool SubtitleSources::Source::matches(const Source &other) const noexcept {
  // Identity is what the source IS, never the id it currently holds.
  return origin == other.origin && matroskaTrack == other.matroskaTrack &&
         mp4Track == other.mp4Track && mpvSid == other.mpvSid &&
         closedCaptions == other.closedCaptions &&
         filePath == other.filePath && label == other.label;
}

bool SubtitleSources::hasClosedCaptionsSource() const noexcept {
  return std::any_of(sources_.begin(), sources_.end(),
                     [](const Source &source) { return source.closedCaptions; });
}

void SubtitleSources::addClosedCaptionsSource() {
  if (hasClosedCaptionsSource())
    return;
  Source source;
  source.closedCaptions = true;
  source.origin = Origin::Embedded;
  source.label = QStringLiteral("Closed Captions");
  source.id = next_id_++;
  sources_.push_back(std::move(source));
}

bool SubtitleSources::activeIsClosedCaptions() const noexcept {
  if (!caption_feed_)
    return false;
  const Source *source = find(active_id_);
  return source != nullptr && source->closedCaptions;
}

int SubtitleSources::remap(const Source &previous) const noexcept {
  for (const Source &source : sources_) {
    if (source.matches(previous))
      return source.id;
  }
  return kOffId;
}

int SubtitleSources::addFileSource(const std::filesystem::path &path,
                                   Origin origin, const QString &label,
                                   std::int64_t mpvSid) {
  if (path.empty())
    return kOffId;
  // Adding the same file twice is a re-selection, not a second entry.
  for (const Source &source : sources_) {
    if (source.filePath == path) {
      return source.id;
    }
  }
  Source source;
  source.id = next_id_++;
  source.label = label.isEmpty()
                     ? QString::fromStdString(path.filename().string())
                     : label;
  source.origin = origin;
  source.mpvSid = mpvSid;
  source.filePath = path;
  const int assigned = source.id;
  sources_.push_back(std::move(source));
  // A loaded file can collide with an embedded track's label too (a sidecar
  // literally named "English.srt" next to an unnamed English track). Ids are
  // untouched here, so a live selection keeps naming the same source.
  disambiguateSourceLabels(sources_);
  return assigned;
}

QVariantList SubtitleSources::toVariantList() const {
  QVariantList list;
  list.reserve(static_cast<qsizetype>(sources_.size()));
  for (const Source &source : sources_) {
    QVariantMap entry;
    entry.insert(QStringLiteral("id"), source.id);
    entry.insert(QStringLiteral("label"), source.label);
    entry.insert(QStringLiteral("language"), source.language);
    entry.insert(QStringLiteral("origin"), originName(source.origin));
    entry.insert(QStringLiteral("isDefault"), source.defaultFlag);
    entry.insert(QStringLiteral("isForced"), source.forcedFlag);
    // The menu shows bitmap tracks exactly like text tracks; this flag exists
    // so a future view can distinguish them without re-deriving the codec.
    entry.insert(QStringLiteral("isBitmap"), source.isBitmap());
    list.append(entry);
  }
  return list;
}

const SubtitleSources::Source *SubtitleSources::find(int id) const noexcept {
  for (const Source &source : sources_) {
    if (source.id == id)
      return &source;
  }
  return nullptr;
}

int SubtitleSources::idForMpvSid(std::int64_t sid) const noexcept {
  if (sid <= 0)
    return kOffId;
  for (const Source &source : sources_) {
    if (source.mpvSid == sid)
      return source.id;
  }
  return kOffId;
}

int SubtitleSources::containerPreferredId() const noexcept {
  // Forced first: a forced track exists precisely because the container is
  // asserting the viewer needs it (foreign dialogue in an otherwise
  // same-language film), so it outranks a merely default one.
  for (const Source &source : sources_) {
    if (source.origin == Origin::Embedded && source.forcedFlag)
      return source.id;
  }
  for (const Source &source : sources_) {
    if (source.origin == Origin::Embedded && source.defaultFlag)
      return source.id;
  }
  return kOffId;
}

// ---------------------------------------------------------------------------

void SubtitleSources::cancelNativeLoad() {
  if (cancel_)
    cancel_->store(true, std::memory_order_relaxed);
  if (worker_.joinable())
    worker_.join();
  cancel_.reset();
  setLoading(false);
}

void SubtitleSources::beginNativeLoad(int id) {
  cancelNativeLoad();
  const Source *source = find(id);
  if (source == nullptr)
    return;

  if (source->closedCaptions) {
    // Nothing to load: the cues come from the live feed as the pictures are
    // presented. Any loaded track's cues are dropped so they cannot show
    // through.
    if (!cues_.empty() || !bitmap_.cues.empty()) {
      cues_.clear();
      clearBitmapCues();
      emit cuesChanged();
    }
    resetLookupHint();
    return;
  }
  if (source->matroskaTrack == 0 && source->mp4Track == 0) {
    // A sidecar source on the native route: small, local, and read inline.
    QString error;
    if (!loadFileCues(source->filePath, &error))
      emit loadFailed(error);
    return;
  }

  if (!cues_.empty() || !bitmap_.cues.empty()) {
    cues_.clear();
    clearBitmapCues();
    resetLookupHint();
    emit cuesChanged();
  }

  const std::uint64_t generation = ++generation_;
  auto cancel = std::make_shared<std::atomic<bool>>(false);
  cancel_ = cancel;
  const std::filesystem::path path = source->filePath;
  const std::uint64_t track = source->matroskaTrack;
  const media::subtitles::TextCodec codec = source->codec;
  setLoading(true);

  if (source->mp4Track != 0) {
    // The MP4 tx3g lane. Same worker discipline as the Matroska lanes: one
    // thread, cancelled and joined before it can be replaced, result delivered
    // queued onto the owning thread. The reader opens its own descriptor and
    // never touches the playback source, so a subtitle read cannot perturb
    // decode -- the same rule matroska_subtitles.hpp states and for the same
    // reason.
    const std::uint32_t mp4Track = source->mp4Track;
    worker_ = std::thread([this, generation, path, mp4Track]() {
      media::mp4::SubtitleTrackLoad mp4Load =
          media::mp4::loadMp4SubtitleTrack(path, mp4Track);
      // Restated as the Matroska load the apply path already understands, so
      // the cue lane below stays single-shaped. Style spans are dropped here:
      // the overlay is Text.PlainText by design (see the report's deferrals).
      media::matroska::SubtitleTrackLoad load;
      load.cues = std::move(mp4Load.cues);
      load.ok = mp4Load.ok;
      load.truncated = mp4Load.truncated;
      load.skippedWithoutDuration = mp4Load.skipped;
      load.error = std::move(mp4Load.error);
      QMetaObject::invokeMethod(
          this,
          [this, generation, load = std::move(load)]() mutable {
            applyLoad(generation, std::move(load));
          },
          Qt::QueuedConnection);
    });
    return;
  }

  if (source->isBitmap()) {
    // The bitmap lane. Same worker discipline as the text lane: one thread,
    // cancelled and joined before it can be replaced, result delivered queued
    // onto the owning thread.
    const media::subtitles::BitmapCodec bitmapCodec = source->bitmapCodec;
    worker_ = std::thread([this, generation, path, track, bitmapCodec, cancel]() {
      const media::matroska::CancellationToken token{
          cancel.get(), [](const void *context) noexcept {
            return static_cast<const std::atomic<bool> *>(context)->load(
                std::memory_order_relaxed);
          }};
      media::matroska::BitmapSubtitleTrackLoad load =
          media::matroska::loadMatroskaBitmapSubtitleTrack(path, track,
                                                           bitmapCodec, token);
      QMetaObject::invokeMethod(
          this,
          [this, generation, load = std::move(load)]() mutable {
            applyBitmapLoad(generation, std::move(load));
          },
          Qt::QueuedConnection);
    });
    return;
  }

  worker_ = std::thread([this, generation, path, track, codec, cancel]() {
    const media::matroska::CancellationToken token{
        cancel.get(), [](const void *context) noexcept {
          return static_cast<const std::atomic<bool> *>(context)->load(
              std::memory_order_relaxed);
        }};
    media::matroska::SubtitleTrackLoad load =
        media::matroska::loadMatroskaSubtitleTrack(path, track, codec, token);
    // Queued, so the result lands on the owning thread. `this` stays alive:
    // the destructor cancels and JOINS before it runs, so no delivery can
    // outlive the object.
    QMetaObject::invokeMethod(
        this,
        [this, generation, load = std::move(load)]() mutable {
          applyLoad(generation, std::move(load));
        },
        Qt::QueuedConnection);
  });
}

void SubtitleSources::applyLoad(std::uint64_t generation,
                                media::matroska::SubtitleTrackLoad load) {
  // A newer selection already superseded this one.
  if (generation != generation_)
    return;
  setLoading(false);
  if (load.cancelled)
    return;
  if (!load.ok) {
    emit loadFailed(load.error.empty()
                        ? QStringLiteral("The subtitle track could not be read.")
                        : QString::fromStdString(load.error));
    return;
  }
  cues_ = std::move(load.cues);
  resetLookupHint();
  emit cuesChanged();
}

void SubtitleSources::setLoading(bool loading) {
  if (loading_ == loading)
    return;
  loading_ = loading;
  emit loadingChanged();
}

bool SubtitleSources::loadFileCues(const std::filesystem::path &path,
                                   QString *error) {
  const auto fail = [error](const QString &reason) {
    if (error != nullptr)
      *error = reason;
    return false;
  };
  QFile file(QString::fromStdString(path.string()));
  if (!file.open(QIODevice::ReadOnly))
    return fail(QStringLiteral("The subtitle file could not be opened."));
  if (file.size() > kMaximumSubtitleFileBytes)
    return fail(QStringLiteral("That file is too large to be subtitles."));
  const QByteArray bytes = file.readAll();
  const std::string extension = path.extension().string();
  const media::subtitles::ParsedFile parsed = media::subtitles::parseSubtitleFile(
      std::string_view(bytes.constData(), static_cast<std::size_t>(bytes.size())),
      extension);
  if (parsed.cues.empty()) {
    return fail(parsed.error.empty()
                    ? QStringLiteral("That file contains no subtitles.")
                    : QString::fromStdString(parsed.error));
  }
  cues_ = parsed.cues;
  media::subtitles::finalizeCues(&cues_, false);
  resetLookupHint();
  emit cuesChanged();
  return true;
}

QString SubtitleSources::textAt(double seconds) noexcept {
  if (!std::isfinite(seconds))
    return {};
  const double clamped = std::max(0.0, seconds);
  // Guard the conversion rather than trusting a transport value: a runaway
  // clock must not wrap the multiply.
  if (clamped > 1.0e7)
    return {};
  const auto t = static_cast<std::int64_t>(clamped * kNanosecondsPerSecond);
  if (activeIsClosedCaptions()) {
    // The live feed answers directly; its list changes as pictures go by, so
    // the loaded-cue hint below does not apply to it.
    const std::string text = caption_feed_->textAt(t);
    if (cached_text_ != QString::fromStdString(text))
      cached_text_ = QString::fromStdString(text);
    return cached_text_;
  }
  if (cues_.empty())
    return {};
  const std::ptrdiff_t index = media::subtitles::cueIndexAt(cues_, t, hint_);
  if (index == hint_)
    return cached_text_;
  hint_ = index;
  // Only build the QString when the cue actually turns over. This is called
  // on every published position -- about thirty times a second on the native
  // route -- and converting the same UTF-8 payload again on each of those was
  // an allocation and a decode per frame for a line that had not changed.
  cached_text_ = index < 0 ? QString()
                           : QString::fromStdString(
                                 cues_[static_cast<std::size_t>(index)].text);
  return cached_text_;
}

void SubtitleSources::clearBitmapCues() {
  bitmap_ = {};
  bitmap_active_.clear();
  bitmap_frame_ = BitmapFrame{};
  // Publishing a null image is the overlay's signal that there is nothing to
  // draw, and it releases the last caption's pixels.
  SubtitleBitmapStore::instance().publish(
      static_cast<quint64>(reinterpret_cast<quintptr>(this)), QImage());
}

void SubtitleSources::applyBitmapLoad(
    std::uint64_t generation, media::matroska::BitmapSubtitleTrackLoad load) {
  // A newer selection already superseded this one.
  if (generation != generation_)
    return;
  setLoading(false);
  if (load.cancelled)
    return;
  if (!load.ok) {
    emit loadFailed(load.error.empty()
                        ? QStringLiteral("The subtitle track could not be read.")
                        : QString::fromStdString(load.error));
    return;
  }
  bitmap_ = std::move(load.content);
  bitmap_active_.clear();
  bitmap_frame_ = BitmapFrame{};
  emit cuesChanged();
}

void SubtitleSources::composeBitmapFrame() {
  bitmap_frame_ = BitmapFrame{};
  const auto key = static_cast<quint64>(reinterpret_cast<quintptr>(this));
  if (bitmap_active_.empty() || bitmap_.canvasWidth == 0 ||
      bitmap_.canvasHeight == 0) {
    SubtitleBitmapStore::instance().publish(key, QImage());
    return;
  }

  // The union of the covering cues, so the overlay stays one image and one
  // rectangle however many composition objects the format put on screen.
  std::int64_t left = std::numeric_limits<std::int64_t>::max();
  std::int64_t top = std::numeric_limits<std::int64_t>::max();
  std::int64_t right = std::numeric_limits<std::int64_t>::min();
  std::int64_t bottom = std::numeric_limits<std::int64_t>::min();
  for (const std::size_t index : bitmap_active_) {
    const auto &cue = bitmap_.cues[index];
    left = std::min<std::int64_t>(left, cue.x);
    top = std::min<std::int64_t>(top, cue.y);
    right = std::max<std::int64_t>(right, cue.x + cue.image.width);
    bottom = std::max<std::int64_t>(bottom, cue.y + cue.image.height);
  }
  if (right <= left || bottom <= top) {
    SubtitleBitmapStore::instance().publish(key, QImage());
    return;
  }

  const int width = static_cast<int>(right - left);
  const int height = static_cast<int>(bottom - top);
  QImage canvas(width, height, QImage::Format_ARGB32);
  if (canvas.isNull()) {
    SubtitleBitmapStore::instance().publish(key, QImage());
    return;
  }
  canvas.fill(Qt::transparent);

  std::vector<std::uint32_t> pixels;
  for (const std::size_t index : bitmap_active_) {
    const auto &cue = bitmap_.cues[index];
    if (!media::subtitles::expandToBgra(cue.image, &pixels))
      continue;
    const int originX = static_cast<int>(cue.x - left);
    if (originX < 0 || originX + static_cast<int>(cue.image.width) > width)
      continue;
    for (std::uint32_t row = 0; row < cue.image.height; ++row) {
      const int y = static_cast<int>(cue.y - top) + static_cast<int>(row);
      if (y < 0 || y >= height)
        continue;
      // Straight-alpha 0xAARRGGBB words are exactly QImage::Format_ARGB32, so
      // no per-pixel conversion is needed -- only the transparency test, which
      // keeps a later cue from erasing an earlier one through its holes.
      auto *destination =
          reinterpret_cast<std::uint32_t *>(canvas.scanLine(y)) + originX;
      const std::uint32_t *source =
          pixels.data() + static_cast<std::size_t>(row) * cue.image.width;
      for (std::uint32_t column = 0; column < cue.image.width; ++column) {
        if ((source[column] >> 24) != 0)
          destination[column] = source[column];
      }
    }
  }

  bitmap_frame_.visible = true;
  bitmap_frame_.image = canvas;
  bitmap_frame_.x = static_cast<double>(left) / bitmap_.canvasWidth;
  bitmap_frame_.y = static_cast<double>(top) / bitmap_.canvasHeight;
  bitmap_frame_.width = static_cast<double>(width) / bitmap_.canvasWidth;
  bitmap_frame_.height = static_cast<double>(height) / bitmap_.canvasHeight;
  bitmap_frame_.serial = ++bitmap_serial_;
  SubtitleBitmapStore::instance().publish(key, canvas);
}

const SubtitleSources::BitmapFrame &SubtitleSources::bitmapFrameAt(
    double seconds) {
  const bool usable = !bitmap_.cues.empty() && std::isfinite(seconds) &&
                      seconds < 1.0e7;
  if (!usable) {
    if (!bitmap_active_.empty()) {
      bitmap_active_.clear();
      composeBitmapFrame();
    }
    return bitmap_frame_;
  }
  const auto t = static_cast<std::int64_t>(std::max(0.0, seconds) *
                                           kNanosecondsPerSecond);
  media::subtitles::bitmapCuesAt(bitmap_.cues, t, &bitmap_scratch_);
  // Recompose only on turnover. This runs on every published position -- about
  // thirty times a second -- and compositing an unchanged caption on each of
  // those would be a full-size image allocation per frame.
  if (bitmap_scratch_ == bitmap_active_)
    return bitmap_frame_;
  bitmap_active_ = bitmap_scratch_;
  composeBitmapFrame();
  return bitmap_frame_;
}

}  // namespace wam::qt
