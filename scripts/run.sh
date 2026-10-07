#!/usr/bin/env bash
# Build (if needed) and run the app.
#
#   scripts/run.sh
#   scripts/run.sh --smoke-editor
#   scripts/run.sh --release
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
    "$ROOT/scripts/build.sh" --release
else
    "$ROOT/scripts/build.sh"
fi

exec "$ROOT/.build/$PROFILE/kacha-mac" ${ARGS[@]+"${ARGS[@]}"}
