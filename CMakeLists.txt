cmake_minimum_required(VERSION 3.24)

# Qt 6.11 supports macOS 13 and newer. Pin the executable's load-command floor
# instead of inheriting the build machine's current SDK version.
if(APPLE AND NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "13.3" CACHE STRING
      "Minimum supported macOS version")
endif()

project(WAM VERSION 0.4.30 LANGUAGES CXX)

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

set(WAM_FFMPEG_LGPL_ROOT "${CMAKE_SOURCE_DIR}/third_party/ffmpeg-lgpl" CACHE PATH
    "Pinned native FFmpeg LGPL installation")
option(WAM_ENABLE_AVFORMAT_STAGE "Build the native libavformat demux stage" ${APPLE})
option(WAM_ENABLE_AVCODEC_STAGE "Build the native libavcodec decode adapters" OFF)
if(WAM_ENABLE_AVCODEC_STAGE OR WAM_ENABLE_AVFORMAT_STAGE)
  if(NOT APPLE OR NOT EXISTS "${WAM_FFMPEG_LGPL_ROOT}/include/libavcodec/avcodec.h")
    message(FATAL_ERROR "Run scripts/build_ffmpeg_lgpl.sh with the pinned local archive first")
  endif()
  add_library(wam_ffmpeg_lgpl INTERFACE)
  target_include_directories(wam_ffmpeg_lgpl INTERFACE "${WAM_FFMPEG_LGPL_ROOT}/include")
  add_library(wam_avcodec_worker STATIC src/media/avcodec/decode_worker.cpp src/media/avcodec/runtime.cpp)
  target_include_directories(wam_avcodec_worker PUBLIC src)
  target_compile_features(wam_avcodec_worker PUBLIC cxx_std_20)
  target_link_libraries(wam_avcodec_worker PUBLIC wam_ffmpeg_lgpl)
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
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(WAM_BUILD_APP "Build WAM's Qt application" ON)
option(WAM_BUILD_WAMKIT "Build the native embedding framework" ${APPLE})
include(src/wamkit/NativeTargets.cmake)
if(NOT WAM_BUILD_APP)
  if(WAM_BUILD_WAMKIT)
    add_subdirectory(src/wamkit)
  endif()
  return()
