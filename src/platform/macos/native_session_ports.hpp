#pragma once

#include "native_audio_session.hpp"
#include "native_preview_frame_lane.hpp"
#include "native_video_consumer.hpp"

#include <cstdint>
#include <optional>

namespace wam::macos {

// The children a NativeMediaSession actuates, as the session sees them. Every
// call is confined to the one session worker thread. Production binds these to
// NativeAudioSession / NativeSilentTimebase, NativeVideoConsumer and
// NativePreviewFrameLane; the session tests implement the same interfaces.

// The transport and clock authority of one generation: the audio session for
// a generation with audio, the silent timebase for one without.
class SessionClockAuthority {
 public:
  virtual ~SessionClockAuthority() = default;

  [[nodiscard]] virtual NativeAudioSessionProgress start() noexcept = 0;
  [[nodiscard]] virtual NativeAudioSessionProgress setPaused(
      bool paused) noexcept = 0;
  [[nodiscard]] virtual NativeAudioSessionProgress setGain(
      float gain) noexcept = 0;
  [[nodiscard]] virtual NativeAudioSessionProgress setMuted(
      bool muted) noexcept = 0;
  // Exact rate plus the preserve-pitch preference (true = time-stretched,
  // false = varispeed). An authority with no audio ignores the preference.
  [[nodiscard]] virtual NativeAudioSessionProgress setRate(
      media::NativePlaybackRate rate, bool preservePitch) noexcept = 0;
  [[nodiscard]] virtual NativeAudioSessionProgress stop() noexcept = 0;
  [[nodiscard]] virtual media::NativeMediaClockSnapshot visibleClock()
      const noexcept = 0;
  [[nodiscard]] virtual media::MediaGeneration highestExposedGeneration()
      const noexcept = 0;
  // Wake-rate lever: stops the output device for a settled pause. Only an
  // authority that owns an output device has anything to idle.
  [[nodiscard]] virtual bool suspendsForPause() const noexcept {
    return false;
  }
  [[nodiscard]] virtual NativeAudioSessionProgress suspendForPause() noexcept {
    return NativeAudioSessionProgress::Invalid;
  }
  // Diagnostic counters; empty when the authority has no render callback.
  [[nodiscard]] virtual std::optional<media::NativeAudioRenderStats> renderStats()
      const noexcept {
    return std::nullopt;
  }
};

struct SessionVideoMetrics {
  std::uint64_t drawnFrames{0};
  media::MediaTime firstDrawPts{};
  std::uint64_t decodedPrerollFrames{0};
  std::uint64_t submittedFrames{0};
  std::uint64_t supersededFrames{0};
  std::uint64_t discardedLateFrames{0};
};

class SessionVideoPort {
 public:
  virtual ~SessionVideoPort() = default;

  [[nodiscard]] virtual NativeVideoConsumerArmProgress armFirstGeneration(
      media::MediaGeneration generation) noexcept = 0;
  [[nodiscard]] virtual media::MediaGeneration
  highestExposedGeneration() noexcept = 0;
  [[nodiscard]] virtual std::uint64_t lastOutputEventSequence() noexcept = 0;
  [[nodiscard]] virtual std::uint64_t nextDueHostTicks() noexcept = 0;
  [[nodiscard]] virtual std::optional<NativeTrackedVideoEvent>
  takeOutputEvent() noexcept = 0;
  [[nodiscard]] virtual NativeVideoConsumerPreviewProgress quiesceForPreview(
      media::MediaGeneration generation) noexcept = 0;
  // Diagnostic counters; empty when the port cannot sample them.
  [[nodiscard]] virtual std::optional<SessionVideoMetrics> metrics() noexcept {
    return std::nullopt;
  }
};

class SessionPreviewPort {
 public:
  virtual ~SessionPreviewPort() = default;

  [[nodiscard]] virtual NativePreviewFrameRequestStatus request(
      media::native_playback::PreviewFrame command,
      NativePreviewFrameTarget target) noexcept = 0;
  [[nodiscard]] virtual NativePreviewFramePumpProgress pump() noexcept = 0;
  [[nodiscard]] virtual std::optional<media::native_playback::PreviewPresented>
  takePresented() noexcept = 0;
  [[nodiscard]] virtual NativePreviewFrameCancelProgress stop(
      media::native_playback::Generation activeGeneration) noexcept = 0;
};

}  // namespace wam::macos
