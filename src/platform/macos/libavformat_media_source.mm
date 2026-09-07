#include "platform/macos/libavformat_media_source.hpp"
#include "media/libavformat_cursor.hpp"
#include "media/matroska_opus.hpp"
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
  std::array<std::shared_ptr<Storage>, 32> pool{};
  CMFormatDescriptionRef format{};
  ~PacketReader() {
    if (format)
      CFRelease(format);
  }
  bool initialize(const MediaTrackDescriptor &track, std::string &error) {
    format = track.audio ? createAudioFormatDescription(track)
                         : createMatroskaVideoFormatDescription(track);
    if (!format) {
      error = "LibavformatVideoFormatDescription";
      return false;
    }
    for (auto &slot : pool)
      slot = std::make_shared<Storage>();
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
            ? CMSampleBufferCreateReady(kCFAllocatorDefault, block, format, 1,
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
  MediaTime target{}, decodeStart{};
  bool eos{}, opened{};
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
  bool start(MediaTime requested, MediaSeekMode mode, std::string &error) {
    target = requested;
    eos = false;
    head.reset();
    decodeStart = preceding(*context, target);
    if (mode == MediaSeekMode::KeyFrame)
      target = decodeStart;
    if (!reader->cursor.seek(context->selectedStream, decodeStart, error))
      return false;
    LibavformatCursor::Packet packet;
    for (unsigned skipped = 0; skipped < 4096; ++skipped) {
      const auto rc = reader->cursor.read(packet, error);
      if (rc != LibavformatCursor::Read::Packet) {
        if (error.empty())
          error = "LibavformatNoSeekHead";
        return false;
      }
      if (packet.stream != context->selectedStream)
        continue;
      if (context->audioOnly
              ? compareMediaTime(packet.pts, context->audioOrigin) !=
                    MediaTimeOrder::Equal
              : (!packet.key || compareMediaTime(packet.pts, decodeStart) !=
                                    MediaTimeOrder::Equal)) {
        error = "LibavformatSeekDidNotReachPrecedingRap";
        return false;
      }
      MediaSample sample;
      if (!reader->materialize(packet, generation, target,
                               context->descriptor()->tracks.front(), sample,
                               error))
        return false;
      peak = std::max(peak, sample.payload.byteSize());
      head = std::move(sample);
      return true;
    }
    error = "LibavformatInterleaveLimit";
    return false;
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
  s.head.reset();
  s.reader = std::make_unique<PacketReader>();
  s.context.reset();
  s.opened = false;
  out.status = MediaSourceOpenStatus::Unsupported;
  auto fail = [&]() {
    if (s.isCancelled())
      out.status = MediaSourceOpenStatus::Cancelled;
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
  if (video && audio) {
    out.error = "LibavformatAudioTimingUnproven: ";
    out.error += s.reader->cursor.codecName(*audio);
    return fail();
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
  if (audioOnly) {
    const auto opus = matroska::parseOpusIdentificationHeader(stream.extradata);
    if (stream.codecId != AV_CODEC_ID_OPUS || !opus.admitted() ||
        stream.rate != 48000 ||
        stream.channels != opus.configuration->channelCount) {
      out.error = "LibavformatAudioTimingUnproven: ";
      out.error += s.reader->cursor.codecName(*video);
      return fail();
    }
    track.kind = MediaTrackKind::Audio;
    track.codec = MediaCodec::Opus;
    track.timeBase = {1, 48000};
    track.codecConfigurationKind =
        MediaCodecConfigurationKind::AudioMagicCookie;
    track.codecConfiguration.assign(stream.extradata.begin(),
                                    stream.extradata.end());
    MediaAudioFormat format;
    format.sampleRate = 48000;
    format.channels = stream.channels;
    format.formatTag = kAudioFormatOpus;
    format.channelLayoutPresent = true;
    format.channelLayoutTag = stream.channels == 1
                                  ? kAudioChannelLayoutTag_Mono
                                  : kAudioChannelLayoutTag_Stereo;
    track.audio = format;
    descriptor->selectedAudio = track.id;
  } else if (!videoDescriptor(stream, options.limits, track, out.error)) {
    out.error += ": ";
    out.error += s.reader->cursor.codecName(*video);
    return fail();
  }
  if (!audioOnly)
    descriptor->selectedVideo = track.id;
  auto context = std::make_shared<Context>(path, options, descriptor);
  context->selectedStream = *video;
  context->identity = s.reader->cursor.identity();
  context->audioOnly = audioOnly;
  if (audioOnly) {
    context->raps.push_back({0, 1});
    context->audioOrigin = {
        -matroska::parseOpusIdentificationHeader(stream.extradata)
             .configuration->preSkipFrames,
        48000};
  }
  LibavformatCursor::Packet packet;
  MediaTime end{0, 1};
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
    if (packet.stream != *video)
      continue;
    if (!packet.pts.valid() || (!audioOnly && packet.pts.value < 0) ||
        !packet.duration.valid() || packet.duration.value <= 0 ||
        packet.corrupt) {
      out.error = "LibavformatExactVideoTimelineUnavailable";
      return fail();
    }
    if (packet.bytes.size() > (audioOnly
                                   ? options.limits.maximumAudioSampleBytes
                                   : options.limits.maximumVideoSampleBytes)) {
      out.error = "LibavformatSampleLimit";
      return fail();
    }
    if (audioOnly) {
      const auto frames = matroska::opusPacketFrameCount(packet.bytes);
      if (!frames || !exactAudioFrameIndex(packet.pts, 48000) ||
          !exactAudioFrameIndex(packet.duration, 48000) || audioTail) {
        out.error = "LibavformatOpusPacketGrid";
        return fail();
      }
      if (!audioPackets)
        track.audio->framesPerPacket = *frames;
      const auto expected =
          context->audioOrigin.value + static_cast<std::int64_t>(audioPackets) *
                                           track.audio->framesPerPacket;
      const auto declared = *exactAudioFrameIndex(packet.duration, 48000);
      if (*frames != track.audio->framesPerPacket ||
          *exactAudioFrameIndex(packet.pts, 48000) != expected ||
          declared > *frames ||
          (packet.skipStart &&
           (audioPackets ||
            packet.skipStart != std::uint64_t(-context->audioOrigin.value))) ||
          (packet.skipEnd && declared + packet.skipEnd != *frames)) {
        out.error = "LibavformatOpusPacketGrid";
        return fail();
      }
      audioTail = declared < *frames;
      ++audioPackets;
    }
    const auto packetEnd = checkedExactTimeSum(packet.pts, packet.duration);
    if (!packetEnd) {
      out.error = "LibavformatVideoTimelineUnrepresentable";
      return fail();
    }
    if (compareMediaTime(*packetEnd, end) == MediaTimeOrder::Greater)
      end = *packetEnd;
    if (packet.key && !audioOnly) {
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
  if (context->raps.empty() || context->raps.front().value != 0) {
    out.error = "LibavformatStreamOriginRapMissing";
    return fail();
  }
  descriptor->duration = track.duration = end;
  descriptor->tracks.push_back(std::move(track));
  if (!validateMediaSourceDescriptor(*descriptor, options.limits, &out.error) ||
      !s.reader->initialize(descriptor->tracks.front(), out.error))
    return fail();
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
  out.actualDecodeStart = s.decodeStart;
  out.descriptor = descriptor;
  out.preparedContext = context;
  if (audioOnly)
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
    s.reader.reset();
    s.context.reset();
    s.opened = false;
    s.operation.store(0, std::memory_order_release);
    return out;
  }
  ++s.seeks;
  out.accepted = true;
  out.actualDecodeStart = s.decodeStart;
  out.preparedContext = s.context;
  if (s.context->audioOnly)
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
  if (s.eos)
    return MediaSourceExhausted{expected};
  LibavformatCursor::Packet packet;
  std::string error;
  for (unsigned skipped = 0; skipped < 4096; ++skipped) {
    const auto rc = s.reader->cursor.read(packet, error);
    if (rc == LibavformatCursor::Read::End) {
      s.eos = true;
      return MediaEndOfStream{expected,
                              s.context->descriptor()->tracks.front().id};
    }
    if (rc == LibavformatCursor::Read::Cancelled)
      return MediaSourceCancelled{expected};
    if (rc != LibavformatCursor::Read::Packet)
      return MediaSourceFailure{expected, std::move(error)};
    if (packet.stream != s.context->selectedStream)
      continue;
    MediaSample sample;
    if (!s.reader->materialize(packet, expected, s.target,
                               s.context->descriptor()->tracks.front(), sample,
                               error))
      return MediaSourceFailure{expected, std::move(error)};
    ++s.emitted;
    return sample;
  }
  return MediaSourceFailure{expected, "LibavformatInterleaveLimit"};
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
  out.stagedGeneration = s.head ? s.generation : 0;
  out.stagedVideoHeads =
      s.head && s.head->kind == MediaSampleKind::EncodedVideo ? 1 : 0;
  out.stagedAudioHeads =
      s.head && s.head->kind == MediaSampleKind::EncodedAudio ? 1 : 0;
  out.stagedPayloadBytes = s.head ? s.head->payload.byteSize() : 0;
  out.peakStagedPayloadBytes = s.peak;
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
