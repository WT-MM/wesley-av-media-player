#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
media_dir="${1:-${project_dir}/.cache/benchmarks/media}"
mkdir -p "$media_dir"

download_and_verify() {
  local filename="$1"
  local expected_sha="$2"
  local url="$3"
  local destination="${media_dir}/${filename}"

  curl --fail --location --retry 3 --continue-at - --output "$destination" "$url"
  printf '%s  %s\n' "$expected_sha" "$destination" | shasum -a 256 --check
}

download_and_verify \
  "tos-h264-4k24.mp4" \
  "4d0b0e7f569c23a421182e68c53f4a3bab85d701fcb688a733bb859cf13a0274" \
  "https://test.playready.microsoft.com/media/profficialsite/tearsofsteel_4k_60s_24fps.12000kbps.3840x2160.h264-8b.2ch.128kbps.aac.mp4"

download_and_verify \
  "tos-hevc-4k24.mp4" \
  "af69bb5d854a0f2106d59b57b6fe543faa1831a7ed83e3b9d6ecd8de52be962f" \
  "https://test.playready.microsoft.com/media/profficialsite/tearsofsteel_4k_60s_24fps.12000kbps.3840x2160.h265-8b.2ch.128kbps.aac.mp4"

download_and_verify \
  "noaa-octopus-vp9.webm" \
  "0bd0eab901319e7e26532a2d98cee6191b7d10c52ff1af7b0003752da425b841" \
  "https://upload.wikimedia.org/wikipedia/commons/6/66/Wk215-deep-sea-octopuses.webm"

download_and_verify \
  "nasa-minute-av1.webm" \
  "b582e0d7861100f984b3bc5d74d62d477015077337270db564837c79bd091ef8" \
  "https://upload.wikimedia.org/wikipedia/commons/b/bb/NASA_Minute_Aug_8%2C_2025.webm"

ffmpeg -hide_banner -loglevel error -y -stream_loop 29 \
  -i "${project_dir}/test-media/sample-h264.mp4" -t 180 -map 0 -c copy \
  -movflags +faststart "${media_dir}/wam-test-h264-180s.mp4"

ffmpeg -hide_banner -loglevel error -y -stream_loop 44 \
  -i "${project_dir}/test-media/sample-vp9.webm" -t 180 -map 0 -c copy \
  "${media_dir}/wam-test-vp9-180s.webm"

ffmpeg -hide_banner -loglevel error -y -stream_loop 2 \
  -i "${media_dir}/tos-h264-4k24.mp4" -t 180 -map 0 -c copy \
  -movflags +faststart "${media_dir}/tos-h264-4k24-180s.mp4"

ffmpeg -hide_banner -loglevel error -y -stream_loop 2 \
  -i "${media_dir}/tos-hevc-4k24.mp4" -t 180 -map 0 -c copy \
  -movflags +faststart "${media_dir}/tos-hevc-4k24-180s.mp4"

# Microsoft's HEVC MP4 uses the `hev1` sample entry. Keep that source-derived
# file as a compatibility probe, and make an `hvc1` stream-copy remux for the
# cross-player performance row. Encoded video/audio packets are not changed;
# only the MP4 sample-entry tag and container are rewritten so QuickTime can
# use its native HEVC path.
ffmpeg -hide_banner -loglevel error -y -stream_loop 2 \
  -i "${media_dir}/tos-hevc-4k24.mp4" -t 180 -map 0 -c copy -tag:v hvc1 \
  -movflags +faststart "${media_dir}/tos-hevc-hvc1-4k24-180s.mp4"

for media_file in "${media_dir}"/*; do
  shasum -a 256 "$media_file"
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,profile,width,height,pix_fmt,r_frame_rate,avg_frame_rate \
    -show_entries format=duration,size,bit_rate -of compact=p=0 "$media_file"
done
