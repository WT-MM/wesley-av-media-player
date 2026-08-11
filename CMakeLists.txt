cmake_minimum_required(VERSION 3.24)

# Qt 6.11 supports macOS 13 and newer. Pin the executable's load-command floor
# instead of inheriting the build machine's current SDK version.
if(APPLE AND NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING
      "Minimum supported macOS version")
endif()

project(WAM VERSION 0.3.1 LANGUAGES CXX)

option(WAM_ENABLE_MACOS_NATIVE_VIDEO
  "Build the experimental VideoToolbox/IOSurface/Metal presenter foundation"
  OFF)
set(WAM_NATIVE_VIDEO_TEST_FIXTURE "" CACHE FILEPATH
  "Optional H.264 B-frame fixture used by the macOS VideoToolbox test")

if(WAM_ENABLE_MACOS_NATIVE_VIDEO AND NOT APPLE)
  message(FATAL_ERROR
    "WAM_ENABLE_MACOS_NATIVE_VIDEO is available only on macOS")
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
  OpenGL)
find_package(PkgConfig REQUIRED)
pkg_check_modules(MPV REQUIRED IMPORTED_TARGET mpv)

qt_standard_project_setup(REQUIRES 6.11)

qt_add_executable(wam MACOSX_BUNDLE WIN32
  src/qt/main.cpp
  src/qt/player_controller.cpp
  src/qt/player_controller.hpp
  src/qt/player_core.cpp
  src/qt/player_core_p.hpp
  src/qt/playback_policy.hpp
  src/qt/mpv_video_item.cpp
  src/qt/mpv_video_item.hpp
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
    qml/IconButton.qml
    qml/QuietButton.qml
    qml/QuickEditSheet.qml
    qml/Scrubber.qml)

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
  PkgConfig::MPV)

if(MSVC)
  target_compile_options(wam PRIVATE /W4 /permissive-)
else()
  target_compile_options(wam PRIVATE -Wall -Wextra -Wpedantic)
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
    BUILD_RPATH "/opt/homebrew/lib;/opt/homebrew/opt/qt/lib"
    INSTALL_RPATH "@executable_path/../Frameworks")

  if(WAM_ENABLE_MACOS_NATIVE_VIDEO)
    enable_language(OBJCXX)
    find_library(WAM_COREFOUNDATION_FRAMEWORK CoreFoundation REQUIRED)
    find_library(WAM_COREMEDIA_FRAMEWORK CoreMedia REQUIRED)
    find_library(WAM_COREVIDEO_FRAMEWORK CoreVideo REQUIRED)
    find_library(WAM_FOUNDATION_FRAMEWORK Foundation REQUIRED)
    find_library(WAM_IOSURFACE_FRAMEWORK IOSurface REQUIRED)
    find_library(WAM_METAL_FRAMEWORK Metal REQUIRED)
    find_library(WAM_VIDEOTOOLBOX_FRAMEWORK VideoToolbox REQUIRED)

    add_library(wam_macos_native_video STATIC
      src/platform/macos/native_video_presenter.hpp
      src/platform/macos/native_video_presenter.mm
      src/platform/macos/video_toolbox_decoder.hpp
      src/platform/macos/video_toolbox_decoder.mm)
    target_include_directories(wam_macos_native_video PUBLIC src)
    target_compile_features(wam_macos_native_video PUBLIC cxx_std_20)
    target_compile_options(wam_macos_native_video PRIVATE
      "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
      -Wall -Wextra -Wpedantic)
    target_link_libraries(wam_macos_native_video PUBLIC
      "${WAM_COREFOUNDATION_FRAMEWORK}"
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_COREVIDEO_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_IOSURFACE_FRAMEWORK}"
      "${WAM_METAL_FRAMEWORK}"
      "${WAM_VIDEOTOOLBOX_FRAMEWORK}")

    # Linking the inert foundation proves it coexists with the shipping app.
    # No runtime code selects it yet, so libmpv remains the only default path.
    target_link_libraries(wam PRIVATE wam_macos_native_video)
    target_compile_definitions(wam PRIVATE WAM_HAS_MACOS_NATIVE_VIDEO=1)
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

install(FILES README.md THIRD_PARTY_NOTICES.md DESTINATION share/doc/wam)

include(CTest)
if(BUILD_TESTING)
  add_executable(wam_playback_policy_test tests/playback_policy_test.cpp)
  target_include_directories(wam_playback_policy_test PRIVATE src)
  add_test(NAME playback_policy COMMAND wam_playback_policy_test)

  add_executable(wam_jobs_test tests/jobs_test.cpp src/jobs.cpp src/jobs.hpp)
  target_include_directories(wam_jobs_test PRIVATE src)
  add_test(NAME jobs COMMAND wam_jobs_test)

  add_executable(wam_state_test
    tests/state_store_test.cpp src/state_store.cpp src/state_store.hpp)
  target_include_directories(wam_state_test PRIVATE src)
  add_test(NAME state_store COMMAND wam_state_test)

  add_executable(wam_caption_test
    tests/caption_service_test.cpp
    src/caption_service.cpp
    src/caption_service.hpp
    src/jobs.cpp
    src/jobs.hpp)
  target_include_directories(wam_caption_test PRIVATE src)
  add_test(NAME caption_service COMMAND wam_caption_test)

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

    if(WAM_ENABLE_MACOS_NATIVE_VIDEO)
      add_executable(wam_native_video_test
        tests/native_video_presenter_test.mm)
      target_link_libraries(wam_native_video_test PRIVATE
        wam_macos_native_video)
      target_compile_options(wam_native_video_test PRIVATE
        "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
        -Wall -Wextra -Wpedantic)
      set_target_properties(wam_native_video_test PROPERTIES
        LINKER_LANGUAGE OBJCXX)
      add_test(NAME macos_native_video COMMAND wam_native_video_test)
      set_tests_properties(macos_native_video PROPERTIES SKIP_RETURN_CODE 77)

      find_library(WAM_AVFOUNDATION_FRAMEWORK AVFoundation REQUIRED)
      add_executable(wam_video_toolbox_decoder_test
        tests/video_toolbox_decoder_test.mm)
      target_link_libraries(wam_video_toolbox_decoder_test PRIVATE
        wam_macos_native_video
        "${WAM_AVFOUNDATION_FRAMEWORK}")
      target_compile_options(wam_video_toolbox_decoder_test PRIVATE
        "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
        -Wall -Wextra -Wpedantic)
      set_target_properties(wam_video_toolbox_decoder_test PROPERTIES
        LINKER_LANGUAGE OBJCXX)
      set(WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE
        "${WAM_NATIVE_VIDEO_TEST_FIXTURE}")
      if(NOT WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE AND
          EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/test-media/sample-h264.mp4")
        set(WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE
          "${CMAKE_CURRENT_SOURCE_DIR}/test-media/sample-h264.mp4")
      endif()
      if(WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE AND
          EXISTS "${WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE}")
        add_test(NAME macos_video_toolbox_decoder
          COMMAND wam_video_toolbox_decoder_test
            "${WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE}")
        set_tests_properties(macos_video_toolbox_decoder PROPERTIES
          TIMEOUT 30)
      else()
        message(WARNING
          "Native VideoToolbox test target built without an H.264 fixture; "
          "set WAM_NATIVE_VIDEO_TEST_FIXTURE to register it with CTest")
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
