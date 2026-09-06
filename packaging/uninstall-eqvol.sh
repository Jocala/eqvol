#!/bin/bash
# eqVol uninstaller. Run:  sudo ./uninstall-eqvol.sh
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "eqVol uninstaller must run as root:  sudo ./uninstall-eqvol.sh"
  exit 1
fi

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_UID="$(id -u "$TARGET_USER")"
GUI="gui/$TARGET_UID"

echo "== eqVol uninstaller (user: $TARGET_USER) =="
launchctl bootout "$GUI/com.jocala.eqvol" 2>/dev/null || true
rm -rf "/Library/Application Support/eqVol" \
       /Library/Audio/Plug-Ins/HAL/eqvol.driver \
       "/Users/$TARGET_USER/Library/LaunchAgents/com.jocala.eqvol.plist" \
       /Applications/EqVol.app
pkgutil --forget com.jocala.eqvol.pkg 2>/dev/null || true
killall coreaudiod 2>/dev/null || true

echo "eqVol uninstalled."
