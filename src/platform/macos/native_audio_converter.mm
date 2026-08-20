#include "native_audio_converter.hpp"

#include "media/matroska_opus.hpp"

#include <vector>

#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <limits>
#include <new>
#include <numeric>
#include <optional>
#include <utility>

namespace wam::macos {
namespace {

constexpr OSStatus kInputTemporarilyUnavailable = 'wamu';
constexpr std::size_t kMaximumPacketsPerFill = 16;

void assignError(std::string *error, const char *message) {
  if (error != nullptr) {
    *error = message;
  }
}

void saturatingAdd(std::uint64_t &value, std::uint64_t amount) noexcept {
  const auto maximum = std::numeric_limits<std::uint64_t>::max();
  value = amount > maximum - value ? maximum : value + amount;
}

[[nodiscard]] bool checkedAdd(std::uint64_t value, std::uint64_t amount,
                              std::uint64_t *result) noexcept {
  if (amount > std::numeric_limits<std::uint64_t>::max() - value) {
    return false;
  }
  *result = value + amount;
  return true;
}

[[nodiscard]] std::uint64_t magnitude(std::int64_t value) noexcept {
  return value < 0 ? static_cast<std::uint64_t>(-(value + 1)) + 1
                   : static_cast<std::uint64_t>(value);
}

// Converts an exact rational time to an integral output-frame coordinate
// without relying on a wide compiler extension. Reducing both factors before
// multiplication also makes overflow a checkable admission fact.
[[nodiscard]] bool exactFrame(std::int64_t value, std::int32_t timescale,
                              std::uint32_t sampleRate,
                              std::int64_t *result) noexcept {
  if (timescale <= 0 || sampleRate == 0 || result == nullptr) {
    return false;
  }
  std::uint64_t numerator = magnitude(value);
  std::uint64_t denominator = static_cast<std::uint32_t>(timescale);
  std::uint64_t rate = sampleRate;
  const std::uint64_t first = std::gcd(numerator, denominator);
  numerator /= first;
  denominator /= first;
  const std::uint64_t second = std::gcd(rate, denominator);
  rate /= second;
  denominator /= second;
  if (denominator != 1 ||
      (rate != 0 &&
       numerator > std::numeric_limits<std::uint64_t>::max() / rate)) {
    return false;
  }
  const std::uint64_t absolute = numerator * rate;
  if (value < 0) {
    constexpr std::uint64_t negativeLimit =
        std::uint64_t{1} << (std::numeric_limits<std::uint64_t>::digits - 1);
    if (absolute > negativeLimit) {
      return false;
    }
    *result = absolute == negativeLimit
                  ? std::numeric_limits<std::int64_t>::min()
                  : -static_cast<std::int64_t>(absolute);
    return true;
  }
  if (absolute >
      static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
    return false;
  }
  *result = static_cast<std::int64_t>(absolute);
  return true;
}

[[nodiscard]] bool exactFrame(media::MediaTime time, std::uint32_t sampleRate,
                              std::int64_t *result) noexcept {
  return time.valid() &&
         exactFrame(time.value, time.timescale, sampleRate, result);
}

[[nodiscard]] bool exactFrame(CMTime time, std::uint32_t sampleRate,
                              std::int64_t *result) noexcept {
  return CMTIME_IS_NUMERIC(time) && time.epoch == 0 &&
         (time.flags & kCMTimeFlags_HasBeenRounded) == 0 &&
         exactFrame(time.value, time.timescale, sampleRate, result);
}

[[nodiscard]] bool optionalFrame(CMTime time, std::uint32_t sampleRate,
                                 std::optional<std::int64_t> *result) noexcept {
  if (!CMTIME_IS_VALID(time)) {
    result->reset();
    return true;
  }
  std::int64_t frame = 0;
  if (!exactFrame(time, sampleRate, &frame)) {
    return false;
  }
  *result = frame;
  return true;
}

[[nodiscard]] bool checkedFrameEnd(std::int64_t start, std::uint64_t frames,
                                   std::int64_t *end) noexcept {
  if (frames >
      static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
    return false;
  }
  const auto signedFrames = static_cast<std::int64_t>(frames);
  if (start > std::numeric_limits<std::int64_t>::max() - signedFrames) {
    return false;
  }
  *end = start + signedFrames;
  return true;
}

[[nodiscard]] bool distanceWithin(std::int64_t start, std::int64_t end,
                                  std::uint64_t limit) noexcept {
  if (start > end) {
    return false;
  }
  if (start >= 0) {
    return static_cast<std::uint64_t>(end - start) <= limit;
  }
  if (end < 0) {
    return magnitude(start) - magnitude(end) <= limit;
  }
  const std::uint64_t beforeZero = magnitude(start);
  return beforeZero <= limit &&
         static_cast<std::uint64_t>(end) <= limit - beforeZero;
}

[[nodiscard]] bool frameDistance(std::int64_t start, std::int64_t end,
                                 std::uint64_t *distance) noexcept {
  if (start > end || distance == nullptr) {
    return false;
  }
  if (start >= 0) {
    *distance = static_cast<std::uint64_t>(end - start);
    return true;
  }
  if (end < 0) {
    *distance = magnitude(start) - magnitude(end);
    return true;
  }
  return checkedAdd(magnitude(start), static_cast<std::uint64_t>(end),
                    distance);
}

[[nodiscard]] bool supportedRate(double rate,
                                 std::uint32_t *exactRate) noexcept {
  if (!std::isfinite(rate) || rate <= 0.0 ||
      rate > media::MediaSourceLimits::kHardMaximumAudioSampleRate) {
    return false;
  }
  constexpr std::array<std::uint32_t, 4> rates{44'100, 48'000, 96'000, 192'000};
  for (const std::uint32_t candidate : rates) {
    if (rate == static_cast<double>(candidate)) {
      *exactRate = candidate;
      return true;
    }
  }
  return false;
}

[[nodiscard]] bool supportedCodec(media::MediaCodec codec,
                                  std::uint32_t formatTag) noexcept {
  switch (codec) {
  case media::MediaCodec::Aac:
    return formatTag == kAudioFormatMPEG4AAC ||
           formatTag == kAudioFormatMPEG4AAC_HE ||
           formatTag == kAudioFormatMPEG4AAC_HE_V2;
  case media::MediaCodec::Alac:
    return formatTag == kAudioFormatAppleLossless;
  case media::MediaCodec::Mp3:
    return formatTag == kAudioFormatMPEGLayer3;
  case media::MediaCodec::Opus:
    return formatTag == kAudioFormatOpus;
  default:
    return false;
  }
}

// AudioToolbox swallows exactly this many leading frames from every freshly
// created Opus converter and ignores the OpusHead pre-skip while doing it, so
// a generation decodes this many fewer frames than its packets declare. It is
// a property of the decoder, not of the container, which is why it is stated
// here and not carried in the timeline.
[[nodiscard]] std::uint32_t decoderLeadInFrames(
    media::MediaCodec codec) noexcept {
  return codec == media::MediaCodec::Opus
             ? wam::media::matroska::kOpusDecoderDelayFrames
             : 0U;
}

constexpr std::size_t kChannelLayoutPrefixBytes =
    offsetof(AudioChannelLayout, mChannelDescriptions);

struct ChannelLayoutIdentity {
  bool present{false};
  std::uint32_t tag{0};
};

[[nodiscard]] bool
supportedChannelLayout(const media::MediaAudioFormat &audio) noexcept {
  if (!audio.channelLayoutPresent) {
    return audio.channelLayoutTag == 0;
  }
  return (audio.channels == 1 &&
          audio.channelLayoutTag == kAudioChannelLayoutTag_Mono) ||
         (audio.channels == 2 &&
          audio.channelLayoutTag == kAudioChannelLayoutTag_Stereo);
}

[[nodiscard]] bool readSupportedChannelLayout(
    const AudioChannelLayout *layout, std::size_t layoutSize,
    std::uint32_t channels, ChannelLayoutIdentity *identity) noexcept {
  if (identity == nullptr) {
    return false;
  }
  if (layout == nullptr) {
    if (layoutSize != 0) {
      return false;
    }
    *identity = {};
    return true;
  }
  if (layoutSize < kChannelLayoutPrefixBytes ||
      layout->mNumberChannelDescriptions != 0 ||
      layout->mChannelBitmap != 0 ||
      (layoutSize != kChannelLayoutPrefixBytes &&
       layoutSize != sizeof(AudioChannelLayout))) {
    return false;
  }
  media::MediaAudioFormat candidate;
  candidate.channels = channels;
  candidate.channelLayoutTag = layout->mChannelLayoutTag;
  candidate.channelLayoutPresent = true;
  if (!supportedChannelLayout(candidate)) {
    return false;
  }
  *identity = {true, layout->mChannelLayoutTag};
  return true;
}

[[nodiscard]] AudioStreamBasicDescription
exactAsbd(const media::MediaAudioFormat &format) noexcept {
  AudioStreamBasicDescription result{};
  result.mSampleRate = format.sampleRate;
  result.mFormatID = format.formatTag;
  result.mFormatFlags = format.formatFlags;
  result.mBytesPerPacket = format.bytesPerPacket;
  result.mFramesPerPacket = format.framesPerPacket;
  result.mBytesPerFrame = format.bytesPerFrame;
  result.mChannelsPerFrame = format.channels;
  result.mBitsPerChannel = format.bitsPerChannel;
  return result;
}

[[nodiscard]] AudioStreamBasicDescription
floatOutputAsbd(std::uint32_t rate, std::uint32_t channels) noexcept {
  AudioStreamBasicDescription result{};
  result.mSampleRate = rate;
  result.mFormatID = kAudioFormatLinearPCM;
  result.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
  result.mBytesPerPacket = channels * sizeof(float);
  result.mFramesPerPacket = 1;
  result.mBytesPerFrame = channels * sizeof(float);
  result.mChannelsPerFrame = channels;
  result.mBitsPerChannel = 8U * sizeof(float);
  return result;
}

class CoreAudioConverterBackend final : public NativeAudioConverterBackend {
public:
  ~CoreAudioConverterBackend() override { close(); }

