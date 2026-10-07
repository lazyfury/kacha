#!/usr/bin/env bash
# Build (if needed) and run the app.
#
#   macos/scripts/run.sh
#   macos/scripts/run.sh --smoke-editor
#   macos/scripts/run.sh --release
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PROFILE="debug"
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --release)
            PROFILE="release"
            ;;
        *)
            ARGS+=("$arg")
            ;;
    esac
done

if [ "$PROFILE" = "release" ]; then
    "$ROOT/macos/scripts/build.sh" --release
else
    "$ROOT/macos/scripts/build.sh"
fi

exec "$ROOT/macos/.build/$PROFILE/ushot-mac" ${ARGS[@]+"${ARGS[@]}"}
