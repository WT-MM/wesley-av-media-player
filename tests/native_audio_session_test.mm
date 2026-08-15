#define WAM_NATIVE_AUDIO_SESSION_TESTING 1

#include "media/native_media_dispatcher.hpp"
#include "platform/macos/native_audio_session.hpp"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstddef>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <optional>
#include <span>
#include <thread>
#include <utility>
#include <vector>

namespace {

std::atomic<bool> trackAllocations{false};
std::atomic<std::uint64_t> allocations{0};

void noteAllocation() noexcept {
  if (trackAllocations.load(std::memory_order_relaxed)) {
    allocations.fetch_add(1, std::memory_order_relaxed);
  }
}

} // namespace

void* operator new(std::size_t size) {
  noteAllocation();
  if (void* memory = std::malloc(size == 0 ? 1 : size)) {
    return memory;
  }
  throw std::bad_alloc();
}

void* operator new[](std::size_t size) { return ::operator new(size); }
void operator delete(void* memory) noexcept { std::free(memory); }
void operator delete[](void* memory) noexcept { std::free(memory); }
void operator delete(void* memory, std::size_t) noexcept {
  std::free(memory);
}
void operator delete[](void* memory, std::size_t) noexcept {
  std::free(memory);
}

namespace {

using namespace wam::macos;
using namespace wam::media;

constexpr std::uint32_t kRate = 48'000;
constexpr MediaTrackId kTrack = 2;
int failures = 0;

static_assert(noexcept(
    std::declval<NativeAudioSession&>().setGain(0.5F)));
static_assert(noexcept(
    std::declval<NativeAudioSession&>().setMuted(true)));

void expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

struct BackendScript {
  std::size_t consume{0};
  std::size_t produce{0};
  bool finalInputReleased{false};
  bool needsInput{false};
  bool drained{false};
  bool failed{false};
};

struct BackendState {
  std::array<BackendScript, 8> scripts{};
  std::size_t scriptCount{0};
  std::size_t scriptIndex{0};
  std::uint32_t channels{0};
  std::uint32_t rate{0};
  std::uint32_t configureCalls{0};
  std::uint32_t resetCalls{0};
  std::uint32_t closeCalls{0};
  bool configureSucceeds{true};
  bool resetSucceeds{true};

  void add(BackendScript script) noexcept {
    scripts[scriptCount++] = script;
  }
};

class FakeBackend final : public NativeAudioConverterBackend {
 public:
  explicit FakeBackend(std::shared_ptr<BackendState> state) noexcept
      : state_(std::move(state)) {}

  bool configure(const NativeAudioBackendConfiguration& configuration,
                 std::string*) override {
    ++state_->configureCalls;
    state_->channels = configuration.outputChannels;
    state_->rate = configuration.outputSampleRate;
    return state_->configureSucceeds;
  }

  NativeAudioBackendResult convert(
      NativeAudioBackendInput input,
      std::span<float> interleavedOutput) override {
    if (state_->scriptIndex >= state_->scriptCount) {
      return {.failed = true};
    }
    const BackendScript script = state_->scripts[state_->scriptIndex++];
    const std::size_t samples = script.produce * state_->channels;
    if (script.consume > input.packets.size() ||
        samples > interleavedOutput.size()) {
      return {.failed = true};
    }
    for (std::size_t index = 0; index < samples; ++index) {
      interleavedOutput[index] = static_cast<float>((index % 31) + 1) / 31.0F;
    }
    return {script.consume, script.produce, script.finalInputReleased,
            script.needsInput, script.drained, script.failed};
  }

  bool reset(std::string*) override {
    ++state_->resetCalls;
    state_->scriptIndex = 0;
    return state_->resetSucceeds;
  }

  void close() noexcept override { ++state_->closeCalls; }

 private:
  std::shared_ptr<BackendState> state_;
};

struct FakePlatform final {
  std::atomic<bool> wakePending{false};
  std::atomic<std::uint64_t> wakeSignals{0};
  std::atomic<std::uint64_t> now{1'000};
  std::atomic<bool> blockHost{false};
  std::mutex hostMutex;
  std::condition_variable hostCondition;
  bool hostEntered{false};
  bool releaseHost{false};

  std::mutex callbackMutex;
  std::condition_variable callbackCondition;
  bool callbackEntered{false};
  bool releaseCallback{false};

  int componentToken{0};
  int unitToken{0};
  bool initialized{false};
  bool started{false};
  bool callbackAttached{false};
  bool listenerAttached{false};
  bool failInitialize{false};
  int disposeFailures{0};
  std::uint32_t maximumFrames{NativeAudioOutput::kMaximumFramesPerSlice};
  AudioStreamBasicDescription clientFormat{};
  AURenderCallback callback{nullptr};
  void* callbackContext{nullptr};
  AudioUnitPropertyListenerProc listener{nullptr};
  void* listenerContext{nullptr};

  static FakePlatform& self(void* context) noexcept {
    return *static_cast<FakePlatform*>(context);
  }

  static std::uint64_t readTicks(void* context) noexcept {
    FakePlatform& fake = self(context);
    if (fake.blockHost.load(std::memory_order_acquire)) {
      std::unique_lock<std::mutex> lock(fake.hostMutex);
      fake.hostEntered = true;
      fake.hostCondition.notify_all();
      fake.hostCondition.wait(lock, [&fake] { return fake.releaseHost; });
    }
    return fake.now.load(std::memory_order_relaxed);
  }

  static void blockAfterRenderPreflight(void* context) noexcept {
    FakePlatform& fake = self(context);
    std::unique_lock<std::mutex> lock(fake.callbackMutex);
    fake.callbackEntered = true;
    fake.callbackCondition.notify_all();
    fake.callbackCondition.wait(
        lock, [&fake] { return fake.releaseCallback; });
  }

  static void signalWake(void* context) noexcept {
    self(context).wakeSignals.fetch_add(1, std::memory_order_relaxed);
  }

  static AudioComponent findNext(
      void* context, AudioComponent,
      const AudioComponentDescription* description) {
    FakePlatform& fake = self(context);
    if (description == nullptr ||
        description->componentType != kAudioUnitType_Output ||
        description->componentSubType != kAudioUnitSubType_DefaultOutput ||
        description->componentManufacturer != kAudioUnitManufacturer_Apple) {
      return nullptr;
    }
    return reinterpret_cast<AudioComponent>(&fake.componentToken);
  }

  static OSStatus instanceNew(void* context, AudioComponent component,
                              AudioComponentInstance* instance) {
    FakePlatform& fake = self(context);
    if (component == nullptr || instance == nullptr) {
      return kAudio_ParamError;
    }
    *instance = reinterpret_cast<AudioComponentInstance>(&fake.unitToken);
    return noErr;
  }

  static OSStatus instanceDispose(void* context,
                                  AudioComponentInstance instance) {
    FakePlatform& fake = self(context);
    if (fake.disposeFailures > 0) {
      --fake.disposeFailures;
      return kAudio_ParamError;
    }
    if (instance == reinterpret_cast<AudioComponentInstance>(
                        &fake.unitToken)) {
      return noErr;
    }
    return kAudio_ParamError;
  }

  static OSStatus setProperty(void* context, AudioUnit,
                              AudioUnitPropertyID property,
                              AudioUnitScope scope, AudioUnitElement,
                              const void* data, UInt32 size) {
    FakePlatform& fake = self(context);
    if (property == kAudioUnitProperty_MaximumFramesPerSlice &&
        size == sizeof(UInt32) && data != nullptr) {
      fake.maximumFrames = *static_cast<const UInt32*>(data);
      return noErr;
    }
    if (property == kAudioUnitProperty_StreamFormat &&
        scope == kAudioUnitScope_Input &&
        size == sizeof(AudioStreamBasicDescription) && data != nullptr) {
      fake.clientFormat =
          *static_cast<const AudioStreamBasicDescription*>(data);
      return noErr;
    }
    if (property == kAudioUnitProperty_SetRenderCallback &&
        size == sizeof(AURenderCallbackStruct) && data != nullptr) {
      const auto callback = static_cast<const AURenderCallbackStruct*>(data);
      fake.callback = callback->inputProc;
      fake.callbackContext = callback->inputProcRefCon;
      fake.callbackAttached = fake.callback != nullptr;
      return noErr;
    }
    return kAudioUnitErr_InvalidProperty;
  }

  static OSStatus getProperty(void* context, AudioUnit,
                              AudioUnitPropertyID property,
                              AudioUnitScope scope, AudioUnitElement,
                              void* data, UInt32* size) {
    FakePlatform& fake = self(context);
    if (data == nullptr || size == nullptr) {
      return kAudio_ParamError;
    }
    if (property == kAudioUnitProperty_MaximumFramesPerSlice &&
        *size >= sizeof(UInt32)) {
      *static_cast<UInt32*>(data) = fake.maximumFrames;
      *size = sizeof(UInt32);
      return noErr;
    }
    if (property == kAudioUnitProperty_StreamFormat &&
        *size >= sizeof(AudioStreamBasicDescription)) {
      AudioStreamBasicDescription format{};
      if (scope == kAudioUnitScope_Output) {
        format.mSampleRate = kRate;
      } else {
        format = fake.clientFormat;
      }
      *static_cast<AudioStreamBasicDescription*>(data) = format;
      *size = sizeof(AudioStreamBasicDescription);
      return noErr;
    }
    return kAudioUnitErr_InvalidProperty;
  }

  static OSStatus initialize(void* context, AudioUnit) {
    FakePlatform& fake = self(context);
    if (fake.failInitialize) {
      return kAudio_ParamError;
    }
    fake.initialized = true;
    return noErr;
  }
  static OSStatus uninitialize(void* context, AudioUnit) {
    self(context).initialized = false;
    return noErr;
  }
  static OSStatus start(void* context, AudioUnit) {
    self(context).started = true;
    return noErr;
  }
  static OSStatus stop(void* context, AudioUnit) {
    self(context).started = false;
    return noErr;
  }
  static OSStatus addListener(
      void* context, AudioUnit, AudioUnitPropertyID,
      AudioUnitPropertyListenerProc listener, void* listenerContext) {
    FakePlatform& fake = self(context);
    fake.listener = listener;
    fake.listenerContext = listenerContext;
    fake.listenerAttached = true;
    return noErr;
  }
  static OSStatus removeListener(
      void* context, AudioUnit, AudioUnitPropertyID,
      AudioUnitPropertyListenerProc listener, void* listenerContext) {
    FakePlatform& fake = self(context);
    if (listener != fake.listener || listenerContext != fake.listenerContext) {
      return kAudio_ParamError;
    }
    fake.listener = nullptr;
    fake.listenerContext = nullptr;
    fake.listenerAttached = false;
    return noErr;
  }
  static Float64 frequency(void*) { return static_cast<Float64>(kRate); }

  [[nodiscard]] NativeAudioUnitCallTable calls() noexcept {
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
            &addListener,
            &removeListener,
            &frequency};
  }

