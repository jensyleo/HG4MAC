//
//  HWGrowlNetworkMonitor.m
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/2/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

// compile with ARC: -fobjc-arc
#import "HWGrowlNetworkMonitor.h"
#import "HWGWifiSignal.h"
#import "GrowlNetworkUtilities.h"
#import "HWGIconOverrideStore.h"
#import "HWGIconPickerView.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <CoreWLAN/CoreWLAN.h>
#import <CoreLocation/CoreLocation.h>

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

// F20: user-configurable rate-limit between two "Wi-Fi Signal Changed" notifications, so a
// value hovering at a bar threshold doesn't spam. Default 10s, clamped 0–60 (0 = disabled).
#define HWG_WIFI_COOLDOWN_KEY     @"HWGWifiSignalCooldown"
#define HWG_WIFI_COOLDOWN_DEFAULT 10.0
#define HWG_WIFI_COOLDOWN_MIN     0.0
#define HWG_WIFI_COOLDOWN_MAX     60.0

// F33: individually configurable fields shown in Network Monitor notifications, grouped
// into 3 sections (Wi-Fi / Ethernet / Other-IP) in Preferences → Modules → Network Monitor.
// All default to YES (matching prior always-on behavior) except HWG_ETH_SHOW_ALL_KEY,
// which defaults to NO (matches the F35 hardcoded "real Ethernet only" filter).
#define HWG_WIFI_SHOW_SSID_KEY       @"HWGWifiShowSSID"
#define HWG_WIFI_SHOW_BSSID_KEY      @"HWGWifiShowBSSID"
#define HWG_WIFI_SHOW_BAND_KEY       @"HWGWifiShowBand"
#define HWG_WIFI_SHOW_GENERATION_KEY @"HWGWifiShowGeneration"
#define HWG_WIFI_SHOW_SECURITY_KEY   @"HWGWifiShowSecurity"
// Added 17-ago-2026 (feedback del usuario: "agregar todo lo posible") — all 3 read from
// CWInterface, same as Band/Generation/Security above; none require Location permission
// (they describe the radio link itself, not the network's identity).
#define HWG_WIFI_SHOW_RATE_KEY       @"HWGWifiShowTransmitRate"
#define HWG_WIFI_SHOW_CHANNEL_KEY    @"HWGWifiShowChannel"
#define HWG_WIFI_SHOW_SNR_KEY        @"HWGWifiShowNoiseSNR"
// Final API audit (18-ago-2026), batch 2 — all 4 read from CWInterface, same class already
// used for Band/Generation/Security/Rate/Channel/SNR above. OFF by default.
#define HWG_WIFI_SHOW_COUNTRY_KEY    @"HWGWifiShowCountryCode"
#define HWG_WIFI_SHOW_TXPOWER_KEY    @"HWGWifiShowTransmitPower"
#define HWG_WIFI_SHOW_HWADDR_KEY     @"HWGWifiShowHardwareAddress"
#define HWG_WIFI_SHOW_MODE_KEY       @"HWGWifiShowInterfaceMode"

#define HWG_ETH_SHOW_INTERFACE_KEY   @"HWGEthernetShowInterface"
#define HWG_ETH_SHOW_SPEED_KEY       @"HWGEthernetShowSpeed"
#define HWG_ETH_SHOW_MODE_KEY        @"HWGEthernetShowMode"
#define HWG_ETH_SHOW_ALL_KEY         @"HWGEthernetShowAllInterfaces"

#define HWG_IP_SHOW_IPV4_KEY         @"HWGIPShowIPv4"
#define HWG_IP_SHOW_IPV6_KEY         @"HWGIPShowIPv6"
#define HWG_IP_SHOW_GATEWAY_KEY      @"HWGIPShowGateway"
#define HWG_IP_SHOW_NONROUTABLE_KEY  @"HWGIPShowNonRoutableTag"
// #9 (05-ago-2026): colored "old → new" line per interface when its address actually
// changed — same pattern as Display Monitor's per-field toggles. ON by default; independent
// per-interface tracking (previousIPv4/6ByInterface) so only the interface that actually
// changed shows an arrow, not every interface every time any one of them changes.
#define HWG_IP_SHOW_OLDNEW_KEY       @"HWGIPShowOldNewAddress"
#define HWG_IP_USE_FRIENDLY_KEY      @"HWGIPUseFriendlyNames"

// F34 #4: VPN connected/disconnected. OFF by default per user request — this is a NEW
// notification, not a visibility toggle on an existing one. Detection is a HEURISTIC (see
// -vpnLikeInterfaceNamesFromIPInfo:ipv6: below and the README "Known limitations" entry) —
// there is no public API that says "this interface IS a VPN"; we infer it from the BSD
// interface-name prefix macOS gives virtual tunnel interfaces.
#define HWG_VPN_NOTIFY_KEY @"HWGNetworkNotifyVPN"

// Final API audit (18-ago-2026), batch 1 of the 32-candidate NetworkMonitor pass — 4 items:
// general Internet reachability, DHCP lease renewal, hostname/computer-name change, and
// Network Location change. All OFF by default (new notification categories, not visibility
// toggles on an existing one — same convention as HWG_VPN_NOTIFY_KEY above).
#define HWG_NET_NOTIFY_REACHABILITY_KEY @"HWGNetworkNotifyReachability"
#define HWG_NET_NOTIFY_DHCP_RENEWED_KEY @"HWGNetworkNotifyDHCPRenewed"
#define HWG_NET_NOTIFY_HOSTNAME_KEY      @"HWGNetworkNotifyHostnameChanged"
#define HWG_NET_NOTIFY_LOCATION_KEY      @"HWGNetworkNotifyLocationChanged"

// Final API audit (18-ago-2026), batch 2 — Wi-Fi interface entering/leaving Host AP (Internet
// Sharing) or IBSS (ad-hoc) mode. Same CWInterfaceMode already read for the General-tab
// "Interface mode" field (HWG_WIFI_SHOW_MODE_KEY), but as a state-TRANSITION event.
#define HWG_NET_NOTIFY_WIFI_HOSTAP_KEY @"HWGNetworkNotifyWifiHostAPMode"

// Per-row "Notify?" checkboxes (Icons tab) — one per icon row, matching the USB/Thunderbolt/
// Bluetooth/Volume Monitor pattern. Several rows share one underlying notifyWithName call
// (5 Wi-Fi signal-level rows share AirportSignalChange; Ethernet/Other Interface share
// NetworkLinkUp/Down; Generic Connected/Disconnected share IPAddressChange) — each such call
// site is gated by looking up the specific row key for the icon it's about to use.
#define HWG_NET_NOTIFY_WIFI_BAR_PREFIX   @"HWGNetworkNotifyWifiBar"   // + 0/1/2/3/4
#define HWG_NET_NOTIFY_WIFI_OFF_KEY      @"HWGNetworkNotifyWifiOff"
#define HWG_NET_NOTIFY_ETH_ON_KEY        @"HWGNetworkNotifyEthernetOn"
#define HWG_NET_NOTIFY_ETH_OFF_KEY       @"HWGNetworkNotifyEthernetOff"
#define HWG_NET_NOTIFY_ETH_SPEED_KEY     @"HWGNetworkNotifyEthernetSpeedChanged"
#define HWG_NET_NOTIFY_DNS_KEY           @"HWGNetworkNotifyDNSChanged"
#define HWG_NET_NOTIFY_PRIMARY_IF_KEY    @"HWGNetworkNotifyPrimaryInterfaceChanged"
#define HWG_NET_NOTIFY_PROXY_KEY         @"HWGNetworkNotifyProxyChanged"
// Added 18-ago-2026 (feedback del usuario) — Wi-Fi radio power on/off, distinct from
// "AirportConnected/Disconnected" (network association) — CWEventTypePowerDidChange already
// existed and already routed here, but the destination method never checked this specifically.
// Split into two independent keys (same day, same feedback) matching the Connected/Disconnected
// precedent — each direction gets its own row/icon, customizable independently.
#define HWG_NET_NOTIFY_WIFI_RADIO_ON_KEY  @"HWGNetworkNotifyWifiRadioOn"
#define HWG_NET_NOTIFY_WIFI_RADIO_OFF_KEY @"HWGNetworkNotifyWifiRadioOff"
#define HWG_NET_NOTIFY_OTHER_ON_KEY      @"HWGNetworkNotifyOtherOn"
#define HWG_NET_NOTIFY_OTHER_OFF_KEY     @"HWGNetworkNotifyOtherOff"
#define HWG_NET_NOTIFY_GENERIC_ON_KEY    @"HWGNetworkNotifyGenericOn"
#define HWG_NET_NOTIFY_GENERIC_OFF_KEY   @"HWGNetworkNotifyGenericOff"

// HWGFlippedContentView now lives in HWGIconPickerView.h/.m (shared across every monitor's
// Icons tab) — this file already imports that header, so no local definition needed here.

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
// F33: whether any IPv4/IPv6 address was present on the last check — tracked separately
// from previousIPCombined (the DISPLAYED text) because F33's per-field toggles can make
// the displayed text empty even while addresses are genuinely still present.
@property (nonatomic, assign) BOOL previousHasIPAddresses;
// #9 (05-ago-2026): per-interface previous address, keyed by BSD name (e.g. "en0") — needed
// to show "old → new" per interface, since previousIPCombined is the whole DISPLAYED block
// across every interface and can't tell which specific interface actually changed when
// there are several (e.g. a USB-Ethernet dock on top of Wi-Fi).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *previousIPv4ByInterface;
@property (nonatomic, strong) NSArray<NSString *> *lastKnownDNSServers;
@property (nonatomic, copy) NSString *lastKnownProxySummary;
@property (nonatomic, strong) NSString *lastKnownPrimaryInterface;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *previousIPv6ByInterface;

// P10 (reverted 16-jul-2026): Ethernet (wired) link up/down was briefly detected via
// NWPathMonitor, but that only reports an interface once it has a USABLE network path
// (an IP + working route) — an interface with link but no DHCP-assigned IP (or one with a
// slow-to-settle static IP) never appeared at all, or appeared very late. Back to watching
// the RAW physical-link SCDynamicStore key (".../Link"), which reflects carrier/link state
// alone, independent of DHCP/IP — the same signal System Settings uses, and the same one
// already confirmed firing correctly on this exact machine (see iPhone USB test, 30-jun-2026,
// before this ever became NWPathMonitor). SCDynamicStore is also still used for IP/gateway.

// Remembers, per interface, whether it had recognized Ethernet media when it came up,
// so the Link-Down notification uses the same icon family as the Link-Up (the media is
// often unreadable once the interface is gone).
@property (nonatomic, strong) NSMutableDictionary *interfaceIsEthernet;

// Ethernet link speed while the link stays up (e.g. a cable degrading from
// 1000baseT to 100baseTX without the link ever dropping). Keyed by interface
// name -> last-seen media string from -getMediaTypeForInterface:mode:.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *lastKnownEthernetSpeed;
@property (nonatomic, strong) NSTimer *ethernetSpeedPollTimer;

// Caches -isWiredEthernetInterface:'s result per BSD name (bsdName -> @YES/@NO). BUG FIX
// (11-ago-2026): unplugging a USB-Ethernet adapter (or the hub/dock it's inside) tears the
// interface out of SCNetworkInterfaceCopyAll() almost immediately — often before, or at the
// same moment as, its "Link" key changes — so a live re-query at disconnect time silently
// fails to classify it as Ethernet, -handleLinkKeyChanged: bails out early, and the real
// disconnect is never processed (networkInterfaceStates keeps stale "Active: 1"). That stale
// state then surfaces on the NEXT reconnect: the first link read (while the adapter is still
// negotiating) reports inactive, compared against the stale "was active" baseline fires a
// bogus "Ethernet Disconnected", followed shortly by the real "Ethernet Connected" once the
// link actually comes up — a disconnect that's silently dropped, then a phantom
// disconnect+reconnect pair on the next plug-in, exactly as reported. Live classification is
// still tried FIRST every time (so a genuinely different device later reusing the same BSD
// name is reclassified correctly); this cache is only consulted as a fallback when the
// interface has already vanished from the live registry, so a real disconnect is still
// recognized as the SAME (now-gone) Ethernet interface it always was.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *ethernetClassificationCache;

// CoreWLAN: replaces the deprecated SCDynamicStore AirPort keys for WiFi events.
// weak: the framework owns the +sharedWiFiClient singleton; we don't.
@property (nonatomic, weak) CWWiFiClient *wifiClient;
@property (nonatomic, strong) NSString *lastReportedSSID;

// Tracks the BSSID (access point MAC) of the currently-associated network, separate from
// lastReportedSSID, so roaming to a different AP on the same SSID (same building, different
// room) is detected even though the SSID string never changes.
@property (nonatomic, strong) NSData *lastReportedBSSID;

// F20: track the last reported WiFi signal bar level (0–4; -1 = not connected / unknown)
// so we notify only when the LEVEL changes, plus a cooldown to avoid threshold flapping.
@property (nonatomic, assign) NSInteger lastReportedWifiBars;
// -1 = no baseline read yet this launch, 0/1 = last known radio power state (off/on).
@property (nonatomic, assign) NSInteger lastReportedWifiRadioOn;
@property (nonatomic, assign) NSInteger lastReportedWifiInterfaceMode;
@property (nonatomic, strong) NSDate *lastSignalNoteTime;
@property (nonatomic, strong) NSTimer *signalPollTimer;

// Preferences pane (built programmatically — no nib) for the WiFi signal poll interval.
@property (nonatomic, strong) NSView *prefsView;
@property (nonatomic, weak) NSTextField *intervalValueLabel;
@property (nonatomic, weak) NSTextField *cooldownValueLabel;

// CoreLocation: required since macOS 10.14 to read the Wi-Fi SSID
@property (nonatomic, strong) CLLocationManager *locationManager;

// F34 #4: BSD names of VPN-like interfaces (utunN/pppN/ipsecN with a real address) currently
// believed active, so we notify only on the connect/disconnect TRANSITION.
@property (nonatomic, strong) NSMutableSet<NSString*> *activeVPNInterfaceNames;

// Final API audit (18-ago-2026), batch 1.
@property (nonatomic, assign) SCNetworkReachabilityRef reachabilityRef;
@property (nonatomic, assign) SCNetworkReachabilityFlags lastReachabilityFlags;
@property (nonatomic, assign) BOOL haveLastReachabilityFlags;
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSDate*> *lastKnownDHCPLeaseStartByInterface;
@property (nonatomic, strong) NSString *lastKnownComputerName;
@property (nonatomic, strong) NSString *lastKnownLocationName;

@end

@implementation HWGrowlNetworkMonitor

@synthesize delegate;
@synthesize rlSrc;
@synthesize dynStore;
@synthesize networkInterfaceStates;
@synthesize previousIPCombined;
@synthesize previousHasIPAddresses;
@synthesize previousIPv4ByInterface;
@synthesize lastKnownDNSServers;
@synthesize lastKnownProxySummary;
@synthesize lastKnownPrimaryInterface;
@synthesize previousIPv6ByInterface;
@synthesize interfaceIsEthernet;
@synthesize lastKnownEthernetSpeed;
@synthesize ethernetSpeedPollTimer;
@synthesize reachabilityRef;
@synthesize lastReachabilityFlags;
@synthesize haveLastReachabilityFlags;
@synthesize lastKnownDHCPLeaseStartByInterface;
@synthesize lastKnownComputerName;
@synthesize lastKnownLocationName;
@synthesize ethernetClassificationCache;
@synthesize wifiClient;
@synthesize lastReportedSSID;
@synthesize lastReportedBSSID;
@synthesize lastReportedWifiBars;
@synthesize lastReportedWifiRadioOn;
@synthesize lastReportedWifiInterfaceMode;
@synthesize lastSignalNoteTime;
@synthesize signalPollTimer;
@synthesize prefsView;
@synthesize intervalValueLabel;
@synthesize cooldownValueLabel;
@synthesize locationManager;

