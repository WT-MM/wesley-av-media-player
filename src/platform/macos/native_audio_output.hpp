#pragma once

#include "native_audio_render_core.hpp"

#include <AudioToolbox/AudioToolbox.h>

#include <atomic>
#include <cstdint>
#include <limits>
#include <memory>

namespace wam::macos {

// Every AudioUnit/host-clock dependency is injected. The table is copied into
// NativeAudioOutput and its opaque context must outlive the output. None of
// these calls is made from the render callback.
struct NativeAudioUnitCallTable {
  void *context{nullptr};
  AudioComponent (*findNext)(void *context, AudioComponent current,
                             const AudioComponentDescription *description){
      nullptr};
  OSStatus (*instanceNew)(void *context, AudioComponent component,
                          AudioComponentInstance *instance){nullptr};
  OSStatus (*instanceDispose)(void *context,
                              AudioComponentInstance instance){nullptr};
  OSStatus (*setProperty)(void *context, AudioUnit unit,
                          AudioUnitPropertyID property,
                          AudioUnitScope scope,
                          AudioUnitElement element, const void *data,
                          UInt32 dataSize){nullptr};
  OSStatus (*getProperty)(void *context, AudioUnit unit,
                          AudioUnitPropertyID property,
                          AudioUnitScope scope,
                          AudioUnitElement element, void *data,
                          UInt32 *dataSize){nullptr};
  OSStatus (*initialize)(void *context, AudioUnit unit){nullptr};
  OSStatus (*uninitialize)(void *context, AudioUnit unit){nullptr};
  OSStatus (*start)(void *context, AudioUnit unit){nullptr};
  OSStatus (*stop)(void *context, AudioUnit unit){nullptr};
  OSStatus (*addPropertyListener)(
      void *context, AudioUnit unit, AudioUnitPropertyID property,
      AudioUnitPropertyListenerProc listener, void *listenerContext){nullptr};
  OSStatus (*removePropertyListener)(
      void *context, AudioUnit unit, AudioUnitPropertyID property,
      AudioUnitPropertyListenerProc listener, void *listenerContext){nullptr};
  Float64 (*hostClockFrequency)(void *context){nullptr};
};

[[nodiscard]] NativeAudioUnitCallTable
nativeAudioUnitSystemCallTable() noexcept;

struct NativeAudioOutputConfiguration {
  std::uint64_t generation{0};
  std::uint64_t streamFrameCursor{0};
  media::MediaTime mediaOrigin{};
  std::uint64_t hostTicksPerSecond{0};
  std::uint32_t sampleRate{0};
  // Exact paused generation/Commit position. mediaOrigin is independently
  // the source timestamp of generation-local PCM frame zero.
  media::MediaTime pausedClockPosition{};
};

using NativeAudioOutputWake = void (*)(void *context) noexcept;

// Immutable callback seam. pending, videoDueHostTicks, and context must
// outlive successful close() and any signal call already in progress. The
// callback changes *pending from false to true and calls signal() only for
// that transition. videoDueHostTicks is optional; when present, zero means no
// video deadline and a nonzero value is the exact host-tick deadline published
// by the serialized session worker. The callback consumes a reached deadline
// with compare-exchange before waking that worker.
// Both pending and signal are mandatory at create(). After waking, the owner
// clears pending before it reads facts or retries stop()/close(); an exit
// racing that retry then rearms the signal. Every lifecycle operation that
// returns Quiescing also re-arms before returning. This closes the interval in
// which an already-coalesced callback notification precedes its final bridge-
// count decrement. The pending atomic and signal() must be bounded, lock-free,
// wait-free, and exception-free (for example, a semaphore signal).
struct NativeAudioOutputWakeSeam {
  std::atomic<bool> *pending{nullptr};
  NativeAudioOutputWake signal{nullptr};
  void *context{nullptr};
  std::atomic<std::uint64_t> *videoDueHostTicks{nullptr};
};

enum class NativeAudioOutputProgress : std::uint8_t {
  Done,
  Quiescing,
  Invalid,
  Failed,
};

enum class NativeAudioOutputState : std::uint8_t {
  Closed,
  Configuring,
  Stopped,
  Starting,
  Started,
  Stopping,
  Detaching,
};

enum class NativeAudioOutputFailure : std::uint8_t {
  None,
  InvalidConfiguration,
  ComponentUnavailable,
  InstanceCreationFailed,
  DeviceFormatQueryFailed,
  DeviceRateMismatch,
  DeviceListenerInstallationFailed,
  DeviceListenerRemovalFailed,
  MaximumFramesConfigurationFailed,
  ClientFormatConfigurationFailed,
  RenderCoreActivationFailed,
  CallbackInstallationFailed,
  InitializationFailed,
  StartFailed,
  StopFailed,
  UninitializationFailed,
  CallbackDetachmentFailed,
  InstanceDisposalFailed,
  InvalidCallbackBuffer,
  InvalidCallbackTimestamp,
  ReentrantCallback,
  FrameCursorOverflow,
  RenderCoreFailed,
  NativeException,
};

// Independently atomic, bounded facts rather than a transactional snapshot.
// started means AudioOutputUnitStart succeeded and stop has not been requested.
// stopped means render admission is revoked, AudioOutputUnitStop (when needed)
// succeeded, and every callback that captured an open admission bridge has
// exited. A later callback can only silence under the stopped bridge epoch.
// callbackQuiescent is true only after the inner adapter/core counters, raw
// callback bridge entries, and lifetime-safe exit notifications have drained;
// a Done stop is the durable proof needed before ring/clock mutation or
// admission reopening.
struct NativeAudioOutputFacts {
  NativeAudioOutputState state{NativeAudioOutputState::Closed};
  NativeAudioOutputFailure failure{NativeAudioOutputFailure::None};
  OSStatus osStatus{noErr};
  std::uint64_t generation{0};
  std::uint64_t frameCursor{0};
  std::uint64_t callbacks{0};
  std::uint64_t renderedCallbacks{0};
  std::uint64_t rejectedCallbacks{0};
  std::uint64_t requestedFrames{0};
  std::uint64_t callbackWakeRequests{0};
  std::uint64_t callbackWakeSignals{0};
  std::uint64_t suppressedCallbackWakes{0};
  std::uint64_t refillWakeRequests{0};
  std::uint64_t underrunWakeRequests{0};
  std::uint64_t videoDueWakeRequests{0};
  std::uint64_t stateWakeRequests{0};
  std::uint32_t sampleRate{0};
  std::uint32_t callbackEntries{0};
  std::uint32_t admittedCallbacks{0};
  bool configured{false};
  bool activated{false};
  bool started{false};
  bool stopped{true};
  bool fatal{false};
  bool firstCallbackObserved{false};
  bool callbackQuiescent{true};
};

// Serialized lifecycle owner for a macOS DefaultOutput AudioUnit. configure(),
// activate(), start(), stop(), and close() are called by one off-real-time
// owner and never concurrently. The system render callback performs bounded
// validation and calls only NativeAudioRenderCore::render for media work.
// It requires CoreAudio's exact HostTime timestamp for the first frame. The
// exclusive end is a deterministic device-presentation prediction derived
// from frame count, the integral host frequency, and rateScalar represented as
// its exact positive IEEE-754 binary rational. An integer remainder is carried
// across exactly adjacent callbacks having the same scalar; scalars whose
// exact bounded rational cannot be evaluated are rejected. An exact integral
// SampleTime additionally proves sample-frame continuity; other sample
// timestamps safely use HostTicks timing.
// The client (input-scope) format is always the STREAM rate, and every host-
// tick computation, the published sample rate, and the render core all stay in
// that one stream-rate domain. The device is not required to run at the stream
// rate and its nominal rate is never changed: when the two differ, the output
// AudioUnit's OWN converter resamples at the input-scope boundary, and the
// render callback's frame counts and timestamps are already delivered in the
// client domain. No sample-rate conversion is ever performed by this code.
// A StreamFormat property listener remains installed for the complete unit
// lifetime. The device rate observed at the first configure()-time query is
// latched; every later query must still equal it. Any live device/default-
// format change therefore immediately revokes render admission, latches a
// fatal rate failure, and wakes the serialized owner. Device invalidation and
// start admission share one atomic commit gate, so neither can overwrite the
// other.
//
// stop() first revokes callback/core admission, then stops the AudioUnit. It
// never spins: Quiescing asks the owner to retry after an entered callback
// exits. A Done stop is the proof required before mutating the ring or clock.
// activate() is the stopped-only quiescent generation/cursor reset used after
// such a mutation and before the next start. A monotonically increasing
// admission epoch also prevents a callback that raced a stopped interval from
// crossing the next start boundary. mediaOrigin is the exact nonnegative
// media position of generation-local frame zero.
//
// close() is idempotent and progresses without a sleep, spin, thread, or timer
// through stop, logical callback/listener sealing, entry drain, uninitialize,
// physical callback detach, device-listener removal, and dispose. Logical
// sealing makes every later OS entry fail closed without dereferencing the
// owner; uninitialize therefore cannot overlap any adapter or listener entry.
// The owner must retain this object, its call-table context, and wake storage
// until close() returns Done. While either callback
// context is attached, a single bounded process registry retains the object
// and create() rejects a second output. Thus premature owner release
// quarantines at most one AudioUnit rather than freeing its callback context;
// recoverQuarantined() can finish teardown.
class NativeAudioOutput final
    : public std::enable_shared_from_this<NativeAudioOutput> {
 public:
  static constexpr std::uint32_t kChannels = 2;
  static constexpr std::uint32_t kMaximumFramesPerSlice =
      static_cast<std::uint32_t>(NativePcmRing::kFramesPerSlab);

  [[nodiscard]] static std::shared_ptr<NativeAudioOutput> create(
      NativeAudioRenderCore &renderCore,
      NativeAudioUnitCallTable calls,
      NativeAudioOutputWakeSeam wake) noexcept;
  ~NativeAudioOutput();

  NativeAudioOutput(const NativeAudioOutput &) = delete;
  NativeAudioOutput &operator=(const NativeAudioOutput &) = delete;
  NativeAudioOutput(NativeAudioOutput &&) = delete;
  NativeAudioOutput &operator=(NativeAudioOutput &&) = delete;

  [[nodiscard]] NativeAudioOutputProgress
  configure(NativeAudioOutputConfiguration configuration) noexcept;

  // Re-establishes generation-local render state after a completed stop and
  // owner-serialized ring/clock transition. The sample rate is immutable for
  // the lifetime of the configured AudioUnit.
  [[nodiscard]] NativeAudioOutputProgress
  activate(std::uint64_t generation, std::uint64_t streamFrameCursor,
           media::MediaTime mediaOrigin,
           media::MediaTime pausedClockPosition) noexcept;

  [[nodiscard]] NativeAudioOutputProgress start() noexcept;
  [[nodiscard]] NativeAudioOutputProgress stop() noexcept;
  [[nodiscard]] NativeAudioOutputProgress close() noexcept;

  [[nodiscard]] NativeAudioOutputFacts facts() const noexcept;

  // Test/lifecycle recovery seam for the single bounded process retention.
  // Production code normally never calls this: retaining the returned owner
  // until close() is Done prevents quarantine. A non-null result gives the
  // caller an owner with which it can finish close().
  [[nodiscard]] static std::shared_ptr<NativeAudioOutput>
  recoverQuarantined() noexcept;

 private:
  explicit NativeAudioOutput(NativeAudioRenderCore &renderCore,
                             NativeAudioUnitCallTable calls,
                             NativeAudioOutputWakeSeam wake) noexcept;

  static OSStatus renderCallback(
      void *context, AudioUnitRenderActionFlags *actionFlags,
      const AudioTimeStamp *timestamp, UInt32 busNumber,
      UInt32 frameCount, AudioBufferList *data) noexcept;
  static void devicePropertyChanged(
      void *context, AudioUnit unit, AudioUnitPropertyID property,
      AudioUnitScope scope, AudioUnitElement element) noexcept;

  [[nodiscard]] OSStatus render(
      AudioUnitRenderActionFlags *actionFlags,
      const AudioTimeStamp *timestamp, UInt32 busNumber,
      UInt32 frameCount, AudioBufferList *data,
      std::uint64_t admissionEpoch,
      bool bridgeAdmissionOpen,
      std::uint32_t *wakeReasons) noexcept;
  [[nodiscard]] static bool signalWake(
      NativeAudioOutputWakeSeam wake) noexcept;
  [[nodiscard]] NativeAudioOutputProgress quiescing() noexcept;
  [[nodiscard]] NativeAudioOutputProgress closeStep() noexcept;

  [[nodiscard]] bool validCallTable() const noexcept;
  [[nodiscard]] bool admittedSampleRate(std::uint32_t sampleRate) const
      noexcept;
  [[nodiscard]] bool usableDeviceRate(
      const AudioStreamBasicDescription &format) const noexcept;
  [[nodiscard]] bool validDeviceRate(
      const AudioStreamBasicDescription &format) const noexcept;
  [[nodiscard]] bool validClientFormat(
      const AudioStreamBasicDescription &format) const noexcept;
  [[nodiscard]] AudioStreamBasicDescription clientFormat() const noexcept;
  [[nodiscard]] bool callbackInput(
      const AudioTimeStamp &timestamp, std::uint32_t frameCount,
      NativeAudioRenderInput *input,
      __uint128_t *nextRemainder,
      __uint128_t *nextDenominator,
      std::uint64_t *nextRateScalarBits) noexcept;
  [[nodiscard]] static bool rateScalarComponents(
      double rateScalar, std::uint64_t *significand,
      int *binaryExponent, std::uint64_t *bits) noexcept;
  [[nodiscard]] static bool exactSampleTime(
      double sampleTime, std::uint32_t frameCount,
      std::int64_t *first, std::int64_t *end) noexcept;

  static void zeroValidBuffer(AudioUnitRenderActionFlags *actionFlags,
                              std::uint32_t frameCount,
                              AudioBufferList *data) noexcept;
  static void boundedCounterAdd(std::atomic<std::uint64_t> &counter,
                                std::uint64_t amount) noexcept;
  void latchFailure(NativeAudioOutputFailure failure,
                    OSStatus status) noexcept;
  void setState(NativeAudioOutputState state) noexcept;

  [[nodiscard]] AudioComponent findComponent(
      const AudioComponentDescription &description) noexcept;
  [[nodiscard]] OSStatus newInstance(AudioComponent component,
                                     AudioComponentInstance *instance)
      noexcept;
  [[nodiscard]] OSStatus disposeInstance(AudioComponentInstance instance)
      noexcept;
  [[nodiscard]] OSStatus setProperty(AudioUnitPropertyID property,
                                     AudioUnitScope scope,
                                     AudioUnitElement element,
                                     const void *data,
                                     UInt32 dataSize) noexcept;
  [[nodiscard]] OSStatus getProperty(AudioUnitPropertyID property,
                                     AudioUnitScope scope,
                                     AudioUnitElement element, void *data,
                                     UInt32 *dataSize) noexcept;
  [[nodiscard]] OSStatus initializeUnit() noexcept;
  [[nodiscard]] OSStatus uninitializeUnit() noexcept;
  [[nodiscard]] OSStatus startUnit() noexcept;
  [[nodiscard]] OSStatus stopUnit() noexcept;
  [[nodiscard]] OSStatus addDeviceListener() noexcept;
  [[nodiscard]] OSStatus removeDeviceListener() noexcept;
  [[nodiscard]] double hostClockFrequency() noexcept;

  NativeAudioRenderCore &render_core_;
  const NativeAudioUnitCallTable calls_;
  const NativeAudioOutputWakeSeam wake_;

  AudioComponentInstance unit_{nullptr};
  std::uint64_t host_ticks_per_second_{0};
  __uint128_t timing_remainder_{0};
  __uint128_t prior_timing_denominator_{0};
  std::uint64_t prior_rate_scalar_bits_{0};
  std::uint64_t prior_end_host_ticks_{0};
  std::uint32_t sample_rate_{0};
  // The DEVICE format rate latched at the first configure()-time query. It is
  // deliberately independent of sample_rate_ (the stream rate): the client
  // format and every timing computation stay in the stream-rate domain while
  // the unit's own converter bridges to whatever the device runs at. A later
  // query that no longer matches this latched value proves the device changed
  // under us and is fatal.
  Float64 device_rate_{0.0};
  bool used_{false};
  bool callback_attached_{false};
  bool listener_attached_{false};
  bool initialize_attempted_{false};
  bool initialized_{false};
  bool stop_required_{false};
  bool stop_succeeded_{true};
  bool activated_{false};
  bool claim_held_{false};
  std::shared_ptr<NativeAudioOutput> callback_self_owner_;

  using TestHook = void (*)(void *context) noexcept;
  TestHook before_admission_hook_{nullptr};
  void *before_admission_context_{nullptr};
  TestHook before_start_commit_hook_{nullptr};
  void *before_start_commit_context_{nullptr};
  TestHook after_callback_wake_hook_{nullptr};
  void *after_callback_wake_context_{nullptr};
  TestHook after_listener_wake_hook_{nullptr};
  void *after_listener_wake_context_{nullptr};
  TestHook after_facts_bridge_owner_hook_{nullptr};
  void *after_facts_bridge_owner_context_{nullptr};

  static constexpr std::uint64_t kAdmissionClosed =
      std::uint64_t{1} << 63U;
  static constexpr std::uint64_t kAdmissionDeviceInvalid =
      std::uint64_t{1} << 62U;
  static constexpr std::uint64_t kAdmissionCountMask =
      kAdmissionDeviceInvalid - 1U;
  // No queued slab is observable before the first render callback.
  static constexpr std::uint32_t kUnobservedQueuedSlabs =
      std::numeric_limits<std::uint32_t>::max();

  std::atomic<std::uint32_t> callback_entries_{0};
  std::atomic<std::uint64_t> admission_gate_{kAdmissionClosed};
  std::atomic<std::uint64_t> admission_epoch_{1};
  std::atomic<std::uint64_t> device_change_serial_{0};
  std::atomic_flag render_gate_ = ATOMIC_FLAG_INIT;

  alignas(128) std::atomic<std::uint8_t> state_{
      static_cast<std::uint8_t>(NativeAudioOutputState::Closed)};
  std::atomic<std::uint8_t> failure_{
      static_cast<std::uint8_t>(NativeAudioOutputFailure::None)};
  std::atomic<std::int32_t> os_status_{noErr};
  std::atomic<std::uint64_t> generation_{0};
  std::atomic<std::uint64_t> frame_cursor_{0};
  std::atomic<std::uint32_t> published_sample_rate_{0};
  std::atomic<bool> configured_{false};
  std::atomic<bool> published_activated_{false};
  std::atomic<bool> started_{false};
  std::atomic<bool> stopped_{true};
  std::atomic<bool> first_callback_observed_{false};
  std::atomic<std::uint64_t> callbacks_{0};
  std::atomic<std::uint64_t> rendered_callbacks_{0};
  std::atomic<std::uint64_t> rejected_callbacks_{0};
  std::atomic<std::uint64_t> requested_frames_{0};
  std::atomic<std::uint64_t> callback_wake_requests_{0};
  std::atomic<std::uint64_t> callback_wake_signals_{0};
  std::atomic<std::uint64_t> suppressed_callback_wakes_{0};
  std::atomic<std::uint64_t> refill_wake_requests_{0};
  std::atomic<std::uint64_t> underrun_wake_requests_{0};
  std::atomic<std::uint64_t> video_due_wake_requests_{0};
  std::atomic<std::uint64_t> state_wake_requests_{0};
  std::atomic<std::uint32_t> observed_queued_slabs_{kUnobservedQueuedSlabs};
  std::atomic<bool> underrun_active_{false};
  std::atomic<bool> failure_wake_emitted_{false};

  friend struct NativeAudioOutputTestAccess;
};

}  // namespace wam::macos
