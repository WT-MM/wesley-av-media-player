#pragma once

#include "media/audio_downmix.hpp"
#include "media/native_media_source.hpp"
#include "native_pcm_ring.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <string>
#include <utility>

namespace wam::macos {

struct NativeAudioPacketDescription {
  std::int64_t startOffset{0};
  std::uint32_t byteSize{0};
  std::uint32_t variableFrames{0};
};

struct NativeAudioBackendConfiguration {
  media::MediaAudioFormat input;
  // Borrowed only for the duration of configure().
  std::span<const std::byte> magicCookie;
  std::uint32_t outputChannels{0};
  std::uint32_t outputSampleRate{0};
};

struct NativeAudioBackendInput {
  std::span<const std::byte> bytes;
  std::span<const NativeAudioPacketDescription> packets;
  bool endOfStream{false};
};

struct NativeAudioBackendResult {
  std::size_t consumedPackets{0};
  std::size_t producedFrames{0};
  // True only when the input proc was invoked after the final nonempty packet
  // handoff. At that documented callback boundary, the wrapper may reuse the
  // prior byte and packet-description storage.
  bool finalInputReleased{false};
  bool needsInput{false};
  bool drained{false};
  bool failed{false};
};

// Owner-thread decoder boundary. Implementations may throw; the wrapper
// catches every exception before it crosses the media producer boundary.
// convert() receives capacity for exactly one fixed 4096-frame output slab.
class NativeAudioConverterBackend {
public:
  virtual ~NativeAudioConverterBackend() = default;

  [[nodiscard]] virtual bool
  configure(const NativeAudioBackendConfiguration &configuration,
            std::string *error) = 0;
  [[nodiscard]] virtual NativeAudioBackendResult
  convert(NativeAudioBackendInput input,
          std::span<float> interleavedOutput) = 0;
  [[nodiscard]] virtual bool reset(std::string *error) = 0;
  virtual void close() noexcept = 0;

  // Reports the exact ordered channel roles the backend's decoded output
  // carries, so a multichannel generation can be folded to stereo by LABEL
  // rather than by an assumed index order. Writes at most roles.size() entries
  // and stores the count.
  //
  // Deliberately NOT pure: the default answers "this backend states no channel
  // layout", which is the truthful answer for every stereo-or-narrower test
  // double and keeps the existing frozen backends compiling unchanged. The
  // converter only ASKS when the source is wider than stereo, and a source
  // wider than stereo whose backend cannot state its layout is refused rather
  // than guessed.
  [[nodiscard]] virtual bool
  outputChannelRoles(std::span<media::AudioChannelRole> roles,
                     std::size_t *roleCount) noexcept {
    static_cast<void>(roles);
    if (roleCount != nullptr) {
      *roleCount = 0;
    }
    return false;
  }
};

enum class NativeAudioSubmitResult : std::uint8_t {
  Accepted,
  Backpressure,
  StaleGeneration,
  Invalid,
  Failed,
};

// Exact generation-local audio presentation contract. presentationFloor is
// the source timestamp A of the first PCM frame the generation may publish;
// it is deliberately separate from an arbitrary visual seek target T. The
// converter never relabels the retained frame A as T. trimBeforeFloor is true
// only for an accurate seek whose first compressed audio access unit D starts
// before A. The converter decodes that bounded preroll to establish codec
// state, then discards every whole decoded PCM frame before A.
struct NativeAudioGenerationTimeline {
  media::MediaTime presentationFloor{0, 1};
  bool trimBeforeFloor{false};
  // True only when the reader begins at the admitted stream origin. Every
  // other fresh decoder generation must prove that its first compressed audio
  // sample is an ImmediatePlayoutFrame before conversion.
  bool startsAtStreamOrigin{true};
  // Mirror image of presentationFloor: the source timestamp of the first PCM
  // frame the generation may NOT publish. It exists because a constant-frame
  // codec cannot end mid-packet -- an Opus encoder always emits a final full
  // packet and states the overrun as Matroska DiscardPadding -- so the decoded
  // tail has to be discarded at exact frame granularity. The discarded frames
  // still count as decoded, so the generation's exact accepted-frame budget is
  // unchanged; only publication stops early. Appended with an inert default so
  // every existing aggregate initialiser keeps its exact meaning.
  media::MediaTime presentationCeiling{};
  bool trimAfterCeiling{false};
};

class NativeAudioConverter;

// Move-only proof that one exact MediaSample was fully validated and staged
// while its caller retained ownership. A stable contiguous payload is borrowed
// under the subsequently committed lease; non-contiguous payloads are copied
// into the converter's bounded staging area. The proof is bound both to one
// prepare serial and to the borrowed native CMSampleBuffer identity; it cannot
// be reused for another lease.
class NativeAudioPreparedSample final {
public:
  NativeAudioPreparedSample() noexcept = default;
  NativeAudioPreparedSample(NativeAudioPreparedSample &&other) noexcept
      : instance_(std::move(other.instance_)),
        owner_(std::exchange(other.owner_, nullptr)),
        serial_(std::exchange(other.serial_, 0)),
        native_identity_(std::exchange(other.native_identity_, nullptr)) {}
  NativeAudioPreparedSample &
  operator=(NativeAudioPreparedSample &&other) noexcept {
    if (this != &other) {
      instance_ = std::move(other.instance_);
      owner_ = std::exchange(other.owner_, nullptr);
      serial_ = std::exchange(other.serial_, 0);
      native_identity_ = std::exchange(other.native_identity_, nullptr);
    }
    return *this;
  }

