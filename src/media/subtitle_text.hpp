#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

// Neutral text-subtitle handling: cue records, payload rendering for the three
// text codecs Matroska carries, and whole-file parsers for the sidecar formats
// WAM can attach (whisper's own .srt output, and anything the user loads).
//
// Deliberately free of Qt and of Apple frameworks, for the same reason the
// Matroska parser is: it is pure, testable, and reusable from the demuxer, the
// Qt controller and a unit test without dragging a toolkit behind it.
//
// Full ASS styling is explicitly out of scope. An ASS payload is rendered as
// the text a reader needs -- override blocks removed, hard breaks preserved --
// which is what a player without libass can honestly show.
namespace wam::media::subtitles {

// Times are nanoseconds on the media timeline, matching MediaTime's unit and
// avoiding every floating-point rounding question at cue boundaries.
struct Cue {
  std::int64_t startNanoseconds{0};
  std::int64_t endNanoseconds{0};
  std::string text;

  [[nodiscard]] bool covers(std::int64_t t) const noexcept {
    return t >= startNanoseconds && t < endNanoseconds;
  }
};

// Bounds. A text track that exceeds either is truncated at the limit rather
// than refused: showing the first two hours of subtitles beats showing none,
// and the caller is told it was truncated.
inline constexpr std::size_t kMaximumCues{65'536};
inline constexpr std::size_t kMaximumTotalTextBytes{8U * 1024U * 1024U};
// One cue's rendered text. Longer payloads are truncated on a UTF-8 boundary.
inline constexpr std::size_t kMaximumCueTextBytes{4'096};

enum class TextCodec : std::uint8_t {
  Unknown,
  SubRip,   // S_TEXT/UTF8
  Ass,      // S_TEXT/ASS
  Ssa,      // S_TEXT/SSA
  WebVtt,   // S_TEXT/WEBVTT
};

// Matroska CodecID -> codec. Unknown for anything not a text codec, which is
// how PGS (S_HDMV/PGS) and VobSub (S_VOBSUB) are declined.
[[nodiscard]] TextCodec textCodecFromMatroskaCodecId(
    std::string_view codecId) noexcept;

[[nodiscard]] constexpr bool isTextCodec(TextCodec codec) noexcept {
  return codec != TextCodec::Unknown;
}

// ---------------------------------------------------------------------------
// Block payload rendering (one Matroska Block -> one cue's display text).
// ---------------------------------------------------------------------------

// S_TEXT/ASS and S_TEXT/SSA store a Dialogue line stripped of its "Dialogue:"
// keyword and of the Start/End timestamps, i.e. the field list
//   ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
// (SSA has no ReadOrder-less variant in Matroska; both carry 8 leading fields
// followed by the text, which may itself contain commas).
//
// Returns the text field with override blocks removed, "\N"/"\n" turned into
// real line breaks and "\h" into a space. A payload with fewer than 8 commas
// is treated as already being bare text rather than discarded.
[[nodiscard]] std::string renderAssDialoguePayload(std::string_view payload);

// Removes "<...>" inline tags (WebVTT), keeps line breaks and text.
[[nodiscard]] std::string renderWebVttPayload(std::string_view payload);

// Dispatches on codec; SubRip is passed through with only normalization.
[[nodiscard]] std::string renderBlockPayload(TextCodec codec,
                                             std::string_view payload);

// Removes ASS/SSA "{...}" override blocks and unescapes the "\N", "\n", "\h"
// sequences. Exposed for testing; renderAssDialoguePayload applies it.
[[nodiscard]] std::string stripAssOverrideTags(std::string_view text);

// Normalizes line endings to '\n', strips a UTF-8 BOM and trailing blank
// space, and truncates on a UTF-8 boundary at kMaximumCueTextBytes. Every
// render path ends here, so no cue can carry CRs or an unbounded payload.
[[nodiscard]] std::string normalizeCueText(std::string_view text);

// ---------------------------------------------------------------------------
// Whole-file parsers (sidecar sources: generated captions, user-loaded files).
// ---------------------------------------------------------------------------

struct ParsedFile {
  std::vector<Cue> cues;
  bool truncated{false};
  // Empty on success; a short reason otherwise. `cues` may still be non-empty
  // when a trailing block was malformed -- a partially readable subtitle file
  // is worth showing.
  std::string error;
};

// SubRip. Tolerates: missing/duplicated indices, CRLF, a BOM, blank lines
// inside a cue, "," or "." as the millisecond separator, and a final cue with
// no trailing blank line. A block whose timing line does not parse is skipped;
// a cue whose end precedes its start is skipped.
[[nodiscard]] ParsedFile parseSubRip(std::string_view bytes);

// SubStation Alpha / Advanced SSA: reads [Events], honours the Format: line to
// locate Start/End/Text, and renders each Dialogue through the same tag
// stripper the embedded path uses.
[[nodiscard]] ParsedFile parseAss(std::string_view bytes);

// WebVTT sidecar files (hh:mm:ss.mmm --> hh:mm:ss.mmm, optional cue settings).
[[nodiscard]] ParsedFile parseWebVtt(std::string_view bytes);

// Chooses a parser from the file's first bytes, then from the extension.
[[nodiscard]] ParsedFile parseSubtitleFile(std::string_view bytes,
                                           std::string_view extensionHint);

// ---------------------------------------------------------------------------
// Cue-list finishing and lookup.
// ---------------------------------------------------------------------------

// Sorts by start time (stable, so equal starts keep file order), drops empty
// and non-positive-length cues, and clamps each cue's end to the next cue's
// start ONLY when the caller asks -- overlapping cues are legal in ASS and are
// preserved otherwise.
void finalizeCues(std::vector<Cue>* cues, bool clampOverlaps);

// Index of the cue covering `t`, or -1. `hint` is the previously returned
// index and turns the common sequential case into two comparisons; any value
// is safe. Cues must be sorted by start.
[[nodiscard]] std::ptrdiff_t cueIndexAt(const std::vector<Cue>& cues,
                                        std::int64_t t,
                                        std::ptrdiff_t hint) noexcept;

}  // namespace wam::media::subtitles
