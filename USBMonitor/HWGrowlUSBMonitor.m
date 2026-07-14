//
//  HWGrowlUSBMonitor.m
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/5/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

// compile with ARC: -fobjc-arc
#import "HWGrowlUSBMonitor.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USB.h>

// kIOMainPortDefault is available since macOS 12 (deployment target is 13).
// (It's a const, not a macro — a #ifndef fallback would wrongly redefine it to
// the deprecated kIOMasterPortDefault.)

static void usbDeviceAdded(void *refCon, io_iterator_t iterator);
static void usbDeviceRemoved(void *refCon, io_iterator_t iterator);

@interface HWGrowlUSBMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, assign) BOOL notificationsArePrimed;

// C / Core Foundation pointers — ARC does NOT manage these; keep assign.
@property (nonatomic, assign) IONotificationPortRef ioKitNotificationPort;
@property (nonatomic, assign)	CFRunLoopSourceRef notificationRunLoopSource;
// Persistent IOKit notification iterators — must be IOObjectRelease'd in dealloc.
@property (nonatomic, assign) io_iterator_t addedIterator;
@property (nonatomic, assign) io_iterator_t removedIterator;

@end

@implementation HWGrowlUSBMonitor

@synthesize delegate;
@synthesize notificationsArePrimed;
@synthesize ioKitNotificationPort;
@synthesize notificationRunLoopSource;
@synthesize addedIterator;
@synthesize removedIterator;

-(void)dealloc {
	// Keep the CF/IOKit teardown; ARC handles ObjC memory. No [super dealloc].
	if (addedIterator)   { IOObjectRelease(addedIterator);   addedIterator = 0; }
	if (removedIterator) { IOObjectRelease(removedIterator); removedIterator = 0; }
	if (self.ioKitNotificationPort) {
		CFRunLoopRemoveSource(CFRunLoopGetMain(), self.notificationRunLoopSource, kCFRunLoopDefaultMode);
		IONotificationPortDestroy(self.ioKitNotificationPort);
	}
}

-(id)init {
	if((self = [super init])){
		self.notificationsArePrimed = NO;

		self.ioKitNotificationPort = IONotificationPortCreate(kIOMainPortDefault);
		self.notificationRunLoopSource = IONotificationPortGetRunLoopSource(ioKitNotificationPort);

		CFRunLoopAddSource(CFRunLoopGetMain(),
								 notificationRunLoopSource,
								 kCFRunLoopDefaultMode);
	}
	return self;
}

-(void)postRegistrationInit {
	[self registerForUSBNotifications];
}

-(void)registerForUSBNotifications {
	//http://developer.apple.com/documentation/DeviceDrivers/Conceptual/AccessingHardware/AH_Finding_Devices/chapter_4_section_2.html#//apple_ref/doc/uid/TP30000379/BABEACCJ
	kern_return_t	matchingResult;
	kern_return_t	removeNoteResult;
	// addedIterator / removedIterator are now ivars (released in dealloc).

	//	NSLog(@"registerForUSBNotifications");
	
	//	Setup a matching Dictionary.
	CFDictionaryRef myMatchDictionary;
	myMatchDictionary = IOServiceMatching(kIOUSBDeviceClassName);
	
	//	Register our notification
	matchingResult = IOServiceAddMatchingNotification(ioKitNotificationPort,
																	  kIOFirstPublishNotification,
																	  myMatchDictionary,
																	  usbDeviceAdded,
																	  (__bridge void *)self,
																	  &addedIterator);
	
	if (matchingResult)
		NSLog(@"matching notification registration failed: %d", matchingResult);
	
	//	Prime the Notifications (And Deal with the existing devices)...
	[self usbDeviceAdded:addedIterator];
	
	//	Register for removal notifications.
	//	It seems we have to make a new dictionary...  reusing the old one didn't work.
	
	myMatchDictionary = IOServiceMatching(kIOUSBDeviceClassName);
	removeNoteResult = IOServiceAddMatchingNotification(ioKitNotificationPort,
																		 kIOTerminatedNotification,
																		 myMatchDictionary,
																		 usbDeviceRemoved,
																		 (__bridge void *)self,
																		 &removedIterator);
	
	// Matching notification must be "primed" by iterating over the
	// iterator returned from IOServiceAddMatchingNotification(), so
	// we call our device removed method here...
	//
	if (kIOReturnSuccess != removeNoteResult) {
		NSLog(@"Couldn't add device removal notification");
	} else {
		// Prime the removal iterator exactly once. (The old code drained it
		// twice — once here and again via usbDeviceRemoved(NULL, …) which ran
		// unconditionally due to a missing-braces bug — leaving the removal
		// notification mis-primed.)
		[self usbDeviceRemoved:removedIterator];
	}

	self.notificationsArePrimed = YES;
}

-(void)usbDeviceID:(uint64_t)deviceID name:(NSString*)deviceName added:(BOOL)added {
	NSString *title = added ? NSLocalizedString(@"USB Connection", @"") : NSLocalizedString(@"USB Disconnection", @"");
	
    NSString *imageName = added ? @"USB-On" : @"USB-Off";
    NSData *iconData = [[NSImage imageNamed:imageName] TIFFRepresentation];
	[delegate notifyWithName:added ? @"USBConnected" : @"USBDisconnected"
							 title:title
					 description:deviceName
							  icon:iconData
			  identifierString:[NSString stringWithFormat:@"%llu", deviceID]
				  contextString:nil
							plugin:self];
}

