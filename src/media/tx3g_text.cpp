#include "media/tx3g_text.hpp"

#include <algorithm>
#include <cstring>

#include "media/subtitle_text.hpp"

namespace wam::media::subtitles {
namespace {

constexpr std::size_t kBoxHeaderBytes{8};
constexpr std::size_t kStyleRecordBytes{12};

[[nodiscard]] std::uint16_t readU16(const unsigned char* p) noexcept {
  return static_cast<std::uint16_t>((static_cast<std::uint16_t>(p[0]) << 8) |
                                    static_cast<std::uint16_t>(p[1]));
}

[[nodiscard]] std::uint32_t readU32(const unsigned char* p) noexcept {
  return (static_cast<std::uint32_t>(p[0]) << 24) |
         (static_cast<std::uint32_t>(p[1]) << 16) |
         (static_cast<std::uint32_t>(p[2]) << 8) |
         static_cast<std::uint32_t>(p[3]);
}

// Number of UTF-16 code units the UTF-8 sequence starting at `i` contributes,
// and how many bytes it occupies. An invalid lead byte is treated as one
// single-unit byte so a malformed payload still advances.
struct Utf8Step {
  std::size_t bytes{1};
  std::size_t units{1};
};

[[nodiscard]] Utf8Step utf8Step(std::string_view text, std::size_t i) noexcept {
  const auto lead = static_cast<unsigned char>(text[i]);
  if (lead < 0x80U) return {1, 1};
  if ((lead & 0xE0U) == 0xC0U && i + 1 < text.size()) return {2, 1};
  if ((lead & 0xF0U) == 0xE0U && i + 2 < text.size()) return {3, 1};
  // Astral planes are one UTF-8 4-byte sequence but TWO UTF-16 code units;
  // getting this wrong is what shifts every style span in an emoji subtitle.
  if ((lead & 0xF8U) == 0xF0U && i + 3 < text.size()) return {4, 2};
  return {1, 1};
}

// Maps each UTF-16 code-unit offset to a UTF-8 byte offset. Index `n` in the
// returned table is the byte offset of code unit `n`; the table has one extra
// trailing entry equal to text.size() so an end offset always resolves.
[[nodiscard]] std::vector<std::size_t> utf16ToUtf8Table(std::string_view text) {
  std::vector<std::size_t> table;
  table.reserve(text.size() + 1);
  std::size_t i = 0;
  while (i < text.size()) {
    const Utf8Step step = utf8Step(text, i);
    for (std::size_t u = 0; u < step.units; ++u) table.push_back(i);
    i += step.bytes;
  }
  table.push_back(text.size());
  return table;
}

void appendSpan(std::vector<Tx3gStyleSpan>* spans, Tx3gStyleSpan span) {
  if (span.plain() || span.startByte >= span.endByte) return;
  spans->push_back(span);
}

}  // namespace

std::vector<Tx3gStyleSpan> convertStyleRangesToUtf8(
    std::string_view text, const std::vector<Tx3gStyleRecord>& records,
    bool* malformed) {
  std::vector<Tx3gStyleSpan> spans;
  if (records.empty()) return spans;
  const std::vector<std::size_t> table = utf16ToUtf8Table(text);
  const auto lastUnit = table.size() - 1;

  spans.reserve(records.size());
  for (const Tx3gStyleRecord& record : records) {
    std::size_t startUnit = record.startChar;
    std::size_t endUnit = record.endChar;
    if (startUnit > lastUnit || endUnit > lastUnit) {
      if (malformed != nullptr) *malformed = true;
      startUnit = std::min(startUnit, lastUnit);
      endUnit = std::min(endUnit, lastUnit);
    }
    if (startUnit >= endUnit) continue;
    Tx3gStyleSpan span;
    span.startByte = table[startUnit];
    span.endByte = table[endUnit];
    span.bold = record.bold();
    span.italic = record.italic();
    span.underline = record.underline();
    appendSpan(&spans, span);
  }

  std::stable_sort(spans.begin(), spans.end(),
                   [](const Tx3gStyleSpan& a, const Tx3gStyleSpan& b) {
                     return a.startByte < b.startByte;
                   });
  // Overlapping records are legal in the format but meaningless to a plain
  // span list; the later record's start truncates the earlier one's end.
  for (std::size_t i = 0; i + 1 < spans.size(); ++i) {
    spans[i].endByte = std::min(spans[i].endByte, spans[i + 1].startByte);
  }
  spans.erase(std::remove_if(spans.begin(), spans.end(),
                             [](const Tx3gStyleSpan& s) {
                               return s.startByte >= s.endByte;
                             }),
              spans.end());
  return spans;
}

namespace {

// Reads the style records out of one 'styl' box body.
void parseStylBody(std::string_view body, std::vector<Tx3gStyleRecord>* records,
                   bool* malformed) {
  if (body.size() < 2) {
    *malformed = true;
    return;
  }
  const auto* p = reinterpret_cast<const unsigned char*>(body.data());
  std::size_t count = readU16(p);
  std::size_t offset = 2;
  if (count > kMaximumStyleRecords) {
    count = kMaximumStyleRecords;
    *malformed = true;
  }
  for (std::size_t i = 0; i < count; ++i) {
    if (offset + kStyleRecordBytes > body.size()) {
      *malformed = true;
      return;
    }
    const unsigned char* r = p + offset;
    Tx3gStyleRecord record;
    record.startChar = readU16(r);
    record.endChar = readU16(r + 2);
    record.fontId = readU16(r + 4);
    record.faceStyleFlags = r[6];
    record.fontSize = r[7];
    record.textColorRgba = readU32(r + 8);
    records->push_back(record);
    offset += kStyleRecordBytes;
  }
}

}  // namespace

bool decodeTx3gSample(std::string_view sample, Tx3gSample* out) {
  if (out == nullptr) return false;
  *out = Tx3gSample{};
  if (sample.size() < 2) return false;

  const auto* base = reinterpret_cast<const unsigned char*>(sample.data());
  const std::size_t textLength = readU16(base);
  if (textLength == 0) {
    out->clearsScreen = true;
    // A zero-length sample may still carry boxes; nothing in them can put text
    // on screen, so they are not read.
    return true;
  }
  if (2 + textLength > sample.size()) {
    // Truncated payload: show what is there rather than nothing.
    out->text = normalizeCueText(sample.substr(2));
    out->malformed = true;
    return true;
  }

  const std::string_view rawText = sample.substr(2, textLength);
  out->text = normalizeCueText(rawText);

  std::vector<Tx3gStyleRecord> records;
  std::size_t offset = 2 + textLength;
  while (offset + kBoxHeaderBytes <= sample.size()) {
    const auto* box = base + offset;
    const std::uint32_t boxSize = readU32(box);
    if (boxSize < kBoxHeaderBytes ||
        offset + static_cast<std::size_t>(boxSize) > sample.size()) {
      out->malformed = true;
      break;
    }
    if (std::memcmp(box + 4, "styl", 4) == 0) {
      parseStylBody(sample.substr(offset + kBoxHeaderBytes,
                                  boxSize - kBoxHeaderBytes),
                    &records, &out->malformed);
    }
    offset += boxSize;
  }

  // Style offsets index the RAW sample text. normalizeCueText can shorten it
  // (BOM removal, CR stripping, the byte cap), so spans are computed against
  // the raw text and then dropped if normalization moved past them.
  bool spanMalformed = false;
  std::vector<Tx3gStyleSpan> spans =
      convertStyleRangesToUtf8(rawText, records, &spanMalformed);
  if (spanMalformed) out->malformed = true;
  if (out->text.size() != rawText.size()) {
    spans.erase(std::remove_if(spans.begin(), spans.end(),
                               [&out](const Tx3gStyleSpan& s) {
                                 return s.endByte > out->text.size();
                               }),
                spans.end());
  }
  out->styles = std::move(spans);
  return true;
}

}  // namespace wam::media::subtitles
