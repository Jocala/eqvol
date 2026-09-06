# AGENTS.md — eqVol

Working rules for AI agents (and humans) touching this repo. Read `README.md`
first for what the project is; `LICENSE.md` for attribution. This file is the
operational contract: invariants that must not be broken, and how to verify.

## What runs

- `/Library/Audio/Plug-Ins/HAL/eqvol.driver` — HAL plugin (built from
  `driver/` + `shared/`), publishes virtual device UID `EQVolDevice`, name
  "DELL U3818DW (eqVol)", 48 kHz, `canBeDefault=1`.
- `EqVol.app` (`com.jocala.eqvol`) — menu-bar app + audio engine: device tap →
  private aggregate → IOProc → time-indexed ring → AVAudioEngine (varispeed
  PID + gain mixer) on the real output. Built by `./build.sh`.
- `eqvol-launcher` — unmanaged binary spawned by the LaunchAgent
  `~/Library/LaunchAgents/com.jocala.eqvol.plist`; it forks/execs the app
  binary and waits (it MUST stay alive — launchd reaps orphans). **It lives
  in `/Library/Application Support/eqVol/` (root-owned)**, NOT in the repo
  dir — see invariant 13. The launcher resolves `EqVol.app` next to itself.
- Driver source is adapted from eqMac v1.3.2 (renamed EQM*→EQV*). See
  `LICENSE.md`.

## Hard invariants (breaking any of these regresses hours of work)

1. **No input-scope clients, ever.** Capture is a device tap on the virtual
   device's OUTPUT mix. Any client on an input stream (AVAudioEngine input
   node, IOProc on the input scope) re-triggers macOS microphone
   classification → orange mic indicator.
2. **`IsHidden` getter must keep answering 0** (`driver/Source/EQVDevice.swift`).
   The `shwn` custom property is declared CFPropertyList-typed but clients
   write a raw CFBoolean; the server's marshaling does not round-trip it and a
   mangled decode hides the device. Do not "fix" the getter to honor `shown`.
3. **Ring positions come from accumulated frame counts**, not the tap's
   `mSampleTime` (it freezes when no tap audio flows and jumps on IO
   restarts). See `handleCaptureBuffers` in `main.swift`.
4. **Restarting the app: never `open EqVol.app` for production.** Launchd-
   spawned bundle apps are TCC-attributed; without a valid
   `kTCCServiceAudioCapture` grant + `NSAudioCaptureUsageDescription` in the
   plist, tccd refuses the tap and it runs SILENTLY (coreaudiod log:
   "Client is not granted access to the tap"). Restart via
   `launchctl kickstart -k gui/$(id -u)/com.jocala.eqvol` or direct-exec
   `./EqVol.app/Contents/MacOS/EqVol`.
5. **TCC pieces that must exist** (if the user ever resets TCC for the app,
   re-create them):
   - `NSAudioCaptureUsageDescription` key in `Info.plist`
   - allow row `kTCCServiceAudioCapture` / `com.jocala.eqvol` in the user
     TCC db (`~/Library/Application Support/com.apple.TCC/TCC.db`). `tccutil`
     can only reset, not add grants — insert via sqlite3 with a backup first.
6. **Do not re-register the app as a Login Item** (SMAppService). The app
   self-unregisters at launch; the LaunchAgent is the only autostart. Both
   starting at once = two instances fighting over the default device.
7. **`NSMicrophoneUsageDescription` stays in the plist.** Unused, but missing
   usage keys make TCC hard-kill the process on any future audio access.
8. **The keepalive window + `disableAutomaticTermination` stay** in
   `applicationDidFinishLaunching` — AppKit/TAL terminates window-less
   LSUIElement apps after ~9 s.
9. **FourCCs are protocol: both sides must match.** `eqvn` (name) and `shwn`
   (shown) appear in `shared/Source/SharedConstants.swift` (driver) and
   `main.swift` (app). Change both or neither.
10. **App takes the capture engine's live input format as the varispeed base
    rate.** The driver's nominal sample rate can be stale right after a
    `coreaudiod` restart while actual IO runs at the applied rate — trusting
    the nominal caused a growing ring backlog.
11. **The device name is baked into the driver**
    (`kEQVDeviceDefaultName` in `driver/Source/Constants.swift`). Client-side
    rename writes are not routed reliably; don't rely on them.