-(void)usbDeviceAdded:(io_iterator_t)iterator {
	//	NSLog(@"USB Device Added Notification.");
	io_object_t	thisObject;
	while ((thisObject = IOIteratorNext(iterator))) {
		if (self.notificationsArePrimed || [delegate onLaunchEnabled]) {
			kern_return_t	nameResult;
			io_name_t		deviceNameChars;
			kern_return_t	idResult;
			uint64_t			deviceID;
			
			//	This works with USB devices...
			//	but apparently not firewire
			nameResult = IORegistryEntryGetName(thisObject, deviceNameChars);
			if (nameResult != KERN_SUCCESS) {
				continue;
			}
			
			idResult = IORegistryEntryGetRegistryEntryID(thisObject, &deviceID);
			if(idResult != KERN_SUCCESS) {
				continue;
			}
			
			NSString *deviceName = [NSString stringWithCString:deviceNameChars encoding:NSASCIIStringEncoding];
			if (deviceName) {
				deviceName = [self deviceBusNameSwap:deviceName];
				
				// NSLog(@"USB Device Attached: %@" , deviceName);
				[self usbDeviceID:deviceID name:deviceName added:YES];
			}
		}
		
		IOObjectRelease(thisObject);
	}
}

static void usbDeviceAdded(void *refCon, io_iterator_t iterator) {
	HWGrowlUSBMonitor *monitor = (__bridge HWGrowlUSBMonitor*)refCon;
	[monitor usbDeviceAdded:iterator];
}

-(void)usbDeviceRemoved:(io_iterator_t)iterator {
	//	NSLog(@"USB Device Removed Notification.");
	io_object_t thisObject;
	while ((thisObject = IOIteratorNext(iterator))) {
		kern_return_t	nameResult;
		io_name_t		deviceNameChars;
		kern_return_t	idResult;
		uint64_t			deviceID;

		//	This works with USB devices...
		//	but apparently not firewire
		nameResult = IORegistryEntryGetName(thisObject, deviceNameChars);
		if (nameResult != KERN_SUCCESS) {
			continue;
		}
		
		idResult = IORegistryEntryGetRegistryEntryID(thisObject, &deviceID);
		if(idResult != KERN_SUCCESS) {
			continue;
		}
		
		NSString *deviceName = [NSString stringWithCString:deviceNameChars encoding:NSASCIIStringEncoding];
		if (deviceName) {
			deviceName = [self deviceBusNameSwap:deviceName];
			
			// NSLog(@"USB Device Detached: %@" , deviceName);
			[self usbDeviceID:deviceID name:deviceName added:NO];
		}
		
		IOObjectRelease(thisObject);
	}
}

static void usbDeviceRemoved(void *refCon, io_iterator_t iterator) {
	HWGrowlUSBMonitor *monitor = (__bridge HWGrowlUSBMonitor*)refCon;
	[monitor usbDeviceRemoved:iterator];
}

-(NSString*)deviceBusNameSwap:(NSString*)deviceName {
	NSString *newName = deviceName;
	if (([deviceName compare:@"OHCI Root Hub Simulation"] == NSOrderedSame) ||
		 ([deviceName compare:@"UHCI Root Hub Simulation"] == NSOrderedSame)) {
		newName = NSLocalizedString(@"USB Bus", @"");
	} else if ([deviceName compare:@"EHCI Root Hub Simulation"] == NSOrderedSame ||
				  [deviceName compare:@"XHCI Root Hub USB 2.0 Simulation"] == NSOrderedSame) {
		newName = NSLocalizedString(@"USB 2.0 Bus", @"");
	} else if ([deviceName compare:@"XHCI Root Hub SS Simulation"] == NSOrderedSame) {
		newName = NSLocalizedString(@"USB 3.0 Bus", @"");
	}
	return newName;
}

#pragma mark HWGrowlPluginProtocol

// delegate accessors are auto-synthesized from the @property (weak).
-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"USB Monitor", @"");
}
-(NSImage*)preferenceIcon {
	static NSImage *_icon = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_icon = [NSImage imageNamed:@"HWGPrefsUSB"];
	});
	return _icon;
}
-(NSView*)preferencePane {
	return nil;
}

#pragma mark HWGrowlPluginNotifierProtocol

-(NSArray*)noteNames {
	return [NSArray arrayWithObjects:@"USBConnected", @"USBDisconnected", nil];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"USB Connected", @""), @"USBConnected",
			  NSLocalizedString(@"USB Disconnected", @""), @"USBDisconnected", nil];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Sent when a USB Device is connected", @""), @"USBConnected",
			  NSLocalizedString(@"Sent when a USB Device is disconnected", @""), @"USBDisconnected", nil];
}
-(NSArray*)defaultNotifications {
	return [NSArray arrayWithObjects:@"USBConnected", @"USBDisconnected", nil];
}

@end
