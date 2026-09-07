#include "platform/macos/libavformat_media_source.hpp"
#include "media/libavformat_cursor.hpp"
#include "media/matroska_opus.hpp"
#include "media/matroska_aac.hpp"
#include "media/media_iso_color.hpp"
#include "media/video_codec_configuration.hpp"
#include "platform/macos/core_media_source_support.hpp"
#include "platform/macos/matroska_sample_builder.hpp"
extern "C" {
#include <libavcodec/codec_id.h>
}
#include <algorithm>
#include <array>
#include <atomic>
#include <numeric>

namespace wam::macos {
namespace {
using namespace media;
class Context final : public MediaSourcePreparedContext {
public:
  static constexpr std::size_t kMaximumRaps = 65536;
  Context(const std::filesystem::path &path,
          const MediaSourceOpenOptions &options,
          std::shared_ptr<const MediaSourceDescriptor> descriptor)
      : MediaSourcePreparedContext(MediaSourceBackendKind::Libavformat, path,
                                   options, std::move(descriptor)) {
    raps.reserve(kMaximumRaps);
  }
  std::vector<MediaTime> raps;
  unsigned selectedStream{};
  LibavformatCursor::Identity identity{};
  bool audioOnly{};
  std::optional<unsigned> audioStream;
  std::uint32_t audioPacketFrames{};
  MediaTime audioQuantum{};
  MediaTime audioOrigin{};
};
// Slots and control blocks are allocated at open. A slot is mutable only when
// the source holds its sole reference; asynchronous decoder leases keep it
// busy.
class Storage final : public MediaPayloadStorage {
public:
  ~Storage() override {
    if (sample)
      CFRelease(sample);
  }
  CMSampleBufferRef sample{};
  std::size_t bytes{};
  std::size_t byteSize() const noexcept override { return bytes; }
  std::span<const std::byte> contiguousBytes() const noexcept override {
    char *pointer{};
    std::size_t contiguous{}, total{};
    if (!sample ||
        CMBlockBufferGetDataPointer(CMSampleBufferGetDataBuffer(sample), 0,
                                    &contiguous, &total, &pointer) != noErr ||
        contiguous != bytes || total != bytes)
      return {};
    return {reinterpret_cast<const std::byte *>(pointer), bytes};
  }
  bool copyBytes(std::size_t offset,
                 std::span<std::byte> destination) const noexcept override {
    return offset <= bytes && destination.size() <= bytes - offset &&
           CMBlockBufferCopyDataBytes(CMSampleBufferGetDataBuffer(sample),
                                      offset, destination.size(),
                                      destination.data()) == noErr;
  }

protected:
  std::optional<NativePayloadKind> nativePayloadKind() const noexcept override {
    return NativePayloadKind::CoreMediaSampleBuffer;
  }
  const void *borrowedNativePayload() const noexcept override { return sample; }
};
class PacketReader {
public:
  LibavformatCursor cursor;
  std::unique_ptr<LibavformatCursor> audioCursor;
  std::array<std::shared_ptr<Storage>, 32> pool{};
  CMFormatDescriptionRef format{}, audioFormat{};
  ~PacketReader() {
    if (format)
      CFRelease(format);
    if (audioFormat) CFRelease(audioFormat);
  }
  bool initialize(const MediaTrackDescriptor &track, std::string &error) {
    auto& description=track.audio?audioFormat:format;
    description = track.audio ? createAudioFormatDescription(track)
                              : createMatroskaVideoFormatDescription(track);
    if (!description) {
      error = "LibavformatVideoFormatDescription";
      return false;
    }
    for (auto &slot : pool)
      if(!slot) slot = std::make_shared<Storage>();
    return true;
  }
  bool materialize(const LibavformatCursor::Packet &packet,
                   MediaGeneration generation, MediaTime target,
                   const MediaTrackDescriptor &track, MediaSample &out,
                   std::string &error) {
    const auto decodeOnly =
        track.audio ? std::optional<bool>(false)
                    : accurateVideoDecodeOnly(packet.pts, packet.duration,
                                              target, &error);
    if (!decodeOnly || packet.corrupt) {
      if (packet.corrupt)
        error = "LibavformatDamagedVideoPacket";
      return false;
    }
    for (auto &slot : pool)
      if (slot.use_count() == 1 && slot->sample) {
        CFRelease(slot->sample);
        slot->sample = nullptr;
        slot->bytes = 0;
      }
    auto free = std::find_if(pool.begin(), pool.end(), [](const auto &slot) {
      return slot.use_count() == 1;
    });
    if (free == pool.end()) {
      error = "LibavformatPayloadLeaseLimit";
      return false;
    }
    auto &storage = **free;
    if (storage.sample) {
      CFRelease(storage.sample);
      storage.sample = nullptr;
    }
    CMBlockBufferRef block{};
    const std::size_t size = packet.bytes.size();
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, size,
                                           kCFAllocatorDefault, nullptr, 0,
                                           size, 0, &block) != noErr) {
      error = "LibavformatBlockAllocation";
      return false;
    }
    const MediaTime duration =
        track.audio
            ? MediaTime{track.audio->framesPerPacket,
                        static_cast<std::int32_t>(track.audio->sampleRate)}
            : packet.duration;
    const CMSampleTimingInfo timing{
        CMTimeMake(duration.value, duration.timescale),
        CMTimeMake(packet.pts.value, packet.pts.timescale),
        packet.dts.valid() ? CMTimeMake(packet.dts.value, packet.dts.timescale)
                           : kCMTimeInvalid};
    const auto copied =
        CMBlockBufferReplaceDataBytes(packet.bytes.data(), block, 0, size);
    const auto built =
        copied == noErr
            ? CMSampleBufferCreateReady(kCFAllocatorDefault, block, track.audio?audioFormat:format, 1,
                                        1, &timing, 1, &size, &storage.sample)
            : copied;
    CFRelease(block);
    if (built != noErr) {
      error = "LibavformatSampleAllocation";
      return false;
    }
    if (!track.audio) {
      CFArrayRef attachments =
          CMSampleBufferGetSampleAttachmentsArray(storage.sample, true);
      if (!attachments || !CFArrayGetCount(attachments)) {
        error = "LibavformatSampleAttachments";
        return false;
      }
      auto dict = static_cast<CFMutableDictionaryRef>(
          const_cast<void *>(CFArrayGetValueAtIndex(attachments, 0)));
      CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync,
                           packet.key ? kCFBooleanFalse : kCFBooleanTrue);
    }
    storage.bytes = size;
    out.generation = generation;
    out.track = track.id;
    out.kind = track.audio ? MediaSampleKind::EncodedAudio
                           : MediaSampleKind::EncodedVideo;
    out.presentationTime = packet.pts;
    out.decodeTime = packet.dts;
    out.duration = duration;
    out.keyFrame = packet.key;
    out.decodeOnly = *decodeOnly;
    out.payload = MediaPayloadLease(*free);
    return true;
  }
};
bool audioDescriptor(const LibavformatCursor::Stream& stream, MediaTrackDescriptor& track,
                     std::uint32_t& frames, MediaTime& origin, std::string& error) {
  if(stream.codecId!=AV_CODEC_ID_AAC && (stream.rate!=48000 || !stream.channels || stream.channels>2)) {
    error="LibavformatAudioFormatUnqualified";return false;
  }
  MediaAudioFormat format;
  format.sampleRate=48000;format.channels=stream.channels;
  format.channelLayoutPresent=true;
  format.channelLayoutTag=stream.channels==1?kAudioChannelLayoutTag_Mono:kAudioChannelLayoutTag_Stereo;
  track.kind=MediaTrackKind::Audio;track.timeBase={1,48000};
  track.codecConfigurationKind=MediaCodecConfigurationKind::AudioMagicCookie;
  if(stream.codecId==AV_CODEC_ID_OPUS) {
    const auto opus=matroska::parseOpusIdentificationHeader(stream.extradata);
    if(!opus.admitted() || opus.configuration->channelCount!=stream.channels) {
      error="LibavformatOpusConfigurationUnqualified";return false;
    }
    track.codec=MediaCodec::Opus;format.formatTag=kAudioFormatOpus;
    track.codecConfiguration.assign(stream.extradata.begin(),stream.extradata.end());
    origin={-opus.configuration->preSkipFrames,48000};frames=0;
  } else if(stream.codecId==AV_CODEC_ID_AAC) {
    const auto asc=matroska::parseAacLcAudioSpecificConfig(stream.extradata);
    if(!asc.admitted() || asc.configuration->sampleRate!=48000 || !asc.configuration->channelCount || asc.configuration->channelCount>2) {
      error="LibavformatAacConfigurationUnqualified";return false;
    }
    const auto cookie=matroska::buildAacLcEsDescriptorCookie(*asc.configuration);
    if(!cookie) {error="LibavformatAacConfigurationUnqualified";return false;}
    track.codec=MediaCodec::Aac;format.formatTag=kAudioFormatMPEG4AAC;
    format.channels=asc.configuration->channelCount;
    format.channelLayoutTag=format.channels==1?kAudioChannelLayoutTag_Mono:kAudioChannelLayoutTag_Stereo;
    track.codecConfiguration.assign(cookie->view().begin(),cookie->view().end());
    origin={0,48000};frames=1024;format.framesPerPacket=frames;
  } else {error="LibavformatAudioTimingUnproven";return false;}
  track.audio=format;return true;
}
bool audioPacket(LibavformatCursor::Packet& packet, const MediaTrackDescriptor& track,
                 MediaTime origin, MediaTime quantum, std::uint64_t ordinal, std::uint32_t& frames,
                 bool& tail, std::string& error) {
  if(track.codec==MediaCodec::Opus && (packet.bytes.empty() || (std::to_integer<unsigned>(packet.bytes.front())>>3)<16)) {
    error="LibavformatOpusModeUnqualified";return false;
  }
  const auto parsed=track.codec==MediaCodec::Opus?matroska::opusPacketFrameCount(packet.bytes)
                                               :std::optional<std::uint32_t>(track.audio->framesPerPacket);
  if(!parsed || !packet.pts.valid() || packet.corrupt || tail ||
     ordinal>std::uint64_t(INT64_MAX)/(*parsed)) {error="LibavformatAudioPacketGrid";return false;}
  if(!frames)frames=*parsed;
  if(*parsed!=frames) {error="LibavformatAudioPacketGrid";return false;}
  const auto expected=origin.value+static_cast<std::int64_t>(ordinal*frames);
  // Adjacent integer container ticks cover quantization without altering the codec sample ordinal.
  const __int128 observed=__int128(packet.pts.value)*48000;
  const __int128 exact=__int128(expected)*packet.pts.timescale;
  const auto residual=observed-exact;
  const auto bound=__int128(48000)*packet.pts.timescale*quantum.value;
  if(!ordinal && track.codec==MediaCodec::Aac && residual!=0) {
    error="LibavformatAudioTimingUnproven: aac";return false;
  }
  if(!quantum.valid() || quantum.value<=0 || residual*quantum.timescale<=-bound || residual*quantum.timescale>=bound ||
     (packet.skipStart && (ordinal || origin.value>=0 || packet.skipStart!=std::uint64_t(-origin.value))) ||
     packet.skipEnd>=frames) {error="LibavformatAudioPacketGrid";return false;}
  if(track.codec==MediaCodec::Aac && packet.skipStart) {error="LibavformatAacPrimingUnqualified";return false;}
  tail=packet.skipEnd!=0;
  packet.pts=packet.dts={expected,48000};
  packet.duration={frames-packet.skipEnd,48000};
  return true;
}
bool videoDescriptor(const LibavformatCursor::Stream &stream,
                     const MediaSourceLimits &limits,
                     MediaTrackDescriptor &track, std::string &error) {
  if (stream.unsupportedMetadata) {
    error = "LibavformatPresentationMetadataUnsupported";
    return false;
  }
  track.kind = MediaTrackKind::Video;
  if (stream.codecId == AV_CODEC_ID_H264) {
    track.codec = MediaCodec::H264;
    track.codecConfigurationKind = MediaCodecConfigurationKind::AvcC;
  } else if (stream.codecId == AV_CODEC_ID_HEVC) {
    track.codec = MediaCodec::Hevc;
    track.codecConfigurationKind = MediaCodecConfigurationKind::HvcC;
  } else if (stream.codecId == AV_CODEC_ID_MPEG4) {
    track.codec = MediaCodec::Mpeg4Visual;
    track.codecConfigurationKind = MediaCodecConfigurationKind::CodecPrivate;
  } else {
    error = "LibavformatVideoCodecNotAdmitted";
    return false;
  }
  if (stream.extradata.size() > limits.maximumCodecConfigurationBytes) {
    error = "LibavformatConfigurationLimit";
    return false;
  }
  VideoCodecConfigurationLimits config;
  config.maximumConfigurationBytes = limits.maximumCodecConfigurationBytes;
  config.maximumWidth = limits.maximumCodedWidth;
  config.maximumHeight = limits.maximumCodedHeight;
  config.maximumPixels = limits.maximumCodedPixels;
  config.admitHighDynamicRangeColor = true;
  config.admitSoftwareProfiles = true;
  const auto inspected =
      track.codec == MediaCodec::Mpeg4Visual
          ? inspectMpeg4VisualHeaders(stream.extradata, config)
          : inspectVideoCodecConfiguration(track.codec,
                                           track.codecConfigurationKind,
                                           stream.extradata, config);
  if (!inspected.admitted()) {
    error = "LibavformatVideoConfigurationNotAdmitted";
    return false;
  }
  const auto &facts = *inspected.facts;
  if (facts.width != stream.width || facts.height != stream.height) {
    error = "LibavformatVideoDimensionsDisagree";
    return false;
  }
  if (track.codec == MediaCodec::Mpeg4Visual) {
    track.codecConfiguration.resize(kMpeg4VisualEsdsOverheadBytes +
                                    stream.extradata.size());
    std::size_t written{};
    if (!buildMpeg4VisualEsds(stream.extradata, track.codecConfiguration,
                              &written, config) ||
        written != track.codecConfiguration.size()) {
      error = "LibavformatEsdsConfiguration";
      return false;
    }
  } else
    track.codecConfiguration.assign(stream.extradata.begin(),
                                    stream.extradata.end());
  track.timeBase = stream.timeBase;
  MediaVideoFormat video;
  video.codedWidth = video.displayWidth = facts.width;
  video.codedHeight = video.displayHeight = facts.height;
  video.bitsPerComponent = facts.bitDepth;
  video.sampleFormat = facts.sampleFormat;
  if (facts.color.colorDescriptionPresent) {
    video.colorPrimaries =
        mediaColorPrimariesFromIso(facts.color.colorPrimaries);
    video.transferFunction =
        mediaTransferFunctionFromIso(facts.color.transferCharacteristics);
    video.matrixCoefficients =
        mediaMatrixCoefficientsFromIso(facts.color.matrixCoefficients);
  }
  if (stream.primaries != 2)
    video.colorPrimaries = mediaColorPrimariesFromIso(stream.primaries);
  if (stream.transfer != 2)
    video.transferFunction = mediaTransferFunctionFromIso(stream.transfer);
  if (stream.matrix != 2)
    video.matrixCoefficients = mediaMatrixCoefficientsFromIso(stream.matrix);
  track.video = video;
  return true;
}
MediaTime preceding(const Context &context, MediaTime target) {
  auto it =
      std::upper_bound(context.raps.begin(), context.raps.end(), target,
                       [](MediaTime a, MediaTime b) {
                         return compareMediaTime(a, b) == MediaTimeOrder::Less;
                       });
  return it == context.raps.begin() ? context.raps.front() : *--it;
}
} // namespace
struct LibavformatMediaSource::Impl {
  std::atomic<MediaGeneration> operation{}, cancelled{};
  bool isCancelled() const noexcept {
    const auto active = operation.load(std::memory_order_acquire);
    return active && cancelled.load(std::memory_order_acquire) == active;
  }
  LibavformatCursor::Cancellation cancellation() const noexcept {
    return {this, [](const void *value) noexcept {
              return static_cast<const Impl *>(value)->isCancelled();
            }};
  }
  MediaGeneration highWater{}, armed{}, generation{};
  std::shared_ptr<const Context> context;
  std::unique_ptr<PacketReader> reader;
  std::optional<MediaSample> head;
  std::optional<LibavformatCursor::Packet> videoPending,audioPending;
  MediaTime target{}, decodeStart{};
  bool eos{}, audioEos{}, opened{}, audioTail{}, audioEosPublished{}, videoEosPublished{};
  std::uint64_t audioOrdinal{};
  std::uint64_t emitted{}, seeks{};
  std::size_t peak{};
  bool arm(MediaGeneration next) noexcept {
    if (!next || next <= highWater || armed)
      return false;
    highWater = next;
    armed = next;
    operation.store(next, std::memory_order_release);
    return true;
  }
  const MediaTrackDescriptor* packetTrack(unsigned stream) const {
    for(const auto& track:context->descriptor()->tracks)if(track.id==stream+1)return &track;
    return nullptr;
  }
  bool normalize(LibavformatCursor::Packet& packet,std::string& error) {
    const auto* track=packetTrack(packet.stream);
    if(!track || !track->audio)return true;
    auto frames=context->audioPacketFrames;
    return audioPacket(packet,*track,context->audioOrigin,context->audioQuantum,audioOrdinal++,frames,audioTail,error);
  }
  bool start(MediaTime requested, MediaSeekMode mode, std::string &error) {
    target=requested;eos=false;audioEos=false;audioTail=false;audioOrdinal=0;audioEosPublished=false;videoEosPublished=false;head.reset();videoPending.reset();audioPending.reset();
    decodeStart=preceding(*context,target);
    if(mode==MediaSeekMode::KeyFrame && compareMediaTime(decodeStart,target)!=MediaTimeOrder::Greater)target=decodeStart;
    if(reader->audioCursor && !reader->audioCursor->seek(*context->audioStream,context->audioOrigin,error))return false;
    if(!reader->cursor.seek(context->selectedStream,context->audioOnly?context->audioOrigin:decodeStart,error))return false;
    LibavformatCursor::Packet packet;
    for(unsigned skipped=0;skipped<4096;++skipped) {
      if(reader->cursor.read(packet,error)!=LibavformatCursor::Read::Packet) {
        if(error.empty())error="LibavformatNoSeekHead";return false;
      }
      if(packet.stream!=context->selectedStream)continue;
      const auto* track=packetTrack(packet.stream);if(!track)continue;
      if(track->video && (!packet.key || compareMediaTime(packet.pts,decodeStart)!=MediaTimeOrder::Equal))continue;
      if(!normalize(packet,error))return false;
      MediaSample sample;
      if(!reader->materialize(packet,generation,target,*track,sample,error))return false;
      peak=std::max(peak,sample.payload.byteSize());head=std::move(sample);return true;
    }
    error="LibavformatInterleaveLimit";return false;
  }

};
LibavformatMediaSource::LibavformatMediaSource()
    : impl_(std::make_unique<Impl>()) {}
