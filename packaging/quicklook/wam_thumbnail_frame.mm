// Implementation of the thumbnail frame extractor declared in
// wam_thumbnail_frame.hpp. See that header for the contract and
// packaging/quicklook/README.md for the evidence behind each choice.
//
// HARD CONSTRAINT: Qt-free, and no non-system dynamic library. It links
// wam_native_core (which declares no link dependencies of its own) and
// compiles the two Qt-free sample builders plus the VideoToolbox capability
// probe directly. It deliberately does NOT link wam_macos_native_video_core:
// that archive carries software_vp8_decoder and therefore a Homebrew libvpx
// edge, and nothing in the bundle-repair walk rewrites install names for a
// nested appex.
//
// Decode is deliberately NOT routed through wam::macos::VideoToolboxDecoder.
// That class is an owner-driven, generation-scoped, sink-backed streaming
// state machine (reorder depth, in-flight credit, drain/retire lifecycle)
// built for continuous playback. A thumbnail needs exactly one frame with no
// ordering obligations, so this file drives a bare VTDecompressionSession:
// fewer moving parts, no surface budget, no libvpx, and a hard bound that is
// trivially auditable.

#include "wam_thumbnail_frame.hpp"

#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>
#include <variant>
#include <vector>

#include "media/matroska_demuxer.hpp"
#include "media/mpegts_demuxer.hpp"
#include "media/native_media_source.hpp"
#include "platform/macos/matroska_sample_builder.hpp"
#include "platform/macos/mpegts_sample_builder.hpp"
#include "platform/macos/software_vp8_decoder.hpp"

// matroska_sample_builder.mm gates its VP8 branch on a RUNTIME call rather than
// on WAM_ENABLE_SOFTWARE_VP8, so the symbol is referenced whatever the build
// flags say. This appex links no software VP8 decoder at all -- pulling in
// software_vp8_decoder.mm drags FrameLease and the whole presenter closure,
// and enabling it drags Homebrew libvpx, which is the one dependency that
// would break the bundle's self-containment audit (nothing rewrites install
// names for a nested appex).
//
// Answering `false` is exactly what the production translation unit answers
// when WAM_ENABLE_SOFTWARE_VP8 is undefined, so this is that configuration and
// not a divergent stub. The observable result is that VP8-in-WebM gets no
// format description, the provider replies with an error, and Finder keeps its
// generic icon -- the same graceful path every other unsupported input takes.
namespace wam::macos {
bool SoftwareVp8Decoder::available() noexcept { return false; }
}  // namespace wam::macos

namespace {

using wam::quicklook::ThumbnailFrame;
using wam::media::MediaCodec;
using wam::media::MediaSeekMode;
using wam::media::MediaSourceOpenOptions;
using wam::media::MediaTime;
using wam::media::MediaTrackDescriptor;
using wam::media::MediaTrackKind;

// Hard ceiling for the whole request. Finder shows the generic icon until we
// reply, so a slow provider reads as a broken one. No kill was observed at a
// 40 s stall on the QLThumbnailGenerator path, but that is the API's patience,
// not the user's. Every demuxer entry point takes the cancellation token this
// deadline backs, so the bound is enforced inside the read loops and not only
// between them.
constexpr std::chrono::milliseconds kThumbnailBudget{3000};

// Additional wall-clock bound on the single VideoToolbox decode, inside the
// budget above. VTDecompressionSessionWaitForAsynchronousFrames has no timeout
// parameter, so the ceiling is expressed by refusing to start a decode that
// cannot finish inside the remaining budget.
constexpr std::chrono::milliseconds kMinimumDecodeHeadroom{250};

// Never render frame 0: the first frame of a real encode is very often black or
// a fade-in. Aim 10 % in, which lands past titles on a short clip and stays
// inside the opening scene on a feature.
constexpr std::int64_t kTargetNumerator = 1;
constexpr std::int64_t kTargetDenominator = 10;

// Absolute cap on how far in to seek. Ten percent of a three-hour film is
// eighteen minutes; a Cue lookup there is no more expensive, but a file whose
// Cues are absent degrades to a scan, and a scan that far in is the one case
// that can blow the budget.
constexpr std::int64_t kMaximumTargetSeconds = 120;

// Pixel ceiling. A thumbnail is at most a few hundred points on a side, so
// nothing above 4K DCI is worth decoding; an 8K frame is ~130 MB of BGRA in an
// extension the system may run several of at once. Oversized inputs fail
// closed to the generic icon rather than allocating.
constexpr std::int32_t kMaximumCodedDimension = 4096;

using SteadyClock = std::chrono::steady_clock;

// Cancellation token backed by a wall-clock deadline. wam::media's token is a
// plain {context, probe} pair, so this needs no allocation and no atomics: the
// demuxer probes it on the same thread that owns the deadline.
struct Deadline {
  SteadyClock::time_point expiry{};

