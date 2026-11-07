#pragma once
#include "media/native_media_source.hpp"
#include <cstddef>
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
// Software decode worker limits, one worker per player window (asserted in
// platform/macos/native_surface_budget.hpp). Decoder admission charges
// softwareDecoderReservation against them.
inline constexpr std::uint64_t kNativeSoftwareMaximumPicturePixels = MediaSourceLimits::kHardMaximumCodedPixels;
inline constexpr std::size_t kNativeSoftwarePacketSlots = 4;
inline constexpr std::size_t kNativeSoftwarePacketBytes = 4U * 1024U * 1024U;
inline constexpr std::size_t kNativeSoftwarePacketPaddingBytes = 64;
inline constexpr std::size_t kNativeSoftwareWorkerPacketStorageBytes =
    kNativeSoftwarePacketSlots * (kNativeSoftwarePacketBytes + kNativeSoftwarePacketPaddingBytes);
inline constexpr unsigned kNativeSoftwareDecoderThreads = 1;
inline constexpr unsigned kNativeSoftwareProcessWorkers = 16;
// A combined software audio/video session reserves two workers; eight consume all sixteen.
inline constexpr unsigned kNativeSoftwareCombinedAudioVideoWorkers = 2;
inline constexpr std::size_t kNativeSoftwareAudioConversionScratchBytes = 4096U * 8U * sizeof(float);
inline constexpr std::size_t kNativeSoftwareSessionConversionScratchBytes =
    kNativeSoftwarePacketBytes + kNativeSoftwareAudioConversionScratchBytes;
inline constexpr std::size_t kNativeSoftwareProcessPacketStorageBytes =
    kNativeSoftwareProcessWorkers * kNativeSoftwareWorkerPacketStorageBytes;
static_assert(kNativeSoftwareWorkerPacketStorageBytes == 16'777'472);
static_assert(kNativeSoftwareSessionConversionScratchBytes == 4'325'376);
static_assert(kNativeSoftwareProcessPacketStorageBytes == 268'439'552);
static_assert(kNativeSoftwareProcessWorkers * kNativeSoftwareDecoderThreads == 16);
inline constexpr std::uint64_t kSoftwarePrivateAllocationMaximumBytes = 384ULL << 20;
inline constexpr std::uint64_t kSoftwareProcessReservationMaximumBytes = 2ULL << 30;
// Capacity includes aligned allocation headers; the worker allocator enforces ancillary storage too.
[[nodiscard]] constexpr std::optional<SoftwareDecoderReservation> softwareDecoderReservation(
    MediaCodec codec, std::uint32_t width, std::uint32_t height,
    unsigned depth, unsigned chroma, std::uint64_t extradata) noexcept {
  if(extradata > MediaSourceLimits::kHardMaximumCodecConfigurationBytes) return {};
  SoftwareDecoderReservation r;
  r.packetBytes=kNativeSoftwareWorkerPacketStorageBytes;
  r.extradataBytes=2*(extradata+64);
  const bool audio=codec==MediaCodec::Dts || codec==MediaCodec::TrueHd || codec==MediaCodec::Mlp;
  if(audio) {
    r.conversionBytes=kNativeSoftwareAudioConversionScratchBytes;
    r.privateScratchBytes=16ULL<<20;
  } else {
    if(!MediaSourceLimits::codedDimensionsWithinHardCeiling(width,height) ||
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
