//
//  HWGrowlPluginController.m
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/2/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

// compile with ARC: -fobjc-arc
#import "HWGrowlPluginController.h"
#import "HWGNotificationHistoryStore.h"

//DO NOT TOUCH, FOR KEEPING LOCALIZATION SCRIPT SIMPLER
#define GrowlOffSwitchFake NSLocalizedString(@"OFF", @"If the string is too long, use O");
#define GrowlOnSwitchFake NSLocalizedString(@"ON", @"If the string is too long, use I");

@interface HWGrowlPluginController ()

@property (nonatomic, strong) NSMutableArray *notifiers;
@property (nonatomic, strong) NSMutableArray *monitors;

@end

@implementation HWGrowlPluginController

@synthesize plugins;
@synthesize notifiers;
@synthesize monitors;

// ARC: no manual dealloc needed (plugins/notifiers/monitors are strong).

-(id)init {
	if((self = [super init])){
		self.plugins = [NSMutableArray array];
		self.notifiers = [NSMutableArray array];
		self.monitors = [NSMutableArray array];
		[self loadPlugins];
		
		[GrowlApplicationBridge setGrowlDelegate:self];
		[GrowlApplicationBridge setShouldUseBuiltInNotifications:YES];

		// BUG FIX (10-ago-2026): fireOnLaunchNotes (announces WiFi/IP already-connected
		// state, among others) used to run AFTER postRegistrationInit. BluetoothMonitor's
		// own postRegistrationInit (IOBluetoothDevice registerForConnectNotifications:) has
		// been observed to abort the whole process on this macOS version — see TODO.md — and
		// since that happened first in the old order, the process never reached
		// fireOnLaunchNotes at all, so Network Monitor's IP/WiFi launch announcements never
		// fired. Fire the launch announcements FIRST so they're not at the mercy of whatever
		// postRegistrationInit does later.
		if([self onLaunchEnabled])
			[self fireOnLaunchNotes];

		[self postRegistrationInit];
	}
	return self;
}

-(void)loadPlugins {
	NSString *pluginsPath = [[NSBundle mainBundle] builtInPlugInsPath];
	NSArray *pluginBundles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:pluginsPath
																										  error:nil];
	if(pluginBundles) {
		NSDictionary *disabledPlugins = [[NSUserDefaults standardUserDefaults] objectForKey:@"DisabledPlugins"];
		
		__block HWGrowlPluginController *blockSelf = self;
		[pluginBundles enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
			NSString *bundlePath = [pluginsPath stringByAppendingPathComponent:obj];
			NSBundle *pluginBundle = [NSBundle bundleWithPath:bundlePath];
			
			if(pluginBundle && [pluginBundle load])
			{
				NSString *bundleID = [pluginBundle bundleIdentifier];
				id plugin = [[[pluginBundle principalClass] alloc] init];
				if(plugin)
				{ 
					if([plugin conformsToProtocol:@protocol(HWGrowlPluginProtocol)])
					{
						[plugin setDelegate:self];
						BOOL disabled = NO;
						if(disabledPlugins && [disabledPlugins objectForKey:bundleID])
							disabled = [[disabledPlugins objectForKey:bundleID] boolValue];
						else if([plugin respondsToSelector:@selector(enabledByDefault)])
							disabled = ![plugin enabledByDefault];
						
						NSMutableDictionary *pluginDict = [NSMutableDictionary dictionaryWithObjectsAndKeys:plugin, @"plugin", 
																	  [NSNumber numberWithBool:disabled], @"disabled", nil];
						[blockSelf.plugins addObject:pluginDict];
						
						if([plugin conformsToProtocol:@protocol(HWGrowlPluginNotifierProtocol)])
							[blockSelf.notifiers addObject:plugin];
						if([plugin conformsToProtocol:@protocol(HWGrowlPluginMonitorProtocol)])
							[blockSelf.monitors addObject:plugin];
					}else{
						NSLog(@"%@ does not conform to HWGrowlPluginProtocol", NSStringFromClass([pluginBundle principalClass]));
					}
					// ARC balances the +1 from alloc/init; arrays hold their own strong refs.
				}else{
					NSLog(@"We couldn't instantiate %@ for plugin %@", NSStringFromClass([pluginBundle principalClass]), bundleID);
				}
			}else{
				NSLog(@"%@ is not a bundle or could not be loaded", bundlePath);
			}
		}];
	}
	[plugins sortUsingComparator:^NSComparisonResult(id obj1, id obj2) {
		return [[[obj1 objectForKey:@"plugin"] pluginDisplayName] compare:[[obj2 objectForKey:@"plugin"] pluginDisplayName]];
	}];
}
			
