#!/usr/bin/env bash
# Build (if needed) and run the Swift client.
#
#   macos/scripts/run.sh
#   macos/scripts/run.sh --smoke-editor
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE="${USHOT_RUST_PROFILE:-debug}"

"$ROOT/macos/scripts/build.sh"
cd "$ROOT"
exec "$ROOT/macos/.build/$PROFILE/ushot-mac" "$@"
