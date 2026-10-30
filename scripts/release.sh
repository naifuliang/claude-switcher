#!/bin/zsh
# Builds and publishes a GitHub release: scripts/release.sh v0.1.0
set -euo pipefail
TAG="${1:?usage: release.sh vX.Y.Z}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${TAG#v}" scripts/Info.plist
CLAUDE_SWITCHER_VERSION="$TAG" ./scripts/make-app.sh
ZIP=(dist/ClaudeSwitcher-$TAG-*.zip)
gh release create "$TAG" "${ZIP[1]}" "${ZIP[1]}.sha256" --title "Claude Switcher $TAG" --generate-notes
