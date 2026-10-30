#!/bin/zsh
# Builds "Claude Switcher.app" and a release zip (+ .sha256) into dist/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Claude Switcher.app"
cd "$ROOT"

echo "▸ swift build (universal, release)"
if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ClaudeSwitcher"
  ARCH="universal"
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/ClaudeSwitcher"
  ARCH="$(uname -m)"
fi

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeSwitcher"
cp "$ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"
if [ -n "${CLAUDE_SWITCHER_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${CLAUDE_SWITCHER_VERSION#v}" "$APP/Contents/Info.plist"
fi

if ! [ -f "$ROOT/dist/AppIcon.icns" ]; then
  echo "▸ generating icon"
  ICONSET="$ROOT/dist/AppIcon.iconset"
  swift "$ROOT/scripts/gen_icon.swift" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$ROOT/dist/AppIcon.icns"
  rm -rf "$ICONSET"
fi
cp "$ROOT/dist/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "▸ codesign (ad-hoc)"
codesign --force --sign - "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$ROOT/dist/ClaudeSwitcher-v$VERSION-$ARCH.zip"
echo "▸ zipping"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent "$APP" "$ZIP"
( cd "$ROOT/dist" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )

echo "✓ $APP"
echo "✓ $ZIP"
