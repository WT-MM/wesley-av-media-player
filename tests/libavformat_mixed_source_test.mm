#include "platform/macos/routed_media_source.hpp"
#include "platform/macos/libavformat_media_source.hpp"
#include <cstdio>
#include <set>
#include <string>
#include "support/expect.hpp"
int main(int argc,char** argv) {
  using namespace wam::media;
  REQUIRE(argc==2 || argc==4);
  const unsigned wantVideo=argc==4?std::stoul(argv[2]):48,wantAudio=argc==4?std::stoul(argv[3]):90;
  auto source=wam::macos::createRoutedMediaSource();
  MediaSourceOpenOptions options;
  REQUIRE(source->armOperation(1));
  auto opened=source->openLocalFile(argv[1],options,1);
  if(!opened.error.empty())std::fprintf(stderr,"%s\n",opened.error.c_str());
  REQUIRE(opened.status==MediaSourceOpenStatus::Ready);
  REQUIRE(opened.preparedContext->backendKind()==MediaSourceBackendKind::Libavformat);
  EXPECT(!source->supportsAudioTrackRetry());
  REQUIRE(opened.descriptor->selectedAudio && opened.descriptor->selectedVideo);
  std::set<MediaTrackId> ended;unsigned video{},audio{};
  for(;;) {
    auto read=source->readNext(1);
    if(auto* sample=std::get_if<MediaSample>(&read)) {
      EXPECT(!ended.contains(sample->track));
      EXPECT(validateMediaSample(*sample,*opened.descriptor,options.limits));
      if(sample->kind==MediaSampleKind::EncodedAudio)++audio;else ++video;
    } else if(auto* eos=std::get_if<MediaEndOfStream>(&read))EXPECT(ended.insert(eos->track).second);
    else if(std::holds_alternative<MediaSourceExhausted>(read))break;
    else REQUIRE(false);
  }
  EXPECT(video==wantVideo && audio==wantAudio && ended.size()==2);
  for(unsigned epoch=2;epoch<6;++epoch) {
    const MediaTime target=epoch%2?MediaTime{1,7}:MediaTime{1,1};
    EXPECT(source->armOperation(epoch));
    auto seek=source->seek({epoch,target,MediaSeekMode::Accurate});
    EXPECT(seek.accepted);
    EXPECT(compareMediaTime(seek.actualDecodeStart,target)!=MediaTimeOrder::Greater);
    EXPECT(std::holds_alternative<MediaSample>(source->readNext(epoch)));
  }
  // A cancelled generation withdraws the source, as on every native route.
  source->requestCancel(5);
  EXPECT(std::holds_alternative<MediaSourceCancelled>(source->readNext(5)));
  source->close();EXPECT(source->stats().stagedPayloadBytes==0);
  std::printf("routed mixed: video=%u audio=%u EOS=2; exact seeks, cancellation, zero staged payload\n",video,audio);
  return failures == 0 ? 0 : 1;
}
