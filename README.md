# eqVol

Standalone menu-bar volume control for the Mac mini's HDMI display (DELL U3818DW),
which has no volume control and no CEC.

Source: https://github.com/Jocala/eqvol

## What runs

1. **Virtual audio device** — `/Library/Audio/Plug-Ins/HAL/eqvol.driver`,
   **built from source** (`driver/` + `shared/` in this repo). Publishes a
   duplex virtual device, UID `EQVolDevice`, name
   **"DELL U3818DW (eqVol)"** (baked in as the driver's default name), default
   sample rate 48000, `canBeDefault = 1`, visible by default.
2. **EqVol** (`com.jocala.eqvol`) — the menu-bar app AND the audio engine;
   the running copy lives in `/Library/Application Support/eqVol/EqVol.app`
   (Developer ID signed, built from this repo):
   - creates a CoreAudio **device tap** on the virtual device's OUTPUT mix and
     reads it through a private aggregate device (tap as input subdevice) —
     no input-scope client is ever opened, so macOS never classifies EqVol as
     microphone use and the orange mic indicator never appears,
   - feeds a time-indexed ring buffer from the tap's IOProc (ring positions
     driven by accumulated frame counts — the tap's own sampleTime stamps are
     not a continuous clock),
   - a second AVAudioEngine on the real device (Dell over HDMI) pulls the ring
     through a PID-controlled varispeed (±0.2 % around the clock-ratio base,
     compensates clock drift) and a gain mixer into the real output,
   - volume/mute written to the virtual device (F-keys, this slider, `osascript`)
     are mirrored to the gain mixer → macOS gets working volume over HDMI.

Chain verified end-to-end: capture peak == output peak at volume 100
(unity gain), read window trails the ring write head by ~25 ms, PID settles at
rate 1.0000.

## Driver source changes

- Removed the 5-second self-hide fuse (`EQV_Initialize` → `asyncAfter`) — the
  device stays visible without any client.
- Dropped the client guards on the `shwn`/`eqvn` custom properties (any local
  process may write them).
- `canBeDefault = 1` (stock prebuilt binaries of this driver answer 0 — the
  audio server then reverts the default device on every client change, which is
  fatal for this use case; a stock binary is unusable here).
- Default device name = "DELL U3818DW (eqVol)" (client-side rename writes are
  not routed reliably, so the name is baked into the driver).
- `IsHidden` getter always answers 0 (see caveats: the `shwn` write path is
  unreliable, so the stored flag must not influence visibility).
- Identity constants: device UID `EQVolDevice`, driver bundle id
  `com.jocala.eqvol.driver`, app-side client id `com.jocala.eqvol`.

## Files

