#pragma once

#include "software_vp8_decoder.hpp"
#include "video_toolbox_decoder.hpp"
#if defined(WAM_ENABLE_AVCODEC_STAGE)
#include "software_avcodec_video_decoder.hpp"
#include "native_video_decode_plan.hpp"
#include "media/software_color_qualification.hpp"
#endif

#include <cstdint>
#include <cstdio>
#include <memory>
#include <optional>
#include <string>
#include <utility>

namespace wam::macos {

// The one decode backend NativeVideoConsumer owns, selected once per open.
//
// Every method here is the same method the consumer already called on
// VideoToolboxDecoder, with the same signature and the same result type, so
// the consumer's state machine, its stats proofs and its EOS/flush/retire
// lifecycle are the same for every backend (VideoToolbox, libvpx VP8, and
// libavcodec when WAM_ENABLE_AVCODEC_STAGE is defined). A backend that changed
// the seam would have to re-prove all of it.
//
// SELECTION HAPPENS ONCE, IN configure(). With the libavcodec stage built it
// walks nativeVideoDecodePlan()'s candidates in order, and each VideoToolbox
// candidate overwrites requireHardwareDecode/preferHardwareDecode with its own
// hardware/software choice; otherwise it keys on the CoreMedia codec type
// (VP8 to libvpx, everything else to VideoToolbox). After that the only
// per-call cost is one or two predictable tests of member pointers that never
// change for the life of a generation -- not a lookup, not a virtual call, and nothing that
// runs per pixel or per sample beyond that test. See
// docs/AGENT_PERFORMANCE_PRINCIPLES.md, "Dispatch at the top, not in the
// loop".
//
// Software backends are constructed lazily, so a session that never selects
// one pays only null pointers for them.
class VideoDecodeLane final {
public:
  explicit VideoDecodeLane(VideoToolboxDecoderOptions options = {})
      : options_(options), videoToolbox_(options) {}

  VideoDecodeLane(const VideoDecodeLane &) = delete;
  VideoDecodeLane &operator=(const VideoDecodeLane &) = delete;
  VideoDecodeLane(VideoDecodeLane &&) = delete;
  VideoDecodeLane &operator=(VideoDecodeLane &&) = delete;

  [[nodiscard]] static bool softwareVp8Available() noexcept {
    return SoftwareVp8Decoder::available();
  }

  [[nodiscard]] bool configure(const VideoStreamConfiguration &configuration,
                               DecodedFrameSink &sink, std::string *error,
                               std::optional<bool> hardwareCapability = {}) {
#if defined(WAM_ENABLE_AVCODEC_STAGE)
    close();
    software_.reset();
    avcodec_.reset();
    const auto plan = nativeVideoDecodePlan(configuration, SoftwareVp8Decoder::available(), hardwareCapability);
    for (const auto& candidate : plan.candidates) {
      if (candidate.refusal != media::DecodeRefusal::None) continue;
      auto configured = configuration;
      switch (candidate.implementation) {
      case media::DecodeImplementation::VideoToolboxHardware:
      case media::DecodeImplementation::VideoToolboxSoftware:
        configured.requireHardwareDecode = candidate.implementation == media::DecodeImplementation::VideoToolboxHardware;
        configured.preferHardwareDecode = configured.requireHardwareDecode;
        if (videoToolbox_.configure(configured, sink, error)) {
          std::fprintf(stderr, "WAM: native decoder stage=%s codec=%08x\n",
              videoToolbox_.stats().usingHardwareAcceleratedDecoder ? "VideoToolboxHardware" : "VideoToolboxSoftware", configuration.codec);
          if (error) error->clear();
          return true;
        }
        videoToolbox_.close();
        break;
      case media::DecodeImplementation::Libavcodec: {
        const auto codec = media::mediaCodecForCoreMediaType(configuration.codec);
        const auto& facts = media::mediaCodecFacts(codec);
        media::VideoCodecConfigurationLimits limits;
        limits.admitSoftwareProfiles = true;
        limits.admitHighDynamicRangeColor = true;
        const auto inspected = media::inspectVideoCodecConfiguration(
            codec, facts.configurationKind, configuration.codecConfiguration, limits);
        auto colorFacts = inspected.facts.value_or(media::VideoCodecConfigurationFacts{});
        if (configuration.fullRangeVideo)
          colorFacts.color.fullRange = *configuration.fullRangeVideo;
        if (!inspected.admitted() || !media::softwareColorQualified(
                colorFacts, configuration.highDynamicRangeTransfer)) {
          if (error) *error = "SoftwareColorUnqualified";
          return false;
        }
        avcodec_ = std::make_unique<SoftwareAvcodecVideoDecoder>(options_);
        if (!avcodec_->configure(configured, sink, error)) return false;
        std::fprintf(stderr, "WAM: native decoder stage=Libavcodec codec=%08x\n", configuration.codec);
        if (error) error->clear();
        return true;
      }
      case media::DecodeImplementation::Libvpx:
        software_ = std::make_unique<SoftwareVp8Decoder>(options_);
        if (!software_->configure(configured, sink, error)) return false;
        std::fprintf(stderr, "WAM: native decoder stage=Libvpx codec=%08x\n", configuration.codec);
        if (error) error->clear();
        return true;
      default: break;
      }
    }
    if (error) *error = "NativeDecodePlanExhausted";
    return false;
#else
    static_cast<void>(hardwareCapability);
    if (configuration.codec == kWamVideoCodecTypeVp8) {
      if (!SoftwareVp8Decoder::available()) {
        if (error != nullptr) {
          *error = "this build has no software VP8 decoder";
        }
        return false;
      }
      if (software_ == nullptr) {
        software_ = std::make_unique<SoftwareVp8Decoder>(options_);
      }
      return software_->configure(configuration, sink, error);
    }
    return videoToolbox_.configure(configuration, sink, error);
#endif
  }

