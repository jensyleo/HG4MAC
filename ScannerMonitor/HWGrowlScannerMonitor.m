//
//  HWGrowlScannerMonitor.m
//  HardwareGrowler
//
//  Detects NETWORK scanners (not USB — USB scanner detection already exists in USBMonitor) via
//  Bonjour/mDNS service discovery for `_scanner._tcp` (generic network scanner / WSD) and
//  `_uscan._tcp` (eSCL/AirScan). Uses NSNetServiceBrowser rather than any lower-level DNS-SD API
//  since it's already available via Foundation with no new framework/link dependency.
//
//  This is the FIRST feature in this app to request macOS's Local Network permission (via
//  NSBonjourServices + NSLocalNetworkUsageDescription in the main app's Info.plist) — a prompt
//  the app has never triggered before. To keep that blast radius as small as possible: OFF by
//  default (browsing never starts until the user opts in from Preferences), and starting/
//  stopping the two NSNetServiceBrowsers is the ONLY thing the enable checkbox controls.

// compile with ARC: -fobjc-arc
#import "HWGrowlScannerMonitor.h"
#import "HWGIconOverrideStore.h"
#import "HWGIconPickerView.h"

#define HWG_SCANNER_NOTIFY_KEY @"HWGScannerNotifyEnabled"
// Independent from HWG_SCANNER_NOTIFY_KEY above (which also controls whether browsing runs at
// all) — these only silence the notification itself while detection/state-tracking continues.
// Split into two separate keys (17-ago-2026, feedback del usuario) — each now has its own icon
// (green check for Found, red X for Lost), so a single shared toggle no longer made sense; this
// also matches Printer Monitor's Connected/Needs Attention precedent of one key per icon row.
#define HWG_SCANNER_NOTIFY_FOUND_KEY @"HWGScannerNotifyFound"
#define HWG_SCANNER_NOTIFY_LOST_KEY @"HWGScannerNotifyLost"

// #6 (05-ago-2026): scan job start/finish, via eSCL/AirScan's GET /eSCL/ScannerStatus — the
// same protocol _uscan._tcp already advertises (Mopria eSCL Technical Specification, publicly
// downloadable, free click-through license). Polls each resolved device's ScannerStatus
// endpoint for its <pwg:State> (Idle/Processing/Testing/Stopped) and diffs against the last
// known state to fire Started/Finished — same architecture as WiFi Monitor's signal poll.
// OFF by default: unlike Printer Job Status (CUPS, verified working end-to-end against a real
// test queue this session), this has NEVER been tested against a real network scanner —
// firmware compliance with ScannerStatus is known to vary significantly by vendor (per
// sane-airscan's own reason for existing), and some devices may only surface job completion
// via the per-job resource (GET /eSCL/ScanJobs/{id}) rather than the top-level status this
// polls. Ship it opt-in so it can be verified live once real hardware is available, same
// pattern as every other unverified-but-plausible feature in this app.
#define HWG_SCANNER_NOTIFY_SCANSTATUS_KEY @"HWGScannerNotifyScanStatus"
#define HWG_SCANNER_SCANSTATUS_POLL_KEY   @"HWGScannerScanStatusPollInterval"
#define HWG_SCANNER_SCANSTATUS_POLL_DEFAULT 10.0
#define HWG_SCANNER_SCANSTATUS_POLL_MIN     5.0
#define HWG_SCANNER_SCANSTATUS_POLL_MAX     60.0

// 13-ago-2026: automatic document feeder state (paper jam/empty/cover open), same ScannerStatus
// poll used above for scan job status. AdfState is OPTIONAL in the eSCL spec — not every
// scanner/MFP firmware exposes it — so this genuinely may never fire for a given device, which
// is expected behavior, not a bug. Pending validation against a real ADF-equipped device (see
// TODO.md); implemented now so it's ready once that hardware is available.
#define HWG_SCANNER_NOTIFY_ADFSTATE_KEY @"HWGScannerNotifyAdfState"
#define HWG_SCANNER_SHOW_JOB_REASONS_KEY @"HWGScannerShowJobStateReasons"

