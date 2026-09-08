if(NOT APPLE)
  message(FATAL_ERROR "WAMKit requires macOS")
endif()
add_library(wamkit_public_layer STATIC
  ../platform/macos/native_layer_video_output.mm ../platform/macos/native_layer_host_view.mm
  ../platform/macos/native_embedding_support.mm)
target_include_directories(wamkit_public_layer PRIVATE "${PROJECT_SOURCE_DIR}/src")
target_compile_options(wamkit_public_layer PRIVATE -fobjc-arc)
target_compile_definitions(wamkit_public_layer PRIVATE WAM_PUBLIC_PRESENTATION_API=1)
target_link_libraries(wamkit_public_layer PUBLIC wam_macos_native_video_core
  "-framework AppKit" "-framework AVFoundation" "-framework QuartzCore" "-framework CoreImage")
add_library(WAMKit SHARED wamkit.mm include/WAMKit/WAMKit.h include/WAMKit/WAMKitObjC.h)
set_target_properties(WAMKit PROPERTIES FRAMEWORK TRUE FRAMEWORK_VERSION A
  MACOSX_FRAMEWORK_IDENTIFIER org.wam.WAMKit VERSION 1.0.0 SOVERSION 1
  PUBLIC_HEADER "include/WAMKit/WAMKit.h;include/WAMKit/WAMKitObjC.h"
  CXX_VISIBILITY_PRESET hidden OBJCXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN YES
  INSTALL_NAME_DIR "@rpath" BUILD_WITH_INSTALL_NAME_DIR YES)
