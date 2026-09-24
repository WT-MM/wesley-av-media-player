#include "media/avcodec/decode_worker.hpp"
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
using namespace wam::media::avcodec;
#define CHECK(x) do { if (!(x)) { std::fprintf(stderr, "%d: %s\n", __LINE__, #x); std::abort(); } } while (0)
static FrameResult receive(void*, const AVFrame&, const PacketTiming&) noexcept {
  return FrameResult::Accepted;
}
int main() {
  Configuration config;
  config.codec=Codec::H264; config.width=320; config.height=180;
  std::array<std::unique_ptr<DecodeWorker>, 48> lanes;
  for (auto& lane : lanes) {
    lane=std::make_unique<DecodeWorker>(FrameHandler{receive,nullptr});
    CHECK(lane->configure(config));
  }
  CHECK(DecodeWorker::reservedWorkers()==16);
  CHECK(DecodeWorker::pendingWorkers()==32);
  const auto bytes=DecodeWorker::reservedProcessBytes();
  CHECK(bytes>0);
  DecodeWorker overflow({receive,nullptr});
  CHECK(!overflow.configure(config));
  CHECK(std::strcmp(overflow.failure(), "AvcodecWorkerBudgetExceeded")==0);
  overflow.close();
  lanes[20].reset(); // queued cancellation removes exactly this identity
  CHECK(DecodeWorker::pendingWorkers()==31);
  CHECK(DecodeWorker::reservedProcessBytes()==bytes);
  lanes[0].reset(); // FIFO admission, with no seventeenth thread
  const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
  while (!lanes[16]->hasCapacity()) {
    CHECK(!lanes[16]->failure());
    CHECK(std::chrono::steady_clock::now()<deadline);
    std::this_thread::yield();
  }
  CHECK(DecodeWorker::pendingWorkers()==30);
  CHECK(!lanes[17]->hasCapacity());
  CHECK(DecodeWorker::peakReservedWorkers()==16);
  // Cancel waiting jobs before closing active lanes: none may start afterward.
  for (unsigned i=17;i<lanes.size();++i) lanes[i].reset();
  CHECK(DecodeWorker::pendingWorkers()==0);
  for (auto& lane:lanes) lane.reset();
  CHECK(DecodeWorker::reservedWorkers()==0);
  CHECK(DecodeWorker::reservedProcessBytes()==0);
  std::puts("16 active / 32 queued; FIFO admission, overflow refusal, cancellation and zero-byte retirement passed");
}
