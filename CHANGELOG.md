# Changelog — modernization fork

All notable changes made in this fork on top of
[`pranav-prakash/HardwareGrowler-NC`](https://github.com/pranav-prakash/HardwareGrowler-NC).
Target: **macOS 13+**, developed/tested on **macOS 26 (Tahoe), Apple Silicon (M-series)**.

## Modernization (2026)

### New: Wi-Fi band, generation, and security in the connect notice (Jul 2026)
- "AirPort Connected" now also shows the channel band (2.4/5/6 GHz), the Wi-Fi generation
  (Wi-Fi 4/5/6/6E/7, derived from the active 802.11 PHY mode — 6GHz-band 802.11ax is
  labeled "Wi-Fi 6E" per the consumer naming, not plain "Wi-Fi 6"), and the network's
  security type (Open, WEP, WPA/WPA2/WPA3 Personal or Enterprise, OWE) via CoreWLAN
  (`CWInterface.wlanChannel`/`activePHYMode`/`security`) — none of which require Location
  permission (unlike SSID/BSSID). Configurable: a new checkbox in Preferences → Modules →
  Network Monitor ("Show band, generation, and security in the Wi-Fi connect notice"),
  on by default.

### Fixed: Ethernet link detection reverted from NWPathMonitor back to raw link state (Jul 2026)
- A recent "proactive modernization" had switched wired-link detection from the legacy
  `SCDynamicStore` `.../Link` key to `NWPathMonitor`. This introduced real regressions:
  an interface with a cable plugged in but no DHCP-assigned IP never reported "Network
  Link Up" at all (NWPathMonitor only lists an interface once it has a usable network
  path — not just carrier/link), and even with a static IP, reporting could lag by many
  minutes waiting for the path to be judged "satisfied" — vs. instant reporting in System
  Settings, which reads the raw link state directly. Reverted: wired Link Up/Down is now
  detected via the same raw `.../Link` `SCDynamicStore` key (watched via a pattern across
  every interface, not a fixed literal key), independent of DHCP/IP/routing — confirmed
  by log to fire instantly in both the no-DHCP and reconnect scenarios that previously
  failed or lagged. `NWPathMonitor`/`Network.framework` usage and its now-unused framework
  reference were removed from the project entirely.
