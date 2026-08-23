#pragma once

#include "media/matroska_ebml.hpp"
#include "media/subtitle_text.hpp"

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

// Embedded Matroska/WebM TEXT subtitle tracks, read on a lane that is entirely
// separate from playback.
//
// WHY THIS IS NOT IN matroska_demuxer.cpp. The demuxer's prepared asset, its
// cursors and its A/V merge are the playback graph: they own the clock's input,
// the dispatcher's admission and the read-count guarantee that the
// pre-admission pass exists to protect. A subtitle line every few seconds has
// no business anywhere near that. This pair therefore sits directly on the
// public matroska_ebml parser and opens its OWN pread-backed descriptor, so:
//
//   * matroska_demuxer.{hpp,cpp} are byte-unchanged, and the mutation-checked
//     "refuses a multichannel file without reading inside any Cluster" test
//     cannot regress because nothing it covers was touched;
//   * a subtitle read can never block, starve, stall or reorder an audio or
//     video read, because it does not share a descriptor, a thread, a buffer
//     or a lock with them;
//   * admission is unaffected: an unreadable or absent subtitle track degrades
//     to "no subtitle tracks", never to a playback failure.
//
// Bitmap subtitles (S_HDMV/PGS, S_VOBSUB) are out of scope and are simply not
// reported as tracks: they need a bitmap decoder and a compositing surface,
// which is a different feature from a text overlay.
namespace wam::media::matroska {

struct SubtitleTrackInfo {
  // Matroska TrackNumber -- the identity the cue loader takes.
  std::uint64_t number{0};
  subtitles::TextCodec codec{subtitles::TextCodec::Unknown};
  // TrackEntry/Language, ISO 639-2 ("eng", "fre"). "und" when absent.
  // LanguageBCP47 (0x22B59D) is deliberately NOT consulted; the EBML parser
  // does not collect it today and Language is present on every real mux.
  std::string language;
  // TrackEntry/Name, decoded from its ByteRange. Empty when absent.
  std::string name;
  bool defaultFlag{false};
  bool forcedFlag{false};
  bool enabled{true};
};

struct SubtitleTrackInventory {
  std::vector<SubtitleTrackInfo> tracks;
  // True when the file parsed far enough to trust `tracks`. False means "we
  // could not tell", which the caller must treat as "no subtitle tracks"
  // rather than as an error worth showing anyone.
  bool valid{false};
};

// Header-only. Parses the EBML header, Info and Tracks and stops at the first
// Cluster; Clusters are skipped in O(1) by declared size and no Block is ever
// touched. This is the same shape as the demuxer's pre-admission probe and
// costs a few hundred reads regardless of file size.
[[nodiscard]] SubtitleTrackInventory inspectMatroskaSubtitleTracks(
    const std::filesystem::path& path, CancellationToken cancellation = {}) noexcept;

// Same pass against a caller-supplied reader. Exists so a test can count and
// bound the reads this makes -- the cost of the header pass is a contract, not
// an implementation detail, because it runs on every Matroska open.
[[nodiscard]] SubtitleTrackInventory inspectMatroskaSubtitleTracks(
    SeekableByteReader& reader, CancellationToken cancellation = {}) noexcept;

struct SubtitleTrackLoad {
  std::vector<subtitles::Cue> cues;
  bool ok{false};
  bool truncated{false};
  bool cancelled{false};
  // Number of Blocks that carried no usable duration and were therefore not
  // shown. Reported rather than hidden: a track that loses cues this way is a
  // fact worth being able to see.
  std::uint32_t skippedWithoutDuration{0};
  std::string error;
};

// One bounded pass over the container, with only `trackNumber` selected, so
// every other track's Blocks are skipped from a bounded prefix with no payload
// read. Text payloads ARE read (they are the point) through the same
// descriptor. Intended to run on a worker thread; honour `cancellation`.
[[nodiscard]] SubtitleTrackLoad loadMatroskaSubtitleTrack(
    const std::filesystem::path& path, std::uint64_t trackNumber,
    subtitles::TextCodec codec, CancellationToken cancellation = {}) noexcept;

// Same load against a caller-supplied reader. The file-identity re-check that
// the path form performs at the end is the one thing this cannot do, so the
// path form stays the production entry point; this exists to make the read
// behaviour measurable next to the header pass above.
[[nodiscard]] SubtitleTrackLoad loadMatroskaSubtitleTrack(
    SeekableByteReader& reader, std::uint64_t trackNumber,
    subtitles::TextCodec codec, CancellationToken cancellation = {}) noexcept;

}  // namespace wam::media::matroska
