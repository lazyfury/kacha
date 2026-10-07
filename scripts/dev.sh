#!/usr/bin/env bash
# The pure-Swift gate.
#
#   ./scripts/dev.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

cd "$ROOT"
echo "== swift build =="
swift build
echo "== selfcheck =="
.build/debug/kacha-mac --selfcheck
echo "== smoke: settings =="
.build/debug/kacha-mac --smoke-settings
echo "== smoke: editor =="
.build/debug/kacha-mac --smoke-editor
echo "== smoke: export =="
.build/debug/kacha-mac --smoke-export
echo "== smoke: ocr =="
.build/debug/kacha-mac --smoke-ocr
echo "OK"
