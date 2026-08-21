#pragma once

#include <cstdint>
#include <limits>

namespace wam::media::native_playback {

// Identifiers deliberately have distinct types. Accidentally comparing a
// request to a generation (or a source to an attempt) must not compile.
struct AttemptId {
  std::uint64_t value{0};

  friend constexpr bool operator==(AttemptId, AttemptId) = default;
};

struct Serial {
  std::uint64_t value{0};

  friend constexpr bool operator==(Serial, Serial) = default;
};

struct SourceKey {
  std::uint64_t value{0};

  friend constexpr bool operator==(SourceKey, SourceKey) = default;
};

struct Generation {
  std::uint64_t value{0};

  friend constexpr bool operator==(Generation, Generation) = default;
};

// Zero means no generation has ever been exposed; UINT64_MAX means the
// generation domain was terminally exhausted. This is intentionally not
// interchangeable with Generation: it summarizes all retired and live
// generations across attempts and is an allocation input, never an identity.
struct GenerationHighWater {
  std::uint64_t value{0};

  friend constexpr bool operator==(GenerationHighWater,
                                   GenerationHighWater) = default;
};

struct GestureId {
  std::uint64_t value{0};

  friend constexpr bool operator==(GestureId, GestureId) = default;
};

struct RequestId {
  std::uint64_t value{0};

  friend constexpr bool operator==(RequestId, RequestId) = default;
};

struct AudioClockAnchorId {
  std::uint64_t value{0};

  friend constexpr bool operator==(AudioClockAnchorId,
                                   AudioClockAnchorId) = default;
};

// A response echoes the stamp of the command that caused it. Ended and Failed
// echo the stamp of the exact live or Stop command/state they observed. There
// is one strictly increasing, non-wrapping command-serial domain per attempt.
struct Stamp {
  AttemptId attempt;
  Serial serial;

