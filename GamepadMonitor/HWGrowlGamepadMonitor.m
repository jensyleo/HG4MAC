//
//  HWGrowlGamepadMonitor.m
//  HardwareGrowler
//

// compile with ARC: -fobjc-arc
#import "HWGrowlGamepadMonitor.h"
#import <GameController/GameController.h>
#import <GameController/GCKeyboard.h>
#import <GameController/GCMouse.h>
#import <GameController/GCRacingWheel.h>
#import <GameController/GCXboxGamepad.h>
#import "HWGIconOverrideStore.h"
#import "HWGIconPickerView.h"

// F19: unlike Audio/Camera Monitor, GameController framework exposes no transport type for a
// GCController, so there's no reliable way to suppress the (very common) case where the same
// physical connect is ALSO reported by USB/Bluetooth Monitor. Deliberately NOT suppressed —
// confirmed with the user (19-jul-2026) as the right call, same reasoning already accepted
// for Audio Monitor's default-device-change axis: the generic "USB/Bluetooth Device
// Connected: <name>" notification doesn't know it's specifically a recognized GAME
// CONTROLLER, its vendor/product category (DualSense/Xbox/MFi/etc.), player index, or
// battery — genuinely new information even when the underlying connect event is the same one
// another monitor already announced.

#define HWG_GAMEPAD_SHOW_CATEGORY_KEY    @"HWGGamepadShowCategory"
#define HWG_GAMEPAD_SHOW_PLAYER_INDEX_KEY @"HWGGamepadShowPlayerIndex"
#define HWG_GAMEPAD_SHOW_BATTERY_KEY     @"HWGGamepadShowBattery"
#define HWG_GAMEPAD_SHOW_TRIGGERS_KEY    @"HWGGamepadShowAdaptiveTriggers"
#define HWG_GAMEPAD_SHOW_BATTERY_STATE_KEY @"HWGGamepadShowBatteryState"
#define HWG_GAMEPAD_SHOW_TOUCHPAD_KEY    @"HWGGamepadShowTouchpad"
#define HWG_GAMEPAD_SHOW_HAPTICS_KEY     @"HWGGamepadShowHaptics"
#define HWG_GAMEPAD_SHOW_MOTION_KEY      @"HWGGamepadShowMotion"
#define HWG_GAMEPAD_SHOW_LIGHTBAR_KEY    @"HWGGamepadShowLightbarColor"
#define HWG_GAMEPAD_SHOW_PADDLES_KEY     @"HWGGamepadShowXboxElitePaddles"
#define HWG_GAMEPAD_NOTIFY_KEY           @"HWGGamepadNotifyConnect"
// Final API audit (18-ago-2026) — GCKeyboard/GCMouse/GCRacingWheel are separate device classes
// exposed by GameController.framework, distinct from GCController (game controllers). Their
// connect notifications carry a GCKeyboard/GCMouse/GCRacingWheel object, not a GCController, so
// they get their own notify keys/handlers rather than reusing HWG_GAMEPAD_NOTIFY_KEY.
#define HWG_GAMEPAD_NOTIFY_KEYBOARD_KEY  @"HWGGamepadNotifyKeyboard"
#define HWG_GAMEPAD_NOTIFY_MOUSE_KEY     @"HWGGamepadNotifyMouse"
#define HWG_GAMEPAD_NOTIFY_RACING_WHEEL_KEY @"HWGGamepadNotifyRacingWheel"

static BOOL HWGGamepadBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

@interface HWGrowlGamepadMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, strong) NSView *prefsView;

@end

@implementation HWGrowlGamepadMonitor

@synthesize delegate;
@synthesize prefsView;

