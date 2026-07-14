# Changelog — modernization fork

All notable changes made in this fork on top of
[`pranav-prakash/HardwareGrowler-NC`](https://github.com/pranav-prakash/HardwareGrowler-NC).
Target: **macOS 13+**, developed/tested on **macOS 26 (Tahoe), Apple Silicon (M-series)**.

## Modernization (2026)

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
