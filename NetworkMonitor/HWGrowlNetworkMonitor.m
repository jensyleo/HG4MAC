//
//  HWGrowlNetworkMonitor.m
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/2/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

// compile with ARC: -fobjc-arc
#import "HWGrowlNetworkMonitor.h"
#import "GrowlNetworkUtilities.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <CoreWLAN/CoreWLAN.h>
#import <CoreLocation/CoreLocation.h>
#import <Network/Network.h>

#include <sys/socket.h>
#include <sys/sockio.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <net/if_media.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <ifaddrs.h>

/* @"Link Status" == 1 seems to mean disconnected */
#define AIRPORT_DISCONNECTED 1

// F20: user-configurable WiFi signal poll interval (seconds). Default 12, clamped 5–60.
#define HWG_WIFI_POLL_KEY     @"HWGWifiSignalPollInterval"
#define HWG_WIFI_POLL_DEFAULT 12.0
#define HWG_WIFI_POLL_MIN     5.0
#define HWG_WIFI_POLL_MAX     60.0

static struct ifmedia_description ifm_subtype_ethernet_descriptions[] = IFM_SUBTYPE_ETHERNET_DESCRIPTIONS;
static struct ifmedia_description ifm_shared_option_descriptions[] = IFM_SHARED_OPTION_DESCRIPTIONS;

typedef enum {
	HWGAirPortInterface,
	HWGEthernetInterface,
} NetworkInterfaceType;

@interface HWGrowlNetworkInterfaceStatus : NSObject;

@property (nonatomic, strong) NSString *interface;
@property (nonatomic, strong) NSDictionary *status;
@property (nonatomic, assign) NetworkInterfaceType type;

-(id)initForInterface:(NSString*)anInterface ofType:(NetworkInterfaceType)aType withStatus:(NSDictionary*)theStatus;

@end

@implementation HWGrowlNetworkInterfaceStatus

@synthesize interface;
@synthesize status;
@synthesize type;

-(id)initForInterface:(NSString *)anInterface 
					ofType:(NetworkInterfaceType)aType 
			  withStatus:(NSDictionary *)theStatus 
{
	if((self = [super init])){
		self.interface = anInterface;
		self.type = aType;
		self.status = theStatus;
	}
	return self;
}

// ARC: no manual dealloc needed (interface/status are strong, auto-released).

@end

@interface HWGrowlNetworkMonitor () <CWEventDelegate, CLLocationManagerDelegate>

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;

// Core Foundation pointers — ARC does NOT manage these; keep assign.
@property (nonatomic, assign) SCDynamicStoreRef dynStore;
@property (nonatomic, assign) CFRunLoopSourceRef rlSrc;

@property (nonatomic, strong) NSMutableDictionary *networkInterfaceStates;
@property (nonatomic, strong) NSString *previousIPCombined;

// F20/P10: Ethernet (wired) link up/down is detected via NWPathMonitor (modern
// Network.framework) instead of the legacy SCDynamicStore Link keys. SCDynamicStore is
// still used for IP addresses / gateway.
@property (nonatomic, strong) nw_path_monitor_t pathMonitor;
@property (nonatomic, strong) NSMutableSet *trackedWiredInterfaces;
@property (nonatomic, assign) BOOL nwPathPrimed;

// Remembers, per interface, whether it had recognized Ethernet media when it came up,
// so the Link-Down notification uses the same icon family as the Link-Up (the media is
// often unreadable once the interface is gone).
@property (nonatomic, strong) NSMutableDictionary *interfaceIsEthernet;

// CoreWLAN: replaces the deprecated SCDynamicStore AirPort keys for WiFi events.
// weak: the framework owns the +sharedWiFiClient singleton; we don't.
@property (nonatomic, weak) CWWiFiClient *wifiClient;
@property (nonatomic, strong) NSString *lastReportedSSID;

// F20: track the last reported WiFi signal bar level (0–4; -1 = not connected / unknown)
// so we notify only when the LEVEL changes, plus a cooldown to avoid threshold flapping.
@property (nonatomic, assign) NSInteger lastReportedWifiBars;
@property (nonatomic, strong) NSDate *lastSignalNoteTime;
@property (nonatomic, strong) NSTimer *signalPollTimer;

// Preferences pane (built programmatically — no nib) for the WiFi signal poll interval.
@property (nonatomic, strong) NSView *prefsView;
@property (nonatomic, weak) NSTextField *intervalValueLabel;

// CoreLocation: required since macOS 10.14 to read the Wi-Fi SSID
@property (nonatomic, strong) CLLocationManager *locationManager;

@end

@implementation HWGrowlNetworkMonitor

@synthesize delegate;
@synthesize rlSrc;
@synthesize dynStore;
@synthesize networkInterfaceStates;
@synthesize previousIPCombined;
@synthesize interfaceIsEthernet;
@synthesize pathMonitor;
@synthesize trackedWiredInterfaces;
@synthesize nwPathPrimed;
@synthesize wifiClient;
@synthesize lastReportedSSID;
@synthesize lastReportedWifiBars;
@synthesize lastSignalNoteTime;
@synthesize signalPollTimer;
@synthesize prefsView;
@synthesize intervalValueLabel;
@synthesize locationManager;

-(id)init {
	if((self = [super init])){
		self.previousIPCombined = nil;
		self.networkInterfaceStates = [NSMutableDictionary dictionary];
		self.interfaceIsEthernet = [NSMutableDictionary dictionary];
		self.trackedWiredInterfaces = [NSMutableSet set];
		self.lastReportedWifiBars = -1;

		[self startObserving];
		[self startWiFiMonitoring];
		[self requestLocationForSSID];
	}
	return self;
}

// Reading the Wi-Fi SSID requires Location authorization since macOS 10.14.
// We ask once; if granted, [CWInterface ssid] starts returning the real name.
-(void)requestLocationForSSID {
	self.locationManager = [[CLLocationManager alloc] init];
	self.locationManager.delegate = self;
	[self.locationManager requestWhenInUseAuthorization];
}

