#include "platform/macos/native_audio_converter.hpp"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdlib>
#include <initializer_list>
#include <iostream>
#include <limits>
#include <memory>
#include <new>
#include <span>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>

namespace {

using namespace wam::macos;
using namespace wam::media;

std::atomic<std::uint64_t> allocations{0};
int failures = 0;

void expect(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

class SampleStorage final : public MediaPayloadStorage {
public:
  SampleStorage(CMSampleBufferRef sample, std::size_t size,
                std::atomic<int> *releaseCounter,
                bool exposeContiguous = false,
                std::atomic<std::uint64_t> *copiedBytes = nullptr) noexcept
      : sample_(sample), size_(size), release_counter_(releaseCounter),
        copied_bytes_(copiedBytes), expose_contiguous_(exposeContiguous) {}
  ~SampleStorage() override {
    CFRelease(sample_);
    if (release_counter_ != nullptr) {
      release_counter_->fetch_add(1, std::memory_order_relaxed);
    }
  }

  [[nodiscard]] std::size_t byteSize() const noexcept override { return size_; }
  [[nodiscard]] std::span<const std::byte>
  contiguousBytes() const noexcept override {
    if (!expose_contiguous_) {
      return {};
    }
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample_);
    char *data = nullptr;
    std::size_t contiguousLength = 0;
    std::size_t totalLength = 0;
    if (block == nullptr ||
        CMBlockBufferGetDataPointer(block, 0, &contiguousLength, &totalLength,
                                    &data) != noErr ||
        data == nullptr || totalLength != size_ ||
        contiguousLength != totalLength) {
      return {};
    }
    return {reinterpret_cast<const std::byte *>(data), totalLength};
  }
  [[nodiscard]] bool
  copyBytes(std::size_t offset,
            std::span<std::byte> destination) const noexcept override {
    if (offset > size_ || destination.size() > size_ - offset) {
      return false;
    }
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample_);
    const bool copied =
        destination.empty() ||
        (block != nullptr &&
         CMBlockBufferCopyDataBytes(block, offset, destination.size(),
                                    destination.data()) == noErr);
    if (copied && copied_bytes_ != nullptr) {
      copied_bytes_->fetch_add(destination.size(), std::memory_order_relaxed);
    }
    return copied;
  }

protected:
  [[nodiscard]] std::optional<NativePayloadKind>
  nativePayloadKind() const noexcept override {
    return NativePayloadKind::CoreMediaSampleBuffer;
  }
  [[nodiscard]] const void *borrowedNativePayload() const noexcept override {
    return sample_;
  }

private:
  CMSampleBufferRef sample_{nullptr};
  std::size_t size_{0};
  std::atomic<int> *release_counter_{nullptr};
  std::atomic<std::uint64_t> *copied_bytes_{nullptr};
  bool expose_contiguous_{false};
};

MediaTrackDescriptor makeTrack(std::uint32_t channels = 2,
                               double rate = 48'000.0,
                               MediaCodec codec = MediaCodec::Aac,
                               AudioFormatID tag = kAudioFormatMPEG4AAC) {
  MediaTrackDescriptor track;
  track.id = 7;
  track.kind = MediaTrackKind::Audio;
  track.codec = codec;
  track.timeBase = {1, 48'000};
  track.duration = {10, 1};
  track.codecConfigurationKind = MediaCodecConfigurationKind::AudioMagicCookie;
  track.codecConfiguration = {std::byte{0x12}, std::byte{0x10}};
  track.audio =
      MediaAudioFormat{rate, channels, tag, 0, 1024, 0, 0, 0, 0, true};
  return track;
}

void setTrackLayout(MediaTrackDescriptor &track,
                    AudioChannelLayoutTag tag) noexcept {
  track.audio->channelLayoutTag = tag;
  track.audio->channelLayoutPresent = true;
}

MediaSample
makeSample(const MediaTrackDescriptor &track, MediaGeneration generation,
           std::span<const std::uint32_t> packetSizes, bool decodeOnly = false,
           bool includePacketDescriptions = true,
           std::atomic<int> *releaseCounter = nullptr,
           std::int64_t presentationFrame = 0,
           bool exposeContiguous = false,
           std::atomic<std::uint64_t> *copiedBytes = nullptr,
           std::span<const std::int64_t> packetOffsets = {}) {
  const std::uint32_t exactRate =
      static_cast<std::uint32_t>(track.audio->sampleRate);
  const std::uint32_t exactPacketFrames = track.audio->framesPerPacket;
  expect(packetOffsets.empty() || packetOffsets.size() == packetSizes.size(),
         "explicit packet offsets match the packet count");
  const std::size_t byteCount = [&] {
    std::size_t total = 0;
    for (std::size_t index = 0; index < packetSizes.size(); ++index) {
      if (packetOffsets.empty()) {
        total += packetSizes[index];
        continue;
      }
      expect(packetOffsets[index] >= 0,
             "explicit packet offsets are nonnegative");
      const auto start = static_cast<std::size_t>(packetOffsets[index]);
      total = std::max(total, start + packetSizes[index]);
    }
    return total;
  }();
  AudioStreamBasicDescription asbd{};
  asbd.mSampleRate = track.audio->sampleRate;
  asbd.mFormatID = track.audio->formatTag;
  asbd.mFormatFlags = track.audio->formatFlags;
  asbd.mBytesPerPacket = track.audio->bytesPerPacket;
  asbd.mFramesPerPacket = track.audio->framesPerPacket;
  asbd.mBytesPerFrame = track.audio->bytesPerFrame;
  asbd.mChannelsPerFrame = track.audio->channels;
  asbd.mBitsPerChannel = track.audio->bitsPerChannel;
  AudioChannelLayout layout{};
  std::size_t layoutSize = 0;
  const AudioChannelLayout *layoutPointer = nullptr;
  if (track.audio->channelLayoutPresent) {
    layout.mChannelLayoutTag = track.audio->channelLayoutTag;
    layoutPointer = &layout;
    layoutSize = offsetof(AudioChannelLayout, mChannelDescriptions);
    if (layout.mChannelLayoutTag ==
        kAudioChannelLayoutTag_UseChannelDescriptions) {
      expect(track.audio->channels == 1,
             "description-layout fixture is bounded to one channel");
      layout.mNumberChannelDescriptions = 1;
      layout.mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Mono;
      layoutSize = sizeof(AudioChannelLayout);
    }
  }
  CMAudioFormatDescriptionRef format = nullptr;
  OSStatus status = CMAudioFormatDescriptionCreate(
      kCFAllocatorDefault, &asbd, layoutSize, layoutPointer,
      track.codecConfiguration.size(), track.codecConfiguration.data(),
      nullptr, &format);
  expect(status == noErr && format != nullptr,
         "synthetic audio format creation succeeds");
  CMBlockBufferRef block = nullptr;
  status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr,
                                              byteCount, kCFAllocatorDefault,
                                              nullptr, 0, byteCount, 0, &block);
  expect(status == noErr && block != nullptr,
         "synthetic audio block creation succeeds");
  std::array<std::byte, 256> bytes{};
  expect(byteCount <= bytes.size(), "synthetic payload fits its fixture");
  for (std::size_t index = 0; index < byteCount; ++index) {
    bytes[index] = static_cast<std::byte>(index + 1);
  }
  status = CMBlockBufferReplaceDataBytes(bytes.data(), block, 0, byteCount);
  expect(status == noErr, "synthetic audio bytes are initialized");
  std::array<AudioStreamPacketDescription, 16> descriptions{};
  expect(packetSizes.size() <= descriptions.size(),
         "synthetic packet descriptions fit their fixture");
  std::int64_t offset = 0;
  for (std::size_t index = 0; index < packetSizes.size(); ++index) {
    const std::int64_t packetOffset =
        packetOffsets.empty() ? offset : packetOffsets[index];
    descriptions[index] = {packetOffset, exactPacketFrames, packetSizes[index]};
    offset += packetSizes[index];
  }
  CMSampleBufferRef nativeSample = nullptr;
  status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      kCFAllocatorDefault, block, format,
      static_cast<CMItemCount>(packetSizes.size()),
      CMTimeMake(presentationFrame, exactRate),
      includePacketDescriptions ? descriptions.data() : nullptr, &nativeSample);
  CFRelease(block);
  CFRelease(format);
  expect(status == noErr && nativeSample != nullptr,
         "synthetic packetized sample creation succeeds");
  MediaSample sample;
  sample.generation = generation;
  sample.track = track.id;
  sample.kind = MediaSampleKind::EncodedAudio;
  sample.presentationTime = {presentationFrame,
                             static_cast<std::int32_t>(exactRate)};
  sample.duration = {
      static_cast<std::int64_t>(packetSizes.size() * exactPacketFrames),
      static_cast<std::int32_t>(exactRate)};
  sample.sampleCount = static_cast<std::uint32_t>(packetSizes.size());
  sample.decodeOnly = decodeOnly;
  sample.payload = MediaPayloadLease(
      std::make_shared<SampleStorage>(nativeSample, byteCount, releaseCounter,
                                      exposeContiguous, copiedBytes));
  return sample;
}

