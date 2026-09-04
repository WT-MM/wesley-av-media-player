#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

// Neutral bitmap-subtitle types: the palettised image a bitmap subtitle codec
// produces, the timed cue that carries it, and the track-level content record
// that names the coordinate space those cues are positioned in.
//
// Deliberately free of Qt and of Apple frameworks, exactly as subtitle_text.hpp
// is, so the PGS and VobSub decoders are pure, testable and reusable from the
// Matroska lane, the Qt controller and a unit test without dragging a toolkit
// behind them.
//
// WHY PALETTISED AND NOT RGBA. Both formats natively produce an 8-bit (PGS) or
// 2-bit (VobSub) index into a small palette, and both a movie's worth of cues
// and a mutation-checkable test want the compact, exact form: a 1920x1080 cue
// expanded to BGRA is 8 MiB, while its index plane is 2 MiB and its RLE source
// is a few KiB. Expansion to BGRA happens once, at display time, for the one or
// two cues actually on screen -- see expandToBgra below.
namespace wam::media::subtitles {

enum class BitmapCodec : std::uint8_t {
  Unknown,
  HdmvPgs,  // S_HDMV/PGS  -- Blu-ray presentation graphics
  VobSub,   // S_VOBSUB    -- DVD sub-picture units
};

// Matroska CodecID -> bitmap codec. Unknown for anything that is not a bitmap
// subtitle codec, which is how the text codecs are declined here (they are
// handled by textCodecFromMatroskaCodecId in subtitle_text.hpp). The two
// predicates are exclusive: no CodecID is accepted by both.
[[nodiscard]] BitmapCodec bitmapCodecFromMatroskaCodecId(
    std::string_view codecId) noexcept;

[[nodiscard]] constexpr bool isBitmapCodec(BitmapCodec codec) noexcept {
  return codec != BitmapCodec::Unknown;
}

// A short human name for the codec, for the track menu ("PGS", "VobSub").
[[nodiscard]] std::string_view bitmapCodecName(BitmapCodec codec) noexcept;

// Palette entries are 0xAARRGGBB, straight (NOT premultiplied) alpha. Straight
// is what both formats specify -- PGS carries alpha as its own palette field
// and VobSub carries a separate 4-bit contrast value -- and premultiplying is
// the renderer's business, not the decoder's.
using BitmapPalette = std::array<std::uint32_t, 256>;

struct BitmapImage {
  std::uint32_t width{0};
  std::uint32_t height{0};
  // width * height palette indices, row-major, no padding.
  std::vector<std::uint8_t> indices;
  BitmapPalette palette{};

  [[nodiscard]] bool empty() const noexcept {
    return width == 0 || height == 0 || indices.empty();
  }
  // True when `indices` is exactly width*height. Every decoder guarantees this
  // on success; a test asserts it rather than trusting it.
  [[nodiscard]] bool consistent() const noexcept {
    return indices.size() ==
           static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
  }
};

// One displayed bitmap, positioned in the track's coordinate space.
struct BitmapCue {
  std::int64_t startNanoseconds{0};
  std::int64_t endNanoseconds{0};
  // Top-left of `image` within the canvas named by BitmapSubtitleContent.
  std::int32_t x{0};
  std::int32_t y{0};
  BitmapImage image;
  // PGS composition-object forced flag / VobSub forced-display. Drives the
  // existing forced-subtitle policy unchanged.
  bool forced{false};

  [[nodiscard]] bool covers(std::int64_t t) const noexcept {
    return t >= startNanoseconds && t < endNanoseconds;
  }
};

// The decoded track. `canvasWidth/Height` is the coordinate space the cues'
// x/y/width/height are expressed in -- the PGS presentation composition's
// declared video size, or the VobSub .idx "size:" line. It is NOT necessarily
// the video's coded size (a 1920x1080 PGS track is legal over a 1920x816
// letterboxed encode), so the renderer must scale by this and not by the video.
struct BitmapSubtitleContent {
  std::uint32_t canvasWidth{0};
  std::uint32_t canvasHeight{0};
  std::vector<BitmapCue> cues;
  bool truncated{false};
  // Cues the decoder produced but could not time (no following clear and no
  // duration). Reported rather than hidden, matching SubtitleTrackLoad.
  std::uint32_t skippedWithoutDuration{0};
  // Empty on success; a short reason otherwise. `cues` may still be non-empty:
  // a partially readable bitmap track is worth showing.
  std::string error;
};

// Bounds, mirroring subtitle_text.hpp's. A track exceeding either is truncated
// at the limit rather than refused.
inline constexpr std::size_t kMaximumBitmapCues{16'384};
// Total decoded index-plane bytes retained for one track. A two-hour PGS track
// of 1000x100 cues is ~1500 cues * 100 KiB = 150 MiB, so this bound is real.
inline constexpr std::size_t kMaximumBitmapIndexBytes{192U * 1024U * 1024U};
// One cue's pixel count. 4096x2160 is beyond any real presentation graphic.
inline constexpr std::size_t kMaximumBitmapPixels{4096U * 2160U};
// Longest duration a cue may claim from its own payload. Both formats can
// encode "no stop" as a maximal delay -- a VobSub stop delay of 0xFFFF is 745
// seconds -- and a caption stuck on screen for twelve minutes is worse than one
// clipped at thirty seconds. A container-supplied BlockDuration is trusted
// ahead of this and is not clamped.
inline constexpr std::int64_t kMaximumBitmapCueDurationNanoseconds{
    30LL * 1'000'000'000LL};

// Expands to 32-bit BGRA in memory order (byte 0 = blue), which is what both
// QImage::Format_ARGB32 on a little-endian host and CoreGraphics' default
// 32-bit little-endian layout expect. Returns false and leaves `out` untouched
// when the image is inconsistent.
[[nodiscard]] bool expandToBgra(const BitmapImage& image,
                                std::vector<std::uint32_t>* out) noexcept;

// True when every pixel of `image` is fully transparent. Both formats routinely
// carry such objects (a display set that only moves a window, a VobSub packet
// whose visible area is empty); showing them would flash an empty overlay, so
// the loaders drop them.
[[nodiscard]] bool isFullyTransparent(const BitmapImage& image) noexcept;

// Shrinks `cue`'s image to its opaque bounding box, moving x/y to match, so a
// mostly-empty object does not carry a screen-sized transparent plane through
// the render path. A fully transparent image is left untouched (callers drop
// it via isFullyTransparent first). Returns true when anything changed.
bool cropToOpaqueBounds(BitmapCue* cue) noexcept;

// BT.601 limited-range YCrCb -> 0xAARRGGBB, the conversion both formats
// specify for their palettes.
[[nodiscard]] std::uint32_t ycrcbToArgb(std::uint8_t y, std::uint8_t cr,
                                        std::uint8_t cb,
                                        std::uint8_t alpha) noexcept;

// Sorts by start time (stable), drops empty and non-positive-length cues.
// Overlapping cues are NOT clamped: PGS legitimately shows two composition
// objects at once, and each is its own cue.
void finalizeBitmapCues(std::vector<BitmapCue>* cues);

// Indices of every cue covering `t`, appended to `out`. Unlike text cues, more
// than one bitmap cue can be on screen at once, so this returns a set rather
// than a single index. Cues must be sorted by start.
void bitmapCuesAt(const std::vector<BitmapCue>& cues, std::int64_t t,
                  std::vector<std::size_t>* out);

}  // namespace wam::media::subtitles