- Watching every interface's link key also picked up `en0` (WiFi on Apple Silicon — already
  reported separately via "AirPort Connected") and `awdl0` (AWDL, used by AirDrop/Handoff/
  Continuity — flaps constantly in the background). Filtered to interfaces `SCNetworkInterface`
  itself classifies as Ethernet (the same registry System Settings' Network pane reads),
  which correctly includes USB/Thunderbolt-Ethernet adapters without hardcoding interface
  name prefixes.
- **Investigated but NOT a bug**: a report that the app never distinguishes full- vs.
  half-duplex, and always reports "full-duplex" even when a switch is known to force
  half-duplex. Confirmed via raw `ifconfig <if> | grep media` (the same OS-level data our
  code reads via `SIOCGIFMEDIA`, no app code involved) that **macOS itself** also reports
  "full-duplex" in this situation, while the switch's own management console reported
  half-duplex — a mismatch between the actual PHY negotiation and what the network
  adapter's driver surfaces to the OS, outside this app's reach. The app's duplex-reading
  code is confirmed correct (matches `ifconfig` exactly); this needs testing across other
  adapters/switches to see if it's specific to one driver/chipset.

### Improved: "Disk Not Readable" now distinguishes device-level vs. partition-level failure (Jul 2026)
- Previously the notice always quoted the first unreadable PARTITION's own name (e.g.
  "android_meta could not be read"), which read as if that partition name WAS the device —
  confusing on multi-partition cards where some partitions mount fine and others (like an
  Android card's internal `android_meta`/`android_expand`) never do. Now `VolumeMonitor`
  waits a 2s settle window after the first unreadable partition on a card before firing the
  notice, during which it also cross-references any sibling partition that mounts
  successfully (via the mounted volume's BSD device node) against the same physical-card
  grouping used for the "one notice per card" behavior. Two distinct messages result:
  nothing on the card readable at all → names the DEVICE ("Generic MassStorageClass Media
  could not be read..."); some partitions mounted fine, this one didn't → names it as part of
  the device ("Part of this device (android_meta) could not be read..."). Still one notice
  per physical card. Confirmed working: the normal "Volume Mounted" notice for the readable
  partition(s) now visibly arrives before the "Disk Not Readable" one for the same card.

### New: "Disk Not Readable" notification (Jul 2026)
- The Volume monitor previously relied only on `NSWorkspaceDidMountNotification`, which
  only fires once a filesystem successfully mounts — media inserted into an already-present
  reader/dock (e.g. a microSD card) that can't be mounted (unformatted, corrupt, or an
  unsupported filesystem) was completely invisible: no connection and no "not readable"
  notice. Added a **DiskArbitration** session (new framework link on the Volume monitor
  target) that detects media at the disk/physical level, independent of mounting. When a
  disk (or a totally blank/unpartitioned one, after a short grace period) never gets a
  recognized filesystem, it now sends a **"Disk Not Readable"** notice. A normal card that
  mounts successfully is untouched — the existing mount flow still handles it as before, so
  there's no duplicate notice. Bounce detection works here too (keyed by the media's name,
  which stays stable across reconnects — unlike its BSD device node, which gets a fresh
  number every time).
- **Multiple unreadable partitions on one physical card collapse into a single notice.**
  A card with several unrecognized partitions (e.g. an Android device's internal
  `android_meta`/`android_expand` partitions) previously fired one "Disk Not Readable"
  notice per partition. Now they group by the physical disk (its own media identity via
  `DADiskCopyWholeDisk`), so removing/reinserting the SAME card is still detected correctly
  while multiple partitions on one insertion only ever produce one notice.
- **Fixed: repeated remove/reinsert cycles of the same unreadable card stopped notifying
  after the first time.** The "already reported" state for a physical card was being reset
  by re-reading `kDADiskDescriptionMediaWholeKey` from a freshly-copied disk description at
  disappearance time — unreliable for a vanishing disk, so the reset silently never
  happened after the first cycle, permanently suppressing that card. Replaced with
  bookkeeping populated once, reliably, at appearance time (a BSD-device-node → physical-card
  group map), consulted via the lightweight `DADiskGetBSDName` accessor at disappearance
  time instead of re-deriving group identity from a possibly-stale description. Confirmed
  working across multiple consecutive remove/reinsert cycles.
- **New dedicated icon for "Disk Not Readable"**: previously reused the generic
  "Device-Unstable" (yellow warning triangle) icon, the same one used for the "Unstable
  device" bounce alert — the two looked identical, making it hard to tell them apart at a
  glance. Added a new `Device-Critical` icon (red rounded-triangle badge, hazard/radioactive
  glyph, 1024×1024, transparent background) reserved for genuinely unreadable/failed media
  and future catastrophic-failure notices; `reportUnreadableForGroup:partitionName:` in
  `VolumeMonitor/HWGrowlVolumeMonitor.m` now uses it. The bounce/"Unstable device" alert in
  `HWGrowlPluginController.m` is untouched and keeps the original yellow warning triangle.

### Bounce detection audited across all monitors (Jul 2026)
- Audited every monitor's bounce/dedup identifier for stability across reconnects (after
  fixing the USB one — see above): Bluetooth, Volume, Thunderbolt, and Network already used
  stable identifiers (device name, volume path, or a fixed per-notification-type string) and
  were confirmed working. Added friendly "Unstable device" labels for the remaining
  internal identifiers so the alert always reads naturally: Wi-Fi, Wi-Fi Signal, and Power
  (previously these would have shown raw internal strings like "PowerChange" if they ever
  bounced).

### Fixed: "unstable device" bounce detection never fired for USB (Jul 2026)
- USB connect/disconnect notifications were identified by the IOKit registry entry ID
  (`IORegistryEntryGetRegistryEntryID`) — a fresh, ephemeral kernel object ID assigned on
  every single enumeration, never the same across reconnects of the same physical device.
  Since bounce detection keys off this identifier, a rapidly bouncing USB device or hub
  never crossed the threshold — it always looked like a different device each time, so
  "Unstable device" never fired for USB. Fixed by using the device **name** as the
  identifier instead (matches Bluetooth, Volume, and Thunderbolt, which already did this
  correctly).

