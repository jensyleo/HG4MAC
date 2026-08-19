//
//  HWGrowlBluetoothMonitor.m
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/5/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

// compile with ARC: -fobjc-arc
#import "HWGrowlBluetoothMonitor.h"
#import "HWGIconOverrideStore.h"
#import "HWGIconPickerView.h"
#import <stdlib.h>
#import <IOBluetooth/IOBluetooth.h>
#include <IOKit/IOKitLib.h>

// F33: individually configurable fields in the Bluetooth connect notification's extra
// info — same pattern as Network/Power/USB Monitor. All default to YES.
#define HWG_BT_SHOW_TYPE_KEY    @"HWGBluetoothShowType"
#define HWG_BT_SHOW_PAIRED_KEY  @"HWGBluetoothShowPaired"
#define HWG_BT_SHOW_ADDRESS_KEY @"HWGBluetoothShowAddress"
// F36 (a): battery level for Apple accessories (AirPods/Magic Mouse/Keyboard/Trackpad) via
// IOBluetoothDevice's unofficial, undocumented battery selectors — not in the public header,
// so every read is respondsToSelector:-guarded and wrapped in performSelector. On by default
// since this is the well-established, widely-used mechanism (same one iStat Menus/Barttery/etc.
// rely on) for Apple's own accessories specifically. Non-Apple (CoreBluetooth GATT Battery
// Service) is a separate, not-yet-implemented rope — see TODO.md, blocked on hardware to test.
#define HWG_BT_SHOW_BATTERY_KEY @"HWGBluetoothShowBattery"
#define HWG_BT_SHOW_RSSI_KEY    @"HWGBluetoothShowRSSI"
#define HWG_BT_SHOW_SERVICES_KEY @"HWGBluetoothShowServices"

static BOOL HWGBTBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

// Same dBm thresholds as HWGWifiBarsForRSSI (NetworkMonitor/HWGWifiSignal.m) — both values are
// raw receiver signal strength in dBm, so the physical scale is comparable even though
// Bluetooth doesn't document a standard "golden range" the way Wi-Fi chipsets do. Best-effort,
// not a verified Bluetooth-specific calibration.
static NSInteger HWGBluetoothBarsForRSSI(NSInteger rssi) {
	if (rssi >= -55) return 4;
	else if (rssi >= -65) return 3;
	else if (rssi >= -73) return 2;
	else if (rssi >= -80) return 1;
	else return 0;
}

// Per-device-type "Notify" toggle (Icons tab) — same mechanism as USB/Thunderbolt Monitor's.
// Gates only the CONNECT notification (disconnect has no reliable class info, per the
// existing note on `-bluetoothDisconnection:device:`).
#define HWG_BT_NOTIFY_KEY_PREFIX @"HWGBluetoothNotifyType_"
#define HWG_BT_NOTIFY_DISCONNECT_KEY @"HWGBluetoothNotifyDisconnect"

// Added 18-ago-2026 (feedback del usuario: "cuando prendo y apago el BT no lo detecta") — the
// Bluetooth RADIO's own power state (System Settings/Control Center toggle), distinct from any
// device connect/disconnect. IOBluetoothHostController.powerState is public API (declared in
// IOBluetoothHostController.h, the same header this app already imports via <IOBluetooth/
// IOBluetooth.h>) — but IOBluetooth ships no documented push notification for this specific
// state change, so it's polled, same pattern already used elsewhere in this app for hardware
// states with no native push event (e.g. NetworkMonitor's Ethernet speed).
// Split into two independent toggles/rows (18-ago-2026, feedback del usuario) — each with its
// own dedicated icon (Bluetooth-Radio-On/-Off, NOT the existing Bluetooth-On/-Off assets, which
// are already the defaultName for "Connected (generic)"/"Disconnected (generic)" a few rows up
// in this same picker — this app's icon-override system keys customizations by defaultName, so
// reusing those would mean customizing "Connected (generic)" silently also re-skins this event,
// and vice versa).
#define HWG_BT_NOTIFY_RADIO_ON_KEY  @"HWGBluetoothNotifyRadioOn"
#define HWG_BT_NOTIFY_RADIO_OFF_KEY @"HWGBluetoothNotifyRadioOff"
// BUG FIX (18-ago-2026, feedback del usuario: "tarda mucho en aparecer" / "sigue estando muy
// lento") — was 5.0s, then 2.0s. Combined with the always-tracking fix above (see
// -pollRadioPowerState), 1.0s keeps this near-instant from the user's perspective while still
// only doing a single cheap IOBluetoothHostController property read per tick (no I/O).
#define HWG_BT_RADIO_POLL_INTERVAL 1.0

@interface HWGrowlBluetoothMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, assign) BOOL starting;
@property (nonatomic, strong) NSView *prefsView;

// strong: we keep this object to call -unregister on it later, so the monitor
// must own it.
@property (nonatomic, strong) IOBluetoothUserNotification *connectionNotification;
@property (nonatomic, strong) NSTimer *radioPowerPollTimer;
// -1 = no baseline read yet this launch, 0/1 = last known adapter power state (off/on).
@property (nonatomic, assign) NSInteger lastKnownRadioPowerState;

@end

@implementation HWGrowlBluetoothMonitor