-(id)init {
	if((self = [super init])){
		self.previousIPCombined = nil;
		self.previousIPv4ByInterface = [NSMutableDictionary dictionary];
		self.previousIPv6ByInterface = [NSMutableDictionary dictionary];
		self.networkInterfaceStates = [NSMutableDictionary dictionary];
		self.interfaceIsEthernet = [NSMutableDictionary dictionary];
		self.lastKnownEthernetSpeed = [NSMutableDictionary dictionary];
		self.ethernetClassificationCache = [NSMutableDictionary dictionary];
		self.lastReportedWifiBars = -1;
		self.lastReportedWifiRadioOn = -1;
		self.lastReportedWifiInterfaceMode = -1;
		self.activeVPNInterfaceNames = [NSMutableSet set];
		self.lastKnownDHCPLeaseStartByInterface = [NSMutableDictionary dictionary];

		[self startObserving];
		[self startWiFiMonitoring];
		[self requestLocationForSSID];
		[self startEthernetSpeedPolling];
		[self startReachabilityMonitoring];
		[self primeHostnameAndLocationState];
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
	[ethernetSpeedPollTimer invalidate];

	if (rlSrc)
		CFRunLoopRemoveSource(CFRunLoopGetMain(), rlSrc, kCFRunLoopDefaultMode);
   if (dynStore)
		CFRelease(dynStore);

	if (wifiClient) {
		[wifiClient stopMonitoringAllEventsAndReturnError:NULL];
		wifiClient.delegate = nil;
	}

	locationManager.delegate = nil;

	if (reachabilityRef) {
		SCNetworkReachabilityUnscheduleFromRunLoop(reachabilityRef, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
		CFRelease(reachabilityRef);
	}
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
		NSString *bssidStr = [iface bssid];
		if (bssidStr) {
			unsigned int b[6] = {0};
			sscanf([bssidStr UTF8String], "%x:%x:%x:%x:%x:%x",
			       &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]);
			unsigned char bytes[6] = {(unsigned char)b[0], (unsigned char)b[1],
			                          (unsigned char)b[2], (unsigned char)b[3],
			                          (unsigned char)b[4], (unsigned char)b[5]};
			self.lastReportedBSSID = [NSData dataWithBytes:bytes length:6];
		}
	}
}

-(void)powerStateDidChangeForWiFiInterfaceWithName:(NSString *)interfaceName {
	// Added 18-ago-2026 (feedback del usuario: "cuando prendo y apago el WiFi no lo detecta") —
	// this callback (CWEventTypePowerDidChange) already existed and already routed into
	// -handleWiFiStateChangeForInterface: below, but that method only distinguishes "connected
	// to a network" vs "not connected" — turning the Wi-Fi radio off entirely and merely losing
	// network association both looked identical to it (both fire "AirportDisconnected"). Added
	// a genuinely separate check here for the radio's own power state, independent of whether
	// it's associated to a network.
	[self checkWifiRadioPowerStateForInterface:interfaceName];
	[self handleWiFiStateChangeForInterface:interfaceName];
}

-(void)checkWifiRadioPowerStateForInterface:(NSString *)interfaceName {
	if (![NSThread isMainThread]) {
		dispatch_async(dispatch_get_main_queue(), ^{ [self checkWifiRadioPowerStateForInterface:interfaceName]; });
		return;
	}
	CWInterface *iface = [self.wifiClient interfaceWithName:interfaceName];
	if (!iface) return;
	[self checkWifiRadioPowerStateWithInterface:iface];
}

// BUG FIX (18-ago-2026, feedback del usuario: "el de radio off no notifica") — pulled the actual
// check out into its own method so it can ALSO run from -pollWifiSignal: (already scheduled
// every ~12s) as a fallback, not just from the CWEventTypePowerDidChange callback above. Same
// precedent as this file's own F20 comment a few lines below: some CoreWLAN CWEventDelegate
// callbacks don't fire reliably on macOS Tahoe (confirmed there for CWEventTypeLinkQualityDidChange,
// which is why RSSI is polled instead of push-driven) — CWEventTypePowerDidChange turning OFF
// specifically not firing fits that same known pattern, so this no longer depends on it alone.
-(void)checkWifiRadioPowerStateWithInterface:(CWInterface *)iface {
	// Split into two independent toggles/rows (18-ago-2026, feedback del usuario) — matches the
	// Bluetooth Radio On/Off split done the same day, same reasoning: lets each direction be
	// enabled/customized independently, same precedent as every other Connected/Disconnected
	// pair elsewhere in this app.
	BOOL onEnabled = [self boolForKey:HWG_NET_NOTIFY_WIFI_RADIO_ON_KEY default:NO];
	BOOL offEnabled = [self boolForKey:HWG_NET_NOTIFY_WIFI_RADIO_OFF_KEY default:NO];
	if (!onEnabled && !offEnabled) return;

	BOOL poweredOn = [iface powerOn];
	if (lastReportedWifiRadioOn == poweredOn) return;   // no real change, or first read this launch — baseline below
	BOOL hadBaseline = (lastReportedWifiRadioOn != -1);
	self.lastReportedWifiRadioOn = poweredOn;
	if (!hadBaseline) return;   // first sighting — baseline only, no notification
	if (poweredOn && !onEnabled) return;
	if (!poweredOn && !offEnabled) return;

	NSData *iconData = [HWGResolveIconNamed(poweredOn ? @"Network-Wifi-Radio-On" : @"Network-Wifi-Radio-Off") TIFFRepresentation];
	[delegate notifyWithName:poweredOn ? @"WifiRadioOn" : @"WifiRadioOff"
							 title:poweredOn ? NSLocalizedString(@"Wi-Fi Turned On", @"") : NSLocalizedString(@"Wi-Fi Turned Off", @"")
					 description:@""
							  icon:iconData
			  identifierString:@"HWGrowlWifiRadioPower"
				  contextString:nil
							plugin:self];
}

-(void)bssidDidChangeForWiFiInterfaceWithName:(NSString *)interfaceName {
	[self checkWifiRadioPowerStateForInterface:interfaceName];
	[self handleWiFiStateChangeForInterface:interfaceName];
}

-(void)modeDidChangeForWiFiInterfaceWithName:(NSString *)interfaceName {
	[self checkWifiRadioPowerStateForInterface:interfaceName];
	[self handleWiFiStateChangeForInterface:interfaceName];
	// Final API audit (18-ago-2026), batch 2 — this CWEventDelegate callback already fires on
	// every CWInterfaceMode transition, including entering/leaving Host AP (Internet Sharing)
	// or IBSS (ad-hoc) — the audit's candidate. No new observation mechanism needed, just
	// reading the mode here and comparing.
	CWInterface *iface = [self.wifiClient interfaceWithName:interfaceName];
	if (iface) [self checkWifiModeTransition:[iface interfaceMode]];
}

-(NSString *)wifiInterfaceModeLabel:(CWInterfaceMode)mode {
	switch (mode) {
		case kCWInterfaceModeStation: return NSLocalizedString(@"Station (normal client)", @"");
		case kCWInterfaceModeIBSS:    return NSLocalizedString(@"Ad-hoc (IBSS)", @"");
		case kCWInterfaceModeHostAP:  return NSLocalizedString(@"Host AP (Internet Sharing)", @"");
		default:                      return NSLocalizedString(@"None", @"");
	}
}

// Silent baseline on first sighting (lastReportedWifiInterfaceMode starts at -1, an impossible
// CWInterfaceMode value) — same convention as every other transition-tracking property in this
// file (e.g. lastReportedWifiRadioOn above).
-(void)checkWifiModeTransition:(CWInterfaceMode)mode {
	if (![self boolForKey:HWG_NET_NOTIFY_WIFI_HOSTAP_KEY default:NO]) return;
	if (lastReportedWifiInterfaceMode == mode) return;
	BOOL hadBaseline = (lastReportedWifiInterfaceMode != -1);
	NSInteger previousMode = lastReportedWifiInterfaceMode;
	self.lastReportedWifiInterfaceMode = mode;
	if (!hadBaseline) return;
	// Only notify for a transition INTO or OUT OF Host AP/IBSS — not every Station<->Station
	// no-op or association-detail change that might also route through this delegate callback.
	BOOL wasSpecial = (previousMode == kCWInterfaceModeHostAP || previousMode == kCWInterfaceModeIBSS);
	BOOL nowSpecial = (mode == kCWInterfaceModeHostAP || mode == kCWInterfaceModeIBSS);
	if (!wasSpecial && !nowSpecial) return;

	[delegate notifyWithName:@"WifiHostAPModeChanged"
						 title:NSLocalizedString(@"Wi-Fi Interface Mode Changed", @"")
					   description:[NSString stringWithFormat:NSLocalizedString(@"%@ → %@", @""), [self wifiInterfaceModeLabel:previousMode], [self wifiInterfaceModeLabel:mode]]
						  icon:HWGResolveIconDataNamed(@"HWGPrefsNetwork-Module")
			  identifierString:@"HWGrowlWifiHostAPMode"
				 contextString:nil
						plugin:self];
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
		// Roaming to a different access point on the SAME SSID never changed
		// displayName, so the old dedup (SSID-only) silently swallowed real roam
		// events. Only treat it as "already reported" when BOTH SSID and BSSID
		// match — a BSSID we can't read (nil, e.g. no Location permission) never
		// triggers a false roam notification, it just falls back to SSID-only dedup.
		BOOL sameSSID  = lastReportedSSID && [lastReportedSSID isEqualToString:displayName];
		BOOL sameBSSID = (bssidData == nil) || (lastReportedBSSID == nil) || [lastReportedBSSID isEqualToData:bssidData];
		if (sameSSID && sameBSSID)
			return; // already reported this state
		self.lastReportedSSID = displayName;
		self.lastReportedBSSID = bssidData;
		// F20: baseline the signal bar level right away instead of waiting for
		// pollWifiSignal:'s first scheduled tick to do it — otherwise detecting any
		// real change takes two full poll intervals (one just to baseline, one to
		// compare) instead of one.
		NSInteger rssiNow = [iface rssiValue];
		self.lastReportedWifiBars = (rssiNow != 0) ? HWGWifiBarsForRSSI(rssiNow) : -1;
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
		self.lastReportedBSSID = nil;
		self.lastReportedWifiBars = -1;   // re-baseline signal level on next connect (F20)
		// BUG FIX (18-ago-2026, feedback del usuario: "esto no es coherente" — screenshot showed
		// "AirPort Disconnected" appearing before "Wi-Fi Turned Off" when the radio itself was
		// turned off, even though this method's caller already calls the radio check FIRST in
		// code. Both notifyWithName calls fire back-to-back with no delay, so the actual
		// stacking order the user sees is left to macOS's own notification delivery/display
		// timing rather than our call order. A short delay here (harmless for the far more
		// common plain-signal-loss disconnect too) guarantees the radio notification — which
		// is the actual CAUSE when both fire together — reaches the notification center
		// meaningfully earlier, so it reads as cause-then-effect instead of the reverse.
		__weak HWGrowlNetworkMonitor *blockSelf = self;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			[blockSelf airportDisconnected:previousName];
		});
	}
}

-(void)linkDidChangeForWiFiInterfaceWithName:(NSString *)interfaceName {
	// BUG FIX (18-ago-2026, feedback del usuario: "el de wifi radio off no notifica") — turning
	// the radio off apparently reaches CWEventDelegate as a LINK change (this callback), not
	// (or not reliably as) a CWEventTypePowerDidChange — confirmed live: AirportDisconnected
	// (which this same method already triggers via -handleWiFiStateChangeForInterface: below)
	// fired instantly on radio-off, but the radio check (only hooked to the power callback
	// before this fix) never ran. Hooking the same check into every WiFi state-change callback
	// (link/mode/BSSID, not just power) makes it robust to whichever one macOS actually fires.
	[self checkWifiRadioPowerStateForInterface:interfaceName];
	[self handleWiFiStateChangeForInterface:interfaceName];
}

-(void)ssidDidChangeForWiFiInterfaceWithName:(NSString *)interfaceName {
	[self checkWifiRadioPowerStateForInterface:interfaceName];
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

// Configured rate-limit between two signal-change notifications, clamped to [MIN, MAX].
-(NSTimeInterval)signalCooldownInterval {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:HWG_WIFI_COOLDOWN_KEY];
	NSTimeInterval v = stored ? [[NSUserDefaults standardUserDefaults] doubleForKey:HWG_WIFI_COOLDOWN_KEY] : HWG_WIFI_COOLDOWN_DEFAULT;
	if (v < HWG_WIFI_COOLDOWN_MIN) v = HWG_WIFI_COOLDOWN_MIN;
	if (v > HWG_WIFI_COOLDOWN_MAX) v = HWG_WIFI_COOLDOWN_MAX;
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
	// BUG FIX (18-ago-2026) — fallback radio power-state check, see the doc comment on
	// -checkWifiRadioPowerStateWithInterface: above. Runs every tick regardless of association
	// state (unlike the RSSI logic below, which needs to be associated).
	if (iface) [self checkWifiRadioPowerStateWithInterface:iface];

	if (!(iface && [iface powerOn] && [iface interfaceMode] == kCWInterfaceModeStation)) {
		self.lastReportedWifiBars = -1;   // not associated → re-baseline on reconnect
		return;
	}
	NSInteger rssi = [iface rssiValue];
	if (rssi == 0) return;

	NSInteger bars = HWGWifiBarsForRSSI(rssi);

	if (lastReportedWifiBars < 0) {   // first sample after connect → baseline, don't notify
		self.lastReportedWifiBars = bars;
		return;
	}
	if (bars == lastReportedWifiBars) return;   // no level change

	// Rate-limit so a value hovering at a threshold doesn't spam. Don't update the baseline
	// while in cooldown, so a later poll still catches the net change (and flapping back to
	// the old level self-cancels since then bars == lastReportedWifiBars).
	NSTimeInterval cooldown = [self signalCooldownInterval];
	if (cooldown > 0 && lastSignalNoteTime && [[NSDate date] timeIntervalSinceDate:lastSignalNoteTime] < cooldown)
		return;

	BOOL improved = (bars > lastReportedWifiBars);
	NSString *ssid = [iface ssid] ?: (lastReportedSSID ?: NSLocalizedString(@"Wi-Fi", @""));
	NSString *arrow = improved ? @"↑" : @"↓";
	NSString *dir = improved ? NSLocalizedString(@"improved", @"WiFi signal got stronger")
	                         : NSLocalizedString(@"degraded", @"WiFi signal got weaker");
	NSString *desc = [NSString stringWithFormat:
		NSLocalizedString(@"%@\nSignal %@ %@ (%ld/4)", @"network name, arrow, improved/degraded, bars"),
		ssid, arrow, dir, (long)bars];
	NSString *barKey = [HWG_NET_NOTIFY_WIFI_BAR_PREFIX stringByAppendingFormat:@"%ld", (long)bars];
	if (![self boolForKey:barKey default:YES]) {
		self.lastReportedWifiBars = bars;
		self.lastSignalNoteTime = [NSDate date];
		return;
	}

	NSData *iconData = [HWGResolveIconNamed([NSString stringWithFormat:@"Network-Wifi-%ld", (long)bars]) TIFFRepresentation];

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
	// BUG FIX (06-ago-2026): getifaddrs() itself is an instant synchronous kernel read, not a
	// daemon that needs warming up — but on an actual Mac restart/login this can run before
	// DHCP finishes, so the very first read here can genuinely see zero addresses even though
	// a real IP is about to be assigned moments later. -updateIP's own dedup (repeats are
	// silently skipped when nothing changed) makes repeated delayed calls safe to always
	// schedule. Poll every 2s for up to 15s, stopping early once an address shows up.
	//
	// BUG FIX (10-ago-2026): this used to also call -interateInterfaces synchronously,
	// right here, BEFORE scheduling the poll — so in the common case (network already up),
	// IP fired essentially instantly while WiFi (below) always waits out its own 1.5s CoreWLAN
	// warm-up delay, making "IP Addresses Updated" appear before "AirPort Connected" — backwards
	// from the order that actually makes sense (you join a network, THEN get an address on it).
	// Removed the synchronous call; the first iteration of the poll below (at 2s) now serves
	// as the initial check too, so WiFi's 1.5s announcement reliably lands first.
	[self pollForIPAtLaunchElapsed:0];
	// BUG FIX (11-ago-2026): announce an Ethernet cable that was already connected before
	// launch — see -fireExistingWiredEthernetIfEnabled's comment for why this couldn't be
	// decided earlier, in -primeWiredLinkState itself.
	//
	// NOTE (11-ago-2026, later same day): confirmed live (window-list probe) that firing this
	// immediately meant it competed with the ~14 OTHER notifications every plugin fires in the
	// same ~40ms launch instant (Power, 7 volume mounts, 6 USB devices) for the small number of
	// on-screen banner slots — a real visibility problem (the notification itself always fired
	// correctly; confirmed present in Notification History the whole time). The actual fix for
	// that is in GrowlApplicationBridge.m (see its BUG FIX comment near kMinVisibleBeforeEvictable):
	// a launch burst too fast for any banner to be evictable used to fall through and create a
	// banner positioned off the bottom of the screen — genuinely unshowable for its whole 5s
	// lifetime — instead of queuing it to be shown once room frees up. With that fixed, this can
	// stay a plain, immediate call: Ethernet's banner is now guaranteed to eventually get its
	// turn on screen instead of being lost, same as everything else in the launch flood.
	[self fireExistingWiredEthernetIfEnabled];
	// BUG FIX (06-ago-2026): CWWiFiClient's XPC connection to the system WiFi daemon isn't
	// always warm yet this early in process launch — querying it synchronously right here
	// (same run-loop tick as -init) can read the interface as "not associated" even when
	// WiFi is already connected. Since no CoreWLAN change event ever fires for a connection
	// that was already up before launch, that false read meant WiFi silently never got
	// announced at all for the rest of the session. Give CoreWLAN a moment to settle, with
	// one retry in case the first attempt is still too early.
	[self fireCurrentWiFiStateRetrying:YES];
}

