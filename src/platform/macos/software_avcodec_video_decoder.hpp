#pragma once
#include "video_toolbox_decoder.hpp"
#include <memory>
namespace wam::macos {
class SoftwareAvcodecVideoDecoder final {
public:
  explicit SoftwareAvcodecVideoDecoder(VideoToolboxDecoderOptions options={});
  ~SoftwareAvcodecVideoDecoder();
  bool configure(const VideoStreamConfiguration&,DecodedFrameSink&,std::string*);
  VideoDecodeSubmitResult submitCMSampleBuffer(CMSampleBufferRef,std::uint64_t,std::string*);
  VideoDecodeDrainProgress beginEndOfStream(std::uint64_t,std::string*);
  VideoDecodeDrainProgress drainPresentation(std::uint64_t,std::string*);
  VideoDecodeDrainProgress drainEndOfStream(std::uint64_t,std::string*);
  void flush(std::uint64_t) noexcept;
  VideoDecoderRetireProgress retire(std::uint64_t,std::uint64_t) noexcept;
  void close() noexcept;
  VideoToolboxDecoderStats stats() const noexcept;
  VideoToolboxDecoderMemoryFacts memoryFacts() const noexcept;
  std::optional<std::string> takeLastError();
private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
}
