#include "media/avcodec/api.hpp"
#include "media/avcodec/decode_worker.hpp"
#include "media/avcodec/runtime.hpp"
#include <array>
#include <cstdio>
#include <cstring>
#include <memory>
#include <thread>
using namespace wam::media;
using namespace wam::media::avcodec;
#define CHECK(x) do { if(!(x)) { std::fprintf(stderr,"line %d: %s\n",__LINE__,#x);return 1; } } while(0)
FrameResult receive(void*,const AVFrame&,const PacketTiming&) noexcept { return FrameResult::Accepted; }
int main() {
  const auto asp=softwareDecoderReservation(MediaCodec::Mpeg4Visual,1920,1088,8,1,0);
  const auto h264=softwareDecoderReservation(MediaCodec::H264,1920,1088,10,2,0);
  CHECK(asp && h264 && asp->referenceSlots==8 && h264->referenceSlots==38);
  CHECK(asp->planeBytes==1920ULL*1152*3/2+192);
  CHECK(h264->planeBytes==1920ULL*1152*4+192);
  CHECK(h264->referenceBytes==38*h264->planeBytes);
  CHECK(!softwareDecoderReservation(MediaCodec::H264,4096,2320,10,2,0));
  CHECK(softwareDecoderReservation(MediaCodec::Mpeg4Visual,4096,2320,8,1,0));
  RuntimeLease runtime;CHECK(runtime.acquire()==nullptr);
  auto& functions=api();void* domain=functions.av_wam_reservation_begin(1024);CHECK(domain);
  auto* first=functions.av_mallocz(512);CHECK(first && reinterpret_cast<std::uintptr_t>(first)%64==0);
  CHECK(functions.av_wam_reservation_used(domain)>512);
  CHECK(!functions.av_mallocz(512));CHECK(functions.av_wam_reservation_exhausted(domain));
  std::thread freeThread([&]{functions.av_free(first);});freeThread.join();
  CHECK(functions.av_wam_reservation_end(domain)==0);
  domain=functions.av_wam_reservation_begin(1024);CHECK(domain);
  first=functions.av_mallocz(128);CHECK(first);
  CHECK(functions.av_wam_reservation_end(domain)==192);
  std::thread lateFree([&]{functions.av_free(first);});lateFree.join();
  std::array<std::unique_ptr<DecodeWorker>,16> workers;
  Configuration config;config.codec=Codec::Mlp;config.rate=48000;config.channels=2;
  for(auto& worker:workers) {worker=std::make_unique<DecodeWorker>(FrameHandler{receive,nullptr});CHECK(worker->configure(config));}
  CHECK(DecodeWorker::reservedWorkers()==16);
  const auto reserved=DecodeWorker::reservedProcessBytes();CHECK(reserved>0);
  DecodeWorker refused({receive,nullptr});CHECK(!refused.configure(config));
  CHECK(refused.failure() && std::strcmp(refused.failure(),"AvcodecWorkerBudgetExceeded")==0);
  refused.close();CHECK(DecodeWorker::reservedProcessBytes()==reserved);
  for(auto& worker:workers)worker->close();
  CHECK(DecodeWorker::reservedProcessBytes()==0 && DecodeWorker::reservedWorkers()==0);
  DecodeWorker large({receive,nullptr});config.codec=Codec::Mpeg4;config.width=1920;config.height=1088;
  config.rate=0;config.channels=0;CHECK(large.configure(config));large.close();
  CHECK(DecodeWorker::reservedProcessBytes()==0 && DecodeWorker::reservedWorkers()==0);
  std::puts("derived planes, enforced allocator, cross-thread retirement, 16-worker admission and cancellation passed");
}