LibavformatMediaSource::~LibavformatMediaSource() = default;
bool LibavformatMediaSource::armOperation(MediaGeneration generation) noexcept {
  return impl_->arm(generation);
}
MediaSourceOpenOutcome
LibavformatMediaSource::openLocalFile(const std::filesystem::path &path,
                                      const MediaSourceOpenOptions &options,
                                      MediaGeneration generation) {
  auto &s = *impl_;
  MediaSourceOpenOutcome out;
  out.generation = generation;
  if (s.armed != generation || !generation) {
    out.error = "LibavformatOperationNotArmed";
    return out;
  }
  s.armed = 0;
  s.generation = generation;
  s.head.reset();s.videoPending.reset();s.audioPending.reset();
  s.reader = std::make_unique<PacketReader>();
  s.context.reset();
  s.opened = false;
  out.status = MediaSourceOpenStatus::Unsupported;
  auto fail = [&]() {
    if (s.isCancelled())
      out.status = MediaSourceOpenStatus::Cancelled;
    s.videoPending.reset();s.audioPending.reset();
    s.reader.reset();
    s.context.reset();
    s.head.reset();
    s.operation.store(0, std::memory_order_release);
    return out;
  };
  if (!s.reader->cursor.open(path, s.cancellation(), out.error))
    return fail();
  auto descriptor = std::make_shared<MediaSourceDescriptor>();
  std::optional<unsigned> video, audio;
  const auto count = s.reader->cursor.streamCount();
  if (count > options.limits.maximumTracks) {
    out.error = "LibavformatTrackLimit";
    return fail();
  }
  for (unsigned i = 0; i < count; ++i) {
    const auto stream = s.reader->cursor.stream(i);
    ++descriptor->inventory.total;
    if (stream.video && !stream.attached) {
      ++descriptor->inventory.video;
      if (!video || options.selection.preferredVideo == i + 1)
        video = i;
    } else if (stream.audio) {
      ++descriptor->inventory.audio;
      if (!audio || options.selection.preferredAudio == i + 1)
        audio = i;
    } else
      ++descriptor->inventory.metadata;
  }
  if(audio) {
    const auto codec=s.reader->cursor.stream(*audio).codecId;
    const std::string_view container=s.reader->cursor.formatName();
    const bool opus=codec==AV_CODEC_ID_OPUS && (!video ||
        (s.reader->cursor.stream(*video).codecId==AV_CODEC_ID_HEVC && container.find("matroska")!=std::string_view::npos));
    const bool aac=codec==AV_CODEC_ID_AAC && video && s.reader->cursor.stream(*video).codecId==AV_CODEC_ID_H264 &&
        (container.find("mov")!=std::string_view::npos || container=="flv");
    if(!opus && !aac) {
      out.error="LibavformatAudioTimingUnproven: ";out.error+=s.reader->cursor.codecName(*audio);return fail();
    }
  }
  if (!video && !audio) {
    out.error = "LibavformatNoAdmittedVideoTrack";
    return fail();
  }
  const bool audioOnly = !video;
  if (audioOnly && options.selection.requireVideo) {
    out.error = "LibavformatRequiredVideoTrackMissing";
    return fail();
  }
  if (!audio && options.selection.requireAudio) {
    out.error = "LibavformatRequiredAudioTrackMissing";
    return fail();
  }
  if (audioOnly)
    video = audio;
  if (options.selection.preferredVideo &&
      *options.selection.preferredVideo != *video + 1) {
    out.error = "LibavformatSelectedTrackUnavailable";
    return fail();
  }
  MediaTrackDescriptor track;
  track.id = *video + 1;
  const auto stream = s.reader->cursor.stream(*video);
  MediaTrackDescriptor audioTrack;
  MediaTime audioOrigin{};
  std::uint32_t audioFrames{};
  if(audio) {
    audioTrack.id=*audio+1;
    if(!audioDescriptor(s.reader->cursor.stream(*audio),audioTrack,audioFrames,audioOrigin,out.error)) {
      out.error+=": ";out.error+=s.reader->cursor.codecName(*audio);return fail();
    }
    descriptor->selectedAudio=audioTrack.id;
  }
  if(audioOnly)track=audioTrack;
  else if(!videoDescriptor(stream,options.limits,track,out.error))return fail();
  if(!audioOnly)descriptor->selectedVideo=track.id;
  auto context=std::make_shared<Context>(path,options,descriptor);
  context->selectedStream=*video;context->identity=s.reader->cursor.identity();
  context->audioOnly=audioOnly;context->audioStream=audio;
  context->audioOrigin=audioOrigin;
  if(audio)context->audioQuantum=s.reader->cursor.stream(*audio).timeBase;
  if(audioOnly)context->raps.push_back({0,1});
  LibavformatCursor::Packet packet;
  MediaTime end{0, 1}, audioEnd{0,1},videoEnd{0,1};
  std::uint64_t bytes{}, audioPackets{};
  bool audioTail = false;
  for (std::size_t packets = 0;; ++packets) {
    if (packets == 2'000'000 || bytes > 16ULL * 1024 * 1024 * 1024) {
      out.error = "LibavformatIndexScanLimit";
      return fail();
    }
    const auto rc = s.reader->cursor.read(packet, out.error);
    if (rc == LibavformatCursor::Read::End)
      break;
    if (rc != LibavformatCursor::Read::Packet)
      return fail();
    bytes += packet.bytes.size();
    const bool isAudio=audio && packet.stream==*audio;
    if(packet.stream!=*video && !isAudio)continue;
    if (!packet.pts.valid() || (!isAudio && packet.pts.value < 0) ||
        (!isAudio && (!packet.duration.valid() || packet.duration.value <= 0)) ||
        packet.corrupt) {
      out.error = "LibavformatExactVideoTimelineUnavailable";
      return fail();
    }
    if (packet.bytes.size() > (isAudio
                                   ? options.limits.maximumAudioSampleBytes
                                   : options.limits.maximumVideoSampleBytes)) {
      out.error = "LibavformatSampleLimit";
      return fail();
    }
    if(isAudio) {
      if(!audioPacket(packet,audioTrack,audioOrigin,context->audioQuantum,audioPackets++,audioFrames,audioTail,out.error))return fail();
      audioTrack.audio->framesPerPacket=audioFrames;
    }
    const auto packetEnd = checkedExactTimeSum(packet.pts, packet.duration);
    if (!packetEnd) {
      out.error = "LibavformatVideoTimelineUnrepresentable";
      return fail();
    }
    if (compareMediaTime(*packetEnd, end) == MediaTimeOrder::Greater)
      end = *packetEnd;
    if(isAudio)audioEnd=*packetEnd;
    else if(compareMediaTime(*packetEnd,videoEnd)==MediaTimeOrder::Greater)videoEnd=*packetEnd;
    if (packet.key && !isAudio) {
      if (context->raps.size() == Context::kMaximumRaps) {
        out.error = "LibavformatRapIndexLimit";
        return fail();
      }
      if (!context->raps.empty() &&
          compareMediaTime(packet.pts, context->raps.back()) !=
              MediaTimeOrder::Greater) {
        out.error = "LibavformatNonmonotonicRapIndex";
        return fail();
      }
      context->raps.push_back(packet.pts);
    }
  }
  if (context->raps.empty() || (!audio && context->raps.front().value != 0)) {
    out.error = "LibavformatStreamOriginRapMissing";
    return fail();
  }
  context->audioPacketFrames=audioFrames;
  descriptor->duration=end;
  if(!audioOnly) { track.duration=videoEnd;descriptor->tracks.push_back(std::move(track)); }
  if(audio) { audioTrack.duration=audioEnd;descriptor->tracks.push_back(std::move(audioTrack)); }
  if(!validateMediaSourceDescriptor(*descriptor,options.limits,&out.error))return fail();
  for(const auto& selected:descriptor->tracks)if(!s.reader->initialize(selected,out.error))return fail();
  if(audio && !audioOnly) {
    s.reader->audioCursor=std::make_unique<LibavformatCursor>();
    if(!s.reader->audioCursor->open(path,s.cancellation(),out.error) ||
       s.reader->audioCursor->identity()!=context->identity)return fail();
  }
  s.context = context;
  const MediaTime target = options.initialPosition
                               ? options.initialPosition->target
                               : MediaTime{0, 1};
  if (!target.valid() || target.value < 0 ||
      compareMediaTime(target, end) == MediaTimeOrder::Greater) {
    out.error = "LibavformatInitialTargetOutsideDuration";
    return fail();
  }
  if (!s.start(target,
               options.initialPosition ? options.initialPosition->mode
                                       : MediaSeekMode::Accurate,
               out.error))
    return fail();
  if (s.isCancelled())
    return fail();
  s.opened = true;
  out.status = MediaSourceOpenStatus::Ready;
  out.actualDecodeStart = s.context->audioStream && compareMediaTime(s.decodeStart,s.target)==MediaTimeOrder::Greater
      ? MediaTime{0,1}:s.decodeStart;
  out.descriptor = descriptor;
  out.preparedContext = context;
  if (audio)
    out.audioWindow = {context->audioOrigin,
                       *audioFrameAtOrAfter(s.target, 48000), true};
  return out;
}
MediaSourceSeekOutcome
LibavformatMediaSource::seek(const MediaSourceSeekRequest &request) {
  auto &s = *impl_;
  MediaSourceSeekOutcome out;
  out.generation = request.generation;
  if (s.armed != request.generation || !s.context || !request.target.valid() ||
      request.target.value < 0 ||
      compareMediaTime(request.target, s.context->descriptor()->duration) ==
          MediaTimeOrder::Greater) {
    if (s.armed == request.generation) {
      s.armed = 0;
      s.operation.store(s.opened ? s.generation : 0, std::memory_order_release);
    }
    out.error = "LibavformatSeekRequestRejected";
    return out;
  }
  s.armed = 0;
  s.generation = request.generation;
  if (!s.start(request.target, request.mode, out.error)) {
    s.head.reset();
    s.videoPending.reset();s.audioPending.reset();
    s.reader.reset();
    s.context.reset();
    s.opened = false;
    s.operation.store(0, std::memory_order_release);
    return out;
  }
  ++s.seeks;
  out.accepted = true;
  out.actualDecodeStart = s.context->audioStream && compareMediaTime(s.decodeStart,s.target)==MediaTimeOrder::Greater
      ? MediaTime{0,1}:s.decodeStart;
  out.preparedContext = s.context;
  if (s.context->audioStream)
    out.audioWindow = {s.context->audioOrigin,
                       *audioFrameAtOrAfter(s.target, 48000), true};
  return out;
}
MediaSourceReadResult
LibavformatMediaSource::readNext(MediaGeneration expected) {
  auto &s = *impl_;
  if (s.isCancelled())
    return MediaSourceCancelled{expected};
  if (!s.opened || expected != s.generation)
    return MediaSourceFailure{expected, "LibavformatReadGenerationMismatch"};
  if (s.head) {
    auto sample = std::move(*s.head);
    s.head.reset();
    ++s.emitted;
    return sample;
  }
  const bool mixed=bool(s.reader->audioCursor);
  std::string error;
  const auto fill=[&](bool audio)->bool {
    auto& pending=audio?s.audioPending:s.videoPending;
    auto& ended=audio?s.audioEos:s.eos;
    if(pending || ended)return true;
    auto& cursor=audio?*s.reader->audioCursor:s.reader->cursor;
    const auto stream=audio?*s.context->audioStream:s.context->selectedStream;
    for(unsigned skipped=0;skipped<4096;++skipped) {
      LibavformatCursor::Packet packet;
      const auto rc=cursor.read(packet,error);
      if(rc==LibavformatCursor::Read::End) {ended=true;return true;}
      if(rc!=LibavformatCursor::Read::Packet)return false;
      if(packet.stream!=stream)continue;
      if(!s.normalize(packet,error))return false;
      pending=packet;return true;
    }
    error="LibavformatInterleaveLimit";return false;
  };
  if(!fill(false) || (mixed && !fill(true))) {
    if(s.isCancelled())return MediaSourceCancelled{expected};
    return MediaSourceFailure{expected,std::move(error)};
  }
  if(s.eos && !s.videoPending && !s.videoEosPublished) {
    s.videoEosPublished=true;return MediaEndOfStream{expected,s.context->selectedStream+1};
  }
  if(mixed && s.audioEos && !s.audioPending && !s.audioEosPublished) {
    s.audioEosPublished=true;return MediaEndOfStream{expected,*s.context->audioStream+1};
  }
  if(!s.videoPending && !s.audioPending)return MediaSourceExhausted{expected};
  const auto timestamp=[](const LibavformatCursor::Packet& packet) {
    return packet.dts.valid()?packet.dts:packet.pts;
  };
  const bool audio=s.audioPending && (!s.videoPending ||
      compareMediaTime(timestamp(*s.audioPending),timestamp(*s.videoPending))!=MediaTimeOrder::Greater);
  auto& pending=audio?s.audioPending:s.videoPending;
  const auto* track=s.packetTrack(pending->stream);
  MediaSample sample;
  if(!track || !s.reader->materialize(*pending,expected,s.target,*track,sample,error))
    return MediaSourceFailure{expected,std::move(error)};
  pending.reset();++s.emitted;return sample;
}
void LibavformatMediaSource::requestCancel(
    MediaGeneration generation) noexcept {
  if (generation &&
      impl_->operation.load(std::memory_order_acquire) == generation) {
    auto observed = impl_->cancelled.load(std::memory_order_acquire);
    while (observed < generation &&
           !impl_->cancelled.compare_exchange_weak(observed, generation,
                                                   std::memory_order_release,
                                                   std::memory_order_acquire)) {
    }
  }
}
void LibavformatMediaSource::close() noexcept {
  impl_->head.reset();
  impl_->videoPending.reset();impl_->audioPending.reset();
  impl_->reader.reset();
  impl_->context.reset();
  impl_->opened = false;
  impl_->armed = 0;
  impl_->operation.store(0, std::memory_order_release);
}
MediaSourceStats LibavformatMediaSource::stats() const noexcept {
  const auto &s = *impl_;
  MediaSourceStats out;
  out.open = s.opened;
  out.cancelled = s.isCancelled();
  out.operationGeneration = s.operation.load(std::memory_order_acquire);
  out.generation = s.generation;
  out.stagedGeneration = s.head || s.videoPending || s.audioPending ? s.generation : 0;
  out.stagedVideoHeads =
      (s.head && s.head->kind == MediaSampleKind::EncodedVideo) || (s.videoPending && !s.context->audioOnly) ? 1 : 0;
  out.stagedAudioHeads =
      (s.head && s.head->kind == MediaSampleKind::EncodedAudio) || s.audioPending || (s.videoPending && s.context->audioOnly) ? 1 : 0;
  out.stagedPayloadBytes = (s.head ? s.head->payload.byteSize() : 0) +
      (s.videoPending?s.videoPending->bytes.size():0)+(s.audioPending?s.audioPending->bytes.size():0);
  out.peakStagedPayloadBytes = std::max(s.peak,out.stagedPayloadBytes);
  out.samplesEmitted = s.emitted;
  out.seeksAccepted = s.seeks;
  return out;
}
} // namespace wam::macos

