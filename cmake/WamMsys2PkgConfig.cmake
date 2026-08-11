function(wam_rebase_msys2_path output_variable msys2_root input_path)
  if(input_path MATCHES "^/[^/]")
    string(REGEX REPLACE "^/" "" relative_path "${input_path}")
    cmake_path(SET native_path NORMALIZE "${msys2_root}")
    cmake_path(APPEND native_path "${relative_path}")
  else()
    set(native_path "${input_path}")
  endif()

  set(${output_variable} "${native_path}" PARENT_SCOPE)
endfunction()

function(wam_normalize_msys2_pkgconfig_target target)
  if(NOT WIN32 OR "$ENV{MSYSTEM}" STREQUAL "")
    return()
  endif()

  find_program(wam_cygpath NAMES cygpath REQUIRED NO_CACHE)
  execute_process(
    COMMAND "${wam_cygpath}" -m /
    RESULT_VARIABLE cygpath_result
    OUTPUT_VARIABLE msys2_root
    ERROR_VARIABLE cygpath_error
    OUTPUT_STRIP_TRAILING_WHITESPACE)
  if(NOT cygpath_result EQUAL 0 OR msys2_root STREQUAL "")
    message(FATAL_ERROR
      "Unable to resolve the MSYS2 root with cygpath: ${cygpath_error}")
  endif()

  foreach(property IN ITEMS
      INTERFACE_INCLUDE_DIRECTORIES
      INTERFACE_LINK_DIRECTORIES
      INTERFACE_LINK_LIBRARIES)
    get_target_property(property_values "${target}" "${property}")
    if(NOT property_values OR property_values MATCHES "-NOTFOUND$")
      set(property_values "")
    endif()

    if(property STREQUAL "INTERFACE_LINK_DIRECTORIES")
      list(APPEND property_values ${ARGN})
    endif()

    set(native_values "")
    foreach(value IN LISTS property_values)
      wam_rebase_msys2_path(native_value "${msys2_root}" "${value}")
      list(APPEND native_values "${native_value}")
    endforeach()
    list(REMOVE_DUPLICATES native_values)

    if(native_values)
      set_property(TARGET "${target}" PROPERTY "${property}" "${native_values}")
    endif()
  endforeach()

  message(STATUS
    "Normalized ${target} paths against MSYS2 root ${msys2_root}")
endfunction()
