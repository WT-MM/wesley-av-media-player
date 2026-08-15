#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/wam-native-media-session.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM
mkdir "$build_dir/production"

common_flags='-std=c++20 -Wall -Wextra -Wpedantic -Werror -Wconversion -Wsign-conversion -Wshadow -Wundef -Wcast-align -Wformat=2 -Wimplicit-fallthrough'
include_flags="-I$repo_dir/src"
test_defines='-DWAM_AVFOUNDATION_ASSET_CONTEXT_TESTING=1 -DWAM_NATIVE_MEDIA_SESSION_TESTING=1'

clang++ $common_flags $include_flags $test_defines -c \
  "$repo_dir/src/media/native_media_source.cpp" \
  -o "$build_dir/native_media_source.o"
clang++ $common_flags $include_flags $test_defines -c \
  "$repo_dir/src/media/native_media_dispatcher.cpp" \
  -o "$build_dir/native_media_dispatcher.o"

# Mirror wam_macos_native_video_core, which the CMake session gate links as a
# production-layout archive. These objects deliberately do not see test seams.
clang++ $common_flags $include_flags -x objective-c++ -fobjc-arc -c \
  "$repo_dir/src/platform/macos/native_surface_budget.mm" \
  -o "$build_dir/native_surface_budget.o"
clang++ $common_flags $include_flags -x objective-c++ -fobjc-arc -c \
  "$repo_dir/src/platform/macos/native_video_presenter.mm" \
  -o "$build_dir/native_video_presenter.o"
clang++ $common_flags $include_flags -x objective-c++ -fobjc-arc -c \
  "$repo_dir/src/platform/macos/video_toolbox_decoder.mm" \
  -o "$build_dir/video_toolbox_decoder.o"

# Mirror the private macro-bearing source closure of
# wam_native_media_session_test. Every implementation in this closure must see
# both seams so declarations and class layouts match the test translation unit.
clang++ $common_flags $include_flags $test_defines \
  -x objective-c++ -fobjc-arc -c \
  "$repo_dir/src/platform/macos/avfoundation_asset_context.mm" \
  -o "$build_dir/avfoundation_asset_context.o"
clang++ $common_flags $include_flags $test_defines \
  -x objective-c++ -fobjc-arc -c \
  "$repo_dir/src/platform/macos/avfoundation_preview_source.mm" \
  -o "$build_dir/avfoundation_preview_source.o"
clang++ $common_flags $include_flags $test_defines \
  -x objective-c++ -fobjc-arc -c \
  "$repo_dir/src/platform/macos/native_media_session.mm" \
  -o "$build_dir/native_media_session.o"
clang++ $common_flags $include_flags $test_defines \
  -x objective-c++ -fobjc-arc -c \
  "$repo_dir/src/platform/macos/native_preview_frame_lane.mm" \
  -o "$build_dir/native_preview_frame_lane.o"
# Compile the concrete production branch separately. Keeping the object in a
# subdirectory prevents duplicate symbols in the deterministic test link.
clang++ $common_flags $include_flags \
  -x objective-c++ -fobjc-arc -c \
  "$repo_dir/src/platform/macos/native_media_session.mm" \
  -o "$build_dir/production/native_media_session.o"
clang++ $common_flags $include_flags $test_defines \
  -x objective-c++ -fobjc-arc -c \
  "$repo_dir/tests/native_media_session_test.mm" \
  -o "$build_dir/native_media_session_test.o"

clang++ "$build_dir"/*.o \
  -framework CoreFoundation -framework CoreGraphics -framework CoreMedia \
  -framework CoreVideo -framework Foundation -framework IOSurface \
  -framework AudioToolbox -framework CoreAudio -framework AVFoundation \
  -framework VideoToolbox \
  -o "$build_dir/native_media_session_test"
"$build_dir/native_media_session_test"
