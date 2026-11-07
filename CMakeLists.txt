cmake_minimum_required(VERSION 3.24)

file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/packaging/pins.env" wam_pin_lines
  REGEX "^WAM_[A-Z0-9_]+=")
foreach(wam_pin_line IN LISTS wam_pin_lines)
  string(REGEX MATCH "^([^=]+)=(.*)$" wam_pin_match "${wam_pin_line}")
  set(${CMAKE_MATCH_1} "${CMAKE_MATCH_2}")
endforeach()

# Qt 6.11 supports macOS 13 and newer. Pin the executable's load-command floor
# instead of inheriting the build machine's current SDK version.
if(APPLE AND NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "${WAM_MACOS_DEPLOYMENT_TARGET}" CACHE STRING
      "Minimum supported macOS version")
endif()

project(WAM VERSION 0.4.46 LANGUAGES CXX)

if(APPLE)
  # Apple-native targets below use Objective-C++ even when
  # WAM_ENABLE_MACOS_NATIVE_VIDEO is off.
  enable_language(OBJCXX)
endif()

if(APPLE)
  set(WAM_MACOS_NATIVE_VIDEO_DEFAULT ON)
else()
  set(WAM_MACOS_NATIVE_VIDEO_DEFAULT OFF)
endif()
option(WAM_ENABLE_MACOS_NATIVE_VIDEO
  "Build the shipping AVFoundation/VideoToolbox native playback path"
  ${WAM_MACOS_NATIVE_VIDEO_DEFAULT})
# VP8 is the one video codec in WAM's envelope that no Apple hardware decodes,
# so it needs a software decode stage. libvpx supplies it. Discovery is
# best-effort and the option defaults to whatever discovery found: a machine
# without libvpx configures cleanly and routes VP8 to the compatibility
# fallback.
#
# PACKAGING: this is a real runtime dependency. Development builds link the
# Homebrew dylib by absolute path -- the same shape as the staged FFmpeg
# binary. Release builds take libvpx from the pinned media closure
# (scripts/build_media_closure.sh) through PKG_CONFIG_PATH.
find_package(PkgConfig QUIET)
set(WAM_LIBVPX_FOUND OFF)
if(APPLE AND PkgConfig_FOUND)
  pkg_check_modules(WAM_LIBVPX QUIET IMPORTED_TARGET vpx)
  if(WAM_LIBVPX_FOUND)
    message(STATUS "libvpx ${WAM_LIBVPX_VERSION} found -- software VP8 decode "
      "is available")
  endif()
endif()
option(WAM_ENABLE_SOFTWARE_VP8
  "Decode VP8 in software with libvpx (no Apple hardware decoder exists)"
  ${WAM_LIBVPX_FOUND})
if(WAM_ENABLE_SOFTWARE_VP8 AND NOT WAM_LIBVPX_FOUND)
  message(FATAL_ERROR
    "WAM_ENABLE_SOFTWARE_VP8=ON but libvpx was not found by pkg-config. "
    "Install it (brew install libvpx) or configure with "
    "-DWAM_ENABLE_SOFTWARE_VP8=OFF.")
endif()
if(NOT WAM_ENABLE_SOFTWARE_VP8)
  message(STATUS
    "Software VP8 decode is off -- VP8 sources route to the compatibility "
    "fallback.")
endif()

set(WAM_FFMPEG_LGPL_ROOT "${CMAKE_SOURCE_DIR}/third_party/ffmpeg-lgpl" CACHE PATH
    "Pinned native FFmpeg LGPL installation")
option(WAM_ENABLE_AVFORMAT_STAGE "Build the native libavformat demux stage" ${APPLE})
option(WAM_ENABLE_AVCODEC_STAGE "Build the native libavcodec decode adapters" OFF)
if(WAM_ENABLE_AVCODEC_STAGE OR WAM_ENABLE_AVFORMAT_STAGE)
  if(NOT APPLE OR NOT EXISTS "${WAM_FFMPEG_LGPL_ROOT}/include/libavcodec/avcodec.h")
    message(FATAL_ERROR "Run scripts/build_ffmpeg_lgpl.sh with the pinned local archive first")
  endif()
