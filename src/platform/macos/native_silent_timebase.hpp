#pragma once

#include "media/native_media_source.hpp"
#include "native_audio_session.hpp"
#include "native_media_clock.hpp"

#include <memory>

namespace wam::macos {

// Authoritative media timebase for an audio-less (silent) native generation.
//
// The native v1 clock is normally audio-authoritative: the AudioUnit render
// callback is the sole writer of NativeMediaClock and publishes one exact
// media interval per device period. A source with no selected audio track has
// no such writer, so this object supplies the same authority from the host
// clock alone.
//
// It deliberately does NOT drive an AudioUnit. NativeMediaClock already
// evaluates media time as an exact linear function of host ticks whenever no
// bounded segment is published (see NativeMediaClock::mediaAt), so an anchored
// running generation *is* a 1.0x timebase with no periodic writer at all. A
// silent output unit would only reintroduce a real device, its power draw, its
// absent-device failure mode, and the underrun/late-frame retirement machinery
// that has nothing to retire here.
//
// The surface deliberately mirrors the subset of NativeAudioSession that
// NativeMediaSession actuates through its SessionAudioControl table, so the
// session's Start / SetRunState / CommitSeek / Ended chains are unchanged: they
// keep issuing the same calls and validating the same clock proofs. Gain and
// mute are accepted and discarded because a silent generation has no PCM to
// scale, and the owner must not have to special-case a user volume gesture.
//
// Every method is confined to the one session worker thread, exactly like
// NativeAudioSession's owner-thread operations. visibleClock() is the sole
// method safe to sample concurrently, and only under NativeMediaClock's own
// lock-free publication contract.
class NativeSilentTimebase final {
 public:
  [[nodiscard]] static std::unique_ptr<NativeSilentTimebase> create(
      NativeMediaHostClock hostClock) noexcept;

  NativeSilentTimebase(const NativeSilentTimebase&) = delete;
  NativeSilentTimebase& operator=(const NativeSilentTimebase&) = delete;
  NativeSilentTimebase(NativeSilentTimebase&&) = delete;
  NativeSilentTimebase& operator=(NativeSilentTimebase&&) = delete;

  // Quiescent generation transition. positionSeconds becomes the exact paused
  // commit position of the new generation, so a CommitSeek proof comparing
  // visibleClock().mediaSeconds against its binary64 target matches bit for
  // bit. The first activation anchors a fresh generation; later activations
  // must name a strictly newer generation and pause the retired one first.
  [[nodiscard]] bool activate(media::MediaGeneration generation,
                              double positionSeconds) noexcept;

  // Opens transport admission for the activated generation. The clock is
  // already anchored paused at its commit position, so unlike an audio start
  // there is nothing to prebuffer and this never reports WaitingForData.
  [[nodiscard]] NativeAudioSessionProgress start() noexcept;
  [[nodiscard]] NativeAudioSessionProgress setPaused(bool paused) noexcept;
  // Accepted and discarded; see the class comment.
  [[nodiscard]] NativeAudioSessionProgress setGain(float gain) noexcept;
  [[nodiscard]] NativeAudioSessionProgress setMuted(bool muted) noexcept;
  // Freezes the timebase at its current position and closes admission. The
  // session samples visibleClock() immediately afterwards for the Ended
  // position, so this must leave a valid, paused, current publication.
  [[nodiscard]] NativeAudioSessionProgress stop() noexcept;

  [[nodiscard]] NativeMediaClockSnapshot visibleClock() const noexcept;
  [[nodiscard]] media::MediaGeneration
  highestExposedGeneration() const noexcept;
  // Terminal invalidation, mirroring NativeAudioSession::retire(). The clock
  // publication moves to the invalidation generation and no later activation
  // is accepted.
  [[nodiscard]] bool retire(
      media::MediaGeneration invalidationGeneration) noexcept;

 private:
  explicit NativeSilentTimebase(NativeMediaHostClock hostClock) noexcept;

  NativeMediaClock clock_;
  media::MediaGeneration generation_{0};
  bool retired_{false};
};

}  // namespace wam::macos
