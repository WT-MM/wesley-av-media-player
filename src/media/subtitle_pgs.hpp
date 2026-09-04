#pragma once

#include "media/subtitle_bitmap.hpp"

#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <vector>

// HDMV Presentation Graphics (Blu-ray PGS, Matroska CodecID S_HDMV/PGS).
//
// The format is small and fully documented, so WAM decodes it directly rather
// than taking a dependency: a presentation graphics stream is a sequence of
// segments, each
//
//     type (u8) | size (u16 BE) | payload[size]
//
// grouped into "display sets" terminated by an END segment. A display set that
// carries composition objects puts bitmaps on screen; a display set with zero
// composition objects takes them off again. Five segment types exist:
//
//   PCS (0x16)  presentation composition -- the canvas size, the composition
//               state, and where each object is placed
//   WDS (0x17)  window definitions -- the rectangles compositions live in
//   PDS (0x14)  palette definition -- YCrCb + alpha entries, 0..255
//   ODS (0x15)  object definition -- width, height and run-length data,
//               possibly split across several segments
//   END (0x80)  end of display set
//
// In Matroska each Block payload holds the segments of one display set with no
// further framing, and the Block timestamp supplies the time. In a standalone
// .sup file every segment is additionally prefixed by a 10-byte header
// ("PG", PTS u32, DTS u32) at 90 kHz; parseSupStream reads that form.
//
// Qt-free and Apple-free by the same argument as subtitle_text.hpp.
namespace wam::media::subtitles::pgs {

enum class SegmentType : std::uint8_t {
  PaletteDefinition = 0x14,
  ObjectDefinition = 0x15,
  PresentationComposition = 0x16,
  WindowDefinition = 0x17,
  End = 0x80,
};

[[nodiscard]] bool isKnownSegmentType(std::uint8_t value) noexcept;

struct Segment {
  SegmentType type{SegmentType::End};
  // Points into the caller's buffer; valid only as long as that buffer is.
  std::span<const std::uint8_t> payload;
  // 90 kHz presentation timestamp. Meaningful only for .sup input; a Matroska
  // Block carries its own timestamp and leaves this zero.
  std::uint32_t presentationTimestamp90k{0};
};

// Splits one un-prefixed segment run (a Matroska Block payload). A trailing
// partial segment is an error: Matroska Blocks are whole display sets.
[[nodiscard]] bool parseSegments(std::span<const std::uint8_t> bytes,
                                 std::vector<Segment>* out,
                                 std::string* error);

// Splits a standalone .sup elementary stream, honouring the 10-byte
// "PG" + PTS + DTS header on every segment.
[[nodiscard]] bool parseSupStream(std::span<const std::uint8_t> bytes,
                                  std::vector<Segment>* out,
                                  std::string* error);

// ---------------------------------------------------------------------------
// Segment payload parsers. Each is total: it either fills its output and
// returns true, or leaves it unspecified, sets `error` and returns false.
// ---------------------------------------------------------------------------

enum class CompositionState : std::uint8_t {
  Normal = 0x00,
  AcquisitionPoint = 0x40,
  EpochStart = 0x80,
};

struct CompositionObject {
  std::uint16_t objectId{0};
  std::uint8_t windowId{0};
  // Bit 0x40 of the object flags. The Blu-ray spec names this
  // "forced_on_flag": it marks a caption the player must show even when
  // subtitles are otherwise off (burned-in signage, foreign dialogue).
  bool forced{false};
  bool cropped{false};
  std::int32_t x{0};
  std::int32_t y{0};
  // Only meaningful when `cropped`.
  std::uint16_t cropX{0};
  std::uint16_t cropY{0};
  std::uint16_t cropWidth{0};
  std::uint16_t cropHeight{0};
};

struct PresentationComposition {
  std::uint16_t width{0};
  std::uint16_t height{0};
  std::uint16_t compositionNumber{0};
  CompositionState state{CompositionState::Normal};
  bool paletteUpdate{false};
  std::uint8_t paletteId{0};
  std::vector<CompositionObject> objects;
};

[[nodiscard]] bool parsePresentationComposition(
    std::span<const std::uint8_t> payload, PresentationComposition* out,
    std::string* error);

struct WindowRect {
  std::uint8_t windowId{0};
  std::uint16_t x{0};
  std::uint16_t y{0};
  std::uint16_t width{0};
  std::uint16_t height{0};
};

[[nodiscard]] bool parseWindowDefinition(std::span<const std::uint8_t> payload,
                                         std::vector<WindowRect>* out,
                                         std::string* error);

struct PaletteEntry {
  std::uint8_t index{0};
  std::uint8_t y{0};
  std::uint8_t cr{0};
  std::uint8_t cb{0};
  std::uint8_t alpha{0};
};

struct PaletteDefinition {
  std::uint8_t paletteId{0};
  std::uint8_t version{0};
  std::vector<PaletteEntry> entries;
};

[[nodiscard]] bool parsePaletteDefinition(std::span<const std::uint8_t> payload,
                                          PaletteDefinition* out,
                                          std::string* error);

struct ObjectDefinition {
  std::uint16_t objectId{0};
  std::uint8_t version{0};
  bool first{false};  // 0x80 -- first in sequence, carries width/height/length
  bool last{false};   // 0x40 -- last in sequence
  // Present only when `first`. The declared byte count covers width, height and
  // the run-length data across the whole sequence.
  std::uint32_t declaredDataLength{0};
  std::uint16_t width{0};
  std::uint16_t height{0};
  // This segment's slice of the run-length data.
  std::span<const std::uint8_t> data;
};

[[nodiscard]] bool parseObjectDefinition(std::span<const std::uint8_t> payload,
                                         ObjectDefinition* out,
                                         std::string* error);

// PGS run-length decoding into `width * height` palette indices.
//
//   C (C != 0)                        one pixel of colour C
//   0x00 0x00                         end of line
//   0x00 00LLLLLL                     L pixels of colour 0
//   0x00 01LLLLLL LLLLLLLL            L pixels of colour 0
//   0x00 10LLLLLL CCCCCCCC            L pixels of colour C
//   0x00 11LLLLLL LLLLLLLL CCCCCCCC   L pixels of colour C
//
// A line that ends short is padded with colour 0 and a line that overruns is
// clipped: real muxes contain both, and refusing the object would lose a whole
// caption over a rounding error in an encoder nobody controls.
[[nodiscard]] bool decodeRunLength(std::span<const std::uint8_t> rle,
                                   std::uint32_t width, std::uint32_t height,
                                   std::vector<std::uint8_t>* indices,
                                   std::string* error);

// ---------------------------------------------------------------------------
// Track decoding.
// ---------------------------------------------------------------------------

// Accumulates display sets into timed cues. Epoch state -- palettes and object
// bitmaps -- persists across display sets exactly as the format requires, so
// this must be fed a track's Blocks in order.
//
// Timing: a display set carrying composition objects opens cues at that
// timestamp; the next display set with zero composition objects closes them.
// Matroska muxes carry the clear as its own Block, which is why the decoder is
// stateful rather than per-Block.
class TrackDecoder {
 public:
  TrackDecoder();