static BOOL HWGScannerBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

// Minimal eSCL ScannerStatus XML parser — pulls just the device-level <pwg:State> text
// (Idle/Processing/Testing/Stopped per the spec). Namespace processing deliberately left OFF
// (default), so elementName arrives as the raw qualified name ("pwg:State") — simpler than
// resolving the scan:/pwg: namespace URIs for a single field, and every real-world eSCL
// response uses these exact prefixes per the spec's own examples.
@interface HWGESCLStatusParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, copy) NSString *deviceState;
// ADF (automatic document feeder) state — e.g. ScannerAdfLoaded/ScannerAdfJam/ScannerAdfEmpty
// per the Mopria eSCL spec's <pwg:AdfState>. OPTIONAL in the spec: nil here just means this
// device's firmware doesn't report it, not a parse failure.
@property (nonatomic, copy) NSString *adfState;
// Added 17-ago-2026 (feedback del usuario) — <pwg:JobStateReason> entries under
// <pwg:Jobs>/<pwg:JobInfo>/<pwg:JobStateReasons>, same schema/endpoint already polled above.
// Optional per spec, like AdfState — an empty array here just means this firmware doesn't
// report per-job reasons, not a parse failure.
@property (nonatomic, strong) NSMutableArray<NSString *> *jobStateReasons;
@end
@implementation HWGESCLStatusParser {
	BOOL _inPwgState;
	BOOL _inAdfState;
	BOOL _inJobStateReason;
	NSMutableString *_buffer;
	NSMutableString *_adfBuffer;
	NSMutableString *_jobReasonBuffer;
}
- (instancetype)init {
	if ((self = [super init])) {
		_jobStateReasons = [NSMutableArray array];
	}
	return self;
}
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *,NSString *> *)attributeDict {
	if ([elementName isEqualToString:@"pwg:State"]) {
		_inPwgState = YES;
		_buffer = [NSMutableString string];
	} else if ([elementName isEqualToString:@"pwg:AdfState"]) {
		_inAdfState = YES;
		_adfBuffer = [NSMutableString string];
	} else if ([elementName isEqualToString:@"pwg:JobStateReason"]) {
		_inJobStateReason = YES;
		_jobReasonBuffer = [NSMutableString string];
	}
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
	if (_inPwgState) [_buffer appendString:string];
	if (_inAdfState) [_adfBuffer appendString:string];
	if (_inJobStateReason) [_jobReasonBuffer appendString:string];
}
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
	if ([elementName isEqualToString:@"pwg:State"] && _inPwgState) {
		self.deviceState = [_buffer stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		_inPwgState = NO;
	} else if ([elementName isEqualToString:@"pwg:AdfState"] && _inAdfState) {
		self.adfState = [_adfBuffer stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		_inAdfState = NO;
	} else if ([elementName isEqualToString:@"pwg:JobStateReason"] && _inJobStateReason) {
		NSString *reason = [_jobReasonBuffer stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if ([reason length]) [self.jobStateReasons addObject:reason];
		_inJobStateReason = NO;
	}
}
@end

@interface HWGrowlScannerMonitor () <NSNetServiceBrowserDelegate, NSNetServiceDelegate>

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, strong) NSView *prefsView;

// One browser per service type — `_scanner._tcp` (generic network scanner / WSD) and
// `_uscan._tcp` (eSCL/AirScan), both domain "local." per the task's Bonjour usage description.
@property (nonatomic, strong) NSNetServiceBrowser *scannerTCPBrowser;
@property (nonatomic, strong) NSNetServiceBrowser *uscanBrowser;

// Keeps a strong reference to every currently-known NSNetService so it isn't deallocated while
// still resolving/being tracked (NSNetServiceBrowser does not retain them for you), keyed by a
// browser-qualified name so `_scanner._tcp` and `_uscan._tcp` never collide if the same device
// advertises both.
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSNetService*> *knownServices;

// #6: scan job status. Resolved "host:port" per known service key (only devices that have
// actually resolved get polled — an unresolved service has nowhere to send a GET to).
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSString*> *resolvedHostPortByKey;
// Last device-level <pwg:State> actually seen per key, so a poll only fires a notification on
// a real Idle<->Processing transition, not every tick. No entry yet = not seen/baselined.
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSString*> *lastKnownScanStateByKey;
@property (nonatomic, strong) NSTimer *scanStatusPollTimer;
// Same baseline-then-diff pattern as lastKnownScanStateByKey above, for <pwg:AdfState>.
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSString*> *lastKnownAdfStateByKey;

@end

@implementation HWGrowlScannerMonitor

@synthesize delegate;
@synthesize prefsView;

-(id)init {
	if ((self = [super init])) {
		self.knownServices = [NSMutableDictionary dictionary];
		self.resolvedHostPortByKey = [NSMutableDictionary dictionary];
		self.lastKnownScanStateByKey = [NSMutableDictionary dictionary];
		self.lastKnownAdfStateByKey = [NSMutableDictionary dictionary];
		[self updateBrowsingState];
	}
	return self;
}

-(void)dealloc {
	[self stopBrowsing];
	[self stopScanStatusPolling];
}

-(void)updateBrowsingState {
	BOOL enabled = HWGScannerBoolForKey(HWG_SCANNER_NOTIFY_KEY, NO);
	if (enabled) {
		[self startBrowsing];
	} else {
		[self stopBrowsing];
	}
	[self updateScanStatusPollingState];
}

-(void)updateScanStatusPollingState {
	BOOL wantsPolling = HWGScannerBoolForKey(HWG_SCANNER_NOTIFY_KEY, NO) &&
	                    HWGScannerBoolForKey(HWG_SCANNER_NOTIFY_SCANSTATUS_KEY, NO);
	if (wantsPolling) {
		[self startScanStatusPolling];
	} else {
		[self stopScanStatusPolling];
	}
}

-(NSTimeInterval)scanStatusPollInterval {
	BOOL stored = [[NSUserDefaults standardUserDefaults] objectForKey:HWG_SCANNER_SCANSTATUS_POLL_KEY] != nil;
	NSTimeInterval v = stored ? [[NSUserDefaults standardUserDefaults] doubleForKey:HWG_SCANNER_SCANSTATUS_POLL_KEY] : HWG_SCANNER_SCANSTATUS_POLL_DEFAULT;
	if (v < HWG_SCANNER_SCANSTATUS_POLL_MIN) v = HWG_SCANNER_SCANSTATUS_POLL_MIN;
	if (v > HWG_SCANNER_SCANSTATUS_POLL_MAX) v = HWG_SCANNER_SCANSTATUS_POLL_MAX;
	return v;
}

-(void)startScanStatusPolling {
	if (self.scanStatusPollTimer) return;
	__weak typeof(self) weakSelf = self;
	self.scanStatusPollTimer = [NSTimer scheduledTimerWithTimeInterval:[self scanStatusPollInterval]
																repeats:YES
																  block:^(NSTimer * _Nonnull timer) {
		[weakSelf pollAllScanStatuses];
	}];
}

-(void)stopScanStatusPolling {
	[self.scanStatusPollTimer invalidate];
	self.scanStatusPollTimer = nil;
	[self.lastKnownScanStateByKey removeAllObjects];
}

-(void)pollAllScanStatuses {
	for (NSString *key in [self.resolvedHostPortByKey allKeys]) {
		NSString *hostPort = self.resolvedHostPortByKey[key];
		NSNetService *service = self.knownServices[key];
		if (!hostPort || !service) continue;
		[self pollScanStatusForKey:key hostPort:hostPort deviceName:service.name];
	}
}

-(void)pollScanStatusForKey:(NSString *)key hostPort:(NSString *)hostPort deviceName:(NSString *)deviceName {
	NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@/eSCL/ScannerStatus", hostPort]];
	if (!url) return;
	__weak typeof(self) weakSelf = self;
	NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		if (!data || error) return;   // device offline/unreachable this tick — silently skip, try again next poll
		HWGESCLStatusParser *parser = [HWGESCLStatusParser new];
		NSXMLParser *xmlParser = [[NSXMLParser alloc] initWithData:data];
		xmlParser.delegate = parser;
		if (![xmlParser parse] || ![parser.deviceState length]) return;   // unparseable/unexpected shape — skip rather than guess
		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf handleScanState:parser.deviceState forKey:key deviceName:deviceName jobStateReasons:parser.jobStateReasons];
			if ([parser.adfState length]) {
				[weakSelf handleAdfState:parser.adfState forKey:key deviceName:deviceName];
			}
		});
	}];
	[task resume];
}

