#include "media/matroska_demuxer.hpp"

#include "media/audio_codec_timing.hpp"
#include "media/matroska_aac.hpp"
#include "media/matroska_ac3.hpp"
#include "media/matroska_flac.hpp"
#include "media/matroska_mpeg_audio.hpp"
#include "media/matroska_opus.hpp"
#include "media/matroska_vorbis.hpp"
#include "media/video_codec_configuration.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <numeric>
#include <optional>
#include <span>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>

namespace wam::media::matroska {
namespace {

constexpr std::size_t kCopyChunkBytes{64U * 1024U};
constexpr std::uint32_t kAacFormatTag{0x61616320U};
constexpr std::uint32_t kOpusFormatTag{0x6F707573U};
constexpr std::uint32_t kVorbisFormatTag{kVorbisAudioFormatTag};
// 'ac-3', 'ec-3', 'flac', '.mp3' -- kAudioFormatAC3, kAudioFormatEnhancedAC3,
// kAudioFormatFLAC and kAudioFormatMPEGLayer3. Spelled numerically here so the
// demuxer stays free of the AudioToolbox headers, exactly as the AAC and Opus
// tags already are.
constexpr std::uint32_t kAc3FormatTag{0x61632D33U};
constexpr std::uint32_t kEnhancedAc3FormatTag{0x65632D33U};
constexpr std::uint32_t kFlacFormatTag{0x666C6163U};
constexpr std::uint32_t kMpegLayer3FormatTag{0x2E6D7033U};
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

  // The property this proves is exactly one thing: the bytes reachable through
  // the retained descriptor are still the bytes the cluster/cue plan was built
  // against. dev+ino catch a replaced file, size catches truncation and
  // extension, and mtime catches any write to the content.
  //
  // st_ctime is deliberately NOT part of that identity, and used to be. ctime
  // is the INODE-metadata timestamp: it moves for xattr writes, chmod, chown,
  // link-count and rename -- none of which touch a single content byte. On
  // macOS those happen to a media file constantly and from outside this
  // process: Spotlight/mds indexing, iCloud/FileProvider sync bookkeeping,
  // quarantine and last-used-date stamping. Including ctime therefore made
  // this predicate report "the file changed" for events that are, by
  // construction, not changes to the file's content -- an unfixable false
  // positive whose probability grew with how long the demuxer held the plan
  // and with how busy the machine's metadata daemons were. That is precisely
  // the observed defect: a load-dependent Matroska-only open/playback failure
  // (FileChanged -> SourceOpen/SourceRead -> Protocol/Decode -> fallback),
  // where the AVFoundation route, which makes no such assertion, was immune.
  //
  // What dropping ctime gives up is only the case of an in-place, byte-count-
  // preserving write whose mtime is then restored by an explicit utimes()
  // call. That is deliberate forgery, not a hazard a local media player is
  // defending against, and every honest mutation still moves mtime or size.
  [[nodiscard]] bool unchanged() const noexcept {
    struct stat facts {};
    return ::fstat(descriptor_, &facts) == 0 && facts.st_size >= 0 &&
           facts.st_dev == device_ && facts.st_ino == inode_ &&
           static_cast<std::uint64_t>(facts.st_size) == size_ &&
           facts.st_mtimespec.tv_sec == modifiedSeconds_ &&
           facts.st_mtimespec.tv_nsec == modifiedNanoseconds_;
  }

 private:
  StableFileReader(int descriptor, const struct stat& facts) noexcept
      : descriptor_(descriptor), size_(static_cast<std::uint64_t>(facts.st_size)),
        device_(facts.st_dev), inode_(facts.st_ino),
        modifiedSeconds_(facts.st_mtimespec.tv_sec),
        modifiedNanoseconds_(facts.st_mtimespec.tv_nsec) {}

  int descriptor_{-1};
  std::uint64_t size_{0};
  dev_t device_{};
  ino_t inode_{};
  time_t modifiedSeconds_{};
  long modifiedNanoseconds_{};
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
    // Header-probe mode: prepareMatroska's cheap pre-admission pass wants only
    // the EBML header, Info and Tracks, all of which precede the first Cluster
    // in a non-streaming mux -- and a master element is never delivered
    // piecewise, so Tracks is complete by the time this fires. Stopping here
    // is what keeps that pass cheap: it never reaches the Cues, which on the
    // file that motivated it hold the parser's 65,536-cue maximum and cost
    // about 1.08 million reads on their own.
    if (stopAtFirstCluster) {
      return VisitorAction::Stop;
    }
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

  // Returns the collector to its just-constructed state while KEEPING the
  // reserved capacity. prepareMatroska reuses one collector for its second,
  // fallback parse rather than constructing a second one, so the 65,536-cue
  // and 65,536-cluster reservations are paid once per open however many passes
  // run.
  void reset() noexcept {
    header.reset();
    segment.reset();
    info.reset();
    chapters.reset();
    summary.reset();
    tracks.clear();
    clusters.clear();
    cuePositions.clear();
    headerCount = 0;
    segmentCount = 0;
    infoCount = 0;
    allocationFailure = false;
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
  // Opt-in for the header-probe pass only; see onCluster above. Off for every
  // authoritative parse, which needs the whole cluster list.
  bool stopAtFirstCluster{false};
};

struct TrackRuntime {
  TrackEntry entry;
  MediaTrackId id{0};
  MediaTrackKind kind{MediaTrackKind::Metadata};
  MediaCodec codec{MediaCodec::Unknown};
  std::uint32_t audioSampleRate{0};
  // Two grids, deliberately separate.
  //
  // Container ticks always live on the CODEC grid: Matroska defines a Block's
  // timestamp as the codec time, from which CodecDelay MUST be subtracted to
  // obtain the presentation time. Ordinal k's tick is therefore
  // k * samplesPerAccessUnit / sampleRate with origin zero for every codec.
  //
  // Presentation times live on the PRESENTATION grid, whose origin is
  // -CodecDelay. Ordinal 0 of an Opus track legitimately presents preSkip
  // frames before media time zero; for AAC the two grids coincide.
  std::uint32_t audioSamplesPerAccessUnit{kAacLcSamplesPerAccessUnit};
  MediaTime audioPresentationOrigin{0, 1};
  // Presentation frame index of ordinal 0 is -audioGridOffsetFrames. It is the
  // Opus pre-skip and zero for every other codec.
  std::uint32_t audioGridOffsetFrames{0};
  // Always assigned by makeAudioDescriptor; the literal keeps this struct
  // declarable above kMaximumAacGridTickResidual, which is 1.
  std::int64_t audioTickResidualTolerance{1};
  std::uint64_t audioPrimingAccessUnits{0};
  // The one Block permitted to carry DiscardPadding, and the exact value it
  // must carry. Both are proven at preparation; the cursor accepts nothing
  // else, so a mid-stream padding element still fails the generation closed.
  bool audioTailBlockKnown{false};
  std::uint64_t audioTailBlockOffset{0};
  std::int64_t audioTailDiscardPaddingNanoseconds{0};
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
  // Both lanes are optional and exactly symmetric. `video` became optional for
  // audio-only media (MKA, and an audio-only MKV/WebM): the clock is
  // audio-authoritative, so a generation with no video lane is the simpler of
  // the two degenerate cases -- the silent-video one had to manufacture a
  // timebase, this one already owns the authority.
  std::optional<TrackRuntime> video;
  std::optional<TrackRuntime> audio;
  std::vector<MatroskaClusterIndexEntry> clusters;
  std::vector<MatroskaCueIndexEntry> cues;

