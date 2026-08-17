#pragma once

#include "media/matroska_demuxer.hpp"
#include "media/native_media_source.hpp"

#include <cstdint>
#include <filesystem>
#include <memory>

namespace wam::macos {

// Immutable, session-scoped identity and admitted Matroska asset state. The
// context owns no cursor and has no operation generation: every main seek and
// preview request plans and creates its own pair of cursors while the prepared
// asset, its index, and the exact descriptor instance remain shared.
//
// The AVFoundation context counts reader creations because one AVAssetReader
// is the unit of streaming state there. The equivalent unit here is a cursor,
// so the same two facts are stated against cursors: one attempt per
// makeVideoCursor()/makeAudioCursor() call and one start per cursor that was
// actually produced.
struct MatroskaAssetContextFacts {
  std::uint64_t cursorCreationAttempts{0};
  std::uint64_t cursorsStarted{0};
};

class MatroskaAssetContext final : public media::MediaSourcePreparedContext {
 public:
  ~MatroskaAssetContext() override;

  MatroskaAssetContext(const MatroskaAssetContext&) = delete;
  MatroskaAssetContext& operator=(const MatroskaAssetContext&) = delete;

  [[nodiscard]] MatroskaAssetContextFacts facts() const noexcept;

  // The prepared asset is const and internally re-verifies file identity at
  // every entry point, so planning, cursor creation, and payload copies remain
  // safe to issue repeatedly from the single source owner.
  [[nodiscard]] const std::shared_ptr<
      const media::matroska::MatroskaPreparedAsset>&
  asset() const noexcept;

 private:
  struct Impl;
  MatroskaAssetContext(
      std::filesystem::path path,
      const media::MediaSourceOpenOptions& options,
      std::shared_ptr<const media::MediaSourceDescriptor> descriptor,
      std::unique_ptr<Impl> impl) noexcept;
  std::unique_ptr<Impl> impl_;

  friend std::shared_ptr<const MatroskaAssetContext>
  adoptPreparedMatroskaAssetContext(
      std::filesystem::path path,
      const media::MediaSourceOpenOptions& options,
      std::shared_ptr<const media::matroska::MatroskaPreparedAsset>
          asset) noexcept;
  friend void noteMatroskaAssetContextCursorCreationAttempt(
      const MatroskaAssetContext& context) noexcept;
  friend void noteMatroskaAssetContextCursorStarted(
      const MatroskaAssetContext& context) noexcept;
};

// Platform implementation boundary. Only the worker that has completed the
// bounded Matroska admission may adopt a prepared asset into a context. The
// context republishes the asset's own descriptor instance rather than a copy,
// because exact descriptor-pointer identity is what later seeks and preview
// bindings prove themselves against.
[[nodiscard]] std::shared_ptr<const MatroskaAssetContext>
adoptPreparedMatroskaAssetContext(
    std::filesystem::path path,
    const media::MediaSourceOpenOptions& options,
    std::shared_ptr<const media::matroska::MatroskaPreparedAsset>
        asset) noexcept;
void noteMatroskaAssetContextCursorCreationAttempt(
    const MatroskaAssetContext& context) noexcept;
void noteMatroskaAssetContextCursorStarted(
    const MatroskaAssetContext& context) noexcept;

}  // namespace wam::macos
