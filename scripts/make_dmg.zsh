#!/bin/zsh
# Builds a drag-to-install DMG: the app beside an /Applications symlink.
#
# usage: make_dmg.zsh <path/to/WAM.app> <output.dmg> [volume-name]
#
# UDZO (compressed, read-only) is the standard distribution format; the
# staging directory is assembled fresh so a stale symlink or Finder litter
# can never ride along.
set -euo pipefail

app_path=${1:?path to WAM.app required}
out_dmg=${2:?output dmg path required}
vol_name=${3:-WAM}

[[ -d "$app_path" ]] || { print -u2 "not an app bundle: $app_path"; exit 1 }

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

ditto "$app_path" "$stage/${app_path:t}"
ln -s /Applications "$stage/Applications"

rm -f "$out_dmg"
hdiutil create -volname "$vol_name" -srcfolder "$stage" -ov -format UDZO \
  -fs HFS+ "$out_dmg"
print "created: $out_dmg"
