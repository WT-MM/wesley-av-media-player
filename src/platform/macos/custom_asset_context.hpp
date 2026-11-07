#pragma once

#include "media/native_media_source.hpp"
#include "platform/macos/native_primitives.hpp"

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <utility>

namespace wam::macos {

// The AVFoundation context counts reader creations because one AVAssetReader
// is the unit of streaming state there. The equivalent unit for a custom
// demuxer is a cursor, so the same two facts are stated against cursors: one
// attempt per makeVideoCursor()/makeAudioCursor() call and one start per
// cursor that was actually produced.
struct CustomAssetContextFacts {
  std::uint64_t cursorCreationAttempts{0};
  std::uint64_t cursorsStarted{0};
};

// Immutable, session-scoped identity and admitted asset state for a custom
// demuxer (Matroska, MPEG-TS). The context owns no cursor and has no operation
// generation: every main seek and preview request plans and creates its own
// pair of cursors while the prepared asset, its index, and the exact
// descriptor instance remain shared. The containers differ only in which
// selection admission requires (kVideoRequired).
template <class PreparedAsset, media::MediaSourceBackendKind kBackend,
          bool kVideoRequired>
class CustomAssetContext final : public media::MediaSourcePreparedContext {
 public:
  CustomAssetContext(const CustomAssetContext&) = delete;
  CustomAssetContext& operator=(const CustomAssetContext&) = delete;

  [[nodiscard]] CustomAssetContextFacts facts() const noexcept {
    return {cursorCreationAttempts_.load(std::memory_order_relaxed),
            cursorsStarted_.load(std::memory_order_relaxed)};
  }

  // The prepared asset is const and internally re-verifies file identity at
  // every entry point, so planning, cursor creation, and payload reads remain
  // safe to issue repeatedly from the single source owner.
  [[nodiscard]] const std::shared_ptr<const PreparedAsset>& asset()
      const noexcept {
    return asset_;
  }

  // Platform implementation boundary. Only the worker that has completed the
  // bounded admission may adopt a prepared asset into a context. The context
  // republishes the asset's own descriptor instance rather than a copy,
  // because exact descriptor-pointer identity is what later seeks and preview
  // bindings prove themselves against.
  [[nodiscard]] static std::shared_ptr<const CustomAssetContext> adopt(
      std::filesystem::path path, const media::MediaSourceOpenOptions& options,
      std::shared_ptr<const PreparedAsset> asset) noexcept {
    try {
      const media::MediaSourceLimits effective =
          media::clampMediaSourceLimits(options.limits);
      if (path.empty() || asset == nullptr) {
        return {};
      }
      std::shared_ptr<const media::MediaSourceDescriptor> descriptor =
          asset->descriptor();
      if (!admitted(descriptor, effective)) {
        return {};
      }
      // The path the caller admitted and the path the asset actually holds
      // open are one fact stated twice. A mismatch means admission and payload
      // reads would target different files, so fail the adoption closed.
      if (asset->path() != path) {
        return {};
      }
      return std::shared_ptr<const CustomAssetContext>(new CustomAssetContext(
          std::move(path), options, std::move(descriptor), std::move(asset)));
    } catch (...) {
      return {};
    }
  }

  static void noteCursorCreationAttempt(
      const CustomAssetContext& context) noexcept {
    saturatingIncrement(context.cursorCreationAttempts_);
  }
  static void noteCursorStarted(const CustomAssetContext& context) noexcept {
    saturatingIncrement(context.cursorsStarted_);
  }

 private:
  CustomAssetContext(std::filesystem::path path,
                     const media::MediaSourceOpenOptions& options,
                     std::shared_ptr<const media::MediaSourceDescriptor>
                         descriptor,
                     std::shared_ptr<const PreparedAsset> asset) noexcept
      : MediaSourcePreparedContext(kBackend, std::move(path), options,
                                   std::move(descriptor)),
        asset_(std::move(asset)) {}

  // Video is mandatory where kVideoRequired; otherwise at least one lane must
  // be selected, since a context naming no lane could not produce a sample.
  // The descriptor validator already rejects a selection that names a track
  // of the wrong kind or no track at all.
  [[nodiscard]] static bool admitted(
      const std::shared_ptr<const media::MediaSourceDescriptor>& descriptor,
      const media::MediaSourceLimits& limits) noexcept {
    if (descriptor == nullptr) {
      return false;
    }
    const bool lanes = kVideoRequired ? descriptor->selectedVideo.has_value()
                                      : descriptor->selectedVideo.has_value() ||
                                            descriptor->selectedAudio.has_value();
    return lanes &&
           media::validateMediaSourceDescriptor(*descriptor, limits, nullptr);
  }

  std::shared_ptr<const PreparedAsset> asset_;
  mutable std::atomic<std::uint64_t> cursorCreationAttempts_{0};
  mutable std::atomic<std::uint64_t> cursorsStarted_{0};
};

}  // namespace wam::macos
