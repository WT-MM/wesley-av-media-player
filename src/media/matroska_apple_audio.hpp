#pragma once

#include "media/native_media_source.hpp"
#include "media/adpcm_audio.hpp"
#include <span>
#include <string_view>

namespace wam::media::matroska {

struct AppleAudioPacketFormat {
  MediaCodec codec{MediaCodec::Unknown};
  MediaAudioFormat format{};
  std::uint32_t blockFrames{0};
  std::span<const std::byte> cookie{};
};

[[nodiscard]] inline std::uint32_t appleAudioInteger(
    std::span<const std::byte> bytes, std::size_t offset,
    unsigned count, bool little = false) noexcept {
  if (offset > bytes.size() || count > bytes.size() - offset) return 0;
  std::uint32_t value = 0;
  for (unsigned i = 0; i < count; ++i)
    value = (value << 8U) | std::to_integer<unsigned>(
        bytes[offset + (little ? count - 1U - i : i)]);
  return value;
}

[[nodiscard]] inline AppleAudioPacketFormat appleAudioPacketFormat(
    std::string_view id, std::span<const std::byte> bytes,
    std::uint32_t rate, std::uint32_t channels, std::uint32_t depth) noexcept {
  AppleAudioPacketFormat out;
  if (rate == 0 || channels == 0 || channels > 2) return out;
  auto& f = out.format;
  f.sampleRate = rate;
  f.channels = channels;
  if (id == "A_ALAC") {
    if (bytes.size() != 24 || appleAudioInteger(bytes, 9, 1) != channels ||
        appleAudioInteger(bytes, 20, 4) != rate) return {};
    depth = appleAudioInteger(bytes, 5, 1);
    if (depth != 16 && depth != 20 && depth != 24 && depth != 32) return {};
    out.blockFrames = appleAudioInteger(bytes, 0, 4);
    if (out.blockFrames == 0 || out.blockFrames > 4096) return {};
    out.codec = MediaCodec::Alac;
    f.formatTag = 0x616c6163U;
    f.formatFlags = depth == 16 ? 1U : depth == 20 ? 2U : depth == 24 ? 3U : 4U;
    f.framesPerPacket = out.blockFrames;
    out.cookie = bytes;
  } else if (id == "A_PCM/INT/LIT" || id == "A_PCM/FLOAT/IEEE") {
    const bool floating = id == "A_PCM/FLOAT/IEEE";
    if (!bytes.empty() || (floating ? depth != 32 :
        (depth != 8 && depth != 16 && depth != 24 && depth != 32))) return {};
    out.codec = MediaCodec::Pcm;
    f.formatTag = 0x6c70636dU;
    f.formatFlags = 8U | (floating ? 1U : 4U);
    f.framesPerPacket = 1;
    f.bitsPerChannel = depth;
    f.bytesPerFrame = channels * (depth / 8U);
    f.bytesPerPacket = f.bytesPerFrame;
  } else if (id == "A_MS/ACM") {
    if (bytes.size() < 20 || appleAudioInteger(bytes, 2, 2, true) != channels ||
        appleAudioInteger(bytes, 4, 4, true) != rate ||
        appleAudioInteger(bytes, 14, 2, true) != 4 ||
        appleAudioInteger(bytes, 16, 2, true) != bytes.size() - 18) return {};
    const auto tag = appleAudioInteger(bytes, 0, 2, true);
    f.bytesPerPacket = appleAudioInteger(bytes, 12, 2, true);
    out.blockFrames = appleAudioInteger(bytes, 18, 2, true);
    if (f.bytesPerPacket <= 7 * channels || out.blockFrames == 0) return {};
    if (tag == 17 && bytes.size() == 20 &&
        out.blockFrames == 1 + (f.bytesPerPacket - 4 * channels) * 2 / channels) {
      out.codec = MediaCodec::AdpcmIma;
      f.formatTag = 0x6d730011U;
    } else if (tag == 2 && bytes.size() == 50 &&
               out.blockFrames == 2 + (f.bytesPerPacket - 7 * channels) * 2 / channels) {
      constexpr std::int16_t coefficients[]{256,0,512,-256,0,0,192,64,240,0,460,-208,392,-232};
      if (appleAudioInteger(bytes, 20, 2, true) != 7) return {};
      for (unsigned i = 0; i < 14; ++i)
        if (appleAudioInteger(bytes, 22 + 2*i, 2, true) !=
            static_cast<std::uint16_t>(coefficients[i])) return {};
      out.codec = MediaCodec::AdpcmMs;
      f.formatTag = kMicrosoftAdpcmAudioFormatTag;
    } else return {};
    f.framesPerPacket = out.blockFrames;
  }
  return out;
}

// ALAC's explicit frame count begins at bit 23; absent means frameLength.
[[nodiscard]] inline std::uint32_t alacPacketFrames(
    std::span<const std::byte> bytes, std::uint32_t maximum) noexcept {
  if (bytes.size() < 3) return 0;
  if ((std::to_integer<unsigned>(bytes[2]) & 0x10U) == 0) return maximum;
  if (bytes.size() < 7) return 0;
  std::uint32_t frames = 0;
  for (unsigned bit = 23; bit < 55; ++bit)
    frames = (frames << 1U) | ((std::to_integer<unsigned>(bytes[bit/8]) >>
                               (7U-bit%8)) & 1U);
  return frames <= maximum ? frames : 0;
}

} // namespace wam::media::matroska
