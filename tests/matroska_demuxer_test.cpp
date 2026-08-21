#include "media/matroska_demuxer.hpp"

#include "media/matroska_aac.hpp"
#include "media/matroska_ebml.hpp"
#include "media/native_media_source.hpp"
#include "media/video_codec_configuration.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <fcntl.h>
#include <filesystem>
#include <iostream>
#include <limits>
#include <numeric>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <type_traits>
#include <unistd.h>
#include <utility>
#include <variant>
#include <vector>

namespace {

using namespace wam::media::matroska;
using wam::media::MediaAudioGenerationWindow;
using wam::media::MediaCodec;
using wam::media::MediaCodecConfigurationKind;
using wam::media::MediaColorPrimaries;
using wam::media::MediaMatrixCoefficients;
using wam::media::MediaSampleKind;
using wam::media::MediaSeekMode;
using wam::media::MediaSourceLimits;
using wam::media::MediaSourceOpenOptions;
using wam::media::MediaTime;
using wam::media::MediaTrackKind;
using wam::media::MediaTransferFunction;
using wam::media::MediaVideoSampleFormat;
using Bytes = std::vector<std::byte>;

static_assert(!std::is_copy_constructible_v<MatroskaCursor>);
static_assert(!std::is_copy_assignable_v<MatroskaCursor>);
static_assert(std::is_nothrow_move_constructible_v<MatroskaCursor>);
static_assert(std::is_nothrow_move_assignable_v<MatroskaCursor>);
static_assert(!std::is_copy_constructible_v<MatroskaPreparedAsset>);
static_assert(!std::is_copy_assignable_v<MatroskaPreparedAsset>);
static_assert(!std::is_default_constructible_v<MatroskaPreparedAsset>);
static_assert(kMaximumMatroskaEncodedBlockBytes ==
              kMaximumMatroskaClusterBytes);
// A compressed sample is pure metadata: exact ranges into the retained reader
// with no owned payload storage of any kind.
static_assert(std::is_trivially_copyable_v<MatroskaCompressedSample>);
static_assert(sizeof(MatroskaCompressedSample) <=
              sizeof(FrameRange) * ParseOptions::kHardMaximumLaceFrames + 128U);

int failures = 0;

void expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

// ---------------------------------------------------------------------------
// Exact EBML byte builders. These mirror tests/matroska_ebml_test.cpp so both
// suites construct byte-identical structures from the same primitives.
// ---------------------------------------------------------------------------

constexpr std::uint32_t kEbmlHeaderId{0x1A45DFA3};
constexpr std::uint32_t kSegmentId{0x18538067};
constexpr std::uint32_t kInfoId{0x1549A966};
constexpr std::uint32_t kTimestampScaleId{0x2AD7B1};
constexpr std::uint32_t kDurationId{0x4489};
constexpr std::uint32_t kTracksId{0x1654AE6B};
constexpr std::uint32_t kTrackEntryId{0xAE};
constexpr std::uint32_t kTrackNumberId{0xD7};
constexpr std::uint32_t kTrackUidId{0x73C5};
constexpr std::uint32_t kTrackTypeId{0x83};
constexpr std::uint32_t kFlagLacingId{0x9C};
constexpr std::uint32_t kDefaultDurationId{0x23E383};
constexpr std::uint32_t kCodecIdId{0x86};
constexpr std::uint32_t kCodecPrivateId{0x63A2};
constexpr std::uint32_t kLanguageId{0x22B59C};
constexpr std::uint32_t kCodecDelayId{0x56AA};
constexpr std::uint32_t kSeekPreRollId{0x56BB};
constexpr std::uint32_t kVideoId{0xE0};
constexpr std::uint32_t kFlagInterlacedId{0x9A};
constexpr std::uint32_t kPixelWidthId{0xB0};
constexpr std::uint32_t kPixelHeightId{0xBA};
constexpr std::uint32_t kColourId{0x55B0};
constexpr std::uint32_t kMatrixCoefficientsId{0x55B1};
constexpr std::uint32_t kTransferCharacteristicsId{0x55BA};
constexpr std::uint32_t kPrimariesId{0x55BB};
constexpr std::uint32_t kAudioId{0xE1};
constexpr std::uint32_t kSamplingFrequencyId{0xB5};
constexpr std::uint32_t kChannelsId{0x9F};
constexpr std::uint32_t kBitDepthId{0x6264};
constexpr std::uint32_t kClusterId{0x1F43B675};
constexpr std::uint32_t kClusterTimestampId{0xE7};
constexpr std::uint32_t kSimpleBlockId{0xA3};
constexpr std::uint32_t kBlockGroupId{0xA0};
constexpr std::uint32_t kBlockId{0xA1};
constexpr std::uint32_t kBlockDurationId{0x9B};
constexpr std::uint32_t kReferenceBlockId{0xFB};
constexpr std::uint32_t kCuesId{0x1C53BB6B};
constexpr std::uint32_t kCuePointId{0xBB};
constexpr std::uint32_t kCueTimeId{0xB3};
constexpr std::uint32_t kCueTrackPositionsId{0xB7};
constexpr std::uint32_t kCueTrackId{0xF7};
constexpr std::uint32_t kCueClusterPositionId{0xF1};
constexpr std::uint32_t kCueRelativePositionId{0xF0};
constexpr std::uint32_t kCueBlockNumberId{0x5378};
constexpr std::uint32_t kVoidId{0xEC};

void append(Bytes& destination, std::span<const std::byte> source) {
  destination.insert(destination.end(), source.begin(), source.end());
}

void append(Bytes& destination, const Bytes& source) {
  append(destination, std::span<const std::byte>(source));
}

void appendId(Bytes& bytes, std::uint32_t id) {
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

void appendVintOfWidth(Bytes& bytes, std::uint64_t value, unsigned width) {
  const std::uint64_t encoded = (std::uint64_t{1} << (7U * width)) | value;
  for (unsigned index = width; index > 0; --index) {
    bytes.push_back(
        static_cast<std::byte>((encoded >> ((index - 1U) * 8U)) & 0xFFU));
  }
}

void appendSize(Bytes& bytes, std::uint64_t size) {
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

void appendSignedVint(Bytes& bytes, std::int64_t value) {
  unsigned width = 1;
  while (width < 8) {
    const std::int64_t bound =
        (std::int64_t{1} << (7U * width - 1U)) - 1;
    if (value >= -bound && value <= bound) {
      break;
    }
    ++width;
  }
  const std::int64_t bias =
      (std::int64_t{1} << (7U * width - 1U)) - 1;
  appendVintOfWidth(bytes, static_cast<std::uint64_t>(value + bias), width);
}

Bytes element(std::uint32_t id, const Bytes& payload) {
  Bytes result;
  appendId(result, id);
  appendSize(result, payload.size());
  append(result, payload);
  return result;
}

Bytes unsignedBytes(std::uint64_t value) {
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

Bytes signedBytes(std::int64_t value, unsigned width = 1) {
  const auto bits = std::bit_cast<std::uint64_t>(value);
  Bytes result;
  for (unsigned index = width; index > 0; --index) {
    result.push_back(
        static_cast<std::byte>((bits >> ((index - 1U) * 8U)) & 0xFFU));
  }
  return result;
}

Bytes uintElement(std::uint32_t id, std::uint64_t value) {
  return element(id, unsignedBytes(value));
}

Bytes signedElement(std::uint32_t id, std::int64_t value,
                    unsigned width = 1) {
  return element(id, signedBytes(value, width));
}

Bytes asciiElement(std::uint32_t id, std::string_view value) {
  Bytes payload;
  for (const char character : value) {
    payload.push_back(static_cast<std::byte>(character));
  }
  return element(id, payload);
}

Bytes doubleElement(std::uint32_t id, double value) {
  const auto bits = std::bit_cast<std::uint64_t>(value);
  Bytes payload;
  for (unsigned index = 8; index > 0; --index) {
    payload.push_back(
        static_cast<std::byte>((bits >> ((index - 1U) * 8U)) & 0xFFU));
  }
  return element(id, payload);
}

Bytes ebmlHeader(const std::string& docType = "matroska") {
  Bytes payload;
  append(payload, uintElement(0x4286, 1));
  append(payload, uintElement(0x42F7, 1));
  append(payload, uintElement(0x42F2, 4));
  append(payload, uintElement(0x42F3, 8));
  append(payload, asciiElement(0x4282, docType));
  append(payload, uintElement(0x4287, 4));
  append(payload, uintElement(0x4285, 2));
  return element(kEbmlHeaderId, payload);
}

// Encoder-produced High-profile avcC for the repository's deterministic
// 1280x720 H.264 sample. It is byte-identical to the record admitted by
// tests/video_codec_configuration_test.cpp.
constexpr std::array<std::uint8_t, 45> kSampleAvcC{
    0x01, 0x64, 0x00, 0x1f, 0xff, 0xe1, 0x00, 0x1a, 0x67, 0x64, 0x00, 0x1f,
    0xac, 0xd9, 0x40, 0x50, 0x05, 0xbb, 0x01, 0x10, 0x00, 0x00, 0x03, 0x00,
    0x10, 0x00, 0x00, 0x03, 0x03, 0xc0, 0xf1, 0x83, 0x19, 0x60, 0x01, 0x00,
    0x04, 0x68, 0xef, 0x8f, 0xcb, 0xfd, 0xf8, 0xf8, 0x00};

constexpr std::uint32_t kSampleAvcWidth{1280};
constexpr std::uint32_t kSampleAvcHeight{720};

// The 18-byte av1C and the leading bytes of the first (key) frame from
// test-media/codec-envelope. Both are byte-identical to the records admitted
// by tests/video_codec_configuration_test.cpp; the Matroska Block payload for
// VP9 is the elementary-stream frame verbatim, so the keyframe bytes below are
// exactly what the demuxer hands the bitstream parser.
constexpr std::array<std::uint8_t, 18> kSampleAv1C{
    0x81, 0x08, 0x0c, 0x00, 0x0a, 0x0c, 0x02, 0x00, 0x00,
    0x42, 0x95, 0x5d, 0xfe, 0x1b, 0x80, 0x5f, 0x00, 0x08};
constexpr std::array<std::uint8_t, 12> kSampleVp9Keyframe{
    0x82, 0x49, 0x83, 0x42, 0x00, 0x77, 0xf0, 0x43, 0x76, 0x06, 0x38, 0x24};
// A real 12-byte vpcC for the same stream: version 1, profile 0, level 4.1,
// 8-bit 4:2:0 co-located narrow range, unspecified colour.
constexpr std::array<std::uint8_t, 12> kSampleVpcC{
    0x01, 0x00, 0x00, 0x00, 0x00, 0x29, 0x82, 0x02, 0x02, 0x02, 0x00, 0x00};

// The first ten bytes of the first coded frame of
// scratchpad/fixtures/vp8_vorbis60.webm, a 1920x1080 key frame: the three-byte
// frame tag, the 9d 01 2a start code, and the two 14-bit dimension fields.
constexpr std::array<std::uint8_t, 10> kSampleVp8Keyframe{
    0x10, 0xb1, 0x03, 0x9d, 0x01, 0x2a, 0x80, 0x07, 0x38, 0x04};

constexpr std::uint32_t kSampleCodecEnvelopeWidth{1920};
constexpr std::uint32_t kSampleCodecEnvelopeHeight{1080};

// Real ffmpeg CodecPrivate from a 1920x1080 MPEG-4 Part 2 Matroska file: the
// start-code-delimited VisualObjectSequence, VisualObject, VideoObject,
// VideoObjectLayer and user_data. The two records differ only where the
// verdict is decided -- the first is Simple Profile (video_object_type_
// indication 1, verid 1), the second Advanced Simple (17 and 5), which is what
// Xvid and DivX produce and what Apple's VideoToolbox decoder refuses.
constexpr std::array<std::uint8_t, 47> kSampleMpeg4SimpleProfile{
    0x00, 0x00, 0x01, 0xb0, 0x01, 0x00, 0x00, 0x01, 0xb5, 0x89, 0x13, 0x00,
    0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x20, 0x00, 0xc4, 0x8d, 0x88, 0x00,
    0xf5, 0x3c, 0x04, 0x87, 0x14, 0x43, 0x00, 0x00, 0x01, 0xb2, 0x4c, 0x61,
    0x76, 0x63, 0x36, 0x32, 0x2e, 0x32, 0x38, 0x2e, 0x31, 0x30, 0x32};

constexpr std::array<std::uint8_t, 48> kSampleMpeg4AdvancedSimple{
    0x00, 0x00, 0x01, 0xb0, 0xf1, 0x00, 0x00, 0x01, 0xb5, 0xa9, 0x13, 0x00,
    0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x20, 0x08, 0xd4, 0x8d, 0x08, 0x00,
    0xf5, 0x3c, 0x04, 0x87, 0x14, 0x10, 0x3f, 0x00, 0x00, 0x01, 0xb2, 0x4c,
    0x61, 0x76, 0x63, 0x36, 0x32, 0x2e, 0x32, 0x38, 0x2e, 0x31, 0x30, 0x32};

// Canonical two-byte AAC-LC AudioSpecificConfig: 48 kHz, stereo, 1024 samples.
constexpr std::array<std::uint8_t, 2> kAacStereo48Asc{0x11, 0x90};

// The canonical 19-byte OpusHead every ffmpeg mux writes: version 1, stereo,
// pre-skip 312, 48 kHz encoder input, unity gain, channel mapping family 0.
constexpr std::array<std::uint8_t, 19> kOpusHeadStereo312{
    0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64, 0x01, 0x02,
    0x38, 0x01, 0x80, 0xBB, 0x00, 0x00, 0x00, 0x00, 0x00};

constexpr std::uint32_t kAudioSampleRate{48'000};
constexpr std::uint64_t kTimestampScaleNanoseconds{1'000'000};
constexpr std::uint64_t kVideoDefaultDurationNanoseconds{40'000'000};

Bytes fromOctets(std::span<const std::uint8_t> octets) {
  Bytes result;
  result.reserve(octets.size());
  for (const std::uint8_t octet : octets) {
    result.push_back(static_cast<std::byte>(octet));
  }
  return result;
}

// A Matroska A_VORBIS CodecPrivate: a packet-count byte, Xiph-lacing lengths
// for the identification and comment headers, then the three payloads. Stereo
// at kAudioSampleRate, with the packed block-size byte left to the caller so a
// test can vary that one field and nothing else.
Bytes vorbisCodecPrivate(std::uint8_t packedBlockSizes) {
  Bytes identification(30U, std::byte{0});
  identification[0] = std::byte{0x01};
  const char *magic = "vorbis";
  for (std::size_t index = 0; index < 6U; ++index) {
    identification[index + 1U] =
        static_cast<std::byte>(static_cast<std::uint8_t>(magic[index]));
  }
  identification[11] = std::byte{0x02};
  for (std::size_t index = 0; index < 4U; ++index) {
    identification[12U + index] =
        static_cast<std::byte>((kAudioSampleRate >> (8U * index)) & 0xFFU);
  }
  identification[28] = static_cast<std::byte>(packedBlockSizes);
  identification[29] = std::byte{0x01};

  const auto namedHeader = [magic](std::uint8_t type, std::size_t size) {
    Bytes header(size, std::byte{0x5A});
    header[0] = static_cast<std::byte>(type);
    for (std::size_t index = 0; index < 6U; ++index) {
      header[index + 1U] =
          static_cast<std::byte>(static_cast<std::uint8_t>(magic[index]));
    }
    return header;
  };
  const Bytes comment = namedHeader(3U, 16U);
  const Bytes setup = namedHeader(5U, 64U);

  Bytes blob;
  blob.push_back(std::byte{0x02});
  blob.push_back(static_cast<std::byte>(identification.size()));
  blob.push_back(static_cast<std::byte>(comment.size()));
  blob.insert(blob.end(), identification.begin(), identification.end());
  blob.insert(blob.end(), comment.begin(), comment.end());
  blob.insert(blob.end(), setup.begin(), setup.end());
  return blob;
}

// ---------------------------------------------------------------------------
// Block, Cluster, and document assembly with exact retained byte facts.
// ---------------------------------------------------------------------------

std::uint8_t lacingFlagBits(Lacing lacing) {
  switch (lacing) {
  case Lacing::None:
    return 0x00U;
  case Lacing::Xiph:
    return 0x02U;
  case Lacing::Fixed:
    return 0x04U;
  case Lacing::Ebml:
    return 0x06U;
  }
  return 0x00U;
}

struct FramePayload {
  Bytes bytes;
  std::vector<ByteRange> frames;
};

// Frame bytes are a deterministic rolling counter so any offset error in the
// demuxer changes the copied bytes instead of silently matching.
FramePayload buildFramePayload(Lacing lacing,
                               std::span<const std::size_t> sizes,
                               std::uint8_t& fill) {
  FramePayload result;
  const auto count = static_cast<std::uint8_t>(sizes.size() - 1U);
  switch (lacing) {
  case Lacing::None:
    break;
  case Lacing::Xiph: {
    result.bytes.push_back(static_cast<std::byte>(count));
    for (std::size_t index = 0; index + 1U < sizes.size(); ++index) {
      std::size_t remaining = sizes[index];
      while (remaining >= 255U) {
        result.bytes.push_back(std::byte{0xFF});
        remaining -= 255U;
      }
      result.bytes.push_back(static_cast<std::byte>(remaining));
    }
    break;
  }
  case Lacing::Fixed:
    result.bytes.push_back(static_cast<std::byte>(count));
    break;
  case Lacing::Ebml: {
    result.bytes.push_back(static_cast<std::byte>(count));
    appendSize(result.bytes, sizes.front());
    for (std::size_t index = 1; index + 1U < sizes.size(); ++index) {
      appendSignedVint(result.bytes,
                       static_cast<std::int64_t>(sizes[index]) -
                           static_cast<std::int64_t>(sizes[index - 1U]));
    }
    break;
  }
  }
  for (const std::size_t size : sizes) {
    const std::size_t offset = result.bytes.size();
    for (std::size_t index = 0; index < size; ++index) {
      result.bytes.push_back(static_cast<std::byte>(fill));
      fill = static_cast<std::uint8_t>(fill + 1U);
    }
    result.frames.push_back(
        ByteRange{static_cast<std::uint64_t>(offset),
                  static_cast<std::uint64_t>(size)});
  }
  return result;
}

Bytes blockBody(std::uint8_t flags, const Bytes& laceAndFrames,
                std::int16_t timestamp, std::uint64_t trackNumber) {
  Bytes payload{
      static_cast<std::byte>(0x80U | trackNumber),
      static_cast<std::byte>(
          (static_cast<std::uint16_t>(timestamp) >> 8U) & 0xFFU),
      static_cast<std::byte>(static_cast<std::uint16_t>(timestamp) & 0xFFU),
      static_cast<std::byte>(flags)};
  append(payload, laceAndFrames);
  return payload;
}

struct BuiltBlock {
  Bytes bytes;
  // Offsets are relative to bytes[0] until the fixture makes them absolute.
  std::vector<ByteRange> frames;
  std::uint64_t containerOffset{0};
  std::int64_t tick{0};
  std::uint64_t firstOrdinal{0};
  std::uint16_t frameCount{0};
  bool keyFrame{false};
  bool video{true};
  bool invisible{false};
  bool discardable{false};
  std::optional<std::uint64_t> durationTicks;
};

BuiltBlock buildSimpleBlock(std::uint64_t track, std::int64_t tick,
                            std::int16_t relative, bool keyFrame,
                            bool invisible, bool discardable, Lacing lacing,
                            std::span<const std::size_t> sizes,
                            std::uint8_t& fill) {
  FramePayload payload = buildFramePayload(lacing, sizes, fill);
  const auto flags = static_cast<std::uint8_t>(
      (keyFrame ? 0x80U : 0U) | (invisible ? 0x08U : 0U) |
      lacingFlagBits(lacing) | (discardable ? 0x01U : 0U));
  const Bytes body = blockBody(flags, payload.bytes, relative, track);
  BuiltBlock block;
  block.bytes = element(kSimpleBlockId, body);
  const auto base =
      static_cast<std::uint64_t>(block.bytes.size() - body.size()) + 4U;
  for (const ByteRange frame : payload.frames) {
    block.frames.push_back(ByteRange{base + frame.offset, frame.size});
  }
  block.tick = tick;
  block.keyFrame = keyFrame;
  block.invisible = invisible;
  block.discardable = discardable;
  block.frameCount = static_cast<std::uint16_t>(sizes.size());
  return block;
}

BuiltBlock buildBlockGroup(std::uint64_t track, std::int64_t tick,
                           std::int16_t relative,
                           std::span<const std::int64_t> references,
                           std::optional<std::uint64_t> durationTicks,
                           bool invisible, Lacing lacing,
                           std::span<const std::size_t> sizes,
                           std::uint8_t& fill) {
  FramePayload payload = buildFramePayload(lacing, sizes, fill);
  const auto flags = static_cast<std::uint8_t>(
      (invisible ? 0x08U : 0U) | lacingFlagBits(lacing));
  const Bytes body = blockBody(flags, payload.bytes, relative, track);
  const Bytes blockElement = element(kBlockId, body);
  Bytes groupPayload;
  for (const std::int64_t reference : references) {
    append(groupPayload, signedElement(kReferenceBlockId, reference, 2));
  }
  if (durationTicks) {
    append(groupPayload, uintElement(kBlockDurationId, *durationTicks));
  }
  const auto blockOffset = static_cast<std::uint64_t>(groupPayload.size());
  append(groupPayload, blockElement);
  BuiltBlock block;
  block.bytes = element(kBlockGroupId, groupPayload);
  const auto groupPrefix =
      static_cast<std::uint64_t>(block.bytes.size() - groupPayload.size());
  const auto base = groupPrefix + blockOffset +
                    static_cast<std::uint64_t>(blockElement.size() -
                                               body.size()) +
                    4U;
  for (const ByteRange frame : payload.frames) {
    block.frames.push_back(ByteRange{base + frame.offset, frame.size});
  }
  block.tick = tick;
  block.keyFrame = references.empty();
  block.invisible = invisible;
  block.frameCount = static_cast<std::uint16_t>(sizes.size());
  block.durationTicks = durationTicks;
  return block;
}

struct BuiltCluster {
  Bytes bytes;
  std::uint64_t timestamp{0};
  std::uint64_t dataOffset{0};
  std::vector<BuiltBlock> blocks;
};

BuiltCluster buildCluster(std::uint64_t timestamp,
                          std::vector<BuiltBlock> blocks,
                          std::size_t voidPaddingBytes = 0) {
  Bytes payload = uintElement(kClusterTimestampId, timestamp);
  if (voidPaddingBytes != 0) {
    append(payload, element(kVoidId, Bytes(voidPaddingBytes, std::byte{0})));
  }
  for (BuiltBlock& block : blocks) {
    const auto at = static_cast<std::uint64_t>(payload.size());
    block.containerOffset = at;
    for (ByteRange& frame : block.frames) {
      frame.offset += at;
    }
    append(payload, block.bytes);
  }
  BuiltCluster cluster;
  cluster.bytes = element(kClusterId, payload);
  cluster.dataOffset =
      static_cast<std::uint64_t>(cluster.bytes.size() - payload.size());
  cluster.timestamp = timestamp;
  for (BuiltBlock& block : blocks) {
    block.containerOffset += cluster.dataOffset;
    for (ByteRange& frame : block.frames) {
      frame.offset += cluster.dataOffset;
    }
  }
  cluster.blocks = std::move(blocks);
  return cluster;
}

struct BlockFacts {
  std::uint64_t containerOffset{0};
  std::uint32_t clusterIndex{0};
  std::int64_t tick{0};
  std::uint64_t firstOrdinal{0};
  std::uint16_t frameCount{0};
  bool keyFrame{false};
  bool invisible{false};
  bool discardable{false};
  std::optional<std::uint64_t> durationTicks;
  std::vector<ByteRange> frames;
};

enum class CueVariant : std::uint8_t {
  Canonical,
  Absent,
  NonZeroFirst,
  Unsorted,
  DuplicateTime,
  NoRelativePosition,
  BlockNumberTwo,
  NonKeyFrameTarget,
  OutsideCluster,
  AudioTrackOnly,
};

struct FixtureSpec {
  std::vector<std::uint64_t> clusterTimestamps{0, 500, 1000};
  double durationTicks{1500.0};
  bool includeVideoTrack{true};
  bool includeAudioTrack{true};
  bool includeSubtitleTrack{true};
  std::string videoCodecId{"V_MPEG4/ISO/AVC"};
  std::string audioCodecId{"A_AAC"};
  // WebM is Matroska with a smaller codec set. Writing "webm" here is what
  // exercises the DocType-scoped audio allow-list.
  std::string docType{"matroska"};
  Bytes videoCodecPrivate{fromOctets(kSampleAvcC)};
  // WebM muxers routinely write no CodecPrivate at all for VP9, so the
  // element has to be omittable, not merely empty.
  bool includeVideoCodecPrivate{true};
  // When set, replaces the frame payload of every video random access point.
  // VP9 admission proves its facts from the first keyframe's bitstream, so
  // that keyframe has to carry a real VP9 uncompressed header.
  Bytes videoKeyframePayload;
  Bytes audioCodecPrivate{fromOctets(kAacStereo48Asc)};
  std::optional<std::uint64_t> videoInterlaced;
  std::optional<std::uint64_t> videoCodecDelayNanoseconds;
  std::uint64_t videoPixelWidth{kSampleAvcWidth};
  std::uint64_t videoPixelHeight{kSampleAvcHeight};
  double audioSamplingFrequency{static_cast<double>(kAudioSampleRate)};
  std::uint64_t audioChannels{2};
  std::optional<std::uint64_t> audioBitDepth;
  std::optional<std::uint64_t> audioCodecDelayNanoseconds;
  std::optional<std::uint64_t> audioSeekPreRollNanoseconds;
  std::uint64_t videoTrackNumber{1};
  std::uint64_t audioTrackNumber{2};
  std::size_t largeVideoFrameBytes{0};
  // Real muxers reserve Void padding at Segment and Cluster level; a nonzero
  // value writes one Void before every Cluster and one after every Timestamp.
  std::size_t voidPaddingBytes{0};
  CueVariant cues{CueVariant::Canonical};
  bool videoDefaultDuration{true};
};

struct Fixture {
  Bytes bytes;
  std::uint64_t segmentDataOffset{0};
  std::vector<std::uint64_t> clusterEncodedOffsets;
  std::vector<std::uint64_t> clusterDataOffsets;
  std::vector<std::uint64_t> clusterTimestamps;
  std::vector<BlockFacts> videoBlocks;
  std::vector<BlockFacts> audioBlocks;
  std::vector<std::uint64_t> cueTicks;

  [[nodiscard]] const BlockFacts* videoBlockAt(std::uint64_t offset) const {
    for (const BlockFacts& block : videoBlocks) {
      if (block.containerOffset == offset) {
        return &block;
      }
    }
    return nullptr;
  }
};

Bytes videoTrackEntry(const FixtureSpec& spec) {
  Bytes videoPayload;
  if (spec.videoInterlaced) {
    append(videoPayload, uintElement(kFlagInterlacedId, *spec.videoInterlaced));
  }
  append(videoPayload, uintElement(kPixelWidthId, spec.videoPixelWidth));
  append(videoPayload, uintElement(kPixelHeightId, spec.videoPixelHeight));
  Bytes colourPayload;
  append(colourPayload, uintElement(kMatrixCoefficientsId, 1));
  append(colourPayload, uintElement(kTransferCharacteristicsId, 1));
  append(colourPayload, uintElement(kPrimariesId, 1));
  append(videoPayload, element(kColourId, colourPayload));

  Bytes payload;
  append(payload, uintElement(kTrackNumberId, spec.videoTrackNumber));
  append(payload, uintElement(kTrackUidId, 0xAB11));
  append(payload, uintElement(kTrackTypeId, 1));
  append(payload, uintElement(kFlagLacingId, 0));
  if (spec.videoDefaultDuration) {
    append(payload, uintElement(kDefaultDurationId,
                                kVideoDefaultDurationNanoseconds));
  }
  if (spec.videoCodecDelayNanoseconds) {
    append(payload,
           uintElement(kCodecDelayId, *spec.videoCodecDelayNanoseconds));
  }
  append(payload, asciiElement(kCodecIdId, spec.videoCodecId));
  append(payload, asciiElement(kLanguageId, "und"));
  if (spec.includeVideoCodecPrivate) {
    append(payload, element(kCodecPrivateId, spec.videoCodecPrivate));
  }
  append(payload, element(kVideoId, videoPayload));
  return element(kTrackEntryId, payload);
}

Bytes audioTrackEntry(const FixtureSpec& spec) {
  Bytes audioPayload;
  append(audioPayload,
         doubleElement(kSamplingFrequencyId, spec.audioSamplingFrequency));
  append(audioPayload, uintElement(kChannelsId, spec.audioChannels));
  if (spec.audioBitDepth) {
    append(audioPayload, uintElement(kBitDepthId, *spec.audioBitDepth));
  }

  Bytes payload;
  append(payload, uintElement(kTrackNumberId, spec.audioTrackNumber));
  append(payload, uintElement(kTrackUidId, 0xAB22));
  append(payload, uintElement(kTrackTypeId, 2));
  append(payload, asciiElement(kCodecIdId, spec.audioCodecId));
  append(payload, asciiElement(kLanguageId, "eng"));
  if (spec.audioCodecDelayNanoseconds) {
    append(payload,
           uintElement(kCodecDelayId, *spec.audioCodecDelayNanoseconds));
  }
  if (spec.audioSeekPreRollNanoseconds) {
    append(payload,
           uintElement(kSeekPreRollId, *spec.audioSeekPreRollNanoseconds));
  }
  append(payload, element(kCodecPrivateId, spec.audioCodecPrivate));
  append(payload, element(kAudioId, audioPayload));
  return element(kTrackEntryId, payload);
}

Bytes subtitleTrackEntry() {
  Bytes payload;
  append(payload, uintElement(kTrackNumberId, 3));
  append(payload, uintElement(kTrackUidId, 0xAB33));
  append(payload, uintElement(kTrackTypeId, 0x11));
  append(payload, asciiElement(kCodecIdId, "S_TEXT/UTF8"));
  append(payload, asciiElement(kLanguageId, "fra"));
  return element(kTrackEntryId, payload);
}

struct CuePointSpec {
  std::uint64_t time{0};
  std::uint64_t track{1};
  std::uint64_t clusterPosition{0};
  std::optional<std::uint64_t> relativePosition;
  std::optional<std::uint64_t> blockNumber;
};

Bytes cuesElement(std::span<const CuePointSpec> points) {
  Bytes payload;
  for (const CuePointSpec& point : points) {
    Bytes positions;
    append(positions, uintElement(kCueTrackId, point.track));
    append(positions,
           uintElement(kCueClusterPositionId, point.clusterPosition));
    if (point.relativePosition) {
      append(positions,
             uintElement(kCueRelativePositionId, *point.relativePosition));
    }
    if (point.blockNumber) {
      append(positions, uintElement(kCueBlockNumberId, *point.blockNumber));
    }
    Bytes cuePoint = uintElement(kCueTimeId, point.time);
    append(cuePoint, element(kCueTrackPositionsId, positions));
    append(payload, element(kCuePointId, cuePoint));
  }
  return element(kCuesId, payload);
}

// Video pattern per Cluster: one SimpleBlock random access point, two
// BlockGroups (one reference-only, one B-frame with an explicit VFR
// BlockDuration), and two non-key SimpleBlocks carrying the invisible and
// discardable flags.
struct VideoBlockPlan {
  std::int64_t relative{0};
  bool simple{true};
  bool keyFrame{false};
  bool invisible{false};
  bool discardable{false};
  std::size_t frameBytes{6};
  std::vector<std::int64_t> references;
  std::optional<std::uint64_t> durationTicks;
};

std::vector<VideoBlockPlan> videoBlockPlans(const FixtureSpec& spec) {
  std::vector<VideoBlockPlan> plans;
  plans.push_back({0, true, true, false, false, 6, {}, std::nullopt});
  plans.push_back({40, false, false, false, false, 7, {-40}, std::nullopt});
  plans.push_back({80, false, false, false, false, 8, {-40, 40}, 60});
  plans.push_back({120, true, false, true, false,
                   spec.largeVideoFrameBytes != 0 ? spec.largeVideoFrameBytes
                                                  : 5,
                   {}, std::nullopt});
  plans.push_back({160, true, false, false, true, 4, {}, std::nullopt});
  return plans;
}

struct AudioBlockPlan {
  std::uint16_t frameCount{4};
  Lacing lacing{Lacing::Fixed};
  std::vector<std::size_t> sizes;
};

std::vector<AudioBlockPlan> audioLacingCycle() {
  return {{4, Lacing::Fixed, {5, 5, 5, 5}},
          {4, Lacing::Xiph, {3, 4, 5, 6}},
          {3, Lacing::Ebml, {7, 6, 8}},
          {1, Lacing::None, {9}}};
}

Fixture buildFixture(const FixtureSpec& spec) {
  std::uint8_t fill = 1;
  Fixture fixture;

  Bytes infoPayload;
  append(infoPayload,
         uintElement(kTimestampScaleId, kTimestampScaleNanoseconds));
  append(infoPayload, doubleElement(kDurationId, spec.durationTicks));
  const Bytes infoElement = element(kInfoId, infoPayload);

  Bytes trackEntries;
  if (spec.includeVideoTrack) {
    append(trackEntries, videoTrackEntry(spec));
  }
  if (spec.includeAudioTrack) {
    append(trackEntries, audioTrackEntry(spec));
  }
  if (spec.includeSubtitleTrack) {
    append(trackEntries, subtitleTrackEntry());
  }

  std::vector<std::vector<BuiltBlock>> clusterBlocks(
      spec.clusterTimestamps.size());
  if (spec.includeVideoTrack) {
    const auto plans = videoBlockPlans(spec);
    for (std::size_t index = 0; index < spec.clusterTimestamps.size();
         ++index) {
      const std::uint64_t base = spec.clusterTimestamps[index];
      for (const VideoBlockPlan& plan : plans) {
        const std::int64_t tick =
            static_cast<std::int64_t>(base) + plan.relative;
        const bool realKeyframe =
            plan.keyFrame && !spec.videoKeyframePayload.empty();
        const std::array<std::size_t, 1> sizes{
            realKeyframe ? spec.videoKeyframePayload.size()
                         : plan.frameBytes};
        BuiltBlock block =
            plan.simple
                ? buildSimpleBlock(spec.videoTrackNumber, tick,
                                   static_cast<std::int16_t>(plan.relative),
                                   plan.keyFrame, plan.invisible,
                                   plan.discardable, Lacing::None, sizes,
                                   fill)
                : buildBlockGroup(spec.videoTrackNumber, tick,
                                  static_cast<std::int16_t>(plan.relative),
                                  plan.references, plan.durationTicks,
                                  plan.invisible, Lacing::None, sizes, fill);
        if (realKeyframe) {
          // Frame ranges are still Block-relative here; buildCluster shifts
          // them once the Block is placed.
          std::copy(spec.videoKeyframePayload.begin(),
                    spec.videoKeyframePayload.end(),
                    block.bytes.begin() +
                        static_cast<std::ptrdiff_t>(block.frames[0].offset));
        }
        block.video = true;
        clusterBlocks[index].push_back(std::move(block));
      }
    }
  }
  if (spec.includeAudioTrack) {
    const auto cycle = audioLacingCycle();
    std::uint64_t ordinal = 0;
    std::size_t patternIndex = 0;
    while (true) {
      const auto tick = nearestMatroskaTick(
          {MediaTime{0, 1}, ordinal, kAudioSampleRate},
          kTimestampScaleNanoseconds);
      if (!tick ||
          static_cast<double>(*tick) >= spec.durationTicks) {
        break;
      }
      std::size_t cluster = 0;
      for (std::size_t index = 0; index < spec.clusterTimestamps.size();
           ++index) {
        if (static_cast<std::int64_t>(spec.clusterTimestamps[index]) <=
            *tick) {
          cluster = index;
        }
      }
      const AudioBlockPlan& plan = cycle[patternIndex % cycle.size()];
      const std::int64_t relative =
          *tick - static_cast<std::int64_t>(spec.clusterTimestamps[cluster]);
      BuiltBlock block = buildSimpleBlock(
          spec.audioTrackNumber, *tick, static_cast<std::int16_t>(relative),
          true, false, false, plan.lacing, plan.sizes, fill);
      block.video = false;
      block.firstOrdinal = ordinal;
      clusterBlocks[cluster].push_back(std::move(block));
      ordinal += plan.frameCount;
      ++patternIndex;
    }
  }

  std::vector<BuiltCluster> clusters;
  clusters.reserve(spec.clusterTimestamps.size());
  for (std::size_t index = 0; index < spec.clusterTimestamps.size();
       ++index) {
    std::stable_sort(clusterBlocks[index].begin(), clusterBlocks[index].end(),
                     [](const BuiltBlock& lhs, const BuiltBlock& rhs) {
                       return lhs.tick < rhs.tick;
                     });
    clusters.push_back(buildCluster(spec.clusterTimestamps[index],
                                    std::move(clusterBlocks[index]),
                                    spec.voidPaddingBytes));
  }

  Bytes segmentPayload = infoElement;
  if (!trackEntries.empty()) {
    append(segmentPayload, element(kTracksId, trackEntries));
  }
  std::vector<std::uint64_t> clusterRelativeOffsets;
  for (const BuiltCluster& cluster : clusters) {
    if (spec.voidPaddingBytes != 0) {
      append(segmentPayload,
             element(kVoidId, Bytes(spec.voidPaddingBytes, std::byte{0})));
    }
    clusterRelativeOffsets.push_back(
        static_cast<std::uint64_t>(segmentPayload.size()));
    append(segmentPayload, cluster.bytes);
  }

  std::vector<CuePointSpec> cuePoints;
  if (spec.cues != CueVariant::Absent) {
    for (std::size_t index = 0; index < clusters.size(); ++index) {
      const BuiltCluster& cluster = clusters[index];
      const BuiltBlock* keyBlock = nullptr;
      const BuiltBlock* laterBlock = nullptr;
      const BuiltBlock* audioBlock = nullptr;
      for (const BuiltBlock& block : cluster.blocks) {
        if (!block.video) {
          if (audioBlock == nullptr) {
            audioBlock = &block;
          }
          continue;
        }
        if (block.keyFrame && keyBlock == nullptr) {
          keyBlock = &block;
        } else if (!block.keyFrame && laterBlock == nullptr) {
          laterBlock = &block;
        }
      }
      if (keyBlock == nullptr) {
        continue;
      }
      const BuiltBlock* target = keyBlock;
      if (spec.cues == CueVariant::NonKeyFrameTarget && laterBlock != nullptr) {
        target = laterBlock;
      } else if (spec.cues == CueVariant::AudioTrackOnly &&
                 audioBlock != nullptr) {
        target = audioBlock;
      }
      CuePointSpec point;
      // CueTime always names the Cluster's random access point so that an
      // index variant changes exactly one fact at a time.
      point.time = static_cast<std::uint64_t>(keyBlock->tick);
      point.track = spec.cues == CueVariant::AudioTrackOnly
                        ? spec.audioTrackNumber
                        : spec.videoTrackNumber;
      point.clusterPosition = clusterRelativeOffsets[index];
      point.relativePosition =
          target->containerOffset - cluster.dataOffset;
      point.blockNumber = 1;
      if (spec.cues == CueVariant::NoRelativePosition) {
        point.relativePosition.reset();
      }
      if (spec.cues == CueVariant::BlockNumberTwo) {
        point.blockNumber = 2;
      }
      if (spec.cues == CueVariant::OutsideCluster) {
        point.clusterPosition = clusterRelativeOffsets[index] + 1U;
      }
      cuePoints.push_back(point);
    }
    if (spec.cues == CueVariant::NonZeroFirst && !cuePoints.empty()) {
      cuePoints.erase(cuePoints.begin());
    }
    if (spec.cues == CueVariant::Unsorted && cuePoints.size() >= 3) {
      std::swap(cuePoints[1], cuePoints[2]);
    }
    if (spec.cues == CueVariant::DuplicateTime && cuePoints.size() >= 2) {
      cuePoints[1].time = cuePoints[0].time;
    }
    append(segmentPayload, cuesElement(cuePoints));
  }

  fixture.bytes = ebmlHeader(spec.docType);
  const Bytes segmentElement = element(kSegmentId, segmentPayload);
  const auto segmentPrefix =
      static_cast<std::uint64_t>(segmentElement.size() - segmentPayload.size());
  fixture.segmentDataOffset =
      static_cast<std::uint64_t>(fixture.bytes.size()) + segmentPrefix;
  append(fixture.bytes, segmentElement);

  for (std::size_t index = 0; index < clusters.size(); ++index) {
    const BuiltCluster& cluster = clusters[index];
    const std::uint64_t base =
        fixture.segmentDataOffset + clusterRelativeOffsets[index];
    fixture.clusterEncodedOffsets.push_back(base);
    fixture.clusterDataOffsets.push_back(base + cluster.dataOffset);
    fixture.clusterTimestamps.push_back(cluster.timestamp);
    for (const BuiltBlock& block : cluster.blocks) {
      BlockFacts facts;
      facts.containerOffset = base + block.containerOffset;
      facts.clusterIndex = static_cast<std::uint32_t>(index);
      facts.tick = block.tick;
      facts.firstOrdinal = block.firstOrdinal;
      facts.frameCount = block.frameCount;
      facts.keyFrame = block.keyFrame;
      facts.invisible = block.invisible;
      facts.discardable = block.discardable;
      facts.durationTicks = block.durationTicks;
      for (const ByteRange frame : block.frames) {
        facts.frames.push_back(ByteRange{base + frame.offset, frame.size});
      }
      if (block.video) {
        fixture.videoBlocks.push_back(std::move(facts));
      } else {
        fixture.audioBlocks.push_back(std::move(facts));
      }
    }
  }
  for (const CuePointSpec& point : cuePoints) {
    fixture.cueTicks.push_back(point.time);
  }
  return fixture;
}

// A minimal-but-valid document whose Cluster count is caller controlled. The
// clusters carry only their mandatory Timestamp so an over-cap directory costs
// seven bytes per entry instead of a real payload.
Bytes buildMinimalClusterDocument(std::size_t clusterCount) {
  FixtureSpec spec;
  spec.includeAudioTrack = false;
  spec.includeSubtitleTrack = false;
  Bytes segmentPayload;
  Bytes infoPayload;
  append(infoPayload,
         uintElement(kTimestampScaleId, kTimestampScaleNanoseconds));
  append(infoPayload, doubleElement(kDurationId, 1000.0));
  append(segmentPayload, element(kInfoId, infoPayload));
  append(segmentPayload, element(kTracksId, videoTrackEntry(spec)));
  const Bytes cluster = element(kClusterId, uintElement(kClusterTimestampId, 0));
  for (std::size_t index = 0; index < clusterCount; ++index) {
    append(segmentPayload, cluster);
  }
  Bytes bytes = ebmlHeader();
  append(bytes, element(kSegmentId, segmentPayload));
  return bytes;
}

// One real Cluster plus a caller-controlled number of CuePoints that name it
// without a CueRelativePosition, so the Cue cap is reached without payloads.
Bytes buildRepeatedCueDocument(std::size_t cueCount) {
  FixtureSpec spec;
  spec.includeAudioTrack = false;
  spec.includeSubtitleTrack = false;
  Bytes segmentPayload;
  Bytes infoPayload;
  append(infoPayload,
         uintElement(kTimestampScaleId, kTimestampScaleNanoseconds));
  append(infoPayload, doubleElement(kDurationId, 1000.0));
  append(segmentPayload, element(kInfoId, infoPayload));
  append(segmentPayload, element(kTracksId, videoTrackEntry(spec)));
  const auto clusterPosition =
      static_cast<std::uint64_t>(segmentPayload.size());
  append(segmentPayload,
         element(kClusterId, uintElement(kClusterTimestampId, 0)));
  std::vector<CuePointSpec> points;
  points.reserve(cueCount);
  for (std::size_t index = 0; index < cueCount; ++index) {
    CuePointSpec point;
    point.time = index;
    point.track = 1;
    point.clusterPosition = clusterPosition;
    points.push_back(point);
  }
  append(segmentPayload, cuesElement(points));
  Bytes bytes = ebmlHeader();
  append(bytes, element(kSegmentId, segmentPayload));
  return bytes;
}

// ---------------------------------------------------------------------------
// Readers and cancellation seams.
// ---------------------------------------------------------------------------

class ProbeReader final : public SeekableByteReader {
 public:
  explicit ProbeReader(Bytes bytes)
      : bytes_(std::move(bytes)),
        reportedSize_(static_cast<std::uint64_t>(bytes_.size())) {}

  [[nodiscard]] std::uint64_t size() const noexcept override {
    return reportedSize_;
  }

  [[nodiscard]] bool
  readAt(std::uint64_t offset,
         std::span<std::byte> destination) noexcept override {
    ++reads;
    readOffsets.push_back(offset);
    readSizes.push_back(destination.size());
    totalRead += destination.size();
    maximumRead = std::max(maximumRead, destination.size());
    if (failAtRead != 0 && reads >= failAtRead) {
      return false;
    }
    if (offset > bytes_.size() ||
        destination.size() > bytes_.size() - offset) {
      return false;
    }
    std::copy_n(bytes_.begin() + static_cast<std::ptrdiff_t>(offset),
                destination.size(), destination.begin());
    if (cancelAtRead != 0 && reads >= cancelAtRead && cancellation != nullptr) {
      cancellation->store(true, std::memory_order_release);
    }
    if (shrinkAtRead != 0 && reads == shrinkAtRead) {
      reportedSize_ -= 1U;
    }
    if (growAtRead != 0 && reads == growAtRead) {
      reportedSize_ += 1U;
    }
    return true;
  }

  void shrink() noexcept { reportedSize_ -= 1U; }
  void grow() noexcept { reportedSize_ += 1U; }
  void restore() noexcept {
    reportedSize_ = static_cast<std::uint64_t>(bytes_.size());
  }
  [[nodiscard]] const Bytes& bytes() const noexcept { return bytes_; }

  std::size_t reads{0};
  std::size_t totalRead{0};
  std::size_t maximumRead{0};
  std::size_t failAtRead{0};
  std::size_t cancelAtRead{0};
  std::size_t shrinkAtRead{0};
  std::size_t growAtRead{0};
  std::vector<std::uint64_t> readOffsets;
  std::vector<std::size_t> readSizes;
  std::atomic<bool>* cancellation{nullptr};

 private:
  Bytes bytes_;
  std::uint64_t reportedSize_{0};
};

// Serves real bytes for a few explicit chunks and zeros elsewhere. It exists
// so the 64 MiB structural Cluster/Block ceilings can be proven without
// allocating 64 MiB: the parser only reads element headers and then skips the
// declared payload, so the virtual region is never interpreted.
class SparseReader final : public SeekableByteReader {
 public:
  SparseReader(std::uint64_t reportedSize,
               std::vector<std::pair<std::uint64_t, Bytes>> chunks)
      : chunks_(std::move(chunks)), size_(reportedSize) {}

  [[nodiscard]] std::uint64_t size() const noexcept override { return size_; }

  [[nodiscard]] bool
  readAt(std::uint64_t offset,
         std::span<std::byte> destination) noexcept override {
    if (offset > size_ || destination.size() > size_ - offset) {
      return false;
    }
    std::fill(destination.begin(), destination.end(), std::byte{0});
    for (const auto& chunk : chunks_) {
      const std::uint64_t chunkEnd =
          chunk.first + static_cast<std::uint64_t>(chunk.second.size());
      const std::uint64_t readEnd =
          offset + static_cast<std::uint64_t>(destination.size());
      const std::uint64_t begin = std::max(offset, chunk.first);
      const std::uint64_t end = std::min(readEnd, chunkEnd);
      for (std::uint64_t position = begin; position < end; ++position) {
        destination[static_cast<std::size_t>(position - offset)] =
            chunk.second[static_cast<std::size_t>(position - chunk.first)];
      }
    }
    return true;
  }

 private:
  std::vector<std::pair<std::uint64_t, Bytes>> chunks_;
  std::uint64_t size_{0};
};

bool atomicCancellation(const void* context) noexcept {
  return static_cast<const std::atomic<bool>*>(context)->load(
      std::memory_order_acquire);
}

const std::filesystem::path kFixturePath{"/private/tmp/wam-demuxer-fixture.mkv"};

struct PreparedFixture {
  Fixture fixture;
  std::shared_ptr<ProbeReader> reader;
  MatroskaPrepareOutcome outcome;

  [[nodiscard]] const MatroskaPreparedAsset& asset() const noexcept {
    return *outcome.asset;
  }
};

PreparedFixture prepareFixture(const FixtureSpec& spec,
                               const MediaSourceOpenOptions& options = {}) {
  PreparedFixture prepared;
  prepared.fixture = buildFixture(spec);
  prepared.reader = std::make_shared<ProbeReader>(prepared.fixture.bytes);
  prepared.outcome =
      prepareMatroska(prepared.reader, kFixturePath, options);
  return prepared;
}

MediaTime reducedTime(std::uint64_t numerator, std::uint64_t denominator) {
  const std::uint64_t divisor = std::gcd(numerator, denominator);
  return MediaTime{static_cast<std::int64_t>(numerator / divisor),
                   static_cast<std::int32_t>(denominator / divisor)};
}

MediaTime tickTime(std::int64_t tick) {
  return reducedTime(static_cast<std::uint64_t>(tick) *
                         kTimestampScaleNanoseconds,
                     1'000'000'000U);
}

MediaTime audioGridTime(std::uint64_t ordinal) {
  return reducedTime(ordinal * 1024U, kAudioSampleRate);
}

const char* errorName(MatroskaDemuxError error) {
  switch (error) {
  case MatroskaDemuxError::None:
    return "None";
  case MatroskaDemuxError::InvalidRequest:
    return "InvalidRequest";
  case MatroskaDemuxError::InvalidContainer:
    return "InvalidContainer";
  case MatroskaDemuxError::UnsupportedContainer:
    return "UnsupportedContainer";
  case MatroskaDemuxError::TrackSelection:
    return "TrackSelection";
  case MatroskaDemuxError::UnsupportedTrack:
    return "UnsupportedTrack";
  case MatroskaDemuxError::CodecConfiguration:
    return "CodecConfiguration";
  case MatroskaDemuxError::InvalidTimeline:
    return "InvalidTimeline";
  case MatroskaDemuxError::MissingCues:
    return "MissingCues";
  case MatroskaDemuxError::InvalidCue:
    return "InvalidCue";
  case MatroskaDemuxError::IndexLimit:
    return "IndexLimit";
  case MatroskaDemuxError::SampleLimit:
    return "SampleLimit";
  case MatroskaDemuxError::FileChanged:
    return "FileChanged";
  case MatroskaDemuxError::Io:
    return "Io";
  case MatroskaDemuxError::Cancelled:
    return "Cancelled";
  }
  return "?";
}

// A WebM-shaped VP9 track: 1920x1080, no CodecPrivate, and every random access
// point carrying the repository sample's real VP9 uncompressed frame header.
FixtureSpec vp9FixtureSpec() {
  FixtureSpec spec;
  spec.videoCodecId = "V_VP9";
  spec.includeVideoCodecPrivate = false;
  spec.videoKeyframePayload = fromOctets(kSampleVp9Keyframe);
  spec.videoPixelWidth = kSampleCodecEnvelopeWidth;
  spec.videoPixelHeight = kSampleCodecEnvelopeHeight;
  return spec;
}

// A WebM-shaped VP8 track: 1920x1080, no CodecPrivate (RFC 6386 defines none),
// and every random access point carrying a real VP8 key frame header.
FixtureSpec vp8FixtureSpec() {
  FixtureSpec spec;
  spec.videoCodecId = "V_VP8";
  spec.includeVideoCodecPrivate = false;
  spec.videoKeyframePayload = fromOctets(kSampleVp8Keyframe);
  spec.videoPixelWidth = kSampleCodecEnvelopeWidth;
  spec.videoPixelHeight = kSampleCodecEnvelopeHeight;
  return spec;
}

// An ffmpeg-shaped MPEG-4 Part 2 track: 1920x1080, the raw VisualObjectSequence
// in CodecPrivate. ffmpeg writes V_MPEG4/ISO/ASP for Simple Profile too, which
// is exactly why the CodecID cannot be the profile gate.
FixtureSpec mpeg4VisualFixtureSpec() {
  FixtureSpec spec;
  spec.videoCodecId = "V_MPEG4/ISO/ASP";
  spec.videoCodecPrivate = fromOctets(kSampleMpeg4SimpleProfile);
  spec.videoPixelWidth = kSampleCodecEnvelopeWidth;
  spec.videoPixelHeight = kSampleCodecEnvelopeHeight;
  return spec;
}

FixtureSpec av1FixtureSpec() {
  FixtureSpec spec;
  spec.videoCodecId = "V_AV1";
  spec.videoCodecPrivate = fromOctets(kSampleAv1C);
  spec.videoPixelWidth = kSampleCodecEnvelopeWidth;
  spec.videoPixelHeight = kSampleCodecEnvelopeHeight;
  return spec;
}

void expectPrepareError(const FixtureSpec& spec, MatroskaDemuxError expected,
                        const char* message) {
  const PreparedFixture prepared = prepareFixture(spec);
  const bool matched = prepared.outcome.asset == nullptr &&
                       prepared.outcome.error == expected &&
                       prepared.outcome.status != MatroskaDemuxStatus::Ready;
  if (!matched) {
    std::cerr << "  (observed " << errorName(prepared.outcome.error)
              << ", expected " << errorName(expected) << ")\n";
  }
  expect(matched, message);
}

// ---------------------------------------------------------------------------
// 1. Complete synthetic document preparation.
// ---------------------------------------------------------------------------

void testCompleteDocumentPreparation() {
  const PreparedFixture prepared = prepareFixture({});
  expect(prepared.outcome.status == MatroskaDemuxStatus::Ready &&
             prepared.outcome.error == MatroskaDemuxError::None &&
             prepared.outcome.asset != nullptr,
         "complete synthetic Matroska document prepares Ready");
  if (prepared.outcome.asset == nullptr) {
    std::cerr << "  (" << prepared.outcome.message << ")\n";
    return;
  }
  const MatroskaPreparedAsset& asset = prepared.asset();
  const Fixture& fixture = prepared.fixture;

  expect(asset.path() == kFixturePath &&
             asset.timestampScaleNanoseconds() == kTimestampScaleNanoseconds,
         "prepared asset retains its path identity and TimestampScale");

  const auto descriptor = asset.descriptor();
  expect(descriptor != nullptr && descriptor->duration == MediaTime{3, 2},
         "Duration 1500 ticks at 1 ms scale is the exact rational 3/2 s");
  if (descriptor == nullptr) {
    return;
  }
  expect(descriptor->inventory.video == 1 && descriptor->inventory.audio == 1 &&
             descriptor->inventory.subtitle == 1 &&
             descriptor->inventory.total == 3 &&
             descriptor->tracks.size() == 2,
         "track inventory counts every TrackEntry but details only selections");
  expect(descriptor->selectedVideo == 1 && descriptor->selectedAudio == 2 &&
             !descriptor->selectedSubtitle,
         "default selection admits the first video and audio tracks");

  const auto* video = wam::media::findMediaTrack(*descriptor, 1);
  expect(video != nullptr, "selected video descriptor is present");
  if (video != nullptr) {
    expect(video->kind == MediaTrackKind::Video &&
               video->codec == MediaCodec::H264 &&
               video->codecConfigurationKind ==
                   MediaCodecConfigurationKind::AvcC &&
               video->codecConfiguration.size() == kSampleAvcC.size(),
           "video track publishes its exact avcC configuration bytes");
    expect(video->timeBase == MediaTime{1, 1'000'000'000} &&
               video->duration == MediaTime{3, 2} && video->language == "und",
           "video track carries a nanosecond time base and container language");
    expect(video->video && video->video->codedWidth == kSampleAvcWidth &&
               video->video->codedHeight == kSampleAvcHeight &&
               video->video->displayWidth == kSampleAvcWidth &&
               video->video->displayHeight == kSampleAvcHeight &&
               video->video->progressive &&
               video->video->sampleFormat ==
                   MediaVideoSampleFormat::Yuv420EightBit,
           "video format comes from the SPS and matches PixelWidth/Height");
    expect(video->video &&
               video->video->colorPrimaries == MediaColorPrimaries::Bt709 &&
               video->video->transferFunction == MediaTransferFunction::Bt709 &&
               video->video->matrixCoefficients ==
                   MediaMatrixCoefficients::Bt709,
           "container Colour BT.709 triple is admitted exactly");
  }

  const auto* audio = wam::media::findMediaTrack(*descriptor, 2);
  expect(audio != nullptr, "selected audio descriptor is present");
  if (audio != nullptr) {
    expect(audio->kind == MediaTrackKind::Audio &&
               audio->codec == MediaCodec::Aac &&
               audio->codecConfigurationKind ==
                   MediaCodecConfigurationKind::AudioMagicCookie &&
               !audio->codecConfiguration.empty(),
           "audio track publishes an ES_Descriptor magic cookie, not the ASC");
    expect(audio->timeBase ==
               MediaTime{1, static_cast<std::int32_t>(kAudioSampleRate)} &&
               audio->audio &&
               audio->audio->sampleRate ==
                   static_cast<double>(kAudioSampleRate) &&
               audio->audio->channels == 2 &&
               audio->audio->framesPerPacket == kAacLcSamplesPerAccessUnit &&
               audio->audio->channelLayoutPresent,
           "AAC-LC audio format is exact: 48 kHz stereo, 1024 frames/packet");
  }

  expect(fixture.clusterEncodedOffsets.size() == 3U &&
             fixture.videoBlocks.size() == 15U &&
             fixture.audioBlocks.size() == 23U && fixture.cueTicks.size() == 3U,
         "the canonical fixture holds 3 clusters, 15 video and 23 AAC blocks");
  expect(asset.clusters().size() == fixture.clusterEncodedOffsets.size(),
         "cluster directory holds exactly one entry per Cluster");
  bool clustersExact = asset.clusters().size() ==
                       fixture.clusterEncodedOffsets.size();
  for (std::size_t index = 0;
       clustersExact && index < asset.clusters().size(); ++index) {
    const MatroskaClusterIndexEntry& entry = asset.clusters()[index];
    clustersExact =
        entry.encodedOffset == fixture.clusterEncodedOffsets[index] &&
        entry.timestampTick == fixture.clusterTimestamps[index] &&
        entry.dataRange().offset == fixture.clusterDataOffsets[index] &&
        !entry.unknownSize() &&
        entry.encodedRange().offset + entry.encodedRange().size <=
            fixture.bytes.size();
  }
  expect(clustersExact,
         "cluster index entries carry exact encoded/data ranges and ticks");

  expect(asset.cues().size() == fixture.cueTicks.size() &&
             !asset.cues().empty() && asset.cues().front().timestampTick == 0,
         "selected-video cue index is populated and begins at tick zero");
  bool cuesExact = asset.cues().size() == fixture.cueTicks.size();
  for (std::size_t index = 0; cuesExact && index < asset.cues().size();
       ++index) {
    const MatroskaCueIndexEntry& cue = asset.cues()[index];
    const std::uint64_t blockOffset =
        asset.clusters()[cue.clusterIndex].dataRange().offset +
        cue.relativeBlockOffset;
    const BlockFacts* block = fixture.videoBlockAt(blockOffset);
    cuesExact = cue.timestampTick == fixture.cueTicks[index] &&
                cue.clusterIndex == index && block != nullptr &&
                block->keyFrame &&
                block->tick == static_cast<std::int64_t>(cue.timestampTick);
    if (cuesExact && index != 0) {
      cuesExact = asset.cues()[index - 1].timestampTick < cue.timestampTick &&
                  asset.cues()[index - 1].clusterIndex <= cue.clusterIndex;
    }
  }
  expect(cuesExact,
         "cue entries are strictly increasing and resolve to key-frame blocks");

  expect(prepared.reader->maximumRead <= ParseOptions::kHardMaximumReadBytes,
         "preparation never issues a read larger than 64 KiB");
}

void testPreparationRequestValidation() {
  const Fixture fixture = buildFixture({});
  const MediaSourceOpenOptions options;
  const auto nullOutcome =
      prepareMatroska(nullptr, kFixturePath, options);
  expect(nullOutcome.error == MatroskaDemuxError::InvalidRequest &&
             nullOutcome.asset == nullptr,
         "a null reader is rejected as an invalid request");

  auto reader = std::make_shared<ProbeReader>(fixture.bytes);
  const auto emptyPath = prepareMatroska(reader, {}, options);
  expect(emptyPath.error == MatroskaDemuxError::InvalidRequest,
         "an empty path identity is rejected as an invalid request");

  auto emptyReader = std::make_shared<ProbeReader>(Bytes{});
  expect(prepareMatroska(emptyReader, kFixturePath, options).error ==
             MatroskaDemuxError::InvalidRequest,
         "a zero-length reader is rejected as an invalid request");

  MediaSourceOpenOptions negative;
  negative.initialPosition = {MediaTime{-1, 1'000}, MediaSeekMode::Accurate};
  auto negativeReader = std::make_shared<ProbeReader>(fixture.bytes);
  expect(prepareMatroska(negativeReader, kFixturePath, negative).error ==
             MatroskaDemuxError::InvalidRequest,
         "a negative initial position is rejected before any I/O");

  MediaSourceOpenOptions accepted;
  accepted.initialPosition = {MediaTime{1, 2}, MediaSeekMode::KeyFrame};
  auto acceptedReader = std::make_shared<ProbeReader>(fixture.bytes);
  const auto positioned =
      prepareMatroska(acceptedReader, kFixturePath, accepted);
  expect(positioned.status == MatroskaDemuxStatus::Ready,
         "a representable initial position is planned during preparation");

  MediaSourceOpenOptions beyond;
  beyond.initialPosition = {MediaTime{3, 2}, MediaSeekMode::Accurate};
  auto beyondReader = std::make_shared<ProbeReader>(fixture.bytes);
  const auto rejected = prepareMatroska(beyondReader, kFixturePath, beyond);
  expect(rejected.asset == nullptr &&
             rejected.error == MatroskaDemuxError::InvalidTimeline,
         "an initial position at the duration fails preparation closed");
}

// ---------------------------------------------------------------------------
// 2. Bounded cluster and cue indexes.
// ---------------------------------------------------------------------------

void testBoundedIndexes() {
  {
    auto reader = std::make_shared<ProbeReader>(
        buildMinimalClusterDocument(kMaximumMatroskaClusters));
    const auto outcome = prepareMatroska(reader, kFixturePath, {});
    // The directory itself is admitted at the cap; the document then fails
    // only because these minimal clusters carry no Cues.
    expect(outcome.error == MatroskaDemuxError::MissingCues,
           "exactly 65,536 clusters stay inside the bounded directory");
  }
  {
    auto reader = std::make_shared<ProbeReader>(
        buildMinimalClusterDocument(kMaximumMatroskaClusters + 1U));
    const auto outcome = prepareMatroska(reader, kFixturePath, {});
    expect(outcome.asset == nullptr &&
               outcome.error == MatroskaDemuxError::IndexLimit,
           "65,537 clusters are rejected with IndexLimit");
  }
  {
    auto reader = std::make_shared<ProbeReader>(buildMinimalClusterDocument(0));
    const auto outcome = prepareMatroska(reader, kFixturePath, {});
    expect(outcome.asset == nullptr &&
               outcome.error == MatroskaDemuxError::IndexLimit,
           "a Segment without any Cluster is rejected with IndexLimit");
  }
  {
    auto reader = std::make_shared<ProbeReader>(
        buildRepeatedCueDocument(kMaximumMatroskaCues));
    const auto outcome = prepareMatroska(reader, kFixturePath, {});
    expect(outcome.asset == nullptr &&
               outcome.error == MatroskaDemuxError::InvalidCue,
           "65,536 cues parse and then fail on their missing relative position");
  }
  {
    auto reader = std::make_shared<ProbeReader>(
        buildRepeatedCueDocument(kMaximumMatroskaCues + 1U));
    const auto outcome = prepareMatroska(reader, kFixturePath, {});
    expect(outcome.asset == nullptr &&
               outcome.error == MatroskaDemuxError::IndexLimit,
           "65,537 cues are rejected with IndexLimit");
  }
  static_assert(sizeof(MatroskaClusterIndexEntry) == 24U);
  static_assert(sizeof(MatroskaCueIndexEntry) == 16U);
  static_assert(kMaximumMatroskaClusters * sizeof(MatroskaClusterIndexEntry) +
                    kMaximumMatroskaCues * sizeof(MatroskaCueIndexEntry) <=
                3U * 1024U * 1024U);
}

// ---------------------------------------------------------------------------
// 3. Exact selected-codec admission and track selection.
// ---------------------------------------------------------------------------

void testCodecAdmissionAndSelection() {
  {
    FixtureSpec spec;
    spec.videoCodecId = "V_MPEGH/ISO/HEVC";
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "an avcC record under an HEVC CodecID is not admitted");
  }
  {
    // V_VP9 is an admitted CodecID now, so an avcC under it is a codec
    // configuration verdict rather than a track-selection one; nothing in the
    // Block payloads is a VP9 keyframe header either.
    FixtureSpec spec;
    spec.videoCodecId = "V_VP9";
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "a VP9 track whose blocks are not VP9 is not admitted");
  }
  {
    // MPEG-4 Part 2 Simple Profile. The Matroska CodecPrivate is the raw
    // VisualObjectSequence; what the descriptor publishes is the esds
    // CoreMedia needs, synthesized from it -- the same move VP8 and VP9 make
    // with their vpcC.
    const PreparedFixture prepared = prepareFixture(mpeg4VisualFixtureSpec());
    expect(prepared.outcome.status == MatroskaDemuxStatus::Ready &&
               prepared.outcome.asset != nullptr,
           "an MPEG-4 Part 2 Simple Profile track is admitted");
    if (prepared.outcome.asset != nullptr) {
      const wam::media::MediaTrackDescriptor& video =
          prepared.outcome.asset->descriptor()->tracks.front();
      expect(video.codec == MediaCodec::Mpeg4Visual &&
                 video.codecConfigurationKind ==
                     MediaCodecConfigurationKind::CodecPrivate,
             "MPEG-4 Part 2 admission names the CodecPrivate record kind");
      expect(video.codecConfiguration.size() ==
                 wam::media::kMpeg4VisualEsdsOverheadBytes +
                     kSampleMpeg4SimpleProfile.size(),
             "MPEG-4 Part 2 admission publishes a synthesized esds");
      // The headers must survive byte for byte inside the descriptor: they are
      // the DecoderSpecificInfo VideoToolbox actually parses.
      expect(video.codecConfiguration.size() >
                     kSampleMpeg4SimpleProfile.size() + 6U &&
                 std::equal(kSampleMpeg4SimpleProfile.begin(),
                            kSampleMpeg4SimpleProfile.end(),
                            video.codecConfiguration.end() -
                                static_cast<std::ptrdiff_t>(
                                    kSampleMpeg4SimpleProfile.size()) -
                                6,
                            video.codecConfiguration.end() - 6,
                            [](std::uint8_t lhs, std::byte rhs) {
                              return static_cast<std::byte>(lhs) == rhs;
                            }),
             "the synthesized esds carries the headers byte for byte");
      expect(video.video &&
                 video.video->codedWidth == kSampleCodecEnvelopeWidth &&
                 video.video->codedHeight == kSampleCodecEnvelopeHeight &&
                 video.video->bitsPerComponent == 8U &&
                 video.video->sampleFormat ==
                     MediaVideoSampleFormat::Yuv420EightBit,
             "MPEG-4 Part 2 video format comes from the VideoObjectLayer");
    }
  }
  {
    // V_MPEG4/ISO/SP is the CodecID Matroska defines for Simple Profile. No
    // ffmpeg build this project has seen writes it, but the spec allows it and
    // the same headers must be admitted under it.
    FixtureSpec spec = mpeg4VisualFixtureSpec();
    spec.videoCodecId = "V_MPEG4/ISO/SP";
    const PreparedFixture prepared = prepareFixture(spec);
    expect(prepared.outcome.status == MatroskaDemuxStatus::Ready &&
               prepared.outcome.asset != nullptr,
           "the V_MPEG4/ISO/SP CodecID is admitted for the same headers");
  }
  {
    // THE REFUSAL, at the container boundary. Advanced Simple Profile is every
    // Xvid/DivX-era file. VideoToolbox refuses it at session creation with
    // codecBadDataErr (-8969) -- measured 2026-08-20, and reproduced by
    // AVFoundation itself on a plain mp4v MP4 -- so it is refused here as a
    // codec-configuration verdict, which falls back cleanly rather than
    // failing an open.
    FixtureSpec spec = mpeg4VisualFixtureSpec();
    spec.videoCodecPrivate = fromOctets(kSampleMpeg4AdvancedSimple);
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "an Advanced Simple Profile MPEG-4 Part 2 track is not "
                       "admitted");
  }
  {
    // The headers are the only fact source, so a track without them cannot be
    // admitted no matter what the CodecID claims.
    FixtureSpec spec = mpeg4VisualFixtureSpec();
    spec.includeVideoCodecPrivate = false;
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "an MPEG-4 Part 2 track without CodecPrivate is not "
                       "admitted");
  }
  {
    // The VideoObjectLayer's own dimensions must agree with the container's,
    // exactly as they must for every other codec.
    FixtureSpec spec = mpeg4VisualFixtureSpec();
    spec.videoPixelWidth = 1280;
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "an MPEG-4 Part 2 track whose PixelWidth disagrees with "
                       "its VideoObjectLayer is not admitted");
  }
  {
    // V_MS/VFW/FOURCC is the old AVI-remux carriage for DivX/Xvid. Its
    // CodecPrivate is a BITMAPINFOHEADER rather than a VisualObjectSequence,
    // and the payload it wraps is Advanced Simple or MS-MPEG-4 v3, so the
    // CodecID is deliberately never selected at all.
    FixtureSpec spec = mpeg4VisualFixtureSpec();
    spec.videoCodecId = "V_MS/VFW/FOURCC";
    expectPrepareError(spec, MatroskaDemuxError::TrackSelection,
                       "the VFW-wrapped DivX/Xvid CodecID is not admitted");
  }
  {
    // A WebM-shaped VP9 track: no CodecPrivate at all, facts proven from the
    // first keyframe's uncompressed header, and a vpcC synthesized from them
    // because VideoToolbox cannot open a VP9 session without one.
    FixtureSpec spec = vp9FixtureSpec();
    const PreparedFixture prepared = prepareFixture(spec);
    expect(prepared.outcome.status == MatroskaDemuxStatus::Ready &&
               prepared.outcome.asset != nullptr,
           "a VP9 track with no CodecPrivate is admitted from its bitstream");
    if (prepared.outcome.asset != nullptr) {
      const wam::media::MediaTrackDescriptor& video =
          prepared.outcome.asset->descriptor()->tracks.front();
      expect(video.codec == MediaCodec::Vp9 &&
                 video.codecConfigurationKind ==
                     MediaCodecConfigurationKind::VpcC &&
                 video.codecConfiguration.size() == kSampleVpcC.size(),
             "VP9 admission produces a twelve-byte synthesized vpcC");
      expect(std::equal(video.codecConfiguration.begin(),
                        video.codecConfiguration.end(), kSampleVpcC.begin(),
                        kSampleVpcC.end(),
                        [](std::byte lhs, std::uint8_t rhs) {
                          return lhs == static_cast<std::byte>(rhs);
                        }),
             "the synthesized vpcC matches the proven bitstream facts exactly");
      expect(video.video && video.video->codedWidth ==
                                kSampleCodecEnvelopeWidth &&
                 video.video->codedHeight == kSampleCodecEnvelopeHeight &&
                 video.video->bitsPerComponent == 8U &&
                 video.video->sampleFormat ==
                     MediaVideoSampleFormat::Yuv420EightBit,
             "VP9 video format comes from the proven keyframe header");
    }
  }
  {
    // The same stream with a real vpcC present: it is adopted byte-identically
    // rather than re-synthesized.
    FixtureSpec spec = vp9FixtureSpec();
    spec.includeVideoCodecPrivate = true;
    spec.videoCodecPrivate = fromOctets(kSampleVpcC);
    const PreparedFixture prepared = prepareFixture(spec);
    expect(prepared.outcome.status == MatroskaDemuxStatus::Ready &&
               prepared.outcome.asset != nullptr,
           "a VP9 track with a real vpcC is admitted");
    if (prepared.outcome.asset != nullptr) {
      const wam::media::MediaTrackDescriptor& video =
          prepared.outcome.asset->descriptor()->tracks.front();
      expect(std::equal(video.codecConfiguration.begin(),
                        video.codecConfiguration.end(), kSampleVpcC.begin(),
                        kSampleVpcC.end(),
                        [](std::byte lhs, std::uint8_t rhs) {
                          return lhs == static_cast<std::byte>(rhs);
                        }),
             "a present vpcC is adopted byte-identically");
    }
  }
  {
    // A vpcC that contradicts the bitstream describes a different stream.
    FixtureSpec spec = vp9FixtureSpec();
    spec.includeVideoCodecPrivate = true;
    auto contradicting = kSampleVpcC;
    contradicting[4] = 2U;    // profile 2
    contradicting[6] = 0xA2U; // 10-bit
    spec.videoCodecPrivate = fromOctets(contradicting);
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "a vpcC that contradicts the keyframe is not admitted");
  }
  {
    FixtureSpec spec = vp9FixtureSpec();
    spec.videoPixelWidth = 1280;
    expectPrepareError(
        spec, MatroskaDemuxError::CodecConfiguration,
        "PixelWidth must equal the VP9 bitstream's coded width exactly");
  }
  {
    FixtureSpec spec = vp9FixtureSpec();
    spec.videoKeyframePayload.clear();
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "VP9 with no readable keyframe header is not admitted");
  }
#if defined(WAM_ENABLE_SOFTWARE_VP8)
  {
    // A WebM-shaped VP8 track. RFC 6386 defines no configuration record at
    // all, so the facts come from the key frame header and a vpcC is
    // synthesized from them purely to keep VP8 inside the pipeline's
    // "codec configuration is nonempty and bounded" envelope.
    FixtureSpec spec = vp8FixtureSpec();
    const PreparedFixture prepared = prepareFixture(spec);
    expect(prepared.outcome.status == MatroskaDemuxStatus::Ready &&
               prepared.outcome.asset != nullptr,
           "a VP8 track with no CodecPrivate is admitted from its bitstream");
    if (prepared.outcome.asset != nullptr) {
      const wam::media::MediaTrackDescriptor& video =
          prepared.outcome.asset->descriptor()->tracks.front();
      expect(video.codec == MediaCodec::Vp8 &&
                 video.codecConfigurationKind ==
                     MediaCodecConfigurationKind::VpcC &&
                 video.codecConfiguration.size() == kSampleVpcC.size(),
             "VP8 admission produces a twelve-byte synthesized vpcC");
      // A VPCodecConfigurationBox describes vp08 and vp09 alike, and both are
      // profile 0, 8-bit, 4:2:0 co-located, narrow range and unspecified
      // colour here, so the same geometry yields byte-identical records. The
      // codec is distinguished by the sample entry, not by this box.
      expect(std::equal(video.codecConfiguration.begin(),
                        video.codecConfiguration.end(), kSampleVpcC.begin(),
                        kSampleVpcC.end(),
                        [](std::byte lhs, std::uint8_t rhs) {
                          return lhs == static_cast<std::byte>(rhs);
                        }),
             "the synthesized VP8 vpcC matches the proven bitstream facts");
      expect(video.video && video.video->codedWidth ==
                                kSampleCodecEnvelopeWidth &&
                 video.video->codedHeight == kSampleCodecEnvelopeHeight &&
                 video.video->bitsPerComponent == 8U &&
                 video.video->sampleFormat ==
                     MediaVideoSampleFormat::Yuv420EightBit,
             "VP8 video format comes from the proven key frame header");
      // The bitstream states no colour description at all (RFC 6386 has one
      // colour space and no primaries or transfer syntax), so the container's
      // Colour element -- which this fixture writes as the BT.709 triple -- is
      // the only thing that can describe it.
      expect(video.video->colorPrimaries == MediaColorPrimaries::Bt709 &&
                 video.video->transferFunction ==
                     MediaTransferFunction::Bt709 &&
                 video.video->matrixCoefficients ==
                     MediaMatrixCoefficients::Bt709,
             "VP8 colour comes from the container, never from the bitstream");
    }
  }
  {
    // VP8 has no configuration record, so a V_VP8 track that carries one
    // describes something this decoder cannot honour. Refusing it outright is
    // what keeps such a mux distinguishable from a conforming one.
    FixtureSpec spec = vp8FixtureSpec();
    spec.includeVideoCodecPrivate = true;
    spec.videoCodecPrivate = fromOctets(kSampleVpcC);
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "a VP8 track carrying a CodecPrivate is not admitted");
  }
  {
    FixtureSpec spec = vp8FixtureSpec();
    spec.videoPixelWidth = 1280;
    expectPrepareError(
        spec, MatroskaDemuxError::CodecConfiguration,
        "PixelWidth must equal the VP8 bitstream's coded width exactly");
  }
  {
    FixtureSpec spec = vp8FixtureSpec();
    spec.videoPixelHeight = 720;
    expectPrepareError(
        spec, MatroskaDemuxError::CodecConfiguration,
        "PixelHeight must equal the VP8 bitstream's coded height exactly");
  }
  {
    FixtureSpec spec = vp8FixtureSpec();
    spec.videoKeyframePayload.clear();
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "VP8 with no readable key frame header is not admitted");
  }
  {
    // The header is exactly ten bytes; a shorter random access point cannot
    // state a dimension and must fail closed rather than be extrapolated.
    FixtureSpec spec = vp8FixtureSpec();
    spec.videoKeyframePayload =
        fromOctets(std::span<const std::uint8_t>(kSampleVp8Keyframe).first(9));
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "a VP8 key frame shorter than its header is refused");
  }
  {
    // A V_VP8 CodecID over blocks that are not VP8 at all.
    FixtureSpec spec;
    spec.videoCodecId = "V_VP8";
    spec.includeVideoCodecPrivate = false;
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "a VP8 track whose blocks are not VP8 is not admitted");
  }
