#include "native_audio_converter.hpp"
#include "platform/macos/native_primitives.hpp"
#include "native_audio_admission.hpp"
#include "native_audio_converter_backends.hpp"

#include "media/audio_downmix.hpp"
#include "media/media_codec_facts.hpp"
#include "core_media_codec_facts.hpp"
#include "core_media_time.hpp"
#include "native_audio_channel_map.hpp"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>

#include <algorithm>
#include <cstdio>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <limits>
#include <new>
#include <optional>
#include <utility>

namespace wam::macos {
namespace {


[[nodiscard]] bool checkedAdd(std::uint64_t value, std::uint64_t amount,
                              std::uint64_t *result) noexcept {
  if (amount > std::numeric_limits<std::uint64_t>::max() - value) {
    return false;
  }
  *result = value + amount;
  return true;
}

[[nodiscard]] std::uint64_t magnitude(std::int64_t value) noexcept {
  return value < 0 ? static_cast<std::uint64_t>(-(value + 1)) + 1
                   : static_cast<std::uint64_t>(value);
}

[[nodiscard]] bool exactFrame(media::MediaTime time, std::uint32_t sampleRate,
                              std::int64_t *result) noexcept {
  const auto frame = media::exactAudioFrameIndex(time, sampleRate);
  if (!frame || result == nullptr) {
    return false;
  }
  *result = *frame;
  return true;
}

[[nodiscard]] bool exactFrame(CMTime time, std::uint32_t sampleRate,
                              std::int64_t *result) noexcept {
  const auto exact = exactMediaTime(time);
  return exact && exactFrame(*exact, sampleRate, result);
}

[[nodiscard]] bool optionalFrame(CMTime time, std::uint32_t sampleRate,
                                 std::optional<std::int64_t> *result) noexcept {
  if (!CMTIME_IS_VALID(time)) {
    result->reset();
    return true;
  }
  std::int64_t frame = 0;
  if (!exactFrame(time, sampleRate, &frame)) {
    return false;
  }
  *result = frame;
  return true;
}

[[nodiscard]] bool checkedFrameEnd(std::int64_t start, std::uint64_t frames,
                                   std::int64_t *end) noexcept {
  if (frames >
      static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
    return false;
  }
  const auto signedFrames = static_cast<std::int64_t>(frames);
  if (start > std::numeric_limits<std::int64_t>::max() - signedFrames) {
    return false;
  }
  *end = start + signedFrames;
  return true;
}



[[nodiscard]] bool frameDistance(std::int64_t start, std::int64_t end,
                                 std::uint64_t *distance) noexcept {
  if (start > end || distance == nullptr) {
    return false;
  }
  if (start >= 0) {
    *distance = static_cast<std::uint64_t>(end - start);
    return true;
  }
  if (end < 0) {
    *distance = magnitude(start) - magnitude(end);
    return true;
  }
  return checkedAdd(magnitude(start), static_cast<std::uint64_t>(end),
                    distance);
}

// AudioToolbox swallows this many leading frames before it emits anything, so a
// generation decodes this many fewer frames than its packets declare. It is a
// property of the decoder, not of the container, which is why it is stated in
// the codec facts table and not carried in the timeline.
using media::decoderLeadInFrames;

// The frames a decoder never emits at all: its lead-in, unless it flushes the
// same number at the end.
[[nodiscard]] std::uint32_t
decoderFrameDeficitFrames(media::MediaCodec codec,
                          std::uint32_t framesPerPacket) noexcept {
  if (media::mediaCodecFacts(codec).decoderFlushesLeadInAtEnd) {
    return 0U;
  }
  return decoderLeadInFrames(codec, framesPerPacket);
}

// How many frames short of its declared packet budget a decoder may
// legitimately finish. See NativeAudioConverterState::decodedBudgetExhausted
// and the codec facts rows for why each value is what it is.
[[nodiscard]] std::uint32_t decoderTailShortfallBoundFrames(
    media::MediaCodec codec, std::uint32_t framesPerPacket) noexcept {
  const media::MediaCodecFacts &facts = media::mediaCodecFacts(codec);
  if (facts.decoderTailShortfallBelowOnePacket) {
    return framesPerPacket == 0U ? 0U : framesPerPacket - 1U;
  }
  return facts.decoderTailShortfallFrames;
}

// The AAC piecewise path works on the AAC-LC access-unit grid.
constexpr std::uint64_t kAacFrames = media::codec::kAacLcSamplesPerAccessUnit;

struct ChannelLayoutIdentity {
  bool present{false};
  std::uint32_t tag{0};
};

[[nodiscard]] bool readSupportedChannelLayout(
    const AudioChannelLayout *layout, std::size_t layoutSize,
    std::uint32_t channels, ChannelLayoutIdentity *identity) noexcept {
  if (identity == nullptr) {
    return false;
  }
  if (layout == nullptr) {
    if (layoutSize != 0) {
      return false;
    }
    *identity = {};
    return true;
  }
  if (layoutSize < kChannelLayoutPrefixBytes ||
      layout->mNumberChannelDescriptions != 0 ||
      layout->mChannelBitmap != 0 ||
      (layoutSize != kChannelLayoutPrefixBytes &&
       layoutSize != sizeof(AudioChannelLayout))) {
    return false;
  }
  media::MediaAudioFormat candidate;
  candidate.channels = channels;
  candidate.channelLayoutTag = layout->mChannelLayoutTag;
  candidate.channelLayoutPresent = true;
  if (!audioChannelLayoutAdmitted(candidate)) {
    return false;
  }
  *identity = {true, layout->mChannelLayoutTag};
  return true;
}


[[nodiscard]] bool falseOrAbsent(CMSampleBufferRef sample, CFStringRef key,
                                 std::string *error,
                                 const char *malformedMessage,
                                 const char *trueMessage) {
  CFTypeRef value = CMGetAttachment(sample, key, nullptr);
  if (value == nullptr) {
    return true;
  }
  if (CFGetTypeID(value) != CFBooleanGetTypeID()) {
    assignError(error, malformedMessage);
    return false;
  }
  if (CFBooleanGetValue(static_cast<CFBooleanRef>(value))) {
    assignError(error, trueMessage);
    return false;
  }
  return true;
}

[[nodiscard]] bool zeroTrimOrAbsent(CMSampleBufferRef sample, CFStringRef key,
                                    std::string *error) {
  CFTypeRef value = CMGetAttachment(sample, key, nullptr);
  if (value == nullptr) {
    return true;
  }
  if (CFGetTypeID(value) != CFDictionaryGetTypeID()) {
    assignError(error, "audio trim attachment is malformed");
    return false;
  }
  const CMTime trim =
      CMTimeMakeFromDictionary(static_cast<CFDictionaryRef>(value));
  const auto exactTrim = exactMediaTime(trim);
  if (!exactTrim || exactTrim->value != 0) {
    assignError(error, "nonzero audio trim is outside native v1");
    return false;
  }
  return true;
}

[[nodiscard]] bool normalSpeedOrAbsent(CMSampleBufferRef sample,
                                       std::string *error) {
  CFTypeRef value = CMGetAttachment(
      sample, kCMSampleBufferAttachmentKey_SpeedMultiplier, nullptr);
  if (value == nullptr) {
    return true;
  }
  if (CFGetTypeID(value) != CFNumberGetTypeID()) {
    assignError(error, "audio speed attachment is malformed");
    return false;
  }
  double speed = 0.0;
  if (!CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberDoubleType,
                        &speed) ||
      !std::isfinite(speed) || speed != 1.0) {
    assignError(error, "non-1.0 audio speed is outside native v1");
    return false;
  }
  return true;
}

[[nodiscard]] bool absentAttachment(CMSampleBufferRef sample, CFStringRef key,
                                    std::string *error, const char *message) {
  if (CMGetAttachment(sample, key, nullptr) == nullptr) {
    return true;
  }
  assignError(error, message);
  return false;
}

[[nodiscard]] bool immediatePlayoutFrame(CMSampleBufferRef sample,
                                         std::string *error) {
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(sample, false);
  if (attachments == nullptr || CFArrayGetCount(attachments) <= 0) {
    assignError(error,
                "accurate-seek audio lacks a decoder refresh attachment");
    return false;
  }
  auto first =
      static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
  if (first == nullptr || CFGetTypeID(first) != CFDictionaryGetTypeID()) {
    assignError(error, "audio decoder refresh attachment is malformed");
    return false;
  }
  CFTypeRef raw = CFDictionaryGetValue(
      first, kCMSampleAttachmentKey_AudioIndependentSampleDecoderRefreshCount);
  if (raw == nullptr || CFGetTypeID(raw) != CFNumberGetTypeID() ||
      CFNumberIsFloatType(static_cast<CFNumberRef>(raw))) {
    assignError(error,
                raw == nullptr
                    ? "accurate-seek audio is not an immediate playout frame"
                    : "audio decoder refresh attachment is malformed");
    return false;
  }
  std::int64_t refreshCount = -1;
  if (!CFNumberGetValue(static_cast<CFNumberRef>(raw), kCFNumberSInt64Type,
                        &refreshCount) ||
      refreshCount != 0) {
    assignError(error, "accurate-seek audio is not an immediate playout frame");
    return false;
  }
  return true;
}

[[nodiscard]] bool admissibleAttachments(CMSampleBufferRef sample,
                                         std::string *error) {
  return zeroTrimOrAbsent(
             sample, kCMSampleBufferAttachmentKey_TrimDurationAtStart, error) &&
         zeroTrimOrAbsent(
             sample, kCMSampleBufferAttachmentKey_TrimDurationAtEnd, error) &&
         normalSpeedOrAbsent(sample, error) &&
         falseOrAbsent(sample, kCMSampleBufferAttachmentKey_Reverse, error,
                       "audio reverse attachment is malformed",
                       "reverse audio is outside native v1") &&
         falseOrAbsent(
             sample,
             kCMSampleBufferAttachmentKey_FillDiscontinuitiesWithSilence, error,
             "audio silence-fill attachment is malformed",
             "semantic silence fill is outside native v1") &&
         falseOrAbsent(sample, kCMSampleBufferAttachmentKey_EmptyMedia, error,
                       "empty-media attachment is malformed",
                       "empty-media audio is outside converter ingress") &&
         falseOrAbsent(sample,
                       kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
                       error, "audio decoder-reset attachment is malformed",
                       "audio decoder reset is outside native v1") &&
         falseOrAbsent(sample, kCMSampleBufferAttachmentKey_DrainAfterDecoding,
                       error, "audio decoder-drain attachment is malformed",
                       "audio decoder drain is outside native v1") &&
         falseOrAbsent(sample, kCMSampleBufferAttachmentKey_PermanentEmptyMedia,
                       error, "permanent-empty attachment is malformed",
                       "permanent-empty audio is outside converter ingress") &&
         falseOrAbsent(sample,
                       kCMSampleBufferAttachmentKey_EndsPreviousSampleDuration,
                       error, "previous-duration attachment is malformed",
                       "deferred audio duration is outside native v1") &&
         absentAttachment(sample, kCMSampleBufferAttachmentKey_ResumeOutput,
                          error,
                          "audio resume semantics are outside native v1") &&
         absentAttachment(sample, kCMSampleBufferAttachmentKey_TransitionID,
                          error,
                          "audio transition semantics are outside native v1") &&
         absentAttachment(
             sample, kCMSampleBufferAttachmentKey_GradualDecoderRefresh, error,
             "gradual audio decoder refresh is outside native v1");
}

} // namespace