endif()

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
  src/qt/subtitle_bitmap_provider.cpp
  src/qt/subtitle_bitmap_provider.hpp
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

  add_library(wam_macos_native_qt_tracked STATIC
    src/platform/macos/native_qt_gl_output.hpp
    src/platform/macos/native_qt_gl_output.mm
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
      wam_macos_native_layer
      Qt6::Core
      Qt6::Gui
      Qt6::Quick
    PRIVATE
      "${WAM_OPENGL_FRAMEWORK}"
      "-framework AVFoundation"
      "-framework QuartzCore"
      # CIFilter, for the Vivid boost's exposure filter on the display layer
      # (src/platform/macos/native_layer_host_view.mm). CoreAnimation applies
      # it during compositing, so this buys the EDR brightness change without
      # a per-frame pass in this process.
      "-framework CoreImage")
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
  # Named explicitly because the layer contract test links the host view
  # without the umbrella that otherwise drags CoreImage in for the app.
  find_library(WAM_COREIMAGE_FRAMEWORK CoreImage REQUIRED)
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

    if(BUILD_TESTING)
      add_executable(wam_native_session_factory_test tests/native_session_factory_test.mm)
      target_link_libraries(wam_native_session_factory_test PRIVATE wam_macos_native_session_system)
      add_test(NAME native_session_factory COMMAND wam_native_session_factory_test)
      add_executable(wam_native_retirement_test tests/native_retirement_test.mm)
      target_link_libraries(wam_native_retirement_test PRIVATE wam_macos_native_session_system)
      add_test(NAME native_retirement COMMAND wam_native_retirement_test)
      set_tests_properties(native_retirement PROPERTIES TIMEOUT 10)
      add_executable(wam_native_owner_embedding_test tests/native_owner_embedding_test.mm)
      target_link_libraries(wam_native_owner_embedding_test PRIVATE wam_macos_native_session_system)
      add_test(NAME native_owner_embedding COMMAND wam_native_owner_embedding_test)
      add_executable(wam_native_exact_embedding_time_test tests/native_exact_embedding_time_test.cpp)
      target_link_libraries(wam_native_exact_embedding_time_test PRIVATE wam_native_core)
      add_test(NAME native_exact_embedding_time COMMAND wam_native_exact_embedding_time_test)
      add_executable(wam_native_layer_embedding_test tests/native_layer_embedding_test.mm)
      target_compile_options(wam_native_layer_embedding_test PRIVATE -fobjc-arc)
      target_link_libraries(wam_native_layer_embedding_test PRIVATE wam_macos_native_layer)
      add_test(NAME native_layer_embedding COMMAND wam_native_layer_embedding_test)
    endif()

    target_sources(wam PRIVATE
      src/qt/native_benchmark_telemetry.hpp
      src/qt/native_benchmark_telemetry.cpp
      src/qt/native_playback_metrics.hpp
      src/qt/native_playback_metrics.cpp
      src/qt/native_open_preflight.hpp
      src/qt/native_open_preflight.mm
      src/qt/native_playback_owner.hpp
      src/qt/native_playback_owner.mm
      src/qt/native_media_session_adapter.hpp
      src/qt/native_media_session_adapter.mm)
    target_compile_definitions(wam PRIVATE
      WAM_HAS_MACOS_NATIVE_PLAYBACK=1)
    target_compile_options(wam PRIVATE
      "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
    target_link_libraries(wam PRIVATE
      wam_macos_native_session_system)
    set_target_properties(wam PROPERTIES LINKER_LANGUAGE OBJCXX)
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

    add_executable(wam_media_container_routing_test
      tests/media_container_routing_test.cpp)
    target_link_libraries(
      wam_media_container_routing_test PRIVATE wam_native_core)
    add_test(NAME media_container_routing
      COMMAND wam_media_container_routing_test)

    add_executable(wam_matroska_ebml_test
      tests/matroska_ebml_test.cpp)
    target_link_libraries(wam_matroska_ebml_test PRIVATE wam_native_core)
    add_test(NAME matroska_ebml COMMAND wam_matroska_ebml_test)

    add_executable(wam_subtitle_text_test
      tests/subtitle_text_test.cpp)
    target_link_libraries(wam_subtitle_text_test PRIVATE wam_native_core)
    add_test(NAME subtitle_text COMMAND wam_subtitle_text_test)

    add_executable(wam_embedded_captions_test
      tests/embedded_captions_test.cpp)
    target_link_libraries(wam_embedded_captions_test PRIVATE wam_native_core)
    add_test(NAME embedded_captions COMMAND wam_embedded_captions_test)

    add_executable(wam_subtitle_bitmap_test
      tests/subtitle_bitmap_test.cpp)
    target_link_libraries(wam_subtitle_bitmap_test PRIVATE wam_native_core)
    add_test(NAME subtitle_bitmap COMMAND wam_subtitle_bitmap_test)

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

    add_executable(wam_audio_codec_timing_test
      tests/audio_codec_timing_test.cpp)
    target_link_libraries(wam_audio_codec_timing_test PRIVATE wam_native_core)
    add_test(NAME audio_codec_timing COMMAND wam_audio_codec_timing_test)

    add_executable(wam_native_audio_sample_rates_test
      tests/native_audio_sample_rates_test.cpp
      src/platform/macos/native_audio_sample_rates.hpp)
    target_link_libraries(wam_native_audio_sample_rates_test PRIVATE
      wam_native_core)
    add_test(NAME native_audio_sample_rates
      COMMAND wam_native_audio_sample_rates_test)

    add_executable(wam_native_coverage_admission_test
      tests/native_coverage_admission_test.cpp)
    target_link_libraries(wam_native_coverage_admission_test PRIVATE wam_native_core)
    add_test(NAME native_coverage_admission COMMAND wam_native_coverage_admission_test)

    add_executable(wam_media_codec_facts_test
      tests/media_codec_facts_test.cpp)
    target_link_libraries(wam_media_codec_facts_test PRIVATE wam_native_core)
    add_test(NAME media_codec_facts COMMAND wam_media_codec_facts_test)

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
    if(WAM_ENABLE_AVCODEC_STAGE)
      target_compile_definitions(wam_matroska_demuxer_test PRIVATE WAM_ENABLE_AVCODEC_STAGE=1)
    endif()
    add_test(NAME matroska_demuxer COMMAND wam_matroska_demuxer_test)

    add_executable(wam_mpegts_demuxer_test
      tests/mpegts_demuxer_test.cpp)
    target_link_libraries(wam_mpegts_demuxer_test PRIVATE wam_native_core)
    add_test(NAME mpegts_demuxer COMMAND wam_mpegts_demuxer_test)
    find_program(WAM_MPEGTS_PYTHON NAMES python3 REQUIRED)
    find_program(WAM_MPEGTS_FFMPEG NAMES ffmpeg
      HINTS "${CMAKE_BINARY_DIR}/runtime" REQUIRED)
    set(WAM_MPEGTS_FIXTURE_DIR "${CMAKE_BINARY_DIR}/mpegts-fixtures-v1")
    add_test(NAME mpegts_fixture_setup
      COMMAND "${WAM_MPEGTS_PYTHON}"
        "${CMAKE_SOURCE_DIR}/tests/prepare_mpegts_fixtures.py"
        --root "${WAM_MPEGTS_FIXTURE_DIR}" --ffmpeg "${WAM_MPEGTS_FFMPEG}")
    set_tests_properties(mpegts_fixture_setup PROPERTIES
      FIXTURES_SETUP mpegts_corpus TIMEOUT 120)
    add_test(NAME mpegts_demuxer_integration
      COMMAND wam_mpegts_demuxer_test --integration)
    set_tests_properties(mpegts_demuxer_integration PROPERTIES
      FIXTURES_REQUIRED mpegts_corpus
      ENVIRONMENT "WAM_MPEGTS_FIXTURES=${WAM_MPEGTS_FIXTURE_DIR}")

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
    target_link_libraries(wam_native_media_clock_test PRIVATE wam_native_core)
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
        wam_embedded_captions_test
        wam_subtitle_bitmap_test
        wam_matroska_subtitles_test
        wam_matroska_opus_test
        wam_matroska_vorbis_test
        wam_matroska_ac3_test
        wam_audio_downmix_test
        wam_audio_codec_timing_test
        wam_native_audio_sample_rates_test
        wam_media_codec_facts_test
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
      embedded_captions
      subtitle_bitmap
      matroska_subtitles
      matroska_opus
      matroska_vorbis
      matroska_ac3
      audio_downmix
      audio_codec_timing
      native_audio_sample_rates
      media_codec_facts
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
    src/qt/subtitle_bitmap_provider.cpp
    src/qt/subtitle_bitmap_provider.hpp
    src/media/subtitle_text.cpp
    src/media/matroska_subtitles.cpp
    src/media/tx3g_text.cpp
    src/media/mp4_subtitles.cpp
    src/media/h264_caption_sei.cpp
    src/media/cea608_decoder.cpp
    src/media/live_caption_feed.cpp
    src/media/subtitle_bitmap.cpp
    src/media/subtitle_pgs.cpp
    src/media/subtitle_vobsub.cpp
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
    src/qt/subtitle_bitmap_provider.cpp
    src/qt/subtitle_bitmap_provider.hpp
    src/media/subtitle_text.cpp
    src/media/matroska_subtitles.cpp
    src/media/tx3g_text.cpp
    src/media/mp4_subtitles.cpp
    src/media/h264_caption_sei.cpp
    src/media/cea608_decoder.cpp
    src/media/live_caption_feed.cpp
    src/media/subtitle_bitmap.cpp
    src/media/subtitle_pgs.cpp
    src/media/subtitle_vobsub.cpp
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
      src/qt/subtitle_bitmap_provider.cpp
      src/qt/subtitle_bitmap_provider.hpp
      src/media/subtitle_text.cpp
      src/media/matroska_subtitles.cpp
    src/media/tx3g_text.cpp
    src/media/mp4_subtitles.cpp
    src/media/h264_caption_sei.cpp
    src/media/cea608_decoder.cpp
    src/media/live_caption_feed.cpp
      src/media/subtitle_bitmap.cpp
      src/media/subtitle_pgs.cpp
      src/media/subtitle_vobsub.cpp
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
      add_test(NAME macos_avfoundation_reader_cancellation
        COMMAND wam_avfoundation_media_source_test --cancel-only
          "${PROJECT_SOURCE_DIR}/test-media/wamkit/av.mp4")
      set_tests_properties(macos_avfoundation_reader_cancellation PROPERTIES TIMEOUT 15)
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

      add_executable(wam_native_apple_audio_probe tests/native_apple_audio_probe.mm)
      target_link_libraries(wam_native_apple_audio_probe PRIVATE
        "${WAM_FOUNDATION_FRAMEWORK}" "${WAM_AUDIOTOOLBOX_FRAMEWORK}")

      add_executable(wam_native_apple_video_probe tests/native_apple_video_probe.mm)
      target_link_libraries(wam_native_apple_video_probe PRIVATE
        wam_macos_native_backend "-framework ImageIO")

      add_executable(wam_native_coverage_source_probe
        tests/native_coverage_source_probe.mm)
      target_link_libraries(wam_native_coverage_source_probe PRIVATE
        wam_macos_native_backend)

      add_executable(wam_native_coverage_audio_probe
        tests/native_coverage_audio_probe.mm)
      target_link_libraries(wam_native_coverage_audio_probe PRIVATE
        wam_macos_native_backend)

      find_program(WAM_COVERAGE_FFMPEG NAMES ffmpeg
        HINTS "${CMAKE_SOURCE_DIR}/build/runtime")
      if(WAM_COVERAGE_FFMPEG)
        add_test(NAME native_coverage_wiring
          COMMAND "${WAM_MPEGTS_PYTHON}"
            "${CMAKE_SOURCE_DIR}/tests/native_coverage_wiring_test.py"
            --app "$<TARGET_FILE:wam>" --ffmpeg "${WAM_COVERAGE_FFMPEG}")
        set_tests_properties(native_coverage_wiring PROPERTIES TIMEOUT 180)
        add_test(NAME macos_native_coverage_integration
          COMMAND "${WAM_MPEGTS_PYTHON}"
            "${CMAKE_SOURCE_DIR}/tests/native_coverage_integration.py"
            --audio "$<TARGET_FILE:wam_native_coverage_audio_probe>"
            --source "$<TARGET_FILE:wam_native_coverage_source_probe>"
            --ffmpeg "${WAM_COVERAGE_FFMPEG}")
        set_tests_properties(macos_native_coverage_integration PROPERTIES TIMEOUT 90)
        add_test(NAME macos_native_phase0b_integration
          COMMAND "${WAM_MPEGTS_PYTHON}"
            "${CMAKE_SOURCE_DIR}/tests/native_phase0b_integration.py"
            --source "$<TARGET_FILE:wam_native_coverage_source_probe>"
            --video "$<TARGET_FILE:wam_native_apple_video_probe>"
            --ffmpeg "${WAM_COVERAGE_FFMPEG}")
        set_tests_properties(macos_native_phase0b_integration PROPERTIES TIMEOUT 180)
      endif()

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

      # The audio session test builds its own strict-flag translation units in
      # a temporary directory rather than linking a CMake target, which is why
      # it is a script. Registering the script is what puts it in ctest; it
      # needs no target of its own and stays runnable by hand.
      add_test(NAME macos_native_audio_session
        COMMAND sh
        "${CMAKE_CURRENT_SOURCE_DIR}/tests/run_native_audio_session_test.sh")
      set_tests_properties(macos_native_audio_session PROPERTIES
        TIMEOUT 600)

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

      add_executable(wam_native_audio_output_converter_test
        tests/native_audio_output_converter_test.mm
        src/platform/macos/native_audio_sample_rates.hpp)
      target_include_directories(wam_native_audio_output_converter_test
        PRIVATE src)
      target_link_libraries(wam_native_audio_output_converter_test PRIVATE
        wam_native_core
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
        "${WAM_COREAUDIO_FRAMEWORK}")
      add_test(NAME macos_native_audio_output_converter
        COMMAND wam_native_audio_output_converter_test)
      set_tests_properties(macos_native_audio_output_converter PROPERTIES
        TIMEOUT 120)

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
          wam_native_core
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
      # native_layer_host_view.mm comes along because the output's
      # setPresentationRotation defers the actual CoreAnimation work to it --
      # the rotation lives with the layer's geometry, not with the enqueue
      # path. AppKit and CoreImage are its dependencies, not the output's.
      add_executable(wam_native_layer_video_output_test
        tests/native_layer_video_output_test.mm
        src/platform/macos/native_layer_video_output.hpp
        src/platform/macos/native_layer_video_output.mm
        src/platform/macos/native_layer_host_view.hpp
        src/platform/macos/native_layer_host_view.mm)
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
        "${WAM_APPKIT_FRAMEWORK}"
        "${WAM_COREIMAGE_FRAMEWORK}"
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

      # The two custom-container media sources and the MPEG-TS preview source,
      # driven over their neutral public surface against containers muxed at
      # test time. Each binary skips when no muxer is installed, so a clean
      # checkout still builds and runs the suite. An absent find_program result
      # must reach the test as an empty argument, not as its NOTFOUND spelling.
      set(WAM_CONTAINER_FIXTURE_MUXER "")
      if(WAM_FFMPEG_EXECUTABLE)
        set(WAM_CONTAINER_FIXTURE_MUXER "${WAM_FFMPEG_EXECUTABLE}")
      endif()

      add_executable(wam_matroska_media_source_test
        tests/matroska_media_source_test.mm
        src/platform/macos/matroska_asset_context.hpp
        src/platform/macos/matroska_asset_context.cpp
        src/platform/macos/matroska_media_source.hpp
        src/platform/macos/matroska_media_source.mm
        src/platform/macos/matroska_sample_builder.hpp
        src/platform/macos/matroska_sample_builder.mm)
      target_include_directories(
        wam_matroska_media_source_test PRIVATE src)
      target_link_libraries(wam_matroska_media_source_test PRIVATE
        wam_native_core
        wam_macos_native_video_core
        "${WAM_COREMEDIA_FRAMEWORK}"
        "${WAM_COREFOUNDATION_FRAMEWORK}"
        "${WAM_COREGRAPHICS_FRAMEWORK}"
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
        "${WAM_AVFOUNDATION_FRAMEWORK}")
      add_test(NAME macos_matroska_media_source
        COMMAND wam_matroska_media_source_test "${WAM_CONTAINER_FIXTURE_MUXER}")
      set_tests_properties(macos_matroska_media_source PROPERTIES
        TIMEOUT 120
        SKIP_RETURN_CODE 77)

      add_executable(wam_mpegts_media_source_test
        tests/mpegts_media_source_test.mm
        src/platform/macos/mpegts_asset_context.hpp
        src/platform/macos/mpegts_asset_context.cpp
        src/platform/macos/mpegts_media_source.hpp
        src/platform/macos/mpegts_media_source.mm
        src/platform/macos/mpegts_sample_builder.hpp
        src/platform/macos/mpegts_sample_builder.mm)
      target_include_directories(
        wam_mpegts_media_source_test PRIVATE src)
      target_link_libraries(wam_mpegts_media_source_test PRIVATE
        wam_native_core
        wam_macos_native_video_core
        "${WAM_COREMEDIA_FRAMEWORK}"
        "${WAM_COREFOUNDATION_FRAMEWORK}"
        "${WAM_COREGRAPHICS_FRAMEWORK}"
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
        "${WAM_AVFOUNDATION_FRAMEWORK}")
      add_test(NAME macos_mpegts_media_source
        COMMAND wam_mpegts_media_source_test "${WAM_MPEGTS_FIXTURE_DIR}")
      set_tests_properties(macos_mpegts_media_source PROPERTIES
        TIMEOUT 120
        FIXTURES_REQUIRED mpegts_corpus)

      add_executable(wam_mpegts_preview_source_test
        tests/mpegts_preview_source_test.mm
        src/platform/macos/mpegts_asset_context.hpp
        src/platform/macos/mpegts_asset_context.cpp
        src/platform/macos/mpegts_media_source.hpp
        src/platform/macos/mpegts_media_source.mm
        src/platform/macos/mpegts_preview_source.hpp
        src/platform/macos/mpegts_preview_source.mm
        src/platform/macos/mpegts_sample_builder.hpp
        src/platform/macos/mpegts_sample_builder.mm
        # native_preview_source.mm switches exhaustively on backendKind, so
        # every backend's preview implementation is part of this test's link
        # closure whether or not the test exercises it.
        src/platform/macos/matroska_asset_context.hpp
        src/platform/macos/matroska_asset_context.cpp
        src/platform/macos/matroska_preview_source.hpp
        src/platform/macos/matroska_preview_source.mm
        src/platform/macos/matroska_sample_builder.hpp
        src/platform/macos/matroska_sample_builder.mm
        src/platform/macos/avfoundation_asset_context.hpp
        src/platform/macos/avfoundation_asset_context.mm
        src/platform/macos/avfoundation_preview_source.hpp
        src/platform/macos/avfoundation_preview_source.mm
        src/platform/macos/native_preview_source.hpp
        src/platform/macos/native_preview_source.mm)
      target_include_directories(
        wam_mpegts_preview_source_test PRIVATE src)
      target_link_libraries(wam_mpegts_preview_source_test PRIVATE
        wam_native_core
        wam_macos_native_video_core
        "${WAM_COREMEDIA_FRAMEWORK}"
        "${WAM_COREFOUNDATION_FRAMEWORK}"
        "${WAM_COREGRAPHICS_FRAMEWORK}"
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
        "${WAM_AVFOUNDATION_FRAMEWORK}")
      add_test(NAME macos_mpegts_preview_source
        COMMAND wam_mpegts_preview_source_test "${WAM_CONTAINER_FIXTURE_MUXER}")
      set_tests_properties(macos_mpegts_preview_source PROPERTIES
        TIMEOUT 120
        SKIP_RETURN_CODE 77)

      # The Traits seam of the shared custom-source core: both backends are
      # linked so the two Traits can be compared in one binary.
      add_executable(wam_native_custom_source_traits_test
        tests/native_custom_source_traits_test.mm
        src/platform/macos/native_custom_source_core.hpp
        src/platform/macos/matroska_asset_context.hpp
        src/platform/macos/matroska_asset_context.cpp
        src/platform/macos/matroska_media_source.hpp
        src/platform/macos/matroska_media_source.mm
        src/platform/macos/matroska_sample_builder.hpp
        src/platform/macos/matroska_sample_builder.mm
        src/platform/macos/mpegts_asset_context.hpp
        src/platform/macos/mpegts_asset_context.cpp
        src/platform/macos/mpegts_media_source.hpp
        src/platform/macos/mpegts_media_source.mm
        src/platform/macos/mpegts_sample_builder.hpp
        src/platform/macos/mpegts_sample_builder.mm)
      target_include_directories(
        wam_native_custom_source_traits_test PRIVATE src)
      target_link_libraries(wam_native_custom_source_traits_test PRIVATE
        wam_native_core
        wam_macos_native_video_core
        "${WAM_COREMEDIA_FRAMEWORK}"
        "${WAM_COREFOUNDATION_FRAMEWORK}"
        "${WAM_COREGRAPHICS_FRAMEWORK}"
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
        "${WAM_AVFOUNDATION_FRAMEWORK}")
      add_test(NAME macos_native_custom_source_traits
        COMMAND wam_native_custom_source_traits_test)
      set_tests_properties(macos_native_custom_source_traits PROPERTIES
        TIMEOUT 30)

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
        src/platform/macos/mpegts_media_source.mm
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
      add_test(NAME macos_mpegts_session_fallback
        COMMAND wam_native_media_session_test --mpegts-integration)
      set_tests_properties(macos_mpegts_session_fallback PROPERTIES
        FIXTURES_REQUIRED mpegts_corpus
        ENVIRONMENT "WAM_MPEGTS_FIXTURES=${WAM_MPEGTS_FIXTURE_DIR}")
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
        wam_macos_native_session_system
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
          wam_matroska_media_source_test
          wam_mpegts_media_source_test
          wam_mpegts_preview_source_test
          wam_native_custom_source_traits_test
          wam_native_audio_converter_test
          wam_native_audio_output_test
          wam_native_audio_output_converter_test
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
        WAM_NATIVE_SURFACE_BUDGET_TESTING=1)
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

      # Scene-graph route adapter gate (WAM_PRESENTATION=scenegraph). The
      # adapter's fault-injection seams exist only under the testing macro, so
      # the test compiles the adapter and item privately instead of linking
      # the production archive.
      add_executable(wam_native_qt_gl_output_test
        tests/native_qt_gl_output_test.mm
        src/platform/macos/native_qt_gl_output.hpp
        src/platform/macos/native_qt_gl_output.mm
        src/platform/macos/qt_gl_video_item.hpp
        src/platform/macos/qt_gl_video_item.mm)
      target_include_directories(wam_native_qt_gl_output_test PRIVATE src)
      target_compile_definitions(wam_native_qt_gl_output_test PRIVATE
        WAM_NATIVE_GL_VIDEO_TESTING=1
        GL_SILENCE_DEPRECATION=1)
      target_link_libraries(wam_native_qt_gl_output_test PRIVATE
        wam_macos_native_video_core
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
        COMMAND wam_native_qt_gl_output_test)
      set_tests_properties(macos_native_qt_gl_output PROPERTIES TIMEOUT 120)

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
        wam_native_core
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

      if(WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE AND
          EXISTS "${WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE}")
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

