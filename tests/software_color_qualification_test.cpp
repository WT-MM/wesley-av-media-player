#include "media/software_color_qualification.hpp"
#include <cstdio>
#define CHECK(x) do {if(!(x)){std::fprintf(stderr,"line %d: %s\n",__LINE__,#x);return 1;}}while(0)
int main() {
  using namespace wam::media;
  VideoCodecConfigurationFacts f;
  f.codec=MediaCodec::Mpeg4Visual;f.bitDepth=8;f.sampleFormat=MediaVideoSampleFormat::Yuv420EightBit;
  CHECK(softwareColorQualified(f,false));
  f.codec=MediaCodec::H264;CHECK(!softwareColorQualified(f,false));
  f.bitDepth=10;f.sampleFormat=MediaVideoSampleFormat::Yuv420TenBit;CHECK(softwareColorQualified(f,false));
  f.sampleFormat=MediaVideoSampleFormat::Yuv422TenBit;CHECK(softwareColorQualified(f,false));
  f.color.fullRange=true;CHECK(!softwareColorQualified(f,false));
  f.color.fullRange=false;CHECK(!softwareColorQualified(f,true));
  f.color.transferCharacteristics=16;CHECK(!softwareColorQualified(f,false));
  f.color.transferCharacteristics=18;CHECK(!softwareColorQualified(f,false));
  f.color.transferCharacteristics=1;f.codec=MediaCodec::Vp9;CHECK(!softwareColorQualified(f,false));
  f.bitDepth=8;f.sampleFormat=MediaVideoSampleFormat::Yuv420EightBit;CHECK(!softwareColorQualified(f,false));
  std::puts("retained ASP/Hi10P/422 SDR limited range admitted; other software colors refused");
}
