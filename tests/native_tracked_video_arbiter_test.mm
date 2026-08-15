#include "platform/macos/native_tracked_video_arbiter.hpp"

#include <CoreVideo/CoreVideo.h>

#include <concepts>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace {

using wam::macos::FrameLease;
using wam::macos::FrameTiming;
using wam::macos::NativeTrackedFrameSequence;
using wam::macos::NativeTrackedVideoArbiter;
using wam::macos::NativeTrackedVideoCapacity;
using wam::macos::NativeTrackedVideoEvent;
using wam::macos::NativeTrackedVideoEventKind;
using wam::macos::NativeTrackedVideoOutput;
using wam::macos::NativeTrackedVideoOutputFacts;
using wam::macos::NativeTrackedVideoOutputProgress;
using wam::macos::NativeTrackedVideoPreviewCancelProgress;
using wam::macos::NativeTrackedVideoPreviewEventKind;
using wam::macos::NativeTrackedVideoPreviewPort;
using wam::macos::NativeTrackedVideoSubmitStatus;

template <class Port>
concept HasFlushProgress = requires(Port& port) {
  port.flushProgress(std::uint64_t{1}, std::uint64_t{2});
};

template <class Port>
concept HasCloseProgress = requires(Port& port) {
  port.closeProgress(std::uint64_t{2});
};

static_assert(!HasFlushProgress<NativeTrackedVideoPreviewPort>);
static_assert(!HasCloseProgress<NativeTrackedVideoPreviewPort>);

int failures = 0;

void expect(bool condition, const char* message) {
  if (condition) {
    return;
  }
  ++failures;
  std::cerr << "FAIL: " << message << '\n';
}

[[nodiscard]] bool sameTime(CMTime lhs, CMTime rhs) noexcept {
  return lhs.value == rhs.value && lhs.timescale == rhs.timescale &&
         lhs.flags == rhs.flags && lhs.epoch == rhs.epoch;
}

[[nodiscard]] bool sameTiming(const FrameTiming& lhs,
                              const FrameTiming& rhs) noexcept {
  return lhs.generation == rhs.generation &&
         lhs.keyFrame == rhs.keyFrame &&
         sameTime(lhs.presentationTime, rhs.presentationTime) &&
         sameTime(lhs.duration, rhs.duration);
}

FrameLease makeFrame(std::uint64_t generation, std::int64_t value) {
  CVPixelBufferRef pixelBuffer = nullptr;
  const CVReturn created = CVPixelBufferCreate(
      kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nullptr,
      &pixelBuffer);
  expect(created == kCVReturnSuccess && pixelBuffer != nullptr,
         "test pixel buffer is created");
  if (pixelBuffer == nullptr) {
    return {};
  }
  FrameLease frame(pixelBuffer,
                   FrameTiming{CMTimeMake(value, 600), CMTimeMake(20, 600),
                               generation, value == 0});
  CVPixelBufferRelease(pixelBuffer);
  expect(static_cast<bool>(frame), "test frame lease is valid");
  return frame;
}

class FakeTrackedOutput final : public NativeTrackedVideoOutput {
 public:
  explicit FakeTrackedOutput(std::uint64_t generation) noexcept
      : generation_(generation) {}

  [[nodiscard]] NativeTrackedVideoCapacity capacity(
      std::uint64_t generation) const noexcept override {
    if (fatal_ || closed_) {
      return NativeTrackedVideoCapacity::Failed;
    }
    if (generation != generation_) {
      return NativeTrackedVideoCapacity::StaleGeneration;
    }
    return admitted_.valid() || event_ || flushPending_ || closePending_
               ? NativeTrackedVideoCapacity::Backpressure
               : NativeTrackedVideoCapacity::Available;
  }

  [[nodiscard]] NativeTrackedVideoSubmitStatus submit(
      const FrameLease& frame, NativeTrackedFrameSequence sequence,
      std::string* error) noexcept override {
    if (error != nullptr) {
      error->clear();
    }
    if (!frame || !sequence.valid()) {
      return NativeTrackedVideoSubmitStatus::Failed;
    }
    switch (capacity(frame.timing().generation)) {
    case NativeTrackedVideoCapacity::Backpressure:
      return NativeTrackedVideoSubmitStatus::Backpressure;
    case NativeTrackedVideoCapacity::StaleGeneration:
      return NativeTrackedVideoSubmitStatus::StaleGeneration;
    case NativeTrackedVideoCapacity::Failed:
      return NativeTrackedVideoSubmitStatus::Failed;
    case NativeTrackedVideoCapacity::Available:
      break;
    }
    if (lastAccepted_.valid() && sequence.value <= lastAccepted_.value) {
      fatal_ = true;
      return NativeTrackedVideoSubmitStatus::Failed;
    }
    admitted_ = sequence;
    lastAccepted_ = sequence;
    timing_ = frame.timing();
    acceptedSequences_.push_back(sequence.value);
    ++submitted_;
    return NativeTrackedVideoSubmitStatus::Accepted;
  }

