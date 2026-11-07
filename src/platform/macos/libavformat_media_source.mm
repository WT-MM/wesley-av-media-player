#include "platform/macos/libavformat_aac_timing.hpp"
#include "media/software_color_qualification.hpp"
#include "media/audio_codec_timing.hpp"
#include "media/aac_packet_timeline.hpp"
#include "media/media_codec_facts.hpp"
#include "platform/macos/libavformat_media_source.hpp"
#include "media/libavformat_cursor.hpp"
#include "media/native_late_frame_trace.hpp"
#include "media/codec/opus.hpp"
#include "media/codec/aac.hpp"
#include "media/media_iso_color.hpp"
#include "media/video_codec_configuration.hpp"
#include "platform/macos/core_media_codec_facts.hpp"
#include "platform/macos/core_media_source_support.hpp"
#include "platform/macos/core_media_carriage.hpp"
#include "platform/macos/native_custom_source_core.hpp"
#include "platform/macos/native_preview_source_core.hpp"
extern "C" {
#include <libavcodec/codec_id.h>
}
#include <algorithm>
#include <array>
#include <atomic>
#include <numeric>
#include <chrono>
#include <cstdio>
#include <cstdlib>

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
  FileIdentity identity{};
  bool audioOnly{};
  std::shared_ptr<AacPacketTimeline> aacTimeline;
  std::optional<unsigned> audioStream;
  std::uint32_t audioPacketFrames{};
  MediaTime audioQuantum{};
  MediaTime audioOrigin{};
  MediaTime audioDemuxOrigin{};
  MediaTime audioMediaStart{0,1};
};
// At most kPayloadLeases samples may be leased at once; a slot is reusable
// only when the reader holds its sole reference.
class PacketReader {
public:
  static constexpr std::size_t kPayloadLeases = 32;
  LibavformatCursor cursor;
  std::unique_ptr<LibavformatCursor> audioCursor;
  std::array<std::shared_ptr<CoreMediaSampleStorage>, kPayloadLeases> pool{};
  CMFormatDescriptionRef format{}, audioFormat{};
  ~PacketReader() {
    if (format)
      CFRelease(format);
    if (audioFormat) CFRelease(audioFormat);
  }
  bool initialize(const MediaTrackDescriptor &track, std::string &error) {
    auto& description=track.audio?audioFormat:format;
    description = track.audio ? createAudioFormatDescription(track)
                              : createVideoFormatDescription(track);
    if (!description) {
      error = "LibavformatVideoFormatDescription";
      return false;
    }
    return true;
  }
  bool materialize(const LibavformatCursor::Packet &packet,
                   MediaGeneration generation, MediaTime target,
                   const Context &context, const MediaTrackDescriptor &track,
                   MediaSample &out, std::string &error) {
    const auto decodeOnly =
        track.audio ? std::optional<bool>(false)
                    : accurateVideoDecodeOnly(packet.pts, packet.duration,
                                              target, &error);
    if (!decodeOnly || packet.corrupt) {
      if (packet.corrupt)
        error = "LibavformatDamagedVideoPacket";
      return false;
    }
    // Retire every sample whose lease has come back, so a free slot never
    // keeps its last CMSampleBuffer alive.
    for (auto &slot : pool)
      if (slot.use_count() == 1)
        slot.reset();
    auto free = std::find(pool.begin(), pool.end(), nullptr);
    if (free == pool.end()) {
      error = "LibavformatPayloadLeaseLimit";
      return false;
    }
    const std::size_t size = packet.bytes.size();
    CMBlockBufferRef block{};
    std::span<std::byte> destination;
    if (!allocateSampleBlock(size, "libavformat", &block, &destination, &error))
      return false;
    std::copy(packet.bytes.begin(), packet.bytes.end(), destination.begin());
    const MediaTime duration =
        track.audio && track.codec != MediaCodec::Aac
            ? MediaTime{track.audio->framesPerPacket,
                        static_cast<std::int32_t>(track.audio->sampleRate)}
            : packet.duration;
    CompressedSampleShape shape;
    shape.timing = {
        CMTimeMake(duration.value, duration.timescale),
        CMTimeMake(packet.pts.value, packet.pts.timescale),
        packet.dts.valid() ? CMTimeMake(packet.dts.value, packet.dts.timescale)
                           : kCMTimeInvalid};
    shape.sizes = &size;
    if (!track.audio)
      shape.videoKeyFrame = packet.key;
    ScopedSampleBuffer owned;
    if (!buildCompressedSampleBuffer(block, track.audio ? audioFormat : format,
                                     shape, "libavformat", &owned, &error))
      return false;
    if (track.audio) {
      const auto floor=audioFrameAtOrAfter(target,static_cast<std::uint32_t>(track.audio->sampleRate));
      const auto frame=exactAudioFrameIndex(packet.pts,static_cast<std::uint32_t>(track.audio->sampleRate));
      const auto floorFrame=floor ? exactAudioFrameIndex(*floor,static_cast<std::uint32_t>(track.audio->sampleRate)) : std::nullopt;
      if (floorFrame && frame && *floorFrame-*frame>=audioPrimingFrames(track.codec,track.audio->framesPerPacket))
        static_cast<void>(statedImmediatePlayoutFrame(owned.get()));
    }
    *free = leaseSampleBuffer(std::move(owned), size);
    out.generation = generation;
    out.track = track.id;
    out.kind = track.audio ? MediaSampleKind::EncodedAudio
                           : MediaSampleKind::EncodedVideo;
    out.presentationTime = packet.pts;
    out.decodeTime = packet.dts;
    out.duration = duration;
    out.keyFrame = packet.key;
    out.decodeOnly = *decodeOnly;
    out.aacPiecewiseTimeline = track.codec == MediaCodec::Aac;
    out.payload = MediaPayloadLease(*free);
    return validateMediaSample(out, *context.descriptor(), context.limits(),
                               &error);
  }
};
bool audioDescriptor(const LibavformatCursor::Stream& stream, MediaTrackDescriptor& track,
                     std::uint32_t& frames, MediaTime& origin, bool flvHeader, std::string& error) {
  if(stream.codecId!=AV_CODEC_ID_AAC && (stream.rate!=48000 || !stream.channels || stream.channels>2)) {
    error="LibavformatAudioFormatUnqualified";return false;
  }
  MediaAudioFormat format;
  format.sampleRate=stream.rate;format.channels=stream.channels;
  applyChannelLayoutTag(&format,stream.channels);
  track.kind=MediaTrackKind::Audio;track.timeBase={1,static_cast<std::int32_t>(stream.rate)};
  track.codecConfigurationKind=MediaCodecConfigurationKind::AudioMagicCookie;
  if(stream.codecId==AV_CODEC_ID_OPUS) {
    const auto opus=codec::parseOpusIdentificationHeader(stream.extradata);
    if(!opus.admitted() || opus.configuration->channelCount!=stream.channels) {
      error="LibavformatOpusConfigurationUnqualified";return false;
    }
    track.codec=MediaCodec::Opus;format.formatTag=kAudioFormatOpus;
    track.codecConfiguration.assign(stream.extradata.begin(),stream.extradata.end());
    origin={-opus.configuration->preSkipFrames,48000};frames=0;
  } else if(stream.codecId==AV_CODEC_ID_AAC) {
    const auto asc=codec::parseAacLcAudioSpecificConfig(stream.extradata);
    if(!asc.admitted() || (!flvHeader && (asc.configuration->sampleRate!=stream.rate || asc.configuration->channelCount!=stream.channels))) {
      error="LibavformatAacConfigurationUnqualified";
      if (codec::aacSbrSignaled(stream.extradata)) error=codec::kHeAacDecoderDelayRefusal;
      if (stream.extradata.size() >= 2) {
        const auto index=static_cast<std::uint8_t>(((std::to_integer<unsigned>(stream.extradata[0])&7)<<1) |
                         (std::to_integer<unsigned>(stream.extradata[1])>>7));
        const auto rate=codec::aacSampleRateForIndex(index);
        if (rate && rate*2==stream.rate) error=codec::kHeAacDecoderDelayRefusal;
      }
      return false;
    }
    const auto cookie=codec::buildAacLcEsDescriptorCookie(*asc.configuration);
    if(!cookie) {error="LibavformatAacConfigurationUnqualified";return false;}
    track.codec=MediaCodec::Aac;format.formatTag=kAudioFormatMPEG4AAC;
    // FLV's legacy SoundRate/SoundType fields are not AAC configuration.
    // The ASC is authoritative for AAC's rate and channel arrangement.
    format.sampleRate=asc.configuration->sampleRate;
    track.timeBase={1,static_cast<std::int32_t>(asc.configuration->sampleRate)};
    format.channels=asc.configuration->channelCount;
    applyChannelLayoutTag(&format,format.channels);
    track.codecConfiguration.assign(cookie->view().begin(),cookie->view().end());
    origin={0,static_cast<std::int32_t>(asc.configuration->sampleRate)};frames=codec::kAacLcSamplesPerAccessUnit;format.framesPerPacket=frames;
  } else {error="LibavformatAudioTimingUnproven";return false;}
  track.audio=format;return true;
}
bool audioPacket(LibavformatCursor::Packet& packet, const MediaTrackDescriptor& track,
                 MediaTime origin, MediaTime demuxOrigin, MediaTime quantum, std::uint64_t ordinal, std::uint32_t& frames,
                 bool& tail, std::string& error, const AacPacketTimeline::Packet* proof = nullptr) {
  if(track.codec==MediaCodec::Opus && (packet.bytes.empty() || (std::to_integer<unsigned>(packet.bytes.front())>>3)<16)) {
    error="LibavformatOpusModeUnqualified";return false;
  }
  const auto parsed=track.codec==MediaCodec::Opus?codec::opusPacketFrameCount(packet.bytes)
                                               :std::optional<std::uint32_t>(track.audio->framesPerPacket);
  if(!parsed || !*parsed || !packet.pts.valid() || packet.corrupt || tail ||
     ordinal>std::uint64_t(INT64_MAX)/(*parsed)) {error="LibavformatAudioPacketGrid";return false;}
  if(!frames)frames=*parsed;
  if(*parsed!=frames) {error="LibavformatAudioPacketGrid";return false;}
  const __int128 expectedWide=__int128(origin.value)+__int128(ordinal)*frames;
  const __int128 demuxWide=__int128(demuxOrigin.value)+__int128(ordinal)*frames;
  if (expectedWide<INT64_MIN || expectedWide>INT64_MAX ||
      demuxWide<INT64_MIN || demuxWide>INT64_MAX) {
    error="LibavformatAudioPacketGridOverflow";return false;
  }
  const auto expected=static_cast<std::int64_t>(expectedWide);
  // AAC is on grid when the shared piecewise timeline (quarter-access-unit
  // bound) proved the packet; Opus must lie within one container tick.
  const auto rate = static_cast<std::int32_t>(track.audio->sampleRate);
  const __int128 observed=__int128(packet.pts.value)*rate;
  const __int128 exact=demuxWide*packet.pts.timescale;
  const auto residual=observed-exact;
  const auto bound=__int128(rate)*packet.pts.timescale*quantum.value;
  if(!ordinal && track.codec==MediaCodec::Aac && residual!=0) {
    error="LibavformatAudioTimingUnproven: aac";return false;
  }
  const bool onGrid = track.codec == MediaCodec::Aac
      ? proof != nullptr
      : quantum.valid() && quantum.value>0 && residual*quantum.timescale>=-bound && residual*quantum.timescale<=bound;
  if (!onGrid && track.codec==MediaCodec::Aac) {
    error="AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples";return false;
  }
  if(!onGrid ||
     (packet.skipStart && (ordinal || demuxOrigin.value>=0 || packet.skipStart!=std::uint64_t(-demuxOrigin.value))) ||
     packet.skipEnd>=frames) {error="LibavformatAudioPacketGrid";return false;}
  tail=packet.skipEnd!=0;
  const __int128 presentation = proof ? __int128(proof->start)+origin.value-demuxOrigin.value : expected;
  if (presentation < INT64_MIN || presentation > INT64_MAX) {
    error="LibavformatAudioPacketGridOverflow";return false;
  }
  packet.pts=packet.dts={static_cast<std::int64_t>(presentation),rate};
  packet.duration={proof ? std::min<std::int64_t>(proof->duration, packet.skipEnd ? frames-packet.skipEnd : INT64_MAX) : frames-packet.skipEnd,rate};
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
  auto config = VideoCodecConfigurationLimits::from(limits);
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
  if (const char* refusal = softwareContainerColorRefusal(track.codec, stream.fullRange, facts.profile)) {
    error = refusal;
    return false;
  }
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
  video.fullRangeVideo = stream.rangeSpecified ? stream.fullRange : facts.color.fullRange;
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
struct LibavformatSourceTraits {
  static constexpr const char* kName = "libavformat";
  using AssetContext = Context;
};
using Clock = std::chrono::steady_clock;
double milliseconds(Clock::time_point from, Clock::time_point to) {
  return std::chrono::duration<double,std::milli>(to-from).count();
}
struct OpenTelemetry {
  bool enabled{};
  Clock::time_point begun, cursorOpened, scanStarted, scanFinished;
  double readMs{}, witnessMs{};
  std::size_t packets{};
  std::uint64_t bytes{};
};
} // namespace
struct LibavformatMediaSource::Impl final
    : NativeSourceCore<Impl, LibavformatSourceTraits> {
  std::unique_ptr<PacketReader> reader;
  std::optional<LibavformatCursor::Packet> videoPending,audioPending;
  MediaTime target{}, decodeStart{}, audioDecodeStart{}, windowStart{};
  MediaAudioGenerationWindow audioWindow{};
  bool audioStartsAtOrigin{true};
  bool audioTail{};
  std::uint64_t audioOrdinal{};
  CancellationToken cancellation() const noexcept {
    return {this, [](const void *value) noexcept {
              return static_cast<const Impl *>(value)->isCancelled();
            }};
  }
  void retireActive() noexcept {
    videoPending.reset();
    audioPending.reset();
  }
  void resetSourceFacts() noexcept { reader.reset(); }
  const MediaTrackDescriptor* packetTrack(unsigned stream) const {
    const auto& context = assetContext;
    for(const auto& track:context->descriptor()->tracks)if(track.id==stream+1)return &track;
    return nullptr;
  }
  bool normalize(LibavformatCursor::Packet& packet,std::string& error) {
    const auto& context = assetContext;
    const auto* track=packetTrack(packet.stream);
    if(!track || !track->audio)return true;
    auto frames=context->audioPacketFrames;
    const auto* proof=context->aacTimeline ? context->aacTimeline->find(packet.pts) : nullptr;
    if (context->aacTimeline && (!proof || audioOrdinal >= context->aacTimeline->packets().size() ||
        proof != &context->aacTimeline->packets()[audioOrdinal])) {
      error="LibavformatAudioPacketSequenceChanged";return false;
    }
    return audioPacket(packet,*track,context->audioOrigin,context->audioDemuxOrigin,context->audioQuantum,audioOrdinal++,frames,audioTail,error,proof);
  }
  // Indexes the whole file once at cold open: the descriptor, the video RAP
  // index and the AAC piecewise timeline.
  std::shared_ptr<Context> scan(const std::filesystem::path &path,
                                const MediaSourceOpenOptions &options,
                                std::string &error, MediaRefusalClass &refusal,
                                OpenTelemetry &t) {
  if (!reader->cursor.open(path, cancellation(), error, &refusal))
    return nullptr;
  t.cursorOpened = Clock::now();
  auto descriptor = std::make_shared<MediaSourceDescriptor>();
  std::optional<unsigned> video, audio;
  const auto count = reader->cursor.streamCount();
  if (count > options.limits.maximumTracks) {
    error = "LibavformatTrackLimit";
    return nullptr;
  }
  for (unsigned i = 0; i < count; ++i) {
    const auto stream = reader->cursor.stream(i);
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
    const auto codec=reader->cursor.stream(*audio).codecId;
    const std::string_view container=reader->cursor.formatName();
    const bool opus=codec==AV_CODEC_ID_OPUS && (!video ||
        (reader->cursor.stream(*video).codecId==AV_CODEC_ID_HEVC && container.find("matroska")!=std::string_view::npos));
    const bool aac=codec==AV_CODEC_ID_AAC &&
        (container.find("mov")!=std::string_view::npos ||
         (container=="flv" && video && reader->cursor.stream(*video).codecId==AV_CODEC_ID_H264) ||
         container.find("matroska")!=std::string_view::npos);
    if(!opus && !aac) {
      error="LibavformatAudioTimingUnproven: ";error+=reader->cursor.codecName(*audio);return nullptr;
    }
  }
  if (!video && !audio) {
    error = "LibavformatNoAdmittedVideoTrack";
    return nullptr;
  }
  const bool audioOnly = !video;
  if (audioOnly && options.selection.requireVideo) {
    error = "LibavformatRequiredVideoTrackMissing";
    return nullptr;
  }
  if (!audio && options.selection.requireAudio) {
    error = "LibavformatRequiredAudioTrackMissing";
    return nullptr;
  }
  if (audioOnly)
    video = audio;
  if (options.selection.preferredVideo &&
      *options.selection.preferredVideo != *video + 1) {
    error = "LibavformatSelectedTrackUnavailable";
    return nullptr;
  }
  MediaTrackDescriptor track;
  track.id = *video + 1;
  const auto stream = reader->cursor.stream(*video);
  MediaTrackDescriptor audioTrack;
  MediaTime audioOrigin{};
  std::uint32_t audioFrames{};
  if(audio) {
    audioTrack.id=*audio+1;
    if(!audioDescriptor(reader->cursor.stream(*audio),audioTrack,audioFrames,audioOrigin,std::string_view(reader->cursor.formatName())=="flv",error)) {
      error+=": ";error+=reader->cursor.codecName(*audio);return nullptr;
    }
    descriptor->selectedAudio=audioTrack.id;
  }
  if(audioOnly)track=audioTrack;
  else if(!videoDescriptor(stream,options.limits,track,error))return nullptr;
  if(!audioOnly)descriptor->selectedVideo=track.id;
  auto context=std::make_shared<Context>(path,options,descriptor);
  context->selectedStream=*video;context->identity=reader->cursor.identity();
  context->audioOnly=audioOnly;context->audioStream=audio;
  context->audioOrigin=audioOrigin;
  context->audioDemuxOrigin=audioOrigin;
  if(audio)context->audioQuantum=reader->cursor.stream(*audio).timeBase;
  if(audioOnly)context->raps.push_back({0,1});
  LibavformatCursor::Packet packet;
  MediaTime end{0, 1}, audioEnd{0,1},videoEnd{0,1};
  std::uint64_t& bytes = t.bytes;
  std::uint64_t audioPackets{};
  bool audioTail = false;
  std::optional<MediaTime> aacProvedEnd;
  std::optional<LibavformatAacEdit> aacEditEnd;
  t.scanStarted = Clock::now();
  for (std::size_t packets = 0;; ++packets) {
    if (packets == kMaximumAudioIndexScanPackets || bytes > 16ULL * 1024 * 1024 * 1024) {
      error = "LibavformatIndexScanLimit";
      return nullptr;
    }
    const auto readStarted = t.enabled ? Clock::now() : Clock::time_point{};
    const auto rc = reader->cursor.read(packet, error);
    if (t.enabled) t.readMs += milliseconds(readStarted,Clock::now());
    t.packets = packets;
    if (rc == LibavformatCursor::Read::End)
      break;
    if (rc != LibavformatCursor::Read::Packet)
      return nullptr;
    bytes += packet.bytes.size();
    const bool isAudio=audio && packet.stream==*audio;
    if(packet.stream!=*video && !isAudio)continue;
    if (!packet.pts.valid() || (!isAudio && packet.pts.value < 0) ||
        (!isAudio && (!packet.duration.valid() || packet.duration.value <= 0)) ||
        packet.corrupt) {
      error = "LibavformatExactVideoTimelineUnavailable";
      return nullptr;
    }
    if (packet.bytes.size() > (isAudio
                                   ? options.limits.maximumAudioSampleBytes
                                   : options.limits.maximumVideoSampleBytes)) {
      error = "LibavformatSampleLimit";
      return nullptr;
    }
    if(isAudio) {
      if (!audioPackets && audioTrack.codec == MediaCodec::Aac) {
        const auto witnessStarted = Clock::now();
        const auto rate = static_cast<std::uint32_t>(audioTrack.audio->sampleRate);
        const auto origin = exactAudioFrameIndex(packet.pts, rate);
        if (!origin || (*origin < 0 && packet.skipStart != std::uint64_t(-*origin)) ||
            (*origin >= 0 && packet.skipStart)) {
          error="LibavformatAudioPrimingUnproven: aac";return nullptr;
        }
        audioOrigin = {*origin,static_cast<std::int32_t>(rate)};
        context->audioOrigin = context->audioDemuxOrigin = audioOrigin;
        context->audioMediaStart = audioOrigin.value > 0 ? audioOrigin : MediaTime{0,1};
        // Fragmented Apple MOV can add an extra encoder edit; it is proved by
        // an independent byte-and-output-timing witness instead of guessed.
        const std::string_view container = reader->cursor.formatName();
        // FLV has no edit/CodecDelay witness for a displaced AAC origin, so
        // FLV AAC is admitted only at a zero origin.
        if (container=="flv" && (*origin!=0 || packet.skipStart)) {
          error="LibavformatAudioTimingUnproven: aac";return nullptr;
        }
        if (container.find("mov") != std::string_view::npos) {
          aacEditEnd = inspectLibavformatAacEdit(path,reader->cursor.stream(*audio).containerTrackId);
          if (!aacEditEnd) {error="LibavformatAudioTimingUnproven: aac";return nullptr;}
          context->audioMediaStart = *audioFrameAtOrAfter(aacEditEnd->start,rate);
          if (compareMediaTime(audioOrigin,context->audioMediaStart)==MediaTimeOrder::Greater) {
            error="LibavformatAudioPrimingUnproven: origin after media start";return nullptr;
          }
        }
        if (rate == 48000 && (*origin == -64 || *origin == -2112)) {
          const auto proof = proveLibavformatAacTiming(path,
              reader->cursor.stream(*audio).containerTrackId, packet);
          if (!proof) {error="LibavformatAudioTimingUnproven: aac";return nullptr;}
          audioOrigin = proof->origin;
          aacProvedEnd = proof->end;
          context->audioOrigin = audioOrigin;
          context->audioDemuxOrigin = proof->demuxOrigin;
        }
        t.witnessMs += milliseconds(witnessStarted,Clock::now());
      }
      if (audioTrack.codec == MediaCodec::Aac) {
        if (!context->aacTimeline) context->aacTimeline = std::make_shared<AacPacketTimeline>(
            static_cast<std::uint32_t>(audioTrack.audio->sampleRate));
        // Some containers omit packet duration; their fixed AAC extent is
        // known from the ASC. Explicit short durations (MOV) are used as stated.
        const auto duration = packet.duration.valid() && packet.duration.value > 0 ? packet.duration :
            MediaTime{codec::kAacLcSamplesPerAccessUnit,static_cast<std::int32_t>(audioTrack.audio->sampleRate)};
        if (!context->aacTimeline->append(packet.pts,duration)) {
          error="AacPacketTimelineDiscontinuity: unrepresentable piecewise grid";return nullptr;
        }
      }
      if(!audioPacket(packet,audioTrack,audioOrigin,context->audioDemuxOrigin,context->audioQuantum,audioPackets++,audioFrames,audioTail,error,
          context->aacTimeline ? &context->aacTimeline->packets().back() : nullptr))return nullptr;
      audioTrack.audio->framesPerPacket=audioFrames;
    }
    const auto packetEnd = media::addMediaTime(packet.pts, packet.duration);
    if (!packetEnd) {
      error = "LibavformatVideoTimelineUnrepresentable";
      return nullptr;
    }
    if (compareMediaTime(*packetEnd, end) == MediaTimeOrder::Greater)
      end = *packetEnd;
    if(isAudio)audioEnd=*packetEnd;
    else if(compareMediaTime(*packetEnd,videoEnd)==MediaTimeOrder::Greater)videoEnd=*packetEnd;
    if (packet.key && !isAudio) {
      if (context->raps.size() == Context::kMaximumRaps) {
        error = "LibavformatRapIndexLimit";
        return nullptr;
      }
      if (!context->raps.empty() &&
          compareMediaTime(packet.pts, context->raps.back()) !=
              MediaTimeOrder::Greater) {
        error = "LibavformatNonmonotonicRapIndex";
        return nullptr;
      }
      context->raps.push_back(packet.pts);
    }
  }
  t.scanFinished = Clock::now();
  if (context->aacTimeline && !context->aacTimeline->finish(std::string_view(reader->cursor.formatName()).find("mov")!=std::string_view::npos)) {
    error="AacPacketTailTrimUnproven";return nullptr;
  }
  if (context->raps.empty() || (!audio && context->raps.front().value != 0)) {
    error = "LibavformatStreamOriginRapMissing";
    return nullptr;
  }
  if (audio) {
    const auto rate=static_cast<std::uint32_t>(audioTrack.audio->sampleRate);
    const auto frame=exactAudioFrameIndex(audioEnd,rate);
    if (!frame) {error="LibavformatAudioEndUnrepresentable";return nullptr;}
    audioEnd={*frame,static_cast<std::int32_t>(rate)};
  }
  if (context->aacTimeline) {
    const auto& last = context->aacTimeline->packets().back();
    const MediaTime provedEnd{last.start+last.duration+context->audioOrigin.value-context->audioDemuxOrigin.value,
                             context->audioOrigin.timescale};
    if (compareMediaTime(provedEnd,audioEnd)==MediaTimeOrder::Less) audioEnd=provedEnd;
  }
  if (aacEditEnd && !aacProvedEnd) {
    const auto rate = static_cast<std::uint32_t>(audioTrack.audio->sampleRate);
    const auto declared = audioFrameAtOrAfter(aacEditEnd->end,rate);
    const auto frame=declared ? exactAudioFrameIndex(*declared,rate) : std::nullopt;
    if (!frame || *frame > audioEnd.value + kAacPacketGridResidualFrames) {
      error="LibavformatAudioTimingUnproven: aac edit extends beyond packet end";return nullptr;
    }
  }
  if (aacProvedEnd && compareMediaTime(audioEnd,*aacProvedEnd)!=MediaTimeOrder::Equal) {
    error="LibavformatAudioTimingUnproven: aac endpoint " + std::to_string(audioEnd.value) + "/" + std::to_string(audioEnd.timescale) + " tail=" + std::to_string(context->aacTimeline->packets().back().start) + "+" + std::to_string(context->aacTimeline->packets().back().duration) + " shift=" + std::to_string(context->audioOrigin.value-context->audioDemuxOrigin.value) + " versus " + std::to_string(aacProvedEnd->value) + "/" + std::to_string(aacProvedEnd->timescale);return nullptr;
  }
  context->audioPacketFrames=audioFrames;
  descriptor->duration=end;
  if(!audioOnly) { track.duration=videoEnd;descriptor->tracks.push_back(std::move(track)); }
  if(audio) { audioTrack.duration=audioEnd;descriptor->tracks.push_back(std::move(audioTrack)); }
  if(!validateMediaSourceDescriptor(*descriptor,options.limits,&error))return nullptr;
  for(const auto& selected:descriptor->tracks)if(!reader->initialize(selected,error))return nullptr;
  if(audio && !audioOnly) {
    reader->audioCursor=std::make_unique<LibavformatCursor>();
    if(!reader->audioCursor->open(path,cancellation(),error) ||
       reader->audioCursor->identity()!=context->identity)return nullptr;
  }
    return context;
  }
  // Positions the audio lane a bounded preroll before the target rather than
  // at the stream origin, so seek cost does not grow with the target time.
  bool seekAudio(std::string& error) {
    const auto& context = assetContext;
    auto& cursor=context->audioOnly ? reader->cursor : *reader->audioCursor;
    const auto* track=packetTrack(*context->audioStream);
    const auto rate=static_cast<std::uint32_t>(context->audioOrigin.timescale);
    const auto floor=audioFrameAtOrAfter(target,rate);
    const auto frame=floor ? exactAudioFrameIndex(*floor,rate) : std::nullopt;
    if(!track || !frame) {error="LibavformatAudioSeekTarget";return false;}
    const std::int64_t packetFrames=context->audioPacketFrames;
    const auto preroll=audioPrimingFrames(track->codec,packetFrames);
    const auto demuxOrigin=context->audioDemuxOrigin;
    const auto demuxFrame=*frame-context->audioOrigin.value+demuxOrigin.value;
    // Backs off twice the preroll, so a container seek landing up to one
    // preroll late still leaves the whole preroll ahead of the target.
    MediaTime seekTime=demuxOrigin;
    if(context->aacTimeline) {
      // An elapsed-time backoff alone can land inside declared silence,
      // with no decoder warm-up at all. Require actual packets too.
      const auto targetIndex=context->aacTimeline->indexAtFrame(demuxFrame);
      const auto index=std::min(targetIndex > kAacSeekBackoffPackets ? targetIndex-kAacSeekBackoffPackets : 0,
          context->aacTimeline->indexAtFrame(demuxFrame-2*preroll));
      seekTime=context->aacTimeline->packets()[index].observed;
    } else if(demuxFrame-2*preroll>demuxOrigin.value) {
      const auto ordinal=(demuxFrame-2*preroll-demuxOrigin.value)/packetFrames;
      seekTime={demuxOrigin.value+ordinal*packetFrames,demuxOrigin.timescale};
    }
    // A landing that is not the first packet yet does not begin after the
    // audio media start is neither an origin generation nor a primed one;
    // it restarts from the origin.
    for(bool retry=false;;retry=true) {
      if(!cursor.seek(*context->audioStream,retry ? demuxOrigin : seekTime,error))return false;
      LibavformatCursor::Packet packet;
      for(unsigned skipped=0;;++skipped) {
        if(skipped==4096 || cursor.read(packet,error)!=LibavformatCursor::Read::Packet) {
          error="LibavformatAudioSeekHeadUnavailable";return false;
        }
        if(packet.stream==*context->audioStream)break;
      }
      if(context->aacTimeline) {
        const auto* proof=context->aacTimeline->find(packet.pts);
        if (!proof) {error="LibavformatAudioSeekOrdinal";return false;}
        audioOrdinal=static_cast<std::uint64_t>(proof-context->aacTimeline->packets().data());
      } else {
        // The nearest ordinal on the constant grid; normalize then holds the
        // packet to within one container tick of it.
        const __int128 offset=packet.pts.valid() ?
            __int128(packet.pts.value)*rate-__int128(demuxOrigin.value)*packet.pts.timescale : -1;
        const __int128 unit=__int128(packetFrames)*packet.pts.timescale;
        if(!packet.pts.valid() || offset<-unit/2) {error="LibavformatAudioSeekOrdinal";return false;}
        audioOrdinal=static_cast<std::uint64_t>((offset+unit/2)/unit);
      }
      audioStartsAtOrigin=audioOrdinal==0;
      if(!normalize(packet,error))return false;
      audioDecodeStart=packet.pts;
      if(!audioStartsAtOrigin && !retry &&
         compareMediaTime(audioDecodeStart,context->audioMediaStart)!=MediaTimeOrder::Greater)continue;
      if(!audioStartsAtOrigin && *frame-audioDecodeStart.value < preroll) {
        error="LibavformatAudioSeekPrerollUnproven";return false;
      }
      audioPending=packet;
      return true;
    }
  }
  bool start(MediaTime requested, MediaSeekMode mode, std::string &error) {
    const auto& context = assetContext;
    target=requested;audioTail=false;audioOrdinal=0;
    decodeStart=preceding(*context,target);
    if(mode==MediaSeekMode::KeyFrame && compareMediaTime(decodeStart,target)!=MediaTimeOrder::Greater)target=decodeStart;
    audioDecodeStart=context->audioOrigin;audioStartsAtOrigin=true;
    if(context->audioStream && !seekAudio(error))return false;
    if(context->audioOnly)return stage(true,true,&error) && stage(false,true,&error) && stateWindow(error);
    if(!reader->cursor.seek(context->selectedStream,decodeStart,error))return false;
    LibavformatCursor::Packet packet;
    for(unsigned skipped=0;skipped<4096;++skipped) {
      if(reader->cursor.read(packet,error)!=LibavformatCursor::Read::Packet) {
        if(error.empty())error="LibavformatNoSeekHead";return false;
      }
      if(packet.stream!=context->selectedStream)continue;
      const auto* track=packetTrack(packet.stream);if(!track)continue;
      if(track->video && (!packet.key || compareMediaTime(packet.pts,decodeStart)!=MediaTimeOrder::Equal))continue;
      if(!normalize(packet,error))return false;
      (track->video?videoPending:audioPending)=packet;
      return stage(true,true,&error) && stage(false,true,&error) && stateWindow(error);
    }
    error="LibavformatInterleaveLimit";return false;
  }
  // The generation's reported decode start and audio window, shared by open
  // and seek.
  bool stateWindow(std::string& error) {
    const auto& context = assetContext;
    const auto start=timelineWindowDecodeStart(decodeStart,target,context->raps.front());
    if(!start) {error="LibavformatDecodeStartOutsideWindow";return false;}
    windowStart=*start;
    audioWindow={};
    if(!context->audioStream)return true;
    const auto presentationStart=audioFrameAtOrAfter(
        compareMediaTime(target,context->audioMediaStart)==MediaTimeOrder::Less ? context->audioMediaStart : target,
        context->audioOrigin.timescale);
    if(!presentationStart) {error="LibavformatAudioWindowUnrepresentable";return false;}
    audioWindow={audioDecodeStart,*presentationStart,audioStartsAtOrigin,context->audioMediaStart};
    return true;
  }

  // One lane head: the positioned packet when begin left one, else the next
  // packet of the lane's stream, materialized as one CoreMedia sample.
  [[nodiscard]] bool stage(bool video, bool admission, std::string* error) {
    const std::optional<MediaTrackId> selected =
        video ? descriptor->selectedVideo : descriptor->selectedAudio;
    if (!selected) {
      (video ? videoTerminal : audioTerminal) = true;
      return true;
    }
    auto& pending = video ? videoPending : audioPending;
    std::string message;
    if (!pending) {
      auto& cursor = video || assetContext->audioOnly ? reader->cursor : *reader->audioCursor;
      const unsigned stream = *selected - 1;
      for (unsigned skipped = 0;; ++skipped) {
        if (skipped == 4096) {
          assignError(error, "LibavformatInterleaveLimit");
          return false;
        }
        LibavformatCursor::Packet packet;
        const auto rc = cursor.read(packet, message);
        if (rc == LibavformatCursor::Read::End) {
          (video ? videoTerminal : audioTerminal) = true;
          if (admission) {
            assignNamed(error, "selected ", " output has no admission sample");
            return false;
          }
          return true;
        }
        if (rc != LibavformatCursor::Read::Packet) {
          if (error != nullptr) *error = std::move(message);
          return false;
        }
        if (packet.stream != stream) continue;
        if (!normalize(packet, message)) {
          if (error != nullptr) *error = std::move(message);
          return false;
        }
        pending = std::move(packet);
        break;
      }
    }
    const auto* track = packetTrack(pending->stream);
    MediaSample sample;
    if (track == nullptr ||
        !reader->materialize(*pending, generation, target, *assetContext, *track,
                             sample, message)) {
      if (error != nullptr) *error = std::move(message);
      return false;
    }
    pending.reset();
    const std::size_t bytes = sample.payload.byteSize();
    const MediaTime order =
        sample.decodeTime.valid() ? sample.decodeTime : sample.presentationTime;
    (video ? videoHead : audioHead) =
        StagedSample{*selected, order, std::move(sample), bytes};
    publishHeadFacts();
    return true;
  }
  [[nodiscard]] GenerationStart begin(
      const std::filesystem::path& requestedPath,
      const MediaSourceOpenOptions& requestedOptions,
      MediaGeneration requestedGeneration,
      const std::optional<MediaTime>& requestedTarget,
      MediaSeekMode mode, const std::shared_ptr<const Context>& existingContext) {
    GenerationStart started;
    OpenTelemetry t;
    t.enabled = existingContext == nullptr && media::late_trace::enabled;
    t.begun = Clock::now();
    if (!resetForGeneration(requestedOptions, requestedGeneration,
                            requestedTarget, mode)) {
      started.status = MediaSourceOpenStatus::Cancelled;
      return started;
    }
    started.status = MediaSourceOpenStatus::Unsupported;
    const auto fail = [&] {
      if (isCancelled())
        started.status = MediaSourceOpenStatus::Cancelled;
      reader.reset();
      withdrawFailedOperation();
      return started;
    };
    std::shared_ptr<const Context> context = existingContext;
    if (context == nullptr) {
      reader = std::make_unique<PacketReader>();
      context = scan(requestedPath, requestedOptions, started.error,
                     started.refusal, t);
      if (context == nullptr) return fail();
    } else if (reader == nullptr) {
      started.error = "LibavformatReaderUnavailable";
      return fail();
    }
    assetContext = context;
    descriptor = context->descriptor();
    const MediaTime position = requestedTarget.value_or(MediaTime{0, 1});
    if (!position.valid() || position.value < 0 ||
        compareMediaTime(position, descriptor->duration) == MediaTimeOrder::Greater) {
      started.error = "LibavformatInitialTargetOutsideDuration";
      return fail();
    }
    if (!start(position, mode, started.error) || isCancelled())
      return fail();
    started.status = MediaSourceOpenStatus::Ready;
    started.actualDecodeStart = windowStart;
    started.descriptor = descriptor;
    started.context = context;
    started.audioWindow = audioWindow;
    open = true;
    openSnapshot.store(true, std::memory_order_release);
    if (t.enabled) std::fprintf(stderr,
        "WAM: libavformat open packets=%zu bytes=%llu cursor_ms=%.3f metadata_ms=%.3f scan_ms=%.3f read_ms=%.3f witness_ms=%.3f generation_ms=%.3f total_ms=%.3f\n",
        t.packets,static_cast<unsigned long long>(t.bytes),milliseconds(t.begun,t.cursorOpened),milliseconds(t.cursorOpened,t.scanStarted),
        milliseconds(t.scanStarted,t.scanFinished),t.readMs,t.witnessMs,milliseconds(t.scanFinished,Clock::now()),milliseconds(t.begun,Clock::now()));
    return started;
  }
};
LibavformatMediaSource::LibavformatMediaSource()
    : impl_(std::make_unique<Impl>()) {}
