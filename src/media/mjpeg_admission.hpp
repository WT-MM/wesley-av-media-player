#pragma once

#include <cstddef>
#include <cstdint>
#include <span>

namespace wam::media {

enum class MjpegAdmission : std::uint8_t {
  Yuv420,
  UnsupportedChroma,
  UnsupportedFrame,
  InvalidHeader,
};

// Only baseline, eight-bit, three-component 2x2/1x1/1x1 JPEG reaches VT.
// The caller supplies at most one bounded compressed admission sample.
[[nodiscard]] inline MjpegAdmission
inspectMjpegHeader(std::span<const std::byte> bytes) noexcept {
  const auto octet = [&](std::size_t i) {
    return std::to_integer<unsigned>(bytes[i]);
  };
  if (bytes.size() < 4 || octet(0) != 0xff || octet(1) != 0xd8) {
    return MjpegAdmission::InvalidHeader;
  }
  std::size_t offset = 2;
  while (offset < bytes.size()) {
    if (octet(offset++) != 0xff)
      return MjpegAdmission::InvalidHeader;
    while (offset < bytes.size() && octet(offset) == 0xff)
      ++offset;
    if (offset == bytes.size())
      return MjpegAdmission::InvalidHeader;
    const unsigned marker = octet(offset++);
    if (marker == 0 || marker == 0xd8 || marker == 0xd9 || marker == 0xda ||
        (marker >= 0xd0 && marker <= 0xd7)) {
      return MjpegAdmission::InvalidHeader;
    }
    if (bytes.size() - offset < 2)
      return MjpegAdmission::InvalidHeader;
    const std::size_t length = (octet(offset) << 8U) | octet(offset + 1);
    if (length < 2 || length > bytes.size() - offset) {
      return MjpegAdmission::InvalidHeader;
    }
    const bool sof = marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 &&
                     marker != 0xc8 && marker != 0xcc;
    if (sof) {
      if (marker != 0xc0)
        return MjpegAdmission::UnsupportedFrame;
      if (length < 8)
        return MjpegAdmission::InvalidHeader;
      const unsigned components = octet(offset + 7);
      if (length != 8U + 3U * components || components == 0 ||
          (octet(offset + 3) == 0 && octet(offset + 4) == 0) ||
          (octet(offset + 5) == 0 && octet(offset + 6) == 0)) {
        return MjpegAdmission::InvalidHeader;
      }
      if (octet(offset + 2) != 8)
        return MjpegAdmission::UnsupportedFrame;
      if (components != 3 || octet(offset + 9) != 0x22 ||
          octet(offset + 12) != 0x11 || octet(offset + 15) != 0x11) {
        return MjpegAdmission::UnsupportedChroma;
      }
      if (octet(offset + 8) == octet(offset + 11) ||
          octet(offset + 8) == octet(offset + 14) ||
          octet(offset + 11) == octet(offset + 14) || octet(offset + 10) > 3 ||
          octet(offset + 13) > 3 || octet(offset + 16) > 3)
        return MjpegAdmission::InvalidHeader;
      return MjpegAdmission::Yuv420;
    }
    offset += length;
  }
  return MjpegAdmission::InvalidHeader;
}

[[nodiscard]] constexpr const char *
mjpegAdmissionReason(MjpegAdmission result) noexcept {
  switch (result) {
  case MjpegAdmission::Yuv420:
    return "";
  case MjpegAdmission::UnsupportedChroma:
    return "Motion JPEG chroma is outside the native 4:2:0 decoder envelope";
  case MjpegAdmission::UnsupportedFrame:
    return "Motion JPEG requires baseline eight-bit SOF0 frames";
  case MjpegAdmission::InvalidHeader:
    return "Motion JPEG admission sample has an invalid or truncated header";
  }
  return "Motion JPEG admission failed";
}
} // namespace wam::media
