//
//  HWGrowlBluetoothMonitor.m
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/5/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

// compile with ARC: -fobjc-arc
#import "HWGrowlBluetoothMonitor.h"
#import <stdlib.h>
#import <IOBluetooth/IOBluetooth.h>

@interface HWGrowlBluetoothMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, assign) BOOL starting;

// strong: we keep this object to call -unregister on it later, so the monitor
// must own it.
@property (nonatomic, strong) IOBluetoothUserNotification *connectionNotification;

@end

@implementation HWGrowlBluetoothMonitor

@synthesize delegate;
@synthesize starting;
@synthesize connectionNotification;

-(void)dealloc {
	[connectionNotification unregister];
	// ARC handles the release; no [super dealloc].
}

-(id)init {
	// Legacy 10.7-10.7.2 incompatibility check removed: the app's deployment
	// target is 13.0, so that range is unreachable.
	self = [super init];
	return self;
}

-(void)postRegistrationInit {
	self.starting = YES;
	self.connectionNotification = [IOBluetoothDevice registerForConnectNotifications:self 
																									selector:@selector(bluetoothConnection:device:)];
	self.starting = NO;
}

-(void)bluetoothName:(NSString*)name connected:(BOOL)connected {
	NSString *title = connected ? NSLocalizedString(@"Bluetooth Connection", @"") : NSLocalizedString(@"Bluetooth Disconnection", @"");
	
    NSString *imageName = (connected ? @"Bluetooth-On" : @"Bluetooth-Off");
	NSData *iconData = [[NSImage imageNamed:imageName] TIFFRepresentation];
    
	[delegate notifyWithName:connected ? @"BluetoothConnected" : @"BluetoothDisconnected"
							 title:title
					 description:name
							  icon:iconData
			  identifierString:name
				  contextString:nil
							plugin:self];
}

-(void)bluetoothDisconnection:(IOBluetoothUserNotification*)note 
							  device:(IOBluetoothDevice*)device
{
	[self bluetoothName:[device name] connected:NO];
	[note unregister];
	
}

-(void)bluetoothConnection:(IOBluetoothUserNotification*)note 
						  device:(IOBluetoothDevice*)device 
{
	if (!starting || [delegate onLaunchEnabled])
		[self bluetoothName:[device name] connected:YES];
	
	[device registerForDisconnectNotification:self selector:@selector(bluetoothDisconnection:device:)];
}

#pragma mark HWGrowlPluginProtocol

// -delegate / -setDelegate: are auto-generated from the @property (weak) +
// @synthesize above (satisfies HWGrowlPluginProtocol). No manual accessors —
// hand-written ones could silently mask the property's weak qualifier.
-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Bluetooth Monitor", @"");
}
-(NSImage*)preferenceIcon {
	static NSImage *_icon = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_icon = [NSImage imageNamed:@"HWGPrefsBluetooth"];
	});
	return _icon;
}
-(NSView*)preferencePane {
	return nil;
}

#pragma mark HWGrowlPluginNotifierProtocol

-(NSArray*)noteNames {
	return [NSArray arrayWithObjects:@"BluetoothConnected", @"BluetoothDisconnected", nil];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Bluetooth Connected", @""), @"BluetoothConnected",
			  NSLocalizedString(@"Bluetooth Disconnected", @""), @"BluetoothDisconnected", nil];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Sent when a Bluetooth Device is connected", @""), @"BluetoothConnected",
			  NSLocalizedString(@"Sent when a Bluetooth Device is disconnected", @""), @"BluetoothDisconnected", nil];
}
-(NSArray*)defaultNotifications {
	return [NSArray arrayWithObjects:@"BluetoothConnected", @"BluetoothDisconnected", nil];
}

@end