if(BUILD_TESTING AND WAM_ENABLE_AVCODEC_STAGE)
  add_executable(wam_avcodec_worker_test tests/avcodec_worker_test.cpp)
  target_link_libraries(wam_avcodec_worker_test PRIVATE wam_avcodec_worker)
  foreach(specimen IN ITEMS hi10p h264422 asp)
    if(specimen STREQUAL "asp")
      set(codec mpeg4)
    else()
      set(codec h264)
    endif()
    add_test(NAME avcodec_worker_${specimen} COMMAND wam_avcodec_worker_test
      "${CMAKE_SOURCE_DIR}/test-media/native-coverage/phase2/${specimen}.packets" "${codec}")
    set_tests_properties(avcodec_worker_${specimen} PROPERTIES TIMEOUT 30)
  endforeach()
endif()

if(BUILD_TESTING AND WAM_ENABLE_AVCODEC_STAGE)
  add_executable(wam_software_avcodec_video_test tests/software_avcodec_video_test.mm)
  target_link_libraries(wam_software_avcodec_video_test PRIVATE wam_macos_native_video_core)
  foreach(specimen IN ITEMS hi10p h264422 asp vp9 vp9p2)
    add_test(NAME software_avcodec_video_${specimen} COMMAND wam_software_avcodec_video_test
      "${CMAKE_SOURCE_DIR}/test-media/native-coverage/phase2/${specimen}.packets" "${specimen}")
    set_tests_properties(software_avcodec_video_${specimen} PROPERTIES TIMEOUT 30)
  endforeach()