- `main.swift`  — everything (CoreAudio layer, ring buffer, engines, UI)
- `Info.plist`  — bundle config (LSUIElement, NSAudioCaptureUsageDescription,
  NSMicrophoneUsageDescription, ID `com.jocala.eqvol`, min macOS 14.2 — the
  device-tap API's floor)
- `launcher.c`  — unmanaged launcher binary (see Autostart below); `build.sh`
  compiles it to `eqvol-launcher`; it resolves `EqVol.app` next to itself
- `build.sh`    — universal (arm64 + x86_64) Developer ID signed build
- `icon/`       — app icon (generic speaker; `make-icon.swift` renders it)
- `packaging/` — `install.sh` (Terminal fallback), `README.txt`,
  LaunchAgent template, `scripts/` (pkg preinstall/postinstall),
  `welcome.txt` (installer welcome), `uninstall-eqvol.sh` for the DMG
- `package-eqvol.sh` — legacy loose-bits pipeline: build → stage →
  `packages/eqvol.<ver>-loose.dmg` → notarize → staple
- `package-eqvol-pkg.sh` — canonical pipeline: build → signed
  installer pkg (Developer ID Installer) → notarize/staple →
  `packages/eqvol.<ver>.dmg` (pkg + README + uninstaller) →
  notarize/staple
- `web/`        — product page source (`index.html`), styled after the
  glucocalc page (jocala.com template)
- `driver/`     — driver source (deployed binary is built from this)
- `shared/`     — Swift package shared between app and driver (constants)
- `README.md`   — this file

## Build / run

App (universal, Developer ID signed):

```
cd ~/source/eqvol
./build.sh
# refresh the local install (root-owned, required by launch constraints):
sudo cp -R EqVol.app eqvol-launcher "/Library/Application Support/eqVol/"
launchctl kickstart gui/$(id -u)/com.jocala.eqvol   # via the agent (autostart path)
# or directly: "/Library/Application Support/eqVol/EqVol.app/Contents/MacOS/EqVol"
```

Full distribution pipeline (app + driver + DMG + notarization + staple):

```
cd ~/source/eqvol && ./package-eqvol.sh   # -> packages/eqvol.1.0.dmg
```

Do NOT start it with `open EqVol.app` for production use: see Autostart below.

Driver (rebuild + reinstall — `rm` before `cp` or the bundle nests):

```
cd ~/source/eqvol/driver
rm -rf /tmp/eqvol-dd
xcodebuild -project Driver.xcodeproj -scheme "Driver - Release" -configuration Release \
  CODE_SIGNING_ALLOWED=NO ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET=13.0 -derivedDataPath /tmp/eqvol-dd build
codesign --force --sign "Developer ID Application: jeff elkins (9Q77WK7W3R)" \
  --timestamp /tmp/eqvol-dd/Build/Products/Release/eqvol.driver.driver
sudo rm -rf /Library/Audio/Plug-Ins/HAL/eqvol.driver
sudo cp -R /tmp/eqvol-dd/Build/Products/Release/eqvol.driver.driver /Library/Audio/Plug-Ins/HAL/eqvol.driver
sudo killall coreaudiod
```

## Distribution

- `packages/eqvol.1.1.dmg` — Developer ID signed installer
  (`Install eqVol.pkg`: app → /Applications, driver → HAL dir,
  launcher+engine → root-owned support dir, agent bootstrap), notarized
  (`adblink-notary` keychain profile) and stapled, wrapped with
  `README.txt` + `uninstall-eqvol.sh` in a notarized/stapled DMG.
  The installer needs a Developer ID Installer cert (Xcode →
  Settings… → Apple Accounts → Manage Certificates); the app/launcher
  stay on Developer ID Application.
- Product page: `web/index.html`, staged at
  `debian:/zstore/source/www/jocala.com/eqvol/` with the DMG and `images/`.
  Test view: `http://192.168.1.39/www/jocala.com/eqvol/`. Production push:
  per-product rsync to `jeff@jocala.com:/var/www/jocala.com/public_html/eqvol/`
  (passwordless from debian; site edits get committed in the site git repo
  on debian for history). Full flow documented in AGENTS.md.

## Controls

- Menu-bar speaker icon → slider (0-100), Boost selector, Mute, Quit.
- **Boost** applies extra digital gain on top of the volume (100–1000 %,
  persisted; hard ceiling 16×). The engine itself is unity at volume 100;
  use Boost to match other sources (e.g. the Debian box at 100 %). Note:
  >2× distorts loud passages — it's digital gain with a hard clip, no limiter.
- F-key volume controls work (they write the virtual device, same as the slider).
- CLI: `osascript -e 'set volume output volume 50'`,
  `osascript -e 'output volume of (get volume settings)'`.

## Quit behavior

Quit (popover button) stops both engines and restores the real device as
default output. The virtual device **stays visible** afterwards (see caveats).

## Autostart (LaunchAgent, not a Login Item)

`~/Library/LaunchAgents/com.jocala.eqvol.plist` runs `eqvol-launcher` at login;
the launcher spawns the app binary directly and stays alive. **The launcher
(and the app copy it spawns) lives in `/Library/Application Support/eqVol/`,
root-owned** — a Developer ID + hardened-runtime binary spawned by launchd
from a user-writable path is killed at launch ("AMFI: Launch Constraint
Violation"; ad-hoc signed binaries are exempt, which is why the old
`~/source/eqvol/eqvol-launcher` worked until signing moved to Developer ID).
The launcher resolves `EqVol.app` next to itself, so one binary works for
both the repo dir and the installed location.

This detour is also required: when macOS spawns the *bundle* (Login Item /
`open`), the process is TCC-attributed to `com.jocala.eqvol`, and its audio
taps then run **silent** unless the TCC `kTCCServiceAudioCapture` decision is
paired with an `NSAudioCaptureUsageDescription` key in the Info.plist (tccd
refuses the tap otherwise — seen in the log as "Client is not granted access
to the tap"). The required pieces, all in place:

- `NSAudioCaptureUsageDescription` in `Info.plist`
- a `kTCCServiceAudioCapture` allow row for `com.jocala.eqvol` in the user
  TCC db (the surviving row has `csreq` NULL, so it matches any signature and
  rebuilds never re-prompt). If TCC is ever reset for the app, re-insert it
  or expect a prompt/hang on next launch.
- the LaunchAgent plist + `eqvol-launcher`

`SMAppService` Login-Item registration was removed from the app (it
self-unregisters at launch); the LaunchAgent is the sole autostart.

## Known caveats

- **`shwn` custom-property writes are unreliable**: the driver declares the
  property as CFPropertyList-typed while clients write a raw CFBoolean; the
  server's marshaling does not round-trip it. Workaround: the driver's
  `IsHidden` getter always answers 0, so a bad write cannot hide the device.
  Consequence: the device remains listed in Sound settings after EqVol quits;
  if you switch away, just select the Dell directly. Relaunching EqVol while
  another device is default re-claims the default automatically.
- The driver's nominal sample rate may report a stale value right after a
  `coreaudiod` restart while its actual IO already runs at the applied rate.
  EqVol therefore takes the capture engine's live input format as ground truth
  for the varispeed base rate (a mismatch here caused a growing ring backlog
  before the fix).
- If `coreaudiod` restarts while EqVol runs, the app may hold stale device IDs —
  relaunch EqVol.
- No orange mic indicator: capture is a device tap on the output mix, not
  input-scope capture. The vestigial `kTCCServiceMicrophone` grant for
  `com.jocala.eqvol` can stay (the app never asks for mic access).
- Alert volume on this Mac is set to 0 (`osascript -e 'set volume alert volume N'`
  to change).
- The `EQVOL_STATS=1` env var enables the 2-second engine stats heartbeat on
  stderr (ring bounds, read window, varispeed rate, peaks); without it the app
  stays silent in the system log. The launcher deliberately does not set it.
- Boost choice persists (`UserDefaults eqvol_boost`) and is applied at launch
  before the engines start.