  friend constexpr bool operator==(Stamp, Stamp) = default;
};

// UINT64_MAX is reserved for a terminal Stop serial and its invalidation
// generation. Live work may use at most UINT64_MAX - 1, guaranteeing that a
// strictly newer terminal value always remains representable without wrap.
inline constexpr std::uint64_t kTerminalStopValue =
    std::numeric_limits<std::uint64_t>::max();
inline constexpr std::uint64_t kMaximumLiveValue = kTerminalStopValue - 1;

[[nodiscard]] constexpr bool valid(AttemptId value) noexcept {
  return value.value != 0;
}

[[nodiscard]] constexpr bool valid(Serial value) noexcept {
  return value.value != 0;
}

[[nodiscard]] constexpr bool valid(SourceKey value) noexcept {
  return value.value != 0;
}

[[nodiscard]] constexpr bool valid(Generation value) noexcept {
  return value.value != 0;
}

[[nodiscard]] constexpr bool valid(GestureId value) noexcept {
  return value.value != 0;
}

[[nodiscard]] constexpr bool valid(RequestId value) noexcept {
  return value.value != 0;
}

[[nodiscard]] constexpr bool valid(AudioClockAnchorId value) noexcept {
  return value.value != 0;
}

[[nodiscard]] constexpr bool valid(Stamp value) noexcept {
  return valid(value.attempt) && valid(value.serial);
}

[[nodiscard]] constexpr bool validLive(Serial value) noexcept {
  return valid(value) && value.value <= kMaximumLiveValue;
}

[[nodiscard]] constexpr bool validLive(Generation value) noexcept {
  return valid(value) && value.value <= kMaximumLiveValue;
}

[[nodiscard]] constexpr bool validLive(Stamp value) noexcept {
  return valid(value.attempt) && validLive(value.serial);
}

// std::isfinite is not constexpr in every C++20 standard library. These
// comparisons reject NaN and both infinities while accepting positive zero
// and the harmless -0.0 representation.
[[nodiscard]] constexpr bool validPosition(double value) noexcept {
  return value >= 0.0 && value <= std::numeric_limits<double>::max();
}

[[nodiscard]] constexpr bool sameAttempt(Stamp left, Stamp right) noexcept {
  return valid(left) && valid(right) && left.attempt == right.attempt;
}

[[nodiscard]] constexpr bool sameCommand(Stamp command, Stamp fact) noexcept {
  return valid(command) && command == fact;
}

[[nodiscard]] constexpr bool follows(Stamp previous, Stamp next) noexcept {
  return sameAttempt(previous, next) &&
         next.serial.value > previous.serial.value;
}

[[nodiscard]] constexpr bool
canReserveLiveSerialAfter(Serial current) noexcept {
  return validLive(current) && current.value < kMaximumLiveValue;
}

[[nodiscard]] constexpr bool
canReserveStopSerialAfter(Serial current) noexcept {
  return validLive(current) && current.value < kTerminalStopValue;
}

[[nodiscard]] constexpr bool
canReserveLiveGenerationAfter(GenerationHighWater current) noexcept {
  return current.value < kMaximumLiveValue;
}

[[nodiscard]] constexpr bool
canReserveStopInvalidationAfter(GenerationHighWater current) noexcept {
  return current.value < kTerminalStopValue;
}

[[nodiscard]] constexpr bool
freshLiveGeneration(Generation generation,
                    GenerationHighWater highWater) noexcept {
  return validLive(generation) && generation.value > highWater.value;
}

[[nodiscard]] constexpr bool
freshStopInvalidation(Generation invalidation,
                      GenerationHighWater highWater) noexcept {
  return valid(invalidation) && invalidation.value > highWater.value;
}

inline constexpr double kVersion1Rate = 1.0;

// Advertised pitch-preserved playback-rate window. Both endpoints are exact
// binary rationals and both are exactly representable on the admission grid
// below.
inline constexpr double kMinimumNativeRate = 0.25;
inline constexpr double kMaximumNativeRate = 4.0;

// The admission grid. Every rate that reaches the native engine is first
// snapped to a multiple of 1/kNativeRateGrid, so it is an EXACT rational p/q
// with q dividing kNativeRateGrid -- never a UI double folded into the clock.
// 64 is chosen for two independent reasons and both are load bearing:
//   * it divides the device IO buffer (1024 frames), so the media advance
//     per render callback, outputFrames * p / q, is an exact integer with no
//     residual to carry and no rounding for the stretch stage to disagree
//     with; and
//   * its step, 1/64 = 1.5625%, is finer than half of the smallest step any
//     rate control in this application produces (the 0.05 speed slider), so
//     snapping never crosses a neighbouring control position and the worst
//     displacement from the requested speed is 1/128 -- inaudible, and far
//     below the ~4% pitch/tempo just-noticeable difference.
inline constexpr std::uint32_t kNativeRateGrid = 64;

// An exact playback rate as the reduced rational numerator/denominator. This
// is the only representation permitted past the protocol boundary; the media
// clock's rate is derived from integer frame counts built out of it, never
// from a double.
struct PlaybackRateRatio {
  std::uint32_t numerator{1};
  std::uint32_t denominator{1};

  [[nodiscard]] constexpr bool unity() const noexcept {
    return numerator == denominator;
  }
  [[nodiscard]] constexpr bool valid() const noexcept {
    return numerator != 0 && denominator != 0 &&
           kNativeRateGrid % denominator == 0 &&
           numerator * 4U >= denominator && numerator <= denominator * 4U;
  }
  // Exact: both operands are small integers and the quotient of two exactly
  // representable integers is correctly rounded exactly once.
  [[nodiscard]] constexpr double toDouble() const noexcept {
    return static_cast<double>(numerator) / static_cast<double>(denominator);
  }

