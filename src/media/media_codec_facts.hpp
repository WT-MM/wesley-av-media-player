#pragma once

#include "media/matroska_ac3.hpp"
#include "media/matroska_mpeg_audio.hpp"
#include "media/matroska_opus.hpp"
#include "media/native_media_source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>

namespace wam::media {

// The per-codec facts every layer of this player has to agree on, stated once.
//
// Each fact here answers a question that admission, decode configuration and
// the preview lane all ask, and a codec one layer admits while another refuses
// -- or silently mis-decodes -- is the failure this table exists to make
// unrepresentable. Nothing in this project compiles with -Werror, so a fact
// restated as an if-chain with a silent `default:` arm loses a newly appended
// enumerator to build noise. The lookup below is an exhaustive switch with no
// default and the table is covered by a static_assert on the enumerator count,
// so an append-only MediaCodec addition is a compile diagnostic at exactly one
// place.
//
// Every consumer of this table is on an open/admission path, never on a
// per-sample or per-frame path, so a constexpr array read costs nothing that
// matters.

// MediaCodec names video and audio codecs only. Subtitle formats are carried by
// MediaTrackKind and their own descriptors, never by a MediaCodec enumerator,
// which is why this enumeration has no Subtitle value to state.
enum class MediaCodecKind : std::uint8_t {
  Unknown,
  Video,
  Audio,
};

struct MediaCodecFacts {
  MediaCodec codec{MediaCodec::Unknown};
  MediaCodecKind kind{MediaCodecKind::Unknown};

  // The CoreMedia four-character code a format description of this codec
  // states, as a plain integer so this header stays platform-neutral. Zero for
  // audio codecs and for Unknown: an audio track is described by an
  // AudioFormatID, and one codec can be reached by several of them (see
  // audioCodecFormatTagAdmitted in the platform layer), so there is no single
  // code to state here.
  //
  // ProRes states the CANONICAL member of its 422 family. The family has four
  // codes and VideoToolbox decodes them interchangeably;
  // mediaCodecForCoreMediaType maps all four back to this one enumerator.
  std::uint32_t coreMediaType{0};

  // The configuration-record kind a VIDEO track of this codec must present in
  // its descriptor.
  //
  // The three record fields below are asked of video tracks only. An audio
  // track's record kind is a property of the CONTAINER rather than of the
  // codec -- Matroska states a magic cookie for AAC and nothing for AC-3, and a
  // transport stream states neither -- so every audio row holds the neutral
  // value and the assertion below keeps it there, rather than stating a codec
  // fact that would be wrong for one of the containers.
  MediaCodecConfigurationKind configurationKind{
      MediaCodecConfigurationKind::None};

  // The sample-description extension atom a CoreMedia format description of
  // this codec carries the record in. Empty when there is no atom: either
  // because the codec carries no record at all, or -- for VP8 -- because its
  // record never reaches CoreMedia, the software stage reading it directly.
  //
  // Deliberately NOT derived from configurationKind: MPEG-4 Part 2's record
  // kind is CodecPrivate (the contract names no Esds enumerator) while its atom
  // is 'esds', and VP8's kind is VpcC with no atom at all.
  const char *configurationAtomName{nullptr};

  // False for a codec with NO out-of-band decoder configuration record, so that
  // an EMPTY record is its only correct descriptor and "no atom" is the
  // admitted shape rather than a missing one.
  bool carriesConfigurationRecord{false};

  // True for a codec whose VideoToolbox decoder does not natively produce a
  // bi-planar 4:2:0 surface, so the session's destination attributes must pin
  // the output pixel format.
  //
  // This is a property of the DECODER's native output and nothing else. It is
  // deliberately a separate field from carriesConfigurationRecord, which was
  // true of MPEG-2 for an unrelated reason and selected the right codec only
  // while MPEG-2 was the sole legacy decoder here: MPEG-4 Part 2 carries a
  // record AND decodes to '2vuy'.
  bool needsPinnedOutputPixelFormat{false};