CMSampleBufferRef nativeSample(MediaSample &sample) {
  const auto borrowed =
      sample.payload.borrowNative<NativePayloadKind::CoreMediaSampleBuffer>();
  return static_cast<CMSampleBufferRef>(
      const_cast<void *>(borrowed->opaqueAddress()));
}

MediaSample aliasSample(const MediaSample &source,
                        std::atomic<int> *releaseCounter = nullptr) {
  const auto borrowed =
      source.payload.borrowNative<NativePayloadKind::CoreMediaSampleBuffer>();
  auto native = static_cast<CMSampleBufferRef>(
      const_cast<void *>(borrowed->opaqueAddress()));
  CFRetain(native);
  MediaSample alias;
  alias.generation = source.generation;
  alias.track = source.track;
  alias.kind = source.kind;
  alias.presentationTime = source.presentationTime;
  alias.decodeTime = source.decodeTime;
  alias.duration = source.duration;
  alias.keyFrame = source.keyFrame;
  alias.decodeOnly = source.decodeOnly;
  alias.discontinuity = source.discontinuity;
  alias.sampleCount = source.sampleCount;
  alias.decodedAudioFrames = source.decodedAudioFrames;
  alias.payload = MediaPayloadLease(std::make_shared<SampleStorage>(
      native, source.payload.byteSize(), releaseCounter));
  return alias;
}

struct Script {
  std::size_t consume{0};
  std::size_t produce{0};
  bool finalInputReleased{false};
  bool needsInput{false};
  bool drained{false};
  bool failed{false};
  bool throws{false};
};

class FakeBackend final : public NativeAudioConverterBackend {
public:
  [[nodiscard]] bool
  configure(const NativeAudioBackendConfiguration &configuration,
            std::string *) override {
    ++configureCalls;
    if (throwConfigure) {
      throw std::runtime_error("configure");
    }
    configuredRate = configuration.outputSampleRate;
    configuredChannels = configuration.outputChannels;
    configuredLayoutPresent = configuration.input.channelLayoutPresent;
    configuredLayoutTag = configuration.input.channelLayoutTag;
    cookieSize = configuration.magicCookie.size();
    std::copy(configuration.magicCookie.begin(),
              configuration.magicCookie.end(), cookie.begin());
    return configureSucceeds;
  }

  [[nodiscard]] NativeAudioBackendResult
  convert(NativeAudioBackendInput input,
          std::span<float> interleavedOutput) override {
    ++convertCalls;
    observedPacketCount = input.packets.size();
    observedByteCount = input.bytes.size();
    observedBytesData = input.bytes.data();
    observedEof = input.endOfStream;
    const std::size_t observedPacketsToCopy =
        std::min(input.packets.size(), observedPackets.size());
    std::copy_n(input.packets.begin(), observedPacketsToCopy,
                observedPackets.begin());
    const std::size_t observedBytesToCopy =
        std::min(input.bytes.size(), observedBytes.size());
    std::copy_n(input.bytes.begin(), observedBytesToCopy,
                observedBytes.begin());
    if (observedPacketsToCopy != 0) {
      firstPacket = observedPackets.front();
    }
    const Script current =
        scripts[scriptIndex < scriptCount ? scriptIndex++ : scriptCount];
    if (current.throws) {
      throw std::runtime_error("convert");
    }
    const std::size_t samples = std::min(
        interleavedOutput.size(),
        current.produce * static_cast<std::size_t>(configuredChannels));
    for (std::size_t index = 0; index < samples; ++index) {
      interleavedOutput[index] =
          static_cast<float>(100 * convertCalls + index + 1);
    }
    return {current.consume,    current.produce, current.finalInputReleased,
            current.needsInput, current.drained, current.failed};
  }

  [[nodiscard]] bool reset(std::string *) override {
    ++resetCalls;
    if (lifecycleReleaseCounter != nullptr) {
      releaseCountSeenByReset =
          lifecycleReleaseCounter->load(std::memory_order_relaxed);
    }
    if (throwReset) {
      throw std::runtime_error("reset");
    }
    return resetSucceeds;
  }
  void close() noexcept override {
    ++closeCalls;
    if (lifecycleReleaseCounter != nullptr) {
      releaseCountSeenByClose =
          lifecycleReleaseCounter->load(std::memory_order_relaxed);
    }
  }

  void setScripts(std::initializer_list<Script> values) {
    scriptCount = values.size();
    scriptIndex = 0;
    std::copy(values.begin(), values.end(), scripts.begin());
  }

  std::array<Script, 12> scripts{};
  std::array<std::byte, 32> cookie{};
  std::size_t scriptCount{0};
  std::size_t scriptIndex{0};
  std::size_t cookieSize{0};
  std::size_t observedPacketCount{0};
  std::size_t observedByteCount{0};
  const std::byte *observedBytesData{nullptr};
  std::array<NativeAudioPacketDescription, 16> observedPackets{};
  std::array<std::byte, 32> observedBytes{};
  NativeAudioPacketDescription firstPacket{};
  std::uint32_t configuredRate{0};
  std::uint32_t configuredChannels{0};
  bool configuredLayoutPresent{false};
  std::uint32_t configuredLayoutTag{0};
  int configureCalls{0};
  int convertCalls{0};
  int resetCalls{0};
  int closeCalls{0};
  int releaseCountSeenByReset{-1};
  int releaseCountSeenByClose{-1};
  std::atomic<int> *lifecycleReleaseCounter{nullptr};
  bool observedEof{false};
  bool configureSucceeds{true};
  bool resetSucceeds{true};
  bool throwConfigure{false};
  bool throwReset{false};
};

struct Fixture {
  explicit Fixture(MediaGeneration generation = 1,
                   MediaTrackDescriptor value = makeTrack(),
                   NativeAudioGenerationTimeline timeline = {})
      : ring(generation), track(std::move(value)) {
    auto owned = std::make_unique<FakeBackend>();
    backend = owned.get();
    converter = std::make_unique<NativeAudioConverter>(ring, std::move(owned));
    ready = converter->configure(track, generation, timeline, &error);
  }
  NativePcmRing ring;
  MediaTrackDescriptor track;
  FakeBackend *backend{nullptr};
  std::unique_ptr<NativeAudioConverter> converter;
  std::string error;
  bool ready{false};
};

void setBooleanAttachment(MediaSample &sample, CFStringRef key, bool value) {
  CMSetAttachment(nativeSample(sample), key,
                  value ? kCFBooleanTrue : kCFBooleanFalse,
                  kCMAttachmentMode_ShouldNotPropagate);
}

void setSpeedAttachment(MediaSample &sample, double speed) {
  CFNumberRef number =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &speed);
  CMSetAttachment(nativeSample(sample),
                  kCMSampleBufferAttachmentKey_SpeedMultiplier, number,
                  kCMAttachmentMode_ShouldNotPropagate);
  CFRelease(number);
}

void setTrimAttachment(MediaSample &sample, CFStringRef key, CMTime trim) {
  CFDictionaryRef value = CMTimeCopyAsDictionary(trim, kCFAllocatorDefault);
  CMSetAttachment(nativeSample(sample), key, value,
                  kCMAttachmentMode_ShouldNotPropagate);
  CFRelease(value);
}

void setBufferAttachment(MediaSample &sample, CFStringRef key,
                         CFTypeRef value) {
  CMSetAttachment(nativeSample(sample), key, value,
                  kCMAttachmentMode_ShouldNotPropagate);
}

