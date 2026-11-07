# Seam-enabled twins of the production libraries, for tests.
#
# wam_add_test_seams_twins(<lib>...) defines <lib>_test_seams for each named
# library: the same sources, flags and dependencies, compiled with
# WAM_NATIVE_TEST_SEAMS=1 (src/platform/macos/native_test_seams.hpp), with every
# dependency on another named library redirected to that library's twin. The
# definition is PUBLIC so a test sees the class layout its twin was compiled
# with. A binary links twins or production libraries, never both. Shipping
# targets link only the production libraries and never see the macro.
#
# Twins carry the WAM_TEST_SEAMS_TWIN property, which source files may use to
# add test-build-only flags (see the strict audio warnings below).
function(wam_add_test_seams_twins)
  set(twinned "")
  foreach(library IN LISTS ARGN)
    if(TARGET ${library})
      list(APPEND twinned ${library})
    endif()
  endforeach()
  foreach(library IN LISTS twinned)
    set(twin ${library}_test_seams)
    get_target_property(sources ${library} SOURCES)
    add_library(${twin} STATIC EXCLUDE_FROM_ALL ${sources})
    foreach(property IN ITEMS
        COMPILE_DEFINITIONS COMPILE_OPTIONS COMPILE_FEATURES
        INCLUDE_DIRECTORIES INTERFACE_COMPILE_DEFINITIONS
        INTERFACE_COMPILE_OPTIONS INTERFACE_COMPILE_FEATURES
        INTERFACE_INCLUDE_DIRECTORIES INTERFACE_SYSTEM_INCLUDE_DIRECTORIES
        LINK_LIBRARIES INTERFACE_LINK_LIBRARIES LINKER_LANGUAGE
        AUTOMOC AUTOUIC AUTORCC)
      get_target_property(value ${library} ${property})
      if(property MATCHES "^AUTO" AND NOT value)
        set(value OFF)
      elseif(NOT value)
        continue()
      endif()
      if(property MATCHES "LINK_LIBRARIES$")
        foreach(other IN LISTS twinned)
          list(TRANSFORM value REPLACE "^${other}$" "${other}_test_seams")
          list(TRANSFORM value REPLACE "^\\$<LINK_ONLY:${other}>$"
            "$<LINK_ONLY:${other}_test_seams>")
        endforeach()
      endif()
      set_property(TARGET ${twin} PROPERTY ${property} "${value}")
    endforeach()
    target_compile_definitions(${twin} PUBLIC WAM_NATIVE_TEST_SEAMS=1)
    set_property(TARGET ${twin} PROPERTY WAM_TEST_SEAMS_TWIN ON)
  endforeach()
endfunction()

wam_add_test_seams_twins(
  wam_avcodec_worker
  wam_native_core
  wam_macos_native_video_core
  wam_macos_native_layer
  wam_macos_native_backend
  wam_macos_native_session_system
  wam_macos_native_qt_tracked)

# The audio pipeline compiles with a stricter warning set in its test twins,
# where the audio session and device-recovery tests exercise it.
set(wam_strict_audio_warnings -Werror -Wconversion -Wsign-conversion -Wshadow
  -Wundef -Wcast-align -Wformat=2 -Wimplicit-fallthrough)
list(TRANSFORM wam_strict_audio_warnings PREPEND
  "$<$<AND:$<PLATFORM_ID:Darwin>,$<BOOL:$<TARGET_PROPERTY:WAM_TEST_SEAMS_TWIN>>>:")
list(TRANSFORM wam_strict_audio_warnings APPEND ">")
set_property(SOURCE
    src/media/native_media_source.cpp
    src/media/native_media_dispatcher.cpp
    src/media/adpcm_decoder.cpp
    src/media/audio_downmix.cpp
    src/media/native_pcm_ring.cpp
    src/media/native_media_clock.cpp
    src/media/native_audio_render_core.cpp
    src/platform/macos/native_audio_converter.mm
    src/platform/macos/native_audio_converter_backends.mm
    src/platform/macos/native_audio_stretch_stage.mm
    src/platform/macos/native_audio_output.mm
    src/platform/macos/native_audio_session.mm
  APPEND PROPERTY COMPILE_OPTIONS ${wam_strict_audio_warnings})
