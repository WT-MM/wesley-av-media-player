#include "qt/subtitle_sources.hpp"

#include <QFile>
#include <QFileInfo>
#include <QMetaObject>
#include <QVariantMap>

#include <algorithm>
#include <cmath>
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

}  // namespace

SubtitleSources::SubtitleSources(QObject *parent) : QObject(parent) {}

SubtitleSources::~SubtitleSources() { cancelNativeLoad(); }

void SubtitleSources::clear() {
  cancelNativeLoad();
  sources_.clear();
  active_id_ = kOffId;
  last_selected_id_ = kOffId;
  next_id_ = 1;
  if (!cues_.empty()) {
    cues_.clear();
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
  next_id_ = 1;
  for (Source &source : sources_)
    source.id = next_id_++;
}

bool SubtitleSources::Source::matches(const Source &other) const noexcept {
  // Identity is what the source IS, never the id it currently holds.
  return origin == other.origin && matroskaTrack == other.matroskaTrack &&
         mpvSid == other.mpvSid && filePath == other.filePath &&
         label == other.label;
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
  sources_.push_back(std::move(source));
  return sources_.back().id;
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

  if (source->matroskaTrack == 0) {
    // A sidecar source on the native route: small, local, and read inline.
    QString error;
    if (!loadFileCues(source->filePath, &error))
      emit loadFailed(error);
    return;
  }

  if (!cues_.empty()) {
    cues_.clear();
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
  if (cues_.empty() || !std::isfinite(seconds))
    return {};
  const double clamped = std::max(0.0, seconds);
  // Guard the conversion rather than trusting a transport value: a runaway
  // clock must not wrap the multiply.
  if (clamped > 1.0e7)
    return {};
  const auto t = static_cast<std::int64_t>(clamped * kNanosecondsPerSecond);
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

}  // namespace wam::qt
