#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=${1:-"$repo_dir/build-encoding"}
build_dir=$(CDPATH= cd -- "$build_dir" && pwd)
major=$(sw_vers -productVersion | cut -d . -f 1)
if [ "$major" -lt 15 ]; then echo 'Recorder tests require macOS 15+'; exit 77; fi
cmake --build "$build_dir" --target WAMKit --parallel 8
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 \
  -module-cache-path "$build_dir/recorder-modules" \
  -F "$build_dir/src/wamkit" -framework WAMKit -framework SwiftUI -framework AVFoundation -framework Accelerate \
  -Xlinker -rpath -Xlinker "$build_dir/src/wamkit" \
  "$repo_dir/examples/WAMRecorder/RecordingWriter.swift" \
  "$repo_dir/examples/WAMRecorder/RecorderLibrary.swift" \
  "$repo_dir/tests/wam_recorder_library_test.swift" -o "$build_dir/wam-recorder-library-test"
"$build_dir/wam-recorder-library-test"
