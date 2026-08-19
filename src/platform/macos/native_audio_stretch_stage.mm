#include "native_audio_stretch_stage.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

namespace wam::macos {
namespace {

constexpr std::uint32_t kChannels =
    static_cast<std::uint32_t>(NativePcmRing::kChannels);

// Non-interleaved packed float is the only client format AUNewTimePitch
// accepts; interleaved is rejected with kAudioUnitErr_FormatNotSupported.
[[nodiscard]] AudioStreamBasicDescription stretchFormat(
    std::uint32_t sampleRate) noexcept {
  AudioStreamBasicDescription format{};
  format.mSampleRate = static_cast<Float64>(sampleRate);
  format.mFormatID = kAudioFormatLinearPCM;
  format.mFormatFlags = kAudioFormatFlagIsFloat |
                        kAudioFormatFlagIsPacked |
                        kAudioFormatFlagIsNonInterleaved;
  format.mChannelsPerFrame = kChannels;
  format.mBitsPerChannel = 32;
  format.mFramesPerPacket = 1;
  format.mBytesPerFrame = sizeof(float);
  format.mBytesPerPacket = sizeof(float);
  return format;
}

// Two non-interleaved mono buffers laid out contiguously, so one stack object
// can stand in for an AudioBufferList without any allocation.
struct StereoBufferList {
  UInt32 numberBuffers{kChannels};
  AudioBuffer buffers[kChannels]{};

  StereoBufferList(float *left, float *right, std::uint32_t frames) noexcept {
    const UInt32 bytes = frames * static_cast<UInt32>(sizeof(float));
    buffers[0].mNumberChannels = 1;
    buffers[0].mDataByteSize = bytes;
    buffers[0].mData = left;
    buffers[1].mNumberChannels = 1;
    buffers[1].mDataByteSize = bytes;
    buffers[1].mData = right;
  }

  [[nodiscard]] AudioBufferList *list() noexcept {
    return reinterpret_cast<AudioBufferList *>(this);
  }
};

static_assert(offsetof(StereoBufferList, numberBuffers) ==
              offsetof(AudioBufferList, mNumberBuffers));
static_assert(offsetof(StereoBufferList, buffers) ==
              offsetof(AudioBufferList, mBuffers));

}  // namespace

NativeAudioStretchUnit::NativeAudioStretchUnit(
    std::uint32_t sampleRate) noexcept
    : sample_rate_(sampleRate) {}

NativeAudioStretchUnit::~NativeAudioStretchUnit() {
  if (unit_ != nullptr) {
    if (initialized_) {
      static_cast<void>(AudioUnitUninitialize(unit_));
    }
    static_cast<void>(AudioComponentInstanceDispose(unit_));
    unit_ = nullptr;
  }
}

std::unique_ptr<NativeAudioStretchUnit> NativeAudioStretchUnit::create(
    std::uint32_t sampleRate) noexcept {
  if (sampleRate == 0) {
    return nullptr;
  }
  std::unique_ptr<NativeAudioStretchUnit> unit(
      new (std::nothrow) NativeAudioStretchUnit(sampleRate));
  if (!unit || !unit->initialize()) {
    return nullptr;
  }
  return unit;
}

bool NativeAudioStretchUnit::initialize() noexcept {
  // Every workspace the render path can touch is sized here, on the owner
  // thread, once. Nothing below this line allocates again.
  pull_scratch_.assign(
      static_cast<std::size_t>(kMaximumOutputFrames) * kChannels, 0.0F);
  output_left_.assign(kMaximumOutputFrames, 0.0F);
  output_right_.assign(kMaximumOutputFrames, 0.0F);

  const AudioComponentDescription description{
      kAudioUnitType_FormatConverter, kAudioUnitSubType_NewTimePitch,
      kAudioUnitManufacturer_Apple, 0, 0};
  AudioComponent component = AudioComponentFindNext(nullptr, &description);
  if (component == nullptr) {
    return false;
  }
  if (AudioComponentInstanceNew(component, &unit_) != noErr ||
      unit_ == nullptr) {
    unit_ = nullptr;
    return false;
  }

  const AudioStreamBasicDescription format = stretchFormat(sample_rate_);
  if (AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat,
                           kAudioUnitScope_Input, 0, &format,
                           sizeof(format)) != noErr ||
      AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat,
                           kAudioUnitScope_Output, 0, &format,
                           sizeof(format)) != noErr) {
    return false;
  }

  // Pinning the slice to one ring slab bounds an input pull to exactly what a
  // single ring consume() can serve, which is what lets the pull path stay a
  // straight copy with no partial-slab bookkeeping.
  UInt32 maximumFrames = kMaximumOutputFrames;
  if (AudioUnitSetProperty(unit_, kAudioUnitProperty_MaximumFramesPerSlice,
                           kAudioUnitScope_Global, 0, &maximumFrames,
                           sizeof(maximumFrames)) != noErr) {
    return false;
  }

  AURenderCallbackStruct callback{&NativeAudioStretchUnit::inputCallback,
                                  this};
  if (AudioUnitSetProperty(unit_, kAudioUnitProperty_SetRenderCallback,
                           kAudioUnitScope_Input, 0, &callback,
                           sizeof(callback)) != noErr) {
    return false;
  }
  if (AudioUnitInitialize(unit_) != noErr) {
    return false;
  }
  initialized_ = true;
  return measureLatencyModel();
}

