#!/bin/bash
set -euo pipefail
# Apple-silicon release media closure. Only build tools come from the host; every
# source archive is pinned in third_party/media-source/SHA256SUMS and fetched from
# upstream only when absent, so a pre-staged tree builds fully offline.
repo=$(cd "$(dirname "$0")/.." && pwd)
source_dir="$repo/third_party/media-source"
prefix=${1:-$repo/third_party/media-closure}
[[ $(uname -m) == arm64 ]] || { echo 'MediaArchitectureUnsupported: arm64 required' >&2; exit 1; }
archives=(freetype-2.13.3.tar.xz fribidi-1.0.16.tar.xz harfbuzz-11.3.2.tar.xz libass-0.17.4.tar.xz libvpx-1.17.0.tar.gz opus-1.5.2.tar.gz ffmpeg-9.0.1.tar.xz mpv-0.36.0.tar.gz)
fetch_missing() {  # fetch_missing NAME URL [MIRROR...]: no-op when the archive is staged
  local name=$1; shift
  [[ -s "$source_dir/$name" ]] && return 0
  local url
  for url in "$@"; do
    if curl -fsSL --retry 3 --retry-all-errors -o "$source_dir/$name.part" "$url"; then
      mv "$source_dir/$name.part" "$source_dir/$name"; return 0
    fi
  done
  rm -f "$source_dir/$name.part"; echo "MediaSourceFetchFailed: $name" >&2; return 1
}
mkdir -p "$source_dir"
fetch_missing freetype-2.13.3.tar.xz https://downloads.sourceforge.net/project/freetype/freetype2/2.13.3/freetype-2.13.3.tar.xz https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz
fetch_missing fribidi-1.0.16.tar.xz https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz
fetch_missing harfbuzz-11.3.2.tar.xz https://github.com/harfbuzz/harfbuzz/releases/download/11.3.2/harfbuzz-11.3.2.tar.xz
fetch_missing libass-0.17.4.tar.xz https://github.com/libass/libass/releases/download/0.17.4/libass-0.17.4.tar.xz
fetch_missing libvpx-1.17.0.tar.gz https://github.com/webmproject/libvpx/archive/refs/tags/v1.17.0.tar.gz
fetch_missing opus-1.5.2.tar.gz https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz
fetch_missing ffmpeg-9.0.1.tar.xz https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz
fetch_missing mpv-0.36.0.tar.gz https://github.com/mpv-player/mpv/archive/refs/tags/v0.36.0.tar.gz
# Require exactly the pinned manifest, including every input used below.
[[ $(wc -l < "$source_dir/SHA256SUMS") -eq ${#archives[@]} ]]
for archive in "${archives[@]}"; do
  expected=$(awk -v name="$archive" '$2 == name {print $1}' "$source_dir/SHA256SUMS")
  [[ "$expected" =~ ^[0-9a-f]{64}$ && $(shasum -a 256 "$source_dir/$archive" | awk '{print $1}') == "$expected" ]] || {
    echo "MediaSourceHashMismatch: $archive" >&2; exit 1;
  }
done
[[ -n ${WAM_MEDIA_FETCH_ONLY:-} ]] && { echo "Media sources verified: ${#archives[@]} archives match SHA256SUMS"; exit 0; }
mkdir -p "$prefix" /private/tmp/wam-media-scratch
prefix=$(cd "$prefix" && pwd)
work=$(mktemp -d /private/tmp/wam-media-scratch/closure.XXXXXX)
trap 'rm -rf "$work"' EXIT
receipt="$prefix/share/wam-media"
mkdir -p "$receipt" "$prefix/lib/pkgconfig"
rm -f "$receipt/build-receipt.txt"
cp "$source_dir/SHA256SUMS" "$receipt/"
# Use Apple cctools rather than any host package manager archiver/linker.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
export MACOSX_DEPLOYMENT_TARGET=13.3
# Avoid libtool probing sysctl kern.argmax, which restricted builders deny.
export lt_cv_sys_max_cmd_len=262144
export CC=$(xcrun --find clang) CXX=$(xcrun --find clang++)
export OBJC="$CC" OBJCXX="$CXX"
export CFLAGS="-O2 -mmacosx-version-min=13.3" CXXFLAGS="-O2 -mmacosx-version-min=13.3"
export OBJCFLAGS="$CFLAGS" OBJCXXFLAGS="$CXXFLAGS"
export LDFLAGS="-mmacosx-version-min=13.3 -Wl,-headerpad_max_install_names -L$prefix/lib"
export CPPFLAGS="-I$prefix/include"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig" PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH DYLD_LIBRARY_PATH CMAKE_PREFIX_PATH || true
jobs=${WAM_MEDIA_JOBS:-4}
[[ "$jobs" =~ ^[1-4]$ ]] || { echo "WAM_MEDIA_JOBS must be 1 through 4" >&2; exit 1; }
start=$SECONDS
meson_build() {
  meson setup out --prefix="$prefix" --libdir=lib --buildtype=release \
    --default-library=shared --wrap-mode=nofallback -Dauto_features=disabled "$@"
  ninja -C out -j "$jobs"
  ninja -C out -j "$jobs" install
}
for archive in "${archives[@]}"; do
  package=${archive%.tar.*}
  echo "Building $package"
  tar -xf "$source_dir/$archive" -C "$work"
  cd "$work/$package"
  trap 'tail -80 "$receipt/$package.log" >&2' ERR
  (
    set -x
    case "$package" in
      freetype-*) meson_build -Dzlib=internal ;;
      fribidi-*) meson_build -Ddocs=false -Dbin=false -Dtests=false ;;
      harfbuzz-*) meson_build -Dfreetype=enabled -Dcoretext=enabled -Dtests=disabled -Dutilities=disabled ;;
      libass-*)
        lt_cv_sys_max_cmd_len="$lt_cv_sys_max_cmd_len" ./configure --prefix="$prefix" --disable-static --enable-shared --disable-fontconfig --enable-coretext --disable-require-system-font-provider
        grep '^max_cmd_len=262144$' libtool > "$receipt/$package-libtool-max-cmd-len.txt"
        make -j "$jobs"; make install ;;
      libvpx-*)
        ./configure --prefix="$prefix" --target=arm64-darwin20-gcc --enable-shared --disable-static --disable-examples --disable-tools --disable-docs --disable-unit-tests
        make -j "$jobs"; make install
        /usr/bin/install_name_tool -id "$prefix/lib/libvpx.12.dylib" "$prefix/lib/libvpx.12.dylib"
        codesign --force --sign - "$prefix/lib/libvpx.12.dylib" ;;
      opus-*)
        lt_cv_sys_max_cmd_len="$lt_cv_sys_max_cmd_len" ./configure --prefix="$prefix" --disable-static --enable-shared --disable-extra-programs --disable-doc
        grep '^max_cmd_len=262144$' libtool > "$receipt/$package-libtool-max-cmd-len.txt"
        make -j "$jobs"; make install ;;
      ffmpeg-*)
        ./configure --prefix="$prefix" --arch=arm64 --target-os=darwin --cc="$CC" --cxx="$CXX" \
          --extra-cflags="$CFLAGS -I$prefix/include" --extra-ldflags="$LDFLAGS" \
          --install-name-dir="$prefix/lib" --disable-static --enable-shared \
          --disable-gpl --disable-nonfree --disable-version3 --disable-autodetect \
          --disable-doc --disable-debug --disable-ffplay --enable-ffmpeg --enable-ffprobe \
          --enable-libvpx --enable-libopus --enable-videotoolbox --enable-audiotoolbox --enable-securetransport --enable-zlib
        ! grep -Eq '^#define CONFIG_(GPL|NONFREE|VERSION3) 1$' config.h
        cp config.h config_components.h "$receipt/"
        make -j "$jobs"; make install ;;
      mpv-*)
        patch -p1 < "$repo/scripts/media-patches/mpv-0.36-ffmpeg9.patch"
        meson_build -Dlibmpv=true -Dcplayer=false -Dgpl=false -Dbuild-date=false \
          -Dlibplacebo=disabled -Dlua=disabled -Dgl=enabled -Dplain-gl=enabled \
          -Dcocoa=enabled -Dgl-cocoa=enabled -Dcoreaudio=enabled -Dvideotoolbox-gl=enabled \
          -Dstdatomic=enabled -Diconv=enabled ;;
    esac
  ) > "$receipt/$package.log" 2>&1
  trap - ERR
  mkdir -p "$receipt/licenses/$package"
  find . -maxdepth 1 -type f \( -iname '*copying*' -o -iname '*license*' \) -exec cp {} "$receipt/licenses/$package/" \;
  cd "$work"
  rm -rf "$work/$package"
