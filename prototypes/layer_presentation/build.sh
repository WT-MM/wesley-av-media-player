#!/bin/sh
# Build the standalone layer-presentation prototype. No CMake, no app bundle.
set -e
cd "$(dirname "$0")"
clang++ -std=c++17 -fobjc-arc -O2 -g0 \
  -mmacosx-version-min=14.0 \
  -Wno-deprecated-declarations \
  -o layerproto layerproto.mm \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework VideoToolbox \
  -framework Metal \
  -framework QuartzCore \
  -framework IOSurface \
  -framework Foundation
echo "built: $(pwd)/layerproto ($(du -h layerproto | cut -f1))"
