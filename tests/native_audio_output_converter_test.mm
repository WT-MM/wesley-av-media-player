// Measures the output-unit family's OWN sample-rate converter -- the stage
// that admits every sub-device rate in native_audio_sample_rates.hpp -- where
// its output can be captured: kAudioUnitSubType_GenericOutput is the same
// AUOutputBase as DefaultOutput, with the same input-scope converter, but it
// renders into the caller's buffer instead of a device. No hardware is touched
// and nothing is audible.
//
// Two facts are load-bearing for the clock and neither can be argued from
// documentation:
//
//  1. THE INPUT DEMAND IS EXACT. Over N output frames the converter pulls
//     either floor(N * Rin / Rout) or one more client frame -- a ceil-carry
//     with no cumulative drift -- so "media frames consumed" and the clock's
//     frame arithmetic can never diverge.
//  2. THE DECLARED LATENCY IS THE REAL ONE. NativeAudioOutput shifts every
//     published host endpoint by kAudioUnitProperty_Latency; that is only
//     honest if a chirp pulled through the converter comes out delayed by
//     exactly that much. A linear chirp has one correlation peak (a tone
//     matches at every whole period), so its cross-correlation lag against the
//     same chirp sampled directly at the output rate IS the group delay.

#include "platform/macos/native_audio_sample_rates.hpp"

#include <AudioToolbox/AudioToolbox.h>

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <numbers>
#include <vector>

#include "support/expect.hpp"

namespace {

constexpr double kOutputRate = 48000.0;
constexpr std::uint32_t kBlockFrames = 1024;
constexpr double kSeconds = 2.0;

// The chirp is defined in continuous time so it can be sampled at EITHER rate:
// 100 Hz to 0.45 * Rin over kSeconds, which keeps it below the input Nyquist
// so the direct output-rate sampling is the ideal band-limited resample.
struct Chirp {
  double inputRate;
  [[nodiscard]] float at(double seconds) const noexcept {
    const double f0 = 100.0;
    const double f1 = 0.45 * inputRate;
    const double k = (f1 - f0) / kSeconds;
    return static_cast<float>(
        0.5 * std::sin(2.0 * std::numbers::pi *
                       (f0 * seconds + 0.5 * k * seconds * seconds)));
  }
};

struct Source {
  Chirp chirp;
  std::uint64_t position{0};
  std::uint64_t pulls{0};

