#include "platform/macos/routed_media_source.hpp"
#include "platform/macos/libavformat_media_source.hpp"
#include <cstdio>
#include <set>
#define CHECK(x) do { if(!(x)) { std::fprintf(stderr,"line %d: %s\n",__LINE__,#x);return 1;} } while(0)
int main(int argc,char** argv) {
  using namespace wam::media;
  CHECK(argc==2);
  auto source=wam::macos::createRoutedMediaSource();
  MediaSourceOpenOptions options;
  CHECK(source->armOperation(1));
  auto opened=source->openLocalFile(argv[1],options,1);
  if(!opened.error.empty())std::fprintf(stderr,"%s\n",opened.error.c_str());
  CHECK(opened.status==MediaSourceOpenStatus::Ready);
  CHECK(opened.preparedContext->backendKind()==MediaSourceBackendKind::Libavformat);
  CHECK(opened.descriptor->selectedAudio && opened.descriptor->selectedVideo);
  std::set<MediaTrackId> ended;unsigned video{},audio{};
  for(;;) {
    auto read=source->readNext(1);
    if(auto* sample=std::get_if<MediaSample>(&read)) {
      CHECK(!ended.contains(sample->track));
      CHECK(validateMediaSample(*sample,*opened.descriptor,options.limits));
      if(sample->kind==MediaSampleKind::EncodedAudio)++audio;else ++video;
    } else if(auto* eos=std::get_if<MediaEndOfStream>(&read))CHECK(ended.insert(eos->track).second);
    else if(std::holds_alternative<MediaSourceExhausted>(read))break;
    else CHECK(false);
  }
  CHECK(video==48 && audio==90 && ended.size()==2);
  for(unsigned epoch=2;epoch<6;++epoch) {
    const MediaTime target=epoch%2?MediaTime{1,7}:MediaTime{1,1};
    CHECK(source->armOperation(epoch));
    auto seek=source->seek({epoch,target,MediaSeekMode::Accurate});
    CHECK(seek.accepted);
    CHECK(compareMediaTime(seek.actualDecodeStart,target)!=MediaTimeOrder::Greater);
    CHECK(std::holds_alternative<MediaSample>(source->readNext(epoch)));
    source->requestCancel(epoch);
    CHECK(std::holds_alternative<MediaSourceCancelled>(source->readNext(epoch)));
  }
  source->close();CHECK(source->stats().stagedPayloadBytes==0);
  std::puts("routed mixed: video=48 audio=90 EOS=2; exact seeks, cancellation, zero staged payload");
}
