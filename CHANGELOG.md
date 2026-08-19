# Changelog — modernization fork

All notable changes made in this fork on top of
[`pranav-prakash/HardwareGrowler-NC`](https://github.com/pranav-prakash/HardwareGrowler-NC).
Target: **macOS 13+**, developed/tested on **macOS 26 (Tahoe), Apple Silicon (M-series)**.

## v1.18.0 — 2026-08-18 (in progress)

Result of a final exhaustive public-API audit across all 13 monitors (see the "Final API audit"
comments throughout the code). Adding one confirmed, tested feature at a time.

### Removed: 3 Intel-only features pulled from this build (documented for HG4MAC-INTEL)
Thermal Monitor's CPU Power Limited and Hardware Thermal Warning Level, and Thunderbolt
Monitor's real GPU identity/location/VRAM in eGPU notifications, were all implemented and
verified working — then confirmed LIVE that their underlying APIs (`IOPMCopyCPUPowerStatus`,
`IOPMGetThermalWarningLevel`) always return `kIOReturnNotFound` on Apple Silicon, and that eGPUs
aren't supported on Apple Silicon at all. Kept the risk (these 3 rows repeatedly triggered a
real layout bug in the shared icon-picker component) with zero payoff on this hardware, so they
were pulled from the Apple Silicon build. Full working code preserved in git history
(`770c430`, `db84c66`) and documented in detail in `TODO.md`'s "PENDIENTE — SOLO PARA
HG4MAC-INTEL" section for direct porting when that fork resumes.

### Fixed (properly, this time): Icons tab checkbox layout bug
The zero-width and zero-margin fixes below were both real and are still in place. A third
attempt to ALSO make long labels wrap instead of truncate (so "(Intel only)" style qualifiers
stayed visible) introduced a new regression affecting more checkboxes than the wrapping was
meant to fix, and was reverted — `HWGIconPickerView` is back to the simpler single-line +
240pt-cap-and-truncate approach, which was independently confirmed working via
`AXUIElementCopyElementAtPosition` hit-testing before the wrapping attempt. Removing the two
Intel-only Thermal rows (above) also means no label in the app is currently long enough to need
wrapping in the first place.

### Added: Printer Monitor — Rejecting Jobs event + Capabilities field
Both read from the same `printer-type` `CUPS_PRINTER_*` bitmask CUPS already returns (no extra
IPP round-trip): `CUPS_PRINTER_REJECTING` (a printer can start/stop accepting jobs at any time —
admin pause, or auto-reject after repeated errors) gets its own Icons-tab event with a dedicated
icon; Color/Duplex/Staple/Fax/MFP capability bits are a static General-tab field on the existing
"Printer Connected" notification. The "job name/owner" candidate from the audit was already
covered by the existing Print Job Started/Finished feature — no new work needed there.

### Fixed: Dark Wake Thermal Emergency notification now off by default
Same reasoning as the other rare/niche fields in this app: an event this uncommon shouldn't be
noisy out of the box.

### Added: Gamepad Monitor — 5 remaining audit candidates (cross-platform, no Intel-only content)
Game-recognized keyboard/mouse connect/disconnect (`GCKeyboard`/`GCMouse`, macOS 11+), racing
wheel connect/disconnect (`GCRacingWheel`, macOS 13+), DualSense/DualShock lightbar color as a
read-only field, and Xbox Elite paddle presence. All added as plain General-tab checkboxes
following the same pattern already verified working in Thunderbolt/Camera Monitor — the shared
`HWGIconPickerView` component was not touched. Pending live hardware verification (see `TODO.md`).

### Fixed: notify toggles misplaced in General tab instead of Icons (correction)
Several new "enable/disable this notification" checkboxes added during this session's audit
pass ended up on the General tab instead of Icons, violating this app's own established
convention (notify toggles → Icons, field-visibility toggles → General). Moved across all 5
modules touched this session: Gamepad (Keyboard/Mouse/Racing Wheel), Camera (Portrait Effect/
Studio Light/Reactions/Background Replacement), Display (Sleep/Wake, Color Profile), Audio
(Jack/Data Source/Device Stopped Responding/Microphone Mode/Head-Tracking/MIDI), and Network
(Detaching/Service Order/Promiscuous/Bond — the dedicated "Other" tab created for these was
reverted back to its empty placeholder). Field-visibility checkboxes that were correctly on
General were left untouched.

### Added: Network Monitor — batch 5/N of 32 audit candidates (cross-platform) — module complete
Adapter Detaching (reuses the existing Link dict, no new observation), service order changed
(new watched key, distinct from PrimaryInterfaceChanged), baudrate for non-Ethernet interfaces,
promiscuous mode, and Link Aggregation (Bond) member status — first real use of the previously-
placeholder "Other" tab. 25/32 candidates done.

Investigated and confirmed the remaining 7: `NEVPNManager`/`NEFilterManager`/
`NEDNSSettingsManager`/`NETransparentProxyManager` are all "this app's own configuration only"
(confirmed via the NEFilterManager header's own documented disable-other-apps'-configs
behavior) — VPN protocol/server detail, VPN config CRUD, content filter, encrypted DNS, and
traffic-interception-extension status can't be read for third-party apps' configurations via
public API, so they're not implemented. AVB/TSN and private Wi-Fi MAC rotation have no public
API/event either. NetworkMonitor's 32-candidate audit is now considered complete.

### Added: Network Monitor — batch 4/N of 32 audit candidates (cross-platform)
Path status/costly/constrained (`nw_path_monitor`, a new mechanism distinct from the reverted
16-jul NWPathMonitor link-detection attempt — this reads facts SCDynamicStore/SCNetworkReachability
can't provide, not connect/disconnect), link quality (`nw_path_get_link_quality` — found to be
macOS 26.0+ only, guarded with `@available`, degrades to "Unknown" on older macOS), and max
supported vs. negotiated Ethernet speed (two-pass `SIOCGIFMEDIA`). New `Network.framework` link.
Fixed a real ARC bridging bug during implementation (nw_path_monitor_t retain/release via
`__bridge_retained`/`__bridge_transfer`, not manual nw_release). 20/32 candidates done — see
`TODO.md`.

### Added: Network Monitor — batch 3/N of 32 audit candidates (cross-platform)
IP config method (DHCP/Manual), MTU, decoded interface type (`SCNetworkInterfaceGetInterfaceType`),
MAC address (non-Wi-Fi), DNS search domains, and full DHCP lease detail (start/expiration/
server) — all static fields on the existing IPAddressChange notification. Also fixed a real
layout bug: the IP tab's `scrollWrapping:height:` was undersized for its new row count (same bug
class as the Icons tab fix on 17-ago), bumped 230→430. 15/32 candidates done — see `TODO.md`.

### Added: Network Monitor — batch 2/N of 32 audit candidates (cross-platform)
Wi-Fi country/region code, transmit power, hardware address, interface mode — all from
`CWInterface`, same class as the existing Band/Generation/Security fields. Also: Wi-Fi Host AP/
ad-hoc mode transition notification, reusing the existing `-modeDidChangeForWiFiInterfaceWithName:`
CWEventDelegate callback (no new observation mechanism). All off by default. 9/32 candidates
done — see `TODO.md` for the remaining 23.

### Added: Network Monitor — batch 1/N of 32 audit candidates (cross-platform)
General Internet reachability (`SCNetworkReachability`), DHCP lease renewed/rebound (new
per-interface `SCDynamicStore` key pattern), computer name changed, and Network Location
changed. All off by default, added as Icons-tab notify toggles reusing the module icon. This is
the first of several planned batches for this module's remaining ~28 candidates — see `TODO.md`
for the full remaining list and scope notes (incl. a possible real API limit on VPN protocol
detail via `NEVPNManager`, to investigate before that batch).

### Added: Audio Monitor — 8 remaining audit candidates (cross-platform, no Intel-only content)
Jack connect/disconnect, active data source change (built-in speakers vs. headphones vs. line
out), device-stopped-responding, microphone mode (class-level KVO, same technique as Camera
Monitor's Control Center toggles), head-tracking headphones via `CMHeadphoneMotionManager`
(macOS 14+, new CoreMotion.framework link), MIDI device add/remove (new CoreMIDI.framework
link), and bit depth/latency static fields. Aggregate/Multi-Output device creation needed no new
code — already surfaced through the existing transport-type field. All off by default except
MIDI. Pending live verification with real hardware (headphones, MIDI device, AirPods Pro/Max) —
see `TODO.md`.

### Added: Display Monitor — 8 remaining audit candidates (cross-platform, no Intel-only content)
Color profile change (via `NSDistributedNotificationCenter`, not the usual local one — ColorSync
posts system-wide), EDID vendor/model/serial, VRR/ProMotion range, HDR/EDR headroom, notch/
safe-area presence, per-display sleep/wake (new `DisplaySleepChanged` notification, its own
diffed signature dictionary), and hardware-vs-software mirroring (folded into the existing
mirror-source field). `CGDisplayModeCopyPixelEncoding` (bit depth) was found `API_DEPRECATED`
since macOS 10.11 — not implemented. The `CGDisplayChangeSummaryFlags` enum-of-11-bits candidate
is already covered by this module's existing derived events (Connected/Disconnected/ModeChanged/
RoleChanged); no separate raw-bitmask diagnostic was added. All new fields off by default except
Sleep/Wake (on, matching Mode/Role Changed's convention for genuinely new events). Pending live
verification with external hardware — see `TODO.md`.

### Added: Camera Monitor — 6 remaining audit candidates (cross-platform, no Intel-only content)
Portrait Effect / Studio Light / Reactions / Background Replacement (Control Center video
effects, macOS 12/13/14/15+, observed via class-level KVO on `AVCaptureDevice`), System Preferred
Camera (macOS 13+), and max supported frame rate. All off by default, plain General-tab
checkboxes. `AVCaptureDevice.isSuspended` from the same audit entry was found to not exist on
macOS at all (`API_UNAVAILABLE` there, iOS/tvOS/visionOS only per the SDK header) — not
implemented, documented as an audit inaccuracy in `TODO.md`. Pending live verification (toggling
Control Center effects, testing with a second camera) — see `TODO.md`.

### Fixed: every Icons tab "Notify?" checkbox had zero width (silently unclickable)
Reported live as "the last 2 Thermal Monitor checkboxes don't respond to clicks" — the first
attempted diagnosis (bumping Thermal Monitor's fixed pane height, since that's the bug class
already fixed twice earlier this session) did NOT fix it. Built an isolated test harness that
loads the compiled plugin bundle directly, places its `-preferencePane` in a throwaway window,
and dumps the real Auto Layout-resolved frame of every subview — confirmed the actual root
cause: `HWGIconPickerView`'s per-row "Notify?" checkbox had a `leading` constraint and a
`trailing <= self.trailingAnchor` **inequality**, but no width constraint and no positive pull
resolving its width — Auto Layout collapsed it to `frame.width == 0` on every single row, in
every monitor that uses this shared component (13 modules). This went unnoticed because most
existing rows default ON (nothing to click to see it "work"); Thermal Monitor's two newest
rows are the first to default OFF, on the only toggle able to enable them (no General-tab
equivalent) — the first case where actually clicking that specific checkbox mattered. Fixed
with an explicit `widthAnchor` constraint (20pt) in the shared component — corrects every
monitor at once, not just Thermal Monitor. Verified via the same harness: frame went from
`{0, 16}` to `{20, 16}` across all rows.

### Fixed: Icons tab's LAST row could sit flush against a zero-margin computed edge
After the width fix above, the report persisted for the same two rows specifically — same
harness, this time dumping `HWGIconPickerView`'s own closing constraint: the view's bottom was
pinned to the last row's image view with a bare equality (`== self.bottomAnchor`, no slack),
so every caller sizing this view from `-fittingSize` gets the tightest possible height with
zero margin below the final row. Any fractional-point Auto Layout rounding there clips exactly
the bottom row and only the bottom row — matching the reported pattern precisely (always the
LAST items, never an earlier one, since earlier rows have real margin from the next row's own
top gap). Added 8pt of bottom padding to the closing constraint; confirmed via the harness that
`HWGIconPickerView`'s frame grew accordingly (365→373pt) and the last row now has real
clearance instead of sitting at the exact computed edge.

### Fixed: Thermal Monitor's Icons tab still needed to scroll by a hair to reach the last row
Reported a third time after both fixes above. Did the actual arithmetic instead of guessing
again: the Icons tab's real content height is 432pt (header + 7 rows + padding), but the pane's
outer fixed frame was 460pt — after subtracting the tab header's own chrome (~25-30pt), the
VISIBLE area was only marginally larger than the content, right at the edge where scrolling
either barely wasn't needed or barely was, depending on rounding — and scrolling to reach a row
this close to the fold is exactly the kind of interaction most likely to misfire. Bumped the
pane's fixed height from 460 to 560 (visible area now ~530pt vs 432pt needed — over 100pt of
real margin, scrolling provably not required at all). Confirmed via the harness:
`scroll.documentView.frame.size.height` (432) vs `scroll.contentSize.height` (604 in a 650pt
test window) — content fits with room to spare.

### Added: Thunderbolt Monitor — real GPU identity, location and VRAM in eGPU notifications
`MTLDevice.name/location/isRemovable/recommendedMaxWorkingSetSize` (Metal.framework, public,
macOS 10.11+). The existing eGPU detection (PCI class-code "Display Controller") only ever knew
the raw vendor/device ID; this resolves the actual GPU Metal sees, matching on
`isRemovable == YES`. Only meaningful on connect (Metal's device list has already dropped the
card by the time a disconnect fires, same limitation the PCI-based check already documents).
Skipped from this audit: a Metal-based `MTLDeviceWasAddedNotification` connect/disconnect event
would duplicate the PCI-based detection this module already has; Neural Engine core count
(`MLAllComputeDevices`) doesn't belong to a Thunderbolt monitor conceptually — left out rather
than force-fit.

