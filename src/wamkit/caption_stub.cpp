#include "include/WAMKit/WAMCaption.h"
#include <condition_variable>
#include <mutex>
#include <thread>
// Identical asynchronous callback contract on SDKs without SpeechAnalyzer.
struct Stub {
  wam_caption_callback_v1 callback;
  void *context;
  std::mutex mutex;
  std::condition_variable cv;
  uint64_t generation = 0;
  int kind = 0;
  bool stop = false;
  std::thread worker;
  Stub(wam_caption_callback_v1 cb,void* ctx):callback(cb),context(ctx),worker([this] {
    std::unique_lock lock(mutex);
    for (;;) {
      cv.wait(lock,[this] {return stop || kind;});
      if(stop) return;
      const auto g=generation; const auto event=kind; kind=0;
      lock.unlock();
      callback(context,g,event,0,0,0,0,"Apple Speech unavailable in this build");
      lock.lock();
    }
  }) {}
  void send(uint64_t g,int event) { std::lock_guard lock(mutex);generation=g;kind=event;cv.notify_one(); }
  ~Stub() { {std::lock_guard lock(mutex);stop=true;cv.notify_one();} worker.join(); }
};
extern "C" {
wam_caption_session_v1 wam_caption_create_v1(wam_caption_callback_v1 cb, void *ctx) { return new Stub(cb,ctx); }
void wam_caption_query_v1(void *p, uint64_t g, const char *) { static_cast<Stub*>(p)->send(g,WAM_CAPTION_CAPABILITIES); }
void wam_caption_prepare_v1(void *p, uint64_t g, int32_t) { static_cast<Stub*>(p)->send(g,WAM_CAPTION_ERROR); }
void wam_caption_start_v1(void *p, uint64_t g, const char *) { wam_caption_prepare_v1(p,g,0); }
void wam_caption_cancel_v1(void *) {}
void wam_caption_finish_v1(void *p,uint64_t g) { static_cast<Stub*>(p)->send(g,WAM_CAPTION_FINISHED); }
void wam_caption_release_v1(void *p) { delete static_cast<Stub*>(p); }
}
