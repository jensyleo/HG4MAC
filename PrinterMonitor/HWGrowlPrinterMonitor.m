//
//  HWGrowlPrinterMonitor.m
//  HardwareGrowler
//
//  F34 #5: printer connected/disconnected. There is no public push notification for the
//  system's printer list changing — this monitor POLLS the current CUPS destination list on
//  a short timer and diffs against the previous snapshot. This works uniformly for USB,
//  Bluetooth, AND network (IPP/AirPrint/Bonjour) printers because all three end up as CUPS
//  destinations once macOS has added them (System Settings → Printers & Scanners) — but a
//  network printer only appears once it's actually been ADDED there, not merely
//  reachable/discoverable on the LAN. OFF by default per user request.
//
//  BUG FIX (23-jul-2026): originally used `[NSPrinter printerNames]` (classic AppKit printing
//  API) — confirmed via live testing (added/removed a real Bonjour/AirPrint printer) that this
//  API returns an EMPTY list in this app the entire time, even while `lpstat -p` / CUPS itself
//  correctly showed the printer as added. `NSPrinter` apparently doesn't reliably enumerate
//  CUPS destinations for this kind of background-only (LSUIElement) process. Switched to
//  `cupsGetDests()` — the actual public CUPS C API `lpstat` itself is built on — which reads
//  the destination list directly and does not depend on any AppKit printing-panel machinery.
//
//  ATTEMPTED (23-jul-2026, REVERTED): tried watching /etc/cups/printers.conf directly via a
//  kqueue-backed DispatchSource for instant, event-driven detection instead of polling.
//  Confirmed via live testing this silently detected nothing at all: that file is mode 0600,
//  owned by root:_lp — a normal user process cannot even open() it, so the watcher never
//  attached (open() failed, and the code silently gave up, exactly matching the report "no
//  notifica nada"). `cupsGetDests()` itself doesn't have this problem because it talks to
//  cupsd over IPP (a local socket any user can query), not by reading the config file
//  directly. Reverted to polling, but with a much shorter interval (3s vs the original 15s)
//  since cupsGetDests() itself is a cheap local IPP round-trip — this gets most of the
//  "feels instant" benefit without requiring privileges this app will never have.

// compile with ARC: -fobjc-arc
#import "HWGrowlPrinterMonitor.h"
#import "HWGIconOverrideStore.h"
#import "HWGIconPickerView.h"
#import <cups/cups.h>

#define HWG_PRINTER_NOTIFY_KEY @"HWGPrinterNotifyConnectDisconnect"
#define HWG_PRINTER_POLL_INTERVAL 8.0

// F34 follow-up (23-jul-2026, user request): 3 additions, all OFF by default —
// #1 printer error/warning state, #2 default-printer-changed, #3 extra info fields on Connected.
#define HWG_PRINTER_NOTIFY_ERROR_KEY   @"HWGPrinterNotifyErrorState"
#define HWG_PRINTER_NOTIFY_CONNECT_KEY @"HWGPrinterNotifyConnectRow"
#define HWG_PRINTER_NOTIFY_DEFAULT_KEY @"HWGPrinterNotifyDefaultChanged"
#define HWG_PRINTER_SHOW_LOCATION_KEY   @"HWGPrinterShowLocation"
#define HWG_PRINTER_SHOW_MAKEMODEL_KEY  @"HWGPrinterShowMakeModel"
#define HWG_PRINTER_SHOW_CONNECTION_KEY @"HWGPrinterShowConnectionType"
#define HWG_PRINTER_SHOW_SHARED_KEY     @"HWGPrinterShowShared"

// #6 (Fase B, 04-ago-2026): print job started/finished. Investigated first: CUPS has no true
// push mechanism usable in-process (IPP job subscriptions only invoke external rss:/mailto:
// notifier binaries or still require polling their own event queue) — polling `cupsGetJobs()`
// on the SAME timer this monitor already uses for `cupsGetDests()` is the only realistic,
// low-effort path, and fits the existing "cheap local IPP round-trip every 3s" reasoning
// above. OFF by default like the other opt-in additions. UNTESTED against a real print job:
// this Mac has zero configured printers (`lpstat -p` empty) — logic verified against CUPS's
// public header (`ipp_jstate_t` enum: PENDING/HELD/PROCESSING/STOPPED/CANCELED/ABORTED/
// COMPLETED) but not exercised against an actual job in flight. See TODO.md.
#define HWG_PRINTER_NOTIFY_JOB_KEY @"HWGPrinterNotifyJobStatus"

// Toner/ink levels via IPP marker-levels (12-ago-2026 investigation) — this is live printer
// STATE, not part of cupsGetDests()'s cached destination options like #1/#2/#3 above (those
// come from CUPS's own local cache; marker-levels requires an explicit Get-Printer-Attributes
// IPP round-trip per printer). Confirmed public/standard: the IPP "Marker" attribute group
// (marker-names/marker-levels/marker-colors/marker-types) is part of the IPP Everywhere /
// Printer MIB-derived standard attribute set, exposed identically by CUPS regardless of the
// underlying connection (USB/Bluetooth/Network all present as local CUPS queues either way).
// Polled far less often than connect/disconnect/error/job checks (every 10th tick ≈ 30s
// instead of every 3s) since — unlike cupsGetDests()/cupsGetJobs(), which only ever talk to
// the local cupsd — this is a live round-trip to the physical printer itself for network/
// Bluetooth devices, and many older/cheaper printers simply don't report it at all (silently
// skipped, not an error). OFF by default; threshold fixed at 10% (documented in the UI
// caption) rather than a slider — unlike WiFi's poll interval, which genuinely varies by
// environment, one sensible low-ink threshold covers the real use case here without adding a
// second control surface for a checkbox this minor.
#define HWG_PRINTER_NOTIFY_SUPPLY_KEY @"HWGPrinterNotifySupplyLow"
#define HWG_PRINTER_SUPPLY_POLL_EVERY_N_TICKS 10
#define HWG_PRINTER_SUPPLY_LOW_THRESHOLD 10
#define HWG_PRINTER_SUPPLY_RECOVER_THRESHOLD 15

static BOOL HWGPrinterBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

// One CUPS destination's info, read once per poll and reused for all 3 features below (name
// diffing, error-state tracking, default-printer tracking, and Connected's extra info lines) —
// avoids querying CUPS multiple times per tick for the same data.
@interface HWGPrinterInfo : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL isDefault;
@property (nonatomic, copy) NSString *stateReasons;   // e.g. "none", or "media-empty-warning,toner-low-warning"
@property (nonatomic, copy) NSString *location;
@property (nonatomic, copy) NSString *makeModel;
@property (nonatomic, copy) NSString *connectionType;   // "USB" / "Network" / "Bluetooth" / raw scheme
// Added 17-ago-2026 (feedback del usuario) — printer-is-shared, already sitting in the same
// per-dest options dict every other field above reads, no extra IPP round-trip needed.
@property (nonatomic, assign) BOOL isShared;
@end
@implementation HWGPrinterInfo
@end

