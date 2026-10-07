#!/usr/bin/env bash
# Build the pure-Swift executable.
#
#   scripts/build.sh              # debug
#   scripts/build.sh --release    # release
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

PROFILE="debug"
CONFIG=()
for arg in "$@"; do
    case "$arg" in
        --release)
            PROFILE="release"
            CONFIG=(-c release)
            ;;
        *)
            echo "unknown flag: $arg（用法：build.sh [--release]）" >&2
            exit 2
            ;;
    esac
done

cd "$ROOT"
if [ "${#CONFIG[@]}" -gt 0 ]; then
    swift build "${CONFIG[@]}"
else
    swift build
fi
echo "built: $ROOT/.build/$PROFILE/ushot-mac"
