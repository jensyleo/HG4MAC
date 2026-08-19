//
//  HWGrowlThermalMonitor.m
//  HardwareGrowler
//

// compile with ARC: -fobjc-arc
#import "HWGrowlThermalMonitor.h"
#import "HWGIconOverrideStore.h"
#import "HWGIconPickerView.h"
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/pwr_mgt/IOPM.h>
#import <IOKit/IOMessage.h>
#import <notify.h>

// F34 candidate #3: per-level configurable thermal-state notifications. Each key gates
// whether ENTERING that level (in either direction) fires a notification. All levels are
// tracked internally regardless of these toggles, so turning one on later doesn't miss the
// next real transition. Serious/Critical default ON (actionable); Nominal/Fair default OFF
// (avoid noise on "back to normal").
#define HWG_THERMAL_NOTIFY_NOMINAL_KEY  @"HWGThermalNotifyNominal"
#define HWG_THERMAL_NOTIFY_FAIR_KEY     @"HWGThermalNotifyFair"
#define HWG_THERMAL_NOTIFY_SERIOUS_KEY  @"HWGThermalNotifySerious"
#define HWG_THERMAL_NOTIFY_CRITICAL_KEY @"HWGThermalNotifyCritical"
#define HWG_THERMAL_SHOW_LOWPOWER_KEY   @"HWGThermalShowLowPowerCorrelation"

// Final API audit (18-ago-2026) — kIOPMMessageDarkWakeThermalEmergency, delivered to any
// IOServiceAddInterestNotification observer on the IOPMrootDomain service (public,
// IOKit/pwr_mgt/IOPMLib.h + IOMessage.h). Distinct from the NSProcessInfo.thermalState levels
// above: this fires specifically when the Mac overheats DURING a brief dark wake (network/
// maintenance wake while the lid is closed or display is off), a scenario the thermalState
// polling wouldn't necessarily catch since the Mac may go straight back to sleep afterward.
// ON by default — rare and always actionable when it happens.
#define HWG_THERMAL_NOTIFY_DARKWAKE_EMERGENCY_KEY @"HWGThermalNotifyDarkWakeEmergency"

// Final API audit (18-ago-2026) — IOPMGetThermalWarningLevel() and IOPMCopyCPUPowerStatus()
// (both IOKit/pwr_mgt/IOPMLib.h, public). CONFIRMED LIVE on this M4 (Apple Silicon): both
// return kIOReturnNotFound — Apple Silicon simply never publishes these two values. They are
// real on Intel Macs, which this app still targets (ARCHS = arm64 x86_64) — so this is not
// dead code, just silent no-ops here. Each has a documented BSD notify(3) push key
// (kIOPMThermalWarningNotificationKey / kIOPMCPUPowerNotificationKey in IOPMLib.h) instead of
// requiring a poll timer. Both OFF by default: unlike Dark Wake Emergency (rare, unambiguous),
// these can be noisy under sustained load on the Intel Macs where they DO fire, and this app's
// own performance-tuning pass this session already prioritized fewer background timers/events
// over completeness by default.
#define HWG_THERMAL_NOTIFY_CPU_THROTTLE_KEY @"HWGThermalNotifyCPUThrottle"
#define HWG_THERMAL_NOTIFY_WARNING_LEVEL_KEY @"HWGThermalNotifyWarningLevel"

static BOOL HWGThermalBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

@interface HWGrowlThermalMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, assign) NSProcessInfoThermalState lastReportedThermalState;
@property (nonatomic, strong) NSView *prefsView;
// "Simulate Test Notification" popups — see -simulateThermalTransitionForTesting:.
@property (nonatomic, strong) NSPopUpButton *simulateFromPopup;
@property (nonatomic, strong) NSPopUpButton *simulateToPopup;
@property (nonatomic, assign) IONotificationPortRef rootDomainNotifyPort;
@property (nonatomic, assign) io_object_t rootDomainNotifier;
@property (nonatomic, assign) int cpuPowerNotifyToken;
@property (nonatomic, assign) int thermalWarningNotifyToken;
@property (nonatomic, assign) uint32_t lastReportedThermalWarningLevel;
@property (nonatomic, assign) BOOL lastReportedCPUThrottled;
@property (nonatomic, assign) BOOL hasCPUThrottleBaseline;