struct NativeAudioConverter::Impl {
  Impl(media::NativePcmRing &target,
       std::unique_ptr<NativeAudioConverterBackend> injected,
       NativeAudioBackendWake wake)
      : instance_identity(std::make_shared<const std::byte>(std::byte{})),
        ring(target),
        injected_backend(bool(injected)),
        backend_wake(wake),
        backend(std::move(injected)) {}

  // The committed input sample's three states. Ordering is not a ladder: a
  // generation cycles Idle -> Feeding -> AwaitingRelease -> Idle once per
  // sample. AwaitingRelease means the backend still borrows the encoded
  // storage, so it always implies a held lease -- which is why "released
  // storage the converter never handed over" is a single comparison and not a
  // pair of flags that could disagree.
  enum class InputPhase : std::uint8_t { Idle, Feeding, AwaitingRelease };

  bool fail(std::string *error, const char *message) noexcept {
    saturatingAdd(statistics.failures, 1);
    try {
      assignError(error, message);
    } catch (...) {
    }
    return false;
  }

  bool failPump(std::string *error, const char *message) noexcept {
    failed = true;
    return fail(error, message);
  }

  void closeBackend() noexcept {
    if (backend == nullptr) {
      return;
    }
    try {
      backend->close();
    } catch (...) {
    }
  }

  // A configure() that reached the backend and failed leaves no live
  // configuration behind.
  bool failConfigure(std::string *error, const char *message) noexcept {
    downmix = {};
    closeBackend();
    audio = {};
    track = 0;
    cookie_size = 0;
    sample_rate = 0;
    return fail(error, message);
  }

  void clearInputMetadata() noexcept {
    encoded_data = nullptr;
    encoded_size = 0;
    encoded_borrowed = false;
    packet_count = 0;
    next_packet = 0;
    prepared_frame_count = 0;
    prepared_start_frame = 0;
    prepared_end_frame = 0;
    prepared_accepted_frames = 0;
    prepared_presentation_time = {};
    prepared_decode_time = {};
    prepared_duration = {};
    prepared_key_frame = false;
    prepared_decode_only = false;
    prepared_discontinuity = false;
    prepared_decoded_audio_frames = 0;
  }

  void clearPreparedProof() noexcept {
    prepared = false;
    prepared_serial = 0;
    prepared_native_identity = nullptr;
  }

  void abandonPrepared() noexcept {
    clearPreparedProof();
    if (!lease) {
      clearInputMetadata();
    }
  }

  // The only place the lease is dropped, so it is also the only place the
  // input phase returns to Idle.
  void releaseSample() noexcept {
    lease.reset();
    input_phase = InputPhase::Idle;
    retained_payload_bytes = 0;
    clearInputMetadata();
  }

  void clearFlow() noexcept {
    releaseSample();
    clearPreparedProof();
    eof_requested = false;
    drained = false;
    staged_frames = 0;
    staged_start = 0;
  }

  void resetExactTimeline(NativeAudioGenerationTimeline value,
                          std::int64_t floorFrame,
                          std::int64_t ceilingFrame,
                          bool ceilingKnown) noexcept {
    timeline = value;
    presentation_floor_frame = floorFrame;
    presentation_ceiling_frame = ceilingFrame;
    has_presentation_ceiling = ceilingKnown;
    has_input_timeline = false;
    expected_input_frame = 0;
    decoded_cursor_frame = 0;
    accepted_pcm_frames = 0;
    aac = {};
    statistics.decodedPcmFrames = 0;
    statistics.discardedTrimFrames = 0;
    statistics.insertedSilenceFrames = 0;
    statistics.publishedPcmFrames = 0;
    statistics.presentationFloorFrame = floorFrame;
    statistics.firstPublishedFrame = 0;
    statistics.firstPublishedFrameKnown = false;
  }

  // How many frames the decoder NEVER emits, which is not the same question as
  // where its first emitted frame sits.
  //
  // For Opus, Vorbis, AC-3 and E-AC-3 the two coincide: the frames the decoder
  // swallows at the head are simply gone, so the generation decodes exactly
  // lead_in_frames fewer than its packets declare. MP3 separates them -- it
  // swallows 529 frames at the head and FLUSHES 529 at the end, so its output
  // is shifted by 529 while its COUNT is exactly what the packets declared.
  // Conflating the two would fail every MP3 file with "decoded audio exceeds its
  // exact accepted timeline budget".
  //
  // lead_in_frames keeps the positioning role (it is where the decoded cursor
  // starts); this is the counting one.
  [[nodiscard]] bool decodedWithinBudget(std::uint64_t decoded) const noexcept {
    return frame_deficit_frames <= accepted_pcm_frames &&
           decoded <= accepted_pcm_frames - frame_deficit_frames;
  }

  // At end of stream the decoder is normally exactly spent: it has emitted one
  // frame for every frame its packets declared, less the lead-in it swallowed.
  // Some codecs legitimately fall SHORT of that, by a bounded and stated amount:
  //
  //  * AC-3 and E-AC-3 hold a fixed 32 frames in flight and never flush them.
  //    Explicit post-drain AudioConverterFillComplexBuffer calls return zero
  //    frames, so those frames are unreachable rather than merely unrequested.
  //    The withheld audio is the encoder's silent MDCT
  //    ring-down, measured at -113 dBFS.
  //  * FLAC's FINAL frame is legitimately shorter than the stream's block
  //    size, so the last packet decodes to fewer frames than the constant grid
  //    declares. STREAMINFO states the exact total, which is where the track's
  //    duration comes from; the shortfall here is bounded by one block.
  //  * ALAC has FLAC's shape with a self-inflicted cause: the MP4 states the
  //    final packet's true length, and this player's own AAC end-trim
  //    restatement overwrites it with the full grid before the converter sees
  //    it, so the budget overstates the stream by up to one packet. Measured
  //    3,824 frames (86.7 ms) on a 4.000 s 44.1 kHz fixture whose last packet
  //    holds 272 of 4096. The decoder itself is exact -- it emits precisely the
  //    176,400 frames the container declares -- so this bound covers an
  //    accounting artefact, not a decoder that gives up early.
  //
  // This is a bound, not a licence to be approximate. What the generation
  // actually PUBLISHES is still governed exactly, by the presentation ceiling
  // the demuxer derives -- and for these codecs that ceiling was measured equal
  // to the decoder's own output frame for frame. The bound is zero for Opus,
  // Vorbis, AAC, MP3 and both ADPCM families, so their arithmetic is exact
  // equality -- ADPCM in particular decodes bit-exactly to its
  // declared frame count, so widening it there would hide a real defect.
  [[nodiscard]] bool decodedBudgetExhausted(
      std::uint64_t decoded) const noexcept {
    if (frame_deficit_frames > accepted_pcm_frames) {
      return false;
    }
    const std::uint64_t expected = accepted_pcm_frames - frame_deficit_frames;
    return decoded <= expected &&
           expected - decoded <= tail_shortfall_bound_frames;
  }

  // The fold for the roles the backend reports now; empty when it reports
  // none.
  [[nodiscard]] media::StereoDownmixMatrix reportedDownmix() noexcept {
    // Build the fold from the labels the backend itself reports, never from
    // an index convention: the four codecs measured here emit three different
    // 5.1 orders (AAC C L R Ls Rs LFE, AC-3/E-AC-3 L C R Ls Rs LFE, FLAC
    // L R C LFE Ls Rs), so index 1 is the centre for one family and the left
    // channel for another.
    std::array<media::AudioChannelRole, media::kMaximumDownmixSourceChannels>
        roles{};
    std::size_t roleCount = 0;
    bool reported = false;
    try {
      reported = backend->outputChannelRoles(roles, &roleCount);
    } catch (...) {
      reported = false;
    }
    return reported ? media::buildStereoDownmixMatrix({roles.data(), roleCount})
                    : media::StereoDownmixMatrix{};
  }

  // Installs the fold for a source of `channels`; false (and no fold) when the
  // backend's layout does not fold exactly that width.
  [[nodiscard]] bool buildDownmix(std::uint32_t channels) noexcept {
    downmix = reportedDownmix();
    if (!downmix.admitted() || downmix.sourceChannels != channels) {
      downmix = {};
      return false;
    }
    return true;
  }

  void failClosedProtocol() noexcept {
    saturatingAdd(statistics.failures, 1);
    closeBackend();
    clearFlow();
    configured = false;
    failed = true;
  }

