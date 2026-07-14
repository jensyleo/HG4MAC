//
//  AppDelegate.m
//  HG4MAC
//
//  Created by Daniel Siemer on 5/2/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

// compile with ARC: -fobjc-arc
#import "AppDelegate.h"
#import "GrowlOnSwitch.h"
#import "HWGrowlPluginController.h"
#import "HWGImageTextCell.h"
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>
#import <CoreBluetooth/CoreBluetooth.h>
#include <unistd.h>

#define ShowDevicesTitle     NSLocalizedString(@"Show Connected Devices at Launch", nil)
#define QuitTitle	           NSLocalizedString(@"Quit HG4MAC", nil)
#define PreferencesTitle     NSLocalizedString(@"Preferences", nil)
#define OpenPreferencesTitle NSLocalizedString(@"Open HG4MAC Preferences...", nil)
#define IconTitle            NSLocalizedString(@"Icon:", nil)
#define StartAtLoginTitle    NSLocalizedString(@"Start HG4MAC at Login:", nil)
#define NoPluginPrefsTitle   NSLocalizedString(@"There are no preferences available for this monitor.", @"")
#define ModuleLabel          NSLocalizedString(@"Modules", @"")

@interface AppDelegate ()

@end

@implementation AppDelegate

@synthesize window = _window;
@synthesize iconPopUp;
@synthesize pluginController;

@synthesize showDevices;
@synthesize quitTitle;
@synthesize preferencesTitle;
@synthesize openPreferencesTitle;
@synthesize iconTitle;
@synthesize startAtLoginTitle;
@synthesize noPluginPrefsTitle;
@synthesize moduleLabel;

@synthesize iconInMenu;
@synthesize iconInDock;
@synthesize iconInBoth;
@synthesize noIcon;

@synthesize toolbar;
@synthesize generalItem;
@synthesize modulesItem;
@synthesize tabView;
@synthesize tableView;
@synthesize moduleColumn;
@synthesize containerView;
@synthesize noPrefsLabel;
@synthesize placeholderView;
@synthesize currentView;

+(void)initialize
{
	[[NSUserDefaults standardUserDefaults] registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:
																				[NSNumber numberWithBool:NO], @"OnLogin",
																				[NSNumber numberWithBool:YES], @"ShowExisting",
																				[NSNumber numberWithBool:NO], @"GroupNetwork",
																				[NSNumber numberWithInteger:0], @"Visibility", nil]];
	[[NSUserDefaults standardUserDefaults] synchronize];
	[super initialize];
}

// ARC: no manual dealloc needed (all ObjC ivars are strong/weak, auto-managed).
// (AppDelegate lives for the whole app lifetime anyway.)

- (void) awakeFromNib {
	self.iconInMenu = NSLocalizedString(@"Show icon in the menubar", @"default option for where the icon should be seen");
	self.iconInDock = NSLocalizedString(@"Show icon in the dock", @"display the icon only in the dock");
	self.iconInBoth = NSLocalizedString(@"Show icon in both", @"display the icon in both the menubar and the dock");
	self.noIcon = NSLocalizedString(@"No icon visible", @"display no icon at all");
	
	[generalItem setLabel:NSLocalizedString(@"General", @"")];
	[modulesItem setLabel:NSLocalizedString(@"Modules", @"")];
	
	NSNumber *visibility = [[NSUserDefaults standardUserDefaults] objectForKey:@"Visibility"];
	if(visibility == nil || [visibility integerValue] == kShowIconInDock || [visibility integerValue] == kShowIconInBoth){
		[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
	}
	
	if(visibility == nil || [visibility integerValue] == kShowIconInMenu || [visibility integerValue] == kShowIconInBoth){
		[self initMenu];
	}
	
	BOOL _isOn = [self isRegisteredAtLogin];
	[[NSUserDefaults standardUserDefaults] setBool:_isOn forKey:@"OnLogin"];
	[[NSUserDefaultsController sharedUserDefaultsController].defaults setBool:_isOn forKey:@"OnLogin"];
	[onLoginSwitch setState:_isOn];
	oldOnLoginValue = _isOn;

	// weak capture: onLoginSwitch retains the action block, so a strong self
	// capture would create a retain cycle (self → onLoginSwitch → block → self).
	__weak AppDelegate *weakSelf = self;
	[onLoginSwitch setActionBlock:^(NSInteger state) {
		AppDelegate *blockSelf = weakSelf;
		if (!blockSelf) return;
		BOOL enabled = (state != 0);
		[blockSelf setStartAtLogin:enabled];
		blockSelf->oldOnLoginValue = enabled;
		[[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"OnLogin"];
	}];

	self.pluginController = [[HWGrowlPluginController alloc] init];
	
	
	NSDictionary *attrDict = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSFont systemFontOfSize:13.0f], NSFontAttributeName,
		[NSColor secondaryLabelColor], NSForegroundColorAttributeName, nil];
	NSMutableAttributedString *noPrefsAttributed = [[NSMutableAttributedString alloc] initWithString:NoPluginPrefsTitle
		attributes:attrDict];
	[noPrefsAttributed setAlignment:NSTextAlignmentCenter range:NSMakeRange(0, [noPrefsAttributed length])];
	[noPrefsLabel setAttributedStringValue:noPrefsAttributed];

	HWGImageTextCell *imageTextCell = [[HWGImageTextCell alloc] init];
   [moduleColumn setDataCell:imageTextCell];

	// Fixed row height so the icon (sized below) never overflows into the next row.
	[tableView setRowHeight:40.0];

	// Fondo transparente para que se vea el fondo oscuro de la ventana
	[tableView setBackgroundColor:[NSColor clearColor]];
	[tableView setUsesAlternatingRowBackgroundColors:NO];
	tableView.style = NSTableViewStyleSourceList;
	[[tableView enclosingScrollView] setDrawsBackground:NO];
	[[tableView enclosingScrollView] setBorderType:NSNoBorder];
}

