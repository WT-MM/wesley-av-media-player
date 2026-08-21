#pragma once

#include "media/mpegts_demuxer.hpp"
#include "media/native_media_source.hpp"

#include <cstdint>
#include <filesystem>
#include <memory>

namespace wam::macos {

// Immutable, session-scoped identity and admitted MPEG-TS asset state. The
// shape is a deliberate transliteration of `matroska_asset_context.hpp`: the
// context owns no cursor and has no operation generation, so every main seek
// and preview request plans and creates its own pair of cursors while the
// prepared asset, its built index, and the exact descriptor instance stay
// shared.
//
// The counted unit is the cursor, exactly as it is for Matroska, because one
// cursor is the unit of streaming state in both demuxers.
struct MpegTsAssetContextFacts {
  std::uint64_t cursorCreationAttempts{0};
  std::uint64_t cursorsStarted{0};
};

class MpegTsAssetContext final : public media::MediaSourcePreparedContext {
 public:
  ~MpegTsAssetContext() override;

  MpegTsAssetContext(const MpegTsAssetContext&) = delete;
  MpegTsAssetContext& operator=(const MpegTsAssetContext&) = delete;

  [[nodiscard]] MpegTsAssetContextFacts facts() const noexcept;

  // The prepared asset is const and internally re-verifies file identity at
  // every entry point, so planning, cursor creation, and payload gathers
  // remain safe to issue repeatedly from the single source owner.
  [[nodiscard]] const std::shared_ptr<
      const media::mpegts::MpegTsPreparedAsset>&
  asset() const noexcept;

 private:
  struct Impl;
  MpegTsAssetContext(
      std::filesystem::path path,
      const media::MediaSourceOpenOptions& options,
      std::shared_ptr<const media::MediaSourceDescriptor> descriptor,
      std::unique_ptr<Impl> impl) noexcept;
  std::unique_ptr<Impl> impl_;

  friend std::shared_ptr<const MpegTsAssetContext>
  adoptPreparedMpegTsAssetContext(
      std::filesystem::path path,
      const media::MediaSourceOpenOptions& options,
      std::shared_ptr<const media::mpegts::MpegTsPreparedAsset> asset) noexcept;
  friend void noteMpegTsAssetContextCursorCreationAttempt(
      const MpegTsAssetContext& context) noexcept;
  friend void noteMpegTsAssetContextCursorStarted(
      const MpegTsAssetContext& context) noexcept;
};

// Platform implementation boundary. Only the worker that has completed the
// bounded MPEG-TS admission may adopt a prepared asset into a context. The
// context republishes the asset's own descriptor instance rather than a copy,
// because exact descriptor-pointer identity is what later seeks and preview
// bindings prove themselves against.
[[nodiscard]] std::shared_ptr<const MpegTsAssetContext>
adoptPreparedMpegTsAssetContext(
    std::filesystem::path path, const media::MediaSourceOpenOptions& options,
    std::shared_ptr<const media::mpegts::MpegTsPreparedAsset> asset) noexcept;
void noteMpegTsAssetContextCursorCreationAttempt(
    const MpegTsAssetContext& context) noexcept;
void noteMpegTsAssetContextCursorStarted(
    const MpegTsAssetContext& context) noexcept;

}  // namespace wam::macos