  NativeAudioPreparedSample(const NativeAudioPreparedSample &) = delete;
  NativeAudioPreparedSample &
  operator=(const NativeAudioPreparedSample &) = delete;

  [[nodiscard]] explicit operator bool() const noexcept {
    return !instance_.expired() && owner_ != nullptr && serial_ != 0 &&
           native_identity_ != nullptr;
  }

private:
  // The weak capability invalidates when its converter is destroyed, so a
  // stale token cannot revive if a later converter reuses the same address.
  std::weak_ptr<const void> instance_;
  const NativeAudioConverter *owner_{nullptr};
  std::uint64_t serial_{0};
  const void *native_identity_{nullptr};

  friend class NativeAudioConverter;
};

struct NativeAudioPrepareOutcome {
  NativeAudioSubmitResult result{NativeAudioSubmitResult::Failed};
  NativeAudioPreparedSample prepared;
};

enum class NativeAudioPumpResult : std::uint8_t {
  Published,
  Progress,
  Backpressure,
  NeedsInput,
  Drained,
  StaleGeneration,
  NotConfigured,
  Failed,
};

struct NativeAudioConverterStats {
  bool configured{false};
  bool cancelled{false};
  bool failed{false};
  bool samplePrepared{false};
  bool sampleRetained{false};
  // Exact logical compressed MediaPayload bytes currently owned by the
  // converter. A fragmented payload copied into the already-resident bounded
  // staging array is charged once here through its retained lease, never again
  // as staging capacity. The HWM is diagnostic since the latest successful
  // generation transition or explicit reset and is non-additive with every
  // other owner's HWM.
  std::size_t retainedPayloadBytes{0};
  std::size_t peakRetainedPayloadBytes{0};
  bool endOfStreamRequested{false};
  bool drained{false};
  std::uint64_t generation{0};
  std::uint32_t sampleRate{0};
  std::uint32_t sourceChannels{0};
  std::uint64_t acceptedSamples{0};
  std::uint64_t rejectedSamples{0};
  std::uint64_t staleSamples{0};
  std::uint64_t backpressuredSamples{0};
  // Successfully prepared ingress work, including a preparation later
  // abandoned by its dispatcher owner. These saturating counters distinguish
  // stable lease-backed borrowing from the bounded fragmented-payload copy
  // fallback.
  std::uint64_t borrowedEncodedSamples{0};
  std::uint64_t borrowedEncodedBytes{0};
  std::uint64_t copiedEncodedSamples{0};
  std::uint64_t copiedEncodedBytes{0};
  std::uint64_t consumedPackets{0};
  std::uint64_t producedFrames{0};
  // Unlike the saturating diagnostic counters above, these three counters are
  // exact and generation-local. Any overflow fails the converter before the
  // affected PCM can reach the ring.
  std::uint64_t decodedPcmFrames{0};
  std::uint64_t discardedTrimFrames{0};
  std::uint64_t publishedPcmFrames{0};
  std::int64_t presentationFloorFrame{0};
  std::int64_t firstPublishedFrame{0};
  bool firstPublishedFrameKnown{false};
  std::uint64_t publishedSlabs{0};
  std::uint64_t ringBackpressure{0};
  std::uint64_t failures{0};
  // Multichannel folding. downmixApplied is false for every mono and stereo
  // generation -- those bypass the stage entirely -- so a test can ASSERT the
  // bypass rather than infer it. downmixedFrames counts decoded frames that
  // passed through the matrix, which is exactly decodedPcmFrames when the
  // stage is active and zero when it is not; the downmix changes sample WIDTH
  // only and can never change a frame count.
  bool downmixApplied{false};
  std::uint64_t downmixedFrames{0};
};

// Serialized, off-real-time AudioConverter owner. The AudioUnit callback only
// sees NativePcmRing; this class creates no thread, timer, lock, or callback
// work. Construction reserves the full 256 KiB encoded staging area, 1024
// packet descriptions, 256 KiB magic cookie, and one 4096-frame Float32 slab.
// Their bounded payload/PCM paths allocate nothing after configuration.
//
// v1 admits exact AAC/HE-AAC/ALAC/MP3 ASBDs and only integral 44.1/48/96/192
// kHz rates. Channel-layout metadata may be absent; if present it must be the
// exact canonical Mono or Stereo tag matching the ASBD, or -- for a
// multichannel source -- a tag whose expansion is an admissible stereo
// downmix. It preserves the source rate.
//
// WIDTH is normalised immediately before publishing, never earlier and never
// on the render callback: mono is duplicated to stereo, and a source wider
// than stereo is decoded at its FULL native layout and folded to stereo by
// media::applyStereoDownmix using the decoder's own reported channel labels.
// Everything below the ring therefore stays exactly two channels. The fold is
// a width reduction only: frame counts, timestamps and every budget identity
// are untouched by it. CoreMedia buffer attachments
// TrimDurationAtStart/End accept only exact zero, SpeedMultiplier only exactly
// 1, and Reverse/FillDiscontinuitiesWithSilence/EmptyMedia only false. Missing
// keys carry their documented defaults. Input and output CoreMedia timing must
// be identical, packet durations must map to integral output frames, and the
// generation must be contiguous. Thus an unrepresented edit or codec trim is
// rejected before its affected PCM can be published. Encoded audio decodeOnly
// is always rejected; accurate-seek trimming is authorized only by the
// generation timeline.
class NativeAudioConverter final {
public:
  static constexpr std::size_t kMaximumEncodedBytes =
      media::MediaSourceLimits::kHardMaximumAudioSampleBytes;
  static constexpr std::size_t kMaximumPackets =
      media::MediaSourceLimits::kHardMaximumAudioSampleCount;
  static constexpr std::size_t kFramesPerPump = NativePcmRing::kFramesPerSlab;

