#include "media/avcodec/api.hpp"
#include "software_avcodec_audio_backend.hpp"
extern "C" {
#include <libavutil/frame.h>
#include <libavutil/samplefmt.h>
}
#include <algorithm>
#include <array>
#include <atomic>
#include <cstring>
#include <limits>
#include <vector>
namespace wam::macos {
namespace {
using namespace media::avcodec;
media::AudioChannelRole role(AVChannel channel) {
  using R=media::AudioChannelRole;
  switch(channel) {
  case AV_CHAN_FRONT_LEFT:return R::Left;
  case AV_CHAN_FRONT_RIGHT:return R::Right;
  case AV_CHAN_FRONT_CENTER:return R::Center;
  case AV_CHAN_LOW_FREQUENCY:return R::LowFrequency;
  case AV_CHAN_BACK_LEFT:case AV_CHAN_SIDE_LEFT:return R::SurroundLeft;
  case AV_CHAN_BACK_RIGHT:case AV_CHAN_SIDE_RIGHT:return R::SurroundRight;
  case AV_CHAN_BACK_CENTER:return R::SurroundCenter;
  default:return R::Unmapped;
  }
}
float sample(const std::uint8_t* address,AVSampleFormat format) noexcept {
  switch(format) {
  case AV_SAMPLE_FMT_U8:return (static_cast<int>(*address)-128)*(1.0F/128.0F);
  case AV_SAMPLE_FMT_S16:{std::int16_t v;std::memcpy(&v,address,2);return static_cast<float>(v)*(1.0F/32768.0F);}
  case AV_SAMPLE_FMT_S32:{std::int32_t v;std::memcpy(&v,address,4);return static_cast<float>(v)*(1.0F/2147483648.0F);}
  case AV_SAMPLE_FMT_FLT:{float v;std::memcpy(&v,address,4);return v;}
  case AV_SAMPLE_FMT_DBL:{double v;std::memcpy(&v,address,8);return static_cast<float>(v);}
  default:return 0;
  }
}
}
struct SoftwareAvcodecAudioBackend::Impl {
  Codec codec;
  NativeAudioBackendConfiguration configuration;
  std::vector<std::byte> extra;
  std::unique_ptr<DecodeWorker> worker;
  std::array<float,4096*media::kMaximumDownmixSourceChannels> slab{};
  static_assert(sizeof(slab)==kNativeSoftwareAudioConversionScratchBytes);
  std::array<media::AudioChannelRole,media::kMaximumDownmixSourceChannels> roles{};
  std::atomic<bool> filled{false},layoutKnown{false};
  std::atomic<const char*> error{nullptr};
  std::size_t slabFrames{},offset{};
  std::int64_t nextFrame{};
  bool eos{},configured{};
  std::uint64_t generation{1};
  static FrameResult receive(void* opaque,const AVFrame& frame,const PacketTiming&) noexcept {
    auto& s=*static_cast<Impl*>(opaque);
    if(s.filled.load(std::memory_order_acquire))return FrameResult::Backpressure;
    if(frame.sample_rate!=int(s.configuration.outputSampleRate) ||
       frame.ch_layout.nb_channels!=int(s.configuration.outputChannels) || frame.nb_samples<=0) {
      s.error.store("AvcodecAudioFormatChanged"); return FrameResult::Failed;
    }
    const unsigned channels=s.configuration.outputChannels;
    std::array<media::AudioChannelRole,media::kMaximumDownmixSourceChannels> actual{};
    for(unsigned i=0;i<channels;++i) {
      actual[i]=role(wam::media::avcodec::api().av_channel_layout_channel_from_index(&frame.ch_layout,i));
      if(actual[i]==media::AudioChannelRole::Unmapped) {s.error.store("AvcodecAudioChannelRoleUnsupported");return FrameResult::Failed;}
    }
    if(s.layoutKnown.load(std::memory_order_acquire)) {
      if(actual!=s.roles) {s.error.store("AvcodecAudioChannelLayoutChanged");return FrameResult::Failed;}
    } else {s.roles=actual;s.layoutKnown.store(true,std::memory_order_release);}
    const auto format=static_cast<AVSampleFormat>(frame.format);
    const auto packed=wam::media::avcodec::api().av_get_packed_sample_fmt(format);
    if(packed!=AV_SAMPLE_FMT_U8 && packed!=AV_SAMPLE_FMT_S16 && packed!=AV_SAMPLE_FMT_S32 &&
       packed!=AV_SAMPLE_FMT_FLT && packed!=AV_SAMPLE_FMT_DBL) {
      s.error.store("AvcodecAudioSampleFormatUnsupported");return FrameResult::Failed;
    }
    const auto bytes=static_cast<std::size_t>(wam::media::avcodec::api().av_get_bytes_per_sample(format));
    const bool planar=wam::media::avcodec::api().av_sample_fmt_is_planar(format);
    const auto count=std::min<std::size_t>(4096,static_cast<std::size_t>(frame.nb_samples)-s.offset);
    for(std::size_t f=0;f<count;++f)for(unsigned c=0;c<channels;++c) {
      const auto* source=frame.extended_data[planar?c:0]+((s.offset+f)*(planar?1:channels)+(planar?0:c))*bytes;
      s.slab[f*channels+c]=sample(source,packed);
    }
    s.slabFrames=count;s.offset+=count;
    const bool complete=s.offset==static_cast<std::size_t>(frame.nb_samples);
    if(complete)s.offset=0;
    s.filled.store(true,std::memory_order_release);
    return complete?FrameResult::Accepted:FrameResult::Backpressure;
  }
  bool start() {
    worker=std::make_unique<DecodeWorker>(FrameHandler{receive,this});
    Configuration config;config.codec=codec;config.generation=generation;config.epoch=generation;
    config.extradata=extra;config.rate=configuration.outputSampleRate;config.channels=configuration.outputChannels;
    configured=worker->configure(config);return configured;
  }
};
SoftwareAvcodecAudioBackend::SoftwareAvcodecAudioBackend(Codec codec):impl_(std::make_unique<Impl>()) {impl_->codec=codec;}
SoftwareAvcodecAudioBackend::~SoftwareAvcodecAudioBackend(){close();}
bool SoftwareAvcodecAudioBackend::configure(const NativeAudioBackendConfiguration& config,std::string* error) {
  close();auto& s=*impl_;
  if (config.decodePlan.implementation != media::DecodeImplementation::Libavcodec ||
      config.decodePlan.configurationRepresentation != media::DecodeConfigurationRepresentation::RawExtradata ||
      !config.magicCookie.empty() ||
      config.rawExtradata.size()>media::MediaSourceLimits::kHardMaximumCodecConfigurationBytes) {
    if (error) *error="AvcodecAudioConfigurationRepresentationUnsupported";return false;
  }
  if(!config.outputSampleRate || config.outputSampleRate!=config.input.sampleRate ||
     !config.outputChannels || config.outputChannels>media::kMaximumDownmixSourceChannels ||
     config.outputChannels!=config.input.channels || !config.input.framesPerPacket) {
    if(error)*error="AvcodecAudioResamplingUnsupported";return false;
  }
  s.configuration=config;s.extra.assign(config.rawExtradata.begin(),config.rawExtradata.end());s.configuration.rawExtradata=s.extra;
  s.nextFrame=0;s.eos=false;s.offset=0;s.error.store(nullptr);s.layoutKnown.store(false);
  if(!s.start()) {if(error)*error=s.worker->failure()?s.worker->failure():"AvcodecAudioConfigureFailed";return false;}
  return true;
}
NativeAudioBackendResult SoftwareAvcodecAudioBackend::convert(NativeAudioBackendInput input,std::span<float> output) {
  auto& s=*impl_;NativeAudioBackendResult result;
  if(!s.configured || s.error.load() || s.worker->failure()) {result.failed=true;return result;}
  if(s.filled.load(std::memory_order_acquire)) {
    const auto samples=s.slabFrames*s.configuration.outputChannels;
    if(output.size()<samples) {result.failed=true;return result;}
    std::copy_n(s.slab.data(),samples,output.data());result.producedFrames=s.slabFrames;
    s.filled.store(false,std::memory_order_release);s.worker->retryOutput();
  }
  for(const auto& packet:input.packets) {
    if(packet.startOffset<0 || std::uint64_t(packet.startOffset)>input.bytes.size() ||
       packet.byteSize>input.bytes.size()-static_cast<std::size_t>(packet.startOffset)) {result.failed=true;return result;}
    const auto frames=packet.variableFrames?packet.variableFrames:s.configuration.input.framesPerPacket;
    if(s.nextFrame>INT64_MAX-frames) {result.failed=true;return result;}
    PacketTiming timing{{s.nextFrame,static_cast<std::int32_t>(s.configuration.outputSampleRate)},
      {s.nextFrame,static_cast<std::int32_t>(s.configuration.outputSampleRate)},
      {frames,static_cast<std::int32_t>(s.configuration.outputSampleRate)},s.generation,s.generation};
    const auto submitted=s.worker->submit(input.bytes.subspan(static_cast<std::size_t>(packet.startOffset),packet.byteSize),timing);
    if(submitted==WorkerResult::Backpressure)break;
    if(submitted!=WorkerResult::Accepted){result.failed=true;return result;}
    s.nextFrame+=frames;++result.consumedPackets;
  }
  result.finalInputReleased=!input.packets.empty() && result.consumedPackets==input.packets.size();
  if(input.endOfStream && !s.eos) {
    if(!input.packets.empty()) {result.failed=true;return result;}
    if(s.worker->endOfStream(s.generation)!=WorkerResult::Accepted){result.failed=true;return result;}
    s.eos=true;
  }
  result.drained=s.eos && s.worker->drained() && !s.filled.load(std::memory_order_acquire);
  result.needsInput=!s.eos && s.worker->hasCapacity();
  return result;
}
bool SoftwareAvcodecAudioBackend::reset(std::string* error) {
  auto& s=*impl_;if(s.worker)s.worker->close();s.worker.reset();
  s.filled.store(false);s.offset=0;s.nextFrame=0;s.eos=false;s.error.store(nullptr);++s.generation;
  try {return s.start();}catch(...){if(error)*error="AvcodecAudioResetFailed";return false;}
}
void SoftwareAvcodecAudioBackend::close() noexcept {
  auto& s=*impl_;if(s.worker)s.worker->close();s.worker.reset();s.filled.store(false);s.configured=false;
}
bool SoftwareAvcodecAudioBackend::outputChannelRoles(std::span<media::AudioChannelRole> roles,std::size_t* count) noexcept {
  auto& s=*impl_;if(count)*count=0;
  if(!s.layoutKnown.load(std::memory_order_acquire)||roles.size()<s.configuration.outputChannels)return false;
  std::copy_n(s.roles.begin(),s.configuration.outputChannels,roles.begin());
  if(count)*count=s.configuration.outputChannels;return true;
}
#if defined(WAM_AVCODEC_AUDIO_TESTING)
media::avcodec::FrameResult SoftwareAvcodecAudioBackendTestAccess::receive(
    SoftwareAvcodecAudioBackend& backend,const AVFrame& frame) noexcept {
  return SoftwareAvcodecAudioBackend::Impl::receive(backend.impl_.get(),frame,{});
}
#endif

}