LibavformatMediaSource::~LibavformatMediaSource() { close(); }
bool LibavformatMediaSource::armOperation(MediaGeneration generation) noexcept {
  return impl_->arm(generation);
}
MediaSourceOpenOutcome
LibavformatMediaSource::openLocalFile(const std::filesystem::path &path,
                                      const MediaSourceOpenOptions &options,
                                      MediaGeneration generation) {
  return impl_->openLocalFile(path, options, generation);
}
MediaSourceSeekOutcome
LibavformatMediaSource::seek(const MediaSourceSeekRequest &request) {
  return impl_->seek(request);
}
MediaSourceReadResult
LibavformatMediaSource::readNext(MediaGeneration expected) {
  return impl_->readNext(expected);
}
void LibavformatMediaSource::requestCancel(
    MediaGeneration generation) noexcept {
  impl_->requestCancel(generation);
}
void LibavformatMediaSource::close() noexcept { impl_->close(); }
MediaSourceStats LibavformatMediaSource::stats() const noexcept {
  return impl_->stats();
}
} // namespace wam::macos

namespace wam::macos {
namespace {
class Preview final : public NativePreviewSource {
public:
  Preview(std::shared_ptr<const Context> context,
          const MediaTrackDescriptor &track)
      : context_(std::move(context)), track_(track) {}
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
              CancellationToken{
                  this,
                  [](const void *value) noexcept {
                    return static_cast<const Preview *>(value)->isCancelled();
                  }},
              out.error) ||
          !reader_->initialize(track_, out.error)) {
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
      if (!reader_->materialize(packet, epoch, facts_.target, *context_,
                                track_, sample, error))
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
    publishPreviewCancellation(operation_, cancelled_, epoch);
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
  // Borrowed from the descriptor the context retains for this source's life.
  const MediaTrackDescriptor &track_;
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
    const MediaTrackDescriptor *track = previewableVideoTrack(binding);
    if (!context || !track ||
        !context->matchesPreviewBinding(binding.localPath, binding.descriptor))
      return {};
    return std::make_unique<Preview>(std::move(context), *track);
  } catch (...) {
    return {};
  }
}
} // namespace wam::macos
