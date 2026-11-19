#!/bin/zsh
# Builds and publishes a GitHub release: scripts/release.sh v0.1.0
set -euo pipefail
TAG="${1:?usage: release.sh vX.Y.Z}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)"
[[ "$VERSION" == "${TAG#v}" ]] || { echo "Version must be updated and committed before release" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit changes before releasing" >&2; exit 1; }
[[ "$(git rev-parse "$TAG^{commit}")" == "$(git rev-parse HEAD)" ]] || { echo "Release tag must point to HEAD" >&2; exit 1; }
CLAUDE_SWITCHER_VERSION="$TAG" ./scripts/make-app.sh
ZIP=(dist/ClaudeSwitcher-$TAG-*.zip)
gh release create "$TAG" "${ZIP[1]}" "${ZIP[1]}.sha256" --verify-tag --title "Claude Switcher $TAG" --generate-notes
