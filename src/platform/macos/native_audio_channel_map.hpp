#pragma once

#include "media/audio_downmix.hpp"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudioTypes/CoreAudioTypes.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

namespace wam::macos {

// CoreAudio channel layout -> neutral downmix roles.
//
// THE TRAP THIS EXISTS FOR. AudioToolbox hands back a different channel order
// for every codec family, measured on one identical 5.1 tone fixture:
//
//   AAC-LC 5.1   tag 0x007C0006 (MPEG_5_1_D)  C  L  R  Ls Rs LFE
//   AC-3 5.1     tag 0x007B0006 (MPEG_5_1_C)  L  C  R  Ls Rs LFE
//   E-AC-3 5.1   tag 0x007B0006 (MPEG_5_1_C)  L  C  R  Ls Rs LFE
//   FLAC 5.1     tag 0x00790006 (MPEG_5_1_A)  L  R  C  LFE Ls Rs
//
// Index 1 is the centre channel for AC-3 and the LEFT channel for AAC; index 3
// is LFE for FLAC and left surround for the other three. Any mapping written
// against a channel INDEX therefore mixes dialogue into the wrong place for at
// least one codec. Every lookup here goes through the label.
//
// The layout is read back from the converter itself
// (kAudioConverterOutputChannelLayout) rather than from the container, because
// the converter normalises what it is given: a FLAC file stating tag
// 0x00BB0006 (labels ... Rls Rrs) is reported back as 0x00790006 (labels
// ... Ls Rs). Only the converter's own answer describes the bytes it will
// actually write.

// Enough descriptions for any layout this player admits, with generous slack
// so a tag that expands wider than expected is REFUSED on the size check
// rather than silently truncated.
inline constexpr std::size_t kMaximumChannelLayoutDescriptions{64};

[[nodiscard]] inline media::AudioChannelRole
roleForChannelLabel(AudioChannelLabel label) noexcept {
  switch (label) {
  case kAudioChannelLabel_Left:
    return media::AudioChannelRole::Left;
  case kAudioChannelLabel_Right:
    return media::AudioChannelRole::Right;
  case kAudioChannelLabel_Center:
    return media::AudioChannelRole::Center;
  case kAudioChannelLabel_LFEScreen:
  case kAudioChannelLabel_LFE2:
    return media::AudioChannelRole::LowFrequency;
  // Side, rear and "direct" surrounds all take the same coefficient in
  // libswresample, verified on a 7.1 fixture where the side pair and the back
  // pair both measured 0.707107 into their own output.
  case kAudioChannelLabel_LeftSurround:
  case kAudioChannelLabel_LeftSurroundDirect:
  case kAudioChannelLabel_RearSurroundLeft:
    return media::AudioChannelRole::SurroundLeft;
  case kAudioChannelLabel_RightSurround:
  case kAudioChannelLabel_RightSurroundDirect:
  case kAudioChannelLabel_RearSurroundRight:
    return media::AudioChannelRole::SurroundRight;
  case kAudioChannelLabel_CenterSurround:
    return media::AudioChannelRole::SurroundCenter;
  default:
    // Front left/right-of-centre, every height and object label, Unused and
    // Unknown all land here. Unmapped makes the whole layout inadmissible,
    // which is a clean mpv fallback rather than a dropped channel.
    return media::AudioChannelRole::Unmapped;
  }
}

// Expands any of the three AudioChannelLayout encodings -- explicit
// descriptions, a bitmap, or a layout tag -- into an ordered role list.
// Returns false, writing nothing usable, when the layout cannot be expanded,
// does not describe exactly `expectedChannels` channels, or is wider than the
// caller's span.
[[nodiscard]] inline bool
channelRolesForLayout(const AudioChannelLayout *layout, std::size_t layoutBytes,
                      std::uint32_t expectedChannels,
                      std::span<media::AudioChannelRole> roles,
                      std::size_t *roleCount) noexcept {
  if (layout == nullptr || roleCount == nullptr || expectedChannels == 0 ||
      expectedChannels > roles.size() ||
      layoutBytes < offsetof(AudioChannelLayout, mChannelDescriptions)) {
    return false;
  }
  *roleCount = 0;

  // Storage for an expansion the caller did not supply directly. Sized for
  // kMaximumChannelLayoutDescriptions so the expansion either fits or is
  // refused; it is a plain stack local on the converter's owner thread and
  // never touched by the render callback.
  alignas(AudioChannelLayout) std::array<
      std::byte, sizeof(AudioChannelLayout) +
                     (kMaximumChannelLayoutDescriptions - 1) *
                         sizeof(AudioChannelDescription)>
      expansion{};

  const AudioChannelLayout *resolved = layout;
  if (layout->mNumberChannelDescriptions == 0) {
    const AudioFormatPropertyID property =
        layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap
            ? kAudioFormatProperty_ChannelLayoutForBitmap
            : kAudioFormatProperty_ChannelLayoutForTag;
    const UInt32 specifier =
        property == kAudioFormatProperty_ChannelLayoutForBitmap
            ? layout->mChannelBitmap
            : layout->mChannelLayoutTag;
    if (property == kAudioFormatProperty_ChannelLayoutForTag &&
        (specifier == kAudioChannelLayoutTag_UseChannelDescriptions ||
         (specifier & 0xFFFFU) != expectedChannels)) {
      // A tag states its own channel count in its low sixteen bits. Disagreeing
      // with the ASBD means the two descriptions of the same stream do not
      // match, which is never something to reconcile by guessing.
      return false;
    }
    UInt32 size = 0;
    if (AudioFormatGetPropertyInfo(property, sizeof(specifier), &specifier,
                                   &size) != noErr ||
        size == 0 || size > expansion.size()) {
      return false;
    }
    if (AudioFormatGetProperty(property, sizeof(specifier), &specifier, &size,
                               expansion.data()) != noErr) {
      return false;
    }
    resolved = reinterpret_cast<const AudioChannelLayout *>(expansion.data());
  }

  if (resolved->mNumberChannelDescriptions != expectedChannels) {
    return false;
  }
  for (UInt32 index = 0; index < expectedChannels; ++index) {
    const media::AudioChannelRole role =
        roleForChannelLabel(resolved->mChannelDescriptions[index].mChannelLabel);
    if (role == media::AudioChannelRole::Unmapped) {
      return false;
    }
    roles[index] = role;
  }
  *roleCount = expectedChannels;
  return true;
}

// Convenience for admission checks that hold only a layout TAG: true when the
// tag expands to exactly `channels` mapped labels that form an admissible
// stereo downmix.
[[nodiscard]] inline bool
multichannelLayoutTagAdmitted(std::uint32_t tag,
                              std::uint32_t channels) noexcept {
  if (channels < 2 || channels > media::kMaximumDownmixSourceChannels) {
    return false;
  }
  AudioChannelLayout layout{};
  layout.mChannelLayoutTag = tag;
  std::array<media::AudioChannelRole, media::kMaximumDownmixSourceChannels>
      roles{};
  std::size_t count = 0;
  if (!channelRolesForLayout(&layout,
                             offsetof(AudioChannelLayout, mChannelDescriptions),
                             channels, roles, &count)) {
    return false;
  }
  return media::buildStereoDownmixMatrix({roles.data(), count}).admitted();
}

} // namespace wam::macos