  // True when a full slab decoded from here would land entirely before the
  // accurate-seek floor and therefore be discarded whole. Such a block must
  // not be held back by ring backpressure: it never reaches the ring, so
  // waiting for ring space would stall the seek forever.
  [[nodiscard]] bool nextBlockIsAllPreroll() const noexcept {
    std::int64_t blockEnd = 0;
    return timeline.trimBeforeFloor && has_input_timeline &&
           decoded_cursor_frame < presentation_floor_frame &&
           checkedFrameEnd(decoded_cursor_frame, kFramesPerPump, &blockEnd) &&
           blockEnd <= presentation_floor_frame;
  }

  // Projects one decoded block onto the generation's exact accepted timeline
  // without committing it. Both out-params are set for an empty block too, so
  // the caller can carry them forward unconditionally.
  [[nodiscard]] bool projectDecodedBlock(std::uint64_t producedFrames,
                                         std::uint64_t *decodedAfter,
                                         std::int64_t *cursorAfter)
      const noexcept {
    *decodedAfter = statistics.decodedPcmFrames;
    *cursorAfter = decoded_cursor_frame;
    if (producedFrames == 0) {
      return true;
    }
    return has_input_timeline &&
           checkedAdd(statistics.decodedPcmFrames, producedFrames,
                      decodedAfter) &&
           decodedWithinBudget(*decodedAfter) &&
           checkedFrameEnd(decoded_cursor_frame, producedFrames, cursorAfter);
  }

  // Everything a backend return value must satisfy before any part of it is
  // believed. The backend is an injectable virtual boundary, so this is a
  // check on an external contract and not on this converter's own state.
  [[nodiscard]] bool
  resultWithinContract(const NativeAudioBackendResult &converted,
                       std::size_t offeredPackets,
                       bool sendingEof) const noexcept {
    return !converted.failed && converted.consumedPackets <= offeredPackets &&
           converted.producedFrames <= kFramesPerPump &&
           (!converted.needsInput ||
            converted.consumedPackets == offeredPackets) &&
           (!converted.drained || sendingEof);
  }

  // The one end-of-stream seal. Every pump exit that reaches a drain goes
  // through it, and the exact budget identity is the same at all of them.
  [[nodiscard]] bool sealDrain(std::uint64_t decodedFrames,
                               std::string *error) noexcept {
    if (!decodedBudgetExhausted(decodedFrames)) {
      failPump(error, "audio backend drained before its exact timeline ended");
      return false;
    }
    drained = true;
    return true;
  }

  struct PcmTrimPlan {
    std::int64_t publishStart{0};
    std::uint64_t headDiscarded{0};
    std::uint64_t tailDiscarded{0};
    std::uint64_t publishFrames{0};
    std::uint64_t discardedTrimAfter{0};
  };

  // Head and tail trim for one decoded block. Pure: it commits nothing, so the
  // caller still owns the rule that frame accounting is final before the PCM
  // changes shape. Returns the refusing message, or nullptr when the plan
  // holds.
  [[nodiscard]] const char *planTrim(std::uint64_t producedFrames,
                                     std::int64_t cursorAfter,
                                     PcmTrimPlan *plan) const noexcept {
    std::uint64_t discarded = 0;
    if (timeline.trimBeforeFloor &&
        decoded_cursor_frame < presentation_floor_frame) {
      const std::int64_t discardEnd =
          std::min(cursorAfter, presentation_floor_frame);
      if (!frameDistance(decoded_cursor_frame, discardEnd, &discarded) ||
          discarded > producedFrames) {
        return "accurate-seek PCM trim is not frame-exact";
      }
    }
    std::int64_t publishStart = 0;
    if (!checkedFrameEnd(decoded_cursor_frame, discarded, &publishStart)) {
      return "generation-local PCM accounting overflowed";
    }
    // Mirror image of the head trim. The final packet of a constant-frame
    // codec always overruns the stream's exact end; those frames are decoded
    // (so the budget identity still holds) but never published.
    std::uint64_t tailDiscarded = 0;
    if (has_presentation_ceiling && cursorAfter > presentation_ceiling_frame) {
      const std::int64_t keepEnd =
          std::max(publishStart, presentation_ceiling_frame);
      if (!frameDistance(keepEnd, cursorAfter, &tailDiscarded) ||
          tailDiscarded > producedFrames - discarded) {
        return "end-of-stream PCM trim is not frame-exact";
      }
    }
    const std::uint64_t publishFrames =
        producedFrames - discarded - tailDiscarded;
    std::uint64_t trimmed = 0;
    std::uint64_t discardedAfter = 0;
    std::uint64_t publishedBefore = 0;
    std::uint64_t publishedAfter = 0;
    if (!checkedAdd(discarded, tailDiscarded, &trimmed) ||
        !checkedAdd(statistics.discardedTrimFrames, trimmed, &discardedAfter) ||
        !checkedAdd(statistics.publishedPcmFrames, staged_frames,
                    &publishedBefore) ||
        !checkedAdd(publishedBefore, publishFrames, &publishedAfter)) {
      return "generation-local PCM accounting overflowed";
    }
    plan->publishStart = publishStart;
    plan->headDiscarded = discarded;
    plan->tailDiscarded = tailDiscarded;
    plan->publishFrames = publishFrames;
    plan->discardedTrimAfter = discardedAfter;
    return nullptr;
  }

  // A backend that returns without consuming, producing, releasing, asking or
  // draining has stalled the generation. Every input to that verdict is named
  // in the message because the combination, not any one flag, is the defect.
  void describeStall(const NativeAudioBackendResult &converted, bool sendingEof,
                     bool hasInput, std::string *error) noexcept {
    char detail[256];
    std::snprintf(detail, sizeof(detail),
                  "native audio backend made no bounded progress "
                  "[produced=%llu consumed=%llu needsInput=%d finalRel=%d "
                  "drained=%d sendingEof=%d hasInput=%d eofReq=%d await=%d "
                  "next=%llu count=%llu decoded=%llu accepted=%llu "
                  "deficit=%u lead=%u]",
                  (unsigned long long)converted.producedFrames,
                  (unsigned long long)converted.consumedPackets,
                  converted.needsInput ? 1 : 0,
                  converted.finalInputReleased ? 1 : 0,
                  converted.drained ? 1 : 0, sendingEof ? 1 : 0,
                  hasInput ? 1 : 0, eof_requested ? 1 : 0,
                  input_phase == InputPhase::AwaitingRelease ? 1 : 0,
                  (unsigned long long)next_packet,
                  (unsigned long long)packet_count,
                  (unsigned long long)statistics.decodedPcmFrames,
                  (unsigned long long)accepted_pcm_frames,
                  frame_deficit_frames, lead_in_frames);
    failPump(error, detail);
  }

  [[nodiscard]] bool formatMatches(CMSampleBufferRef sample) const noexcept {
    CMFormatDescriptionRef raw = CMSampleBufferGetFormatDescription(sample);
    if (raw == nullptr ||
        CMFormatDescriptionGetMediaType(raw) != kCMMediaType_Audio) {
      return false;
    }
    auto format = static_cast<CMAudioFormatDescriptionRef>(raw);
    const AudioStreamBasicDescription *asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(format);
    if (asbd == nullptr || asbd->mSampleRate != audio.sampleRate ||
        asbd->mFormatID != audio.formatTag ||
        asbd->mFormatFlags != audio.formatFlags ||
        asbd->mBytesPerPacket != audio.bytesPerPacket ||
        asbd->mFramesPerPacket !=
            (audio.variableFramesPerPacket ? 0U : audio.framesPerPacket) ||
        asbd->mBytesPerFrame != audio.bytesPerFrame ||
        asbd->mChannelsPerFrame != audio.channels ||
        asbd->mBitsPerChannel != audio.bitsPerChannel) {
      return false;
    }
    std::size_t cookieLength = 0;
    const void *cookie =
        CMAudioFormatDescriptionGetMagicCookie(format, &cookieLength);
    if (cookieLength != cookie_size ||
        (cookieLength != 0 &&
         (cookie == nullptr ||
          std::memcmp(cookie, cookie_storage.data(), cookieLength) != 0))) {
      return false;
    }
    std::size_t layoutSize = 0;
    const AudioChannelLayout *layout =
        CMAudioFormatDescriptionGetChannelLayout(format, &layoutSize);
    ChannelLayoutIdentity layoutIdentity;
    return readSupportedChannelLayout(layout, layoutSize, audio.channels,
                                      &layoutIdentity) &&
           layoutIdentity.present == audio.channelLayoutPresent &&
           layoutIdentity.tag == audio.channelLayoutTag;
  }

  [[nodiscard]] bool loadPacketDescriptions(CMSampleBufferRef sample,
                                            std::size_t sampleCount,
                                            std::size_t byteCount,
                                            std::uint64_t *totalFrames,
                                            std::string *error) noexcept {
    std::uint64_t frameTotal = 0;
    const auto recordFrames = [&](std::size_t index,
                                  std::uint32_t variableFrames) noexcept {
      const std::uint32_t frames =
          aac.piecewise ? kAacFrames : variableFrames != 0 ? variableFrames : audio.framesPerPacket;
      std::uint64_t nextTotal = 0;
      if (frames == 0 || !checkedAdd(frameTotal, frames, &nextTotal) ||
          (audio.variableFramesPerPacket &&
           (variableFrames == 0 || variableFrames > audio.framesPerPacket))) {
        return false;
      }
      packet_frames[index] = frames;
      frameTotal = nextTotal;
      return true;
    };
    const AudioStreamPacketDescription *source = nullptr;
    std::size_t sourceBytes = 0;
    const OSStatus status = CMSampleBufferGetAudioStreamPacketDescriptionsPtr(
        sample, &source, &sourceBytes);
    if (status != noErr) {
      return fail(error, "CoreMedia packet descriptions are unavailable");
    }
    if (source == nullptr && sourceBytes == 0) {
      if (audio.bytesPerPacket == 0 ||
          sampleCount > byteCount / audio.bytesPerPacket ||
          sampleCount * audio.bytesPerPacket != byteCount) {
        return fail(error,
                    "variable compressed audio requires packet descriptions");
      }
      for (std::size_t index = 0; index < sampleCount; ++index) {
        packets[index] = {
            static_cast<std::int64_t>(index * audio.bytesPerPacket),
            audio.bytesPerPacket, 0};
        if (!recordFrames(index, 0)) {
          return fail(error, "audio packet frame count is not exact");
        }
      }
      packet_count = sampleCount;
      *totalFrames = frameTotal;
      return true;
    }
    if (source == nullptr ||
        sourceBytes != sampleCount * sizeof(AudioStreamPacketDescription)) {
      return fail(error, "audio packet description count is not exact");
    }
    std::uint64_t priorEnd = 0;
    for (std::size_t index = 0; index < sampleCount; ++index) {
      const auto &packet = source[index];
      if (packet.mStartOffset < 0 || packet.mDataByteSize == 0) {
        return fail(error, "audio packet description is malformed");
      }
      const std::uint64_t start =
          static_cast<std::uint64_t>(packet.mStartOffset);
      if (start < priorEnd || start > byteCount ||
          packet.mDataByteSize > byteCount - start) {
        return fail(error, "audio packet description exceeds its payload");
      }
      packets[index] = {packet.mStartOffset, packet.mDataByteSize,
                        packet.mVariableFramesInPacket};
      if (!recordFrames(index, packet.mVariableFramesInPacket)) {
        return fail(error, "audio packet frame count is not exact");
      }
      priorEnd = start + packet.mDataByteSize;
    }
    packet_count = sampleCount;
    *totalFrames = frameTotal;
    return true;
  }