  friend constexpr bool operator==(PlaybackRateRatio,
                                   PlaybackRateRatio) = default;
};

[[nodiscard]] constexpr std::uint32_t
gcd32(std::uint32_t a, std::uint32_t b) noexcept {
  while (b != 0) {
    const std::uint32_t t = a % b;
    a = b;
    b = t;
  }
  return a;
}

// Snaps an arbitrary requested speed onto the admission grid and reduces it.
// Out-of-window and non-finite inputs collapse to the nearest admitted
// endpoint; the caller decides separately whether that counts as acceptance.
[[nodiscard]] constexpr PlaybackRateRatio
nativeRateRatio(double rate) noexcept {
  // constexpr-safe finiteness: NaN fails every comparison.
  const bool ordered = rate == rate;
  double bounded = ordered ? rate : kVersion1Rate;
  if (bounded < kMinimumNativeRate) {
    bounded = kMinimumNativeRate;
  }
  if (bounded > kMaximumNativeRate) {
    bounded = kMaximumNativeRate;
  }
  const double scaled = bounded * static_cast<double>(kNativeRateGrid);
  // Round half away from zero; the operand is positive and below 257.
  auto ticks = static_cast<std::uint32_t>(scaled + 0.5);
  const std::uint32_t minimumTicks = kNativeRateGrid / 4U;
  const std::uint32_t maximumTicks = kNativeRateGrid * 4U;
  if (ticks < minimumTicks) {
    ticks = minimumTicks;
  }
  if (ticks > maximumTicks) {
    ticks = maximumTicks;
  }
  const std::uint32_t divisor = gcd32(ticks, kNativeRateGrid);
  return PlaybackRateRatio{ticks / divisor, kNativeRateGrid / divisor};
}

enum class RateRoute : std::uint8_t {
  NativeVersion1,
  Fallback,
};

// Rates inside the advertised pitch-preserved window are served natively; the
// engine snaps them onto the exact 1/64 admission grid. Anything outside the
// window (or non-finite) still routes to the compatibility engine, which has
// no such bound. No epsilon is permitted at this boundary: admission is
// decided on the exact snapped rational, not on a tolerance around a double.
[[nodiscard]] constexpr RateRoute routeForRate(double rate) noexcept {
  const bool ordered = rate == rate;
  if (!ordered || rate < kMinimumNativeRate || rate > kMaximumNativeRate) {
    return RateRoute::Fallback;
  }
  return nativeRateRatio(rate).valid() ? RateRoute::NativeVersion1
                                       : RateRoute::Fallback;
}

struct PreparedDescriptor {
  double durationSeconds{0.0};
  bool hasAudio{false};
  bool hasVideo{false};

