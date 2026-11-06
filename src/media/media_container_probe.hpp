#pragma once
#include "media/matroska_ebml.hpp"
#include "media/media_container_routing.hpp"
#include "media/mpegts_packet.hpp"
#include <cstring>
#include <span>
namespace wam::media {
// An ISO-BMFF top-level box type at `offset` (the type follows a 4-byte size).
inline bool isoBmffTopLevelBoxAt(std::span<const std::byte> bytes,
                                 std::size_t offset) noexcept {
  if (offset > bytes.size() || bytes.size() - offset < 4)
    return false;
  for (const char *type : {"ftyp", "moov", "mdat", "free", "moof"})
    if (!std::memcmp(bytes.data() + offset, type, 4))
      return true;
  return false;
}

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
  if (bytes.size() >= 4 &&
      ((std::uint32_t(bytes[0]) << 24) | (std::uint32_t(bytes[1]) << 16) |
       (std::uint32_t(bytes[2]) << 8) | std::uint32_t(bytes[3])) ==
          matroska::kEbmlHeaderId)
    return MediaSourceBackendKind::Matroska;
  // The demuxer's own framing rule; with the window as the file size it asks
  // for as many sync confirmations as the window can hold.
  mpegts::MpegTsFraming framing;
  if (mpegts::detectMpegTsFraming(bytes, bytes.size(), framing))
    return MediaSourceBackendKind::MpegTs;
  if (isoBmffTopLevelBoxAt(bytes, 4))
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
  return containerBackendForExtension(hint).value_or(
      MediaSourceBackendKind::AVFoundation);
}
} // namespace wam::media
