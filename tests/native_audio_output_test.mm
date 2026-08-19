#include "platform/macos/native_audio_output.hpp"

#include <Foundation/Foundation.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <initializer_list>
#include <limits>
#include <memory>
#include <new>
#include <numeric>
#include <optional>
#include <span>
#include <thread>
#include <type_traits>
#include <utility>

namespace {

std::atomic<bool> gTrackAllocations{false};
std::atomic<std::uint64_t> gAllocations{0};

void noteAllocation() noexcept {
  if (gTrackAllocations.load(std::memory_order_relaxed)) {
    gAllocations.fetch_add(1, std::memory_order_relaxed);
  }
}

}  // namespace

void *operator new(std::size_t size) {
  noteAllocation();
  if (void *memory = std::malloc(size == 0 ? 1 : size)) {
    return memory;
  }
  throw std::bad_alloc();
}

void *operator new[](std::size_t size) { return ::operator new(size); }

void operator delete(void *memory) noexcept { std::free(memory); }
void operator delete[](void *memory) noexcept { std::free(memory); }
void operator delete(void *memory, std::size_t) noexcept {
  std::free(memory);
}
void operator delete[](void *memory, std::size_t) noexcept {
  std::free(memory);
}

namespace wam::macos {

struct NativeAudioRenderCoreTestAccess {
  static void setAfterPreflightHook(NativeAudioRenderCore &core,
                                    NativeAudioRenderCore::TestHook hook,
                                    void *context) noexcept {
    core.after_preflight_hook_ = hook;
    core.after_preflight_context_ = context;
  }
};

struct NativeAudioOutputTestAccess {
  static void setBeforeAdmissionHook(NativeAudioOutput &output,
                                     NativeAudioOutput::TestHook hook,
                                     void *context) noexcept {
    output.before_admission_hook_ = hook;
    output.before_admission_context_ = context;
  }

  static void setBeforeStartCommitHook(NativeAudioOutput &output,
                                       NativeAudioOutput::TestHook hook,
                                       void *context) noexcept {
    output.before_start_commit_hook_ = hook;
    output.before_start_commit_context_ = context;
  }

  static void setAfterCallbackWakeHook(NativeAudioOutput &output,
                                       NativeAudioOutput::TestHook hook,
                                       void *context) noexcept {
    output.after_callback_wake_hook_ = hook;
    output.after_callback_wake_context_ = context;
  }

  static void setAfterListenerWakeHook(NativeAudioOutput &output,
                                       NativeAudioOutput::TestHook hook,
                                       void *context) noexcept {
    output.after_listener_wake_hook_ = hook;
    output.after_listener_wake_context_ = context;
  }

  static void setAfterFactsBridgeOwnerHook(
      NativeAudioOutput &output, NativeAudioOutput::TestHook hook,
      void *context) noexcept {
    output.after_facts_bridge_owner_hook_ = hook;
    output.after_facts_bridge_owner_context_ = context;
  }

  // Seeds the exactly-adjacent carry state the render callback would have left
  // behind, so a slice sequence can be evaluated deterministically.
  static void seedCarry(NativeAudioOutput &output, __uint128_t remainder,
                        __uint128_t denominator, std::uint64_t rateScalarBits,
                        std::uint64_t endHostTicks) noexcept {
    output.timing_remainder_ = remainder;
    output.prior_timing_denominator_ = denominator;
    output.prior_rate_scalar_bits_ = rateScalarBits;
    output.prior_end_host_ticks_ = endHostTicks;
  }

  [[nodiscard]] static bool callbackInput(
      NativeAudioOutput &output, const AudioTimeStamp &timestamp,
      std::uint32_t frameCount, NativeAudioRenderInput *input,
      __uint128_t *nextRemainder, __uint128_t *nextDenominator,
      std::uint64_t *nextRateScalarBits) noexcept {
    return output.callbackInput(timestamp, frameCount, input, nextRemainder,
                                nextDenominator, nextRateScalarBits);
  }

  [[nodiscard]] static Float64 deviceRate(
      const NativeAudioOutput &output) noexcept {
    return output.device_rate_;
  }
};

}  // namespace wam::macos