  explicit NativeAudioConverter(
      NativePcmRing &ring,
      std::unique_ptr<NativeAudioConverterBackend> backend = {});
  ~NativeAudioConverter();

  NativeAudioConverter(const NativeAudioConverter &) = delete;
  NativeAudioConverter &operator=(const NativeAudioConverter &) = delete;
  NativeAudioConverter(NativeAudioConverter &&) = delete;
  NativeAudioConverter &operator=(NativeAudioConverter &&) = delete;

  [[nodiscard]] bool configure(const media::MediaTrackDescriptor &track,
                               media::MediaGeneration generation,
                               std::string *error = nullptr);
  [[nodiscard]] bool configure(const media::MediaTrackDescriptor &track,
                               media::MediaGeneration generation,
                               NativeAudioGenerationTimeline timeline,
                               std::string *error = nullptr);
  // Transactional dispatcher ingress: prepare() performs every rejectable
  // check and chooses stable-span borrowing or a bounded fallback copy without
  // taking ownership. On Accepted, the caller takes the exact sample once and
  // immediately calls commitPrepared(). A correct pair cannot fail; false is
  // an observable consumer-protocol fault and leaves the converter failed
  // closed.
  [[nodiscard]] NativeAudioPrepareOutcome
  prepare(const media::MediaSample &sample, std::string *error = nullptr);
  [[nodiscard]] bool commitPrepared(NativeAudioPreparedSample &&prepared,
                                    media::MediaSample &&sample) noexcept;

  // Convenience boundary for non-transactional owners. Non-Accepted results
  // do not move from sample.
  [[nodiscard]] NativeAudioSubmitResult submit(media::MediaSample &&sample,
                                               std::string *error = nullptr);
  [[nodiscard]] NativeAudioPumpResult pump(std::string *error = nullptr);
  [[nodiscard]] NativeAudioPumpResult
  endOfStream(media::MediaGeneration generation, std::string *error = nullptr);

  // Exact-generation cancellation is inert for stale/future values. flush()
  // accepts only a strictly newer nonzero generation already installed in the
  // quiescent ring by its lifecycle owner.
  void cancel(media::MediaGeneration generation) noexcept;
  [[nodiscard]] bool
  flush(media::MediaGeneration nextGeneration,
        NativeAudioGenerationTimeline timeline = {}) noexcept;
  void close() noexcept;

  [[nodiscard]] std::uint32_t outputSampleRate() const noexcept;
  [[nodiscard]] NativeAudioConverterStats stats() const noexcept;
  // Serialized owner phase boundary. The converter/ring/output graph must be
  // stopped and the expected generation must still be current. Success seeds
  // the diagnostic HWM from current retained ownership rather than zero.
  [[nodiscard]] bool resetRetainedPayloadByteHighWater(
      media::MediaGeneration expectedGeneration) noexcept;

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace wam::macos
