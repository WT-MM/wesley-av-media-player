#include "media/matroska_subtitles.hpp"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstring>
#include <optional>

namespace wam::media::matroska {
namespace {

using subtitles::Cue;
using subtitles::TextCodec;

constexpr std::uint64_t kSubtitleTrackType{0x11};
// One text Block. Generous next to a subtitle line, tiny next to a video
// frame, and it bounds what a malformed file can make us allocate per cue.
constexpr std::size_t kMaximumSubtitleBlockBytes{64U * 1024U};

// A pread-backed reader owned by this lane alone. Deliberately NOT the
// demuxer's StableFileReader: that one is private to the playback path and
// carries an identity predicate tuned for a live decode session. This one
// exists so a subtitle read shares no descriptor and no state with playback.
class SubtitleFileReader final : public SeekableByteReader {
 public:
  ~SubtitleFileReader() override {
    if (descriptor_ >= 0)
      ::close(descriptor_);
  }

  [[nodiscard]] static std::unique_ptr<SubtitleFileReader> open(
      const std::filesystem::path& path) noexcept {
    const int descriptor = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (descriptor < 0)
      return nullptr;
    struct ::stat status {};
    if (::fstat(descriptor, &status) != 0 || !S_ISREG(status.st_mode) ||
        status.st_size <= 0) {
      ::close(descriptor);
      return nullptr;
    }
    auto reader = std::unique_ptr<SubtitleFileReader>(new SubtitleFileReader());
    reader->descriptor_ = descriptor;
    reader->size_ = static_cast<std::uint64_t>(status.st_size);
    reader->device_ = status.st_dev;
    reader->inode_ = status.st_ino;
    reader->modified_ = status.st_mtimespec;
    return reader;
  }

  [[nodiscard]] std::uint64_t size() const noexcept override { return size_; }

  [[nodiscard]] bool readAt(std::uint64_t offset,
                            std::span<std::byte> destination) noexcept override {
    if (destination.empty())
      return true;
    if (offset > size_ || destination.size() > size_ - offset)
      return false;
    std::size_t filled = 0;
    while (filled < destination.size()) {
      const ssize_t read = ::pread(
          descriptor_, destination.data() + filled, destination.size() - filled,
          static_cast<off_t>(offset + filled));
      if (read > 0) {
        filled += static_cast<std::size_t>(read);
        continue;
      }
      if (read < 0 && errno == EINTR)
        continue;
      return false;
    }
    return true;
  }

  // dev + ino + size + mtime, matching the identity the demuxer settled on
  // after st_ctime proved to move for xattr and Spotlight writes that change
  // no content byte (see the 2026-08-17 handoff addendum).
  [[nodiscard]] bool unchanged() const noexcept {
    struct ::stat status {};
    if (::fstat(descriptor_, &status) != 0)
      return false;
    return status.st_dev == device_ && status.st_ino == inode_ &&
           static_cast<std::uint64_t>(status.st_size) == size_ &&
           status.st_mtimespec.tv_sec == modified_.tv_sec &&
           status.st_mtimespec.tv_nsec == modified_.tv_nsec;
  }

 private:
  SubtitleFileReader() = default;

  int descriptor_{-1};
  std::uint64_t size_{0};
  dev_t device_{};
  ino_t inode_{};
  struct timespec modified_ {};
};

[[nodiscard]] std::string inlineString(const InlineAscii& value) {
  const auto view = value.view();
  return std::string(view.data(), view.size());
}

// Every TrackEntry the file declares, in file order: the cue pass must hand
// the parser a constraint row for each one (numbers and lacing must match what
// it rediscovers) while selecting exactly one.
struct TrackShape {
  std::uint64_t number{0};
  bool lacingAllowed{true};
};

class HeaderVisitor final : public Visitor {
 public:
  explicit HeaderVisitor(SeekableByteReader& reader) : reader_(reader) {}