-(void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
	// When the user grants access, refresh the WiFi state so the SSID we now
	// can read gets reflected (and update the IP notification's interface info).
	CLAuthorizationStatus status = manager.authorizationStatus;
	if (status == kCLAuthorizationStatusAuthorizedAlways ||
	    status == kCLAuthorizationStatusAuthorized) {
		CWInterface *iface = [self.wifiClient interface];
		if (iface && [iface ssid]) {
			// Update our cached name so a re-read shows the real SSID next time.
			self.lastReportedSSID = [iface ssid];
		}
	}
}

-(void)dealloc {
	// ARC handles the ObjC ivars; keep the non-memory teardown (cancel timers,
	// CF teardown, stop CoreWLAN monitoring, drop delegates).
	[NSObject cancelPreviousPerformRequestsWithTarget:self];
	[signalPollTimer invalidate];
	if (pathMonitor) nw_path_monitor_cancel(pathMonitor);

	if (rlSrc)
		CFRunLoopRemoveSource(CFRunLoopGetMain(), rlSrc, kCFRunLoopDefaultMode);
   if (dynStore)
		CFRelease(dynStore);

	if (wifiClient) {
		[wifiClient stopMonitoringAllEventsAndReturnError:NULL];
		wifiClient.delegate = nil;
	}

	locationManager.delegate = nil;
}

#pragma mark CoreWLAN — WiFi event monitoring (replaces deprecated SCDynamicStore AirPort keys)

-(void)startWiFiMonitoring {
	self.wifiClient = [CWWiFiClient sharedWiFiClient];
	self.wifiClient.delegate = self;

	NSError *err = nil;
	[self.wifiClient startMonitoringEventWithType:CWEventTypeLinkDidChange error:&err];
	if (err) NSLog(@"HWG WiFi linkDidChange monitor error: %@", err);
	err = nil;
	[self.wifiClient startMonitoringEventWithType:CWEventTypeSSIDDidChange error:&err];
	if (err) NSLog(@"HWG WiFi ssidDidChange monitor error: %@", err);
	err = nil;
	[self.wifiClient startMonitoringEventWithType:CWEventTypePowerDidChange error:&err];
	if (err) NSLog(@"HWG WiFi powerDidChange monitor error: %@", err);
	err = nil;
	[self.wifiClient startMonitoringEventWithType:CWEventTypeBSSIDDidChange error:&err];
	if (err) NSLog(@"HWG WiFi bssidDidChange monitor error: %@", err);
	err = nil;
	[self.wifiClient startMonitoringEventWithType:CWEventTypeModeDidChange error:&err];
	if (err) NSLog(@"HWG WiFi modeDidChange monitor error: %@", err);

	// F20 (Plan B): CWEventTypeLinkQualityDidChange does NOT fire on macOS Tahoe, so poll
	// the RSSI on a timer to detect signal-level changes. Interval is user-configurable.
	[self restartSignalPollTimer];

	// Initialize lastReportedSSID from the CURRENT state. If WiFi is already
	// connected when the app launches, no change event will fire — without
	// this, the first disconnect would be ignored (lastReportedSSID == nil).
	CWInterface *iface = [self.wifiClient interface];
	if (iface && [iface powerOn] && [iface interfaceMode] == kCWInterfaceModeStation) {
		self.lastReportedSSID = [iface ssid] ?: NSLocalizedString(@"Wi-Fi", @"");
	}
}

-(void)powerStateDidChangeForWiFiInterfaceWithName:(NSString *)interfaceName {
	[self handleWiFiStateChangeForInterface:interfaceName];
}

-(void)bssidDidChangeForWiFiInterfaceWithName:(NSString *)interfaceName {
	[self handleWiFiStateChangeForInterface:interfaceName];
}

-(void)modeDidChangeForWiFiInterfaceWithName:(NSString *)interfaceName {
	[self handleWiFiStateChangeForInterface:interfaceName];
}

-(void)handleWiFiStateChangeForInterface:(NSString *)interfaceName {
	// CoreWLAN delivers CWEventDelegate callbacks on its own internal queue, not the
	// main thread. This method mutates lastReportedSSID and posts notifications that
	// build NSImages / touch UI, so marshal the whole thing to main to avoid races.
	if (![NSThread isMainThread]) {
		dispatch_async(dispatch_get_main_queue(), ^{ [self handleWiFiStateChangeForInterface:interfaceName]; });
		return;
	}

	CWInterface *iface = [self.wifiClient interfaceWithName:interfaceName];
	if (!iface) return;

	// interfaceMode is the OS's operational state of the radio and does NOT
	// require Location permission (unlike ssid/bssid which return nil without
	// it). kCWInterfaceModeStation = associated to an access point.
	BOOL              poweredOn = [iface powerOn];
	CWInterfaceMode   mode      = [iface interfaceMode];
	BOOL              connected = poweredOn && (mode == kCWInterfaceModeStation);

	NSString *ssid     = [iface ssid];      // nil if Location permission denied
	NSString *bssidStr = [iface bssid];     // nil if Location permission denied

	if (connected) {
		NSString *displayName = ssid ?: NSLocalizedString(@"Wi-Fi", @"");
		if (lastReportedSSID && [lastReportedSSID isEqualToString:displayName])
			return; // already reported this state
		self.lastReportedSSID = displayName;
		NSData *bssidData = nil;
		if (bssidStr) {
			unsigned int b[6] = {0};
			sscanf([bssidStr UTF8String], "%x:%x:%x:%x:%x:%x",
			       &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]);
			unsigned char bytes[6] = {(unsigned char)b[0], (unsigned char)b[1],
			                          (unsigned char)b[2], (unsigned char)b[3],
			                          (unsigned char)b[4], (unsigned char)b[5]};
			bssidData = [NSData dataWithBytes:bytes length:6];
		}
		[self airportConnected:displayName bssid:bssidData];
		// IPv4 often arrives after the WiFi link comes up (DHCP completes
		// later than IPv6 SLAAC). The SCDynamicStore IPv4 key change does
		// not always fire reliably on macOS Tahoe, so we manually re-check
		// IPs a couple of times to pick up the late IPv4 address. Use
		// dispatch_after on the main queue (not performSelector:afterDelay:)
		// because this method may run off the main thread.
		__weak HWGrowlNetworkMonitor *blockSelf = self;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
		               dispatch_get_main_queue(), ^{ [blockSelf updateIP]; });
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
		               dispatch_get_main_queue(), ^{ [blockSelf updateIP]; });
	} else {
		if (lastReportedSSID == nil)
			return; // already disconnected
		NSString *previousName = ([lastReportedSSID length] > 0)
		    ? lastReportedSSID
		    : NSLocalizedString(@"Wi-Fi", @"");
		self.lastReportedSSID = nil;
		self.lastReportedWifiBars = -1;   // re-baseline signal level on next connect (F20)
		[self airportDisconnected:previousName];
	}
}