### Added: Thermal Monitor — CPU Power Limited and Hardware Thermal Warning Level (Intel only)
`IOPMCopyCPUPowerStatus()` and `IOPMGetThermalWarningLevel()` (both `IOKit/pwr_mgt/IOPMLib.h`,
public), pushed via their documented BSD `notify(3)` keys (`com.apple.system.power.CPU` /
`com.apple.system.power.thermal_warning`) instead of a poll timer. **Confirmed live on this M4
(Apple Silicon): both return `kIOReturnNotFound`** — Apple Silicon never publishes these values,
only Intel does. Since this app still ships as a universal binary (`arm64 x86_64`), this is real
functionality on Intel Macs, not dead code — just a silent no-op on Apple Silicon. Both OFF by
default and labeled "(Intel only)" in the Icons tab so Apple Silicon users aren't left wondering
why the toggle never fires anything.

### Added: Thermal Monitor — Dark Wake Thermal Emergency
`kIOPMMessageDarkWakeThermalEmergency`, delivered via `IOServiceAddInterestNotification` on
`IOPMrootDomain` (public API, `IOKit/pwr_mgt/IOPMLib.h` + `IOMessage.h`). Fires specifically when
the Mac overheats during a brief maintenance wake (network/backup wake while the lid is closed or
the display is off) — a scenario the existing `NSProcessInfo.thermalState` polling might not catch
before the Mac goes back to sleep. New dedicated icon (crescent moon + warning badge). ON by
default.

## v1.17.0 — 2026-08-17

### Added: "Recommended" Performance preset
The Modules tab's Performance selector only offered Minimal / All / Custom. Added a fourth
option, "Recommended" — Minimal's set (Volume, USB, Thunderbolt, Bluetooth, Power, Network)
plus Display and Audio, the two monitors most people actually want day-to-day, while still
skipping the heavier-polling or more niche ones (Printer's CUPS polling, Scanner's network
ESCL polling, Gamepad, Thermal, Camera). Performance-first coverage of what's common, not
everything that's common.

### Performance: reduced Printer Monitor's main-thread polling cost
`checkPrinters` calls `cupsGetDests()` (a CUPS/network round-trip) on the main thread on every
poll tick, and that tick was firing every 3s whenever any printer notification was enabled —
by far the shortest fixed interval of any monitor's background poll. Raised to 8s; printer
state changes slowly enough that this trades no meaningful responsiveness for noticeably less
background CUPS traffic.

### Fixed: "IP Addresses Updated" could land before "AirPort Disconnected"
When losing an IP address (as opposed to gaining one), this races against the WiFi radio-off/
disconnect sequence: `SCDynamicStore` detects the address is gone almost immediately once the
link drops, while the CoreWLAN-driven pair now has its own 0.4s delay (see the entry below).
That let "IP Addresses Updated" win the race and land before "AirPort Disconnected" — backwards
from radio → network → address, the order that actually reflects cause and effect. Delayed only
the release case (a fresh address assignment has no such ordering concern) by 0.8s, landing it
reliably last.

### Fixed: Bluetooth radio still felt slow; Wi-Fi notification order was backwards
Bluetooth's poll was resetting its baseline to "unknown" on every tick while both toggles were
off, so enabling a toggle in Preferences didn't take effect until the NEXT tick just to
re-establish a baseline (no notification), and only the tick after THAT could detect a real
change — up to a full extra poll interval of latency on top of the poll cadence itself. Now
tracks the real adapter state unconditionally every tick and only gates the notification on the
toggles, so a state already captured while disabled counts as a valid baseline the moment either
toggle turns on. Poll interval also shortened 2s→1s.

Wi-Fi: confirmed live (screenshot) that "AirPort Disconnected" could display before "Wi-Fi
Turned Off" even though the radio check already runs first in code — both `notifyWithName` calls
fire back-to-back with no delay, so the actual on-screen stacking order was left to macOS's own
notification delivery timing rather than call order. Added a short (0.4s) delay before "AirPort
Disconnected" specifically, so the radio notification (the actual cause, when both fire together)
reliably reaches the notification center first — reads as cause-then-effect instead of the reverse.

### Fixed: Wi-Fi Radio Off never notified; Bluetooth radio detection felt slow
Wi-Fi radio power detection was only hooked into the CWEventTypePowerDidChange CoreWLAN
callback — confirmed live that turning the radio off reaches CWEventDelegate as a LINK change
instead (or at least more reliably/promptly than the power callback): "AirPort Disconnected"
and the IP-address update, both driven by the same underlying method, fired instantly, but the
radio-off check never ran since it wasn't hooked to that path. Now runs from every WiFi
state-change callback (link/mode/BSSID, not just power), plus a poll-based fallback piggybacked
on the existing ~12s Wi-Fi signal poll, so it doesn't depend on any single CoreWLAN callback
firing reliably. Bluetooth's poll interval shortened from 5s to 2s, and now baselines
immediately when its checkbox is enabled instead of waiting for the first tick — could take up
to ~10s before the first real notification previously.

### Fixed: Bluetooth/Wi-Fi radio On and Off events shared icons with other rows
Both radio power events initially reused existing icons (Bluetooth-On/-Off, already the
defaultName for "Connected (generic)"/"Disconnected (generic)" a few rows up in the same
picker) — this app's icon-override system keys customizations by defaultName, so a user
customizing "Connected (generic)"'s icon would have silently re-skinned "Bluetooth Radio On"
too. Gave each radio event its own dedicated icon (Bluetooth-Radio-On/-Off, Network-Wifi-Radio-
On/-Off — the Wi-Fi ones were already distinct from "Wi-Fi Off"'s icon, no collision there, but
split into separate rows/keys anyway for symmetry with the Connected/Disconnected precedent) and
split each into two independent toggles (On and Off separately enable/customizable).