endif()

if(WAM_ENABLE_AVCODEC_STAGE OR WAM_ENABLE_AVFORMAT_STAGE)
  set_property(TARGET wam APPEND PROPERTY BUILD_RPATH "@executable_path/../Frameworks")
  set_property(TARGET wam APPEND PROPERTY INSTALL_RPATH "@executable_path/../Frameworks")
  if(WAM_ENABLE_AVCODEC_STAGE)
    target_sources(wam_avcodec_worker PRIVATE src/platform/macos/software_avcodec_audio_backend.cpp)
  endif()
  file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/native-codecs")
  set(WAM_NATIVE_FFMPEG_LIBRARIES libavcodec-wamnative.63.dylib libavutil-wamnative.61.dylib)
  if(WAM_ENABLE_AVFORMAT_STAGE)
    list(APPEND WAM_NATIVE_FFMPEG_LIBRARIES libavformat-wamnative.63.dylib)
  endif()
  foreach(native_library IN LISTS WAM_NATIVE_FFMPEG_LIBRARIES)
    configure_file("${WAM_FFMPEG_LGPL_ROOT}/lib/${native_library}"
      "${CMAKE_BINARY_DIR}/native-codecs/${native_library}" COPYONLY)
    add_custom_command(TARGET wam POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_DIR:wam>/Contents/Frameworks"
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${WAM_FFMPEG_LGPL_ROOT}/lib/${native_library}"
        "$<TARGET_BUNDLE_DIR:wam>/Contents/Frameworks/${native_library}")
  endforeach()
  add_custom_command(TARGET wam POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_DIR:wam>/Contents/Resources/native-ffmpeg"
    COMMAND ${CMAKE_COMMAND} -E touch "$<TARGET_BUNDLE_DIR:wam>/Contents/Resources/native-ffmpeg/stage-built")
  set(WAM_NATIVE_FFMPEG_NOTICE_DIR "${CMAKE_SOURCE_DIR}/docs/native-coverage/phase2")
  if(WAM_ENABLE_AVFORMAT_STAGE)
    set(WAM_NATIVE_FFMPEG_NOTICE_DIR "${CMAKE_SOURCE_DIR}/docs/native-coverage/phase3")
    add_custom_command(TARGET wam POST_BUILD COMMAND ${CMAKE_COMMAND} -E touch
      "$<TARGET_BUNDLE_DIR:wam>/Contents/Resources/native-ffmpeg/demux-stage-built")
  endif()
  foreach(notice IN ITEMS FFMPEG_NOTICES.md COPYING.LGPLv2.1 LICENSE.md configure-command.txt build-receipt.txt)
    add_custom_command(TARGET wam POST_BUILD COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${WAM_NATIVE_FFMPEG_NOTICE_DIR}/${notice}"
      "$<TARGET_BUNDLE_DIR:wam>/Contents/Resources/native-ffmpeg/${notice}")
  endforeach()
  set(WAM_NATIVE_FFMPEG_SOURCE_NOTICE "${CMAKE_SOURCE_DIR}/docs/native-coverage/phase2b/SOURCE_DISTRIBUTION.md")
  if(WAM_ENABLE_AVFORMAT_STAGE)
    set(WAM_NATIVE_FFMPEG_SOURCE_NOTICE "${WAM_NATIVE_FFMPEG_NOTICE_DIR}/SOURCE_DISTRIBUTION.md")
  endif()
  add_custom_command(TARGET wam POST_BUILD COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${WAM_NATIVE_FFMPEG_SOURCE_NOTICE}"
    "$<TARGET_BUNDLE_DIR:wam>/Contents/Resources/native-ffmpeg/SOURCE_DISTRIBUTION.md")
