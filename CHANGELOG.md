# Changelog — modernization fork

All notable changes made in this fork on top of
[`pranav-prakash/HardwareGrowler-NC`](https://github.com/pranav-prakash/HardwareGrowler-NC).
Target: **macOS 13+**, developed/tested on **macOS 26 (Tahoe), Apple Silicon (M-series)**.

## 2026-07-17

### New: per-field notification settings for USB, Bluetooth, and Thunderbolt
- Extends the per-field toggle pattern already used by Network/Power Monitor to the three
  monitors below. Every field is independently switchable from Preferences → Modules → the
  relevant monitor, all on by default:
  - **USB**: manufacturer/product name, vendor/product ID, speed, device class.
  - **Bluetooth**: device type, paired state, MAC address.
  - **Thunderbolt**: vendor/product ID, device class.
- Fixed a layout bug hit while building this: the first-ever time the Preferences window is
  opened in a session, the pane for whichever monitor is selected by default (Bluetooth,
  alphabetically first) showed its "Notification fields" controls displaced far below where
  they belonged, with a large empty gap above them. Root cause, found via Accessibility
  introspection of the live app (comparing real on-screen element positions in the broken
  vs. self-corrected state): the pane is sized to match its container's frame at the moment
  it's first inserted, but the container itself is *not* at its final on-screen size yet at
  that point — it grows once the window's sidebar/detail split actually resolves. Every
  other monitor's pane only ever gets built after the user manually clicks its row, by which
  time the container is already at its real size, so they never hit this. Fixed by observing
  `NSViewFrameDidChangeNotification` on the container and re-syncing the currently-displayed
  pane's frame whenever it actually changes, instead of assuming the frame at insertion time
  is final.

### New: richer notification detail for USB, Bluetooth, and Thunderbolt
- These three monitors previously showed only the device name. Added, using public/
  documented APIs only:
  - **USB**: manufacturer and product name, vendor/product ID, USB generation/speed
    (1.0/1.1/2.0/3.x), and a human-readable device class (Mass Storage, HID, Hub, Audio,
    etc. — from the USB-IF's published base class table), all read via
    `IORegistryEntryCreateCFProperty` the same way the existing hub detection already
    reads `bDeviceClass`.
  - **Bluetooth**: a device type label (Keyboard, Mouse/Trackpad, Headphones, Hands-Free,
    etc. — from `IOBluetoothDevice`'s public `deviceClassMajor`/`deviceClassMinor`), paired
    state, and MAC address. Battery level remains intentionally excluded — no public,
    documented API exposes it for an arbitrary paired accessory.
  - **Thunderbolt**: vendor/device ID and a device type label (Storage Controller, Display
    Controller, Bridge/Dock, etc. — from the PCI-SIG's published class-code table), read
    from the same `IOPCIDevice` registry entry as the existing device name. True
    Thunderbolt-generation/link-speed info (TB3/TB4/USB4) has no public API and was
    deliberately left out.
  - None of this extra detail is shown on disconnect — registry properties are frequently
    unreadable from an already-terminating device by the time that callback fires.
- Confirmed working: USB flash drive and a multi-chip USB-C hub/dock (each internal chip —
  LAN, card reader, USB 2.0/3.0 hub controllers — correctly reported separately with its
  own manufacturer/VID:PID/speed/type, which is expected since each enumerates as its own
  USB device), and a Bluetooth keyboard (showed "Keyboard" type correctly). Thunderbolt
  untested — no genuine Thunderbolt hardware available.

### New: per-field notification settings for Power Monitor
- Every field in the power/battery notification body is now independently toggleable from
  Preferences → Modules → Power Monitor: power source type (Battery/UPS/Unknown), charge
  state (Charging/Finishing/Charged), battery percentage, and time remaining/to-charge. All
  default on, matching prior always-on behavior. Added as a new "Notification fields"
  section below the existing refire-settings panel (that nib was left untouched) rather
  than converting the whole pane to a programmatic layout.
- Fixed a layout bug hit while building this: `PowerMonitorPrefs.xib`'s own content only
  occupies the top half of its declared frame (its lowest control's bottom edge sits well
  above the frame's actual bottom, with unused space baked in below it) — stacking new
  content from the frame's full height left a large gap. Found via Accessibility
  introspection of the live running app (queried real on-screen element positions rather
  than guessing from screenshots) and fixed by resuming the layout from the xib's actual
  content bottom instead.

## 2026-07-16

### New: Wi-Fi band, generation, and security in the connect notice
- "AirPort Connected" now also shows the channel band (2.4/5/6 GHz), the Wi-Fi generation
  (Wi-Fi 4/5/6/6E/7, derived from the active 802.11 PHY mode — 6GHz-band 802.11ax is
  labeled "Wi-Fi 6E" per the consumer naming, not plain "Wi-Fi 6"), and the network's
  security type (Open, WEP, WPA/WPA2/WPA3 Personal or Enterprise, OWE) via CoreWLAN
  (`CWInterface.wlanChannel`/`activePHYMode`/`security`) — none of which require Location
  permission (unlike SSID/BSSID). Configurable: a new checkbox in Preferences → Modules →
  Network Monitor ("Show band, generation, and security in the Wi-Fi connect notice"),
  on by default. Label formatting uses a single tab after each field for consistent
  left alignment.

### Fixed: Ethernet link detection reverted from NWPathMonitor back to raw link state
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

### New: per-field notification settings for Network Monitor, in Wi-Fi / Ethernet / IP tabs
- Every individual piece of information Network Monitor can show is now independently
  toggleable from Preferences → Modules → Network Monitor, organized into 3 tabs:
  - **Wi-Fi**: SSID, BSSID, band, generation, security type (all default on), plus the
    existing signal-check-interval slider.
  - **Ethernet**: interface name, speed, mode/duplex (all default on), and a new toggle to
    also report Wi-Fi's own link and AWDL/AirDrop events (default off — these are normally
    filtered out as noise, see the link-detection fix above).
  - **IP**: IPv4 address, IPv6 address, gateway, the "(non-routable)" tag, and whether to
    use friendly interface names instead of raw BSD names (all default on).
  All defaults match prior always-on behavior, so no existing notification content changes
  unless a box is unchecked. The "released" transition in "IP Addresses Updated" is now
  decided from actual address presence rather than the (now potentially empty, depending on
  toggles) displayed text, so hiding every IP field doesn't misreport a live connection as
  disconnected.
- Fixed a related, longer-standing cosmetic bug while adding this panel: the Preferences
  window's "Modules" box didn't grow when the window was resized, for any monitor — two
  `autoresizesSubviews="NO"` flags in `MainMenu.xib` (on the General/Modules tab switcher
  and the per-monitor settings box) were blocking the resize from propagating down.

### Repository cleanup
- Removed `NOTICE.md` (content was already duplicated in the README's Credits & license
  section) and `SFSymbols-Migration-Notes.md` (unimplemented internal planning notes) —
  only `README.md` and `CHANGELOG.md` remain as markdown files.
- Stopped tracking `xcuserdata/` (Xcode's local user state), which had been committed
  before `.gitignore` excluded it.
- Corrected two stale README claims: the menu-bar icon is a colored image (not a
  template), and the project builds with 0 warnings (not 1). Added a Known Limitations
  section documenting the full/half-duplex discrepancy above.