  [[nodiscard]] bool
  configure(const NativeAudioBackendConfiguration &configuration,
            std::string *error) override {
    close();
    input_asbd_ = exactAsbd(configuration.input);
    output_asbd_ = floatOutputAsbd(configuration.outputSampleRate,
                                   configuration.outputChannels);
    try {
      cookie_.assign(configuration.magicCookie.begin(),
                     configuration.magicCookie.end());
    } catch (...) {
      assignError(error, "AudioConverter magic cookie could not be retained");
      return false;
    }
    layout_present_ = configuration.input.channelLayoutPresent;
    layout_tag_ = configuration.input.channelLayoutTag;
    return createConverter(error);
  }

  [[nodiscard]] bool createConverter(std::string *error) {
    OSStatus status =
        AudioConverterNew(&input_asbd_, &output_asbd_, &converter_);
    if (status != noErr || converter_ == nullptr) {
      converter_ = nullptr;
      assignError(error, "AudioConverter rejected the exact input ASBD");
      return false;
    }
    // The documented Normal method requires no input pre-seek and produces no
    // output latency. Make that default explicit and verify it before any
    // compressed bytes enter the converter; a backend that cannot prove this
    // timeline identity is outside native v1.
    // AudioConverter publishes the priming property only for chains that can
    // actually prime. A same-rate decode owns no priming stage at all and
    // answers kAudioConverterErr_PropertyNotSupported, which is a stronger
    // zero-latency proof than an installed Normal method. Accept exactly that,
    // and otherwise still require Normal to read back.
    UInt32 primeMethod = kConverterPrimeMethod_Normal;
    status = AudioConverterSetProperty(converter_, kAudioConverterPrimeMethod,
                                       sizeof(primeMethod), &primeMethod);
    if (status != kAudioConverterErr_PropertyNotSupported) {
      UInt32 primeMethodSize = sizeof(primeMethod);
      UInt32 installedPrimeMethod = 0;
      if (status != noErr ||
          AudioConverterGetProperty(converter_, kAudioConverterPrimeMethod,
                                    &primeMethodSize,
                                    &installedPrimeMethod) != noErr ||
          primeMethodSize != sizeof(installedPrimeMethod) ||
          installedPrimeMethod != kConverterPrimeMethod_Normal) {
        close();
        assignError(error,
                    "AudioConverter cannot prove zero-latency normal priming");
        return false;
      }
    }
    if (!cookie_.empty()) {
      status = AudioConverterSetProperty(
          converter_, kAudioConverterDecompressionMagicCookie,
          static_cast<UInt32>(cookie_.size()), cookie_.data());
      if (status != noErr) {
        close();
        assignError(error, "AudioConverter rejected the audio magic cookie");
        return false;
      }
    }
    if (layout_present_) {
      AudioChannelLayout layout{};
      layout.mChannelLayoutTag = layout_tag_;
      status = AudioConverterSetProperty(converter_,
                                         kAudioConverterInputChannelLayout,
                                         kChannelLayoutPrefixBytes, &layout);
      if (status != noErr) {
        close();
        assignError(error, "AudioConverter rejected the channel layout tag");
        return false;
      }
    }
    return true;
  }

  [[nodiscard]] NativeAudioBackendResult
  convert(NativeAudioBackendInput input,
          std::span<float> interleavedOutput) override {
    NativeAudioBackendResult result;
    if (converter_ == nullptr || interleavedOutput.empty() ||
        interleavedOutput.size() % output_asbd_.mChannelsPerFrame != 0) {
      result.failed = true;
      return result;
    }
    InputContext context{this, input};
    UInt32 outputFrames = static_cast<UInt32>(interleavedOutput.size() /
                                              output_asbd_.mChannelsPerFrame);
    AudioBufferList output{};
    output.mNumberBuffers = 1;
    output.mBuffers[0].mNumberChannels = output_asbd_.mChannelsPerFrame;
    output.mBuffers[0].mDataByteSize =
        static_cast<UInt32>(interleavedOutput.size_bytes());
    output.mBuffers[0].mData = interleavedOutput.data();
    const OSStatus status = AudioConverterFillComplexBuffer(
        converter_, &CoreAudioConverterBackend::inputProc, &context,
        &outputFrames, &output, nullptr);
    result.consumedPackets = context.packetIndex;
    result.producedFrames = outputFrames;
    result.finalInputReleased = context.finalInputReleased;
    result.needsInput = context.needsInput;
    result.drained =
        input.endOfStream && outputFrames == 0 && context.sawEndOfStream;
    result.failed = status != noErr && status != kInputTemporarilyUnavailable;
    return result;
  }

  [[nodiscard]] bool reset(std::string *error) override {
    if (converter_ == nullptr) {
      assignError(error, "AudioConverter is not configured");
      return false;
    }
    input_storage_outstanding_ = false;
    outstanding_storage_was_final_ = false;
    // AudioConverterReset does NOT restore an Opus converter's priming state:
    // measured, a reset converter emits the decoder's 120-frame startup
    // transient as real output instead of swallowing it, so the same stream
    // decodes to a different frame count depending on whether the generation
    // was configured or flushed. Rebuilding the converter restores the single
    // invariant the whole Opus trim is derived from. Every other codec keeps
    // the cheaper reset it has always used.
    if (input_asbd_.mFormatID == kAudioFormatOpus) {
      AudioConverterDispose(converter_);
      converter_ = nullptr;
      if (!createConverter(error)) {
        return false;
      }
      return true;
    }
    if (AudioConverterReset(converter_) != noErr) {
      assignError(error, "AudioConverter reset failed");
      return false;
    }
    return true;
  }

  void close() noexcept override {
    if (converter_ != nullptr) {
      AudioConverterDispose(converter_);
      converter_ = nullptr;
    }
    cookie_.clear();
    layout_present_ = false;
    layout_tag_ = 0;
    input_storage_outstanding_ = false;
    outstanding_storage_was_final_ = false;
  }

private:
  struct InputContext {
    CoreAudioConverterBackend *owner;
    NativeAudioBackendInput input;
    std::size_t packetIndex{0};
    bool needsInput{false};
    bool sawEndOfStream{false};
    bool finalInputReleased{false};
  };

  static OSStatus
  inputProc(AudioConverterRef, UInt32 *ioNumberDataPackets,
            AudioBufferList *ioData,
            AudioStreamPacketDescription **outDataPacketDescription,
            void *userData) noexcept {
    auto &context = *static_cast<InputContext *>(userData);
    if (ioNumberDataPackets == nullptr || ioData == nullptr) {
      return kAudioConverterErr_UnspecifiedError;
    }
    // Apple permits reusing callback storage only when this callback is
    // invoked again. Record whether the storage retired at this exact boundary
    // was the final packet handoff from the wrapper's retained sample.
    if (context.owner->input_storage_outstanding_) {
      context.finalInputReleased =
          context.finalInputReleased ||
          context.owner->outstanding_storage_was_final_;
      context.owner->input_storage_outstanding_ = false;
      context.owner->outstanding_storage_was_final_ = false;
    }
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels =
        context.owner->input_asbd_.mChannelsPerFrame;
    ioData->mBuffers[0].mData = nullptr;
    ioData->mBuffers[0].mDataByteSize = 0;
    const std::size_t remaining =
        context.input.packets.size() - context.packetIndex;
    const std::size_t fillBudget =
        kMaximumPacketsPerFill -
        std::min(context.packetIndex, kMaximumPacketsPerFill);
    if (remaining == 0 || fillBudget == 0) {
      *ioNumberDataPackets = 0;
      if (context.input.endOfStream && remaining == 0) {
        context.sawEndOfStream = true;
        return noErr;
      }
      context.needsInput = remaining == 0;
      return kInputTemporarilyUnavailable;
    }
    const std::size_t supplied =
        std::min({remaining, fillBudget,
                  static_cast<std::size_t>(*ioNumberDataPackets)});
    if (supplied == 0) {
      return kInputTemporarilyUnavailable;
    }
    for (std::size_t index = 0; index < supplied; ++index) {
      const auto &source = context.input.packets[context.packetIndex + index];
      context.owner->callback_packets_[index] = {
          source.startOffset, source.variableFrames, source.byteSize};
    }
    ioData->mBuffers[0].mData =
        const_cast<std::byte *>(context.input.bytes.data());
    ioData->mBuffers[0].mDataByteSize =
        static_cast<UInt32>(context.input.bytes.size());
    if (outDataPacketDescription != nullptr) {
      *outDataPacketDescription = context.owner->callback_packets_.data();
    }
    context.packetIndex += supplied;
    context.owner->input_storage_outstanding_ = true;
    context.owner->outstanding_storage_was_final_ =
        context.packetIndex == context.input.packets.size();
    *ioNumberDataPackets = static_cast<UInt32>(supplied);
    return noErr;
  }

