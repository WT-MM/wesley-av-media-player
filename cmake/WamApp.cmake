
# 6.10 is the floor: nothing here needs a newer API, and the Windows lane
# takes the newest Qt its installer can resolve (6.10.3); macOS and Linux
# still build against the pinned Qt (packaging/pins.env).
find_package(Qt6 6.10 REQUIRED COMPONENTS
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
  # its compatibility client, but it must not acquire a load command
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
  # These two integration tests intentionally exercise a real linked
  # mpv client through an injected table. Keep that strong dependency private
  # to tests; the shipping executable sees only wam_mpv_headers.
  pkg_check_modules(MPV_TEST_LINK REQUIRED IMPORTED_TARGET mpv)
  set(WAM_MPV_INTEGRATION_TEST_TARGET PkgConfig::MPV_TEST_LINK)
else()
  set(WAM_MPV_INTEGRATION_TEST_TARGET PkgConfig::MPV)
endif()

qt_standard_project_setup(REQUIRES 6.10)

qt_add_executable(wam MACOSX_BUNDLE WIN32
  src/qt/main.cpp
  src/qt/player_controller.cpp
  src/qt/player_controller.hpp
  src/qt/app_settings.cpp
  src/qt/app_settings.hpp
  src/qt/mpv_engine.cpp
  src/qt/mpv_engine.hpp
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
  src/qt/media_url.cpp
  src/qt/media_url.hpp
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
    qml/Scrubber.qml
    qml/AppMenuBar.qml
    qml/AppMenu.qml)

target_include_directories(wam PRIVATE src)
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
  wam_mpv_headers
  wam_caption_runtime)

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
    wam_mpv_headers
  PRIVATE
    wam_pins)
if(CMAKE_DL_LIBS)
  target_link_libraries(wam_mpv_runtime PRIVATE ${CMAKE_DL_LIBS})
endif()
target_link_libraries(wam PRIVATE wam_mpv_runtime)
if(NOT APPLE)
  target_link_libraries(wam PRIVATE wam_native_core)
endif()

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
  set(WAM_STAGED_FFMPEG "${CMAKE_CURRENT_BINARY_DIR}/runtime/ffmpeg${CMAKE_EXECUTABLE_SUFFIX}")
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

  add_library(wam_macos_native_qt_tracked STATIC
    src/qt/macos/native_qt_gl_output.hpp
    src/qt/macos/native_qt_gl_output.mm
    src/qt/macos/qt_gl_video_item.hpp
    src/qt/macos/qt_gl_video_item.mm)
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
  target_sources(wam PRIVATE
    src/qt/macos_window_chrome.hpp
    src/qt/macos_window_chrome.mm
    src/qt/macos_video_service_cleanup.mm)
  # ARC only for the window-chrome helper: the playback .mm sources are
  # ARC-agnostic by design and pay per-frame retain/release costs under ARC.
  set_source_files_properties(src/qt/macos_window_chrome.mm PROPERTIES
    COMPILE_OPTIONS "-fobjc-arc")
  target_link_libraries(wam PRIVATE
    "${WAM_APPKIT_FRAMEWORK}"
    "${WAM_QUARTZCORE_FRAMEWORK}"
    "${WAM_AVFOUNDATION_FRAMEWORK}")
  set_target_properties(wam PROPERTIES LINKER_LANGUAGE OBJCXX)

  # The AppKit consent alert shown before a caption engine download.
  add_library(wam_caption_prompt STATIC src/qt/caption_download_prompt.mm)
  target_compile_options(wam_caption_prompt PRIVATE -fobjc-arc)
  target_link_libraries(wam_caption_prompt PRIVATE "${WAM_APPKIT_FRAMEWORK}")
  set_target_properties(wam_caption_prompt PROPERTIES AUTOMOC OFF)
  target_link_libraries(wam PRIVATE wam_caption_prompt)

  if(WAM_ENABLE_MACOS_NATIVE_VIDEO)

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
      src/qt/macos/qt_native_presentation_adapter.mm)
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
      src/platform/macos/core_media_carriage.hpp
      src/platform/macos/core_media_carriage.mm
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

if(WAM_ENABLE_AVCODEC_STAGE OR WAM_ENABLE_AVFORMAT_STAGE)
  set_property(TARGET wam APPEND PROPERTY BUILD_RPATH "@executable_path/../Frameworks")
  set_property(TARGET wam APPEND PROPERTY INSTALL_RPATH "@executable_path/../Frameworks")
  file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/native-codecs")
  set(WAM_NATIVE_FFMPEG_LIBRARIES ${WAM_NATIVE_AVCODEC_DYLIB} ${WAM_NATIVE_AVUTIL_DYLIB})
  if(WAM_ENABLE_AVFORMAT_STAGE)
    list(APPEND WAM_NATIVE_FFMPEG_LIBRARIES ${WAM_NATIVE_AVFORMAT_DYLIB})
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

set(CPACK_PACKAGE_NAME "WAM")
set(CPACK_PACKAGE_VENDOR "Wesley Maa")
set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
if(WIN32)
  set(CPACK_GENERATOR "ZIP")
else()
  set(CPACK_GENERATOR "TGZ")
endif()
include(CPack)
