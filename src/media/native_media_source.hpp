#pragma once

#include "media/media_refusal.hpp"
#include "media/media_time.hpp"

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <type_traits>
#include <variant>
#include <vector>

namespace wam::media {

using MediaGeneration = std::uint64_t;
using MediaTrackId = std::uint32_t;

[[nodiscard]] std::optional<MediaGeneration>
nextMediaGeneration(MediaGeneration current) noexcept;

enum class MediaTrackKind : std::uint8_t {
  Video,
  Audio,
  Subtitle,
  Text,
  ClosedCaption,
  Metadata,
};

enum class MediaCodec : std::uint8_t {
  Unknown,
  H264,
  Hevc,
  Av1,
  Vp9,
  Aac,
  Alac,
  Mp3,
  Opus,
  Vorbis,
  Pcm,
  // This enum is APPEND-ONLY: new values go at the end and every existing
  // value keeps its ordinal. VP8 has no hardware decoder
  // on any Apple platform and is decoded by the libvpx software stage, which is
  // why it is the only video codec here that is not a VideoToolbox codec.
  Vp8,
  // All three are decoded by AudioToolbox: Apple ships licensed AC-3 and
  // E-AC-3 decoders ('ac-3' / 'ec-3') and a FLAC decoder ('flac'), all three
  // reported by kAudioFormatProperty_DecodeFormatIDs on this platform.
  Ac3,
  Eac3,
  Flac,
  // MPEG-2 video, carried in Transport Stream. VideoToolbox decodes MPEG-2 on
  // Apple Silicon through a SOFTWARE decoder --
  // VTIsHardwareDecodeSupported(kCMVideoCodecType_MPEG2Video) is 0 and
  // UsingHardwareAcceleratedVideoDecoder is unavailable -- so it is not a
  // hardware VideoToolbox codec. It needs NO codec configuration record: the sequence
  // header is in-band and CMVideoFormatDescriptionCreate takes a null
  // extensions dictionary.
  Mpeg2Video,
  // MPEG-4 Part 2 video (ISO/IEC 14496-2, CoreMedia 'mp4v') in Matroska.
  // The name is the codec family's ISO name
  // deliberately: only SIMPLE PROFILE is admitted, because Apple's
  // VideoToolbox decoder refuses Advanced Simple Profile -- the Xvid/DivX
  // profile -- at VTDecompressionSessionCreate with codecBadDataErr (-8969),
  // with AVFoundation reproducing the identical failure
  // on a plain mp4v MP4. Naming this enumerator Mpeg4Asp would name the one
  // profile it cannot carry. Like Mpeg2Video and Vp8 it is not a hardware
  // codec (VTIsHardwareDecodeSupported is 0); unlike Mpeg2Video it DOES need
  // a configuration record, and the record is the esds the Matroska demuxer
  // synthesizes around the CodecPrivate headers.
  Mpeg4Visual,
  // Apple ProRes in QuickTime/MP4. Its VideoToolbox decoder is genuinely
  // HARDWARE on Apple Silicon: VTIsHardwareDecodeSupported is 1 and a created
  // session reports UsingHardwareAcceleratedVideoDecoder = TRUE for all six
  // FourCCs. Like Mpeg2Video it
  // carries NO codec configuration record -- a QuickTime ProRes sample
  // description has no parameter-set atom, and CMVideoFormatDescriptionCreate
  // takes a null extensions dictionary.
  //
  // This enumerator deliberately names only the ProRes 422 FAMILY -- 'apco'
  // (Proxy), 'apcs' (LT), 'apcn' (422) and 'apch' (HQ). That is exactly the
  // set VideoToolbox decodes interchangeably: a session created from ANY
  // 422-family format description decodes samples of ANY other 422-family
  // flavor, while a 422-family session fed 4444 samples fails with -12916 and
  // vice versa. The 4444 family ('ap4h', 'ap4x') is therefore a SECOND decode
  // family with its own enumerator, ProRes4444, rather than being
  // mis-dispatched through this one.
  ProRes,
  // Motion JPEG ('jpeg'). Decoded by VideoToolbox's SOFTWARE JPEG decoder --
  // VTIsHardwareDecodeSupported reports 1 but a created session reports no
  // UsingHardwareAcceleratedVideoDecoder property at all, the same signature
  // Mpeg2Video and Mpeg4Visual show. Carries no configuration record either.
  //
  // Admitted for 4:2:0 chroma ONLY. Apple's JPEG video
  // decoder fails 4:2:2, 4:4:4 and grayscale JPEG with kVTAllocationFailedErr
  // (-12904), and AVAssetImageGenerator reports "Cannot Decode" for the same
  // files, while ImageIO decodes the identical bytes -- so the limit is the
  // video decoder's, not the media's. The chroma gate lives upstream on the
  // JPEG frame header, exactly as inspectMpeg4VisualHeaders() gates profile.
  Mjpeg,
  // The two ADPCM families that real WAV files carry: IMA/DVI ADPCM
  // ('ms\0\x11', the format of game clips and old voice recorders) and
  // Microsoft ADPCM ('ms\0\x02').
  //
  // TWO enumerators rather than one, because they are two different decoders
  // with two different bitstreams; a single AdpcmWav enumerator would have to
  // be disambiguated by format tag at every site that dispatches on it, which
  // is precisely the mis-dispatch the ProRes 422/4444 note above refuses.
  //
  // Their AudioToolbox decode is BIT-EXACT against ffmpeg, not merely close:
  // on linear-CHIRP inputs at 44.1 kHz, mono and stereo, both families produce
  // exactly the container's declared frame count, the chirp cross-correlation
  // lag against ffmpeg's decode is 0 frames, and every decoded frame matches
  // ffmpeg's to the bit (max |diff| = 0). A chirp is load-bearing here and a
  // tone would not be: a steady tone correlates nearly as well at a whole-period
  // offset as at zero, so it can "prove" an alignment that is wrong by a period.
  //
  // Structurally they are CONSTANT-bit-rate inputs -- mBytesPerPacket 1024 with
  // mFramesPerPacket 1012-2041, and CoreMedia attaches no packet descriptions --
  // so they are carried by the CBR input-proc arm used for LPCM
  // and by the packet-table synthesis path beside it, with no new converter
  // machinery. Both state mBitsPerChannel = 0 and mBytesPerFrame = 0, which is
  // why they are NOT spelled as MediaCodec::Pcm: that enumerator means linear
  // PCM, whose sample depth those two fields carry.
  AdpcmIma,
  AdpcmMs,
  ProRes4444,
  Dts,
  TrueHd,
  Mlp,
};

enum class MediaCodecConfigurationKind : std::uint8_t {
  None,
  AvcC,
  HvcC,
  Av1C,
  VpcC,
  AudioMagicCookie,
  CodecPrivate,
};

enum class MediaColorPrimaries : std::uint8_t {
  Unknown,
  Bt601,
  Bt709,
  Bt2020,
  OtherExplicit,
};

enum class MediaTransferFunction : std::uint8_t {
  Unknown,
  Bt709,
  Srgb,
  Pq,
  Hlg,
  OtherExplicit,
};

[[nodiscard]] constexpr bool mediaTransferIsHighDynamicRange(
    MediaTransferFunction transfer) noexcept {
  return transfer == MediaTransferFunction::Pq ||
         transfer == MediaTransferFunction::Hlg;
}

enum class MediaMatrixCoefficients : std::uint8_t {
  Unknown,
  Bt601,
  Bt709,
  Bt2020Ncl,
  OtherExplicit,
};

enum class MediaChromaLocation : std::uint8_t {
  Unspecified,
  Left,
  Center,
  OtherExplicit,
};

enum class MediaVideoSampleFormat : std::uint8_t {
  Unknown,
  Yuv420EightBit,
  Yuv420TenBit,
  Unsupported,
  Yuv422EightBit,
  Yuv422TenBit,
  Yuv444EightBit,
};

// Exact bounded scalar used for container display geometry. Values are always
// canonicalized to a positive, nonzero denominator and lowest terms.
struct MediaRational {
  std::int64_t numerator{0};
  std::uint64_t denominator{1};