  friend constexpr bool operator==(const PreparedDescriptor &,
                                   const PreparedDescriptor &) = default;
};

// Commands -----------------------------------------------------------------

struct Prepare {
  Stamp stamp;
  SourceKey sourceKey;
  Generation reservedGeneration;
  double initialPositionSeconds{0.0};
};

struct Start {
  Stamp stamp;
  Generation preparedGeneration;
  bool paused{true};
};

struct SetRunState {
  Stamp stamp;
  Generation generation;
  bool paused{true};
  double rate{kVersion1Rate};
  // Live playback only. True time-stretches, keeping the original pitch at
  // any rate; false is classic varispeed, where pitch scales with the rate.
  // It rides with the rate rather than travelling as a command of its own
  // because the two are one decision at the audio stage, and no ordering
  // between them can then be observed. At kVersion1Rate it means nothing --
  // a rate of 1 shifts pitch by zero either way -- so it never affects
  // whether a command is valid.
  bool preservePitch{true};
};

struct PreviewFrame {
  Stamp stamp;
  Generation generation;
  GestureId gesture;
  RequestId request;
  double targetSeconds{0.0};
};

struct CommitSeek {
  Stamp stamp;
  Generation sourceGeneration;
  Generation targetGeneration;
  GestureId gesture;
  RequestId request;
  double targetSeconds{0.0};
};

struct Stop {
  Stamp stamp;
  Generation invalidationGeneration;
};

// Events and proofs ---------------------------------------------------------

struct Prepared {
  Stamp stamp;
  SourceKey sourceKey;
  PreparedDescriptor descriptor;
  Generation generation;
};

// This is the only generation-free terminal preparation fact. It means the
// source was rejected before the Prepare reservation was exposed to native
// playback state. The authoritative PrepareOutcomeState below admits it
// exactly once.
struct UnsupportedSource {
  Stamp stamp;
  SourceKey sourceKey;
};

struct Started {
  Stamp stamp;
  Generation generation;
  // This is a counter snapshot, not an ID. Zero validly means that no draw
  // preceded Start; a later draw proof must still be nonzero and greater.
  std::uint64_t drawBaseline{0};
};

struct PreviewPresented {
  Stamp stamp;
  Generation generation;
  GestureId gesture;
  RequestId request;
  double actualPresentationTimeSeconds{0.0};
};

// Exact terminal acknowledgement for a PreviewFrame that was accepted by the
// public session boundary but could not reach a real draw. Unlike a playback
// Failed fact this retires only preview demand; CommitSeek and the live graph
// remain usable. The echoed target closes identity over the whole command.
struct PreviewFailed {
  Stamp stamp;
  Generation generation;
  GestureId gesture;
  RequestId request;
  double targetSeconds{0.0};
};

struct AudioClockProof {
  Stamp stamp;
  Generation generation;
  AudioClockAnchorId anchor;
  double positionSeconds{0.0};
  bool paused{true};
  double rate{kVersion1Rate};
};

struct VideoDrawProof {
  Stamp stamp;
  Generation generation;
  std::uint64_t drawSequence{0};
  double frameStartSeconds{0.0};
  double frameDurationSeconds{0.0};
  // An audio-only generation has no video lane, so there is no covering frame
  // for a commit to prove. This names that absence explicitly instead of
  // letting a zeroed proof pass as a real draw: when it is set, every other
  // field must be exactly zero and the commit's whole progress proof is the
  // audio clock -- which is the position authority in every generation anyway.
  // A picture needs a covering frame because it is a sample-and-hold signal;
  // PCM is not, so nothing has to stand in for the frame here.
  bool videoLaneAbsent{false};
};

struct CommitReady {
  Stamp stamp;
  Generation generation;
  GestureId gesture;
  RequestId request;
  double targetSeconds{0.0};
  AudioClockProof audioClock;
  VideoDrawProof videoDraw;
};

struct Ended {
  Stamp stamp;
  Generation generation;
  double finalPositionSeconds{0.0};
};

// Reasons are deliberately closed and allocation-free. Human-readable,
// backend-specific diagnostics stay outside this cross-platform protocol.
// Preparation has one narrow pre-resource meaning: before Prepared or Started
// is published, the backend has released every tentative resource and has not
// published or retained native state under reservedGeneration. After either
// publication, use another reason and complete exact Stop; Preparation must
// not bypass that retirement.
enum class FailureReason : std::uint8_t {
  Preparation = 1,
  Startup = 2,
  Clock = 3,
  Decode = 4,
  AudioOutput = 5,
  VideoOutput = 6,
  Preview = 7,
  CommitSeek = 8,
  Stop = 9,
  Protocol = 10,
};

struct Failed {
  Stamp stamp;
  // Preparation is the pre-resource guarantee documented on FailureReason;
  // it is not a generic failure after Prepared or Started publication.
  FailureReason reason{static_cast<FailureReason>(0)};
};

struct Stopped {
  Stamp stamp;
  Generation invalidationGeneration;
};

enum class PrepareDisposition : std::uint8_t {
  Outstanding,
  PreparedStopRequired,
  UnsupportedBeforeResources,
  FailedBeforeResources,
};

// Local validators ----------------------------------------------------------

[[nodiscard]] constexpr bool valid(const PreparedDescriptor &value) noexcept {
  // At least one lane must exist; neither is individually required. A
  // video-less source produces no draw proof, and the contract no longer asks
  // for one: an audio-only generation's progress proof is the audio clock,
  // which is the authority in every other generation too. A source with
  // neither lane could not produce a single sample.
  return validPosition(value.durationSeconds) &&
         (value.hasVideo || value.hasAudio);
}

[[nodiscard]] constexpr bool valid(const Prepare &value) noexcept {
  return validLive(value.stamp) && valid(value.sourceKey) &&
         validLive(value.reservedGeneration) &&
         validPosition(value.initialPositionSeconds);
}

[[nodiscard]] constexpr bool valid(const Start &value) noexcept {
  // Start always establishes the prepared generation while paused. Running
  // is a later, independently serialised SetRunState command.
  return validLive(value.stamp) && validLive(value.preparedGeneration) &&
         value.paused;
}

[[nodiscard]] constexpr bool valid(const SetRunState &value) noexcept {
  return validLive(value.stamp) && validLive(value.generation) &&
         routeForRate(value.rate) == RateRoute::NativeVersion1;
}

[[nodiscard]] constexpr bool valid(const PreviewFrame &value) noexcept {
  return validLive(value.stamp) && validLive(value.generation) &&
         valid(value.gesture) && valid(value.request) &&
         validPosition(value.targetSeconds);
}

[[nodiscard]] constexpr bool valid(const CommitSeek &value) noexcept {
  return validLive(value.stamp) && validLive(value.sourceGeneration) &&
         validLive(value.targetGeneration) &&
         value.targetGeneration.value > value.sourceGeneration.value &&
         valid(value.gesture) && valid(value.request) &&
         validPosition(value.targetSeconds);
}

[[nodiscard]] constexpr bool valid(const Stop &value) noexcept {
  return valid(value.stamp) && valid(value.invalidationGeneration);
}

[[nodiscard]] constexpr bool valid(const Prepared &value) noexcept {
  return validLive(value.stamp) && valid(value.sourceKey) &&
         valid(value.descriptor) && validLive(value.generation);
}

[[nodiscard]] constexpr bool valid(const UnsupportedSource &value) noexcept {
  return validLive(value.stamp) && valid(value.sourceKey);
}

[[nodiscard]] constexpr bool valid(const Started &value) noexcept {
  return validLive(value.stamp) && validLive(value.generation);
}

[[nodiscard]] constexpr bool valid(const PreviewPresented &value) noexcept {
  return validLive(value.stamp) && validLive(value.generation) &&
         valid(value.gesture) && valid(value.request) &&
         validPosition(value.actualPresentationTimeSeconds);
}

[[nodiscard]] constexpr bool valid(const PreviewFailed &value) noexcept {
  return validLive(value.stamp) && validLive(value.generation) &&
         valid(value.gesture) && valid(value.request) &&
         validPosition(value.targetSeconds);
}

[[nodiscard]] constexpr bool valid(const AudioClockProof &value) noexcept {
  // `paused` is NOT required here any more. A running sample is a legitimate
  // proof shape: it is the UI playhead observation for an audio-only
  // generation, which draws no frames and therefore has no frame PTS to use
  // instead. Every consumer that genuinely needs a settled, paused clock --
  // only the commit handshake does -- states that requirement itself, see
  // valid(CommitReady) below.
  return validLive(value.stamp) && validLive(value.generation) &&
         valid(value.anchor) && validPosition(value.positionSeconds) &&
         routeForRate(value.rate) == RateRoute::NativeVersion1;
}

[[nodiscard]] constexpr bool valid(const VideoDrawProof &value) noexcept {
  if (value.videoLaneAbsent) {
    // Exactly the zero shape and nothing else, so an absent-lane proof can
    // never be confused with a real draw that merely failed to fill in.
    return validLive(value.stamp) && validLive(value.generation) &&
           value.drawSequence == 0 && value.frameStartSeconds == 0.0 &&
           value.frameDurationSeconds == 0.0;
  }
  return validLive(value.stamp) && validLive(value.generation) &&
         value.drawSequence != 0 && validPosition(value.frameStartSeconds) &&
         value.frameDurationSeconds > 0.0 &&
         value.frameDurationSeconds <= std::numeric_limits<double>::max();
}

[[nodiscard]] constexpr bool
frameCoversPosition(const VideoDrawProof &frame,
                    double positionSeconds) noexcept {
  if (frame.videoLaneAbsent) {
    // Nothing to cover: an audio-only generation has no picture that must be
    // held over the target instant.
    return true;
  }
  // Subtraction after the ordered comparison avoids overflowing a
  // frameStart + frameDuration sum. The half-open interval assigns an exact
  // boundary to the following frame.
  return valid(frame) && validPosition(positionSeconds) &&
         positionSeconds >= frame.frameStartSeconds &&
         positionSeconds - frame.frameStartSeconds < frame.frameDurationSeconds;
}

[[nodiscard]] constexpr bool valid(const CommitReady &value) noexcept {
  return validLive(value.stamp) && validLive(value.generation) &&
         valid(value.gesture) && valid(value.request) &&
         validPosition(value.targetSeconds) && valid(value.audioClock) &&
         // A commit lands the transport paused at the target, so its clock
         // proof must be a settled paused sample -- the requirement that used
         // to live inside valid(AudioClockProof) and is stated here now.
         value.audioClock.paused && valid(value.videoDraw) &&
         sameCommand(value.stamp, value.audioClock.stamp) &&
         sameCommand(value.stamp, value.videoDraw.stamp) &&
         value.audioClock.generation == value.generation &&
         value.videoDraw.generation == value.generation &&
         value.audioClock.positionSeconds == value.targetSeconds &&
         frameCoversPosition(value.videoDraw, value.targetSeconds);
}

[[nodiscard]] constexpr bool valid(const Ended &value) noexcept {
  return validLive(value.stamp) && validLive(value.generation) &&
         validPosition(value.finalPositionSeconds);
}

[[nodiscard]] constexpr bool valid(FailureReason value) noexcept {
  switch (value) {
  case FailureReason::Preparation:
  case FailureReason::Startup:
  case FailureReason::Clock:
  case FailureReason::Decode:
  case FailureReason::AudioOutput:
  case FailureReason::VideoOutput:
  case FailureReason::Preview:
  case FailureReason::CommitSeek:
  case FailureReason::Stop:
  case FailureReason::Protocol:
    return true;
  }
  return false;
}

[[nodiscard]] constexpr bool valid(const Failed &value) noexcept {
  // Only failure of the terminal Stop command may echo the reserved maximum
  // serial. All other failures are observations of live commands.
  return valid(value.stamp) && valid(value.reason) &&
         (validLive(value.stamp) || value.reason == FailureReason::Stop);
}

[[nodiscard]] constexpr bool valid(const Stopped &value) noexcept {
  return valid(value.stamp) && valid(value.invalidationGeneration);
}

// Cross-item state rules ----------------------------------------------------

[[nodiscard]] constexpr bool
prepareFollows(GenerationHighWater generationHighWater,
               const Prepare &command) noexcept {
  return valid(command) &&
         freshLiveGeneration(command.reservedGeneration, generationHighWater);
}

[[nodiscard]] constexpr bool
preparedMatches(const Prepare &command, GenerationHighWater generationHighWater,
                const Prepared &event) noexcept {
  return prepareFollows(generationHighWater, command) && valid(event) &&
         sameCommand(command.stamp, event.stamp) &&
         command.sourceKey == event.sourceKey &&
         command.initialPositionSeconds <= event.descriptor.durationSeconds &&
         command.reservedGeneration == event.generation;
}

// The identity and one-shot disposition are deliberately inseparable. This
// state is constructed in place for one accepted Prepare and cannot be copied,
// moved, assigned, or retargeted. Returning identity snapshots by value also
// prevents const_cast from reaching the authoritative fields. The owner must
// destroy and re-emplace the state before accepting a different Prepare.
class PrepareOutcomeState final {
public:
  explicit constexpr PrepareOutcomeState(
      Prepare command, GenerationHighWater generationHighWater) noexcept
      : command_(command), generationHighWater_(generationHighWater) {}