namespace wam::macos {
namespace {
class Preview final : public NativePreviewSource {
public:
  explicit Preview(std::shared_ptr<const Context> context)
      : context_(std::move(context)) {}
  NativePreviewBeginOutcome
  begin(NativePreviewRequest request) noexcept override {
    NativePreviewBeginOutcome out;
    out.epoch = request.epoch;
    if (!request.epoch || request.epoch <= facts_.epochHighWater ||
        !request.target.valid() || request.target.value < 0 ||
        compareMediaTime(request.target, context_->descriptor()->duration) ==
            MediaTimeOrder::Greater)
      return out;
    operation_.store(request.epoch, std::memory_order_release);
    facts_.epochHighWater = request.epoch;
    facts_.target = request.target;
    facts_.open = false;
    reader_.reset();
    try {
      reader_ = std::make_unique<PacketReader>();
      ++facts_.backend.readersCreated;
      if (!reader_->cursor.open(
              context_->localPath(),
              LibavformatCursor::Cancellation{
                  this,
                  [](const void *value) noexcept {
                    return static_cast<const Preview *>(value)->isCancelled();
                  }},
              out.error) ||
          !reader_->initialize(context_->descriptor()->tracks.front(),
                               out.error)) {
        out.status = NativePreviewStatus::Unsupported;
        return out;
      }
      if (reader_->cursor.identity() != context_->identity) {
        out.status = NativePreviewStatus::Failed;
        out.error = "LibavformatFileChanged";
        reader_.reset();
        return out;
      }
      out.actualDecodeStart = preceding(*context_, request.target);
      if (!reader_->cursor.seek(context_->selectedStream, out.actualDecodeStart,
                                out.error)) {
        out.status = NativePreviewStatus::Failed;
        return out;
      }
      if (isCancelled()) {
        out.status = NativePreviewStatus::Cancelled;
        return out;
      }
      facts_.activeEpoch = request.epoch;
      facts_.actualDecodeStart = out.actualDecodeStart;
      facts_.open = true;
      ++facts_.backend.readersStarted;
      out.status = NativePreviewStatus::Ready;
      return out;
    } catch (...) {
      out.status = NativePreviewStatus::Failed;
      out.error = "LibavformatPreviewAllocation";
      return out;
    }
  }
  bool advanceTarget(std::uint64_t epoch, MediaTime target) noexcept override {
    if (epoch != facts_.activeEpoch || !facts_.open || isCancelled() ||
        !target.valid() ||
        compareMediaTime(target, facts_.target) == MediaTimeOrder::Less ||
        compareMediaTime(target, context_->descriptor()->duration) ==
            MediaTimeOrder::Greater)
      return false;
    facts_.target = target;
    ++facts_.forwardRetargets;
    return true;
  }
  NativePreviewReadResult readNext(std::uint64_t epoch) noexcept override {
    if (isCancelled())
      return NativePreviewCancelled{epoch};
    if (!facts_.open || epoch != facts_.activeEpoch)
      return NativePreviewFailure{epoch, "LibavformatPreviewEpochMismatch"};
    std::string error;
    LibavformatCursor::Packet packet;
    for (unsigned skipped = 0; skipped < 4096; ++skipped) {
      const auto rc = reader_->cursor.read(packet, error);
      if (rc == LibavformatCursor::Read::End) {
        facts_.open = false;
        return NativePreviewEndOfStream{epoch};
      }
      if (rc == LibavformatCursor::Read::Cancelled)
        return NativePreviewCancelled{epoch};
      if (rc != LibavformatCursor::Read::Packet)
        return NativePreviewFailure{epoch, std::move(error)};
      if (packet.stream != context_->selectedStream)
        continue;
      MediaSample sample;
      if (!reader_->materialize(packet, epoch, facts_.target,
                                context_->descriptor()->tracks.front(), sample,
                                error))
        return NativePreviewFailure{epoch, std::move(error)};
      ++facts_.samplesRead;
      facts_.peakStagedSampleBuffers = 1;
      memory_.peakStagedCompressedBytes =
          std::max(memory_.peakStagedCompressedBytes,
                   std::uint64_t(packet.bytes.size()));
      return sample;
    }
    return NativePreviewFailure{epoch, "LibavformatPreviewInterleaveLimit"};
  }
  void requestCancel(std::uint64_t epoch) noexcept override {
    if (epoch && operation_.load(std::memory_order_acquire) == epoch) {
      auto observed = cancelled_.load(std::memory_order_acquire);
      while (observed < epoch && !cancelled_.compare_exchange_weak(
                                     observed, epoch, std::memory_order_release,
                                     std::memory_order_acquire)) {
      }
    }
  }
  void close() noexcept override {
    operation_.store(0, std::memory_order_release);
    reader_.reset();
    facts_.open = false;
    facts_.activeEpoch = 0;
  }
  NativePreviewSourceFacts facts() const noexcept override {
    auto result = facts_;
    result.operationEpoch = operation_.load(std::memory_order_acquire);
    result.cancelled = isCancelled();
    return result;
  }
  NativePreviewSourceMemoryFacts memoryFacts() const noexcept override {
    return memory_;
  }

private:
  std::shared_ptr<const Context> context_;
  std::unique_ptr<PacketReader> reader_;
  bool isCancelled() const noexcept {
    const auto active = operation_.load(std::memory_order_acquire);
    return active && cancelled_.load(std::memory_order_acquire) == active;
  }
  std::atomic<std::uint64_t> cancelled_{};
  std::atomic<std::uint64_t> operation_{};
  NativePreviewSourceFacts facts_{};
  NativePreviewSourceMemoryFacts memory_{};
};
} // namespace
std::unique_ptr<NativePreviewSource>
createLibavformatPreviewSource(NativePreviewBinding binding) noexcept {
  try {
    auto context =
        std::dynamic_pointer_cast<const Context>(binding.assetContext);
    if (!context || context->audioOnly ||
        !context->matchesPreviewBinding(binding.localPath, binding.descriptor))
      return {};
    return std::make_unique<Preview>(std::move(context));
  } catch (...) {
    return {};
  }
}
} // namespace wam::macos
