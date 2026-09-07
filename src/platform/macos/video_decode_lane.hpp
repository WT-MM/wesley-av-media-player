#pragma once

#include "software_vp8_decoder.hpp"
#include "video_toolbox_decoder.hpp"
#if defined(WAM_ENABLE_AVCODEC_STAGE)
#include "software_avcodec_video_decoder.hpp"
#include "native_video_decode_plan.hpp"
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
// lifecycle are untouched. That is deliberate: a VP8 stage that changed the
// seam would have to re-prove all of it.
//
// SELECTION HAPPENS ONCE, IN configure(), keyed on the CoreMedia codec type
// the consumer already computed from the track. After that the only per-call
// cost is one predictable test of a member pointer that never changes for the
// life of a generation -- not a lookup, not a virtual call, and nothing that
// runs per pixel or per sample beyond that test. See
// docs/AGENT_PERFORMANCE_PRINCIPLES.md, "Dispatch at the top, not in the
// loop".
//
// The software backend is constructed lazily, so a session that never plays
// VP8 pays one null pointer for this class.
class VideoDecodeLane final {
public:
  explicit VideoDecodeLane(VideoToolboxDecoderOptions options = {})
      : options_(options), videoToolbox_(options) {}

  VideoDecodeLane(const VideoDecodeLane &) = delete;
  VideoDecodeLane &operator=(const VideoDecodeLane &) = delete;
  VideoDecodeLane(VideoDecodeLane &&) = delete;
  VideoDecodeLane &operator=(VideoDecodeLane &&) = delete;

  // True when this build can decode VP8 at all.
  [[nodiscard]] static bool softwareVp8Available() noexcept {
    return SoftwareVp8Decoder::available();
  }

  [[nodiscard]] bool configure(const VideoStreamConfiguration &configuration,
                               DecodedFrameSink &sink, std::string *error) {
#if defined(WAM_ENABLE_AVCODEC_STAGE)
    close();
    software_.reset();
    avcodec_.reset();
    plan_ = nativeVideoDecodePlan(configuration, SoftwareVp8Decoder::available(), true);
    for (auto& candidate : plan_.candidates) {
      if (candidate.refusal != media::DecodeRefusal::None) continue;
      auto configured = configuration;
      switch (candidate.implementation) {
      case media::DecodeImplementation::VideoToolboxHardware:
      case media::DecodeImplementation::VideoToolboxSoftware:
        configured.requireHardwareDecode = candidate.implementation == media::DecodeImplementation::VideoToolboxHardware;
        configured.preferHardwareDecode = configured.requireHardwareDecode;
        if (videoToolbox_.configure(configured, sink, error)) {
          plan_.implementation = candidate.implementation;
          std::fprintf(stderr, "WAM: native decoder stage=%s codec=%08x\n",
              videoToolbox_.stats().usingHardwareAcceleratedDecoder ? "VideoToolboxHardware" : "VideoToolboxSoftware", configuration.codec);
          if (error) error->clear();
          return true;
        }
        videoToolbox_.close();
        candidate.refusal = media::DecodeRefusal::AppleCodecUnavailable;
        break;
      case media::DecodeImplementation::Libavcodec:
        avcodec_ = std::make_unique<SoftwareAvcodecVideoDecoder>(options_);
        if (!avcodec_->configure(configured, sink, error)) return false;
        plan_.implementation = candidate.implementation;
        std::fprintf(stderr, "WAM: native decoder stage=Libavcodec codec=%08x\n", configuration.codec);
        if (error) error->clear();
        return true;
      case media::DecodeImplementation::Libvpx:
        software_ = std::make_unique<SoftwareVp8Decoder>(options_);
        if (!software_->configure(configured, sink, error)) return false;
        plan_.implementation = candidate.implementation;
        std::fprintf(stderr, "WAM: native decoder stage=Libvpx codec=%08x\n", configuration.codec);
        if (error) error->clear();
        return true;
      default: break;
      }
    }
    plan_.implementation = media::DecodeImplementation::None;
    if (error) *error = "NativeDecodePlanExhausted";
    return false;
#else
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

  // True only while a software generation is active. Telemetry and the
  // consumer's own diagnostics use it; nothing on the frame path does.
  [[nodiscard]] bool usesSoftwareDecode() const noexcept {
#if defined(WAM_ENABLE_AVCODEC_STAGE)
    if (avcodec_) return true;
#endif
    return software_ != nullptr;
  }

private:
  const VideoToolboxDecoderOptions options_;
  VideoToolboxDecoder videoToolbox_;
  std::unique_ptr<SoftwareVp8Decoder> software_;
#if defined(WAM_ENABLE_AVCODEC_STAGE)
  std::unique_ptr<SoftwareAvcodecVideoDecoder> avcodec_;
  media::DecodePlan plan_{};
#endif
};

} // namespace wam::macos
