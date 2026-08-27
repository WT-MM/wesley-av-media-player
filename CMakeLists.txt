cmake_minimum_required(VERSION 3.24)

# Qt 6.11 supports macOS 13 and newer. Pin the executable's load-command floor
# instead of inheriting the build machine's current SDK version.
if(APPLE AND NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "13.3" CACHE STRING
      "Minimum supported macOS version")
endif()

project(WAM VERSION 0.4.11 LANGUAGES CXX)

if(APPLE)
  # Apple-native targets below use Objective-C++ even when the dormant legacy
  # video option is off. Enabling the language here keeps target availability
  # independent of that older feature gate.
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
option(WAM_ENABLE_MACOS_NATIVE_VIDEO_ACTIVATION
  "Compile the dormant macOS native-video activation seam"
  OFF)
# VP8 is the one video codec in WAM's envelope that no Apple hardware decodes,
# so it needs a software decode stage. libvpx supplies it. Discovery is
# best-effort and the option defaults to whatever discovery found: a machine
# without libvpx configures cleanly and simply keeps routing VP8 to the
# compatibility fallback, exactly as before this stage existed.
#
# PACKAGING: this adds a real runtime dependency. Development builds link the
# Homebrew dylib by absolute path -- the same shape as the staged FFmpeg
# binary -- but a shipped app needs libvpx added to the pinned, relocatable
# closure in scripts/bundle_macos.zsh and to the release workflow's
# checksum-pinned media archive. Until that lands, a bundled WAM.app must be
# built with WAM_ENABLE_SOFTWARE_VP8=OFF or it will not launch off this
# machine.
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

set(WAM_NATIVE_VIDEO_TEST_FIXTURE "" CACHE FILEPATH
  "Optional H.264 B-frame fixture used by the macOS VideoToolbox test")
set(WAM_NATIVE_VIDEO_10BIT_TEST_FIXTURE "" CACHE FILEPATH
  "Optional Main 10 HEVC fixture used by the macOS VideoToolbox test")
option(WAM_REQUIRE_NATIVE_VIDEO_TEST_HARDWARE
  "Require hardware H.264/Main 10 decoding in the macOS VideoToolbox test"
  OFF)

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
if(WAM_ENABLE_MACOS_NATIVE_VIDEO_ACTIVATION AND NOT APPLE)
  message(FATAL_ERROR
    "WAM_ENABLE_MACOS_NATIVE_VIDEO_ACTIVATION is available only on macOS")
endif()
if(WAM_ENABLE_MACOS_NATIVE_VIDEO_ACTIVATION AND
    NOT WAM_ENABLE_MACOS_NATIVE_VIDEO)
  message(FATAL_ERROR
    "WAM_ENABLE_MACOS_NATIVE_VIDEO_ACTIVATION requires "
    "WAM_ENABLE_MACOS_NATIVE_VIDEO=ON")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

find_package(Qt6 6.11 REQUIRED COMPONENTS
  Core
  Gui
  Qml
  Quick
  QuickControls2
  QuickDialogs2
  QuickLayouts
  OpenGL
  LabsPlatform)
find_package(PkgConfig REQUIRED)
if(APPLE)
  # The native-first macOS executable needs libmpv's declarations to compile
  # its dormant compatibility client, but it must not acquire a load command
  # for libmpv. The fallback runtime resolves the complete API table only
  # after the playback router explicitly selects fallback.
  pkg_check_modules(MPV_HEADERS REQUIRED mpv)
  add_library(wam_mpv_headers INTERFACE)
  target_include_directories(wam_mpv_headers SYSTEM INTERFACE
    ${MPV_HEADERS_INCLUDE_DIRS})
  target_compile_options(wam_mpv_headers INTERFACE
    ${MPV_HEADERS_CFLAGS_OTHER})
else()
  pkg_check_modules(MPV REQUIRED IMPORTED_TARGET mpv)
  add_library(wam_mpv_headers INTERFACE)
  target_link_libraries(wam_mpv_headers INTERFACE PkgConfig::MPV)
endif()
include(cmake/WamMsys2PkgConfig.cmake)
if(TARGET PkgConfig::MPV)
  wam_normalize_msys2_pkgconfig_target(PkgConfig::MPV ${MPV_LIBRARY_DIRS})
endif()
if(APPLE AND BUILD_TESTING)
  # These two legacy integration tests intentionally exercise a real linked
  # mpv client through an injected table. Keep that strong dependency private
  # to tests; the shipping executable sees only wam_mpv_headers.
  pkg_check_modules(MPV_TEST_LINK REQUIRED IMPORTED_TARGET mpv)
  set(WAM_MPV_INTEGRATION_TEST_TARGET PkgConfig::MPV_TEST_LINK)
else()
  set(WAM_MPV_INTEGRATION_TEST_TARGET PkgConfig::MPV)
endif()

qt_standard_project_setup(REQUIRES 6.11)

qt_add_executable(wam MACOSX_BUNDLE WIN32
  src/qt/main.cpp
  src/qt/player_controller.cpp
  src/qt/player_controller.hpp
  src/qt/subtitle_sources.cpp
  src/qt/subtitle_sources.hpp
  src/qt/scroll_gesture.cpp
  src/qt/scroll_gesture.hpp
  src/qt/player_core.cpp
  src/qt/player_core_p.hpp
  src/qt/mpv_hwdec_interop_policy.hpp
  src/qt/render_lifecycle.hpp
  src/qt/playback_policy.hpp
  src/qt/mpv_video_item.cpp
  src/qt/mpv_video_item.hpp
  src/qt/window_manager.cpp
  src/qt/window_manager.hpp
  src/jobs.cpp
  src/jobs.hpp
  src/caption_service.cpp
  src/caption_service.hpp
  src/state_store.cpp
  src/state_store.hpp)

qt_add_qml_module(wam
  URI Wam
  VERSION 1.0
  QML_FILES
    qml/Main.qml
    qml/FloatingControls.qml
    qml/NoticeToast.qml
    qml/ValueOsd.qml
    qml/IconButton.qml
    qml/QuietButton.qml
    qml/ChromeToolTip.qml
    qml/QuickEditSheet.qml
    qml/CropOverlay.qml
    qml/PreferencesWindow.qml
    qml/AppPreferences.qml
    qml/Scrubber.qml
    qml/AppMenuBar.qml
    qml/AppMenu.qml)

target_include_directories(wam PRIVATE src src/qt)
target_compile_definitions(wam PRIVATE WAM_VERSION="${PROJECT_VERSION}")
target_link_libraries(wam PRIVATE
  Qt6::Core
  Qt6::Gui
  Qt6::Qml
  Qt6::Quick
  Qt6::QuickControls2
  Qt6::QuickDialogs2
  Qt6::QuickLayouts
  Qt6::OpenGL
  Qt6::LabsPlatform
  wam_mpv_headers)

if(MSVC)
  target_compile_options(wam PRIVATE /W4 /permissive-)
else()
  target_compile_options(wam PRIVATE -Wall -Wextra -Wpedantic)
endif()

add_library(wam_mpv_runtime STATIC
  src/playback/mpv/mpv_api.hpp
  src/playback/mpv/mpv_api.cpp
  src/playback/mpv/mpv_runtime.hpp
  src/playback/mpv/mpv_runtime_common.cpp)
if(APPLE)
  target_sources(wam_mpv_runtime PRIVATE
    src/playback/mpv/mpv_runtime.cpp)
else()
  target_sources(wam_mpv_runtime PRIVATE
    src/playback/mpv/mpv_runtime_linked.cpp)
endif()
target_include_directories(wam_mpv_runtime PUBLIC src)
target_compile_features(wam_mpv_runtime PUBLIC cxx_std_20)
if(MSVC)
  target_compile_options(wam_mpv_runtime PRIVATE /W4 /permissive-)
else()
  target_compile_options(wam_mpv_runtime PRIVATE
    -Wall -Wextra -Wpedantic)
endif()
target_link_libraries(wam_mpv_runtime
  PUBLIC
    Qt6::Core
    wam_mpv_headers)
if(CMAKE_DL_LIBS)
  target_link_libraries(wam_mpv_runtime PRIVATE ${CMAKE_DL_LIBS})
endif()
target_link_libraries(wam PRIVATE wam_mpv_runtime)

# Stage FFmpeg into the development runtime.
#
# The packaged app carries its own FFmpeg in Contents/Resources/tools, staged by
# scripts/bundle_macos.zsh from the release workflow's pinned dependency closure.
# The development app had no equivalent and fell through to the host's
# /opt/homebrew/bin, which a GUI launch can still reach because the tool search
# consults the standard install prefixes directly rather than PATH. Copying the
# binary into build/runtime -- which the search ranks above every host prefix --
# makes the development app resolve *its own* FFmpeg, so the dev and packaged
# routes exercise the same code path instead of only the packaged one.
#
# This is a plain copy of the executable, not a relocatable closure: the copied
# binary still references its Homebrew/MacPorts dylibs by absolute path and so
# only runs on a machine that has them. That is exactly right for a development
# build and deliberately not enough for shipping -- building a self-contained
# closure (dylib collection, install_name rewriting, signing) is
# scripts/bundle_macos.zsh's job and stays there.
find_program(WAM_DEV_FFMPEG_EXECUTABLE
  NAMES ffmpeg
  HINTS /opt/homebrew/bin /usr/local/bin /opt/local/bin
  DOC "FFmpeg binary staged into the development runtime (build/runtime)")
if(WAM_DEV_FFMPEG_EXECUTABLE)
  # A custom command keyed on the staged file, rather than a POST_BUILD hook:
  # the build system then restores build/runtime/ffmpeg when it is missing or
  # older than its source, even on a build where nothing else changed and the
  # app does not relink.
  set(WAM_STAGED_FFMPEG "${CMAKE_CURRENT_BINARY_DIR}/runtime/ffmpeg")
  add_custom_command(
    OUTPUT "${WAM_STAGED_FFMPEG}"
    COMMAND ${CMAKE_COMMAND} -E make_directory
      "${CMAKE_CURRENT_BINARY_DIR}/runtime"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${WAM_DEV_FFMPEG_EXECUTABLE}" "${WAM_STAGED_FFMPEG}"
    DEPENDS "${WAM_DEV_FFMPEG_EXECUTABLE}"
    COMMENT "Staging FFmpeg into build/runtime for the development app"
    VERBATIM)
  add_custom_target(wam_stage_ffmpeg DEPENDS "${WAM_STAGED_FFMPEG}")
  add_dependencies(wam wam_stage_ffmpeg)
else()
  # Not an error: WAM runs without FFmpeg and only export needs it, so a
  # developer who has not installed it should still get a working build.
  message(STATUS
    "FFmpeg not found -- build/runtime/ffmpeg will not be staged. "
    "Video export in build/WAM.app will report the tool as missing until "
    "FFmpeg is installed (brew install ffmpeg) and CMake is re-run.")
endif()

if(APPLE)
  add_library(wam_native_core STATIC
    src/media/matroska_aac.hpp
    src/media/matroska_aac.cpp
    src/media/audio_codec_timing.hpp
    src/media/audio_downmix.hpp
    src/media/audio_downmix.cpp
    src/media/matroska_opus.hpp
    src/media/matroska_opus.cpp
    src/media/matroska_vorbis.hpp
    src/media/matroska_vorbis.cpp
    src/media/matroska_ac3.hpp
    src/media/matroska_ac3.cpp
    src/media/matroska_flac.hpp
    src/media/matroska_flac.cpp
    src/media/matroska_mpeg_audio.hpp
    src/media/matroska_mpeg_audio.cpp
    src/media/matroska_ebml.hpp
    src/media/matroska_ebml.cpp
    src/media/matroska_demuxer.hpp
    src/media/matroska_demuxer.cpp
    src/media/subtitle_text.hpp
    src/media/subtitle_text.cpp
    src/media/matroska_subtitles.hpp
    src/media/matroska_subtitles.cpp
    src/media/mpegts_packet.hpp
    src/media/mpegts_packet.cpp
    src/media/mpegts_demuxer.hpp
    src/media/mpegts_demuxer.cpp
    src/media/video_codec_configuration.hpp
    src/media/video_codec_configuration.cpp
    src/media/native_media_source.hpp
    src/media/native_media_source.cpp
    src/media/native_media_backend.hpp
    src/media/native_media_backend.cpp
    src/media/native_media_dispatcher.hpp
    src/media/native_media_dispatcher.cpp
    src/media/native_playback_contract.hpp
    src/media/playback_router.hpp
    src/media/playback_router.cpp
    src/platform/macos/native_media_clock.hpp
    src/platform/macos/native_media_clock.cpp
    src/platform/macos/native_pcm_ring.hpp
    src/platform/macos/native_pcm_ring.cpp
    src/platform/macos/native_audio_render_core.hpp
    src/platform/macos/native_audio_render_core.cpp)
  target_include_directories(wam_native_core PUBLIC src)
  target_compile_features(wam_native_core PUBLIC cxx_std_20)
  target_compile_options(wam_native_core PRIVATE
    -Wall -Wextra -Wpedantic)
  if(WAM_ENABLE_SOFTWARE_VP8)
    # The demuxer must not name V_VP8 in a build whose platform layer cannot
    # decode it: admitting the track and then failing the open is a worse
    # fallback than never selecting it.
    target_compile_definitions(wam_native_core PUBLIC WAM_ENABLE_SOFTWARE_VP8)
  endif()
endif()

