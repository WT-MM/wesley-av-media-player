#include "native_tracked_video_arbiter.hpp"

#include <limits>
#include <new>
#include <utility>

namespace wam::macos {
namespace {

enum class AdmissionOwner : std::uint8_t {
  None,
  Main,
  Preview,
};

void clearError(std::string* error) noexcept {
  if (error == nullptr) {
    return;
  }
  try {
    error->clear();
  } catch (...) {
  }
}

void assignError(std::string* error, const char* message) noexcept {
  if (error == nullptr) {
    return;
  }
  try {
    error->assign(message);
  } catch (...) {
  }
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

[[nodiscard]] NativeTrackedVideoPreviewEventKind previewKind(
    NativeTrackedVideoEventKind kind) noexcept {
  switch (kind) {
  case NativeTrackedVideoEventKind::FrameDrawn:
    return NativeTrackedVideoPreviewEventKind::FrameDrawn;
  case NativeTrackedVideoEventKind::FrameSuperseded:
    return NativeTrackedVideoPreviewEventKind::FrameSuperseded;
  case NativeTrackedVideoEventKind::Failed:
  case NativeTrackedVideoEventKind::GenerationInvalidated:
  case NativeTrackedVideoEventKind::Closed:
    return NativeTrackedVideoPreviewEventKind::Failed;
  }
  return NativeTrackedVideoPreviewEventKind::Failed;
}

}  // namespace

struct NativeTrackedVideoArbiter::State final {
  struct Admission {
    AdmissionOwner owner{AdmissionOwner::None};
    NativeTrackedFrameSequence internalSequence{};
    NativeTrackedFrameSequence mainSequence{};
    NativeTrackedVideoPreviewSequence previewSequence{};
    std::uint64_t generation{0};
    FrameTiming timing{};

    [[nodiscard]] bool active() const noexcept {
      return owner != AdmissionOwner::None;
    }
  };

  explicit State(std::shared_ptr<NativeTrackedVideoOutput> wrapped) noexcept
      : output(std::move(wrapped)) {}

  [[nodiscard]] bool allocateInternal(
      NativeTrackedFrameSequence* sequence) noexcept {
    if (internalSequenceExhausted) {
      return false;
    }
    *sequence = NativeTrackedFrameSequence{nextInternalSequence};
    return true;
  }

  void commitInternal() noexcept {
    if (nextInternalSequence ==
        std::numeric_limits<std::uint64_t>::max()) {
      internalSequenceExhausted = true;
      return;
    }
    ++nextInternalSequence;
  }

  [[nodiscard]] bool allocatePreview(
      NativeTrackedVideoPreviewSequence* sequence) noexcept {
    if (previewSequenceExhausted) {
      return false;
    }
    *sequence = NativeTrackedVideoPreviewSequence{nextPreviewSequence};
    return true;
  }

  void commitPreview() noexcept {
    if (nextPreviewSequence ==
        std::numeric_limits<std::uint64_t>::max()) {
      previewSequenceExhausted = true;
      return;
    }
    ++nextPreviewSequence;
  }

  [[nodiscard]] bool allocateEvent(AdmissionOwner owner,
                                   std::uint64_t* sequence) noexcept {
    std::uint64_t* highWater = owner == AdmissionOwner::Preview
                                   ? &previewEventSequence
                                   : &mainEventSequence;
    if (*highWater == std::numeric_limits<std::uint64_t>::max()) {
      fatal = true;
      return false;
    }
    *sequence = ++*highWater;
    return true;
  }

  [[nodiscard]] bool validFrameEvent(
      const NativeTrackedVideoEvent& event) const noexcept {
    return admission.active() && event.frameSequence.valid() &&
           event.frameSequence == admission.internalSequence &&
           event.generation == admission.generation &&
           sameTiming(event.timing, admission.timing) &&
           (event.kind == NativeTrackedVideoEventKind::FrameDrawn ||
            event.kind == NativeTrackedVideoEventKind::FrameSuperseded ||
            event.kind == NativeTrackedVideoEventKind::Failed);
  }

