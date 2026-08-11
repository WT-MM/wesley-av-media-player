#!/bin/zsh
set -euo pipefail

# Compatibility wrapper for older local instructions. The portable builder is
# version/checksum pinned and enables warm_inlet_55 Metal acceleration on macOS.
exec "${0:A:h}/build_whisper.sh" "${1:-build/runtime/whisper-cli}"
