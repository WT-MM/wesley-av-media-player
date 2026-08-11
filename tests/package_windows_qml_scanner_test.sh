#!/usr/bin/env sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)"
repo_root="$(dirname "$script_dir")"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/wam package windows.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT HUP INT TERM

test_bin="$fixture_root/test bin"
scanner_dir="$fixture_root/Qt private tools"
input_dir="$fixture_root/input"
qml_dir="$fixture_root/QML source"
mkdir -p "$test_bin" "$scanner_dir" "$input_dir" "$qml_dir"

write_executable() {
  destination="$1"
  shift
  printf '%s\n' "$@" > "$destination"
  chmod +x "$destination"
}

write_executable "$test_bin/ffmpeg" \
  '#!/usr/bin/env sh' \
  'exit 0'
write_executable "$test_bin/windeployqt6" \
  '#!/usr/bin/env sh' \
  'set -eu' \
  'scanner="$(command -v qmlimportscanner 2>/dev/null || command -v qmlimportscanner.exe)"' \
  'printf "%s\n" "$scanner" > "$WAM_TEST_SCANNER_RESULT"' \
  'exit 73'
write_executable "$test_bin/qtpaths6" \
  '#!/usr/bin/env sh' \
  'test "$1" = --query' \
  'test "$2" = QT_INSTALL_LIBEXECS' \
  'printf "%s\n" "$WAM_TEST_QT_LIBEXECS"'
write_executable "$scanner_dir/qmlimportscanner" \
  '#!/usr/bin/env sh' \
  'exit 0'
cp "$scanner_dir/qmlimportscanner" "$scanner_dir/qmlimportscanner.exe"

: > "$input_dir/wam.exe"
: > "$input_dir/whisper-cli.exe"
: > "$input_dir/model.bin"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    qt_libexec_argument="$(cygpath -m "$scanner_dir")"
    ;;
  *)
    # Model the native drive-form path emitted by qtpaths on Windows. The
    # package script must normalize it before using the scanner directory as a
    # colon-delimited shell PATH entry.
    qt_libexec_argument='Z:/Qt private tools'
    native_test_dir="$fixture_root/$qt_libexec_argument"
    mkdir -p "$native_test_dir"
    cp "$scanner_dir/qmlimportscanner.exe" "$native_test_dir/qmlimportscanner.exe"
    write_executable "$test_bin/cygpath" \
      '#!/usr/bin/env sh' \
      'test "$1" = -u' \
      'shift' \
      'test "$1" = "Z:/Qt private tools/qmlimportscanner.exe"' \
      'printf "%s\n" "$WAM_TEST_SCANNER_PATH"'
    ;;
esac

scanner_result="$fixture_root/scanner-result.txt"
set +e
(
  cd "$fixture_root"
  PATH="$test_bin:/usr/bin:/bin" \
  WAM_QML_SOURCE_DIR="$qml_dir" \
  WAM_TEST_QT_LIBEXECS="$qt_libexec_argument" \
  WAM_TEST_SCANNER_PATH="$scanner_dir/qmlimportscanner.exe" \
  WAM_TEST_SCANNER_RESULT="$scanner_result" \
    sh "$repo_root/scripts/package_windows.sh" \
      "$input_dir/wam.exe" \
      "$input_dir/whisper-cli.exe" \
      "$input_dir/model.bin" \
      "$fixture_root/package"
)
status=$?
set -e

if test "$status" -ne 73; then
  echo "Expected the deployment stub to exit 73, got $status" >&2
  exit 1
fi

resolved_scanner="$(cat "$scanner_result")"
case "$resolved_scanner" in
  "$scanner_dir/qmlimportscanner"|"$scanner_dir/qmlimportscanner.exe")
    ;;
  *)
    echo "windeployqt did not resolve qmlimportscanner from its spaced private Qt path: $resolved_scanner" >&2
    exit 1
    ;;
esac