if(APPLE)
  set(WAM_MACOS_ICON "${CMAKE_CURRENT_SOURCE_DIR}/assets/WAM.icns")
  set_source_files_properties("${WAM_MACOS_ICON}" PROPERTIES
    MACOSX_PACKAGE_LOCATION "Resources")
  target_sources(wam PRIVATE "${WAM_MACOS_ICON}")
  set_target_properties(wam PROPERTIES
    OUTPUT_NAME "WAM"
    MACOSX_BUNDLE_BUNDLE_NAME "Wesley's Audiovisual Media Player"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.wesleymaa.wam"
    MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
    MACOSX_BUNDLE_ICON_FILE "WAM.icns"
    # Same template Qt's own qt_add_executable(MACOSX_BUNDLE) would generate
    # (see .../lib/cmake/Qt6/macos/Info.plist.app.in), plus CFBundleDocumentTypes
    # / UTImportedTypeDeclarations so WAM can be set as the default handler for
    # the media it opens without shadowing system UTIs or overriding Finder's
    # QuickLook video-frame thumbnails -- see packaging/Info.plist.in for the
    # detailed rationale.
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/packaging/Info.plist.in"
    BUILD_RPATH "/opt/homebrew/lib;/opt/homebrew/opt/qt/lib"
    INSTALL_RPATH "@executable_path/../Frameworks")

  # The macOS stage always owns one tracked native surface, even before a
  # native media epoch is selected. Keep its implementation and the neutral
  # FrameLease/video primitives in one Apple-only production closure. Metal
  # texture mapping lives in its opt-in archive below so the OpenGL route does
  # not acquire Metal merely by retaining decoded-frame leases.
  find_library(WAM_COREFOUNDATION_FRAMEWORK CoreFoundation REQUIRED)
  find_library(WAM_COREMEDIA_FRAMEWORK CoreMedia REQUIRED)
  find_library(WAM_COREVIDEO_FRAMEWORK CoreVideo REQUIRED)
  find_library(WAM_FOUNDATION_FRAMEWORK Foundation REQUIRED)
  find_library(WAM_IOSURFACE_FRAMEWORK IOSurface REQUIRED)
  find_library(WAM_OPENGL_FRAMEWORK OpenGL REQUIRED)
  find_library(WAM_VIDEOTOOLBOX_FRAMEWORK VideoToolbox REQUIRED)

  set(WAM_MACOS_NATIVE_VIDEO_CORE_SOURCES
    src/platform/macos/native_surface_budget.hpp
    src/platform/macos/native_surface_budget.mm
    src/platform/macos/native_video_codec_capability.hpp
    src/platform/macos/native_video_codec_capability.mm
    src/platform/macos/native_video_limits.hpp
    src/platform/macos/native_video_presenter.hpp
    src/platform/macos/native_video_presenter.mm
    src/platform/macos/video_toolbox_decoder.hpp
    src/platform/macos/video_toolbox_decoder.mm
    src/platform/macos/software_vp8_decoder.hpp
    src/platform/macos/software_vp8_decoder.mm
    src/platform/macos/video_decode_lane.hpp)
  add_library(wam_macos_native_video_core STATIC
    ${WAM_MACOS_NATIVE_VIDEO_CORE_SOURCES})
  target_include_directories(wam_macos_native_video_core PUBLIC src)
  target_compile_features(wam_macos_native_video_core PUBLIC cxx_std_20)
  target_compile_options(wam_macos_native_video_core PRIVATE
    "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
    -Wall -Wextra -Wpedantic)
  target_link_libraries(wam_macos_native_video_core PUBLIC
    "${WAM_COREFOUNDATION_FRAMEWORK}"
    "${WAM_COREMEDIA_FRAMEWORK}"
    "${WAM_COREVIDEO_FRAMEWORK}"
    "${WAM_FOUNDATION_FRAMEWORK}"
    "${WAM_IOSURFACE_FRAMEWORK}"
    "${WAM_VIDEOTOOLBOX_FRAMEWORK}")
  if(WAM_ENABLE_SOFTWARE_VP8)
    target_compile_definitions(wam_macos_native_video_core PUBLIC
      WAM_ENABLE_SOFTWARE_VP8)
    target_link_libraries(wam_macos_native_video_core PUBLIC
      PkgConfig::WAM_LIBVPX)
  endif()
  set_target_properties(wam_macos_native_video_core PROPERTIES
    LINKER_LANGUAGE OBJCXX)

  add_library(wam_macos_native_qt_tracked STATIC
    src/platform/macos/native_qt_gl_output.hpp
    src/platform/macos/native_qt_gl_output.mm
    src/platform/macos/native_layer_video_output.hpp
    src/platform/macos/native_layer_video_output.mm
    src/platform/macos/native_layer_host_view.hpp
    src/platform/macos/native_layer_host_view.mm
    src/platform/macos/qt_gl_video_item.hpp
    src/platform/macos/qt_gl_video_item.mm)
  target_include_directories(wam_macos_native_qt_tracked PUBLIC src)
  target_compile_features(wam_macos_native_qt_tracked PUBLIC cxx_std_20)
  target_compile_definitions(wam_macos_native_qt_tracked PRIVATE
    GL_SILENCE_DEPRECATION=1)
  target_compile_options(wam_macos_native_qt_tracked PRIVATE
    "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
    -Wall -Wextra -Wpedantic)
  target_link_libraries(wam_macos_native_qt_tracked
    PUBLIC
      wam_macos_native_video_core
      Qt6::Core
      Qt6::Gui
      Qt6::Quick
    PRIVATE
      "${WAM_OPENGL_FRAMEWORK}"
      "-framework AVFoundation"
      "-framework QuartzCore")
  set_target_properties(wam_macos_native_qt_tracked PROPERTIES
    AUTOMOC ON
    LINKER_LANGUAGE OBJCXX)
  target_link_libraries(wam PRIVATE wam_macos_native_qt_tracked)

  # QuickTime-style window chrome (transparent full-size-content titlebar,
  # aspect-ratio-locked interactive resizing, double-click Actual Size) is a
  # small always-on AppKit UI helper, independent of which video backend is
  # selected, so it is not gated behind WAM_ENABLE_MACOS_NATIVE_VIDEO below.
  find_library(WAM_APPKIT_FRAMEWORK AppKit REQUIRED)
  find_library(WAM_QUARTZCORE_FRAMEWORK QuartzCore REQUIRED)
  find_library(WAM_AVFOUNDATION_FRAMEWORK AVFoundation REQUIRED)
  target_sources(wam PRIVATE
    src/qt/macos_window_chrome.hpp
    src/qt/macos_window_chrome.mm)
  # ARC only for the window-chrome helper: the playback .mm sources are
  # ARC-agnostic by design and pay per-frame retain/release costs under ARC.
  set_source_files_properties(src/qt/macos_window_chrome.mm PROPERTIES
    COMPILE_OPTIONS "-fobjc-arc")
  target_link_libraries(wam PRIVATE
    "${WAM_APPKIT_FRAMEWORK}"
    "${WAM_QUARTZCORE_FRAMEWORK}"
    "${WAM_AVFOUNDATION_FRAMEWORK}")
  set_target_properties(wam PROPERTIES LINKER_LANGUAGE OBJCXX)

  if(WAM_ENABLE_MACOS_NATIVE_VIDEO)
    find_library(WAM_COREGRAPHICS_FRAMEWORK CoreGraphics REQUIRED)
    find_library(WAM_APPKIT_FRAMEWORK AppKit REQUIRED)
    find_library(WAM_AUDIOTOOLBOX_FRAMEWORK AudioToolbox REQUIRED)
    find_library(WAM_COREAUDIO_FRAMEWORK CoreAudio REQUIRED)
    find_library(WAM_AVFOUNDATION_FRAMEWORK AVFoundation REQUIRED)
    find_library(WAM_METAL_FRAMEWORK Metal REQUIRED)
    find_library(WAM_QUARTZCORE_FRAMEWORK QuartzCore REQUIRED)

    set(WAM_MACOS_NATIVE_VIDEO_METAL_MAPPER_SOURCES
      src/platform/macos/native_video_metal_mapper.mm)
    add_library(wam_macos_native_video_metal_mapper STATIC
      ${WAM_MACOS_NATIVE_VIDEO_METAL_MAPPER_SOURCES})
    target_include_directories(
      wam_macos_native_video_metal_mapper PUBLIC src)
    target_compile_features(
      wam_macos_native_video_metal_mapper PUBLIC cxx_std_20)
    target_compile_options(wam_macos_native_video_metal_mapper PRIVATE
      "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
      -Wall -Wextra -Wpedantic)
    target_link_libraries(wam_macos_native_video_metal_mapper
      PUBLIC
        wam_macos_native_video_core
      PRIVATE
        "${WAM_METAL_FRAMEWORK}")
    set_target_properties(wam_macos_native_video_metal_mapper PROPERTIES
      LINKER_LANGUAGE OBJCXX)

    set(WAM_MACOS_NATIVE_BACKEND_SOURCES
      src/platform/macos/avfoundation_asset_context.hpp
      src/platform/macos/avfoundation_asset_context.mm
      src/platform/macos/avfoundation_media_source.hpp
      src/platform/macos/avfoundation_media_source.mm
      src/platform/macos/avfoundation_preview_source.hpp
      src/platform/macos/avfoundation_preview_source.mm
      src/platform/macos/matroska_asset_context.hpp
      src/platform/macos/matroska_asset_context.cpp
      src/platform/macos/matroska_media_source.hpp
      src/platform/macos/matroska_media_source.mm
      src/platform/macos/matroska_preview_source.hpp
      src/platform/macos/matroska_preview_source.mm
      src/platform/macos/matroska_sample_builder.hpp
      src/platform/macos/matroska_sample_builder.mm
      src/platform/macos/mpegts_asset_context.hpp
      src/platform/macos/mpegts_asset_context.cpp
      src/platform/macos/mpegts_media_source.hpp
      src/platform/macos/mpegts_media_source.mm
      src/platform/macos/mpegts_preview_source.hpp
      src/platform/macos/mpegts_preview_source.mm
      src/platform/macos/mpegts_sample_builder.hpp
      src/platform/macos/mpegts_sample_builder.mm
      src/platform/macos/native_preview_source.hpp
      src/platform/macos/native_preview_source.mm
      src/platform/macos/native_audio_converter.hpp
      src/platform/macos/native_audio_converter.mm
      src/platform/macos/native_audio_output.hpp
      src/platform/macos/native_audio_output.mm
      src/platform/macos/native_audio_stretch_stage.hpp
      src/platform/macos/native_audio_stretch_stage.mm
      src/platform/macos/native_audio_session.hpp
      src/platform/macos/native_audio_session.mm
      src/platform/macos/native_media_session.hpp
      src/platform/macos/native_media_session.mm
      src/platform/macos/native_silent_timebase.hpp
      src/platform/macos/native_silent_timebase.cpp
      src/platform/macos/native_preview_frame_lane.hpp
      src/platform/macos/native_preview_frame_lane.mm
      src/platform/macos/native_tracked_video_arbiter.hpp
      src/platform/macos/native_tracked_video_arbiter.mm
      src/platform/macos/native_tracked_video_output.hpp
      src/platform/macos/native_video_consumer.hpp
      src/platform/macos/native_video_consumer.mm)

    add_library(wam_macos_native_backend STATIC
      ${WAM_MACOS_NATIVE_BACKEND_SOURCES})
    target_include_directories(wam_macos_native_backend PUBLIC src)
    target_compile_features(wam_macos_native_backend PUBLIC cxx_std_20)
    target_compile_options(wam_macos_native_backend PRIVATE
      "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
      -Wall -Wextra -Wpedantic)
    target_link_libraries(wam_macos_native_backend PUBLIC
      wam_native_core
      wam_macos_native_video_core
      "${WAM_COREFOUNDATION_FRAMEWORK}"
      "${WAM_COREGRAPHICS_FRAMEWORK}"
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_COREVIDEO_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_IOSURFACE_FRAMEWORK}"
      "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
      "${WAM_COREAUDIO_FRAMEWORK}"
      "${WAM_AVFOUNDATION_FRAMEWORK}"
      "${WAM_VIDEOTOOLBOX_FRAMEWORK}")
    set_target_properties(wam_macos_native_backend PROPERTIES
      LINKER_LANGUAGE OBJCXX)

    # This production factory is the only layer that joins the platform
    # session backend to its tracked Qt output. PlayerController's macOS route
    # owner now consumes it directly; keep both implementations single-owned
    # while making the native route part of the shipping executable.
    add_library(wam_macos_native_session_system STATIC
      src/platform/macos/native_media_session_system.hpp
      src/platform/macos/native_media_session_system.mm)
    target_include_directories(wam_macos_native_session_system PUBLIC src)
    target_compile_features(wam_macos_native_session_system PUBLIC cxx_std_20)
    target_compile_options(wam_macos_native_session_system PRIVATE
      "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
      -Wall -Wextra -Wpedantic)
    target_link_libraries(wam_macos_native_session_system
      PUBLIC
        wam_macos_native_backend
        wam_macos_native_qt_tracked)
    set_target_properties(wam_macos_native_session_system PROPERTIES
      LINKER_LANGUAGE OBJCXX)

    target_sources(wam PRIVATE
      src/qt/native_benchmark_telemetry.hpp
      src/qt/native_benchmark_telemetry.cpp
      src/qt/native_playback_metrics.hpp
      src/qt/native_playback_metrics.cpp
      src/qt/native_open_preflight.hpp
      src/qt/native_open_preflight.mm
      src/qt/native_playback_owner.hpp
      src/qt/native_playback_owner.mm)
    target_compile_definitions(wam PRIVATE
      WAM_HAS_MACOS_NATIVE_PLAYBACK=1)
    target_compile_options(wam PRIVATE
      "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
    target_link_libraries(wam PRIVATE
      wam_macos_native_session_system)
    set_target_properties(wam PROPERTIES LINKER_LANGUAGE OBJCXX)

    # Legacy tests that require decoder-only test seams compile a private
    # variant of this exact subset. Keep the new audio/source consumers out of
    # that macro-bearing archive so production and test class layouts cannot
    # mix.
    set(WAM_MACOS_NATIVE_VIDEO_SOURCES
      src/platform/macos/metal_layer_presenter.hpp
      src/platform/macos/metal_layer_presenter.mm
      src/platform/macos/native_video_pipeline.hpp
      src/platform/macos/native_video_pipeline.mm)
    add_library(wam_macos_native_video STATIC
      ${WAM_MACOS_NATIVE_VIDEO_SOURCES})
    target_include_directories(wam_macos_native_video PUBLIC src)
    target_compile_features(wam_macos_native_video PUBLIC cxx_std_20)
    target_compile_options(wam_macos_native_video PRIVATE
      "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
      -Wall -Wextra -Wpedantic)
    target_link_libraries(wam_macos_native_video PUBLIC
      wam_macos_native_video_metal_mapper
      "${WAM_APPKIT_FRAMEWORK}"
      "${WAM_QUARTZCORE_FRAMEWORK}"
      "${WAM_AVFOUNDATION_FRAMEWORK}")

    if(WAM_ENABLE_MACOS_NATIVE_VIDEO_ACTIVATION)
      # Compile the already-reviewed coordinator, bounded action runner,
      # macOS command adapter and one-shot session as one production
      # configuration. The single Qt OpenGL output implementation is supplied
      # by the always-present tracked surface archive above.
      set(WAM_MACOS_NATIVE_VIDEO_ACTIVATION_SOURCES
        src/qt/native_activation_coordinator.hpp
        src/qt/native_activation_coordinator.cpp
        src/qt/native_video_controller.hpp
        src/qt/native_video_controller.cpp
        src/platform/macos/native_video_action_driver.hpp
        src/platform/macos/native_video_action_driver.mm
        src/platform/macos/native_video_session.hpp
        src/platform/macos/native_video_session.mm)
      add_library(wam_macos_native_video_activation STATIC
        ${WAM_MACOS_NATIVE_VIDEO_ACTIVATION_SOURCES})
      target_include_directories(wam_macos_native_video_activation PUBLIC src)
      target_compile_features(wam_macos_native_video_activation PUBLIC
        cxx_std_20)
      target_compile_definitions(wam_macos_native_video_activation PRIVATE
        GL_SILENCE_DEPRECATION=1)
      target_compile_options(wam_macos_native_video_activation PRIVATE
        "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
        -Wall -Wextra -Wpedantic)
      target_link_libraries(wam_macos_native_video_activation
        PUBLIC
          wam_macos_native_video
          wam_macos_native_qt_tracked
        PRIVATE
          Qt6::Core
          Qt6::Gui
          Qt6::Qml
          Qt6::Quick
          "${WAM_OPENGL_FRAMEWORK}")
      set_target_properties(wam_macos_native_video_activation PROPERTIES
        AUTOMOC ON
        LINKER_LANGUAGE OBJCXX)
      target_link_libraries(wam PRIVATE
        wam_macos_native_video_activation)
      target_compile_definitions(wam PRIVATE
        WAM_HAS_MACOS_NATIVE_VIDEO_ACTIVATION=1)

      if(BUILD_TESTING)
        # Headless closure gate: referencing one symbol from each boundary
        # forces the production-macro archive (including AUTOMOC and the
        # session -> Qt output -> QtGL chain) to resolve without constructing
        # a window or starting a native attempt.
        add_executable(wam_native_video_activation_link_test
          tests/native_video_activation_link_test.mm)
        target_include_directories(
          wam_native_video_activation_link_test PRIVATE src)
        target_link_libraries(wam_native_video_activation_link_test PRIVATE
          wam_macos_native_video_activation)
        target_compile_options(wam_native_video_activation_link_test PRIVATE
          "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
          -Wall -Wextra -Wpedantic)
        set_target_properties(wam_native_video_activation_link_test
          PROPERTIES LINKER_LANGUAGE OBJCXX)
        add_test(NAME macos_native_video_activation_link
          COMMAND wam_native_video_activation_link_test)
        set_tests_properties(macos_native_video_activation_link PROPERTIES
          TIMEOUT 10)
      endif()
    endif()

    # Keep the legacy CAMetalLayer pipeline available to its focused tests and
    # to the separately gated activation seam above. The shipping native owner
    # uses wam_macos_native_session_system plus the tracked OpenGL surface and
    # therefore must not link this dormant Metal archive.
  endif()
endif()

if(WIN32)
  set(WAM_WINDOWS_ICON
    "${CMAKE_CURRENT_SOURCE_DIR}/packaging/windows/wam.ico")
  set(WAM_WINDOWS_ICON_RC "${CMAKE_CURRENT_BINARY_DIR}/wam-icon.rc")
  configure_file(packaging/windows/wam.rc.in "${WAM_WINDOWS_ICON_RC}" @ONLY)
  target_sources(wam PRIVATE "${WAM_WINDOWS_ICON_RC}")
  target_compile_definitions(wam PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
endif()

if(APPLE)
  # ---------------------------------------------------------------------------
  # QuickLook thumbnail extension (WAMThumbnail.appex)
  # ---------------------------------------------------------------------------
  #
  # macOS ships no Matroska demuxer, so Finder shows a generic document icon
  # for .mkv. WAM already owns a complete, Qt-free read path, so it can supply
  # the frame the system cannot produce. (Measured on macOS 26.3: this OS
  # already thumbnails .webm and .ts itself. Those types stay claimed because
  # the same code serves them for free and the 13.3 deployment floor does not
  # have that support; where the system answers, the system wins.) See
  # packaging/quicklook/README.md for the evidence behind every choice here.
  #
  # SELF-CONTAINMENT IS THE DESIGN CONSTRAINT. scripts/bundle_macos_lib.zsh
  # audits every Mach-O under Contents/ -- including a nested appex -- but its
  # install-name repair walk is seeded only from the four top-level payload
  # binaries, so an appex it had to rewrite would hard-fail the release. This
  # target therefore links NOTHING but static archives and system frameworks:
  #
  #   * wam_native_core          -- Qt-free, and declares no link dependencies
  #                                 of its own, so it contributes no dylib edge.
  #   * the two sample builders  -- compiled directly, exactly as
  #     + the codec capability      wam_matroska_preview_source_test does.
  #
  # It deliberately does NOT link wam_macos_native_video_core: that archive
  # carries software_vp8_decoder and therefore a Homebrew PkgConfig::WAM_LIBVPX
  # edge whenever WAM_ENABLE_SOFTWARE_VP8 is ON (which release.yml sets), and
  # that edge is the one thing nothing would rewrite for a nested appex.
  #
  # matroska_sample_builder.mm gates its VP8 branch on a RUNTIME
  # SoftwareVp8Decoder::available() call rather than on the preprocessor, so
  # the symbol is referenced whatever the flags say; wam_thumbnail_frame.mm
  # defines that one function to return false, which is exactly what the
  # production source does when WAM_ENABLE_SOFTWARE_VP8 is undefined. VP8 WebM
  # therefore gets no thumbnail and falls back to Finder's generic icon, like
  # every other unsupported input.
  option(WAM_BUILD_QUICKLOOK_APPEX
    "Build and embed the QuickLook thumbnail extension in WAM.app" ON)

  if(WAM_BUILD_QUICKLOOK_APPEX)
    find_library(WAM_COREGRAPHICS_FRAMEWORK CoreGraphics REQUIRED)
    find_library(WAM_QUICKLOOKTHUMBNAILING_FRAMEWORK QuickLookThumbnailing
      REQUIRED)

    set(WAM_QUICKLOOK_BUNDLE_IDENTIFIER
      "com.wesleymaa.wam.quicklook.thumbnail")
    set(WAM_QUICKLOOK_INFO_PLIST
      "${CMAKE_CURRENT_BINARY_DIR}/WAMThumbnail-Info.plist")
    configure_file(packaging/quicklook/Info.plist
      "${WAM_QUICKLOOK_INFO_PLIST}" @ONLY)

    # The decode pipeline, split out of the Objective-C shim so ctest can
    # drive it. A QuickLook extension is close to untestable in place: it runs
    # in a system-launched sandboxed process whose stderr no test can read.
    set(WAM_QUICKLOOK_FRAME_SOURCES
      packaging/quicklook/wam_thumbnail_frame.hpp
      packaging/quicklook/wam_thumbnail_frame.mm
      src/platform/macos/matroska_sample_builder.hpp
      src/platform/macos/matroska_sample_builder.mm
      src/platform/macos/mpegts_sample_builder.hpp
      src/platform/macos/mpegts_sample_builder.mm
      src/platform/macos/native_video_codec_capability.hpp
      src/platform/macos/native_video_codec_capability.mm)

    add_executable(wam_quicklook_thumbnail MACOSX_BUNDLE
      packaging/quicklook/WAMThumbnailProvider.mm
      ${WAM_QUICKLOOK_FRAME_SOURCES})
    set_target_properties(wam_quicklook_thumbnail PROPERTIES
      OUTPUT_NAME "WAMThumbnail"
      BUNDLE TRUE
      BUNDLE_EXTENSION "appex"
      LINKER_LANGUAGE OBJCXX
      MACOSX_BUNDLE_INFO_PLIST "${WAM_QUICKLOOK_INFO_PLIST}"
      # Nothing here is a QObject and nothing may reach Qt tooling; the global
      # AUTOMOC would otherwise add a moc dependency to a target whose whole
      # point is that it does not know Qt exists.
      AUTOMOC OFF
      AUTOUIC OFF
      AUTORCC OFF
      # No BUILD_RPATH/INSTALL_RPATH on purpose. This binary resolves nothing
      # outside /usr/lib and /System, so it needs no rpath at all; adding the
      # (correct) four-level @loader_path/../../../../Frameworks would only
      # invite a future dylib edge that the repair walk still would not fix.
      XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES)
    target_include_directories(wam_quicklook_thumbnail PRIVATE src)
    target_compile_features(wam_quicklook_thumbnail PRIVATE cxx_std_20)
    target_compile_options(wam_quicklook_thumbnail PRIVATE
      "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
      -Wall -Wextra -Wpedantic)
    target_link_libraries(wam_quicklook_thumbnail PRIVATE
      wam_native_core
      "${WAM_COREFOUNDATION_FRAMEWORK}"
      "${WAM_COREGRAPHICS_FRAMEWORK}"
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_COREVIDEO_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_QUICKLOOKTHUMBNAILING_FRAMEWORK}"
      "${WAM_VIDEOTOOLBOX_FRAMEWORK}")
    # An app extension's entry point is NSExtensionMain, not main().
    target_link_options(wam_quicklook_thumbnail PRIVATE
      "LINKER:-e,_NSExtensionMain")

    # Dev convenience: keep the appex inside the just-built WAM.app so a local
    # `lsregister -f build/WAM.app` picks it up without running the installer.
    # The staged/release copy comes from the install() rule below.
    #
    # The copy hangs off `wam`, not off the appex, so the ordering edge points
    # appex -> wam and the appex stays buildable on its own when the Qt half of
    # the tree is mid-edit.
    add_dependencies(wam wam_quicklook_thumbnail)
    add_custom_command(TARGET wam POST_BUILD
      COMMAND "${CMAKE_COMMAND}" -E make_directory
        "$<TARGET_BUNDLE_DIR:wam>/Contents/PlugIns"
      COMMAND "${CMAKE_COMMAND}" -E rm -rf
        "$<TARGET_BUNDLE_DIR:wam>/Contents/PlugIns/WAMThumbnail.appex"
      COMMAND "${CMAKE_COMMAND}" -E copy_directory
        "$<TARGET_BUNDLE_DIR:wam_quicklook_thumbnail>"
        "$<TARGET_BUNDLE_DIR:wam>/Contents/PlugIns/WAMThumbnail.appex"
      VERBATIM)

    if(BUILD_TESTING)
      find_library(WAM_IMAGEIO_FRAMEWORK ImageIO REQUIRED)
      add_executable(wam_quicklook_thumbnail_frame_test
        tests/quicklook_thumbnail_frame_test.mm
        ${WAM_QUICKLOOK_FRAME_SOURCES})
      set_target_properties(wam_quicklook_thumbnail_frame_test PROPERTIES
        LINKER_LANGUAGE OBJCXX
        AUTOMOC OFF AUTOUIC OFF AUTORCC OFF)
      target_include_directories(wam_quicklook_thumbnail_frame_test PRIVATE
        src "${CMAKE_CURRENT_SOURCE_DIR}")
      target_compile_features(wam_quicklook_thumbnail_frame_test PRIVATE
        cxx_std_20)
      target_compile_options(wam_quicklook_thumbnail_frame_test PRIVATE
        "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
        -Wall -Wextra -Wpedantic)
      target_link_libraries(wam_quicklook_thumbnail_frame_test PRIVATE
        wam_native_core
        "${WAM_COREFOUNDATION_FRAMEWORK}"
        "${WAM_COREGRAPHICS_FRAMEWORK}"
        "${WAM_COREMEDIA_FRAMEWORK}"
        "${WAM_COREVIDEO_FRAMEWORK}"
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_IMAGEIO_FRAMEWORK}"
        "${WAM_VIDEOTOOLBOX_FRAMEWORK}")
      # No media fixture in the tree is a Matroska or transport stream, so the
      # argument-free run is a contract check: a missing file must fail closed
      # with a reason rather than crashing, hanging, or handing back a frame.
      add_test(NAME macos_quicklook_thumbnail_frame
        COMMAND wam_quicklook_thumbnail_frame_test)
      set_tests_properties(macos_quicklook_thumbnail_frame PROPERTIES
        TIMEOUT 30)
    endif()
  endif()