-(void)darkWakeThermalEmergencyFired;
-(void)cpuPowerStatusNotifyFired;
-(void)thermalWarningLevelNotifyFired;

@end

// C callback required by IOServiceAddInterestNotification's function-pointer signature (not
// a selector/block) — refcon carries the plugin instance across the bridge. Only messageType
// kIOPMMessageDarkWakeThermalEmergency is handled; every other IOPMrootDomain interest message
// (sleep/wake/etc.) is already covered by Power Monitor's NSWorkspace-based observing, so
// those are ignored here rather than duplicated.
static void HWGThermalRootDomainCallback(void *refcon, io_service_t service, uint32_t messageType, void *messageArgument) {
	if (messageType != kIOPMMessageDarkWakeThermalEmergency) return;
	HWGrowlThermalMonitor *monitor = (__bridge HWGrowlThermalMonitor *)refcon;
	[monitor darkWakeThermalEmergencyFired];
}

@implementation HWGrowlThermalMonitor

@synthesize delegate;
@synthesize lastReportedThermalState;
@synthesize prefsView;
@synthesize lastReportedThermalWarningLevel;
@synthesize lastReportedCPUThrottled;
@synthesize hasCPUThrottleBaseline;

-(id)init {
	self = [super init];
	if (self) {
		// Baseline silently at launch — like WiFi/USB/Bluetooth — so the first real
		// transition after this point is the first thing ever notified.
		lastReportedThermalState = [NSProcessInfo processInfo].thermalState;
		[[NSNotificationCenter defaultCenter] addObserver:self
												  selector:@selector(thermalStateChanged:)
													  name:NSProcessInfoThermalStateDidChangeNotification
													object:nil];

		// Final API audit (18-ago-2026) — kIOPMMessageDarkWakeThermalEmergency via
		// IOServiceAddInterestNotification on IOPMrootDomain. Public API (IOPMLib.h/IOMessage.h),
		// no entitlement required (confirmed: this target has no CODE_SIGN_ENTITLEMENTS).
		io_service_t rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
		if (rootDomain) {
			self.rootDomainNotifyPort = IONotificationPortCreate(kIOMainPortDefault);
			CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(self.rootDomainNotifyPort), kCFRunLoopDefaultMode);
			IOServiceAddInterestNotification(self.rootDomainNotifyPort, rootDomain, kIOGeneralInterest,
											  HWGThermalRootDomainCallback, (__bridge void *)self, &_rootDomainNotifier);
			IOObjectRelease(rootDomain);
		}

		// Final API audit (18-ago-2026) — push registration via BSD notify(3), no poll timer.
		// Baseline silently first (matches the WiFi/USB/Bluetooth/thermalState convention) so
		// only a REAL subsequent change notifies, not the registration-time initial read.
		lastReportedThermalWarningLevel = kIOPMThermalLevelUnknown;
		lastReportedCPUThrottled = NO;
		[self thermalWarningLevelNotifyFired];
		[self cpuPowerStatusNotifyFired];

		__weak HWGrowlThermalMonitor *weakSelf = self;
		notify_register_dispatch(kIOPMThermalWarningNotificationKey, &_thermalWarningNotifyToken,
								  dispatch_get_main_queue(), ^(int token) {
			[weakSelf thermalWarningLevelNotifyFired];
		});
		notify_register_dispatch(kIOPMCPUPowerNotificationKey, &_cpuPowerNotifyToken,
								  dispatch_get_main_queue(), ^(int token) {
			[weakSelf cpuPowerStatusNotifyFired];
		});
	}
	return self;
}