  VisitorAction onInfo(const Info& value) noexcept override {
    timestampScaleNanoseconds = value.timestampScaleNanoseconds;
    return VisitorAction::Continue;
  }

  VisitorAction onTrackEntry(const TrackEntry& entry) noexcept override {
    try {
      shapes.push_back(TrackShape{entry.number, entry.lacingAllowed});
      if (entry.type != kSubtitleTrackType)
        return VisitorAction::Continue;
      SubtitleTrackInfo info;
      info.number = entry.number;
      info.codec =
          subtitles::textCodecFromMatroskaCodecId(inlineString(entry.codecId));
      info.language = inlineString(entry.language);
      info.defaultFlag = entry.defaultTrack;
      info.forcedFlag = entry.forced;
      info.enabled = entry.enabled;
      if (entry.name)
        info.name = readText(*entry.name);
      // Bitmap subtitle tracks are counted by neither the menu nor the loader;
      // an unknown text codec is simply not a track this player can show.
      if (subtitles::isTextCodec(info.codec))
        tracks.push_back(std::move(info));
    } catch (...) {
      allocationFailure = true;
      return VisitorAction::Stop;
    }
    return VisitorAction::Continue;
  }

  // The whole point of the header pass: stop before any Cluster is entered.
  VisitorAction onCluster(const Cluster&) noexcept override {
    reachedCluster = true;
    return stopAtFirstCluster ? VisitorAction::Stop : VisitorAction::Continue;
  }

  std::vector<SubtitleTrackInfo> tracks;
  std::vector<TrackShape> shapes;
  std::uint64_t timestampScaleNanoseconds{1'000'000};
  bool reachedCluster{false};
  bool allocationFailure{false};
  bool stopAtFirstCluster{true};

 private:
  [[nodiscard]] std::string readText(ByteRange range) {
    if (range.size == 0 || range.size > MediaSourceLimits::kHardMaximumTrackTextBytes)
      return {};
    std::string text(static_cast<std::size_t>(range.size), '\0');
    if (!reader_.readAt(range.offset,
                        std::as_writable_bytes(std::span<char>(text)))) {
      return {};
    }
    // TrackEntry/Name is a UTF-8 string element; trailing NUL padding is legal.
    while (!text.empty() && text.back() == '\0')
      text.pop_back();
    return text;
  }

  SeekableByteReader& reader_;
};

class CueVisitor final : public Visitor {
 public:
  CueVisitor(SeekableByteReader& reader, std::uint64_t trackNumber,
             TextCodec codec)
      : reader_(reader), trackNumber_(trackNumber), codec_(codec) {}

  VisitorAction onInfo(const Info& value) noexcept override {
    timestampScaleNanoseconds_ = value.timestampScaleNanoseconds;
    return VisitorAction::Continue;
  }

  VisitorAction onTrackEntry(const TrackEntry& entry) noexcept override {
    if (entry.number == trackNumber_)
      defaultDurationNanoseconds_ = entry.defaultDurationNanoseconds;
    return VisitorAction::Continue;
  }

  VisitorAction onCluster(const Cluster& value) noexcept override {
    clusterTimestampTick_ = value.timestamp;
    return VisitorAction::Continue;
  }

