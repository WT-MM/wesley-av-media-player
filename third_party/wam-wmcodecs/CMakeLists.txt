# SPDX-License-Identifier: LGPL-2.1-or-later
#
# LGPL-2.1-or-later WMA decoder. Always a shared library: MIT targets may
# link it dynamically only, never statically.
add_library(wam_wmcodecs SHARED
  include/wam_wmcodecs.h
  src/wma_decoder.cpp
  src/wma_tables.h)
set_target_properties(wam_wmcodecs PROPERTIES
  OUTPUT_NAME wam-wmcodecs
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON)
target_include_directories(wam_wmcodecs PUBLIC include)
target_compile_features(wam_wmcodecs PRIVATE cxx_std_20)
target_compile_options(wam_wmcodecs PRIVATE -Wall -Wextra -O3)
target_link_libraries(wam_wmcodecs PRIVATE "-framework Accelerate")
