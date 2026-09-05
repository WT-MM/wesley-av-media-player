#pragma once

#include "media/native_media_source.hpp"

#include <array>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>

namespace wam::media {

// Extension-only container routing, stated once for every consumer: the
// playback session's backend selection and the QuickLook thumbnail provider's
// demuxer selection. A row says which demuxer is even CAPABLE of the
// container, never whether the media is admissible -- the selected source owns
// that decision and reports Unsupported through the one existing fallback
// route. A fourth container is one row here plus its own backend.
//
// `.mka` is present so an audio-only Matroska reaches the Matroska source and
// is refused there for having no video track, rather than being handed to a
// backend that cannot parse the container at all.
//
// `.mpg`/`.mpeg` are deliberately absent. Those extensions name MPEG PROGRAM
// streams far more often than transport streams, and a program stream is a
// different container the transport-stream demuxer refuses at its first
// sync-byte probe; routing them here would trade a working AVFoundation route
// for a guaranteed fallback.
struct ContainerExtensionRow final {
  std::string_view extension;
  MediaSourceBackendKind backend;
};

inline constexpr std::array<ContainerExtensionRow, 9> kContainerExtensions{{
    {".mkv", MediaSourceBackendKind::Matroska},
    {".mk3d", MediaSourceBackendKind::Matroska},
    {".mka", MediaSourceBackendKind::Matroska},
    {".webm", MediaSourceBackendKind::Matroska},
    {".ts", MediaSourceBackendKind::MpegTs},
    {".m2ts", MediaSourceBackendKind::MpegTs},
    {".mts", MediaSourceBackendKind::MpegTs},
    {".m2t", MediaSourceBackendKind::MpegTs},
    {".mpegts", MediaSourceBackendKind::MpegTs},
}};

// std::nullopt means no neutral demuxer claims the extension. What that means
// is the caller's to decide: the playback session hands the file to
// AVFoundation, the thumbnail provider probes both headers in turn.
[[nodiscard]] inline std::optional<MediaSourceBackendKind>
containerBackendForExtension(const std::filesystem::path &path) noexcept {
  try {
    std::string extension = path.extension().string();
    for (char &character : extension) {
      if (character >= 'A' && character <= 'Z') {
        character = static_cast<char>(character - 'A' + 'a');
      }
    }
    for (const ContainerExtensionRow &row : kContainerExtensions) {
      if (row.extension == extension) {
        return row.backend;
      }
    }
    return std::nullopt;
  } catch (...) {
    // A path whose extension cannot be narrowed to this locale's char is not
    // one of these containers.
    return std::nullopt;
  }
}

} // namespace wam::media