std::uint32_t NativeAudioStretchUnit::declaredLatencyFrames() noexcept {
  Float64 seconds = 0.0;
  UInt32 size = sizeof(seconds);
  if (AudioUnitGetProperty(unit_, kAudioUnitProperty_Latency,
                           kAudioUnitScope_Global, 0, &seconds,
                           &size) != noErr ||
      !std::isfinite(seconds) || seconds < 0.0) {
    return 0;
  }
  const double frames = seconds * static_cast<double>(sample_rate_);
  if (!(frames >= 0.0) || frames > 1.0e7) {
    return 0;
  }
  return static_cast<std::uint32_t>(frames + 0.5);
}

bool NativeAudioStretchUnit::measureLatencyModel() noexcept {
  // The unit declares its group delay as a function of the stretch factor.
  // Querying that property is not a render-thread-safe operation, so the
  // model is established here, once, and evaluated in integer arithmetic
  // afterwards. Establishing it is also the proof that the model is real:
  // if the declaration does not follow base + base/rate at the probe points,
  // no compensation is applied rather than a wrong one.
  const auto set = [this](double rate) noexcept {
    return AudioUnitSetParameter(
               unit_, kNewTimePitchParam_Rate, kAudioUnitScope_Global, 0,
               static_cast<AudioUnitParameterValue>(rate), 0) == noErr;
  };
  if (!set(1.0)) {
    return false;
  }
  const std::uint32_t unitLatency = declaredLatencyFrames();
  latency_base_frames_ = 0;
  if (unitLatency != 0 && unitLatency % 2U == 0) {
    const std::uint32_t base = unitLatency / 2U;
    const auto matches = [&](double rate, std::uint32_t expected) noexcept {
      if (!set(rate)) {
        return false;
      }
      const std::uint32_t observed = declaredLatencyFrames();
      const std::uint32_t difference =
          observed > expected ? observed - expected : expected - observed;
      return difference <= 1U;
    };
    if (matches(2.0, base + base / 2U) && matches(0.5, base + base * 2U)) {
      latency_base_frames_ = base;
    }
  }
  numerator_ = 1;
  denominator_ = 1;
  return set(1.0);
}

NativeAudioStretchStage NativeAudioStretchUnit::stage() noexcept {
  NativeAudioStretchStage stage;
  stage.context = this;
  stage.configure = &NativeAudioStretchUnit::stageConfigure;
  stage.setRate = &NativeAudioStretchUnit::stageSetRate;
  stage.latencyOutputFrames = &NativeAudioStretchUnit::stageLatency;
  stage.render = &NativeAudioStretchUnit::stageRender;
  stage.reset = &NativeAudioStretchUnit::stageReset;
  return stage;
}

bool NativeAudioStretchUnit::stageConfigure(
    void *context, NativeAudioStretchPull pull, void *pullContext) noexcept {
  auto *self = static_cast<NativeAudioStretchUnit *>(context);
  if (self == nullptr || pull == nullptr || self->unit_ == nullptr) {
    return false;
  }
  self->pull_ = pull;
  self->pull_context_ = pullContext;
  return true;
}

float NativeAudioStretchUnit::pitchCents(std::uint32_t numerator,
                                         std::uint32_t denominator,
                                         bool preservePitch) noexcept {
  if (preservePitch || numerator == denominator || numerator == 0 ||
      denominator == 0) {
    return 0.0F;
  }
  // Varispeed by cents. A rate of r played back as if the tape ran r times
  // faster raises every partial by exactly r, which in the unit's parameter
  // domain is 1200 * log2(r) cents. The advertised window lands exactly on
  // the parameter's own limits: 4x -> +2400, 0.25x -> -2400.
  const double rate = static_cast<double>(numerator) /
                      static_cast<double>(denominator);
  const double cents = 1200.0 * std::log2(rate);
  return static_cast<float>(
      std::clamp(cents, -kPitchCentsLimit, kPitchCentsLimit));
}

