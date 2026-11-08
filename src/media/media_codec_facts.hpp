#pragma once

#include "media/codec/ac3.hpp"
#include "media/codec/mpeg_audio.hpp"
#include "media/codec/opus.hpp"
#include "media/adpcm_audio.hpp"
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
// enumerator to build noise. The lookup below is an index into one table
// whose size and row order are covered by static_asserts against the
// enumerator count, so an append-only MediaCodec addition is a compile
// diagnostic at exactly one place.
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
  // deliberately a separate field from carriesConfigurationRecord: MPEG-2
  // carries no record and pins, while MPEG-4 Part 2 carries a record AND
  // decodes to '2vuy'.
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
  // still parsed, in band, into a stated sample format. ProRes, ProRes 4444 and
  // Motion JPEG are the false rows, and their gate is stronger rather than
  // weaker -- all three pin their decode output format and have every delivered surface validated
  // against that pin, which is what a parsed record only ever predicted.
  bool statesCodedSampleFormat{false};

  // True where the scrub-preview lane can decode this codec. A preview decodes
  // from a key frame forward and shows the first frame it gets, so what it
  // needs is a codec whose decoder is available unconditionally on this
  // machine; the lane selects decoders exactly as main playback does, so VP8
  // previews through the software stage. AV1, VP9 and ProRes 4444 are the false
  // video rows: AV1 and VP9 are gated on a decode block the preview lane has no
  // fallback for.
  //
  // The preview SOURCE and the preview LANE both read this field. A codec one
  // admits and the other refuses turns a scrub into a latched failure.
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
  // Vorbis states zero here and sets decoderLeadInIsOnePacket instead.
  std::uint16_t decoderLeadInFrames{0};

  bool requiresMjpegHeaderInspection{false};

  // The canonical CoreAudio AudioFormatID of an audio codec, as a plain
  // integer so this header stays platform-neutral; the platform layer asserts
  // each against its kAudioFormat* constant. Zero for video and for the
  // software-decoded audio codecs, which never reach an AudioConverter.
  std::uint32_t coreAudioFormatTag{0};

  // The decoder's lead-in is exactly one access unit rather than a constant:
  // Vorbis' first packet carries only the left half of an overlap-add window
  // and decodes to zero samples by specification. Measured invariant across
  // fresh converters and across AudioConverterReset alike, which is why Vorbis
  // can use the cheap reset that Opus cannot.
  bool decoderLeadInIsOnePacket{false};

  // The decoder flushes at the end as many frames as it swallowed at the head,
  // so the track decodes to exactly the frame count its packets declare even
  // though its first emitted frame sits decoderLeadInFrames into the packet
  // grid. MP3: 529 in, 529 out.
  bool decoderFlushesLeadInAtEnd{false};

  // Frames the decoder stops short of the end of the stream and never emits.
  std::uint16_t decoderTailShortfallFrames{0};

  // The final packet may decode up to one packet less one frame short of the
  // declared budget, so the tail shortfall bound is framesPerPacket - 1.
  bool decoderTailShortfallBelowOnePacket{false};

  // AudioConverterReset does not restore this decoder's priming state, so a
  // reset must rebuild the converter instead.
  bool decoderResetRebuilds{false};

  // Frames a decoder must decode and discard after a seek before its output
  // converges, where the codec states more than two access units' worth.
  std::uint16_t seekPrerollFrames{0};

  // Decoded by the libavcodec software stage rather than AudioToolbox.
  bool softwareDecoded{false};

  // The codec's first access unit legitimately presents BEFORE media time
  // zero; see audioCodecPrecedesStreamOrigin for what that relaxes.
  bool precedesStreamOrigin{false};

  // The lead-in Apple's decoder swallows is part of the stream's presentation:
  // ffmpeg and mpv play those frames from access unit 0's own timestamp. A
  // container that states the lead-in as a delay (Matroska CodecDelay, an
  // MP4 edit) moves access unit 0 early by it; one that states nothing puts
  // the decoder's first output leadIn frames after access unit 0. See
  // firstDecodableAudioTime.
  bool decoderLeadInIsPresentedMedia{false};

  // The reorder depth of a video codec whose configuration record states none,
  // a property of the codec rather than of the stream. H.264, HEVC and AV1
  // derive theirs from the record and state zero here.
  std::uint8_t intrinsicReorderDepth{0};
};

