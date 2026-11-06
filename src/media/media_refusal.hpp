#pragma once

#include <cstddef>
#include <cstdint>
#include <iterator>
#include <string>
#include <string_view>

namespace wam::media {

// The order is a contract: tests print the ordinal of MediaSourceOpenStatus.
enum class MediaSourceOpenStatus : std::uint8_t {
  Ready,
  Unsupported,
  Cancelled,
  Failed,
};

// Every typed refusal a media source can name. Append new values only.
//
// CodedDimensionLimit: a video track whose coded dimensions are outside the
// admission envelope. Distinct from TrackSelection, which says "the tracks
// you asked for are unavailable": the track IS there, the envelope refuses
// it, and the verdict carries both numbers.
//
// SparseRandomAccess: the selected video track's own random access cadence is
// wider than the seek preroll the route decodes through, proven by a Cluster
// scan rather than inferred from a Cues element. Distinct from InvalidCue and
// MissingCues, which both blame the index; this says the index is right and
// the bitstream has no seed to offer.
//
// SegmentLayout: a Matroska file that is not one finite, unlinked Segment.
// MissingInitialization: a recording whose initialization metadata (moov) is
// missing.
#define WAM_MEDIA_REFUSAL_CLASSES(X) \
  X(None)                            \
  X(InvalidRequest)                  \
  X(InvalidContainer)                \
  X(UnsupportedContainer)            \
  X(SegmentLayout)                   \
  X(NotTransportStream)              \
  X(MissingProgramTable)             \
  X(TrackSelection)                  \
  X(ProgramSelection)                \
  X(UnsupportedTrack)                \
  X(UnsupportedStreamType)           \
  X(CodecConfiguration)              \
  X(CodedDimensionLimit)             \
  X(InvalidTimeline)                 \
  X(MissingCues)                     \
  X(InvalidCue)                      \
  X(SparseRandomAccess)              \
  X(IndexLimit)                      \
  X(SampleLimit)                     \
  X(ScanLimit)                       \
  X(FileChanged)                     \
  X(Io)                              \
  X(Cancelled)                       \
  X(MissingInitialization)           \
  X(AudioBackendConfigurationRefused) \
  X(AudioTrackRetryFailed)           \
  X(AudioTrackRetryExhausted)        \
  X(AudioTrackRetryUnavailable)

#define WAM_MEDIA_REFUSAL_ENUMERATOR(name) name,
enum class MediaRefusalClass : std::uint8_t {
  WAM_MEDIA_REFUSAL_CLASSES(WAM_MEDIA_REFUSAL_ENUMERATOR)
};
#undef WAM_MEDIA_REFUSAL_ENUMERATOR

#define WAM_MEDIA_REFUSAL_NAME(name) #name,
inline constexpr const char* kMediaRefusalClassNames[] = {
    WAM_MEDIA_REFUSAL_CLASSES(WAM_MEDIA_REFUSAL_NAME)};
#undef WAM_MEDIA_REFUSAL_NAME
#undef WAM_MEDIA_REFUSAL_CLASSES

[[nodiscard]] constexpr const char* mediaRefusalClassName(
    MediaRefusalClass refusal) noexcept {
  const auto index = static_cast<std::size_t>(refusal);
  return index < std::size(kMediaRefusalClassNames)
             ? kMediaRefusalClassNames[index]
             : "Unknown";
}

// "<what> (<class name>)". The suffix keeps the class recoverable from text
// that has to travel as a plain failure message.
[[nodiscard]] inline std::string refusalMessage(std::string_view what,
                                                MediaRefusalClass refusal) {
  std::string message(what);
  message += " (";
  message += mediaRefusalClassName(refusal);
  message += ")";
  return message;
}

}  // namespace wam::media
