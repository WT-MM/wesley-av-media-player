#include "native_silent_timebase.hpp"

namespace wam::macos {

NativeSilentTimebase::NativeSilentTimebase(
    media::NativeMediaHostClock hostClock) noexcept
    : clock_(hostClock) {}

std::unique_ptr<NativeSilentTimebase> NativeSilentTimebase::create(
    media::NativeMediaHostClock hostClock) noexcept {
  if (hostClock.readTicks == nullptr || hostClock.ticksPerSecond == 0) {
    return {};
  }
  try {
    std::unique_ptr<NativeSilentTimebase> timebase(
        new NativeSilentTimebase(hostClock));
    if (!timebase->clock_.configured()) {
      return {};
    }
    return timebase;
  } catch (...) {
    return {};
  }
}

bool NativeSilentTimebase::activate(media::MediaGeneration generation,
                                    media::MediaTime target) noexcept {
  if (phase_ == Phase::Retired || generation == 0 || generation <= generation_)
    return false;
  // seek() carries the retired generation's running fact forward, so the
  // transition is pinned paused first. The session's CommitSeek chain has
  // already published its own physical pause of the retired generation; this
  // repeat is idempotent and keeps the invariant local.
  const bool applied = phase_ == Phase::Unarmed
      ? clock_.anchor(generation, target, rate_, false)
      : clock_.pause(generation_) && clock_.seek(generation_, generation, target);
  if (!applied) return false;
  generation_ = generation;
  phase_ = Phase::Paused;
  return true;
}

NativeAudioSessionProgress NativeSilentTimebase::start() noexcept {
  if (!armed()) {
    return NativeAudioSessionProgress::Invalid;
  }
  return NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress NativeSilentTimebase::setPaused(
    bool paused) noexcept {
  if (!armed()) {
    return NativeAudioSessionProgress::Invalid;
  }
  const bool applied =
      paused ? clock_.pause(generation_)
             : clock_.run(generation_, rate_);
  if (!applied) {
    return NativeAudioSessionProgress::Failed;
  }
  phase_ = paused ? Phase::Paused : Phase::Running;
  return NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress NativeSilentTimebase::setRate(
    media::NativePlaybackRate rate, bool) noexcept {
  if (phase_ == Phase::Retired || !rate.valid()) {
    return NativeAudioSessionProgress::Invalid;
  }
  if (rate == rate_) {
    return NativeAudioSessionProgress::Done;
  }
  rate_ = rate;
  if (phase_ != Phase::Running) {
    // Nothing is advancing yet; the new slope is picked up by the resume.
    return NativeAudioSessionProgress::Done;
  }
  // Re-running an already running generation re-anchors it at the position it
  // has reached and continues from there at the new slope. That is exactly a
  // rate change: no media time is created or destroyed at the boundary.
  return clock_.run(generation_, rate_)
             ? NativeAudioSessionProgress::Done
             : NativeAudioSessionProgress::Failed;
}

NativeAudioSessionProgress NativeSilentTimebase::setGain(float) noexcept {
  return phase_ == Phase::Retired ? NativeAudioSessionProgress::Invalid
                                  : NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress NativeSilentTimebase::setMuted(bool) noexcept {
  return phase_ == Phase::Retired ? NativeAudioSessionProgress::Invalid
                                  : NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress NativeSilentTimebase::stop() noexcept {
  if (!armed()) {
    return NativeAudioSessionProgress::Invalid;
  }
  if (!clock_.pause(generation_)) {
    return NativeAudioSessionProgress::Failed;
  }
  phase_ = Phase::Paused;
  return NativeAudioSessionProgress::Done;
}

media::NativeMediaClockSnapshot NativeSilentTimebase::visibleClock() const noexcept {
  return clock_.sample();
}

media::MediaGeneration
NativeSilentTimebase::highestExposedGeneration() const noexcept {
  return generation_;
}

bool NativeSilentTimebase::retire(
    media::MediaGeneration invalidationGeneration) noexcept {
  switch (phase_) {
  case Phase::Retired:
    return true;
  case Phase::Unarmed:
    break;
  case Phase::Paused:
  case Phase::Running:
    if (!clock_.stop(generation_, invalidationGeneration)) {
      return false;
    }
    break;
  }
  phase_ = Phase::Retired;
  return true;
}

}  // namespace wam::macos
