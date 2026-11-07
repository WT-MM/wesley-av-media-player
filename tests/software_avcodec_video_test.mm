#include "platform/macos/software_avcodec_video_decoder.hpp"
#include "platform/macos/video_decode_lane.hpp"
#include "media/video_codec_configuration.hpp"
#include "media/media_codec_facts.hpp"
#include "media/avcodec/decode_worker.hpp"
#include "support/expect.hpp"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <filesystem>
#include <cstring>
#include <thread>
#include <vector>
using namespace wam::macos;
struct Sink:DecodedFrameSink {
  bool blocked=true,ended=false;
  unsigned count=0;
  std::uint64_t generation=0;
  OSType expected{};
  std::vector<std::byte> reference;
  FrameEnqueueResult enqueue(FrameLease frame,std::string*) override {
    if(blocked)return FrameEnqueueResult::Backpressure;
    REQUIRE(frame && frame.timing().generation==generation);
    REQUIRE(frame.pixelFormat()==expected);
    REQUIRE(CMTimeCompare(frame.timing().presentationTime,CMTimeMake(count*40,1000))==0);
    REQUIRE(CMTimeCompare(frame.timing().duration,CMTimeMake(40,1000))==0);
    const bool wide=expected==kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange;
    const bool ten=expected!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    const std::size_t bytes=ten?2:1, cw=160, ch=wide?180:90;
    const std::size_t yBytes=320*180*bytes, cBytes=cw*ch*bytes, frameBytes=yBytes+2*cBytes;
    REQUIRE(reference.size()>=(count+1)*frameBytes);
    const auto* source=reference.data()+count*frameBytes;
    REQUIRE(CVPixelBufferLockBaseAddress(frame.pixelBuffer(),kCVPixelBufferLock_ReadOnly)==kCVReturnSuccess);
    for(unsigned plane=0;plane<2;++plane) {
      const auto* output=static_cast<const std::byte*>(CVPixelBufferGetBaseAddressOfPlane(frame.pixelBuffer(),plane));
      const auto stride=CVPixelBufferGetBytesPerRowOfPlane(frame.pixelBuffer(),plane);
      const std::size_t rows=plane?ch:180,columns=plane?cw:320;
      for(std::size_t y=0;y<rows;++y)for(std::size_t x=0;x<columns;++x)for(unsigned component=0;component<(plane?2U:1U);++component) {
        const auto* from=source+(plane?yBytes+component*cBytes:0)+(y*columns+x)*bytes;
        const auto* to=output+y*stride+(plane?2*x+component:x)*bytes;
        if(ten) {std::uint16_t a,b;std::memcpy(&a,from,2);std::memcpy(&b,to,2);REQUIRE(std::uint16_t(a<<6)==b);}
        else REQUIRE(*from==*to);
      }
    }
    CVPixelBufferUnlockBaseAddress(frame.pixelBuffer(),kCVPixelBufferLock_ReadOnly);
    ++count; return FrameEnqueueResult::Accepted;
  }
  void endOfStream(std::uint64_t value) override { REQUIRE(value==generation); ended=true; }
  void flush(std::uint64_t value) noexcept override { generation=value; count=0; ended=false; }
};
template<class T>T read(std::ifstream& file) {T v;file.read(reinterpret_cast<char*>(&v),sizeof(v));REQUIRE(file.good());return v;}
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
  REQUIRE(argc==3);
  std::ifstream file(argv[1],std::ios::binary);
  auto extraSize=read<std::uint32_t>(file),packetCount=read<std::uint32_t>(file);
  std::vector<std::byte> extra(extraSize);file.read(reinterpret_cast<char*>(extra.data()),extraSize);
  bool asp=std::string(argv[2])=="asp";
  bool vp9=std::string(argv[2]).starts_with("vp9");
  bool eight=asp || std::string(argv[2])=="vp9";
  bool is422=std::string(argv[2])=="h264422";
  wam::media::VideoCodecConfigurationLimits limits;limits.admitSoftwareProfiles=true;
  if(asp) {
    std::vector<std::byte> esds(extra.size()+wam::media::kMpeg4VisualEsdsOverheadBytes);std::size_t size=0;
    REQUIRE(wam::media::buildMpeg4VisualEsds(extra,esds,&size,limits));EXPECT(size==esds.size());extra=std::move(esds);
  }
  std::vector<Packet> packets;
  for(unsigned i=0;i<packetCount;++i) {
    auto size=read<std::uint32_t>(file); Packet p;
    p.pts=read<std::int64_t>(file);p.dts=read<std::int64_t>(file);p.duration=read<std::int64_t>(file);
    p.bytes.resize(size);file.read(reinterpret_cast<char*>(p.bytes.data()),size);REQUIRE(file.good());packets.push_back(std::move(p));
  }
  if (vp9) {
    auto parsed=wam::media::inspectVp9BitstreamKeyframe(packets.front().bytes,limits);
    REQUIRE(parsed.admitted());
    std::array<std::byte,wam::media::kVideoCodecVpcCBytes> record{};
    REQUIRE(wam::media::buildVp9CodecConfiguration(*parsed.facts,record));
    extra.assign(record.begin(),record.end());
    EXPECT(nativeVp9StageAdmitted());
  }
  Sink sink;sink.expected=eight?kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    is422?kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
  auto referencePath=std::filesystem::path(argv[1]);referencePath.replace_extension(".yuv");
  std::ifstream raw(referencePath,std::ios::binary|std::ios::ate);REQUIRE(raw.good());const auto rawSize=raw.tellg();REQUIRE(rawSize>0);
  sink.reference.resize(static_cast<std::size_t>(rawSize));raw.seekg(0);raw.read(reinterpret_cast<char*>(sink.reference.data()),rawSize);REQUIRE(raw.good());
  TestDecoder decoder{true};
  setNativeVideoHardwareDisabledForTesting(true);
  VideoStreamConfiguration config;config.codec=asp?'mp4v':vp9?'vp09':'avc1';config.codedSize={320,180};config.codecConfiguration=extra;config.generation=1;
  const auto plan=nativeVideoDecodePlan(config,true,false);
  EXPECT(plan.implementation==wam::media::DecodeImplementation::Libavcodec);
  const auto hardware=nativeVideoDecodePlan(config,true,true);
  if (!asp) EXPECT(hardware.implementation==wam::media::DecodeImplementation::VideoToolboxHardware);
  std::string error;
  if (!decoder.configure(config,sink,&error)) { std::fprintf(stderr,"configure: %s\n",error.c_str()); REQUIRE(false); }
  for(unsigned pass=0;pass<2;++pass) {
    if(pass)decoder.flush(2);
    const auto generation=pass+1;
    std::size_t index=0;bool pressured=false;
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
    while(index<packets.size()) {
      REQUIRE(std::chrono::steady_clock::now()<deadline);
      auto& packet=packets[index];
      CMBlockBufferRef block{};CMSampleBufferRef sample{};
      REQUIRE(CMBlockBufferCreateWithMemoryBlock(nullptr,packet.bytes.data(),packet.bytes.size(),kCFAllocatorNull,nullptr,0,packet.bytes.size(),0,&block)==0);
      CMSampleTimingInfo timing{CMTimeMake(packet.duration,1000),CMTimeMake(packet.pts,1000),packet.dts==INT64_MIN?kCMTimeInvalid:CMTimeMake(packet.dts,1000)};
      const std::size_t size=packet.bytes.size();
      REQUIRE(CMSampleBufferCreateReady(nullptr,block,nullptr,1,1,&timing,1,&size,&sample)==0);
      const auto result=decoder.submitCMSampleBuffer(sample,generation,&error);
      CFRelease(sample);CFRelease(block);
      if(result==VideoDecodeSubmitResult::Accepted)++index;
      else if(result==VideoDecodeSubmitResult::Backpressure) {pressured=true;sink.blocked=false;}
      else {std::fprintf(stderr,"%s\n",error.c_str());REQUIRE(false);}
      const auto drained=decoder.drainPresentation(generation,&error);
      if(drained==VideoDecodeDrainProgress::Failed) {std::fprintf(stderr,"%s\n",error.c_str());REQUIRE(false);}
      std::this_thread::yield();
    }
    sink.blocked=false;
    EXPECT(decoder.beginEndOfStream(generation,&error)!=VideoDecodeDrainProgress::Failed);
    // Idempotent: a repeated begin reports progress without restarting EOS.
    EXPECT(decoder.beginEndOfStream(generation,&error)!=VideoDecodeDrainProgress::Failed);
    while(!sink.ended) {
      REQUIRE(std::chrono::steady_clock::now()<deadline);
      if(decoder.drainEndOfStream(generation,&error)==VideoDecodeDrainProgress::Failed) {std::fprintf(stderr,"%s\n",error.c_str());REQUIRE(false);}
      std::this_thread::yield();
    }
    EXPECT(sink.count==packets.size() && pressured);
    sink.blocked=true;
  }
  EXPECT(decoder.retire(2,3)==VideoDecoderRetireProgress::Done);
  EXPECT(decoder.retire(2,3)==VideoDecoderRetireProgress::Done);
  EXPECT(decoder.retire(2,4)==VideoDecoderRetireProgress::StaleGeneration);

  // A seek's decoder restart that fails must surface as a failed drain, not as
  // a decoder that reports itself configured and quiescent forever. Preview
  // handoff releases the worker; other lanes then exhaust the process worker
  // queue, so the seek's restart is refused.
  {
    Sink restartSink;
    VideoDecodeLane lane;
    REQUIRE(lane.configure(config,restartSink,&error));
    lane.suspendForPreview(2);
    std::vector<std::unique_ptr<wam::media::avcodec::DecodeWorker>> others;
    for(unsigned i=0;i<4*wam::media::kNativeSoftwareProcessWorkers;++i) {
      auto worker=std::make_unique<wam::media::avcodec::DecodeWorker>(
          wam::media::avcodec::FrameHandler{[](void*,const AVFrame&,const wam::media::avcodec::PacketTiming&) noexcept {
            return wam::media::avcodec::FrameResult::Backpressure;
          },nullptr});
      wam::media::avcodec::Configuration other{wam::media::avcodec::Codec::Vp9,{},1,1,320,180};
      other.bitDepth=8; other.chroma=1;
      const bool admitted=worker->configure(other);
      others.push_back(std::move(worker));
      if(!admitted) break;
    }
    REQUIRE(!others.back()->hasCapacity() && others.back()->failure());
    lane.flush(3);
    error.clear();
    EXPECT(lane.drainPresentation(3,&error)==VideoDecodeDrainProgress::Failed);
    EXPECT(error=="AvcodecFlushFailed");
    EXPECT(!lane.stats().configured);
    lane.flush(4);
    EXPECT(lane.drainPresentation(4,&error)==VideoDecodeDrainProgress::Failed);
    others.clear();
    lane.close();
    EXPECT(lane.stats().generation==5 && restartSink.generation==5);
  }
  std::puts("video adapter packet/EOS/flush/backpressure and surface format passed");
  return failures==0?0:1;
}