- (IBAction)showPreferences:(id)sender
{
	[NSApp activateIgnoringOtherApps:YES];
   if(![self.window isVisible]){
      [self.window center];
      [self.window setFrameAutosaveName:@"HWGrowlerPrefsWindowFrame"];
      [self.window setFrameUsingName:@"HWGrowlerPrefsWindowFrame" force:YES];
   }
	// Become a regular (Dock-visible, focusable) app so the window can take
	// focus, then activate. Modern replacement for the deprecated Carbon
	// TransformProcessType(kProcessTransformToForegroundApplication).
	[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
	[NSApp activateIgnoringOtherApps:YES];

	[self.window makeKeyAndOrderFront:sender];
}

- (void)windowWillClose:(NSNotification *)notification {
	NSNumber *value = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] valueForKey:@"Visibility"];
	HWGrowlIconState visibility = [value integerValue];
	if(visibility == kDontShowIcon || visibility == kShowIconInMenu){
		dispatch_async(dispatch_get_main_queue(), ^{
			// Go back to a background (menu-bar-only) app. Modern replacement
			// for TransformProcessType(kProcessTransformToUIElementApplication).
			[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
			// Relinquish focus — macOS automatically brings the previously
			// active app forward. More reliable than tracking the prior app,
			// because clicking our status item already made us frontmost.
			[NSApp hide:nil];
		});
	}
}