  friend constexpr bool operator==(const MediaRational&,
                                   const MediaRational&) = default;
};

// ISO/QuickTime clean-aperture offsets are measured from the coded-image
// center. AVFoundation emits exact rational arrays when a component is not an
// integer; the backend rejects an unrepresentable value instead of rounding.
struct MediaCleanAperture {
  MediaRational width{};
  MediaRational height{};
  MediaRational horizontalOffset{};
  MediaRational verticalOffset{};

  friend constexpr bool operator==(const MediaCleanAperture&,
                                   const MediaCleanAperture&) = default;
};

struct MediaVideoFormat {
  std::uint32_t codedWidth{0};
  std::uint32_t codedHeight{0};
  std::uint32_t displayWidth{0};
  std::uint32_t displayHeight{0};
  std::uint32_t pixelAspectNumerator{1};
  std::uint32_t pixelAspectDenominator{1};
  std::int16_t rotationDegrees{0};
  std::uint8_t bitsPerComponent{0};
  bool progressive{true};
  bool identityTransform{true};
  // Zero means the field-count extension is absent. A present FieldDetail or
  // a field count other than one makes progressive false.
  std::uint8_t fieldCount{0};
  bool fieldDetailPresent{false};
  // Absence means the container's exact implied full-coded aperture. Native
  // backends materialize an explicit rational aperture when inspecting media.
  std::optional<MediaCleanAperture> cleanAperture;
  MediaColorPrimaries colorPrimaries{MediaColorPrimaries::Unknown};
  MediaTransferFunction transferFunction{MediaTransferFunction::Unknown};
  MediaMatrixCoefficients matrixCoefficients{
      MediaMatrixCoefficients::Unknown};
  MediaChromaLocation topFieldChromaLocation{
      MediaChromaLocation::Unspecified};
  MediaChromaLocation bottomFieldChromaLocation{
      MediaChromaLocation::Unspecified};
  // This single fail-closed fact covers malformed/unrecognized explicit
  // color/chroma metadata and ICC/gamma/alpha metadata that the current
  // renderer does not implement. Known values remain available above.
  //
  // It does not cover HDR colour: BT.2020 primaries, the PQ and HLG
  // transfers, the BT.2020 NCL matrix, and the two HDR volume/light
  // descriptions are MODELLED facts rather than an opaque "unsupported" bit,
  // because the presentation path carries them correctly end to end -- see the
  // presence bools below.
  bool unsupportedColorMetadataPresent{false};
  bool dolbyVisionConfigurationPresent{false};
  // Exact result of parsing the codec configuration (for example avcC/hvcC and
  // its SPS). Unsupported is an immutable fallback proof.
  MediaVideoSampleFormat sampleFormat{MediaVideoSampleFormat::Unknown};

