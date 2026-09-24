#include "playback/mpv/frame_counters.hpp"
#include <cstdio>

int main() {
  wam::playback::mpv::FrameCounters counters;
  mpv_render_frame_info info{};
  counters.rendered(info, 0); // expose with no pending frame
  info.flags = MPV_RENDER_FRAME_INFO_PRESENT | MPV_RENDER_FRAME_INFO_REDRAW;
  counters.rendered(info, 0); // paused option change
  info.flags = MPV_RENDER_FRAME_INFO_PRESENT | MPV_RENDER_FRAME_INFO_REPEAT;
  counters.rendered(info, 0); // display-sync repeat
  info.flags = MPV_RENDER_FRAME_INFO_PRESENT;
  counters.rendered(info, -1); // failed draw is not presented
  if (counters.drawn() != 0) return 1;
  counters.rendered(info, 0);
  info.flags |= MPV_RENDER_FRAME_INFO_BLOCK_VSYNC;
  counters.rendered(info, 0);
  if (counters.drawn() != 2) return 2;
  counters.reset(); // a new file owns a fresh counter epoch
  if (counters.drawn() != 0) return 3;
  counters.rendered(info, 0);
  if (counters.drawn() != 1) return 4;
  std::puts("mpv counters: new frames counted; redraws/repeats/failures excluded; epoch reset passed");
}