@synthesize delegate;
@synthesize starting;
@synthesize connectionNotification;
@synthesize prefsView;
@synthesize radioPowerPollTimer;
@synthesize lastKnownRadioPowerState;

-(void)dealloc {
	[connectionNotification unregister];
	[radioPowerPollTimer invalidate];
	// ARC handles the release; no [super dealloc].
}

-(id)init {
	// Legacy 10.7-10.7.2 incompatibility check removed: the app's deployment
	// target is 13.0, so that range is unreachable.
	self = [super init];
	self.lastKnownRadioPowerState = -1;
	return self;
}

// Added 18-ago-2026 — see HWG_BT_NOTIFY_RADIO_KEY's doc comment above. The timer always runs
// (cheap — a single IOBluetoothHostController property read every 5s) and the toggle is
// checked first thing inside -pollRadioPowerState, same "always-scheduled, checks its own flag"
// pattern NetworkMonitor's Ethernet-speed poll already uses — this Icons-tab checkbox has no
// direct hook into starting/stopping a timer the way a General-tab checkbox's own action would,
// so gating inside the poll itself is simpler and matches an existing precedent in this app.
-(void)updateRadioPowerPollState {
	if (radioPowerPollTimer) return;
	self.radioPowerPollTimer = [NSTimer scheduledTimerWithTimeInterval:HWG_BT_RADIO_POLL_INTERVAL
																 target:self
															   selector:@selector(pollRadioPowerState)
															   userInfo:nil
																repeats:YES];
	[self pollRadioPowerState];   // baseline immediately rather than waiting for the first tick
}

-(void)pollRadioPowerState {
	// BUG FIX (18-ago-2026, feedback del usuario: "sigue estando muy lento en activarse") —
	// used to reset the baseline to -1 on EVERY tick while both toggles were off, so enabling
	// a toggle in Preferences didn't take effect until the NEXT tick just to (re-)establish a
	// baseline (no notification yet), and only the tick AFTER that could detect a real change —
	// up to one whole extra poll interval of latency on top of the poll cadence itself. Now
	// tracks the real hardware state unconditionally every tick, and only gates the
	// NOTIFICATION on the toggles — so a state actually captured while disabled already counts
	// as a valid baseline the moment either toggle is turned on.
	IOBluetoothHostController *controller = [IOBluetoothHostController defaultController];
	if (!controller) return;   // no Bluetooth hardware present
	BOOL poweredOn = ([controller powerState] == kBluetoothHCIPowerStateON);
	if (lastKnownRadioPowerState == poweredOn) return;
	BOOL hadBaseline = (lastKnownRadioPowerState != -1);
	self.lastKnownRadioPowerState = poweredOn;
	if (!hadBaseline) return;   // first sighting — baseline only, no notification

	// Split toggles (18-ago-2026) — each direction's notification is independently gated,
	// matching the Connected (generic)/Disconnected (generic) precedent a few rows up in the
	// Icons picker.
	BOOL onEnabled = HWGBTBoolForKey(HWG_BT_NOTIFY_RADIO_ON_KEY, NO);
	BOOL offEnabled = HWGBTBoolForKey(HWG_BT_NOTIFY_RADIO_OFF_KEY, NO);
	if (poweredOn && !onEnabled) return;
	if (!poweredOn && !offEnabled) return;

	NSData *iconData = [HWGResolveIconNamed(poweredOn ? @"Bluetooth-Radio-On" : @"Bluetooth-Radio-Off") TIFFRepresentation];
	[delegate notifyWithName:poweredOn ? @"BluetoothRadioOn" : @"BluetoothRadioOff"
							 title:poweredOn ? NSLocalizedString(@"Bluetooth Turned On", @"") : NSLocalizedString(@"Bluetooth Turned Off", @"")
					 description:@""
							  icon:iconData
			  identifierString:@"HWGrowlBluetoothRadioPower"
				  contextString:nil
							plugin:self];
}

-(void)postRegistrationInit {
	self.starting = YES;
	[self updateRadioPowerPollState];
	// RE-ENABLED (10-ago-2026): was disabled after CONFIRMING this call made the whole
	// process crash on macOS Tahoe 26.x with a TCC privacy-violation abort. Since found the
	// actual root cause (see v1.10.8 in CHANGELOG.md): Xcode's default ad-hoc build left the
	// code-signing Identifier as the raw executable name ("HG4MAC") instead of the real
	// CFBundleIdentifier ("com.jensyleo.hg4mac"), AND never bound Info.plist into the
	// signature at all. The earlier test that still crashed only had Info.plist bound — the
	// Identifier mismatch was still present, since that fix hadn't been found yet. Re-testing
	// now that the build phase fixes BOTH (see HardwareGrowler target's "Re-sign..." script
	// phase) to see if a fully correct ad-hoc identity (no paid Developer ID/Team needed) is
	// actually sufficient to avoid this crash.
	self.connectionNotification = [IOBluetoothDevice registerForConnectNotifications:self
																									selector:@selector(bluetoothConnection:device:)];
	self.starting = NO;
}

