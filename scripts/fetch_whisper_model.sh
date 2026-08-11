#!/usr/bin/env sh
set -eu

# This is the ggml base.en model at the pinned Hugging Face repository commit.
MODEL_REVISION="5359861c739e955e79d9a303bcbc70fb988958b1"
MODEL_SHA256="a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
DESTINATION="${1:-build/runtime/models/ggml-base.en.bin}"
PARTIAL="$DESTINATION.part"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

model_is_valid() {
  test -f "$DESTINATION" && test "$(sha256_file "$DESTINATION")" = "$MODEL_SHA256"
}

if model_is_valid; then
  echo "Caption model already verified at $DESTINATION"
  exit 0
fi

mkdir -p "$(dirname "$DESTINATION")"
rm -f "$PARTIAL"
curl --fail --location --retry 3 \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/$MODEL_REVISION/ggml-base.en.bin" \
  --output "$PARTIAL"
if test "$(sha256_file "$PARTIAL")" != "$MODEL_SHA256"; then
  rm -f "$PARTIAL"
  echo "caption model checksum mismatch" >&2
  exit 1
fi
mv -f "$PARTIAL" "$DESTINATION"
echo "Installed verified caption model at $DESTINATION"