// Maps a device-uri scheme (e.g. "usb://…", "dnssd://…") to a human-readable connection type.
// Same 3-way split already documented in README for how this monitor detects printers.
static NSString *HWGConnectionTypeForDeviceURI(NSString *uri) {
	if (![uri length]) return nil;
	NSString *scheme = [[uri componentsSeparatedByString:@":"] firstObject].lowercaseString;
	if ([scheme isEqualToString:@"usb"]) return NSLocalizedString(@"USB", @"");
	if ([scheme isEqualToString:@"bluetooth"]) return NSLocalizedString(@"Bluetooth", @"");
	if ([scheme isEqualToString:@"dnssd"] || [scheme isEqualToString:@"ipp"] || [scheme isEqualToString:@"ipps"] ||
		[scheme isEqualToString:@"socket"] || [scheme isEqualToString:@"lpd"] || [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
		return NSLocalizedString(@"Network", @"");
	}
	return [scheme length] ? [scheme uppercaseString] : nil;
}

// Reads every CUPS destination (what `lpstat -p` also reads — see BUG FIX note above for why
// this replaced `[NSPrinter printerNames]`) with the extra attributes #1/#2/#3 need.
static NSDictionary<NSString*, HWGPrinterInfo*> *HWGCollectPrinterInfo(void) {
	cups_dest_t *dests = NULL;
	int count = cupsGetDests(&dests);
	NSMutableDictionary<NSString*, HWGPrinterInfo*> *result = [NSMutableDictionary dictionaryWithCapacity:(NSUInteger)MAX(count, 0)];
	for (int i = 0; i < count; i++) {
		cups_dest_t *dest = &dests[i];
		if (!dest->name) continue;
		HWGPrinterInfo *info = [[HWGPrinterInfo alloc] init];
		info.name = [NSString stringWithUTF8String:dest->name];
		info.isDefault = dest->is_default ? YES : NO;

		const char *reasons = cupsGetOption("printer-state-reasons", dest->num_options, dest->options);
		info.stateReasons = reasons ? [NSString stringWithUTF8String:reasons] : @"none";

		const char *location = cupsGetOption("printer-location", dest->num_options, dest->options);
		info.location = (location && *location) ? [NSString stringWithUTF8String:location] : nil;

		const char *makeModel = cupsGetOption("printer-make-and-model", dest->num_options, dest->options);
		info.makeModel = (makeModel && *makeModel) ? [NSString stringWithUTF8String:makeModel] : nil;

		const char *deviceURI = cupsGetOption("device-uri", dest->num_options, dest->options);
		info.connectionType = deviceURI ? HWGConnectionTypeForDeviceURI([NSString stringWithUTF8String:deviceURI]) : nil;

		const char *isShared = cupsGetOption("printer-is-shared", dest->num_options, dest->options);
		info.isShared = (isShared && strcmp(isShared, "true") == 0);

		result[info.name] = info;
	}
	if (dests) cupsFreeDests(count, dests);
	return result;
}

// Whether a printer-state-reasons string indicates an actual problem. Per the IPP spec
// (RFC 8011 §5.4.12), each comma-separated keyword carries its own severity as a suffix:
// "-error" (blocks printing), "-warning" (degraded but still working), or no suffix at all
// ("-report", purely informational — e.g. "connecting-to-device", which just means the
// printer/driver is opening the connection to send a job, a completely normal part of
// printing over network/WiFi, not something to "check the printer" about).
//
// BUG FIX (27-jul-2026): this used to treat ANY reason other than the literal "none" as a
// problem — including plain "-report"-level keywords. Confirmed live over WiFi printing:
// the printer reports "connecting-to-device" while a job starts, which isn't a suffixed
// keyword at all, so the old code fired a false "Printer Needs Attention", then a false
// "Printer OK" once the job finished and the reason cleared — both about a normal print,
// not an actual problem. Fixed to only match "-error"/"-warning" suffixes, per spec.
static BOOL HWGStateReasonsIndicateProblem(NSString *reasons) {
	if (![reasons length] || [reasons isEqualToString:@"none"]) return NO;
	for (NSString *reason in [reasons componentsSeparatedByString:@","]) {
		if ([reason hasSuffix:@"-error"] || [reason hasSuffix:@"-warning"]) return YES;
	}
	return NO;
}

// Maps known IPP printer-state-reasons keywords (RFC 8011 §5.4.12 base set + common vendor-
// neutral extensions also defined in the same registry) to short, human-readable phrases —
// e.g. "Out of paper" instead of the raw "media-empty-error" that used to be shown verbatim in
// the notification body. Falls back to a dash→space, capitalized rendering of the raw keyword
// for anything not in this table, so an unrecognized/vendor-specific reason still reads
// reasonably instead of being dropped or shown as raw hyphenated IPP syntax.
static NSString *HWGFriendlyLabelForStateReason(NSString *reasonWithSuffix) {
	static NSDictionary<NSString*, NSString*> *table = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		table = @{
			@"media-empty":              NSLocalizedString(@"Out of paper", @""),
			@"media-jam":                NSLocalizedString(@"Paper jam", @""),
			@"media-low":                NSLocalizedString(@"Paper low", @""),
			@"media-needed":             NSLocalizedString(@"Wrong paper loaded", @""),
			@"door-open":                NSLocalizedString(@"Door open", @""),
			@"cover-open":               NSLocalizedString(@"Cover open", @""),
			@"interlock-open":           NSLocalizedString(@"Interlock open", @""),
			@"toner-low":                NSLocalizedString(@"Toner low", @""),
			@"toner-empty":              NSLocalizedString(@"Toner empty", @""),
			@"marker-supply-low":        NSLocalizedString(@"Ink/toner low", @""),
			@"marker-supply-empty":      NSLocalizedString(@"Ink/toner empty", @""),
			@"marker-waste-almost-full": NSLocalizedString(@"Waste tank almost full", @""),
			@"marker-waste-full":        NSLocalizedString(@"Waste tank full", @""),
			@"input-tray-missing":       NSLocalizedString(@"Paper tray missing", @""),
			@"output-tray-missing":      NSLocalizedString(@"Output tray missing", @""),
			@"output-area-almost-full":  NSLocalizedString(@"Output tray almost full", @""),
			@"output-area-full":         NSLocalizedString(@"Output tray full", @""),
			@"paused":                   NSLocalizedString(@"Paused", @""),
			@"shutdown":                 NSLocalizedString(@"Shutting down", @""),
			@"stopped-partly":           NSLocalizedString(@"Partially stopped", @""),
			@"stopping":                 NSLocalizedString(@"Stopping", @""),
			@"timed-out":                NSLocalizedString(@"Not responding", @""),
			@"offline":                  NSLocalizedString(@"Offline", @""),
			@"fuser-over-temp":          NSLocalizedString(@"Fuser overheating", @""),
			@"fuser-under-temp":         NSLocalizedString(@"Fuser too cold", @""),
			@"spool-area-full":          NSLocalizedString(@"Spool area full", @""),
		};
	});

	NSString *base = reasonWithSuffix;
	for (NSString *suffix in @[@"-error", @"-warning", @"-report"]) {
		if ([base hasSuffix:suffix]) { base = [base substringToIndex:base.length - suffix.length]; break; }
	}
	NSString *friendly = table[base];
	if (friendly) return friendly;
	NSString *spaced = [base stringByReplacingOccurrencesOfString:@"-" withString:@" "];
	if (!spaced.length) return base;
	return [spaced stringByReplacingCharactersInRange:NSMakeRange(0, 1) withString:[[spaced substringToIndex:1] uppercaseString]];
}

// Builds the full human-readable description for a "Needs Attention" notification from the raw
// comma-separated printer-state-reasons string — e.g. "Out of paper, Cover open" instead of
// "media-empty-error,cover-open-warning". Only the "-error"/"-warning" keywords are included
// (matching HWGStateReasonsIndicateProblem's own definition of "an actual problem" above);
// purely informational "-report" keywords are left out here too. Returns nil if there's
// nothing to show (caller falls back to the raw string in that case, which shouldn't normally
// happen since this is only called when HWGStateReasonsIndicateProblem already said YES).
static NSString *HWGFriendlyStateReasonsDescription(NSString *reasons) {
	if (![reasons length] || [reasons isEqualToString:@"none"]) return nil;
	NSMutableArray<NSString*> *labels = [NSMutableArray array];
	for (NSString *reason in [reasons componentsSeparatedByString:@","]) {
		if ([reason hasSuffix:@"-error"] || [reason hasSuffix:@"-warning"]) {
			[labels addObject:HWGFriendlyLabelForStateReason(reason)];
		}
	}
	return labels.count ? [labels componentsJoinedByString:@", "] : nil;
}

// Formats a job's processing duration for the "Print Job Finished" notification body.
static NSString *HWGFormattedDuration(NSTimeInterval seconds) {
	NSInteger total = (NSInteger)llround(seconds);
	NSInteger mins = total / 60;
	NSInteger secs = total % 60;
	if (mins > 0) return [NSString stringWithFormat:NSLocalizedString(@"%ldm %lds", @""), (long)mins, (long)secs];
	return [NSString stringWithFormat:NSLocalizedString(@"%lds", @""), (long)secs];
}