  [[nodiscard]] bool
  timingAt(const std::array<CMSampleTimingInfo,
                            NativeAudioConverter::kMaximumPackets> &entries,
           std::size_t entryCount, std::size_t index, std::uint64_t priorFrames,
           std::int64_t *presentation, std::optional<std::int64_t> *decode,
           std::uint64_t *durationFrames, std::string *error) noexcept {
    const CMSampleTimingInfo &timing = entries[entryCount == 1 ? 0 : index];
    std::int64_t duration = 0;
    std::int64_t basePresentation = 0;
    std::optional<std::int64_t> baseDecode;
    if (!exactFrame(timing.duration, sample_rate, &duration) || duration <= 0 ||
        !exactFrame(timing.presentationTimeStamp, sample_rate,
                    &basePresentation) ||
        !optionalFrame(timing.decodeTimeStamp, sample_rate, &baseDecode)) {
      assignError(error, "CoreMedia audio timing is not frame-exact");
      return false;
    }
    *durationFrames = static_cast<std::uint64_t>(duration);
    if (entryCount != 1) {
      *presentation = basePresentation;
      *decode = baseDecode;
      return true;
    }
    if (!checkedFrameEnd(basePresentation, priorFrames, presentation)) {
      assignError(error, "CoreMedia audio timing overflows its frame range");
      return false;
    }
    if (!baseDecode) {
      decode->reset();
      return true;
    }
    std::int64_t expandedDecode = 0;
    if (!checkedFrameEnd(*baseDecode, priorFrames, &expandedDecode)) {
      assignError(error,
                  "CoreMedia audio decode timing overflows its frame range");
      return false;
    }
    *decode = expandedDecode;
    return true;
  }

  [[nodiscard]] bool validateTiming(CMSampleBufferRef sample,
                                    const media::MediaSample &neutral,
                                    std::uint64_t totalFrames,
                                    std::int64_t *sampleStart,
                                    std::string *error) noexcept {
    CMItemCount inputCount = 0;
    CMItemCount outputCount = 0;
    const auto capacity = static_cast<CMItemCount>(input_timing.size());
    if (CMSampleBufferGetSampleTimingInfoArray(
            sample, capacity, input_timing.data(), &inputCount) != noErr ||
        CMSampleBufferGetOutputSampleTimingInfoArray(
            sample, capacity, output_timing.data(), &outputCount) != noErr ||
        (inputCount != 1 && inputCount != neutral.sampleCount) ||
        (outputCount != 1 && outputCount != neutral.sampleCount)) {
      assignError(error,
                  "CoreMedia audio sample timing is unavailable or unbounded");
      return false;
    }

    std::uint64_t priorFrames = 0;
    std::int64_t expectedPresentation = 0;
    std::optional<std::int64_t> firstDecode;
    for (std::size_t index = 0; index < neutral.sampleCount; ++index) {
      std::int64_t inputPresentation = 0;
      std::int64_t outputPresentation = 0;
      std::optional<std::int64_t> inputDecode;
      std::optional<std::int64_t> outputDecode;
      std::uint64_t inputDuration = 0;
      std::uint64_t outputDuration = 0;
      if (!timingAt(input_timing, static_cast<std::size_t>(inputCount), index,
                    priorFrames, &inputPresentation, &inputDecode,
                    &inputDuration, error) ||
          !timingAt(output_timing, static_cast<std::size_t>(outputCount), index,
                    priorFrames, &outputPresentation, &outputDecode,
                    &outputDuration, error) ||
          (!aac.piecewise && inputDuration != packet_frames[index]) ||
          outputDuration != inputDuration ||
          inputPresentation != outputPresentation ||
          inputDecode != outputDecode ||
          (inputDecode && *inputDecode != inputPresentation)) {
        if (error != nullptr && error->empty()) {
          assignError(error,
                      "CoreMediaAudioEditExactTimelineProofMissing: input/output timing contains an edit");
        }
        return false;
      }
      if (index == 0) {
        *sampleStart = inputPresentation;
        expectedPresentation = inputPresentation;
        firstDecode = inputDecode;
      }
      if (inputPresentation != expectedPresentation ||
          !checkedFrameEnd(expectedPresentation, aac.piecewise ? inputDuration : packet_frames[index],
                           &expectedPresentation)) {
        assignError(error, "CoreMedia audio packets are not contiguous");
        return false;
      }
      if (aac.piecewise) {
        aac.prepared[index] = {inputPresentation,inputDuration};
      }
      priorFrames += packet_frames[index];
    }
    if (priorFrames != totalFrames) {
      assignError(error, "CoreMedia audio packet duration is inconsistent");
      return false;
    }

    std::int64_t neutralPresentation = 0;
    std::int64_t neutralDuration = 0;
    std::optional<std::int64_t> neutralDecode;
    if (!exactFrame(neutral.presentationTime, sample_rate,
                    &neutralPresentation) ||
        !exactFrame(neutral.duration, sample_rate, &neutralDuration) ||
        neutralDuration <= 0 ||
        static_cast<std::uint64_t>(neutralDuration) != (aac.piecewise ?
            static_cast<std::uint64_t>(expectedPresentation-*sampleStart) : totalFrames)) {
      assignError(error, "neutral audio timing is not frame-exact");
      return false;
    }
    if (neutral.decodeTime.valid()) {
      std::int64_t value = 0;
      if (!exactFrame(neutral.decodeTime, sample_rate, &value)) {
        assignError(error, "neutral audio decode time is not frame-exact");
        return false;
      }
      neutralDecode = value;
    } else if (neutral.decodeTime.value != 0 ||
               neutral.decodeTime.timescale != 0) {
      assignError(error, "neutral audio decode time is malformed");
      return false;
    }

    std::int64_t aggregatePresentation = 0;
    std::int64_t outputPresentation = 0;
    std::int64_t aggregateDuration = 0;
    std::int64_t outputDuration = 0;
    std::optional<std::int64_t> aggregateDecode;
    std::optional<std::int64_t> outputDecode;
    if (!exactFrame(CMSampleBufferGetPresentationTimeStamp(sample), sample_rate,
                    &aggregatePresentation) ||
        !exactFrame(CMSampleBufferGetOutputPresentationTimeStamp(sample),
                    sample_rate, &outputPresentation) ||
        !exactFrame(CMSampleBufferGetDuration(sample), sample_rate,
                    &aggregateDuration) ||
        !exactFrame(CMSampleBufferGetOutputDuration(sample), sample_rate,
                    &outputDuration) ||
        !optionalFrame(CMSampleBufferGetDecodeTimeStamp(sample), sample_rate,
                       &aggregateDecode) ||
        !optionalFrame(CMSampleBufferGetOutputDecodeTimeStamp(sample),
                       sample_rate, &outputDecode) ||
        aggregatePresentation != *sampleStart ||
        outputPresentation != *sampleStart || aggregateDuration <= 0 ||
        outputDuration != aggregateDuration ||
        aggregateDuration != neutralDuration ||
        aggregateDecode != firstDecode || outputDecode != firstDecode ||
        neutralPresentation != *sampleStart || neutralDecode != firstDecode) {
      assignError(error,
                  "CoreMedia and neutral audio timelines are not identical");
      return false;
    }
    return true;
  }

  // One source-proved presentation extent of an AAC access unit.
  struct AacEdit {
    std::int64_t start{};
    std::uint64_t duration{};
  };
  // The AAC piecewise timeline. A source that proves AAC packet extents from
  // the container's edit list (MediaSample::aacPiecewiseTimeline)
  // states each packet's presentation extent, which may be shorter or longer
  // than the packet's kAacFrames decoded frames; the extents of committed
  // samples queue here until their decoded frames are published.
  struct AacTimeline {
    bool piecewise{};
    // The extents of the prepared, not yet committed, sample.
    std::array<AacEdit, NativeAudioConverter::kMaximumPackets> prepared{};
    // Committed extents, a ring of `size` entries starting at `head`.
    std::array<AacEdit, NativeAudioConverter::kMaximumPackets * 2> edits{};
    std::size_t head{}, size{};
    // Progress through the front extent: decoded frames consumed, then
    // declared-silence frames emitted past kAacFrames.
    std::uint64_t decodedOffset{}, silenceOffset{};
    // The decoded block in pcm[] waiting to be mapped onto extents.
    std::size_t pendingCount{}, pendingOffset{};

