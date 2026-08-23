#include "media/subtitle_text.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <charconv>

namespace wam::media::subtitles {
namespace {

constexpr std::int64_t kNanosecondsPerSecond{1'000'000'000};

[[nodiscard]] bool isSpace(char c) noexcept {
  return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' ||
         c == '\v';
}

[[nodiscard]] std::string_view trim(std::string_view value) noexcept {
  while (!value.empty() && isSpace(value.front()))
    value.remove_prefix(1);
  while (!value.empty() && isSpace(value.back()))
    value.remove_suffix(1);
  return value;
}

// A continuation byte is 10xxxxxx; a truncation point must not land on one.
[[nodiscard]] bool isUtf8Continuation(char c) noexcept {
  return (static_cast<unsigned char>(c) & 0xC0U) == 0x80U;
}

[[nodiscard]] std::size_t utf8SafeLength(std::string_view text,
                                         std::size_t limit) noexcept {
  if (text.size() <= limit)
    return text.size();
  std::size_t cut = limit;
  while (cut > 0 && isUtf8Continuation(text[cut]))
    --cut;
  return cut;
}

// Reads the next line and advances `rest` past its terminator. Returns false
// only when `rest` is exhausted.
bool nextLine(std::string_view* rest, std::string_view* line) noexcept {
  if (rest->empty())
    return false;
  const std::size_t breakAt = rest->find('\n');
  if (breakAt == std::string_view::npos) {
    *line = *rest;
    *rest = {};
  } else {
    *line = rest->substr(0, breakAt);
    rest->remove_prefix(breakAt + 1);
  }
  if (!line->empty() && line->back() == '\r')
    line->remove_suffix(1);
  return true;
}

[[nodiscard]] bool parseUnsigned(std::string_view text,
                                 std::uint64_t* value) noexcept {
  if (text.empty())
    return false;
  const char* first = text.data();
  const char* last = first + text.size();
  const auto result = std::from_chars(first, last, *value);
  return result.ec == std::errc{} && result.ptr == last;
}

// "hh:mm:ss,mmm" / "hh:mm:ss.mmm" / "h:mm:ss.cc" (ASS centiseconds) /
// "mm:ss.mmm" (WebVTT short form). Returns nanoseconds.
[[nodiscard]] bool parseTimestamp(std::string_view text,
                                  std::int64_t* nanoseconds) noexcept {
  text = trim(text);
  if (text.empty())
    return false;

  // Split off the fraction first, so the colon walk below is unambiguous.
  std::string_view fraction;
  const std::size_t dot = text.find_last_of(".,");
  if (dot != std::string_view::npos) {
    fraction = text.substr(dot + 1);
    text = text.substr(0, dot);
  }

  std::array<std::uint64_t, 3> parts{};
  std::size_t partCount = 0;
  while (!text.empty()) {
    const std::size_t colon = text.find(':');
    const std::string_view field =
        colon == std::string_view::npos ? text : text.substr(0, colon);
    if (partCount >= parts.size())
      return false;
    if (!parseUnsigned(trim(field), &parts[partCount]))
      return false;
    ++partCount;
    if (colon == std::string_view::npos)
      break;
    text.remove_prefix(colon + 1);
    // A trailing colon is malformed rather than an implicit zero.
    if (text.empty())
      return false;
  }
  if (partCount == 0)
    return false;

  std::uint64_t hours = 0;
  std::uint64_t minutes = 0;
  std::uint64_t seconds = 0;
  if (partCount == 3) {
    hours = parts[0];
    minutes = parts[1];
    seconds = parts[2];
  } else if (partCount == 2) {
    minutes = parts[0];
    seconds = parts[1];
  } else {
    seconds = parts[0];
  }
  // Guard the multiply rather than trusting a well-formed file. 10^6 hours is
  // far past any real medium and keeps the arithmetic inside int64.
  if (hours > 1'000'000 || minutes > 59'999 || seconds > 59'999)
    return false;

  std::int64_t total =
      static_cast<std::int64_t>(hours * 3600 + minutes * 60 + seconds) *
      kNanosecondsPerSecond;

  if (!fraction.empty()) {
    // Digits only; scale by position so ".5", ".50", ".500" and ASS's ".05"
    // centiseconds all mean what they say.
    std::uint64_t scaled = 0;
    std::size_t digits = 0;
    for (const char c : fraction) {
      if (c < '0' || c > '9')
        return false;
      if (digits < 9) {
        scaled = scaled * 10 + static_cast<std::uint64_t>(c - '0');
        ++digits;
      }
    }
    std::int64_t nanos = static_cast<std::int64_t>(scaled);
    for (std::size_t i = digits; i < 9; ++i)
      nanos *= 10;
    total += nanos;
  }
  *nanoseconds = total;
  return true;
}

void appendCue(ParsedFile* out, std::int64_t start, std::int64_t end,
               std::string text) {
  if (text.empty() || end <= start)
    return;
  if (out->cues.size() >= kMaximumCues) {
    out->truncated = true;
    return;
  }
  out->cues.push_back(Cue{start, end, std::move(text)});
}

// Joins the payload lines of one cue block with '\n'.
[[nodiscard]] std::string joinLines(const std::vector<std::string_view>& lines) {
  std::string joined;
  std::size_t needed = 0;
  for (const std::string_view line : lines)
    needed += line.size() + 1;
  joined.reserve(needed);
  for (const std::string_view line : lines) {
    if (!joined.empty())
      joined.push_back('\n');
    joined.append(line);
  }
  return joined;
}

// "a --> b" with either arrow spacing, plus anything trailing (WebVTT cue
// settings, SRT position coordinates), which is ignored.
[[nodiscard]] bool parseTimingLine(std::string_view line, std::int64_t* start,
                                   std::int64_t* end) noexcept {
  const std::size_t arrow = line.find("-->");
  if (arrow == std::string_view::npos)
    return false;
  const std::string_view left = line.substr(0, arrow);
  std::string_view right = line.substr(arrow + 3);
  // Trailing settings are separated by whitespace from the end timestamp.
  const std::string_view trimmedRight = trim(right);
  const std::size_t space = trimmedRight.find_first_of(" \t");
  if (space != std::string_view::npos)
    right = trimmedRight.substr(0, space);
  else
    right = trimmedRight;
  return parseTimestamp(left, start) && parseTimestamp(right, end);
}

// Shared body for SubRip and WebVTT: both are blank-line-separated blocks
// whose timing line contains "-->".
[[nodiscard]] ParsedFile parseCueBlocks(std::string_view bytes,
                                        bool webVtt) {
  ParsedFile out;
  std::string_view rest = bytes;
  // Strip a UTF-8 BOM once, at the file level.
  if (rest.size() >= 3 && static_cast<unsigned char>(rest[0]) == 0xEF &&
      static_cast<unsigned char>(rest[1]) == 0xBB &&
      static_cast<unsigned char>(rest[2]) == 0xBF) {
    rest.remove_prefix(3);
  }

  std::size_t totalText = 0;
  std::vector<std::string_view> payload;
  std::string_view line;
  bool seenAnyTiming = false;

  while (nextLine(&rest, &line)) {
    const std::string_view trimmed = trim(line);
    if (trimmed.empty())
      continue;
    // WebVTT headers, NOTE/STYLE/REGION blocks and SRT cue numbers all land
    // here; only a line containing the arrow starts a cue.
    std::int64_t start = 0;
    std::int64_t end = 0;
    if (!parseTimingLine(trimmed, &start, &end)) {
      if (webVtt && (trimmed.starts_with("NOTE") ||
                     trimmed.starts_with("STYLE") ||
                     trimmed.starts_with("REGION"))) {
        // Skip to the next blank line so a NOTE's body is never mistaken for
        // a cue payload.
        while (nextLine(&rest, &line) && !trim(line).empty()) {
        }
      }
      continue;
    }
    seenAnyTiming = true;

    payload.clear();
    while (nextLine(&rest, &line)) {
      if (trim(line).empty())
        break;
      // A new timing line without an intervening blank line means the
      // previous cue's payload ended; put it back by handling it next round.
      payload.push_back(line);
    }
    std::string text = webVtt ? renderWebVttPayload(joinLines(payload))
                              : normalizeCueText(joinLines(payload));
    totalText += text.size();
    if (totalText > kMaximumTotalTextBytes) {
      out.truncated = true;
      break;
    }
    appendCue(&out, start, end, std::move(text));
    if (out.truncated)
      break;
  }

  if (!seenAnyTiming && out.cues.empty())
    out.error = "no subtitle cues were found";
  return out;
}

}  // namespace

TextCodec textCodecFromMatroskaCodecId(std::string_view codecId) noexcept {
  if (codecId == "S_TEXT/UTF8")
    return TextCodec::SubRip;
  if (codecId == "S_TEXT/ASS")
    return TextCodec::Ass;
  if (codecId == "S_TEXT/SSA")
    return TextCodec::Ssa;
  if (codecId == "S_TEXT/WEBVTT")
    return TextCodec::WebVtt;
  // WebM does not use the S_ namespace for WebVTT. Its four flavours are
  // D_WEBVTT/{SUBTITLES,CAPTIONS,DESCRIPTIONS,METADATA}; the first two are
  // displayable text, the last two are not meant to be drawn over the picture.
  if (codecId == "D_WEBVTT/SUBTITLES" || codecId == "D_WEBVTT/CAPTIONS")
    return TextCodec::WebVtt;
  return TextCodec::Unknown;
}

std::string normalizeCueText(std::string_view text) {
  std::string out;
  out.reserve(text.size());
  for (std::size_t i = 0; i < text.size(); ++i) {
    const char c = text[i];
    if (c == '\r') {
      // CRLF collapses to one break; a lone CR is still a break.
      if (i + 1 < text.size() && text[i + 1] == '\n')
        continue;
      out.push_back('\n');
      continue;
    }
    out.push_back(c);
  }
  std::string_view view(out);
  if (view.size() >= 3 && static_cast<unsigned char>(view[0]) == 0xEF &&
      static_cast<unsigned char>(view[1]) == 0xBB &&
      static_cast<unsigned char>(view[2]) == 0xBF) {
    view.remove_prefix(3);
  }
  view = trim(view);
  view = view.substr(0, utf8SafeLength(view, kMaximumCueTextBytes));
  return std::string(view);
}

std::string stripAssOverrideTags(std::string_view text) {
  std::string out;
  out.reserve(text.size());
  std::size_t depth = 0;
  for (std::size_t i = 0; i < text.size(); ++i) {
    const char c = text[i];
    if (c == '{') {
      ++depth;
      continue;
    }
    if (c == '}') {
      if (depth > 0)
        --depth;
      continue;
    }
    if (depth > 0)
      continue;
    if (c == '\\' && i + 1 < text.size()) {
      const char next = text[i + 1];
      // ASS escapes: \N is a hard break, \n a soft one (a renderer may wrap
      // there; with no wrapping engine, treating it as a break is the honest
      // reading), \h a non-breaking space.
      if (next == 'N' || next == 'n') {
        out.push_back('\n');
        ++i;
        continue;
      }
      if (next == 'h') {
        out.push_back(' ');
        ++i;
        continue;
      }
    }
    out.push_back(c);
  }
  return out;
}

std::string renderAssDialoguePayload(std::string_view payload) {
  // Skip the 8 leading comma-separated fields. The 9th field is the text and
  // may contain commas of its own, so this counts separators instead of
  // splitting.
  constexpr int kLeadingFields = 8;
  std::size_t offset = 0;
  int commas = 0;
  for (; offset < payload.size() && commas < kLeadingFields; ++offset) {
    if (payload[offset] == ',')
      ++commas;
  }
  // Fewer than 8 commas means this is not a Matroska ASS field list; treat the
  // whole payload as text rather than throwing a line away.
  const std::string_view text =
      commas == kLeadingFields ? payload.substr(offset) : payload;
  return normalizeCueText(stripAssOverrideTags(text));
}

std::string renderWebVttPayload(std::string_view payload) {
  std::string out;
  out.reserve(payload.size());
  bool inTag = false;
  for (const char c : payload) {
    if (c == '<') {
      inTag = true;
      continue;
    }
    if (c == '>') {
      inTag = false;
      continue;
    }
    if (!inTag)
      out.push_back(c);
  }
  return normalizeCueText(out);
}

std::string renderBlockPayload(TextCodec codec, std::string_view payload) {
  switch (codec) {
    case TextCodec::Ass:
    case TextCodec::Ssa:
      return renderAssDialoguePayload(payload);
    case TextCodec::WebVtt:
      return renderWebVttPayload(payload);
    case TextCodec::SubRip:
      return normalizeCueText(payload);
    case TextCodec::Unknown:
      break;
  }
  return {};
}

ParsedFile parseSubRip(std::string_view bytes) {
  return parseCueBlocks(bytes, false);
}

ParsedFile parseWebVtt(std::string_view bytes) {
  return parseCueBlocks(bytes, true);
}

ParsedFile parseAss(std::string_view bytes) {
  ParsedFile out;
  std::string_view rest = bytes;
  std::string_view line;
  bool inEvents = false;
  // Defaults matching the near-universal V4+ Format line, used only if a
  // [Events] section omits its own Format:.
  int startField = 1;
  int endField = 2;
  int textField = 9;
  int fieldCount = 10;
  std::size_t totalText = 0;

  while (nextLine(&rest, &line)) {
    const std::string_view trimmed = trim(line);
    if (trimmed.empty())
      continue;
    if (trimmed.front() == '[') {
      inEvents = trimmed.size() >= 8 &&
                 (trimmed.substr(0, 8) == "[Events]" ||
                  trimmed.substr(0, 8) == "[events]");
      continue;
    }
    if (!inEvents)
      continue;

    if (trimmed.starts_with("Format:")) {
      std::string_view fields = trimmed.substr(7);
      int index = 0;
      startField = endField = textField = -1;
      while (!fields.empty()) {
        const std::size_t comma = fields.find(',');
        const std::string_view name =
            trim(comma == std::string_view::npos ? fields
                                                 : fields.substr(0, comma));
        if (name == "Start")
          startField = index;
        else if (name == "End")
          endField = index;
        else if (name == "Text")
          textField = index;
        ++index;
        if (comma == std::string_view::npos)
          break;
        fields.remove_prefix(comma + 1);
      }
      fieldCount = index;
      continue;
    }
    if (!trimmed.starts_with("Dialogue:"))
      continue;
    if (startField < 0 || endField < 0 || textField < 0) {
      out.error = "the [Events] Format line is missing Start, End or Text";
      continue;
    }

    std::string_view body = trimmed.substr(9);
    // Walk to each wanted field. Text is last by definition of the format, so
    // once its index is reached the remainder (commas included) is the text.
    std::string_view startText;
    std::string_view endText;
    std::string_view text;
    int index = 0;
    while (true) {
      const bool isLast = index == fieldCount - 1 || index == textField;
      std::string_view field;
      if (isLast) {
        field = body;
        body = {};
      } else {
        const std::size_t comma = body.find(',');
        if (comma == std::string_view::npos) {
          field = body;
          body = {};
        } else {
          field = body.substr(0, comma);
          body.remove_prefix(comma + 1);
        }
      }
      if (index == startField)
        startText = field;
      if (index == endField)
        endText = field;
      if (index == textField)
        text = field;
      if (isLast || body.empty())
        break;
      ++index;
    }

    std::int64_t start = 0;
    std::int64_t end = 0;
    if (!parseTimestamp(startText, &start) || !parseTimestamp(endText, &end))
      continue;
    std::string rendered = normalizeCueText(stripAssOverrideTags(text));
    totalText += rendered.size();
    if (totalText > kMaximumTotalTextBytes) {
      out.truncated = true;
      break;
    }
    appendCue(&out, start, end, std::move(rendered));
    if (out.truncated)
      break;
  }

  if (out.cues.empty() && out.error.empty())
    out.error = "no subtitle cues were found";
  return out;
}

ParsedFile parseSubtitleFile(std::string_view bytes,
                             std::string_view extensionHint) {
  std::string_view head = bytes.substr(0, std::min<std::size_t>(64, bytes.size()));
  if (head.size() >= 3 && static_cast<unsigned char>(head[0]) == 0xEF &&
      static_cast<unsigned char>(head[1]) == 0xBB &&
      static_cast<unsigned char>(head[2]) == 0xBF) {
    head.remove_prefix(3);
  }
  // Content sniffing first: an .srt file holding ASS is far more common than a
  // correct extension on a wrong file.
  if (head.starts_with("WEBVTT"))
    return parseWebVtt(bytes);
  if (head.find("[Script Info]") != std::string_view::npos)
    return parseAss(bytes);

  std::string extension;
  extension.reserve(extensionHint.size());
  for (const char c : extensionHint) {
    extension.push_back(
        static_cast<char>(std::tolower(static_cast<unsigned char>(c))));
  }
  if (extension == "ass" || extension == "ssa" || extension == ".ass" ||
      extension == ".ssa") {
    return parseAss(bytes);
  }
  if (extension == "vtt" || extension == ".vtt")
    return parseWebVtt(bytes);
  return parseSubRip(bytes);
}

void finalizeCues(std::vector<Cue>* cues, bool clampOverlaps) {
  if (cues == nullptr)
    return;
  std::stable_sort(cues->begin(), cues->end(),
                   [](const Cue& a, const Cue& b) noexcept {
                     return a.startNanoseconds < b.startNanoseconds;
                   });
  cues->erase(std::remove_if(cues->begin(), cues->end(),
                             [](const Cue& cue) noexcept {
                               return cue.text.empty() ||
                                      cue.endNanoseconds <= cue.startNanoseconds;
                             }),
              cues->end());
  if (!clampOverlaps)
    return;
  for (std::size_t i = 0; i + 1 < cues->size(); ++i) {
    Cue& cue = (*cues)[i];
    const std::int64_t nextStart = (*cues)[i + 1].startNanoseconds;
    if (cue.endNanoseconds > nextStart && nextStart > cue.startNanoseconds)
      cue.endNanoseconds = nextStart;
  }
}

std::ptrdiff_t cueIndexAt(const std::vector<Cue>& cues, std::int64_t t,
                          std::ptrdiff_t hint) noexcept {
  const std::ptrdiff_t count = static_cast<std::ptrdiff_t>(cues.size());
  if (count == 0)
    return -1;
  // Sequential playback: the hint is either still current or the next cue.
  if (hint >= 0 && hint < count && cues[static_cast<std::size_t>(hint)].covers(t))
    return hint;

  // Last cue starting at or before t, then a coverage check. Overlapping cues
  // resolve to the latest one that starts in time, which is what a reader
  // expects when two lines share a moment.
  const auto upper = std::upper_bound(
      cues.begin(), cues.end(), t,
      [](std::int64_t value, const Cue& cue) noexcept {
        return value < cue.startNanoseconds;
      });
  if (upper == cues.begin())
    return -1;
  std::ptrdiff_t index = (upper - cues.begin()) - 1;
  // Walk back over cues that already ended, bounded by a small window so a
  // pathological stack of expired overlaps cannot make this a linear scan.
  constexpr std::ptrdiff_t kOverlapWindow = 8;
  for (std::ptrdiff_t step = 0; step < kOverlapWindow && index >= 0;
       ++step, --index) {
    if (cues[static_cast<std::size_t>(index)].covers(t))
      return index;
  }
  return -1;
}

}  // namespace wam::media::subtitles
