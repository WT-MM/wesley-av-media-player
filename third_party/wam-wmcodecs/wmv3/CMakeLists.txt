# SPDX-License-Identifier: LGPL-2.1-or-later
# WMV3 video decoder unit test. The decoder itself is built into
# libwam-wmcodecs (../CMakeLists.txt); WAM's MIT code only dlopens it.
enable_language(C)

if(BUILD_TESTING)
  add_executable(wam_wmv3_test wmv3_test.c wmv3_dsp.c)
  set_target_properties(wam_wmv3_test PROPERTIES C_STANDARD 11)
  add_test(NAME wmv3_decoder COMMAND wam_wmv3_test)
endif()