    [[nodiscard]] std::size_t room() const noexcept {
      return edits.size() - size;
    }
    void commit(std::size_t count) noexcept {
      for (std::size_t i = 0; i < count; ++i) {
        edits[(head + size) % edits.size()] = prepared[i];
        ++size;
      }
    }
    void popFront() noexcept {
      head = (head + 1) % edits.size();
      --size;
      decodedOffset = silenceOffset = 0;
    }
  };
  AacTimeline aac{};
  // Decoded stereo PCM waiting to fill one ring slab. The ring counts its
  // occupancy in slabs, and the output's headroom proof
  // (NativePcmRing::kMinimumFramesPerPublishedSlab) holds only if every slab
  // but a generation's last carries at least that many frames -- which one
  // codec packet per input sample (Opus, Vorbis, FLAC on Matroska or
  // libavformat; an AAC edit extent) does not. So short blocks are coalesced
  // here first. Before an append the staging holds fewer than the floor, and an
  // append is at most one pump's block, so it always fits.
  std::array<float, 2 * NativeAudioConverter::kFramesPerPump *
                        media::NativePcmRing::kChannels>
      staged{};
  std::uint64_t staged_frames{0};
  // Generation-local frame of staged[0]. Staged frames are contiguous: each
  // append starts where the previous one ended.
  std::int64_t staged_start{0};

  void stage(std::int64_t start, const float *frames, std::uint64_t count) noexcept {
    if (staged_frames == 0) {
      staged_start = start;
    }
    float *destination = staged.data() + staged_frames * media::NativePcmRing::kChannels;
    if (frames == nullptr) {
      std::fill_n(destination, count * media::NativePcmRing::kChannels, 0.0f);
    } else {
      std::copy_n(frames, count * media::NativePcmRing::kChannels, destination);
    }
    staged_frames += count;
  }

  // Publishes one slab from staging once it holds the floor, or whatever it
  // holds once `final` says no later frame will join it. Empty when nothing
  // was due.
  [[nodiscard]] std::optional<NativeAudioPumpResult>
  publishStaged(bool final, std::string *error) noexcept {
    if (staged_frames == 0 ||
        (!final && staged_frames < media::NativePcmRing::kMinimumFramesPerPublishedSlab)) {
      return std::nullopt;
    }
    if (ring.queuedSlabs() >= media::NativePcmRing::kSlabCount) {
      saturatingAdd(statistics.ringBackpressure, 1);
      return NativeAudioPumpResult::Backpressure;
    }
    const std::uint64_t frames =
        std::min<std::uint64_t>(staged_frames, media::NativePcmRing::kFramesPerSlab);
    const auto published = ring.publish(
        statistics.generation,
        std::span<const float>(staged.data(), frames * media::NativePcmRing::kChannels),
        frames);
    if (published == media::NativePcmRing::PublishResult::StaleGeneration) {
      return NativeAudioPumpResult::StaleGeneration;
    }
    if (published != media::NativePcmRing::PublishResult::Published) {
      failPump(error, published == media::NativePcmRing::PublishResult::Full
                          ? "ring became full after converter preflight"
                          : "native PCM ring rejected decoded audio");
      return NativeAudioPumpResult::Failed;
    }
    if (!statistics.firstPublishedFrameKnown) {
      statistics.firstPublishedFrame = staged_start;
      statistics.firstPublishedFrameKnown = true;
    }
    saturatingAdd(statistics.publishedPcmFrames, frames);
    saturatingAdd(statistics.publishedSlabs, 1);
    std::copy(staged.begin() + static_cast<std::ptrdiff_t>(frames * media::NativePcmRing::kChannels),
              staged.begin() + static_cast<std::ptrdiff_t>(staged_frames * media::NativePcmRing::kChannels),
              staged.begin());
    staged_frames -= frames;
    staged_start += static_cast<std::int64_t>(frames);
    return NativeAudioPumpResult::Published;
  }

  // True once the staged frames reach the presentation ceiling, after which
  // the generation publishes nothing more.
  [[nodiscard]] bool stagedReachesCeiling() const noexcept {
    return has_presentation_ceiling && staged_frames != 0 &&
           staged_start + static_cast<std::int64_t>(staged_frames) >=
               presentation_ceiling_frame;
  }

  // Decode accounting stays on the natural 1024-frame grid. This bounded
  // queue maps those frames onto the source-proved presentation extents:
  // short extents trim the packet tail; long extents append exact silence.
  NativeAudioPumpResult publishAac(std::string *error) {
    while (true) {
      if (const auto result = publishStaged(
              (drained && aac.size == 0) || stagedReachesCeiling(), error)) {
        return *result;
      }
      if (aac.size == 0) {
        return NativeAudioPumpResult::Progress;
      }
      const AacEdit &edit = aac.edits[aac.head];
      const bool decodedDone = aac.decodedOffset == kAacFrames;
      const bool silence = decodedDone && edit.duration > kAacFrames;
      if (decodedDone &&
          (!silence || aac.silenceOffset == edit.duration - kAacFrames)) {
        aac.popFront();
        continue;
      }
      if (!silence && aac.pendingOffset == aac.pendingCount) {
        return NativeAudioPumpResult::Progress;
      }
      const std::uint64_t offset =
          silence ? kAacFrames + aac.silenceOffset : aac.decodedOffset;
      const std::int64_t start = edit.start + static_cast<std::int64_t>(offset);
      std::uint64_t n =
          silence ? std::min<std::uint64_t>(NativeAudioConverter::kFramesPerPump,
                                            edit.duration - offset)
                  : std::min<std::uint64_t>(kAacFrames - aac.decodedOffset,
                                            aac.pendingCount - aac.pendingOffset);
      // Skipping an hour of declared silence on a seek is arithmetic, not
      // an hour's worth of zero slabs or an unbounded pump loop.
      if (silence && start < presentation_floor_frame) {
        n = std::min(edit.duration - offset,
                     static_cast<std::uint64_t>(presentation_floor_frame - start));
      }
      if (silence && has_presentation_ceiling &&
          start >= presentation_ceiling_frame) {
        n = edit.duration - offset;
      }
      // A short extent keeps only its head; the rest of the packet is trimmed.
      const std::uint64_t kept =
          silence ? n
                  : std::min(n, edit.duration > offset ? edit.duration - offset
                                                       : 0);
      const std::int64_t low = std::max(start, presentation_floor_frame);
      const std::int64_t high =
          std::min(start + static_cast<std::int64_t>(kept),
                   has_presentation_ceiling ? presentation_ceiling_frame
                                            : INT64_MAX);
      const std::uint64_t count =
          high > low ? static_cast<std::uint64_t>(high - low) : 0;
      if (count != 0) {
        stage(low,
              silence ? nullptr
                      : pcm.data() + (aac.pendingOffset +
                                      static_cast<std::size_t>(low - start)) *
                                         media::NativePcmRing::kChannels,
              count);
        if (silence) {
          saturatingAdd(statistics.insertedSilenceFrames, count);
        }
      }
      if (silence) {
        aac.silenceOffset += n;
      } else {
        aac.decodedOffset += n;
        aac.pendingOffset += n;
        saturatingAdd(statistics.discardedTrimFrames, n - count);
      }
    }
  }

  std::shared_ptr<const void> instance_identity;
  media::NativePcmRing &ring;
  const bool injected_backend;
  const NativeAudioBackendWake backend_wake;
  // Empty until the first configure() of a converter without an injected
  // backend.
  std::unique_ptr<NativeAudioConverterBackend> backend;
  NativeAudioBackendCapabilities capabilities{};
  std::array<std::byte, NativeAudioConverter::kMaximumEncodedBytes>
      encoded_storage{};
  std::array<NativeAudioPacketDescription,
             NativeAudioConverter::kMaximumPackets>
      packets{};
  std::array<std::uint32_t, NativeAudioConverter::kMaximumPackets>
      packet_frames{};
  std::array<CMSampleTimingInfo, NativeAudioConverter::kMaximumPackets>
      input_timing{};
  std::array<CMSampleTimingInfo, NativeAudioConverter::kMaximumPackets>
      output_timing{};
  std::array<std::byte,
             media::MediaSourceLimits::kHardMaximumCodecConfigurationBytes>
      cookie_storage{};
  // One fixed slab, at the widest source layout the player admits. The
  // backend decodes the FULL native layout into it and the downmix folds it
  // to stereo in place before publication, so the same storage serves both
  // ends and nothing allocates after configuration. Sizing this at
  // kMaximumDownmixSourceChannels rather than NativePcmRing::kChannels costs
  // 96 KiB per converter (32,768 floats instead of 8,192).
  std::array<float, NativeAudioConverter::kFramesPerPump *
                        media::kMaximumDownmixSourceChannels>
      pcm{};
  // Empty and inert for every mono and stereo generation: those never enter
  // the fold at all.
  media::StereoDownmixMatrix downmix{};
  media::MediaPayloadLease lease;
  const std::byte *encoded_data{nullptr};
  media::MediaAudioFormat audio{};
  media::MediaTime prepared_presentation_time{};
  media::MediaTime prepared_decode_time{};
  media::MediaTime prepared_duration{};
  NativeAudioGenerationTimeline timeline{};
  NativeAudioConverterStats statistics{};
  media::MediaTrackId track{0};
  std::size_t cookie_size{0};
  std::size_t encoded_size{0};
  std::size_t retained_payload_bytes{0};
  std::size_t peak_retained_payload_bytes{0};
  std::size_t packet_count{0};
  std::size_t next_packet{0};
  std::uint32_t sample_rate{0};
  std::uint64_t next_prepare_serial{1};
  std::uint64_t prepared_serial{0};
  const void *prepared_native_identity{nullptr};
  std::uint64_t prepared_frame_count{0};
  std::uint64_t prepared_accepted_frames{0};
  std::uint64_t accepted_pcm_frames{0};
  std::int64_t presentation_floor_frame{0};
  std::int64_t expected_input_frame{0};
  std::int64_t decoded_cursor_frame{0};
  std::int64_t prepared_start_frame{0};
  std::int64_t prepared_end_frame{0};
  std::int64_t presentation_ceiling_frame{0};
  std::uint32_t lead_in_frames{0};
  bool lead_in_is_first_packet{false};
  // See decodedWithinBudget: the frames the decoder never emits, which equals
  // lead_in_frames for every codec except MP3.
  std::uint32_t frame_deficit_frames{0};
  // See decodedBudgetExhausted. Zero for every codec whose decoder is exactly
  // spent at end of stream, which is all of them but AC-3, E-AC-3, FLAC and
  // ALAC.
  std::uint32_t tail_shortfall_bound_frames{0};
  bool has_presentation_ceiling{false};
  bool encoded_borrowed{false};
  bool configured{false};
  bool cancelled{false};
  bool failed{false};
  bool prepared{false};
  bool prepared_key_frame{false};
  bool prepared_decode_only{false};
  bool prepared_discontinuity{false};
  std::uint32_t prepared_decoded_audio_frames{0};
  bool has_input_timeline{false};
  InputPhase input_phase{InputPhase::Idle};
  bool eof_requested{false};
  bool drained{false};
};