// Re-checks -updateIP every 2s for up to 15s after launch (see BUG FIX comment above).
// Stops as soon as an address is present.
-(void)pollForIPAtLaunchElapsed:(NSTimeInterval)elapsed {
	static const NSTimeInterval kPollInterval = 2.0;
	static const NSTimeInterval kPollDeadline = 15.0;
	if (elapsed >= kPollDeadline) return;
	__weak HWGrowlNetworkMonitor *weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPollInterval * NSEC_PER_SEC)),
	               dispatch_get_main_queue(), ^{
		__strong HWGrowlNetworkMonitor *strongSelf = weakSelf;
		if (!strongSelf) return;
		[strongSelf updateIP];
		if (!strongSelf.previousHasIPAddresses) {
			[strongSelf pollForIPAtLaunchElapsed:elapsed + kPollInterval];
		}
	});
}

// At launch (only called when "Show existing" is enabled), announce the WiFi we're
// ALREADY connected to. CoreWLAN only delivers CHANGE events, so an already-up
// connection would otherwise never be reported — unlike volumes / IP, which do
// report at launch. startWiFiMonitoring only records lastReportedSSID silently.
-(void)fireCurrentWiFiStateRetrying:(BOOL)shouldRetry {
	__weak HWGrowlNetworkMonitor *blockSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
	               dispatch_get_main_queue(), ^{
		BOOL reported = [blockSelf fireCurrentWiFiState];
		if (!reported && shouldRetry) {
			[blockSelf fireCurrentWiFiStateRetrying:NO];
		}
	});
}

-(BOOL)fireCurrentWiFiState {
	CWInterface *iface = [self.wifiClient interface];
	if (!(iface && [iface powerOn] && [iface interfaceMode] == kCWInterfaceModeStation))
		return NO;

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
	return YES;
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
    // Wired/Ethernet link up/down: watch EVERY interface's own ".../Link" key via a
    // pattern (not a literal key, since we don't know interface names up front) — this is
    // the raw physical-link/carrier state, independent of DHCP/IP (see property comment
    // above for why NWPathMonitor was reverted).
    // Final API audit (18-ago-2026), batch 1 — "Setup:/System" (ComputerName, changed in
    // Sharing preferences) and "Setup:" itself (root Setup dict, whose CurrentSet property
    // changes when the user switches Network Location — kSCPrefCurrentSet/
    // kSCDynamicStorePropSetupCurrentSet) added as literal keys; DHCP lease detail added as a
    // per-interface pattern, same shape as the existing Link pattern below.
    NSArray *watchedKeys = [NSArray arrayWithObjects:@"State:/Network/Global/IPv4", @"State:/Network/Global/IPv6", @"State:/Network/Global/DNS", @"Setup:/System", @"Setup:", nil];
    NSArray *watchedPatterns = [NSArray arrayWithObjects:@"State:/Network/Interface/[^/]+/Link", @"State:/Network/Interface/[^/]+/DHCP", nil];
	if (!SCDynamicStoreSetNotificationKeys(dynStore,
                                          (__bridge CFArrayRef)watchedKeys,
                                          (__bridge CFArrayRef)watchedPatterns))
   {
		NSLog(@"SCDynamicStoreSetNotificationKeys() failed: %s", SCErrorString(SCError()));
		CFRelease(dynStore);
		dynStore = NULL;
	}

	[self primeWiredLinkState];
}

// Extracts the BSD interface name (e.g. "en0") from a "State:/Network/Interface/<bsd>/Link" key.
-(NSString *)bsdNameFromLinkKey:(NSString *)key {
	NSArray *parts = [key componentsSeparatedByString:@"/"];
	if ([parts count] < 2) return nil;
	return parts[[parts count] - 2];
}

// Reads the raw link-active bit for one interface's ".../Link" key. This reflects
// carrier/link presence alone — no IP, no DHCP, no route involved.
-(BOOL)readLinkActiveForKey:(NSString *)key {
	CFDictionaryRef d = SCDynamicStoreCopyValue(dynStore, (__bridge CFStringRef)key);
	if (!d) return NO;
	NSDictionary *dict = (__bridge_transfer NSDictionary *)d;
	return [dict[(__bridge NSString *)kSCPropNetLinkActive] boolValue];
}

// Watching EVERY interface's ".../Link" key (needed to fix the DHCP/static-IP bugs above)
// picks up more than physical Ethernet: en0 is WiFi on Apple Silicon Macs (already reported
// separately via CoreWLAN/"AirPort Connected") and awdl0 is AWDL (Apple Wireless Direct
// Link — AirDrop/Handoff/Continuity), which flaps constantly in the background and isn't a
// cable a user connected. Filter to interfaces SCNetworkInterface itself classifies as
// Ethernet — this is the same registry System Settings' Network pane reads, so it correctly
// includes USB/Thunderbolt-Ethernet adapters (which register as Ethernet-type) without
// hardcoding interface-name prefixes.
// F33: configurable from Preferences → Modules → Network Monitor ("Also report Wi-Fi's own
// link and AWDL/AirDrop events") — off by default, matching the original hardcoded filter.
-(BOOL)isWiredEthernetInterface:(NSString *)bsdName {
	if ([self boolForKey:HWG_ETH_SHOW_ALL_KEY default:NO]) return YES;
	BOOL isEthernet = NO;
	BOOL found = NO;
	CFArrayRef ifaces = SCNetworkInterfaceCopyAll();
	if (ifaces) {
		for (CFIndex i = 0; i < CFArrayGetCount(ifaces); i++) {
			SCNetworkInterfaceRef iface = (SCNetworkInterfaceRef)CFArrayGetValueAtIndex(ifaces, i);
			NSString *bsd = (__bridge NSString *)SCNetworkInterfaceGetBSDName(iface);
			if (bsd && [bsd isEqualToString:bsdName]) {
				NSString *type = (__bridge NSString *)SCNetworkInterfaceGetInterfaceType(iface);
				isEthernet = [type isEqualToString:(__bridge NSString *)kSCNetworkInterfaceTypeEthernet];
				found = YES;
				break;
			}
		}
		CFRelease(ifaces);
	}
	// See ethernetClassificationCache's declaration: a live miss (interface already torn down,
	// e.g. its USB hub was just unplugged) falls back to the last known classification instead
	// of silently defaulting to "not Ethernet" — which used to make the real disconnect event
	// get dropped entirely. A live hit always wins and refreshes the cache, so a different
	// device later reusing the same BSD name is still classified correctly.
	if (found) {
		self.ethernetClassificationCache[bsdName] = @(isEthernet);
		return isEthernet;
	}
	NSNumber *cached = self.ethernetClassificationCache[bsdName];
	return cached ? [cached boolValue] : NO;
}

// At launch: read the CURRENT raw link state of every WIRED ETHERNET interface (by listing
// all existing ".../Link" keys and filtering out WiFi/AWDL/other virtual ones) and record it
// as the dedup baseline for -updateLinkWithInterface: (so the very next real link-change event
// is compared against reality, not against nothing).
//
// BUG FIX (11-ago-2026): this used to also decide whether to ANNOUNCE the already-connected
// interface, gated on `[delegate onLaunchEnabled]` — but this method runs from -init (via
// -startObserving), which -loadPlugins calls BEFORE it calls -setDelegate: on the plugin (see
// HWGrowlPluginController.m: `id plugin = [[... alloc] init]; ... [plugin setDelegate:self];`
// happens strictly after). So `delegate` was always nil at the time this ran, `[delegate
// onLaunchEnabled]` was always messaging nil (silently NO), and an already-connected Ethernet
// cable was NEVER announced at launch — regardless of the user's actual "Show existing on
// launch" preference — since nothing ever re-read the baseline stashed below to fire it later.
// The announce decision now happens in -fireExistingWiredEthernetIfEnabled (below), called from
// -fireOnLaunchNotes once `delegate` is guaranteed to be set.
-(void)primeWiredLinkState {
	CFArrayRef keys = SCDynamicStoreCopyKeyList(dynStore, CFSTR("State:/Network/Interface/[^/]+/Link"));
	if (!keys) return;
	CFIndex count = CFArrayGetCount(keys);
	for (CFIndex i = 0; i < count; i++) {
		NSString *key = (__bridge NSString *)CFArrayGetValueAtIndex(keys, i);
		NSString *ifname = [self bsdNameFromLinkKey:key];
		if (!ifname || ![self isWiredEthernetInterface:ifname] || ![self readLinkActiveForKey:key]) continue;
		HWGrowlNetworkInterfaceStatus *st = [[HWGrowlNetworkInterfaceStatus alloc]
			initForInterface:ifname ofType:HWGEthernetInterface withStatus:@{@"Active": @1}];
		[networkInterfaceStates setObject:st forKey:ifname];
	}
	CFRelease(keys);
}

// Real announce decision for an Ethernet cable that was already connected before launch — see
// the BUG FIX comment on -primeWiredLinkState above for why this has to be a separate step.
// Called from -fireOnLaunchNotes, where `delegate` is safely non-nil. Removes the interface's
// primed baseline first so -updateLinkWithInterface:'s dedup sees this as a real change (old
// state "unknown") instead of "already active, nothing to report" — otherwise the very state
// -primeWiredLinkState just stored would suppress the announcement a second time.
-(void)fireExistingWiredEthernetIfEnabled {
	if (![delegate onLaunchEnabled]) return;
	CFArrayRef keys = SCDynamicStoreCopyKeyList(dynStore, CFSTR("State:/Network/Interface/[^/]+/Link"));
	if (!keys) return;
	CFIndex count = CFArrayGetCount(keys);
	for (CFIndex i = 0; i < count; i++) {
		NSString *key = (__bridge NSString *)CFArrayGetValueAtIndex(keys, i);
		NSString *ifname = [self bsdNameFromLinkKey:key];
		if (!ifname || ![self isWiredEthernetInterface:ifname] || ![self readLinkActiveForKey:key]) continue;
		[networkInterfaceStates removeObjectForKey:ifname];
		[self updateInterface:ifname forType:HWGEthernetInterface withStatus:@{@"Active": @1}];
	}
	CFRelease(keys);
}

// Fired by scCallback for a changed ".../Link" key: ignore anything that isn't a real wired
// Ethernet interface (see isWiredEthernetInterface: above), then feed the existing
// updateInterface: flow (dedup against the previous state happens there).
-(void)handleLinkKeyChanged:(NSString *)key {
	NSString *ifname = [self bsdNameFromLinkKey:key];
	if (!ifname || ![self isWiredEthernetInterface:ifname]) return;
	BOOL active = [self readLinkActiveForKey:key];
	[self updateInterface:ifname forType:HWGEthernetInterface withStatus:@{@"Active": @(active)}];
}

#pragma mark DHCP lease / Hostname / Location (final API audit, 18-ago-2026, batch 1)

// "State:/Network/Interface/<bsd>/DHCP" holds a dict with LeaseStartTime (an NSDate) whenever
// the interface actually holds a DHCP-assigned address. A changed LeaseStartTime for an
// interface we'd already seen a start time for is exactly "renewed/rebound" — the audit's
// candidate — as distinct from the FIRST time we see a lease (which is just the normal DHCP
// completion already implied by the existing IP-address-changed notification).
-(void)handleDHCPKeyChanged:(NSString *)key {
	if (![self boolForKey:HWG_NET_NOTIFY_DHCP_RENEWED_KEY default:NO]) return;
	NSArray<NSString *> *parts = [key componentsSeparatedByString:@"/"];
	if (parts.count < 4) return;
	NSString *ifname = parts[3];

	CFDictionaryRef d = SCDynamicStoreCopyValue(dynStore, (__bridge CFStringRef)key);
	if (!d) return;
	NSDate *leaseStart = [(__bridge NSDictionary *)d objectForKey:@"LeaseStartTime"];
	CFRelease(d);
	if (![leaseStart isKindOfClass:[NSDate class]]) return;

	NSDate *previous = self.lastKnownDHCPLeaseStartByInterface[ifname];
	self.lastKnownDHCPLeaseStartByInterface[ifname] = leaseStart;
	// First time seeing a lease for this interface (previous == nil) is the normal initial
	// DHCP completion, not a renewal — only a DIFFERENT start time on a KNOWN interface counts.
	if (!previous || [previous isEqualToDate:leaseStart]) return;

	[delegate notifyWithName:@"NetworkDHCPLeaseRenewed"
						 title:NSLocalizedString(@"DHCP Lease Renewed", @"")
					   description:[NSString stringWithFormat:NSLocalizedString(@"%@\nRenewed at %@", @""), ifname, leaseStart]
						  icon:HWGResolveIconDataNamed(@"HWGPrefsNetwork-Module")
			  identifierString:[NSString stringWithFormat:@"HWGrowlDHCPRenewed-%@", ifname]
				 contextString:nil
						plugin:self];
}