  PrepareOutcomeState() = delete;
  PrepareOutcomeState(const PrepareOutcomeState &) = delete;
  PrepareOutcomeState(PrepareOutcomeState &&) = delete;
  PrepareOutcomeState &operator=(const PrepareOutcomeState &) = delete;
  PrepareOutcomeState &operator=(PrepareOutcomeState &&) = delete;

  [[nodiscard]] constexpr Prepare command() const noexcept { return command_; }

  [[nodiscard]] constexpr GenerationHighWater
  generationHighWater() const noexcept {
    return generationHighWater_;
  }

  [[nodiscard]] constexpr PrepareDisposition disposition() const noexcept {
    return disposition_;
  }

  [[nodiscard]] constexpr bool admitted() const noexcept {
    return prepareFollows(generationHighWater_, command_);
  }

  [[nodiscard]] constexpr bool
  matchesPrepared(const Prepared &event) const noexcept {
    return disposition_ == PrepareDisposition::Outstanding && admitted() &&
           preparedMatches(command_, generationHighWater_, event);
  }

  [[nodiscard]] constexpr bool
  matchesUnsupportedSource(const UnsupportedSource &event) const noexcept {
    return disposition_ == PrepareDisposition::Outstanding && admitted() &&
           valid(event) && sameCommand(command_.stamp, event.stamp) &&
           command_.sourceKey == event.sourceKey;
  }

