//
//  HWGrowlVolumeMonitor.m
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/3/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

// compile with ARC: -fobjc-arc
#import "HWGrowlVolumeMonitor.h"

#define VolumeNotifierUnmountWaitSeconds	600.0
#define VolumeEjectCacheInfoIndex			0
#define VolumeEjectCacheTimerIndex			1

@implementation VolumeInfo

@synthesize iconData;
@synthesize path;
@synthesize name;

+ (NSImage*)ejectIconImage {
	static NSImage *_ejectIconImage = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_ejectIconImage = [NSImage imageNamed:@"DisksVolumes-Eject"];
	});
	return _ejectIconImage;
}

+ (NSData*)mountIconData {
	static NSData *_mountIconData = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		// Custom colored mount icon from the asset catalog (replaces the old
		// generic SF Symbol "externaldrive").
		_mountIconData = [[NSImage imageNamed:@"DisksVolumes-Mounted"] TIFFRepresentation];
	});
	return _mountIconData;
}

+ (VolumeInfo *) volumeInfoForMountWithPath:(NSString *)aPath {
	return [[VolumeInfo alloc] initForMountWithPath:aPath];
}

+ (VolumeInfo *) volumeInfoForUnmountWithPath:(NSString *)aPath {
	return [[VolumeInfo alloc] initForUnmountWithPath:aPath];
}

- (id) initForMountWithPath:(NSString *)aPath {
	if ((self = [self initWithPath:aPath])) {
		// Always use the generic mount icon. Reading the volume's actual
		// icon (via iconForFile: or NSURLEffectiveIconKey) traverses to the
		// source file (e.g. the .dmg in ~/Downloads) and triggers TCC
		// permission prompts. We never touch the filesystem here.
		self.iconData = [VolumeInfo mountIconData];
	}
	return self;
}

- (id) initForUnmountWithPath:(NSString *)aPath {
	if ((self = [self initWithPath:aPath])) {
		// Always use the eject icon alone for unmounts. No filesystem access,
		// no TCC prompts. The volume name in the title is enough to identify
		// which volume was ejected.
		NSImage *ejectIcon = [VolumeInfo ejectIconImage];
		NSData *tiff = [ejectIcon TIFFRepresentation];
		NSBitmapImageRep *bitmapRep = [NSBitmapImageRep imageRepWithData:tiff];
		self.iconData = [bitmapRep representationUsingType:NSBitmapImageFileTypePNG
												properties:@{}];
	}

	return self;
}

- (id) initWithPath:(NSString *)aPath {
	if ((self = [super init])) {
		if (aPath) {
			path = aPath;
			// Use the last path component as the volume name. This is purely
			// string manipulation — no filesystem access, no TCC prompts.
			// For /Volumes/MyDrive this yields "MyDrive", which matches the
			// display name macOS shows in Finder for nearly all volumes.
			name = [aPath lastPathComponent];
		}
	}

	return self;
}

// No -dealloc needed under ARC (the ivars were only released here).

- (NSString *) description {
	NSMutableDictionary *desc = [NSMutableDictionary dictionary];
	
	if (name)
		[desc setObject:name forKey:@"name"];
	if (path)
		[desc setObject:path forKey:@"path"];
	if (iconData)
		[desc setObject:@"<yes>" forKey:@"iconData"];
	
	return [desc description];
}

@end

@interface HWGrowlVolumeMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, strong) NSMutableDictionary *ejectCache;
@property (nonatomic, strong) NSString *ignoredVolumeColumnTitle;

// strong (not assign): these come from the prefs nib. NSArrayController is a
// top-level nib object — under ARC it needs a strong outlet to survive past
// nib load (otherwise it deallocs and the prefs pane crashes).
@property (nonatomic, strong) IBOutlet NSArrayController *arrayController;
@property (nonatomic, strong) IBOutlet NSTableView *tableView;

@end

@implementation HWGrowlVolumeMonitor

@synthesize delegate;
@synthesize ejectCache;

@synthesize prefsView;
@synthesize arrayController;
@synthesize tableView;

-(id)init {
	if((self = [super init])){
		self.ejectCache = [NSMutableDictionary dictionary];
		
		NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];
		
		[center addObserver:self selector:@selector(volumeDidMount:) name:NSWorkspaceDidMountNotification object:nil];
		//Note that we must use both WILL and DID unmount, so we can only get the volume's icon before the volume has finished unmounting.
		//The icon and data is stored during WILL unmount, and then displayed during DID unmount.
		[center addObserver:self selector:@selector(volumeDidUnmount:) name:NSWorkspaceDidUnmountNotification object:nil];
		[center addObserver:self selector:@selector(volumeWillUnmount:) name:NSWorkspaceWillUnmountNotification object:nil];
		
		self.ignoredVolumeColumnTitle = NSLocalizedString(@"Ignored Drives:", @"Title for colum in table of ignored volumes");
	}
	return self;
}

