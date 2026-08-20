#include "platform/macos/native_audio_converter.hpp"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <iostream>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <utility>
#include <vector>

namespace {

using namespace wam::macos;
using namespace wam::media;

int failures = 0;

void expect(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

// AudioToolbox swallows exactly this many leading frames from a freshly
// created Opus converter, so an Opus generation decodes this many fewer PCM
// frames than its packets declare.
constexpr std::uint64_t kOpusLeadInFrames = 120;
constexpr std::uint32_t kOpusFramesPerPacket = 960;
constexpr std::uint32_t kAacFramesPerPacket = 1024;
// OpusHead pre-skip of the fixture stream. The container therefore labels the
// first access unit at frame -312, and the head trim the converter must apply
// is preSkip - kOpusDecoderDelayFrames == 192.
constexpr std::int64_t kPreSkipFrames = 312;
constexpr std::int64_t kFirstSampleFrame = -kPreSkipFrames;
constexpr std::uint64_t kExpectedHeadTrim =
    static_cast<std::uint64_t>(kPreSkipFrames) - kOpusLeadInFrames;
constexpr std::size_t kOpusPackets = 4;
// The exact frame budget the four submitted packets declare.
constexpr std::uint64_t kOpusDeclaredFrames =
    kOpusPackets * kOpusFramesPerPacket;
// What an honest Opus decoder actually emits for that budget.
constexpr std::uint64_t kOpusDecodableFrames =
    kOpusDeclaredFrames - kOpusLeadInFrames;
constexpr std::uint32_t kPacketBytes = 8;
constexpr std::int32_t kRate = 48'000;

class SampleStorage final : public MediaPayloadStorage {
public:
  SampleStorage(CMSampleBufferRef sample, std::size_t size) noexcept
      : sample_(sample), size_(size) {}
  ~SampleStorage() override { CFRelease(sample_); }

  [[nodiscard]] std::size_t byteSize() const noexcept override { return size_; }
  [[nodiscard]] std::span<const std::byte>
  contiguousBytes() const noexcept override {
    return {};
  }
  [[nodiscard]] bool
  copyBytes(std::size_t offset,
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
};

// A 19-byte OpusHead identification header, the exact codec configuration a
// Matroska Opus track carries as its AudioMagicCookie.
std::vector<std::byte> opusHeadCookie() {
  std::vector<std::byte> cookie;
  cookie.reserve(19);
  for (const char letter : {'O', 'p', 'u', 's', 'H', 'e', 'a', 'd'}) {
    cookie.push_back(static_cast<std::byte>(letter));
  }
  cookie.push_back(std::byte{1});                             // version
  cookie.push_back(std::byte{2});                             // channels
  cookie.push_back(static_cast<std::byte>(kPreSkipFrames & 0xFF));
  cookie.push_back(static_cast<std::byte>((kPreSkipFrames >> 8) & 0xFF));
  cookie.push_back(static_cast<std::byte>(48'000 & 0xFF));    // input rate LE
  cookie.push_back(static_cast<std::byte>((48'000 >> 8) & 0xFF));
  cookie.push_back(std::byte{0});
  cookie.push_back(std::byte{0});
  cookie.push_back(std::byte{0});                             // output gain
  cookie.push_back(std::byte{0});
  cookie.push_back(std::byte{0});                             // mapping family
  return cookie;
}

MediaTrackDescriptor makeOpusTrack() {
  MediaTrackDescriptor track;
  track.id = 7;
  track.kind = MediaTrackKind::Audio;
  track.codec = MediaCodec::Opus;
  track.timeBase = {1, kRate};
  track.duration = {10, 1};
  track.codecConfigurationKind = MediaCodecConfigurationKind::AudioMagicCookie;
  track.codecConfiguration = opusHeadCookie();
  track.audio = MediaAudioFormat{48'000.0,
                                 2,
                                 kAudioFormatOpus,
                                 0,
                                 kOpusFramesPerPacket,
                                 0,
                                 0,
                                 0,
                                 kAudioChannelLayoutTag_Stereo,
                                 true,
                                 true};
  return track;
}

MediaTrackDescriptor makeAacTrack() {
  MediaTrackDescriptor track;
  track.id = 7;
  track.kind = MediaTrackKind::Audio;
  track.codec = MediaCodec::Aac;
  track.timeBase = {1, kRate};
  track.duration = {10, 1};
  track.codecConfigurationKind = MediaCodecConfigurationKind::AudioMagicCookie;
  track.codecConfiguration = {std::byte{0x12}, std::byte{0x10}};
  track.audio = MediaAudioFormat{48'000.0,
                                 2,
                                 kAudioFormatMPEG4AAC,
                                 0,
                                 kAacFramesPerPacket,
                                 0,
                                 0,
                                 0,
                                 kAudioChannelLayoutTag_Stereo,
                                 true,
                                 true};
  return track;
}

MediaSample makeSample(const MediaTrackDescriptor &track,
                       MediaGeneration generation, std::size_t packetCount,
                       std::int64_t presentationFrame) {
  const auto exactRate = static_cast<std::uint32_t>(track.audio->sampleRate);
  const std::uint32_t framesPerPacket = track.audio->framesPerPacket;
  const std::size_t byteCount = packetCount * kPacketBytes;
  AudioStreamBasicDescription asbd{};
  asbd.mSampleRate = track.audio->sampleRate;
  asbd.mFormatID = track.audio->formatTag;
  asbd.mFormatFlags = track.audio->formatFlags;
  asbd.mBytesPerPacket = track.audio->bytesPerPacket;
  asbd.mFramesPerPacket = framesPerPacket;
  asbd.mBytesPerFrame = track.audio->bytesPerFrame;
  asbd.mChannelsPerFrame = track.audio->channels;
  asbd.mBitsPerChannel = track.audio->bitsPerChannel;
  AudioChannelLayout layout{};
  layout.mChannelLayoutTag = track.audio->channelLayoutTag;
  const std::size_t layoutSize =
      offsetof(AudioChannelLayout, mChannelDescriptions);
  CMAudioFormatDescriptionRef format = nullptr;
  OSStatus status = CMAudioFormatDescriptionCreate(
      kCFAllocatorDefault, &asbd, layoutSize, &layout,
      track.codecConfiguration.size(), track.codecConfiguration.data(), nullptr,
      &format);
  expect(status == noErr && format != nullptr,
         "synthetic audio format creation succeeds");
  CMBlockBufferRef block = nullptr;
  status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr,
                                              byteCount, kCFAllocatorDefault,
                                              nullptr, 0, byteCount, 0, &block);
  expect(status == noErr && block != nullptr,
         "synthetic audio block creation succeeds");
  std::array<std::byte, 128> bytes{};
  expect(byteCount <= bytes.size(), "synthetic payload fits its fixture");
  for (std::size_t index = 0; index < byteCount; ++index) {
    bytes[index] = static_cast<std::byte>(index + 1);
  }
  status = CMBlockBufferReplaceDataBytes(bytes.data(), block, 0, byteCount);
  expect(status == noErr, "synthetic audio bytes are initialized");
  std::array<AudioStreamPacketDescription, 16> descriptions{};
  expect(packetCount <= descriptions.size(),
         "synthetic packet descriptions fit their fixture");
  for (std::size_t index = 0; index < packetCount; ++index) {
    descriptions[index] = {static_cast<std::int64_t>(index * kPacketBytes),
                           framesPerPacket, kPacketBytes};
  }
  CMSampleBufferRef nativeSample = nullptr;
  status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      kCFAllocatorDefault, block, format,
      static_cast<CMItemCount>(packetCount),
      CMTimeMake(presentationFrame, static_cast<std::int32_t>(exactRate)),
      descriptions.data(), &nativeSample);
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
  sample.duration = {static_cast<std::int64_t>(packetCount * framesPerPacket),
                     static_cast<std::int32_t>(exactRate)};
  sample.sampleCount = static_cast<std::uint32_t>(packetCount);
  sample.payload =
      MediaPayloadLease(std::make_shared<SampleStorage>(nativeSample,
                                                        byteCount));
  return sample;
}

struct Script {
  std::size_t consume{0};
  std::size_t produce{0};
  bool finalInputReleased{false};
  bool needsInput{false};
  bool drained{false};
  bool failed{false};
};

// Same shape as the frozen contract's fake backend, but its per-call frame
// production is the whole point here: every case states exactly how many PCM
// frames the decoder emits for the packets it consumed.
class FakeBackend final : public NativeAudioConverterBackend {
public:
  [[nodiscard]] bool
  configure(const NativeAudioBackendConfiguration &configuration,
            std::string *) override {
    ++configureCalls;
    configuredRate = configuration.outputSampleRate;
    configuredChannels = configuration.outputChannels;
    configuredFormatTag = configuration.input.formatTag;
    configuredFramesPerPacket = configuration.input.framesPerPacket;
    configuredLayoutTag = configuration.input.channelLayoutTag;
    cookieSize = configuration.magicCookie.size();
    return true;
  }

  [[nodiscard]] NativeAudioBackendResult
  convert(NativeAudioBackendInput input,
          std::span<float> interleavedOutput) override {
    ++convertCalls;
    observedPacketCount = input.packets.size();
    observedEof = input.endOfStream;
    const Script current =
        scripts[scriptIndex < scriptCount ? scriptIndex++ : scriptCount];
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
    return true;
  }
  void close() noexcept override { ++closeCalls; }

  void setScripts(std::initializer_list<Script> values) {
    scriptCount = values.size();
    scriptIndex = 0;
    std::copy(values.begin(), values.end(), scripts.begin());
  }

  std::array<Script, 8> scripts{};
  std::size_t scriptCount{0};
  std::size_t scriptIndex{0};
  std::size_t cookieSize{0};
  std::size_t observedPacketCount{0};
  std::uint32_t configuredRate{0};
  std::uint32_t configuredChannels{0};
  std::uint32_t configuredFormatTag{0};
  std::uint32_t configuredFramesPerPacket{0};
  std::uint32_t configuredLayoutTag{0};
  int configureCalls{0};
  int convertCalls{0};
  int resetCalls{0};
  int closeCalls{0};
  bool observedEof{false};
};

struct Fixture {
  Fixture(MediaGeneration generation, MediaTrackDescriptor value,
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

NativeAudioGenerationTimeline originTimeline() {
  NativeAudioGenerationTimeline timeline;
  timeline.presentationFloor = {0, kRate};
  timeline.trimBeforeFloor = true;
  timeline.startsAtStreamOrigin = true;
  return timeline;
}

// Feeds one Opus sample of kOpusPackets packets starting at kFirstSampleFrame
// and runs exactly one conversion that emits decodedFrames PCM frames.
NativeAudioPumpResult decodeOneOpusBlock(Fixture &fixture,
                                         MediaGeneration generation,
                                         std::uint64_t decodedFrames,
                                         std::string *error) {
  fixture.backend->setScripts({{kOpusPackets,
                                static_cast<std::size_t>(decodedFrames)},
                               {0, 0, true, true},
                               {0, 0, false, false, true}});
  auto sample = makeSample(fixture.track, generation, kOpusPackets,
                           kFirstSampleFrame);
  expect(fixture.converter->submit(std::move(sample), error) ==
             NativeAudioSubmitResult::Accepted,
         "the negative-timestamp Opus generation is admitted");
  return fixture.converter->pump(error);
}

void testOpusDecoderLeadInHeadTrim() {
  Fixture fixture(1, makeOpusTrack(), originTimeline());
  expect(fixture.ready && fixture.backend->cookieSize == 19 &&
             fixture.backend->configuredFormatTag == kAudioFormatOpus &&
             fixture.backend->configuredFramesPerPacket ==
                 kOpusFramesPerPacket &&
             fixture.backend->configuredRate == 48'000 &&
             fixture.backend->configuredChannels == 2 &&
             fixture.backend->configuredLayoutTag ==
                 kAudioChannelLayoutTag_Stereo,
         "the exact Opus ASBD, stereo layout and 19-byte OpusHead configure");

  std::string error;
  expect(decodeOneOpusBlock(fixture, 1, kOpusDecodableFrames, &error) ==
             NativeAudioPumpResult::Published,
         "an Opus block short by the decoder lead-in publishes PCM");
  const auto snapshot = fixture.converter->stats();
  expect(snapshot.decodedPcmFrames == kOpusDecodableFrames &&
             snapshot.discardedTrimFrames == kExpectedHeadTrim &&
             snapshot.publishedPcmFrames ==
                 kOpusDecodableFrames - kExpectedHeadTrim &&
             snapshot.firstPublishedFrameKnown &&
             snapshot.firstPublishedFrame == 0,
         "head trim is exactly preSkip - decoder lead-in (312 - 120 == 192) "
         "and publication starts at frame 0");
  expect(fixture.backend->observedPacketCount == kOpusPackets &&
             !fixture.backend->observedEof,
         "the whole Opus sample reached one non-terminal conversion");
  expect(snapshot.publishedPcmFrames + snapshot.discardedTrimFrames ==
             snapshot.decodedPcmFrames,
         "published + discarded == decoded across the head trim");
  expect(fixture.ring.queuedSlabs() == 1, "the published suffix reached the "
                                          "ring as one slab");

  expect(fixture.converter->pump(&error) == NativeAudioPumpResult::Progress,
         "the input-release callback boundary makes bounded progress");
  expect(fixture.converter->endOfStream(1, &error) ==
                 NativeAudioPumpResult::Drained &&
             fixture.converter->stats().drained &&
             !fixture.converter->stats().failed &&
             fixture.backend->observedEof,
         "an Opus generation that decodes declared - 120 frames drains "
         "cleanly");
  expect(fixture.converter->stats().decodedPcmFrames + kOpusLeadInFrames ==
             kOpusDeclaredFrames,
         "the clean drain identity is decoded + lead-in == accepted");
}

void testOpusTailTrimPublishesExactlyUpToTheCeiling() {
  constexpr std::uint64_t kCeilingFrame = 2048;
  auto timeline = originTimeline();
  timeline.presentationCeiling = {static_cast<std::int64_t>(kCeilingFrame),
                                  kRate};
  timeline.trimAfterCeiling = true;
  Fixture fixture(2, makeOpusTrack(), timeline);
  expect(fixture.ready, "an exactly representable ceiling configures");

  std::string error;
  expect(decodeOneOpusBlock(fixture, 2, kOpusDecodableFrames, &error) ==
             NativeAudioPumpResult::Published,
         "a ceiling-trimmed Opus block still publishes its kept prefix");
  const auto snapshot = fixture.converter->stats();
  // The block spans frames [0, 3528) after the head trim; the ceiling keeps
  // [0, 2048) and discards the remaining 1480 tail frames.
  constexpr std::uint64_t kExpectedTailTrim =
      kOpusDecodableFrames - kExpectedHeadTrim - kCeilingFrame;
  expect(snapshot.publishedPcmFrames == kCeilingFrame,
         "publication stops at exactly the ceiling frame count");
  expect(snapshot.discardedTrimFrames == kExpectedHeadTrim + kExpectedTailTrim,
         "the frames at or beyond the ceiling are charged to trim, not "
         "publication");
  expect(snapshot.decodedPcmFrames == kOpusDecodableFrames,
         "tail-trimmed frames are still counted as decoded");
  expect(snapshot.publishedPcmFrames + snapshot.discardedTrimFrames ==
             snapshot.decodedPcmFrames,
         "published + discarded == decoded across head and tail trim");

  expect(fixture.converter->pump(&error) == NativeAudioPumpResult::Progress,
         "the ceiling does not disturb the input-release boundary");
  expect(fixture.converter->endOfStream(2, &error) ==
             NativeAudioPumpResult::Drained,
         "tail trimming leaves the exact accepted-frame budget untouched");
  expect(fixture.converter->stats().decodedPcmFrames + kOpusLeadInFrames ==
             kOpusDeclaredFrames,
         "decoded + 120 == accepted at drain even with a ceiling");
}

void testInertCeilingDefaultAndRefusals() {
  // The default trimAfterCeiling is false: even a ceiling value that would cut
  // the block in half must leave publication byte-identical to the untrimmed
  // headline case.
  auto inert = originTimeline();
  inert.presentationCeiling = {2048, kRate};
  inert.trimAfterCeiling = false;
  Fixture defaulted(3, makeOpusTrack(), inert);
  std::string error;
  expect(defaulted.ready &&
             decodeOneOpusBlock(defaulted, 3, kOpusDecodableFrames, &error) ==
                 NativeAudioPumpResult::Published,
         "an inert ceiling configures and publishes");
  const auto snapshot = defaulted.converter->stats();
  expect(snapshot.publishedPcmFrames ==
                 kOpusDecodableFrames - kExpectedHeadTrim &&
             snapshot.discardedTrimFrames == kExpectedHeadTrim,
         "trimAfterCeiling == false leaves publication untouched");

  // 1/44100 s is not an integral number of frames at 48 kHz.
  auto offGrid = originTimeline();
  offGrid.presentationCeiling = {1, 44'100};
  offGrid.trimAfterCeiling = true;
  Fixture ungridded(4, makeOpusTrack(), offGrid);
  expect(!ungridded.ready && !ungridded.converter->stats().configured &&
             ungridded.backend->configureCalls == 0,
         "a ceiling off the sample-rate frame grid is refused before backend "
         "setup rather than trimmed approximately");

  NativeAudioGenerationTimeline belowFloor;
  belowFloor.presentationFloor = {480, kRate};
  belowFloor.trimBeforeFloor = true;
  belowFloor.presentationCeiling = {479, kRate};
  belowFloor.trimAfterCeiling = true;
  Fixture inverted(5, makeOpusTrack(), belowFloor);
  expect(!inverted.ready && !inverted.converter->stats().configured &&
             inverted.backend->configureCalls == 0,
         "a ceiling below the presentation floor is refused");

  NativeAudioGenerationTimeline atFloor = belowFloor;
  atFloor.presentationCeiling = {480, kRate};
  Fixture degenerate(6, makeOpusTrack(), atFloor);
  expect(degenerate.ready,
         "the refusal is exactly 'below the floor', not 'at or below'");
}

void testOpusFullDeclaredFrameCountFailsClosed() {
  // A backend that emits the full declared count has produced 120 frames the
  // generation's accepted budget cannot account for.
  Fixture overrun(7, makeOpusTrack(), originTimeline());
  std::string overrunError;
  expect(overrun.ready &&
             decodeOneOpusBlock(overrun, 7, kOpusDeclaredFrames,
                                &overrunError) ==
                 NativeAudioPumpResult::Failed,
         "an Opus backend emitting the full declared count fails the pump");
  expect(overrunError.find("exceeds its exact accepted timeline budget") !=
             std::string::npos,
         "the full declared count trips the lead-in-adjusted budget check");
  expect(overrun.converter->stats().failed &&
             overrun.converter->stats().decodedPcmFrames == 0 &&
             overrun.ring.queuedSlabs() == 0,
         "no PCM from an over-decoding Opus backend reaches the ring");
  expect(overrun.converter->pump(nullptr) == NativeAudioPumpResult::Failed,
         "the failure is terminal");

  // The mirror image: a backend that stops short of declared - 120 and then
  // claims to have drained cannot satisfy the drain identity either.
  Fixture shortfall(8, makeOpusTrack(), originTimeline());
  std::string shortfallError;
  expect(shortfall.ready &&
             decodeOneOpusBlock(shortfall, 8, kOpusDecodableFrames - 120,
                                &shortfallError) ==
                 NativeAudioPumpResult::Published &&
             shortfall.converter->pump(&shortfallError) ==
                 NativeAudioPumpResult::Progress,
         "an Opus block short of the lead-in-adjusted budget still publishes");
  expect(shortfall.converter->endOfStream(8, &shortfallError) ==
                 NativeAudioPumpResult::Failed &&
             shortfallError.find(
                 "drained before its exact timeline ended") != std::string::npos,
         "draining before decoded == accepted - lead-in fails closed");
}

void testNonOpusCodecsAreUnaffected() {
  constexpr std::size_t kAacPackets = 2;
  constexpr std::uint64_t kAacDeclaredFrames =
      kAacPackets * kAacFramesPerPacket;
  NativeAudioGenerationTimeline timeline;
  timeline.presentationFloor = {0, kRate};
  timeline.startsAtStreamOrigin = true;

  Fixture exact(9, makeAacTrack(), timeline);
  exact.backend->setScripts({{kAacPackets,
                              static_cast<std::size_t>(kAacDeclaredFrames)},
                             {0, 0, true, true},
                             {0, 0, false, false, true}});
  auto sample = makeSample(exact.track, 9, kAacPackets, 0);
  std::string error;
  expect(exact.ready &&
             exact.converter->submit(std::move(sample), &error) ==
                 NativeAudioSubmitResult::Accepted &&
             exact.converter->pump(&error) == NativeAudioPumpResult::Published,
         "an AAC generation publishes its full declared frame count");
  const auto snapshot = exact.converter->stats();
  expect(snapshot.decodedPcmFrames == kAacDeclaredFrames &&
             snapshot.publishedPcmFrames == kAacDeclaredFrames &&
             snapshot.discardedTrimFrames == 0 &&
             snapshot.firstPublishedFrameKnown &&
             snapshot.firstPublishedFrame == 0,
         "AAC has no decoder lead-in: nothing is decoded away or trimmed");
  expect(exact.converter->pump(&error) == NativeAudioPumpResult::Progress &&
             exact.converter->endOfStream(9, &error) ==
                 NativeAudioPumpResult::Drained,
         "AAC drains exactly when decoded == accepted");

  Fixture shortByLeadIn(10, makeAacTrack(), timeline);
  shortByLeadIn.backend->setScripts(
      {{kAacPackets,
        static_cast<std::size_t>(kAacDeclaredFrames - kOpusLeadInFrames)},
       {0, 0, true, true},
       {0, 0, false, false, true}});
  auto shortSample = makeSample(shortByLeadIn.track, 10, kAacPackets, 0);
  std::string shortError;
  expect(shortByLeadIn.ready &&
             shortByLeadIn.converter->submit(std::move(shortSample),
                                             &shortError) ==
                 NativeAudioSubmitResult::Accepted &&
             shortByLeadIn.converter->pump(&shortError) ==
                 NativeAudioPumpResult::Published &&
             shortByLeadIn.converter->pump(&shortError) ==
                 NativeAudioPumpResult::Progress,
         "an AAC block short by 120 frames still publishes");
  expect(shortByLeadIn.converter->endOfStream(10, &shortError) ==
             NativeAudioPumpResult::Failed,
         "the Opus lead-in allowance is not granted to AAC");
}

} // namespace

int main() {
  testOpusDecoderLeadInHeadTrim();
  testOpusTailTrimPublishesExactlyUpToTheCeiling();
  testInertCeilingDefaultAndRefusals();
  testOpusFullDeclaredFrameCountFailsClosed();
  testNonOpusCodecsAreUnaffected();
  if (failures != 0) {
    std::cerr << failures << " native audio opus converter test(s) failed\n";
    return 1;
  }
  std::cout << "native audio opus converter tests passed\n";
  return 0;
}
