#include "platform/macos/native_video_pipeline.hpp"
#include "platform/macos/native_video_codec_capability.hpp"
#include "platform/macos/native_video_limits.hpp"

#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include <mach/mach.h>
#include <sys/resource.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <optional>
#include <span>
#include <string>
#include <thread>
#include <vector>

namespace {

void check(bool condition, const char* expression, int line,
           const std::string& detail = {}) {
  if (condition) {
    return;
  }
  std::cerr << "CHECK failed at line " << line << ": " << expression;
  if (!detail.empty()) {
    std::cerr << " (" << detail << ')';
  }
  std::cerr << '\n';
  std::exit(EXIT_FAILURE);
}

#define WAM_CHECK(expression)                                                  \
  check(static_cast<bool>(expression), #expression, __LINE__)
#define WAM_CHECK_DETAIL(expression, detail)                                   \
  check(static_cast<bool>(expression), #expression, __LINE__, (detail))

void checkNativeVideoLimitContract() {
  using namespace wam::macos::native_video_limits;
  static_assert(kMaximumCompressedVideoAccessUnitBytes ==
                8ULL * 1024ULL * 1024ULL);
  static_assert(kMaximumVideoCodecConfigurationBytes ==
                256ULL * 1024ULL);
  static_assert(kMaximumTransientVideoCodecConfigurationBytes ==
                768ULL * 1024ULL);
  static_assert(kMaximumRetainedVideoCodecConfigurationBytes ==
                256ULL * 1024ULL);
  static_assert(kMaximumPipelineInFlightAccessUnits == 2);
  static_assert(kMaximumPipelineLogicalCompressedVideoBytes ==
                24ULL * 1024ULL * 1024ULL);
  static_assert(acceptsCompressedVideoAccessUnitSize(
      kMaximumCompressedVideoAccessUnitBytes));
  static_assert(!acceptsCompressedVideoAccessUnitSize(
      kMaximumCompressedVideoAccessUnitBytes + 1));
  static_assert(acceptsVideoCodecConfigurationSize(
      kMaximumVideoCodecConfigurationBytes));
  static_assert(!acceptsVideoCodecConfigurationSize(
      kMaximumVideoCodecConfigurationBytes + 1));

  WAM_CHECK(acceptsCompressedVideoAccessUnitSize(
      kMaximumCompressedVideoAccessUnitBytes));
  WAM_CHECK(!acceptsCompressedVideoAccessUnitSize(
      kMaximumCompressedVideoAccessUnitBytes + 1));
  WAM_CHECK(acceptsVideoCodecConfigurationSize(
      kMaximumVideoCodecConfigurationBytes));
  WAM_CHECK(!acceptsVideoCodecConfigurationSize(
      kMaximumVideoCodecConfigurationBytes + 1));
}

class TestBitWriter final {
 public:
  void bits(std::uint32_t value, std::size_t count) {
    for (std::size_t index = count; index > 0; --index) {
      bit(((value >> (index - 1U)) & 1U) != 0);
    }
  }

  void unsignedExpGolomb(std::uint32_t value) {
    const std::uint64_t code = static_cast<std::uint64_t>(value) + 1U;
    std::size_t significantBits = 0;
    for (std::uint64_t remaining = code; remaining != 0;
         remaining >>= 1U) {
      ++significantBits;
    }
    for (std::size_t index = 1; index < significantBits; ++index) {
      bit(false);
    }
    bits(static_cast<std::uint32_t>(code), significantBits);
  }

  void bit(bool value) {
    const std::size_t bitInByte = bitCount_ % 8;
    if (bitInByte == 0) {
      bytes_.push_back(std::byte{0});
    }
    if (value) {
      bytes_.back() |= std::byte{static_cast<std::uint8_t>(
          1U << (7U - static_cast<unsigned>(bitInByte)))};
    }
    ++bitCount_;
  }

  std::vector<std::byte> finishRbsp() {
    bit(true);
    while (bitCount_ % 8 != 0) {
      bit(false);
    }
    return std::move(bytes_);
  }

 private:
  std::vector<std::byte> bytes_;
  std::size_t bitCount_{0};
};

std::vector<std::byte> escapeRbsp(std::span<const std::byte> rbsp) {
  std::vector<std::byte> escaped;
  std::size_t zeroCount = 0;
  for (const std::byte byte : rbsp) {
    const std::uint8_t value = std::to_integer<std::uint8_t>(byte);
    if (zeroCount >= 2 && value <= 3) {
      escaped.push_back(std::byte{0x03});
      zeroCount = 0;
    }
    escaped.push_back(byte);
    zeroCount = value == 0 ? zeroCount + 1 : 0;
  }
  return escaped;
}

std::vector<std::byte> makeH264Configuration(
    std::uint8_t profile, std::uint32_t chromaFormat = 1,
    std::uint32_t lumaDepthMinusEight = 0,
    std::uint32_t chromaDepthMinusEight = 0,
    std::optional<std::uint8_t> summaryProfile = std::nullopt) {
  TestBitWriter bits;
  bits.bits(profile, 8);
  bits.bits(0, 8);
  bits.bits(31, 8);
  bits.unsignedExpGolomb(0);
  if (profile == 100) {
    bits.unsignedExpGolomb(chromaFormat);
    bits.unsignedExpGolomb(lumaDepthMinusEight);
    bits.unsignedExpGolomb(chromaDepthMinusEight);
  }
  std::vector<std::byte> nal{std::byte{0x67}};
  std::vector<std::byte> rbsp = escapeRbsp(bits.finishRbsp());
  nal.insert(nal.end(), rbsp.begin(), rbsp.end());

  std::vector<std::byte> configuration{
      std::byte{0x01}, std::byte{summaryProfile.value_or(profile)},
      std::byte{0x00}, std::byte{0x1f}, std::byte{0xff}, std::byte{0xe1},
      std::byte{static_cast<std::uint8_t>((nal.size() >> 8U) & 0xffU)},
      std::byte{static_cast<std::uint8_t>(nal.size() & 0xffU)}};
  configuration.insert(configuration.end(), nal.begin(), nal.end());
  return configuration;
}

std::vector<std::byte> makeHevcConfiguration(
    std::uint32_t chromaFormat, std::uint32_t lumaDepthMinusEight,
    std::uint32_t chromaDepthMinusEight,
    std::optional<std::uint8_t> summaryChroma = std::nullopt,
    std::optional<std::uint8_t> summaryLumaDepth = std::nullopt,
    std::optional<std::uint8_t> summaryChromaDepth = std::nullopt) {
  TestBitWriter bits;
  bits.bits(0, 4);
  bits.bits(0, 3);
  bits.bit(true);
  bits.bits(0, 32);
  bits.bits(0, 32);
  bits.bits(0, 32);
  bits.unsignedExpGolomb(0);
  bits.unsignedExpGolomb(chromaFormat);
  bits.unsignedExpGolomb(320);
  bits.unsignedExpGolomb(180);
  bits.bit(false);
  bits.unsignedExpGolomb(lumaDepthMinusEight);
  bits.unsignedExpGolomb(chromaDepthMinusEight);
  std::vector<std::byte> nal{std::byte{0x42}, std::byte{0x01}};
  std::vector<std::byte> rbsp = escapeRbsp(bits.finishRbsp());
  nal.insert(nal.end(), rbsp.begin(), rbsp.end());

  std::vector<std::byte> configuration(23, std::byte{0});
  configuration[0] = std::byte{0x01};
  configuration[13] = std::byte{0xf0};
  configuration[15] = std::byte{0xfc};
  configuration[16] = std::byte{static_cast<std::uint8_t>(
      0xfcU | summaryChroma.value_or(chromaFormat))};
  configuration[17] = std::byte{static_cast<std::uint8_t>(
      0xf8U | summaryLumaDepth.value_or(lumaDepthMinusEight))};
  configuration[18] = std::byte{static_cast<std::uint8_t>(
      0xf8U | summaryChromaDepth.value_or(chromaDepthMinusEight))};
  configuration[21] = std::byte{0x03};
  configuration[22] = std::byte{0x01};
  configuration.push_back(std::byte{0xa1});
  configuration.push_back(std::byte{0x00});
  configuration.push_back(std::byte{0x01});
  configuration.push_back(
      std::byte{static_cast<std::uint8_t>((nal.size() >> 8U) & 0xffU)});
  configuration.push_back(
      std::byte{static_cast<std::uint8_t>(nal.size() & 0xffU)});
  configuration.insert(configuration.end(), nal.begin(), nal.end());
  return configuration;
}

void checkSampleFormatAdmissionModel() {
  using wam::macos::NativeVideoSampleFormatAdmission;
  const auto admission = [](CMVideoCodecType codec,
                            const std::vector<std::byte>& configuration) {
    return wam::macos::nativeVideoSampleFormatAdmission(
        codec, std::span<const std::byte>(configuration));
  };

  WAM_CHECK(admission(kCMVideoCodecType_H264,
                      makeH264Configuration(66)) ==
            NativeVideoSampleFormatAdmission::Yuv420EightBit);
  WAM_CHECK(admission(kCMVideoCodecType_H264,
                      makeH264Configuration(100)) ==
            NativeVideoSampleFormatAdmission::Yuv420EightBit);
  for (const auto& configuration : {
           makeH264Configuration(100, 2),
           makeH264Configuration(100, 3),
           makeH264Configuration(100, 1, 2, 2),
           makeH264Configuration(110, 1, 2, 2),
           makeH264Configuration(144, 3),
           makeH264Configuration(100, 1, 0, 0, 66)}) {
    WAM_CHECK(admission(kCMVideoCodecType_H264, configuration) ==
              NativeVideoSampleFormatAdmission::Unsupported);
  }

  const auto hevcEight = makeHevcConfiguration(1, 0, 0);
  const auto hevcTen = makeHevcConfiguration(1, 2, 2);
  WAM_CHECK(admission(kCMVideoCodecType_HEVC, hevcEight) ==
            NativeVideoSampleFormatAdmission::Yuv420EightBit);
  WAM_CHECK(admission(kCMVideoCodecType_HEVC, hevcTen) ==
            NativeVideoSampleFormatAdmission::Yuv420TenBit);
  for (const auto& configuration : {
           makeHevcConfiguration(1, 4, 4),
           makeHevcConfiguration(2, 0, 0),
           makeHevcConfiguration(3, 0, 0),
           makeHevcConfiguration(1, 0, 0, 1, 2, 2)}) {
    WAM_CHECK(admission(kCMVideoCodecType_HEVC, configuration) ==
              NativeVideoSampleFormatAdmission::Unsupported);
  }

  std::vector<std::byte> wrongNal = hevcEight;
  WAM_CHECK(wrongNal.size() > 28);
  wrongNal[28] = std::byte{0x40};
  WAM_CHECK(admission(kCMVideoCodecType_HEVC, wrongNal) ==
            NativeVideoSampleFormatAdmission::Unsupported);
  std::vector<std::byte> truncated = hevcEight;
  truncated.pop_back();
  WAM_CHECK(admission(kCMVideoCodecType_HEVC, truncated) ==
            NativeVideoSampleFormatAdmission::Unsupported);
  std::vector<std::byte> lengthOverflow = hevcEight;
  lengthOverflow[26] = std::byte{0xff};
  lengthOverflow[27] = std::byte{0xff};
  WAM_CHECK(admission(kCMVideoCodecType_HEVC, lengthOverflow) ==
            NativeVideoSampleFormatAdmission::Unsupported);
  WAM_CHECK(wam::macos::nativeVideoSampleFormatAdmission(
                kCMVideoCodecType_H264, {}) ==
            NativeVideoSampleFormatAdmission::Unsupported);
  WAM_CHECK(wam::macos::nativeVideoSampleFormatAdmission(
                kCMVideoCodecType_HEVC, {}) ==
            NativeVideoSampleFormatAdmission::Unsupported);
}

void checkAdmissionModel() {
  using wam::macos::NativeVideoCodecAdmission;
  using wam::macos::NativeVideoContainerFamily;
  using wam::macos::NativeVideoDemuxPreference;

  const auto mp4 =
      wam::macos::nativeVideoContainerAdmissionHint("/tmp/movie.MP4");
  WAM_CHECK(mp4.container == NativeVideoContainerFamily::IsoBaseMedia);
  WAM_CHECK(mp4.preferredDemux == NativeVideoDemuxPreference::AvFoundation);

  const auto m4v =
      wam::macos::nativeVideoContainerAdmissionHint("/tmp/movie.m4v");
  WAM_CHECK(m4v.container == NativeVideoContainerFamily::IsoBaseMedia);
  WAM_CHECK(m4v.preferredDemux == NativeVideoDemuxPreference::AvFoundation);

  const auto mov =
      wam::macos::nativeVideoContainerAdmissionHint("/tmp/movie.mov");
  WAM_CHECK(mov.container == NativeVideoContainerFamily::QuickTime);
  WAM_CHECK(mov.preferredDemux == NativeVideoDemuxPreference::AvFoundation);
  const auto qt =
      wam::macos::nativeVideoContainerAdmissionHint("/tmp/movie.QT");
  WAM_CHECK(qt.container == NativeVideoContainerFamily::QuickTime);
  WAM_CHECK(qt.preferredDemux == NativeVideoDemuxPreference::AvFoundation);

  const auto mkv =
      wam::macos::nativeVideoContainerAdmissionHint("/tmp/movie.mkv");
  WAM_CHECK(mkv.container == NativeVideoContainerFamily::Matroska);
  WAM_CHECK(mkv.preferredDemux ==
            NativeVideoDemuxPreference::ExternalBridgeRequired);
  const auto mk3d =
      wam::macos::nativeVideoContainerAdmissionHint("/tmp/movie.mk3d");
  WAM_CHECK(mk3d.container == NativeVideoContainerFamily::Matroska);
  WAM_CHECK(mk3d.preferredDemux ==
            NativeVideoDemuxPreference::ExternalBridgeRequired);
  const auto mka =
      wam::macos::nativeVideoContainerAdmissionHint("/tmp/movie.mka");
  WAM_CHECK(mka.container == NativeVideoContainerFamily::Matroska);

  const auto webm =
      wam::macos::nativeVideoContainerAdmissionHint("/tmp/movie.webm");
  WAM_CHECK(webm.container == NativeVideoContainerFamily::WebM);
  WAM_CHECK(webm.preferredDemux ==
            NativeVideoDemuxPreference::ExternalBridgeRequired);

  const auto avi =
      wam::macos::nativeVideoContainerAdmissionHint("/tmp/movie.AVI");
  WAM_CHECK(avi.container == NativeVideoContainerFamily::Avi);
  WAM_CHECK(avi.preferredDemux ==
            NativeVideoDemuxPreference::ProbeAvFoundation);

  const auto transport =
      wam::macos::nativeVideoContainerAdmissionHint("/tmp/movie.m2ts");
  WAM_CHECK(transport.container ==
            NativeVideoContainerFamily::MpegTransportStream);
  WAM_CHECK(transport.preferredDemux ==
            NativeVideoDemuxPreference::ProbeAvFoundation);
  for (const char* path : {"/tmp/movie.ts", "/tmp/movie.MTS"}) {
    const auto hint = wam::macos::nativeVideoContainerAdmissionHint(path);
    WAM_CHECK(hint.container ==
              NativeVideoContainerFamily::MpegTransportStream);
    WAM_CHECK(hint.preferredDemux ==
              NativeVideoDemuxPreference::ProbeAvFoundation);
  }

  for (const char* path : {"/tmp/movie.ogg", "/tmp/movie.OGV"}) {
    const auto hint = wam::macos::nativeVideoContainerAdmissionHint(path);
    WAM_CHECK(hint.container == NativeVideoContainerFamily::Ogg);
    WAM_CHECK(hint.preferredDemux ==
              NativeVideoDemuxPreference::ExternalBridgeRequired);
  }
  const auto flv =
      wam::macos::nativeVideoContainerAdmissionHint("/tmp/movie.flv");
  WAM_CHECK(flv.container == NativeVideoContainerFamily::FlashVideo);
  WAM_CHECK(flv.preferredDemux ==
            NativeVideoDemuxPreference::ExternalBridgeRequired);

  // Unknown, extensionless, hidden, and otherwise unrecognized names remain
  // probe candidates. Known external-bridge families above fail closed.
  const auto unknown =
      wam::macos::nativeVideoContainerAdmissionHint("/tmp/movie.custom");
  WAM_CHECK(unknown.container == NativeVideoContainerFamily::Unknown);
  WAM_CHECK(unknown.preferredDemux ==
            NativeVideoDemuxPreference::ProbeAvFoundation);
  const auto extensionless =
      wam::macos::nativeVideoContainerAdmissionHint("/tmp/movie");
  WAM_CHECK(extensionless.container == NativeVideoContainerFamily::Unknown);
  for (const char* path : {"/tmp/a.mov/movie", "/tmp/movie.",
                           "/tmp/.mp4", R"(C:\clips.v1\movie)"}) {
    const auto hint = wam::macos::nativeVideoContainerAdmissionHint(path);
    WAM_CHECK(hint.container == NativeVideoContainerFamily::Unknown);
    WAM_CHECK(hint.preferredDemux ==
              NativeVideoDemuxPreference::ProbeAvFoundation);
  }
  const auto windows =
      wam::macos::nativeVideoContainerAdmissionHint(R"(C:\clips.v1\movie.MOV)");
  WAM_CHECK(windows.container == NativeVideoContainerFamily::QuickTime);

  WAM_CHECK(wam::macos::nativeVideoCodecAdmission(kCMVideoCodecType_H264) ==
            NativeVideoCodecAdmission::H264);
  WAM_CHECK(wam::macos::nativeVideoCodecAdmission(kCMVideoCodecType_HEVC) ==
            NativeVideoCodecAdmission::Hevc);
  // VP9 and AV1 admission is machine-dependent: the supplemental VP9 decoder
  // may be absent and AV1 hardware decode exists only from Apple M3 onward.
  // Assert the contract against the same capability authority the production
  // gate consults, so this stays honest on hosts without the hardware.
  WAM_CHECK(wam::macos::nativeVideoCodecAdmission(kCMVideoCodecType_VP9) ==
            (wam::macos::nativeVideoToolboxSupportsVp9()
                 ? NativeVideoCodecAdmission::Vp9
                 : NativeVideoCodecAdmission::Unsupported));
  WAM_CHECK(wam::macos::nativeVideoCodecAdmission(kCMVideoCodecType_AV1) ==
            (wam::macos::nativeVideoToolboxSupportsAv1()
                 ? NativeVideoCodecAdmission::Av1
                 : NativeVideoCodecAdmission::Unsupported));
  WAM_CHECK(wam::macos::nativeVideoCodecAdmission(0x7a7a7a7aU) ==
            NativeVideoCodecAdmission::Unsupported);
  checkSampleFormatAdmissionModel();
}

std::optional<std::vector<std::byte>> fixtureCodecConfiguration(
    const std::filesystem::path& sourcePath, CMVideoCodecType* codec,
    std::string* error) {
  @autoreleasepool {
    NSString* sourceString = [NSString stringWithUTF8String:sourcePath.c_str()];
    AVURLAsset* source = [AVURLAsset
        URLAssetWithURL:[NSURL fileURLWithPath:sourceString]
                options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVAssetTrack* track =
        [source tracksWithMediaType:AVMediaTypeVideo].firstObject;
    NSArray* descriptions = track.formatDescriptions;
#pragma clang diagnostic pop
    if (track == nil || descriptions.count != 1) {
      *error = "fixture has no single video format description";
      return std::nullopt;
    }
    CMVideoFormatDescriptionRef format =
        (__bridge CMVideoFormatDescriptionRef)descriptions.firstObject;
    *codec = CMFormatDescriptionGetMediaSubType(format);
    CFDictionaryRef extensions = CMFormatDescriptionGetExtensions(format);
    auto atoms = extensions == nullptr
                     ? nullptr
                     : static_cast<CFDictionaryRef>(CFDictionaryGetValue(
                           extensions,
                           kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms));
    CFStringRef atomName = *codec == kCMVideoCodecType_H264   ? CFSTR("avcC")
                           : *codec == kCMVideoCodecType_HEVC ? CFSTR("hvcC")
                                                              : nullptr;
    auto atom = atoms == nullptr || atomName == nullptr
                    ? nullptr
                    : static_cast<CFDataRef>(
                          CFDictionaryGetValue(atoms, atomName));
    if (atom == nullptr || CFGetTypeID(atom) != CFDataGetTypeID()) {
      *error = "fixture has no avcC/hvcC atom";
      return std::nullopt;
    }
    const CFIndex length = CFDataGetLength(atom);
    if (length <= 0) {
      *error = "fixture codec atom is empty";
      return std::nullopt;
    }
    std::vector<std::byte> result(static_cast<std::size_t>(length));
    std::memcpy(result.data(), CFDataGetBytePtr(atom), result.size());
    return result;
  }
}

void checkFixtureSampleFormatAdmission(
    const std::filesystem::path& path,
    std::optional<wam::macos::NativeVideoSampleFormatAdmission>
        expected = std::nullopt) {
  CMVideoCodecType codec = 0;
  std::string error;
  const auto configuration = fixtureCodecConfiguration(path, &codec, &error);
  WAM_CHECK_DETAIL(configuration.has_value(), error);
  WAM_CHECK(wam::macos::native_video_limits::
                acceptsVideoCodecConfigurationSize(configuration->size()));
  const auto admission = wam::macos::nativeVideoSampleFormatAdmission(
      codec, std::span<const std::byte>(*configuration));
  WAM_CHECK(admission !=
            wam::macos::NativeVideoSampleFormatAdmission::Unsupported);
  if (expected) {
    WAM_CHECK(admission == *expected);
  }

  std::vector<std::byte> malformed = *configuration;
  if (codec == kCMVideoCodecType_H264) {
    WAM_CHECK(malformed.size() >= 10);
    malformed[9] = std::byte{144};
  } else {
    WAM_CHECK(codec == kCMVideoCodecType_HEVC);
    WAM_CHECK(malformed.size() >= 23);
    // hvcC's summary may not contradict any embedded SPS.
    malformed[17] =
        (malformed[17] & std::byte{0xf8}) | std::byte{0x04};
  }
  WAM_CHECK(wam::macos::nativeVideoSampleFormatAdmission(
                codec, std::span<const std::byte>(malformed)) ==
            wam::macos::NativeVideoSampleFormatAdmission::Unsupported);

  WAM_CHECK(wam::macos::nativeVideoSampleFormatAdmission(codec, {}) ==
            wam::macos::NativeVideoSampleFormatAdmission::Unsupported);
  for (std::size_t length = 1;
       length < std::min<std::size_t>(configuration->size(), 8); ++length) {
    WAM_CHECK(wam::macos::nativeVideoSampleFormatAdmission(
                  codec,
                  std::span<const std::byte>(configuration->data(), length)) ==
              wam::macos::NativeVideoSampleFormatAdmission::Unsupported);
  }
  std::vector<std::byte> lengthOverflow = *configuration;
  if (codec == kCMVideoCodecType_H264) {
    WAM_CHECK(lengthOverflow.size() >= 8);
    lengthOverflow[6] = std::byte{0xff};
    lengthOverflow[7] = std::byte{0xff};
  } else {
    WAM_CHECK(lengthOverflow.size() >= 28);
    lengthOverflow[26] = std::byte{0xff};
    lengthOverflow[27] = std::byte{0xff};
  }
  WAM_CHECK(wam::macos::nativeVideoSampleFormatAdmission(
                codec, std::span<const std::byte>(lengthOverflow)) ==
            wam::macos::NativeVideoSampleFormatAdmission::Unsupported);
}

std::uint64_t residentBytes() {
  mach_task_basic_info_data_t information{};
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                reinterpret_cast<task_info_t>(&information),
                &count) != KERN_SUCCESS) {
    return 0;
  }
  return information.resident_size;
}

double processCpuSeconds() {
  rusage usage{};
  if (getrusage(RUSAGE_SELF, &usage) != 0) {
    return 0.0;
  }
  const auto seconds = [](const timeval& value) {
    return static_cast<double>(value.tv_sec) +
           static_cast<double>(value.tv_usec) / 1'000'000.0;
  };
  return seconds(usage.ru_utime) + seconds(usage.ru_stime);
}

template <typename Predicate>
bool waitUntil(Predicate predicate,
               std::chrono::milliseconds timeout =
                   std::chrono::milliseconds(5000)) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (std::chrono::steady_clock::now() < deadline) {
    if (predicate()) {
      return true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  return predicate();
}

std::optional<wam::macos::NativeVideoPrepareOutcome> waitForPrepareResult(
    wam::macos::NativeVideoPipeline& pipeline,
    std::chrono::milliseconds timeout = std::chrono::milliseconds(5000)) {
  std::optional<wam::macos::NativeVideoPrepareOutcome> outcome;
  const bool completed = waitUntil(
      [&] {
        outcome = pipeline.takePrepareResult();
        return outcome.has_value();
      },
      timeout);
  return completed ? std::move(outcome) : std::nullopt;
}

std::optional<wam::macos::NativeVideoPrepareOutcome> startAndWait(
    wam::macos::NativeVideoPipeline& pipeline,
    const std::filesystem::path& path, double position,
    std::string* startError,
    std::chrono::milliseconds timeout = std::chrono::milliseconds(5000)) {
  if (!pipeline.prepareLocalFileAsync(path, position, startError)) {
    return std::nullopt;
  }
  return waitForPrepareResult(pipeline, timeout);
}

struct TemporaryFile {
  std::filesystem::path path;

  ~TemporaryFile() {
    if (!path.empty()) {
      std::error_code error;
      std::filesystem::remove(path, error);
    }
  }
};

std::filesystem::path makeRenamedCopy(const std::filesystem::path& source,
                                      std::string_view suffix,
                                      std::string* error) {
  std::filesystem::path destination =
      std::filesystem::temp_directory_path() /
      ("wam-native-renamed-" +
       std::to_string(std::chrono::steady_clock::now()
                          .time_since_epoch()
                          .count()) +
       std::string(suffix));
  std::error_code copyError;
  if (!std::filesystem::copy_file(
          source, destination, std::filesystem::copy_options::none,
          copyError)) {
    *error = "could not make renamed container fixture: " +
             copyError.message();
    return {};
  }
  return destination;
}

std::filesystem::path makeVideoOnlyFixture(
    const std::filesystem::path& sourcePath, std::string* error) {
  @autoreleasepool {
    NSString* sourceString = [NSString stringWithUTF8String:sourcePath.c_str()];
    AVURLAsset* source = [AVURLAsset
        URLAssetWithURL:[NSURL fileURLWithPath:sourceString]
                options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVAssetTrack* sourceVideo =
        [source tracksWithMediaType:AVMediaTypeVideo].firstObject;
#pragma clang diagnostic pop
    if (sourceVideo == nil) {
      *error = "source fixture has no video track";
      return {};
    }

    AVMutableComposition* composition = [AVMutableComposition composition];
    AVMutableCompositionTrack* video = [composition
        addMutableTrackWithMediaType:AVMediaTypeVideo
                    preferredTrackID:kCMPersistentTrackID_Invalid];
    NSError* insertionError = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    const bool inserted = [video insertTimeRange:sourceVideo.timeRange
                                         ofTrack:sourceVideo
                                          atTime:kCMTimeZero
                                           error:&insertionError];
#pragma clang diagnostic pop
    if (!inserted) {
      *error = insertionError == nil
                   ? "could not create the video-only fixture"
                   : std::string(
                         insertionError.localizedDescription.UTF8String);
      return {};
    }

    NSString* name = [NSString
        stringWithFormat:@"wam-native-video-only-%@.mov", [NSUUID UUID].UUIDString];
    NSString* outputString = [NSTemporaryDirectory()
        stringByAppendingPathComponent:name];
    NSURL* outputURL = [NSURL fileURLWithPath:outputString];
    AVAssetExportSession* exporter = [[AVAssetExportSession alloc]
        initWithAsset:composition
           presetName:AVAssetExportPresetPassthrough];
    if (exporter == nil) {
      *error = "AVFoundation could not create a passthrough exporter";
      return {};
    }
    exporter.outputURL = outputURL;
    exporter.outputFileType = AVFileTypeQuickTimeMovie;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    [exporter exportAsynchronouslyWithCompletionHandler:^{
      dispatch_semaphore_signal(finished);
    }];
    if (dispatch_semaphore_wait(
            finished,
            dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) != 0) {
      [exporter cancelExport];
      *error = "video-only fixture export timed out";
      return {};
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    const AVAssetExportSessionStatus status = exporter.status;
    NSError* exportError = exporter.error;
#pragma clang diagnostic pop
    if (status != AVAssetExportSessionStatusCompleted) {
      *error = exportError == nil
                   ? "video-only fixture export failed"
                   : std::string(exportError.localizedDescription.UTF8String);
      return {};
    }
    return std::filesystem::path(outputString.fileSystemRepresentation);
  }
}

std::optional<CMVideoCodecType> fixtureVideoCodec(
    const std::filesystem::path& sourcePath, std::string* error) {
  @autoreleasepool {
    NSString* sourceString = [NSString stringWithUTF8String:sourcePath.c_str()];
    AVURLAsset* source = [AVURLAsset
        URLAssetWithURL:[NSURL fileURLWithPath:sourceString]
                options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVAssetTrack* videoTrack =
        [source tracksWithMediaType:AVMediaTypeVideo].firstObject;
#pragma clang diagnostic pop
    if (videoTrack == nil) {
      *error = "source fixture has no video track";
      return std::nullopt;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray* descriptions = videoTrack.formatDescriptions;
#pragma clang diagnostic pop
    if (descriptions.count == 0) {
      *error = "source fixture video track has no format description";
      return std::nullopt;
    }
    CMFormatDescriptionRef description =
        (__bridge CMFormatDescriptionRef)descriptions.firstObject;
    return CMFormatDescriptionGetMediaSubType(description);
  }
}

const char* codecName(CMVideoCodecType codec) {
  if (codec == kCMVideoCodecType_H264) {
    return "H.264 (avc1)";
  }
  if (codec == kCMVideoCodecType_HEVC) {
    return "HEVC (hvc1)";
  }
  return "unsupported codec";
}

}  // namespace

int main(int argc, char** argv) {
  checkNativeVideoLimitContract();
  checkAdmissionModel();
  if (argc == 2 && std::string_view(argv[1]) == "--admission-only") {
    std::cout << "native video admission model tests passed\n";
    return EXIT_SUCCESS;
  }
  if (argc != 2) {
    std::cerr << "usage: native_video_pipeline_test "
                 "<h264-or-hevc-file>|--admission-only\n";
    return EXIT_FAILURE;
  }

  checkFixtureSampleFormatAdmission(argv[1]);
  if (const char* tenBitFixture = std::getenv(
          "WAM_NATIVE_VIDEO_10BIT_TEST_FIXTURE");
      tenBitFixture != nullptr && tenBitFixture[0] != '\0') {
    checkFixtureSampleFormatAdmission(
        tenBitFixture,
        wam::macos::NativeVideoSampleFormatAdmission::Yuv420TenBit);
  }

  std::string fixtureError;
  TemporaryFile videoOnlyFixture{
      makeVideoOnlyFixture(argv[1], &fixtureError)};
  WAM_CHECK_DETAIL(!videoOnlyFixture.path.empty(), fixtureError);

  std::string error;
  auto pipeline = wam::macos::NativeVideoPipeline::create(&error);
  if (!pipeline) {
    std::cerr << "SKIP: native Metal/display-link path unavailable: " << error
              << '\n';
    return 77;
  }

  // A presenter/output exception must be contained inside the noexcept GCD
  // event-handler boundary. Its failure record is a static diagnostic, so the
  // bad_alloc handler itself performs no second allocation.
  WAM_CHECK(wam::macos::NativeVideoPipelineTestAccess::
                exercisePresentationExceptionBoundary(*pipeline));
  const auto presentationException = pipeline->takeLastError();
  WAM_CHECK(presentationException.has_value());
  WAM_CHECK_DETAIL(
      *presentationException ==
          "native video presentation exhausted its bounded memory",
      *presentationException);

  // If allocating the public wrapper fails after the source/display-link have
  // been installed, construction cleanup must synchronously revoke them. A
  // fresh factory call then proves that no partial callback infrastructure was
  // stranded.
  wam::macos::NativeVideoPipelineTestAccess::
      failNextFactoryWrapperAllocation();
  auto failedFactory = wam::macos::NativeVideoPipeline::create(&error);
  WAM_CHECK(failedFactory == nullptr);
  WAM_CHECK_DETAIL(error == "native video pipeline could not be created",
                   error);
  auto recoveredFactory = wam::macos::NativeVideoPipeline::create(&error);
  WAM_CHECK_DETAIL(recoveredFactory != nullptr, error);
  recoveredFactory.reset();

  // CoreVideo transition failures are observed and permanently poison the
  // affected display link. The handler owns only a weak Impl and a stable GCD
  // source, so final release remains safe even when Stop itself reports an
  // error.
  auto startFailureProbe = wam::macos::NativeVideoPipeline::create(&error);
  WAM_CHECK_DETAIL(startFailureProbe != nullptr, error);
  wam::macos::NativeVideoPipelineTestAccess::failNextDisplayLinkStart(
      *startFailureProbe);
  WAM_CHECK(!wam::macos::NativeVideoPipelineTestAccess::setDisplayLinkRunning(
      *startFailureProbe, true));
  WAM_CHECK(!wam::macos::NativeVideoPipelineTestAccess::displayLinkHealthy(
      *startFailureProbe));
  startFailureProbe.reset();

  auto stopFailureProbe = wam::macos::NativeVideoPipeline::create(&error);
  WAM_CHECK_DETAIL(stopFailureProbe != nullptr, error);
  WAM_CHECK(wam::macos::NativeVideoPipelineTestAccess::setDisplayLinkRunning(
      *stopFailureProbe, true));
  wam::macos::NativeVideoPipelineTestAccess::failNextDisplayLinkStop(
      *stopFailureProbe);
  WAM_CHECK(!wam::macos::NativeVideoPipelineTestAccess::setDisplayLinkRunning(
      *stopFailureProbe, false));
  WAM_CHECK(!wam::macos::NativeVideoPipelineTestAccess::displayLinkHealthy(
      *stopFailureProbe));
  stopFailureProbe.reset();

  // A misleading extension in a family that needs the unimplemented demux
  // bridge fails closed even when the bytes are an otherwise valid MP4.
  TemporaryFile renamedMkv{
      makeRenamedCopy(argv[1], ".mkv", &fixtureError)};
  WAM_CHECK_DETAIL(!renamedMkv.path.empty(), fixtureError);
  auto renamedOutcome =
      startAndWait(*pipeline, renamedMkv.path, 0.0, &error);
  WAM_CHECK_DETAIL(renamedOutcome.has_value(), error);
  WAM_CHECK(renamedOutcome->result ==
            wam::macos::NativeVideoPrepareResult::Unsupported);
  WAM_CHECK(renamedOutcome->generation == 0);
  WAM_CHECK_DETAIL(renamedOutcome->error.find("external") !=
                       std::string::npos,
                   renamedOutcome->error);
  WAM_CHECK(!pipeline->active());
  WAM_CHECK(!pipeline->stats().decoder.configured);

  // Unsupported media is also reported asynchronously. Starting the request
  // never reads AVAsset state on this caller.
  WAM_CHECK_DETAIL(pipeline->prepareLocalFileAsync(
                       videoOnlyFixture.path, 0.0, &error),
                   error);
  bool unexpectedAdmission = false;
  const bool videoOnlyResultPending = waitUntil([&] {
    std::string retryError;
    if (pipeline->prepareLocalFileAsync(argv[1], 0.0, &retryError)) {
      unexpectedAdmission = true;
      return true;
    }
    return retryError.find("consume the previous") != std::string::npos;
  });
  WAM_CHECK(videoOnlyResultPending);
  WAM_CHECK(!unexpectedAdmission);
  auto videoOnlyOutcome = pipeline->takePrepareResult();
  WAM_CHECK_DETAIL(videoOnlyOutcome.has_value(), error);
  WAM_CHECK(videoOnlyOutcome->result ==
            wam::macos::NativeVideoPrepareResult::Unsupported);
  WAM_CHECK_DETAIL(videoOnlyOutcome->error.find("audio track") !=
                       std::string::npos,
                   videoOnlyOutcome->error);
  WAM_CHECK(videoOnlyOutcome->generation == 0);
  WAM_CHECK(!pipeline->takePrepareResult().has_value());
  WAM_CHECK(!pipeline->active());

  std::string codecError;
  const auto codec = fixtureVideoCodec(argv[1], &codecError);
  WAM_CHECK_DETAIL(codec.has_value(), codecError);
  WAM_CHECK(*codec == kCMVideoCodecType_H264 ||
            *codec == kCMVideoCodecType_HEVC);
  if (!VTIsHardwareDecodeSupported(*codec)) {
    std::cout << "SKIP: this runner has no hardware VideoToolbox decoder for "
              << codecName(*codec)
              << "; asynchronous unsupported-media probing passed before the "
                 "capability check\n";
    return 77;
  }

  // A throw after AVAssetReader returns a retained CMSampleBuffer must unwind
  // both the CF lease and the active-reader registration before the worker's
  // fixed, allocation-free failure latch becomes observable.
  wam::macos::NativeVideoPipelineTestAccess::failNextWorkerSampleSubmission(
      *pipeline);
  auto workerFaultReady = startAndWait(*pipeline, argv[1], 0.0, &error);
  WAM_CHECK(workerFaultReady.has_value());
  WAM_CHECK_DETAIL(workerFaultReady->result ==
                       wam::macos::NativeVideoPrepareResult::Ready,
                   workerFaultReady->error);
  std::optional<std::string> workerFailure;
  WAM_CHECK(waitUntil([&] {
    workerFailure = pipeline->takeLastError();
    return workerFailure.has_value();
  }));
  WAM_CHECK_DETAIL(
      *workerFailure == "native video worker exhausted its bounded memory",
      *workerFailure);
  WAM_CHECK(!pipeline->active());
  WAM_CHECK(!wam::macos::NativeVideoPipelineTestAccess::hasActiveReader(
      *pipeline));
  (void)pipeline->stop();
  WAM_CHECK(waitUntil([&] { return !pipeline->stats().stopping; }));

  // Hold AVFoundation's real asset-load completion before its continuation is
  // delivered. The public call must return promptly, stop() must issue
  // cancelLoading from the private queue, and process admission must remain
  // closed until the in-flight callback is released and acknowledges cancel.
  std::promise<void> slowCancellationRelease;
  auto slowCancellationEntered =
      std::make_shared<std::atomic<bool>>(false);
  auto slowCancellationIssued =
      std::make_shared<std::atomic<bool>>(false);
  wam::macos::NativeVideoPipelineTestAccess::setAssetLoadCallbackBarrier(
      *pipeline, slowCancellationRelease.get_future().share(),
      slowCancellationEntered);
  wam::macos::NativeVideoPipelineTestAccess::setPreparationCancellationMarker(
      *pipeline, slowCancellationIssued);
  const auto slowStart = std::chrono::steady_clock::now();
  WAM_CHECK_DETAIL(
      pipeline->prepareLocalFileAsync(argv[1], 0.0, &error), error);
  const auto slowStartElapsed = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - slowStart);
  WAM_CHECK(slowStartElapsed < std::chrono::milliseconds(250));
  WAM_CHECK(waitUntil([&] {
    return slowCancellationEntered->load(std::memory_order_acquire);
  }));
  WAM_CHECK(!pipeline->takePrepareResult().has_value());
  const auto loadingStopStart = std::chrono::steady_clock::now();
  (void)pipeline->stop();
  const auto loadingStopElapsed = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - loadingStopStart);
  WAM_CHECK(loadingStopElapsed < std::chrono::milliseconds(250));
  WAM_CHECK(waitUntil([&] {
    return slowCancellationIssued->load(std::memory_order_acquire);
  }));
  auto loadingContender =
      wam::macos::NativeVideoPipeline::create(&error);
  WAM_CHECK_DETAIL(loadingContender != nullptr, error);
  WAM_CHECK(!loadingContender->prepareLocalFileAsync(
      argv[1], 0.0, &error));
  WAM_CHECK_DETAIL(error.find("another native video attempt") !=
                       std::string::npos,
                   error);
  WAM_CHECK(!pipeline->takePrepareResult().has_value());
  slowCancellationRelease.set_value();
  auto loadingCancelled = waitForPrepareResult(*pipeline);
  WAM_CHECK(loadingCancelled.has_value());
  WAM_CHECK(loadingCancelled->result ==
            wam::macos::NativeVideoPrepareResult::Failed);
  WAM_CHECK_DETAIL(loadingCancelled->error ==
                       "native video preparation was cancelled",
                   loadingCancelled->error);
  WAM_CHECK(loadingCancelled->generation == 0);
  WAM_CHECK(waitUntil([&] { return !pipeline->stats().stopping; }));
  WAM_CHECK(!pipeline->active());
  loadingContender.reset();

  // A slow-but-successful load follows the same prompt caller contract.
  std::promise<void> slowSuccessRelease;
  auto slowSuccessEntered = std::make_shared<std::atomic<bool>>(false);
  wam::macos::NativeVideoPipelineTestAccess::setPreparationLoadBarrier(
      *pipeline, slowSuccessRelease.get_future().share(), slowSuccessEntered);
  const auto slowSuccessStart = std::chrono::steady_clock::now();
  WAM_CHECK_DETAIL(
      pipeline->prepareLocalFileAsync(argv[1], 0.0, &error), error);
  const auto slowSuccessStartElapsed =
      std::chrono::duration<double, std::milli>(
          std::chrono::steady_clock::now() - slowSuccessStart);
  WAM_CHECK(slowSuccessStartElapsed < std::chrono::milliseconds(250));
  WAM_CHECK(waitUntil([&] {
    return slowSuccessEntered->load(std::memory_order_acquire);
  }));
  WAM_CHECK(!pipeline->takePrepareResult().has_value());
  slowSuccessRelease.set_value();
  auto slowSuccessOutcome = waitForPrepareResult(*pipeline);
  WAM_CHECK(slowSuccessOutcome.has_value());
  WAM_CHECK_DETAIL(slowSuccessOutcome->result ==
                       wam::macos::NativeVideoPrepareResult::Ready,
                   slowSuccessOutcome->error);
  WAM_CHECK(slowSuccessOutcome->generation != 0);
  WAM_CHECK(slowSuccessOutcome->generation == pipeline->stats().generation);
  WAM_CHECK(waitUntil([&] {
    return pipeline->stats().compressedSamplesSubmitted >= 1;
  }));
  (void)pipeline->stop();
  WAM_CHECK(waitUntil([&] { return !pipeline->stats().stopping; }));

  // An allocation/thread-construction exception must never cross a GCD block.
  // Inject one after AVFoundation ownership has moved into Impl so the test
  // also proves partial resources retire before process admission reopens.
  wam::macos::NativeVideoPipelineTestAccess::
      failNextPreparationAfterResourceTransfer(*pipeline);
  WAM_CHECK_DETAIL(
      pipeline->prepareLocalFileAsync(argv[1], 0.0, &error), error);
  auto exceptionOutcome = waitForPrepareResult(*pipeline);
  WAM_CHECK(exceptionOutcome.has_value());
  WAM_CHECK(exceptionOutcome->result ==
            wam::macos::NativeVideoPrepareResult::Failed);
  WAM_CHECK_DETAIL(exceptionOutcome->error == "native prep failed",
                   exceptionOutcome->error);
  WAM_CHECK(exceptionOutcome->generation == 0);
  WAM_CHECK(waitUntil([&] { return !pipeline->stats().stopping; }));
  WAM_CHECK(!pipeline->stats().decoder.configured);

  // Pause after a decoder is configured but before preparation can commit.
  // stop() must revoke that Preparing attempt without waiting, and the worker
  // must never start after the barrier is released.
  std::promise<void> preparationRelease;
  auto preparationEntered = std::make_shared<std::atomic<bool>>(false);
  wam::macos::NativeVideoPipelineTestAccess::setPreparationCommitBarrier(
      *pipeline, preparationRelease.get_future().share(), preparationEntered);
  WAM_CHECK_DETAIL(
      pipeline->prepareLocalFileAsync(argv[1], 0.0, &error), error);
  WAM_CHECK(waitUntil([&] {
    return preparationEntered->load(std::memory_order_acquire);
  }));
  const auto preparingStopStart = std::chrono::steady_clock::now();
  (void)pipeline->stop();
  const auto preparingStopElapsed = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - preparingStopStart);
  WAM_CHECK(preparingStopElapsed < std::chrono::milliseconds(250));
  preparationRelease.set_value();
  auto cancelledPrepare = waitForPrepareResult(*pipeline);
  WAM_CHECK(cancelledPrepare.has_value());
  WAM_CHECK(cancelledPrepare->result ==
            wam::macos::NativeVideoPrepareResult::Failed);
  WAM_CHECK_DETAIL(cancelledPrepare->error ==
                       "native video preparation was cancelled",
                   cancelledPrepare->error);
  WAM_CHECK(cancelledPrepare->generation == 0);
  WAM_CHECK(waitUntil([&] { return !pipeline->stats().stopping; }));
  WAM_CHECK(!pipeline->active());

  // Destruction while the selected track's property load callback is held is
  // also non-blocking. No client callback exists; the self-owned request
  // publishes cancellation internally, retires, and only then releases
  // process-wide admission.
  auto loadingDestructionPipeline =
      wam::macos::NativeVideoPipeline::create(&error);
  WAM_CHECK_DETAIL(loadingDestructionPipeline != nullptr, error);
  std::promise<void> destructionLoadRelease;
  auto destructionLoadEntered = std::make_shared<std::atomic<bool>>(false);
  auto destructionCancellationIssued =
      std::make_shared<std::atomic<bool>>(false);
  wam::macos::NativeVideoPipelineTestAccess::setTrackLoadCallbackBarrier(
      *loadingDestructionPipeline,
      destructionLoadRelease.get_future().share(), destructionLoadEntered);
  wam::macos::NativeVideoPipelineTestAccess::setPreparationCancellationMarker(
      *loadingDestructionPipeline, destructionCancellationIssued);
  WAM_CHECK_DETAIL(loadingDestructionPipeline->prepareLocalFileAsync(
                       argv[1], 0.0, &error),
                   error);
  WAM_CHECK(waitUntil([&] {
    return destructionLoadEntered->load(std::memory_order_acquire);
  }));
  const auto loadingDestructionStart = std::chrono::steady_clock::now();
  loadingDestructionPipeline.reset();
  const auto loadingDestructionElapsed =
      std::chrono::duration<double, std::milli>(
          std::chrono::steady_clock::now() - loadingDestructionStart);
  WAM_CHECK(loadingDestructionElapsed < std::chrono::milliseconds(250));
  WAM_CHECK(waitUntil([&] {
    return destructionCancellationIssued->load(std::memory_order_acquire);
  }));
  WAM_CHECK(!pipeline->prepareLocalFileAsync(argv[1], 0.0, &error));
  WAM_CHECK_DETAIL(error.find("another native video attempt") !=
                       std::string::npos,
                   error);
  destructionLoadRelease.set_value();

  const std::uint64_t residentBefore = residentBytes();
  const double cpuBefore = processCpuSeconds();
  const auto wallStart = std::chrono::steady_clock::now();

  // Admission of this request is the deterministic completion signal for the
  // destroyed loading request; rejected retries do not enqueue notifications.
  bool prepareAccepted = waitUntil([&] {
    return pipeline->prepareLocalFileAsync(argv[1], 0.0, &error);
  });
  WAM_CHECK_DETAIL(prepareAccepted, error);
  auto prepare = waitForPrepareResult(*pipeline);
  WAM_CHECK(prepare.has_value());
  WAM_CHECK_DETAIL(
      prepare->result == wam::macos::NativeVideoPrepareResult::Ready,
      prepare->error);
  WAM_CHECK(prepare->generation != 0);
  WAM_CHECK(prepare->generation == pipeline->stats().generation);
  WAM_CHECK(waitUntil([&] {
    const auto stats = pipeline->stats();
    return stats.hardwareDecode && stats.compressedSamplesSubmitted >= 3 &&
           stats.decoder.deliveredFrames >= 1;
  }));

  const auto initial = pipeline->stats();
  WAM_CHECK(initial.active);
  WAM_CHECK(initial.hardwareDecode);
  WAM_CHECK(initial.queueCapacity == 3);
  WAM_CHECK(initial.queueDepth <= initial.queueCapacity);
  WAM_CHECK(initial.decoder.inFlightFrames <=
            initial.decoder.maxInFlightFrames);
  WAM_CHECK(initial.decoder.pendingPresentationFrames <= 3);
  WAM_CHECK(initial.decoder.directSampleBufferSubmissions ==
            initial.decoder.submittedFrames);
  WAM_CHECK(initial.decoder.directSampleBufferBytes > 0);
  WAM_CHECK(initial.decoder.copiedSpanSubmissions == 0);
  WAM_CHECK(initial.decoder.copiedSpanBytes == 0);

  // The bound is process-wide, not merely per frontend: a caller cannot evade
  // an active/retiring session's admission lease by constructing another
  // NativeVideoPipeline and piling up VideoToolbox resources.
  auto contender = wam::macos::NativeVideoPipeline::create(&error);
  WAM_CHECK_DETAIL(contender != nullptr, error);
  WAM_CHECK(!contender->prepareLocalFileAsync(argv[1], 0.0, &error));
  WAM_CHECK_DETAIL(error.find("another native video attempt") !=
                       std::string::npos,
                   error);
  WAM_CHECK(!contender->takePrepareResult().has_value());

  const std::uint64_t firstGeneration = initial.generation;
  const std::uint64_t submissionsBeforeSeek =
      initial.compressedSamplesSubmitted;
  const std::uint64_t drawableAttemptsBeforeSeek =
      initial.drawableUnavailableEvents;
  (void)pipeline->seek(2.017);
  WAM_CHECK(waitUntil([&] {
    const auto stats = pipeline->stats();
    return stats.generation == firstGeneration + 1 &&
           stats.decoder.generation == stats.generation &&
           stats.compressedSamplesSubmitted > submissionsBeforeSeek &&
           stats.drawableUnavailableEvents > drawableAttemptsBeforeSeek;
  }));

  const auto afterSeek = pipeline->stats();
  WAM_CHECK(afterSeek.active);
  WAM_CHECK(afterSeek.queueDepth <= afterSeek.queueCapacity);
  WAM_CHECK(afterSeek.decoder.inFlightFrames <=
            afterSeek.decoder.maxInFlightFrames);
  WAM_CHECK(afterSeek.decoder.pendingPresentationFrames <= 3);
  WAM_CHECK(afterSeek.decoder.directSampleBufferSubmissions ==
            afterSeek.decoder.submittedFrames);
  WAM_CHECK(afterSeek.decoder.directSampleBufferBytes >=
            initial.decoder.directSampleBufferBytes);
  WAM_CHECK(afterSeek.decoder.copiedSpanSubmissions == 0);
  WAM_CHECK(afterSeek.decoder.copiedSpanBytes == 0);
  const auto asyncFailure = pipeline->takeLastError();
  WAM_CHECK_DETAIL(!asyncFailure.has_value(),
                   asyncFailure.value_or(std::string{}));

  // Detach owns only the immediate AppKit layer mutation. AVAssetReader worker
  // join and VideoToolbox callback drain must be transferred to the private
  // retirement owner rather than stalling this main thread.
  NSView* hostView = [[NSView alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 640.0, 360.0)];
  WAM_CHECK_DETAIL(pipeline->attachToView((__bridge void*)hostView, &error),
                   error);
  WAM_CHECK(pipeline->attached());
  const auto detachStart = std::chrono::steady_clock::now();
  pipeline->detach();
  const auto detachElapsed = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - detachStart);
  WAM_CHECK(detachElapsed < std::chrono::milliseconds(250));
  WAM_CHECK(!pipeline->active());
  WAM_CHECK(!pipeline->attached());
  WAM_CHECK(waitUntil([&] { return !pipeline->stats().stopping; }));
  const auto stopped = pipeline->stats();
  WAM_CHECK(!stopped.prepared);
  WAM_CHECK(!stopped.decoder.configured);
  WAM_CHECK(stopped.queueDepth == 0);

  // Once the single retirement slot is clear the same frontend can prepare a
  // fresh generation.
  auto restarted = startAndWait(*pipeline, argv[1], 0.0, &error);
  WAM_CHECK(restarted.has_value());
  WAM_CHECK_DETAIL(
      restarted->result == wam::macos::NativeVideoPrepareResult::Ready,
      restarted->error);
  WAM_CHECK(restarted->generation != 0);
  WAM_CHECK(restarted->generation == pipeline->stats().generation);
  WAM_CHECK(waitUntil([&] {
    const auto stats = pipeline->stats();
    return stats.active && stats.compressedSamplesSubmitted >= 1;
  }));
  const auto stopStart = std::chrono::steady_clock::now();
  (void)pipeline->stop();
  const auto stopElapsed = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - stopStart);
  WAM_CHECK(stopElapsed < std::chrono::milliseconds(250));
  WAM_CHECK(!pipeline->active());
  WAM_CHECK(waitUntil([&] { return !pipeline->stats().stopping; }));

  // Explicitly exercise the Retiring -> Finalizing upgrade.
  auto contenderReady = startAndWait(*contender, argv[1], 0.0, &error);
  WAM_CHECK(contenderReady.has_value());
  WAM_CHECK_DETAIL(
      contenderReady->result == wam::macos::NativeVideoPrepareResult::Ready,
      contenderReady->error);
  WAM_CHECK(contenderReady->generation != 0);
  WAM_CHECK(contenderReady->generation == contender->stats().generation);
  WAM_CHECK(waitUntil([&] {
    return contender->stats().compressedSamplesSubmitted >= 1;
  }));
  std::promise<void> upgradeRetirementRelease;
  auto upgradeRetirementEntered =
      std::make_shared<std::atomic<bool>>(false);
  wam::macos::NativeVideoPipelineTestAccess::setRetirementBarrier(
      *contender, upgradeRetirementRelease.get_future().share(),
      upgradeRetirementEntered);
  (void)contender->stop();
  WAM_CHECK(waitUntil([&] {
    return upgradeRetirementEntered->load(std::memory_order_acquire);
  }));
  const auto upgradeDestructionStart = std::chrono::steady_clock::now();
  contender.reset();
  const auto upgradeDestructionElapsed =
      std::chrono::duration<double, std::milli>(
          std::chrono::steady_clock::now() - upgradeDestructionStart);
  WAM_CHECK(upgradeDestructionElapsed < std::chrono::milliseconds(250));
  upgradeRetirementRelease.set_value();

  // Active destruction follows the same transfer contract.
  auto destructionPipeline = wam::macos::NativeVideoPipeline::create(&error);
  WAM_CHECK_DETAIL(destructionPipeline != nullptr, error);
  bool destructionAccepted = waitUntil([&] {
    return destructionPipeline->prepareLocalFileAsync(
        argv[1], 0.0, &error);
  });
  WAM_CHECK_DETAIL(destructionAccepted, error);
  auto destructionReady = waitForPrepareResult(*destructionPipeline);
  WAM_CHECK(destructionReady.has_value());
  WAM_CHECK_DETAIL(
      destructionReady->result == wam::macos::NativeVideoPrepareResult::Ready,
      destructionReady->error);
  WAM_CHECK(destructionReady->generation != 0);
  WAM_CHECK(destructionReady->generation ==
            destructionPipeline->stats().generation);
  WAM_CHECK(waitUntil([&] {
    return destructionPipeline->stats().compressedSamplesSubmitted >= 1;
  }));
  std::promise<void> activeRetirementRelease;
  auto activeRetirementEntered =
      std::make_shared<std::atomic<bool>>(false);
  wam::macos::NativeVideoPipelineTestAccess::setRetirementBarrier(
      *destructionPipeline, activeRetirementRelease.get_future().share(),
      activeRetirementEntered);
  const auto destructionStart = std::chrono::steady_clock::now();
  destructionPipeline.reset();
  const auto destructionElapsed = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - destructionStart);
  WAM_CHECK(destructionElapsed < std::chrono::milliseconds(250));
  WAM_CHECK(waitUntil([&] {
    return activeRetirementEntered->load(std::memory_order_acquire);
  }));
  activeRetirementRelease.set_value();

