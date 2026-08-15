#include "playback/mpv/mpv_runtime.hpp"

#include <cstdlib>
#include <iostream>

namespace {

int failures = 0;

void expect(bool condition, const char* message) {
  if (condition) {
    return;
  }
  ++failures;
  std::cerr << "FAIL: " << message << '\n';
}

}  // namespace

int main() {
  using wam::playback::mpv::MpvLinkedRuntimeFactory;
  using wam::playback::mpv::MpvRuntimeLoadError;

  const auto first = MpvLinkedRuntimeFactory::create();
  expect(static_cast<bool>(first), "linked runtime is available");
  expect(first.error == MpvRuntimeLoadError::None,
         "linked runtime reports no load error");
  if (!first) {
    return EXIT_FAILURE;
  }

  expect(first.runtime->api().complete(),
         "linked runtime publishes a complete immutable table");
  expect(first.runtime->api().mpv_create == &::mpv_create,
         "linked runtime captures the linked client image");
  expect(first.runtime->clientApiVersion() >= MPV_CLIENT_API_VERSION,
         "linked runtime is not older than its headers");
  expect((first.runtime->clientApiVersion() >> 16U) ==
             (MPV_CLIENT_API_VERSION >> 16U),
         "linked runtime has the header major version");
  expect(first.runtime->loadedPath() == QStringLiteral("linked-libmpv"),
         "linked runtime makes no dynamic-library path claim");

  const auto second = MpvLinkedRuntimeFactory::create();
  expect(second.runtime.get() == first.runtime.get(),
         "linked runtime has one process-wide identity");

  if (failures == 0) {
    std::cout << "linked mpv runtime tests passed\n";
  }
  return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
