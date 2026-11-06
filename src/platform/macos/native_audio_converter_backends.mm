#include "native_audio_converter_backends.hpp"
#if defined(WAM_ENABLE_AVCODEC_STAGE)
#include "software_avcodec_audio_backend.hpp"
#endif

#include "media/adpcm_audio.hpp"
#include "media/adpcm_decoder.hpp"
#include "media/media_codec_facts.hpp"
#include "native_audio_channel_map.hpp"

#import <AudioToolbox/AudioToolbox.h>

#include <algorithm>
#include <array>
#include <vector>

namespace wam::macos {
namespace {

constexpr OSStatus kInputTemporarilyUnavailable = 'wamu';
constexpr std::size_t kMaximumPacketsPerFill = 16;

void assignError(std::string *error, const char *message) {
  if (error != nullptr) {
    *error = message;
  }
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

class WamAdpcmBackend final : public NativeAudioConverterBackend {
  media::AdpcmFormat format_{};
  std::vector<float> block_;
  std::size_t cursor_{0}, available_{0};
  const char *refusal_{nullptr};

public:
  bool configure(const NativeAudioBackendConfiguration &c,
                 std::string *error) override {
    close();
    format_ = {static_cast<std::uint16_t>(c.input.formatTag & 0xffffU),
               c.input.channels, c.input.bytesPerPacket,
               c.input.framesPerPacket};
    if (const char *e = media::validateAdpcmFormat(format_)) {
      refusal_ = e;
      assignError(error, e);
      return false;
    }
    if (c.outputChannels != format_.channels ||
        c.outputSampleRate != c.input.sampleRate) {
      assignError(error, "AdpcmOutputFormatMismatch");
      return false;
    }
    block_.resize(static_cast<std::size_t>(format_.blockFrames) *
                  format_.channels);
    return true;
  }
  NativeAudioBackendResult convert(NativeAudioBackendInput input,
                                   std::span<float> out) override {
    NativeAudioBackendResult r;
    if (available_ == 0 && !input.packets.empty()) {
      const auto &p = input.packets.front();
      if (p.startOffset < 0 ||
          static_cast<std::uint64_t>(p.startOffset) > input.bytes.size() ||
          p.byteSize >
              input.bytes.size() - static_cast<std::size_t>(p.startOffset))
        refusal_ = "AdpcmPacketBoundsInvalid";
      else if (p.variableFrames != 0 && p.variableFrames != format_.blockFrames)
        refusal_ = "AdpcmPacketFramesMismatch";
      else
        refusal_ = media::decodeAdpcmBlock(
            format_,
            input.bytes.subspan(static_cast<std::size_t>(p.startOffset),
                                p.byteSize),
            block_);
      if (refusal_) {
        r.failed = true;
        return r;
      }
      cursor_ = 0;
      available_ = format_.blockFrames;
      r.consumedPackets = 1;
      r.finalInputReleased = input.packets.size() == 1;
    }
    r.producedFrames = std::min(available_, out.size() / format_.channels);
    std::copy_n(block_.data() + cursor_ * format_.channels,
                r.producedFrames * format_.channels, out.data());
    cursor_ += r.producedFrames;
    available_ -= r.producedFrames;
    r.needsInput = available_ == 0 &&
                   r.consumedPackets == input.packets.size() &&
                   !input.endOfStream;
    r.drained = input.endOfStream && available_ == 0 && r.producedFrames == 0;
    return r;
  }
  const char *failureReason() const noexcept override { return refusal_; }
  bool reset(std::string *) override {
    cursor_ = available_ = 0;
    refusal_ = nullptr;
    return !block_.empty();
  }
  void close() noexcept override {
    cursor_ = available_ = 0;
    refusal_ = nullptr;
  }
};

class CoreAudioConverterBackend final : public NativeAudioConverterBackend {
public:
  ~CoreAudioConverterBackend() override { close(); }

  [[nodiscard]] bool
  configure(const NativeAudioBackendConfiguration &configuration,
            std::string *error) override {
    close();
    rebuild_on_reset_ =
        media::mediaCodecFacts(configuration.codec).decoderResetRebuilds;
    input_asbd_ = exactAsbd(configuration.input);
    output_asbd_ = floatOutputAsbd(configuration.outputSampleRate,
                                   configuration.outputChannels);
    try {
      cookie_.assign(configuration.codecConfiguration.begin(),
                     configuration.codecConfiguration.end());
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
    // Drained means: the caller asked for the end, nothing came out, and there
    // was no input left to consume.
    //
    // `context.sawEndOfStream` alone is not sufficient. MP3's decoder still
    // holds frames after its last packet -- it swallows 529 at the head and
    // flushes 529 at the end -- so the first end-of-stream convert call returns
    // those 529 frames and the SECOND one finds CoreAudio already finished: it
    // returns zero without invoking the input proc again, so nothing sets
    // sawEndOfStream and the pump would report "native audio backend made no
    // bounded progress" at every MP3 end of file. An empty packet span at end
    // of stream is the same proof by a route CoreAudio cannot skip.
    result.drained = input.endOfStream && outputFrames == 0 &&
                     (context.sawEndOfStream || input.packets.empty());
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
    // A codec whose priming state AudioConverterReset does not restore is
    // rebuilt (see decoderResetRebuilds); every other codec uses the cheaper
    // reset.
    if (rebuild_on_reset_) {
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

  // Asks the LIVE converter what it will actually write, not what the
  // container claimed. AudioToolbox normalises the layout it was handed (a
  // FLAC track stating tag 0x00BB0006 is reported back as 0x00790006) and
  // gives a different order per codec family, so this query is the only
  // trustworthy source for the label order the downmix indexes.
  [[nodiscard]] bool
  outputChannelRoles(std::span<media::AudioChannelRole> roles,
                     std::size_t *roleCount) noexcept override {
    if (roleCount != nullptr) {
      *roleCount = 0;
    }
    if (converter_ == nullptr || roleCount == nullptr) {
      return false;
    }
    UInt32 layoutBytes = 0;
    Boolean writable = false;
    if (AudioConverterGetPropertyInfo(converter_,
                                      kAudioConverterOutputChannelLayout,
                                      &layoutBytes, &writable) != noErr ||
        layoutBytes == 0) {
      return false;
    }
    alignas(AudioChannelLayout) std::array<
        std::byte, sizeof(AudioChannelLayout) +
                       (kMaximumChannelLayoutDescriptions - 1) *
                           sizeof(AudioChannelDescription)>
        storage{};
    if (layoutBytes > storage.size()) {
      return false;
    }
    if (AudioConverterGetProperty(converter_,
                                  kAudioConverterOutputChannelLayout,
                                  &layoutBytes, storage.data()) != noErr) {
      return false;
    }
    return channelRolesForLayout(
        reinterpret_cast<const AudioChannelLayout *>(storage.data()),
        layoutBytes, output_asbd_.mChannelsPerFrame, roles, roleCount);
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
    // A CONSTANT-bit-rate input carries no packet descriptions at all:
    // CoreAudio derives the packet count from mDataByteSize / mBytesPerPacket
    // and IGNORES any description array handed to it. Every compressed codec
    // this converter admits is variable-rate and states mBytesPerPacket = 0;
    // LPCM does not. Handing LPCM the whole payload's mDataByteSize while
    // declaring kMaximumPacketsPerFill packets makes CoreAudio consume the
    // whole payload -- measured as producedFrames = 1024 against
    // consumedPackets = 16 -- and the next pump would decode the same frames
    // again and run the generation past its accepted budget. So a CBR input
    // gets a BYTE-EXACT window of exactly the packets it is told about.
    //
    // It also needs no callback_packets_ storage, which is why it is not
    // bounded by kMaximumPacketsPerFill: at one frame per packet that bound
    // would mean 256 input-proc calls for a single 4096-frame pump.
    const std::uint32_t bytesPerPacket =
        context.owner->input_asbd_.mBytesPerPacket;
    if (bytesPerPacket != 0) {
      if (remaining == 0) {
        *ioNumberDataPackets = 0;
        if (context.input.endOfStream) {
          context.sawEndOfStream = true;
          return noErr;
        }
        context.needsInput = true;
        return kInputTemporarilyUnavailable;
      }
      const std::size_t supplied =
          std::min(remaining, static_cast<std::size_t>(*ioNumberDataPackets));
      if (supplied == 0) {
        return kInputTemporarilyUnavailable;
      }
      const auto &first = context.input.packets[context.packetIndex];
      if (first.startOffset < 0) {
        return kAudioConverterErr_UnspecifiedError;
      }
      const auto start = static_cast<std::size_t>(first.startOffset);
      const std::size_t windowBytes = supplied * bytesPerPacket;
      if (start > context.input.bytes.size() ||
          windowBytes > context.input.bytes.size() - start) {
        return kAudioConverterErr_UnspecifiedError;
      }
      ioData->mBuffers[0].mData =
          const_cast<std::byte *>(context.input.bytes.data() + start);
      ioData->mBuffers[0].mDataByteSize = static_cast<UInt32>(windowBytes);
      if (outDataPacketDescription != nullptr) {
        *outDataPacketDescription = nullptr;
      }
      context.packetIndex += supplied;
      context.owner->input_storage_outstanding_ = true;
      context.owner->outstanding_storage_was_final_ =
          context.packetIndex == context.input.packets.size();
      *ioNumberDataPackets = static_cast<UInt32>(supplied);
      return noErr;
    }
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
  bool rebuild_on_reset_{false};
  std::array<AudioStreamPacketDescription, kMaximumPacketsPerFill>
      callback_packets_{};
  bool input_storage_outstanding_{false};
  bool outstanding_storage_was_final_{false};
};

} // namespace

std::unique_ptr<NativeAudioConverterBackend>
makeNativeAudioConverterBackend(media::MediaCodec codec,
                                NativeAudioBackendWake wake) {
  switch (codec) {
  case media::MediaCodec::AdpcmIma:
  case media::MediaCodec::AdpcmMs:
    return std::make_unique<WamAdpcmBackend>();
#if defined(WAM_ENABLE_AVCODEC_STAGE)
  case media::MediaCodec::Dts:
    return std::make_unique<SoftwareAvcodecAudioBackend>(
        media::avcodec::Codec::Dts, wake);
  case media::MediaCodec::TrueHd:
    return std::make_unique<SoftwareAvcodecAudioBackend>(
        media::avcodec::Codec::TrueHd, wake);
  case media::MediaCodec::Mlp:
    return std::make_unique<SoftwareAvcodecAudioBackend>(
        media::avcodec::Codec::Mlp, wake);
#endif
  default:
    static_cast<void>(wake);
    return media::softwareAudioCodec(codec)
               ? nullptr
               : std::make_unique<CoreAudioConverterBackend>();
  }
}

} // namespace wam::macos