endif()

set(WAM_NATIVE_VIDEO_TEST_FIXTURE "" CACHE FILEPATH
  "Optional H.264 B-frame fixture used by the macOS VideoToolbox test")
set(WAM_NATIVE_VIDEO_10BIT_TEST_FIXTURE "" CACHE FILEPATH
  "Optional Main 10 HEVC fixture used by the macOS VideoToolbox test")
option(WAM_REQUIRE_NATIVE_VIDEO_TEST_HARDWARE
  "Require hardware H.264/Main 10 decoding in the macOS VideoToolbox test"
  OFF)

option(WAM_NATIVE_BENCHMARK_TELEMETRY
  "Compile per-frame deadline diagnostics (also requires runtime opt-in)" OFF)
if(WAM_NATIVE_BENCHMARK_TELEMETRY AND NOT APPLE)
  message(FATAL_ERROR "WAM_NATIVE_BENCHMARK_TELEMETRY is available only on macOS")
endif()

include(CTest)
if(WAM_REQUIRE_NATIVE_VIDEO_TEST_HARDWARE AND
    (NOT APPLE OR NOT BUILD_TESTING OR
     NOT WAM_ENABLE_MACOS_NATIVE_VIDEO))
  message(FATAL_ERROR
    "WAM_REQUIRE_NATIVE_VIDEO_TEST_HARDWARE requires macOS, "
    "BUILD_TESTING=ON, and WAM_ENABLE_MACOS_NATIVE_VIDEO=ON")
endif()

if(WAM_ENABLE_MACOS_NATIVE_VIDEO AND NOT APPLE)
  message(FATAL_ERROR
    "WAM_ENABLE_MACOS_NATIVE_VIDEO is available only on macOS")
endif()
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(WAM_BUILD_APP "Build WAM's Qt application" ON)
option(WAM_BUILD_WAMKIT "Build the native embedding framework" ${APPLE})

if(BUILD_TESTING OR (APPLE AND WAM_BUILD_WAMKIT))
  find_package(Python3 COMPONENTS Interpreter REQUIRED)
endif()

configure_file(cmake/wam_pins.hpp.in
  "${PROJECT_BINARY_DIR}/generated/wam_pins.hpp" @ONLY)
add_library(wam_pins INTERFACE)
target_include_directories(wam_pins INTERFACE "${PROJECT_BINARY_DIR}/generated")

include(cmake/CaptionBackend.cmake)

# The app's Qt-free core: export and caption jobs, persisted state and the
# scroll-gesture model. The app and the tests link it (tests that need its
# seams link the wam_app_core_test_seams twin).
add_library(wam_app_core STATIC
  src/jobs.cpp
  src/jobs.hpp
  src/caption_service.cpp
  src/caption_service.hpp
  src/state_store.cpp
  src/state_store.hpp
  src/qt/scroll_gesture.cpp
  src/qt/scroll_gesture.hpp)
target_include_directories(wam_app_core PUBLIC src)
target_compile_features(wam_app_core PUBLIC cxx_std_20)
if(MSVC)
  target_compile_options(wam_app_core PRIVATE /W4)
else()
  target_compile_options(wam_app_core PRIVATE -Wall -Wextra -Wpedantic)
endif()
target_link_libraries(wam_app_core PUBLIC wam_caption_runtime)

include(cmake/NativeTargets.cmake)
if(WAM_BUILD_APP)
  include(cmake/WamApp.cmake)
endif()
if(BUILD_TESTING OR WAMKIT_ENABLE_TEST_SUPPORT)
  include(cmake/TestSeams.cmake)
endif()
if(BUILD_TESTING)
  add_subdirectory(tests)
endif()
if(APPLE AND WAM_BUILD_WAMKIT)
  add_subdirectory(src/wamkit)
endif()
