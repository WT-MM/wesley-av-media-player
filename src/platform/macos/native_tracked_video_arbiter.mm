#include "native_tracked_video_arbiter.hpp"
#include "platform/macos/native_primitives.hpp"

#include <limits>
#include <new>
#include <utility>
#include <variant>

namespace wam::macos {
namespace {

void clearError(std::string* error) noexcept {
  if (error == nullptr) {
    return;
  }
  try {
    error->clear();
  } catch (...) {
  }
}

[[nodiscard]] NativeTrackedVideoPreviewEventKind previewKind(
    NativeTrackedVideoEventKind kind) noexcept {
  switch (kind) {
  case NativeTrackedVideoEventKind::FrameDrawn:
    return NativeTrackedVideoPreviewEventKind::FrameDrawn;
  case NativeTrackedVideoEventKind::FrameSuperseded:
    return NativeTrackedVideoPreviewEventKind::FrameSuperseded;
  case NativeTrackedVideoEventKind::Failed:
    return NativeTrackedVideoPreviewEventKind::Failed;
  }
  return NativeTrackedVideoPreviewEventKind::Failed;
}

}  // namespace

struct NativeTrackedVideoArbiter::State final {
  // The one frame the wrapped capacity-one output holds, under the identity
  // the arbiter gave it.
  struct AdmittedFrame {
    NativeTrackedFrameSequence internalSequence;
    std::uint64_t generation;
    FrameTiming timing;
  };
  struct Empty {};
  struct MainAdmitted {
    AdmittedFrame frame;
    NativeTrackedFrameSequence sequence;
  };
  struct PreviewAdmitted {
    AdmittedFrame frame;
    NativeTrackedVideoPreviewSequence sequence;
    // A main lifecycle operation or the preview client asked to cancel;
    // further preview submits back off until this frame's terminal event.
    bool cancelRequested{false};
  };
  using Admission = std::variant<Empty, MainAdmitted, PreviewAdmitted>;

  [[nodiscard]] bool admitted() const noexcept {
    return !std::holds_alternative<Empty>(admission);
  }
  [[nodiscard]] const AdmittedFrame* admittedFrame() const noexcept {
    if (const auto* main = std::get_if<MainAdmitted>(&admission)) {
      return &main->frame;
    }
    if (const auto* preview = std::get_if<PreviewAdmitted>(&admission)) {
      return &preview->frame;
    }
    return nullptr;
  }
  [[nodiscard]] bool previewCancelRequested() const noexcept {
    const auto* preview = std::get_if<PreviewAdmitted>(&admission);
    return preview != nullptr && preview->cancelRequested;
  }

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

  [[nodiscard]] bool allocateEvent(bool preview,
                                   std::uint64_t* sequence) noexcept {
    std::uint64_t* highWater =
        preview ? &previewEventSequence : &mainEventSequence;
    if (*highWater == std::numeric_limits<std::uint64_t>::max()) {
      fatal = true;
      return false;
    }
    *sequence = ++*highWater;
    return true;
  }

  [[nodiscard]] bool validFrameEvent(
      const NativeTrackedVideoEvent& event) const noexcept {
    const AdmittedFrame* frame = admittedFrame();
    return frame != nullptr && event.frameSequence.valid() &&
           event.frameSequence == frame->internalSequence &&
           event.generation == frame->generation &&
           sameFrameTiming(event.timing, frame->timing);
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

    if (!validFrameEvent(*event)) {
      fatal = true;
      return;
    }
    std::uint64_t publicEventSequence = 0;
    const auto* preview = std::get_if<PreviewAdmitted>(&admission);
    if (!allocateEvent(preview != nullptr, &publicEventSequence)) {
      return;
    }
    if (const auto* main = std::get_if<MainAdmitted>(&admission)) {
      mainEvent.emplace(NativeTrackedVideoEvent{
          event->kind, publicEventSequence, main->sequence,
          event->generation, event->timing});
      if (event->kind == NativeTrackedVideoEventKind::FrameDrawn) {
        ++mainDrawnFrames;
      } else if (event->kind ==
                 NativeTrackedVideoEventKind::FrameSuperseded) {
        ++mainSupersededFrames;
      }
      return;
    }
    previewEvent.emplace(NativeTrackedVideoPreviewEvent{
        previewKind(event->kind), publicEventSequence, preview->sequence,
        event->generation, event->timing});
    // The arbiter has consumed the real output terminal fact and the
    // underlying lease is released. Keep the typed preview event pending
    // (and therefore keep global admission backpressured), but do not make
    // main lifecycle progress depend on the preview client polling it.
    admission = Empty{};
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
    return admitted() || mainEvent || previewEvent
               ? NativeTrackedVideoCapacity::Backpressure
               : NativeTrackedVideoCapacity::Available;
  }

  // The main client took the terminal event of its admitted frame.
  void consumeMainAdmission() noexcept {
    if (!std::holds_alternative<MainAdmitted>(admission)) {
      fatal = true;
      return;
    }
    admission = Empty{};
  }

  [[nodiscard]] bool frameTerminalPending() const noexcept {
    return admitted() && (mainEvent || previewEvent);
  }

  void requestPreviewCancel() noexcept {
    if (auto* preview = std::get_if<PreviewAdmitted>(&admission)) {
      preview->cancelRequested = true;
    }
  }

  std::shared_ptr<NativeTrackedVideoOutput> output;
  Admission admission;
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
    state_->admission = State::MainAdmitted{
        {internal, generation, frame.timing()}, sequence};
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
      state_->consumeMainAdmission();
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
    return state_->admitted() ? NativeTrackedVideoOutputProgress::Quiescing
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
    return state_->admitted() ? NativeTrackedVideoOutputProgress::Quiescing
                              : progress;
  }

  // Capability facts are forwarded: the arbiter neither samples, converts nor
  // draws the surface, so only the wrapped presenter can answer them.
  [[nodiscard]] NativePresentationCapabilities presentationCapabilities()
      const noexcept override {
    return state_->output->presentationCapabilities();
  }

  [[nodiscard]] bool applyPresentationGeometry(
      media::MediaDisplaySize displaySize,
      int quarterTurnDegrees) noexcept override {
    return state_->output->applyPresentationGeometry(displaySize,
                                                     quarterTurnDegrees);
  }

#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) && WAM_NATIVE_BENCHMARK_TELEMETRY
  [[nodiscard]] late_display_trace::Snapshot diagnosticDisplayPhase() const noexcept override {
    return state_->output->diagnosticDisplayPhase();
  }
#endif

  [[nodiscard]] NativeTrackedVideoOutputFacts facts()
      const noexcept override {
    state_->pumpEvent();
    NativeTrackedVideoOutputFacts result = state_->output->facts();
    const auto* main = std::get_if<State::MainAdmitted>(&state_->admission);
    result.admittedFrame =
        main != nullptr ? main->sequence : NativeTrackedFrameSequence{};
    result.submittedFrames = state_->mainSubmittedFrames;
    result.drawnFrames = state_->mainDrawnFrames;
    result.supersededFrames = state_->mainSupersededFrames;
    result.lastEventSequence = state_->mainEventSequence;
    // Preserve the shared capacity-one credit without exposing a preview
    // identity through the main facade.
    result.retainedFrames = state_->admitted() ? 1U : 0U;
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
    if (state_->previewCancelRequested()) {
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
    state_->admission = State::PreviewAdmitted{
        {internal, generation, frame.timing()}, preview};
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
    return std::holds_alternative<State::PreviewAdmitted>(state_->admission)
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
