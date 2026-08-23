#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

namespace wam::media {

// Backend-neutral multichannel -> stereo downmix.
//
// WHY THIS EXISTS. The whole output chain below the converter is stereo
// (NativePcmRing::kChannels == 2), so a 5.1 or 7.1 source has to be reduced
// somewhere. The two things the platform offers were both measured wrong:
// asking AudioConverter for a two-channel output ASBD makes Apple's AC-3
// decoder emit a normalised Lt/Rt matrix at -10.70 dB (both surrounds folded
// into BOTH outputs) and makes the FLAC path silently discard centre, LFE and
// both surrounds. Either would play the file audibly wrongly where mpv plays
// it correctly, which is why multichannel used to be refused at admission
// instead. The fix is to decode the FULL native layout and apply the exact
// coefficients here.
//
// THE COEFFICIENTS are ITU-R BS.775 style, and are exactly what
// libswresample -- and therefore ffmpeg and mpv -- produce for float output:
//
//   L' = L + (1/sqrt2)*C + (1/sqrt2)*Ls
//   R' = R + (1/sqrt2)*C + (1/sqrt2)*Rs
//
// measured to six decimal places against `ffmpeg -ac 2 -c:a pcm_f32le` and
// against mpv's own `--ao=pcm` output on a per-channel tone fixture. LFE is
// EXCLUDED, which is swresample's default (lfe_mix_level 0) and therefore
// what mpv, VLC and QuickTime do as well.
//
// NORMALISATION. None. The row sum can reach 1 + 2/sqrt2 = 2.414214, so the
// result can exceed full scale (measured peak 1.0268 on a 5.1 tone fixture).
// ffmpeg's INTEGER output path divides by that row sum, i.e. -7.655 dB, and
// mpv deliberately does not (`--audio-normalize-downmix` defaults to no).
// Matching the quiet variant would be an audible 7.7 dB regression against the
// mpv fallback this path is replacing, so the post-gain is fixed at exactly
// 1.0. Overshoot is bounded downstream by the render core, which already
// saturates every stereo sample to +/-1 after applying gain -- and doing it
// there rather than here means a listener at less than full volume never
// clips at all.

// The channel roles this player knows how to fold into stereo. Deliberately
// coarser than CoreAudio's label space: several distinct labels (side, rear
// and direct surrounds) share one role because ffmpeg gives them the same
// coefficient, and every label that does NOT map to a role here makes the
// whole layout inadmissible rather than being quietly dropped.
enum class AudioChannelRole : std::uint8_t {
  Unmapped = 0,
  Left,
  Right,
  Center,
  LowFrequency,
  SurroundLeft,
  SurroundRight,
  SurroundCenter,
};

// Eight is MediaSourceLimits::kHardMaximumAudioChannels; the array bound is
// restated here so this neutral module stays free of the source header, and
// the two are tied together by a static_assert in audio_downmix.cpp.
inline constexpr std::size_t kMaximumDownmixSourceChannels{8};

inline constexpr std::size_t kStereoDownmixOutputChannels{2};

// 1/sqrt(2) in float, the value libswresample computes as M_SQRT1_2 and
// rounds into its float matrix. Written out rather than derived so the exact
// shipped constant is greppable and testable.
inline constexpr float kDownmixCenterCoefficient{0.70710678F};
inline constexpr float kDownmixSurroundCoefficient{0.70710678F};
// A single rear-centre channel splits equally: swresample uses
// slev * (1/sqrt2) = 0.5, measured exactly on a 6.1 fixture.
inline constexpr float kDownmixSurroundCenterCoefficient{0.5F};
// Stated explicitly because "the LFE coefficient" is a policy, not an
// oversight, and a future change has to edit a named constant to alter it.
inline constexpr float kDownmixLowFrequencyCoefficient{0.0F};

struct StereoDownmixMatrix {
  std::array<float, kMaximumDownmixSourceChannels> left{};
  std::array<float, kMaximumDownmixSourceChannels> right{};
  std::uint32_t sourceChannels{0};
  bool valid{false};

  [[nodiscard]] constexpr bool admitted() const noexcept { return valid; }

  friend constexpr bool operator==(const StereoDownmixMatrix &,
                                   const StereoDownmixMatrix &) = default;
};

// Builds the matrix for one exact ordered role list, which is the decoder's
// own reported output channel order translated label by label. Returns an
// invalid matrix -- never a guessed one -- when the layout is not one this
// policy can state exactly:
//
//   * fewer than two or more than kMaximumDownmixSourceChannels channels;
//   * any Unmapped role (an unrecognised CoreAudio label);
//   * not exactly one Left and exactly one Right;
//   * more than one Center, LowFrequency or SurroundCenter;
//   * unequal or excessive surround-left/surround-right counts.
//
// A refused layout is a clean fallback at admission, not a silent mis-mix.
[[nodiscard]] StereoDownmixMatrix
buildStereoDownmixMatrix(std::span<const AudioChannelRole> roles) noexcept;

// Folds `frameCount` interleaved frames of `matrix.sourceChannels` channels
// into interleaved stereo, IN PLACE at the front of the same buffer.
//
// Safe in place because the destination cursor 2*f never overtakes the source
// cursor N*f while N >= 2, so a single forward pass reads every input sample
// before the write that would overwrite it. FRAME COUNT IS INVARIANT: this is
// a width reduction only, and nothing here touches a timestamp, an ordinal or
// a statistic. Allocation-free and branch-free per sample; it runs on the
// converter's owner thread, never on the real-time render callback.
//
// Does nothing when the matrix is invalid or the buffer is too small to hold
// frameCount * sourceChannels samples.
void applyStereoDownmix(const StereoDownmixMatrix &matrix,
                        std::span<float> interleaved,
                        std::size_t frameCount) noexcept;

} // namespace wam::media
