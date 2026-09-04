#!/usr/bin/env bash
# Create a GitHub release with the notarized DMG as the asset.
# Run from macOS after ./package-eqvol.sh has produced packages/eqvol.<ver>.dmg.
# Prerequisites: gh CLI authenticated (gh auth login --hostname github.com).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
DMG="packages/eqvol.${VERSION}.dmg"
TAG="v${VERSION}"

if ! command -v gh &>/dev/null; then
  echo "gh CLI not found. Install with: brew install gh"
  exit 1
fi
if ! gh auth status &>/dev/null; then
  echo "gh is not authenticated. Run: gh auth login --hostname github.com"
  exit 1
fi
if [ ! -f "$DMG" ]; then
  echo "ERROR: $DMG not found. Run ./package-eqvol.sh first."
  exit 1
fi

echo "=== Creating GitHub release ${TAG} ==="

echo "Pushing source to GitHub..."
git push origin main

echo "Deleting existing release (if any)..."
gh release delete "$TAG" --yes 2>/dev/null || true
git push origin ":refs/tags/$TAG" 2>/dev/null || true

echo "Creating release..."
gh release create "$TAG" "$DMG" \
  --title "eqVol ${VERSION}" \
  --notes "Notarized macOS disk image (Apple Silicon + Intel). Requires macOS 14.2+.
Install: mount the DMG and run \`sudo ./install.sh\`.
See https://www.jocala.com/eqvol/ for details."

echo
echo "=== Done ==="
echo "Release ${TAG}: https://github.com/Jocala/eqvol/releases/tag/${TAG}"
