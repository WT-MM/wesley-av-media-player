#pragma once

#include "native_audio_render_core.hpp"
#include "native_audio_stretch_stage.hpp"
#include "native_audio_test_mute.hpp"

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
  // Appended, never inserted: the numeric value of every enumerator above is
  // already carried in telemetry.
  DeviceBufferFramesUnsupported,
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
  // The device IO buffer size the HAL accepted, in frames, or 0 when the
  // device would not report one. The render callback rate is sampleRate
  // divided by this, so it is the process's audio wake rate made observable.
  std::uint32_t deviceBufferFrames{0};
  // Notifications the StreamFormat listener has recorded, and whether one is
  // still unreconciled. The listener cannot tell a real device change from the
  // HAL re-publishing an unchanged format, so it only records; the count is
  // what makes "the listener fired" observable to a test or a log.
  std::uint64_t deviceChangeSerial{0};
  std::uint64_t deviceChangeReconciliations{0};
  bool deviceChangePending{false};
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
// latched; every later query must still equal it. A StreamFormat notification
// immediately revokes render admission, records the notification and wakes the
// serialized owner -- but it does NOT decide that the device changed, because
// the HAL posts this notification for reasons that leave the rate alone (a
// device re-publishing its unchanged format shortly after first audio, or
// another process changing the device-global IO buffer size). The listener
// cannot read a property from notification context, so the owner re-reads
// StreamFormat in reconcileDeviceChange(): only a rate that no longer equals
// the latched one is fatal, and an unchanged rate is recovered by a clean
// stop/start. Device invalidation and start admission share one atomic commit
// gate, so neither can overwrite the other, and the notification serial makes
// a notification that lands mid-reconciliation impossible to lose.
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
// until close() returns Done. While either callback context is attached, the
// output's slot in a bounded process registry retains the object.
//
// That registry is a statically allocated table of exactly
// kMaximumConcurrentPlayerWindows slots (native_concurrency_limits.hpp), one
// per simultaneously open player window; create() takes the first free slot
// and returns null once every slot is claimed. The table has process lifetime
// and is address-stable by construction -- never reallocated, never destroyed
// -- because CoreAudio holds the addresses of a slot's two bridges as the
// render callback's and the device property listener's void* contexts. A
// callback already in flight when its owner is released must land in a
// still-valid object and read a gate that tells it nobody is home; freeing or
// moving a slot would turn that landing into a use-after-free. Each slot's
// pair of bridges is private to the output that claimed it, so N windows
// neither share a gate nor observe each other's quiescence.
//
// Thus premature owner release quarantines that window's AudioUnit rather than
// freeing its callback context, the process holds at most
// kMaximumConcurrentPlayerWindows such quarantines, and recoverQuarantined()
// can finish teardown one at a time.
class NativeAudioOutput final
    : public std::enable_shared_from_this<NativeAudioOutput> {
 public:
  static constexpr std::uint32_t kChannels = 2;
  static constexpr std::uint32_t kMaximumFramesPerSlice =
      static_cast<std::uint32_t>(NativePcmRing::kFramesPerSlab);

  // Smallest PCM block the producer can put into one ring slab. The producer's
  // admission unit is a slab, not a frame: pump() converts one input lease per
  // call and publishes exactly one slab from it, so a slab carries one
  // delivered sample's decoded frames. AAC-LC's access unit is 1024 frames and
  // is the smallest among the admitted codecs (MP3 is 1152, ALAC up to 4096),
  // and a container may deliver exactly one access unit per sample. 1024 is
  // therefore the floor on what a slab is guaranteed to hold.
  static constexpr std::uint32_t kMinimumFramesPerPublishedSlab = 1024;

  // Frames a completely full ring is *guaranteed* to hold. Deliberately not
  // kSlabCount * kFramesPerSlab: that is the ring's storage, not its reachable
  // occupancy, because occupancy is counted in slabs and a slab may be short.
  static constexpr std::uint32_t kGuaranteedRingFrames =
      static_cast<std::uint32_t>(NativePcmRing::kSlabCount) *
      kMinimumFramesPerPublishedSlab;

  // Device periods of producer headroom the ring must carry. The producer is
  // rearmed by the slab-retirement edge that this render callback raises, so it
  // gets one scheduling opportunity per device period; requiring the ring to
  // span four periods is what keeps a single late producer pass from
  // underrunning rather than merely narrowing the window.
  static constexpr std::uint32_t kRingDevicePeriodsOfHeadroom = 4;

  // Media frames one device period can consume at the fastest admitted
  // playback rate. Below rate support this was the device period itself; a
  // time-stretched callback emits the same number of device frames but eats
  // rate times as many media frames, and the ring is stocked in MEDIA frames.
  // Every headroom inequality in this file is stated in that unit.
  static constexpr std::uint32_t kMaximumRateNumerator = 4;

  // Device IO buffer size requested from the HAL. Every render callback is a
  // real-time thread wake and the wake rate is exactly sampleRate/frames, so
  // this constant is the process's largest single wake-rate lever. Measured on
  // the default output device at 48 kHz: 512 -> 93.78 callbacks/s, 1024 ->
  // 46.88, 2048 -> 23.39, 4096 -> 11.67. Left unset the device keeps whatever
  // the previous client left behind, which is both unbounded from our side and
  // (at the system default of 512) twice the wake rate the ring can support.
  static constexpr std::uint32_t kDeviceBufferFrames = 1024;

  // A device period must fit in one render slice, or render() rejects every
  // callback as an invalid buffer.
  static_assert(kDeviceBufferFrames <= kMaximumFramesPerSlice);
  // ... and the ring must be able to cover kRingDevicePeriodsOfHeadroom of
  // them AT THE FASTEST ADMITTED RATE. This is the inequality that pins
  // NativePcmRing::kSlabCount to 16: 1024 * 4 (rate) * 4 (periods) == 16384 ==
  // 16 * kMinimumFramesPerPublishedSlab, exactly. Raising the requested size,
  // or the maximum rate, requires raising kSlabCount (or proving a larger
  // kMinimumFramesPerPublishedSlab) in the same change.
  static_assert(kDeviceBufferFrames * kMaximumRateNumerator *
                    kRingDevicePeriodsOfHeadroom <=
                kGuaranteedRingFrames);
  // The guaranteed occupancy can never exceed the storage that backs it.
  static_assert(kGuaranteedRingFrames <=
                static_cast<std::uint32_t>(NativePcmRing::kSlabCount) *
                    static_cast<std::uint32_t>(NativePcmRing::kFramesPerSlab));
  // Non-zero, and a power of two so the HAL accepts it verbatim on every
  // device whose range covers it.
  static_assert(kDeviceBufferFrames != 0 &&
                (kDeviceBufferFrames & (kDeviceBufferFrames - 1)) == 0);

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

  // Publishes an exact rational playback rate. Owner-thread only, and safe
  // while the render callback runs: the pitch-preserving stage is created
  // here on first non-unit use and the callback latches the new rational at
  // its own boundary. The unit rate never creates a stage, so the default
  // path keeps exactly the cost profile it had before rate support existed.
  // Failure means the stage could not be created or the rate is outside the
  // admitted window; the previously accepted rate stays in force.
  [[nodiscard]] bool setRate(NativePlaybackRate rate) noexcept;
  [[nodiscard]] NativePlaybackRate rate() const noexcept;
  // Live "Preserve pitch at other speeds" preference. Never fails and never
  // needs a stretch unit of its own: it is stored in the render core and the
  // stage picks it up at the next callback boundary, at the unit rate as a
  // no-op and otherwise as the stage's pitch offset.
  void setPreservePitch(bool preserve) noexcept;
  [[nodiscard]] bool preservePitch() const noexcept;

  [[nodiscard]] NativeAudioOutputProgress start() noexcept;
  [[nodiscard]] NativeAudioOutputProgress stop() noexcept;
  [[nodiscard]] NativeAudioOutputProgress close() noexcept;

  // Serialized owner half of the StreamFormat listener. The listener runs in
  // HAL notification context and cannot read a property, so it only revokes
  // admission and records the notification; deciding what the notification
  // MEANT is this call's job and belongs on the owner thread.
  //
  // Done with facts().deviceChangePending false means the device is proven
  // unchanged and the output is back at a Done stop, ready for start(). The
  // owner is responsible for restarting it: this call deliberately does not,
  // because only the owner knows whether the graph should be running.
  // Failed latches DeviceRateMismatch and is reserved for a rate that really
  // moved off the value configure() latched, or a format query that failed.
  // Quiescing means a callback entered before admission closed has not drained
  // yet, or a fresh notification arrived mid-reconciliation; call again.
  // Done with nothing pending, and Invalid outside a configured unit, are both
  // no-ops.
  [[nodiscard]] NativeAudioOutputProgress reconcileDeviceChange() noexcept;

  [[nodiscard]] NativeAudioOutputFacts facts() const noexcept;

  // Test/lifecycle recovery seam for the bounded process retention. Production
  // code normally never calls this: retaining the returned owner until close()
  // is Done prevents quarantine. A non-null result gives the caller an owner
  // with which it can finish close().
  //
  // At most one output per call, so a caller draining the registry repeats
  // until it returns null. An output no reference but its slot's retention
  // still keeps alive -- the true quarantine, which nothing else can ever
  // close -- is returned ahead of a still-retained one, so a healthy playing
  // window is never handed to a caller that would close it.
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
  // Test-only silent output; see native_audio_test_mute.hpp. Snapshotted once
  // here so the render callback reads a plain bool, never an atomic, and an
  // unmuted process pays exactly one never-taken branch per callback.
  const bool test_muted_{nativeAudioOutputTestMuted()};

  // Created lazily on the first non-unit rate and destroyed with the output.
  // Its absence is the proof that a unit-rate session paid nothing for rate
  // support: no component lookup, no instance, no workspace, no property
  // traffic.
  std::unique_ptr<NativeAudioStretchUnit> stretch_;

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
  // Whether this output still holds the claim on gSlots[slot_index_]. Taken
  // once by create() and released exactly once, on the first of the three
  // paths that can end the claim: the already-detached close() short circuit,
  // the completed close(), or the destructor of an output that never closed.
  bool claim_held_{false};
  // Index of this output's slot in the .mm's process-lifetime registry, fixed
  // by create() before the object is ever published and never changed again --
  // not even by close(), because facts() must still be able to see that the
  // slot's bridges have moved on to a replacement output. -1 is unreachable
  // for any object a caller can hold: create() is the only way to obtain one
  // and it assigns a real index or destroys the object. int rather than the
  // slot type so this header stays free of the registry's layout.
  int slot_index_{-1};
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
  std::atomic<std::uint64_t> device_change_reconciliations_{0};
  std::atomic_flag render_gate_ = ATOMIC_FLAG_INIT;

  alignas(128) std::atomic<std::uint8_t> state_{
      static_cast<std::uint8_t>(NativeAudioOutputState::Closed)};
  std::atomic<std::uint8_t> failure_{
      static_cast<std::uint8_t>(NativeAudioOutputFailure::None)};
  std::atomic<std::int32_t> os_status_{noErr};
  std::atomic<std::uint64_t> generation_{0};
  std::atomic<std::uint64_t> frame_cursor_{0};
  std::atomic<std::uint32_t> published_sample_rate_{0};
  std::atomic<std::uint32_t> device_buffer_frames_{0};
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

// Media frames one device period of `deviceBufferFrames` can consume at the
// fastest admitted playback rate. Below rate support this was the device
// period itself; a time-stretched callback emits the same number of device
// frames but eats rate times as many media frames, and the ring is stocked in
// MEDIA frames. Every producer-headroom inequality is stated in that unit.
[[nodiscard]] constexpr std::uint32_t maximumMediaFramesPerDevicePeriod(
    std::uint32_t deviceBufferFrames) noexcept {
  return deviceBufferFrames * NativeAudioOutput::kMaximumRateNumerator;
}

}  // namespace wam::macos