-(void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	if (_rootDomainNotifier) IOObjectRelease(_rootDomainNotifier);
	if (_rootDomainNotifyPort) IONotificationPortDestroy(_rootDomainNotifyPort);
	if (_thermalWarningNotifyToken) notify_cancel(_thermalWarningNotifyToken);
	if (_cpuPowerNotifyToken) notify_cancel(_cpuPowerNotifyToken);
}

// Silent no-op on Apple Silicon (IOPMGetThermalWarningLevel returns kIOReturnNotFound, confirmed
// live) — real on Intel Macs. kIOPMThermalWarningLevelNormal/Danger/Crisis are the documented
// 3 levels (aliases of kIOPMThermalLevelNormal/Warning/Critical in IOPM.h).
-(void)thermalWarningLevelNotifyFired {
	uint32_t level = kIOPMThermalLevelUnknown;
	if (IOPMGetThermalWarningLevel(&level) != kIOReturnSuccess) return;
	if (level == lastReportedThermalWarningLevel) return;
	BOOL hadBaseline = (lastReportedThermalWarningLevel != kIOPMThermalLevelUnknown);
	self.lastReportedThermalWarningLevel = level;
	if (!hadBaseline) return;
	if (!HWGThermalBoolForKey(HWG_THERMAL_NOTIFY_WARNING_LEVEL_KEY, NO)) return;

	NSString *levelName;
	switch (level) {
		case kIOPMThermalWarningLevelNormal: levelName = NSLocalizedString(@"Normal", @""); break;
		case kIOPMThermalWarningLevelDanger: levelName = NSLocalizedString(@"Danger", @""); break;
		case kIOPMThermalWarningLevelCrisis: levelName = NSLocalizedString(@"Crisis", @""); break;
		default: levelName = NSLocalizedString(@"Unknown", @""); break;
	}
	[delegate notifyWithName:@"ThermalWarningLevelChanged"
						 title:NSLocalizedString(@"Hardware Thermal Warning Level Changed", @"")
				   description:[NSString stringWithFormat:NSLocalizedString(@"Level: %@", @""), levelName]
						  icon:HWGResolveIconDataNamed(@"Thermal-WarningLevel")
			  identifierString:@"HWGrowlThermalWarningLevel"
				 contextString:nil
						plugin:self];
}

// Silent no-op on Apple Silicon (IOPMCopyCPUPowerStatus returns kIOReturnNotFound, confirmed
// live) — real on Intel Macs under sustained thermal/power duress.
-(void)cpuPowerStatusNotifyFired {
	CFDictionaryRef status = NULL;
	if (IOPMCopyCPUPowerStatus(&status) != kIOReturnSuccess || !status) return;
	NSDictionary *dict = CFBridgingRelease(status);

	NSNumber *speedLimit = dict[@kIOPMCPUPowerLimitProcessorSpeedKey];
	NSNumber *cpuLimit = dict[@kIOPMCPUPowerLimitProcessorCountKey];
	BOOL throttled = (speedLimit && speedLimit.integerValue < 100) || (cpuLimit && cpuLimit.integerValue < 100);
	BOOL hadBaseline = hasCPUThrottleBaseline;
	self.hasCPUThrottleBaseline = YES;
	if (throttled == lastReportedCPUThrottled) return;
	self.lastReportedCPUThrottled = throttled;
	if (!hadBaseline) return; // first read ever: record silently, don't notify on launch
	if (!throttled) return;   // only notify on entering throttled state, not on recovery
	if (!HWGThermalBoolForKey(HWG_THERMAL_NOTIFY_CPU_THROTTLE_KEY, NO)) return;

	NSMutableArray<NSString*> *parts = [NSMutableArray array];
	if (speedLimit) [parts addObject:[NSString stringWithFormat:NSLocalizedString(@"CPU speed limited to %@%%", @""), speedLimit]];
	if (cpuLimit) [parts addObject:[NSString stringWithFormat:NSLocalizedString(@"%@%% of cores available", @""), cpuLimit]];
	NSString *description = parts.count ? [parts componentsJoinedByString:@"\n"] : NSLocalizedString(@"CPU power/speed is being limited by the hardware", @"");

	[delegate notifyWithName:@"CPUPowerLimited"
						 title:NSLocalizedString(@"CPU Power Limited", @"")
				   description:description
						  icon:HWGResolveIconDataNamed(@"Thermal-CPUThrottled")
			  identifierString:@"HWGrowlCPUPowerLimited"
				 contextString:nil
						plugin:self];
}