  OSStatus renderInto(std::span<float> samples, std::uint32_t frames,
                      std::uint64_t hostTicks,
                      double sampleTime = 0.0) noexcept {
    const std::size_t sampleCount =
        static_cast<std::size_t>(frames) * NativePcmRing::kChannels;
    if (callback == nullptr || frames == 0 ||
        frames > NativeAudioOutput::kMaximumFramesPerSlice ||
        samples.size() < sampleCount) {
      return kAudio_ParamError;
    }
    now.store(hostTicks, std::memory_order_release);
    AudioBufferList data{};
    data.mNumberBuffers = 1;
    data.mBuffers[0].mNumberChannels = NativePcmRing::kChannels;
    data.mBuffers[0].mDataByteSize =
        frames * NativePcmRing::kChannels * sizeof(float);
    data.mBuffers[0].mData = samples.data();
    AudioTimeStamp timestamp{};
    timestamp.mHostTime = hostTicks;
    timestamp.mSampleTime = sampleTime;
    timestamp.mRateScalar = 1.0;
    timestamp.mFlags = kAudioTimeStampHostTimeValid |
                       kAudioTimeStampSampleTimeValid |
                       kAudioTimeStampRateScalarValid;
    AudioUnitRenderActionFlags flags = 0;
    return callback(callbackContext, &flags, &timestamp, 0, frames, &data);
  }

  OSStatus render(std::uint32_t frames, std::uint64_t hostTicks,
                  double sampleTime = 0.0) noexcept {
    std::array<float, NativePcmRing::kSamplesPerSlab> samples{};
    return renderInto(samples, frames, hostTicks, sampleTime);
  }
};

NativeAudioSessionDependencies dependencies(
    const std::shared_ptr<FakePlatform>& platform,
    std::unique_ptr<NativeAudioConverterBackend> backend) {
  NativeAudioSessionDependencies result;
  result.externalLifetime = platform;
  result.hostClock = {&FakePlatform::readTicks, platform.get(), kRate};
  result.outputCalls = platform->calls();
  result.outputWake = {&platform->wakePending, &FakePlatform::signalWake,
                       platform.get()};
  result.converterBackend = std::move(backend);
  return result;
}

MediaTrackDescriptor audioTrack(double rate = kRate) {
  MediaTrackDescriptor track;
  track.id = kTrack;
  track.kind = MediaTrackKind::Audio;
  track.codec = MediaCodec::Aac;
  track.timeBase = {1, static_cast<std::int32_t>(kRate)};
  track.duration = {10, 1};
  track.codecConfigurationKind = MediaCodecConfigurationKind::None;
  track.audio = MediaAudioFormat{rate,
                                 2,
                                 kAudioFormatMPEG4AAC,
                                 0,
                                 1024,
                                 0,
                                 0,
                                 0,
                                 0,
                                 true};
  return track;
}

NativeMediaGenerationTimeline timeline(
    MediaGeneration generation, std::int64_t targetFrame,
    std::int64_t decodeFrame = 0,
    MediaSeekMode mode = MediaSeekMode::Accurate) {
  NativeMediaGenerationTimeline result;
  result.generation = generation;
  result.mode = mode;
  result.requestedTarget = {targetFrame, static_cast<std::int32_t>(kRate)};
  result.actualDecodeStart = {decodeFrame, static_cast<std::int32_t>(kRate)};
  result.presentationFloor = mode == MediaSeekMode::Accurate
                                 ? result.requestedTarget
                                 : result.actualDecodeStart;
  result.startsAtStreamOrigin = decodeFrame == 0;
  result.audioWindow.decodeStart = {
      decodeFrame, static_cast<std::int32_t>(kRate)};
  result.audioWindow.presentationStart = {
      mode == MediaSeekMode::Accurate ? targetFrame : decodeFrame,
      static_cast<std::int32_t>(kRate)};
  result.audioWindow.startsAtStreamOrigin = decodeFrame == 0;
  return result;
}

class SampleStorage final : public MediaPayloadStorage {
 public:
  SampleStorage(CMSampleBufferRef sample, std::size_t size,
                std::shared_ptr<std::atomic<int>> releases) noexcept
      : sample_(sample), size_(size), releases_(std::move(releases)) {}
  ~SampleStorage() override {
    CFRelease(sample_);
    releases_->fetch_add(1, std::memory_order_relaxed);
  }

  std::size_t byteSize() const noexcept override { return size_; }
  std::span<const std::byte> contiguousBytes() const noexcept override {
    return {};
  }
  bool copyBytes(std::size_t offset,
                 std::span<std::byte> destination) const noexcept override {
    if (offset > size_ || destination.size() > size_ - offset) {
      return false;
    }
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample_);
    return destination.empty() ||
           (block != nullptr &&
            CMBlockBufferCopyDataBytes(block, offset, destination.size(),
                                       destination.data()) == noErr);
  }

 protected:
  std::optional<NativePayloadKind> nativePayloadKind() const noexcept override {
    return NativePayloadKind::CoreMediaSampleBuffer;
  }
  const void* borrowedNativePayload() const noexcept override {
    return sample_;
  }

 private:
  CMSampleBufferRef sample_{nullptr};
  std::size_t size_{0};
  std::shared_ptr<std::atomic<int>> releases_;
};

MediaSample makeSample(const MediaTrackDescriptor& track,
                       MediaGeneration generation,
                       std::size_t packetCount,
                       std::int64_t presentationFrame,
                       const std::shared_ptr<std::atomic<int>>& releases) {
  AudioStreamBasicDescription asbd{};
  asbd.mSampleRate = track.audio->sampleRate;
  asbd.mFormatID = track.audio->formatTag;
  asbd.mFormatFlags = track.audio->formatFlags;
  asbd.mBytesPerPacket = track.audio->bytesPerPacket;
  asbd.mFramesPerPacket = track.audio->framesPerPacket;
  asbd.mBytesPerFrame = track.audio->bytesPerFrame;
  asbd.mChannelsPerFrame = track.audio->channels;
  asbd.mBitsPerChannel = track.audio->bitsPerChannel;
  CMAudioFormatDescriptionRef format = nullptr;
  expect(CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, nullptr,
                                        0, nullptr, nullptr, &format) == noErr,
         "audio format fixture is created");

  constexpr std::uint32_t packetBytes = 16;
  const std::size_t byteCount = packetCount * packetBytes;
  CMBlockBufferRef block = nullptr;
  expect(CMBlockBufferCreateWithMemoryBlock(
             kCFAllocatorDefault, nullptr, byteCount, kCFAllocatorDefault,
             nullptr, 0, byteCount, 0, &block) == noErr,
         "audio payload fixture is created");
  std::array<std::byte, 128> bytes{};
  expect(byteCount <= bytes.size(), "audio payload fixture remains bounded");
  expect(CMBlockBufferReplaceDataBytes(bytes.data(), block, 0, byteCount) ==
             noErr,
         "audio payload fixture is initialized");
  std::array<AudioStreamPacketDescription, 8> packets{};
  for (std::size_t index = 0; index < packetCount; ++index) {
    packets[index] = {static_cast<std::int64_t>(index * packetBytes), 1024,
                      packetBytes};
  }
  CMSampleBufferRef native = nullptr;
  expect(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
             kCFAllocatorDefault, block, format,
             static_cast<CMItemCount>(packetCount),
             CMTimeMake(presentationFrame, kRate), packets.data(), &native) ==
             noErr,
         "audio sample fixture is created");
  CFRelease(block);
  CFRelease(format);

  MediaSample sample;
  sample.generation = generation;
  sample.track = track.id;
  sample.kind = MediaSampleKind::EncodedAudio;
  sample.presentationTime = {presentationFrame,
                             static_cast<std::int32_t>(kRate)};
  sample.duration = {static_cast<std::int64_t>(packetCount * 1024),
                     static_cast<std::int32_t>(kRate)};
  sample.sampleCount = static_cast<std::uint32_t>(packetCount);
  sample.payload = MediaPayloadLease(
      std::make_shared<SampleStorage>(native, byteCount, releases));
  return sample;
}