endif()

if(BUILD_TESTING AND WAM_ENABLE_AVCODEC_STAGE)
  find_package(Python3 COMPONENTS Interpreter REQUIRED)
  find_program(WAM_AVCODEC_FIXTURE_FFMPEG ffmpeg REQUIRED)
  find_program(WAM_AVCODEC_FIXTURE_FFPROBE ffprobe REQUIRED)
  add_test(NAME avcodec_fixtures COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_SOURCE_DIR}/tests/native_avcodec_fixtures.py"
    --output "${CMAKE_SOURCE_DIR}/test-media/native-coverage/phase2"
    --ffmpeg "${WAM_AVCODEC_FIXTURE_FFMPEG}" --ffprobe "${WAM_AVCODEC_FIXTURE_FFPROBE}")
  set_tests_properties(avcodec_fixtures PROPERTIES
    FIXTURES_SETUP avcodec_media RUN_SERIAL TRUE RESOURCE_LOCK avcodec_fixture_generation TIMEOUT 120)
  add_test(NAME avcodec_packaging_audit COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_SOURCE_DIR}/tests/native_avcodec_packaging_audit_test.py")
  add_test(NAME avcodec_fixture_transaction COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_SOURCE_DIR}/tests/native_avcodec_fixture_transaction_test.py")
  set_tests_properties(avcodec_worker_hi10p avcodec_worker_h264422 avcodec_worker_asp
    software_avcodec_video_hi10p software_avcodec_video_h264422 software_avcodec_video_asp
    software_avcodec_video_vp9 software_avcodec_video_vp9p2
    PROPERTIES FIXTURES_REQUIRED avcodec_media)
  add_executable(wam_software_avcodec_audio_test tests/software_avcodec_audio_test.cpp
    src/platform/macos/software_avcodec_audio_backend.cpp)
  target_compile_definitions(wam_software_avcodec_audio_test PRIVATE WAM_AVCODEC_AUDIO_TESTING=1)
  target_link_libraries(wam_software_avcodec_audio_test PRIVATE wam_avcodec_worker)
  target_sources(wam_software_avcodec_audio_test PRIVATE src/media/audio_downmix.cpp)
  foreach(specimen IN ITEMS dts truehd mlp)
    add_test(NAME software_avcodec_audio_${specimen} COMMAND wam_software_avcodec_audio_test
      "${CMAKE_SOURCE_DIR}/test-media/native-coverage/phase2/${specimen}.audio-packets"
      "${CMAKE_SOURCE_DIR}/test-media/native-coverage/phase2/${specimen}.f32" "${specimen}")
    set_tests_properties(software_avcodec_audio_${specimen} PROPERTIES FIXTURES_REQUIRED avcodec_media TIMEOUT 30)
  endforeach()
endif()

if(BUILD_TESTING AND WAM_ENABLE_AVCODEC_STAGE)
  add_executable(wam_avcodec_runtime_test tests/avcodec_runtime_test.cpp)
  target_link_libraries(wam_avcodec_runtime_test PRIVATE wam_avcodec_worker)
  add_test(NAME avcodec_runtime COMMAND wam_avcodec_runtime_test)
  add_test(NAME avcodec_runtime_relocation COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_SOURCE_DIR}/tests/avcodec_runtime_relocation.py"
    --binary "$<TARGET_FILE:wam_avcodec_runtime_test>"
    --libraries "${CMAKE_BINARY_DIR}/native-codecs")
endif()

