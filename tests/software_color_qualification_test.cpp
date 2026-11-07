#include "media/software_color_qualification.hpp"
#include "support/expect.hpp"
#include <cstdio>
int main() {
  using namespace wam::media;
  VideoCodecConfigurationFacts f;
  f.codec=MediaCodec::Mpeg4Visual;f.bitDepth=8;f.sampleFormat=MediaVideoSampleFormat::Yuv420EightBit;
  EXPECT(softwareColorQualified(f,false));
  f.color.fullRange=true;EXPECT(!softwareColorQualified(f,false));
  f.profile=0xf5;EXPECT(softwareColorQualified(f,false));
  f.color.fullRange=false;f.codec=MediaCodec::H264;EXPECT(!softwareColorQualified(f,false));
  f.bitDepth=10;f.sampleFormat=MediaVideoSampleFormat::Yuv420TenBit;EXPECT(softwareColorQualified(f,false));
  f.color.fullRange=true;EXPECT(softwareColorQualified(f,false));
  f.sampleFormat=MediaVideoSampleFormat::Yuv422TenBit;EXPECT(softwareColorQualified(f,false));
  EXPECT(!softwareColorQualified(f,true));
  f.color.transferCharacteristics=16;EXPECT(!softwareColorQualified(f,false));
  f.color.transferCharacteristics=18;EXPECT(!softwareColorQualified(f,false));
  f.color.transferCharacteristics=1;f.codec=MediaCodec::Vp9;EXPECT(!softwareColorQualified(f,false));
  f.sampleFormat=MediaVideoSampleFormat::Yuv420TenBit;EXPECT(softwareColorQualified(f,false));
  f.color.fullRange=false;EXPECT(softwareColorQualified(f,false));
  f.bitDepth=8;f.sampleFormat=MediaVideoSampleFormat::Yuv420EightBit;EXPECT(softwareColorQualified(f,false));
  f.color.fullRange=true;EXPECT(softwareColorQualified(f,false));
  f.color.fullRange=false;f.color.transferCharacteristics=16;EXPECT(!softwareColorQualified(f,false));
  std::puts("qualified SDR full-range ASP/VP9 admitted; HDR remains refused");
  return failures == 0 ? 0 : 1;
}