void setImmediatePlayoutAttachment(MediaSample &sample,
                                   std::int64_t refreshCount) {
  CFNumberRef value =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &refreshCount);
  CFArrayRef array =
      CMSampleBufferGetSampleAttachmentsArray(nativeSample(sample), true);
  auto first = static_cast<CFMutableDictionaryRef>(
      const_cast<void *>(CFArrayGetValueAtIndex(array, 0)));
  CFDictionarySetValue(
      first, kCMSampleAttachmentKey_AudioIndependentSampleDecoderRefreshCount,
      value);
  CFRelease(value);
}

void testConfigurationPacketMetadataAndAdmission() {
  Fixture fixture;
  expect(fixture.ready && fixture.converter->outputSampleRate() == 48'000 &&
             fixture.backend->cookieSize == 2 &&
             fixture.backend->cookie[0] == std::byte{0x12} &&
             fixture.backend->configuredChannels == 2,
         "exact ASBD, output rate, channels, and cookie reach the backend");
  fixture.backend->setScripts({{1, 1}});
  const std::array<std::uint32_t, 2> sizes{3, 5};
  auto sample = makeSample(fixture.track, 1, sizes);
  expect(fixture.converter->submit(std::move(sample), &fixture.error) ==
                 NativeAudioSubmitResult::Accepted &&
             fixture.converter->pump(&fixture.error) ==
                 NativeAudioPumpResult::Published &&
             fixture.backend->observedPacketCount == 2 &&
             fixture.backend->observedByteCount == 8 &&
             fixture.backend->firstPacket.startOffset == 0 &&
             fixture.backend->firstPacket.byteSize == 3 &&
             fixture.backend->firstPacket.variableFrames == 1024,
         "bounded packet descriptions and payload reach conversion exactly");

  auto cbrTrack =
      makeTrack(2, 48'000.0, MediaCodec::Mp3, kAudioFormatMPEGLayer3);
  cbrTrack.codecConfigurationKind = MediaCodecConfigurationKind::None;
  cbrTrack.codecConfiguration.clear();
  cbrTrack.audio->bytesPerPacket = 4;
  cbrTrack.audio->framesPerPacket = 1152;
  Fixture cbr(16, cbrTrack);
  cbr.backend->setScripts({{1, 1}});
  const std::array<std::uint32_t, 2> cbrSizes{4, 4};
  auto cbrSample = makeSample(cbr.track, 16, cbrSizes, false, false);
  expect(cbr.ready &&
             cbr.converter->submit(std::move(cbrSample), nullptr) ==
                 NativeAudioSubmitResult::Accepted &&
             cbr.converter->pump(nullptr) == NativeAudioPumpResult::Published &&
             cbr.backend->firstPacket.byteSize == 4 &&
             cbr.backend->firstPacket.startOffset == 0,
         "constant-size packets synthesize bounded descriptions when CoreMedia "
         "omits them");

  Fixture rateFixture(2);
  auto nonIntegral = makeTrack(2, 48'000.5);
  auto unusualIntegral = makeTrack(2, 88'200.0);
  expect(!rateFixture.converter->configure(nonIntegral, 2, nullptr) &&
             !rateFixture.converter->configure(unusualIntegral, 2, nullptr) &&
             rateFixture.converter->stats().configured &&
             rateFixture.converter->outputSampleRate() == 48'000,
         "invalid reconfiguration is rejected without mutating the live "
         "configuration");
  rateFixture.backend->configureSucceeds = false;
  expect(!rateFixture.converter->configure(makeTrack(), 2, nullptr) &&
             !rateFixture.converter->stats().configured &&
             rateFixture.converter->outputSampleRate() == 0,
         "partial backend configuration failure leaves a fail-closed state");

  Fixture attachments(3);
  const std::array<std::uint32_t, 1> onePacket{4};
  auto acceptedDefaults = makeSample(attachments.track, 3, onePacket);
  setBooleanAttachment(acceptedDefaults, kCMSampleBufferAttachmentKey_Reverse,
                       false);
  setSpeedAttachment(acceptedDefaults, 1.0);
  setTrimAttachment(acceptedDefaults,
                    kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                    CMTimeMake(0, 48'000));
  expect(attachments.converter->submit(std::move(acceptedDefaults), nullptr) ==
             NativeAudioSubmitResult::Accepted,
         "documented no-op attachment values are accepted");
  attachments.converter->cancel(3);

  Fixture rejected(4);
  auto reverse = makeSample(rejected.track, 4, onePacket);
  setBooleanAttachment(reverse, kCMSampleBufferAttachmentKey_Reverse, true);
  auto speed = makeSample(rejected.track, 4, onePacket);
  setSpeedAttachment(speed, 2.0);
  auto trim = makeSample(rejected.track, 4, onePacket);
  setTrimAttachment(trim, kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
                    CMTimeMake(1, 48'000));
  auto roundedZero = makeSample(rejected.track, 4, onePacket);
  CMTime inexactZero = CMTimeMake(0, 48'000);
  inexactZero.flags |= kCMTimeFlags_HasBeenRounded;
  setTrimAttachment(roundedZero,
                    kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                    inexactZero);
  auto decoderReset = makeSample(rejected.track, 4, onePacket);
  setBufferAttachment(decoderReset,
                      kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
                      kCFBooleanTrue);
  auto gradual = makeSample(rejected.track, 4, onePacket);
  std::int64_t refresh = 1;
  CFNumberRef gradualCount =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &refresh);
  setBufferAttachment(gradual,
                      kCMSampleBufferAttachmentKey_GradualDecoderRefresh,
                      gradualCount);
  CFRelease(gradualCount);
  expect(rejected.converter->submit(std::move(reverse), nullptr) ==
                 NativeAudioSubmitResult::Invalid &&
             rejected.converter->submit(std::move(speed), nullptr) ==
                 NativeAudioSubmitResult::Invalid &&
             rejected.converter->submit(std::move(trim), nullptr) ==
                 NativeAudioSubmitResult::Invalid &&
             rejected.converter->submit(std::move(roundedZero), nullptr) ==
                 NativeAudioSubmitResult::Invalid &&
             rejected.converter->submit(std::move(decoderReset), nullptr) ==
                 NativeAudioSubmitResult::Invalid &&
             rejected.converter->submit(std::move(gradual), nullptr) ==
                 NativeAudioSubmitResult::Invalid,
         "unmodeled audio transform, trim, and decoder controls fail closed");

  auto bitmapLayout = makeTrack();
  setTrackLayout(bitmapLayout, kAudioChannelLayoutTag_UseChannelBitmap);
  auto describedLayout = makeTrack();
  setTrackLayout(describedLayout,
                 kAudioChannelLayoutTag_UseChannelDescriptions);
  auto customLayout = makeTrack();
  setTrackLayout(customLayout, kAudioChannelLayoutTag_StereoHeadphones);
  auto absentTaggedLayout = makeTrack();
  absentTaggedLayout.audio->channelLayoutTag = kAudioChannelLayoutTag_Stereo;
  auto mismatchedCanonicalLayout = makeTrack();
  setTrackLayout(mismatchedCanonicalLayout, kAudioChannelLayoutTag_Mono);
  Fixture layoutGate(52);
  expect(!layoutGate.converter->configure(bitmapLayout, 52, nullptr) &&
             !layoutGate.converter->configure(describedLayout, 52, nullptr) &&
             !layoutGate.converter->configure(customLayout, 52, nullptr) &&
             !layoutGate.converter->configure(absentTaggedLayout, 52,
                                                nullptr) &&
             !layoutGate.converter->configure(mismatchedCanonicalLayout, 52,
                                                nullptr),
         "absent-tag aliases, sentinel, and unmodeled layouts fail before "
         "backend setup");

  auto canonicalStereo = makeTrack();
  setTrackLayout(canonicalStereo, kAudioChannelLayoutTag_Stereo);
  Fixture canonicalLayout(53, canonicalStereo);
  auto canonicalSample = makeSample(canonicalLayout.track, 53, onePacket);
  expect(canonicalLayout.ready &&
             canonicalLayout.backend->configuredLayoutPresent &&
             canonicalLayout.backend->configuredLayoutTag ==
                 kAudioChannelLayoutTag_Stereo &&
             canonicalLayout.converter->submit(std::move(canonicalSample),
                                                nullptr) ==
                 NativeAudioSubmitResult::Accepted,
         "an explicit canonical stereo layout matches at configure and "
         "sample ingress");

  Fixture describedIngress(54, makeTrack(1));
  auto describedSampleTrack = describedIngress.track;
  setTrackLayout(describedSampleTrack,
                 kAudioChannelLayoutTag_UseChannelDescriptions);
  auto describedSample = makeSample(describedSampleTrack, 54, onePacket);
  std::size_t describedLayoutSize = 0;
  const auto describedFormat = static_cast<CMAudioFormatDescriptionRef>(
      CMSampleBufferGetFormatDescription(nativeSample(describedSample)));
  const AudioChannelLayout *actualDescribedLayout =
      CMAudioFormatDescriptionGetChannelLayout(describedFormat,
                                               &describedLayoutSize);
  const auto describedOutcome =
      describedIngress.converter->prepare(describedSample, nullptr);
  expect(describedIngress.ready &&
             actualDescribedLayout != nullptr &&
             actualDescribedLayout->mChannelLayoutTag ==
                 kAudioChannelLayoutTag_UseChannelDescriptions &&
             describedLayoutSize >=
                 offsetof(AudioChannelLayout, mChannelDescriptions) &&
             describedOutcome.result == NativeAudioSubmitResult::Invalid &&
             describedSample.payload &&
             describedIngress.backend->convertCalls == 0 &&
             describedIngress.ring.stats().queuedSlabs == 0,
         "an actual description-array layout cannot alias absent layout "
         "metadata or publish audible PCM");
}

void testTransactionalPreparePreservesExactOwnership() {
  const std::array<std::uint32_t, 1> size{4};
  Fixture fixture(41);
  std::atomic<int> releaseCount{0};
  auto exact = makeSample(fixture.track, 41, size, false, true, &releaseCount);
  auto blocked = makeSample(fixture.track, 41, size);
  auto prepared = fixture.converter->prepare(exact, nullptr);
  auto backpressure = fixture.converter->prepare(blocked, nullptr);
  const auto staged = fixture.converter->stats();
  expect(prepared.result == NativeAudioSubmitResult::Accepted &&
             static_cast<bool>(prepared.prepared) && exact.payload &&
             backpressure.result == NativeAudioSubmitResult::Backpressure &&
             blocked.payload && staged.samplePrepared &&
             !staged.sampleRetained && staged.acceptedSamples == 0 &&
             staged.retainedPayloadBytes == 0 &&
             staged.peakRetainedPayloadBytes == 0 &&
             releaseCount == 0,
         "prepare validates and stages without taking dispatcher ownership");
  expect(fixture.converter->commitPrepared(std::move(prepared.prepared),
                                           std::move(exact)) &&
             !exact.payload && fixture.converter->stats().sampleRetained &&
             fixture.converter->stats().retainedPayloadBytes == 4 &&
             fixture.converter->stats().peakRetainedPayloadBytes == 4 &&
             fixture.converter->stats().acceptedSamples == 1,
         "the exact prepare proof commits the exact native lease once");
  fixture.converter->cancel(41);
  expect(releaseCount == 1 &&
             fixture.converter->stats().retainedPayloadBytes == 0 &&
             fixture.converter->stats().peakRetainedPayloadBytes == 4,
         "committed transactional ownership retires through lifecycle reset");

  Fixture mismatch(42);
  auto first = makeSample(mismatch.track, 42, size);
  auto other = makeSample(mismatch.track, 42, size);
  auto firstProof = mismatch.converter->prepare(first, nullptr);
  expect(firstProof.result == NativeAudioSubmitResult::Accepted &&
             !mismatch.converter->commitPrepared(std::move(firstProof.prepared),
                                                 std::move(other)) &&
             first.payload && other.payload &&
             !mismatch.converter->stats().configured,
         "a prepare token cannot commit a different native sample identity");

  Fixture mutated(50);
  auto changedEnvelope = makeSample(mutated.track, 50, size);
  auto changedProof = mutated.converter->prepare(changedEnvelope, nullptr);
  changedEnvelope.decodedAudioFrames = 1;
  expect(
      changedProof.result == NativeAudioSubmitResult::Accepted &&
          !mutated.converter->commitPrepared(std::move(changedProof.prepared),
                                             std::move(changedEnvelope)) &&
          changedEnvelope.payload && !mutated.converter->stats().configured,
      "commit rejects mutation of the prepared sample envelope");

  Fixture abandoned(43);
  std::atomic<int> abandonedRelease{0};
  auto callerOwned =
      makeSample(abandoned.track, 43, size, false, true, &abandonedRelease);
  auto abandonedProof = abandoned.converter->prepare(callerOwned, nullptr);
  abandoned.converter->cancel(43);
  expect(abandonedProof.result == NativeAudioSubmitResult::Accepted &&
             callerOwned.payload && abandonedRelease == 0 &&
             !abandoned.converter->stats().samplePrepared,
         "cancel abandons prepared bytes without stealing the caller's lease");
  callerOwned.payload.reset();
  expect(abandonedRelease == 1,
         "the caller remains the sole owner of an abandoned prepared sample");

  Fixture overtaken(54);
  std::atomic<int> overtakenRelease{0};
  auto preparedBeforeEof =
      makeSample(overtaken.track, 54, size, false, true, &overtakenRelease);
  auto overtakenProof =
      overtaken.converter->prepare(preparedBeforeEof, nullptr);
  const auto acceptedBeforeEof = overtaken.converter->stats().acceptedSamples;
  expect(overtakenProof.result == NativeAudioSubmitResult::Accepted &&
             overtaken.converter->endOfStream(54, nullptr) ==
                 NativeAudioPumpResult::Failed &&
             !overtaken.converter->commitPrepared(
                 std::move(overtakenProof.prepared),
                 std::move(preparedBeforeEof)) &&
             preparedBeforeEof.payload && overtakenRelease == 0 &&
             overtaken.converter->stats().acceptedSamples == acceptedBeforeEof,
         "terminal state cannot admit an earlier prepared audio delivery");

  NativePcmRing reusedRing(49);
  alignas(NativeAudioConverter)
      std::array<std::byte, sizeof(NativeAudioConverter)>
          converterStorage{};
  auto sharedNative = makeSample(makeTrack(), 49, size);
  auto sameNativeAlias = aliasSample(sharedNative);
  auto firstBackend = std::make_unique<FakeBackend>();
  auto *firstConverter = ::new (converterStorage.data())
      NativeAudioConverter(reusedRing, std::move(firstBackend));
  expect(firstConverter->configure(makeTrack(), 49, nullptr),
         "first placement converter configures");
  auto staleProof = firstConverter->prepare(sharedNative, nullptr);
  firstConverter->~NativeAudioConverter();
  expect(staleProof.result == NativeAudioSubmitResult::Accepted &&
             !static_cast<bool>(staleProof.prepared) && sharedNative.payload,
         "converter destruction invalidates every outstanding prepare token");

  auto secondBackend = std::make_unique<FakeBackend>();
  auto *secondConverter = ::new (converterStorage.data())
      NativeAudioConverter(reusedRing, std::move(secondBackend));
  expect(secondConverter->configure(makeTrack(), 49, nullptr),
         "replacement converter reuses the exact object address");
  auto replacementProof = secondConverter->prepare(sameNativeAlias, nullptr);
  expect(replacementProof.result == NativeAudioSubmitResult::Accepted &&
             !secondConverter->commitPrepared(std::move(staleProof.prepared),
                                              std::move(sameNativeAlias)) &&
             sameNativeAlias.payload && !secondConverter->stats().configured,
         "address, serial, and CMSampleBuffer ABA cannot revive a stale token");
  secondConverter->~NativeAudioConverter();
}

void testExactAccurateSeekPcmTrimming() {
  const std::array<std::uint32_t, 1> size{4};
  Fixture fixture(44, makeTrack(),
                  NativeAudioGenerationTimeline{{1026, 48'000}, true, false});
  fixture.backend->setScripts({{1, 1024, true}, {1, 1024, true}});
  auto wholePreroll =
      makeSample(fixture.track, 44, size, false, true, nullptr, 0);
  setImmediatePlayoutAttachment(wholePreroll, 0);
  auto straddling =
      makeSample(fixture.track, 44, size, false, true, nullptr, 1024);
  expect(
      fixture.ready &&
          fixture.converter->submit(std::move(wholePreroll), nullptr) ==
              NativeAudioSubmitResult::Accepted &&
          fixture.converter->pump(nullptr) == NativeAudioPumpResult::Progress &&
          fixture.ring.queuedSlabs() == 0 &&
          fixture.converter->submit(std::move(straddling), nullptr) ==
              NativeAudioSubmitResult::Accepted &&
          fixture.converter->pump(nullptr) == NativeAudioPumpResult::Published,
      "accurate seek decodes whole and straddling compressed preroll");
  std::array<float, 4> output{};
  const auto consumed = fixture.ring.consume(44, output);
  const auto snapshot = fixture.converter->stats();
  expect(consumed.pcmFrames == 2 && output[0] == 205.0F &&
             output[1] == 206.0F && output[2] == 207.0F &&
             output[3] == 208.0F && snapshot.decodedPcmFrames == 2048 &&
             snapshot.discardedTrimFrames == 1026 &&
             snapshot.publishedPcmFrames == 1022 &&
             snapshot.firstPublishedFrameKnown &&
             snapshot.firstPublishedFrame == 1026,
         "only the exact PCM suffix at the requested frame reaches the ring");

  Fixture fullRing(45, makeTrack(),
                   NativeAudioGenerationTimeline{{4096, 48'000}, true, false});
  std::array<float, 2> occupied{1.0F, -1.0F};
  for (std::size_t index = 0; index < NativePcmRing::kSlabCount; ++index) {
    expect(fullRing.ring.publish(45, occupied, 1) ==
               NativePcmRing::PublishResult::Published,
           "full-ring trim fixture reserves a slab");
  }
  fullRing.backend->setScripts({{1, 1024, true}});
  auto discarded =
      makeSample(fullRing.track, 45, size, false, true, nullptr, 0);
  setImmediatePlayoutAttachment(discarded, 0);
  expect(
      fullRing.converter->submit(std::move(discarded), nullptr) ==
              NativeAudioSubmitResult::Accepted &&
          fullRing.converter->pump(nullptr) ==
              NativeAudioPumpResult::Progress &&
          fullRing.backend->convertCalls == 1 &&
          fullRing.converter->stats().discardedTrimFrames == 1024 &&
          fullRing.ring.queuedSlabs() == NativePcmRing::kSlabCount,
      "known all-preroll output can progress while the publish ring is full");

  Fixture decodeOnlyRejected(
      51, makeTrack(), NativeAudioGenerationTimeline{{4, 48'000}, true, false});
  auto decodeOnlyAudio =
      makeSample(decodeOnlyRejected.track, 51, size, true, true, nullptr, 0);
  expect(decodeOnlyRejected.converter->submit(std::move(decodeOnlyAudio),
                                              nullptr) ==
             NativeAudioSubmitResult::Invalid,
         "audio decodeOnly is never reinterpreted as accurate-seek trimming");

  Fixture refreshGate(53, makeTrack(),
                      NativeAudioGenerationTimeline{{4, 48'000}, true, false});
  auto missing =
      makeSample(refreshGate.track, 53, size, false, true, nullptr, 0);
  auto independent =
      makeSample(refreshGate.track, 53, size, false, true, nullptr, 0);
  setImmediatePlayoutAttachment(independent, 1);
  auto malformed =
      makeSample(refreshGate.track, 53, size, false, true, nullptr, 0);
  CFArrayRef sampleAttachments =
      CMSampleBufferGetSampleAttachmentsArray(nativeSample(malformed), true);
  auto first = static_cast<CFMutableDictionaryRef>(
      const_cast<void *>(CFArrayGetValueAtIndex(sampleAttachments, 0)));
  CFDictionarySetValue(
      first, kCMSampleAttachmentKey_AudioIndependentSampleDecoderRefreshCount,
      kCFBooleanFalse);
  expect(refreshGate.converter->submit(std::move(missing), nullptr) ==
                 NativeAudioSubmitResult::Invalid &&
             refreshGate.converter->submit(std::move(independent), nullptr) ==
                 NativeAudioSubmitResult::Invalid &&
             refreshGate.converter->submit(std::move(malformed), nullptr) ==
                 NativeAudioSubmitResult::Invalid &&
             refreshGate.backend->convertCalls == 0 &&
             refreshGate.ring.queuedSlabs() == 0,
         "missing, nonzero, and malformed seek refresh proofs publish no PCM");

  Fixture exactFloorGate(
      55, makeTrack(),
      NativeAudioGenerationTimeline{{4, 48'000}, false, false});
  auto floorMissing =
      makeSample(exactFloorGate.track, 55, size, false, true, nullptr, 4);
  auto floorIndependent =
      makeSample(exactFloorGate.track, 55, size, false, true, nullptr, 4);
  setImmediatePlayoutAttachment(floorIndependent, 1);
  auto floorMalformed =
      makeSample(exactFloorGate.track, 55, size, false, true, nullptr, 4);
  CFArrayRef floorAttachments = CMSampleBufferGetSampleAttachmentsArray(
      nativeSample(floorMalformed), true);
  auto floorFirst = static_cast<CFMutableDictionaryRef>(
      const_cast<void *>(CFArrayGetValueAtIndex(floorAttachments, 0)));
  CFDictionarySetValue(
      floorFirst,
      kCMSampleAttachmentKey_AudioIndependentSampleDecoderRefreshCount,
      kCFBooleanFalse);
  expect(exactFloorGate.converter->submit(std::move(floorMissing), nullptr) ==
                 NativeAudioSubmitResult::Invalid &&
             exactFloorGate.converter->submit(std::move(floorIndependent),
                                              nullptr) ==
                 NativeAudioSubmitResult::Invalid &&
             exactFloorGate.converter->submit(std::move(floorMalformed),
                                              nullptr) ==
                 NativeAudioSubmitResult::Invalid &&
             exactFloorGate.backend->convertCalls == 0 &&
             exactFloorGate.ring.queuedSlabs() == 0,
         "non-origin exact-floor starts require an immediate playout proof");

  Fixture exactFloorAccepted(
      56, makeTrack(),
      NativeAudioGenerationTimeline{{4, 48'000}, false, false});
  exactFloorAccepted.backend->setScripts({{1, 1024, true}});
  auto floorIpf = makeSample(exactFloorAccepted.track, 56, size, false, true,
                             nullptr, 4);
  setImmediatePlayoutAttachment(floorIpf, 0);
  expect(exactFloorAccepted.converter->submit(std::move(floorIpf), nullptr) ==
                 NativeAudioSubmitResult::Accepted &&
             exactFloorAccepted.converter->pump(nullptr) ==
                 NativeAudioPumpResult::Published &&
             exactFloorAccepted.ring.queuedSlabs() == 1,
         "IPF zero admits a non-origin generation starting at its exact floor");
}

void testTimelineEditsAndDecoderOverrunFailClosed() {
  const std::array<std::uint32_t, 1> size{4};
  Fixture edited(46);
  auto shifted = makeSample(edited.track, 46, size);
  expect(CMSampleBufferSetOutputPresentationTimeStamp(
             nativeSample(shifted), CMTimeMake(1, 48'000)) == noErr,
         "explicit output timeline edit fixture is installed");
  auto shiftedResult = edited.converter->prepare(shifted, nullptr);
  expect(shiftedResult.result == NativeAudioSubmitResult::Invalid &&
             shifted.payload && edited.backend->convertCalls == 0 &&
             edited.ring.queuedSlabs() == 0,
         "an unrepresented CoreMedia edit fails before audible PCM");

  Fixture continuity(47);
  continuity.backend->setScripts({{1, 1024, true}});
  auto first =
      makeSample(continuity.track, 47, size, false, true, nullptr, 0);
  auto gap =
      makeSample(continuity.track, 47, size, false, true, nullptr, 1025);
  expect(continuity.converter->submit(std::move(first), nullptr) ==
                 NativeAudioSubmitResult::Accepted &&
             continuity.converter->pump(nullptr) ==
                 NativeAudioPumpResult::Published &&
             continuity.converter->prepare(gap, nullptr).result ==
                 NativeAudioSubmitResult::Invalid &&
             gap.payload,
         "a generation timing gap is rejected before its PCM is decoded");

  Fixture overrun(48);
  overrun.backend->setScripts({{1, 1025}});
  auto tooMuch =
      makeSample(overrun.track, 48, size, false, true, nullptr, 0);
  expect(
      overrun.converter->submit(std::move(tooMuch), nullptr) ==
              NativeAudioSubmitResult::Accepted &&
          overrun.converter->pump(nullptr) == NativeAudioPumpResult::Failed &&
          overrun.converter->pump(nullptr) == NativeAudioPumpResult::Failed &&
          overrun.ring.queuedSlabs() == 0 &&
          overrun.converter->stats().decodedPcmFrames == 0 &&
          overrun.converter->stats().failed,
      "decoder output beyond the accepted frame budget fails before publish");
}

void testPartialOutputAndCapacityOne() {
  Fixture fixture(5, makeTrack(1));
  fixture.backend->setScripts({{1, 2}, {1, 1}, {0, 0, true, true}});
  const std::array<std::uint32_t, 2> sizes{3, 5};
  auto first = makeSample(fixture.track, 5, sizes);
  auto blocked = makeSample(fixture.track, 5, sizes);
  expect(
      fixture.ready &&
          fixture.converter->submit(std::move(first), nullptr) ==
              NativeAudioSubmitResult::Accepted &&
          fixture.converter->submit(std::move(blocked), nullptr) ==
              NativeAudioSubmitResult::Backpressure &&
          fixture.converter->pump(nullptr) ==
              NativeAudioPumpResult::Published &&
          fixture.converter->stats().sampleRetained &&
          fixture.converter->stats().retainedPayloadBytes == 8 &&
          fixture.converter->stats().peakRetainedPayloadBytes == 8 &&
          fixture.converter->pump(nullptr) ==
              NativeAudioPumpResult::Published &&
          fixture.converter->stats().sampleRetained &&
          fixture.converter->stats().retainedPayloadBytes == 8 &&
          fixture.converter->pump(nullptr) == NativeAudioPumpResult::Progress &&
          !fixture.converter->stats().sampleRetained &&
          fixture.converter->stats().retainedPayloadBytes == 0 &&
          fixture.converter->stats().peakRetainedPayloadBytes == 8,
      "partial conversion retains exactly one sample until all packets feed");
  std::array<float, 6> output{};
  const auto consumed = fixture.ring.consume(5, output);
  expect(consumed.pcmFrames == 3 && !consumed.underrun &&
             output[0] == output[1] && output[2] == output[3] &&
             output[4] == output[5],
         "mono is expanded to interleaved stereo across partial slabs");
}

void testRingBackpressurePrecedesConversion() {
  Fixture fixture(6);
  std::array<float, 2> frame{1.0F, -1.0F};
  for (std::size_t index = 0; index < NativePcmRing::kSlabCount; ++index) {
    expect(fixture.ring.publish(6, frame, 1) ==
               NativePcmRing::PublishResult::Published,
           "ring-full fixture publishes one slab");
  }
  fixture.backend->setScripts({{1, 1}});
  const std::array<std::uint32_t, 1> size{4};
  auto sample = makeSample(fixture.track, 6, size);
  expect(fixture.converter->submit(std::move(sample), nullptr) ==
                 NativeAudioSubmitResult::Accepted &&
             fixture.converter->pump(nullptr) ==
                 NativeAudioPumpResult::Backpressure &&
             fixture.backend->convertCalls == 0 &&
             fixture.converter->stats().sampleRetained &&
             fixture.converter->stats().retainedPayloadBytes == 4,
         "ring-full preflight advances neither input nor converter state");
  std::array<float, 2> output{};
  expect(fixture.ring.consume(6, output).pcmFrames == 1 &&
             fixture.converter->pump(nullptr) ==
                 NativeAudioPumpResult::Published &&
             fixture.backend->convertCalls == 1,
         "conversion resumes after the consumer releases capacity");
}

void testGenerationFlushCancellationAndDecodeOnlyRejection() {
  Fixture fixture(10);
  const std::array<std::uint32_t, 1> size{4};
  auto decodeOnly = makeSample(fixture.track, 10, size, true);
  std::atomic<int> releases{0};
  fixture.backend->lifecycleReleaseCounter = &releases;
  auto retained = makeSample(fixture.track, 10, size, false, true, &releases);
  expect(
      fixture.converter->submit(std::move(decodeOnly), nullptr) ==
              NativeAudioSubmitResult::Invalid &&
          fixture.converter->submit(std::move(retained), nullptr) ==
              NativeAudioSubmitResult::Accepted,
      "decode-only input fails closed and an ordinary sample may be retained");
  expect(fixture.ring.flush(11) && fixture.converter->flush(11) &&
             fixture.backend->resetCalls == 1 &&
             fixture.backend->releaseCountSeenByReset == 0 && releases == 1 &&
             fixture.converter->stats().retainedPayloadBytes == 0 &&
             fixture.converter->stats().peakRetainedPayloadBytes == 0,
         "flush resets the converter before retiring retained input");
  auto stale = makeSample(fixture.track, 10, size);
  auto current = makeSample(fixture.track, 11, size);
  expect(fixture.converter->submit(std::move(stale), nullptr) ==
                 NativeAudioSubmitResult::StaleGeneration &&
             fixture.converter->submit(std::move(current), nullptr) ==
                 NativeAudioSubmitResult::Accepted,
         "stale generation is inert after flush and current input is accepted");
  fixture.converter->cancel(10);
  expect(!fixture.converter->stats().cancelled,
         "stale cancellation cannot burn the current generation");
  fixture.converter->cancel(11);
  expect(fixture.converter->stats().cancelled &&
             !fixture.converter->stats().sampleRetained &&
             fixture.converter->stats().retainedPayloadBytes == 0 &&
             fixture.converter->stats().peakRetainedPayloadBytes == 4,
         "exact cancellation retires the retained sample");
  fixture.backend->lifecycleReleaseCounter = nullptr;
}

void testExactInputStorageLifetimeHandshake() {
  Fixture fixture(20);
  fixture.backend->setScripts(
      {{1, 1}, {0, 2}, {0, 0, true, true}, {1, 1, true}});
  const std::array<std::uint32_t, 1> size{4};
  std::atomic<int> firstRelease{0};
  auto first = makeSample(fixture.track, 20, size, false, true, &firstRelease);
  auto blocked = makeSample(fixture.track, 20, size);
  expect(fixture.converter->submit(std::move(first), nullptr) ==
                 NativeAudioSubmitResult::Accepted &&
             fixture.converter->pump(nullptr) ==
                 NativeAudioPumpResult::Published &&
             fixture.converter->stats().sampleRetained && firstRelease == 0 &&
             fixture.converter->submit(std::move(blocked), nullptr) ==
                 NativeAudioSubmitResult::Backpressure,
         "final handoff without a later callback retains its lease and "
         "backpressures");
  expect(fixture.converter->pump(nullptr) == NativeAudioPumpResult::Published &&
             fixture.converter->stats().sampleRetained && firstRelease == 0,
         "buffered PCM without an input callback cannot release prior storage");
  expect(fixture.converter->pump(nullptr) == NativeAudioPumpResult::Progress &&
             !fixture.converter->stats().sampleRetained && firstRelease == 1,
         "the later exact input callback boundary releases storage once");

  std::atomic<int> sameFillRelease{0};
  auto sameFill =
      makeSample(fixture.track, 20, size, false, true, &sameFillRelease, 1024);
  expect(fixture.converter->submit(std::move(sameFill), nullptr) ==
                 NativeAudioSubmitResult::Accepted &&
             fixture.converter->pump(nullptr) ==
                 NativeAudioPumpResult::Published &&
             !fixture.converter->stats().sampleRetained && sameFillRelease == 1,
         "a callback after final handoff in the same Fill permits immediate "
         "release");
}

void testLifecycleRetiresBackendBeforeInputStorage() {
  const std::array<std::uint32_t, 1> size{4};

  Fixture cancelled(30);
  std::atomic<int> cancelRelease{0};
  cancelled.backend->lifecycleReleaseCounter = &cancelRelease;
  auto cancelSample =
      makeSample(cancelled.track, 30, size, false, true, &cancelRelease);
  expect(cancelled.converter->submit(std::move(cancelSample), nullptr) ==
             NativeAudioSubmitResult::Accepted,
         "cancel lifetime fixture retains input");
  cancelled.converter->cancel(30);
  expect(cancelled.backend->releaseCountSeenByReset == 0 &&
             cancelRelease == 1 && cancelled.converter->stats().cancelled,
         "successful cancel reset precedes input lease retirement");
  cancelled.backend->lifecycleReleaseCounter = nullptr;

  Fixture resetFailure(31);
  std::atomic<int> failureRelease{0};
  resetFailure.backend->lifecycleReleaseCounter = &failureRelease;
  resetFailure.backend->resetSucceeds = false;
  auto failedResetSample =
      makeSample(resetFailure.track, 31, size, false, true, &failureRelease);
  expect(
      resetFailure.converter->submit(std::move(failedResetSample), nullptr) ==
          NativeAudioSubmitResult::Accepted,
      "reset-failure lifetime fixture retains input");
  resetFailure.converter->cancel(31);
  expect(
      resetFailure.backend->releaseCountSeenByReset == 0 &&
          resetFailure.backend->releaseCountSeenByClose == 0 &&
          failureRelease == 1 && !resetFailure.converter->stats().configured,
      "failed reset closes the backend before retiring input and fails closed");
  resetFailure.backend->lifecycleReleaseCounter = nullptr;

  Fixture closed(32);
  std::atomic<int> closeRelease{0};
  closed.backend->lifecycleReleaseCounter = &closeRelease;
  auto closeSample =
      makeSample(closed.track, 32, size, false, true, &closeRelease);
  expect(closed.converter->submit(std::move(closeSample), nullptr) ==
             NativeAudioSubmitResult::Accepted,
         "close lifetime fixture retains input");
  closed.converter->close();
  expect(closed.backend->releaseCountSeenByClose == 0 && closeRelease == 1 &&
             !closed.converter->stats().configured,
         "close retires the backend before releasing callback storage");
  closed.backend->lifecycleReleaseCounter = nullptr;
}

void testBoundedEofDrainAndFailures() {
  Fixture eof(12);
  eof.backend->setScripts({{1, 1024, true}, {0, 0, false, false, true}});
  const std::array<std::uint32_t, 1> size{4};
  auto exactEofSample =
      makeSample(eof.track, 12, size, false, true, nullptr, 0);
  expect(eof.converter->submit(std::move(exactEofSample), nullptr) ==
                 NativeAudioSubmitResult::Accepted &&
             eof.converter->endOfStream(12, nullptr) ==
                 NativeAudioPumpResult::Published &&
             eof.backend->convertCalls == 1 &&
             eof.converter->pump(nullptr) == NativeAudioPumpResult::Drained &&
             eof.backend->convertCalls == 2 && eof.converter->stats().drained,
         "EOF emits at most one slab per pump and reaches an explicit drain");

  Fixture eofWithInput(18);
  eofWithInput.backend->setScripts(
      {{1, 1024}, {0, 0, true, true}, {0, 0, false, false, true}});
  std::atomic<int> eofRelease{0};
  auto eofSample =
      makeSample(eofWithInput.track, 18, size, false, true, &eofRelease, 0);
  expect(eofWithInput.converter->submit(std::move(eofSample), nullptr) ==
                 NativeAudioSubmitResult::Accepted &&
             eofWithInput.converter->endOfStream(18, nullptr) ==
                 NativeAudioPumpResult::Published &&
             eofWithInput.converter->stats().sampleRetained &&
             eofWithInput.converter->pump(nullptr) ==
                 NativeAudioPumpResult::Progress &&
             eofRelease == 1 &&
             eofWithInput.converter->pump(nullptr) ==
                 NativeAudioPumpResult::Drained,
         "EOF waits for the final input callback boundary before its bounded "
         "drain");

  Fixture throwing(13);
  throwing.backend->setScripts({{0, 0, false, false, false, false, true}});
  std::atomic<int> throwRelease{0};
  throwing.backend->lifecycleReleaseCounter = &throwRelease;
  auto sample =
      makeSample(throwing.track, 13, size, false, true, &throwRelease);
  expect(
      throwing.converter->submit(std::move(sample), nullptr) ==
              NativeAudioSubmitResult::Accepted &&
          throwing.converter->pump(nullptr) == NativeAudioPumpResult::Failed &&
          throwing.converter->stats().failures == 1 &&
          throwing.converter->stats().sampleRetained && throwRelease == 0,
      "backend conversion exceptions retain storage and become typed failures");
  throwing.converter->close();
  expect(throwing.backend->releaseCountSeenByClose == 0 && throwRelease == 1,
         "closing after conversion failure retires the backend before input");
  throwing.backend->lifecycleReleaseCounter = nullptr;

  Fixture failed(17);
  failed.backend->setScripts({{0, 0, false, false, false, true}});
  auto failedSample = makeSample(failed.track, 17, size);
  expect(failed.converter->submit(std::move(failedSample), nullptr) ==
                 NativeAudioSubmitResult::Accepted &&
             failed.converter->pump(nullptr) == NativeAudioPumpResult::Failed &&
             failed.converter->stats().failures == 1,
         "backend failure results become typed failures");

  Fixture malformed(14);
  malformed.backend->setScripts(
      {{1, NativeAudioConverter::kFramesPerPump + 1}});
  auto bad = makeSample(malformed.track, 14, size);
  expect(malformed.converter->submit(std::move(bad), nullptr) ==
                 NativeAudioSubmitResult::Accepted &&
             malformed.converter->pump(nullptr) ==
                 NativeAudioPumpResult::Failed,
         "backend bound violations fail without touching the ring");
}

void testContiguousBorrowAndFragmentedFallback() {
  const std::array<std::uint32_t, 2> sizes{3, 5};
  const std::array<std::int64_t, 2> offsets{2, 7};

  Fixture contiguous(57);
  contiguous.backend->setScripts({{2, 2}, {0, 0, true, true}});
  std::atomic<int> contiguousRelease{0};
  std::atomic<std::uint64_t> contiguousCopiedBytes{0};
  auto leaseBacked = makeSample(
      contiguous.track, 57, sizes, false, true, &contiguousRelease, 0, true,
      &contiguousCopiedBytes, offsets);
  const std::span<const std::byte> originalSpan =
      leaseBacked.payload.contiguousBytes();
  const std::byte *const originalData = originalSpan.data();
  expect(originalSpan.size() == 12 && originalData != nullptr,
         "contiguous fixture exposes its exact stable native span");
  expect(contiguous.converter->submit(std::move(leaseBacked), nullptr) ==
             NativeAudioSubmitResult::Accepted,
         "stable contiguous audio is admitted without an encoded copy");
  const auto borrowedAtIngress = contiguous.converter->stats();
  expect(borrowedAtIngress.borrowedEncodedSamples == 1 &&
             borrowedAtIngress.borrowedEncodedBytes == 12 &&
             borrowedAtIngress.copiedEncodedSamples == 0 &&
             borrowedAtIngress.copiedEncodedBytes == 0 &&
             borrowedAtIngress.retainedPayloadBytes == 12 &&
             borrowedAtIngress.peakRetainedPayloadBytes == 12 &&
             contiguousCopiedBytes.load(std::memory_order_relaxed) == 0 &&
             contiguousRelease.load(std::memory_order_relaxed) == 0,
         "contiguous ingress records twelve borrowed and zero copied bytes");
  expect(contiguous.converter->pump(nullptr) ==
             NativeAudioPumpResult::Published &&
             contiguous.backend->observedBytesData == originalData &&
             contiguous.backend->observedByteCount == 12 &&
             contiguous.backend->observedPacketCount == 2 &&
             contiguous.backend->observedPackets[0].startOffset == 2 &&
             contiguous.backend->observedPackets[0].byteSize == 3 &&
             contiguous.backend->observedPackets[1].startOffset == 7 &&
             contiguous.backend->observedPackets[1].byteSize == 5 &&
             contiguous.backend->observedBytes[2] == std::byte{3} &&
             contiguous.backend->observedBytes[7] == std::byte{8} &&
             contiguous.converter->stats().sampleRetained &&
             contiguousRelease.load(std::memory_order_relaxed) == 0,
         "the backend receives the original span, offsets, and bytes under its "
         "retained lease");
  expect(contiguous.converter->pump(nullptr) ==
             NativeAudioPumpResult::Progress &&
             !contiguous.converter->stats().sampleRetained &&
             contiguous.converter->stats().retainedPayloadBytes == 0 &&
             contiguous.converter->stats().peakRetainedPayloadBytes == 12 &&
             contiguousRelease.load(std::memory_order_relaxed) == 1 &&
             contiguousCopiedBytes.load(std::memory_order_relaxed) == 0,
         "the borrowed span lease retires only at the backend release boundary");

  Fixture fragmented(58);
  fragmented.backend->setScripts({{2, 1, true}});
  std::atomic<int> fragmentedRelease{0};
  std::atomic<std::uint64_t> fragmentedCopiedBytes{0};
  auto fragmentedPayload = makeSample(
      fragmented.track, 58, sizes, false, true, &fragmentedRelease, 0, false,
      &fragmentedCopiedBytes, offsets);
  expect(fragmented.converter->submit(std::move(fragmentedPayload), nullptr) ==
             NativeAudioSubmitResult::Accepted,
         "fragmented audio is admitted through bounded copy fallback");
  const auto copiedAtIngress = fragmented.converter->stats();
  expect(copiedAtIngress.borrowedEncodedSamples == 0 &&
             copiedAtIngress.borrowedEncodedBytes == 0 &&
             copiedAtIngress.copiedEncodedSamples == 1 &&
             copiedAtIngress.copiedEncodedBytes == 12 &&
             copiedAtIngress.retainedPayloadBytes == 12 &&
             copiedAtIngress.peakRetainedPayloadBytes == 12 &&
             fragmentedCopiedBytes.load(std::memory_order_relaxed) == 12,
         "fragmented ingress records exactly one bounded twelve-byte copy");
  expect(fragmented.converter->pump(nullptr) ==
             NativeAudioPumpResult::Published &&
             fragmented.backend->observedByteCount == 12 &&
             fragmented.backend->observedPacketCount == 2 &&
             fragmented.backend->observedPackets[0].startOffset == 2 &&
             fragmented.backend->observedPackets[1].startOffset == 7 &&
             fragmented.backend->observedBytes[2] == std::byte{3} &&
             fragmented.backend->observedBytes[7] == std::byte{8} &&
             fragmentedRelease.load(std::memory_order_relaxed) == 1 &&
             !fragmented.converter->stats().sampleRetained &&
             fragmented.converter->stats().retainedPayloadBytes == 0 &&
             fragmented.converter->stats().peakRetainedPayloadBytes == 12,
         "copy fallback preserves packet offsets and retires its exact lease");
}

void testRetainedPayloadHighWaterReset() {
  Fixture fixture(59);
  const std::array<std::uint32_t, 2> sizes{3, 5};
  auto sample = makeSample(fixture.track, 59, sizes);
  expect(fixture.converter->submit(std::move(sample), nullptr) ==
             NativeAudioSubmitResult::Accepted,
         "HWM fixture retains its exact eight-byte payload");
  expect(!fixture.converter->resetRetainedPayloadByteHighWater(0) &&
             !fixture.converter->resetRetainedPayloadByteHighWater(60) &&
             fixture.converter->resetRetainedPayloadByteHighWater(59),
         "converter HWM reset rejects stale generations and accepts its owner epoch");
  auto stats = fixture.converter->stats();
  expect(stats.retainedPayloadBytes == 8 &&
             stats.peakRetainedPayloadBytes == 8,
         "converter HWM reset seeds from current retained ownership");
  fixture.converter->cancel(59);
  expect(fixture.converter->resetRetainedPayloadByteHighWater(59),
         "stopped cancelled converter permits a zero-current phase seed");
  stats = fixture.converter->stats();
  expect(stats.retainedPayloadBytes == 0 &&
             stats.peakRetainedPayloadBytes == 0,
         "zero-current reset clears only the diagnostic converter HWM");

  Fixture descending(60);
  descending.backend->setScripts({{2, 0, true, true}});
  auto eightBytes = makeSample(descending.track, 60, sizes);
  expect(descending.converter->submit(std::move(eightBytes), nullptr) ==
                 NativeAudioSubmitResult::Accepted &&
             descending.converter->pump(nullptr) ==
                 NativeAudioPumpResult::Progress,
         "descending-HWM fixture releases an eight-byte payload");
  const std::array<std::uint32_t, 1> four{4};
  auto fourBytes = makeSample(descending.track, 60, four, false, true,
                              nullptr, 2048);
  expect(descending.converter->submit(std::move(fourBytes), nullptr) ==
             NativeAudioSubmitResult::Accepted,
         "descending-HWM fixture retains a later four-byte payload");
  stats = descending.converter->stats();
  expect(stats.retainedPayloadBytes == 4 &&
             stats.peakRetainedPayloadBytes == 8,
         "converter distinguishes current ownership from its earlier HWM");
  expect(!descending.converter->resetRetainedPayloadByteHighWater(0) &&
             !descending.converter->resetRetainedPayloadByteHighWater(61),
         "rejected converter HWM resets remain inert");
  stats = descending.converter->stats();
  expect(stats.retainedPayloadBytes == 4 &&
             stats.peakRetainedPayloadBytes == 8,
         "rejected converter resets preserve current and peak independently");
  expect(descending.converter->resetRetainedPayloadByteHighWater(60),
         "exact converter HWM reset accepts its current generation");
  stats = descending.converter->stats();
  expect(stats.retainedPayloadBytes == 4 &&
             stats.peakRetainedPayloadBytes == 4,
         "exact converter reset seeds its lower current ownership");
  descending.converter->cancel(60);
  stats = descending.converter->stats();
  expect(stats.retainedPayloadBytes == 0 &&
             stats.peakRetainedPayloadBytes == 4,
         "later release clears current while retaining the seeded HWM");
}

void testFlatAllocationAfterStart() {
  Fixture fixture(15);
  fixture.backend->setScripts({{1, 4}});
  const std::array<std::uint32_t, 1> size{4};
  auto sample = makeSample(fixture.track, 15, size);
  const std::uint64_t before = allocations.load(std::memory_order_relaxed);
  const auto submitted = fixture.converter->submit(std::move(sample), nullptr);
  const auto pumped = fixture.converter->pump(nullptr);
  const auto snapshot = fixture.converter->stats();
  const std::uint64_t after = allocations.load(std::memory_order_relaxed);
  expect(submitted == NativeAudioSubmitResult::Accepted &&
             pumped == NativeAudioPumpResult::Published &&
             snapshot.producedFrames == 4 && before == after,
         "submit, conversion, publish, and stats allocate nothing after start");
}

} // namespace

void *operator new(std::size_t size) {
  allocations.fetch_add(1, std::memory_order_relaxed);
  if (void *memory = std::malloc(size)) {
    return memory;
  }
  throw std::bad_alloc();
}

void operator delete(void *memory) noexcept { std::free(memory); }
void operator delete(void *memory, std::size_t) noexcept { std::free(memory); }

int main() {
  static_assert(std::is_trivially_copyable_v<NativeAudioConverterStats>);
  static_assert(std::is_standard_layout_v<NativeAudioConverterStats>);
  static_assert(noexcept(
      std::declval<NativeAudioConverter&>()
          .resetRetainedPayloadByteHighWater(MediaGeneration{})));
  static_assert(noexcept(
      std::declval<const NativeAudioConverter&>().stats()));
  testConfigurationPacketMetadataAndAdmission();
  testTransactionalPreparePreservesExactOwnership();
  testExactAccurateSeekPcmTrimming();
  testTimelineEditsAndDecoderOverrunFailClosed();
  testPartialOutputAndCapacityOne();
  testRingBackpressurePrecedesConversion();
  testGenerationFlushCancellationAndDecodeOnlyRejection();
  testExactInputStorageLifetimeHandshake();
  testLifecycleRetiresBackendBeforeInputStorage();
  testBoundedEofDrainAndFailures();
  testContiguousBorrowAndFragmentedFallback();
  testRetainedPayloadHighWaterReset();
  testFlatAllocationAfterStart();
  if (failures != 0) {
    std::cerr << failures << " native audio converter test(s) failed\n";
    return 1;
  }
  std::cout << "native audio converter tests passed\n";
  return 0;
}
