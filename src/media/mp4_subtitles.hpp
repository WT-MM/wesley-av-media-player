#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

#include "media/subtitle_text.hpp"
#include "media/tx3g_text.hpp"

// Embedded MP4/MOV timed-text subtitle tracks (tx3g / "mov_text"), read on a
// lane entirely separate from playback.
//
// WHY THIS IS NOT IN avfoundation_media_source.mm, and why it does not use
// AVAssetReader. The same reasoning matroska_subtitles.hpp gives applies here:
// the playback source owns the clock's input and the dispatcher's admission,
// and a subtitle line every few seconds has no business near it. Beyond that,
// vending subtitle samples through AVAssetReader would mean adding a second
// reader output to the very object whose read-count and admission behaviour
// are pinned by tests. This walks the sample table itself, through its own
// descriptor, and cannot perturb playback at all.
//
// It is also neutral: no Qt, no AVFoundation. That is what lets the tx3g
// decode be unit-tested against synthesized samples, and it is what will let
// the MPEG-TS and Matroska routes reuse it if they ever carry tx3g.
namespace wam::media::mp4 {

// What the track's handler declares it is. Only Tx3gText is decodable today.
enum class SubtitleTrackKind : std::uint8_t {
  Unknown,
  // handler 'sbtl' or 'text' with a 'tx3g' sample entry: 3GPP timed text.
  Tx3gText,
  // handler 'clcp' with a 'c608'/'c708' sample entry: a closed-caption TRACK,
  // which is a different thing from captions carried in video SEI. Reported so
  // the menu can say the file has one; decoding it is a named deferral.
  ClosedCaptionTrack,
};

struct SubtitleTrackInfo {
  // The MP4 track_id from tkhd -- the identity the cue loader takes.
  std::uint32_t trackId{0};
  SubtitleTrackKind kind{SubtitleTrackKind::Unknown};
  // mdhd language, unpacked from its 5-bit-per-letter packing. "und" when
  // absent or when the packed value is the "undetermined" code.
  std::string language;
  // The track's user-facing name from a 'udta'/'name' box, when present.
  std::string name;
  // tkhd flag 0x1: the track is enabled.
  bool enabled{true};
  std::uint32_t sampleCount{0};
};

struct SubtitleTrackInventory {
  std::vector<SubtitleTrackInfo> tracks;
  // True when the file parsed far enough to trust `tracks`. False means "we
  // could not tell", which the caller must treat as "no subtitle tracks"
  // rather than as an error worth showing anyone.
  bool valid{false};
};

// Bounds. A 'moov' larger than this is not parsed: it is either not a media
// file we can serve or it is pathological, and either way the answer is "no
// subtitle tracks" rather than an unbounded read.
inline constexpr std::uint64_t kMaximumMoovBytes{64ULL * 1024ULL * 1024ULL};
// Sample tables larger than this are truncated, not refused.
inline constexpr std::size_t kMaximumSubtitleSamples{131'072};
// One tx3g sample. The format's own length field is 16-bit, and style boxes
// are small; anything larger is malformed.
inline constexpr std::size_t kMaximumSubtitleSampleBytes{262'144};

// Header-only pass: finds 'moov', walks each 'trak' and reports the timed-text
// tracks. No sample payload is read. Cost is one bounded read of the moov box
// regardless of file size.
[[nodiscard]] SubtitleTrackInventory inspectMp4SubtitleTracks(
    const std::filesystem::path& path) noexcept;

// Same pass over an in-memory MP4 (or just its moov region). Exists so tests
// can drive the walker without a file.
[[nodiscard]] SubtitleTrackInventory inspectMp4SubtitleTracksInMemory(
    std::string_view bytes) noexcept;

struct SubtitleTrackLoad {
  std::vector<subtitles::Cue> cues;
  // Style spans per cue, parallel to `cues`. Empty for an unstyled track. A
  // cue with no styling has an empty vector at its index.
  std::vector<std::vector<subtitles::Tx3gStyleSpan>> styles;
  bool ok{false};
  bool truncated{false};
  // Samples that decoded to nothing usable. Reported rather than hidden.
  std::uint32_t skipped{0};
  std::string error;
};

// Reads every sample of one timed-text track and renders it to cues.
//
// tx3g states duration per sample rather than an end time, and spells "clear
// the screen" as a zero-length sample. Both are honoured: a zero-length sample
// produces no cue, and a text sample's end is its start plus its stts duration
// (clamped to the next sample's start, which is what a muxer that writes
// overlong durations means).
[[nodiscard]] SubtitleTrackLoad loadMp4SubtitleTrack(
    const std::filesystem::path& path, std::uint32_t trackId) noexcept;

// Unpacks mdhd's 15-bit ISO-639-2 packing (three 5-bit letters, 0x60 based).
// Exposed for testing.
[[nodiscard]] std::string unpackIso639Language(std::uint16_t packed);

}  // namespace wam::media::mp4