inline constexpr std::array<MediaCodecFacts, 25> kMediaCodecFacts{{
    {.codec = MediaCodec::Unknown, .kind = MediaCodecKind::Unknown},
    {.codec = MediaCodec::H264, .kind = MediaCodecKind::Video,
     .coreMediaType = 0x61766331U /* 'avc1' */,
     .configurationKind = MediaCodecConfigurationKind::AvcC,
     .configurationAtomName = "avcC", .carriesConfigurationRecord = true,
     .requiresHardwareDecode = true, .statesCodedSampleFormat = true,
     .previewScrubAdmitted = true, .avfoundationVideoAdmitted = true},
    {.codec = MediaCodec::Hevc, .kind = MediaCodecKind::Video,
     .coreMediaType = 0x68766331U /* 'hvc1' */,
     .configurationKind = MediaCodecConfigurationKind::HvcC,
     .configurationAtomName = "hvcC", .carriesConfigurationRecord = true,
     .requiresHardwareDecode = true, .statesCodedSampleFormat = true,
     .previewScrubAdmitted = true, .avfoundationVideoAdmitted = true},
    {.codec = MediaCodec::Av1, .kind = MediaCodecKind::Video,
     .coreMediaType = 0x61763031U /* 'av01' */,
     .configurationKind = MediaCodecConfigurationKind::Av1C,
     .configurationAtomName = "av1C", .carriesConfigurationRecord = true,
     .requiresHardwareDecode = true, .statesCodedSampleFormat = true,
     .avfoundationVideoAdmitted = true},
    // VP9 has no output reordering. Alternate-reference ("hidden") frames are
    // decoded but never output at their own decode position; they reach the
    // output only through show_existing_frame, which emits an already-decoded
    // frame at the point the bitstream asks for it. Output order therefore
    // equals bitstream order, which is why VP9 containers carry PTS == DTS on
    // every packet. The vpcC record carries no reorder signal at all.
    {.codec = MediaCodec::Vp9, .kind = MediaCodecKind::Video,
     .coreMediaType = 0x76703039U /* 'vp09' */,
     .configurationKind = MediaCodecConfigurationKind::VpcC,
     .configurationAtomName = "vpcC", .carriesConfigurationRecord = true,
     .requiresHardwareDecode = true, .statesCodedSampleFormat = true,
     .avfoundationVideoAdmitted = true},
    // AAC states one 1024-frame access unit of encoder priming whenever the
    // mux encoded rather than copied the track.
    {.codec = MediaCodec::Aac, .kind = MediaCodecKind::Audio,
     .coreAudioFormatTag = 0x61616320U /* 'aac ' */,
     .precedesStreamOrigin = true},
    // Structurally FLAC's tail bound, for a different reason than the codec:
    // on the AVFoundation route the shortfall is manufactured by this player.
    // An MP4's stts states the final ALAC packet's true length -- 272 frames of
    // a 4096-frame grid on the measured fixture -- but
    // restateCompressedAudioPacketDurations (avfoundation_media_source.mm)
    // lengthens every short trailing unit back to mFramesPerPacket, because
    // that is the correct end-trim fix for AAC, whose 1024-frame packet
    // genuinely decodes 1024 frames and whose trim really is an edit. ALAC's
    // final packet genuinely holds fewer frames -- the count is in the ALAC
    // frame header, which is how AudioToolbox decodes it exactly -- so the
    // restatement inflates the budget by up to one packet and the decoder can
    // never reach it. The bound is exactly the largest inflation that
    // restatement can produce, one packet less one frame.
    {.codec = MediaCodec::Alac, .kind = MediaCodecKind::Audio,
     .coreAudioFormatTag = 0x616C6163U /* 'alac' */,
     .decoderTailShortfallBelowOnePacket = true},
    // MP3 swallows 529 frames at the head and flushes exactly 529 more at the
    // end, so the track still decodes to the frame count its packets declare
    // even though its content sits 529 frames earlier than the packet grid
    // alone would say. It precedes the origin by the LAME encoder delay plus
    // that 529-frame decoder delay (1105 frames from every ffmpeg mux).
    {.codec = MediaCodec::Mp3, .kind = MediaCodecKind::Audio,
     .decoderLeadInFrames =
         static_cast<std::uint16_t>(codec::kMpegLayer3DecoderDelayFrames),
     .coreAudioFormatTag = 0x2E6D7033U /* '.mp3' */,
     .decoderFlushesLeadInAtEnd = true, .precedesStreamOrigin = true},
    // AudioConverterReset does NOT restore an Opus converter's priming state:
    // measured, a reset converter emits the decoder's 120-frame startup
    // transient as real output instead of swallowing it, so the same stream
    // decodes to a different frame count depending on whether the generation
    // was configured or flushed. Rebuilding the converter restores the single
    // invariant the whole Opus trim is derived from.
    {.codec = MediaCodec::Opus, .kind = MediaCodecKind::Audio,
     .decoderLeadInFrames =
         static_cast<std::uint16_t>(codec::kOpusDecoderDelayFrames),
     .coreAudioFormatTag = 0x6F707573U /* 'opus' */,
     .decoderResetRebuilds = true,
     .seekPrerollFrames =
         static_cast<std::uint16_t>(codec::kOpusSeekPrerollFrames),
     .precedesStreamOrigin = true},
    // 'vorb'. AudioToolbox registers a Vorbis decoder under this fourcc --
    // kAudioFormatProperty_DecodeFormatIDs reports it -- but publishes no
    // kAudioFormatVorbis constant for it. Vorbis precedes the origin for
    // Opus' structural reason stated differently by the format: its first
    // packet decodes to no samples, so access unit 0 presents one block before
    // media zero. Where Opus states the offset as a CodecDelay/pre-skip field,
    // Vorbis implies it, but it lands in exactly the same arithmetic.
    {.codec = MediaCodec::Vorbis, .kind = MediaCodecKind::Audio,
     .coreAudioFormatTag = 0x766F7262U /* 'vorb' */,
     .decoderLeadInIsOnePacket = true, .precedesStreamOrigin = true},
    {.codec = MediaCodec::Pcm, .kind = MediaCodecKind::Audio,
     .coreAudioFormatTag = 0x6C70636DU /* 'lpcm' */},
    // VP8 has no VideoToolbox decoder on any Apple platform and is decoded by
    // the libvpx software stage, which reads the vpcC record directly. The
    // four-character code is the ISO Media binding's own VP8 sample entry name
    // rather than an invented one, and VideoToolbox refuses it -- which is what
    // keeps a VP8 stream from ever reaching a decompression session.
    {.codec = MediaCodec::Vp8, .kind = MediaCodecKind::Video,
     .coreMediaType = 0x76703038U /* 'vp08' */,
     .configurationKind = MediaCodecConfigurationKind::VpcC,
     .carriesConfigurationRecord = true, .statesCodedSampleFormat = true,
     .previewScrubAdmitted = true},
    // AC-3 and E-AC-3: Apple's decoder swallows 256 leading frames that the
    // stream presents (the encoder's priming). ffmpeg states them as a
    // 256-frame CodecDelay, so access unit 0 presents 256 frames early.
    {.codec = MediaCodec::Ac3, .kind = MediaCodecKind::Audio,
     .decoderLeadInFrames =
         static_cast<std::uint16_t>(codec::kAc3DecoderDelayFrames),
     .coreAudioFormatTag = 0x61632D33U /* 'ac-3' */,
     .decoderTailShortfallFrames =
         static_cast<std::uint16_t>(codec::kAc3DecoderTailShortfallFrames),
     .precedesStreamOrigin = true,
     .decoderLeadInIsPresentedMedia = true},
    {.codec = MediaCodec::Eac3, .kind = MediaCodecKind::Audio,
     .decoderLeadInFrames =
         static_cast<std::uint16_t>(codec::kAc3DecoderDelayFrames),
     .coreAudioFormatTag = 0x65632D33U /* 'ec-3' */,
     .decoderTailShortfallFrames =
         static_cast<std::uint16_t>(codec::kAc3DecoderTailShortfallFrames),
     .precedesStreamOrigin = true,
     .decoderLeadInIsPresentedMedia = true},
    // The final FLAC frame carries at least one sample and at most a whole
    // block. FLAC states no CodecDelay and its decoder swallows nothing, so
    // its access unit 0 is media frame 0 exactly: it deliberately does NOT
    // precede the origin even though it states an exact decoded duration.
    {.codec = MediaCodec::Flac, .kind = MediaCodecKind::Audio,
     .coreAudioFormatTag = 0x666C6163U /* 'flac' */,
     .decoderTailShortfallBelowOnePacket = true},
    // Reorder depth one, and it is a property of the codec rather than of the
    // stream. MPEG-2 reorders through exactly two reference frame stores: a B
    // picture is output at its own decode position, and the only picture ever
    // held back is the FUTURE anchor decoded ahead of the B pictures that
    // reference it. That is true regardless of how many consecutive B pictures
    // a GOP codes -- an M of 3 and an M of 12 both hold exactly one anchor --
    // so the depth is 1 for every legal MPEG-2 stream and never needs a
    // bitstream parse.
    //
    // Stating 1 rather than 0 costs one retained frame on a stream that codes
    // no B pictures at all, which both of this project's MPEG-2 fixtures are
    // (ffmpeg's mpeg2video encoder defaults to max_b_frames = 0). That is one
    // frame of startup hold at SD rates and the right side to be wrong on:
    // understating the depth reorders output, while overstating it by one
    // delays it by one frame.
    {.codec = MediaCodec::Mpeg2Video, .kind = MediaCodecKind::Video,
     .coreMediaType = 0x6D703276U /* 'mp2v' */,
     .needsPinnedOutputPixelFormat = true, .statesCodedSampleFormat = true,
     .previewScrubAdmitted = true, .intrinsicReorderDepth = 1},
    // MPEG-4 Part 2's record is the esds the Matroska demuxer synthesizes
    // around the CodecPrivate headers. Only Simple Profile is admitted for
    // VideoToolbox, and that gate is upstream on the bitstream headers.
    //
    // Reorder depth zero is a property of the admitted PROFILE rather than of
    // the codec. MPEG-4 Part 2 as a whole reorders exactly like MPEG-2, but
    // B-VOPs are an Advanced Simple Profile tool, and Apple's 'mp4v' decoder
    // refuses that profile at session creation, so
    // media::inspectMpeg4VisualHeaders() admits Simple Profile alone. Simple
    // Profile codes I-VOPs and P-VOPs only, so decode order IS presentation
    // order -- which is also why the Matroska route's missing decode
    // timestamps cost this codec nothing.
    {.codec = MediaCodec::Mpeg4Visual, .kind = MediaCodecKind::Video,
     .coreMediaType = 0x6D703476U /* 'mp4v' */,
     .configurationKind = MediaCodecConfigurationKind::CodecPrivate,
     .configurationAtomName = "esds", .carriesConfigurationRecord = true,
     .needsPinnedOutputPixelFormat = true, .statesCodedSampleFormat = true,
     .previewScrubAdmitted = true},
    // ProRes, ProRes 4444 and Motion JPEG are ALL-INTRA by construction: every
    // ProRes frame is independently coded and Motion JPEG is a sequence of
    // independent JPEG images, so decode order IS presentation order and the
    // reorder depth is honestly zero rather than a defensive one.
    {.codec = MediaCodec::ProRes, .kind = MediaCodecKind::Video,
     .coreMediaType = 0x6170636EU /* 'apcn' */,
     .needsPinnedOutputPixelFormat = true, .previewScrubAdmitted = true,
     .avfoundationVideoAdmitted = true},
    {.codec = MediaCodec::Mjpeg, .kind = MediaCodecKind::Video,
     .coreMediaType = 0x6A706567U /* 'jpeg' */,
     .needsPinnedOutputPixelFormat = true, .previewScrubAdmitted = true,
     .avfoundationVideoAdmitted = true, .requiresMjpegHeaderInspection = true},
    {.codec = MediaCodec::AdpcmIma, .kind = MediaCodecKind::Audio,
     .coreAudioFormatTag = 0x6D730011U /* kAudioFormatDVIIntelIMA */},
    {.codec = MediaCodec::AdpcmMs, .kind = MediaCodecKind::Audio,
     .coreAudioFormatTag = kMicrosoftAdpcmAudioFormatTag},
    // Opaque presentation ignores alpha in packed RGB10; chroma is not subsampled.
    {.codec = MediaCodec::ProRes4444, .kind = MediaCodecKind::Video,
     .coreMediaType = 0x61703468U /* 'ap4h' */,
     .needsPinnedOutputPixelFormat = true, .requiresHardwareDecode = true,
     .avfoundationVideoAdmitted = true},
    {.codec = MediaCodec::Dts, .kind = MediaCodecKind::Audio,
     .softwareDecoded = true},
    {.codec = MediaCodec::TrueHd, .kind = MediaCodecKind::Audio,
     .softwareDecoded = true},
    {.codec = MediaCodec::Mlp, .kind = MediaCodecKind::Audio,
     .softwareDecoded = true},
}};