  [[nodiscard]] bool expired() const noexcept {
    return SteadyClock::now() >= expiry;
  }
  [[nodiscard]] std::chrono::milliseconds remaining() const noexcept {
    const auto left = expiry - SteadyClock::now();
    if (left <= SteadyClock::duration::zero()) {
      return std::chrono::milliseconds{0};
    }
    return std::chrono::duration_cast<std::chrono::milliseconds>(left);
  }
};

bool DeadlineProbe(const void* context) noexcept {
  return static_cast<const Deadline*>(context)->expired();
}

wam::media::matroska::CancellationToken MatroskaToken(
    const Deadline& deadline) noexcept {
  return {&deadline, &DeadlineProbe};
}

wam::media::mpegts::CancellationToken MpegTsToken(
    const Deadline& deadline) noexcept {
  return {&deadline, &DeadlineProbe};
}

// Ten percent into `duration`, capped by kMaximumTargetSeconds and clamped
// back toward zero for clips too short to have a tenth worth seeking to.
// Returns a MediaTime on `duration`'s own timescale so no rational is rounded
// through double.
MediaTime PreferredTarget(MediaTime duration) noexcept {
  if (!duration.valid() || duration.value <= 0) {
    return MediaTime{0, 1};
  }
  std::int64_t ticks = duration.value / kTargetDenominator * kTargetNumerator;
  const std::int64_t cap =
      kMaximumTargetSeconds * static_cast<std::int64_t>(duration.timescale);
  ticks = std::min(ticks, cap);
  // Never land at or past the end: a plan targeting EOF has no sample to read.
  ticks = std::min(ticks, duration.value > 0 ? duration.value - 1 : 0);
  if (ticks < 0) {
    ticks = 0;
  }
  return MediaTime{ticks, duration.timescale};
}

// Selected video track, or nullptr. Both demuxers publish the same descriptor
// shape, so one helper serves both.
const MediaTrackDescriptor* SelectedVideoTrack(
    const wam::media::MediaSourceDescriptor& descriptor) noexcept {
  if (descriptor.selectedVideo.has_value()) {
    for (const auto& track : descriptor.tracks) {
      if (track.id == *descriptor.selectedVideo) {
        return &track;
      }
    }
  }
  for (const auto& track : descriptor.tracks) {
    if (track.kind == MediaTrackKind::Video) {
      return &track;
    }
  }
  return nullptr;
}

bool AdmitsDimensions(const MediaTrackDescriptor& track,
                      std::string* error) noexcept {
  if (!track.video.has_value()) {
    if (error) *error = "video track carries no video format";
    return false;
  }
  const auto& format = *track.video;
  if (format.codedWidth == 0 || format.codedHeight == 0) {
    if (error) *error = "video track has no coded dimensions";
    return false;
  }
  if (format.codedWidth > static_cast<std::uint32_t>(kMaximumCodedDimension) ||
      format.codedHeight > static_cast<std::uint32_t>(kMaximumCodedDimension)) {
    if (error) *error = "frame exceeds the 4K thumbnail ceiling";
    return false;
  }
  return true;
}

// Display size after pixel aspect, used only to letter/pillar-box the draw.
CGSize DisplaySize(const MediaTrackDescriptor& track) noexcept {
  const auto& format = *track.video;
  double w = static_cast<double>(format.codedWidth);
  double h = static_cast<double>(format.codedHeight);
  if (format.displayWidth > 0 && format.displayHeight > 0) {
    w = static_cast<double>(format.displayWidth);
    h = static_cast<double>(format.displayHeight);
  } else if (format.pixelAspectNumerator > 0 &&
             format.pixelAspectDenominator > 0) {
    w = w * static_cast<double>(format.pixelAspectNumerator) /
        static_cast<double>(format.pixelAspectDenominator);
  }
  if (format.rotationDegrees == 90 || format.rotationDegrees == 270 ||
      format.rotationDegrees == -90) {
    std::swap(w, h);
  }
  return CGSizeMake(static_cast<CGFloat>(w), static_cast<CGFloat>(h));
}

struct DecodeSink {
  CVPixelBufferRef pixels{nullptr};
  OSStatus status{noErr};
};

void DecodeOutputCallback(void* decompressionOutputRefCon,
                          void* /*sourceFrameRefCon*/, OSStatus status,
                          VTDecodeInfoFlags /*infoFlags*/,
                          CVImageBufferRef imageBuffer,
                          CMTime /*presentationTimeStamp*/,
                          CMTime /*presentationDuration*/) {
  auto* sink = static_cast<DecodeSink*>(decompressionOutputRefCon);
  if (sink == nullptr) {
    return;
  }
  if (status != noErr) {
    sink->status = status;
    return;
  }
  if (imageBuffer == nullptr || sink->pixels != nullptr) {
    // Only the first frame is wanted; a session fed one access unit should not
    // produce a second, but dropping extras costs nothing and keeps ownership
    // singular.
    return;
  }
  sink->pixels = CVPixelBufferRetain(imageBuffer);
}

// Decodes exactly one compressed access unit into a retained CGImage.
//
// The output pixel format is pinned to 32BGRA. VideoToolbox will interpose a
// pixel transfer for that pin -- which is precisely the per-frame cost
// video_toolbox_decoder.hpp documents and avoids for playback -- but here it
// runs once, and it guarantees a CPU-readable surface rather than an AGX
// lossless-compressed one that CGImage cannot be built from.
CGImageRef DecodeOneAccessUnit(CMSampleBufferRef sample,
                               CMVideoFormatDescriptionRef format,
                               const Deadline& deadline, std::string* error) {
  if (deadline.remaining() < kMinimumDecodeHeadroom) {
    if (error) *error = "budget exhausted before decode";
    return nullptr;
  }

  const CMVideoDimensions dimensions =
      CMVideoFormatDescriptionGetDimensions(format);
  if (dimensions.width <= 0 || dimensions.height <= 0 ||
      dimensions.width > kMaximumCodedDimension ||
      dimensions.height > kMaximumCodedDimension) {
    if (error) *error = "format dimensions outside the thumbnail ceiling";
    return nullptr;
  }

  NSDictionary* destinationAttributes = @{
    (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey :
        @(kCVPixelFormatType_32BGRA),
    (__bridge NSString*)kCVPixelBufferWidthKey : @(dimensions.width),
    (__bridge NSString*)kCVPixelBufferHeightKey : @(dimensions.height),
    (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };

  DecodeSink sink{};
  VTDecompressionOutputCallbackRecord callback{};
  callback.decompressionOutputCallback = &DecodeOutputCallback;
  callback.decompressionOutputRefCon = &sink;

  VTDecompressionSessionRef session = nullptr;
  OSStatus status = VTDecompressionSessionCreate(
      kCFAllocatorDefault, format, /*videoDecoderSpecification=*/nullptr,
      (__bridge CFDictionaryRef)destinationAttributes, &callback, &session);
  if (status != noErr || session == nullptr) {
    if (error) {
      *error = "VTDecompressionSessionCreate failed (" +
               std::to_string(static_cast<long>(status)) + ")";
    }
    return nullptr;
  }

  VTDecodeInfoFlags infoFlags = 0;
  // No temporal processing and no async reordering: one keyframe, one output.
  status = VTDecompressionSessionDecodeFrame(
      session, sample, kVTDecodeFrame_EnableAsynchronousDecompression,
      /*sourceFrameRefCon=*/nullptr, &infoFlags);
  if (status == noErr) {
    status = VTDecompressionSessionWaitForAsynchronousFrames(session);
  }
  VTDecompressionSessionInvalidate(session);
  CFRelease(session);

  if (status != noErr) {
    CVPixelBufferRelease(sink.pixels);
    if (error) {
      *error = "VideoToolbox decode failed (" +
               std::to_string(static_cast<long>(status)) + ")";
    }
    return nullptr;
  }
  if (sink.status != noErr) {
    CVPixelBufferRelease(sink.pixels);
    if (error) {
      *error = "VideoToolbox emitted an error (" +
               std::to_string(static_cast<long>(sink.status)) + ")";
    }
    return nullptr;
  }
  if (sink.pixels == nullptr) {
    if (error) *error = "decoder produced no frame";
    return nullptr;
  }

  CGImageRef image = nullptr;
  status = VTCreateCGImageFromCVPixelBuffer(sink.pixels, /*options=*/nullptr,
                                            &image);
  CVPixelBufferRelease(sink.pixels);
  if (status != noErr || image == nullptr) {
    if (error) {
      *error = "VTCreateCGImageFromCVPixelBuffer failed (" +
               std::to_string(static_cast<long>(status)) + ")";
    }
    return nullptr;
  }
  return image;
}

// ---------------------------------------------------------------------------
// Matroska
// ---------------------------------------------------------------------------

bool CopyMatroskaKeyframe(const std::filesystem::path& path,
                          const Deadline& deadline,
                          wam::quicklook::ThumbnailFrame* out,
                          std::string* error) {
  namespace mkv = wam::media::matroska;

  MediaSourceOpenOptions options{};
  options.selection.requireVideo = true;
  options.selection.requireAudio = false;

  const auto token = MatroskaToken(deadline);
  auto outcome = mkv::prepareMatroskaLocalFile(path, options, token);
  if (outcome.status != mkv::MatroskaDemuxStatus::Ready || !outcome.asset) {
    if (error) {
      *error = outcome.message.empty() ? "matroska prepare failed"
                                       : outcome.message;
    }
    return false;
  }
  const mkv::MatroskaPreparedAsset& asset = *outcome.asset;
  const auto& descriptor = asset.descriptor();
  if (!descriptor) {
    if (error) *error = "matroska prepare published no descriptor";
    return false;
  }

  const MediaTrackDescriptor* track = SelectedVideoTrack(*descriptor);
  if (track == nullptr) {
    if (error) *error = "no video track";
    return false;
  }
  if (!AdmitsDimensions(*track, error)) {
    return false;
  }

  auto planned = asset.planGeneration(PreferredTarget(descriptor->duration),
                                      MediaSeekMode::Accurate, token);
  if (!planned.plan.has_value()) {
    if (error) {
      *error = planned.message.empty() ? "no random access point"
                                       : planned.message;
    }
    return false;
  }

  auto cursor = asset.makeVideoCursor(*planned.plan);
  if (!cursor) {
    if (error) *error = "matroska video cursor unavailable";
    return false;
  }

  mkv::MatroskaCompressedSample keyframe{};
  bool found = false;
  // planGeneration lands on a random access point by construction, so the
  // first sample is normally the keyframe. Tolerate a couple of non-key
  // samples rather than trusting that unconditionally; never loop unbounded.
  for (int attempt = 0; attempt < 4 && !deadline.expired(); ++attempt) {
    auto read = cursor->readNext(token);
    if (auto* sample = std::get_if<mkv::MatroskaCompressedSample>(&read)) {
      if (sample->keyFrame) {
        keyframe = *sample;
        found = true;
        break;
      }
      continue;
    }
    break;
  }
  if (!found) {
    if (error) *error = "no keyframe at the planned position";
    return false;
  }

  CMVideoFormatDescriptionRef format =
      wam::macos::createMatroskaVideoFormatDescription(*track);
  if (format == nullptr) {
    if (error) *error = "unsupported video codec for CoreMedia";
    return false;
  }

  wam::macos::MatroskaSampleBuildInputs inputs{};
  inputs.asset = &asset;
  inputs.cancellation = token;
  inputs.format = format;
  inputs.video = true;

  wam::macos::MatroskaScopedSampleBuffer built;
  const auto build = wam::macos::buildMatroskaCompressedSampleBuffer(
      inputs, keyframe, &built, error);
  if (build != wam::macos::MatroskaSampleBuildStatus::Built ||
      built.get() == nullptr) {
    CFRelease(format);
    if (error && error->empty()) *error = "sample build failed";
    return false;
  }

  out->image = DecodeOneAccessUnit(built.get(), format, deadline, error);
  CFRelease(format);
  if (out->image == nullptr) {
    return false;
  }
  out->displaySize = DisplaySize(*track);
  return true;
}

// ---------------------------------------------------------------------------
// MPEG-2 Transport Stream
// ---------------------------------------------------------------------------

bool CopyMpegTsKeyframe(const std::filesystem::path& path,
                        const Deadline& deadline,
                          wam::quicklook::ThumbnailFrame* out,
                        std::string* error) {
  namespace ts = wam::media::mpegts;

  MediaSourceOpenOptions options{};
  options.selection.requireVideo = true;
  options.selection.requireAudio = false;

  const auto token = MpegTsToken(deadline);
  auto outcome = ts::prepareMpegTsLocalFile(path, options, token);
  if (outcome.status != ts::MpegTsDemuxStatus::Ready || !outcome.asset) {
    if (error) {
      *error = outcome.message.empty() ? "mpeg-ts prepare failed"
                                       : outcome.message;
    }
    return false;
  }
  const ts::MpegTsPreparedAsset& asset = *outcome.asset;
  const auto& descriptor = asset.descriptor();
  if (!descriptor) {
    if (error) *error = "mpeg-ts prepare published no descriptor";
    return false;
  }

  const MediaTrackDescriptor* track = SelectedVideoTrack(*descriptor);
  if (track == nullptr) {
    if (error) *error = "no video track";
    return false;
  }
  if (!AdmitsDimensions(*track, error)) {
    return false;
  }

  auto planned = asset.planGeneration(PreferredTarget(descriptor->duration),
                                      MediaSeekMode::Accurate, token);
  if (!planned.plan.has_value()) {
    if (error) {
      *error = planned.message.empty() ? "no random access point"
                                       : planned.message;
    }
    return false;
  }

  auto cursor = asset.makeVideoCursor(*planned.plan);
  if (!cursor) {
    if (error) *error = "mpeg-ts video cursor unavailable";
    return false;
  }

  ts::MpegTsCompressedSample keyframe{};
  bool found = false;
  // A transport stream's index is coarser than Matroska Cues, so allow a few
  // more access units before giving up -- still a fixed, small bound.
  for (int attempt = 0; attempt < 16 && !deadline.expired(); ++attempt) {
    auto read = cursor->readNext(token);
    if (auto* sample = std::get_if<ts::MpegTsCompressedSample>(&read)) {
      if (sample->keyFrame && sample->decodableFromCold) {
        keyframe = *sample;
        found = true;
        break;
      }
      continue;
    }
    break;
  }
  if (!found) {
    if (error) *error = "no cold-decodable keyframe at the planned position";
    return false;
  }

  CMVideoFormatDescriptionRef format =
      wam::macos::createMpegTsVideoFormatDescription(*track);
  if (format == nullptr) {
    if (error) *error = "unsupported video codec for CoreMedia";
    return false;
  }

  std::vector<std::byte> workspace;
  wam::macos::MpegTsSampleBuildInputs inputs{};
  inputs.asset = &asset;
  inputs.cancellation = token;
  inputs.format = format;
  inputs.codec = track->codec;
  inputs.video = true;
  inputs.workspace = &workspace;

  wam::macos::MpegTsScopedSampleBuffer built;
  const auto build = wam::macos::buildMpegTsCompressedSampleBuffer(
      inputs, keyframe, &built, error);
  if (build != wam::macos::MpegTsSampleBuildStatus::Built ||
      built.get() == nullptr) {
    CFRelease(format);
    if (error && error->empty()) *error = "sample build failed";
    return false;
  }

  out->image = DecodeOneAccessUnit(built.get(), format, deadline, error);
  CFRelease(format);
  if (out->image == nullptr) {
    return false;
  }
  out->displaySize = DisplaySize(*track);
  return true;
}

// ---------------------------------------------------------------------------

enum class Container { Matroska, MpegTs, Unknown };

Container ClassifyByExtension(const std::filesystem::path& path) noexcept {
  std::string extension = path.extension().string();
  std::transform(extension.begin(), extension.end(), extension.begin(),
                 [](unsigned char c) { return static_cast<char>(::tolower(c)); });
  if (extension == ".mkv" || extension == ".mk3d" || extension == ".webm") {
    return Container::Matroska;
  }
  if (extension == ".ts" || extension == ".m2ts" || extension == ".mts" ||
      extension == ".m2t" || extension == ".mpegts") {
    return Container::MpegTs;
  }
  return Container::Unknown;
}

}  // namespace

namespace wam::quicklook {

bool copyKeyframeImage(const std::filesystem::path& path, ThumbnailFrame* out,
                       std::string* error) {
  const Deadline deadline{SteadyClock::now() + kThumbnailBudget};

  switch (ClassifyByExtension(path)) {
    case Container::Matroska:
      return CopyMatroskaKeyframe(path, deadline, out, error);
    case Container::MpegTs:
      return CopyMpegTsKeyframe(path, deadline, out, error);
    case Container::Unknown:
      break;
  }
  // LaunchServices routed a UTI this provider claims but whose extension it
  // does not recognise. Try Matroska then transport stream rather than
  // guessing: both refuse a foreign container from its header alone.
  if (CopyMatroskaKeyframe(path, deadline, out, error)) {
    return true;
  }
  return CopyMpegTsKeyframe(path, deadline, out, error);
}

}  // namespace wam::quicklook

