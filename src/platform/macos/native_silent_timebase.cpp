#include "native_silent_timebase.hpp"

#include "media/native_playback_contract.hpp"

#include <cmath>

namespace wam::macos {
namespace {

namespace protocol = media::native_playback;

}  // namespace

NativeSilentTimebase::NativeSilentTimebase(
    NativeMediaHostClock hostClock) noexcept
    : clock_(hostClock) {}

std::unique_ptr<NativeSilentTimebase> NativeSilentTimebase::create(
    NativeMediaHostClock hostClock) noexcept {
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
                                    double positionSeconds) noexcept {
  if (retired_ || generation == 0 || generation <= generation_ ||
      !std::isfinite(positionSeconds) || positionSeconds < 0.0) {
    return false;
  }
  if (generation_ == 0) {
    if (!clock_.anchor(generation, positionSeconds, protocol::kVersion1Rate,
                       false)) {
      return false;
    }
  } else {
    // seek() carries the retired generation's running fact forward, so the
    // transition is pinned paused first. The session's CommitSeek chain has
    // already published its own physical pause of the retired generation;
    // this repeat is idempotent and keeps the invariant local.
    if (!clock_.pause(generation_) ||
        !clock_.seek(generation_, generation, positionSeconds)) {
      return false;
    }
  }
  generation_ = generation;
  return true;
}

NativeAudioSessionProgress NativeSilentTimebase::start() noexcept {
  if (retired_ || generation_ == 0) {
    return NativeAudioSessionProgress::Invalid;
  }
  return NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress NativeSilentTimebase::setPaused(
    bool paused) noexcept {
  if (retired_ || generation_ == 0) {
    return NativeAudioSessionProgress::Invalid;
  }
  const bool applied = paused ? clock_.pause(generation_)
                              : clock_.run(generation_,
                                           protocol::kVersion1Rate);
  return applied ? NativeAudioSessionProgress::Done
                 : NativeAudioSessionProgress::Failed;
}

NativeAudioSessionProgress NativeSilentTimebase::setGain(float) noexcept {
  return retired_ ? NativeAudioSessionProgress::Invalid
                  : NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress NativeSilentTimebase::setMuted(bool) noexcept {
  return retired_ ? NativeAudioSessionProgress::Invalid
                  : NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress NativeSilentTimebase::stop() noexcept {
  if (retired_ || generation_ == 0) {
    return NativeAudioSessionProgress::Invalid;
  }
  return clock_.pause(generation_) ? NativeAudioSessionProgress::Done
                                   : NativeAudioSessionProgress::Failed;
}

NativeMediaClockSnapshot NativeSilentTimebase::visibleClock() const noexcept {
  return clock_.sample();
}

media::MediaGeneration
NativeSilentTimebase::highestExposedGeneration() const noexcept {
  return generation_;
}

bool NativeSilentTimebase::retire(
    media::MediaGeneration invalidationGeneration) noexcept {
  if (retired_) {
    return true;
  }
  if (generation_ == 0) {
    retired_ = true;
    return true;
  }
  if (!clock_.stop(generation_, invalidationGeneration)) {
    return false;
  }
  retired_ = true;
  return true;
}

}  // namespace wam::macos