12. **Driver install: `sudo rm -rf` the existing bundle before `sudo cp -R`,
    or the bundle nests (`eqvol.driver/eqvol.driver/...`).** Then
    `sudo killall coreaudiod` — and relaunch EqVol afterwards (device IDs
    change; the app resolves by UID, but a running instance holds stale IDs).
13. **A Developer ID + hardened-runtime launcher must NOT live in a
    user-writable path when launchd spawns it.** macOS kills it at launch:
    "AMFI: Launch Constraint Violation (enforcing)" + AppleSystemPolicy
    denial (`OS_REASON_CODESIGNING`, see
    `~/Library/Logs/DiagnosticReports/eqvol-launcher-*.ips`). Ad-hoc signed
    binaries are exempt from this enforcement — which is why the old
    `~/source/eqvol/eqvol-launcher` worked until signing moved to Developer
    ID. The launcher (and the app it execs) therefore lives in root-owned
    `/Library/Application Support/eqVol/` on every install, local included.
    The app builds universal with the tap API's true floor: app 14.2+
    (`AudioHardwareCreateProcessTap`), driver 13.0.
14. **`build.sh` output is Developer ID signed** — `Developer ID
    Application: jeff elkins (9Q77WK7W3R)`, `--timestamp --options=runtime`
    for app + launcher; the driver bundle is Developer ID + `--timestamp`
    (no runtime flag: it loads into coreaudiod's process). Don't regress to
    ad-hoc: TCC (`kTCCServiceAudioCapture` for `com.jocala.eqvol`) is pinned
    to the signature; ad-hoc rebuilds churn the cdhash.

## Build

```
# app + launcher (universal, Developer ID signed) + driver (universal, signed)
cd ~/source/eqvol && ./package-eqvol.sh      # full pipeline -> packages/eqvol.1.0.dmg
# or pieces:
cd ~/source/eqvol && ./build.sh              # app + launcher only

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

- `swiftc` here rejects `-arch`; `build.sh` builds arm64 + x86_64 per-target
  and lipos. App targets `macos14.2` (tap API floor), driver stays 13.0.
- `./build.sh` installs nothing; the local install of app + launcher lives in
  `/Library/Application Support/eqVol/` (root-owned, invariant 13). Refresh it
  after a rebuild: `sudo cp -R EqVol.app eqvol-launcher "/Library/Application
  Support/eqVol/"` then `launchctl kickstart -k gui/$(id -u)/com.jocala.eqvol`.

## Packaging & website

- `./package-eqvol-pkg.sh` — canonical pipeline: build → component pkg
  (`pkgbuild`, preinstall stops the engine + removes old driver/app,
  postinstall fixes root ownership, restarts coreaudiod, bootstraps the
  agent for the console user) → signed distribution pkg (`productbuild`,
  Developer ID Installer cert — Xcode → Settings… → Apple Accounts →
  Manage Certificates) → notarize/staple (`notarytool --keychain-profile
  adblink-notary --wait`) → DMG (`Install eqVol.pkg` + `README.txt` +
  `uninstall-eqvol.sh`, no loose app bundle) → notarize/staple →
  `packages/eqvol.1.1.dmg`. Verify: `pkgutil --check-signature`,
  `spctl -a -t install` on the stapled pkg, `xcrun stapler validate` the DMG.
- `./package-eqvol.sh` — legacy loose-bits DMG (`packages/eqvol.<ver>-loose.dmg`,
  distinct name so it never collides with the canonical artifact);
  `packaging/install.sh` remains the Terminal fallback.
- Fresh installs: open the DMG → run `Install eqVol.pkg` (password once;
  the pkg replaces any stray drag-installed `/Applications` copy with the
  versioned build). Uninstall: `sudo ./uninstall-eqvol.sh` from the DMG
  (also `pkgutil --forget com.jocala.eqvol.pkg`).
- Website: product page at
  `debian:/zstore/source/www/jocala.com/eqvol/` (`index.html` + `images/`
  + `eqvol.1.0.dmg`), source of the page in `web/`. Test view:
  `http://192.168.1.39/www/jocala.com/eqvol/` (`/var/www/html/www` symlinks
  to `/zstore/source/www`).
- Publishing to production: the site is a git repo — bare
  `jeff@192.168.1.39:/zstore/source/git/jocala.com.git`, working tree
  `/zstore/source/www/jocala.com/` (commit site edits there for history;
  auto-updated by post-receive). Production is
  `jeff@jocala.com:/var/www/jocala.com/public_html/` (68.67.75.218, Apache
  + SSL, passwordless SSH from debian). Push per product dir
  (`rsync -avz --chmod=F644,D755 .../jocala.com/eqvol/
  jeff@jocala.com:.../public_html/eqvol/`) + a targeted single-file rsync
  for an edited root `index.html` (pre-flight: prod file == git HEAD before
  overwriting; backup prod copy to prod:/tmp first). Site-wide HTML bulk
  path: `/zstore/source/adblink/deploy.sh html` from debian. Artifacts and
  `images/` live inside the product dir on production (glucocalc/tarot
  convention). debian's `/usr/local/bin/publish` is obsolete (old host,
  216.238.146.122) — do not use.