// Diffs against the last known state and fires Started/Finished only on the real transition —
// same baseline-then-diff pattern every other monitor in this app uses. "Processing" is the
// only in-progress value the eSCL spec defines besides Idle/Testing/Stopped; treated as
// "scanning", everything else as "not scanning".
-(void)handleScanState:(NSString *)newState forKey:(NSString *)key deviceName:(NSString *)deviceName jobStateReasons:(NSArray<NSString *> *)jobStateReasons {
	NSString *previousState = self.lastKnownScanStateByKey[key];
	self.lastKnownScanStateByKey[key] = newState;
	if (!previousState) return;   // first sighting for this device — baseline only, no notification

	BOOL wasScanning = [previousState isEqualToString:@"Processing"];
	BOOL isScanning  = [newState isEqualToString:@"Processing"];
	if (wasScanning == isScanning) return;

	// Added 17-ago-2026 (feedback del usuario) — <pwg:JobStateReason> entries, same
	// ScannerStatus poll, extending the existing parser. OFF by default like every other
	// experimental Scanner Monitor field — optional in the spec, may never appear.
	NSString *description = deviceName;
	if ([jobStateReasons count] && HWGScannerBoolForKey(HWG_SCANNER_SHOW_JOB_REASONS_KEY, NO)) {
		description = [NSString stringWithFormat:@"%@\n%@", deviceName, [jobStateReasons componentsJoinedByString:@", "]];
	}

	NSData *iconData = [[HWGrowlScannerMonitor scannerScanStatusIcon] TIFFRepresentation];
	[delegate notifyWithName:@"ScannerScanStatus"
							 title:isScanning ? NSLocalizedString(@"Scan Started", @"") : NSLocalizedString(@"Scan Finished", @"")
					 description:description
							  icon:iconData
			  identifierString:[NSString stringWithFormat:@"HWGrowlScannerScanStatus-%@-%@", key, isScanning ? @"started" : @"finished"]
				  contextString:nil
							plugin:self];
}

