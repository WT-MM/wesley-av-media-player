#include "platform/macos/software_avcodec_audio_backend.hpp"
extern "C" {
#include <libavutil/frame.h>
}
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <thread>
#include <vector>
#include <array>
#include <cmath>
using namespace wam::macos;
#define CHECK(x) do{if(!(x)){std::fprintf(stderr,"line %d: %s\n",__LINE__,#x);std::abort();}}while(0)
template<class T>T read(std::ifstream& file){T v;file.read(reinterpret_cast<char*>(&v),sizeof(v));CHECK(file.good());return v;}
int main(int argc,char** argv) {
  CHECK(argc==4);bool dts=std::string(argv[3])=="dts";
  auto codec=dts?wam::media::avcodec::Codec::Dts:std::string(argv[3])=="mlp"?wam::media::avcodec::Codec::Mlp:wam::media::avcodec::Codec::TrueHd;
  std::ifstream file(argv[1],std::ios::binary);const auto count=read<unsigned>(file);
  std::vector<std::vector<std::byte>> packets;
  for(unsigned i=0;i<count;++i){auto size=read<unsigned>(file);packets.emplace_back(size);file.read(reinterpret_cast<char*>(packets.back().data()),size);CHECK(file.good());}
  std::ifstream reference(argv[2],std::ios::binary|std::ios::ate);auto size=reference.tellg();CHECK(size>0);reference.seekg(0);
  std::vector<float> expected(static_cast<std::size_t>(size)/4);reference.read(reinterpret_cast<char*>(expected.data()),size);
  SoftwareAvcodecAudioBackend backend(codec);
  NativeAudioBackendConfiguration config;config.input.sampleRate=48000;config.input.channels=2;config.input.framesPerPacket=dts?512:40;config.outputSampleRate=48000;config.outputChannels=2;
  std::string error;CHECK(backend.configure(config,&error));
  for(unsigned pass=0;pass<2;++pass) {
    if(pass)CHECK(backend.reset(&error));
    std::array<float,4096*2> output{};std::size_t packetIndex=0,frames=0;bool drained=false;
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
    while(!drained){
      CHECK(std::chrono::steady_clock::now()<deadline);
      NativeAudioBackendInput input;NativeAudioPacketDescription packet;
      if(packetIndex<packets.size()) {packet.byteSize=static_cast<unsigned>(packets[packetIndex].size());packet.variableFrames=config.input.framesPerPacket;input.bytes=packets[packetIndex];input.packets={&packet,1};}
      else input.endOfStream=true;
      auto result=backend.convert(input,output);CHECK(!result.failed);CHECK(result.consumedPackets<=1);CHECK(result.producedFrames<=4096);
      if(result.consumedPackets){CHECK(result.finalInputReleased);++packetIndex;}
      CHECK((frames+result.producedFrames)*2<=expected.size());
      for(std::size_t i=0;i<result.producedFrames*2;++i)CHECK(std::abs(output[i]-expected[frames*2+i])<=(dts?0.000002F:0.0F));
      frames+=result.producedFrames;drained=result.drained;std::this_thread::yield();
    }
    CHECK(frames*2==expected.size());
    std::array<wam::media::AudioChannelRole,8> roles;std::size_t roleCount=0;
    CHECK(backend.outputChannelRoles(roles,&roleCount));CHECK(roleCount==2);CHECK(roles[0]==wam::media::AudioChannelRole::Left);CHECK(roles[1]==wam::media::AudioChannelRole::Right);
  }
  backend.close();config.input.channels=6;config.outputChannels=6;
  CHECK(backend.configure(config,&error));
  AVFrame* frame=av_frame_alloc();CHECK(frame);frame->format=AV_SAMPLE_FMT_FLTP;
  frame->sample_rate=48000;frame->nb_samples=8193;av_channel_layout_default(&frame->ch_layout,6);
  CHECK(av_frame_get_buffer(frame,0)==0);
  for(int c=0;c<6;++c)for(int f=0;f<8193;++f)reinterpret_cast<float*>(frame->extended_data[c])[f]=float(c)*0.01F+float(f)*0.00001F;
  std::array<float,4096*6> slab{};std::size_t offset=0;
  for(std::size_t expectedFrames:{4096U,4096U,1U}) {
    const auto received=SoftwareAvcodecAudioBackendTestAccess::receive(backend,*frame);
    CHECK(received==(expectedFrames==1?wam::media::avcodec::FrameResult::Accepted:wam::media::avcodec::FrameResult::Backpressure));
    const auto converted=backend.convert({},slab);CHECK(!converted.failed && converted.producedFrames==expectedFrames);
    for(std::size_t f=0;f<expectedFrames;++f)for(int c=0;c<6;++c)
      CHECK(slab[f*6+c]==float(c)*0.01F+float(offset+f)*0.00001F);
    offset+=expectedFrames;
  }
  CHECK(offset==8193);av_frame_free(&frame);backend.close();
  std::puts("audio sample count, zero-offset PCM comparison, roles, packet release, EOS and reset passed");
}
