#include "caption_service.hpp"
#include <chrono>
#include <iostream>
#include <fstream>
#include <thread>
// Opt-in integration proof; never authorizes a download. Run twice to check
// warm analyzer reuse and file-relative timestamps. Arguments: WAV output-dir.
int main(int argc,char** argv) {
  if (argc != 3) return 64;
  wam::CaptionService service;
  std::string first;
  for (int trial=0;trial<2;++trial) {
    wam::CaptionRequest request;
    request.input=argv[1]; request.output_srt=std::filesystem::path(argv[2])/ ("apple-"+std::to_string(trial)+".srt");
    request.tools=wam::findCaptionTools(nullptr);
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
      << " error=" << status.error << std::endl;
    if(!status.succeeded || status.engine!=wam::CaptionEngine::Apple) return 1;
    std::ifstream file(status.output_srt);
    const std::string text{std::istreambuf_iterator<char>(file),{}};
    if(trial==0) first=text;
    else if(text!=first) { std::cerr << "Repeated-file transcript drifted across requests\n"; return 1; }
  }
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
