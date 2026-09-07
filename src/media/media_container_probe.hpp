#pragma once
#include "media/media_container_routing.hpp"
#include <cstring>
#include <span>
namespace wam::media {
// A recognized signature outranks the filename. ISO-BMFF keeps AVFoundation
// first; only a refused admission advances to the general demux stage.
inline MediaSourceBackendKind
containerBackendForBytes(std::span<const std::byte> bytes,
                         const std::filesystem::path &hint) noexcept {
  const auto match = [&](std::size_t offset, const char *text,
                         std::size_t size) {
    return offset <= bytes.size() && size <= bytes.size() - offset &&
           !std::memcmp(bytes.data() + offset, text, size);
  };
  if (match(0, "\x1a\x45\xdf\xa3", 4))
    return MediaSourceBackendKind::Matroska;
  for (const unsigned stride : {188U, 192U, 204U}) {
    const unsigned offset = stride == 192 ? 4 : 0;
    if (bytes.size() > offset + 2 * stride &&
        bytes[offset] == std::byte{0x47} &&
        bytes[offset + stride] == std::byte{0x47} &&
        bytes[offset + 2 * stride] == std::byte{0x47})
      return MediaSourceBackendKind::MpegTs;
  }
  if (match(4, "ftyp", 4) || match(4, "moov", 4) || match(4, "mdat", 4) ||
      match(4, "free", 4) || match(4, "moof", 4))
    return MediaSourceBackendKind::AVFoundation;
  if ((match(0, "RIFF", 4) && match(8, "AVI ", 4)) || match(0, "FLV", 3) ||
      match(0, "OggS", 4) || match(0, ".RMF", 4) ||
      match(0,
            "\x30\x26\xb2\x75\x8e\x66\xcf\x11\xa6\xd9\x00\xaa\x00\x62\xce\x6c",
            16) ||
      match(0, "\x00\x00\x01\xba", 4))
    return MediaSourceBackendKind::Libavformat;
  if ((match(0, "RIFF", 4) && match(8, "WAVE", 4)) || match(0, "fLaC", 4) ||
      match(0, "ID3", 3) ||
      (match(0, "FORM", 4) && (match(8, "AIFF", 4) || match(8, "AIFC", 4))))
    return MediaSourceBackendKind::AVFoundation;
  const auto known = containerBackendForExtension(hint);
  if (known)
    return *known;
  try {
    auto extension = hint.extension().string();
    for (auto &c : extension)
      if (c >= 'A' && c <= 'Z')
        c = char(c - 'A' + 'a');
    for (const auto name :
         {".avi", ".flv", ".ogg", ".ogv", ".oga", ".opus", ".asf", ".wmv",
          ".wma", ".rm", ".rmvb", ".mpg", ".mpeg", ".vob"})
      if (extension == name)
        return MediaSourceBackendKind::Libavformat;
  } catch (...) {
  }
  return MediaSourceBackendKind::AVFoundation;
}
} // namespace wam::media
