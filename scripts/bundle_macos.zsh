#!/bin/zsh
set -euo pipefail

APP_PATH="${1:-build/WAM.app}"
APP_PATH="${APP_PATH:A}"
WHISPER_SOURCE="${2:-build/runtime/whisper-cli}"
MODEL_SOURCE="${3:-$APP_PATH/Contents/Resources/models/ggml-base.en.bin}"
EXECUTABLE="$APP_PATH/Contents/MacOS/WAM"
FRAMEWORKS="$APP_PATH/Contents/Frameworks"
PLUGINS="$APP_PATH/Contents/PlugIns"
RESOURCES="$APP_PATH/Contents/Resources"
TOOLS="$APP_PATH/Contents/Resources/tools"
MODELS="$APP_PATH/Contents/Resources/models"
MEDIA_MANIFEST="$RESOURCES/wam-media-libraries.manifest"
INSTALL_NAME_TOOL="$(xcrun --find install_name_tool)"
BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"

if [[ ! -x "$EXECUTABLE" ]]; then
  print -u2 "WAM executable not found at $EXECUTABLE"
  exit 1
fi

# Qt's deployment step owns Frameworks, PlugIns, and Resources/qml. Never
# replace those directories here. Remove only media libraries copied by an
# earlier invocation of this script, then rebuild that small manifest.
if [[ -f "$MEDIA_MANIFEST" ]]; then
  while IFS= read -r owned_name; do
    if [[ "$owned_name" == *.dylib && "$owned_name" != */* ]]; then
      /bin/rm -f -- "$FRAMEWORKS/$owned_name"
    fi
  done < "$MEDIA_MANIFEST"
fi
mkdir -p "$FRAMEWORKS" "$PLUGINS" "$RESOURCES" "$TOOLS" "$MODELS"
/bin/rm -f -- "$TOOLS/ffmpeg" "$TOOLS/whisper-cli"
cp -f README.md THIRD_PARTY_NOTICES.md "$RESOURCES/"

if [[ ! -d "$FRAMEWORKS/QtCore.framework" ||
      ! -d "$FRAMEWORKS/QtQuick.framework" ||
      ! -f "$PLUGINS/platforms/libqcocoa.dylib" ||
      ! -d "$RESOURCES/qml/QtQuick" ]]; then
  print -u2 "Qt/QML runtime is missing from $APP_PATH"
  print -u2 "Run cmake --install (Qt deployment) before bundle_macos.zsh"
  exit 1
fi

# Homebrew Qt may deploy QML metadata and plugin binaries as malformed relative
# links back into its Cellar. Materialize only links whose resolved target is
# external to the app. CMake's official Qt deployment deliberately places QML
# plug-ins in Contents/PlugIns and links to them from Resources/qml; preserving
# those internal links also preserves the @loader_path directory macdeployqt
# used when it rewrote the plug-in's dependencies.
repaired_qt_links=0
materialize_qt_links() {
  local qml_link qml_source qml_link_target
  while IFS= read -r qml_link; do
    qml_source="${qml_link:A}"
    if [[ -f "$qml_source" &&
          ( "$qml_source" == "$APP_PATH" ||
            "$qml_source" == "$APP_PATH"/* ) ]]; then
      continue
    fi
    if [[ ! -f "$qml_source" && -n "$BREW_PREFIX" ]]; then
      qml_link_target="$(readlink "$qml_link")"
      if [[ "$qml_link_target" == *Cellar/* ]]; then
        qml_source="$BREW_PREFIX/Cellar/${qml_link_target#*Cellar/}"
      fi
    fi
    if [[ ! -f "$qml_source" ]]; then
      print -u2 "Qt deployment left an unresolved QML link: $qml_link"
      exit 1
    fi
    /bin/rm -f -- "$qml_link"
    cp -fL "$qml_source" "$qml_link"
    (( repaired_qt_links += 1 ))
  done < <(find "$PLUGINS" "$RESOURCES/qml" -type l)
}
materialize_qt_links

# CMake's first macdeployqt pass cannot inspect those dangling Homebrew plugin
# links and therefore omits their Qt framework closure. Once materialized, run
# the matching Qt deployer again so it can discover and copy every dependency.
# A pinned official Qt install normally has no broken links and skips this pass.
if (( repaired_qt_links > 0 )); then
  QMAKE_EXECUTABLE="${WAM_QMAKE_EXECUTABLE:-$(command -v qmake6 || command -v qmake || true)}"
  if [[ ! -x "$QMAKE_EXECUTABLE" ]]; then
    print -u2 "Qt deployment repair requires qmake6/qmake from the build Qt"
    exit 1
  fi
  QT_BIN_DIR="$($QMAKE_EXECUTABLE -query QT_INSTALL_BINS)"
  QT_LIB_DIR="$($QMAKE_EXECUTABLE -query QT_INSTALL_LIBS)"
  QT_QML_DIR="$($QMAKE_EXECUTABLE -query QT_INSTALL_QML)"
  MACDEPLOYQT="$QT_BIN_DIR/macdeployqt"
  if [[ ! -x "$MACDEPLOYQT" ]]; then
    print -u2 "Matching macdeployqt was not found at $MACDEPLOYQT"
    exit 1
  fi
  "$MACDEPLOYQT" "$APP_PATH" \
    "-qmldir=$PWD/qml" \
    "-qmlimport=$QT_QML_DIR" \
    "-libpath=$QT_LIB_DIR" \
    -always-overwrite -no-strip -no-codesign -verbose=1
  # macdeployqt may recreate the same package-manager links while copying the
  # now-complete closure. Materialize external links again while retaining its
  # intentional in-bundle QML plug-in links.
  materialize_qt_links
fi

# macdeployqt/CMake owns the Qt framework layout. Some package-manager Qt
# builds nevertheless leave their original absolute install names inside the
# copied framework binaries. Repair only references whose matching framework
# already exists in this app; never copy or flatten a Qt framework here.
typeset -a QT_DEPLOYED_MACHOS
QT_DEPLOYED_MACHOS=("$EXECUTABLE")
for qt_root in "$FRAMEWORKS" "$PLUGINS" "$RESOURCES/qml"; do
  while IFS= read -r qt_candidate; do
    file "$qt_candidate" | grep -q 'Mach-O' || continue
    QT_DEPLOYED_MACHOS+=("$qt_candidate")
  done < <(find "$qt_root" -type f)
done
for qt_target in "${QT_DEPLOYED_MACHOS[@]}"; do
  qt_relative="${qt_target#$FRAMEWORKS/}"
  if [[ "$qt_target" == "$FRAMEWORKS"/Qt*.framework/Versions/*/* &&
        "${qt_relative:t}" == "${${qt_relative%%.framework/*}:t}" ]]; then
    qt_expected_id="@rpath/$qt_relative"
    qt_current_id="$(otool -D "$qt_target" 2>/dev/null | tail -n 1 || true)"
    if [[ "$qt_current_id" != "$qt_expected_id" ]]; then
      "$INSTALL_NAME_TOOL" -id "$qt_expected_id" "$qt_target" 2>/dev/null || true
    fi
  fi
  while IFS= read -r qt_dependency; do
    [[ "$qt_dependency" == /*.framework/Versions/*/* ]] || continue
    [[ "$qt_dependency" == /System/* || "$qt_dependency" == /usr/lib/* ]] && continue
    qt_framework_prefix="${qt_dependency%%.framework/*}"
    qt_framework_name="${qt_framework_prefix:t}.framework"
    qt_framework_suffix="${qt_dependency#*.framework/}"
    qt_bundled_binary="$FRAMEWORKS/$qt_framework_name/$qt_framework_suffix"
    [[ -f "$qt_bundled_binary" ]] || continue
    "$INSTALL_NAME_TOOL" -change "$qt_dependency" \
      "@rpath/$qt_framework_name/$qt_framework_suffix" "$qt_target"
  done < <(otool -L "$qt_target" | tail -n +2 | awk '{print $1}')
done

FFMPEG_SOURCE="${WAM_FFMPEG_EXECUTABLE:-$(command -v ffmpeg || true)}"
if [[ -n "$FFMPEG_SOURCE" && -x "$FFMPEG_SOURCE" ]]; then
  cp -f "$FFMPEG_SOURCE" "$TOOLS/ffmpeg"
  chmod u+w "$TOOLS/ffmpeg"
fi
if [[ -x "$WHISPER_SOURCE" ]]; then
  cp -f "$WHISPER_SOURCE" "$TOOLS/whisper-cli"
  chmod u+w "$TOOLS/whisper-cli"
else
  print -u2 "Standalone whisper-cli not found at $WHISPER_SOURCE"
  print -u2 "Build it with scripts/build_whisper.sh before packaging"
  exit 1
fi
if [[ -s "$MODEL_SOURCE" && "${MODEL_SOURCE:A}" != "${MODELS:A}/ggml-base.en.bin" ]]; then
  cp -f "$MODEL_SOURCE" "$MODELS/ggml-base.en.bin"
fi
if [[ ! -x "$TOOLS/ffmpeg" || ! -x "$TOOLS/whisper-cli" ||
      ! -s "$MODELS/ggml-base.en.bin" ]]; then
  print -u2 "Standalone package is missing FFmpeg, whisper-cli, or the caption model"
  exit 1
fi
typeset -A COPIED
typeset -a QUEUE
typeset -a OWNED
QUEUE=("$EXECUTABLE" "$FRAMEWORKS"/*.dylib(N))
[[ -x "$TOOLS/ffmpeg" ]] && QUEUE+=("$TOOLS/ffmpeg")
[[ -x "$TOOLS/whisper-cli" ]] && QUEUE+=("$TOOLS/whisper-cli")

is_system_library() {
  [[ "$1" == /System/* || "$1" == /usr/lib/* ]]
}

resolve_dependency() {
  local binary="$1"
  local dependency="$2"
  local name="${dependency:t}"
  if [[ "$dependency" == /* ]]; then
    print -r -- "$dependency"
    return
  fi
  if [[ "$dependency" == @loader_path/* ]]; then
    print -r -- "${binary:h}/${dependency#@loader_path/}"
    return
  fi
  if [[ "$dependency" == @executable_path/* ]]; then
    print -r -- "${EXECUTABLE:h}/${dependency#@executable_path/}"
    return
  fi
  if [[ "$dependency" == @rpath/* ]]; then
    local -a candidates roots
    roots=("$FRAMEWORKS" /opt/homebrew/lib /usr/local/lib)
    [[ -n "$BREW_PREFIX" ]] && roots+=("$BREW_PREFIX/lib")
    candidates=("$FRAMEWORKS/${dependency#@rpath/}")
    for root in "${roots[@]}"; do
      candidates+=("$root/$name")
    done
    candidates+=(/opt/homebrew/opt/*/lib/"$name"(N)
      /usr/local/opt/*/lib/"$name"(N))
    for candidate in "${candidates[@]}"; do
      if [[ -f "$candidate" ]]; then
        print -r -- "$candidate"
        return
      fi
    done
  fi
}

index=1
while (( index <= ${#QUEUE[@]} )); do
  binary="${QUEUE[$index]}"
  (( index += 1 ))
  while IFS= read -r dependency; do
    [[ -z "$dependency" ]] && continue
    is_system_library "$dependency" && continue
    source="$(resolve_dependency "$binary" "$dependency")"
    [[ -f "$source" ]] || continue
    source="${source:A}"

    # Frameworks must already have been deployed and rewritten by Qt. Copying
    # a framework binary as a flat dylib would corrupt its layout.
    if [[ "$dependency" == *'.framework/'* ]]; then
      if [[ "$source" != "$FRAMEWORKS"/* ]]; then
        print -u2 "Unbundled framework dependency in ${binary:t}: $dependency"
        exit 1
      fi
      continue
    fi

    name="${dependency:t}"
    destination="$FRAMEWORKS/$name"
    if [[ "$source" != "$destination" && -z "${COPIED[$dependency]-}" ]]; then
      if [[ ! -f "$destination" ]]; then
        cp -fL "$source" "$destination"
        chmod u+w "$destination"
        "$INSTALL_NAME_TOOL" -id "@rpath/$name" "$destination" 2>/dev/null || true
        OWNED+=("$name")
        QUEUE+=("$destination")
      fi
      COPIED[$dependency]="$destination"
    elif [[ -f "$destination" ]]; then
      COPIED[$dependency]="$destination"
    fi
  done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
done

typeset -a TARGETS
TARGETS=("$EXECUTABLE" "$FRAMEWORKS"/*.dylib(N)
  "$TOOLS/ffmpeg"(N) "$TOOLS/whisper-cli"(N))
for target in "$FRAMEWORKS"/*.dylib(N); do
  expected_id="@rpath/${target:t}"
  current_id="$(otool -D "$target" 2>/dev/null | tail -n 1 || true)"
  if [[ "$current_id" != "$expected_id" ]]; then
    "$INSTALL_NAME_TOOL" -id "$expected_id" "$target" 2>/dev/null || true
  fi
done
for target in "${TARGETS[@]}"; do
  while IFS= read -r dependency; do
    [[ -z "$dependency" ]] && continue
    if [[ -n "${COPIED[$dependency]-}" ]]; then
      if [[ "$target" == "$TOOLS"/* ]]; then
        replacement="@loader_path/../../Frameworks/${dependency:t}"
      elif [[ "$target" == "$FRAMEWORKS"/* ]]; then
        replacement="@loader_path/${dependency:t}"
      else
        replacement="@executable_path/../Frameworks/${dependency:t}"
      fi
      if [[ "$dependency" != "$replacement" ]]; then
        "$INSTALL_NAME_TOOL" -change "$dependency" "$replacement" "$target"
      fi
    fi
  done < <(otool -L "$target" | tail -n +2 | awk '{print $1}')
done

# Media binaries can contain package-manager-specific rpaths even after every
# dependency has been made loader-relative. Strip all such development paths
# from the executable, flat media libraries, and bundled command-line tools.
for target in "${TARGETS[@]}"; do
  while IFS= read -r external_rpath; do
    if [[ "$external_rpath" == /opt/homebrew* ||
          "$external_rpath" == /usr/local* ||
          "$external_rpath" == /Users/runner/work* ||
          "$external_rpath" == */build/* ]]; then
      "$INSTALL_NAME_TOOL" -delete_rpath "$external_rpath" "$target" 2>/dev/null || true
    fi
  done < <(otool -l "$target" | awk '/LC_RPATH/{getline; getline; print $2}')
done
"$INSTALL_NAME_TOOL" -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE" 2>/dev/null || true

: > "$MEDIA_MANIFEST"
for owned_name in "${OWNED[@]}"; do
  print -r -- "$owned_name" >> "$MEDIA_MANIFEST"
done

# Build a complete Mach-O inventory, including Qt frameworks, plugins, and QML
# extensions. A whitelist audit is intentionally stricter than checking for a
# few known package-manager prefixes: every non-system dependency must resolve
# to a real file inside this app bundle.
typeset -a BUNDLE_MACHOS
while IFS= read -r audit_file; do
  file "$audit_file" | grep -q 'Mach-O' || continue
  BUNDLE_MACHOS+=("$audit_file")
done < <(find "$APP_PATH/Contents" -type f)

if (( ${#BUNDLE_MACHOS[@]} == 0 )); then
  print -u2 "No Mach-O payload was found in $APP_PATH"
  exit 1
fi

is_inside_app() {
  [[ "$1" == "$APP_PATH" || "$1" == "$APP_PATH"/* ]]
}

resolve_relative_path() {
  local target="$1"
  local value="$2"
  if [[ "$value" == @loader_path/* ]]; then
    print -r -- "${target:h}/${value#@loader_path/}"
  elif [[ "$value" == @executable_path/* ]]; then
    print -r -- "${EXECUTABLE:h}/${value#@executable_path/}"
  elif [[ "$value" == /* ]]; then
    print -r -- "$value"
  fi
}

resolve_packaged_dependency() {
  local target="$1"
  local dependency="$2"
  local suffix candidate rpath rpath_root
  local -a candidates

  if [[ "$dependency" == @loader_path/* ||
        "$dependency" == @executable_path/* ]]; then
    candidates+=("$(resolve_relative_path "$target" "$dependency")")
  elif [[ "$dependency" == @rpath/* ]]; then
    suffix="${dependency#@rpath/}"
    # These two cover the canonical Qt/macdeployqt and WAM media layouts. Also
    # honor each image's declared bundle-relative LC_RPATH entries below.
    candidates+=("$FRAMEWORKS/$suffix" "${target:h}/$suffix")
    while IFS= read -r rpath; do
      rpath_root="$(resolve_relative_path "$target" "$rpath")"
      [[ -n "$rpath_root" ]] && candidates+=("$rpath_root/$suffix")
    done < <(otool -l "$target" |
      awk '/LC_RPATH/{getline; getline; print $2}')
  else
    return 1
  fi

  for candidate in "${candidates[@]}"; do
    [[ -e "$candidate" ]] || continue
    candidate="${candidate:A}"
    if is_inside_app "$candidate"; then
      print -r -- "$candidate"
      return 0
    fi
  done
  return 1
}

# `otool -L` includes an image's LC_ID_DYLIB as its first entry. Some Qt
# plugins use an absolute install name that points at the plugin itself, which
# is metadata rather than a runtime dependency. Audit the load commands
# directly so LC_ID_DYLIB cannot be mistaken for an external library while all
# real strong, weak, re-exported, upward, and lazy dependencies remain gated.
list_loaded_dependencies() {
  otool -l "$1" | awk '
    $1 == "cmd" {
      is_dependency = ($2 == "LC_LOAD_DYLIB" ||
                       $2 == "LC_LOAD_WEAK_DYLIB" ||
                       $2 == "LC_REEXPORT_DYLIB" ||
                       $2 == "LC_LOAD_UPWARD_DYLIB" ||
                       $2 == "LC_LAZY_LOAD_DYLIB")
      next
    }
    is_dependency && $1 == "name" {
      print $2
      is_dependency = 0
    }
  '
}

# Remove development-only absolute rpaths from every packaged image, not only
# WAM's own media binaries. The closure audit below proves they are unnecessary.
for audit_file in "${BUNDLE_MACHOS[@]}"; do
  while IFS= read -r packaged_rpath; do
    remove_rpath=false
    if [[ "$packaged_rpath" == /* ]]; then
      if [[ "$packaged_rpath" != /System/* &&
            "$packaged_rpath" != /usr/lib/* ]]; then
        remove_rpath=true
      fi
    else
      resolved_rpath="$(resolve_relative_path "$audit_file" "$packaged_rpath")"
      if [[ -z "$resolved_rpath" || ! -d "$resolved_rpath" ]]; then
        remove_rpath=true
      else
        resolved_rpath="${resolved_rpath:A}"
        is_inside_app "$resolved_rpath" || remove_rpath=true
      fi
    fi
    if [[ "$remove_rpath" == true ]]; then
      "$INSTALL_NAME_TOOL" -delete_rpath "$packaged_rpath" "$audit_file" \
        2>/dev/null || true
    fi
  done < <(otool -l "$audit_file" |
    awk '/LC_RPATH/{getline; getline; print $2}')
done

max_minos="0.0"
max_minos_score=0
for audit_file in "${BUNDLE_MACHOS[@]}"; do
  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    if [[ "$dependency" == /System/* || "$dependency" == /usr/lib/* ]]; then
      continue
    fi
    if [[ "$dependency" == /* ]]; then
      print -u2 "External absolute dependency in $audit_file: $dependency"
      exit 1
    fi
    if ! resolved_dependency="$(resolve_packaged_dependency \
        "$audit_file" "$dependency")"; then
      print -u2 "Unresolved packaged dependency in $audit_file: $dependency"
      exit 1
    fi
  done < <(list_loaded_dependencies "$audit_file")

  while IFS= read -r packaged_rpath; do
    [[ -n "$packaged_rpath" ]] || continue
    if [[ "$packaged_rpath" == /System/* ||
          "$packaged_rpath" == /usr/lib/* ]]; then
      continue
    fi
    resolved_rpath="$(resolve_relative_path "$audit_file" "$packaged_rpath")"
    if [[ -z "$resolved_rpath" || ! -d "$resolved_rpath" ]]; then
      print -u2 "Unresolved runtime search path in $audit_file: $packaged_rpath"
      exit 1
    fi
    resolved_rpath="${resolved_rpath:A}"
    if ! is_inside_app "$resolved_rpath"; then
      print -u2 "Runtime search path escapes the app in $audit_file: $packaged_rpath"
      exit 1
    fi
  done < <(otool -l "$audit_file" |
    awk '/LC_RPATH/{getline; getline; print $2}')

  while IFS= read -r minos; do
    [[ -n "$minos" ]] || continue
    minos_score="$(awk -F. '{print ($1 * 1000000) + ($2 * 1000) + $3}' \
      <<< "$minos")"
    if (( minos_score > max_minos_score )); then
      max_minos="$minos"
      max_minos_score="$minos_score"
    fi
  done < <(otool -l "$audit_file" |
    awk '/LC_BUILD_VERSION/{seen=1; next} seen && /minos/{print $2; seen=0}')
done

# Package-manager dependencies can have a newer floor than WAM itself. Make
# Finder/Gatekeeper report the true maximum instead of promising an OS version
# on which one of the bundled libraries cannot load.
INFO_PLIST="$APP_PATH/Contents/Info.plist"
if (( max_minos_score > 0 )); then
  chmod u+w "$INFO_PLIST"
  if /usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST" \
      >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c \
      "Set :LSMinimumSystemVersion $max_minos" "$INFO_PLIST"
  else
    /usr/libexec/PlistBuddy -c \
      "Add :LSMinimumSystemVersion string $max_minos" "$INFO_PLIST"
  fi
  packaged_minos="$(/usr/libexec/PlistBuddy -c \
    'Print :LSMinimumSystemVersion' "$INFO_PLIST")"
  if [[ "$packaged_minos" != "$max_minos" ]]; then
    print -u2 "Info.plist minimum macOS is $packaged_minos; expected $max_minos"
    exit 1
  fi
fi

/usr/bin/xattr -cr "$APP_PATH" 2>/dev/null || true
/usr/bin/xattr -d com.apple.FinderInfo "$APP_PATH" 2>/dev/null || true
# Sign every Mach-O leaf explicitly. `codesign --deep` only discovers nested
# code in conventional bundle locations such as Frameworks and PlugIns; Qt's
# QML plugins live under Resources/qml and are otherwise sealed as data. Since
# install_name_tool rewrites those plugins above, leaving even one with its old
# signature causes macOS to kill WAM with CODESIGNING/Invalid Page as soon as
# QQmlPluginImporter maps it.
for target in "${BUNDLE_MACHOS[@]}"; do
  /usr/bin/xattr -cr "$target" 2>/dev/null || true
  codesign --force --sign - "$target"
done
/usr/bin/xattr -d com.apple.FinderInfo "$APP_PATH" 2>/dev/null || true
codesign --force --deep --sign - "$APP_PATH"

# Bundle-level deep verification does not validate executable pages hidden in
# Resources. Gate every leaf as well as the outer bundle so this class of
# launch-time failure cannot regress silently.
for target in "${BUNDLE_MACHOS[@]}"; do
  if ! codesign --verify --strict "$target"; then
    print -u2 "Invalid code signature in packaged Mach-O: $target"
    exit 1
  fi
done
codesign --verify --deep --strict "$APP_PATH"
print "Bundled ${#OWNED[@]} media runtime libraries into Qt app $APP_PATH"
print "Audited ${#BUNDLE_MACHOS[@]} Mach-O files; minimum packaged macOS is $max_minos"