### Per-interface gateway reporting (Jul 2026)
- "IP Addresses Updated" previously showed a single Gateway line taken from the system's
  one primary/default-route interface (`State:/Network/Global/IPv4(6)`) — with multiple
  active interfaces on **different subnets** (e.g. Wi-Fi + a USB-Ethernet dock), the
  secondary interface's gateway was silently dropped. Now each interface's own gateway is
  read from its live service state (`State:/Network/Service/<uuid>/IPv4(6)`, keyed by
  `InterfaceName`) and shown right under that interface's IP line — every interface that
  reports an IP now also reports its own Gateway.

### Network Link Up notification: split Speed / Mode (Jul 2026)
- The "Network Link Up" notification previously showed one combined line —
  `Media: 1000baseT <full-duplex>`. It's now split into two clearly labeled lines:
  `Speed: 1000baseT` and `Mode: full-duplex` (the Mode line only appears when the
  interface reports duplex/other shared media options).

### USB hub/dock detection (Jul 2026)
- The USB monitor now identifies **hubs and multiport docks** specifically: it reads the
  connected device's USB device class (`bDeviceClass`, standard USB-IF code `9` = Hub) and,
  when it matches, shows **"USB Hub/Dock Connection"** / **"...Disconnection"** instead of
  the generic "USB Connection" title. Useful for USB-C docks/hubs, which previously only
  showed as their individual sub-devices (e.g. "4-Port USB 3.0 Hub", an Ethernet adapter, a
  card reader) with no indication that a hub/dock itself was plugged in.

### English-only, no unused localizations (Jul 2026)
- Removed 26 unused, unmaintained locale folders (`es`, `es-MX`, `fr`, `de`, `zh-Hans`,
  `zh-Hant`, `ja`, `ru`, etc.) inherited from Growl — the app only ships **English**
  (`en.lproj`) now. Reduced the `Localizable.strings` variant group to `en` only and
  removed a vestigial "pt-BR link to pt" build script phase that produced a dangling
  `pt.lproj` symlink after the locales were removed.

### Fixed a real memory leak — every banner ever shown was retained forever (Jul 2026)
- Found and fixed a **retain cycle** in the custom notification banner
  (`GrowlApplicationBridge.m`): the banner's `NSPanel` retained its close button, whose
  `onClick` block strongly captured the `dismiss` block, which in turn strongly captured
  the panel itself (`panel → closeBtn → onClick block → panel`). This meant every banner
  ever shown was **never deallocated** — only hidden (`orderOut`) — leaking permanently for
  the app's whole run. With periodic status refires, Wi-Fi signal-level notices, and device
  events, this accumulated into hundreds of MB of RSS over hours of uptime.
- Fixed by capturing the panel **weakly** inside the `dismiss` block (re-strengthened locally
  only for the duration of the dismiss call). Verified with a stress test: 60 real banner
  notifications (mount/eject cycles) now leave `phys_footprint` unchanged (~75 MB) after the
  banners auto-dismiss, versus growing without bound before the fix.

### Fixes (Jul 2026)
- **Static-analyzer pass (clean):** (1) the login-helper's `Info.plist` still carried the
  old `com.growl.HardwareGrowlerLauncher` bundle id after the rename, mismatching its
  `PRODUCT_BUNDLE_IDENTIFIER` — set it to `$(PRODUCT_BUNDLE_IDENTIFIER)` so it always
  matches (`com.jensyleo.hg4mac.Launcher`). (2) `HWGImageTextCell.m` was compiled
  without ARC, so its `strong` `image` ivar leaked (no `dealloc`) — added `-fobjc-arc`
  to that file (it was already written ARC-style). Analyzer now clean.
- **Single-instance guaranteed.** Added `LSMultipleInstancesProhibited` to the Info.plist
  and a runtime guard at launch: if another copy with the same bundle id is already
  running, the new launch quits immediately and the existing one keeps running. Covers
  launches Launch Services doesn't police (running the binary directly / via launchd).
