#include "media/media_container_routing.hpp"

#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <string_view>

int main() {
  using wam::media::containerBackendForExtension;
  using wam::media::kMediaFileExtensions;
  using wam::media::MediaSourceBackendKind;

  int failures = 0;
  const auto expect = [&failures](bool condition, const char *message) {
    if (condition)
      return;
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  };

  expect(containerBackendForExtension("/media/clip.mkv") ==
             MediaSourceBackendKind::Matroska,
         "Matroska video reaches the Matroska backend");
  expect(containerBackendForExtension("/media/clip.mk3d") ==
             MediaSourceBackendKind::Matroska,
         "stereoscopic Matroska reaches the Matroska backend");
  expect(containerBackendForExtension("/media/clip.webm") ==
             MediaSourceBackendKind::Matroska,
         "WebM reaches the Matroska backend");
  // Audio-only Matroska must reach the Matroska source and be refused there
  // for having no video track, never a backend that cannot parse EBML.
  expect(containerBackendForExtension("/media/clip.mka") ==
             MediaSourceBackendKind::Matroska,
         "audio-only Matroska reaches the Matroska backend");

  expect(containerBackendForExtension("/media/clip.ts") ==
             MediaSourceBackendKind::MpegTs,
         "transport stream reaches the MPEG-TS backend");
  expect(containerBackendForExtension("/media/clip.m2ts") ==
             MediaSourceBackendKind::MpegTs,
         "BDAV transport stream reaches the MPEG-TS backend");
  expect(containerBackendForExtension("/media/clip.mts") ==
             MediaSourceBackendKind::MpegTs,
         "AVCHD transport stream reaches the MPEG-TS backend");

  // Program streams are a different container the transport-stream demuxer
  // refuses at its first sync-byte probe; the general demux stage takes them.
  expect(containerBackendForExtension("/media/clip.mpg") ==
             MediaSourceBackendKind::Libavformat,
         "an MPEG program stream reaches the general demuxer, not MPEG-TS");
  expect(containerBackendForExtension("/media/clip.mpeg") ==
             MediaSourceBackendKind::Libavformat,
         "the long program-stream spelling reaches the general demuxer");
  expect(!containerBackendForExtension("/media/list.m3u8").has_value(),
         "a playlist claims no demuxer");
  expect(!containerBackendForExtension("/media/clip.mp4").has_value(),
         "MP4 claims no neutral demuxer");
  expect(!containerBackendForExtension("/media/clip").has_value(),
         "an extensionless path claims no neutral demuxer");
  expect(!containerBackendForExtension("/media/mkv").has_value(),
         "a bare name matching an extension is not an extension");

  expect(containerBackendForExtension("/media/CLIP.MKV") ==
             MediaSourceBackendKind::Matroska,
         "extension matching is case-insensitive");
  expect(containerBackendForExtension("/media/CLIP.M2TS") ==
             MediaSourceBackendKind::MpegTs,
         "upper-case transport-stream extensions route identically");

  // The table is the statement; every row must be reachable through the
  // lookup, and no row may name the backend that means "not in this table".
  bool m3u8Playlist = false;
  for (const auto &row : kMediaFileExtensions) {
    m3u8Playlist = m3u8Playlist || (row.extension == ".m3u8" && row.playlist &&
                                    !row.backend);
    const std::filesystem::path path =
        std::filesystem::path("/media/clip").concat(row.extension);
    expect(containerBackendForExtension(path) == row.backend,
           "every table row is reachable through the lookup");
    expect(row.backend != MediaSourceBackendKind::AVFoundation,
           "AVFoundation is the absence of a backend, never a backend");
  }
  expect(m3u8Playlist, "m3u8 is a playlist row with no backend");

  if (failures != 0)
    return EXIT_FAILURE;
  std::cout << "media container routing tests passed\n";
  return EXIT_SUCCESS;
}