-(void)linkDidChangeForWiFiInterfaceWithName:(NSString *)interfaceName {
	[self handleWiFiStateChangeForInterface:interfaceName];
}

-(void)ssidDidChangeForWiFiInterfaceWithName:(NSString *)interfaceName {
	[self handleWiFiStateChangeForInterface:interfaceName];
}

// F20: CoreWLAN link-quality events carry the live RSSI. Report only when the signal
// BAR LEVEL changes (RSSI fluctuates constantly), with direction, plus a cooldown so a
// value hovering at a threshold doesn't spam.
// F20 (Plan B): macOS Tahoe does NOT deliver CWEventTypeLinkQualityDidChange, so we poll
// the RSSI on a timer instead. Fires every ~12s (App Nap is disabled, so it's reliable),
// reads the live RSSI, and reports only when the signal BAR LEVEL changes.
// Configured WiFi signal poll interval (seconds), clamped to [MIN, MAX], default if unset.
-(NSTimeInterval)signalPollInterval {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:HWG_WIFI_POLL_KEY];
	NSTimeInterval v = stored ? [[NSUserDefaults standardUserDefaults] doubleForKey:HWG_WIFI_POLL_KEY] : HWG_WIFI_POLL_DEFAULT;
	if (v < HWG_WIFI_POLL_MIN) v = HWG_WIFI_POLL_MIN;
	if (v > HWG_WIFI_POLL_MAX) v = HWG_WIFI_POLL_MAX;
	return v;
}

-(void)restartSignalPollTimer {
	[signalPollTimer invalidate];
	self.signalPollTimer = [NSTimer scheduledTimerWithTimeInterval:[self signalPollInterval]
	                                                        target:self
	                                                      selector:@selector(pollWifiSignal:)
	                                                      userInfo:nil
	                                                       repeats:YES];
}

-(void)pollWifiSignal:(NSTimer *)timer {
	CWInterface *iface = [self.wifiClient interface];
	if (!(iface && [iface powerOn] && [iface interfaceMode] == kCWInterfaceModeStation)) {
		self.lastReportedWifiBars = -1;   // not associated → re-baseline on reconnect
		return;
	}
	NSInteger rssi = [iface rssiValue];
	if (rssi == 0) return;

	NSInteger bars = [self wifiBarsForRSSI:rssi];

	if (lastReportedWifiBars < 0) {   // first sample after connect → baseline, don't notify
		self.lastReportedWifiBars = bars;
		return;
	}
	if (bars == lastReportedWifiBars) return;   // no level change

	// Rate-limit so a value hovering at a threshold doesn't spam. Don't update the baseline
	// while in cooldown, so a later poll still catches the net change (and flapping back to
	// the old level self-cancels since then bars == lastReportedWifiBars).
	const NSTimeInterval cooldown = 20.0;
	if (lastSignalNoteTime && [[NSDate date] timeIntervalSinceDate:lastSignalNoteTime] < cooldown)
		return;

	BOOL improved = (bars > lastReportedWifiBars);
	NSString *ssid = [iface ssid] ?: (lastReportedSSID ?: NSLocalizedString(@"Wi-Fi", @""));
	NSString *arrow = improved ? @"↑" : @"↓";
	NSString *dir = improved ? NSLocalizedString(@"improved", @"WiFi signal got stronger")
	                         : NSLocalizedString(@"degraded", @"WiFi signal got weaker");
	NSString *desc = [NSString stringWithFormat:
		NSLocalizedString(@"%@\nSignal %@ %@ (%ld/4)", @"network name, arrow, improved/degraded, bars"),
		ssid, arrow, dir, (long)bars];
	NSData *iconData = [[NSImage imageNamed:[NSString stringWithFormat:@"Network-Wifi-%ld", (long)bars]] TIFFRepresentation];

	[delegate notifyWithName:@"AirportSignalChange"
						 title:NSLocalizedString(@"Wi-Fi Signal Changed", @"")
				 description:desc
						  icon:iconData
		  identifierString:@"HWGrowlAirPortSignal"
			  contextString:nil
						plugin:self];

	self.lastReportedWifiBars = bars;
	self.lastSignalNoteTime = [NSDate date];
}

-(void)fireOnLaunchNotes {
	[self interateInterfaces];
	[self fireCurrentWiFiState];
}

