#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

// Neutral 3GPP Timed Text (tx3g / "mov_text") sample decoding.
//
// One tx3g sample is a 16-bit big-endian text length, that many UTF-8 bytes,
// and then zero or more optional boxes. Only 'styl' is read; every other box
// is skipped by its declared size. A zero-length sample is the format's way of
// spelling "nothing is on screen from here", and is reported as such rather
// than as an empty cue, because the two mean different things to a cue list.
//
// Deliberately free of Qt and of Apple frameworks, like subtitle_text.hpp: the
// AVFoundation adapter, a raw box walker and a unit test can all use it.
namespace wam::media::subtitles {

// A style record from a 'styl' box. Character offsets are UTF-16 code-unit
// offsets into the sample text, which is what the specification says and what
// every muxer writes; convertStyleRangesToUtf8 restates them as byte offsets
// into the UTF-8 payload so callers never have to think in UTF-16.
struct Tx3gStyleRecord {
  std::uint16_t startChar{0};
  std::uint16_t endChar{0};
  std::uint16_t fontId{0};
  std::uint8_t faceStyleFlags{0};
  std::uint8_t fontSize{0};
  std::uint32_t textColorRgba{0};

  static constexpr std::uint8_t kBold{0x01};
  static constexpr std::uint8_t kItalic{0x02};
  static constexpr std::uint8_t kUnderline{0x04};

  [[nodiscard]] constexpr bool bold() const noexcept {
    return (faceStyleFlags & kBold) != 0;
  }
  [[nodiscard]] constexpr bool italic() const noexcept {
    return (faceStyleFlags & kItalic) != 0;
  }
  [[nodiscard]] constexpr bool underline() const noexcept {
    return (faceStyleFlags & kUnderline) != 0;
  }
};

// A style range restated in UTF-8 byte offsets, which is the form the overlay
// needs. Only the three face-style bits survive; see kDroppedTx3gFeatures.
struct Tx3gStyleSpan {
  std::size_t startByte{0};
  std::size_t endByte{0};
  bool bold{false};
  bool italic{false};
  bool underline{false};

  [[nodiscard]] constexpr bool plain() const noexcept {
    return !bold && !italic && !underline;
  }
};

struct Tx3gSample {
  // Normalized display text (never longer than kMaximumCueTextBytes).
  std::string text;
  // Style spans in UTF-8 byte offsets into `text`, sorted, non-overlapping,
  // clamped to the text, and with plain spans dropped. Empty for an unstyled
  // sample, which is the overwhelmingly common case.
  std::vector<Tx3gStyleSpan> styles;
  // True when the sample declared zero text bytes: an explicit "clear".
  bool clearsScreen{false};
  // True when a box was truncated or a style record fell outside the text; the
  // sample is still returned, because a readable line beats a discarded one.
  bool malformed{false};
};

// Bounds. A sample carrying more style records than this keeps the first
// kMaximumStyleRecords and sets `malformed`.
inline constexpr std::size_t kMaximumStyleRecords{64};

// Decodes one tx3g sample. Returns false only when `sample` is too short to
// hold the mandatory 16-bit length, which is the one unrecoverable shape.
[[nodiscard]] bool decodeTx3gSample(std::string_view sample, Tx3gSample* out);

// Restates UTF-16 code-unit style offsets as UTF-8 byte offsets into `text`.
// Exposed for testing. Offsets past the end of the text clamp to its end.
[[nodiscard]] std::vector<Tx3gStyleSpan> convertStyleRangesToUtf8(
    std::string_view text, const std::vector<Tx3gStyleRecord>& records,
    bool* malformed);

// What this decoder deliberately does not carry out of a tx3g sample. Kept as
// a named list so the omission is a decision on the record rather than a gap:
//   - the sample description's default style, box, and display flags
//     (scroll-in/out, vertical placement, "fill text region");
//   - per-sample 'tbox' text boxes, so every cue lands where the overlay puts
//     every other cue;
//   - font table ('ftab') name lookup, colour and font size from 'styl';
//   - 'hlit'/'hclr' highlight, 'dlay' delay, 'href' links, 'krok' karaoke,
//     and the text-wrap box;
//   - right-to-left and vertical text layout.
// The three face-style bits are carried because they are the only part of the
// format that changes what a word means rather than where it sits.
inline constexpr std::string_view kDroppedTx3gFeatures{
    "tx3g: colour, font, size, position/tbox, highlight, karaoke, links, "
    "scroll flags and RTL/vertical layout are not carried; bold/italic/"
    "underline are"};

}  // namespace wam::media::subtitles