-(void)darkWakeThermalEmergencyFired {
	if (!HWGThermalBoolForKey(HWG_THERMAL_NOTIFY_DARKWAKE_EMERGENCY_KEY, YES)) return;
	[delegate notifyWithName:@"DarkWakeThermalEmergency"
						 title:NSLocalizedString(@"Dark Wake Thermal Emergency", @"")
				   description:NSLocalizedString(@"The Mac overheated during a brief maintenance wake and may sleep again immediately to cool down.", @"")
						  icon:HWGResolveIconDataNamed(@"Thermal-DarkWakeEmergency")
			  identifierString:@"HWGrowlDarkWakeThermalEmergency"
				 contextString:nil
						plugin:self];
}

// Description phrase ONLY (no level name prefix) — the level name is shown separately via
// -thermalStateShortLabel: in the "old → new" arrow, so this shouldn't repeat it (that used to
// read as "Critical → Nominal (Nominal — running normally)" — the duplicated "Nominal" was
// confusing noise).
-(NSString *)thermalStateLabel:(NSProcessInfoThermalState)state {
	switch (state) {
		case NSProcessInfoThermalStateNominal:  return NSLocalizedString(@"running normally", @"");
		case NSProcessInfoThermalStateFair:      return NSLocalizedString(@"slightly elevated", @"");
		case NSProcessInfoThermalStateSerious:   return NSLocalizedString(@"performance reduced", @"");
		case NSProcessInfoThermalStateCritical:  return NSLocalizedString(@"performance significantly reduced", @"");
		default: return NSLocalizedString(@"unknown", @"");
	}
}

// Short word only (Nominal/Fair/Serious/Critical), used for the "old → new" arrow line —
// the long descriptive phrase from -thermalStateLabel: (e.g. "performance significantly
// reduced") describes what that severity level MEANS, which only makes sense attached to the
// CURRENT/new state; showing it for the OLD state too reads as if the old explanation still
// applies after the transition (e.g. "Critical — performance significantly reduced →
// Nominal" makes it look like performance is STILL reduced, right before the arrow says
// otherwise).
-(NSString *)thermalStateShortLabel:(NSProcessInfoThermalState)state {
	switch (state) {
		case NSProcessInfoThermalStateNominal:  return NSLocalizedString(@"Nominal", @"");
		case NSProcessInfoThermalStateFair:      return NSLocalizedString(@"Fair", @"");
		case NSProcessInfoThermalStateSerious:   return NSLocalizedString(@"Serious", @"");
		case NSProcessInfoThermalStateCritical:  return NSLocalizedString(@"Critical", @"");
		default: return NSLocalizedString(@"Unknown", @"");
	}
}

-(NSString *)userDefaultsKeyForThermalState:(NSProcessInfoThermalState)state {
	switch (state) {
		case NSProcessInfoThermalStateNominal:  return HWG_THERMAL_NOTIFY_NOMINAL_KEY;
		case NSProcessInfoThermalStateFair:      return HWG_THERMAL_NOTIFY_FAIR_KEY;
		case NSProcessInfoThermalStateSerious:   return HWG_THERMAL_NOTIFY_SERIOUS_KEY;
		case NSProcessInfoThermalStateCritical:  return HWG_THERMAL_NOTIFY_CRITICAL_KEY;
		default: return nil;
	}
}