// At launch (only called when "Show existing" is enabled), announce the WiFi we're
// ALREADY connected to. CoreWLAN only delivers CHANGE events, so an already-up
// connection would otherwise never be reported — unlike volumes / IP, which do
// report at launch. startWiFiMonitoring only records lastReportedSSID silently.
-(void)fireCurrentWiFiState {
	CWInterface *iface = [self.wifiClient interface];
	if (!(iface && [iface powerOn] && [iface interfaceMode] == kCWInterfaceModeStation))
		return;

	NSString *ssid        = [iface ssid];   // nil if Location permission denied
	NSString *displayName = ssid ?: NSLocalizedString(@"Wi-Fi", @"");
	NSString *bssidStr    = [iface bssid];
	NSData   *bssidData   = nil;
	if (bssidStr) {
		unsigned int b[6] = {0};
		sscanf([bssidStr UTF8String], "%x:%x:%x:%x:%x:%x",
		       &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]);
		unsigned char bytes[6] = {(unsigned char)b[0], (unsigned char)b[1],
		                          (unsigned char)b[2], (unsigned char)b[3],
		                          (unsigned char)b[4], (unsigned char)b[5]};
		bssidData = [NSData dataWithBytes:bytes length:6];
	}
	self.lastReportedSSID = displayName;
	[self airportConnected:displayName bssid:bssidData];
}

-(void)setupDynamicStore
{
   if(dynStore != NULL)
      return;
   
   SCDynamicStoreContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
   
	dynStore = SCDynamicStoreCreate(kCFAllocatorDefault,
                                   CFBundleGetIdentifier(CFBundleGetMainBundle()),
                                   scCallback,
                                   &context);
	if (!dynStore) {
		NSLog(@"SCDynamicStoreCreate() failed: %s", SCErrorString(SCError()));
	}
   
   rlSrc = SCDynamicStoreCreateRunLoopSource(kCFAllocatorDefault, dynStore, 0);
	CFRunLoopAddSource(CFRunLoopGetMain(), rlSrc, kCFRunLoopDefaultMode);
   CFRelease(rlSrc);
}

-(void)startObserving
{
   [self setupDynamicStore];
	
    // AirPort key removed — WiFi events are now handled by CoreWLAN
    // (CWWiFiClient). Keeping it would fire duplicate disconnect notifications.
    // Wired/Ethernet link up/down is now detected via NWPathMonitor; SCDynamicStore only
    // watches the IP keys (the legacy ".../Link" key is no longer needed here).
    NSArray *watchedKeys = [NSArray arrayWithObjects:@"State:/Network/Global/IPv4", @"State:/Network/Global/IPv6", nil];
	if (!SCDynamicStoreSetNotificationKeys(dynStore,
                                          NULL,
                                          (__bridge CFArrayRef)watchedKeys))
   {
		NSLog(@"SCDynamicStoreSetNotificationKeys() failed: %s", SCErrorString(SCError()));
		CFRelease(dynStore);
		dynStore = NULL;
	}

	[self startWiredPathMonitor];
}

// P10: modern replacement for the legacy SCDynamicStore ".../Link" watching. NWPathMonitor
// reports the set of available WIRED interfaces; we diff it across updates to detect
// Ethernet/USB-ethernet link up (interface appears) and down (interface disappears), then
// feed the existing updateInterface: flow (which keeps the media/icon logic + notifications).
-(void)startWiredPathMonitor {
	self.pathMonitor = nw_path_monitor_create_with_type(nw_interface_type_wired);
	nw_path_monitor_set_queue(pathMonitor, dispatch_get_main_queue());
	__weak HWGrowlNetworkMonitor *weakSelf = self;
	nw_path_monitor_set_update_handler(pathMonitor, ^(nw_path_t path) {
		[weakSelf handleWiredPath:path];
	});
	nw_path_monitor_start(pathMonitor);
}

-(void)handleWiredPath:(nw_path_t)path {
	NSMutableSet *now = [NSMutableSet set];
	nw_path_enumerate_interfaces(path, ^bool(nw_interface_t iface) {
		if (nw_interface_get_type(iface) == nw_interface_type_wired) {
			const char *n = nw_interface_get_name(iface);
			if (n) [now addObject:[NSString stringWithUTF8String:n]];
		}
		return true;
	});

	if (!nwPathPrimed) {
		// First update = current state at launch. Report existing wired links only if
		// "show existing" is enabled; otherwise seed the state silently so a later real
		// change still fires correctly.
		self.nwPathPrimed = YES;
		BOOL announce = [delegate onLaunchEnabled];
		for (NSString *ifname in now) {
			if (announce) {
				[self updateInterface:ifname forType:HWGEthernetInterface withStatus:@{@"Active": @1}];
			} else {
				HWGrowlNetworkInterfaceStatus *st = [[HWGrowlNetworkInterfaceStatus alloc]
					initForInterface:ifname ofType:HWGEthernetInterface withStatus:@{@"Active": @1}];
				[networkInterfaceStates setObject:st forKey:ifname];
			}
		}
		[trackedWiredInterfaces setSet:now];
		return;
	}

	NSMutableSet *added = [now mutableCopy];
	[added minusSet:trackedWiredInterfaces];
	NSMutableSet *removed = [trackedWiredInterfaces mutableCopy];
	[removed minusSet:now];
	for (NSString *ifname in added)
		[self updateInterface:ifname forType:HWGEthernetInterface withStatus:@{@"Active": @1}];
	for (NSString *ifname in removed)
		[self updateInterface:ifname forType:HWGEthernetInterface withStatus:@{@"Active": @0}];
	[trackedWiredInterfaces setSet:now];
}

-(void)updateInterface:(NSString*)interface forType:(NetworkInterfaceType)type withStatus:(NSDictionary*)status {
	HWGrowlNetworkInterfaceStatus *new = [[HWGrowlNetworkInterfaceStatus alloc] initForInterface:interface
																														ofType:type
																												  withStatus:status];
	if(type == HWGAirPortInterface)
		[self updateAirportWithInterface:new];
	else if(type == HWGEthernetInterface)
		[self updateLinkWithInterface:new];
	
	[networkInterfaceStates setObject:new forKey:interface];
}

