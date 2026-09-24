#include "caption_service.hpp"
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <fstream>
#include <thread>
#ifdef __APPLE__
#include <mach/mach.h>
#endif
// Opt-in integration proof; never authorizes a download. Run twice to check
// warm analyzer reuse and file-relative timestamps. Arguments: WAV output-dir.
std::uint64_t rss() {
#ifdef __APPLE__
  mach_task_basic_info_data_t info{};
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
      reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) return 0;
  return info.resident_size;
#else
  return 0; // This opt-in SpeechAnalyzer RSS proof requires macOS.
#endif
}
int main(int argc,char** argv) {
  if (argc != 3 && argc != 5) return 64;
  const bool whisper = std::getenv("WAM_CAPTION_PROOF_WHISPER") != nullptr;
  wam::CaptionService service;
  std::string first;
  std::cout << "rss_before_bytes=" << rss() << std::endl;
  for (int trial=0;trial<3;++trial) {
    wam::CaptionRequest request;
    request.input=argv[argc==5 && trial>0 ? trial+2 : 1]; request.output_srt=std::filesystem::path(argv[2])/ ("apple-"+std::to_string(trial)+".srt");
    request.tools=wam::findCaptionTools(nullptr);
    request.options.prefer_apple = !whisper;
    const auto start=std::chrono::steady_clock::now();
    if (!service.start(request)) return 1;
    std::string last;
    while (service.running()) {
      auto status=service.status();
      if(status.needs_download_consent) service.respondToDownload(false);
      if(status.message!=last) { std::cout << status.message << std::endl; last=status.message; }
      if(std::chrono::steady_clock::now()-start>std::chrono::seconds(90)) service.cancel();
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    service.wait(); const auto status=service.status();
    std::cout << "trial=" << trial << " apple=" << (status.engine==wam::CaptionEngine::Apple)
      << " success=" << status.succeeded << " segments=" << status.segments.size()
      << " seconds=" << std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count()
      << " rss_bytes=" << rss() << " preparations=" << status.engine_preparations
      << " error=" << status.error << std::endl;
    if(!status.succeeded || status.engine!=(whisper ? wam::CaptionEngine::Whisper : wam::CaptionEngine::Apple)) return 1;
    std::ifstream file(status.output_srt);
    const std::string text{std::istreambuf_iterator<char>(file),{}};
    if(trial==0) first=text;
    else if(argc==3 && text!=first) { std::cerr << "Repeated-file transcript drifted across requests\n"; return 1; }
  }
  std::cout << "rss_after_three_bytes=" << rss() << std::endl;
  if (whisper) return 0;
  // Real production deadline, no shorter test-only eviction policy.
  std::this_thread::sleep_for(std::chrono::seconds(32));
  std::cout << "rss_after_idle_bytes=" << rss() << std::endl;
  wam::CaptionRequest afterIdle;
  afterIdle.input=argv[1]; afterIdle.output_srt=std::filesystem::path(argv[2])/"after-idle.srt";
  afterIdle.tools=wam::findCaptionTools(nullptr);
  if (!service.start(afterIdle)) return 1;
  service.wait();
  const auto idleStatus=service.status();
  std::cout << "idle_reprepare=" << idleStatus.engine_preparations << std::endl;
  if (!idleStatus.succeeded || idleStatus.engine_preparations!=1) return 1;
  // Cancel during a live result stream, then reuse the service. The existing
  // destination must survive; cancellation itself must not join Swift work.
  wam::CaptionRequest cancelRequest;
  cancelRequest.input=argv[1];
  cancelRequest.output_srt=std::filesystem::path(argv[2])/"cancel.srt";
  cancelRequest.tools=wam::findCaptionTools(nullptr);
  std::ofstream(cancelRequest.output_srt)<<"preserve old captions";
  if(!service.start(cancelRequest)) return 1;
  const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
  while(service.running() && service.status().segments.empty() && std::chrono::steady_clock::now()<deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  if(!service.running()) {std::cerr<<"Cancellation did not reach active analysis\n";return 1;}
  const auto cancelStart=std::chrono::steady_clock::now();
  service.cancel();
  const auto returned=std::chrono::steady_clock::now();
  service.wait();
  const auto joined=std::chrono::steady_clock::now();
  std::ifstream kept(cancelRequest.output_srt);
  const std::string old{std::istreambuf_iterator<char>(kept),{}};
  const double callMs=std::chrono::duration<double,std::milli>(returned-cancelStart).count();
  const double finishMs=std::chrono::duration<double,std::milli>(joined-cancelStart).count();
  std::cout<<"cancel_call_ms="<<callMs<<" cancel_finish_ms="<<finishMs<<std::endl;
  if(!service.status().cancelled || old!="preserve old captions" || callMs>50 || finishMs>5000) return 1;
  if(!service.start(cancelRequest)) return 1;
  service.wait();
  if(!service.succeeded()) return 1;
  std::cout<<"reuse_after_cancel=passed"<<std::endl;

}