  // Moves at most one raw event into exactly one typed owner mailbox. Calls
  // are owner-thread-only, matching NativeTrackedVideoOutput's consumer.
  void pumpEvent() noexcept {
    if (fatal || mainEvent || previewEvent) {
      return;
    }
    const std::optional<NativeTrackedVideoEvent> event = output->takeEvent();
    if (!event) {
      return;
    }
    if (event->eventSequence == 0 ||
        event->eventSequence <= lastUnderlyingEventSequence) {
      fatal = true;
      return;
    }
    lastUnderlyingEventSequence = event->eventSequence;

    if (event->frameSequence.valid()) {
      if (!validFrameEvent(*event)) {
        fatal = true;
        return;
      }
      std::uint64_t publicEventSequence = 0;
      if (!allocateEvent(admission.owner, &publicEventSequence)) {
        return;
      }
      if (admission.owner == AdmissionOwner::Main) {
        mainEvent.emplace(NativeTrackedVideoEvent{
            event->kind, publicEventSequence, admission.mainSequence,
            event->generation, event->timing});
        if (event->kind == NativeTrackedVideoEventKind::FrameDrawn) {
          ++mainDrawnFrames;
        } else if (event->kind ==
                   NativeTrackedVideoEventKind::FrameSuperseded) {
          ++mainSupersededFrames;
        }
        return;
      }
      if (admission.owner == AdmissionOwner::Preview) {
        previewEvent.emplace(NativeTrackedVideoPreviewEvent{
            previewKind(event->kind), publicEventSequence,
            admission.previewSequence, event->generation, event->timing});
        // The arbiter has consumed the real output terminal fact and the
        // underlying lease is released. Keep the typed preview event pending
        // (and therefore keep global admission backpressured), but do not make
        // main lifecycle progress depend on the preview client polling it.
        admission = {};
        previewCancelPending = false;
        return;
      }
      fatal = true;
      return;
    }

    if (event->kind == NativeTrackedVideoEventKind::FrameDrawn ||
        event->kind == NativeTrackedVideoEventKind::FrameSuperseded ||
        event->kind == NativeTrackedVideoEventKind::Failed ||
        admission.active()) {
      fatal = true;
      return;
    }
    std::uint64_t publicEventSequence = 0;
    if (!allocateEvent(AdmissionOwner::Main, &publicEventSequence)) {
      return;
    }
    mainEvent.emplace(NativeTrackedVideoEvent{
        event->kind, publicEventSequence, {}, event->generation,
        event->timing});
  }

  [[nodiscard]] NativeTrackedVideoCapacity capacity(
      std::uint64_t generation) noexcept {
    pumpEvent();
    const NativeTrackedVideoCapacity wrapped = output->capacity(generation);
    if (fatal || wrapped == NativeTrackedVideoCapacity::Failed) {
      return NativeTrackedVideoCapacity::Failed;
    }
    if (wrapped != NativeTrackedVideoCapacity::Available) {
      return wrapped;
    }
    return admission.active() || mainEvent || previewEvent
               ? NativeTrackedVideoCapacity::Backpressure
               : NativeTrackedVideoCapacity::Available;
  }

  void consumeAdmission(AdmissionOwner owner) noexcept {
    if (admission.owner != owner) {
      fatal = true;
      return;
    }
    admission = {};
    if (owner == AdmissionOwner::Preview) {
      previewCancelPending = false;
    }
  }

  [[nodiscard]] bool frameTerminalPending() const noexcept {
    return admission.active() && (mainEvent || previewEvent);
  }

  void requestPreviewCancel() noexcept {
    if (admission.owner == AdmissionOwner::Preview) {
      previewCancelPending = true;
    }
  }