NativeAudioConverter::NativeAudioConverter(
    media::NativePcmRing &ring, std::unique_ptr<NativeAudioConverterBackend> backend,
    NativeAudioBackendWake wake)
    : impl_(std::make_unique<Impl>(ring, std::move(backend), wake)) {}

NativeAudioConverter::~NativeAudioConverter() { close(); }

namespace {

// Resolves the tail-trim ceiling to an exact frame index. A generation that
// declares a ceiling it cannot express exactly is refused rather than trimmed
// approximately.
[[nodiscard]] bool resolveCeiling(const NativeAudioGenerationTimeline &timeline,
                                  std::uint32_t sampleRate,
                                  std::int64_t floorFrame,
                                  std::int64_t *ceilingFrame,
                                  bool *ceilingKnown) noexcept {
  if (!timeline.trimAfterCeiling) {
    *ceilingFrame = 0;
    *ceilingKnown = false;
    return true;
  }
  std::int64_t frame = 0;
  if (!exactFrame(timeline.presentationCeiling, sampleRate, &frame) ||
      frame < floorFrame) {
    return false;
  }
  *ceilingFrame = frame;
  *ceilingKnown = true;
  return true;
}

} // namespace

bool NativeAudioConverter::configure(const media::MediaTrackDescriptor &track,
                                     media::MediaGeneration generation,
                                     std::string *error) {
  return configure(track, generation, NativeAudioGenerationTimeline{}, error);
}

bool NativeAudioConverter::configure(const media::MediaTrackDescriptor &track,
                                     media::MediaGeneration generation,
                                     NativeAudioGenerationTimeline timeline,
                                     std::string *error) {
  auto &state = *impl_;
#if !defined(WAM_ENABLE_AVCODEC_STAGE)
  if (media::softwareAudioCodec(track.codec)) {
    return state.fail(error, "SoftwareAudioStageNotBuilt");
  }
#endif
  const std::optional<AdmittedAudio> admitted = admitAudioTrack(track);
  const std::uint32_t candidateSampleRate = admitted ? admitted->sampleRate : 0;
  std::int64_t candidateFloorFrame = 0;
  std::int64_t candidateCeilingFrame = 0;
  bool candidateCeilingKnown = false;
  if (generation == 0 || state.ring.generation() != generation || !admitted ||
      !exactFrame(timeline.presentationFloor, candidateSampleRate,
                  &candidateFloorFrame) ||
      !resolveCeiling(timeline, candidateSampleRate, candidateFloorFrame,
                      &candidateCeilingFrame, &candidateCeilingKnown)) {
    return state.fail(error, "audio track is outside native converter v1");
  }
  state.closeBackend();
  if (!state.injected_backend) {
    state.backend =
        makeNativeAudioConverterBackend(track.codec, state.backend_wake);
    if (state.backend == nullptr) {
      return state.fail(error, "SoftwareAudioStageNotBuilt");
    }
  }
  state.capabilities = state.backend->capabilities();
  state.clearFlow();
  state.configured = false;
  state.cancelled = false;
  state.failed = false;
  state.downmix = {};
  // The backend is asked for the source's OWN width. Asking it for stereo
  // instead yields Apple's normalised Lt/Rt matrix for AC-3 and silently
  // drops centre/LFE/surrounds for FLAC; the fold happens here,
  // after a complete decode, or not at all.
  NativeAudioBackendConfiguration configuration;
  configuration.codec = track.codec;
  configuration.input = *track.audio;
  configuration.codecConfiguration = track.codecConfiguration;
  configuration.outputChannels = track.audio->channels;
  configuration.outputSampleRate = candidateSampleRate;
  bool backendConfigured = false;
  try {
    backendConfigured = state.backend->configure(configuration, error);
  } catch (...) {
    return state.failConfigure(error,
                               "native audio backend configuration threw");
  }
  if (!backendConfigured) {
    const char *refusal = state.backend->failureReason();
    return state.failConfigure(
        error, refusal ? refusal : "native audio backend configuration failed");
  }
  if (state.capabilities.channelRolesAtConfigure &&
      track.audio->channels > media::NativePcmRing::kChannels &&
      !state.buildDownmix(track.audio->channels)) {
    return state.failConfigure(
        error, "multichannel audio layout is outside native converter v1");
  }
  state.audio = *track.audio;
  state.track = track.id;
  // Only an AudioToolbox magic cookie is restated by every CoreMedia sample's
  // format description; formatMatches() compares against it.
  state.cookie_size = track.codecConfigurationKind ==
                              media::MediaCodecConfigurationKind::AudioMagicCookie
                          ? track.codecConfiguration.size()
                          : 0;
  state.sample_rate = candidateSampleRate;
  std::copy(track.codecConfiguration.begin(), track.codecConfiguration.end(),
            state.cookie_storage.begin());
  state.configured = true;
  state.failed = false;
  state.statistics = {};
  state.peak_retained_payload_bytes = state.retained_payload_bytes;
  state.statistics.generation = generation;
  state.statistics.sampleRate = state.sample_rate;
  state.statistics.sourceChannels = state.audio.channels;
  state.statistics.downmixApplied = state.downmix.admitted();
  state.lead_in_frames =
      decoderLeadInFrames(track.codec, state.audio.framesPerPacket);
  state.lead_in_is_first_packet =
      media::mediaCodecFacts(track.codec).decoderLeadInIsOnePacket;
  state.frame_deficit_frames =
      decoderFrameDeficitFrames(track.codec, state.audio.framesPerPacket);
  state.tail_shortfall_bound_frames =
      decoderTailShortfallBoundFrames(track.codec, state.audio.framesPerPacket);
  state.resetExactTimeline(timeline, candidateFloorFrame, candidateCeilingFrame,
                           candidateCeilingKnown);
  return true;
}