-(void)bluetoothName:(NSString*)name connected:(BOOL)connected iconName:(NSString *)iconNameOverride extraInfo:(NSString *)extraInfo {
	NSString *title = connected ? NSLocalizedString(@"Bluetooth Connection", @"") : NSLocalizedString(@"Bluetooth Disconnection", @"");

	// Device-type icon: `deviceClassMajor`/`deviceClassMinor` (source of `iconNameOverride`)
	// come from the paired device's cached class-of-device record, not a live-connection-only
	// property, so it's still available at disconnect (unlike extraInfo's battery reading,
	// which does need an active connection and stays nil there). When a type-specific icon is
	// available, use its dedicated "-Disconnected" variant (base art + red X, same convention
	// as Volume Monitor's Unmounted states) instead of the plain generic icon.
	NSString *imageName;
	if (connected) {
		imageName = iconNameOverride ?: @"Bluetooth-On";
	} else if (iconNameOverride) {
		imageName = [iconNameOverride stringByAppendingString:@"-Disconnected"];
	} else {
		imageName = @"Bluetooth-Off";
	}
	NSData *iconData = [HWGResolveIconNamed(imageName) TIFFRepresentation];
	NSString *description = extraInfo ? [NSString stringWithFormat:@"%@\n%@", name, extraInfo] : name;

	[delegate notifyWithName:connected ? @"BluetoothConnected" : @"BluetoothDisconnected"
							 title:title
					 description:description
							  icon:iconData
			  identifierString:name
				  contextString:nil
							plugin:self];
}

// Human-readable label for a device's major class, and (for the two categories that carry
// useful sub-detail) its minor class — via the Bluetooth SIG's published Class of Device
// major/minor tables, read through IOBluetoothDevice's own public `deviceClassMajor`/
// `deviceClassMinor` accessors (developer.apple.com/documentation/iobluetooth).
-(NSString *)bluetoothTypeLabelForDevice:(IOBluetoothDevice *)device {
	BluetoothDeviceClassMajor major = [device deviceClassMajor];
	BluetoothDeviceClassMinor minor = [device deviceClassMinor];

	switch (major) {
		case kBluetoothDeviceClassMajorComputer:       return NSLocalizedString(@"Computer", @"");
		case kBluetoothDeviceClassMajorPhone:           return NSLocalizedString(@"Phone", @"");
		case kBluetoothDeviceClassMajorLANAccessPoint:  return NSLocalizedString(@"Network Access Point", @"");
		case kBluetoothDeviceClassMajorImaging:         return NSLocalizedString(@"Imaging", @"");
		case kBluetoothDeviceClassMajorWearable:        return NSLocalizedString(@"Wearable", @"");
		case kBluetoothDeviceClassMajorToy:             return NSLocalizedString(@"Toy", @"");
		case kBluetoothDeviceClassMajorHealth:           return NSLocalizedString(@"Health Device", @"");
		case kBluetoothDeviceClassMajorPeripheral: {
			// Peripheral minor class packs Keyboard/Pointing/Combo into the top 2 bits.
			uint8_t peripheralType = minor & 0x30;
			if (peripheralType == 0x10) return NSLocalizedString(@"Keyboard", @"");
			if (peripheralType == 0x20) return NSLocalizedString(@"Mouse/Trackpad", @"");
			if (peripheralType == 0x30) return NSLocalizedString(@"Keyboard & Mouse", @"");
			return NSLocalizedString(@"Peripheral", @"");
		}
		case kBluetoothDeviceClassMajorAudio: {
			switch (minor) {
				case kBluetoothDeviceClassMinorAudioHeadset:    return NSLocalizedString(@"Headset", @"");
				case kBluetoothDeviceClassMinorAudioHandsFree:  return NSLocalizedString(@"Hands-Free", @"");
				case kBluetoothDeviceClassMinorAudioMicrophone: return NSLocalizedString(@"Microphone", @"");
				case kBluetoothDeviceClassMinorAudioLoudspeaker: return NSLocalizedString(@"Speaker", @"");
				case kBluetoothDeviceClassMinorAudioHeadphones: return NSLocalizedString(@"Headphones", @"");
				case kBluetoothDeviceClassMinorAudioPortable:   return NSLocalizedString(@"Portable Audio", @"");
				case kBluetoothDeviceClassMinorAudioCar:        return NSLocalizedString(@"Car Audio", @"");
				case kBluetoothDeviceClassMinorAudioHiFi:       return NSLocalizedString(@"Hi-Fi Audio", @"");
				default: return NSLocalizedString(@"Audio/Video", @"");
			}
		}
		default: return nil;   // Miscellaneous/Unclassified — nothing useful to say
	}
}

