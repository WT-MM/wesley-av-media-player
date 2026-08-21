#pragma once

#include "media/mpegts_demuxer.hpp"
#include "media/native_media_source.hpp"

#include <CoreMedia/CoreMedia.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace wam::macos {

// Internal boundary shared by the MPEG-TS CoreMedia consumers, mirroring
// `matroska_sample_builder.hpp`: the main media source and any future preview
// source must hand VideoToolbox the byte-identical format description and the
// identically assembled sample buffer, because the decoder compares the
// description it was configured with against the one every sample carries.
//
// Nothing here is part of the shipping surface of `mpegts_media_source.hpp`;
// this header is included only by MPEG-TS backend translation units.

// Owns the +1 on one retained CoreMedia buffer.
class MpegTsScopedSampleBuffer final {
 public:
  MpegTsScopedSampleBuffer() noexcept = default;
  explicit MpegTsScopedSampleBuffer(CMSampleBufferRef owned) noexcept
      : value_(owned) {}
  ~MpegTsScopedSampleBuffer() {
    if (value_ != nullptr) {
      CFRelease(value_);
    }
  }

  MpegTsScopedSampleBuffer(MpegTsScopedSampleBuffer&& other) noexcept
      : value_(other.value_) {
    other.value_ = nullptr;
  }
  MpegTsScopedSampleBuffer& operator=(MpegTsScopedSampleBuffer&& other) noexcept {
    if (this != &other) {
      if (value_ != nullptr) {
        CFRelease(value_);
      }
      value_ = other.value_;
      other.value_ = nullptr;
    }
    return *this;
  }
  MpegTsScopedSampleBuffer(const MpegTsScopedSampleBuffer&) = delete;
  MpegTsScopedSampleBuffer& operator=(const MpegTsScopedSampleBuffer&) = delete;

  [[nodiscard]] CMSampleBufferRef get() const noexcept { return value_; }
  [[nodiscard]] CMSampleBufferRef release() noexcept {
    CMSampleBufferRef owned = value_;
    value_ = nullptr;
    return owned;
  }

 private:
  CMSampleBufferRef value_{nullptr};
};

// Owns the +1 on one retained CoreMedia buffer for the lifetime of every lease
// taken against it. Shape copied from the AVFoundation and Matroska storages so
// the native video consumer and the audio converter accept MPEG-TS samples
// unchanged.
class MpegTsCoreMediaSampleStorage final : public media::MediaPayloadStorage {
 public:
  MpegTsCoreMediaSampleStorage(CMSampleBufferRef ownedSample,
                               std::size_t byteSize) noexcept;
  ~MpegTsCoreMediaSampleStorage() override;

  MpegTsCoreMediaSampleStorage(const MpegTsCoreMediaSampleStorage&) = delete;
  MpegTsCoreMediaSampleStorage& operator=(const MpegTsCoreMediaSampleStorage&) =
      delete;

  [[nodiscard]] std::size_t byteSize() const noexcept override;
  [[nodiscard]] std::span<const std::byte>
  contiguousBytes() const noexcept override;
  [[nodiscard]] bool copyBytes(
      std::size_t offset,
      std::span<std::byte> destination) const noexcept override;

 protected:
  [[nodiscard]] std::optional<media::NativePayloadKind>
  nativePayloadKind() const noexcept override;
  [[nodiscard]] const void* borrowedNativePayload() const noexcept override;

 private:
  CMSampleBufferRef sample_{nullptr};
  std::size_t byte_size_{0};
};

// Exact sum of two container rationals, in 128 bits. Copied from the
// AVFoundation and Matroska backends so all three answer decodeOnly
// identically for the same interval.
[[nodiscard]] std::optional<media::MediaTime> mpegTsCheckedExactTimeSum(
    media::MediaTime lhs, media::MediaTime rhs) noexcept;

// True when the sample's whole presentation interval closes at or before the
// accurate-seek target, which is exactly the decodeOnly predicate.
[[nodiscard]] std::optional<bool> mpegTsAccurateVideoDecodeOnly(
    media::MediaTime presentationTime, media::MediaTime duration,
    media::MediaTime target, std::string* error) noexcept;

[[nodiscard]] const char* mpegTsDemuxErrorNameForMessage(
    media::mpegts::MpegTsDemuxError error) noexcept;

// The neutral header owns no FileChanged status, so a mid-stream identity
// change has to travel as a MediaSourceFailure. Naming the demuxer error
// inside the message keeps that fact recoverable by an owner that must
// distinguish a swapped file from an ordinary read error.
[[nodiscard]] std::string mpegTsDemuxErrorMessage(
    const char* what, media::mpegts::MpegTsDemuxError error);

