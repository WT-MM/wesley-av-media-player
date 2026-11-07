#pragma once

#include "media/native_media_source.hpp"
#include "media/adpcm_audio.hpp"
#include "media/adpcm_decoder.hpp"
#include "media/media_codec_facts.hpp"
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
    f.formatTag = mediaCodecFacts(MediaCodec::Alac).coreAudioFormatTag;
    f.formatFlags = depth == 16 ? 1U : depth == 20 ? 2U : depth == 24 ? 3U : 4U;
    f.framesPerPacket = out.blockFrames;
    out.cookie = bytes;
  } else if (id == "A_PCM/INT/LIT" || id == "A_PCM/FLOAT/IEEE") {
    const bool floating = id == "A_PCM/FLOAT/IEEE";
    if (!bytes.empty() || (floating ? depth != 32 :
        (depth != 8 && depth != 16 && depth != 24 && depth != 32))) return {};
    out.codec = MediaCodec::Pcm;
    f.formatTag = mediaCodecFacts(MediaCodec::Pcm).coreAudioFormatTag;
    // Matroska integer PCM is unsigned at 8 bits and signed above 8 bits.
    f.formatFlags = 8U | (floating ? 1U : depth == 8 ? 0U : 4U);
    f.framesPerPacket = 1;
    f.bitsPerChannel = depth;
    f.bytesPerFrame = channels * (depth / 8U);
    f.bytesPerPacket = f.bytesPerFrame;
  } else if (id == "A_MS/ACM") {
    const auto adpcm = parseAdpcmWaveFormat(bytes, rate, channels);
    if (!adpcm) return {};
    const bool ima = adpcm->tag == 17;
    out.codec = ima ? MediaCodec::AdpcmIma : MediaCodec::AdpcmMs;
    f.formatTag = ima ? mediaCodecFacts(MediaCodec::AdpcmIma).coreAudioFormatTag
                      : kMicrosoftAdpcmAudioFormatTag;
    f.bytesPerPacket = adpcm->blockBytes;
    out.blockFrames = adpcm->blockFrames;
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
