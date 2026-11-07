#include "media/avcodec/decode_worker.hpp"
#include "media/avcodec_time.hpp"
#include "media/native_decode_plan.hpp"
#include "media/avcodec/runtime.hpp"
extern "C" {
#include <libavutil/frame.h>
}
#include "support/expect.hpp"
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <limits>
#include <thread>
#include <vector>
using namespace wam::media;
using namespace wam::media::avcodec;
struct Observer {
  std::atomic<bool> blocked{true};
  std::atomic<unsigned> calls{0}, count{0};
  unsigned width{320},height{180};
  std::int64_t previous{-1};
  std::thread::id owner{std::this_thread::get_id()};
  static FrameResult receive(void* opaque,const AVFrame& frame,const PacketTiming& timing) noexcept {
    auto& self=*static_cast<Observer*>(opaque);
    REQUIRE(std::this_thread::get_id()!=self.owner);
    if (self.blocked.load()) {
      self.calls.fetch_add(1);
      return FrameResult::Backpressure;
    }
    REQUIRE(timing.generation==7 && timing.epoch==3);
    REQUIRE(timing.pts.valid() && timing.duration.valid());
    REQUIRE(__int128(timing.duration.value)*25==timing.duration.timescale);
    const auto time=__int128(timing.pts.value)*1000/timing.pts.timescale;
    REQUIRE(time==__int128(self.count.load())*40);
    REQUIRE(time>self.previous);
    self.previous=static_cast<std::int64_t>(time);
    REQUIRE(frame.width==int(self.width) && frame.height==int(self.height));
    self.count.fetch_add(1);
    return FrameResult::Accepted;
  }
};
template<class F> void until(F predicate) {
  const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
  while(!predicate()) { REQUIRE(std::chrono::steady_clock::now()<deadline); std::this_thread::yield(); }
}
template<class T> T read(std::ifstream& stream) { T v; stream.read(reinterpret_cast<char*>(&v),sizeof(v)); REQUIRE(stream.good()); return v; }
int main(int argc,char** argv) {
  REQUIRE(argc==3 || argc==5);
  const unsigned width=argc==5?std::atoi(argv[3]):320;
  const unsigned height=argc==5?std::atoi(argv[4]):180;
  REQUIRE(runtimeFailure()==nullptr);
  EXPECT(!avcodecExactTime(INT64_MIN,1,1000));
  EXPECT(!avcodecExactTime(INT64_MAX,2,1));
  EXPECT((avcodecExactTime(INT64_MAX,2,2)==MediaTime{INT64_MAX,1}));
  EXPECT((avcodecExactTime(-6,5,15)==MediaTime{-2,1}));
  EXPECT(!avcodecExactTime(5,0,1));
  auto plan=chooseDecodePlan({DecodeRefusal::None,DecodeRefusal::None,DecodeRefusal::NotApplicable,DecodeRefusal::None});
  EXPECT(plan.implementation==DecodeImplementation::VideoToolboxHardware);
  plan=chooseDecodePlan({DecodeRefusal::HardwareUnavailable,DecodeRefusal::AppleProfileUnsupported,DecodeRefusal::NotApplicable,DecodeRefusal::None});
  EXPECT(plan.implementation==DecodeImplementation::Libavcodec);
  std::ifstream file(argv[1],std::ios::binary);
  const auto extraSize=read<std::uint32_t>(file), packets=read<std::uint32_t>(file);
  std::vector<std::byte> extra(extraSize); file.read(reinterpret_cast<char*>(extra.data()),extraSize);
  Observer observer;observer.width=width;observer.height=height;
  DecodeWorker worker({Observer::receive,&observer});
  Configuration config; config.codec=std::strcmp(argv[2],"h264")==0?Codec::H264:Codec::Mpeg4;
  config.extradata=extra; config.generation=7; config.epoch=3; config.width=width; config.height=height;
  if (std::uint64_t(width)*height>DecodeWorker::kMaximumSoftwarePixels) {
    EXPECT(!worker.configure(config));
    EXPECT(worker.failure() && std::strcmp(worker.failure(),"AvcodecSoftwareReferenceBudgetExceeded")==0);
    std::puts(worker.failure());return failures==0?0:1;
  }
  REQUIRE(worker.configure(config));
  bool pressure=false;
  for(unsigned i=0;i<packets;++i) {
    const auto size=read<std::uint32_t>(file);
    const auto pts=read<std::int64_t>(file), dts=read<std::int64_t>(file), duration=read<std::int64_t>(file);
    std::vector<std::byte> bytes(size); file.read(reinterpret_cast<char*>(bytes.data()),size); EXPECT(file.good());
    PacketTiming timing{{pts,1000},dts==INT64_MIN?MediaTime{}:MediaTime{dts,1000},{duration,1000},7,3};
    auto stale=timing; stale.generation=6;
    EXPECT(worker.submit(bytes,stale)==WorkerResult::StaleGeneration);
    auto result=worker.submit(bytes,timing);
    if(result==WorkerResult::Backpressure) {
      pressure=true;
      until([&] { REQUIRE(!worker.failure()); return observer.calls.load()!=0; });
      observer.blocked.store(false); worker.retryOutput();
      until([&] { REQUIRE(!worker.failure()); result=worker.submit(bytes,timing); return result!=WorkerResult::Backpressure; });
    }
    EXPECT(result==WorkerResult::Accepted);
    std::fill(bytes.begin(),bytes.end(),std::byte{0xA5});
  }
  observer.blocked.store(false); worker.retryOutput();
  EXPECT(worker.endOfStream(6)==WorkerResult::StaleGeneration);
  EXPECT(worker.endOfStream(7)==WorkerResult::Accepted);
  until([&] { if(worker.failure()) std::fprintf(stderr,"%s\n",worker.failure()); REQUIRE(!worker.failure()); return worker.drained(); });
  EXPECT(observer.count==packets && pressure);
  worker.close();
  std::printf("decoded %u reordered frames; owned packets, EOS, backpressure, generation and worker isolation passed\n",packets);
  return failures==0?0:1;
}