// Maps the same major/minor Class of Device values used by `bluetoothTypeLabelForDevice:`
// to one of the device-type icons (Assets.xcassets) added for the "maximum icon coverage"
// pass — nil whenever there's no dedicated icon for that specific sub-case (e.g. Imaging,
// Toy, or an Audio minor class without one of the 4 icons made for Headphones/Speaker/
// Headset/Microphone), which falls back to the plain generic Bluetooth-On icon.
-(NSString *)bluetoothIconNameForDevice:(IOBluetoothDevice *)device {
	BluetoothDeviceClassMajor major = [device deviceClassMajor];
	BluetoothDeviceClassMinor minor = [device deviceClassMinor];

	switch (major) {
		case kBluetoothDeviceClassMajorComputer:       return @"BT-TypeComputer";
		case kBluetoothDeviceClassMajorPhone:           return @"BT-TypePhone";
		case kBluetoothDeviceClassMajorLANAccessPoint:  return @"BT-TypeAccessPoint";
		case kBluetoothDeviceClassMajorWearable:        return @"BT-TypeWearable";
		case kBluetoothDeviceClassMajorHealth:           return @"BT-TypeHealth";
		case kBluetoothDeviceClassMajorPeripheral: {
			uint8_t peripheralType = minor & 0x30;
			if (peripheralType == 0x10) return @"BT-TypeKeyboard";
			if (peripheralType == 0x20) return @"BT-TypeMouse";
			if (peripheralType == 0x30) return @"BT-TypeCombo";
			return nil;   // plain "Peripheral" — nothing more specific to show
		}
		case kBluetoothDeviceClassMajorAudio: {
			switch (minor) {
				case kBluetoothDeviceClassMinorAudioHeadset:
				case kBluetoothDeviceClassMinorAudioHandsFree: return @"BT-TypeHeadset";
				case kBluetoothDeviceClassMinorAudioMicrophone: return @"BT-TypeMicrophone";
				case kBluetoothDeviceClassMinorAudioLoudspeaker: return @"BT-TypeSpeaker";
				case kBluetoothDeviceClassMinorAudioHeadphones: return @"BT-TypeHeadphones";
				default: return nil;   // Portable/Car/Hi-Fi/etc. — no dedicated icon made
			}
		}
		default: return nil;   // Imaging, Toy, Miscellaneous/Unclassified
	}
}

// Stable identifier per type, used to build the "Notify" defaults key — kept separate
// from the icon-name lookup so notify-toggle identifiers survive an icon asset rename.
// Every sub-case that falls back to a shared/no icon above also shares one "Other" key.
-(NSString *)bluetoothTypeIdentifierForDevice:(IOBluetoothDevice *)device {
	BluetoothDeviceClassMajor major = [device deviceClassMajor];
	BluetoothDeviceClassMinor minor = [device deviceClassMinor];

	switch (major) {
		case kBluetoothDeviceClassMajorComputer:       return @"Computer";
		case kBluetoothDeviceClassMajorPhone:           return @"Phone";
		case kBluetoothDeviceClassMajorLANAccessPoint:  return @"AccessPoint";
		case kBluetoothDeviceClassMajorWearable:        return @"Wearable";
		case kBluetoothDeviceClassMajorHealth:           return @"Health";
		case kBluetoothDeviceClassMajorPeripheral: {
			uint8_t peripheralType = minor & 0x30;
			if (peripheralType == 0x10) return @"Keyboard";
			if (peripheralType == 0x20) return @"Mouse";
			if (peripheralType == 0x30) return @"Combo";
			return @"Other";
		}
		case kBluetoothDeviceClassMajorAudio: {
			switch (minor) {
				case kBluetoothDeviceClassMinorAudioHeadset:
				case kBluetoothDeviceClassMinorAudioHandsFree: return @"Headset";
				case kBluetoothDeviceClassMinorAudioMicrophone: return @"Microphone";
				case kBluetoothDeviceClassMinorAudioLoudspeaker: return @"Speaker";
				case kBluetoothDeviceClassMinorAudioHeadphones: return @"Headphones";
				default: return @"Other";
			}
		}
		default: return @"Other";
	}
}

// Calls one of IOBluetoothDevice's unofficial battery selectors (batteryPercentSingle /
// batteryPercentLeft / batteryPercentRight / batteryPercentCase) and returns the percentage,
// or -1 if the device doesn't respond to that selector or reports no reading. Not in the
// public IOBluetoothDevice header — every call is respondsToSelector:-guarded first, and the
// invocation is built via NSInvocation (not a plain performSelector:) because the return
// type is a small integer, not an object; a plain performSelector: would misinterpret it.
-(NSInteger)bluetoothBatteryValueForSelectorName:(NSString *)selectorName device:(IOBluetoothDevice *)device {
	SEL selector = NSSelectorFromString(selectorName);
	if (![device respondsToSelector:selector]) return -1;

	NSMethodSignature *signature = [device methodSignatureForSelector:selector];
	if (!signature) return -1;

	NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
	invocation.selector = selector;
	invocation.target = device;
	[invocation invoke];

	// All four known selectors return a signed 8-bit percentage (-1 = "no reading").
	int8_t result = -1;
	[invocation getReturnValue:&result];
	return result;
}

// Strips everything except hex digits and lowercases — Bluetooth addresses show up in
// different separator styles across IOKit properties (confirmed on this Mac: IOBluetoothDevice's
// own -addressString vs. the registry's "DeviceAddress"/"SerialNumber" don't necessarily agree
// on "-" vs ":"), so comparing the bare hex digits is the only format-proof way to match them.
static NSString *HWGBTNormalizedAddress(NSString *address) {
	if (!address.length) return @"";
	NSMutableString *hexOnly = [NSMutableString stringWithCapacity:address.length];
	NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
	for (NSUInteger i = 0; i < address.length; i++) {
		unichar c = [address characterAtIndex:i];
		if ([hexSet characterIsMember:c]) [hexOnly appendFormat:@"%C", c];
	}
	return [hexOnly lowercaseString];
}

