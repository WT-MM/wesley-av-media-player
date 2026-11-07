#include "media/avcodec/api.hpp"
#include "media/avcodec/decode_worker.hpp"
#include "media/avcodec/runtime.hpp"
#include <array>
#include <cstdio>
#include <memory>
#include <thread>
#include "support/expect.hpp"
using namespace wam::media;
using namespace wam::media::avcodec;
FrameResult receive(void*,const AVFrame&,const PacketTiming&) noexcept { return FrameResult::Accepted; }
int main() {
  const auto asp=softwareDecoderReservation(MediaCodec::Mpeg4Visual,1920,1088,8,1,0);
  const auto h264=softwareDecoderReservation(MediaCodec::H264,1920,1088,10,2,0);
  REQUIRE(asp && h264 && asp->referenceSlots==8 && h264->referenceSlots==38);
  EXPECT(asp->planeBytes==1920ULL*1152*3/2+192);
  EXPECT(h264->planeBytes==1920ULL*1152*4+192);
  EXPECT(h264->referenceBytes==38*h264->planeBytes);
  EXPECT(!softwareDecoderReservation(MediaCodec::H264,4096,2320,10,2,0));
  EXPECT(softwareDecoderReservation(MediaCodec::Mpeg4Visual,4096,2320,8,1,0));
  // The same sorted-axis ceiling as admission: two long axes are refused even
  // under the pixel cap.
  EXPECT(!softwareDecoderReservation(MediaCodec::Mpeg4Visual,3000,3000,8,1,0));
  RuntimeLease runtime;REQUIRE(runtime.acquire()==nullptr);
  auto& functions=api();void* domain=functions.av_wam_reservation_begin(1024);REQUIRE(domain);
  auto* first=functions.av_mallocz(512);REQUIRE(first && reinterpret_cast<std::uintptr_t>(first)%64==0);
  EXPECT(functions.av_wam_reservation_used(domain)>512);
  EXPECT(!functions.av_mallocz(512));EXPECT(functions.av_wam_reservation_exhausted(domain));
  std::thread freeThread([&]{functions.av_free(first);});freeThread.join();
  EXPECT(functions.av_wam_reservation_end(domain)==0);
  domain=functions.av_wam_reservation_begin(1024);REQUIRE(domain);
  first=functions.av_mallocz(128);REQUIRE(first);
  EXPECT(functions.av_wam_reservation_end(domain)==192);
  std::thread lateFree([&]{functions.av_free(first);});lateFree.join();
  std::array<std::unique_ptr<DecodeWorker>,16> workers;
  Configuration config;config.codec=Codec::Mlp;config.rate=48000;config.channels=2;
  for(auto& worker:workers) {worker=std::make_unique<DecodeWorker>(FrameHandler{receive,nullptr});EXPECT(worker->configure(config));}
  EXPECT(DecodeWorker::reservedWorkers()==16);
  const auto reserved=DecodeWorker::reservedProcessBytes();EXPECT(reserved>0);
  // A seventeenth worker queues without reserving; queue overflow is
  // avcodec_admission_queue's subject.
  DecodeWorker queued({receive,nullptr});EXPECT(queued.configure(config));
  EXPECT(!queued.hasCapacity() && DecodeWorker::pendingWorkers()==1 && DecodeWorker::reservedWorkers()==16);
  queued.close();EXPECT(DecodeWorker::reservedProcessBytes()==reserved && DecodeWorker::pendingWorkers()==0);
  for(auto& worker:workers)worker->close();
  EXPECT(DecodeWorker::reservedProcessBytes()==0 && DecodeWorker::reservedWorkers()==0);
  DecodeWorker large({receive,nullptr});config.codec=Codec::Mpeg4;config.width=1920;config.height=1088;
  config.rate=0;config.channels=0;EXPECT(large.configure(config));large.close();
  EXPECT(DecodeWorker::reservedProcessBytes()==0 && DecodeWorker::reservedWorkers()==0);
  std::puts("derived planes, enforced allocator, cross-thread retirement, 16-worker admission and queued cancellation passed");
  return failures == 0 ? 0 : 1;
}