-(void)updateAirportWithInterface:(HWGrowlNetworkInterfaceStatus*)interface {
	NSString *interfaceString = [interface interface];
	NSDictionary *newValue = [interface status];
	NSDictionary *existing = [(HWGrowlNetworkInterfaceStatus*)[networkInterfaceStates objectForKey:interfaceString] status];
	//	NSLog(CFSTR("AirPort event"));
	
	NSData *newBSSID = nil;
	if (newValue)
		newBSSID = [newValue objectForKey:@"BSSID"];
	
	NSData *oldBSSID = nil;
	if (existing)
		oldBSSID = [existing objectForKey:@"BSSID"];
		
	if (newValue && ![oldBSSID isEqualToData:newBSSID] && !(newBSSID && oldBSSID && CFEqual((__bridge CFTypeRef)oldBSSID, (__bridge CFTypeRef)newBSSID))) {
		NSNumber *linkStatus = [newValue objectForKey:@"Link Status"];
		NSNumber *powerStatus = [newValue objectForKey:@"Power Status"];
		if (linkStatus || powerStatus) {
			int status = 0;
			if (linkStatus) {
				status = [linkStatus intValue];
			} else if (powerStatus) {
				status = [powerStatus intValue];
				status = !status;
			}
			NSString *networkName = nil;
			if (status == AIRPORT_DISCONNECTED) {
				networkName = [existing objectForKey:@"SSID_STR"];
				if (!networkName)
					networkName = [existing objectForKey:@"SSID"];
				if(networkName)
                    [self airportDisconnected:networkName];
			} else {
				networkName = [newValue objectForKey:@"SSID_STR"];
				if (!networkName)
					networkName = [newValue objectForKey:@"SSID"];
				if(networkName && newBSSID){
					[self airportConnected:networkName bssid:newBSSID];
				}
			}
		}
	}
}

-(void)airportDisconnected:(NSString*)networkName {
	NSData *iconData = [[NSImage imageNamed:@"Network-Wifi-Off"] TIFFRepresentation];
    [delegate notifyWithName:@"AirportDisconnected"
							 title:NSLocalizedString(@"AirPort Disconnected", @"")
					 description:[NSString stringWithFormat:NSLocalizedString(@"Left network %@.", @""), networkName]
							  icon:iconData
			  identifierString:@"HWGrowlAirPort"
				  contextString:nil 
							plugin:self];
}

// Map a Wi-Fi RSSI (dBm — negative, closer to 0 is stronger) to a bar level 0–4.
// rssi == 0 means "unavailable" → level 0 (the all-gray "no signal" icon).
-(NSInteger)wifiBarsForRSSI:(NSInteger)rssi {
	if (rssi == 0)        return 0;   // unavailable → gray "no signal" (Network-Wifi-0)
	else if (rssi >= -55) return 4;
	else if (rssi >= -65) return 3;
	else if (rssi >= -73) return 2;
	else if (rssi >= -80) return 1;
	else                  return 0;
}

// Icon name for the current signal. rssiValue does NOT require Location permission.
-(NSString*)wifiIconNameForCurrentSignal {
	CWInterface *iface = [self.wifiClient interface];
	NSInteger rssi = iface ? [iface rssiValue] : 0;
	return [NSString stringWithFormat:@"Network-Wifi-%ld", (long)[self wifiBarsForRSSI:rssi]];
}

-(void)airportConnected:(NSString*)name bssid:(NSData*)data {
	// BSSID is nil when Location permission is denied (macOS 10.14+). Build a
	// description with whatever info we have, never deref a NULL buffer.
	NSString *description = nil;
	if (data && [data length] >= 6) {
		const unsigned char *bssidBytes = [data bytes];
		NSString *bssid = [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",
								 bssidBytes[0], bssidBytes[1], bssidBytes[2],
								 bssidBytes[3], bssidBytes[4], bssidBytes[5]];
		description = [NSString stringWithFormat:NSLocalizedString(@"Joined network.\nSSID:\t\t%@\nBSSID:\t%@", ""),
						   name, bssid];
	} else {
		description = [NSString stringWithFormat:NSLocalizedString(@"Joined network %@.", @""), name];
	}
	
    
	NSData *iconData = [[NSImage imageNamed:[self wifiIconNameForCurrentSignal]] TIFFRepresentation];

	[delegate notifyWithName:@"AirportConnected"
							 title:NSLocalizedString(@"AirPort Connected", @"")
					 description:description
							  icon:iconData
			  identifierString:@"HWGrowlAirPort"
				  contextString:nil
							plugin:self];
}