// Same baseline-then-diff pattern as -handleScanState:forKey:deviceName: above. AdfState values
// per the Mopria eSCL spec are things like ScannerAdfProcessing/ScannerAdfEmpty/ScannerAdfJam/
// ScannerAdfCoverOpen — shown verbatim rather than mapped to a fixed table, since the exact set
// of values a given vendor's firmware sends hasn't been confirmed against real hardware yet.
-(void)handleAdfState:(NSString *)newState forKey:(NSString *)key deviceName:(NSString *)deviceName {
	if (!HWGScannerBoolForKey(HWG_SCANNER_NOTIFY_ADFSTATE_KEY, NO)) return;
	NSString *previousState = self.lastKnownAdfStateByKey[key];
	self.lastKnownAdfStateByKey[key] = newState;
	if (!previousState) return;   // first sighting for this device — baseline only, no notification
	if ([previousState isEqualToString:newState]) return;

	NSData *iconData = [[HWGrowlScannerMonitor scannerAdfStateIcon] TIFFRepresentation];
	[delegate notifyWithName:@"ScannerAdfStateChanged"
							 title:NSLocalizedString(@"Scanner Feeder State Changed", @"")
					 description:[NSString stringWithFormat:@"%@\n%@", deviceName, newState]
							  icon:iconData
			  identifierString:[NSString stringWithFormat:@"HWGrowlScannerAdfState-%@", key]
				  contextString:nil
							plugin:self];
}

