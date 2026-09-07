#include "platform/macos/native_playback_owner.hpp"
#include <cstdlib>
#include <iostream>
#include <vector>

namespace native = wam::media::native_playback;
namespace router = wam::media::playback_router;
using namespace wam::macos;
namespace {
void expect(bool value, const char* message) {
  if (!value) { std::cerr << message << '\n'; std::exit(1); }
}
class Host final : public NativePlaybackOwner {
public:
  std::vector<char> events;
  native::SetRunState activate() {
    const auto prepare = router_.open({{1}, router::Route::NativeEligibleLocal, 0, false}, nextTick()).action->prepare;
    const auto start = router_.onNativePrepared({prepare.stamp, prepare.sourceKey,
        {30, true, true}, prepare.reservedGeneration}, nextTick()).action->start;
    return router_.onNativeStarted({start.stamp, start.preparedGeneration, 0}, nextTick()).action->runState;
  }
  void deliver(NativeMediaSessionObservations observations) {
    consumeObservations(std::move(observations));
  }
private:
  std::optional<Preparation> preparationFor(native::SourceKey) override { return {}; }
  std::optional<router::Transition> beginFallbackCreate(const router::Action&) override { return {}; }
  bool beginFallbackOpen(const router::Action&) override { return false; }
  bool beginFallbackStop(const router::Action&) override { return false; }
  std::optional<router::Transition> applyFallbackRunState(const router::Action&) override { return {}; }
  void pruneSourceRecords() override {}
  void maybeCompleteFallbackStop() override {}
  void sessionCleared() noexcept override {}
  void surfaceNativeError(const char*) override { events.push_back('!'); }
  void ownerError(const char*) override { events.push_back('!'); }
  void ownerNotice(const char*) override {}
  void seekProgress(std::uint64_t) override {}
  void commitFailed(std::uint64_t, std::uint64_t) override {}
  void publishLifecycle(const NativeMediaSessionFact&, bool) override { events.push_back('L'); }
  void publishRunState(const NativeMediaSessionRunStateApplied&) override { events.push_back('R'); }
  void publishAudioClock(const native::AudioClockProof&) override { events.push_back('A'); }
  void publishVideoDraw(const native::VideoDrawProof&, bool) override { events.push_back('V'); }
  void publishPreviewPresented(const native::PreviewPresented&) override { events.push_back('P'); }
  void publishPreviewFailed(const native::PreviewFailed&) override { events.push_back('F'); }
  void publishCommitReady(const native::CommitReady&) override { events.push_back('C'); }
};
}
int main() {
  Host host;
  const auto command = host.activate();
  NativeMediaSessionObservations observations;
  observations.audioClock = native::AudioClockProof{command.stamp, command.generation, {1}, 0, true, 1};
  observations.videoDraw = native::VideoDrawProof{command.stamp, command.generation, 1, 0, 1.0/30};
  host.deliver(observations);
  expect(host.events == std::vector<char>({'A', 'V'}), "current facts are delivered in audio/video order");
  host.events.clear();
  observations.audioClock->stamp.serial.value--;
  host.deliver(observations);
  expect(host.events.empty(), "stale audio serial and duplicate draw cannot be republished");
  observations.audioClock.reset();
  observations.videoDraw->drawSequence = 2;
  observations.videoDraw->generation.value++;
  host.deliver(observations);
  expect(host.events.empty(), "foreign-generation draw cannot reach the host");
  observations.videoDraw->generation = command.generation;
  observations.lifecycle = native::Ended{command.stamp, command.generation, 30};
  host.deliver(observations);
  expect(host.events == std::vector<char>({'L'}), "terminal lifecycle invalidates coalesced generic draws before delivery");
}
