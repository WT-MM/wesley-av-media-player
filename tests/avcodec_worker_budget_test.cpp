#include "media/avcodec/decode_worker.hpp"
#include "media/avcodec/closure.hpp"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mach/mach.h>
using namespace wam::media::avcodec;
#define CHECK(x) do { if (!(x)) {std::fprintf(stderr,"line %d: %s\n",__LINE__,#x);std::abort();} } while(0)
static unsigned threads() {
  thread_act_array_t list{};mach_msg_type_number_t count{};
  CHECK(task_threads(mach_task_self(),&list,&count)==KERN_SUCCESS);
  for(unsigned i=0;i<count;++i)mach_port_deallocate(mach_task_self(),list[i]);
  vm_deallocate(mach_task_self(),reinterpret_cast<vm_address_t>(list),count*sizeof(thread_t));
  return count;
}
static FrameResult receive(void*,const AVFrame&,const PacketTiming&) noexcept {return FrameResult::Accepted;}
int main() {
  const unsigned before=threads();
  std::array<std::unique_ptr<DecodeWorker>,16> workers;
  Configuration config;config.codec=Codec::Mpeg4;config.width=320;config.height=180;
  for(auto& worker:workers) {worker=std::make_unique<DecodeWorker>(FrameHandler{receive,nullptr});CHECK(worker->configure(config));}
  const unsigned during=threads();CHECK(during==before+16);
  DecodeWorker excess({receive,nullptr});CHECK(!excess.configure(config));
  CHECK(excess.failure() && std::strcmp(excess.failure(),"AvcodecWorkerBudgetExceeded")==0);
  for(auto& worker:workers)worker->close();
  CHECK(!nativeClosurePresent());
  const unsigned after=threads();CHECK(after==before);
  std::printf("threads before=%u during=%u after=%u; worker 17 refused by budget\n",before,during,after);
}
