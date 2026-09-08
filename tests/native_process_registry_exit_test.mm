#include "platform/macos/native_audio_session.hpp"
#include "platform/macos/native_video_consumer.hpp"
#include "platform/macos/native_process_lifetime.hpp"
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <unistd.h>

namespace {
bool audio = true;
void lateRegistryAccess() {
  if (audio) (void)wam::macos::NativeAudioSession::quarantineFacts();
  else (void)wam::macos::NativeVideoConsumer::quarantineFacts();
  constexpr char passed[] = "registry remained valid after global teardown\n";
  (void)::write(STDOUT_FILENO, passed, sizeof(passed) - 1);
}
// Registration must precede the ordinary static registry constructors.
__attribute__((constructor(101))) void registerLateAccess() {
  std::atexit(&lateRegistryAccess);
}
}
int main(int argc, char** argv) {
  if (argc != 2) return 2;
  audio = std::strcmp(argv[1], "audio") == 0;
  if (!audio && std::strcmp(argv[1], "video") != 0) return 2;
  static_assert(sizeof(wam::macos::NativeProcessLifetime<std::mutex>) == sizeof(std::mutex));
  static_assert(std::is_trivially_destructible_v<wam::macos::NativeProcessLifetime<std::mutex>>);
  (void)wam::macos::NativeAudioSession::quarantineFacts();
  (void)wam::macos::NativeVideoConsumer::quarantineFacts();
}
