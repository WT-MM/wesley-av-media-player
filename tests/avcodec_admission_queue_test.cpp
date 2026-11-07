#include "media/avcodec/decode_worker.hpp"
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include "support/expect.hpp"
using namespace wam::media::avcodec;
static FrameResult receive(void*, const AVFrame&, const PacketTiming&) noexcept {
  return FrameResult::Accepted;
}
int main() {
  Configuration config;
  config.codec=Codec::H264; config.width=320; config.height=180;
  std::array<std::unique_ptr<DecodeWorker>, 48> lanes;
  for (auto& lane : lanes) {
    lane=std::make_unique<DecodeWorker>(FrameHandler{receive,nullptr});
    EXPECT(lane->configure(config));
  }
  EXPECT(DecodeWorker::reservedWorkers()==16);
  EXPECT(DecodeWorker::pendingWorkers()==32);
  const auto bytes=DecodeWorker::reservedProcessBytes();
  EXPECT(bytes>0);
  DecodeWorker overflow({receive,nullptr});
  EXPECT(!overflow.configure(config));
  EXPECT(overflow.failure() && std::strcmp(overflow.failure(), "AvcodecWorkerBudgetExceeded")==0);
  overflow.close();
  lanes[20].reset(); // queued cancellation removes exactly this identity
  EXPECT(DecodeWorker::pendingWorkers()==31);
  EXPECT(DecodeWorker::reservedProcessBytes()==bytes);
  lanes[0].reset(); // FIFO admission, with no seventeenth thread
  const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
  while (!lanes[16]->hasCapacity()) {
    REQUIRE(!lanes[16]->failure());
    REQUIRE(std::chrono::steady_clock::now()<deadline);
    std::this_thread::yield();
  }
  EXPECT(DecodeWorker::pendingWorkers()==30);
  EXPECT(!lanes[17]->hasCapacity());
  EXPECT(DecodeWorker::peakReservedWorkers()==16);
  // Cancel waiting jobs before closing active lanes: none may start afterward.
  for (unsigned i=17;i<lanes.size();++i) lanes[i].reset();
  EXPECT(DecodeWorker::pendingWorkers()==0);
  for (auto& lane:lanes) lane.reset();
  EXPECT(DecodeWorker::reservedWorkers()==0);
  EXPECT(DecodeWorker::reservedProcessBytes()==0);
  std::puts("16 active / 32 queued; FIFO admission, overflow refusal, cancellation and zero-byte retirement passed");
  return failures == 0 ? 0 : 1;
}
