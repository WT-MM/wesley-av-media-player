#include "platform/macos/software_avcodec_video_decoder.hpp"
#include "platform/macos/video_decode_lane.hpp"
#include "media/video_codec_configuration.hpp"
#include "media/media_codec_facts.hpp"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <filesystem>
#include <cstring>
#include <thread>
#include <vector>
using namespace wam::macos;
#define CHECK(x) do { if(!(x)) { std::fprintf(stderr,"line %d: %s\n",__LINE__,#x); std::abort(); } } while(0)
struct Sink:DecodedFrameSink {
  bool blocked=true,ended=false;
  unsigned count=0;
  std::uint64_t generation=0;
  OSType expected{};
  std::vector<std::byte> reference;
  FrameEnqueueResult enqueue(FrameLease frame,std::string*) override {
    if(blocked)return FrameEnqueueResult::Backpressure;
    CHECK(frame && frame.timing().generation==generation);
    CHECK(frame.pixelFormat()==expected);
    CHECK(CMTimeCompare(frame.timing().presentationTime,CMTimeMake(count*40,1000))==0);
    CHECK(CMTimeCompare(frame.timing().duration,CMTimeMake(40,1000))==0);
    const bool wide=expected==kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange;
    const bool ten=expected!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    const std::size_t bytes=ten?2:1, cw=160, ch=wide?180:90;
    const std::size_t yBytes=320*180*bytes, cBytes=cw*ch*bytes, frameBytes=yBytes+2*cBytes;
    CHECK(reference.size()>=(count+1)*frameBytes);
    const auto* source=reference.data()+count*frameBytes;
    CHECK(CVPixelBufferLockBaseAddress(frame.pixelBuffer(),kCVPixelBufferLock_ReadOnly)==kCVReturnSuccess);
    for(unsigned plane=0;plane<2;++plane) {
      const auto* output=static_cast<const std::byte*>(CVPixelBufferGetBaseAddressOfPlane(frame.pixelBuffer(),plane));
      const auto stride=CVPixelBufferGetBytesPerRowOfPlane(frame.pixelBuffer(),plane);
      const std::size_t rows=plane?ch:180,columns=plane?cw:320;
      for(std::size_t y=0;y<rows;++y)for(std::size_t x=0;x<columns;++x)for(unsigned component=0;component<(plane?2U:1U);++component) {
        const auto* from=source+(plane?yBytes+component*cBytes:0)+(y*columns+x)*bytes;
        const auto* to=output+y*stride+(plane?2*x+component:x)*bytes;
        if(ten) {std::uint16_t a,b;std::memcpy(&a,from,2);std::memcpy(&b,to,2);CHECK(std::uint16_t(a<<6)==b);}
        else CHECK(*from==*to);
      }
    }
    CVPixelBufferUnlockBaseAddress(frame.pixelBuffer(),kCVPixelBufferLock_ReadOnly);
    ++count; return FrameEnqueueResult::Accepted;
  }
  void endOfStream(std::uint64_t value) override { CHECK(value==generation); ended=true; }
  void flush(std::uint64_t value) noexcept override { generation=value; count=0; ended=false; }
};
template<class T>T read(std::ifstream& file) {T v;file.read(reinterpret_cast<char*>(&v),sizeof(v));CHECK(file.good());return v;}
struct Packet {std::vector<std::byte> bytes;std::int64_t pts,dts,duration;};
struct TestDecoder {
  explicit TestDecoder(bool useLane):productionLane(useLane) {}
  bool productionLane;
  SoftwareAvcodecVideoDecoder software;
  VideoDecodeLane lane;
  bool configure(const VideoStreamConfiguration& c,DecodedFrameSink& sink,std::string* e) {
    return productionLane?lane.configure(c,sink,e):software.configure(c,sink,e);
  }
  VideoDecodeSubmitResult submitCMSampleBuffer(CMSampleBufferRef sample,std::uint64_t g,std::string* e) {
    return productionLane?lane.submitCMSampleBuffer(sample,g,e):software.submitCMSampleBuffer(sample,g,e);
  }
  VideoDecodeDrainProgress drainPresentation(std::uint64_t g,std::string* e) {
    return productionLane?lane.drainPresentation(g,e):software.drainPresentation(g,e);
  }
  VideoDecodeDrainProgress beginEndOfStream(std::uint64_t g,std::string* e) {
    return productionLane?lane.beginEndOfStream(g,e):software.beginEndOfStream(g,e);
  }
  VideoDecodeDrainProgress drainEndOfStream(std::uint64_t g,std::string* e) {
    return productionLane?lane.drainEndOfStream(g,e):software.drainEndOfStream(g,e);
  }
  void flush(std::uint64_t g) { if(productionLane)lane.flush(g);else software.flush(g); }
  VideoDecoderRetireProgress retire(std::uint64_t g,std::uint64_t n) {
    return productionLane?lane.retire(g,n):software.retire(g,n);
  }
};

