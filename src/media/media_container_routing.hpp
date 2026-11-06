#pragma once

#include "media/native_media_source.hpp"

#include <filesystem>
#include <optional>
#include <string>
#include <string_view>

namespace wam::media {

// Every file extension WAM offers to open, stated once for container
// routing (the playback session's backend selection, the routed probe's
// fallback, the QuickLook thumbnail provider's demuxer selection), the
// launcher's local-path inference and the open dialog's filter.
//
// `backend` says which demuxer is even CAPABLE of the container, never
// whether the media is admissible -- the selected source owns that decision
// and reports Unsupported through the one existing fallback route. nullopt
// means no neutral demuxer claims it: AVFoundation is the absence of a
// backend. Playlists have no backend.
//
// packaging/Info.plist.in and packaging/quicklook/Info.plist declare the
// document types as UTIs; those remain hand-kept.
struct MediaFileExtensionRow final {
  std::string_view extension;
  std::optional<MediaSourceBackendKind> backend;
  bool playlist;
};

inline constexpr MediaFileExtensionRow kMediaFileExtensions[] = {
    {".mp4", std::nullopt, false},
    {".mkv", MediaSourceBackendKind::Matroska, false},
    {".mov", std::nullopt, false},
    {".avi", MediaSourceBackendKind::Libavformat, false},
    {".webm", MediaSourceBackendKind::Matroska, false},
    {".m4v", std::nullopt, false},
    {".mk3d", MediaSourceBackendKind::Matroska, false},
    // Present so an audio-only Matroska reaches the Matroska source and is
    // refused there for having no video track, rather than being handed to a
    // backend that cannot parse the container at all.
    {".mka", MediaSourceBackendKind::Matroska, false},
    // Deliberately NOT MpegTs. These extensions name MPEG PROGRAM streams far
    // more often than transport streams, and a program stream is a different
    // container the transport-stream demuxer refuses at its first sync-byte
    // probe.
    {".mpg", MediaSourceBackendKind::Libavformat, false},
    {".mpeg", MediaSourceBackendKind::Libavformat, false},
    {".3gp", std::nullopt, false},
    {".3g2", std::nullopt, false},
    {".vob", MediaSourceBackendKind::Libavformat, false},
    {".ogv", MediaSourceBackendKind::Libavformat, false},
    {".qt", std::nullopt, false},
    {".mp3", std::nullopt, false},
    {".m4a", std::nullopt, false},
    {".m4b", std::nullopt, false},
    {".wav", std::nullopt, false},
    {".aiff", std::nullopt, false},
    {".aif", std::nullopt, false},
    {".flac", std::nullopt, false},
    {".ogg", MediaSourceBackendKind::Libavformat, false},
    {".oga", MediaSourceBackendKind::Libavformat, false},
    {".opus", MediaSourceBackendKind::Libavformat, false},
    {".aac", std::nullopt, false},
    {".ac3", std::nullopt, false},
    {".eac3", std::nullopt, false},
    {".dts", std::nullopt, false},
    {".caf", std::nullopt, false},
    {".amr", std::nullopt, false},
    {".w64", std::nullopt, false},
    {".wma", MediaSourceBackendKind::Libavformat, false},
    {".ts", MediaSourceBackendKind::MpegTs, false},
    {".m2ts", MediaSourceBackendKind::MpegTs, false},
    {".mts", MediaSourceBackendKind::MpegTs, false},
    {".wmv", MediaSourceBackendKind::Libavformat, false},
    {".asf", MediaSourceBackendKind::Libavformat, false},
    {".flv", MediaSourceBackendKind::Libavformat, false},
    {".3gpp", std::nullopt, false},
    {".alac", std::nullopt, false},
    {".spx", std::nullopt, false},
    {".wv", std::nullopt, false},
    {".m2t", MediaSourceBackendKind::MpegTs, false},
    {".mpegts", MediaSourceBackendKind::MpegTs, false},
    {".rm", MediaSourceBackendKind::Libavformat, false},
    {".rmvb", MediaSourceBackendKind::Libavformat, false},
    {".m3u", std::nullopt, true},
    {".m3u8", std::nullopt, true},
    {".pls", std::nullopt, true},
    {".cue", std::nullopt, true},
};

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
    for (const MediaFileExtensionRow &row : kMediaFileExtensions) {
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