// PERFORMANCE FIX (17-ago-2026, feedback del usuario: "la app se siente lenta al iniciar") —
// this used to run all 13 plugins' postRegistrationInit back-to-back, synchronously, on the
// main thread, DURING -init (i.e. before the app has even returned from launching) — unlike
// -fireOnLaunchNotes below, which already got the same "don't block on this" treatment on
// 11-ago-2026. Some plugins' postRegistrationInit does real synchronous work here: USB/
// Thunderbolt Monitor prime their IOKit matching notifications by walking every currently
// attached device (when "notify on launch" is enabled), and Bluetooth Monitor registers with
// IOBluetoothDevice (a daemon round-trip). With 13 plugins doing this one after another with
// zero yield to the run loop, the app's menu bar icon/UI doesn't become responsive until the
// slowest one finishes.
//
// Fix: same micro-stagger pattern as -fireOnLaunchNotes — dispatch_after on the MAIN queue
// (not a background queue: IOKit notification port setup expects to attach to the calling
// thread's run loop, so moving this off-main risks silently broken notification delivery).
// This doesn't make any individual plugin's setup faster, but it lets the current run loop
// tick (which shows the app's UI) finish immediately instead of waiting for all 13 in a row.
-(void)postRegistrationInit {
	static const NSTimeInterval kPerModuleStagger = 0.15;
	[plugins enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		id plugin = [obj objectForKey:@"plugin"];
		if([plugin respondsToSelector:@selector(postRegistrationInit)]) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((NSTimeInterval)idx * kPerModuleStagger * NSEC_PER_SEC)),
			               dispatch_get_main_queue(), ^{
				[plugin postRegistrationInit];
			});
		}
	}];
}

-(void)fireOnLaunchNotes {
	// BUG FIX (11-ago-2026): every module's -fireOnLaunchNotes used to run back-to-back in the
	// very same synchronous pass, so one module's own family of related notifications (e.g.
	// Network Monitor's Ethernet -> WiFi -> IP, which already fire in that order internally)
	// landed interleaved with a completely unrelated module's burst arriving in the same
	// instant (e.g. Volume Monitor mounting 7 volumes) — even with the launch-flood banner
	// queue fix (see GrowlApplicationBridge.m) guaranteeing nothing is lost off-screen anymore,
	// the two families still visually interleaved on screen, reading as scattered noise rather
	// than "here's what your network did" as one grouped unit. Staggering each module's own
	// -fireOnLaunchNotes call by a small fixed offset (based on its position in this list) gives
	// each module's whole family a clear head start before the next module's burst begins,
	// without touching any module's own internal sequencing.
	static const NSTimeInterval kPerModuleStagger = 0.6;
	[notifiers enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		if([obj respondsToSelector:@selector(fireOnLaunchNotes)]) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((NSTimeInterval)idx * kPerModuleStagger * NSEC_PER_SEC)),
			               dispatch_get_main_queue(), ^{
				[obj fireOnLaunchNotes];
			});
		}
	}];
}