  [[nodiscard]] VideoDecodeSubmitResult
  submitCMSampleBuffer(CMSampleBufferRef sample, std::uint64_t generation,
                       std::string *error) {
#if defined(WAM_ENABLE_AVCODEC_STAGE)
    if (avcodec_) return avcodec_->submitCMSampleBuffer(sample, generation, error);
#endif
    return software_ != nullptr
               ? software_->submitCMSampleBuffer(sample, generation, error)
               : videoToolbox_.submitCMSampleBuffer(sample, generation, error);
  }

  [[nodiscard]] VideoDecodeDrainProgress
  beginEndOfStream(std::uint64_t generation, std::string *error) {
#if defined(WAM_ENABLE_AVCODEC_STAGE)
    if (avcodec_) return avcodec_->beginEndOfStream(generation, error);
#endif
    return software_ != nullptr
               ? software_->beginEndOfStream(generation, error)
               : videoToolbox_.beginEndOfStream(generation, error);
  }

  [[nodiscard]] VideoDecodeDrainProgress
  drainPresentation(std::uint64_t generation, std::string *error) {
#if defined(WAM_ENABLE_AVCODEC_STAGE)
    if (avcodec_) return avcodec_->drainPresentation(generation, error);
#endif
    return software_ != nullptr
               ? software_->drainPresentation(generation, error)
               : videoToolbox_.drainPresentation(generation, error);
  }

  [[nodiscard]] VideoDecodeDrainProgress
  drainEndOfStream(std::uint64_t generation, std::string *error) {
#if defined(WAM_ENABLE_AVCODEC_STAGE)
    if (avcodec_) return avcodec_->drainEndOfStream(generation, error);
#endif
    return software_ != nullptr
               ? software_->drainEndOfStream(generation, error)
               : videoToolbox_.drainEndOfStream(generation, error);
  }

  // Handoff releases the software worker reservation instead of immediately
  // reopening an idle playback decoder that would starve its own preview.
  void suspendForPreview(std::uint64_t generation) noexcept {
#if defined(WAM_ENABLE_AVCODEC_STAGE)
    if (avcodec_) { avcodec_->suspendForPreview(generation); return; }
#endif
    flush(generation);
  }
  bool resumeAfterPreview() noexcept {
#if defined(WAM_ENABLE_AVCODEC_STAGE)
    if (avcodec_) return avcodec_->resumeAfterPreview();
#endif
    return true;
  }

  void flush(std::uint64_t nextGeneration) noexcept {
#if defined(WAM_ENABLE_AVCODEC_STAGE)
    if (avcodec_) { avcodec_->flush(nextGeneration); return; }
#endif
    if (software_ != nullptr) {
      software_->flush(nextGeneration);
      return;
    }
    videoToolbox_.flush(nextGeneration);
  }

  [[nodiscard]] VideoDecoderRetireProgress
  retire(std::uint64_t retiredGeneration,
         std::uint64_t invalidationGeneration) noexcept {
#if defined(WAM_ENABLE_AVCODEC_STAGE)
    if (avcodec_) return avcodec_->retire(retiredGeneration, invalidationGeneration);
#endif
    return software_ != nullptr
               ? software_->retire(retiredGeneration, invalidationGeneration)
               : videoToolbox_.retire(retiredGeneration,
                                      invalidationGeneration);
  }

  void close() noexcept {
#if defined(WAM_ENABLE_AVCODEC_STAGE)
    if (avcodec_) { avcodec_->close(); return; }
#endif
    if (software_ != nullptr) {
      software_->close();
      return;
    }
    videoToolbox_.close();
  }

  [[nodiscard]] VideoToolboxDecoderStats stats() const noexcept {
#if defined(WAM_ENABLE_AVCODEC_STAGE)
    if (avcodec_) return avcodec_->stats();
#endif
    return software_ != nullptr ? software_->stats() : videoToolbox_.stats();
  }

  [[nodiscard]] VideoToolboxDecoderMemoryFacts memoryFacts() const noexcept {
#if defined(WAM_ENABLE_AVCODEC_STAGE)
    if (avcodec_) return avcodec_->memoryFacts();
#endif
    return software_ != nullptr ? software_->memoryFacts()
                                : videoToolbox_.memoryFacts();
  }

  [[nodiscard]] std::optional<std::string> takeLastError() {
#if defined(WAM_ENABLE_AVCODEC_STAGE)
    if (avcodec_) return avcodec_->takeLastError();
#endif
    return software_ != nullptr ? software_->takeLastError()
                                : videoToolbox_.takeLastError();
  }

private:
  const VideoToolboxDecoderOptions options_;
  VideoToolboxDecoder videoToolbox_;
  std::unique_ptr<SoftwareVp8Decoder> software_;
#if defined(WAM_ENABLE_AVCODEC_STAGE)
  std::unique_ptr<SoftwareAvcodecVideoDecoder> avcodec_;
#endif
};

} // namespace wam::macos
