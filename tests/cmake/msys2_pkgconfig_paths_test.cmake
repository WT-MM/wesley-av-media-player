include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/WamMsys2PkgConfig.cmake")

function(expect_rebased input expected)
  wam_rebase_msys2_path(actual "D:/actions/msys64" "${input}")
  if(NOT actual STREQUAL expected)
    message(FATAL_ERROR
      "Expected '${input}' to become '${expected}', got '${actual}'")
  endif()
endfunction()

expect_rebased("/ucrt64/include" "D:/actions/msys64/ucrt64/include")
expect_rebased("/ucrt64/lib" "D:/actions/msys64/ucrt64/lib")
expect_rebased("/ucrt64/lib/libmpv.dll.a"
  "D:/actions/msys64/ucrt64/lib/libmpv.dll.a")
expect_rebased("mpv" "mpv")
expect_rebased("C:/SDK/include" "C:/SDK/include")
expect_rebased("//server/share/include" "//server/share/include")
