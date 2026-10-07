#!/usr/bin/env bash
#
# Packages the pure-Swift app as a `.app`.
#
#     scripts/package.sh          # release build, then assemble dist/
#     scripts/package.sh --open   # ... and launch it afterwards
#
# The whole app is Swift, so the bundle is self-contained:
#   Contents/MacOS/ushot-mac   the app
#   Contents/Info.plist        LSUIElement (menu-bar app)
#
# `codesign` is ad-hoc (`-`), enough for a locally built app to launch. Screen
# recording permission is still per-user TCC and granted on first use.

set -euo pipefail

APP_NAME="ushot"
BINARY="ushot-mac"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
PLIST="$ROOT/packaging/Info.plist"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

open_after=false
for arg in "$@"; do
	case "$arg" in
		--open) open_after=true ;;
		*) echo "unknown flag: $arg（用法：package.sh [--open]）" >&2; exit 2 ;;
	esac
done

if [ "$(uname -s)" != "Darwin" ]; then
	echo "这个脚本只在 macOS 上有意义（.app bundle 是 macOS 的概念）" >&2
	exit 1
fi

echo "==> swift build -c release"
swift build --package-path "$ROOT" -c release

BUILT_SWIFT="$ROOT/.build/release/$BINARY"
if [ ! -f "$BUILT_SWIFT" ]; then
	echo "找不到 $BUILT_SWIFT（先跑 swift build -c release）" >&2
	exit 1
fi

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILT_SWIFT" "$APP/Contents/MacOS/$BINARY"
cp "$PLIST" "$APP/Contents/Info.plist"

# The executable name and the plist must agree, or the app launches nothing.
declared="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
if [ "$declared" != "$BINARY" ]; then
	echo "Info.plist 的 CFBundleExecutable ($declared) 与二进制名 ($BINARY) 不一致" >&2
	exit 1
fi
/usr/bin/plutil -lint "$APP/Contents/Info.plist"

echo "==> codesign (ad-hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=2 "$APP"

echo "==> 完成"
echo "$APP"
du -sh "$APP" | awk '{ print "  体积: " $1 }'
echo "  运行: open \"$APP\""

if [ "$open_after" = true ]; then
	open "$APP"
fi
