#include "caption_backend.hpp"
#include "apple_caption_backend.hpp"
#include "support/expect.hpp"
using namespace wam;
int main(int argc, char**) {
  if (argc>1) { AppleCaptionBackend backend; EXPECT(!backend.capabilities("en-US").available); }
  for (int available=0;available<2;++available)
    for (int ready=0;ready<2;++ready)
      for (int translate=0;translate<2;++translate)
        EXPECT(selectCaptionEngine({bool(available),bool(ready),!ready,-1},translate) ==
              (available && ready && !translate ? CaptionEngine::Apple : CaptionEngine::Whisper));
  EXPECT(selectCaptionEngine({}) == CaptionEngine::Whisper); // SDK/OS absent
  std::vector<CaptionSegment> store;
  reviseCaptionSegments(store,{0,2,"hel",false});
  reviseCaptionSegments(store,{0,3,"hello world",false});
  EXPECT(store.size()==1 && store[0].text=="hello world");
  reviseCaptionSegments(store,{0,3,"Hello world.",true});
  reviseCaptionSegments(store,{3,4,"next",false});
  EXPECT(store.size()==2 && store[0].final);
  reviseCaptionSegments(store,{3,5,"Next sentence.",true});
  EXPECT(store.size()==2 && store[1].final);
  reviseCaptionSegments(store,{-1,3,"invalid",true});
  EXPECT(store.size()==2);
  reviseCaptionSegments(store,{0,3,"stale volatile",false});
  reviseCaptionSegments(store,{0,3,"duplicate final",true});
  EXPECT(store.size()==2 && store[0].text=="Hello world.");
  std::cout << "caption policy and revision checks passed\n";
  return failures == 0 ? 0 : 1;
}