// "Setup:/System" holds the ComputerName the user sets in System Settings → General → Sharing.
-(void)checkComputerNameChanged {
	if (![self boolForKey:HWG_NET_NOTIFY_HOSTNAME_KEY default:NO]) return;
	CFDictionaryRef d = SCDynamicStoreCopyValue(dynStore, CFSTR("Setup:/System"));
	if (!d) return;
	NSString *name = [(__bridge NSDictionary *)d objectForKey:(__bridge NSString *)kSCPropSystemComputerName];
	CFRelease(d);
	if (![name isKindOfClass:[NSString class]]) return;

	NSString *previous = self.lastKnownComputerName;
	self.lastKnownComputerName = name;
	if (!previous || [previous isEqualToString:name]) return;

	[delegate notifyWithName:@"NetworkHostnameChanged"
						 title:NSLocalizedString(@"Computer Name Changed", @"")
					   description:[NSString stringWithFormat:NSLocalizedString(@"%@ → %@", @""), previous, name]
						  icon:HWGResolveIconDataNamed(@"HWGPrefsNetwork-Module")
			  identifierString:@"HWGrowlHostnameChanged"
				 contextString:nil
						plugin:self];
}

// "Setup:" (root Setup dict) holds CurrentSet — a path like "/Sets/4E3E9EA5-..." identifying
// which named Network Location (Home/Work/Automatic/etc.) is active. The human-readable name
// lives in the Setup dict at that same path, under kSCPropUserDefinedName.
-(void)checkLocationChanged {
	if (![self boolForKey:HWG_NET_NOTIFY_LOCATION_KEY default:NO]) return;
	CFDictionaryRef setupDict = SCDynamicStoreCopyValue(dynStore, CFSTR("Setup:"));
	if (!setupDict) return;
	NSString *currentSetPath = [(__bridge NSDictionary *)setupDict objectForKey:(__bridge NSString *)kSCPrefCurrentSet];
	CFRelease(setupDict);
	if (![currentSetPath isKindOfClass:[NSString class]]) return;

	NSString *name = currentSetPath.lastPathComponent;   // fallback: the Set's UUID
	CFDictionaryRef setDict = SCDynamicStoreCopyValue(dynStore, (__bridge CFStringRef)currentSetPath);
	if (setDict) {
		NSString *userDefinedName = [(__bridge NSDictionary *)setDict objectForKey:(__bridge NSString *)kSCPropUserDefinedName];
		if ([userDefinedName isKindOfClass:[NSString class]]) name = userDefinedName;
		CFRelease(setDict);
	}

	NSString *previous = self.lastKnownLocationName;
	self.lastKnownLocationName = name;
	if (!previous || [previous isEqualToString:name]) return;

	[delegate notifyWithName:@"NetworkLocationChanged"
						 title:NSLocalizedString(@"Network Location Changed", @"")
					   description:[NSString stringWithFormat:NSLocalizedString(@"%@ → %@", @""), previous, name]
						  icon:HWGResolveIconDataNamed(@"HWGPrefsNetwork-Module")
			  identifierString:@"HWGrowlLocationChanged"
				 contextString:nil
						plugin:self];
}

-(void)primeHostnameAndLocationState {
	// Silent baseline — same "no notification for the pre-existing state" convention every
	// other monitor follows — reuses the same read logic, just seeds the ivars first so the
	// first REAL change (not this priming call) is what gets compared and reported.
	CFDictionaryRef d = SCDynamicStoreCopyValue(dynStore, CFSTR("Setup:/System"));
	if (d) {
		NSString *name = [(__bridge NSDictionary *)d objectForKey:(__bridge NSString *)kSCPropSystemComputerName];
		if ([name isKindOfClass:[NSString class]]) self.lastKnownComputerName = name;
		CFRelease(d);
	}
	CFDictionaryRef setupDict = SCDynamicStoreCopyValue(dynStore, CFSTR("Setup:"));
	if (setupDict) {
		NSString *currentSetPath = [(__bridge NSDictionary *)setupDict objectForKey:(__bridge NSString *)kSCPrefCurrentSet];
		CFRelease(setupDict);
		if ([currentSetPath isKindOfClass:[NSString class]]) {
			NSString *name = currentSetPath.lastPathComponent;
			CFDictionaryRef setDict = SCDynamicStoreCopyValue(dynStore, (__bridge CFStringRef)currentSetPath);
			if (setDict) {
				NSString *userDefinedName = [(__bridge NSDictionary *)setDict objectForKey:(__bridge NSString *)kSCPropUserDefinedName];
				if ([userDefinedName isKindOfClass:[NSString class]]) name = userDefinedName;
				CFRelease(setDict);
			}
			self.lastKnownLocationName = name;
		}
	}
}

#pragma mark General Internet reachability (SCNetworkReachability, final API audit, 18-ago-2026)

static void HWGReachabilityCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info) {
	HWGrowlNetworkMonitor *observer = (__bridge HWGrowlNetworkMonitor *)info;
	[observer reachabilityFlagsChanged:flags];
}

-(void)startReachabilityMonitoring {
	// A zero address ("0.0.0.0") is the standard SCNetworkReachability idiom for "general
	// Internet reachability" — not a specific host, matching the audit's "Reachability
	// perdida/recuperada" (general, not per-destination) candidate.
	struct sockaddr_in zeroAddress;
	bzero(&zeroAddress, sizeof(zeroAddress));
	zeroAddress.sin_len = sizeof(zeroAddress);
	zeroAddress.sin_family = AF_INET;

	reachabilityRef = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr *)&zeroAddress);
	if (!reachabilityRef) return;

	SCNetworkReachabilityContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
	if (SCNetworkReachabilitySetCallback(reachabilityRef, HWGReachabilityCallback, &context)) {
		SCNetworkReachabilityScheduleWithRunLoop(reachabilityRef, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
	}
	// Silent baseline — same convention as every other feature's initial priming.
	SCNetworkReachabilityFlags flags;
	if (SCNetworkReachabilityGetFlags(reachabilityRef, &flags)) {
		lastReachabilityFlags = flags;
		haveLastReachabilityFlags = YES;
	}
}

-(void)reachabilityFlagsChanged:(SCNetworkReachabilityFlags)flags {
	BOOL wasReachable = haveLastReachabilityFlags && (lastReachabilityFlags & kSCNetworkReachabilityFlagsReachable);
	BOOL nowReachable = (flags & kSCNetworkReachabilityFlagsReachable) != 0;
	BOOL hadPrevious = haveLastReachabilityFlags;
	lastReachabilityFlags = flags;
	haveLastReachabilityFlags = YES;

	if (!hadPrevious || wasReachable == nowReachable) return;
	if (![self boolForKey:HWG_NET_NOTIFY_REACHABILITY_KEY default:NO]) return;

	[delegate notifyWithName:@"NetworkReachabilityChanged"
						 title:nowReachable ? NSLocalizedString(@"Internet Reachable", @"") : NSLocalizedString(@"Internet Unreachable", @"")
					   description:nowReachable ? NSLocalizedString(@"General Internet connectivity was restored", @"") : NSLocalizedString(@"General Internet connectivity was lost", @"")
						  icon:HWGResolveIconDataNamed(@"HWGPrefsNetwork-Module")
			  identifierString:@"HWGrowlReachabilityChanged"
				 contextString:nil
						plugin:self];
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
	if (![self boolForKey:HWG_NET_NOTIFY_WIFI_OFF_KEY default:YES]) return;
	NSData *iconData = [HWGResolveIconNamed(@"Network-Wifi-Off") TIFFRepresentation];
    [delegate notifyWithName:@"AirportDisconnected"
							 title:NSLocalizedString(@"AirPort Disconnected", @"")
					 description:[NSString stringWithFormat:NSLocalizedString(@"Left network %@.", @""), networkName]
							  icon:iconData
			  identifierString:@"HWGrowlAirPort"
				  contextString:nil 
							plugin:self];
}

// Icon name for the current signal. rssiValue does NOT require Location permission.
-(NSString*)wifiIconNameForCurrentSignal {
	CWInterface *iface = [self.wifiClient interface];
	NSInteger rssi = iface ? [iface rssiValue] : 0;
	return [NSString stringWithFormat:@"Network-Wifi-%ld", (long)HWGWifiBarsForRSSI(rssi)];
}

// F33: generic reader for a per-field visibility toggle, defaulting to `def` when unset.
-(BOOL)boolForKey:(NSString *)key default:(BOOL)def {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

// "2.4 GHz" / "5 GHz" / "6 GHz". None of channelBand/activePHYMode/security require
// Location permission (unlike ssid/bssid) — they describe the RADIO/PROTOCOL, not the
// network's identity.
-(NSString*)wifiBandStringForChannel:(CWChannel*)channel {
	switch ([channel channelBand]) {
		case kCWChannelBand2GHz: return NSLocalizedString(@"2.4 GHz", @"");
		case kCWChannelBand5GHz: return NSLocalizedString(@"5 GHz", @"");
		case kCWChannelBand6GHz: return NSLocalizedString(@"6 GHz", @"");
		default:                 return NSLocalizedString(@"Unknown", @"");
	}
}

// Maps the 802.11 PHY mode to the consumer "Wi-Fi N" generation name most people
// recognize. 6GHz-band 802.11ax is marketed as "Wi-Fi 6E" rather than plain "Wi-Fi 6".
-(NSString*)wifiGenerationStringForPHYMode:(CWPHYMode)mode band:(CWChannelBand)band {
	switch (mode) {
		case kCWPHYMode11be: return NSLocalizedString(@"Wi-Fi 7", @"");
		case kCWPHYMode11ax: return (band == kCWChannelBand6GHz)
			? NSLocalizedString(@"Wi-Fi 6E", @"")
			: NSLocalizedString(@"Wi-Fi 6", @"");
		case kCWPHYMode11ac: return NSLocalizedString(@"Wi-Fi 5", @"");
		case kCWPHYMode11n:  return NSLocalizedString(@"Wi-Fi 4", @"");
		case kCWPHYMode11a:
		case kCWPHYMode11b:
		case kCWPHYMode11g:  return NSLocalizedString(@"Legacy 802.11", @"");
		default:             return NSLocalizedString(@"Unknown", @"");
	}
}

-(NSString*)wifiSecurityStringForSecurity:(CWSecurity)security {
	switch (security) {
		case kCWSecurityNone:               return NSLocalizedString(@"Open (no security)", @"");
		case kCWSecurityWEP:
		case kCWSecurityDynamicWEP:          return @"WEP";
		case kCWSecurityWPAPersonal:
		case kCWSecurityWPAPersonalMixed:    return @"WPA Personal";
		case kCWSecurityWPA2Personal:
		case kCWSecurityPersonal:            return @"WPA2 Personal";
		case kCWSecurityWPA3Personal:        return @"WPA3 Personal";
		case kCWSecurityWPA3Transition:      return @"WPA2/WPA3 Personal";
		case kCWSecurityWPAEnterprise:
		case kCWSecurityWPAEnterpriseMixed:  return @"WPA Enterprise";
		case kCWSecurityWPA2Enterprise:
		case kCWSecurityEnterprise:          return @"WPA2 Enterprise";
		case kCWSecurityWPA3Enterprise:      return @"WPA3 Enterprise";
		case kCWSecurityOWE:
		case kCWSecurityOWETransition:       return NSLocalizedString(@"Enhanced Open (OWE)", @"");
		default:                             return NSLocalizedString(@"Unknown", @"");
	}
}

// F33: builds the "Band:"/"Wi-Fi:"/"Security:" lines for the current connection —
// EACH individually toggleable from Preferences → Modules → Network Monitor. Band and
// generation combine onto one line ("Band: 5 GHz (Wi-Fi 6)") when both are enabled;
// otherwise each gets its own line. Returns nil if nothing is enabled or the interface
// isn't associated.
-(NSString*)wifiExtraInfoLines {
	BOOL showBand    = [self boolForKey:HWG_WIFI_SHOW_BAND_KEY default:YES];
	BOOL showGen     = [self boolForKey:HWG_WIFI_SHOW_GENERATION_KEY default:YES];
	BOOL showSec     = [self boolForKey:HWG_WIFI_SHOW_SECURITY_KEY default:YES];
	BOOL showRate    = [self boolForKey:HWG_WIFI_SHOW_RATE_KEY default:NO];
	BOOL showChannel = [self boolForKey:HWG_WIFI_SHOW_CHANNEL_KEY default:NO];
	BOOL showSNR     = [self boolForKey:HWG_WIFI_SHOW_SNR_KEY default:NO];
	BOOL showCountry = [self boolForKey:HWG_WIFI_SHOW_COUNTRY_KEY default:NO];
	BOOL showTxPower = [self boolForKey:HWG_WIFI_SHOW_TXPOWER_KEY default:NO];
	BOOL showHWAddr  = [self boolForKey:HWG_WIFI_SHOW_HWADDR_KEY default:NO];
	BOOL showMode    = [self boolForKey:HWG_WIFI_SHOW_MODE_KEY default:NO];
	if (!showBand && !showGen && !showSec && !showRate && !showChannel && !showSNR
		&& !showCountry && !showTxPower && !showHWAddr && !showMode) return nil;

	CWInterface *iface = [self.wifiClient interface];
	if (!iface) return nil;
	CWChannel *channel = [iface wlanChannel];
	if (!channel) return nil;

	NSString *band = [self wifiBandStringForChannel:channel];
	NSString *gen  = [self wifiGenerationStringForPHYMode:[iface activePHYMode] band:[channel channelBand]];
	NSString *sec  = [self wifiSecurityStringForSecurity:[iface security]];

	NSMutableArray *lines = [NSMutableArray array];
	if (showBand && showGen) {
		[lines addObject:[NSString stringWithFormat:
			NSLocalizedString(@"Band:\t%@ (%@)", "First %@ = band e.g. '5 GHz', second %@ = generation e.g. 'Wi-Fi 6'"), band, gen]];
	} else if (showBand) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Band:\t%@", ""), band]];
	} else if (showGen) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Wi-Fi Generation:\t%@", ""), gen]];
	}
	if (showSec) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Security:\t%@", ""), sec]];
	}
	// Transmit rate (Mbps) — CWInterface.transmitRate, public, no Location permission needed.
	if (showRate) {
		double rate = [iface transmitRate];
		if (rate > 0) {
			[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Link Rate:\t%.0f Mbps", ""), rate]];
		}
	}
	// Channel number + width — CWChannel.channelNumber/channelWidth, same object already read for band.
	if (showChannel) {
		NSString *widthStr;
		switch ([channel channelWidth]) {
			case kCWChannelWidth20MHz:  widthStr = @"20 MHz"; break;
			case kCWChannelWidth40MHz:  widthStr = @"40 MHz"; break;
			case kCWChannelWidth80MHz:  widthStr = @"80 MHz"; break;
			case kCWChannelWidth160MHz: widthStr = @"160 MHz"; break;
			default:                    widthStr = NSLocalizedString(@"Unknown", @""); break;
		}
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Channel:\t%ld (%@)", "First %ld = channel number, %@ = width e.g. '80 MHz'"), (long)[channel channelNumber], widthStr]];
	}
	// Noise floor (dBm) + derived SNR — CWInterface.noiseMeasurement, public, combined with the
	// RSSI this monitor already reads elsewhere for a real signal-to-noise ratio (a materially
	// better quality indicator than RSSI alone).
	if (showSNR) {
		NSInteger noise = [iface noiseMeasurement];
		NSInteger rssi = [iface rssiValue];
		if (noise != 0) {
			[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Noise:\t%ld dBm (SNR: %ld dB)", "First %ld = noise floor in dBm, second %ld = signal-to-noise ratio in dB"), (long)noise, (long)(rssi - noise)]];
		}
	}
	// Final API audit (18-ago-2026), batch 2 — CWInterface.countryCode/transmitPower/
	// hardwareAddress/interfaceMode, all public since macOS 10.6/10.7.
	if (showCountry) {
		NSString *country = [iface countryCode];
		if (country.length) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Regulatory country/region:\t%@", @""), country]];
	}
	if (showTxPower) {
		NSInteger power = [iface transmitPower];
		if (power != 0) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Transmit power:\t%ld dBm", @""), (long)power]];
	}
	if (showHWAddr) {
		NSString *hwAddr = [iface hardwareAddress];
		if (hwAddr.length) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Wi-Fi hardware address:\t%@", @""), hwAddr]];
	}
	if (showMode) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Interface mode:\t%@", @""), [self wifiInterfaceModeLabel:[iface interfaceMode]]]];
	}
	return [lines count] ? [lines componentsJoinedByString:@"\n"] : nil;
}