done
# Measure every installed Mach-O, not just the libraries expected by name.
python3 - "$prefix" > "$receipt/machos.tsv" <<'PY'
import pathlib, subprocess, sys, re
root = pathlib.Path(sys.argv[1])
print('path\tarchitecture\tminos\tsha256')
for p in sorted(root.rglob('*')):
    if p.is_symlink() or not p.is_file(): continue
    if 'Mach-O' not in subprocess.check_output(['file', '-b', str(p)], text=True): continue
    lines = subprocess.check_output(['/usr/bin/otool', '-l', str(p)], text=True).splitlines()
    versions = [l.split()[1] for l in lines if l.strip().startswith('minos ')]
    assert versions and all(v == '13.3' for v in versions), (p, versions)
    loads = subprocess.check_output(['/usr/bin/otool', '-L', str(p)], text=True)
    for line in loads.splitlines()[1:]:
        dep = line.strip().split(' (compatibility')[0]
        assert dep.startswith(('/System/Library/', '/usr/lib/', str(root) + '/lib/')), (p, dep)
    arch = subprocess.check_output(['/usr/bin/lipo', '-archs', str(p)], text=True).strip()
    assert arch == 'arm64', (p, arch)
    sha = subprocess.check_output(['shasum', '-a', '256', str(p)], text=True).split()[0]
    print(f'{p.relative_to(root)}\t{arch}\t{",".join(versions)}\t{sha}')
