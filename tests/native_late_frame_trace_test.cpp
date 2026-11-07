#include "media/native_late_frame_trace.hpp"
#include "support/expect.hpp"
#include <thread>

using wam::media::late_trace::Ring;
int main() {
  Ring<std::uint64_t, 4> ring;
  std::uint64_t value = 99;
  EXPECT(!ring.pop(value) && value == 99);
  for (unsigned i = 0; i != 4; ++i) EXPECT(ring.push(i));
  EXPECT(!ring.push(999) && ring.lost.load() == 1);
  for (unsigned i = 0; i != 4; ++i) EXPECT(ring.pop(value) && value == i);
  EXPECT(!ring.pop(value));
  Ring<std::uint64_t, 64> concurrent;
  std::thread producer([&] {
    for (std::uint64_t i = 0; i != 100000; ++i)
      while (!concurrent.push(i)) std::this_thread::yield();
  });
  for (std::uint64_t i = 0; i != 100000; ++i) {
    while (!concurrent.pop(value)) std::this_thread::yield();
    EXPECT(value == i);
  }
  producer.join();
  EXPECT(!concurrent.pop(value));
  return failures == 0 ? 0 : 1;
}
