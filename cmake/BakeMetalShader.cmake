if(NOT DEFINED QSB_EXECUTABLE OR NOT DEFINED INPUT OR NOT DEFINED OUTPUT OR
    NOT DEFINED DEPLOYMENT_TARGET)
  message(FATAL_ERROR
    "BakeMetalShader.cmake requires QSB_EXECUTABLE, INPUT, OUTPUT, and "
    "DEPLOYMENT_TARGET")
endif()
if(NOT DEPLOYMENT_TARGET MATCHES "^[0-9]+[.][0-9]+([.][0-9]+)?$")
  message(FATAL_ERROR
    "Invalid macOS shader deployment target: ${DEPLOYMENT_TARGET}")
endif()

get_filename_component(WAM_QSB_OUTPUT_DIRECTORY "${OUTPUT}" DIRECTORY)
file(MAKE_DIRECTORY "${WAM_QSB_OUTPUT_DIRECTORY}")

# qsb invokes a program literally named "xcrun". Newer Xcode releases can
# install the Metal compiler as a cryptex-mounted component without teaching
# the default xcrun proxy where that component lives. Prefer normal xcrun when
# it works; otherwise resolve the current mount from Xcode's component JSON and
# put a tiny, build-local delegating xcrun at the front of qsb's PATH.
execute_process(
  COMMAND /usr/bin/xcrun metal --version
  RESULT_VARIABLE WAM_PLAIN_METAL_RESULT
  OUTPUT_QUIET
  ERROR_QUIET)

set(WAM_XCRUN_DELEGATE "exec /usr/bin/xcrun \"\$@\"")
if(NOT WAM_PLAIN_METAL_RESULT EQUAL 0)
  execute_process(
    COMMAND /usr/bin/xcodebuild -showComponent MetalToolchain -json
    RESULT_VARIABLE WAM_METAL_COMPONENT_RESULT
    OUTPUT_VARIABLE WAM_METAL_COMPONENT_JSON
    ERROR_VARIABLE WAM_METAL_COMPONENT_ERROR)
  if(NOT WAM_METAL_COMPONENT_RESULT EQUAL 0)
    message(FATAL_ERROR
      "Plain xcrun cannot run metal, and Xcode could not resolve its installed "
      "MetalToolchain component:\n${WAM_METAL_COMPONENT_ERROR}")
  endif()

  string(JSON WAM_METAL_COMPONENT_STATUS ERROR_VARIABLE WAM_STATUS_JSON_ERROR
    GET "${WAM_METAL_COMPONENT_JSON}" status)
  string(JSON WAM_METAL_TOOLCHAIN_SEARCH_PATH
    ERROR_VARIABLE WAM_PATH_JSON_ERROR
    GET "${WAM_METAL_COMPONENT_JSON}" toolchainSearchPath)
  if(WAM_STATUS_JSON_ERROR OR WAM_PATH_JSON_ERROR OR
      NOT WAM_METAL_COMPONENT_STATUS STREQUAL "installed" OR
      NOT WAM_METAL_TOOLCHAIN_SEARCH_PATH)
    message(FATAL_ERROR
      "Xcode did not report an installed MetalToolchain with a search path. "
      "Run: xcodebuild -downloadComponent MetalToolchain\n"
      "Component metadata:\n${WAM_METAL_COMPONENT_JSON}")
  endif()

  set(WAM_METAL_XCTOOLCHAIN
    "${WAM_METAL_TOOLCHAIN_SEARCH_PATH}/Metal.xctoolchain")
  execute_process(
    COMMAND /usr/bin/xcrun --toolchain "${WAM_METAL_XCTOOLCHAIN}"
      metal --version
    RESULT_VARIABLE WAM_COMPONENT_METAL_RESULT
    OUTPUT_VARIABLE WAM_COMPONENT_METAL_OUTPUT
    ERROR_VARIABLE WAM_COMPONENT_METAL_ERROR)
  if(NOT WAM_COMPONENT_METAL_RESULT EQUAL 0)
    message(FATAL_ERROR
      "Xcode reports MetalToolchain installed, but its exact toolchain cannot "
      "run metal:\n${WAM_COMPONENT_METAL_OUTPUT}${WAM_COMPONENT_METAL_ERROR}")
  endif()
  set(WAM_XCRUN_DELEGATE
    "exec /usr/bin/xcrun --toolchain '${WAM_METAL_XCTOOLCHAIN}' \"\$@\"")