  AudioConverterRef converter_{nullptr};
  // Retained so the converter can be rebuilt identically on reset.
  std::vector<std::byte> cookie_;
  std::uint32_t layout_tag_{0};
  bool layout_present_{false};
  AudioStreamBasicDescription input_asbd_{};
  AudioStreamBasicDescription output_asbd_{};
  std::array<AudioStreamPacketDescription, kMaximumPacketsPerFill>
      callback_packets_{};
  bool input_storage_outstanding_{false};
  bool outstanding_storage_was_final_{false};
};

[[nodiscard]] bool falseOrAbsent(CMSampleBufferRef sample, CFStringRef key,
                                 std::string *error,
                                 const char *malformedMessage,
                                 const char *trueMessage) {
  CFTypeRef value = CMGetAttachment(sample, key, nullptr);
  if (value == nullptr) {
    return true;
  }
  if (CFGetTypeID(value) != CFBooleanGetTypeID()) {
    assignError(error, malformedMessage);
    return false;
  }
  if (CFBooleanGetValue(static_cast<CFBooleanRef>(value))) {
    assignError(error, trueMessage);
    return false;
  }
  return true;
}

[[nodiscard]] bool zeroTrimOrAbsent(CMSampleBufferRef sample, CFStringRef key,
                                    std::string *error) {
  CFTypeRef value = CMGetAttachment(sample, key, nullptr);
  if (value == nullptr) {
    return true;
  }
  if (CFGetTypeID(value) != CFDictionaryGetTypeID()) {
    assignError(error, "audio trim attachment is malformed");
    return false;
  }
  const CMTime trim =
      CMTimeMakeFromDictionary(static_cast<CFDictionaryRef>(value));
  if (!CMTIME_IS_NUMERIC(trim) || trim.epoch != 0 || trim.timescale <= 0 ||
      trim.value != 0 || (trim.flags & kCMTimeFlags_HasBeenRounded) != 0) {
    assignError(error, "nonzero audio trim is outside native v1");
    return false;
  }
  return true;
}

[[nodiscard]] bool normalSpeedOrAbsent(CMSampleBufferRef sample,
                                       std::string *error) {
  CFTypeRef value = CMGetAttachment(
      sample, kCMSampleBufferAttachmentKey_SpeedMultiplier, nullptr);
  if (value == nullptr) {
    return true;
  }
  if (CFGetTypeID(value) != CFNumberGetTypeID()) {
    assignError(error, "audio speed attachment is malformed");
    return false;
  }
  double speed = 0.0;
  if (!CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberDoubleType,
                        &speed) ||
      !std::isfinite(speed) || speed != 1.0) {
    assignError(error, "non-1.0 audio speed is outside native v1");
    return false;
  }
  return true;
}

[[nodiscard]] bool absentAttachment(CMSampleBufferRef sample, CFStringRef key,
                                    std::string *error, const char *message) {
  if (CMGetAttachment(sample, key, nullptr) == nullptr) {
    return true;
  }
  assignError(error, message);
  return false;
}

[[nodiscard]] bool immediatePlayoutFrame(CMSampleBufferRef sample,
                                         std::string *error) {
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(sample, false);
  if (attachments == nullptr || CFArrayGetCount(attachments) <= 0) {
    assignError(error,
                "accurate-seek audio lacks a decoder refresh attachment");
    return false;
  }
  auto first =
      static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
  if (first == nullptr || CFGetTypeID(first) != CFDictionaryGetTypeID()) {
    assignError(error, "audio decoder refresh attachment is malformed");
    return false;
  }
  CFTypeRef raw = CFDictionaryGetValue(
      first, kCMSampleAttachmentKey_AudioIndependentSampleDecoderRefreshCount);
  if (raw == nullptr || CFGetTypeID(raw) != CFNumberGetTypeID() ||
      CFNumberIsFloatType(static_cast<CFNumberRef>(raw))) {
    assignError(error,
                raw == nullptr
                    ? "accurate-seek audio is not an immediate playout frame"
                    : "audio decoder refresh attachment is malformed");
    return false;
  }
  std::int64_t refreshCount = -1;
  if (!CFNumberGetValue(static_cast<CFNumberRef>(raw), kCFNumberSInt64Type,
                        &refreshCount) ||
      refreshCount != 0) {
    assignError(error, "accurate-seek audio is not an immediate playout frame");
    return false;
  }
  return true;
}

[[nodiscard]] bool admissibleAttachments(CMSampleBufferRef sample,
                                         std::string *error) {
  return zeroTrimOrAbsent(
             sample, kCMSampleBufferAttachmentKey_TrimDurationAtStart, error) &&
         zeroTrimOrAbsent(
             sample, kCMSampleBufferAttachmentKey_TrimDurationAtEnd, error) &&
         normalSpeedOrAbsent(sample, error) &&
         falseOrAbsent(sample, kCMSampleBufferAttachmentKey_Reverse, error,
                       "audio reverse attachment is malformed",
                       "reverse audio is outside native v1") &&
         falseOrAbsent(
             sample,
             kCMSampleBufferAttachmentKey_FillDiscontinuitiesWithSilence, error,
             "audio silence-fill attachment is malformed",
             "semantic silence fill is outside native v1") &&
         falseOrAbsent(sample, kCMSampleBufferAttachmentKey_EmptyMedia, error,
                       "empty-media attachment is malformed",
                       "empty-media audio is outside converter ingress") &&
         falseOrAbsent(sample,
                       kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
                       error, "audio decoder-reset attachment is malformed",
                       "audio decoder reset is outside native v1") &&
         falseOrAbsent(sample, kCMSampleBufferAttachmentKey_DrainAfterDecoding,
                       error, "audio decoder-drain attachment is malformed",
                       "audio decoder drain is outside native v1") &&
         falseOrAbsent(sample, kCMSampleBufferAttachmentKey_PermanentEmptyMedia,
                       error, "permanent-empty attachment is malformed",
                       "permanent-empty audio is outside converter ingress") &&
         falseOrAbsent(sample,
                       kCMSampleBufferAttachmentKey_EndsPreviousSampleDuration,
                       error, "previous-duration attachment is malformed",
                       "deferred audio duration is outside native v1") &&
         absentAttachment(sample, kCMSampleBufferAttachmentKey_ResumeOutput,
                          error,
                          "audio resume semantics are outside native v1") &&
         absentAttachment(sample, kCMSampleBufferAttachmentKey_TransitionID,
                          error,
                          "audio transition semantics are outside native v1") &&
         absentAttachment(
             sample, kCMSampleBufferAttachmentKey_GradualDecoderRefresh, error,
             "gradual audio decoder refresh is outside native v1");
}

} // namespace

struct NativeAudioConverter::Impl {
  Impl(NativePcmRing &target,
       std::unique_ptr<NativeAudioConverterBackend> injected)
      : instance_identity(std::make_shared<const std::byte>(std::byte{})),
        ring(target),
        backend(injected ? std::move(injected)
                         : std::make_unique<CoreAudioConverterBackend>()) {}

  bool fail(std::string *error, const char *message) noexcept {
    saturatingAdd(statistics.failures, 1);
    try {
      assignError(error, message);
    } catch (...) {
    }
    return false;
  }

  bool failPump(std::string *error, const char *message) noexcept {
    failed = true;
    statistics.failed = true;
    return fail(error, message);
  }

  void clearInputMetadata() noexcept {
    encoded_data = nullptr;
    encoded_size = 0;
    encoded_borrowed = false;
    packet_count = 0;
    next_packet = 0;
    prepared_frame_count = 0;
    prepared_start_frame = 0;
    prepared_end_frame = 0;
    prepared_accepted_frames = 0;
    prepared_presentation_time = {};
    prepared_decode_time = {};
    prepared_duration = {};
    prepared_key_frame = false;
    prepared_decode_only = false;
    prepared_discontinuity = false;
    prepared_decoded_audio_frames = 0;
  }

  void clearPreparedProof() noexcept {
    prepared = false;
    prepared_serial = 0;
    prepared_native_identity = nullptr;
  }

  void abandonPrepared() noexcept {
    clearPreparedProof();
    if (!lease) {
      clearInputMetadata();
    }
  }

  void releaseSample() noexcept {
    lease.reset();
    retained_payload_bytes = 0;
    clearInputMetadata();
  }

  void clearFlow() noexcept {
    releaseSample();
    clearPreparedProof();
    awaiting_input_release = false;
    eof_requested = false;
    drained = false;
  }