### Added: Bluetooth and Wi-Fi radio power on/off detection
Both radios' on/off toggle (System Settings/Control Center) went undetected before — this
monitor only ever reported device connect/disconnect (Bluetooth) or network association
(Wi-Fi's existing "AirPort Connected/Disconnected"), neither of which fires when the radio
itself is switched off while nothing was connected, or switched on with nothing yet associated.
Both new events, OFF by default, in the Icons tab with dedicated icons:
- **Bluetooth**: `IOBluetoothHostController.powerState` (public API), polled every 5s — no
  documented push notification exists for this specific state.
- **Wi-Fi**: reuses the existing `CWEventTypePowerDidChange` CoreWLAN callback (was already
  wired up but never checked for this independently of network association) — new dedicated
  "Wi-Fi Radio Turned On/Off" icon (green/gray power-button badge) to visually distinguish it
  from the existing "Wi-Fi Off" (disconnected-from-network) icon.

### Fixed: slow app launch
`HWGrowlPluginController.-postRegistrationInit` ran all 13 plugins synchronously, back-to-back,
on the main thread during `-init` — unlike `-fireOnLaunchNotes`, which already got a stagger
fix on 11-ago-2026. Any plugin doing real work there (USB/Thunderbolt Monitor walking every
attached device when "notify on launch" is enabled, Bluetooth Monitor's IOBluetoothDevice daemon
registration, Printer Monitor's `cupsGetDests()`) blocked every other plugin's setup, and the
app's own UI, in a cascading chain. Applied the same `dispatch_after` stagger pattern already
proven for `-fireOnLaunchNotes` (0.15s per module, main queue — not background, since IOKit
notification ports need to attach to the calling thread's run loop).

### Fixed: Scanner Monitor's eSCL poll could pile up overlapping requests
`NSURLSession`'s default request timeout (60s) is longer than this poll's own interval (5-60s,
10s default) — a scanner that's asleep/unreachable could accumulate overlapping HTTP requests
faster than they time out. Added an explicit 5s request timeout plus a per-device in-flight
guard, so a new poll tick skips a device still waiting on its previous request instead of
piling another one on top.

### Fixed: new checkboxes across 9 monitors were unclickable (fixed-height layout overflow)
Same bug class already hit once in Scanner Monitor's Icons tab, this time in General tabs
across Network, Printer, Bluetooth, USB, Audio, Camera, Display, Gamepad, and Thermal Monitor:
each uses a hardcoded content-view height rather than computing it from the actual row count.
Adding new checkboxes (this release) without growing that constant pushed the new rows past
the view's own bounds — AppKit doesn't hit-test subviews outside their parent's bounds, so the
checkbox renders but never responds to a click. Bumped every affected height with margin.
Volume Monitor and Power Monitor were unaffected — both already compute their height
dynamically from the row count.

### Added: dedicated Proxy Configuration Changed icon
Replaced the reused Network-Generic-On placeholder with its own icon: dark slate badge with a
server-rack glyph (3 status-lit blades), inspired by the "proxy server" concept the user shared
— redrawn in this app's flat two-tone style rather than copying the 3D reference image.

### Added: dedicated Ethernet Speed Changed icon
Replaced the reused Network-Ethernet-On (plain connected) icon with an orange speedometer badge
over the Ethernet jack — a direct visual reference to "speed changed" that the generic connected
icon didn't carry.

### Fixed: Battery Health Check used the wrong icon
Was showing the CURRENT CHARGE LEVEL icon (e.g. 50%-charged battery), unrelated to battery
HEALTH. Now picks by health percentage instead, reusing existing battery icons already in the
asset catalog: Power-100 (full/healthy look) at ≥80%, Power-50 (half, visually degraded) at
50-79%, Power-BatteryFailure (already used elsewhere for a failed battery) below 50%.

### Added: second full 13-module gap audit — "everything the system can offer"
A deeper follow-up to v1.16.0's audit: 13 parallel research passes (one per monitor) looking
for ANY remaining public-API data point or event not yet surfaced, this time explicitly
including items that need specific hardware to verify live. ~15 additional findings that would
require private/undocumented APIs (SMC fan/temperature, Night Shift, True Tone, external
display brightness, Bluetooth audio codec, DualSense lightbar color, etc.) were investigated
and deliberately NOT implemented, to preserve this app's public-API-only convention — each is
documented in detail in the local TODO.md in case Apple ever publishes an equivalent API.

**Network Monitor**: Wi-Fi link rate (Mbps), channel number + width, noise floor + derived SNR
(all via `CWInterface`/`CWChannel`, no Location permission needed), proxy configuration change
detection (HTTP/HTTPS/SOCKS/PAC via `SCDynamicStore`, same family as the existing DNS/primary-
interface detection).

**Bluetooth Monitor**: advertised SDP services list (`IOBluetoothDevice.services`), never
surfaced before — gives a more precise "what can this device do" than the existing class-based
type guess.

**Volume Monitor**: format description (APFS/exFAT/MS-DOS…), volume UUID, removable/ejectable
flags, read-only flag, case-sensitivity — all via `NSURLVolumeKeys` never read before.

**Power Monitor**: battery health condition string (`kIOPSBatteryHealthConditionKey` —
"Normal"/"Service Recommended"/"Replace Soon"/"Replace Now"), extra power-adapter fields
(family/ID/serial) on Adapter Changed, and four new events via `NSWorkspace`: System Sleep,
System Wake, Display(s) Sleep, Display(s) Wake — the last two distinguish a display-only sleep
(screen dims/locks, Mac stays awake) from a full system sleep, something this monitor never
distinguished before.

**USB Monitor**: serial number, firmware/release number (`bcdDevice`), port location ID — all
standard USB descriptor fields via the same `IORegistryEntryCreateCFProperty` pattern already
used for VID/PID.

**Audio Monitor**: device UID (stable identity across reconnects, unlike `AudioDeviceID` which
macOS can reassign), mute state.

**Camera Monitor**: position (Front/Back/Unspecified) via `AVCaptureDevice.position`.

**Display Monitor**: stable UUID (`CGDisplayCreateUUIDFromDisplayID`, survives reconnects unlike
`CGDirectDisplayID`), physical size + derived PPI, color space/gamut name, built-in flag,
mirror-source display ID (which display a mirrored display is actually mirroring).

**Gamepad Monitor**: battery state (Charging/Full/Discharging, not just the percentage already
shown), touchpad presence (DualSense/DualShock), haptics support, motion sensors presence — all
presence/capability checks via `GCController`, none activate the actual hardware.

**Printer Monitor**: sharing status (`printer-is-shared`, already sitting in the same per-dest
options dictionary every other field reads — no extra IPP round-trip).

**Scanner Monitor**: extended the existing `ScannerStatus` XML parser to also capture
`<pwg:JobStateReason>` entries — same endpoint/poll already in place for Scan Started/Finished,
optional field like ADF state (may never appear depending on firmware).

**Thermal Monitor**: notes when Low Power Mode is also currently on alongside a thermal-state
transition (`NSProcessInfo.isLowPowerModeEnabled`) — correlation only, not causal (Low Power
Mode can also be toggled manually or triggered by low battery independent of thermal pressure).

**Thunderbolt Monitor**: vendor name lookup (Intel/OWC/CalDigit/Kensington/Belkin/Elgato) over
the vendor-id already read for VID:PID.

**Deferred to a future pass** (identified, real value, but higher engineering effort/risk —
kept out of this round to keep it stable): Volume Monitor's second low-space warning tier
(touches proven hysteresis logic), Printer Monitor's print-queue length, Bluetooth Monitor's
adapter power-state (on/off) event.

## v1.16.1 — 2026-08-17

### Fixed: Scanner Monitor — no checkbox in the Icons tab responded to clicks
- Found live testing right after the icon work below shipped: **every** notify checkbox in this
  monitor's Icons tab (Found, Lost, Scan Started/Finished, Feeder State) stopped responding to
  clicks — not just the two new rows.
- Root cause: the new rows' labels included a `"(experimental)"` suffix, at 249-252pt wide. This
  picker shares one `nameColumnWidth` across every row (sized to the single longest label in the
  list), so that suffix blew the shared column width past this pane's fixed 528pt budget,
  pushing every row's checkbox column outside the visible/clickable area — including Found/Lost,
  which weren't touched by the icon work itself.
- Fixed by shortening the two labels to "Scan Started/Finished" and "Feeder State Changed" (the
  "experimental" caveat still appears in full in each event's `-noteDescriptions` entry, used by
  the History panel). Confirmed live: all 4 checkboxes toggle and persist correctly now.
- Added a visible caption below the Icons picker itself, explaining which two rows are
  experimental and why — the label shortening above made that caveat disappear from the row
  title, so it's now surfaced as plain body text instead (doesn't affect the shared column
  width, so it can't reintroduce the click bug above).

### Fixed: Printer Monitor — last "Notify" toggle moved from General to Icons
- "Notify when a printer is added/removed" was the one remaining checkbox still living in the
  General tab after every other Printer Monitor notification toggle was already moved to Icons
  in a prior pass. Investigated its relationship to the existing "Connected" row first (they
  looked possibly redundant): confirmed they gate genuinely different things — this key is the
  master switch for whether the poll timer runs at all, while "Connected" only controls that one
  notification's own text once polling is already active for any reason. Kept as two separate
  rows, no logic changes; only the UI location moved.

### Fixed: Scanner Monitor — all 4 notification icons were visually identical
- Every row in Scanner Monitor's Icons tab (Module Icon, Scanner Found/Lost, Scan Started/
  Finished, Feeder State Changed) reused the same bare `USB-TypeScanner` glyph, making the four
  rows indistinguishable from one another.
- Added 4 dedicated icons, following the same badge convention already used elsewhere in this
  app: a green check for Found, a red X for Lost, a blue document+scan-beam badge for Scan
  Started/Finished, and an amber "!" badge for Feeder (ADF) State.
- Found/Lost was originally a single shared toggle/icon; split into two independent checkboxes
  and icon rows (one event can't be represented by one icon covering two opposite states),
  matching the precedent Printer Monitor already set for Connected/Needs Attention.

## v1.16.0 — 2026-08-13

### Added: full monitoring gap audit across all 13 modules, several new fields/events implemented

A systematic review of every monitor (Network, Bluetooth, Volume, Power, USB, Camera, Gamepad,
Audio, Scanner, Display) to find any remaining public-API gaps, at the same depth as the earlier
printer supply-level work. Findings were split into "ready now", "needs specific hardware to
verify", and "no reliable public API" — the last group intentionally left out.

**Fixed:**
- **Network Monitor — roaming Wi-Fi never notified.** The dedup for Wi-Fi state changes compared
  only SSID, so moving between access points on the same network (same SSID, different BSSID)
  never fired anything. Now tracks the last-reported BSSID separately and reports a roam as its
  own event.

**Added (implemented and shipping):**
- **Network Monitor**: Ethernet link speed change (polled every 20s — no push event exists for
  this), DNS server changed, primary interface changed (Wi-Fi↔Ethernet).
- **Bluetooth Monitor**: signal strength (RSSI), shown as "Signal: -45 dBm (3/4)" with 5 icon
  levels matching Wi-Fi's own bar thresholds. Off by default (continuous BLE polling has a real
  power cost) — when off, only the plain connection is shown, no signal line.
- **Volume Monitor**: low free space warning (5% threshold, hysteresis to re-arm only above 15%),
  unsafe eject detection.
- **Power Monitor**: Low Power Mode and AC adapter change now have their own dedicated icons
  (previously reused the generic power icon) and live in the Icons tab like every other event.
- **USB Monitor**: power draw (mA required vs. available) and storage medium (HDD/SSD/Flash)
  display fields.
- **Camera Monitor**: max resolution shown on connect; Transport Type field's label now spells
  out every value it can show (USB, Bluetooth, Thunderbolt, AirPlay/Continuity, Built-in,
  Virtual) instead of assuming the reader already knows the FourCharCode mapping.
- **Gamepad Monitor**: DualSense Adaptive Triggers detection.
- **Audio Monitor**: sample rate change and volume-critical-level notifications, each with a
  dedicated icon and moved to the Icons tab (previously bare toggles in General).

**Added (implemented, pending hardware to verify — off by default where relevant):**
- **Camera Monitor**: Continuity Camera / Desk View companion detection (needs a paired iPhone),
  Center Stage active status (needs a Center Stage–capable camera).
- **Scanner Monitor**: automatic document feeder (ADF) state — jam/empty/cover open, via the
  eSCL `AdfState` field. Optional in the spec, so many devices may simply never report it.
- **Volume Monitor**: FileVault/encryption status field for mounted volumes, primarily useful
  for external disks.
- **Display Monitor**: documented (code comment, no behavior change) the expectation that
  Continuity Camera/Desk View should never surface here as a "display" — it enumerates as a
  capture device, not a `CGDirectDisplayID`.

**UI/philosophy corrections found and fixed while implementing the above:**
- A pre-existing Wi-Fi-only checkbox ("report Wi-Fi's own link/AWDL events") was living in the
  Ethernet tab; moved to the Wi-Fi tab where it actually applies.
- Every "Notify when X" toggle across Power, Camera, Audio, and Scanner Monitor now lives in the
  Icons tab with its own icon, consistent with how every other event-level toggle in this app
  works — General tab is reserved for field-visibility toggles on an existing notice, not for
  turning whole notifications on/off.

**Not implemented — no reliable public API found (audited, documented, deliberately left out):**
what app is using the camera, Bluetooth audio codec in use, audio clipping detection, display
HDR/Night Shift/True Tone/physical connection type, network captive-portal detection, Optimized
Battery Charging status, and Thunderbolt link speed (values observed identical across two
Macs with different controller generations, with no external accessory connected — not a
reliable signal, and `IOThunderboltFamily` has no public header to confirm the mapping).

## v1.15.1 — 2026-08-12

### Added: dedicated icons for Default Printer Changed and Print Job Started/Finished
- Both notifications used to reuse the "Connected" checkmark badge — each now has its own icon,
  designed with the user via mockup iterations and approved before implementing:
  - **Default Printer Changed**: the printer glyph's existing green badge circle, with the
    checkmark replaced by a rotating two-arrow "sync" symbol (same badge circle/outline as
    Connected — only the symbol inside it changed).
  - **Print Job Started/Finished**: crossed racing flags (one plain green, one checkered — the
    classic motorsport "start" and "finish" pairing) placed directly on the printer glyph's
    top-right corner, without a badge circle behind them.
- New assets: `PrinterMonitor-Icon-DefaultChanged` and `PrinterMonitor-Icon-JobStatus` in
  Assets.xcassets — both fully user-customizable (Custom/System/Reset) via their own Icons tab
  rows, same as every other notification icon in this monitor.

## v1.15.0 — 2026-08-12

### Added: Printer Monitor — toner/ink level notifications
- New opt-in notification, "Printer Supply Low", fires when a printer's toner/ink level drops
  to 10% or below (with hysteresis: only re-arms once the level recovers to 15%+, so a level
  hovering right at the threshold can't spam repeated notifications).
- Reads the standard IPP "Marker" attribute group (`marker-levels`/`marker-names`/
  `marker-colors`) via a direct `Get-Printer-Attributes` request — this is live printer state,
  not part of what `cupsGetDests()` already caches locally, so it needs its own IPP round-trip
  per printer. Polled far less often than the rest of this monitor (~every 30s instead of every
  3s) since, unlike the local-only CUPS calls this monitor already makes, this is a live
  round-trip to the physical printer for network/Bluetooth devices.
- Not all printers/drivers report this — many older or cheaper printers simply don't expose
  marker levels over IPP at all, in which case this feature silently never fires for that
  printer (not an error).
- Checkbox: "Notify when toner/ink is running low" (Preferences → Printer Monitor → Icons,
  next to its icon row — see the app-convention fix below), OFF by default like the other
  opt-in additions to this monitor.

### Improved: Printer Monitor — human-readable error reasons and richer job notifications
- "Printer Needs Attention" used to show the raw comma-separated IPP `printer-state-reasons`
  keywords verbatim (e.g. `media-empty-error,cover-open-warning`). Now translated to plain
  language ("Out of paper, Cover open") via a table of ~25 known keywords from RFC 8011 plus
  common vendor-neutral extensions, with a reasonable fallback (dash→space, capitalized) for
  anything not in the table.
- "Print Job Started" now includes the submitting user and job size in KB.
- "Print Job Finished" now includes the actual print duration.

### Fixed: new notification toggles were placed on the wrong tab
- The 4 new/changed "does this event notify at all" checkboxes (Needs Attention, Default
  Printer Changed, Print Job Started/Finished, Supply Low) were initially added to the
  "General" tab as a plain checkbox list. That breaks this app's own convention, followed by
  every other monitor: **General** configures *how* a notification behaves/looks (which
  fields it shows, thresholds, polling); **Icons** is where each distinct notification event
  gets its own row — icon + on/off toggle together, via the shared `HWGIconPickerView`.
  Moved all 4 into the Icons tab as their own rows (reusing the existing Connected/Disconnected
  icon slots, since no dedicated artwork exists yet for these events — same pattern "Needs
  Attention" already used). The 2 explanatory notes that don't fit the picker's fixed row
  format (the state-reasons heuristic, the ~30s supply-check interval) moved to a caption
  under the icon list instead of being dropped.

### Fixed: a scroll-view content view could anchor to the bottom instead of the top
- Found while adding the checkbox above: Printer Monitor's "General" tab content, when wrapped
  in an `NSScrollView` to avoid clipping against the Preferences window's fixed container size
  (same technique Network Monitor's Wi-Fi tab already uses), used a plain non-flipped `NSView`
  as the scroll view's document view. When the content is shorter than the visible viewport,
  a non-flipped document view anchors to the bottom, leaving a blank gap above the content and
  potentially clipping content at the very bottom. Fixed by using `HWGFlippedContentView`
  (already used elsewhere in this same file, for the Icons tab) instead of a plain `NSView`.

## v1.14.1 — 2026-08-11

### Housekeeping: pre-publish code audit
- Full clean-build audit before publishing v1.11.0–v1.14.0: zero compiler warnings across all
  13 plugin targets plus the main app (only build-system-level noise — `ONLY_ACTIVE_ARCH`/manual
  target order — no source-level warnings at all), zero orphaned source files (all 63 tracked
  `.m`/`.h` files confirmed referenced either in `project.pbxproj` or via `#import` + header
  search path), zero unused `#import`s (an automated heuristic flagged 19 candidates; every
  single one was manually verified as a false positive — e.g. `HWGIconOverrideStore.h` is used
  via its `HWGResolveIconNamed()` function, not a class matching the header's own name — so
  none were removed), zero `#if 0` blocks, zero real `TODO`/`FIXME` markers (the 5 matches found
  are just doc comments cross-referencing `TODO.md`, not broken/incomplete code).
- Found and fixed one genuine leftover: `PowerMonitor/HWGrowlPowerMonitor.m`'s battery
  time-remaining parser logged the unhelpful `NSLog(@"GAH")` when a `CFNumber` came back in an
  unexpected type — replaced with a real diagnostic message naming the actual type encountered.
  This file is flagged delicate (see TODO.md's P20 retain note) but the touched line has no
  interaction with that concern — it's a log-message-only change, no logic/memory behavior
  touched. Verified: clean build, 12/12 tests, all 13 plugins present, app runs without crashing.

## v1.14.0 — 2026-08-11

### Fixed: unplugging a USB-Ethernet adapter's hub never announced the disconnect
- Reported by the user: unplugging a USB hub with an Ethernet cable connected reported nothing
  at all, but plugging it back in reported a spurious "Ethernet Disconnected" followed shortly
  by "Ethernet Connected" — IP address updates were detected correctly the whole time.
- Root cause found by code inspection: `-isWiredEthernetInterface:` classifies a BSD name as
  real Ethernet by querying `SCNetworkInterfaceCopyAll()` live. Unplugging the hub tears the
  adapter out of that registry almost immediately — often before, or at the same instant as,
  its "Link" key changes — so the live re-query at disconnect time fails to classify it,
  `-handleLinkKeyChanged:` bails out early, and the real disconnect is silently dropped.
  `networkInterfaceStates` is left holding a stale "Active: 1" for that interface. On the NEXT
  reconnect, the first link read (while the adapter is still negotiating) reports inactive,
  which — compared against that stale "was active" baseline — fires a bogus "Ethernet
  Disconnected", followed shortly by the real "Ethernet Connected" once the link actually comes
  up: a real disconnect silently dropped, then a phantom disconnect+reconnect pair on the very
  next plug-in, exactly matching what was reported. IP updates were unaffected since they're
  driven by a completely separate mechanism (`getifaddrs()`, not this classification gate).
- Fixed by adding `ethernetClassificationCache`, remembering each BSD name's last successful
  live classification. A live lookup is still tried first every time (so a genuinely different
  device later reusing the same BSD name is still classified correctly); the cache is only
  consulted as a fallback once the interface has already vanished from the live registry, so a
  real disconnect is still recognized as the same (now-gone) Ethernet interface it always was.
- Verified live by the user with a real USB-Ethernet hub: disconnect now correctly fires
  "Network Link Down" with nothing else, and reconnect fires only "Network Link Up" — no more
  dropped disconnect, no more phantom disconnect+reconnect pair. Clean build, 12/12 tests, app
  runs without crashing.

## v1.13.0 — 2026-08-11

### Changed: unified the generic-device "connected" checkmark badge across all modules
- Bluetooth Monitor's generic (unrecognized-type) "Connected" icon has always shown a green
  circular checkmark badge overlaid on the base icon. Auditing every other module's own
  generic/single "Connected" icon found the same convention only partially applied: USB Monitor,
  Audio Monitor, Camera Monitor, Gamepad Monitor, and Display Monitor had no checkmark badge at
  all, while Printer Monitor had one but drawn as an inconsistent rounded SQUARE, and Thunderbolt
  Monitor had one at a slightly different size/position — no two modules matched.
- Extracted the exact green circle + white checkmark pixels from `Bluetooth-On.png` (isolated via
  color-based masking so no Bluetooth-icon-blue leaked into the cutout) and applied that identical
  badge, at the same position, to `USB-On`, `AudioMonitor-Icon`, `CameraMonitor-Icon`,
  `GamepadMonitor-Icon`, and `Display-On` (added, previously missing), and re-drew it onto
  `PrinterMonitor-Icon-Connected` and `Thunderbolt-On` (replacing their inconsistent badges) —
  7 assets updated, all now pixel-identical to Bluetooth's reference badge.
- Verified pixel-loss-free: confirmed via a before/after diff that Thunderbolt's lightning bolt
  artwork and Printer's outline weren't damaged when their old badges were removed (only the old
  badge's own green/white pixels were erased, not a blanket rectangle, after an initial attempt
  that DID clip 2754 bolt pixels was caught and corrected before this build).
- Deliberately out of scope: type-SPECIFIC icons (e.g. `BT-TypeMouse`, `USB-TypeScanner`) never
  had a checkmark and still don't — the badge marks "generic, type unidentified", not "connected"
  in general. Volume Monitor's own generic-mount fallback uses the system's own default disk icon
  (`NSWorkspace`), a different mechanism entirely — left untouched.
- Verified: clean build, 12/12 tests, all 13 plugins present, app launches and runs without
  crashing.

### Fixed: Thunderbolt's bolt tip didn't actually overlap the checkmark badge
- Spotted after the change above: on every other icon the badge visibly overlaps part of the
  base artwork (a natural "on top of" look), but Thunderbolt's lightning bolt tip stopped just
  short of the badge circle — a ~10-20px gap — reading as two separate floating shapes instead
  of one overlapping the other. Confirmed via git history that this gap existed even in the
  very first version of this icon that ever had a badge (v1.9.0), so it wasn't something this
  session's change introduced.
- Fixed by extending the bolt's tip with a small connecting patch (same yellow, continuing the
  bolt's existing edge angle) so it genuinely reaches into the badge's circle, then re-compositing
  the identical badge tile on top — the badge itself is untouched pixel-for-pixel. First attempt
  left a thin white seam where the patch met the original anti-aliased edge; fixed by extending
  the patch further into the bolt's solid body instead of just touching its boundary.
- **Follow-up #1 (same day)**: that first patch used a few sharp-angled polygon points, one of
  which sat too close to the badge circle's true radius (measured: only ~2px margin) — anti-
  aliasing pushed a small sliver of yellow past the circle's edge, visible as a stray spike
  poking out above the badge, plus a second angular point created a slight concave notch.
  Re-measured the badge's exact circle (center/radius from the actual badge tile, not an
  estimate) and redrew the connecting patch as a smooth two-bezier-curve shape with every point
  kept at least ~25px inside the true radius, plus a thick overlapping stroke along the seam
  line for guaranteed full coverage.
- **Follow-up #2 (same day)**: the two-bezier-curve patch still weren't quite right — the two
  curves met at their shared endpoint with DIFFERENT tangent directions, leaving a small concave
  notch right at that join (a thin white wedge visible cutting into the yellow, outside the
  badge's actual coverage). Replaced the curve approach entirely with a convex hull of 4 anchor
  points (two a few px inside the bolt's existing solid edges for guaranteed overlap, the true
  apex, and one point safely inside the badge circle) — a convex polygon cannot pinch into a
  concave notch by construction, and its straight edges also read as sharper/more angular,
  matching the rest of the bolt's geometric style better than a rounded curve would.
- **Correction (same day) — the whole approach above was wrong**: follow-ups #1–#3 all tried to
  fix this by *redrawing the bolt artwork* (extending its tip with hand-built patches) so it would
  reach the badge. That was the wrong premise: no other icon's base artwork is modified at all —
  the badge is simply composited on top of the complete symbol and naturally covers part of it.
  Measured how much base art the badge actually hides in each of the other icons: USB 11.1%,
  Display 14.9%, Camera 5.6%, Gamepad 6.9%, Audio 10.4% — versus **0%** for Thunderbolt, which is
  the real reason it read as two separate floating shapes rather than one overlapping the other.
  Root cause of the 0%: v1.9.0's icon redraw had shortened the bolt (tip moved from y=8 down to
  y=99, height 503px → 412px), leaving it too small and too low to ever reach the badge's corner.
  Fixed properly by discarding every hand-drawn patch, recovering the pristine bolt artwork
  (verified lossless — zero bolt pixels ever sat under the badge), and scaling/repositioning it
  **as-is** (1.15×, LANCZOS, no reshaping) so the badge covers 12.0% of it — squarely inside the
  5.6–14.9% range the other icons use. Validated: artwork fully inside the canvas, 0 unexpected-
  colour pixels (no resampling halos), bolt geometry unchanged apart from uniform scale.
- ~~Follow-up #3~~ (superseded by the correction above): the convex hull still left a tiny notch on the right side —
  measured the actual gap between the bolt's true edge and the badge circle's boundary at every
  row from the tip down to the blend zone, and found it is NOT constant (27px near the tip,
  shrinking to ~11px around the "shoulder", widening again below that) — a single straight hull
  edge cannot track a gap that curves non-linearly like that without either falling short (a
  notch) or overshooting (a bulge) somewhere along the way. Replaced the hull's right edge with
  a row-by-row fill driven directly by the real measured curve on both sides (the true bolt edge
  and the circle's own boundary equation) instead of any straight-line or bezier approximation —
  by construction, every single row is exactly flush with both curves, so no gap or notch is
  geometrically possible anywhere along the transition.

## v1.12.0 — 2026-08-11

### Added: launch notifications now group by module instead of interleaving
- Every module's `-fireOnLaunchNotes` used to run back-to-back in the very same synchronous
  pass, so one module's own family of related notifications (e.g. Network Monitor's Ethernet
  -> WiFi -> IP, which already fire in that order internally) landed interleaved with a
  completely unrelated module's burst arriving in the same instant (e.g. Volume Monitor
  mounting 7 volumes) — even with v1.11.2's queue fix guaranteeing nothing gets lost off-screen,
  the two families still visually interleaved, reading as scattered noise instead of "here's
  what your network did" as one grouped unit.
- `HWGrowlPluginController.fireOnLaunchNotes` now staggers each module's own call by a small
  fixed offset (0.6s × its position in the notifiers list) — giving each module's whole family
  a clear head start before the next module's burst begins, without touching any module's own
  internal sequencing.
- Verified live: Notification History timestamps now show clean per-module clusters (USB's 7
  notifications together at +0.0s, Power at +0.2s, Network's Ethernet at +0.25s, Volume's 8
  mounts together at +1.7s, Bluetooth at +2.1s, Network's own IP update at +2.3s — landing right
  after its own Ethernet announcement, exactly the grouped family behavior intended) instead of
  everything piling into the same ~40ms window as before.

## v1.11.2 — 2026-08-11

### Fixed: Ethernet (and other early-firing) launch notifications invisible under the launch flood
- After v1.11.1's fix made the Ethernet detection logic correct (confirmed present in
  Notification History), the user reported "still not detecting Ethernet" — investigated
  further and confirmed, live, this was a pure DISPLAY/visibility bug, not detection: every
  plugin fires its own "already connected"/"already mounted" notifications within the same
  ~40ms window at launch (measured: Power, Network Link Up, 7 Volume Monitor mounts, 6 USB
  devices — 15 notifications in 40ms). Both our own custom banner stack (`GrowlApplicationBridge.m`)
  and real macOS notification banners (already authorized on this Mac) stack newest-on-top, so
  anything fired that early gets buried under whatever arrives a few ms later.
- Found the deeper bug while investigating: `_pendingBannerReveals` (the queue meant to hold
  banners that can't fit on screen yet) has been dead code since the 05-ago-2026 eviction
  rework — something still *consumes* it (in the dismiss handler) but nothing has *produced*
  into it since. So a burst too fast for eviction to apply (every current banner younger than
  `kMinVisibleBeforeEvictable`) fell through and revealed the new banner anyway — positioned by
  `repositionBanners`' unbounded stacking math past the bottom of the screen (measured Y origins
  over 2000pt on a 956pt-tall screen), genuinely invisible for its whole 5s lifetime with zero
  chance of ever being seen.
- Restored the queue: when there's no room AND nothing is old enough to evict, the banner now
  queues instead of revealing off-screen; eviction still wins whenever it can, so a normal-sized
  burst still shows the newest notification instantly like before. Verified with a window-list
  probe (`CGWindowListCopyWindowInfo`, on-screen only): the visible custom-banner stack now
  holds a clean, non-overlapping set of exactly as many banners as fit the screen (8 on this
  display) with zero off-screen duplicates, cycling in the queued ones as each dismisses.
- Verified live with the real Ethernet adapter, isolated (all other plugins temporarily
  disabled to remove ambiguity): "Network Link Up — Interface: en5, Speed: 1000baseT, Mode:
  full-duplex" now correctly appears on screen. Restored normal plugin configuration afterward.

## v1.11.1 — 2026-08-11

### Fixed: Ethernet not announced at launch (already-connected cable never reported)
- Root cause confirmed: `-primeWiredLinkState` (detects an Ethernet cable that's already
  connected before launch) runs from Network Monitor's `-init`, which `HWGrowlPluginController`
  calls BEFORE it assigns `delegate` to the plugin (`init` happens, THEN `setDelegate:` — see
  `-loadPlugins`). So `[delegate onLaunchEnabled]` was always messaging `nil` at that point,
  silently returning NO regardless of the user's real "Show existing on launch" preference —
  and since nothing ever re-read the state stashed there, the announcement was permanently lost.
  Same category of bug as the WiFi/IP launch-timing fixes (v1.10.2/v1.10.6/v1.10.8), but a
  different root cause (delegate-not-set-yet vs. CoreWLAN/DHCP warm-up).
- Split the responsibility: `-primeWiredLinkState` now only records the dedup baseline (still
  called early, safely, since it no longer needs `delegate`); a new `-fireExistingWiredEthernetIfEnabled`
  makes the real announce decision once `delegate` is guaranteed to be set, called from
  `-fireOnLaunchNotes`. It clears the primed baseline first so `-updateLinkWithInterface:`'s
  dedup doesn't see the just-recorded state as "no change" and swallow the announcement again.
- Verified live (own Ethernet adapter, `en5`, USB 10/100/1000 LAN): "Network Link Up" (Interface:
  en5, Speed: 1000baseT, Mode: full-duplex) now correctly appears in Notification History on 2
  consecutive clean relaunches — never appeared before this fix. `ShowExisting` (the "Show
  existing on launch" preference this depends on) defaults to YES for all users.

### Changed: Icon Picker labels clarify the generic-fallback row (Bluetooth/USB/Thunderbolt)
- The single "Disconnected" row (Bluetooth/USB/Thunderbolt Icons tab) now reads "Disconnected
  (generic)" — clarifying that it's the fallback used only for unrecognized device classes,
  since v1.11.0 gave every other type its own dedicated "-Disconnected" icon. No functional
  change, just disambiguation (matches the existing "Connected (generic)" row's naming).

## v1.11.0 — 2026-08-11

### Added: dedicated type-specific "Disconnected" icons (Bluetooth/USB/Thunderbolt)
- Previously, connecting a typed device (e.g. a Bluetooth mouse, a USB webcam, a Thunderbolt
  dock) showed its specific icon, but disconnecting the same device always fell back to the
  plain generic icon (`Bluetooth-Off`/`USB-Off`/`Thunderbolt-Off`) — the type information was
  simply dropped on the disconnect path. Added 32 new `-Disconnected` icon variants (12
  Bluetooth types, 9 Thunderbolt types, 11 USB types), generated by overlaying the same
  standardized red X already used for Volume Monitor's "Unmounted" states onto each existing
  type icon, so disconnect notifications now show the correct device-specific icon with an X
  instead of losing that detail.
- **Bluetooth**: `deviceClassMajor`/`deviceClassMinor` (the source of the type icon) come from
  the paired device's cached class-of-device record, not a live-connection-only property, so
  they're still safely readable at disconnect — confirmed correct, no caching needed.
- **Thunderbolt**: registry properties (including the PCI class-code the type icon is based on)
  are frequently unreadable from an already-terminating registry entry by the time the removal
  callback fires (this is a real, previously-documented IOKit limitation, not something fixed
  here). Solved without touching that constraint: the icon name is now cached by device name at
  connect time and looked up (then cleared) at disconnect, instead of re-reading the dying
  registry entry.
- **USB**: `bDeviceClass` turned out to already be safely readable at disconnect in the existing
  code (it's what `isHub` was already computed from on that path) — reused that same read for
  the type icon lookup instead of assuming it was unreadable like Thunderbolt's case.
  "Device-USBDrive" (Mass Storage) reuses its existing "-Unmounted" variant from Volume Monitor
  rather than a redundant new asset.
- Verified: clean build, 12/12 automated tests passing, all 13 plugins present, app launches
  and runs stably (no crash) with the properly-signed identity from v1.10.8/v1.10.9.

## v1.10.9 — 2026-08-10

### Fixed: Bluetooth connect/disconnect detection re-enabled — same root cause as v1.10.8
- The Bluetooth TCC crash disabled in v1.10.6 turned out to be caused by the exact same
  bad ad-hoc signature fixed in v1.10.8 (wrong code-signing Identifier + unbound Info.plist)
  — NOT something that required a paid Apple Developer Program membership. An earlier test
  during the investigation only had Info.plist bound but still had the Identifier mismatch,
  which is why it still crashed and looked like this needed a real (paid) Developer ID.
- Re-enabled `BluetoothMonitor`'s `IOBluetoothDevice registerForConnectNotifications:` call.
  Verified with a full purge (app + prefs + notification history + Microphone/Bluetooth TCC
  reset) and 5 consecutive clean relaunches — zero crashes, matching v1.10.8's fix.
- Bluetooth connect/disconnect detection and Apple accessory battery reporting (F36:
  AirPods/Magic Mouse/Keyboard/Trackpad) are both back to fully working — the ad-hoc,
  free, no-Developer-ID-needed signature fix from v1.10.8 was sufficient on its own.

## v1.10.8 — 2026-08-10

### Fixed: microphone permission never actually persisting between launches
- Found the real root cause of "asks for microphone access every single launch": Xcode's
  default build produces a lightweight "linker-signed" ad-hoc signature that does NOT bind
  Info.plist into the code signature, and can leave the code-signing Identifier as the raw
  executable name (`HG4MAC`) instead of the real bundle identifier (`com.jensyleo.hg4mac`).
  TCC's per-launch authorization check relies on this identity — with it wrong/unbound, a
  granted permission never reliably re-associated with the app on the next launch.
- Added a build phase that re-signs the built app (`codesign --force --deep --sign -` —
  still fully ad-hoc, no Developer ID or Apple ID needed) after Xcode's own build, and
  disabled the separate "Strip" post-processing step for this target (it was invalidating
  the corrected signature right after). Confirmed: identifier now correctly reads
  `com.jensyleo.hg4mac`, Info.plist shows as bound (`entries=35` instead of "not bound").
- Verified with a full purge (app + prefs + notification history + TCC reset) and 5
  consecutive clean relaunches — zero re-prompts, versus every single launch before this fix.

## v1.10.7 — 2026-08-10

### Restored: automated test target (dropped during today's investigation)
- The `HardwareGrowlerTests` target (12 tests) and the `HWGWifiSignal` extraction from
  v1.10.4 got dropped during the Bluetooth-crash investigation above (several `git reset
  --hard` steps while bisecting). Recreated on top of v1.10.6's fixes — same 12 tests,
  same standalone (no host application) setup. Verified: `xcodebuild test` passes 12/12.

## v1.10.6 — 2026-08-10

### Fixed: app crashing on launch on macOS Tahoe 26.x, breaking Network Monitor's launch announcements
- Confirmed (with a from-scratch minimal test app, zero HardwareGrowler code) that on the
  current macOS Tahoe 26.x, an ad-hoc-signed app calling Bluetooth's connect-notification API
  (`IOBluetoothDevice registerForConnectNotifications:` — Bluetooth Monitor's own connect/
  disconnect detection) gets the whole process aborted by the OS with a TCC privacy-violation
  crash, falsely claiming `NSBluetoothAlwaysUsageDescription` is missing from Info.plist even
  though it's present. Confirmed NOT present on macOS Ventura 13.7.8. Since this ran early in
  launch (`HWGrowlPluginController`'s `postRegistrationInit`), the process died before Network
  Monitor's own launch announcements (Wi-Fi/IP) ever got a chance to run.
- Bluetooth connect/disconnect detection is disabled for now (Bluetooth Monitor's other
  features are unaffected) until this can be re-enabled with a stable, Apple-issued signing
  identity — ad-hoc signing appears to be the actual trigger, not anything specific to this
  codebase (verified against the unmodified v1.10.0 codebase and against the HG4MAC-INTEL
  fork, both of which hit the exact same crash under the same conditions).
- Also reordered `HWGrowlPluginController`'s init so launch announcements (Wi-Fi/IP) run
  BEFORE Bluetooth's registration, so they're never at the mercy of what runs after them again
  in the future.
- Fixed a real display-order bug found along the way: Wi-Fi's launch announcement always
  waits ~1.5s (CoreWLAN warm-up), but IP's used to fire synchronously and instantly — so
  "IP Addresses Updated" could appear before "AirPort Connected", backwards from a sensible
  reading order. IP's initial check now goes through the same delayed-poll path, so Wi-Fi's
  announcement reliably lands first.
- Fixed a banner-eviction bug: the on-launch notification flood (volume mounts, USB, etc.)
  could evict a just-revealed banner (confirmed via diagnostic logging: Network Monitor's "IP
  Addresses Updated") within a fraction of a second of it appearing — technically shown
  (`panel.isVisible == YES`) but never actually visible to a human. Eviction now requires a
  banner to have been visible for at least ~4.5s (near its full 5s lifetime) before it's a
  candidate — the stack can temporarily overflow during a big flood instead of cutting a
  fresh banner short.
- Removed a redundant `CBCentralManager` in `AppDelegate.requestAllPermissions` that only
  existed to trigger the Bluetooth permission dialog — Bluetooth Monitor's own registration
  already does this on its own, and having both running was part of what made the crash above
  more reliably reproducible.

## v1.10.3 — 2026-08-06

### Improved: camera "in use" notification responsiveness
- v1.10.2's debounce for the camera "Started/Stopped Being Used" notifications (to prevent
  CoreMediaIO flicker artifacts during video call setup) applied a blanket 1-second delay to
  all notifications, making even the "Started" signal feel laggy — confirmed by user feedback.
  The flicker only happens on "Stopped" (the camera briefly reports "off" then "on" again),
  so redesigned the debounce to be asymmetric: "Started" fires instantly (no delay), while
  each "Stopped" gets its own 1-second settle check that cancels if the camera shows running
  again before it fires. This restores pre-fix responsiveness for the privacy-relevant
  "Started" signal while still suppressing spurious "Stopped" from the CMIO burst.

## v1.10.2 — 2026-08-06

### Fixed: Wi-Fi not announced at launch
- Network Monitor's "already connected" Wi-Fi announcement at launch was querying
  `CWWiFiClient` synchronously in the same run-loop tick as app startup. CoreWLAN's XPC
  connection to the system Wi-Fi daemon isn't always warm that early, so the read could
  come back as "not associated" even when Wi-Fi was already connected — and since no
  CoreWLAN change event ever fires for a connection that was already up before launch,
  that false read meant Wi-Fi silently never got announced for the rest of the session.
  Now delayed by 1.5s with one retry, matching the wait-and-recheck pattern already used
  elsewhere in this file for late-arriving IPv4 addresses.
- Audited the other two modules that also announce state at launch (Power Monitor,
  Volume Monitor): both read from sources with no comparable daemon warm-up (IOKit power
  sources, NSFileManager's mounted-volume list) and aren't affected by this class of bug.

## v1.10.1 — 2026-08-06

### Internal: dead code removal (no functional change)
- Removed `Growl.framework` and `GNTPClientService` as build dependencies of the app
  target — both compiled on every build but were never embedded or linked into the app
  (empty "Copy Frameworks" phase, no XPC copy phase, zero runtime references). The app's
  actual notification delivery has used its own `GrowlApplicationBridge` copy since
  earlier in this fork.
- Removed the entire `Growl.xcodeproj` cross-project reference, along with `Framework/`,
  `XPC/`, `Plugins/`, `GrowlLauncher/`, and `Unit tests/` — none of it was reachable from
  the app's build graph.
- Pruned `Core/Source/` and `Common/Source/` down to only the handful of legacy files the
  app actually compiles or imports (traced by following the real `#import` chain), removing
  168 unused files left over from the original Growl preferences UI, ticket database, and
  GNTP forwarder/subscription code.
- Verified with a full clean build after each step; the resulting `.app` bundle is
  byte-identical to the pre-cleanup build.

## v1.10.0 — 2026-08-05

### Added: scan job start/finish notifications (experimental)
- Scanner Monitor can now notify when a network scanner starts and finishes a scan job, by
  polling the device's eSCL (AirScan) status endpoint — checkbox "Notify when a scan
  starts/finishes (experimental)", **off by default**. This has not yet been verified against
  a real network scanner: eSCL firmware compliance is known to vary by manufacturer, and some
  devices may only surface job completion via a separate per-job resource rather than the
  general status endpoint this polls.

## v1.9.9 — 2026-08-05

### Added: IP address old → new + more "old → new" toggles
- Network Monitor's "IP Addresses Updated" notification now shows the previous address next
  to the new one per interface (e.g. "en0 — IPv4: 192.168.1.5/24 → 192.168.1.12/24") instead
  of only the current value — tracked per interface, so only the interface that actually
  changed shows an arrow when there are several (e.g. a USB-Ethernet dock alongside Wi-Fi).
  New checkbox "Show old → new address when it changes", on by default.
- Added the same optional "old → new" toggle, matching Display Monitor's existing per-field
  pattern, to two other places that already showed this but couldn't be turned off
  independently: Power Monitor's power-source-changed line, and Audio Monitor's
  default-device-changed line. Both on by default.
- Deliberately NOT added to Thermal Monitor or Printer Monitor's "default printer changed" —
  in both, the old → new line IS the entire content of the notification; a toggle to hide it
  would only ever produce an empty, pointless notification.

## v1.9.8 — 2026-08-05

### Removed: "URL" icon download button
- The icon customization picker (14 monitors) no longer offers downloading an icon from a
  pasted image URL. "Custom" (local file) and "System" (macOS's own icon set) remain — icon
  customization is now local-file-only, with no network path in the icon picker at all.

## v1.9.7 — 2026-08-05

### Fixed: modern high-capacity flash drives misclassified as external disks
- Volume Monitor's device-type icon guess checked the 400GB size threshold before checking
  for explicit "flash"/"thumb"/"usb drive" naming tokens, so a real, modern pendrive (1TB+
  flash drives are common products now — SanDisk Extreme, Kingston, etc.) that explicitly
  identifies itself as a flash drive got classified as an external disk anyway, purely by
  size. Explicit naming now takes priority — the size threshold only applies as a last
  resort for large, anonymously-named storage with no identifying token at all.

### Fixed: contradictory microphone notifications around MS Teams calls
- Starting or ending a Teams call reliably produced 3 rapid, real "Microphone
  Started/Stopped Being Used" notifications within under a second — e.g. Stopped → Started →
  Stopped when the user just STARTED a call, ending on the visually wrong state (looked like
  the mic ended up unused right as the call began). Confirmed live (user screenshots) and
  independently with a standalone diagnostic tool built during this investigation: macOS
  genuinely reports these as 3 distinct `kAudioDevicePropertyDeviceIsRunningSomewhere`
  transitions — this is Teams' own audio session briefly cycling its input capture during
  call setup/teardown, not the user touching the microphone multiple times, and not a
  coalescing bug on this app's side.
- Notifying every one of those raw transitions was individually accurate but produced a
  confusing, self-contradicting sequence of banners. Fixed with a 1-second debounce: after
  any mic state change, wait 1s for the state to settle (canceling and restarting the wait if
  another change arrives first), then notify only the net difference between the last
  state actually announced and the state that stuck. A burst that returns to its starting
  state (e.g. off → on → off within the window) now correctly produces no notification at
  all, since nothing really changed from the user's perspective. A single, isolated toggle
  still notifies exactly as before — the 1s wait only ever matters when a second change
  arrives inside that window.

## v1.9.6 — 2026-08-05

### Added: USB Mass Storage device icon
- USB Monitor's device-type classification already labeled Mass Storage devices (flash
  drives, external HDDs, USB card readers) correctly in text, but had no icon for the class —
  it fell back to the generic connected icon. Now uses the same drive icon Volume Monitor
  already shows for these devices.
- Full audit of connect-time icon coverage across Bluetooth/Thunderbolt/USB's device-type
  classifiers: Thunderbolt and Bluetooth found to already have complete, correct coverage for
  every class with an unambiguous real-world meaning — no further gaps.

## v1.9.5 — 2026-08-05

### Fixed: 5 plugin bundles never received the app's version number
- Camera, Audio, Printer, Scanner, and Gamepad Monitor's Xcode build configurations were
  never linked to the shared xcconfig chain that defines the version number, so their
  bundles' own `CFBundleShortVersionString`/`CFBundleVersion` silently stayed hardcoded at
  "1.0"/"1" through every release regardless of the app's actual version. Also the direct
  cause of v1.9.4's own version string drifting at 1.8.0 since v1.9.0 — three prior releases
  (v1.9.1-v1.9.3) shipped without noticing the visible version hadn't moved.

## v1.9.4 — 2026-08-05

### Fixed: Camera/Microphone "in use" notifications getting silently suppressed
- Started/Stopped notifications for the same camera or microphone used to share one
  notification identifier, so macOS silently replaced the still-visible banner instead of
  showing a new one — "Stopped" wouldn't appear until "Started" had already cleared on
  screen. Each transition now gets its own identifier.
- That same identifier was also being treated as a duplicate by the 3-second anti-spam
  cache when toggling quickly, silently dropping every other transition. These in-use
  state transitions are now exempt from that cache — they're already real, distinct
  events, never accidental repeats.
- The existing "device is unstable" bounce alert (for hardware flapping on/off repeatedly)
  used to only count Started or Stopped events separately after the identifier change
  above, needing 4 of the same direction to trigger instead of 4 toggles total. Fixed to
  count both directions together again.

### Fixed: notification banners waiting to appear when the screen was full
- When the on-screen notification stack was full (most commonly right after launch, when
  every module announces its current state at once), a new notification used to queue and
  wait for an existing banner's full 5-second lifetime to end before appearing — visible as
  "nothing shows up until the last one disappears." The newest notification now evicts the
  oldest visible one immediately instead of waiting.

### Added: cap on Notification History size
- The optional Notification History list (off by default) was only pruned by age
  (1-30 days), with no ceiling on entry count. Camera/Microphone "in use" notifications can
  fire far more often per day than the connect/disconnect events this feature was designed
  around. Capped at 500 entries, trimmed automatically as new ones are added.

### Improved: memory/performance audit
- Notification icons (Camera, Microphone, Thermal) are now TIFF-cached per icon name instead
  of being re-rendered from scratch on every single notification — previously harmless at
  connect/disconnect frequency, but now more relevant given Camera/Microphone's higher-frequency
  "in use" notifications.
- Power Monitor's two repeating timers (auto-refire, battery health check) switched from
  `target:self` to weak-self blocks, removing an unnecessary retain cycle (matches the
  pattern Display Monitor already used) — not an active leak today since plugins live for
  the app's whole run, but now consistent and safe if plugin teardown is ever added.
- Full audit of every monitor's IOKit/CoreAudio/CoreMediaIO listeners, timers, and caches
  found no other leaks — all other listener registrations, timers, and caches were already
  correctly paired/pruned.

## v1.9.3 — 2026-08-05

### Fixed: print job notifications never fired
- The "Notify when a print job starts/finishes" feature (added in v1.9.2) had its polling
  code accidentally nested inside the unrelated "default printer changed" checkbox's `if`
  block, so it never ran regardless of its own checkbox state. Confirmed fixed against a real
  local test print queue — Started, Finished, and Canceled all fire correctly now.

## v1.9.2 — 2026-08-04

### New: USB device speed in notifications
- USB Monitor's "Speed" field (behind the existing "USB speed / generation" checkbox) now
  covers USB 3.2 Gen 2x2 (20 Gb/s) — the one connection speed code that was previously falling
  through to no label.

### New: Bluetooth accessory battery level (Apple devices)
- Bluetooth Monitor can now show the battery level of Apple accessories (AirPods, Magic
  Mouse/Keyboard/Trackpad) in the connect notification — checkbox "Battery level (Apple
  accessories)", on by default.
- Reads two different sources depending on device type: AirPods/Beats-style devices report
  through undocumented `IOBluetoothDevice` selectors; Magic Mouse/Keyboard/Trackpad instead
  report through a separate IOKit registry node, matched by Bluetooth address. Both paths are
  combined so the feature works across all of these devices without the user needing to know
  which one applies.

### New: internal drive health percentage
- Volume Monitor can now show a real health percentage for internal disks when they mount —
  checkbox "Drive health % (internal disks)", on by default. Uses Apple's public NVMe SMART
  interface to read the drive's actual wear-level log page (not a synthesized estimate).
  Scoped to internal storage only.

### New: print job start/finish notifications
- Printer Monitor can now notify when a print job starts and when it finishes or is canceled —
  checkbox "Notify when a print job starts/finishes", off by default. Polls the same interval
  already used for printer list changes, so there's no additional background overhead.

### New: microphone-in-use notifications
- Audio Monitor can now notify when any connected microphone starts or stops being actively
  used by any app — checkbox "Notify when a microphone starts/stops being used", on by
  default. Requests Microphone access the first time this is enabled (used only to observe
  activity state — no audio is ever captured, recorded, or transmitted).

### Fixed: VPN notification icon
- VPN connect/disconnect notifications now use a dedicated shield icon instead of the generic
  network icon.

### Fixed: History panel could lag behind real notifications
- The notification History list (Preferences → History) previously only refreshed when
  switching to that tab — a notification firing while a different tab was showing (or the
  window closed) wouldn't appear in the list until the next time History was opened, however
  many events had piled up by then. It now refreshes live while the History tab is visible.

### Fixed: Printer Monitor's background polling could silently do nothing
- Enabling only one of the printer-error/default-changed/job-status checkboxes (without also
  enabling the original connect/disconnect notification) previously never started the polling
  timer those features depend on, so they'd do nothing. Any one of these checkboxes now starts
  it correctly.

## v1.8.0 — 2026-07-29

### New: Scanner Monitor (13th monitor) — network scanner detection
- Detects scanners/MFPs advertising themselves on the local network via Bonjour
  (`_scanner._tcp`/`_uscan._tcp`, eSCL/AirScan), posting a notification when one appears or
  disappears on the LAN.
- **Off by default.** This is the first feature in the app to request macOS's Local Network
  permission — nothing runs (no Bonjour browsing, no permission prompt) until the user
  explicitly enables "Enable network scanner detection" in Preferences → Scanner Monitor.

### Icon fixes and completeness pass
- New `USB-TypeScanner` icon, wired into USB Monitor's device-class classifier (USB scanners
  were previously falling back to the generic USB icon).
- Volume Monitor's Optical and NAS device icons now have "Unmounted"/"Critical" variants,
  matching the External Disk/SD Card/USB Drive icons (same reused red-X/radioactive-badge
  overlay, not new artwork).
- Network Monitor's Icons tab was missing a row for the icon used when a non-Ethernet,
  non-Wi-Fi interface connects/disconnects (e.g. a phone's USB network interface) — added.

### Improved: Uninstall now offers to reset system permissions
- The confirmation dialog has a new checkbox (on by default) to also reset the Bluetooth,
  Location, and Local Network authorizations macOS has recorded for this app — see
  [Uninstall](#uninstall) below for details and a known OS-level caveat.

## 2026-07-27

### New: notification history (Preferences → History)
- A new "History" tab (alongside General/Modules) optionally keeps a record of
  notifications the app fires, **off by default**.
- Configurable retention window, 1–30 days (slider), pruned automatically.
- Per-module opt-in: the module checklist lists every monitor, active or not (inactive
  ones shown disabled/unchecked, since a disabled monitor never fires anything to record
  anyway). Turning a monitor off (manually, or via the Minimal/All performance preset)
  automatically clears its history checkbox if it was on.
- Three bulk actions above the module list: **Select All**, **Select None**, and
  **Select Active Modules** (checks only monitors currently enabled, unchecks the rest —
  a one-click reset to the sensible default).
- "Clear History…" permanently deletes every saved entry, with a confirmation prompt.
- Recording happens at the single choke point all notifications already pass through
  (`HWGrowlPluginController`'s `notifyWithName:...`), so history only ever reflects what
  the user actually saw — after disabled-module and duplicate-suppression checks, not
  before.
- Storage: a plain JSON file in Application Support (no Core Data/SQLite — entry volume
  is low, consistent with how the rest of the app avoids a database dependency), written
  from a private serial queue for thread safety.
- **New files**: `HardwareGrowler/HWGNotificationHistoryStore.h/.m`.

### Fix: Printer Monitor misreported normal network printing as a device problem
- `printer-state-reasons` (the IPP-standard field this app already reads for the optional
  "notify when a printer needs attention" toggle) carries a severity suffix per the IPP
  spec (RFC 8011 §5.4.12): `-error` (blocks printing), `-warning` (degraded), or no suffix
  at all (purely informational). The problem-detection check here treated ANY reason
  other than the literal `none` as a problem — including plain informational keywords.
- Confirmed live printing over Wi-Fi: printers report `connecting-to-device` (no
  suffix — just "opening the connection to send the job", a normal part of network
  printing) while a job starts. The old check fired a false "Printer Needs Attention" for
  this, then a false "Printer OK" once the job finished and the reason cleared — both
  about an entirely normal print, not an actual fault.
- Fixed to only treat `-error`/`-warning`-suffixed reasons as a real problem, matching
  what the surrounding code comment already claimed to do.

## 2026-07-24

### Fix: notification banners silently lost during a burst at launch
- **Root cause #1**: the notification-routing layer (`GrowlApplicationBridge`) decides
  whether to use the system Notification Center or its own built-in banner via a flag that
  starts `NO` and is only corrected asynchronously, once authorization with the system
  notification daemon round-trips — which can take a perceptible moment amid the IOKit/
  Bluetooth/CoreWLAN setup happening at launch. Any notification fired before that
  resolves tried the system path first, which always fails for this ad-hoc/linker-signed
  build (see "Notifications & code signing" below), and only fell back to the built-in
  banner after a SECOND async round-trip — one that may not resolve before the app moves
  on, silently dropping the notification. Fixed by defaulting to the built-in banner
  immediately and only switching to the system Notification Center once real permission is
  confirmed granted.
- **Root cause #2**: the banner stack has no on-screen height limit — each new banner
  is placed strictly below the previous one with no cap or overflow handling. On a Mac
  with several APFS system volumes, Volume Monitor's launch report of all of them (by
  design — see below) could produce enough banners to push older, still-pending ones
  (Power Monitor's battery/AC status, USB) past the bottom of the screen: invisible for
  their whole 5 s lifetime, even though they fired correctly. Fixed with a small queue —
  a banner that would overflow the screen waits until room frees up (another banner
  dismissing) instead of being silently lost off-screen; its 5 s auto-dismiss timer only
  starts once it's actually shown, so queued banners still get their full visible time.
- Confirmed live: Bluetooth Monitor's own detection of a keyboard/mouse already connected
  at launch was investigated as part of this and found to be present since the pre-existing
  `registerForConnectNotifications:` call already reports state at registration time, not
  just future events — the earlier assumption that it didn't was incorrect. Its disconnect
  notification is now also registered unconditionally (regardless of whether the "notify on
  launch" preference is on), and the already-connected-at-launch notification itself is
  deferred ~2 s past registration so the banner infrastructure above has time to finish
  initializing before it's posted.

### New: four new monitors — Audio, Camera, Gamepad, Printer
- **Audio Monitor**: reports default output/input device changes (old device → new device,
  with transport/channel count/sample rate when enabled) and device connect/disconnect,
  filtered by transport so a Bluetooth speaker doesn't also fire a redundant "Audio Device
  Connected" on top of Bluetooth Monitor's own notice. Verified live with a real Bluetooth
  speaker (VTA-82891) for both output and input, and with a real AV receiver over
  HDMI/optical. Icon is currently a temporary vector drawing in code (speaker + sound
  waves, orange) rather than a designed PNG — replacing it with a hand-designed asset
  (same pipeline as Power/Thermal/Thunderbolt/Volume Monitor) remains open.
- **Camera Monitor**: reports camera connect/disconnect and "started/stopped being used",
  filtered by transport the same way as Audio. Two real crashes were found and fixed during
  testing with a USB webcam:
  - The "in use" CMIO listener was only registered once at launch, against the devices that
    existed at that moment — a camera plugged in AFTER launch never got a listener, so
    "USB camera started being used" silently never fired even though the checkbox was on.
    Fixed with a listener over the CMIO device list itself that re-registers automatically
    whenever a device appears/disappears.
  - Unplugging the USB camera then crashed the app with `SIGSEGV` inside
    `CMIOObjectRemovePropertyListenerBlock`, called from `unregisterInUseListeners`, itself
    called from INSIDE CoreMediaIO's own device-list-changed callback — an unsafe reentrant
    call into the framework at the exact moment the removed camera's `CMIODeviceID` becomes
    invalid. A second, related crash then showed up on CONNECT too (with Preferences open),
    ruling out reentrancy as the sole cause: the real root cause was
    `inUseListenerBlock`/`deviceListChangedBlock` being declared `@property (nonatomic,
    assign)` instead of `copy` — with `assign`, ARC never copies the block to the heap, so
    the property pointed at already-freed stack memory as soon as `-init` returned; any
    later use (adding/removing the listener) read invalid memory, crashing unpredictably on
    either a connect or a disconnect event. Fixed by (1) deferring the re-registration work
    with `dispatch_async` to leave the CMIO callback's stack before touching listeners, and
    (2) switching both block properties to `copy`. Re-tested with Preferences both open and
    closed after both fixes — no crash on either connect or disconnect.
  - Icon (camera + lens, Bluetooth blue) confirmed visually; flagged as a
    candidate for more color variety, not yet redesigned.
- **Gamepad Monitor**: reports game-controller connect/disconnect via `GCController`. A real
  bug was found and fixed: connecting a controller only ever produced the generic
  USB/Bluetooth notice, never "Game Controller Connected" — nothing was calling
  `[GCController startWirelessControllerDiscoveryWithCompletionHandler:]`, without which
  GameController doesn't route connection events to a menu/background-only app (even for
  wired controllers, in practice). Fixed by calling it in `-init` (nil handler, runs for the
  plugin's whole lifetime) and `stopWirelessControllerDiscovery` in `-dealloc`. After that
  fix, testing with the only controller available (a generic/third-party pad) still didn't
  produce "Game Controller Connected" — confirmed as a real, documented **limitation, not a
  bug**: `GCController` only recognizes devices implementing the HID "Extended Gamepad"
  profile (official PS4/PS5/Xbox/MFi controllers); a generic pad works as a normal HID/USB
  device (which is why USB Monitor still sees it) but the system never exposes it as a
  `GCController`, regardless of app code. Testing the Type/Player/Battery fields and the
  disconnect notice is closed pending access to an official controller.
- **Printer Monitor** (one of twelve monitor plugins): reports printer connect/disconnect
  via CUPS, polling every 3s (down from an initial 15s). A real bug was found and fixed
  during live testing with a Bonjour printer: `[NSPrinter printerNames]` always returned
  empty in this app even though `lpstat`/CUPS could see the printer — replaced with
  `cupsGetDests()`, the real API `lpstat` itself uses. An instant file-watch mechanism over
  `/etc/cups/printers.conf` (via kqueue) was attempted and then reverted: that file is mode
  600, owned `root:_lp`, and this app will never read it without privileges it shouldn't
  request — documented in README. Icon redesigned from a supplied reference image,
  adapted to the app's color language and enlarged ~22%.
  - Three additional, independently toggleable features were added, all **off by default**
    and still pending live testing: (1) error/attention-state notification via the
    IPP-standard `printer-state-reasons` transition (out of paper, jammed, offline); (2)
    "default printer changed" notification; (3) extra fields (Location / Make-model /
    Connection type) on the existing "Printer Connected" notice.

### New: candidate monitor extensions — Low Power Mode, eGPU, VPN detection
- **Power Monitor**: new, off-by-default "Notify when Low Power Mode is turned on/off"
  notification, driven by `NSProcessInfoPowerStateDidChangeNotification` plus a
  last-known-state comparison (the notification can also fire from a shared underlying
  mechanism on thermal-state changes on some OS versions, so the raw notification alone
  isn't trusted). Verified live and confirmed working.
- **Thunderbolt Monitor**: new, off-by-default "Notify separately when an eGPU is connected"
  checkbox. Detects a hot-plugged PCI "Display Controller" function (class-code base 0x03)
  — in practice, an external GPU attached via Thunderbolt, since internal Apple Silicon GPUs
  never enumerate as a post-launch `IOPCIDevice` add/remove. Documented in README that
  DISCONNECT will often be silently missed: registry properties are frequently unreadable
  from a terminating IOKit entry by the time the removal callback fires, the same limitation
  the generic Thunderbolt removal notice already has. Still pending a live test with a real
  eGPU (none available in this environment).
- **Network Monitor**: new, off-by-default "Notify when a VPN connects/disconnects",
  in its own dedicated "VPN" tab (split out of the previously-reserved "Other" tab, which
  stays empty for future use). Detection is a heuristic: BSD interface names with a
  `utun`/`ppp`/`ipsec` prefix that gain/lose a real IP address are treated as a VPN
  connect/disconnect transition. `utun` in particular is also used by some non-VPN system
  features (Content Filter / Network Extension), so a false positive is possible in
  principle — documented in README. Live testing with a real VPN connect/disconnect is in
  progress.

### New: Performance preset (Modules → Minimal / All / Custom)
- Added a 3-way preset control at the top of the Modules tab (moved there from General,
  compressing the monitor table/detail pane to make room) to address concern about running
  all twelve monitors at once: **Minimal** enables only Volume/USB/Thunderbolt/Bluetooth/
  Power/Network; **All** re-enables every monitor; **Custom** leaves the current selection
  untouched. Selecting a monitor's checkbox directly in the Modules table, or any setting
  INSIDE an individual monitor's own preferences pane, automatically flips the radio to
  "Custom" — the latter is detected by diffing `NSUserDefaults` snapshots via
  `NSUserDefaultsDidChangeNotification`, since the plugins have no shared "a setting
  changed" callback into `AppDelegate`. A bug where "Custom" silently lost its own
  configuration when switching away to Minimal/All and back was found and fixed by
  capturing a snapshot at the moment Custom is left. All scenarios (visual placement,
  Minimal/All/Custom switching, both auto-switch-to-Custom paths, Custom-state
  preservation, internal checkboxes never being touched by the preset) confirmed live.

### New: device-specific icons for Volume Monitor (SD card / USB drive / external disk)
- Added `Device-SDCard`, `Device-USBDrive`, `Device-ExternalDisk` (plus `-Critical` and
  `-Unmounted` variants for each, using the same red-X overlay as the existing generic
  eject icon) and wired them into Volume Monitor via a new heuristic classifier,
  `HWGDeviceCategoryFromInfo`, that reads Disk Arbitration's protocol/media-name/model/size
  and falls back to the existing generic mount/eject/"Disk Not Readable" icons whenever the
  signal isn't strong enough to make a confident call — it never forces a guess.
- Several real bugs were found and fixed during live testing with a real pendrive
  (Kingston "DT 100 G2") and a real external hard disk connected together:
  - The classifier initially only matched brand-name-free tokens (`flash`/`thumb`/`pen
    drive`/`mass storage`); most real devices report their own brand/model instead, so it
    fell back to the generic icon. Added a fallback: USB protocol + a known size + no
    disk/SD match → `USBDrive` (a USB Mass Storage device under 400GB that isn't a card
    reader is almost always a pendrive in practice).
  - A false "Disk Not Readable" briefly appeared for an already-mounted pendrive at app
    launch, because Disk Arbitration sometimes delivers the "whole disk" object noticeably
    before the already-populated partition callback during the initial device scan, and the
    existing 1.5s grace window didn't always cover that gap. Fixed by cross-checking the
    real mount table (`getmntinfo()`) before declaring "not readable": an already-mounted
    partition cancels the false alert.
  - Ejecting/unplugging an already-identified device always showed the generic eject icon
    on "Unmounted" instead of its specific device icon, because the unmount `VolumeInfo`
    was built with a fixed eject icon without re-querying the device category (and by the
    time `-volumeDidUnmount:` runs, the path no longer exists to query). Fixed by capturing
    the category into a new `pathDeviceCategory` dictionary at MOUNT time (always reliable)
    instead of at unmount time — this also transparently covers both an ordered Finder
    eject and a direct physical "surprise" disconnect, which a first attempt (capturing the
    category in `-volumeWillUnmount:`) missed, since that callback only fires on an ordered
    software eject.
  - With a pendrive and an external hard disk connected together, the first attempt failed
    to detect the pendrive and produced a false "Disk Not Readable" for the (healthy)
    external disk. Root cause: `wholeDiskGroupKeyForDisk:` grouped devices by the whole
    disk's generic media name (e.g. "Generic") — many different physical devices report
    the same generic name for their whole-disk object, so two unrelated devices could
    collide under the same internal grouping key and cross-contaminate each other's
    "not readable" timers and "already reported" bookkeeping. Fixed by switching the
    grouping key to the whole disk's BSD name (e.g. "disk4" — unique per physical device
    for the session) while keeping the medium name only for the notification's display
    text. Thunderbolt/USB/Camera/Printer Monitor were reviewed for the same pattern and
    found not to share the risk (their identifiers are either pure dedup strings or
    guaranteed-unique hardware/CUPS identifiers, not internal dictionary keys).
  - A **known, deliberately unfixed limitation**: the app cannot distinguish "the user
    unmounted this on purpose and it's healthy" from "this never mounted because it's
    damaged" — both look identical to Disk Arbitration (device present, no filesystem
    mounted or recognized at that moment). Documented in README as an accepted,
    deliberately unfixed limitation.
  - A regression was found and **reverted**: after the pendrive-name fallback above, an SD
    card in a USB card reader/adapter got classified as a pendrive, because it reported
    itself as generic USB Mass Storage (media name "STORAGE DEVICE", protocol "USB", no
    SD/reader token anywhere) — indistinguishable from a genuinely unbranded pendrive with
    the signals available. The fallback was reverted; both cases now fall back to the
    generic icon again, documented in README as a known limitation. A related concern was
    also raised and documented: the ≥400GB "ExternalDisk" size heuristic is no longer
    fully reliable, since pendrives larger than 400GB now exist on the market (e.g. 1TB
    USB 3.1/3.2 drives).
- Icon sizing was standardized across the whole app: all 63 notification icons (Bluetooth,
  Device-*, Display, DisksVolumes, Network-*, Power/battery, Thermal, Thunderbolt, USB —
  Preferences-only `HWGPrefs*` icons excluded) were rescaled uniformly (same factor on both
  axes, never deforming naturally-horizontal icons like battery/USB/Thunderbolt) to ~94%
  canvas coverage, from a previous range of 42%–100%. The red "X" used by 13 of those icons
  (the 3 new device-category "Unmounted" variants, plus `Bluetooth-Off`,
  `DisksVolumes-Eject`, `Display-Off`, `Network-Ethernet-Off`, `Network-Generic-Off`,
  `Network-Interface-Off`, `Network-Wifi-Off`, `Thunderbolt-Off`, `USB-Off`,
  `Power-NoBattery`) was likewise standardized to the same span/thickness across all 13,
  reconstructed from each icon's "on"/base counterpart.

### Changed: `AppDelegate.h`/`.m` — Performance preset state and defaults-diffing
- Added the Minimal/All/Custom radio outlets and the `applyingPerformancePreset` reentrancy
  guard (prevents the preset-apply code path from re-triggering its own "user changed a
  monitor, switch to Custom" detection), plus `lastKnownDefaultsSnapshot` for the
  `NSUserDefaultsDidChangeNotification`-based diffing described above.


## 2026-07-19

### New: colored "before → after" highlight in notification banners
- The custom notification banner (`GrowlApplicationBridge.m`) now automatically highlights,
  in an accent color (blue in light mode, teal in dark mode) and bold, the "new" half of any
  description line written as `"Label:\told → new"` — the reader's eye lands on what actually
  changed instead of having to re-read the whole line.
- This is a single change in the shared banner-rendering code, so any current or future
  notification that uses that line format benefits automatically, with no per-plugin banner
  work needed.
- Adopted by three monitors so far: Thermal (state transitions), Display (resolution/refresh
  rate/rotation/role changes), and Power (AC/battery source changes). Not adopted by
  Volume/USB/Thunderbolt/Bluetooth, whose connect/disconnect events are binary rather than
  "a value that had a previous value."

### New: Display Monitor — detects changes on an already-connected display
- Two new notifications, both independently toggleable in Preferences and both firing
  without requiring a disconnect/reconnect:
  - **Resolution / refresh rate / rotation changed** — e.g. picking a different resolution
    in System Settings, a TV renegotiating a lower refresh rate, or physically rotating a
    monitor. Shown as separate "old → new" lines per field that actually changed.
  - **Role changed** (Main / Extended / Mirrored) — e.g. switching a display from Extended to
    Mirrored (or back), or moving the menu bar to a different display. Switching to Mirrored
    commonly changes BOTH resolution and role in the same reconfiguration event (macOS
    renegotiates a shared resolution across both displays) — the two are reported as two
    separate, distinct notifications on purpose, each with its own toggle, rather than merged
    into one.
- Confirmed as expected behavior, not a bug: switching between "Entire Screen" / "Window or
  App" / "Extended Display" on an *already-connected* display does not fire a notification,
  because the physical link never actually drops across that transition (see "Known
  limitations" below for the full explanation).

### New: Power Monitor — "Check Now" and a minutes option for the Battery Health reminder
- Added a "Check Now" button next to "Check every" that reports Battery Health (cycle
  count / battery health %) immediately, without waiting for the configured interval (up to
  a month by default).
- The optional "Notify every" reminder can now be set in **minutes** as well as hours (a new
  unit dropdown), for anyone who wants a tighter reminder cadence than the 1–24 hour range
  allowed.
- The Battery Health Check notification's icon now reflects the Mac's actual current power
  status (charging level, battery level, or plugged-in) instead of a fixed "plugged in" icon.

### Improved: Thermal Monitor transition wording + a way to preview any state
- The "old → new" thermal-state line now uses short state names in the arrow (e.g.
  "Critical → Nominal") and only attaches the descriptive phrase ("performance significantly
  reduced", etc.) to the CURRENT state — previously the old state's description was shown
  too, which could misleadingly read as if the old, worse condition still applied right
  after the arrow said otherwise.
- Added an explicit "↓ Cooling down (improving)" / "↑ Warming up (worsening)" tag so the
  direction of a transition is unambiguous at a glance.
- Added a "Simulate Test Notification" control (Preferences → Thermal Monitor): two dropdowns
  (From/To) plus a button, letting any state-to-state transition be previewed on demand.
  Useful because many Macs (this one included, under sustained CPU stress) rarely or never
  reach Serious/Critical under normal/moderate load, so those notifications/icons would
  otherwise be very hard to ever actually see and verify.

## 2026-07-18

### New: experimental early physical-link detection for Display Monitor (off by default)
- Added an opt-in, off-by-default feature in Display Monitor's preferences: "Early
  physical-link detection (Experimental)", with a 1–10 second polling interval slider.
- Reads the macOS unified log via the public `OSLogStore` API (macOS 10.15+, no special
  entitlement needed — confirmed with a standalone unprivileged test binary) for the
  kernel's `DCPAVFamilyProxy`/`IOAVFamily` HDCP handshake messages, whose `ReceiverConnected`
  entry marks the moment a physical HDMI/DisplayPort link is established — before macOS
  assigns the display an arrangement (Extended/Mirror), which is where the normal
  `CGGetOnlineDisplayList`-based detection starts.
- Fires as its own separate notification ("Video Link Detected (Experimental)", note name
  `DisplayLinkDetected`), not merged into or confused with the authoritative "Display
  Connected" notification.
- Deliberately NOT the default detection path: this scrapes free-form kernel debug log text
  with no API stability contract (can silently break on any macOS update), requires
  continuous polling since `OSLogStore` has no live-streaming callback (real, ongoing
  CPU/battery cost while enabled), and only applies to Apple Silicon (`DCPAVFamilyProxy` is
  the M-series Display Co-Processor proxy). All of this is spelled out in-app (preferences
  pane warning text) and in README under "Experimental: early physical-link detection".
- Both the app-facing GUI text and README document every trade-off in detail per explicit
  request, since this is expected to need re-verification/re-tuning against future macOS
  releases if it's ever kept enabled long-term.

### New: Display Monitor (8th monitor plugin)
- Added `DisplayMonitor`, a new plugin reporting external display connect/disconnect,
  wired into the Xcode project the same way as the other 7 monitors (own `.hwgrowlmonitor`
  bundle target, `com.jensyleo.hg4mac.DisplayMonitor` bundle id).
- Detection deliberately uses `CGGetOnlineDisplayList` + `CGDisplayRegisterReconfigurationCallback`
  (CoreGraphics), **not** `NSScreen`/`NSApplicationDidChangeScreenParametersNotification`.
  Empirically verified that `NSScreen` only exposes displays AppKit can address a window to:
  a display connected while macOS puts it in Mirror mode does not get its own `NSScreen`
  entry at all (confirmed live — the AppKit notification fired, but `[NSScreen screens]`
  never changed size), while `CGGetOnlineDisplayList` correctly reflects it in both Mirror
  and Extended arrangements.
- Notification includes the display's name (`NSScreen.localizedName`) plus three
  individually toggleable fields (same per-field pattern as USB/Thermal, all default on):
  resolution (with a Retina/scale-factor note when applicable), refresh rate, and role
  (Main / Extended / Mirrored).
- New icons: `Display-On`/`Display-Off` (notification) and `HWGPrefsDisplay` (sidebar),
  matching the existing flat icon style and exact system colors used by USB Monitor.
- Live-tested end to end with a real HDMI display through a USB hub: connect/disconnect
  detected correctly once macOS assigns the display an arrangement (Extended or Mirror).
  One edge case observed and closed: if the user dismisses macOS's own "how do you want to
  use this display" prompt without choosing an arrangement, the display has no
  `CGDirectDisplayID` yet and nothing is detectable — not an app or hub defect, just the
  normal state before macOS finishes negotiating the display.
- **Known limitation** (see README): the physical connection type (HDMI/DisplayPort/USB-C/
  Thunderbolt) and vendor/model via EDID are not obtainable through any public API on
  Apple Silicon — documented rather than worked around with a private/undocumented API.

### New: dedicated per-level notification icons for Thermal Monitor
- Replaced the "Device-Unstable" generic placeholder (previously reused for
  Serious/Critical, with Nominal/Fair falling back to the app icon) with 4 dedicated icons,
  one per `NSProcessInfoThermalState` level — `Thermal-Nominal`, `Thermal-Fair`,
  `Thermal-Serious`, `Thermal-Critical`. Each is the same thermometer glyph with a fill
  level proportional to severity (Nominal ~18% → Critical 100%, mirroring Power Monitor's
  charge-level ramp convention), plus a badge in the top-right corner that escalates in
  meaning: Nominal = green checkmark ("all good"), Fair = blue dash ("steady, still
  normal" — deliberately left neutral/undecorated in an earlier iteration, then given a
  blue accent to visually associate it with "normal" rather than a
  warning), Serious = the same warning triangle already used for "Unstable device" bounce
  alerts, Critical = the same radioactive icon already used for "Disk Not Readable" — reuse
  chosen deliberately so severity reads consistently across the whole app, not just within
  this one monitor. Iterated through several preview rounds before
  landing on the final set. Build 0 warnings, verified the 4 renditions compiled into the
  asset catalog and the app launches cleanly; forcing a real thermal-state transition to
  see the notification fire remains untested against real hardware.

### New: dedicated Thermal Monitor sidebar icon
- Replaced the temporary placeholder (no dedicated icon, sidebar row previously showed no
  image) with a proper flat icon matching the app's existing style: a thermometer with the
  same silhouette language as Power Monitor's battery icon (flat gray outline, no
  gradients/shadows), a solid red bulb, 4 stacked red segments in the tube (kept as 4
  distinct sections — one per thermal level — but all the same red), and tick marks for
  readability as a thermometer. Iterated through several previews (taller tube, smaller bulb,
  single-color segments) before
  landing on the final version. New `HWGPrefsThermal.imageset`. Verified live in the
  Preferences sidebar alongside the other 6 monitor icons.

### Changed: Power Monitor icon color order
- Reordered the battery icon's 4 blocks from green→yellow→orange→red (low-to-high, left to
  right) to red→orange→yellow→green (high-to-low, left to right).

### New: configurable notification fields for Volume Monitor
- Volume Monitor's "Volume Mounted" notification can now show, each independently
  toggleable from Preferences → Modules → Volume Monitor (all default on): the mount path,
  the file system type, and the volume's total size. Completes the per-field toggle pattern
  already applied to Network/Power/USB/Bluetooth/Thunderbolt — Volume was the only
  remaining monitor without it.
- File system type and size are read via a plain `statfs()` syscall (the same mechanism
  already used elsewhere in this file for readable-sibling detection) — never
  `NSFileManager`/`NSWorkspace`, so this doesn't touch TCC-gated file access. Mount-only:
  an unmounted path has no live filesystem left to stat.
- The new checkboxes appear ABOVE the existing "Ignored Drives" ignore-list picker (a real
  nib, unlike the other monitors' plain programmatic panes), using the same frame-based
  layout approach as Power Monitor — verified this xib's own content has no baked-in blank
  space (unlike PowerMonitorPrefs.xib), so no extra care was needed there.
- Verified live end-to-end: created and mounted a real disk image, confirmed the
  notification banner shows "Click to open" / mount path / "File system: apfs" /
  "Size: 10,4 MB" exactly as configured.

### Fix: checkboxes silently hidden behind the "Ignored Drives" list (Volume Monitor prefs pane)
- After moving "Ignored Drives" below the new checkboxes, the checkboxes stopped rendering
  entirely — confirmed via Accessibility introspection that they still existed (right
  element count, right approximate position) but were completely covered. Root cause: the
  ignore-list's nib-authored NSTableView/NSScrollView is pinned to its container's edges via
  Auto Layout, and that content silently grows taller than the nib's declared 195pt at
  runtime. With the list positioned at the TOP of the pane (its original position) any
  overflow simply extended above the pane's own bounds and got clipped away by the
  surrounding container — invisible, never a problem. With the list moved to the BOTTOM,
  that same overflow grows UPWARD from its fixed bottom edge and silently covers whatever
  sits above it. Fixed by wrapping the ignore-list view in a fixed-size container with
  `wantsLayer = YES` / `layer.masksToBounds = YES`, hard-clipping it to its intended
  202×195 box regardless of what its internal Auto Layout wants to do — decouples the
  checkbox layout math from the list's internal content growth entirely.

### Fix: Volume Monitor prefs pane floating with a gap above it (same root cause as the historical Bluetooth bug)
- Same failure mode documented earlier for Bluetooth's "gap above Notification fields on
  first open": AppDelegate force-resizes whatever `preferencePane` returns to match the
  container's real frame (`[newView setFrameSize:...]`, via `containerViewFrameDidChange:`).
  First fix attempt wrapped the content in a plain `NSScrollView` (matching Power Monitor's
  pattern) — this stopped the pane from floating/overflowing, but a **second**, related
  symptom remained: a non-flipped document view, when shorter than the scroll view's
  visible clip area, gets anchored to the BOTTOM of the clip by AppKit's default behavior,
  leaving the slack as a gap ABOVE the content instead of below it — exactly the symptom
  observed. Final fix: made the document
  view a FLIPPED `NSView` subclass (`HWGVolumeFlippedContentView`, same pattern as
  NetworkMonitor's existing `HWGFlippedContentView`) and rebuilt the layout top-down
  (cursor starts at 0, grows downward) instead of the previous bottom-up/pre-computed-height
  approach — a flipped document is anchored to the TOP of the clip by default, and as a
  bonus this also removes the whole class of "hand-computed total height drifts from the
  real content extent" bugs (height is simply wherever the cursor ends up). Verified live:
  content flush at the top on first open AND after switching away and back to the tab, no
  unnecessary scrollbar.

### New: Battery health check (Power Monitor, candidate #8)
- Power Monitor now reads `CycleCount` and computes battery health % (`AppleRawMaxCapacity`
  ÷ `DesignCapacity`) straight from the IOKit `AppleSmartBattery` registry — `IOPowerSources`
  (used elsewhere in this file) doesn't expose either. Verified against real `ioreg -c
  AppleSmartBattery -r` output; the top-level `MaxCapacity` key is a self-calibrating 0–100
  value that resets near 100 after recalibration events, so it's not used for long-term
  health — the raw mAh figures are. When present, `DesignCycleCount9C` (the manufacturer's
  rated cycle budget) is shown alongside the cycle count for context.
- Reported as its own periodic notification ("Battery Health Check"), separate from the
  existing minutes-based status refire — health/cycles change on a days/weeks/months
  timescale, not a minutes one. New Preferences → Modules → Power Monitor section:
  - Two independent checkboxes ("Cycle count", "Battery health %") — if both are off, the
    check is skipped entirely (nothing to report).
  - A slider (1–12) + unit popup (Days/Weeks/Months) controlling how often it fires;
    default 1 month. Persisted as a last-checked timestamp (not a running timer), so the
    configured interval is honored correctly across app relaunches/sleep, and a desktop Mac
    with no battery simply never fires (checked once per hour internally, cheaply, but only
    acts once the real interval has elapsed).
  - A child "Notify every" control (checkbox + hours slider, 1–24h, off by default):
    an optional, more frequent reminder of the same cached numbers while waiting for the
    next full check — independent cadence from "Check every" above, in hours instead of
    days/weeks/months.

### Fix: unit popup button's arrow/chevron not clickable (Power Monitor prefs pane)
- The "Days/Weeks/Months" popup (added for the battery health check above) silently
  extended past the right edge of its containing view — a subview whose frame exceeds its
  superview's bounds is only clickable in the portion still within those bounds, so only
  the popup's text (further left, in-bounds) responded to clicks; the arrow/chevron at its
  far right edge did not. Fixed by widening the prefs pane's internal layout width (380 →
  460) so every control in the "Check every"/"Notify every" rows fits fully within bounds.

### Fix: phantom scroll space in Power Monitor prefs pane
- `totalHeight` (the hand-computed height reserved for the pane's scrollable content) was
  over-reserving space: it counted `PowerMonitorPrefs.xib`'s full declared height (204pt)
  even though the very next line already skips ~97pt of that xib's own baked-in blank space
  and resumes from its real content bottom (a documented, intentional trick — see the
  comment above `xibContentBottomLocal`). Since content is anchored top-down, that
  unaccounted-for surplus always landed as dead space at the very BOTTOM of the pane, which
  in turn made the scroll view believe there was more content to scroll to — an empty,
  unnecessary scrollbar with nothing under it. Fixed by reserving exactly the amount of
  space the xib section actually consumes (`xibContentBottomLocal + 16`) instead of its full
  declared height, so the pane's real content ends flush with its bottom padding and no
  scrollbar appears.

### New: Thermal Monitor — 7th monitor plugin
- New loadable plugin `ThermalMonitor.hwgrowlmonitor`, separate from Power Monitor by
  design (battery state and thermal/throttling state shown independently to the user),
  though it reads from the same system power/process-info APIs (`NSProcessInfo`) as Power
  Monitor.
- Detects the Mac's thermal state via the public `NSProcessInfo.thermalState` API (4
  levels: Nominal/Fair/Serious/Critical) and `NSProcessInfoThermalStateDidChangeNotification`
  — no polling, no private APIs.
- Per-level notification toggles in Preferences → Modules → Thermal Monitor: notify when
  **entering** Nominal/Fair/Serious/Critical, each independently switchable. Defaults:
  Serious and Critical **on** (actionable — performance is being reduced), Nominal and Fair
  **off** (avoid noise on "back to normal"). The level is tracked internally regardless of
  the toggles, so enabling one later doesn't miss the next real transition.
- Icon: **temporary** — reuses the existing "Device-Unstable" warning triangle for
  Serious/Critical, no dedicated icon yet for Nominal/Fair (falls back to the app icon).
  Dedicated per-level icons are pending (4 PNGs).
- Two related monitor ideas were considered and **deferred instead of implemented**:
  Sleep/Wake and Screen Lock/Unlock — both decided to not fit the app's philosophy of
  reporting hardware changes while the Mac is in active use; Screen Lock additionally has
  no public/documented API.


### Fixed: Wi-Fi signal-change detection appeared delayed by up to 2 poll cycles
- Confirmed via user testing (walking between two known-different signal spots, once and
  waiting): a real signal-bar change was only reported after the poll timer fired *twice*,
  regardless of the configured poll interval (12s → 2 cycles = 24s; 5s → 3-4 cycles =
  15-20s) — the constant factor pointed at a fixed ~20s delay rather than the interval
  itself.
- Root cause: `pollWifiSignal:`'s hardcoded 20-second cooldown between two
  "Wi-Fi Signal Changed" notifications (meant to stop a value hovering at a bar threshold
  from spamming) was also blocking a legitimate second, real change that followed shortly
  after a first one — exactly the test pattern above (settle at 100% → notified → move to
  a weaker spot within the next 20s → blocked until the cooldown expired).
- Also baselines the signal bar level the moment Wi-Fi connects (using the RSSI already
  available at that point) instead of waiting for the poll timer's first tick to do it —
  minor secondary fix, doesn't apply if Wi-Fi was already connected before the app started
  polling.
- Made the cooldown user-configurable: a new slider in Preferences → Modules →
  Network Monitor → Wi-Fi ("Minimum time between signal-change notices"), 0–60 s, default
  **10 s** (down from the prior hardcoded 20 s), 0 = disabled.

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
