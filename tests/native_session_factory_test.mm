#include "platform/macos/native_media_session_system.hpp"

#include <cstdlib>
#include <iostream>

using namespace wam::macos;
namespace {
void expect(bool value, const char* reason) {
  if (!value) { std::cerr << reason << '\n'; std::exit(1); }
}
class Output final : public NativeTrackedVideoOutput {
 public:
  explicit Output(std::weak_ptr<void> lifetime) : lifetime_(std::move(lifetime)) {}
  ~Output() override {
    expect(!lifetime_.expired(), "presentation outlives output destruction");
  }
  NativeTrackedVideoCapacity capacity(std::uint64_t) const noexcept override {
    return NativeTrackedVideoCapacity::Available;
  }
  NativeTrackedVideoSubmitStatus submit(const FrameLease&,
      NativeTrackedFrameSequence, std::string*) noexcept override {
    return NativeTrackedVideoSubmitStatus::Failed;
  }
  std::optional<NativeTrackedVideoEvent> takeEvent() noexcept override { return {}; }
  NativeTrackedVideoOutputProgress flushProgress(std::uint64_t,
      std::uint64_t) noexcept override { return NativeTrackedVideoOutputProgress::Done; }
  NativeTrackedVideoOutputProgress closeProgress(std::uint64_t) noexcept override {
    return NativeTrackedVideoOutputProgress::Done;
  }
  NativeTrackedVideoOutputFacts facts() const noexcept override { return {}; }
 private:
  std::weak_ptr<void> lifetime_;
};
struct Context {
  unsigned calls{0};
  std::shared_ptr<void> lifetime = std::make_shared<int>(1);
};
NativeMediaSessionPresentation present(void* opaque,
    NativeTrackedVideoOutputWakeSeam wake, std::string*) noexcept {
  auto& context = *static_cast<Context*>(opaque);
  ++context.calls;
  expect(wake.signal && wake.context, "factory receives the session wake");
  return {std::make_shared<Output>(context.lifetime), context.lifetime};
}
NativeMediaSessionPresentation refuse(void*, NativeTrackedVideoOutputWakeSeam,
    std::string* error) noexcept {
  *error = "PresentationRequiresMacOS14";
  return {};
}
NativeMediaSessionPresentation unavailable(void*, NativeTrackedVideoOutputWakeSeam,
    std::string*) noexcept { return {}; }
}
int main() {
  Context context;
  std::string error;
  auto caller = std::make_shared<int>(2);
  auto session = createNativeMediaSessionSystem({{1}, "/nonexistent.mkv"}, caller,
      {&context, &present}, &error);
  expect(session && error.empty() && context.calls == 1,
      "toolkit-independent construction performs no media I/O");
  std::weak_ptr<void> lifetime = context.lifetime;
  context.lifetime.reset();
  expect(!lifetime.expired(), "session retains presentation dependencies");
  session.reset();
  expect(lifetime.expired(), "session destruction releases presentation dependencies");
  session = createNativeMediaSessionSystem({{1}, "/nonexistent.mkv"}, caller,
      {nullptr, &refuse}, &error);
  expect(!session && error == "PresentationRequiresMacOS14",
      "presentation refusal preserves its name without a toolkit fallback");
  session = createNativeMediaSessionSystem({{1}, "/nonexistent.mkv"}, caller,
      {nullptr, &unavailable}, &error);
  expect(!session && error == "PresentationUnavailable", "missing presentation is named");
  session = createNativeMediaSessionSystem({{1}, "relative.mkv"}, caller,
      {&context, &present}, &error);
  expect(!session && context.calls == 1, "invalid source never constructs presentation");
}
