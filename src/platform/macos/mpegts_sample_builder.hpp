#pragma once

#include "media/codec/aac.hpp"
#include "media/mpegts_demuxer.hpp"
#include "media/native_media_source.hpp"
#include "platform/macos/core_media_carriage.hpp"

#include <CoreMedia/CoreMedia.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace wam::macos {

// Internal boundary shared by the MPEG-TS CoreMedia consumers (the main media
// source and the scrub preview source), mirroring
// `matroska_sample_builder.hpp`. The format description and the sample-buffer
// assembly itself are the shared carriage in core_media_carriage.hpp.
//
// Nothing here is part of the shipping surface of `mpegts_media_source.hpp`;
// this header is included only by MPEG-TS backend translation units.

using MpegTsSampleBuildStatus = CompressedSampleBuildStatus;

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
  // Byte offset into the PES payload at which each access unit's first bit
  // lives, and how far into that byte. Stated explicitly rather than derived as
  // `sourceSize - outputSize`, because that derivation silently assumes the
  // access unit ends where the frame does and begins on a byte boundary --
  // true of ADTS, AC-3 and MPEG audio, and false of LOAS/LATM, whose
  // AudioMuxElement opens with a single useSameStreamMux bit and therefore
  // starts its access unit at bit 1 + 8k of the frame.
  std::array<std::uint32_t, kMaximumMpegTsAudioFrames> outputOffset{};
  std::array<std::uint8_t, kMaximumMpegTsAudioFrames> outputBitShift{};
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
// `latmConfig` is the StreamMuxConfig the demuxer proved at preparation, and it
// is what distinguishes the two AAC framings: non-null means LOAS/LATM, null
// means ADTS. MediaCodec::Aac alone cannot say, and must not -- the two are one
// codec with one cookie and one frame grid, differing only in framing.
//
// It is REQUIRED for LATM rather than rediscovered per payload: a LOAS frame
// that reuses the established config carries none of its own, and the frame a
// generation starts on after a seek is almost never the one that carried it.
//
// `partialTail`, when non-null, admits ONE trailing partial ADTS frame: an
// access unit that commences in this PES and continues in the next, which
// 13818-1 permits (a PES need not align to access units). Its offset is
// stored there (payload.size() when the payload ends on a frame boundary) and
// the frames before it are laid out as usual; the count may then be zero. The
// remainder is only admitted as a frame PREFIX -- a header that parses with
// the admitted format and states a length past the end, or fewer bytes than a
// header -- so a desynchronized payload is still refused, and the caller's
// walk over the joined bytes proves the prefix when the next PES arrives.
[[nodiscard]] bool layOutMpegTsAudioFrames(
    std::span<const std::byte> payload, media::MediaCodec codec,
    const media::mpegts::LatmStreamMuxConfig* latmConfig,
    std::uint32_t sampleRate, std::uint32_t channels,
    std::uint32_t framesPerPacket, MpegTsAudioFrameLayout& layout,
    std::string* error, std::size_t* partialTail = nullptr) noexcept;

// Fixed ADTS header (protection_absent = 1) and the largest frame its 13-bit
// frame_length can state.
inline constexpr std::size_t kAdtsHeaderBytes{7};
inline constexpr std::size_t kMaximumAdtsFrameBytes{8191};

// Where the first ADTS access unit COMMENCING in a PES payload begins, for a
// PES that opens with the tail of an access unit the generation never saw
// begin (a seek lands on any PES). 13818-1 2.4.3.7 ties the PES timestamp to
// that access unit, so this is also where the PES timestamp applies. The
// answer is the first offset whose header states the admitted format and from
// which whole frames chain to the end of the payload (ending, at most, in one
// partial frame). A candidate that merely looks like a header is refused one
// header later -- the walk over the next PES must find a header exactly where
// the chain predicts -- rather than decoded as audio. Empty when no access
// unit commences in the payload. `layout` is scratch.
[[nodiscard]] std::optional<std::size_t> findAdtsAccessUnitStart(
    std::span<const std::byte> payload, std::uint32_t sampleRate,
    std::uint32_t channels, std::uint32_t framesPerPacket,
    MpegTsAudioFrameLayout& layout) noexcept;

struct MpegTsSampleBuildInputs {
  const media::mpegts::MpegTsPreparedAsset* asset{nullptr};
  media::CancellationToken cancellation{};
  CMFormatDescriptionRef format{nullptr};
  media::MediaCodec codec{media::MediaCodec::Unknown};
  bool video{true};
  // Gather workspace for H.264/HEVC video. Annex-B to AVCC cannot size its
  // output before the input is assembled, so the gather lands here first. See
  // the note in the implementation for the copy the shape costs and why it is
  // deliberately not optimized away unmeasured.
  std::vector<std::byte>* workspace{nullptr};
  // Audio only: the access units to frame, already gathered by the source.
  // Not the cursor sample's own payload, because an ADTS access unit may begin
  // in an earlier PES; the source joins them.
  std::span<const std::byte> audioPayload{};
  MpegTsAudioFrameLayout* audioLayout{nullptr};
  // Audio only, AAC only: non-null selects LOAS/LATM framing. See
  // layOutMpegTsAudioFrames.
  const media::mpegts::LatmStreamMuxConfig* latmConfig{nullptr};
  std::uint32_t audioSampleRate{0};
  std::uint32_t audioChannels{0};
  std::uint32_t audioFramesPerPacket{0};
  // Audio only: the exact presentation timestamp the source derived from its
  // own frame-grid ordinal, which is NOT the PES timestamp. See
  // mpegts_media_source.mm for why the container's 90 kHz stamp cannot be
  // published verbatim for a 44.1 kHz track.
  media::MediaTime audioPresentationTime{};
  // Audio only, AAC only: this generation's implicit-SBR check
  // (AacImplicitSbrCheck). Null checks nothing.
  media::codec::AacImplicitSbrCheck* aacSbrCheck{nullptr};
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
    ScopedSampleBuffer* out, std::string* error);

}  // namespace wam::macos