  VisitorAction onBlock(const BlockHeader& header,
                        std::span<const FrameRange> frames,
                        const BlockGroupFields& group,
                        std::span<const std::int64_t>) noexcept override {
    if (header.trackNumber != trackNumber_ || frames.empty())
      return VisitorAction::Continue;
    if (!clusterTimestampTick_)
      return VisitorAction::Continue;

    // Ticks are signed on the relative side; a Block may legally precede its
    // Cluster's own timestamp.
    const std::int64_t tick =
        static_cast<std::int64_t>(*clusterTimestampTick_) +
        static_cast<std::int64_t>(header.relativeTimestamp);
    if (tick < 0)
      return VisitorAction::Continue;
    const std::int64_t scale =
        static_cast<std::int64_t>(timestampScaleNanoseconds_);
    if (scale <= 0)
      return VisitorAction::Continue;
    const std::int64_t start = tick * scale;

    // Refuse to show rather than fail: a text Block with no stateable duration
    // has no honest on-screen lifetime, and guessing one puts a stale line
    // over the picture. BlockDuration first (which is why text tracks are
    // muxed as BlockGroups), then the track's DefaultDuration.
    std::int64_t duration = 0;
    if (group.duration) {
      duration = static_cast<std::int64_t>(*group.duration) * scale;
    } else if (defaultDurationNanoseconds_ && *defaultDurationNanoseconds_ > 0) {
      duration = static_cast<std::int64_t>(*defaultDurationNanoseconds_);
    }
    if (duration <= 0) {
      ++skippedWithoutDuration;
      return VisitorAction::Continue;
    }

    // A laced text Block is not a thing any muxer writes; take the first frame
    // and no more, which also bounds this callback's work.
    const ByteRange payload = frames.front().bytes;
    if (payload.size == 0 || payload.size > kMaximumSubtitleBlockBytes)
      return VisitorAction::Continue;

    try {
      if (cues.size() >= subtitles::kMaximumCues ||
          totalTextBytes_ >= subtitles::kMaximumTotalTextBytes) {
        truncated = true;
        return VisitorAction::Stop;
      }
      std::string raw(static_cast<std::size_t>(payload.size), '\0');
      if (!reader_.readAt(payload.offset,
                          std::as_writable_bytes(std::span<char>(raw)))) {
        readFailed = true;
        return VisitorAction::Stop;
      }
      std::string text = subtitles::renderBlockPayload(codec_, raw);
      if (text.empty())
        return VisitorAction::Continue;
      totalTextBytes_ += text.size();
      cues.push_back(Cue{start, start + duration, std::move(text)});
    } catch (...) {
      allocationFailure = true;
      return VisitorAction::Stop;
    }
    return VisitorAction::Continue;
  }

  std::vector<Cue> cues;
  std::uint32_t skippedWithoutDuration{0};
  bool truncated{false};
  bool readFailed{false};
  bool allocationFailure{false};

