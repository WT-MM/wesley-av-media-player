#include "native_audio_session.hpp"

#include "media/adpcm_audio.hpp"
#include "media/audio_codec_timing.hpp"
#include "media/audio_downmix.hpp"
#include "media/matroska_vorbis.hpp"
#include "native_audio_channel_map.hpp"
#include "native_concurrency_limits.hpp"

#import <AudioToolbox/AudioToolbox.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <limits>
#include <mutex>
#include <numeric>
#include <optional>
#include <utility>

namespace wam::macos {
namespace {

enum class SessionLifecycle : std::uint8_t {
  None,
  Flush,
  Cancel,
};

enum class FlushStage : std::uint8_t {
  Stop,
  Reset,
  Activate,
};

enum class RetireStage : std::uint8_t {
  StopOutput,
  InvalidateGraph,
  CloseOutput,
};

enum class TerminalOverride : std::uint8_t {
  None,
  Stop,
  Cancel,
};

// Pause-driven idling of the output AudioUnit. Stopping is not instantaneous:
// AudioOutputUnitStop revokes admission and stops the device synchronously,
// but a callback already inside the bridge must still drain before the stop
// is Done. Stopping therefore names the interval in which the device is
// already stopped and admission already revoked while that drain completes.
// It exists so that a resume arriving inside that interval cannot mistake a
// Started session for a running output and leave the device stopped forever.
enum class OutputSuspension : std::uint8_t {
  None,
  Stopping,
  Suspended,
};

struct TimelinePlan {
  NativeAudioGenerationTimeline converter{};
  media::MediaTime decodeStart{};       // first source-proved audio AU D
  media::MediaTime mediaOrigin{};       // first retained source PCM frame A
  media::MediaTime clockPosition{};     // exact visual generation floor T
  std::int64_t floorFrame{0};
  std::uint32_t sampleRate{0};
  // Generation-local frame index of mediaOrigin: the frame the clock's cursor
  // zero names. Equal to floorFrame unless the container declares silence
  // before its audio, in which case the clock starts at the VISUAL floor and
  // the audio floor sits leadInSilenceFrames later.
  std::int64_t originFrame{0};
  std::uint64_t leadInSilenceFrames{0};
  // The same facts in generation-local cursor frames, as the render core takes
  // them. Derived once here so the arithmetic exists in exactly one place.
  NativeAudioDeclaredSilence declaredSilence{};
  // Absolute audio frame at which this generation's PRESENTATION must end when
  // the container declares trailing silence (a video tail past the end of the
  // selected audio). Zero means "the audio's own end".
  std::int64_t presentationEndFrame{0};
  // Absolute audio frame at which the container states its audio media ends.
  // Zero unless presentationEndFrame is stated too.
  std::int64_t audioEndFrame{0};
};

// Guards the session-envelope registry below: gRetainedSessions and every
// quarantine slot. Taken only on create(), on the Done-close release, on a
// destructor's quarantine transfer, on recoverQuarantined() and on
// quarantineFacts(). No render callback, no trySample(), no clock publication
// and no owner-thread steady-state path touches it, so it can never appear on
// the audio hot path.
std::mutex gSessionMutex;
// Sessions currently charged against the process envelope: every session
// create() admitted whose graph has not yet proved a Done close. A quarantined
// session is still charged -- it still owns its AudioUnit, its converter, its
// PCM ring and the callback contexts the device may still be inside -- so the
// count is live plus quarantined and never exceeds
// kMaximumConcurrentPlayerWindows. This is the old single `bool
// gSessionClaimed` widened from one window to N.
int gRetainedSessions{0};
// One quarantine slot per admissible player window, so every open window's
// graph can be held at once and none is ever dropped for want of a slot. A
// fixed array of empty shared_ptrs: the registry allocates nothing itself and
// cannot grow, whatever a teardown storm does.
std::array<std::shared_ptr<NativeAudioSessionControl>,
           kMaximumConcurrentPlayerWindows>
    gSessionQuarantine;
std::atomic<std::uint64_t> gRejectedCreates{0};
std::atomic<std::uint64_t> gQuarantineTransfers{0};
std::atomic<std::uint64_t> gQuarantineRecoveries{0};

void saturatingIncrement(std::atomic<std::uint64_t>& counter) noexcept {
  const std::uint64_t maximum = std::numeric_limits<std::uint64_t>::max();
  std::uint64_t current = counter.load(std::memory_order_relaxed);
  for (unsigned attempt = 0; attempt != 2 && current != maximum; ++attempt) {
    if (counter.compare_exchange_weak(current, current + 1U,
                                      std::memory_order_relaxed,
                                      std::memory_order_relaxed)) {
      return;
    }
  }
}

void assignError(std::string* error, const char* message) noexcept {
  if (error == nullptr) {
    return;
  }
  try {
    *error = message;
  } catch (...) {
  }
}

[[nodiscard]] std::uint64_t magnitude(std::int64_t value) noexcept {
  return value < 0 ? static_cast<std::uint64_t>(-(value + 1)) + 1U
                   : static_cast<std::uint64_t>(value);
}

[[nodiscard]] bool exactFrame(media::MediaTime time,
                              std::uint32_t sampleRate,
                              std::int64_t* result) noexcept {
  if (!time.valid() || sampleRate == 0 || result == nullptr) {
    return false;
  }
  std::uint64_t numerator = magnitude(time.value);
  std::uint64_t denominator = static_cast<std::uint32_t>(time.timescale);
  std::uint64_t rate = sampleRate;
  const std::uint64_t first = std::gcd(numerator, denominator);
  numerator /= first;
  denominator /= first;
  const std::uint64_t second = std::gcd(rate, denominator);
  rate /= second;
  denominator /= second;
  if (denominator != 1 ||
      (rate != 0 &&
       numerator > std::numeric_limits<std::uint64_t>::max() / rate)) {
    return false;
  }
  const std::uint64_t absolute = numerator * rate;
  if (time.value < 0) {
    constexpr std::uint64_t negativeLimit = std::uint64_t{1} << 63U;
    if (absolute > negativeLimit) {
      return false;
    }
    *result = absolute == negativeLimit
                  ? std::numeric_limits<std::int64_t>::min()
                  : -static_cast<std::int64_t>(absolute);
    return true;
  }
  if (absolute >
      static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
    return false;
  }
  *result = static_cast<std::int64_t>(absolute);
  return true;
}

[[nodiscard]] bool supportedRate(double rate,
                                 std::uint32_t* exactRate) noexcept {
  constexpr std::array<std::uint32_t, 4> supported{
      44'100, 48'000, 96'000, 192'000};
  if (!std::isfinite(rate) || exactRate == nullptr) {
    return false;
  }
  for (const std::uint32_t candidate : supported) {
    if (rate == static_cast<double>(candidate)) {
      *exactRate = candidate;
      return true;
    }
  }
  return false;
}

[[nodiscard]] bool supportedCodec(const media::MediaTrackDescriptor& track)
    noexcept {
  if (!track.audio) {
    return false;
  }
  switch (track.codec) {
  case media::MediaCodec::Aac:
    return track.audio->formatTag == kAudioFormatMPEG4AAC ||
           track.audio->formatTag == kAudioFormatMPEG4AAC_HE ||
           track.audio->formatTag == kAudioFormatMPEG4AAC_HE_V2;
  case media::MediaCodec::Alac:
    return track.audio->formatTag == kAudioFormatAppleLossless;
  // Uncompressed audio, which reaches this pipeline only from AVFoundation:
  // a standalone .wav or .aiff, or an lpcm track in a QuickTime movie. There
  // is no bitstream to parse and no decoder to prime, so the converter's whole
  // per-codec table stays at its zero defaults; what the AudioConverter does
  // for it is the interleaved-int-to-float restatement it would otherwise do
  // as the last step of every decode. The format's own flags carry the sample
  // depth, signedness and endianness, and exactAsbd already restates them
  // verbatim, which is what lets one arm cover .wav (0xc) and .aiff (0xe)
  // alike.
  case media::MediaCodec::Pcm:
    return track.audio->formatTag == kAudioFormatLinearPCM;
  // ADPCM in WAV, admitted for exactly the measured reason stated at the
  // matching arm in native_audio_converter.mm: a bit-exact decode against
  // ffmpeg with a zero-frame lead-in, carried by the existing CBR arm.
  case media::MediaCodec::AdpcmIma:
    return track.audio->formatTag == kAudioFormatDVIIntelIMA;
  case media::MediaCodec::AdpcmMs:
    return track.audio->formatTag == media::kMicrosoftAdpcmAudioFormatTag;
  case media::MediaCodec::Mp3:
    // The routing family, not one layer. Layer II reaches this arm from
    // MPEG-TS stream types 0x03/0x04, and it is admitted here for exactly the
    // measured reason stated at the matching arm in native_audio_converter.mm.
    return track.audio->formatTag == kAudioFormatMPEGLayer3 ||
           track.audio->formatTag == kAudioFormatMPEGLayer2;
  case media::MediaCodec::Opus:
    return track.audio->formatTag == kAudioFormatOpus;
  case media::MediaCodec::Vorbis:
    return track.audio->formatTag ==
           wam::media::matroska::kVorbisAudioFormatTag;
  case media::MediaCodec::Ac3:
    return track.audio->formatTag == kAudioFormatAC3;
  case media::MediaCodec::Eac3:
    return track.audio->formatTag == kAudioFormatEnhancedAC3;
  case media::MediaCodec::Flac:
    return track.audio->formatTag == kAudioFormatFLAC;
  default:
    return false;
  }
}

// Whether this track's first access unit legitimately presents before media
// time zero: Matroska stores a Block's timestamp on the codec grid and states
// CodecDelay separately, so access unit 0 of an Opus, Vorbis, AC-3, E-AC-3,
// MP3 or CodecDelay-bearing AAC track starts early. The generation therefore
// decodes a bounded preroll it must not publish -- exactly what
// trimBeforeFloor already means.
[[nodiscard]] bool codecStartsBeforeStreamOrigin(
    const media::MediaTrackDescriptor& track) noexcept {
  return media::audioCodecPrecedesStreamOrigin(track.codec);
}

// Whether this track's stated duration is the exact decoded sample count, and
// therefore usable as the frame the generation must stop publishing at.
//
// Until this sweep the answer was the SAME predicate as the one above, because
// the two codecs that needed either needed both. They are genuinely different
// questions and the sets now differ at both ends: FLAC states an exact
// duration but starts at the origin, and AAC precedes the origin but reaches
// this pipeline from AVFoundation as well as from Matroska.
//
// AAC is the reason for the second clause. Only the Matroska descriptor states
// a decoded sample count; an AVFoundation track's duration is the container's
// own number, which is not required to be a whole number of frames at all. The
// ceiling is therefore taken only when the stated duration IS an exact whole
// frame count -- which the Matroska path always produces by construction, and
// which an approximate container duration cannot fake into being wrong: if it
// is not exact the track simply keeps today's behaviour instead of failing the
// whole session, and if it is exact then it is the true end of the track and
// stopping there is right.
[[nodiscard]] bool codecStatesExactDecodedDuration(
    const media::MediaTrackDescriptor& track, std::uint32_t sampleRate) noexcept {
  if (!media::audioCodecStatesExactDecodedDuration(track.codec)) {
    if (track.codec != media::MediaCodec::Aac) {
      return false;
    }
  }
  std::int64_t ceilingFrame = 0;
  return exactFrame(track.duration, sampleRate, &ceilingFrame) &&
         ceilingFrame > 0;
}

// Mirrors NativeAudioConverter's own rule exactly: mono and stereo must state
// their canonical tag or none at all, and a multichannel track may state a tag
// only when that tag expands to a stereo fold this player can perform. The
// session refuses first so an inadmissible layout produces a clean fallback
// instead of a converter failure part-way through graph construction.
[[nodiscard]] bool supportedLayout(const media::MediaAudioFormat& audio)
    noexcept {
  if (!audio.channelLayoutPresent) {
    return audio.channelLayoutTag == 0;
  }
  if (audio.channels == 1) {
    return audio.channelLayoutTag == kAudioChannelLayoutTag_Mono;
  }
  if (audio.channels == 2) {
    return audio.channelLayoutTag == kAudioChannelLayoutTag_Stereo;
  }
  return multichannelLayoutTagAdmitted(audio.channelLayoutTag, audio.channels);
}

[[nodiscard]] bool validCallTable(
    const NativeAudioUnitCallTable& calls) noexcept {
  return calls.findNext != nullptr && calls.instanceNew != nullptr &&
         calls.instanceDispose != nullptr && calls.setProperty != nullptr &&
         calls.getProperty != nullptr && calls.initialize != nullptr &&
         calls.uninitialize != nullptr && calls.start != nullptr &&
         calls.stop != nullptr && calls.addPropertyListener != nullptr &&
         calls.removePropertyListener != nullptr &&
         calls.hostClockFrequency != nullptr;
}

[[nodiscard]] bool validDependencies(
    const NativeAudioSessionDependencies& dependencies) noexcept {
  return dependencies.externalLifetime != nullptr &&
         dependencies.hostClock.readTicks != nullptr &&
         dependencies.hostClock.ticksPerSecond != 0 &&
         validCallTable(dependencies.outputCalls) &&
         dependencies.outputWake.pending != nullptr &&
         dependencies.outputWake.signal != nullptr &&
         dependencies.outputWake.pending->is_lock_free();
}

[[nodiscard]] std::optional<TimelinePlan> timelinePlanForRate(
    media::MediaGeneration generation,
    const media::NativeMediaGenerationTimeline& timeline,
    std::uint32_t sampleRate, bool audioMayPrecedeStreamOrigin) noexcept {
  std::int64_t floorFrame = 0;
  std::int64_t decodeFrame = 0;
  if (generation == 0 || timeline.generation != generation ||
      !timeline.requestedTarget.valid() ||
      !timeline.actualDecodeStart.valid() ||
      !timeline.presentationFloor.valid() ||
      !timeline.audioWindow.decodeStart.valid() ||
      !timeline.audioWindow.presentationStart.valid() ||
      !exactFrame(timeline.audioWindow.decodeStart, sampleRate,
                  &decodeFrame) ||
      !exactFrame(timeline.audioWindow.presentationStart, sampleRate,
                  &floorFrame) ||
      (decodeFrame < 0 && !audioMayPrecedeStreamOrigin) ||
      floorFrame < 0) {
    return std::nullopt;
  }

  constexpr media::MediaTime origin{0, 1};
  const auto actualAgainstFloor = media::compareMediaTime(
      timeline.actualDecodeStart, timeline.presentationFloor);
  const auto actualAgainstOrigin =
      media::compareMediaTime(timeline.actualDecodeStart, origin);
  const auto targetAgainstFloor = media::compareMediaTime(
      timeline.requestedTarget, timeline.presentationFloor);
  const auto targetAgainstOrigin =
      media::compareMediaTime(timeline.requestedTarget, origin);
  const auto actualAgainstTarget = media::compareMediaTime(
      timeline.actualDecodeStart, timeline.requestedTarget);
  const auto audioDecodeAgainstFloor = media::compareMediaTime(
      timeline.audioWindow.decodeStart,
      timeline.audioWindow.presentationStart);
  const auto audioDecodeAgainstOrigin = media::compareMediaTime(
      timeline.audioWindow.decodeStart, origin);
  const auto audioDecodeAgainstMediaStart = media::compareMediaTime(
      timeline.audioWindow.decodeStart, timeline.audioWindow.mediaStart);
  if (!actualAgainstFloor ||
      *actualAgainstFloor == media::MediaTimeOrder::Greater ||
      !actualAgainstOrigin ||
      *actualAgainstOrigin == media::MediaTimeOrder::Less ||
      !targetAgainstFloor || !targetAgainstOrigin ||
      *targetAgainstOrigin == media::MediaTimeOrder::Less ||
      !actualAgainstTarget ||
      *actualAgainstTarget == media::MediaTimeOrder::Greater ||
      timeline.startsAtStreamOrigin !=
          (*actualAgainstOrigin == media::MediaTimeOrder::Equal) ||
      !audioDecodeAgainstFloor ||
      *audioDecodeAgainstFloor == media::MediaTimeOrder::Greater ||
      !audioDecodeAgainstOrigin ||
      (*audioDecodeAgainstOrigin == media::MediaTimeOrder::Less &&
       !audioMayPrecedeStreamOrigin) ||
      // An audio window that begins at or before the movie time the audio
      // media begins can only be the stream origin: there is nothing earlier
      // for it to be. mediaStart is the origin for every source that declares
      // no silence before its audio, so this is the prior rule verbatim there.
      !audioDecodeAgainstMediaStart ||
      timeline.audioWindow.startsAtStreamOrigin !=
          (*audioDecodeAgainstMediaStart !=
           media::MediaTimeOrder::Greater)) {
    return std::nullopt;
  }

  bool trimBeforeFloor = false;
  switch (timeline.mode) {
  case media::MediaSeekMode::Accurate:
    if (*targetAgainstFloor != media::MediaTimeOrder::Equal) {
      return std::nullopt;
    }
    // Audio presentation begins at the requested target, or at the movie time
    // the container says its audio media begins -- whichever is later. The two
    // differ exactly when a leading empty edit declares silence the target
    // falls inside; the span between them is what the render core renders as
    // declared silence, and the equality below still pins the boundary to an
    // exact frame with no rounding.
    if (const auto mediaStartAgainstTarget = media::compareMediaTime(
            timeline.audioWindow.mediaStart, timeline.requestedTarget);
        !mediaStartAgainstTarget) {
      return std::nullopt;
    } else if (const auto expected = media::audioFrameAtOrAfter(
                   *mediaStartAgainstTarget == media::MediaTimeOrder::Greater
                       ? timeline.audioWindow.mediaStart
                       : timeline.requestedTarget,
                   sampleRate);
               !expected ||
               media::compareMediaTime(
                   timeline.audioWindow.presentationStart, *expected) !=
                   media::MediaTimeOrder::Equal) {
      return std::nullopt;
    }
    trimBeforeFloor =
        *audioDecodeAgainstFloor == media::MediaTimeOrder::Less;
    break;
  case media::MediaSeekMode::KeyFrame:
    if (*actualAgainstFloor != media::MediaTimeOrder::Equal ||
        (*audioDecodeAgainstFloor != media::MediaTimeOrder::Equal &&
         !audioMayPrecedeStreamOrigin) ||
        media::compareMediaTime(timeline.audioWindow.presentationStart,
                                timeline.presentationFloor) !=
            media::MediaTimeOrder::Equal) {
      return std::nullopt;
    }
    trimBeforeFloor =
        *audioDecodeAgainstFloor == media::MediaTimeOrder::Less;
    break;
  default:
    return std::nullopt;
  }

  // The clock's origin is the first audio frame boundary at or after the
  // VISUAL floor -- which is exactly what NativeAudioRenderCore::activate()
  // already requires of mediaOrigin at cursor zero, and which equals the
  // converter's presentation floor for every source that declares no silence
  // before its audio. Decoupling the two is the whole of leading-silence
  // support: the clock starts where the picture starts, the converter still
  // publishes its first PCM frame at the audio floor, and the frames between
  // them are the container's declared silence.
  std::int64_t originFrame = 0;
  const auto originBoundary = media::audioFrameAtOrAfter(
      timeline.presentationFloor, sampleRate);
  if (!originBoundary ||
      !exactFrame(*originBoundary, sampleRate, &originFrame) ||
      originFrame < 0 || originFrame > floorFrame) {
    return std::nullopt;
  }

  TimelinePlan result;
  result.converter.presentationFloor = {
      floorFrame, static_cast<std::int32_t>(sampleRate)};
  result.converter.trimBeforeFloor = trimBeforeFloor;
  result.converter.startsAtStreamOrigin =
      timeline.audioWindow.startsAtStreamOrigin;
  result.decodeStart = timeline.audioWindow.decodeStart;
  result.mediaOrigin = {originFrame, static_cast<std::int32_t>(sampleRate)};
  result.clockPosition = timeline.presentationFloor;
  result.floorFrame = floorFrame;
  result.originFrame = originFrame;
  result.leadInSilenceFrames =
      static_cast<std::uint64_t>(floorFrame - originFrame);
  result.declaredSilence.leadInFrames = result.leadInSilenceFrames;
  result.sampleRate = sampleRate;
  return result;
}

// The tail-trim ceiling and the pre-origin allowance are codec facts, so they
// have to survive into every later flush, which never sees the descriptor
// again. Both call sites therefore go through this one function.
[[nodiscard]] std::optional<TimelinePlan> timelinePlanFor(
    media::MediaGeneration generation,
    const media::NativeMediaGenerationTimeline& timeline,
    std::uint32_t sampleRate, bool audioMayPrecedeStreamOrigin,
    bool trimAfterCeiling, media::MediaTime presentationCeiling) noexcept {
  auto plan = timelinePlanForRate(generation, timeline, sampleRate,
                                  audioMayPrecedeStreamOrigin);
  if (!plan) {
    return std::nullopt;
  }
  if (trimAfterCeiling) {
    // The demuxer states an Opus track's duration as the exact decoded sample
    // count after both trims, so it is the frame the generation must stop
    // publishing at. A track that cannot state it exactly is not admitted
    // natively at all rather than played a few milliseconds long.
    std::int64_t ceilingFrame = 0;
    if (!presentationCeiling.valid() ||
        !exactFrame(presentationCeiling, sampleRate, &ceilingFrame) ||
        ceilingFrame <= plan->floorFrame) {
      return std::nullopt;
    }
    plan->converter.presentationCeiling = presentationCeiling;
    plan->converter.trimAfterCeiling = true;
  }
  // Container-declared TRAILING silence. presentationEnd is the movie time the
  // generation's presentation must reach when the selected audio stops short
  // of the selected video; the frames between the last real PCM frame and it
  // are declared silence, exactly like the leading span. Absent (the default)
  // it stays zero and the generation ends at its own audio end, as before.
  if (timeline.audioWindow.presentationEnd.valid()) {
    std::int64_t endFrame = 0;
    std::int64_t audioEndFrame = 0;
    if (!timeline.audioWindow.audioEnd.valid() ||
        !exactFrame(timeline.audioWindow.presentationEnd, sampleRate,
                    &endFrame) ||
        !exactFrame(timeline.audioWindow.audioEnd, sampleRate,
                    &audioEndFrame) ||
        endFrame < plan->floorFrame || audioEndFrame > endFrame) {
      return std::nullopt;
    }
    plan->presentationEndFrame = endFrame;
    plan->audioEndFrame = audioEndFrame;
    // Cursor space: frame zero of the generation is the clock's media origin.
    // A declared end at or before the origin states no trailing silence for
    // THIS generation (a seek past the audio's end), and is left inert.
    if (endFrame > plan->originFrame) {
      plan->declaredSilence.presentationEndFrame =
          static_cast<std::uint64_t>(endFrame - plan->originFrame);
      plan->declaredSilence.pcmEndFrame =
          audioEndFrame > plan->originFrame
              ? static_cast<std::uint64_t>(audioEndFrame - plan->originFrame)
              : 0;
    }
  }
  return plan;
}

[[nodiscard]] std::optional<TimelinePlan> preflight(
    const media::MediaTrackDescriptor& track,
    media::MediaGeneration generation,
    const media::NativeMediaGenerationTimeline& timeline) noexcept {
  std::uint32_t sampleRate = 0;
  if (generation == 0 || timeline.generation != generation ||
      track.id == 0 || track.kind != media::MediaTrackKind::Audio ||
      !track.audio || !supportedCodec(track) ||
      track.audio->channels == 0 ||
      track.audio->channels > media::kMaximumDownmixSourceChannels ||
      !track.audio->interleaved || track.audio->framesPerPacket == 0 ||
      !supportedLayout(*track.audio) ||
      !supportedRate(track.audio->sampleRate, &sampleRate) ||
      track.codecConfiguration.size() >
          media::MediaSourceLimits::kHardMaximumCodecConfigurationBytes ||
      (!track.codecConfiguration.empty() &&
       track.codecConfigurationKind !=
           media::MediaCodecConfigurationKind::AudioMagicCookie) ||
      (track.codecConfiguration.empty() &&
       track.codecConfigurationKind !=
           media::MediaCodecConfigurationKind::None)) {
    return std::nullopt;
  }
  return timelinePlanFor(generation, timeline, sampleRate,
                         codecStartsBeforeStreamOrigin(track),
                         codecStatesExactDecodedDuration(track, sampleRate),
                         track.duration);
}

[[nodiscard]] bool sameTimeline(
    const media::NativeMediaGenerationTimeline& lhs,
    const media::NativeMediaGenerationTimeline& rhs) noexcept {
  return lhs == rhs;
}

// The gain wire admits VLC-style amplification above unity. The ceiling is
// the render core's own kMaximumGain so the session can never publish a gain
// the core would silently re-clamp, and the fail-safe for a non-finite value
// stays silence. See NativeAudioRenderCore::applyGain for the [-1, 1] sample
// saturation that goes with it.
[[nodiscard]] float normalizedGain(float gain) noexcept {
  return std::isfinite(gain)
             ? std::clamp(gain, NativeAudioRenderCore::kMinimumGain,
                          NativeAudioRenderCore::kMaximumGain)
             : NativeAudioRenderCore::kMinimumGain;
}

[[nodiscard]] bool acceptsAudioControls(
    NativeAudioSessionState state) noexcept {
  switch (state) {
  case NativeAudioSessionState::Fresh:
  case NativeAudioSessionState::Configuring:
  case NativeAudioSessionState::Ready:
  case NativeAudioSessionState::Started:
  case NativeAudioSessionState::Stopping:
  case NativeAudioSessionState::Flushing:
    return true;
  case NativeAudioSessionState::Retiring:
  case NativeAudioSessionState::Cancelling:
  case NativeAudioSessionState::Cancelled:
  case NativeAudioSessionState::Closing:
  case NativeAudioSessionState::Unsupported:
  case NativeAudioSessionState::Failed:
  case NativeAudioSessionState::Closed:
    return false;
  }
  return false;
}

void advanceControlRevision(std::uint64_t& revision) noexcept {
  if (revision != std::numeric_limits<std::uint64_t>::max()) {
    ++revision;
  }
}

} // namespace

struct NativeAudioSessionControl final {
  NativeAudioSessionControl(
      media::MediaGeneration initialGeneration,
      std::shared_ptr<void> external,
      NativeMediaHostClock hostClock,
      NativeAudioUnitCallTable outputCalls,
      NativeAudioOutputWakeSeam outputWake,
      std::unique_ptr<NativeAudioConverterBackend> backend)
      : externalLifetime(std::move(external)),
        hostClock(hostClock),
        outputCalls(outputCalls),
        outputWake(outputWake),
        ring(initialGeneration),
        clock(this->hostClock),
        renderCore(ring, clock, this->hostClock.ticksPerSecond),
        converter(ring, std::move(backend)),
        generation(initialGeneration) {}

