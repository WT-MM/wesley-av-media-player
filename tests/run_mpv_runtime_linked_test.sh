#!/bin/sh
set -eu

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/wam-mpv-runtime-linked.XXXXXX")
trap 'rm -rf -- "$build_dir"' EXIT HUP INT TERM

mpv_cflags=$(pkg-config --cflags mpv)
mpv_libs=$(pkg-config --libs mpv)
qt_cflags=$(pkg-config --cflags Qt6Core)
qt_libs=$(pkg-config --libs Qt6Core)

# Intentional shell splitting: pkg-config emits compiler/linker argument lists.
/usr/bin/clang++ -std=c++20 -Wall -Wextra -Wpedantic -Werror \
  -I"$repository_dir/src" $mpv_cflags $qt_cflags \
  "$repository_dir/src/playback/mpv/mpv_api.cpp" \
  "$repository_dir/src/playback/mpv/mpv_runtime_common.cpp" \
  "$repository_dir/src/playback/mpv/mpv_runtime_linked.cpp" \
  "$repository_dir/tests/mpv_runtime_linked_test.cpp" \
  $mpv_libs $qt_libs -o "$build_dir/mpv_runtime_linked_test"

# Unlike macOS shipping objects, this non-Apple implementation deliberately
# imports the linked client. Prove the expected edge remains explicit.
if ! nm -u "$build_dir/mpv_runtime_linked_test" |
  grep -E '(^|[[:space:]])_?mpv_create$' >/dev/null; then
  echo "linked runtime test does not import the expected libmpv client" >&2
  exit 1
fi

"$build_dir/mpv_runtime_linked_test"