-(BOOL)defaultNotifyForThermalState:(NSProcessInfoThermalState)state {
	return (state == NSProcessInfoThermalStateSerious || state == NSProcessInfoThermalStateCritical);
}

// Dedicated icon per level: a thermometer with a fill level proportional to severity
// (Nominal ~18% .. Critical 100%, matching Power Monitor's charge-level ramp convention),
// plus a badge in the top-right corner that escalates in meaning: Nominal = green
// checkmark ("all good"), Fair = blue dash ("steady, still normal"), Serious = the same
// warning triangle used for "Unstable device" bounce alerts, Critical = the same
// radioactive icon used for "Disk Not Readable".
-(NSData *)iconDataForThermalState:(NSProcessInfoThermalState)state {
	NSString *name;
	switch (state) {
		case NSProcessInfoThermalStateNominal:  name = @"Thermal-Nominal";  break;
		case NSProcessInfoThermalStateFair:      name = @"Thermal-Fair";     break;
		case NSProcessInfoThermalStateSerious:   name = @"Thermal-Serious";  break;
		case NSProcessInfoThermalStateCritical:  name = @"Thermal-Critical"; break;
		default: return nil;
	}
	return HWGResolveIconDataNamed(name);
}

-(void)thermalStateChanged:(NSNotification *)note {
	NSProcessInfoThermalState state = [NSProcessInfo processInfo].thermalState;
	if (state == lastReportedThermalState) return;
	NSProcessInfoThermalState previousState = lastReportedThermalState;
	self.lastReportedThermalState = state;

	NSString *key = [self userDefaultsKeyForThermalState:state];
	BOOL shouldNotify = key ? HWGThermalBoolForKey(key, [self defaultNotifyForThermalState:state]) : NO;
	if (!shouldNotify) return;

	// "old → new" plus an explicit improving/worsening tag — see
	// -descriptionForThermalTransitionFrom:to:.
	NSString *description = [self descriptionForThermalTransitionFrom:previousState to:state];

	// Added 17-ago-2026 (feedback del usuario) — NSProcessInfo.isLowPowerModeEnabled, public,
	// same class already used for thermalState above. Correlation only ("coincides in time"),
	// not causal — Low Power Mode can also be toggled manually or triggered by low battery,
	// independent of thermal pressure. OFF by default.
	if (HWGThermalBoolForKey(HWG_THERMAL_SHOW_LOWPOWER_KEY, NO) && [NSProcessInfo processInfo].isLowPowerModeEnabled) {
		description = [description stringByAppendingFormat:@"\n%@", NSLocalizedString(@"(Low Power Mode is also currently on)", @"")];
	}

	[delegate notifyWithName:@"ThermalStateChanged"
						 title:NSLocalizedString(@"Thermal State Changed", @"")
				   description:description
						  icon:[self iconDataForThermalState:state]
			  identifierString:@"HWGrowlThermalState"
				 contextString:nil
						plugin:self];
}

// Builds the "State:\told → new" line PLUS an explicit "(Cooling down)"/"(Warming up)" tag.
// Uses SHORT labels (just the word) for the "old → new" arrow, and appends the full
// descriptive phrase (from -thermalStateLabel:) only for the NEW state — that phrase explains
// what the severity level MEANS, which only makes sense for the state you're actually in now;
// attaching it to the OLD state too would make e.g. "Critical — performance significantly
// reduced → Nominal" read as if performance were STILL reduced, right before the arrow says
// otherwise. No improving/worsening tag for a same-level from==to (shouldn't happen via the
// real observer, but the simulate-testing path allows selecting equal states).
-(NSString *)descriptionForThermalTransitionFrom:(NSProcessInfoThermalState)fromState to:(NSProcessInfoThermalState)toState {
	NSString *line = [NSString stringWithFormat:NSLocalizedString(@"State:\t%@ → %@ — %@", @""),
		[self thermalStateShortLabel:fromState], [self thermalStateShortLabel:toState], [self thermalStateLabel:toState]];
	if (toState < fromState) {
		return [line stringByAppendingFormat:@"\n%@", NSLocalizedString(@"↓ Cooling down (improving)", @"")];
	} else if (toState > fromState) {
		return [line stringByAppendingFormat:@"\n%@", NSLocalizedString(@"↑ Warming up (worsening)", @"")];
	}
	return line;
}

