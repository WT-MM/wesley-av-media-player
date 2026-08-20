#pragma once

#include "media/native_media_source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace wam::media::matroska {

// A Matroska A_FLAC track's CodecPrivate is the native FLAC stream header: the
// four-byte 'fLaC' marker followed by the metadata blocks, of which the first
// is always STREAMINFO.
inline constexpr std::size_t kFlacStreamMarkerBytes{4};
inline constexpr std::size_t kFlacMetadataBlockHeaderBytes{4};
inline constexpr std::size_t kFlacStreamInfoBytes{34};

// AudioToolbox's FLAC decoder does NOT take that blob. It wants the ISO-BMFF
// 'dfLa' box, complete with its own 4-byte size and 4-byte type -- which was
// read out of Apple's own parser rather than guessed at: opening a .flac file
// with AudioFileOpenURL and asking for kAudioFilePropertyMagicCookieData
// returns exactly
//
//   00000032 'dfLa' 00000000 80000022 <34-byte STREAMINFO>
//
// The three plausible repackings (the raw CodecPrivate, the bare STREAMINFO
// payload, and the metadata block with its header but no box) are each refused
// with kAudioCodecUnsupportedFormatError, so the decoder parses the box rather
// than storing the bytes. See scratchpad/flacinfo.mm and sweep_probe.mm.
//
// The cookie this source builds carries STREAMINFO and nothing else. That is
// deliberate: it is all the decoder needs (proven -- a cookie built from every
// metadata block and one built from STREAMINFO alone both decode identically),
// and it makes the cookie a FIXED 50 bytes, so a file carrying a multi-megabyte
// PICTURE block cannot push the magic cookie past the pipeline's configuration
// budget.
inline constexpr std::size_t kFlacMagicCookieBytes{
    8U + 4U + kFlacMetadataBlockHeaderBytes + kFlacStreamInfoBytes};

// FLAC block sizes are 16..65535 frames; the format reserves 0.
inline constexpr std::uint32_t kMinimumFlacBlockSize{16};
inline constexpr std::uint32_t kMaximumFlacBlockSize{65'535};

enum class FlacAdmissionError : std::uint8_t {
  None,
  InvalidCodecPrivateSize,
  UnexpectedMagic,
  MissingStreamInfo,
  MalformedMetadataBlocks,
  InvalidBlockSize,
  // min != max: the stream's frames are not all the same length, so the
  // demuxer's affine ordinal grid cannot place them.
  VariableBlockSize,
  UnsupportedChannelCount,
  UnsupportedSampleRate,
  UnsupportedBitDepth,
  // STREAMINFO's total sample count is zero, i.e. the encoder did not know the
  // length. Without it there is no exact duration and no tail to trim to.
  UnknownTotalSamples,
};

struct FlacConfiguration {
  std::uint32_t sampleRate{0};
  std::uint8_t channelCount{0};
  std::uint8_t bitsPerSample{0};
  // Equal by admission, so every frame but the last decodes to exactly this
  // many samples. The last frame is legitimately shorter, and the decoder
  // emits it correctly -- see totalSamples.
  std::uint32_t blockSize{0};
  // STREAMINFO's own count of the decoded samples in the stream. This is what
  // makes FLAC the one codec in this sweep that needs no trim arithmetic at
  // all: the exact duration is READ, not derived. Measured equal to ffmpeg's
  // own decoded frame count on every fixture.
  std::uint64_t totalSamples{0};

  friend constexpr bool operator==(const FlacConfiguration &,
                                   const FlacConfiguration &) = default;
};

struct FlacAdmission {
  FlacAdmissionError error{FlacAdmissionError::InvalidCodecPrivateSize};
  std::optional<FlacConfiguration> configuration;

  [[nodiscard]] constexpr bool admitted() const noexcept {
    return error == FlacAdmissionError::None && configuration.has_value();
  }
};

// Validates the 'fLaC' marker, walks every metadata block so a blob whose
// lengths do not account for its own size is refused rather than handed to
// AudioToolbox, and reads STREAMINFO.
[[nodiscard]] FlacAdmission
parseFlacCodecPrivate(std::span<const std::byte> bytes) noexcept;

struct FlacMagicCookie {
  std::array<std::byte, kFlacMagicCookieBytes> bytes{};

  [[nodiscard]] constexpr std::span<const std::byte> view() const noexcept {
    return {bytes.data(), bytes.size()};
  }
};

// Builds the 'dfLa' cookie from the same CodecPrivate the admission read. The
// STREAMINFO block header is emitted with the last-block flag SET regardless of
// what it carried in the file, because the cookie contains only that one block
// and a decoder that kept reading would run off the end.
[[nodiscard]] std::optional<FlacMagicCookie>
buildFlacMagicCookie(std::span<const std::byte> codecPrivate) noexcept;

} // namespace wam::media::matroska