// One toner/ink marker's live reading — a printer usually reports several (e.g. separate
// Cyan/Magenta/Yellow/Black cartridges), so a printer can appear more than once in the array
// HWGCopyMarkerLevelsForDest returns below.
@interface HWGMarkerInfo : NSObject
@property (nonatomic, copy) NSString *name;    // e.g. "Black Cartridge" — from marker-names
@property (nonatomic, copy) NSString *color;   // e.g. "black" / "#00FFFF" — from marker-colors, may be nil
@property (nonatomic, assign) NSInteger level; // 0-100, or -1 per IPP spec meaning "not reported"
@end
@implementation HWGMarkerInfo
@end

// Queries live marker-levels (toner/ink) via a direct IPP Get-Printer-Attributes request against
// the printer's own local CUPS queue URI ("ipp://localhost:<port>/printers/<name>" — the same
// address `lpstat`/`ipptool` use for any CUPS-registered destination, regardless of whether the
// physical printer itself is USB/Bluetooth/Network). This data is NOT part of cupsGetDests()'s
// cached destination options (unlike printer-state-reasons/location/make-model above), so it
// needs its own request — hence why this is polled on a slower cadence than the rest of this
// monitor (see HWG_PRINTER_SUPPLY_POLL_EVERY_N_TICKS). Returns nil if the printer doesn't answer
// within the timeout (offline/unreachable) or doesn't report any markers at all (common on
// older/cheaper printers) — both cases are silently skipped by the caller, not treated as errors.
static NSArray<HWGMarkerInfo*> *HWGCopyMarkerLevelsForDest(cups_dest_t *dest) {
	char resource[1024];
	http_t *http = cupsConnectDest(dest, CUPS_DEST_FLAGS_NONE, 3000, NULL, resource, sizeof(resource), NULL, NULL);
	if (!http) return nil;

	char uri[1024];
	httpAssembleURIf(HTTP_URI_CODING_ALL, uri, sizeof(uri), "ipp", NULL, "localhost", ippPort(), "/printers/%s", dest->name);

	ipp_t *request = ippNewRequest(IPP_OP_GET_PRINTER_ATTRIBUTES);
	ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", NULL, uri);
	ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", NULL, cupsUser());
	static const char * const requestedAttrs[] = { "marker-names", "marker-levels", "marker-colors", "marker-types" };
	ippAddStrings(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes", 4, NULL, requestedAttrs);

	ipp_t *response = cupsDoRequest(http, request, resource);
	httpClose(http);
	if (!response) return nil;

	ipp_attribute_t *levelsAttr = ippFindAttribute(response, "marker-levels", IPP_TAG_ZERO);
	ipp_attribute_t *namesAttr  = ippFindAttribute(response, "marker-names", IPP_TAG_ZERO);
	ipp_attribute_t *colorsAttr = ippFindAttribute(response, "marker-colors", IPP_TAG_ZERO);
	if (!levelsAttr) { ippDelete(response); return nil; }

	int count = ippGetCount(levelsAttr);
	NSMutableArray<HWGMarkerInfo*> *result = [NSMutableArray arrayWithCapacity:(NSUInteger)MAX(count, 0)];
	for (int i = 0; i < count; i++) {
		HWGMarkerInfo *marker = [[HWGMarkerInfo alloc] init];
		marker.level = ippGetInteger(levelsAttr, i);
		const char *name = (namesAttr && i < ippGetCount(namesAttr)) ? ippGetString(namesAttr, i, NULL) : NULL;
		const char *color = (colorsAttr && i < ippGetCount(colorsAttr)) ? ippGetString(colorsAttr, i, NULL) : NULL;
		marker.name = name ? [NSString stringWithUTF8String:name] : [NSString stringWithFormat:NSLocalizedString(@"Supply %d", @""), i + 1];
		marker.color = color ? [NSString stringWithUTF8String:color] : nil;
		[result addObject:marker];
	}
	ippDelete(response);
	return result;
}

@interface HWGrowlPrinterMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, strong) NSView *prefsView;
@property (nonatomic, strong) NSSet<NSString*> *knownPrinterNames;
@property (nonatomic, strong) NSTimer *pollTimer;

// #1: last known state-reasons per printer, to fire only on the OK↔problem transition, not
// on every poll tick while a problem persists.
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSString*> *lastKnownStateReasons;
// #2: last known default-printer name, to fire only when it actually changes.
@property (nonatomic, copy) NSString *lastKnownDefaultPrinter;

// #6: last known ipp_jstate_t per job ID (boxed NSNumber), to fire only on the
// active→terminal transition, and a baseline-seeded flag so enabling the feature never
// retroactively "starts"-notifies jobs already in flight before the checkbox was turned on.
@property (nonatomic, strong) NSMutableDictionary<NSNumber*, NSNumber*> *lastKnownJobStates;
@property (nonatomic, assign) BOOL jobTrackingBaselineSeeded;

// Toner/ink levels: tick counter to poll the slower marker-levels check every Nth
// -checkPrinters call (see HWG_PRINTER_SUPPLY_POLL_EVERY_N_TICKS), and last known "was low"
// state per printer+marker (key: "printerName|markerName") so the notification fires only on
// the healthy→low transition, with hysteresis (HWG_PRINTER_SUPPLY_LOW_THRESHOLD vs
// _RECOVER_THRESHOLD) so a level hovering right at the cutoff can't flap repeatedly.
@property (nonatomic, assign) NSUInteger pollTickCount;
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSNumber*> *lastKnownSupplyLow;

@end

@implementation HWGrowlPrinterMonitor

@synthesize delegate;
@synthesize prefsView;

-(id)init {
	if ((self = [super init])) {
		self.lastKnownStateReasons = [NSMutableDictionary dictionary];
		self.lastKnownJobStates = [NSMutableDictionary dictionary];
		self.lastKnownSupplyLow = [NSMutableDictionary dictionary];
		// Baseline silently at launch — never announce printers/states/defaults that were
		// already present.
		NSDictionary<NSString*, HWGPrinterInfo*> *info = HWGCollectPrinterInfo();
		self.knownPrinterNames = [NSSet setWithArray:[info allKeys]];
		for (HWGPrinterInfo *p in [info allValues]) {
			self.lastKnownStateReasons[p.name] = p.stateReasons;
			if (p.isDefault) self.lastKnownDefaultPrinter = p.name;
		}
		[self updateWatcherState];
	}
	return self;
}

-(void)dealloc {
	[_pollTimer invalidate];
}

-(void)updateWatcherState {
	// BUG FIX (04-ago-2026): this used to gate the poll timer on HWG_PRINTER_NOTIFY_KEY alone —
	// meaning enabling ONLY the #1/#2/#6 follow-up checkboxes (error state, default-changed,
	// job status) while leaving the original connect/disconnect toggle off would never even
	// start the timer, silently doing nothing. Now starts the timer if ANY of the 4 features
	// that depend on it are enabled.
	BOOL enabled = HWGPrinterBoolForKey(HWG_PRINTER_NOTIFY_KEY, NO) ||
		HWGPrinterBoolForKey(HWG_PRINTER_NOTIFY_ERROR_KEY, NO) ||
		HWGPrinterBoolForKey(HWG_PRINTER_NOTIFY_DEFAULT_KEY, NO) ||
		HWGPrinterBoolForKey(HWG_PRINTER_NOTIFY_JOB_KEY, NO) ||
		HWGPrinterBoolForKey(HWG_PRINTER_NOTIFY_SUPPLY_KEY, NO);
	if (enabled && !_pollTimer) {
		self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:HWG_PRINTER_POLL_INTERVAL
														   target:self
														 selector:@selector(checkPrinters)
														 userInfo:nil
														  repeats:YES];
	} else if (!enabled && _pollTimer) {
		[_pollTimer invalidate];
		self.pollTimer = nil;
	}
}