// "Simulate Test Notification" (Preferences > Thermal Monitor): lets a user preview any
// from→to state combination on demand, without waiting for the Mac to actually throttle —
// genuinely useful on machines that rarely (or never, under light/moderate load — confirmed
// via `pmset -g therm` and NSProcessInfo.thermalState on an M4 under sustained CPU stress)
// reach Serious/Critical, so the notification/icon for those levels can still be seen and
// verified without forcing real thermal stress. Does NOT touch lastReportedThermalState, so
// it can't desync the real tracking from the actual OS-reported state, and does NOT check the
// per-level F33 checkbox (simulating is opt-in by definition — always fires so every
// combination, including ones disabled by default like Nominal/Fair, can still be previewed).
-(IBAction)simulateThermalTransitionForTesting:(NSButton*)sender {
	NSProcessInfoThermalState fromState = (NSProcessInfoThermalState)[self.simulateFromPopup indexOfSelectedItem];
	NSProcessInfoThermalState toState   = (NSProcessInfoThermalState)[self.simulateToPopup indexOfSelectedItem];
	NSString *description = [self descriptionForThermalTransitionFrom:fromState to:toState];
	[delegate notifyWithName:@"ThermalStateChanged"
						 title:NSLocalizedString(@"Thermal State Changed", @"")
					   description:description
						  icon:[self iconDataForThermalState:toState]
			  identifierString:@"HWGrowlThermalState"
				 contextString:nil
						plugin:self];
}

#pragma mark HWGrowlPluginProtocol

-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Thermal Monitor", @"");
}
-(NSImage*)preferenceIcon {
	// Resolved fresh every call (not cached) since this is user-customizable via the Icons
	// tab's "Module Icon (Sidebar)" row — see the same note on AudioMonitor's -preferenceIcon.
	return HWGResolveIconNamed(@"HWGPrefsThermal-Module");
}

-(IBAction)fieldToggleChanged:(NSButton*)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
}

