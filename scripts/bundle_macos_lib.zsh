#!/bin/zsh

# Sourced implementation for bundle_macos.zsh and its fixture-only transaction
# harness. This file defines functions only; sourcing it never mutates an app.
typeset -gr WAM_BUNDLE_MACOS_LIBRARY_DIRECTORY="${${(%):-%N}:A:h}"

wam_bundle_macos() {
set -euo pipefail

REQUESTED_APP_PATH="${1:-build/WAM.app}"
FINAL_APP_PATH="${REQUESTED_APP_PATH:A}"
APP_PATH="$FINAL_APP_PATH"
WHISPER_SOURCE="${2:-build/runtime/whisper-cli}"
MODEL_SOURCE="${3:-$APP_PATH/Contents/Resources/models/ggml-base.en.bin}"
EXECUTABLE="$APP_PATH/Contents/MacOS/WAM"
FRAMEWORKS="$APP_PATH/Contents/Frameworks"
PLUGINS="$APP_PATH/Contents/PlugIns"
RESOURCES="$APP_PATH/Contents/Resources"
TOOLS="$APP_PATH/Contents/Resources/tools"
MODELS="$APP_PATH/Contents/Resources/models"
MEDIA_MANIFEST="$RESOURCES/wam-media-libraries.manifest"
MPV_FALLBACK_NAME="WAMMpvFallback.dylib"
MPV_FALLBACK_SONAME_MAJOR="2"
RELEASE_FLOOR="${WAM_MACOS_RELEASE_FLOOR:-}"
CODESIGN_IDENTITY="${WAM_MACOS_CODESIGN_IDENTITY:-}"
EXPECTED_SIGNING_AUTHORITY="${WAM_MACOS_EXPECTED_SIGNING_AUTHORITY:-}"
EXPECTED_TEAM_ID="${WAM_MACOS_EXPECTED_TEAM_ID:-}"
RELEASE_SIGNING=false

score_macos_version() {
  local version="$1"
  awk -F. '
    NF < 2 || NF > 3 ||
    $1 !~ /^(0|[1-9][0-9]*)$/ ||
    $2 !~ /^(0|[1-9][0-9]*)$/ ||
    (NF == 3 && $3 !~ /^(0|[1-9][0-9]*)$/) ||
    $1 > 999 || $2 > 999 || (NF == 3 && $3 > 999) { exit 65 }
    {
      patch = (NF == 3 ? $3 : 0)
      print ($1 * 1000000) + ($2 * 1000) + patch
    }
  ' <<< "$version"
}

if [[ -n "$RELEASE_FLOOR" ]]; then
  if ! RELEASE_FLOOR_SCORE="$(score_macos_version "$RELEASE_FLOOR")" ||
      [[ -z "$RELEASE_FLOOR_SCORE" ]]; then
    print -u2 "WAM_MACOS_RELEASE_FLOOR must be a canonical macOS version"
    return 64
  fi
else
  RELEASE_FLOOR_SCORE=0
fi

signing_policy_values=0
[[ -z "$CODESIGN_IDENTITY" ]] || (( signing_policy_values += 1 ))
[[ -z "$EXPECTED_SIGNING_AUTHORITY" ]] || (( signing_policy_values += 1 ))
[[ -z "$EXPECTED_TEAM_ID" ]] || (( signing_policy_values += 1 ))
if (( signing_policy_values != 0 && signing_policy_values != 3 )); then
  print -u2 "Developer ID packaging requires identity, authority, and team ID"
  return 64
fi
if (( signing_policy_values == 3 )); then
  if [[ -z "$RELEASE_FLOOR" ]]; then
    print -u2 "Developer ID packaging requires WAM_MACOS_RELEASE_FLOOR"
    return 64
  fi
  if [[ "$CODESIGN_IDENTITY" == *$'\n'* ||
        "$CODESIGN_IDENTITY" == *$'\r'* ||
        ( ! "$CODESIGN_IDENTITY" =~ "^[A-Fa-f0-9]{40}$" &&
          "$CODESIGN_IDENTITY" != "$EXPECTED_SIGNING_AUTHORITY" ) ||
        "$EXPECTED_SIGNING_AUTHORITY" == *$'\n'* ||
        "$EXPECTED_SIGNING_AUTHORITY" == *$'\r'* ||
        "$EXPECTED_SIGNING_AUTHORITY" != "Developer ID Application: "* ||
        ! "$EXPECTED_TEAM_ID" =~ "^[A-Z0-9]{10}$" ||
        "$EXPECTED_SIGNING_AUTHORITY" != *" ($EXPECTED_TEAM_ID)" ]]; then
    print -u2 "Invalid Developer ID signing policy"
    return 64
  fi
  RELEASE_SIGNING=true
fi
WAM_TEST_FAULT="${4:-}"
WAM_TEST_FIXTURE_ROOT="${5:-}"
WAM_TEST_FAULTS_ENABLED=false
if [[ -n "$WAM_TEST_FAULT" ]]; then
  if [[ "$WAM_TEST_FIXTURE_ROOT" != /* ||
        ! -d "$WAM_TEST_FIXTURE_ROOT" || -L "$WAM_TEST_FIXTURE_ROOT" ]]; then
    print -u2 "Fixture-only fault injection requires one exact fixture root"
    return 64
  fi
  WAM_TEST_FIXTURE_ROOT="${WAM_TEST_FIXTURE_ROOT:A}"
  if [[ "$FINAL_APP_PATH" != "$WAM_TEST_FIXTURE_ROOT"/* ]]; then
    print -u2 "Fixture-only fault injection cannot target this app"
    return 64
  fi
  WAM_TEST_FAULTS_ENABLED=true
  case "$WAM_TEST_FAULT" in
    after-copy|after-install-name|after-rpath-introspection|before-swap|helper-rollback) ;;
    *)
      print -u2 "Unknown fixture-only packaging failure point: $WAM_TEST_FAULT"
      return 64
      ;;
  esac
fi
if ! INSTALL_NAME_TOOL="$(xcrun --find install_name_tool)" ||
    [[ -z "$INSTALL_NAME_TOOL" ]]; then
  print -u2 "Could not locate install_name_tool"
  return 1
fi
if ! WAM_CURRENT_UID="$(id -u)" || [[ -z "$WAM_CURRENT_UID" ]]; then
  print -u2 "Could not establish the packaging user identity"
  return 1
fi
SYSTEM_LIBRARY_ROOT="/System/Library"
SYSTEM_LIBRARY_ROOT="${SYSTEM_LIBRARY_ROOT:A}"
USR_LIBRARY_ROOT="/usr/lib"
USR_LIBRARY_ROOT="${USR_LIBRARY_ROOT:A}"

wam_fail_if_requested() {
  local point="$1"
  if [[ "$WAM_TEST_FAULTS_ENABLED" == true &&
        "$WAM_TEST_FAULT" == "$point" ]]; then
    print -u2 "Injected fixture-only packaging failure: $point"
    return 97
  fi
}

# Read dependency load commands instead of `otool -L`: that summary also
# reports LC_ID_DYLIB, which is image identity metadata and never a dependency
# edge. Keep every real dyld edge, including weak, re-exported, upward, and
# lazy loads.
parse_load_command_values() {
  local command_kind="$1"
  case "$command_kind" in
    dependency|identity|rpath) ;;
    *)
      print -u2 "Unknown Mach-O load-command parser: $command_kind"
      return 64
      ;;
  esac
  if ! awk -v requested="$command_kind" '
    $1 == "cmd" {
      if (wanted) exit 65
      wanted = 0
      if (requested == "dependency") {
        wanted = ($2 == "LC_LOAD_DYLIB" ||
                  $2 == "LC_LOAD_WEAK_DYLIB" ||
                  $2 == "LC_REEXPORT_DYLIB" ||
                  $2 == "LC_LOAD_UPWARD_DYLIB" ||
                  $2 == "LC_LAZY_LOAD_DYLIB")
        field = "name"
      } else if (requested == "identity") {
        wanted = ($2 == "LC_ID_DYLIB")
        field = "name"
      } else if (requested == "rpath") {
        wanted = ($2 == "LC_RPATH")
        field = "path"
      }
      next
    }
    wanted {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (index(line, field " ") == 1) {
        sub("^" field " ", "", line)
        sub(/ \(offset [0-9]+\)$/, "", line)
        if (line == "" || line ~ /[[:cntrl:]]/) exit 65
        print line
        wanted = 0
      }
    }
    END {
      if (wanted) exit 65
    }
  '; then
    print -u2 "Could not parse Mach-O $command_kind load commands"
    return 1
  fi
}

list_loaded_dependencies() {
  local load_commands
  if ! load_commands="$(otool -l "$1")"; then
    print -u2 "Could not inspect Mach-O load commands: $1"
    return 1
  fi
  if ! parse_load_command_values dependency <<< "$load_commands"; then
    return 1
  fi
}

list_install_names() {
  local load_commands
  if ! load_commands="$(otool -l "$1")"; then
    print -u2 "Could not inspect Mach-O install name: $1"
    return 1
  fi
  if ! parse_load_command_values identity <<< "$load_commands"; then
    return 1
  fi
}

list_runtime_search_paths() {
  local load_commands
  if ! load_commands="$(otool -l "$1")"; then
    print -u2 "Could not inspect Mach-O runtime search paths: $1"
    return 1
  fi
  if ! parse_load_command_values rpath <<< "$load_commands"; then
    return 1
  fi
}

read_loaded_dependencies() {
  local binary="$1"
  local dependency_output
  WAM_INTROSPECTION_LINES=()
  if ! dependency_output="$(list_loaded_dependencies "$binary")"; then
    return 1
  fi
  if [[ -n "$dependency_output" ]]; then
    WAM_INTROSPECTION_LINES=("${(@f)dependency_output}")
  fi
}

read_runtime_search_paths() {
  local binary="$1"
  local rpath_output
  WAM_INTROSPECTION_LINES=()
  if ! rpath_output="$(list_runtime_search_paths "$binary")"; then
    return 1
  fi
  wam_fail_if_requested after-rpath-introspection || return 1
  if [[ -n "$rpath_output" ]]; then
    WAM_INTROSPECTION_LINES=("${(@f)rpath_output}")
  fi
}

typeset -ga WAM_INTROSPECTION_LINES
typeset -gA SOURCE_ORIGINS
typeset -ga WAM_EFFECTIVE_RUNPATHS
typeset -g WAM_RESOLVED_SOURCE

read_found_paths() {
  local path_kind="$1"
  shift
  local inventory_file found_path
  WAM_INTROSPECTION_LINES=()
  if ! inventory_file="$(mktemp "${TMPDIR:-/tmp}/wam-find.XXXXXX")"; then
    print -u2 "Could not create a bundle inventory file"
    return 1
  fi
  if ! find "$@" -type "$path_kind" -print0 > "$inventory_file"; then
    print -u2 "Could not inventory bundle paths"
    if ! /bin/rm -f -- "$inventory_file"; then
      print -u2 "Could not remove the failed bundle inventory file"
    fi
    return 1
  fi
  while IFS= read -r -d $'\0' found_path; do
    WAM_INTROSPECTION_LINES+=("$found_path")
  done < "$inventory_file"
  if ! /bin/rm -f -- "$inventory_file"; then
    print -u2 "Could not remove the bundle inventory file"
    return 1
  fi
}

copy_registered_media_leaf() {
  local source="$1"
  local name="$2"
  local destination="$FRAMEWORKS/$name"
  if ! cp -fL "$source" "$destination"; then
    print -u2 "Could not copy media dependency: $source"
    return 1
  fi
  wam_fail_if_requested after-copy || return 1
}

rewrite_install_id() {
  local target="$1"
  local install_id="$2"
  if ! "$INSTALL_NAME_TOOL" -id "$install_id" "$target"; then
    print -u2 "Could not rewrite install name: $target"
    return 1
  fi
  wam_fail_if_requested after-install-name || return 1
}

rewrite_dependency_edge() {
  local target="$1"
  local dependency="$2"
  local packaged_dependency="$3"
  local packaged_relative replacement
  if [[ "$packaged_dependency" != "$FRAMEWORKS"/* ]]; then
    print -u2 "Packaged dependency escaped Frameworks: $packaged_dependency"
    return 1
  fi
  packaged_relative="${packaged_dependency#$FRAMEWORKS/}"
  if [[ "$target" == "$TOOLS"/* ]]; then
    replacement="@loader_path/../../Frameworks/$packaged_relative"
  elif [[ "$target" == "$MPV_FALLBACK_DESTINATION" ]]; then
    replacement="@executable_path/../Frameworks/$packaged_relative"
  elif [[ "$target" == "$FRAMEWORKS"/* ]]; then
    replacement="@loader_path/$packaged_relative"
  else
    replacement="@executable_path/../Frameworks/$packaged_relative"
  fi
  if [[ "$dependency" != "$replacement" ]]; then
    if ! "$INSTALL_NAME_TOOL" -change "$dependency" "$replacement" \
        "$target"; then
      print -u2 "Could not rewrite dependency in $target: $dependency"
      return 1
    fi
  fi
}

set_edge_key() {
  local referencing_image="$1"
  local dependency="$2"
  WAM_EDGE_KEY="${#referencing_image}:$referencing_image$dependency"
}

absolute_dependency_has_dot_component() {
  local dependency="$1"
  [[ "$dependency" == /* ]] || return 1
  [[ "$dependency" == */./* || "$dependency" == */../* ||
     "$dependency" == */. || "$dependency" == */.. ]]
}