#else
  {
    // Without the libvpx stage compiled in, V_VP8 must not even be named as a
    // video CodecID: admitting the track and then failing the open is a worse
    // fallback than never selecting it.
    FixtureSpec spec = vp8FixtureSpec();
    expectPrepareError(spec, MatroskaDemuxError::TrackSelection,
                       "V_VP8 is not a selectable CodecID without libvpx");
  }
#endif
  {
    // AV1 keeps CodecPrivate mandatory: the av1C is the only fact source.
    FixtureSpec spec = av1FixtureSpec();
    const PreparedFixture prepared = prepareFixture(spec);
    expect(prepared.outcome.status == MatroskaDemuxStatus::Ready &&
               prepared.outcome.asset != nullptr,
           "an AV1 track with a real av1C is admitted");
    if (prepared.outcome.asset != nullptr) {
      const wam::media::MediaTrackDescriptor& video =
          prepared.outcome.asset->descriptor()->tracks.front();
      expect(video.codec == MediaCodec::Av1 &&
                 video.codecConfigurationKind ==
                     MediaCodecConfigurationKind::Av1C &&
                 std::equal(video.codecConfiguration.begin(),
                            video.codecConfiguration.end(),
                            kSampleAv1C.begin(), kSampleAv1C.end(),
                            [](std::byte lhs, std::uint8_t rhs) {
                              return lhs == static_cast<std::byte>(rhs);
                            }),
             "the av1C is adopted byte-identically under Kind::Av1C");
      expect(video.video &&
                 video.video->codedWidth == kSampleCodecEnvelopeWidth &&
                 video.video->codedHeight == kSampleCodecEnvelopeHeight &&
                 video.video->sampleFormat ==
                     MediaVideoSampleFormat::Yuv420EightBit,
             "AV1 dimensions come from the Sequence Header OBU");
    }
  }
  {
    FixtureSpec spec = av1FixtureSpec();
    spec.includeVideoCodecPrivate = false;
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "AV1 without CodecPrivate has no fact source");
  }
  {
    FixtureSpec spec = av1FixtureSpec();
    spec.videoPixelHeight = 1088;
    expectPrepareError(
        spec, MatroskaDemuxError::CodecConfiguration,
        "PixelHeight must equal the AV1 sequence header height exactly");
  }
  {
    // An avcC under V_AV1 must not reach the HEVC parser, which is what the
    // previous CodecID-to-kind ternary would have done for every non-AVC id.
    FixtureSpec spec;
    spec.videoCodecId = "V_AV1";
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "an avcC record under an AV1 CodecID is not admitted");
  }
  {
    // Product decision: a file that carries audio the native path cannot
    // decode falls back as a whole file rather than preparing video-only.
    // Preparing video-only would play the file natively and completely
    // silently; mpv plays the same file with sound. This deliberately
    // replaces the previous contract, which admitted video-only whenever
    // audio was optional.
    //
    // The example used to be A_OPUS, then A_VORBIS, then A_FLAC; all three are
    // now decoded natively. DTS is the current stand-in for "audio this source
    // does not decode" -- Apple ships no DTS decoder at all, so it is a codec
    // Matroska can carry that isAudioCodec() does not name, and the track is
    // never selected in the first place.
    FixtureSpec spec;
    spec.audioCodecId = "A_DTS";
    expectPrepareError(
        spec, MatroskaDemuxError::TrackSelection,
        "a document whose only audio is undecodable falls back whole-file");
  }
  {
    // The no-audio-track case is a different thing entirely and stays admitted
    // as the correct silent-video path.
    FixtureSpec spec;
    spec.includeAudioTrack = false;
    const PreparedFixture prepared = prepareFixture(spec);
    expect(prepared.outcome.status == MatroskaDemuxStatus::Ready &&
               prepared.outcome.asset != nullptr &&
               prepared.outcome.asset->descriptor()->selectedAudio ==
                   std::nullopt,
           "a document with no audio track at all still prepares video-only");
  }
  {
    FixtureSpec spec;
    spec.audioCodecId = "A_DTS";
    MediaSourceOpenOptions options;
    options.selection.requireAudio = true;
    const PreparedFixture prepared = prepareFixture(spec, options);
    expect(prepared.outcome.asset == nullptr &&
               prepared.outcome.error == MatroskaDemuxError::TrackSelection,
           "requireAudio rejects a document whose audio codec is unsupported");
  }
  {
    // THE headline change of the audio sweep. AAC's CodecDelay used to be
    // refused outright, which is why every AAC track FFmpeg *encodes* -- as
    // opposed to copies -- fell back as a whole file. 21,333,333 ns is one
    // 1024-frame access unit at 48 kHz, which is the only priming AAC-LC can
    // have, and it is now honoured as an exact head trim.
    FixtureSpec spec;
    spec.audioCodecDelayNanoseconds = 21'333'333;
    const PreparedFixture prepared = prepareFixture(spec);
    expect(prepared.outcome.status == MatroskaDemuxStatus::Ready &&
               prepared.outcome.asset != nullptr,
           "an AAC track whose CodecDelay is exactly one access unit is now "
           "admitted");
  }
  {
    // Any OTHER value is priming this path cannot prove, so the distrust the
    // historic rule expressed is kept exactly where it is still earned.
    // 6,500,000 ns is 312 frames at 48 kHz -- an Opus pre-skip, not an AAC
    // access unit.
    FixtureSpec spec;
    spec.audioCodecDelayNanoseconds = 6'500'000;
    expectPrepareError(
        spec, MatroskaDemuxError::CodecConfiguration,
        "an AAC CodecDelay that is not one whole access unit still falls back");
  }
  {
    // A_AC3, A_EAC3, A_FLAC and A_MPEG/L3 are now selectable CodecIDs, so a
    // track carrying one reaches codec admission instead of failing track
    // selection. The default fixture's audio payload is not a syncframe of
    // any of them, so admission is what refuses it -- and the verdict moving
    // from TrackSelection to CodecConfiguration is the proof that selection
    // now admits the CodecID.
    for (const char *codecId : {"A_AC3", "A_EAC3", "A_MPEG/L3"}) {
      FixtureSpec spec;
      spec.audioCodecId = codecId;
      expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                         "a selectable AC-3/E-AC-3/MP3 CodecID falls back at "
                         "admission, not at track selection");
    }
    {
      // Diagnostic control for the loop above: with the default A_AAC CodecID
      // the identical document prepares, so the refusals are the new codecs'
      // admission gates and not something about the fixture.
      const PreparedFixture control = prepareFixture({});
      expect(control.outcome.status == MatroskaDemuxStatus::Ready,
             "the same document with A_AAC still prepares");
    }
  }
  {
    // WebM's audio codec set is Vorbis and Opus. AC-3, E-AC-3, FLAC and MP3
    // are legal in Matroska and NOT legal in WebM, so a file whose DocType
    // says "webm" while carrying one of them is malformed -- and admitting it
    // would mean this source plays a file no other WebM decoder would.
    //
    // The verdict is TrackSelection rather than CodecConfiguration, which is
    // the load-bearing half: the track is never SELECTED, so this is the
    // DocType allow-list refusing it and not the codec admission that the
    // Matroska-DocType cases above exercise.
    for (const char *codecId : {"A_AC3", "A_EAC3", "A_MPEG/L3", "A_FLAC"}) {
      FixtureSpec spec;
      spec.docType = "webm";
      spec.audioCodecId = codecId;
      expectPrepareError(spec, MatroskaDemuxError::TrackSelection,
                         "AC-3, E-AC-3, MP3 and FLAC are not selectable in a "
                         "WebM DocType");
    }
    {
      // The same document in a Matroska DocType reaches codec admission, so
      // the refusal above is provably the DocType gate.
      FixtureSpec spec;
      spec.audioCodecId = "A_FLAC";
      expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                         "the identical A_FLAC track in a Matroska DocType "
                         "reaches codec admission instead");
    }
    {
      // AAC is not WebM-legal either, but it WAS selectable in a WebM DocType
      // before this work and the rule is deliberately not extended to it: a
      // consistent gate that turned working files into fallbacks would be a
      // worse trade than an inconsistent one that changes nothing it was not
      // asked to. This case pins that decision rather than describing the
      // format.
      FixtureSpec spec;
      spec.docType = "webm";
      const PreparedFixture prepared = prepareFixture(spec);
      expect(prepared.outcome.status == MatroskaDemuxStatus::Ready &&
                 prepared.outcome.asset != nullptr,
             "AAC in a WebM DocType keeps preparing, exactly as before");
    }
    FixtureSpec flac;
    flac.audioCodecId = "A_FLAC";
    expectPrepareError(flac, MatroskaDemuxError::CodecConfiguration,
                       "an A_FLAC track whose CodecPrivate is not a fLaC "
                       "stream header falls back at admission");
  }
  {
    FixtureSpec spec;
    spec.audioSeekPreRollNanoseconds = 80'000'000;
    expectPrepareError(
        spec, MatroskaDemuxError::CodecConfiguration,
        "a nonzero SeekPreRoll on an AAC track still falls back");
  }
  {
    // A_OPUS is now a decodable CodecID, so track selection admits it and the
    // verdict moves to codec admission -- which refuses a CodecPrivate that is
    // not an OpusHead identification header.
    FixtureSpec spec;
    spec.audioCodecId = "A_OPUS";
    expectPrepareError(
        spec, MatroskaDemuxError::CodecConfiguration,
        "an Opus track whose CodecPrivate is not an OpusHead falls back");
  }
  {
    // A well-formed OpusHead whose pre-skip the container's CodecDelay does
    // not corroborate is refused rather than guessed at: every downstream trim
    // is derived from that one number.
    FixtureSpec spec;
    spec.audioCodecId = "A_OPUS";
    spec.audioCodecPrivate = fromOctets(kOpusHeadStereo312);
    spec.audioCodecDelayNanoseconds = 6'500'000 + 100'000;
    expectPrepareError(
        spec, MatroskaDemuxError::CodecConfiguration,
        "an Opus track whose CodecDelay disagrees with its pre-skip falls "
        "back");
  }
  {
    FixtureSpec spec;
    spec.audioCodecId = "A_OPUS";
    spec.audioCodecPrivate = fromOctets(kOpusHeadStereo312);
    expectPrepareError(
        spec, MatroskaDemuxError::CodecConfiguration,
        "an Opus track with no CodecDelay at all falls back");
  }
  {
    // A_VORBIS is likewise a decodable CodecID now, so its refusals are codec
    // admission rather than track selection.
    FixtureSpec spec;
    spec.audioCodecId = "A_VORBIS";
    expectPrepareError(
        spec, MatroskaDemuxError::CodecConfiguration,
        "a Vorbis track whose CodecPrivate is not Xiph-laced headers falls "
        "back");
  }
  {
    // Well-formed headers, but the container states no CodecDelay to
    // corroborate the one-block presentation offset the trim is derived from.
    FixtureSpec spec;
    spec.audioCodecId = "A_VORBIS";
    spec.audioCodecPrivate = vorbisCodecPrivate(0xBBU);
    expectPrepareError(
        spec, MatroskaDemuxError::CodecConfiguration,
        "a Vorbis track with no CodecDelay at all falls back");
  }
  {
    // The variable-block-size refusal, at the demuxer level. 0xB8 is
    // blocksize0 256 / blocksize1 2048 -- exactly what reference libvorbis
    // emits -- whose per-packet duration this demuxer's constant-rate grid
    // cannot represent. It falls back deliberately, with a correct CodecDelay
    // present, so the refusal is provably the block-size gate and nothing else.
    FixtureSpec spec;
    spec.audioCodecId = "A_VORBIS";
    spec.audioCodecPrivate = vorbisCodecPrivate(0xB8U);
    spec.audioCodecDelayNanoseconds = 21'333'333;
    expectPrepareError(
        spec, MatroskaDemuxError::CodecConfiguration,
        "a Vorbis track with unequal block sizes falls back rather than "
        "being placed on a constant-duration grid");
  }
  {
    FixtureSpec spec;
    spec.includeAudioTrack = false;
    MediaSourceOpenOptions options;
    options.selection.requireAudio = true;
    const PreparedFixture prepared = prepareFixture(spec, options);
    expect(prepared.outcome.asset == nullptr &&
               prepared.outcome.error == MatroskaDemuxError::TrackSelection,
           "requireAudio rejects a document with no audio track at all");
  }
  {
    FixtureSpec spec;
    spec.includeAudioTrack = false;
    const PreparedFixture prepared = prepareFixture(spec);
    expect(prepared.outcome.status == MatroskaDemuxStatus::Ready &&
               prepared.outcome.asset != nullptr &&
               !prepared.outcome.asset->descriptor()->selectedAudio,
           "audio remains optional by default");
    if (prepared.outcome.asset != nullptr) {
      MatroskaGenerationPlan plan;
      expect(prepared.asset().makeAudioCursor(plan) == nullptr,
             "an audio cursor is unavailable without a selected audio track");
    }
  }
  {
    FixtureSpec spec;
    spec.includeVideoTrack = false;
    expectPrepareError(spec, MatroskaDemuxError::TrackSelection,
                       "requireVideo, which is the default, still rejects an "
                       "audio-only document");
  }
  {
    FixtureSpec spec;
    spec.includeVideoTrack = false;
    spec.includeAudioTrack = false;
    spec.includeSubtitleTrack = false;
    expectPrepareError(spec, MatroskaDemuxError::InvalidContainer,
                       "a Segment with no Tracks element is not a container");
  }
  {
    FixtureSpec spec;
    spec.includeVideoTrack = false;
    spec.includeAudioTrack = false;
    spec.includeSubtitleTrack = true;
    expectPrepareError(spec, MatroskaDemuxError::TrackSelection,
                       "a subtitle-only Tracks element admits no A/V output");
  }
  {
    // Audio-only Matroska (an MKA, or an audio-only MKV/WebM). The clock is
    // audio-authoritative in every generation, so dropping the video lane is
    // the simpler of the two degenerate cases: nothing has to stand in for the
    // missing authority. The Cue index stays selected-video-only and is
    // therefore empty here; the Block scan seeds off the Cluster directory
    // instead, which is what lets a Cue-less MKA seek at all.
    FixtureSpec spec;
    spec.includeVideoTrack = false;
    MediaSourceOpenOptions options;
    options.selection.requireVideo = false;
    const PreparedFixture prepared = prepareFixture(spec, options);
    expect(prepared.outcome.status == MatroskaDemuxStatus::Ready &&
               prepared.outcome.asset != nullptr &&
               !prepared.outcome.asset->descriptor()->selectedVideo &&
               prepared.outcome.asset->descriptor()->selectedAudio.has_value(),
           "requireVideo false admits an audio-only document with no video "
           "lane");
    if (prepared.outcome.asset != nullptr) {
      expect(prepared.asset().cues().empty(),
             "an audio-only asset builds no selected-video Cue index");
      const MatroskaPlanOutcome planned = prepared.asset().planGeneration(
          MediaTime{0, 1}, MediaSeekMode::Accurate);
      expect(planned.status == MatroskaDemuxStatus::Ready &&
                 planned.plan.has_value(),
             "an audio-only generation plans off the Cluster directory");
      if (planned.plan) {
        expect(planned.plan->actualDecodeStart.valid() &&
                   planned.plan->actualDecodeStart.value >= 0,
               "an audio-only plan states a nonnegative decode start");
        expect(prepared.asset().makeVideoCursor(*planned.plan) == nullptr,
               "a video cursor is unavailable without a selected video track");
        expect(prepared.asset().makeAudioCursor(*planned.plan) != nullptr,
               "the audio cursor is the only lane an audio-only asset opens");
      }
    }
  }
  {
    MediaSourceOpenOptions options;
    options.selection.preferredVideo = 2;
    const PreparedFixture prepared = prepareFixture({}, options);
    expect(prepared.outcome.asset == nullptr &&
               prepared.outcome.error == MatroskaDemuxError::TrackSelection,
           "a preferred video track that names the audio track is rejected");
  }
  {
    MediaSourceOpenOptions options;
    options.selection.preferredAudio = 7;
    const PreparedFixture prepared = prepareFixture({}, options);
    expect(prepared.outcome.asset == nullptr &&
               prepared.outcome.error == MatroskaDemuxError::TrackSelection,
           "a preferred audio track that does not exist is rejected");
  }
  {
    MediaSourceOpenOptions options;
    options.selection.preferredSubtitle = 3;
    const PreparedFixture prepared = prepareFixture({}, options);
    expect(prepared.outcome.asset == nullptr &&
               prepared.outcome.error == MatroskaDemuxError::TrackSelection,
           "any requested subtitle selection is rejected in v1");
  }
  {
    MediaSourceOpenOptions options;
    options.selection.preferredVideo = 1;
    options.selection.preferredAudio = 2;
    const PreparedFixture prepared = prepareFixture({}, options);
    expect(prepared.outcome.status == MatroskaDemuxStatus::Ready,
           "explicitly preferred existing tracks are honored");
  }
  {
    FixtureSpec spec;
    spec.audioChannels = 1;
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "Channels must equal the ASC channel configuration");
  }
  {
    FixtureSpec spec;
    spec.audioSamplingFrequency = 44'100.0;
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "SamplingFrequency must equal the ASC sampling rate");
  }
  {
    // BitDepth is a PCM field. On a compressed AAC track it is informational
    // and cannot affect the bitstream, the ASC, or the derived ES_Descriptor,
    // so its presence is admitted and simply ignored. FFmpeg writes
    // BitDepth=32 on every AAC track it muxes; rejecting it rejected
    // essentially all real AAC-in-Matroska.
    FixtureSpec spec;
    spec.audioBitDepth = 16;
    const PreparedFixture prepared = prepareFixture(spec);
    expect(prepared.outcome.status == MatroskaDemuxStatus::Ready &&
               prepared.outcome.asset != nullptr,
           "a compressed AAC track may declare an ignored BitDepth");
  }
  {
    FixtureSpec spec;
    spec.audioCodecPrivate = Bytes{std::byte{0x12}, std::byte{0x10}};
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "a non AAC-LC AudioSpecificConfig is not admitted");
  }
  {
    FixtureSpec spec;
    spec.videoPixelWidth = 1'279;
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "PixelWidth must equal the SPS cropped luma width");
  }
  {
    FixtureSpec spec;
    spec.videoPixelHeight = 721;
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "PixelHeight must equal the SPS cropped luma height");
  }
  {
    FixtureSpec spec;
    spec.videoCodecPrivate = Bytes(8, std::byte{0x01});
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "a malformed avcC record fails codec admission");
  }
  {
    FixtureSpec spec;
    spec.videoInterlaced = 1;
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "FlagInterlaced interlaced content is not admitted");
  }
  {
    FixtureSpec spec;
    spec.videoInterlaced = 2;
    const PreparedFixture prepared = prepareFixture(spec);
    expect(prepared.outcome.status == MatroskaDemuxStatus::Ready,
           "FlagInterlaced progressive is admitted like an absent flag");
  }
  {
    FixtureSpec spec;
    spec.videoCodecDelayNanoseconds = 1;
    expectPrepareError(spec, MatroskaDemuxError::CodecConfiguration,
                       "a nonzero CodecDelay on the selected video is refused");
  }
  {
    FixtureSpec spec;
    spec.videoPixelWidth = kSampleAvcWidth;
    MediaSourceOpenOptions options;
    options.limits.maximumCodedWidth = 640;
    const PreparedFixture prepared = prepareFixture(spec, options);
    expect(prepared.outcome.asset == nullptr &&
               prepared.outcome.error ==
                   MatroskaDemuxError::CodecConfiguration,
           "a tightened coded-width limit rejects the 1280x720 record");
  }
}

