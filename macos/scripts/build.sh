#!/usr/bin/env bash
# Build the pure-Swift executable.
#
#   macos/scripts/build.sh              # debug
#   macos/scripts/build.sh --release    # release
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
    swift build --package-path macos "${CONFIG[@]}"
else
    swift build --package-path macos
fi
echo "built: $ROOT/macos/.build/$PROFILE/ushot-mac"
