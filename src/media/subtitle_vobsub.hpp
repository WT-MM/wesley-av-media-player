#pragma once

#include "media/subtitle_bitmap.hpp"

#include <array>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>

// VobSub / DVD sub-pictures (Matroska CodecID S_VOBSUB).
//
// A DVD subtitle is a "sub-picture unit" (SPU): a run of 2-bit run-length data
// followed by a chain of control sequences that say when to show it, where to
// put it, which four of the sixteen palette colours to use and how opaque each
// of them is. In Matroska each Block payload is exactly one SPU and the Block
// timestamp is the SPU's own time base; the sixteen-entry palette and the
// coordinate space live in the track's CodecPrivate, which is the text of the
// original .idx file:
//
//     size: 720x480
//     palette: 000000, 0000ff, 00ff00, ...   (16 RRGGBB entries)
//
// SPU layout:
//     u16 packetSize | u16 controlOffset | pixel data ... | control sequences
//
// Control sequence: u16 delay (in 1024/90000 s units) | u16 nextOffset |
// commands until 0xFF. The commands this decoder honours:
//     0x00 forced display        0x01 start display     0x02 stop display
//     0x03 set palette (4 nibbles)   0x04 set alpha (4 nibbles)
//     0x05 set display area (two 12-bit x, two 12-bit y)
//     0x06 set pixel-data offsets (top field, bottom field)
//
// Qt-free and Apple-free by the same argument as subtitle_text.hpp.
namespace wam::media::subtitles::vobsub {

// The sixteen-entry track palette plus the coordinate space, parsed from the
// Matroska CodecPrivate (the .idx text).
struct IdxMetadata {
  std::uint32_t width{0};
  std::uint32_t height{0};
  // 0x00RRGGBB per entry; alpha comes from the SPU, never from the .idx.
  std::array<std::uint32_t, 16> palette{};
  bool hasPalette{false};
  bool hasSize{false};
};

// Parses the "size:" and "palette:" lines. Every other line (langidx, id,
// timestamp, custom colors, ...) is ignored: they describe a sidecar .sub file
// that Matroska has already replaced with its own Blocks. Returns false only
// when neither line was found.
[[nodiscard]] bool parseIdxMetadata(std::string_view text, IdxMetadata* out,
                                    std::string* error);

// A DVD sub-picture's default palette, used when the track carries no .idx
// palette at all. Chosen so text remains legible rather than invisible: entry 0
// black, 1 white, 2 black, 3 grey, which is the conventional DVD arrangement
// for a white glyph with a black border.
[[nodiscard]] std::array<std::uint32_t, 16> defaultIdxPalette() noexcept;

// One decoded SPU.
struct SubPicture {
  // Offsets from the Block's own timestamp, in nanoseconds.
  std::int64_t startOffsetNanoseconds{0};
  std::int64_t endOffsetNanoseconds{0};
  bool hasStop{false};
  bool forced{false};
  std::int32_t x{0};
  std::int32_t y{0};
  BitmapImage image;
};

// Decodes one whole SPU (one Matroska Block payload). `metadata` supplies the
// sixteen-entry palette. Returns false when the packet is unusable.
[[nodiscard]] bool decodeSubPicture(std::span<const std::uint8_t> packet,
                                    const IdxMetadata& metadata,
                                    SubPicture* out, std::string* error);

// The 2-bit run-length form DVD sub-pictures use, decoded into `width*height`
// palette indices in the range 0..3.
//
// Nibbles are read most-significant first. A run is the shortest of:
//     nnnn                (n >= 0x4)   run = n >> 2      (1..3)
//     nnnnnnnn            (n >= 0x10)  run = n >> 2      (4..15)
//     nnnnnnnnnnnn        (n >= 0x40)  run = n >> 2      (16..63)
//     nnnnnnnnnnnnnnnn                 run = n >> 2      (0..255)
// with colour = n & 3 in every case, and run == 0 in the four-nibble form
// meaning "to the end of this line". Each line ends on a byte boundary.
//
// The two fields are interleaved: `topOffset` starts the even lines and
// `bottomOffset` the odd ones, both as byte offsets into `data`.
[[nodiscard]] bool decodeRunLength(std::span<const std::uint8_t> data,
                                   std::size_t topOffset,
                                   std::size_t bottomOffset,
                                   std::uint32_t width, std::uint32_t height,
                                   std::vector<std::uint8_t>* indices,
                                   std::string* error);

// ---------------------------------------------------------------------------
// Track decoding.
// ---------------------------------------------------------------------------

// Turns a track's Blocks into timed cues. Unlike PGS this is stateless between
// Blocks -- each SPU carries its own start and stop -- but an SPU with no stop
// command is closed by the following SPU, so the decoder still accumulates.
class TrackDecoder {
 public:
  // `codecPrivate` is the Matroska CodecPrivate (the .idx text); it may be
  // empty, in which case the default palette and a 720x480 canvas are assumed.
  explicit TrackDecoder(std::string_view codecPrivate);

  // One Matroska Block payload at `timestampNanoseconds`.
  // `durationNanoseconds` is the container's BlockDuration (or DefaultDuration)
  // and is 0 when absent. It is TRUSTED AHEAD of the SPU's own stop command,
  // matching the rule the text-subtitle loader already applies: Matroska's
  // BlockDuration is the container's statement about when a cue ends, and real
  // muxes carry it precisely because an SPU's stop delay is often "unknown".
  // Returns false only when the packet could not be decoded at all.
  bool appendBlock(std::span<const std::uint8_t> payload,
                   std::int64_t timestampNanoseconds,
                   std::int64_t durationNanoseconds = 0);

  // Closes a cue still open at `endNanoseconds` and returns the track.
  [[nodiscard]] BitmapSubtitleContent finish(std::int64_t endNanoseconds);

  [[nodiscard]] const std::string& error() const noexcept { return error_; }
  [[nodiscard]] const IdxMetadata& metadata() const noexcept { return metadata_; }

 private:
  void noteError(std::string_view reason);

  IdxMetadata metadata_;
  BitmapSubtitleContent content_;
  // Index of a cue whose stop time is not yet known.
  std::size_t openCue_{static_cast<std::size_t>(-1)};
  std::size_t indexBytes_{0};
  std::string error_;
  bool errorSet_{false};
};

}  // namespace wam::media::subtitles::vobsub
