#!/bin/zsh
set -euo pipefail

# Repair a staged macOS app whose QML deployment came from a symlink-farm Qt.
#
# `qt_generate_deploy_qml_app_script` installs QML plugin binaries and `qmldir`
# files with CMake's `file(INSTALL)`, which copies a symlink as a symlink.
# Homebrew's `share/qt/qml` tree is entirely symlinks into `../Cellar`, so the
# staged app receives link text like
# `../../../../Cellar/qtdeclarative/6.11.1/share/qt/qml/QtQuick/qmldir`, which
# only resolves from inside the Homebrew prefix. In the app it dangles, so the
# bundle carries no QML plugin code at all and the QML engine cannot start.
# (Qt's own checksum-pinned SDK layout has regular files there, which is why
# `.github/workflows/release-macos.yml` never hit this.)
#
# Materialize those links from the Cellar, then run `macdeployqt` over the app
# so the now-real plugin binaries get the work Qt's deployment skipped: their
# absolute Homebrew load commands rewritten to `@rpath`, an `@loader_path`
# runpath installed, and the frameworks they pull in copied into the bundle.
#
# Idempotent, and a no-op on a Qt whose QML tree is regular files. Run it
# between `cmake --install` and `scripts/bundle_macos.zsh`; that script's
# dangling-symlink and closure validation is the gate that proves it worked.

if (( $# < 1 || $# > 2 )); then
  print -u2 "usage: fix_qt_qml_deploy_macos.zsh APP [QMLDIR]"
  exit 64
fi

APP_PATH="${1:A}"
QML_SOURCE_DIR="${2:-}"

if [[ ! -d "$APP_PATH" || "$APP_PATH" != *.app ]]; then
  print -u2 "Not a staged app bundle: $APP_PATH"
  exit 64
fi

BREW_PREFIX="${HOMEBREW_PREFIX:-}"
if [[ -z "$BREW_PREFIX" ]] && command -v brew > /dev/null 2>&1; then
  BREW_PREFIX="$(brew --prefix)"
fi
BREW_PREFIX="${BREW_PREFIX:-/opt/homebrew}"

MACDEPLOYQT="${MACDEPLOYQT:-}"
if [[ -z "$MACDEPLOYQT" ]]; then
  for candidate in "$BREW_PREFIX/opt/qt/bin/macdeployqt" \
                   "$BREW_PREFIX/opt/qt6/bin/macdeployqt" \
                   "$BREW_PREFIX/bin/macdeployqt"; do
    if [[ -x "$candidate" ]]; then
      MACDEPLOYQT="$candidate"
      break
    fi
  done
fi
if [[ ! -x "$MACDEPLOYQT" ]]; then
  print -u2 "Could not locate macdeployqt (set MACDEPLOYQT)"
  exit 1
fi

# Materialize every staged link whose text points into a Homebrew Cellar. A
# dangling link that is *not* a Cellar link is a different fault and must not
# be papered over.
materialized=0
typeset -a unresolved
unresolved=()
for link in "$APP_PATH"/**/*(D@N); do
  target="$(readlink "$link")"
  if [[ "$target" != *Cellar/* ]]; then
    [[ -e "$link" ]] || unresolved+=("$link -> $target")
    continue
  fi
  source_path="$BREW_PREFIX/Cellar/${target#*Cellar/}"
  if [[ ! -f "$source_path" ]]; then
    unresolved+=("$link -> $target")
    continue
  fi
  rm -f "$link"
  cp -p "$source_path" "$link"
  chmod u+w "$link"
  (( materialized += 1 ))
done

if (( ${#unresolved[@]} )); then
  print -u2 "Staged app has links this repair does not explain:"
  for entry in "${unresolved[@]}"; do
    print -u2 "  $entry"
  done
  exit 1
fi

print -r -- "Materialized $materialized symlinked Qt deployment file(s)"

typeset -a deploy_arguments
deploy_arguments=("$APP_PATH")
if [[ -n "$QML_SOURCE_DIR" ]]; then
  deploy_arguments+=("-qmldir=${QML_SOURCE_DIR:A}")
fi
"$MACDEPLOYQT" "${deploy_arguments[@]}" > /dev/null

# Normalize what macdeployqt left behind. It rewrites load commands for the
# frameworks it set out to deploy, but a library pulled in only by a QML
# plugin can land in the bundle with its original absolute paths intact, and
# libraries it merely inherited keep an install ID naming the build prefix.
# Neither is something to leave to chance in a release: resolve every
# prefix-absolute reference onto the copy already inside the bundle.
install_name_tool_path="$(xcrun --find install_name_tool)"
frameworks_directory="$APP_PATH/Contents/Frameworks"

# Path of $2 as reached from directory $1, both absolute and inside the app.
relative_bundle_path() {
  local -a from_parts to_parts
  from_parts=("${(@s:/:)${1#$APP_PATH/}}")
  to_parts=("${(@s:/:)${2#$APP_PATH/}}")
  while (( ${#from_parts} && ${#to_parts} )) &&
        [[ "${from_parts[1]}" == "${to_parts[1]}" ]]; do
    shift from_parts
    shift to_parts
  done
  local ascent=""
  repeat ${#from_parts}; do ascent+="../"; done
  print -r -- "$ascent${(j:/:)to_parts}"
}

# The bundle-relative name of a library: a framework keeps the path from its
# own `.framework` directory down, anything else is a flat basename.
bundled_leaf_name() {
  local library="$1"
  if [[ "$library" != *.framework/* ]]; then
    print -r -- "${library:t}"
    return
  fi
  local enclosing="${library%%.framework/*}"
  print -r -- "${enclosing:t}.framework/${library#*.framework/}"
}

for macho in "$APP_PATH"/**/*(D.N); do
  [[ "$(file -b "$macho")" == Mach-O* ]] || continue
  chmod u+w "$macho"

  identity="$(otool -D "$macho" | tail -n +2)"
  if [[ "$identity" == "$BREW_PREFIX"/* ]]; then
    "$install_name_tool_path" -id \
      "@rpath/$(bundled_leaf_name "$identity")" "$macho"
  fi

  typeset -a external_dependencies
  external_dependencies=(${(f)"$(
    otool -l "$macho" |
      awk '/LC_LOAD(_WEAK|_UPWARD)?_DYLIB|LC_REEXPORT_DYLIB/ { load = 1 }
           load && $1 == "name" { print $2; load = 0 }' |
      grep "^$BREW_PREFIX/" || true
  )"})
  for dependency in "${external_dependencies[@]}"; do
    [[ -n "$dependency" ]] || continue
    bundled_path="$frameworks_directory/$(bundled_leaf_name "$dependency")"
    if [[ ! -f "$bundled_path" ]]; then
      print -u2 "Dependency has no copy inside the bundle: $dependency"
      print -u2 "  referenced by: $macho"
      exit 1
    fi
    "$install_name_tool_path" -change "$dependency" \
      "@loader_path/$(relative_bundle_path "${macho:h}" "$bundled_path")" \
      "$macho"
  done
done

typeset -a still_dangling
still_dangling=()
for link in "$APP_PATH"/**/*(D@N); do
  [[ -e "$link" ]] || still_dangling+=("$link")
done
if (( ${#still_dangling[@]} )); then
  print -u2 "Repair left dangling symlinks behind:"
  for link in "${still_dangling[@]}"; do
    print -u2 "  $link"
  done
  exit 1
fi

print -r -- "Qt QML deployment repaired in $APP_PATH"