-(void)notifyWithName:(NSString*)name 
					 title:(NSString*)title
			 description:(NSString*)description
					  icon:(NSData*)iconData
	  identifierString:(NSString*)identifier
		  contextString:(NSString*)context
					plugin:(id)plugin
{
	__block BOOL disabled = NO;
	[plugins enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		if([obj objectForKey:@"plugin"] == plugin)
		{
			disabled = [[obj objectForKey:@"disabled"] boolValue];
			*stop = YES;
		}
	}];
	if(disabled)
		return;

	// Duplicate suppression (also covers the cold-boot double, where
	// fireOnLaunchNotes and a real connect event report the same thing).
	// Skip if an identical notification (same name + identifier + description)
	// was already shown within the cooldown window.
	//
	// BUG FIX (05-ago-2026): Camera/Audio Monitor's in-use "-started"/"-stopped"
	// identifiers are real, already-debounced state transitions computed upstream —
	// never accidental repeats like the cold-boot double this cache exists for. During
	// fast toggling (on/off/on within under 3s) the SAME identifier+description recurs
	// (e.g. "started" fires again), so this cache was silently eating every other
	// transition — the exact "stopped appearing until the last one clears" symptom
	// reported after the identifier fix. Exempt these from dedup; bounce detection
	// below already handles genuine flapping.
	BOOL isStateTransition = [identifier hasSuffix:@"-started"] || [identifier hasSuffix:@"-stopped"];
	if (!isStateTransition) {
		static NSMutableDictionary *recentNotes = nil;
		static dispatch_once_t onceToken;
		dispatch_once(&onceToken, ^{ recentNotes = [[NSMutableDictionary alloc] init]; });
		const NSTimeInterval cooldown = 3.0;
		@synchronized(recentNotes) {
			NSString *key = [NSString stringWithFormat:@"%@|%@|%@",
			                 name ?: @"", identifier ?: @"", description ?: @""];
			NSDate *now  = [NSDate date];
			// Purge expired entries so this dict can't grow unbounded over a long
			// uptime (entries older than the cooldown are dead weight anyway).
			NSMutableArray *stale = [NSMutableArray array];
			[recentNotes enumerateKeysAndObjectsUsingBlock:^(id k, NSDate *v, BOOL *stop){
				if ([now timeIntervalSinceDate:v] >= cooldown) [stale addObject:k];
			}];
			[recentNotes removeObjectsForKeys:stale];
			NSDate *last = [recentNotes objectForKey:key];
			if (last && [now timeIntervalSinceDate:last] < cooldown) {
				return; // duplicate within window — skip
			}
			[recentNotes setObject:now forKey:key];
		}
	}

	// Bounce detection: if the same device (identifier) produces many events in
	// a short window, surface ONE extra "unstable device" alert. The individual
	// connect/disconnect notifications are still shown — this only adds a heads-up.
	//
	// BUG FIX (05-ago-2026): Camera/Audio Monitor's "in use"/"idle" notifications now append
	// "-started"/"-stopped" to their identifierString (see those files' own fix, same date) so
	// UNUserNotificationCenter treats each transition as its own banner instead of silently
	// replacing the still-visible previous one. That fix accidentally split THIS bounce
	// counter too — "-started" and "-stopped" events used to share one identifier and count
	// toward the same total, but now accrue separately, so a camera flapping on/off/on/off
	// needed 4 of the SAME direction to trip the threshold instead of 4 toggles total.
	// Stripping that suffix here (bounce-grouping only — the actual notification identifier
	// above is untouched) restores counting both directions together, matching the user's
	// request to have rapid in-use toggling surface the same "device is unstable" heads-up
	// other flapping hardware already gets.
	NSString *bounceIdentifier = identifier;
	if ([bounceIdentifier hasSuffix:@"-started"]) {
		bounceIdentifier = [bounceIdentifier substringToIndex:bounceIdentifier.length - @"-started".length];
	} else if ([bounceIdentifier hasSuffix:@"-stopped"]) {
		bounceIdentifier = [bounceIdentifier substringToIndex:bounceIdentifier.length - @"-stopped".length];
	}
	if (bounceIdentifier && [bounceIdentifier length]) {
		static NSMutableDictionary *bounceTimes = nil;    // identifier -> NSMutableArray<NSDate>
		static NSMutableDictionary *bounceAlerted = nil;  // identifier -> NSDate (last alert)
		static dispatch_once_t bounceOnce;
		dispatch_once(&bounceOnce, ^{
			bounceTimes   = [[NSMutableDictionary alloc] init];
			bounceAlerted = [[NSMutableDictionary alloc] init];
		});
		const NSTimeInterval bounceWindow = 20.0;
		const NSUInteger     bounceThreshold = 4;

		BOOL shouldAlert = NO;
		NSUInteger eventCount = 0;
		@synchronized(bounceTimes) {
			NSDate *now = [NSDate date];
			// Purge identifiers with no activity within the window so bounceTimes /
			// bounceAlerted can't grow unbounded across many unique devices.
			NSMutableArray *staleIds = [NSMutableArray array];
			[bounceTimes enumerateKeysAndObjectsUsingBlock:^(id k, NSArray *times, BOOL *stop){
				NSDate *newest = [times lastObject];
				if (!newest || [now timeIntervalSinceDate:newest] >= bounceWindow) [staleIds addObject:k];
			}];
			[bounceTimes removeObjectsForKeys:staleIds];
			[bounceAlerted removeObjectsForKeys:staleIds];
			NSMutableArray *kept = [NSMutableArray array];
			for (NSDate *t in (NSArray *)[bounceTimes objectForKey:bounceIdentifier]) {
				if ([now timeIntervalSinceDate:t] < bounceWindow) [kept addObject:t];
			}
			[kept addObject:now];
			[bounceTimes setObject:kept forKey:bounceIdentifier];
			eventCount = [kept count];

			if (eventCount >= bounceThreshold) {
				NSDate *lastAlert = [bounceAlerted objectForKey:bounceIdentifier];
				if (!lastAlert || [now timeIntervalSinceDate:lastAlert] >= bounceWindow) {
					shouldAlert = YES;
					[bounceAlerted setObject:now forKey:bounceIdentifier];
				}
			}
		}

		if (shouldAlert) {
			// Friendly device label. Internal identifiers carry the "HWGrowl"
			// prefix (e.g. "HWGrowlAirPort" -> "AirPort"); real device names
			// (USB/Volume/Bluetooth) are used as-is. A few internal ones get a
			// nicer mapping so they don't read like code.
			NSDictionary *labelMap = @{
				@"HWGrowlNetworkLink":     @"Ethernet",
				@"HWGrowlIPAddressChange": @"Network",
				@"HWGrowlAirPort":         @"Wi-Fi",
				@"HWGrowlAirPortSignal":   @"Wi-Fi Signal",
				@"PowerChange":            @"Power",
				@"PowerWarning":           @"Power",
			};
			NSString *deviceLabel = bounceIdentifier;
			if ([labelMap objectForKey:bounceIdentifier]) {
				deviceLabel = [labelMap objectForKey:bounceIdentifier];
			} else if ([bounceIdentifier hasPrefix:@"HWGrowl"]) {
				deviceLabel = [bounceIdentifier substringFromIndex:[@"HWGrowl" length]];
			}
			NSString *desc = [NSString stringWithFormat:
				NSLocalizedString(@"%@ is unstable\nPlease check the device", @""),
				deviceLabel];
			NSData *unstableIcon = [[NSImage imageNamed:@"Device-Unstable"] TIFFRepresentation];
			[GrowlApplicationBridge notifyWithTitle:NSLocalizedString(@"Unstable device", @"")
										description:desc
								   notificationName:@"DeviceUnstable"
										   iconData:unstableIcon
										   priority:1
										   isSticky:NO
									   clickContext:nil
										 identifier:[@"HWGBounce-" stringByAppendingString:bounceIdentifier]];
		}
	}

	NSString *contextCombined = nil;
	if(context && [context rangeOfString:@" : "].location != NSNotFound) {
		NSLog(@"found \" : \" in context string %@", context);
	}
	if(context && plugin && [context rangeOfString:@" : "].location == NSNotFound) {
		contextCombined = [NSString stringWithFormat:@"%@ : %@", NSStringFromClass([plugin class]), context];
	}

	// F37: optional notification history — off by default, and per-module even when the
	// master switch is on. Recorded here (not earlier) so history only ever reflects
	// notifications that actually made it past the disabled-plugin/dedup checks above —
	// the same set the user actually sees.
	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"HWGHistoryEnabled"]) {
		NSString *bundleID = [[NSBundle bundleForClass:[plugin class]] bundleIdentifier];
		NSDictionary *historyModules = [[NSUserDefaults standardUserDefaults] objectForKey:@"HWGHistoryEnabledModules"];
		if (bundleID && [[historyModules objectForKey:bundleID] boolValue]) {
			NSString *displayName = [plugin respondsToSelector:@selector(pluginDisplayName)]
				? [plugin pluginDisplayName] : bundleID;
			[[HWGNotificationHistoryStore sharedStore] addEntryWithModuleBundleID:bundleID
															   moduleDisplayName:displayName
																			title:title
																			 body:description];
		}
	}

    [GrowlApplicationBridge	notifyWithTitle:title
										 description:description
								  notificationName:name 
											 iconData:iconData
											 priority:0
											 isSticky:NO
										clickContext:contextCombined
										  identifier:identifier];
}

