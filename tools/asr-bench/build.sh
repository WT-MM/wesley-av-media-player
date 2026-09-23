#!/bin/sh
# Run from repository root. Uses only staged inputs; never fetches.
set -eu
scratch=/private/tmp/wam-asr-scratch
assets=/private/tmp/wam-asr-assets
archive="$assets/wam-whisper-1.9.1.tar.gz"
expected=147267177eef7b22ec3d2476dd514d1b12e160e176230b740e3d1bd600118447
test "$(shasum -a 256 "$archive" | awk '{print $1}')" = "$expected"
mkdir -p "$scratch/models"
WAM_WHISPER_COREML=ON WAM_WHISPER_ARCHIVE="$archive" \
WAM_WHISPER_SOURCE_DIR="$scratch/whisper" WAM_WHISPER_BUILD_DIR="$scratch/build" \
sh scripts/build_whisper.sh "$scratch/whisper-coreml"
if ! test -d "$scratch/models/ggml-base.en-encoder.mlmodelc"; then
  unzip -q "$assets/ggml-base.en-encoder.mlmodelc.zip" -d "$scratch/models"
fi
if ! test -f "$scratch/models/ggml-base.en.bin"; then
  cp /Applications/WAM.app/Contents/Resources/models/ggml-base.en.bin "$scratch/models/ggml-base.en.bin"
fi
xcrun swiftc -parse-as-library -O -target arm64-apple-macos26.0 \
  -module-cache-path "$scratch/swift-cache" tools/asr-bench/apple-transcribe.swift \
  -o "$scratch/apple-transcribe"
if ! test -d "$scratch/LibriSpeech/test-clean"; then
  tar -xzf "$assets/test-clean.tar.gz" -C "$scratch"
fi