-(void)startBrowsing {
	if (!_scannerTCPBrowser) {
		self.scannerTCPBrowser = [[NSNetServiceBrowser alloc] init];
		_scannerTCPBrowser.delegate = self;
		[_scannerTCPBrowser searchForServicesOfType:@"_scanner._tcp." inDomain:@"local."];
	}
	if (!_uscanBrowser) {
		self.uscanBrowser = [[NSNetServiceBrowser alloc] init];
		_uscanBrowser.delegate = self;
		[_uscanBrowser searchForServicesOfType:@"_uscan._tcp." inDomain:@"local."];
	}
}

-(void)stopBrowsing {
	[_scannerTCPBrowser stop];
	[_uscanBrowser stop];
	self.scannerTCPBrowser = nil;
	self.uscanBrowser = nil;
	[self.knownServices removeAllObjects];
}

// Distinguishes the same device name advertised over both service types.
-(NSString *)keyForService:(NSNetService*)service {
	return [NSString stringWithFormat:@"%@|%@", service.type, service.name];
}

#pragma mark NSNetServiceBrowserDelegate

-(void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing {
	NSString *key = [self keyForService:service];
	self.knownServices[key] = service;
	service.delegate = self;
	[service resolveWithTimeout:5.0];

	if (!HWGScannerBoolForKey(HWG_SCANNER_NOTIFY_FOUND_KEY, YES)) return;
	NSData *iconData = [[HWGrowlScannerMonitor scannerFoundIcon] TIFFRepresentation];
	[delegate notifyWithName:@"ScannerFound"
							 title:NSLocalizedString(@"Network Scanner Found", @"")
					 description:service.name
							  icon:iconData
			  identifierString:[NSString stringWithFormat:@"HWGrowlScanner-%@", key]
				  contextString:nil
							plugin:self];
}

-(void)netServiceBrowser:(NSNetServiceBrowser *)browser didRemoveService:(NSNetService *)service moreComing:(BOOL)moreComing {
	NSString *key = [self keyForService:service];
	[self.knownServices removeObjectForKey:key];
	[self.resolvedHostPortByKey removeObjectForKey:key];
	[self.lastKnownScanStateByKey removeObjectForKey:key];

	if (!HWGScannerBoolForKey(HWG_SCANNER_NOTIFY_LOST_KEY, YES)) return;
	NSData *iconData = [[HWGrowlScannerMonitor scannerLostIcon] TIFFRepresentation];
	[delegate notifyWithName:@"ScannerLost"
							 title:NSLocalizedString(@"Network Scanner Lost", @"")
					 description:service.name
							  icon:iconData
			  identifierString:[NSString stringWithFormat:@"HWGrowlScanner-%@", key]
				  contextString:nil
							plugin:self];
}

#pragma mark NSNetServiceDelegate

// #6: captures host:port once Bonjour resolves the service, so scan-status polling has
// somewhere to send its GET. hostName sometimes arrives with a trailing "." (DNS root label) —
// harmless for URLWithString: but stripped here for a cleaner host string regardless.
-(void)netServiceDidResolveAddress:(NSNetService *)sender {
	NSString *key = [self keyForService:sender];
	if (![self.knownServices objectForKey:key]) return;   // already removed before resolution finished
	NSString *host = sender.hostName;
	if ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
	if (![host length] || sender.port <= 0) return;
	self.resolvedHostPortByKey[key] = [NSString stringWithFormat:@"%@:%ld", host, (long)sender.port];
}

-(void)netService:(NSNetService *)sender didNotResolve:(NSDictionary<NSString *, NSNumber *> *)errorDict {
	// Leave it unresolved — this device just doesn't get polled for scan status until (if
	// ever) a future resolve attempt succeeds; ScannerFound/Lost detection is unaffected.
}

#pragma mark Icon

// Reuses the existing "USB-TypeScanner" asset (Assets.xcassets) rather than drawing new
// artwork — this monitor detects the same kind of device (a scanner), just discovered over
// the network instead of USB, so the same glyph reads correctly for both the notification icon
// and the module/sidebar icon. A dedicated network-specific icon can be a follow-up.
+(NSImage *)scannerIcon {
	NSImage *override = [[HWGIconOverrideStore sharedStore] overrideImageForDefaultName:@"USB-TypeScanner"];
	return override ?: [NSImage imageNamed:@"USB-TypeScanner"];
}

// Dedicated per-event icons (17-ago-2026, feedback del usuario) — the module icon above reused
// the same bare glyph for every event, which read as "all four rows are identical" in the Icons
// tab. Each of these follows the badge convention already established elsewhere in this app
// (green check/red X for Found/Lost, matching Printer Monitor's Connected/Disconnected; blue
// document+scan-beam for Scan Started/Finished; amber "!" for ADF State, since jam/empty/cover-
// open are attention-worthy but not necessarily critical).
+(NSImage *)scannerFoundIcon {
	NSImage *override = [[HWGIconOverrideStore sharedStore] overrideImageForDefaultName:@"ScannerMonitor-Icon-Found"];
	return override ?: [NSImage imageNamed:@"ScannerMonitor-Icon-Found"];
}
+(NSImage *)scannerLostIcon {
	NSImage *override = [[HWGIconOverrideStore sharedStore] overrideImageForDefaultName:@"ScannerMonitor-Icon-Lost"];
	return override ?: [NSImage imageNamed:@"ScannerMonitor-Icon-Lost"];
}
+(NSImage *)scannerScanStatusIcon {
	NSImage *override = [[HWGIconOverrideStore sharedStore] overrideImageForDefaultName:@"ScannerMonitor-Icon-ScanStatus"];
	return override ?: [NSImage imageNamed:@"ScannerMonitor-Icon-ScanStatus"];
}
+(NSImage *)scannerAdfStateIcon {
	NSImage *override = [[HWGIconOverrideStore sharedStore] overrideImageForDefaultName:@"ScannerMonitor-Icon-AdfState"];
	return override ?: [NSImage imageNamed:@"ScannerMonitor-Icon-AdfState"];
}

#pragma mark HWGrowlPluginProtocol

-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Scanner Monitor", @"");
}
-(NSImage*)preferenceIcon {
	NSImage *override = [[HWGIconOverrideStore sharedStore] overrideImageForDefaultName:@"USB-TypeScanner"];
	return override ?: [NSImage imageNamed:@"USB-TypeScanner"];
}

