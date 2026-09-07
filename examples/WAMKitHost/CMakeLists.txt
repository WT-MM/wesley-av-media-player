enable_language(OBJC)
add_executable(WAMKitHost MACOSX_BUNDLE main.m)
set_target_properties(WAMKitHost PROPERTIES AUTOMOC OFF AUTOUIC OFF AUTORCC OFF
  MACOSX_BUNDLE_GUI_IDENTIFIER org.wam.WAMKitHost
  BUILD_RPATH "@executable_path/../Frameworks" BUILD_WITH_INSTALL_RPATH YES
  INSTALL_RPATH "@executable_path/../Frameworks")
target_compile_options(WAMKitHost PRIVATE -fobjc-arc -Wall -Wextra)
target_link_libraries(WAMKitHost PRIVATE WAMKit "-framework AppKit")
add_custom_command(TARGET WAMKitHost POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_DIR:WAMKitHost>/Contents/Frameworks"
  COMMAND ${CMAKE_COMMAND} -E rm -rf "$<TARGET_BUNDLE_DIR:WAMKitHost>/Contents/Frameworks/WAMKit.framework"
  COMMAND /usr/bin/ditto "$<TARGET_BUNDLE_DIR:WAMKit>" "$<TARGET_BUNDLE_DIR:WAMKitHost>/Contents/Frameworks/WAMKit.framework"
  COMMAND codesign --force --sign - "$<TARGET_BUNDLE_DIR:WAMKitHost>"
  COMMAND codesign --verify --deep --strict "$<TARGET_BUNDLE_DIR:WAMKitHost>")
target_link_options(WAMKitHost PRIVATE "LINKER:-rpath,@executable_path/../Frameworks")
if(BUILD_TESTING)
  add_test(NAME wamkit_host_packaging COMMAND "${Python3_EXECUTABLE}" "${PROJECT_SOURCE_DIR}/scripts/audit_wamkit.py"
    --framework "$<TARGET_BUNDLE_DIR:WAMKitHost>/Contents/Frameworks/WAMKit.framework"
    --exports "${PROJECT_SOURCE_DIR}/src/wamkit/exports.txt"
    --output "/private/tmp/wam-wamkit-scratch/host-packaging-audit.json")
endif()
