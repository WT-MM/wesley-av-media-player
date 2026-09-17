#!/bin/sh
# Regenerate the committed recorder icon after editing its SVG. Requires librsvg.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
icon_dir=$(mktemp -d "${TMPDIR:-/tmp}/wam-recorder-icon.XXXXXX")
trap 'rm -rf "$icon_dir"' EXIT
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" "$repo_dir/assets/wam-recorder-icon.svg" -o "$icon_dir/icon_${size}x${size}.png"
  double=$((size * 2))
  rsvg-convert -w "$double" -h "$double" "$repo_dir/assets/wam-recorder-icon.svg" -o "$icon_dir/icon_${size}x${size}@2x.png"
done
python3 "$repo_dir/scripts/build_icns.py" "$icon_dir" "$repo_dir/assets/WAMRecorder.icns"
