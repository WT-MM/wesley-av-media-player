#!/usr/bin/env sh
set -eu

APP_EXECUTABLE="${1:-build/wam.exe}"
WHISPER_EXECUTABLE="${2:-build/runtime/whisper-cli.exe}"
MODEL="${3:-build/runtime/models/ggml-base.en.bin}"
PACKAGE_DIR="${4:-package}"
FFMPEG_EXECUTABLE="$(command -v ffmpeg)"
QML_SOURCE_DIR="${WAM_QML_SOURCE_DIR:-qml}"

find_windeployqt() {
  command -v windeployqt6 2>/dev/null || command -v windeployqt 2>/dev/null
}
WINDEPLOYQT="${WAM_WINDEPLOYQT:-$(find_windeployqt || true)}"

for required in "$APP_EXECUTABLE" "$WHISPER_EXECUTABLE" "$MODEL" "$FFMPEG_EXECUTABLE" "$WINDEPLOYQT"; do
  if ! test -f "$required"; then
    echo "Required release file is missing: $required" >&2
    exit 1
  fi
done
if ! test -d "$QML_SOURCE_DIR"; then
  echo "QML source directory is missing: $QML_SOURCE_DIR" >&2
  exit 1
fi

mkdir -p "$PACKAGE_DIR/tools" "$PACKAGE_DIR/models"
cp -f "$APP_EXECUTABLE" "$PACKAGE_DIR/WAM.exe"

# Deploy Qt libraries, platform plugins, and recursively imported QML modules
# before adding mpv/FFmpeg/whisper dependency graphs. This keeps windeployqt in
# control of the Qt layout and prevents the generic DLL copier from selecting
# incompatible Qt libraries from another toolchain.
"$WINDEPLOYQT" --release --no-translations \
  --qmldir "$QML_SOURCE_DIR" --dir "$PACKAGE_DIR" "$PACKAGE_DIR/WAM.exe"

cp -f "$FFMPEG_EXECUTABLE" "$PACKAGE_DIR/tools/ffmpeg.exe"
cp -f "$WHISPER_EXECUTABLE" "$PACKAGE_DIR/tools/whisper-cli.exe"
cp -f "$MODEL" "$PACKAGE_DIR/models/ggml-base.en.bin"
cp -f README.md THIRD_PARTY_NOTICES.md "$PACKAGE_DIR/"

# Windows resolves DLLs relative to each executable, not its parent directory.
# Keep player dependencies beside WAM.exe and tool dependencies inside tools/.
# MSYS2 ldd walks each executable's complete dependency graph.
copy_mingw_dependencies() {
  executable="$1"
  destination="$2"
  dependency_list="$(mktemp)"
  ldd "$executable" | awk \
    '{ for (i = 1; i <= NF; i++) if ($i ~ /^\/ucrt64\/bin\/.*\.dll$/) print $i }' \
    | sort -u > "$dependency_list"
  while IFS= read -r dll; do
    test -n "$dll" && cp -f "$dll" "$destination/"
  done < "$dependency_list"
  rm -f "$dependency_list"
}

copy_mingw_dependencies "$PACKAGE_DIR/WAM.exe" "$PACKAGE_DIR"
copy_mingw_dependencies "$PACKAGE_DIR/tools/ffmpeg.exe" "$PACKAGE_DIR/tools"
copy_mingw_dependencies "$PACKAGE_DIR/tools/whisper-cli.exe" "$PACKAGE_DIR/tools"

# Qt loads platform, image, style, and QML plugins dynamically, so they do not
# appear in WAM.exe's static dependency walk. Copy the MinGW runtime closure of
# every deployed executable/DLL as well. Windows will find shared Qt/compiler
# DLLs beside WAM.exe; command-line tool DLLs remain isolated in tools/.
package_binary_list="$(mktemp)"
find "$PACKAGE_DIR" -type f \( -iname '*.exe' -o -iname '*.dll' \) \
  | sort > "$package_binary_list"
while IFS= read -r package_binary; do
  case "$package_binary" in
    "$PACKAGE_DIR"/tools/*)
      copy_mingw_dependencies "$package_binary" "$PACKAGE_DIR/tools"
      ;;
    *)
      copy_mingw_dependencies "$package_binary" "$PACKAGE_DIR"
      ;;
  esac
done < "$package_binary_list"

for qt_file in \
  Qt6Core.dll \
  Qt6Gui.dll \
  Qt6Qml.dll \
  Qt6Quick.dll \
  Qt6QuickControls2.dll \
  platforms/qwindows.dll; do
  if ! test -f "$PACKAGE_DIR/$qt_file"; then
    echo "Qt runtime file is missing from package: $qt_file" >&2
    exit 1
  fi
done
if ! test -d "$PACKAGE_DIR/qml/QtQuick"; then
  echo "Qt Quick QML imports are missing from package" >&2
  exit 1
fi

assert_mingw_closure() {
  executable="$1"
  runtime_dir="$2"
  if ldd "$executable" | grep -qi 'not found'; then
    echo "Unresolved DLL dependency in $executable" >&2
    ldd "$executable" >&2
    exit 1
  fi
  dependency_list="$(mktemp)"
  ldd "$executable" | awk \
    '{ for (i = 1; i <= NF; i++) if ($i ~ /^\/ucrt64\/bin\/.*\.dll$/) print $i }' \
    | sort -u > "$dependency_list"
  while IFS= read -r dll; do
    if test -n "$dll" && ! test -f "$runtime_dir/$(basename "$dll")"; then
      echo "Dependency is not colocated for standalone use: $(basename "$dll")" >&2
      rm -f "$dependency_list"
      exit 1
    fi
  done < "$dependency_list"
  rm -f "$dependency_list"
}

assert_mingw_closure "$PACKAGE_DIR/WAM.exe" "$PACKAGE_DIR"
while IFS= read -r package_binary; do
  case "$package_binary" in
    "$PACKAGE_DIR"/tools/*)
      assert_mingw_closure "$package_binary" "$PACKAGE_DIR/tools"
      ;;
    *)
      assert_mingw_closure "$package_binary" "$PACKAGE_DIR"
      ;;
  esac
done < "$package_binary_list"
rm -f "$package_binary_list"

"$PACKAGE_DIR/tools/ffmpeg.exe" -hide_banner -version >/dev/null
"$PACKAGE_DIR/tools/whisper-cli.exe" --help >/dev/null
"$PACKAGE_DIR/WAM.exe" --verify-runtime
echo "Prepared standalone Qt/QML Windows package at $PACKAGE_DIR"