 private:
  SeekableByteReader& reader_;
  std::uint64_t trackNumber_{0};
  TextCodec codec_{TextCodec::Unknown};
  std::uint64_t timestampScaleNanoseconds_{1'000'000};
  std::optional<std::uint64_t> clusterTimestampTick_;
  std::optional<std::uint64_t> defaultDurationNanoseconds_;
  std::size_t totalTextBytes_{0};
};

}  // namespace

SubtitleTrackInventory inspectMatroskaSubtitleTracks(
    const std::filesystem::path& path, CancellationToken cancellation) noexcept {
  auto reader = SubtitleFileReader::open(path);
  if (!reader)
    return {};
  return inspectMatroskaSubtitleTracks(*reader, cancellation);
}

SubtitleTrackInventory inspectMatroskaSubtitleTracks(
    SeekableByteReader& fileReader, CancellationToken cancellation) noexcept {
  SubtitleTrackInventory inventory;
  SeekableByteReader* reader = &fileReader;

  ParseOptions options;
  // Header-only shape, identical in spirit to the demuxer's pre-admission
  // probe: no Cluster is descended into, so cost is O(header), not O(file).
  options.visitClusterBlocks = false;
  options.scanClusterMetadata = false;

  HeaderVisitor visitor(*reader);
  const ParseOutcome outcome =
      parseDocument(*reader, visitor, options, cancellation);
  if (!outcome.ok() || visitor.allocationFailure)
    return inventory;

  inventory.tracks = std::move(visitor.tracks);
  inventory.valid = true;
  return inventory;
}

SubtitleTrackLoad loadMatroskaSubtitleTrack(const std::filesystem::path& path,
                                            std::uint64_t trackNumber,
                                            subtitles::TextCodec codec,
                                            CancellationToken cancellation) noexcept {
  SubtitleTrackLoad load;
  if (trackNumber == 0 || !subtitles::isTextCodec(codec)) {
    load.error = "no readable subtitle track was requested";
    return load;
  }
  auto file = SubtitleFileReader::open(path);
  if (!file) {
    load.error = "the media file could not be opened for subtitles";
    return load;
  }
  load = loadMatroskaSubtitleTrack(*file, trackNumber, codec, cancellation);
  if (load.ok && !file->unchanged()) {
    load = {};
    load.error = "the media file changed while its subtitles were read";
  }
  return load;
}

SubtitleTrackLoad loadMatroskaSubtitleTrack(SeekableByteReader& fileReader,
                                            std::uint64_t trackNumber,
                                            subtitles::TextCodec codec,
                                            CancellationToken cancellation) noexcept {
  SubtitleTrackLoad load;
  if (trackNumber == 0 || !subtitles::isTextCodec(codec)) {
    load.error = "no readable subtitle track was requested";
    return load;
  }
  SeekableByteReader* reader = &fileReader;

  // Phase 1, cheap: learn every TrackEntry's number and lacing rule so phase 2
  // can hand the parser a constraint table that selects exactly one track.
  // Without it the parser builds its own table with EVERY track selected, and
  // would parse the lacing of every audio and video Block in the file.
  ParseOptions headerOptions;
  headerOptions.visitClusterBlocks = false;
  headerOptions.scanClusterMetadata = false;
  HeaderVisitor headerVisitor(*reader);
  const ParseOutcome headerOutcome =
      parseDocument(*reader, headerVisitor, headerOptions, cancellation);
  if (cancellation.cancelled()) {
    load.cancelled = true;
    return load;
  }
  if (!headerOutcome.ok() || headerVisitor.shapes.empty()) {
    load.error = "the media file's track header could not be read";
    return load;
  }

  std::vector<TrackConstraint> constraints;
  try {
    constraints.reserve(headerVisitor.shapes.size());
    for (const TrackShape& shape : headerVisitor.shapes) {
      TrackConstraint constraint;
      constraint.number = shape.number;
      constraint.lacingAllowed = shape.lacingAllowed;
      constraint.selected = shape.number == trackNumber;
      constraint.maximumBlockBytes =
          constraint.selected ? kMaximumSubtitleBlockBytes : 0;
      constraints.push_back(constraint);
    }
  } catch (...) {
    load.error = "out of memory while preparing the subtitle read";
    return load;
  }

  ParseOptions options;
  options.visitClusterBlocks = true;
  options.scanClusterMetadata = true;
  options.trackConstraints = constraints;
  options.maximumBlockBytes = kMaximumSubtitleBlockBytes;

  CueVisitor visitor(*reader, trackNumber, codec);
  const ParseOutcome outcome =
      parseDocument(*reader, visitor, options, cancellation);
  if (cancellation.cancelled()) {
    load.cancelled = true;
    return load;
  }
  load.skippedWithoutDuration = visitor.skippedWithoutDuration;
  load.truncated = visitor.truncated;
  if (visitor.readFailed || visitor.allocationFailure) {
    load.error = "the subtitle track could not be read";
    return load;
  }
  // A Stop from the truncation guard is an ok() status; only a genuine parse
  // failure with nothing collected is worth refusing.
  if (!outcome.ok() && visitor.cues.empty()) {
    load.error = "the subtitle track could not be parsed";
    return load;
  }
  load.cues = std::move(visitor.cues);
  // Overlapping text cues are not clamped: two speakers can legally share a
  // moment, and the lookup resolves to the later one.
  subtitles::finalizeCues(&load.cues, false);
  load.ok = true;
  return load;
}

}  // namespace wam::media::matroska
