#pragma once

#include "player_core_p.hpp"

namespace wam::qt {

// Shared by the scene-graph node and its deterministic gate test. A render
// pass that no longer wants libmpv presentation is the safe point at which its
// current OpenGL context can release the renderer without blocking the GUI.
[[nodiscard]] inline bool retainMpvRenderContextForPass(
    PlayerCore& core, bool render_requested) {
  if (render_requested && core.renderContextAllowed())
    return true;
  core.releaseRenderContext();
  return false;
}

}  // namespace wam::qt
