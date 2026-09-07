#include "media/avcodec/api.hpp"
#include "media/avcodec/runtime.hpp"
#include "media/avcodec/allocation_probe.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <vector>
using namespace wam::media::avcodec;
#define REQUIRE(x) do { if (!(x)) { std::fprintf(stderr,"line %d: %s\n",__LINE__,#x); std::abort(); } } while(0)
template<class T> T read(std::ifstream& input) {
  T value{}; input.read(reinterpret_cast<char*>(&value),sizeof(value)); REQUIRE(input.good()); return value;
}
int main(int argc,char** argv) {
  REQUIRE(argc==5);
  std::ifstream input(argv[1],std::ios::binary);
  const auto extraSize=read<unsigned>(input), packetCount=read<unsigned>(input);
  std::vector<unsigned char> extra(extraSize);
  input.read(reinterpret_cast<char*>(extra.data()),extra.size());
  std::vector<std::vector<unsigned char>> packets;
  for (unsigned n=0;n<packetCount;++n) {
    const auto size=read<unsigned>(input);
    for(unsigned i=0;i<3;++i) (void)read<long long>(input);
    auto& packet=packets.emplace_back(size+AV_INPUT_BUFFER_PADDING_SIZE,0);
    input.read(reinterpret_cast<char*>(packet.data()),size); REQUIRE(input.good());
  }
  RuntimeLease runtime; REQUIRE(!runtime.acquire());
  const auto id=std::strcmp(argv[2],"h264")==0?AV_CODEC_ID_H264:
                std::strcmp(argv[2],"vp9")==0?AV_CODEC_ID_VP9:AV_CODEC_ID_MPEG4;
  const auto width=std::atoi(argv[3]),height=std::atoi(argv[4]);
  REQUIRE(width>0 && height>0 && width<=4096 && height<=4096);
  // This diagnostic measures beyond production admission; it cannot widen it.
  allocationProbeBegin();
  const auto* decoder=api().avcodec_find_decoder(id); REQUIRE(decoder);
  auto* context=api().avcodec_alloc_context3(decoder);
  auto* packet=api().av_packet_alloc(); auto* frame=api().av_frame_alloc();
  REQUIRE(context && packet && frame);
  context->width=width;context->height=height;context->max_pixels=9502720;
  context->thread_count=1;context->thread_type=0;
  context->err_recognition=AV_EF_BITSTREAM|AV_EF_BUFFER|AV_EF_EXPLODE;
  if (extraSize) {
    context->extradata=static_cast<unsigned char*>(api().av_mallocz(extraSize+AV_INPUT_BUFFER_PADDING_SIZE));
    REQUIRE(context->extradata); context->extradata_size=static_cast<int>(extraSize);
    std::memcpy(context->extradata,extra.data(),extraSize);
  }
  REQUIRE(api().avcodec_open2(context,decoder,nullptr)==0);
  unsigned decoded=0;
  auto receive=[&](bool draining) {
    for (;;) {
      const int status=api().avcodec_receive_frame(context,frame);
      if(status==AVERROR_EOF) { REQUIRE(draining); return; }
      if(status==AVERROR(EAGAIN)) { REQUIRE(!draining); return; }
      REQUIRE(status==0 && frame->width==width && frame->height==height);
      ++decoded;allocationProbeFrame();api().av_frame_unref(frame);
    }
  };
  for (auto& bytes:packets) {
    packet->data=bytes.data();packet->size=static_cast<int>(bytes.size()-AV_INPUT_BUFFER_PADDING_SIZE);
    REQUIRE(api().avcodec_send_packet(context,packet)==0);
    api().av_packet_unref(packet);receive(false);
  }
  REQUIRE(api().avcodec_send_packet(context,nullptr)==0);receive(true);
  REQUIRE(decoded==packetCount);
  api().av_frame_free(&frame);api().av_packet_free(&packet);api().avcodec_free_context(&context);
  allocationProbeEnd();
  std::printf("decoded=%u width=%d height=%d private_decoder_only=1\n",decoded,width,height);
}