-(void)checkPrinters {
	NSDictionary<NSString*, HWGPrinterInfo*> *currentInfo = HWGCollectPrinterInfo();
	NSSet<NSString*> *currentNames = [NSSet setWithArray:[currentInfo allKeys]];

	BOOL namesChanged = ![currentNames isEqualToSet:self.knownPrinterNames];
	BOOL showLocation   = HWGPrinterBoolForKey(HWG_PRINTER_SHOW_LOCATION_KEY, NO);
	BOOL showMakeModel  = HWGPrinterBoolForKey(HWG_PRINTER_SHOW_MAKEMODEL_KEY, NO);
	BOOL showConnection = HWGPrinterBoolForKey(HWG_PRINTER_SHOW_CONNECTION_KEY, NO);

	if (namesChanged) {
		NSMutableSet<NSString*> *added = [currentNames mutableCopy];
		[added minusSet:self.knownPrinterNames];
		NSMutableSet<NSString*> *removed = [self.knownPrinterNames mutableCopy];
		[removed minusSet:currentNames];

		NSImage *icon = [HWGrowlPrinterMonitor printerIconConnected:YES];
		NSData *onIcon = [icon TIFFRepresentation];
		NSImage *offImage = [HWGrowlPrinterMonitor printerIconConnected:NO];
		NSData *offIcon = [offImage TIFFRepresentation];

		for (NSString *name in added) {
			// #3: extra info lines on Connected — each independently toggleable, OFF by
			// default (23-jul-2026). Absent entirely if all 3 are off, matching the plain
			// name-only description this notification always had before.
			HWGPrinterInfo *info = currentInfo[name];
			NSMutableArray<NSString*> *lines = [NSMutableArray arrayWithObject:name];
			if (showLocation && [info.location length]) {
				[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Location: %@", @""), info.location]];
			}
			if (showMakeModel && [info.makeModel length]) {
				[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Model: %@", @""), info.makeModel]];
			}
			if (showConnection && [info.connectionType length]) {
				[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Connection: %@", @""), info.connectionType]];
			}
			// Added 17-ago-2026 (feedback del usuario) — printer-is-shared, same options dict
			// already read above, no extra IPP round-trip.
			if (HWGPrinterBoolForKey(HWG_PRINTER_SHOW_SHARED_KEY, NO)) {
				[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Shared: %@", @""), info.isShared ? NSLocalizedString(@"Yes", @"") : NSLocalizedString(@"No", @"")]];
			}

			if (HWGPrinterBoolForKey(HWG_PRINTER_NOTIFY_CONNECT_KEY, YES)) {
				[delegate notifyWithName:@"PrinterConnected"
										 title:NSLocalizedString(@"Printer Connected", @"")
								 description:[lines componentsJoinedByString:@"\n"]
										  icon:onIcon
						  identifierString:[NSString stringWithFormat:@"HWGrowlPrinter-%@", name]
							  contextString:nil
										plugin:self];
			}
		}
		for (NSString *name in removed) {
			[delegate notifyWithName:@"PrinterDisconnected"
									 title:NSLocalizedString(@"Printer Disconnected", @"")
							 description:name
									  icon:offIcon
					  identifierString:[NSString stringWithFormat:@"HWGrowlPrinter-%@", name]
						  contextString:nil
									plugin:self];
		}

		// Re-arm error-state tracking for removed printers (a later reinsertion should be
		// evaluated fresh, not compared against a stale reading from before it disappeared).
		for (NSString *name in removed) [self.lastKnownStateReasons removeObjectForKey:name];

		self.knownPrinterNames = currentNames;
	}

	// #1: error/warning state — OFF by default. Fires only on the OK↔problem transition.
	if (HWGPrinterBoolForKey(HWG_PRINTER_NOTIFY_ERROR_KEY, NO)) {
		for (HWGPrinterInfo *info in [currentInfo allValues]) {
			NSString *previousReasons = self.lastKnownStateReasons[info.name];
			BOOL wasProblem = HWGStateReasonsIndicateProblem(previousReasons);
			BOOL isProblem  = HWGStateReasonsIndicateProblem(info.stateReasons);
			if (isProblem && !wasProblem) {
				NSData *iconData = [[HWGrowlPrinterMonitor printerIconConnected:NO] TIFFRepresentation];
				NSString *friendlyReasons = HWGFriendlyStateReasonsDescription(info.stateReasons);
				[delegate notifyWithName:@"PrinterError"
										 title:NSLocalizedString(@"Printer Needs Attention", @"")
								 description:[NSString stringWithFormat:@"%@\n%@", info.name, friendlyReasons ?: info.stateReasons]
										  icon:iconData
						  identifierString:[NSString stringWithFormat:@"HWGrowlPrinterError-%@", info.name]
							  contextString:nil
										plugin:self];
			} else if (!isProblem && wasProblem) {
				NSData *iconData = [[HWGrowlPrinterMonitor printerIconConnected:YES] TIFFRepresentation];
				[delegate notifyWithName:@"PrinterError"
										 title:NSLocalizedString(@"Printer OK", @"")
								 description:info.name
										  icon:iconData
						  identifierString:[NSString stringWithFormat:@"HWGrowlPrinterError-%@", info.name]
							  contextString:nil
										plugin:self];
			}
			self.lastKnownStateReasons[info.name] = info.stateReasons;
		}
	}

	// #2: default printer changed — OFF by default. Fires only on an actual change, and
	// never on the very first read (nothing to compare "from" yet).
	if (HWGPrinterBoolForKey(HWG_PRINTER_NOTIFY_DEFAULT_KEY, NO)) {
		NSString *currentDefault = nil;
		for (HWGPrinterInfo *info in [currentInfo allValues]) {
			if (info.isDefault) { currentDefault = info.name; break; }
		}
		if (currentDefault && ![currentDefault isEqualToString:self.lastKnownDefaultPrinter]) {
			NSString *previous = self.lastKnownDefaultPrinter;
			self.lastKnownDefaultPrinter = currentDefault;
			if (previous) {   // skip the very first baseline read
				// 12-ago-2026: own dedicated icon (rotating-arrows badge on the printer glyph,
				// replacing the shared Connected checkmark badge) instead of reusing
				// +printerIconConnected: — see PrinterMonitor-Icon-DefaultChanged in
				// Assets.xcassets. HWGResolveIconNamed already handles the user-override check.
				NSData *iconData = [HWGResolveIconNamed(@"PrinterMonitor-Icon-DefaultChanged") TIFFRepresentation];
				[delegate notifyWithName:@"PrinterDefaultChanged"
										 title:NSLocalizedString(@"Default Printer Changed", @"")
								 description:[NSString stringWithFormat:NSLocalizedString(@"%@ → %@", @""), previous, currentDefault]
										  icon:iconData
						  identifierString:@"HWGrowlPrinterDefault"
							  contextString:nil
										plugin:self];
			}
		}
	}

	// BUG FIX (05-ago-2026): this block was accidentally left nested inside the #2
	// (HWG_PRINTER_NOTIFY_DEFAULT_KEY) `if` above — since that checkbox defaults OFF, print
	// job polling silently never ran at all, regardless of HWG_PRINTER_NOTIFY_JOB_KEY's own
	// state. Confirmed live with a real local test print queue: moving this to run
	// unconditionally (same level as #1/#2 above) fixed it — jobs now correctly detected.
	// #6: print job started/finished.
	if (HWGPrinterBoolForKey(HWG_PRINTER_NOTIFY_JOB_KEY, NO)) {
		[self checkPrintJobs];
	} else if (self.jobTrackingBaselineSeeded) {
		// Feature turned off mid-session — drop tracking state so re-enabling later starts
		// a fresh baseline instead of comparing against stale job IDs.
		[self.lastKnownJobStates removeAllObjects];
		self.jobTrackingBaselineSeeded = NO;
	}

	// Toner/ink levels: slower cadence than everything above (see the define's comment) — only
	// actually queries IPP marker-levels every Nth tick, and only while the checkbox is on.
	self.pollTickCount++;
	if (HWGPrinterBoolForKey(HWG_PRINTER_NOTIFY_SUPPLY_KEY, NO)) {
		if (self.pollTickCount % HWG_PRINTER_SUPPLY_POLL_EVERY_N_TICKS == 0) {
			[self checkSupplyLevels];
		}
	} else if (self.lastKnownSupplyLow.count) {
		// Feature turned off mid-session — same reasoning as job tracking above.
		[self.lastKnownSupplyLow removeAllObjects];
	}
}

// #6: polls the CUPS job queue (all local jobs, not just this user's — `cupsGetJobs` with
// `myjobs=0`, matching what `lpq`/`lpstat -o` show) and diffs each job's `ipp_jstate_t`
// against the last poll. Reuses `checkPrinters`'s own 3s timer rather than a separate one.
-(void)checkPrintJobs {
	cups_job_t *jobs = NULL;
	int jobCount = cupsGetJobs(&jobs, NULL, 0, CUPS_WHICHJOBS_ALL);

	NSMutableSet<NSNumber*> *currentJobIDs = [NSMutableSet setWithCapacity:(NSUInteger)MAX(jobCount, 0)];
	for (int i = 0; i < jobCount; i++) {
		cups_job_t *job = &jobs[i];
		NSNumber *jobID = @(job->id);
		[currentJobIDs addObject:jobID];

		ipp_jstate_t state = job->state;
		BOOL isActive   = (state == IPP_JSTATE_PENDING || state == IPP_JSTATE_HELD || state == IPP_JSTATE_PROCESSING);
		BOOL isTerminal = (state == IPP_JSTATE_COMPLETED || state == IPP_JSTATE_CANCELED || state == IPP_JSTATE_ABORTED);
		NSNumber *previousStateNum = self.lastKnownJobStates[jobID];

		NSString *destName = job->dest ? [NSString stringWithUTF8String:job->dest] : NSLocalizedString(@"Unknown printer", @"");
		NSString *jobTitle = (job->title && *job->title) ? [NSString stringWithUTF8String:job->title] : nil;
		NSString *jobUser  = (job->user && *job->user) ? [NSString stringWithUTF8String:job->user] : nil;

		if (!previousStateNum) {
			// New job. Only announce "Started" once baseline-seeded (i.e. not the very first
			// poll after enabling the checkbox, which would otherwise retroactively "start"-
			// notify every job already in flight) AND it's genuinely still active.
			if (self.jobTrackingBaselineSeeded && isActive) {
				// 12-ago-2026: enriched with submitting user + job size (`cups_job_t.size`, in
				// KB per the public header) on their own line — the plain title+printer name
				// this used to show gave no sense of "is this a big job" at a glance.
				NSMutableArray<NSString*> *lines = [NSMutableArray arrayWithObject:jobTitle ?: destName];
				if (jobTitle) [lines addObject:destName];
				NSMutableArray<NSString*> *metaParts = [NSMutableArray array];
				if (jobUser.length) [metaParts addObject:jobUser];
				if (job->size > 0) [metaParts addObject:[NSString stringWithFormat:NSLocalizedString(@"%d KB", @""), job->size]];
				if (metaParts.count) [lines addObject:[metaParts componentsJoinedByString:@" • "]];

				// 12-ago-2026: own dedicated icon (crossed racing flags — one plain green for
				// "start", one checkered for "finish" — designed and approved with the user via
				// mockup before implementing) instead of reusing +printerIconConnected:.
				NSData *iconData = [HWGResolveIconNamed(@"PrinterMonitor-Icon-JobStatus") TIFFRepresentation];
				[delegate notifyWithName:@"PrintJobStarted"
										 title:NSLocalizedString(@"Print Job Started", @"")
								 description:[lines componentsJoinedByString:@"\n"]
										  icon:iconData
						  identifierString:[NSString stringWithFormat:@"HWGrowlPrintJob-%d", job->id]
							  contextString:nil
										plugin:self];
			}
		} else {
			ipp_jstate_t previousState = (ipp_jstate_t)previousStateNum.integerValue;
			BOOL wasActive = (previousState == IPP_JSTATE_PENDING || previousState == IPP_JSTATE_HELD || previousState == IPP_JSTATE_PROCESSING);
			if (isTerminal && wasActive) {
				BOOL succeeded = (state == IPP_JSTATE_COMPLETED);
				NSData *iconData = [HWGResolveIconNamed(@"PrinterMonitor-Icon-JobStatus") TIFFRepresentation];
				NSString *title = succeeded ? NSLocalizedString(@"Print Job Finished", @"")
													  : NSLocalizedString(@"Print Job Canceled", @"");

				// 12-ago-2026: enriched with elapsed processing duration when CUPS reports both
				// endpoints (`processing_time` falls back to `creation_time` for jobs that
				// never actually left the queue — e.g. canceled before printing started).
				NSMutableArray<NSString*> *lines = [NSMutableArray arrayWithObject:jobTitle ?: destName];
				if (jobTitle) [lines addObject:destName];
				time_t start = job->processing_time > 0 ? job->processing_time : job->creation_time;
				if (succeeded && job->completed_time > 0 && start > 0 && job->completed_time >= start) {
					[lines addObject:HWGFormattedDuration((NSTimeInterval)(job->completed_time - start))];
				}
				[delegate notifyWithName:@"PrintJobFinished"
										 title:title
								 description:[lines componentsJoinedByString:@"\n"]
										  icon:iconData
						  identifierString:[NSString stringWithFormat:@"HWGrowlPrintJob-%d", job->id]
							  contextString:nil
										plugin:self];
			}
		}
		self.lastKnownJobStates[jobID] = @(state);
	}

	// A job that vanished entirely between polls (small/fast jobs can complete and age out of
	// CUPS's job list within one 3s tick) is treated the same as an observed active→terminal
	// transition — assume it completed successfully rather than silently dropping the "Started"
	// notification's counterpart.
	NSMutableSet<NSNumber*> *vanishedJobIDs = [NSMutableSet setWithArray:[self.lastKnownJobStates allKeys]];
	[vanishedJobIDs minusSet:currentJobIDs];
	for (NSNumber *jobID in vanishedJobIDs) {
		ipp_jstate_t previousState = (ipp_jstate_t)[self.lastKnownJobStates[jobID] integerValue];
		BOOL wasActive = (previousState == IPP_JSTATE_PENDING || previousState == IPP_JSTATE_HELD || previousState == IPP_JSTATE_PROCESSING);
		if (wasActive && self.jobTrackingBaselineSeeded) {
			NSData *iconData = [HWGResolveIconNamed(@"PrinterMonitor-Icon-JobStatus") TIFFRepresentation];
			[delegate notifyWithName:@"PrintJobFinished"
									 title:NSLocalizedString(@"Print Job Finished", @"")
							 description:NSLocalizedString(@"Job completed", @"")
									  icon:iconData
					  identifierString:[NSString stringWithFormat:@"HWGrowlPrintJob-%@", jobID]
						  contextString:nil
									plugin:self];
		}
		[self.lastKnownJobStates removeObjectForKey:jobID];
	}

	self.jobTrackingBaselineSeeded = YES;
	if (jobs) cupsFreeJobs(jobCount, jobs);
}

// Toner/ink levels (12-ago-2026): re-fetches its own `cups_dest_t` array (rather than reusing
// `HWGCollectPrinterInfo`'s already-freed one) since `HWGCopyMarkerLevelsForDest` needs the raw
// CUPS dest struct to connect to each printer — a second, independent `cupsGetDests()` call,
// acceptable here since this only runs every 10th tick (~30s), not every 3s like the rest of
// this monitor. Fires "Printer Supply Low" once per printer+marker on the healthy→low
// transition; recovering above the (higher) recovery threshold just resets the tracking
// silently so a later dip re-fires, without a matching "supply OK" notification — replacing a
// cartridge is something the user just did and observed directly, unlike PrinterError's
// OK/problem pair which covers a fault the user may not be looking at when it clears.
-(void)checkSupplyLevels {
	cups_dest_t *dests = NULL;
	int count = cupsGetDests(&dests);
	for (int i = 0; i < count; i++) {
		cups_dest_t *dest = &dests[i];
		if (!dest->name) continue;
		NSString *printerName = [NSString stringWithUTF8String:dest->name];

		NSArray<HWGMarkerInfo*> *markers = HWGCopyMarkerLevelsForDest(dest);
		if (!markers) continue;   // offline/unreachable, or doesn't report markers at all

		for (HWGMarkerInfo *marker in markers) {
			if (marker.level < 0) continue;   // IPP "-1" = not reported, per spec — not a real 0%
			NSString *stateKey = [NSString stringWithFormat:@"%@|%@", printerName, marker.name];
			BOOL wasLow = [self.lastKnownSupplyLow[stateKey] boolValue];
			BOOL isLow = marker.level <= HWG_PRINTER_SUPPLY_LOW_THRESHOLD;
			BOOL hasRecovered = marker.level >= HWG_PRINTER_SUPPLY_RECOVER_THRESHOLD;

			if (isLow && !wasLow) {
				// 12-ago-2026: own dedicated icon (ink dropper with a falling drop — the user's
				// own reference image, background-removed and composited onto the printer
				// glyph, approved via mockup before implementing) instead of reusing
				// +printerIconConnected:NO's red-X Disconnected badge.
				NSData *iconData = [HWGResolveIconNamed(@"PrinterMonitor-Icon-SupplyLow") TIFFRepresentation];
				NSString *label = marker.color.length ? [NSString stringWithFormat:@"%@ (%@)", marker.name, marker.color] : marker.name;
				[delegate notifyWithName:@"PrinterSupplyLow"
										 title:NSLocalizedString(@"Printer Supply Low", @"")
								 description:[NSString stringWithFormat:@"%@\n%@: %ld%%", printerName, label, (long)marker.level]
										  icon:iconData
						  identifierString:[NSString stringWithFormat:@"HWGrowlPrinterSupply-%@", stateKey]
							  contextString:nil
										plugin:self];
				self.lastKnownSupplyLow[stateKey] = @YES;
			} else if (hasRecovered && wasLow) {
				self.lastKnownSupplyLow[stateKey] = @NO;
			}
		}
	}
	if (dests) cupsFreeDests(count, dests);
}

#pragma mark Icon

+(NSColor *)accentColor {
	// Teal — not used by any other monitor (Bluetooth/Camera=blue, Network=cyan,
	// Thunderbolt=yellow, Thermal=red, Power=green, Audio=orange, Gamepad=pink).
	return [NSColor systemTealColor];
}

// Flat-color vector icon (23-jul-2026, adapted from a reference image the user provided) —
// unlike the other hand-drawn monitor icons in this codebase (stroke-only, single accent
// color), this one is a filled flat illustration: gray printer body with side "ears" and a
// paper tray sticking up (recolored to the accent teal, replacing the reference's blue), a
// dark control-panel bevel with button dots, and — when `connected` — a printed page
// emerging from the bottom slot with text lines and a small accent-colored swatch, matching
// the reference's composition. Black outlines throughout (as in the reference), which read
// fine on both light and dark sidebar backgrounds.
+(NSImage *)printerIconConnected:(BOOL)connected {
	// This icon is drawn procedurally (no Assets.xcassets entry), so it can't be resolved
	// via HWGResolveIconNamed's [NSImage imageNamed:] fallback — that would return nil for
	// these names. Check the override store directly first instead, drawing the procedural
	// glyph below only when the user hasn't supplied a custom image for this name.
	NSString *defaultName = connected ? @"PrinterMonitor-Icon-Connected" : @"PrinterMonitor-Icon-Disconnected";
	NSImage *override = [[HWGIconOverrideStore sharedStore] overrideImageForDefaultName:defaultName];
	if (override) return override;
	return [self drawnPrinterIconConnected:connected];
}

// The always-default procedural glyph, ignoring any user override — used for the sidebar/
// Modules-list icon (-preferenceIcon), which must stay the app's own fixed artwork and not
// follow the user's "Connected" notification-icon customization (that customization is
// scoped to notifications only; the module list shouldn't visibly change alongside it).
+(NSImage *)drawnPrinterIconConnected:(BOOL)connected {
	NSSize canvasSize = NSMakeSize(128, 128);
	NSImage *image = [NSImage imageWithSize:canvasSize flipped:NO drawingHandler:^BOOL(NSRect rect) {
		// Enlarged 23-jul-2026 per user request — scale the whole drawing up around the
		// canvas center rather than re-deriving every proportion by hand.
		NSAffineTransform *enlarge = [NSAffineTransform transform];
		[enlarge translateXBy:NSMidX(rect) yBy:NSMidY(rect)];
		[enlarge scaleBy:1.22];
		[enlarge translateXBy:-NSMidX(rect) yBy:-NSMidY(rect)];
		[enlarge concat];

		NSColor *accent = [HWGrowlPrinterMonitor accentColor];
		NSColor *outline = [NSColor colorWithWhite:0.08 alpha:1.0];
		NSColor *bodyGray = [NSColor colorWithWhite:0.80 alpha:1.0];
		NSColor *earGray = [NSColor colorWithWhite:0.62 alpha:1.0];
		NSColor *bevelGray = [NSColor colorWithWhite:0.55 alpha:1.0];
		NSColor *slotGray = [NSColor colorWithWhite:0.45 alpha:1.0];
		CGFloat strokeW = rect.size.width * 0.028;

		CGFloat w = rect.size.width, h = rect.size.height;
		CGFloat bodyW = w * 0.66, bodyH = h * 0.34;
		NSRect bodyRect = NSMakeRect(NSMidX(rect) - bodyW / 2.0, h * 0.14, bodyW, bodyH);

		// Side "ears" (paper-tray posts) flanking the top paper slot.
		CGFloat earW = bodyW * 0.14, earH = h * 0.22;
		NSRect leftEar  = NSMakeRect(NSMinX(bodyRect) + bodyW * 0.10, NSMaxY(bodyRect) - h * 0.03, earW, earH);
		NSRect rightEar = NSMakeRect(NSMaxX(bodyRect) - bodyW * 0.10 - earW, NSMaxY(bodyRect) - h * 0.03, earW, earH);
		for (NSValue *v in @[[NSValue valueWithRect:leftEar], [NSValue valueWithRect:rightEar]]) {
			NSRect earRect = v.rectValue;
			NSBezierPath *ear = [NSBezierPath bezierPathWithRoundedRect:earRect xRadius:earW * 0.15 yRadius:earW * 0.15];
			[earGray setFill]; [ear fill];
			ear.lineWidth = strokeW; [outline setStroke]; [ear stroke];
		}

		// Paper tray sticking up between the ears, in the accent color.
		CGFloat trayPaperW = bodyW * 0.42;
		NSRect trayPaperRect = NSMakeRect(NSMidX(rect) - trayPaperW / 2.0, NSMinY(leftEar) + earH * 0.15, trayPaperW, earH * 1.15);
		NSBezierPath *trayPaper = [NSBezierPath bezierPathWithRoundedRect:trayPaperRect xRadius:trayPaperW * 0.06 yRadius:trayPaperW * 0.06];
		[[accent colorWithAlphaComponent:0.35] setFill]; [trayPaper fill];
		trayPaper.lineWidth = strokeW; [outline setStroke]; [trayPaper stroke];

		// Dark bevel strip (control panel) with 3 small button dots, just above the body.
		CGFloat bevelH = h * 0.06;
		NSRect bevelRect = NSMakeRect(NSMinX(bodyRect), NSMaxY(bodyRect) - bevelH * 0.4, bodyW, bevelH);
		NSBezierPath *bevel = [NSBezierPath bezierPathWithRoundedRect:bevelRect xRadius:bevelH * 0.2 yRadius:bevelH * 0.2];
		[bevelGray setFill]; [bevel fill];
		bevel.lineWidth = strokeW; [outline setStroke]; [bevel stroke];

		CGFloat dotD = bevelH * 0.42;
		for (int i = 0; i < 3; i++) {
			CGFloat dotX = NSMinX(bodyRect) + bodyW * (0.16 + i * 0.08);
			NSRect dotRect = NSMakeRect(dotX, NSMidY(bevelRect) - dotD / 2.0, dotD, dotD);
			NSBezierPath *dot = [NSBezierPath bezierPathWithRoundedRect:dotRect xRadius:dotD * 0.25 yRadius:dotD * 0.25];
			[outline setFill]; [dot fill];
		}

		// Printer body (main gray box).
		NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:bodyRect xRadius:bodyW * 0.06 yRadius:bodyW * 0.06];
		[bodyGray setFill]; [body fill];
		body.lineWidth = strokeW * 1.3; [outline setStroke]; [body stroke];

		// Output slot: a dark horizontal bar low on the body, where the page emerges from.
		CGFloat slotW = bodyW * 0.62, slotH = h * 0.045;
		NSRect slotRect = NSMakeRect(NSMidX(rect) - slotW / 2.0, NSMinY(bodyRect) + bodyH * 0.16, slotW, slotH);
		NSBezierPath *slot = [NSBezierPath bezierPathWithRoundedRect:slotRect xRadius:slotH * 0.2 yRadius:slotH * 0.2];
		[slotGray setFill]; [slot fill];
		slot.lineWidth = strokeW; [outline setStroke]; [slot stroke];

		if (connected) {
			// Printed page emerging below the slot: white sheet with text lines + a small
			// accent-colored swatch (bottom-right), matching the reference's composition.
			CGFloat pageW = w * 0.46, pageH = h * 0.30;
			NSRect pageRect = NSMakeRect(NSMidX(rect) - pageW / 2.0, NSMinY(slotRect) - pageH * 0.82, pageW, pageH);
			NSBezierPath *page = [NSBezierPath bezierPathWithRoundedRect:pageRect xRadius:pageW * 0.04 yRadius:pageW * 0.04];
			[[NSColor whiteColor] setFill]; [page fill];
			page.lineWidth = strokeW * 1.2; [outline setStroke]; [page stroke];

			CGFloat lineH = pageH * 0.09;
			CGFloat lineInset = pageW * 0.10;
			for (int i = 0; i < 3; i++) {
				CGFloat lineY = NSMaxY(pageRect) - pageH * 0.22 - i * (lineH + pageH * 0.07);
				CGFloat lineW = (i == 2) ? pageW * 0.42 : pageW * 0.58;
				NSRect lineRect = NSMakeRect(NSMinX(pageRect) + lineInset, lineY, lineW, lineH);
				NSBezierPath *line = [NSBezierPath bezierPathWithRoundedRect:lineRect xRadius:lineH * 0.3 yRadius:lineH * 0.3];
				[outline setFill]; [line fill];
			}

			CGFloat swatchD = pageH * 0.34;
			NSRect swatchRect = NSMakeRect(NSMaxX(pageRect) - lineInset - swatchD, NSMinY(pageRect) + pageH * 0.14, swatchD, swatchD);
			NSBezierPath *swatch = [NSBezierPath bezierPathWithRoundedRect:swatchRect xRadius:swatchD * 0.15 yRadius:swatchD * 0.15];
			[accent setFill]; [swatch fill];
			swatch.lineWidth = strokeW; [outline setStroke]; [swatch stroke];
		}

		return YES;
	}];
	return image;
}

#pragma mark HWGrowlPluginProtocol

-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Printer Monitor", @"");
}
-(NSImage*)preferenceIcon {
	// Resolved fresh every call (not cached) since this is user-customizable — see the same
	// note on AudioMonitor's -preferenceIcon. Own dedicated default name
	// ("PrinterMonitor-ModuleIcon"), separate from the "Connected"/"Needs Attention"
	// notification icons — customizing one must never silently change the other. Falls back
	// to a static render of the procedural connected glyph (Assets.xcassets) rather than
	// redrawing it live, since this icon never needs to reflect live connection state the
	// way the notification icon does.
	NSImage *override = [[HWGIconOverrideStore sharedStore] overrideImageForDefaultName:@"PrinterMonitor-ModuleIcon"];
	return override ?: [NSImage imageNamed:@"PrinterMonitor-ModuleIcon"];
}

-(IBAction)fieldToggleChanged:(NSButton*)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
	[self updateWatcherState];
}

-(NSButton *)checkboxWithKey:(NSString *)key title:(NSString *)title defaultOn:(BOOL)defaultOn {
	NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(fieldToggleChanged:)];
	box.identifier = key;
	box.state = HWGPrinterBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	return box;
}