endif()

get_filename_component(WAM_QSB_OUTPUT_NAME "${OUTPUT}" NAME)
set(WAM_XCRUN_SHIM_DIRECTORY
  "${WAM_QSB_OUTPUT_DIRECTORY}/.${WAM_QSB_OUTPUT_NAME}-tools")
set(WAM_XCRUN_SHIM "${WAM_XCRUN_SHIM_DIRECTORY}/xcrun")
file(MAKE_DIRECTORY "${WAM_XCRUN_SHIM_DIRECTORY}")
file(WRITE "${WAM_XCRUN_SHIM}"
  "#!/bin/sh\n${WAM_XCRUN_DELEGATE}\n")
file(CHMOD "${WAM_XCRUN_SHIM}"
  PERMISSIONS
    OWNER_READ OWNER_WRITE OWNER_EXECUTE
    GROUP_READ GROUP_EXECUTE
    WORLD_READ WORLD_EXECUTE)

# Invoke qsb directly so this gate can select Xcode's optional Metal toolchain,
# propagate WAM's deployment floor, and inspect the resulting bytecode. qsb
# 6.11 may still exit zero when Apple's optional compiler is absent, so verify
# the serialized artifact rather than trusting the process status alone.
execute_process(
  COMMAND "${CMAKE_COMMAND}" -E env
    "PATH=${WAM_XCRUN_SHIM_DIRECTORY}:$ENV{PATH}"
    "MACOSX_DEPLOYMENT_TARGET=${DEPLOYMENT_TARGET}"
    "${QSB_EXECUTABLE}" -b --msl 12 -t -o "${OUTPUT}" "${INPUT}"
  RESULT_VARIABLE WAM_QSB_BAKE_RESULT
  OUTPUT_VARIABLE WAM_QSB_BAKE_STDOUT
  ERROR_VARIABLE WAM_QSB_BAKE_STDERR)
if(NOT WAM_QSB_BAKE_RESULT EQUAL 0 OR NOT EXISTS "${OUTPUT}")
  file(REMOVE "${OUTPUT}")
  message(FATAL_ERROR
    "qsb failed to bake ${INPUT}:\n${WAM_QSB_BAKE_STDOUT}${WAM_QSB_BAKE_STDERR}")
endif()

execute_process(
  COMMAND "${QSB_EXECUTABLE}" -d "${OUTPUT}"
  RESULT_VARIABLE WAM_QSB_DUMP_RESULT
  OUTPUT_VARIABLE WAM_QSB_DUMP
  ERROR_VARIABLE WAM_QSB_DUMP_ERROR)
string(TOLOWER "${WAM_QSB_DUMP}" WAM_QSB_DUMP_LOWER)
if(NOT WAM_QSB_DUMP_RESULT EQUAL 0 OR
    NOT WAM_QSB_DUMP_LOWER MATCHES
      "shader [0-9]+: (metallib|metal library)")
  file(REMOVE "${OUTPUT}")
  message(FATAL_ERROR
    "qsb did not embed a macOS metallib for ${INPUT}. Install Apple's Metal "
    "Toolchain (xcodebuild -downloadComponent MetalToolchain). qsb output:\n"
    "${WAM_QSB_BAKE_STDOUT}${WAM_QSB_BAKE_STDERR}\n"
    "Serialized artifact dump:\n${WAM_QSB_DUMP}${WAM_QSB_DUMP_ERROR}")
endif()

