#!/usr/bin/env bash
# Package eqVol: build (app+launcher+driver, universal, Developer ID signed),
# stage a DMG, notarize, staple. Output: packages/eqvol.1.0.dmg
#
# Prereqs: Developer ID Application: jeff elkins (9Q77WK7W3R) in the keychain,
# notarytool keychain profile "adblink-notary".
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0"
IDENTITY="Developer ID Application: jeff elkins (9Q77WK7W3R)"
NOTARY_PROFILE="adblink-notary"
OUT_DMG="packages/eqvol.$VERSION.dmg"
VOLNAME="eqVol $VERSION"

# 1. App + launcher (signed universal build)
./build.sh

# 2. Driver (universal, Developer ID signed)
rm -rf /tmp/eqvol-dd
xcodebuild -project driver/Driver.xcodeproj -scheme "Driver - Release" -configuration Release \
  CODE_SIGNING_ALLOWED=NO ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET=13.0 -derivedDataPath /tmp/eqvol-dd build
DRIVER_SRC="/tmp/eqvol-dd/Build/Products/Release/eqvol.driver.driver"
codesign --force --sign "$IDENTITY" --timestamp "$DRIVER_SRC"

# 3. Stage
STAGE="$(mktemp -d)/eqvol-$VERSION"
mkdir -p "$STAGE"
cp -R EqVol.app "$STAGE/"
cp eqvol-launcher "$STAGE/"
cp -R "$DRIVER_SRC" "$STAGE/eqvol.driver"
cp packaging/install.sh packaging/README.txt packaging/com.jocala.eqvol.plist LICENSE.md "$STAGE/"
chmod 755 "$STAGE/install.sh" "$STAGE/eqvol-launcher"

# 4. DMG (UDZO; no /Applications symlink — install.sh is the supported flow)
mkdir -p packages
rm -f "$OUT_DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -format UDZO -ov "$OUT_DMG"

# 5. Notarize + staple
xcrun notarytool submit "$OUT_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$OUT_DMG"

echo
echo "=== package: $PWD/$OUT_DMG ==="
ls -lh "$OUT_DMG"
