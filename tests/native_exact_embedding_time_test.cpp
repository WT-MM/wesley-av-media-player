#include "media/native_exact_playback.hpp"
#include "platform/macos/native_media_clock.hpp"
#include <bit>
#include <cfenv>
#include <cstdlib>
#include <iostream>
#include <limits>

using namespace wam;
namespace {
void expect(bool value, const char* message) {
  if (!value) { std::cerr << message << '\n'; std::exit(1); }
}
std::uint64_t ticks(void* value) noexcept { return *static_cast<std::uint64_t*>(value); }
}
int main() {
  expect(media::canonicalNonnegativeTime({2,6}) == media::MediaTime{1,3}, "canonical rational retains a third");
  expect(!media::canonicalNonnegativeTime({-1,3}) && !media::canonicalNonnegativeTime({1,0}), "invalid external times fail closed");
  expect(media::exactFrameCovers({0,25},{1,25},{1001,30000}), "off-grid target is covered exactly");
  expect(!media::exactFrameCovers({0,25},{1,25},{1,25}), "frame end is excluded exactly");
  expect(!media::exactFrameCovers({9007199254740992LL,1000},{1,1000},
                                {9007199254740993LL,1000}), "adjacent large ticks cannot alias at a covering boundary");
  for (int mode : {FE_TONEAREST, FE_DOWNWARD, FE_UPWARD, FE_TOWARDZERO}) {
    std::fesetround(mode);
    const auto value = media::mediaTimeSecondsAtHostTicks({1,3}, 0, 24000000, 64);
    expect(value && std::bit_cast<std::uint64_t>(*value) == 0x3fd5555555555555ULL,
        "host-clock conversion rounds only the final rational, independently of rounding mode");
  }
  std::fesetround(FE_TONEAREST);
  expect(!media::mediaTimeSecondsAtHostTicks({std::numeric_limits<std::int64_t>::max(),1},
      1, std::numeric_limits<std::uint64_t>::max(),17), "rational host-clock overflow fails closed");
  std::uint64_t now = 1000;
  macos::NativeMediaClock clock({ticks,&now,24000000});
  expect(clock.anchorExact(1,{1,3},1,false), "exact anchor is admitted");
  expect(clock.sample().exactPausedTarget == media::MediaTime{1,3}, "paused proof retains original rational");
  expect(clock.run(1,1), "exact clock runs");
  now += 12000000;
  expect(clock.sample().mediaSeconds == *media::mediaTimeSeconds({5,6}), "host elapsed time is added before binary64 rounding");
  expect(clock.pause(1), "clock pauses");
  expect(!clock.sample().exactPausedTarget.valid(), "an approximate pause is never relabelled exact");
  expect(clock.seekExact(1,2,{1001,30000}), "exact seek creates a new anchor");
  expect(clock.sample().generation == 2 && clock.sample().exactPausedTarget == media::MediaTime{1001,30000},
      "seek target and generation survive without reconstruction");
}
