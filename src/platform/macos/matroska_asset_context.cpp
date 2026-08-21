#include "platform/macos/matroska_asset_context.hpp"

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
  // Neither selection is individually mandatory, but at least one must exist:
  // an audio-less Matroska plays on the silent timebase and a video-less one
  // (MKA, audio-only MKV/WebM) plays on the audio clock. A context that names
  // no lane at all could not produce a single sample. The descriptor validator
  // already rejects a selection that names a track of the wrong kind or no
  // track at all.
  return descriptor != nullptr &&
         (descriptor->selectedVideo.has_value() ||
          descriptor->selectedAudio.has_value()) &&
         media::validateMediaSourceDescriptor(*descriptor, limits, nullptr);
}

}  // namespace

struct MatroskaAssetContext::Impl final {
  explicit Impl(
      std::shared_ptr<const media::matroska::MatroskaPreparedAsset>
          suppliedAsset) noexcept
      : asset(std::move(suppliedAsset)) {}

  std::shared_ptr<const media::matroska::MatroskaPreparedAsset> asset;
  std::atomic<std::uint64_t> cursorCreationAttempts{0};
  std::atomic<std::uint64_t> cursorsStarted{0};
};

MatroskaAssetContext::MatroskaAssetContext(
    std::filesystem::path path,
    const media::MediaSourceOpenOptions& options,
    std::shared_ptr<const media::MediaSourceDescriptor> descriptor,
    std::unique_ptr<Impl> impl) noexcept
    : MediaSourcePreparedContext(media::MediaSourceBackendKind::Matroska,
                                 std::move(path), options,
                                 std::move(descriptor)),
      impl_(std::move(impl)) {}

MatroskaAssetContext::~MatroskaAssetContext() = default;

MatroskaAssetContextFacts MatroskaAssetContext::facts() const noexcept {
  if (impl_ == nullptr) {
    return {};
  }
  return MatroskaAssetContextFacts{
      impl_->cursorCreationAttempts.load(std::memory_order_relaxed),
      impl_->cursorsStarted.load(std::memory_order_relaxed)};
}

const std::shared_ptr<const media::matroska::MatroskaPreparedAsset>&
MatroskaAssetContext::asset() const noexcept {
  // impl_ is never null for a context produced by the only factory below, so
  // returning the stored reference keeps the borrow allocation-free.
  return impl_->asset;
}

std::shared_ptr<const MatroskaAssetContext> adoptPreparedMatroskaAssetContext(
    std::filesystem::path path,
    const media::MediaSourceOpenOptions& options,
    std::shared_ptr<const media::matroska::MatroskaPreparedAsset>
        asset) noexcept {
  try {
    const media::MediaSourceLimits effective =
        media::clampMediaSourceLimits(options.limits);
    if (path.empty() || asset == nullptr) {
      return {};
    }
    // The descriptor instance is the asset's own. Copying it here would defeat
    // the entire point of the context: seeks and preview bindings prove they
    // retained the admitted backend state by comparing descriptor pointers.
    const std::shared_ptr<const media::MediaSourceDescriptor> descriptor =
        asset->descriptor();
    if (!validPreparedDescriptor(descriptor, effective)) {
      return {};
    }
    // The path the caller admitted and the path the asset actually holds open
    // are one fact stated twice. A mismatch means admission and payload reads
    // would target different files, so fail the adoption closed.
    if (asset->path() != path) {
      return {};
    }
    auto impl = std::make_unique<MatroskaAssetContext::Impl>(std::move(asset));
    return std::shared_ptr<const MatroskaAssetContext>(
        new MatroskaAssetContext(std::move(path), options, descriptor,
                                 std::move(impl)));
  } catch (...) {
    return {};
  }
}

void noteMatroskaAssetContextCursorCreationAttempt(
    const MatroskaAssetContext& context) noexcept {
  if (context.impl_ != nullptr) {
    saturatingIncrement(context.impl_->cursorCreationAttempts);
  }
}

void noteMatroskaAssetContextCursorStarted(
    const MatroskaAssetContext& context) noexcept {
  if (context.impl_ != nullptr) {
    saturatingIncrement(context.impl_->cursorsStarted);
  }
}

}  // namespace wam::macos
