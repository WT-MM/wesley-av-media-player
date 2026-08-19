#include "native_audio_output.hpp"

#include <CoreAudio/HostTime.h>

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <type_traits>

namespace wam::macos {

namespace {

constexpr std::uint64_t kMaximumExactDoubleInteger =
    std::uint64_t{1} << 53U;
constexpr std::uint64_t kBridgeDetached = std::uint64_t{1} << 63U;
constexpr std::uint64_t kBridgePaused = std::uint64_t{1} << 62U;
constexpr std::uint64_t kBridgeCountMask = kBridgePaused - 1U;
constexpr std::uint64_t kMaximumBridgeEntries = 1024;
constexpr std::uint32_t kWakeRefill = 1U << 0U;
constexpr std::uint32_t kWakeUnderrun = 1U << 1U;
constexpr std::uint32_t kWakeVideoDue = 1U << 2U;
constexpr std::uint32_t kWakePause = 1U << 3U;
constexpr std::uint32_t kWakeTerminal = 1U << 4U;
constexpr std::uint32_t kWakeFailure = 1U << 5U;
constexpr std::uint32_t kWakeStateMask =
    kWakePause | kWakeTerminal | kWakeFailure;

struct CallbackBridge {
  std::atomic<NativeAudioOutput *> owner{nullptr};
  std::atomic<std::uint64_t> gate{kBridgeDetached | kBridgePaused};
  std::atomic<std::uint32_t> exitPins{0};
};

std::atomic<bool> gOutputClaimed{false};
std::atomic<NativeAudioOutput *> gCallbackOwner{nullptr};
CallbackBridge gCallbackBridge;
CallbackBridge gDeviceListenerBridge;

static_assert(std::atomic<std::uint32_t>::is_always_lock_free);
static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
static_assert(std::atomic<bool>::is_always_lock_free);
static_assert(sizeof(float) == 4);
static_assert(std::numeric_limits<float>::is_iec559);
static_assert(std::is_trivially_copyable_v<NativeAudioOutputConfiguration>);
static_assert(std::is_trivially_copyable_v<NativeAudioOutputFacts>);

AudioComponent systemFindNext(
    void *, AudioComponent current,
    const AudioComponentDescription *description) {
  return AudioComponentFindNext(current, description);
}

OSStatus systemInstanceNew(void *, AudioComponent component,
                           AudioComponentInstance *instance) {
  return AudioComponentInstanceNew(component, instance);
}

// Device IO buffer size to request. NativeAudioOutput::kDeviceBufferFrames is
// what ships; WAM_AUDIO_IO_FRAMES exists so that one binary can serve both arms
// of a paired wake-rate measurement. Measuring the two sizes by rebuilding
// between arms would confound the treatment with every other difference two
// builds can carry, which on a machine whose ambient load and default audio
// device both drift is not a difference anyone can subtract afterwards.
//
// The override is admitted only if it satisfies the same inequalities the
// constant does -- a power of two, within one render slice, and covered
// kRingDevicePeriodsOfHeadroom times over by the ring's guaranteed occupancy
// AT THE FASTEST ADMITTED PLAYBACK RATE, which is what actually drains it.
// So it can select a size the ring has been proven to feed and nothing else;
// it is a measurement seam, not an escape hatch. Read once per process.
[[nodiscard]] std::uint32_t requestedDeviceBufferFrames() noexcept {
  static const std::uint32_t frames = []() noexcept -> std::uint32_t {
    const char *const raw = std::getenv("WAM_AUDIO_IO_FRAMES");
    if (raw == nullptr) {
      return NativeAudioOutput::kDeviceBufferFrames;
    }
    std::uint32_t parsed = 0;
    for (const char *cursor = raw; *cursor != '\0'; ++cursor) {
      if (*cursor < '0' || *cursor > '9' ||
          parsed > NativeAudioOutput::kMaximumFramesPerSlice) {
        return NativeAudioOutput::kDeviceBufferFrames;
      }
      parsed = parsed * 10U + static_cast<std::uint32_t>(*cursor - '0');
    }
    const bool admissible =
        parsed != 0 && (parsed & (parsed - 1)) == 0 &&
        parsed <= NativeAudioOutput::kMaximumFramesPerSlice &&
        maximumMediaFramesPerDevicePeriod(parsed) *
                NativeAudioOutput::kRingDevicePeriodsOfHeadroom <=
            NativeAudioOutput::kGuaranteedRingFrames;
    return admissible ? parsed : NativeAudioOutput::kDeviceBufferFrames;
  }();
  return frames;
}

OSStatus systemInstanceDispose(void *, AudioComponentInstance instance) {
  return AudioComponentInstanceDispose(instance);
}

OSStatus systemSetProperty(void *, AudioUnit unit,
                           AudioUnitPropertyID property,
                           AudioUnitScope scope,
                           AudioUnitElement element, const void *data,
                           UInt32 dataSize) {
  return AudioUnitSetProperty(unit, property, scope, element, data, dataSize);
}

OSStatus systemGetProperty(void *, AudioUnit unit,
                           AudioUnitPropertyID property,
                           AudioUnitScope scope,
                           AudioUnitElement element, void *data,
                           UInt32 *dataSize) {
  return AudioUnitGetProperty(unit, property, scope, element, data, dataSize);
}

OSStatus systemInitialize(void *, AudioUnit unit) {
  return AudioUnitInitialize(unit);
}

OSStatus systemUninitialize(void *, AudioUnit unit) {
  return AudioUnitUninitialize(unit);
}

OSStatus systemStart(void *, AudioUnit unit) {
  return AudioOutputUnitStart(unit);
}

OSStatus systemStop(void *, AudioUnit unit) {
  return AudioOutputUnitStop(unit);
}

OSStatus systemAddPropertyListener(
    void *, AudioUnit unit, AudioUnitPropertyID property,
    AudioUnitPropertyListenerProc listener, void *listenerContext) {
  return AudioUnitAddPropertyListener(unit, property, listener,
                                      listenerContext);
}

OSStatus systemRemovePropertyListener(
    void *, AudioUnit unit, AudioUnitPropertyID property,
    AudioUnitPropertyListenerProc listener, void *listenerContext) {
  return AudioUnitRemovePropertyListenerWithUserData(
      unit, property, listener, listenerContext);
}

Float64 systemHostClockFrequency(void *) {
  return AudioGetHostClockFrequency();
}

class EntryGuard final {
 public:
  explicit EntryGuard(std::atomic<std::uint32_t> &entries) noexcept
      : entries_(entries) {
    entries_.fetch_add(1, std::memory_order_acq_rel);
  }
  ~EntryGuard() { entries_.fetch_sub(1, std::memory_order_acq_rel); }

  EntryGuard(const EntryGuard &) = delete;
  EntryGuard &operator=(const EntryGuard &) = delete;

 private:
  std::atomic<std::uint32_t> &entries_;
};

class BridgeEntryGuard final {
 public:
  explicit BridgeEntryGuard(CallbackBridge &bridge) noexcept
      : bridge_(bridge) {}
  ~BridgeEntryGuard() { static_cast<void>(release()); }

  BridgeEntryGuard(const BridgeEntryGuard &) = delete;
  BridgeEntryGuard &operator=(const BridgeEntryGuard &) = delete;

  [[nodiscard]] bool enter(bool *paused = nullptr) noexcept {
    std::uint64_t observed = bridge_.gate.load(std::memory_order_acquire);
    for (unsigned attempt = 0; attempt != 4; ++attempt) {
      if ((observed & kBridgeDetached) != 0 ||
          (observed & kBridgeCountMask) >= kMaximumBridgeEntries) {
        return false;
      }
      if (bridge_.gate.compare_exchange_weak(
              observed, observed + 1U, std::memory_order_acq_rel,
              std::memory_order_acquire)) {
        entered_ = true;
        if (paused != nullptr) {
          *paused = (observed & kBridgePaused) != 0;
        }
        return true;
      }
    }
    return false;
  }

  [[nodiscard]] std::uint64_t release() noexcept {
    if (entered_) {
      const std::uint64_t previous =
          bridge_.gate.fetch_sub(1, std::memory_order_acq_rel);
      entered_ = false;
      return previous;
    }
    return 0;
  }

 private:
  CallbackBridge &bridge_;
  bool entered_{false};
};

class BridgeExitPinGuard final {
 public:
  explicit BridgeExitPinGuard(CallbackBridge &bridge) noexcept
      : bridge_(bridge) {
    bridge_.exitPins.fetch_add(1, std::memory_order_acq_rel);
  }
  ~BridgeExitPinGuard() {
    bridge_.exitPins.fetch_sub(1, std::memory_order_acq_rel);
  }

  BridgeExitPinGuard(const BridgeExitPinGuard &) = delete;
  BridgeExitPinGuard &operator=(const BridgeExitPinGuard &) = delete;

 private:
  CallbackBridge &bridge_;
};

[[nodiscard]] bool finalDrainingBridgeEntry(
    std::uint64_t previous) noexcept {
  return (previous & kBridgeCountMask) == 1 &&
         (previous & (kBridgePaused | kBridgeDetached)) != 0;
}

class AdmissionGuard final {
 public:
  explicit AdmissionGuard(std::atomic<std::uint64_t> &gate) noexcept
      : gate_(gate) {}
  ~AdmissionGuard() {
    if (admitted_) {
      gate_.fetch_sub(1, std::memory_order_acq_rel);
    }
  }

  AdmissionGuard(const AdmissionGuard &) = delete;
  AdmissionGuard &operator=(const AdmissionGuard &) = delete;

