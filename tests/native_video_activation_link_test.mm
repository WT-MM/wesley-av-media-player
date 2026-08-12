#include "platform/macos/native_video_action_driver.hpp"
#include "platform/macos/native_video_session.hpp"
#include "qt/native_video_controller.hpp"

#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <memory>
#include <string>

namespace {

bool check(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "activation link gate failed: " << message << '\n';
  }
  return condition;
}

}  // namespace

int main() {
  using wam::macos::MacosNativeVideoActionDriver;
  using wam::macos::NativeVideoSession;
  using wam::native_activation::NativeVideoController;
  using wam::native_activation::Transport;

  bool passed = true;
  NativeVideoController disabled(nullptr, false);
  passed &= check(!disabled.begin(1, 1, Transport{}).has_value(),
                  "disabled runner admitted an attempt");
  passed &= check(!disabled.pump() && !disabled.poll() && !disabled.tick(1),
                  "disabled runner performed work");

  std::string error;
  auto driver = MacosNativeVideoActionDriver::create(
      std::filesystem::path("unused.mp4"), nullptr, nullptr, nullptr, &error);
  passed &= check(driver == nullptr && !error.empty(),
                  "adapter accepted missing dependency ports");

  error.clear();
  auto session = NativeVideoSession::create(
      nullptr, {}, std::filesystem::path("unused.mp4"), &error);
  passed &= check(session == nullptr && !error.empty(),
                  "session accepted an invalid token/item boundary");

  if (!passed) {
    return EXIT_FAILURE;
  }
  std::cout << "native video activation production link gate passed\n";
  return EXIT_SUCCESS;
}