-(IBAction)fieldToggleChanged:(NSButton*)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
	[self updateBrowsingState];
}

-(NSButton *)checkboxWithKey:(NSString *)key title:(NSString *)title defaultOn:(BOOL)defaultOn {
	NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(fieldToggleChanged:)];
	box.identifier = key;
	box.state = HWGScannerBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	return box;
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 560, 340)];
	tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 340)];

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notification fields", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:header];
	[NSLayoutConstraint activateConstraints:@[
		[header.topAnchor     constraintEqualToAnchor:v.topAnchor constant:16],
		[header.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
	]];

	// Brand-new capability requesting a brand-new macOS permission (Local Network) — OFF by
	// default, same as every other new monitor added to this app, but doubly important here
	// since this is the first feature that will ever trigger that specific system prompt.
	NSButton *row = [self checkboxWithKey:HWG_SCANNER_NOTIFY_KEY title:NSLocalizedString(@"Enable network scanner detection", @"") defaultOn:NO];
	[v addSubview:row];
	[NSLayoutConstraint activateConstraints:@[
		[row.topAnchor     constraintEqualToAnchor:header.bottomAnchor constant:10],
		[row.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
		[row.heightAnchor   constraintEqualToConstant:24],
	]];

	NSTextField *caption = [NSTextField wrappingLabelWithString:
		NSLocalizedString(@"Detects scanners on your local network via Bonjour (_scanner._tcp and _uscan._tcp/eSCL-AirScan). Enabling this asks macOS for Local Network permission — a prompt this app has never shown before.", @"")];
	caption.textColor = [NSColor secondaryLabelColor];
	caption.font = [NSFont systemFontOfSize:11];
	caption.translatesAutoresizingMaskIntoConstraints = NO;
	caption.preferredMaxLayoutWidth = 380;
	[v addSubview:caption];
	[NSLayoutConstraint activateConstraints:@[
		[caption.topAnchor     constraintEqualToAnchor:row.bottomAnchor constant:8],
		[caption.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
		[caption.trailingAnchor constraintLessThanOrEqualToAnchor:v.trailingAnchor constant:-16],
	]];

	// Added 17-ago-2026 (feedback del usuario) — <pwg:JobStateReason> entries on Scan
	// Started/Finished, same ScannerStatus poll already parsed above. OFF by default: optional
	// field, may never appear depending on firmware.
	NSButton *jobReasonsRow = [self checkboxWithKey:HWG_SCANNER_SHOW_JOB_REASONS_KEY title:NSLocalizedString(@"Job state reasons on Scan Started/Finished (experimental)", @"") defaultOn:NO];
	[v addSubview:jobReasonsRow];
	[NSLayoutConstraint activateConstraints:@[
		[jobReasonsRow.topAnchor     constraintEqualToAnchor:caption.bottomAnchor constant:14],
		[jobReasonsRow.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
		[jobReasonsRow.heightAnchor   constraintEqualToConstant:24],
	]];

	NSTabViewItem *generalItem = [[NSTabViewItem alloc] initWithIdentifier:@"general"];
	generalItem.label = NSLocalizedString(@"General", @"");
	generalItem.view = v;
	[tabs addTabViewItem:generalItem];

	// --- Tab: Icons ---
	CGFloat iconsPad = 16;
	CGFloat iconsWidth = 560 - 2 * iconsPad;
	// Each row now has its own dedicated icon instead of all four sharing the bare module glyph
	// (17-ago-2026, feedback del usuario) — Found/Lost also split into two independent toggles,
	// matching Printer Monitor's Connected/Needs Attention precedent (one key per icon row).
	HWGIconPickerView *iconPicker = [[HWGIconPickerView alloc] initWithIconSpecs:@[
		@[@"Module Icon (Sidebar)", @"USB-TypeScanner"],
		@[@"Scanner Found", @"ScannerMonitor-Icon-Found", HWG_SCANNER_NOTIFY_FOUND_KEY],
		@[@"Scanner Lost", @"ScannerMonitor-Icon-Lost", HWG_SCANNER_NOTIFY_LOST_KEY],
		// Moved here from General (13-ago-2026, feedback del usuario) — per this app's
		// convention, "Notify when X" toggles always live in Icons, never General (General is
		// only for field-visibility toggles on an existing notice). Both OFF by default: neither
		// has been verified against real hardware yet (see each feature's own doc comment above,
		// and -noteDescriptions below, which still spells out "experimental" in full).
		//
		// BUG FIX (17-ago-2026): labels used to say "... (experimental)" — at 249-252pt wide,
		// that blew nameColumnWidth (shared across every row in this picker) past this fixed
		// 560pt-wide pane's available 528pt, pushing EVERY row's notify checkbox in this tab
		// (including Found/Lost, unrelated to these two rows) outside the clickable area.
		// Confirmed live: no checkbox in this tab responded to clicks until this was shortened.
		@[@"Scan Started/Finished", @"ScannerMonitor-Icon-ScanStatus", HWG_SCANNER_NOTIFY_SCANSTATUS_KEY, @NO],
		@[@"Feeder State Changed", @"ScannerMonitor-Icon-AdfState", HWG_SCANNER_NOTIFY_ADFSTATE_KEY, @NO],
	]];
	iconPicker.translatesAutoresizingMaskIntoConstraints = YES;
	iconPicker.frame = NSMakeRect(0, 0, iconsWidth, 0);
	CGFloat iconPickerH = iconPicker.fittingSize.height;

	NSTextField *iconsHeader = [NSTextField labelWithString:NSLocalizedString(@"Notification icons", @"")];
	iconsHeader.font = [NSFont boldSystemFontOfSize:12];
	iconsHeader.textColor = [NSColor secondaryLabelColor];
	iconsHeader.translatesAutoresizingMaskIntoConstraints = YES;
	CGFloat iconsHeaderH = iconsHeader.fittingSize.height;
	CGFloat iconsGap = 12;

	// Visible caveat for "Scan Started/Finished" and "Feeder State Changed" (17-ago-2026,
	// feedback del usuario) — their row labels themselves must stay short (see the BUG FIX
	// comment above: a longer "(experimental)" suffix broke every checkbox in this tab by
	// blowing the shared column width), so the "not yet verified against real hardware" caveat
	// is surfaced here instead, as a plain caption below the picker — same information, safe
	// from that layout bug since this caption doesn't affect nameColumnWidth at all.
	NSTextField *experimentalNote = [NSTextField wrappingLabelWithString:
		NSLocalizedString(@"\"Scan Started/Finished\" and \"Feeder State Changed\" are experimental: implemented and enabled by these checkboxes, but not yet confirmed against a real network scanner. \"Feeder State Changed\" may also simply never fire on some devices — that field is optional in the eSCL spec many scanners don't implement it.", @"")];
	experimentalNote.textColor = [NSColor secondaryLabelColor];
	experimentalNote.font = [NSFont systemFontOfSize:11];
	experimentalNote.translatesAutoresizingMaskIntoConstraints = YES;
	experimentalNote.frame = NSMakeRect(0, 0, iconsWidth, 0);
	CGFloat experimentalNoteH = ceil([experimentalNote.cell cellSizeForBounds:NSMakeRect(0, 0, iconsWidth, CGFLOAT_MAX)].height);

	NSView *iconsContent = [[HWGFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, 560, iconsHeaderH + iconsGap + iconPickerH + iconsGap + experimentalNoteH + 2 * iconsPad)];
	iconsHeader.frame = NSMakeRect(iconsPad, iconsPad, iconsWidth, iconsHeaderH);
	[iconsContent addSubview:iconsHeader];
	iconPicker.frame = NSMakeRect(iconsPad, iconsPad + iconsHeaderH + iconsGap, iconsWidth, iconPickerH);
	[iconsContent addSubview:iconPicker];
	experimentalNote.frame = NSMakeRect(iconsPad, iconsPad + iconsHeaderH + iconsGap + iconPickerH + iconsGap, iconsWidth, experimentalNoteH);
	[iconsContent addSubview:experimentalNote];

	NSScrollView *iconsScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 560, 120)];
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
	return [NSArray arrayWithObjects:@"ScannerFound", @"ScannerLost", @"ScannerScanStatus", @"ScannerAdfStateChanged", nil];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Network Scanner Found", @""), @"ScannerFound",
			  NSLocalizedString(@"Network Scanner Lost", @""), @"ScannerLost",
			  NSLocalizedString(@"Scan Started/Finished", @""), @"ScannerScanStatus",
			  NSLocalizedString(@"Feeder State Changed", @""), @"ScannerAdfStateChanged", nil];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Sent when a network scanner (Bonjour _scanner._tcp/_uscan._tcp) appears on the LAN", @""), @"ScannerFound",
			  NSLocalizedString(@"Sent when a previously-seen network scanner disappears from the LAN", @""), @"ScannerLost",
			  NSLocalizedString(@"Sent when a scan job starts or finishes (experimental, via eSCL ScannerStatus polling)", @""), @"ScannerScanStatus",
			  NSLocalizedString(@"Sent when the automatic document feeder's state changes (jam/empty/cover open, experimental, when reported by the device)", @""), @"ScannerAdfStateChanged", nil];
}
-(NSArray*)defaultNotifications {
	return [NSArray array];
}

@end