void setImmediatePlayoutAttachment(MediaSample& sample,
                                   std::int64_t refreshCount) {
  const auto borrowed = sample.payload.borrowNative<
      NativePayloadKind::CoreMediaSampleBuffer>();
  expect(borrowed.has_value(), "audio attachment fixture borrows its sample");
  auto native = static_cast<CMSampleBufferRef>(
      const_cast<void*>(borrowed->opaqueAddress()));
  CFNumberRef value =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &refreshCount);
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(native, true);
  auto first = static_cast<CFMutableDictionaryRef>(
      const_cast<void*>(CFArrayGetValueAtIndex(attachments, 0)));
  CFDictionarySetValue(
      first, kCMSampleAttachmentKey_AudioIndependentSampleDecoderRefreshCount,
      value);
  CFRelease(value);
}

std::shared_ptr<const MediaSourceDescriptor> descriptor(
    const MediaTrackDescriptor& track) {
  auto value = std::make_shared<MediaSourceDescriptor>();
  value->duration = {10, 1};
  value->inventory.audio = 1;
  value->inventory.total = 1;
  value->tracks.push_back(track);
  value->selectedAudio = track.id;
  return value;
}

class FakeSource final : public MediaSource {
 public:
  FakeSource(std::shared_ptr<const MediaSourceDescriptor> descriptor,
             MediaTime actualDecodeStart,
             std::vector<MediaSourceReadResult> events)
      : descriptor_(std::move(descriptor)),
        actualDecodeStart_(actualDecodeStart),
        audioDecodeStart_(actualDecodeStart),
        events_(std::move(events)) {}

  void setAudioDecodeStart(MediaTime value) noexcept {
    audioDecodeStart_ = value;
  }

  bool armOperation(MediaGeneration generation) noexcept override {
    if (generation == 0 || armed_ != 0 || generation <= highWater_) {
      return false;
    }
    highWater_ = generation;
    armed_ = generation;
    return true;
  }
  MediaSourceOpenOutcome openLocalFile(const std::filesystem::path&,
                                       const MediaSourceOpenOptions& options,
                                       MediaGeneration generation) override {
    if (armed_ != generation) {
      return {};
    }
    armed_ = 0;
    active_ = generation;
    const MediaTime target = options.initialPosition
                                 ? options.initialPosition->target
                                 : MediaTime{0, 1};
    const MediaSeekMode mode = options.initialPosition
                                   ? options.initialPosition->mode
                                   : MediaSeekMode::Accurate;
    const auto boundary = audioFrameAtOrAfter(target, kRate);
    MediaAudioGenerationWindow audioWindow;
    audioWindow.decodeStart = audioDecodeStart_;
    audioWindow.presentationStart =
        mode == MediaSeekMode::KeyFrame ? actualDecodeStart_
                                        : boundary.value_or(MediaTime{});
    audioWindow.startsAtStreamOrigin =
        compareMediaTime(audioDecodeStart_, {0, 1}) ==
        MediaTimeOrder::Equal;
    return {MediaSourceOpenStatus::Ready, generation, actualDecodeStart_,
            descriptor_, {}, {}, audioWindow};
  }
  MediaSourceSeekOutcome seek(const MediaSourceSeekRequest& request) override {
    if (armed_ != request.generation) {
      return {};
    }
    armed_ = 0;
    active_ = request.generation;
    const auto boundary = audioFrameAtOrAfter(request.target, kRate);
    MediaAudioGenerationWindow audioWindow;
    audioWindow.decodeStart = audioDecodeStart_;
    audioWindow.presentationStart =
        request.mode == MediaSeekMode::KeyFrame
            ? actualDecodeStart_
            : boundary.value_or(MediaTime{});
    audioWindow.startsAtStreamOrigin =
        compareMediaTime(audioDecodeStart_, {0, 1}) ==
        MediaTimeOrder::Equal;
    return {true, request.generation, actualDecodeStart_, {}, {},
            audioWindow};
  }
  MediaSourceReadResult readNext(MediaGeneration generation) override {
    if (generation != active_) {
      return MediaSourceFailure{generation, "stale source read"};
    }
    if (occupySession != nullptr && occupySample && next_ == occupyAtRead) {
      occupyResult = NativeAudioSessionTestAccess::occupyConverter(
          *occupySession, std::move(*occupySample));
      occupySample.reset();
    }
    if (next_ < events_.size()) {
      return std::move(events_[next_++]);
    }
    return MediaSourceExhausted{generation};
  }
  void requestCancel(MediaGeneration) noexcept override {}
  void close() noexcept override { active_ = 0; }
  MediaSourceStats stats() const noexcept override {
    MediaSourceStats result;
    result.open = active_ != 0;
    result.generation = highWater_;
    result.operationGeneration = armed_ != 0 ? armed_ : active_;
    return result;
  }

  NativeAudioSession* occupySession{nullptr};
  std::optional<MediaSample> occupySample;
  std::size_t occupyAtRead{std::numeric_limits<std::size_t>::max()};
  NativeAudioSubmitResult occupyResult{NativeAudioSubmitResult::Failed};

 private:
  std::shared_ptr<const MediaSourceDescriptor> descriptor_;
  MediaTime actualDecodeStart_{};
  MediaTime audioDecodeStart_{};
  std::vector<MediaSourceReadResult> events_;
  std::size_t next_{0};
  MediaGeneration highWater_{0};
  MediaGeneration armed_{0};
  MediaGeneration active_{0};
};

class NullVideo final : public NativeVideoConsumer {
 public:
  NativeMediaConsumeResult configure(const MediaTrackDescriptor&,
                                     MediaGeneration,
                                     const NativeMediaGenerationTimeline&,
                                     std::string*) override {
    return NativeMediaConsumeResult::Accepted;
  }
  NativeMediaConsumeResult capacity(MediaGeneration) override {
    return NativeMediaConsumeResult::Accepted;
  }
  NativeMediaConsumeResult trySample(NativeMediaSampleDelivery&,
                                     std::string*) override {
    return NativeMediaConsumeResult::Failed;
  }
  NativeMediaConsumeResult discontinuity(const MediaDiscontinuity&,
                                          std::string*) override {
    return NativeMediaConsumeResult::Failed;
  }
  NativeMediaConsumeResult endOfStream(const MediaEndOfStream&,
                                       std::string*) override {
    return NativeMediaConsumeResult::Drained;
  }
  NativeMediaConsumerProgress drain(MediaGeneration,
                                    std::string*) override {
    return NativeMediaConsumerProgress::Done;
  }
  NativeMediaConsumerProgress cancel(MediaGeneration) noexcept override {
    return NativeMediaConsumerProgress::Done;
  }
  NativeMediaConsumerProgress flush(
      MediaGeneration, MediaGeneration,
      const NativeMediaGenerationTimeline&) noexcept override {
    return NativeMediaConsumerProgress::Done;
  }
  NativeMediaConsumerProgress retire(
      MediaGeneration, MediaGeneration) noexcept override {
    return NativeMediaConsumerProgress::Done;
  }
  NativeMediaConsumerProgress close() noexcept override {
    return NativeMediaConsumerProgress::Done;
  }
};

MediaSourceOpenOptions audioOptions(std::int64_t targetFrame) {
  MediaSourceOpenOptions options;
  options.selection.requireVideo = false;
  options.selection.requireAudio = true;
  options.initialPosition = MediaSourceInitialPosition{
      {targetFrame, static_cast<std::int32_t>(kRate)},
      MediaSeekMode::Accurate};
  return options;
}

[[nodiscard]] bool sameControlFacts(const NativeAudioSessionFacts& lhs,
                                    const NativeAudioSessionFacts& rhs)
    noexcept {
  return lhs.requestedGain == rhs.requestedGain &&
         lhs.appliedGain == rhs.appliedGain &&
         lhs.requestedMuted == rhs.requestedMuted &&
         lhs.appliedMuted == rhs.appliedMuted &&
         lhs.controlRevision == rhs.controlRevision &&
         lhs.appliedControlRevision == rhs.appliedControlRevision;
}

void expectTerminalControlsInert(NativeAudioSession& session,
                                 const char* message) {
  const NativeAudioSessionFacts before = session.facts();
  allocations.store(0, std::memory_order_relaxed);
  trackAllocations.store(true, std::memory_order_release);
  const NativeAudioSessionProgress gain = session.setGain(0.875F);
  const NativeAudioSessionProgress mute =
      session.setMuted(!before.requestedMuted);
  trackAllocations.store(false, std::memory_order_release);
  const NativeAudioSessionFacts after = session.facts();
  expect(gain == NativeAudioSessionProgress::Invalid &&
             mute == NativeAudioSessionProgress::Invalid &&
             allocations.load(std::memory_order_relaxed) == 0 &&
             sameControlFacts(before, after),
         message);
}