  std::shared_ptr<NativeTrackedVideoOutput> output;
  Admission admission{};
  std::optional<NativeTrackedVideoEvent> mainEvent;
  std::optional<NativeTrackedVideoPreviewEvent> previewEvent;
  NativeTrackedFrameSequence lastMainSequence{};
  std::uint64_t nextInternalSequence{1};
  std::uint64_t nextPreviewSequence{1};
  std::uint64_t mainEventSequence{0};
  std::uint64_t previewEventSequence{0};
  std::uint64_t lastUnderlyingEventSequence{0};
  std::uint64_t mainSubmittedFrames{0};
  std::uint64_t mainDrawnFrames{0};
  std::uint64_t mainSupersededFrames{0};
  bool internalSequenceExhausted{false};
  bool previewSequenceExhausted{false};
  bool previewCancelPending{false};
  bool fatal{false};
};

class NativeTrackedVideoArbiter::MainOutput final
    : public NativeTrackedVideoOutput {
 public:
  explicit MainOutput(std::shared_ptr<State> state) noexcept
      : state_(std::move(state)) {}

  [[nodiscard]] NativeTrackedVideoCapacity capacity(
      std::uint64_t generation) const noexcept override {
    return state_->capacity(generation);
  }

  [[nodiscard]] NativeTrackedVideoSubmitStatus submit(
      const FrameLease& frame, NativeTrackedFrameSequence sequence,
      std::string* error) noexcept override {
    clearError(error);
    if (!sequence.valid() ||
        (state_->lastMainSequence.valid() &&
         sequence.value <= state_->lastMainSequence.value)) {
      state_->fatal = true;
      assignError(error, "main tracked frame sequence repeated or regressed");
      return NativeTrackedVideoSubmitStatus::Failed;
    }
    const std::uint64_t generation = frame.timing().generation;
    switch (state_->capacity(generation)) {
    case NativeTrackedVideoCapacity::Backpressure:
      return NativeTrackedVideoSubmitStatus::Backpressure;
    case NativeTrackedVideoCapacity::StaleGeneration:
      return NativeTrackedVideoSubmitStatus::StaleGeneration;
    case NativeTrackedVideoCapacity::Failed:
      assignError(error, "tracked video arbiter failed");
      return NativeTrackedVideoSubmitStatus::Failed;
    case NativeTrackedVideoCapacity::Available:
      break;
    }
    NativeTrackedFrameSequence internal{};
    if (!state_->allocateInternal(&internal)) {
      state_->fatal = true;
      assignError(error, "tracked video arbiter sequence is exhausted");
      return NativeTrackedVideoSubmitStatus::Failed;
    }
    const NativeTrackedVideoSubmitStatus status =
        state_->output->submit(frame, internal, error);
    if (status != NativeTrackedVideoSubmitStatus::Accepted) {
      if (status == NativeTrackedVideoSubmitStatus::Failed) {
        state_->fatal = true;
      }
      return status;
    }
    state_->commitInternal();
    state_->lastMainSequence = sequence;
    state_->admission = State::Admission{AdmissionOwner::Main, internal,
                                         sequence, {}, generation,
                                         frame.timing()};
    ++state_->mainSubmittedFrames;
    return NativeTrackedVideoSubmitStatus::Accepted;
  }

  [[nodiscard]] std::optional<NativeTrackedVideoEvent>
  takeEvent() noexcept override {
    state_->pumpEvent();
    if (!state_->mainEvent) {
      return std::nullopt;
    }
    std::optional<NativeTrackedVideoEvent> result =
        std::move(state_->mainEvent);
    state_->mainEvent.reset();
    if (result->frameSequence.valid()) {
      state_->consumeAdmission(AdmissionOwner::Main);
    }
    return result;
  }

  [[nodiscard]] NativeTrackedVideoOutputProgress flushProgress(
      std::uint64_t retiredGeneration,
      std::uint64_t nextGeneration) noexcept override {
    state_->pumpEvent();
    state_->requestPreviewCancel();
    if (state_->frameTerminalPending()) {
      return NativeTrackedVideoOutputProgress::Quiescing;
    }
    const NativeTrackedVideoOutputProgress progress =
        state_->output->flushProgress(retiredGeneration, nextGeneration);
    state_->pumpEvent();
    if (state_->fatal) {
      return NativeTrackedVideoOutputProgress::Failed;
    }
    return state_->admission.active()
               ? NativeTrackedVideoOutputProgress::Quiescing
               : progress;
  }

  [[nodiscard]] NativeTrackedVideoOutputProgress closeProgress(
      std::uint64_t finalGeneration) noexcept override {
    state_->pumpEvent();
    state_->requestPreviewCancel();
    if (state_->frameTerminalPending()) {
      return NativeTrackedVideoOutputProgress::Quiescing;
    }
    const NativeTrackedVideoOutputProgress progress =
        state_->output->closeProgress(finalGeneration);
    state_->pumpEvent();
    if (state_->fatal) {
      return NativeTrackedVideoOutputProgress::Failed;
    }
    return state_->admission.active()
               ? NativeTrackedVideoOutputProgress::Quiescing
               : progress;
  }

  [[nodiscard]] NativeTrackedVideoOutputFacts facts()
      const noexcept override {
    state_->pumpEvent();
    NativeTrackedVideoOutputFacts result = state_->output->facts();
    result.admittedFrame =
        state_->admission.owner == AdmissionOwner::Main
            ? state_->admission.mainSequence
            : NativeTrackedFrameSequence{};
    result.submittedFrames = state_->mainSubmittedFrames;
    result.drawnFrames = state_->mainDrawnFrames;
    result.supersededFrames = state_->mainSupersededFrames;
    result.lastEventSequence = state_->mainEventSequence;
    // Preserve the shared capacity-one credit without exposing a preview
    // identity through the main facade.
    result.retainedFrames = state_->admission.active() ? 1U : 0U;
    result.eventPending = state_->mainEvent.has_value();
    result.fatal = result.fatal || state_->fatal;
    return result;
  }

 private:
  std::shared_ptr<State> state_;
};

class NativeTrackedVideoArbiter::PreviewPort final
    : public NativeTrackedVideoPreviewPort {
 public:
  explicit PreviewPort(std::shared_ptr<State> state) noexcept
      : state_(std::move(state)) {}

  [[nodiscard]] NativeTrackedVideoCapacity capacity(
      std::uint64_t generation) const noexcept override {
    if (state_->previewCancelPending) {
      return NativeTrackedVideoCapacity::Backpressure;
    }
    return state_->capacity(generation);
  }

  [[nodiscard]] NativeTrackedVideoPreviewSubmitResult submit(
      std::uint64_t generation, const FrameLease& frame,
      std::string* error) noexcept override {
    clearError(error);
    if (generation == 0 || frame.timing().generation != generation) {
      return {NativeTrackedVideoSubmitStatus::StaleGeneration, {}};
    }
    switch (capacity(generation)) {
    case NativeTrackedVideoCapacity::Backpressure:
      return {NativeTrackedVideoSubmitStatus::Backpressure, {}};
    case NativeTrackedVideoCapacity::StaleGeneration:
      return {NativeTrackedVideoSubmitStatus::StaleGeneration, {}};
    case NativeTrackedVideoCapacity::Failed:
      assignError(error, "tracked video arbiter failed");
      return {NativeTrackedVideoSubmitStatus::Failed, {}};
    case NativeTrackedVideoCapacity::Available:
      break;
    }
    NativeTrackedFrameSequence internal{};
    NativeTrackedVideoPreviewSequence preview{};
    if (!state_->allocateInternal(&internal) ||
        !state_->allocatePreview(&preview)) {
      state_->fatal = true;
      assignError(error, "tracked video arbiter sequence is exhausted");
      return {NativeTrackedVideoSubmitStatus::Failed, {}};
    }
    const NativeTrackedVideoSubmitStatus status =
        state_->output->submit(frame, internal, error);
    if (status != NativeTrackedVideoSubmitStatus::Accepted) {
      if (status == NativeTrackedVideoSubmitStatus::Failed) {
        state_->fatal = true;
      }
      return {status, {}};
    }
    state_->commitInternal();
    state_->commitPreview();
    state_->admission = State::Admission{AdmissionOwner::Preview, internal,
                                         {}, preview, generation,
                                         frame.timing()};
    return {NativeTrackedVideoSubmitStatus::Accepted, preview};
  }

  [[nodiscard]] std::optional<NativeTrackedVideoPreviewEvent>
  takeEvent() noexcept override {
    state_->pumpEvent();
    if (!state_->previewEvent) {
      return std::nullopt;
    }
    std::optional<NativeTrackedVideoPreviewEvent> result =
        std::move(state_->previewEvent);
    state_->previewEvent.reset();
    return result;
  }

  [[nodiscard]] NativeTrackedVideoPreviewCancelProgress
  cancel() noexcept override {
    state_->pumpEvent();
    state_->requestPreviewCancel();
    if (state_->fatal) {
      return NativeTrackedVideoPreviewCancelProgress::Failed;
    }
    return state_->admission.owner == AdmissionOwner::Preview
               ? NativeTrackedVideoPreviewCancelProgress::Quiescing
               : NativeTrackedVideoPreviewCancelProgress::Done;
  }

 private:
  std::shared_ptr<State> state_;
};

std::shared_ptr<NativeTrackedVideoArbiter>
NativeTrackedVideoArbiter::create(
    std::shared_ptr<NativeTrackedVideoOutput> output,
    std::string* error) noexcept {
  clearError(error);
  if (output == nullptr) {
    assignError(error, "tracked video arbiter requires an output");
    return {};
  }
  const NativeTrackedVideoOutputFacts facts = output->facts();
  if (facts.fatal || facts.closed || facts.admittedFrame.valid() ||
      facts.submittedFrames != 0 || facts.drawnFrames != 0 ||
      facts.supersededFrames != 0 || facts.lastEventSequence != 0 ||
      facts.retainedFrames != 0 || facts.eventPending ||
      facts.invalidationPending) {
    assignError(error,
                "tracked video arbiter requires a fresh quiescent output");
    return {};
  }
  try {
    auto state = std::make_shared<State>(std::move(output));
    auto result = std::shared_ptr<NativeTrackedVideoArbiter>(
        new NativeTrackedVideoArbiter(state));
    result->mainOutput_ = std::make_shared<MainOutput>(state);
    result->previewPort_ = std::make_shared<PreviewPort>(std::move(state));
    return result;
  } catch (...) {
    assignError(error, "tracked video arbiter allocation failed");
    return {};
  }
}

NativeTrackedVideoArbiter::NativeTrackedVideoArbiter(
    std::shared_ptr<State> state)
    : state_(std::move(state)) {}

NativeTrackedVideoArbiter::~NativeTrackedVideoArbiter() = default;

std::shared_ptr<NativeTrackedVideoOutput>
NativeTrackedVideoArbiter::mainOutput() const noexcept {
  return mainOutput_;
}

std::shared_ptr<NativeTrackedVideoPreviewPort>
NativeTrackedVideoArbiter::previewPort() const noexcept {
  return previewPort_;
}

}  // namespace wam::macos
