#!/bin/sh
set -eu

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/wam-mpv-runtime-test.XXXXXX")
trap 'rm -rf -- "$build_dir"' EXIT HUP INT TERM

mpv_cflags=$(pkg-config --cflags mpv)
qt_cflags=$(pkg-config --cflags Qt6Core)
qt_libs=$(pkg-config --libs Qt6Core)

build_fake() {
  variant=$1
  definition=$2
  output_dir="$build_dir/$variant"
  mkdir -p "$output_dir"
  # Intentional shell splitting: pkg-config emits compiler argument lists.
  /usr/bin/clang++ -std=c++20 -dynamiclib -fvisibility=hidden \
    -Wall -Wextra -Wpedantic -Werror \
    $mpv_cflags "$definition" \
    "$repository_dir/tests/fakes/mpv_runtime/fake_mpv.cpp" \
    -Wl,-install_name,@rpath/WAMMpvFallback.dylib \
    -o "$output_dir/WAMMpvFallback.dylib"
}

build_fake valid -DWAM_FAKE_MPV_NEWER_MINOR=1
build_fake missing -DWAM_FAKE_MPV_OMIT_WAIT_EVENT=1
build_fake wrong-major -DWAM_FAKE_MPV_WRONG_MAJOR=1
build_fake old-minor -DWAM_FAKE_MPV_OLD_MINOR=1
build_fake collision -DWAM_FAKE_MPV_COLLISION=1

# Deliberately omit every libmpv linker flag. Any direct mpv call in the
# runtime or test makes this link fail.
# Intentional shell splitting: pkg-config emits compiler argument lists.
/usr/bin/clang++ -std=c++20 \
  -Wall -Wextra -Wpedantic -Werror \
  -I"$repository_dir/src" $mpv_cflags $qt_cflags \
  "$repository_dir/src/playback/mpv/mpv_api.cpp" \
  "$repository_dir/src/playback/mpv/mpv_runtime_common.cpp" \
  "$repository_dir/src/playback/mpv/mpv_runtime.cpp" \
  "$repository_dir/tests/mpv_runtime_test.cpp" \
  $qt_libs -o "$build_dir/mpv_runtime_test"

undefined_symbols="$build_dir/mpv_runtime_test.undefined"
if ! nm -u "$build_dir/mpv_runtime_test" >"$undefined_symbols"; then
  echo "cannot inspect mpv_runtime_test undefined symbols" >&2
  exit 1
fi
if grep -E '[[:space:]]_mpv_' "$undefined_symbols" >/dev/null; then
  echo "mpv_runtime_test has a forbidden direct libmpv reference" >&2
  exit 1
fi

"$build_dir/mpv_runtime_test" \
  "$build_dir/valid/WAMMpvFallback.dylib" \
  "$build_dir/missing/WAMMpvFallback.dylib" \
  "$build_dir/wrong-major/WAMMpvFallback.dylib" \
  "$build_dir/old-minor/WAMMpvFallback.dylib" \
  "$build_dir/collision/WAMMpvFallback.dylib"
