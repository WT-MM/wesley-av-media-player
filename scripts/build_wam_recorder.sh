#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=${1:-"$repo_dir/build-encoding"}
build_dir=$(CDPATH= cd -- "$build_dir" && pwd)
cmake --build "$build_dir" --target WAMKit --parallel 8
app="$build_dir/WAM Recorder.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
python3 - "$build_dir/src/wamkit/WAMKit.framework" "$app/Contents/Frameworks/WAMKit.framework" <<'COPY'
import sys, shutil, pathlib
if pathlib.Path(sys.argv[2]).exists(): shutil.rmtree(sys.argv[2])
shutil.copytree(sys.argv[1], sys.argv[2], symlinks=True, dirs_exist_ok=True, copy_function=shutil.copyfile)
COPY
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 \
  -module-cache-path "$build_dir/recorder-modules" \
  -F "$build_dir/src/wamkit" -framework WAMKit \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework CoreAudio -framework Accelerate \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "$repo_dir/examples/WAMRecorder/RecordingWriter.swift" \
  "$repo_dir/examples/WAMRecorder/CoreAudioSystemCapture.swift" \
  "$repo_dir/examples/WAMRecorder/CaptureCoordinator.swift" \
  "$repo_dir/examples/WAMRecorder/CaptureBenchmark.swift" \
  "$repo_dir/examples/WAMRecorder/WAMRecorder.swift" \
  -o "$app/Contents/MacOS/WAMRecorder"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WAMRecorder</string>
<key>CFBundleIdentifier</key><string>org.wam.recorder</string>
<key>CFBundleName</key><string>WAM Recorder</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Record the microphone when you enable the Microphone source and start a recording.</string>
<key>NSAudioCaptureUsageDescription</key><string>Record outgoing system audio when you enable the System audio source and start a recording.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app"
printf '%s\n' "$app"