  // These follow every older field so aggregate initialization and the
  // defaulted operator== are unchanged for callers that do not set them.
  //
  // These are PRESENCE facts, deliberately not payloads. On this platform
  // VideoToolbox copies the container's
  // MasteringDisplayColorVolume and ContentLightLevelInfo verbatim onto the
  // decoded CVPixelBuffer, and CMVideoFormatDescriptionCreateForImageBuffer --
  // which is how native_layer_video_output builds the layer's format
  // description -- reproduces them byte for byte. Re-carrying the 24 and 4
  // bytes through this descriptor would create a second copy that could only
  // ever disagree with the decoder's. What admission needs from the container
  // is only whether the metadata exists, so that is all this records.
  bool masteringDisplayColorVolumePresent{false};
  bool contentLightLevelInfoPresent{false};
  // Admitted only as the single qualified HLG payload that
  // mediaVideoColorAdmitted() checks; any other ambient-viewing payload is
  // refused. Modelled separately from unsupportedColorMetadataPresent so that
  // check does not have to re-derive the whole opaque bit.
  bool ambientViewingEnvironmentPresent{false};
  std::uint64_t ambientViewingEnvironmentPayload{0};
  bool fullRangeVideo{false};

  friend bool operator==(const MediaVideoFormat&, const MediaVideoFormat&) =
      default;
};

// For compressed audio this describes the stream before decoding. Backend-
// specific decoder setup bytes (for example, an AAC magic cookie) live in the
// track's bounded codecConfiguration vector.
struct MediaAudioFormat {
  // CoreAudio exposes an exact Float64 sample rate. Keep it as double so
  // non-integer ASBD rates are not truncated during source admission.
  double sampleRate{0.0};
  std::uint32_t channels{0};
  // Exact encoded sample-entry/format identity as a backend-neutral,
  // fourcc-compatible scalar (for example, CoreAudio's ASBD format ID).
  // MediaCodec is only a routing family and cannot reconstruct AAC variants.
  std::uint32_t formatTag{0};
  std::uint32_t formatFlags{0};
  std::uint32_t framesPerPacket{0};
  std::uint32_t bytesPerPacket{0};
  std::uint32_t bytesPerFrame{0};
  std::uint32_t bitsPerChannel{0};
  std::uint32_t channelLayoutTag{0};
  bool interleaved{true};
  // A CoreAudio layout tag is not self-describing with respect to presence:
  // kAudioChannelLayoutTag_UseChannelDescriptions is numerically zero, just
  // like the value-initialized tag used when no layout metadata exists.
  // Preserve that distinction explicitly.  This field is intentionally
  // appended after interleaved so existing aggregate initialization cannot
  // silently reinterpret its final boolean as layout presence.
  bool channelLayoutPresent{false};

  friend bool operator==(const MediaAudioFormat&, const MediaAudioFormat&) =
      default;
};

struct MediaTrackDescriptor {
  MediaTrackId id{0};
  MediaTrackKind kind{MediaTrackKind::Metadata};
  MediaCodec codec{MediaCodec::Unknown};
  MediaTime timeBase{};
  MediaTime duration{};
  std::string language;
  std::string label;
  MediaCodecConfigurationKind codecConfigurationKind{
      MediaCodecConfigurationKind::None};
  std::vector<std::byte> codecConfiguration;
  std::optional<MediaVideoFormat> video;
  std::optional<MediaAudioFormat> audio;

  friend bool operator==(const MediaTrackDescriptor&,
                         const MediaTrackDescriptor&) = default;
};

// Fixed, allocation-free result of one bounded container track enumeration.
// `tracks` below remains the detailed descriptor set needed by selected
// outputs; inventory is authoritative for admission facts about unselected
// tracks, so opening a many-track asset does not trigger per-track loads.
struct MediaTrackInventory {
  std::uint8_t video{0};
  std::uint8_t audio{0};
  std::uint8_t subtitle{0};
  std::uint8_t text{0};
  std::uint8_t closedCaption{0};
  std::uint8_t metadata{0};
  std::uint8_t total{0};

  friend constexpr bool operator==(const MediaTrackInventory&,
                                   const MediaTrackInventory&) = default;
};

struct MediaSourceDescriptor {
  MediaTime duration{};
  MediaTrackInventory inventory;
  std::vector<MediaTrackDescriptor> tracks;
  std::optional<MediaTrackId> selectedVideo;
  std::optional<MediaTrackId> selectedAudio;
  std::optional<MediaTrackId> selectedSubtitle;

  friend bool operator==(const MediaSourceDescriptor&,
                         const MediaSourceDescriptor&) = default;
};

// These are deliberately opaque tags rather than public Apple/FFmpeg types.
// A backend-specific adapter must request the exact kind and then bridge the
// returned address while retaining the MediaPayloadLease.
enum class NativePayloadKind : std::uint8_t {
  CoreMediaSampleBuffer,
  CoreMediaAudioBufferList,
};

template <NativePayloadKind Kind>
class BorrowedNativePayload final {
 public:
  [[nodiscard]] explicit operator bool() const noexcept {
    return address_ != nullptr;
  }
  [[nodiscard]] const void* opaqueAddress() const noexcept { return address_; }

 private:
  explicit BorrowedNativePayload(const void* address) noexcept
      : address_(address) {}

  const void* address_{nullptr};
  friend class MediaPayloadLease;
};

// Immutable payload ownership. Implementations may retain a CMSampleBuffer,
// move-ref an AVPacket, or own bounded bytes. A borrowed span/native address
// is valid only while at least one MediaPayloadLease remains alive.
class MediaPayloadStorage {
 public:
  virtual ~MediaPayloadStorage() = default;

