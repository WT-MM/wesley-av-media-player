#pragma once
#include "native_audio_converter.hpp"
#include "media/avcodec/decode_worker.hpp"
struct AVFrame;
namespace wam::macos {
class SoftwareAvcodecAudioBackend final:public NativeAudioConverterBackend {
public:
  explicit SoftwareAvcodecAudioBackend(media::avcodec::Codec codec);
  ~SoftwareAvcodecAudioBackend() override;
  bool configure(const NativeAudioBackendConfiguration&,std::string*) override;
  NativeAudioBackendResult convert(NativeAudioBackendInput,std::span<float>) override;
  bool reset(std::string*) override;
  void close() noexcept override;
  bool outputChannelRoles(std::span<media::AudioChannelRole>,std::size_t*) noexcept override;
private:
  friend struct SoftwareAvcodecAudioBackendTestAccess;
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
#if defined(WAM_AVCODEC_AUDIO_TESTING)
struct SoftwareAvcodecAudioBackendTestAccess {
  static media::avcodec::FrameResult receive(SoftwareAvcodecAudioBackend&,const AVFrame&) noexcept;
};
#endif
}