  // FailureReason::Preparation at the exact Prepare stamp is the proof
  // promised above: no Prepared/Started publication, no published or retained
  // state under the reserved generation, and all tentative resources already
  // released. If any condition is false, the backend must publish another
  // failure and retire through exact Stop.
  [[nodiscard]] constexpr bool
  matchesFailedBeforeResources(const Failed &event) const noexcept {
    return disposition_ == PrepareDisposition::Outstanding && admitted() &&
           valid(event) && event.reason == FailureReason::Preparation &&
           sameCommand(command_.stamp, event.stamp);
  }

  constexpr bool acceptPrepared(const Prepared &event) noexcept {
    if (!matchesPrepared(event)) {
      return false;
    }
    acceptedPrepared_ = event;
    disposition_ = PrepareDisposition::PreparedStopRequired;
    return true;
  }

  constexpr bool
  acceptUnsupportedSource(const UnsupportedSource &event) noexcept {
    if (!matchesUnsupportedSource(event)) {
      return false;
    }
    disposition_ = PrepareDisposition::UnsupportedBeforeResources;
    return true;
  }

  constexpr bool acceptFailedBeforeResources(const Failed &event) noexcept {
    if (!matchesFailedBeforeResources(event)) {
      return false;
    }
    disposition_ = PrepareDisposition::FailedBeforeResources;
    return true;
  }