  [[nodiscard]] std::optional<NativeTrackedVideoEvent>
  takeEvent() noexcept override {
    std::optional<NativeTrackedVideoEvent> result = std::move(event_);
    event_.reset();
    if (result && result->frameSequence.valid()) {
      admitted_ = {};
      timing_ = {};
    }
    return result;
  }

  [[nodiscard]] NativeTrackedVideoOutputProgress flushProgress(
      std::uint64_t retiredGeneration,
      std::uint64_t nextGeneration) noexcept override {
    if (fatal_ || closed_ || nextGeneration <= retiredGeneration) {
      return NativeTrackedVideoOutputProgress::Failed;
    }
    if (flushPending_) {
      if (flushRetired_ != retiredGeneration ||
          flushNext_ != nextGeneration) {
        return NativeTrackedVideoOutputProgress::StaleGeneration;
      }
    } else {
      if (retiredGeneration != generation_) {
        return NativeTrackedVideoOutputProgress::StaleGeneration;
      }
      flushPending_ = true;
      flushRetired_ = retiredGeneration;
      flushNext_ = nextGeneration;
    }
    if (admitted_.valid() && !event_) {
      supersede();
    }
    if (admitted_.valid() || event_) {
      return NativeTrackedVideoOutputProgress::Quiescing;
    }
    generation_ = nextGeneration;
    flushPending_ = false;
    flushRetired_ = 0;
    flushNext_ = 0;
    return NativeTrackedVideoOutputProgress::Done;
  }

  [[nodiscard]] NativeTrackedVideoOutputProgress closeProgress(
      std::uint64_t finalGeneration) noexcept override {
    if (finalGeneration == 0 ||
        (!closePending_ && finalGeneration <= generation_)) {
      return NativeTrackedVideoOutputProgress::Failed;
    }
    if (closed_) {
      return finalGeneration == closeGeneration_
                 ? NativeTrackedVideoOutputProgress::Done
                 : NativeTrackedVideoOutputProgress::StaleGeneration;
    }
    if (closePending_ && closeGeneration_ != finalGeneration) {
      return NativeTrackedVideoOutputProgress::StaleGeneration;
    }
    closePending_ = true;
    closeGeneration_ = finalGeneration;
    if (admitted_.valid() && !event_) {
      supersede();
    }
    if (admitted_.valid() || event_) {
      return NativeTrackedVideoOutputProgress::Quiescing;
    }
    generation_ = finalGeneration;
    closePending_ = false;
    closed_ = true;
    return NativeTrackedVideoOutputProgress::Done;
  }

  [[nodiscard]] NativeTrackedVideoOutputFacts facts()
      const noexcept override {
    NativeTrackedVideoOutputFacts result;
    result.generation = generation_;
    result.admittedFrame = admitted_;
    result.submittedFrames = submitted_;
    result.drawnFrames = drawn_;
    result.supersededFrames = superseded_;
    result.lastEventSequence = eventSequence_;
    result.retainedFrames = admitted_.valid() ? 1U : 0U;
    result.eventPending = event_.has_value();
    result.invalidationPending = flushPending_ || closePending_;
    result.closed = closed_;
    result.fatal = fatal_;
    return result;
  }

  void draw() noexcept {
    expect(admitted_.valid() && !event_,
           "fake draw requires exactly one admitted frame");
    event_.emplace(NativeTrackedVideoEvent{
        NativeTrackedVideoEventKind::FrameDrawn, ++eventSequence_,
        admitted_, generation_, timing_});
    ++drawn_;
  }

  void publishInvalidated(std::uint64_t generation) noexcept {
    expect(!admitted_.valid() && !event_,
           "fake lifecycle event requires an empty mailbox");
    event_.emplace(NativeTrackedVideoEvent{
        NativeTrackedVideoEventKind::GenerationInvalidated,
        ++eventSequence_, {}, generation, {}});
  }

  void markDirty() noexcept {
    submitted_ = 1;
  }

  [[nodiscard]] const std::vector<std::uint64_t>&
  acceptedSequences() const noexcept {
    return acceptedSequences_;
  }

 private:
  void supersede() noexcept {
    event_.emplace(NativeTrackedVideoEvent{
        NativeTrackedVideoEventKind::FrameSuperseded, ++eventSequence_,
        admitted_, generation_, timing_});
    ++superseded_;
  }