-(void)airportConnected:(NSString*)name bssid:(NSData*)data {
	BOOL showSSID  = [self boolForKey:HWG_WIFI_SHOW_SSID_KEY default:YES];
	BOOL showBSSID = [self boolForKey:HWG_WIFI_SHOW_BSSID_KEY default:YES];

	// BSSID is nil when Location permission is denied (macOS 10.14+). Build a
	// description with whatever info we have, never deref a NULL buffer.
	NSMutableArray *lines = [NSMutableArray arrayWithObject:NSLocalizedString(@"Joined network.", @"")];
	if (showSSID) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"SSID:\t%@", ""), name]];
	}
	if (showBSSID && data && [data length] >= 6) {
		const unsigned char *bssidBytes = [data bytes];
		NSString *bssid = [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",
								 bssidBytes[0], bssidBytes[1], bssidBytes[2],
								 bssidBytes[3], bssidBytes[4], bssidBytes[5]];
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"BSSID:\t%@", ""), bssid]];
	}
	NSString *description = [lines componentsJoinedByString:@"\n"];

	NSString *extra = [self wifiExtraInfoLines];
	if (extra) description = [description stringByAppendingFormat:@"\n%@", extra];

	NSData *iconData = [HWGResolveIconNamed([self wifiIconNameForCurrentSignal]) TIFFRepresentation];

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
	BOOL showInterface = [self boolForKey:HWG_ETH_SHOW_INTERFACE_KEY default:YES];
	BOOL showSpeed     = [self boolForKey:HWG_ETH_SHOW_SPEED_KEY default:YES];
	BOOL showMode      = [self boolForKey:HWG_ETH_SHOW_MODE_KEY default:YES];

	if (newActive && !oldActive) {
		// Use the Ethernet connector icon only for interfaces with a recognized Ethernet
		// media (e.g. "1000baseT/full-duplex"); unidentified interfaces (media "Unknown"
		// or unreadable — e.g. an iPhone/USB net interface) get a generic interface icon.
		NSString *mode = nil;
		NSString *speed = [self getMediaTypeForInterface:interfaceString mode:&mode];
		BOOL isEthernet = (speed != nil && ![speed hasPrefix:@"Unknown"]);
		[interfaceIsEthernet setObject:@(isEthernet) forKey:interfaceString];
		noteName = @"NetworkLinkUp";
		noteTitle = NSLocalizedString(@"Network Link Up", @"");

		NSMutableArray *lines = [NSMutableArray array];
		if (showInterface) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Interface:\t%@", ""), interfaceString]];
		if (showSpeed)     [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Speed:\t%@", ""), speed ?: NSLocalizedString(@"Unknown", @"")]];
		if (showMode && mode) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Mode:\t%@", ""), mode]];
		noteDescription = [lines count] ? [lines componentsJoinedByString:@"\n"] : nil;
		imageName = isEthernet ? @"Network-Ethernet-On" : @"Network-Interface-On";
	} else if (!newActive && oldActive) {
		// Match the icon family chosen when the interface came up (media is often
		// unreadable once it's down). Default to the generic interface icon.
		BOOL isEthernet = [[interfaceIsEthernet objectForKey:interfaceString] boolValue];
		[interfaceIsEthernet removeObjectForKey:interfaceString];
		[lastKnownEthernetSpeed removeObjectForKey:interfaceString];
		noteName = @"NetworkLinkDown";
		noteTitle = NSLocalizedString(@"Network Link Down", @"");
		noteDescription = showInterface
			? [NSString stringWithFormat:NSLocalizedString(@"Interface:\t%@", nil), interfaceString]
			: nil;
		imageName = isEthernet ? @"Network-Ethernet-Off" : @"Network-Interface-Off";
	}
	
	NSString *rowKey = nil;
	if ([imageName isEqualToString:@"Network-Ethernet-On"]) rowKey = HWG_NET_NOTIFY_ETH_ON_KEY;
	else if ([imageName isEqualToString:@"Network-Ethernet-Off"]) rowKey = HWG_NET_NOTIFY_ETH_OFF_KEY;
	else if ([imageName isEqualToString:@"Network-Interface-On"]) rowKey = HWG_NET_NOTIFY_OTHER_ON_KEY;
	else if ([imageName isEqualToString:@"Network-Interface-Off"]) rowKey = HWG_NET_NOTIFY_OTHER_OFF_KEY;
	if (rowKey && ![self boolForKey:rowKey default:YES]) noteName = nil;

	if(noteName){
		// imageName is only nil when neither transition branch above ran, i.e. exactly the
		// case where noteName is also still nil — so it's always set here.
		NSData *iconData = [HWGResolveIconNamed(imageName) TIFFRepresentation];
		[delegate notifyWithName:noteName
								 title:noteTitle
						 description:noteDescription
								  icon:iconData
				  identifierString:@"HWGrowlNetworkLink"
					  contextString:nil
								plugin:self];
	}
}

// A cable degrading (e.g. 1000baseT -> 100baseTX) doesn't drop the link, so
// -updateLinkWithInterface: never fires again for it — that only reacts to the SCDynamicStore
// "Link" key toggling. Polling is the only way to catch a live speed change on an already-up
// interface. Runs on a fixed, generous interval (not user-configurable, unlike the Wi-Fi signal
// poll) since a degraded cable is a rare, slow-changing condition, not something needing
// near-real-time feedback.
-(void)startEthernetSpeedPolling {
	[ethernetSpeedPollTimer invalidate];
	self.ethernetSpeedPollTimer = [NSTimer scheduledTimerWithTimeInterval:20.0
	                                                                 target:self
	                                                               selector:@selector(pollEthernetSpeed:)
	                                                               userInfo:nil
	                                                                repeats:YES];
}

-(void)pollEthernetSpeed:(NSTimer *)timer {
	if (![self boolForKey:HWG_NET_NOTIFY_ETH_SPEED_KEY default:NO]) return;

	for (NSString *interfaceString in [interfaceIsEthernet allKeys]) {
		if (![[interfaceIsEthernet objectForKey:interfaceString] boolValue]) continue; // not a recognized Ethernet link
		NSString *mode = nil;
		NSString *speed = [self getMediaTypeForInterface:interfaceString mode:&mode];
		if (!speed) continue; // interface went away or media unreadable this tick; the Link-down path handles disappearance

		NSString *previousSpeed = [lastKnownEthernetSpeed objectForKey:interfaceString];
		if (previousSpeed == nil) {
			// First observation since link-up (or since app launch): baseline silently.
			[lastKnownEthernetSpeed setObject:speed forKey:interfaceString];
			continue;
		}
		if ([previousSpeed isEqualToString:speed]) continue;

		[lastKnownEthernetSpeed setObject:speed forKey:interfaceString];
		NSData *iconData = [HWGResolveIconNamed(@"Network-Ethernet-Speed") TIFFRepresentation];
		[delegate notifyWithName:@"NetworkLinkSpeedChanged"
								 title:NSLocalizedString(@"Ethernet Speed Changed", @"")
						 description:[NSString stringWithFormat:NSLocalizedString(@"%@:\t%@ → %@", @""), interfaceString, previousSpeed, speed]
								  icon:iconData
				  identifierString:@"HWGrowlNetworkLinkSpeed"
					  contextString:nil
								plugin:self];
	}
}