  // Once Prepared wins, any later Failed fact still needs the attempt's exact
  // Stopped proof before ownership may transfer.
  [[nodiscard]] constexpr bool requiresStopProof() const noexcept {
    return disposition_ == PrepareDisposition::PreparedStopRequired;
  }

  [[nodiscard]] constexpr bool
  startFollows(const Start &command) const noexcept {
    // Startup derives only from the exact Prepared snapshot that won the
    // one-shot transition. No later, merely matching descriptor is accepted.
    return disposition_ == PrepareDisposition::PreparedStopRequired &&
           admitted() &&
           preparedMatches(command_, generationHighWater_, acceptedPrepared_) &&
           valid(command) && follows(acceptedPrepared_.stamp, command.stamp) &&
           command.preparedGeneration == acceptedPrepared_.generation;
  }

  [[nodiscard]] constexpr bool
  startedMatches(const Start &command, const Started &event) const noexcept {
    return startFollows(command) && valid(event) &&
           sameCommand(command.stamp, event.stamp) &&
           command.preparedGeneration == event.generation;
  }

private:
  Prepare command_;
  GenerationHighWater generationHighWater_;
  Prepared acceptedPrepared_{};
  PrepareDisposition disposition_{PrepareDisposition::Outstanding};
};

[[nodiscard]] constexpr bool valid(const PrepareOutcomeState &state) noexcept {
  return state.admitted();
}

[[nodiscard]] constexpr bool
runStateFollows(Stamp current, Generation activeGeneration,
                const SetRunState &command) noexcept {
  return valid(activeGeneration) && valid(command) &&
         follows(current, command.stamp) &&
         command.generation == activeGeneration;
}

[[nodiscard]] constexpr bool
previewFollows(Stamp current, Generation activeGeneration,
               const PreviewFrame &command) noexcept {
  return valid(activeGeneration) && valid(command) &&
         follows(current, command.stamp) &&
         command.generation == activeGeneration;
}

// A capacity-one preview slot replaces its current command only with a newer
// serial from the same attempt, generation, and gesture. A new gesture resets
// the slot in the owner instead of coalescing across gesture lifetimes. The
// exact retained command, not merely the largest request ID observed by a
// backend, owns completion.
[[nodiscard]] constexpr bool
previewSupersedes(const PreviewFrame &current,
                  const PreviewFrame &candidate) noexcept {
  return valid(current) && valid(candidate) &&
         follows(current.stamp, candidate.stamp) &&
         current.generation == candidate.generation &&
         current.gesture == candidate.gesture;
}

[[nodiscard]] constexpr bool
previewPresentedMatches(const PreviewFrame &latest,
                        const PreviewPresented &event) noexcept {
  return valid(latest) && valid(event) &&
         sameCommand(latest.stamp, event.stamp) &&
         latest.generation == event.generation &&
         latest.gesture == event.gesture && latest.request == event.request;
}

[[nodiscard]] constexpr bool
previewFailedMatches(const PreviewFrame &latest,
                     const PreviewFailed &event) noexcept {
  return valid(latest) && valid(event) &&
         sameCommand(latest.stamp, event.stamp) &&
         latest.generation == event.generation &&
         latest.gesture == event.gesture && latest.request == event.request &&
         latest.targetSeconds == event.targetSeconds;
}

[[nodiscard]] constexpr bool
commitFollows(Stamp current, Generation activeGeneration,
              GenerationHighWater generationHighWater,
              const CommitSeek &command) noexcept {
  return validLive(current) && validLive(activeGeneration) && valid(command) &&
         follows(current, command.stamp) &&
         command.sourceGeneration == activeGeneration &&
         freshLiveGeneration(command.targetGeneration, generationHighWater);
}

// When a gesture has previews, its commit must follow the exact latest
// retained preview. The commit request itself is new and therefore need not
// reuse the preview request ID or target.
[[nodiscard]] constexpr bool
commitFollowsLatestPreview(Stamp current, Generation activeGeneration,
                           const PreviewFrame &latest,
                           GenerationHighWater generationHighWater,
                           const CommitSeek &command) noexcept {
  return valid(latest) && validLive(current) && validLive(activeGeneration) &&
         sameAttempt(latest.stamp, current) &&
         latest.stamp.serial.value <= current.serial.value &&
         latest.generation == activeGeneration &&
         commitFollows(current, activeGeneration, generationHighWater,
                       command) &&
         latest.gesture == command.gesture;
}

[[nodiscard]] constexpr bool
commitReadyMatches(const CommitSeek &command, std::uint64_t drawBaseline,
                   const CommitReady &event) noexcept {
  return valid(command) && valid(event) &&
         sameCommand(command.stamp, event.stamp) &&
         command.targetGeneration == event.generation &&
         command.gesture == event.gesture && command.request == event.request &&
         command.targetSeconds == event.targetSeconds &&
         (event.videoDraw.videoLaneAbsent ||
          event.videoDraw.drawSequence > drawBaseline);
}

[[nodiscard]] constexpr bool endedMatches(Stamp current,
                                          Generation activeGeneration,
                                          const Ended &event) noexcept {
  return valid(activeGeneration) && valid(event) &&
         sameCommand(current, event.stamp) &&
         activeGeneration == event.generation;
}

[[nodiscard]] constexpr bool failedMatches(Stamp current,
                                           const Failed &event) noexcept {
  return valid(event) && sameCommand(current, event.stamp);
}

// generationHighWater may be zero when preparation failed before allocating
// any generation. The requested invalidation itself is always nonzero and
// must strictly retire every generation the attempt could have exposed.
[[nodiscard]] constexpr bool
stopFollows(Stamp current, GenerationHighWater generationHighWater,
            const Stop &command) noexcept {
  return validLive(current) && valid(command) &&
         follows(current, command.stamp) &&
         freshStopInvalidation(command.invalidationGeneration,
                               generationHighWater);
}

[[nodiscard]] constexpr bool stoppedMatches(const Stop &command,
                                            const Stopped &event) noexcept {
  return valid(command) && valid(event) &&
         sameCommand(command.stamp, event.stamp) &&
         command.invalidationGeneration == event.invalidationGeneration;
}

// An attempt is burned after its exact Stopped proof. Even a fact carrying a
// numerically later serial cannot resurrect it; a new attempt ID is required.
[[nodiscard]] constexpr bool rejectedAfterStop(const Stopped &stopped,
                                               Stamp fact) noexcept {
  return valid(stopped) && valid(fact) && stopped.stamp.attempt == fact.attempt;
}

} // namespace wam::media::native_playback