NativeAudioPrepareOutcome
NativeAudioConverter::prepare(const media::MediaSample &sample,
                              std::string *error) {
  NativeAudioPrepareOutcome outcome;
  auto &state = *impl_;
  if (!state.configured || state.cancelled || state.failed) {
    state.fail(error, "native audio converter is not accepting samples");
    outcome.result = NativeAudioSubmitResult::Failed;
    return outcome;
  }
  if (sample.generation != state.statistics.generation) {
    saturatingAdd(state.statistics.staleSamples, 1);
    outcome.result = NativeAudioSubmitResult::StaleGeneration;
    return outcome;
  }
  if (state.lease || state.prepared) {
    saturatingAdd(state.statistics.backpressuredSamples, 1);
    outcome.result = NativeAudioSubmitResult::Backpressure;
    return outcome;
  }
  if (state.eof_requested || state.drained || sample.track != state.track ||
      sample.kind != media::MediaSampleKind::EncodedAudio ||
      sample.discontinuity || sample.sampleCount == 0 ||
      sample.sampleCount > kMaximumPackets || !sample.payload ||
      sample.payload.byteSize() == 0 ||
      sample.payload.byteSize() > kMaximumEncodedBytes) {
    saturatingAdd(state.statistics.rejectedSamples, 1);
    assignError(error, "encoded audio sample is outside native v1");
    outcome.result = NativeAudioSubmitResult::Invalid;
    return outcome;
  }
  const auto borrowed =
      sample.payload
          .borrowNative<media::NativePayloadKind::CoreMediaSampleBuffer>();
  if (!borrowed) {
    saturatingAdd(state.statistics.rejectedSamples, 1);
    assignError(error, "native audio requires a CoreMedia sample lease");
    outcome.result = NativeAudioSubmitResult::Invalid;
    return outcome;
  }
  auto nativeSample = static_cast<CMSampleBufferRef>(
      const_cast<void *>(borrowed->opaqueAddress()));
  const CMItemCount nativeCount = CMSampleBufferGetNumSamples(nativeSample);
  if (!CMSampleBufferDataIsReady(nativeSample) || nativeCount <= 0 ||
      static_cast<std::uint64_t>(nativeCount) != sample.sampleCount ||
      !state.formatMatches(nativeSample) ||
      !admissibleAttachments(nativeSample, error)) {
    saturatingAdd(state.statistics.rejectedSamples, 1);
    if (error != nullptr && error->empty()) {
      assignError(error, "CoreMedia audio metadata does not match its track");
    }
    outcome.result = NativeAudioSubmitResult::Invalid;
    return outcome;
  }
  const bool piecewise = state.audio.formatTag == kAudioFormatMPEG4AAC &&
      sample.aacPiecewiseTimeline;
  if ((state.has_input_timeline && piecewise != state.aac.piecewise) ||
      (piecewise && sample.sampleCount > state.aac.room())) {
    assignError(error,"AAC piecewise mapping capacity or identity mismatch");
    outcome.result = NativeAudioSubmitResult::Invalid;
    return outcome;
  }
  state.aac.piecewise = piecewise;
  const std::size_t byteCount = sample.payload.byteSize();
  std::uint64_t totalFrames = 0;
  std::int64_t sampleStart = 0;
  std::int64_t sampleEnd = 0;
  if (!state.loadPacketDescriptions(nativeSample, sample.sampleCount, byteCount,
                                    &totalFrames, error) ||
      !state.validateTiming(nativeSample, sample, totalFrames, &sampleStart,
                            error) ||
      !checkedFrameEnd(sampleStart, state.aac.piecewise ?
          static_cast<std::uint64_t>(state.aac.prepared[sample.sampleCount-1].start - sampleStart +
          static_cast<std::int64_t>(state.aac.prepared[sample.sampleCount-1].duration)) : totalFrames, &sampleEnd)) {
    state.clearInputMetadata();
    saturatingAdd(state.statistics.rejectedSamples, 1);
    if (error != nullptr && error->empty()) {
      assignError(error, "audio sample timeline is not exactly representable");
    }
    outcome.result = NativeAudioSubmitResult::Invalid;
    return outcome;
  }

  const bool timelineAdmissible =
      state.has_input_timeline ? sampleStart == state.expected_input_frame
      : state.timeline.trimBeforeFloor
          ? sampleStart <= state.presentation_floor_frame
          : sampleStart == state.presentation_floor_frame;
  const bool needsRefreshProof =
      !state.timeline.startsAtStreamOrigin && !state.has_input_timeline;
  std::uint64_t acceptedAfter = 0;
  if (!timelineAdmissible || sample.decodeOnly ||
      (needsRefreshProof && !immediatePlayoutFrame(nativeSample, error)) ||
      !checkedAdd(state.accepted_pcm_frames, totalFrames, &acceptedAfter)) {
    state.clearInputMetadata();
    saturatingAdd(state.statistics.rejectedSamples, 1);
    assignError(error,
                "audio sample does not continue the exact generation timeline");
    outcome.result = NativeAudioSubmitResult::Invalid;
    return outcome;
  }

  const std::span<const std::byte> contiguous =
      sample.payload.contiguousBytes();
  const bool borrowContiguous = contiguous.size() == byteCount;
  if (borrowContiguous) {
    state.encoded_data = contiguous.data();
    state.encoded_borrowed = true;
  } else {
    if (!sample.payload.copyBytes(
            0,
            std::span<std::byte>(state.encoded_storage.data(), byteCount))) {
      state.clearInputMetadata();
      saturatingAdd(state.statistics.rejectedSamples, 1);
      assignError(error, "CoreMedia audio payload copy failed");
      outcome.result = NativeAudioSubmitResult::Invalid;
      return outcome;
    }
    state.encoded_data = state.encoded_storage.data();
    state.encoded_borrowed = false;
  }
  if (state.next_prepare_serial == 0) {
    state.clearInputMetadata();
    state.failPump(error, "native audio prepare serial space is exhausted");
    outcome.result = NativeAudioSubmitResult::Failed;
    return outcome;
  }
  state.encoded_size = byteCount;
  state.next_packet = 0;
  state.prepared_frame_count = totalFrames;
  state.prepared_accepted_frames = acceptedAfter;
  state.prepared_start_frame = sampleStart;
  state.prepared_end_frame = sampleEnd;
  state.prepared_presentation_time = sample.presentationTime;
  state.prepared_decode_time = sample.decodeTime;
  state.prepared_duration = sample.duration;
  state.prepared_key_frame = sample.keyFrame;
  state.prepared_decode_only = sample.decodeOnly;
  state.prepared_discontinuity = sample.discontinuity;
  state.prepared_decoded_audio_frames = sample.decodedAudioFrames;
  state.prepared_serial = state.next_prepare_serial;
  state.prepared_native_identity = borrowed->opaqueAddress();
  state.prepared = true;
  if (state.encoded_borrowed) {
    saturatingAdd(state.statistics.borrowedEncodedSamples, 1);
    saturatingAdd(state.statistics.borrowedEncodedBytes, byteCount);
  } else {
    saturatingAdd(state.statistics.copiedEncodedSamples, 1);
    saturatingAdd(state.statistics.copiedEncodedBytes, byteCount);
  }
  state.next_prepare_serial =
      state.next_prepare_serial == std::numeric_limits<std::uint64_t>::max()
          ? 0
          : state.next_prepare_serial + 1;
  outcome.result = NativeAudioSubmitResult::Accepted;
  outcome.prepared.instance_ = state.instance_identity;
  outcome.prepared.owner_ = this;
  outcome.prepared.serial_ = state.prepared_serial;
  outcome.prepared.native_identity_ = state.prepared_native_identity;
  return outcome;
}

bool NativeAudioConverter::commitPrepared(
    NativeAudioPreparedSample &&prepared,
    media::MediaSample &&sample) noexcept {
  auto &state = *impl_;
  const std::shared_ptr<const void> preparedInstance =
      prepared.instance_.lock();
  const auto borrowed =
      sample.payload
          .borrowNative<media::NativePayloadKind::CoreMediaSampleBuffer>();
  const std::span<const std::byte> committedContiguous =
      state.encoded_borrowed ? sample.payload.contiguousBytes()
                             : std::span<const std::byte>{};
  std::int64_t sampleStart = 0;
  std::int64_t sampleDuration = 0;
  const bool matches =
      state.configured && !state.cancelled && !state.failed &&
      !state.eof_requested && !state.drained && state.prepared &&
      !state.lease && preparedInstance &&
      preparedInstance == state.instance_identity && prepared.owner_ == this &&
      prepared.serial_ != 0 && prepared.serial_ == state.prepared_serial &&
      prepared.native_identity_ == state.prepared_native_identity && borrowed &&
      borrowed->opaqueAddress() == state.prepared_native_identity &&
      sample.generation == state.statistics.generation &&
      sample.track == state.track &&
      sample.kind == media::MediaSampleKind::EncodedAudio &&
      sample.sampleCount == state.packet_count &&
      sample.presentationTime == state.prepared_presentation_time &&
      sample.decodeTime == state.prepared_decode_time &&
      sample.duration == state.prepared_duration &&
      sample.keyFrame == state.prepared_key_frame &&
      sample.decodeOnly == state.prepared_decode_only &&
      sample.discontinuity == state.prepared_discontinuity &&
      sample.decodedAudioFrames == state.prepared_decoded_audio_frames &&
      sample.payload.byteSize() == state.encoded_size &&
      (!state.encoded_borrowed ||
       (committedContiguous.size() == state.encoded_size &&
        committedContiguous.data() == state.encoded_data)) &&
      exactFrame(sample.presentationTime, state.sample_rate, &sampleStart) &&
      exactFrame(sample.duration, state.sample_rate, &sampleDuration) &&
      sampleDuration > 0 && sampleStart == state.prepared_start_frame &&
      static_cast<std::uint64_t>(sampleDuration) == (state.aac.piecewise ?
          static_cast<std::uint64_t>(state.prepared_end_frame-state.prepared_start_frame) : state.prepared_frame_count);
  prepared.instance_.reset();
  prepared.owner_ = nullptr;
  prepared.serial_ = 0;
  prepared.native_identity_ = nullptr;
  if (!matches) {
    state.failClosedProtocol();
    return false;
  }

  const std::size_t retainedBytes = state.encoded_size;
  state.lease = std::move(sample.payload);
  state.input_phase = Impl::InputPhase::Feeding;
  state.retained_payload_bytes = retainedBytes;
  state.peak_retained_payload_bytes =
      std::max(state.peak_retained_payload_bytes, retainedBytes);
  if (!state.has_input_timeline) {
    // A one-packet lead-in is the generation's first packet, whatever its
    // length.
    if (state.lead_in_is_first_packet) {
      state.lead_in_frames = state.frame_deficit_frames = state.packet_frames[0];
    }
    // The first PCM frame this generation will see is not the first frame of
    // the first packet: the decoder has already consumed its own lead-in.
    if (!checkedFrameEnd(state.prepared_start_frame, state.lead_in_frames,
                         &state.decoded_cursor_frame)) {
      state.failClosedProtocol();
      return false;
    }
    state.has_input_timeline = true;
  }
  if (state.aac.piecewise) {
    state.aac.commit(sample.sampleCount);
  }
  state.expected_input_frame = state.prepared_end_frame;
  state.accepted_pcm_frames = state.prepared_accepted_frames;
  state.clearPreparedProof();
  saturatingAdd(state.statistics.acceptedSamples, 1);
  return true;
}

