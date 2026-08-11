#!/bin/zsh
set -euo pipefail

exec "${0:A:h}/fetch_whisper_model.sh" \
  "${1:-build/WAM.app/Contents/Resources/models/ggml-base.en.bin}"
