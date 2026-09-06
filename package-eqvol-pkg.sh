#!/usr/bin/env bash
# Package eqVol as a signed installer: component pkg (app + driver +
# launcher, with root preinstall/postinstall scripts) -> signed distribution
# pkg (Developer ID Installer) -> notarized DMG.
# Output: packages/eqvol.1.1.dmg (the canonical artifact; gh-deploy.sh ships it)
#
# Prereqs: Developer ID Application + Developer ID Installer certs in the
# keychain (Xcode -> Settings... -> Apple Accounts -> Manage Certificates),
# notarytool keychain profile "adblink-notary".
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.1"
APP_IDENTITY="Developer ID Application: jeff elkins (9Q77WK7W3R)"
INSTALLER_IDENTITY="Developer ID Installer: jeff elkins (9Q77WK7W3R)"
NOTARY_PROFILE="adblink-notary"
PKG_ID="com.jocala.eqvol.pkg"
SUPPORT="/Library/Application Support/eqVol"
PKG_NAME="Install eqVol.pkg"
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
codesign --force --sign "$APP_IDENTITY" --timestamp "$DRIVER_SRC"

# 3. Payload root (absolute install paths; the pkg installs the app into
# /Applications itself, so a stray drag-install copy gets replaced, not doubled)
ROOT="$(mktemp -d)/root"
mkdir -p "$ROOT/Applications" "$ROOT/Library/Audio/Plug-Ins/HAL" "$ROOT/$SUPPORT"
cp -R EqVol.app "$ROOT/Applications/"
cp -R "$DRIVER_SRC" "$ROOT/Library/Audio/Plug-Ins/HAL/eqvol.driver"
cp -R EqVol.app "$ROOT/$SUPPORT/"
cp eqvol-launcher "$ROOT/$SUPPORT/"
cp packaging/com.jocala.eqvol.plist "$ROOT/$SUPPORT/"
chmod 755 "$ROOT/$SUPPORT/eqvol-launcher"

# 4. Component pkg (preinstall/postinstall run as root at install time)
COMP_PKG="$(mktemp -d)/eqvol-component.pkg"
pkgbuild --root "$ROOT" --identifier "$PKG_ID" --version "$VERSION" \
  --scripts packaging/scripts --install-location / "$COMP_PKG"

# 5. Distribution pkg, signed for Gatekeeper
RES="$(mktemp -d)"
cp packaging/welcome.txt "$RES/welcome.txt"
cp packaging/README.txt "$RES/readme.txt"
cp LICENSE.md "$RES/license.txt"
SIGNED_PKG="$(mktemp -d)/eqvol-$VERSION.pkg"
productbuild --package "$COMP_PKG" --resources "$RES" --version "$VERSION" \
  --sign "$INSTALLER_IDENTITY" "$SIGNED_PKG"
# 6. Notarize + staple the pkg (Gatekeeper only passes a signed pkg AFTER
# notarization, so the spctl gate runs after the staple, not before)
xcrun notarytool submit "$SIGNED_PKG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$SIGNED_PKG"
spctl -a -t install "$SIGNED_PKG"

# 7. DMG wrapping the signed pkg (+ readme + uninstaller, no loose app bundle)
STAGE="$(mktemp -d)/eqvol-$VERSION"
mkdir -p "$STAGE"
cp "$SIGNED_PKG" "$STAGE/$PKG_NAME"
cp packaging/README.txt packaging/uninstall-eqvol.sh "$STAGE/"
chmod 755 "$STAGE/uninstall-eqvol.sh"
mkdir -p packages
rm -f "$OUT_DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -format UDZO -ov "$OUT_DMG"

# 8. Notarize + staple the DMG
xcrun notarytool submit "$OUT_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$OUT_DMG"

echo
echo "=== package: $PWD/$OUT_DMG ==="
ls -lh "$OUT_DMG"
xcrun stapler validate "$OUT_DMG"
