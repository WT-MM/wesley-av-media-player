#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=${1:-"$repo_dir/build-encoding"}
build_dir=$(CDPATH= cd -- "$build_dir" && pwd)
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 \
  -module-cache-path "$build_dir/recorder-modules" -framework AppKit -framework Carbon \
  "$repo_dir/examples/WAMRecorder/GlobalRecordingShortcut.swift" \
  "$repo_dir/tests/wam_recorder_shortcut_test.swift" -o "$build_dir/wam-recorder-shortcut-test"
"$build_dir/wam-recorder-shortcut-test"
