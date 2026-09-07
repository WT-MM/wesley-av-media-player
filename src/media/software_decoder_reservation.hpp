#pragma once
#include "media/native_media_source.hpp"
#include <cstdint>
#include <optional>
namespace wam::media {
struct SoftwareDecoderReservation {
  std::uint64_t packetBytes{}, extradataBytes{}, conversionBytes{};
  std::uint64_t planeBytes{}, referenceBytes{}, privateScratchBytes{}, privateBytes{};
  std::uint32_t referenceSlots{}, workers{1};
  [[nodiscard]] constexpr std::uint64_t totalBytes() const noexcept {
    return packetBytes + extradataBytes + conversionBytes + privateBytes;
  }
};
inline constexpr std::uint64_t kSoftwarePrivateAllocationMaximumBytes = 384ULL << 20;
inline constexpr std::uint64_t kSoftwareProcessReservationMaximumBytes = 2ULL << 30;
// Capacity includes aligned allocation headers; the worker allocator enforces ancillary storage too.
[[nodiscard]] constexpr std::optional<SoftwareDecoderReservation> softwareDecoderReservation(
    MediaCodec codec, std::uint32_t width, std::uint32_t height,
    unsigned depth, unsigned chroma, std::uint64_t extradata) noexcept {
  if(extradata > MediaSourceLimits::kHardMaximumCodecConfigurationBytes) return {};
  SoftwareDecoderReservation r;
  r.packetBytes=4ULL*((4ULL<<20)+64);
  r.extradataBytes=2*(extradata+64);
  const bool audio=codec==MediaCodec::Dts || codec==MediaCodec::TrueHd || codec==MediaCodec::Mlp;
  if(audio) {
    r.conversionBytes=4096ULL*8*sizeof(float);
    r.privateScratchBytes=16ULL<<20;
  } else {
    if(!width || !height || std::uint64_t(width)*height>MediaSourceLimits::kHardMaximumCodedPixels ||
       width>MediaSourceLimits::kHardMaximumCodedWidth || height>MediaSourceLimits::kHardMaximumCodedWidth ||
       (depth!=8 && depth!=10) || (chroma!=1 && chroma!=2)) return {};
    if(codec==MediaCodec::H264) r.referenceSlots=38;
    else if(codec==MediaCodec::Mpeg4Visual && depth==8 && chroma==1) r.referenceSlots=8;
    else if(codec==MediaCodec::Vp9) r.referenceSlots=28;
    else return {};
    const std::uint64_t w=(width+127ULL)&~127ULL, h=(height+127ULL)&~127ULL;
    const auto bytes=depth==8?1ULL:2ULL;
    const auto luma=(w*bytes+63)&~63ULL, chromaStride=(w/2*bytes+63)&~63ULL;
    r.planeBytes=luma*h+2*chromaStride*(chroma==1?h/2:h)+3*64;
    r.referenceBytes=r.planeBytes*r.referenceSlots;
    r.privateScratchBytes=8ULL<<20;
    r.conversionBytes=4ULL<<20;
  }
  r.privateBytes=r.referenceBytes+r.privateScratchBytes;
  if(r.privateBytes>kSoftwarePrivateAllocationMaximumBytes) return {};
  return r;
}
}