  void resetExactTimeline(NativeAudioGenerationTimeline value,
                          std::int64_t floorFrame,
                          std::int64_t ceilingFrame,
                          bool ceilingKnown) noexcept {
    timeline = value;
    presentation_floor_frame = floorFrame;
    presentation_ceiling_frame = ceilingFrame;
    has_presentation_ceiling = ceilingKnown;
    has_input_timeline = false;
    expected_input_frame = 0;
    decoded_cursor_frame = 0;
    accepted_pcm_frames = 0;
    statistics.decodedPcmFrames = 0;
    statistics.discardedTrimFrames = 0;
    statistics.publishedPcmFrames = 0;
    statistics.presentationFloorFrame = floorFrame;
    statistics.firstPublishedFrame = 0;
    statistics.firstPublishedFrameKnown = false;
  }

  // The decoder swallows lead_in_frames of its own before it emits anything,
  // so a generation legitimately decodes that many fewer PCM frames than its
  // packets declare. Both invariants are stated against the same identity, so
  // lead_in_frames == 0 leaves the historic arithmetic byte-identical.
  [[nodiscard]] bool decodedWithinBudget(std::uint64_t decoded) const noexcept {
    return lead_in_frames <= accepted_pcm_frames &&
           decoded <= accepted_pcm_frames - lead_in_frames;
  }

  [[nodiscard]] bool decodedBudgetExhausted(
      std::uint64_t decoded) const noexcept {
    return lead_in_frames <= accepted_pcm_frames &&
           decoded == accepted_pcm_frames - lead_in_frames;
  }

  void failClosedProtocol() noexcept {
    saturatingAdd(statistics.failures, 1);
    try {
      backend->close();
    } catch (...) {
    }
    clearFlow();
    configured = false;
    failed = true;
    statistics.configured = false;
    statistics.failed = true;
  }

  [[nodiscard]] bool formatMatches(CMSampleBufferRef sample) const noexcept {
    CMFormatDescriptionRef raw = CMSampleBufferGetFormatDescription(sample);
    if (raw == nullptr ||
        CMFormatDescriptionGetMediaType(raw) != kCMMediaType_Audio) {
      return false;
    }
    auto format = static_cast<CMAudioFormatDescriptionRef>(raw);
    const AudioStreamBasicDescription *asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(format);
    if (asbd == nullptr || asbd->mSampleRate != audio.sampleRate ||
        asbd->mFormatID != audio.formatTag ||
        asbd->mFormatFlags != audio.formatFlags ||
        asbd->mBytesPerPacket != audio.bytesPerPacket ||
        asbd->mFramesPerPacket != audio.framesPerPacket ||
        asbd->mBytesPerFrame != audio.bytesPerFrame ||
        asbd->mChannelsPerFrame != audio.channels ||
        asbd->mBitsPerChannel != audio.bitsPerChannel) {
      return false;
    }
    std::size_t cookieLength = 0;
    const void *cookie =
        CMAudioFormatDescriptionGetMagicCookie(format, &cookieLength);
    if (cookieLength != cookie_size ||
        (cookieLength != 0 &&
         (cookie == nullptr ||
          std::memcmp(cookie, cookie_storage.data(), cookieLength) != 0))) {
      return false;
    }
    std::size_t layoutSize = 0;
    const AudioChannelLayout *layout =
        CMAudioFormatDescriptionGetChannelLayout(format, &layoutSize);
    ChannelLayoutIdentity layoutIdentity;
    return readSupportedChannelLayout(layout, layoutSize, audio.channels,
                                      &layoutIdentity) &&
           layoutIdentity.present == audio.channelLayoutPresent &&
           layoutIdentity.tag == audio.channelLayoutTag;
  }

  [[nodiscard]] bool loadPacketDescriptions(CMSampleBufferRef sample,
                                            std::size_t sampleCount,
                                            std::size_t byteCount,
                                            std::uint64_t *totalFrames,
                                            std::string *error) noexcept {
    std::uint64_t frameTotal = 0;
    const auto recordFrames = [&](std::size_t index,
                                  std::uint32_t variableFrames) noexcept {
      const std::uint32_t frames =
          variableFrames != 0 ? variableFrames : audio.framesPerPacket;
      std::uint64_t nextTotal = 0;
      if (frames == 0 || !checkedAdd(frameTotal, frames, &nextTotal)) {
        return false;
      }
      packet_frames[index] = frames;
      frameTotal = nextTotal;
      return true;
    };
    const AudioStreamPacketDescription *source = nullptr;
    std::size_t sourceBytes = 0;
    const OSStatus status = CMSampleBufferGetAudioStreamPacketDescriptionsPtr(
        sample, &source, &sourceBytes);
    if (status != noErr) {
      return fail(error, "CoreMedia packet descriptions are unavailable");
    }
    if (source == nullptr && sourceBytes == 0) {
      if (audio.bytesPerPacket == 0 ||
          sampleCount > byteCount / audio.bytesPerPacket ||
          sampleCount * audio.bytesPerPacket != byteCount) {
        return fail(error,
                    "variable compressed audio requires packet descriptions");
      }
      for (std::size_t index = 0; index < sampleCount; ++index) {
        packets[index] = {
            static_cast<std::int64_t>(index * audio.bytesPerPacket),
            audio.bytesPerPacket, 0};
        if (!recordFrames(index, 0)) {
          return fail(error, "audio packet frame count is not exact");
        }
      }
      packet_count = sampleCount;
      *totalFrames = frameTotal;
      return true;
    }
    if (source == nullptr ||
        sourceBytes != sampleCount * sizeof(AudioStreamPacketDescription)) {
      return fail(error, "audio packet description count is not exact");
    }
    std::uint64_t priorEnd = 0;
    for (std::size_t index = 0; index < sampleCount; ++index) {
      const auto &packet = source[index];
      if (packet.mStartOffset < 0 || packet.mDataByteSize == 0) {
        return fail(error, "audio packet description is malformed");
      }
      const std::uint64_t start =
          static_cast<std::uint64_t>(packet.mStartOffset);
      if (start < priorEnd || start > byteCount ||
          packet.mDataByteSize > byteCount - start) {
        return fail(error, "audio packet description exceeds its payload");
      }
      packets[index] = {packet.mStartOffset, packet.mDataByteSize,
                        packet.mVariableFramesInPacket};
      if (!recordFrames(index, packet.mVariableFramesInPacket)) {
        return fail(error, "audio packet frame count is not exact");
      }
      priorEnd = start + packet.mDataByteSize;
    }
    packet_count = sampleCount;
    *totalFrames = frameTotal;
    return true;
  }

  [[nodiscard]] bool
  timingAt(const std::array<CMSampleTimingInfo,
                            NativeAudioConverter::kMaximumPackets> &entries,
           std::size_t entryCount, std::size_t index, std::uint64_t priorFrames,
           std::int64_t *presentation, std::optional<std::int64_t> *decode,
           std::uint64_t *durationFrames, std::string *error) noexcept {
    const CMSampleTimingInfo &timing = entries[entryCount == 1 ? 0 : index];
    std::int64_t duration = 0;
    std::int64_t basePresentation = 0;
    std::optional<std::int64_t> baseDecode;
    if (!exactFrame(timing.duration, sample_rate, &duration) || duration <= 0 ||
        !exactFrame(timing.presentationTimeStamp, sample_rate,
                    &basePresentation) ||
        !optionalFrame(timing.decodeTimeStamp, sample_rate, &baseDecode)) {
      assignError(error, "CoreMedia audio timing is not frame-exact");
      return false;
    }
    *durationFrames = static_cast<std::uint64_t>(duration);
    if (entryCount != 1) {
      *presentation = basePresentation;
      *decode = baseDecode;
      return true;
    }
    if (!checkedFrameEnd(basePresentation, priorFrames, presentation)) {
      assignError(error, "CoreMedia audio timing overflows its frame range");
      return false;
    }
    if (!baseDecode) {
      decode->reset();
      return true;
    }
    std::int64_t expandedDecode = 0;
    if (!checkedFrameEnd(*baseDecode, priorFrames, &expandedDecode)) {
      assignError(error,
                  "CoreMedia audio decode timing overflows its frame range");
      return false;
    }
    *decode = expandedDecode;
    return true;
  }

