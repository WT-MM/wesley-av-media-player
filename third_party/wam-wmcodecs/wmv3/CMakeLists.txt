# SPDX-License-Identifier: LGPL-2.1-or-later
# WMV3 video decoder: a separate LGPL shared library (see ../NOTICE). WAM's
# MIT code must only link to it dynamically.
enable_language(C)

add_library(wam_wmv3 SHARED wmv3dec.c wmv3_dsp.c)
target_include_directories(wam_wmv3 PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
set_target_properties(wam_wmv3 PROPERTIES C_STANDARD 11 C_VISIBILITY_PRESET hidden)
target_compile_definitions(wam_wmv3 PRIVATE "WMV3_API=__attribute__((visibility(\"default\")))")
target_compile_options(wam_wmv3 PRIVATE -O3)

if(BUILD_TESTING)
  add_executable(wam_wmv3_test wmv3_test.c wmv3_dsp.c)
  set_target_properties(wam_wmv3_test PROPERTIES C_STANDARD 11)
  add_test(NAME wmv3_decoder COMMAND wam_wmv3_test)
endif()
