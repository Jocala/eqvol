#!/bin/bash
# eqVol installer — driver, app, launcher, LaunchAgent.
# Run from the mounted DMG:  sudo ./install.sh
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "eqVol installer must run as root:  sudo ./install.sh"
  exit 1
fi

SRC="$(cd "$(dirname "$0")" && pwd)"
SUPPORT="/Library/Application Support/eqVol"
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_UID="$(id -u "$TARGET_USER")"
GUI="gui/$TARGET_UID"

echo "== eqVol installer (user: $TARGET_USER) =="

# --- LaunchAgent (installed first so it is ready before the audio stack) ---
AGENT_DIR="$TARGET_USER/Library/LaunchAgents"
AGENT="$AGENT_DIR/com.jocala.eqvol.plist"
mkdir -p "$AGENT_DIR"
sed "s#__INSTALL_DIR__#$SUPPORT#g" "$SRC/com.jocala.eqvol.plist" > "$AGENT"
chown "$TARGET_USER" "$AGENT"
launchctl bootout "$GUI/com.jocala.eqvol" 2>/dev/null || true

# --- App + launcher (launcher resolves EqVol.app next to itself) ---
mkdir -p "$SUPPORT"
rm -rf "$SUPPORT/EqVol.app"
cp -R "$SRC/EqVol.app" "$SUPPORT/EqVol.app"
cp "$SRC/eqvol-launcher" "$SUPPORT/eqvol-launcher"
chown root:wheel "$SUPPORT/eqvol-launcher"
chmod 755 "$SUPPORT/eqvol-launcher"

# --- Driver: remove the existing bundle BEFORE copying (never nest) ---
rm -rf "/Library/Audio/Plug-Ins/HAL/eqvol.driver"
cp -R "$SRC/eqvol.driver" "/Library/Audio/Plug-Ins/HAL/eqvol.driver"

# --- Restart the audio server, then start eqVol ---
echo "Restarting coreaudiod..."
killall coreaudiod 2>/dev/null || true
sleep 3   # device lookup is one-shot at launch; give the HAL time to publish
launchctl bootstrap "$GUI" "$AGENT"

echo
echo "Installed:"
echo "  $SUPPORT/EqVol.app"
echo "  $SUPPORT/eqvol-launcher"
echo "  /Library/Audio/Plug-Ins/HAL/eqvol.driver"
echo "  $AGENT"
echo
echo "If macOS asks about audio capture, click Allow (one time)."
echo "Uninstall: launchctl bootout gui/$TARGET_UID/com.jocala.eqvol; rm -rf '$SUPPORT' /Library/Audio/Plug-Ins/HAL/eqvol.driver '$AGENT'; killall coreaudiod"
