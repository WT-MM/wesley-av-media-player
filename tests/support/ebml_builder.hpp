#pragma once

// Byte builders for hand-made EBML/Matroska test documents.

#include <bit>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>
#include <vector>

using Bytes = std::vector<std::byte>;

inline void append(Bytes& destination, std::span<const std::byte> source) {
  destination.insert(destination.end(), source.begin(), source.end());
}

inline void append(Bytes& destination, const Bytes& source) {
  append(destination, std::span<const std::byte>(source));
}

// Element IDs keep their marker bits, so the width is the ID's byte count.
inline void appendId(Bytes& bytes, std::uint32_t id) {
  unsigned width = 1;
  if (id > 0xFFFFFFU) {
    width = 4;
  } else if (id > 0xFFFFU) {
    width = 3;
  } else if (id > 0xFFU) {
    width = 2;
  }
  for (unsigned index = width; index > 0; --index) {
    bytes.push_back(
        static_cast<std::byte>((id >> ((index - 1U) * 8U)) & 0xFFU));
  }
}

inline void appendVintOfWidth(Bytes& bytes, std::uint64_t value,
                              unsigned width) {
  const std::uint64_t encoded = (std::uint64_t{1} << (7U * width)) | value;
  for (unsigned index = width; index > 0; --index) {
    bytes.push_back(
        static_cast<std::byte>((encoded >> ((index - 1U) * 8U)) & 0xFFU));
  }
}

// Shortest size VINT; the all-ones value of each width is reserved for
// "unknown size", hence the - 2.
inline void appendSize(Bytes& bytes, std::uint64_t size) {
  unsigned width = 1;
  while (width < 8) {
    const auto maximum = (std::uint64_t{1} << (7U * width)) - 2U;
    if (size <= maximum) {
      break;
    }
    ++width;
  }
  appendVintOfWidth(bytes, size, width);
}

inline Bytes element(std::uint32_t id, const Bytes& payload) {
  Bytes result;
  appendId(result, id);
  appendSize(result, payload.size());
  append(result, payload);
  return result;
}

inline Bytes unsignedBytes(std::uint64_t value) {
  unsigned width = 1;
  while (width < 8 && value >= (std::uint64_t{1} << (width * 8U))) {
    ++width;
  }
  Bytes result;
  for (unsigned index = width; index > 0; --index) {
    result.push_back(
        static_cast<std::byte>((value >> ((index - 1U) * 8U)) & 0xFFU));
  }
  return result;
}

inline Bytes signedBytes(std::int64_t value, unsigned width = 1) {
  const auto bits = std::bit_cast<std::uint64_t>(value);
  Bytes result;
  for (unsigned index = width; index > 0; --index) {
    result.push_back(
        static_cast<std::byte>((bits >> ((index - 1U) * 8U)) & 0xFFU));
  }
  return result;
}

inline Bytes uintElement(std::uint32_t id, std::uint64_t value) {
  return element(id, unsignedBytes(value));
}

inline Bytes signedElement(std::uint32_t id, std::int64_t value,
                           unsigned width = 1) {
  return element(id, signedBytes(value, width));
}

inline Bytes asciiElement(std::uint32_t id, std::string_view value) {
  Bytes payload;
  for (const char character : value) {
    payload.push_back(static_cast<std::byte>(character));
  }
  return element(id, payload);
}

inline Bytes doubleElement(std::uint32_t id, double value) {
  const auto bits = std::bit_cast<std::uint64_t>(value);
  Bytes payload;
  for (unsigned index = 8; index > 0; --index) {
    payload.push_back(
        static_cast<std::byte>((bits >> ((index - 1U) * 8U)) & 0xFFU));
  }
  return element(id, payload);
}

// The four-byte float ffmpeg writes for every Projection pose angle.
inline Bytes floatElement(std::uint32_t id, float value) {
  const auto bits = std::bit_cast<std::uint32_t>(value);
  Bytes payload;
  for (unsigned index = 4; index > 0; --index) {
    payload.push_back(
        static_cast<std::byte>((bits >> ((index - 1U) * 8U)) & 0xFFU));
  }
  return element(id, payload);
}

// The defaults are the header ffmpeg's Matroska muxer writes.
inline Bytes ebmlHeader(std::uint64_t ebmlVersion = 1,
                        std::uint64_t ebmlReadVersion = 1,
                        std::uint64_t maximumSizeLength = 8,
                        std::uint64_t docTypeVersion = 4,
                        std::uint64_t docTypeReadVersion = 2,
                        std::string_view docType = "matroska") {
  Bytes payload;
  append(payload, uintElement(0x4286, ebmlVersion));
  append(payload, uintElement(0x42F7, ebmlReadVersion));
  append(payload, uintElement(0x42F2, 4));
  append(payload, uintElement(0x42F3, maximumSizeLength));
  append(payload, asciiElement(0x4282, docType));
  append(payload, uintElement(0x4287, docTypeVersion));
  append(payload, uintElement(0x4285, docTypeReadVersion));
  return element(0x1A45DFA3, payload);
}