if(BUILD_TESTING AND WAM_ENABLE_AVCODEC_STAGE)
  add_library(wam_avcodec_instrumented STATIC
    src/media/avcodec/decode_worker.cpp src/media/avcodec/runtime.cpp)
  target_include_directories(wam_avcodec_instrumented PUBLIC src)
  target_compile_features(wam_avcodec_instrumented PUBLIC cxx_std_20)
  target_compile_definitions(wam_avcodec_instrumented PRIVATE WAM_AVCODEC_ALLOCATION_PROBE=1)
  target_link_libraries(wam_avcodec_instrumented PUBLIC wam_ffmpeg_lgpl)
  add_library(wam_avcodec_probe_hooks SHARED tests/avcodec_allocation_probe.cpp)
  target_include_directories(wam_avcodec_probe_hooks PRIVATE src)
  target_compile_definitions(wam_avcodec_probe_hooks PRIVATE WAM_AVCODEC_ALLOCATION_PROBE=1)
  target_link_libraries(wam_avcodec_instrumented PUBLIC wam_avcodec_probe_hooks)
  add_executable(wam_avcodec_allocation_test tests/avcodec_worker_test.cpp)
  target_compile_definitions(wam_avcodec_allocation_test PRIVATE WAM_AVCODEC_ALLOCATION_PROBE=1)
  target_link_libraries(wam_avcodec_allocation_test PRIVATE wam_avcodec_instrumented)
  add_executable(wam_avcodec_audio_allocation_test tests/software_avcodec_audio_test.cpp
    src/platform/macos/software_avcodec_audio_backend.cpp)
  target_compile_definitions(wam_avcodec_audio_allocation_test PRIVATE
    WAM_AVCODEC_ALLOCATION_PROBE=1 WAM_AVCODEC_AUDIO_TESTING=1)
  target_link_libraries(wam_avcodec_audio_allocation_test PRIVATE wam_avcodec_instrumented)
  target_sources(wam_avcodec_audio_allocation_test PRIVATE src/media/audio_downmix.cpp)
endif()

if(BUILD_TESTING AND WAM_ENABLE_AVCODEC_STAGE)
  foreach(specimen IN ITEMS dts51 truehd51)
    add_test(NAME software_avcodec_audio_${specimen} COMMAND wam_software_avcodec_audio_test
      "${CMAKE_SOURCE_DIR}/test-media/native-coverage/phase2/${specimen}.audio-packets"
      "${CMAKE_SOURCE_DIR}/test-media/native-coverage/phase2/${specimen}.f32" "${specimen}" 6
      "${CMAKE_SOURCE_DIR}/test-media/native-coverage/phase2/${specimen}.stereo.f32")
    set_tests_properties(software_avcodec_audio_${specimen} PROPERTIES FIXTURES_REQUIRED avcodec_media TIMEOUT 30)
  endforeach()
endif()

if(BUILD_TESTING AND WAM_ENABLE_AVCODEC_STAGE)
  add_executable(wam_avcodec_video_allocation_test tests/software_avcodec_video_test.mm)
  target_link_libraries(wam_avcodec_video_allocation_test PRIVATE
    wam_avcodec_instrumented wam_macos_native_video_core)
  add_test(NAME avcodec_allocation_attribution COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_SOURCE_DIR}/tests/avcodec_allocation_attribution_test.py"
    "$<TARGET_FILE:wam_avcodec_video_allocation_test>"
    "${CMAKE_SOURCE_DIR}/test-media/native-coverage/phase2/asp.packets" asp)
  set_tests_properties(avcodec_allocation_attribution PROPERTIES FIXTURES_REQUIRED avcodec_media TIMEOUT 45)
endif()

if(BUILD_TESTING AND WAM_ENABLE_AVCODEC_STAGE)
  add_executable(wam_avcodec_worker_budget_test tests/avcodec_worker_budget_test.cpp)
  target_link_libraries(wam_avcodec_worker_budget_test PRIVATE wam_avcodec_worker)
  add_test(NAME avcodec_worker_budget COMMAND wam_avcodec_worker_budget_test)
endif()

if(BUILD_TESTING AND WAM_ENABLE_AVFORMAT_STAGE)
  find_package(Python3 COMPONENTS Interpreter REQUIRED)
  find_program(WAM_AVCODEC_FIXTURE_FFMPEG ffmpeg REQUIRED)
  add_executable(wam_libavformat_source_test tests/libavformat_source_test.mm)
  target_link_libraries(wam_libavformat_source_test PRIVATE wam_macos_native_backend)
  set(WAM_AVFORMAT_FIXTURES "${CMAKE_SOURCE_DIR}/test-media/native-coverage/phase3")
  add_test(NAME libavformat_fixtures COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_SOURCE_DIR}/tests/libavformat_fixtures.py" --root "${WAM_AVFORMAT_FIXTURES}"
    --ffmpeg "${WAM_AVCODEC_FIXTURE_FFMPEG}")
  set_tests_properties(libavformat_fixtures PROPERTIES FIXTURES_SETUP avformat_media TIMEOUT 120)
  foreach(specimen IN ITEMS fragmented.mp4 boundary.mp4 mid-moof.mp4 mid-mdat.mp4 asp.avi)
    add_test(NAME libavformat_source_${specimen} COMMAND wam_libavformat_source_test
      "${WAM_AVFORMAT_FIXTURES}/${specimen}" ready)
    set_tests_properties(libavformat_source_${specimen} PROPERTIES FIXTURES_REQUIRED avformat_media TIMEOUT 30)
  endforeach()
  add_test(NAME libavformat_missing_init COMMAND wam_libavformat_source_test
    "${WAM_AVFORMAT_FIXTURES}/missing-init.mp4"
    "this recording is incomplete: its initialization metadata is missing")
  set_tests_properties(libavformat_missing_init PROPERTIES FIXTURES_REQUIRED avformat_media TIMEOUT 30)
endif()
if(BUILD_TESTING AND WAM_ENABLE_AVFORMAT_STAGE)
  add_executable(wam_libavformat_differential_test tests/libavformat_differential_test.cpp)
  target_link_libraries(wam_libavformat_differential_test PRIVATE wam_avcodec_worker wam_native_core)
  foreach(container IN ITEMS mkv ts)
    add_test(NAME libavformat_differential_${container} COMMAND wam_libavformat_differential_test
      "${WAM_AVFORMAT_FIXTURES}/oracle.${container}" "${container}")
    set_tests_properties(libavformat_differential_${container} PROPERTIES FIXTURES_REQUIRED avformat_media TIMEOUT 30)
  endforeach()
endif()
if(BUILD_TESTING AND WAM_ENABLE_AVFORMAT_STAGE)
  add_executable(wam_libavformat_decode_test tests/libavformat_decode_test.mm)
  target_link_libraries(wam_libavformat_decode_test PRIVATE wam_macos_native_backend)
endif()
if(BUILD_TESTING AND WAM_ENABLE_AVFORMAT_STAGE)
  add_executable(wam_libavformat_contract_test tests/libavformat_contract_test.cpp)
  target_link_libraries(wam_libavformat_contract_test PRIVATE wam_avcodec_worker)
  add_test(NAME libavformat_contract COMMAND wam_libavformat_contract_test)