- (void)dealloc {
	// Keep the non-memory teardown (observer + timers); ARC frees the rest.
	[[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];

	[ejectCache enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
		[[obj objectAtIndex:VolumeEjectCacheTimerIndex] invalidate];
	}];
}

- (void) sendMountNotificationForVolume:(VolumeInfo*)volume mounted:(BOOL)mounted {
	NSArray *exceptions = [[NSUserDefaults standardUserDefaults] objectForKey:@"HWGVolumeMonitorExceptions"];
	__block BOOL found = NO;
	[exceptions enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		NSString *justAString = [obj valueForKey:@"justastring"];
		NSString *path = [volume path];
		NSString *name = [volume name];
		BOOL hasWildCard = [justAString hasSuffix:@"*"];
		if(!hasWildCard){
			if([path caseInsensitiveCompare:justAString] == NSOrderedSame ||
				[name caseInsensitiveCompare:justAString] == NSOrderedSame)
			{
				found = YES;
				*stop = YES;
			}
		}else{
			justAString = [justAString substringToIndex:[justAString length] - 1];
			if([path rangeOfString:justAString options:(NSAnchoredSearch | NSCaseInsensitivePredicateOption)].location != NSNotFound ||
				[name rangeOfString:justAString options:(NSAnchoredSearch | NSCaseInsensitivePredicateOption)].location != NSNotFound)
			{
				found = YES;
				*stop = YES;
			}
		}
	}];
	if(found)
		return;
	
	NSString *context = mounted ? [volume path] : nil;
	NSString *type = mounted ? @"VolumeMounted" : @"VolumeUnmounted";
	NSString *title = [NSString stringWithFormat:@"%@ %@", [volume name], mounted ? NSLocalizedString(@"Mounted", @"") : NSLocalizedString(@"Unmounted", @"")];
	[delegate notifyWithName:type
							 title:title
					 description:mounted ? NSLocalizedString(@"Click to open", @"Message body on a volume mount notification, clicking it opens the drive in finder") : nil
							  icon:[volume iconData]
			  identifierString:[volume path]
				  contextString:context 
							plugin:self];
}

- (void) staleEjectItemTimerFired:(NSTimer *)theTimer {
	VolumeInfo *info = [theTimer userInfo];
	
	[ejectCache removeObjectForKey:[info path]];
}

- (void) volumeDidMount:(NSNotification *)aNotification {
	//send notification
	VolumeInfo *volume = [VolumeInfo volumeInfoForMountWithPath:[[aNotification userInfo] objectForKey:@"NSDevicePath"]];
	[self sendMountNotificationForVolume:volume mounted:YES];
}

- (void) volumeWillUnmount:(NSNotification *)aNotification {
	NSString *path = [[aNotification userInfo] objectForKey:@"NSDevicePath"];
	
	if (path) {
		VolumeInfo *info = [VolumeInfo volumeInfoForUnmountWithPath:path];
		NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:VolumeNotifierUnmountWaitSeconds
																		  target:self
																		selector:@selector(staleEjectItemTimerFired:)
																		userInfo:info
																		 repeats:NO];
		
		// need to invalidate the timer for a previous item if it exists
		NSArray *cacheItem = [ejectCache objectForKey:path];
		if (cacheItem)
			[[cacheItem objectAtIndex:VolumeEjectCacheTimerIndex] invalidate];
		
		[ejectCache setObject:[NSArray arrayWithObjects:info, timer, nil] forKey:path];
	}
}

- (void) volumeDidUnmount:(NSNotification *)aNotification {
	VolumeInfo *info = nil;
	NSString *path = [[aNotification userInfo] objectForKey:@"NSDevicePath"];
	NSArray *cacheItem = path ? [ejectCache objectForKey:path] : nil;
	
	if (cacheItem)
		info = [cacheItem objectAtIndex:VolumeEjectCacheInfoIndex];
	else
		info = [VolumeInfo volumeInfoForUnmountWithPath:path];
	
	//Send notification
	[self sendMountNotificationForVolume:info mounted:NO];
	
	if (cacheItem) {
		[[cacheItem objectAtIndex:VolumeEjectCacheTimerIndex] invalidate];
		// we need to remove the item from the cache AFTER calling volumeDidUnmount so that "info" stays
		// retained long enough to be useful. After this next call, "info" is no longer valid.
		[ejectCache removeObjectForKey:path];
		info = nil;
	}
}

#pragma mark UI

-(void)tableViewSelectionDidChange:(NSNotification *)notification {
   NSArray *arranged = [arrayController arrangedObjects];
   NSUInteger selection = [arrayController selectionIndex];
   if(selection < [arranged count] && [arranged count]){
      NSString *justastring = [[arranged objectAtIndex:selection] valueForKey:@"justastring"];
      if(!justastring || [justastring isEqualToString:@""])
         [self.tableView editColumn:0 row:selection withEvent:nil select:YES];
   }
}