  std::uint64_t generation_{0};
  NativeTrackedFrameSequence admitted_{};
  NativeTrackedFrameSequence lastAccepted_{};
  FrameTiming timing_{};
  std::optional<NativeTrackedVideoEvent> event_;
  std::vector<std::uint64_t> acceptedSequences_;
  std::uint64_t submitted_{0};
  std::uint64_t drawn_{0};
  std::uint64_t superseded_{0};
  std::uint64_t eventSequence_{0};
  std::uint64_t flushRetired_{0};
  std::uint64_t flushNext_{0};
  std::uint64_t closeGeneration_{0};
  bool flushPending_{false};
  bool closePending_{false};
  bool closed_{false};
  bool fatal_{false};
};

struct Fixture {
  explicit Fixture(std::uint64_t generation = 7)
      : output(std::make_shared<FakeTrackedOutput>(generation)),
        arbiter(NativeTrackedVideoArbiter::create(output)),
        main(arbiter == nullptr ? nullptr : arbiter->mainOutput()),
        preview(arbiter == nullptr ? nullptr : arbiter->previewPort()) {
    expect(arbiter != nullptr && main != nullptr && preview != nullptr,
           "fresh output creates both arbiter ports");
  }

  std::shared_ptr<FakeTrackedOutput> output;
  std::shared_ptr<NativeTrackedVideoArbiter> arbiter;
  std::shared_ptr<NativeTrackedVideoOutput> main;
  std::shared_ptr<NativeTrackedVideoPreviewPort> preview;
};

void creationRequiresFreshOutput() {
  std::string error;
  expect(!NativeTrackedVideoArbiter::create(nullptr, &error) &&
             !error.empty(),
         "null output is rejected with an error");

  auto dirty = std::make_shared<FakeTrackedOutput>(7);
  dirty->markDirty();
  error.clear();
  expect(!NativeTrackedVideoArbiter::create(dirty, &error) &&
             !error.empty(),
         "used output is rejected because internal sequence history is hidden");
}

void previewEventNeverAppearsAsMain() {
  Fixture fixture;
  FrameLease frame = makeFrame(7, 120);
  const FrameTiming timing = frame.timing();
  const auto submitted = fixture.preview->submit(7, frame);
  expect(submitted.status == NativeTrackedVideoSubmitStatus::Accepted &&
             submitted.sequence.value == 1,
         "arbiter assigns first typed preview sequence");
  expect(fixture.output->acceptedSequences() ==
             std::vector<std::uint64_t>{1},
         "arbiter assigns the first shared internal sequence");
  const NativeTrackedVideoOutputFacts hidden = fixture.main->facts();
  expect(!hidden.admittedFrame.valid() && hidden.submittedFrames == 0 &&
             hidden.lastEventSequence == 0 && hidden.retainedFrames == 1,
         "main facts hide preview identity and counters but retain shared credit");

  fixture.output->draw();
  expect(!fixture.main->takeEvent(),
         "polling main routes but never returns preview terminal event");
  expect(fixture.main->capacity(7) ==
             NativeTrackedVideoCapacity::Backpressure,
         "typed preview mailbox preserves global capacity one");
  const auto event = fixture.preview->takeEvent();
  expect(event && event->kind ==
                      NativeTrackedVideoPreviewEventKind::FrameDrawn &&
             event->frameSequence == submitted.sequence &&
             event->generation == 7 && sameTiming(event->timing, timing),
         "preview receives its exact translated draw fact");
  expect(!fixture.main->takeEvent() &&
             fixture.main->capacity(7) ==
                 NativeTrackedVideoCapacity::Available,
         "preview draw never enters main lane and releases shared credit once");
}

void mainEventNeverAppearsAsPreview() {
  Fixture fixture;
  FrameLease frame = makeFrame(7, 240);
  const FrameTiming timing = frame.timing();
  expect(fixture.main->submit(frame, NativeTrackedFrameSequence{41}, nullptr) ==
             NativeTrackedVideoSubmitStatus::Accepted,
         "main facade accepts caller identity");
  expect(fixture.output->acceptedSequences() ==
             std::vector<std::uint64_t>{1},
         "main caller identity is translated to arbiter identity");
  fixture.output->draw();
  expect(!fixture.preview->takeEvent(),
         "polling preview routes but never returns main terminal event");
  const auto event = fixture.main->takeEvent();
  expect(event && event->kind == NativeTrackedVideoEventKind::FrameDrawn &&
             event->frameSequence == NativeTrackedFrameSequence{41} &&
             event->eventSequence == 1 &&
             sameTiming(event->timing, timing),
         "main receives exact caller identity in its own event sequence domain");
  expect(!fixture.preview->takeEvent(),
         "main draw never enters typed preview lane");
  const NativeTrackedVideoOutputFacts facts = fixture.main->facts();
  expect(facts.submittedFrames == 1 && facts.drawnFrames == 1 &&
             facts.supersededFrames == 0 && facts.lastEventSequence == 1,
         "main facts count only main-owned work");
}

