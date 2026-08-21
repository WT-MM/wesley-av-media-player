#pragma once

#include "media/native_media_source.hpp"

#include <cstdint>
#include <filesystem>
#include <memory>

namespace wam::macos {

// Owner-confined cold-admission accounting. The source records a batch at the
// actual AVFoundation issuance edge, then transfers this snapshot into the
// immutable context only after descriptor admission succeeds.
enum class AVFoundationAssetContextMetadataLoadBatch : std::uint8_t {
  Asset,
  SelectedTracks,
};

struct AVFoundationAssetContextMetadataLoadFacts {
  std::uint64_t assetMetadataLoadBatches{0};
  std::uint64_t selectedTrackMetadataLoadBatches{0};
};

// Immutable, session-scoped identity and admitted AVFoundation asset state.
// The context owns no AVAssetReader and has no operation generation: every
// main seek and preview request creates and cancels its own reader while the
// prepared asset, selected tracks, and exact descriptor remain shared.
struct AVFoundationAssetContextFacts {
  std::uint64_t assetMetadataLoadBatches{0};
  std::uint64_t selectedTrackMetadataLoadBatches{0};
  std::uint64_t readerCreationAttempts{0};
  std::uint64_t readersStarted{0};
};

// Opaque Apple borrows are valid only while the caller retains the context.
// Keeping them opaque prevents Objective-C ownership qualifiers from changing
// this header's C++ layout between ordinary C++ and Objective-C++ consumers.
struct AVFoundationAssetContextNativeHandles {
  const void* asset{nullptr};
  const void* selectedVideoTrack{nullptr};
  const void* selectedAudioTrack{nullptr};

  // Native v1 admits audio-less assets (a GIF-to-MP4 conversion carries one
  // H.264 track and no audio) AND video-less ones (a standalone music file),
  // so either track handle may legitimately be null. Completeness therefore
  // states only what every admitted asset owns -- the asset itself and at
  // least one lane to read; both handles are cross-checked against the
  // descriptor's selections in adoptPreparedAVFoundationAssetContext, which is
  // the one place that knows which lanes this asset was admitted with.
  [[nodiscard]] bool complete() const noexcept {
    return asset != nullptr &&
           (selectedVideoTrack != nullptr || selectedAudioTrack != nullptr);
  }
};

class AVFoundationAssetContext final
    : public media::MediaSourcePreparedContext {
 public:
  ~AVFoundationAssetContext() override;

  AVFoundationAssetContext(const AVFoundationAssetContext&) = delete;
  AVFoundationAssetContext& operator=(const AVFoundationAssetContext&) =
      delete;

  [[nodiscard]] AVFoundationAssetContextFacts facts() const noexcept;

 private:
  struct Impl;
  AVFoundationAssetContext(
      std::filesystem::path path,
      const media::MediaSourceOpenOptions& options,
      std::shared_ptr<const media::MediaSourceDescriptor> descriptor,
      std::unique_ptr<Impl> impl) noexcept;
  std::unique_ptr<Impl> impl_;

  friend std::shared_ptr<const AVFoundationAssetContext>
  adoptPreparedAVFoundationAssetContext(
      std::filesystem::path path,
      const media::MediaSourceOpenOptions& options,
      std::shared_ptr<const media::MediaSourceDescriptor> descriptor,
      AVFoundationAssetContextNativeHandles handles,
      AVFoundationAssetContextMetadataLoadFacts metadataLoads) noexcept;
  friend AVFoundationAssetContextNativeHandles
  borrowAVFoundationAssetContextNativeHandles(
      const AVFoundationAssetContext& context) noexcept;
  friend void noteAVFoundationAssetContextReaderCreationAttempt(
      const AVFoundationAssetContext& context) noexcept;
  friend void noteAVFoundationAssetContextReaderStarted(
      const AVFoundationAssetContext& context) noexcept;
#if defined(WAM_AVFOUNDATION_ASSET_CONTEXT_TESTING) || \
    defined(WAM_AVFOUNDATION_MEDIA_SOURCE_TESTING) || \
    defined(WAM_AVFOUNDATION_PREVIEW_SOURCE_TESTING)
  friend std::shared_ptr<const AVFoundationAssetContext>
  makeAVFoundationAssetContextForTesting(
      std::filesystem::path path,
      const media::MediaSourceOpenOptions& options,
      std::shared_ptr<const media::MediaSourceDescriptor> descriptor,
      std::shared_ptr<void> lifetime) noexcept;
#endif
};

// Platform implementation boundary. Only the worker that has completed the
// bounded AVFoundation admission may adopt native handles into a context.
[[nodiscard]] std::shared_ptr<const AVFoundationAssetContext>
adoptPreparedAVFoundationAssetContext(
    std::filesystem::path path,
    const media::MediaSourceOpenOptions& options,
    std::shared_ptr<const media::MediaSourceDescriptor> descriptor,
    AVFoundationAssetContextNativeHandles handles,
    AVFoundationAssetContextMetadataLoadFacts metadataLoads) noexcept;
void noteAVFoundationAssetContextMetadataLoadBatch(
    AVFoundationAssetContextMetadataLoadFacts& facts,
    AVFoundationAssetContextMetadataLoadBatch batch) noexcept;
[[nodiscard]] AVFoundationAssetContextNativeHandles
borrowAVFoundationAssetContextNativeHandles(
    const AVFoundationAssetContext& context) noexcept;
void noteAVFoundationAssetContextReaderCreationAttempt(
    const AVFoundationAssetContext& context) noexcept;
void noteAVFoundationAssetContextReaderStarted(
    const AVFoundationAssetContext& context) noexcept;

#if defined(WAM_AVFOUNDATION_ASSET_CONTEXT_TESTING) || \
    defined(WAM_AVFOUNDATION_MEDIA_SOURCE_TESTING) || \
    defined(WAM_AVFOUNDATION_PREVIEW_SOURCE_TESTING)
// Test fixtures that inject already-prepared Apple handles explicitly model
// the one asset and one selected-track batch required for cold admission.
[[nodiscard]] std::shared_ptr<const AVFoundationAssetContext>
adoptPreparedAVFoundationAssetContext(
    std::filesystem::path path,
    const media::MediaSourceOpenOptions& options,
    std::shared_ptr<const media::MediaSourceDescriptor> descriptor,
    AVFoundationAssetContextNativeHandles handles) noexcept;
// Fixture-free context with no Apple borrows. Injected backends use it to
// validate identity, reuse, and destruction without opening a media file.
[[nodiscard]] std::shared_ptr<const AVFoundationAssetContext>
makeAVFoundationAssetContextForTesting(
    std::filesystem::path path,
    const media::MediaSourceOpenOptions& options,
    std::shared_ptr<const media::MediaSourceDescriptor> descriptor,
    std::shared_ptr<void> lifetime = {}) noexcept;
#endif

}  // namespace wam::macos