target_include_directories(WAMKit PRIVATE "${PROJECT_SOURCE_DIR}/src" include)
target_compile_options(WAMKit PRIVATE -fobjc-arc -Wall -Wextra)
target_link_libraries(WAMKit PRIVATE wam_macos_native_session_system wamkit_public_layer "-framework AppKit")
target_link_options(WAMKit PRIVATE "LINKER:-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/exports.txt")
set_property(TARGET WAMKit APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/exports.txt" "${PROJECT_SOURCE_DIR}/scripts/package_wamkit.py")
add_custom_command(TARGET WAMKit POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_DIR:WAMKit>/Versions/A/Modules"
  COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_CURRENT_SOURCE_DIR}/module.modulemap" "$<TARGET_BUNDLE_DIR:WAMKit>/Versions/A/Modules/module.modulemap")
install(TARGETS WAMKit FRAMEWORK DESTINATION Library/Frameworks COMPONENT WAMKit)

find_package(Python3 REQUIRED COMPONENTS Interpreter)
add_custom_command(TARGET WAMKit POST_BUILD
  COMMAND "${Python3_EXECUTABLE}" "${PROJECT_SOURCE_DIR}/scripts/package_wamkit.py"
    --framework "$<TARGET_BUNDLE_DIR:WAMKit>" --source "${PROJECT_SOURCE_DIR}" --ffmpeg "${WAM_FFMPEG_LGPL_ROOT}")
if(BUILD_TESTING)
  add_test(NAME wamkit_abi COMMAND "${Python3_EXECUTABLE}" "${PROJECT_SOURCE_DIR}/tests/wamkit_abi_test.py"
    "$<TARGET_FILE:WAMKit>" "${CMAKE_CURRENT_SOURCE_DIR}/exports.txt")
  add_test(NAME wamkit_headers COMMAND "${Python3_EXECUTABLE}" "${PROJECT_SOURCE_DIR}/tests/wamkit_header_test.py"
    "$<TARGET_BUNDLE_DIR:WAMKit>")
endif()

option(WAMKIT_ENABLE_TEST_SUPPORT "Enable private identity-gated quiet proof seams" OFF)
if(WAMKIT_ENABLE_TEST_SUPPORT)
  target_compile_definitions(WAMKit PRIVATE WAMKIT_ENABLE_TEST_SUPPORT=1)
endif()
option(WAMKIT_BUILD_HOST "Build the non-Qt AppKit embedding example" ${APPLE})
if(WAMKIT_BUILD_HOST)
  add_subdirectory("${PROJECT_SOURCE_DIR}/examples/WAMKitHost" "${PROJECT_BINARY_DIR}/examples/WAMKitHost")
endif()

if(BUILD_TESTING AND WAMKIT_BUILD_HOST AND WAMKIT_ENABLE_TEST_SUPPORT)
  find_program(WAMKIT_FIXTURE_FFMPEG ffmpeg REQUIRED)
  add_custom_command(OUTPUT "${PROJECT_SOURCE_DIR}/test-media/wamkit/manifest.json"
    BYPRODUCTS "${PROJECT_SOURCE_DIR}/test-media/wamkit/av.mp4" "${PROJECT_SOURCE_DIR}/test-media/wamkit/av.mkv" "${PROJECT_SOURCE_DIR}/test-media/wamkit/refused.m4a"
    COMMAND "${Python3_EXECUTABLE}" "${PROJECT_SOURCE_DIR}/scripts/generate_wamkit_fixtures.py"
      --ffmpeg "${WAMKIT_FIXTURE_FFMPEG}" --output "${PROJECT_SOURCE_DIR}/test-media/wamkit"
    DEPENDS "${PROJECT_SOURCE_DIR}/scripts/generate_wamkit_fixtures.py")
  add_custom_target(wamkit_fixtures DEPENDS "${PROJECT_SOURCE_DIR}/test-media/wamkit/manifest.json")
  add_dependencies(WAMKitHost wamkit_fixtures)
  foreach(kind IN ITEMS mp4 mkv refusal api quarantine replace recovery)
    set(asset "${PROJECT_SOURCE_DIR}/test-media/wamkit/av.${kind}")
    set(arguments --seek)
    if(kind STREQUAL "recovery")
      set(asset "${PROJECT_SOURCE_DIR}/test-media/wamkit/av.mkv")
      set(arguments --seek --device-recovery)
    elseif(kind STREQUAL "refusal")
      set(asset "${PROJECT_SOURCE_DIR}/test-media/wamkit/refused.m4a")
      set(arguments --refusal HeAacSbrDecoderDelayUnproven)
    elseif(kind STREQUAL "replace")
      set(asset "${PROJECT_SOURCE_DIR}/test-media/wamkit/av.mp4")
      set(arguments --replace)
    elseif(kind STREQUAL "quarantine")
      set(asset "${PROJECT_SOURCE_DIR}/test-media/wamkit/av.mp4")
      set(arguments --quarantine)
    elseif(kind STREQUAL "api")
      set(asset "${PROJECT_SOURCE_DIR}/test-media/wamkit/av.mp4")
      set(arguments --api)
    endif()
    add_test(NAME wamkit_host_${kind} COMMAND "${Python3_EXECUTABLE}" "${PROJECT_SOURCE_DIR}/tests/wamkit_embedding_test.py"
      --host "$<TARGET_FILE:WAMKitHost>" --asset "${asset}"
      --output "/private/tmp/wam-wamkit-scratch/ctest-host-${kind}" --unique ${arguments})
    set_tests_properties(wamkit_host_${kind} PROPERTIES RUN_SERIAL TRUE TIMEOUT 30)
  endforeach()
endif()

if(BUILD_TESTING)
  add_test(NAME wamkit_device_recovery COMMAND sh "${PROJECT_SOURCE_DIR}/tests/run_wamkit_device_recovery_test.sh")
endif()

find_program(WAMKIT_SWIFT swift)
find_program(WAMKIT_XCODEBUILD xcodebuild)
if(WAMKIT_XCODEBUILD)
  execute_process(COMMAND "${WAMKIT_XCODEBUILD}" -version RESULT_VARIABLE WAMKIT_XCODE_STATUS OUTPUT_QUIET ERROR_QUIET)
endif()
if(WAMKIT_SWIFT AND WAMKIT_XCODEBUILD AND WAMKIT_XCODE_STATUS EQUAL 0 AND WAMKIT_BUILD_HOST AND CMAKE_HOST_SYSTEM_PROCESSOR STREQUAL "arm64")
  add_custom_target(WAMKitSwiftHost
    COMMAND "${Python3_EXECUTABLE}" "${PROJECT_SOURCE_DIR}/scripts/build_wamkit_swift.py"
      --framework "$<TARGET_BUNDLE_DIR:WAMKit>" --build "${PROJECT_BINARY_DIR}"
    DEPENDS WAMKit USES_TERMINAL)
  if(BUILD_TESTING)
    add_test(NAME wamkit_swift_build COMMAND "${Python3_EXECUTABLE}"
      "${PROJECT_SOURCE_DIR}/scripts/build_wamkit_swift.py"
      --framework "$<TARGET_BUNDLE_DIR:WAMKit>" --build "${PROJECT_BINARY_DIR}")
    set_tests_properties(wamkit_swift_build PROPERTIES RUN_SERIAL TRUE TIMEOUT 300 FIXTURES_SETUP wamkit_swift)
    if(WAMKIT_ENABLE_TEST_SUPPORT)
      foreach(kind IN ITEMS mp4 mkv refusal)
        set(asset "${PROJECT_SOURCE_DIR}/test-media/wamkit/av.${kind}")
        set(arguments --seek)
        if(kind STREQUAL "refusal")
          set(asset "${PROJECT_SOURCE_DIR}/test-media/wamkit/refused.m4a")
          set(arguments --refusal HeAacSbrDecoderDelayUnproven)
        endif()
        add_test(NAME wamkit_swift_${kind} COMMAND "${Python3_EXECUTABLE}"
          "${PROJECT_SOURCE_DIR}/tests/wamkit_embedding_test.py"
          --host "${PROJECT_BINARY_DIR}/examples/WAMKitSwiftHost/WAMKitSwiftHost.app/Contents/MacOS/WAMKitSwiftHost"
          --asset "${asset}" --output "/private/tmp/wam-wamkit-scratch/swift-${kind}" --unique ${arguments})
        set_tests_properties(wamkit_swift_${kind} PROPERTIES RUN_SERIAL TRUE TIMEOUT 30 FIXTURES_REQUIRED wamkit_swift)
      endforeach()
    endif()
  endif()
endif()

if(BUILD_TESTING)
  add_test(NAME wamkit_dogfooding COMMAND "${Python3_EXECUTABLE}" "${PROJECT_SOURCE_DIR}/tests/wamkit_dogfooding_test.py")
endif()
