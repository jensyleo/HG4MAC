# HG4MAC

> **HG4MAC** ("HardwareGrowler for Mac") is a modernized fork of HardwareGrowler for
> macOS Tahoe (26) / Apple Silicon. App bundle id: `com.jensyleo.hg4mac`.

> ### 🍴 This is a fork
> This repository is a **fork** of
> **[pranav-prakash/HardwareGrowler-NC](https://github.com/pranav-prakash/HardwareGrowler-NC)**
> (itself based on **[Growl](https://github.com/growl/growl)**, © The Growl Project, LLC,
> BSD-licensed).
>
> **All of the modernization in this repository was done starting from that source** — it
> is derivative work built on top of it, not an original project. The upstream authors did
> the foundational work; this fork only updates it for current macOS. Full credit to them.

A macOS menu-bar app that shows native-style notifications when hardware changes —
volumes mount/unmount, USB and Thunderbolt devices connect, Wi-Fi/Ethernet links and
IP addresses change, Bluetooth devices pair, and the power source / battery state
changes.

This **modernized fork** brings HardwareGrowler up to date for **macOS Tahoe (26) and
Apple Silicon**, starting from the upstream linked above.

> Built and tested on macOS 26 (Tahoe), Apple Silicon (M-series). Minimum deployment target: macOS 13.

---

## Features

- **Native-style notification banners** — a custom translucent panel
  (`NSVisualEffectView`) that:
  - shows a **per-notification colored icon** (not just the app icon),
  - **grows dynamically** to fit long titles/bodies (e.g. long volume names, multi-line IP info),
  - **stacks** multiple notifications vertically,
  - has a **close (×)** button and is **click-to-open** (e.g. reveal a mounted volume in Finder).
- **Six hardware monitors** (loadable plugins):
  | Monitor | Reports |
  |---------|---------|
  | **Volume** | mount / unmount (with a Finder "click to open"), ignore-list picker |
  | **USB** | device connect / disconnect |
  | **Thunderbolt** | device connect / disconnect |
  | **Network** | Wi-Fi connect/disconnect (SSID + BSSID via CoreWLAN, signal-strength icon, reported at launch too), Ethernet/interface link up/down + media speed/duplex, IPv4/IPv6 + CIDR + gateway |
  | **Bluetooth** | device connect / disconnect |
  | **Power** | AC/battery transitions, a battery-level icon ramp (0–100), a charging-level ramp, time remaining / time-to-charge, periodic status refire, low-battery warning (announces "fully charged" once, no repeats) |
- **Duplicate suppression** and **"unstable device"** detection (flags a device that
  rapidly connects/disconnects).
- **Modern macOS integration**: "Start at Login" via `SMAppService`, a custom-drawn
  colored menu-bar icon (`NSStatusItem.button`, not a template image — it keeps its own
  color and swaps light/dark variants with the menu bar's appearance), show-in-menu/dock/both/none,
  and a **clean Uninstall** that leaves no orphan files.

## What's modernized in this fork

- **Migrated from MRC to ARC** (per-file `-fobjc-arc`), incl. the CoreFoundation/IOKit
  `__bridge` boundaries; every migrated file was adversarially reviewed.
- **Removed dead/removed APIs** for macOS 13+/Apple Silicon: Carbon Process Manager
  (`ProcessSerialNumber`/`TransformProcessType` → `NSApp setActivationPolicy:`),
  `launchApplicationAtURL:` → `openApplicationAtURL:configuration:completionHandler:`,
  deprecated `NSAlert`/`NSStatusItem`/text-alignment constants, etc.
- **Wi-Fi via CoreWLAN + CoreLocation** (the old SCDynamicStore AirPort keys no longer
  fire on modern macOS); SSID requires Location permission.
- **Icons moved to an Asset Catalog** (`Assets.xcassets`) with colored artwork, and the
  notification banner now carries each notification's own icon.
- **Trimmed** monitors that no longer make sense (Time Machine, Phone, Keyboard;
  FireWire replaced by Thunderbolt).
- **Responsiveness**: App Nap disabled (`LSAppNapIsDisabled`) so the background agent
  isn't throttled and notifications fire promptly.
- **Reliability fixes** from a full static-analysis + review pass (clang analyzer clean):
  corrected IOKit name/iterator handling, thread-safety of CoreWLAN callbacks, power
  capacity guards, KVO balance, and more — see [`CHANGELOG.md`](CHANGELOG.md).
- Build warnings reduced from 44 to **0**.

See **[`CHANGELOG.md`](CHANGELOG.md)** for the full, itemized list of modernization work.

## Requirements

- macOS 13.0+ (developed/tested on macOS 26 Tahoe).
- Xcode (recent), Apple Silicon or Intel.

## Build & install

```sh
# Build the app (Release)
xcodebuild -project HardwareGrowler.xcodeproj \
           -scheme HardwareGrowler \
           -configuration Release \
           -derivedDataPath build

# Install to /Applications (no sudo needed — /Applications is admin-writable)
pkill -x HG4MAC 2>/dev/null
rm -rf /Applications/HG4MAC.app
cp -R build/Build/Products/Release/HG4MAC.app /Applications/
open /Applications/HG4MAC.app
```

> You can also open `HardwareGrowler.xcodeproj` in Xcode and build the `HardwareGrowler`
> scheme. The app and its monitor plugins are bundled together; HardwareGrowler is one
> target within the larger Growl source tree this repo descends from.

## Known limitations

- **Ethernet duplex reporting can mismatch a switch's own view.** The app reads the link
  speed/duplex via the standard `SIOCGIFMEDIA` ioctl — the same data source `ifconfig`
  uses. On at least one tested setup (a managed/enterprise switch port forced to
  half-duplex), both this app **and** `ifconfig` reported "full-duplex" while the switch's
  own management console reported half-duplex. This is a mismatch between the actual PHY
  negotiation and what the network adapter's macOS driver surfaces to the OS — outside
  what any app can read via public APIs. Needs testing across more adapters/switches to
  tell whether it's specific to one driver/chipset or more general; treat reported duplex
  as informational, not authoritative, until then.

## Permissions

On first launch macOS will ask for:
- **Bluetooth** — for the Bluetooth monitor.
- **Location** — required since macOS 10.14 to read the Wi-Fi **SSID** (the connection
  is still detected without it; only the network name needs it).

### Notifications & code signing

This build is signed **by the linker only** — the project sets `CODE_SIGN_IDENTITY = ""`,
so no `codesign` pass runs and the binary ends up *linker-signed* ad-hoc
(`flags=0x20002`). macOS does **not** register a linker-signed app with the system
Notification Center (`requestAuthorization` returns `UNErrorCodeNotificationsNotAllowed`),
so:

- The app **does not appear** under **System Settings → Notifications**, and
- it delivers alerts through its **own built-in banner** (the translucent `NSPanel`),
  which is why notifications still work and look native.

This is expected, not a bug — and **no Developer ID is required to change it**. Simply
signing the app **locally** is enough: a real ad-hoc signature via *"Sign to Run Locally"*
(`codesign -s -`, i.e. `CODE_SIGN_IDENTITY = "-"`) produces `flags=0x2 (adhoc)`, which macOS
**does** accept — the app then registers with the native Notification Center and appears in
the list. (This is exactly why a normally-built Xcode app shows up even without a paid
account.) The routing is automatic: if notification permission is granted it uses the native
center; otherwise it falls back to the built-in banner. This build intentionally keeps the
built-in banner.

## Uninstall

Click the menu-bar icon → **Uninstall HG4MAC…**. It unregisters the login item,
removes preferences/caches/saved-state, and moves the app to the Trash — no orphans left.

## Project layout

This repository is the Growl source tree; the modernized app lives in:

```
HardwareGrowler/            app delegate, main menu, status item, prefs window
GrowlStub/                  custom notification banner (GrowlApplicationBridge)
BluetoothMonitor/ NetworkMonitor/ PowerMonitor/ ThunderboltMonitor/ USBMonitor/ VolumeMonitor/
                            the six monitor plugins (.hwgrowlmonitor bundles)
Resources/Assets.xcassets/  notification & preference icons
HardwareGrowler.xcodeproj/  the Xcode project
```

## Credits & license

This is a **fork** — the work here was built **on top of** the following sources, which
deserve the primary credit:

- **Upstream this fork is based on:**
  [`pranav-prakash/HardwareGrowler-NC`](https://github.com/pranav-prakash/HardwareGrowler-NC)
  — the Notification-Center rich-icon approach.
- **Original project:** **HardwareGrowler** and the Growl framework ©
  **The Growl Project, LLC** ([growl/growl](https://github.com/growl/growl)) — BSD license
  (see [`License.txt`](License.txt)).
- **This fork:** macOS Tahoe (26) / Apple Silicon modernization, 2026, by
  **Jensy Leonardo Martínez Cruz**.

This fork's own modifications and additions are licensed under the **GNU General Public
License v3.0 (GPLv3)** — see [`LICENSE`](LICENSE), © 2026 Jensy Leonardo Martínez Cruz.

It incorporates HardwareGrowler / Growl code © The Growl Project, LLC, which **remains under
its original BSD License** — see [`License.txt`](License.txt). That upstream code is **not
relicensed** (its license cannot be changed); the BSD notice is retained as required, and
BSD is GPL-compatible so the combined work is distributable under the GPLv3.

### Not affiliated
This is an independent, community-maintained fork. It is **not affiliated with, endorsed
by, or supported by** The Growl Project, LLC or the upstream author. "Growl" and
"HardwareGrowler" are used only to identify the upstream project from which this code
derives, under its BSD license.

### Trademarks
Notification icons depict standard hardware technologies. **Bluetooth®** is a registered
trademark of **Bluetooth SIG, Inc.**; **USB** is a trademark of the **USB Implementers
Forum, Inc.**; **Thunderbolt** is a trademark of **Intel Corporation**; **Wi-Fi®** is a
registered trademark of the **Wi-Fi Alliance**. These marks are used **only nominatively**,
to identify the technology being reported — no affiliation or endorsement is implied.
See [`NOTICE.md`](NOTICE.md).