  static OSStatus input(void *context, AudioUnitRenderActionFlags *,
                        const AudioTimeStamp *, UInt32, UInt32 frames,
                        AudioBufferList *data) noexcept {
    auto *self = static_cast<Source *>(context);
    auto *out = static_cast<float *>(data->mBuffers[0].mData);
    for (UInt32 i = 0; i < frames; ++i) {
      const float value = self->chirp.at(
          static_cast<double>(self->position + i) / self->chirp.inputRate);
      out[i * 2] = value;
      out[i * 2 + 1] = -value;  // an inverted right channel proves identity
    }
    self->position += frames;
    ++self->pulls;
    return noErr;
  }
};

[[nodiscard]] AudioStreamBasicDescription interleavedFloat(double rate) {
  AudioStreamBasicDescription format{};
  format.mSampleRate = rate;
  format.mFormatID = kAudioFormatLinearPCM;
  format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  format.mChannelsPerFrame = 2;
  format.mBitsPerChannel = 32;
  format.mFramesPerPacket = 1;
  format.mBytesPerFrame = 8;
  format.mBytesPerPacket = 8;
  return format;
}

struct Measurement {
  bool rendered{false};
  double declaredOutputFrames{0.0};
  double measuredOutputFrames{0.0};
  long long minimumDemandDeviation{0};
  long long maximumDemandDeviation{0};
  bool channelsIntact{true};
};

[[nodiscard]] Measurement measure(double inputRate) {
  Measurement result;
  const AudioComponentDescription description{
      kAudioUnitType_Output, kAudioUnitSubType_GenericOutput,
      kAudioUnitManufacturer_Apple, 0, 0};
  AudioComponent component = AudioComponentFindNext(nullptr, &description);
  AudioComponentInstance unit = nullptr;
  if (component == nullptr ||
      AudioComponentInstanceNew(component, &unit) != noErr) {
    return result;
  }
  const AudioStreamBasicDescription inputFormat = interleavedFloat(inputRate);
  const AudioStreamBasicDescription outputFormat =
      interleavedFloat(kOutputRate);
  UInt32 maximumFrames = kBlockFrames;
  Source source{Chirp{inputRate}};
  const AURenderCallbackStruct callback{&Source::input, &source};
  const bool configured =
      AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                           kAudioUnitScope_Output, 0, &outputFormat,
                           sizeof(outputFormat)) == noErr &&
      AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                           kAudioUnitScope_Input, 0, &inputFormat,
                           sizeof(inputFormat)) == noErr &&
      AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                           kAudioUnitScope_Global, 0, &maximumFrames,
                           sizeof(maximumFrames)) == noErr &&
      AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                           kAudioUnitScope_Input, 0, &callback,
                           sizeof(callback)) == noErr &&
      AudioUnitInitialize(unit) == noErr;
  if (!configured) {
    AudioComponentInstanceDispose(unit);
    return result;
  }
  Float64 latencySeconds = 0.0;
  UInt32 size = sizeof(latencySeconds);
  if (AudioUnitGetProperty(unit, kAudioUnitProperty_Latency,
                           kAudioUnitScope_Global, 0, &latencySeconds,
                           &size) == noErr) {
    result.declaredOutputFrames = latencySeconds * kOutputRate;
  }

  const auto totalFrames = static_cast<std::uint64_t>(kSeconds * kOutputRate);
  std::vector<float> output;
  output.reserve((totalFrames + kBlockFrames) * 2);
  std::vector<float> block(kBlockFrames * 2);
  std::uint64_t produced = 0;
  bool everyRenderSucceeded = true;
  while (produced < totalFrames) {
    AudioBufferList list;
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = 2;
    list.mBuffers[0].mDataByteSize = kBlockFrames * 8;
    list.mBuffers[0].mData = block.data();
    AudioTimeStamp timestamp{};
    timestamp.mFlags = kAudioTimeStampSampleTimeValid;
    timestamp.mSampleTime = static_cast<Float64>(produced);
    AudioUnitRenderActionFlags flags = 0;
    if (AudioUnitRender(unit, &flags, &timestamp, 0, kBlockFrames, &list) !=
        noErr) {
      everyRenderSucceeded = false;
      break;
    }
    output.insert(output.end(), block.begin(), block.end());
    produced += kBlockFrames;
    // Fact 1: cumulative demand against the exact rational, after every block.
    const auto exact = static_cast<long long>(
        static_cast<__int128>(produced) * static_cast<long long>(inputRate) /
        static_cast<long long>(kOutputRate));
    const long long deviation =
        static_cast<long long>(source.position) - exact;
    result.minimumDemandDeviation =
        std::min(result.minimumDemandDeviation, deviation);
    result.maximumDemandDeviation =
        std::max(result.maximumDemandDeviation, deviation);
  }
  AudioUnitUninitialize(unit);
  AudioComponentInstanceDispose(unit);
  if (!everyRenderSucceeded) {
    return result;
  }
  result.rendered = true;

  // Fact 2: chirp cross-correlation against the ideal, sampled at the output
  // rate, over the middle of the run (clear of the converter's ramp-in and
  // of the tail). Lags are searched over [0, 4096) output frames.
  const std::size_t frames = produced;
  const std::size_t begin = frames / 10;
  const std::size_t end = frames - frames / 10;
  const Chirp chirp{inputRate};
  std::vector<double> ideal(frames);
  for (std::size_t i = 0; i < frames; ++i) {
    ideal[i] = chirp.at(static_cast<double>(i) / kOutputRate);
  }
  constexpr std::size_t kMaximumLag = 4096;
  double best = -1.0;
  std::size_t bestLag = 0;
  std::vector<double> correlation(kMaximumLag, 0.0);
  for (std::size_t lag = 0; lag < kMaximumLag; ++lag) {
    double sum = 0.0;
    for (std::size_t i = begin; i + lag < end; ++i) {
      sum += static_cast<double>(output[(i + lag) * 2]) * ideal[i];
    }
    correlation[lag] = sum;
    if (sum > best) {
      best = sum;
      bestLag = lag;
    }
  }
  // Parabolic interpolation refines the peak to a fraction of a frame, which
  // is what a non-integral declared delay (16 * Rout / Rin) needs.
  double fraction = 0.0;
  if (bestLag > 0 && bestLag + 1 < kMaximumLag) {
    const double y0 = correlation[bestLag - 1];
    const double y1 = correlation[bestLag];
    const double y2 = correlation[bestLag + 1];
    const double denominator = y0 - 2.0 * y1 + y2;
    if (denominator != 0.0) {
      fraction = 0.5 * (y0 - y2) / denominator;
    }
  }
  result.measuredOutputFrames = static_cast<double>(bestLag) + fraction;
  for (std::size_t i = begin; i < end; ++i) {
    if (std::abs(output[i * 2] + output[i * 2 + 1]) > 1.0e-6F) {
      result.channelsIntact = false;
      break;
    }
  }
  return result;
}

void testEveryAdmittedSubDeviceRate() {
  for (const std::uint32_t rate : wam::macos::kNativeAudioSampleRates) {
    if (static_cast<double>(rate) >= kOutputRate) {
      continue;  // the converter is bypassed at and above the output rate
    }
    const Measurement measured = measure(static_cast<double>(rate));
    std::cout << "  " << rate << " Hz -> 48000: declared "
              << measured.declaredOutputFrames << " measured "
              << measured.measuredOutputFrames << " output frames; demand "
              << "deviation [" << measured.minimumDemandDeviation << ", "
              << measured.maximumDemandDeviation << "]\n";
    expect(measured.rendered, "the generic output unit converts this rate");
    expect(measured.minimumDemandDeviation >= 0 &&
               measured.maximumDemandDeviation <= 1,
           "input demand is floor(N * Rin / Rout) or one frame more, with "
           "no cumulative drift");
    expect(measured.declaredOutputFrames > 0.0,
           "the unit declares a nonzero group delay for a converted rate");
    expect(std::abs(measured.measuredOutputFrames -
                    measured.declaredOutputFrames) <= 0.05,
           "the chirp comes out delayed by exactly the declared latency");
    expect(measured.channelsIntact, "left and right stay in their slots");
  }
}

void testTheBypassDeclaresNothing() {
  const Measurement measured = measure(kOutputRate);
  expect(measured.rendered, "the unit renders at the output rate");
  expect(measured.minimumDemandDeviation == 0 &&
             measured.maximumDemandDeviation == 0,
         "at the output rate the demand is exactly the output frames");
  expect(measured.declaredOutputFrames == 0.0 &&
             measured.measuredOutputFrames == 0.0,
         "at the output rate there is no converter and no delay to declare");
}

}  // namespace

int main() {
  testEveryAdmittedSubDeviceRate();
  testTheBypassDeclaresNothing();
  if (failures != 0) {
    std::cerr << failures << " failure(s)\n";
    return EXIT_FAILURE;
  }
  std::cout << "native_audio_output_converter: ok\n";
  return EXIT_SUCCESS;
}
