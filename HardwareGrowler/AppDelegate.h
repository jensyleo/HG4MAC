//
//  AppDelegate.h
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/2/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>

@class GrowlOnSwitch, HWGrowlPluginController;

typedef enum : NSInteger {
	kShowIconInMenu = 0,
	kShowIconInDock = 1,
	kShowIconInBoth = 2,
	kDontShowIcon = 3
} HWGrowlIconState;

@interface AppDelegate : NSObject <NSApplicationDelegate, NSToolbarDelegate, NSTableViewDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate> {
	// Only ivars WITHOUT a @property live here; the rest are synthesized with the
	// correct ARC ownership from the @property declarations below.
	NSStatusItem *statusItem;          // strong (we create/own it); set to nil to release
	IBOutlet NSMenu *statusMenu;       // top-level nib object
	IBOutlet GrowlOnSwitch *onLoginSwitch;

	HWGrowlIconState oldIconValue;
	BOOL oldOnLoginValue;
}

@property (nonatomic, strong) IBOutlet NSString *showDevices;
@property (nonatomic, strong) IBOutlet NSString *quitTitle;
@property (nonatomic, strong) IBOutlet NSString *preferencesTitle;
@property (nonatomic, strong) IBOutlet NSString *openPreferencesTitle;
@property (nonatomic, strong) IBOutlet NSString *iconTitle;
@property (nonatomic, strong) IBOutlet NSString *startAtLoginTitle;
@property (nonatomic, strong) IBOutlet NSString *noPluginPrefsTitle;
@property (nonatomic, strong) IBOutlet NSString *moduleLabel;

@property (nonatomic, strong) NSString *iconInMenu;
@property (nonatomic, strong) NSString *iconInDock;
@property (nonatomic, strong) NSString *iconInBoth;
@property (nonatomic, strong) NSString *noIcon;

// Views/controls owned by the nib/view hierarchy → weak (was assign).
// EXCEPTION: window is strong. It's a top-level nib object with visibleAtLaunch=NO,
// so nothing else reliably keeps it alive before the user opens Preferences. Owning
// it here guarantees it survives (no cycle: window.delegate is weak; AppDelegate is
// app-lifetime). This mirrors the placeholderView/prefs-pane top-level-object lesson.
@property (strong) IBOutlet NSWindow *window;
@property (nonatomic, weak) IBOutlet NSPopUpButton *iconPopUp;
@property (nonatomic, strong) HWGrowlPluginController *pluginController;

@property (nonatomic, weak) IBOutlet NSToolbar *toolbar;
@property (nonatomic, weak) IBOutlet NSToolbarItem *generalItem;
@property (nonatomic, weak) IBOutlet NSToolbarItem *modulesItem;
@property (nonatomic, weak) IBOutlet NSTabView *tabView;
@property (nonatomic, weak) IBOutlet NSTableColumn *moduleColumn;
@property (nonatomic, weak) IBOutlet NSTableView *tableView;
@property (nonatomic, weak) IBOutlet NSView *containerView;
@property (nonatomic, weak) IBOutlet NSTextField *noPrefsLabel;
// strong: placeholderView is removed from its superview when another pane shows,
// so we must own it or it would dealloc (we add it back later).
@property (nonatomic, strong) IBOutlet NSView *placeholderView;
@property (nonatomic, weak) IBOutlet NSView *currentView;

- (void)setStartAtLogin:(BOOL)enabled;
- (BOOL)isRegisteredAtLogin;

@end
