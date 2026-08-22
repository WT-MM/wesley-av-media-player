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
