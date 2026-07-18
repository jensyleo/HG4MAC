//
//  HWGrowlThermalMonitor.m
//  HardwareGrowler
//

// compile with ARC: -fobjc-arc
#import "HWGrowlThermalMonitor.h"

// F34 candidate #3: per-level configurable thermal-state notifications. Each key gates
// whether ENTERING that level (in either direction) fires a notification. All levels are
// tracked internally regardless of these toggles, so turning one on later doesn't miss the
// next real transition. Serious/Critical default ON (actionable); Nominal/Fair default OFF
// (avoid noise on "back to normal").
#define HWG_THERMAL_NOTIFY_NOMINAL_KEY  @"HWGThermalNotifyNominal"
#define HWG_THERMAL_NOTIFY_FAIR_KEY     @"HWGThermalNotifyFair"
#define HWG_THERMAL_NOTIFY_SERIOUS_KEY  @"HWGThermalNotifySerious"
#define HWG_THERMAL_NOTIFY_CRITICAL_KEY @"HWGThermalNotifyCritical"

static BOOL HWGThermalBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

@interface HWGrowlThermalMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, assign) NSProcessInfoThermalState lastReportedThermalState;
@property (nonatomic, strong) NSView *prefsView;

@end

@implementation HWGrowlThermalMonitor

@synthesize delegate;
@synthesize lastReportedThermalState;
@synthesize prefsView;

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
	}
	return self;
}

-(void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

-(NSString *)thermalStateLabel:(NSProcessInfoThermalState)state {
	switch (state) {
		case NSProcessInfoThermalStateNominal:  return NSLocalizedString(@"Nominal — running normally", @"");
		case NSProcessInfoThermalStateFair:      return NSLocalizedString(@"Fair — slightly elevated", @"");
		case NSProcessInfoThermalStateSerious:   return NSLocalizedString(@"Serious — performance reduced", @"");
		case NSProcessInfoThermalStateCritical:  return NSLocalizedString(@"Critical — performance significantly reduced", @"");
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
	return [[NSImage imageNamed:name] TIFFRepresentation];
}

-(void)thermalStateChanged:(NSNotification *)note {
	NSProcessInfoThermalState state = [NSProcessInfo processInfo].thermalState;
	if (state == lastReportedThermalState) return;
	self.lastReportedThermalState = state;

	NSString *key = [self userDefaultsKeyForThermalState:state];
	BOOL shouldNotify = key ? HWGThermalBoolForKey(key, [self defaultNotifyForThermalState:state]) : NO;
	if (!shouldNotify) return;

	[delegate notifyWithName:@"ThermalStateChanged"
						 title:NSLocalizedString(@"Thermal State Changed", @"")
				   description:[self thermalStateLabel:state]
						  icon:[self iconDataForThermalState:state]
			  identifierString:@"HWGrowlThermalState"
				 contextString:nil
						plugin:self];
}

#pragma mark HWGrowlPluginProtocol

-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Thermal Monitor", @"");
}
-(NSImage*)preferenceIcon {
	return [NSImage imageNamed:@"HWGPrefsThermal"];
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

	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, 190)];

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

	prefsView = v;
	return prefsView;
}

#pragma mark HWGrowlPluginNotifierProtocol

-(NSArray*)noteNames {
	return [NSArray arrayWithObject:@"ThermalStateChanged"];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObject:NSLocalizedString(@"Thermal State Changed", @"") forKey:@"ThermalStateChanged"];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObject:NSLocalizedString(@"Sent when the Mac's thermal state changes (throttling level)", @"") forKey:@"ThermalStateChanged"];
}
-(NSArray*)defaultNotifications {
	return [NSArray arrayWithObject:@"ThermalStateChanged"];
}

@end