endif()
if(BUILD_TESTING AND WAM_ENABLE_AVFORMAT_STAGE)
  add_test(NAME libavformat_avi_missing_pts COMMAND wam_libavformat_source_test
    "${WAM_AVFORMAT_FIXTURES}/reordered-asp.avi" "LibavformatExactVideoTimelineUnavailable")
  add_test(NAME libavformat_flv_audio_refusal COMMAND wam_libavformat_source_test
    "${CMAKE_SOURCE_DIR}/test-media/native-coverage/phase2e/positive-aac.flv" "LibavformatAudioTimingUnproven: aac")
  add_test(NAME libavformat_asf_audio_refusal COMMAND wam_libavformat_source_test
    "${WAM_AVFORMAT_FIXTURES}/legacy.asf" "LibavformatAudioTimingUnproven: wmav2")
  add_test(NAME libavformat_routed_avi COMMAND wam_libavformat_source_test
    "${WAM_AVFORMAT_FIXTURES}/asp.avi" ready routed)
  set_tests_properties(libavformat_avi_missing_pts libavformat_flv_audio_refusal
    libavformat_asf_audio_refusal libavformat_routed_avi PROPERTIES FIXTURES_REQUIRED avformat_media TIMEOUT 30)
endif()
if(BUILD_TESTING AND WAM_ENABLE_AVFORMAT_STAGE)
  add_test(NAME libavformat_opus_audio_exact COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_SOURCE_DIR}/tests/libavformat_audio_proof.py"
    --probe "$<TARGET_FILE:wam_native_coverage_audio_probe>"
    --asset "${WAM_AVFORMAT_FIXTURES}/opus.ogg" --ffmpeg "${WAM_AVCODEC_FIXTURE_FFMPEG}"
    --output "${CMAKE_BINARY_DIR}/libavformat-audio-proof.json")
  set_tests_properties(libavformat_opus_audio_exact PROPERTIES FIXTURES_REQUIRED avformat_media TIMEOUT 60)
endif()
if(BUILD_TESTING AND WAM_ENABLE_AVFORMAT_STAGE)
  add_test(NAME libavformat_routed_header_stripping COMMAND wam_libavformat_source_test
    "${WAM_AVFORMAT_FIXTURES}/header-stripped.mkv" ready routed)
  set_tests_properties(libavformat_routed_header_stripping PROPERTIES FIXTURES_REQUIRED avformat_media TIMEOUT 30)
endif()

if(BUILD_TESTING AND WAM_ENABLE_AVFORMAT_STAGE)
  add_library(wam_libavformat_allocation_hooks SHARED tests/avcodec_allocation_probe.cpp)
  target_include_directories(wam_libavformat_allocation_hooks PRIVATE src)
  target_compile_definitions(wam_libavformat_allocation_hooks PRIVATE WAM_AVCODEC_ALLOCATION_PROBE=1)
  add_executable(wam_libavformat_allocation_test tests/libavformat_allocation_test.mm)
  target_compile_definitions(wam_libavformat_allocation_test PRIVATE WAM_AVCODEC_ALLOCATION_PROBE=1)
  target_link_libraries(wam_libavformat_allocation_test PRIVATE
    wam_macos_native_backend wam_libavformat_allocation_hooks)
  add_test(NAME libavformat_vorbis_refusal COMMAND wam_libavformat_source_test
    "${WAM_AVFORMAT_FIXTURES}/vorbis.ogg" "LibavformatAudioTimingUnproven: vorbis")
  add_test(NAME libavformat_program_stream_refusal COMMAND wam_libavformat_source_test
    "${WAM_AVFORMAT_FIXTURES}/program.vob" "LibavformatAudioTimingUnproven: unmapped codec")
  set_tests_properties(libavformat_vorbis_refusal libavformat_program_stream_refusal
    PROPERTIES FIXTURES_REQUIRED avformat_media TIMEOUT 30)
endif()

if(BUILD_TESTING AND WAM_ENABLE_AVFORMAT_STAGE)
  add_executable(wam_libavformat_preview_decode_test tests/libavformat_preview_decode_test.mm)
  target_link_libraries(wam_libavformat_preview_decode_test PRIVATE wam_macos_native_backend)
endif()

if(BUILD_TESTING AND WAM_ENABLE_AVFORMAT_STAGE)
  set(WAM_AVFORMAT_PREVIEW_SPECIMENS fragmented.mp4)
  if(WAM_ENABLE_AVCODEC_STAGE)
    list(APPEND WAM_AVFORMAT_PREVIEW_SPECIMENS asp.avi)
  endif()
  foreach(specimen IN LISTS WAM_AVFORMAT_PREVIEW_SPECIMENS)
    add_test(NAME libavformat_preview_decode_${specimen} COMMAND wam_libavformat_preview_decode_test
      "${WAM_AVFORMAT_FIXTURES}/${specimen}")
    set_tests_properties(libavformat_preview_decode_${specimen} PROPERTIES
      FIXTURES_REQUIRED avformat_media TIMEOUT 30)
  endforeach()
endif()

if(BUILD_TESTING AND WAM_ENABLE_AVFORMAT_STAGE)
  foreach(specimen IN ITEMS mid-moof.mp4 mid-mdat.mp4)
    add_test(NAME libavformat_routed_recovery_${specimen} COMMAND wam_libavformat_source_test
      "${WAM_AVFORMAT_FIXTURES}/${specimen}" ready routed)
    set_tests_properties(libavformat_routed_recovery_${specimen} PROPERTIES
      FIXTURES_REQUIRED avformat_media TIMEOUT 30)
  endforeach()
endif()

if(BUILD_TESTING AND APPLE)
  find_package(Python3 COMPONENTS Interpreter REQUIRED)
  add_test(NAME native_stage_defaults COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_SOURCE_DIR}/tests/native_stage_defaults_test.py")
endif()

if(BUILD_TESTING AND WAM_ENABLE_AVCODEC_STAGE)
  add_executable(wam_software_avcodec_surface_contention_test
    tests/software_avcodec_surface_contention_test.mm
    src/platform/macos/native_surface_budget.mm)
  target_compile_definitions(wam_software_avcodec_surface_contention_test PRIVATE
    WAM_NATIVE_SURFACE_BUDGET_TESTING=1)
  target_link_libraries(wam_software_avcodec_surface_contention_test PRIVATE
    wam_macos_native_video_core)
  add_test(NAME software_avcodec_surface_contention
    COMMAND wam_software_avcodec_surface_contention_test
      "${CMAKE_SOURCE_DIR}/test-media/native-coverage/phase2/asp.packets")
  set_tests_properties(software_avcodec_surface_contention PROPERTIES
    FIXTURES_REQUIRED avcodec_media TIMEOUT 30)
endif()

