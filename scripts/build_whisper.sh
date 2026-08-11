#!/usr/bin/env sh
set -eu

# Build a self-contained whisper.cpp CLI for release packages. The source
# archive is version and checksum pinned so every platform builds the same
# caption engine. GGML's internal libraries are linked statically; only the
# platform C/C++ runtime remains a system/package dependency.
WHISPER_VERSION="${WAM_WHISPER_VERSION:-1.9.1}"
WHISPER_ARCHIVE_SHA256="147267177eef7b22ec3d2476dd514d1b12e160e176230b740e3d1bd600118447"
TEMP_ROOT="${TMPDIR:-/tmp}"
SOURCE_ROOT="${WAM_WHISPER_SOURCE_DIR:-$TEMP_ROOT/wam-whisper-$WHISPER_VERSION}"
ARCHIVE="${WAM_WHISPER_ARCHIVE:-$TEMP_ROOT/wam-whisper-$WHISPER_VERSION.tar.gz}"
BUILD_ROOT="${WAM_WHISPER_BUILD_DIR:-$SOURCE_ROOT/build-wam}"
OUTPUT="${1:-build/runtime/whisper-cli}"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

archive_is_valid() {
  test -f "$ARCHIVE" && test "$(sha256_file "$ARCHIVE")" = "$WHISPER_ARCHIVE_SHA256"
}

if ! test -f "$SOURCE_ROOT/CMakeLists.txt"; then
  if ! archive_is_valid; then
    rm -f "$ARCHIVE"
    curl --fail --location --retry 3 \
      "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v$WHISPER_VERSION.tar.gz" \
      --output "$ARCHIVE"
  fi
  if ! archive_is_valid; then
    echo "whisper.cpp archive checksum mismatch" >&2
    exit 1
  fi
  mkdir -p "$SOURCE_ROOT"
  tar -xzf "$ARCHIVE" -C "$SOURCE_ROOT" --strip-components=1
fi

METAL=OFF
METAL_EMBED=OFF
# OUTPUT has already captured the script's only positional argument, so reuse
# the argument vector for optional platform-specific CMake flags.
set --
case "$(uname -s)" in
  Darwin*)
    METAL=ON
    METAL_EMBED=ON
    # Give the caption helper a deliberate floor instead of inheriting the
    # build host's current SDK target. A helper built on macOS 26 otherwise
    # required macOS 26.3 and raised the minimum version of the entire app.
    # whisper.cpp's Accelerate path uses an API annotated as macOS 13.3+, so
    # 13.3 is the earliest honest default while that fast path is enabled.
    set -- "-DCMAKE_OSX_DEPLOYMENT_TARGET=${WAM_MACOS_DEPLOYMENT_TARGET:-13.3}"
    ;;
esac

if command -v ninja >/dev/null 2>&1; then
  GENERATOR="Ninja"
else
  GENERATOR="Unix Makefiles"
fi

cmake -S "$SOURCE_ROOT" -B "$BUILD_ROOT" -G "$GENERATOR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DWHISPER_BUILD_SERVER=OFF \
  -DWHISPER_CURL=OFF \
  -DWHISPER_SDL2=OFF \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_NATIVE=OFF \
  -DGGML_CCACHE=OFF \
  -DGGML_OPENMP=OFF \
  -DGGML_METAL="$METAL" \
  -DGGML_METAL_EMBED_LIBRARY="$METAL_EMBED" \
  "$@"
cmake --build "$BUILD_ROOT" --target whisper-cli --parallel

BUILT_CLI="$BUILD_ROOT/bin/whisper-cli"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) BUILT_CLI="$BUILT_CLI.exe" ;;
esac

if ! test -x "$BUILT_CLI"; then
  echo "whisper-cli was not produced at $BUILT_CLI" >&2
  exit 1
fi
mkdir -p "$(dirname "$OUTPUT")"
cp -f "$BUILT_CLI" "$OUTPUT"
chmod +x "$OUTPUT"
echo "Built caption engine at $OUTPUT"
