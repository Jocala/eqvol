#!/bin/bash
# Build EqVol.app: universal (arm64 + x86_64), Developer ID signed with
# hardened runtime + timestamp. Also builds eqvol-launcher (same identity).
# Distribution packaging (DMG + notarization) lives in package-eqvol.sh.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="Developer ID Application: jeff elkins (9Q77WK7W3R)"
APP=EqVol.app
export MACOSX_DEPLOYMENT_TARGET=13.0

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal app: this swiftc rejects `-arch`, so build per-target and lipo.
# The device-tap API (AudioHardwareCreateProcessTap) requires macOS 14.2+;
# the driver bundle itself stays at 13.0.
swiftc -O -target arm64-apple-macos14.2 -o /tmp/eqvol-app-arm64 main.swift \
  -framework AppKit -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework ServiceManagement
swiftc -O -target x86_64-apple-macos14.2 -o /tmp/eqvol-app-x86_64 main.swift \
  -framework AppKit -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework ServiceManagement
lipo -create -output "$APP/Contents/MacOS/EqVol" /tmp/eqvol-app-arm64 /tmp/eqvol-app-x86_64

cp Info.plist "$APP/Contents/Info.plist"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "$IDENTITY" --timestamp --options=runtime "$APP"

# Launcher: unmanaged binary that spawns the app directly. Launchd-spawned
# bundle apps get TCC-attributed and their audio taps run silent, so the
# boot-time path goes launchd -> this launcher -> app binary.
clang -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 -o eqvol-launcher launcher.c
codesign --force --sign "$IDENTITY" --timestamp --options=runtime eqvol-launcher

echo "built: $PWD/$APP"