  [[nodiscard]] virtual std::size_t byteSize() const noexcept = 0;
  // Empty means either an empty payload or non-contiguous backing. Callers
  // distinguish those cases with byteSize().
  [[nodiscard]] virtual std::span<const std::byte>
  contiguousBytes() const noexcept = 0;
  [[nodiscard]] virtual bool
  copyBytes(std::size_t offset, std::span<std::byte> destination) const
      noexcept = 0;

 protected:
  [[nodiscard]] virtual std::optional<NativePayloadKind>
  nativePayloadKind() const noexcept = 0;
  [[nodiscard]] virtual const void* borrowedNativePayload() const noexcept = 0;

 private:
  friend class MediaPayloadLease;
};

class MediaPayloadLease final {
 public:
  MediaPayloadLease() noexcept = default;
  explicit MediaPayloadLease(
      std::shared_ptr<const MediaPayloadStorage> storage) noexcept;

  [[nodiscard]] explicit operator bool() const noexcept;
  [[nodiscard]] std::size_t byteSize() const noexcept;
  [[nodiscard]] std::span<const std::byte> contiguousBytes() const noexcept;
  [[nodiscard]] bool
  copyBytes(std::size_t offset,
            std::span<std::byte> destination) const noexcept;

  template <NativePayloadKind Kind>
  [[nodiscard]] std::optional<BorrowedNativePayload<Kind>>
  borrowNative() const noexcept {
    if (storage_ == nullptr || storage_->nativePayloadKind() != Kind) {
      return std::nullopt;
    }
    const void* address = storage_->borrowedNativePayload();
    if (address == nullptr) {
      return std::nullopt;
    }
    return BorrowedNativePayload<Kind>(address);
  }

  void reset() noexcept { storage_.reset(); }

 private:
  std::shared_ptr<const MediaPayloadStorage> storage_;
};

enum class MediaSampleKind : std::uint8_t {
  EncodedVideo,
  EncodedAudio,
  DecodedAudio,
};

// Samples are move-only to prevent accidental fan-out. Consumers that must
// retain bytes across an asynchronous API call explicitly copy the cheap,
// immutable payload lease after first reserving bounded capacity.
struct MediaSample {
  MediaGeneration generation{0};
  MediaTrackId track{0};
  MediaSampleKind kind{MediaSampleKind::EncodedVideo};
  MediaTime presentationTime{};
  MediaTime decodeTime{};
  MediaTime duration{};
  bool keyFrame{false};
  bool decodeOnly{false};
  bool discontinuity{false};
  // Compressed video is exactly one access unit. A retained CoreMedia audio
  // sample buffer may contain multiple compressed packets; their packet
  // descriptions remain available through its typed native lease.
  std::uint32_t sampleCount{1};
  std::uint32_t decodedAudioFrames{0};
  // AAC only: each packet's CoreMedia timing states the presentation extent
  // the source proved from the container's edit list (an overlap trim when
  // shorter than the access unit, declared silence when longer) instead of
  // the access unit's decoded length. The converter maps such samples onto
  // its piecewise timeline.
  bool aacPiecewiseTimeline{false};
  MediaPayloadLease payload;

  MediaSample() = default;
  MediaSample(MediaSample&&) noexcept = default;
  MediaSample& operator=(MediaSample&&) noexcept = default;
  MediaSample(const MediaSample&) = delete;
  MediaSample& operator=(const MediaSample&) = delete;
};

struct MediaEndOfStream {
  MediaGeneration generation{0};
  MediaTrackId track{0};
};

struct MediaSourceCancelled {
  MediaGeneration generation{0};
};

struct MediaSourceFailure {
  MediaGeneration generation{0};
  std::string error;
};

struct MediaSourceExhausted {
  MediaGeneration generation{0};
};

// Marker-only buffers and container timeline resets carry no encoded payload.
// Keeping them separate from MediaFormatChanged prevents consumers from
// rebuilding decoders for a pure clock/discontinuity boundary.
struct MediaDiscontinuity {
  MediaGeneration generation{0};
  MediaTrackId track{0};
  MediaTime time{};
};

struct MediaFormatChanged {
  MediaGeneration generation{0};
  MediaTrackDescriptor track;
};

using MediaSourceReadResult =
    std::variant<MediaSample, MediaEndOfStream, MediaFormatChanged,
                 MediaDiscontinuity, MediaSourceCancelled,
                 MediaSourceFailure, MediaSourceExhausted>;

enum class MediaSeekMode : std::uint8_t {
  Accurate,
  KeyFrame,
};

// Exact initial positioning is part of the first source generation. A native
// owner must pass this through openLocalFile(); opening at zero and then
// recreating the reader through seek() is not an equivalent preparation.
struct MediaSourceInitialPosition {
  MediaTime target{};
  MediaSeekMode mode{MediaSeekMode::Accurate};

  friend constexpr bool operator==(const MediaSourceInitialPosition&,
                                   const MediaSourceInitialPosition&) =
      default;
};

struct MediaSourceLimits {
  static constexpr std::size_t kHardMaximumTracks{64};
  static constexpr std::size_t kHardMaximumCodecConfigurationBytes{
      256U * 1024U};
  static constexpr std::size_t kHardMaximumVideoSampleBytes{
      8U * 1024U * 1024U};
  static constexpr std::size_t kHardMaximumAudioSampleBytes{256U * 1024U};
  static constexpr std::size_t kHardMaximumAudioSampleCount{1024};
  static constexpr std::size_t kHardMaximumDecodedAudioFrames{4096};
  static constexpr std::size_t kHardMaximumDecodedAudioBytes{
      4096U * 8U * sizeof(float)};
  static constexpr std::size_t kHardMaximumTrackTextBytes{1024};
  // 4096x2320 is the 4K-class envelope: it covers DCI 4K (4096x2160), UHD
  // (3840x2160), and the taller-than-UHD desktop capture geometries screen
  // recorders produce (for example 3418x1843), while 9,502,720 px is exactly
  // 4096*2320 rather than an
  // independently chosen number. Every byte budget derived from this ceiling
  // restates its own arithmetic where it lives:
  //   native_surface_budget.hpp   process-wide decoded-surface byte budget
  //   native_video_consumer.hpp   the route's worst-case lease bytes
  //   software_vp8_decoder.hpp    the VP8 pool's footprint
  static constexpr std::uint32_t kHardMaximumCodedWidth{4096};
  static constexpr std::uint32_t kHardMaximumCodedHeight{2320};
  static constexpr std::uint64_t kHardMaximumCodedPixels{
      4096ULL * 2320ULL};