// Wraps a fixed-height content view in a scroll view sized to fill whatever the tab control
// actually gives it — AppDelegate force-sizes the top-level preferencePane view to the prefs
// window's container (a fixed size, decided once), which can be shorter than a tab's full
// content — same technique already used by Network Monitor's Wi-Fi tab for the same reason.
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

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 560, 340)];
	tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	// 12-ago-2026: switched to HWGFlippedContentView (same class the Icons tab below already
	// uses for its own scroll-view document view) and enlarged to fit the new supply-low
	// checkbox + caption. A plain non-flipped NSView as an NSScrollView's documentView anchors
	// content to the BOTTOM of the viewport when the content is shorter than the visible area
	// (confirmed live: caused a large blank gap above "Notification fields" and clipped the
	// last caption at the bottom) — flipped fixes that, matching Auto Layout's normal top-down
	// expectations. The actual visible height is controlled by -scrollWrapping:height: below.
	NSView *v = [[HWGFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, 560, 620)];

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notification fields", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:header];
	[NSLayoutConstraint activateConstraints:@[
		[header.topAnchor     constraintEqualToAnchor:v.topAnchor constant:16],
		[header.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
	]];

	// Moved to Icons tab (17-ago-2026, feedback del usuario) — this was the one leftover "Notify
	// when X" toggle still in General after the 12-ago-2026 pass below already moved every other
	// one. Investigated first (see TODO.md): NOT redundant with HWG_PRINTER_NOTIFY_CONNECT_KEY —
	// this key is the master gate for -updateWatcherState's poll timer (OFF by default means the
	// timer never even starts unless some other feature enables it), while CONNECT_KEY only
	// toggles whether the "Connected" notification's own text is shown once polling is already
	// happening for any reason. Genuinely distinct events, so kept as its own row per the app's
	// established pattern for that case (see TODO.md's own decision tree).
	NSTextField *caption = [NSTextField wrappingLabelWithString:
		NSLocalizedString(@"Detects USB, Bluetooth, and network (IPP/AirPrint/Bonjour) printers alike, by polling the system's printer list every 3s — there is no instant push notification for this (CUPS's own config file can't be watched directly without root). A network printer is only detected once it has actually been added in System Settings → Printers & Scanners, not merely discoverable on the LAN.", @"")];
	caption.textColor = [NSColor secondaryLabelColor];
	caption.font = [NSFont systemFontOfSize:11];
	caption.translatesAutoresizingMaskIntoConstraints = NO;
	caption.preferredMaxLayoutWidth = 380;
	[v addSubview:caption];
	[NSLayoutConstraint activateConstraints:@[
		[caption.topAnchor     constraintEqualToAnchor:header.bottomAnchor constant:10],
		[caption.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
		[caption.trailingAnchor constraintLessThanOrEqualToAnchor:v.trailingAnchor constant:-16],
	]];

	// #3: extra info lines on "Printer Connected" — each OFF by default (23-jul-2026).
	NSTextField *infoHeader = [NSTextField labelWithString:NSLocalizedString(@"Extra info on connect", @"")];
	infoHeader.font = [NSFont boldSystemFontOfSize:12];
	infoHeader.textColor = [NSColor secondaryLabelColor];
	infoHeader.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:infoHeader];
	[NSLayoutConstraint activateConstraints:@[
		[infoHeader.topAnchor     constraintEqualToAnchor:caption.bottomAnchor constant:18],
		[infoHeader.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
	]];

	NSButton *locationRow  = [self checkboxWithKey:HWG_PRINTER_SHOW_LOCATION_KEY   title:NSLocalizedString(@"Location", @"") defaultOn:NO];
	NSButton *makeModelRow = [self checkboxWithKey:HWG_PRINTER_SHOW_MAKEMODEL_KEY  title:NSLocalizedString(@"Make/model", @"") defaultOn:NO];
	NSButton *connRow      = [self checkboxWithKey:HWG_PRINTER_SHOW_CONNECTION_KEY title:NSLocalizedString(@"Connection type (USB/Network/Bluetooth)", @"") defaultOn:NO];
	// Added 17-ago-2026 — printer-is-shared, same options dict already read.
	NSButton *sharedRow    = [self checkboxWithKey:HWG_PRINTER_SHOW_SHARED_KEY title:NSLocalizedString(@"Sharing status", @"") defaultOn:NO];
	NSView *previous = infoHeader;
	CGFloat gap = 10;
	for (NSButton *r in @[locationRow, makeModelRow, connRow, sharedRow]) {
		[v addSubview:r];
		[NSLayoutConstraint activateConstraints:@[
			[r.topAnchor     constraintEqualToAnchor:previous.bottomAnchor constant:gap],
			[r.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
			[r.heightAnchor   constraintEqualToConstant:24],
		]];
		previous = r;
		gap = 6;
	}

	// 12-ago-2026: the "which events notify, on/off + icon" toggles used to live here as a
	// plain checkbox list ("Additional notifications") — moved to the Icons tab below instead,
	// each as its own row via HWGIconPickerView (label + icon + notify checkbox together),
	// matching how "Connected"/"Needs Attention" already worked. General is for configuring
	// HOW a notification looks/behaves (which fields it shows, thresholds, polling); WHETHER a
	// given event notifies at all — and its icon — belongs with the icon it's paired with.
	[v.bottomAnchor constraintGreaterThanOrEqualToAnchor:previous.bottomAnchor constant:16].active = YES;

	NSTabViewItem *generalItem = [[NSTabViewItem alloc] initWithIdentifier:@"general"];
	generalItem.label = NSLocalizedString(@"General", @"");
	// BUG FIX (17-ago-2026): was 420, a hand-guessed constant not tied to the actual row count —
	// same risk class already confirmed live in Network Monitor's Wi-Fi tab (adding a row here
	// without growing this pushes it past the document view's own bounds, where it renders but
	// doesn't respond to clicks). Bumped with margin after adding the "Sharing status" row.
	generalItem.view = [self scrollWrapping:v height:460];
	[tabs addTabViewItem:generalItem];

	// --- Tab: Icons ---
	CGFloat iconsPad = 16;
	CGFloat iconsWidth = 560 - 2 * iconsPad;
	// 12-ago-2026: "Default Printer Changed" and "Print Job Started/Finished" each got their
	// own dedicated icon (rotating-arrows badge, and crossed start/finish racing flags,
	// respectively — both designed and approved with the user via mockup before implementing),
	// replacing the shared Connected checkmark badge they used to reuse.
	HWGIconPickerView *iconPicker = [[HWGIconPickerView alloc] initWithIconSpecs:@[
		@[@"Module Icon (Sidebar)", @"PrinterMonitor-ModuleIcon"],
		// Master gate for printer add/remove detection itself (starts/stops the poll timer) —
		// distinct from "Connected" below, which only toggles that one notification's own text
		// once detection is already running for any reason (see comment in General tab above).
		@[@"Detect Printer Added/Removed", @"PrinterMonitor-Icon-Connected", HWG_PRINTER_NOTIFY_KEY, @NO],
		@[@"Connected", @"PrinterMonitor-Icon-Connected", HWG_PRINTER_NOTIFY_CONNECT_KEY],
		@[@"Needs Attention", @"PrinterMonitor-Icon-Disconnected", HWG_PRINTER_NOTIFY_ERROR_KEY, @NO],
		@[@"Default Printer Changed", @"PrinterMonitor-Icon-DefaultChanged", HWG_PRINTER_NOTIFY_DEFAULT_KEY, @NO],
		@[@"Print Job Started / Finished", @"PrinterMonitor-Icon-JobStatus", HWG_PRINTER_NOTIFY_JOB_KEY, @NO],
		@[@"Supply Low (Toner/Ink)", @"PrinterMonitor-Icon-SupplyLow", HWG_PRINTER_NOTIFY_SUPPLY_KEY, @NO],
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

	// 12-ago-2026: notes on 2 rows' behavior that don't fit in the picker's fixed label/icon/
	// checkbox row format — kept here rather than dropped when their checkboxes moved from
	// General's old "Additional notifications" list into this tab.
	NSTextField *iconsCaption = [NSTextField wrappingLabelWithString:
		NSLocalizedString(@"\"Needs Attention\" is read from the printer's standard IPP state-reasons — a heuristic (any reason other than \"none\"), not a CUPS-specific guarantee of what's wrong. \"Supply Low\" (10% or below) is checked every ~30s via IPP marker-levels, separately from the other rows above — not all printers/drivers report it.", @"")];
	iconsCaption.textColor = [NSColor secondaryLabelColor];
	iconsCaption.font = [NSFont systemFontOfSize:11];
	iconsCaption.translatesAutoresizingMaskIntoConstraints = YES;
	iconsCaption.preferredMaxLayoutWidth = iconsWidth;
	CGFloat iconsCaptionH = [iconsCaption sizeThatFits:NSMakeSize(iconsWidth, CGFLOAT_MAX)].height;

	NSView *iconsContent = [[HWGFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, 560, iconsHeaderH + iconsGap + iconPickerH + iconsGap + iconsCaptionH + 2 * iconsPad)];
	iconsHeader.frame = NSMakeRect(iconsPad, iconsPad, iconsWidth, iconsHeaderH);
	[iconsContent addSubview:iconsHeader];
	iconPicker.frame = NSMakeRect(iconsPad, iconsPad + iconsHeaderH + iconsGap, iconsWidth, iconPickerH);
	[iconsContent addSubview:iconPicker];
	iconsCaption.frame = NSMakeRect(iconsPad, NSMaxY(iconPicker.frame) + iconsGap, iconsWidth, iconsCaptionH);
	[iconsContent addSubview:iconsCaption];

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
	return [NSArray arrayWithObjects:@"PrinterConnected", @"PrinterDisconnected", @"PrinterError", @"PrinterDefaultChanged", @"PrintJobStarted", @"PrintJobFinished", @"PrinterSupplyLow", nil];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Printer Connected", @""), @"PrinterConnected",
			  NSLocalizedString(@"Printer Disconnected", @""), @"PrinterDisconnected",
			  NSLocalizedString(@"Printer Needs Attention", @""), @"PrinterError",
			  NSLocalizedString(@"Default Printer Changed", @""), @"PrinterDefaultChanged",
			  NSLocalizedString(@"Print Job Started", @""), @"PrintJobStarted",
			  NSLocalizedString(@"Print Job Finished", @""), @"PrintJobFinished",
			  NSLocalizedString(@"Printer Supply Low", @""), @"PrinterSupplyLow", nil];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Sent when a printer is added to the system (F34)", @""), @"PrinterConnected",
			  NSLocalizedString(@"Sent when a printer is removed from the system (F34)", @""), @"PrinterDisconnected",
			  NSLocalizedString(@"Sent when a printer's state indicates a problem (out of paper/toner, jammed, offline…), and when it clears", @""), @"PrinterError",
			  NSLocalizedString(@"Sent when the system's default printer changes", @""), @"PrinterDefaultChanged",
			  NSLocalizedString(@"Sent when a print job starts processing", @""), @"PrintJobStarted",
			  NSLocalizedString(@"Sent when a print job completes or is canceled", @""), @"PrintJobFinished",
			  NSLocalizedString(@"Sent when a printer's toner/ink level drops to 10% or below", @""), @"PrinterSupplyLow", nil];
}
-(NSArray*)defaultNotifications {
	return [NSArray array];
}

@end