// CoreAudio's mono and stereo channel layout tags (kAudioChannelLayoutTag_Mono
// and _Stereo), as plain integers; the platform layer asserts both.
inline constexpr std::uint32_t kCoreAudioMonoLayoutTag{0x00640001U};
inline constexpr std::uint32_t kCoreAudioStereoLayoutTag{0x00650002U};

// Mono and stereo keep their exact canonical tags. A WIDER layout states no
// tag at all, deliberately.
//
// A demuxer knows a channel COUNT; it does not know AudioToolbox's
// per-codec channel-order convention, and its decoders emit three different
// 5.1 orders (AAC C L R Ls Rs LFE, AC-3 and E-AC-3 L C R Ls Rs LFE, FLAC
// L R C LFE Ls Rs). Inventing a CoreAudio tag here would be guessing at that
// convention, and a wrong guess puts dialogue in the surround channel with no
// other symptom. AudioConverter reports the identical output channel layout
// whether or not an input layout is supplied, so supplying none costs nothing
// and the platform layer reads the authoritative order back from the decoder
// itself.
inline void applyChannelLayoutTag(MediaAudioFormat* format,
                                  std::uint32_t channelCount) noexcept {
  if (channelCount == 1) {
    format->channelLayoutTag = kCoreAudioMonoLayoutTag;
    format->channelLayoutPresent = true;
    return;
  }
  if (channelCount == 2) {
    format->channelLayoutTag = kCoreAudioStereoLayoutTag;
    format->channelLayoutPresent = true;
    return;
  }
  format->channelLayoutTag = 0;
  format->channelLayoutPresent = false;
}

