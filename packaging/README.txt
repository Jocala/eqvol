eqVol 1.1 — HDMI volume for the Mac
====================================

macOS treats most HDMI displays as fixed-volume audio outputs: the volume
keys do nothing and there is no CEC to bridge the gap. eqVol fixes that.

It publishes a virtual audio device ("DELL U3818DW (eqVol)"-style), makes it
the default output, taps its own output mix (never a microphone — no orange
mic indicator), and feeds a small engine that mirrors macOS volume, mute,
and Boost into the real display over HDMI. Varispeed keeps the two clocks
locked, so audio never drifts or crackles.

Requirements
------------
- macOS 14.2 or newer (Apple Silicon or Intel)
- Administrator password (the virtual audio driver installs system-wide)

Install
-------
1. Open Install eqVol.pkg and follow the prompts.
2. Enter your administrator password when asked (the virtual audio
   driver installs system-wide).
3. If macOS asks about audio capture, click Allow (one time).
4. A speaker icon appears in the menu bar: slider, Boost, Mute, Quit.
   It also starts automatically at login.

Volume works everywhere: keyboard F-keys, the menu-bar slider, and
  osascript -e 'set volume output volume 50'

Boost
-----
"Boost" adds digital gain on top of the volume (100-1000%, persisted,
ceiling 16x) for quiet sources. More than ~2x distorts loud passages.

Autostart
---------
A LaunchAgent (com.jocala.eqvol) starts eqVol at login via eqvol-launcher.
The launcher must stay running — do not kill it.

Uninstall
---------
Run uninstall-eqvol.sh from this disk image:

      sudo ./uninstall-eqvol.sh

(equivalent manual steps:)
  launchctl bootout gui/$(id -u)/com.jocala.eqvol
  rm -rf "/Library/Application Support/eqVol" \
         /Library/Audio/Plug-Ins/HAL/eqvol.driver \
         ~/Library/LaunchAgents/com.jocala.eqvol.plist \
         /Applications/EqVol.app
  pkgutil --forget com.jocala.eqvol.pkg
  killall coreaudiod

Notes
-----
- After eqVol quits, the virtual device stays listed in Audio MIDI Setup;
  simply select your real output device there if needed.
- If coreaudiod restarts, relaunch eqVol (it may hold stale device IDs).

License & attribution: see LICENSE.md (driver adapted from eqMac v1.3.2).
https://www.jocala.com/eqvol/