/* TO DO: REWRITE ME WITH BETTER METHODS OF GETTING INFO */
// Returns the media speed (e.g. "1000baseT"), and — via `outMode` — the duplex/other
// shared options (e.g. "full-duplex"), kept as SEPARATE pieces so the caller can label
// them individually ("Speed:" / "Mode:") instead of one combined "100baseT <full-duplex>"
// string. `outMode` is set to nil when there are no shared options to report.
- (NSString *)getMediaTypeForInterface:(NSString*)interfaceString mode:(NSString **)outMode {
	// This is all made by looking through Darwin's src/network_cmds/ifconfig.tproj.
	// There's no pretty way to get media stuff; I've stripped it down to the essentials
	// for what I'm doing.

	if (outMode) *outMode = nil;

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

	if (outMode) *outMode = options;

	return [NSString stringWithUTF8String:type];
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

// Reads the gateway (Router) PER INTERFACE from SCDynamicStore, keyed by BSD interface
// name (e.g. "en0" -> "10.4.200.2"), by enumerating every network service's live State
// dictionary — "State:/Network/Service/<uuid>/IPv4" or ".../IPv6" — which each carry their
// own "InterfaceName" and "Router". This replaces reading only the single Global/IPv4(6)
// dictionary, which reflects just the system's ONE primary/default route: with multiple
// active interfaces on DIFFERENT subnets (e.g. Wi-Fi + a USB-Ethernet dock), the Global
// dictionary silently drops every gateway except the primary one. Per-service lookup
// reports every interface's own gateway, matching what's actually shown for each interface.
- (NSDictionary *)gatewaysByInterfaceForProtocol:(NSString *)proto {
	NSMutableDictionary *result = [NSMutableDictionary dictionary];
	NSString *pattern = [NSString stringWithFormat:@"State:/Network/Service/[^/]+/%@", proto];
	CFArrayRef keys = SCDynamicStoreCopyKeyList(dynStore, (__bridge CFStringRef)pattern);
	if (!keys) return result;
	CFIndex count = CFArrayGetCount(keys);
	for (CFIndex i = 0; i < count; i++) {
		CFStringRef key = CFArrayGetValueAtIndex(keys, i);
		CFDictionaryRef d = SCDynamicStoreCopyValue(dynStore, key);
		if (!d) continue;
		NSDictionary *dict = (__bridge NSDictionary *)d;
		NSString *ifname = dict[@"InterfaceName"];
		NSString *router = dict[@"Router"];
		if (ifname && router) result[ifname] = router;
		CFRelease(d);
	}
	CFRelease(keys);
	return result;
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

// F34 #4: BSD interface-name prefixes macOS uses for VPN/tunnel interfaces — "utun" covers
// IKEv2/IPSec, WireGuard, and most modern VPN clients (incl. the built-in VPN pane and
// third-party apps like Tunnelblick/NordVPN/etc.); "ppp" covers legacy PPTP/L2TP. This is a
// HEURISTIC, not a definitive check: macOS also uses utun for some non-VPN system services
// (e.g. Content Filter / Network Extension–based features), so a false positive is possible
// in principle — documented in README. A utun/ppp interface with NO address assigned yet
// (or one that lost its address) is not counted as "connected".
-(NSArray<NSString*> *)vpnLikeInterfaceNamesFromIPInfo:(NSArray *)ipv4Info ipv6:(NSArray *)ipv6Info {
	NSMutableSet<NSString*> *names = [NSMutableSet set];
	for (NSDictionary *info in ipv4Info) {
		NSString *ifname = info[@"if"];
		if ([ifname hasPrefix:@"utun"] || [ifname hasPrefix:@"ppp"] || [ifname hasPrefix:@"ipsec"]) {
			[names addObject:ifname];
		}
	}
	for (NSDictionary *info in ipv6Info) {
		NSString *ifname = info[@"if"];
		if ([ifname hasPrefix:@"utun"] || [ifname hasPrefix:@"ppp"] || [ifname hasPrefix:@"ipsec"]) {
			[names addObject:ifname];
		}
	}
	return [names allObjects];
}

// F34 #4: compares the current set of VPN-like interfaces against activeVPNInterfaceNames
// and fires a connect/disconnect notice for each TRANSITION. OFF by default.
-(void)checkVPNTransitionsWithIPv4Info:(NSArray *)ipv4Info ipv6Info:(NSArray *)ipv6Info {
	if (![self boolForKey:HWG_VPN_NOTIFY_KEY default:NO]) return;

	NSSet<NSString*> *currentNames = [NSSet setWithArray:[self vpnLikeInterfaceNamesFromIPInfo:ipv4Info ipv6:ipv6Info]];

	NSMutableSet<NSString*> *newlyConnected = [currentNames mutableCopy];
	[newlyConnected minusSet:self.activeVPNInterfaceNames];
	NSMutableSet<NSString*> *newlyDisconnected = [self.activeVPNInterfaceNames mutableCopy];
	[newlyDisconnected minusSet:currentNames];

	// BUG FIX (04-ago-2026): reused the plain generic network globe icon here originally —
	// confirmed live (user testing with Surfshark) this read as generic/wrong for a VPN-
	// specific notification. Replaced with a dedicated shield+lock icon (own arte, matching
	// this monitor's teal accent color from Network-Generic-On.png).
	NSData *onIcon  = [HWGResolveIconNamed(@"Network-VPN-On") TIFFRepresentation];
	NSData *offIcon = [HWGResolveIconNamed(@"Network-VPN-Off") TIFFRepresentation];

	for (NSString *ifname in newlyConnected) {
		[delegate notifyWithName:@"VPNConnected"
								 title:NSLocalizedString(@"VPN Connected", @"")
						 description:[NSString stringWithFormat:NSLocalizedString(@"Interface:\t%@", @""), ifname]
								  icon:onIcon
				  identifierString:[NSString stringWithFormat:@"HWGrowlVPN-%@", ifname]
					  contextString:nil
								plugin:self];
	}
	for (NSString *ifname in newlyDisconnected) {
		[delegate notifyWithName:@"VPNDisconnected"
								 title:NSLocalizedString(@"VPN Disconnected", @"")
						 description:[NSString stringWithFormat:NSLocalizedString(@"Interface:\t%@", @""), ifname]
								  icon:offIcon
				  identifierString:[NSString stringWithFormat:@"HWGrowlVPN-%@", ifname]
					  contextString:nil
								plugin:self];
	}

	self.activeVPNInterfaceNames = [currentNames mutableCopy];
}

// Both DNS servers and the primary interface live in State:/Network/Global/* dicts (like the
// gateway already read elsewhere) — a direct SCDynamicStore read, not the kernel ioctl path
// used for per-interface addresses.
-(void)checkDNSServersChanged {
	if (![self boolForKey:HWG_NET_NOTIFY_DNS_KEY default:NO]) return;
	CFDictionaryRef d = SCDynamicStoreCopyValue(dynStore, CFSTR("State:/Network/Global/DNS"));
	if (!d) return;
	NSDictionary *dict = (__bridge_transfer NSDictionary *)d;
	NSArray<NSString *> *servers = dict[@"ServerAddresses"];
	if (!servers) return;

	if (lastKnownDNSServers && ![lastKnownDNSServers isEqualToArray:servers]) {
		NSData *iconData = [HWGResolveIconNamed(@"Network-Generic-On") TIFFRepresentation];
		[delegate notifyWithName:@"DNSServersChanged"
								 title:NSLocalizedString(@"DNS Servers Changed", @"")
						 description:[NSString stringWithFormat:NSLocalizedString(@"%@ → %@", @""),
						              [lastKnownDNSServers componentsJoinedByString:@", "],
						              [servers componentsJoinedByString:@", "]]
								  icon:iconData
				  identifierString:@"HWGrowlDNSServers"
					  contextString:nil
								plugin:self];
	}
	self.lastKnownDNSServers = servers;
}

-(void)checkPrimaryInterfaceChanged {
	if (![self boolForKey:HWG_NET_NOTIFY_PRIMARY_IF_KEY default:NO]) return;
	CFDictionaryRef d = SCDynamicStoreCopyValue(dynStore, CFSTR("State:/Network/Global/IPv4"));
	if (!d) return;
	NSDictionary *dict = (__bridge_transfer NSDictionary *)d;
	NSString *primary = dict[@"PrimaryInterface"];
	if (!primary) return;

	if (lastKnownPrimaryInterface && ![lastKnownPrimaryInterface isEqualToString:primary]) {
		NSDictionary *friendly = [self bsdToFriendlyNameMap];
		NSData *iconData = [HWGResolveIconNamed(@"Network-Generic-On") TIFFRepresentation];
		[delegate notifyWithName:@"PrimaryInterfaceChanged"
								 title:NSLocalizedString(@"Primary Network Interface Changed", @"")
						 description:[NSString stringWithFormat:NSLocalizedString(@"%@ → %@", @""),
						              friendly[lastKnownPrimaryInterface] ?: lastKnownPrimaryInterface,
						              friendly[primary] ?: primary]
								  icon:iconData
				  identifierString:@"HWGrowlPrimaryInterface"
					  contextString:nil
								plugin:self];
	}
	self.lastKnownPrimaryInterface = primary;
}

// Added 17-ago-2026 (feedback del usuario) — proxy configuration (HTTP/HTTPS/SOCKS/PAC),
// same SCDynamicStore family already used for DNS/primary-interface above
// (State:/Network/Global/Proxies is the public key SCDynamicStoreCopyProxies()/System
// Settings → Network → Proxies itself is built on). Reports only whether ANY proxy got
// turned on/off/changed, not a full per-protocol diff — matches this monitor's existing
// "one line, what changed" style for DNS/primary-interface.
-(void)checkProxyConfigChanged {
	if (![self boolForKey:HWG_NET_NOTIFY_PROXY_KEY default:NO]) return;
	CFDictionaryRef d = SCDynamicStoreCopyValue(dynStore, CFSTR("State:/Network/Global/Proxies"));
	if (!d) return;
	NSDictionary *dict = (__bridge_transfer NSDictionary *)d;

	BOOL httpEnabled  = [dict[@"HTTPEnable"] boolValue];
	BOOL httpsEnabled = [dict[@"HTTPSEnable"] boolValue];
	BOOL socksEnabled = [dict[@"SOCKSEnable"] boolValue];
	BOOL pacEnabled   = [dict[@"ProxyAutoConfigEnable"] boolValue];
	NSString *summary = [NSString stringWithFormat:@"%d|%d|%d|%d|%@|%@",
		httpEnabled, httpsEnabled, socksEnabled, pacEnabled,
		dict[@"HTTPProxy"] ?: @"", dict[@"ProxyAutoConfigURLString"] ?: @""];

	if (lastKnownProxySummary && ![lastKnownProxySummary isEqualToString:summary]) {
		NSMutableArray<NSString *> *active = [NSMutableArray array];
		if (httpEnabled)  [active addObject:@"HTTP"];
		if (httpsEnabled) [active addObject:@"HTTPS"];
		if (socksEnabled) [active addObject:@"SOCKS"];
		if (pacEnabled)   [active addObject:@"Auto-Config (PAC)"];
		NSString *desc = [active count]
			? [NSString stringWithFormat:NSLocalizedString(@"Active: %@", @""), [active componentsJoinedByString:@", "]]
			: NSLocalizedString(@"No proxy configured", @"");
		NSData *iconData = [HWGResolveIconNamed(@"Network-Proxy-On") TIFFRepresentation];
		[delegate notifyWithName:@"ProxyConfigChanged"
								 title:NSLocalizedString(@"Proxy Configuration Changed", @"")
						 description:desc
								  icon:iconData
				  identifierString:@"HWGrowlProxyConfig"
					  contextString:nil
								plugin:self];
	}
	self.lastKnownProxySummary = summary;
}

-(void)updateIP {
	NSDictionary *friendly     = [self bsdToFriendlyNameMap];
	NSArray  *ipv4Info         = [self collectIPv4InfoFromKernel];
	NSArray  *ipv6Info         = [self collectIPv6InfoFromKernel];
	[self checkVPNTransitionsWithIPv4Info:ipv4Info ipv6Info:ipv6Info];
	[self checkDNSServersChanged];
	[self checkPrimaryInterfaceChanged];
	[self checkProxyConfigChanged];
	NSDictionary *ipv4Gateways = [self gatewaysByInterfaceForProtocol:@"IPv4"];
	NSDictionary *ipv6Gateways = [self gatewaysByInterfaceForProtocol:@"IPv6"];

	// F33: each field individually toggleable from Preferences → Modules → Network Monitor.
	// Routability still drives icon choice below regardless of what's actually displayed.
	BOOL showIPv4        = [self boolForKey:HWG_IP_SHOW_IPV4_KEY default:YES];
	BOOL showIPv6        = [self boolForKey:HWG_IP_SHOW_IPV6_KEY default:YES];
	BOOL showGateway     = [self boolForKey:HWG_IP_SHOW_GATEWAY_KEY default:YES];
	BOOL showNonRoutable = [self boolForKey:HWG_IP_SHOW_NONROUTABLE_KEY default:YES];
	BOOL useFriendly     = [self boolForKey:HWG_IP_USE_FRIENDLY_KEY default:YES];
	BOOL showOldNew      = [self boolForKey:HWG_IP_SHOW_OLDNEW_KEY default:YES];

	NSString *nonRoutableTag = NSLocalizedString(@"(non-routable)", @"");
	BOOL anyRoutable = NO;

	// #9: seen-this-pass sets so addresses that disappeared entirely (interface unplugged,
	// DHCP lease dropped) don't leave a stale "old" value forever haunting a future re-add.
	NSMutableSet<NSString *> *seenIPv4Interfaces = [NSMutableSet set];
	NSMutableSet<NSString *> *seenIPv6Interfaces = [NSMutableSet set];

	NSMutableArray *lines = [NSMutableArray array];
	for (NSDictionary *info in ipv4Info) {
		BOOL r = [info[@"routable"] boolValue];
		if (r) anyRoutable = YES;
		NSString *bsdName = info[@"if"];
		NSString *currentAddr = info[@"ip"];
		[seenIPv4Interfaces addObject:bsdName];
		NSString *previousAddr = self.previousIPv4ByInterface[bsdName];
		self.previousIPv4ByInterface[bsdName] = currentAddr;
		if (!showIPv4) continue;
		NSString *ifname = useFriendly ? (friendly[bsdName] ?: bsdName) : bsdName;
		NSString *addrPart = (showOldNew && previousAddr && ![previousAddr isEqualToString:currentAddr])
			? [NSString stringWithFormat:@"%@/%@ → %@/%@", previousAddr, info[@"cidr"], currentAddr, info[@"cidr"]]
			: [NSString stringWithFormat:@"%@/%@", currentAddr, info[@"cidr"]];
		[lines addObject:[NSString stringWithFormat:@"%@ — IPv4:\t%@", ifname, addrPart]];
		if (!r && showNonRoutable) [lines addObject:nonRoutableTag];   // tag on its own line
		// Each interface's own gateway (not just the system's single primary route) —
		// so a secondary interface (e.g. a USB-Ethernet dock on a different subnet)
		// still gets its gateway reported.
		NSString *gw = ipv4Gateways[bsdName];
		if (gw && showGateway) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Gateway:\t%@", @""), gw]];
	}
	[self.previousIPv4ByInterface removeObjectsForKeys:[self.previousIPv4ByInterface.allKeys filteredArrayUsingPredicate:
		[NSPredicate predicateWithBlock:^BOOL(NSString *key, NSDictionary *bindings) { return ![seenIPv4Interfaces containsObject:key]; }]]];
	for (NSDictionary *info in ipv6Info) {
		BOOL r = [info[@"routable"] boolValue];
		if (r) anyRoutable = YES;
		NSString *bsdName = info[@"if"];
		[seenIPv6Interfaces addObject:bsdName];
		NSString *currentAddr6 = info[@"ip"];
		NSString *previousAddr6 = self.previousIPv6ByInterface[bsdName];
		self.previousIPv6ByInterface[bsdName] = currentAddr6;
		if (!showIPv6) continue;
		NSString *ifname = useFriendly ? (friendly[bsdName] ?: bsdName) : bsdName;
		NSString *addr6Part = (showOldNew && previousAddr6 && ![previousAddr6 isEqualToString:currentAddr6])
			? [NSString stringWithFormat:@"%@ → %@", previousAddr6, currentAddr6]
			: currentAddr6;
		[lines addObject:[NSString stringWithFormat:@"%@ — IPv6:\t%@", ifname, addr6Part]];
		if (!r && showNonRoutable) [lines addObject:nonRoutableTag];   // tag on its own line
		NSString *gw = ipv6Gateways[bsdName];
		if (gw && showGateway) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Gateway:\t%@", @""), gw]];
	}
	[self.previousIPv6ByInterface removeObjectsForKeys:[self.previousIPv6ByInterface.allKeys filteredArrayUsingPredicate:
		[NSPredicate predicateWithBlock:^BOOL(NSString *key, NSDictionary *bindings) { return ![seenIPv6Interfaces containsObject:key]; }]]];

	NSString *combined = [lines componentsJoinedByString:@"\n"];
	BOOL hasAddressesNow = ([ipv4Info count] + [ipv6Info count]) > 0;

	// The "released" transition is decided from actual address PRESENCE (independent of
	// the F33 display toggles, which can make `combined` empty even with real addresses
	// still up); the displayed-text dedup below is separate and only skips a re-fire when
	// what would actually be SHOWN hasn't changed.
	if (!hasAddressesNow && !previousHasIPAddresses)
		return;   // fresh launch with no connection, or already reported "released"
	if (hasAddressesNow && [combined isEqualTo:previousIPCombined])
		return;   // addresses present but nothing in the visible text changed

	self.previousHasIPAddresses = hasAddressesNow;
	self.previousIPCombined = combined;

	NSString *description = nil;
	NSString *imageName   = nil;

	if (!hasAddressesNow) {
		description = NSLocalizedString(@"IP address released", @"");
		imageName   = @"Network-Generic-Off";
	} else {
		description = [combined length] ? combined : NSLocalizedString(@"IP address updated", @"");
		// Icon reflects whether we have real connectivity (a routable address)
		// or only self-assigned addresses.
		imageName   = anyRoutable ? @"Network-Generic-On" : @"Network-Generic-Off";
	}

	NSString *genericRowKey = [imageName isEqualToString:@"Network-Generic-On"] ? HWG_NET_NOTIFY_GENERIC_ON_KEY : HWG_NET_NOTIFY_GENERIC_OFF_KEY;
	if (![self boolForKey:genericRowKey default:YES]) return;

	NSData *iconData = [HWGResolveIconNamed(imageName) TIFFRepresentation];
	NSString *description2 = description;
	NSData *iconData2 = iconData;
	__weak HWGrowlNetworkMonitor *blockSelf = self;
	void (^fireIPNote)(void) = ^{
		[blockSelf.delegate notifyWithName:@"IPAddressChange"
									  title:NSLocalizedString(@"IP Addresses Updated", @"")
								description:description2
									   icon:iconData2
						   identifierString:@"HWGrowlIPAddressChange"
							  contextString:nil
									 plugin:blockSelf];
	};
	if (!hasAddressesNow) {
		// BUG FIX (18-ago-2026, feedback del usuario) — when the address is being RELEASED
		// (as opposed to newly assigned), this races against the WiFi radio-off/AirPort
		// Disconnected sequence above: SCDynamicStore detects the address is gone almost
		// immediately once the link drops, while the CoreWLAN-driven pair now has its own
		// 0.4s delay (see -handleWiFiStateChangeForInterface: doc comment) — meaning "IP
		// Addresses Updated" could win the race and land BEFORE "AirPort Disconnected", which
		// reads backwards (you lose the network, THEN lose the address on it, not the other
		// way around). Delaying only the release case (a fresh address assignment has no such
		// ordering expectation to protect) keeps it reliably last in the sequence: radio →
		// network → address.
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), fireIPNote);
	} else {
		fireIPNote();
	}
}

- (void) interateInterfaces
{
    // Wired/Ethernet link priming at launch is handled by primeWiredLinkState (called from
    // startObserving before this runs). Here we just fire the current IP state (gated by
    // onLaunchEnabled via fireOnLaunchNotes).
    [self updateIP];
}

static void scCallback(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info) {
	@autoreleasepool {
        HWGrowlNetworkMonitor *observer = (__bridge HWGrowlNetworkMonitor *)info;
        // Global IPv4/IPv6 keys (exact) + every interface's own ".../Link" key (pattern).
        [(__bridge NSArray*)changedKeys enumerateObjectsUsingBlock:^(NSString *key, NSUInteger idx, BOOL *stop) {
            if([key hasPrefix:@"State:/Network/Global"])
                [observer updateIP];
            else if ([key hasSuffix:@"/Link"])
                [observer handleLinkKeyChanged:key];
            else if ([key hasSuffix:@"/DHCP"])
                [observer handleDHCPKeyChanged:key];
            else if ([key isEqualToString:@"Setup:/System"])
                [observer checkComputerNameChanged];
            else if ([key isEqualToString:@"Setup:"])
                [observer checkLocationChanged];
        }];
    }
}

#pragma mark HWGrowlPluginProtocol

// delegate accessors are auto-synthesized from the @property (weak).
-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Network Monitor", @"");
}
-(NSImage*)preferenceIcon {
	// Resolved fresh every call (not cached) since this is user-customizable via the Icons
	// tab's "Module Icon (Sidebar)" row — see the same note on AudioMonitor's -preferenceIcon.
	return HWGResolveIconNamed(@"HWGPrefsNetwork-Module");
}
-(IBAction)signalIntervalChanged:(NSSlider*)sender {
	NSInteger secs = lround([sender doubleValue]);
	[[NSUserDefaults standardUserDefaults] setInteger:secs forKey:HWG_WIFI_POLL_KEY];
	self.intervalValueLabel.stringValue = [NSString stringWithFormat:@"%ld s", (long)secs];
	[self restartSignalPollTimer];   // apply the new interval immediately
}

-(IBAction)signalCooldownChanged:(NSSlider*)sender {
	NSInteger secs = lround([sender doubleValue]);
	[[NSUserDefaults standardUserDefaults] setInteger:secs forKey:HWG_WIFI_COOLDOWN_KEY];
	self.cooldownValueLabel.stringValue = (secs == 0)
		? NSLocalizedString(@"off", @"cooldown disabled")
		: [NSString stringWithFormat:@"%ld s", (long)secs];
}

// F33: single generic handler for every per-field visibility checkbox. Each checkbox's
// `identifier` carries the NSUserDefaults key it controls (set when the checkbox is built).
-(IBAction)fieldToggleChanged:(NSButton*)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
}

-(NSButton *)checkboxWithKey:(NSString *)key title:(NSString *)title defaultOn:(BOOL)defaultOn {
	NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(fieldToggleChanged:)];
	box.identifier = key;
	box.state = [self boolForKey:key default:defaultOn] ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	return box;
}