-(void)updateLinkWithInterface:(HWGrowlNetworkInterfaceStatus*)interface {
	NSString *interfaceString = [interface interface];
	NSDictionary *newValue = [interface status];
	NSDictionary *existing = [(HWGrowlNetworkInterfaceStatus*)[networkInterfaceStates objectForKey:interfaceString] status];
	int newActive = [[newValue objectForKey:@"Active"] intValue];
	int oldActive = [[existing objectForKey:@"Active"] intValue];
	
	NSString *noteName = nil;
	NSString *noteTitle = nil;
	NSString *noteDescription = nil;
	NSString *imageName = nil;
	if (newActive && !oldActive) {
		// Use the Ethernet connector icon only for interfaces with a recognized Ethernet
		// media (e.g. "1000baseT/full-duplex"); unidentified interfaces (media "Unknown"
		// or unreadable — e.g. an iPhone/USB net interface) get a generic interface icon.
		NSString *media = [self getMediaForInterface:interfaceString];
		BOOL isEthernet = (media != nil && ![media hasPrefix:@"Unknown"]);
		[interfaceIsEthernet setObject:@(isEthernet) forKey:interfaceString];
		noteName = @"NetworkLinkUp";
		noteTitle = NSLocalizedString(@"Network Link Up", @"");
		noteDescription = [NSString stringWithFormat:
								 NSLocalizedString(@"Interface:\t%@\nMedia:\t%@", "The first %@ will be replaced with the interface (en0, en1, etc) second %@ will be replaced by a description of the Ethernet media such as '100BT/full-duplex'"),
								 interfaceString,
								 media ?: NSLocalizedString(@"Unknown", @"")];
		imageName = isEthernet ? @"Network-Ethernet-On" : @"Network-Interface-On";
	} else if (!newActive && oldActive) {
		// Match the icon family chosen when the interface came up (media is often
		// unreadable once it's down). Default to the generic interface icon.
		BOOL isEthernet = [[interfaceIsEthernet objectForKey:interfaceString] boolValue];
		[interfaceIsEthernet removeObjectForKey:interfaceString];
		noteName = @"NetworkLinkDown";
		noteTitle = NSLocalizedString(@"Network Link Down", @"");
		noteDescription = [NSString stringWithFormat:NSLocalizedString(@"Interface:\t%@", nil), interfaceString];
		imageName = isEthernet ? @"Network-Ethernet-Off" : @"Network-Interface-Off";
	}
	
	NSData *iconData = [[NSImage imageNamed:imageName] TIFFRepresentation];
   
	if(noteName){
		[delegate notifyWithName:noteName
								 title:noteTitle
						 description:noteDescription
								  icon:iconData
				  identifierString:@"HWGrowlNetworkLink"
					  contextString:nil
								plugin:self];
	}
}

/* TO DO: REWRITE ME WITH BETTER METHODS OF GETTING INFO */
- (NSString *)getMediaForInterface:(NSString*)interfaceString {
	// This is all made by looking through Darwin's src/network_cmds/ifconfig.tproj.
	// There's no pretty way to get media stuff; I've stripped it down to the essentials
	// for what I'm doing.
	
	const char *interface = [interfaceString UTF8String];
	size_t length = strlen(interface);
	if (length >= IFNAMSIZ)
		NSLog(@"Interface name too long");
	
	int s = socket(AF_INET, SOCK_DGRAM, 0);
	if (s < 0) {
		NSLog(@"Can't open datagram socket");
		return NULL;
	}
	struct ifmediareq ifmr;
	memset(&ifmr, 0, sizeof(ifmr));
	strncpy(ifmr.ifm_name, interface, sizeof(ifmr.ifm_name));
	
	if (ioctl(s, SIOCGIFMEDIA, (caddr_t)&ifmr) < 0) {
		// Media not supported.
		close(s);
		return NULL;
	}
	
	close(s);
	
	// Now ifmr.ifm_current holds the selected type (probably auto-select)
	// ifmr.ifm_active holds details (100baseT <full-duplex> or similar)
	// We only want the ifm_active bit.
	
	const char *type = "Unknown";
	
	// We'll only look in the Ethernet list. I don't care about anything else.
	struct ifmedia_description *desc;
	for (desc = ifm_subtype_ethernet_descriptions; desc->ifmt_string; ++desc) {
		if (IFM_SUBTYPE(ifmr.ifm_active) == desc->ifmt_word) {
			type = desc->ifmt_string;
			break;
		}
	}
	
	NSMutableString *options = nil;
	
	// And fill in the duplex settings.
	for (desc = ifm_shared_option_descriptions; desc->ifmt_string; desc++) {
		if (ifmr.ifm_active & desc->ifmt_word) {
			if (options) {
				[options appendFormat:@",%s", desc->ifmt_string];
			} else {
				options = [NSMutableString stringWithUTF8String:desc->ifmt_string];
			}
		}
	}
	
	NSString *media;
	if (options) {
		media = [NSString stringWithFormat:@"%s <%@>",
					type,
					options];
	} else {
		media = [NSString stringWithUTF8String:type];
	}
	
	return media;
}

// Counts the number of leading 1-bits in a 32-bit IPv4 netmask.
static int cidrBitsFromNetmaskV4(uint32_t netmask) {
	uint32_t hostOrder = ntohl(netmask);
	int bits = 0;
	while (hostOrder & 0x80000000) {
		bits++;
		hostOrder <<= 1;
	}
	return bits;
}

// Reads the IPv4 address + CIDR mask of every active interface (skips lo0,
// link-local 169.254.x). Returns array of dicts {@"ip": "x", @"cidr": "n"}.
- (NSArray *)collectIPv4InfoFromKernel {
	NSMutableArray *out = [NSMutableArray array];
	struct ifaddrs *interfaces = NULL;
	if (getifaddrs(&interfaces) != 0) return out;
	for (struct ifaddrs *cur = interfaces; cur != NULL; cur = cur->ifa_next) {
		if (!cur->ifa_addr || cur->ifa_addr->sa_family != AF_INET) continue;
		NSString *ifname = [NSString stringWithUTF8String:cur->ifa_name];
		if ([ifname isEqualToString:@"lo0"]) continue;
		struct sockaddr_in *sin = (struct sockaddr_in *)cur->ifa_addr;
		char buf[INET_ADDRSTRLEN] = {0};
		if (!inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) continue;
		NSString *ip = [NSString stringWithUTF8String:buf];
		if ([ip isEqualToString:@"127.0.0.1"]) continue;
		// 169.254.0.0/16 is APIPA / self-assigned: non-routable. We still show
		// it (the interface did acquire an address) but flag it as such.
		BOOL routable = ![ip hasPrefix:@"169.254."];
		int cidr = 0;
		if (cur->ifa_netmask) {
			struct sockaddr_in *mask = (struct sockaddr_in *)cur->ifa_netmask;
			cidr = cidrBitsFromNetmaskV4(mask->sin_addr.s_addr);
		}
		[out addObject:@{@"ip": ip, @"cidr": @(cidr), @"if": ifname, @"routable": @(routable)}];
	}
	freeifaddrs(interfaces);
	return out;
}

