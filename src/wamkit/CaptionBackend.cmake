option(WAM_ENABLE_APPLE_CAPTIONS "Build SpeechAnalyzer when the SDK provides it" ON)
set(WAM_HAS_SPEECH_ANALYZER OFF)
if(APPLE AND WAM_ENABLE_APPLE_CAPTIONS)
  find_program(WAM_SWIFTC swiftc)
  if(WAM_SWIFTC)
    execute_process(COMMAND xcrun --show-sdk-path OUTPUT_VARIABLE WAM_CAPTION_SDK OUTPUT_STRIP_TRAILING_WHITESPACE)
    execute_process(COMMAND xcrun --find swiftc OUTPUT_VARIABLE WAM_CAPTION_SWIFTC OUTPUT_STRIP_TRAILING_WHITESPACE)
    file(WRITE "${CMAKE_BINARY_DIR}/caption-sdk-probe.swift"
      "import Speech\n@available(macOS 26, *) func probe(_ a: SpeechAnalyzer) {}\n")
    execute_process(COMMAND "${WAM_CAPTION_SWIFTC}" -typecheck
      -sdk "${WAM_CAPTION_SDK}" -module-cache-path "${CMAKE_BINARY_DIR}/caption-swift-cache"
      "${CMAKE_BINARY_DIR}/caption-sdk-probe.swift"
      RESULT_VARIABLE WAM_CAPTION_SDK_RESULT OUTPUT_QUIET ERROR_QUIET)
    if(WAM_CAPTION_SDK_RESULT EQUAL 0)
      set(WAM_HAS_SPEECH_ANALYZER ON)
    endif()
  endif()
endif()
if(WAM_HAS_SPEECH_ANALYZER)
  set(caption_archive "${CMAKE_BINARY_DIR}/libWAMCaption.a")
  add_custom_command(OUTPUT "${caption_archive}"
    COMMAND "${WAM_CAPTION_SWIFTC}" -parse-as-library -O -emit-library -static
      -module-name WAMCaption -target "${CMAKE_SYSTEM_PROCESSOR}-apple-macos${CMAKE_OSX_DEPLOYMENT_TARGET}"
      -sdk "${WAM_CAPTION_SDK}" -module-cache-path "${CMAKE_BINARY_DIR}/caption-swift-cache"
      "${PROJECT_SOURCE_DIR}/src/wamkit/apple_caption.swift" -o "${caption_archive}"
    DEPENDS "${PROJECT_SOURCE_DIR}/src/wamkit/apple_caption.swift")
  add_custom_target(wam_caption_swift DEPENDS "${caption_archive}")
  add_library(wam_caption_runtime INTERFACE)
  add_dependencies(wam_caption_runtime wam_caption_swift)
  get_filename_component(swift_bin "${WAM_CAPTION_SWIFTC}" DIRECTORY)
  target_link_directories(wam_caption_runtime INTERFACE "${swift_bin}/../lib/swift/macosx" "${WAM_CAPTION_SDK}/usr/lib/swift")
  target_link_libraries(wam_caption_runtime INTERFACE "${caption_archive}"
    "-framework Foundation" "-framework AVFoundation" "-framework CoreMedia")
  target_link_options(wam_caption_runtime INTERFACE "LINKER:-weak_framework,Speech" "LINKER:-rpath,/usr/lib/swift")
else()
  add_library(wam_caption_runtime STATIC "${PROJECT_SOURCE_DIR}/src/wamkit/caption_stub.cpp")
endif()
message(STATUS "Apple SpeechAnalyzer caption backend: ${WAM_HAS_SPEECH_ANALYZER}")
# CaptionService is also compiled directly into controller fixtures.
link_libraries(wam_caption_runtime)
add_compile_definitions(WAM_CAPTION_ABI=1)

if(APPLE)
  add_library(wam_caption_prompt STATIC "${PROJECT_SOURCE_DIR}/src/qt/caption_download_prompt.mm")
  target_compile_options(wam_caption_prompt PRIVATE -fobjc-arc)
  target_link_libraries(wam_caption_prompt PRIVATE "-framework AppKit")
  link_libraries(wam_caption_prompt)
endif()