  // The envelope is a RECTANGLE, not a width and a
  // height. Read per-axis, the two constants above would refuse 2160x3840 -- an
  // ordinary portrait 4K phone video -- because its long axis is its height,
  // even though its 8,294,400 px is comfortably under the 9,502,720 px budget
  // and its decoded surface costs exactly what its landscape transpose costs.
  // The rule is therefore stated once, here, against the SORTED pair:
  //
  //     max(w,h) <= kHardMaximumCodedWidth   (4096, the longest axis)
  //     min(w,h) <= kHardMaximumCodedHeight  (2320, the shortest axis)
  //     w * h    <= kHardMaximumCodedPixels  (9,502,720, unchanged)
  //
  // Every byte budget DERIVED from the pixel budget is therefore independent
  // of orientation. This does not admit arbitrary shapes -- 4096x4096 still
  // fails on min(w,h). The axis a bound applies to is decided by the shape,
  // not by the field's name.
  //
  // NOTE the one derivation that is NOT a pure function of the pixel count:
  // native_surface_budget.hpp's row-alignment slack scales with a surface's
  // HEIGHT, and the tallest admissible surface is 4096 rows, not 2320. That
  // header re-derives its own arithmetic and re-asserts it.
  //
  // Division rather than multiplication for the area test: `w <= P / h` is
  // exactly equivalent to `w * h <= P` over positive integers, and cannot
  // overflow on the way to the answer.
  [[nodiscard]] static constexpr bool codedDimensionsWithin(
      std::uint64_t width, std::uint64_t height, std::uint64_t longestAxis,
      std::uint64_t shortestAxis, std::uint64_t pixels) noexcept {
    if (width == 0 || height == 0) {
      return false;
    }
    const std::uint64_t longer = width > height ? width : height;
    const std::uint64_t shorter = width > height ? height : width;
    return longer <= longestAxis && shorter <= shortestAxis &&
           width <= pixels / height;
  }

  // The fixed v1 envelope, which no caller can expand.
  [[nodiscard]] static constexpr bool codedDimensionsWithinHardCeiling(
      std::uint64_t width, std::uint64_t height) noexcept {
    return codedDimensionsWithin(width, height, kHardMaximumCodedWidth,
                                 kHardMaximumCodedHeight,
                                 kHardMaximumCodedPixels);
  }
  static constexpr std::uint32_t kHardMaximumAudioChannels{8};
  static constexpr double kHardMaximumAudioSampleRate{384'000.0};
  // Fast-seek thresholds; longer preroll is streamed with bounded retention
  // and may be superseded by a newer generation. These are not admission caps.
  static constexpr double kHardMaximumVideoSeekPrerollSeconds{12.0};
  static constexpr std::uint32_t kHardMaximumAudioSeekPrerollSeconds{12};

  std::size_t maximumTracks{kHardMaximumTracks};
  std::size_t maximumCodecConfigurationBytes{
      kHardMaximumCodecConfigurationBytes};
  std::size_t maximumVideoSampleBytes{kHardMaximumVideoSampleBytes};
  std::size_t maximumAudioSampleBytes{kHardMaximumAudioSampleBytes};
  std::size_t maximumAudioSampleCount{kHardMaximumAudioSampleCount};
  // 4096 frames and 128 KiB cover one float32 block at up to eight channels.
  std::size_t maximumDecodedAudioFrames{kHardMaximumDecodedAudioFrames};
  std::size_t maximumDecodedAudioBytes{kHardMaximumDecodedAudioBytes};
  std::size_t maximumTrackTextBytes{kHardMaximumTrackTextBytes};
  // Callers may tighten these backend admission limits, but validation never
  // expands the current v1 hard ceilings of 4096x2320, eight channels, and
  // 384 kHz.
  std::uint32_t maximumCodedWidth{kHardMaximumCodedWidth};
  std::uint32_t maximumCodedHeight{kHardMaximumCodedHeight};
  std::uint64_t maximumCodedPixels{kHardMaximumCodedPixels};

  // The same rectangle rule against THIS instance's (possibly tightened)
  // bounds. A caller that tightens to 1920x1080 is asking for "no axis over
  // 1920, no second axis over 1080", which admits 1080x1920 -- the tightening
  // is a smaller rectangle, still orientation-agnostic, never an expansion.
  [[nodiscard]] constexpr bool codedDimensionsAdmitted(
      std::uint64_t width, std::uint64_t height) const noexcept {
    return codedDimensionsWithin(width, height, maximumCodedWidth,
                                 maximumCodedHeight, maximumCodedPixels);
  }
  std::uint32_t maximumAudioChannels{kHardMaximumAudioChannels};
  double maximumAudioSampleRate{kHardMaximumAudioSampleRate};
  double maximumVideoSeekPrerollSeconds{
      kHardMaximumVideoSeekPrerollSeconds};
  // The integer fast-seek threshold keeps frame-domain comparisons exact.
  std::uint32_t maximumAudioSeekPrerollSeconds{
      kHardMaximumAudioSeekPrerollSeconds};
};

// Options may tighten resource limits but can never expand the fixed v1
// admission envelope. Backends call this before allocating, probing, or
// constructing a reader; the validation helpers also clamp defensively.
[[nodiscard]] MediaSourceLimits clampMediaSourceLimits(
    const MediaSourceLimits& requested) noexcept;
// Cheap validation for the part of an initial position that is knowable
// before source metadata is loaded. Duration-relative validation remains the
// backend's responsibility once it has the exact descriptor duration.
[[nodiscard]] bool validateMediaSourceInitialPosition(
    const std::optional<MediaSourceInitialPosition>& position,
    std::string* error = nullptr) noexcept;

struct MediaTrackSelection {
  std::optional<MediaTrackId> preferredVideo;
  std::optional<MediaTrackId> preferredAudio;
  std::optional<MediaTrackId> preferredSubtitle;
  bool requireVideo{true};
  bool requireAudio{false};
};

struct MediaSourceOpenOptions {
  MediaTrackSelection selection;
  MediaSourceLimits limits;
  std::optional<MediaSourceInitialPosition> initialPosition;
  // The open preflight found the file on a non-local mount; such a file is
  // read through the buffered libavformat route.
  bool bufferedStorage{false};
};

// Immutable identity of the backend state admitted by one Ready open. Main
// generations and private preview cursors may own different reader/cursor
// objects, but they must retain this exact context and descriptor instance.
// Initial position is deliberately absent from identity: it selects a
// generation range, not a different prepared container or track selection.
enum class MediaSourceBackendKind : std::uint8_t {
  AVFoundation,
  Matroska,
  // MPEG-2 Transport Stream is demuxed by src/media/mpegts_demuxer.*; unlike the two above it
  // carries an explicit PES DTS, which is why its media source keys the A/V
  // merge on real decode timestamps rather than on a synthetic ordering lead.
  MpegTs,
  Libavformat,
};

class MediaSourcePreparedContext {
 public:
  virtual ~MediaSourcePreparedContext();