// Second battery path, for Apple HID peripherals (Magic Mouse/Keyboard/Trackpad) — confirmed
// via `ioreg` that these do NOT answer the IOBluetoothDevice private selectors above (those
// are mainly for AirPods/Beats headphones per Hammerspoon's reverse-engineering notes); their
// battery instead lives in the IOKit registry, on an `AppleDeviceManagementHIDEventService`
// node with a "DeviceAddress" property matching the Bluetooth device's address (hex digits
// only — see HWGBTNormalizedAddress above), and a "BatteryPercent" integer property (confirmed
// present and correct — read 53 on a real Magic Keyboard while writing this).
-(NSInteger)bluetoothHIDBatteryPercentForDevice:(IOBluetoothDevice *)device {
	NSString *targetAddress = HWGBTNormalizedAddress([device addressString]);
	if (!targetAddress.length) return -1;

	CFMutableDictionaryRef matchDict = IOServiceMatching("AppleDeviceManagementHIDEventService");
	if (!matchDict) return -1;

	io_iterator_t iterator = IO_OBJECT_NULL;
	if (IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator) != kIOReturnSuccess) return -1;

	NSInteger result = -1;
	io_object_t service;
	while ((service = IOIteratorNext(iterator))) {
		// Try "DeviceAddress" first, then "SerialNumber" as a fallback — both were observed
		// carrying the device's Bluetooth address (in different separator styles) on this Mac's
		// registry nodes, but not every node necessarily has both keys populated.
		BOOL matched = NO;
		for (NSString *addressKey in @[@"DeviceAddress", @"SerialNumber"]) {
			CFTypeRef addressRef = IORegistryEntryCreateCFProperty(service, (__bridge CFStringRef)addressKey, kCFAllocatorDefault, 0);
			if (!addressRef) continue;
			if (CFGetTypeID(addressRef) == CFStringGetTypeID()) {
				NSString *entryAddress = HWGBTNormalizedAddress((__bridge NSString *)addressRef);
				if (entryAddress.length && [entryAddress isEqualToString:targetAddress]) matched = YES;
			}
			CFRelease(addressRef);
			if (matched) break;
		}

		if (matched) {
			CFTypeRef percentRef = IORegistryEntryCreateCFProperty(service, CFSTR("BatteryPercent"), kCFAllocatorDefault, 0);
			if (percentRef) {
				if (CFGetTypeID(percentRef) == CFNumberGetTypeID()) {
					int percent = -1;
					CFNumberGetValue((CFNumberRef)percentRef, kCFNumberIntType, &percent);
					result = percent;
				}
				CFRelease(percentRef);
			}
		}
		IOObjectRelease(service);
		if (result >= 0) break;
	}
	IOObjectRelease(iterator);
	return result;
}

// AirPods-style devices report Left/Right/Case independently via the private IOBluetoothDevice
// selectors; Apple HID peripherals (Magic Mouse/Keyboard/Trackpad) report only a single overall
// value via the IOKit registry path above. Builds one "Battery:" line covering whichever
// reading is actually available, or nil if neither path has anything (e.g. non-Apple devices).
-(NSString *)bluetoothBatteryInfoForDevice:(IOBluetoothDevice *)device {
	NSInteger single = [self bluetoothBatteryValueForSelectorName:@"batteryPercentSingle" device:device];
	if (single < 0) single = [self bluetoothHIDBatteryPercentForDevice:device];
	if (single >= 0) {
		return [NSString stringWithFormat:NSLocalizedString(@"Battery:\t%ld%%", @""), (long)single];
	}

	NSInteger left  = [self bluetoothBatteryValueForSelectorName:@"batteryPercentLeft"  device:device];
	NSInteger right = [self bluetoothBatteryValueForSelectorName:@"batteryPercentRight" device:device];
	NSInteger box   = [self bluetoothBatteryValueForSelectorName:@"batteryPercentCase"  device:device];
	if (left < 0 && right < 0 && box < 0) return nil;

	NSMutableArray<NSString*> *parts = [NSMutableArray array];
	if (left  >= 0) [parts addObject:[NSString stringWithFormat:NSLocalizedString(@"L %ld%%", @""), (long)left]];
	if (right >= 0) [parts addObject:[NSString stringWithFormat:NSLocalizedString(@"R %ld%%", @""), (long)right]];
	if (box   >= 0) [parts addObject:[NSString stringWithFormat:NSLocalizedString(@"Case %ld%%", @""), (long)box]];
	return [NSString stringWithFormat:NSLocalizedString(@"Battery:\t%@", @""), [parts componentsJoinedByString:@" / "]];
}