namespace {

using wam::macos::NativeAudioOutput;
using wam::macos::NativeAudioOutputConfiguration;
using wam::macos::NativeAudioOutputFailure;
using wam::macos::NativeAudioOutputFacts;
using wam::macos::NativeAudioOutputProgress;
using wam::macos::NativeAudioOutputState;
using wam::macos::NativeAudioOutputTestAccess;
using wam::macos::NativeAudioOutputWakeSeam;
using wam::macos::NativeAudioRenderCore;
using wam::macos::NativeAudioRenderCoreTestAccess;
using wam::macos::NativeAudioRenderInput;
using wam::macos::NativeAudioRenderStats;
using wam::macos::NativeAudioUnitCallTable;
using wam::macos::NativeMediaClock;
using wam::macos::NativeMediaHostClock;
using wam::macos::NativePcmRing;
using wam::media::MediaTime;

static_assert(std::is_trivially_copyable_v<NativeAudioOutputConfiguration>);
static_assert(std::is_trivially_copyable_v<NativeAudioOutputFacts>);
static_assert(noexcept(std::declval<NativeAudioOutput &>().start()));
static_assert(noexcept(std::declval<NativeAudioOutput &>().stop()));
static_assert(noexcept(std::declval<NativeAudioOutput &>().close()));

constexpr std::uint32_t kSampleRate = 48000;
constexpr std::uint64_t kHostTicksPerSecond = 48000;
constexpr OSStatus kFakeFailure = -70001;
int failures = 0;

void expect(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

[[nodiscard]] double mediaSecondsAtFrame(
    MediaTime origin, std::uint64_t frame,
    std::uint32_t sampleRate) noexcept {
  return wam::media::mediaTimeSecondsAtFrame(origin, frame, sampleRate)
      .value_or(-1.0);
}

enum class Call : std::uint8_t {
  None,
  Find,
  New,
  GetDeviceFormat,
  SetMaximumFrames,
  GetMaximumFrames,
  SetClientFormat,
  GetClientFormat,
  AttachCallback,
  AddDeviceListener,
  Initialize,
  Start,
  Stop,
  Uninitialize,
  DetachCallback,
  RemoveDeviceListener,
  Dispose,
  HostFrequency,
};

struct FakeAudioUnit {
  std::array<Call, 64> calls{};
  std::size_t callCount{0};
  Call failAt{Call::None};
  Call throwAt{Call::None};
  bool failOnce{true};
  bool findUnavailable{false};
  bool invokeDuringStart{false};
  bool invokeDuringUninitialize{false};
  bool changeRateDuringStart{false};
  OSStatus uninitializeCallbackStatus{noErr};
  bool uninitializeCallbackSilenced{false};
  bool started{false};
  bool initialized{false};
  bool callbackAttached{false};
  bool listenerAttached{false};
  std::uint32_t maximumFrames{
      NativeAudioOutput::kMaximumFramesPerSlice};
  // Device IO buffer size. deviceBufferFrames models what the HAL reports back
  // after a set; deviceBufferFramesClamp lets a test model a device that
  // honours the property but lands somewhere else, and
  // deviceBufferFramesSupported models a device that refuses it outright (the
  // default-constructed value below matches the real system default so a test
  // that never touches these fields still sees a plausible device).
  std::uint32_t deviceBufferFrames{512};
  std::uint32_t requestedDeviceBufferFrames{0};
  std::uint32_t deviceBufferFramesClamp{0};
  bool deviceBufferFramesSupported{true};
  double deviceRate{kSampleRate};
  double hostFrequency{kHostTicksPerSecond};
  AudioStreamBasicDescription clientFormat{};
  AURenderCallback callback{nullptr};
  void *callbackContext{nullptr};
  AudioUnitPropertyListenerProc listener{nullptr};
  void *listenerContext{nullptr};
  int componentToken{0};
  int unitToken{0};

  void record(Call call) {
    if (callCount < calls.size()) {
      calls[callCount++] = call;
    }
    if (throwAt == call) {
      throwAt = Call::None;
      @throw [NSException exceptionWithName:@"FakeAudioUnit"
                                     reason:nil
                                   userInfo:nil];
    }
  }

  [[nodiscard]] OSStatus status(Call call) {
    record(call);
    if (failAt == call) {
      if (failOnce) {
        failAt = Call::None;
      }
      return kFakeFailure;
    }
    return noErr;
  }

  [[nodiscard]] bool sawOrdered(
      std::initializer_list<Call> expected) const noexcept {
    std::size_t cursor = 0;
    for (Call wanted : expected) {
      while (cursor < callCount && calls[cursor] != wanted) {
        ++cursor;
      }
      if (cursor == callCount) {
        return false;
      }
      ++cursor;
    }
    return true;
  }

  static FakeAudioUnit &self(void *context) {
    return *static_cast<FakeAudioUnit *>(context);
  }

  static AudioComponent findNext(
      void *context, AudioComponent,
      const AudioComponentDescription *description) {
    FakeAudioUnit &fake = self(context);
    fake.record(Call::Find);
    if (fake.findUnavailable || description == nullptr ||
        description->componentType != kAudioUnitType_Output ||
        description->componentSubType != kAudioUnitSubType_DefaultOutput ||
        description->componentManufacturer != kAudioUnitManufacturer_Apple) {
      return nullptr;
    }
    return reinterpret_cast<AudioComponent>(&fake.componentToken);
  }

  static OSStatus instanceNew(void *context, AudioComponent component,
                              AudioComponentInstance *instance) {
    FakeAudioUnit &fake = self(context);
    const OSStatus result = fake.status(Call::New);
    if (result == noErr && component != nullptr && instance != nullptr) {
      *instance = reinterpret_cast<AudioComponentInstance>(&fake.unitToken);
    }
    return result;
  }

  static OSStatus instanceDispose(void *context,
                                  AudioComponentInstance instance) {
    FakeAudioUnit &fake = self(context);
    const OSStatus result = fake.status(Call::Dispose);
    if (result == noErr &&
        instance != reinterpret_cast<AudioComponentInstance>(
                        &fake.unitToken)) {
      return kAudio_ParamError;
    }
    return result;
  }

  static OSStatus setProperty(void *context, AudioUnit,
                              AudioUnitPropertyID property,
                              AudioUnitScope scope,
                              AudioUnitElement element, const void *data,
                              UInt32 dataSize) {
    FakeAudioUnit &fake = self(context);
    if (element != 0) {
      return kAudio_ParamError;
    }
    if (property == kAudioUnitProperty_MaximumFramesPerSlice &&
        scope == kAudioUnitScope_Global) {
      const OSStatus result = fake.status(Call::SetMaximumFrames);
      if (result == noErr && data != nullptr &&
          dataSize == sizeof(std::uint32_t)) {
        fake.maximumFrames = *static_cast<const std::uint32_t *>(data);
      }
      return result;
    }
    if (property == kAudioDevicePropertyBufferFrameSize &&
        scope == kAudioUnitScope_Global) {
      if (!fake.deviceBufferFramesSupported) {
        return kAudioUnitErr_InvalidProperty;
      }
      if (data == nullptr || dataSize != sizeof(std::uint32_t)) {
        return kAudio_ParamError;
      }
      fake.requestedDeviceBufferFrames =
          *static_cast<const std::uint32_t *>(data);
      fake.deviceBufferFrames = fake.deviceBufferFramesClamp != 0
                                    ? fake.deviceBufferFramesClamp
                                    : fake.requestedDeviceBufferFrames;
      return noErr;
    }
    if (property == kAudioUnitProperty_StreamFormat &&
        scope == kAudioUnitScope_Input) {
      const OSStatus result = fake.status(Call::SetClientFormat);
      if (result == noErr && data != nullptr &&
          dataSize == sizeof(AudioStreamBasicDescription)) {
        fake.clientFormat =
            *static_cast<const AudioStreamBasicDescription *>(data);
      }
      return result;
    }
    if (property == kAudioUnitProperty_SetRenderCallback &&
        scope == kAudioUnitScope_Input && data != nullptr &&
        dataSize == sizeof(AURenderCallbackStruct)) {
      const auto &installed =
          *static_cast<const AURenderCallbackStruct *>(data);
      const bool detach = installed.inputProc == nullptr;
      const OSStatus result = fake.status(
          detach ? Call::DetachCallback : Call::AttachCallback);
      if (result == noErr) {
        fake.callbackAttached = !detach;
        fake.callback = installed.inputProc;
        fake.callbackContext = installed.inputProcRefCon;
      }
      return result;
    }
    return kAudioUnitErr_InvalidProperty;
  }

  static OSStatus getProperty(void *context, AudioUnit,
                              AudioUnitPropertyID property,
                              AudioUnitScope scope,
                              AudioUnitElement element, void *data,
                              UInt32 *dataSize) {
    FakeAudioUnit &fake = self(context);
    if (element != 0 || data == nullptr || dataSize == nullptr) {
      return kAudio_ParamError;
    }
    if (property == kAudioUnitProperty_StreamFormat &&
        scope == kAudioUnitScope_Output) {
      const OSStatus result = fake.status(Call::GetDeviceFormat);
      if (result == noErr &&
          *dataSize >= sizeof(AudioStreamBasicDescription)) {
        auto format = AudioStreamBasicDescription{};
        format.mSampleRate = fake.deviceRate;
        *static_cast<AudioStreamBasicDescription *>(data) = format;
        *dataSize = sizeof(format);
      }
      return result;
    }
    if (property == kAudioUnitProperty_MaximumFramesPerSlice &&
        scope == kAudioUnitScope_Global) {
      const OSStatus result = fake.status(Call::GetMaximumFrames);
      if (result == noErr && *dataSize >= sizeof(std::uint32_t)) {
        *static_cast<std::uint32_t *>(data) = fake.maximumFrames;
        *dataSize = sizeof(std::uint32_t);
      }
      return result;
    }
    if (property == kAudioDevicePropertyBufferFrameSize &&
        scope == kAudioUnitScope_Global) {
      if (!fake.deviceBufferFramesSupported) {
        return kAudioUnitErr_InvalidProperty;
      }
      if (*dataSize < sizeof(std::uint32_t)) {
        return kAudio_ParamError;
      }
      *static_cast<std::uint32_t *>(data) = fake.deviceBufferFrames;
      *dataSize = sizeof(std::uint32_t);
      return noErr;
    }
    if (property == kAudioUnitProperty_StreamFormat &&
        scope == kAudioUnitScope_Input) {
      const OSStatus result = fake.status(Call::GetClientFormat);
      if (result == noErr &&
          *dataSize >= sizeof(AudioStreamBasicDescription)) {
        *static_cast<AudioStreamBasicDescription *>(data) =
            fake.clientFormat;
        *dataSize = sizeof(AudioStreamBasicDescription);
      }
      return result;
    }
    return kAudioUnitErr_InvalidProperty;
  }

  static OSStatus initialize(void *context, AudioUnit) {
    FakeAudioUnit &fake = self(context);
    const OSStatus result = fake.status(Call::Initialize);
    if (result == noErr) {
      fake.initialized = true;
    }
    return result;
  }

  static OSStatus uninitialize(void *context, AudioUnit) {
    FakeAudioUnit &fake = self(context);
    const OSStatus result = fake.status(Call::Uninitialize);
    if (fake.invokeDuringUninitialize && fake.callback != nullptr) {
      fake.invokeDuringUninitialize = false;
      std::array<float, 16> samples{};
      samples.fill(8.0F);
      AudioTimeStamp timestamp{};
      timestamp.mHostTime = 200;
      timestamp.mFlags = kAudioTimeStampHostTimeValid;
      fake.uninitializeCallbackStatus = fake.invoke(
          timestamp, 8, samples.data(), sizeof(samples));
      fake.uninitializeCallbackSilenced = std::all_of(
          samples.begin(), samples.end(),
          [](float sample) { return sample == 0.0F; });
    }
    if (result == noErr) {
      fake.initialized = false;
    }
    return result;
  }

  static OSStatus start(void *context, AudioUnit) {
    FakeAudioUnit &fake = self(context);
    const OSStatus result = fake.status(Call::Start);
    if (fake.invokeDuringStart && fake.callback != nullptr) {
      std::array<float, 16> samples{};
      samples.fill(8.0F);
      AudioBufferList list{};
      list.mNumberBuffers = 1;
      list.mBuffers[0].mNumberChannels = 2;
      list.mBuffers[0].mDataByteSize = sizeof(samples);
      list.mBuffers[0].mData = samples.data();
      AudioTimeStamp timestamp{};
      timestamp.mHostTime = 100;
      timestamp.mFlags = kAudioTimeStampHostTimeValid;
      AudioUnitRenderActionFlags flags = 0;
      static_cast<void>(fake.callback(fake.callbackContext, &flags,
                                      &timestamp, 0, 8, &list));
    }
    if (fake.changeRateDuringStart) {
      fake.changeRateDuringStart = false;
      fake.changeDeviceRate(44100.0);
    }
    if (result == noErr) {
      fake.started = true;
    }
    return result;
  }

  static OSStatus stop(void *context, AudioUnit) {
    FakeAudioUnit &fake = self(context);
    const OSStatus result = fake.status(Call::Stop);
    if (result == noErr) {
      fake.started = false;
    }
    return result;
  }

  static OSStatus addPropertyListener(
      void *context, AudioUnit, AudioUnitPropertyID property,
      AudioUnitPropertyListenerProc listener, void *listenerContext) {
    FakeAudioUnit &fake = self(context);
    const OSStatus result = fake.status(Call::AddDeviceListener);
    if (result == noErr && property == kAudioUnitProperty_StreamFormat &&
        listener != nullptr) {
      fake.listenerAttached = true;
      fake.listener = listener;
      fake.listenerContext = listenerContext;
    }
    return result;
  }

  static OSStatus removePropertyListener(
      void *context, AudioUnit, AudioUnitPropertyID property,
      AudioUnitPropertyListenerProc listener, void *listenerContext) {
    FakeAudioUnit &fake = self(context);
    const OSStatus result = fake.status(Call::RemoveDeviceListener);
    if (result == noErr && property == kAudioUnitProperty_StreamFormat &&
        listener == fake.listener && listenerContext == fake.listenerContext) {
      fake.listenerAttached = false;
      fake.listener = nullptr;
      fake.listenerContext = nullptr;
    }
    return result;
  }

  void changeDeviceRate(double rate) noexcept {
    deviceRate = rate;
    if (listenerAttached && listener != nullptr) {
      listener(listenerContext, reinterpret_cast<AudioUnit>(&unitToken),
               kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0);
    }
  }

  static Float64 hostClockFrequency(void *context) {
    FakeAudioUnit &fake = self(context);
    fake.record(Call::HostFrequency);
    return fake.hostFrequency;
  }

  [[nodiscard]] NativeAudioUnitCallTable table() noexcept {
    return {this,
            &findNext,
            &instanceNew,
            &instanceDispose,
            &setProperty,
            &getProperty,
            &initialize,
            &uninitialize,
            &start,
            &stop,
            &addPropertyListener,
            &removePropertyListener,
            &hostClockFrequency};
  }

  [[nodiscard]] OSStatus invoke(AudioTimeStamp timestamp,
                                std::uint32_t frames, float *samples,
                                std::uint32_t byteSize,
                                std::uint32_t channels = 2,
                                std::uint32_t buffers = 1,
                                std::uint32_t bus = 0) const noexcept {
    if (callback == nullptr) {
      return kAudio_ParamError;
    }
    AudioBufferList list{};
    list.mNumberBuffers = buffers;
    list.mBuffers[0].mNumberChannels = channels;
    list.mBuffers[0].mDataByteSize = byteSize;
    list.mBuffers[0].mData = samples;
    AudioUnitRenderActionFlags flags = 0;
    return callback(callbackContext, &flags, &timestamp, bus, frames,
                    buffers == 0 ? nullptr : &list);
  }
};

struct FakeHostClock {
  std::atomic<std::uint64_t> ticks{0};

  static std::uint64_t read(void *context) noexcept {
    return static_cast<FakeHostClock *>(context)->ticks.load(
        std::memory_order_relaxed);
  }

  [[nodiscard]] NativeMediaHostClock seam(
      std::uint64_t frequency) noexcept {
    return {&read, this, frequency};
  }
};

struct WakeCounter {
  std::atomic<bool> pending{false};
  std::atomic<std::uint64_t> videoDueHostTicks{0};
  std::atomic<std::uint64_t> calls{0};
  std::atomic<std::uint64_t> orderingViolations{0};
  std::atomic<bool> block{false};
  std::atomic<bool> entered{false};
  std::atomic<bool> release{false};
  NativeAudioOutput *output{nullptr};

  static void signal(void *context) noexcept {
    auto &wake = *static_cast<WakeCounter *>(context);
    wake.calls.fetch_add(1, std::memory_order_relaxed);
    if (wake.output != nullptr) {
      const NativeAudioOutputFacts facts = wake.output->facts();
      if (facts.callbackEntries != 0 || facts.admittedCallbacks != 0) {
        wake.orderingViolations.fetch_add(1, std::memory_order_relaxed);
      }
    }
    if (wake.block.load(std::memory_order_acquire)) {
      wake.entered.store(true, std::memory_order_release);
      while (!wake.release.load(std::memory_order_acquire)) {
        std::this_thread::yield();
      }
    }
  }

  [[nodiscard]] NativeAudioOutputWakeSeam seam() noexcept {
    return {&pending, &signal, this, &videoDueHostTicks};
  }

  void clear() noexcept { pending.store(false, std::memory_order_release); }
};

struct Fixture {
  std::uint64_t hostFrequency{kHostTicksPerSecond};
  FakeHostClock host;
  // Heap-backed. One ring is half a megabyte of PCM payload -- the capacity
  // the maximum playback rate needs -- and several of these fixtures are live
  // in one stack frame, which overflows the 8 MiB main-thread stack outright.
  std::unique_ptr<NativePcmRing> ringStorage{
      std::make_unique<NativePcmRing>(1)};
  NativePcmRing &ring{*ringStorage};
  NativeMediaClock clock;
  NativeAudioRenderCore core;
  FakeAudioUnit fake;
  WakeCounter wake;
  std::shared_ptr<NativeAudioOutput> output;
  bool anchored{false};

  explicit Fixture(std::uint64_t frequency = kHostTicksPerSecond,
                   double initialMediaSeconds = 0.0)
      : hostFrequency(frequency), clock(host.seam(frequency)),
        core(ring, clock, frequency) {
    fake.hostFrequency = static_cast<double>(frequency);
    anchored = clock.anchorAtHostTicks(
        1, 0, initialMediaSeconds, 1.0, false);
    output = NativeAudioOutput::create(core, fake.table(), wake.seam());
    wake.output = output.get();
  }

  ~Fixture() { cleanup(); }

  [[nodiscard]] NativeAudioOutputConfiguration configuration(
      std::uint32_t sampleRate = kSampleRate,
      std::uint64_t frameCursor = 0) const noexcept {
    const std::uint64_t divisor = std::gcd(
        frameCursor, static_cast<std::uint64_t>(sampleRate));
    const MediaTime paused{
        static_cast<std::int64_t>(frameCursor / divisor),
        static_cast<std::int32_t>(
            static_cast<std::uint64_t>(sampleRate) / divisor)};
    return {1, frameCursor, {0, 1}, hostFrequency, sampleRate, paused};
  }

  [[nodiscard]] bool configure() {
    return anchored && output &&
           output->configure(configuration()) ==
               NativeAudioOutputProgress::Done;
  }

  [[nodiscard]] bool start() {
    core.setPaused(false);
    return configure() &&
           output->start() == NativeAudioOutputProgress::Done;
  }

  void cleanup() noexcept {
    fake.failAt = Call::None;
    fake.throwAt = Call::None;
    for (unsigned attempt = 0; output && attempt != 4; ++attempt) {
      if (output->close() == NativeAudioOutputProgress::Done) {
        break;
      }
    }
    output.reset();
    std::shared_ptr<NativeAudioOutput> recovered =
        NativeAudioOutput::recoverQuarantined();
    for (unsigned attempt = 0; recovered && attempt != 4; ++attempt) {
      if (recovered->close() == NativeAudioOutputProgress::Done) {
        break;
      }
    }
  }
};

[[nodiscard]] bool publishConstant(NativePcmRing &ring,
                                   std::size_t frames,
                                   float value = 1.0F) noexcept {
  std::array<float, NativePcmRing::kSamplesPerSlab> samples{};
  std::fill_n(samples.begin(), frames * NativePcmRing::kChannels, value);
  return ring.publish(
             1, std::span<const float>(samples).first(
                    frames * NativePcmRing::kChannels),
             frames) == NativePcmRing::PublishResult::Published;
}

[[nodiscard]] AudioTimeStamp hostTimestamp(
    std::uint64_t hostTicks) noexcept {
  AudioTimeStamp timestamp{};
  timestamp.mHostTime = hostTicks;
  timestamp.mFlags = kAudioTimeStampHostTimeValid;
  return timestamp;
}

[[nodiscard]] AudioTimeStamp sampleTimestamp(
    std::uint64_t hostTicks, double sampleTime,
    double rateScalar = 1.0) noexcept {
  AudioTimeStamp timestamp{};
  timestamp.mHostTime = hostTicks;
  timestamp.mSampleTime = sampleTime;
  timestamp.mRateScalar = rateScalar;
  timestamp.mFlags = kAudioTimeStampHostTimeValid |
                     kAudioTimeStampSampleTimeValid |
                     kAudioTimeStampRateScalarValid;
  return timestamp;
}

template <std::size_t Samples>
OSStatus invokeTracked(FakeAudioUnit &fake, AudioTimeStamp timestamp,
                       std::uint32_t frames,
                       std::array<float, Samples> &samples) {
  const std::uint64_t before =
      gAllocations.load(std::memory_order_relaxed);
  gTrackAllocations.store(true, std::memory_order_release);
  const OSStatus status = fake.invoke(timestamp, frames, samples.data(),
                                      sizeof(samples));
  gTrackAllocations.store(false, std::memory_order_release);
  expect(gAllocations.load(std::memory_order_relaxed) == before,
         "AudioUnit callback performs no dynamic allocation");
  return status;
}

void testConfigurationAndExactDeviceFormat() {
  {
    FakeHostClock host;
    auto ringStorage = std::make_unique<NativePcmRing>(1);
    NativePcmRing &ring = *ringStorage;
    NativeMediaClock clock(host.seam(kHostTicksPerSecond));
    NativeAudioRenderCore core(ring, clock, kHostTicksPerSecond);
    FakeAudioUnit fake;
    expect(!NativeAudioOutput::create(core, fake.table(), {}),
           "creation requires a callback-safe lifecycle wake seam");
  }

  Fixture fixture;
  expect(fixture.configure(),
         "DefaultOutput configures at an exact admitted device rate");
  const NativeAudioOutputFacts facts = fixture.output->facts();
  expect(facts.configured && facts.activated && facts.stopped &&
             !facts.started && facts.generation == 1 &&
             facts.sampleRate == kSampleRate &&
             fixture.fake.clientFormat.mFormatID ==
                 kAudioFormatLinearPCM &&
             fixture.fake.clientFormat.mFormatFlags ==
                 (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked) &&
             fixture.fake.clientFormat.mChannelsPerFrame == 2 &&
             fixture.fake.clientFormat.mBytesPerFrame == 8,
         "configured facts and client format are interleaved stereo Float32");
  fixture.cleanup();

  Fixture differing;
  differing.fake.deviceRate = 44100.0;
  expect(differing.output->configure(differing.configuration()) ==
             NativeAudioOutputProgress::Done &&
             differing.output->facts().failure ==
                 NativeAudioOutputFailure::None &&
             differing.fake.sawOrdered(
                 {Call::GetDeviceFormat, Call::SetClientFormat}) &&
             differing.fake.clientFormat.mSampleRate ==
                 static_cast<Float64>(kSampleRate) &&
             differing.output->facts().sampleRate == kSampleRate &&
             differing.fake.deviceRate == 44100.0,
         "a device rate that differs from the stream rate is admitted at the "
         "unit's own converter");
  differing.cleanup();

  Fixture unusableRate;
  unusableRate.fake.deviceRate = 0.0;
  expect(unusableRate.output->configure(unusableRate.configuration()) ==
             NativeAudioOutputProgress::Failed &&
             unusableRate.output->facts().failure ==
                 NativeAudioOutputFailure::DeviceRateMismatch &&
             unusableRate.fake.sawOrdered(
                 {Call::GetDeviceFormat, Call::Dispose}) &&
             !unusableRate.fake.sawOrdered({Call::SetClientFormat}),
         "an unusable device rate fails before any client format is set");

  Fixture invalid;
  expect(invalid.output->configure(invalid.configuration(32000)) ==
             NativeAudioOutputProgress::Invalid &&
             invalid.output->facts().failure ==
                 NativeAudioOutputFailure::InvalidConfiguration,
         "non-admitted integral sample rates are rejected");

  Fixture changedRate;
  expect(changedRate.configure(),
         "device-change fixture configures at the admitted rate");
  changedRate.fake.deviceRate = 44100.0;
  changedRate.core.setPaused(false);
  expect(changedRate.output->start() ==
             NativeAudioOutputProgress::Failed &&
             changedRate.output->facts().failure ==
                 NativeAudioOutputFailure::DeviceRateMismatch &&
             !changedRate.fake.started,
         "every start revalidates the live DefaultOutput rate before audio");
  changedRate.cleanup();

  Fixture liveChange;
  expect(liveChange.start(),
         "live-rate-change fixture starts with exact-rate proof");
  liveChange.wake.clear();
  const std::uint64_t allocationsBeforeChange =
      gAllocations.load(std::memory_order_relaxed);
  gTrackAllocations.store(true, std::memory_order_release);
  liveChange.fake.changeDeviceRate(44100.0);
  gTrackAllocations.store(false, std::memory_order_release);
  expect(liveChange.output->facts().failure ==
             NativeAudioOutputFailure::DeviceRateMismatch &&
             !liveChange.output->facts().started &&
             !liveChange.output->facts().stopped &&
             liveChange.wake.calls.load(std::memory_order_relaxed) == 1 &&
             gAllocations.load(std::memory_order_relaxed) ==
                 allocationsBeforeChange,
         "live stream-format notification revokes audio and wakes owner");
  liveChange.cleanup();

  Fixture duringStartChange;
  expect(duringStartChange.configure(),
         "during-start rate-change fixture configures");
  duringStartChange.core.setPaused(false);
  duringStartChange.fake.changeRateDuringStart = true;
  expect(duringStartChange.output->start() ==
             NativeAudioOutputProgress::Failed &&
             duringStartChange.output->facts().failure ==
                 NativeAudioOutputFailure::DeviceRateMismatch &&
             !duringStartChange.output->facts().started,
         "listener closes the query-to-start device-rate race");
  duringStartChange.cleanup();

  constexpr std::uint64_t cursor = 0;
  constexpr MediaTime origin{189751, 52016};
  const std::optional<double> originSeconds =
      wam::media::mediaTimeSecondsAtFrame(origin, cursor, kSampleRate);
  const std::optional<double> directlyRoundedOrigin =
      wam::media::mediaTimeSeconds(origin);
  Fixture nonzeroOrigin(kHostTicksPerSecond,
                        originSeconds.value_or(-1.0));
  NativeAudioOutputConfiguration originConfiguration =
      nonzeroOrigin.configuration(kSampleRate, cursor);
  originConfiguration.mediaOrigin = origin;
  originConfiguration.pausedClockPosition = origin;
  expect(nonzeroOrigin.output->configure(originConfiguration) ==
             NativeAudioOutputProgress::Done &&
             originSeconds && directlyRoundedOrigin &&
             *originSeconds == *directlyRoundedOrigin &&
             std::bit_cast<std::uint64_t>(*originSeconds) ==
                 UINT64_C(0x400d2ef8ad3d2f53),
         "canonical nonzero media origin is forwarded into render activation");
  nonzeroOrigin.cleanup();

  constexpr MediaTime visualTarget{1, 7};
  constexpr MediaTime firstAudioFrame{1143, 8000};
  const auto visualSeconds = wam::media::mediaTimeSeconds(visualTarget);
  const auto audioSeconds = wam::media::mediaTimeSeconds(firstAudioFrame);
  Fixture dualOrigin(kHostTicksPerSecond,
                     visualSeconds.value_or(-1.0));
  NativeAudioOutputConfiguration dualConfiguration =
      dualOrigin.configuration();
  dualConfiguration.mediaOrigin = firstAudioFrame;
  dualConfiguration.pausedClockPosition = visualTarget;
  expect(dualOrigin.output->configure(dualConfiguration) ==
             NativeAudioOutputProgress::Done &&
             visualSeconds && audioSeconds &&
             dualOrigin.core.visibleClock().mediaSeconds == *visualSeconds,
         "output activates PCM A while exposing exact paused visual T");
  dualOrigin.core.setPaused(false);
  expect(publishConstant(dualOrigin.ring, 4) &&
             dualOrigin.output->start() == NativeAudioOutputProgress::Done,
         "dual-origin output starts with retained PCM");
  dualOrigin.host.ticks.store(100, std::memory_order_relaxed);
  std::array<float, 8> dualSamples{};
  expect(invokeTracked(dualOrigin.fake, hostTimestamp(100), 4,
                       dualSamples) == noErr &&
             dualOrigin.core.visibleClock().running &&
             dualOrigin.core.visibleClock().anchorMediaSeconds ==
                 *audioSeconds,
         "first output callback publishes source A as a discontinuous "
         "segment rather than relabelling it as T");
  dualOrigin.cleanup();

  FakeHostClock mismatchedHost;
  auto mismatchedRingStorage = std::make_unique<NativePcmRing>(1);
  NativePcmRing &mismatchedRing = *mismatchedRingStorage;
  NativeMediaClock mismatchedClock(
      mismatchedHost.seam(kHostTicksPerSecond * 2U));
  NativeAudioRenderCore mismatchedCore(
      mismatchedRing, mismatchedClock, kHostTicksPerSecond * 2U);
  FakeAudioUnit mismatchedFake;
  WakeCounter mismatchedWake;
  const bool mismatchedAnchor = mismatchedClock.anchorAtHostTicks(
      1, 0, 0.0, 1.0, false);
  std::shared_ptr<NativeAudioOutput> mismatchedOutput =
      NativeAudioOutput::create(mismatchedCore, mismatchedFake.table(),
                                mismatchedWake.seam());
  NativeAudioOutputConfiguration mismatchedConfiguration{
      1, 0, {0, 1}, kHostTicksPerSecond, kSampleRate, {0, 1}};
  expect(mismatchedAnchor && mismatchedOutput &&
             mismatchedOutput->configure(mismatchedConfiguration) ==
                 NativeAudioOutputProgress::Invalid &&
             mismatchedOutput->facts().failure ==
                 NativeAudioOutputFailure::InvalidConfiguration &&
             mismatchedFake.callCount == 0,
         "output rejects a mismatched core/clock host timebase before lookup");
  mismatchedOutput.reset();

  Fixture invalidOrigin;
  NativeAudioOutputConfiguration invalidOriginConfiguration =
      invalidOrigin.configuration();
  invalidOriginConfiguration.mediaOrigin = {-1, 1};
  expect(invalidOrigin.output->configure(invalidOriginConfiguration) ==
             NativeAudioOutputProgress::Invalid,
         "negative media origin is rejected by the output contract");

  Fixture invalidPaused;
  NativeAudioOutputConfiguration invalidPausedConfiguration =
      invalidPaused.configuration();
  invalidPausedConfiguration.pausedClockPosition = {-1, 1};
  expect(invalidPaused.output->configure(invalidPausedConfiguration) ==
             NativeAudioOutputProgress::Invalid,
         "negative paused visual clock position is rejected by the output "
         "contract");
}

void testPartialInitializationAndStartUnwind() {
  constexpr std::array<Call, 9> configurationFailures{
      Call::New,
      Call::GetDeviceFormat,
      Call::SetMaximumFrames,
      Call::GetMaximumFrames,
      Call::SetClientFormat,
      Call::GetClientFormat,
      Call::AttachCallback,
      Call::AddDeviceListener,
      Call::Initialize,
  };
  for (Call failurePoint : configurationFailures) {
    Fixture partial;
    partial.fake.failAt = failurePoint;
    expect(partial.output->configure(partial.configuration()) ==
               NativeAudioOutputProgress::Failed &&
               partial.output->facts().state ==
                   NativeAudioOutputState::Closed,
           "every fallible configuration call has a closed unwind path");
    if (failurePoint != Call::New) {
      expect(partial.fake.sawOrdered({Call::New, Call::Dispose}),
             "every post-instance configuration failure disposes instance");
    }
  }

  Fixture unavailable;
  unavailable.fake.findUnavailable = true;
  expect(unavailable.output->configure(unavailable.configuration()) ==
             NativeAudioOutputProgress::Failed &&
             unavailable.output->facts().failure ==
                 NativeAudioOutputFailure::ComponentUnavailable,
         "missing DefaultOutput component fails without creating an instance");

  Fixture badFrequency;
  badFrequency.fake.hostFrequency =
      std::numeric_limits<double>::quiet_NaN();
  expect(badFrequency.output->configure(badFrequency.configuration()) ==
             NativeAudioOutputProgress::Invalid &&
             badFrequency.output->facts().state ==
                 NativeAudioOutputState::Closed,
         "invalid injected host frequency fails before component lookup");

  Fixture preAttachDispose;
  preAttachDispose.fake.deviceRate =
      std::numeric_limits<double>::quiet_NaN();
  preAttachDispose.fake.failAt = Call::Dispose;
  expect(preAttachDispose.output->configure(
             preAttachDispose.configuration()) ==
             NativeAudioOutputProgress::Failed &&
             NativeAudioOutput::recoverQuarantined().get() ==
                 preAttachDispose.output.get() &&
             preAttachDispose.output->close() ==
                 NativeAudioOutputProgress::Done,
         "pre-attach dispose failure enters the same bounded recovery slot");

  Fixture initFailure;
  initFailure.fake.failAt = Call::Initialize;
  expect(initFailure.output->configure(initFailure.configuration()) ==
             NativeAudioOutputProgress::Failed &&
             initFailure.output->facts().state ==
                 NativeAudioOutputState::Closed &&
             initFailure.fake.sawOrdered(
                 {Call::AttachCallback, Call::AddDeviceListener,
                  Call::Initialize,
                  Call::Uninitialize, Call::DetachCallback,
                  Call::RemoveDeviceListener,
                  Call::Dispose}),
         "initialization failure unwinds callback and instance in order");

  Fixture exceptionFailure;
  exceptionFailure.fake.throwAt = Call::GetDeviceFormat;
  expect(exceptionFailure.output->configure(
             exceptionFailure.configuration()) ==
             NativeAudioOutputProgress::Failed &&
             exceptionFailure.output->facts().failure ==
                 NativeAudioOutputFailure::NativeException &&
             exceptionFailure.fake.sawOrdered({Call::Dispose}),
         "Objective-C exceptions are contained and partial instances dispose");

  Fixture startFailure;
  expect(startFailure.configure(), "start-failure fixture configures");
  startFailure.fake.failAt = Call::Start;
  startFailure.fake.invokeDuringStart = true;
  startFailure.core.setPaused(false);
  expect(startFailure.output->start() ==
             NativeAudioOutputProgress::Failed &&
             startFailure.output->facts().renderedCallbacks == 0 &&
             startFailure.output->facts().rejectedCallbacks == 1 &&
             !startFailure.output->facts().firstCallbackObserved &&
             startFailure.output->close() ==
                 NativeAudioOutputProgress::Done &&
             startFailure.fake.sawOrdered(
                 {Call::Start, Call::Stop, Call::Uninitialize,
                  Call::DetachCallback, Call::RemoveDeviceListener,
                  Call::Dispose}),
         "failed start rejects synchronous callback and fully unwinds");
}

void testTimestampModesAndRationalCarry() {
  Fixture fixture;
  expect(fixture.start() && publishConstant(fixture.ring, 192),
         "timestamp fixture starts with PCM");

  std::array<float, 96> first{};
  fixture.host.ticks.store(1000, std::memory_order_relaxed);
  expect(invokeTracked(fixture.fake, sampleTimestamp(1000, 800.0),
                       48, first) == noErr &&
             fixture.clock.sample().segmentEndHostTicks == 1048 &&
             fixture.output->facts().frameCursor == 48 &&
             fixture.output->facts().firstCallbackObserved,
         "exact integral sample and host timestamp reaches render core");

  std::array<float, 96> second{};
  fixture.host.ticks.store(1048, std::memory_order_relaxed);
  expect(invokeTracked(fixture.fake, sampleTimestamp(1048, 848.0),
                       48, second) == noErr &&
             fixture.clock.sample().segmentEndHostTicks == 1096 &&
             fixture.output->facts().frameCursor == 96,
         "adjacent sample timestamp preserves exact endpoint continuity");

  std::array<float, 96> scalar{};
  fixture.host.ticks.store(1200, std::memory_order_relaxed);
  expect(invokeTracked(fixture.fake, sampleTimestamp(1200, 900.5, 0.5),
                       48, scalar) == noErr &&
             fixture.clock.sample().pendingEndHostTicks == 1224,
         "fractional sample time falls back to exact host-scalar timing");
  fixture.cleanup();

  Fixture nanosecond(1000000000);
  expect(nanosecond.start() && publishConstant(nanosecond.ring, 3),
         "nanosecond host fixture starts with three frames");
  std::array<float, 2> one{};
  nanosecond.host.ticks.store(500000, std::memory_order_relaxed);
  expect(invokeTracked(nanosecond.fake, hostTimestamp(500000), 1, one) ==
             noErr,
         "first fractional host interval renders");
  nanosecond.host.ticks.store(520833, std::memory_order_relaxed);
  expect(invokeTracked(nanosecond.fake, hostTimestamp(520833), 1, one) ==
             noErr,
         "second fractional host interval renders");
  nanosecond.host.ticks.store(541666, std::memory_order_relaxed);
  expect(invokeTracked(nanosecond.fake, hostTimestamp(541666), 1, one) ==
             noErr &&
             nanosecond.clock.sample().pendingEndHostTicks == 562500,
         "integer carry produces 20833, 20833, then 20834 host ticks");
  nanosecond.cleanup();

  Fixture partialPrefix(1000000000);
  expect(partialPrefix.start() && publishConstant(partialPrefix.ring, 3),
         "exact-prefix fixture starts with three of four requested frames");
  std::array<float, 8> partialOutput{};
  partialPrefix.host.ticks.store(0, std::memory_order_relaxed);
  expect(invokeTracked(partialPrefix.fake, hostTimestamp(0), 4,
                       partialOutput) == noErr &&
             partialPrefix.clock.sample().segmentEndHostTicks == 62500 &&
             partialPrefix.output->facts().frameCursor == 3,
         "partial PCM prefix uses its exact rational host endpoint");
  expect(publishConstant(partialPrefix.ring, 3),
         "three frames follow the silent hardware tail");
  partialPrefix.host.ticks.store(83333, std::memory_order_relaxed);
  std::array<float, 6> carriedOutput{};
  expect(invokeTracked(partialPrefix.fake, hostTimestamp(83333), 3,
                       carriedOutput) == noErr &&
             partialPrefix.clock.sample().pendingEndHostTicks == 145833,
         "adapter carry advances across the full hardware callback timeline");
  partialPrefix.cleanup();

  Fixture exactScalar(1000000000);
  expect(exactScalar.start() &&
             publishConstant(exactScalar.ring,
                             NativeAudioOutput::kMaximumFramesPerSlice),
         "non-dyadic-display scalar fixture starts with one full slice");
  std::array<float, NativePcmRing::kSamplesPerSlab> exactOutput{};
  exactScalar.host.ticks.store(0, std::memory_order_relaxed);
  expect(invokeTracked(exactScalar.fake,
                       sampleTimestamp(0, 0.0, 1.000011),
                       NativeAudioOutput::kMaximumFramesPerSlice,
                       exactOutput) == noErr &&
             exactScalar.clock.sample().segmentEndHostTicks == 85334271,
         "IEEE-754 rateScalar produces its exact rational endpoint");
  expect(publishConstant(exactScalar.ring,
                         NativeAudioOutput::kMaximumFramesPerSlice),
         "adjacent exact-scalar slice is available");
  exactScalar.host.ticks.store(85334271, std::memory_order_relaxed);
  expect(invokeTracked(exactScalar.fake,
                       sampleTimestamp(85334271, 4096.0, 1.000011),
                       NativeAudioOutput::kMaximumFramesPerSlice,
                       exactOutput) == noErr &&
             exactScalar.output->facts().renderedCallbacks == 2 &&
             exactScalar.clock.sample().segmentEndHostTicks == 170668543,
         "exact scalar remainder preserves the next adjacent boundary");
}

// A 44100 Hz stream on a 48000 Hz device. The device nominal rate is never
// touched; the output AudioUnit's own converter bridges the two at the
// input-scope boundary, so the client format and every host-tick computation
// stay entirely in the 44100 domain. The client slice size that CoreAudio then
// delivers is 512 * 44100 / 48000 = 470.4, i.e. an alternating 470/471, which
// makes the carried integer remainder load-bearing on every callback.
void testStreamRateBelowDeviceRateUsesUnitConverter() {
  constexpr std::uint32_t kStreamRate = 44100;
  constexpr std::uint64_t kConverterHostFrequency = 24000000;

  Fixture converted(kConverterHostFrequency);
  converted.fake.deviceRate = 48000.0;
  expect(converted.anchored && converted.output &&
             converted.output->configure(
                 converted.configuration(kStreamRate)) ==
                 NativeAudioOutputProgress::Done &&
             converted.output->facts().failure ==
                 NativeAudioOutputFailure::None,
         "a 44100 stream configures against a 48000 default output device");
  expect(converted.fake.clientFormat.mSampleRate ==
             static_cast<Float64>(kStreamRate) &&
             converted.fake.clientFormat.mFormatID == kAudioFormatLinearPCM &&
             converted.fake.clientFormat.mChannelsPerFrame == 2 &&
             converted.fake.clientFormat.mBytesPerFrame == 8 &&
             converted.fake.deviceRate == 48000.0 &&
             NativeAudioOutputTestAccess::deviceRate(*converted.output) ==
                 48000.0,
         "the client format carries the stream rate while the device keeps its "
         "own nominal rate");
  expect(converted.output->facts().sampleRate == kStreamRate,
         "published facts report the stream rate, not the device rate");

  converted.core.setPaused(false);
  expect(converted.output->start() == NativeAudioOutputProgress::Done,
         "a 44100 stream starts on a 48000 device");

  // The AU-internal converter reports client-domain slices, so the exact
  // rational endpoints must chain across a non-uniform 470/471/470 sequence.
  std::array<float, 940> shortSlice{};
  std::array<float, 942> longSlice{};
  converted.host.ticks.store(0, std::memory_order_relaxed);
  expect(publishConstant(converted.ring, 470) &&
             invokeTracked(converted.fake, hostTimestamp(0), 470,
                           shortSlice) == noErr &&
             converted.output->facts().frameCursor == 470 &&
             converted.clock.sample().segmentEndHostTicks == 255782,
         "first 470-frame client slice lands on its exact rational endpoint");
  converted.host.ticks.store(255782, std::memory_order_relaxed);
  expect(publishConstant(converted.ring, 471) &&
             invokeTracked(converted.fake, hostTimestamp(255782), 471,
                           longSlice) == noErr &&
             converted.output->facts().frameCursor == 941 &&
             converted.clock.sample().segmentEndHostTicks == 512108,
         "adjacent 471-frame client slice carries the remainder forward");
  converted.host.ticks.store(512108, std::memory_order_relaxed);
  expect(publishConstant(converted.ring, 470) &&
             invokeTracked(converted.fake, hostTimestamp(512108), 470,
                           shortSlice) == noErr &&
             converted.output->facts().frameCursor == 1411 &&
             converted.clock.sample().segmentEndHostTicks == 767891 &&
             converted.output->facts().failure ==
                 NativeAudioOutputFailure::None,
         "the carried remainder makes 1411 client frames end at the exact "
         "floor 767891 rather than the 767890 a per-slice truncation gives");

  // Direct evaluation of the adapter's rational input, seeded with the carry
  // state each preceding slice leaves behind.
  const std::uint64_t unitScalarBits = std::bit_cast<std::uint64_t>(1.0);
  NativeAudioRenderInput input{};
  __uint128_t remainder = 0;
  __uint128_t denominator = 0;
  std::uint64_t scalarBits = 0;

  NativeAudioOutputTestAccess::seedCarry(*converted.output, 0, 0, 0, 0);
  expect(NativeAudioOutputTestAccess::callbackInput(
             *converted.output, hostTimestamp(0), 470, &input, &remainder,
             &denominator, &scalarBits) &&
             input.sampleRate == kStreamRate &&
             input.hostTickDenominator == static_cast<__uint128_t>(44100) &&
             input.hostTickNumeratorPerFrame ==
                 static_cast<__uint128_t>(kConverterHostFrequency) &&
             input.hostTickRemainderAtStart == 0 &&
             input.endHostTicks == 255782 &&
             denominator == static_cast<__uint128_t>(44100) &&
             remainder == static_cast<__uint128_t>(13800) &&
             scalarBits == unitScalarBits,
         "callbackInput denominates 470 client frames in the 44100 domain");

  NativeAudioOutputTestAccess::seedCarry(
      *converted.output, static_cast<__uint128_t>(13800),
      static_cast<__uint128_t>(44100), unitScalarBits, 255782);
  expect(NativeAudioOutputTestAccess::callbackInput(
             *converted.output, hostTimestamp(255782), 471, &input,
             &remainder, &denominator, &scalarBits) &&
             input.hostTickDenominator == static_cast<__uint128_t>(44100) &&
             input.hostTickRemainderAtStart ==
                 static_cast<__uint128_t>(13800) &&
             input.firstHostTicks == 255782 &&
             input.endHostTicks == 512108 &&
             remainder == static_cast<__uint128_t>(37200),
         "an exactly adjacent 471-frame slice consumes the carried remainder");

  NativeAudioOutputTestAccess::seedCarry(
      *converted.output, static_cast<__uint128_t>(37200),
      static_cast<__uint128_t>(44100), unitScalarBits, 512108);
  expect(NativeAudioOutputTestAccess::callbackInput(
             *converted.output, hostTimestamp(512108), 470, &input,
             &remainder, &denominator, &scalarBits) &&
             input.hostTickRemainderAtStart ==
                 static_cast<__uint128_t>(37200) &&
             input.firstHostTicks == 512108 &&
             input.endHostTicks == 767891 &&
             remainder == static_cast<__uint128_t>(6900),
         "the accumulated carry lengthens the third slice by one host tick");

  // A device that changes away from the latched rate is still fatal, even
  // though the stream rate never equalled it.
  converted.fake.changeDeviceRate(44100.0);
  expect(converted.output->facts().failure ==
             NativeAudioOutputFailure::DeviceRateMismatch &&
             !converted.output->facts().started,
         "a live device rate change remains fatal under unit conversion");
  converted.cleanup();
}

void testMalformedAndPostStopCallbacks() {
  Fixture nilList;
  expect(nilList.start(), "nil-list fixture starts");
  std::array<float, 16> nilListStorage{};
  expect(nilList.fake.invoke(hostTimestamp(0), 8,
                             nilListStorage.data(),
                             sizeof(nilListStorage), 2, 0) ==
             kAudio_ParamError &&
             nilList.output->facts().failure ==
                 NativeAudioOutputFailure::InvalidCallbackBuffer,
         "nil AudioBufferList is rejected without dereference");
  nilList.cleanup();

  Fixture malformed;
  expect(malformed.start(), "malformed-buffer fixture starts");
  std::array<float, 16> data{};
  data.fill(7.0F);
  expect(malformed.fake.invoke(hostTimestamp(0), 8, nullptr,
                               sizeof(data)) == kAudio_ParamError &&
             malformed.output->facts().failure ==
                 NativeAudioOutputFailure::InvalidCallbackBuffer &&
             malformed.wake.calls.load(std::memory_order_relaxed) == 1,
         "nil callback storage is rejected, fatal, and wakes after exit");
  malformed.cleanup();

  Fixture oversized;
  expect(oversized.start(), "oversized-buffer fixture starts");
  std::array<float, NativePcmRing::kSamplesPerSlab> bounded{};
  bounded.fill(9.0F);
  expect(oversized.fake.invoke(
             hostTimestamp(0),
             NativeAudioOutput::kMaximumFramesPerSlice + 1U,
             bounded.data(), sizeof(bounded)) == kAudio_ParamError &&
             std::all_of(bounded.begin(), bounded.end(),
                         [](float value) { return value == 0.0F; }),
         "oversized callback is bounded, silenced, and rejected");
  oversized.cleanup();

  Fixture stopped;
  expect(stopped.start() && publishConstant(stopped.ring, 8) &&
             stopped.output->stop() == NativeAudioOutputProgress::Done,
         "post-stop fixture proves admitted callbacks quiescent");
  const auto before = stopped.core.stats();
  std::array<float, 16> postStop{};
  postStop.fill(5.0F);
  expect(stopped.fake.invoke(hostTimestamp(100), 8, postStop.data(),
                             sizeof(postStop)) == noErr &&
             std::all_of(postStop.begin(), postStop.end(),
                         [](float value) { return value == 0.0F; }) &&
             stopped.core.stats().callbacks == before.callbacks &&
             stopped.output->facts().rejectedCallbacks == 1,
         "callback after stop can only silence and never reaches render core");

  std::array<float, NativePcmRing::kSamplesPerSlab> oversizedPostStop{};
  oversizedPostStop.fill(5.0F);
  expect(stopped.fake.invoke(
             hostTimestamp(108),
             NativeAudioOutput::kMaximumFramesPerSlice + 1U,
             oversizedPostStop.data(), sizeof(oversizedPostStop)) ==
             kAudio_ParamError &&
             std::all_of(oversizedPostStop.begin(),
                         oversizedPostStop.end(),
                         [](float value) { return value == 0.0F; }),
         "oversized post-stop callback is bounded, silenced, and fails closed");
}

void testFrameAndTimestampOverflow() {
  Fixture hostOverflow;
  expect(hostOverflow.start() && publishConstant(hostOverflow.ring, 16),
         "host-overflow fixture starts with PCM");
  std::array<float, 32> samples{};
  expect(hostOverflow.fake.invoke(
             hostTimestamp(std::numeric_limits<std::uint64_t>::max() - 8U),
             16, samples.data(), sizeof(samples)) == kAudio_ParamError &&
             hostOverflow.output->facts().failure ==
                 NativeAudioOutputFailure::InvalidCallbackTimestamp &&
             hostOverflow.ring.readableFrames(1).frames == 16,
         "host endpoint overflow is rejected before PCM consumption");
  hostOverflow.cleanup();

  Fixture scalarOverflow;
  expect(scalarOverflow.start() && publishConstant(scalarOverflow.ring, 8),
         "rate-scalar overflow fixture starts with PCM");
  AudioTimeStamp hugeScalar = sampleTimestamp(100, 0.0);
  hugeScalar.mRateScalar = 4294967296.0;
  expect(scalarOverflow.fake.invoke(hugeScalar, 8, samples.data(),
                                    16U * sizeof(float)) ==
             kAudio_ParamError &&
         scalarOverflow.output->facts().failure ==
                 NativeAudioOutputFailure::InvalidCallbackTimestamp,
         "out-of-contract rate scalar is rejected deterministically");
  scalarOverflow.cleanup();

  constexpr std::uint64_t maximumExactFrame = std::uint64_t{1} << 53U;
  Fixture frameOverflow(
      kHostTicksPerSecond,
      mediaSecondsAtFrame({0, 1}, maximumExactFrame, kSampleRate));
  expect(frameOverflow.anchored &&
             frameOverflow.output->configure(
                 frameOverflow.configuration(kSampleRate,
                                             maximumExactFrame)) ==
                 NativeAudioOutputProgress::Done,
         "frame-overflow fixture activates at maximum exact cursor");
  frameOverflow.core.setPaused(false);
  expect(frameOverflow.output->start() == NativeAudioOutputProgress::Done &&
             publishConstant(frameOverflow.ring, 1),
         "frame-overflow fixture starts with one PCM frame");
  std::array<float, 2> one{};
  expect(frameOverflow.fake.invoke(hostTimestamp(100), 1, one.data(),
                                   sizeof(one)) == noErr &&
             frameOverflow.output->facts().failure ==
                 NativeAudioOutputFailure::RenderCoreFailed &&
             frameOverflow.output->facts().frameCursor ==
                 maximumExactFrame,
         "media-frame exactness overflow is fatal without cursor advance");
}

struct BlockingHook {
  std::atomic<bool> entered{false};
  std::atomic<bool> release{false};

  static void run(void *context) noexcept {
    auto &hook = *static_cast<BlockingHook *>(context);
    hook.entered.store(true, std::memory_order_release);
    while (!hook.release.load(std::memory_order_acquire)) {
      std::this_thread::yield();
    }
  }
};

void testDeviceChangeWinsStartCommit() {
  Fixture fixture;
  expect(fixture.configure(),
         "start-commit-race fixture configures with listener proof");
  fixture.core.setPaused(false);
  BlockingHook hook;
  NativeAudioOutputTestAccess::setBeforeStartCommitHook(
      *fixture.output, &BlockingHook::run, &hook);
  NativeAudioOutputProgress startProgress = NativeAudioOutputProgress::Done;
  std::thread starter([&] { startProgress = fixture.output->start(); });
  while (!hook.entered.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }

  fixture.fake.changeDeviceRate(44100.0);
  hook.release.store(true, std::memory_order_release);
  starter.join();
  NativeAudioOutputTestAccess::setBeforeStartCommitHook(
      *fixture.output, nullptr, nullptr);
  expect(startProgress == NativeAudioOutputProgress::Failed &&
             fixture.output->facts().failure ==
                 NativeAudioOutputFailure::DeviceRateMismatch &&
             !fixture.output->facts().started &&
             fixture.output->facts().renderedCallbacks == 0,
         "device invalidation atomically defeats the pending start commit");
}

void testStopRaceAndQuarantineLifetime() {
  Fixture fixture;
  expect(fixture.start() && publishConstant(fixture.ring, 32),
         "stop-race fixture starts with PCM");
  BlockingHook hook;
  NativeAudioRenderCoreTestAccess::setAfterPreflightHook(
      fixture.core, &BlockingHook::run, &hook);
  std::array<float, 64> output{};
  std::thread callback([&] {
    static_cast<void>(fixture.fake.invoke(hostTimestamp(100), 32,
                                          output.data(), sizeof(output)));
  });
  while (!hook.entered.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }

  std::weak_ptr<NativeAudioOutput> lifetime = fixture.output;
  expect(fixture.output->stop() == NativeAudioOutputProgress::Quiescing &&
             !fixture.output->facts().callbackQuiescent,
         "stop never claims quiescence while a render is admitted");
  expect(fixture.output->close() == NativeAudioOutputProgress::Quiescing,
         "close remains nonblocking while the admitted callback is live");
  fixture.output.reset();
  std::shared_ptr<NativeAudioOutput> recovered =
      NativeAudioOutput::recoverQuarantined();
  expect(recovered && !lifetime.expired(),
         "premature wrapper release retains callback context in quarantine");

  FakeHostClock secondHost;
  auto secondRingStorage = std::make_unique<NativePcmRing>(1);
  NativePcmRing &secondRing = *secondRingStorage;
  NativeMediaClock secondClock(secondHost.seam(kHostTicksPerSecond));
  NativeAudioRenderCore secondCore(secondRing, secondClock,
                                   kHostTicksPerSecond);
  WakeCounter secondWake;
  expect(!NativeAudioOutput::create(secondCore, fixture.fake.table(),
                                    secondWake.seam()),
         "single quarantine cap rejects a second output");

  // Quiescing deliberately wakes the lifecycle owner while the callback is
  // still live. Rearm here so the counters below describe only the final
  // callback-exit notification.
  fixture.wake.clear();
  fixture.wake.calls.store(0, std::memory_order_relaxed);
  fixture.wake.orderingViolations.store(0, std::memory_order_relaxed);
  hook.release.store(true, std::memory_order_release);
  callback.join();
  NativeAudioRenderCoreTestAccess::setAfterPreflightHook(
      fixture.core, nullptr, nullptr);
  expect(fixture.wake.calls.load(std::memory_order_relaxed) == 1 &&
             fixture.wake.orderingViolations.load(
                 std::memory_order_relaxed) == 0 &&
             recovered->facts().callbackEntries == 0 &&
             recovered->facts().admittedCallbacks == 0,
         "final callback-exit wake observes both lifecycle guards released");
  fixture.wake.clear();
  expect(recovered->close() == NativeAudioOutputProgress::Done,
         "recovered owner completes teardown after wake-driven retry");
  recovered.reset();
  expect(lifetime.expired(),
         "successful detach and dispose release quarantined self-owner");
}

void testStoppedCallbackCannotCrossRestartEpoch() {
  Fixture fixture;
  expect(fixture.start() &&
             fixture.output->stop() == NativeAudioOutputProgress::Done,
         "restart-race fixture reaches a fully stopped state");
  const NativeAudioRenderStats before = fixture.core.stats();
  BlockingHook hook;
  NativeAudioOutputTestAccess::setBeforeAdmissionHook(
      *fixture.output, &BlockingHook::run, &hook);
  std::array<float, 16> staleOutput{};
  staleOutput.fill(6.0F);
  std::thread staleCallback([&] {
    static_cast<void>(fixture.fake.invoke(hostTimestamp(10), 8,
                                          staleOutput.data(),
                                          sizeof(staleOutput)));
  });
  while (!hook.entered.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }

  expect(fixture.output->start() == NativeAudioOutputProgress::Quiescing &&
             !fixture.output->facts().started,
         "restart cannot reopen admission while an old callback entry lives");
  hook.release.store(true, std::memory_order_release);
  staleCallback.join();
  NativeAudioOutputTestAccess::setBeforeAdmissionHook(
      *fixture.output, nullptr, nullptr);
  expect(std::all_of(staleOutput.begin(), staleOutput.end(),
                     [](float value) { return value == 0.0F; }) &&
             fixture.core.stats().callbacks == before.callbacks &&
             fixture.output->facts().callbackQuiescent &&
             fixture.output->start() == NativeAudioOutputProgress::Done,
         "stale stopped callback drains silently before the next epoch starts");
}

// Stopping the output while paused is the largest single wake-rate lever in
// the process: every render callback is a real-time thread wake and a paused
// callback does nothing but memset zeroes. This is the output-level proof
// that the transition is a no-op on everything the clock and the A/V boundary
// are made of. The device really idles (AudioOutputUnitStop is issued), the
// generation, stream cursor and retained PCM survive, a callback the HAL
// delivers after the stop is benign, and the first callback after the restart
// resumes at exactly the frame the pause left behind.
void testPauseSuspendKeepsStreamPositionAcrossRestart() {
  constexpr std::uint32_t kFrames = 128;
  Fixture fixture;
  fixture.core.setGain(1.0F);
  expect(fixture.start() && publishConstant(fixture.ring, kFrames * 2),
         "pause-suspend fixture starts with two callbacks of retained PCM");
  std::array<float, kFrames * NativePcmRing::kChannels> samples{};
  fixture.host.ticks.store(0, std::memory_order_relaxed);
  // The gain ramp runs over this first callback, so only its tail is at unit
  // gain; the resumed callback below is compared at full gain instead.
  expect(invokeTracked(fixture.fake, hostTimestamp(0), kFrames, samples) ==
             noErr &&
             fixture.core.visibleClock().running &&
             samples[(kFrames - 1) * NativePcmRing::kChannels] > 0.9F,
         "first callback consumes retained PCM and runs the clock");

  // Pause exactly as production does: the render core publishes the pause
  // boundary from its own callback, and that boundary is what freezes the
  // authoritative clock.
  fixture.core.setPaused(true);
  fixture.host.ticks.store(kFrames, std::memory_order_relaxed);
  samples.fill(7.0F);
  expect(invokeTracked(fixture.fake, hostTimestamp(kFrames), kFrames,
                       samples) == noErr &&
             std::all_of(samples.begin(), samples.end(),
                         [](float value) { return value == 0.0F; }) &&
             !fixture.clock.sample().running,
         "paused callback silences its buffer and publishes the pause "
         "boundary");
  const wam::macos::NativeMediaClockSnapshot pausedClock = fixture.clock.sample();
  const NativeAudioOutputFacts pausedFacts = fixture.output->facts();
  expect(pausedFacts.frameCursor == kFrames,
         "a paused callback advances no stream frames");

  // Suspend. AudioOutputUnitStop must actually be issued -- revoking
  // admission alone would leave the HAL calling us to memset silence.
  const std::size_t callsBeforeStop = fixture.fake.callCount;
  expect(fixture.output->stop() == NativeAudioOutputProgress::Done &&
             !fixture.fake.started,
         "a settled pause stops the output unit");
  {
    bool sawStop = false;
    for (std::size_t index = callsBeforeStop;
         index < fixture.fake.callCount; ++index) {
      sawStop = sawStop || fixture.fake.calls[index] == Call::Stop;
    }
    expect(sawStop, "the suspend issues AudioOutputUnitStop, not merely a "
                    "logical admission revoke");
  }

  // The owner-side settlement is clock-neutral. Advance the host clock first
  // so a pause() that was not idempotent would visibly move the published
  // media position.
  fixture.host.ticks.store(kFrames * 8, std::memory_order_relaxed);
  expect(fixture.clock.pause(1) && fixture.core.settlePausedAfterStop(1),
         "the stopped output settles the clock and the callback-local run");
  const wam::macos::NativeMediaClockSnapshot settledClock = fixture.clock.sample();
  expect(settledClock.publicationSerial == pausedClock.publicationSerial &&
             settledClock.mediaSeconds == pausedClock.mediaSeconds &&
             settledClock.anchorHostTicks == pausedClock.anchorHostTicks &&
             settledClock.anchorMediaSeconds ==
                 pausedClock.anchorMediaSeconds &&
             !settledClock.running,
         "settling an already-paused clock publishes nothing and moves the "
         "playhead by exactly zero");

  const NativeAudioOutputFacts stoppedFacts = fixture.output->facts();
  expect(stoppedFacts.state == NativeAudioOutputState::Stopped &&
             !stoppedFacts.started && stoppedFacts.stopped &&
             stoppedFacts.callbackQuiescent &&
             stoppedFacts.generation == pausedFacts.generation &&
             stoppedFacts.frameCursor == pausedFacts.frameCursor,
         "a suspended output keeps its generation and stream cursor");

  // A callback the HAL delivers after Stop returns must be benign.
  samples.fill(5.0F);
  expect(fixture.fake.invoke(hostTimestamp(kFrames * 8), kFrames,
                             samples.data(), sizeof(samples)) == noErr &&
             std::all_of(samples.begin(), samples.end(),
                         [](float value) { return value == 0.0F; }) &&
             fixture.output->facts().frameCursor ==
                 pausedFacts.frameCursor &&
             !fixture.output->facts().fatal &&
             fixture.clock.sample().publicationSerial ==
                 pausedClock.publicationSerial,
         "a late callback under a stopped output silences without touching "
         "the cursor or the clock");

  // Resume. The ring was never flushed, so this must play the retained PCM.
  fixture.core.setPaused(false);
  const std::size_t callsBeforeStart = fixture.fake.callCount;
  expect(fixture.output->start() == NativeAudioOutputProgress::Done &&
             fixture.fake.started,
         "a suspended output restarts without a re-activation");
  {
    bool sawStart = false;
    for (std::size_t index = callsBeforeStart;
         index < fixture.fake.callCount; ++index) {
      sawStart = sawStart || fixture.fake.calls[index] == Call::Start;
    }
    expect(sawStart, "the resume issues AudioOutputUnitStart");
  }

  fixture.host.ticks.store(kFrames * 9, std::memory_order_relaxed);
  samples.fill(0.0F);
  expect(invokeTracked(fixture.fake, hostTimestamp(kFrames * 9), kFrames,
                       samples) == noErr &&
             samples[0] == 1.0F &&
             samples[(kFrames - 1) * NativePcmRing::kChannels] == 1.0F,
         "the first callback after the restart plays the retained PCM at the "
         "gain the pause left behind -- no re-ramp, so no pop");
  const wam::macos::NativeMediaClockSnapshot resumedClock = fixture.clock.sample();
  expect(resumedClock.running && resumedClock.generation == 1 &&
             resumedClock.anchorMediaSeconds == pausedClock.mediaSeconds &&
             fixture.output->facts().frameCursor == kFrames * 2,
         "the resumed segment starts at exactly the media position and "
         "stream frame the pause froze");
  expect(fixture.core.stats().failure == wam::macos::NativeAudioRenderFailure::None &&
             fixture.output->facts().failure ==
                 NativeAudioOutputFailure::None,
         "a full pause/suspend/resume cycle latches no failure");
}

void testWakeGatesResetAcrossGenerationActivation() {
  Fixture fixture;
  expect(fixture.start(),
         "wake-reset fixture starts its first generation empty");
  fixture.wake.clear();
  constexpr std::uint32_t kFrames = 128;
  std::array<float, kFrames * NativePcmRing::kChannels> samples{};
  fixture.host.ticks.store(0, std::memory_order_relaxed);
  expect(invokeTracked(fixture.fake, hostTimestamp(0), kFrames,
                       samples) == noErr &&
             fixture.wake.calls.load(std::memory_order_relaxed) == 1,
         "first-generation underrun disarms both wake gates");

  fixture.wake.clear();
  fixture.core.setPaused(true);
  fixture.host.ticks.store(kFrames, std::memory_order_relaxed);
  expect(fixture.output->stop() == NativeAudioOutputProgress::Done &&
             fixture.core.settlePausedAfterStop(1) &&
             fixture.ring.flush(2) && fixture.clock.seek(1, 2, 0.0) &&
             fixture.output->activate(2, 0, {0, 1}, {0, 1}) ==
                 NativeAudioOutputProgress::Done,
         "quiescent seek activates a distinct output generation");
  fixture.core.setPaused(false);
  expect(fixture.output->start() == NativeAudioOutputProgress::Done,
         "second generation reopens output admission");
  fixture.host.ticks.store(kFrames, std::memory_order_relaxed);
  expect(invokeTracked(fixture.fake, hostTimestamp(kFrames), kFrames,
                       samples) == noErr,
         "second-generation empty callback remains valid");

  const NativeAudioOutputFacts facts = fixture.output->facts();
  expect(fixture.wake.calls.load(std::memory_order_relaxed) == 2 &&
             facts.callbackWakeRequests == 2 &&
             facts.callbackWakeSignals == 2 &&
             facts.refillWakeRequests == 0 &&
             facts.underrunWakeRequests == 2,
         "generation activation resets the underrun wake edge while an "
         "always-empty ring never retires a slab to refill");
}

// The refill wake is the producer's admission edge: it fires exactly when the
// ring retires a slab, because a slab is the unit the producer publishes. A
// frame-count threshold cannot express this. The producer publishes one
// converter output per slab, so a full ring holds only kSlabCount packets'
// worth of frames, and any slab-derived frame threshold would sit above every
// occupancy the producer can reach and latch the edge off permanently.
void testRefillEdgeTracksSlabRetirement() {
  constexpr std::uint32_t kSlabFrames = 128;
  Fixture fixture;
  expect(fixture.start() &&
             publishConstant(fixture.ring, kSlabFrames) &&
             publishConstant(fixture.ring, kSlabFrames) &&
             publishConstant(fixture.ring, kSlabFrames),
         "slab-retirement fixture starts with three queued producer slabs");
  fixture.wake.clear();

  std::array<float, (kSlabFrames / 2U) * NativePcmRing::kChannels> half{};
  std::uint64_t hostTicks = 0;
  fixture.host.ticks.store(hostTicks, std::memory_order_relaxed);
  expect(invokeTracked(fixture.fake, hostTimestamp(hostTicks),
                       kSlabFrames / 2U, half) == noErr &&
             fixture.wake.calls.load(std::memory_order_relaxed) == 0 &&
             fixture.output->facts().refillWakeRequests == 0,
         "the first callback of a generation only baselines the queue depth");
  hostTicks += kSlabFrames / 2U;

  fixture.host.ticks.store(hostTicks, std::memory_order_relaxed);
  expect(invokeTracked(fixture.fake, hostTimestamp(hostTicks),
                       kSlabFrames / 2U, half) == noErr &&
             fixture.wake.calls.load(std::memory_order_relaxed) == 1 &&
             fixture.output->facts().refillWakeRequests == 1,
         "retiring one slab publishes exactly one producer-admission wake");
  hostTicks += kSlabFrames / 2U;

  fixture.wake.clear();
  fixture.host.ticks.store(hostTicks, std::memory_order_relaxed);
  expect(invokeTracked(fixture.fake, hostTimestamp(hostTicks),
                       kSlabFrames / 2U, half) == noErr &&
             fixture.wake.calls.load(std::memory_order_relaxed) == 1 &&
             fixture.output->facts().refillWakeRequests == 1,
         "consuming inside a retained slab publishes no producer edge");
  hostTicks += kSlabFrames / 2U;

  fixture.host.ticks.store(hostTicks, std::memory_order_relaxed);
  expect(invokeTracked(fixture.fake, hostTimestamp(hostTicks),
                       kSlabFrames / 2U, half) == noErr &&
             fixture.wake.calls.load(std::memory_order_relaxed) == 2 &&
             fixture.output->facts().refillWakeRequests == 2,
         "each further slab retirement publishes exactly one more edge");
  hostTicks += kSlabFrames / 2U;

  // One slab remains queued. A quiescent generation transition must drop the
  // observed depth, otherwise the flushed ring would look like a retirement
  // and publish a producer edge the new generation never earned.
  fixture.wake.clear();
  fixture.core.setPaused(true);
  expect(fixture.output->stop() == NativeAudioOutputProgress::Done &&
             fixture.clock.pause(1) && fixture.core.settlePausedAfterStop(1) &&
             fixture.ring.flush(2) && fixture.clock.seek(1, 2, 0.0) &&
             fixture.output->activate(2, 0, {0, 1}, {0, 1}) ==
                 NativeAudioOutputProgress::Done,
         "quiescent seek flushes the ring and activates a new generation");
  fixture.core.setPaused(false);
  expect(fixture.output->start() == NativeAudioOutputProgress::Done,
         "slab-retirement fixture reopens output admission");
  fixture.host.ticks.store(hostTicks, std::memory_order_relaxed);
  expect(invokeTracked(fixture.fake, hostTimestamp(hostTicks),
                       kSlabFrames / 2U, half) == noErr &&
             fixture.output->facts().refillWakeRequests == 2,
         "activation rebaselines the queue depth instead of publishing a "
         "spurious producer edge for the flushed slabs");
}

void testWakeAndListenerPinsDrainBeforeClose() {
  Fixture callbackWake;
  // A short playable prefix keeps this callback's wake reason independent of
  // the producer-admission edge, which never fires on the first observation.
  expect(callbackWake.start() && publishConstant(callbackWake.ring, 4),
         "wake-pin fixture starts with a short PCM prefix");
  callbackWake.wake.block.store(true, std::memory_order_release);
  std::array<float, 16> callbackOutput{};
  std::thread callback([&] {
    static_cast<void>(callbackWake.fake.invoke(
        hostTimestamp(0), 8, callbackOutput.data(), sizeof(callbackOutput)));
  });
  while (!callbackWake.wake.entered.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }
  expect(callbackWake.output->facts().callbackEntries == 0 &&
             callbackWake.output->facts().admittedCallbacks == 0 &&
             callbackWake.output->close() ==
                 NativeAudioOutputProgress::Quiescing,
         "post-render wake stays lifetime-pinned after render guards drain");
  callbackWake.wake.release.store(true, std::memory_order_release);
  callback.join();
  expect(callbackWake.output->close() == NativeAudioOutputProgress::Done,
         "close completes only after the in-progress wake returns");

  Fixture listenerWake;
  expect(listenerWake.start(),
         "listener-pin fixture starts with live-rate listener");
  listenerWake.wake.block.store(true, std::memory_order_release);
  std::thread listener(
      [&] { listenerWake.fake.changeDeviceRate(44100.0); });
  while (!listenerWake.wake.entered.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }
  expect(listenerWake.output->close() ==
             NativeAudioOutputProgress::Quiescing,
         "close drains an in-progress device listener before context release");
  listenerWake.wake.release.store(true, std::memory_order_release);
  listener.join();
  expect(listenerWake.output->close() == NativeAudioOutputProgress::Done,
         "listener teardown completes after the pinned notification exits");

  Fixture coalescedExit;
  expect(coalescedExit.start() &&
             publishConstant(coalescedExit.ring,
                             NativePcmRing::kFramesPerSlab) &&
             publishConstant(coalescedExit.ring,
                             NativePcmRing::kFramesPerSlab) &&
             publishConstant(coalescedExit.ring,
                             NativePcmRing::kFramesPerSlab),
         "coalesced-exit fixture starts with a fully queued ring");
  BlockingHook preflight;
  BlockingHook afterWake;
  NativeAudioRenderCoreTestAccess::setAfterPreflightHook(
      coalescedExit.core, &BlockingHook::run, &preflight);
  NativeAudioOutputTestAccess::setAfterCallbackWakeHook(
      *coalescedExit.output, &BlockingHook::run, &afterWake);
  std::array<float, 16> silent{};
  std::thread coalescedCallback([&] {
    static_cast<void>(coalescedExit.fake.invoke(
        hostTimestamp(300), 8, silent.data(), sizeof(silent)));
  });
  while (!preflight.entered.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }
  expect(coalescedExit.output->close() ==
             NativeAudioOutputProgress::Quiescing,
         "live full-ring callback makes close retry through the wake edge");
  coalescedExit.wake.clear();
  coalescedExit.wake.calls.store(0, std::memory_order_relaxed);
  coalescedExit.wake.orderingViolations.store(0,
                                               std::memory_order_relaxed);
  preflight.release.store(true, std::memory_order_release);
  while (!afterWake.entered.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }
  coalescedExit.wake.clear();
  afterWake.release.store(true, std::memory_order_release);
  coalescedCallback.join();
  NativeAudioRenderCoreTestAccess::setAfterPreflightHook(
      coalescedExit.core, nullptr, nullptr);
  NativeAudioOutputTestAccess::setAfterCallbackWakeHook(
      *coalescedExit.output, nullptr, nullptr);
  const NativeAudioOutputFacts coalescedFacts =
      coalescedExit.output->facts();
  expect(coalescedExit.wake.pending.load(std::memory_order_acquire) &&
             coalescedExit.wake.calls.load(std::memory_order_relaxed) == 2 &&
             coalescedExit.wake.orderingViolations.load(
                 std::memory_order_relaxed) == 0 &&
             coalescedFacts.callbackWakeRequests == 1 &&
             coalescedFacts.callbackWakeSignals == 2 &&
             coalescedFacts.refillWakeRequests == 0 &&
             coalescedFacts.underrunWakeRequests == 0 &&
             coalescedFacts.stateWakeRequests == 0,
         "lifecycle and final-drain wakes rearm without a media wake reason");
  coalescedExit.wake.clear();
  expect(coalescedExit.output->close() == NativeAudioOutputProgress::Done,
         "post-release render wake drives teardown to completion");

  Fixture listenerExit;
  expect(listenerExit.start(),
         "listener-exit fixture starts before device invalidation");
  listenerExit.wake.pending.store(true, std::memory_order_release);
  BlockingHook afterListenerWake;
  NativeAudioOutputTestAccess::setAfterListenerWakeHook(
      *listenerExit.output, &BlockingHook::run, &afterListenerWake);
  std::thread changingListener(
      [&] { listenerExit.fake.changeDeviceRate(44100.0); });
  while (!afterListenerWake.entered.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }
  listenerExit.wake.clear();
  expect(listenerExit.output->close() ==
             NativeAudioOutputProgress::Quiescing &&
             listenerExit.wake.pending.load(std::memory_order_acquire) &&
             listenerExit.wake.calls.load(std::memory_order_relaxed) == 1,
         "Quiescing retry rearms a coalesced device-listener wake");
  listenerExit.wake.clear();
  afterListenerWake.release.store(true, std::memory_order_release);
  changingListener.join();
  NativeAudioOutputTestAccess::setAfterListenerWakeHook(
      *listenerExit.output, nullptr, nullptr);
  expect(listenerExit.wake.pending.load(std::memory_order_acquire) &&
             listenerExit.wake.calls.load(std::memory_order_relaxed) == 2,
         "final listener bridge release signals after immediate wake consume");
  listenerExit.wake.clear();
  expect(listenerExit.output->close() == NativeAudioOutputProgress::Done,
         "post-release listener wake drives teardown to completion");
}

void testClosedFactsIgnoreReusedProcessBridge() {
  Fixture retainedClosed;
  expect(retainedClosed.configure(),
         "first retained output configures before bridge reuse");
  BlockingHook factsHook;
  NativeAudioOutputTestAccess::setAfterFactsBridgeOwnerHook(
      *retainedClosed.output, &BlockingHook::run, &factsHook);
  NativeAudioOutputFacts retainedFacts;
  std::thread samplingFacts(
      [&] { retainedFacts = retainedClosed.output->facts(); });
  while (!factsHook.entered.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }
  expect(retainedClosed.output->close() ==
             NativeAudioOutputProgress::Done,
         "first output closes after facts captures its bridge ownership");

  Fixture active;
  expect(active.start() && publishConstant(active.ring, 8),
         "second output reuses the process callback bridge");
  BlockingHook hook;
  NativeAudioRenderCoreTestAccess::setAfterPreflightHook(
      active.core, &BlockingHook::run, &hook);
  std::array<float, 16> samples{};
  std::thread callback([&] {
    static_cast<void>(active.fake.invoke(hostTimestamp(400), 8,
                                         samples.data(), sizeof(samples)));
  });
  while (!hook.entered.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }

  factsHook.release.store(true, std::memory_order_release);
  samplingFacts.join();
  NativeAudioOutputTestAccess::setAfterFactsBridgeOwnerHook(
      *retainedClosed.output, nullptr, nullptr);
  expect(retainedFacts.callbackQuiescent &&
             retainedClosed.output->facts().callbackQuiescent &&
             !active.output->facts().callbackQuiescent,
         "split facts snapshot ignores a live bridge transferred to replacement");
  hook.release.store(true, std::memory_order_release);
  callback.join();
  NativeAudioRenderCoreTestAccess::setAfterPreflightHook(
      active.core, nullptr, nullptr);
}

struct ReentryHook {
  FakeAudioUnit *fake{nullptr};
  OSStatus status{noErr};

  static void run(void *context) noexcept {
    auto &hook = *static_cast<ReentryHook *>(context);
    std::array<float, 16> nested{};
    hook.status = hook.fake->invoke(hostTimestamp(100), 8, nested.data(),
                                    sizeof(nested));
  }
};

void testReentryAndWakeSemantics() {
  Fixture reentry;
  expect(reentry.start() && publishConstant(reentry.ring, 16),
         "reentry fixture starts with PCM");
  ReentryHook hook{&reentry.fake};
  NativeAudioRenderCoreTestAccess::setAfterPreflightHook(
      reentry.core, &ReentryHook::run, &hook);
  std::array<float, 32> output{};
  static_cast<void>(reentry.fake.invoke(hostTimestamp(100), 16,
                                        output.data(), sizeof(output)));
  NativeAudioRenderCoreTestAccess::setAfterPreflightHook(
      reentry.core, nullptr, nullptr);
  expect(hook.status == kAudio_ParamError &&
             reentry.output->facts().failure ==
                 NativeAudioOutputFailure::ReentrantCallback &&
             reentry.output->facts().callbacks == 2,
         "adapter rejects reentry before a second render-core call");
  reentry.cleanup();

  Fixture wake;
  // Two producer slabs: the first callback only baselines the queue depth, so
  // the second callback owns the retirement that publishes the producer edge.
  expect(wake.start() && publishConstant(wake.ring, 8) &&
             publishConstant(wake.ring, 8),
         "wake fixture starts with two final PCM slabs");
  std::array<float, 16> wakeOutput{};
  wake.host.ticks.store(0, std::memory_order_relaxed);
  expect(invokeTracked(wake.fake, hostTimestamp(0), 8, wakeOutput) == noErr &&
             wake.wake.calls.load(std::memory_order_relaxed) == 0,
         "the first admitted callback only baselines the producer queue");
  wake.host.ticks.store(8, std::memory_order_relaxed);
  expect(invokeTracked(wake.fake, hostTimestamp(8), 8, wakeOutput) == noErr &&
             wake.wake.calls.load(std::memory_order_relaxed) == 1 &&
             wake.core.publishTerminalFrame(1, 16),
         "admitted callback emits one coalesced RT-safe wake after exit");
  wake.host.ticks.store(16, std::memory_order_relaxed);
  expect(invokeTracked(wake.fake, hostTimestamp(16), 8, wakeOutput) == noErr &&
             wake.wake.calls.load(std::memory_order_relaxed) == 1,
         "uncleared pending bit coalesces later callback exits");
  wake.wake.clear();
  wake.host.ticks.store(24, std::memory_order_relaxed);
  static_cast<void>(invokeTracked(wake.fake, hostTimestamp(24), 8,
                                  wakeOutput));
  expect(wake.wake.calls.load(std::memory_order_relaxed) == 1 &&
             wake.output->facts().suppressedCallbackWakes == 2,
         "owner clear does not turn steady callback exits into worker wakes");
  wake.wake.clear();
  expect(wake.output->stop() == NativeAudioOutputProgress::Done,
         "wake fixture stops before rejected callback check");
  static_cast<void>(wake.fake.invoke(hostTimestamp(32), 8,
                                     wakeOutput.data(), sizeof(wakeOutput)));
  expect(wake.wake.calls.load(std::memory_order_relaxed) == 2 &&
             wake.wake.orderingViolations.load(
                 std::memory_order_relaxed) == 0,
         "post-stop exit wakes only after entry/admission counters drain");
}

void testCallbackWakeGatingAndForwardProgress() {
  Fixture refill;
  expect(refill.start() &&
             publishConstant(refill.ring,
                             NativePcmRing::kFramesPerSlab) &&
             publishConstant(refill.ring,
                             NativePcmRing::kFramesPerSlab) &&
             publishConstant(refill.ring,
                             NativePcmRing::kFramesPerSlab) &&
             publishConstant(refill.ring,
                             NativePcmRing::kFramesPerSlab),
         "wake-gating fixture starts with a full PCM ring");
  refill.wake.clear();

  constexpr std::uint32_t kFrames = 128;
  std::array<float, kFrames * NativePcmRing::kChannels> samples{};
  std::uint64_t hostTicks = 0;
  for (unsigned callback = 0; callback != 64; ++callback) {
    refill.host.ticks.store(hostTicks, std::memory_order_relaxed);
    expect(invokeTracked(refill.fake, hostTimestamp(hostTicks), kFrames,
                         samples) == noErr,
           "full-ring callback burst renders without failure");
    hostTicks += kFrames;
  }
  expect(refill.wake.calls.load(std::memory_order_relaxed) == 1 &&
             refill.wake.pending.load(std::memory_order_acquire),
         "sixty-four callbacks coalesce the two slab retirements they cause "
         "into one exact producer wake");

  refill.wake.clear();
  for (unsigned callback = 0; callback != 64; ++callback) {
    refill.host.ticks.store(hostTicks, std::memory_order_relaxed);
    expect(invokeTracked(refill.fake, hostTimestamp(hostTicks), kFrames,
                         samples) == noErr,
           "draining callback burst renders without failure");
    hostTicks += kFrames;
  }
  expect(refill.wake.calls.load(std::memory_order_relaxed) == 2,
         "the next drained slabs coalesce into exactly one further wake");

  refill.host.ticks.store(hostTicks, std::memory_order_relaxed);
  expect(invokeTracked(refill.fake, hostTimestamp(hostTicks), kFrames,
                       samples) == noErr &&
             refill.wake.calls.load(std::memory_order_relaxed) == 2,
         "the first true underrun coalesces into the pending producer wake");
  hostTicks += kFrames;
  refill.wake.clear();
  for (unsigned callback = 0; callback != 16; ++callback) {
    refill.host.ticks.store(hostTicks, std::memory_order_relaxed);
    expect(invokeTracked(refill.fake, hostTimestamp(hostTicks), kFrames,
                         samples) == noErr,
           "continued underrun callback remains bounded");
    hostTicks += kFrames;
    refill.wake.clear();
  }
  expect(refill.wake.calls.load(std::memory_order_relaxed) == 2,
         "continued underrun remains one edge even when the owner clears");

  expect(publishConstant(refill.ring, kFrames / 2U),
         "producer can partially recover the underrun with fresh PCM");
  refill.host.ticks.store(hostTicks, std::memory_order_relaxed);
  expect(invokeTracked(refill.fake, hostTimestamp(hostTicks), kFrames,
                       samples) == noErr &&
             refill.wake.calls.load(std::memory_order_relaxed) == 3,
         "a short playable prefix re-enters underrun and publishes a new edge");
  hostTicks += kFrames;
  refill.host.ticks.store(hostTicks, std::memory_order_relaxed);
  expect(invokeTracked(refill.fake, hostTimestamp(hostTicks), kFrames,
                       samples) == noErr &&
             refill.wake.calls.load(std::memory_order_relaxed) == 3,
         "empty callbacks after the partial-recovery edge remain coalesced");
  hostTicks += kFrames;

  expect(publishConstant(refill.ring,
                         NativePcmRing::kFramesPerSlab) &&
             publishConstant(refill.ring,
                             NativePcmRing::kFramesPerSlab) &&
             publishConstant(refill.ring,
                             NativePcmRing::kFramesPerSlab) &&
             publishConstant(refill.ring,
                             NativePcmRing::kFramesPerSlab),
         "producer refills the whole ring for a sustained-playback cycle");
  refill.wake.clear();
  for (unsigned callback = 0; callback != 31; ++callback) {
    refill.host.ticks.store(hostTicks, std::memory_order_relaxed);
    expect(invokeTracked(refill.fake, hostTimestamp(hostTicks), kFrames,
                         samples) == noErr,
           "second full-ring callback burst renders without failure");
    hostTicks += kFrames;
  }
  expect(refill.wake.calls.load(std::memory_order_relaxed) == 3,
         "a refilled ring publishes no edge until a slab is actually retired");
  refill.host.ticks.store(hostTicks, std::memory_order_relaxed);
  expect(invokeTracked(refill.fake, hostTimestamp(hostTicks), kFrames,
                       samples) == noErr &&
             refill.wake.calls.load(std::memory_order_relaxed) == 4,
         "the first retirement of the refilled ring publishes a fresh wake");

  const NativeAudioOutputFacts refillFacts = refill.output->facts();
  expect(refillFacts.callbacks == 179 &&
             refillFacts.callbackWakeRequests == 7 &&
             refillFacts.callbackWakeSignals == 4 &&
             refillFacts.suppressedCallbackWakes == 172 &&
             refillFacts.refillWakeRequests == 5 &&
             refillFacts.underrunWakeRequests == 2 &&
             refillFacts.videoDueWakeRequests == 0 &&
             refillFacts.stateWakeRequests == 0,
         "wake facts prove 179 callbacks require only four worker signals");
  refill.cleanup();

  Fixture videoDue;
  expect(videoDue.start() &&
             publishConstant(videoDue.ring,
                             NativePcmRing::kFramesPerSlab) &&
             publishConstant(videoDue.ring,
                             NativePcmRing::kFramesPerSlab) &&
             publishConstant(videoDue.ring,
                             NativePcmRing::kFramesPerSlab) &&
             publishConstant(videoDue.ring,
                             NativePcmRing::kFramesPerSlab),
         "video-deadline fixture starts above refill low water");
  videoDue.wake.clear();
  videoDue.wake.videoDueHostTicks.store(500,
                                        std::memory_order_release);
  for (unsigned callback = 0; callback != 8; ++callback) {
    const std::uint64_t start = callback * kFrames;
    videoDue.host.ticks.store(start, std::memory_order_relaxed);
    expect(invokeTracked(videoDue.fake, hostTimestamp(start), kFrames,
                         samples) == noErr,
           "video-deadline callback burst renders without failure");
    if (callback == 2) {
      expect(videoDue.wake.calls.load(std::memory_order_relaxed) == 0,
             "callbacks before the video deadline remain suppressed");
    }
  }
  const NativeAudioOutputFacts videoFacts = videoDue.output->facts();
  expect(videoDue.wake.calls.load(std::memory_order_relaxed) == 1 &&
             videoDue.wake.videoDueHostTicks.load(
                 std::memory_order_acquire) == 0 &&
             videoFacts.callbackWakeRequests == 1 &&
             videoFacts.callbackWakeSignals == 1 &&
             videoFacts.videoDueWakeRequests == 1 &&
             videoFacts.suppressedCallbackWakes == 7,
         "the callback crossing a video deadline consumes and signals it once");
}

void testRetryableTeardownOrdering() {
  Fixture sealedBeforeUninitialize;
  expect(sealedBeforeUninitialize.configure(),
         "logical-seal fixture configures with callback attached");
  sealedBeforeUninitialize.fake.invokeDuringUninitialize = true;
  expect(sealedBeforeUninitialize.output->close() ==
             NativeAudioOutputProgress::Done &&
             sealedBeforeUninitialize.fake.uninitializeCallbackStatus ==
                 kAudio_ParamError &&
             sealedBeforeUninitialize.fake.uninitializeCallbackSilenced &&
             sealedBeforeUninitialize.output->facts().callbacks == 0,
         "close seals OS callback entry before AudioUnit uninitialization");

  Fixture stopFailure;
  expect(stopFailure.start(), "stop-failure fixture starts");
  stopFailure.fake.failAt = Call::Stop;
  expect(stopFailure.output->stop() == NativeAudioOutputProgress::Failed &&
             !stopFailure.output->facts().stopped &&
             stopFailure.output->stop() == NativeAudioOutputProgress::Done &&
             stopFailure.fake.sawOrdered({Call::Stop, Call::Stop}),
         "failed AudioOutputUnitStop retains state for an exact retry");
  stopFailure.cleanup();

  Fixture uninitialize;
  expect(uninitialize.configure(),
         "uninitialize-failure fixture configures");
  uninitialize.fake.failAt = Call::Uninitialize;
  expect(uninitialize.output->close() == NativeAudioOutputProgress::Failed &&
             uninitialize.fake.callbackAttached &&
             uninitialize.output->close() == NativeAudioOutputProgress::Done,
         "uninitialize failure retains callback and retries without dispose");
  expect(uninitialize.fake.sawOrdered(
             {Call::Uninitialize, Call::Uninitialize,
              Call::DetachCallback, Call::RemoveDeviceListener,
              Call::Dispose}),
         "callback detaches only after successful uninitialize");

  Fixture detach;
  expect(detach.configure(), "detach-failure fixture configures");
  detach.fake.failAt = Call::DetachCallback;
  expect(detach.output->close() == NativeAudioOutputProgress::Failed &&
             detach.fake.callbackAttached &&
             detach.output->close() == NativeAudioOutputProgress::Done &&
             detach.fake.sawOrdered(
                 {Call::Uninitialize, Call::DetachCallback,
                  Call::DetachCallback, Call::RemoveDeviceListener,
                  Call::Dispose}),
         "detach failure keeps self-owner reachable and retries exact step");

  Fixture removeListener;
  expect(removeListener.configure(),
         "listener-removal-failure fixture configures");
  removeListener.fake.failAt = Call::RemoveDeviceListener;
  expect(removeListener.output->close() ==
             NativeAudioOutputProgress::Failed &&
             removeListener.fake.listenerAttached &&
             removeListener.output->close() ==
                 NativeAudioOutputProgress::Done &&
             removeListener.fake.sawOrdered(
                 {Call::DetachCallback, Call::RemoveDeviceListener,
                  Call::RemoveDeviceListener, Call::Dispose}),
         "listener removal failure remains retained and retries before dispose");

  Fixture dispose;
  expect(dispose.configure(), "dispose-failure fixture configures");
  dispose.fake.failAt = Call::Dispose;
  expect(dispose.output->close() == NativeAudioOutputProgress::Failed &&
             dispose.output->facts().state ==
                 NativeAudioOutputState::Detaching &&
             NativeAudioOutput::recoverQuarantined().get() ==
                 dispose.output.get() &&
             dispose.output->close() == NativeAudioOutputProgress::Done,
         "dispose failure stays bounded and recoverable for one retry");
}

}  // namespace

// The device IO buffer size is the process's audio wake rate: the render
// callback fires exactly sampleRate/frames times a second. configure() states
// it rather than inheriting whatever the previous client on the device left
// behind, which fixes the wake rate and, just as importantly, bounds it -- a
// device left above kMaximumFramesPerSlice would otherwise fail every callback
// for the whole session.
void testDeviceBufferFramesConfiguration() {
  // The requested size is only sound because the ring can cover it. Restate
  // the bound here so a future change to either constant fails at the test
  // boundary as well as at the header.
  static_assert(wam::macos::maximumMediaFramesPerDevicePeriod(
                    NativeAudioOutput::kDeviceBufferFrames) *
                    NativeAudioOutput::kRingDevicePeriodsOfHeadroom <=
                NativeAudioOutput::kGuaranteedRingFrames);
  static_assert(NativeAudioOutput::kDeviceBufferFrames <=
                NativeAudioOutput::kMaximumFramesPerSlice);
  static_assert(NativeAudioOutput::kGuaranteedRingFrames ==
                static_cast<std::uint32_t>(NativePcmRing::kSlabCount) *
                    NativeAudioOutput::kMinimumFramesPerPublishedSlab);

  Fixture accepted;
  expect(accepted.configure() &&
             accepted.fake.requestedDeviceBufferFrames ==
                 NativeAudioOutput::kDeviceBufferFrames &&
             accepted.fake.deviceBufferFrames ==
                 NativeAudioOutput::kDeviceBufferFrames &&
             accepted.output->facts().deviceBufferFrames ==
                 NativeAudioOutput::kDeviceBufferFrames &&
             accepted.output->facts().failure ==
                 NativeAudioOutputFailure::None,
         "configure states the device IO buffer size and publishes the size "
         "the device accepted");
  accepted.cleanup();

  // A device is free to land somewhere else. A smaller period is always safe:
  // it only costs wakes, it cannot outrun the ring.
  Fixture clamped;
  clamped.fake.deviceBufferFramesClamp = 256;
  expect(clamped.output->configure(clamped.configuration()) ==
             NativeAudioOutputProgress::Done &&
             clamped.fake.requestedDeviceBufferFrames ==
                 NativeAudioOutput::kDeviceBufferFrames &&
             clamped.output->facts().deviceBufferFrames == 256 &&
             clamped.output->facts().failure ==
                 NativeAudioOutputFailure::None,
         "a device that clamps the request downwards is admitted at the size "
         "it actually chose");
  clamped.cleanup();

  // A period the render slice cannot cover must fail here, once, rather than
  // failing every callback for the life of the session.
  Fixture oversized;
  oversized.fake.deviceBufferFramesClamp =
      NativeAudioOutput::kMaximumFramesPerSlice + 1U;
  expect(oversized.output->configure(oversized.configuration()) ==
             NativeAudioOutputProgress::Failed &&
             oversized.output->facts().failure ==
                 NativeAudioOutputFailure::DeviceBufferFramesUnsupported &&
             oversized.output->facts().deviceBufferFrames == 0,
         "a device period larger than one render slice fails configuration");
  oversized.cleanup();

  // The WAM_AUDIO_IO_FRAMES measurement seam admits only sizes that satisfy
  // the same inequalities the shipped constant does, so a paired A/B can run
  // from one binary without the environment ever being able to select a size
  // the ring has not been proven to feed.
  {
    // The seam is read once per process (a function-local static), so only the
    // first value observed in this process is testable through configure().
    // Restate the admission predicate itself here instead, which is the part
    // that has to hold for every candidate a harness might pass.
    const auto admissible = [](std::uint32_t frames) {
      return frames != 0 && (frames & (frames - 1)) == 0 &&
             frames <= NativeAudioOutput::kMaximumFramesPerSlice &&
             wam::macos::maximumMediaFramesPerDevicePeriod(frames) *
                     NativeAudioOutput::kRingDevicePeriodsOfHeadroom <=
                 NativeAudioOutput::kGuaranteedRingFrames;
    };
    expect(admissible(512) && admissible(NativeAudioOutput::kDeviceBufferFrames),
           "the baseline and shipped device periods are both admissible");
    expect(!admissible(0) && !admissible(3) && !admissible(768) &&
               !admissible(2048) && !admissible(8192),
           "zero, non-powers of two, and any size the ring cannot cover four "
           "times over are all rejected");
  }

  // A device that refuses the property outright is still a device we can
  // render to: render() enforces the same per-callback bound regardless.
  Fixture unsupported;
  unsupported.fake.deviceBufferFramesSupported = false;
  expect(unsupported.output->configure(unsupported.configuration()) ==
             NativeAudioOutputProgress::Done &&
             unsupported.output->facts().failure ==
                 NativeAudioOutputFailure::None &&
             unsupported.output->facts().deviceBufferFrames == 0,
         "a device that will not report its IO buffer size still configures");
  unsupported.cleanup();
}

int main() {
  @autoreleasepool {
    testDeviceBufferFramesConfiguration();
    testConfigurationAndExactDeviceFormat();
    testPartialInitializationAndStartUnwind();
    testTimestampModesAndRationalCarry();
    testStreamRateBelowDeviceRateUsesUnitConverter();
    testMalformedAndPostStopCallbacks();
    testFrameAndTimestampOverflow();
    testDeviceChangeWinsStartCommit();
    testStopRaceAndQuarantineLifetime();
    testStoppedCallbackCannotCrossRestartEpoch();
    testPauseSuspendKeepsStreamPositionAcrossRestart();
    testWakeGatesResetAcrossGenerationActivation();
    testRefillEdgeTracksSlabRetirement();
    testWakeAndListenerPinsDrainBeforeClose();
    testClosedFactsIgnoreReusedProcessBridge();
    testReentryAndWakeSemantics();
    testCallbackWakeGatingAndForwardProgress();
    testRetryableTeardownOrdering();

  }
  if (failures != 0) {
    std::cerr << failures << " native audio output check(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "native audio output checks passed\n";
  return EXIT_SUCCESS;
}
