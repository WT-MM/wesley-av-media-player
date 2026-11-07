#include "avfoundation_asset_context.hpp"
#include "platform/macos/native_primitives.hpp"

#import <AVFoundation/AVFoundation.h>

#include <algorithm>
#include <atomic>
#include <limits>
#include <utility>

namespace wam::macos {
namespace {

[[nodiscard]] bool validPreparedDescriptor(
    const std::shared_ptr<const media::MediaSourceDescriptor>& descriptor,
    const media::MediaSourceLimits& limits) noexcept {
  // Neither selection is individually mandatory, but at least one must exist:
  // an audio-less asset is admitted with selectedAudio unset and a video-less
  // one (a standalone music file) with selectedVideo unset. The descriptor
  // validator already rejects a selection that names a track of the wrong kind
  // or no track at all.
  return descriptor != nullptr &&
         (descriptor->selectedVideo.has_value() ||
          descriptor->selectedAudio.has_value()) &&
         media::validateMediaSourceDescriptor(*descriptor, limits, nullptr);
}

}  // namespace

struct AVFoundationAssetContext::Impl final {
  Impl(AVURLAsset* suppliedAsset, AVAssetTrack* suppliedVideoTrack,
       AVAssetTrack* suppliedAudioTrack,
       AVFoundationAssetContextMetadataLoadFacts suppliedMetadataLoads,
       std::shared_ptr<void> suppliedTestingLifetime) noexcept
      : asset(suppliedAsset),
        videoTrack(suppliedVideoTrack),
        audioTrack(suppliedAudioTrack),
        metadataLoads(suppliedMetadataLoads),
        testingLifetime(std::move(suppliedTestingLifetime)) {}

