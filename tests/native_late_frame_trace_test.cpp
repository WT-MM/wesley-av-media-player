#include "media/native_late_frame_trace.hpp"
#include <cstdlib>
#include <iostream>
#include <thread>

using wam::media::late_trace::Ring;
static void require(bool value) {
  if (!value) { std::cerr << "late trace invariant failed\n"; std::exit(1); }
}
int main() {
  Ring<std::uint64_t, 4> ring;
  std::uint64_t value = 99;
  require(!ring.pop(value) && value == 99);
  for (unsigned i = 0; i != 4; ++i) require(ring.push(i));
  require(!ring.push(999) && ring.lost.load() == 1);
  for (unsigned i = 0; i != 4; ++i) require(ring.pop(value) && value == i);
  require(!ring.pop(value));
  Ring<std::uint64_t, 64> concurrent;
  std::thread producer([&] {
    for (std::uint64_t i = 0; i != 100000; ++i)
      while (!concurrent.push(i)) std::this_thread::yield();
  });
  for (std::uint64_t i = 0; i != 100000; ++i) {
    while (!concurrent.pop(value)) std::this_thread::yield();
    require(value == i);
  }
  producer.join();
  require(!concurrent.pop(value));
}