[[nodiscard]] constexpr bool mediaSampleFormatIs422(MediaVideoSampleFormat format) noexcept {
  return format == MediaVideoSampleFormat::Yuv422EightBit ||
         format == MediaVideoSampleFormat::Yuv422TenBit;
}

[[nodiscard]] constexpr unsigned mediaSampleFormatDepth(MediaVideoSampleFormat format) noexcept {
  switch (format) {
  case MediaVideoSampleFormat::Yuv420EightBit:
  case MediaVideoSampleFormat::Yuv422EightBit:
  case MediaVideoSampleFormat::Yuv444EightBit: return 8;
  case MediaVideoSampleFormat::Yuv420TenBit:
  case MediaVideoSampleFormat::Yuv422TenBit: return 10;
  default: return 0;
  }
}

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

// The frames Apple's decoder swallows at the head of a track: the stated
// constant, or one whole access unit where the codec says so (Vorbis).
[[nodiscard]] constexpr std::uint32_t decoderLeadInFrames(
    MediaCodec codec, std::uint32_t framesPerPacket) noexcept {
  const MediaCodecFacts &facts = mediaCodecFacts(codec);
  return facts.decoderLeadInIsOnePacket ? framesPerPacket
                                        : facts.decoderLeadInFrames;
}

[[nodiscard]] constexpr bool softwareAudioCodec(MediaCodec codec) noexcept {
  return mediaCodecFacts(codec).softwareDecoded;
}

