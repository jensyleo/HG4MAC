# P9 Option A — Migrating TIFF icons to SF Symbols (notes)

Full list of images in use and the proposed SF Symbol.
Total to evaluate: 7 monitor (preferences) icons + 35 notification icons.

## Monitor icons (Preferences > Modules)

| Current file | Proposed SF Symbol | Note |
|--------------|--------------------|------|
| HWGPrefsUSB.tif | `cable.connector` | |
| HWGPrefsNetwork.tif | `network` | |
| HWGPrefsPower.tif | `bolt.fill` | or `battery.100` |
| HWGPrefsDrivesVolumes.tif | `externaldrive` | already used in VolumeMonitor |
| HWGPrefsThunderbolt.tif | `bolt` | ⚠️ no official Thunderbolt symbol |
| HWGPrefsBluetooth.tif | (no equivalent) | ⚠️ Apple has NO Bluetooth glyph (trademark) — keep TIFF or custom |
| HWGPrefsDefault.tif | `questionmark.circle` | generic fallback |

## Notification icons

### USB
| USB-On.tif | `cable.connector` |
| USB-Off.tif | `cable.connector.slash` (or no variant) |

### Bluetooth ⚠️ (no official SF Symbol)
| Bluetooth-On.tif | keep TIFF / custom symbol |
| Bluetooth-Off.tif | keep TIFF / custom symbol |

### Disks & Volumes
| DisksVolumes-Eject.tif | `eject.fill` |

### Network
| Network-Wifi-0.tif | `wifi` (low signal) |
| Network-Wifi-1.tif | `wifi` |
| Network-Wifi-2.tif | `wifi` |
| Network-Wifi-3.tif | `wifi` |
| Network-Wifi-4.tif | `wifi` (full signal) |
| Network-Wifi-Off.tif | `wifi.slash` |
| Network-Ethernet-On.tif | `cable.connector` or `network` |
| Network-Ethernet-Off.tif | `network.slash` |
| Network-Generic-On.tif | `network` |
| Network-Generic-Off.tif | `network.slash` |
| Note | SF Symbols has no 5 distinct Wi-Fi signal levels; you'd use the same `wifi` or compose with opacity |

### Power (battery)
| Power-0.tif | `battery.0` |
| Power-10/20.tif | `battery.25` |
| Power-30/40/50.tif | `battery.50` |
| Power-60/70.tif | `battery.75` |
| Power-80/90/100.tif | `battery.100` |
| Power-Charging.tif | `battery.100.bolt` |
| Power-Plugged.tif | `powerplug.fill` |
| Power-NoBattery.tif | `bolt.slash` |
| Power-BatteryFailure.tif | `exclamationmark.triangle.fill` |

### Thunderbolt ⚠️ (no official SF Symbol)
| Thunderbolt-On.tif | `bolt` (approximate) |
| Thunderbolt-Off.tif | `bolt.slash` |

## Known issues

1. **Bluetooth and Thunderbolt have NO official SF Symbol** (trademarks). Options: keep their
   TIFFs, or create "custom symbols" (SVG from Apple's template).
2. **Wi-Fi by signal level**: SF Symbols only has one `wifi`; the 5 levels (0-4) would be lost
   or would have to be simulated.
3. **Look change**: SF Symbols are linear/monochrome, different from Growl's classic colored
   icons.

## Recommendation
Migrate to SF Symbols the ones with a good equivalent (USB, Network, Power, Volume/Eject) and
**keep TIFF for Bluetooth and Thunderbolt**. Final decision by the user, monitor by monitor.

> Status: notes only — this migration has not been done. The app currently uses colored
> Asset-catalog icons (and the Wi-Fi level icons are now color-coded — see CHANGELOG).