if(BUILD_TESTING AND WAM_ENABLE_AVCODEC_STAGE)
  add_executable(wam_software_audio_packet_test tests/software_audio_packet_test.cpp)
  target_include_directories(wam_software_audio_packet_test PRIVATE src)
  add_test(NAME software_audio_packet COMMAND wam_software_audio_packet_test)
  add_test(NAME software_audio_production COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_SOURCE_DIR}/tests/software_audio_production_proof.py"
    --probe "$<TARGET_FILE:wam_native_coverage_audio_probe>"
    --fixtures "${CMAKE_SOURCE_DIR}/test-media/native-coverage/phase2"
    --ffmpeg "${WAM_AVCODEC_FIXTURE_FFMPEG}"
    --output "${CMAKE_BINARY_DIR}/software-audio-production.json")
  set_tests_properties(software_audio_production PROPERTIES FIXTURES_REQUIRED avcodec_media TIMEOUT 120)
endif()

if(BUILD_TESTING AND WAM_ENABLE_AVCODEC_STAGE)
  add_executable(wam_software_decoder_reservation_test tests/software_decoder_reservation_test.cpp)
  target_link_libraries(wam_software_decoder_reservation_test PRIVATE wam_avcodec_worker)
  add_test(NAME software_decoder_reservation COMMAND wam_software_decoder_reservation_test)
  set_tests_properties(software_decoder_reservation PROPERTIES TIMEOUT 30)
endif()

if(BUILD_TESTING AND WAM_ENABLE_AVCODEC_STAGE)
  add_test(NAME ffmpeg_reservation_allocator COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_SOURCE_DIR}/tests/ffmpeg_reservation_proof.py")
  add_test(NAME ffmpeg_reservation_unload COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_SOURCE_DIR}/tests/ffmpeg_reservation_loader_proof.py")
endif()

if(BUILD_TESTING AND APPLE AND WAM_ENABLE_AVFORMAT_STAGE)
  add_executable(wam_libavformat_mixed_audio_probe tests/libavformat_mixed_audio_probe.mm)
  target_link_libraries(wam_libavformat_mixed_audio_probe PRIVATE wam_macos_native_backend)
endif()
if(BUILD_TESTING AND APPLE AND WAM_ENABLE_AVFORMAT_STAGE)
  add_executable(wam_libavformat_mixed_decode_test tests/libavformat_mixed_decode_test.mm)
  target_link_libraries(wam_libavformat_mixed_decode_test PRIVATE wam_macos_native_backend)
endif()

if(BUILD_TESTING AND APPLE AND WAM_ENABLE_AVFORMAT_STAGE)
  find_program(WAM_MIXED_FFPROBE ffprobe REQUIRED)
  set(WAM_MIXED_FIXTURES "${CMAKE_SOURCE_DIR}/test-media/native-coverage/phase2e")
  add_executable(wam_libavformat_mixed_source_test tests/libavformat_mixed_source_test.mm)
  target_link_libraries(wam_libavformat_mixed_source_test PRIVATE wam_macos_native_backend)
  add_test(NAME libavformat_mixed_fixtures COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_SOURCE_DIR}/tests/libavformat_mixed_fixtures.py" --root "${WAM_MIXED_FIXTURES}" --ffmpeg "${WAM_AVCODEC_FIXTURE_FFMPEG}")
  set_tests_properties(libavformat_mixed_fixtures PROPERTIES FIXTURES_SETUP mixed_media TIMEOUT 60)
  add_test(NAME libavformat_mixed_exact COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_SOURCE_DIR}/tests/libavformat_mixed_proof.py"
    --video-probe "$<TARGET_FILE:wam_libavformat_mixed_decode_test>"
    --audio-probe "$<TARGET_FILE:wam_libavformat_mixed_audio_probe>"
    --ffmpeg "${WAM_AVCODEC_FIXTURE_FFMPEG}" --ffprobe "${WAM_MIXED_FFPROBE}"
    --output "${CMAKE_BINARY_DIR}/mixed-proof.json" --equal-endpoints
    --asset "${WAM_MIXED_FIXTURES}/mixed-fragmented.mp4" --asset "${WAM_MIXED_FIXTURES}/mixed.flv"
    --asset "${WAM_MIXED_FIXTURES}/mixed-opus.mkv")
  set_tests_properties(libavformat_mixed_exact PROPERTIES FIXTURES_REQUIRED mixed_media TIMEOUT 120)
  set_tests_properties(libavformat_flv_audio_refusal PROPERTIES FIXTURES_REQUIRED mixed_media)
  add_test(NAME libavformat_flv_audio_exact COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_SOURCE_DIR}/tests/libavformat_mixed_proof.py"
    --video-probe "$<TARGET_FILE:wam_libavformat_mixed_decode_test>"
    --audio-probe "$<TARGET_FILE:wam_libavformat_mixed_audio_probe>"
    --ffmpeg "${WAM_AVCODEC_FIXTURE_FFMPEG}" --ffprobe "${WAM_MIXED_FFPROBE}"
    --output "${CMAKE_BINARY_DIR}/phase3-flv-proof.json" --asset "${WAM_AVFORMAT_FIXTURES}/h264-aac.flv")
  set_tests_properties(libavformat_flv_audio_exact PROPERTIES FIXTURES_REQUIRED avformat_media TIMEOUT 30)
  add_test(NAME libavformat_mixed_routed COMMAND wam_libavformat_mixed_source_test "${WAM_MIXED_FIXTURES}/mixed-fragmented.mp4")
  add_test(NAME libavformat_opus_mode_refusal COMMAND wam_libavformat_source_test "${WAM_MIXED_FIXTURES}/mixed-hybrid.mkv" "LibavformatOpusModeUnqualified")
  set_tests_properties(libavformat_mixed_routed libavformat_opus_mode_refusal PROPERTIES FIXTURES_REQUIRED mixed_media TIMEOUT 30)
endif()

if(BUILD_TESTING AND APPLE AND (WAM_ENABLE_AVCODEC_STAGE OR WAM_ENABLE_AVFORMAT_STAGE))
  add_library(wam_coexistence_fake_mpv SHARED tests/fakes/mpv_runtime/fake_mpv.cpp)
  target_compile_definitions(wam_coexistence_fake_mpv PRIVATE WAM_FAKE_MPV_NEWER_MINOR=1)
  target_link_libraries(wam_coexistence_fake_mpv PRIVATE wam_mpv_headers)
  set_target_properties(wam_coexistence_fake_mpv PROPERTIES PREFIX "" OUTPUT_NAME WAMMpvFallback)
  add_executable(wam_ffmpeg_coexistence_test tests/ffmpeg_coexistence_test.cpp)
  target_link_libraries(wam_ffmpeg_coexistence_test PRIVATE wam_avcodec_worker wam_mpv_runtime)
  add_test(NAME ffmpeg_coexistence COMMAND wam_ffmpeg_coexistence_test "$<TARGET_FILE:wam_coexistence_fake_mpv>")
endif()

if(BUILD_TESTING AND APPLE)
  add_executable(wam_software_color_qualification_test tests/software_color_qualification_test.cpp)
  target_include_directories(wam_software_color_qualification_test PRIVATE src)
  add_test(NAME software_color_qualification COMMAND wam_software_color_qualification_test)
endif()

if(WAM_BUILD_WAMKIT)
  add_subdirectory(src/wamkit)
endif()