  // Admission does not reopen until the destroyed frontend's decoder and sink
  // have completed their self-owned close.
  auto completionProbe = wam::macos::NativeVideoPipeline::create(&error);
  WAM_CHECK_DETAIL(completionProbe != nullptr, error);
  bool completionAccepted = waitUntil([&] {
    return completionProbe->prepareLocalFileAsync(argv[1], 0.0, &error);
  });
  WAM_CHECK_DETAIL(completionAccepted, error);
  auto completionReady = waitForPrepareResult(*completionProbe);
  WAM_CHECK(completionReady.has_value());
  WAM_CHECK_DETAIL(
      completionReady->result == wam::macos::NativeVideoPrepareResult::Ready,
      completionReady->error);
  WAM_CHECK(completionReady->generation != 0);
  WAM_CHECK(completionReady->generation ==
            completionProbe->stats().generation);
  (void)completionProbe->stop();
  WAM_CHECK(waitUntil([&] { return !completionProbe->stats().stopping; }));

  const auto wallEnd = std::chrono::steady_clock::now();
  const double cpuAfter = processCpuSeconds();
  const std::uint64_t residentAfter = residentBytes();
  const double wallSeconds =
      std::chrono::duration<double>(wallEnd - wallStart).count();
  const double residentDeltaMiB =
      residentAfter >= residentBefore
          ? static_cast<double>(residentAfter - residentBefore) /
                (1024.0 * 1024.0)
          : 0.0;

  std::cout
      << "Native asynchronous probe/decode/seek/shutdown passed; wall="
      << wallSeconds << "s cpu=" << (cpuAfter - cpuBefore)
      << "s resident_delta=" << residentDeltaMiB
      << "MiB slow_start_ms=" << slowStartElapsed.count()
      << " slow_success_start_ms=" << slowSuccessStartElapsed.count()
      << " loading_stop_ms=" << loadingStopElapsed.count()
      << " preparing_stop_ms=" << preparingStopElapsed.count()
      << " loading_destroy_ms=" << loadingDestructionElapsed.count()
      << " detach_ms=" << detachElapsed.count()
      << " stop_ms=" << stopElapsed.count()
      << " stop_destroy_ms=" << upgradeDestructionElapsed.count()
      << " destroy_ms=" << destructionElapsed.count()
      << " submitted=" << afterSeek.compressedSamplesSubmitted
      << " direct_compressed_bytes="
      << afterSeek.decoder.directSampleBufferBytes
      << " copied_compressed_bytes=" << afterSeek.decoder.copiedSpanBytes
      << " delivered=" << afterSeek.decoder.deliveredFrames << '\n';
  return EXIT_SUCCESS;
}