  void latch(NativeAudioSessionFailure value) noexcept {
    if (failure == NativeAudioSessionFailure::None) {
      failure = value;
    }
    if (state != NativeAudioSessionState::Retiring &&
        state != NativeAudioSessionState::Closing &&
        state != NativeAudioSessionState::Closed) {
      state = NativeAudioSessionState::Failed;
    }
  }

  // Destruction order is intentional: output, converter, render core, clock,
  // and ring are destroyed before the external callback lifetime token.
  std::shared_ptr<void> externalLifetime;
  const NativeMediaHostClock hostClock;
  const NativeAudioUnitCallTable outputCalls;
  const NativeAudioOutputWakeSeam outputWake;
  NativePcmRing ring;
  NativeMediaClock clock;
  NativeAudioRenderCore renderCore;
  NativeAudioConverter converter;
  std::shared_ptr<NativeAudioOutput> output;

  NativeAudioSessionState state{NativeAudioSessionState::Fresh};
  NativeAudioSessionFailure failure{NativeAudioSessionFailure::None};
  SessionLifecycle lifecycle{SessionLifecycle::None};
  FlushStage flushStage{FlushStage::Stop};
  RetireStage retireStage{RetireStage::StopOutput};
  OutputSuspension outputSuspension{OutputSuspension::None};
  media::MediaGeneration generation{0};
  media::MediaGeneration highestExposedGeneration{0};
  media::MediaGeneration lifecycleRetired{0};
  media::MediaGeneration lifecycleTarget{0};
  media::MediaGeneration cancelledGeneration{0};
  media::MediaGeneration completedFlushRetired{0};
  media::MediaGeneration completedFlushTarget{0};
  media::MediaTrackId track{0};
  std::uint32_t sampleRate{0};
  // Codec facts fixed at configure() and reused by every later flush, which
  // does not see the track descriptor again.
  bool audioMayPrecedeStreamOrigin{false};
  bool trimAfterCeiling{false};
  media::MediaTime presentationCeiling{};
  std::int64_t presentationFloorFrame{0};
  // Container-declared silence facts for the active generation. Both are zero
  // for every source that declares none, and every expression that reads them
  // then reduces to the prior arithmetic verbatim.
  std::int64_t mediaOriginFrame{0};
  std::uint64_t leadInSilenceFrames{0};
  std::int64_t presentationEndFrame{0};
  media::MediaTime mediaOrigin{};
  media::MediaTime audioDecodeStart{};
  media::NativeMediaGenerationTimeline timeline{};
  media::NativeMediaGenerationTimeline lifecycleTimeline{};
  NativeAudioGenerationTimeline converterTimeline{};
  TimelinePlan lifecyclePlan{};
  // Set when a StreamFormat notification froze a graph that was running, so
  // the reconciliation knows to start the output again once the device proves
  // unchanged. Cleared as soon as that restart is Done, or when the owner
  // takes the session somewhere the restart no longer applies.
  bool deviceChangeResumePending{false};
  std::uint64_t deviceChangeRecoveries{0};
  // Owned by publishFailureText(); NativeAudioSession::failureText() hands out
  // a reference to it, so it is never cleared once set.
  std::string failureText;
  bool claimHeld{true};
  bool resourceEntered{false};
  bool configured{false};
  bool firstAudioSampleAccepted{false};
  bool requestedPaused{true};
  float requestedGain{1.0F};
  float appliedGain{1.0F};
  bool requestedMuted{false};
  bool appliedMuted{false};
  NativePlaybackRate requestedRate{};
  bool requestedPreservePitch{true};
  std::uint64_t controlRevision{0};
  std::uint64_t appliedControlRevision{0};
  bool endOfStreamRequested{false};
  bool terminalPublished{false};
  bool clockActivated{false};
  bool retireRequested{false};
  bool retireDone{false};
  media::MediaGeneration retireRetiredGeneration{0};
  media::MediaGeneration retireInvalidationGeneration{0};
  bool closeDone{false};
  TerminalOverride terminalOverride{TerminalOverride::None};
  media::MediaGeneration terminalOverrideGeneration{0};
#if defined(WAM_NATIVE_AUDIO_SESSION_TESTING)
  bool forceCloseQuiescing{false};
#endif
};




#if defined(WAM_NATIVE_AUDIO_SESSION_TESTING)
struct NativeAudioRenderCoreTestAccess {
  static void setAfterPreflightHook(
      NativeAudioRenderCore& core,
      NativeAudioRenderCore::TestHook hook,
      void* context) noexcept {
    core.after_preflight_hook_ = hook;
    core.after_preflight_context_ = context;
  }
};

NativeAudioSubmitResult NativeAudioSessionTestAccess::occupyConverter(
    NativeAudioSession& session, media::MediaSample&& sample) noexcept {
  try {
    return session.control_->converter.submit(std::move(sample), nullptr);
  } catch (...) {
    return NativeAudioSubmitResult::Failed;
  }
}

void NativeAudioSessionTestAccess::setAfterRenderPreflightHook(
    NativeAudioSession& session, CallbackHook hook,
    void* context) noexcept {
  NativeAudioRenderCoreTestAccess::setAfterPreflightHook(
      session.control_->renderCore, hook, context);
}

void NativeAudioSessionTestAccess::stageFlushAfterStop(
    NativeAudioSession& session,
    media::MediaGeneration retiredGeneration,
    media::MediaGeneration nextGeneration,
    media::NativeMediaGenerationTimeline timeline,
    NativeAudioGenerationTimeline converterTimeline,
    media::MediaTime mediaOrigin,
    std::int64_t floorFrame) noexcept {
  NativeAudioSessionControl& control = *session.control_;
  control.lifecycle = SessionLifecycle::Flush;
  control.flushStage = FlushStage::Reset;
  control.lifecycleRetired = retiredGeneration;
  control.lifecycleTarget = nextGeneration;
  control.highestExposedGeneration = nextGeneration;
  control.lifecycleTimeline = timeline;
  control.lifecyclePlan = {converterTimeline, timeline.audioWindow.decodeStart,
                           mediaOrigin,
                           timeline.presentationFloor, floorFrame,
                           control.sampleRate};
  control.requestedPaused = true;
  control.renderCore.setPaused(true);
  control.state = NativeAudioSessionState::Flushing;
}

void NativeAudioSessionTestAccess::forceCloseQuiescing(
    NativeAudioSession& session, bool enabled) noexcept {
  session.control_->forceCloseQuiescing = enabled;
}
#endif

namespace {

// Gives one session's slot in the process envelope back, after that session
// proved a Done close. claimHeld makes this single-shot per graph, which the
// count now depends on: the envelope used to be a bool, where a second release
// was a no-op, and is now an integer, where a second release would invent a
// slot and let N + 1 sessions live at once. A session that closes Done while
// sitting in quarantine also vacates its slot here -- the registry only holds
// graphs that still owe a Done close.
void releaseClaim(NativeAudioSessionControl& control) noexcept {
  std::lock_guard<std::mutex> lock(gSessionMutex);
  if (!control.claimHeld) {
    return;
  }
  for (std::shared_ptr<NativeAudioSessionControl>& slot : gSessionQuarantine) {
    if (slot.get() == &control) {
      slot.reset();
      break;
    }
  }
  control.claimHeld = false;
  --gRetainedSessions;
}

// Moves a graph whose owner could not prove a Done close into the registry, so
// a device callback still inside the bridge keeps a live graph under it. The
// envelope count is deliberately unchanged: the graph is still charged, it has
// only swapped a NativeAudioSession owner for the registry until
// recoverQuarantined() drives it to Done.
void quarantine(
    const std::shared_ptr<NativeAudioSessionControl>& control) noexcept {
  if (control == nullptr || !control->claimHeld || control->closeDone) {
    return;
  }
  std::lock_guard<std::mutex> lock(gSessionMutex);
  // A free slot always exists here: quarantined graphs are a subset of the
  // gRetainedSessions charged against the envelope, and this graph still holds
  // its own claim (claimHeld above) while not yet occupying a slot, so at most
  // kMaximumConcurrentPlayerWindows - 1 slots can be taken.
  for (std::shared_ptr<NativeAudioSessionControl>& slot : gSessionQuarantine) {
    if (slot == nullptr) {
      slot = control;
      saturatingIncrement(gQuarantineTransfers);
      return;
    }
  }
}

[[nodiscard]] const char* outputFailureName(
    NativeAudioOutputFailure failure) noexcept {
  switch (failure) {
  case NativeAudioOutputFailure::None: return "None";
  case NativeAudioOutputFailure::InvalidConfiguration:
    return "InvalidConfiguration";
  case NativeAudioOutputFailure::ComponentUnavailable:
    return "ComponentUnavailable";
  case NativeAudioOutputFailure::InstanceCreationFailed:
    return "InstanceCreationFailed";
  case NativeAudioOutputFailure::DeviceFormatQueryFailed:
    return "DeviceFormatQueryFailed";
  case NativeAudioOutputFailure::DeviceRateMismatch:
    return "DeviceRateMismatch";
  case NativeAudioOutputFailure::DeviceListenerInstallationFailed:
    return "DeviceListenerInstallationFailed";
  case NativeAudioOutputFailure::DeviceListenerRemovalFailed:
    return "DeviceListenerRemovalFailed";
  case NativeAudioOutputFailure::MaximumFramesConfigurationFailed:
    return "MaximumFramesConfigurationFailed";
  case NativeAudioOutputFailure::ClientFormatConfigurationFailed:
    return "ClientFormatConfigurationFailed";
  case NativeAudioOutputFailure::RenderCoreActivationFailed:
    return "RenderCoreActivationFailed";
  case NativeAudioOutputFailure::CallbackInstallationFailed:
    return "CallbackInstallationFailed";
  case NativeAudioOutputFailure::InitializationFailed:
    return "InitializationFailed";
  case NativeAudioOutputFailure::StartFailed: return "StartFailed";
  case NativeAudioOutputFailure::StopFailed: return "StopFailed";
  case NativeAudioOutputFailure::UninitializationFailed:
    return "UninitializationFailed";
  case NativeAudioOutputFailure::CallbackDetachmentFailed:
    return "CallbackDetachmentFailed";
  case NativeAudioOutputFailure::InstanceDisposalFailed:
    return "InstanceDisposalFailed";
  case NativeAudioOutputFailure::InvalidCallbackBuffer:
    return "InvalidCallbackBuffer";
  case NativeAudioOutputFailure::InvalidCallbackTimestamp:
    return "InvalidCallbackTimestamp";
  case NativeAudioOutputFailure::ReentrantCallback:
    return "ReentrantCallback";
  case NativeAudioOutputFailure::FrameCursorOverflow:
    return "FrameCursorOverflow";
  case NativeAudioOutputFailure::RenderCoreFailed: return "RenderCoreFailed";
  case NativeAudioOutputFailure::NativeException: return "NativeException";
  case NativeAudioOutputFailure::DeviceBufferFramesUnsupported:
    return "DeviceBufferFramesUnsupported";
  }
  return "Unknown";
}

[[nodiscard]] const char* renderFailureName(
    NativeAudioRenderFailure failure) noexcept {
  switch (failure) {
  case NativeAudioRenderFailure::None: return "None";
  case NativeAudioRenderFailure::InvalidInput: return "InvalidInput";
  case NativeAudioRenderFailure::ReentrantCallback:
    return "ReentrantCallback";
  case NativeAudioRenderFailure::ResumeRejected: return "ResumeRejected";
  case NativeAudioRenderFailure::RingContractViolation:
    return "RingContractViolation";
  case NativeAudioRenderFailure::ClockCommitFailed:
    return "ClockCommitFailed";
  case NativeAudioRenderFailure::StretchStageFailed:
    return "StretchStageFailed";
  }
  return "Unknown";
}

[[nodiscard]] const char* sessionFailureName(
    NativeAudioSessionFailure failure) noexcept {
  switch (failure) {
  case NativeAudioSessionFailure::None: return "None";
  case NativeAudioSessionFailure::InvalidDependency:
    return "InvalidDependency";
  case NativeAudioSessionFailure::OutputUnavailable:
    return "OutputUnavailable";
  case NativeAudioSessionFailure::ConverterConfiguration:
    return "ConverterConfiguration";
  case NativeAudioSessionFailure::ClockActivation: return "ClockActivation";
  case NativeAudioSessionFailure::OutputConfiguration:
    return "OutputConfiguration";
  case NativeAudioSessionFailure::Converter: return "Converter";
  case NativeAudioSessionFailure::Output: return "Output";
  case NativeAudioSessionFailure::Discontinuity: return "Discontinuity";
  case NativeAudioSessionFailure::ConsumerProtocol: return "ConsumerProtocol";
  case NativeAudioSessionFailure::RingTransition: return "RingTransition";
  case NativeAudioSessionFailure::ClockTransition: return "ClockTransition";
  case NativeAudioSessionFailure::OutputActivation:
    return "OutputActivation";
  case NativeAudioSessionFailure::TerminalPublication:
    return "TerminalPublication";
  }
  return "Unknown";
}

// Names the gate that actually refused, for every audio result that would
// otherwise reach the dispatcher's failure line carrying nothing. The two
// leaves that can fail without an error out-parameter are the output
// AudioUnit and the render core, and only this session can see either, so it
// is the only place the text can be composed at all. Cached in the control
// block so failureText() can hand out a stable reference.
void publishFailureText(NativeAudioSessionControl& control,
                        std::string* error) noexcept {
  try {
    const NativeAudioOutputFailure outputFailure =
        control.output != nullptr ? control.output->facts().failure
                                  : NativeAudioOutputFailure::None;
    const NativeAudioRenderFailure renderFailure = control.renderCore.failure();
    if (outputFailure != NativeAudioOutputFailure::None) {
      control.failureText =
          std::string("audio output: ") + outputFailureName(outputFailure) +
          " (osStatus " +
          std::to_string(
              static_cast<long long>(control.output->facts().osStatus)) +
          ")";
    } else if (renderFailure != NativeAudioRenderFailure::None) {
      control.failureText =
          std::string("audio render core: ") + renderFailureName(renderFailure);
    } else if (control.failure != NativeAudioSessionFailure::None) {
      control.failureText =
          std::string("audio session: ") + sessionFailureName(control.failure);
    } else {
      return;
    }
    if (error != nullptr && error->empty()) {
      *error = control.failureText;
    }
  } catch (...) {
    // A diagnostic string must never change the failure already decided.
  }
}

[[nodiscard]] bool outputFailed(NativeAudioSessionControl& control) noexcept {
  if (control.output != nullptr && control.output->facts().fatal) {
    control.latch(NativeAudioSessionFailure::Output);
    return true;
  }
  if (control.renderCore.failure() != NativeAudioRenderFailure::None) {
    control.latch(NativeAudioSessionFailure::Output);
    return true;
  }
  return false;
}

void clearOutputWake(NativeAudioSessionControl& control) noexcept {
  control.outputWake.pending->store(false, std::memory_order_release);
}

[[nodiscard]] bool settleStopped(
    NativeAudioSessionControl& control,
    media::MediaGeneration generation) noexcept {
  if (!control.clock.pause(generation) ||
      !control.renderCore.settlePausedAfterStop(generation)) {
    control.latch(NativeAudioSessionFailure::ClockTransition);
    return false;
  }
  return true;
}

[[nodiscard]] bool verifyPublishedOrigin(
    NativeAudioSessionControl& control) noexcept {
  const NativeAudioConverterStats stats = control.converter.stats();
  if (stats.publishedPcmFrames == 0) {
    return true;
  }
  if (!stats.firstPublishedFrameKnown ||
      stats.firstPublishedFrame != control.presentationFloorFrame) {
    control.latch(NativeAudioSessionFailure::Converter);
    return false;
  }
  return true;
}

[[nodiscard]] bool publishTerminal(
    NativeAudioSessionControl& control) noexcept {
  const NativeAudioConverterStats stats = control.converter.stats();
  if (!stats.drained || !verifyPublishedOrigin(control)) {
    if (!stats.drained) {
      control.latch(NativeAudioSessionFailure::ConsumerProtocol);
    }
    return false;
  }
  if (!control.terminalPublished) {
    // The generation's terminal is the frame after its last PRESENTED frame.
    // Real PCM occupies [leadInSilenceFrames, leadInSilenceFrames +
    // publishedPcmFrames); container-declared silence may precede it, and may
    // follow it when the source states a presentation end past the audio's own
    // end. Both spans are cursor frames the clock passes, so both belong in
    // the terminal. With no declared silence this is publishedPcmFrames
    // verbatim.
    std::uint64_t terminalFrame =
        control.leadInSilenceFrames + stats.publishedPcmFrames;
    if (control.presentationEndFrame > control.mediaOriginFrame) {
      const auto declaredEnd = static_cast<std::uint64_t>(
          control.presentationEndFrame - control.mediaOriginFrame);
      if (declaredEnd > terminalFrame) {
        terminalFrame = declaredEnd;
      }
    }
    if (!control.renderCore.publishTerminalFrame(control.generation,
                                                 terminalFrame)) {
      control.latch(NativeAudioSessionFailure::TerminalPublication);
      return false;
    }
    control.terminalPublished = true;
  }
  return true;
}

[[nodiscard]] bool terminalObserved(
    const NativeAudioSessionControl& control) noexcept {
  return control.terminalPublished &&
         control.renderCore.terminalObservation().generation ==
             control.generation;
}

[[nodiscard]] media::NativeMediaConsumeResult mapPumpForCapacity(
    NativeAudioSessionControl& control,
    NativeAudioPumpResult result) noexcept {
  switch (result) {
  case NativeAudioPumpResult::Published:
    return verifyPublishedOrigin(control)
               ? media::NativeMediaConsumeResult::Draining
               : media::NativeMediaConsumeResult::Failed;
  case NativeAudioPumpResult::Progress:
    return media::NativeMediaConsumeResult::Draining;
  case NativeAudioPumpResult::Backpressure:
    return media::NativeMediaConsumeResult::Backpressure;
  case NativeAudioPumpResult::NeedsInput:
    return media::NativeMediaConsumeResult::Accepted;
  case NativeAudioPumpResult::StaleGeneration:
    return media::NativeMediaConsumeResult::StaleGeneration;
  case NativeAudioPumpResult::Drained:
    control.latch(NativeAudioSessionFailure::ConsumerProtocol);
    return media::NativeMediaConsumeResult::Failed;
  case NativeAudioPumpResult::NotConfigured:
  case NativeAudioPumpResult::Failed:
    control.latch(NativeAudioSessionFailure::Converter);
    return media::NativeMediaConsumeResult::Failed;
  }
  control.latch(NativeAudioSessionFailure::ConsumerProtocol);
  return media::NativeMediaConsumeResult::Failed;
}

[[nodiscard]] media::NativeMediaConsumerProgress mapPumpForDrain(
    NativeAudioSessionControl& control,
    NativeAudioPumpResult result) noexcept {
  switch (result) {
  case NativeAudioPumpResult::Published:
    return verifyPublishedOrigin(control)
               ? media::NativeMediaConsumerProgress::Progress
               : media::NativeMediaConsumerProgress::Failed;
  case NativeAudioPumpResult::Progress:
    return media::NativeMediaConsumerProgress::Progress;
  case NativeAudioPumpResult::Backpressure:
    return media::NativeMediaConsumerProgress::Quiescing;
  case NativeAudioPumpResult::NeedsInput:
    return media::NativeMediaConsumerProgress::Done;
  case NativeAudioPumpResult::StaleGeneration:
    return media::NativeMediaConsumerProgress::StaleGeneration;
  case NativeAudioPumpResult::Drained:
    if (!control.endOfStreamRequested || !publishTerminal(control)) {
      return media::NativeMediaConsumerProgress::Failed;
    }
    return terminalObserved(control)
               ? media::NativeMediaConsumerProgress::Done
               : media::NativeMediaConsumerProgress::Quiescing;
  case NativeAudioPumpResult::NotConfigured:
  case NativeAudioPumpResult::Failed:
    control.latch(NativeAudioSessionFailure::Converter);
    return media::NativeMediaConsumerProgress::Failed;
  }
  control.latch(NativeAudioSessionFailure::ConsumerProtocol);
  return media::NativeMediaConsumerProgress::Failed;
}

[[nodiscard]] NativeAudioSessionProgress mapOutputProgress(
    NativeAudioSessionControl& control,
    NativeAudioOutputProgress progress,
    NativeAudioSessionFailure failure) noexcept {
  switch (progress) {
  case NativeAudioOutputProgress::Done:
    return NativeAudioSessionProgress::Done;
  case NativeAudioOutputProgress::Quiescing:
    return NativeAudioSessionProgress::Quiescing;
  case NativeAudioOutputProgress::Invalid:
    control.latch(failure);
    return NativeAudioSessionProgress::Invalid;
  case NativeAudioOutputProgress::Failed:
    control.latch(failure);
    return NativeAudioSessionProgress::Failed;
  }
  control.latch(failure);
  return NativeAudioSessionProgress::Failed;
}

// Drives an already-begun pause suspend to its Done stop proof. From the
// first stop attempt onward the AudioUnit is stopped and render admission is
// revoked, so no owner operation may treat the output as running until this
// returns Done: the only thing still outstanding is the drain of a callback
// that entered before admission closed. settleStopped() needs that drain,
// because settlePausedAfterStop() takes the render core's callback gate.
[[nodiscard]] NativeAudioSessionProgress completeOutputSuspend(
    NativeAudioSessionControl& control) noexcept {
  const NativeAudioSessionProgress stopped = mapOutputProgress(
      control, control.output->stop(), NativeAudioSessionFailure::Output);
  if (stopped != NativeAudioSessionProgress::Done) {
    return stopped;
  }
  if (!settleStopped(control, control.generation)) {
    return NativeAudioSessionProgress::Failed;
  }
  control.outputSuspension = OutputSuspension::Suspended;
  control.state = NativeAudioSessionState::Ready;
  return NativeAudioSessionProgress::Done;
}

// Outcome of one reconciliation pass over an outstanding StreamFormat
// notification. Idle means there was nothing to do.
enum class DeviceReconcile : std::uint8_t {
  Idle,
  Progressed,
  Failed,
};

// The owner-thread half of the StreamFormat listener, and the reason a
// notification no longer ends native audio. The listener revoked render
// admission without knowing whether the device actually changed; this decides.
//
// A rate that really moved fails closed, exactly as start()'s own revalidation
// does. An unchanged rate is recovered by reusing the pause-suspend lever's
// machinery verbatim: freeze the graph, take the output to a proved stop, then
// start it again. Reuse is not incidental. A device that stops under a running
// graph must not leave the authoritative clock free-running across the silent
// gap, and settlePausedAfterStop() is what reconciles the callback-local
// running fact and forces the next callback to establish a fresh host-tick
// anchor. Doing anything cheaper would resume audio against a clock that had
// advanced while nothing was rendering.
[[nodiscard]] DeviceReconcile reconcileOutputDeviceChange(
    NativeAudioSessionControl& control) noexcept {
  if (control.output == nullptr) {
    return DeviceReconcile::Idle;
  }
  const NativeAudioOutputFacts facts = control.output->facts();
  if (facts.fatal) {
    // Already latched by something else; outputFailed() owns the report.
    return DeviceReconcile::Idle;
  }
  if (!facts.deviceChangePending && !control.deviceChangeResumePending) {
    return DeviceReconcile::Idle;
  }
  // Teardown owns the output outright once any of these is in flight, and a
  // retiring/closing session has no interest in resuming a device.
  if (control.retireRequested || control.closeDone ||
      control.lifecycle != SessionLifecycle::None ||
      control.terminalOverride != TerminalOverride::None ||
      (control.state != NativeAudioSessionState::Started &&
       control.state != NativeAudioSessionState::Ready)) {
    control.deviceChangeResumePending = false;
    return DeviceReconcile::Idle;
  }

  if (facts.deviceChangePending) {
    if (control.state == NativeAudioSessionState::Started &&
        control.outputSuspension == OutputSuspension::None) {
      // The device went out from under a running graph. Freeze it the way a
      // pause suspend does, and remember that this freeze was not the user's
      // idea so the resume below can undo it.
      control.deviceChangeResumePending = true;
      control.renderCore.setPaused(true);
      if (!control.clock.pause(control.generation)) {
        control.latch(NativeAudioSessionFailure::ClockTransition);
        return DeviceReconcile::Failed;
      }
      control.outputSuspension = OutputSuspension::Stopping;
    }
    const NativeAudioOutputProgress reconciled =
        control.output->reconcileDeviceChange();
    if (reconciled == NativeAudioOutputProgress::Quiescing) {
      return DeviceReconcile::Progressed;
    }
    if (reconciled != NativeAudioOutputProgress::Done) {
      control.latch(NativeAudioSessionFailure::Output);
      return DeviceReconcile::Failed;
    }
    // reconcileDeviceChange() proved a Done stop; finish the suspend
    // bookkeeping so the session and the output agree the device is idle.
    if (control.outputSuspension == OutputSuspension::Stopping) {
      if (!settleStopped(control, control.generation)) {
        return DeviceReconcile::Failed;
      }
      control.outputSuspension = OutputSuspension::Suspended;
      control.state = NativeAudioSessionState::Ready;
    }
    return DeviceReconcile::Progressed;
  }

  // The device is valid again. Resume only a freeze this reconciliation
  // caused: a user pause that happened to overlap it keeps the device idle.
  if (!control.deviceChangeResumePending) {
    return DeviceReconcile::Idle;
  }
  if (control.outputSuspension != OutputSuspension::Suspended ||
      control.requestedPaused) {
    control.deviceChangeResumePending = false;
    return DeviceReconcile::Idle;
  }
  // Same admission rule start() applies: a running output that cannot be fed
  // would underrun on its very first callback.
  const NativePcmRing::ReadableFramesResult readable =
      control.ring.readableFrames(control.generation);
  if (readable.frames == 0 && !control.terminalPublished) {
    return DeviceReconcile::Progressed;
  }
  control.renderCore.setPaused(false);
  const NativeAudioSessionProgress started = mapOutputProgress(
      control, control.output->start(), NativeAudioSessionFailure::Output);
  if (started == NativeAudioSessionProgress::Failed ||
      started == NativeAudioSessionProgress::Invalid) {
    return DeviceReconcile::Failed;
  }
  if (started != NativeAudioSessionProgress::Done) {
    return DeviceReconcile::Progressed;
  }
  control.outputSuspension = OutputSuspension::None;
  control.state = NativeAudioSessionState::Started;
  control.deviceChangeResumePending = false;
  if (control.deviceChangeRecoveries !=
      std::numeric_limits<std::uint64_t>::max()) {
    ++control.deviceChangeRecoveries;
  }
  // Always on, and one grep-able line. A device notification used to end
  // native audio outright and report nothing; a recovery that leaves no trace
  // would make the same class of problem just as invisible the next time.
  // Bounded: one line per notification, and notifications are rare.
  std::fprintf(stderr,
               "WAM: audio device republished its format; native audio "
               "recovered (notifications=%llu recoveries=%llu)\n",
               static_cast<unsigned long long>(
                   control.output->facts().deviceChangeSerial),
               static_cast<unsigned long long>(control.deviceChangeRecoveries));
  std::fflush(stderr);
  return DeviceReconcile::Progressed;
}

[[nodiscard]] media::NativeMediaConsumerProgress mapLifecycleProgress(
    NativeAudioSessionProgress progress) noexcept {
  switch (progress) {
  case NativeAudioSessionProgress::Done:
    return media::NativeMediaConsumerProgress::Done;
  case NativeAudioSessionProgress::Quiescing:
  case NativeAudioSessionProgress::WaitingForData:
    return media::NativeMediaConsumerProgress::Quiescing;
  case NativeAudioSessionProgress::Invalid:
  case NativeAudioSessionProgress::Failed:
    return media::NativeMediaConsumerProgress::Failed;
  }
  return media::NativeMediaConsumerProgress::Failed;
}

} // namespace

NativeAudioSession::NativeAudioSession(
    std::shared_ptr<NativeAudioSessionControl> control) noexcept
    : control_(std::move(control)) {}

std::unique_ptr<NativeAudioSession> NativeAudioSession::create(
    media::MediaGeneration initialGeneration,
    NativeAudioSessionDependencies dependencies) noexcept {
  if (initialGeneration == 0 || !validDependencies(dependencies)) {
    saturatingIncrement(gRejectedCreates);
    return {};
  }
  {
    std::lock_guard<std::mutex> lock(gSessionMutex);
    // The envelope is full when N sessions are already charged against it,
    // live or quarantined. Refuse quietly: an N+1'th AudioUnit graph would
    // overrun the per-process resource accounting that
    // kMaximumConcurrentPlayerWindows exists to bound, and the owner is meant
    // to report "no more windows" rather than retry.
    if (gRetainedSessions >= kMaximumConcurrentPlayerWindows) {
      saturatingIncrement(gRejectedCreates);
      return {};
    }
    ++gRetainedSessions;
  }

  try {
    auto control = std::make_shared<NativeAudioSessionControl>(
        initialGeneration, std::move(dependencies.externalLifetime),
        dependencies.hostClock, dependencies.outputCalls,
        dependencies.outputWake, std::move(dependencies.converterBackend));
    return std::unique_ptr<NativeAudioSession>(
        new NativeAudioSession(std::move(control)));
  } catch (...) {
    // No control block exists, so nothing is charged: hand the reserved slot
    // straight back instead of leaving a permanent hole in the envelope.
    std::lock_guard<std::mutex> lock(gSessionMutex);
    --gRetainedSessions;
    saturatingIncrement(gRejectedCreates);
    return {};
  }
}

NativeAudioSession::~NativeAudioSession() {
  if (control_ == nullptr) {
    return;
  }
  if (close() != media::NativeMediaConsumerProgress::Done) {
    quarantine(control_);
  }
  control_.reset();
}

std::unique_ptr<NativeAudioSession>
NativeAudioSession::recoverQuarantined() noexcept {
  std::lock_guard<std::mutex> lock(gSessionMutex);
  // First occupied slot wins. The registry is a bag of graphs that still owe a
  // Done close, not a queue: recovery order carries no meaning, and a caller
  // draining quarantine simply repeats this until it returns nullptr. The
  // envelope count is unchanged -- ownership moves back to a
  // NativeAudioSession, the charge stays until that owner reaches Done.
  for (std::shared_ptr<NativeAudioSessionControl>& slot : gSessionQuarantine) {
    if (slot == nullptr) {
      continue;
    }
    try {
      auto recovered =
          std::unique_ptr<NativeAudioSession>(new NativeAudioSession(slot));
      slot.reset();
      saturatingIncrement(gQuarantineRecoveries);
      return recovered;
    } catch (...) {
      return {};
    }
  }
  return {};
}

NativeAudioSessionQuarantineFacts
NativeAudioSession::quarantineFacts() noexcept {
  NativeAudioSessionQuarantineFacts result;
  result.rejectedCreates = gRejectedCreates.load(std::memory_order_relaxed);
  result.transfers =
      gQuarantineTransfers.load(std::memory_order_relaxed);
  result.recoveries =
      gQuarantineRecoveries.load(std::memory_order_relaxed);
  std::lock_guard<std::mutex> lock(gSessionMutex);
  // claimed means "the envelope is holding at least one session", which is
  // what the single-claim bool meant; quarantined means "at least one slot is
  // occupied", i.e. there is still a graph the owner must drive to Done.
  // Neither reports occupancy, because callers act by looping recovery rather
  // than by counting.
  result.claimed = gRetainedSessions != 0;
  result.quarantined =
      std::any_of(gSessionQuarantine.begin(), gSessionQuarantine.end(),
                  [](const std::shared_ptr<NativeAudioSessionControl>& slot) {
                    return slot != nullptr;
                  });
  return result;
}

media::NativeMediaConsumeResult NativeAudioSession::configure(
    const media::MediaTrackDescriptor& track,
    media::MediaGeneration generation,
    const media::NativeMediaGenerationTimeline& timeline,
    std::string* error) {
  if (control_ == nullptr) {
    assignError(error, "native audio session is unavailable");
    return media::NativeMediaConsumeResult::Failed;
  }
  NativeAudioSessionControl& control = *control_;
  if (generation != control.generation) {
    return media::NativeMediaConsumeResult::StaleGeneration;
  }
  if (control.state != NativeAudioSessionState::Fresh) {
    assignError(error, "native audio session configure is not fresh");
    return media::NativeMediaConsumeResult::Failed;
  }
  // A configure call exposes its generation even when pure preflight rejects
  // it or a later resource step fails. Router retirement must name that exact
  // generation; a never-called port alone retains exposure zero.
  control.highestExposedGeneration = generation;

  const std::optional<TimelinePlan> plan =
      preflight(track, generation, timeline);
  if (!plan) {
    control.state = NativeAudioSessionState::Unsupported;
    assignError(error, "audio track or timeline is outside native v1");
    return media::NativeMediaConsumeResult::Unsupported;
  }

  control.state = NativeAudioSessionState::Configuring;
  control.resourceEntered = true;
  clearOutputWake(control);
  control.output = NativeAudioOutput::create(
      control.renderCore, control.outputCalls, control.outputWake);
  if (control.output == nullptr) {
    control.latch(NativeAudioSessionFailure::OutputUnavailable);
    assignError(error, "native audio output is unavailable");
    return media::NativeMediaConsumeResult::Failed;
  }

  if (!control.converter.configure(track, generation, plan->converter,
                                   error)) {
    control.latch(NativeAudioSessionFailure::ConverterConfiguration);
    return media::NativeMediaConsumeResult::Failed;
  }
  const auto clockSeconds = media::mediaTimeSeconds(plan->clockPosition);
  if (!clockSeconds ||
      !control.clock.anchor(generation, *clockSeconds, 1.0, false)) {
    control.latch(NativeAudioSessionFailure::ClockActivation);
    assignError(error, "native audio clock activation failed");
    return media::NativeMediaConsumeResult::Failed;
  }
  control.clockActivated = true;

  control.renderCore.setPaused(true);
  // The callback controls already exist in Fresh. Re-publish the cached pair
  // at the resource boundary so configure can never replace a preflight UI
  // request with hard-coded defaults. This is not a new owner request and
  // therefore does not mint a control revision.
  control.renderCore.setGain(control.requestedGain);
  control.renderCore.setMuted(control.requestedMuted);
  control.appliedGain = control.requestedGain;
  control.appliedMuted = control.requestedMuted;
  control.appliedControlRevision = control.controlRevision;
  const NativeAudioOutputProgress outputConfigured =
      control.output->configure({generation, 0, plan->mediaOrigin,
                                 control.hostClock.ticksPerSecond,
                                 plan->sampleRate,
                                 plan->clockPosition,
                                 plan->declaredSilence});
  // The stream rate is known only from here on, so a cached non-unit rate can
  // only now be turned into a real stretch stage. A refusal drops back to the
  // unit rate rather than failing the whole configure: playing at 1x is a
  // better outcome than not playing.
  if (outputConfigured == NativeAudioOutputProgress::Done) {
    // The preference is republished unconditionally, exactly like the cached
    // gain/mute pair: it cannot fail, and at the unit rate it applies nothing.
    control.output->setPreservePitch(control.requestedPreservePitch);
    if (!control.requestedRate.unity() &&
        !control.output->setRate(control.requestedRate)) {
      control.requestedRate = NativePlaybackRate{};
    }
  }
  if (outputConfigured != NativeAudioOutputProgress::Done) {
    control.latch(NativeAudioSessionFailure::OutputConfiguration);
    assignError(error, "native audio output configuration failed");
    return media::NativeMediaConsumeResult::Failed;
  }

  control.track = track.id;
  control.sampleRate = plan->sampleRate;
  control.audioMayPrecedeStreamOrigin = codecStartsBeforeStreamOrigin(track);
  control.trimAfterCeiling = plan->converter.trimAfterCeiling;
  control.presentationCeiling = plan->converter.presentationCeiling;
  control.presentationFloorFrame = plan->floorFrame;
  control.mediaOriginFrame = plan->originFrame;
  control.leadInSilenceFrames = plan->leadInSilenceFrames;
  control.presentationEndFrame = plan->presentationEndFrame;
  control.mediaOrigin = plan->mediaOrigin;
  control.audioDecodeStart = plan->decodeStart;
  control.firstAudioSampleAccepted = false;
  control.timeline = timeline;
  control.converterTimeline = plan->converter;
  control.configured = true;
  control.requestedPaused = true;
  control.state = NativeAudioSessionState::Ready;
  return media::NativeMediaConsumeResult::Accepted;
}

media::NativeMediaConsumeResult NativeAudioSession::capacity(
    media::MediaGeneration generation) {
  if (control_ == nullptr) {
    return media::NativeMediaConsumeResult::Failed;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);
  if (generation != control.generation) {
    return media::NativeMediaConsumeResult::StaleGeneration;
  }
  if (!control.configured ||
      control.state == NativeAudioSessionState::Failed ||
      control.state == NativeAudioSessionState::Retiring ||
      control.state == NativeAudioSessionState::Closing ||
      control.state == NativeAudioSessionState::Closed ||
      control.state == NativeAudioSessionState::Cancelled ||
      outputFailed(control)) {
    return media::NativeMediaConsumeResult::Failed;
  }
  if (control.endOfStreamRequested) {
    return terminalObserved(control)
               ? media::NativeMediaConsumeResult::Drained
               : media::NativeMediaConsumeResult::Backpressure;
  }
  return mapPumpForCapacity(control, control.converter.pump(nullptr));
}

media::NativeMediaConsumeResult NativeAudioSession::trySample(
    media::NativeMediaSampleDelivery& delivery,
    std::string* error) {
  if (control_ == nullptr) {
    return media::NativeMediaConsumeResult::Failed;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);
  const media::MediaSample& sample = delivery.sample();
  if (sample.generation != control.generation) {
    return media::NativeMediaConsumeResult::StaleGeneration;
  }
  if (!control.configured ||
      control.endOfStreamRequested ||
      control.state == NativeAudioSessionState::Failed ||
      control.state == NativeAudioSessionState::Retiring ||
      control.state == NativeAudioSessionState::Closing ||
      control.state == NativeAudioSessionState::Closed ||
      control.state == NativeAudioSessionState::Cancelled ||
      outputFailed(control)) {
    assignError(error, "native audio session is not accepting samples");
    return media::NativeMediaConsumeResult::Failed;
  }

  if (sample.track != control.track ||
      sample.kind != media::MediaSampleKind::EncodedAudio) {
    control.latch(NativeAudioSessionFailure::Converter);
    assignError(error, "sample is not for the configured audio track");
    return media::NativeMediaConsumeResult::Failed;
  }
  if (!control.firstAudioSampleAccepted &&
      media::compareMediaTime(sample.presentationTime,
                              control.audioDecodeStart) !=
          media::MediaTimeOrder::Equal) {
    control.latch(NativeAudioSessionFailure::ConsumerProtocol);
    assignError(error,
                "first audio sample does not match source-proved decode start");
    return media::NativeMediaConsumeResult::Failed;
  }

  NativeAudioPrepareOutcome prepared = control.converter.prepare(sample, error);
  switch (prepared.result) {
  case NativeAudioSubmitResult::Backpressure:
    return media::NativeMediaConsumeResult::Backpressure;
  case NativeAudioSubmitResult::StaleGeneration:
    return media::NativeMediaConsumeResult::StaleGeneration;
  case NativeAudioSubmitResult::Invalid:
  case NativeAudioSubmitResult::Failed:
    control.latch(NativeAudioSessionFailure::Converter);
    return media::NativeMediaConsumeResult::Failed;
  case NativeAudioSubmitResult::Accepted:
    break;
  }

  media::MediaSample owned = delivery.take();
  if (!control.converter.commitPrepared(std::move(prepared.prepared),
                                        std::move(owned))) {
    control.latch(NativeAudioSessionFailure::ConsumerProtocol);
    return media::NativeMediaConsumeResult::Accepted;
  }
  control.firstAudioSampleAccepted = true;
  const NativeAudioPumpResult pumped = control.converter.pump(error);
  if (pumped == NativeAudioPumpResult::Published) {
    static_cast<void>(verifyPublishedOrigin(control));
  } else if (pumped == NativeAudioPumpResult::Failed ||
             pumped == NativeAudioPumpResult::NotConfigured) {
    control.latch(NativeAudioSessionFailure::Converter);
  } else if (pumped == NativeAudioPumpResult::StaleGeneration) {
    control.latch(NativeAudioSessionFailure::ConsumerProtocol);
  }
  return media::NativeMediaConsumeResult::Accepted;
}

media::NativeMediaConsumeResult NativeAudioSession::discontinuity(
    const media::MediaDiscontinuity& discontinuity,
    std::string* error) {
  if (control_ == nullptr) {
    return media::NativeMediaConsumeResult::Failed;
  }
  NativeAudioSessionControl& control = *control_;
  if (control.retireRequested) {
    return media::NativeMediaConsumeResult::Failed;
  }
  if (discontinuity.generation != control.generation) {
    return media::NativeMediaConsumeResult::StaleGeneration;
  }
  control.latch(NativeAudioSessionFailure::Discontinuity);
  assignError(error, "audio discontinuities are outside native v1");
  return media::NativeMediaConsumeResult::Failed;
}

media::NativeMediaConsumeResult NativeAudioSession::endOfStream(
    const media::MediaEndOfStream& end,
    std::string* error) {
  if (control_ == nullptr) {
    return media::NativeMediaConsumeResult::Failed;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);
  if (end.generation != control.generation) {
    return media::NativeMediaConsumeResult::StaleGeneration;
  }
  if (!control.configured ||
      end.track != control.track ||
      control.state == NativeAudioSessionState::Failed ||
      control.state == NativeAudioSessionState::Retiring ||
      outputFailed(control)) {
    control.latch(NativeAudioSessionFailure::ConsumerProtocol);
    return media::NativeMediaConsumeResult::Failed;
  }
  control.endOfStreamRequested = true;
  const NativeAudioPumpResult result =
      control.converter.endOfStream(end.generation, error);
  switch (result) {
  case NativeAudioPumpResult::Published:
    return verifyPublishedOrigin(control)
               ? media::NativeMediaConsumeResult::Draining
               : media::NativeMediaConsumeResult::Failed;
  case NativeAudioPumpResult::Progress:
    return media::NativeMediaConsumeResult::Draining;
  case NativeAudioPumpResult::Backpressure:
    return media::NativeMediaConsumeResult::Backpressure;
  case NativeAudioPumpResult::Drained:
    if (!publishTerminal(control)) {
      return media::NativeMediaConsumeResult::Failed;
    }
    return terminalObserved(control)
               ? media::NativeMediaConsumeResult::Drained
               : media::NativeMediaConsumeResult::Draining;
  case NativeAudioPumpResult::StaleGeneration:
    return media::NativeMediaConsumeResult::StaleGeneration;
  case NativeAudioPumpResult::NeedsInput:
  case NativeAudioPumpResult::NotConfigured:
  case NativeAudioPumpResult::Failed:
    control.latch(NativeAudioSessionFailure::Converter);
    return media::NativeMediaConsumeResult::Failed;
  }
  control.latch(NativeAudioSessionFailure::ConsumerProtocol);
  return media::NativeMediaConsumeResult::Failed;
}

media::NativeMediaConsumerProgress NativeAudioSession::drain(
    media::MediaGeneration generation,
    std::string* error) {
  if (control_ == nullptr) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);
  if (generation != control.generation) {
    return media::NativeMediaConsumerProgress::StaleGeneration;
  }
  if (!control.configured ||
      control.state == NativeAudioSessionState::Failed ||
      control.state == NativeAudioSessionState::Retiring ||
      control.state == NativeAudioSessionState::Closing ||
      control.state == NativeAudioSessionState::Closed ||
      control.state == NativeAudioSessionState::Cancelled) {
    publishFailureText(control, error);
    return media::NativeMediaConsumerProgress::Failed;
  }
  // The dispatcher pumps drain() on every wake, and the StreamFormat listener
  // signals exactly that wake, so this is the seam where an outstanding device
  // notification is decided. It runs before outputFailed() because it is what
  // decides whether there is a failure at all.
  switch (reconcileOutputDeviceChange(control)) {
  case DeviceReconcile::Idle:
    break;
  case DeviceReconcile::Progressed:
    return media::NativeMediaConsumerProgress::Progress;
  case DeviceReconcile::Failed:
    publishFailureText(control, error);
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (outputFailed(control)) {
    publishFailureText(control, error);
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (terminalObserved(control)) {
    return media::NativeMediaConsumerProgress::Done;
  }
  return mapPumpForDrain(control, control.converter.pump(error));
}

NativeAudioSessionProgress NativeAudioSession::start() noexcept {
  if (control_ == nullptr) {
    return NativeAudioSessionProgress::Invalid;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);
  if (control.state == NativeAudioSessionState::Started &&
      control.outputSuspension == OutputSuspension::None) {
    return NativeAudioSessionProgress::Done;
  }
  // A suspend that has begun already stopped the device; finish its proof
  // before reopening admission, or start() would reopen over an unsettled
  // callback-local running fact. This runs before the state gate below
  // because a suspend in flight still reports Started.
  if (control.outputSuspension == OutputSuspension::Stopping &&
      control.output != nullptr) {
    const NativeAudioSessionProgress settled = completeOutputSuspend(control);
    if (settled != NativeAudioSessionProgress::Done) {
      return settled;
    }
  }
  if (control.state != NativeAudioSessionState::Ready ||
      control.output == nullptr) {
    return NativeAudioSessionProgress::Invalid;
  }
  if (outputFailed(control)) {
    return NativeAudioSessionProgress::Failed;
  }
  const NativePcmRing::ReadableFramesResult readable =
      control.ring.readableFrames(control.generation);
  if (!control.requestedPaused && readable.frames == 0 &&
      !control.terminalPublished) {
    return NativeAudioSessionProgress::WaitingForData;
  }
  control.renderCore.setPaused(control.requestedPaused);
  const NativeAudioSessionProgress result = mapOutputProgress(
      control, control.output->start(), NativeAudioSessionFailure::Output);
  if (result == NativeAudioSessionProgress::Done) {
    control.state = NativeAudioSessionState::Started;
    control.outputSuspension = OutputSuspension::None;
  }
  return result;
}

NativeAudioSessionProgress
NativeAudioSession::setPaused(bool paused) noexcept {
  if (control_ == nullptr) {
    return NativeAudioSessionProgress::Invalid;
  }
  NativeAudioSessionControl& control = *control_;
  if ((control.state != NativeAudioSessionState::Ready &&
       control.state != NativeAudioSessionState::Started)) {
    return NativeAudioSessionProgress::Invalid;
  }
  if (outputFailed(control)) {
    return NativeAudioSessionProgress::Failed;
  }
  // A suspend that has begun owns the output until it is Done, in either
  // direction: the device is already stopped and admission already revoked,
  // so a resume that skipped this would unpause a render core that can never
  // be entered again.
  if (control.outputSuspension == OutputSuspension::Stopping &&
      control.output != nullptr) {
    const NativeAudioSessionProgress settled = completeOutputSuspend(control);
    if (settled != NativeAudioSessionProgress::Done) {
      return settled;
    }
  }
  control.requestedPaused = paused;
  control.renderCore.setPaused(paused);
  if (paused) {
    // Ready covers both a never-started output and a suspended one. In the
    // suspended case the clock is already paused, so this is the idempotent
    // early return in NativeMediaClock::pause().
    if (control.state == NativeAudioSessionState::Ready &&
        !control.clock.pause(control.generation)) {
      control.latch(NativeAudioSessionFailure::ClockTransition);
      return NativeAudioSessionProgress::Failed;
    }
    return NativeAudioSessionProgress::Done;
  }
  if (control.outputSuspension == OutputSuspension::Suspended) {
    if (control.output == nullptr) {
      control.latch(NativeAudioSessionFailure::Output);
      return NativeAudioSessionProgress::Failed;
    }
    // Same admission rule start() applies: a running output that cannot be
    // fed would underrun on its very first callback. The ring was never
    // flushed by the suspend, so this is satisfied immediately for any pause
    // that did not empty it.
    const NativePcmRing::ReadableFramesResult readable =
        control.ring.readableFrames(control.generation);
    if (readable.frames == 0 && !control.terminalPublished) {
      return NativeAudioSessionProgress::WaitingForData;
    }
    const NativeAudioSessionProgress started = mapOutputProgress(
        control, control.output->start(), NativeAudioSessionFailure::Output);
    if (started != NativeAudioSessionProgress::Done) {
      return started;
    }
    control.outputSuspension = OutputSuspension::None;
    control.state = NativeAudioSessionState::Started;
  }
  return NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress
NativeAudioSession::suspendOutputForPause() noexcept {
  if (control_ == nullptr) {
    return NativeAudioSessionProgress::Invalid;
  }
  NativeAudioSessionControl& control = *control_;
  if (control.outputSuspension == OutputSuspension::Suspended) {
    return NativeAudioSessionProgress::Done;
  }
  if (control.output == nullptr || !control.requestedPaused ||
      control.retireRequested ||
      control.lifecycle != SessionLifecycle::None ||
      control.terminalOverride != TerminalOverride::None ||
      control.state != NativeAudioSessionState::Started) {
    return NativeAudioSessionProgress::Invalid;
  }
  if (outputFailed(control)) {
    return NativeAudioSessionProgress::Failed;
  }
  // The pause must already be settled on the authoritative clock. The render
  // callback's own pause boundary is what publishes that, and it is the whole
  // reason this transition cannot move the playhead: with the clock already
  // paused, the clock.pause() inside settleStopped() takes NativeMediaClock's
  // !running early return, publishing nothing and moving nothing. Suspending
  // before the boundary would be equally exact but would freeze the clock up
  // to one device period earlier than an in-place pause does.
  const NativeMediaClockSnapshot clock = control.clock.sample();
  if (!clock.publicationCurrent || !clock.valid || clock.running ||
      clock.generation != control.generation) {
    return NativeAudioSessionProgress::Invalid;
  }
  control.outputSuspension = OutputSuspension::Stopping;
  return completeOutputSuspend(control);
}

NativeAudioSessionProgress NativeAudioSession::setGain(float gain) noexcept {
  if (control_ == nullptr) {
    return NativeAudioSessionProgress::Invalid;
  }
  NativeAudioSessionControl& control = *control_;
  if (!acceptsAudioControls(control.state)) {
    return NativeAudioSessionProgress::Invalid;
  }

  control.requestedGain = normalizedGain(gain);
  advanceControlRevision(control.controlRevision);
  control.renderCore.setGain(control.requestedGain);
  control.appliedGain = control.requestedGain;
  control.appliedMuted = control.requestedMuted;
  control.appliedControlRevision = control.controlRevision;
  return NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress NativeAudioSession::setRate(
    NativePlaybackRate rate, bool preservePitch) noexcept {
  if (control_ == nullptr || !rate.valid()) {
    return NativeAudioSessionProgress::Invalid;
  }
  NativeAudioSessionControl& control = *control_;
  if (!acceptsAudioControls(control.state)) {
    return NativeAudioSessionProgress::Invalid;
  }
  // Before configure there is no output to create a stretch unit against, so
  // the request is merely cached; configure re-publishes it exactly the way
  // it re-publishes the cached gain/mute pair.
  // Pitch is published first and cached unconditionally: it cannot fail, and
  // doing it first means the callback never latches the new rate while the
  // old preference is still in force. A refused rate therefore leaves the
  // previous rate running at the newly requested pitch behaviour, which is
  // the only combination that is true of what the engine is doing.
  control.requestedPreservePitch = preservePitch;
  if (control.output != nullptr) {
    control.output->setPreservePitch(preservePitch);
    if (!control.output->setRate(rate)) {
      return NativeAudioSessionProgress::Invalid;
    }
  }
  control.requestedRate = rate;
  advanceControlRevision(control.controlRevision);
  control.appliedControlRevision = control.controlRevision;
  return NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress NativeAudioSession::setMuted(bool muted) noexcept {
  if (control_ == nullptr) {
    return NativeAudioSessionProgress::Invalid;
  }
  NativeAudioSessionControl& control = *control_;
  if (!acceptsAudioControls(control.state)) {
    return NativeAudioSessionProgress::Invalid;
  }

  control.requestedMuted = muted;
  advanceControlRevision(control.controlRevision);
  control.renderCore.setMuted(control.requestedMuted);
  control.appliedGain = control.requestedGain;
  control.appliedMuted = control.requestedMuted;
  control.appliedControlRevision = control.controlRevision;
  return NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress NativeAudioSession::stop() noexcept {
  if (control_ == nullptr) {
    return NativeAudioSessionProgress::Invalid;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);
  if (control.retireRequested) {
    return NativeAudioSessionProgress::Invalid;
  }
  if (control.terminalOverride == TerminalOverride::Stop) {
    if (control.terminalOverrideGeneration != control.generation) {
      return NativeAudioSessionProgress::Invalid;
    }
    if (control.closeDone || control.state == NativeAudioSessionState::Closed) {
      return NativeAudioSessionProgress::Done;
    }
    switch (close()) {
    case media::NativeMediaConsumerProgress::Done:
      return NativeAudioSessionProgress::Done;
    case media::NativeMediaConsumerProgress::Quiescing:
    case media::NativeMediaConsumerProgress::Progress:
      return NativeAudioSessionProgress::Quiescing;
    case media::NativeMediaConsumerProgress::StaleGeneration:
    case media::NativeMediaConsumerProgress::Unsupported:
    case media::NativeMediaConsumerProgress::Failed:
      return NativeAudioSessionProgress::Failed;
    }
  }
  if (control.lifecycle == SessionLifecycle::Flush ||
      control.state == NativeAudioSessionState::Flushing) {
    control.terminalOverride = TerminalOverride::Stop;
    control.terminalOverrideGeneration = control.generation;
    switch (close()) {
    case media::NativeMediaConsumerProgress::Done:
      return NativeAudioSessionProgress::Done;
    case media::NativeMediaConsumerProgress::Quiescing:
    case media::NativeMediaConsumerProgress::Progress:
      return NativeAudioSessionProgress::Quiescing;
    case media::NativeMediaConsumerProgress::StaleGeneration:
    case media::NativeMediaConsumerProgress::Unsupported:
    case media::NativeMediaConsumerProgress::Failed:
      return NativeAudioSessionProgress::Failed;
    }
    return NativeAudioSessionProgress::Failed;
  }
  if (control.state == NativeAudioSessionState::Cancelled) {
    return NativeAudioSessionProgress::Done;
  }
  if ((control.state != NativeAudioSessionState::Ready &&
       control.state != NativeAudioSessionState::Started &&
       control.state != NativeAudioSessionState::Stopping) ||
      control.output == nullptr) {
    return NativeAudioSessionProgress::Invalid;
  }
  control.requestedPaused = true;
  control.renderCore.setPaused(true);
  control.state = NativeAudioSessionState::Stopping;
  const NativeAudioSessionProgress result = mapOutputProgress(
      control, control.output->stop(), NativeAudioSessionFailure::Output);
  if (result == NativeAudioSessionProgress::Done) {
    if (!settleStopped(control, control.generation)) {
      return NativeAudioSessionProgress::Failed;
    }
    control.state = NativeAudioSessionState::Ready;
    // An owner-requested stop supersedes a pause suspend: the resume path
    // back from here is the owner's own start(), not setPaused(false).
    control.outputSuspension = OutputSuspension::None;
  }
  return result;
}

media::NativeMediaConsumerProgress NativeAudioSession::flush(
    media::MediaGeneration retiredGeneration,
    media::MediaGeneration nextGeneration,
    const media::NativeMediaGenerationTimeline& timeline) noexcept {
  if (control_ == nullptr) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);
  if (control.retireRequested) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (nextGeneration != 0 && nextGeneration > retiredGeneration &&
      nextGeneration > control.highestExposedGeneration) {
    // flush() itself exposes the target before returning any outcome.
    control.highestExposedGeneration = nextGeneration;
  }
  if (control.state == NativeAudioSessionState::Closing ||
      control.state == NativeAudioSessionState::Closed ||
      control.state == NativeAudioSessionState::Stopping ||
      control.state == NativeAudioSessionState::Cancelling ||
      control.state == NativeAudioSessionState::Cancelled) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (control.completedFlushRetired == retiredGeneration &&
      control.completedFlushTarget == nextGeneration &&
      sameTimeline(control.timeline, timeline) &&
      control.generation == nextGeneration) {
    return media::NativeMediaConsumerProgress::Done;
  }
  if (control.lifecycle == SessionLifecycle::Flush) {
    if (control.lifecycleRetired != retiredGeneration ||
        control.lifecycleTarget != nextGeneration ||
        !sameTimeline(control.lifecycleTimeline, timeline)) {
      return media::NativeMediaConsumerProgress::StaleGeneration;
    }
  } else {
    if (control.lifecycle != SessionLifecycle::None ||
        !control.configured ||
        control.state == NativeAudioSessionState::Failed ||
        retiredGeneration != control.generation || nextGeneration == 0 ||
        nextGeneration <= retiredGeneration) {
      return retiredGeneration != control.generation
                 ? media::NativeMediaConsumerProgress::StaleGeneration
                 : media::NativeMediaConsumerProgress::Failed;
    }
    const std::optional<TimelinePlan> plan = timelinePlanFor(
        nextGeneration, timeline, control.sampleRate,
        control.audioMayPrecedeStreamOrigin, control.trimAfterCeiling,
        control.presentationCeiling);
    if (!plan) {
      control.latch(NativeAudioSessionFailure::ClockTransition);
      return media::NativeMediaConsumerProgress::Failed;
    }
    control.lifecyclePlan = *plan;
    control.lifecycle = SessionLifecycle::Flush;
    control.flushStage = FlushStage::Stop;
    control.lifecycleRetired = retiredGeneration;
    control.lifecycleTarget = nextGeneration;
    control.lifecycleTimeline = timeline;
    control.firstAudioSampleAccepted = false;
    control.requestedPaused = true;
    control.renderCore.setPaused(true);
    // The flush owns the output from here: it stops, re-anchors and
    // re-activates it, so a pause suspend can no longer be the thing that
    // resumes it.
    control.outputSuspension = OutputSuspension::None;
    control.state = NativeAudioSessionState::Flushing;
  }

  if (control.flushStage == FlushStage::Stop) {
    const NativeAudioSessionProgress stopped = mapOutputProgress(
        control, control.output->stop(), NativeAudioSessionFailure::Output);
    if (stopped != NativeAudioSessionProgress::Done) {
      return mapLifecycleProgress(stopped);
    }
    if (!settleStopped(control, control.lifecycleRetired)) {
      return media::NativeMediaConsumerProgress::Failed;
    }
    control.flushStage = FlushStage::Reset;
  }

  if (control.flushStage == FlushStage::Reset) {
    const auto clockSeconds =
        media::mediaTimeSeconds(control.lifecyclePlan.clockPosition);
    if (!clockSeconds || !control.ring.flush(control.lifecycleTarget)) {
      control.latch(NativeAudioSessionFailure::RingTransition);
      return media::NativeMediaConsumerProgress::Failed;
    }
    if (!control.clock.seek(control.lifecycleRetired,
                            control.lifecycleTarget, *clockSeconds)) {
      control.latch(NativeAudioSessionFailure::ClockTransition);
      return media::NativeMediaConsumerProgress::Failed;
    }
    if (!control.converter.flush(control.lifecycleTarget,
                                 control.lifecyclePlan.converter)) {
      control.latch(NativeAudioSessionFailure::Converter);
      return media::NativeMediaConsumerProgress::Failed;
    }
    control.renderCore.setPaused(true);
    control.flushStage = FlushStage::Activate;
  }

  const NativeAudioSessionProgress activated = mapOutputProgress(
      control,
      control.output->activate(control.lifecycleTarget, 0,
                               control.lifecyclePlan.mediaOrigin,
                               control.lifecyclePlan.clockPosition,
                               control.lifecyclePlan.declaredSilence),
      NativeAudioSessionFailure::OutputActivation);
  if (activated != NativeAudioSessionProgress::Done) {
    return mapLifecycleProgress(activated);
  }

  control.completedFlushRetired = control.lifecycleRetired;
  control.completedFlushTarget = control.lifecycleTarget;
  control.generation = control.lifecycleTarget;
  control.timeline = control.lifecycleTimeline;
  control.converterTimeline = control.lifecyclePlan.converter;
  control.mediaOrigin = control.lifecyclePlan.mediaOrigin;
  control.audioDecodeStart = control.lifecyclePlan.decodeStart;
  control.firstAudioSampleAccepted = false;
  control.presentationFloorFrame = control.lifecyclePlan.floorFrame;
  control.mediaOriginFrame = control.lifecyclePlan.originFrame;
  control.leadInSilenceFrames = control.lifecyclePlan.leadInSilenceFrames;
  control.presentationEndFrame = control.lifecyclePlan.presentationEndFrame;
  control.endOfStreamRequested = false;
  control.terminalPublished = false;
  control.lifecycle = SessionLifecycle::None;
  control.lifecycleRetired = 0;
  control.lifecycleTarget = 0;
  control.state = NativeAudioSessionState::Ready;
  return media::NativeMediaConsumerProgress::Done;
}

media::NativeMediaConsumerProgress NativeAudioSession::cancel(
    media::MediaGeneration generation) noexcept {
  if (control_ == nullptr) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);
  if (control.retireRequested) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (generation != control.generation) {
    return media::NativeMediaConsumerProgress::StaleGeneration;
  }
  if (control.terminalOverride == TerminalOverride::Cancel) {
    if (generation != control.terminalOverrideGeneration) {
      return media::NativeMediaConsumerProgress::StaleGeneration;
    }
    return close();
  }
  if (control.lifecycle == SessionLifecycle::Flush ||
      control.state == NativeAudioSessionState::Flushing) {
    // A terminal cancellation supersedes a reversible seek flush. The graph
    // may already be split across retired/target generations, so the only
    // exact result is fail-closed teardown, never resuming Reset/Activate.
    control.terminalOverride = TerminalOverride::Cancel;
    control.terminalOverrideGeneration = generation;
    return close();
  }
  if (control.state == NativeAudioSessionState::Cancelled &&
      control.cancelledGeneration == generation) {
    return media::NativeMediaConsumerProgress::Done;
  }
  if (control.lifecycle != SessionLifecycle::None &&
      control.lifecycle != SessionLifecycle::Cancel) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (control.state == NativeAudioSessionState::Failed ||
      control.state == NativeAudioSessionState::Closing ||
      control.state == NativeAudioSessionState::Closed) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  control.lifecycle = SessionLifecycle::Cancel;
  control.lifecycleTarget = generation;
  control.requestedPaused = true;
  control.renderCore.setPaused(true);
  control.outputSuspension = OutputSuspension::None;
  control.state = NativeAudioSessionState::Cancelling;
  const NativeAudioSessionProgress stopped = mapOutputProgress(
      control, control.output->stop(), NativeAudioSessionFailure::Output);
  if (stopped != NativeAudioSessionProgress::Done) {
    return mapLifecycleProgress(stopped);
  }
  if (!settleStopped(control, generation)) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  control.converter.cancel(generation);
  if (control.converter.stats().configured) {
    control.renderCore.clearTerminal(generation);
    control.endOfStreamRequested = false;
    control.terminalPublished = false;
    control.firstAudioSampleAccepted = false;
    control.audioDecodeStart = {};
    control.cancelledGeneration = generation;
    control.lifecycle = SessionLifecycle::None;
    control.state = NativeAudioSessionState::Cancelled;
    return media::NativeMediaConsumerProgress::Done;
  }
  control.latch(NativeAudioSessionFailure::Converter);
  return media::NativeMediaConsumerProgress::Failed;
}

media::NativeMediaConsumerProgress NativeAudioSession::retire(
    media::MediaGeneration retiredGeneration,
    media::MediaGeneration invalidationGeneration) noexcept {
  if (control_ == nullptr) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);

  if (control.retireRequested) {
    if (retiredGeneration != control.retireRetiredGeneration ||
        invalidationGeneration != control.retireInvalidationGeneration) {
      return media::NativeMediaConsumerProgress::StaleGeneration;
    }
    if (control.retireDone) {
      return media::NativeMediaConsumerProgress::Done;
    }
  } else {
    if (retiredGeneration != control.highestExposedGeneration) {
      return media::NativeMediaConsumerProgress::StaleGeneration;
    }
    const NativeAudioConverterStats converter = control.converter.stats();
    const NativeAudioOutputFacts output =
        control.output != nullptr ? control.output->facts()
                                  : NativeAudioOutputFacts{};
    const NativeMediaClockSnapshot clock = control.clock.sample();
    media::MediaGeneration highestInstalled = control.ring.generation();
    highestInstalled = std::max(highestInstalled, control.generation);
    highestInstalled = std::max(highestInstalled, converter.generation);
    highestInstalled = std::max(highestInstalled, output.generation);
    highestInstalled = std::max(highestInstalled, clock.generation);
    highestInstalled =
        std::max(highestInstalled, control.lifecycleTarget);
    if (invalidationGeneration == 0 ||
        invalidationGeneration <= retiredGeneration ||
        invalidationGeneration <= highestInstalled) {
      return media::NativeMediaConsumerProgress::Failed;
    }
    control.retireRequested = true;
    control.retireRetiredGeneration = retiredGeneration;
    control.retireInvalidationGeneration = invalidationGeneration;
    control.retireStage = RetireStage::StopOutput;
    control.lifecycle = SessionLifecycle::None;
    control.lifecycleRetired = 0;
    control.lifecycleTarget = 0;
    control.terminalOverride = TerminalOverride::None;
    control.terminalOverrideGeneration = 0;
    control.requestedPaused = true;
    control.renderCore.setPaused(true);
    control.outputSuspension = OutputSuspension::None;
    control.state = NativeAudioSessionState::Retiring;
  }

  if (control.retireStage == RetireStage::StopOutput) {
    if (control.output != nullptr) {
      const NativeAudioOutputProgress stopped = control.output->stop();
      if (stopped == NativeAudioOutputProgress::Quiescing) {
        return media::NativeMediaConsumerProgress::Quiescing;
      }
      if (stopped != NativeAudioOutputProgress::Done) {
        // A partially configured output can be in Detaching, where stop() is
        // intentionally invalid but close() remains the only legal progress
        // operation. Lower-layer failure may also have completed part of its
        // close sequence, so keep the exact pair retryable rather than
        // claiming an irreversible terminal failure.
        control.latch(NativeAudioSessionFailure::Output);
        control.state = NativeAudioSessionState::Retiring;
        const NativeAudioOutputProgress closed = control.output->close();
        if (closed == NativeAudioOutputProgress::Quiescing) {
          return media::NativeMediaConsumerProgress::Quiescing;
        }
        if (closed != NativeAudioOutputProgress::Done) {
          return media::NativeMediaConsumerProgress::Progress;
        }
      }
    }

    if (control.clockActivated) {
      NativeMediaClockSnapshot clock = control.clock.sample();
      if (!clock.publicationCurrent || !clock.valid ||
          clock.generation == 0 ||
          !control.clock.pause(clock.generation)) {
        control.latch(NativeAudioSessionFailure::ClockTransition);
        control.state = NativeAudioSessionState::Retiring;
        return media::NativeMediaConsumerProgress::Failed;
      }
      clock = control.clock.sample();
      if (!clock.publicationCurrent || !clock.valid || clock.running) {
        control.latch(NativeAudioSessionFailure::ClockTransition);
        control.state = NativeAudioSessionState::Retiring;
        return media::NativeMediaConsumerProgress::Failed;
      }
      if (control.output != nullptr) {
        const NativeAudioOutputFacts output = control.output->facts();
        if (output.activated && output.generation == clock.generation &&
            !control.renderCore.settlePausedAfterStop(clock.generation)) {
          control.latch(NativeAudioSessionFailure::ClockTransition);
          control.state = NativeAudioSessionState::Retiring;
          return media::NativeMediaConsumerProgress::Failed;
        }
      }
    }
    control.retireStage = RetireStage::InvalidateGraph;
  }

  if (control.retireStage == RetireStage::InvalidateGraph) {
    const media::MediaGeneration invalidation =
        control.retireInvalidationGeneration;
    const media::MediaGeneration ringGeneration = control.ring.generation();
    if (ringGeneration != invalidation &&
        !control.ring.flush(invalidation)) {
      control.latch(NativeAudioSessionFailure::RingTransition);
      control.state = NativeAudioSessionState::Retiring;
      return media::NativeMediaConsumerProgress::Failed;
    }

    if (control.clockActivated) {
      const NativeMediaClockSnapshot clock = control.clock.sample();
      if (clock.generation != invalidation) {
        if (!clock.valid || clock.generation == 0 ||
            !control.clock.stop(clock.generation, invalidation)) {
          control.latch(NativeAudioSessionFailure::ClockTransition);
          control.state = NativeAudioSessionState::Retiring;
          return media::NativeMediaConsumerProgress::Failed;
        }
      }
      const NativeMediaClockSnapshot invalid = control.clock.sample();
      if (!invalid.publicationCurrent || invalid.valid || invalid.running ||
          invalid.generation != invalidation) {
        control.latch(NativeAudioSessionFailure::ClockTransition);
        control.state = NativeAudioSessionState::Retiring;
        return media::NativeMediaConsumerProgress::Failed;
      }
    }

    control.renderCore.clearTerminal(control.generation);
    control.converter.close();
    const NativeAudioConverterStats converter = control.converter.stats();
    if (converter.configured || converter.samplePrepared ||
        converter.sampleRetained) {
      control.latch(NativeAudioSessionFailure::Converter);
      control.state = NativeAudioSessionState::Retiring;
      return media::NativeMediaConsumerProgress::Failed;
    }
    control.endOfStreamRequested = false;
    control.terminalPublished = false;
    control.retireStage = RetireStage::CloseOutput;
  }

  if (control.output != nullptr) {
    const NativeAudioOutputProgress closed = control.output->close();
    if (closed == NativeAudioOutputProgress::Quiescing) {
      return media::NativeMediaConsumerProgress::Quiescing;
    }
    if (closed != NativeAudioOutputProgress::Done) {
      control.latch(NativeAudioSessionFailure::Output);
      control.state = NativeAudioSessionState::Retiring;
      return media::NativeMediaConsumerProgress::Progress;
    }
    const NativeAudioOutputFacts output = control.output->facts();
    if (output.configured || output.started || !output.stopped ||
        !output.callbackQuiescent ||
        output.state != NativeAudioOutputState::Closed) {
      control.latch(NativeAudioSessionFailure::Output);
      control.state = NativeAudioSessionState::Retiring;
      return media::NativeMediaConsumerProgress::Progress;
    }
  }

  const media::MediaGeneration invalidation =
      control.retireInvalidationGeneration;
  const NativeAudioConverterStats converter = control.converter.stats();
  if (control.ring.generation() != invalidation ||
      control.ring.queuedSlabs() != 0 || converter.configured ||
      converter.samplePrepared || converter.sampleRetained) {
    control.latch(NativeAudioSessionFailure::ConsumerProtocol);
    control.state = NativeAudioSessionState::Retiring;
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (control.clockActivated) {
    const NativeMediaClockSnapshot clock = control.clock.sample();
    if (!clock.publicationCurrent || clock.valid || clock.running ||
        clock.generation != invalidation) {
      control.latch(NativeAudioSessionFailure::ClockTransition);
      control.state = NativeAudioSessionState::Retiring;
      return media::NativeMediaConsumerProgress::Failed;
    }
  }

  control.output.reset();
  control.generation = invalidation;
  control.configured = false;
  control.firstAudioSampleAccepted = false;
  control.audioDecodeStart = {};
  control.retireDone = true;
  control.state = NativeAudioSessionState::Closed;
  releaseClaim(control);
  return media::NativeMediaConsumerProgress::Done;
}

const std::string& NativeAudioSession::failureText() const noexcept {
  static const std::string none;
  return control_ == nullptr ? none : control_->failureText;
}

media::NativeMediaConsumerProgress NativeAudioSession::close() noexcept {
  if (control_ == nullptr) {
    return media::NativeMediaConsumerProgress::Done;
  }
  NativeAudioSessionControl& control = *control_;
  clearOutputWake(control);
  // Emergency close remains memory-safe but never mints or completes Router
  // retirement proof. If an exact retirement is already latched, keep its
  // public pair/facts intact while performing the same quarantine-safe tear
  // down.
  if (control.closeDone ||
      (control.state == NativeAudioSessionState::Closed &&
       !control.retireDone)) {
    return media::NativeMediaConsumerProgress::Done;
  }
  control.state = NativeAudioSessionState::Closing;
  // Close has absolute precedence over every reversible operation. An older
  // quiescing flush/cancel can never resume Reset/Activate after this point.
  control.lifecycle = SessionLifecycle::None;
  control.lifecycleRetired = 0;
  control.lifecycleTarget = 0;
  control.requestedPaused = true;
  control.renderCore.setPaused(true);
  control.outputSuspension = OutputSuspension::None;
#if defined(WAM_NATIVE_AUDIO_SESSION_TESTING)
  if (control.forceCloseQuiescing) {
    return media::NativeMediaConsumerProgress::Quiescing;
  }
#endif
  if (control.output != nullptr) {
    const NativeAudioSessionProgress closed = mapOutputProgress(
        control, control.output->close(), NativeAudioSessionFailure::Output);
    if (closed != NativeAudioSessionProgress::Done) {
      control.state = NativeAudioSessionState::Closing;
      return mapLifecycleProgress(closed);
    }
  }
  if (control.configured) {
    static_cast<void>(settleStopped(control, control.generation));
  }
  control.converter.close();
  control.output.reset();
  control.configured = false;
  control.firstAudioSampleAccepted = false;
  control.audioDecodeStart = {};
  control.closeDone = true;
  control.lifecycle = SessionLifecycle::None;
  control.state = NativeAudioSessionState::Closed;
  releaseClaim(control);
  return media::NativeMediaConsumerProgress::Done;
}

NativeMediaClockSnapshot NativeAudioSession::visibleClock() const noexcept {
  if (control_ == nullptr) {
    return {};
  }
  if (control_->retireRequested && control_->clockActivated) {
    return control_->clock.sample();
  }
  if (!control_->configured) {
    return {};
  }
  return control_->renderCore.visibleClock();
}

NativeAudioRenderStats NativeAudioSession::renderStats() const noexcept {
  if (control_ == nullptr) {
    return {};
  }
  return control_->renderCore.stats();
}

NativeAudioSessionFacts NativeAudioSession::facts() const noexcept {
  NativeAudioSessionFacts result;
  if (control_ == nullptr) {
    result.state = NativeAudioSessionState::Closed;
    result.closeDone = true;
    return result;
  }
  const NativeAudioSessionControl& control = *control_;
  result.state = control.state;
  result.failure = control.failure;
  result.generation = control.generation;
  result.track = control.track;
  result.sampleRate = control.sampleRate;
  result.presentationFloorFrame = control.presentationFloorFrame;
  const NativePcmRing::Stats ring = control.ring.stats();
  result.ringGeneration = ring.generation;
  result.queuedSlabs = ring.queuedSlabs;
  result.resourceEntered = control.resourceEntered;
  result.configured = control.configured;
  result.requestedPaused = control.requestedPaused;
  result.requestedGain = control.requestedGain;
  result.appliedGain = control.appliedGain;
  result.requestedMuted = control.requestedMuted;
  result.appliedMuted = control.appliedMuted;
  result.controlRevision = control.controlRevision;
  result.appliedControlRevision = control.appliedControlRevision;
  result.endOfStreamRequested = control.endOfStreamRequested;
  result.terminalPublished = control.terminalPublished;
  result.terminalObserved = terminalObserved(control);
  const NativeMediaClockSnapshot clock = control.clock.sample();
  result.clockGeneration = clock.generation;
  result.clockValid = clock.valid;
  result.highestExposedGeneration = control.highestExposedGeneration;
  result.retiredGeneration = control.retireRetiredGeneration;
  result.invalidationGeneration = control.retireInvalidationGeneration;
  result.retireDone = control.retireDone;
  result.closeDone = control.closeDone;
  result.outputSuspended =
      control.outputSuspension == OutputSuspension::Suspended;
  result.converter = control.converter.stats();
  result.converterDrained = result.converter.drained;
  result.memory.generation = control.generation;
  result.memory.converterGeneration = result.converter.generation;
  result.memory.ringGeneration = ring.generation;
  result.memory.converterRetainedPayloadBytes =
      result.converter.retainedPayloadBytes;
  result.memory.peakConverterRetainedPayloadBytes =
      result.converter.peakRetainedPayloadBytes;
  result.memory.ringUnreadPcmBytes = ring.unreadPcmBytes;
  result.memory.peakRingUnreadPcmBytes = ring.peakUnreadPcmBytes;
  result.memory.generationCoherent =
      result.memory.ringGeneration == result.memory.generation &&
      (result.memory.converterRetainedPayloadBytes == 0 ||
       result.memory.converterGeneration == result.memory.generation);
  if (control.output != nullptr) {
    result.output = control.output->facts();
  }
  return result;
}

bool NativeAudioSession::resetMemoryHighWater(
    media::MediaGeneration expectedGeneration) noexcept {
  if (control_ == nullptr || expectedGeneration == 0) {
    return false;
  }
  NativeAudioSessionControl& control = *control_;
  if (!control.configured ||
      control.state != NativeAudioSessionState::Ready ||
      control.generation != expectedGeneration || control.output == nullptr) {
    return false;
  }
  const NativeAudioConverterStats converter = control.converter.stats();
  const NativePcmRing::Stats ring = control.ring.stats();
  const NativeAudioOutputFacts output = control.output->facts();
  if (converter.generation != expectedGeneration ||
      ring.generation != expectedGeneration || output.started ||
      !output.stopped || !output.callbackQuiescent) {
    return false;
  }

  // Both generation checks were preflighted under the serialized stopped-owner
  // contract, so the two noexcept leaf resets cannot partially fail.
  const bool converterReset =
      control.converter.resetRetainedPayloadByteHighWater(expectedGeneration);
  const bool ringReset =
      control.ring.resetUnreadPcmByteHighWater(expectedGeneration);
  return converterReset && ringReset;
}

} // namespace wam::macos
