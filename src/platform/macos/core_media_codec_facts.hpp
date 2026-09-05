#pragma once

#include "media/adpcm_audio.hpp"
#include "media/matroska_vorbis.hpp"
#include "media/media_codec_facts.hpp"
#include "media/native_media_source.hpp"
#include "native_audio_channel_map.hpp"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>

#include <array>
#include <cstdint>
#include <cstring>

namespace wam::macos {

// The CoreMedia and AudioToolbox bindings of the neutral per-codec facts table.
//
// media/media_codec_facts.hpp stays platform-neutral -- it states four-character
// codes as integers and atom names as plain strings -- so the Apple constants
// those stand for are tied to it here, once, and proven to agree at compile
// time where the language allows and by coreMediaConfigurationAtomsMatchFacts()
// where it does not.

static_assert(media::mediaCodecFacts(media::MediaCodec::H264).coreMediaType ==
                  static_cast<std::uint32_t>(kCMVideoCodecType_H264),
              "the facts table's four-character code must be CoreMedia's");
static_assert(media::mediaCodecFacts(media::MediaCodec::Hevc).coreMediaType ==
                  static_cast<std::uint32_t>(kCMVideoCodecType_HEVC),
              "the facts table's four-character code must be CoreMedia's");
static_assert(media::mediaCodecFacts(media::MediaCodec::Av1).coreMediaType ==
                  static_cast<std::uint32_t>(kCMVideoCodecType_AV1),
              "the facts table's four-character code must be CoreMedia's");
static_assert(media::mediaCodecFacts(media::MediaCodec::Vp9).coreMediaType ==
                  static_cast<std::uint32_t>(kCMVideoCodecType_VP9),
              "the facts table's four-character code must be CoreMedia's");
static_assert(
    media::mediaCodecFacts(media::MediaCodec::Mpeg2Video).coreMediaType ==
        static_cast<std::uint32_t>(kCMVideoCodecType_MPEG2Video),
    "the facts table's four-character code must be CoreMedia's");
static_assert(
    media::mediaCodecFacts(media::MediaCodec::Mpeg4Visual).coreMediaType ==
        static_cast<std::uint32_t>(kCMVideoCodecType_MPEG4Video),
    "the facts table's four-character code must be CoreMedia's");
static_assert(media::mediaCodecFacts(media::MediaCodec::ProRes).coreMediaType ==
                  static_cast<std::uint32_t>(kCMVideoCodecType_AppleProRes422),
              "the facts table's four-character code must be CoreMedia's");
static_assert(media::mediaCodecFacts(media::MediaCodec::Mjpeg).coreMediaType ==
                  static_cast<std::uint32_t>(kCMVideoCodecType_JPEG),
              "the facts table's four-character code must be CoreMedia's");
static_assert(
    media::kProRes422FamilyCoreMediaTypes ==
        std::array<std::uint32_t, 4>{
            static_cast<std::uint32_t>(kCMVideoCodecType_AppleProRes422Proxy),
            static_cast<std::uint32_t>(kCMVideoCodecType_AppleProRes422LT),
            static_cast<std::uint32_t>(kCMVideoCodecType_AppleProRes422),
            static_cast<std::uint32_t>(kCMVideoCodecType_AppleProRes422HQ)},
    "the facts table's ProRes family must be CoreMedia's four 422 codes");

[[nodiscard]] inline CMVideoCodecType coreMediaCodecType(
    media::MediaCodec codec) noexcept {
  return static_cast<CMVideoCodecType>(
      media::mediaCodecFacts(codec).coreMediaType);
}

// The sample-description extension atom a format description of this codec
// carries its configuration record in, or null when the codec has no atom.
//
// CFSTR values are compile-time constants, so this stays allocation-free and is
// legal on the per-sample format-change path that compares a live format
// description against the admitted track. The switch is exhaustive over the
// atom names the facts table states, and coreMediaConfigurationAtomsMatchFacts()
// proves the two spellings agree.
[[nodiscard]] inline CFStringRef coreMediaConfigurationAtomName(
    media::MediaCodec codec) noexcept {
  switch (media::mediaCodecFacts(codec).configurationKind) {
  case media::MediaCodecConfigurationKind::AvcC:
    return CFSTR("avcC");
  case media::MediaCodecConfigurationKind::HvcC:
    return CFSTR("hvcC");
  case media::MediaCodecConfigurationKind::Av1C:
    return CFSTR("av1C");
  case media::MediaCodecConfigurationKind::VpcC:
    // VP9 is the only codec whose vpcC atom reaches CoreMedia. VP8 states the
    // same record kind and no atom: its record is read by the libvpx software
    // stage directly and never travels in a format description, which is why
    // the facts table -- not this record kind -- is what decides.
    return media::mediaCodecFacts(codec).configurationAtomName == nullptr
               ? nullptr
               : CFSTR("vpcC");
  case media::MediaCodecConfigurationKind::CodecPrivate:
    // MPEG-4 Part 2. The format description must carry an 'esds' -- the
    // ISO/IEC 14496-1 ES_Descriptor wrapping the VisualObjectSequence -- or
    // VTDecompressionSessionCreate fails: the raw headers in band, or an
    // ES_Descriptor missing the box's four version/flags bytes, both return
    // kVTVideoDecoderBadDataErr (-12909).
    return CFSTR("esds");
  case media::MediaCodecConfigurationKind::None:
  case media::MediaCodecConfigurationKind::AudioMagicCookie:
    return nullptr;
  }
  return nullptr;
}

// Proof that the CFSTR spellings above are the facts table's own. Called from
// the tests rather than asserted, because a CFStringRef is not a constant
// expression and the two spellings can only be compared at run time.
[[nodiscard]] inline bool coreMediaConfigurationAtomsMatchFacts() noexcept {
  for (const media::MediaCodecFacts& facts : media::kMediaCodecFacts) {
    const CFStringRef atom = coreMediaConfigurationAtomName(facts.codec);
    if (facts.configurationAtomName == nullptr) {
      if (atom != nullptr) {
        return false;
      }
      continue;
    }
    if (atom == nullptr) {
      return false;
    }
    char spelled[8] = {};
    if (!CFStringGetCString(atom, spelled, sizeof(spelled),
                            kCFStringEncodingASCII) ||
        std::strcmp(spelled, facts.configurationAtomName) != 0) {
      return false;
    }
  }
  return true;
}

// The AudioToolbox format identifiers this player admits, per codec.
//
// One codec can be reached by several of them, which is why this is a table of
// (codec, tag) pairs rather than a field in the neutral facts table: an
// AudioFormatID names a bitstream flavour the table has no enumerator for.
struct AdmittedAudioFormatTag {
  media::MediaCodec codec;
  std::uint32_t formatTag;
};

inline constexpr std::array<AdmittedAudioFormatTag, 14> kAdmittedAudioFormatTags{{
    {media::MediaCodec::Aac, kAudioFormatMPEG4AAC},
    {media::MediaCodec::Aac, kAudioFormatMPEG4AAC_HE},
    {media::MediaCodec::Aac, kAudioFormatMPEG4AAC_HE_V2},
    {media::MediaCodec::Alac, kAudioFormatAppleLossless},
    // Uncompressed audio, which reaches this pipeline only from AVFoundation: a
    // standalone .wav or .aiff, or an lpcm track in a QuickTime movie. There is
    // no bitstream to parse and no decoder to prime, so the converter's whole
    // per-codec table stays at its zero defaults; what the AudioConverter does
    // for it is the interleaved-int-to-float restatement it would otherwise do
    // as the last step of every decode. The format's own flags carry the sample
    // depth, signedness and endianness, and exactAsbd already restates them
    // verbatim, which is what lets one row cover .wav (0xc) and .aiff (0xe)
    // alike.
    {media::MediaCodec::Pcm, kAudioFormatLinearPCM},
    // ADPCM in WAV. Constant-bit-rate like LPCM (mBytesPerPacket 1024), so it
    // rides the CBR input-proc arm unchanged; unlike LPCM it is a real decode,
    // and it is admitted because that decode was measured bit-exact against
    // ffmpeg with a zero-frame lead-in.
    {media::MediaCodec::AdpcmIma, kAudioFormatDVIIntelIMA},
    {media::MediaCodec::AdpcmMs, media::kMicrosoftAdpcmAudioFormatTag},
    // MediaCodec::Mp3 is the MPEG-1/2 audio ROUTING FAMILY, not one layer.
    // Matroska only ever reaches this row with Layer III, but a transport
    // stream's stream types 0x03/0x04 carry Layer I, II or III and broadcast
    // MPEG-2 is overwhelmingly Layer II. Layer II is admitted because it was
    // measured, not assumed: '.mp2' is among kAudioFormatProperty_DecodeFormatIDs
    // on this platform, and a real 115-frame MP2 elementary stream decodes to
    // exactly 115 x 1152 = 132,480 PCM frames through an AudioConverter created
    // with mFormatID = kAudioFormatMPEGLayer2 and no magic cookie. Layer I is
    // deliberately NOT admitted: the format ID is listed but no fixture of this
    // project exercises it, and an unmeasured admission is exactly the shape of
    // bug this audio path has been bitten by before.
    {media::MediaCodec::Mp3, kAudioFormatMPEGLayer3},
    {media::MediaCodec::Mp3, kAudioFormatMPEGLayer2},
    {media::MediaCodec::Opus, kAudioFormatOpus},
    {media::MediaCodec::Vorbis, media::matroska::kVorbisAudioFormatTag},
    {media::MediaCodec::Ac3, kAudioFormatAC3},
    {media::MediaCodec::Eac3, kAudioFormatEnhancedAC3},
    {media::MediaCodec::Flac, kAudioFormatFLAC},
}};

namespace detail {

// Every audio codec in the facts table admits at least one tag and no video
// codec admits any, so a codec cannot be routed to the converter without a
// stated bitstream flavour.
[[nodiscard]] constexpr bool admittedAudioFormatTagsCoverAudioCodecs() noexcept {
  for (const media::MediaCodecFacts &facts : media::kMediaCodecFacts) {
    bool admitted = false;
    for (const AdmittedAudioFormatTag &entry : kAdmittedAudioFormatTags) {
      admitted = admitted || entry.codec == facts.codec;
    }
    if (admitted != (facts.kind == media::MediaCodecKind::Audio)) {
      return false;
    }
  }
  return true;
}

} // namespace detail

static_assert(detail::admittedAudioFormatTagsCoverAudioCodecs(),
              "each audio codec admits at least one AudioToolbox format tag "
              "and no video codec admits any");

[[nodiscard]] constexpr bool audioCodecFormatTagAdmitted(
    media::MediaCodec codec, std::uint32_t formatTag) noexcept {
  for (const AdmittedAudioFormatTag &entry : kAdmittedAudioFormatTags) {
    if (entry.codec == codec && entry.formatTag == formatTag) {
      return true;
    }
  }
  return false;
}

// Mono and stereo must state their canonical tag or none at all, and a
// multichannel track may state a tag only when that tag expands to a stereo
// fold this player can perform exactly. An unrecognised label makes the whole
// track inadmissible -- a clean fallback -- rather than a channel this path
// would silently drop.
//
// The audio session asks this before the converter does, so an inadmissible
// layout produces a clean fallback instead of a converter failure part-way
// through graph construction.
[[nodiscard]] inline bool audioChannelLayoutAdmitted(
    const media::MediaAudioFormat& audio) noexcept {
  if (!audio.channelLayoutPresent) {
    return audio.channelLayoutTag == 0;
  }
  if (audio.channels == 1) {
    return audio.channelLayoutTag == kAudioChannelLayoutTag_Mono;
  }
  if (audio.channels == 2) {
    return audio.channelLayoutTag == kAudioChannelLayoutTag_Stereo;
  }
  return multichannelLayoutTagAdmitted(audio.channelLayoutTag, audio.channels);
}

} // namespace wam::macos