endif()

install(TARGETS wam
  BUNDLE DESTINATION .
  RUNTIME DESTINATION bin)

# Use Qt's supported deployment API so each installed artifact contains the
# platform plugins, linked Qt libraries, and recursively discovered QML imports
# needed to launch without a developer Qt installation.
qt_generate_deploy_qml_app_script(
  TARGET wam
  OUTPUT_SCRIPT wam_qml_deploy_script
  NO_TRANSLATIONS)
install(SCRIPT ${wam_qml_deploy_script})

# Deliberately AFTER the Qt deploy script: macdeployqt walks Contents/PlugIns
# looking for Qt plugins to repair, and the appex is not one. Installing it
# afterwards keeps it out of that pass entirely. It needs no repair anyway --
# it links only static archives and system frameworks.
if(APPLE AND WAM_BUILD_QUICKLOOK_APPEX)
  install(TARGETS wam_quicklook_thumbnail
    BUNDLE DESTINATION "WAM.app/Contents/PlugIns")
endif()

install(FILES README.md THIRD_PARTY_NOTICES.md DESTINATION share/doc/wam)

if(BUILD_TESTING)
  if(APPLE)
    add_test(NAME macos_bundle_lazy_mpv_transaction
      COMMAND /bin/zsh
        "${CMAKE_CURRENT_SOURCE_DIR}/tests/bundle_macos_lazy_mpv_seed_test.zsh")
    set_tests_properties(macos_bundle_lazy_mpv_transaction PROPERTIES
      TIMEOUT 120)
    add_test(NAME macos_release_notarize_transaction
      COMMAND /bin/zsh
        "${CMAKE_CURRENT_SOURCE_DIR}/tests/release_macos_notarize_test.zsh")
    set_tests_properties(macos_release_notarize_transaction PROPERTIES
      TIMEOUT 90)
  endif()
  add_test(NAME msys2_pkgconfig_paths
    COMMAND ${CMAKE_COMMAND} -P
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/cmake/msys2_pkgconfig_paths_test.cmake)

  if(APPLE)
    add_executable(wam_native_media_source_test
      tests/native_media_source_test.cpp)
    target_link_libraries(
      wam_native_media_source_test PRIVATE wam_native_core)
    add_test(NAME native_media_source COMMAND wam_native_media_source_test)

    add_executable(wam_native_media_backend_test
      tests/native_media_backend_test.cpp)
    target_link_libraries(
      wam_native_media_backend_test PRIVATE wam_native_core)
    add_test(NAME native_media_backend COMMAND wam_native_media_backend_test)

    add_executable(wam_matroska_ebml_test
      tests/matroska_ebml_test.cpp)
    target_link_libraries(wam_matroska_ebml_test PRIVATE wam_native_core)
    add_test(NAME matroska_ebml COMMAND wam_matroska_ebml_test)

    add_executable(wam_subtitle_text_test
      tests/subtitle_text_test.cpp)
    target_link_libraries(wam_subtitle_text_test PRIVATE wam_native_core)
    add_test(NAME subtitle_text COMMAND wam_subtitle_text_test)

    add_executable(wam_matroska_subtitles_test
      tests/matroska_subtitles_test.cpp)
    target_link_libraries(wam_matroska_subtitles_test PRIVATE wam_native_core)
    add_test(NAME matroska_subtitles COMMAND wam_matroska_subtitles_test)

    add_executable(wam_matroska_aac_test
      tests/matroska_aac_test.cpp)
    target_link_libraries(wam_matroska_aac_test PRIVATE wam_native_core)
    add_test(NAME matroska_aac COMMAND wam_matroska_aac_test)

    add_executable(wam_matroska_opus_test
      tests/matroska_opus_test.cpp)
    target_link_libraries(wam_matroska_opus_test PRIVATE wam_native_core)
    add_test(NAME matroska_opus COMMAND wam_matroska_opus_test)

    add_executable(wam_matroska_vorbis_test
      tests/matroska_vorbis_test.cpp)
    target_link_libraries(wam_matroska_vorbis_test PRIVATE wam_native_core)
    add_test(NAME matroska_vorbis COMMAND wam_matroska_vorbis_test)

    add_executable(wam_matroska_ac3_test
      tests/matroska_ac3_test.cpp)
    target_link_libraries(wam_matroska_ac3_test PRIVATE wam_native_core)
    add_test(NAME matroska_ac3 COMMAND wam_matroska_ac3_test)

    add_executable(wam_audio_downmix_test
      tests/audio_downmix_test.cpp)
    target_link_libraries(wam_audio_downmix_test PRIVATE wam_native_core)
    add_test(NAME audio_downmix COMMAND wam_audio_downmix_test)

    add_executable(wam_matroska_flac_test
      tests/matroska_flac_test.cpp)
    target_link_libraries(wam_matroska_flac_test PRIVATE wam_native_core)
    add_test(NAME matroska_flac COMMAND wam_matroska_flac_test)

    add_executable(wam_matroska_mpeg_audio_test
      tests/matroska_mpeg_audio_test.cpp)
    target_link_libraries(wam_matroska_mpeg_audio_test PRIVATE wam_native_core)
    add_test(NAME matroska_mpeg_audio COMMAND wam_matroska_mpeg_audio_test)

    add_executable(wam_matroska_demuxer_test
      tests/matroska_demuxer_test.cpp)
    target_link_libraries(wam_matroska_demuxer_test PRIVATE wam_native_core)
    add_test(NAME matroska_demuxer COMMAND wam_matroska_demuxer_test)

    add_executable(wam_mpegts_demuxer_test
      tests/mpegts_demuxer_test.cpp)
    target_link_libraries(wam_mpegts_demuxer_test PRIVATE wam_native_core)
    add_test(NAME mpegts_demuxer COMMAND wam_mpegts_demuxer_test)

    # Regime microbenchmarks for the demuxer. EXCLUDE_FROM_ALL keeps it off the
    # default build; the ctest entry carries the `benchmark` label so it never
    # enters the required-test regex, which names tests explicitly.
    add_executable(wam_matroska_demuxer_bench EXCLUDE_FROM_ALL
      benchmarks/matroska_demuxer_bench.cpp)
    target_link_libraries(wam_matroska_demuxer_bench PRIVATE wam_native_core)
    target_compile_features(wam_matroska_demuxer_bench PRIVATE cxx_std_20)
    target_compile_options(wam_matroska_demuxer_bench PRIVATE
      -Wall -Wextra -Wpedantic)
    add_test(NAME matroska_demuxer_bench
      COMMAND wam_matroska_demuxer_bench --quick)
    set_tests_properties(matroska_demuxer_bench PROPERTIES
      LABELS benchmark TIMEOUT 600 DISABLED FALSE)

    add_executable(wam_video_codec_configuration_test
      tests/video_codec_configuration_test.cpp)
    target_link_libraries(
      wam_video_codec_configuration_test PRIVATE wam_native_core)
    add_test(NAME video_codec_configuration
      COMMAND wam_video_codec_configuration_test)

    add_executable(wam_native_playback_contract_test
      tests/native_playback_contract_test.cpp)
    target_link_libraries(
      wam_native_playback_contract_test PRIVATE wam_native_core)
    add_test(NAME native_playback_contract
      COMMAND wam_native_playback_contract_test)

    add_executable(wam_native_media_dispatcher_test
      tests/native_media_dispatcher_test.cpp)
    target_link_libraries(
      wam_native_media_dispatcher_test PRIVATE wam_native_core)
    add_test(NAME native_media_dispatcher
      COMMAND wam_native_media_dispatcher_test)

    add_executable(wam_playback_router_test
      tests/playback_router_test.cpp)
    target_link_libraries(wam_playback_router_test PRIVATE wam_native_core)
    add_test(NAME playback_router COMMAND wam_playback_router_test)

    # The clock's bounded publication-token domain is a compile-time test
    # seam; compile a complete private implementation rather than mixing it
    # with the production wam_native_core object.
    add_executable(wam_native_media_clock_test
      tests/native_media_clock_test.cpp
      src/platform/macos/native_media_clock.hpp
      src/platform/macos/native_media_clock.cpp)
    target_include_directories(wam_native_media_clock_test PRIVATE src)
    target_compile_definitions(wam_native_media_clock_test PRIVATE
      WAM_NATIVE_MEDIA_CLOCK_TESTING=1)
    add_test(NAME native_media_clock COMMAND wam_native_media_clock_test)

    add_executable(wam_native_pcm_ring_test
      tests/native_pcm_ring_test.cpp)
    target_link_libraries(wam_native_pcm_ring_test PRIVATE wam_native_core)
    add_test(NAME native_pcm_ring COMMAND wam_native_pcm_ring_test)

    add_executable(wam_native_audio_render_core_test
      tests/native_audio_render_core_test.cpp)
    target_link_libraries(
      wam_native_audio_render_core_test PRIVATE wam_native_core)
    add_test(NAME native_audio_render_core
      COMMAND wam_native_audio_render_core_test)

    foreach(WAM_NATIVE_CORE_TEST_TARGET IN ITEMS
        wam_matroska_aac_test
        wam_matroska_ebml_test
        wam_subtitle_text_test
        wam_matroska_subtitles_test
        wam_matroska_opus_test
        wam_matroska_vorbis_test
        wam_matroska_ac3_test
        wam_audio_downmix_test
        wam_matroska_flac_test
        wam_matroska_mpeg_audio_test
        wam_matroska_demuxer_test
        wam_mpegts_demuxer_test
        wam_video_codec_configuration_test
        wam_native_media_source_test
        wam_native_media_backend_test
        wam_native_playback_contract_test
        wam_native_media_dispatcher_test
        wam_playback_router_test
        wam_native_media_clock_test
        wam_native_pcm_ring_test
        wam_native_audio_render_core_test)
      target_compile_features(${WAM_NATIVE_CORE_TEST_TARGET} PRIVATE
        cxx_std_20)
      target_compile_options(${WAM_NATIVE_CORE_TEST_TARGET} PRIVATE
        -Wall -Wextra -Wpedantic)
    endforeach()
    set_tests_properties(
      matroska_aac
      matroska_ebml
      subtitle_text
      matroska_subtitles
      matroska_opus
      matroska_vorbis
      matroska_ac3
      audio_downmix
      matroska_flac
      matroska_mpeg_audio
      matroska_demuxer
      mpegts_demuxer
      video_codec_configuration
      native_media_source
      native_media_backend
      native_playback_contract
      native_media_dispatcher
      playback_router
      native_media_clock
      native_pcm_ring
      native_audio_render_core
      PROPERTIES TIMEOUT 10)
  endif()

  add_executable(wam_playback_policy_test tests/playback_policy_test.cpp)
  target_include_directories(wam_playback_policy_test PRIVATE src)
  add_test(NAME playback_policy COMMAND wam_playback_policy_test)

  add_executable(wam_mpv_hwdec_interop_policy_test
    tests/mpv_hwdec_interop_policy_test.cpp
    src/qt/mpv_hwdec_interop_policy.hpp)
  target_include_directories(wam_mpv_hwdec_interop_policy_test PRIVATE src)
  add_test(NAME mpv_hwdec_interop_policy
    COMMAND wam_mpv_hwdec_interop_policy_test)

  add_executable(wam_jobs_test tests/jobs_test.cpp src/jobs.cpp src/jobs.hpp)
  target_include_directories(wam_jobs_test PRIVATE src)
  add_test(NAME jobs COMMAND wam_jobs_test)

  add_executable(wam_state_test
    tests/state_store_test.cpp src/state_store.cpp src/state_store.hpp)
  target_include_directories(wam_state_test PRIVATE src)
  add_test(NAME state_store COMMAND wam_state_test)

  # The pointer-scroll gesture model links no Qt at all, which is exactly why
  # it is its own translation unit: normalization, axis lock and the 100%
  # detent are decided there and proved here without a GUI.
  add_executable(wam_scroll_gesture_test
    tests/scroll_gesture_test.cpp
    src/qt/scroll_gesture.cpp
    src/qt/scroll_gesture.hpp)
  target_include_directories(wam_scroll_gesture_test PRIVATE src)
  target_compile_features(wam_scroll_gesture_test PRIVATE cxx_std_20)
  target_compile_options(wam_scroll_gesture_test PRIVATE
    -Wall -Wextra -Wpedantic)
  add_test(NAME scroll_gesture COMMAND wam_scroll_gesture_test)

  add_executable(wam_caption_test
    tests/caption_service_test.cpp
    src/caption_service.cpp
    src/caption_service.hpp
    src/jobs.cpp
    src/jobs.hpp)
  target_include_directories(wam_caption_test PRIVATE src)
  add_test(NAME caption_service COMMAND wam_caption_test)

  add_executable(wam_player_controller_lazy_test
    tests/player_controller_lazy_test.cpp
    src/playback/mpv/mpv_api.cpp
    src/playback/mpv/mpv_runtime_common.cpp
    src/qt/player_controller.cpp
    src/qt/player_controller.hpp
    src/qt/subtitle_sources.cpp
    src/qt/subtitle_sources.hpp
    src/media/subtitle_text.cpp
    src/media/matroska_subtitles.cpp
    src/media/matroska_ebml.cpp
    src/qt/scroll_gesture.cpp
    src/qt/scroll_gesture.hpp
    src/qt/player_core.cpp
    src/qt/player_core_p.hpp
    src/jobs.cpp
    src/jobs.hpp
    src/caption_service.cpp
    src/caption_service.hpp)
  target_include_directories(wam_player_controller_lazy_test PRIVATE src)
  target_compile_definitions(wam_player_controller_lazy_test PRIVATE
    WAM_MPV_RUNTIME_TESTING=1)
  target_link_libraries(wam_player_controller_lazy_test PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Quick
    Qt6::OpenGL
    ${WAM_MPV_INTEGRATION_TEST_TARGET})
  add_test(NAME player_controller_lazy COMMAND wam_player_controller_lazy_test)
  set_tests_properties(player_controller_lazy PROPERTIES TIMEOUT 20)

  add_executable(wam_player_core_render_context_permission_test
    tests/player_core_render_context_permission_test.cpp
    src/playback/mpv/mpv_api.cpp
    src/playback/mpv/mpv_runtime_common.cpp
    src/qt/player_controller.cpp
    src/qt/player_controller.hpp
    src/qt/subtitle_sources.cpp
    src/qt/subtitle_sources.hpp
    src/media/subtitle_text.cpp
    src/media/matroska_subtitles.cpp
    src/media/matroska_ebml.cpp
    src/qt/scroll_gesture.cpp
    src/qt/scroll_gesture.hpp
    src/qt/player_core.cpp
    src/qt/player_core_p.hpp
    src/qt/render_lifecycle.hpp
    src/qt/mpv_render_context_policy.hpp
    src/jobs.cpp
    src/jobs.hpp
    src/caption_service.cpp
    src/caption_service.hpp)
  target_include_directories(
    wam_player_core_render_context_permission_test PRIVATE src)
  target_compile_definitions(
    wam_player_core_render_context_permission_test PRIVATE
    WAM_MPV_RUNTIME_TESTING=1
    WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING=1)
  target_link_libraries(wam_player_core_render_context_permission_test PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Quick
    Qt6::OpenGL
    ${WAM_MPV_INTEGRATION_TEST_TARGET})
  add_test(NAME player_core_render_context_permission
    COMMAND wam_player_core_render_context_permission_test)
  set_tests_properties(player_core_render_context_permission PROPERTIES
    TIMEOUT 30)
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set_tests_properties(player_core_render_context_permission PROPERTIES
      ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
  endif()

  add_executable(wam_render_lifecycle_test
    tests/render_lifecycle_test.cpp
    src/qt/render_lifecycle.hpp)
  target_include_directories(wam_render_lifecycle_test PRIVATE src)
  add_test(NAME render_lifecycle COMMAND wam_render_lifecycle_test)

  add_executable(wam_native_activation_coordinator_test
    tests/native_activation_coordinator_test.cpp
    src/qt/native_activation_coordinator.cpp
    src/qt/native_activation_coordinator.hpp)
  target_include_directories(
    wam_native_activation_coordinator_test PRIVATE src)
  add_test(NAME native_activation_coordinator
    COMMAND wam_native_activation_coordinator_test)
  set_tests_properties(native_activation_coordinator PROPERTIES TIMEOUT 10)

  # Pure capacity-one action runner. This target is test-only; the default
  # application omits the activation seam, and the opt-in application still
  # does not construct or begin it.
  add_executable(wam_native_video_controller_test
    tests/native_video_controller_test.cpp
    src/qt/native_video_controller.cpp
    src/qt/native_video_controller.hpp
    src/qt/native_activation_coordinator.cpp
    src/qt/native_activation_coordinator.hpp)
  target_include_directories(wam_native_video_controller_test PRIVATE src)
  target_compile_options(wam_native_video_controller_test PRIVATE
    -Wall -Wextra -Wpedantic)
  add_test(NAME native_video_controller
    COMMAND wam_native_video_controller_test)
  set_tests_properties(native_video_controller PROPERTIES TIMEOUT 10)

  find_program(WAM_FFMPEG_EXECUTABLE ffmpeg)
  find_program(WAM_FFPROBE_EXECUTABLE ffprobe)
  if(WAM_FFMPEG_EXECUTABLE AND WAM_FFPROBE_EXECUTABLE)
    add_executable(wam_export_integration_test
      tests/export_integration_test.cpp src/jobs.cpp src/jobs.hpp)
    target_include_directories(wam_export_integration_test PRIVATE src)
    add_test(NAME export_duration COMMAND wam_export_integration_test
      "${WAM_FFMPEG_EXECUTABLE}" "${WAM_FFPROBE_EXECUTABLE}")
  endif()

  if(APPLE)
    string(REPLACE "." "\\." WAM_MACOS_DEPLOYMENT_TARGET_REGEX
      "${CMAKE_OSX_DEPLOYMENT_TARGET}")
    add_test(NAME macos_deployment_target
      COMMAND /usr/bin/otool -l "$<TARGET_FILE:wam>")
    set_tests_properties(macos_deployment_target PROPERTIES
      PASS_REGULAR_EXPRESSION
        "minos ${WAM_MACOS_DEPLOYMENT_TARGET_REGEX}")

    # Structural, unshown-window gate for the one native child owned by the
    # macOS stage. Compile the same controller/core closure as production so
    # MpvVideoItem is never tested against placeholder method definitions.
    add_executable(wam_mpv_video_item_native_host_test
      tests/mpv_video_item_native_host_test.cpp
      src/qt/mpv_video_item.cpp
      src/qt/mpv_video_item.hpp
      src/qt/player_controller.cpp
      src/qt/player_controller.hpp
      src/qt/subtitle_sources.cpp
      src/qt/subtitle_sources.hpp
      src/media/subtitle_text.cpp
      src/media/matroska_subtitles.cpp
      src/media/matroska_ebml.cpp
      src/qt/scroll_gesture.cpp
      src/qt/scroll_gesture.hpp
      src/qt/player_core.cpp
      src/qt/player_core_p.hpp
      src/jobs.cpp
      src/jobs.hpp
      src/caption_service.cpp
      src/caption_service.hpp)
    target_include_directories(wam_mpv_video_item_native_host_test PRIVATE
      src src/qt)
    target_compile_features(wam_mpv_video_item_native_host_test PRIVATE
      cxx_std_20)
    target_compile_options(wam_mpv_video_item_native_host_test PRIVATE
      -Wall -Wextra -Wpedantic)
    target_link_libraries(wam_mpv_video_item_native_host_test PRIVATE
      wam_mpv_runtime
      wam_macos_native_qt_tracked
      Qt6::Core
      Qt6::Gui
      Qt6::Qml
      Qt6::Quick
      Qt6::OpenGL)
    set_target_properties(wam_mpv_video_item_native_host_test PROPERTIES
      AUTOMOC ON
      LINKER_LANGUAGE OBJCXX)
    add_test(NAME macos_mpv_video_item_native_host
      COMMAND wam_mpv_video_item_native_host_test)
    set_tests_properties(macos_mpv_video_item_native_host PROPERTIES
      TIMEOUT 20)

    if(WAM_ENABLE_MACOS_NATIVE_VIDEO)
      # Fixture-free gates with test-only declarations compile their complete
      # macro-bearing implementations privately. Production-layout contract
      # gates may link the production archive directly.
      add_executable(wam_avfoundation_media_source_test
        tests/avfoundation_media_source_test.mm
        src/platform/macos/avfoundation_asset_context.hpp
        src/platform/macos/avfoundation_asset_context.mm
        src/platform/macos/avfoundation_media_source.hpp
        src/platform/macos/avfoundation_media_source.mm
        src/platform/macos/native_video_codec_capability.hpp
        src/platform/macos/native_video_codec_capability.mm)
      target_include_directories(
        wam_avfoundation_media_source_test PRIVATE src)
      target_compile_definitions(wam_avfoundation_media_source_test PRIVATE
        WAM_AVFOUNDATION_MEDIA_SOURCE_TESTING=1)
      target_link_libraries(wam_avfoundation_media_source_test PRIVATE
        wam_native_core
        "${WAM_COREFOUNDATION_FRAMEWORK}"
        "${WAM_COREGRAPHICS_FRAMEWORK}"
        "${WAM_COREMEDIA_FRAMEWORK}"
        "${WAM_COREVIDEO_FRAMEWORK}"
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
        "${WAM_AVFOUNDATION_FRAMEWORK}"
        "${WAM_VIDEOTOOLBOX_FRAMEWORK}")
      add_test(NAME macos_avfoundation_media_source
        COMMAND wam_avfoundation_media_source_test)
      set_tests_properties(macos_avfoundation_media_source PROPERTIES
        TIMEOUT 30)

      add_executable(wam_avfoundation_preview_source_test
        tests/avfoundation_preview_source_test.mm
        src/platform/macos/avfoundation_asset_context.hpp
        src/platform/macos/avfoundation_asset_context.mm
        src/platform/macos/avfoundation_preview_source.hpp
        src/platform/macos/avfoundation_preview_source.mm)
      target_include_directories(
        wam_avfoundation_preview_source_test PRIVATE src)
      target_compile_definitions(
        wam_avfoundation_preview_source_test PRIVATE
        WAM_AVFOUNDATION_PREVIEW_SOURCE_TESTING=1)
      target_link_libraries(wam_avfoundation_preview_source_test PRIVATE
        wam_native_core
        "${WAM_COREFOUNDATION_FRAMEWORK}"
        "${WAM_COREGRAPHICS_FRAMEWORK}"
        "${WAM_COREMEDIA_FRAMEWORK}"
        "${WAM_COREVIDEO_FRAMEWORK}"
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_AVFOUNDATION_FRAMEWORK}")
      add_test(NAME macos_avfoundation_preview_source
        COMMAND wam_avfoundation_preview_source_test)
      set_tests_properties(macos_avfoundation_preview_source PROPERTIES
        TIMEOUT 30)

      add_executable(wam_native_audio_converter_test
        tests/native_audio_converter_test.mm
        src/platform/macos/native_audio_converter.hpp
        src/platform/macos/native_audio_converter.mm)
      target_include_directories(wam_native_audio_converter_test PRIVATE src)
      target_link_libraries(wam_native_audio_converter_test PRIVATE
        wam_native_core
        "${WAM_COREFOUNDATION_FRAMEWORK}"
        "${WAM_COREMEDIA_FRAMEWORK}"
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_AUDIOTOOLBOX_FRAMEWORK}")
      add_test(NAME macos_native_audio_converter
        COMMAND wam_native_audio_converter_test)
      set_tests_properties(macos_native_audio_converter PROPERTIES
        TIMEOUT 20)

      # New Opus behaviour lives alongside the frozen converter contract
      # rather than inside it.
      add_executable(wam_native_audio_converter_opus_test
        tests/native_audio_converter_opus_test.mm
        src/platform/macos/native_audio_converter.hpp
        src/platform/macos/native_audio_converter.mm)
      target_include_directories(wam_native_audio_converter_opus_test
        PRIVATE src)
      target_link_libraries(wam_native_audio_converter_opus_test PRIVATE
        wam_native_core
        "${WAM_COREFOUNDATION_FRAMEWORK}"
        "${WAM_COREMEDIA_FRAMEWORK}"
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_AUDIOTOOLBOX_FRAMEWORK}")
      add_test(NAME macos_native_audio_converter_opus
        COMMAND wam_native_audio_converter_opus_test)
      set_tests_properties(macos_native_audio_converter_opus PROPERTIES
        TIMEOUT 20)

      add_executable(wam_native_audio_channel_map_test
        tests/native_audio_channel_map_test.mm
        src/platform/macos/native_audio_channel_map.hpp)
      target_include_directories(wam_native_audio_channel_map_test
        PRIVATE src)
      target_link_libraries(wam_native_audio_channel_map_test PRIVATE
        wam_native_core
        "${WAM_COREFOUNDATION_FRAMEWORK}"
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
        "${WAM_COREAUDIO_FRAMEWORK}")
      add_test(NAME macos_native_audio_channel_map
        COMMAND wam_native_audio_channel_map_test)
      set_tests_properties(macos_native_audio_channel_map PROPERTIES
        TIMEOUT 20)

      add_executable(wam_native_audio_stretch_stage_test
        tests/native_audio_stretch_stage_test.mm
        src/platform/macos/native_audio_stretch_stage.hpp
        src/platform/macos/native_audio_stretch_stage.mm)
      target_include_directories(wam_native_audio_stretch_stage_test
        PRIVATE src)
      target_link_libraries(wam_native_audio_stretch_stage_test PRIVATE
        wam_native_core
        "${WAM_COREMEDIA_FRAMEWORK}"
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
        "${WAM_COREAUDIO_FRAMEWORK}")
      add_test(NAME macos_native_audio_stretch_stage
        COMMAND wam_native_audio_stretch_stage_test)
      set_tests_properties(macos_native_audio_stretch_stage PROPERTIES
        TIMEOUT 60)

      add_executable(wam_native_audio_output_test
        tests/native_audio_output_test.mm
        src/platform/macos/native_audio_output.hpp
        src/platform/macos/native_audio_output.mm
        src/platform/macos/native_audio_stretch_stage.hpp
        src/platform/macos/native_audio_stretch_stage.mm)
      target_include_directories(wam_native_audio_output_test PRIVATE src)
      target_link_libraries(wam_native_audio_output_test PRIVATE
        wam_native_core
        "${WAM_COREMEDIA_FRAMEWORK}"
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
        "${WAM_COREAUDIO_FRAMEWORK}")
      add_test(NAME macos_native_audio_output
        COMMAND wam_native_audio_output_test)
      set_tests_properties(macos_native_audio_output PROPERTIES TIMEOUT 30)

      add_executable(wam_native_surface_budget_test
        tests/native_surface_budget_test.mm
        src/platform/macos/native_surface_budget.hpp
        src/platform/macos/native_surface_budget.mm)
      target_include_directories(wam_native_surface_budget_test PRIVATE src)
      target_compile_definitions(wam_native_surface_budget_test PRIVATE
        WAM_NATIVE_SURFACE_BUDGET_TESTING=1)
      target_link_libraries(wam_native_surface_budget_test PRIVATE
        "${WAM_COREFOUNDATION_FRAMEWORK}"
        "${WAM_COREVIDEO_FRAMEWORK}"
        "${WAM_IOSURFACE_FRAMEWORK}")
      add_test(NAME macos_native_surface_budget
        COMMAND wam_native_surface_budget_test)
      set_tests_properties(macos_native_surface_budget PROPERTIES TIMEOUT 20)

      # The multi-window resource envelope: one cap, every derived bound.
      # Deliberately a separate target from the budget suite above so the
      # derived constants are checked from a translation unit that does not
      # derive them.
      add_executable(wam_native_concurrency_limits_test
        tests/native_concurrency_limits_test.cpp
        src/platform/macos/native_concurrency_limits.hpp
        src/platform/macos/native_layer_presentation_state.hpp
        src/platform/macos/native_surface_budget.hpp)
      target_include_directories(wam_native_concurrency_limits_test
        PRIVATE src)
      target_link_libraries(wam_native_concurrency_limits_test PRIVATE
        "${WAM_COREVIDEO_FRAMEWORK}")
      add_test(NAME macos_native_concurrency_limits
        COMMAND wam_native_concurrency_limits_test)
      set_tests_properties(macos_native_concurrency_limits
        PROPERTIES TIMEOUT 20)

      # The libvpx VP8 decode stage: bounded pool, I420 -> NV12 conversion,
      # stage lifecycle, and the once-per-open lane selection. Fixture-free --
      # the decode arm encodes its own VP8 stream with libvpx.
      if(WAM_ENABLE_SOFTWARE_VP8)
        add_executable(wam_software_vp8_test
          tests/software_vp8_test.mm
          src/platform/macos/software_vp8_decoder.hpp
          src/platform/macos/software_vp8_decoder.mm
          src/platform/macos/video_decode_lane.hpp
          src/platform/macos/native_surface_budget.hpp
          src/platform/macos/native_surface_budget.mm
          src/platform/macos/native_video_presenter.hpp
          src/platform/macos/native_video_presenter.mm
          src/platform/macos/native_video_codec_capability.hpp
          src/platform/macos/native_video_codec_capability.mm
          src/platform/macos/video_toolbox_decoder.hpp
          src/platform/macos/video_toolbox_decoder.mm)
        target_include_directories(wam_software_vp8_test PRIVATE src)
        target_compile_definitions(wam_software_vp8_test PRIVATE
          WAM_ENABLE_SOFTWARE_VP8
          WAM_SOFTWARE_VP8_TESTING=1)
        target_link_libraries(wam_software_vp8_test PRIVATE
          PkgConfig::WAM_LIBVPX
          "${WAM_COREFOUNDATION_FRAMEWORK}"
          "${WAM_COREMEDIA_FRAMEWORK}"
          "${WAM_COREVIDEO_FRAMEWORK}"
          "${WAM_FOUNDATION_FRAMEWORK}"
          "${WAM_IOSURFACE_FRAMEWORK}"
          "${WAM_VIDEOTOOLBOX_FRAMEWORK}")
        target_compile_options(wam_software_vp8_test PRIVATE
          "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
          -Wall -Wextra -Wpedantic)
        set_target_properties(wam_software_vp8_test PROPERTIES
          LINKER_LANGUAGE OBJCXX)
        add_test(NAME macos_software_vp8 COMMAND wam_software_vp8_test)
        set_tests_properties(macos_software_vp8 PROPERTIES TIMEOUT 60)
      endif()

      add_executable(wam_native_video_consumer_test
        tests/native_video_consumer_test.mm
        src/platform/macos/native_video_consumer.hpp
        src/platform/macos/native_video_consumer.mm
        src/platform/macos/native_surface_budget.hpp
        src/platform/macos/native_surface_budget.mm
        src/platform/macos/native_video_codec_capability.hpp
        src/platform/macos/native_video_codec_capability.mm
        src/platform/macos/native_video_presenter.hpp
        src/platform/macos/native_video_presenter.mm
        src/platform/macos/video_toolbox_decoder.hpp
        src/platform/macos/video_toolbox_decoder.mm
        src/platform/macos/software_vp8_decoder.hpp
        src/platform/macos/software_vp8_decoder.mm
        src/platform/macos/video_decode_lane.hpp)
      target_include_directories(wam_native_video_consumer_test PRIVATE src)
      target_compile_definitions(wam_native_video_consumer_test PRIVATE
        WAM_NATIVE_VIDEO_CONSUMER_TESTING=1)
      if(WAM_ENABLE_SOFTWARE_VP8)
        target_link_libraries(wam_native_video_consumer_test PRIVATE
          PkgConfig::WAM_LIBVPX)
      endif()
      target_link_libraries(wam_native_video_consumer_test PRIVATE
        wam_native_core
        "${WAM_COREFOUNDATION_FRAMEWORK}"
        "${WAM_COREMEDIA_FRAMEWORK}"
        "${WAM_COREVIDEO_FRAMEWORK}"
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_IOSURFACE_FRAMEWORK}"
        "${WAM_METAL_FRAMEWORK}"
        "${WAM_VIDEOTOOLBOX_FRAMEWORK}")
      add_test(NAME macos_native_video_consumer
        COMMAND wam_native_video_consumer_test)
      set_tests_properties(macos_native_video_consumer PROPERTIES TIMEOUT 30)

      # Layer-presentation contract gate. The presenter is headless by
      # construction -- createTracked(nullptr, ...) builds its own detached
      # AVSampleBufferDisplayLayer, which accepts and acknowledges enqueues
      # without ever joining a view hierarchy -- so it compiles here beside the
      # other fixture-free native gates rather than in the Qt window block.
      # Only the presenter itself is compiled in; FrameLease and the surface
      # budget come from the one production video core.
      add_executable(wam_native_layer_video_output_test
        tests/native_layer_video_output_test.mm
        src/platform/macos/native_layer_video_output.hpp
        src/platform/macos/native_layer_video_output.mm)
      target_include_directories(
        wam_native_layer_video_output_test PRIVATE src)
      target_link_libraries(wam_native_layer_video_output_test PRIVATE
        wam_native_core
        wam_macos_native_video_core
        "${WAM_COREFOUNDATION_FRAMEWORK}"
        "${WAM_COREMEDIA_FRAMEWORK}"
        "${WAM_COREVIDEO_FRAMEWORK}"
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_IOSURFACE_FRAMEWORK}"
        "${WAM_AVFOUNDATION_FRAMEWORK}"
        "${WAM_QUARTZCORE_FRAMEWORK}")
      add_test(NAME macos_native_layer_video_output
        COMMAND wam_native_layer_video_output_test)
      set_tests_properties(macos_native_layer_video_output PROPERTIES
        TIMEOUT 30
        SKIP_RETURN_CODE 77)

      # The arbiter has no test-only class layout. Exercise the single
      # production implementation through the backend archive instead of
      # compiling a second copy into this executable.
      add_executable(wam_native_tracked_video_arbiter_test
        tests/native_tracked_video_arbiter_test.mm)
      target_include_directories(
        wam_native_tracked_video_arbiter_test PRIVATE src)
      target_link_libraries(wam_native_tracked_video_arbiter_test PRIVATE
        wam_macos_native_backend)
      add_test(NAME macos_native_tracked_video_arbiter
        COMMAND wam_native_tracked_video_arbiter_test)
      set_tests_properties(macos_native_tracked_video_arbiter PROPERTIES
        TIMEOUT 20)

      # The Matroska preview source's own contract. It links the main
      # Matroska media source as well, so the promoted sample builders in
      # matroska_sample_builder.hpp are proved to serve both consumers from
      # one definition rather than two copies.
      add_executable(wam_matroska_preview_source_test
        tests/matroska_preview_source_test.mm
        src/platform/macos/matroska_asset_context.hpp
        src/platform/macos/matroska_asset_context.cpp
        src/platform/macos/matroska_media_source.hpp
        src/platform/macos/matroska_media_source.mm
        src/platform/macos/matroska_preview_source.hpp
        src/platform/macos/matroska_preview_source.mm
        src/platform/macos/matroska_sample_builder.hpp
        src/platform/macos/matroska_sample_builder.mm
        # native_preview_source.mm switches exhaustively on backendKind, so
        # every backend's preview implementation is part of this test's link
        # closure whether or not the test exercises it.
        src/platform/macos/mpegts_asset_context.hpp
        src/platform/macos/mpegts_asset_context.cpp
        src/platform/macos/mpegts_preview_source.hpp
        src/platform/macos/mpegts_preview_source.mm
        src/platform/macos/mpegts_sample_builder.hpp
        src/platform/macos/mpegts_sample_builder.mm
        src/platform/macos/avfoundation_asset_context.hpp
        src/platform/macos/avfoundation_asset_context.mm
        src/platform/macos/avfoundation_preview_source.hpp
        src/platform/macos/avfoundation_preview_source.mm
        src/platform/macos/native_preview_source.hpp
        src/platform/macos/native_preview_source.mm)
      target_include_directories(
        wam_matroska_preview_source_test PRIVATE src)
      target_link_libraries(wam_matroska_preview_source_test PRIVATE
        wam_native_core
        wam_macos_native_video_core
        "${WAM_COREMEDIA_FRAMEWORK}"
        "${WAM_COREFOUNDATION_FRAMEWORK}"
        "${WAM_COREGRAPHICS_FRAMEWORK}"
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
        "${WAM_AVFOUNDATION_FRAMEWORK}")
      add_test(NAME macos_matroska_preview_source
        COMMAND wam_matroska_preview_source_test)
      set_tests_properties(macos_matroska_preview_source PROPERTIES
        TIMEOUT 20)

      # The lane's deterministic synthetic-frame seam is absent from the
      # shipping class. Compile the lane and its source dependency privately
      # under one macro, while reusing the production decoder/video core.
      add_executable(wam_native_preview_frame_lane_test
        tests/native_preview_frame_lane_test.mm
        src/platform/macos/avfoundation_asset_context.hpp
        src/platform/macos/avfoundation_asset_context.mm
        src/platform/macos/avfoundation_preview_source.hpp
        src/platform/macos/avfoundation_preview_source.mm
        src/platform/macos/native_preview_frame_lane.hpp
        src/platform/macos/native_preview_frame_lane.mm)
      target_include_directories(
        wam_native_preview_frame_lane_test PRIVATE src)
      target_compile_definitions(
        wam_native_preview_frame_lane_test PRIVATE
        WAM_NATIVE_PREVIEW_FRAME_LANE_TESTING=1)
      target_link_libraries(wam_native_preview_frame_lane_test PRIVATE
        wam_native_core
        wam_macos_native_video_core
        "${WAM_COREGRAPHICS_FRAMEWORK}"
        "${WAM_AVFOUNDATION_FRAMEWORK}")
      add_test(NAME macos_native_preview_frame_lane
        COMMAND wam_native_preview_frame_lane_test)
      set_tests_properties(macos_native_preview_frame_lane PROPERTIES
        TIMEOUT 30)

      # Every implementation in this private closure sees the session test
      # seam, and no production archive containing a differently laid-out
      # NativeMediaSession is linked.
      add_executable(wam_native_media_session_test
        tests/native_media_session_test.mm
        src/media/native_media_source.hpp
        src/media/native_media_source.cpp
        src/media/native_media_dispatcher.hpp
        src/media/native_media_dispatcher.cpp
        src/platform/macos/avfoundation_asset_context.hpp
        src/platform/macos/avfoundation_asset_context.mm
        src/platform/macos/avfoundation_preview_source.hpp
        src/platform/macos/avfoundation_preview_source.mm
        src/platform/macos/matroska_asset_context.hpp
        src/platform/macos/matroska_asset_context.cpp
        src/platform/macos/matroska_preview_source.hpp
        src/platform/macos/matroska_preview_source.mm
        src/platform/macos/matroska_sample_builder.hpp
        src/platform/macos/matroska_sample_builder.mm
        src/platform/macos/mpegts_asset_context.hpp
        src/platform/macos/mpegts_asset_context.cpp
        src/platform/macos/mpegts_preview_source.hpp
        src/platform/macos/mpegts_preview_source.mm
        src/platform/macos/mpegts_sample_builder.hpp
        src/platform/macos/mpegts_sample_builder.mm
        src/platform/macos/native_preview_source.hpp
        src/platform/macos/native_preview_source.mm
        src/platform/macos/native_media_session.hpp
        src/platform/macos/native_media_session.mm
        src/platform/macos/native_media_clock.hpp
        src/platform/macos/native_media_clock.cpp
        src/platform/macos/native_silent_timebase.hpp
        src/platform/macos/native_silent_timebase.cpp
        src/platform/macos/native_preview_frame_lane.hpp
        src/platform/macos/native_preview_frame_lane.mm)
      target_include_directories(wam_native_media_session_test PRIVATE src)
      target_compile_definitions(wam_native_media_session_test PRIVATE
        WAM_AVFOUNDATION_ASSET_CONTEXT_TESTING=1
        WAM_NATIVE_MEDIA_SESSION_TESTING=1)
      target_link_libraries(wam_native_media_session_test PRIVATE
        wam_native_core
        wam_macos_native_video_core
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_COREMEDIA_FRAMEWORK}"
        "${WAM_COREAUDIO_FRAMEWORK}"
        "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
        "${WAM_COREGRAPHICS_FRAMEWORK}"
        "${WAM_AVFOUNDATION_FRAMEWORK}")
      add_test(NAME macos_native_media_session
        COMMAND wam_native_media_session_test)
      set_tests_properties(macos_native_media_session PROPERTIES TIMEOUT 30)

      # Pure route/retirement contract gate. It intentionally links the one
      # production backend archive for exact-position preflight instead of
      # compiling a second NativeMediaSession or NativePlaybackOwner.
      add_executable(wam_native_playback_owner_contract_test
        tests/native_playback_owner_contract_test.cpp)
      target_include_directories(
        wam_native_playback_owner_contract_test PRIVATE src)
      target_link_libraries(wam_native_playback_owner_contract_test PRIVATE
        wam_macos_native_backend)
      add_test(NAME macos_native_playback_owner_contract
        COMMAND wam_native_playback_owner_contract_test)
      set_tests_properties(macos_native_playback_owner_contract PROPERTIES
        TIMEOUT 10)

      add_executable(wam_native_open_preflight_test
        tests/native_open_preflight_test.mm
        src/qt/native_open_preflight.hpp
        src/qt/native_open_preflight.mm)
      target_include_directories(wam_native_open_preflight_test PRIVATE src)
      target_link_libraries(wam_native_open_preflight_test PRIVATE
        wam_macos_native_backend
        Qt6::Core)
      add_test(NAME macos_native_open_preflight
        COMMAND wam_native_open_preflight_test)
      set_tests_properties(macos_native_open_preflight PROPERTIES TIMEOUT 10)

      add_executable(wam_native_benchmark_telemetry_test
        tests/native_benchmark_telemetry_test.cpp
        src/qt/native_benchmark_telemetry.hpp
        src/qt/native_benchmark_telemetry.cpp)
      target_include_directories(
        wam_native_benchmark_telemetry_test PRIVATE src)
      target_compile_definitions(
        wam_native_benchmark_telemetry_test PRIVATE
        WAM_NATIVE_BENCHMARK_TELEMETRY_TESTING=1)
      target_compile_features(
        wam_native_benchmark_telemetry_test PRIVATE cxx_std_20)
      target_compile_options(
        wam_native_benchmark_telemetry_test PRIVATE
        -Wall -Wextra -Wpedantic)
      add_test(NAME macos_native_benchmark_telemetry
        COMMAND wam_native_benchmark_telemetry_test)
      set_tests_properties(macos_native_benchmark_telemetry PROPERTIES
        TIMEOUT 10)

      foreach(WAM_HEADLESS_NATIVE_TEST_TARGET IN ITEMS
          wam_avfoundation_media_source_test
          wam_avfoundation_preview_source_test
          wam_matroska_preview_source_test
          wam_native_audio_converter_test
          wam_native_audio_output_test
          wam_native_audio_stretch_stage_test
          wam_native_surface_budget_test
          wam_native_video_consumer_test
          wam_native_layer_video_output_test
          wam_native_tracked_video_arbiter_test
          wam_native_preview_frame_lane_test
          wam_native_media_session_test
          wam_native_playback_owner_contract_test
          wam_native_open_preflight_test)
        target_compile_features(${WAM_HEADLESS_NATIVE_TEST_TARGET} PRIVATE
          cxx_std_20)
        target_compile_options(${WAM_HEADLESS_NATIVE_TEST_TARGET} PRIVATE
          "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
          -Wall -Wextra -Wpedantic)
        set_target_properties(${WAM_HEADLESS_NATIVE_TEST_TARGET} PROPERTIES
          LINKER_LANGUAGE OBJCXX)
      endforeach()

      add_executable(wam_native_video_test
        tests/native_video_presenter_test.mm
        src/platform/macos/native_video_presenter.hpp
        src/platform/macos/native_video_presenter.mm
        ${WAM_MACOS_NATIVE_VIDEO_METAL_MAPPER_SOURCES})
      target_include_directories(wam_native_video_test PRIVATE src)
      target_compile_definitions(wam_native_video_test PRIVATE
        WAM_NATIVE_FRAME_LEASE_TESTING=1
        WAM_NATIVE_SURFACE_BUDGET_TESTING=1
        WAM_METAL_LAYER_PRESENTER_TESTING=1)
      target_link_libraries(wam_native_video_test PRIVATE
        "${WAM_COREFOUNDATION_FRAMEWORK}"
        "${WAM_COREMEDIA_FRAMEWORK}"
        "${WAM_COREVIDEO_FRAMEWORK}"
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_IOSURFACE_FRAMEWORK}"
        "${WAM_APPKIT_FRAMEWORK}"
        "${WAM_METAL_FRAMEWORK}"
        "${WAM_QUARTZCORE_FRAMEWORK}")
      target_compile_options(wam_native_video_test PRIVATE
        "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
        -Wall -Wextra -Wpedantic)
      set_target_properties(wam_native_video_test PROPERTIES
        LINKER_LANGUAGE OBJCXX)
      add_test(NAME macos_native_video COMMAND wam_native_video_test)
      set_tests_properties(macos_native_video PROPERTIES SKIP_RETURN_CODE 77)

      # Isolated activation gate for a future integrated Qt Quick Metal path.
      # The shipping executable deliberately remains OpenGL/libmpv. Invoke qsb
      # explicitly so the build can select Xcode's optional Metal toolchain,
      # propagate WAM's deployment floor, and inspect every embedded metallib.
      find_package(Qt6ShaderToolsTools 6.11 REQUIRED CONFIG)
      set(WAM_NATIVE_VIDEO_SHADER_BUILD_DIR
        "${CMAKE_CURRENT_BINARY_DIR}/native-video-shaders")
      set(WAM_NATIVE_VIDEO_QSB_FILES)
      foreach(WAM_NATIVE_VIDEO_SHADER IN ITEMS
          native_video.vert native_video.frag)
        set(WAM_NATIVE_VIDEO_SHADER_SOURCE
          "${CMAKE_CURRENT_SOURCE_DIR}/src/platform/macos/shaders/${WAM_NATIVE_VIDEO_SHADER}")
        set(WAM_NATIVE_VIDEO_SHADER_QSB
          "${WAM_NATIVE_VIDEO_SHADER_BUILD_DIR}/${WAM_NATIVE_VIDEO_SHADER}.qsb")
        add_custom_command(
          OUTPUT "${WAM_NATIVE_VIDEO_SHADER_QSB}"
          COMMAND ${CMAKE_COMMAND}
            "-DQSB_EXECUTABLE=$<TARGET_FILE:Qt6::qsb>"
            "-DINPUT=${WAM_NATIVE_VIDEO_SHADER_SOURCE}"
            "-DOUTPUT=${WAM_NATIVE_VIDEO_SHADER_QSB}"
            "-DDEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}"
            -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/BakeMetalShader.cmake"
          DEPENDS
            "${WAM_NATIVE_VIDEO_SHADER_SOURCE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/cmake/BakeMetalShader.cmake"
            Qt6::qsb
          COMMENT "Baking ${WAM_NATIVE_VIDEO_SHADER} with an embedded metallib"
          VERBATIM)
        set_source_files_properties("${WAM_NATIVE_VIDEO_SHADER_QSB}"
          PROPERTIES
            GENERATED TRUE
            QT_RESOURCE_ALIAS "${WAM_NATIVE_VIDEO_SHADER}.qsb")
        list(APPEND WAM_NATIVE_VIDEO_QSB_FILES
          "${WAM_NATIVE_VIDEO_SHADER_QSB}")
      endforeach()

      add_executable(wam_native_qt_metal_compositor_test
        tests/native_qt_metal_compositor_test.mm
        src/platform/macos/qt_metal_video_item.hpp
        src/platform/macos/qt_metal_video_item.mm)
      qt_add_resources(wam_native_qt_metal_compositor_test
        wam_native_qt_metal_shaders
        PREFIX "/wam/native-video/shaders"
        FILES ${WAM_NATIVE_VIDEO_QSB_FILES})
      target_include_directories(wam_native_qt_metal_compositor_test PRIVATE
        src)
      target_compile_definitions(wam_native_qt_metal_compositor_test PRIVATE
        WAM_NATIVE_METAL_VIDEO_TESTING=1)
      target_link_libraries(wam_native_qt_metal_compositor_test PRIVATE
        wam_macos_native_video_metal_mapper
        Qt6::Core
        Qt6::Gui
        Qt6::Qml
        Qt6::Quick)
      target_compile_options(wam_native_qt_metal_compositor_test PRIVATE
        "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
        -Wall -Wextra -Wpedantic)
      set_target_properties(wam_native_qt_metal_compositor_test PROPERTIES
        AUTOMOC ON
        LINKER_LANGUAGE OBJCXX)
      add_test(NAME macos_native_qt_metal_compositor
        COMMAND wam_native_qt_metal_compositor_test)
      set_tests_properties(macos_native_qt_metal_compositor PROPERTIES
        TIMEOUT 20)

      # OpenGL/CGL hardware gate matching the shipping Qt graphics backend.
      # The item is absent from default application builds; the opt-in
      # production seam compiles it but does not register or construct it.
      add_executable(wam_native_qt_gl_compositor_test
        tests/native_qt_gl_compositor_test.mm
        src/platform/macos/qt_gl_video_item.hpp
        src/platform/macos/qt_gl_video_item.mm)
      target_include_directories(wam_native_qt_gl_compositor_test PRIVATE src)
      target_compile_definitions(wam_native_qt_gl_compositor_test PRIVATE
        WAM_NATIVE_GL_VIDEO_TESTING=1
        GL_SILENCE_DEPRECATION=1)
      target_link_libraries(wam_native_qt_gl_compositor_test PRIVATE
        wam_macos_native_video_core
        Qt6::Core
        Qt6::Gui
        Qt6::Qml
        Qt6::Quick
        "${WAM_OPENGL_FRAMEWORK}")
      target_compile_options(wam_native_qt_gl_compositor_test PRIVATE
        "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
        -Wall -Wextra -Wpedantic)
      set_target_properties(wam_native_qt_gl_compositor_test PROPERTIES
        AUTOMOC ON
        LINKER_LANGUAGE OBJCXX)
      add_test(NAME macos_native_qt_gl_compositor
        COMMAND wam_native_qt_gl_compositor_test)
      set_tests_properties(macos_native_qt_gl_compositor PROPERTIES
        TIMEOUT 120)

      # One-shot native action executor gate. The session, Qt output adapter,
      # and OpenGL item are absent from default application builds; the opt-in
      # production seam compiles them without creating a runtime owner.
      add_executable(wam_native_video_session_test
        tests/native_video_session_test.mm
        src/platform/macos/native_video_session.hpp
        src/platform/macos/native_video_session.mm
        src/platform/macos/native_qt_gl_output.hpp
        src/platform/macos/native_qt_gl_output.mm
        src/platform/macos/qt_gl_video_item.hpp
        src/platform/macos/qt_gl_video_item.mm)
      target_include_directories(wam_native_video_session_test PRIVATE src)
      target_compile_definitions(wam_native_video_session_test PRIVATE
        WAM_NATIVE_VIDEO_SESSION_TESTING=1
        WAM_NATIVE_GL_VIDEO_TESTING=1
        GL_SILENCE_DEPRECATION=1)
      target_link_libraries(wam_native_video_session_test PRIVATE
        wam_macos_native_video
        Qt6::Core
        Qt6::Gui
        Qt6::Qml
        Qt6::Quick
        "${WAM_OPENGL_FRAMEWORK}")
      target_compile_options(wam_native_video_session_test PRIVATE
        "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
        -Wall -Wextra -Wpedantic)
      set_target_properties(wam_native_video_session_test PROPERTIES
        AUTOMOC ON
        LINKER_LANGUAGE OBJCXX)
      add_test(NAME macos_native_video_session
        COMMAND wam_native_video_session_test)
      set_tests_properties(macos_native_video_session PROPERTIES TIMEOUT 20)

      # Exact coordinator-action adapter gate. The adapter is absent from
      # default application builds. The opt-in production seam compiles it,
      # but no concrete PlayerController ports construct or select it yet.
      add_executable(wam_native_video_action_driver_test
        tests/native_video_action_driver_test.mm
        src/platform/macos/native_video_action_driver.hpp
        src/platform/macos/native_video_action_driver.mm)
      target_include_directories(wam_native_video_action_driver_test PRIVATE
        src)
      target_link_libraries(wam_native_video_action_driver_test PRIVATE
        "${WAM_FOUNDATION_FRAMEWORK}")
      target_compile_options(wam_native_video_action_driver_test PRIVATE
        "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
        -Wall -Wextra -Wpedantic)
      set_target_properties(wam_native_video_action_driver_test PROPERTIES
        LINKER_LANGUAGE OBJCXX)
      add_test(NAME macos_native_video_action_driver
        COMMAND wam_native_video_action_driver_test)
      set_tests_properties(macos_native_video_action_driver PROPERTIES
        TIMEOUT 10)

      find_library(WAM_AVFOUNDATION_FRAMEWORK AVFoundation REQUIRED)
      add_executable(wam_video_toolbox_decoder_test
        tests/video_toolbox_decoder_test.mm
        ${WAM_MACOS_NATIVE_VIDEO_CORE_SOURCES}
        ${WAM_MACOS_NATIVE_VIDEO_METAL_MAPPER_SOURCES})
      target_include_directories(wam_video_toolbox_decoder_test PRIVATE src)
      target_compile_definitions(wam_video_toolbox_decoder_test PRIVATE
        WAM_NATIVE_VIDEO_TESTING=1
        GL_SILENCE_DEPRECATION=1)
      if(WAM_ENABLE_SOFTWARE_VP8)
        # This target compiles the core sources directly rather than linking
        # the library, so it needs the same feature definition and the same
        # libvpx link the library carries.
        target_compile_definitions(wam_video_toolbox_decoder_test PRIVATE
          WAM_ENABLE_SOFTWARE_VP8)
        target_link_libraries(wam_video_toolbox_decoder_test PRIVATE
          PkgConfig::WAM_LIBVPX)
      endif()
      target_link_libraries(wam_video_toolbox_decoder_test PRIVATE
        "${WAM_COREFOUNDATION_FRAMEWORK}"
        "${WAM_COREMEDIA_FRAMEWORK}"
        "${WAM_COREVIDEO_FRAMEWORK}"
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_IOSURFACE_FRAMEWORK}"
        "${WAM_METAL_FRAMEWORK}"
        "${WAM_OPENGL_FRAMEWORK}"
        "${WAM_VIDEOTOOLBOX_FRAMEWORK}"
        "${WAM_AVFOUNDATION_FRAMEWORK}")
      target_compile_options(wam_video_toolbox_decoder_test PRIVATE
        "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
        -Wall -Wextra -Wpedantic)
      set_target_properties(wam_video_toolbox_decoder_test PROPERTIES
        LINKER_LANGUAGE OBJCXX)
      add_test(NAME macos_video_toolbox_decoder_limits
        COMMAND wam_video_toolbox_decoder_test --limits-only)
      set_tests_properties(macos_video_toolbox_decoder_limits PROPERTIES
        TIMEOUT 10)
      set(WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE
        "${WAM_NATIVE_VIDEO_TEST_FIXTURE}")
      set(WAM_RESOLVED_NATIVE_VIDEO_10BIT_TEST_FIXTURE
        "${WAM_NATIVE_VIDEO_10BIT_TEST_FIXTURE}")
      if(NOT WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE AND
          EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/test-media/sample-h264.mp4")
        set(WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE
          "${CMAKE_CURRENT_SOURCE_DIR}/test-media/sample-h264.mp4")
      endif()

      if(WAM_REQUIRE_NATIVE_VIDEO_TEST_HARDWARE)
        if(NOT WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE OR
            NOT EXISTS "${WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE}")
          message(FATAL_ERROR
            "WAM_REQUIRE_NATIVE_VIDEO_TEST_HARDWARE requires an existing "
            "H.264 fixture")
        endif()
        if(NOT WAM_RESOLVED_NATIVE_VIDEO_10BIT_TEST_FIXTURE OR
            NOT EXISTS "${WAM_RESOLVED_NATIVE_VIDEO_10BIT_TEST_FIXTURE}")
          message(FATAL_ERROR
            "WAM_REQUIRE_NATIVE_VIDEO_TEST_HARDWARE requires an existing "
            "Main 10 HEVC fixture")
        endif()
      endif()

      set(WAM_NATIVE_HEADLESS_PERFORMANCE_FIXTURE
        "${CMAKE_CURRENT_SOURCE_DIR}/test-media/sample-h264.mp4")
      # Always compile the production-layout regression, including in clean
      # checkouts without media. Only its real-file execution needs the known
      # H.264/AAC fixture. Verdicts use identity, reuse, and bounded-ownership
      # facts; optional timings remain report-only.
      add_executable(wam_native_headless_performance_test
        tests/native_headless_performance_test.mm)
      target_include_directories(
        wam_native_headless_performance_test PRIVATE src)
      target_compile_features(
        wam_native_headless_performance_test PRIVATE cxx_std_20)
      target_compile_options(
        wam_native_headless_performance_test PRIVATE
        "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
        -Wall -Wextra -Wpedantic)
      target_link_libraries(wam_native_headless_performance_test PRIVATE
        wam_macos_native_backend)
      set_target_properties(
        wam_native_headless_performance_test PROPERTIES
        LINKER_LANGUAGE OBJCXX)
      if(EXISTS "${WAM_NATIVE_HEADLESS_PERFORMANCE_FIXTURE}")
        add_test(NAME macos_native_headless_performance
          COMMAND wam_native_headless_performance_test
            "${WAM_NATIVE_HEADLESS_PERFORMANCE_FIXTURE}")
        set_tests_properties(macos_native_headless_performance PROPERTIES
          TIMEOUT 30)
      endif()

      # The pipeline's scheduling hooks alter its private layout and control
      # flow. Compile its complete legacy implementation privately so neither
      # the production backend nor its class layouts can mix with this macro-
      # bearing executable.
      add_library(wam_macos_native_video_pipeline_test_impl STATIC
        ${WAM_MACOS_NATIVE_VIDEO_CORE_SOURCES}
        ${WAM_MACOS_NATIVE_VIDEO_METAL_MAPPER_SOURCES}
        ${WAM_MACOS_NATIVE_VIDEO_SOURCES})
      target_include_directories(
        wam_macos_native_video_pipeline_test_impl PUBLIC src)
      target_compile_features(
        wam_macos_native_video_pipeline_test_impl PUBLIC cxx_std_20)
      target_compile_definitions(
        wam_macos_native_video_pipeline_test_impl PRIVATE
        WAM_NATIVE_VIDEO_PIPELINE_TESTING=1)
      if(WAM_ENABLE_SOFTWARE_VP8)
        # Compiles the core sources directly instead of linking the library,
        # so it needs the same feature definition and libvpx link.
        target_compile_definitions(
          wam_macos_native_video_pipeline_test_impl PUBLIC
          WAM_ENABLE_SOFTWARE_VP8)
        target_link_libraries(
          wam_macos_native_video_pipeline_test_impl PUBLIC
          PkgConfig::WAM_LIBVPX)
      endif()
      target_compile_options(
        wam_macos_native_video_pipeline_test_impl PRIVATE
        "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
        -Wall -Wextra -Wpedantic)
      target_link_libraries(
        wam_macos_native_video_pipeline_test_impl PUBLIC
        "${WAM_COREFOUNDATION_FRAMEWORK}"
        "${WAM_COREMEDIA_FRAMEWORK}"
        "${WAM_COREVIDEO_FRAMEWORK}"
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_IOSURFACE_FRAMEWORK}"
        "${WAM_APPKIT_FRAMEWORK}"
        "${WAM_AVFOUNDATION_FRAMEWORK}"
        "${WAM_METAL_FRAMEWORK}"
        "${WAM_QUARTZCORE_FRAMEWORK}"
        "${WAM_VIDEOTOOLBOX_FRAMEWORK}")

      add_executable(wam_native_video_pipeline_test
        tests/native_video_pipeline_test.mm)
      target_compile_definitions(wam_native_video_pipeline_test PRIVATE
        WAM_NATIVE_VIDEO_PIPELINE_TESTING=1)
      target_link_libraries(wam_native_video_pipeline_test PRIVATE
        wam_macos_native_video_pipeline_test_impl)
      target_compile_options(wam_native_video_pipeline_test PRIVATE
        "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
        -Wall -Wextra -Wpedantic)
      set_target_properties(wam_native_video_pipeline_test PROPERTIES
        LINKER_LANGUAGE OBJCXX)
      add_test(NAME macos_native_video_pipeline_admission
        COMMAND wam_native_video_pipeline_test --admission-only)
      set_tests_properties(macos_native_video_pipeline_admission PROPERTIES
        TIMEOUT 10)

      if(WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE AND
          EXISTS "${WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE}")
        add_test(NAME macos_native_video_pipeline
          COMMAND wam_native_video_pipeline_test
            "${WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE}")
        set_tests_properties(macos_native_video_pipeline PROPERTIES
          TIMEOUT 45
          SKIP_RETURN_CODE 77)
        if(WAM_RESOLVED_NATIVE_VIDEO_10BIT_TEST_FIXTURE AND
            EXISTS "${WAM_RESOLVED_NATIVE_VIDEO_10BIT_TEST_FIXTURE}")
          string(REPLACE ";" "\\;"
            WAM_ESCAPED_NATIVE_VIDEO_10BIT_TEST_FIXTURE
            "${WAM_RESOLVED_NATIVE_VIDEO_10BIT_TEST_FIXTURE}")
          string(CONCAT WAM_NATIVE_VIDEO_PIPELINE_TEST_ENVIRONMENT
            "WAM_NATIVE_VIDEO_10BIT_TEST_FIXTURE="
            "${WAM_ESCAPED_NATIVE_VIDEO_10BIT_TEST_FIXTURE}")
          set_tests_properties(macos_native_video_pipeline PROPERTIES
            ENVIRONMENT
              "${WAM_NATIVE_VIDEO_PIPELINE_TEST_ENVIRONMENT}")
        endif()

        # Dormant scheduler-to-Qt bridge hardware gate. The adapter and Qt
        # OpenGL item are absent from default application builds. The opt-in
        # production seam compiles them, but does not construct, register, or
        # select them until controller/fallback activation is approved.
        add_executable(wam_native_qt_gl_output_test
          tests/native_qt_gl_output_test.mm
          src/platform/macos/native_qt_gl_output.hpp
          src/platform/macos/native_qt_gl_output.mm
          src/platform/macos/qt_gl_video_item.hpp
          src/platform/macos/qt_gl_video_item.mm)
        target_include_directories(wam_native_qt_gl_output_test PRIVATE src)
        target_compile_definitions(wam_native_qt_gl_output_test PRIVATE
          WAM_NATIVE_VIDEO_PIPELINE_TESTING=1
          WAM_NATIVE_GL_VIDEO_TESTING=1
          GL_SILENCE_DEPRECATION=1)
        target_link_libraries(wam_native_qt_gl_output_test PRIVATE
          wam_macos_native_video_pipeline_test_impl
          Qt6::Core
          Qt6::Gui
          Qt6::Qml
          Qt6::Quick
          "${WAM_OPENGL_FRAMEWORK}")
        target_compile_options(wam_native_qt_gl_output_test PRIVATE
          "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
          -Wall -Wextra -Wpedantic)
        set_target_properties(wam_native_qt_gl_output_test PROPERTIES
          AUTOMOC ON
          LINKER_LANGUAGE OBJCXX)
        add_test(NAME macos_native_qt_gl_output
          COMMAND wam_native_qt_gl_output_test
            "${WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE}")
        set_tests_properties(macos_native_qt_gl_output PROPERTIES
          TIMEOUT 45
          SKIP_RETURN_CODE 77)

        set(WAM_VIDEO_TOOLBOX_DECODER_TEST_ARGUMENTS
          "${WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE}")
        if(WAM_RESOLVED_NATIVE_VIDEO_10BIT_TEST_FIXTURE AND
            EXISTS "${WAM_RESOLVED_NATIVE_VIDEO_10BIT_TEST_FIXTURE}")
          list(APPEND WAM_VIDEO_TOOLBOX_DECODER_TEST_ARGUMENTS
            "${WAM_RESOLVED_NATIVE_VIDEO_10BIT_TEST_FIXTURE}")
        else()
          message(WARNING
            "Native VideoToolbox decoder test will run without real P010 "
            "decode coverage; set WAM_NATIVE_VIDEO_10BIT_TEST_FIXTURE to "
            "enable it")
        endif()
        if(WAM_REQUIRE_NATIVE_VIDEO_TEST_HARDWARE)
          list(APPEND WAM_VIDEO_TOOLBOX_DECODER_TEST_ARGUMENTS
            "--require-hardware")
        endif()
        add_test(NAME macos_video_toolbox_decoder
          COMMAND wam_video_toolbox_decoder_test
            ${WAM_VIDEO_TOOLBOX_DECODER_TEST_ARGUMENTS})
        set_tests_properties(macos_video_toolbox_decoder PROPERTIES
          TIMEOUT 30)
      else()
        message(WARNING
          "Fixture-backed native video tests were not registered; set "
          "WAM_NATIVE_VIDEO_TEST_FIXTURE to enable them")
      endif()
    endif()
  endif()
endif()

set(CPACK_PACKAGE_NAME "WAM")
set(CPACK_PACKAGE_VENDOR "Wesley Maa")
set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
if(WIN32)
  set(CPACK_GENERATOR "ZIP")
else()
  set(CPACK_GENERATOR "TGZ")
endif()
include(CPack)
