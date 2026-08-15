#include "avfoundation_asset_context.hpp"

#import <AVFoundation/AVFoundation.h>

#include <algorithm>
#include <atomic>
#include <limits>
#include <utility>

namespace wam::macos {
namespace {

void saturatingIncrement(std::atomic<std::uint64_t>& value) noexcept {
  std::uint64_t observed = value.load(std::memory_order_relaxed);
  while (observed != std::numeric_limits<std::uint64_t>::max() &&
         !value.compare_exchange_weak(observed, observed + 1,
                                      std::memory_order_relaxed,
                                      std::memory_order_relaxed)) {
  }
}

[[nodiscard]] bool validPreparedDescriptor(
    const std::shared_ptr<const media::MediaSourceDescriptor>& descriptor,
    const media::MediaSourceLimits& limits) noexcept {
  return descriptor != nullptr && descriptor->selectedVideo.has_value() &&
         descriptor->selectedAudio.has_value() &&
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
    AVURLAsset* asset = (__bridge AVURLAsset*)(
        const_cast<void*>(handles.asset));
    AVAssetTrack* videoTrack = (__bridge AVAssetTrack*)(
        const_cast<void*>(handles.selectedVideoTrack));
    AVAssetTrack* audioTrack = (__bridge AVAssetTrack*)(
        const_cast<void*>(handles.selectedAudioTrack));
    auto impl = std::make_unique<AVFoundationAssetContext::Impl>(
        asset, videoTrack, audioTrack, metadataLoads, nullptr);
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
      (__bridge const void*)context.impl_->audioTrack};
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

#if defined(WAM_AVFOUNDATION_ASSET_CONTEXT_TESTING) || \
    defined(WAM_AVFOUNDATION_MEDIA_SOURCE_TESTING) || \
    defined(WAM_AVFOUNDATION_PREVIEW_SOURCE_TESTING)
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
