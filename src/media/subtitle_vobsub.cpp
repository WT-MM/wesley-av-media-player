#include "media/subtitle_vobsub.hpp"

#include <algorithm>
#include <cctype>
#include <cstring>

namespace wam::media::subtitles::vobsub {
namespace {

// Control-sequence delays are in units of 1024/90000 s.
constexpr std::int64_t kDelayNumerator = 1024LL * 1'000'000'000LL;
constexpr std::int64_t kDelayDenominator = 90'000LL;

constexpr std::uint32_t kDefaultCanvasWidth = 720;
constexpr std::uint32_t kDefaultCanvasHeight = 480;

[[nodiscard]] std::uint16_t readU16(const std::uint8_t* p) noexcept {
  return static_cast<std::uint16_t>((static_cast<std::uint16_t>(p[0]) << 8) |
                                    static_cast<std::uint16_t>(p[1]));
}

void setError(std::string* error, std::string_view reason) {
  if (error != nullptr && error->empty()) {
    error->assign(reason);
  }
}

[[nodiscard]] std::int64_t delayToNanoseconds(std::uint16_t delay) noexcept {
  return static_cast<std::int64_t>(delay) * kDelayNumerator / kDelayDenominator;
}

[[nodiscard]] std::string_view trim(std::string_view text) noexcept {
  while (!text.empty() &&
         std::isspace(static_cast<unsigned char>(text.front())) != 0) {
    text.remove_prefix(1);
  }
  while (!text.empty() &&
         std::isspace(static_cast<unsigned char>(text.back())) != 0) {
    text.remove_suffix(1);
  }
  return text;
}

[[nodiscard]] bool parseHex(std::string_view text, std::uint32_t* out) noexcept {
  if (text.empty() || text.size() > 8) {
    return false;
  }
  std::uint32_t value = 0;
  for (const char c : text) {
    std::uint32_t digit = 0;
    if (c >= '0' && c <= '9') {
      digit = static_cast<std::uint32_t>(c - '0');
    } else if (c >= 'a' && c <= 'f') {
      digit = static_cast<std::uint32_t>(c - 'a') + 10;
    } else if (c >= 'A' && c <= 'F') {
      digit = static_cast<std::uint32_t>(c - 'A') + 10;
    } else {
      return false;
    }
    value = (value << 4) | digit;
  }
  *out = value;
  return true;
}

[[nodiscard]] bool parseDecimal(std::string_view text,
                                std::uint32_t* out) noexcept {
  if (text.empty() || text.size() > 6) {
    return false;
  }
  std::uint32_t value = 0;
  for (const char c : text) {
    if (c < '0' || c > '9') {
      return false;
    }
    value = value * 10 + static_cast<std::uint32_t>(c - '0');
  }
  *out = value;
  return true;
}

// Reads 4-bit nibbles most-significant first.
class NibbleReader {
 public:
  NibbleReader(std::span<const std::uint8_t> data, std::size_t byteOffset)
      : data_(data), nibble_(byteOffset * 2) {}

  [[nodiscard]] bool read(std::uint8_t* out) noexcept {
    const std::size_t byte = nibble_ / 2;
    if (byte >= data_.size()) {
      return false;
    }
    const std::uint8_t value = data_[byte];
    *out = (nibble_ % 2 == 0) ? static_cast<std::uint8_t>(value >> 4)
                              : static_cast<std::uint8_t>(value & 0x0F);
    ++nibble_;
    return true;
  }

  void alignToByte() noexcept {
    if (nibble_ % 2 != 0) {
      ++nibble_;
    }
  }

  [[nodiscard]] bool exhausted() const noexcept {
    return nibble_ / 2 >= data_.size();
  }

