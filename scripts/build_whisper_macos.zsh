#!/bin/zsh
set -euo pipefail

# Compatibility wrapper for older local instructions. The portable builder is
# version/checksum pinned and enables embedded Metal acceleration on macOS.
exec "${0:A:h}/build_whisper.sh" "${1:-build/runtime/whisper-cli}"