// Wraps a fixed-height content view in a scroll view sized to fill whatever the tab
// control actually gives it — the container forces the top-level preferencePane to a
// fixed size that's shorter than 3 sections' worth of checkboxes, so content that doesn't
// fit scrolls instead of overflowing the tab's visible box.
-(NSScrollView *)scrollWrapping:(NSView *)content height:(CGFloat)height {
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:content.frame];
	scroll.hasVerticalScroller = YES;
	scroll.autohidesScrollers = YES;
	scroll.drawsBackground = NO;
	scroll.documentView = content;
	content.translatesAutoresizingMaskIntoConstraints = NO;
	[NSLayoutConstraint activateConstraints:@[
		[content.topAnchor      constraintEqualToAnchor:scroll.contentView.topAnchor],
		[content.leadingAnchor  constraintEqualToAnchor:scroll.contentView.leadingAnchor],
		[content.widthAnchor    constraintEqualToAnchor:scroll.contentView.widthAnchor],
		[content.heightAnchor   constraintEqualToConstant:height],
	]];
	return scroll;
}

-(NSTextField *)sectionHeaderWithTitle:(NSString *)title {
	NSTextField *h = [NSTextField labelWithString:title];
	h.font = [NSFont boldSystemFontOfSize:12];
	h.textColor = [NSColor secondaryLabelColor];
	h.translatesAutoresizingMaskIntoConstraints = NO;
	return h;
}