- **"Battery fully charged" notification now actually fires.** Reaching 100% on AC
  doesn't change the power-source type and doesn't flip the time-remaining-known state,
  so the existing changedType/sendTime/refire path never announced it — the notice was
  effectively dead. Added an explicit one-time "Battery Fully Charged" notice that fires
  when the battery transitions to 100% while running, exactly once (re-armed only when it
  drops below 100% or is unplugged). It stays silent at app launch if the battery is
  already full, so it announces a real transition, not every startup. Uses a distinct
  notification identifier (`PowerFullyCharged`) so the duplicate-suppression key
  (name+identifier+description) doesn't collide with the generic "On AC Power" notice
  that fires on reconnect with the same description.
- **No more "Charging at 100%".** At 100% macOS briefly still reports `isCharging`, so the
  status text read "Charging at 100%". Any state at ≥100% now reads "Charged at 100%".

### App & menu-bar icons (Jul 2026)
- Replaced both the **app icon (Dock)** and the **menu-bar icon** — both were the **Growl
  paw mascot** — with **original HG4MAC artwork**, completing the rebrand and removing
  third-party brand artwork from the app's own identity.
- The **menu-bar icon keeps its blue-dot accent in color** (the app's distinctive mark): it
  is a non-template color image with **light/dark variants** (dark claws for a light menu
  bar, light claws for a dark one) picked automatically by the menu bar's appearance, so it
  reads on both themes while preserving the blue dot. Drawn at 18 pt.
- All images that ship in the app are now **original** (menu-bar + app icon; the 54
  Asset-catalog icons are our own PNGs; no third-party artwork bundled).
- **Removed all third-party / unused image remnants from the repo.** The only images left
  are the app's own (`Resources/` — 54 Asset icons + app icon + menu-bar icons). Moved out
  (not used by the app): Growl framework artwork (`images/`, `Core/Resources/`), the two
  Prowl-plugin PNGs, and the legacy `Extras/` tree; plus old prebuilt binaries next to the
  repo (`Apple Silicon/`, `Intel/`, incl. 2018 `Growl.app`/`HardwareGrowler.app`). Verified
  none were referenced by the Xcode project — the app still builds clean.

### Cleanup: removed the unused login helper (Jul 2026)
- Dropped the legacy **`HardwareGrowlerLauncher`** login-helper from the build: it was a
  Growl-era helper that auto-started the app at login, but HG4MAC uses **`SMAppService`
  (mainAppService)** on macOS 13+, so the helper was dead weight. Removed the "Copy Launcher"
  embed phase and the target dependency, so it no longer builds or ships in
  `Contents/Library/LoginItems/`. This also eliminates the **last build warning** (the
  helper's ad-hoc code-signing notice) — the project now builds with **0 warnings**.
  Start-at-Login is unaffected.
- Also moved unused monorepo folders out of the tree (`Bindings/`, `Developer Tools/`,
  `mas/`) — not referenced by the Xcode project.

### About panel (Jul 2026)
- Added an **"About HG4MAC…"** item to the status menu → standard macOS About panel
  showing name, **version (1.0)**, **© 2026 Jensy Leonardo Martínez Cruz**, a **GPLv3 +
  NO-WARRANTY notice** and a **link to the license**. Defined the previously-empty
  `HWG_VERSION` / `COPYRIGHT` build settings so version and copyright are populated.
- Replaced the About panel's `Credits.rtf` (was the Growl-themed "Grrrr… A Growl Extra…")
  with a neutral, serious description of HG4MAC + GPLv3/no-warranty line.

### UI tweaks (Jul 2026)
- Rotated the USB module icon 180° in the Preferences module list (`HWGPrefsUSB`
  asset only; the USB notification icons are unchanged).
- **Rotated the USB notification icons 180°** (`USB-On`, `USB-Off`) — they were upside
  down and are now correct. `HWGPrefsUSB` was briefly rotated too but reverted — its prior
  orientation was correct (it's an all-white glyph on transparent, invisible against the
  Preferences row background — a pre-existing, unrelated cosmetic issue in the source
  artwork, left as-is).
- **Color-coded Wi-Fi signal icons** — levels 1/2/3 are now red / orange / yellow
  (previously all blue), so signal strength reads at a glance. Levels 0 and 4 kept as-is.
- **Wi-Fi with no RSSI reading now shows the all-gray "no signal" icon** (`Network-Wifi-0`)
  instead of assuming full bars.
- **Preferences window default size** set to 611×319 (was 500×231). The window still
  autosaves any resize (`HWGrowlerPrefsWindowFrame`).

### Rebranded to HG4MAC (Jul 2026)
- The app is now **HG4MAC** ("HardwareGrowler for Mac"): product/app name → `HG4MAC.app`,
  menu-bar & notification display name → HG4MAC, and all visible menu strings updated.
- **Own bundle identifiers**, moving off the Growl namespace: app `com.jensyleo.hg4mac`,
  login helper `com.jensyleo.hg4mac.Launcher`, and the six monitors
  `com.jensyleo.hg4mac.<Monitor>`. This also strengthens trademark distance from Growl.
- Uninstall cleans both the new domain and legacy `com.growl.hardwaregrowler` /
  `HardwareGrowler` artifacts, so upgraders leave nothing behind.
- The internal Xcode target/scheme stays `HardwareGrowler`; upstream attribution (fork of
  HardwareGrowler / Growl) is unchanged.

### Licensing & third-party code hygiene (Jul 2026)
- Full legal audit of every **compiled** source for GPL compatibility. The binary now
  contains only **GPLv3** (this fork's own code) + **BSD** (Growl, GPL-compatible),
  each with its notice retained.
- **`TMSliderControl`** (on/off toggle) confirmed to be an original rewrite (draws via
  `NSBezierPath`, uses no artwork); added a GPLv3 header, removed 8 unused 1×1 placeholder
  PNGs and their project references.
- **`GrowlApplicationBridge.m`** given a header documenting its Growl (BSD) origin and the
  fork's GPL modifications.
- **Replaced Apple sample-code cell** `ACImageAndTextCell` with a clean-room, original
  implementation **`HWGImageTextCell`** (GPLv3) — the preferences module list no longer
  carries any Apple sample code.
- **Closed license-header gaps:** every compiled source now carries a license notice.
  Files with no header were resolved by origin — Growl-original files (`GrowlDefines.h`,
  `GrowlVersionUtilities`, `GrowlOperatingSystemVersion`) got their **BSD/Growl** notice
  restored; the fork's own `GrowlStub/Growl.h` got a **GPLv3** header.
- Licensing policy: fork's own work is **GPLv3**; Growl (BSD) code may be modified as needed
  but keeps its BSD notice (derivative work); genuine license gaps in own/ambiguous files are
  resolved toward GPL. Goal: maximize GPL-licensed work while respecting upstream licenses.

### Memory management & build
- Migrated all compiled sources from **MRC to ARC** (per-file `-fobjc-arc`): the six
  monitors (Bluetooth, Network, Power, Thunderbolt, USB, Volume), `HWGrowlPluginController`,
  `AppDelegate`, and `GrowlApplicationBridge`. CoreFoundation/IOKit boundaries use explicit
  `__bridge` casts; CF/IOKit objects are still released manually.
- Unified deployment target to **13.0** and architectures to standard 64-bit.
- Reduced build warnings from **44 → 1** (only the ad-hoc launcher code-signing notice
  remains, which requires a Developer ID).
- Removed dead code: the `#ifdef BETA` block (used removed `NSCalendarDate` /
  `NSRunAlertPanel`); confirmed legacy monitors fully removed.

### Removed / replaced deprecated & removed APIs (macOS 13+ / Apple Silicon)
- Carbon Process Manager (`ProcessSerialNumber`, `TransformProcessType`, `GetFrontProcess`)
  → `NSApp setActivationPolicy:` + `NSApp hide:`.
- `launchApplicationAtURL:options:configuration:error:` →
  `openApplicationAtURL:configuration:completionHandler:`.
- Deprecated `NSAlert`/`NSStatusItem`/text-alignment/compositing constants modernized.
- `kIOMasterPortDefault` → `kIOMainPortDefault`; `CFRunLoopGetCurrent` → `CFRunLoopGetMain`
  for IOKit callbacks.
- Login item migrated to **`SMAppService`** (macOS 13+), with legacy LaunchAgent cleanup.
- Menu-bar item via **`NSStatusItem.button`** (template image, auto-tint/highlight).

### Notifications (custom banner)
- Custom translucent **`NSPanel`** banner using **`NSVisualEffectView`**:
  - per-notification colored icon (not just the app icon),
  - dynamic height for long titles/bodies,
  - vertical stacking of multiple banners,
  - close (×) button and click-to-open (e.g. reveal a mounted volume in Finder).
- **Duplicate suppression** (cooldown) and **"unstable device"** bounce detection with its
  own warning icon; the dedup/bounce dictionaries self-purge to avoid unbounded growth.

### Monitors
- **Network**: Wi-Fi connect/disconnect via **CoreWLAN** (+ **CoreLocation** for SSID),
  Ethernet/interface link up/down with media speed, IPv4/IPv6 with CIDR and gateway.
  - Reports the **already-connected Wi-Fi at launch** (CoreWLAN only fires on change).
  - The **Wi-Fi icon reflects signal strength** (RSSI → `Network-Wifi-0…4`) instead of
    always showing full bars.
  - **Notifies when the Wi-Fi signal level changes** (improved ↑ / degraded ↓) — only when
    the bar level crosses (0↔4), with a cooldown to avoid flapping. New notification type
    "Wi-Fi Signal Changed". Implemented by polling the RSSI on a timer, because the CoreWLAN
    link-quality event does not fire on modern macOS.
  - The **Network monitor now has a Preferences pane** (Preferences → Modules → Network)
    with a configurable **Wi-Fi signal check interval** (slider, 5–60 s, default 12 s).
  - Reports interface up/down **even without an IP/media** (intended).
  - Uses the **Ethernet connector icon only for real Ethernet** (recognized media); other
    interfaces (e.g. an iPhone/USB net interface with "Unknown" media) get a generic
    **interface icon** — the same family is kept across the matching up/down pair.
  - **Ethernet/wired link up/down now uses `NWPathMonitor`** (modern Network.framework)
    instead of the legacy SCDynamicStore `.../Link` keys — it diffs the set of available
    wired interfaces across path updates and feeds the same notification path (media speed
    + icon). SCDynamicStore is still used only for IP addresses / gateway.
- **Power**: AC/battery transitions, **battery-level icon ramp (0–100)**, a
  **charging-level icon ramp**, time-remaining / time-to-charge, periodic refire,
  low-battery warning.
  - Fixed the periodic refire **repeating "100%"** when fully charged — now announced once.
  - Fixed the plugged-in icon: shows the **charging ramp at the actual battery level**
    (not a full-battery icon) when you connect at e.g. 10%; the plain "plugged" icon is
    used only when the battery is full.
- **Removed** monitors that no longer apply: Time Machine, Phone, Keyboard; **FireWire
  replaced by Thunderbolt**.

### Icons
- Migrated icons from TIFF to an **Asset Catalog** (`Assets.xcassets`) with colored
  artwork; the banner carries each notification's own icon. Battery ramp colors
  (red → orange → yellow → green) and a charging ramp added.

### Reliability / code-quality pass
A full clang **static-analysis** run (clean) plus a multi-area review fixed:
- Thunderbolt: used `IORegistryEntryGetName` (was `IORegistryEntryGetProperty` with an
  **uninitialized size** argument — undefined behavior).
- IOKit notification **iterators released** in `dealloc` (Thunderbolt, USB).
- Network: CoreWLAN `CWEventDelegate` callbacks **marshaled to the main thread**.
- Power: guarded `CFNumberGetValue` against NULL and against **divide-by-zero**.
- `GrowlOnSwitch`: balanced KVO observer across `initWithFrame:`/`initWithCoder:`/`dealloc`;
  dark-mode-safe label colors.
- Banner: validate icon data (`-isValid`) before use.
- `TMSliderControl`: wrapped shadow drawing in save/restore graphics state.

### Responsiveness
- **App Nap disabled** (`LSAppNapIsDisabled`) so the background menu-bar agent isn't
  throttled and hardware notifications fire promptly.

### Uninstall
- Clean **Uninstall** menu item: unregisters the login item, removes preferences / caches /
  saved state, and moves the app to the Trash — leaving no orphan files.
