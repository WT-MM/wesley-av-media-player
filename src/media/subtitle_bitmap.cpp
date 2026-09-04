#include "media/subtitle_bitmap.hpp"

#include <algorithm>
#include <cstring>

namespace wam::media::subtitles {
namespace {

[[nodiscard]] std::uint8_t clampToByte(int value) noexcept {
  if (value < 0) {
    return 0;
  }
  if (value > 255) {
    return 255;
  }
  return static_cast<std::uint8_t>(value);
}

}  // namespace

BitmapCodec bitmapCodecFromMatroskaCodecId(std::string_view codecId) noexcept {
  // Matroska CodecIDs are ASCII and case-sensitive by spec; real muxers emit
  // exactly these two. A trailing NUL is tolerated because CodecPrivate-adjacent
  // string elements are occasionally NUL-padded.
  while (!codecId.empty() && codecId.back() == '\0') {
    codecId.remove_suffix(1);
  }
  if (codecId == "S_HDMV/PGS") {
    return BitmapCodec::HdmvPgs;
  }
  if (codecId == "S_VOBSUB") {
    return BitmapCodec::VobSub;
  }
  return BitmapCodec::Unknown;
}

std::string_view bitmapCodecName(BitmapCodec codec) noexcept {
  switch (codec) {
    case BitmapCodec::HdmvPgs:
      return "PGS";
    case BitmapCodec::VobSub:
      return "VobSub";
    case BitmapCodec::Unknown:
      break;
  }
  return "";
}

std::uint32_t ycrcbToArgb(std::uint8_t y, std::uint8_t cr, std::uint8_t cb,
                          std::uint8_t alpha) noexcept {
  // BT.601 limited range (16..235 luma, 16..240 chroma), the conversion both
  // HDMV presentation graphics and DVD sub-pictures specify. Fixed-point in
  // 1/256 units so the result is bit-identical on every host.
  const int yy = (static_cast<int>(y) - 16) * 298;
  const int ccr = static_cast<int>(cr) - 128;
  const int ccb = static_cast<int>(cb) - 128;
  const int r = (yy + 409 * ccr + 128) >> 8;
  const int g = (yy - 100 * ccb - 208 * ccr + 128) >> 8;
  const int b = (yy + 516 * ccb + 128) >> 8;
  return (static_cast<std::uint32_t>(alpha) << 24) |
         (static_cast<std::uint32_t>(clampToByte(r)) << 16) |
         (static_cast<std::uint32_t>(clampToByte(g)) << 8) |
         static_cast<std::uint32_t>(clampToByte(b));
}

bool expandToBgra(const BitmapImage& image,
                  std::vector<std::uint32_t>* out) noexcept {
  if (out == nullptr || !image.consistent() || image.empty()) {
    return false;
  }
  const std::size_t count = image.indices.size();
  // On a little-endian host a 0xAARRGGBB word already reads as B,G,R,A in
  // memory order, which is what QImage::Format_ARGB32 and CoreGraphics'
  // little-endian 32-bit layout both consume. No per-pixel swizzle is needed;
  // the palette is stored in exactly that word form.
  try {
    out->resize(count);
  } catch (...) {
    return false;
  }
  const std::uint8_t* src = image.indices.data();
  std::uint32_t* dst = out->data();
  for (std::size_t i = 0; i < count; ++i) {
    dst[i] = image.palette[src[i]];
  }
  return true;
}

bool isFullyTransparent(const BitmapImage& image) noexcept {
  if (!image.consistent() || image.empty()) {
    return true;
  }
  // Check which palette entries are opaque once, then scan indices: a 256-entry
  // table beats an alpha shift per pixel.
  std::array<bool, 256> visible{};
  bool anyVisible = false;
  for (std::size_t i = 0; i < visible.size(); ++i) {
    visible[i] = (image.palette[i] >> 24) != 0;
    anyVisible = anyVisible || visible[i];
  }
  if (!anyVisible) {
    return true;
  }
  for (const std::uint8_t index : image.indices) {
    if (visible[index]) {
      return false;
    }
  }
  return true;
}

bool cropToOpaqueBounds(BitmapCue* cue) noexcept {
  if (cue == nullptr || !cue->image.consistent() || cue->image.empty()) {
    return false;
  }
  BitmapImage& image = cue->image;
  std::array<bool, 256> visible{};
  for (std::size_t i = 0; i < visible.size(); ++i) {
    visible[i] = (image.palette[i] >> 24) != 0;
  }

  const std::uint32_t width = image.width;
  const std::uint32_t height = image.height;
  std::uint32_t minX = width;
  std::uint32_t minY = height;
  std::uint32_t maxX = 0;
  std::uint32_t maxY = 0;
  bool any = false;
  for (std::uint32_t row = 0; row < height; ++row) {
    const std::uint8_t* line = image.indices.data() +
                               static_cast<std::size_t>(row) * width;
    for (std::uint32_t col = 0; col < width; ++col) {
      if (!visible[line[col]]) {
        continue;
      }
      any = true;
      minX = std::min(minX, col);
      maxX = std::max(maxX, col);
      minY = std::min(minY, row);
      maxY = std::max(maxY, row);
    }
  }
  if (!any) {
    return false;  // fully transparent; callers drop it instead.
  }
  if (minX == 0 && minY == 0 && maxX == width - 1 && maxY == height - 1) {
    return false;  // already tight
  }

  const std::uint32_t newWidth = maxX - minX + 1;
  const std::uint32_t newHeight = maxY - minY + 1;
  std::vector<std::uint8_t> cropped;
  try {
    cropped.resize(static_cast<std::size_t>(newWidth) * newHeight);
  } catch (...) {
    return false;
  }
  for (std::uint32_t row = 0; row < newHeight; ++row) {
    const std::uint8_t* src = image.indices.data() +
                              static_cast<std::size_t>(row + minY) * width + minX;
    std::memcpy(cropped.data() + static_cast<std::size_t>(row) * newWidth, src,
                newWidth);
  }
  image.indices = std::move(cropped);
  image.width = newWidth;
  image.height = newHeight;
  cue->x += static_cast<std::int32_t>(minX);
  cue->y += static_cast<std::int32_t>(minY);
  return true;
}

void finalizeBitmapCues(std::vector<BitmapCue>* cues) {
  if (cues == nullptr) {
    return;
  }
  std::erase_if(*cues, [](const BitmapCue& cue) {
    return cue.endNanoseconds <= cue.startNanoseconds || cue.image.empty() ||
           !cue.image.consistent();
  });
  std::stable_sort(cues->begin(), cues->end(),
                   [](const BitmapCue& a, const BitmapCue& b) {
                     return a.startNanoseconds < b.startNanoseconds;
                   });
}

void bitmapCuesAt(const std::vector<BitmapCue>& cues, std::int64_t t,
                  std::vector<std::size_t>* out) {
  if (out == nullptr) {
    return;
  }
  out->clear();
  // Cues are sorted by start, so every candidate begins at or before the first
  // cue whose start exceeds t. Ends are not sorted, so the scan walks back from
  // there; bitmap cue lists are small (a movie is ~1500 cues) and overlapping
  // runs are shorter still.
  const auto upper = std::upper_bound(
      cues.begin(), cues.end(), t,
      [](std::int64_t value, const BitmapCue& cue) {
        return value < cue.startNanoseconds;
      });
  for (auto it = cues.begin(); it != upper; ++it) {
    if (it->covers(t)) {
      out->push_back(static_cast<std::size_t>(it - cues.begin()));
    }
  }
}

}  // namespace wam::media::subtitles