// Lays out a vertical stack of checkboxes (optionally preceded by other rows already
// pinned by the caller) inside `tab`, top-anchored to `topView`/`topAnchor`.
-(void)layoutRows:(NSArray<NSView*> *)rows inView:(NSView *)tab belowView:(NSView *)topView gap:(CGFloat)firstGap {
	NSView *previous = topView;
	CGFloat gap = firstGap;
	for (NSView *row in rows) {
		[tab addSubview:row];
		[NSLayoutConstraint activateConstraints:@[
			[row.topAnchor     constraintEqualToAnchor:previous == tab ? tab.topAnchor : previous.bottomAnchor constant:gap],
			[row.leadingAnchor  constraintEqualToAnchor:tab.leadingAnchor constant:16],
			[row.heightAnchor   constraintEqualToConstant:24],
		]];
		previous = row;
		gap = 8;
	}
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 560, 260)];
	// AppDelegate sizes this view once via -setFrameSize: to match the prefs window's
	// container, then never again — without an autoresizing mask this view (and its
	// visible tab box) stays whatever size it was created at even if the user later
	// resizes the Preferences window. Track the container's size going forward.
	tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	// --- Tab: Wi-Fi (also hosts the pre-existing signal-poll-interval slider) ---
	// BUG FIX (17-ago-2026): was 420 — fixed at the old row count (5 fields). Adding 3 more
	// checkboxes (Link rate/Channel/Noise+SNR) below without growing this pushed them past the
	// document view's own bounds — confirmed live: rows near/past the cutoff render but don't
	// respond to clicks (NSClipView only hit-tests within the document's own frame height,
	// regardless of what Auto Layout draws beyond it). Bumped to fit all 8 rows + the existing
	// slider/cooldown controls above them, with margin.
	NSView *wifiTab = [[HWGFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, tabs.bounds.size.width, 560)];
	NSTimeInterval cur = [self signalPollInterval];

	NSTextField *title = [NSTextField labelWithString:NSLocalizedString(@"Wi-Fi signal check interval", @"")];
	title.font = [NSFont boldSystemFontOfSize:12];
	title.translatesAutoresizingMaskIntoConstraints = NO;

	NSSlider *slider = [NSSlider sliderWithValue:cur minValue:HWG_WIFI_POLL_MIN maxValue:HWG_WIFI_POLL_MAX
										  target:self action:@selector(signalIntervalChanged:)];
	slider.translatesAutoresizingMaskIntoConstraints = NO;

	NSTextField *value = [NSTextField labelWithString:[NSString stringWithFormat:@"%.0f s", cur]];
	self.intervalValueLabel = value;
	value.translatesAutoresizingMaskIntoConstraints = NO;

	NSTextField *caption = [NSTextField labelWithString:
		NSLocalizedString(@"How often the Wi-Fi signal strength is checked (5–60 s).", @"")];
	caption.textColor = [NSColor secondaryLabelColor];
	caption.font = [NSFont systemFontOfSize:11];
	caption.translatesAutoresizingMaskIntoConstraints = NO;

	// F20: rate-limit between two signal-change notifications, so a value hovering at a bar
	// threshold doesn't spam. Configurable — a 20s cooldown fixed regardless of poll interval
	// otherwise blocks a legitimate second signal change that follows shortly after the first.
	NSTimeInterval curCooldown = [self signalCooldownInterval];
	NSTextField *cooldownTitle = [NSTextField labelWithString:NSLocalizedString(@"Minimum time between signal-change notices", @"")];
	cooldownTitle.font = [NSFont boldSystemFontOfSize:12];
	cooldownTitle.translatesAutoresizingMaskIntoConstraints = NO;

	NSSlider *cooldownSlider = [NSSlider sliderWithValue:curCooldown minValue:HWG_WIFI_COOLDOWN_MIN maxValue:HWG_WIFI_COOLDOWN_MAX
												   target:self action:@selector(signalCooldownChanged:)];
	cooldownSlider.translatesAutoresizingMaskIntoConstraints = NO;

	NSTextField *cooldownValue = [NSTextField labelWithString:(curCooldown < 0.5)
		? NSLocalizedString(@"off", @"cooldown disabled")
		: [NSString stringWithFormat:@"%.0f s", curCooldown]];
	self.cooldownValueLabel = cooldownValue;
	cooldownValue.translatesAutoresizingMaskIntoConstraints = NO;

	NSTextField *cooldownCaption = [NSTextField labelWithString:
		NSLocalizedString(@"Prevents repeat notices if the signal hovers at a threshold (0–60 s, 0 = off).", @"")];
	cooldownCaption.textColor = [NSColor secondaryLabelColor];
	cooldownCaption.font = [NSFont systemFontOfSize:11];
	cooldownCaption.translatesAutoresizingMaskIntoConstraints = NO;

	NSTextField *wifiFieldsHeader = [self sectionHeaderWithTitle:NSLocalizedString(@"Notification fields", @"")];

	[wifiTab addSubview:title]; [wifiTab addSubview:slider]; [wifiTab addSubview:value]; [wifiTab addSubview:caption];
	[wifiTab addSubview:cooldownTitle]; [wifiTab addSubview:cooldownSlider]; [wifiTab addSubview:cooldownValue]; [wifiTab addSubview:cooldownCaption];
	[NSLayoutConstraint activateConstraints:@[
		[title.topAnchor      constraintEqualToAnchor:wifiTab.topAnchor constant:16],
		[title.leadingAnchor  constraintEqualToAnchor:wifiTab.leadingAnchor constant:16],
		[slider.topAnchor     constraintEqualToAnchor:title.bottomAnchor constant:12],
		[slider.leadingAnchor constraintEqualToAnchor:wifiTab.leadingAnchor constant:16],
		[slider.widthAnchor   constraintEqualToConstant:220],
		[value.centerYAnchor  constraintEqualToAnchor:slider.centerYAnchor],
		[value.leadingAnchor  constraintEqualToAnchor:slider.trailingAnchor constant:10],
		[caption.topAnchor     constraintEqualToAnchor:slider.bottomAnchor constant:6],
		[caption.leadingAnchor constraintEqualToAnchor:wifiTab.leadingAnchor constant:16],

		[cooldownTitle.topAnchor      constraintEqualToAnchor:caption.bottomAnchor constant:18],
		[cooldownTitle.leadingAnchor  constraintEqualToAnchor:wifiTab.leadingAnchor constant:16],
		[cooldownSlider.topAnchor     constraintEqualToAnchor:cooldownTitle.bottomAnchor constant:12],
		[cooldownSlider.leadingAnchor constraintEqualToAnchor:wifiTab.leadingAnchor constant:16],
		[cooldownSlider.widthAnchor   constraintEqualToConstant:220],
		[cooldownValue.centerYAnchor  constraintEqualToAnchor:cooldownSlider.centerYAnchor],
		[cooldownValue.leadingAnchor  constraintEqualToAnchor:cooldownSlider.trailingAnchor constant:10],
		[cooldownCaption.topAnchor     constraintEqualToAnchor:cooldownSlider.bottomAnchor constant:6],
		[cooldownCaption.leadingAnchor constraintEqualToAnchor:wifiTab.leadingAnchor constant:16],
	]];
	[wifiTab addSubview:wifiFieldsHeader];
	[NSLayoutConstraint activateConstraints:@[
		[wifiFieldsHeader.topAnchor     constraintEqualToAnchor:cooldownCaption.bottomAnchor constant:18],
		[wifiFieldsHeader.leadingAnchor  constraintEqualToAnchor:wifiTab.leadingAnchor constant:16],
	]];
	[self layoutRows:@[
		[self checkboxWithKey:HWG_WIFI_SHOW_SSID_KEY        title:NSLocalizedString(@"SSID (network name)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_WIFI_SHOW_BSSID_KEY       title:NSLocalizedString(@"BSSID (access point address)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_WIFI_SHOW_BAND_KEY        title:NSLocalizedString(@"Band (2.4/5/6 GHz)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_WIFI_SHOW_GENERATION_KEY  title:NSLocalizedString(@"Generation (Wi-Fi 4–7)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_WIFI_SHOW_SECURITY_KEY    title:NSLocalizedString(@"Security type", @"") defaultOn:YES],
		// Added 17-ago-2026 — OFF by default (unlike the 5 fields above, on since v1.0): keeps
		// the default notification text as compact as it's always been, opt-in for users who
		// want the extra radio-link detail.
		[self checkboxWithKey:HWG_WIFI_SHOW_RATE_KEY        title:NSLocalizedString(@"Link rate (Mbps)", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_WIFI_SHOW_CHANNEL_KEY     title:NSLocalizedString(@"Channel number + width", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_WIFI_SHOW_SNR_KEY         title:NSLocalizedString(@"Noise floor + SNR", @"") defaultOn:NO],
		// Final API audit (18-ago-2026), batch 2 — OFF by default, same tier as Rate/Channel/SNR.
		[self checkboxWithKey:HWG_WIFI_SHOW_COUNTRY_KEY     title:NSLocalizedString(@"Regulatory country/region code", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_WIFI_SHOW_TXPOWER_KEY     title:NSLocalizedString(@"Transmit power", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_WIFI_SHOW_HWADDR_KEY      title:NSLocalizedString(@"Wi-Fi hardware (MAC) address", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_WIFI_SHOW_MODE_KEY        title:NSLocalizedString(@"Interface mode (Station/IBSS/Host AP)", @"") defaultOn:NO],
		// Moved here from the Ethernet tab (13-ago-2026, feedback del usuario) — this controls
		// whether Wi-Fi's OWN link/AWDL/AirDrop events get reported, so it belongs with the
		// rest of the Wi-Fi settings, not Ethernet's (Ethernet's own real-interface filter at
		// -isRealEthernetInterface: just READS this same key, unaffected by which tab shows it).
		[self checkboxWithKey:HWG_ETH_SHOW_ALL_KEY          title:NSLocalizedString(@"Also report Wi-Fi's own link and AWDL/AirDrop events", @"") defaultOn:NO],
	] inView:wifiTab belowView:wifiFieldsHeader gap:10];

	NSTabViewItem *wifiItem = [[NSTabViewItem alloc] initWithIdentifier:@"wifi"];
	wifiItem.label = NSLocalizedString(@"Wi-Fi", @"");
	wifiItem.view = [self scrollWrapping:wifiTab height:560];
	[tabs addTabViewItem:wifiItem];

	// --- Tab: Ethernet ---
	NSView *ethTab = [[HWGFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, tabs.bounds.size.width, 200)];
	NSTextField *ethHeader = [self sectionHeaderWithTitle:NSLocalizedString(@"Notification fields", @"")];
	[ethTab addSubview:ethHeader];
	[NSLayoutConstraint activateConstraints:@[
		[ethHeader.topAnchor     constraintEqualToAnchor:ethTab.topAnchor constant:16],
		[ethHeader.leadingAnchor  constraintEqualToAnchor:ethTab.leadingAnchor constant:16],
	]];
	[self layoutRows:@[
		[self checkboxWithKey:HWG_ETH_SHOW_INTERFACE_KEY title:NSLocalizedString(@"Interface name (en0, en5…)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_ETH_SHOW_SPEED_KEY     title:NSLocalizedString(@"Speed", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_ETH_SHOW_MODE_KEY      title:NSLocalizedString(@"Mode / duplex", @"") defaultOn:YES],
	] inView:ethTab belowView:ethHeader gap:10];

	NSTabViewItem *ethItem = [[NSTabViewItem alloc] initWithIdentifier:@"ethernet"];
	ethItem.label = NSLocalizedString(@"Ethernet", @"");
	ethItem.view = [self scrollWrapping:ethTab height:200];
	[tabs addTabViewItem:ethItem];

	// --- Tab: IP ---
	NSView *ipTab = [[HWGFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, tabs.bounds.size.width, 230)];
	NSTextField *ipHeader = [self sectionHeaderWithTitle:NSLocalizedString(@"Notification fields", @"")];
	[ipTab addSubview:ipHeader];
	[NSLayoutConstraint activateConstraints:@[
		[ipHeader.topAnchor     constraintEqualToAnchor:ipTab.topAnchor constant:16],
		[ipHeader.leadingAnchor  constraintEqualToAnchor:ipTab.leadingAnchor constant:16],
	]];
	[self layoutRows:@[
		[self checkboxWithKey:HWG_IP_SHOW_IPV4_KEY        title:NSLocalizedString(@"IPv4 address", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_IP_SHOW_IPV6_KEY        title:NSLocalizedString(@"IPv6 address", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_IP_SHOW_GATEWAY_KEY     title:NSLocalizedString(@"Gateway (per interface)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_IP_SHOW_NONROUTABLE_KEY title:NSLocalizedString(@"\"(non-routable)\" tag on self-assigned addresses", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_IP_USE_FRIENDLY_KEY     title:NSLocalizedString(@"Use friendly interface names (vs. en0/en5…)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_IP_SHOW_OLDNEW_KEY      title:NSLocalizedString(@"Show old → new address when it changes", @"") defaultOn:YES],
	] inView:ipTab belowView:ipHeader gap:10];

	NSTabViewItem *ipItem = [[NSTabViewItem alloc] initWithIdentifier:@"ip"];
	ipItem.label = NSLocalizedString(@"IP", @"");
	ipItem.view = [self scrollWrapping:ipTab height:230];
	[tabs addTabViewItem:ipItem];

	// --- Tab: VPN (F34 #4 — split out of "Other" 22-jul-2026, own dedicated tab) ---
	NSView *vpnTab = [[HWGFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, tabs.bounds.size.width, 120)];
	NSTextField *vpnHeader = [self sectionHeaderWithTitle:NSLocalizedString(@"VPN detection (F34)", @"")];
	[vpnTab addSubview:vpnHeader];
	[NSLayoutConstraint activateConstraints:@[
		[vpnHeader.topAnchor     constraintEqualToAnchor:vpnTab.topAnchor constant:16],
		[vpnHeader.leadingAnchor  constraintEqualToAnchor:vpnTab.leadingAnchor constant:16],
	]];
	// F34 #4: OFF by default — new notification, and detection is a heuristic (utun/ppp/ipsec
	// interface name prefix), not a guaranteed "this is definitely a VPN" signal.
	NSButton *vpnRow = [self checkboxWithKey:HWG_VPN_NOTIFY_KEY title:NSLocalizedString(@"Notify when a VPN connects/disconnects", @"") defaultOn:NO];
	[self layoutRows:@[vpnRow] inView:vpnTab belowView:vpnHeader gap:10];

	NSTextField *vpnCaption = [NSTextField wrappingLabelWithString:
		NSLocalizedString(@"Detected via utun/ppp/ipsec virtual interfaces (used by most VPN clients, incl. macOS's built-in VPN and third-party apps). This is a heuristic — some non-VPN system features can also use a utun interface. See README for details.", @"")];
	vpnCaption.textColor = [NSColor secondaryLabelColor];
	vpnCaption.font = [NSFont systemFontOfSize:11];
	vpnCaption.translatesAutoresizingMaskIntoConstraints = NO;
	vpnCaption.preferredMaxLayoutWidth = 360;
	[vpnTab addSubview:vpnCaption];
	[NSLayoutConstraint activateConstraints:@[
		[vpnCaption.topAnchor     constraintEqualToAnchor:vpnRow.bottomAnchor constant:6],
		[vpnCaption.leadingAnchor  constraintEqualToAnchor:vpnTab.leadingAnchor constant:16],
		[vpnCaption.trailingAnchor constraintLessThanOrEqualToAnchor:vpnTab.trailingAnchor constant:-16],
	]];

	NSTabViewItem *vpnItem = [[NSTabViewItem alloc] initWithIdentifier:@"vpn"];
	vpnItem.label = NSLocalizedString(@"VPN", @"");
	vpnItem.view = [self scrollWrapping:vpnTab height:120];
	[tabs addTabViewItem:vpnItem];

	// --- Tab: Other (catch-all reserved for FUTURE fields that don't fit Wi-Fi/Ethernet/IP/VPN) ---
	NSView *otherTab = [[HWGFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, tabs.bounds.size.width, 120)];
	NSTextField *otherPlaceholder = [NSTextField labelWithString:
		NSLocalizedString(@"No additional fields yet.", @"")];
	otherPlaceholder.textColor = [NSColor secondaryLabelColor];
	otherPlaceholder.font = [NSFont systemFontOfSize:12];
	otherPlaceholder.translatesAutoresizingMaskIntoConstraints = NO;
	[otherTab addSubview:otherPlaceholder];
	[NSLayoutConstraint activateConstraints:@[
		[otherPlaceholder.topAnchor     constraintEqualToAnchor:otherTab.topAnchor constant:16],
		[otherPlaceholder.leadingAnchor  constraintEqualToAnchor:otherTab.leadingAnchor constant:16],
	]];

	NSTabViewItem *otherItem = [[NSTabViewItem alloc] initWithIdentifier:@"other"];
	otherItem.label = NSLocalizedString(@"Other", @"");
	otherItem.view = [self scrollWrapping:otherTab height:120];
	[tabs addTabViewItem:otherItem];

	// --- Tab: Icons (per-event icon overrides) ---
	// NOTE: deliberately NOT using -scrollWrapping:height: here (unlike the other tabs
	// above) — that helper forces the CONTENT view's height to a fixed guessed constant,
	// which is exactly the bug that broke this tab's layout (10 icon rows crammed into a
	// fixed 260pt container). Instead the content view is sized to the icon picker's real
	// -fittingSize, and only the outer NSScrollView's frame uses a fixed "viewport" height
	// (260, matching the tab's prior visual size) — content taller than that scrolls.
	CGFloat iconsPad = 16;
	CGFloat iconsGap = 12;
	CGFloat iconsWidth = tabs.bounds.size.width - 2 * iconsPad;

	NSTextField *iconsHeader = [self sectionHeaderWithTitle:NSLocalizedString(@"Notification icons", @"")];
	iconsHeader.translatesAutoresizingMaskIntoConstraints = YES;
	CGFloat iconsHeaderH = iconsHeader.fittingSize.height;

	HWGIconPickerView *iconPicker = [[HWGIconPickerView alloc] initWithIconSpecs:@[
		@[@"Module Icon (Sidebar)", @"HWGPrefsNetwork-Module"],
		@[@"Wi-Fi — No Signal", @"Network-Wifi-0", [HWG_NET_NOTIFY_WIFI_BAR_PREFIX stringByAppendingString:@"0"]],
		@[@"Wi-Fi — Weak", @"Network-Wifi-1", [HWG_NET_NOTIFY_WIFI_BAR_PREFIX stringByAppendingString:@"1"]],
		@[@"Wi-Fi — Fair", @"Network-Wifi-2", [HWG_NET_NOTIFY_WIFI_BAR_PREFIX stringByAppendingString:@"2"]],
		@[@"Wi-Fi — Good", @"Network-Wifi-3", [HWG_NET_NOTIFY_WIFI_BAR_PREFIX stringByAppendingString:@"3"]],
		@[@"Wi-Fi — Excellent", @"Network-Wifi-4", [HWG_NET_NOTIFY_WIFI_BAR_PREFIX stringByAppendingString:@"4"]],
		@[@"Wi-Fi Off", @"Network-Wifi-Off", HWG_NET_NOTIFY_WIFI_OFF_KEY],
		// Added 18-ago-2026 — the RADIO's own power state (macOS Wi-Fi toggle), distinct from
		// "Wi-Fi Off" above (that fires when disconnected FROM A NETWORK, radio can stay on).
		// Own dedicated icons (Network-Wifi-Radio-On/-Off) — NOT "Network-Wifi-Off" above, which
		// is a different asset for a different event; no name collision, but split into two
		// rows/keys anyway to match the Connected/Disconnected precedent (independent toggles).
		@[@"Wi-Fi Radio On", @"Network-Wifi-Radio-On", HWG_NET_NOTIFY_WIFI_RADIO_ON_KEY, @NO],
		@[@"Wi-Fi Radio Off", @"Network-Wifi-Radio-Off", HWG_NET_NOTIFY_WIFI_RADIO_OFF_KEY, @NO],
		@[@"Ethernet Connected", @"Network-Ethernet-On", HWG_NET_NOTIFY_ETH_ON_KEY],
		@[@"Ethernet Disconnected", @"Network-Ethernet-Off", HWG_NET_NOTIFY_ETH_OFF_KEY],
		@[@"Ethernet Speed Changed", @"Network-Ethernet-Speed", HWG_NET_NOTIFY_ETH_SPEED_KEY, @NO],
		@[@"Other Interface Connected", @"Network-Interface-On", HWG_NET_NOTIFY_OTHER_ON_KEY],
		@[@"Other Interface Disconnected", @"Network-Interface-Off", HWG_NET_NOTIFY_OTHER_OFF_KEY],
		@[@"Generic Connected", @"Network-Generic-On", HWG_NET_NOTIFY_GENERIC_ON_KEY],
		@[@"Generic Disconnected", @"Network-Generic-Off", HWG_NET_NOTIFY_GENERIC_OFF_KEY],
		@[@"VPN Connected", @"Network-VPN-On", HWG_VPN_NOTIFY_KEY],
		@[@"VPN Disconnected", @"Network-VPN-Off", HWG_VPN_NOTIFY_KEY],
		@[@"DNS Servers Changed", @"Network-DNS-On", HWG_NET_NOTIFY_DNS_KEY, @NO],
		@[@"Primary Interface Changed", @"Network-PrimaryInterface-On", HWG_NET_NOTIFY_PRIMARY_IF_KEY, @NO],
		@[@"Proxy Configuration Changed", @"Network-Proxy-On", HWG_NET_NOTIFY_PROXY_KEY, @NO],
		// Final API audit (18-ago-2026), batch 1 — no dedicated icon assets yet, reusing the
		// module icon (same "reuse rather than collide" approach as Gamepad Monitor's
		// Keyboard/Mouse/Racing Wheel rows this same audit pass — each still gets its own key).
		@[@"Internet Reachability Changed", @"HWGPrefsNetwork-Module", HWG_NET_NOTIFY_REACHABILITY_KEY, @NO],
		@[@"DHCP Lease Renewed", @"HWGPrefsNetwork-Module", HWG_NET_NOTIFY_DHCP_RENEWED_KEY, @NO],
		@[@"Computer Name Changed", @"HWGPrefsNetwork-Module", HWG_NET_NOTIFY_HOSTNAME_KEY, @NO],
		@[@"Network Location Changed", @"HWGPrefsNetwork-Module", HWG_NET_NOTIFY_LOCATION_KEY, @NO],
		@[@"Wi-Fi Host AP / Ad-hoc Mode Changed", @"HWGPrefsNetwork-Module", HWG_NET_NOTIFY_WIFI_HOSTAP_KEY, @NO],
	]];
	iconPicker.translatesAutoresizingMaskIntoConstraints = YES;
	iconPicker.frame = NSMakeRect(0, 0, iconsWidth, 0);
	CGFloat iconPickerH = iconPicker.fittingSize.height;

	CGFloat iconsContentH = iconsHeaderH + iconsGap + iconPickerH + 2 * iconsPad;
	NSView *iconsTab = [[HWGFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, tabs.bounds.size.width, iconsContentH)];
	iconsHeader.frame = NSMakeRect(iconsPad, iconsPad, iconsWidth, iconsHeaderH);
	[iconsTab addSubview:iconsHeader];
	iconPicker.frame = NSMakeRect(iconsPad, iconsPad + iconsHeaderH + iconsGap, iconsWidth, iconPickerH);
	[iconsTab addSubview:iconPicker];

	NSScrollView *iconsScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, tabs.bounds.size.width, 260)];
	iconsScroll.hasVerticalScroller = YES;
	iconsScroll.autohidesScrollers = YES;
	iconsScroll.drawsBackground = NO;
	iconsScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	iconsScroll.documentView = iconsTab;

	NSTabViewItem *iconsItem = [[NSTabViewItem alloc] initWithIdentifier:@"icons"];
	iconsItem.label = NSLocalizedString(@"Icons", @"");
	iconsItem.view = iconsScroll;
	[tabs addTabViewItem:iconsItem];

	prefsView = tabs;
	return prefsView;
}

#pragma mark HWGrowlPluginNotifierProtocol

-(NSArray*)noteNames {
	return [NSArray arrayWithObjects:@"IPAddressChange", @"NetworkLinkUp", @"NetworkLinkDown", @"NetworkLinkSpeedChanged", @"AirportConnected", @"AirportDisconnected", @"AirportSignalChange", @"VPNConnected", @"VPNDisconnected", @"DNSServersChanged", @"PrimaryInterfaceChanged", @"ProxyConfigChanged", @"WifiRadioOn", @"WifiRadioOff", @"NetworkReachabilityChanged", @"NetworkDHCPLeaseRenewed", @"NetworkHostnameChanged", @"NetworkLocationChanged", @"WifiHostAPModeChanged", nil];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"IP Address Changed", @""), @"IPAddressChange",
			  NSLocalizedString(@"Network Link Up", @""), @"NetworkLinkUp",
			  NSLocalizedString(@"Network Link Down", @""), @"NetworkLinkDown",
			  NSLocalizedString(@"Ethernet Speed Changed", @""), @"NetworkLinkSpeedChanged",
			  NSLocalizedString(@"AirPort Connected", @""), @"AirportConnected",
			  NSLocalizedString(@"AirPort Disconnected", @""), @"AirportDisconnected",
			  NSLocalizedString(@"Wi-Fi Signal Changed", @""), @"AirportSignalChange",
			  NSLocalizedString(@"VPN Connected", @""), @"VPNConnected",
			  NSLocalizedString(@"VPN Disconnected", @""), @"VPNDisconnected",
			  NSLocalizedString(@"DNS Servers Changed", @""), @"DNSServersChanged",
			  NSLocalizedString(@"Primary Interface Changed", @""), @"PrimaryInterfaceChanged",
			  NSLocalizedString(@"Proxy Configuration Changed", @""), @"ProxyConfigChanged",
			  NSLocalizedString(@"Wi-Fi Radio On", @""), @"WifiRadioOn",
			  NSLocalizedString(@"Wi-Fi Radio Off", @""), @"WifiRadioOff",
			  NSLocalizedString(@"Internet Reachability Changed", @""), @"NetworkReachabilityChanged",
			  NSLocalizedString(@"DHCP Lease Renewed", @""), @"NetworkDHCPLeaseRenewed",
			  NSLocalizedString(@"Computer Name Changed", @""), @"NetworkHostnameChanged",
			  NSLocalizedString(@"Network Location Changed", @""), @"NetworkLocationChanged",
			  NSLocalizedString(@"Wi-Fi Host AP / Ad-hoc Mode Changed", @""), @"WifiHostAPModeChanged", nil];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Sent when the systems IP address changes", @""), @"IPAddressChange",
			  NSLocalizedString(@"Sent when an Ethernet link starts", @""), @"NetworkLinkUp",
			  NSLocalizedString(@"Sent when an Ethernet link goes down", @""), @"NetworkLinkDown",
			  NSLocalizedString(@"Sent when an already-up Ethernet link's negotiated speed changes (e.g. a degrading cable)", @""), @"NetworkLinkSpeedChanged",
			  NSLocalizedString(@"Sent when AirPort connects to a network", @""), @"AirportConnected",
			  NSLocalizedString(@"Sent when AirPort disconnects from a network", @""), @"AirportDisconnected",
			  NSLocalizedString(@"Sent when the Wi-Fi signal strength level changes", @""), @"AirportSignalChange",
			  NSLocalizedString(@"Sent when a VPN tunnel interface connects (F34, heuristic detection)", @""), @"VPNConnected",
			  NSLocalizedString(@"Sent when a VPN tunnel interface disconnects (F34, heuristic detection)", @""), @"VPNDisconnected",
			  NSLocalizedString(@"Sent when the system's DNS server list changes", @""), @"DNSServersChanged",
			  NSLocalizedString(@"Sent when the primary network interface changes (e.g. Wi-Fi ↔ Ethernet)", @""), @"PrimaryInterfaceChanged",
			  NSLocalizedString(@"Sent when HTTP/HTTPS/SOCKS/PAC proxy settings change", @""), @"ProxyConfigChanged",
			  NSLocalizedString(@"Sent when the Wi-Fi radio itself is turned on (regardless of whether it then connects to a network)", @""), @"WifiRadioOn",
			  NSLocalizedString(@"Sent when the Wi-Fi radio itself is turned off", @""), @"WifiRadioOff",
			  NSLocalizedString(@"Sent when general Internet reachability (not tied to Wi-Fi/Ethernet specifically) is lost or restored — off by default", @""), @"NetworkReachabilityChanged",
			  NSLocalizedString(@"Sent when an interface's DHCP lease is renewed/rebound while it stays connected — off by default", @""), @"NetworkDHCPLeaseRenewed",
			  NSLocalizedString(@"Sent when the computer's name (Sharing preferences) changes — off by default", @""), @"NetworkHostnameChanged",
			  NSLocalizedString(@"Sent when the active Network Location changes (e.g. Home/Work/Automatic) — off by default", @""), @"NetworkLocationChanged",
			  NSLocalizedString(@"Sent when the Wi-Fi interface enters/leaves Host AP (Internet Sharing) or ad-hoc (IBSS) mode — off by default", @""), @"WifiHostAPModeChanged", nil];
}
-(NSArray*)defaultNotifications {
	return [NSArray arrayWithObjects:@"IPAddressChange", @"NetworkLinkUp", @"NetworkLinkDown", @"AirportConnected", @"AirportDisconnected", @"AirportSignalChange", nil];
}

@end
