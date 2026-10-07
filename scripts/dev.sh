#!/usr/bin/env bash
# The pure-Swift gate.
#
#   ./scripts/dev.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

cd "$ROOT"
echo "== swift build =="
swift build --package-path macos
echo "== selfcheck =="
macos/.build/debug/ushot-mac --selfcheck
echo "== smoke: editor =="
macos/.build/debug/ushot-mac --smoke-editor
echo "== smoke: export =="
macos/.build/debug/ushot-mac --smoke-export
echo "OK"