  [[nodiscard]] bool validateTiming(CMSampleBufferRef sample,
                                    const media::MediaSample &neutral,
                                    std::uint64_t totalFrames,
                                    std::int64_t *sampleStart,
                                    std::string *error) noexcept {
    CMItemCount inputCount = 0;
    CMItemCount outputCount = 0;
    const auto capacity = static_cast<CMItemCount>(input_timing.size());
    if (CMSampleBufferGetSampleTimingInfoArray(
            sample, capacity, input_timing.data(), &inputCount) != noErr ||
        CMSampleBufferGetOutputSampleTimingInfoArray(
            sample, capacity, output_timing.data(), &outputCount) != noErr ||
        (inputCount != 1 && inputCount != neutral.sampleCount) ||
        (outputCount != 1 && outputCount != neutral.sampleCount)) {
      assignError(error,
                  "CoreMedia audio sample timing is unavailable or unbounded");
      return false;
    }

    std::uint64_t priorFrames = 0;
    std::int64_t expectedPresentation = 0;
    std::optional<std::int64_t> firstDecode;
    for (std::size_t index = 0; index < neutral.sampleCount; ++index) {
      std::int64_t inputPresentation = 0;
      std::int64_t outputPresentation = 0;
      std::optional<std::int64_t> inputDecode;
      std::optional<std::int64_t> outputDecode;
      std::uint64_t inputDuration = 0;
      std::uint64_t outputDuration = 0;
      if (!timingAt(input_timing, static_cast<std::size_t>(inputCount), index,
                    priorFrames, &inputPresentation, &inputDecode,
                    &inputDuration, error) ||
          !timingAt(output_timing, static_cast<std::size_t>(outputCount), index,
                    priorFrames, &outputPresentation, &outputDecode,
                    &outputDuration, error) ||
          inputDuration != packet_frames[index] ||
          outputDuration != packet_frames[index] ||
          inputPresentation != outputPresentation ||
          inputDecode != outputDecode ||
          (inputDecode && *inputDecode != inputPresentation)) {
        if (error != nullptr && error->empty()) {
          assignError(error,
                      "CoreMedia audio input/output timing contains an edit");
        }
        return false;
      }
      if (index == 0) {
        *sampleStart = inputPresentation;
        expectedPresentation = inputPresentation;
        firstDecode = inputDecode;
      }
      if (inputPresentation != expectedPresentation ||
          !checkedFrameEnd(expectedPresentation, packet_frames[index],
                           &expectedPresentation)) {
        assignError(error, "CoreMedia audio packets are not contiguous");
        return false;
      }
      priorFrames += packet_frames[index];
    }
    if (priorFrames != totalFrames) {
      assignError(error, "CoreMedia audio packet duration is inconsistent");
      return false;
    }

    std::int64_t neutralPresentation = 0;
    std::int64_t neutralDuration = 0;
    std::optional<std::int64_t> neutralDecode;
    if (!exactFrame(neutral.presentationTime, sample_rate,
                    &neutralPresentation) ||
        !exactFrame(neutral.duration, sample_rate, &neutralDuration) ||
        neutralDuration <= 0 ||
        static_cast<std::uint64_t>(neutralDuration) != totalFrames) {
      assignError(error, "neutral audio timing is not frame-exact");
      return false;
    }
    if (neutral.decodeTime.valid()) {
      std::int64_t value = 0;
      if (!exactFrame(neutral.decodeTime, sample_rate, &value)) {
        assignError(error, "neutral audio decode time is not frame-exact");
        return false;
      }
      neutralDecode = value;
    } else if (neutral.decodeTime.value != 0 ||
               neutral.decodeTime.timescale != 0) {
      assignError(error, "neutral audio decode time is malformed");
      return false;
    }

    std::int64_t aggregatePresentation = 0;
    std::int64_t outputPresentation = 0;
    std::int64_t aggregateDuration = 0;
    std::int64_t outputDuration = 0;
    std::optional<std::int64_t> aggregateDecode;
    std::optional<std::int64_t> outputDecode;
    if (!exactFrame(CMSampleBufferGetPresentationTimeStamp(sample), sample_rate,
                    &aggregatePresentation) ||
        !exactFrame(CMSampleBufferGetOutputPresentationTimeStamp(sample),
                    sample_rate, &outputPresentation) ||
        !exactFrame(CMSampleBufferGetDuration(sample), sample_rate,
                    &aggregateDuration) ||
        !exactFrame(CMSampleBufferGetOutputDuration(sample), sample_rate,
                    &outputDuration) ||
        !optionalFrame(CMSampleBufferGetDecodeTimeStamp(sample), sample_rate,
                       &aggregateDecode) ||
        !optionalFrame(CMSampleBufferGetOutputDecodeTimeStamp(sample),
                       sample_rate, &outputDecode) ||
        aggregatePresentation != *sampleStart ||
        outputPresentation != *sampleStart || aggregateDuration <= 0 ||
        outputDuration != aggregateDuration ||
        static_cast<std::uint64_t>(aggregateDuration) != totalFrames ||
        aggregateDecode != firstDecode || outputDecode != firstDecode ||
        neutralPresentation != *sampleStart || neutralDecode != firstDecode) {
      assignError(error,
                  "CoreMedia and neutral audio timelines are not identical");
      return false;
    }
    return true;
  }

  std::shared_ptr<const void> instance_identity;
  NativePcmRing &ring;
  std::unique_ptr<NativeAudioConverterBackend> backend;
  std::array<std::byte, NativeAudioConverter::kMaximumEncodedBytes>
      encoded_storage{};
  std::array<NativeAudioPacketDescription,
             NativeAudioConverter::kMaximumPackets>
      packets{};
  std::array<std::uint32_t, NativeAudioConverter::kMaximumPackets>
      packet_frames{};
  std::array<CMSampleTimingInfo, NativeAudioConverter::kMaximumPackets>
      input_timing{};
  std::array<CMSampleTimingInfo, NativeAudioConverter::kMaximumPackets>
      output_timing{};
  std::array<std::byte,
             media::MediaSourceLimits::kHardMaximumCodecConfigurationBytes>
      cookie_storage{};
  std::array<float,
             NativeAudioConverter::kFramesPerPump * NativePcmRing::kChannels>
      pcm{};
  media::MediaPayloadLease lease;
  const std::byte *encoded_data{nullptr};
  media::MediaAudioFormat audio{};
  media::MediaTime prepared_presentation_time{};
  media::MediaTime prepared_decode_time{};
  media::MediaTime prepared_duration{};
  NativeAudioGenerationTimeline timeline{};
  NativeAudioConverterStats statistics{};
  media::MediaTrackId track{0};
  std::size_t cookie_size{0};
  std::size_t encoded_size{0};
  std::size_t retained_payload_bytes{0};
  std::size_t peak_retained_payload_bytes{0};
  std::size_t packet_count{0};
  std::size_t next_packet{0};
  std::uint32_t sample_rate{0};
  std::uint64_t next_prepare_serial{1};
  std::uint64_t prepared_serial{0};
  const void *prepared_native_identity{nullptr};
  std::uint64_t prepared_frame_count{0};
  std::uint64_t prepared_accepted_frames{0};
  std::uint64_t accepted_pcm_frames{0};
  std::int64_t presentation_floor_frame{0};
  std::int64_t expected_input_frame{0};
  std::int64_t decoded_cursor_frame{0};
  std::int64_t prepared_start_frame{0};
  std::int64_t prepared_end_frame{0};
  std::int64_t presentation_ceiling_frame{0};
  std::uint32_t lead_in_frames{0};
  bool has_presentation_ceiling{false};
  bool encoded_borrowed{false};
  bool configured{false};
  bool cancelled{false};
  bool failed{false};
  bool prepared{false};
  bool prepared_key_frame{false};
  bool prepared_decode_only{false};
  bool prepared_discontinuity{false};
  std::uint32_t prepared_decoded_audio_frames{0};
  bool has_input_timeline{false};
  bool awaiting_input_release{false};
  bool eof_requested{false};
  bool drained{false};
};

NativeAudioConverter::NativeAudioConverter(
    NativePcmRing &ring, std::unique_ptr<NativeAudioConverterBackend> backend)
    : impl_(std::make_unique<Impl>(ring, std::move(backend))) {}

NativeAudioConverter::~NativeAudioConverter() { close(); }

namespace {

// Resolves the tail-trim ceiling to an exact frame index. A generation that
// declares a ceiling it cannot express exactly is refused rather than trimmed
// approximately.
[[nodiscard]] bool resolveCeiling(const NativeAudioGenerationTimeline &timeline,
                                  std::uint32_t sampleRate,
                                  std::int64_t floorFrame,
                                  std::int64_t *ceilingFrame,
                                  bool *ceilingKnown) noexcept {
  if (!timeline.trimAfterCeiling) {
    *ceilingFrame = 0;
    *ceilingKnown = false;
    return true;
  }
  std::int64_t frame = 0;
  if (!exactFrame(timeline.presentationCeiling, sampleRate, &frame) ||
      frame < floorFrame) {
    return false;
  }
  *ceilingFrame = frame;
  *ceilingKnown = true;
  return true;
}

} // namespace

bool NativeAudioConverter::configure(const media::MediaTrackDescriptor &track,
                                     media::MediaGeneration generation,
                                     std::string *error) {
  return configure(track, generation, NativeAudioGenerationTimeline{}, error);
}