int main(int argc,char** argv) {
  CHECK(argc==3);
  std::ifstream file(argv[1],std::ios::binary);
  auto extraSize=read<std::uint32_t>(file),packetCount=read<std::uint32_t>(file);
  std::vector<std::byte> extra(extraSize);file.read(reinterpret_cast<char*>(extra.data()),extraSize);
  bool asp=std::string(argv[2])=="asp";
  bool is422=std::string(argv[2])=="h264422";
  wam::media::VideoCodecConfigurationLimits limits;limits.admitSoftwareProfiles=true;
  if(asp) {
    std::vector<std::byte> esds(extra.size()+wam::media::kMpeg4VisualEsdsOverheadBytes);std::size_t size=0;
    CHECK(wam::media::buildMpeg4VisualEsds(extra,esds,&size,limits));CHECK(size==esds.size());extra=std::move(esds);
  }
  std::vector<Packet> packets;
  for(unsigned i=0;i<packetCount;++i) {
    auto size=read<std::uint32_t>(file); Packet p;
    p.pts=read<std::int64_t>(file);p.dts=read<std::int64_t>(file);p.duration=read<std::int64_t>(file);
    p.bytes.resize(size);file.read(reinterpret_cast<char*>(p.bytes.data()),size);CHECK(file.good());packets.push_back(std::move(p));
  }
  Sink sink;sink.expected=asp?kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    is422?kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
  auto referencePath=std::filesystem::path(argv[1]);referencePath.replace_extension(".yuv");
  std::ifstream raw(referencePath,std::ios::binary|std::ios::ate);CHECK(raw.good());const auto rawSize=raw.tellg();CHECK(rawSize>0);
  sink.reference.resize(static_cast<std::size_t>(rawSize));raw.seekg(0);raw.read(reinterpret_cast<char*>(sink.reference.data()),rawSize);CHECK(raw.good());
  TestDecoder decoder{asp};
  VideoStreamConfiguration config;config.codec=asp?'mp4v':'avc1';config.codedSize={320,180};config.codecConfiguration=extra;config.generation=1;
  std::string error;
  CHECK(decoder.configure(config,sink,&error));
  for(unsigned pass=0;pass<2;++pass) {
    if(pass)decoder.flush(2);
    const auto generation=pass+1;
    std::size_t index=0;bool pressured=false;
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
    while(index<packets.size()) {
      CHECK(std::chrono::steady_clock::now()<deadline);
      auto& packet=packets[index];
      CMBlockBufferRef block{};CMSampleBufferRef sample{};
      CHECK(CMBlockBufferCreateWithMemoryBlock(nullptr,packet.bytes.data(),packet.bytes.size(),kCFAllocatorNull,nullptr,0,packet.bytes.size(),0,&block)==0);
      CMSampleTimingInfo timing{CMTimeMake(packet.duration,1000),CMTimeMake(packet.pts,1000),packet.dts==INT64_MIN?kCMTimeInvalid:CMTimeMake(packet.dts,1000)};
      const std::size_t size=packet.bytes.size();
      CHECK(CMSampleBufferCreateReady(nullptr,block,nullptr,1,1,&timing,1,&size,&sample)==0);
      const auto result=decoder.submitCMSampleBuffer(sample,generation,&error);
      CFRelease(sample);CFRelease(block);
      if(result==VideoDecodeSubmitResult::Accepted)++index;
      else if(result==VideoDecodeSubmitResult::Backpressure) {pressured=true;sink.blocked=false;}
      else {std::fprintf(stderr,"%s\n",error.c_str());CHECK(false);}
      const auto drained=decoder.drainPresentation(generation,&error);
      if(drained==VideoDecodeDrainProgress::Failed) {std::fprintf(stderr,"%s\n",error.c_str());CHECK(false);}
      std::this_thread::yield();
    }
    sink.blocked=false;
    CHECK(decoder.beginEndOfStream(generation,&error)!=VideoDecodeDrainProgress::Failed);
    while(!sink.ended) {
      CHECK(std::chrono::steady_clock::now()<deadline);
      if(decoder.drainEndOfStream(generation,&error)==VideoDecodeDrainProgress::Failed) {std::fprintf(stderr,"%s\n",error.c_str());CHECK(false);}
      std::this_thread::yield();
    }
    CHECK(sink.count==packets.size() && pressured);
    sink.blocked=true;
  }
  CHECK(decoder.retire(2,3)==VideoDecoderRetireProgress::Done);
  std::puts("video adapter packet/EOS/flush/backpressure and surface format passed");
}