-(NSButton *)checkboxWithKey:(NSString *)key title:(NSString *)title defaultOn:(BOOL)defaultOn {
	NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(fieldToggleChanged:)];
	box.identifier = key;
	box.state = HWGThermalBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	return box;
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	// BUG FIX (17-ago-2026): was 300 — same fixed-constant risk class confirmed live in Network
	// Monitor's Wi-Fi tab. Bumped with margin after adding 1 row (Low Power Mode correlation).
	NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 560, 560)];
	tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 560)];

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notify when entering:", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;

	NSArray<NSButton*> *rows = @[
		[self checkboxWithKey:HWG_THERMAL_NOTIFY_NOMINAL_KEY  title:NSLocalizedString(@"Nominal (back to normal)", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_THERMAL_NOTIFY_FAIR_KEY     title:NSLocalizedString(@"Fair (slightly elevated)", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_THERMAL_NOTIFY_SERIOUS_KEY  title:NSLocalizedString(@"Serious (throttling active)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_THERMAL_NOTIFY_CRITICAL_KEY title:NSLocalizedString(@"Critical (severe throttling)", @"") defaultOn:YES],
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

	// Added 17-ago-2026 (feedback del usuario) — NSProcessInfo.isLowPowerModeEnabled
	// correlation, public API, OFF by default.
	NSButton *lowPowerRow = [self checkboxWithKey:HWG_THERMAL_SHOW_LOWPOWER_KEY title:NSLocalizedString(@"Note if Low Power Mode is also on", @"") defaultOn:NO];
	[v addSubview:lowPowerRow];
	[NSLayoutConstraint activateConstraints:@[
		[lowPowerRow.topAnchor     constraintEqualToAnchor:previous.bottomAnchor constant:14],
		[lowPowerRow.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
		[lowPowerRow.heightAnchor   constraintEqualToConstant:24],
	]];
	previous = lowPowerRow;

	// "Simulate Test Notification" controls — see -simulateThermalTransitionForTesting:. Two
	// popups (From/To) instead of a single fixed button so EVERY 4×4 state combination can be
	// previewed (including same-level no-ops and "skip a level" jumps like Nominal→Critical),
	// not just one hardcoded transition — useful for any user who wants to see what a given
	// notification/icon looks like without waiting for (or being able to force) real thermal
	// throttling.
	NSArray<NSString *> *stateNames = @[
		NSLocalizedString(@"Nominal", @""), NSLocalizedString(@"Fair", @""),
		NSLocalizedString(@"Serious", @""), NSLocalizedString(@"Critical", @"")];

	NSTextField *simHeader = [NSTextField labelWithString:NSLocalizedString(@"Simulate Test Notification", @"")];
	simHeader.font = [NSFont boldSystemFontOfSize:12];
	simHeader.textColor = [NSColor secondaryLabelColor];
	simHeader.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:simHeader];
	[NSLayoutConstraint activateConstraints:@[
		[simHeader.topAnchor     constraintEqualToAnchor:previous.bottomAnchor constant:16],
		[simHeader.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
	]];

	NSTextField *fromLabel = [NSTextField labelWithString:NSLocalizedString(@"From:", @"")];
	fromLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:fromLabel];
	[NSLayoutConstraint activateConstraints:@[
		[fromLabel.topAnchor     constraintEqualToAnchor:simHeader.bottomAnchor constant:10],
		[fromLabel.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
	]];

	self.simulateFromPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(16 + 44, 0, 100, 24) pullsDown:NO];
	self.simulateFromPopup.translatesAutoresizingMaskIntoConstraints = NO;
	[self.simulateFromPopup addItemsWithTitles:stateNames];
	[self.simulateFromPopup selectItemAtIndex:NSProcessInfoThermalStateNominal];
	[v addSubview:self.simulateFromPopup];
	[NSLayoutConstraint activateConstraints:@[
		[self.simulateFromPopup.centerYAnchor constraintEqualToAnchor:fromLabel.centerYAnchor],
		[self.simulateFromPopup.leadingAnchor  constraintEqualToAnchor:fromLabel.trailingAnchor constant:8],
	]];

	NSTextField *toLabel = [NSTextField labelWithString:NSLocalizedString(@"To:", @"")];
	toLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:toLabel];
	[NSLayoutConstraint activateConstraints:@[
		[toLabel.centerYAnchor constraintEqualToAnchor:fromLabel.centerYAnchor],
		[toLabel.leadingAnchor  constraintEqualToAnchor:self.simulateFromPopup.trailingAnchor constant:16],
	]];

	self.simulateToPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 100, 24) pullsDown:NO];
	self.simulateToPopup.translatesAutoresizingMaskIntoConstraints = NO;
	[self.simulateToPopup addItemsWithTitles:stateNames];
	[self.simulateToPopup selectItemAtIndex:NSProcessInfoThermalStateSerious];
	[v addSubview:self.simulateToPopup];
	[NSLayoutConstraint activateConstraints:@[
		[self.simulateToPopup.centerYAnchor constraintEqualToAnchor:fromLabel.centerYAnchor],
		[self.simulateToPopup.leadingAnchor  constraintEqualToAnchor:toLabel.trailingAnchor constant:8],
	]];

	NSButton *testButton = [NSButton buttonWithTitle:NSLocalizedString(@"Simulate", @"")
	                                            target:self action:@selector(simulateThermalTransitionForTesting:)];
	testButton.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:testButton];
	[NSLayoutConstraint activateConstraints:@[
		[testButton.topAnchor     constraintEqualToAnchor:fromLabel.bottomAnchor constant:12],
		[testButton.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
	]];

	NSTabViewItem *generalItem = [[NSTabViewItem alloc] initWithIdentifier:@"general"];
	generalItem.label = NSLocalizedString(@"General", @"");
	generalItem.view = v;
	[tabs addTabViewItem:generalItem];

	// --- Tab: Icons ---
	CGFloat iconsPad = 16;
	CGFloat iconsWidth = 560 - 2 * iconsPad;
	HWGIconPickerView *iconPicker = [[HWGIconPickerView alloc] initWithIconSpecs:@[
		@[@"Module Icon (Sidebar)", @"HWGPrefsThermal-Module"],
		@[@"Nominal", @"Thermal-Nominal", HWG_THERMAL_NOTIFY_NOMINAL_KEY, @NO],
		@[@"Fair", @"Thermal-Fair", HWG_THERMAL_NOTIFY_FAIR_KEY, @NO],
		@[@"Serious", @"Thermal-Serious", HWG_THERMAL_NOTIFY_SERIOUS_KEY, @YES],
		@[@"Critical", @"Thermal-Critical", HWG_THERMAL_NOTIFY_CRITICAL_KEY, @YES],
		@[@"Dark Wake Thermal Emergency", @"Thermal-DarkWakeEmergency", HWG_THERMAL_NOTIFY_DARKWAKE_EMERGENCY_KEY, @YES],
		@[@"CPU Power Limited (Intel only)", @"Thermal-CPUThrottled", HWG_THERMAL_NOTIFY_CPU_THROTTLE_KEY, @NO],
		@[@"Hardware Thermal Warning Level (Intel only)", @"Thermal-WarningLevel", HWG_THERMAL_NOTIFY_WARNING_LEVEL_KEY, @NO],
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

	NSView *iconsContent = [[HWGFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, 560, iconsHeaderH + iconsGap + iconPickerH + 2 * iconsPad)];
	iconsHeader.frame = NSMakeRect(iconsPad, iconsPad, iconsWidth, iconsHeaderH);
	[iconsContent addSubview:iconsHeader];
	iconPicker.frame = NSMakeRect(iconsPad, iconsPad + iconsHeaderH + iconsGap, iconsWidth, iconPickerH);
	[iconsContent addSubview:iconPicker];

	NSScrollView *iconsScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 560, 460)];
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
	return @[@"ThermalStateChanged", @"DarkWakeThermalEmergency", @"ThermalWarningLevelChanged", @"CPUPowerLimited"];
}
-(NSDictionary*)localizedNames {
	return @{
		@"ThermalStateChanged": NSLocalizedString(@"Thermal State Changed", @""),
		@"DarkWakeThermalEmergency": NSLocalizedString(@"Dark Wake Thermal Emergency", @""),
		@"ThermalWarningLevelChanged": NSLocalizedString(@"Hardware Thermal Warning Level Changed", @""),
		@"CPUPowerLimited": NSLocalizedString(@"CPU Power Limited", @""),
	};
}
-(NSDictionary*)noteDescriptions {
	return @{
		@"ThermalStateChanged": NSLocalizedString(@"Sent when the Mac's thermal state changes (throttling level)", @""),
		@"DarkWakeThermalEmergency": NSLocalizedString(@"Sent when the Mac overheats during a brief maintenance wake", @""),
		@"ThermalWarningLevelChanged": NSLocalizedString(@"Sent when the hardware thermal warning level changes (Intel Macs only)", @""),
		@"CPUPowerLimited": NSLocalizedString(@"Sent when the CPU's speed or core count is being limited by the hardware (Intel Macs only)", @""),
	};
}
-(NSArray*)defaultNotifications {
	return @[@"ThermalStateChanged", @"DarkWakeThermalEmergency"];
}

@end