bool NativeAudioConverter::configure(const media::MediaTrackDescriptor &track,
                                     media::MediaGeneration generation,
                                     NativeAudioGenerationTimeline timeline,
                                     std::string *error) {
  auto &state = *impl_;
  std::uint32_t candidateSampleRate = 0;
  std::int64_t candidateFloorFrame = 0;
  std::int64_t candidateCeilingFrame = 0;
  bool candidateCeilingKnown = false;
  if (generation == 0 || state.ring.generation() != generation ||
      track.id == 0 || track.kind != media::MediaTrackKind::Audio ||
      !track.audio || !supportedCodec(track.codec, track.audio->formatTag) ||
      (track.audio->channels != 1 && track.audio->channels != 2) ||
      !track.audio->interleaved || track.audio->framesPerPacket == 0 ||
      !supportedChannelLayout(*track.audio) ||
      !supportedRate(track.audio->sampleRate, &candidateSampleRate) ||
      !exactFrame(timeline.presentationFloor, candidateSampleRate,
                  &candidateFloorFrame) ||
      !resolveCeiling(timeline, candidateSampleRate, candidateFloorFrame,
                      &candidateCeilingFrame, &candidateCeilingKnown) ||
      track.codecConfiguration.size() > state.cookie_storage.size() ||
      (!track.codecConfiguration.empty() &&
       track.codecConfigurationKind !=
           media::MediaCodecConfigurationKind::AudioMagicCookie) ||
      (track.codecConfiguration.empty() &&
       track.codecConfigurationKind !=
           media::MediaCodecConfigurationKind::None)) {
    return state.fail(error, "audio track is outside native converter v1");
  }
  state.backend->close();
  state.clearFlow();
  state.configured = false;
  state.cancelled = false;
  state.failed = false;
  NativeAudioBackendConfiguration configuration{
      *track.audio, track.codecConfiguration, track.audio->channels,
      candidateSampleRate};
  try {
    if (!state.backend->configure(configuration, error)) {
      state.backend->close();
      state.audio = {};
      state.track = 0;
      state.cookie_size = 0;
      state.sample_rate = 0;
      state.statistics.configured = false;
      return state.fail(error, "native audio backend configuration failed");
    }
  } catch (...) {
    state.backend->close();
    state.audio = {};
    state.track = 0;
    state.cookie_size = 0;
    state.sample_rate = 0;
    state.statistics.configured = false;
    return state.fail(error, "native audio backend configuration threw");
  }
  state.audio = *track.audio;
  state.track = track.id;
  state.cookie_size = track.codecConfiguration.size();
  state.sample_rate = candidateSampleRate;
  std::copy(track.codecConfiguration.begin(), track.codecConfiguration.end(),
            state.cookie_storage.begin());
  state.configured = true;
  state.failed = false;
  state.statistics = {};
  state.peak_retained_payload_bytes = state.retained_payload_bytes;
  state.statistics.configured = true;
  state.statistics.generation = generation;
  state.statistics.sampleRate = state.sample_rate;
  state.statistics.sourceChannels = state.audio.channels;
  state.lead_in_frames = decoderLeadInFrames(track.codec);
  state.resetExactTimeline(timeline, candidateFloorFrame, candidateCeilingFrame,
                           candidateCeilingKnown);
  return true;
}

NativeAudioPrepareOutcome
NativeAudioConverter::prepare(const media::MediaSample &sample,
                              std::string *error) {
  NativeAudioPrepareOutcome outcome;
  auto &state = *impl_;
  if (!state.configured || state.cancelled || state.failed) {
    state.fail(error, "native audio converter is not accepting samples");
    outcome.result = NativeAudioSubmitResult::Failed;
    return outcome;
  }
  if (sample.generation != state.statistics.generation) {
    saturatingAdd(state.statistics.staleSamples, 1);
    outcome.result = NativeAudioSubmitResult::StaleGeneration;
    return outcome;
  }
  if (state.lease || state.prepared) {
    saturatingAdd(state.statistics.backpressuredSamples, 1);
    outcome.result = NativeAudioSubmitResult::Backpressure;
    return outcome;
  }
  if (state.eof_requested || state.drained || sample.track != state.track ||
      sample.kind != media::MediaSampleKind::EncodedAudio ||
      sample.discontinuity || sample.sampleCount == 0 ||
      sample.sampleCount > kMaximumPackets || !sample.payload ||
      sample.payload.byteSize() == 0 ||
      sample.payload.byteSize() > kMaximumEncodedBytes) {
    saturatingAdd(state.statistics.rejectedSamples, 1);
    assignError(error, "encoded audio sample is outside native v1");
    outcome.result = NativeAudioSubmitResult::Invalid;
    return outcome;
  }
  const auto borrowed =
      sample.payload
          .borrowNative<media::NativePayloadKind::CoreMediaSampleBuffer>();
  if (!borrowed) {
    saturatingAdd(state.statistics.rejectedSamples, 1);
    assignError(error, "native audio requires a CoreMedia sample lease");
    outcome.result = NativeAudioSubmitResult::Invalid;
    return outcome;
  }
  auto nativeSample = static_cast<CMSampleBufferRef>(
      const_cast<void *>(borrowed->opaqueAddress()));
  const CMItemCount nativeCount = CMSampleBufferGetNumSamples(nativeSample);
  if (!CMSampleBufferDataIsReady(nativeSample) || nativeCount <= 0 ||
      static_cast<std::uint64_t>(nativeCount) != sample.sampleCount ||
      !state.formatMatches(nativeSample) ||
      !admissibleAttachments(nativeSample, error)) {
    saturatingAdd(state.statistics.rejectedSamples, 1);
    if (error != nullptr && error->empty()) {
      assignError(error, "CoreMedia audio metadata does not match its track");
    }
    outcome.result = NativeAudioSubmitResult::Invalid;
    return outcome;
  }
  const std::size_t byteCount = sample.payload.byteSize();
  std::uint64_t totalFrames = 0;
  std::int64_t sampleStart = 0;
  std::int64_t sampleEnd = 0;
  if (!state.loadPacketDescriptions(nativeSample, sample.sampleCount, byteCount,
                                    &totalFrames, error) ||
      !state.validateTiming(nativeSample, sample, totalFrames, &sampleStart,
                            error) ||
      !checkedFrameEnd(sampleStart, totalFrames, &sampleEnd)) {
    state.clearInputMetadata();
    saturatingAdd(state.statistics.rejectedSamples, 1);
    if (error != nullptr && error->empty()) {
      assignError(error, "audio sample timeline is not exactly representable");
    }
    outcome.result = NativeAudioSubmitResult::Invalid;
    return outcome;
  }

  constexpr std::uint64_t maximumPrerollSeconds = 12;
  const std::uint64_t maximumPrerollFrames =
      maximumPrerollSeconds * state.sample_rate;
  const bool timelineAdmissible =
      state.has_input_timeline ? sampleStart == state.expected_input_frame
      : state.timeline.trimBeforeFloor
          ? sampleStart <= state.presentation_floor_frame &&
                distanceWithin(sampleStart, state.presentation_floor_frame,
                               maximumPrerollFrames)
          : sampleStart == state.presentation_floor_frame;
  const bool needsRefreshProof =
      !state.timeline.startsAtStreamOrigin && !state.has_input_timeline;
  std::uint64_t acceptedAfter = 0;
  if (!timelineAdmissible || sample.decodeOnly ||
      (needsRefreshProof && !immediatePlayoutFrame(nativeSample, error)) ||
      !checkedAdd(state.accepted_pcm_frames, totalFrames, &acceptedAfter)) {
    state.clearInputMetadata();
    saturatingAdd(state.statistics.rejectedSamples, 1);
    assignError(error,
                "audio sample does not continue the exact generation timeline");
    outcome.result = NativeAudioSubmitResult::Invalid;
    return outcome;
  }

  const std::span<const std::byte> contiguous =
      sample.payload.contiguousBytes();
  const bool borrowContiguous = contiguous.size() == byteCount;
  if (borrowContiguous) {
    state.encoded_data = contiguous.data();
    state.encoded_borrowed = true;
  } else {
    if (!sample.payload.copyBytes(
            0,
            std::span<std::byte>(state.encoded_storage.data(), byteCount))) {
      state.clearInputMetadata();
      saturatingAdd(state.statistics.rejectedSamples, 1);
      assignError(error, "CoreMedia audio payload copy failed");
      outcome.result = NativeAudioSubmitResult::Invalid;
      return outcome;
    }
    state.encoded_data = state.encoded_storage.data();
    state.encoded_borrowed = false;
  }
  if (state.next_prepare_serial == 0) {
    state.clearInputMetadata();
    state.failPump(error, "native audio prepare serial space is exhausted");
    outcome.result = NativeAudioSubmitResult::Failed;
    return outcome;
  }
  state.encoded_size = byteCount;
  state.next_packet = 0;
  state.prepared_frame_count = totalFrames;
  state.prepared_accepted_frames = acceptedAfter;
  state.prepared_start_frame = sampleStart;
  state.prepared_end_frame = sampleEnd;
  state.prepared_presentation_time = sample.presentationTime;
  state.prepared_decode_time = sample.decodeTime;
  state.prepared_duration = sample.duration;
  state.prepared_key_frame = sample.keyFrame;
  state.prepared_decode_only = sample.decodeOnly;
  state.prepared_discontinuity = sample.discontinuity;
  state.prepared_decoded_audio_frames = sample.decodedAudioFrames;
  state.prepared_serial = state.next_prepare_serial;
  state.prepared_native_identity = borrowed->opaqueAddress();
  state.prepared = true;
  if (state.encoded_borrowed) {
    saturatingAdd(state.statistics.borrowedEncodedSamples, 1);
    saturatingAdd(state.statistics.borrowedEncodedBytes, byteCount);
  } else {
    saturatingAdd(state.statistics.copiedEncodedSamples, 1);
    saturatingAdd(state.statistics.copiedEncodedBytes, byteCount);
  }
  state.next_prepare_serial =
      state.next_prepare_serial == std::numeric_limits<std::uint64_t>::max()
          ? 0
          : state.next_prepare_serial + 1;
  outcome.result = NativeAudioSubmitResult::Accepted;
  outcome.prepared.instance_ = state.instance_identity;
  outcome.prepared.owner_ = this;
  outcome.prepared.serial_ = state.prepared_serial;
  outcome.prepared.native_identity_ = state.prepared_native_identity;
  return outcome;
}