// Reads IPv6 addresses (skips ::1 loopback). fe80:: link-local are included
// but flagged non-routable so they can be labeled in the notification.
- (NSArray *)collectIPv6InfoFromKernel {
	NSMutableArray *out = [NSMutableArray array];
	struct ifaddrs *interfaces = NULL;
	if (getifaddrs(&interfaces) != 0) return out;
	for (struct ifaddrs *cur = interfaces; cur != NULL; cur = cur->ifa_next) {
		if (!cur->ifa_addr || cur->ifa_addr->sa_family != AF_INET6) continue;
		NSString *ifname = [NSString stringWithUTF8String:cur->ifa_name];
		if ([ifname isEqualToString:@"lo0"]) continue;
		struct sockaddr_in6 *sin = (struct sockaddr_in6 *)cur->ifa_addr;
		char buf[INET6_ADDRSTRLEN] = {0};
		if (!inet_ntop(AF_INET6, &sin->sin6_addr, buf, sizeof(buf))) continue;
		NSString *ip = [NSString stringWithUTF8String:buf];
		// strip the "%en0" scope suffix that link-local addresses carry
		NSRange pct = [ip rangeOfString:@"%"];
		if (pct.location != NSNotFound) ip = [ip substringToIndex:pct.location];
		if ([ip isEqualToString:@"::1"]) continue;    // loopback
		// fe80:: link-local is auto-generated on EVERY interface (utun, awdl,
		// llw, en…) and never carries useful signal — skip it entirely.
		if ([[ip lowercaseString] hasPrefix:@"fe80:"]) continue;
		[out addObject:@{@"ip": ip, @"routable": @(YES), @"if": ifname}];
	}
	freeifaddrs(interfaces);
	return out;
}

// Reads the IPv4 gateway from SCDynamicStore Global/IPv4 dictionary.
- (NSString *)readIPv4Gateway {
	NSString *gw = nil;
	CFDictionaryRef d = SCDynamicStoreCopyValue(dynStore, CFSTR("State:/Network/Global/IPv4"));
	if (d) {
		NSString *router = [(__bridge NSDictionary *)d objectForKey:@"Router"];
		if (router) gw = [NSString stringWithString:router];
		CFRelease(d);
	}
	return gw;
}

// Reads the IPv6 gateway from SCDynamicStore Global/IPv6 dictionary.
- (NSString *)readIPv6Gateway {
	NSString *gw = nil;
	CFDictionaryRef d = SCDynamicStoreCopyValue(dynStore, CFSTR("State:/Network/Global/IPv6"));
	if (d) {
		NSString *router = [(__bridge NSDictionary *)d objectForKey:@"Router"];
		if (router) gw = [NSString stringWithString:router];
		CFRelease(d);
	}
	return gw;
}

// Maps BSD interface names (en0, en1…) to friendly names (Wi-Fi, Ethernet…).
- (NSDictionary *)bsdToFriendlyNameMap {
	NSMutableDictionary *map = [NSMutableDictionary dictionary];
	CFArrayRef ifaces = SCNetworkInterfaceCopyAll();
	if (ifaces) {
		for (CFIndex i = 0; i < CFArrayGetCount(ifaces); i++) {
			SCNetworkInterfaceRef iface =
			    (SCNetworkInterfaceRef)CFArrayGetValueAtIndex(ifaces, i);
			NSString *bsd  = (__bridge NSString *)SCNetworkInterfaceGetBSDName(iface);
			NSString *name = (__bridge NSString *)SCNetworkInterfaceGetLocalizedDisplayName(iface);
			if (bsd && name) [map setObject:name forKey:bsd];
		}
		CFRelease(ifaces);
	}
	return map;
}

-(void)updateIP {
	NSDictionary *friendly = [self bsdToFriendlyNameMap];
	NSArray  *ipv4Info  = [self collectIPv4InfoFromKernel];
	NSArray  *ipv6Info  = [self collectIPv6InfoFromKernel];
	NSString *gateway   = [self readIPv4Gateway];
	NSString *gateway6  = [self readIPv6Gateway];

	NSString *nonRoutableTag = NSLocalizedString(@"(non-routable)", @"");
	BOOL anyRoutable = NO;

	NSMutableArray *lines = [NSMutableArray array];
	for (NSDictionary *info in ipv4Info) {
		BOOL r = [info[@"routable"] boolValue];
		if (r) anyRoutable = YES;
		NSString *ifname = friendly[info[@"if"]] ?: info[@"if"];
		[lines addObject:[NSString stringWithFormat:@"%@ — IPv4:\t%@/%@",
		                  ifname, info[@"ip"], info[@"cidr"]]];
		if (!r) [lines addObject:nonRoutableTag];   // tag on its own line
	}
	if (gateway && [ipv4Info count] > 0) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Gateway:\t%@", @""), gateway]];
	}
	for (NSDictionary *info in ipv6Info) {
		BOOL r = [info[@"routable"] boolValue];
		if (r) anyRoutable = YES;
		NSString *ifname = friendly[info[@"if"]] ?: info[@"if"];
		[lines addObject:[NSString stringWithFormat:@"%@ — IPv6:\t%@", ifname, info[@"ip"]]];
		if (!r) [lines addObject:nonRoutableTag];   // tag on its own line
	}
	if (gateway6 && [ipv6Info count] > 0) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Gateway:\t%@", @""), gateway6]];
	}

	NSString *combined = [lines componentsJoinedByString:@"\n"];
	if([combined isEqualTo:previousIPCombined])
		return;

	BOOL hadAddressesBefore = ([previousIPCombined length] > 0);
	self.previousIPCombined = combined;

	NSString *description = nil;
	NSString *imageName   = nil;

	if ([combined length] == 0) {
		// All addresses gone. Only notify if we previously HAD addresses — this
		// is a real "IP released" transition (disconnect). On a fresh launch
		// with no connection, previousIPCombined is also empty, so we stay quiet.
		if (!hadAddressesBefore)
			return;
		description = NSLocalizedString(@"IP address released", @"");
		imageName   = @"Network-Generic-Off";
	} else {
		description = combined;
		// Icon reflects whether we have real connectivity (a routable address)
		// or only self-assigned addresses.
		imageName   = anyRoutable ? @"Network-Generic-On" : @"Network-Generic-Off";
	}

	NSData *iconData = [[NSImage imageNamed:imageName] TIFFRepresentation];
	[delegate notifyWithName:@"IPAddressChange"
							 title:NSLocalizedString(@"IP Addresses Updated", @"")
					 description:description
							  icon:iconData
			  identifierString:@"HWGrowlIPAddressChange"
				  contextString:nil
							plugin:self];
}