  // One Matroska Block payload (a whole display set, no "PG" prefix) at
  // `timestampNanoseconds` on the media timeline. Returns false when the block
  // could not be parsed at all; malformed sub-parts are skipped and recorded in
  // `error()` without failing the track.
  bool appendBlock(std::span<const std::uint8_t> payload,
                   std::int64_t timestampNanoseconds);

  // Feeds a whole standalone .sup stream, using its own 90 kHz timestamps.
  bool appendSupStream(std::span<const std::uint8_t> bytes);

  // Closes any cue still open at `endNanoseconds` and returns the track. The
  // decoder must not be used afterwards.
  [[nodiscard]] BitmapSubtitleContent finish(std::int64_t endNanoseconds);

  [[nodiscard]] const std::string& error() const noexcept { return error_; }

 private:
  struct ObjectState {
    std::uint16_t width{0};
    std::uint16_t height{0};
    std::uint32_t declaredDataLength{0};
    std::vector<std::uint8_t> data;
    bool complete{false};
  };

  bool applyDisplaySet(const std::vector<Segment>& segments,
                       std::int64_t timestampNanoseconds);
  void closeOpenCues(std::int64_t endNanoseconds);
  void noteError(std::string_view reason);

  // objectId -> most recent complete bitmap for this epoch.
  std::vector<std::pair<std::uint16_t, ObjectState>> objects_;
  // paletteId -> palette, retained across display sets within an epoch.
  std::vector<std::pair<std::uint8_t, BitmapPalette>> palettes_;
  std::vector<WindowRect> windows_;

  BitmapSubtitleContent content_;
  // Cues opened by the last composition and not yet closed.
  std::vector<std::size_t> openCues_;
  std::int64_t openSince_{0};
  std::size_t indexBytes_{0};
  std::string error_;
  bool errorSet_{false};
};

}  // namespace wam::media::subtitles::pgs