bool NativeAudioConverter::commitPrepared(
    NativeAudioPreparedSample &&prepared,
    media::MediaSample &&sample) noexcept {
  auto &state = *impl_;
  const std::shared_ptr<const void> preparedInstance =
      prepared.instance_.lock();
  const auto borrowed =
      sample.payload
          .borrowNative<media::NativePayloadKind::CoreMediaSampleBuffer>();
  const std::span<const std::byte> committedContiguous =
      state.encoded_borrowed ? sample.payload.contiguousBytes()
                             : std::span<const std::byte>{};
  std::int64_t sampleStart = 0;
  std::int64_t sampleDuration = 0;
  const bool matches =
      state.configured && !state.cancelled && !state.failed &&
      !state.eof_requested && !state.drained && state.prepared &&
      !state.lease && preparedInstance &&
      preparedInstance == state.instance_identity && prepared.owner_ == this &&
      prepared.serial_ != 0 && prepared.serial_ == state.prepared_serial &&
      prepared.native_identity_ == state.prepared_native_identity && borrowed &&
      borrowed->opaqueAddress() == state.prepared_native_identity &&
      sample.generation == state.statistics.generation &&
      sample.track == state.track &&
      sample.kind == media::MediaSampleKind::EncodedAudio &&
      sample.sampleCount == state.packet_count &&
      sample.presentationTime == state.prepared_presentation_time &&
      sample.decodeTime == state.prepared_decode_time &&
      sample.duration == state.prepared_duration &&
      sample.keyFrame == state.prepared_key_frame &&
      sample.decodeOnly == state.prepared_decode_only &&
      sample.discontinuity == state.prepared_discontinuity &&
      sample.decodedAudioFrames == state.prepared_decoded_audio_frames &&
      sample.payload.byteSize() == state.encoded_size &&
      (!state.encoded_borrowed ||
       (committedContiguous.size() == state.encoded_size &&
        committedContiguous.data() == state.encoded_data)) &&
      exactFrame(sample.presentationTime, state.sample_rate, &sampleStart) &&
      exactFrame(sample.duration, state.sample_rate, &sampleDuration) &&
      sampleDuration > 0 && sampleStart == state.prepared_start_frame &&
      static_cast<std::uint64_t>(sampleDuration) == state.prepared_frame_count;
  prepared.instance_.reset();
  prepared.owner_ = nullptr;
  prepared.serial_ = 0;
  prepared.native_identity_ = nullptr;
  if (!matches) {
    state.failClosedProtocol();
    return false;
  }

  const std::size_t retainedBytes = state.encoded_size;
  state.lease = std::move(sample.payload);
  state.retained_payload_bytes = retainedBytes;
  state.peak_retained_payload_bytes =
      std::max(state.peak_retained_payload_bytes, retainedBytes);
  if (!state.has_input_timeline) {
    // The first PCM frame this generation will see is not the first frame of
    // the first packet: the decoder has already consumed its own lead-in.
    if (!checkedFrameEnd(state.prepared_start_frame, state.lead_in_frames,
                         &state.decoded_cursor_frame)) {
      state.failClosedProtocol();
      return false;
    }
    state.has_input_timeline = true;
  }
  state.expected_input_frame = state.prepared_end_frame;
  state.accepted_pcm_frames = state.prepared_accepted_frames;
  state.clearPreparedProof();
  saturatingAdd(state.statistics.acceptedSamples, 1);
  return true;
}

NativeAudioSubmitResult
NativeAudioConverter::submit(media::MediaSample &&sample, std::string *error) {
  NativeAudioPrepareOutcome outcome = prepare(sample, error);
  if (outcome.result != NativeAudioSubmitResult::Accepted) {
    return outcome.result;
  }
  return commitPrepared(std::move(outcome.prepared), std::move(sample))
             ? NativeAudioSubmitResult::Accepted
             : NativeAudioSubmitResult::Failed;
}

NativeAudioPumpResult NativeAudioConverter::pump(std::string *error) {
  auto &state = *impl_;
  if (!state.configured || state.cancelled) {
    return NativeAudioPumpResult::NotConfigured;
  }
  if (state.failed) {
    return NativeAudioPumpResult::Failed;
  }
  if (state.ring.generation() != state.statistics.generation) {
    return NativeAudioPumpResult::StaleGeneration;
  }
  if (state.drained) {
    return NativeAudioPumpResult::Drained;
  }
  std::int64_t maximumBlockEnd = 0;
  const bool maximumBlockIsPreroll =
      state.timeline.trimBeforeFloor && state.has_input_timeline &&
      state.decoded_cursor_frame < state.presentation_floor_frame &&
      checkedFrameEnd(state.decoded_cursor_frame, kFramesPerPump,
                      &maximumBlockEnd) &&
      maximumBlockEnd <= state.presentation_floor_frame;
  if (!maximumBlockIsPreroll &&
      state.ring.queuedSlabs() >= NativePcmRing::kSlabCount) {
    saturatingAdd(state.statistics.ringBackpressure, 1);
    return NativeAudioPumpResult::Backpressure;
  }
  const bool hasInput = state.lease && !state.awaiting_input_release &&
                        state.next_packet < state.packet_count;
  if (!hasInput && !state.awaiting_input_release && !state.eof_requested) {
    return NativeAudioPumpResult::NeedsInput;
  }
  if (hasInput && state.encoded_data == nullptr) {
    state.failPump(error, "native audio input storage is unavailable");
    return NativeAudioPumpResult::Failed;
  }
  const auto byteSpan =
      hasInput ? std::span<const std::byte>(state.encoded_data,
                                            state.encoded_size)
               : std::span<const std::byte>{};
  const auto packetSpan = hasInput
                              ? std::span<const NativeAudioPacketDescription>(
                                    state.packets.data() + state.next_packet,
                                    state.packet_count - state.next_packet)
                              : std::span<const NativeAudioPacketDescription>{};
  const bool sendingEof =
      state.eof_requested && !hasInput && !state.awaiting_input_release;
  NativeAudioBackendResult converted;
  try {
    converted = state.backend->convert(
        {byteSpan, packetSpan, sendingEof},
        std::span<float>(state.pcm.data(),
                         kFramesPerPump * state.audio.channels));
  } catch (...) {
    state.failPump(error, "native audio backend convert threw");
    return NativeAudioPumpResult::Failed;
  }
  if (converted.failed || converted.consumedPackets > packetSpan.size() ||
      converted.producedFrames > kFramesPerPump ||
      (converted.needsInput &&
       converted.consumedPackets != packetSpan.size()) ||
      (converted.drained && !sendingEof)) {
    state.failPump(error, "native audio backend violated its bounded contract");
    return NativeAudioPumpResult::Failed;
  }
  std::uint64_t decodedAfter = state.statistics.decodedPcmFrames;
  std::int64_t cursorAfter = state.decoded_cursor_frame;
  if (converted.producedFrames != 0 &&
      (!state.has_input_timeline ||
       !checkedAdd(state.statistics.decodedPcmFrames, converted.producedFrames,
                   &decodedAfter) ||
       !state.decodedWithinBudget(decodedAfter) ||
       !checkedFrameEnd(state.decoded_cursor_frame, converted.producedFrames,
                        &cursorAfter))) {
    state.failPump(error,
                   "decoded audio exceeds its exact accepted timeline budget");
    return NativeAudioPumpResult::Failed;
  }
  state.next_packet += converted.consumedPackets;
  saturatingAdd(state.statistics.consumedPackets, converted.consumedPackets);
  saturatingAdd(state.statistics.producedFrames, converted.producedFrames);
  if (state.lease && state.next_packet == state.packet_count) {
    state.awaiting_input_release = true;
  }
  if (converted.finalInputReleased) {
    if (!state.lease || !state.awaiting_input_release) {
      state.failPump(error,
                     "native audio backend released untracked input storage");
      return NativeAudioPumpResult::Failed;
    }
    state.releaseSample();
    state.awaiting_input_release = false;
  }
  if (converted.producedFrames != 0) {
    std::uint64_t discarded = 0;
    if (state.timeline.trimBeforeFloor &&
        state.decoded_cursor_frame < state.presentation_floor_frame) {
      const std::int64_t discardEnd =
          std::min(cursorAfter, state.presentation_floor_frame);
      if (!frameDistance(state.decoded_cursor_frame, discardEnd, &discarded) ||
          discarded > converted.producedFrames) {
        state.failPump(error, "accurate-seek PCM trim is not frame-exact");
        return NativeAudioPumpResult::Failed;
      }
    }
    std::int64_t publishStart = 0;
    if (!checkedFrameEnd(state.decoded_cursor_frame, discarded,
                         &publishStart)) {
      state.failPump(error, "generation-local PCM accounting overflowed");
      return NativeAudioPumpResult::Failed;
    }
    // Mirror image of the head trim. The final packet of a constant-frame
    // codec always overruns the stream's exact end; those frames are decoded
    // (so the budget identity above still holds) but never published.
    std::uint64_t tailDiscarded = 0;
    if (state.has_presentation_ceiling &&
        cursorAfter > state.presentation_ceiling_frame) {
      const std::int64_t keepEnd =
          std::max(publishStart, state.presentation_ceiling_frame);
      if (!frameDistance(keepEnd, cursorAfter, &tailDiscarded) ||
          tailDiscarded > converted.producedFrames - discarded) {
        state.failPump(error, "end-of-stream PCM trim is not frame-exact");
        return NativeAudioPumpResult::Failed;
      }
    }
    const std::uint64_t publishFrames =
        converted.producedFrames - discarded - tailDiscarded;
    std::uint64_t discardedAfter = 0;
    std::uint64_t publishedAfter = 0;
    std::uint64_t trimmed = 0;
    if (!checkedAdd(discarded, tailDiscarded, &trimmed) ||
        !checkedAdd(state.statistics.discardedTrimFrames, trimmed,
                    &discardedAfter) ||
        !checkedAdd(state.statistics.publishedPcmFrames, publishFrames,
                    &publishedAfter)) {
      state.failPump(error, "generation-local PCM accounting overflowed");
      return NativeAudioPumpResult::Failed;
    }
    state.statistics.decodedPcmFrames = decodedAfter;
    state.statistics.discardedTrimFrames = discardedAfter;
    state.decoded_cursor_frame = cursorAfter;
    if (state.audio.channels == 1) {
      for (std::size_t frame = converted.producedFrames; frame != 0; --frame) {
        const float value = state.pcm[frame - 1];
        state.pcm[(frame - 1) * 2] = value;
        state.pcm[(frame - 1) * 2 + 1] = value;
      }
    }
    if (publishFrames == 0) {
      if (converted.drained) {
        if (!state.decodedBudgetExhausted(decodedAfter)) {
          state.failPump(
              error, "audio backend drained before its exact timeline ended");
          return NativeAudioPumpResult::Failed;
        }
        state.drained = true;
      }
      return NativeAudioPumpResult::Progress;
    }
    const auto published = state.ring.publish(
        state.statistics.generation,
        std::span<const float>(state.pcm.data() +
                                   discarded * NativePcmRing::kChannels,
                               publishFrames * NativePcmRing::kChannels),
        publishFrames);
    if (published == NativePcmRing::PublishResult::Full) {
      state.failPump(error, "ring became full after converter preflight");
      return NativeAudioPumpResult::Failed;
    }
    if (published == NativePcmRing::PublishResult::StaleGeneration) {
      return NativeAudioPumpResult::StaleGeneration;
    }
    if (published != NativePcmRing::PublishResult::Published) {
      state.failPump(error, "native PCM ring rejected decoded audio");
      return NativeAudioPumpResult::Failed;
    }
    state.statistics.publishedPcmFrames = publishedAfter;
    if (!state.statistics.firstPublishedFrameKnown) {
      state.statistics.firstPublishedFrame = publishStart;
      state.statistics.firstPublishedFrameKnown = true;
    }
    saturatingAdd(state.statistics.publishedSlabs, 1);
    if (converted.drained) {
      if (!state.decodedBudgetExhausted(decodedAfter)) {
        state.failPump(error,
                       "audio backend drained before its exact timeline ended");
        return NativeAudioPumpResult::Failed;
      }
      state.drained = true;
    }
    return NativeAudioPumpResult::Published;
  }
  if (converted.drained) {
    if (!state.decodedBudgetExhausted(state.statistics.decodedPcmFrames)) {
      state.failPump(error,
                     "audio backend drained before its exact timeline ended");
      return NativeAudioPumpResult::Failed;
    }
    state.drained = true;
    return NativeAudioPumpResult::Drained;
  }
  if (converted.consumedPackets != 0 || converted.finalInputReleased) {
    return NativeAudioPumpResult::Progress;
  }
  if (converted.needsInput && !state.eof_requested) {
    return NativeAudioPumpResult::NeedsInput;
  }
  state.failPump(error, "native audio backend made no bounded progress");
  return NativeAudioPumpResult::Failed;
}

