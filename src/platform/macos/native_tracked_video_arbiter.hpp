#pragma once

#include "native_tracked_video_output.hpp"

#include <cstdint>
#include <memory>
#include <optional>
#include <string>

namespace wam::macos {

// Preview identities live in a separate type and sequence domain so a preview
// terminal fact cannot accidentally satisfy NativeVideoConsumer's main-video
// credit.
struct NativeTrackedVideoPreviewSequence {
  std::uint64_t value{0};

  [[nodiscard]] constexpr bool valid() const noexcept { return value != 0; }
  friend constexpr bool operator==(NativeTrackedVideoPreviewSequence,
                                   NativeTrackedVideoPreviewSequence) =
      default;
};

enum class NativeTrackedVideoPreviewEventKind : std::uint8_t {
  FrameDrawn,
  FrameSuperseded,
  Failed,
};

struct NativeTrackedVideoPreviewEvent {
  NativeTrackedVideoPreviewEventKind kind{
      NativeTrackedVideoPreviewEventKind::Failed};
  std::uint64_t eventSequence{0};
  NativeTrackedVideoPreviewSequence frameSequence{};
  std::uint64_t generation{0};
  FrameTiming timing{};
};

struct NativeTrackedVideoPreviewSubmitResult {
  NativeTrackedVideoSubmitStatus status{
      NativeTrackedVideoSubmitStatus::Failed};
  // Nonzero only when status is Accepted. The arbiter, not the caller,
  // allocates this nonwrapping preview identity.
  NativeTrackedVideoPreviewSequence sequence{};
};

enum class NativeTrackedVideoPreviewCancelProgress : std::uint8_t {
  Done,
  Quiescing,
  Failed,
};

// Owner-thread preview lane over a capacity-one tracked video output. It has
// no generation lifecycle authority: only the main NativeTrackedVideoOutput
// facade may flush or close the shared presenter.
//
// cancel() revokes the current preview admission. The underlying output has
// no per-frame cancellation primitive, so an already accepted frame remains
// Quiescing until its real terminal event, or until the main facade's
// flush/close supersedes it. No terminal event is fabricated.
class NativeTrackedVideoPreviewPort {
 public:
  virtual ~NativeTrackedVideoPreviewPort() = default;

  [[nodiscard]] virtual NativeTrackedVideoCapacity capacity(
      std::uint64_t generation) const noexcept = 0;
  [[nodiscard]] virtual NativeTrackedVideoPreviewSubmitResult submit(
      std::uint64_t generation, const FrameLease& frame,
      std::string* error = nullptr) noexcept = 0;
  [[nodiscard]] virtual std::optional<NativeTrackedVideoPreviewEvent>
  takeEvent() noexcept = 0;
  [[nodiscard]] virtual NativeTrackedVideoPreviewCancelProgress
  cancel() noexcept = 0;
};

// Splits one fresh NativeTrackedVideoOutput into two owner-thread views. The
// main view preserves the stable NativeTrackedVideoOutput API. The preview
// view is deliberately typed and cannot flush or close.
//
// Every accepted delivery receives one arbiter-owned sequence for the shared
// output. The matching owner and public identity are retained until the exact
// terminal event is routed. Main and preview event sequences are independent;
// neither lane observes the other lane's frame event or identity.
//
// The wrapped output must be fresh and quiescent (no prior frame submission,
// retained frame, event, or lifecycle operation). NativeTrackedVideoOutput
// does not expose its historical frame-sequence high-water, so wrapping an
// already-used instance could not assign a provably increasing next identity.
class NativeTrackedVideoArbiter final {
 public:
  [[nodiscard]] static std::shared_ptr<NativeTrackedVideoArbiter> create(
      std::shared_ptr<NativeTrackedVideoOutput> output,
      std::string* error = nullptr) noexcept;

  NativeTrackedVideoArbiter(const NativeTrackedVideoArbiter&) = delete;
  NativeTrackedVideoArbiter& operator=(const NativeTrackedVideoArbiter&) =
      delete;
  ~NativeTrackedVideoArbiter();

  [[nodiscard]] std::shared_ptr<NativeTrackedVideoOutput>
  mainOutput() const noexcept;
  [[nodiscard]] std::shared_ptr<NativeTrackedVideoPreviewPort>
  previewPort() const noexcept;

 private:
  struct State;
  class MainOutput;
  class PreviewPort;

  explicit NativeTrackedVideoArbiter(std::shared_ptr<State> state);

  std::shared_ptr<State> state_;
  std::shared_ptr<NativeTrackedVideoOutput> mainOutput_;
  std::shared_ptr<NativeTrackedVideoPreviewPort> previewPort_;
};

}  // namespace wam::macos
