#include "media/native_playback_contract.hpp"

#include <cstdlib>
#include <iostream>
#include <limits>
#include <type_traits>
#include <utility>

namespace {

using namespace wam::media::native_playback;

int failures = 0;

void expect(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

constexpr AttemptId kAttempt{7};
constexpr SourceKey kSource{91};
constexpr Generation kPreparedGeneration{40};
constexpr GestureId kGesture{12};

constexpr Stamp stamp(std::uint64_t serial, AttemptId attempt = kAttempt) {
  return {attempt, Serial{serial}};
}

template <typename T>
concept HasGenerationMember = requires(T value) { value.generation; };

template <typename T>
concept HasPublicPrepareCommandField = requires(T value) { value.command_; };

template <typename T>
concept HasPublicPrepareDispositionField =
    requires(T value) { value.disposition_; };

template <typename T>
concept AcceptsExternalPreparedForStart =
    requires(const T &state, const Prepared &prepared, const Start &start) {
      state.startFollows(prepared, start);
    };

template <typename T>
concept AcceptsExternalPreparedForStarted = requires(
    const T &state, const Prepared &prepared, const Start &start,
    const Started &started) { state.startedMatches(prepared, start, started); };

void testLocalValidationAndRateRouting() {
  using DrawSequence = decltype(VideoDrawProof{}.drawSequence);

  static_assert(validPosition(0.0));
  static_assert(validPosition(-0.0));
  static_assert(!validPosition(-1.0));
  static_assert(routeForRate(1.0) == RateRoute::NativeVersion1);
  // The advertised pitch-preserved window is served natively; only rates
  // outside it fall back.
  static_assert(routeForRate(0.5) == RateRoute::NativeVersion1);
  static_assert(routeForRate(0.25) == RateRoute::NativeVersion1);
  static_assert(routeForRate(4.0) == RateRoute::NativeVersion1);
  static_assert(routeForRate(0.2) == RateRoute::Fallback);
  static_assert(routeForRate(4.001) == RateRoute::Fallback);
  static_assert(routeForRate(16.0) == RateRoute::Fallback);
  // Admission snaps onto the exact 1/64 grid, so no double ever reaches the
  // clock: the reduced rational is the only representation that crosses.
  static_assert(nativeRateRatio(1.0) == PlaybackRateRatio{1, 1});
  static_assert(nativeRateRatio(0.25) == PlaybackRateRatio{1, 4});
  static_assert(nativeRateRatio(0.5) == PlaybackRateRatio{1, 2});
  static_assert(nativeRateRatio(1.5) == PlaybackRateRatio{3, 2});
  static_assert(nativeRateRatio(1.25) == PlaybackRateRatio{5, 4});
  static_assert(nativeRateRatio(2.0) == PlaybackRateRatio{2, 1});
  static_assert(nativeRateRatio(4.0) == PlaybackRateRatio{4, 1});
  // A slider position that is not a binary rational snaps to its nearest
  // grid neighbour and stays there deterministically.
  static_assert(nativeRateRatio(0.3) == PlaybackRateRatio{19, 64});
  static_assert(nativeRateRatio(1.1) == PlaybackRateRatio{35, 32});
  // Every admitted ratio has a denominator dividing the grid, which is what
  // makes outputFrames * p / q exact for a 1024-frame device period.
  static_assert(kNativeRateGrid % nativeRateRatio(0.3).denominator == 0);
  static_assert(1024U % kNativeRateGrid == 0);
  static_assert(follows(stamp(1), stamp(2)));
  static_assert(!follows(stamp(2), stamp(2)));
  static_assert(canReserveLiveSerialAfter(Serial{1}));
  static_assert(!canReserveLiveSerialAfter(Serial{kMaximumLiveValue}));
  static_assert(canReserveStopSerialAfter(Serial{kMaximumLiveValue}));
  static_assert(!canReserveStopSerialAfter(Serial{kTerminalStopValue}));
  static_assert(canReserveLiveGenerationAfter(GenerationHighWater{1}));
  static_assert(
      !canReserveLiveGenerationAfter(GenerationHighWater{kMaximumLiveValue}));
  static_assert(
      canReserveStopInvalidationAfter(GenerationHighWater{kMaximumLiveValue}));
  static_assert(!canReserveStopInvalidationAfter(
      GenerationHighWater{kTerminalStopValue}));
  static_assert(!std::is_convertible_v<Serial, GenerationHighWater>);
  static_assert(!std::is_convertible_v<Generation, GenerationHighWater>);
  static_assert(!std::is_convertible_v<DrawSequence, GenerationHighWater>);
  static_assert(noexcept(valid(Prepare{})));
  static_assert(
      noexcept(preparedMatches(Prepare{}, GenerationHighWater{}, Prepared{})));
  static_assert(std::is_constructible_v<PrepareOutcomeState, Prepare,
                                        GenerationHighWater>);
  static_assert(!std::is_default_constructible_v<PrepareOutcomeState>);
  static_assert(!std::is_copy_constructible_v<PrepareOutcomeState>);
  static_assert(!std::is_move_constructible_v<PrepareOutcomeState>);
  static_assert(!std::is_copy_assignable_v<PrepareOutcomeState>);
  static_assert(!std::is_move_assignable_v<PrepareOutcomeState>);
  static_assert(!std::is_aggregate_v<PrepareOutcomeState>);
  static_assert(std::is_trivially_destructible_v<PrepareOutcomeState>);
  static_assert(!HasPublicPrepareCommandField<PrepareOutcomeState>);
  static_assert(!HasPublicPrepareDispositionField<PrepareOutcomeState>);
  static_assert(!AcceptsExternalPreparedForStart<PrepareOutcomeState>);
  static_assert(!AcceptsExternalPreparedForStarted<PrepareOutcomeState>);
  static_assert(
      !std::is_reference_v<
          decltype(std::declval<const PrepareOutcomeState &>().command())>);
  static_assert(
      !std::is_reference_v<decltype(std::declval<const PrepareOutcomeState &>()
                                        .generationHighWater())>);
  static_assert(std::is_trivially_copyable_v<PrepareDisposition>);
  static_assert(std::is_trivially_copyable_v<UnsupportedSource>);
  static_assert(!HasGenerationMember<UnsupportedSource>);
  static_assert(!std::is_same_v<PreviewPresented, CommitReady>);
  static_assert(!std::is_convertible_v<PreviewPresented, CommitReady>);
  static_assert(!std::is_same_v<PreviewPresented, PreviewFailed>);

  const double nan = std::numeric_limits<double>::quiet_NaN();
  const double infinity = std::numeric_limits<double>::infinity();
  expect(!validPosition(nan), "NaN is not a protocol position");
  expect(!validPosition(infinity), "+infinity is not a protocol position");
  expect(!validPosition(-infinity), "-infinity is not a protocol position");
  expect(routeForRate(nan) == RateRoute::Fallback,
         "a NaN rate routes to fallback");
  expect(routeForRate(infinity) == RateRoute::Fallback,
         "an infinite rate routes to fallback");
  expect(routeForRate(1.0000001) == RateRoute::NativeVersion1,
         "a rate inside the advertised window is served natively");
  expect(nativeRateRatio(1.0000001) == (PlaybackRateRatio{1, 1}),
         "admission snaps to the exact grid rather than approximating");
  expect(routeForRate(0.0) == RateRoute::Fallback,
         "a zero rate is outside the native window");
  expect(routeForRate(-1.0) == RateRoute::Fallback,
         "a negative rate is outside the native window");

  expect(!valid(Prepare{}), "default Prepare has zero lineage and source");
  expect(!valid(Prepare{stamp(1), SourceKey{}, kPreparedGeneration, 0.0}),
         "Prepare rejects a zero source key");
  expect(!valid(Prepare{stamp(1), kSource, kPreparedGeneration, -0.01}),
         "Prepare rejects a negative initial position");
  expect(!valid(Prepare{stamp(1), kSource, kPreparedGeneration, nan}),
         "Prepare rejects a NaN initial position");
  expect(!valid(Prepare{stamp(1), kSource, kPreparedGeneration, infinity}),
         "Prepare rejects an infinite initial position");
  expect(!valid(Prepare{
             {AttemptId{}, Serial{1}}, kSource, kPreparedGeneration, 0.0}),
         "Prepare rejects a zero attempt ID");
  expect(
      !valid(Prepare{{kAttempt, Serial{}}, kSource, kPreparedGeneration, 0.0}),
      "Prepare rejects a zero command serial");
  expect(!valid(Prepare{stamp(1), kSource, Generation{}, 0.0}),
         "Prepare rejects a zero reserved generation");
  expect(
      !valid(Prepare{stamp(1), kSource, Generation{kTerminalStopValue}, 0.0}),
      "Prepare cannot reserve the terminal invalidation generation");

  expect(!valid(Start{stamp(2), Generation{}, true}),
         "Start rejects a zero prepared generation");
  expect(!valid(Start{stamp(2), kPreparedGeneration, false}),
         "Start must establish the prepared generation paused");
  expect(valid(SetRunState{stamp(3), kPreparedGeneration, false, 1.25}),
         "a run rate inside the advertised window is a native command");
  expect(!valid(SetRunState{stamp(3), kPreparedGeneration, false, 8.0}),
         "unsupported run rates do not enter the native command stream");

  expect(!valid(PreviewFrame{stamp(4), kPreparedGeneration, GestureId{},
                             RequestId{1}, 2.0}),
         "PreviewFrame rejects a zero gesture ID");
  expect(!valid(PreviewFrame{stamp(4), kPreparedGeneration, kGesture,
                             RequestId{}, 2.0}),
         "PreviewFrame rejects a zero request ID");
  expect(
      !valid(PreviewFrame{stamp(4), Generation{}, kGesture, RequestId{1}, 2.0}),
      "PreviewFrame rejects a zero generation");
  expect(!valid(PreviewFrame{stamp(4), kPreparedGeneration, kGesture,
                             RequestId{1}, nan}),
         "PreviewFrame rejects a NaN target");

  expect(!valid(CommitSeek{stamp(5), kPreparedGeneration, kPreparedGeneration,
                           kGesture, RequestId{2}, 3.0}),
         "CommitSeek must reserve a newer generation");
  expect(!valid(CommitSeek{stamp(5), kPreparedGeneration, Generation{},
                           kGesture, RequestId{2}, 3.0}),
         "CommitSeek rejects a zero target generation");
  expect(!valid(Stop{stamp(6), Generation{}}),
         "Stop rejects a zero invalidation generation");

  expect(!valid(Failed{stamp(2), static_cast<FailureReason>(0)}),
         "Failed rejects the default failure reason");
  expect(!valid(Failed{stamp(2), static_cast<FailureReason>(255)}),
         "Failed rejects reasons outside the bounded enumeration");
}

void testPreparationAndStartupProofs() {
  const double nan = std::numeric_limits<double>::quiet_NaN();
  const double infinity = std::numeric_limits<double>::infinity();
  const Prepare prepare{stamp(1), kSource, kPreparedGeneration, 2.0};
  const Prepared prepared{
      stamp(1), kSource, {20.0, true, true}, kPreparedGeneration};
  expect(preparedMatches(prepare, GenerationHighWater{}, prepared),
         "Prepared exactly proves its Prepare command");

  Prepared wrong = prepared;
  wrong.stamp.attempt = AttemptId{8};
  expect(!preparedMatches(prepare, GenerationHighWater{}, wrong),
         "a Prepared event from another attempt is stale");
  wrong = prepared;
  wrong.stamp.serial = Serial{2};
  expect(!preparedMatches(prepare, GenerationHighWater{}, wrong),
         "Prepared must echo the causal serial");
  wrong = prepared;
  wrong.sourceKey = SourceKey{92};
  expect(!preparedMatches(prepare, GenerationHighWater{}, wrong),
         "Prepared must echo the exact source key");
  wrong = prepared;
  wrong.generation = Generation{41};
  expect(!preparedMatches(prepare, GenerationHighWater{}, wrong),
         "Prepared must echo the exact reserved generation");
  wrong = prepared;
  wrong.descriptor.durationSeconds = 1.0;
  expect(!preparedMatches(prepare, GenerationHighWater{}, wrong),
         "a descriptor ending before the initial position is invalid proof");
  wrong = prepared;
  wrong.descriptor.hasVideo = false;
  expect(!preparedMatches(prepare, GenerationHighWater{}, wrong),
         "a video-less descriptor cannot prove native playback readiness");
  wrong = prepared;
  wrong.descriptor.durationSeconds = nan;
  expect(!preparedMatches(prepare, GenerationHighWater{}, wrong),
         "a NaN descriptor duration is not preparation proof");
  wrong = prepared;
  wrong.descriptor.durationSeconds = infinity;
  expect(!preparedMatches(prepare, GenerationHighWater{}, wrong),
         "an infinite descriptor duration is not preparation proof");

  const Start start{stamp(2), kPreparedGeneration, true};
  PrepareOutcomeState state{prepare, GenerationHighWater{}};
  expect(!state.startFollows(start),
         "Start cannot bypass settlement of the authoritative Prepare state");
  const Started started{stamp(2), kPreparedGeneration, 100};
  expect(!state.startedMatches(start, started),
         "Started cannot prove startup while Prepare remains outstanding");
  const Failed contradictoryFailure{prepare.stamp, FailureReason::Preparation};
  expect(state.matchesFailedBeforeResources(contradictoryFailure),
         "Preparation failure remains available only before Prepared wins");

  PrepareOutcomeState failedState{prepare, GenerationHighWater{}};
  expect(failedState.acceptFailedBeforeResources(contradictoryFailure) &&
             failedState.disposition() ==
                 PrepareDisposition::FailedBeforeResources &&
             !failedState.startFollows(start) &&
             !failedState.startedMatches(start, started),
         "a pre-resource failure settles the outcome and permanently rejects "
         "the contradictory Prepared startup chain");

  expect(state.acceptPrepared(prepared) &&
             state.disposition() == PrepareDisposition::PreparedStopRequired,
         "the exact Prepared fact settles authoritative state before Start");
  Prepared substitutedPrepared = prepared;
  substitutedPrepared.descriptor.durationSeconds = 3.0;
  substitutedPrepared.descriptor.hasAudio = false;
  expect(preparedMatches(prepare, GenerationHighWater{}, substitutedPrepared),
         "the adversarial descriptor is independently valid for Prepare");
  expect(!state.acceptPrepared(substitutedPrepared) &&
             state.startFollows(start),
         "a later matching descriptor cannot replace or influence the exact "
         "Prepared snapshot that won");
  expect(state.startFollows(start),
         "Start follows the exact prepared generation");
  expect(!state.startFollows(
             Start{stamp(2, AttemptId{8}), kPreparedGeneration, true}),
         "Start cannot cross attempts");
  expect(!state.startFollows(Start{stamp(2), Generation{41}, true}),
         "Start cannot substitute a different prepared generation");
  expect(!state.startFollows(Start{stamp(1), kPreparedGeneration, true}),
         "Start must have a newer monotonic serial");

  expect(state.startedMatches(start, started),
         "Started proves the exact Start command and generation");
  expect(
      !state.startedMatches(start, Started{stamp(3), kPreparedGeneration, 100}),
      "a newer-looking but non-causal Started serial is rejected");
  expect(!state.startedMatches(start, Started{stamp(2), Generation{41}, 100}),
         "Started cannot switch generations");
  expect(!state.matchesFailedBeforeResources(contradictoryFailure) &&
             !state.acceptFailedBeforeResources(contradictoryFailure),
         "Preparation failure cannot contradict accepted Prepared startup");

  expect(
      runStateFollows(started.stamp, started.generation,
                      SetRunState{stamp(3), kPreparedGeneration, false, 1.0}),
      "run state follows startup on the active generation");
  expect(!runStateFollows(started.stamp, started.generation,
                          SetRunState{stamp(3, AttemptId{8}),
                                      kPreparedGeneration, false, 1.0}),
         "run state cannot cross attempt lineage");
}

void testPrepareReservationAndOneShotOutcome() {
  const GenerationHighWater highWater{40};
  const Prepare prepare{stamp(20), kSource, Generation{41}, 3.0};
  expect(prepareFollows(highWater, prepare),
         "Prepare admits a strictly fresh live generation reservation");

  Prepare stale = prepare;
  stale.reservedGeneration = Generation{40};
  expect(!prepareFollows(highWater, stale),
         "Prepare cannot reuse the generation high-water mark");
  stale.reservedGeneration = Generation{39};
  expect(!prepareFollows(highWater, stale),
         "Prepare cannot reserve a generation below the high-water mark");
  stale.reservedGeneration = Generation{};
  expect(!prepareFollows(highWater, stale),
         "Prepare cannot reserve generation zero");
  stale.reservedGeneration = Generation{kTerminalStopValue};
  expect(!prepareFollows(highWater, stale),
         "Prepare cannot consume the terminal invalidation reservation");

  const Prepared prepared{
      prepare.stamp, kSource, {30.0, true, true}, prepare.reservedGeneration};
  Prepared wrongGeneration = prepared;
  wrongGeneration.generation = Generation{42};
  expect(!preparedMatches(prepare, highWater, wrongGeneration),
         "Prepared cannot substitute a generation for the reservation");

  PrepareOutcomeState preparedState{prepare, highWater};
  expect(valid(preparedState),
         "admitted Prepare creates a valid authoritative outcome state");
  Prepare commandSnapshot = preparedState.command();
  commandSnapshot.sourceKey = SourceKey{999};
  GenerationHighWater highWaterSnapshot = preparedState.generationHighWater();
  highWaterSnapshot.value = 999;
  expect(preparedState.command().sourceKey == prepare.sourceKey &&
             preparedState.generationHighWater() == highWater,
         "value snapshots cannot retarget the authoritative identity");

  const Prepare retargetedPrepare{stamp(22), SourceKey{92}, Generation{42},
                                  4.0};
  const Prepared retargetedPrepared{retargetedPrepare.stamp,
                                    retargetedPrepare.sourceKey,
                                    {30.0, true, true},
                                    retargetedPrepare.reservedGeneration};
  const UnsupportedSource retargetedUnsupported{retargetedPrepare.stamp,
                                                retargetedPrepare.sourceKey};
  const Failed retargetedFailure{retargetedPrepare.stamp,
                                 FailureReason::Preparation};
  expect(!preparedState.acceptPrepared(retargetedPrepared) &&
             !preparedState.acceptUnsupportedSource(retargetedUnsupported) &&
             !preparedState.acceptFailedBeforeResources(retargetedFailure) &&
             preparedState.disposition() == PrepareDisposition::Outstanding,
         "matching facts for another constructed outcome cannot consume the "
         "authoritative state");
  PrepareOutcomeState retargetedState{retargetedPrepare, highWater};
  expect(retargetedState.acceptPrepared(retargetedPrepared),
         "the same retargeted fact is valid only for its own state");

  PrepareOutcomeState unsupportedState{prepare, highWater};
  const UnsupportedSource unsupported{prepare.stamp, prepare.sourceKey};
  expect(unsupportedState.matchesUnsupportedSource(unsupported),
         "the exact unsupported fact matches only the outstanding state");

  UnsupportedSource wrongUnsupported = unsupported;
  wrongUnsupported.stamp.attempt = AttemptId{8};
  expect(!unsupportedState.acceptUnsupportedSource(wrongUnsupported),
         "UnsupportedSource rejects the wrong attempt");
  wrongUnsupported = unsupported;
  wrongUnsupported.stamp.serial = Serial{21};
  expect(!unsupportedState.acceptUnsupportedSource(wrongUnsupported),
         "UnsupportedSource rejects a stale or unrelated serial");
  wrongUnsupported = unsupported;
  wrongUnsupported.sourceKey = SourceKey{92};
  expect(!unsupportedState.acceptUnsupportedSource(wrongUnsupported),
         "UnsupportedSource rejects the wrong source");
  expect(unsupportedState.disposition() == PrepareDisposition::Outstanding,
         "mismatched facts do not transition authoritative state");
  expect(unsupportedState.acceptUnsupportedSource(unsupported) &&
             unsupportedState.disposition() ==
                 PrepareDisposition::UnsupportedBeforeResources,
         "the exact pre-resource unsupported fact settles the outcome");
  expect(!unsupportedState.matchesUnsupportedSource(unsupported) &&
             !unsupportedState.acceptUnsupportedSource(unsupported),
         "a duplicate unsupported fact cannot trigger fallback twice");
  expect(!unsupportedState.acceptPrepared(prepared) &&
             !unsupportedState.requiresStopProof(),
         "pre-allocation unsupported needs no native Stop proof");

  expect(preparedState.matchesPrepared(prepared),
         "the exact Prepared fact matches an outstanding state");
  expect(preparedState.acceptPrepared(prepared) &&
             preparedState.disposition() ==
                 PrepareDisposition::PreparedStopRequired,
         "Prepared settles the authoritative state with a Stop obligation");
  expect(!preparedState.matchesPrepared(prepared) &&
             !preparedState.acceptPrepared(prepared),
         "a duplicate Prepared fact cannot settle twice");
  expect(!preparedState.matchesUnsupportedSource(unsupported) &&
             !preparedState.acceptUnsupportedSource(unsupported),
         "UnsupportedSource cannot match after Prepared");
  expect(preparedState.requiresStopProof(),
         "a prepared attempt requires exact Stop proof before transfer");
  const Failed postPrepareFailure{stamp(21), FailureReason::Decode};
  expect(valid(postPrepareFailure) && preparedState.requiresStopProof(),
         "post-prepare failure does not replace required Stop proof");
  const Stop retirement{stamp(21), Generation{42}};
  expect(stopFollows(prepare.stamp,
                     GenerationHighWater{prepare.reservedGeneration.value},
                     retirement),
         "Stop can reserve an invalidation strictly above Prepare's live "
         "generation");
  expect(!stopFollows(prepare.stamp, GenerationHighWater{42}, retirement),
         "Stop cannot reuse a generation already at the high-water mark");

  PrepareOutcomeState failedState{prepare, highWater};
  const Failed failedBeforeResources{prepare.stamp, FailureReason::Preparation};
  expect(failedState.matchesFailedBeforeResources(failedBeforeResources),
         "exact Preparation failure proves resource-free preparation failure");
  expect(failedState.acceptFailedBeforeResources(failedBeforeResources) &&
             failedState.disposition() ==
                 PrepareDisposition::FailedBeforeResources,
         "pre-resource failure settles the authoritative outcome");
  expect(!failedState.requiresStopProof(),
         "a proven pre-resource failure permits immediate fallback");
  expect(!failedState.matchesPrepared(prepared) &&
             !failedState.acceptPrepared(prepared),
         "Prepared cannot follow a settled pre-resource failure");
  expect(!failedState.matchesUnsupportedSource(unsupported) &&
             !failedState.acceptUnsupportedSource(unsupported),
         "UnsupportedSource cannot follow a settled pre-resource failure");

  const Failed wrongFailureStamp{stamp(21), FailureReason::Preparation};
  PrepareOutcomeState wrongFailureState{prepare, highWater};
  expect(!wrongFailureState.acceptFailedBeforeResources(wrongFailureStamp),
         "pre-resource failure must echo the exact Prepare stamp");
  const Failed wrongFailureReason{prepare.stamp, FailureReason::Startup};
  expect(!wrongFailureState.acceptFailedBeforeResources(wrongFailureReason),
         "only Preparation carries the pre-resource release guarantee");
  const Failed contradictoryAfterPrepared{prepare.stamp,
                                          FailureReason::Preparation};
  expect(
      !preparedState.matchesFailedBeforeResources(contradictoryAfterPrepared) &&
          !preparedState.acceptFailedBeforeResources(
              contradictoryAfterPrepared) &&
          preparedState.requiresStopProof(),
      "Preparation cannot bypass Stop after Prepared exposed resources");
}

void testLatestPreviewProof() {
  const double infinity = std::numeric_limits<double>::infinity();
  const Stamp current = stamp(3);
  const PreviewFrame first{stamp(4), kPreparedGeneration, kGesture,
                           RequestId{100}, 4.0};
  const PreviewFrame latest{stamp(5), kPreparedGeneration, kGesture,
                            RequestId{101}, 8.0};
  expect(previewFollows(current, kPreparedGeneration, first),
         "a preview follows the live generation");
  expect(previewSupersedes(first, latest),
         "the later serial replaces the capacity-one preview");
  expect(!previewSupersedes(latest, first),
         "an older preview cannot replace a newer preview");
  expect(!previewSupersedes(first, PreviewFrame{stamp(5), Generation{41},
                                                kGesture, RequestId{101}, 8.0}),
         "a preview from another generation cannot replace the slot");
  expect(!previewSupersedes(first,
                            PreviewFrame{stamp(5), kPreparedGeneration,
                                         GestureId{13}, RequestId{101}, 8.0}),
         "a new gesture resets instead of coalescing the preview slot");

  const PreviewPresented firstFact{stamp(4), kPreparedGeneration, kGesture,
                                   RequestId{100}, 3.96};
  const PreviewPresented latestFact{stamp(5), kPreparedGeneration, kGesture,
                                    RequestId{101}, 7.92};
  expect(previewPresentedMatches(first, firstFact),
         "a preview may report an actual PTS different from its target");
  expect(!previewPresentedMatches(latest, firstFact),
         "a superseded preview fact cannot satisfy the latest command");
  expect(previewPresentedMatches(latest, latestFact),
         "the exact latest preview fact is accepted");

  const PreviewFailed latestFailure{latest.stamp, latest.generation,
                                    latest.gesture, latest.request,
                                    latest.targetSeconds};
  expect(previewFailedMatches(latest, latestFailure) &&
             !previewFailedMatches(first, latestFailure),
         "only the exact latest preview failure retires its command");
  PreviewFailed wrongFailure = latestFailure;
  wrongFailure.targetSeconds = 7.5;
  expect(!previewFailedMatches(latest, wrongFailure),
         "preview failure rejects an echoed target mismatch");
  wrongFailure = latestFailure;
  wrongFailure.request = RequestId{100};
  expect(!previewFailedMatches(latest, wrongFailure),
         "preview failure rejects a wrong request");

  PreviewPresented wrong = latestFact;
  wrong.stamp.attempt = AttemptId{8};
  expect(!previewPresentedMatches(latest, wrong),
         "preview proof rejects a wrong attempt");
  wrong = latestFact;
  wrong.generation = Generation{41};
  expect(!previewPresentedMatches(latest, wrong),
         "preview proof rejects a wrong generation");
  wrong = latestFact;
  wrong.request = RequestId{100};
  expect(!previewPresentedMatches(latest, wrong),
         "preview proof rejects a wrong request");
  wrong = latestFact;
  wrong.gesture = GestureId{13};
  expect(!previewPresentedMatches(latest, wrong),
         "preview proof rejects a wrong gesture");
  wrong = latestFact;
  wrong.actualPresentationTimeSeconds = infinity;
  expect(!previewPresentedMatches(latest, wrong),
         "preview proof rejects an infinite actual PTS");
}

CommitReady readyFor(const CommitSeek &command, std::uint64_t drawSequence) {
  const AudioClockProof audio{command.stamp,
                              command.targetGeneration,
                              AudioClockAnchorId{70},
                              command.targetSeconds,
                              true,
                              1.0};
  const VideoDrawProof video{command.stamp, command.targetGeneration,
                             drawSequence, command.targetSeconds, 1.0 / 30.0};
  return {command.stamp,
          command.targetGeneration,
          command.gesture,
          command.request,
          command.targetSeconds,
          audio,
          video};
}

void testCommitNeedsExactClockAndDrawProof() {
  const PreviewFrame latest{stamp(5), kPreparedGeneration, kGesture,
                            RequestId{101}, 8.0};
  const CommitSeek commit{stamp(6), kPreparedGeneration, Generation{41},
                          kGesture, RequestId{102},      8.25};
  expect(commitFollowsLatestPreview(latest.stamp, latest.generation, latest,
                                    GenerationHighWater{40}, commit),
         "commit follows the exact latest gesture and reserves a generation");
  expect(!commitFollowsLatestPreview(
             latest.stamp, latest.generation, latest, GenerationHighWater{41},
             CommitSeek{stamp(6), kPreparedGeneration, Generation{41}, kGesture,
                        RequestId{102}, 8.25}),
         "commit generation must exceed the complete generation high-water");
  expect(!commitFollowsLatestPreview(stamp(10), latest.generation, latest,
                                     GenerationHighWater{40}, commit),
         "commit must follow the attempt-wide current serial, not merely the "
         "retained preview");
  CommitSeek afterCurrent = commit;
  afterCurrent.stamp = stamp(11);
  expect(commitFollowsLatestPreview(stamp(10), latest.generation, latest,
                                    GenerationHighWater{40}, afterCurrent),
         "a retained preview remains bindable after intervening live work");
  const CommitSeek staleGenerationCommit{stamp(11),      Generation{40},
                                         Generation{42}, kGesture,
                                         RequestId{103}, 8.25};
  expect(!commitFollowsLatestPreview(stamp(10), Generation{41}, latest,
                                     GenerationHighWater{41},
                                     staleGenerationCommit),
         "a retained preview from generation 40 cannot commit after generation "
         "41 became active");

  const CommitReady ready = readyFor(commit, 101);
  expect(commitReadyMatches(commit, 100, ready),
         "commit converges on its exact audio anchor and a newer video draw");
  expect(!commitReadyMatches(commit, 101, ready),
         "a retained baseline draw is not a post-commit draw proof");

  CommitReady wrong = ready;
  wrong.stamp.attempt = AttemptId{8};
  wrong.audioClock.stamp = wrong.stamp;
  wrong.videoDraw.stamp = wrong.stamp;
  expect(!commitReadyMatches(commit, 100, wrong),
         "commit proof rejects a wrong attempt");
  wrong = ready;
  wrong.generation = Generation{42};
  wrong.audioClock.generation = Generation{42};
  wrong.videoDraw.generation = Generation{42};
  expect(!commitReadyMatches(commit, 100, wrong),
         "commit proof rejects a wrong generation");
  wrong = ready;
  wrong.request = RequestId{103};
  expect(!commitReadyMatches(commit, 100, wrong),
         "commit proof rejects a wrong request");
  wrong = ready;
  wrong.targetSeconds = 8.5;
  wrong.audioClock.positionSeconds = 8.5;
  expect(!commitReadyMatches(commit, 100, wrong),
         "commit proof must echo the exact requested target");
  wrong = ready;
  wrong.audioClock.positionSeconds = 8.0;
  expect(!valid(wrong), "commit proof requires its exact audio clock target");
  wrong = ready;
  wrong.audioClock.paused = false;
  expect(!valid(wrong), "commit clock proof must be paused");
  wrong = ready;
  wrong.audioClock.rate = 8.0;
  expect(!valid(wrong), "commit clock proof rejects unsupported rate");
  wrong = ready;
  wrong.audioClock.rate = 1.25;
  expect(valid(wrong),
         "commit clock proof accepts a rate inside the advertised window");
  wrong = ready;
  wrong.audioClock.anchor = AudioClockAnchorId{};
  expect(!valid(wrong), "commit clock proof requires a nonzero anchor ID");
  wrong = ready;
  wrong.videoDraw.drawSequence = 0;
  expect(!valid(wrong), "commit video proof requires a nonzero draw ID");
  wrong = ready;
  wrong.videoDraw.frameDurationSeconds = 0.0;
  expect(!valid(wrong), "commit video proof requires a positive frame span");
  wrong = ready;
  wrong.videoDraw.frameStartSeconds = commit.targetSeconds + 0.01;
  expect(!valid(wrong),
         "a frame entirely after the target is not exact commit proof");
  wrong = ready;
  wrong.videoDraw.frameStartSeconds = commit.targetSeconds - 1.0;
  wrong.videoDraw.frameDurationSeconds = 0.5;
  expect(!valid(wrong),
         "a frame ending before the target is not exact commit proof");

  const PreviewPresented preview{latest.stamp, latest.generation,
                                 latest.gesture, latest.request, 8.0};
  expect(previewPresentedMatches(latest, preview),
         "the adversarial preview is a valid preview proof");
  expect(!std::is_convertible_v<decltype(preview), CommitReady>,
         "a preview proof cannot be confused with commit readiness");
}

void testTerminalAndStopProofs() {
  const Stamp current = stamp(7);
  const Generation currentGeneration{41};
  const Ended ended{current, currentGeneration, 20.0};
  expect(endedMatches(current, currentGeneration, ended),
         "Ended matches the exact current generation and command stamp");
  expect(!endedMatches(stamp(8), currentGeneration, ended),
         "an Ended fact cannot satisfy a newer command");
  expect(!valid(Ended{current, currentGeneration,
                      std::numeric_limits<double>::infinity()}),
         "Ended rejects an infinite final position");

  const Failed failed{current, FailureReason::Decode};
  expect(failedMatches(current, failed),
         "Failed matches the exact current command stamp");
  expect(!failedMatches(stamp(8), failed),
         "a stale Failed fact cannot fail a newer command");

  const Stop stop{stamp(8), Generation{42}};
  expect(stopFollows(current, GenerationHighWater{41}, stop),
         "Stop reserves an invalidation newer than every exposed generation");
  expect(!stopFollows(current, GenerationHighWater{42}, stop),
         "Stop cannot reuse the generation high-water mark");
  expect(!stopFollows(current, GenerationHighWater{41},
                      Stop{stamp(8, AttemptId{8}), Generation{42}}),
         "Stop cannot cross attempts");

  const Stopped stopped{stamp(8), Generation{42}};
  expect(stoppedMatches(stop, stopped),
         "Stopped proves the exact requested invalidation");
  expect(!stoppedMatches(stop, Stopped{stamp(8), Generation{43}}),
         "a different invalidation cannot prove Stop");
  expect(!stoppedMatches(stop, Stopped{stamp(9), Generation{42}}),
         "a different serial cannot prove Stop");
  expect(!std::is_convertible_v<Ended, Stopped> &&
             !std::is_convertible_v<Failed, Stopped>,
         "Ended and Failed are not stop proofs");
  expect(rejectedAfterStop(stopped, stamp(9)),
         "the retired attempt rejects even later facts");
  expect(!rejectedAfterStop(stopped, stamp(1, AttemptId{8})),
         "a distinct nonzero attempt remains admissible");
}

void testTerminalReservationAndGenerationExhaustion() {
  constexpr AttemptId boundaryAttempt{80};
  const Stamp lastLive{boundaryAttempt, Serial{kMaximumLiveValue}};
  const Stamp terminal{boundaryAttempt, Serial{kTerminalStopValue}};
  const Generation lastLiveGeneration{kMaximumLiveValue};

  expect(validLive(lastLive), "UINT64_MAX - 1 is the final live serial");
  expect(validLive(lastLiveGeneration),
         "UINT64_MAX - 1 is the final live generation");
  expect(!validLive(terminal), "UINT64_MAX is not a live serial");
  expect(!validLive(Generation{kTerminalStopValue}),
         "UINT64_MAX is not a live generation");

  const SetRunState lastLiveCommand{lastLive, lastLiveGeneration, true, 1.0};
  expect(valid(lastLiveCommand),
         "a nonterminal command may consume UINT64_MAX - 1");
  expect(!valid(SetRunState{terminal, lastLiveGeneration, true, 1.0}),
         "the reserved maximum cannot be a nonterminal command serial");
  expect(!valid(Started{terminal, lastLiveGeneration, 0}),
         "Started cannot consume the terminal command serial");
  expect(!valid(PreviewPresented{terminal, lastLiveGeneration, GestureId{1},
                                 RequestId{1}, 0.0}),
         "PreviewPresented cannot consume the terminal command serial");
  expect(!runStateFollows(lastLive, lastLiveGeneration,
                          SetRunState{terminal, lastLiveGeneration, true, 1.0}),
         "serial exhaustion cannot wrap or consume the Stop reservation");

  const CommitSeek lastGenerationCommit{
      {boundaryAttempt, Serial{kMaximumLiveValue}},
      Generation{kMaximumLiveValue - 1},
      lastLiveGeneration,
      GestureId{1},
      RequestId{1},
      0.0};
  expect(valid(lastGenerationCommit),
         "CommitSeek may allocate the final live generation");
  CommitSeek terminalGenerationCommit = lastGenerationCommit;
  terminalGenerationCommit.targetGeneration = Generation{kTerminalStopValue};
  expect(!valid(terminalGenerationCommit),
         "CommitSeek cannot consume the terminal invalidation generation");
  expect(!valid(Prepared{{boundaryAttempt, Serial{1}},
                         kSource,
                         {20.0, true, true},
                         Generation{kTerminalStopValue}}),
         "Prepared cannot publish the terminal invalidation generation");
  const Prepare lastGenerationPrepare{
      {boundaryAttempt, Serial{1}}, kSource, lastLiveGeneration, 0.0};
  const GenerationHighWater beforeLastGeneration{kMaximumLiveValue - 1};
  const Prepared lastGenerationPrepared{lastGenerationPrepare.stamp,
                                        kSource,
                                        {20.0, true, true},
                                        lastLiveGeneration};
  expect(prepareFollows(beforeLastGeneration, lastGenerationPrepare) &&
             preparedMatches(lastGenerationPrepare, beforeLastGeneration,
                             lastGenerationPrepared),
         "Prepare may reserve and Prepared may echo UINT64_MAX - 1");

  const Stop stop{terminal, Generation{kTerminalStopValue}};
  expect(valid(stop), "Stop may use UINT64_MAX exactly");
  expect(stopFollows(lastLive, GenerationHighWater{kMaximumLiveValue}, stop),
         "the max Stop serial and invalidation retire a max-1 live state");
  expect(
      stoppedMatches(stop, Stopped{terminal, Generation{kTerminalStopValue}}),
      "Stopped can prove the exact maximum invalidation");
  expect(valid(Failed{terminal, FailureReason::Stop}),
         "a Stop failure may echo the terminal Stop serial");
  expect(!valid(Failed{terminal, FailureReason::Decode}),
         "a live failure cannot consume the terminal Stop serial");
  expect(!canReserveLiveSerialAfter(Serial{kMaximumLiveValue}) &&
             canReserveStopSerialAfter(Serial{kMaximumLiveValue}),
         "max-1 serial exhaustion leaves only Stop representable");
  expect(
      !canReserveLiveGenerationAfter(GenerationHighWater{kMaximumLiveValue}) &&
          canReserveStopInvalidationAfter(
              GenerationHighWater{kMaximumLiveValue}),
      "max-1 generation exhaustion leaves only invalidation representable");

  constexpr AttemptId nextAttempt{81};
  const Stopped priorStop{{kAttempt, Serial{8}}, Generation{42}};
  expect(valid(priorStop),
         "the prior attempt supplies a valid exact Stop invalidation");
  const GenerationHighWater priorStopHighWater{
      priorStop.invalidationGeneration.value};
  const Prepare nextPrepare{
      {nextAttempt, Serial{1}}, kSource, Generation{42}, 0.0};
  const Prepared stale{
      {nextAttempt, Serial{1}}, kSource, {20.0, true, true}, Generation{42}};
  expect(!prepareFollows(priorStopHighWater, nextPrepare),
         "a new attempt cannot reserve the prior invalidation generation");
  expect(!preparedMatches(nextPrepare, priorStopHighWater, stale),
         "a new attempt cannot reuse the prior Stop invalidation generation");
  Prepare freshPrepare = nextPrepare;
  freshPrepare.reservedGeneration = Generation{43};
  Prepared fresh = stale;
  fresh.generation = freshPrepare.reservedGeneration;
  expect(prepareFollows(priorStopHighWater, freshPrepare) &&
             preparedMatches(freshPrepare, priorStopHighWater, fresh),
         "a new attempt may publish a strictly fresh live generation");
  Prepare terminalPrepare = freshPrepare;
  terminalPrepare.reservedGeneration = Generation{kTerminalStopValue};
  fresh.generation = Generation{kTerminalStopValue};
  expect(!prepareFollows(GenerationHighWater{kMaximumLiveValue},
                         terminalPrepare) &&
             !preparedMatches(terminalPrepare,
                              GenerationHighWater{kMaximumLiveValue}, fresh),
         "Prepared cannot allocate UINT64_MAX after generation exhaustion");
}

void testValidSequence() {
  const Prepare prepare{stamp(1), kSource, kPreparedGeneration, 0.0};
  const Prepared prepared{
      prepare.stamp, kSource, {60.0, true, true}, kPreparedGeneration};
  const Start start{stamp(2), prepared.generation, true};
  const Started started{start.stamp, prepared.generation, 10};
  const SetRunState run{stamp(3), started.generation, false, 1.0};
  const PreviewFrame preview{stamp(4), started.generation, kGesture,
                             RequestId{1}, 10.0};
  const PreviewPresented presented{preview.stamp, preview.generation,
                                   preview.gesture, preview.request, 9.96};
  const CommitSeek commit{stamp(5), started.generation, Generation{41},
                          kGesture, RequestId{2},       10.0};
  const CommitReady committed = readyFor(commit, 11);
  const SetRunState resumed{stamp(6), commit.targetGeneration, false, 1.0};
  const Stop stop{stamp(7), Generation{42}};
  const Stopped stopped{stop.stamp, stop.invalidationGeneration};
  PrepareOutcomeState prepareState{prepare, GenerationHighWater{}};
  const bool acceptedPrepared = prepareState.acceptPrepared(prepared);

  expect(preparedMatches(prepare, GenerationHighWater{}, prepared) &&
             acceptedPrepared &&
             prepareState.disposition() ==
                 PrepareDisposition::PreparedStopRequired &&
             prepareState.startFollows(start) &&
             prepareState.startedMatches(start, started) &&
             runStateFollows(started.stamp, started.generation, run) &&
             previewFollows(run.stamp, run.generation, preview) &&
             previewPresentedMatches(preview, presented) &&
             commitFollowsLatestPreview(preview.stamp, preview.generation,
                                        preview, GenerationHighWater{40},
                                        commit) &&
             commitReadyMatches(commit, started.drawBaseline, committed) &&
             runStateFollows(commit.stamp, commit.targetGeneration, resumed) &&
             stopFollows(resumed.stamp, GenerationHighWater{41}, stop) &&
             stoppedMatches(stop, stopped),
         "the complete version 1 protocol sequence is valid");
}

} // namespace

int main() {
  testLocalValidationAndRateRouting();
  testPreparationAndStartupProofs();
  testPrepareReservationAndOneShotOutcome();
  testLatestPreviewProof();
  testCommitNeedsExactClockAndDrawProof();
  testTerminalAndStopProofs();
  testTerminalReservationAndGenerationExhaustion();
  testValidSequence();

  if (failures == 0) {
    std::cout << "native playback contract tests passed\n";
  }
  return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