- (void) initMenu{
	statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
	[statusItem setMenu:statusMenu];
	
	// Menu-bar icon: a COLOR image (NOT a template) so the blue dot — our distinctive
	// mark — keeps its color. Because it isn't a template, macOS won't auto-tint it, so
	// we ship two variants and pick by the menu bar's appearance: "Normal" has dark claws
	// (for a light menu bar), "Selected" has light claws (for a dark menu bar); both keep
	// the blue dot. A drawing-handler image re-renders on appearance change, so it swaps
	// automatically when the user toggles light/dark.
	NSString *lightPath = [[NSBundle mainBundle] pathForResource:@"menubarIcon_Normal"   ofType:@"png"];
	NSString *darkPath  = [[NSBundle mainBundle] pathForResource:@"menubarIcon_Selected" ofType:@"png"];
	NSImage *clawsLight = [[NSImage alloc] initWithContentsOfFile:lightPath];  // dark claws + blue dot
	NSImage *clawsDark  = [[NSImage alloc] initWithContentsOfFile:darkPath];   // light claws + blue dot
	NSImage *icon = [NSImage imageWithSize:NSMakeSize(18.0, 18.0) flipped:NO drawingHandler:^BOOL(NSRect rect) {
		NSAppearanceName match = [[NSAppearance currentDrawingAppearance]
			bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
		NSImage *use = [match isEqualToString:NSAppearanceNameDarkAqua] ? clawsDark : clawsLight;
		[use drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
		return YES;
	}];
	icon.template = NO;   // color icon — do not tint (keeps the blue dot)
	statusItem.button.image = icon;

	// Add "About…" and "Uninstall…" items at the bottom of the status menu.
	[statusMenu addItem:[NSMenuItem separatorItem]];
	NSMenuItem *aboutItem = [[NSMenuItem alloc]
		initWithTitle:NSLocalizedString(@"About HG4MAC…", @"")
			   action:@selector(showAbout:)
		keyEquivalent:@""];
	aboutItem.target = self;
	[statusMenu addItem:aboutItem];

	NSMenuItem *uninstallItem = [[NSMenuItem alloc]
		initWithTitle:NSLocalizedString(@"Uninstall HG4MAC…", @"")
			   action:@selector(uninstall:)
		keyEquivalent:@""];
	uninstallItem.target = self;
	[statusMenu addItem:uninstallItem];
}

// Standard macOS About panel. Name / version / copyright come from the Info.plist
// (CFBundleName, CFBundleShortVersionString, NSHumanReadableCopyright); the credits
// carry the GPLv3 + no-warranty notice and a link to the license.
- (IBAction)showAbout:(id)sender {
	if (@available(macOS 14.0, *)) { [NSApp activate]; }
	else { [NSApp activateIgnoringOtherApps:YES]; }

	NSMutableAttributedString *credits = [[NSMutableAttributedString alloc]
		initWithString:NSLocalizedString(@"A macOS menu-bar app that shows native-style notifications when hardware changes.\n\nModernized fork of HardwareGrowler / Growl. Free software under the GNU General Public License v3.0 — with NO WARRANTY.\n", @"")
		attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:11],
		              NSForegroundColorAttributeName: [NSColor secondaryLabelColor] }];
	[credits appendAttributedString:[[NSAttributedString alloc]
		initWithString:@"gnu.org/licenses/gpl-3.0"
		attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:11],
		              NSLinkAttributeName: [NSURL URLWithString:@"https://www.gnu.org/licenses/gpl-3.0.html"] }]];

	[NSApp orderFrontStandardAboutPanel:@{ NSAboutPanelOptionCredits: credits }];
}

- (IBAction)uninstall:(id)sender {
	[NSApp activateIgnoringOtherApps:YES];
	NSAlert *alert = [[NSAlert alloc] init];
	alert.alertStyle = NSAlertStyleCritical;
	alert.messageText = NSLocalizedString(@"Uninstall HG4MAC?", @"");
	alert.informativeText = NSLocalizedString(@"This will quit HG4MAC, remove it from login items, delete all of its settings, and move the app to the Trash.\n\nThis cannot be undone.", @"");
	[alert addButtonWithTitle:NSLocalizedString(@"Uninstall", @"")];  // NSAlertFirstButtonReturn
	[alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"")];     // NSAlertSecondButtonReturn
	if ([alert runModal] != NSAlertFirstButtonReturn)
		return;
	[self performUninstall];
}

- (void)performUninstall {
	NSString *bundleID = @"com.jensyleo.hg4mac";
	NSString *home = NSHomeDirectory();
	NSString *appPath = [[NSBundle mainBundle] bundlePath];

	// Unregister the login item in-process (needs our SMAppService).
	if (@available(macOS 13.0, *)) {
		[[SMAppService mainAppService] unregisterAndReturnError:NULL];
	}

	// Everything else is done by a DETACHED shell script that runs AFTER we
	// quit. This is essential for the preferences: while the app is alive,
	// cfprefsd owns the domain and rewrites the plist on exit, so deleting it
	// in-process leaves an orphan. Running `defaults delete` + rm after the app
	// has terminated avoids that. The script also clears every other standard
	// Library location and moves the app bundle to the Trash — no orphans left.
	NSString *trash = [home stringByAppendingPathComponent:@".Trash"];
	NSArray *dirs = @[@"Library/Preferences", @"Library/Preferences/ByHost",
	                  @"Library/Caches", @"Library/Saved Application State",
	                  @"Library/HTTPStorages", @"Library/WebKit",
	                  @"Library/Application Support", @"Library/LaunchAgents",
	                  @"Library/Logs/DiagnosticReports",
	                  @"Library/Application Support/CrashReporter"];

	NSMutableString *cmd = [NSMutableString string];
	[cmd appendString:@"sleep 1; "];
	[cmd appendFormat:@"/usr/bin/defaults delete %@ >/dev/null 2>&1; ", bundleID];
	// Also drop the legacy Growl-named prefs domain from installs before the rename.
	[cmd appendString:@"/usr/bin/defaults delete com.growl.hardwaregrowler >/dev/null 2>&1; "];
	for (NSString *rel in dirs) {
		NSString *dir = [home stringByAppendingPathComponent:rel];
		[cmd appendFormat:@"/bin/rm -rf \"%@\"/*%@* >/dev/null 2>&1; ", dir, bundleID];
		[cmd appendFormat:@"/bin/rm -rf \"%@\"/*HG4MAC* >/dev/null 2>&1; ", dir];
		// Legacy pre-rename artifacts (old app name / bundle id).
		[cmd appendFormat:@"/bin/rm -rf \"%@\"/*HardwareGrowler* >/dev/null 2>&1; ", dir];
		[cmd appendFormat:@"/bin/rm -rf \"%@\"/*com.growl.hardwaregrowler* >/dev/null 2>&1; ", dir];
	}
	[cmd appendFormat:@"/bin/mv \"%@\" \"%@/\" >/dev/null 2>&1; ", appPath, trash];

	NSTask *task = [[NSTask alloc] init];
	task.launchPath = @"/bin/sh";
	task.arguments = @[@"-c", cmd];
	[task launch];

	[NSApp terminate:nil];
}