  // True where a decompression session may REQUIRE hardware decode. False for
  // every codec whose only decoder on some host this build targets is software:
  // requiring hardware there turns a decode that works into
  // kVTCouldNotFindVideoDecoderErr and a fallback. ProRes is false for that
  // reason rather than for lack of a block -- Apple Silicon decodes it in
  // hardware, Intel hosts on the 13.3 deployment target do not. Every route
  // still PREFERS hardware; only the requirement varies.
  bool requiresHardwareDecode{false};

  // True where a descriptor states this codec's CODED sample format, so the
  // admission gates may prove the decoded surface will be 4:2:0 by reading it.
  //
  // Deliberately NOT carriesConfigurationRecord, which is the same set minus
  // MPEG-2: MPEG-2 carries no out-of-band record and its sequence header is
  // still parsed, in band, into a stated sample format. ProRes and Motion JPEG
  // are the false rows, and their gate is stronger rather than weaker -- both
  // pin their decode output format and have every delivered surface validated
  // against that pin, which is what a parsed record only ever predicted.
  bool statesCodedSampleFormat{false};

  // True where the scrub-preview lane can decode this codec. A preview decodes
  // from a key frame forward and shows the first frame it gets, so what it
  // needs is a codec whose VideoToolbox decoder is available unconditionally on
  // this machine. AV1, VP9 and VP8 are the false video rows: the first two are
  // gated on a decode block the preview lane has no fallback for, and VP8's
  // software stage is not wired into that lane at all.
  //
  // The preview SOURCE and the preview LANE both read this field. A codec one
  // admits and the other refuses turns a scrub into a latched failure, which is
  // exactly what a second whitelist produced for ProRes and Motion JPEG.
  bool previewScrubAdmitted{false};

  // True where AVFoundation demuxes this codec into this pipeline in a shape
  // the native route admits. False for the three video codecs that reach this
  // player only through its own demuxers -- VP8 and MPEG-4 Part 2 from
  // Matroska, MPEG-2 from a transport stream -- and for every audio codec,
  // whose AVFoundation admission is a measured envelope stated at its own site.
  bool avfoundationVideoAdmitted{false};

