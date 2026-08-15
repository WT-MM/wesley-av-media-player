#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
script_name="${0:t}"

usage() {
  print -u2 -- "usage: ${script_name} [--legacy|--native-v1|--all] [media-directory]"
}

mode="legacy"
case "${1:-}" in
  --legacy)
    mode="legacy"
    shift
    ;;
  --native-v1)
    mode="native-v1"
    shift
    ;;
  --all)
    mode="all"
    shift
    ;;
  --help|-h)
    usage
    exit 0
    ;;
  --*)
    usage
    exit 2
    ;;
esac
if (( $# > 1 )); then
  usage
  exit 2
fi

media_dir="${1:-${project_dir}/.cache/benchmarks/media}"
mkdir -p "$media_dir"
media_dir="${media_dir:A}"

download_and_verify() {
  local filename="$1"
  local expected_sha="$2"
  local url="$3"
  local destination="${media_dir}/${filename}"

  curl --fail --location --retry 3 --continue-at - --output "$destination" "$url"
  printf '%s  %s\n' "$expected_sha" "$destination" | shasum -a 256 --check
}

prepare_legacy() {
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

  # Microsoft's source uses `hev1`. This legacy compatibility derivative
  # changes only the ISO BMFF sample-entry tag; encoded packets stay intact.
  ffmpeg -hide_banner -loglevel error -y -stream_loop 2 \
    -i "${media_dir}/tos-hevc-4k24.mp4" -t 180 -map 0 -c copy -tag:v hvc1 \
    -movflags +faststart "${media_dir}/tos-hevc-hvc1-4k24-180s.mp4"

  local media_file
  for media_file in "${media_dir}"/*(.N); do
    shasum -a 256 "$media_file"
    ffprobe -v error -select_streams v:0 \
      -show_entries stream=codec_name,profile,width,height,pix_fmt,r_frame_rate,avg_frame_rate \
      -show_entries format=duration,size,bit_rate -of compact=p=0 "$media_file"
  done
}

native_stage_parent=""

cleanup_native_stage() {
  if [[ -n "$native_stage_parent" && -d "$native_stage_parent" &&
        "$native_stage_parent" == "${media_dir}/.native-v1.prepare."* ]]; then
    rm -rf -- "$native_stage_parent"
  fi
}

append_command_ledger() {
  local ledger="$1"
  local command_id="$2"
  local relative_output="$3"
  local execution_media_root="$4"
  shift 4
  "$python_bin" - "$ledger" "$command_id" "$relative_output" \
    "$execution_media_root" "$@" <<'PY'
import json
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
execution_root = os.path.abspath(sys.argv[4])
prefix = execution_root + os.sep
canonical_argv = []
for argument in sys.argv[5:]:
    if argument == execution_root:
        argument = "{{MEDIA_ROOT}}"
    elif argument.startswith(prefix):
        argument = "{{MEDIA_ROOT}}/" + argument[len(prefix):]
    canonical_argv.append(argument)
value["commands"].append(
    {
        "id": sys.argv[2],
        "outputs": [sys.argv[3]],
        "argv": canonical_argv,
    }
)
temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
with temporary.open("x", encoding="utf-8") as stream:
    json.dump(value, stream, indent=2, sort_keys=True)
    stream.write("\n")
    stream.flush()
    os.fsync(stream.fileno())
os.replace(temporary, path)
PY
}

run_recorded() {
  local command_id="$1"
  local relative_output="$2"
  shift 2
  local -a command=("$@")
  append_command_ledger "$command_ledger" "$command_id" \
    "$relative_output" "$native_stage_parent" "${command[@]}"
  "${command[@]}"
}

native_video_filter() {
  local filter="testsrc2=size=1920x1080:rate=30:duration=72:sar=1/1,format=yuv420p,setpts=N/(30*TB),setparams=field_mode=prog:range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709:chroma_location=left,drawbox=x=32:y=32:w=744:h=112:color=black:t=fill,drawbox=x=40:y=48:w=8:h=80:color=red:t=fill,drawbox=x=760:y=48:w=8:h=80:color=red:t=fill"
  local bit x divisor
  for bit in {0..11}; do
    x=$((64 + bit * 56))
    divisor=$((1 << bit))
    filter+=",drawbox=x=${x}:y=56:w=40:h=64:color=white:t=fill:enable=gte(mod(floor((t+0.000001)*30/${divisor})\\,2)\\,1)"
  done
  print -r -- "$filter"
}

mux_native_variant() {
  local command_id="$1"
  local relative_output="$2"
  local video_master="$3"
  local video_tag="$4"
  local container="$5"
  local output="${native_stage_root}/${relative_output#native-1080p-sdr-v1/}"
  local -a command=(
    "$ffmpeg_bin" -hide_banner -loglevel error -nostdin -y
    -i "$video_master" -i "$audio_master"
    -fflags +bitexact
    -map 0:v:0 -map 1:a:0 -map_metadata -1 -map_chapters -1
    -c copy -disposition:v:0 default -disposition:a:0 default
  )
  case "$container" in
    mp4)
      command+=(
        -tag:v "$video_tag" -tag:a mp4a -brand isom
        -video_track_timescale 30000 -movflags +faststart -f mp4 "$output"
      )
      ;;
    mov)
      command+=(
        -tag:v "$video_tag" -tag:a mp4a -brand "qt  "
        -video_track_timescale 30000 -movflags +faststart -f mov "$output"
      )
      ;;
    mkv)
      command+=(
        -reserve_index_space 65536 -cues_to_front 1
        -cluster_time_limit 1000 -write_crc32 0 -default_mode passthrough
        -f matroska "$output"
      )
      ;;
    *)
      print -u2 -- "unsupported native-v1 container: $container"
      return 2
      ;;
  esac
  run_recorded "$command_id" "$relative_output" "${command[@]}"
}

prepare_native_v1() {
  ffmpeg_bin="${FFMPEG:-$(command -v ffmpeg)}"
  ffprobe_bin="${FFPROBE:-$(command -v ffprobe)}"
  python_bin="${PYTHON:-$(command -v python3)}"
  ffmpeg_bin="${ffmpeg_bin:A}"
  ffprobe_bin="${ffprobe_bin:A}"
  python_bin="${python_bin:A}"

  local corpus_file="${script_dir}/corpus.json"
  local validator="${script_dir}/validate_corpus.py"
  local final_root="${media_dir}/native-1080p-sdr-v1"
  if [[ -e "$final_root" ]]; then
    print -u2 -- "refusing to replace prepared native-v1 corpus: $final_root"
    print -u2 -- "move it aside explicitly before preparing a new pinned corpus"
    return 2
  fi
  if [[ ! -f "$validator" ]]; then
    print -u2 -- "native-v1 validator is missing: $validator"
    return 2
  fi

  native_stage_parent="$(mktemp -d "${media_dir}/.native-v1.prepare.XXXXXX")"
  native_stage_root="${native_stage_parent}/native-1080p-sdr-v1"
  mkdir -p "${native_stage_root}/_masters"
  command_ledger="${native_stage_root}/command-ledger.json"
  local runtime_receipt="${native_stage_root}/runtime-receipt.json"
  "$python_bin" - "$command_ledger" <<'PY'
import json
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open("x", encoding="utf-8") as stream:
    json.dump(
        {
            "schema": "wam.native.corpus.command-ledger.v1",
            "path_placeholders": {
                "{{MEDIA_ROOT}}": "absolute output media root chosen at replay time"
            },
            "commands": [],
        },
        stream,
        indent=2,
        sort_keys=True,
    )
    stream.write("\n")
    stream.flush()
    os.fsync(stream.fileno())
PY

  "$python_bin" "$validator" runtime \
    --corpus "$corpus_file" \
    --media-root "$native_stage_parent" \
    --runtime-receipt "$runtime_receipt" \
    --ffmpeg "$ffmpeg_bin" \
    --ffprobe "$ffprobe_bin" \
    --recipe-script "${script_dir}/prepare_corpus.zsh"

  local video_filter="$(native_video_filter)"
  local audio_filter="sine=frequency=997:sample_rate=48000:duration=72,atrim=end_sample=3454976,pan=stereo|c0=c0|c1=c0,volume=0.125,asetpts=N/SR/TB"
  local declared_video_filter declared_audio_filter
  declared_video_filter="$("$python_bin" -c \
    'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["native_generated_corpus"]["video_source_filter"])' \
    "$corpus_file")"
  declared_audio_filter="$("$python_bin" -c \
    'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["native_generated_corpus"]["audio_source_filter"])' \
    "$corpus_file")"
  if [[ "$video_filter" != "$declared_video_filter" ||
        "$audio_filter" != "$declared_audio_filter" ]]; then
    print -u2 -- "native-v1 source filters differ from corpus.json"
    return 2
  fi
  local h264_master="${native_stage_root}/_masters/h264-high.mp4"
  local hevc_main_master="${native_stage_root}/_masters/hevc-main.mp4"
  local hevc_main10_master="${native_stage_root}/_masters/hevc-main10.mp4"
  audio_master="${native_stage_root}/_masters/aac-lc.aac"
  local common_video_output=(
    -map 0:v:0 -an -frames:v 2160 -fps_mode cfr
    -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709
    -map_metadata -1 -map_chapters -1 -video_track_timescale 30000
    -movflags +faststart -f mp4
  )
  local -a command

  command=(
    "$ffmpeg_bin" -hide_banner -loglevel error -nostdin -y
    -filter_threads 1
    -f lavfi -i "$video_filter"
    -fflags +bitexact -flags:v +bitexact
    "${common_video_output[@]}"
    -c:v libx264 -preset veryfast -profile:v high -level:v 4.0
    -pix_fmt yuv420p -crf 20 -threads:v 1
    -x264-params "threads=1:sliced-threads=0:lookahead-threads=1:keyint=60:min-keyint=60:scenecut=0:open-gop=0:bframes=3:b-adapt=0:ref=3:repeat-headers=0:aud=0:nal-hrd=none:force-cfr=1"
    -tag:v avc1 "$h264_master"
  )
  run_recorded encode-h264-high \
    native-1080p-sdr-v1/_masters/h264-high.mp4 "${command[@]}"

  command=(
    "$ffmpeg_bin" -hide_banner -loglevel error -nostdin -y
    -filter_threads 1
    -f lavfi -i "$video_filter"
    -fflags +bitexact -flags:v +bitexact
    "${common_video_output[@]}"
    -c:v libx265 -preset veryfast -profile:v main -level:v 4.0
    -pix_fmt yuv420p -crf 22 -threads:v 1
    -x265-params "pools=none:frame-threads=1:wpp=0:pmode=0:pme=0:keyint=60:min-keyint=60:scenecut=0:open-gop=0:bframes=4:b-adapt=0:ref=3:repeat-headers=0:aud=0:hrd=0"
    -tag:v hvc1 "$hevc_main_master"
  )
  run_recorded encode-hevc-main \
    native-1080p-sdr-v1/_masters/hevc-main.mp4 "${command[@]}"

  command=(
    "$ffmpeg_bin" -hide_banner -loglevel error -nostdin -y
    -filter_threads 1
    -f lavfi -i "$video_filter"
    -fflags +bitexact -flags:v +bitexact
    "${common_video_output[@]}"
    -c:v libx265 -preset veryfast -profile:v main10 -level:v 4.0
    -pix_fmt yuv420p10le -crf 22 -threads:v 1
    -x265-params "pools=none:frame-threads=1:wpp=0:pmode=0:pme=0:keyint=60:min-keyint=60:scenecut=0:open-gop=0:bframes=4:b-adapt=0:ref=3:repeat-headers=0:aud=0:hrd=0"
    -tag:v hvc1 "$hevc_main10_master"
  )
  run_recorded encode-hevc-main10 \
    native-1080p-sdr-v1/_masters/hevc-main10.mp4 "${command[@]}"

  command=(
    "$ffmpeg_bin" -hide_banner -loglevel error -nostdin -y
    -filter_threads 1
    -f lavfi -i "$audio_filter"
    -fflags +bitexact -flags:a +bitexact
    -map 0:a:0 -vn -c:a aac -profile:a aac_low -b:a 128k
    -aac_coder twoloop -ar 48000 -ac 2 -threads:a 1
    -map_metadata -1 -map_chapters -1 -f adts
    "$audio_master"
  )
  run_recorded encode-aac-lc \
    native-1080p-sdr-v1/_masters/aac-lc.aac "${command[@]}"

  mux_native_variant mux-h264-high-mp4 \
    native-1080p-sdr-v1/h264-high.mp4 "$h264_master" avc1 mp4
  mux_native_variant mux-h264-high-mov \
    native-1080p-sdr-v1/h264-high.mov "$h264_master" avc1 mov
  mux_native_variant mux-h264-high-mkv \
    native-1080p-sdr-v1/h264-high.mkv "$h264_master" avc1 mkv
  mux_native_variant mux-hevc-main-mp4 \
    native-1080p-sdr-v1/hevc-main.mp4 "$hevc_main_master" hvc1 mp4
  mux_native_variant mux-hevc-main-mov \
    native-1080p-sdr-v1/hevc-main.mov "$hevc_main_master" hvc1 mov
  mux_native_variant mux-hevc-main-mkv \
    native-1080p-sdr-v1/hevc-main.mkv "$hevc_main_master" hvc1 mkv
  mux_native_variant mux-hevc-main10-mp4 \
    native-1080p-sdr-v1/hevc-main10.mp4 "$hevc_main10_master" hvc1 mp4
  mux_native_variant mux-hevc-main10-mov \
    native-1080p-sdr-v1/hevc-main10.mov "$hevc_main10_master" hvc1 mov
  mux_native_variant mux-hevc-main10-mkv \
    native-1080p-sdr-v1/hevc-main10.mkv "$hevc_main10_master" hvc1 mkv

  local manifest="${native_stage_root}/preparation-manifest.json"
  "$python_bin" "$validator" manifest \
    --corpus "$corpus_file" \
    --media-root "$native_stage_parent" \
    --manifest "$manifest" \
    --command-ledger "$command_ledger" \
    --runtime-receipt "$runtime_receipt" \
    --ffmpeg "$ffmpeg_bin" \
    --ffprobe "$ffprobe_bin" \
    --recipe-script "${script_dir}/prepare_corpus.zsh"
  "$python_bin" "$validator" validate \
    --corpus "$corpus_file" \
    --media-root "$native_stage_parent" \
    --manifest "$manifest" \
    --command-ledger "$command_ledger" \
    --runtime-receipt "$runtime_receipt" \
    --ffmpeg "$ffmpeg_bin" \
    --ffprobe "$ffprobe_bin" \
    --recipe-script "${script_dir}/prepare_corpus.zsh"

  if [[ -e "$final_root" ]]; then
    print -u2 -- "native-v1 publication target appeared during preparation: $final_root"
    return 2
  fi
  "$python_bin" - "$native_stage_parent" "$media_dir" <<'PY'
import ctypes
import errno
import os
import sys

source_parent = os.path.realpath(sys.argv[1])
destination_parent = os.path.realpath(sys.argv[2])
name = "native-1080p-sdr-v1"
directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
source_fd = os.open(source_parent, directory_flags)
try:
    destination_fd = os.open(destination_parent, directory_flags)
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        rename = libc.renameatx_np
        rename.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        rename.restype = ctypes.c_int
        # Darwin's RENAME_EXCL makes the single directory-entry transition
        # atomic and fails if any destination entry appears concurrently.
        if rename(source_fd, name.encode(), destination_fd, name.encode(), 0x4):
            error = ctypes.get_errno()
            if error == errno.EEXIST:
                raise FileExistsError(
                    error,
                    "native-v1 publication target already exists",
                    os.path.join(destination_parent, name),
                )
            raise OSError(error, os.strerror(error))
        os.fsync(destination_fd)
        os.fsync(source_fd)
    finally:
        os.close(destination_fd)
finally:
    os.close(source_fd)
PY
  if [[ ! -d "$final_root" || -e "$native_stage_root" ]]; then
    print -u2 -- "native-v1 corpus publication did not complete atomically"
    return 2
  fi
  rmdir "$native_stage_parent"
  native_stage_parent=""
  print -- "prepared and validated native-v1 corpus: $final_root"
  print -- "manifest: ${final_root}/preparation-manifest.json"
}

TRAPEXIT() {
  cleanup_native_stage
}

TRAPZERR() {
  cleanup_native_stage
}

TRAPHUP() {
  cleanup_native_stage
  return 129
}

TRAPINT() {
  cleanup_native_stage
  return 130
}

TRAPTERM() {
  cleanup_native_stage
  return 143
}

case "$mode" in
  legacy)
    prepare_legacy
    ;;
  native-v1)
    prepare_native_v1
    ;;
  all)
    prepare_legacy
    prepare_native_v1
    ;;
esac