NativeAudioPumpResult NativeAudioConverter::pump(std::string *error) {
  auto &state = *impl_;
  if (!state.configured || state.cancelled) {
    return NativeAudioPumpResult::NotConfigured;
  }
  if (state.failed) {
    return NativeAudioPumpResult::Failed;
  }
  if (state.ring.generation() != state.statistics.generation) {
    return NativeAudioPumpResult::StaleGeneration;
  }
  if (state.aac.piecewise && state.aac.size) {
    const auto mapped = state.publishAac(error);
    if (mapped != NativeAudioPumpResult::Progress) return mapped;
  }
  if (state.drained) {
    if (const auto staged = state.publishStaged(true, error)) {
      return *staged;
    }
    return NativeAudioPumpResult::Drained;
  }
  if (!state.nextBlockIsAllPreroll() &&
      state.ring.queuedSlabs() >= media::NativePcmRing::kSlabCount) {
    saturatingAdd(state.statistics.ringBackpressure, 1);
    return NativeAudioPumpResult::Backpressure;
  }
  const bool awaitingRelease =
      state.input_phase == Impl::InputPhase::AwaitingRelease;
  const bool hasInput = state.input_phase == Impl::InputPhase::Feeding &&
                        state.next_packet < state.packet_count;
  if (!hasInput && !awaitingRelease && !state.eof_requested) {
    return NativeAudioPumpResult::NeedsInput;
  }
  if (hasInput && state.encoded_data == nullptr) {
    state.failPump(error, "native audio input storage is unavailable");
    return NativeAudioPumpResult::Failed;
  }
  const auto byteSpan =
      hasInput ? std::span<const std::byte>(state.encoded_data,
                                            state.encoded_size)
               : std::span<const std::byte>{};
  const auto packetSpan = hasInput
                              ? std::span<const NativeAudioPacketDescription>(
                                    state.packets.data() + state.next_packet,
                                    state.packet_count - state.next_packet)
                              : std::span<const NativeAudioPacketDescription>{};
  const bool sendingEof = state.eof_requested && !hasInput && !awaitingRelease;
  NativeAudioBackendResult converted;
  try {
    converted = state.backend->convert(
        {byteSpan, packetSpan, sendingEof},
        std::span<float>(state.pcm.data(),
                         kFramesPerPump * state.audio.channels));
  } catch (...) {
    state.failPump(error, "native audio backend convert threw");
    return NativeAudioPumpResult::Failed;
  }
  if (!state.resultWithinContract(converted, packetSpan.size(), sendingEof)) {
    state.failPump(error, state.backend->failureReason() ? state.backend->failureReason() :
                          "native audio backend violated its bounded contract");
    return NativeAudioPumpResult::Failed;
  }
  std::uint64_t decodedAfter = 0;
  std::int64_t cursorAfter = 0;
  if (!state.projectDecodedBlock(converted.producedFrames, &decodedAfter,
                                 &cursorAfter)) {
    state.failPump(error,
                   "decoded audio exceeds its exact accepted timeline budget");
    return NativeAudioPumpResult::Failed;
  }
  state.next_packet += converted.consumedPackets;
  saturatingAdd(state.statistics.consumedPackets, converted.consumedPackets);
  saturatingAdd(state.statistics.producedFrames, converted.producedFrames);
  if (state.input_phase == Impl::InputPhase::Feeding &&
      state.next_packet == state.packet_count) {
    state.input_phase = Impl::InputPhase::AwaitingRelease;
  }
  if (converted.finalInputReleased) {
    if (state.input_phase != Impl::InputPhase::AwaitingRelease) {
      state.failPump(error,
                     "native audio backend released untracked input storage");
      return NativeAudioPumpResult::Failed;
    }
    state.releaseSample();
  }
  if (converted.producedFrames != 0) {
    if (!state.capabilities.channelRolesAtConfigure &&
        state.audio.channels > media::NativePcmRing::kChannels &&
        !state.downmix.admitted()) {
      if (!state.buildDownmix(state.audio.channels)) {
        state.failPump(error, "SoftwareAudioDecodedChannelLayoutUnqualified");
        return NativeAudioPumpResult::Failed;
      }
      state.statistics.downmixApplied = true;
    }
    Impl::PcmTrimPlan plan;
    if (const char *refusal = state.aac.piecewise ? nullptr :
            state.planTrim(converted.producedFrames, cursorAfter, &plan)) {
      state.failPump(error, refusal);
      return NativeAudioPumpResult::Failed;
    }
    const std::uint64_t discarded = plan.headDiscarded;
    const std::uint64_t publishFrames = plan.publishFrames;
    state.statistics.decodedPcmFrames = decodedAfter;
    if (!state.aac.piecewise) state.statistics.discardedTrimFrames = plan.discardedTrimAfter;
    state.decoded_cursor_frame = cursorAfter;
    // Width normalisation, and the ONLY place the decoded PCM changes shape.
    // It happens after the frame accounting above is already final and before
    // the ring sees a single sample, so the ring, clock, stretch, gain and
    // render callback all stay exactly two channels and completely unaware
    // that a 5.1 track was ever involved. Neither branch can change a frame
    // count: mono widens each frame, multichannel narrows each frame.
    if (state.audio.channels == 1) {
      for (std::size_t frame = converted.producedFrames; frame != 0; --frame) {
        const float value = state.pcm[frame - 1];
        state.pcm[(frame - 1) * 2] = value;
        state.pcm[(frame - 1) * 2 + 1] = value;
      }
    } else if (state.downmix.admitted()) {
      media::applyStereoDownmix(state.downmix, state.pcm,
                                converted.producedFrames);
      saturatingAdd(state.statistics.downmixedFrames,
                    converted.producedFrames);
    }
    if (state.aac.piecewise) {
      state.aac.pendingCount = converted.producedFrames;
      state.aac.pendingOffset = 0;
      if (converted.drained && !state.sealDrain(decodedAfter,error)) return NativeAudioPumpResult::Failed;
      return state.publishAac(error);
    }
    if (publishFrames != 0) {
      state.stage(plan.publishStart,
                  state.pcm.data() + discarded * media::NativePcmRing::kChannels,
                  publishFrames);
    }
    if (converted.drained && !state.sealDrain(decodedAfter, error)) {
      return NativeAudioPumpResult::Failed;
    }
    // The pump preflight left room for this one slab. A remainder a drained
    // generation could not publish here is published by the next pump before
    // it reports Drained.
    const bool final = converted.drained ||
                       (state.has_presentation_ceiling &&
                        cursorAfter >= state.presentation_ceiling_frame);
    if (const auto staged = state.publishStaged(final, error)) {
      return *staged;
    }
    return NativeAudioPumpResult::Progress;
  }
  if (converted.drained) {
    if (!state.sealDrain(state.statistics.decodedPcmFrames, error)) {
      return NativeAudioPumpResult::Failed;
    }
    if (const auto staged = state.publishStaged(true, error)) {
      return *staged;
    }
    return NativeAudioPumpResult::Drained;
  }
  if (converted.consumedPackets != 0 || converted.finalInputReleased) {
    return NativeAudioPumpResult::Progress;
  }
  if (converted.needsInput && !state.eof_requested) {
    return NativeAudioPumpResult::NeedsInput;
  }
  if (state.capabilities.idleConvertRetries) {
    return NativeAudioPumpResult::Backpressure;
  }
  state.describeStall(converted, sendingEof, hasInput, error);
  return NativeAudioPumpResult::Failed;
}

NativeAudioPumpResult
NativeAudioConverter::endOfStream(media::MediaGeneration generation,
                                  std::string *error) {
  auto &state = *impl_;
  if (!state.configured || state.cancelled) {
    return NativeAudioPumpResult::NotConfigured;
  }
  if (state.failed) {
    return NativeAudioPumpResult::Failed;
  }
  if (generation != state.statistics.generation) {
    return NativeAudioPumpResult::StaleGeneration;
  }
  if (state.prepared) {
    state.failPump(error,
                   "end-of-stream cannot overtake a prepared audio sample");
    return NativeAudioPumpResult::Failed;
  }
  state.eof_requested = true;
  return pump(error);
}

void NativeAudioConverter::cancel(media::MediaGeneration generation) noexcept {
  auto &state = *impl_;
  if (!state.configured || generation != state.statistics.generation) {
    return;
  }
  state.cancelled = true;
  try {
    if (state.capabilities.cancelCloses) {
      state.backend->close();
    } else if (!state.backend->reset(nullptr)) {
      saturatingAdd(state.statistics.failures, 1);
      state.backend->close();
      state.configured = false;
    }
  } catch (...) {
    saturatingAdd(state.statistics.failures, 1);
    try {
      state.backend->close();
    } catch (...) {
    }
    state.configured = false;
  }
  state.clearFlow();
}

bool NativeAudioConverter::flush(
    media::MediaGeneration nextGeneration,
    NativeAudioGenerationTimeline timeline) noexcept {
  auto &state = *impl_;
  std::int64_t floorFrame = 0;
  std::int64_t ceilingFrame = 0;
  bool ceilingKnown = false;
  if (!state.configured || nextGeneration == 0 ||
      nextGeneration <= state.statistics.generation ||
      state.ring.generation() != nextGeneration ||
      !exactFrame(timeline.presentationFloor, state.sample_rate, &floorFrame) ||
      !resolveCeiling(timeline, state.sample_rate, floorFrame, &ceilingFrame,
                      &ceilingKnown)) {
    return false;
  }
  bool reset = false;
  try {
    reset = state.backend->reset(nullptr);
  } catch (...) {
  }
  // A backend reset may REBUILD the converter rather than reset it (see
  // decoderResetRebuilds), and a rebuilt converter is entitled to state its
  // layout afresh. Re-derive the fold and require it to be identical; a
  // generation that silently changed channel order mid-stream would put
  // dialogue in the wrong place with no other symptom.
  if (!reset || (state.downmix.admitted() &&
                 state.reportedDownmix() != state.downmix)) {
    state.failClosedProtocol();
    return false;
  }
  state.clearFlow();
  state.cancelled = false;
  state.failed = false;
  state.statistics.generation = nextGeneration;
  state.peak_retained_payload_bytes = state.retained_payload_bytes;
  state.statistics.sampleRetained = false;
  state.statistics.endOfStreamRequested = false;
  state.statistics.drained = false;
  state.resetExactTimeline(timeline, floorFrame, ceilingFrame, ceilingKnown);
  return true;
}

void NativeAudioConverter::close() noexcept {
  if (!impl_) {
    return;
  }
  auto &state = *impl_;
  state.closeBackend();
  state.clearFlow();
  state.configured = false;
  state.failed = false;
  state.downmix = {};
  state.statistics.downmixApplied = false;
}

NativeAudioConverterStats NativeAudioConverter::stats() const noexcept {
  auto result = impl_->statistics;
  result.configured = impl_->configured;
  result.sampleRate = impl_->configured ? impl_->sample_rate : 0;
  result.cancelled = impl_->cancelled;
  result.failed = impl_->failed;
  result.samplePrepared = impl_->prepared;
  result.sampleRetained = static_cast<bool>(impl_->lease);
  result.retainedPayloadBytes = impl_->retained_payload_bytes;
  result.peakRetainedPayloadBytes =
      std::max(impl_->peak_retained_payload_bytes,
               result.retainedPayloadBytes);
  result.endOfStreamRequested = impl_->eof_requested;
  result.drained = impl_->drained && impl_->staged_frames == 0;
  return result;
}

#if defined(WAM_NATIVE_TEST_SEAMS)
bool NativeAudioConverter::resetRetainedPayloadByteHighWater(
    media::MediaGeneration expectedGeneration) noexcept {
  if (expectedGeneration == 0 ||
      impl_->statistics.generation != expectedGeneration) {
    return false;
  }
  impl_->peak_retained_payload_bytes = impl_->retained_payload_bytes;
  return true;
}
#endif

} // namespace wam::macos
