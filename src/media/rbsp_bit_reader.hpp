#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <span>

namespace wam::media {

// Bit reader over one NAL unit payload with ITU-T H.264/H.265 emulation
// prevention undone as it reads. Allocation-free by construction: the
// unescape is a running zero-count over the source span, never a copy into a
// scratch buffer. Shared by the neutral configuration parser and the MPEG-TS
// HEVC record builder so there is exactly one unescape rule.
//
// Every read returns its value and, once any read has run past the supplied
// bytes or a bounded read has seen an out-of-range value, the reader latches
// failed and every later read returns zero without touching the bytes. The
// zero is the load-bearing part: a latched loop count or present flag can
// never gate a read the bitstream could not have supported, so a parse body
// reads straight through and asks ok() once at the end -- and again wherever
// a verdict other than MalformedRecord depends on a value that has to be real,
// because a latched zero is not a chroma format or a bit depth. A read whose
// value the parser does not need is written as a statement.
class RbspBitReader final {
public:
  explicit RbspBitReader(std::span<const std::uint8_t> escapedBytes) noexcept
      : bytes_(escapedBytes) {}

  [[nodiscard]] bool ok() const noexcept { return !failed_; }
  void require(bool condition) noexcept { failed_ = failed_ || !condition; }

  bool readBit() noexcept { return readBits(1U) != 0U; }

  std::uint32_t readBits(std::size_t count) noexcept {
    if (failed_ || count > 32U) {
      failed_ = true;
      return 0U;
    }
    std::uint32_t value = 0;
    for (std::size_t index = 0; index < count; ++index) {
      if (bitsRemaining_ == 0U && !loadByte()) {
        failed_ = true;
        return 0U;
      }
      value = static_cast<std::uint32_t>(
          (value << 1U) | ((currentByte_ >> (bitsRemaining_ - 1U)) & 1U));
      --bitsRemaining_;
    }
    return value;
  }

  std::uint32_t readBitsAtMost(std::size_t count,
                               std::uint32_t maximum) noexcept {
    return bounded(readBits(count), maximum);
  }

  void skipBits(std::size_t count) noexcept {
    while (count != 0U && !failed_) {
      const std::size_t chunk = std::min<std::size_t>(count, 32U);
      readBits(chunk);
      count -= chunk;
    }
  }

  std::uint32_t readUnsignedExpGolomb() noexcept {
    std::size_t leadingZeroBits = 0;
    while (!readBit()) {
      if (failed_ || ++leadingZeroBits > 31U) {
        failed_ = true;
        return 0U;
      }
    }
    // At most 31 leading zeros, so the sum stays below 2^32.
    const std::uint32_t suffix = readBits(leadingZeroBits);
    return static_cast<std::uint32_t>(
        ((std::uint64_t{1} << leadingZeroBits) - 1U) + suffix);
  }

  std::uint32_t readUnsignedExpGolombAtMost(std::uint32_t maximum) noexcept {
    return bounded(readUnsignedExpGolomb(), maximum);
  }

  // ue(v) and se(v) share one bit layout, so a skipped value needs no sign.
  void skipExpGolomb(std::size_t count) noexcept {
    for (std::size_t index = 0; index < count && !failed_; ++index) {
      readUnsignedExpGolomb();
    }
  }

  std::int32_t readSignedExpGolomb() noexcept {
    const std::uint32_t encoded = readUnsignedExpGolomb();
    // encoded < 2^32 - 1, so the magnitude fits in int32 with either sign.
    const auto magnitude = static_cast<std::int32_t>(
        (static_cast<std::uint64_t>(encoded) + 1U) / 2U);
    return (encoded & 1U) != 0U ? magnitude : -magnitude;
  }

  std::int32_t readSignedExpGolombWithin(std::int32_t minimum,
                                         std::int32_t maximum) noexcept {
    const std::int32_t value = readSignedExpGolomb();
    require(value >= minimum && value <= maximum);
    return failed_ ? 0 : value;
  }

  // Whether syntax bits remain before rbsp_trailing_bits, consuming nothing.
  // A copied probe suffices: the reader owns no storage.
  [[nodiscard]] bool moreRbspData() noexcept {
    RbspBitReader probe = *this;
    const bool possibleStopBit = probe.readBit();
    bool more = !possibleStopBit;
    while (possibleStopBit && !more && probe.bitsRemaining_ != 0U) {
      more = probe.readBit();
    }
    if (possibleStopBit && !more) {
      more = probe.offset_ != probe.bytes_.size();
    }
    require(probe.ok());
    return ok() && more;
  }

  // Accepted syntax is parsed through rbsp_trailing_bits, which catches both
  // truncation and hidden payload after the claimed syntax.
  [[nodiscard]] bool finishRbsp() noexcept {
    require(readBit());
    while (bitsRemaining_ != 0U && !failed_) {
      require(!readBit());
    }
    return ok() && offset_ == bytes_.size();
  }

private:
  std::uint32_t bounded(std::uint32_t value, std::uint32_t maximum) noexcept {
    require(value <= maximum);
    return failed_ ? 0U : value;
  }

  [[nodiscard]] bool loadByte() noexcept {
    while (offset_ < bytes_.size()) {
      const std::uint8_t value = bytes_[offset_++];
      if (zeroCount_ >= 2U && value == 0x03U) {
        if (offset_ >= bytes_.size() || bytes_[offset_] > 0x03U) {
          return false;
        }
        zeroCount_ = 0;
        continue;
      }
      if (zeroCount_ >= 2U && value <= 0x02U) {
        return false;
      }
      zeroCount_ = value == 0U ? zeroCount_ + 1U : 0U;
      currentByte_ = value;
      bitsRemaining_ = 8U;
      return true;
    }
    return false;
  }

  std::span<const std::uint8_t> bytes_;
  std::size_t offset_{0};
  std::size_t zeroCount_{0};
  std::uint8_t currentByte_{0};
  std::size_t bitsRemaining_{0};
  bool failed_{false};
};

} // namespace wam::media