  // Frames Apple's decoder swallows at the head of a track before it emits its
  // first PCM frame. A generation places access unit 0 exactly this many frames
  // BEFORE the presentation origin, and the converter labels the decoder's
  // first output frame packet0 + this, so the source's decode start and the
  // converter's first published frame meet on the presentation floor.
  //
  // Vorbis is absent by construction and states zero here: its lead-in is one
  // access unit -- the first packet carries half an overlap-add window and
  // decodes to no samples -- so it is the PACKET LENGTH rather than a constant,
  // and the one site that needs it supplies that length itself.
  std::uint16_t decoderLeadInFrames{0};
};

inline constexpr std::array<MediaCodecFacts, 21> kMediaCodecFacts{{
    {MediaCodec::Unknown, MediaCodecKind::Unknown, 0,
     MediaCodecConfigurationKind::None, nullptr, false, false, false, false,
     false, false, 0},
    {MediaCodec::H264, MediaCodecKind::Video, 0x61766331U /* 'avc1' */,
     MediaCodecConfigurationKind::AvcC, "avcC", true, false, true, true, true,
     true, 0},
    {MediaCodec::Hevc, MediaCodecKind::Video, 0x68766331U /* 'hvc1' */,
     MediaCodecConfigurationKind::HvcC, "hvcC", true, false, true, true, true,
     true, 0},
    {MediaCodec::Av1, MediaCodecKind::Video, 0x61763031U /* 'av01' */,
     MediaCodecConfigurationKind::Av1C, "av1C", true, false, true, true, false,
     true, 0},
    {MediaCodec::Vp9, MediaCodecKind::Video, 0x76703039U /* 'vp09' */,
     MediaCodecConfigurationKind::VpcC, "vpcC", true, false, true, true, false,
     true, 0},
    {MediaCodec::Aac, MediaCodecKind::Audio, 0,
     MediaCodecConfigurationKind::None, nullptr, false, false, false, false,
     false, false, 0},
    {MediaCodec::Alac, MediaCodecKind::Audio, 0,
     MediaCodecConfigurationKind::None, nullptr, false, false, false, false,
     false, false, 0},
    // MP3 swallows 529 frames at the head and flushes exactly 529 more at the
    // end, so the track still decodes to the frame count its packets declare
    // even though its content sits 529 frames earlier than the packet grid
    // alone would say. That second half of the fact is
    // decoderFrameDeficitFrames in the converter, which is a DIFFERENT question
    // and stays separate.
    {MediaCodec::Mp3, MediaCodecKind::Audio, 0,
     MediaCodecConfigurationKind::None, nullptr, false, false, false, false,
     false, false,
     static_cast<std::uint16_t>(matroska::kMpegLayer3DecoderDelayFrames)},
    {MediaCodec::Opus, MediaCodecKind::Audio, 0,
     MediaCodecConfigurationKind::None, nullptr, false, false, false, false,
     false, false,
     static_cast<std::uint16_t>(matroska::kOpusDecoderDelayFrames)},
    {MediaCodec::Vorbis, MediaCodecKind::Audio, 0,
     MediaCodecConfigurationKind::None, nullptr, false, false, false, false,
     false, false, 0},
    {MediaCodec::Pcm, MediaCodecKind::Audio, 0,
     MediaCodecConfigurationKind::None, nullptr, false, false, false, false,
     false, false, 0},
    // VP8 has no VideoToolbox decoder on any Apple platform and is decoded by
    // the libvpx software stage, which reads the vpcC record directly. The
    // four-character code is the ISO Media binding's own VP8 sample entry name
    // rather than an invented one, and VideoToolbox refuses it -- which is what
    // keeps a VP8 stream from ever reaching a decompression session.
    {MediaCodec::Vp8, MediaCodecKind::Video, 0x76703038U /* 'vp08' */,
     MediaCodecConfigurationKind::VpcC, nullptr, true, false, false, true,
     false, false, 0},
    {MediaCodec::Ac3, MediaCodecKind::Audio, 0,
     MediaCodecConfigurationKind::None, nullptr, false, false, false, false,
     false, false,
     static_cast<std::uint16_t>(matroska::kAc3DecoderDelayFrames)},
    {MediaCodec::Eac3, MediaCodecKind::Audio, 0,
     MediaCodecConfigurationKind::None, nullptr, false, false, false, false,
     false, false,
     static_cast<std::uint16_t>(matroska::kAc3DecoderDelayFrames)},
    {MediaCodec::Flac, MediaCodecKind::Audio, 0,
     MediaCodecConfigurationKind::None, nullptr, false, false, false, false,
     false, false, 0},
    {MediaCodec::Mpeg2Video, MediaCodecKind::Video, 0x6D703276U /* 'mp2v' */,
     MediaCodecConfigurationKind::None, nullptr, false, true, false, true, true,
     false, 0},
    // MPEG-4 Part 2's record is the esds the Matroska demuxer synthesizes
    // around the CodecPrivate headers. Only Simple Profile is admitted, and
    // that gate is upstream on the bitstream headers.
    {MediaCodec::Mpeg4Visual, MediaCodecKind::Video, 0x6D703476U /* 'mp4v' */,
     MediaCodecConfigurationKind::CodecPrivate, "esds", true, true, false, true,
     true, false, 0},
    {MediaCodec::ProRes, MediaCodecKind::Video, 0x6170636EU /* 'apcn' */,
     MediaCodecConfigurationKind::None, nullptr, false, true, false, false,
     true, true, 0},
    {MediaCodec::Mjpeg, MediaCodecKind::Video, 0x6A706567U /* 'jpeg' */,
     MediaCodecConfigurationKind::None, nullptr, false, true, false, false,
     true, true, 0},
    {MediaCodec::AdpcmIma, MediaCodecKind::Audio, 0,
     MediaCodecConfigurationKind::None, nullptr, false, false, false, false,
     false, false, 0},
    {MediaCodec::AdpcmMs, MediaCodecKind::Audio, 0,
     MediaCodecConfigurationKind::None, nullptr, false, false, false, false,
     false, false, 0},
}};

// The row for a codec.
//
// Rows sit at their enumerator's ordinal (proved by the assertions below), so
// the lookup is an index. An enumerator appended to the frozen enum without a
// row here lands on the Unknown row, which admits nothing: the file falls back
// rather than being decoded under another codec's facts. kLastMediaCodec is
// the one place that must move with such an append.
[[nodiscard]] constexpr const MediaCodecFacts &
mediaCodecFacts(MediaCodec codec) noexcept {
  const auto index = static_cast<std::size_t>(codec);
  return kMediaCodecFacts[index < kMediaCodecFacts.size() ? index : 0U];
}

// The last enumerator of the frozen, append-only MediaCodec. Appending one
// without adding its row fails the coverage assertion below.
inline constexpr MediaCodec kLastMediaCodec = MediaCodec::AdpcmMs;
inline constexpr std::size_t kMediaCodecCount =
    static_cast<std::size_t>(kLastMediaCodec) + 1U;

static_assert(kMediaCodecFacts.size() == kMediaCodecCount,
              "every MediaCodec enumerator needs exactly one facts row");

namespace detail {

// Each row sits at its own enumerator's ordinal and states its own codec, so
// the lookup above cannot be wired to the wrong row.
[[nodiscard]] constexpr bool mediaCodecFactsRowsAreOrdered() noexcept {
  for (std::size_t index = 0; index < kMediaCodecFacts.size(); ++index) {
    const auto codec = static_cast<MediaCodec>(index);
    if (kMediaCodecFacts[index].codec != codec ||
        &mediaCodecFacts(codec) != &kMediaCodecFacts[index]) {
      return false;
    }
  }
  return true;
}

} // namespace detail

static_assert(detail::mediaCodecFactsRowsAreOrdered(),
              "each facts row must sit at its own enumerator's ordinal");

// The four-character codes of the ProRes 422 family, and exactly that family.
//
// VideoToolbox decodes these four INTERCHANGEABLY: a session created from a
// synthesized description of any one of them decodes real samples of any other.
// The 4444 family ('ap4h'/'ap4x') is interchangeable within itself and NOT with
// this one -- feeding 4444 samples to a 422-family session fails with -12916,
// and the reverse fails identically -- so the two are different decode
// contracts and only this one has an enumerator to be named by.
inline constexpr std::array<std::uint32_t, 4> kProRes422FamilyCoreMediaTypes{
    0x6170636FU /* 'apco', Proxy */, 0x61706373U /* 'apcs', LT */,
    0x6170636EU /* 'apcn', 422 */, 0x61706368U /* 'apch', HQ */};

// The codec a CoreMedia four-character code names, or Unknown for a code this
// player has no enumerator for.
//
// This is the inverse of the coreMediaType field and is proven to be exactly
// that by the assertion below; the ProRes family is the one place where the
// mapping is many-to-one.
[[nodiscard]] constexpr MediaCodec
mediaCodecForCoreMediaType(std::uint32_t coreMediaType) noexcept {
  if (coreMediaType == 0) {
    return MediaCodec::Unknown;
  }
  for (const std::uint32_t proRes : kProRes422FamilyCoreMediaTypes) {
    if (coreMediaType == proRes) {
      return MediaCodec::ProRes;
    }
  }
  for (const MediaCodecFacts &facts : kMediaCodecFacts) {
    if (facts.coreMediaType == coreMediaType) {
      return facts.codec;
    }
  }
  return MediaCodec::Unknown;
}

namespace detail {

[[nodiscard]] constexpr bool mediaCodecCoreMediaTypesRoundTrip() noexcept {
  for (const MediaCodecFacts &facts : kMediaCodecFacts) {
    const bool stated = facts.coreMediaType != 0;
    if (stated != (facts.kind == MediaCodecKind::Video)) {
      return false;
    }
    if (stated &&
        mediaCodecForCoreMediaType(facts.coreMediaType) != facts.codec) {
      return false;
    }
    if (!stated &&
        (facts.configurationKind != MediaCodecConfigurationKind::None ||
         facts.configurationAtomName != nullptr ||
         facts.carriesConfigurationRecord ||
         facts.needsPinnedOutputPixelFormat || facts.requiresHardwareDecode ||
         facts.statesCodedSampleFormat || facts.previewScrubAdmitted ||
         facts.avfoundationVideoAdmitted)) {
      return false;
    }
  }
  return true;
}

} // namespace detail

static_assert(detail::mediaCodecCoreMediaTypesRoundTrip(),
              "exactly the video rows state a four-character code and the "
              "video-only fields, and each code names its own codec back");

} // namespace wam::media
