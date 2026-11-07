#include "software_avcodec_video_decoder.hpp"
#include "software_presentation_pool.hpp"
#include "media/avcodec/decode_worker.hpp"
#include "media/media_codec_facts.hpp"
#include "media/media_iso_color.hpp"
#include "media/video_codec_configuration.hpp"
#include "native_video_color.hpp"
extern "C" {
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>
}
#include <atomic>
#include <optional>
#include <string>
#include <utility>
#include <cstring>
#include <vector>

namespace wam::macos {
namespace {
using namespace media::avcodec;
media::MediaTime exact(CMTime t) noexcept {
  if(!CMTIME_IS_NUMERIC(t) || (t.flags & kCMTimeFlags_HasBeenRounded)) return {};
  return {t.value,t.timescale};
}
CMTime cm(media::MediaTime t) noexcept { return t.valid()?CMTimeMake(t.value,t.timescale):kCMTimeInvalid; }
}
struct SoftwareAvcodecVideoDecoder::Impl {
  VideoDecoderOptions options;
  VideoStreamConfiguration configuration;
  std::vector<std::byte> configurationBytes;
  std::unique_ptr<DecodeWorker> worker;
  SoftwarePresentationPool pool;
  DecodedFrameSink* sink{};
  FrameLease pending;
  std::atomic<bool> published{false};
  std::atomic<const char*> error{nullptr};
  std::uint64_t submitted{},delivered{},pressure{},generation{};
  unsigned depth{};
  bool chroma422{},fullRange{},eos{},notified{},suspended{},awaitingKeyFrame{};
  bool retired{};
  std::uint64_t retiredGeneration{},retiredInvalidation{};
  // The diagnostic takeLastError() hands over once; failure state itself stays
  // in `error` and the worker.
  const char* reported{};
  std::optional<std::string> lastError;
  void latch(const char* reason,std::string* out) {
    if(out) *out=reason;
    if(!lastError) { try { lastError.emplace(reason); } catch(...) {} }
  }
  OSType pixelFormat{};
  media::avcodec::Codec codec{};
  void fail(const char* reason) noexcept { error.store(reason,std::memory_order_release); }
  static FrameResult receive(void* context,const AVFrame& frame,const PacketTiming& provenance) noexcept {
    auto& s=*static_cast<Impl*>(context);
    if(s.published.load(std::memory_order_acquire)) return FrameResult::Backpressure;
    const bool is422=frame.format==AV_PIX_FMT_YUV422P || frame.format==AV_PIX_FMT_YUV422P10LE;
    const unsigned bits=frame.format==AV_PIX_FMT_YUV420P10LE || frame.format==AV_PIX_FMT_YUV422P10LE?10:8;
    if(frame.format!=AV_PIX_FMT_YUV420P && frame.format!=AV_PIX_FMT_YUV420P10LE &&
       frame.format!=AV_PIX_FMT_YUV422P && frame.format!=AV_PIX_FMT_YUV422P10LE) {
      s.fail("AvcodecPresentationFormatUnsupported"); return FrameResult::Failed;
    }
    if(frame.width!=s.configuration.codedSize.width || frame.height!=s.configuration.codedSize.height ||
       bits!=s.depth || is422!=s.chroma422 || frame.crop_top || frame.crop_bottom || frame.crop_left || frame.crop_right) {
      s.fail("AvcodecFrameGeometryChanged"); return FrameResult::Failed;
    }
    if(frame.color_range!=AVCOL_RANGE_UNSPECIFIED && (frame.color_range==AVCOL_RANGE_JPEG)!=s.fullRange) {
      s.fail("AvcodecFrameRangeChanged"); return FrameResult::Failed;
    }
    auto destination=s.pool.acquire();
    if(!destination) return FrameResult::Backpressure;
    const std::uint8_t* planes[]{frame.data[0],frame.data[1],frame.data[2]};
    if(!copySoftwarePlanes(destination,planes,frame.linesize,frame.width,frame.height,bits,is422)) {
      CVPixelBufferRelease(destination); s.fail("AvcodecPlaneLayoutUnsupported"); return FrameResult::Failed;
    }
    const auto attach=[destination](CFStringRef key,CFTypeRef value) {
      if(value) CVBufferSetAttachment(destination,key,value,kCVAttachmentMode_ShouldPropagate);
    };
    const auto& config=s.configuration;
    CFStringRef primaries=frame.color_primaries==AVCOL_PRI_UNSPECIFIED?config.colorPrimaries:
      colorPrimariesExtension(media::mediaColorPrimariesFromIso(frame.color_primaries));
    CFStringRef transfer=frame.color_trc==AVCOL_TRC_UNSPECIFIED?config.transferFunction:
      transferFunctionExtension(media::mediaTransferFunctionFromIso(frame.color_trc));
    CFStringRef matrix=frame.colorspace==AVCOL_SPC_UNSPECIFIED?config.ycbcrMatrix:
      ycbcrMatrixExtension(media::mediaMatrixCoefficientsFromIso(frame.colorspace));
    if((frame.color_primaries!=AVCOL_PRI_UNSPECIFIED && !primaries) ||
       (frame.color_trc!=AVCOL_TRC_UNSPECIFIED && !transfer) ||
       (frame.colorspace!=AVCOL_SPC_UNSPECIFIED && !matrix)) {
      CVPixelBufferRelease(destination); s.fail("AvcodecFrameColorUnsupported"); return FrameResult::Failed;
    }
    const UntaggedSurfaceTags untagged=untaggedSurfaceTags(frame.width,frame.height);
    attach(kCVImageBufferColorPrimariesKey,primaries?primaries:untagged.primaries);
    attach(kCVImageBufferTransferFunctionKey,transfer?transfer:untagged.transfer);
    attach(kCVImageBufferYCbCrMatrixKey,matrix?matrix:untagged.matrix);
    CFStringRef location=nullptr;
    switch(frame.chroma_location) {
    case AVCHROMA_LOC_UNSPECIFIED: break;
    case AVCHROMA_LOC_LEFT: location=kCVImageBufferChromaLocation_Left; break;
    case AVCHROMA_LOC_CENTER: location=kCVImageBufferChromaLocation_Center; break;
    case AVCHROMA_LOC_TOPLEFT: location=kCVImageBufferChromaLocation_TopLeft; break;
    case AVCHROMA_LOC_TOP: location=kCVImageBufferChromaLocation_Top; break;
    case AVCHROMA_LOC_BOTTOMLEFT: location=kCVImageBufferChromaLocation_BottomLeft; break;
    case AVCHROMA_LOC_BOTTOM: location=kCVImageBufferChromaLocation_Bottom; break;
    default: CVPixelBufferRelease(destination); s.fail("AvcodecChromaLocationUnsupported"); return FrameResult::Failed;
    }
    attach(kCVImageBufferChromaLocationTopFieldKey,location);
    FrameTiming timing{cm(provenance.pts),cm(provenance.duration),provenance.generation,(frame.flags&AV_FRAME_FLAG_KEY)!=0};
    FrameLease lease(destination,timing);
    CVPixelBufferRelease(destination);
    // Registry insertion contention retains this decoded frame for the next owner wake.
    if(!lease) return FrameResult::Backpressure;
    s.pending=std::move(lease);
    s.published.store(true,std::memory_order_release);
    if(s.options.progressHandler.function) s.options.progressHandler.function(s.options.progressHandler.context);
    return FrameResult::Accepted;
  }
  bool start() {
    worker=std::make_unique<DecodeWorker>(FrameHandler{receive,this},
      WakeHandler{options.progressHandler.function,options.progressHandler.context});
    auto extra=std::span<const std::byte>(configurationBytes);
    if(codec==Codec::Mpeg4) {
      const auto payload=media::mpeg4VisualDecoderSpecificInfo(extra);
      if(!payload) { fail("AvcodecMpeg4ExtradataMissing"); return false; }
      extra=*payload;
    } else if(codec==Codec::Vp9) extra={};
    Configuration config{codec,extra,generation,generation,
      static_cast<unsigned>(configuration.codedSize.width),static_cast<unsigned>(configuration.codedSize.height)};
    config.bitDepth=depth; config.chroma=chroma422?2:1;
    return worker->configure(config);
  }
};
SoftwareAvcodecVideoDecoder::SoftwareAvcodecVideoDecoder(VideoDecoderOptions options):impl_(std::make_unique<Impl>()) { impl_->options=options; }
SoftwareAvcodecVideoDecoder::~SoftwareAvcodecVideoDecoder() { close(); }
bool SoftwareAvcodecVideoDecoder::configure(const VideoStreamConfiguration& configuration,DecodedFrameSink& sink,std::string* error) {
  auto& s=*impl_;
  if(s.retired) { s.latch("AvcodecDecoderRetired",error); return false; }
  close();
  if (configuration.codedSize.width<=0 || configuration.codedSize.height<=0 ||
      !media::MediaSourceLimits::codedDimensionsWithinHardCeiling(
          std::uint64_t(configuration.codedSize.width),std::uint64_t(configuration.codedSize.height))) {
    if(error)*error="AvcodecSoftwareReferenceBudgetExceeded";return false;
  }
  media::VideoCodecConfigurationLimits limits; limits.admitHighDynamicRangeColor=true; limits.admitSoftwareProfiles=true;
  const auto codec=media::mediaCodecForCoreMediaType(configuration.codec);
  const auto facts=media::inspectVideoCodecConfiguration(codec,media::mediaCodecFacts(codec).configurationKind,configuration.codecConfiguration,limits);
  if(!facts.admitted() || (codec!=media::MediaCodec::H264 && codec!=media::MediaCodec::Mpeg4Visual && codec!=media::MediaCodec::Vp9)) {
    if(error) *error="AvcodecVideoConfigurationUnsupported"; return false;
  }
  s.codec=codec==media::MediaCodec::H264?Codec::H264:codec==media::MediaCodec::Vp9?Codec::Vp9:Codec::Mpeg4;
  s.configuration=configuration;
  s.configurationBytes.assign(configuration.codecConfiguration.begin(),configuration.codecConfiguration.end());
  s.configuration.codecConfiguration=s.configurationBytes;
  s.generation=configuration.generation; s.sink=&sink;
  s.depth=facts.facts->bitDepth;
  if(configuration.highDynamicRangeTransfer && s.depth<10) {
    if(error)*error="AvcodecHdrDepthPromotionUnsupported";close();return false;
  }
  s.chroma422=media::mediaSampleFormatIs422(facts.facts->sampleFormat);
  s.fullRange=configuration.fullRangeVideo.value_or(facts.facts->color.fullRange);
  s.pixelFormat=biplanarVideoRangeFormat(s.chroma422,s.depth==10);
  if(s.fullRange) s.pixelFormat=fullRangeCounterpartFormat(s.pixelFormat);
  s.eos=false; s.notified=false; s.suspended=false; s.awaitingKeyFrame=true; s.error.store(nullptr);
  s.reported=nullptr;
  if(!s.pool.configure(configuration.codedSize.width,configuration.codedSize.height,s.pixelFormat) || !s.start()) {
    if(error) *error=s.worker && s.worker->failure()?s.worker->failure():"AvcodecVideoConfigureFailed";
    close(); return false;
  }
  sink.flush(s.generation); return true;
}
VideoDecodeSubmitResult SoftwareAvcodecVideoDecoder::submitCMSampleBuffer(CMSampleBufferRef sample,std::uint64_t generation,std::string* error) {
  auto& s=*impl_;
  if(!sample || !s.worker || generation!=s.generation) {
    s.latch(!sample?"AvcodecSampleMissing":!s.worker?"AvcodecNotConfigured":"AvcodecStaleGeneration",error);
    return VideoDecodeSubmitResult::Rejected;
  }
  if(s.eos) { s.latch("AvcodecSubmitAfterEndOfStream",error); return VideoDecodeSubmitResult::Rejected; }
  if(s.awaitingKeyFrame && !sampleIsSyncSample(sample)) {
    s.latch("decoder requires a key frame after configure or flush",error);
    return VideoDecodeSubmitResult::Rejected;
  }
  if(!s.worker->hasCapacity()) {
    if(s.worker->failure()) { s.latch(s.worker->failure(),error); return VideoDecodeSubmitResult::Rejected; }
    ++s.pressure; return VideoDecodeSubmitResult::Backpressure;
  }
  auto block=CMSampleBufferGetDataBuffer(sample);
  const auto bytes=block?CMBlockBufferGetDataLength(block):0;
  const auto scratch=s.worker->conversionStorage();
  if(!bytes || bytes>scratch.size() || CMBlockBufferCopyDataBytes(block,0,bytes,scratch.data())!=noErr) {
    s.latch("AvcodecPacketStorageInvalid",error); return VideoDecodeSubmitResult::Rejected;
  }
  PacketTiming timing{exact(CMSampleBufferGetPresentationTimeStamp(sample)),exact(CMSampleBufferGetDecodeTimeStamp(sample)),
    exact(CMSampleBufferGetDuration(sample)),generation,generation};
  switch(s.worker->submit(scratch.first(bytes),timing)) {
  case WorkerResult::Accepted: s.awaitingKeyFrame=false; ++s.submitted; return VideoDecodeSubmitResult::Accepted;
  case WorkerResult::Backpressure: ++s.pressure; return VideoDecodeSubmitResult::Backpressure;
  default: s.latch("AvcodecPacketSubmissionRefused",error); return VideoDecodeSubmitResult::Rejected;
  }
}
VideoDecodeDrainProgress SoftwareAvcodecVideoDecoder::beginEndOfStream(std::uint64_t generation,std::string* error) {
  auto& s=*impl_; if(generation!=s.generation)return VideoDecodeDrainProgress::StaleGeneration;
  if(!s.eos) {
    if(!s.worker || s.worker->endOfStream(generation)!=WorkerResult::Accepted) {
      s.latch(s.worker?"AvcodecEndOfStreamRefused":"AvcodecNotConfigured",error);
      return VideoDecodeDrainProgress::Failed;
    }
    s.eos=true;
    return VideoDecodeDrainProgress::Progress;
  }
  if(s.notified) return VideoDecodeDrainProgress::Done;
  return VideoDecodeDrainProgress::Quiescing;
}
VideoDecodeDrainProgress SoftwareAvcodecVideoDecoder::drainPresentation(std::uint64_t generation,std::string* error) {
  auto& s=*impl_; if(generation!=s.generation)return VideoDecodeDrainProgress::StaleGeneration;
  if(s.suspended) return VideoDecodeDrainProgress::Quiescing;
  const char* failure=s.error.load(); if(!failure && s.worker)failure=s.worker->failure();
  if(failure || !s.worker) { s.latch(failure?failure:"AvcodecNotConfigured",error); return VideoDecodeDrainProgress::Failed; }
  if(!s.published.load(std::memory_order_acquire)) { s.worker->retryOutput(); return VideoDecodeDrainProgress::Quiescing; }
  const auto result=s.sink->enqueue(s.pending,error);
  if(result==FrameEnqueueResult::Backpressure)return VideoDecodeDrainProgress::Quiescing;
  if(result==FrameEnqueueResult::Rejected) {
    s.fail("AvcodecSinkRejectedFrame"); s.latch("AvcodecSinkRejectedFrame",error);
    return VideoDecodeDrainProgress::Failed;
  }
  s.pending.reset(); s.published.store(false,std::memory_order_release); ++s.delivered;
  s.worker->retryOutput(); return VideoDecodeDrainProgress::Progress;
}
VideoDecodeDrainProgress SoftwareAvcodecVideoDecoder::drainEndOfStream(std::uint64_t generation,std::string* error) {
  auto& s=*impl_;
  if(generation==s.generation && !s.eos) {
    s.latch("AvcodecEndOfStreamDrainBeforeBegin",error); return VideoDecodeDrainProgress::Failed;
  }
  const auto progress=drainPresentation(generation,error);
  if(progress!=VideoDecodeDrainProgress::Quiescing)return progress;
  if(s.eos && s.worker->drained() && !s.published.load(std::memory_order_acquire)) {
    if(!s.notified) { s.sink->endOfStream(generation); s.notified=true; }
    return VideoDecodeDrainProgress::Done;
  }
  return VideoDecodeDrainProgress::Quiescing;
}
void SoftwareAvcodecVideoDecoder::suspendForPreview(std::uint64_t next) noexcept {
  auto& s=*impl_; if(s.retired || (!s.worker && !s.suspended))return;
  if(s.worker) s.worker->close();
  s.worker.reset(); s.pending.reset(); s.published.store(false);
  s.generation=next; s.eos=false; s.notified=false; s.error.store(nullptr);
  s.suspended=true; s.awaitingKeyFrame=true; s.sink->flush(next);
}
bool SoftwareAvcodecVideoDecoder::resumeAfterPreview() noexcept {
  auto& s=*impl_; if(!s.suspended)return true;
  try {
    if(!s.start()) { s.fail("AvcodecFlushFailed"); return false; }
  } catch(...) { s.fail("AvcodecFlushFailed"); return false; }
  s.suspended=false;
  return true;
}
void SoftwareAvcodecVideoDecoder::flush(std::uint64_t next) noexcept {
  if(impl_->retired) return;
  suspendForPreview(next);
  static_cast<void>(resumeAfterPreview());
}
VideoDecoderRetireProgress SoftwareAvcodecVideoDecoder::retire(std::uint64_t retired,std::uint64_t next) noexcept {
  auto& s=*impl_;
  if(s.retired)
    return s.retiredGeneration==retired && s.retiredInvalidation==next
        ? VideoDecoderRetireProgress::Done : VideoDecoderRetireProgress::StaleGeneration;
  if(retired!=s.generation)return VideoDecoderRetireProgress::StaleGeneration;
  if(next<=retired)return VideoDecoderRetireProgress::Failed;
  close(); s.generation=next;
  s.retired=true; s.retiredGeneration=retired; s.retiredInvalidation=next;
  return VideoDecoderRetireProgress::Done;
}
void SoftwareAvcodecVideoDecoder::close() noexcept {
  auto& s=*impl_; if(s.retired) return;
  if(s.worker) s.worker->close(); s.worker.reset();
  s.pending.reset(); s.published.store(false); s.pool.close(); s.suspended=false;
  std::vector<std::byte>().swap(s.configurationBytes); s.configuration.codecConfiguration={};
  if(s.sink) s.sink->flush(s.generation+1); s.sink=nullptr;
}
VideoDecoderStats SoftwareAvcodecVideoDecoder::stats() const noexcept {
  const auto& s=*impl_; VideoDecoderStats result;
  result.configured=bool(s.worker)||s.suspended; result.generation=s.generation; result.awaitingKeyFrame=s.awaitingKeyFrame;
  result.maxInFlightFrames=s.options.maxInFlightFrames;
  result.inFlightFrames=s.worker?s.worker->queuedPackets():0;
  result.acceptsCompressedSample=s.worker && s.worker->hasCapacity();
  result.retainedPresentationFrames=s.published.load(std::memory_order_acquire)?1:0;
  result.pendingPresentationFrames=result.retainedPresentationFrames;
  result.submittedFrames=s.submitted; result.deliveredFrames=s.delivered; result.backpressuredSubmissions=s.pressure;
  result.endOfStreamBegun=s.eos; result.endOfStreamCallbacksFinalized=s.worker&&s.worker->drained(); result.endOfStreamSinkNotified=s.notified;
  result.outputInterop=s.options.outputInterop; result.requestedOutputPixelFormat=s.pixelFormat; result.actualOutputPixelFormat=s.pixelFormat;
  return result;
}
VideoDecoderMemoryFacts SoftwareAvcodecVideoDecoder::memoryFacts() const noexcept {
  VideoDecoderMemoryFacts facts;
  facts.presentationFrames=impl_->published.load(std::memory_order_acquire)?1:0;
  if(impl_->worker) {
    facts.inFlightFrames=impl_->worker->queuedPackets();
    facts.currentCompressedBytes=impl_->worker->compressedBytes();
    facts.currentCopiedCompressedBytes=facts.currentCompressedBytes;
    facts.peakCompressedBytes=impl_->worker->peakCompressedBytes();
    facts.peakCopiedCompressedBytes=facts.peakCompressedBytes;
  }
  return facts;
}
std::optional<std::string> SoftwareAvcodecVideoDecoder::takeLastError() {
  auto& s=*impl_;
  // Asynchronous worker/frame failures are surfaced once, like a latched one.
  const char* failure=s.error.load();
  if(!failure && s.worker) failure=s.worker->failure();
  if(failure && failure!=s.reported) { s.reported=failure; s.latch(failure,nullptr); }
  return std::exchange(s.lastError,std::nullopt);
}
}
