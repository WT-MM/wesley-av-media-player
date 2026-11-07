#include "caption_service.hpp"
#include "wamkit/include/WAMKit/WAMCaption.h"
#include <atomic>
#include <chrono>
#include <fstream>
#include "support/expect.hpp"
#include <stdexcept>
#include <thread>
using namespace std::chrono_literals;
namespace fs=std::filesystem;
namespace {
std::atomic<int> capability{3}, installs{0}, mode{0};
std::atomic<bool> query_fails{false};
struct Session { wam_caption_callback_v1 cb; void* ctx; std::thread worker; std::atomic<bool> cancelled{false}; };
void emit(Session* s,uint64_t g,int kind,const char* text="",int flags=0) { s->cb(s->ctx,g,kind,0,1,0.5,flags,text); }
void join(Session* s) { if(s->worker.joinable()) s->worker.join(); }
void write(const fs::path& p,const char* s) {std::ofstream(p)<<s;}
}
extern "C" {
void* wam_caption_create_v1(wam_caption_callback_v1 cb,void* c) {return new Session{cb,c};}
void wam_caption_query_v1(void* p,uint64_t g,const char*) {
 auto s=static_cast<Session*>(p); join(s); s->cancelled=false;
 if(query_fails) emit(s,g,WAM_CAPTION_ERROR,"query failed");
 else emit(s,g,WAM_CAPTION_CAPABILITIES,"en_US",capability);
}
void wam_caption_prepare_v1(void* p,uint64_t g,int32_t consent) {
 auto s=static_cast<Session*>(p); join(s); s->cancelled=false;
 s->worker=std::thread([=] {
   if(consent) ++installs;
   emit(s,g,WAM_CAPTION_PROGRESS,"Downloading language");
   if(mode==2) while(!s->cancelled) std::this_thread::sleep_for(2ms);
   if(s->cancelled) emit(s,g,WAM_CAPTION_CANCELLED);
   else if(mode==1) emit(s,g,WAM_CAPTION_ERROR,"installation failed");
   else emit(s,g,WAM_CAPTION_PREPARED);
 });
}
void wam_caption_start_v1(void* p,uint64_t g,const char*) {
 auto s=static_cast<Session*>(p); join(s);
 s->worker=std::thread([=] {
   emit(s,g-1,WAM_CAPTION_SEGMENT,"stale request",1);
   emit(s,g,WAM_CAPTION_SEGMENT,"vola");
   emit(s,g,WAM_CAPTION_SEGMENT,"Final Apple text",1);
   if(mode==4) for(int i=1;i<=600;++i)
     s->cb(s->ctx,g,WAM_CAPTION_SEGMENT,i,i+1,0,1,"bounded final");
   if(mode==3) while(!s->cancelled) std::this_thread::sleep_for(2ms);
   emit(s,g,s->cancelled ? WAM_CAPTION_CANCELLED : WAM_CAPTION_COMPLETED);
 });
}
void wam_caption_cancel_v1(void* p) {static_cast<Session*>(p)->cancelled=true;}
void wam_caption_finish_v1(void* p,uint64_t g) {auto s=static_cast<Session*>(p);s->cancelled=true;join(s);emit(s,g,WAM_CAPTION_FINISHED);}
void wam_caption_release_v1(void* p) {auto s=static_cast<Session*>(p);join(s);delete s;}
}
int main(int argc,char**argv) {
 if(fs::path(argv[0]).filename()=="fake-ffmpeg") {write(argv[argc-1],"PCM"); return 0;}
 if(fs::path(argv[0]).filename()=="fake-whisper") {
   for(int i=1;i+1<argc;++i) if(std::string(argv[i])=="-of") {write(std::string(argv[i+1])+".srt","1\n00:00:00,000 --> 00:00:01,000\nWhisper\n"); return 0;}
   return 1;
 }
 const auto root=fs::temp_directory_path()/("wam-caption-flow-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
 try {
 fs::create_directories(root);
 for(auto name:{"fake-ffmpeg","fake-whisper"}) fs::copy_file(fs::absolute(argv[0]),root/name);
 write(root/"input.wav","media");write(root/"model.bin","model");
 wam::CaptionRequest request;request.input=root/"input.wav";request.output_srt=root/"output.srt";
 request.tools={root/"fake-ffmpeg",root/"fake-whisper",root/"model.bin"};
 auto run=[&](wam::CaptionService& service,int response,bool cancel=false) {
   expect(service.start(request),"start refused");
   expect(!service.start(request),"concurrent request admitted");
   const auto deadline=std::chrono::steady_clock::now()+3s;
   while(service.running() && std::chrono::steady_clock::now()<deadline) {
     const auto status=service.status();
     if(status.needsDownloadConsent()) service.respondToDownload(response>0);
     if(cancel && status.message.starts_with("Downloading language")) service.cancel();
     std::this_thread::sleep_for(2ms);
   }
   if(service.running()) service.cancel();
   service.wait(); return service.status();
 };
 {
   wam::CaptionService service;
   auto s=run(service,0);expect(s.succeeded() && s.engine==wam::CaptionEngine::Apple,"ready Apple selection failed");
   expect(installs==0,"ready asset downloaded");expect(s.segments.size()==1 && s.segments[0].text=="Final Apple text","revision or generation isolation failed");
 }
 {
   // The service keeps its Apple session warm between runs; a query that
   // fails must not be answered with the previous run's capabilities.
   wam::CaptionService service;
   expect(run(service,0).engine==wam::CaptionEngine::Apple,"ready Apple selection failed");
   query_fails=true;
   expect(run(service,0).engine==wam::CaptionEngine::Whisper,"failed query reused stale Apple capabilities");
   query_fails=false;
 }
 mode=4;
 {wam::CaptionService service; auto s=run(service,0);
  expect(s.succeeded() && s.segments.size()==512 && s.segments.front().start==89 &&
        s.segments.back().start==600,"live snapshot must retain only latest 512 segments");}
 mode=0;
 capability=0;
 {wam::CaptionService service;expect(run(service,0).engine==wam::CaptionEngine::Whisper,"unavailable must degrade");}
 capability=5;
 {
   wam::CaptionService service;expect(run(service,-1).succeeded(),"decline fallback failed");
   expect(installs==0,"declined download started");
   expect(run(service,1).engine==wam::CaptionEngine::Whisper,"decline must be asked once per service");
 }
 {wam::CaptionService service;expect(run(service,1).engine==wam::CaptionEngine::Apple,"consented prepare failed");expect(installs==1,"install not explicitly consented");}
 mode=1;
 {wam::CaptionService service;auto s=run(service,1);expect(s.succeeded() && s.engine==wam::CaptionEngine::Whisper,"install failure fallback failed");}
 mode=2;
 {wam::CaptionService service;write(request.output_srt,"keep old output");auto s=run(service,1,true);expect(s.cancelled(),"download cancellation failed");std::string old;std::ifstream(request.output_srt)>>old;expect(old=="keep","cancel overwrote output");}
 fs::remove_all(root);std::cout<<"caption consent, fallback, generation and cancellation checks passed\n";return failures==0?0:1;
 } catch(const std::exception& e) {std::cerr<<e.what()<<'\n';fs::remove_all(root);return 1;}
}
