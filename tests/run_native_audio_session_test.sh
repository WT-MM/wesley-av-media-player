#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/wam-native-audio-session.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

common_flags='-std=c++20 -Wall -Wextra -Wpedantic -Werror -Wconversion -Wsign-conversion -Wshadow -Wundef -Wcast-align -Wformat=2 -Wimplicit-fallthrough'
include_flags="-I$repo_dir/src"
test_define='-DWAM_NATIVE_AUDIO_SESSION_TESTING=1'

clang++ $common_flags $include_flags -c \
  "$repo_dir/src/media/native_media_source.cpp" \
  -o "$build_dir/native_media_source.o"
clang++ $common_flags $include_flags -c \
  "$repo_dir/src/media/native_media_dispatcher.cpp" \
  -o "$build_dir/native_media_dispatcher.o"
clang++ $common_flags $include_flags -c \
  "$repo_dir/src/platform/macos/native_pcm_ring.cpp" \
  -o "$build_dir/native_pcm_ring.o"
clang++ $common_flags $include_flags -c \
  "$repo_dir/src/platform/macos/native_media_clock.cpp" \
  -o "$build_dir/native_media_clock.o"
clang++ $common_flags $include_flags -c \
  "$repo_dir/src/platform/macos/native_audio_render_core.cpp" \
  -o "$build_dir/native_audio_render_core.o"
clang++ $common_flags $include_flags -x objective-c++ -fobjc-arc -c \
  "$repo_dir/src/platform/macos/native_audio_converter.mm" \
  -o "$build_dir/native_audio_converter.o"
clang++ $common_flags $include_flags -x objective-c++ -fobjc-arc -c \
  "$repo_dir/src/platform/macos/native_audio_output.mm" \
  -o "$build_dir/native_audio_output.o"
clang++ $common_flags $include_flags $test_define \
  -x objective-c++ -fobjc-arc -c \
  "$repo_dir/src/platform/macos/native_audio_session.mm" \
  -o "$build_dir/native_audio_session.o"
clang++ $common_flags $include_flags $test_define \
  -x objective-c++ -fobjc-arc -c \
  "$repo_dir/tests/native_audio_session_test.mm" \
  -o "$build_dir/native_audio_session_test.o"

clang++ "$build_dir"/*.o \
  -framework Foundation -framework CoreMedia -framework CoreAudio \
  -framework AudioToolbox \
  -o "$build_dir/native_audio_session_test"
"$build_dir/native_audio_session_test"