void testCachedGainMuteControls() {
  auto platform = std::make_shared<FakePlatform>();
  auto backendState = std::make_shared<BackendState>();
  backendState->add({1, 1024, true, true, false, false});
  const MediaTrackDescriptor track = audioTrack();
  auto releases = std::make_shared<std::atomic<int>>(0);
  std::vector<MediaSourceReadResult> events;
  events.emplace_back(makeSample(track, 1, 1, 0, releases));
  auto session = NativeAudioSession::create(
      1, dependencies(platform,
                      std::make_unique<FakeBackend>(backendState)));
  expect(session != nullptr &&
             session->setGain(0.25F) == NativeAudioSessionProgress::Done &&
             session->setMuted(true) == NativeAudioSessionProgress::Done,
         "Fresh audio controls accept a cached gain and independent mute");
  const NativeAudioSessionFacts cached = session->facts();
  expect(cached.requestedGain == 0.25F && cached.appliedGain == 0.25F &&
             cached.requestedMuted && cached.appliedMuted &&
             cached.controlRevision == 2 &&
             cached.appliedControlRevision == 2,
         "Fresh controls publish one exact normalized pair per request");

  NativeAudioSession* audio = session.get();
  NativeMediaDispatcher dispatcher(
      std::make_unique<FakeSource>(
          descriptor(track), MediaTime{0, static_cast<std::int32_t>(kRate)},
          std::move(events)),
      std::make_unique<NullVideo>(), std::move(session));
  expect(dispatcher.openLocalFile("/tmp/audio-controls.mov", audioOptions(0),
                                  1)
                 .status == NativeMediaDispatcherOpenStatus::Ready,
         "cached-control fixture configures");
  const NativeAudioSessionFacts configured = audio->facts();
  expect(sameControlFacts(cached, configured) &&
             configured.controlRevision == 2,
         "configure republishes cached controls without fabricating a request");
  expect(dispatcher.step().action == NativeMediaDispatcherAction::AudioSample &&
             audio->setPaused(false) == NativeAudioSessionProgress::Done &&
             audio->start() == NativeAudioSessionProgress::Done,
         "cached-control fixture starts from bounded PCM");

  std::array<float, 256> mutedSamples{};
  expect(platform->renderInto(mutedSamples, 128, 10'000, 0.0) == noErr &&
             std::all_of(mutedSamples.begin(), mutedSamples.end(),
                         [](float value) { return value == 0.0F; }),
         "preconfigure mute remains active in the first render callback");
  expect(audio->setMuted(false) == NativeAudioSessionProgress::Done,
         "unmute leaves the cached gain intact");
  std::array<float, 256> unmutedSamples{};
  expect(platform->renderInto(unmutedSamples, 128, 10'128, 128.0) == noErr,
         "unmuted callback consumes the next bounded PCM interval");
  constexpr float expectedLastLeft = 15.0F / 124.0F;
  expect(std::fabs(unmutedSamples[254] - expectedLastLeft) < 0.000001F,
         "unmute ramps to the preconfigure quarter-gain target");
  const NativeAudioSessionFacts unmuted = audio->facts();
  expect(unmuted.requestedGain == 0.25F &&
             unmuted.appliedGain == 0.25F && !unmuted.requestedMuted &&
             !unmuted.appliedMuted && unmuted.controlRevision == 3 &&
             unmuted.appliedControlRevision == 3,
         "mute changes never overwrite gain or lose callback publication");

  allocations.store(0, std::memory_order_relaxed);
  trackAllocations.store(true, std::memory_order_release);
  bool rapidAccepted =
      audio->setGain(-1.0F) == NativeAudioSessionProgress::Done;
  const float clampedLow = audio->facts().requestedGain;
  rapidAccepted = rapidAccepted &&
                  audio->setGain(0.2F) == NativeAudioSessionProgress::Done;
  rapidAccepted = rapidAccepted &&
                  audio->setGain(2.0F) == NativeAudioSessionProgress::Done;
  const float clampedHigh = audio->facts().requestedGain;
  rapidAccepted =
      rapidAccepted &&
      audio->setGain(std::numeric_limits<float>::quiet_NaN()) ==
          NativeAudioSessionProgress::Done;
  const float failSafeNonFinite = audio->facts().requestedGain;
  rapidAccepted = rapidAccepted &&
                  audio->setGain(0.75F) == NativeAudioSessionProgress::Done;
  rapidAccepted = rapidAccepted &&
                  audio->setMuted(true) == NativeAudioSessionProgress::Done;
  rapidAccepted = rapidAccepted &&
                  audio->setMuted(false) == NativeAudioSessionProgress::Done;
  trackAllocations.store(false, std::memory_order_release);
  const NativeAudioSessionFacts rapid = audio->facts();
  expect(rapidAccepted && allocations.load(std::memory_order_relaxed) == 0 &&
             clampedLow == 0.0F && clampedHigh == 1.0F &&
             failSafeNonFinite == 0.0F &&
             rapid.requestedGain == 0.75F &&
             rapid.appliedGain == 0.75F && !rapid.requestedMuted &&
             !rapid.appliedMuted && rapid.controlRevision == 10 &&
             rapid.appliedControlRevision == 10,
         "rapid normalized controls are allocation-free and last-write wins");

  expect(dispatcher.close(1).status ==
             NativeMediaDispatcherLifecycleStatus::Done,
         "cached-control fixture retires exactly");
  expectTerminalControlsInert(
      *audio, "Closed retirement rejects controls without changing facts");
}

void testTerminalGainMuteRejection() {
  {
    auto platform = std::make_shared<FakePlatform>();
    auto backendState = std::make_shared<BackendState>();
    auto session = NativeAudioSession::create(
        1, dependencies(platform,
                        std::make_unique<FakeBackend>(backendState)));
    expect(session->setGain(0.4F) == NativeAudioSessionProgress::Done &&
               session->configure(audioTrack(32'000.0), 1, timeline(1, 0),
                                  nullptr) ==
                   NativeMediaConsumeResult::Unsupported,
           "unsupported control fixture reaches its pre-resource terminal");
    expectTerminalControlsInert(
        *session, "Unsupported session rejects controls without mutation");
    expect(session->close() == NativeMediaConsumerProgress::Done,
           "unsupported control fixture closes");
  }

  {
    auto platform = std::make_shared<FakePlatform>();
    auto backendState = std::make_shared<BackendState>();
    backendState->configureSucceeds = false;
    auto session = NativeAudioSession::create(
        2, dependencies(platform,
                        std::make_unique<FakeBackend>(backendState)));
    expect(session->setMuted(true) == NativeAudioSessionProgress::Done &&
               session->configure(audioTrack(), 2, timeline(2, 0), nullptr) ==
                   NativeMediaConsumeResult::Failed,
           "failed control fixture enters fail-closed state");
    expectTerminalControlsInert(
        *session, "Failed session rejects controls without mutation");
    expect(session->close() == NativeMediaConsumerProgress::Done,
           "failed control fixture closes");
  }

  {
    auto platform = std::make_shared<FakePlatform>();
    auto backendState = std::make_shared<BackendState>();
    auto session = NativeAudioSession::create(
        3, dependencies(platform,
                        std::make_unique<FakeBackend>(backendState)));
    expect(session->configure(audioTrack(), 3, timeline(3, 0), nullptr) ==
                   NativeMediaConsumeResult::Accepted &&
               session->setGain(0.3F) == NativeAudioSessionProgress::Done &&
               session->cancel(3) == NativeMediaConsumerProgress::Done &&
               session->facts().state == NativeAudioSessionState::Cancelled,
           "cancelled control fixture reaches an exact terminal state");
    expectTerminalControlsInert(
        *session, "Cancelled session rejects controls without mutation");
    expect(session->close() == NativeMediaConsumerProgress::Done,
           "cancelled control fixture closes");
  }

  {
    auto platform = std::make_shared<FakePlatform>();
    auto backendState = std::make_shared<BackendState>();
    auto session = NativeAudioSession::create(
        4, dependencies(platform,
                        std::make_unique<FakeBackend>(backendState)));
    expect(session->configure(audioTrack(), 4, timeline(4, 0), nullptr) ==
               NativeMediaConsumeResult::Accepted,
           "Closing control fixture configures");
    NativeAudioSessionTestAccess::forceCloseQuiescing(*session, true);
    expect(session->close() == NativeMediaConsumerProgress::Quiescing &&
               session->facts().state == NativeAudioSessionState::Closing,
           "Closing control fixture exposes an in-progress terminal state");
    expectTerminalControlsInert(
        *session, "Closing session rejects controls without mutation");
    NativeAudioSessionTestAccess::forceCloseQuiescing(*session, false);
    expect(session->close() == NativeMediaConsumerProgress::Done,
           "Closing control fixture finishes");
    expectTerminalControlsInert(
        *session, "emergency-Closed session keeps controls inert");
  }
}

void testPreflightAndPostResourceFailure() {
  {
    auto platform = std::make_shared<FakePlatform>();
    auto backendState = std::make_shared<BackendState>();
    auto session = NativeAudioSession::create(
        1, dependencies(platform,
                        std::make_unique<FakeBackend>(backendState)));
    NativeMediaGenerationTimeline missingWindow = timeline(1, 0);
    missingWindow.audioWindow = {};
    expect(session->configure(audioTrack(), 1, missingWindow, nullptr) ==
               NativeMediaConsumeResult::Unsupported &&
               !session->facts().resourceEntered &&
               backendState->configureCalls == 0,
           "missing source-proved audio window is pre-resource Unsupported");
    expect(session->close() == NativeMediaConsumerProgress::Done,
           "missing-window session closes exactly");
  }

  {
    auto platform = std::make_shared<FakePlatform>();
    auto backendState = std::make_shared<BackendState>();
    auto session = NativeAudioSession::create(
        1, dependencies(platform,
                        std::make_unique<FakeBackend>(backendState)));
    expect(session != nullptr, "unsupported preflight session is created");
    MediaTrackDescriptor unsupported = audioTrack(32'000.0);
    expect(session->configure(unsupported, 1, timeline(1, 0), nullptr) ==
               NativeMediaConsumeResult::Unsupported,
           "unsupported rate is rejected before resource entry");
    expect(!session->facts().resourceEntered,
           "unsupported preflight creates no native resource");
    expect(backendState->configureCalls == 0,
           "unsupported preflight never configures decoder backend");
    expect(session->close() == NativeMediaConsumerProgress::Done,
           "unsupported session closes exactly");
  }

  {
    auto platform = std::make_shared<FakePlatform>();
    auto backendState = std::make_shared<BackendState>();
    auto session = NativeAudioSession::create(
        1, dependencies(platform,
                        std::make_unique<FakeBackend>(backendState)));
    NativeMediaGenerationTimeline fractional = timeline(1, 0);
    fractional.requestedTarget = {1, 7};
    fractional.presentationFloor = {1, 7};
    fractional.audioWindow.presentationStart = {1143, 8000};
    expect(session->configure(audioTrack(), 1, fractional, nullptr) ==
               NativeMediaConsumeResult::Accepted &&
               session->facts().resourceEntered &&
               session->facts().presentationFloorFrame == 6858,
           "fractional visual floor admits the first source PCM frame at "
           "ceil(T*R)");
    const auto exactTarget = mediaTimeSeconds(fractional.presentationFloor);
    const NativeMediaClockSnapshot fractionalClock = session->visibleClock();
    expect(exactTarget && fractionalClock.valid &&
               !fractionalClock.running &&
               fractionalClock.mediaSeconds == *exactTarget,
           "fractional seek keeps the paused Commit clock at exact visual T");
    expect(session->close() == NativeMediaConsumerProgress::Done,
           "fractional-floor session closes exactly");
  }

  {
    auto platform = std::make_shared<FakePlatform>();
    auto backendState = std::make_shared<BackendState>();
    auto session = NativeAudioSession::create(
        1, dependencies(platform,
                        std::make_unique<FakeBackend>(backendState)));
    expect(session->configure(
               audioTrack(), 1,
               timeline(1, 1024, 1024, MediaSeekMode::KeyFrame), nullptr) ==
               NativeMediaConsumeResult::Accepted,
           "keyframe audio timeline anchors at its exact decode start");
    const NativeAudioSessionFacts keyframe = session->facts();
    expect(keyframe.presentationFloorFrame == 1024,
           "keyframe floor is the canonical decode-start frame");
    expect(session->close() == NativeMediaConsumerProgress::Done,
           "keyframe session closes exactly");
  }

  {
    auto platform = std::make_shared<FakePlatform>();
    auto backendState = std::make_shared<BackendState>();
    backendState->configureSucceeds = false;
    auto session = NativeAudioSession::create(
        1, dependencies(platform,
                        std::make_unique<FakeBackend>(backendState)));
    expect(session->configure(audioTrack(), 1, timeline(1, 0), nullptr) ==
               NativeMediaConsumeResult::Failed,
           "decoder setup failure is post-resource Failed");
    const NativeAudioSessionFacts failed = session->facts();
    expect(failed.resourceEntered &&
               failed.state == NativeAudioSessionState::Failed,
           "post-resource failure remains terminal-teardown-only");
    expect(session->start() == NativeAudioSessionProgress::Invalid,
           "failed session cannot restart");
    expect(session->close() == NativeMediaConsumerProgress::Done,
           "failed setup closes its retained graph");
  }
}

void testAccurateTrimClockPauseAndEof() {
  auto platform = std::make_shared<FakePlatform>();
  auto backendState = std::make_shared<BackendState>();
  backendState->add({3, 3072, true, true, false, false});
  backendState->add({0, 0, false, false, true, false});
  auto session = NativeAudioSession::create(
      1, dependencies(platform,
                      std::make_unique<FakeBackend>(backendState)));
  NativeAudioSession* audio = session.get();
  const MediaTrackDescriptor track = audioTrack();
  auto releases = std::make_shared<std::atomic<int>>(0);
  std::vector<MediaSourceReadResult> events;
  events.emplace_back(makeSample(track, 1, 3, 0, releases));
  events.emplace_back(MediaEndOfStream{1, track.id});
  auto source = std::make_unique<FakeSource>(
      descriptor(track), MediaTime{0, static_cast<std::int32_t>(kRate)},
      std::move(events));
  NativeMediaDispatcher dispatcher(std::move(source),
                                   std::make_unique<NullVideo>(),
                                   std::move(session));
  const NativeMediaDispatcherOpenOutcome opened = dispatcher.openLocalFile(
      "/tmp/native-audio-session.mov", audioOptions(2048), 1);
  expect(opened.status == NativeMediaDispatcherOpenStatus::Ready,
         "dispatcher configures native audio session");
  allocations.store(0, std::memory_order_relaxed);
  trackAllocations.store(true, std::memory_order_release);
  const NativeMediaDispatcherStep sampleStep = dispatcher.step();
  trackAllocations.store(false, std::memory_order_release);
  expect(sampleStep.action == NativeMediaDispatcherAction::AudioSample,
         "transactional sample delivery is accepted");
  expect(allocations.load(std::memory_order_relaxed) == 0,
         "transactional prepare, commit, and actual decoder pump allocate "
         "nothing after configuration");

  NativeAudioSessionFacts facts = audio->facts();
  expect(facts.converter.discardedTrimFrames == 2048 &&
             facts.converter.publishedPcmFrames == 1024 &&
             facts.converter.firstPublishedFrame == 2048,
         "accurate seek decodes preroll and publishes from exact floor");
  expect(releases->load(std::memory_order_relaxed) == 1,
         "converter releases the exact delivered sample lease");
  expect(facts.queuedSlabs <= NativePcmRing::kSlabCount,
         "prebuffer is bounded by the fixed ring");

  allocations.store(0, std::memory_order_relaxed);
  trackAllocations.store(true, std::memory_order_release);
  const NativeMediaConsumeResult needsInput = audio->capacity(1);
  trackAllocations.store(false, std::memory_order_release);
  expect(needsInput == NativeMediaConsumeResult::Accepted &&
             allocations.load(std::memory_order_relaxed) == 0,
         "owner-thread converter pump and capacity check allocate nothing");

  expect(audio->setPaused(false) == NativeAudioSessionProgress::Done,
         "resume request is accepted while output is stopped");
  expect(audio->start() == NativeAudioSessionProgress::Done,
         "prebuffered output starts");
  const NativeMediaClockSnapshot before = audio->visibleClock();
  expect(before.valid && !before.running &&
             before.mediaSeconds == 2048.0 / kRate,
         "visible clock remains paused until first callback commits");

  allocations.store(0, std::memory_order_relaxed);
  trackAllocations.store(true, std::memory_order_release);
  expect(platform->render(256, 10'000, 0.0) == noErr,
         "first output callback consumes PCM");
  expect(audio->setPaused(true) == NativeAudioSessionProgress::Done,
         "pause request is accepted");
  expect(platform->render(128, 10'256, 256.0) == noErr,
         "callback publishes exact pause boundary");
  const NativeMediaClockSnapshot paused = audio->visibleClock();
  expect(paused.valid && !paused.running,
         "paused callback freezes authoritative clock");
  expect(audio->setPaused(false) == NativeAudioSessionProgress::Done,
         "resume request does not speculate clock motion");
  expect(!audio->visibleClock().running,
         "clock stays paused until resumed callback commits");
  expect(platform->render(128, 10'384, 384.0) == noErr,
         "resumed callback consumes retained PCM");
  trackAllocations.store(false, std::memory_order_release);
  expect(allocations.load(std::memory_order_relaxed) == 0,
         "steady callback, pause, resume, and clock reads allocate nothing");
  expect(audio->visibleClock().running,
         "first resumed callback restarts the authoritative clock");

  expect(audio->stop() == NativeAudioSessionProgress::Done,
         "output stop settles callback-local and authoritative clocks");
  expect(audio->setPaused(false) == NativeAudioSessionProgress::Done &&
             audio->start() == NativeAudioSessionProgress::Done,
         "stopped output restarts with its retained PCM");
  expect(platform->render(640, 10'512, 512.0) == noErr &&
             audio->visibleClock().running,
         "first callback after stop establishes a fresh clock run");

  expect(dispatcher.step().action ==
             NativeMediaDispatcherAction::AudioEndOfStream,
         "compressed EOF drains decoder and publishes terminal frame");
  facts = audio->facts();
  expect(facts.terminalPublished && !facts.terminalObserved &&
             facts.converter.publishedPcmFrames == 1024,
         "EOF terminal uses exact generation-local published frame count");
  expect(platform->render(64, 11'152, 1'152.0) == noErr,
         "callback observes terminal boundary without consuming silence");
  expect(audio->facts().terminalObserved,
         "terminal completion requires durable render observation");
  static_cast<void>(dispatcher.step());
  expect(dispatcher.step().action == NativeMediaDispatcherAction::Exhausted,
         "dispatcher exhausts only after audio render observation");
  expect(dispatcher.close(1).status ==
             NativeMediaDispatcherLifecycleStatus::Done,
         "dispatcher closes native audio graph exactly");
}

void testSeekStopCancelAndFailure() {
  auto platform = std::make_shared<FakePlatform>();
  auto backendState = std::make_shared<BackendState>();
  auto session = NativeAudioSession::create(
      1, dependencies(platform,
                      std::make_unique<FakeBackend>(backendState)));
  expect(session->configure(audioTrack(), 1, timeline(1, 0), nullptr) ==
             NativeMediaConsumeResult::Accepted,
         "direct session configuration succeeds");
  expect(session->stop() == NativeAudioSessionProgress::Done,
         "stopped output is idempotently quiescent");
  const NativeMediaGenerationTimeline next = timeline(2, 4096, 0);
  expect(session->flush(1, 2, next) == NativeMediaConsumerProgress::Done,
         "seek flush installs exact next generation while paused");
  const NativeAudioSessionFacts sought = session->facts();
  expect(sought.generation == 2 && sought.presentationFloorFrame == 4096 &&
             sought.requestedPaused && !sought.output.started,
         "seek activates new output generation without starting it");
  expect(session->flush(1, 2, next) == NativeMediaConsumerProgress::Done,
         "completed exact flush is idempotent");
  expect(session->capacity(1) == NativeMediaConsumeResult::StaleGeneration,
         "retired generation cannot regain capacity");
  expect(session->setPaused(false) == NativeAudioSessionProgress::Done &&
             session->start() == NativeAudioSessionProgress::WaitingForData,
         "unpaused output requires bounded prebuffer before start");
  expect(session->cancel(1) ==
             NativeMediaConsumerProgress::StaleGeneration,
         "stale cancellation is inert");
  expect(session->cancel(2) == NativeMediaConsumerProgress::Done,
         "active generation cancellation quiesces and resets decoder");
  expect(session->cancel(2) == NativeMediaConsumerProgress::Done,
         "exact cancellation completion is idempotent");
  expect(session->close() == NativeMediaConsumerProgress::Done,
         "cancelled session closes");

  auto failurePlatform = std::make_shared<FakePlatform>();
  auto failureBackend = std::make_shared<BackendState>();
  auto failed = NativeAudioSession::create(
      3, dependencies(failurePlatform,
                      std::make_unique<FakeBackend>(failureBackend)));
  expect(failed->configure(audioTrack(), 3, timeline(3, 0), nullptr) ==
             NativeMediaConsumeResult::Accepted,
         "failure fixture configures");
  expect(failed->discontinuity({3, kTrack, {1, 1}}, nullptr) ==
             NativeMediaConsumeResult::Failed,
         "unmodeled discontinuity fails closed");
  expect(failed->facts().state == NativeAudioSessionState::Failed,
         "post-resource discontinuity requires close");
  expect(failed->close() == NativeMediaConsumerProgress::Done,
         "failed discontinuity graph closes");
}

void testBackpressurePreservesDispatcherDelivery() {
  auto platform = std::make_shared<FakePlatform>();
  auto backendState = std::make_shared<BackendState>();
  backendState->add({1, 1024, true, true, false, false});
  backendState->add({1, 1024, true, true, false, false});
  const MediaTrackDescriptor track = audioTrack();
  auto sourceRelease = std::make_shared<std::atomic<int>>(0);
  auto blockerRelease = std::make_shared<std::atomic<int>>(0);
  std::vector<MediaSourceReadResult> events;
  events.emplace_back(makeSample(track, 1, 1, 1024, sourceRelease));
  auto session = NativeAudioSession::create(
      1, dependencies(platform,
                      std::make_unique<FakeBackend>(backendState)));
  NativeAudioSession* audio = session.get();
  auto source = std::make_unique<FakeSource>(
      descriptor(track), MediaTime{0, static_cast<std::int32_t>(kRate)},
      std::move(events));
  FakeSource* sourceFacts = source.get();
  sourceFacts->setAudioDecodeStart(
      {1024, static_cast<std::int32_t>(kRate)});
  sourceFacts->occupySession = audio;
  sourceFacts->occupyAtRead = 0;
  auto blocker = makeSample(track, 1, 1, 0, blockerRelease);
  setImmediatePlayoutAttachment(blocker, 0);
  sourceFacts->occupySample = std::move(blocker);
  NativeMediaDispatcher dispatcher(std::move(source),
                                   std::make_unique<NullVideo>(),
                                   std::move(session));
  expect(dispatcher.openLocalFile("/tmp/backpressure.mov",
                                  audioOptions(2048), 1)
                 .status == NativeMediaDispatcherOpenStatus::Ready,
         "backpressure dispatcher configures");
  const NativeMediaDispatcherStep firstBackpressureStep = dispatcher.step();
  expect(firstBackpressureStep.action == NativeMediaDispatcherAction::BlockedAudio,
         "source sample remains pending behind occupied converter ingress");
  const NativeMediaDispatcherStats blocked = dispatcher.stats();
  expect(blocked.pending == NativeMediaPendingKind::AudioSample &&
             blocked.audioSamples == 0 && sourceRelease->load() == 0 &&
             sourceFacts->occupyResult == NativeAudioSubmitResult::Accepted,
         "Backpressure leaves the exact-D delivery and first-AU proof "
         "untouched");
  expect(dispatcher.step().action ==
             NativeMediaDispatcherAction::AudioProgress &&
             blockerRelease->load() == 1 && sourceRelease->load() == 0,
         "bounded pump releases only the independently occupied ingress");
  expect(dispatcher.step().action == NativeMediaDispatcherAction::AudioSample,
         "same pending source sample with exact D succeeds on retry");
  expect(dispatcher.stats().audioSamples == 1 && sourceRelease->load() == 1,
         "retried delivery transfers and releases exactly once");
  expect(dispatcher.close(1).status ==
             NativeMediaDispatcherLifecycleStatus::Done,
         "backpressure fixture closes");
}

void testFirstAudioSampleBindsSourceDecodeStart() {
  const auto runMismatch = [](
      std::int64_t targetFrame, std::int64_t declaredDecodeFrame,
      std::int64_t actualSampleFrame, std::uint32_t prerollSeconds,
      const char* openMessage, const char* rejectMessage) {
    auto platform = std::make_shared<FakePlatform>();
    auto backendState = std::make_shared<BackendState>();
    backendState->add({1, 1024, true, true, false, false});
    const MediaTrackDescriptor track = audioTrack();
    auto releases = std::make_shared<std::atomic<int>>(0);
    std::vector<MediaSourceReadResult> events;
    events.emplace_back(
        makeSample(track, 1, 1, actualSampleFrame, releases));
    auto session = NativeAudioSession::create(
        1, dependencies(platform,
                        std::make_unique<FakeBackend>(backendState)));
    NativeAudioSession* audio = session.get();
    auto source = std::make_unique<FakeSource>(
        descriptor(track), MediaTime{0, static_cast<std::int32_t>(kRate)},
        std::move(events));
    source->setAudioDecodeStart(
        {declaredDecodeFrame, static_cast<std::int32_t>(kRate)});
    NativeMediaDispatcher dispatcher(std::move(source),
                                     std::make_unique<NullVideo>(),
                                     std::move(session));
    MediaSourceOpenOptions options = audioOptions(targetFrame);
    options.limits.maximumAudioSeekPrerollSeconds = prerollSeconds;
    expect(dispatcher.openLocalFile("/tmp/forged-audio-d.mov", options, 1)
                   .status == NativeMediaDispatcherOpenStatus::Ready,
           openMessage);
    const NativeMediaDispatcherStep rejected = dispatcher.step();
    expect(rejected.action == NativeMediaDispatcherAction::Failed &&
               audio->facts().state == NativeAudioSessionState::Failed &&
               audio->facts().converter.acceptedSamples == 0 &&
               releases->load(std::memory_order_relaxed) == 1,
           rejectMessage);
    static_cast<void>(dispatcher.close(1));
  };

  runMismatch(
      0, 0, 1024, 1,
      "declared-origin D mismatch fixture passes source-window admission",
      "declared D=0 cannot accept a first compressed audio AU whose PTS is "
      "later");
  runMismatch(
      96'000, 95'999, 0, 1,
      "near-A declared D stays within the configured one-second source cap",
      "an actual first AU earlier than declared D cannot hide true preroll "
      "beyond the configured cap");
}

void testCloseSupersedesStagedFlush() {
  const NativeMediaGenerationTimeline next = timeline(2, 4096, 0);
  NativeAudioGenerationTimeline converterNext;
  converterNext.presentationFloor = {4096,
                                     static_cast<std::int32_t>(kRate)};
  converterNext.trimBeforeFloor = true;
  converterNext.startsAtStreamOrigin = true;
  const auto makeStaged = [&]() {
    auto platform = std::make_shared<FakePlatform>();
    auto backendState = std::make_shared<BackendState>();
    auto session = NativeAudioSession::create(
        1, dependencies(platform,
                        std::make_unique<FakeBackend>(backendState)));
    expect(session != nullptr &&
               session->configure(audioTrack(), 1, timeline(1, 0), nullptr) ==
                   NativeMediaConsumeResult::Accepted,
           "lifecycle precedence fixture configures");
    NativeAudioSessionTestAccess::stageFlushAfterStop(
        *session, 1, 2, next, converterNext,
        {4096, static_cast<std::int32_t>(kRate)}, 4096);
    return session;
  };

  auto closeSession = makeStaged();
  expect(closeSession->close() == NativeMediaConsumerProgress::Done,
         "close durably supersedes a staged flush");
  expect(closeSession->flush(1, 2, next) ==
                 NativeMediaConsumerProgress::Failed &&
             closeSession->facts().state == NativeAudioSessionState::Closed &&
             closeSession->facts().generation == 1 &&
             !closeSession->facts().retireDone &&
             closeSession->facts().retiredGeneration == 0 &&
             closeSession->facts().invalidationGeneration == 0,
         "emergency close cannot reactivate flush or mint retirement proof");

  auto cancelSession = makeStaged();
  expect(cancelSession->cancel(2) ==
                 NativeMediaConsumerProgress::StaleGeneration &&
             cancelSession->facts().state ==
                 NativeAudioSessionState::Flushing,
         "stale cancel cannot supersede a staged flush");
  NativeAudioSessionTestAccess::forceCloseQuiescing(*cancelSession, true);
  expect(cancelSession->cancel(1) ==
             NativeMediaConsumerProgress::Quiescing &&
             cancelSession->cancel(1) ==
                 NativeMediaConsumerProgress::Quiescing,
         "exact superseding cancel retry remains Quiescing");
  NativeAudioSessionTestAccess::forceCloseQuiescing(*cancelSession, false);
  expect(cancelSession->cancel(1) == NativeMediaConsumerProgress::Done &&
             cancelSession->facts().state ==
                 NativeAudioSessionState::Closed &&
             cancelSession->flush(1, 2, next) ==
                 NativeMediaConsumerProgress::Failed,
         "cancel fail-closes and permanently supersedes a split flush");
  expect(cancelSession->cancel(1) == NativeMediaConsumerProgress::Done &&
             cancelSession->cancel(2) ==
                 NativeMediaConsumerProgress::StaleGeneration,
         "exact superseding cancel retry stays Done after close");

  auto stopSession = makeStaged();
  NativeAudioSessionTestAccess::forceCloseQuiescing(*stopSession, true);
  expect(stopSession->stop() == NativeAudioSessionProgress::Quiescing &&
             stopSession->stop() == NativeAudioSessionProgress::Quiescing,
         "exact superseding stop retry remains Quiescing");
  NativeAudioSessionTestAccess::forceCloseQuiescing(*stopSession, false);
  expect(stopSession->stop() == NativeAudioSessionProgress::Done &&
             stopSession->facts().state == NativeAudioSessionState::Closed &&
             stopSession->flush(1, 2, next) ==
                 NativeMediaConsumerProgress::Failed,
         "stop fail-closes and permanently supersedes a split flush");
  expect(stopSession->stop() == NativeAudioSessionProgress::Done,
         "exact superseding stop retry stays Done after close");
}

void expectExactRetirement(const NativeAudioSession& session,
                           MediaGeneration retired,
                           MediaGeneration invalidation,
                           bool clockWasActivated,
                           const char* message) {
  const NativeAudioSessionFacts facts = session.facts();
  const NativeMediaClockSnapshot clock = session.visibleClock();
  expect(facts.state == NativeAudioSessionState::Closed &&
             facts.generation == invalidation && facts.retireDone &&
             facts.highestExposedGeneration == retired &&
             facts.retiredGeneration == retired &&
             facts.invalidationGeneration == invalidation &&
             facts.ringGeneration == invalidation &&
             facts.queuedSlabs == 0 && !facts.configured &&
             !facts.converter.configured &&
             !facts.converter.samplePrepared &&
             !facts.converter.sampleRetained &&
             facts.output.state == NativeAudioOutputState::Closed &&
             !facts.output.configured && !facts.output.started &&
             facts.output.stopped && facts.output.callbackQuiescent &&
             (!clockWasActivated ||
              (facts.clockGeneration == invalidation &&
               !facts.clockValid && clock.publicationCurrent &&
               clock.generation == invalidation && !clock.valid &&
               !clock.running)),
         message);
}

void testExactTerminalRetirement() {
  {
    auto platform = std::make_shared<FakePlatform>();
    auto backendState = std::make_shared<BackendState>();
    auto session = NativeAudioSession::create(
        1, dependencies(platform,
                        std::make_unique<FakeBackend>(backendState)));
    expect(session->configure(audioTrack(32'000.0), 1, timeline(1, 0),
                              nullptr) ==
                   NativeMediaConsumeResult::Unsupported &&
               !session->facts().resourceEntered &&
               session->facts().highestExposedGeneration == 1,
           "preflight rejection still records the Router-exposed generation");
    expect(session->retire(1, 8) == NativeMediaConsumerProgress::Done,
           "resource-free configured rejection retires with its exposed base");
    expectExactRetirement(*session, 1, 8, false,
                          "resource-free retirement advances the internal ring exactly");
  }

  {
    auto platform = std::make_shared<FakePlatform>();
    auto backendState = std::make_shared<BackendState>();
    auto session = NativeAudioSession::create(
        5, dependencies(platform,
                        std::make_unique<FakeBackend>(backendState)));
    expect(session->retire(5, 20) ==
                   NativeMediaConsumerProgress::StaleGeneration &&
               session->facts().state == NativeAudioSessionState::Fresh &&
               session->facts().retiredGeneration == 0,
           "never-configured retirement rejects a fabricated retired generation");
    expect(session->retire(0, 5) == NativeMediaConsumerProgress::Failed &&
               session->facts().state == NativeAudioSessionState::Fresh,
           "invalidation must exceed constructor-internal generations");
    expect(session->retire(0, 20) == NativeMediaConsumerProgress::Done,
           "never-configured port retires with the exact zero base");
    expectExactRetirement(*session, 0, 20, false,
                          "never-configured retirement advances and empties the ring");
    expect(session->retire(0, 20) == NativeMediaConsumerProgress::Done &&
               session->retire(0, 21) ==
                   NativeMediaConsumerProgress::StaleGeneration,
           "terminal pair is exact and retryable after Done");
  }

  {
    auto platform = std::make_shared<FakePlatform>();
    auto backendState = std::make_shared<BackendState>();
    auto session = NativeAudioSession::create(
        10, dependencies(platform,
                         std::make_unique<FakeBackend>(backendState)));
    expect(session->configure(audioTrack(), 10, timeline(10, 0), nullptr) ==
               NativeMediaConsumeResult::Accepted,
           "configured retirement fixture arms resources");
    expect(session->retire(9, 100) ==
                   NativeMediaConsumerProgress::StaleGeneration &&
               session->facts().state == NativeAudioSessionState::Ready &&
               session->facts().retiredGeneration == 0,
           "wrong configured retired generation is inert");
    expect(session->retire(10, 10) == NativeMediaConsumerProgress::Failed &&
               session->facts().state == NativeAudioSessionState::Ready,
           "non-advancing invalidation is rejected before latching");
    expect(session->retire(10, 100) == NativeMediaConsumerProgress::Done,
           "configured graph reaches exact terminal retirement");
    expectExactRetirement(*session, 10, 100, true,
                          "retirement exposes exact invalid clock and closed graph proof");
    expect(session->close() == NativeMediaConsumerProgress::Done &&
               session->retire(10, 100) == NativeMediaConsumerProgress::Done,
           "emergency close after proof does not erase exact retirement");
  }

  {
    auto platform = std::make_shared<FakePlatform>();
    auto backendState = std::make_shared<BackendState>();
    backendState->configureSucceeds = false;
    auto session = NativeAudioSession::create(
        3, dependencies(platform,
                        std::make_unique<FakeBackend>(backendState)));
    expect(session->configure(audioTrack(), 3, timeline(3, 0), nullptr) ==
               NativeMediaConsumeResult::Failed,
           "partial-arm retirement fixture fails after resource exposure");
    expect(session->retire(3, 30) == NativeMediaConsumerProgress::Done,
           "failed partial-arm graph remains exactly retireable");
    expectExactRetirement(*session, 3, 30, false,
                          "failed partial-arm retirement releases every lease and callback");
  }

  {
    auto platform = std::make_shared<FakePlatform>();
    platform->failInitialize = true;
    auto backendState = std::make_shared<BackendState>();
    auto session = NativeAudioSession::create(
        4, dependencies(platform,
                        std::make_unique<FakeBackend>(backendState)));
    expect(session->configure(audioTrack(), 4, timeline(4, 0), nullptr) ==
                   NativeMediaConsumeResult::Failed &&
               session->facts().resourceEntered,
           "output-arm failure occurs after converter and clock activation");
    expect(session->retire(4, 40) == NativeMediaConsumerProgress::Done,
           "clock-activated output-arm failure remains exactly retireable");
    expectExactRetirement(*session, 4, 40, true,
                          "partial output arm publishes exact invalid clock proof");
  }

  {
    auto platform = std::make_shared<FakePlatform>();
    platform->disposeFailures = 1;
    auto backendState = std::make_shared<BackendState>();
    auto session = NativeAudioSession::create(
        6, dependencies(platform,
                        std::make_unique<FakeBackend>(backendState)));
    expect(session->configure(audioTrack(), 6, timeline(6, 0), nullptr) ==
               NativeMediaConsumeResult::Accepted,
           "retryable close failure retirement fixture configures");
    expect(session->retire(6, 60) == NativeMediaConsumerProgress::Progress &&
               session->facts().state == NativeAudioSessionState::Retiring &&
               session->facts().retiredGeneration == 6 &&
               session->facts().invalidationGeneration == 60,
           "partially progressed lower close remains an exact retry");
    expect(session->retire(6, 61) ==
                   NativeMediaConsumerProgress::StaleGeneration &&
               session->retire(6, 60) == NativeMediaConsumerProgress::Done,
           "wrong retry is inert and the exact retry completes");
    expectExactRetirement(*session, 6, 60, true,
                          "retryable output failure cannot weaken terminal proof");
  }

  {
    const NativeMediaGenerationTimeline next = timeline(2, 4096, 0);
    NativeAudioGenerationTimeline converterNext;
    converterNext.presentationFloor = {
        4096, static_cast<std::int32_t>(kRate)};
    converterNext.trimBeforeFloor = true;
    converterNext.startsAtStreamOrigin = true;
    auto platform = std::make_shared<FakePlatform>();
    auto backendState = std::make_shared<BackendState>();
    auto session = NativeAudioSession::create(
        1, dependencies(platform,
                        std::make_unique<FakeBackend>(backendState)));
    expect(session->configure(audioTrack(), 1, timeline(1, 0), nullptr) ==
               NativeMediaConsumeResult::Accepted,
           "staged-flush retirement fixture configures");
    NativeAudioSessionTestAccess::stageFlushAfterStop(
        *session, 1, 2, next, converterNext,
        {4096, static_cast<std::int32_t>(kRate)}, 4096);
    expect(session->retire(1, 9) ==
                   NativeMediaConsumerProgress::StaleGeneration &&
               session->facts().state == NativeAudioSessionState::Flushing,
           "retirement requires the flush-exposed target generation");
    expect(session->retire(2, 2) == NativeMediaConsumerProgress::Failed &&
               session->facts().state == NativeAudioSessionState::Flushing,
           "flush target must be strictly below terminal invalidation");
    expect(session->retire(2, 9) == NativeMediaConsumerProgress::Done &&
               session->flush(1, 2, next) ==
                   NativeMediaConsumerProgress::Failed,
           "exact retirement permanently supersedes staged flush");
    expectExactRetirement(*session, 2, 9, true,
                          "staged flush converges to one invalid generation");
  }
}

void testRetirementQuiescingAndExactRetry() {
  auto platform = std::make_shared<FakePlatform>();
  auto backendState = std::make_shared<BackendState>();
  backendState->add({1, 1024, true, true, false, false});
  const MediaTrackDescriptor track = audioTrack();
  auto releases = std::make_shared<std::atomic<int>>(0);
  std::vector<MediaSourceReadResult> events;
  events.emplace_back(makeSample(track, 1, 1, 0, releases));
  auto session = NativeAudioSession::create(
      1, dependencies(platform,
                      std::make_unique<FakeBackend>(backendState)));
  NativeAudioSession* audio = session.get();
  auto dispatcher = std::make_unique<NativeMediaDispatcher>(
      std::make_unique<FakeSource>(
          descriptor(track), MediaTime{0, static_cast<std::int32_t>(kRate)},
          std::move(events)),
      std::make_unique<NullVideo>(), std::move(session));
  expect(dispatcher->openLocalFile("/tmp/retire.mov", audioOptions(0), 1)
                     .status == NativeMediaDispatcherOpenStatus::Ready &&
             dispatcher->step().action ==
                 NativeMediaDispatcherAction::AudioSample &&
             audio->setPaused(false) == NativeAudioSessionProgress::Done &&
             audio->start() == NativeAudioSessionProgress::Done,
         "quiescing retirement fixture starts one exact callback graph");

  NativeAudioSessionTestAccess::setAfterRenderPreflightHook(
      *audio, &FakePlatform::blockAfterRenderPreflight, platform.get());
  std::thread callback([platform] {
    static_cast<void>(platform->render(512, 30'000, 0.0));
  });
  {
    std::unique_lock<std::mutex> lock(platform->callbackMutex);
    platform->callbackCondition.wait(
        lock, [&platform] { return platform->callbackEntered; });
  }
  expect(audio->retire(1, 20) == NativeMediaConsumerProgress::Quiescing &&
             audio->retire(1, 20) ==
                 NativeMediaConsumerProgress::Quiescing &&
             audio->retire(1, 21) ==
                 NativeMediaConsumerProgress::StaleGeneration &&
             audio->facts().state == NativeAudioSessionState::Retiring &&
             audio->facts().retiredGeneration == 1 &&
             audio->facts().invalidationGeneration == 20,
         "entered callback keeps only the exact latched pair retryable");
  expectTerminalControlsInert(
      *audio, "Retiring session rejects controls without changing facts");
  {
    std::lock_guard<std::mutex> lock(platform->callbackMutex);
    platform->releaseCallback = true;
  }
  platform->callbackCondition.notify_all();
  callback.join();
  NativeAudioSessionTestAccess::setAfterRenderPreflightHook(
      *audio, nullptr, nullptr);
  expect(audio->retire(1, 20) == NativeMediaConsumerProgress::Done,
         "wake-driven retry completes after callback exit");
  expectExactRetirement(*audio, 1, 20, true,
                        "quiescing retirement completes exact closed proof");
  dispatcher.reset();
}

void testQuiescingDestructorQuarantineRecovery() {
  auto platform = std::make_shared<FakePlatform>();
  auto backendState = std::make_shared<BackendState>();
  backendState->add({1, 1024, true, true, false, false});
  const MediaTrackDescriptor track = audioTrack();
  auto releases = std::make_shared<std::atomic<int>>(0);
  std::vector<MediaSourceReadResult> events;
  events.emplace_back(makeSample(track, 1, 1, 0, releases));
  auto session = NativeAudioSession::create(
      1, dependencies(platform,
                      std::make_unique<FakeBackend>(backendState)));
  NativeAudioSession* audio = session.get();
  auto dispatcher = std::make_unique<NativeMediaDispatcher>(
      std::make_unique<FakeSource>(
          descriptor(track), MediaTime{0, static_cast<std::int32_t>(kRate)},
          std::move(events)),
      std::make_unique<NullVideo>(), std::move(session));
  expect(dispatcher->openLocalFile("/tmp/quarantine.mov", audioOptions(0), 1)
                 .status == NativeMediaDispatcherOpenStatus::Ready &&
             dispatcher->step().action ==
                 NativeMediaDispatcherAction::AudioSample,
         "quarantine fixture prebuffers one sample");
  expect(audio->setPaused(false) == NativeAudioSessionProgress::Done &&
             audio->start() == NativeAudioSessionProgress::Done,
         "quarantine fixture starts output");

  platform->blockHost.store(true, std::memory_order_release);
  std::thread callback([platform] {
    static_cast<void>(platform->render(512, 20'000, 0.0));
  });
  {
    std::unique_lock<std::mutex> lock(platform->hostMutex);
    platform->hostCondition.wait(lock,
                                 [&platform] { return platform->hostEntered; });
  }
  expect(audio->stop() == NativeAudioSessionProgress::Quiescing,
         "entered render callback makes stop explicitly Quiescing");
  dispatcher.reset();
  expect(NativeAudioSession::quarantineFacts().quarantined,
         "destructor transfers the whole callback graph to quarantine");

  auto rejectedPlatform = std::make_shared<FakePlatform>();
  auto rejectedBackend = std::make_shared<BackendState>();
  expect(NativeAudioSession::create(
             7, dependencies(rejectedPlatform,
                             std::make_unique<FakeBackend>(rejectedBackend))) ==
             nullptr,
         "capacity-one quarantine rejects a second session");

  {
    std::lock_guard<std::mutex> lock(platform->hostMutex);
    platform->releaseHost = true;
  }
  platform->hostCondition.notify_all();
  callback.join();
  auto recovered = NativeAudioSession::recoverQuarantined();
  expect(recovered != nullptr,
         "quarantined graph has a discoverable recovery owner");
  expect(recovered->close() == NativeMediaConsumerProgress::Done,
         "recovered owner completes exact close after callback exit");
  const NativeAudioSessionQuarantineFacts quarantine =
      NativeAudioSession::quarantineFacts();
  expect(!quarantine.claimed && !quarantine.quarantined &&
             quarantine.transfers >= 1 && quarantine.recoveries >= 1 &&
             quarantine.rejectedCreates >= 1,
         "quarantine release and bounded counters are observable");
}

} // namespace

int main() {
  testCachedGainMuteControls();
  testTerminalGainMuteRejection();
  testPreflightAndPostResourceFailure();
  testAccurateTrimClockPauseAndEof();
  testSeekStopCancelAndFailure();
  testFirstAudioSampleBindsSourceDecodeStart();
  testBackpressurePreservesDispatcherDelivery();
  testCloseSupersedesStagedFlush();
  testExactTerminalRetirement();
  testRetirementQuiescingAndExactRetry();
  testQuiescingDestructorQuarantineRecovery();
  if (failures != 0) {
    std::cerr << failures << " native audio session checks failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "native audio session checks passed\n";
  return EXIT_SUCCESS;
}