// Two video shapes, and exactly two.
//
//  * H.264 arrives as Annex-B with in-band SPS/PPS. The demuxer synthesized an
//    avcC from those parameter sets and the shared codec inspector already
//    admitted it, so the record travels to CoreMedia verbatim as an `avcC`
//    sample-description extension atom, exactly as the Matroska path does.
//  * MPEG-2 needs NO extensions dictionary at all. Its sequence header is
//    in-band and `CMVideoFormatDescriptionCreate` accepts a null extensions
//    argument -- measured in scratchpad/vt_mpeg2_probe.mm, where a session
//    built this way decoded 60 access units 1:1.
[[nodiscard]] CMVideoFormatDescriptionRef createMpegTsVideoFormatDescription(
    const media::MediaTrackDescriptor& track) noexcept;

enum class MpegTsSampleBuildStatus : std::uint8_t {
  Built,
  Cancelled,
  Failed,
};

// Largest number of whole audio access units one PES payload may carry. The
// frozen source limit caps a compressed audio sample at 1,024 access units and
// the converter refuses more, so a PES that frames more than this is refused
// rather than truncated.
inline constexpr std::size_t kMaximumMpegTsAudioFrames{
    media::MediaSourceLimits::kHardMaximumAudioSampleCount};

// Where each admitted audio access unit lives inside a gathered PES payload,
// and how large it is once its framing header has been stripped. This is a
// workspace, not a value: it is ~24 KiB and lives as a member of the source.
struct MpegTsAudioFrameLayout {
  std::array<std::uint32_t, kMaximumMpegTsAudioFrames> sourceOffset{};
  std::array<std::uint32_t, kMaximumMpegTsAudioFrames> sourceSize{};
  std::array<std::size_t, kMaximumMpegTsAudioFrames> outputSize{};
  std::size_t count{0};
  std::size_t outputBytes{0};
  std::uint64_t decodedFrames{0};

  void reset() noexcept {
    count = 0;
    outputBytes = 0;
    decodedFrames = 0;
  }
};

// Splits one gathered PES payload into whole audio access units.
//
// Every codec MPEG-TS carries here is self-framing, and each states its frame
// length in its own header: ADTS states the whole frame length including the
// 7- or 9-byte header, which is stripped because an AudioConverter configured
// from an ES_Descriptor magic cookie wants raw AAC; AC-3/E-AC-3 and MPEG audio
// state a length that stays whole because their decoders read the frame header
// themselves and take no cookie at all.
//
// A payload that does not divide exactly into whole frames is refused. The
// alternative -- decoding the frames that did parse and dropping a trailing
// remainder -- is the silent-drop failure mode, and here it would also break
// the exact frame-grid continuity the converter checks on the NEXT sample.
[[nodiscard]] bool layOutMpegTsAudioFrames(std::span<const std::byte> payload,
                                           media::MediaCodec codec,
                                           std::uint32_t sampleRate,
                                           std::uint32_t channels,
                                           std::uint32_t framesPerPacket,
                                           MpegTsAudioFrameLayout& layout,
                                           std::string* error) noexcept;

struct MpegTsSampleBuildInputs {
  const media::mpegts::MpegTsPreparedAsset* asset{nullptr};
  media::mpegts::CancellationToken cancellation{};
  CMFormatDescriptionRef format{nullptr};
  media::MediaCodec codec{media::MediaCodec::Unknown};
  bool video{true};
  // Video only: the exact repack workspace. Annex-B to AVCC cannot size its
  // output before the input is assembled, so the gather lands here first. See
  // the note in the implementation for the copy the shape costs and why it is
  // deliberately not optimized away unmeasured.
  std::vector<std::byte>* workspace{nullptr};
  // Audio only.
  MpegTsAudioFrameLayout* audioLayout{nullptr};
  std::uint32_t audioSampleRate{0};
  std::uint32_t audioChannels{0};
  std::uint32_t audioFramesPerPacket{0};
  // Audio only: the exact presentation timestamp the source derived from its
  // own frame-grid ordinal, which is NOT the PES timestamp. See
  // mpegts_media_source.mm for why the container's 90 kHz stamp cannot be
  // published verbatim for a 44.1 kHz track.
  media::MediaTime audioPresentationTime{};
};

// Materializes one payload-free cursor sample into a retained CMSampleBuffer.
//
// Timing is the load-bearing decision. Container rationals are carried straight
// into CMTimeMake as {value, timescale}; converting through seconds would
// reintroduce exactly the rounding the demuxer was built to avoid. Unlike the
// Matroska builder the decode stamp is REAL: a PES header carries an explicit
// DTS and the demuxer publishes it, so VideoToolbox is handed the stream's own
// decode order rather than being left to infer it from submission order.
[[nodiscard]] MpegTsSampleBuildStatus buildMpegTsCompressedSampleBuffer(
    const MpegTsSampleBuildInputs& inputs,
    const media::mpegts::MpegTsCompressedSample& sample,
    MpegTsScopedSampleBuffer* out, std::string* error);

}  // namespace wam::macos