- (void) initTitles{
	self.showDevices = ShowDevicesTitle;
	self.quitTitle = QuitTitle;
	self.preferencesTitle = PreferencesTitle;
	self.openPreferencesTitle = OpenPreferencesTitle;
	self.iconTitle = IconTitle;
	self.startAtLoginTitle = StartAtLoginTitle;
	self.noPluginPrefsTitle = NoPluginPrefsTitle;
	self.moduleLabel = ModuleLabel;
}

- (void)requestAllPermissions {
	// 1. Notificaciones — el delegate se necesita para el caso en que sí se otorgue permiso
	[[UNUserNotificationCenter currentNotificationCenter] setDelegate:self];
	[[UNUserNotificationCenter currentNotificationCenter]
		requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
		completionHandler:^(BOOL granted, NSError *error) {
			(void)granted; (void)error;
		}];

	// 2. Bluetooth — iniciarlo provoca el diálogo de permiso del sistema
	dispatch_async(dispatch_get_main_queue(), ^{
		CBCentralManager *cbManager = [[CBCentralManager alloc]
			initWithDelegate:nil queue:nil
			options:@{CBCentralManagerOptionShowPowerAlertKey: @NO}];
		// Retener brevemente para que el sistema procese el permiso
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			(void)cbManager; // liberar
		});
	});
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
	// Single-instance guard: if another copy with our bundle id is already running,
	// this launch is a duplicate — quit immediately and let the existing one keep
	// running. Belt-and-suspenders alongside LSMultipleInstancesProhibited in the
	// Info.plist (this also covers launches Launch Services doesn't police, e.g.
	// executing the binary directly or via launchd).
	NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
	for (NSRunningApplication *other in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID]) {
		if (![other isEqual:[NSRunningApplication currentApplication]]) {
			[NSApp terminate:nil];
			return;
		}
	}

	[self requestAllPermissions];

	[[self toolbar] setVisible:YES];
	if([[[self toolbar] items] count] == 0){
		[[self toolbar] insertItemWithItemIdentifier:@"General" atIndex:0];
		[[self toolbar] insertItemWithItemIdentifier:@"Modules" atIndex:1];
	}
	[self selectTabIndex:0];
	[self initTitles];
		
	[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self
																				 forKeyPath:@"values.Visibility"
																					 options:NSKeyValueObservingOptionNew
																					 context:nil];
	oldIconValue = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] integerForKey:@"Visibility"];

	BOOL isRegistered = [self isRegisteredAtLogin];
	[[NSUserDefaultsController sharedUserDefaultsController].defaults setBool:isRegistered forKey:@"OnLogin"];
	oldOnLoginValue = isRegistered;
}

- (BOOL) applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag {
	[self showPreferences:self];
	return YES;
}

