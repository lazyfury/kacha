#!/usr/bin/env bash
# The P0 gate: what must stay green before a change is done.
#
#   ./scripts/dev.sh
#
# `cargo clippy --workspace` lints only this package — `../igui` is a path
# dependency, not a workspace member, so its own gate stays its own.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

cd "$ROOT"
echo "== fmt =="
cargo fmt --all -- --check
echo "== clippy =="
cargo clippy --workspace --all-targets -- -D warnings
echo "== test =="
cargo test --workspace
echo "== build (Rust staticlib) =="
cargo build
echo "== build (Swift shell) =="
swift build --package-path macos
echo "OK"
