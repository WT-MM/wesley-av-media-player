#include "media/mp4_subtitles.hpp"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>

namespace wam::media::mp4 {
namespace {

constexpr std::size_t kBoxHeader{8};

[[nodiscard]] unsigned char at(std::string_view s, std::size_t i) noexcept {
  return static_cast<unsigned char>(s[i]);
}

[[nodiscard]] std::uint16_t readU16(std::string_view s, std::size_t i) noexcept {
  return static_cast<std::uint16_t>((at(s, i) << 8) | at(s, i + 1));
}

[[nodiscard]] std::uint32_t readU32(std::string_view s, std::size_t i) noexcept {
  return (static_cast<std::uint32_t>(at(s, i)) << 24) |
         (static_cast<std::uint32_t>(at(s, i + 1)) << 16) |
         (static_cast<std::uint32_t>(at(s, i + 2)) << 8) |
         static_cast<std::uint32_t>(at(s, i + 3));
}

[[nodiscard]] std::uint64_t readU64(std::string_view s, std::size_t i) noexcept {
  return (static_cast<std::uint64_t>(readU32(s, i)) << 32) |
         static_cast<std::uint64_t>(readU32(s, i + 4));
}

struct Box {
  std::string_view type;
  std::size_t begin{0};  // first byte of the body
  std::size_t end{0};    // one past the last byte of the body
};

// Calls `fn(Box)` for each box directly inside [begin, end). Stops on the
// first malformed header rather than guessing.
template <typename Fn>
void forEachBox(std::string_view d, std::size_t begin, std::size_t end,
                Fn&& fn) {
  std::size_t offset = begin;
  while (offset + kBoxHeader <= end) {
    std::uint64_t size = readU32(d, offset);
    const std::string_view type = d.substr(offset + 4, 4);
    std::size_t header = kBoxHeader;
    if (size == 1) {
      if (offset + 16 > end) return;
      size = readU64(d, offset + 8);
      header = 16;
    } else if (size == 0) {
      size = end - offset;
    }
    if (size < header || offset + size > end) return;
    fn(Box{type, offset + header, offset + static_cast<std::size_t>(size)});
    offset += static_cast<std::size_t>(size);
  }
}

[[nodiscard]] bool findBox(std::string_view d, std::size_t begin,
                           std::size_t end, std::string_view type, Box* out) {
  bool found = false;
  forEachBox(d, begin, end, [&](const Box& box) {
    if (!found && box.type == type) {
      *out = box;
      found = true;
    }
  });
  return found;
}

// Descends a path of box types, e.g. {"mdia","minf","stbl","stsd"}.
[[nodiscard]] bool findPath(std::string_view d, Box scope,
                            std::initializer_list<std::string_view> path,
                            Box* out) {
  Box current = scope;
  for (const std::string_view type : path) {
    Box next;
    if (!findBox(d, current.begin, current.end, type, &next)) return false;
    current = next;
  }
  *out = current;
  return true;
}

struct SampleEntry {
  std::uint64_t offset{0};
  std::uint32_t size{0};
  std::uint64_t startTicks{0};
  std::uint32_t durationTicks{0};
};

// Expands stts/stsz/stsc/stco into a flat sample list.
[[nodiscard]] bool buildSampleTable(std::string_view d, Box stbl,
                                    std::vector<SampleEntry>* out,
                                    bool* truncated) {
  Box stts;
  Box stsz;
  Box stsc;
  Box stco;
  const bool haveStco = findBox(d, stbl.begin, stbl.end, "stco", &stco);
  const bool haveCo64 =
      !haveStco && findBox(d, stbl.begin, stbl.end, "co64", &stco);
  if (!findBox(d, stbl.begin, stbl.end, "stts", &stts) ||
      !findBox(d, stbl.begin, stbl.end, "stsz", &stsz) ||
      !findBox(d, stbl.begin, stbl.end, "stsc", &stsc) ||
      (!haveStco && !haveCo64)) {
    return false;
  }

  // Sizes.
  if (stsz.begin + 12 > stsz.end) return false;
  const std::uint32_t uniformSize = readU32(d, stsz.begin + 4);
  std::uint32_t sampleCount = readU32(d, stsz.begin + 8);
  if (sampleCount > kMaximumSubtitleSamples) {
    sampleCount = static_cast<std::uint32_t>(kMaximumSubtitleSamples);
    *truncated = true;
  }
  std::vector<std::uint32_t> sizes(sampleCount, uniformSize);
  if (uniformSize == 0) {
    if (stsz.begin + 12 + 4ULL * sampleCount > stsz.end) return false;
    for (std::uint32_t i = 0; i < sampleCount; ++i) {
      sizes[i] = readU32(d, stsz.begin + 12 + 4ULL * i);
    }
  }

  // Durations.
  if (stts.begin + 8 > stts.end) return false;
  const std::uint32_t sttsCount = readU32(d, stts.begin + 4);
  std::vector<std::uint32_t> durations;
  durations.reserve(sampleCount);
  for (std::uint32_t i = 0; i < sttsCount; ++i) {
    const std::size_t entry = stts.begin + 8 + 8ULL * i;
    if (entry + 8 > stts.end) break;
    const std::uint32_t count = readU32(d, entry);
    const std::uint32_t delta = readU32(d, entry + 4);
    for (std::uint32_t k = 0; k < count && durations.size() < sampleCount; ++k) {
      durations.push_back(delta);
    }
  }
  durations.resize(sampleCount, 0);

  // Chunk offsets.
  if (stco.begin + 8 > stco.end) return false;
  const std::uint32_t chunkCount = readU32(d, stco.begin + 4);
  std::vector<std::uint64_t> chunks;
  chunks.reserve(chunkCount);
  for (std::uint32_t i = 0; i < chunkCount; ++i) {
    const std::size_t entry = stco.begin + 8 + (haveCo64 ? 8ULL : 4ULL) * i;
    if (entry + (haveCo64 ? 8U : 4U) > stco.end) break;
    chunks.push_back(haveCo64 ? readU64(d, entry) : readU32(d, entry));
  }

  // Samples per chunk.
  if (stsc.begin + 8 > stsc.end) return false;
  const std::uint32_t stscCount = readU32(d, stsc.begin + 4);
  std::vector<std::uint32_t> perChunk(chunks.size(), 0);
  for (std::uint32_t i = 0; i < stscCount; ++i) {
    const std::size_t entry = stsc.begin + 8 + 12ULL * i;
    if (entry + 12 > stsc.end) break;
    const std::uint32_t firstChunk = readU32(d, entry);
    const std::uint32_t samples = readU32(d, entry + 4);
    std::uint32_t lastChunk = static_cast<std::uint32_t>(chunks.size());
    if (i + 1 < stscCount && entry + 24 <= stsc.end) {
      const std::uint32_t nextFirst = readU32(d, entry + 12);
      if (nextFirst >= 1) lastChunk = nextFirst - 1;
    }
    for (std::uint32_t c = firstChunk; c >= 1 && c <= lastChunk &&
                                       c <= chunks.size();
         ++c) {
      perChunk[c - 1] = samples;
    }
  }

  // Flatten.
  out->reserve(sampleCount);
  std::uint32_t sampleIndex = 0;
  std::uint64_t ticks = 0;
  for (std::size_t c = 0; c < chunks.size() && sampleIndex < sampleCount; ++c) {
    std::uint64_t offset = chunks[c];
    for (std::uint32_t k = 0; k < perChunk[c] && sampleIndex < sampleCount;
         ++k) {
      SampleEntry entry;
      entry.offset = offset;
      entry.size = sizes[sampleIndex];
      entry.startTicks = ticks;
      entry.durationTicks = durations[sampleIndex];
      out->push_back(entry);
      offset += sizes[sampleIndex];
      ticks += durations[sampleIndex];
      ++sampleIndex;
    }
  }
  return !out->empty();
}

[[nodiscard]] SubtitleTrackKind classifyTrack(std::string_view d, Box trak,
                                              std::string_view handler) {
  Box stsd;
  if (!findPath(d, trak, {"mdia", "minf", "stbl", "stsd"}, &stsd)) {
    return SubtitleTrackKind::Unknown;
  }
  // stsd: version/flags (4) + entry_count (4), then sample entries.
  if (stsd.begin + 8 + kBoxHeader > stsd.end) return SubtitleTrackKind::Unknown;
  const std::string_view format = d.substr(stsd.begin + 12, 4);
  if (handler == "sbtl" || handler == "text") {
    if (format == "tx3g" || format == "text") return SubtitleTrackKind::Tx3gText;
  }
  if (handler == "clcp") return SubtitleTrackKind::ClosedCaptionTrack;
  return SubtitleTrackKind::Unknown;
}

struct TrackTiming {
  std::uint32_t timescale{0};
  std::string language{"und"};
};

[[nodiscard]] bool readMdhd(std::string_view d, Box trak, TrackTiming* out) {
  Box mdhd;
  if (!findPath(d, trak, {"mdia", "mdhd"}, &mdhd)) return false;
  if (mdhd.begin + 4 > mdhd.end) return false;
  const unsigned char version = at(d, mdhd.begin);
  const std::size_t timescaleOffset = mdhd.begin + (version == 1 ? 20 : 12);
  const std::size_t languageOffset = mdhd.begin + (version == 1 ? 32 : 20);
  if (languageOffset + 2 > mdhd.end) return false;
  out->timescale = readU32(d, timescaleOffset);
  out->language = unpackIso639Language(readU16(d, languageOffset));
  return out->timescale != 0;
}

[[nodiscard]] std::uint32_t readTrackId(std::string_view d, Box trak,
                                        bool* enabled) {
  Box tkhd;
  if (!findBox(d, trak.begin, trak.end, "tkhd", &tkhd)) return 0;
  if (tkhd.begin + 4 > tkhd.end) return 0;
  const unsigned char version = at(d, tkhd.begin);
  *enabled = (readU32(d, tkhd.begin) & 0x1U) != 0;
  const std::size_t idOffset = tkhd.begin + (version == 1 ? 20 : 12);
  if (idOffset + 4 > tkhd.end) return 0;
  return readU32(d, idOffset);
}

[[nodiscard]] std::string readHandler(std::string_view d, Box trak) {
  Box hdlr;
  if (!findPath(d, trak, {"mdia", "hdlr"}, &hdlr)) return {};
  if (hdlr.begin + 12 > hdlr.end) return {};
  return std::string(d.substr(hdlr.begin + 8, 4));
}

[[nodiscard]] std::string readTrackName(std::string_view d, Box trak) {
  Box udta;
  if (!findBox(d, trak.begin, trak.end, "udta", &udta)) return {};
  Box name;
  if (!findBox(d, udta.begin, udta.end, "name", &name)) return {};
  if (name.end <= name.begin) return {};
  return subtitles::normalizeCueText(
      d.substr(name.begin, name.end - name.begin));
}

// Reads the whole moov box into `out`. Returns false when there is none, when
// it is larger than kMaximumMoovBytes, or when the file cannot be read.
[[nodiscard]] bool readMoov(const std::filesystem::path& path,
                            std::string* out) {
  std::ifstream file(path, std::ios::binary);
  if (!file) return false;
  file.seekg(0, std::ios::end);
  const auto fileSize = static_cast<std::uint64_t>(file.tellg());
  std::uint64_t offset = 0;
  while (offset + kBoxHeader <= fileSize) {
    char header[16];
    file.seekg(static_cast<std::streamoff>(offset));
    if (!file.read(header, kBoxHeader)) return false;
    const std::string_view view(header, kBoxHeader);
    std::uint64_t size = readU32(view, 0);
    const std::string_view type = view.substr(4, 4);
    std::uint64_t headerBytes = kBoxHeader;
    if (size == 1) {
      if (!file.read(header + kBoxHeader, 8)) return false;
      size = readU64(std::string_view(header, 16), 8);
      headerBytes = 16;
    } else if (size == 0) {
      size = fileSize - offset;
    }
    if (size < headerBytes || offset + size > fileSize) return false;
    if (type == "moov") {
      if (size > kMaximumMoovBytes) return false;
      out->assign(static_cast<std::size_t>(size), '\0');
      file.seekg(static_cast<std::streamoff>(offset));
      return static_cast<bool>(
          file.read(out->data(), static_cast<std::streamsize>(size)));
    }
    offset += size;
  }
  return false;
}

}  // namespace

std::string unpackIso639Language(std::uint16_t packed) {
  // Three 5-bit letters, each offset from 0x60. 0 is "undetermined".
  if (packed == 0 || (packed & 0x8000U) != 0) return "und";
  std::string out;
  for (int shift = 10; shift >= 0; shift -= 5) {
    const auto letter =
        static_cast<char>(((packed >> shift) & 0x1FU) + 0x60U);
    if (letter < 'a' || letter > 'z') return "und";
    out.push_back(letter);
  }
  return out;
}

SubtitleTrackInventory inspectMp4SubtitleTracksInMemory(
    std::string_view bytes) noexcept {
  SubtitleTrackInventory inventory;
  Box moov;
  // The caller may hand us either a whole file or the moov box alone.
  if (!findBox(bytes, 0, bytes.size(), "moov", &moov)) {
    moov = Box{"moov", 0, bytes.size()};
  }
  forEachBox(bytes, moov.begin, moov.end, [&](const Box& trak) {
    if (trak.type != "trak") return;
    const std::string handler = readHandler(bytes, trak);
    if (handler != "sbtl" && handler != "text" && handler != "clcp") return;
    const SubtitleTrackKind kind = classifyTrack(bytes, trak, handler);
    if (kind == SubtitleTrackKind::Unknown) return;
    SubtitleTrackInfo info;
    bool enabled = true;
    info.trackId = readTrackId(bytes, trak, &enabled);
    if (info.trackId == 0) return;
    info.kind = kind;
    info.enabled = enabled;
    TrackTiming timing;
    if (readMdhd(bytes, trak, &timing)) info.language = timing.language;
    info.name = readTrackName(bytes, trak);
    Box stsz;
    if (findPath(bytes, trak, {"mdia", "minf", "stbl", "stsz"}, &stsz) &&
        stsz.begin + 12 <= stsz.end) {
      info.sampleCount = readU32(bytes, stsz.begin + 8);
    }
    inventory.tracks.push_back(std::move(info));
  });
  inventory.valid = true;
  return inventory;
}

SubtitleTrackInventory inspectMp4SubtitleTracks(
    const std::filesystem::path& path) noexcept {
  std::string moov;
  if (!readMoov(path, &moov)) return {};
  return inspectMp4SubtitleTracksInMemory(moov);
}

SubtitleTrackLoad loadMp4SubtitleTrack(const std::filesystem::path& path,
                                       std::uint32_t trackId) noexcept {
  SubtitleTrackLoad load;
  std::string moov;
  if (!readMoov(path, &moov)) {
    load.error = "no readable moov box";
    return load;
  }
  const std::string_view d(moov);

  Box moovBox;
  if (!findBox(d, 0, d.size(), "moov", &moovBox)) {
    load.error = "no moov box";
    return load;
  }

  Box selected{};
  TrackTiming timing;
  bool found = false;
  forEachBox(d, moovBox.begin, moovBox.end, [&](const Box& trak) {
    if (found || trak.type != "trak") return;
    bool enabled = true;
    if (readTrackId(d, trak, &enabled) != trackId) return;
    if (!readMdhd(d, trak, &timing)) return;
    selected = trak;
    found = true;
  });
  if (!found) {
    load.error = "track not found";
    return load;
  }

  Box stbl;
  if (!findPath(d, selected, {"mdia", "minf", "stbl"}, &stbl)) {
    load.error = "track has no sample table";
    return load;
  }
  std::vector<SampleEntry> samples;
  if (!buildSampleTable(d, stbl, &samples, &load.truncated)) {
    load.error = "track sample table is unreadable";
    return load;
  }

  std::ifstream file(path, std::ios::binary);
  if (!file) {
    load.error = "file could not be reopened for sample reads";
    return load;
  }

  const auto toNanoseconds = [&timing](std::uint64_t ticks) -> std::int64_t {
    // Exact rational scaling; the 1e9 numerator and a 32-bit timescale cannot
    // overflow a signed 64-bit value for any duration a file can hold.
    return static_cast<std::int64_t>(ticks * 1'000'000'000ULL /
                                     timing.timescale);
  };

  std::size_t totalTextBytes = 0;
  std::string buffer;
  for (std::size_t i = 0; i < samples.size(); ++i) {
    const SampleEntry& entry = samples[i];
    if (entry.size == 0 || entry.size > kMaximumSubtitleSampleBytes) {
      ++load.skipped;
      continue;
    }
    buffer.assign(entry.size, '\0');
    file.seekg(static_cast<std::streamoff>(entry.offset));
    if (!file.read(buffer.data(), static_cast<std::streamsize>(entry.size))) {
      ++load.skipped;
      continue;
    }
    subtitles::Tx3gSample sample;
    if (!subtitles::decodeTx3gSample(buffer, &sample) || sample.clearsScreen ||
        sample.text.empty()) {
      // A zero-length sample is the format's "clear"; it produces no cue, and
      // the previous cue's end already stops at this sample's start.
      continue;
    }
    if (load.cues.size() >= subtitles::kMaximumCues ||
        totalTextBytes + sample.text.size() >
            subtitles::kMaximumTotalTextBytes) {
      load.truncated = true;
      break;
    }
    std::uint64_t endTicks = entry.startTicks + entry.durationTicks;
    if (i + 1 < samples.size()) {
      endTicks = std::min(endTicks, samples[i + 1].startTicks);
    }
    if (endTicks <= entry.startTicks) {
      ++load.skipped;
      continue;
    }
    subtitles::Cue cue;
    cue.startNanoseconds = toNanoseconds(entry.startTicks);
    cue.endNanoseconds = toNanoseconds(endTicks);
    totalTextBytes += sample.text.size();
    cue.text = std::move(sample.text);
    load.cues.push_back(std::move(cue));
    load.styles.push_back(std::move(sample.styles));
  }

  load.ok = true;
  return load;
}

}  // namespace wam::media::mp4