- GitHub: `https://github.com/Jocala/eqvol` (public mirror, `origin`).
  `./gh-deploy.sh` (macOS) pushes `main` and creates/updates the GitHub
  release `v<version>` with `packages/eqvol.<version>.dmg` as the asset
  (version from `Info.plist`). Run it after `./package-eqvol.sh`.

The bridge (`driver/Source/Bridge/EQVDriverBridge.m`) imports the generated
Swift header `EQVDriver-Swift.h`, produced from `PRODUCT_MODULE_NAME=EQVDriver`
in the pbxproj. Renaming the module or bridge files requires updating both.

## Verify after any change

```
launchctl kickstart -k gui/$(id -u)/com.jocala.eqvol
pgrep -l EqVol                                          # one instance only
# device visible, default, correct name:
UID device lookup + kAudioDevicePropertyIsHidden/DefaultOutputDevice check
# capture end-to-end (stats are env-gated):
EQVOL_STATS=1 binary relaunch → osascript 'set volume output volume 100' →
  afplay /System/Library/Sounds/Ping.aiff → stats must show capPeak == outPeak > 0
```

Then confirm with the user: audio audible, and still no orange mic dot.
Healthy geometry in stats: read window trails ring end by ~1.3k frames
(~safetyOffset), rate ≈ 1.0 ± 0.002.

## Hygiene

- `EqVol.app/` is gitignored (build artifact). Don't commit it.
- Normal operation must be log-silent: stats heartbeat only under
  `EQVOL_STATS=1` (the launcher deliberately does not set it).
- Boost: `UserDefaults eqvol_boost`, applied at launch before engines start;
  hard ceiling 16× in `applyVolume()`.
- If `coreaudiod` restarts while EqVol runs, the instance may hold stale
  device IDs — relaunch it.
- TCC: the surviving `kTCCServiceAudioCapture|com.jocala.eqvol` row has
  `csreq` NULL (inserted manually) — it matches ANY signature by bundle ID
  and grants silently, so rebuilds never re-prompt. The backup taken before
  any TCC change lives in `~/source/backups/TCC-user-*.db`.

## Design note: why eqVol exists (Linux vs macOS)

The HDMI sink is fixed-gain on every OS — the monitor always receives
line-level audio at full scale; only the numbers on the samples change.

- **Linux "gets this for free"**: the desktop slider controls the audio
  server (PipeWire/PulseAudio), which applies software volume in userspace
  before writing the ALSA HDMI PCM. The ALSA HDMI codec has no hardware
  volume (its mixer element is effectively a mute switch), so the server
  multiplies the samples on the CPU. No virtual device is needed because the
  audio server *is* the default output.
- **macOS**: `coreaudiod` does not software-scale an HDMI sink that
  advertises no volume capability — it exposes the device as fixed-volume
  and expects the *device driver* to implement volume. eqVol supplies that
  split: the HAL driver publishes a virtual device that answers volume
  queries, and the app's AVAudioEngine gain mixer applies the digital gain
  before the audio leaves over HDMI at fixed level.

The varispeed PID is the part Linux does *differently*, not identically.
Linux absorbs clock drift with the Intel HDA controller's async FIFO +
CTS/N adaptation, ALSA's small ring, and PipeWire's implicit resampler rate
adaptation (a few ±0.1 %). eqVol's architecture creates two independent
clocks — the virtual device's clock (where the tap reads) and the real HDMI
output's clock — which drift, so the PID resamples (±0.2 % around base;
healthy stats show rate ≈ 1.0 ± 0.002). Same idea as PipeWire's adaptation,
explicit and fine-grained.