# qsb's dump proves that bytecode exists, but not that it can load on WAM's
# supported macOS floor. Xcode otherwise defaults the AIR target to the build
# host's current OS (for example macOS 26), even when the app itself targets
# macOS 13. Extract every metallib variant and inspect its full target triple.
string(REPLACE "." ";" WAM_DEPLOYMENT_TARGET_PARTS "${DEPLOYMENT_TARGET}")
list(LENGTH WAM_DEPLOYMENT_TARGET_PARTS WAM_DEPLOYMENT_TARGET_PART_COUNT)
if(WAM_DEPLOYMENT_TARGET_PART_COUNT EQUAL 2)
  set(WAM_NORMALIZED_DEPLOYMENT_TARGET "${DEPLOYMENT_TARGET}.0")
else()
  set(WAM_NORMALIZED_DEPLOYMENT_TARGET "${DEPLOYMENT_TARGET}")
endif()
string(REPLACE "." "[.]" WAM_DEPLOYMENT_TARGET_REGEX
  "${WAM_NORMALIZED_DEPLOYMENT_TARGET}")

set(WAM_METALLIB_VARIANTS Standard)
if(WAM_QSB_DUMP MATCHES "metallib 12 \\[Batchable\\]")
  list(APPEND WAM_METALLIB_VARIANTS Batchable)
endif()
foreach(WAM_METALLIB_VARIANT IN LISTS WAM_METALLIB_VARIANTS)
  set(WAM_QSB_EXTRACT_VARIANT_ARGUMENTS)
  if(WAM_METALLIB_VARIANT STREQUAL "Batchable")
    list(APPEND WAM_QSB_EXTRACT_VARIANT_ARGUMENTS -b)
  endif()
  string(TOLOWER "${WAM_METALLIB_VARIANT}" WAM_METALLIB_VARIANT_LOWER)
  set(WAM_EXTRACTED_METALLIB
    "${OUTPUT}.${WAM_METALLIB_VARIANT_LOWER}.deployment-target.metallib")
  execute_process(
    COMMAND "${QSB_EXECUTABLE}" ${WAM_QSB_EXTRACT_VARIANT_ARGUMENTS}
      -x metallib,12 -o "${WAM_EXTRACTED_METALLIB}" "${OUTPUT}"
    RESULT_VARIABLE WAM_QSB_EXTRACT_RESULT
    OUTPUT_VARIABLE WAM_QSB_EXTRACT_OUTPUT
    ERROR_VARIABLE WAM_QSB_EXTRACT_ERROR)
  if(NOT WAM_QSB_EXTRACT_RESULT EQUAL 0 OR
      NOT EXISTS "${WAM_EXTRACTED_METALLIB}")
    file(REMOVE "${OUTPUT}" "${WAM_EXTRACTED_METALLIB}")
    message(FATAL_ERROR
      "qsb could not extract the ${WAM_METALLIB_VARIANT} metallib deployment "
      "target for ${INPUT}:\n"
      "${WAM_QSB_EXTRACT_OUTPUT}${WAM_QSB_EXTRACT_ERROR}")
  endif()

  execute_process(
    COMMAND /usr/bin/strings "${WAM_EXTRACTED_METALLIB}"
    RESULT_VARIABLE WAM_METALLIB_STRINGS_RESULT
    OUTPUT_VARIABLE WAM_METALLIB_STRINGS
    ERROR_VARIABLE WAM_METALLIB_STRINGS_ERROR)
  file(REMOVE "${WAM_EXTRACTED_METALLIB}")
  if(NOT WAM_METALLIB_STRINGS_RESULT EQUAL 0 OR
      NOT WAM_METALLIB_STRINGS MATCHES
        "apple-macosx${WAM_DEPLOYMENT_TARGET_REGEX}([^0-9.]|$)")
    file(REMOVE "${OUTPUT}")
    message(FATAL_ERROR
      "The ${WAM_METALLIB_VARIANT} metallib for ${INPUT} does not target "
      "macOS ${WAM_NORMALIZED_DEPLOYMENT_TARGET}. This would make the shader "
      "less compatible than WAM itself. strings output:\n"
      "${WAM_METALLIB_STRINGS}${WAM_METALLIB_STRINGS_ERROR}")
  endif()
endforeach()
