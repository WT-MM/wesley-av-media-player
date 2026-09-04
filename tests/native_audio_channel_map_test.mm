// The layout-mapping half of the multichannel downmix contract.
//
// Every tag below was OBSERVED, not looked up: each one is what
// kAudioConverterOutputChannelLayout reported after AudioConverterNew on a
// real encoded fixture of that arrangement (scratchpad/downmix/mcprobe.mm).
// This test pins that the platform still expands them the same way and that
// the role mapping turns them into the coefficients the downmix policy states.

#include "media/audio_downmix.hpp"
#include "platform/macos/native_audio_channel_map.hpp"

#import <AudioToolbox/AudioToolbox.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <span>
#include <vector>

namespace {

using wam::macos::channelRolesForLayout;
using wam::macos::multichannelLayoutTagAdmitted;
using wam::macos::roleForChannelLabel;
using wam::media::AudioChannelRole;
using wam::media::buildStereoDownmixMatrix;
using wam::media::kMaximumDownmixSourceChannels;
using wam::media::StereoDownmixMatrix;

int failures = 0;

void expect(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

[[nodiscard]] bool rolesForTag(
    std::uint32_t tag, std::uint32_t channels,
    std::array<AudioChannelRole, kMaximumDownmixSourceChannels> *roles,
    std::size_t *count) {
  AudioChannelLayout layout{};
  layout.mChannelLayoutTag = tag;
  return channelRolesForLayout(
      &layout, offsetof(AudioChannelLayout, mChannelDescriptions), channels,
      *roles, count);
}

struct LayoutCase {
  const char *name;
  std::uint32_t tag;
  std::uint32_t channels;
  std::array<AudioChannelRole, kMaximumDownmixSourceChannels> expected;
};

constexpr AudioChannelRole kL = AudioChannelRole::Left;
constexpr AudioChannelRole kR = AudioChannelRole::Right;
constexpr AudioChannelRole kC = AudioChannelRole::Center;
constexpr AudioChannelRole kE = AudioChannelRole::LowFrequency;
constexpr AudioChannelRole kSl = AudioChannelRole::SurroundLeft;
constexpr AudioChannelRole kSr = AudioChannelRole::SurroundRight;
constexpr AudioChannelRole kCs = AudioChannelRole::SurroundCenter;
constexpr AudioChannelRole kX = AudioChannelRole::Unmapped;

void testMeasuredDecoderLayouts() {
  const std::array<LayoutCase, 12> cases{
      // The three DIFFERENT 5.1 orders one identical fixture produced.
      LayoutCase{"AAC-LC 5.1", 0x007C0006U, 6,
                 {kC, kL, kR, kSl, kSr, kE, kX, kX}},
      LayoutCase{"AC-3 and E-AC-3 5.1", 0x007B0006U, 6,
                 {kL, kC, kR, kSl, kSr, kE, kX, kX}},
      LayoutCase{"FLAC 5.1", 0x00790006U, 6,
                 {kL, kR, kC, kE, kSl, kSr, kX, kX}},
      // FLAC 7.1: the rear pair and the side pair carry different labels and
      // the same coefficient.
      LayoutCase{"FLAC 7.1", 0x00BD0008U, 8,
                 {kL, kR, kC, kE, kSl, kSr, kSl, kSr}},
      // The 7.1 and 6.1 arrangements a real AAC fixture produces, measured
      // 2026-09-04 (scratchpad/audio_gaps/wamconv.mm) with the converter
      // configured exactly as native_audio_converter.mm configures it: the
      // decompression magic cookie set FIRST, then the input layout tag. The
      // cookie is load-bearing for this answer -- without it the same
      // converter, on the same file, reports the front-wide 0x007F0008 below
      // instead, and the file would be refused for labels its bytes do not
      // carry. AAC is C-first, and its side pair and rear pair carry different
      // labels with the same coefficient.
      LayoutCase{"AAC 7.1", 0x00B70008U, 8,
                 {kC, kL, kR, kSl, kSr, kSl, kSr, kE}},
      LayoutCase{"AAC 6.1", 0x008E0007U, 7,
                 {kC, kL, kR, kSl, kSr, kCs, kE}},
      // Multichannel LPCM (a 6.1 .wav) states the same family as FLAC and is
      // L-first, so the rear centre lands at index 4 rather than index 5.
      LayoutCase{"LPCM 6.1", 0x00BC0007U, 7,
                 {kL, kR, kC, kE, kCs, kSl, kSr}},
      LayoutCase{"AC-3 3/2 (5.0)", 0x00770005U, 5,
                 {kL, kC, kR, kSl, kSr, kX, kX, kX}},
      LayoutCase{"AC-3 2/2 (quad)", 0x00840004U, 4,
                 {kL, kR, kSl, kSr, kX, kX, kX, kX}},
      LayoutCase{"AC-3 3/1", 0x00970004U, 4,
                 {kL, kC, kR, kCs, kX, kX, kX, kX}},
      LayoutCase{"AC-3 3/0", 0x00960003U, 3,
                 {kL, kC, kR, kX, kX, kX, kX, kX}},
      LayoutCase{"AC-3 2/0 + LFE", 0x00850003U, 3,
                 {kL, kR, kE, kX, kX, kX, kX, kX}}};

  for (const LayoutCase &entry : cases) {
    std::array<AudioChannelRole, kMaximumDownmixSourceChannels> roles{};
    std::size_t count = 0;
    if (!rolesForTag(entry.tag, entry.channels, &roles, &count)) {
      std::cerr << "FAIL: " << entry.name << " did not expand\n";
      ++failures;
      continue;
    }
    if (count != entry.channels) {
      std::cerr << "FAIL: " << entry.name << " expanded to " << count
                << " channels\n";
      ++failures;
      continue;
    }
    for (std::size_t index = 0; index < count; ++index) {
      if (roles[index] != entry.expected[index]) {
        std::cerr << "FAIL: " << entry.name << " channel " << index
                  << " mapped to role "
                  << static_cast<int>(roles[index]) << ", expected "
                  << static_cast<int>(entry.expected[index]) << '\n';
        ++failures;
      }
    }
    const StereoDownmixMatrix matrix =
        buildStereoDownmixMatrix({roles.data(), count});
    expect(matrix.admitted(), entry.name);
    expect(multichannelLayoutTagAdmitted(entry.tag, entry.channels),
           "the admission helper agrees with the expansion");
  }
}

// The one arrangement AudioToolbox decodes that this policy deliberately does
// NOT fold: AAC channelConfiguration 7 is the front-wide 3/4.1 layout, whose
// front-left-of-centre and front-right-of-centre channels have no measured
// coefficient here. It must refuse, not guess.
void testFrontWideSevenOneIsRefused() {
  std::array<AudioChannelRole, kMaximumDownmixSourceChannels> roles{};
  std::size_t count = 0;
  expect(!rolesForTag(0x007F0008U, 8, &roles, &count),
         "AAC front-wide 7.1 refuses to map");
  expect(!multichannelLayoutTagAdmitted(0x007F0008U, 8),
         "AAC front-wide 7.1 is not admitted");
  expect(roleForChannelLabel(kAudioChannelLabel_LeftCenter) ==
             AudioChannelRole::Unmapped,
         "front-left-of-centre has no coefficient");
  expect(roleForChannelLabel(kAudioChannelLabel_RightCenter) ==
             AudioChannelRole::Unmapped,
         "front-right-of-centre has no coefficient");
}

void testLabelsMapAsDocumented() {
  expect(roleForChannelLabel(kAudioChannelLabel_Left) == AudioChannelRole::Left,
         "Left");
  expect(roleForChannelLabel(kAudioChannelLabel_Right) ==
             AudioChannelRole::Right,
         "Right");
  expect(roleForChannelLabel(kAudioChannelLabel_Center) ==
             AudioChannelRole::Center,
         "Center");
  expect(roleForChannelLabel(kAudioChannelLabel_LFEScreen) ==
             AudioChannelRole::LowFrequency,
         "LFE");
  // Side, rear and direct surrounds all fold identically -- the 7.1 case above
  // is the reason all three exist.
  expect(roleForChannelLabel(kAudioChannelLabel_LeftSurround) ==
             AudioChannelRole::SurroundLeft,
         "left surround");
  expect(roleForChannelLabel(kAudioChannelLabel_LeftSurroundDirect) ==
             AudioChannelRole::SurroundLeft,
         "left surround direct");
  expect(roleForChannelLabel(kAudioChannelLabel_RearSurroundLeft) ==
             AudioChannelRole::SurroundLeft,
         "rear surround left");
  expect(roleForChannelLabel(kAudioChannelLabel_RightSurround) ==
             AudioChannelRole::SurroundRight,
         "right surround");
  expect(roleForChannelLabel(kAudioChannelLabel_RightSurroundDirect) ==
             AudioChannelRole::SurroundRight,
         "right surround direct");
  expect(roleForChannelLabel(kAudioChannelLabel_RearSurroundRight) ==
             AudioChannelRole::SurroundRight,
         "rear surround right");
  expect(roleForChannelLabel(kAudioChannelLabel_CenterSurround) ==
             AudioChannelRole::SurroundCenter,
         "centre surround");
  expect(roleForChannelLabel(kAudioChannelLabel_Unknown) ==
             AudioChannelRole::Unmapped,
         "Unknown is unmapped");
  expect(roleForChannelLabel(kAudioChannelLabel_Unused) ==
             AudioChannelRole::Unmapped,
         "Unused is unmapped");
  expect(roleForChannelLabel(kAudioChannelLabel_TopCenterSurround) ==
             AudioChannelRole::Unmapped,
         "height channels are unmapped");
}

void testExplicitDescriptionsAreHonoured() {
  // A layout carrying descriptions rather than a tag: the AC-3 order, stated
  // the long way. The mapping must read the labels, not the tag.
  constexpr std::size_t kChannels = 6;
  std::vector<std::byte> storage(
      sizeof(AudioChannelLayout) +
      (kChannels - 1) * sizeof(AudioChannelDescription));
  auto *layout = reinterpret_cast<AudioChannelLayout *>(storage.data());
  layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
  layout->mChannelBitmap = 0;
  layout->mNumberChannelDescriptions = kChannels;
  const std::array<AudioChannelLabel, kChannels> labels{
      kAudioChannelLabel_Left,          kAudioChannelLabel_Center,
      kAudioChannelLabel_Right,         kAudioChannelLabel_LeftSurround,
      kAudioChannelLabel_RightSurround, kAudioChannelLabel_LFEScreen};
  for (std::size_t index = 0; index < kChannels; ++index) {
    layout->mChannelDescriptions[index] = AudioChannelDescription{};
    layout->mChannelDescriptions[index].mChannelLabel = labels[index];
  }
  std::array<AudioChannelRole, kMaximumDownmixSourceChannels> roles{};
  std::size_t count = 0;
  expect(channelRolesForLayout(layout, storage.size(), kChannels, roles,
                               &count),
         "explicit channel descriptions expand");
  expect(count == kChannels, "explicit descriptions keep their width");
  const std::array<AudioChannelRole, kChannels> expected{kL, kC, kR,
                                                         kSl, kSr, kE};
  for (std::size_t index = 0; index < kChannels; ++index) {
    expect(roles[index] == expected[index],
           "explicit description role matches its label");
  }
}

void testMalformedLayoutsAreRefused() {
  std::array<AudioChannelRole, kMaximumDownmixSourceChannels> roles{};
  std::size_t count = 0;
  expect(!channelRolesForLayout(nullptr, 0, 6, roles, &count),
         "a null layout is refused");

  AudioChannelLayout layout{};
  layout.mChannelLayoutTag = 0x007B0006U;
  expect(!channelRolesForLayout(&layout, 3, 6, roles, &count),
         "a truncated layout struct is refused");
  // The tag says six channels; the ASBD says five. Two descriptions of the
  // same stream disagreeing is never reconciled by guessing.
  expect(!channelRolesForLayout(
             &layout, offsetof(AudioChannelLayout, mChannelDescriptions), 5,
             roles, &count),
         "a tag whose width contradicts the ASBD is refused");
  expect(!multichannelLayoutTagAdmitted(0x007B0006U, 5),
         "the admission helper refuses the same contradiction");
  expect(!multichannelLayoutTagAdmitted(0U, 6),
         "a zero tag is not a multichannel layout");
  expect(!multichannelLayoutTagAdmitted(0x007B0006U, 9),
         "a width past the hard channel limit is refused");

  AudioChannelLayout mono{};
  mono.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
  expect(!channelRolesForLayout(
             &mono, offsetof(AudioChannelLayout, mChannelDescriptions), 1,
             roles, &count) ||
             buildStereoDownmixMatrix({roles.data(), count}).admitted() ==
                 false,
         "a mono layout never yields a downmix matrix");
}

} // namespace

int main() {
  testMeasuredDecoderLayouts();
  testFrontWideSevenOneIsRefused();
  testLabelsMapAsDocumented();
  testExplicitDescriptionsAreHonoured();
  testMalformedLayoutsAreRefused();
  if (failures != 0) {
    std::cerr << failures << " channel-map expectation(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "native audio channel map: all expectations passed\n";
  return EXIT_SUCCESS;
}