// ---------------------------------------------------------------------------
// 4. Generation planning.
// ---------------------------------------------------------------------------

void expectAccuratePlan(const MatroskaPreparedAsset& asset, MediaTime target,
                        std::uint64_t expectedCueTick, const char* message) {
  const MatroskaPlanOutcome outcome =
      asset.planGeneration(target, MediaSeekMode::Accurate);
  bool matched = outcome.status == MatroskaDemuxStatus::Ready && outcome.plan;
  if (matched) {
    const MatroskaGenerationPlan& plan = *outcome.plan;
    const auto ceiling =
        wam::media::audioFrameAtOrAfter(target, kAudioSampleRate);
    const auto order =
        wam::media::compareMediaTime(plan.actualDecodeStart, target);
    matched = plan.requestedTarget == target &&
              plan.mode == MediaSeekMode::Accurate &&
              plan.actualDecodeStart == tickTime(
                  static_cast<std::int64_t>(expectedCueTick)) &&
              order && *order != wam::media::MediaTimeOrder::Greater &&
              ceiling && plan.audioWindow.presentationStart == *ceiling;
    // decodeStart names the first access unit the audio cursor actually
    // emits, which is the planned ordinal itself. It used to name the first AU
    // of the Block containing it, which disagreed with the cursor on any
    // mid-Block landing.
    const std::uint64_t audibleOrdinal =
        static_cast<std::uint64_t>(
            *wam::media::exactAudioFrameIndex(*ceiling, kAudioSampleRate)) /
        kAacLcSamplesPerAccessUnit;
    // A non-origin generation stages two whole access units of decoder
    // priming ahead of the first audible frame; at the origin there is
    // nothing earlier to stage.
    const std::uint64_t expectedOrdinal =
        audibleOrdinal >= 2U ? audibleOrdinal - 2U : 0U;
    matched = matched &&
              plan.audioWindow.decodeStart ==
                  audioGridTime(plan.audioAccessUnitOrdinal) &&
              plan.audioAccessUnitOrdinal == expectedOrdinal &&
              plan.audioWindow.startsAtStreamOrigin == (expectedOrdinal == 0U);
  }
  expect(matched, message);
}