- (void) interateInterfaces
{
    // Wired/Ethernet link priming at launch is handled by NWPathMonitor's first update.
    // Here we just fire the current IP state (gated by onLaunchEnabled via fireOnLaunchNotes).
    [self updateIP];
}

static void scCallback(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info) {
	@autoreleasepool {
        HWGrowlNetworkMonitor *observer = (__bridge HWGrowlNetworkMonitor *)info;
        // Only the Global IPv4/IPv6 keys are watched now (wired link → NWPathMonitor).
        [(__bridge NSArray*)changedKeys enumerateObjectsUsingBlock:^(NSString *key, NSUInteger idx, BOOL *stop) {
            if([key hasPrefix:@"State:/Network/Global"])
                [observer updateIP];
        }];
    }
}

#pragma mark HWGrowlPluginProtocol

// delegate accessors are auto-synthesized from the @property (weak).
-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Network Monitor", @"");
}
-(NSImage*)preferenceIcon {
	static NSImage *_icon = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_icon = [NSImage imageNamed:@"HWGPrefsNetwork"];
	});
	return _icon;
}
-(IBAction)signalIntervalChanged:(NSSlider*)sender {
	NSInteger secs = lround([sender doubleValue]);
	[[NSUserDefaults standardUserDefaults] setInteger:secs forKey:HWG_WIFI_POLL_KEY];
	self.intervalValueLabel.stringValue = [NSString stringWithFormat:@"%ld s", (long)secs];
	[self restartSignalPollTimer];   // apply the new interval immediately
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 380, 120)];
	NSTimeInterval cur = [self signalPollInterval];

	NSTextField *title = [NSTextField labelWithString:NSLocalizedString(@"Wi-Fi signal check interval", @"")];
	title.font = [NSFont boldSystemFontOfSize:13];

	NSSlider *slider = [NSSlider sliderWithValue:cur minValue:HWG_WIFI_POLL_MIN maxValue:HWG_WIFI_POLL_MAX
										  target:self action:@selector(signalIntervalChanged:)];

	NSTextField *value = [NSTextField labelWithString:[NSString stringWithFormat:@"%.0f s", cur]];
	self.intervalValueLabel = value;

	NSTextField *caption = [NSTextField labelWithString:
		NSLocalizedString(@"How often the Wi-Fi signal strength is checked (5–60 s).", @"")];
	caption.textColor = [NSColor secondaryLabelColor];
	caption.font = [NSFont systemFontOfSize:11];

	for (NSView *sv in @[title, slider, value, caption]) {
		sv.translatesAutoresizingMaskIntoConstraints = NO;
		[v addSubview:sv];
	}
	[NSLayoutConstraint activateConstraints:@[
		[title.topAnchor      constraintEqualToAnchor:v.topAnchor constant:16],
		[title.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
		[slider.topAnchor     constraintEqualToAnchor:title.bottomAnchor constant:12],
		[slider.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:16],
		[slider.widthAnchor   constraintEqualToConstant:240],
		[value.centerYAnchor  constraintEqualToAnchor:slider.centerYAnchor],
		[value.leadingAnchor  constraintEqualToAnchor:slider.trailingAnchor constant:10],
		[caption.topAnchor     constraintEqualToAnchor:slider.bottomAnchor constant:10],
		[caption.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:16],
	]];

	prefsView = v;
	return prefsView;
}

#pragma mark HWGrowlPluginNotifierProtocol

-(NSArray*)noteNames {
	return [NSArray arrayWithObjects:@"IPAddressChange", @"NetworkLinkUp", @"NetworkLinkDown", @"AirportConnected", @"AirportDisconnected", @"AirportSignalChange", nil];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"IP Address Changed", @""), @"IPAddressChange",
			  NSLocalizedString(@"Network Link Up", @""), @"NetworkLinkUp",
			  NSLocalizedString(@"Network Link Down", @""), @"NetworkLinkDown",
			  NSLocalizedString(@"AirPort Connected", @""), @"AirportConnected",
			  NSLocalizedString(@"AirPort Disconnected", @""), @"AirportDisconnected",
			  NSLocalizedString(@"Wi-Fi Signal Changed", @""), @"AirportSignalChange", nil];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Sent when the systems IP address changes", @""), @"IPAddressChange",
			  NSLocalizedString(@"Sent when an Ethernet link starts", @""), @"NetworkLinkUp",
			  NSLocalizedString(@"Sent when an Ethernet link goes down", @""), @"NetworkLinkDown",
			  NSLocalizedString(@"Sent when AirPort connects to a network", @""), @"AirportConnected",
			  NSLocalizedString(@"Sent when AirPort disconnects from a network", @""), @"AirportDisconnected",
			  NSLocalizedString(@"Sent when the Wi-Fi signal strength level changes", @""), @"AirportSignalChange", nil];
}
-(NSArray*)defaultNotifications {
	return [NSArray arrayWithObjects:@"IPAddressChange", @"NetworkLinkUp", @"NetworkLinkDown", @"AirportConnected", @"AirportDisconnected", @"AirportSignalChange", nil];
}

@end