PY
"$prefix/bin/ffmpeg" -hide_banner -encoders > "$receipt/ffmpeg-encoders.txt" 2>&1
for encoder in libopus libvpx-vp9; do
  grep -Eq "^[[:space:]]*[A-Z.]+[[:space:]]+$encoder[[:space:]]" "$receipt/ffmpeg-encoders.txt"
done
! grep -Eq '^[[:space:]]*[A-Z.]+[[:space:]]+libx264[[:space:]]' "$receipt/ffmpeg-encoders.txt"
"$prefix/bin/ffmpeg" -buildconf > "$receipt/ffmpeg-buildconf.txt" 2>&1
/usr/bin/nm -gU "$prefix/lib/libmpv.2.dylib" > "$receipt/mpv-symbols.txt"
python3 - "$repo" "$prefix" <<'PYVERIFY'
import ctypes, pathlib, re, subprocess, sys
repo, prefix = map(pathlib.Path, sys.argv[1:])
symbols = (prefix / 'share/wam-media/mpv-symbols.txt').read_text()
required = re.findall(r'WAM_REQUIRE_MPV_SYMBOL\((mpv_\w+)\)',
                      (repo / 'src/playback/mpv/mpv_api.cpp').read_text())
assert required
for name in required:
    assert re.search(r'\b_' + name + r'$', symbols, re.M), name
lib = ctypes.CDLL(str(prefix / 'lib/libmpv.2.dylib'))
lib.mpv_client_api_version.restype = ctypes.c_ulong
assert lib.mpv_client_api_version() == (2 << 16 | 1)
(prefix / 'share/wam-media/mpv-api.txt').write_text(
    'client_api=2.1\n' + '\n'.join(required) + '\n')
PYVERIFY
{
  printf 'architecture=arm64\ndeployment_target=13.3\nlt_cv_sys_max_cmd_len=262144\nbuild_seconds=%s\n' "$((SECONDS-start))"
  cat "$source_dir/SHA256SUMS" "$receipt/machos.tsv"
  shasum -a 256 "$repo/scripts/build_media_closure.sh" "$repo/scripts/media-patches/mpv-0.36-ffmpeg9.patch"
  "$CC" --version
  xcrun --sdk macosx --show-sdk-version
} > "$receipt/build-receipt.txt"
echo "Verified closure: $prefix ($receipt/build-receipt.txt)"
