#pragma once

#include "media/matroska_ebml.hpp"
#include "media/native_media_source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <variant>
#include <vector>

namespace wam::media::matroska {

struct MatroskaPrepareOutcome;

inline constexpr std::size_t kMaximumMatroskaClusters{65'536};
inline constexpr std::size_t kMaximumMatroskaCues{65'536};
inline constexpr std::size_t kMaximumMatroskaClusterBytes{64U * 1024U * 1024U};
inline constexpr std::size_t kMaximumMatroskaEncodedBlockBytes{
    kMaximumMatroskaClusterBytes};
inline constexpr std::size_t kMaximumMatroskaSeekClusters{8'192};

enum class MatroskaDemuxStatus : std::uint8_t {
  Ready,
  Unsupported,
  Cancelled,
  Failed,
};

enum class MatroskaDemuxError : std::uint8_t {
  None,
  InvalidRequest,
  InvalidContainer,
  UnsupportedContainer,
  TrackSelection,
  UnsupportedTrack,
  CodecConfiguration,
  InvalidTimeline,
  MissingCues,
  InvalidCue,
  IndexLimit,
  SampleLimit,
  FileChanged,
  Io,
  Cancelled,
  // Appended 2026-08-21. A video track whose coded dimensions are outside the
  // v1 admission envelope. It is split out of TrackSelection because that
  // bucket says only "the tracks you asked for are unavailable", which is the
  // one thing a dimension refusal must not say: the track IS there, it is the
  // envelope that refuses it, and the verdict has to carry both numbers.
  CodedDimensionLimit,
  // Appended 2026-08-21. The selected video track's own random access cadence
  // is wider than the seek preroll the route decodes through -- proven by a
  // Cluster scan, not inferred from a Cues element. Distinct from InvalidCue
  // and MissingCues on purpose: both of those blame the index, and this one
  // says the index is right and the BITSTREAM has no seed to offer. Nothing
  // this demuxer can build changes it.
  SparseRandomAccess,
};

// Exactly 24 bytes and therefore at most 1.5 MiB at the hard cluster cap.
struct MatroskaClusterIndexEntry {
  std::uint64_t encodedOffset{0};
  std::uint64_t timestampTick{0};
  std::uint32_t encodedSize{0};
  std::uint16_t dataOffsetDelta{0};
  std::uint8_t flags{0};
  std::uint8_t reserved{0};

  [[nodiscard]] constexpr bool unknownSize() const noexcept {
    return (flags & 1U) != 0;
  }
  [[nodiscard]] constexpr ByteRange encodedRange() const noexcept {
    return {encodedOffset, encodedSize};
  }
  [[nodiscard]] constexpr ByteRange dataRange() const noexcept {
    return {encodedOffset + dataOffsetDelta,
            encodedSize - dataOffsetDelta};
  }

  friend constexpr bool operator==(MatroskaClusterIndexEntry,
                                   MatroskaClusterIndexEntry) = default;
};
static_assert(sizeof(MatroskaClusterIndexEntry) == 24);

// Selected-video-only cue index: at most 1 MiB at the hard cue cap.
struct MatroskaCueIndexEntry {
  std::uint64_t timestampTick{0};
  std::uint32_t clusterIndex{0};
  std::uint32_t relativeBlockOffset{0};

  friend constexpr bool operator==(MatroskaCueIndexEntry,
                                   MatroskaCueIndexEntry) = default;
};
static_assert(sizeof(MatroskaCueIndexEntry) == 16);

// ---------------------------------------------------------------------------
// The SCANNED (synthetic) selected-video index.
//
// A Matroska Cues element is OPTIONAL and a live mux routinely omits it, writes
// it for the wrong track, stops writing it when the capture is interrupted, or
// -- GStreamer's matroskamux -- writes CuePoints without the equally optional
// CueRelativePosition this index needs to name a Block. In every one of those
// cases the file itself is conforming and its random access points are still
// discoverable: Cluster timestamps and Block headers are self-describing, so
// walking the Cluster directory's element headers rebuilds exactly the index
// Cues would have carried. The scan reads element headers only -- never a
// Block payload -- so its cost is one forward pass over the container's
// skeleton (measured: 34 ms for a 380 MB / 14,451-Block WebM).
//
// The scanned index reuses MatroskaCueIndexEntry and the SAME 65,536-entry cap
// as a file-supplied index, so the 1 MiB index budget is unchanged. What keeps
// it inside that cap for arbitrarily long media is decimation: an entry is
// recorded only when it is at least this far past the previous one.
inline constexpr std::uint64_t kMatroskaScannedCueSpacingNanoseconds{
    1'000'000'000};

// Bound 1 -- decimation never costs a seek its seed. The gap decimation can
// introduce is at most one spacing interval, which has to stay inside the seek
// preroll the envelope already promises to decode and discard.
static_assert(kMatroskaScannedCueSpacingNanoseconds <=
              static_cast<std::uint64_t>(
                  MediaSourceLimits::kHardMaximumVideoSeekPrerollSeconds) *
                  1'000'000'000ULL);

// Bound 2 -- memory. One entry per spacing interval over the entry cap is the
// longest medium the scanned index can describe without decimating further;
// 65,536 s is 18.2 hours, past any real single-file recording, and the index
// itself is exactly 1 MiB at that cap whether it came from Cues or the scan.
inline constexpr std::uint64_t kMatroskaScannedCueSpanNanoseconds{
    static_cast<std::uint64_t>(kMaximumMatroskaCues) *
    kMatroskaScannedCueSpacingNanoseconds};
static_assert(kMatroskaScannedCueSpanNanoseconds >=
              18ULL * 3'600ULL * 1'000'000'000ULL);
static_assert(sizeof(MatroskaCueIndexEntry) * kMaximumMatroskaCues ==
              1024U * 1024U);

// Bound 3 -- an entry's Block offset is stored relative to its Cluster's data
// range in 32 bits, and a Cluster is already capped well inside that.
static_assert(kMaximumMatroskaClusterBytes <= 0xFFFF'FFFFULL);

struct MatroskaCompressedSample {
  MediaTrackId track{0};
  MediaSampleKind kind{MediaSampleKind::EncodedVideo};
  std::array<FrameRange, ParseOptions::kHardMaximumLaceFrames> frames{};
  std::uint16_t frameCount{0};
  std::size_t aggregateBytes{0};
  MediaTime presentationTime{};
  MediaTime decodeTime{};
  MediaTime duration{};
  bool keyFrame{false};
  bool invisible{false};
  bool discardable{false};
};

struct MatroskaGenerationPlan {
  MediaTime requestedTarget{};
  MediaSeekMode mode{MediaSeekMode::Accurate};
  MediaTime actualDecodeStart{};
  MediaAudioGenerationWindow audioWindow{};
  std::uint32_t videoClusterIndex{0};
  std::uint64_t videoBlockOffset{0};
  std::uint32_t audioClusterIndex{0};
  std::uint64_t audioBlockOffset{0};
  std::uint16_t audioFrameIndex{0};
  std::uint64_t audioAccessUnitOrdinal{0};
};

struct MatroskaCursorEnd {};
struct MatroskaCursorCancelled {};
struct MatroskaCursorFailure {
  MatroskaDemuxError error{MatroskaDemuxError::Io};
  std::string message;
};

using MatroskaCursorReadResult =
    std::variant<MatroskaCompressedSample, MatroskaCursorEnd,
                 MatroskaCursorCancelled, MatroskaCursorFailure>;

class MatroskaCursor final {
 public:
  ~MatroskaCursor();
  MatroskaCursor(MatroskaCursor&&) noexcept;
  MatroskaCursor& operator=(MatroskaCursor&&) noexcept;
  MatroskaCursor(const MatroskaCursor&) = delete;
  MatroskaCursor& operator=(const MatroskaCursor&) = delete;

  [[nodiscard]] MatroskaCursorReadResult
  readNext(CancellationToken cancellation = {}) noexcept;

 private:
  struct Impl;
  explicit MatroskaCursor(std::unique_ptr<Impl> impl) noexcept;
  std::unique_ptr<Impl> impl_;
  friend class MatroskaPreparedAsset;
};

struct MatroskaPlanOutcome {
  MatroskaDemuxStatus status{MatroskaDemuxStatus::Failed};
  MatroskaDemuxError error{MatroskaDemuxError::InvalidTimeline};
  std::optional<MatroskaGenerationPlan> plan;
  std::string message;
};

class MatroskaPreparedAsset final
    : public std::enable_shared_from_this<MatroskaPreparedAsset> {
 public:
  ~MatroskaPreparedAsset();
  MatroskaPreparedAsset(const MatroskaPreparedAsset&) = delete;
  MatroskaPreparedAsset& operator=(const MatroskaPreparedAsset&) = delete;

  [[nodiscard]] const std::filesystem::path& path() const noexcept;
  [[nodiscard]] const std::shared_ptr<const MediaSourceDescriptor>&
  descriptor() const noexcept;
  [[nodiscard]] const MediaSourceLimits& limits() const noexcept;
  [[nodiscard]] std::uint64_t timestampScaleNanoseconds() const noexcept;
  [[nodiscard]] std::span<const MatroskaClusterIndexEntry>
  clusters() const noexcept;
  [[nodiscard]] std::span<const MatroskaCueIndexEntry> cues() const noexcept;

  [[nodiscard]] MatroskaPlanOutcome planGeneration(
      MediaTime target, MediaSeekMode mode,
      CancellationToken cancellation = {}) const noexcept;
  [[nodiscard]] std::unique_ptr<MatroskaCursor>
  makeVideoCursor(const MatroskaGenerationPlan& plan) const noexcept;
  [[nodiscard]] std::unique_ptr<MatroskaCursor>
  makeAudioCursor(const MatroskaGenerationPlan& plan) const noexcept;

  // Copies the exact concatenation of ranges. Reads are split into at most
  // 64 KiB and cancellation/file-identity checks bracket every read.
  [[nodiscard]] bool copyRanges(
      std::span<const FrameRange> ranges, std::span<std::byte> destination,
      CancellationToken cancellation = {},
      MatroskaDemuxError* error = nullptr) const noexcept;

 private:
  struct Impl;
  explicit MatroskaPreparedAsset(std::unique_ptr<Impl> impl) noexcept;
  std::unique_ptr<Impl> impl_;
  friend struct MatroskaPrepareOutcome;
  friend MatroskaPrepareOutcome prepareMatroska(
      std::shared_ptr<SeekableByteReader>, std::filesystem::path,
      const MediaSourceOpenOptions&, CancellationToken) noexcept;
  friend MatroskaPrepareOutcome prepareMatroskaLocalFile(
      const std::filesystem::path&, const MediaSourceOpenOptions&,
      CancellationToken) noexcept;
};

struct MatroskaPrepareOutcome {
  MatroskaDemuxStatus status{MatroskaDemuxStatus::Failed};
  MatroskaDemuxError error{MatroskaDemuxError::InvalidContainer};
  std::shared_ptr<const MatroskaPreparedAsset> asset;
  std::string message;
};

// Injected-reader seam used by deterministic tests and non-path owners. The
// asset retains exactly this reader object for its complete lifetime.
[[nodiscard]] MatroskaPrepareOutcome prepareMatroska(
    std::shared_ptr<SeekableByteReader> reader, std::filesystem::path path,
    const MediaSourceOpenOptions& options,
    CancellationToken cancellation = {}) noexcept;

// Opens once with O_RDONLY|O_CLOEXEC and retains that descriptor. No cursor or
// payload copy reopens the path.
[[nodiscard]] MatroskaPrepareOutcome prepareMatroskaLocalFile(
    const std::filesystem::path& path, const MediaSourceOpenOptions& options,
    CancellationToken cancellation = {}) noexcept;

}  // namespace wam::media::matroska