  [[nodiscard]] bool enter(std::uint64_t blocked,
                           std::uint64_t countMask) noexcept {
    std::uint64_t observed = gate_.load(std::memory_order_acquire);
    for (unsigned attempt = 0; attempt != 4; ++attempt) {
      if ((observed & blocked) != 0 ||
          (observed & countMask) == countMask) {
        return false;
      }
      if (gate_.compare_exchange_weak(
              observed, observed + 1U, std::memory_order_acq_rel,
              std::memory_order_acquire)) {
        admitted_ = true;
        return true;
      }
    }
    return false;
  }

 private:
  std::atomic<std::uint64_t> &gate_;
  bool admitted_{false};
};

class RenderGateGuard final {
 public:
  explicit RenderGateGuard(std::atomic_flag &gate) noexcept : gate_(gate) {}
  ~RenderGateGuard() { gate_.clear(std::memory_order_release); }

  RenderGateGuard(const RenderGateGuard &) = delete;
  RenderGateGuard &operator=(const RenderGateGuard &) = delete;

 private:
  std::atomic_flag &gate_;
};

}  // namespace

NativeAudioUnitCallTable nativeAudioUnitSystemCallTable() noexcept {
  return {nullptr,
          &systemFindNext,
          &systemInstanceNew,
          &systemInstanceDispose,
          &systemSetProperty,
          &systemGetProperty,
          &systemInitialize,
          &systemUninitialize,
          &systemStart,
          &systemStop,
          &systemAddPropertyListener,
          &systemRemovePropertyListener,
          &systemHostClockFrequency};
}

std::shared_ptr<NativeAudioOutput> NativeAudioOutput::create(
    NativeAudioRenderCore &renderCore,
    NativeAudioUnitCallTable calls,
    NativeAudioOutputWakeSeam wake) noexcept {
  if (wake.pending == nullptr || wake.signal == nullptr ||
      !wake.pending->is_lock_free() ||
      (wake.videoDueHostTicks != nullptr &&
       !wake.videoDueHostTicks->is_lock_free())) {
    return {};
  }
  bool expected = false;
  if (!gOutputClaimed.compare_exchange_strong(
          expected, true, std::memory_order_acq_rel,
          std::memory_order_acquire)) {
    return {};
  }

  try {
    auto output = std::shared_ptr<NativeAudioOutput>(
        new NativeAudioOutput(renderCore, calls, wake));
    output->claim_held_ = true;
    return output;
  } catch (...) {
    gOutputClaimed.store(false, std::memory_order_release);
    return {};
  }
}

NativeAudioOutput::NativeAudioOutput(
    NativeAudioRenderCore &renderCore,
    NativeAudioUnitCallTable calls,
    NativeAudioOutputWakeSeam wake) noexcept
    : render_core_(renderCore), calls_(calls), wake_(wake) {}

NativeAudioOutput::~NativeAudioOutput() {
  // An attached callback always has the process-bounded owner in
  // gCallbackOwner, so this branch is reachable only for an unattached partial
  // initialization. Best-effort cleanup is safe because no callback can enter.
  if (unit_ != nullptr && !callback_attached_ && !listener_attached_ &&
      callback_entries_.load(std::memory_order_acquire) == 0) {
    if (initialized_ || initialize_attempted_) {
      static_cast<void>(uninitializeUnit());
    }
    static_cast<void>(disposeInstance(unit_));
    unit_ = nullptr;
  }
  if (claim_held_) {
    gOutputClaimed.store(false, std::memory_order_release);
  }
}

std::shared_ptr<NativeAudioOutput>
NativeAudioOutput::recoverQuarantined() noexcept {
  NativeAudioOutput *const output =
      gCallbackOwner.load(std::memory_order_acquire);
  if (output == nullptr) {
    return {};
  }
  try {
    return output->shared_from_this();
  } catch (...) {
    return {};
  }
}

bool NativeAudioOutput::validCallTable() const noexcept {
  return calls_.findNext != nullptr && calls_.instanceNew != nullptr &&
         calls_.instanceDispose != nullptr && calls_.setProperty != nullptr &&
         calls_.getProperty != nullptr && calls_.initialize != nullptr &&
         calls_.uninitialize != nullptr && calls_.start != nullptr &&
         calls_.stop != nullptr && calls_.addPropertyListener != nullptr &&
         calls_.removePropertyListener != nullptr &&
         calls_.hostClockFrequency != nullptr;
}

bool NativeAudioOutput::admittedSampleRate(
    std::uint32_t sampleRate) const noexcept {
  return sampleRate == 44100 || sampleRate == 48000 ||
         sampleRate == 96000 || sampleRate == 192000;
}

bool NativeAudioOutput::usableDeviceRate(
    const AudioStreamBasicDescription &format) const noexcept {
  return std::isfinite(format.mSampleRate) && format.mSampleRate > 0.0;
}

// Proves the device has not changed under us since configure() latched it. The
// device rate need not equal the stream rate: the unit's own converter bridges
// the two at the input-scope boundary.
bool NativeAudioOutput::validDeviceRate(
    const AudioStreamBasicDescription &format) const noexcept {
  return std::isfinite(format.mSampleRate) && device_rate_ > 0.0 &&
         format.mSampleRate == device_rate_;
}

AudioStreamBasicDescription NativeAudioOutput::clientFormat() const noexcept {
  AudioStreamBasicDescription format{};
  format.mSampleRate = static_cast<Float64>(sample_rate_);
  format.mFormatID = kAudioFormatLinearPCM;
  format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  format.mBytesPerPacket = kChannels * sizeof(float);
  format.mFramesPerPacket = 1;
  format.mBytesPerFrame = kChannels * sizeof(float);
  format.mChannelsPerFrame = kChannels;
  format.mBitsPerChannel = sizeof(float) * 8U;
  return format;
}

bool NativeAudioOutput::validClientFormat(
    const AudioStreamBasicDescription &format) const noexcept {
  const AudioStreamBasicDescription expected = clientFormat();
  return format.mSampleRate == expected.mSampleRate &&
         format.mFormatID == expected.mFormatID &&
         format.mFormatFlags == expected.mFormatFlags &&
         format.mBytesPerPacket == expected.mBytesPerPacket &&
         format.mFramesPerPacket == expected.mFramesPerPacket &&
         format.mBytesPerFrame == expected.mBytesPerFrame &&
         format.mChannelsPerFrame == expected.mChannelsPerFrame &&
         format.mBitsPerChannel == expected.mBitsPerChannel;
}

void NativeAudioOutput::setState(NativeAudioOutputState state) noexcept {
  state_.store(static_cast<std::uint8_t>(state), std::memory_order_release);
}

void NativeAudioOutput::latchFailure(
    NativeAudioOutputFailure failure, OSStatus status) noexcept {
  if (failure == NativeAudioOutputFailure::None) {
    return;
  }
  std::uint8_t expected =
      static_cast<std::uint8_t>(NativeAudioOutputFailure::None);
  if (failure_.compare_exchange_strong(
          expected, static_cast<std::uint8_t>(failure),
          std::memory_order_acq_rel, std::memory_order_acquire)) {
    os_status_.store(status, std::memory_order_release);
  }
}

void NativeAudioOutput::boundedCounterAdd(
    std::atomic<std::uint64_t> &counter, std::uint64_t amount) noexcept {
  const std::uint64_t maximum = std::numeric_limits<std::uint64_t>::max();
  std::uint64_t current = counter.load(std::memory_order_relaxed);
  for (unsigned attempt = 0; attempt != 2; ++attempt) {
    const std::uint64_t next =
        amount > maximum - current ? maximum : current + amount;
    if (counter.compare_exchange_weak(current, next,
                                      std::memory_order_relaxed,
                                      std::memory_order_relaxed)) {
      return;
    }
  }
}

AudioComponent NativeAudioOutput::findComponent(
    const AudioComponentDescription &description) noexcept {
  try {
    @try {
      return calls_.findNext(calls_.context, nullptr, &description);
    } @catch (...) {
      latchFailure(NativeAudioOutputFailure::NativeException,
                   kAudio_ParamError);
    }
  } catch (...) {
    latchFailure(NativeAudioOutputFailure::NativeException,
                 kAudio_ParamError);
  }
  return nullptr;
}

OSStatus NativeAudioOutput::newInstance(
    AudioComponent component, AudioComponentInstance *instance) noexcept {
  try {
    @try {
      return calls_.instanceNew(calls_.context, component, instance);
    } @catch (...) {
    }
  } catch (...) {
  }
  latchFailure(NativeAudioOutputFailure::NativeException,
               kAudio_ParamError);
  return kAudio_ParamError;
}

OSStatus NativeAudioOutput::disposeInstance(
    AudioComponentInstance instance) noexcept {
  try {
    @try {
      return calls_.instanceDispose(calls_.context, instance);
    } @catch (...) {
    }
  } catch (...) {
  }
  latchFailure(NativeAudioOutputFailure::NativeException,
               kAudio_ParamError);
  return kAudio_ParamError;
}

OSStatus NativeAudioOutput::setProperty(
    AudioUnitPropertyID property, AudioUnitScope scope,
    AudioUnitElement element, const void *data, UInt32 dataSize) noexcept {
  try {
    @try {
      return calls_.setProperty(calls_.context, unit_, property, scope,
                                element, data, dataSize);
    } @catch (...) {
    }
  } catch (...) {
  }
  latchFailure(NativeAudioOutputFailure::NativeException,
               kAudio_ParamError);
  return kAudio_ParamError;
}

OSStatus NativeAudioOutput::getProperty(
    AudioUnitPropertyID property, AudioUnitScope scope,
    AudioUnitElement element, void *data, UInt32 *dataSize) noexcept {
  try {
    @try {
      return calls_.getProperty(calls_.context, unit_, property, scope,
                                element, data, dataSize);
    } @catch (...) {
    }
  } catch (...) {
  }
  latchFailure(NativeAudioOutputFailure::NativeException,
               kAudio_ParamError);
  return kAudio_ParamError;
}

OSStatus NativeAudioOutput::initializeUnit() noexcept {
  try {
    @try {
      return calls_.initialize(calls_.context, unit_);
    } @catch (...) {
    }
  } catch (...) {
  }
  latchFailure(NativeAudioOutputFailure::NativeException,
               kAudio_ParamError);
  return kAudio_ParamError;
}

OSStatus NativeAudioOutput::uninitializeUnit() noexcept {
  try {
    @try {
      return calls_.uninitialize(calls_.context, unit_);
    } @catch (...) {
    }
  } catch (...) {
  }
  latchFailure(NativeAudioOutputFailure::NativeException,
               kAudio_ParamError);
  return kAudio_ParamError;
}

OSStatus NativeAudioOutput::startUnit() noexcept {
  try {
    @try {
      return calls_.start(calls_.context, unit_);
    } @catch (...) {
    }
  } catch (...) {
  }
  latchFailure(NativeAudioOutputFailure::NativeException,
               kAudio_ParamError);
  return kAudio_ParamError;
}

OSStatus NativeAudioOutput::stopUnit() noexcept {
  try {
    @try {
      return calls_.stop(calls_.context, unit_);
    } @catch (...) {
    }
  } catch (...) {
  }
  latchFailure(NativeAudioOutputFailure::NativeException,
               kAudio_ParamError);
  return kAudio_ParamError;
}

OSStatus NativeAudioOutput::addDeviceListener() noexcept {
  try {
    @try {
      return calls_.addPropertyListener(
          calls_.context, unit_, kAudioUnitProperty_StreamFormat,
          &NativeAudioOutput::devicePropertyChanged,
          &gDeviceListenerBridge);
    } @catch (...) {
    }
  } catch (...) {
  }
  latchFailure(NativeAudioOutputFailure::NativeException,
               kAudio_ParamError);
  return kAudio_ParamError;
}

OSStatus NativeAudioOutput::removeDeviceListener() noexcept {
  try {
    @try {
      return calls_.removePropertyListener(
          calls_.context, unit_, kAudioUnitProperty_StreamFormat,
          &NativeAudioOutput::devicePropertyChanged,
          &gDeviceListenerBridge);
    } @catch (...) {
    }
  } catch (...) {
  }
  latchFailure(NativeAudioOutputFailure::NativeException,
               kAudio_ParamError);
  return kAudio_ParamError;
}

double NativeAudioOutput::hostClockFrequency() noexcept {
  try {
    @try {
      return calls_.hostClockFrequency(calls_.context);
    } @catch (...) {
    }
  } catch (...) {
  }
  latchFailure(NativeAudioOutputFailure::NativeException,
               kAudio_ParamError);
  return 0.0;
}

NativeAudioOutputProgress NativeAudioOutput::configure(
    NativeAudioOutputConfiguration configuration) noexcept {
  if (used_ || !claim_held_) {
    return NativeAudioOutputProgress::Invalid;
  }
  used_ = true;
  setState(NativeAudioOutputState::Configuring);
  stopped_.store(true, std::memory_order_release);
  device_rate_ = 0.0;

  const bool validConfiguration =
      validCallTable() && configuration.generation != 0 &&
      configuration.streamFrameCursor <= kMaximumExactDoubleInteger &&
      configuration.mediaOrigin.valid() &&
      configuration.mediaOrigin.value >= 0 &&
      configuration.pausedClockPosition.valid() &&
      configuration.pausedClockPosition.value >= 0 &&
      configuration.hostTicksPerSecond != 0 &&
      configuration.hostTicksPerSecond <= kMaximumExactDoubleInteger &&
      render_core_.compatibleHostTicksPerSecond(
          configuration.hostTicksPerSecond) &&
      admittedSampleRate(configuration.sampleRate);
  if (!validConfiguration) {
    latchFailure(NativeAudioOutputFailure::InvalidConfiguration,
                 kAudio_ParamError);
    static_cast<void>(close());
    return NativeAudioOutputProgress::Invalid;
  }

  sample_rate_ = configuration.sampleRate;
  host_ticks_per_second_ = configuration.hostTicksPerSecond;
  generation_.store(configuration.generation, std::memory_order_relaxed);
  frame_cursor_.store(configuration.streamFrameCursor,
                      std::memory_order_relaxed);
  published_sample_rate_.store(sample_rate_, std::memory_order_relaxed);
  observed_queued_slabs_.store(kUnobservedQueuedSlabs,
                               std::memory_order_release);
  underrun_active_.store(false, std::memory_order_release);
  failure_wake_emitted_.store(false, std::memory_order_release);

  const double frequency = hostClockFrequency();
  if (!std::isfinite(frequency) || frequency <= 0.0 ||
      frequency != static_cast<double>(host_ticks_per_second_)) {
    latchFailure(NativeAudioOutputFailure::InvalidConfiguration,
                 kAudio_ParamError);
    static_cast<void>(close());
    return NativeAudioOutputProgress::Invalid;
  }

  AudioComponentDescription description{};
  description.componentType = kAudioUnitType_Output;
  description.componentSubType = kAudioUnitSubType_DefaultOutput;
  description.componentManufacturer = kAudioUnitManufacturer_Apple;
  const AudioComponent component = findComponent(description);
  if (component == nullptr) {
    latchFailure(NativeAudioOutputFailure::ComponentUnavailable,
                 kAudio_ParamError);
    static_cast<void>(close());
    return NativeAudioOutputProgress::Failed;
  }

  OSStatus status = newInstance(component, &unit_);
  if (status != noErr || unit_ == nullptr) {
    latchFailure(NativeAudioOutputFailure::InstanceCreationFailed, status);
    static_cast<void>(close());
    return NativeAudioOutputProgress::Failed;
  }

  AudioStreamBasicDescription deviceFormat{};
  UInt32 propertySize = sizeof(deviceFormat);
  status = getProperty(kAudioUnitProperty_StreamFormat,
                       kAudioUnitScope_Output, 0, &deviceFormat,
                       &propertySize);
  if (status != noErr || propertySize != sizeof(deviceFormat)) {
    latchFailure(NativeAudioOutputFailure::DeviceFormatQueryFailed, status);
    static_cast<void>(close());
    return NativeAudioOutputProgress::Failed;
  }
  // The device need not run at the stream rate; it only has to report a usable
  // rate. Latch it so every later query can prove the device did not change.
  if (!usableDeviceRate(deviceFormat) ||
      (admission_gate_.load(std::memory_order_acquire) &
       kAdmissionDeviceInvalid) != 0 ||
      failure_.load(std::memory_order_acquire) !=
          static_cast<std::uint8_t>(NativeAudioOutputFailure::None)) {
    latchFailure(NativeAudioOutputFailure::DeviceRateMismatch,
                 kAudioUnitErr_FormatNotSupported);
    static_cast<void>(close());
    return NativeAudioOutputProgress::Failed;
  }
  device_rate_ = deviceFormat.mSampleRate;

  UInt32 maximumFrames = kMaximumFramesPerSlice;
  status = setProperty(kAudioUnitProperty_MaximumFramesPerSlice,
                       kAudioUnitScope_Global, 0, &maximumFrames,
                       sizeof(maximumFrames));
  if (status == noErr) {
    UInt32 acceptedFrames = 0;
    propertySize = sizeof(acceptedFrames);
    status = getProperty(kAudioUnitProperty_MaximumFramesPerSlice,
                         kAudioUnitScope_Global, 0, &acceptedFrames,
                         &propertySize);
    if (status == noErr &&
        (propertySize != sizeof(acceptedFrames) || acceptedFrames == 0 ||
         acceptedFrames > kMaximumFramesPerSlice)) {
      status = kAudioUnitErr_InvalidPropertyValue;
    }
  }
  if (status != noErr) {
    latchFailure(
        NativeAudioOutputFailure::MaximumFramesConfigurationFailed,
        status);
    static_cast<void>(close());
    return NativeAudioOutputProgress::Failed;
  }

  // Device IO buffer size. Unstated, the device simply keeps whatever the last
  // client on it left behind. Two reasons to state it:
  //
  //   Wake rate. Every render callback is a real-time thread wake and the rate
  //   is exactly sampleRate/frames. The system default of 512 frames costs
  //   93.75 wakes/s at 48 kHz; kDeviceBufferFrames halves that, and the ring
  //   headroom proof for the larger slice is the static_assert block beside the
  //   constant.
  //
  //   Boundedness. render() rejects any callback asking for more than
  //   kMaximumFramesPerSlice frames. A device another client had pushed above
  //   that size would therefore fail every callback for the whole session with
  //   no way back. Naming a size we have proven we can serve removes that
  //   exposure instead of inheriting it.
  //
  // The set is best effort: the property is device-global and its admissible
  // range belongs to the device, so a device that clamps or refuses is still a
  // device we can render to. Only the read-back is load-bearing, and only one
  // outcome is fatal -- an accepted size the render slice cannot cover.
  {
    UInt32 requestedDeviceFrames = requestedDeviceBufferFrames();
    static_cast<void>(setProperty(kAudioDevicePropertyBufferFrameSize,
                                  kAudioUnitScope_Global, 0,
                                  &requestedDeviceFrames,
                                  sizeof(requestedDeviceFrames)));
    UInt32 acceptedDeviceFrames = 0;
    propertySize = sizeof(acceptedDeviceFrames);
    const OSStatus deviceFramesStatus =
        getProperty(kAudioDevicePropertyBufferFrameSize,
                    kAudioUnitScope_Global, 0, &acceptedDeviceFrames,
                    &propertySize);
    const bool reported = deviceFramesStatus == noErr &&
                          propertySize == sizeof(acceptedDeviceFrames) &&
                          acceptedDeviceFrames != 0;
    if (reported && acceptedDeviceFrames > kMaximumFramesPerSlice) {
      latchFailure(NativeAudioOutputFailure::DeviceBufferFramesUnsupported,
                   kAudioUnitErr_InvalidPropertyValue);
      static_cast<void>(close());
      return NativeAudioOutputProgress::Failed;
    }
    // A device that will not report its size is not a failure: render()
    // enforces the same bound on every individual callback regardless.
    device_buffer_frames_.store(reported ? acceptedDeviceFrames : 0,
                                std::memory_order_release);
  }

  const AudioStreamBasicDescription requestedFormat = clientFormat();
  status = setProperty(kAudioUnitProperty_StreamFormat,
                       kAudioUnitScope_Input, 0, &requestedFormat,
                       sizeof(requestedFormat));
  AudioStreamBasicDescription acceptedFormat{};
  if (status == noErr) {
    propertySize = sizeof(acceptedFormat);
    status = getProperty(kAudioUnitProperty_StreamFormat,
                         kAudioUnitScope_Input, 0, &acceptedFormat,
                         &propertySize);
    if (status == noErr &&
        (propertySize != sizeof(acceptedFormat) ||
         !validClientFormat(acceptedFormat))) {
      status = kAudioUnitErr_FormatNotSupported;
    }
  }
  if (status != noErr) {
    latchFailure(
        NativeAudioOutputFailure::ClientFormatConfigurationFailed,
        status);
    static_cast<void>(close());
    return NativeAudioOutputProgress::Failed;
  }

  if (!render_core_.activate(configuration.generation,
                             configuration.streamFrameCursor,
                             configuration.mediaOrigin,
                             configuration.pausedClockPosition,
                             configuration.sampleRate)) {
    latchFailure(NativeAudioOutputFailure::RenderCoreActivationFailed,
                 kAudio_ParamError);
    static_cast<void>(close());
    return NativeAudioOutputProgress::Failed;
  }
  activated_ = true;
  published_activated_.store(true, std::memory_order_release);

  AURenderCallbackStruct callback{&NativeAudioOutput::renderCallback,
                                  &gCallbackBridge};
  status = setProperty(kAudioUnitProperty_SetRenderCallback,
                       kAudioUnitScope_Input, 0, &callback,
                       sizeof(callback));
  if (status != noErr) {
    latchFailure(NativeAudioOutputFailure::CallbackInstallationFailed,
                 status);
    static_cast<void>(close());
    return NativeAudioOutputProgress::Failed;
  }
  callback_attached_ = true;
  callback_self_owner_ = shared_from_this();
  gCallbackOwner.store(this, std::memory_order_release);
  gCallbackBridge.owner.store(this, std::memory_order_release);
  gCallbackBridge.gate.store(kBridgePaused, std::memory_order_release);
  gDeviceListenerBridge.owner.store(this, std::memory_order_release);
  gDeviceListenerBridge.gate.store(0, std::memory_order_release);

  status = addDeviceListener();
  if (status != noErr) {
    latchFailure(
        NativeAudioOutputFailure::DeviceListenerInstallationFailed,
        status);
    static_cast<void>(close());
    return NativeAudioOutputProgress::Failed;
  }
  listener_attached_ = true;

  deviceFormat = {};
  propertySize = sizeof(deviceFormat);
  status = getProperty(kAudioUnitProperty_StreamFormat,
                       kAudioUnitScope_Output, 0, &deviceFormat,
                       &propertySize);
  if (status != noErr || propertySize != sizeof(deviceFormat)) {
    latchFailure(NativeAudioOutputFailure::DeviceFormatQueryFailed,
                 status);
    static_cast<void>(close());
    return NativeAudioOutputProgress::Failed;
  }
  if (!validDeviceRate(deviceFormat) ||
      (admission_gate_.load(std::memory_order_acquire) &
       kAdmissionDeviceInvalid) != 0 ||
      failure_.load(std::memory_order_acquire) !=
          static_cast<std::uint8_t>(NativeAudioOutputFailure::None)) {
    latchFailure(NativeAudioOutputFailure::DeviceRateMismatch,
                 kAudioUnitErr_FormatNotSupported);
    static_cast<void>(close());
    return NativeAudioOutputProgress::Failed;
  }

  initialize_attempted_ = true;
  status = initializeUnit();
  if (status != noErr) {
    latchFailure(NativeAudioOutputFailure::InitializationFailed, status);
    static_cast<void>(close());
    return NativeAudioOutputProgress::Failed;
  }
  initialized_ = true;

  deviceFormat = {};
  propertySize = sizeof(deviceFormat);
  status = getProperty(kAudioUnitProperty_StreamFormat,
                       kAudioUnitScope_Output, 0, &deviceFormat,
                       &propertySize);
  if (status != noErr || propertySize != sizeof(deviceFormat)) {
    latchFailure(NativeAudioOutputFailure::DeviceFormatQueryFailed,
                 status);
    static_cast<void>(close());
    return NativeAudioOutputProgress::Failed;
  }
  if (!validDeviceRate(deviceFormat) ||
      (admission_gate_.load(std::memory_order_acquire) &
       kAdmissionDeviceInvalid) != 0 ||
      failure_.load(std::memory_order_acquire) !=
          static_cast<std::uint8_t>(NativeAudioOutputFailure::None)) {
    latchFailure(NativeAudioOutputFailure::DeviceRateMismatch,
                 kAudioUnitErr_FormatNotSupported);
    static_cast<void>(close());
    return NativeAudioOutputProgress::Failed;
  }

  configured_.store(true, std::memory_order_release);
  setState(NativeAudioOutputState::Stopped);
  return NativeAudioOutputProgress::Done;
}

bool NativeAudioOutput::setRate(NativePlaybackRate rate) noexcept {
  if (!rate.valid()) {
    return false;
  }
  if (!rate.unity() && !stretch_) {
    if (sample_rate_ == 0) {
      // The stream rate is only known from configure() onwards. Refusing here
      // is honest: there is no session to apply a rate to yet.
      return false;
    }
    auto stretch = NativeAudioStretchUnit::create(sample_rate_);
    if (!stretch || !render_core_.attachStretchStage(stretch->stage())) {
      return false;
    }
    stretch_ = std::move(stretch);
  }
  return render_core_.setRate(rate);
}

NativePlaybackRate NativeAudioOutput::rate() const noexcept {
  return render_core_.requestedRate();
}

void NativeAudioOutput::setPreservePitch(bool preserve) noexcept {
  render_core_.setPreservePitch(preserve);
}

bool NativeAudioOutput::preservePitch() const noexcept {
  return render_core_.preservePitch();
}

NativeAudioOutputProgress NativeAudioOutput::activate(
    std::uint64_t generation, std::uint64_t streamFrameCursor,
    media::MediaTime mediaOrigin,
    media::MediaTime pausedClockPosition) noexcept {
  if (!configured_.load(std::memory_order_acquire) ||
      state_.load(std::memory_order_acquire) !=
          static_cast<std::uint8_t>(NativeAudioOutputState::Stopped) ||
      !stopped_.load(std::memory_order_acquire) || generation == 0 ||
      streamFrameCursor > kMaximumExactDoubleInteger ||
      !mediaOrigin.valid() || mediaOrigin.value < 0 ||
      !pausedClockPosition.valid() || pausedClockPosition.value < 0 ||
      (admission_gate_.load(std::memory_order_acquire) &
       kAdmissionDeviceInvalid) != 0 ||
      failure_.load(std::memory_order_acquire) !=
          static_cast<std::uint8_t>(NativeAudioOutputFailure::None)) {
    return NativeAudioOutputProgress::Invalid;
  }
  const std::uint64_t bridge = gCallbackBridge.gate.fetch_or(
      kBridgePaused, std::memory_order_acq_rel);
  if ((bridge & kBridgeCountMask) != 0 ||
      gCallbackBridge.exitPins.load(std::memory_order_acquire) != 0 ||
      callback_entries_.load(std::memory_order_acquire) != 0 ||
      (admission_gate_.load(std::memory_order_acquire) &
       kAdmissionCountMask) != 0) {
    return quiescing();
  }
  if (!render_core_.activate(generation, streamFrameCursor,
                             mediaOrigin, pausedClockPosition,
                             sample_rate_)) {
    latchFailure(NativeAudioOutputFailure::RenderCoreActivationFailed,
                 kAudio_ParamError);
    return NativeAudioOutputProgress::Failed;
  }
  generation_.store(generation, std::memory_order_release);
  frame_cursor_.store(streamFrameCursor, std::memory_order_release);
  timing_remainder_ = 0;
  prior_timing_denominator_ = 0;
  prior_rate_scalar_bits_ = 0;
  prior_end_host_ticks_ = 0;
  observed_queued_slabs_.store(kUnobservedQueuedSlabs,
                               std::memory_order_release);
  underrun_active_.store(false, std::memory_order_release);
  failure_wake_emitted_.store(false, std::memory_order_release);
  activated_ = true;
  published_activated_.store(true, std::memory_order_release);
  return NativeAudioOutputProgress::Done;
}

NativeAudioOutputProgress NativeAudioOutput::start() noexcept {
  if (!configured_.load(std::memory_order_acquire) || !activated_ ||
      state_.load(std::memory_order_acquire) !=
          static_cast<std::uint8_t>(NativeAudioOutputState::Stopped) ||
      !stopped_.load(std::memory_order_acquire) ||
      (admission_gate_.load(std::memory_order_acquire) &
       kAdmissionDeviceInvalid) != 0 ||
      failure_.load(std::memory_order_acquire) !=
          static_cast<std::uint8_t>(NativeAudioOutputFailure::None)) {
    return NativeAudioOutputProgress::Invalid;
  }
  const std::uint64_t bridge = gCallbackBridge.gate.fetch_or(
      kBridgePaused, std::memory_order_acq_rel);
  if ((bridge & kBridgeCountMask) != 0 ||
      gCallbackBridge.exitPins.load(std::memory_order_acquire) != 0 ||
      callback_entries_.load(std::memory_order_acquire) != 0 ||
      (admission_gate_.load(std::memory_order_acquire) &
       kAdmissionCountMask) != 0) {
    return quiescing();
  }
  if (!listener_attached_) {
    latchFailure(NativeAudioOutputFailure::DeviceListenerInstallationFailed,
                 kAudio_ParamError);
    return NativeAudioOutputProgress::Failed;
  }

  const std::uint64_t deviceSerial =
      device_change_serial_.load(std::memory_order_acquire);

  AudioStreamBasicDescription deviceFormat{};
  UInt32 propertySize = sizeof(deviceFormat);
  OSStatus status = getProperty(kAudioUnitProperty_StreamFormat,
                                kAudioUnitScope_Output, 0,
                                &deviceFormat, &propertySize);
  if (status != noErr || propertySize != sizeof(deviceFormat)) {
    latchFailure(NativeAudioOutputFailure::DeviceFormatQueryFailed,
                 status);
    return NativeAudioOutputProgress::Failed;
  }
  if (!validDeviceRate(deviceFormat) ||
      failure_.load(std::memory_order_acquire) !=
          static_cast<std::uint8_t>(NativeAudioOutputFailure::None)) {
    latchFailure(NativeAudioOutputFailure::DeviceRateMismatch,
                 kAudioUnitErr_FormatNotSupported);
    return NativeAudioOutputProgress::Failed;
  }

  const std::uint64_t epoch =
      admission_epoch_.load(std::memory_order_acquire);
  if (epoch == std::numeric_limits<std::uint64_t>::max()) {
    latchFailure(NativeAudioOutputFailure::StartFailed,
                 kAudio_ParamError);
    return NativeAudioOutputProgress::Failed;
  }

  setState(NativeAudioOutputState::Starting);
  stopped_.store(false, std::memory_order_release);
  timing_remainder_ = 0;
  prior_timing_denominator_ = 0;
  prior_rate_scalar_bits_ = 0;
  prior_end_host_ticks_ = 0;
  stop_required_ = true;
  stop_succeeded_ = false;
  observed_queued_slabs_.store(kUnobservedQueuedSlabs,
                               std::memory_order_release);
  underrun_active_.store(false, std::memory_order_release);

  status = startUnit();
  if (status != noErr) {
    started_.store(false, std::memory_order_release);
    latchFailure(NativeAudioOutputFailure::StartFailed, status);
    setState(NativeAudioOutputState::Stopping);
    return NativeAudioOutputProgress::Failed;
  }

  deviceFormat = {};
  propertySize = sizeof(deviceFormat);
  status = getProperty(kAudioUnitProperty_StreamFormat,
                       kAudioUnitScope_Output, 0, &deviceFormat,
                       &propertySize);
  if (status != noErr || propertySize != sizeof(deviceFormat)) {
    started_.store(false, std::memory_order_release);
    latchFailure(NativeAudioOutputFailure::DeviceFormatQueryFailed,
                 status);
    setState(NativeAudioOutputState::Stopping);
    return NativeAudioOutputProgress::Failed;
  }
  if (!validDeviceRate(deviceFormat) ||
      device_change_serial_.load(std::memory_order_acquire) !=
          deviceSerial ||
      failure_.load(std::memory_order_acquire) !=
          static_cast<std::uint8_t>(NativeAudioOutputFailure::None)) {
    started_.store(false, std::memory_order_release);
    latchFailure(NativeAudioOutputFailure::DeviceRateMismatch,
                 kAudioUnitErr_FormatNotSupported);
    setState(NativeAudioOutputState::Stopping);
    return NativeAudioOutputProgress::Failed;
  }

  if (before_start_commit_hook_ != nullptr) {
    before_start_commit_hook_(before_start_commit_context_);
  }

  render_core_.setAccepting(true);
  admission_epoch_.store(epoch + 1U, std::memory_order_release);
  started_.store(true, std::memory_order_release);
  setState(NativeAudioOutputState::Started);
  std::uint64_t expectedAdmission = kAdmissionClosed;
  if (!admission_gate_.compare_exchange_strong(
          expectedAdmission, 0, std::memory_order_acq_rel,
          std::memory_order_acquire)) {
    render_core_.setAccepting(false);
    started_.store(false, std::memory_order_release);
    setState(NativeAudioOutputState::Stopping);
    latchFailure(
        (expectedAdmission & kAdmissionDeviceInvalid) != 0
            ? NativeAudioOutputFailure::DeviceRateMismatch
            : NativeAudioOutputFailure::StartFailed,
        kAudio_ParamError);
    return NativeAudioOutputProgress::Failed;
  }
  gCallbackBridge.gate.fetch_and(~kBridgePaused,
                                 std::memory_order_acq_rel);
  if ((admission_gate_.load(std::memory_order_acquire) &
       kAdmissionDeviceInvalid) != 0 ||
      device_change_serial_.load(std::memory_order_acquire) != deviceSerial ||
      failure_.load(std::memory_order_acquire) !=
          static_cast<std::uint8_t>(NativeAudioOutputFailure::None)) {
    admission_gate_.fetch_or(kAdmissionClosed, std::memory_order_acq_rel);
    render_core_.setAccepting(false);
    started_.store(false, std::memory_order_release);
    setState(NativeAudioOutputState::Stopping);
    return NativeAudioOutputProgress::Failed;
  }
  return NativeAudioOutputProgress::Done;
}

NativeAudioOutputProgress NativeAudioOutput::stop() noexcept {
  const NativeAudioOutputState state = static_cast<NativeAudioOutputState>(
      state_.load(std::memory_order_acquire));
  if (state == NativeAudioOutputState::Closed) {
    return NativeAudioOutputProgress::Done;
  }
  if (state == NativeAudioOutputState::Configuring ||
      state == NativeAudioOutputState::Detaching) {
    return NativeAudioOutputProgress::Invalid;
  }

  admission_gate_.fetch_or(kAdmissionClosed, std::memory_order_acq_rel);
  render_core_.setAccepting(false);
  started_.store(false, std::memory_order_release);
  stopped_.store(false, std::memory_order_release);
  setState(NativeAudioOutputState::Stopping);

  if (stop_required_ && !stop_succeeded_) {
    const OSStatus status = stopUnit();
    if (status != noErr) {
      latchFailure(NativeAudioOutputFailure::StopFailed, status);
      return NativeAudioOutputProgress::Failed;
    }
    stop_succeeded_ = true;
    stop_required_ = false;
  }

  const std::uint64_t bridge = gCallbackBridge.gate.fetch_or(
      kBridgePaused, std::memory_order_acq_rel);

  if ((admission_gate_.load(std::memory_order_acquire) &
      kAdmissionCountMask) != 0 ||
      (bridge & kBridgeCountMask) != 0 ||
      gCallbackBridge.exitPins.load(std::memory_order_acquire) != 0 ||
      callback_entries_.load(std::memory_order_acquire) != 0) {
    return quiescing();
  }
  stopped_.store(true, std::memory_order_release);
  setState(NativeAudioOutputState::Stopped);
  return NativeAudioOutputProgress::Done;
}

NativeAudioOutputProgress NativeAudioOutput::close() noexcept {
  return closeStep();
}

NativeAudioOutputProgress NativeAudioOutput::closeStep() noexcept {
  if (unit_ == nullptr && !callback_attached_ && !listener_attached_) {
    configured_.store(false, std::memory_order_release);
    published_activated_.store(false, std::memory_order_release);
    activated_ = false;
    device_rate_ = 0.0;
    setState(NativeAudioOutputState::Closed);
    if (claim_held_) {
      claim_held_ = false;
      gOutputClaimed.store(false, std::memory_order_release);
    }
    return NativeAudioOutputProgress::Done;
  }

  const NativeAudioOutputState state = static_cast<NativeAudioOutputState>(
      state_.load(std::memory_order_acquire));
  if (state == NativeAudioOutputState::Started ||
      state == NativeAudioOutputState::Starting ||
      state == NativeAudioOutputState::Stopping) {
    const NativeAudioOutputProgress progress = stop();
    if (progress != NativeAudioOutputProgress::Done) {
      return progress;
    }
  } else {
    admission_gate_.fetch_or(kAdmissionClosed, std::memory_order_acq_rel);
    render_core_.setAccepting(false);
  }

  setState(NativeAudioOutputState::Detaching);
  const std::uint64_t renderBridge = gCallbackBridge.gate.fetch_or(
      kBridgeDetached | kBridgePaused, std::memory_order_acq_rel);
  const std::uint64_t listenerBridge = gDeviceListenerBridge.gate.fetch_or(
      kBridgeDetached | kBridgePaused, std::memory_order_acq_rel);
  if ((renderBridge & kBridgeCountMask) != 0 ||
      (listenerBridge & kBridgeCountMask) != 0 ||
      gCallbackBridge.exitPins.load(std::memory_order_acquire) != 0 ||
      gDeviceListenerBridge.exitPins.load(std::memory_order_acquire) != 0 ||
      callback_entries_.load(std::memory_order_acquire) != 0) {
    setState(NativeAudioOutputState::Stopping);
    return quiescing();
  }

  if (initialized_ || initialize_attempted_) {
    const OSStatus status = uninitializeUnit();
    if (status != noErr) {
      latchFailure(NativeAudioOutputFailure::UninitializationFailed,
                   status);
      return NativeAudioOutputProgress::Failed;
    }
    initialized_ = false;
    initialize_attempted_ = false;
  }

  if (callback_attached_) {
    const AURenderCallbackStruct detached{nullptr, nullptr};
    const OSStatus status = setProperty(
        kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
        &detached, sizeof(detached));
    if (status != noErr) {
      latchFailure(NativeAudioOutputFailure::CallbackDetachmentFailed,
                   status);
      return NativeAudioOutputProgress::Failed;
    }
    callback_attached_ = false;
  }

  if (listener_attached_) {
    const OSStatus status = removeDeviceListener();
    if (status != noErr) {
      latchFailure(NativeAudioOutputFailure::DeviceListenerRemovalFailed,
                   status);
      return NativeAudioOutputProgress::Failed;
    }
    listener_attached_ = false;
  }
  gDeviceListenerBridge.gate.fetch_or(
      kBridgeDetached | kBridgePaused, std::memory_order_acq_rel);

  if (unit_ != nullptr) {
    const OSStatus status = disposeInstance(unit_);
    if (status != noErr) {
      if (!callback_self_owner_) {
        callback_self_owner_ = weak_from_this().lock();
        if (callback_self_owner_) {
          gCallbackOwner.store(this, std::memory_order_release);
        }
      }
      latchFailure(NativeAudioOutputFailure::InstanceDisposalFailed,
                   status);
      return NativeAudioOutputProgress::Failed;
    }
    unit_ = nullptr;
  }

  configured_.store(false, std::memory_order_release);
  published_activated_.store(false, std::memory_order_release);
  activated_ = false;
  device_rate_ = 0.0;
  device_buffer_frames_.store(0, std::memory_order_release);
  stopped_.store(true, std::memory_order_release);
  setState(NativeAudioOutputState::Closed);

  if (callback_self_owner_) {
    NativeAudioOutput *bridgeOwner = this;
    static_cast<void>(gCallbackBridge.owner.compare_exchange_strong(
        bridgeOwner, nullptr, std::memory_order_acq_rel,
        std::memory_order_acquire));
    NativeAudioOutput *listenerOwner = this;
    static_cast<void>(gDeviceListenerBridge.owner.compare_exchange_strong(
        listenerOwner, nullptr, std::memory_order_acq_rel,
        std::memory_order_acquire));
    NativeAudioOutput *expected = this;
    static_cast<void>(gCallbackOwner.compare_exchange_strong(
        expected, nullptr, std::memory_order_acq_rel,
        std::memory_order_acquire));
    callback_self_owner_.reset();
  }
  if (claim_held_) {
    claim_held_ = false;
    gOutputClaimed.store(false, std::memory_order_release);
  }
  return NativeAudioOutputProgress::Done;
}

bool NativeAudioOutput::rateScalarComponents(
    double rateScalar, std::uint64_t *significand,
    int *binaryExponent, std::uint64_t *bits) noexcept {
  if (significand == nullptr || binaryExponent == nullptr ||
      bits == nullptr || !std::isfinite(rateScalar) ||
      rateScalar <= 0.0 || rateScalar >= 4294967296.0) {
    return false;
  }
  const std::uint64_t raw = std::bit_cast<std::uint64_t>(rateScalar);
  const std::uint64_t exponentField = (raw >> 52U) & 0x7ffU;
  std::uint64_t value = raw & ((std::uint64_t{1} << 52U) - 1U);
  int exponent = -1074;
  if (exponentField != 0) {
    value |= std::uint64_t{1} << 52U;
    exponent = static_cast<int>(exponentField) - 1023 - 52;
  }
  if (value == 0) {
    return false;
  }
  while ((value & 1U) == 0) {
    value >>= 1U;
    ++exponent;
  }
  *significand = value;
  *binaryExponent = exponent;
  *bits = raw;
  return true;
}

bool NativeAudioOutput::exactSampleTime(
    double sampleTime, std::uint32_t frameCount,
    std::int64_t *first, std::int64_t *end) noexcept {
  if (first == nullptr || end == nullptr || !std::isfinite(sampleTime) ||
      std::trunc(sampleTime) != sampleTime ||
      std::abs(sampleTime) >
          static_cast<double>(kMaximumExactDoubleInteger)) {
    return false;
  }
  const std::int64_t value = static_cast<std::int64_t>(sampleTime);
  if (value > std::numeric_limits<std::int64_t>::max() -
                  static_cast<std::int64_t>(frameCount) ||
      value + static_cast<std::int64_t>(frameCount) >
          static_cast<std::int64_t>(kMaximumExactDoubleInteger) ||
      value < -static_cast<std::int64_t>(kMaximumExactDoubleInteger)) {
    return false;
  }
  *first = value;
  *end = value + static_cast<std::int64_t>(frameCount);
  return true;
}

bool NativeAudioOutput::callbackInput(
    const AudioTimeStamp &timestamp, std::uint32_t frameCount,
    NativeAudioRenderInput *input,
    __uint128_t *nextRemainder,
    __uint128_t *nextDenominator,
    std::uint64_t *nextRateScalarBits) noexcept {
  if (input == nullptr || nextRemainder == nullptr ||
      nextDenominator == nullptr || nextRateScalarBits == nullptr ||
      frameCount == 0 ||
      (timestamp.mFlags & kAudioTimeStampHostTimeValid) == 0 ||
      sample_rate_ == 0 || host_ticks_per_second_ == 0) {
    return false;
  }

  double scalar = 1.0;
  if ((timestamp.mFlags & kAudioTimeStampRateScalarValid) != 0) {
    scalar = timestamp.mRateScalar;
  }
  std::uint64_t scalarSignificand = 0;
  std::uint64_t scalarBits = 0;
  int scalarExponent = 0;
  if (!rateScalarComponents(scalar, &scalarSignificand,
                            &scalarExponent, &scalarBits)) {
    return false;
  }

  constexpr __uint128_t maximum128 = ~static_cast<__uint128_t>(0);
  __uint128_t numeratorPerFrame =
      static_cast<__uint128_t>(host_ticks_per_second_);
  if (scalarSignificand > maximum128 / numeratorPerFrame) {
    return false;
  }
  numeratorPerFrame *= static_cast<__uint128_t>(scalarSignificand);

  __uint128_t denominator = static_cast<__uint128_t>(sample_rate_);
  if (scalarExponent >= 0) {
    const unsigned shift = static_cast<unsigned>(scalarExponent);
    if (shift >= 128U || numeratorPerFrame > (maximum128 >> shift)) {
      return false;
    }
    numeratorPerFrame <<= shift;
  } else {
    const unsigned shift = static_cast<unsigned>(-scalarExponent);
    if (shift >= 128U || denominator > (maximum128 >> shift)) {
      return false;
    }
    denominator <<= shift;
  }

  const __uint128_t carry =
      prior_end_host_ticks_ == timestamp.mHostTime &&
              prior_rate_scalar_bits_ == scalarBits &&
              prior_timing_denominator_ == denominator
          ? timing_remainder_
          : 0;
  if (carry >= denominator ||
      numeratorPerFrame >
          maximum128 / static_cast<__uint128_t>(frameCount)) {
    return false;
  }
  const __uint128_t frameNumerator =
      numeratorPerFrame * static_cast<__uint128_t>(frameCount);
  if (carry > maximum128 - frameNumerator) {
    return false;
  }
  const __uint128_t totalNumerator = frameNumerator + carry;
  const __uint128_t duration = totalNumerator / denominator;
  if (duration == 0 ||
      duration > std::numeric_limits<std::uint64_t>::max() -
                     timestamp.mHostTime) {
    return false;
  }
  const __uint128_t remainder = totalNumerator % denominator;

  input->generation = generation_.load(std::memory_order_acquire);
  input->streamFrameStart =
      frame_cursor_.load(std::memory_order_acquire);
  input->firstHostTicks = timestamp.mHostTime;
  input->endHostTicks =
      timestamp.mHostTime + static_cast<std::uint64_t>(duration);
  input->hostTickNumeratorPerFrame = numeratorPerFrame;
  input->hostTickDenominator = denominator;
  input->hostTickRemainderAtStart = carry;
  input->sampleRate = sample_rate_;
  input->frameCount = frameCount;
  input->timing = NativeAudioRenderInput::Timing::HostTicks;

  std::int64_t firstSample = 0;
  std::int64_t endSample = 0;
  if ((timestamp.mFlags & kAudioTimeStampSampleTimeValid) != 0 &&
      exactSampleTime(timestamp.mSampleTime, frameCount,
                      &firstSample, &endSample)) {
    input->firstSampleTime = firstSample;
    input->endSampleTime = endSample;
    input->timing = NativeAudioRenderInput::Timing::SampleTime;
  }
  *nextRemainder = remainder;
  *nextDenominator = denominator;
  *nextRateScalarBits = scalarBits;
  return true;
}

void NativeAudioOutput::zeroValidBuffer(
    AudioUnitRenderActionFlags *actionFlags, std::uint32_t frameCount,
    AudioBufferList *data) noexcept {
  if (actionFlags != nullptr) {
    *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
  }
  if (data == nullptr || data->mNumberBuffers != 1) {
    return;
  }
  AudioBuffer &buffer = data->mBuffers[0];
  if (buffer.mData == nullptr || buffer.mNumberChannels != kChannels) {
    return;
  }
  const std::uint64_t requested =
      static_cast<std::uint64_t>(frameCount) * kChannels * sizeof(float);
  const std::uint64_t bounded = std::min<std::uint64_t>(
      requested,
      static_cast<std::uint64_t>(kMaximumFramesPerSlice) * kChannels *
          sizeof(float));
  std::memset(buffer.mData, 0,
              static_cast<std::size_t>(
                  std::min<std::uint64_t>(bounded, buffer.mDataByteSize)));
}

OSStatus NativeAudioOutput::renderCallback(
    void *context, AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp, UInt32 busNumber,
    UInt32 frameCount, AudioBufferList *data) noexcept {
  if (context != &gCallbackBridge) {
    zeroValidBuffer(actionFlags, frameCount, data);
    return kAudio_ParamError;
  }
  auto &bridge = *static_cast<CallbackBridge *>(context);
  BridgeEntryGuard bridgeEntry(bridge);
  bool bridgePaused = true;
  if (!bridgeEntry.enter(&bridgePaused)) {
    zeroValidBuffer(actionFlags, frameCount, data);
    return kAudio_ParamError;
  }
  NativeAudioOutput *const output =
      bridge.owner.load(std::memory_order_acquire);
  if (output == nullptr) {
    zeroValidBuffer(actionFlags, frameCount, data);
    return noErr;
  }
  const NativeAudioOutputWakeSeam wake = output->wake_;
  if (output->before_admission_hook_ != nullptr) {
    output->before_admission_hook_(output->before_admission_context_);
  }
  const std::uint64_t admissionEpoch =
      output->admission_epoch_.load(std::memory_order_acquire);
  OSStatus status = kAudio_ParamError;
  std::uint32_t wakeReasons = 0;
  {
    EntryGuard entry(output->callback_entries_);
    try {
      @try {
        status = output->render(actionFlags, timestamp, busNumber,
                                frameCount, data, admissionEpoch,
                                !bridgePaused, &wakeReasons);
      } @catch (...) {
        output->latchFailure(NativeAudioOutputFailure::NativeException,
                             kAudio_ParamError);
      }
    } catch (...) {
      output->latchFailure(NativeAudioOutputFailure::NativeException,
                           kAudio_ParamError);
    }
    if (status != noErr) {
      zeroValidBuffer(actionFlags, frameCount, data);
    }
  }
  // The adapter/admission guards have drained. The exit pin keeps the adapter
  // and external wake storage alive across the bridge-count zero transition.
  BridgeExitPinGuard exitPin(bridge);
  if (output->failure_.load(std::memory_order_acquire) !=
          static_cast<std::uint8_t>(NativeAudioOutputFailure::None) &&
      !output->failure_wake_emitted_.exchange(
          true, std::memory_order_acq_rel)) {
    wakeReasons |= kWakeFailure;
  }
  const std::uint64_t bridgeBeforeRelease =
      bridge.gate.load(std::memory_order_acquire);
  const bool lifecycleWake =
      (bridgeBeforeRelease & (kBridgePaused | kBridgeDetached)) != 0;
  if (wakeReasons != 0 || lifecycleWake) {
    boundedCounterAdd(output->callback_wake_requests_, 1);
    if ((wakeReasons & kWakeRefill) != 0) {
      boundedCounterAdd(output->refill_wake_requests_, 1);
    }
    if ((wakeReasons & kWakeUnderrun) != 0) {
      boundedCounterAdd(output->underrun_wake_requests_, 1);
    }
    if ((wakeReasons & kWakeVideoDue) != 0) {
      boundedCounterAdd(output->video_due_wake_requests_, 1);
    }
    if ((wakeReasons & kWakeStateMask) != 0) {
      boundedCounterAdd(output->state_wake_requests_, 1);
    }
    if (signalWake(wake)) {
      boundedCounterAdd(output->callback_wake_signals_, 1);
    }
    if (output->after_callback_wake_hook_ != nullptr) {
      output->after_callback_wake_hook_(
          output->after_callback_wake_context_);
    }
  } else {
    boundedCounterAdd(output->suppressed_callback_wakes_, 1);
  }
  const std::uint64_t released = bridgeEntry.release();
  if (finalDrainingBridgeEntry(released)) {
    if (signalWake(wake)) {
      boundedCounterAdd(output->callback_wake_signals_, 1);
    }
  }
  return status;
}

void NativeAudioOutput::devicePropertyChanged(
    void *context, AudioUnit, AudioUnitPropertyID,
    AudioUnitScope, AudioUnitElement) noexcept {
  if (context != &gDeviceListenerBridge) {
    return;
  }
  auto &bridge = *static_cast<CallbackBridge *>(context);
  BridgeEntryGuard bridgeEntry(bridge);
  if (!bridgeEntry.enter()) {
    return;
  }
  NativeAudioOutput *const output =
      bridge.owner.load(std::memory_order_acquire);
  if (output == nullptr) {
    return;
  }
  output->admission_gate_.fetch_or(
      kAdmissionClosed | kAdmissionDeviceInvalid,
      std::memory_order_acq_rel);
  boundedCounterAdd(output->device_change_serial_, 1);
  const NativeAudioOutputWakeSeam wake = output->wake_;
  output->render_core_.setAccepting(false);
  output->started_.store(false, std::memory_order_release);
  output->stopped_.store(false, std::memory_order_release);
  output->setState(NativeAudioOutputState::Stopping);
  output->latchFailure(NativeAudioOutputFailure::DeviceRateMismatch,
                       kAudioUnitErr_FormatNotSupported);
  BridgeExitPinGuard exitPin(bridge);
  static_cast<void>(signalWake(wake));
  if (output->after_listener_wake_hook_ != nullptr) {
    output->after_listener_wake_hook_(
        output->after_listener_wake_context_);
  }
  const std::uint64_t released = bridgeEntry.release();
  if (finalDrainingBridgeEntry(released)) {
    static_cast<void>(signalWake(wake));
  }
}

bool NativeAudioOutput::signalWake(NativeAudioOutputWakeSeam wake) noexcept {
  if (wake.pending == nullptr || wake.signal == nullptr) {
    return false;
  }
  bool expected = false;
  if (wake.pending->compare_exchange_strong(
          expected, true, std::memory_order_acq_rel,
          std::memory_order_acquire)) {
    wake.signal(wake.context);
    return true;
  }
  return false;
}

NativeAudioOutputProgress NativeAudioOutput::quiescing() noexcept {
  static_cast<void>(signalWake(wake_));
  return NativeAudioOutputProgress::Quiescing;
}

OSStatus NativeAudioOutput::render(
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp, UInt32 busNumber,
    UInt32 frameCount, AudioBufferList *data,
    std::uint64_t admissionEpoch,
    bool bridgeAdmissionOpen,
    std::uint32_t *wakeReasons) noexcept {
  if (wakeReasons != nullptr) {
    *wakeReasons = 0;
  }
  boundedCounterAdd(callbacks_, 1);
  boundedCounterAdd(requested_frames_, frameCount);

  const std::uint64_t requestedBytes =
      static_cast<std::uint64_t>(frameCount) * kChannels * sizeof(float);
  const bool validBuffer =
      busNumber == 0 && frameCount != 0 &&
      frameCount <= kMaximumFramesPerSlice && data != nullptr &&
      data->mNumberBuffers == 1 && data->mBuffers[0].mData != nullptr &&
      data->mBuffers[0].mNumberChannels == kChannels &&
      data->mBuffers[0].mDataByteSize == requestedBytes;
  if (!validBuffer) {
    zeroValidBuffer(actionFlags, frameCount, data);
    latchFailure(NativeAudioOutputFailure::InvalidCallbackBuffer,
                 kAudio_ParamError);
    boundedCounterAdd(rejected_callbacks_, 1);
    return kAudio_ParamError;
  }

  if (!bridgeAdmissionOpen) {
    zeroValidBuffer(actionFlags, frameCount, data);
    boundedCounterAdd(rejected_callbacks_, 1);
    return noErr;
  }

  AdmissionGuard admission(admission_gate_);
  if (!admission.enter(kAdmissionClosed | kAdmissionDeviceInvalid,
                       kAdmissionCountMask) ||
      admission_epoch_.load(std::memory_order_acquire) != admissionEpoch) {
    zeroValidBuffer(actionFlags, frameCount, data);
    boundedCounterAdd(rejected_callbacks_, 1);
    return noErr;
  }
  first_callback_observed_.store(true, std::memory_order_release);

  if (render_gate_.test_and_set(std::memory_order_acquire)) {
    zeroValidBuffer(actionFlags, frameCount, data);
    latchFailure(NativeAudioOutputFailure::ReentrantCallback,
                 kAudio_ParamError);
    boundedCounterAdd(rejected_callbacks_, 1);
    return kAudio_ParamError;
  }
  RenderGateGuard renderGate(render_gate_);

  if (failure_.load(std::memory_order_acquire) !=
      static_cast<std::uint8_t>(NativeAudioOutputFailure::None)) {
    zeroValidBuffer(actionFlags, frameCount, data);
    boundedCounterAdd(rejected_callbacks_, 1);
    return noErr;
  }

  if (timestamp == nullptr) {
    zeroValidBuffer(actionFlags, frameCount, data);
    latchFailure(NativeAudioOutputFailure::InvalidCallbackTimestamp,
                 kAudio_ParamError);
    boundedCounterAdd(rejected_callbacks_, 1);
    return kAudio_ParamError;
  }

  NativeAudioRenderInput input;
  __uint128_t nextRemainder = 0;
  __uint128_t nextDenominator = 0;
  std::uint64_t nextRateScalarBits = 0;
  if (!callbackInput(*timestamp, frameCount, &input, &nextRemainder,
                     &nextDenominator, &nextRateScalarBits)) {
    zeroValidBuffer(actionFlags, frameCount, data);
    latchFailure(NativeAudioOutputFailure::InvalidCallbackTimestamp,
                 kAudio_ParamError);
    boundedCounterAdd(rejected_callbacks_, 1);
    return kAudio_ParamError;
  }

  auto *samples = static_cast<float *>(data->mBuffers[0].mData);
  const NativeAudioRenderResult result = render_core_.render(
      input, std::span<float>(samples,
                              static_cast<std::size_t>(frameCount) *
                                  kChannels));
  timing_remainder_ = nextRemainder;
  prior_timing_denominator_ = nextDenominator;
  prior_rate_scalar_bits_ = nextRateScalarBits;
  prior_end_host_ticks_ = input.endHostTicks;

  // The render core may publish media time across a device interval it could
  // not fill (a steady-state underrun). Those frames are as spent as rendered
  // ones: the clock has already passed them, so the stream cursor must move
  // with them or the next callback would describe a position the clock has
  // left behind and be rejected as invalid.
  const std::uint64_t advancedFrames =
      static_cast<std::uint64_t>(result.pcmFrames) +
      static_cast<std::uint64_t>(result.advancedSilentFrames);
  if (advancedFrames != 0) {
    const std::uint64_t cursor =
        frame_cursor_.load(std::memory_order_relaxed);
    if (advancedFrames > std::numeric_limits<std::uint64_t>::max() - cursor) {
      zeroValidBuffer(actionFlags, frameCount, data);
      latchFailure(NativeAudioOutputFailure::FrameCursorOverflow,
                   kAudio_ParamError);
      boundedCounterAdd(rejected_callbacks_, 1);
      return kAudio_ParamError;
    }
    frame_cursor_.store(cursor + advancedFrames, std::memory_order_release);
  }
  if (result.failure != NativeAudioRenderFailure::None) {
    latchFailure(NativeAudioOutputFailure::RenderCoreFailed,
                 kAudio_ParamError);
  }
  const bool underrun =
      result.admission == NativeMediaSegmentAdmission::Backpressure ||
      (result.committed && result.silentFrames != 0);
  if (result.pcmFrames != 0) {
    // Any consumed PCM proves that producer progress ended the prior
    // underrun. A short playable prefix can enter underrun again in this same
    // callback and must therefore publish a fresh edge.
    underrun_active_.store(false, std::memory_order_release);
  }
  if (underrun) {
    if (!underrun_active_.exchange(true, std::memory_order_acq_rel) &&
        wakeReasons != nullptr) {
      *wakeReasons |= kWakeUnderrun;
    }
  }
  // Refill edge. The producer's admission unit is a ring slab, not a frame:
  // it publishes one converter output per slab, so a full ring holds only
  // kSlabCount * framesPerPacket frames (1024 per AAC access unit), never
  // kSlabCount * kFramesPerSlab. A frame-count low-water mark therefore cannot
  // express "the producer may publish again" — any slab-derived threshold sits
  // above the occupancy the producer can reach, so its one-shot edge re-arms
  // once, fires once, and then latches off for the rest of playback. Wake on
  // the exact slab-retirement edge instead: it is codec-independent, it is the
  // precise moment the blocked producer regains admission, and a full ring
  // still produces no wake at all.
  {
    const auto queuedSlabs =
        static_cast<std::uint32_t>(render_core_.queuedRingSlabs());
    const std::uint32_t previousSlabs = observed_queued_slabs_.exchange(
        queuedSlabs, std::memory_order_acq_rel);
    if (previousSlabs != kUnobservedQueuedSlabs &&
        queuedSlabs < previousSlabs && wakeReasons != nullptr) {
      *wakeReasons |= kWakeRefill;
    }
  }
  if (result.pauseBoundary && wakeReasons != nullptr) {
    *wakeReasons |= kWakePause;
  }
  if (result.endOfStream && wakeReasons != nullptr) {
    *wakeReasons |= kWakeTerminal;
  }
  if (wake_.videoDueHostTicks != nullptr && wakeReasons != nullptr) {
    std::uint64_t due =
        wake_.videoDueHostTicks->load(std::memory_order_acquire);
    // One strong CAS keeps the AudioUnit callback strictly bounded. If the
    // worker races this attempt by publishing a replacement deadline, that
    // deadline remains armed and the next callback evaluates it.
    if (due != 0 && input.endHostTicks >= due &&
        wake_.videoDueHostTicks->compare_exchange_strong(
            due, 0, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
      *wakeReasons |= kWakeVideoDue;
    }
  }
  if (result.silentFrames == frameCount && actionFlags != nullptr) {
    *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
  }
  boundedCounterAdd(rendered_callbacks_, 1);
  return noErr;
}

NativeAudioOutputFacts NativeAudioOutput::facts() const noexcept {
  NativeAudioOutputFacts result;
  result.state = static_cast<NativeAudioOutputState>(
      state_.load(std::memory_order_acquire));
  result.failure = static_cast<NativeAudioOutputFailure>(
      failure_.load(std::memory_order_acquire));
  result.osStatus = os_status_.load(std::memory_order_acquire);
  result.generation = generation_.load(std::memory_order_relaxed);
  result.frameCursor = frame_cursor_.load(std::memory_order_relaxed);
  result.callbacks = callbacks_.load(std::memory_order_relaxed);
  result.renderedCallbacks =
      rendered_callbacks_.load(std::memory_order_relaxed);
  result.rejectedCallbacks =
      rejected_callbacks_.load(std::memory_order_relaxed);
  result.requestedFrames =
      requested_frames_.load(std::memory_order_relaxed);
  result.callbackWakeRequests =
      callback_wake_requests_.load(std::memory_order_relaxed);
  result.callbackWakeSignals =
      callback_wake_signals_.load(std::memory_order_relaxed);
  result.suppressedCallbackWakes =
      suppressed_callback_wakes_.load(std::memory_order_relaxed);
  result.refillWakeRequests =
      refill_wake_requests_.load(std::memory_order_relaxed);
  result.underrunWakeRequests =
      underrun_wake_requests_.load(std::memory_order_relaxed);
  result.videoDueWakeRequests =
      video_due_wake_requests_.load(std::memory_order_relaxed);
  result.stateWakeRequests =
      state_wake_requests_.load(std::memory_order_relaxed);
  result.sampleRate = published_sample_rate_.load(std::memory_order_relaxed);
  result.deviceBufferFrames =
      device_buffer_frames_.load(std::memory_order_acquire);
  result.callbackEntries =
      callback_entries_.load(std::memory_order_acquire);
  const std::uint64_t admission =
      admission_gate_.load(std::memory_order_acquire);
  result.admittedCallbacks = static_cast<std::uint32_t>(
      std::min<std::uint64_t>(admission & kAdmissionCountMask,
                              std::numeric_limits<std::uint32_t>::max()));
  result.configured = configured_.load(std::memory_order_acquire);
  result.activated = published_activated_.load(std::memory_order_acquire);
  result.started = started_.load(std::memory_order_acquire);
  result.stopped = stopped_.load(std::memory_order_acquire);
  result.fatal = result.failure != NativeAudioOutputFailure::None;
  result.firstCallbackObserved =
      first_callback_observed_.load(std::memory_order_acquire);
  NativeAudioOutput *const bridgeOwnerBefore =
      gCallbackBridge.owner.load(std::memory_order_acquire);
  if (after_facts_bridge_owner_hook_ != nullptr) {
    after_facts_bridge_owner_hook_(
        after_facts_bridge_owner_context_);
  }
  const std::uint64_t callbackBridgeGate =
      gCallbackBridge.gate.load(std::memory_order_acquire);
  const std::uint32_t callbackBridgeExitPins =
      gCallbackBridge.exitPins.load(std::memory_order_acquire);
  NativeAudioOutput *const bridgeOwnerAfter =
      gCallbackBridge.owner.load(std::memory_order_acquire);
  const bool ownsCallbackBridge =
      bridgeOwnerBefore == this && bridgeOwnerAfter == this;
  const bool callbackBridgeQuiescent =
      !ownsCallbackBridge ||
      ((callbackBridgeGate & kBridgeCountMask) == 0 &&
       callbackBridgeExitPins == 0);
  result.callbackQuiescent =
      result.callbackEntries == 0 && result.admittedCallbacks == 0 &&
      callbackBridgeQuiescent;
  return result;
}

}  // namespace wam::macos
