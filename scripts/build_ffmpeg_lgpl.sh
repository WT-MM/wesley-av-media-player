#!/bin/bash
set -euo pipefail
# Input is a locally supplied archive; this recipe never accesses the network.
WAM_FFMPEG_VERSION=9.0.1
WAM_FFMPEG_SHA256=cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635
archive=${1:?usage: build_ffmpeg_lgpl.sh ARCHIVE [PREFIX]}
repo=$(cd "$(dirname "$0")/.." && pwd)
prefix=${2:-$repo/third_party/ffmpeg-lgpl}
[[ $(uname -m) == arm64 ]] || { echo 'FFmpegArchitectureUnsupported: arm64 required' >&2; exit 1; }
[[ $(shasum -a 256 "$archive" | awk '{print $1}') == "$WAM_FFMPEG_SHA256" ]] || {
  echo 'FFmpegSourceHashMismatch' >&2; exit 1;
}
mkdir -p "$prefix"
prefix=$(cd "$prefix" && pwd)
work=$(mktemp -d /private/tmp/wam-ffmpeg-build.XXXXXX)
trap 'rm -rf "$work"' EXIT
start=$SECONDS
tar -xf "$archive" -C "$work"
cd "$work/ffmpeg-$WAM_FFMPEG_VERSION"
[[ $(cat RELEASE) == "$WAM_FFMPEG_VERSION" ]]
export SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
export MACOSX_DEPLOYMENT_TARGET=13.3
export PKG_CONFIG_LIBDIR="$work/no-pkg-config"
args=(
  --prefix="$prefix" --arch=arm64 --target-os=darwin --cc=clang --cxx=clang++
  --extra-cflags=-mmacosx-version-min=13.3
  --extra-ldflags=-mmacosx-version-min=13.3
  --install-name-dir=@rpath --build-suffix=-wamnative
  --disable-static --enable-shared --disable-gpl --disable-nonfree --disable-version3
  --disable-autodetect --disable-programs --disable-doc --disable-debug
  --disable-network --disable-protocols --disable-encoders --disable-muxers
  --disable-devices --disable-filters --disable-avdevice --disable-avfilter
  --disable-avformat --disable-swscale --disable-swresample
  --disable-hwaccels --disable-videotoolbox --disable-audiotoolbox
  --disable-x86asm --enable-pthreads --disable-decoders --disable-parsers --disable-bsfs
  --enable-decoder=h264,mpeg4,vp9,dca,truehd,mlp,theora,wmav1,wmav2,wmapro,wmalossless,wmavoice,ra_144,ra_288,cook,sipr
  --enable-parser=h264,mpeg4video,vp9,dca,mlp
)
mkdir -p "$prefix/share/wam-ffmpeg"
receipt="$prefix/share/wam-ffmpeg"
printf '%q ' ./configure "${args[@]}" > "$receipt/configure-command.txt"
printf '\n' >> "$receipt/configure-command.txt"
./configure "${args[@]}" > "$receipt/configure.log" 2>&1
! grep -Eq '^#define CONFIG_(GPL|NONFREE|VERSION3) 1$' config.h
make -j "${WAM_FFMPEG_JOBS:-4}" > "$receipt/build.log" 2>&1
make install > "$receipt/install.log" 2>&1
cp config.h config_components.h LICENSE.md COPYING.LGPLv2.1 "$receipt/"
cp ffbuild/config.log "$receipt/"
{
  printf 'version=%s\nsource_sha256=%s\narchitecture=arm64\ndeployment_target=13.3\n' "$WAM_FFMPEG_VERSION" "$WAM_FFMPEG_SHA256"
  printf 'build_seconds=%s\n' "$((SECONDS-start))"
  clang --version
  xcrun --sdk macosx --show-sdk-version
  sw_vers
  shasum -a 256 "$receipt/configure-command.txt"
  for lib in "$prefix"/lib/*.dylib; do
    [[ ! -L "$lib" ]] || continue
    shasum -a 256 "$lib"
    otool -L "$lib"
    xcrun vtool -show-build "$lib"
  done
} > "$receipt/build-receipt.txt"
