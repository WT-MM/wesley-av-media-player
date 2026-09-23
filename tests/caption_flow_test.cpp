#include "caption_service.hpp"
#include "wamkit/include/WAMKit/WAMCaption.h"
#include <atomic>
#include <chrono>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <thread>
using namespace std::chrono_literals;
namespace fs=std::filesystem;
namespace {
std::atomic<int> capability{3}, installs{0}, mode{0};
struct Session { wam_caption_callback_v1 cb; void* ctx; std::thread worker; std::atomic<bool> cancelled{false}; };
void emit(Session* s,uint64_t g,int kind,const char* text="",int flags=0) { s->cb(s->ctx,g,kind,0,1,0.5,flags,text); }
void join(Session* s) { if(s->worker.joinable()) s->worker.join(); }
void check(bool value,const char* reason) { if(!value) throw std::runtime_error(reason); }
void write(const fs::path& p,const char* s) {std::ofstream(p)<<s;}
}
extern "C" {
void* wam_caption_create_v1(wam_caption_callback_v1 cb,void* c) {return new Session{cb,c};}
void wam_caption_query_v1(void* p,uint64_t g,const char*) {
 auto s=static_cast<Session*>(p); join(s); s->cancelled=false;
 emit(s,g,WAM_CAPTION_CAPABILITIES,"en_US",capability);
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
   check(service.start(request),"start refused");
   check(!service.start(request),"concurrent request admitted");
   const auto deadline=std::chrono::steady_clock::now()+3s;
   while(service.running() && std::chrono::steady_clock::now()<deadline) {
     const auto status=service.status();
     if(status.needs_download_consent) service.respondToDownload(response>0);
     if(cancel && status.message.starts_with("Downloading language")) service.cancel();
     std::this_thread::sleep_for(2ms);
   }
   if(service.running()) service.cancel();
   service.wait(); return service.status();
 };
 {
   wam::CaptionService service;
   auto s=run(service,0);check(s.succeeded && s.engine==wam::CaptionEngine::Apple,"ready Apple selection failed");
   check(installs==0,"ready asset downloaded");check(s.segments.size()==1 && s.segments[0].text=="Final Apple text","revision or generation isolation failed");
 }
 capability=0;
 {wam::CaptionService service;check(run(service,0).engine==wam::CaptionEngine::Whisper,"unavailable must degrade");}
 capability=5;
 {
   wam::CaptionService service;check(run(service,-1).succeeded,"decline fallback failed");
   check(installs==0,"declined download started");
   check(run(service,1).engine==wam::CaptionEngine::Whisper,"decline must be asked once per service");
 }
 {wam::CaptionService service;check(run(service,1).engine==wam::CaptionEngine::Apple,"consented prepare failed");check(installs==1,"install not explicitly consented");}
 mode=1;
 {wam::CaptionService service;auto s=run(service,1);check(s.succeeded && s.engine==wam::CaptionEngine::Whisper,"install failure fallback failed");}
 mode=2;
 {wam::CaptionService service;write(request.output_srt,"keep old output");auto s=run(service,1,true);check(s.cancelled,"download cancellation failed");std::string old;std::ifstream(request.output_srt)>>old;check(old=="keep","cancel overwrote output");}
 fs::remove_all(root);std::cout<<"caption consent, fallback, generation and cancellation checks passed\n";return 0;
 } catch(const std::exception& e) {std::cerr<<e.what()<<'\n';fs::remove_all(root);return 1;}
}
