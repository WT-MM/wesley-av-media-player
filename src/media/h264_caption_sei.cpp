#include "media/h264_caption_sei.hpp"

#include <cstring>

namespace wam::media::captions {
namespace {

constexpr std::uint8_t kCountryCodeUsa{0xB5};
constexpr std::uint16_t kProviderCodeAtsc{0x0031};
constexpr std::uint8_t kUserDataTypeCcData{0x03};
constexpr std::uint8_t kProcessCcDataFlag{0x40};
constexpr std::uint8_t kSeiPayloadTypeUserDataRegistered{4};
// country + provider + 'GA94' + type + flags + em_data
constexpr std::size_t kCcDataHeaderBytes{10};

[[nodiscard]] unsigned char at(std::string_view s, std::size_t i) noexcept {
  return static_cast<unsigned char>(s[i]);
}

// Reads an SEI ff-coded value (a run of 0xFF bytes then a final byte).
// Returns false when the buffer ends mid-value.
[[nodiscard]] bool readFfCoded(std::string_view s, std::size_t* offset,
                               std::size_t* value) noexcept {
  std::size_t total = 0;
  while (*offset < s.size() && at(s, *offset) == 0xFFU) {
    total += 255;
    ++(*offset);
    // A pathological run of 0xFF would otherwise spin; the cap is far above
    // any legal payload type or size.
    if (total > (1U << 20U)) return false;
  }
  if (*offset >= s.size()) return false;
  total += at(s, *offset);
  ++(*offset);
  *value = total;
  return true;
}

// Parses one A/53 cc_data payload body (starting at itu_t_t35_country_code).
std::size_t appendFromCcDataPayload(std::string_view payload,
                                    std::vector<CcTriplet>* out) {
  if (payload.size() < kCcDataHeaderBytes) return 0;
  if (at(payload, 0) != kCountryCodeUsa) return 0;
  const auto provider = static_cast<std::uint16_t>(
      (static_cast<std::uint16_t>(at(payload, 1)) << 8) | at(payload, 2));
  if (provider != kProviderCodeAtsc) return 0;
  if (std::memcmp(payload.data() + 3, "GA94", 4) != 0) return 0;
  if (at(payload, 7) != kUserDataTypeCcData) return 0;

  const std::uint8_t flags = at(payload, 8);
  if ((flags & kProcessCcDataFlag) == 0) return 0;
  std::size_t count = flags & 0x1FU;
  if (count > kMaximumTripletsPerPicture) count = kMaximumTripletsPerPicture;

  std::size_t appended = 0;
  std::size_t offset = kCcDataHeaderBytes;
  for (std::size_t i = 0; i < count; ++i) {
    if (offset + 3 > payload.size()) break;
    const std::uint8_t marker = at(payload, offset);
    CcTriplet triplet;
    triplet.type = static_cast<CcType>(marker & 0x03U);
    triplet.valid = (marker & 0x04U) != 0;
    triplet.data1 = at(payload, offset + 1);
    triplet.data2 = at(payload, offset + 2);
    out->push_back(triplet);
    ++appended;
    offset += 3;
  }
  return appended;
}

}  // namespace

std::vector<char> removeEmulationPrevention(std::string_view nal) {
  std::vector<char> rbsp;
  rbsp.reserve(nal.size());
  std::size_t zeros = 0;
  for (std::size_t i = 0; i < nal.size(); ++i) {
    const unsigned char byte = at(nal, i);
    if (zeros >= 2 && byte == 0x03U) {
      zeros = 0;
      continue;
    }
    rbsp.push_back(static_cast<char>(byte));
    zeros = (byte == 0x00U) ? zeros + 1 : 0;
  }
  return rbsp;
}

std::size_t appendCaptionTripletsFromSeiRbsp(std::string_view rbsp,
                                             std::vector<CcTriplet>* out) {
  if (out == nullptr || rbsp.size() < 2) return 0;
  // Skip the NAL header byte; HEVC's second header byte is skipped by the
  // caller, which knows which codec it holds.
  std::size_t offset = 1;
  std::size_t appended = 0;
  while (offset < rbsp.size()) {
    // rbsp_trailing_bits terminates the message list.
    if (at(rbsp, offset) == 0x80U && offset + 1 >= rbsp.size()) break;
    std::size_t payloadType = 0;
    std::size_t payloadSize = 0;
    if (!readFfCoded(rbsp, &offset, &payloadType)) break;
    if (!readFfCoded(rbsp, &offset, &payloadSize)) break;
    if (offset + payloadSize > rbsp.size()) break;
    if (payloadType == kSeiPayloadTypeUserDataRegistered) {
      appended += appendFromCcDataPayload(rbsp.substr(offset, payloadSize), out);
    }
    offset += payloadSize;
  }
  return appended;
}

namespace {

// Yields [start, end) of each NAL payload in an Annex-B range.
template <typename Fn>
void forEachAnnexBNal(std::string_view d, Fn&& fn) {
  std::vector<std::size_t> starts;
  const std::size_t n = d.size();
  std::size_t i = 0;
  while (i + 3 <= n) {
    if (at(d, i) == 0 && at(d, i + 1) == 0) {
      if (at(d, i + 2) == 1) {
        starts.push_back(i + 3);
        i += 3;
        continue;
      }
      if (i + 4 <= n && at(d, i + 2) == 0 && at(d, i + 3) == 1) {
        starts.push_back(i + 4);
        i += 4;
        continue;
      }
    }
    ++i;
  }
  for (std::size_t k = 0; k < starts.size(); ++k) {
    std::size_t end = (k + 1 < starts.size()) ? starts[k + 1] : n;
    // Trim the next start code's leading zero bytes off this NAL.
    while (end > starts[k] && at(d, end - 1) == 0x00U) --end;
    fn(d.substr(starts[k], end - starts[k]));
  }
}

std::size_t appendFromNal(std::string_view nal, std::vector<CcTriplet>* out) {
  if (nal.empty() || !isSeiNalHeader(at(nal, 0))) return 0;
  const std::vector<char> rbsp = removeEmulationPrevention(nal);
  return appendCaptionTripletsFromSeiRbsp(
      std::string_view(rbsp.data(), rbsp.size()), out);
}

}  // namespace

std::size_t appendCaptionTripletsFromAnnexB(std::string_view annexB,
                                            std::vector<CcTriplet>* out) {
  if (out == nullptr) return 0;
  std::size_t appended = 0;
  forEachAnnexBNal(annexB,
                   [&](std::string_view nal) { appended += appendFromNal(nal, out); });
  return appended;
}

std::size_t appendCaptionTripletsFromAvcc(std::string_view sample,
                                          std::size_t lengthSize,
                                          std::vector<CcTriplet>* out) {
  if (out == nullptr) return 0;
  if (lengthSize != 1 && lengthSize != 2 && lengthSize != 4) return 0;
  std::size_t appended = 0;
  std::size_t offset = 0;
  while (offset + lengthSize <= sample.size()) {
    std::size_t length = 0;
    for (std::size_t i = 0; i < lengthSize; ++i) {
      length = (length << 8) | at(sample, offset + i);
    }
    offset += lengthSize;
    if (length == 0 || offset + length > sample.size()) break;
    appended += appendFromNal(sample.substr(offset, length), out);
    offset += length;
  }
  return appended;
}

}  // namespace wam::media::captions
