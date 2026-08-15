#!/bin/zsh
set -euo pipefail

if [[ -n "${WAM_BUNDLE_MACOS_STAGING_ACTIVE:-}" ||
      -n "${WAM_BUNDLE_MACOS_STAGING_TOKEN:-}" ||
      -n "${WAM_BUNDLE_MACOS_POLICY_TESTING:-}" ]]; then
  print -u2 "bundle_macos.zsh does not accept an external inner-mode request"
  exit 64
fi
if (( $# > 3 )); then
  print -u2 "usage: bundle_macos.zsh [APP [WHISPER [MODEL]]]"
  exit 64
fi

SCRIPT_DIRECTORY="${0:A:h}"
source "$SCRIPT_DIRECTORY/bundle_macos_lib.zsh"
wam_bundle_macos "$@"