  [[nodiscard]] bool unchanged() const noexcept {
    return reader != nullptr && reader->size() == readerSize &&
           (localReader == nullptr || localReader->unchanged());
  }
};

// Takes the limits rather than the AssetState because the VP9 keyframe probe
// below runs during preparation, before the AssetState's Cluster directory
// exists; every other caller still passes state.limits.
[[nodiscard]] ParseOptions parserOptions(
    const MediaSourceLimits& limits,
    std::span<const TrackConstraint> constraints) noexcept {
  ParseOptions options;
  options.maximumReadBytes = ParseOptions::kHardMaximumReadBytes;
  options.maximumTracks = limits.maximumTracks;
  options.maximumCodecPrivateBytes = limits.maximumCodecConfigurationBytes;
  options.maximumBlockBytes = std::max(limits.maximumVideoSampleBytes,
                                       limits.maximumAudioSampleBytes);
  options.maximumEncodedBlockBytes = kMaximumMatroskaEncodedBlockBytes;
  options.maximumTrackTextBytes = limits.maximumTrackTextBytes;
  options.maximumLaceFrames = std::min(
      ParseOptions::kHardMaximumLaceFrames,
      limits.maximumAudioSampleCount);
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

// Opus needs one tick more. Matroska stores a Block's timestamp on the codec
// grid and states CodecDelay separately, and FFmpeg builds that timestamp as
// round(presentationMilliseconds) + round(delayMilliseconds) -- two roundings
// of values that are exactly half a tick apart for every ffmpeg Opus mux. The
// result is a systematic +1 tick on top of the one tick of ordinary container
// jitter. Two ticks is still an order of magnitude below one access unit (20
// ticks at 20 ms packets), so a genuinely misplaced Block is still rejected.
inline constexpr std::int64_t kMaximumOpusGridTickResidual{2};

// Whole AAC access units staged before the first audible frame of a non-origin
// generation. Two is what the decoder needs to reach full precision, and it is
// the same preroll the AVFoundation backend places for the identical reason.
inline constexpr std::uint64_t kAacPrimingAccessUnits{2};

// Opus states its own decoder warm-up as SeekPreRoll (80 ms from every real
// encoder). Two 20 ms packets would stage only 40 ms, so the priming is the
// larger of the AAC floor and whatever the track actually asks for.
inline constexpr std::uint64_t kMaximumAudioPrimingAccessUnits{64};

// How far back from the end of file the last audio Block is looked for. The
// tail trim is only representable when it is found, so this bound is a
// fall-back-to-mpv threshold rather than a heuristic.
inline constexpr std::size_t kOpusTailProbeClusters{8};

[[nodiscard]] bool aacProjectionOnGrid(
    const std::optional<AacTickGridProjection>& projection,
    std::int64_t tolerance = kMaximumAacGridTickResidual) noexcept {
  if (!projection) {
    return false;
  }
  if (projection->exactTickMatch) {
    return true;
  }
  const std::int64_t residual = projection->signedTickResidual;
  return residual >= -tolerance && residual <= tolerance;
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
  return id == "V_MPEG4/ISO/AVC" || id == "V_MPEGH/ISO/HEVC" ||
         id == "V_AV1" || id == "V_VP9"
         // MPEG-4 Part 2. Both CodecIDs are named because the CodecID is not a
         // profile signal: ffmpeg writes V_MPEG4/ISO/ASP for every mpeg4 track
         // it muxes, Simple Profile included (measured across the whole
         // fixture set), so a track selected here is profile-gated later, on
         // the CodecPrivate headers, by inspectMpeg4VisualHeaders(). Advanced
         // Simple Profile is refused there, cleanly, and falls back.
         //
         // V_MS/VFW/FOURCC -- the old AVI-remux carriage that wraps DIVX/XVID/
         // DX50 in a BITMAPINFOHEADER -- is deliberately NOT named: its
         // CodecPrivate is a Windows structure rather than a
         // VisualObjectSequence, and the payload it wraps is Advanced Simple
         // or MS-MPEG-4 v3 in every case this project has seen.
         || id == "V_MPEG4/ISO/ASP" || id == "V_MPEG4/ISO/SP"
#if defined(WAM_ENABLE_SOFTWARE_VP8)
         // VP8 has no hardware decoder on any Apple platform, so it is a
         // selectable CodecID exactly when this build linked the libvpx
         // software stage. Naming it in a build that cannot decode it would
         // select the track and then fail the open, which is a strictly worse
         // fallback than never selecting it.
         || id == "V_VP8"
#endif
      ;
}

[[nodiscard]] bool isAudioCodec(std::string_view id) noexcept {
  return id == "A_AAC" || id == "A_OPUS" || id == "A_VORBIS" ||
         id == "A_AC3" || id == "A_EAC3" || id == "A_FLAC" ||
         id == "A_MPEG/L3";
}

// WebM's audio codec set is Vorbis and Opus. AC-3, E-AC-3, FLAC and MP3 are
// legal in Matroska and are NOT legal in WebM, so a file whose DocType says
// "webm" while carrying one of them is malformed. Admitting it would mean this
// source plays a file that no other WebM decoder would, which is a worse
// outcome than the mpv fallback -- mpv is not bound by the DocType either, so
// the file still plays, just not down this path.
//
// The rule is deliberately scoped to the four CodecIDs this source has just
// started admitting, and NOT applied to AAC. AAC is not WebM-legal either, but
// an AAC track in a WebM DocType was selectable before this work and playing
// it natively is not a behaviour this change set has any reason to remove. A
// consistent rule that quietly turned working files into fallbacks would be a
// worse trade than an inconsistent one that changes nothing it was not asked
// to.
[[nodiscard]] bool
audioCodecAllowedInDocument(std::string_view codecId,
                            EbmlDocumentType documentType) noexcept {
  if (documentType != EbmlDocumentType::Webm) {
    return true;
  }
  return codecId != "A_AC3" && codecId != "A_EAC3" && codecId != "A_FLAC" &&
         codecId != "A_MPEG/L3";
}

[[nodiscard]] const TrackEntry* chooseTrack(
    const std::vector<TrackEntry>& tracks, std::uint64_t type,
    std::optional<MediaTrackId> preferred,
    EbmlDocumentType documentType) noexcept {
  const auto admitted = [type, documentType](const TrackEntry& track) {
    const std::string_view codec(track.codecId.view().data(),
                                 track.codecId.view().size());
    return track.enabled && track.type == type && trackId(track.number) &&
           (type == 1 ? isVideoCodec(codec)
                      : (isAudioCodec(codec) &&
                         audioCodecAllowedInDocument(codec, documentType)));
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

// CodecDelay and SeekPreRoll are refused by default and always have been:
// honouring a delay the pipeline did not actually apply is a silent A/V shift,
// so distrust was the right default while nothing could prove the arithmetic.
// Opus is the single exception, and only because its delay IS provable -- the
// container's CodecDelay must be exactly the OpusHead pre-skip expressed in
// nanoseconds, which is checked at admission. AAC keeps the historic rule.
[[nodiscard]] bool selectedTrackFeaturesSupported(
    const TrackEntry& track, bool allowCodecDelay = false) noexcept {
  return track.timestampScale == 1.0 && !track.timestampOffsetPresent &&
         (allowCodecDelay ||
          (track.codecDelayNanoseconds == 0 &&
           track.seekPreRollNanoseconds == 0)) &&
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
  //
  // A FRACTIONAL tick count is admitted the same way, because Duration is a
  // float element and nothing requires a muxer to land on a whole tick.
  // GStreamer's matroskamux does not: measured on matroskamux 1.20.3 output it
  // wrote Duration 491295.376732 against TimestampScale 1 ms, i.e. a duration
  // stated to sub-tick precision. That value has no exact int32-timescale
  // rational in SECONDS, so the seconds fallback below failed closed and the
  // whole container was refused with InvalidTimeline -- the exact defect this
  // integral-tick path was written to remove, still reachable through the one
  // door it did not cover.
  //
  // The fraction is resolved at the timeline's own resolution. MediaTime's
  // finest representable step here is one nanosecond (denominator 1e9), so a
  // tick count is converted to nanoseconds and rounded to the nearest whole
  // nanosecond: nothing representable is lost, and the result is exact in the
  // only units the timeline can express. The integral part is multiplied in
  // __int128 so it stays exact for any tick count, and only the sub-tick
  // remainder -- strictly less than one tick -- goes through double.
  const double ticks = *info.durationTicks;
  double integralTicks = 0.0;
  const double fractionalTicks = std::modf(ticks, &integralTicks);
  if (integralTicks <=
      static_cast<double>(std::numeric_limits<std::int64_t>::max())) {
    const auto wholeTicks = static_cast<std::int64_t>(integralTicks);
    const auto scale = static_cast<std::int64_t>(
        info.timestampScaleNanoseconds);
    constexpr std::int64_t kNanosecondsPerSecond{1'000'000'000};
    if (scale > 0) {
      // `fractionalTicks` is in [0, 1) and `scale` is a nanosecond count, so
      // the product is in [0, scale) and llround is exact for every scale a
      // Matroska file can state -- binary64 represents every integer below
      // 2^53 exactly, and TimestampScale is bounded far below that.
      const auto fractionalNanoseconds = static_cast<std::int64_t>(
          std::llround(fractionalTicks * static_cast<double>(scale)));
      const auto nanoseconds =
          static_cast<__int128>(wholeTicks) * static_cast<__int128>(scale) +
          static_cast<__int128>(fractionalNanoseconds);
      if (nanoseconds >= 0 &&
          nanoseconds <=
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
  // Out-of-range tick counts keep the original conservative seconds
  // conversion, which still fails closed when it cannot be exact.
  return exactNonnegativeMediaTime(
      ticks * (static_cast<double>(info.timestampScaleNanoseconds) / 1.0e9));
}

// Reused as a workspace across blocks, never constructed per block. The
// `frames` member is 256 * sizeof(FrameRange) = 4 KiB and a fresh instance
// zero-fills all of it, so constructing one per parsed block spent 4 KiB of
// stores to learn about a Block that carries one frame (video) or four
// (laced AAC). On the seek path that is not a rounding error: a planGeneration
// audio scan walks up to kMaximumMatroskaSeekClusters (8,192) Clusters, so a
// dense file cost hundreds of megabytes of memset per seek. Only `emitted`
// needs clearing between parses -- every other field is written by onBlock
// before it is read, and `frames` is only ever read below `frameCount`.
struct CapturedBlockVisitor final : Visitor {
  void reset() noexcept { emitted = false; }

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

struct VideoCodecIdentity {
  MediaCodec codec{MediaCodec::Unknown};
  MediaCodecConfigurationKind kind{MediaCodecConfigurationKind::None};
};

// A full map, not a default. The previous ternary sent every non-AVC CodecID to
// HvcC, which was harmless only while HEVC was the sole other admitted codec
// and became a silent mis-dispatch the moment a third one existed.
[[nodiscard]] VideoCodecIdentity videoCodecIdentity(
    std::string_view codecId) noexcept {
  if (codecId == "V_MPEG4/ISO/AVC") {
    return {MediaCodec::H264, MediaCodecConfigurationKind::AvcC};
  }
  if (codecId == "V_MPEGH/ISO/HEVC") {
    return {MediaCodec::Hevc, MediaCodecConfigurationKind::HvcC};
  }
  if (codecId == "V_AV1") {
    return {MediaCodec::Av1, MediaCodecConfigurationKind::Av1C};
  }
  if (codecId == "V_VP9") {
    return {MediaCodec::Vp9, MediaCodecConfigurationKind::VpcC};
  }
  if (codecId == "V_MPEG4/ISO/ASP" || codecId == "V_MPEG4/ISO/SP") {
    // CodecPrivate names the esds makeVideoDescriptor synthesizes below from
    // the VisualObjectSequence/VideoObjectLayer headers this CodecID carries,
    // the same way VpcC names the record synthesized for VP8 and VP9.
    return {MediaCodec::Mpeg4Visual,
            MediaCodecConfigurationKind::CodecPrivate};
  }
#if defined(WAM_ENABLE_SOFTWARE_VP8)
  if (codecId == "V_VP8") {
    // A VPCodecConfigurationBox describes vp08 as well as vp09. WebM never
    // carries one for VP8, so this kind names the record makeVideoDescriptor
    // synthesizes from the key frame, exactly as it does for VP9.
    return {MediaCodec::Vp8, MediaCodecConfigurationKind::VpcC};
  }
#endif
  return {};
}

// VP9 and VP8 in Matroska/WebM normally carry no CodecPrivate, so their facts
// have to come from the bitstream. Reads the leading bytes of the first
// keyframe of `trackNumber` within the first `maximumClusters` Clusters --
// enough for the VP9 uncompressed frame header or the VP8 key frame header and
// no more. Keyframe identification is the same codec-agnostic rule the cursor
// uses.
constexpr std::size_t kVp9KeyframeProbeClusters{4};

[[nodiscard]] bool readFirstVideoKeyframePrefix(
    SeekableByteReader& reader, std::span<const Cluster> clusters,
    const ParseOptions& options, std::uint64_t trackNumber,
    std::span<std::byte> prefix, std::size_t* copied,
    CancellationToken cancellation) {
  CapturedBlockVisitor visitor;
  const std::size_t end =
      std::min<std::size_t>(clusters.size(), kVp9KeyframeProbeClusters);
  for (std::size_t index = 0; index < end; ++index) {
    if (cancellation.cancelled()) {
      return false;
    }
    auto cursor =
        beginClusterChildCursor(reader, clusters[index].data, options);
    if (!cursor) {
      return false;
    }
    while (!cursor->done()) {
      visitor.reset();
      const ParseOutcome outcome = parseClusterChildAt(
          reader, *cursor, visitor, options, cancellation);
      if (!outcome.ok()) {
        return false;
      }
      if (!visitor.emitted || visitor.header.trackNumber != trackNumber) {
        continue;
      }
      const bool keyFrame = visitor.header.simpleBlock
                                ? visitor.header.keyFrame
                                : visitor.referenceCount == 0;
      if (!keyFrame) {
        continue;
      }
      // A laced or multi-frame video Block is rejected by the cursor anyway;
      // proving facts from one is not something this admission will attempt.
      if (visitor.frameCount != 1 ||
          visitor.header.lacing != Lacing::None) {
        return false;
      }
      const ByteRange frame = visitor.frames[0].bytes;
      const auto amount = static_cast<std::size_t>(
          std::min<std::uint64_t>(frame.size, prefix.size()));
      if (amount == 0 || !reader.readAt(frame.offset, prefix.first(amount))) {
        return false;
      }
      *copied = amount;
      return true;
    }
  }
  return false;
}

[[nodiscard]] bool makeVideoDescriptor(
    SeekableByteReader& reader, const TrackEntry& entry,
    const MediaSourceLimits& limits, MediaTime duration,
    std::span<const Cluster> clusters,
    std::span<const TrackConstraint> constraints,
    CancellationToken cancellation, MediaTrackDescriptor* result,
    TrackRuntime* runtime) {
  if (!entry.video || !selectedTrackFeaturesSupported(entry)) {
    return false;
  }
  const auto id = trackId(entry.number);
  if (!id) {
    return false;
  }
  const VideoCodecIdentity identity =
      videoCodecIdentity(inlineString(entry.codecId));
  const MediaCodec codec = identity.codec;
  const MediaCodecConfigurationKind kind = identity.kind;
  // CodecPrivate is the only fact source for AVC, HEVC, and AV1, so it stays
  // mandatory for them. VP9 and VP8 are the exceptions: WebM muxers routinely
  // write no CodecPrivate at all because both bitstreams are self-describing,
  // so a missing one is normal rather than a defect. VP8 goes further -- RFC
  // 6386 defines no configuration record, so a VP8 CodecPrivate is refused
  // outright below rather than adopted.
  if (codec == MediaCodec::Unknown ||
      (!entry.codecPrivate && codec != MediaCodec::Vp9 &&
       codec != MediaCodec::Vp8)) {
    return false;
  }
  // FlagInterlaced 0 (undetermined) and 2 (progressive) are the only values a
  // progressive-only v1 renderer can admit; 1 is interlaced content.
  if ((entry.video->interlaced != 0 && entry.video->interlaced != 2) ||
      entry.video->stereoMode != 0 || entry.video->alphaMode != 0 ||
      entry.video->projectionPresent ||
      entry.video->colour.masteringMetadataPresent ||
      entry.video->colour.maximumContentLightLevel ||
      entry.video->colour.maximumFrameAverageLightLevel) {
    return false;
  }
  std::vector<std::byte> configuration;
  if (entry.codecPrivate &&
      !readRange(reader, *entry.codecPrivate, &configuration, cancellation)) {
    return false;
  }
  VideoCodecConfigurationLimits codecLimits;
  codecLimits.maximumConfigurationBytes = limits.maximumCodecConfigurationBytes;
  codecLimits.maximumWidth = limits.maximumCodedWidth;
  codecLimits.maximumHeight = limits.maximumCodedHeight;
  codecLimits.maximumPixels = limits.maximumCodedPixels;

  VideoCodecConfigurationInspection inspection;
  if (codec == MediaCodec::Vp8) {
    // RFC 6386 defines no VP8 configuration record, so a CodecPrivate on a
    // V_VP8 track describes nothing this decoder could honour and is refused
    // rather than ignored: adopting it silently would make a mux that carries
    // one indistinguishable from a conforming one.
    if (!configuration.empty()) {
      return false;
    }
    std::array<std::byte, kVp8KeyframeHeaderMaximumBytes> keyframe{};
    std::size_t keyframeBytes = 0;
    const ParseOptions options = parserOptions(limits, constraints);
    if (!readFirstVideoKeyframePrefix(reader, clusters, options, entry.number,
                                      keyframe, &keyframeBytes,
                                      cancellation) ||
        keyframeBytes != keyframe.size()) {
      return false;
    }
    inspection = inspectVp8BitstreamKeyframe(keyframe, codecLimits);
    if (!inspection.admitted()) {
      return false;
    }
    // Nothing in the native lane parses this back -- libvpx needs no
    // configuration at all -- but the whole pipeline's codec-configuration
    // envelope is "nonempty and bounded", so VP8 states its proven facts as a
    // vpcC rather than becoming the one codec with an empty record.
    std::array<std::byte, kVideoCodecVpcCBytes> synthesized{};
    if (!buildVp8CodecConfiguration(*inspection.facts, synthesized)) {
      return false;
    }
    configuration.assign(synthesized.begin(), synthesized.end());
  } else if (codec == MediaCodec::Vp9) {
    // The proven facts come from the bitstream in every VP9 case, present
    // CodecPrivate or not, because a vpcC carries no dimensions and the exact
    // PixelWidth/PixelHeight cross-check below must keep working.
    std::array<std::byte, kVp9KeyframeHeaderMaximumBytes> keyframe{};
    std::size_t keyframeBytes = 0;
    const ParseOptions options = parserOptions(limits, constraints);
    if (!readFirstVideoKeyframePrefix(reader, clusters, options, entry.number,
                                      keyframe, &keyframeBytes,
                                      cancellation)) {
      return false;
    }
    inspection = inspectVp9BitstreamKeyframe(
        std::span<const std::byte>(keyframe).first(keyframeBytes), codecLimits);
    if (!inspection.admitted()) {
      return false;
    }
    if (configuration.empty()) {
      // VideoToolbox returns kVTCouldNotFindVideoDecoderErr for VP9 unless the
      // format description carries a vpcC atom, so one is synthesized from the
      // proven bitstream facts rather than left absent.
      std::array<std::byte, kVideoCodecVpcCBytes> synthesized{};
      if (!buildVp9CodecConfiguration(*inspection.facts, synthesized)) {
        return false;
      }
      configuration.assign(synthesized.begin(), synthesized.end());
    } else {
      // A real vpcC is adopted byte-identically, mirroring avcC and hvcC, but
      // only after it is shown to describe the same stream the keyframe does.
      const auto declared = inspectVideoCodecConfiguration(
          codec, kind, configuration, codecLimits);
      if (!declared.admitted() ||
          declared.facts->profile != inspection.facts->profile ||
          declared.facts->bitDepth != inspection.facts->bitDepth ||
          declared.facts->sampleFormat != inspection.facts->sampleFormat) {
        return false;
      }
    }
  } else if (codec == MediaCodec::Mpeg4Visual) {
    // CodecPrivate is the raw start-code-delimited VisualObjectSequence, which
    // is where every fact lives -- including the profile gate that refuses
    // Advanced Simple Profile, the one thing VideoToolbox will not decode.
    inspection = inspectMpeg4VisualHeaders(configuration, codecLimits);
    if (!inspection.admitted()) {
      return false;
    }
    // CoreMedia will not build an 'mp4v' format description from the raw
    // headers; it needs them inside an ES_Descriptor. Synthesizing the esds
    // here, once, is the same move VP8 and VP9 make with their vpcC, and it
    // keeps both CoreMedia attachment sites free of any codec-specific
    // transform: they hand the stored record to CFDataCreate verbatim, exactly
    // as they do for avcC and hvcC.
    std::vector<std::byte> esds(kMpeg4VisualEsdsOverheadBytes +
                                configuration.size());
    std::size_t esdsBytes = 0;
    if (!buildMpeg4VisualEsds(configuration, esds, &esdsBytes, codecLimits) ||
        esdsBytes != esds.size() ||
        esds.size() > limits.maximumCodecConfigurationBytes) {
      return false;
    }
    configuration = std::move(esds);
  } else {
    inspection =
        inspectVideoCodecConfiguration(codec, kind, configuration, codecLimits);
    if (!inspection.admitted()) {
      return false;
    }
  }
  const VideoCodecConfigurationFacts& facts = *inspection.facts;
  // DisplayUnit 0 is pixels; 4 is "unspecified" (Matroska v4), which carries
  // no display-size information at all and is therefore only admissible when
  // DisplayWidth/DisplayHeight are absent -- exactly the shape OBS records
  // (unit 4, no dims). Units 1-3 (centimetres, inches, display aspect ratio)
  // express a non-pixel display geometry this square-pixel v1 renderer does
  // not model, and stay rejected.
  const bool displayGeometryAdmitted =
      entry.video->displayUnit == 0
          ? (!entry.video->displayWidth ||
             *entry.video->displayWidth == facts.width) &&
                (!entry.video->displayHeight ||
                 *entry.video->displayHeight == facts.height)
          : entry.video->displayUnit == 4 && !entry.video->displayWidth &&
                !entry.video->displayHeight;
  if (!entry.video->pixelWidth || !entry.video->pixelHeight ||
      *entry.video->pixelWidth != facts.width ||
      *entry.video->pixelHeight != facts.height ||
      entry.video->cropTop != 0 || entry.video->cropBottom != 0 ||
      entry.video->cropLeft != 0 || entry.video->cropRight != 0 ||
      !displayGeometryAdmitted) {
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

// Both ends of the Opus packet grid, proven from the bitstream rather than
// assumed. The head gives the constant packet duration; the tail gives the
// exact sample count, which is the only way to state a duration that agrees
// with the DiscardPadding trim.
struct OpusPacketGridProbe {
  std::uint32_t samplesPerAccessUnit{0};
  std::uint64_t tailBlockOffset{0};
  std::int64_t tailBlockTick{0};
  std::uint16_t tailBlockFrameCount{0};
  std::int64_t tailDiscardPaddingNanoseconds{0};
  bool found{false};
};

// Visits every Block belonging to one track inside one cluster. Shared by the
// Opus and Vorbis probes so the tail search below has exactly one
// implementation.
template <typename OnBlock>
[[nodiscard]] bool visitTrackBlocksInCluster(
    SeekableByteReader& reader, const Cluster& cluster,
    const ParseOptions& options, std::uint64_t trackNumber,
    CancellationToken cancellation, std::size_t index, const OnBlock& onBlock) {
  auto cursor = beginClusterChildCursor(reader, cluster.data, options);
  if (!cursor) {
    return false;
  }
  CapturedBlockVisitor visitor;
  while (!cursor->done()) {
    visitor.reset();
    const ParseOutcome outcome =
        parseClusterChildAt(reader, *cursor, visitor, options, cancellation);
    if (!outcome.ok()) {
      return false;
    }
    if (!visitor.emitted || visitor.header.trackNumber != trackNumber) {
      continue;
    }
    if (!onBlock(index, visitor)) {
      return false;
    }
  }
  return true;
}

// Tail: the last audio Block in the file carries the DiscardPadding, so the
// exact end of the decoded stream is its grid end minus that padding. Codec
// independent -- both Opus and Vorbis state their end-of-stream overrun this
// way.
[[nodiscard]] bool probeAudioTailBlock(
    SeekableByteReader& reader, std::span<const Cluster> clusters,
    const ParseOptions& options, std::uint64_t trackNumber,
    CancellationToken cancellation, OpusPacketGridProbe* probe) {
  const std::size_t tailStart =
      clusters.size() > kOpusTailProbeClusters
          ? clusters.size() - kOpusTailProbeClusters
          : 0;
  for (std::size_t index = tailStart; index < clusters.size(); ++index) {
    if (cancellation.cancelled()) {
      return false;
    }
    if (!clusters[index].timestamp) {
      return false;
    }
    bool failed = false;
    if (!visitTrackBlocksInCluster(
            reader, clusters[index], options, trackNumber, cancellation, index,
            [&](std::size_t clusterIndex, const CapturedBlockVisitor& block) {
              const auto tick = signedBlockTick(
                  *clusters[clusterIndex].timestamp,
                  block.header.relativeTimestamp);
              if (!tick || block.frameCount == 0) {
                failed = true;
                return false;
              }
              probe->tailBlockOffset = block.header.containerEncoded.offset;
              probe->tailBlockTick = *tick;
              probe->tailBlockFrameCount = block.frameCount;
              probe->tailDiscardPaddingNanoseconds =
                  block.group.discardPaddingNanoseconds.value_or(0);
              probe->found = true;
              return true;
            })) {
      return false;
    }
    if (failed) {
      return false;
    }
  }
  return probe->found;
}

[[nodiscard]] bool probeOpusPacketGrid(
    SeekableByteReader& reader, std::span<const Cluster> clusters,
    const ParseOptions& options, std::uint64_t trackNumber,
    CancellationToken cancellation, OpusPacketGridProbe* probe) {
  if (clusters.empty()) {
    return false;
  }
  const auto visitCluster = [&](std::size_t index,
                                const auto& onBlock) -> bool {
    return visitTrackBlocksInCluster(reader, clusters[index], options,
                                     trackNumber, cancellation, index, onBlock);
  };

  // Head: the first audio Block's first frame states the packet duration the
  // whole track must keep. Every later Block is re-checked in the cursor.
  bool headFound = false;
  for (std::size_t index = 0; index < clusters.size() && !headFound; ++index) {
    if (cancellation.cancelled()) {
      return false;
    }
    bool failed = false;
    if (!visitCluster(index, [&](std::size_t, const CapturedBlockVisitor& block) {
          if (headFound) {
            return true;
          }
          if (block.frameCount == 0) {
            failed = true;
            return false;
          }
          std::array<std::byte, 2> toc{};
          const ByteRange frame = block.frames[0].bytes;
          const auto amount = static_cast<std::size_t>(
              std::min<std::uint64_t>(frame.size, toc.size()));
          if (amount == 0 ||
              !reader.readAt(frame.offset, std::span<std::byte>(toc).first(amount))) {
            failed = true;
            return false;
          }
          const auto frames = opusPacketFrameCount(
              std::span<const std::byte>(toc).first(amount));
          if (!frames) {
            failed = true;
            return false;
          }
          probe->samplesPerAccessUnit = *frames;
          headFound = true;
          return true;
        })) {
      return false;
    }
    if (failed) {
      return false;
    }
  }
  if (!headFound) {
    return false;
  }

  return probeAudioTailBlock(reader, clusters, options, trackNumber,
                             cancellation, probe);
}

// Reads the first frame of the first Block belonging to an audio track.
//
// AC-3, E-AC-3 and MP3 carry NO CodecPrivate -- every parameter the pipeline
// needs is restated in each syncframe -- so this is where their admission gets
// its bytes. It is the exact analogue of the head half of
// probeOpusPacketGrid, which reads the first packet's TOC for the same reason.
[[nodiscard]] bool probeFirstAudioFrame(
    SeekableByteReader& reader, std::span<const Cluster> clusters,
    const ParseOptions& options, std::uint64_t trackNumber,
    std::size_t maximumBytes, CancellationToken cancellation,
    std::vector<std::byte>* bytes) {
  bool found = false;
  for (std::size_t index = 0; index < clusters.size() && !found; ++index) {
    if (cancellation.cancelled()) {
      return false;
    }
    bool failed = false;
    if (!visitTrackBlocksInCluster(
            reader, clusters[index], options, trackNumber, cancellation, index,
            [&](std::size_t, const CapturedBlockVisitor& block) {
              if (found) {
                return true;
              }
              if (block.frameCount == 0) {
                failed = true;
                return false;
              }
              const ByteRange frame = block.frames[0].bytes;
              if (frame.size == 0 || frame.size > maximumBytes) {
                failed = true;
                return false;
              }
              try {
                bytes->resize(static_cast<std::size_t>(frame.size));
              } catch (...) {
                failed = true;
                return false;
              }
              if (!reader.readAt(frame.offset, std::span<std::byte>(*bytes))) {
                failed = true;
                return false;
              }
              found = true;
              return true;
            })) {
      return false;
    }
    if (failed) {
      return false;
    }
  }
  return found;
}

// The exact end of a decoded audio stream, in track-rate frames from media
// zero, shared by every codec whose duration is derived rather than read:
//
//   published = (lastOrdinal + lacedFrames) * S - CodecDelay - tailTrim
//
// which is the Opus identity with the pre-skip generalised to CodecDelay. The
// tail trim is the LARGER of what the container asks for (DiscardPadding) and
// what the decoder withholds anyway (kAc3DecoderTailShortfallFrames for AC-3,
// zero for everything else). Taking the maximum is what keeps the stated
// duration equal to what the pipeline can actually render: a ceiling above the
// renderable count would leave the clock waiting at end of file for frames
// that never arrive, and one below it would truncate audible samples.
struct ExactAudioDuration {
  MediaTime duration{0, 1};
  std::uint32_t discardFrames{0};
  std::uint64_t endFrame{0};
};

[[nodiscard]] bool exactAudioDurationFromTail(
    const OpusPacketGridProbe& probe, std::uint32_t sampleRate,
    std::uint32_t samplesPerAccessUnit,
    std::uint64_t timestampScaleNanoseconds, std::uint32_t codecDelayFrames,
    std::uint32_t decoderTailShortfallFrames, std::int64_t tickTolerance,
    ExactAudioDuration* out) noexcept {
  if (sampleRate == 0U || samplesPerAccessUnit == 0U) {
    return false;
  }
  const auto tailProjection = nearestAacAccessUnitForMatroskaTick(
      probe.tailBlockTick, MediaTime{0, 1}, sampleRate,
      timestampScaleNanoseconds, samplesPerAccessUnit);
  if (!aacProjectionOnGrid(tailProjection, tickTolerance)) {
    return false;
  }
  // A DiscardPadding of a whole access unit or more would mean the final Block
  // contributes nothing, which no muxer emits and the ordinal arithmetic below
  // does not model.
  const auto discardFrames = matroskaFramesFromNanoseconds(
      probe.tailDiscardPaddingNanoseconds, sampleRate,
      samplesPerAccessUnit - 1U);
  if (!discardFrames) {
    return false;
  }
  const std::uint32_t tailTrim =
      std::max(*discardFrames, decoderTailShortfallFrames);
  if (tailTrim >= samplesPerAccessUnit) {
    return false;
  }
  const __int128 endOrdinal =
      static_cast<__int128>(tailProjection->accessUnitOrdinal) +
      static_cast<__int128>(probe.tailBlockFrameCount);
  const __int128 endFrame =
      endOrdinal * static_cast<__int128>(samplesPerAccessUnit) -
      static_cast<__int128>(codecDelayFrames) -
      static_cast<__int128>(tailTrim);
  if (endFrame <= 0 ||
      endFrame > static_cast<__int128>(std::numeric_limits<std::int64_t>::max())) {
    return false;
  }
  const auto endFrameValue = static_cast<std::uint64_t>(endFrame);
  const std::uint64_t divisor =
      std::gcd(endFrameValue, static_cast<std::uint64_t>(sampleRate));
  const MediaTime duration{static_cast<std::int64_t>(endFrameValue / divisor),
                           static_cast<std::int32_t>(sampleRate / divisor)};
  if (!duration.valid()) {
    return false;
  }
  out->duration = duration;
  out->discardFrames = *discardFrames;
  out->endFrame = endFrameValue;
  return true;
}

// The presentation-grid origin for a track whose access unit 0 presents
// codecDelayFrames early. Reduced in the frame domain so no nanosecond
// rounding can ever enter the origin.
[[nodiscard]] bool exactPresentationOrigin(std::uint32_t codecDelayFrames,
                                           std::uint32_t sampleRate,
                                           MediaTime* origin) noexcept {
  if (sampleRate == 0U) {
    return false;
  }
  if (codecDelayFrames == 0U) {
    *origin = MediaTime{0, 1};
    return true;
  }
  const std::uint64_t divisor =
      std::gcd(static_cast<std::uint64_t>(codecDelayFrames),
               static_cast<std::uint64_t>(sampleRate));
  const MediaTime candidate{
      -static_cast<std::int64_t>(codecDelayFrames / divisor),
      static_cast<std::int32_t>(sampleRate / divisor)};
  if (!candidate.valid()) {
    return false;
  }
  *origin = candidate;
  return true;
}

// Shared tail of every audio descriptor added by this sweep: the fields are
// identical once the codec-specific admission has produced a sample rate, a
// channel count, an access unit size, a magic cookie and an exact duration.
struct AudioDescriptorFields {
  MediaCodec codec{MediaCodec::Unknown};
  std::uint32_t formatTag{0};
  std::uint32_t sampleRate{0};
  std::uint8_t channelCount{0};
  std::uint32_t samplesPerAccessUnit{0};
  std::uint32_t codecDelayFrames{0};
  MediaTime duration{0, 1};
  MediaTime origin{0, 1};
  std::span<const std::byte> magicCookie{};
  bool tailBlockKnown{false};
  std::uint64_t tailBlockOffset{0};
  std::int64_t tailDiscardPaddingNanoseconds{0};
};

// Mono and stereo keep their exact canonical tags. A WIDER layout states no
// tag at all, deliberately.
//
// This demuxer knows a channel COUNT; it does not know AudioToolbox's
// per-codec channel-order convention, and the four decoders measured for the
// downmix work emit three different 5.1 orders (AAC C L R Ls Rs LFE, AC-3 and
// E-AC-3 L C R Ls Rs LFE, FLAC L R C LFE Ls Rs). Inventing a CoreAudio tag
// here would be guessing at that convention, and a wrong guess puts dialogue
// in the surround channel with no other symptom. Measured on the same
// fixtures: AudioConverter reports the identical output channel layout
// whether or not an input layout is supplied, so supplying none costs nothing
// and the platform layer reads the authoritative order back from the decoder
// itself.
void applyChannelLayoutTag(MediaAudioFormat* format,
                           std::uint32_t channelCount) noexcept {
  if (channelCount == 1) {
    format->channelLayoutTag = kMonoLayoutTag;
    format->channelLayoutPresent = true;
    return;
  }
  if (channelCount == 2) {
    format->channelLayoutTag = kStereoLayoutTag;
    format->channelLayoutPresent = true;
    return;
  }
  format->channelLayoutTag = 0;
  format->channelLayoutPresent = false;
}

void fillAudioDescriptor(const TrackEntry& entry, MediaTrackId id,
                         const AudioDescriptorFields& fields,
                         MediaTrackDescriptor* result, TrackRuntime* runtime) {
  result->id = id;
  result->kind = MediaTrackKind::Audio;
  result->codec = fields.codec;
  result->timeBase =
      MediaTime{1, static_cast<std::int32_t>(fields.sampleRate)};
  // As with Opus and Vorbis, this is NOT the container's declared Duration: it
  // is the exact decoded sample count after every trim, which the audio
  // consumer uses as the tail-trim ceiling.
  result->duration = fields.duration;
  result->language = inlineString(entry.language);
  result->codecConfigurationKind = MediaCodecConfigurationKind::AudioMagicCookie;
  result->codecConfiguration.assign(fields.magicCookie.begin(),
                                    fields.magicCookie.end());
  MediaAudioFormat format;
  format.sampleRate = fields.sampleRate;
  format.channels = fields.channelCount;
  format.formatTag = fields.formatTag;
  format.framesPerPacket = fields.samplesPerAccessUnit;
  applyChannelLayoutTag(&format, fields.channelCount);
  result->audio = format;
  runtime->entry = entry;
  runtime->id = id;
  runtime->kind = MediaTrackKind::Audio;
  runtime->codec = fields.codec;
  runtime->audioSampleRate = fields.sampleRate;
  runtime->audioSamplesPerAccessUnit = fields.samplesPerAccessUnit;
  runtime->audioPresentationOrigin = fields.origin;
  // Two ticks, for the reason the Opus work established: ffmpeg builds a Block
  // timestamp as round(presentationMs) + round(delayMs), two roundings that add
  // a systematic tick on top of ordinary cluster jitter. Still an order of
  // magnitude below one access unit for every codec here (32 ticks for AC-3,
  // 26 for MP3, 21 for AAC, 104 for FLAC), so a Block misplaced by whole
  // access units is still rejected.
  runtime->audioTickResidualTolerance = kMaximumOpusGridTickResidual;
  runtime->audioGridOffsetFrames = fields.codecDelayFrames;
  runtime->audioPrimingAccessUnits = kAacPrimingAccessUnits;
  runtime->audioTailBlockKnown = fields.tailBlockKnown;
  runtime->audioTailBlockOffset = fields.tailBlockOffset;
  runtime->audioTailDiscardPaddingNanoseconds =
      fields.tailDiscardPaddingNanoseconds;
}

// Common admission gates for the codecs this sweep adds. CodecDelay is allowed
// (and then proven exactly, per codec); SeekPreRoll is not -- none of these
// formats states one, and a mux that does is describing warm-up this path has
// not reasoned about.
[[nodiscard]] bool sweepTrackFeaturesSupported(const TrackEntry& entry) noexcept {
  return entry.audio && entry.seekPreRollNanoseconds == 0 &&
         selectedTrackFeaturesSupported(entry, true) &&
         !entry.audio->outputSamplingFrequency;
}

[[nodiscard]] bool audioFormatAgrees(const TrackEntry& entry,
                                     const MediaSourceLimits& limits,
                                     std::uint32_t sampleRate,
                                     std::uint8_t channelCount) noexcept {
  // Multichannel USED to be refused here, because the whole output chain is
  // stereo (NativePcmRing::kChannels == 2) and AudioConverter's own 5.1
  // downmix is unacceptable for both families in this sweep: AC-3 gets a
  // normalised Lt/Rt at -10.70 dB against ffmpeg's Lo/Ro, and FLAC has
  // centre, LFE and both surrounds silently dropped. Both were re-measured
  // and still hold.
  //
  // The player no longer asks AudioConverter to downmix. It decodes the full
  // native layout and folds it to stereo itself with exact BS.775 coefficients
  // (media::applyStereoDownmix), verified against ffmpeg's and mpv's own
  // output channel by channel. So the count bound here is simply the neutral
  // source limit; a layout the fold cannot state exactly is still refused, but
  // it is refused by the platform layer that can actually see the decoder's
  // channel labels.
  return channelCount >= 1U &&
         sampleRate <= limits.maximumAudioSampleRate &&
         channelCount <= limits.maximumAudioChannels &&
         entry.audio->samplingFrequency == static_cast<double>(sampleRate) &&
         entry.audio->channels == channelCount;
}

[[nodiscard]] bool makeAc3AudioDescriptor(
    SeekableByteReader& reader, const TrackEntry& entry,
    const MediaSourceLimits& limits, std::span<const Cluster> clusters,
    std::span<const TrackConstraint> constraints,
    std::uint64_t timestampScaleNanoseconds, bool enhanced,
    CancellationToken cancellation, MediaTrackDescriptor* result,
    TrackRuntime* runtime) {
  const auto id = trackId(entry.number);
  // AC-3 states everything in-band, so a CodecPrivate would be a blob this
  // source does not interpret. Refuse rather than ignore it.
  if (!id || !sweepTrackFeaturesSupported(entry) ||
      (entry.codecPrivate && entry.codecPrivate->size != 0)) {
    return false;
  }
  ParseOptions options = parserOptions(limits, constraints);
  std::vector<std::byte> frame;
  if (!probeFirstAudioFrame(reader, clusters, options, entry.number,
                            static_cast<std::size_t>(
                                limits.maximumAudioSampleBytes),
                            cancellation, &frame)) {
    return false;
  }
  const Ac3Admission admission = parseAc3Syncframe(frame, enhanced);
  if (!admission.admitted()) {
    return false;
  }
  const Ac3Configuration& configuration = *admission.configuration;
  if (!audioFormatAgrees(entry, limits, configuration.sampleRate,
                         configuration.channelCount)) {
    return false;
  }
  // THE identity that makes the AC-3 trim exact: AudioToolbox swallows a fixed
  // 256-frame decoder delay, and every real mux states exactly that number as
  // CodecDelay. Requiring them to agree means the head trim is provably zero
  // instead of derived, and a mux that disagrees falls back rather than being
  // played 5 ms out of sync. The comparison is made in the frame domain the
  // nanosecond value was rounded from.
  if (entry.codecDelayNanoseconds >
      static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
    return false;
  }
  const auto codecDelayFrames = matroskaFramesFromNanoseconds(
      static_cast<std::int64_t>(entry.codecDelayNanoseconds),
      configuration.sampleRate, configuration.samplesPerAccessUnit - 1U);
  if (!codecDelayFrames || *codecDelayFrames != kAc3DecoderDelayFrames) {
    return false;
  }

  OpusPacketGridProbe probe;
  probe.samplesPerAccessUnit = configuration.samplesPerAccessUnit;
  if (!probeAudioTailBlock(reader, clusters, options, entry.number,
                           cancellation, &probe)) {
    return false;
  }
  ExactAudioDuration exact;
  if (!exactAudioDurationFromTail(
          probe, configuration.sampleRate, configuration.samplesPerAccessUnit,
          timestampScaleNanoseconds, *codecDelayFrames,
          kAc3DecoderTailShortfallFrames, kMaximumOpusGridTickResidual,
          &exact)) {
    return false;
  }
  MediaTime origin;
  if (!exactPresentationOrigin(*codecDelayFrames, configuration.sampleRate,
                               &origin)) {
    return false;
  }

  AudioDescriptorFields fields;
  fields.codec = enhanced ? MediaCodec::Eac3 : MediaCodec::Ac3;
  fields.formatTag = enhanced ? kEnhancedAc3FormatTag : kAc3FormatTag;
  fields.sampleRate = configuration.sampleRate;
  fields.channelCount = configuration.channelCount;
  fields.samplesPerAccessUnit = configuration.samplesPerAccessUnit;
  fields.codecDelayFrames = *codecDelayFrames;
  fields.duration = exact.duration;
  fields.origin = origin;
  // AC-3 takes no magic cookie at all -- measured: AudioConverterNew succeeds
  // and decodes with the property never set.
  fields.magicCookie = {};
  fields.tailBlockKnown = true;
  fields.tailBlockOffset = probe.tailBlockOffset;
  fields.tailDiscardPaddingNanoseconds = probe.tailDiscardPaddingNanoseconds;
  fillAudioDescriptor(entry, *id, fields, result, runtime);
  result->codecConfigurationKind = MediaCodecConfigurationKind::None;
  return true;
}

[[nodiscard]] bool makeMpegAudioDescriptor(
    SeekableByteReader& reader, const TrackEntry& entry,
    const MediaSourceLimits& limits, std::span<const Cluster> clusters,
    std::span<const TrackConstraint> constraints,
    std::uint64_t timestampScaleNanoseconds, CancellationToken cancellation,
    MediaTrackDescriptor* result, TrackRuntime* runtime) {
  const auto id = trackId(entry.number);
  if (!id || !sweepTrackFeaturesSupported(entry) ||
      (entry.codecPrivate && entry.codecPrivate->size != 0)) {
    return false;
  }
  ParseOptions options = parserOptions(limits, constraints);
  std::vector<std::byte> frame;
  if (!probeFirstAudioFrame(reader, clusters, options, entry.number,
                            static_cast<std::size_t>(
                                limits.maximumAudioSampleBytes),
                            cancellation, &frame)) {
    return false;
  }
  const MpegAudioAdmission admission = parseMpegAudioFrameHeader(frame);
  if (!admission.admitted()) {
    return false;
  }
  const MpegAudioConfiguration& configuration = *admission.configuration;
  if (!audioFormatAgrees(entry, limits, configuration.sampleRate,
                         configuration.channelCount)) {
    return false;
  }
  if (entry.codecDelayNanoseconds >
      static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
    return false;
  }
  // MP3's CodecDelay is the LAME encoder delay PLUS the 529-frame decoder
  // delay, and AudioToolbox swallows the decoder half itself. So the container
  // must state at least the decoder's own delay -- a smaller value could not
  // have come from a real mux and would ask for a negative head trim.
  const auto codecDelayFrames = matroskaFramesFromNanoseconds(
      static_cast<std::int64_t>(entry.codecDelayNanoseconds),
      configuration.sampleRate, configuration.samplesPerAccessUnit - 1U);
  if (!codecDelayFrames || *codecDelayFrames < kMpegLayer3DecoderDelayFrames) {
    return false;
  }

  OpusPacketGridProbe probe;
  probe.samplesPerAccessUnit = configuration.samplesPerAccessUnit;
  if (!probeAudioTailBlock(reader, clusters, options, entry.number,
                           cancellation, &probe)) {
    return false;
  }
  ExactAudioDuration exact;
  if (!exactAudioDurationFromTail(probe, configuration.sampleRate,
                                  configuration.samplesPerAccessUnit,
                                  timestampScaleNanoseconds, *codecDelayFrames,
                                  0U, kMaximumOpusGridTickResidual, &exact)) {
    return false;
  }
  MediaTime origin;
  if (!exactPresentationOrigin(*codecDelayFrames, configuration.sampleRate,
                               &origin)) {
    return false;
  }

  AudioDescriptorFields fields;
  fields.codec = MediaCodec::Mp3;
  fields.formatTag = kMpegLayer3FormatTag;
  fields.sampleRate = configuration.sampleRate;
  fields.channelCount = configuration.channelCount;
  fields.samplesPerAccessUnit = configuration.samplesPerAccessUnit;
  fields.codecDelayFrames = *codecDelayFrames;
  fields.duration = exact.duration;
  fields.origin = origin;
  fields.magicCookie = {};
  fields.tailBlockKnown = true;
  fields.tailBlockOffset = probe.tailBlockOffset;
  fields.tailDiscardPaddingNanoseconds = probe.tailDiscardPaddingNanoseconds;
  fillAudioDescriptor(entry, *id, fields, result, runtime);
  result->codecConfigurationKind = MediaCodecConfigurationKind::None;
  return true;
}

[[nodiscard]] bool makeFlacAudioDescriptor(
    SeekableByteReader& reader, const TrackEntry& entry,
    const MediaSourceLimits& limits, std::span<const Cluster> clusters,
    std::span<const TrackConstraint> constraints,
    std::uint64_t timestampScaleNanoseconds, CancellationToken cancellation,
    MediaTrackDescriptor* result, TrackRuntime* runtime) {
  const auto id = trackId(entry.number);
  // FLAC states no CodecDelay: its decoder swallows nothing and its first
  // sample is media frame 0. A mux that claims otherwise is describing a
  // stream this path has not reasoned about.
  if (!id || !sweepTrackFeaturesSupported(entry) || !entry.codecPrivate ||
      entry.codecDelayNanoseconds != 0) {
    return false;
  }
  std::vector<std::byte> codecPrivate;
  if (!readRange(reader, *entry.codecPrivate, &codecPrivate, cancellation)) {
    return false;
  }
  const FlacAdmission admission = parseFlacCodecPrivate(codecPrivate);
  if (!admission.admitted()) {
    return false;
  }
  const FlacConfiguration& configuration = *admission.configuration;
  if (!audioFormatAgrees(entry, limits, configuration.sampleRate,
                         configuration.channelCount)) {
    return false;
  }
  const auto cookie = buildFlacMagicCookie(codecPrivate);
  if (!cookie) {
    return false;
  }

  // FLAC is the one codec here whose duration is READ rather than derived:
  // STREAMINFO carries the total decoded sample count. That number is still
  // cross-checked against the container, because two independent statements of
  // the same length that disagree mean one of them is wrong: the last Block
  // must be the access unit that CONTAINS the final sample.
  ParseOptions options = parserOptions(limits, constraints);
  OpusPacketGridProbe probe;
  probe.samplesPerAccessUnit = configuration.blockSize;
  if (!probeAudioTailBlock(reader, clusters, options, entry.number,
                           cancellation, &probe)) {
    return false;
  }
  // No FLAC mux states DiscardPadding, and honouring one would double-count
  // against STREAMINFO's total, so any value at all falls back.
  if (probe.tailDiscardPaddingNanoseconds != 0) {
    return false;
  }
  const auto tailProjection = nearestAacAccessUnitForMatroskaTick(
      probe.tailBlockTick, MediaTime{0, 1}, configuration.sampleRate,
      timestampScaleNanoseconds, configuration.blockSize);
  if (!aacProjectionOnGrid(tailProjection, kMaximumOpusGridTickResidual)) {
    return false;
  }
  const __int128 lastOrdinal =
      static_cast<__int128>(tailProjection->accessUnitOrdinal);
  const __int128 endOrdinal =
      lastOrdinal + static_cast<__int128>(probe.tailBlockFrameCount);
  const __int128 blockSize = static_cast<__int128>(configuration.blockSize);
  const __int128 total = static_cast<__int128>(configuration.totalSamples);
  // Strictly after the start of the final access unit and no later than its
  // end: FLAC's last frame is legitimately short, so equality is expected at
  // the top and impossible at the bottom.
  if (total <= (endOrdinal - 1) * blockSize || total > endOrdinal * blockSize) {
    return false;
  }
  if (total > static_cast<__int128>(std::numeric_limits<std::int64_t>::max())) {
    return false;
  }
  const std::uint64_t divisor =
      std::gcd(configuration.totalSamples,
               static_cast<std::uint64_t>(configuration.sampleRate));
  const MediaTime duration{
      static_cast<std::int64_t>(configuration.totalSamples / divisor),
      static_cast<std::int32_t>(configuration.sampleRate / divisor)};
  if (!duration.valid()) {
    return false;
  }

  AudioDescriptorFields fields;
  fields.codec = MediaCodec::Flac;
  fields.formatTag = kFlacFormatTag;
  fields.sampleRate = configuration.sampleRate;
  fields.channelCount = configuration.channelCount;
  fields.samplesPerAccessUnit = configuration.blockSize;
  fields.codecDelayFrames = 0;
  fields.duration = duration;
  fields.origin = MediaTime{0, 1};
  fields.magicCookie = cookie->view();
  // Deliberately false: with no DiscardPadding admitted anywhere, the cursor's
  // blockFeaturesSupported refuses every Block that carries one.
  fields.tailBlockKnown = false;
  fillAudioDescriptor(entry, *id, fields, result, runtime);
  return true;
}

[[nodiscard]] bool makeVorbisAudioDescriptor(
    SeekableByteReader& reader, const TrackEntry& entry,
    const MediaSourceLimits& limits, std::span<const Cluster> clusters,
    std::span<const TrackConstraint> constraints,
    std::uint64_t timestampScaleNanoseconds, CancellationToken cancellation,
    MediaTrackDescriptor* result, TrackRuntime* runtime) {
  const auto id = trackId(entry.number);
  // Vorbis carries a CodecDelay -- measured, not assumed: ffmpeg writes
  // 23,219,955 ns for a 44.1 kHz track, which is one 1024-frame block. It
  // states no SeekPreRoll, and a track that does is describing warm-up this
  // path has not reasoned about, so it still falls back.
  if (!id || !entry.audio || !entry.codecPrivate ||
      !selectedTrackFeaturesSupported(entry, true) ||
      entry.seekPreRollNanoseconds != 0U || clusters.empty()) {
    return false;
  }
  std::vector<std::byte> header;
  if (!readRange(reader, *entry.codecPrivate, &header, cancellation)) {
    return false;
  }
  const VorbisAdmission admission = parseVorbisCodecPrivate(header);
  if (!admission.admitted()) {
    return false;
  }
  const VorbisConfiguration& configuration = *admission.configuration;
  const std::uint32_t sampleRate = configuration.sampleRate;
  const std::uint32_t samplesPerAccessUnit =
      configuration.samplesPerAccessUnit();
  // The identification header and the Matroska Audio element must agree; a
  // disagreement means the container is describing a stream different from the
  // one the decoder would produce.
  if (entry.audio->samplingFrequency != static_cast<double>(sampleRate) ||
      entry.audio->channels != configuration.channelCount ||
      entry.audio->outputSamplingFrequency ||
      sampleRate > limits.maximumAudioSampleRate ||
      configuration.channelCount > limits.maximumAudioChannels ||
      samplesPerAccessUnit == 0U) {
    return false;
  }

  // THE identity that makes the Vorbis trim exact, and the happy discovery
  // that it is checkable at all: the offset of the presentation grid is
  // derived from the format (one overlap-add block, samplesPerAccessUnit
  // frames), and the container states the same number independently as
  // CodecDelay. Requiring them to agree means a file whose muxer disagreed
  // with the format falls back instead of being trimmed on a guess. The
  // comparison is made in the frame domain the nanosecond value was rounded
  // from, because 1024/44100 s is not a whole number of nanoseconds.
  if (entry.codecDelayNanoseconds >
      static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
    return false;
  }
  const auto codecDelayFrames = vorbisFramesFromNanoseconds(
      static_cast<std::int64_t>(entry.codecDelayNanoseconds), sampleRate);
  if (!codecDelayFrames || *codecDelayFrames != samplesPerAccessUnit) {
    return false;
  }

  ParseOptions options = parserOptions(limits, constraints);
  OpusPacketGridProbe probe;
  probe.samplesPerAccessUnit = samplesPerAccessUnit;
  if (!probeAudioTailBlock(reader, clusters, options, entry.number,
                           cancellation, &probe)) {
    return false;
  }
  // Vorbis states no SeekPreRoll. The AAC floor of two access units is already
  // what the format needs: one packet is swallowed as the decoder's lead-in and
  // the next primes the overlap-add window, so the first published frame after
  // a seek is fully reconstructed.
  const std::uint64_t priming = kAacPrimingAccessUnits;
  static_assert(kAacPrimingAccessUnits <= kMaximumAudioPrimingAccessUnits);

  // Presentation-grid origin is one access unit before zero: Vorbis' first
  // packet carries only half an overlap-add window and decodes to no samples,
  // so ordinal 0 presents samplesPerAccessUnit frames early. This is the exact
  // structural analogue of the Opus pre-skip and it flows through the same
  // fields. Reduced in the frame domain so no rounding enters the origin.
  const std::uint64_t originDivisor =
      std::gcd(static_cast<std::uint64_t>(samplesPerAccessUnit),
               static_cast<std::uint64_t>(sampleRate));
  const MediaTime origin{
      -static_cast<std::int64_t>(samplesPerAccessUnit / originDivisor),
      static_cast<std::int32_t>(sampleRate / originDivisor)};
  if (!origin.valid()) {
    return false;
  }

  // Exact end of the decoded stream, in track-rate frames from media zero:
  //   (lastOrdinal + lacedFrames) * samplesPerAccessUnit
  //     - samplesPerAccessUnit - discardPadding
  const auto tailProjection = nearestAacAccessUnitForMatroskaTick(
      probe.tailBlockTick, MediaTime{0, 1}, sampleRate,
      timestampScaleNanoseconds, samplesPerAccessUnit);
  if (!aacProjectionOnGrid(tailProjection, kMaximumOpusGridTickResidual)) {
    return false;
  }
  const auto discardFrames = vorbisFramesFromNanoseconds(
      probe.tailDiscardPaddingNanoseconds, sampleRate);
  if (!discardFrames || *discardFrames >= samplesPerAccessUnit) {
    return false;
  }
  const __int128 endOrdinal =
      static_cast<__int128>(tailProjection->accessUnitOrdinal) +
      static_cast<__int128>(probe.tailBlockFrameCount);
  const __int128 endFrame =
      endOrdinal * static_cast<__int128>(samplesPerAccessUnit) -
      static_cast<__int128>(samplesPerAccessUnit) -
      static_cast<__int128>(*discardFrames);
  if (endFrame <= 0 ||
      endFrame > static_cast<__int128>(std::numeric_limits<std::int64_t>::max())) {
    return false;
  }
  const auto endFrameValue = static_cast<std::uint64_t>(endFrame);
  const std::uint64_t durationDivisor =
      std::gcd(endFrameValue, static_cast<std::uint64_t>(sampleRate));
  const MediaTime exactDuration{
      static_cast<std::int64_t>(endFrameValue / durationDivisor),
      static_cast<std::int32_t>(sampleRate / durationDivisor)};
  if (!exactDuration.valid()) {
    return false;
  }

  result->id = *id;
  result->kind = MediaTrackKind::Audio;
  result->codec = MediaCodec::Vorbis;
  result->timeBase = MediaTime{1, static_cast<std::int32_t>(sampleRate)};
  // As with Opus, this is the exact decoded sample count after both trims, not
  // the container's declared Duration: the audio consumer uses it as the
  // tail-trim ceiling.
  result->duration = exactDuration;
  result->language = inlineString(entry.language);
  result->codecConfigurationKind = MediaCodecConfigurationKind::AudioMagicCookie;
  result->codecConfiguration.assign(header.begin(), header.end());
  MediaAudioFormat format;
  format.sampleRate = sampleRate;
  format.channels = configuration.channelCount;
  format.formatTag = kVorbisFormatTag;
  format.framesPerPacket = samplesPerAccessUnit;
  applyChannelLayoutTag(&format, configuration.channelCount);
  result->audio = format;
  runtime->entry = entry;
  runtime->id = *id;
  runtime->kind = MediaTrackKind::Audio;
  runtime->codec = MediaCodec::Vorbis;
  runtime->audioSampleRate = sampleRate;
  runtime->audioSamplesPerAccessUnit = samplesPerAccessUnit;
  runtime->audioPresentationOrigin = origin;
  // Measured worst residual on an ffmpeg mux is 0.72 ticks, which the AAC
  // tolerance of 1 would already pass. Two is kept because the residual is a
  // cluster-timestamp rounding artefact whose sign varies, and two ticks is
  // still an order of magnitude below one access unit (23 ticks at 1024
  // frames / 44.1 kHz).
  runtime->audioTickResidualTolerance = kMaximumOpusGridTickResidual;
  runtime->audioGridOffsetFrames = samplesPerAccessUnit;
  runtime->audioPrimingAccessUnits = priming;
  runtime->audioTailBlockKnown = true;
  runtime->audioTailBlockOffset = probe.tailBlockOffset;
  runtime->audioTailDiscardPaddingNanoseconds =
      probe.tailDiscardPaddingNanoseconds;
  return true;
}

[[nodiscard]] bool makeOpusAudioDescriptor(
    SeekableByteReader& reader, const TrackEntry& entry,
    const MediaSourceLimits& limits, std::span<const Cluster> clusters,
    std::span<const TrackConstraint> constraints,
    std::uint64_t timestampScaleNanoseconds, CancellationToken cancellation,
    MediaTrackDescriptor* result, TrackRuntime* runtime) {
  const auto id = trackId(entry.number);
  if (!id || !entry.audio || !entry.codecPrivate ||
      !selectedTrackFeaturesSupported(entry, true)) {
    return false;
  }
  std::vector<std::byte> header;
  if (!readRange(reader, *entry.codecPrivate, &header, cancellation)) {
    return false;
  }
  const OpusAdmission admission = parseOpusIdentificationHeader(header);
  if (!admission.admitted()) {
    return false;
  }
  const OpusConfiguration& configuration = *admission.configuration;
  // Opus always decodes at 48 kHz; a Matroska SamplingFrequency that says
  // anything else describes a stream this source would silently resample.
  if (entry.audio->samplingFrequency !=
          static_cast<double>(kOpusOutputSampleRate) ||
      entry.audio->channels != configuration.channelCount ||
      entry.audio->outputSamplingFrequency ||
      kOpusOutputSampleRate > limits.maximumAudioSampleRate ||
      configuration.channelCount > limits.maximumAudioChannels) {
    return false;
  }
  // THE identity that makes the whole trim exact: the container's CodecDelay
  // must be the header's pre-skip and nothing else. Everything downstream --
  // the presentation-grid origin, the head trim of preSkip - 120, the stated
  // duration -- is derived from one number, so the container's and the
  // header's statements of it must agree or the file falls back. CodecDelay is
  // stated in nanoseconds, which cannot express every frame count exactly, so
  // the comparison is made in the frame domain the value was rounded from.
  if (entry.codecDelayNanoseconds >
          static_cast<std::uint64_t>(
              std::numeric_limits<std::int64_t>::max())) {
    return false;
  }
  const auto codecDelayFrames = opusFramesFromNanoseconds(
      static_cast<std::int64_t>(entry.codecDelayNanoseconds));
  if (!codecDelayFrames || *codecDelayFrames != configuration.preSkipFrames) {
    return false;
  }
  ParseOptions options = parserOptions(limits, constraints);
  OpusPacketGridProbe probe;
  if (!probeOpusPacketGrid(reader, clusters, options, entry.number, cancellation,
                           &probe)) {
    return false;
  }
  // SeekPreRoll is what the encoder says the decoder needs after a jump.
  const std::uint64_t preRollFrames =
      entry.seekPreRollNanoseconds / UINT64_C(1'000'000'000) >
              kMaximumOpusPacketFrames
          ? 0U
          : entry.seekPreRollNanoseconds * kOpusOutputSampleRate /
                UINT64_C(1'000'000'000);
  const std::uint64_t preRollAccessUnits =
      (preRollFrames + probe.samplesPerAccessUnit - 1U) /
      probe.samplesPerAccessUnit;
  const std::uint64_t priming =
      std::max<std::uint64_t>(kAacPrimingAccessUnits, preRollAccessUnits);
  if (priming > kMaximumAudioPrimingAccessUnits) {
    return false;
  }

  // Presentation-grid origin is -CodecDelay exactly: ordinal 0 presents
  // preSkip frames before media time zero. Reduced in the 48 kHz frame domain
  // so no nanosecond rounding can ever enter the origin.
  const std::uint64_t originDivisor =
      std::gcd(static_cast<std::uint64_t>(configuration.preSkipFrames),
               static_cast<std::uint64_t>(kOpusOutputSampleRate));
  const MediaTime origin{
      -static_cast<std::int64_t>(configuration.preSkipFrames / originDivisor),
      static_cast<std::int32_t>(kOpusOutputSampleRate / originDivisor)};
  if (!origin.valid()) {
    return false;
  }

  // Exact end of the decoded stream, in 48 kHz frames from media time zero:
  //   (lastOrdinal + lacedFrames) * samplesPerAccessUnit
  //     - preSkip - discardPadding
  const auto tailProjection = nearestAacAccessUnitForMatroskaTick(
      probe.tailBlockTick, MediaTime{0, 1}, kOpusOutputSampleRate,
      timestampScaleNanoseconds, probe.samplesPerAccessUnit);
  if (!aacProjectionOnGrid(tailProjection, kMaximumOpusGridTickResidual)) {
    return false;
  }
  const auto discardFrames =
      opusFramesFromNanoseconds(probe.tailDiscardPaddingNanoseconds);
  const auto headTrim = opusHeadTrimFrames(configuration);
  if (!discardFrames || !headTrim ||
      *discardFrames >= probe.samplesPerAccessUnit) {
    return false;
  }
  const __int128 endOrdinal =
      static_cast<__int128>(tailProjection->accessUnitOrdinal) +
      static_cast<__int128>(probe.tailBlockFrameCount);
  const __int128 endFrame =
      endOrdinal * static_cast<__int128>(probe.samplesPerAccessUnit) -
      static_cast<__int128>(configuration.preSkipFrames) -
      static_cast<__int128>(*discardFrames);
  if (endFrame <= 0 ||
      endFrame > static_cast<__int128>(std::numeric_limits<std::int64_t>::max())) {
    return false;
  }
  const auto endFrameValue = static_cast<std::uint64_t>(endFrame);
  const std::uint64_t durationDivisor =
      std::gcd(endFrameValue, static_cast<std::uint64_t>(kOpusOutputSampleRate));
  const MediaTime exactDuration{
      static_cast<std::int64_t>(endFrameValue / durationDivisor),
      static_cast<std::int32_t>(kOpusOutputSampleRate / durationDivisor)};
  if (!exactDuration.valid()) {
    return false;
  }

  result->id = *id;
  result->kind = MediaTrackKind::Audio;
  result->codec = MediaCodec::Opus;
  result->timeBase =
      MediaTime{1, static_cast<std::int32_t>(kOpusOutputSampleRate)};
  // Unlike every other track duration in this demuxer, this one is NOT the
  // container's declared Duration: it is the exact decoded sample count after
  // both trims. The audio consumer uses it as the tail-trim ceiling, so an
  // approximate value here would be an approximate end of file.
  result->duration = exactDuration;
  result->language = inlineString(entry.language);
  result->codecConfigurationKind = MediaCodecConfigurationKind::AudioMagicCookie;
  result->codecConfiguration.assign(header.begin(), header.end());
  MediaAudioFormat format;
  format.sampleRate = kOpusOutputSampleRate;
  format.channels = configuration.channelCount;
  format.formatTag = kOpusFormatTag;
  format.framesPerPacket = probe.samplesPerAccessUnit;
  applyChannelLayoutTag(&format, configuration.channelCount);
  result->audio = format;
  runtime->entry = entry;
  runtime->id = *id;
  runtime->kind = MediaTrackKind::Audio;
  runtime->codec = MediaCodec::Opus;
  runtime->audioSampleRate = kOpusOutputSampleRate;
  runtime->audioSamplesPerAccessUnit = probe.samplesPerAccessUnit;
  runtime->audioPresentationOrigin = origin;
  runtime->audioTickResidualTolerance = kMaximumOpusGridTickResidual;
  runtime->audioGridOffsetFrames = configuration.preSkipFrames;
  runtime->audioPrimingAccessUnits = priming;
  runtime->audioTailBlockKnown = true;
  runtime->audioTailBlockOffset = probe.tailBlockOffset;
  runtime->audioTailDiscardPaddingNanoseconds =
      probe.tailDiscardPaddingNanoseconds;
  return true;
}

// The half of AAC-LC admission that is decided entirely by the track header:
// the CodecPrivate AudioSpecificConfig, and the Audio element that must agree
// with it. Nothing here reads a Cluster, which is what lets the cheap
// pre-admission pass in prepareMatroska ask exactly this question before the
// expensive cluster scan runs (see matroskaHeaderRefusal).
//
// Extracted rather than duplicated on purpose: this predicate and the caller
// below are the SAME rule, and a second copy of it drifting would mean the
// pre-pass refusing a file the authoritative pass admits, or the reverse.
//
// OutputSamplingFrequency must stay absent: a differing output rate signals
// SBR/HE-AAC, which is outside the AAC-LC envelope this source decodes.
//
// BitDepth is deliberately NOT a rejection. Matroska defines it for PCM; for
// a compressed AAC track it is informational and has no effect on the
// bitstream, the ASC, or the ES_Descriptor cookie. FFmpeg writes BitDepth=32
// on every AAC track it muxes (reflecting float decoder output), so rejecting
// its presence rejected essentially all real AAC-in-Matroska while the
// identical stream was admitted from MP4.
[[nodiscard]] bool aacLcHeaderAdmitted(const AacLcAdmission& admission,
                                       const TrackEntry& entry,
                                       const MediaSourceLimits& limits) {
  return entry.audio && admission.admitted() &&
         admission.configuration->sampleRate <= limits.maximumAudioSampleRate &&
         admission.configuration->channelCount <=
             limits.maximumAudioChannels &&
         entry.audio->samplingFrequency ==
             static_cast<double>(admission.configuration->sampleRate) &&
         entry.audio->channels == admission.configuration->channelCount &&
         !entry.audio->outputSamplingFrequency;
}

[[nodiscard]] bool makeAudioDescriptor(
    SeekableByteReader& reader, const TrackEntry& entry,
    const MediaSourceLimits& limits, MediaTime duration,
    std::span<const Cluster> clusters,
    std::span<const TrackConstraint> constraints,
    std::uint64_t timestampScaleNanoseconds,
    CancellationToken cancellation, MediaTrackDescriptor* result,
    TrackRuntime* runtime) {
  if (inlineString(entry.codecId) == "A_OPUS") {
    return makeOpusAudioDescriptor(reader, entry, limits, clusters, constraints,
                                   timestampScaleNanoseconds, cancellation,
                                   result, runtime);
  }
  if (inlineString(entry.codecId) == "A_VORBIS") {
    return makeVorbisAudioDescriptor(reader, entry, limits, clusters,
                                     constraints, timestampScaleNanoseconds,
                                     cancellation, result, runtime);
  }
  if (inlineString(entry.codecId) == "A_AC3") {
    return makeAc3AudioDescriptor(reader, entry, limits, clusters, constraints,
                                  timestampScaleNanoseconds, false,
                                  cancellation, result, runtime);
  }
  if (inlineString(entry.codecId) == "A_EAC3") {
    return makeAc3AudioDescriptor(reader, entry, limits, clusters, constraints,
                                  timestampScaleNanoseconds, true, cancellation,
                                  result, runtime);
  }
  if (inlineString(entry.codecId) == "A_MPEG/L3") {
    return makeMpegAudioDescriptor(reader, entry, limits, clusters, constraints,
                                   timestampScaleNanoseconds, cancellation,
                                   result, runtime);
  }
  if (inlineString(entry.codecId) == "A_FLAC") {
    return makeFlacAudioDescriptor(reader, entry, limits, clusters, constraints,
                                   timestampScaleNanoseconds, cancellation,
                                   result, runtime);
  }
  (void)duration;
  // AAC's CodecDelay used to be refused outright, which is why every AAC track
  // FFmpeg encodes -- as opposed to copies -- fell back as a whole file. It is
  // now honoured exactly, and the proof is the same shape as Opus': the
  // container's stated delay must be a number the format could have produced,
  // and the head trim is derived from it rather than guessed.
  if (!entry.audio || !entry.codecPrivate ||
      !selectedTrackFeaturesSupported(entry, true) ||
      entry.seekPreRollNanoseconds != 0) {
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
  // See aacLcHeaderAdmitted above: this exact rule is also asked, ahead of the
  // cluster scan, by prepareMatroska's cheap pre-admission pass.
  if (!aacLcHeaderAdmitted(admission, entry, limits)) {
    return false;
  }
  const auto cookie = buildAacLcEsDescriptorCookie(*admission.configuration);
  if (!cookie) {
    return false;
  }
  const std::uint32_t sampleRate = admission.configuration->sampleRate;

  // AAC's encoder priming is exactly one access unit and nothing else. FFmpeg
  // states 21,333,333 ns on a 48 kHz track, which is 1024 frames; a track that
  // was copied rather than encoded states nothing at all. Any OTHER value
  // describes priming this path cannot prove, so it falls back rather than
  // being trimmed on a derivation -- the same discipline as the Opus
  // CodecDelay == preSkip identity.
  //
  // AudioToolbox's AAC decoder swallows NOTHING of its own (measured: a
  // 283-packet track decodes to exactly 283 * 1024 frames), so the head trim
  // the pipeline owes is the whole CodecDelay. At that offset the decode
  // matches ffmpeg's own container-trimmed decode over every frame.
  if (entry.codecDelayNanoseconds >
      static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
    return false;
  }
  const auto codecDelayFrames = matroskaFramesFromNanoseconds(
      static_cast<std::int64_t>(entry.codecDelayNanoseconds), sampleRate,
      kAacLcSamplesPerAccessUnit);
  if (!codecDelayFrames ||
      (*codecDelayFrames != 0U &&
       *codecDelayFrames != kAacLcSamplesPerAccessUnit)) {
    return false;
  }

  ParseOptions options = parserOptions(limits, constraints);
  OpusPacketGridProbe probe;
  probe.samplesPerAccessUnit = kAacLcSamplesPerAccessUnit;
  if (!probeAudioTailBlock(reader, clusters, options, entry.number,
                           cancellation, &probe)) {
    return false;
  }
  ExactAudioDuration exact;
  if (!exactAudioDurationFromTail(probe, sampleRate,
                                  kAacLcSamplesPerAccessUnit,
                                  timestampScaleNanoseconds, *codecDelayFrames,
                                  0U, kMaximumOpusGridTickResidual, &exact)) {
    return false;
  }
  MediaTime origin;
  if (!exactPresentationOrigin(*codecDelayFrames, sampleRate, &origin)) {
    return false;
  }

  AudioDescriptorFields fields;
  fields.codec = MediaCodec::Aac;
  fields.formatTag = kAacFormatTag;
  fields.sampleRate = sampleRate;
  fields.channelCount = admission.configuration->channelCount;
  fields.samplesPerAccessUnit = kAacLcSamplesPerAccessUnit;
  fields.codecDelayFrames = *codecDelayFrames;
  fields.duration = exact.duration;
  fields.origin = origin;
  fields.magicCookie = cookie->view();
  fields.tailBlockKnown = true;
  fields.tailBlockOffset = probe.tailBlockOffset;
  fields.tailDiscardPaddingNanoseconds = probe.tailDiscardPaddingNanoseconds;
  fillAudioDescriptor(entry, *id, fields, result, runtime);
  return true;
}


[[nodiscard]] std::vector<TrackConstraint>
cursorConstraints(const AssetState& state, MediaTrackId selected) {
  std::vector<TrackConstraint> result = state.constraints;
  for (TrackConstraint& constraint : result) {
    constraint.selected = constraint.number == selected;
    if (constraint.selected) {
      constraint.maximumBlockBytes =
          (state.video && selected == state.video->id)
              ? state.limits.maximumVideoSampleBytes
              : state.limits.maximumAudioSampleBytes;
    }
  }
  return result;
}

// DiscardPadding is honoured for exactly one Block per file: the last Block of
// an Opus track, whose offset and value were both proven at preparation. It is
// a PCM tail trim, so admitting it anywhere else -- or admitting a value the
// stated duration was not derived from -- would let decoded audio outrun the
// timeline the clock counts.
[[nodiscard]] bool blockFeaturesSupported(
    const CapturedBlockVisitor& block,
    const std::optional<TrackRuntime>& audio) noexcept {
  if (block.group.codecState || block.group.blockAdditionsPresent) {
    return false;
  }
  if (!block.group.discardPaddingNanoseconds) {
    return true;
  }
  return audio && audio->audioTailBlockKnown &&
         block.header.trackNumber == audio->entry.number &&
         block.header.containerEncoded.offset == audio->audioTailBlockOffset &&
         *block.group.discardPaddingNanoseconds ==
             audio->audioTailDiscardPaddingNanoseconds;
}

// Element id of Cluster>Timestamp (Matroska calls it ClusterTimestamp; older
// specs called it Timecode). One byte, because the id's VINT marker makes 0xE7
// its whole encoding.
constexpr std::uint32_t kClusterTimestampElementId{0xE7};

// How far into a Cluster the harvest below will look for that Timestamp before
// it gives up and asks for the historical whole-Cluster scan. Matroska requires
// the Timestamp to be present and every muxer in the corpus writes it as the
// first or second child (measured: mean 2.00 children on the 2.2 GB HEVC file
// that motivated this, 2157/2157 recovered), so 16 is generous by an order of
// magnitude while still keeping the pass O(1) per Cluster.
constexpr std::size_t kMaximumClusterHeadElements{16};

// Fills in each known-size Cluster's Timestamp WITHOUT the whole-file walk.
//
// ParseOptions::scanClusterMetadata exists to collect exactly one fact per
// Cluster -- its Timestamp -- and it pays for that fact by abandoning the
// parser's O(1) skip-by-declared-size and reading an element header for EVERY
// SimpleBlock and BlockGroup in EVERY Cluster in the file. Each of those
// headers is four unbuffered pread(2) calls, because a header is a trust
// boundary. Measured on the 2.2 GB HEVC/5.1-AAC file this was written for:
// 2,152,353 reads scattered across the whole 2.2 GB, about 1.1 s warm and much
// worse cold, to recover 2,157 integers that sit in the first 100 bytes of
// their Clusters.
//
// So the authoritative pass now runs with scanClusterMetadata OFF -- every
// known-size Cluster skipped in O(1), exactly as the cheap pre-admission probe
// already did -- and this walks the bounded HEAD of each Cluster afterwards to
// read the one element that was skipped. 19,413 reads instead of 2,152,353,
// for byte-identical values.
//
// It reads through readElementHeader(), the parser's own trust boundary, so no
// structure is trusted that the parser would not have trusted; the difference
// is only how many elements are visited. What the full walk additionally did
// -- charge every in-Cluster child against the element budget and prove its
// size at OPEN time -- is deliberately given up: those same headers are parsed
// and proven by the same parser when a cursor actually reads them, and nothing
// downstream trusts a Block header it has not itself parsed.
//
// Returns false if any Cluster's Timestamp is not in its bounded head. The
// caller then falls back to the historical scan, so a file this cannot serve
// is prepared exactly as it was before rather than refused.
[[nodiscard]] bool harvestClusterTimestamps(
    SeekableByteReader& reader, std::vector<Cluster>& clusters,
    CancellationToken cancellation) noexcept {
  for (Cluster& cluster : clusters) {
    // An unknown-size Cluster is walked by the parser whatever this option
    // says (it has to find the terminator), so it already carries its
    // Timestamp and must not be re-read.
    if (cluster.timestamp) {
      continue;
    }
    if (cancellation.cancelled()) {
      return false;
    }
    const std::uint64_t end = cluster.data.offset + cluster.data.size;
    if (end < cluster.data.offset) {
      return false;
    }
    std::uint64_t position = cluster.data.offset;
    bool found = false;
    for (std::size_t step = 0;
         step < kMaximumClusterHeadElements && position < end; ++step) {
      const ElementHeaderOutcome child =
          readElementHeader(reader, position, end, cancellation);
      if (!child.outcome.ok() || !child.header) {
        return false;
      }
      if (child.header->id == kClusterTimestampElementId) {
        if (child.header->data.size > 8) {
          return false;
        }
        const auto width = static_cast<std::size_t>(child.header->data.size);
        std::byte encoded[8]{};
        if (width != 0 &&
            !reader.readAt(child.header->data.offset,
                           std::span<std::byte>(encoded, width))) {
          return false;
        }
        // EBML unsigned integer: big endian, zero width means zero.
        std::uint64_t value = 0;
        for (std::size_t index = 0; index < width; ++index) {
          value = (value << 8) | std::to_integer<std::uint64_t>(encoded[index]);
        }
        cluster.timestamp = value;
        found = true;
        break;
      }
      const std::uint64_t next =
          child.header->data.offset + child.header->data.size;
      if (next <= position) {
        return false;
      }
      position = next;
    }
    if (!found) {
      return false;
    }
  }
  return true;
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
  ParseOptions options = parserOptions(state.limits, constraints);
  CapturedBlockVisitor visitor;
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
      visitor.reset();
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

// ---------------------------------------------------------------------------
// Random access index coverage, and the scanned index that repairs it.
// ---------------------------------------------------------------------------

// Three decimals: the resolution a 1 ms timestamp scale can actually state,
// and never the exponent form, because these numbers end up in a verdict a
// person reads.
[[nodiscard]] std::string formatSeconds(double value) {
  std::array<char, 32> buffer{};
  const int written =
      std::snprintf(buffer.data(), buffer.size(), "%.3f", value);
  if (written <= 0 || static_cast<std::size_t>(written) >= buffer.size()) {
    return std::string("?");
  }
  return std::string(buffer.data(), static_cast<std::size_t>(written));
}

// The widest span a seek can be asked to decode through, given an index:
// every gap between consecutive entries, PLUS the tail from the last entry to
// the end of the medium. Returns false when some span is wider than the seek
// preroll this route promises to decode and discard, and reports the widest
// span it measured either way (for the verdict text only -- the decision is
// exact 128-bit integer arithmetic, the report is a double).
//
// The tail term is not decoration. The gap loop it joins starts at entry 1, so
// a ONE-entry index -- what a live mux writes, and what the GStreamer
// screencast carries -- used to satisfy a bound that never examined it, and
// every seek on such a file seeded at that single entry however far away the
// target was. A one-entry index is now measured against the duration like any
// other.
[[nodiscard]] bool indexSeedsWithinPreroll(
    const AssetState& state, double* widestSpanSeconds) noexcept {
  *widestSpanSeconds = 0.0;
  if (state.cues.empty()) {
    return false;
  }
  // The preroll bound is a policy ceiling expressed in seconds, so it enters as
  // a whole nanosecond count once; every per-entry term below is exact 128-bit
  // integer arithmetic. Cross-multiplying through `long double` would be plain
  // binary64 on arm64, where a timescale near the int32 ceiling pushes both
  // sides past a 53-bit mantissa and the bound gets decided by rounding.
  constexpr __int128 kNanosecondsPerSecond{1'000'000'000};
  const auto prerollNanoseconds = static_cast<__int128>(
      state.limits.maximumVideoSeekPrerollSeconds * 1.0e9);
  bool within = true;
  const auto measure = [&](const MediaTime& earlier, const MediaTime& later) {
    // (later - earlier) > preroll, cross-multiplied by both timescales and by
    // 1e9 so the seconds bound stays an integer nanosecond count. Magnitudes:
    // |value| < 2^63 and timescale < 2^31 bound the left side by 2^124 and the
    // right by 2^96, both inside __int128.
    const __int128 span =
        (static_cast<__int128>(later.value) * earlier.timescale -
         static_cast<__int128>(earlier.value) * later.timescale) *
        kNanosecondsPerSecond;
    const __int128 bound = prerollNanoseconds *
                           static_cast<__int128>(later.timescale) *
                           static_cast<__int128>(earlier.timescale);
    const double seconds =
        static_cast<double>(later.value) / static_cast<double>(later.timescale) -
        static_cast<double>(earlier.value) / static_cast<double>(earlier.timescale);
    if (seconds > *widestSpanSeconds) {
      *widestSpanSeconds = seconds;
    }
    if (span > bound) {
      within = false;
    }
  };
  // The conversion of entry n-1 is carried forward instead of recomputed. Each
  // conversion is a gcd reduction, and doing both ends of every gap did exactly
  // twice the work this check needs, at open time, O(entries).
  auto previous = timeFromSignedTick(
      static_cast<std::int64_t>(state.cues.front().timestampTick),
      state.timestampScaleNanoseconds);
  if (!previous) {
    return false;
  }
  for (std::size_t index = 1; index < state.cues.size(); ++index) {
    const auto current = timeFromSignedTick(
        static_cast<std::int64_t>(state.cues[index].timestampTick),
        state.timestampScaleNanoseconds);
    if (!current) {
      return false;
    }
    measure(*previous, *current);
    previous = current;
  }
  if (state.descriptor) {
    measure(*previous, state.descriptor->duration);
  }
  return within;
}

struct ScannedCueIndexOutcome {
  MatroskaDemuxStatus status{MatroskaDemuxStatus::Ready};
  MatroskaDemuxError error{MatroskaDemuxError::None};
  const char* message{""};
};

// Rebuilds the selected-video index from the container's own skeleton when the
// file's Cues cannot serve as one.
//
// A Cues element is OPTIONAL, and so is the CueRelativePosition inside it. Live
// muxes exercise both freedoms: GStreamer's matroskamux writes CuePoints with
// no CueRelativePosition, an interrupted capture writes none at all, and OBS
// writes them for one track. In every such case the random access points still
// exist and are still discoverable, because a Cluster states its timestamp and
// every Block header states its track, its offset from that timestamp, and
// whether it is a keyframe. Walking those headers rebuilds exactly the index
// Cues would have carried -- from the bytes rather than from a muxer's promise.
//
// This reads ELEMENT HEADERS only. Frame payloads are described by FrameRange
// offsets the visitor never dereferences, so the pass touches the container's
// skeleton and not its 380 MB of VP8. Blocks of unselected tracks are skipped
// by offset arithmetic without a read at all.
//
// Bounded three ways, all derived in matroska_demuxer.hpp: entries are capped
// at kMaximumMatroskaCues (the same 1 MiB budget a file-supplied index gets),
// decimated to one per kMatroskaScannedCueSpacingNanoseconds so that cap spans
// 18.2 hours, and each entry's Block offset is relative to a Cluster already
// capped inside 32 bits.
[[nodiscard]] ScannedCueIndexOutcome buildScannedVideoCueIndex(
    const AssetState& state, MediaTrackId track,
    std::vector<MatroskaCueIndexEntry>* out, CancellationToken cancellation) {
  out->clear();
  // Decimation in the container's own tick units. A timescale coarser than the
  // spacing floors to zero ticks, which would decimate nothing; one tick is
  // then the finest spacing that still keeps the index strictly increasing.
  const std::uint64_t spacingTicks = std::max<std::uint64_t>(
      1U, kMatroskaScannedCueSpacingNanoseconds /
              std::max<std::uint64_t>(1U, state.timestampScaleNanoseconds));
  std::vector<TrackConstraint> constraints = cursorConstraints(state, track);
  ParseOptions options = parserOptions(state.limits, constraints);
  CapturedBlockVisitor visitor;
  bool seeded = false;
  std::uint64_t lastTick = 0;
  for (std::size_t clusterIndex = 0; clusterIndex < state.clusters.size();
       ++clusterIndex) {
    if (cancellation.cancelled()) {
      return {MatroskaDemuxStatus::Cancelled, MatroskaDemuxError::Cancelled,
              "the Cluster scan was cancelled"};
    }
    const ByteRange data = state.clusters[clusterIndex].dataRange();
    auto cursor = beginClusterChildCursor(*state.reader, data, options);
    if (!cursor) {
      return {MatroskaDemuxStatus::Failed, MatroskaDemuxError::InvalidContainer,
              "a Cluster data range could not be walked"};
    }
    while (!cursor->done()) {
      visitor.reset();
      const ParseOutcome outcome = parseClusterChildAt(
          *state.reader, *cursor, visitor, options, cancellation);
      if (!outcome.ok()) {
        const MatroskaDemuxError error = parseError(outcome);
        return {error == MatroskaDemuxError::Cancelled
                    ? MatroskaDemuxStatus::Cancelled
                    : MatroskaDemuxStatus::Failed,
                error, "a Cluster Block header could not be parsed"};
      }
      if (!visitor.emitted || visitor.header.trackNumber != track) {
        continue;
      }
      // The same codec-agnostic random access rule the cursor and the Cue
      // commit proof already apply, so a scanned entry is admissible exactly
      // where a Cue-derived one is.
      if (!(visitor.header.simpleBlock ? visitor.header.keyFrame
                                       : visitor.referenceCount == 0)) {
        continue;
      }
      const auto tick = signedBlockTick(state.clusters[clusterIndex].timestampTick,
                                        visitor.header.relativeTimestamp);
      if (!tick || *tick < 0) {
        continue;
      }
      const auto ticks = static_cast<std::uint64_t>(*tick);
      if (seeded && ticks < lastTick + spacingTicks) {
        continue;
      }
      const std::uint64_t offset = visitor.header.containerEncoded.offset;
      if (offset < data.offset ||
          offset - data.offset > std::numeric_limits<std::uint32_t>::max()) {
        continue;
      }
      if (out->size() >= kMaximumMatroskaCues) {
        return {MatroskaDemuxStatus::Unsupported, MatroskaDemuxError::IndexLimit,
                "the scanned random access index is over its bounded budget"};
      }
      out->push_back({ticks, static_cast<std::uint32_t>(clusterIndex),
                      static_cast<std::uint32_t>(offset - data.offset)});
      lastTick = ticks;
      seeded = true;
    }
  }
  return {};
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
  // One workspace per cursor, so the 4 KiB frame array is zero-filled once per
  // generation instead of once per sample. Dropping the member initialiser
  // instead measured neutral and would have put indeterminate values in a
  // public record; this gets the same stores back without that trade.
  CapturedBlockVisitor visitor;
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

    CapturedBlockVisitor& visitor = impl_->visitor;
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
        visitor.reset();
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
        if (!blockFeaturesSupported(visitor, state.audio)) {
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
          } else if (state.video &&
                     state.video->entry.defaultDurationNanoseconds) {
            const auto duration = timeFromNanosecondsUnsigned(
                *state.video->entry.defaultDurationNanoseconds);
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
                                         "invalid audio Block"};
          }
          const std::uint32_t samplesPerAccessUnit =
              state.audio->audioSamplesPerAccessUnit;
          const auto projection = nearestAacAccessUnitForMatroskaTick(
              *tick, MediaTime{0, 1}, state.audio->audioSampleRate,
              state.timestampScaleNanoseconds, samplesPerAccessUnit);
          if (!aacProjectionOnGrid(projection,
                                   state.audio->audioTickResidualTolerance)) {
            return MatroskaCursorFailure{MatroskaDemuxError::InvalidTimeline,
                                         "audio Block is off the exact AU grid"};
          }
          // Opus packets carry their own duration in the TOC byte. A track
          // that changes packet duration mid-stream would silently desync the
          // ordinal grid the timestamps are rebuilt from, so every emitted
          // packet is re-proved against the duration admission recorded.
          if (state.audio->codec == MediaCodec::Opus) {
            for (std::uint16_t index = 0; index < visitor.frameCount; ++index) {
              std::array<std::byte, 2> toc{};
              const ByteRange frame = visitor.frames[index].bytes;
              const auto amount = static_cast<std::size_t>(
                  std::min<std::uint64_t>(frame.size, toc.size()));
              if (amount == 0 ||
                  !state.reader->readAt(
                      frame.offset, std::span<std::byte>(toc).first(amount))) {
                return MatroskaCursorFailure{MatroskaDemuxError::Io,
                                             "Opus packet TOC is unreadable"};
              }
              const auto frames = opusPacketFrameCount(
                  std::span<const std::byte>(toc).first(amount));
              if (!frames || *frames != samplesPerAccessUnit) {
                return MatroskaCursorFailure{
                    MatroskaDemuxError::UnsupportedTrack,
                    "Opus packet duration is not constant"};
              }
            }
          }
          // AC-3, E-AC-3 and MP3 restate every stream parameter in each frame
          // header rather than in a CodecPrivate, so the same argument applies
          // with more force than it does for Opus: nothing but the header
          // would reveal a mid-stream change of sample rate or channel mode,
          // and either one silently desyncs the ordinal grid the timestamps
          // are rebuilt from. Each emitted frame is re-proved against the
          // admission.
          if (state.audio->codec == MediaCodec::Ac3 ||
              state.audio->codec == MediaCodec::Eac3 ||
              state.audio->codec == MediaCodec::Mp3) {
            const bool mpeg = state.audio->codec == MediaCodec::Mp3;
            const bool enhanced = state.audio->codec == MediaCodec::Eac3;
            Ac3Configuration ac3Configuration;
            ac3Configuration.sampleRate = state.audio->audioSampleRate;
            ac3Configuration.channelCount = static_cast<std::uint8_t>(
                state.audio->entry.audio ? state.audio->entry.audio->channels
                                         : 0U);
            ac3Configuration.samplesPerAccessUnit = samplesPerAccessUnit;
            ac3Configuration.enhanced = enhanced;
            MpegAudioConfiguration mpegConfiguration;
            mpegConfiguration.sampleRate = ac3Configuration.sampleRate;
            mpegConfiguration.channelCount = ac3Configuration.channelCount;
            mpegConfiguration.samplesPerAccessUnit = samplesPerAccessUnit;
            for (std::uint16_t index = 0; index < visitor.frameCount; ++index) {
              std::array<std::byte, kAc3MinimumSyncframeBytes> header{};
              const ByteRange frame = visitor.frames[index].bytes;
              const auto amount = static_cast<std::size_t>(
                  std::min<std::uint64_t>(frame.size, header.size()));
              if (amount == 0 ||
                  !state.reader->readAt(
                      frame.offset,
                      std::span<std::byte>(header).first(amount))) {
                return MatroskaCursorFailure{MatroskaDemuxError::Io,
                                             "audio frame header is unreadable"};
              }
              const std::span<const std::byte> bytes =
                  std::span<const std::byte>(header).first(amount);
              const bool matched =
                  mpeg ? mpegAudioFrameMatches(bytes, frame.size,
                                               mpegConfiguration)
                       : ac3SyncframeMatches(bytes, frame.size,
                                             ac3Configuration, enhanced);
              if (!matched) {
                return MatroskaCursorFailure{
                    MatroskaDemuxError::UnsupportedTrack,
                    "audio frame header does not match the admitted stream"};
              }
            }
          }
          std::uint16_t firstFrame = 0;
          if (visitor.header.containerEncoded.offset == impl_->startBlockOffset) {
            firstFrame = impl_->startFrameIndex;
          }
          if (firstFrame >= visitor.frameCount ||
              projection->accessUnitOrdinal + firstFrame !=
                  impl_->expectedAudioOrdinal) {
            return MatroskaCursorFailure{MatroskaDemuxError::InvalidTimeline,
                                         "audio ordinal discontinuity"};
          }
          std::size_t bytes = 0;
          for (std::uint16_t index = firstFrame; index < visitor.frameCount;
               ++index) {
            const std::uint64_t frameBytes = visitor.frames[index].bytes.size;
            if (frameBytes > state.limits.maximumAudioSampleBytes ||
                bytes > state.limits.maximumAudioSampleBytes - frameBytes) {
              return MatroskaCursorFailure{MatroskaDemuxError::SampleLimit,
                                           "audio sample exceeds byte cap"};
            }
            sample.frames[sample.frameCount++] = visitor.frames[index];
            bytes += static_cast<std::size_t>(frameBytes);
          }
          sample.aggregateBytes = bytes;
          const auto presentation = aacAccessUnitGridTime(
              {state.audio->audioPresentationOrigin,
               impl_->expectedAudioOrdinal, state.audio->audioSampleRate,
               samplesPerAccessUnit});
          const auto duration = timeFromNanosecondsUnsigned(
              (static_cast<std::uint64_t>(sample.frameCount) *
               samplesPerAccessUnit * UINT64_C(1'000'000'000)) /
              state.audio->audioSampleRate);
          if (!presentation) {
            return MatroskaCursorFailure{MatroskaDemuxError::InvalidTimeline,
                                         "audio presentation overflow"};
          }
          sample.presentationTime = *presentation;
          const std::uint64_t frameCount =
              static_cast<std::uint64_t>(sample.frameCount) *
              samplesPerAccessUnit;
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
                                         "audio duration overflow"};
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
    // The Cue index is strictly increasing in tick (enforced at preparation)
    // and timeFromSignedTick is monotone in tick, so "this Cue starts at or
    // before the target" is a monotone predicate and the last index satisfying
    // it is a binary search rather than a scan. The scan cost one gcd
    // reduction plus one exact rational compare per Cue *passed*, so its price
    // was set by where in the file the user seeks: measured 1.8 us landing on
    // the first Cue but 545 us landing on the last Cue of a 65,536-Cue index
    // (307x), paid on every seek and every open that carries an initial
    // position. Binary search flattens that to 1.8-2.0 us everywhere.
    //
    // Evaluating only O(log n) Cues loses no rejection: preparation's Cue-gap
    // check already converts every Cue tick through timeFromSignedTick and
    // fails closed on any that is not representable, so a prepared asset has
    // no unconvertible Cue left for this loop to find.
    MatroskaGenerationPlan plan;
    plan.requestedTarget = target;
    plan.mode = mode;
    // Seed cluster for the Block scans. With a video lane it is the Cue that
    // covers the target and doubles as the generation's decode start; without
    // one it is simply the last Cluster that starts at or before the target,
    // which the Cluster directory answers by the same binary search (Cluster
    // ticks are proven non-decreasing at preparation).
    std::size_t seedCluster = 0;
    if (state.video) {
      std::size_t cueIndex = 0;
      {
        std::size_t low = 0;
        std::size_t high = state.cues.size();
        while (low < high) {
          const std::size_t middle = low + (high - low) / 2U;
          const auto cueTime = timeFromSignedTick(
              static_cast<std::int64_t>(state.cues[middle].timestampTick),
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
            high = middle;
          } else {
            cueIndex = middle;
            low = middle + 1U;
          }
        }
      }
      const MatroskaCueIndexEntry& cue = state.cues[cueIndex];
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

      // The seek COMMIT PROOF for a video generation: the Cue must name a real
      // random access point, or the first submitted sample would reference
      // frames this generation never decoded.
      const ScanResult videoProof = scanTrack(
          state, state.video->id, cue.clusterIndex, 1,
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
      seedCluster = cue.clusterIndex;
    } else {
      if (!state.audio) {
        outcome.error = MatroskaDemuxError::TrackSelection;
        outcome.message = "generation has neither a video nor an audio lane";
        return outcome;
      }
      std::size_t low = 0;
      std::size_t high = state.clusters.size();
      while (low < high) {
        const std::size_t middle = low + (high - low) / 2U;
        const auto clusterTime = timeFromSignedTick(
            static_cast<std::int64_t>(state.clusters[middle].timestampTick),
            state.timestampScaleNanoseconds);
        if (!clusterTime) {
          outcome.error = MatroskaDemuxError::InvalidTimeline;
          return outcome;
        }
        const auto order = compareMediaTime(*clusterTime, target);
        if (!order) {
          outcome.error = MatroskaDemuxError::InvalidTimeline;
          return outcome;
        }
        if (*order == MediaTimeOrder::Greater) {
          high = middle;
        } else {
          seedCluster = middle;
          low = middle + 1U;
        }
      }
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
      const std::uint32_t samplesPerAccessUnit =
          state.audio->audioSamplesPerAccessUnit;
      const MediaTime presentationOrigin = state.audio->audioPresentationOrigin;
      const std::int64_t tickTolerance =
          state.audio->audioTickResidualTolerance;
      // Ordinal k spans media frames [k*S - offset, (k+1)*S - offset), so the
      // ordinal containing a media frame is (frame + offset) / S. The offset is
      // the Opus pre-skip and zero for AAC, which keeps the AAC expression
      // arithmetically identical to the one this replaced.
      const std::uint64_t desiredOrdinal =
          (static_cast<std::uint64_t>(*pcmFrame) +
           state.audio->audioGridOffsetFrames) /
          samplesPerAccessUnit;
      // Stage whole access units ahead of the first audible one. A decoder
      // reaches full precision only after a couple of frames, so a consumer
      // demands proof that the generation carries that preroll before it will
      // publish PCM. desiredOrdinal alone is the AU *containing* the audible
      // frame, which is never early enough to prove anything, so every
      // non-origin seek would be refused downstream. Opus states the warm-up
      // it needs as SeekPreRoll and gets that many access units instead.
      const std::uint64_t priming = state.audio->audioPrimingAccessUnits;
      const std::uint64_t startOrdinal =
          desiredOrdinal >= priming ? desiredOrdinal - priming : 0;
      // One Cluster of backoff covers the priming access units, which are tens
      // of milliseconds against Clusters that are whole seconds long. An
      // audio-only generation backs off two, because its seed is the Cluster
      // containing the target rather than a Cue at or before it and it has no
      // video RAP to anchor the lower bound.
      const std::size_t backoff = state.video ? 1U : 2U;
      const std::size_t searchStart =
          seedCluster > backoff ? seedCluster - backoff : 0;
      const ScanResult audioBlock = scanTrack(
          state, state.audio->id, static_cast<std::uint32_t>(searchStart),
          kMaximumMatroskaSeekClusters,
          [&state, startOrdinal, samplesPerAccessUnit, tickTolerance](
              std::uint32_t clusterIndex, const CapturedBlockVisitor& block) {
            const auto tick = signedBlockTick(
                state.clusters[clusterIndex].timestampTick,
                block.header.relativeTimestamp);
            if (!tick) {
              return false;
            }
            const auto projection = nearestAacAccessUnitForMatroskaTick(
                *tick, MediaTime{0, 1}, state.audio->audioSampleRate,
                state.timestampScaleNanoseconds, samplesPerAccessUnit);
            return aacProjectionOnGrid(projection, tickTolerance) &&
                   projection->accessUnitOrdinal <= startOrdinal &&
                   startOrdinal < projection->accessUnitOrdinal +
                                      block.frameCount;
          },
          cancellation);
      if (audioBlock.error != MatroskaDemuxError::None || !audioBlock.block) {
        outcome.error = audioBlock.error == MatroskaDemuxError::None
                            ? MatroskaDemuxError::InvalidTimeline
                            : audioBlock.error;
        outcome.message = "audio access unit for seek target was not found";
        return outcome;
      }
      const auto audioTick = signedBlockTick(
          state.clusters[audioBlock.clusterIndex].timestampTick,
          audioBlock.block->header.relativeTimestamp);
      const auto projection = nearestAacAccessUnitForMatroskaTick(
          *audioTick, MediaTime{0, 1}, state.audio->audioSampleRate,
          state.timestampScaleNanoseconds, samplesPerAccessUnit);
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
          {presentationOrigin, startOrdinal, state.audio->audioSampleRate,
           samplesPerAccessUnit});
      if (!decode) {
        outcome.error = MatroskaDemuxError::InvalidTimeline;
        return outcome;
      }
      plan.audioWindow = {*decode, *presentationStart, startOrdinal == 0};
      if (!state.video) {
        // With no video lane the generation's decode start IS the audio
        // window's, floored at the stream origin. Opus states a negative
        // presentation origin (the pre-skip), and the downstream timeline
        // contract requires 0 <= actualDecodeStart <= target; the audio window
        // keeps the exact signed value, which is where the pre-skip is
        // actually honoured.
        constexpr MediaTime kOrigin{0, 1};
        const auto againstOrigin = compareMediaTime(*decode, kOrigin);
        if (!againstOrigin) {
          outcome.error = MatroskaDemuxError::InvalidTimeline;
          return outcome;
        }
        plan.actualDecodeStart =
            *againstOrigin == MediaTimeOrder::Less ? kOrigin : *decode;
      }
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
  if (!impl_->state->video) {
    return nullptr;
  }
  try {
    auto cursor = std::make_unique<MatroskaCursor::Impl>();
    cursor->state = impl_->state;
    cursor->track = impl_->state->video->id;
    cursor->video = true;
    cursor->clusterIndex = plan.videoClusterIndex;
    cursor->startBlockOffset = plan.videoBlockOffset;
    cursor->constraints = cursorConstraints(*impl_->state, cursor->track);
    cursor->options = parserOptions(impl_->state->limits, cursor->constraints);
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
    cursor->options = parserOptions(impl_->state->limits, cursor->constraints);
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
      if (!state.reader->readAt(
              sourceOffset,
              destination.subspan(destinationOffset, amount))) {
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
  // File identity brackets the whole copy rather than each 64 KiB chunk. The
  // guarantee is unchanged -- the destination is only ever reported complete
  // when the retained identity held from before the first read to after the
  // last one, and a mid-copy substitution is still caught here before this
  // function returns true -- but the syscall count is not. Checking twice per
  // chunk made a local-file copy 3 fstat + 1 pread per 64 KiB: measured 1801 ns
  // to move 1 KiB (0.53 GiB/s against 27 GiB/s from memory) and 49 syscalls to
  // move 1 MiB. Per-chunk checking only made a doomed copy abandon sooner; it
  // never made a returned buffer more trustworthy.
  if (!state.unchanged()) {
    if (error != nullptr) {
      *error = MatroskaDemuxError::FileChanged;
    }
    return false;
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

namespace {

// The track-selection envelope verdict, decided entirely from the Tracks
// header. std::nullopt means "nothing here refuses the file"; it never admits
// one on its own.
[[nodiscard]] std::optional<MatroskaPrepareOutcome> trackSelectionRefusal(
    std::span<const TrackEntry> tracks, const TrackEntry* video,
    const TrackEntry* audio, const MediaSourceOpenOptions& requested) {
  // A file that carries audio the native path cannot decode must fall back
  // as a WHOLE FILE, not prepare video-only. Preparing video-only here would
  // play a VP9+Opus WebM natively and completely silently, which is worse
  // than the mpv fallback in every way; mpv plays the same file with sound.
  // A file with no audio track at all is a different thing entirely and
  // stays admitted video-only, which is the correct silent-video path.
  const bool audioTrackPresent =
      std::any_of(tracks.begin(), tracks.end(), [](const TrackEntry& track) {
        return track.enabled && track.type == 2;
      });
  // The mirror of the rule above, for the audio-only route. A file that
  // carries video the native path cannot decode must still fall back as a
  // WHOLE FILE rather than prepare audio-only: playing a VP9+Opus WebM as a
  // black window with sound is worse than the mpv fallback, which shows the
  // picture. A file with no video track at all is a different thing entirely
  // and is admitted audio-only, which is the correct music-file path.
  const bool videoTrackPresent =
      std::any_of(tracks.begin(), tracks.end(), [](const TrackEntry& track) {
        return track.enabled && track.type == 1;
      });
  if (!((videoTrackPresent && video == nullptr) ||
        (audioTrackPresent && audio == nullptr) ||
        (video == nullptr && audio == nullptr) ||
        (requested.selection.requireVideo && video == nullptr) ||
        (requested.selection.requireAudio && audio == nullptr) ||
        (requested.selection.preferredVideo && video == nullptr) ||
        (requested.selection.preferredAudio && audio == nullptr) ||
        requested.selection.preferredSubtitle)) {
    return std::nullopt;
  }
  MatroskaPrepareOutcome result;
  // No admissible track for this request is an envelope verdict, not an
  // error: an unsupported-codec or subtitle-only Matroska must reach the
  // caller as Unsupported so it falls back cleanly, rather than as Failed,
  // which the session reports as a hard protocol fault on a blocking
  // surface.
  result.status = MatroskaDemuxStatus::Unsupported;
  // Name the dimension refusal specifically. Everything else that lands
  // here is genuinely "the track you asked for is not available", but an
  // over-ceiling video track IS available and readable -- it is the v1
  // envelope that declines it -- and saying so with both numbers is the
  // difference between a one-line diagnosis and a rebuild cycle. The scan
  // is over the raw TrackEntry list rather than over anything the admission
  // path produced, because the admission path is exactly what dropped it.
  const TrackEntry* overCeiling = nullptr;
  if (videoTrackPresent && video == nullptr) {
    for (const TrackEntry& track : tracks) {
      if (!track.enabled || track.type != 1 || !track.video ||
          !track.video->pixelWidth || !track.video->pixelHeight) {
        continue;
      }
      if (!codedDimensionsWithinV1Ceiling(*track.video->pixelWidth,
                                          *track.video->pixelHeight)) {
        overCeiling = &track;
        break;
      }
    }
  }
  if (overCeiling != nullptr) {
    result.error = MatroskaDemuxError::CodedDimensionLimit;
    result.message = codedDimensionRefusalMessage(
        *overCeiling->video->pixelWidth, *overCeiling->video->pixelHeight);
  } else {
    result.error = MatroskaDemuxError::TrackSelection;
    result.message = "requested Matroska tracks are unavailable";
  }
  return result;
}

// Cheap pre-admission verdict, asked BEFORE the cluster scan.
//
// Preparation's authoritative parse sets ParseOptions::scanClusterMetadata so
// the parser descends into every Block of every Cluster, purely to collect the
// ClusterTimestamp that the cluster index and the cue index -- both built at
// the very END of preparation -- need. Every header read at that trust
// boundary is deliberately unbuffered, so the walk costs four pread(2) calls
// per element. Measured on the file that produced this defect (a 1.9 GiB
// HEVC + 5.1-AAC MKV): 3,030,956 readAt calls fetching 3.9 MB scattered across
// the whole file, 1.18 s warm on an M3 Max -- and cold, page faults spread
// over all 1.9 GiB. The window sits dead for that entire time.
//
// Every byte of that is wasted when the verdict is "this file cannot play
// natively", because the facts that produce that verdict are stated in the
// Tracks header at the HEAD of the file. So preparation now runs a cheap pass
// first, with scanClusterMetadata off, which skips each Cluster in O(1) by its
// declared size, and asks exactly the header-only questions here.
//
// This gate can only ever REFUSE. Anything it does not refuse falls through to
// the authoritative pass completely unchanged, so a file it cannot judge --
// including one where the cheap parse itself failed -- is judged exactly as it
// was before. Both refusals it can reach are byte-identical to the ones the
// authoritative pass would have produced from the same header, because both
// call the same predicate (trackSelectionRefusal, aacLcHeaderAdmitted).
[[nodiscard]] std::optional<MatroskaPrepareOutcome> matroskaHeaderRefusal(
    SeekableByteReader& reader, const std::vector<TrackEntry>& tracks,
    EbmlDocumentType documentType, const MediaSourceOpenOptions& requested,
    const MediaSourceLimits& limits, CancellationToken cancellation) {
  // No Tracks element was reached, so there is nothing to judge. This is the
  // late-Tracks mux (Tracks written after the Clusters): the probe stops at
  // the first Cluster and legitimately sees no tracks, and refusing on that
  // would deny a file the authoritative pass admits.
  if (tracks.empty()) {
    return std::nullopt;
  }
  const TrackEntry* video =
      chooseTrack(tracks, 1, requested.selection.preferredVideo, documentType);
  const TrackEntry* audio =
      chooseTrack(tracks, 2, requested.selection.preferredAudio, documentType);
  if (auto refusal =
          trackSelectionRefusal(tracks, video, audio, requested)) {
    return refusal;
  }
  // The multichannel refusal that motivated this pass. Only AAC-LC is judged
  // here: it is the one codec whose whole admissible-or-not answer is in
  // CodecPrivate, and the only one whose refusal therefore needs no Cluster.
  // AC-3, MP3, FLAC, Opus and Vorbis all probe a Block, so they keep waiting
  // for the authoritative pass rather than being second-guessed here.
  if (audio == nullptr || inlineString(audio->codecId) != "A_AAC" ||
      !audio->audio || !audio->codecPrivate) {
    return std::nullopt;
  }
  std::vector<std::byte> configuration;
  if (!readRange(reader, *audio->codecPrivate, &configuration, cancellation)) {
    return std::nullopt;
  }
  if (aacLcHeaderAdmitted(parseAacLcAudioSpecificConfig(configuration), *audio,
                          limits)) {
    return std::nullopt;
  }
  MatroskaPrepareOutcome result;
  result.status = MatroskaDemuxStatus::Unsupported;
  result.error = MatroskaDemuxError::CodecConfiguration;
  result.message = "selected AAC-LC or Opus track was not admitted";
  return result;
}

}  // namespace

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
    options.visitClusterBlocks = false;

    // Cheap pre-admission pass -- see matroskaHeaderRefusal. Refusing here
    // turns a multi-second dead window on a large unplayable file into a
    // near-instant fallback. It can only refuse; anything else falls through
    // to the authoritative pass below, unchanged.
    {
      options.scanClusterMetadata = false;
      CollectedDocument probe(state->limits.maximumTracks,
                              kMaximumMatroskaCues);
      probe.stopAtFirstCluster = true;
      const ParseOutcome probed =
          parseDocument(*state->reader, probe, options, cancellation);
      if (probed.ok() && !probe.allocationFailure) {
        if (auto refusal = matroskaHeaderRefusal(
                *state->reader, probe.tracks,
                probe.header ? probe.header->documentType
                             : EbmlDocumentType::Matroska,
                requested, state->limits, cancellation)) {
          return *refusal;
        }
      }
    }

    // ---- Authoritative pass: directory-driven, not scan-driven ------------
    //
    // The pre-admission probe above made a REFUSAL cheap. This makes an
    // ADMISSION cheap, which is the other half of the same defect: a file that
    // plays natively used to pay a whole-file cluster-metadata walk (measured
    // 2,152,353 of the 3,270,191 reads on the 2.2 GB file that motivated this)
    // before its first frame could be drawn.
    //
    // scanClusterMetadata stays OFF, so every known-size Cluster is skipped in
    // O(1) by its declared size and the Cluster directory -- offsets and sizes
    // -- is built from the Segment's own child chain. The single fact the scan
    // existed to collect, each Cluster's Timestamp, is then read directly out
    // of each Cluster's bounded head. See harvestClusterTimestamps.
    //
    // The historical scan remains the fallback, and is entered only when a
    // Cluster does not state its Timestamp within that bounded head. Nothing
    // downstream can tell the two apart: the values are identical, so the
    // cluster directory, the cue harvest, planGeneration, the cursors and the
    // scanned-index rebuild all see exactly what they saw before.
    options.scanClusterMetadata = false;
    ParseOutcome parsed =
        parseDocument(*state->reader, document, options, cancellation);
    if (parsed.ok() && !document.allocationFailure &&
        !harvestClusterTimestamps(*state->reader, document.clusters,
                                  cancellation)) {
      if (cancellation.cancelled()) {
        result.status = MatroskaDemuxStatus::Cancelled;
        result.error = MatroskaDemuxError::Cancelled;
        return result;
      }
      document.reset();
      options.scanClusterMetadata = true;
      parsed = parseDocument(*state->reader, document, options, cancellation);
    }
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
      result.message = "file identity changed during preparation";
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
    const EbmlDocumentType documentType =
        document.header ? document.header->documentType
                        : EbmlDocumentType::Matroska;
    const TrackEntry* video = chooseTrack(
        document.tracks, 1, requested.selection.preferredVideo, documentType);
    const TrackEntry* audio = chooseTrack(
        document.tracks, 2, requested.selection.preferredAudio, documentType);
    if (auto refusal = trackSelectionRefusal(document.tracks, video, audio,
                                             requested)) {
      return *refusal;
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
      const bool isVideo = video != nullptr && track.number == video->number;
      constraint.selected =
          isVideo || (audio != nullptr && track.number == audio->number);
      constraint.maximumBlockBytes = isVideo
                                         ? state->limits.maximumVideoSampleBytes
                                         : state->limits.maximumAudioSampleBytes;
      state->constraints.push_back(constraint);
    }
    if (video != nullptr) {
      MediaTrackDescriptor videoDescriptor;
      TrackRuntime videoRuntime;
      if (!makeVideoDescriptor(*state->reader, *video, state->limits, *duration,
                               document.clusters, state->constraints,
                               cancellation, &videoDescriptor, &videoRuntime)) {
        result.status = MatroskaDemuxStatus::Unsupported;
        // makeVideoDescriptor folds every unadmitted trait into one bool, and
        // "not admitted" is exactly the verdict that cost a rebuild cycle to
        // attribute. The coded-dimension case is separable without guessing --
        // the container states PixelWidth/PixelHeight in the track header,
        // independently of whatever the bitstream inspection concluded -- so
        // when that is the reason, say so with both numbers.
        if (video->video && video->video->pixelWidth &&
            video->video->pixelHeight &&
            !codedDimensionsWithinV1Ceiling(*video->video->pixelWidth,
                                            *video->video->pixelHeight)) {
          result.error = MatroskaDemuxError::CodedDimensionLimit;
          result.message = codedDimensionRefusalMessage(
              *video->video->pixelWidth, *video->video->pixelHeight);
        } else {
          result.error = MatroskaDemuxError::CodecConfiguration;
          result.message =
              "selected AVC/HEVC/AV1/VP9/VP8 track was not admitted";
        }
        return result;
      }
      descriptor->selectedVideo = videoDescriptor.id;
      descriptor->tracks.push_back(std::move(videoDescriptor));
      state->video = videoRuntime;
    }
    if (audio != nullptr) {
      MediaTrackDescriptor audioDescriptor;
      TrackRuntime audioRuntime;
      if (!makeAudioDescriptor(*state->reader, *audio, state->limits, *duration,
                               document.clusters, state->constraints,
                               state->timestampScaleNanoseconds,
                               cancellation, &audioDescriptor,
                               &audioRuntime)) {
        result.error = MatroskaDemuxError::CodecConfiguration;
        result.status = MatroskaDemuxStatus::Unsupported;
        result.message = "selected AAC-LC or Opus track was not admitted";
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

    // The Cue index is, and stays, selected-VIDEO-only: it exists to answer
    // "which encoded byte is the random access point covering this target",
    // and only a video lane has non-random-access samples to skip. An
    // audio-only generation needs no Cue index at all -- every audio Block is
    // its own random access point -- so it seeds its Block scan from the
    // Cluster directory instead (see planGeneration). Harvesting audio Cues
    // here would build a second index with different admission rules for no
    // benefit, and would make a Cue-less MKA (which FFmpeg does emit) refuse.
    //
    // An unusable Cues element is no longer fatal. Every refusal below became a
    // REASON TO REBUILD: buildScannedVideoCueIndex derives the same index from
    // Cluster timestamps and Block headers, which are facts about the bytes
    // rather than a muxer's optional promise, so a file whose Cues this v1
    // index cannot represent still gets a correct index. `degenerate` records
    // WHY the file's own Cues were discarded, so a verdict can still name it if
    // the rebuild fails too.
    const char* degenerate = nullptr;
    for (const CueTrackPosition& cue : document.cuePositions) {
      if (!state->video || cue.track != state->video->id) {
        continue;
      }
      // Name WHICH feature. "an unsupported feature" is a typed verdict with
      // an untyped subject: it does not distinguish a legal file this v1
      // index cannot use from a malformed one. A missing CueRelativePosition
      // is the first kind -- the element is OPTIONAL in Matroska and
      // GStreamer's matroskamux simply does not write it, so the file is
      // conforming. Everything else in this gate is a Cue shape the index
      // cannot represent. Both now route to the scan.
      if (!cue.relativePosition) {
        degenerate =
            "the selected video Cues carry no CueRelativePosition, which this "
            "index needs to locate the random access Block";
        break;
      }
      if (!cue.absoluteBlockOffset ||
          (cue.blockNumber && *cue.blockNumber != 1) ||
          cue.codecStatePosition != 0 || cue.absoluteCodecStateOffset ||
          cue.cueReferencePresent ||
          *cue.relativePosition > std::numeric_limits<std::uint32_t>::max()) {
        degenerate =
            cue.cueReferencePresent
                ? "a selected video Cue carries CueReference, which only a "
                  "non-random-access Cue needs"
                : ((cue.blockNumber && *cue.blockNumber != 1)
                       ? "a selected video Cue names a CueBlockNumber other "
                         "than 1"
                       : (cue.codecStatePosition != 0 ||
                          cue.absoluteCodecStateOffset)
                             ? "a selected video Cue carries CueCodecState"
                             : "a selected video Cue position is outside the "
                               "indexable range");
        break;
      }
      const auto cluster = findCluster(state->clusters,
                                       cue.absoluteClusterOffset);
      if (!cluster ||
          state->clusters[*cluster].dataRange().offset +
                  *cue.relativePosition !=
              *cue.absoluteBlockOffset) {
        degenerate = "a selected video Cue target does not match the Cluster "
                     "directory";
        break;
      }
      if (!state->cues.empty() &&
          cue.cueTime <= state->cues.back().timestampTick) {
        degenerate = "the selected video Cues are not strictly increasing";
        break;
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
    // at or before the first entry to entry zero, so a non-zero first entry
    // needs no special case, and the strictly-increasing check in the harvest
    // above still holds. The same is true of a scanned index, whose first
    // entry is simply the earliest random access Block the Clusters carry.

    // ---- Is the file's own index usable, and if not, rebuild it -----------
    //
    // Two separate questions, deliberately kept apart, because they have
    // opposite answers for the same symptom.
    //
    //   1. Can the FILE'S Cues serve as this index? A no here says nothing
    //      about the medium -- Cues are optional metadata and a live mux
    //      routinely writes them badly or not at all -- so the answer is to
    //      rebuild the index from the Clusters, never to refuse the file.
    //   2. Can the REBUILT index seed a seek anywhere in the medium? A no here
    //      is a fact about the bitstream: the encoder wrote no random access
    //      point inside the seek preroll, and no index can invent one. That is
    //      the only cue-shaped refusal left, and it is named for what it is.
    //
    // Coverage is measured by the same predicate in both places, so a scanned
    // index is held to exactly the bound a file-supplied one is.
    double widestSpanSeconds = 0.0;
    if (state->video) {
      if (degenerate == nullptr && state->cues.empty()) {
        degenerate = "the file carries no Cues for the selected video track";
      }
      if (degenerate == nullptr && state->cues.size() > kMaximumMatroskaCues) {
        degenerate = "the selected video Cue index is over its bound";
      }
      if (degenerate == nullptr &&
          !indexSeedsWithinPreroll(*state, &widestSpanSeconds)) {
        degenerate =
            "the selected video Cues leave a span wider than the seek preroll";
      }
      if (degenerate != nullptr) {
        const ScannedCueIndexOutcome scanned = buildScannedVideoCueIndex(
            *state, state->video->id, &state->cues, cancellation);
        if (scanned.error != MatroskaDemuxError::None) {
          result.status = scanned.status;
          result.error = scanned.error;
          result.message = std::string(scanned.message) + " while rebuilding "
                           "the seek index because " + degenerate;
          return result;
        }
        if (state->cues.empty()) {
          // Not the same refusal as a sparse one. A selected video track with
          // no random access Block anywhere has nothing to start decoding
          // from, at any target, so this is the index genuinely being absent
          // rather than the medium being coarse.
          result.status = MatroskaDemuxStatus::Unsupported;
          result.error = MatroskaDemuxError::MissingCues;
          result.message =
              std::string("no random access Block for the selected video "
                          "track exists in any Cluster, and ") +
              degenerate;
          return result;
        }
        if (!indexSeedsWithinPreroll(*state, &widestSpanSeconds)) {
          // Unsupported, not Failed: the file is conforming and plays from its
          // origin perfectly well. What it cannot do is seed a seek, and the
          // route that can (compatibility playback) should take it without the
          // hard protocol fault a Failed status renders as.
          result.status = MatroskaDemuxStatus::Unsupported;
          result.error = MatroskaDemuxError::SparseRandomAccess;
          result.message =
              "the selected video track offers " +
              std::to_string(state->cues.size()) +
              (state->cues.size() == 1 ? " random access point"
                                       : " random access points") +
              ", leaving a " + formatSeconds(widestSpanSeconds) +
              " s span with no seek seed against a bounded preroll of " +
              formatSeconds(state->limits.maximumVideoSeekPrerollSeconds) +
              " s";
          return result;
        }
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
