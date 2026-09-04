#include "media/cea608_decoder.hpp"

#include <algorithm>

namespace wam::media::captions {
namespace {

constexpr char32_t kBlank{U' '};

[[nodiscard]] bool hasOddParity(std::uint8_t byte) noexcept {
  std::uint8_t v = byte;
  v ^= static_cast<std::uint8_t>(v >> 4);
  v ^= static_cast<std::uint8_t>(v >> 2);
  v ^= static_cast<std::uint8_t>(v >> 1);
  return (v & 1U) != 0U;
}

void appendUtf8(std::string* out, char32_t c) {
  if (c < 0x80) {
    out->push_back(static_cast<char>(c));
  } else if (c < 0x800) {
    out->push_back(static_cast<char>(0xC0U | (c >> 6)));
    out->push_back(static_cast<char>(0x80U | (c & 0x3FU)));
  } else {
    out->push_back(static_cast<char>(0xE0U | (c >> 12)));
    out->push_back(static_cast<char>(0x80U | ((c >> 6) & 0x3FU)));
    out->push_back(static_cast<char>(0x80U | (c & 0x3FU)));
  }
}

// PAC row table, indexed by (b1 & 0x07) then by whether b2 >= 0x60. Rows are
// 1-based as the specification numbers them; 0 means "not a row-bearing b1".
constexpr std::array<std::array<std::uint8_t, 2>, 8> kPacRows{{
    /* 0x10 */ {{11, 0}},
    /* 0x11 */ {{1, 2}},
    /* 0x12 */ {{3, 4}},
    /* 0x13 */ {{12, 13}},
    /* 0x14 */ {{14, 15}},
    /* 0x15 */ {{5, 6}},
    /* 0x16 */ {{7, 8}},
    /* 0x17 */ {{9, 10}},
}};

// Special characters: 0x11 with b2 in 0x30..0x3F.
constexpr std::array<char32_t, 16> kSpecialCharacters{
    U'®', U'°', U'½', U'¿', U'™', U'¢', U'£', U'♪',
    U'à', U' ', U'è', U'â', U'ê', U'î', U'ô', U'û'};

// Extended Spanish/French: 0x12 with b2 in 0x20..0x3F.
constexpr std::array<char32_t, 32> kExtendedLatin1{
    U'Á', U'É', U'Ó', U'Ú', U'Ü', U'ü', U'\'', U'¡',
    U'*', U'\'', U'—', U'©', U'℠', U'•', U'“', U'”',
    U'À', U'Â', U'Ç', U'È', U'Ê', U'Ë', U'ë', U'Î',
    U'Ï', U'ï', U'Ô', U'Ù', U'ù', U'Û', U'«', U'»'};

// Extended Portuguese/German/Danish: 0x13 with b2 in 0x20..0x3F.
constexpr std::array<char32_t, 32> kExtendedLatin2{
    U'Ã', U'ã', U'Í', U'Ì', U'ì', U'Ò', U'ò', U'Õ',
    U'õ', U'{', U'}', U'\\', U'^', U'_', U'|', U'~',
    U'Ä', U'ä', U'Ö', U'ö', U'ß', U'¥', U'¤', U'|',
    U'Å', U'å', U'Ø', U'ø', U'┌', U'┐', U'└', U'┘'};

}  // namespace

char32_t cea608BasicCharacter(std::uint8_t byte) noexcept {
  switch (byte) {
    case 0x2A: return U'á';
    case 0x5C: return U'é';
    case 0x5E: return U'í';
    case 0x5F: return U'ó';
    case 0x60: return U'ú';
    case 0x7B: return U'ç';
    case 0x7C: return U'÷';
    case 0x7D: return U'Ñ';
    case 0x7E: return U'ñ';
    case 0x7F: return U'█';
    default: return static_cast<char32_t>(byte);
  }
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

void Cea608Decoder::Screen::clear() noexcept {
  for (auto& row : cells) row.fill(kBlank);
}

void Cea608Decoder::Screen::clearRow(std::size_t row) noexcept {
  if (row < kCaptionRows) cells[row].fill(kBlank);
}

bool Cea608Decoder::Screen::empty() const noexcept {
  for (const auto& row : cells) {
    for (const char32_t c : row) {
      if (c != kBlank && c != 0) return false;
    }
  }
  return true;
}

std::string Cea608Decoder::Screen::render(std::uint8_t* topRow) const {
  std::string out;
  std::uint8_t top = 0;
  for (std::size_t r = 0; r < kCaptionRows; ++r) {
    std::string line;
    for (const char32_t c : cells[r]) {
      appendUtf8(&line, (c == 0) ? kBlank : c);
    }
    while (!line.empty() && line.back() == ' ') line.pop_back();
    const std::size_t firstNonBlank = line.find_first_not_of(' ');
    if (firstNonBlank == std::string::npos) {
      if (!out.empty()) out.push_back('\n');
      continue;
    }
    if (top == 0) top = static_cast<std::uint8_t>(r + 1);
    if (!out.empty()) out.push_back('\n');
    // Leading blanks are the caption's horizontal placement, which v1 does not
    // honour; they are trimmed so the overlay can centre the line itself.
    out.append(line, firstNonBlank, std::string::npos);
  }
  while (!out.empty() && (out.back() == '\n' || out.back() == ' ')) out.pop_back();
  // A screen of only blank rows renders as nothing at all.
  if (out.find_first_not_of('\n') == std::string::npos) out.clear();
  if (topRow != nullptr) *topRow = out.empty() ? 0 : top;
  return out;
}

// ---------------------------------------------------------------------------
// Decoder
// ---------------------------------------------------------------------------

void Cea608Decoder::reset() {
  displayed_.clear();
  nonDisplayed_.clear();
  mode_ = Cea608Mode::None;
  row_ = kCaptionRows - 1;
  column_ = 0;
  rollUpRows_ = 2;
  underline_ = false;
  italic_ = false;
  channelSelectsSecond_ = false;
  lastControl_ = 0xFFFF;
  lastPublished_.clear();
  updates_.clear();
}

std::vector<Cea608Update> Cea608Decoder::takeUpdates() {
  std::vector<Cea608Update> out;
  out.swap(updates_);
  return out;
}

void Cea608Decoder::feedPicture(std::int64_t timeNanoseconds,
                                const std::vector<CcTriplet>& triplets) {
  for (const CcTriplet& triplet : triplets) feed(timeNanoseconds, triplet);
}

void Cea608Decoder::feed(std::int64_t timeNanoseconds,
                         const CcTriplet& triplet) {
  if (!triplet.valid) return;
  const bool wantsFieldTwo =
      channel_ == Cea608Channel::Cc3 || channel_ == Cea608Channel::Cc4;
  const bool isFieldTwo = triplet.type == CcType::Ntsc608Field2;
  if (triplet.type != CcType::Ntsc608Field1 && !isFieldTwo) return;
  if (isFieldTwo != wantsFieldTwo) return;

  // Parity is odd over the low seven bits. A byte that fails it was corrupted
  // in transmission; a real decoder shows a solid block, but discarding the
  // pair keeps a synthesized-specimen mismatch from looking like caption text.
  if (!hasOddParity(triplet.data1) || !hasOddParity(triplet.data2)) {
    if (triplet.data1 != 0 || triplet.data2 != 0) ++parityErrors_;
    return;
  }

  const auto b1 = static_cast<std::uint8_t>(triplet.data1 & 0x7FU);
  const auto b2 = static_cast<std::uint8_t>(triplet.data2 & 0x7FU);
  if (b1 == 0 && b2 == 0) {
    lastControl_ = 0xFFFF;  // padding breaks a doubled-control pair
    return;
  }

  if (b1 >= 0x10 && b1 <= 0x1F) {
    handleControl(timeNanoseconds, b1, b2);
    return;
  }

  lastControl_ = 0xFFFF;
  if (channelSelectsSecond_ != (channel_ == Cea608Channel::Cc2 ||
                                channel_ == Cea608Channel::Cc4)) {
    return;  // text belonging to the other channel on this field
  }
  sawCaptions_ = true;
  if (b1 >= 0x20) putCharacter(cea608BasicCharacter(b1));
  if (b2 >= 0x20) putCharacter(cea608BasicCharacter(b2));
  publish(timeNanoseconds);
}

void Cea608Decoder::handleControl(std::int64_t t, std::uint8_t b1,
                                  std::uint8_t b2) {
  // Control codes are transmitted twice so a single-byte error cannot lose
  // one. The second copy must be ignored, or every caption is doubled.
  const auto code = static_cast<std::uint16_t>((b1 << 8) | b2);
  if (code == lastControl_) {
    lastControl_ = 0xFFFF;
    return;
  }
  lastControl_ = code;

  // Bit 3 of b1 selects the channel within the field.
  channelSelectsSecond_ = (b1 & 0x08U) != 0;
  const bool wantsSecond =
      channel_ == Cea608Channel::Cc2 || channel_ == Cea608Channel::Cc4;
  if (channelSelectsSecond_ != wantsSecond) return;

  const auto base = static_cast<std::uint8_t>(b1 & 0xF7U);  // clear channel bit
  sawCaptions_ = true;

  if (b2 >= 0x40) {
    handlePreambleAddress(base, b2);
    return;
  }
  if (base == 0x11 && b2 >= 0x20 && b2 <= 0x2F) {
    handleMidRow(b2);
    publish(t);
    return;
  }
  if (base == 0x11 && b2 >= 0x30) {
    putCharacter(kSpecialCharacters[b2 - 0x30U]);
    publish(t);
    return;
  }
  if (base == 0x12 && b2 >= 0x20) {
    replaceLastCharacter(kExtendedLatin1[b2 - 0x20U]);
    publish(t);
    return;
  }
  if (base == 0x13 && b2 >= 0x20) {
    replaceLastCharacter(kExtendedLatin2[b2 - 0x20U]);
    publish(t);
    return;
  }
  if (base == 0x17 && b2 >= 0x21 && b2 <= 0x23) {  // tab offset 1..3
    column_ = std::min(column_ + (b2 - 0x20U), kCaptionColumns - 1);
    return;
  }
  if (base == 0x14 || base == 0x15) {
    handleMiscControl(t, b2);
  }
}

void Cea608Decoder::handlePreambleAddress(std::uint8_t b1, std::uint8_t b2) {
  const std::size_t index = b1 & 0x07U;
  const std::uint8_t row = kPacRows[index][(b2 >= 0x60) ? 1U : 0U];
  if (row == 0) return;
  row_ = row - 1U;
  underline_ = (b2 & 0x01U) != 0;
  // b2 bits 4..1 are either an indent (bit 4 set) or a colour; italics is the
  // colour value 7. Only underline and italics change what a word means.
  const auto style = static_cast<std::uint8_t>((b2 >> 1) & 0x0FU);
  if ((b2 & 0x10U) != 0) {
    column_ = std::min(static_cast<std::size_t>((style & 0x07U) * 4U),
                       kCaptionColumns - 1);
    italic_ = false;
  } else {
    column_ = 0;
    italic_ = (style == 0x07U);
  }
}

void Cea608Decoder::handleMidRow(std::uint8_t b2) {
  // A mid-row code occupies a column as a space and sets colour/italics.
  italic_ = (b2 & 0x0EU) == 0x0EU;
  underline_ = (b2 & 0x01U) != 0;
  putCharacter(kBlank);
}

void Cea608Decoder::handleMiscControl(std::int64_t t, std::uint8_t b2) {
  switch (b2) {
    case 0x20:  // RCL: resume caption loading (pop-on)
      mode_ = Cea608Mode::PopOn;
      break;
    case 0x21:  // BS: backspace
      if (column_ > 0) {
        --column_;
        target().cells[row_][column_] = kBlank;
        publish(t);
      }
      break;
    case 0x24:  // DER: delete to end of row
      for (std::size_t c = column_; c < kCaptionColumns; ++c) {
        target().cells[row_][c] = kBlank;
      }
      publish(t);
      break;
    case 0x25:
    case 0x26:
    case 0x27:  // RU2 / RU3 / RU4
      mode_ = Cea608Mode::RollUp;
      rollUpRows_ = static_cast<std::size_t>(b2 - 0x23U);
      column_ = 0;
      break;
    case 0x29:  // RDC: resume direct captioning (paint-on)
      mode_ = Cea608Mode::PaintOn;
      break;
    case 0x2C:  // EDM: erase displayed memory
      displayed_.clear();
      publish(t);
      break;
    case 0x2D:  // CR: carriage return
      carriageReturn(t);
      break;
    case 0x2E:  // ENM: erase non-displayed memory
      nonDisplayed_.clear();
      break;
    case 0x2F:  // EOC: end of caption, flip the memories
      std::swap(displayed_, nonDisplayed_);
      nonDisplayed_.clear();
      publish(t);
      break;
    default:
      break;
  }
}

void Cea608Decoder::putCharacter(char32_t c) {
  if (row_ >= kCaptionRows) return;
  if (column_ >= kCaptionColumns) return;  // the row is full; 608 discards
  target().cells[row_][column_] = c;
  ++column_;
}

void Cea608Decoder::replaceLastCharacter(char32_t c) {
  // Extended characters arrive AFTER a plain approximation of themselves, and
  // replace it. When nothing precedes them they are simply written.
  if (column_ > 0) --column_;
  putCharacter(c);
}

void Cea608Decoder::carriageReturn(std::int64_t t) {
  if (mode_ != Cea608Mode::RollUp) return;
  const std::size_t base = row_;
  const std::size_t top = (base + 1 >= rollUpRows_) ? base + 1 - rollUpRows_ : 0;
  for (std::size_t r = top; r < base; ++r) {
    displayed_.cells[r] = displayed_.cells[r + 1];
  }
  displayed_.clearRow(base);
  column_ = 0;
  publish(t);
}

void Cea608Decoder::publish(std::int64_t t) {
  std::uint8_t topRow = 0;
  std::string text = displayed_.render(&topRow);
  // The same screen at a later instant is not a change. This is also what
  // keeps pop-on loading silent: RCL/PAC/text all write to the NON-displayed
  // buffer, so the displayed screen is unchanged until EOC swaps them.
  if (text == lastPublished_) return;
  if (updates_.size() >= kMaximumPendingUpdates) {
    ++droppedUpdates_;
    return;
  }
  lastPublished_ = text;
  Cea608Update update;
  update.timeNanoseconds = t;
  update.text = std::move(text);
  update.mode = mode_;
  update.topRow = topRow;
  updates_.push_back(std::move(update));
}

}  // namespace wam::media::captions
