#include "media/matroska_demuxer.hpp"

#include "media/matroska_aac.hpp"
#include "media/video_codec_configuration.hpp"

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <numeric>
#include <optional>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>

namespace wam::media::matroska {
namespace {

constexpr std::size_t kCopyChunkBytes{64U * 1024U};
constexpr std::uint32_t kAacFormatTag{0x61616320U};
constexpr std::uint32_t kMonoLayoutTag{0x00640001U};
constexpr std::uint32_t kStereoLayoutTag{0x00650002U};

[[nodiscard]] std::string inlineString(const InlineAscii& value) {
  const std::span<const char> bytes = value.view();
  return std::string(bytes.begin(), bytes.end());
}

[[nodiscard]] std::optional<MediaTrackId>
trackId(std::uint64_t number) noexcept {
  if (number == 0 || number > std::numeric_limits<MediaTrackId>::max()) {
    return std::nullopt;
  }
  return static_cast<MediaTrackId>(number);
}

[[nodiscard]] std::optional<MediaTime>
timeFromNanosecondsUnsigned(std::uint64_t nanoseconds) noexcept {
  const std::uint64_t divisor = std::gcd(nanoseconds, UINT64_C(1'000'000'000));
  const std::uint64_t numerator = nanoseconds / divisor;
  const std::uint64_t denominator = UINT64_C(1'000'000'000) / divisor;
  if (numerator > static_cast<std::uint64_t>(
                      std::numeric_limits<std::int64_t>::max()) ||
      denominator > static_cast<std::uint64_t>(
                        std::numeric_limits<std::int32_t>::max())) {
    return std::nullopt;
  }
  return MediaTime{static_cast<std::int64_t>(numerator),
                   static_cast<std::int32_t>(denominator)};
}

[[nodiscard]] std::optional<MediaTime>
timeFromSignedTick(std::int64_t tick,
                   std::uint64_t scaleNanoseconds) noexcept {
  const __int128 product = static_cast<__int128>(tick) *
                           static_cast<__int128>(scaleNanoseconds);
  const bool negative = product < 0;
  const unsigned __int128 magnitude = negative
      ? static_cast<unsigned __int128>(-product)
      : static_cast<unsigned __int128>(product);
  const std::uint64_t denominatorBase = UINT64_C(1'000'000'000);
  if (magnitude > std::numeric_limits<std::uint64_t>::max()) {
    return std::nullopt;
  }
  const std::uint64_t rawNumerator = static_cast<std::uint64_t>(magnitude);
  const std::uint64_t divisor = std::gcd(rawNumerator, denominatorBase);
  const std::uint64_t numerator = rawNumerator / divisor;
  const std::uint64_t denominator = denominatorBase / divisor;
  const std::uint64_t maximumMagnitude = negative
      ? static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()) +
            1U
      : static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max());
  if (numerator > maximumMagnitude ||
      denominator > static_cast<std::uint64_t>(
                        std::numeric_limits<std::int32_t>::max())) {
    return std::nullopt;
  }
  std::int64_t signedNumerator = 0;
  if (negative) {
    signedNumerator = numerator == maximumMagnitude
                          ? std::numeric_limits<std::int64_t>::min()
                          : -static_cast<std::int64_t>(numerator);
  } else {
    signedNumerator = static_cast<std::int64_t>(numerator);
  }
  return MediaTime{signedNumerator, static_cast<std::int32_t>(denominator)};
}

[[nodiscard]] std::optional<std::int64_t>
signedBlockTick(std::uint64_t clusterTick, std::int16_t relative) noexcept {
  const __int128 value = static_cast<__int128>(clusterTick) + relative;
  if (value < std::numeric_limits<std::int64_t>::min() ||
      value > std::numeric_limits<std::int64_t>::max()) {
    return std::nullopt;
  }
  return static_cast<std::int64_t>(value);
}

[[nodiscard]] MatroskaDemuxError parseError(ParseOutcome outcome) noexcept {
  if (outcome.status == ParseStatus::Cancelled) {
    return MatroskaDemuxError::Cancelled;
  }
  if (outcome.status == ParseStatus::IoError) {
    return outcome.error == ParseError::FileChanged
               ? MatroskaDemuxError::FileChanged
               : MatroskaDemuxError::Io;
  }
  if (outcome.status == ParseStatus::Unsupported) {
    return MatroskaDemuxError::UnsupportedContainer;
  }
  if (outcome.status == ParseStatus::LimitExceeded) {
    return outcome.error == ParseError::CueLimit
               ? MatroskaDemuxError::IndexLimit
               : MatroskaDemuxError::SampleLimit;
  }
  return MatroskaDemuxError::InvalidContainer;
}

class StableFileReader final : public SeekableByteReader {
 public:
  static std::shared_ptr<StableFileReader>
  open(const std::filesystem::path& path) noexcept {
    const int descriptor = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) {
      return nullptr;
    }
    struct stat facts {};
    if (::fstat(descriptor, &facts) != 0 || facts.st_size < 0 ||
        !S_ISREG(facts.st_mode)) {
      ::close(descriptor);
      return nullptr;
    }
    try {
      return std::shared_ptr<StableFileReader>(
          new StableFileReader(descriptor, facts));
    } catch (...) {
      ::close(descriptor);
      return nullptr;
    }
  }

  ~StableFileReader() override { ::close(descriptor_); }

  [[nodiscard]] std::uint64_t size() const noexcept override {
    return size_;
  }

  [[nodiscard]] bool readAt(
      std::uint64_t offset,
      std::span<std::byte> destination) noexcept override {
    if (destination.empty()) {
      return offset <= size_;
    }
    if (offset > size_ || destination.size() > size_ - offset ||
        offset > static_cast<std::uint64_t>(
                     std::numeric_limits<off_t>::max())) {
      return false;
    }
    std::size_t copied = 0;
    while (copied < destination.size()) {
      const std::uint64_t current = offset + copied;
      if (current > static_cast<std::uint64_t>(
                        std::numeric_limits<off_t>::max())) {
        return false;
      }
      const ssize_t result = ::pread(
          descriptor_, destination.data() + copied, destination.size() - copied,
          static_cast<off_t>(current));
      if (result < 0 && errno == EINTR) {
        continue;
      }
      if (result <= 0) {
        return false;
      }
      copied += static_cast<std::size_t>(result);
    }
    return true;
  }

  [[nodiscard]] bool unchanged() const noexcept {
    struct stat facts {};
    return ::fstat(descriptor_, &facts) == 0 && facts.st_size >= 0 &&
           facts.st_dev == device_ && facts.st_ino == inode_ &&
           static_cast<std::uint64_t>(facts.st_size) == size_ &&
           facts.st_mtimespec.tv_sec == modifiedSeconds_ &&
           facts.st_mtimespec.tv_nsec == modifiedNanoseconds_ &&
           facts.st_ctimespec.tv_sec == changedSeconds_ &&
           facts.st_ctimespec.tv_nsec == changedNanoseconds_;
  }

 private:
  StableFileReader(int descriptor, const struct stat& facts) noexcept
      : descriptor_(descriptor), size_(static_cast<std::uint64_t>(facts.st_size)),
        device_(facts.st_dev), inode_(facts.st_ino),
        modifiedSeconds_(facts.st_mtimespec.tv_sec),
        modifiedNanoseconds_(facts.st_mtimespec.tv_nsec),
        changedSeconds_(facts.st_ctimespec.tv_sec),
        changedNanoseconds_(facts.st_ctimespec.tv_nsec) {}

  int descriptor_{-1};
  std::uint64_t size_{0};
  dev_t device_{};
  ino_t inode_{};
  time_t modifiedSeconds_{};
  long modifiedNanoseconds_{};
  time_t changedSeconds_{};
  long changedNanoseconds_{};
};

struct CollectedDocument final : Visitor {
  explicit CollectedDocument(std::size_t maximumTracks,
                             std::size_t maximumCues) {
    tracks.reserve(maximumTracks);
    clusters.reserve(kMaximumMatroskaClusters);
    cuePositions.reserve(maximumCues);
  }

  VisitorAction onEbmlHeader(const EbmlHeader& value) noexcept override {
    header = value;
    ++headerCount;
    return VisitorAction::Continue;
  }
  VisitorAction onSegment(const SegmentInfo& value) noexcept override {
    segment = value;
    ++segmentCount;
    return VisitorAction::Continue;
  }
  VisitorAction onInfo(const Info& value) noexcept override {
    info = value;
    ++infoCount;
    return VisitorAction::Continue;
  }
  VisitorAction onTrackEntry(const TrackEntry& value) noexcept override {
    try {
      tracks.push_back(value);
      return VisitorAction::Continue;
    } catch (...) {
      allocationFailure = true;
      return VisitorAction::Reject;
    }
  }
  VisitorAction onCluster(const Cluster& value) noexcept override {
    try {
      if (clusters.empty() ||
          clusters.back().encoded.offset != value.encoded.offset) {
        clusters.push_back(value);
      }
      return VisitorAction::Continue;
    } catch (...) {
      allocationFailure = true;
      return VisitorAction::Reject;
    }
  }
  VisitorAction
  onCueTrackPosition(const CueTrackPosition& value) noexcept override {
    try {
      cuePositions.push_back(value);
      return VisitorAction::Continue;
    } catch (...) {
      allocationFailure = true;
      return VisitorAction::Reject;
    }
  }
  VisitorAction onChapterFeatures(const ChapterFeatures& value) noexcept override {
    chapters = value;
    return VisitorAction::Continue;
  }
  VisitorAction onDocumentSummary(const DocumentSummary& value) noexcept override {
    summary = value;
    return VisitorAction::Continue;
  }

  std::optional<EbmlHeader> header;
  std::optional<SegmentInfo> segment;
  std::optional<Info> info;
  std::optional<ChapterFeatures> chapters;
  std::optional<DocumentSummary> summary;
  std::vector<TrackEntry> tracks;
  std::vector<Cluster> clusters;
  std::vector<CueTrackPosition> cuePositions;
  std::size_t headerCount{0};
  std::size_t segmentCount{0};
  std::size_t infoCount{0};
  bool allocationFailure{false};
};

struct TrackRuntime {
  TrackEntry entry;
  MediaTrackId id{0};
  MediaTrackKind kind{MediaTrackKind::Metadata};
  MediaCodec codec{MediaCodec::Unknown};
  std::uint32_t audioSampleRate{0};
};

struct AssetState {
  std::shared_ptr<SeekableByteReader> reader;
  std::shared_ptr<StableFileReader> localReader;
  std::uint64_t readerSize{0};
  std::filesystem::path path;
  MediaSourceLimits limits;
  std::shared_ptr<const MediaSourceDescriptor> descriptor;
  std::uint64_t timestampScaleNanoseconds{1'000'000};
  std::vector<TrackConstraint> constraints;
  TrackRuntime video;
  std::optional<TrackRuntime> audio;
  std::vector<MatroskaClusterIndexEntry> clusters;
  std::vector<MatroskaCueIndexEntry> cues;

  [[nodiscard]] bool unchanged() const noexcept {
    return reader != nullptr && reader->size() == readerSize &&
           (localReader == nullptr || localReader->unchanged());
  }
};

[[nodiscard]] ParseOptions parserOptions(
    const AssetState& state,
    std::span<const TrackConstraint> constraints) noexcept {
  ParseOptions options;
  options.maximumReadBytes = ParseOptions::kHardMaximumReadBytes;
  options.maximumTracks = state.limits.maximumTracks;
  options.maximumCodecPrivateBytes =
      state.limits.maximumCodecConfigurationBytes;
  options.maximumBlockBytes = std::max(state.limits.maximumVideoSampleBytes,
                                       state.limits.maximumAudioSampleBytes);
  options.maximumEncodedBlockBytes = kMaximumMatroskaEncodedBlockBytes;
  options.maximumTrackTextBytes = state.limits.maximumTrackTextBytes;
  options.maximumLaceFrames = std::min(
      ParseOptions::kHardMaximumLaceFrames,
      state.limits.maximumAudioSampleCount);
  options.maximumCues = kMaximumMatroskaCues;
  options.trackConstraints = constraints;
  return options;
}

// A muxer does not have to land AAC Blocks exactly on the access-unit grid.
// FFmpeg writes each Block's timestamp relative to its Cluster and rounds both
// values independently, so a 48 kHz stream in a 1 ms timebase legitimately
// reports ticks 0, 21, 42, 64, 85, 106 where the exact grid is 0, 21, 43, 64,
// 85, 107. Demanding an exact requantization match rejected essentially every
// real AAC-in-Matroska file for being one tick off.
//
// One tick of container jitter is the most double rounding can introduce, so
// admit that and no more. This does not weaken timing: presentation times are
// still reconstructed from the exact ordinal grid rather than the container
// tick, and the ordinal-continuity check at the cursor remains strict, so a
// genuinely misplaced Block (off by whole access units, ~21 ticks here) is
// still rejected.
inline constexpr std::int64_t kMaximumAacGridTickResidual{1};

// Whole AAC access units staged before the first audible frame of a non-origin
// generation. Two is what the decoder needs to reach full precision, and it is
// the same preroll the AVFoundation backend places for the identical reason.
inline constexpr std::uint64_t kAacPrimingAccessUnits{2};

[[nodiscard]] bool aacProjectionOnGrid(
    const std::optional<AacTickGridProjection>& projection) noexcept {
  if (!projection) {
    return false;
  }
  if (projection->exactTickMatch) {
    return true;
  }
  const std::int64_t residual = projection->signedTickResidual;
  return residual >= -kMaximumAacGridTickResidual &&
         residual <= kMaximumAacGridTickResidual;
}

[[nodiscard]] bool readRange(SeekableByteReader& reader, ByteRange range,
                             std::vector<std::byte>* bytes,
                             CancellationToken cancellation) {
  if (range.size > std::numeric_limits<std::size_t>::max()) {
    return false;
  }
  try {
    bytes->resize(static_cast<std::size_t>(range.size));
  } catch (...) {
    return false;
  }
  std::size_t copied = 0;
  while (copied < bytes->size()) {
    if (cancellation.cancelled()) {
      return false;
    }
    const std::size_t amount =
        std::min(kCopyChunkBytes, bytes->size() - copied);
    if (!reader.readAt(range.offset + copied,
                       std::span<std::byte>(*bytes).subspan(copied, amount))) {
      return false;
    }
    copied += amount;
  }
  return !cancellation.cancelled();
}

[[nodiscard]] bool isVideoCodec(std::string_view id) noexcept {
  return id == "V_MPEG4/ISO/AVC" || id == "V_MPEGH/ISO/HEVC";
}

[[nodiscard]] bool isAudioCodec(std::string_view id) noexcept {
  return id == "A_AAC";
}

[[nodiscard]] const TrackEntry* chooseTrack(
    const std::vector<TrackEntry>& tracks, std::uint64_t type,
    std::optional<MediaTrackId> preferred) noexcept {
  const auto admitted = [type](const TrackEntry& track) {
    const std::string_view codec(track.codecId.view().data(),
                                 track.codecId.view().size());
    return track.enabled && track.type == type && trackId(track.number) &&
           (type == 1 ? isVideoCodec(codec) : isAudioCodec(codec));
  };
  if (preferred) {
    const auto found = std::find_if(
        tracks.begin(), tracks.end(), [preferred, &admitted](const TrackEntry& t) {
          return t.number == *preferred && admitted(t);
        });
    return found == tracks.end() ? nullptr : &*found;
  }
  const auto preferredDefault = std::find_if(
      tracks.begin(), tracks.end(), [&admitted](const TrackEntry& track) {
        return track.defaultTrack && admitted(track);
      });
  if (preferredDefault != tracks.end()) {
    return &*preferredDefault;
  }
  const auto first = std::find_if(tracks.begin(), tracks.end(), admitted);
  return first == tracks.end() ? nullptr : &*first;
}

[[nodiscard]] bool selectedTrackFeaturesSupported(
    const TrackEntry& track) noexcept {
  return track.timestampScale == 1.0 && !track.timestampOffsetPresent &&
         track.codecDelayNanoseconds == 0 && track.seekPreRollNanoseconds == 0 &&
         !track.contentEncodingsPresent && !track.trackOperationPresent &&
         !track.blockAdditionMappingPresent;
}

[[nodiscard]] MediaTrackKind inventoryKind(std::uint64_t type) noexcept {
  if (type == 1) {
    return MediaTrackKind::Video;
  }
  if (type == 2) {
    return MediaTrackKind::Audio;
  }
  if (type == 0x11) {
    return MediaTrackKind::Subtitle;
  }
  return MediaTrackKind::Metadata;
}

void incrementInventory(MediaTrackInventory* inventory,
                        MediaTrackKind kind) noexcept {
  auto increment = [](std::uint8_t* value) {
    if (*value != std::numeric_limits<std::uint8_t>::max()) {
      ++*value;
    }
  };
  switch (kind) {
  case MediaTrackKind::Video:
    increment(&inventory->video);
    break;
  case MediaTrackKind::Audio:
    increment(&inventory->audio);
    break;
  case MediaTrackKind::Subtitle:
    increment(&inventory->subtitle);
    break;
  case MediaTrackKind::Text:
    increment(&inventory->text);
    break;
  case MediaTrackKind::ClosedCaption:
    increment(&inventory->closedCaption);
    break;
  case MediaTrackKind::Metadata:
    increment(&inventory->metadata);
    break;
  }
  increment(&inventory->total);
}

[[nodiscard]] std::optional<MediaTime>
trackDuration(const Info& info) noexcept {
  if (!info.durationTicks || !std::isfinite(*info.durationTicks) ||
      *info.durationTicks < 0.0) {
    return std::nullopt;
  }
  // Matroska stores Duration as a float tick count measured in TimestampScale
  // units. Converting it to seconds first destroys exactness: a real 72.021 s
  // file becomes a binary64 whose exact rational needs a 2^46 denominator,
  // which no longer fits MediaTime's int32 timescale, so the conversion fails
  // closed and the whole container is rejected. Essentially every real file
  // has a duration that is not a binary-exact number of seconds.
  //
  // Build the exact nanosecond rational instead and reduce it. Wherever the
  // seconds path already succeeded this yields the identical reduced value,
  // so this is strictly a widening of what is admitted.
  const double ticks = *info.durationTicks;
  double integralTicks = 0.0;
  if (std::modf(ticks, &integralTicks) == 0.0 &&
      integralTicks <=
          static_cast<double>(std::numeric_limits<std::int64_t>::max())) {
    const auto wholeTicks = static_cast<std::int64_t>(integralTicks);
    const auto scale = static_cast<std::int64_t>(
        info.timestampScaleNanoseconds);
    constexpr std::int64_t kNanosecondsPerSecond{1'000'000'000};
    if (scale > 0) {
      const auto nanoseconds =
          static_cast<__int128>(wholeTicks) * static_cast<__int128>(scale);
      if (nanoseconds <=
          static_cast<__int128>(std::numeric_limits<std::int64_t>::max())) {
        auto numerator = static_cast<std::int64_t>(nanoseconds);
        auto denominator = kNanosecondsPerSecond;
        const std::int64_t divisor =
            std::gcd(numerator == 0 ? denominator : numerator, denominator);
        if (divisor > 0) {
          numerator /= divisor;
          denominator /= divisor;
        }
        if (denominator > 0 &&
            denominator <= std::numeric_limits<std::int32_t>::max()) {
          return MediaTime{numerator,
                           static_cast<std::int32_t>(denominator)};
        }
      }
    }
  }
  // Fractional or out-of-range tick counts keep the original conservative
  // seconds conversion, which still fails closed when it cannot be exact.
  return exactNonnegativeMediaTime(
      ticks * (static_cast<double>(info.timestampScaleNanoseconds) / 1.0e9));
}

[[nodiscard]] bool makeVideoDescriptor(
    SeekableByteReader& reader, const TrackEntry& entry,
    const MediaSourceLimits& limits, MediaTime duration,
    CancellationToken cancellation, MediaTrackDescriptor* result,
    TrackRuntime* runtime) {
  if (!entry.video || !entry.codecPrivate ||
      !selectedTrackFeaturesSupported(entry)) {
    return false;
  }
  const auto id = trackId(entry.number);
  if (!id) {
    return false;
  }
  const std::string codecId = inlineString(entry.codecId);
  const MediaCodec codec = codecId == "V_MPEG4/ISO/AVC"
                               ? MediaCodec::H264
                               : codecId == "V_MPEGH/ISO/HEVC"
                                     ? MediaCodec::Hevc
                                     : MediaCodec::Unknown;
  const MediaCodecConfigurationKind kind =
      codec == MediaCodec::H264 ? MediaCodecConfigurationKind::AvcC
                                : MediaCodecConfigurationKind::HvcC;
  // FlagInterlaced 0 (undetermined) and 2 (progressive) are the only values a
  // progressive-only v1 renderer can admit; 1 is interlaced content.
  if (codec == MediaCodec::Unknown ||
      (entry.video->interlaced != 0 && entry.video->interlaced != 2) ||
      entry.video->stereoMode != 0 || entry.video->alphaMode != 0 ||
      entry.video->projectionPresent ||
      entry.video->colour.masteringMetadataPresent ||
      entry.video->colour.maximumContentLightLevel ||
      entry.video->colour.maximumFrameAverageLightLevel) {
    return false;
  }
  std::vector<std::byte> configuration;
  if (!readRange(reader, *entry.codecPrivate, &configuration, cancellation)) {
    return false;
  }
  VideoCodecConfigurationLimits codecLimits;
  codecLimits.maximumConfigurationBytes = limits.maximumCodecConfigurationBytes;
  codecLimits.maximumWidth = limits.maximumCodedWidth;
  codecLimits.maximumHeight = limits.maximumCodedHeight;
  codecLimits.maximumPixels = limits.maximumCodedPixels;
  const auto inspection = inspectVideoCodecConfiguration(
      codec, kind, configuration, codecLimits);
  if (!inspection.admitted()) {
    return false;
  }
  const VideoCodecConfigurationFacts& facts = *inspection.facts;
  if (!entry.video->pixelWidth || !entry.video->pixelHeight ||
      *entry.video->pixelWidth != facts.width ||
      *entry.video->pixelHeight != facts.height ||
      entry.video->cropTop != 0 || entry.video->cropBottom != 0 ||
      entry.video->cropLeft != 0 || entry.video->cropRight != 0 ||
      entry.video->displayUnit != 0 ||
      (entry.video->displayWidth &&
       *entry.video->displayWidth != facts.width) ||
      (entry.video->displayHeight &&
       *entry.video->displayHeight != facts.height)) {
    return false;
  }

  MediaVideoFormat format;
  format.codedWidth = facts.width;
  format.codedHeight = facts.height;
  format.displayWidth = facts.width;
  format.displayHeight = facts.height;
  format.bitsPerComponent = facts.bitDepth;
  format.progressive = true;
  format.sampleFormat = facts.sampleFormat;
  if (facts.color.colorDescriptionPresent) {
    // ISO/IEC 23091-2 value 2 is "unspecified", which carries no color
    // information at all and is therefore Unknown, not OtherExplicit.
    // OtherExplicit means "an explicit value this renderer does not support"
    // and is a fallback proof; mapping unspecified onto it made every stream
    // with a partial VUI (an explicit matrix but unspecified primaries and
    // transfer, which is what encoders commonly emit) fail consumer
    // configuration even though it carries no unsupported metadata.
    format.colorPrimaries =
        facts.color.colorPrimaries == 1   ? MediaColorPrimaries::Bt709
        : facts.color.colorPrimaries == 2 ? MediaColorPrimaries::Unknown
                                          : MediaColorPrimaries::OtherExplicit;
    format.transferFunction =
        facts.color.transferCharacteristics == 1
            ? MediaTransferFunction::Bt709
        : facts.color.transferCharacteristics == 2
            ? MediaTransferFunction::Unknown
            : MediaTransferFunction::OtherExplicit;
    format.matrixCoefficients =
        facts.color.matrixCoefficients == 1   ? MediaMatrixCoefficients::Bt709
        : facts.color.matrixCoefficients == 2 ? MediaMatrixCoefficients::Unknown
                                              : MediaMatrixCoefficients::
                                                    OtherExplicit;
  }
  const VideoColour& colour = entry.video->colour;
  if (colour.primaries) {
    if (*colour.primaries != 1) {
      return false;
    }
    format.colorPrimaries = MediaColorPrimaries::Bt709;
  }
  if (colour.transferCharacteristics) {
    if (*colour.transferCharacteristics != 1) {
      return false;
    }
    format.transferFunction = MediaTransferFunction::Bt709;
  }
  if (colour.matrixCoefficients) {
    if (*colour.matrixCoefficients != 1) {
      return false;
    }
    format.matrixCoefficients = MediaMatrixCoefficients::Bt709;
  }

  result->id = *id;
  result->kind = MediaTrackKind::Video;
  result->codec = codec;
  result->timeBase = MediaTime{1, 1'000'000'000};
  result->duration = duration;
  result->language = inlineString(entry.language);
  result->codecConfigurationKind = kind;
  result->codecConfiguration = std::move(configuration);
  result->video = format;
  runtime->entry = entry;
  runtime->id = *id;
  runtime->kind = MediaTrackKind::Video;
  runtime->codec = codec;
  return true;
}

[[nodiscard]] bool makeAudioDescriptor(
    SeekableByteReader& reader, const TrackEntry& entry,
    const MediaSourceLimits& limits, MediaTime duration,
    CancellationToken cancellation, MediaTrackDescriptor* result,
    TrackRuntime* runtime) {
  if (!entry.audio || !entry.codecPrivate ||
      !selectedTrackFeaturesSupported(entry)) {
    return false;
  }
  const auto id = trackId(entry.number);
  if (!id || inlineString(entry.codecId) != "A_AAC") {
    return false;
  }
  std::vector<std::byte> configuration;
  if (!readRange(reader, *entry.codecPrivate, &configuration, cancellation)) {
    return false;
  }
  const AacLcAdmission admission =
      parseAacLcAudioSpecificConfig(configuration);
  // OutputSamplingFrequency must stay absent: a differing output rate signals
  // SBR/HE-AAC, which is outside the AAC-LC envelope this source decodes.
  //
  // BitDepth is deliberately NOT a rejection. Matroska defines it for PCM; for
  // a compressed AAC track it is informational and has no effect on the
  // bitstream, the ASC, or the ES_Descriptor cookie built below. FFmpeg writes
  // BitDepth=32 on every AAC track it muxes (reflecting float decoder output),
  // so rejecting its presence rejected essentially all real AAC-in-Matroska
  // while the identical stream was admitted from MP4.
  if (!admission.admitted() ||
      admission.configuration->sampleRate > limits.maximumAudioSampleRate ||
      admission.configuration->channelCount > limits.maximumAudioChannels ||
      entry.audio->samplingFrequency !=
          static_cast<double>(admission.configuration->sampleRate) ||
      entry.audio->channels != admission.configuration->channelCount ||
      entry.audio->outputSamplingFrequency) {
    return false;
  }
  const auto cookie = buildAacLcEsDescriptorCookie(*admission.configuration);
  if (!cookie) {
    return false;
  }
  result->id = *id;
  result->kind = MediaTrackKind::Audio;
  result->codec = MediaCodec::Aac;
  result->timeBase =
      MediaTime{1, static_cast<std::int32_t>(admission.configuration->sampleRate)};
  result->duration = duration;
  result->language = inlineString(entry.language);
  result->codecConfigurationKind =
      MediaCodecConfigurationKind::AudioMagicCookie;
  result->codecConfiguration.assign(cookie->view().begin(), cookie->view().end());
  MediaAudioFormat format;
  format.sampleRate = admission.configuration->sampleRate;
  format.channels = admission.configuration->channelCount;
  format.formatTag = kAacFormatTag;
  format.framesPerPacket = kAacLcSamplesPerAccessUnit;
  format.channelLayoutTag = admission.configuration->channelCount == 1
                                ? kMonoLayoutTag
                                : kStereoLayoutTag;
  format.channelLayoutPresent = true;
  result->audio = format;
  runtime->entry = entry;
  runtime->id = *id;
  runtime->kind = MediaTrackKind::Audio;
  runtime->codec = MediaCodec::Aac;
  runtime->audioSampleRate = admission.configuration->sampleRate;
  return true;
}

struct CapturedBlockVisitor final : Visitor {
  VisitorAction onBlock(const BlockHeader& value,
                        std::span<const FrameRange> frameValues,
                        const BlockGroupFields& groupValues,
                        std::span<const std::int64_t> referenceValues) noexcept override {
    header = value;
    group = groupValues;
    referenceCount = referenceValues.size();
    frameCount = static_cast<std::uint16_t>(frameValues.size());
    std::copy(frameValues.begin(), frameValues.end(), frames.begin());
    emitted = true;
    return VisitorAction::Continue;
  }

  BlockHeader header;
  BlockGroupFields group;
  std::array<FrameRange, ParseOptions::kHardMaximumLaceFrames> frames{};
  std::size_t referenceCount{0};
  std::uint16_t frameCount{0};
  bool emitted{false};
};

[[nodiscard]] std::vector<TrackConstraint>
cursorConstraints(const AssetState& state, MediaTrackId selected) {
  std::vector<TrackConstraint> result = state.constraints;
  for (TrackConstraint& constraint : result) {
    constraint.selected = constraint.number == selected;
    if (constraint.selected) {
      constraint.maximumBlockBytes =
          selected == state.video.id ? state.limits.maximumVideoSampleBytes
                                     : state.limits.maximumAudioSampleBytes;
    }
  }
  return result;
}

[[nodiscard]] bool blockFeaturesSupported(
    const CapturedBlockVisitor& block) noexcept {
  return !block.group.codecState && !block.group.discardPaddingNanoseconds &&
         !block.group.blockAdditionsPresent;
}

[[nodiscard]] bool clusterRangeValid(
    const Cluster& cluster, MatroskaClusterIndexEntry* output) noexcept {
  if (!cluster.timestamp || cluster.encoded.size > kMaximumMatroskaClusterBytes ||
      cluster.encoded.size > std::numeric_limits<std::uint32_t>::max() ||
      cluster.data.offset < cluster.encoded.offset ||
      cluster.data.offset - cluster.encoded.offset >
          std::numeric_limits<std::uint16_t>::max() ||
      cluster.data.size > cluster.encoded.size -
                              (cluster.data.offset - cluster.encoded.offset)) {
    return false;
  }
  output->encodedOffset = cluster.encoded.offset;
  output->timestampTick = *cluster.timestamp;
  output->encodedSize = static_cast<std::uint32_t>(cluster.encoded.size);
  output->dataOffsetDelta = static_cast<std::uint16_t>(
      cluster.data.offset - cluster.encoded.offset);
  output->flags = cluster.unknownSize ? 1U : 0U;
  return true;
}

[[nodiscard]] std::optional<std::uint32_t>
findCluster(const std::vector<MatroskaClusterIndexEntry>& clusters,
            std::uint64_t encodedOffset) noexcept {
  const auto found = std::lower_bound(
      clusters.begin(), clusters.end(), encodedOffset,
      [](const MatroskaClusterIndexEntry& entry, std::uint64_t value) {
        return entry.encodedOffset < value;
      });
  if (found == clusters.end() || found->encodedOffset != encodedOffset) {
    return std::nullopt;
  }
  return static_cast<std::uint32_t>(found - clusters.begin());
}

struct ScanResult {
  MatroskaDemuxError error{MatroskaDemuxError::None};
  std::optional<CapturedBlockVisitor> block;
  std::uint32_t clusterIndex{0};
};

template <typename Predicate>
[[nodiscard]] ScanResult scanTrack(
    const AssetState& state, MediaTrackId track, std::uint32_t firstCluster,
    std::uint32_t maximumClusters, Predicate&& predicate,
    CancellationToken cancellation) {
  ScanResult result;
  std::vector<TrackConstraint> constraints = cursorConstraints(state, track);
  ParseOptions options = parserOptions(state, constraints);
  const std::size_t end = std::min<std::size_t>(
      state.clusters.size(), static_cast<std::size_t>(firstCluster) + maximumClusters);
  for (std::size_t clusterIndex = firstCluster; clusterIndex < end;
       ++clusterIndex) {
    if (cancellation.cancelled()) {
      result.error = MatroskaDemuxError::Cancelled;
      return result;
    }
    const ByteRange data = state.clusters[clusterIndex].dataRange();
    auto cursor = beginClusterChildCursor(*state.reader, data, options);
    if (!cursor) {
      result.error = MatroskaDemuxError::InvalidContainer;
      return result;
    }
    while (!cursor->done()) {
      CapturedBlockVisitor visitor;
      const ParseOutcome outcome = parseClusterChildAt(
          *state.reader, *cursor, visitor, options, cancellation);
      if (!outcome.ok()) {
        result.error = parseError(outcome);
        return result;
      }
      if (visitor.emitted && predicate(
                                 static_cast<std::uint32_t>(clusterIndex),
                                 visitor)) {
        result.block = visitor;
        result.clusterIndex = static_cast<std::uint32_t>(clusterIndex);
        return result;
      }
    }
  }
  return result;
}

}  // namespace

struct MatroskaPreparedAsset::Impl {
  explicit Impl(std::shared_ptr<AssetState> value) : state(std::move(value)) {}
  std::shared_ptr<AssetState> state;
};

struct MatroskaCursor::Impl {
  std::shared_ptr<const AssetState> state;
  MediaTrackId track{0};
  bool video{false};
  std::uint32_t clusterIndex{0};
  std::uint64_t startBlockOffset{0};
  std::uint16_t startFrameIndex{0};
  std::uint64_t expectedAudioOrdinal{0};
  bool startFound{false};
  bool ended{false};
  std::vector<TrackConstraint> constraints;
  ParseOptions options;
  std::optional<ClusterChildCursor> clusterCursor;
};

MatroskaCursor::MatroskaCursor(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}
MatroskaCursor::~MatroskaCursor() = default;
MatroskaCursor::MatroskaCursor(MatroskaCursor&&) noexcept = default;
MatroskaCursor& MatroskaCursor::operator=(MatroskaCursor&&) noexcept = default;

MatroskaCursorReadResult
MatroskaCursor::readNext(CancellationToken cancellation) noexcept {
  try {
    if (impl_ == nullptr || impl_->state == nullptr) {
      return MatroskaCursorFailure{MatroskaDemuxError::InvalidRequest,
                                   "cursor is not initialized"};
    }
    if (impl_->ended) {
      return MatroskaCursorEnd{};
    }
    if (cancellation.cancelled()) {
      return MatroskaCursorCancelled{};
    }
    const AssetState& state = *impl_->state;
    if (!state.unchanged()) {
      return MatroskaCursorFailure{MatroskaDemuxError::FileChanged,
                                   "Matroska file changed"};
    }

    while (impl_->clusterIndex < state.clusters.size()) {
      if (!impl_->clusterCursor) {
        auto clusterCursor = beginClusterChildCursor(
            *state.reader, state.clusters[impl_->clusterIndex].dataRange(),
            impl_->options);
        if (!clusterCursor) {
          return MatroskaCursorFailure{MatroskaDemuxError::InvalidContainer,
                                       "invalid Cluster data range"};
        }
        impl_->clusterCursor.emplace(std::move(*clusterCursor));
      }
      while (!impl_->clusterCursor->done()) {
        CapturedBlockVisitor visitor;
        const ParseOutcome outcome = parseClusterChildAt(
            *state.reader, *impl_->clusterCursor, visitor, impl_->options,
            cancellation);
        if (!outcome.ok()) {
          const MatroskaDemuxError error = parseError(outcome);
          if (error == MatroskaDemuxError::Cancelled) {
            return MatroskaCursorCancelled{};
          }
          return MatroskaCursorFailure{error, "Cluster child parse failed"};
        }
        if (!visitor.emitted) {
          continue;
        }
        if (!impl_->startFound) {
          if (visitor.header.containerEncoded.offset < impl_->startBlockOffset) {
            continue;
          }
          if (visitor.header.containerEncoded.offset != impl_->startBlockOffset) {
            return MatroskaCursorFailure{MatroskaDemuxError::InvalidCue,
                                         "generation block was not found"};
          }
          impl_->startFound = true;
        }
        if (!blockFeaturesSupported(visitor)) {
          return MatroskaCursorFailure{MatroskaDemuxError::UnsupportedTrack,
                                       "unsupported BlockGroup feature"};
        }
        const auto tick = signedBlockTick(
            state.clusters[impl_->clusterIndex].timestampTick,
            visitor.header.relativeTimestamp);
        if (!tick) {
          return MatroskaCursorFailure{MatroskaDemuxError::InvalidTimeline,
                                       "block timestamp overflow"};
        }

        MatroskaCompressedSample sample;
        sample.track = impl_->track;
        sample.kind = impl_->video ? MediaSampleKind::EncodedVideo
                                   : MediaSampleKind::EncodedAudio;
        sample.invisible = visitor.header.invisible;
        sample.discardable = visitor.header.discardable;
        if (impl_->video) {
          if (visitor.frameCount != 1 || visitor.header.lacing != Lacing::None) {
            return MatroskaCursorFailure{MatroskaDemuxError::UnsupportedTrack,
                                         "video lacing is not supported"};
          }
          sample.frames[0] = visitor.frames[0];
          sample.frameCount = 1;
          sample.aggregateBytes =
              static_cast<std::size_t>(visitor.frames[0].bytes.size);
          const auto presentation =
              timeFromSignedTick(*tick, state.timestampScaleNanoseconds);
          if (!presentation || presentation->value < 0) {
            return MatroskaCursorFailure{MatroskaDemuxError::InvalidTimeline,
                                         "invalid video presentation time"};
          }
          sample.presentationTime = *presentation;
          sample.keyFrame = visitor.header.simpleBlock
                                ? visitor.header.keyFrame
                                : visitor.referenceCount == 0;
          if (visitor.group.duration) {
            const auto duration = timeFromSignedTick(
                static_cast<std::int64_t>(*visitor.group.duration),
                state.timestampScaleNanoseconds);
            if (!duration) {
              return MatroskaCursorFailure{
                  MatroskaDemuxError::InvalidTimeline,
                  "invalid BlockDuration"};
            }
            sample.duration = *duration;
          } else if (state.video.entry.defaultDurationNanoseconds) {
            const auto duration = timeFromNanosecondsUnsigned(
                *state.video.entry.defaultDurationNanoseconds);
            if (!duration) {
              return MatroskaCursorFailure{
                  MatroskaDemuxError::InvalidTimeline,
                  "invalid DefaultDuration"};
            }
            sample.duration = *duration;
          }
        } else {
          if (!state.audio || visitor.referenceCount != 0 ||
              visitor.frameCount == 0 ||
              visitor.frameCount > state.limits.maximumAudioSampleCount) {
            return MatroskaCursorFailure{MatroskaDemuxError::UnsupportedTrack,
                                         "invalid AAC Block"};
          }
          const auto projection = nearestAacAccessUnitForMatroskaTick(
              *tick, MediaTime{0, 1}, state.audio->audioSampleRate,
              state.timestampScaleNanoseconds);
          if (!aacProjectionOnGrid(projection)) {
            return MatroskaCursorFailure{MatroskaDemuxError::InvalidTimeline,
                                         "AAC Block is off the exact AU grid"};
          }
          std::uint16_t firstFrame = 0;
          if (visitor.header.containerEncoded.offset == impl_->startBlockOffset) {
            firstFrame = impl_->startFrameIndex;
          }
          if (firstFrame >= visitor.frameCount ||
              projection->accessUnitOrdinal + firstFrame !=
                  impl_->expectedAudioOrdinal) {
            return MatroskaCursorFailure{MatroskaDemuxError::InvalidTimeline,
                                         "AAC ordinal discontinuity"};
          }
          std::size_t bytes = 0;
          for (std::uint16_t index = firstFrame; index < visitor.frameCount;
               ++index) {
            const std::uint64_t frameBytes = visitor.frames[index].bytes.size;
            if (frameBytes > state.limits.maximumAudioSampleBytes ||
                bytes > state.limits.maximumAudioSampleBytes - frameBytes) {
              return MatroskaCursorFailure{MatroskaDemuxError::SampleLimit,
                                           "AAC sample exceeds byte cap"};
            }
            sample.frames[sample.frameCount++] = visitor.frames[index];
            bytes += static_cast<std::size_t>(frameBytes);
          }
          sample.aggregateBytes = bytes;
          const auto presentation = aacAccessUnitGridTime(
              {{0, 1}, impl_->expectedAudioOrdinal,
               state.audio->audioSampleRate});
          const auto duration = timeFromNanosecondsUnsigned(
              (static_cast<std::uint64_t>(sample.frameCount) *
               kAacLcSamplesPerAccessUnit * UINT64_C(1'000'000'000)) /
              state.audio->audioSampleRate);
          if (!presentation) {
            return MatroskaCursorFailure{MatroskaDemuxError::InvalidTimeline,
                                         "AAC presentation overflow"};
          }
          sample.presentationTime = *presentation;
          const std::uint64_t frameCount =
              static_cast<std::uint64_t>(sample.frameCount) *
              kAacLcSamplesPerAccessUnit;
          const std::uint64_t divisor =
              std::gcd(frameCount,
                       static_cast<std::uint64_t>(state.audio->audioSampleRate));
          const std::uint64_t numerator = frameCount / divisor;
          const std::uint64_t denominator = state.audio->audioSampleRate / divisor;
          if (!duration ||
              numerator > static_cast<std::uint64_t>(
                              std::numeric_limits<std::int64_t>::max()) ||
              denominator > static_cast<std::uint64_t>(
                                std::numeric_limits<std::int32_t>::max())) {
            return MatroskaCursorFailure{MatroskaDemuxError::InvalidTimeline,
                                         "AAC duration overflow"};
          }
          sample.duration = MediaTime{static_cast<std::int64_t>(numerator),
                                      static_cast<std::int32_t>(denominator)};
          impl_->expectedAudioOrdinal += sample.frameCount;
        }
        return sample;
      }
      impl_->clusterCursor.reset();
      ++impl_->clusterIndex;
    }
    impl_->ended = true;
    return MatroskaCursorEnd{};
  } catch (...) {
    return MatroskaCursorFailure{MatroskaDemuxError::Io,
                                 "cursor allocation failed"};
  }
}

MatroskaPreparedAsset::MatroskaPreparedAsset(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}
MatroskaPreparedAsset::~MatroskaPreparedAsset() = default;

const std::filesystem::path& MatroskaPreparedAsset::path() const noexcept {
  return impl_->state->path;
}
const std::shared_ptr<const MediaSourceDescriptor>&
MatroskaPreparedAsset::descriptor() const noexcept {
  return impl_->state->descriptor;
}
const MediaSourceLimits& MatroskaPreparedAsset::limits() const noexcept {
  return impl_->state->limits;
}
std::uint64_t
MatroskaPreparedAsset::timestampScaleNanoseconds() const noexcept {
  return impl_->state->timestampScaleNanoseconds;
}
std::span<const MatroskaClusterIndexEntry>
MatroskaPreparedAsset::clusters() const noexcept {
  return impl_->state->clusters;
}
std::span<const MatroskaCueIndexEntry>
MatroskaPreparedAsset::cues() const noexcept {
  return impl_->state->cues;
}

MatroskaPlanOutcome MatroskaPreparedAsset::planGeneration(
    MediaTime target, MediaSeekMode mode,
    CancellationToken cancellation) const noexcept {
  MatroskaPlanOutcome outcome;
  try {
    const AssetState& state = *impl_->state;
    if (!target.valid() || target.value < 0 || !state.unchanged()) {
      outcome.error = state.unchanged() ? MatroskaDemuxError::InvalidTimeline
                                        : MatroskaDemuxError::FileChanged;
      outcome.message = "invalid target or changed file";
      return outcome;
    }
    if (cancellation.cancelled()) {
      outcome.status = MatroskaDemuxStatus::Cancelled;
      outcome.error = MatroskaDemuxError::Cancelled;
      return outcome;
    }
    const auto beforeEnd = compareMediaTime(target, state.descriptor->duration);
    if (!beforeEnd || *beforeEnd != MediaTimeOrder::Less) {
      outcome.error = MatroskaDemuxError::InvalidTimeline;
      outcome.message = "target is outside the finite duration";
      return outcome;
    }
    std::size_t cueIndex = 0;
    for (std::size_t index = 0; index < state.cues.size(); ++index) {
      const auto cueTime = timeFromSignedTick(
          static_cast<std::int64_t>(state.cues[index].timestampTick),
          state.timestampScaleNanoseconds);
      if (!cueTime) {
        outcome.error = MatroskaDemuxError::InvalidTimeline;
        return outcome;
      }
      const auto order = compareMediaTime(*cueTime, target);
      if (!order) {
        outcome.error = MatroskaDemuxError::InvalidTimeline;
        return outcome;
      }
      if (*order == MediaTimeOrder::Greater) {
        break;
      }
      cueIndex = index;
    }
    const MatroskaCueIndexEntry& cue = state.cues[cueIndex];
    MatroskaGenerationPlan plan;
    plan.requestedTarget = target;
    plan.mode = mode;
    plan.videoClusterIndex = cue.clusterIndex;
    plan.videoBlockOffset =
        state.clusters[cue.clusterIndex].dataRange().offset +
        cue.relativeBlockOffset;
    const auto decodeStart = timeFromSignedTick(
        static_cast<std::int64_t>(cue.timestampTick),
        state.timestampScaleNanoseconds);
    if (!decodeStart) {
      outcome.error = MatroskaDemuxError::InvalidTimeline;
      return outcome;
    }
    plan.actualDecodeStart = *decodeStart;

    const ScanResult videoProof = scanTrack(
        state, state.video.id, cue.clusterIndex, 1,
        [&plan](std::uint32_t, const CapturedBlockVisitor& block) {
          return block.header.containerEncoded.offset == plan.videoBlockOffset;
        },
        cancellation);
    if (videoProof.error != MatroskaDemuxError::None || !videoProof.block ||
        !(videoProof.block->header.simpleBlock
              ? videoProof.block->header.keyFrame
              : videoProof.block->referenceCount == 0)) {
      outcome.error = videoProof.error == MatroskaDemuxError::None
                          ? MatroskaDemuxError::InvalidCue
                          : videoProof.error;
      outcome.message = "Cue does not identify a video random access point";
      return outcome;
    }

    if (state.audio) {
      std::optional<MediaTime> presentationStart;
      if (mode == MediaSeekMode::Accurate) {
        presentationStart =
            audioFrameAtOrAfter(target, state.audio->audioSampleRate);
      } else if (exactAudioFrameIndex(plan.actualDecodeStart,
                                      state.audio->audioSampleRate)) {
        presentationStart = plan.actualDecodeStart;
      }
      if (!presentationStart) {
        outcome.error = MatroskaDemuxError::InvalidTimeline;
        outcome.message = "audio presentation floor is not representable";
        return outcome;
      }
      const auto pcmFrame = exactAudioFrameIndex(
          *presentationStart, state.audio->audioSampleRate);
      if (!pcmFrame || *pcmFrame < 0) {
        outcome.error = MatroskaDemuxError::InvalidTimeline;
        return outcome;
      }
      const std::uint64_t desiredOrdinal =
          static_cast<std::uint64_t>(*pcmFrame) /
          kAacLcSamplesPerAccessUnit;
      // Stage whole access units ahead of the first audible one. A decoder
      // reaches full precision only after a couple of AAC frames, so a
      // consumer demands proof that the generation carries that preroll before
      // it will publish PCM. desiredOrdinal alone is the AU *containing* the
      // audible frame, which is never early enough to prove anything, so every
      // non-origin seek would be refused downstream.
      const std::uint64_t startOrdinal =
          desiredOrdinal >= kAacPrimingAccessUnits
              ? desiredOrdinal - kAacPrimingAccessUnits
              : 0;
      const std::size_t cueCluster = cue.clusterIndex;
      const std::size_t searchStart = cueCluster == 0 ? 0 : cueCluster - 1;
      const ScanResult audioBlock = scanTrack(
          state, state.audio->id, static_cast<std::uint32_t>(searchStart),
          kMaximumMatroskaSeekClusters,
          [&state, startOrdinal](std::uint32_t clusterIndex,
                                 const CapturedBlockVisitor& block) {
            const auto tick = signedBlockTick(
                state.clusters[clusterIndex].timestampTick,
                block.header.relativeTimestamp);
            if (!tick) {
              return false;
            }
            const auto projection = nearestAacAccessUnitForMatroskaTick(
                *tick, MediaTime{0, 1}, state.audio->audioSampleRate,
                state.timestampScaleNanoseconds);
            return aacProjectionOnGrid(projection) &&
                   projection->accessUnitOrdinal <= startOrdinal &&
                   startOrdinal < projection->accessUnitOrdinal +
                                      block.frameCount;
          },
          cancellation);
      if (audioBlock.error != MatroskaDemuxError::None || !audioBlock.block) {
        outcome.error = audioBlock.error == MatroskaDemuxError::None
                            ? MatroskaDemuxError::InvalidTimeline
                            : audioBlock.error;
        outcome.message = "AAC access unit for seek target was not found";
        return outcome;
      }
      const auto audioTick = signedBlockTick(
          state.clusters[audioBlock.clusterIndex].timestampTick,
          audioBlock.block->header.relativeTimestamp);
      const auto projection = nearestAacAccessUnitForMatroskaTick(
          *audioTick, MediaTime{0, 1}, state.audio->audioSampleRate,
          state.timestampScaleNanoseconds);
      plan.audioClusterIndex = audioBlock.clusterIndex;
      plan.audioBlockOffset = audioBlock.block->header.containerEncoded.offset;
      plan.audioFrameIndex = static_cast<std::uint16_t>(
          startOrdinal - projection->accessUnitOrdinal);
      plan.audioAccessUnitOrdinal = startOrdinal;
      // decodeStart must name the first access unit the audio cursor actually
      // emits, which is startOrdinal -- not the first AU of the Block that
      // contains it. Naming the Block's first AU disagreed with the cursor
      // whenever the seek landed mid-Block.
      const auto decode = aacAccessUnitGridTime(
          {{0, 1}, startOrdinal, state.audio->audioSampleRate});
      if (!decode) {
        outcome.error = MatroskaDemuxError::InvalidTimeline;
        return outcome;
      }
      plan.audioWindow = {*decode, *presentationStart, startOrdinal == 0};
    }
    outcome.status = MatroskaDemuxStatus::Ready;
    outcome.error = MatroskaDemuxError::None;
    outcome.plan = plan;
    return outcome;
  } catch (...) {
    outcome.error = MatroskaDemuxError::Io;
    outcome.message = "generation planning allocation failed";
    return outcome;
  }
}

std::unique_ptr<MatroskaCursor> MatroskaPreparedAsset::makeVideoCursor(
    const MatroskaGenerationPlan& plan) const noexcept {
  try {
    auto cursor = std::make_unique<MatroskaCursor::Impl>();
    cursor->state = impl_->state;
    cursor->track = impl_->state->video.id;
    cursor->video = true;
    cursor->clusterIndex = plan.videoClusterIndex;
    cursor->startBlockOffset = plan.videoBlockOffset;
    cursor->constraints = cursorConstraints(*impl_->state, cursor->track);
    cursor->options = parserOptions(*impl_->state, cursor->constraints);
    return std::unique_ptr<MatroskaCursor>(
        new MatroskaCursor(std::move(cursor)));
  } catch (...) {
    return nullptr;
  }
}

std::unique_ptr<MatroskaCursor> MatroskaPreparedAsset::makeAudioCursor(
    const MatroskaGenerationPlan& plan) const noexcept {
  if (!impl_->state->audio) {
    return nullptr;
  }
  try {
    auto cursor = std::make_unique<MatroskaCursor::Impl>();
    cursor->state = impl_->state;
    cursor->track = impl_->state->audio->id;
    cursor->video = false;
    cursor->clusterIndex = plan.audioClusterIndex;
    cursor->startBlockOffset = plan.audioBlockOffset;
    cursor->startFrameIndex = plan.audioFrameIndex;
    cursor->expectedAudioOrdinal = plan.audioAccessUnitOrdinal;
    cursor->constraints = cursorConstraints(*impl_->state, cursor->track);
    cursor->options = parserOptions(*impl_->state, cursor->constraints);
    return std::unique_ptr<MatroskaCursor>(
        new MatroskaCursor(std::move(cursor)));
  } catch (...) {
    return nullptr;
  }
}

bool MatroskaPreparedAsset::copyRanges(
    std::span<const FrameRange> ranges, std::span<std::byte> destination,
    CancellationToken cancellation, MatroskaDemuxError* error) const noexcept {
  if (error != nullptr) {
    *error = MatroskaDemuxError::None;
  }
  const AssetState& state = *impl_->state;
  if (!state.unchanged()) {
    if (error != nullptr) {
      *error = MatroskaDemuxError::FileChanged;
    }
    return false;
  }
  std::size_t total = 0;
  for (const FrameRange frame : ranges) {
    if (frame.bytes.size > std::numeric_limits<std::size_t>::max() ||
        total > destination.size() -
                    std::min(destination.size(),
                             static_cast<std::size_t>(frame.bytes.size))) {
      if (error != nullptr) {
        *error = MatroskaDemuxError::SampleLimit;
      }
      return false;
    }
    total += static_cast<std::size_t>(frame.bytes.size);
  }
  if (total != destination.size()) {
    if (error != nullptr) {
      *error = MatroskaDemuxError::InvalidRequest;
    }
    return false;
  }
  std::size_t destinationOffset = 0;
  for (const FrameRange frame : ranges) {
    std::uint64_t sourceOffset = frame.bytes.offset;
    std::size_t remaining = static_cast<std::size_t>(frame.bytes.size);
    while (remaining != 0) {
      if (cancellation.cancelled()) {
        if (error != nullptr) {
          *error = MatroskaDemuxError::Cancelled;
        }
        return false;
      }
      const std::size_t amount = std::min(kCopyChunkBytes, remaining);
      if (!state.unchanged() ||
          !state.reader->readAt(
              sourceOffset,
              destination.subspan(destinationOffset, amount)) ||
          !state.unchanged()) {
        if (error != nullptr) {
          *error = state.reader->size() == state.readerSize
                       ? MatroskaDemuxError::Io
                       : MatroskaDemuxError::FileChanged;
        }
        return false;
      }
      sourceOffset += amount;
      destinationOffset += amount;
      remaining -= amount;
    }
  }
  // A cancellation raised by the final read must still be reported exactly;
  // the destination is only complete when the token never flipped.
  if (cancellation.cancelled()) {
    if (error != nullptr) {
      *error = MatroskaDemuxError::Cancelled;
    }
    return false;
  }
  return true;
}

MatroskaPrepareOutcome prepareMatroska(
    std::shared_ptr<SeekableByteReader> reader, std::filesystem::path path,
    const MediaSourceOpenOptions& requested,
    CancellationToken cancellation) noexcept {
  MatroskaPrepareOutcome result;
  try {
    if (reader == nullptr || reader->size() == 0 || path.empty()) {
      result.error = MatroskaDemuxError::InvalidRequest;
      result.message = "a finite reader and path identity are required";
      return result;
    }
    std::string initialError;
    if (!validateMediaSourceInitialPosition(requested.initialPosition,
                                            &initialError)) {
      result.error = MatroskaDemuxError::InvalidRequest;
      result.message = std::move(initialError);
      return result;
    }
    if (cancellation.cancelled()) {
      result.status = MatroskaDemuxStatus::Cancelled;
      result.error = MatroskaDemuxError::Cancelled;
      return result;
    }
    auto state = std::make_shared<AssetState>();
    state->reader = std::move(reader);
    state->readerSize = state->reader->size();
    state->path = std::move(path);
    state->limits = clampMediaSourceLimits(requested.limits);

    CollectedDocument document(state->limits.maximumTracks,
                               kMaximumMatroskaCues);
    ParseOptions options;
    options.maximumTracks = state->limits.maximumTracks;
    options.maximumCodecPrivateBytes =
        state->limits.maximumCodecConfigurationBytes;
    options.maximumBlockBytes = state->limits.maximumVideoSampleBytes;
    options.maximumEncodedBlockBytes = kMaximumMatroskaEncodedBlockBytes;
    options.maximumTrackTextBytes = state->limits.maximumTrackTextBytes;
    options.maximumCues = kMaximumMatroskaCues;
    options.scanClusterMetadata = true;
    options.visitClusterBlocks = false;
    const ParseOutcome parsed =
        parseDocument(*state->reader, document, options, cancellation);
    if (!parsed.ok() || document.allocationFailure) {
      result.error = parseError(parsed);
      result.status = result.error == MatroskaDemuxError::Cancelled
                          ? MatroskaDemuxStatus::Cancelled
                          : parsed.status == ParseStatus::Unsupported
                                ? MatroskaDemuxStatus::Unsupported
                                : MatroskaDemuxStatus::Failed;
      result.message = "Matroska structure was not admitted";
      return result;
    }
    if (!state->unchanged()) {
      result.error = MatroskaDemuxError::FileChanged;
      result.message = "reader size changed during preparation";
      return result;
    }
    if (document.headerCount != 1 || document.segmentCount != 1 ||
        document.infoCount != 1 || !document.info || !document.summary ||
        document.summary->documentCount != 1 ||
        document.summary->segmentCount != 1 ||
        document.summary->trailingDocumentsPresent ||
        (document.chapters &&
         (document.chapters->linkedSegmentPresent ||
          document.chapters->orderedEditionPresent))) {
      result.error = MatroskaDemuxError::UnsupportedContainer;
      result.status = MatroskaDemuxStatus::Unsupported;
      result.message = "v1 requires one finite unlinked Matroska Segment";
      return result;
    }
    const auto duration = trackDuration(*document.info);
    if (!duration || duration->value <= 0) {
      result.error = MatroskaDemuxError::InvalidTimeline;
      result.message = "finite positive Duration is required";
      return result;
    }
    state->timestampScaleNanoseconds =
        document.info->timestampScaleNanoseconds;
    const TrackEntry* video = chooseTrack(
        document.tracks, 1, requested.selection.preferredVideo);
    const TrackEntry* audio = chooseTrack(
        document.tracks, 2, requested.selection.preferredAudio);
    if (video == nullptr ||
        (requested.selection.requireAudio && audio == nullptr) ||
        (requested.selection.preferredAudio && audio == nullptr) ||
        requested.selection.preferredSubtitle) {
      // No admissible track for this request is an envelope verdict, not an
      // error: a VP9 or subtitle-only Matroska must reach the caller as
      // Unsupported so it falls back cleanly, rather than as Failed, which
      // the session reports as a hard protocol fault on a blocking surface.
      result.status = MatroskaDemuxStatus::Unsupported;
      result.error = MatroskaDemuxError::TrackSelection;
      result.message = "requested Matroska tracks are unavailable";
      return result;
    }

    auto descriptor = std::make_shared<MediaSourceDescriptor>();
    descriptor->duration = *duration;
    for (const TrackEntry& track : document.tracks) {
      incrementInventory(&descriptor->inventory, inventoryKind(track.type));
      const auto id = trackId(track.number);
      if (!id) {
        result.error = MatroskaDemuxError::UnsupportedTrack;
        result.message = "track number does not fit MediaTrackId";
        return result;
      }
      TrackConstraint constraint;
      constraint.number = track.number;
      constraint.lacingAllowed = track.lacingAllowed;
      constraint.selected = track.number == video->number ||
                            (audio != nullptr && track.number == audio->number);
      constraint.maximumBlockBytes = track.number == video->number
                                         ? state->limits.maximumVideoSampleBytes
                                         : state->limits.maximumAudioSampleBytes;
      state->constraints.push_back(constraint);
    }
    MediaTrackDescriptor videoDescriptor;
    if (!makeVideoDescriptor(*state->reader, *video, state->limits, *duration,
                             cancellation, &videoDescriptor, &state->video)) {
      result.error = MatroskaDemuxError::CodecConfiguration;
      result.status = MatroskaDemuxStatus::Unsupported;
      result.message = "selected AVC/HEVC track was not admitted";
      return result;
    }
    descriptor->selectedVideo = videoDescriptor.id;
    descriptor->tracks.push_back(std::move(videoDescriptor));
    if (audio != nullptr) {
      MediaTrackDescriptor audioDescriptor;
      TrackRuntime audioRuntime;
      if (!makeAudioDescriptor(*state->reader, *audio, state->limits, *duration,
                               cancellation, &audioDescriptor,
                               &audioRuntime)) {
        result.error = MatroskaDemuxError::CodecConfiguration;
        result.status = MatroskaDemuxStatus::Unsupported;
        result.message = "selected AAC-LC track was not admitted";
        return result;
      }
      descriptor->selectedAudio = audioDescriptor.id;
      descriptor->tracks.push_back(std::move(audioDescriptor));
      state->audio = audioRuntime;
    }
    std::string descriptorError;
    if (!validateMediaSourceDescriptor(*descriptor, state->limits,
                                       &descriptorError)) {
      result.error = MatroskaDemuxError::CodecConfiguration;
      result.message = std::move(descriptorError);
      return result;
    }
    state->descriptor = descriptor;

    if (document.clusters.empty() ||
        document.clusters.size() > kMaximumMatroskaClusters) {
      result.error = MatroskaDemuxError::IndexLimit;
      result.message = "bounded Cluster directory is required";
      return result;
    }
    state->clusters.reserve(document.clusters.size());
    std::uint64_t previousOffset = 0;
    std::uint64_t previousTimestamp = 0;
    for (std::size_t index = 0; index < document.clusters.size(); ++index) {
      MatroskaClusterIndexEntry cluster;
      if (!clusterRangeValid(document.clusters[index], &cluster) ||
          (index != 0 && (cluster.encodedOffset <= previousOffset ||
                         cluster.timestampTick < previousTimestamp))) {
        result.error = MatroskaDemuxError::InvalidTimeline;
        result.message = "Cluster directory is not finite and monotonic";
        return result;
      }
      state->clusters.push_back(cluster);
      previousOffset = cluster.encodedOffset;
      previousTimestamp = cluster.timestampTick;
    }

    for (const CueTrackPosition& cue : document.cuePositions) {
      if (cue.track != state->video.id) {
        continue;
      }
      if (!cue.relativePosition || !cue.absoluteBlockOffset ||
          (cue.blockNumber && *cue.blockNumber != 1) ||
          cue.codecStatePosition != 0 || cue.absoluteCodecStateOffset ||
          cue.cueReferencePresent ||
          *cue.relativePosition > std::numeric_limits<std::uint32_t>::max()) {
        result.error = MatroskaDemuxError::InvalidCue;
        result.message = "selected video Cue uses an unsupported feature";
        return result;
      }
      const auto cluster = findCluster(state->clusters,
                                       cue.absoluteClusterOffset);
      if (!cluster ||
          state->clusters[*cluster].dataRange().offset +
                  *cue.relativePosition !=
              *cue.absoluteBlockOffset) {
        result.error = MatroskaDemuxError::InvalidCue;
        result.message = "Cue target does not match the Cluster directory";
        return result;
      }
      if (!state->cues.empty() &&
          cue.cueTime <= state->cues.back().timestampTick) {
        result.error = MatroskaDemuxError::InvalidCue;
        result.message = "selected video Cues are not strictly increasing";
        return result;
      }
      state->cues.push_back(
          {cue.cueTime, *cluster,
           static_cast<std::uint32_t>(*cue.relativePosition)});
    }
    // The first Cue does not have to sit exactly on tick zero. A stream-copied
    // Matroska routinely places its first video keyframe a few milliseconds in
    // (FFmpeg emits a first CueTime of 21 ms for a 30 fps remux, which is also
    // why such a file reports 72.021 s rather than 72.000 s), and that cue is
    // the true origin of the video timeline. Requiring literal zero rejected
    // essentially every real remux. planGeneration already clamps any target
    // at or before the first cue to cue zero, so a non-zero first cue needs no
    // other special case; the strictly-increasing check below still holds.
    if (state->cues.empty() ||
        state->cues.size() > kMaximumMatroskaCues) {
      result.error = MatroskaDemuxError::MissingCues;
      result.message = "v1 requires a bounded selected-video Cue index";
      return result;
    }
    for (std::size_t index = 1; index < state->cues.size(); ++index) {
      const auto previous = timeFromSignedTick(
          static_cast<std::int64_t>(state->cues[index - 1].timestampTick),
          state->timestampScaleNanoseconds);
      const auto current = timeFromSignedTick(
          static_cast<std::int64_t>(state->cues[index].timestampTick),
          state->timestampScaleNanoseconds);
      if (!previous || !current ||
          static_cast<long double>(current->value) * previous->timescale -
                  static_cast<long double>(previous->value) * current->timescale >
              static_cast<long double>(state->limits.maximumVideoSeekPrerollSeconds) *
                  current->timescale * previous->timescale) {
        result.error = MatroskaDemuxError::InvalidCue;
        result.message = "Cue gap exceeds the bounded seek preroll";
        return result;
      }
    }

    auto asset = std::shared_ptr<MatroskaPreparedAsset>(
        new MatroskaPreparedAsset(
            std::make_unique<MatroskaPreparedAsset::Impl>(state)));
    if (requested.initialPosition) {
      const MatroskaPlanOutcome plan = asset->planGeneration(
          requested.initialPosition->target,
          requested.initialPosition->mode, cancellation);
      if (plan.status != MatroskaDemuxStatus::Ready) {
        result.status = plan.status;
        result.error = plan.error;
        result.message = plan.message;
        return result;
      }
    }
    result.status = MatroskaDemuxStatus::Ready;
    result.error = MatroskaDemuxError::None;
    result.asset = std::move(asset);
    return result;
  } catch (...) {
    result.error = MatroskaDemuxError::Io;
    result.message = "Matroska preparation allocation failed";
    return result;
  }
}

MatroskaPrepareOutcome prepareMatroskaLocalFile(
    const std::filesystem::path& path, const MediaSourceOpenOptions& options,
    CancellationToken cancellation) noexcept {
  if (cancellation.cancelled()) {
    return {MatroskaDemuxStatus::Cancelled, MatroskaDemuxError::Cancelled,
            nullptr, {}};
  }
  std::shared_ptr<StableFileReader> reader = StableFileReader::open(path);
  if (reader == nullptr) {
    return {MatroskaDemuxStatus::Failed, MatroskaDemuxError::Io, nullptr,
            "could not open the local Matroska file"};
  }
  MatroskaPrepareOutcome outcome =
      prepareMatroska(reader, path, options, cancellation);
  if (outcome.asset) {
    const_cast<AssetState*>(outcome.asset->impl_->state.get())->localReader =
        std::move(reader);
  }
  return outcome;
}

}  // namespace wam::media::matroska