validate_dependency_path_syntax() {
  local dependency="$1"
  if absolute_dependency_has_dot_component "$dependency"; then
    print -u2 "Dependency contains forbidden path traversal: $dependency"
    return 1
  fi
}

is_system_library() {
  local dependency="$1"
  [[ "$dependency" == /* ]] || return 1
  absolute_dependency_has_dot_component "$dependency" && return 1
  # Modern macOS supplies many platform dylibs only through the signed dyld
  # shared cache, so their canonical absolute install names need not exist as
  # ordinary filesystem entries. Dot components were rejected above; accept
  # only the two immutable system install-name roots.
  [[ "$dependency" == "$SYSTEM_LIBRARY_ROOT"/* ||
     "$dependency" == "$USR_LIBRARY_ROOT"/* ]]
}

append_unique_runpath() {
  local candidate="$1"
  local existing
  for existing in "${WAM_EFFECTIVE_RUNPATHS[@]}"; do
    [[ "$existing" != "$candidate" ]] || return 0
  done
  WAM_EFFECTIVE_RUNPATHS+=("$candidate")
}

# dyld searches the current image's LC_RPATH entries first, followed by the
# inherited run-path stack of the exact load chain that reached that image.
# Expand every entry against the canonical source image and execution root now;
# never re-create this context later from a staged basename.
build_effective_runpath_stack() {
  local source_image="$1"
  local execution_root="$2"
  shift 2
  local -a inherited_runpaths source_rpaths expanded_entries
  local source_rpath inherited_root expanded_root
  inherited_runpaths=("$@")
  WAM_EFFECTIVE_RUNPATHS=()
  read_runtime_search_paths "$source_image" || return 1
  source_rpaths=("${WAM_INTROSPECTION_LINES[@]}")
  for source_rpath in "${source_rpaths[@]}"; do
    expanded_entries=()
    if [[ "$source_rpath" == @loader_path ]]; then
      expanded_entries+=("${source_image:h}")
    elif [[ "$source_rpath" == @loader_path/* ]]; then
      expanded_entries+=("${source_image:h}/${source_rpath#@loader_path/}")
    elif [[ "$source_rpath" == @executable_path ]]; then
      expanded_entries+=("${execution_root:h}")
    elif [[ "$source_rpath" == @executable_path/* ]]; then
      expanded_entries+=("${execution_root:h}/${source_rpath#@executable_path/}")
    elif [[ "$source_rpath" == @rpath/* ]]; then
      if (( ${#inherited_runpaths[@]} == 0 )); then
        print -u2 "LC_RPATH has no inherited expansion context in $source_image: $source_rpath"
        return 1
      fi
      for inherited_root in "${inherited_runpaths[@]}"; do
        expanded_entries+=("$inherited_root/${source_rpath#@rpath/}")
      done
    elif [[ "$source_rpath" == /* ]]; then
      expanded_entries+=("$source_rpath")
    else
      print -u2 "Source image uses an unsupported relative LC_RPATH: $source_image: $source_rpath"
      return 1
    fi
    for expanded_root in "${expanded_entries[@]}"; do
      if [[ "$expanded_root" != /* ]]; then
        print -u2 "LC_RPATH did not expand to an absolute path: $source_image: $source_rpath"
        return 1
      fi
      expanded_root="${expanded_root:A}"
      append_unique_runpath "$expanded_root" || return 1
    done
  done
  for inherited_root in "${inherited_runpaths[@]}"; do
    append_unique_runpath "$inherited_root" || return 1
  done
}

resolve_dependency_in_context() {
  local referencing_image="$1"
  local source_image="$2"
  local execution_root="$3"
  local dependency="$4"
  shift 4
  local -a runpath_stack matches
  local candidate canonical_candidate runpath_root existing_match
  local duplicate_match
  runpath_stack=("$@")
  WAM_RESOLVED_SOURCE=""

  if [[ "$dependency" == /* ]]; then
    candidate="$dependency"
  elif [[ "$dependency" == @loader_path/* ]]; then
    candidate="${source_image:h}/${dependency#@loader_path/}"
  elif [[ "$dependency" == @executable_path/* ]]; then
    candidate="${execution_root:h}/${dependency#@executable_path/}"
  elif [[ "$dependency" == @rpath/* ]]; then
    for runpath_root in "${runpath_stack[@]}"; do
      candidate="$runpath_root/${dependency#@rpath/}"
      [[ -f "$candidate" ]] || continue
      canonical_candidate="${candidate:A}"
      duplicate_match=false
      for existing_match in "${matches[@]}"; do
        if [[ "$existing_match" == "$canonical_candidate" ]]; then
          duplicate_match=true
          break
        fi
      done
      [[ "$duplicate_match" == true ]] || matches+=("$canonical_candidate")
    done
    if (( ${#matches[@]} == 0 )); then
      return 1
    fi
    if (( ${#matches[@]} > 1 )); then
      print -u2 "Ambiguous inherited @rpath dependency in $referencing_image: $dependency"
      for canonical_candidate in "${matches[@]}"; do
        print -u2 "  candidate: $canonical_candidate"
      done
      return 1
    fi
    WAM_RESOLVED_SOURCE="${matches[1]}"
    return 0
  else
    return 1
  fi

  [[ -f "$candidate" ]] || return 1
  WAM_RESOLVED_SOURCE="${candidate:A}"
}

validate_closure_leaf() {
  local source="$1"
  local description source_mode source_uid source_arches required_arch
  if [[ ! -f "$source" || -L "$source" || "${source:A}" != "$source" ]]; then
    print -u2 "Dependency source is not one canonical regular file: $source"
    return 1
  fi
  if ! source_mode="$(stat -f '%Lp' "$source")" ||
      ! source_uid="$(stat -f '%u' "$source")"; then
    print -u2 "Could not inspect dependency source ownership: $source"
    return 1
  fi
  if (( (8#$source_mode & 8#22) != 0 )) ||
      [[ "$source_uid" != "0" && "$source_uid" != "$WAM_CURRENT_UID" ]]; then
    print -u2 "Dependency source has an unsafe owner or write mode: $source"
    return 1
  fi
  if ! description="$(file -b "$source")" ||
      [[ "$description" != *Mach-O* ||
        "$description" != *"dynamically linked shared library"* ]]; then
    print -u2 "Dependency source is not a Mach-O dylib: $source"
    return 1
  fi
  if ! source_arches="$(lipo -archs "$source")" ||
      [[ -z "$source_arches" ]]; then
    print -u2 "Could not inspect dependency source architectures: $source"
    return 1
  fi
  for required_arch in ${=WAM_REQUIRED_ARCHES}; do
    if [[ " $source_arches " != *" $required_arch "* ]]; then
      print -u2 "Dependency source lacks WAM architecture $required_arch: $source"
      return 1
    fi
  done
}

validate_root_macho() {
  local source="$1"
  local label="$2"
  local description source_mode source_uid source_arches required_arch
  if [[ ! -f "$source" || -L "$source" || "${source:A}" != "$source" ]]; then
    print -u2 "$label is not one canonical regular file: $source"
    return 1
  fi
  if ! source_mode="$(stat -f '%Lp' "$source")" ||
      ! source_uid="$(stat -f '%u' "$source")"; then
    print -u2 "Could not inspect $label ownership: $source"
    return 1
  fi
  if (( (8#$source_mode & 8#22) != 0 )) ||
      [[ "$source_uid" != "0" && "$source_uid" != "$WAM_CURRENT_UID" ]]; then
    print -u2 "$label has an unsafe owner or write mode: $source"
    return 1
  fi
  if ! description="$(file -b "$source")" ||
      [[ "$description" != *Mach-O* ||
        "$description" != *executable* ||
        "$description" == *"dynamically linked shared library"* ]]; then
    print -u2 "$label is not a Mach-O executable: $source"
    return 1
  fi
  if ! source_arches="$(lipo -archs "$source")" ||
      [[ -z "$source_arches" ]]; then
    print -u2 "Could not inspect $label architectures: $source"
    return 1
  fi
  for required_arch in ${=WAM_REQUIRED_ARCHES}; do
    if [[ " $source_arches " != *" $required_arch "* ]]; then
      print -u2 "$label lacks WAM architecture $required_arch: $source"
      return 1
    fi
  done
}

select_mpv_fallback_source() {
  local requested_source pkg_config mpv_libdir canonical_source
  local source_description source_name source_mode source_uid
  local executable_arches source_arches executable_arch install_name id_name
  local -a install_names

  if [[ -n "${WAM_MPV_FALLBACK_LIBRARY:-}" ]]; then
    requested_source="$WAM_MPV_FALLBACK_LIBRARY"
  else
    pkg_config="${WAM_PKG_CONFIG_EXECUTABLE:-$(command -v pkg-config || true)}"
    if [[ -z "$pkg_config" || ! -x "$pkg_config" ]]; then
      print -u2 "pkg-config is required to locate the bundled mpv fallback"
      return 1
    fi
    if ! mpv_libdir="$($pkg_config --variable=libdir mpv 2>/dev/null)" ||
        [[ -z "$mpv_libdir" || "$mpv_libdir" != /* ||
          "$mpv_libdir" == *$'\n'* ]]; then
      print -u2 "pkg-config did not report one absolute mpv library directory"
      return 1
    fi
    requested_source="$mpv_libdir/libmpv.$MPV_FALLBACK_SONAME_MAJOR.dylib"
  fi

  if [[ "$requested_source" != /* ]]; then
    print -u2 "mpv fallback source must be an absolute path: $requested_source"
    return 1
  fi
  if [[ ! -e "$requested_source" ]]; then
    print -u2 "mpv fallback source was not found: $requested_source"
    return 1
  fi
  canonical_source="${requested_source:A}"
  if [[ ! -f "$canonical_source" || -L "$canonical_source" ]]; then
    print -u2 "mpv fallback source is not one canonical regular file: $canonical_source"
    return 1
  fi

  source_name="${canonical_source:t}"
  if [[ "$source_name" != "libmpv.$MPV_FALLBACK_SONAME_MAJOR.dylib" &&
        "$source_name" != libmpv.$MPV_FALLBACK_SONAME_MAJOR.*.dylib ]]; then
    print -u2 "mpv fallback source is not the actual versioned libmpv: $canonical_source"
    return 1
  fi

  if ! source_mode="$(stat -f '%Lp' "$canonical_source")" ||
      ! source_uid="$(stat -f '%u' "$canonical_source")"; then
    print -u2 "could not inspect mpv fallback ownership: $canonical_source"
    return 1
  fi
  if [[ -z "$source_mode" || -z "$source_uid" ]] ||
      (( (8#$source_mode & 8#22) != 0 )) ||
      [[ "$source_uid" != "0" && "$source_uid" != "$WAM_CURRENT_UID" ]]; then
    print -u2 "mpv fallback source has an unsafe owner or write mode: $canonical_source"
    return 1
  fi

  if ! source_description="$(file -b "$canonical_source")" ||
      [[ "$source_description" != *Mach-O* ||
        "$source_description" != *"dynamically linked shared library"* ]]; then
    print -u2 "mpv fallback source is not a Mach-O dylib: $canonical_source"
    return 1
  fi
  local install_name_output
  if ! install_name_output="$(list_install_names "$canonical_source")"; then
    return 1
  fi
  install_names=("${(@f)install_name_output}")
  if (( ${#install_names[@]} != 1 )); then
    print -u2 "mpv fallback source must have exactly one LC_ID_DYLIB: $canonical_source"
    return 1
  fi
  for install_name in "${install_names[@]}"; do
    id_name="${install_name:t}"
    if [[ "$id_name" != "libmpv.$MPV_FALLBACK_SONAME_MAJOR.dylib" &&
          "$id_name" != libmpv.$MPV_FALLBACK_SONAME_MAJOR.*.dylib ]]; then
      print -u2 "mpv fallback LC_ID_DYLIB has the wrong major: $install_name"
      return 1
    fi
  done

  if ! executable_arches="$(lipo -archs "$EXECUTABLE")" ||
      ! source_arches="$(lipo -archs "$canonical_source")"; then
    print -u2 "could not read WAM or mpv fallback Mach-O architectures"
    return 1
  fi
  if [[ -z "$executable_arches" || -z "$source_arches" ]]; then
    print -u2 "could not read WAM or mpv fallback Mach-O architectures"
    return 1
  fi
  for executable_arch in ${=executable_arches}; do
    if [[ " $source_arches " != *" $executable_arch "* ]]; then
      print -u2 "mpv fallback lacks WAM architecture $executable_arch: $canonical_source"
      return 1
    fi
  done

  print -r -- "$canonical_source"
}

validate_secure_bundle_chain() {
  local bundle_root="${1:-$APP_PATH}"
  local expected_uid="" secure_directory secure_mode secure_uid
  local -a secure_directories
  secure_directory="${bundle_root:h}"
  if [[ ! -d "$secure_directory" || -L "$secure_directory" ||
        "${secure_directory:A}" != "$secure_directory" ]] ||
      ! secure_mode="$(stat -f '%Lp' "$secure_directory")" ||
      ! secure_uid="$(stat -f '%u' "$secure_directory")" ||
      (( (8#$secure_mode & 8#22) != 0 )) ||
      [[ "$secure_uid" != "0" && "$secure_uid" != "$WAM_CURRENT_UID" ]]; then
    print -u2 "Bundle parent has an unsafe identity, owner, or mode: $secure_directory"
    return 1
  fi
  secure_directories=("$bundle_root"
    "$bundle_root/Contents" "$bundle_root/Contents/MacOS"
    "$bundle_root/Contents/Frameworks")
  [[ ! -e "$bundle_root/Contents/Resources" ]] ||
    secure_directories+=("$bundle_root/Contents/Resources")
  [[ ! -e "$bundle_root/Contents/PlugIns" ]] ||
    secure_directories+=("$bundle_root/Contents/PlugIns")
  for secure_directory in "${secure_directories[@]}"; do
    if [[ ! -d "$secure_directory" || -L "$secure_directory" ||
          "${secure_directory:A}" != "$secure_directory" ]]; then
      print -u2 "Bundle path is not one canonical directory: $secure_directory"
      return 1
    fi
    if ! secure_mode="$(stat -f '%Lp' "$secure_directory")" ||
        ! secure_uid="$(stat -f '%u' "$secure_directory")"; then
      print -u2 "Could not inspect bundle directory: $secure_directory"
      return 1
    fi
    if [[ -z "$expected_uid" ]]; then
      expected_uid="$secure_uid"
    fi
    if (( (8#$secure_mode & 8#22) != 0 )) ||
        [[ "$secure_uid" != "$expected_uid" ]]; then
      print -u2 "Bundle path has an unsafe owner or mode: $secure_directory"
      return 1
    fi
  done
}

validate_bundle_symlinks() {
  local bundle_root="$1"
  local link_path link_target
  typeset -a bundle_links
  read_found_paths l "$bundle_root" || return 1
  bundle_links=("${WAM_INTROSPECTION_LINES[@]}")
  for link_path in "${bundle_links[@]}"; do
    if [[ ! -e "$link_path" ]]; then
      print -u2 "Bundle contains a dangling symlink: $link_path"
      return 1
    fi
    link_target="${link_path:A}"
    if [[ "$link_target" != "$bundle_root" &&
          "$link_target" != "$bundle_root"/* ]]; then
      print -u2 "Bundle symlink escapes its app: $link_path"
      return 1
    fi
  done
}

validate_bundle_tree() {
  local bundle_root="$1"
  validate_secure_bundle_chain "$bundle_root" || return 1
  validate_bundle_symlinks "$bundle_root" || return 1
}

read_path_identity() {
  # `path` is a special zsh array tied to PATH. A local scalar with that name
  # empties command lookup inside this function, so even `stat` becomes
  # unreachable while validating the bundle.
  local target_path="$1"
  local identity_output
  if ! identity_output="$(stat -f '%d %i %HT' "$target_path")"; then
    return 1
  fi
  WAM_PATH_DEVICE="${identity_output%% *}"
  identity_output="${identity_output#* }"
  WAM_PATH_INODE="${identity_output%% *}"
  WAM_PATH_TYPE="${identity_output#* }"
}

path_has_identity() {
  local target_path="$1"
  local expected_device="$2"
  local expected_inode="$3"
  read_path_identity "$target_path" || return 1
  [[ "$WAM_PATH_TYPE" == "Directory" &&
     "$WAM_PATH_DEVICE" == "$expected_device" &&
     "$WAM_PATH_INODE" == "$expected_inode" ]]
}

validate_final_mpv_fallback() {
  local fallback_destination="$FRAMEWORKS/$MPV_FALLBACK_NAME"
  local expected_uid fallback_mode fallback_uid fallback_links
  local fallback_install_name_output fallback_dependency fallback_relative
  local fallback_resolved component
  local -a fallback_install_names fallback_dependencies

  validate_secure_bundle_chain || return 1
  if ! expected_uid="$(stat -f '%u' "${EXECUTABLE:h}")"; then
    print -u2 "Could not establish bundle owner"
    return 1
  fi
  if [[ ! -f "$fallback_destination" || -L "$fallback_destination" ||
        "${fallback_destination:A}" != "$fallback_destination" ]]; then
    print -u2 "Packaged mpv fallback is not one regular canonical file"
    return 1
  fi
  if ! fallback_mode="$(stat -f '%Lp' "$fallback_destination")" ||
      ! fallback_uid="$(stat -f '%u' "$fallback_destination")" ||
      ! fallback_links="$(stat -f '%l' "$fallback_destination")"; then
    print -u2 "Could not inspect packaged mpv fallback invariants"
    return 1
  fi
  if (( fallback_links != 1 || (8#$fallback_mode & 8#22) != 0 )) ||
      [[ "$fallback_uid" != "$expected_uid" ]]; then
    print -u2 "Packaged mpv fallback has unsafe ownership, mode, or link count"
    return 1
  fi
  if ! fallback_install_name_output="$(list_install_names \
      "$fallback_destination")"; then
    return 1
  fi
  fallback_install_names=("${(@f)fallback_install_name_output}")
  if (( ${#fallback_install_names[@]} != 1 )) ||
      [[ "${fallback_install_names[1]}" != "@rpath/$MPV_FALLBACK_NAME" ]]; then
    print -u2 "Packaged mpv fallback has the wrong install name"
    return 1
  fi
  read_loaded_dependencies "$fallback_destination" || return 1
  fallback_dependencies=("${WAM_INTROSPECTION_LINES[@]}")
  for fallback_dependency in "${fallback_dependencies[@]}"; do
    validate_dependency_path_syntax "$fallback_dependency" || return 1
    is_system_library "$fallback_dependency" && continue
    if [[ "$fallback_dependency" != @executable_path/../Frameworks/* ]]; then
      print -u2 "Descriptor-loaded mpv fallback has an unsafe dependency edge: $fallback_dependency"
      return 1
    fi
    fallback_relative="${fallback_dependency#@executable_path/../Frameworks/}"
    if [[ -z "$fallback_relative" ]]; then
      print -u2 "Descriptor-loaded mpv fallback has an empty dependency edge"
      return 1
    fi
    for component in "${(@s:/:)fallback_relative}"; do
      if [[ -z "$component" || "$component" == . || "$component" == .. ]]; then
        print -u2 "Descriptor-loaded mpv fallback has path traversal: $fallback_dependency"
        return 1
      fi
    done
    fallback_resolved="$FRAMEWORKS/$fallback_relative"
    if [[ ! -f "$fallback_resolved" ]]; then
      print -u2 "Descriptor-loaded mpv fallback dependency is missing: $fallback_dependency"
      return 1
    fi
    fallback_resolved="${fallback_resolved:A}"
    if [[ "$fallback_resolved" != "$FRAMEWORKS"/* ]]; then
      print -u2 "Descriptor-loaded mpv fallback dependency escapes Frameworks: $fallback_dependency"
      return 1
    fi
  done
}

wam_bundle_mutate_staged_app() {
local staged_app="$1"
local source_app="$2"
SOURCE_ORIGINS=()
APP_PATH="$staged_app"
EXECUTABLE="$APP_PATH/Contents/MacOS/WAM"
FRAMEWORKS="$APP_PATH/Contents/Frameworks"
PLUGINS="$APP_PATH/Contents/PlugIns"
RESOURCES="$APP_PATH/Contents/Resources"
TOOLS="$RESOURCES/tools"
MODELS="$RESOURCES/models"
MEDIA_MANIFEST="$RESOURCES/wam-media-libraries.manifest"
SOURCE_EXECUTABLE="$source_app/Contents/MacOS/WAM"

if [[ ! -x "$EXECUTABLE" ]]; then
  print -u2 "WAM executable not found at $EXECUTABLE"
  return 1
fi
validate_secure_bundle_chain || return 1
if ! WAM_REQUIRED_ARCHES="$(lipo -archs "$EXECUTABLE")" ||
    [[ -z "$WAM_REQUIRED_ARCHES" ]]; then
  print -u2 "Could not establish WAM's required architectures"
  return 1
fi

# Qt's deployment step owns Frameworks, PlugIns, and Resources/qml. Never
# replace those directories here. Remove only media libraries copied by an
# earlier invocation of this script, then rebuild that small manifest.
if [[ -e "$MEDIA_MANIFEST" || -L "$MEDIA_MANIFEST" ]]; then
  if [[ ! -f "$MEDIA_MANIFEST" || -L "$MEDIA_MANIFEST" ||
        "${MEDIA_MANIFEST:A}" != "$MEDIA_MANIFEST" ]]; then
    print -u2 "Media manifest is not one canonical regular file: $MEDIA_MANIFEST"
    return 1
  fi
  while IFS= read -r owned_name; do
    if [[ "$owned_name" == *.dylib && "$owned_name" != */* ]]; then
      /bin/rm -f -- "$FRAMEWORKS/$owned_name" || return 1
    fi
  done < "$MEDIA_MANIFEST"
fi
mkdir -p "$FRAMEWORKS" "$PLUGINS" "$RESOURCES" "$TOOLS" "$MODELS" ||
  return 1
/bin/rm -f -- "$TOOLS/ffmpeg" "$TOOLS/whisper-cli" || return 1
cp -f README.md THIRD_PARTY_NOTICES.md "$RESOURCES/" || return 1

if [[ ! -d "$FRAMEWORKS/QtCore.framework" ||
      ! -d "$FRAMEWORKS/QtQuick.framework" ||
      ! -f "$PLUGINS/platforms/libqcocoa.dylib" ||
      ! -d "$RESOURCES/qml/QtQuick" ]]; then
  print -u2 "Qt/QML runtime is missing from $APP_PATH"
  print -u2 "Run cmake --install (Qt deployment) before bundle_macos.zsh"
  return 1
fi

# The transaction never follows deployment links into a package-manager tree
# or guesses a bundled framework from a basename. Preflight requires every
# source-app symlink to resolve inside that app, and the final closure audit
# requires macdeployqt/CMake to have already made every Qt edge self-contained.

FFMPEG_SOURCE="${WAM_FFMPEG_EXECUTABLE:-$(command -v ffmpeg || true)}"
if [[ -n "$FFMPEG_SOURCE" && -x "$FFMPEG_SOURCE" ]]; then
  FFMPEG_SOURCE="${FFMPEG_SOURCE:A}"
  validate_root_macho "$FFMPEG_SOURCE" "FFmpeg source" || return 1
  cp -f "$FFMPEG_SOURCE" "$TOOLS/ffmpeg" || return 1
  chmod u+w "$TOOLS/ffmpeg" || return 1
  SOURCE_ORIGINS[$TOOLS/ffmpeg]="$FFMPEG_SOURCE"
fi
if [[ -x "$WHISPER_SOURCE" ]]; then
  WHISPER_SOURCE="${WHISPER_SOURCE:A}"
  validate_root_macho "$WHISPER_SOURCE" "whisper source" || return 1
  cp -f "$WHISPER_SOURCE" "$TOOLS/whisper-cli" || return 1
  chmod u+w "$TOOLS/whisper-cli" || return 1
  SOURCE_ORIGINS[$TOOLS/whisper-cli]="$WHISPER_SOURCE"
else
  print -u2 "Standalone whisper-cli not found at $WHISPER_SOURCE"
  print -u2 "Build it with scripts/build_whisper.sh before packaging"
  return 1
fi
if [[ -s "$MODEL_SOURCE" && "${MODEL_SOURCE:A}" != "${MODELS:A}/ggml-base.en.bin" ]]; then
  cp -f "$MODEL_SOURCE" "$MODELS/ggml-base.en.bin" || return 1
fi
if [[ ! -x "$TOOLS/ffmpeg" || ! -x "$TOOLS/whisper-cli" ||
      ! -s "$MODELS/ggml-base.en.bin" ]]; then
  print -u2 "Standalone package is missing FFmpeg, whisper-cli, or the caption model"
  return 1
fi
typeset -A EDGE_DESTINATIONS
typeset -A EDGE_SOURCES
typeset -A DESTINATION_SOURCES
typeset -A PROCESSED_CONTEXTS
typeset -A CONTEXT_BINARIES
typeset -A CONTEXT_SOURCES
typeset -A CONTEXT_EXECUTION_ROOTS
typeset -A CONTEXT_RUNPATH_COUNTS
typeset -A CONTEXT_RUNPATHS
typeset -a QUEUE_CONTEXTS
typeset -a OWNED
typeset -a WAM_CONTEXT_RUNPATHS
typeset -i NEXT_CONTEXT_ID=0

enqueue_load_context() {
  local packaged_image="$1"
  local canonical_source="$2"
  local execution_root="$3"
  shift 3
  local runpath position=0
  (( NEXT_CONTEXT_ID += 1 ))
  CONTEXT_BINARIES[$NEXT_CONTEXT_ID]="$packaged_image"
  CONTEXT_SOURCES[$NEXT_CONTEXT_ID]="$canonical_source"
  CONTEXT_EXECUTION_ROOTS[$NEXT_CONTEXT_ID]="$execution_root"
  for runpath in "$@"; do
    (( position += 1 ))
    CONTEXT_RUNPATHS["$NEXT_CONTEXT_ID:$position"]="$runpath"
  done
  CONTEXT_RUNPATH_COUNTS[$NEXT_CONTEXT_ID]="$position"
  QUEUE_CONTEXTS+=("$NEXT_CONTEXT_ID")
}

read_context_runpaths() {
  local context_id="$1"
  local position count="${CONTEXT_RUNPATH_COUNTS[$context_id]}"
  WAM_CONTEXT_RUNPATHS=()
  for (( position = 1; position <= count; position += 1 )); do
    WAM_CONTEXT_RUNPATHS+=("${CONTEXT_RUNPATHS["$context_id:$position"]}")
  done
}

set_context_key() {
  local packaged_image="$1"
  local canonical_source="$2"
  local execution_root="$3"
  shift 3
  local runpath
  WAM_CONTEXT_KEY="${#packaged_image}:$packaged_image"
  WAM_CONTEXT_KEY+="${#canonical_source}:$canonical_source"
  WAM_CONTEXT_KEY+="${#execution_root}:$execution_root"
  for runpath in "$@"; do
    WAM_CONTEXT_KEY+="${#runpath}:$runpath"
  done
}

if ! MPV_FALLBACK_SOURCE="$(select_mpv_fallback_source)"; then
  return 1
fi
MPV_FALLBACK_DESTINATION="$FRAMEWORKS/$MPV_FALLBACK_NAME"
if [[ -e "$MPV_FALLBACK_DESTINATION" || -L "$MPV_FALLBACK_DESTINATION" ]]; then
  print -u2 "mpv fallback destination is already occupied outside the media manifest: $MPV_FALLBACK_DESTINATION"
  return 1
fi
copy_registered_media_leaf "$MPV_FALLBACK_SOURCE" "$MPV_FALLBACK_NAME" ||
  return 1
chmod u+w "$MPV_FALLBACK_DESTINATION" || return 1
rewrite_install_id "$MPV_FALLBACK_DESTINATION" \
  "@rpath/$MPV_FALLBACK_NAME" || return 1
OWNED+=("$MPV_FALLBACK_NAME")
DESTINATION_SOURCES[$MPV_FALLBACK_NAME]="$MPV_FALLBACK_SOURCE"
SOURCE_ORIGINS[$MPV_FALLBACK_DESTINATION]="$MPV_FALLBACK_SOURCE"
SOURCE_ORIGINS[$EXECUTABLE]="$SOURCE_EXECUTABLE"

# Record flat dylibs already owned by Qt deployment before copying media
# closure leaves. An absolute dependency may not silently replace an existing
# file merely because the two sources share a basename.
for existing_library in "$FRAMEWORKS"/*.dylib(N); do
  if [[ -n "${SOURCE_ORIGINS[$existing_library]-}" ]]; then
    continue
  fi
  existing_name="${existing_library:t}"
  source_existing_library="$source_app/Contents/Frameworks/$existing_name"
  if [[ -f "$source_existing_library" ]]; then
    SOURCE_ORIGINS[$existing_library]="${source_existing_library:A}"
  else
    print -u2 "Staged Frameworks leaf has no exact source origin: $existing_library"
    return 1
  fi
  if [[ -z "${DESTINATION_SOURCES[$existing_name]-}" ]]; then
    DESTINATION_SOURCES[$existing_name]="${SOURCE_ORIGINS[$existing_library]}"
  fi
done

# libmpv is intentionally absent from WAM's load commands. Seed its copied
# canonical root explicitly so the normal closure traversal still discovers
# and packages every non-system dependency.
build_effective_runpath_stack "$SOURCE_EXECUTABLE" "$SOURCE_EXECUTABLE" ||
  return 1
typeset -a EXECUTABLE_ROOT_RUNPATHS
EXECUTABLE_ROOT_RUNPATHS=("${WAM_EFFECTIVE_RUNPATHS[@]}")
enqueue_load_context "$EXECUTABLE" "$SOURCE_EXECUTABLE" \
  "$SOURCE_EXECUTABLE"
enqueue_load_context "$MPV_FALLBACK_DESTINATION" "$MPV_FALLBACK_SOURCE" \
  "$SOURCE_EXECUTABLE" "${EXECUTABLE_ROOT_RUNPATHS[@]}"
if [[ -x "$TOOLS/ffmpeg" ]]; then
  enqueue_load_context "$TOOLS/ffmpeg" "${SOURCE_ORIGINS[$TOOLS/ffmpeg]}" \
    "${SOURCE_ORIGINS[$TOOLS/ffmpeg]}"
fi
if [[ -x "$TOOLS/whisper-cli" ]]; then
  enqueue_load_context "$TOOLS/whisper-cli" \
    "${SOURCE_ORIGINS[$TOOLS/whisper-cli]}" \
    "${SOURCE_ORIGINS[$TOOLS/whisper-cli]}"
fi

index=1
while (( index <= ${#QUEUE_CONTEXTS[@]} )); do
  context_id="${QUEUE_CONTEXTS[$index]}"
  (( index += 1 ))
  binary="${CONTEXT_BINARIES[$context_id]}"
  source_binary="${CONTEXT_SOURCES[$context_id]}"
  execution_root="${CONTEXT_EXECUTION_ROOTS[$context_id]}"
  read_context_runpaths "$context_id" || return 1
  typeset -a inherited_runpaths effective_runpaths
  inherited_runpaths=("${WAM_CONTEXT_RUNPATHS[@]}")
  build_effective_runpath_stack "$source_binary" "$execution_root" \
    "${inherited_runpaths[@]}" || return 1
  effective_runpaths=("${WAM_EFFECTIVE_RUNPATHS[@]}")
  set_context_key "$binary" "$source_binary" "$execution_root" \
    "${effective_runpaths[@]}"
  if [[ -n "${PROCESSED_CONTEXTS[$WAM_CONTEXT_KEY]-}" ]]; then
    continue
  fi
  PROCESSED_CONTEXTS[$WAM_CONTEXT_KEY]=1
  typeset -a binary_dependencies
  read_loaded_dependencies "$source_binary" || return 1
  binary_dependencies=("${WAM_INTROSPECTION_LINES[@]}")
  for dependency in "${binary_dependencies[@]}"; do
    [[ -z "$dependency" ]] && continue
    validate_dependency_path_syntax "$dependency" || return 1
    is_system_library "$dependency" && continue
    if ! resolve_dependency_in_context "$binary" "$source_binary" \
        "$execution_root" "$dependency" "${effective_runpaths[@]}"; then
      print -u2 "Could not resolve non-system dependency in $binary: $dependency"
      return 1
    fi
    source="$WAM_RESOLVED_SOURCE"
    validate_closure_leaf "$source" || return 1
    set_edge_key "$binary" "$dependency"
    if [[ -n "${EDGE_SOURCES[$WAM_EDGE_KEY]-}" &&
          "${EDGE_SOURCES[$WAM_EDGE_KEY]}" != "$source" ]]; then
      print -u2 "Dependency resolves differently across dyld load chains in $binary: $dependency"
      print -u2 "  first source: ${EDGE_SOURCES[$WAM_EDGE_KEY]}"
      print -u2 "  second source: $source"
      return 1
    fi
    EDGE_SOURCES[$WAM_EDGE_KEY]="$source"

    # Frameworks must already have been deployed and rewritten by Qt. Copying
    # a framework binary as a flat dylib would corrupt its layout.
    if [[ "$dependency" == *'.framework/'* ||
          "$source" == *'.framework/'* ]]; then
      if [[ "$source" == "$source_app/Contents/Frameworks"/* ]]; then
        packaged_framework="$FRAMEWORKS/${source#$source_app/Contents/Frameworks/}"
      elif [[ "$source" == "$FRAMEWORKS"/* ]]; then
        packaged_framework="$source"
      else
        print -u2 "Unbundled framework dependency in ${binary:t}: $dependency"
        return 1
      fi
      if [[ ! -f "$packaged_framework" || -L "$packaged_framework" ]]; then
        print -u2 "Missing exact staged framework dependency: $packaged_framework"
        return 1
      fi
      EDGE_DESTINATIONS[$WAM_EDGE_KEY]="$packaged_framework"
      if [[ -n "${SOURCE_ORIGINS[$packaged_framework]-}" &&
            "${SOURCE_ORIGINS[$packaged_framework]}" != "$source" ]]; then
        print -u2 "Framework source provenance collision: $packaged_framework"
        return 1
      fi
      SOURCE_ORIGINS[$packaged_framework]="$source"
      enqueue_load_context "$packaged_framework" "$source" \
        "$execution_root" "${effective_runpaths[@]}"
      continue
    fi

    name="${dependency:t}"
    destination="${FRAMEWORKS:A}/$name"
    if [[ "$source" != "$destination" ]]; then
      recorded_source="${DESTINATION_SOURCES[$name]-}"
      if [[ -n "$recorded_source" && "$recorded_source" != "$source" ]]; then
        print -u2 "Media dependency basename collision for $name"
        print -u2 "  first source: $recorded_source"
        print -u2 "  second source: $source"
        return 1
      fi
      if [[ -e "$destination" || -L "$destination" ]]; then
        if [[ -z "$recorded_source" ]]; then
          print -u2 "Media dependency destination is already occupied: $destination"
          return 1
        fi
        SOURCE_ORIGINS[$destination]="$source"
        enqueue_load_context "$destination" "$source" \
          "$execution_root" "${effective_runpaths[@]}"
      else
        copy_registered_media_leaf "$source" "$name" || return 1
        chmod u+w "$destination" || return 1
        rewrite_install_id "$destination" "@rpath/$name" || return 1
        OWNED+=("$name")
        SOURCE_ORIGINS[$destination]="$source"
        enqueue_load_context "$destination" "$source" \
          "$execution_root" "${effective_runpaths[@]}"
      fi
      DESTINATION_SOURCES[$name]="$source"
      EDGE_DESTINATIONS[$WAM_EDGE_KEY]="$destination"
    elif [[ -f "$destination" ]]; then
      enqueue_load_context "$destination" "$source" \
        "$execution_root" "${effective_runpaths[@]}"
      EDGE_DESTINATIONS[$WAM_EDGE_KEY]="$destination"
    fi
  done
done

typeset -a TARGETS
typeset -A TARGET_SEEN
for context_id in "${QUEUE_CONTEXTS[@]}"; do
  target="${CONTEXT_BINARIES[$context_id]}"
  if [[ -z "${TARGET_SEEN[$target]-}" ]]; then
    TARGETS+=("$target")
    TARGET_SEEN[$target]=1
  fi
done
for target in "$FRAMEWORKS"/*.dylib(N); do
  if [[ -z "${TARGET_SEEN[$target]-}" ]]; then
    TARGETS+=("$target")
    TARGET_SEEN[$target]=1
  fi
done
for target in "$FRAMEWORKS"/*.dylib(N); do
  expected_id="@rpath/${target:t}"
  if ! current_id_output="$(list_install_names "$target")"; then
    return 1
  fi
  typeset -a current_install_names
  current_install_names=("${(@f)current_id_output}")
  current_id="${current_install_names[1]-}"
  if [[ "$current_id" != "$expected_id" ]]; then
      rewrite_install_id "$target" "$expected_id" || return 1
  fi
done
for target in "${TARGETS[@]}"; do
  typeset -a target_dependencies
  read_loaded_dependencies "$target" || return 1
  target_dependencies=("${WAM_INTROSPECTION_LINES[@]}")
  for dependency in "${target_dependencies[@]}"; do
    [[ -z "$dependency" ]] && continue
    set_edge_key "$target" "$dependency"
    packaged_dependency="${EDGE_DESTINATIONS[$WAM_EDGE_KEY]-}"
    if [[ -n "$packaged_dependency" ]]; then
      # MpvRuntime opens the root through /dev/fd, so the shared production
      # helper makes its edge executable-relative while retaining loader-
      # relative edges for ordinary Frameworks siblings.
      rewrite_dependency_edge "$target" "$dependency" \
        "$packaged_dependency" || return 1
    fi
  done
done

# Media binaries can contain package-manager-specific rpaths even after every
# dependency has been made loader-relative. Strip all such development paths
# from the executable, flat media libraries, and bundled command-line tools.
for target in "${TARGETS[@]}"; do
  typeset -a target_rpaths
  read_runtime_search_paths "$target" || return 1
  target_rpaths=("${WAM_INTROSPECTION_LINES[@]}")
  for external_rpath in "${target_rpaths[@]}"; do
    if [[ "$external_rpath" == /opt/homebrew* ||
          "$external_rpath" == /usr/local* ||
          "$external_rpath" == /Users/runner/work* ||
          "$external_rpath" == */build/* ]]; then
      if ! "$INSTALL_NAME_TOOL" -delete_rpath "$external_rpath" \
          "$target"; then
        print -u2 "Could not remove development RPATH from $target: $external_rpath"
        return 1
      fi
    fi
  done
done
read_runtime_search_paths "$EXECUTABLE" || return 1
typeset -a executable_rpaths
executable_rpaths=("${WAM_INTROSPECTION_LINES[@]}")
if (( ${executable_rpaths[(I)@executable_path/../Frameworks]} == 0 )); then
  if ! "$INSTALL_NAME_TOOL" -add_rpath \
      "@executable_path/../Frameworks" "$EXECUTABLE"; then
    print -u2 "Could not add the packaged Frameworks RPATH to WAM"
    return 1
  fi
fi

: > "$MEDIA_MANIFEST" || return 1
for owned_name in "${OWNED[@]}"; do
  print -r -- "$owned_name" >> "$MEDIA_MANIFEST" || return 1
done

# Build a complete Mach-O inventory, including Qt frameworks, plugins, and QML
# extensions. A whitelist audit is intentionally stricter than checking for a
# few known package-manager prefixes: every non-system dependency must resolve
# to a real file inside this app bundle.
typeset -a BUNDLE_MACHOS
typeset -a bundle_files
read_found_paths f "$APP_PATH/Contents" || return 1
bundle_files=("${WAM_INTROSPECTION_LINES[@]}")
for audit_file in "${bundle_files[@]}"; do
  if ! audit_description="$(file -b "$audit_file")"; then
    print -u2 "Could not inspect packaged file: $audit_file"
    return 1
  fi
  [[ "$audit_description" == *Mach-O* ]] || continue
  BUNDLE_MACHOS+=("$audit_file")
done

if (( ${#BUNDLE_MACHOS[@]} == 0 )); then
  print -u2 "No Mach-O payload was found in $APP_PATH"
  return 1
fi
BUNDLE_MACHOS=("${(@oa)BUNDLE_MACHOS}")

is_inside_app() {
  [[ "$1" == "$APP_PATH" || "$1" == "$APP_PATH"/* ]]
}

resolve_relative_path() {
  local target="$1"
  local value="$2"
  local executable_context="${3:-$EXECUTABLE}"
  if [[ "$value" == @loader_path/* ]]; then
    print -r -- "${target:h}/${value#@loader_path/}"
  elif [[ "$value" == @executable_path/* ]]; then
    print -r -- "${executable_context:h}/${value#@executable_path/}"
  elif [[ "$value" == /* ]]; then
    print -r -- "$value"
  fi
}

resolve_packaged_dependency() {
  local target="$1"
  local dependency="$2"
  local suffix candidate rpath rpath_root executable_context
  local -a candidates packaged_rpaths executable_rpaths

  if [[ "$target" == "$TOOLS"/* ]]; then
    executable_context="$target"
  else
    executable_context="$EXECUTABLE"
  fi

  if [[ "$dependency" == @loader_path/* ||
        "$dependency" == @executable_path/* ]]; then
    if ! candidate="$(resolve_relative_path \
        "$target" "$dependency" "$executable_context")" ||
        [[ -z "$candidate" ]]; then
      return 1
    fi
    candidates+=("$candidate")
  elif [[ "$dependency" == @rpath/* ]]; then
    suffix="${dependency#@rpath/}"
    read_runtime_search_paths "$target" || return 1
    packaged_rpaths=("${WAM_INTROSPECTION_LINES[@]}")
    for rpath in "${packaged_rpaths[@]}"; do
      if ! rpath_root="$(resolve_relative_path \
          "$target" "$rpath" "$executable_context")"; then
        return 1
      fi
      [[ -n "$rpath_root" ]] || return 1
      candidates+=("$rpath_root/$suffix")
    done
    if [[ "$target" != "$executable_context" ]]; then
      read_runtime_search_paths "$executable_context" || return 1
      executable_rpaths=("${WAM_INTROSPECTION_LINES[@]}")
      for rpath in "${executable_rpaths[@]}"; do
        if ! rpath_root="$(resolve_relative_path \
            "$executable_context" "$rpath" "$executable_context")"; then
          return 1
        fi
        [[ -n "$rpath_root" ]] || return 1
        candidates+=("$rpath_root/$suffix")
      done
    fi
  else
    return 1
  fi

  for candidate in "${candidates[@]}"; do
    [[ -f "$candidate" ]] || continue
    candidate="${candidate:A}"
    if is_inside_app "$candidate"; then
      print -r -- "$candidate"
      return 0
    fi
  done
  return 1
}

# Remove development-only absolute rpaths from every packaged image, not only
# WAM's own media binaries. The closure audit below proves they are unnecessary.
for audit_file in "${BUNDLE_MACHOS[@]}"; do
  typeset -a audit_rpaths
  audit_execution_context="$EXECUTABLE"
  [[ "$audit_file" != "$TOOLS"/* ]] || audit_execution_context="$audit_file"
  read_runtime_search_paths "$audit_file" || return 1
  audit_rpaths=("${WAM_INTROSPECTION_LINES[@]}")
  for packaged_rpath in "${audit_rpaths[@]}"; do
    remove_rpath=false
    if [[ "$packaged_rpath" == /* ]]; then
      validate_dependency_path_syntax "$packaged_rpath" || return 1
      if ! is_system_library "$packaged_rpath"; then
        remove_rpath=true
      fi
    else
      if ! resolved_rpath="$(resolve_relative_path \
          "$audit_file" "$packaged_rpath" \
          "$audit_execution_context")"; then
        resolved_rpath=""
      fi
      if [[ -z "$resolved_rpath" || ! -d "$resolved_rpath" ]]; then
        remove_rpath=true
      else
        resolved_rpath="${resolved_rpath:A}"
        is_inside_app "$resolved_rpath" || remove_rpath=true
      fi
    fi
    if [[ "$remove_rpath" == true ]]; then
      if ! "$INSTALL_NAME_TOOL" -delete_rpath "$packaged_rpath" \
          "$audit_file"; then
        print -u2 "Could not remove external RPATH from $audit_file: $packaged_rpath"
        return 1
      fi
    fi
  done
done

read_macos_slice_minos() {
  local binary="$1"
  local architecture="$2"
  local load_commands
  if ! load_commands="$(otool -arch "$architecture" -l "$binary")"; then
    print -u2 "Could not inspect Mach-O slice minimum OS: $binary ($architecture)"
    return 1
  fi
  if ! awk '
      function finish_build() {
        if (in_build && (platform_count != 1 || minos_count != 1)) exit 65
      }
      $1 == "cmd" {
        finish_build()
        in_build = ($2 == "LC_BUILD_VERSION")
        if (in_build) {
          build_count += 1
          platform_count = 0
          minos_count = 0
        }
        next
      }
      in_build && $1 == "platform" {
        platform_count += 1
        if ($2 != "1" && $2 != "MACOS") exit 65
        next
      }
      in_build && $1 == "minos" {
        minos_count += 1
        if ($2 !~ /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?$/) exit 65
        minos = $2
        next
      }
      END {
        finish_build()
        if (build_count != 1 || minos == "") exit 65
        print minos
      }
    ' <<< "$load_commands"; then
    print -u2 "Could not prove one macOS LC_BUILD_VERSION: $binary ($architecture)"
    return 1
  fi
}

max_minos="0.0"
max_minos_score=0
local audit_minos_output
for audit_file in "${BUNDLE_MACHOS[@]}"; do
  typeset -a audit_dependencies
  if ! audit_arches="$(lipo -archs "$audit_file")" ||
      [[ -z "$audit_arches" ]]; then
    print -u2 "Could not inspect packaged architectures: $audit_file"
    return 1
  fi
  for required_arch in ${=WAM_REQUIRED_ARCHES}; do
    if [[ " $audit_arches " != *" $required_arch "* ]]; then
      print -u2 "Packaged Mach-O lacks WAM architecture $required_arch: $audit_file"
      return 1
    fi
  done
  if [[ -n "$RELEASE_FLOOR" ]]; then
    for audit_arch in ${=audit_arches}; do
      if [[ "$audit_arch" == -* ||
            ! "$audit_arch" =~ "^[A-Za-z0-9_]+$" ]]; then
        print -u2 "Invalid packaged Mach-O architecture: $audit_arch"
        return 1
      fi
      if ! minos="$(read_macos_slice_minos \
          "$audit_file" "$audit_arch")" || [[ -z "$minos" ]] ||
          ! minos_score="$(score_macos_version "$minos")" ||
          [[ -z "$minos_score" ]]; then
        return 1
      fi
      if (( minos_score > RELEASE_FLOOR_SCORE )); then
        print -u2 "Mach-O slice requires macOS $minos above release floor $RELEASE_FLOOR: $audit_file ($audit_arch)"
        return 1
      fi
      if (( minos_score > max_minos_score )); then
        max_minos="$minos"
        max_minos_score="$minos_score"
      fi
    done
  fi
  audit_execution_context="$EXECUTABLE"
  [[ "$audit_file" != "$TOOLS"/* ]] || audit_execution_context="$audit_file"
  read_loaded_dependencies "$audit_file" || return 1
  audit_dependencies=("${WAM_INTROSPECTION_LINES[@]}")
  for dependency in "${audit_dependencies[@]}"; do
    [[ -n "$dependency" ]] || continue
    validate_dependency_path_syntax "$dependency" || return 1
    if is_system_library "$dependency"; then
      continue
    fi
    if [[ "$dependency" == /* ]]; then
      print -u2 "External absolute dependency in $audit_file: $dependency"
      return 1
    fi
    if ! resolved_dependency="$(resolve_packaged_dependency \
        "$audit_file" "$dependency")"; then
      print -u2 "Unresolved packaged dependency in $audit_file: $dependency"
      return 1
    fi
  done

  read_runtime_search_paths "$audit_file" || return 1
  audit_rpaths=("${WAM_INTROSPECTION_LINES[@]}")
  for packaged_rpath in "${audit_rpaths[@]}"; do
    [[ -n "$packaged_rpath" ]] || continue
    validate_dependency_path_syntax "$packaged_rpath" || return 1
    if is_system_library "$packaged_rpath"; then
      continue
    fi
    if ! resolved_rpath="$(resolve_relative_path \
        "$audit_file" "$packaged_rpath" \
        "$audit_execution_context")"; then
      resolved_rpath=""
    fi
    if [[ -z "$resolved_rpath" || ! -d "$resolved_rpath" ]]; then
      print -u2 "Unresolved runtime search path in $audit_file: $packaged_rpath"
      return 1
    fi
    resolved_rpath="${resolved_rpath:A}"
    if ! is_inside_app "$resolved_rpath"; then
      print -u2 "Runtime search path escapes the app in $audit_file: $packaged_rpath"
      return 1
    fi
  done

  if [[ -z "$RELEASE_FLOOR" ]]; then
    if ! audit_load_commands="$(otool -l "$audit_file")"; then
      print -u2 "Could not inspect Mach-O minimum OS: $audit_file"
      return 1
    fi
    if ! audit_minos_output="$(awk \
        '$1 == "cmd" {
           if (wanted) exit 65
           wanted = ($2 == "LC_BUILD_VERSION")
           next
         }
         wanted && $1 == "minos" {
           if ($2 !~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/) exit 65
           print $2
           wanted = 0
         }
         END { if (wanted) exit 65 }' \
        <<< "$audit_load_commands")"; then
      print -u2 "Could not parse Mach-O minimum OS: $audit_file"
      return 1
    fi
    typeset -a audit_minos
    audit_minos=("${(@f)audit_minos_output}")
    for minos in "${audit_minos[@]}"; do
      [[ -n "$minos" ]] || continue
      if ! minos_score="$(score_macos_version "$minos")" ||
          [[ -z "$minos_score" ]]; then
        print -u2 "Could not score Mach-O minimum OS: $minos"
        return 1
      fi
      if (( minos_score > max_minos_score )); then
        max_minos="$minos"
        max_minos_score="$minos_score"
      fi
    done
  fi
done

# Development packages truthfully advertise their highest dependency floor.
# Release packages instead prove every architecture is at or below the one
# declared floor and require the build-generated plist to state it exactly.
INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [[ -n "$RELEASE_FLOOR" ]]; then
  if [[ ! -f "$INFO_PLIST" || -L "$INFO_PLIST" ||
        "${INFO_PLIST:A}" != "$INFO_PLIST" ]] ||
      ! packaged_minos="$(/usr/bin/plutil -extract \
        LSMinimumSystemVersion raw -expect string -o - "$INFO_PLIST")"; then
    print -u2 "Release Info.plist has no canonical minimum macOS string"
    return 1
  fi
  if [[ "$packaged_minos" != "$RELEASE_FLOOR" ]]; then
    print -u2 "Info.plist minimum macOS is $packaged_minos; release floor is $RELEASE_FLOOR"
    return 1
  fi
elif (( max_minos_score > 0 )); then
  chmod u+w "$INFO_PLIST" || return 1
  if /usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST" \
      >/dev/null 2>&1; then
    if ! /usr/libexec/PlistBuddy -c \
        "Set :LSMinimumSystemVersion $max_minos" "$INFO_PLIST"; then
      print -u2 "Could not update Info.plist minimum macOS"
      return 1
    fi
  else
    if ! /usr/libexec/PlistBuddy -c \
        "Add :LSMinimumSystemVersion string $max_minos" "$INFO_PLIST"; then
      print -u2 "Could not add Info.plist minimum macOS"
      return 1
    fi
  fi
  if ! packaged_minos="$(/usr/libexec/PlistBuddy -c \
      'Print :LSMinimumSystemVersion' "$INFO_PLIST")"; then
    print -u2 "Could not verify Info.plist minimum macOS"
    return 1
  fi
  if [[ "$packaged_minos" != "$max_minos" ]]; then
    print -u2 "Info.plist minimum macOS is $packaged_minos; expected $max_minos"
    return 1
  fi
fi

# MpvRuntime validates this exact leaf before dlopen. Recheck the completed
# package after every dependency rewrite and before any signature can bless it.
validate_final_mpv_fallback || return 1
if [[ ! -x "$TOOLS/ffmpeg" || ! -x "$TOOLS/whisper-cli" ]]; then
  print -u2 "Packaging mutation removed a required tool's executable mode"
  return 1
fi

remove_finder_info_if_present() {
  local target="$1"
  local attribute_output
  local -a attribute_names
  if ! attribute_output="$(/usr/bin/xattr "$target")"; then
    print -u2 "Could not inspect extended attributes: $target"
    return 1
  fi
  attribute_names=("${(@f)attribute_output}")
  if (( ${attribute_names[(I)com.apple.FinderInfo]} != 0 )); then
    if ! /usr/bin/xattr -d com.apple.FinderInfo "$target"; then
      print -u2 "Could not remove FinderInfo from $target"
      return 1
    fi
  fi
}

# Revalidate the entire link graph immediately before any recursive metadata
# operation and again before each signature. The validator follows every link
# just far enough to prove its canonical target remains inside this app.
validate_bundle_tree "$APP_PATH" || return 1
if ! /usr/bin/xattr -cr "$APP_PATH"; then
  print -u2 "Could not clear extended attributes from $APP_PATH"
  return 1
fi
remove_finder_info_if_present "$APP_PATH" || return 1

verify_release_signature_facts() {
  local target="$1"
  local target_arches target_arch signature_details authority team
  local timestamp_count entitlements_file entitlement_value
  local release_requirement
  release_requirement="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""
  if ! codesign --verify --strict --all-architectures \
      -R "$release_requirement" "$target"; then
    print -u2 "Packaged code does not satisfy Developer ID trust: $target"
    return 1
  fi
  if [[ "$target" == "$APP_PATH" ]]; then
    target_arches="$WAM_REQUIRED_ARCHES"
  elif ! target_arches="$(lipo -archs "$target")" ||
      [[ -z "$target_arches" ]]; then
    print -u2 "Could not inspect signed target architectures: $target"
    return 1
  fi
  for target_arch in ${=target_arches}; do
    if ! signature_details="$(LC_ALL=C codesign -d --verbose=4 \
        --arch "$target_arch" "$target" 2>&1)"; then
      print -u2 "Could not inspect release signature: $target ($target_arch)"
      return 1
    fi
    authority="$(awk -F= '$1 == "Authority" { print substr($0, 11); exit }' \
      <<< "$signature_details")"
    team="$(awk -F= '$1 == "TeamIdentifier" { print substr($0, 16); exit }' \
      <<< "$signature_details")"
    timestamp_count="$(awk -F= '
      $1 == "Timestamp" { total += 1; if (length($0) > 10) valid += 1 }
      END { print total ":" valid }
    ' <<< "$signature_details")"
    if [[ "$authority" != "$EXPECTED_SIGNING_AUTHORITY" ||
          "$team" != "$EXPECTED_TEAM_ID" ||
          "$timestamp_count" != "1:1" ]] ||
        ! grep -Eq '^CodeDirectory .*flags=.*\([^)]*runtime[^)]*\)' \
          <<< "$signature_details"; then
      print -u2 "Release signature facts do not match policy: $target ($target_arch)"
      return 1
    fi
    if ! entitlements_file="$(mktemp \
        "${TMPDIR:-/tmp}/wam-entitlements.XXXXXX")"; then
      print -u2 "Could not create an entitlement audit file"
      return 1
    fi
    if ! LC_ALL=C codesign -d --arch "$target_arch" --xml \
        --entitlements "$entitlements_file" "$target" >/dev/null 2>&1; then
      /bin/rm -f -- "$entitlements_file"
      print -u2 "Could not inspect release entitlements: $target ($target_arch)"
      return 1
    fi
    if [[ -s "$entitlements_file" ]]; then
      if ! /usr/bin/plutil -lint "$entitlements_file" >/dev/null; then
        /bin/rm -f -- "$entitlements_file"
        print -u2 "Release entitlements are not a valid plist: $target ($target_arch)"
        return 1
      fi
      if entitlement_value="$(/usr/bin/plutil -extract \
          'com\.apple\.security\.get-task-allow' raw -o - \
          "$entitlements_file" 2>/dev/null)"; then
        /bin/rm -f -- "$entitlements_file"
        print -u2 "Release code contains get-task-allow: $target ($target_arch)"
        return 1
      fi
    fi
    if ! /bin/rm -f -- "$entitlements_file"; then
      print -u2 "Could not remove the entitlement audit file"
      return 1
    fi
  done
}

# Sign every Mach-O leaf explicitly. `codesign --deep` only discovers nested
# code in conventional bundle locations such as Frameworks and PlugIns; Qt's
# QML plugins live under Resources/qml and are otherwise sealed as data. Since
# install_name_tool rewrites those plugins above, leaving even one with its old
# signature causes macOS to kill WAM with CODESIGNING/Invalid Page as soon as
# QQmlPluginImporter maps it.
for target in "${BUNDLE_MACHOS[@]}"; do
  validate_bundle_tree "$APP_PATH" || return 1
  if [[ ! -f "$target" || -L "$target" || "${target:A}" != "$target" ||
        "$target" != "$APP_PATH"/* ]]; then
    print -u2 "Mach-O signing target changed identity or escaped the app: $target"
    return 1
  fi
  if ! /usr/bin/xattr -cr "$target"; then
    print -u2 "Could not clear extended attributes from $target"
    return 1
  fi
  if [[ "$RELEASE_SIGNING" == true ]]; then
    signing_arguments=(--force --sign "$CODESIGN_IDENTITY" \
      --options runtime --timestamp)
  else
    signing_arguments=(--force --sign -)
  fi
  if ! codesign "${signing_arguments[@]}" "$target"; then
    print -u2 "Could not sign packaged Mach-O: $target"
    return 1
  fi
done
validate_bundle_tree "$APP_PATH" || return 1
remove_finder_info_if_present "$APP_PATH" || return 1
typeset -a NESTED_CODE_CONTAINERS bundle_directories
read_found_paths d "$APP_PATH/Contents" || return 1
bundle_directories=("${WAM_INTROSPECTION_LINES[@]}")
for code_container in "${bundle_directories[@]}"; do
  case "$code_container" in
    *.framework|*.bundle|*.plugin|*.xpc|*.appex|*.app)
      NESTED_CODE_CONTAINERS+=("$code_container")
      ;;
  esac
done
NESTED_CODE_CONTAINERS=("${(@Oa)NESTED_CODE_CONTAINERS}")
if [[ "$RELEASE_SIGNING" == true ]]; then
  for code_container in "${NESTED_CODE_CONTAINERS[@]}"; do
    validate_bundle_tree "$APP_PATH" || return 1
    if [[ ! -d "$code_container" || -L "$code_container" ||
          "${code_container:A}" != "$code_container" ||
          "$code_container" != "$APP_PATH"/* ]]; then
      print -u2 "Nested signing target changed identity or escaped the app: $code_container"
      return 1
    fi
    if ! codesign --force --sign "$CODESIGN_IDENTITY" \
        --options runtime --timestamp "$code_container"; then
      print -u2 "Could not sign packaged code container: $code_container"
      return 1
    fi
  done
  if ! codesign --force --sign "$CODESIGN_IDENTITY" \
      --options runtime --timestamp "$APP_PATH"; then
    print -u2 "Could not Developer ID sign packaged app: $APP_PATH"
    return 1
  fi
else
  if ! codesign --force --deep --sign - "$APP_PATH"; then
    print -u2 "Could not sign packaged app: $APP_PATH"
    return 1
  fi
fi

# Bundle-level deep verification does not validate executable pages hidden in
# Resources. Gate every leaf as well as the outer bundle so this class of
# launch-time failure cannot regress silently.
for target in "${BUNDLE_MACHOS[@]}"; do
  if ! codesign --verify --strict "$target"; then
    print -u2 "Invalid code signature in packaged Mach-O: $target"
    return 1
  fi
  if [[ "$RELEASE_SIGNING" == true ]]; then
    verify_release_signature_facts "$target" || return 1
  fi
done
if [[ "$RELEASE_SIGNING" == true ]]; then
  for code_container in "${NESTED_CODE_CONTAINERS[@]}"; do
    if ! codesign --verify --strict "$code_container"; then
      print -u2 "Invalid signature on packaged code container: $code_container"
      return 1
    fi
  done
fi
if ! codesign --verify --deep --strict "$APP_PATH"; then
  print -u2 "Packaged app failed strict code-signature verification"
  return 1
fi
if [[ "$RELEASE_SIGNING" == true ]]; then
  verify_release_signature_facts "$APP_PATH" || return 1
fi
print "Bundled ${#OWNED[@]} media runtime libraries into Qt app $APP_PATH"
if [[ -n "$RELEASE_FLOOR" ]]; then
  print "Audited ${#BUNDLE_MACHOS[@]} Mach-O files; release floor is $RELEASE_FLOOR (maximum payload minimum $max_minos)"
else
  print "Audited ${#BUNDLE_MACHOS[@]} Mach-O files; minimum packaged macOS is $max_minos"
fi
}

(
  APP_PATH="$FINAL_APP_PATH"
  EXECUTABLE="$APP_PATH/Contents/MacOS/WAM"
  FRAMEWORKS="$APP_PATH/Contents/Frameworks"
  PLUGINS="$APP_PATH/Contents/PlugIns"
  RESOURCES="$APP_PATH/Contents/Resources"
  TOOLS="$RESOURCES/tools"
  MODELS="$RESOURCES/models"
  MEDIA_MANIFEST="$RESOURCES/wam-media-libraries.manifest"

  validate_bundle_tree "$FINAL_APP_PATH" || return 1
  read_path_identity "${FINAL_APP_PATH:h}" || return 1
  final_parent_device="$WAM_PATH_DEVICE"
  final_parent_inode="$WAM_PATH_INODE"
  read_path_identity "$FINAL_APP_PATH" || return 1
  final_app_device="$WAM_PATH_DEVICE"
  final_app_inode="$WAM_PATH_INODE"

  if ! stage_directory="$(mktemp -d \
      "${FINAL_APP_PATH:h}/.wam-bundle-stage.XXXXXX")"; then
    print -u2 "Could not create an app packaging stage"
    return 1
  fi
  read_path_identity "$stage_directory" || return 1
  stage_parent_device="$WAM_PATH_DEVICE"
  stage_parent_inode="$WAM_PATH_INODE"
  staged_app="$stage_directory/${FINAL_APP_PATH:t}"
  swap_helper="$stage_directory/wam-atomic-swap"
  wam_child_active=false
  wam_stage_cleanup_allowed=true
  stage_app_device=""
  stage_app_inode=""
  cleanup_app_device=""
  cleanup_app_inode=""
  helper_device=""
  helper_inode=""
  swap_sdk=""

  cleanup_staging_transaction() {
    local cleanup_status
    if [[ ! -e "$stage_directory" && ! -L "$stage_directory" ]]; then
      return 0
    fi
    if [[ "$wam_child_active" == true ]]; then
      print -u2 "Packaging stage retained while a child may still own it: $stage_directory"
      return 1
    fi
    if [[ "$wam_stage_cleanup_allowed" != true ]]; then
      print -u2 "Packaging stage retained after an uncertain swap: $stage_directory"
      return 1
    fi
    if [[ -z "$cleanup_app_device" || -z "$cleanup_app_inode" ||
          -z "$helper_device" || -z "$helper_inode" ||
          ! -x "$swap_helper" || -L "$swap_helper" ]]; then
      print -u2 "Packaging stage retained without a complete cleanup identity: $stage_directory"
      return 1
    fi
    wam_child_active=true
    if "$swap_helper" cleanup \
        "${stage_directory:h}" "${stage_directory:t}" \
        "$final_parent_device" "$final_parent_inode" \
        "$stage_parent_device" "$stage_parent_inode" \
        "${staged_app:t}" "$cleanup_app_device" "$cleanup_app_inode" \
        "${swap_helper:t}" "$helper_device" "$helper_inode"; then
      cleanup_status=0
    else
      cleanup_status=$?
    fi
    wam_child_active=false
    if (( cleanup_status != 0 )); then
      print -u2 "Identity-checked packaging stage was conservatively retained: $stage_directory"
      return 1
    fi
    return 0
  }
  trap cleanup_staging_transaction EXIT
  trap 'wam_child_active=true; exit 129' HUP
  trap 'wam_child_active=true; exit 130' INT
  trap 'wam_child_active=true; exit 143' TERM

  if ! swap_compiler="$(xcrun --find clang)" ||
      [[ -z "$swap_compiler" ]]; then
    print -u2 "Could not locate the atomic-swap helper compiler"
    return 1
  fi
  if ! swap_sdk="$(xcrun --sdk macosx --show-sdk-path)" ||
      [[ -z "$swap_sdk" || ! -d "$swap_sdk" ]]; then
    print -u2 "Could not locate the macOS SDK for the atomic-swap helper"
    return 1
  fi
  wam_child_active=true
  if ! "$swap_compiler" -std=c11 -Wall -Wextra -Wpedantic \
      -Wconversion -Wsign-conversion -Wshadow -Wstrict-prototypes -Werror \
      -isysroot "$swap_sdk" \
      "$WAM_BUNDLE_MACOS_LIBRARY_DIRECTORY/wam_atomic_swap.c" \
      -o "$swap_helper"; then
    wam_child_active=false
    return 1
  fi
  wam_child_active=false
  if [[ ! -f "$swap_helper" || -L "$swap_helper" || ! -x "$swap_helper" ]]; then
    print -u2 "Atomic-swap helper is not one executable regular file"
    return 1
  fi
  read_path_identity "$swap_helper" || return 1
  helper_device="$WAM_PATH_DEVICE"
  helper_inode="$WAM_PATH_INODE"

  wam_child_active=true
  if ! /bin/cp -cR "$FINAL_APP_PATH" "$staged_app"; then
    wam_child_active=false
    return 1
  fi
  wam_child_active=false
  validate_bundle_tree "$staged_app" || return 1
  read_path_identity "$staged_app" || return 1
  stage_app_device="$WAM_PATH_DEVICE"
  stage_app_inode="$WAM_PATH_INODE"
  cleanup_app_device="$stage_app_device"
  cleanup_app_inode="$stage_app_inode"

  # Run the staged mutation in its own process. Its `errexit` state is active:
  # the function call is an ordinary command, never the condition of `if` or
  # `!`. The parent checks only `wait`, after the mutator has completed.
  wam_child_active=true
  (
    set -euo pipefail
    wam_bundle_mutate_staged_app "$staged_app" "$FINAL_APP_PATH"
  ) &
  mutation_pid=$!
  if wait "$mutation_pid"; then
    mutation_status=0
  else
    mutation_status=$?
  fi
  wam_child_active=false
  if (( mutation_status != 0 )); then
    return 1
  fi

  validate_bundle_tree "$staged_app" || return 1
  path_has_identity "${FINAL_APP_PATH:h}" "$final_parent_device" \
    "$final_parent_inode" || return 1
  path_has_identity "$FINAL_APP_PATH" "$final_app_device" \
    "$final_app_inode" || return 1
  path_has_identity "$stage_directory" "$stage_parent_device" \
    "$stage_parent_inode" || return 1
  path_has_identity "$staged_app" "$stage_app_device" \
    "$stage_app_inode" || return 1
  wam_fail_if_requested before-swap || return 1

  wam_child_active=true
  wam_stage_cleanup_allowed=false
  swap_mode=swap
  if [[ "$WAM_TEST_FAULTS_ENABLED" == true &&
        "$WAM_TEST_FAULT" == helper-rollback ]]; then
    swap_mode=swap-rollback-test
  fi
  if "$swap_helper" "$swap_mode" \
      "${FINAL_APP_PATH:h}" "${FINAL_APP_PATH:t}" \
      "$final_parent_device" "$final_parent_inode" \
      "$final_app_device" "$final_app_inode" \
      "$stage_directory" "${staged_app:t}" \
      "$stage_parent_device" "$stage_parent_inode" \
      "$stage_app_device" "$stage_app_inode"; then
    swap_status=0
  else
    swap_status=$?
  fi
  wam_child_active=false
  if (( swap_status != 0 )); then
    if (( swap_status == 1 || swap_status == 2 )); then
      wam_stage_cleanup_allowed=true
    fi
    return 1
  fi
  path_has_identity "$FINAL_APP_PATH" "$stage_app_device" \
    "$stage_app_inode" || return 1
  path_has_identity "$staged_app" "$final_app_device" \
    "$final_app_inode" || return 1
  cleanup_app_device="$final_app_device"
  cleanup_app_inode="$final_app_inode"
  wam_stage_cleanup_allowed=true
  if ! cleanup_staging_transaction; then
    print -u2 "Packaging succeeded, but its recognized old-app stage was retained"
  fi
  trap - EXIT
)
}
