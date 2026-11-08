#pragma once

#include "core_media_codec_facts.hpp"
#include "media/audio_downmix.hpp"
#include "media/media_codec_facts.hpp"
#include "media/native_media_source.hpp"
#include "native_audio_sample_rates.hpp"

#include <algorithm>
#include <cstdint>
#include <optional>
#include <vector>

namespace wam::macos {

struct AdmittedAudio {
  // The track's exact integer sample rate.
  std::uint32_t sampleRate{0};
  // Decoded by libavcodec rather than AudioToolbox.
  bool software{false};
};

// Vorbis is the one AudioToolbox decoder this route uses that is not present
// on every supported macOS release: it is admitted only where the system
// lists 'vorb' among its decode formats, so older releases fall back.
[[nodiscard]] inline bool audioToolboxDecodesVorbis() noexcept {
  static const bool present = [] {
    UInt32 size = 0;
    if (AudioFormatGetPropertyInfo(kAudioFormatProperty_DecodeFormatIDs, 0,
                                   nullptr, &size) != noErr) {
      return false;
    }
    std::vector<UInt32> formats(size / sizeof(UInt32));
    if (AudioFormatGetProperty(kAudioFormatProperty_DecodeFormatIDs, 0,
                               nullptr, &size, formats.data()) != noErr) {
      return false;
    }
    formats.resize(size / sizeof(UInt32));
    return std::find(formats.begin(), formats.end(),
                     media::mediaCodecFacts(media::MediaCodec::Vorbis)
                         .coreAudioFormatTag) != formats.end();
  }();
  return present;
}

// The native audio route's track admission, asked by the session preflight
// (so an inadmissible track is a clean fallback) and again by the converter
// at configure (so a direct caller cannot bypass it). Software codecs are
// admitted only when WAM_ENABLE_AVCODEC_STAGE is built, and carry their raw
// CodecPrivate bytes; every other codec carries an AudioToolbox magic cookie
// or no configuration at all.
[[nodiscard]] inline std::optional<AdmittedAudio>
admitAudioTrack(const media::MediaTrackDescriptor &track) noexcept {
  if (track.id == 0 || track.kind != media::MediaTrackKind::Audio ||
      !track.audio) {
    return std::nullopt;
  }
  const media::MediaAudioFormat &audio = *track.audio;
  if (track.codec == media::MediaCodec::Vorbis && !audioToolboxDecodesVorbis()) {
    return std::nullopt;
  }
  const bool software = media::softwareAudioCodec(track.codec);
#if !defined(WAM_ENABLE_AVCODEC_STAGE)
  if (software) {
    return std::nullopt;
  }
#endif
  const bool configurationAdmitted =
      software ? track.codecConfigurationKind ==
                     media::MediaCodecConfigurationKind::CodecPrivate
               : track.codecConfigurationKind ==
                     (track.codecConfiguration.empty()
                          ? media::MediaCodecConfigurationKind::None
                          : media::MediaCodecConfigurationKind::AudioMagicCookie);
  AdmittedAudio admitted{0, software};
  if ((software ? audio.formatTag != 0
                : !audioCodecFormatTagAdmitted(track.codec, audio.formatTag)) ||
      audio.channels == 0 ||
      audio.channels > media::kMaximumDownmixSourceChannels ||
      !audio.interleaved || audio.framesPerPacket == 0 ||
      !audioChannelLayoutAdmitted(audio) ||
      !nativeAudioSampleRateSupported(audio.sampleRate,
                                      &admitted.sampleRate) ||
      track.codecConfiguration.size() >
          media::MediaSourceLimits::kHardMaximumCodecConfigurationBytes ||
      !configurationAdmitted) {
    return std::nullopt;
  }
  return admitted;
}

} // namespace wam::macos