-(IBAction)addVolumeEntry:(id)sender {
   // F15: open a native Finder-style picker rooted at /Volumes instead of adding
   // an empty editable row. The picked volume name(s) go into the exceptions list
   // (key "justastring"), which sendMountNotificationForVolume: matches against
   // both the volume name and path.
   NSOpenPanel *panel = [NSOpenPanel openPanel];
   panel.canChooseDirectories    = YES;
   panel.canChooseFiles          = NO;
   panel.allowsMultipleSelection = YES;
   panel.directoryURL = [NSURL fileURLWithPath:@"/Volumes" isDirectory:YES];
   panel.prompt  = NSLocalizedString(@"Ignore", @"OpenPanel confirm button for choosing drives to ignore");
   panel.message = NSLocalizedString(@"Choose the drive(s) to ignore", @"OpenPanel message for choosing drives to ignore");

   __weak HWGrowlVolumeMonitor *weakSelf = self;
   void (^addPicked)(void) = ^{
      HWGrowlVolumeMonitor *strongSelf = weakSelf;
      if (!strongSelf) return;
      NSMutableArray *added = [NSMutableArray array];
      for (NSURL *url in panel.URLs) {
         // Prefer the volume's localized name (e.g. "Macintosh HD") — the user
         // picked the URL via the open-panel powerbox, so reading this resource
         // value doesn't trigger a TCC prompt. Fall back to the path component.
         NSString *name = nil;
         [url getResourceValue:&name forKey:NSURLVolumeLocalizedNameKey error:NULL];
         if (![name length]) name = [url lastPathComponent];
         // Skip the resolved boot-volume root ("/") and any empty name.
         if (![name length] || [name isEqualToString:@"/"]) continue;
         NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithObject:name forKey:@"justastring"];
         [strongSelf.arrayController addObject:dict];
         [added addObject:dict];
      }
      if ([added count])
         [strongSelf.arrayController setSelectedObjects:added];
   };

   NSWindow *window = [self.tableView window];
   if (window) {
      [panel beginSheetModalForWindow:window completionHandler:^(NSModalResponse result){
         if (result == NSModalResponseOK) addPicked();
      }];
   } else {
      if ([panel runModal] == NSModalResponseOK) addPicked();
   }
}
#pragma mark HWGrowlPluginProtocol

// -delegate / -setDelegate: auto-generated from @property (weak) + @synthesize.
-(NSString*)pluginDisplayName{
	return NSLocalizedString(@"Volume Monitor", @"");
}
-(NSImage*)preferenceIcon {
	static NSImage *_icon = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_icon = [NSImage imageNamed:@"HWGPrefsDrivesVolumes"];
	});
	return _icon;
}
-(NSView*)preferencePane {
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		// The nib lives in THIS plugin's bundle, not the main app bundle.
		[[NSBundle bundleForClass:[self class]] loadNibNamed:@"VolumeMonitorPrefs" owner:self topLevelObjects:nil];
	});
	return prefsView;
}

#pragma mark HWGrowlPluginNotifierProtocol

-(NSArray*)noteNames {
	return [NSArray arrayWithObjects:@"VolumeMounted", @"VolumeUnmounted", nil];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Volume Mounted", @""), @"VolumeMounted",
			  NSLocalizedString(@"Volume Unmounted", @""), @"VolumeUnmounted", nil];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Sent when a volume is mounted", @""), @"VolumeMounted",
			  NSLocalizedString(@"Sent when a volume is unmounted", @""), @"VolumeUnmounted", nil];
}
-(NSArray*)defaultNotifications {
	return [NSArray arrayWithObjects:@"VolumeMounted", @"VolumeUnmounted", nil];
}

-(void)fireOnLaunchNotes{
	// mountedLocalVolumePaths was deprecated in 10.11; use the NSFileManager URL API.
	// options:0 (no SkipHiddenVolumes) to match the old behavior of listing ALL
	// mounted volumes at launch, including system volumes.
	NSArray<NSURL*> *urls = [[NSFileManager defaultManager]
		mountedVolumeURLsIncludingResourceValuesForKeys:nil
												options:0];
	__block HWGrowlVolumeMonitor *blockSelf = self;
	[urls enumerateObjectsUsingBlock:^(NSURL *url, NSUInteger idx, BOOL *stop) {
		[blockSelf sendMountNotificationForVolume:[VolumeInfo volumeInfoForMountWithPath:url.path] mounted:YES];
	}];
}
-(void)noteClosed:(NSString*)contextString byClick:(BOOL)clicked {
	// openFile: was deprecated in 11.0; use openURL: with a file URL.
	if(clicked && contextString)
		[[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:contextString]];
}

@end
