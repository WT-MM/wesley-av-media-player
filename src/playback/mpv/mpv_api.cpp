#include "playback/mpv/mpv_api.hpp"

namespace wam::playback::mpv {

bool MpvApi::complete() const noexcept {
#define WAM_REQUIRE_MPV_SYMBOL(name) &&name != nullptr
  return true WAM_MPV_API(WAM_REQUIRE_MPV_SYMBOL);
#undef WAM_REQUIRE_MPV_SYMBOL
}

}  // namespace wam::playback::mpv