  __strong AVURLAsset* asset{nil};
  __strong AVAssetTrack* videoTrack{nil};
  __strong AVAssetTrack* audioTrack{nil};
  AVFoundationAssetContextMetadataLoadFacts metadataLoads;
  std::shared_ptr<void> testingLifetime;
  std::shared_ptr<const media::AacPacketTimeline> aacTimeline;
  std::optional<media::codec::Mp3LameGapless> mp3Gapless;
  std::atomic<std::uint64_t> readerCreationAttempts{0};
  std::atomic<std::uint64_t> readersStarted{0};
};

AVFoundationAssetContext::AVFoundationAssetContext(
    std::filesystem::path path,
    const media::MediaSourceOpenOptions& options,
    std::shared_ptr<const media::MediaSourceDescriptor> descriptor,
    std::unique_ptr<Impl> impl) noexcept
    : MediaSourcePreparedContext(media::MediaSourceBackendKind::AVFoundation,
                                 std::move(path), options,
                                 std::move(descriptor)),
      impl_(std::move(impl)) {}

AVFoundationAssetContext::~AVFoundationAssetContext() = default;

AVFoundationAssetContextFacts
AVFoundationAssetContext::facts() const noexcept {
  return AVFoundationAssetContextFacts{
      impl_->metadataLoads.assetMetadataLoadBatches,
      impl_->metadataLoads.selectedTrackMetadataLoadBatches,
      impl_->readerCreationAttempts.load(std::memory_order_relaxed),
      impl_->readersStarted.load(std::memory_order_relaxed)};
}

void noteAVFoundationAssetContextMetadataLoadBatch(
    AVFoundationAssetContextMetadataLoadFacts& facts,
    AVFoundationAssetContextMetadataLoadBatch batch) noexcept {
  std::uint64_t& value =
      batch == AVFoundationAssetContextMetadataLoadBatch::Asset
          ? facts.assetMetadataLoadBatches
          : facts.selectedTrackMetadataLoadBatches;
  if (value != std::numeric_limits<std::uint64_t>::max()) {
    ++value;
  }
}

std::shared_ptr<const AVFoundationAssetContext>
adoptPreparedAVFoundationAssetContext(
    std::filesystem::path path,
    const media::MediaSourceOpenOptions& options,
    std::shared_ptr<const media::MediaSourceDescriptor> descriptor,
    AVFoundationAssetContextNativeHandles handles,
    AVFoundationAssetContextMetadataLoadFacts metadataLoads) noexcept {
  try {
    const media::MediaSourceLimits effective =
        media::clampMediaSourceLimits(options.limits);
    if (path.empty() || !handles.complete() ||
        metadataLoads.assetMetadataLoadBatches == 0 ||
        metadataLoads.selectedTrackMetadataLoadBatches == 0 ||
        !validPreparedDescriptor(descriptor, effective)) {
      return {};
    }
    // Each track borrow and the descriptor's matching selection are one fact
    // stated twice. handles.complete() requires neither track, so this is the
    // edge that keeps them agreeing: a lane the descriptor did not select must
    // arrive with a null handle, and a selected lane must arrive with the track
    // it selected. Either mismatch means the caller's admission and its borrows
    // came from different asset views, so fail the adoption closed rather than
    // publish a context that disagrees with its own immutable descriptor.
    if (descriptor->selectedAudio.has_value() !=
            (handles.selectedAudioTrack != nullptr) ||
        descriptor->selectedVideo.has_value() !=
            (handles.selectedVideoTrack != nullptr)) {
      return {};
    }
    AVURLAsset* asset = (__bridge AVURLAsset*)(
        const_cast<void*>(handles.asset));
    AVAssetTrack* videoTrack = (__bridge AVAssetTrack*)(
        const_cast<void*>(handles.selectedVideoTrack));
    AVAssetTrack* audioTrack = (__bridge AVAssetTrack*)(
        const_cast<void*>(handles.selectedAudioTrack));
    auto impl = std::make_unique<AVFoundationAssetContext::Impl>(
        asset, videoTrack, audioTrack, metadataLoads, nullptr);
    impl->aacTimeline = std::move(handles.aacTimeline);
    impl->mp3Gapless = handles.mp3Gapless;
    return std::shared_ptr<const AVFoundationAssetContext>(
        new AVFoundationAssetContext(std::move(path), options,
                                     std::move(descriptor), std::move(impl)));
  } catch (...) {
    return {};
  }
}

AVFoundationAssetContextNativeHandles
borrowAVFoundationAssetContextNativeHandles(
    const AVFoundationAssetContext& context) noexcept {
  if (context.impl_ == nullptr) {
    return {};
  }
  return AVFoundationAssetContextNativeHandles{
      (__bridge const void*)context.impl_->asset,
      (__bridge const void*)context.impl_->videoTrack,
      (__bridge const void*)context.impl_->audioTrack, context.impl_->aacTimeline,
      context.impl_->mp3Gapless};
}

void noteAVFoundationAssetContextReaderCreationAttempt(
    const AVFoundationAssetContext& context) noexcept {
  if (context.impl_ != nullptr) {
    saturatingIncrement(context.impl_->readerCreationAttempts);
  }
}

void noteAVFoundationAssetContextReaderStarted(
    const AVFoundationAssetContext& context) noexcept {
  if (context.impl_ != nullptr) {
    saturatingIncrement(context.impl_->readersStarted);
  }
}

#if defined(WAM_NATIVE_TEST_SEAMS)
std::shared_ptr<const AVFoundationAssetContext>
adoptPreparedAVFoundationAssetContext(
    std::filesystem::path path,
    const media::MediaSourceOpenOptions& options,
    std::shared_ptr<const media::MediaSourceDescriptor> descriptor,
    AVFoundationAssetContextNativeHandles handles) noexcept {
  return adoptPreparedAVFoundationAssetContext(
      std::move(path), options, std::move(descriptor), handles,
      AVFoundationAssetContextMetadataLoadFacts{1, 1});
}

std::shared_ptr<const AVFoundationAssetContext>
makeAVFoundationAssetContextForTesting(
    std::filesystem::path path,
    const media::MediaSourceOpenOptions& options,
    std::shared_ptr<const media::MediaSourceDescriptor> descriptor,
    std::shared_ptr<void> lifetime) noexcept {
  try {
    const media::MediaSourceLimits effective =
        media::clampMediaSourceLimits(options.limits);
    if (path.empty() || !validPreparedDescriptor(descriptor, effective)) {
      return {};
    }
    auto impl = std::make_unique<AVFoundationAssetContext::Impl>(
        nil, nil, nil,
        AVFoundationAssetContextMetadataLoadFacts{1, 1},
        std::move(lifetime));
    return std::shared_ptr<const AVFoundationAssetContext>(
        new AVFoundationAssetContext(std::move(path), options,
                                     std::move(descriptor), std::move(impl)));
  } catch (...) {
    return {};
  }
}
#endif

}  // namespace wam::macos