  MediaSourcePreparedContext(const MediaSourcePreparedContext&) = delete;
  MediaSourcePreparedContext& operator=(
      const MediaSourcePreparedContext&) = delete;

  [[nodiscard]] MediaSourceBackendKind backendKind() const noexcept;
  [[nodiscard]] const std::filesystem::path& localPath() const noexcept;
  [[nodiscard]] const MediaTrackSelection& selection() const noexcept;
  [[nodiscard]] const MediaSourceLimits& limits() const noexcept;
  [[nodiscard]] const std::shared_ptr<const MediaSourceDescriptor>&
  descriptor() const noexcept;

  // Exact descriptor-instance identity is intentional. A deep-equal clone is
  // not proof that a seek or preview cursor retained the admitted backend
  // state. Initial position remains excluded for the reason above.
  [[nodiscard]] bool matchesMainRequest(
      const std::filesystem::path& path,
      const MediaSourceOpenOptions& options,
      const std::shared_ptr<const MediaSourceDescriptor>& descriptor)
      const noexcept;
  [[nodiscard]] bool matchesPreviewBinding(
      const std::filesystem::path& path,
      const std::shared_ptr<const MediaSourceDescriptor>& descriptor)
      const noexcept;

 protected:
  MediaSourcePreparedContext(
      MediaSourceBackendKind backendKind, std::filesystem::path path,
      const MediaSourceOpenOptions& options,
      std::shared_ptr<const MediaSourceDescriptor> descriptor) noexcept;

 private:
  MediaSourceBackendKind backendKind_;
  std::filesystem::path path_;
  MediaTrackSelection selection_;
  MediaSourceLimits limits_;
  std::shared_ptr<const MediaSourceDescriptor> descriptor_;
};

// Source-proved audio boundaries for one generation. decodeStart is the
// timestamp of the first staged compressed audio access unit. After decoding,
// whole PCM frames before presentationStart are discarded; the frame at
// presentationStart retains that source timestamp. Invalid default times are
// the sole empty encoding used when no audio track is selected.
struct MediaAudioGenerationWindow {
  MediaTime decodeStart{};
  MediaTime presentationStart{};
  bool startsAtStreamOrigin{false};
  // Movie time at which the selected audio MEDIA begins. Nonzero exactly for a
  // container that declares silence before its audio -- an ISO-BMFF leading
  // empty edit (elst media_time = -1) states [0, mediaStart) as silence on the
  // movie timeline. The default {0,1} is "audio media begins at the origin",
  // which is every source that declares no such silence.
  MediaTime mediaStart{0, 1};
  // Movie time at which this generation's PRESENTATION ends, when the selected
  // audio stops short of the selected video and the container therefore
  // declares trailing silence. Invalid (the default) means "the selected
  // audio's own end", i.e. no declared trailing silence.
  MediaTime presentationEnd{};
  // Movie time at which the selected audio MEDIA ends, as the container states
  // it. Stated only beside presentationEnd, and only so that the renderer can
  // tell container-declared trailing silence from a producer that is merely
  // late: past this time the source itself says there is no more audio, which
  // an exhausted ring alone cannot prove until the source signals end-of-
  // stream -- and on a real file that signal arrives when reads reach the end
  // of the FILE, long after the audio track's own last sample.
  MediaTime audioEnd{};