void testAccuratePlanning() {
  const PreparedFixture prepared = prepareFixture({});
  if (prepared.outcome.asset == nullptr) {
    expect(false, "accurate planning fixture prepares");
    return;
  }
  const MatroskaPreparedAsset& asset = prepared.asset();

  expectAccuratePlan(asset, MediaTime{0, 1}, 0,
                     "accurate plan at zero uses the first cue exactly");
  expectAccuratePlan(asset, MediaTime{1, 10}, 0,
                     "accurate target before the second cue keeps cue zero");
  expectAccuratePlan(asset, MediaTime{1, 2}, 500,
                     "accurate target exactly on a cue selects that cue");
  expectAccuratePlan(asset, MediaTime{3, 4}, 500,
                     "accurate target between cues selects the earlier cue");
  expectAccuratePlan(asset, MediaTime{1, 1}, 1'000,
                     "accurate target on the last cue selects the last cue");
  expectAccuratePlan(asset, MediaTime{5, 4}, 1'000,
                     "accurate target after the last cue selects the last cue");

  // A = ceil(T * R) / R exactly, including a target that is one PCM frame
  // above an access-unit boundary.
  const MediaTime justAfterFrame{48'001, 96'000};
  const MatroskaPlanOutcome fractional =
      asset.planGeneration(justAfterFrame, MediaSeekMode::Accurate);
  expect(fractional.plan &&
             fractional.plan->audioWindow.presentationStart ==
                 MediaTime{24'001, 48'000},
         "an off-grid accurate target rounds the audio window up one frame");

  const MatroskaPlanOutcome onFrame =
      asset.planGeneration(MediaTime{24'000, 48'000}, MediaSeekMode::Accurate);
  expect(onFrame.plan &&
             onFrame.plan->audioWindow.presentationStart == MediaTime{1, 2},
         "an on-grid accurate target keeps its exact audio presentation start");

  const MatroskaPlanOutcome origin =
      asset.planGeneration(MediaTime{0, 1}, MediaSeekMode::Accurate);
  expect(origin.plan && origin.plan->audioWindow.startsAtStreamOrigin &&
             origin.plan->audioAccessUnitOrdinal == 0 &&
             origin.plan->audioFrameIndex == 0 &&
             origin.plan->videoClusterIndex == 0,
         "planning at zero reports the stream origin window");

  const MatroskaPlanOutcome late =
      asset.planGeneration(MediaTime{5, 4}, MediaSeekMode::Accurate);
  expect(late.plan && !late.plan->audioWindow.startsAtStreamOrigin &&
             late.plan->audioClusterIndex >= 2 &&
             late.plan->videoClusterIndex == 2,
         "a late accurate target stages from the last cue's cluster");

  expect(asset.planGeneration(MediaTime{3, 2}, MediaSeekMode::Accurate)
                 .error == MatroskaDemuxError::InvalidTimeline &&
             asset.planGeneration(MediaTime{2, 1}, MediaSeekMode::Accurate)
                     .error == MatroskaDemuxError::InvalidTimeline,
         "targets at or beyond the finite duration are refused");
  expect(asset.planGeneration(MediaTime{-1, 1'000}, MediaSeekMode::Accurate)
                 .error == MatroskaDemuxError::InvalidTimeline &&
             asset.planGeneration(MediaTime{1, 0}, MediaSeekMode::Accurate)
                     .error == MatroskaDemuxError::InvalidTimeline,
         "negative and invalid targets are refused");
}

void testKeyFramePlanning() {
  const PreparedFixture prepared = prepareFixture({});
  if (prepared.outcome.asset == nullptr) {
    expect(false, "key-frame planning fixture prepares");
    return;
  }
  const MatroskaPreparedAsset& asset = prepared.asset();

  struct Case {
    MediaTime target;
    std::uint64_t cueTick;
    const char* message;
  };
  const std::array<Case, 5> cases{
      Case{MediaTime{0, 1}, 0,
           "key-frame plan at zero pins A = D = the origin RAP"},
      Case{MediaTime{1, 10}, 0,
           "key-frame plan before the second cue pins A = D = cue zero"},
      Case{MediaTime{1, 2}, 500,
           "key-frame plan exactly on a cue pins A = D = that RAP"},
      Case{MediaTime{3, 4}, 500,
           "key-frame plan between cues pins A = D = the earlier RAP"},
      Case{MediaTime{5, 4}, 1'000,
           "key-frame plan after the last cue pins A = D = the last RAP"}};
  for (const Case& item : cases) {
    const MatroskaPlanOutcome outcome =
        asset.planGeneration(item.target, MediaSeekMode::KeyFrame);
    bool matched = outcome.status == MatroskaDemuxStatus::Ready && outcome.plan;
    if (matched) {
      const MatroskaGenerationPlan& plan = *outcome.plan;
      const MediaTime rap = tickTime(static_cast<std::int64_t>(item.cueTick));
      const auto sameStart = wam::media::compareMediaTime(
          plan.audioWindow.presentationStart, plan.actualDecodeStart);
      const auto decodeOrder = wam::media::compareMediaTime(
          plan.audioWindow.decodeStart, plan.audioWindow.presentationStart);
      matched = plan.mode == MediaSeekMode::KeyFrame &&
                plan.actualDecodeStart == rap &&
                sameStart && *sameStart == wam::media::MediaTimeOrder::Equal &&
                decodeOrder &&
                *decodeOrder != wam::media::MediaTimeOrder::Greater;
    }
    expect(matched, item.message);
  }

  const MatroskaPlanOutcome accurate =
      asset.planGeneration(MediaTime{3, 4}, MediaSeekMode::Accurate);
  const MatroskaPlanOutcome keyFrame =
      asset.planGeneration(MediaTime{3, 4}, MediaSeekMode::KeyFrame);
  expect(accurate.plan && keyFrame.plan &&
             accurate.plan->actualDecodeStart ==
                 keyFrame.plan->actualDecodeStart &&
             accurate.plan->videoBlockOffset ==
                 keyFrame.plan->videoBlockOffset &&
             accurate.plan->audioWindow.presentationStart !=
                 keyFrame.plan->audioWindow.presentationStart,
         "both modes share the video RAP and differ only in the audio window");
}

void testPlanningRejectsNonRandomAccessCue() {
  FixtureSpec spec;
  spec.cues = CueVariant::NonKeyFrameTarget;
  const PreparedFixture prepared = prepareFixture(spec);
  expect(prepared.outcome.status == MatroskaDemuxStatus::Ready,
         "a cue that names a non-key block still prepares structurally");
  if (prepared.outcome.asset == nullptr) {
    return;
  }
  const MatroskaPlanOutcome outcome =
      prepared.asset().planGeneration(MediaTime{0, 1}, MediaSeekMode::KeyFrame);
  expect(outcome.status != MatroskaDemuxStatus::Ready &&
             outcome.error == MatroskaDemuxError::InvalidCue,
         "planning proves the cue block really is a random access point");
}

void testPlanningWithoutAudio() {
  FixtureSpec spec;
  spec.includeAudioTrack = false;
  const PreparedFixture prepared = prepareFixture(spec);
  if (prepared.outcome.asset == nullptr) {
    expect(false, "video-only planning fixture prepares");
    return;
  }
  const MatroskaPlanOutcome outcome = prepared.asset().planGeneration(
      MediaTime{3, 4}, MediaSeekMode::Accurate);
  expect(outcome.status == MatroskaDemuxStatus::Ready && outcome.plan &&
             outcome.plan->audioWindow == MediaAudioGenerationWindow{} &&
             outcome.plan->audioAccessUnitOrdinal == 0,
         "a video-only plan carries the empty audio window encoding");
}

// ---------------------------------------------------------------------------
// 5. Payload-free capacity-one cursors.
// ---------------------------------------------------------------------------

const MatroskaCompressedSample* sampleOf(const MatroskaCursorReadResult& result) {
  return std::get_if<MatroskaCompressedSample>(&result);
}

void testVideoCursor() {
  FixtureSpec cursorSpec;
  // One deliberately large frame proves the cursor never copies payloads.
  cursorSpec.largeVideoFrameBytes = 150'000;
  const PreparedFixture prepared = prepareFixture(cursorSpec);
  if (prepared.outcome.asset == nullptr) {
    expect(false, "video cursor fixture prepares");
    return;
  }
  const MatroskaPreparedAsset& asset = prepared.asset();
  const Fixture& fixture = prepared.fixture;
  const MatroskaPlanOutcome plan =
      asset.planGeneration(MediaTime{0, 1}, MediaSeekMode::KeyFrame);
  expect(plan.plan.has_value(), "video cursor plan is available");
  if (!plan.plan) {
    return;
  }
  auto cursor = asset.makeVideoCursor(*plan.plan);
  expect(cursor != nullptr, "video cursor is created from its plan");
  if (cursor == nullptr) {
    return;
  }

  expect(fixture.videoBlocks.size() == 15U,
         "the video cursor fixture holds every planned Block");
  const auto readsBefore = prepared.reader->totalRead;
  std::size_t index = 0;
  bool exact = true;
  bool sawKeyFrame = false;
  bool sawVfrDuration = false;
  bool sawDefaultDuration = false;
  bool sawInvisible = false;
  bool sawDiscardable = false;
  bool sawReordered = false;
  while (index < fixture.videoBlocks.size()) {
    const MatroskaCursorReadResult result = cursor->readNext();
    const MatroskaCompressedSample* sample = sampleOf(result);
    if (sample == nullptr) {
      exact = false;
      break;
    }
    const BlockFacts& facts = fixture.videoBlocks[index];
    const MediaTime expectedDuration =
        facts.durationTicks
            ? tickTime(static_cast<std::int64_t>(*facts.durationTicks))
            : reducedTime(kVideoDefaultDurationNanoseconds, 1'000'000'000U);
    exact = exact && sample->track == 1 &&
            sample->kind == MediaSampleKind::EncodedVideo &&
            sample->frameCount == 1 &&
            sample->frames[0] == FrameRange{facts.frames[0]} &&
            sample->aggregateBytes ==
                static_cast<std::size_t>(facts.frames[0].size) &&
            sample->presentationTime == tickTime(facts.tick) &&
            sample->duration == expectedDuration &&
            sample->keyFrame == facts.keyFrame &&
            sample->invisible == facts.invisible &&
            sample->discardable == facts.discardable &&
            !sample->decodeTime.valid();
    sawKeyFrame = sawKeyFrame || sample->keyFrame;
    sawVfrDuration = sawVfrDuration || facts.durationTicks.has_value();
    sawDefaultDuration =
        sawDefaultDuration || (!facts.durationTicks && !sample->keyFrame);
    sawInvisible = sawInvisible || sample->invisible;
    sawDiscardable = sawDiscardable || sample->discardable;
    sawReordered = sawReordered || (!sample->keyFrame && !sample->invisible &&
                                    !sample->discardable);
    ++index;
  }
  expect(exact && index == fixture.videoBlocks.size(),
         "the video cursor emits every block with exact ranges and timing");
  expect(sawKeyFrame && sawVfrDuration && sawDefaultDuration && sawInvisible &&
             sawDiscardable && sawReordered,
         "the video walk covers RAP, VFR, DefaultDuration, and flag variants");
  expect(std::holds_alternative<MatroskaCursorEnd>(cursor->readNext()) &&
             std::holds_alternative<MatroskaCursorEnd>(cursor->readNext()),
         "the video cursor reports an idempotent end of stream");

  // A complete payload-free walk reads element headers and bounded prefixes
  // only, so it can never approach the single 150,000-byte frame it crossed.
  expect(prepared.reader->totalRead - readsBefore <
             cursorSpec.largeVideoFrameBytes / 4U,
         "cursor reads stay structural instead of copying frame payloads");

  const MatroskaPlanOutcome middle =
      asset.planGeneration(MediaTime{1, 2}, MediaSeekMode::KeyFrame);
  expect(middle.plan.has_value(), "middle-cluster plan is available");
  if (!middle.plan) {
    return;
  }
  auto middleCursor = asset.makeVideoCursor(*middle.plan);
  expect(middleCursor != nullptr, "middle video cursor is created");
  if (middleCursor == nullptr) {
    return;
  }
  const BlockFacts* planned =
      fixture.videoBlockAt(middle.plan->videoBlockOffset);
  const MatroskaCursorReadResult first = middleCursor->readNext();
  const MatroskaCompressedSample* firstSample = sampleOf(first);
  expect(planned != nullptr && firstSample != nullptr &&
             firstSample->presentationTime == MediaTime{1, 2} &&
             firstSample->presentationTime == middle.plan->actualDecodeStart &&
             firstSample->keyFrame &&
             firstSample->frames[0] == FrameRange{planned->frames[0]},
         "a seeked video cursor starts exactly at its planned RAP block");
  std::size_t expectedRemaining = 0;
  for (const BlockFacts& block : fixture.videoBlocks) {
    if (block.containerOffset > middle.plan->videoBlockOffset) {
      ++expectedRemaining;
    }
  }
  std::size_t remaining = 0;
  while (sampleOf(middleCursor->readNext()) != nullptr) {
    ++remaining;
    if (remaining > fixture.videoBlocks.size()) {
      break;
    }
  }
  expect(remaining == expectedRemaining && expectedRemaining != 0,
         "a seeked video cursor emits exactly the remaining blocks");
}

void testAudioCursorLacingAndGrid() {
  const PreparedFixture prepared = prepareFixture({});
  if (prepared.outcome.asset == nullptr) {
    expect(false, "audio cursor fixture prepares");
    return;
  }
  const MatroskaPreparedAsset& asset = prepared.asset();
  const Fixture& fixture = prepared.fixture;
  const MatroskaPlanOutcome plan =
      asset.planGeneration(MediaTime{0, 1}, MediaSeekMode::Accurate);
  expect(plan.plan.has_value(), "audio cursor plan is available");
  if (!plan.plan) {
    return;
  }
  auto cursor = asset.makeAudioCursor(*plan.plan);
  expect(cursor != nullptr, "audio cursor is created from its plan");
  if (cursor == nullptr) {
    return;
  }

  expect(fixture.audioBlocks.size() == 23U,
         "the audio cursor fixture holds every planned AAC Block");
  std::uint64_t ordinal = 0;
  std::size_t index = 0;
  bool exact = true;
  bool sawLaced = false;
  bool sawUnlaced = false;
  std::vector<std::uint16_t> observedFrameCounts;
  while (index < fixture.audioBlocks.size()) {
    const MatroskaCursorReadResult result = cursor->readNext();
    const MatroskaCompressedSample* sample = sampleOf(result);
    if (sample == nullptr) {
      exact = false;
      break;
    }
    const BlockFacts& facts = fixture.audioBlocks[index];
    exact = exact && sample->track == 2 &&
            sample->kind == MediaSampleKind::EncodedAudio &&
            sample->frameCount == facts.frameCount &&
            facts.firstOrdinal == ordinal &&
            sample->presentationTime == audioGridTime(ordinal) &&
            sample->duration ==
                reducedTime(static_cast<std::uint64_t>(sample->frameCount) *
                                kAacLcSamplesPerAccessUnit,
                            kAudioSampleRate) &&
            sample->keyFrame == false && !sample->decodeTime.valid();
    std::size_t aggregate = 0;
    for (std::uint16_t frame = 0; frame < sample->frameCount; ++frame) {
      exact = exact && frame < facts.frames.size() &&
              sample->frames[frame] == FrameRange{facts.frames[frame]};
      aggregate += static_cast<std::size_t>(facts.frames[frame].size);
    }
    exact = exact && sample->aggregateBytes == aggregate;
    sawLaced = sawLaced || sample->frameCount > 1;
    sawUnlaced = sawUnlaced || sample->frameCount == 1;
    if (observedFrameCounts.size() < 4U) {
      observedFrameCounts.push_back(sample->frameCount);
    }
    ordinal += sample->frameCount;
    ++index;
  }
  expect(exact && index == fixture.audioBlocks.size(),
         "every laced AAC block yields exact per-frame ranges and grid times");
  // The fixture cycles fixed(4), Xiph(4), EBML(3), and unlaced(1) blocks.
  expect(sawLaced && sawUnlaced &&
             observedFrameCounts ==
                 std::vector<std::uint16_t>{4, 4, 3, 1},
         "the audio walk covers fixed, Xiph, EBML, and unlaced blocks");
  expect(std::holds_alternative<MatroskaCursorEnd>(cursor->readNext()),
         "the audio cursor reports end of stream after the last block");

  // The ordinal grid is the deterministic ties-to-even quantization; these
  // exact ticks are the ones written into the fixture.
  expect(fixture.audioBlocks.size() > 4 && fixture.audioBlocks[0].tick == 0 &&
             fixture.audioBlocks[1].tick == 85 &&
             fixture.audioBlocks[2].tick == 171 &&
             fixture.audioBlocks[3].tick == 235,
         "fixture AAC block ticks are the exact quantized grid positions");

  const MatroskaPlanOutcome mid =
      asset.planGeneration(MediaTime{3, 4}, MediaSeekMode::Accurate);
  expect(mid.plan.has_value(), "mid-stream audio plan is available");
  if (!mid.plan) {
    return;
  }
  auto midCursor = asset.makeAudioCursor(*mid.plan);
  expect(midCursor != nullptr, "mid-stream audio cursor is created");
  if (midCursor == nullptr) {
    return;
  }
  const MatroskaCursorReadResult first = midCursor->readNext();
  const MatroskaCompressedSample* firstSample = sampleOf(first);
  const BlockFacts* startBlock = nullptr;
  for (const BlockFacts& block : fixture.audioBlocks) {
    if (block.containerOffset == mid.plan->audioBlockOffset) {
      startBlock = &block;
    }
  }
  expect(firstSample != nullptr && startBlock != nullptr &&
             firstSample->presentationTime ==
                 audioGridTime(mid.plan->audioAccessUnitOrdinal) &&
             firstSample->frameCount ==
                 startBlock->frameCount - mid.plan->audioFrameIndex &&
             firstSample->frames[0] ==
                 FrameRange{startBlock->frames[mid.plan->audioFrameIndex]},
         "a mid-block audio seek drops exactly the access units before it");

  std::uint64_t continued = mid.plan->audioAccessUnitOrdinal +
                            (firstSample != nullptr ? firstSample->frameCount
                                                    : 0U);
  bool continuous = firstSample != nullptr;
  while (continuous) {
    const MatroskaCursorReadResult result = midCursor->readNext();
    const MatroskaCompressedSample* sample = sampleOf(result);
    if (sample == nullptr) {
      continuous = std::holds_alternative<MatroskaCursorEnd>(result);
      break;
    }
    continuous = sample->presentationTime == audioGridTime(continued);
    continued += sample->frameCount;
  }
  expect(continuous,
         "the AAC ordinal grid advances exactly across cluster boundaries");
}

void testCursorSampleLimits() {
  FixtureSpec spec;
  MediaSourceOpenOptions options;
  options.limits.maximumAudioSampleBytes = 12;
  const PreparedFixture prepared = prepareFixture(spec, options);
  expect(prepared.outcome.status == MatroskaDemuxStatus::Ready,
         "a tightened audio byte cap still prepares the document");
  if (prepared.outcome.asset == nullptr) {
    return;
  }
  const MatroskaPlanOutcome plan = prepared.asset().planGeneration(
      MediaTime{0, 1}, MediaSeekMode::Accurate);
  if (!plan.plan) {
    expect(false, "capped audio plan is available");
    return;
  }
  auto cursor = prepared.asset().makeAudioCursor(*plan.plan);
  if (cursor == nullptr) {
    expect(false, "capped audio cursor is created");
    return;
  }
  const MatroskaCursorReadResult result = cursor->readNext();
  const auto* failure = std::get_if<MatroskaCursorFailure>(&result);
  expect(failure != nullptr &&
             failure->error == MatroskaDemuxError::SampleLimit,
         "a laced AAC block over the aggregate byte cap fails SampleLimit");

  MediaSourceOpenOptions videoOptions;
  videoOptions.limits.maximumVideoSampleBytes = 4;
  const PreparedFixture cappedVideo = prepareFixture(spec, videoOptions);
  expect(cappedVideo.outcome.asset == nullptr &&
             cappedVideo.outcome.error == MatroskaDemuxError::SampleLimit,
         "a cue-targeted video block over its byte cap fails SampleLimit");
}

// ---------------------------------------------------------------------------
// 6. Exact payload copies.
// ---------------------------------------------------------------------------

void testCopyRanges() {
  FixtureSpec spec;
  spec.largeVideoFrameBytes = 150'000;
  const PreparedFixture prepared = prepareFixture(spec);
  if (prepared.outcome.asset == nullptr) {
    expect(false, "copy fixture prepares");
    return;
  }
  const MatroskaPreparedAsset& asset = prepared.asset();
  const Fixture& fixture = prepared.fixture;

  const BlockFacts* large = nullptr;
  for (const BlockFacts& block : fixture.videoBlocks) {
    if (block.frames[0].size == spec.largeVideoFrameBytes) {
      large = &block;
      break;
    }
  }
  expect(large != nullptr, "the fixture contains the large video frame");
  if (large == nullptr) {
    return;
  }

  const std::array<FrameRange, 1> single{FrameRange{large->frames[0]}};
  std::vector<std::byte> destination(spec.largeVideoFrameBytes);
  const auto readsBefore = prepared.reader->readSizes.size();
  MatroskaDemuxError error = MatroskaDemuxError::Io;
  const bool copied = asset.copyRanges(single, destination, {}, &error);
  expect(copied && error == MatroskaDemuxError::None,
         "a large frame copies successfully");
  bool identical = copied;
  for (std::size_t index = 0; identical && index < destination.size();
       ++index) {
    identical = destination[index] ==
                fixture.bytes[static_cast<std::size_t>(
                    large->frames[0].offset) + index];
  }
  expect(identical, "the copied bytes equal the exact document bytes");

  std::vector<std::size_t> sizes;
  std::vector<std::uint64_t> offsets;
  for (std::size_t index = readsBefore;
       index < prepared.reader->readSizes.size(); ++index) {
    sizes.push_back(prepared.reader->readSizes[index]);
    offsets.push_back(prepared.reader->readOffsets[index]);
  }
  const std::size_t chunk = 64U * 1024U;
  bool splitting = sizes.size() == 3U && sizes[0] == chunk &&
                   sizes[1] == chunk &&
                   sizes[2] == spec.largeVideoFrameBytes - 2U * chunk;
  if (splitting) {
    splitting = offsets[0] == large->frames[0].offset &&
                offsets[1] == large->frames[0].offset + chunk &&
                offsets[2] == large->frames[0].offset + 2U * chunk;
  }
  expect(splitting, "copies are split into consecutive 64 KiB reads");

  const BlockFacts* laced = nullptr;
  for (const BlockFacts& block : fixture.audioBlocks) {
    if (block.frameCount == 4 && block.frames[0].size != block.frames[1].size) {
      laced = &block;
      break;
    }
  }
  expect(laced != nullptr, "the fixture contains a Xiph-laced audio block");
  if (laced != nullptr) {
    std::vector<FrameRange> ranges;
    std::size_t total = 0;
    for (const ByteRange frame : laced->frames) {
      ranges.push_back(FrameRange{frame});
      total += static_cast<std::size_t>(frame.size);
    }
    std::vector<std::byte> concatenated(total);
    MatroskaDemuxError laceError = MatroskaDemuxError::Io;
    const bool laceCopied =
        asset.copyRanges(ranges, concatenated, {}, &laceError);
    bool exact = laceCopied && laceError == MatroskaDemuxError::None;
    std::size_t cursor = 0;
    for (const ByteRange frame : laced->frames) {
      for (std::uint64_t index = 0; exact && index < frame.size; ++index) {
        exact = concatenated[cursor + static_cast<std::size_t>(index)] ==
                fixture.bytes[static_cast<std::size_t>(frame.offset + index)];
      }
      cursor += static_cast<std::size_t>(frame.size);
    }
    expect(exact, "laced frames copy as an exact ordered concatenation");
  }

  MatroskaDemuxError shortError = MatroskaDemuxError::None;
  std::vector<std::byte> tooSmall(4);
  expect(!asset.copyRanges(single, tooSmall, {}, &shortError) &&
             shortError == MatroskaDemuxError::InvalidRequest,
         "a destination smaller than the ranges is refused");
  const std::array<FrameRange, 2> doubled{FrameRange{large->frames[0]},
                                          FrameRange{large->frames[0]}};
  MatroskaDemuxError aggregateError = MatroskaDemuxError::None;
  expect(!asset.copyRanges(doubled, destination, {}, &aggregateError) &&
             aggregateError == MatroskaDemuxError::SampleLimit,
         "ranges whose running total passes the destination fail SampleLimit");
  MatroskaDemuxError longError = MatroskaDemuxError::None;
  std::vector<std::byte> tooLarge(spec.largeVideoFrameBytes + 1U);
  expect(!asset.copyRanges(single, tooLarge, {}, &longError) &&
             longError == MatroskaDemuxError::InvalidRequest,
         "a destination larger than the ranges is refused");
  MatroskaDemuxError emptyError = MatroskaDemuxError::Io;
  expect(asset.copyRanges({}, {}, {}, &emptyError) &&
             emptyError == MatroskaDemuxError::None,
         "an empty copy request succeeds without any read");

  std::atomic<bool> cancelled{false};
  const CancellationToken token{&cancelled, atomicCancellation};
  prepared.reader->cancellation = &cancelled;
  prepared.reader->cancelAtRead = prepared.reader->reads + 1U;
  MatroskaDemuxError cancelError = MatroskaDemuxError::None;
  const bool cancelledCopy =
      asset.copyRanges(single, destination, token, &cancelError);
  prepared.reader->cancelAtRead = 0;
  prepared.reader->cancellation = nullptr;
  expect(!cancelledCopy && cancelError == MatroskaDemuxError::Cancelled,
         "cancellation between split reads reports Cancelled exactly");

  std::atomic<bool> preCancelled{true};
  MatroskaDemuxError preError = MatroskaDemuxError::None;
  expect(!asset.copyRanges(single, destination,
                           {&preCancelled, atomicCancellation}, &preError) &&
             preError == MatroskaDemuxError::Cancelled,
         "an already cancelled copy performs no read");

  std::atomic<bool> lateCancelled{false};
  const std::array<FrameRange, 1> tiny{
      FrameRange{fixture.videoBlocks.front().frames[0]}};
  std::vector<std::byte> tinyDestination(
      static_cast<std::size_t>(tiny[0].bytes.size));
  prepared.reader->cancellation = &lateCancelled;
  prepared.reader->cancelAtRead = prepared.reader->reads + 1U;
  MatroskaDemuxError lateError = MatroskaDemuxError::None;
  const bool lateCopy = asset.copyRanges(
      tiny, tinyDestination, {&lateCancelled, atomicCancellation}, &lateError);
  prepared.reader->cancelAtRead = 0;
  prepared.reader->cancellation = nullptr;
  expect(!lateCopy && lateError == MatroskaDemuxError::Cancelled,
         "cancellation raised by the final read still reports Cancelled");

  prepared.reader->shrink();
  MatroskaDemuxError changedError = MatroskaDemuxError::None;
  expect(!asset.copyRanges(single, destination, {}, &changedError) &&
             changedError == MatroskaDemuxError::FileChanged,
         "a shrunken reader fails the copy with FileChanged");
  prepared.reader->restore();

  prepared.reader->failAtRead = prepared.reader->reads + 1U;
  MatroskaDemuxError ioError = MatroskaDemuxError::None;
  expect(!asset.copyRanges(single, destination, {}, &ioError) &&
             ioError == MatroskaDemuxError::Io,
         "a failing read reports Io while the reader identity is unchanged");
  prepared.reader->failAtRead = 0;

  MatroskaDemuxError recoveredError = MatroskaDemuxError::Io;
  expect(asset.copyRanges(single, destination, {}, &recoveredError) &&
             recoveredError == MatroskaDemuxError::None,
         "the asset remains usable after a failed copy");
}

// ---------------------------------------------------------------------------
// 7. Mutation and cancellation proofs.
// ---------------------------------------------------------------------------

void testMutationAndCancellation() {
  {
    const PreparedFixture prepared = prepareFixture({});
    if (prepared.outcome.asset == nullptr) {
      expect(false, "mutation fixture prepares");
      return;
    }
    const MatroskaPreparedAsset& asset = prepared.asset();
    const MatroskaPlanOutcome plan =
        asset.planGeneration(MediaTime{0, 1}, MediaSeekMode::Accurate);
    if (!plan.plan) {
      expect(false, "mutation fixture plans");
      return;
    }
    auto cursor = asset.makeVideoCursor(*plan.plan);
    if (cursor == nullptr) {
      expect(false, "mutation fixture cursor is created");
      return;
    }
    expect(sampleOf(cursor->readNext()) != nullptr,
           "the cursor emits one sample before the reader mutates");
    prepared.reader->grow();
    const MatroskaCursorReadResult grown = cursor->readNext();
    const auto* grownFailure = std::get_if<MatroskaCursorFailure>(&grown);
    expect(grownFailure != nullptr &&
               grownFailure->error == MatroskaDemuxError::FileChanged,
           "a grown reader stops the cursor with FileChanged");
    expect(asset.planGeneration(MediaTime{0, 1}, MediaSeekMode::Accurate)
                   .error == MatroskaDemuxError::FileChanged,
           "planning against a grown reader fails with FileChanged");
    prepared.reader->restore();
    prepared.reader->shrink();
    const MatroskaCursorReadResult shrunk = cursor->readNext();
    const auto* shrunkFailure = std::get_if<MatroskaCursorFailure>(&shrunk);
    expect(shrunkFailure != nullptr &&
               shrunkFailure->error == MatroskaDemuxError::FileChanged,
           "a shrunken reader stops the cursor with FileChanged");
    prepared.reader->restore();
    expect(sampleOf(cursor->readNext()) != nullptr,
           "a restored reader lets the same cursor continue deterministically");
  }
  {
    const PreparedFixture prepared = prepareFixture({});
    if (prepared.outcome.asset == nullptr) {
      return;
    }
    const MatroskaPlanOutcome plan = prepared.asset().planGeneration(
        MediaTime{0, 1}, MediaSeekMode::Accurate);
    if (!plan.plan) {
      return;
    }
    auto cursor = prepared.asset().makeVideoCursor(*plan.plan);
    if (cursor == nullptr) {
      return;
    }
    prepared.reader->failAtRead = prepared.reader->reads + 1U;
    const MatroskaCursorReadResult result = cursor->readNext();
    const auto* failure = std::get_if<MatroskaCursorFailure>(&result);
    expect(failure != nullptr && failure->error == MatroskaDemuxError::Io,
           "a failing read stops the cursor with Io and no undefined behavior");
    prepared.reader->failAtRead = 0;
  }
  {
    Fixture fixture = buildFixture({});
    auto reader = std::make_shared<ProbeReader>(fixture.bytes);
    std::atomic<bool> cancelled{true};
    const auto outcome = prepareMatroska(reader, kFixturePath, {},
                                         {&cancelled, atomicCancellation});
    expect(outcome.status == MatroskaDemuxStatus::Cancelled &&
               outcome.error == MatroskaDemuxError::Cancelled &&
               reader->reads == 0,
           "preparation cancelled before I/O performs no read");
  }
  {
    Fixture fixture = buildFixture({});
    for (const std::size_t at : {std::size_t{1}, std::size_t{4},
                                 std::size_t{16}, std::size_t{64}}) {
      auto reader = std::make_shared<ProbeReader>(fixture.bytes);
      std::atomic<bool> cancelled{false};
      reader->cancellation = &cancelled;
      reader->cancelAtRead = at;
      const auto outcome = prepareMatroska(reader, kFixturePath, {},
                                           {&cancelled, atomicCancellation});
      expect(outcome.asset == nullptr &&
                 outcome.error == MatroskaDemuxError::Cancelled &&
                 outcome.status == MatroskaDemuxStatus::Cancelled,
             "preparation cancelled mid-parse reports Cancelled exactly");
    }
  }
  {
    const PreparedFixture prepared = prepareFixture({});
    if (prepared.outcome.asset == nullptr) {
      return;
    }
    std::atomic<bool> cancelled{true};
    const CancellationToken token{&cancelled, atomicCancellation};
    const MatroskaPlanOutcome outcome = prepared.asset().planGeneration(
        MediaTime{1, 2}, MediaSeekMode::Accurate, token);
    expect(outcome.status == MatroskaDemuxStatus::Cancelled &&
               outcome.error == MatroskaDemuxError::Cancelled,
           "planning observes cancellation before it scans any cluster");

    const MatroskaPlanOutcome plan = prepared.asset().planGeneration(
        MediaTime{0, 1}, MediaSeekMode::Accurate);
    if (!plan.plan) {
      return;
    }
    auto cursor = prepared.asset().makeVideoCursor(*plan.plan);
    if (cursor == nullptr) {
      return;
    }
    expect(std::holds_alternative<MatroskaCursorCancelled>(
               cursor->readNext(token)),
           "a cancelled cursor read returns the cancelled marker");
    expect(sampleOf(cursor->readNext()) != nullptr,
           "a cancelled read leaves the cursor position untouched");
  }
  {
    // Cancellation raised by the reader in the middle of a cluster walk.
    const PreparedFixture prepared = prepareFixture({});
    if (prepared.outcome.asset == nullptr) {
      return;
    }
    const MatroskaPlanOutcome plan = prepared.asset().planGeneration(
        MediaTime{0, 1}, MediaSeekMode::Accurate);
    if (!plan.plan) {
      return;
    }
    auto cursor = prepared.asset().makeVideoCursor(*plan.plan);
    if (cursor == nullptr) {
      return;
    }
    std::atomic<bool> cancelled{false};
    prepared.reader->cancellation = &cancelled;
    prepared.reader->cancelAtRead = prepared.reader->reads + 1U;
    const MatroskaCursorReadResult result =
        cursor->readNext({&cancelled, atomicCancellation});
    prepared.reader->cancelAtRead = 0;
    prepared.reader->cancellation = nullptr;
    const bool cancelledOrEmitted =
        std::holds_alternative<MatroskaCursorCancelled>(result) ||
        sampleOf(result) != nullptr;
    expect(cancelledOrEmitted,
           "a read cancelled by its own I/O never becomes a failure");
    cancelled.store(false, std::memory_order_release);
    const MatroskaCursorReadResult resumed = cursor->readNext();
    expect(sampleOf(resumed) != nullptr,
           "the cursor resumes exactly after an in-flight cancellation");
    if (const MatroskaCompressedSample* first = sampleOf(result);
        first != nullptr) {
      const MatroskaCompressedSample* second = sampleOf(resumed);
      expect(second != nullptr &&
                 second->frames[0].bytes.offset > first->frames[0].bytes.offset,
             "a cancelled walk never re-emits or skips a Block");
    }
  }
}

// ---------------------------------------------------------------------------
// 8. Malformed input hardening.
// ---------------------------------------------------------------------------

void testMalformedDocuments() {
  {
    FixtureSpec spec;
    spec.cues = CueVariant::Absent;
    expectPrepareError(spec, MatroskaDemuxError::MissingCues,
                       "a document without Cues is refused");
  }
  {
    // A stream-copied Matroska routinely places its first video keyframe a few
    // milliseconds after zero (FFmpeg emits a first CueTime of 21 ms for a
    // 30 fps remux), and that cue is the true origin of the video timeline.
    // planGeneration clamps any earlier target to cue zero, so a non-zero
    // first cue is admitted rather than rejected.
    FixtureSpec spec;
    spec.cues = CueVariant::NonZeroFirst;
    const PreparedFixture prepared = prepareFixture(spec);
    expect(prepared.outcome.status == MatroskaDemuxStatus::Ready &&
               prepared.outcome.asset != nullptr,
           "selected-video Cues may begin after tick zero");
  }
  {
    FixtureSpec spec;
    spec.cues = CueVariant::AudioTrackOnly;
    expectPrepareError(spec, MatroskaDemuxError::MissingCues,
                       "Cues for an unselected track leave the video unindexed");
  }
  {
    FixtureSpec spec;
    spec.cues = CueVariant::Unsorted;
    expectPrepareError(spec, MatroskaDemuxError::InvalidCue,
                       "unsorted selected-video Cues are rejected");
  }
  {
    FixtureSpec spec;
    spec.cues = CueVariant::DuplicateTime;
    expectPrepareError(spec, MatroskaDemuxError::InvalidCue,
                       "duplicate selected-video Cue times are rejected");
  }
  {
    FixtureSpec spec;
    spec.cues = CueVariant::NoRelativePosition;
    expectPrepareError(spec, MatroskaDemuxError::InvalidCue,
                       "a Cue without CueRelativePosition is rejected");
  }
  {
    FixtureSpec spec;
    spec.cues = CueVariant::BlockNumberTwo;
    expectPrepareError(spec, MatroskaDemuxError::InvalidCue,
                       "a Cue naming a second block in its group is rejected");
  }
  {
    FixtureSpec spec;
    spec.cues = CueVariant::OutsideCluster;
    expectPrepareError(spec, MatroskaDemuxError::InvalidContainer,
                       "a Cue pointing outside any Cluster is rejected");
  }
  {
    FixtureSpec spec;
    spec.clusterTimestamps = {0, 13'000};
    spec.durationTicks = 14'000.0;
    spec.includeAudioTrack = false;
    spec.includeSubtitleTrack = false;
    expectPrepareError(spec, MatroskaDemuxError::InvalidCue,
                       "a Cue gap beyond the bounded seek preroll is rejected");
  }
  {
    FixtureSpec spec;
    spec.clusterTimestamps = {0, 500, 400};
    spec.durationTicks = 1'500.0;
    spec.includeAudioTrack = false;
    spec.includeSubtitleTrack = false;
    expectPrepareError(spec, MatroskaDemuxError::InvalidTimeline,
                       "a non-monotonic Cluster timeline is refused");
  }
  {
    const Fixture fixture = buildFixture({});
    for (const std::size_t trim : {std::size_t{1}, std::size_t{7},
                                   std::size_t{40}, std::size_t{200}}) {
      Bytes truncated = fixture.bytes;
      truncated.resize(truncated.size() - trim);
      auto reader = std::make_shared<ProbeReader>(std::move(truncated));
      const auto outcome = prepareMatroska(reader, kFixturePath, {});
      expect(outcome.asset == nullptr &&
                 outcome.status != MatroskaDemuxStatus::Ready,
             "a truncated document never prepares an asset");
    }
  }
  {
    const Fixture fixture = buildFixture({});
    Bytes noHeader(fixture.bytes.begin() +
                       static_cast<std::ptrdiff_t>(ebmlHeader().size()),
                   fixture.bytes.end());
    auto reader = std::make_shared<ProbeReader>(std::move(noHeader));
    const auto outcome = prepareMatroska(reader, kFixturePath, {});
    expect(outcome.asset == nullptr &&
               outcome.error == MatroskaDemuxError::InvalidContainer,
           "a Segment without its EBML header is not a Matroska document");
  }
  {
    const Fixture fixture = buildFixture({});
    Bytes twoDocuments = fixture.bytes;
    append(twoDocuments, fixture.bytes);
    auto reader = std::make_shared<ProbeReader>(std::move(twoDocuments));
    const auto outcome = prepareMatroska(reader, kFixturePath, {});
    expect(outcome.asset == nullptr &&
               outcome.error == MatroskaDemuxError::UnsupportedContainer &&
               outcome.status == MatroskaDemuxStatus::Unsupported,
           "a trailing second document is explicitly unsupported");
  }
  {
    FixtureSpec spec;
    spec.durationTicks = 0.0;
    const Fixture fixture = buildFixture(spec);
    auto reader = std::make_shared<ProbeReader>(fixture.bytes);
    const auto outcome = prepareMatroska(reader, kFixturePath, {});
    expect(outcome.asset == nullptr &&
               outcome.status != MatroskaDemuxStatus::Ready,
           "a zero Duration is refused");
  }
  {
    // A Cluster whose declared size runs past the Segment boundary.
    Bytes segmentPayload;
    Bytes infoPayload;
    append(infoPayload,
           uintElement(kTimestampScaleId, kTimestampScaleNanoseconds));
    append(infoPayload, doubleElement(kDurationId, 1'000.0));
    append(segmentPayload, element(kInfoId, infoPayload));
    FixtureSpec spec;
    spec.includeAudioTrack = false;
    spec.includeSubtitleTrack = false;
    append(segmentPayload, element(kTracksId, videoTrackEntry(spec)));
    Bytes overrun;
    appendId(overrun, kClusterId);
    appendSize(overrun, 4'096);
    append(overrun, uintElement(kClusterTimestampId, 0));
    append(segmentPayload, overrun);
    Bytes bytes = ebmlHeader();
    append(bytes, element(kSegmentId, segmentPayload));
    auto reader = std::make_shared<ProbeReader>(std::move(bytes));
    const auto outcome = prepareMatroska(reader, kFixturePath, {});
    expect(outcome.asset == nullptr &&
               outcome.error == MatroskaDemuxError::InvalidContainer,
           "a Cluster claiming bytes past the Segment is rejected");
  }
  {
    // Void padding at Segment and Cluster level must not disturb any exact
    // offset the demuxer retains.
    FixtureSpec spec;
    spec.voidPaddingBytes = 23;
    const PreparedFixture prepared = prepareFixture(spec);
    expect(prepared.outcome.status == MatroskaDemuxStatus::Ready &&
               prepared.outcome.asset != nullptr,
           "Segment and Cluster Void padding still prepares Ready");
    if (prepared.outcome.asset == nullptr) {
      return;
    }
    const Fixture& padded = prepared.fixture;
    bool exact = prepared.asset().clusters().size() ==
                     padded.clusterEncodedOffsets.size() &&
                 prepared.asset().cues().size() == padded.cueTicks.size();
    for (std::size_t index = 0;
         exact && index < prepared.asset().clusters().size(); ++index) {
      exact = prepared.asset().clusters()[index].encodedOffset ==
              padded.clusterEncodedOffsets[index];
    }
    const MatroskaPlanOutcome plan = prepared.asset().planGeneration(
        MediaTime{1, 2}, MediaSeekMode::KeyFrame);
    expect(plan.plan.has_value(), "the padded document plans a key-frame seek");
    if (!plan.plan) {
      return;
    }
    auto cursor = prepared.asset().makeVideoCursor(*plan.plan);
    expect(cursor != nullptr, "the padded document creates a video cursor");
    if (cursor == nullptr) {
      return;
    }
    const MatroskaCursorReadResult result = cursor->readNext();
    const MatroskaCompressedSample* sample = sampleOf(result);
    const BlockFacts* planned =
        padded.videoBlockAt(plan.plan->videoBlockOffset);
    expect(exact && sample != nullptr && planned != nullptr &&
               sample->frames[0] == FrameRange{planned->frames[0]},
           "Void padding never shifts a retained Cluster, Cue, or frame range");
  }
}

struct SparseDocument {
  std::uint64_t reportedSize{0};
  std::vector<std::pair<std::uint64_t, Bytes>> chunks;
};

// One Cluster holding a small random access point and a SimpleBlock whose
// declared size is caller controlled. Only headers are ever materialized.
SparseDocument buildGiantBlockDocument(std::uint64_t giantDataSize,
                                       bool cueTargetsGiantBlock) {
  FixtureSpec spec;
  spec.includeAudioTrack = false;
  spec.includeSubtitleTrack = false;

  Bytes infoPayload;
  append(infoPayload,
         uintElement(kTimestampScaleId, kTimestampScaleNanoseconds));
  append(infoPayload, doubleElement(kDurationId, 1'000.0));
  const Bytes infoElement = element(kInfoId, infoPayload);
  const Bytes tracksElement = element(kTracksId, videoTrackEntry(spec));
  const Bytes timestamp = uintElement(kClusterTimestampId, 0);

  std::uint8_t fill = 1;
  const std::array<std::size_t, 1> smallSizes{1};
  const BuiltBlock small = buildSimpleBlock(1, 0, 0, true, false, false,
                                            Lacing::None, smallSizes, fill);
  Bytes giantHeader;
  appendId(giantHeader, kSimpleBlockId);
  appendVintOfWidth(giantHeader, giantDataSize, 8);
  const Bytes giantBodyPrefix = blockBody(0x80U, {}, 0, 1);

  const auto clusterDataSize =
      static_cast<std::uint64_t>(timestamp.size() + small.bytes.size() +
                                 giantHeader.size()) +
      giantDataSize;
  Bytes clusterPrefix;
  appendId(clusterPrefix, kClusterId);
  appendVintOfWidth(clusterPrefix, clusterDataSize, 8);

  const auto clusterRelative =
      static_cast<std::uint64_t>(infoElement.size() + tracksElement.size());
  const std::uint64_t clusterDataRelative =
      clusterRelative + static_cast<std::uint64_t>(clusterPrefix.size());
  const std::uint64_t smallRelative =
      clusterDataRelative + static_cast<std::uint64_t>(timestamp.size());
  const std::uint64_t giantRelative =
      smallRelative + static_cast<std::uint64_t>(small.bytes.size());

  CuePointSpec point;
  point.time = 0;
  point.track = 1;
  point.clusterPosition = clusterRelative;
  point.relativePosition =
      (cueTargetsGiantBlock ? giantRelative : smallRelative) -
      clusterDataRelative;
  point.blockNumber = 1;
  const std::array<CuePointSpec, 1> points{point};
  const Bytes cuesBytes = cuesElement(points);

  const std::uint64_t segmentPayloadSize =
      clusterDataRelative + clusterDataSize +
      static_cast<std::uint64_t>(cuesBytes.size());
  Bytes headBytes = ebmlHeader();
  Bytes segmentPrefix;
  appendId(segmentPrefix, kSegmentId);
  appendVintOfWidth(segmentPrefix, segmentPayloadSize, 8);
  const auto segmentDataOffset =
      static_cast<std::uint64_t>(headBytes.size() + segmentPrefix.size());
  append(headBytes, segmentPrefix);
  append(headBytes, infoElement);
  append(headBytes, tracksElement);
  append(headBytes, clusterPrefix);
  append(headBytes, timestamp);
  append(headBytes, small.bytes);
  append(headBytes, giantHeader);
  append(headBytes, giantBodyPrefix);

  SparseDocument sparse;
  sparse.reportedSize = segmentDataOffset + segmentPayloadSize;
  sparse.chunks.emplace_back(0, std::move(headBytes));
  sparse.chunks.emplace_back(
      segmentDataOffset + clusterDataRelative + clusterDataSize, cuesBytes);
  return sparse;
}

void testStructuralByteCeilings() {
  {
    // Encoded SimpleBlock of exactly kMaximumMatroskaEncodedBlockBytes + 1.
    SparseDocument sparse = buildGiantBlockDocument(
        kMaximumMatroskaEncodedBlockBytes + 1U - 9U, true);
    auto reader = std::make_shared<SparseReader>(sparse.reportedSize,
                                                 std::move(sparse.chunks));
    const auto outcome = prepareMatroska(reader, kFixturePath, {});
    expect(outcome.asset == nullptr &&
               outcome.error == MatroskaDemuxError::SampleLimit,
           "an encoded Block past the 64 MiB ceiling fails SampleLimit");
  }
  {
    // The same Block one byte smaller passes the Block ceiling, but its
    // Cluster then exceeds kMaximumMatroskaClusterBytes.
    SparseDocument sparse =
        buildGiantBlockDocument(kMaximumMatroskaEncodedBlockBytes - 9U, false);
    auto reader = std::make_shared<SparseReader>(sparse.reportedSize,
                                                 std::move(sparse.chunks));
    const auto outcome = prepareMatroska(reader, kFixturePath, {});
    expect(outcome.asset == nullptr &&
               outcome.error == MatroskaDemuxError::InvalidTimeline,
           "a Cluster past the 64 MiB ceiling is not indexable");
  }
  {
    SparseDocument sparse = buildGiantBlockDocument(1'024U, false);
    auto reader = std::make_shared<SparseReader>(sparse.reportedSize,
                                                 std::move(sparse.chunks));
    const auto outcome = prepareMatroska(reader, kFixturePath, {});
    expect(outcome.status == MatroskaDemuxStatus::Ready &&
               outcome.asset != nullptr &&
               outcome.asset->clusters().size() == 1U,
           "the same sparse layout under both ceilings prepares normally");
  }
}

// ---------------------------------------------------------------------------
// Cursor ownership: a cursor keeps its immutable asset state alive.
// ---------------------------------------------------------------------------

void testCursorOwnershipAndMoves() {
  Fixture fixture = buildFixture({});
  auto reader = std::make_shared<ProbeReader>(fixture.bytes);
  MatroskaPrepareOutcome outcome =
      prepareMatroska(reader, kFixturePath, {});
  if (outcome.asset == nullptr) {
    expect(false, "cursor ownership fixture prepares");
    return;
  }
  const MatroskaPlanOutcome plan =
      outcome.asset->planGeneration(MediaTime{0, 1}, MediaSeekMode::Accurate);
  if (!plan.plan) {
    expect(false, "cursor ownership fixture plans");
    return;
  }
  auto videoCursor = outcome.asset->makeVideoCursor(*plan.plan);
  auto audioCursor = outcome.asset->makeAudioCursor(*plan.plan);
  expect(videoCursor != nullptr && audioCursor != nullptr,
         "both cursors are created before the asset handle is released");
  if (videoCursor == nullptr || audioCursor == nullptr) {
    return;
  }
  outcome.asset.reset();
  expect(sampleOf(videoCursor->readNext()) != nullptr &&
             sampleOf(audioCursor->readNext()) != nullptr,
         "cursors keep the immutable asset state alive after the asset drops");

  MatroskaCursor moved(std::move(*videoCursor));
  expect(sampleOf(moved.readNext()) != nullptr,
         "a moved-to cursor continues exactly where its source stopped");
  MatroskaCursor target(std::move(*audioCursor));
  target = std::move(moved);
  expect(sampleOf(target.readNext()) != nullptr,
         "move assignment preserves the surviving cursor position");
}

// ---------------------------------------------------------------------------
// Local-file preparation retains one descriptor for its whole lifetime.
// ---------------------------------------------------------------------------

void testLocalFilePreparation() {
  const Fixture fixture = buildFixture({});
  std::array<char, 64> path{};
  const std::string pattern = "/private/tmp/wam-matroska-demuxer-XXXXXX";
  std::copy(pattern.begin(), pattern.end(), path.begin());
  const int descriptor = ::mkstemp(path.data());
  expect(descriptor >= 0, "temporary Matroska fixture opens");
  if (descriptor < 0) {
    return;
  }
  std::size_t written = 0;
  while (written < fixture.bytes.size()) {
    const auto count = ::write(
        descriptor, fixture.bytes.data() + static_cast<std::ptrdiff_t>(written),
        fixture.bytes.size() - written);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      break;
    }
    written += static_cast<std::size_t>(count);
  }
  static_cast<void>(::close(descriptor));
  expect(written == fixture.bytes.size(), "temporary fixture is written whole");

  const std::filesystem::path localPath(path.data());
  const auto outcome = prepareMatroskaLocalFile(localPath, {});
  expect(outcome.status == MatroskaDemuxStatus::Ready && outcome.asset &&
             outcome.asset->path() == localPath,
         "a real local Matroska file prepares through one retained descriptor");
  if (outcome.asset) {
    const MatroskaPlanOutcome plan = outcome.asset->planGeneration(
        MediaTime{1, 2}, MediaSeekMode::KeyFrame);
    expect(plan.status == MatroskaDemuxStatus::Ready,
           "the local-file asset plans a mid-stream key-frame seek");
    if (plan.plan) {
      auto cursor = outcome.asset->makeVideoCursor(*plan.plan);
      expect(cursor != nullptr && sampleOf(cursor->readNext()) != nullptr,
             "the local-file asset emits its planned video sample");
    }
    const int appender = ::open(path.data(), O_WRONLY | O_APPEND);
    if (appender >= 0) {
      const std::byte extra{0};
      static_cast<void>(::write(appender, &extra, 1));
      static_cast<void>(::close(appender));
    }
    const MatroskaPlanOutcome afterGrowth = outcome.asset->planGeneration(
        MediaTime{0, 1}, MediaSeekMode::KeyFrame);
    expect(afterGrowth.error == MatroskaDemuxError::FileChanged,
           "growing the local file invalidates the retained asset identity");
  }

  std::atomic<bool> cancelled{true};
  const auto cancelledOutcome = prepareMatroskaLocalFile(
      localPath, {}, {&cancelled, atomicCancellation});
  expect(cancelledOutcome.status == MatroskaDemuxStatus::Cancelled &&
             cancelledOutcome.error == MatroskaDemuxError::Cancelled,
         "local-file preparation honors cancellation before opening");

  const auto missing = prepareMatroskaLocalFile(
      std::filesystem::path("/private/tmp/wam-matroska-demuxer-absent"), {});
  expect(missing.asset == nullptr && missing.error == MatroskaDemuxError::Io,
         "a missing local file fails with Io");

  static_cast<void>(::unlink(path.data()));
}

}  // namespace

int main() {
  testCompleteDocumentPreparation();
  testPreparationRequestValidation();
  testBoundedIndexes();
  testCodecAdmissionAndSelection();
  testAccuratePlanning();
  testKeyFramePlanning();
  testPlanningRejectsNonRandomAccessCue();
  testPlanningWithoutAudio();
  testVideoCursor();
  testAudioCursorLacingAndGrid();
  testCursorSampleLimits();
  testCursorOwnershipAndMoves();
  testCopyRanges();
  testMutationAndCancellation();
  testMalformedDocuments();
  testStructuralByteCeilings();
  testLocalFilePreparation();
  if (failures != 0) {
    std::cerr << failures << " Matroska demuxer test(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "Matroska demuxer tests passed\n";
  return EXIT_SUCCESS;
}
