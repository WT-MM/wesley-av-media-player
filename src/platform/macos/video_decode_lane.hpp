#pragma once

#include "core_media_codec_facts.hpp"
#include "native_video_color.hpp"
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

// The one decoder configuration for a selected video track, shared by main
// playback and the preview lane so both decode with the same colour.
// The hardware REQUIREMENT comes from the codec facts: requiring hardware
// where the platform's only decoder is software fails
// VTDecompressionSessionCreate with kVTCouldNotFindVideoDecoderErr (-12906) on
// a stream that demonstrably decodes. Every codec still PREFERS hardware. An
// HDR transfer forces a 10-bit output surface (see
// VideoStreamConfiguration::highDynamicRangeTransfer), and the colour
// extensions are stated here so a synthesized description carries them.
[[nodiscard]] inline VideoStreamConfiguration videoStreamConfigurationFor(
    const media::MediaTrackDescriptor &track, std::uint64_t generation) {
  const media::MediaVideoFormat &video = *track.video;
  return {coreMediaCodecType(track.codec),
          {static_cast<std::int32_t>(video.codedWidth),
           static_cast<std::int32_t>(video.codedHeight)},
          track.codecConfiguration,
          true,
          media::mediaCodecFacts(track.codec).requiresHardwareDecode,
          generation,
          media::mediaTransferIsHighDynamicRange(video.transferFunction),
          colorPrimariesExtension(video.colorPrimaries),
          transferFunctionExtension(video.transferFunction),
          ycbcrMatrixExtension(video.matrixCoefficients),
          video.fullRangeVideo};
}

// Random access into an open-GOP stream begins on a picture whose *leading*
// pictures follow it in decode order but present before it. HEVC calls them
// RASL/RADL; x265 emits them at every CRA, while closed-GOP H.264 streams
// never produce the shape. When the
// random-access point itself starts the decode, VideoToolbox has none of the
// pictures those leading pictures reference and answers
// kVTVideoDecoderReferenceMissingErr, which the decoder correctly reports as a
// hard callback failure. The stream is not broken: HEVC states that leading
// pictures associated with a random-access point that begins the bitstream are
// not output and need not be decodable, and no later picture may reference
// them. They also present strictly before that random-access point, which the
// source located at or before the generation's presentation floor, so they can
// never become a visible frame. Recognize them from timing alone and drop them
// as compressed preroll rather than submitting an undecodable access unit.
[[nodiscard]] inline bool leadingPictureBeforeGenerationStart(
    media::MediaTime presentation, bool keyFrame,
    const std::optional<media::MediaTime>& generationStart) noexcept {
  if (keyFrame || !generationStart) {
    return false;
  }
  const auto order = media::compareMediaTime(presentation, *generationStart);
  return order && *order == media::MediaTimeOrder::Less;
}

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
private:
  // The one backend dispatch: the selected software backend, else
  // VideoToolbox. Selection is fixed for a generation, so this is a pair of
  // predictable pointer tests, not a lookup or a virtual call.
  template <typename Self, typename Function>
  static decltype(auto) withBackend(Self &self, Function &&function) {
#if defined(WAM_ENABLE_AVCODEC_STAGE)
    if (self.avcodec_) {
      return function(*self.avcodec_);
    }
#endif
    return self.software_ != nullptr ? function(*self.software_)
                                     : function(self.videoToolbox_);
  }
  template <typename Function> decltype(auto) with(Function &&function) {
    return withBackend(*this, std::forward<Function>(function));
  }
  template <typename Function>
  decltype(auto) with(Function &&function) const {
    return withBackend(*this, std::forward<Function>(function));
  }

public:
  explicit VideoDecodeLane(VideoDecoderOptions options = {})
      : options_(options), videoToolbox_(options) {}

  VideoDecodeLane(const VideoDecodeLane &) = delete;
  VideoDecodeLane &operator=(const VideoDecodeLane &) = delete;
  VideoDecodeLane(VideoDecodeLane &&) = delete;
  VideoDecodeLane &operator=(VideoDecodeLane &&) = delete;

  [[nodiscard]] bool configure(const VideoStreamConfiguration &configuration,
                               DecodedFrameSink &sink, std::string *error) {
#if defined(WAM_ENABLE_AVCODEC_STAGE)
    close();
    software_.reset();
    avcodec_.reset();
    const auto plan = nativeVideoDecodePlan(configuration, SoftwareVp8Decoder::available());
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
      case media::DecodeImplementation::Libavcodec:
        avcodec_ = std::make_unique<SoftwareAvcodecVideoDecoder>(options_);
        if (!avcodec_->configure(configured, sink, error)) return false;
        std::fprintf(stderr, "WAM: native decoder stage=Libavcodec codec=%08x\n", configuration.codec);
        if (error) error->clear();
        return true;
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
    return with([&](auto &decoder) {
      return decoder.submitCMSampleBuffer(sample, generation, error);
    });
  }

  [[nodiscard]] VideoDecodeDrainProgress
  beginEndOfStream(std::uint64_t generation, std::string *error) {
    return with([&](auto &decoder) {
      return decoder.beginEndOfStream(generation, error);
    });
  }

  [[nodiscard]] VideoDecodeDrainProgress
  drainPresentation(std::uint64_t generation, std::string *error) {
    return with([&](auto &decoder) {
      return decoder.drainPresentation(generation, error);
    });
  }

  [[nodiscard]] VideoDecodeDrainProgress
  drainEndOfStream(std::uint64_t generation, std::string *error) {
    return with([&](auto &decoder) {
      return decoder.drainEndOfStream(generation, error);
    });
  }

  // Handoff releases a software worker reservation instead of immediately
  // reopening an idle playback decoder that would starve its own preview; a
  // backend with nothing to release simply flushes.
  void suspendForPreview(std::uint64_t generation) noexcept {
    with([&](auto &decoder) {
      if constexpr (requires { decoder.suspendForPreview(generation); }) {
        decoder.suspendForPreview(generation);
      } else {
        decoder.flush(generation);
      }
    });
  }
  bool resumeAfterPreview() noexcept {
    return with([](auto &decoder) {
      if constexpr (requires { decoder.resumeAfterPreview(); }) {
        return decoder.resumeAfterPreview();
      } else {
        return true;
      }
    });
  }

  void flush(std::uint64_t nextGeneration) noexcept {
    with([&](auto &decoder) { decoder.flush(nextGeneration); });
  }

  [[nodiscard]] VideoDecoderRetireProgress
  retire(std::uint64_t retiredGeneration,
         std::uint64_t invalidationGeneration) noexcept {
    return with([&](auto &decoder) {
      return decoder.retire(retiredGeneration, invalidationGeneration);
    });
  }

  void close() noexcept {
    with([](auto &decoder) { decoder.close(); });
  }

  [[nodiscard]] VideoDecoderStats stats() const noexcept {
    return with([](const auto &decoder) { return decoder.stats(); });
  }

  [[nodiscard]] VideoDecoderMemoryFacts memoryFacts() const noexcept {
    return with([](const auto &decoder) { return decoder.memoryFacts(); });
  }

  [[nodiscard]] std::optional<std::string> takeLastError() {
    return with([](auto &decoder) { return decoder.takeLastError(); });
  }

private:
  const VideoDecoderOptions options_;
  VideoToolboxDecoder videoToolbox_;
  std::unique_ptr<SoftwareVp8Decoder> software_;
#if defined(WAM_ENABLE_AVCODEC_STAGE)
  std::unique_ptr<SoftwareAvcodecVideoDecoder> avcodec_;
#endif
};

} // namespace wam::macos