// The last enumerator of the frozen, append-only MediaCodec. Appending one
// without adding its row fails the coverage assertion below.
inline constexpr MediaCodec kLastMediaCodec = MediaCodec::Mlp;
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
// contracts with distinct enumerators.
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
  if (coreMediaType == 0x61703478U) {
    return MediaCodec::ProRes4444;
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
         facts.avfoundationVideoAdmitted || facts.intrinsicReorderDepth != 0)) {
      return false;
    }
    if (stated &&
        (facts.coreAudioFormatTag != 0 || facts.decoderLeadInFrames != 0 ||
         facts.decoderLeadInIsOnePacket || facts.decoderFlushesLeadInAtEnd ||
         facts.decoderTailShortfallFrames != 0 ||
         facts.decoderTailShortfallBelowOnePacket ||
         facts.decoderResetRebuilds)) {
      return false;
    }
    const bool appleAudio =
        facts.kind == MediaCodecKind::Audio && !softwareAudioCodec(facts.codec);
    if (appleAudio != (facts.coreAudioFormatTag != 0)) {
      return false;
    }
  }
  return true;
}

} // namespace detail

static_assert(detail::mediaCodecCoreMediaTypesRoundTrip(),
              "exactly the video rows state a four-character code and the "
              "video-only fields, each code names its own codec back, and "
              "exactly the Apple-decoded audio rows state an AudioFormatID");

} // namespace wam::media