void ownersShareOneNonwrappingSequenceDomain() {
  Fixture fixture;
  FrameLease previewFrame = makeFrame(7, 10);
  const auto previewSubmit = fixture.preview->submit(7, previewFrame);
  fixture.output->draw();
  expect(fixture.preview->takeEvent().has_value(),
         "first preview credit terminates");

  FrameLease mainFrame = makeFrame(7, 20);
  expect(fixture.main->submit(mainFrame, NativeTrackedFrameSequence{900},
                              nullptr) ==
             NativeTrackedVideoSubmitStatus::Accepted,
         "main admission follows preview admission");
  fixture.output->draw();
  expect(fixture.main->takeEvent().has_value(),
         "main credit terminates");

  FrameLease secondPreviewFrame = makeFrame(7, 30);
  const auto secondPreview = fixture.preview->submit(7, secondPreviewFrame);
  expect(previewSubmit.sequence.value == 1 &&
             secondPreview.sequence.value == 2 &&
             fixture.output->acceptedSequences() ==
                 std::vector<std::uint64_t>({1, 2, 3}),
         "public preview and shared output identities advance independently");
}

void mainLifecycleCancelsPreviewFirst() {
  Fixture fixture;
  FrameLease frame = makeFrame(7, 360);
  const auto submitted = fixture.preview->submit(7, frame);
  expect(fixture.preview->cancel() ==
             NativeTrackedVideoPreviewCancelProgress::Quiescing,
         "preview cancel never fabricates a terminal fact");
  expect(fixture.main->flushProgress(7, 8) ==
             NativeTrackedVideoOutputProgress::Quiescing,
         "main flush first supersedes accepted preview frame");
  expect(!fixture.main->takeEvent(),
         "preview supersession is not observable as a main frame event");
  expect(fixture.main->flushProgress(7, 8) ==
             NativeTrackedVideoOutputProgress::Done,
         "main lifecycle does not wait for preview client to poll routed fact");
  const auto event = fixture.preview->takeEvent();
  expect(event &&
             event->kind ==
                 NativeTrackedVideoPreviewEventKind::FrameSuperseded &&
             event->frameSequence == submitted.sequence &&
             event->generation == 7,
         "cancelled preview receives the real supersession fact exactly once");
  expect(fixture.preview->cancel() ==
             NativeTrackedVideoPreviewCancelProgress::Done &&
             fixture.preview->capacity(8) ==
                 NativeTrackedVideoCapacity::Available,
         "completed flush reopens preview only on the new active generation");
  expect(fixture.preview->capacity(7) ==
             NativeTrackedVideoCapacity::StaleGeneration,
         "retired preview generation stays stale");
}

void lifecycleEventsAreMainOnly() {
  Fixture fixture;
  fixture.output->publishInvalidated(7);
  expect(!fixture.preview->takeEvent(),
         "typed preview port cannot observe lifecycle diagnostics");
  const auto event = fixture.main->takeEvent();
  expect(event &&
             event->kind ==
                 NativeTrackedVideoEventKind::GenerationInvalidated &&
             !event->frameSequence.valid() && event->generation == 7 &&
             event->eventSequence == 1,
         "lifecycle diagnostic routes only to main event domain");
}

void portsOwnTheWrappedLifetime() {
  auto output = std::make_shared<FakeTrackedOutput>(7);
  std::weak_ptr<FakeTrackedOutput> weakOutput = output;
  auto arbiter = NativeTrackedVideoArbiter::create(output);
  auto main = arbiter->mainOutput();
  auto preview = arbiter->previewPort();
  output.reset();
  arbiter.reset();
  expect(!weakOutput.expired(),
         "facade handles retain arbiter state and wrapped output");
  expect(main->closeProgress(8) == NativeTrackedVideoOutputProgress::Done,
         "surviving main facade retains exclusive close authority");
  main.reset();
  expect(!weakOutput.expired(),
         "preview handle safely retains closed shared state");
  preview.reset();
  expect(weakOutput.expired(),
         "wrapped output dies after the last typed handle");
}

}  // namespace

int main() {
  creationRequiresFreshOutput();
  previewEventNeverAppearsAsMain();
  mainEventNeverAppearsAsPreview();
  ownersShareOneNonwrappingSequenceDomain();
  mainLifecycleCancelsPreviewFirst();
  lifecycleEventsAreMainOnly();
  portsOwnTheWrappedLifetime();
  if (failures != 0) {
    return EXIT_FAILURE;
  }
  std::cout << "native tracked video arbiter tests passed\n";
  return EXIT_SUCCESS;
}
