#pragma once

#include "native_audio_render_core.hpp"

#include <AudioToolbox/AudioToolbox.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <vector>

namespace wam::macos {

// Pitch-preserving time-stretch stage backed by Apple's AUNewTimePitch.
//
// WHY THIS UNIT. Its input demand is exactly outputFrames * rate, deterministic
// from the first block, with no read-ahead and no internal input backlog -- so
// the media frames it takes out of the ring and the media time the clock must
// advance are the SAME quantity, and no second cursor or drift term is needed.
// Measured on the default output device at 48 kHz, 1024-frame blocks
// (scratch/probe): 0.25x/0.5x/1.5x/2x/2.5x/4x all pull exactly
// round(outputFrames * rate) with zero cumulative error over 409 600 output
// frames; per-block cost is 58-70 us against a 21 333 us budget; a rate change
// takes effect on the very next render with no transition block and no click.
// Parameter range is 1/32..32, covering the advertised 0.25..4 window.
//
// PITCH. The unit's pitch parameter is independent of its rate parameter, so
// the "Preserve pitch at other speeds" preference is served without a second
// code path and without touching frame accounting: pitch preserved is an
// offset of 0 cents, and varispeed is an offset of 1200 * log2(rate) cents,
// which scales the output pitch by exactly the rate. Input demand stays
// round(outputFrames * rate) either way -- measured, see the stage test.
//
// THE ONE COST is group delay: the unit declares 2048 + 2048/rate output frames
// of latency at 48 kHz. That is constant per rate and is what
// latencyOutputFrames() reports, so the render core can shift its published
// host endpoints by exactly that much and describe when audio is HEARD.
//
// LIFETIME. Created and destroyed only by the serialized audio-output owner,
// never from the render callback. render(), setRate() and latencyOutputFrames()
// are the only entry points the render callback touches; all three are bounded,
// allocation-free and lock-free (AudioUnitSetParameter is documented as
// callable from a render thread, and the latency is a validated closed form
// rather than a property query).
class NativeAudioStretchUnit final {
 public:
  // Output frames of one render. The render core never asks for more than one
  // ring slab of device frames, and the unit's MaximumFramesPerSlice is pinned
  // to exactly this so an input pull can never exceed one ring consume.
  static constexpr std::uint32_t kMaximumOutputFrames =
      static_cast<std::uint32_t>(NativePcmRing::kFramesPerSlab);

  [[nodiscard]] static std::unique_ptr<NativeAudioStretchUnit> create(
      std::uint32_t sampleRate) noexcept;
  ~NativeAudioStretchUnit();

  NativeAudioStretchUnit(const NativeAudioStretchUnit &) = delete;
  NativeAudioStretchUnit &operator=(const NativeAudioStretchUnit &) = delete;
  NativeAudioStretchUnit(NativeAudioStretchUnit &&) = delete;
  NativeAudioStretchUnit &operator=(NativeAudioStretchUnit &&) = delete;

  [[nodiscard]] NativeAudioStretchStage stage() noexcept;

  // Output frames of group delay at rate 1.0, as the unit itself declared it.
  // Zero means the declared latency did not match the closed form the stage
  // validated at construction, and no compensation is applied.
  [[nodiscard]] std::uint32_t latencyBaseFrames() const noexcept {
    return latency_base_frames_;
  }

  // The unit's pitch parameter is in cents and is limited to +/- 2400, which
  // is exactly the 0.25x..4x window expressed as 1200 * log2(rate).
  static constexpr double kPitchCentsLimit = 2400.0;

  // Pitch offset the stage applies for an exact rational rate. Zero whenever
  // pitch is preserved, and zero at the unit rate either way -- a rate of 1
  // is 0 cents, so the toggle cannot perturb 1x.
  [[nodiscard]] static float pitchCents(std::uint32_t numerator,
                                        std::uint32_t denominator,
                                        bool preservePitch) noexcept;

 private:
  explicit NativeAudioStretchUnit(std::uint32_t sampleRate) noexcept;

  [[nodiscard]] bool initialize() noexcept;
  [[nodiscard]] bool measureLatencyModel() noexcept;
  [[nodiscard]] std::uint32_t declaredLatencyFrames() noexcept;

  static bool stageConfigure(void *context, NativeAudioStretchPull pull,
                             void *pullContext) noexcept;
  static bool stageSetRate(void *context, std::uint32_t numerator,
                           std::uint32_t denominator,
                           bool preservePitch) noexcept;
  static std::uint32_t stageLatency(void *context) noexcept;
  static bool stageRender(void *context, std::uint32_t outputFrames,
                          float *interleavedOutput) noexcept;
  static void stageReset(void *context) noexcept;
  static OSStatus inputCallback(void *context,
                                AudioUnitRenderActionFlags *flags,
                                const AudioTimeStamp *timestamp,
                                UInt32 bus, UInt32 frameCount,
                                AudioBufferList *data) noexcept;

  AudioComponentInstance unit_{nullptr};
  bool initialized_{false};
  const std::uint32_t sample_rate_;

  NativeAudioStretchPull pull_{nullptr};
  void *pull_context_{nullptr};

  // Fixed workspaces, sized once here and never touched by the render path
  // except to read and write. AUNewTimePitch refuses interleaved float, so a
  // deinterleave in and an interleave out are both mandatory.
  std::vector<float> pull_scratch_;   // interleaved stereo, from the ring
  std::vector<float> output_left_;
  std::vector<float> output_right_;

  // Latency model, validated against the unit's own declaration at three
  // rates during construction: L(p/q) = base + base * q / p.
  std::uint32_t latency_base_frames_{0};
  std::uint32_t numerator_{1};
  std::uint32_t denominator_{1};
  bool preserve_pitch_{true};
  std::uint64_t render_sample_time_{0};
};

}  // namespace wam::macos