NativeAudioPumpResult
NativeAudioConverter::endOfStream(media::MediaGeneration generation,
                                  std::string *error) {
  auto &state = *impl_;
  if (!state.configured || state.cancelled) {
    return NativeAudioPumpResult::NotConfigured;
  }
  if (state.failed) {
    return NativeAudioPumpResult::Failed;
  }
  if (generation != state.statistics.generation) {
    return NativeAudioPumpResult::StaleGeneration;
  }
  if (state.prepared) {
    state.failPump(error,
                   "end-of-stream cannot overtake a prepared audio sample");
    return NativeAudioPumpResult::Failed;
  }
  state.eof_requested = true;
  return pump(error);
}

void NativeAudioConverter::cancel(media::MediaGeneration generation) noexcept {
  auto &state = *impl_;
  if (!state.configured || generation != state.statistics.generation) {
    return;
  }
  state.cancelled = true;
  state.statistics.cancelled = true;
  try {
    if (!state.backend->reset(nullptr)) {
      saturatingAdd(state.statistics.failures, 1);
      state.backend->close();
      state.configured = false;
    }
  } catch (...) {
    saturatingAdd(state.statistics.failures, 1);
    try {
      state.backend->close();
    } catch (...) {
    }
    state.configured = false;
  }
  state.clearFlow();
}

bool NativeAudioConverter::flush(
    media::MediaGeneration nextGeneration,
    NativeAudioGenerationTimeline timeline) noexcept {
  auto &state = *impl_;
  std::int64_t floorFrame = 0;
  std::int64_t ceilingFrame = 0;
  bool ceilingKnown = false;
  if (!state.configured || nextGeneration == 0 ||
      nextGeneration <= state.statistics.generation ||
      state.ring.generation() != nextGeneration ||
      !exactFrame(timeline.presentationFloor, state.sample_rate, &floorFrame) ||
      !resolveCeiling(timeline, state.sample_rate, floorFrame, &ceilingFrame,
                      &ceilingKnown)) {
    return false;
  }
  try {
    if (!state.backend->reset(nullptr)) {
      saturatingAdd(state.statistics.failures, 1);
      try {
        state.backend->close();
      } catch (...) {
      }
      state.clearFlow();
      state.configured = false;
      state.failed = true;
      state.statistics.configured = false;
      state.statistics.failed = true;
      return false;
    }
  } catch (...) {
    saturatingAdd(state.statistics.failures, 1);
    try {
      state.backend->close();
    } catch (...) {
    }
    state.clearFlow();
    state.configured = false;
    state.failed = true;
    state.statistics.configured = false;
    state.statistics.failed = true;
    return false;
  }
  state.clearFlow();
  state.cancelled = false;
  state.failed = false;
  state.statistics.cancelled = false;
  state.statistics.failed = false;
  state.statistics.generation = nextGeneration;
  state.peak_retained_payload_bytes = state.retained_payload_bytes;
  state.statistics.sampleRetained = false;
  state.statistics.endOfStreamRequested = false;
  state.statistics.drained = false;
  state.resetExactTimeline(timeline, floorFrame, ceilingFrame, ceilingKnown);
  return true;
}

void NativeAudioConverter::close() noexcept {
  if (!impl_) {
    return;
  }
  auto &state = *impl_;
  try {
    state.backend->close();
  } catch (...) {
  }
  state.clearFlow();
  state.configured = false;
  state.failed = false;
  state.statistics.configured = false;
}

std::uint32_t NativeAudioConverter::outputSampleRate() const noexcept {
  return impl_->configured ? impl_->sample_rate : 0;
}

NativeAudioConverterStats NativeAudioConverter::stats() const noexcept {
  auto result = impl_->statistics;
  result.configured = impl_->configured;
  result.cancelled = impl_->cancelled;
  result.failed = impl_->failed;
  result.samplePrepared = impl_->prepared;
  result.sampleRetained = static_cast<bool>(impl_->lease);
  result.retainedPayloadBytes = impl_->retained_payload_bytes;
  result.peakRetainedPayloadBytes =
      std::max(impl_->peak_retained_payload_bytes,
               result.retainedPayloadBytes);
  result.endOfStreamRequested = impl_->eof_requested;
  result.drained = impl_->drained;
  return result;
}

bool NativeAudioConverter::resetRetainedPayloadByteHighWater(
    media::MediaGeneration expectedGeneration) noexcept {
  if (expectedGeneration == 0 ||
      impl_->statistics.generation != expectedGeneration) {
    return false;
  }
  impl_->peak_retained_payload_bytes = impl_->retained_payload_bytes;
  return true;
}

} // namespace wam::macos