  friend constexpr bool operator==(const MediaAudioGenerationWindow&,
                                   const MediaAudioGenerationWindow&) =
      default;
};

struct MediaSourceOpenOutcome {
  MediaSourceOpenStatus status{MediaSourceOpenStatus::Failed};
  MediaGeneration generation{0};
  // Exact full-sync/decode start selected by the backend. It may precede the
  // requested target. Accurate-mode video preroll is marked decodeOnly;
  // compressed audio remains decodable so its consumer can trim decoded PCM
  // at exact frame granularity.
  MediaTime actualDecodeStart{};
  // Ready owns one immutable descriptor instance. The same instance can flow
  // through playback Prepared events without copying bounded codec metadata.
  std::shared_ptr<const MediaSourceDescriptor> descriptor;
  std::string error;
  // Ready additionally proves one immutable backend context whose descriptor
  // pointer is exactly descriptor.get(). Non-Ready outcomes carry no context.
  std::shared_ptr<const MediaSourcePreparedContext> preparedContext;
  // Ready with selected audio must carry an exact, nonempty window.
  MediaAudioGenerationWindow audioWindow{};
  // The typed class of a non-Ready outcome, when the source names one. Routing
  // decisions read this, never the error text.
  MediaRefusalClass refusal{MediaRefusalClass::None};
};

struct MediaSourceSeekRequest {
  MediaGeneration generation{0};
  MediaTime target{};
  MediaSeekMode mode{MediaSeekMode::Accurate};
};

struct MediaSourceSeekOutcome {
  bool accepted{false};
  MediaGeneration generation{0};
  MediaTime actualDecodeStart{};
  std::string error;
  // Every accepted seek returns the exact context pointer admitted by open.
  // A dispatcher rejects the generation before consumer flush if it changes.
  std::shared_ptr<const MediaSourcePreparedContext> preparedContext;
  // Every accepted seek with selected audio must carry an exact window.
  MediaAudioGenerationWindow audioWindow{};
};

struct MediaSourceStats {
  bool open{false};
  bool cancelled{false};
  // Exact generation currently exposed to requestCancel(). During a blocking
  // open this is published before I/O begins, even though open remains false.
  MediaGeneration operationGeneration{0};
  // Latest owner generation, including a cancelled or failed open attempt.
  MediaGeneration generation{0};
  // A source may stage at most one selected video head and one selected audio
  // head while merging their timelines. It has no callback/prefetch queue.
  // These four staged-owner facts form one serialized owner-method-boundary
  // snapshot. stagedGeneration is zero exactly when both head counts are zero;
  // otherwise it names the generation that owns every reported staged byte.
  // `generation` above is only the operation high-water and can already name a
  // newer armed operation while these facts still describe older heads.
  // Arbitrary cross-thread sampling is not a coherent memory checkpoint: the
  // source worker must capture stats() at one of its serialized boundaries and
  // publish that POD through its own synchronization boundary.
  MediaGeneration stagedGeneration{0};
  std::size_t stagedVideoHeads{0};
  std::size_t stagedAudioHeads{0};
  std::size_t stagedPayloadBytes{0};
  // Lifetime diagnostic high-water only. It is never additive with another
  // owner's high-water; a synchronized aggregate ledger must join current
  // ownership transitions to derive a concurrent process peak.
  std::size_t peakStagedPayloadBytes{0};
  std::uint64_t samplesEmitted{0};
  std::uint64_t seeksAccepted{0};
};
static_assert(std::is_standard_layout_v<MediaSourceStats>);
static_assert(std::is_trivially_copyable_v<MediaSourceStats>);

[[nodiscard]] bool validateMediaSourceDescriptor(
    const MediaSourceDescriptor& descriptor, const MediaSourceLimits& limits,
    std::string* error = nullptr) noexcept;
[[nodiscard]] bool validateMediaSample(
    const MediaSample& sample, const MediaSourceDescriptor& descriptor,
    const MediaSourceLimits& limits,
    std::string* error = nullptr) noexcept;
[[nodiscard]] bool validateMediaDiscontinuity(
    const MediaDiscontinuity& discontinuity,
    const MediaSourceDescriptor& descriptor,
    std::string* error = nullptr) noexcept;
[[nodiscard]] const MediaTrackDescriptor* findMediaTrack(
    const MediaSourceDescriptor& descriptor, MediaTrackId id) noexcept;
[[nodiscard]] bool mediaVideoHasFullCodedAperture(
    const MediaVideoFormat& video) noexcept;
[[nodiscard]] bool mediaVideoHasSquarePixels(
    const MediaVideoFormat& video) noexcept;

// THE colour-admission rule for the native presentation contract.
//
// It is ONE function because source admission in avfoundation_media_source.mm
// (`supportedModeledColor`) and native_video_consumer.mm
// (`supportedVideoTrack`) must agree: if they drift apart, a clean Unsupported
// verdict becomes a mid-startup Failed one, because the source admits a
// descriptor the consumer then refuses. Both call this.
//
// WHAT IS ADMITTED, and why it is safe rather than optimistic. VideoToolbox
// attaches the stream's own colorimetry to every decoded surface -- primaries,
// transfer, matrix, and the HDR mastering/content-light descriptions when the
// container carries them -- and it resolves a full CGColorSpace alongside them
// (measured: "Rec. ITU-R BT.2100 PQ" / "Rec. ITU-R BT.2100 HLG").
// CMVideoFormatDescriptionCreateForImageBuffer reproduces all of it, so the
// AVSampleBufferDisplayLayer this player enqueues into receives a fully
// described surface and WindowServer performs the tone mapping. Nothing here
// is a promise about a renderer this player would have to write.
//
//   primaries : Unknown (untagged), BT.601, BT.709, BT.2020
//   transfer  : Unknown (untagged), BT.709, PQ (ST 2084), HLG (BT.2100)
//   matrix    : Unknown (untagged), BT.601, BT.709, BT.2020 NCL
//   depth     : untagged, 8, or 10
//
// 8-bit 4:4:4 is further limited to limited-range video with BT.709 transfer
// and matched BT.709 or BT.601 primaries and matrix. Ambient-viewing-
// environment metadata is admitted only as the qualified HLG payload on
// limited-range BT.2020 / HLG / BT.2020 NCL 10-bit 4:2:0.
//
// STILL REFUSED, by name: sRGB and every other explicit transfer, any
// OtherExplicit value, Dolby Vision configurations, any other
// ambient-viewing-environment metadata, and the opaque
// unsupportedColorMetadataPresent bit (gamma, ICC, alpha, alternative and log
// transfer characteristics, out-of-envelope bit depths).
[[nodiscard]] bool mediaVideoColorAdmitted(
    const MediaVideoFormat& video) noexcept;

// The rectangle the picture occupies on screen, in square pixels. Zero on both
// axes is the sole empty encoding and means "not stated"; see the free
// functions below for who produces it and when.
struct MediaDisplaySize {
  MediaRational width{};
  MediaRational height{};