-(BOOL)onLaunchEnabled {
	return [[NSUserDefaults standardUserDefaults] boolForKey:@"ShowExisting"];
}

-(BOOL)pluginDisabled:(id)plugin {
	__block BOOL disabled = NO;
	[plugins enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		if([obj objectForKey:@"plugin"] == plugin) 
		{
			disabled = [[obj objectForKey:@"disabled"] boolValue];
			*stop = YES;
		}
	}];
	return disabled;
}

-(void)growlNotificationClosed:(id)clickContext viaClick:(BOOL)click {
	NSArray *components = [clickContext componentsSeparatedByString:@" : "];
	if([components count] < 2)
		return;
	NSString *classString = [components objectAtIndex:0];
	NSString *context = [components objectAtIndex:1];
	
	[notifiers enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		if([obj isKindOfClass:NSClassFromString(classString)]){
			if([obj respondsToSelector:@selector(noteClosed:byClick:)])
				[obj noteClosed:context byClick:click];
			*stop = YES;
		}
	}];
}

#pragma mark GrowlApplicationBridgeDelegate methods

- (NSDictionary*)registrationDictionaryForGrowl {
	NSMutableArray *allNotes = [NSMutableArray array];
	NSMutableArray *defaultNotes = [NSMutableArray array];
	NSMutableDictionary *descriptions = [NSMutableDictionary dictionary];
	NSMutableDictionary *localizedNames = [NSMutableDictionary dictionary];
	
	[notifiers enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		id<HWGrowlPluginNotifierProtocol> notifier = obj;
		[allNotes addObjectsFromArray:[notifier noteNames]];
		if([notifier defaultNotifications])
			[defaultNotes addObjectsFromArray:[notifier defaultNotifications]];
		[descriptions addEntriesFromDictionary:[notifier noteDescriptions]];
		[localizedNames addEntriesFromDictionary:[notifier localizedNames]];
	}];
	
	NSDictionary *regDict = [NSDictionary dictionaryWithObjectsAndKeys:allNotes, GROWL_NOTIFICATIONS_ALL,
									 defaultNotes, GROWL_NOTIFICATIONS_DEFAULT,
									 descriptions, GROWL_NOTIFICATIONS_DESCRIPTIONS,
									 localizedNames, GROWL_NOTIFICATIONS_HUMAN_READABLE_NAMES, nil];
	return regDict;
}

- (NSString *) applicationNameForGrowl {
	return @"HG4MAC";
}

-(void)growlNotificationTimedOut:(id)clickContext {
	[self growlNotificationClosed:clickContext viaClick:NO];
}

-(void)growlNotificationWasClicked:(id)clickContext {
	[self growlNotificationClosed:clickContext viaClick:YES];
}

@end