-(NSString *)bluetoothExtraInfoForDevice:(IOBluetoothDevice *)device {
	NSMutableArray<NSString*> *lines = [NSMutableArray array];

	if (HWGBTBoolForKey(HWG_BT_SHOW_TYPE_KEY, YES)) {
		NSString *typeLabel = [self bluetoothTypeLabelForDevice:device];
		if (typeLabel) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Type:\t%@", @""), typeLabel]];
	}

	if (HWGBTBoolForKey(HWG_BT_SHOW_PAIRED_KEY, YES)) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Paired:\t%@", @""),
			[device isPaired] ? NSLocalizedString(@"Yes", @"") : NSLocalizedString(@"No", @"")]];
	}

	if (HWGBTBoolForKey(HWG_BT_SHOW_ADDRESS_KEY, YES)) {
		NSString *address = [device addressString];
		if (address) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Address:\t%@", @""), address]];
	}

	if (HWGBTBoolForKey(HWG_BT_SHOW_BATTERY_KEY, YES)) {
		NSString *batteryInfo = [self bluetoothBatteryInfoForDevice:device];
		if (batteryInfo) [lines addObject:batteryInfo];
	}

	// Added 17-ago-2026 (feedback del usuario) — SDP service records, public API
	// (IOBluetoothDevice.services), never surfaced before. Gives a more precise "what can this
	// device do" than the class-major/minor guess already shown as Type above.
	if (HWGBTBoolForKey(HWG_BT_SHOW_SERVICES_KEY, NO)) {
		NSArray *services = [device services];
		if ([services count]) {
			NSMutableArray<NSString*> *names = [NSMutableArray array];
			for (IOBluetoothSDPServiceRecord *record in services) {
				NSString *name = [record getServiceName];
				if (name) [names addObject:name];
			}
			if ([names count]) {
				[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Services:\t%@", @""), [names componentsJoinedByString:@", "]]];
			}
		}
	}

	if (HWGBTBoolForKey(HWG_BT_SHOW_RSSI_KEY, YES)) {
		// rawRSSI()/RSSI() only return a meaningful value while CONNECTED (public API,
		// IOBluetoothDevice) — not during discovery/pairing, which this monitor doesn't do.
		BluetoothHCIRSSIValue rssi = [device rawRSSI];
		if (rssi != 127) { // 127 = "not available" per IOBluetooth
			// Bars use the SAME dBm thresholds as Wi-Fi's signal bars (both are raw receiver
			// signal strength in dBm) — a reasonable but unverified assumption, since Bluetooth
			// firmwares don't document a standard "golden range" the way Wi-Fi chipsets do.
			// The connect notification deliberately keeps the device-type icon (headphones/
			// mouse/etc.) rather than swapping to a signal-bars icon — per-level icons still
			// exist in the Icons tab for reference/customization (feedback 13-ago-2026).
			NSInteger bars = HWGBluetoothBarsForRSSI(rssi);
			[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Signal:\t%ld dBm (%ld/4)", @""), (long)rssi, (long)bars]];
		}
	}

	return [lines count] ? [lines componentsJoinedByString:@"\n"] : nil;
}

-(void)bluetoothDisconnection:(IOBluetoothUserNotification*)note
							  device:(IOBluetoothDevice*)device
{
	// No extraInfo on disconnect: fields like battery level need a live connection and are
	// less reliably available by the time this fires. The device-type icon is still safe to
	// compute here (see -bluetoothName:connected:iconName:extraInfo: note above).
	if (HWGBTBoolForKey(HWG_BT_NOTIFY_DISCONNECT_KEY, YES)) {
		[self bluetoothName:[device name] connected:NO iconName:[self bluetoothIconNameForDevice:device] extraInfo:nil];
	}
	[note unregister];

}

-(void)bluetoothConnection:(IOBluetoothUserNotification*)note
						  device:(IOBluetoothDevice*)device
{
	[device registerForDisconnectNotification:self selector:@selector(bluetoothDisconnection:device:)];

	if (!starting || [delegate onLaunchEnabled]) {
		if (starting) {
			// A device already connected at launch is reported here synchronously, from
			// `-postRegistrationInit` (itself called from `-awakeFromNib` on the Preferences
			// window controller) — well before `-applicationDidFinishLaunching:` and before
			// the notification banner plumbing (`GrowlApplicationBridge`) has finished its
			// own async setup. Confirmed via logging that this path was reached correctly
			// (device detected, `onLaunchEnabled` true, `notifyWithName:` called) but no
			// banner ever appeared. Deferring a couple of seconds gives that infrastructure
			// time to finish initializing before the notification is actually posted — a
			// real, currently-connecting device (the non-`starting` path below) doesn't need
			// this, since by then the app has been running for a while.
			NSString *name = [device name];
			NSString *iconName = [self bluetoothIconNameForDevice:device];
			NSString *extraInfo = [self bluetoothExtraInfoForDevice:device];
			NSString *notifyKey = [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:[self bluetoothTypeIdentifierForDevice:device]];
			if (HWGBTBoolForKey(notifyKey, YES)) {
				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
					[self bluetoothName:name connected:YES iconName:iconName extraInfo:extraInfo];
				});
			}
		} else {
			NSString *notifyKey = [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:[self bluetoothTypeIdentifierForDevice:device]];
			if (HWGBTBoolForKey(notifyKey, YES)) {
				[self bluetoothName:[device name] connected:YES iconName:[self bluetoothIconNameForDevice:device] extraInfo:[self bluetoothExtraInfoForDevice:device]];
			}
		}
	}
}

#pragma mark HWGrowlPluginProtocol

// -delegate / -setDelegate: are auto-generated from the @property (weak) +
// @synthesize above (satisfies HWGrowlPluginProtocol). No manual accessors —
// hand-written ones could silently mask the property's weak qualifier.
-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Bluetooth Monitor", @"");
}
-(NSImage*)preferenceIcon {
	// Resolved fresh every call (not cached) since this is user-customizable via the Icons
	// tab's "Module Icon (Sidebar)" row — see the same note on AudioMonitor's -preferenceIcon.
	return HWGResolveIconNamed(@"HWGPrefsBluetooth-Module");
}
// F33: single generic handler for every per-field visibility checkbox. Each checkbox's
// `identifier` carries the NSUserDefaults key it controls.
-(IBAction)fieldToggleChanged:(NSButton*)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
}