  [[nodiscard]] constexpr bool empty() const noexcept {
    return width.numerator <= 0 || height.numerator <= 0;
  }

  friend constexpr bool operator==(const MediaDisplaySize&,
                                   const MediaDisplaySize&) = default;
};

// One track's display size, which is what window geometry -- aspect lock,
// aspect snap, Actual Size, fit-to-screen -- has to be shaped from.
//
// For square pixels, displayWidth/displayHeight are preferred over the coded
// size and the coded size is only a fallback for a backend that left them
// unset. For non-square pixels the integral display fields are only hints: the
// size is reconstructed exactly from the clean aperture (or the coded size)
// with its width scaled by the pixel aspect ratio, because an anamorphic
// track's coded size is a different aspect ratio from the picture, and
// shaping a window with it letterboxes the very video the window was supposed
// to hug. AVFoundation fills the display pair from
// CMVideoFormatDescriptionGetPresentationDimensions with pixel aspect ratio
// and clean aperture already applied; the Matroska and MPEG-TS demuxers fill
// it with their admitted (square-pixel, uncropped) geometry.
//
// Rotation is applied last because a quarter turn swaps the rectangle. It is
// applied here, once, rather than by each caller: this is the only function
// through which a display size reaches anything that sizes a window.
[[nodiscard]] MediaDisplaySize mediaVideoDisplaySize(
    const MediaVideoFormat& video) noexcept;

// The same, for whichever video track a descriptor has selected. Empty when no
// video track is selected (an audio-only source), when the selection does not
// resolve to a track in the descriptor, or when that track states no usable
// dimensions at all.
[[nodiscard]] MediaDisplaySize mediaSourceDisplaySize(
    const MediaSourceDescriptor& descriptor) noexcept;

// Single-owner pull boundary. openLocalFile(), seek(), readNext(), and close()
// are confined to one source worker/retirement owner and may block there;
// requestCancel() is prompt, noexcept, and callable from any thread. A source
// holds no more than the two documented A/V lookahead heads and never reads a
// new packet while downstream capacity is unavailable.
// A Ready open has already retained one real sample head from every selected
// A/V output as its admission proof. Those exact heads are delivered by the
// first readNext() calls; implementations must not probe, discard, reopen, and
// reread the same media during activation.
//
// The owner calls armOperation() before it publishes an externally cancellable
// operation or enters openLocalFile()/seek(). A cancelled/failed operation
// withdraws publication; close() fully retires the operation while preserving
// the generation high water, and a later strictly newer open must be supported.
//
// readNext() emits exactly one MediaEndOfStream for each selected track in a
// generation. After all selected-track markers have been consumed, later
// reads return the idempotent MediaSourceExhausted marker for that generation.
class MediaSource {
 public:
  virtual ~MediaSource() = default;

  // Reserves the exact next owner generation. A successful arm immediately
  // burns the generation high water and exposes that exact requestCancel()
  // slot. Matching openLocalFile()/seek() consumes the arm once and checks a
  // latched cancellation before blocking. A mismatched call cannot steal the
  // arm; stale/future cancels remain inert. close() clears an unconsumed arm
  // without lowering the high water.
  [[nodiscard]] virtual bool
  armOperation(MediaGeneration generation) noexcept = 0;
  [[nodiscard]] virtual MediaSourceOpenOutcome openLocalFile(
      const std::filesystem::path& path, const MediaSourceOpenOptions& options,
      MediaGeneration generation) = 0;
  [[nodiscard]] virtual MediaSourceSeekOutcome seek(
      const MediaSourceSeekRequest& request) = 0;
  [[nodiscard]] virtual MediaSourceReadResult
  readNext(MediaGeneration expectedGeneration) = 0;
  // Cancels only the exact currently active generation. Stale and future
  // generation values are inert, so a late cancel cannot burn newer media.
  virtual void requestCancel(MediaGeneration generation) noexcept = 0;
  virtual void close() noexcept = 0;
  // Owner-thread/method-boundary snapshot. An external observer must not poll
  // this concurrently with openLocalFile(), seek(), readNext(), or close().
  [[nodiscard]] virtual MediaSourceStats stats() const noexcept = 0;
};

}  // namespace wam::media