-(id)init {
	self = [super init];
	if (self) {
		[[NSNotificationCenter defaultCenter] addObserver:self
												  selector:@selector(controllerConnected:)
													  name:GCControllerDidConnectNotification
													object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self
												  selector:@selector(controllerDisconnected:)
													  name:GCControllerDidDisconnectNotification
													object:nil];
		// Final API audit (18-ago-2026) — GCKeyboard/GCMouse/GCRacingWheel connect/disconnect,
		// same NSNotificationCenter pattern already used for GCController above. These are
		// "Made for Game Controllers"-recognized keyboards/mice/racing wheels, not a report on
		// every physical keyboard/mouse macOS knows about.
		[[NSNotificationCenter defaultCenter] addObserver:self
												  selector:@selector(keyboardConnected:)
													  name:GCKeyboardDidConnectNotification
													object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self
												  selector:@selector(keyboardDisconnected:)
													  name:GCKeyboardDidDisconnectNotification
													object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self
												  selector:@selector(mouseConnected:)
													  name:GCMouseDidConnectNotification
													object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self
												  selector:@selector(mouseDisconnected:)
													  name:GCMouseDidDisconnectNotification
													object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self
												  selector:@selector(racingWheelConnected:)
													  name:GCRacingWheelDidConnectNotification
													object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self
												  selector:@selector(racingWheelDisconnected:)
													  name:GCRacingWheelDidDisconnectNotification
													object:nil];

		// Without this, GCControllerDidConnectNotification never fires for a controller that
		// connects AFTER launch — confirmed live (22-jul-2026): connecting a controller only
		// produced USB/Bluetooth Monitor's generic notification, never "Game Controller
		// Connected". GCController requires the app to actively ask the system to search for
		// wireless controllers; without ever calling this, GameController framework doesn't
		// route connect events to a background/menu-bar-only app like this one at all (not
		// just for Bluetooth — this turned out to matter even for the wired controller
		// tested). nil completion handler: this runs for the plugin's whole lifetime, there's
		// no single "discovery finished" moment to act on.
		[GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
	}
	return self;
}

-(void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[GCController stopWirelessControllerDiscovery];
}

#pragma mark Connect/disconnect

-(NSString *)playerIndexLabel:(GCControllerPlayerIndex)index {
	switch (index) {
		case GCControllerPlayerIndex1: return @"1";
		case GCControllerPlayerIndex2: return @"2";
		case GCControllerPlayerIndex3: return @"3";
		case GCControllerPlayerIndex4: return @"4";
		default: return nil;
	}
}

-(NSString *)extraInfoForController:(GCController *)controller {
	NSMutableArray<NSString *> *lines = [NSMutableArray array];

	if (HWGGamepadBoolForKey(HWG_GAMEPAD_SHOW_CATEGORY_KEY, YES) && controller.productCategory.length) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Type:\t%@", @""), controller.productCategory]];
	}
	if (HWGGamepadBoolForKey(HWG_GAMEPAD_SHOW_PLAYER_INDEX_KEY, YES)) {
		NSString *playerLabel = [self playerIndexLabel:controller.playerIndex];
		if (playerLabel) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Player:\t%@", @""), playerLabel]];
	}
	if (HWGGamepadBoolForKey(HWG_GAMEPAD_SHOW_BATTERY_KEY, YES) && controller.battery) {
		float level = controller.battery.batteryLevel;
		if (level >= 0) {
			[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Battery:\t%.0f%%", @""), level * 100.0]];
		}
	}
	// Added 17-ago-2026 (feedback del usuario) — GCDeviceBattery.batteryState, same class
	// already used for batteryLevel above. Public, stable since iOS 14/macOS 11.
	if (HWGGamepadBoolForKey(HWG_GAMEPAD_SHOW_BATTERY_STATE_KEY, NO) && controller.battery) {
		NSString *stateLabel = nil;
		switch (controller.battery.batteryState) {
			case GCDeviceBatteryStateCharging:    stateLabel = NSLocalizedString(@"Charging", @""); break;
			case GCDeviceBatteryStateFull:        stateLabel = NSLocalizedString(@"Full", @""); break;
			case GCDeviceBatteryStateDischarging: stateLabel = NSLocalizedString(@"Discharging", @""); break;
			default:                              stateLabel = NSLocalizedString(@"Unknown", @""); break;
		}
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Battery State:\t%@", @""), stateLabel]];
	}
	if (HWGGamepadBoolForKey(HWG_GAMEPAD_SHOW_TRIGGERS_KEY, YES)) {
		// Only detects the CLASS (DualSense-family gamepad) — doesn't configure/use the
		// triggers themselves, this is a monitor, not a controller.
		if ([controller.extendedGamepad isKindOfClass:NSClassFromString(@"GCDualSenseGamepad")]) {
			[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Adaptive Triggers:\t%@", @""), NSLocalizedString(@"Yes", @"")]];
		}
	}
	// Added 17-ago-2026 — GCDualSenseGamepad/GCDualShockGamepad touchpad presence, same
	// class-check pattern already used for adaptive triggers above.
	if (HWGGamepadBoolForKey(HWG_GAMEPAD_SHOW_TOUCHPAD_KEY, NO)) {
		BOOL hasTouchpad = [controller.extendedGamepad isKindOfClass:NSClassFromString(@"GCDualSenseGamepad")] ||
			[controller.extendedGamepad isKindOfClass:NSClassFromString(@"GCDualShockGamepad")];
		if (hasTouchpad) {
			[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Touchpad:\t%@", @""), NSLocalizedString(@"Yes", @"")]];
		}
	}
	// Added 17-ago-2026 — GCController.haptics (GCDeviceHaptics), public, presence-only check
	// (doesn't create a CHHapticEngine or trigger any actual vibration).
	if (HWGGamepadBoolForKey(HWG_GAMEPAD_SHOW_HAPTICS_KEY, NO)) {
		if (controller.haptics) {
			[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Haptics:\t%@", @""), NSLocalizedString(@"Supported", @"")]];
		}
	}
	// Added 17-ago-2026 — GCController.motion (GCMotion), public, presence-only (doesn't
	// activate sensors).
	if (HWGGamepadBoolForKey(HWG_GAMEPAD_SHOW_MOTION_KEY, NO)) {
		if (controller.motion) {
			[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Motion Sensors:\t%@", @""), NSLocalizedString(@"Yes", @"")]];
		}
	}
	// Final API audit (18-ago-2026) — GCController.light.color, read-only informational field.
	// The app never writes to .light.color: this monitor reports hardware state, it doesn't
	// control it (same "no hardware control" boundary already applied to adaptive triggers/
	// haptics/motion above).
	if (HWGGamepadBoolForKey(HWG_GAMEPAD_SHOW_LIGHTBAR_KEY, NO) && controller.light) {
		GCColor *color = controller.light.color;
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Lightbar Color:\tR%.0f G%.0f B%.0f", @""),
						   color.red * 255.0, color.green * 255.0, color.blue * 255.0]];
	}
	// Final API audit (18-ago-2026) — GCXboxGamepad.paddleButton1-4 presence, same class-check
	// presence-only pattern already used for adaptive triggers/touchpad above.
	if (HWGGamepadBoolForKey(HWG_GAMEPAD_SHOW_PADDLES_KEY, NO)) {
		if ([controller.extendedGamepad isKindOfClass:NSClassFromString(@"GCXboxGamepad")]) {
			GCXboxGamepad *xbox = (GCXboxGamepad *)controller.extendedGamepad;
			if (xbox.paddleButton1 || xbox.paddleButton2 || xbox.paddleButton3 || xbox.paddleButton4) {
				[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Elite Paddles:\t%@", @""), NSLocalizedString(@"Yes", @"")]];
			}
		}
	}

	return [lines count] ? [lines componentsJoinedByString:@"\n"] : nil;
}

-(void)controllerConnected:(NSNotification *)note {
	if (!HWGGamepadBoolForKey(HWG_GAMEPAD_NOTIFY_KEY, YES)) return;

	GCController *controller = note.object;
	NSString *name = controller.vendorName ?: NSLocalizedString(@"Game Controller", @"");
	NSString *extraInfo = [self extraInfoForController:controller];
	NSString *description = extraInfo ? [NSString stringWithFormat:@"%@\n%@", name, extraInfo] : name;

	[delegate notifyWithName:@"GamepadConnected"
						 title:NSLocalizedString(@"Game Controller Connected", @"")
					   description:description
						  icon:[self iconData]
			  identifierString:[NSString stringWithFormat:@"HWGrowlGamepad-%p", controller]
				 contextString:nil
						plugin:self];
}

-(void)controllerDisconnected:(NSNotification *)note {
	if (!HWGGamepadBoolForKey(HWG_GAMEPAD_NOTIFY_KEY, YES)) return;

	GCController *controller = note.object;
	NSString *name = controller.vendorName ?: NSLocalizedString(@"Game Controller", @"");

	[delegate notifyWithName:@"GamepadDisconnected"
						 title:NSLocalizedString(@"Game Controller Disconnected", @"")
					   description:name
						  icon:[self iconData]
			  identifierString:[NSString stringWithFormat:@"HWGrowlGamepad-%p", controller]
				 contextString:nil
						plugin:self];
}

#pragma mark Keyboard/Mouse/Racing Wheel (final API audit, 18-ago-2026)

-(void)keyboardConnected:(NSNotification *)note {
	if (!HWGGamepadBoolForKey(HWG_GAMEPAD_NOTIFY_KEYBOARD_KEY, NO)) return;
	GCKeyboard *keyboard = note.object;
	[delegate notifyWithName:@"GamepadKeyboardConnected"
						 title:NSLocalizedString(@"Game-Recognized Keyboard Connected", @"")
					   description:NSLocalizedString(@"A keyboard is now available to GameController-based games/apps", @"")
						  icon:[self iconData]
			  identifierString:[NSString stringWithFormat:@"HWGrowlGamepadKeyboard-%p", keyboard]
				 contextString:nil
						plugin:self];
}

-(void)keyboardDisconnected:(NSNotification *)note {
	if (!HWGGamepadBoolForKey(HWG_GAMEPAD_NOTIFY_KEYBOARD_KEY, NO)) return;
	GCKeyboard *keyboard = note.object;
	[delegate notifyWithName:@"GamepadKeyboardDisconnected"
						 title:NSLocalizedString(@"Game-Recognized Keyboard Disconnected", @"")
					   description:@""
						  icon:[self iconData]
			  identifierString:[NSString stringWithFormat:@"HWGrowlGamepadKeyboard-%p", keyboard]
				 contextString:nil
						plugin:self];
}

-(void)mouseConnected:(NSNotification *)note {
	if (!HWGGamepadBoolForKey(HWG_GAMEPAD_NOTIFY_MOUSE_KEY, NO)) return;
	GCMouse *mouse = note.object;
	[delegate notifyWithName:@"GamepadMouseConnected"
						 title:NSLocalizedString(@"Game-Recognized Mouse Connected", @"")
					   description:NSLocalizedString(@"A mouse is now available to GameController-based games/apps", @"")
						  icon:[self iconData]
			  identifierString:[NSString stringWithFormat:@"HWGrowlGamepadMouse-%p", mouse]
				 contextString:nil
						plugin:self];
}

-(void)mouseDisconnected:(NSNotification *)note {
	if (!HWGGamepadBoolForKey(HWG_GAMEPAD_NOTIFY_MOUSE_KEY, NO)) return;
	GCMouse *mouse = note.object;
	[delegate notifyWithName:@"GamepadMouseDisconnected"
						 title:NSLocalizedString(@"Game-Recognized Mouse Disconnected", @"")
					   description:@""
						  icon:[self iconData]
			  identifierString:[NSString stringWithFormat:@"HWGrowlGamepadMouse-%p", mouse]
				 contextString:nil
						plugin:self];
}

-(void)racingWheelConnected:(NSNotification *)note {
	if (!HWGGamepadBoolForKey(HWG_GAMEPAD_NOTIFY_RACING_WHEEL_KEY, YES)) return;
	GCRacingWheel *wheel = note.object;
	NSString *name = wheel.vendorName ?: NSLocalizedString(@"Racing Wheel", @"");
	[delegate notifyWithName:@"GamepadRacingWheelConnected"
						 title:NSLocalizedString(@"Racing Wheel Connected", @"")
					   description:name
						  icon:[self iconData]
			  identifierString:[NSString stringWithFormat:@"HWGrowlGamepadRacingWheel-%p", wheel]
				 contextString:nil
						plugin:self];
}

-(void)racingWheelDisconnected:(NSNotification *)note {
	if (!HWGGamepadBoolForKey(HWG_GAMEPAD_NOTIFY_RACING_WHEEL_KEY, YES)) return;
	GCRacingWheel *wheel = note.object;
	NSString *name = wheel.vendorName ?: NSLocalizedString(@"Racing Wheel", @"");
	[delegate notifyWithName:@"GamepadRacingWheelDisconnected"
						 title:NSLocalizedString(@"Racing Wheel Disconnected", @"")
					   description:name
						  icon:[self iconData]
			  identifierString:[NSString stringWithFormat:@"HWGrowlGamepadRacingWheel-%p", wheel]
				 contextString:nil
						plugin:self];
}

#pragma mark Icon

// Designed PNG (Assets.xcassets) — replaces the SF Symbol "gamecontroller" glyph this used
// to render at runtime (pink, `systemPinkColor`). Single state: game controllers don't have
// a distinct "off" glyph convention in this app the way muted-audio or unmounted-disk do.
-(NSImage *)gamepadIcon {
	return HWGResolveIconNamed(@"GamepadMonitor-Icon");
}

-(NSData *)iconData {
	return [[self gamepadIcon] TIFFRepresentation];
}

#pragma mark HWGrowlPluginProtocol

-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Gamepad Monitor", @"");
}
-(NSImage*)preferenceIcon {
	// Resolved fresh every call (not cached) since this is user-customizable — see the same
	// note on AudioMonitor's -preferenceIcon. Own dedicated default name ("-Module"),
	// separate from -gamepadIcon's "GamepadMonitor-Icon" — customizing one must never
	// silently change the other.
	return HWGResolveIconNamed(@"GamepadMonitor-Icon-Module");
}

-(IBAction)fieldToggleChanged:(NSButton*)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
}

-(NSButton *)checkboxWithKey:(NSString *)key title:(NSString *)title defaultOn:(BOOL)defaultOn {
	NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(fieldToggleChanged:)];
	box.identifier = key;
	box.state = HWGGamepadBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	return box;
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	// BUG FIX (17-ago-2026): was 160 — same fixed-constant risk class confirmed live in Network
	// Monitor's Wi-Fi tab. Bumped with margin after adding 4 rows (Battery state/Touchpad/
	// Haptics/Motion sensors).
	// BUG FIX (18-ago-2026): was 300 — bumped after adding 5 rows (Lightbar color/Elite paddles/
	// Keyboard/Mouse/Racing Wheel notify toggles), same fixed-constant risk class as the 17-ago
	// bump above. The window's actual size is driven by the Auto Layout top-anchor chain below
	// regardless of this constant (confirmed during the Thermal Monitor checkbox investigation:
	// AppDelegate overrides the tab content view's frame on selection) — this is just the
	// initial NSTabView/NSView frame guess.
	NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 560, 460)];
	tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 460)];

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notification fields", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;

	NSArray<NSButton*> *rows = @[
		[self checkboxWithKey:HWG_GAMEPAD_SHOW_CATEGORY_KEY     title:NSLocalizedString(@"Controller type (DualSense/Xbox/MFi/etc.)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_GAMEPAD_SHOW_PLAYER_INDEX_KEY title:NSLocalizedString(@"Player index", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_GAMEPAD_SHOW_BATTERY_KEY      title:NSLocalizedString(@"Battery level", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_GAMEPAD_SHOW_TRIGGERS_KEY     title:NSLocalizedString(@"Adaptive Triggers (DualSense)", @"") defaultOn:YES],
		// Added 17-ago-2026 — OFF by default.
		[self checkboxWithKey:HWG_GAMEPAD_SHOW_BATTERY_STATE_KEY title:NSLocalizedString(@"Battery state (Charging/Full/Discharging)", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_GAMEPAD_SHOW_TOUCHPAD_KEY      title:NSLocalizedString(@"Touchpad presence (DualSense/DualShock)", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_GAMEPAD_SHOW_HAPTICS_KEY       title:NSLocalizedString(@"Haptics support", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_GAMEPAD_SHOW_MOTION_KEY        title:NSLocalizedString(@"Motion sensors presence", @"") defaultOn:NO],
		// Final API audit (18-ago-2026) — OFF by default, same reasoning as Battery state/
		// Touchpad/Haptics/Motion above.
		[self checkboxWithKey:HWG_GAMEPAD_SHOW_LIGHTBAR_KEY      title:NSLocalizedString(@"Lightbar color (read-only)", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_GAMEPAD_SHOW_PADDLES_KEY       title:NSLocalizedString(@"Xbox Elite paddles presence", @"") defaultOn:NO],
		// Final API audit (18-ago-2026) — separate notify toggles for device classes distinct
		// from GCController (see the header comment on HWG_GAMEPAD_NOTIFY_KEYBOARD_KEY above).
		[self checkboxWithKey:HWG_GAMEPAD_NOTIFY_KEYBOARD_KEY    title:NSLocalizedString(@"Notify for game-recognized keyboards", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_GAMEPAD_NOTIFY_MOUSE_KEY       title:NSLocalizedString(@"Notify for game-recognized mice", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_GAMEPAD_NOTIFY_RACING_WHEEL_KEY title:NSLocalizedString(@"Notify for racing wheels", @"") defaultOn:YES],
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
			[row.trailingAnchor constraintLessThanOrEqualToAnchor:v.trailingAnchor constant:-16],
		]];
		previous = row;
	}

	NSTabViewItem *generalItem = [[NSTabViewItem alloc] initWithIdentifier:@"general"];
	generalItem.label = NSLocalizedString(@"General", @"");
	generalItem.view = v;
	[tabs addTabViewItem:generalItem];

	CGFloat iconsPad = 16;
	CGFloat iconsWidth = 560 - 2 * iconsPad;
	HWGIconPickerView *iconPicker = [[HWGIconPickerView alloc] initWithIconSpecs:@[
		@[@"Module Icon (Sidebar)", @"GamepadMonitor-Icon-Module"],
		@[@"Game Controller", @"GamepadMonitor-Icon", HWG_GAMEPAD_NOTIFY_KEY],
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
	return @[@"GamepadConnected", @"GamepadDisconnected",
			 @"GamepadKeyboardConnected", @"GamepadKeyboardDisconnected",
			 @"GamepadMouseConnected", @"GamepadMouseDisconnected",
			 @"GamepadRacingWheelConnected", @"GamepadRacingWheelDisconnected"];
}
-(NSDictionary*)localizedNames {
	return @{
		@"GamepadConnected": NSLocalizedString(@"Game Controller Connected", @""),
		@"GamepadDisconnected": NSLocalizedString(@"Game Controller Disconnected", @""),
		@"GamepadKeyboardConnected": NSLocalizedString(@"Game-Recognized Keyboard Connected", @""),
		@"GamepadKeyboardDisconnected": NSLocalizedString(@"Game-Recognized Keyboard Disconnected", @""),
		@"GamepadMouseConnected": NSLocalizedString(@"Game-Recognized Mouse Connected", @""),
		@"GamepadMouseDisconnected": NSLocalizedString(@"Game-Recognized Mouse Disconnected", @""),
		@"GamepadRacingWheelConnected": NSLocalizedString(@"Racing Wheel Connected", @""),
		@"GamepadRacingWheelDisconnected": NSLocalizedString(@"Racing Wheel Disconnected", @""),
	};
}
-(NSDictionary*)noteDescriptions {
	return @{
		@"GamepadConnected": NSLocalizedString(@"Sent when a game controller is connected, with type/player/battery detail — even if USB/Bluetooth Monitor also reported the same connect event generically", @""),
		@"GamepadDisconnected": NSLocalizedString(@"Sent when a game controller is disconnected", @""),
		@"GamepadKeyboardConnected": NSLocalizedString(@"Sent when a keyboard becomes available to GameController-based games/apps (off by default)", @""),
		@"GamepadKeyboardDisconnected": NSLocalizedString(@"Sent when that keyboard is no longer available (off by default)", @""),
		@"GamepadMouseConnected": NSLocalizedString(@"Sent when a mouse becomes available to GameController-based games/apps (off by default)", @""),
		@"GamepadMouseDisconnected": NSLocalizedString(@"Sent when that mouse is no longer available (off by default)", @""),
		@"GamepadRacingWheelConnected": NSLocalizedString(@"Sent when a racing wheel is connected (macOS 13+)", @""),
		@"GamepadRacingWheelDisconnected": NSLocalizedString(@"Sent when a racing wheel is disconnected (macOS 13+)", @""),
	};
}
-(NSArray*)defaultNotifications {
	return [self noteNames];
}

@end