-(NSButton *)checkboxWithKey:(NSString *)key title:(NSString *)title defaultOn:(BOOL)defaultOn {
	NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(fieldToggleChanged:)];
	box.identifier = key;
	box.state = HWGBTBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	return box;
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 560, 260)];
	// AppDelegate sizes this view once via -setFrameSize: to match the prefs window's
	// container, then never again — without an autoresizing mask this view (and its
	// visible tab box) stays whatever size it was created at even if the user later
	// resizes the Preferences window. Track the container's size going forward.
	tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	// --- Tab: General (pre-existing "Notification fields" content) ---
	// BUG FIX (17-ago-2026): was 190 — a fixed constant not tied to row count. Same risk class
	// confirmed live in Network Monitor's Wi-Fi tab (a row added without growing this renders
	// but doesn't respond to clicks, since this view's declared frame height is what actually
	// determines its on-screen size — it's never auto-resized to fit content later). Bumped
	// with margin after adding the "Advertised services (SDP)" row.
	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, tabs.bounds.size.width, 230)];

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notification fields", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;

	NSArray<NSButton*> *rows = @[
		[self checkboxWithKey:HWG_BT_SHOW_TYPE_KEY    title:NSLocalizedString(@"Device type (Keyboard, Mouse, Headphones…)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_BT_SHOW_PAIRED_KEY  title:NSLocalizedString(@"Paired state", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_BT_SHOW_ADDRESS_KEY title:NSLocalizedString(@"MAC address", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_BT_SHOW_BATTERY_KEY title:NSLocalizedString(@"Battery level (Apple accessories: AirPods, Magic Mouse/Keyboard/Trackpad)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_BT_SHOW_RSSI_KEY    title:NSLocalizedString(@"Signal strength (RSSI, while connected)", @"") defaultOn:NO],
		// Added 17-ago-2026 — OFF by default: SDP service names are often verbose/technical
		// (e.g. "AVRCP Target", "Handsfree Audio Gateway"), not something every user wants
		// cluttering the notification by default.
		[self checkboxWithKey:HWG_BT_SHOW_SERVICES_KEY title:NSLocalizedString(@"Advertised services (SDP)", @"") defaultOn:NO],
	];

	[v addSubview:header];
	[NSLayoutConstraint activateConstraints:@[
		[header.topAnchor     constraintEqualToAnchor:v.topAnchor constant:16],
		[header.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
	]];
	NSView *previous = header;
	for (NSButton *row in rows) {
		[v addSubview:row];
		[NSLayoutConstraint activateConstraints:@[
			[row.topAnchor     constraintEqualToAnchor:previous.bottomAnchor constant:10],
			[row.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
			[row.heightAnchor   constraintEqualToConstant:24],
		]];
		previous = row;
	}

	NSTabViewItem *generalItem = [[NSTabViewItem alloc] initWithIdentifier:@"general"];
	generalItem.label = NSLocalizedString(@"General", @"");
	generalItem.view = v;
	[tabs addTabViewItem:generalItem];

	// --- Tab: Icons (per-event icon overrides) ---
	CGFloat iconsPad = 16;
	CGFloat iconsWidth = tabs.bounds.size.width - 2 * iconsPad;

	HWGIconPickerView *iconPicker = [[HWGIconPickerView alloc] initWithIconSpecs:@[
		@[@"Module Icon (Sidebar)", @"HWGPrefsBluetooth-Module"],
		@[@"Computer", @"BT-TypeComputer", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Computer"]],
		@[@"Phone", @"BT-TypePhone", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Phone"]],
		@[@"Access Point", @"BT-TypeAccessPoint", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"AccessPoint"]],
		@[@"Wearable", @"BT-TypeWearable", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Wearable"]],
		@[@"Health", @"BT-TypeHealth", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Health"]],
		@[@"Keyboard", @"BT-TypeKeyboard", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Keyboard"]],
		@[@"Mouse", @"BT-TypeMouse", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Mouse"]],
		@[@"Combo", @"BT-TypeCombo", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Combo"]],
		@[@"Headset", @"BT-TypeHeadset", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Headset"]],
		@[@"Microphone", @"BT-TypeMicrophone", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Microphone"]],
		@[@"Speaker", @"BT-TypeSpeaker", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Speaker"]],
		@[@"Headphones", @"BT-TypeHeadphones", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Headphones"]],
		@[@"Connected (generic)", @"Bluetooth-On", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Other"]],
		@[@"Disconnected (generic)", @"Bluetooth-Off", HWG_BT_NOTIFY_DISCONNECT_KEY],
		// Added 18-ago-2026 — the adapter's own power state (System Settings/Control Center
		// toggle), distinct from any device connect/disconnect above. Own dedicated icons
		// (Bluetooth-Radio-On/-Off), not the "Connected/Disconnected (generic)" ones above —
		// see the key defines' doc comment for why sharing those would be a real conflict.
		@[@"Bluetooth Radio On", @"Bluetooth-Radio-On", HWG_BT_NOTIFY_RADIO_ON_KEY, @NO],
		@[@"Bluetooth Radio Off", @"Bluetooth-Radio-Off", HWG_BT_NOTIFY_RADIO_OFF_KEY, @NO],
		// Reference/customization only (13-ago-2026, feedback del usuario) — the connect
		// notification keeps the device-type icon above, it does NOT switch to one of these.
		// No notifyKey: nothing separate to enable/disable here, just icon customization.
		@[@"Signal — No Signal", @"Bluetooth-Signal-0"],
		@[@"Signal — Weak", @"Bluetooth-Signal-1"],
		@[@"Signal — Fair", @"Bluetooth-Signal-2"],
		@[@"Signal — Good", @"Bluetooth-Signal-3"],
		@[@"Signal — Excellent", @"Bluetooth-Signal-4"],
	] width:iconsWidth];
	iconPicker.translatesAutoresizingMaskIntoConstraints = YES;
	iconPicker.frame = NSMakeRect(0, 0, iconsWidth, 0);
	CGFloat iconPickerH = iconPicker.fittingSize.height;

	NSTextField *iconsHeader = [NSTextField labelWithString:NSLocalizedString(@"Notification icons", @"")];
	iconsHeader.font = [NSFont boldSystemFontOfSize:12];
	iconsHeader.textColor = [NSColor secondaryLabelColor];
	iconsHeader.translatesAutoresizingMaskIntoConstraints = YES;
	CGFloat iconsHeaderH = iconsHeader.fittingSize.height;
	CGFloat iconsGap = 12;

	// Explains why the 5 "Signal — …" rows above have no checkbox, since users naturally
	// expect one there given every other row in this picker has it (feedback 13-ago-2026).
	// Per-level RSSI notifications are technically possible but not implemented: RSSI
	// fluctuates continuously (multipath/distance jitter, no hysteresis smoothing applied
	// to it the way WiFi bars are), so a naive per-level trigger would fire repeatedly as
	// the value crosses a threshold back and forth. Tracked as pending work.
	NSTextField *signalNote = [NSTextField wrappingLabelWithString:NSLocalizedString(@"Note: the 5 signal-strength icons above have no notification checkbox — they only customize which image is shown at each RSSI level while “Signal strength” is enabled in General. Per-level signal notifications (e.g. “notify when signal drops to Weak”) are technically possible but not implemented yet, pending hysteresis logic to avoid notification spam from RSSI’s natural fluctuation.", @"")];
	signalNote.font = [NSFont systemFontOfSize:11];
	signalNote.textColor = [NSColor tertiaryLabelColor];
	signalNote.translatesAutoresizingMaskIntoConstraints = YES;
	signalNote.preferredMaxLayoutWidth = iconsWidth;
	CGFloat signalNoteH = signalNote.fittingSize.height;

	NSView *iconsContent = [[HWGFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, tabs.bounds.size.width, iconsHeaderH + iconsGap + iconPickerH + iconsGap + signalNoteH + 2 * iconsPad)];
	iconsHeader.frame = NSMakeRect(iconsPad, iconsPad, iconsWidth, iconsHeaderH);
	[iconsContent addSubview:iconsHeader];
	iconPicker.frame = NSMakeRect(iconsPad, iconsPad + iconsHeaderH + iconsGap, iconsWidth, iconPickerH);
	[iconsContent addSubview:iconPicker];
	signalNote.frame = NSMakeRect(iconsPad, iconsPad + iconsHeaderH + iconsGap + iconPickerH + iconsGap, iconsWidth, signalNoteH);
	[iconsContent addSubview:signalNote];

	NSScrollView *iconsScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, tabs.bounds.size.width, 320)];
	iconsScroll.hasVerticalScroller = YES;
	iconsScroll.autohidesScrollers = YES;
	iconsScroll.drawsBackground = NO;
	iconsScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	iconsScroll.documentView = iconsContent;

	NSTabViewItem *iconsItem = [[NSTabViewItem alloc] initWithIdentifier:@"icons"];
	iconsItem.label = NSLocalizedString(@"Icons", @"");
	iconsItem.view = iconsScroll;
	[tabs addTabViewItem:iconsItem];

	prefsView = tabs;
	return prefsView;
}

#pragma mark HWGrowlPluginNotifierProtocol

-(NSArray*)noteNames {
	return [NSArray arrayWithObjects:@"BluetoothConnected", @"BluetoothDisconnected", @"BluetoothRadioOn", @"BluetoothRadioOff", nil];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Bluetooth Connected", @""), @"BluetoothConnected",
			  NSLocalizedString(@"Bluetooth Disconnected", @""), @"BluetoothDisconnected",
			  NSLocalizedString(@"Bluetooth Radio On", @""), @"BluetoothRadioOn",
			  NSLocalizedString(@"Bluetooth Radio Off", @""), @"BluetoothRadioOff", nil];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Sent when a Bluetooth Device is connected", @""), @"BluetoothConnected",
			  NSLocalizedString(@"Sent when a Bluetooth Device is disconnected", @""), @"BluetoothDisconnected",
			  NSLocalizedString(@"Sent when the Bluetooth radio itself is turned on (System Settings/Control Center toggle)", @""), @"BluetoothRadioOn",
			  NSLocalizedString(@"Sent when the Bluetooth radio itself is turned off", @""), @"BluetoothRadioOff", nil];
}
-(NSArray*)defaultNotifications {
	return [NSArray arrayWithObjects:@"BluetoothConnected", @"BluetoothDisconnected", nil];
}

@end
