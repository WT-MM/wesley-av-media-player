#!/bin/sh
set -eu

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

# Treat dependency headers/frameworks as system headers so strict diagnostics
# remain focused on WAM. pkg-config emits only argument lists here.
mpv_cflags_raw=$(pkg-config --cflags mpv)
qt_cflags_raw=$(pkg-config --cflags Qt6Core Qt6Gui Qt6Quick Qt6OpenGL)
mpv_cflags=$(printf '%s\n' "$mpv_cflags_raw" | sed 's/-I/-isystem /g')
qt_cflags=$(printf '%s\n' "$qt_cflags_raw" |
  sed 's/-I/-isystem /g; s/-F/-iframework /g')
common_flags='-std=c++20 -Wall -Wextra -Wpedantic -Werror -Wconversion -Wsign-conversion -Wshadow -Wundef -Wcast-align -Wformat=2 -Wimplicit-fallthrough'
include_flags="-I$repository_dir/src -I$repository_dir/tests"

compile_target() {
  extra_defines=$1
  shift
  for source in "$@"; do
    # Intentional shell splitting: pkg-config and the strict flag variables
    # contain compiler argument lists. Every TU in one logical target receives
    # the same runtime-testing definition, preserving MpvRuntime's ODR.
    /usr/bin/clang++ $common_flags $include_flags \
      $extra_defines $mpv_cflags $qt_cflags -fsyntax-only "$source"
  done
}

compile_target '' \
  "$repository_dir/src/playback/mpv/mpv_api.cpp" \
  "$repository_dir/src/playback/mpv/mpv_runtime_common.cpp" \
  "$repository_dir/src/playback/mpv/mpv_runtime.cpp" \
  "$repository_dir/src/qt/player_core.cpp" \
  "$repository_dir/src/qt/player_controller.cpp" \
  "$repository_dir/tests/player_controller_lazy_test.cpp"

compile_target '-DWAM_PLAYER_CORE_RENDER_CONTEXT_TESTING=1' \
  "$repository_dir/src/playback/mpv/mpv_api.cpp" \
  "$repository_dir/src/playback/mpv/mpv_runtime_common.cpp" \
  "$repository_dir/src/playback/mpv/mpv_runtime.cpp" \
  "$repository_dir/src/qt/player_core.cpp" \
  "$repository_dir/src/qt/player_controller.cpp" \
  "$repository_dir/tests/player_core_render_context_permission_test.cpp"
