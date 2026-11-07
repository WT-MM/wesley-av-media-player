#pragma once
#include "video_decoder_contract.hpp"
#include <memory>
namespace wam::macos {
class SoftwareAvcodecVideoDecoder final {
public:
  explicit SoftwareAvcodecVideoDecoder(VideoDecoderOptions options={});
  ~SoftwareAvcodecVideoDecoder();
  bool configure(const VideoStreamConfiguration&,DecodedFrameSink&,std::string*);
  VideoDecodeSubmitResult submitCMSampleBuffer(CMSampleBufferRef,std::uint64_t,std::string*);
  VideoDecodeDrainProgress beginEndOfStream(std::uint64_t,std::string*);
  VideoDecodeDrainProgress drainPresentation(std::uint64_t,std::string*);
  VideoDecodeDrainProgress drainEndOfStream(std::uint64_t,std::string*);
  void flush(std::uint64_t) noexcept;
  void suspendForPreview(std::uint64_t) noexcept;
  bool resumeAfterPreview() noexcept;
  VideoDecoderRetireProgress retire(std::uint64_t,std::uint64_t) noexcept;
  void close() noexcept;
  VideoDecoderStats stats() const noexcept;
  VideoDecoderMemoryFacts memoryFacts() const noexcept;
  std::optional<std::string> takeLastError();
private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
}
