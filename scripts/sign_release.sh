#!/bin/sh
set -eu
exec python3 "$(dirname "$0")/sign_release.py" "$@"