bool NativeAudioStretchUnit::stageSetRate(
    void *context, std::uint32_t numerator, std::uint32_t denominator,
    bool preservePitch) noexcept {
  auto *self = static_cast<NativeAudioStretchUnit *>(context);
  if (self == nullptr || self->unit_ == nullptr || numerator == 0 ||
      denominator == 0) {
    return false;
  }
  // Exact: numerator and denominator are small integers, so the quotient is
  // correctly rounded exactly once, and the unit's own demand is
  // round(outputFrames * rate) evaluated on that same value. The render core
  // only ever asks for output frame counts that are multiples of the
  // denominator, so that rounding is never actually exercised.
  const double rate = static_cast<double>(numerator) /
                      static_cast<double>(denominator);
  if (AudioUnitSetParameter(self->unit_, kNewTimePitchParam_Rate,
                            kAudioUnitScope_Global, 0,
                            static_cast<AudioUnitParameterValue>(rate),
                            0) != noErr) {
    return false;
  }
  // Pitch is ORTHOGONAL to rate in this unit: it shifts the spectrum of the
  // frames the rate parameter already decided to consume, so the input demand
  // stays exactly round(outputFrames * rate) at any offset. That is what lets
  // the render core keep one cursor and no drift term whether the toggle is
  // on or off; the stretch-stage test measures it rather than assuming it.
  if (AudioUnitSetParameter(
          self->unit_, kNewTimePitchParam_Pitch, kAudioUnitScope_Global, 0,
          static_cast<AudioUnitParameterValue>(
              pitchCents(numerator, denominator, preservePitch)),
          0) != noErr) {
    return false;
  }
  self->numerator_ = numerator;
  self->denominator_ = denominator;
  self->preserve_pitch_ = preservePitch;
  return true;
}

std::uint32_t NativeAudioStretchUnit::stageLatency(void *context) noexcept {
  auto *self = static_cast<NativeAudioStretchUnit *>(context);
  if (self == nullptr || self->latency_base_frames_ == 0 ||
      self->numerator_ == 0) {
    return 0;
  }
  // base + base * q / p, in output frames. Integer arithmetic only: the
  // render callback must not query an AudioUnit property.
  const std::uint64_t base = self->latency_base_frames_;
  const std::uint64_t scaled =
      base * self->denominator_ / self->numerator_;
  const std::uint64_t total = base + scaled;
  return total > std::numeric_limits<std::uint32_t>::max()
             ? 0U
             : static_cast<std::uint32_t>(total);
}

void NativeAudioStretchUnit::stageReset(void *context) noexcept {
  auto *self = static_cast<NativeAudioStretchUnit *>(context);
  if (self == nullptr || self->unit_ == nullptr) {
    return;
  }
  static_cast<void>(
      AudioUnitReset(self->unit_, kAudioUnitScope_Global, 0));
  self->render_sample_time_ = 0;
}

OSStatus NativeAudioStretchUnit::inputCallback(
    void *context, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
    UInt32, UInt32 frameCount, AudioBufferList *data) noexcept {
  auto *self = static_cast<NativeAudioStretchUnit *>(context);
  if (self == nullptr || data == nullptr ||
      data->mNumberBuffers != kChannels || frameCount == 0 ||
      frameCount > kMaximumOutputFrames || self->pull_ == nullptr) {
    return kAudio_ParamError;
  }
  auto *left = static_cast<float *>(data->mBuffers[0].mData);
  auto *right = static_cast<float *>(data->mBuffers[1].mData);
  if (left == nullptr || right == nullptr) {
    return kAudio_ParamError;
  }
  // The pull always fills exactly frameCount interleaved frames -- with real
  // audio up to the render core's hard budget and silence beyond it -- so the
  // deinterleave below never reads uninitialised scratch.
  static_cast<void>(
      self->pull_(self->pull_context_, self->pull_scratch_.data(),
                  static_cast<std::uint32_t>(frameCount)));
  const float *source = self->pull_scratch_.data();
  for (UInt32 frame = 0; frame < frameCount; ++frame) {
    left[frame] = source[frame * kChannels];
    right[frame] = source[frame * kChannels + 1U];
  }
  return noErr;
}

bool NativeAudioStretchUnit::stageRender(
    void *context, std::uint32_t outputFrames,
    float *interleavedOutput) noexcept {
  auto *self = static_cast<NativeAudioStretchUnit *>(context);
  if (self == nullptr || self->unit_ == nullptr || !self->initialized_ ||
      interleavedOutput == nullptr || outputFrames == 0 ||
      outputFrames > kMaximumOutputFrames || self->pull_ == nullptr) {
    return false;
  }
  StereoBufferList buffers(self->output_left_.data(),
                           self->output_right_.data(), outputFrames);
  // A monotonically increasing sample time is what an effect unit expects
  // from its host; restarting it every call is a legal but unnecessary lie.
  AudioTimeStamp timestamp{};
  timestamp.mFlags = kAudioTimeStampSampleTimeValid;
  timestamp.mSampleTime = static_cast<Float64>(self->render_sample_time_);
  AudioUnitRenderActionFlags flags = 0;
  if (AudioUnitRender(self->unit_, &flags, &timestamp, 0, outputFrames,
                      buffers.list()) != noErr) {
    return false;
  }
  const float *left = self->output_left_.data();
  const float *right = self->output_right_.data();
  for (std::uint32_t frame = 0; frame < outputFrames; ++frame) {
    interleavedOutput[frame * kChannels] = left[frame];
    interleavedOutput[frame * kChannels + 1U] = right[frame];
  }
  self->render_sample_time_ += outputFrames;
  return true;
}

}  // namespace wam::macos