- (void)observeValueForKeyPath:(NSString*)keyPath 
							 ofObject:(id)object 
								change:(NSDictionary*)change 
							  context:(void*)context
{
	NSUserDefaultsController *defaultController = [NSUserDefaultsController sharedUserDefaultsController];
	if([keyPath isEqualToString:@"values.Visibility"])
	{
		NSNumber *value = [[defaultController defaults] valueForKey:@"Visibility"];
		HWGrowlIconState index   = [value integerValue];
		switch (index) {
			case kDontShowIcon:
				if(![[defaultController defaults] boolForKey:@"SuppressNoIconWarn"])
				{
					[NSApp activateIgnoringOtherApps:YES];
					// Modern NSAlert (the alertWithMessageText:defaultButton:... constructor
					// was deprecated in 10.10). First button added = NSAlertFirstButtonReturn.
					NSAlert *alert = [[NSAlert alloc] init];
					alert.messageText = NSLocalizedString(@"Warning! Enabling this option will cause HG4MAC to run in the background", nil);
					alert.informativeText = NSLocalizedString(@"Enabling this option will cause HG4MAC to run without showing a dock icon or a menu item.\n\nTo access preferences, tap HG4MAC in Launchpad, or open HG4MAC in Finder.", nil);
					[alert addButtonWithTitle:NSLocalizedString(@"Ok", nil)];      // NSAlertFirstButtonReturn
					[alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];  // NSAlertSecondButtonReturn
					alert.showsSuppressionButton = YES;
					NSInteger allow = [alert runModal];
					if(allow == NSAlertFirstButtonReturn)
					{
						if([[alert suppressionButton] state] == NSControlStateValueOn){
							[[defaultController defaults] setBool:YES forKey:@"SuppressNoIconWarn"];
						}
						[self warnUserAboutIcons];
						[[NSStatusBar systemStatusBar] removeStatusItem:statusItem];
						statusItem = nil;
					}
					else
					{
						[[defaultController defaults] setInteger:oldIconValue forKey:@"Visibility"];
						[[defaultController defaults] synchronize];
						[iconPopUp selectItemAtIndex:oldIconValue];
					}
				}else{
					[self warnUserAboutIcons];
					[[NSStatusBar systemStatusBar] removeStatusItem:statusItem];
					statusItem = nil;
				}
				break;
			case kShowIconInBoth:
				[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
				if(!statusItem)
					[self initMenu];
				break;
			case kShowIconInDock:
				[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
				[[NSStatusBar systemStatusBar] removeStatusItem:statusItem];
				statusItem = nil;
				break;
			case kShowIconInMenu:
			default:
				if(!statusItem)
					[self initMenu];
				if(oldIconValue == kShowIconInBoth || oldIconValue == kShowIconInDock)
					[self warnUserAboutIcons];
				break;
		}
		oldIconValue = index;
	}
}

- (void)warnUserAboutIcons
{
	// Legacy no-op: this warning only applied to macOS < 10.7, which the app no
	// longer supports (deployment target 13.0). Icon changes apply immediately.
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
	completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

- (void) setStartAtLogin:(BOOL)enabled {
    NSLog(@"HWG setStartAtLogin: %@", enabled ? @"YES" : @"NO");

    // macOS 13+: use SMAppService so the item appears in System Settings >
    // General > Login Items (and "App background activity") and is user-managed.
    if (@available(macOS 13.0, *)) {
        SMAppService *svc = [SMAppService mainAppService];
        NSError *err = nil;
        BOOL ok = enabled ? [svc registerAndReturnError:&err]
                          : [svc unregisterAndReturnError:&err];
        if (!ok) NSLog(@"HWG SMAppService %@ error: %@",
                       enabled ? @"register" : @"unregister", err);
        // Clean up any legacy LaunchAgent left by older versions.
        if (enabled) {
            NSString *legacy = [NSHomeDirectory() stringByAppendingPathComponent:
                @"Library/LaunchAgents/com.growl.hardwaregrowler.plist"];
            [[NSFileManager defaultManager] removeItemAtPath:legacy error:nil];
        }
        return;
    }

    // Fallback for < macOS 13: manual LaunchAgent plist.
    NSString *label = @"com.growl.hardwaregrowler";
    NSString *launchAgentsDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents"];
    NSString *plistPath = [launchAgentsDir stringByAppendingPathComponent:[label stringByAppendingString:@".plist"]];
    if (enabled) {
        [[NSFileManager defaultManager] createDirectoryAtPath:launchAgentsDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
        NSDictionary *plist = @{
            @"Label": label,
            @"ProgramArguments": @[@"/usr/bin/open", @"-a", bundlePath],
            @"RunAtLoad": @YES,
            @"KeepAlive": @NO
        };
        BOOL ok = [plist writeToFile:plistPath atomically:YES];
        NSLog(@"HWG plist written=%d path=%@", ok, plistPath);
    } else {
        [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
        NSLog(@"HWG plist removed");
    }
}

- (BOOL) isRegisteredAtLogin {
    if (@available(macOS 13.0, *)) {
        return [SMAppService mainAppService].status == SMAppServiceStatusEnabled;
    }
    NSString *plistPath = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/LaunchAgents/com.growl.hardwaregrowler.plist"];
    return [[NSFileManager defaultManager] fileExistsAtPath:plistPath];
}

#pragma mark Module Table

-(IBAction)moduleCheckbox:(id)sender {
	NSInteger selection = [tableView clickedRow];
	if(selection >= 0 && (NSUInteger)selection < [[pluginController plugins] count]){
		NSMutableDictionary *pluginDict = [[pluginController plugins] objectAtIndex:selection];
		id<HWGrowlPluginProtocol> plugin = [pluginDict objectForKey:@"plugin"];
		NSString *identifier = [[NSBundle bundleForClass:[plugin class]] bundleIdentifier];
		NSNumber *disabled = [pluginDict objectForKey:@"disabled"];
		
		if([disabled boolValue]){
			if([plugin respondsToSelector:@selector(stopObserving)])
				[plugin stopObserving];
		}else{
			if([plugin respondsToSelector:@selector(startObserving)])
				[plugin startObserving];
		}
		
		NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
		NSMutableDictionary *disabledDict = [[defaults objectForKey:@"DisabledPlugins"] mutableCopy];
		if(!disabledDict)
			disabledDict = [NSMutableDictionary dictionary];
		[disabledDict setObject:disabled forKey:identifier];
		[defaults setObject:disabledDict forKey:@"DisabledPlugins"];
		[defaults synchronize];
	}
}

-(void)tableViewSelectionDidChange:(NSNotification *)notification {
	NSInteger selection = [tableView selectedRow];
	NSView *newView = nil;
	if(selection >= 0 && (NSUInteger)selection < [[pluginController plugins] count]){
		id<HWGrowlPluginProtocol> plugin = [[[pluginController plugins] objectAtIndex:selection] objectForKey:@"plugin"];
		if([plugin preferencePane]){
			newView = [plugin preferencePane];
		}else{
			newView = placeholderView;
		}
	}else
		newView = placeholderView;
	[newView setFrameSize:[containerView frame].size];
	if([currentView superview])
		[currentView removeFromSuperview];
	[containerView addSubview:newView];
	self.currentView = newView;
	[_window recalculateKeyViewLoop];
}

- (id) tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {
	if (aTableColumn == moduleColumn) {
		id<HWGrowlPluginProtocol> plugin = [[[pluginController plugins] objectAtIndex:rowIndex] objectForKey:@"plugin"];
		return [plugin pluginDisplayName];
	}
	return nil;
}

- (void)tableView:(NSTableView *)aTableView willDisplayCell:(id)aCell forTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {
	if (aTableColumn == moduleColumn && [aCell isKindOfClass:[HWGImageTextCell class]]) {
		id<HWGrowlPluginProtocol> plugin = [[[pluginController plugins] objectAtIndex:rowIndex] objectForKey:@"plugin"];
		NSImage *icon = [plugin preferenceIcon];
		if (!icon) {
			static NSImage *placeholder = nil;
			static dispatch_once_t onceToken;
			dispatch_once(&onceToken, ^{
				placeholder = [NSImage imageNamed:@"HWGPrefsDefault"];
			});
			icon = placeholder;
		}
		// Asset-catalog icons are 512×512; the cell draws at the image's natural
		// size, so pin to 32×32 to fit the 40px list row without overlapping.
		icon.size = NSMakeSize(32, 32);
		[(HWGImageTextCell *)aCell setImage:icon];
	}
}

#pragma mark Toolbar

-(void)selectTabIndex:(NSInteger)tab {
	if(tab < 0 || tab > 1)
		tab = 0;
	[toolbar setSelectedItemIdentifier:[NSString stringWithFormat:@"%ld", tab]];
	[tabView selectTabViewItemAtIndex:tab];
}

-(IBAction)selectTab:(id)sender {
	[self selectTabIndex:[sender tag]];
}

-(BOOL)validateToolbarItem:(NSToolbarItem *)theItem {
	return YES;
}

-(NSArray*)toolbarSelectableItemIdentifiers:(NSToolbar*)aToolbar
{
	return [NSArray arrayWithObjects:@"0", @"1", nil];
}

- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar
{
   return [NSArray arrayWithObjects:@"0", @"1", nil];
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar*)aToolbar 
{
   return [NSArray arrayWithObjects:@"0", @"1", nil];
}

@end