 private:
  std::span<const std::uint8_t> data_;
  std::size_t nibble_{0};
};

// Decodes one field (every other line) starting at `byteOffset`.
[[nodiscard]] bool decodeField(std::span<const std::uint8_t> data,
                               std::size_t byteOffset, std::uint32_t width,
                               std::uint32_t height, std::uint32_t firstRow,
                               std::vector<std::uint8_t>* indices) noexcept {
  if (byteOffset >= data.size()) {
    return false;
  }
  NibbleReader reader(data, byteOffset);
  for (std::uint32_t row = firstRow; row < height; row += 2) {
    std::uint32_t col = 0;
    while (col < width) {
      std::uint8_t nibble = 0;
      if (!reader.read(&nibble)) {
        return true;  // ran out of data; the rest of the field stays colour 0
      }
      std::uint32_t value = nibble;
      // Grow the code a nibble at a time until it is unambiguous.
      if (value < 0x4) {
        if (!reader.read(&nibble)) {
          return true;
        }
        value = (value << 4) | nibble;
        if (value < 0x10) {
          if (!reader.read(&nibble)) {
            return true;
          }
          value = (value << 4) | nibble;
          if (value < 0x40) {
            if (!reader.read(&nibble)) {
              return true;
            }
            value = (value << 4) | nibble;
          }
        }
      }
      const std::uint8_t colour = static_cast<std::uint8_t>(value & 0x03);
      std::uint32_t run = value >> 2;
      if (run == 0 || col + run > width) {
        // Zero means "to the end of the line"; an overrun is clipped for the
        // same reason PGS clips one -- a caption is worth more than a byte.
        run = width - col;
      }
      if (colour != 0) {
        std::uint8_t* line =
            indices->data() + static_cast<std::size_t>(row) * width + col;
        std::memset(line, colour, run);
      }
      col += run;
    }
    reader.alignToByte();
    if (reader.exhausted()) {
      return true;
    }
  }
  return true;
}

}  // namespace

std::array<std::uint32_t, 16> defaultIdxPalette() noexcept {
  std::array<std::uint32_t, 16> palette{};
  palette[0] = 0x000000;  // background
  palette[1] = 0xFFFFFF;  // glyph
  palette[2] = 0x000000;  // outline
  palette[3] = 0x808080;  // anti-aliasing
  for (std::size_t i = 4; i < palette.size(); ++i) {
    palette[i] = 0x808080;
  }
  return palette;
}

bool parseIdxMetadata(std::string_view text, IdxMetadata* out,
                      std::string* error) {
  if (out == nullptr) {
    return false;
  }
  *out = IdxMetadata{};
  out->palette = defaultIdxPalette();

  std::size_t pos = 0;
  while (pos <= text.size()) {
    const std::size_t newline = text.find('\n', pos);
    const std::string_view line =
        trim(text.substr(pos, newline == std::string_view::npos
                                  ? std::string_view::npos
                                  : newline - pos));
    pos = (newline == std::string_view::npos) ? text.size() + 1 : newline + 1;
    if (line.empty() || line.front() == '#') {
      continue;
    }
    const std::size_t colon = line.find(':');
    if (colon == std::string_view::npos) {
      continue;
    }
    const std::string_view key = trim(line.substr(0, colon));
    const std::string_view value = trim(line.substr(colon + 1));
    if (key == "size") {
      const std::size_t x = value.find('x');
      if (x == std::string_view::npos) {
        continue;
      }
      std::uint32_t width = 0;
      std::uint32_t height = 0;
      if (parseDecimal(trim(value.substr(0, x)), &width) &&
          parseDecimal(trim(value.substr(x + 1)), &height) && width != 0 &&
          height != 0) {
        out->width = width;
        out->height = height;
        out->hasSize = true;
      }
    } else if (key == "palette") {
      std::size_t entry = 0;
      std::size_t start = 0;
      while (entry < out->palette.size() && start <= value.size()) {
        const std::size_t comma = value.find(',', start);
        const std::string_view item =
            trim(value.substr(start, comma == std::string_view::npos
                                         ? std::string_view::npos
                                         : comma - start));
        start = (comma == std::string_view::npos) ? value.size() + 1 : comma + 1;
        std::uint32_t rgb = 0;
        if (!item.empty() && parseHex(item, &rgb)) {
          out->palette[entry] = rgb & 0x00FFFFFFU;
          ++entry;
        }
        if (comma == std::string_view::npos) {
          break;
        }
      }
      // A short palette line still yields the entries it did carry; the rest
      // keep their defaults rather than turning the caption invisible.
      out->hasPalette = entry > 0;
    }
  }

  if (!out->hasSize) {
    out->width = kDefaultCanvasWidth;
    out->height = kDefaultCanvasHeight;
  }
  if (!out->hasSize && !out->hasPalette) {
    setError(error, "VobSub CodecPrivate carries neither size nor palette");
    return false;
  }
  return true;
}

bool decodeRunLength(std::span<const std::uint8_t> data, std::size_t topOffset,
                     std::size_t bottomOffset, std::uint32_t width,
                     std::uint32_t height, std::vector<std::uint8_t>* indices,
                     std::string* error) {
  if (indices == nullptr) {
    return false;
  }
  if (width == 0 || height == 0) {
    setError(error, "VobSub sub-picture has a zero dimension");
    return false;
  }
  const std::size_t pixels =
      static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
  if (pixels > kMaximumBitmapPixels) {
    setError(error, "VobSub sub-picture exceeds the pixel bound");
    return false;
  }
  try {
    indices->assign(pixels, 0);
  } catch (...) {
    setError(error, "VobSub sub-picture allocation failed");
    return false;
  }
  const bool top = decodeField(data, topOffset, width, height, 0, indices);
  const bool bottom = decodeField(data, bottomOffset, width, height, 1, indices);
  if (!top && !bottom) {
    setError(error, "VobSub pixel-data offsets lie outside the packet");
    return false;
  }
  return true;
}

bool decodeSubPicture(std::span<const std::uint8_t> packet,
                      const IdxMetadata& metadata, SubPicture* out,
                      std::string* error) {
  if (out == nullptr) {
    return false;
  }
  if (packet.size() < 4) {
    setError(error, "VobSub packet is too short to hold a header");
    return false;
  }
  *out = SubPicture{};

  const std::uint16_t declaredSize = readU16(packet.data());
  const std::uint16_t controlOffset = readU16(packet.data() + 2);
  // A packet may be padded past its declared size; it may not be shorter than
  // the control chain it points at.
  const std::size_t usable = std::min<std::size_t>(
      packet.size(), declaredSize != 0 ? declaredSize : packet.size());
  if (controlOffset + 4U > usable) {
    setError(error, "VobSub control offset lies outside the packet");
    return false;
  }

  std::uint32_t x1 = 0;
  std::uint32_t x2 = 0;
  std::uint32_t y1 = 0;
  std::uint32_t y2 = 0;
  bool haveArea = false;
  std::size_t topOffset = 4;
  std::size_t bottomOffset = 4;
  bool haveOffsets = false;
  std::array<std::uint8_t, 4> colourIndex{0, 1, 2, 3};
  std::array<std::uint8_t, 4> alphaNibble{0, 0xF, 0xF, 0xF};
  bool haveStart = false;

  std::size_t sequence = controlOffset;
  int guard = 0;
  while (sequence + 4 <= usable && guard++ < 64) {
    const std::uint16_t delay = readU16(packet.data() + sequence);
    const std::uint16_t next = readU16(packet.data() + sequence + 2);
    std::size_t pos = sequence + 4;
    bool ended = false;
    while (pos < usable && !ended) {
      const std::uint8_t command = packet[pos++];
      switch (command) {
        case 0x00:  // forced display
          out->forced = true;
          if (!haveStart) {
            out->startOffsetNanoseconds = delayToNanoseconds(delay);
            haveStart = true;
          }
          break;
        case 0x01:  // start display
          out->startOffsetNanoseconds = delayToNanoseconds(delay);
          haveStart = true;
          break;
        case 0x02:  // stop display
          out->endOffsetNanoseconds = delayToNanoseconds(delay);
          out->hasStop = true;
          break;
        case 0x03: {  // set palette: four nibbles, colours 3,2,1,0
          if (pos + 2 > usable) {
            ended = true;
            break;
          }
          colourIndex[3] = static_cast<std::uint8_t>(packet[pos] >> 4);
          colourIndex[2] = static_cast<std::uint8_t>(packet[pos] & 0x0F);
          colourIndex[1] = static_cast<std::uint8_t>(packet[pos + 1] >> 4);
          colourIndex[0] = static_cast<std::uint8_t>(packet[pos + 1] & 0x0F);
          pos += 2;
          break;
        }
        case 0x04: {  // set alpha: four nibbles, colours 3,2,1,0
          if (pos + 2 > usable) {
            ended = true;
            break;
          }
          alphaNibble[3] = static_cast<std::uint8_t>(packet[pos] >> 4);
          alphaNibble[2] = static_cast<std::uint8_t>(packet[pos] & 0x0F);
          alphaNibble[1] = static_cast<std::uint8_t>(packet[pos + 1] >> 4);
          alphaNibble[0] = static_cast<std::uint8_t>(packet[pos + 1] & 0x0F);
          pos += 2;
          break;
        }
        case 0x05: {  // set display area: two 12-bit x, two 12-bit y
          if (pos + 6 > usable) {
            ended = true;
            break;
          }
          x1 = (static_cast<std::uint32_t>(packet[pos]) << 4) |
               (static_cast<std::uint32_t>(packet[pos + 1]) >> 4);
          x2 = ((static_cast<std::uint32_t>(packet[pos + 1]) & 0x0F) << 8) |
               static_cast<std::uint32_t>(packet[pos + 2]);
          y1 = (static_cast<std::uint32_t>(packet[pos + 3]) << 4) |
               (static_cast<std::uint32_t>(packet[pos + 4]) >> 4);
          y2 = ((static_cast<std::uint32_t>(packet[pos + 4]) & 0x0F) << 8) |
               static_cast<std::uint32_t>(packet[pos + 5]);
          haveArea = true;
          pos += 6;
          break;
        }
        case 0x06: {  // set pixel-data offsets
          if (pos + 4 > usable) {
            ended = true;
            break;
          }
          topOffset = readU16(packet.data() + pos);
          bottomOffset = readU16(packet.data() + pos + 2);
          haveOffsets = true;
          pos += 4;
          break;
        }
        case 0x07:  // set sub-picture colour/contrast; length-prefixed
          if (pos + 2 > usable) {
            ended = true;
            break;
          }
          pos += readU16(packet.data() + pos);
          break;
        case 0xFF:
          ended = true;
          break;
        default:
          // An unknown command has no length, so the chain cannot be walked
          // past it. Stop here rather than misread the rest as commands.
          ended = true;
          break;
      }
    }
    if (next == sequence || next < controlOffset || next + 4 > usable) {
      break;  // last sequence (it points at itself) or a broken chain
    }
    sequence = next;
  }

  if (!haveArea || x2 < x1 || y2 < y1) {
    setError(error, "VobSub packet declares no usable display area");
    return false;
  }
  const std::uint32_t width = x2 - x1 + 1;
  const std::uint32_t height = y2 - y1 + 1;
  if (!haveOffsets) {
    setError(error, "VobSub packet declares no pixel-data offsets");
    return false;
  }

  out->x = static_cast<std::int32_t>(x1);
  out->y = static_cast<std::int32_t>(y1);
  out->image.width = width;
  out->image.height = height;
  // Only four colours are addressable; the rest of the palette stays
  // transparent so a corrupt index cannot paint an arbitrary colour.
  for (std::size_t i = 0; i < 4; ++i) {
    const std::uint32_t rgb = metadata.palette[colourIndex[i] & 0x0F];
    // A 4-bit contrast value scales to 8 bits by multiplying by 17, so 0xF
    // becomes exactly 255.
    const std::uint32_t alpha =
        static_cast<std::uint32_t>(alphaNibble[i] & 0x0F) * 17U;
    out->image.palette[i] = (alpha << 24) | rgb;
  }

  const std::span<const std::uint8_t> body = packet.subspan(0, usable);
  return decodeRunLength(body, topOffset, bottomOffset, width, height,
                         &out->image.indices, error);
}

// ---------------------------------------------------------------------------

TrackDecoder::TrackDecoder(std::string_view codecPrivate) {
  std::string error;
  if (!parseIdxMetadata(codecPrivate, &metadata_, &error)) {
    // Not fatal: the defaults parseIdxMetadata already installed are usable.
    noteError(error);
  }
  content_.canvasWidth = metadata_.width;
  content_.canvasHeight = metadata_.height;
}

void TrackDecoder::noteError(std::string_view reason) {
  if (!errorSet_ && !reason.empty()) {
    error_.assign(reason);
    errorSet_ = true;
  }
}

bool TrackDecoder::appendBlock(std::span<const std::uint8_t> payload,
                               std::int64_t timestampNanoseconds,
                               std::int64_t durationNanoseconds) {
  SubPicture picture;
  std::string error;
  if (!decodeSubPicture(payload, metadata_, &picture, &error)) {
    noteError(error);
    return false;
  }

  const std::int64_t start =
      timestampNanoseconds + picture.startOffsetNanoseconds;

  // An SPU with no stop command runs until the next one says otherwise.
  if (openCue_ < content_.cues.size()) {
    BitmapCue& previous = content_.cues[openCue_];
    if (previous.endNanoseconds <= previous.startNanoseconds) {
      previous.endNanoseconds = std::max(start, previous.startNanoseconds + 1);
    }
    openCue_ = static_cast<std::size_t>(-1);
  }

  if (isFullyTransparent(picture.image)) {
    return true;  // an SPU that paints nothing is a clear, not a caption
  }
  if (content_.cues.size() >= kMaximumBitmapCues ||
      indexBytes_ >= kMaximumBitmapIndexBytes) {
    content_.truncated = true;
    return true;
  }

  // End time, in the order the container's own rules put them: BlockDuration
  // first, then the SPU's stop command (clamped, because "unknown" is encoded
  // as a maximal delay), then left open for the next SPU to close.
  std::int64_t end = start;
  if (durationNanoseconds > 0) {
    end = timestampNanoseconds + durationNanoseconds;
  } else if (picture.hasStop) {
    const std::int64_t stop =
        timestampNanoseconds + picture.endOffsetNanoseconds;
    if (stop > start) {
      end = std::min(stop, start + kMaximumBitmapCueDurationNanoseconds);
    }
  }

  BitmapCue cue;
  cue.startNanoseconds = start;
  cue.endNanoseconds = end;
  cue.x = picture.x;
  cue.y = picture.y;
  cue.forced = picture.forced;
  cue.image = std::move(picture.image);
  cropToOpaqueBounds(&cue);
  indexBytes_ += cue.image.indices.size();
  const bool open = cue.endNanoseconds <= cue.startNanoseconds;
  content_.cues.push_back(std::move(cue));
  if (open) {
    openCue_ = content_.cues.size() - 1;
  }
  return true;
}

BitmapSubtitleContent TrackDecoder::finish(std::int64_t endNanoseconds) {
  if (openCue_ < content_.cues.size()) {
    BitmapCue& cue = content_.cues[openCue_];
    if (cue.endNanoseconds <= cue.startNanoseconds) {
      if (endNanoseconds > cue.startNanoseconds) {
        cue.endNanoseconds = endNanoseconds;
      } else {
        ++content_.skippedWithoutDuration;
      }
    }
    openCue_ = static_cast<std::size_t>(-1);
  }
  finalizeBitmapCues(&content_.cues);
  content_.canvasWidth = metadata_.width;
  content_.canvasHeight = metadata_.height;
  content_.error = error_;
  return std::move(content_);
}

}  // namespace wam::media::subtitles::vobsub
