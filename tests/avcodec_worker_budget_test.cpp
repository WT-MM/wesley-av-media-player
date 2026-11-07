#include "media/avcodec/decode_worker.hpp"
#include "media/avcodec/closure.hpp"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mach/mach.h>
#include "support/expect.hpp"
using namespace wam::media::avcodec;
static unsigned threads() {
  thread_act_array_t list{};mach_msg_type_number_t count{};
  EXPECT(task_threads(mach_task_self(),&list,&count)==KERN_SUCCESS);
  for(unsigned i=0;i<count;++i)mach_port_deallocate(mach_task_self(),list[i]);
  vm_deallocate(mach_task_self(),reinterpret_cast<vm_address_t>(list),count*sizeof(thread_t));
  return count;
}
static FrameResult receive(void*,const AVFrame&,const PacketTiming&) noexcept {return FrameResult::Accepted;}
int main() {
  const unsigned before=threads();
  std::array<std::unique_ptr<DecodeWorker>,16> workers;
  Configuration config;config.codec=Codec::Mpeg4;config.width=320;config.height=180;
  for(auto& worker:workers) {worker=std::make_unique<DecodeWorker>(FrameHandler{receive,nullptr});EXPECT(worker->configure(config));}
  const unsigned during=threads();EXPECT(during==before+16);
  DecodeWorker excess({receive,nullptr});EXPECT(excess.configure(config));
  EXPECT(!excess.failure() && !excess.hasCapacity());
  EXPECT(DecodeWorker::pendingWorkers()==1 && threads()==during);
  excess.close();
  EXPECT(DecodeWorker::pendingWorkers()==0);
  for(auto& worker:workers)worker->close();
  EXPECT(!nativeClosurePresent());
  const unsigned after=threads();EXPECT(after==before);
  std::printf("threads before=%u during=%u after=%u; worker 17 queued without another thread, then cancelled\n",before,during,after);
  return failures == 0 ? 0 : 1;
}
