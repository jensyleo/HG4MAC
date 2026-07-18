//
//  HWGrowlVolumeMonitor.m
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/3/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

// compile with ARC: -fobjc-arc
#import "HWGrowlVolumeMonitor.h"
#import <sys/param.h>
#import <sys/mount.h>

#define VolumeNotifierUnmountWaitSeconds	600.0
#define VolumeEjectCacheInfoIndex			0
#define VolumeEjectCacheTimerIndex			1

// A plain (non-flipped) NSScrollView document view, when shorter than the visible clip
// area, gets anchored to the BOTTOM of the clip by default — leaving the slack as a gap
// ABOVE the content instead of below it. A flipped content view (y=0 at the TOP, growing
// downward) is anchored to the top instead, which is what a top-down settings pane wants.
// Same pattern already used by NetworkMonitor's `HWGFlippedContentView`.
@interface HWGVolumeFlippedContentView : NSView
@end
@implementation HWGVolumeFlippedContentView
- (BOOL)isFlipped { return YES; }
@end

// F33: individually configurable extra fields in the "Volume Mounted" notification body —
// same pattern as the other monitors' per-field settings. Mount-only (an unmounted path has
// no live filesystem left to stat), all default YES.
#define HWG_VOLUME_SHOW_PATH_KEY    @"HWGVolumeShowMountPath"
#define HWG_VOLUME_SHOW_FSTYPE_KEY  @"HWGVolumeShowFileSystemType"
#define HWG_VOLUME_SHOW_SIZE_KEY    @"HWGVolumeShowVolumeSize"

static BOOL HWGVolumeBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

// Plain statfs() syscall — same mechanism already used by noteReadableSiblingForMountedPath:
// below, not NSFileManager/NSWorkspace, so this never touches TCC-gated file access.
static BOOL HWGCopyVolumeFileSystemInfo(NSString *path, NSString **outFSType, unsigned long long *outTotalBytes) {
	if (![path length]) return NO;
	struct statfs sfs;
	if (statfs([path fileSystemRepresentation], &sfs) != 0) return NO;
	if (outFSType) *outFSType = [NSString stringWithUTF8String:sfs.f_fstypename];
	if (outTotalBytes) *outTotalBytes = (unsigned long long)sfs.f_blocks * (unsigned long long)sfs.f_bsize;
	return YES;
}

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

// Disk Arbitration — detects media at the disk/physical level, independent of whether
// it ever mounts. NSWorkspace (above) only tells us about volumes that mount successfully,
// so media that's inserted but unreadable (unformatted/corrupt/unsupported filesystem)
// was previously invisible to this monitor entirely.
@property (nonatomic, assign) DASessionRef daSession;
// Media-name keys (kDADiskDescriptionMediaNameKey) for whole-disk objects that just
// appeared and might still get a child slice shortly; used to avoid double-reporting a
// disk that DOES turn out to have a recognized partition/filesystem.
@property (nonatomic, strong) NSMutableSet<NSString*> *pendingWholeDisks;
// Media-name keys currently flagged "not readable", so we don't repeat the notice for the
// same still-attached disk, and so removing it re-arms the check for next time.
@property (nonatomic, strong) NSMutableSet<NSString*> *reportedUnreadableDisks;
// BSD device-node name (e.g. "disk4s1") -> its group key, recorded at APPEARED time (when
// the disk's description is reliably populated). Disappeared events only give us
// DADiskGetBSDName reliably — kDADiskDescriptionMediaWholeKey isn't guaranteed accurate by
// then — so this reverse lookup is how we know which physical-card group a vanishing BSD
// node belonged to, without re-deriving it from a possibly-stale description.
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSString*> *bsdNameToGroupKey;
// Group key -> set of BSD names currently believed attached under that physical card. Once
// this becomes empty (every slice/whole-disk node for that card has disappeared), the card
// is genuinely gone and its "already reported" state is cleared, re-arming it.
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSMutableSet<NSString*>*> *groupMembers;
// Group key -> unreadable partition names seen so far for that physical card, collected
// during a short settle window before the notice actually fires (see
// scheduleUnreadableSettleForGroup:) so we can tell "nothing on this card is readable" apart
// from "SOME partitions on this card mounted fine, this one specifically didn't".
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSMutableSet<NSString*>*> *groupUnreadablePartitions;
// Group keys for which at least one sibling partition mounted successfully (cross-referenced
// from volumeDidMount: via the mounted volume's BSD device node -> bsdNameToGroupKey).
@property (nonatomic, strong) NSMutableSet<NSString*> *groupsWithReadableSibling;
// Group keys with a pending settle timer already scheduled, so a second unreadable partition
// arriving during the window doesn't schedule a duplicate timer.
@property (nonatomic, strong) NSMutableSet<NSString*> *groupSettleScheduled;

// strong (not assign): these come from the prefs nib. NSArrayController is a
// top-level nib object — under ARC it needs a strong outlet to survive past
// nib load (otherwise it deallocs and the prefs pane crashes).
@property (nonatomic, strong) IBOutlet NSArrayController *arrayController;
@property (nonatomic, strong) IBOutlet NSTableView *tableView;

- (NSString *)wholeDiskGroupKeyForDisk:(DADiskRef)disk;
- (void)handleDiskAppeared:(DADiskRef)disk;
- (void)handleDiskDisappeared:(DADiskRef)disk;
- (void)scheduleUnreadableSettleForGroup:(NSString *)groupKey partitionName:(NSString *)partitionName;
- (void)finalizeUnreadableForGroup:(NSString *)groupKey;
- (void)noteReadableSiblingForMountedPath:(NSString *)path;

@end

static void hwgDiskAppearedCallback(DADiskRef disk, void *context) {
	HWGrowlVolumeMonitor *monitor = (__bridge HWGrowlVolumeMonitor *)context;
	[monitor handleDiskAppeared:disk];
}

static void hwgDiskDisappearedCallback(DADiskRef disk, void *context) {
	HWGrowlVolumeMonitor *monitor = (__bridge HWGrowlVolumeMonitor *)context;
	[monitor handleDiskDisappeared:disk];
}

@implementation HWGrowlVolumeMonitor

@synthesize delegate;
@synthesize ejectCache;
@synthesize daSession;

@synthesize prefsView;
@synthesize arrayController;
@synthesize tableView;

-(id)init {
	if((self = [super init])){
		self.ejectCache = [NSMutableDictionary dictionary];
		self.pendingWholeDisks = [NSMutableSet set];
		self.reportedUnreadableDisks = [NSMutableSet set];
		self.bsdNameToGroupKey = [NSMutableDictionary dictionary];
		self.groupMembers = [NSMutableDictionary dictionary];
		self.groupUnreadablePartitions = [NSMutableDictionary dictionary];
		self.groupsWithReadableSibling = [NSMutableSet set];
		self.groupSettleScheduled = [NSMutableSet set];

		NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];

		[center addObserver:self selector:@selector(volumeDidMount:) name:NSWorkspaceDidMountNotification object:nil];
		//Note that we must use both WILL and DID unmount, so we can only get the volume's icon before the volume has finished unmounting.
		//The icon and data is stored during WILL unmount, and then displayed during DID unmount.
		[center addObserver:self selector:@selector(volumeDidUnmount:) name:NSWorkspaceDidUnmountNotification object:nil];
		[center addObserver:self selector:@selector(volumeWillUnmount:) name:NSWorkspaceWillUnmountNotification object:nil];

		self.ignoredVolumeColumnTitle = NSLocalizedString(@"Ignored Drives:", @"Title for colum in table of ignored volumes");

		// Disk Arbitration session — see property comments above for why this exists
		// alongside the NSWorkspace mount notifications.
		daSession = DASessionCreate(kCFAllocatorDefault);
		if (daSession) {
			DASessionSetDispatchQueue(daSession, dispatch_get_main_queue());
			DARegisterDiskAppearedCallback(daSession, NULL, hwgDiskAppearedCallback, (__bridge void *)self);
			DARegisterDiskDisappearedCallback(daSession, NULL, hwgDiskDisappearedCallback, (__bridge void *)self);
		}
	}
	return self;
}

- (void)dealloc {
	// Keep the non-memory teardown (observer + timers); ARC frees the rest.
	[[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];

	[ejectCache enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
		[[obj objectAtIndex:VolumeEjectCacheTimerIndex] invalidate];
	}];

	if (daSession) {
		DASessionSetDispatchQueue(daSession, NULL);
		CFRelease(daSession);
	}
}

// Returns a stable label for the PHYSICAL disk that `disk` (whole disk, or one of its
// partitions/slices) belongs to: the whole disk's OWN media name (falling back to its BSD
// name). Every partition of the same physical card resolves to the SAME group key via
// DADiskCopyWholeDisk, regardless of each partition's own label (e.g. a card with
// "android_meta" and "android_expand" partitions both group under the card's own generic
// media name) — this is what lets multiple unreadable partitions on one card collapse into
// a single notice instead of one per partition.
- (NSString *)wholeDiskGroupKeyForDisk:(DADiskRef)disk {
	DADiskRef whole = DADiskCopyWholeDisk(disk);
	if (!whole) return nil;
	NSString *key = nil;
	CFDictionaryRef descRef = DADiskCopyDescription(whole);
	if (descRef) {
		NSDictionary *desc = (__bridge_transfer NSDictionary *)descRef;
		key = desc[(__bridge NSString *)kDADiskDescriptionMediaNameKey];
	}
	if (!key) {
		const char *bsd = DADiskGetBSDName(whole);
		if (bsd) key = [NSString stringWithUTF8String:bsd];
	}
	CFRelease(whole);
	return key;
}

// Disk Arbitration: a disk (whole disk or a slice/partition of one) has appeared. This
// fires for EVERY disk, mountable or not — unlike NSWorkspaceDidMountNotification, which
// only fires once a filesystem is actually mounted. We use it to catch media that's
// present but can't be mounted (unformatted, corrupt, or an unsupported filesystem).
- (void)handleDiskAppeared:(DADiskRef)disk {
	CFDictionaryRef descRef = DADiskCopyDescription(disk);
	if (!descRef) return;
	NSDictionary *desc = (__bridge_transfer NSDictionary *)descRef;

	// Never flag the Mac's own internal storage.
	if ([desc[(__bridge NSString *)kDADiskDescriptionDeviceInternalKey] boolValue]) return;

	NSString *partitionName = desc[(__bridge NSString *)kDADiskDescriptionMediaNameKey]
		?: NSLocalizedString(@"Disk", @"");
	BOOL isWhole = [desc[(__bridge NSString *)kDADiskDescriptionMediaWholeKey] boolValue];
	BOOL hasFilesystem = (desc[(__bridge NSString *)kDADiskDescriptionVolumeKindKey] != nil);
	// Group by the PHYSICAL card, not the individual partition: a card with several
	// unrecognized partitions (e.g. an Android card's "android_meta"/"android_expand") only
	// gets ONE "Disk Not Readable" notice, not one per partition.
	NSString *groupKey = [self wholeDiskGroupKeyForDisk:disk] ?: partitionName;

	// Remember which physical-card group this BSD node belongs to, and that the card is
	// still (at least partly) present — this is what lets handleDiskDisappeared: know when
	// the group is FULLY gone without having to re-read a (possibly stale-by-then)
	// description at disappear time.
	const char *bsdName = DADiskGetBSDName(disk);
	if (bsdName) {
		NSString *bsd = [NSString stringWithUTF8String:bsdName];
		self.bsdNameToGroupKey[bsd] = groupKey;
		NSMutableSet *members = self.groupMembers[groupKey];
		if (!members) { members = [NSMutableSet set]; self.groupMembers[groupKey] = members; }
		[members addObject:bsd];
	}

	if (!isWhole) {
		// A slice/partition appeared under this media's whole disk — it has SOME
		// structure, so the "maybe totally blank" fallback check below no longer applies.
		[self.pendingWholeDisks removeObject:groupKey];
		if (hasFilesystem) return;   // recognized filesystem — the normal mount flow handles it
		[self scheduleUnreadableSettleForGroup:groupKey partitionName:partitionName];
		return;
	}

	// Whole-disk object. A normal, readable card gets a child slice with a recognized
	// filesystem moments later (handled above); a totally blank/unpartitioned card never
	// gets a child slice at all, so give it a couple seconds before treating it as
	// unreadable — long enough for Disk Arbitration to finish probing.
	if (hasFilesystem) return;
	[self.pendingWholeDisks addObject:groupKey];
	__weak HWGrowlVolumeMonitor *weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		HWGrowlVolumeMonitor *strongSelf = weakSelf;
		if (!strongSelf) return;
		if ([strongSelf.pendingWholeDisks containsObject:groupKey]) {
			[strongSelf.pendingWholeDisks removeObject:groupKey];
			[strongSelf scheduleUnreadableSettleForGroup:groupKey partitionName:partitionName];
		}
	});
}

// Disk Arbitration: a disk (whole or slice) has gone away. We deliberately do NOT re-read
// its description here — kDADiskDescriptionMediaWholeKey isn't guaranteed reliable by the
// time a disk is disappearing (especially on a surprise/physical removal), which would
// silently leave a card's "already reported" state stuck forever, so a later reinsertion
// of the SAME card would never notify again. Instead, DADiskGetBSDName (a lightweight
// accessor, not a description copy) reliably still works, and we use OUR OWN bookkeeping
// (populated at appeared time, when the description WAS reliable) to find which physical
// card group this BSD node belonged to.
- (void)handleDiskDisappeared:(DADiskRef)disk {
	const char *bsdName = DADiskGetBSDName(disk);
	if (!bsdName) return;
	NSString *bsd = [NSString stringWithUTF8String:bsdName];

	NSString *groupKey = self.bsdNameToGroupKey[bsd];
	[self.bsdNameToGroupKey removeObjectForKey:bsd];
	if (!groupKey) return;

	NSMutableSet *members = self.groupMembers[groupKey];
	[members removeObject:bsd];
	if (members.count > 0) return;   // other slices of this same card are still present

	// The whole card is gone now (no BSD nodes of this group remain) — re-arm it so a
	// future reinsertion is reported again.
	[self.groupMembers removeObjectForKey:groupKey];
	[self.pendingWholeDisks removeObject:groupKey];
	[self.reportedUnreadableDisks removeObject:groupKey];
	[self.groupUnreadablePartitions removeObjectForKey:groupKey];
	[self.groupsWithReadableSibling removeObject:groupKey];
	[self.groupSettleScheduled removeObject:groupKey];
}

// Records an unreadable partition for this physical card and, if a settle window isn't
// already running for it, starts one. We deliberately delay the actual notice (instead of
// firing immediately, as a first version of this feature did) because a multi-partition card
// can have SOME partitions that mount fine and others that don't (e.g. an Android card whose
// "android_meta"/"android_expand" partitions are never meant to mount, alongside a normal
// user-data partition that does) — reporting the very first unreadable partition immediately
// made the notice read like the partition's internal name WAS the device ("android_meta could
// not be read"), which is misleading. Waiting lets us classify the situation instead:
//   - nothing on the card is readable at all -> name the DEVICE, not a partition
//   - some partitions mounted fine, this one specifically didn't -> name that PARTITION,
//     phrased as "part of the device", not as if it were the whole device
- (void)scheduleUnreadableSettleForGroup:(NSString *)groupKey partitionName:(NSString *)partitionName {
	if ([self.reportedUnreadableDisks containsObject:groupKey]) return;

	NSMutableSet *pending = self.groupUnreadablePartitions[groupKey];
	if (!pending) { pending = [NSMutableSet set]; self.groupUnreadablePartitions[groupKey] = pending; }
	[pending addObject:partitionName];

	if ([self.groupSettleScheduled containsObject:groupKey]) return;   // timer already running
	[self.groupSettleScheduled addObject:groupKey];

	// TEMP (15-jul-2026, pedido del usuario): 1.0s mientras se decide el valor final — ver
	// project_pending_tests.md (el usuario percibió 2s/3s como demasiado largo).
	__weak HWGrowlVolumeMonitor *weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		HWGrowlVolumeMonitor *strongSelf = weakSelf;
		if (!strongSelf) return;
		[strongSelf.groupSettleScheduled removeObject:groupKey];
		[strongSelf finalizeUnreadableForGroup:groupKey];
	});
}

- (void)finalizeUnreadableForGroup:(NSString *)groupKey {
	// Already reported for this physical card since it was inserted — collapse any further
	// unreadable partitions on the SAME card into that one notice instead of repeating it.
	if ([self.reportedUnreadableDisks containsObject:groupKey]) return;
	NSSet *partitions = self.groupUnreadablePartitions[groupKey];
	if (![partitions count]) return;   // nothing actually pending (shouldn't normally happen)
	[self.reportedUnreadableDisks addObject:groupKey];

	BOOL hasReadableSibling = [self.groupsWithReadableSibling containsObject:groupKey];
	NSString *description;
	if (hasReadableSibling) {
		// Case 2: some part of this device DID mount fine — name the partition(s) that
		// didn't, phrased as a PART of the device rather than as the device itself.
		NSString *partsJoined = [[partitions allObjects] componentsJoinedByString:@", "];
		description = [NSString stringWithFormat:
			NSLocalizedString(@"Part of this device (%@) could not be read. It may be unformatted or use an unsupported file system.", @""),
			partsJoined];
	} else {
		// Case 1: nothing on this device could be read at all — name the DEVICE (groupKey
		// is the whole disk's own media name), not whichever partition happened first.
		description = [NSString stringWithFormat:
			NSLocalizedString(@"%@ could not be read. It may be unformatted or use an unsupported file system.", @""),
			groupKey];
	}

	NSData *icon = [[NSImage imageNamed:@"Device-Critical"] TIFFRepresentation];
	[delegate notifyWithName:@"VolumeNotReadable"
							 title:NSLocalizedString(@"Disk Not Readable", @"")
					 description:description
							  icon:icon
			  identifierString:groupKey
				  contextString:nil
							plugin:self];
	[self.groupUnreadablePartitions removeObjectForKey:groupKey];
}

// Cross-references a just-mounted volume's BSD device node against bsdNameToGroupKey (built
// up by handleDiskAppeared: for every disk node Disk Arbitration has ever seen, mountable or
// not) so we know "this physical card has at least one readable partition" even though the
// mount notification and the DiskArbitration unreadable-partition tracking are two entirely
// separate mechanisms.
- (void)noteReadableSiblingForMountedPath:(NSString *)path {
	if (![path length]) return;
	struct statfs sfs;
	if (statfs([path fileSystemRepresentation], &sfs) != 0) return;
	NSString *devPath = [NSString stringWithUTF8String:sfs.f_mntfromname];   // e.g. "/dev/disk4s1"
	NSString *bsd = [devPath lastPathComponent];                             // "disk4s1"
	if (![bsd length]) return;
	NSString *groupKey = self.bsdNameToGroupKey[bsd];
	if (!groupKey) return;
	[self.groupsWithReadableSibling addObject:groupKey];
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

	// F33: extra fields, mount-only — an unmounted path has no live filesystem left to stat.
	NSString *description = mounted ? NSLocalizedString(@"Click to open", @"Message body on a volume mount notification, clicking it opens the drive in finder") : nil;
	if (mounted) {
		BOOL showPath   = HWGVolumeBoolForKey(HWG_VOLUME_SHOW_PATH_KEY, YES);
		BOOL showFSType = HWGVolumeBoolForKey(HWG_VOLUME_SHOW_FSTYPE_KEY, YES);
		BOOL showSize   = HWGVolumeBoolForKey(HWG_VOLUME_SHOW_SIZE_KEY, YES);

		NSMutableArray<NSString*> *extraLines = [NSMutableArray array];
		if (showPath && [volume path]) [extraLines addObject:[volume path]];

		if (showFSType || showSize) {
			NSString *fsType = nil;
			unsigned long long totalBytes = 0;
			if (HWGCopyVolumeFileSystemInfo([volume path], &fsType, &totalBytes)) {
				if (showFSType && [fsType length]) {
					[extraLines addObject:[NSString stringWithFormat:NSLocalizedString(@"File system: %@", @""), fsType]];
				}
				if (showSize && totalBytes > 0) {
					NSString *sizeStr = [NSByteCountFormatter stringFromByteCount:(long long)totalBytes
																	   countStyle:NSByteCountFormatterCountStyleFile];
					[extraLines addObject:[NSString stringWithFormat:NSLocalizedString(@"Size: %@", @""), sizeStr]];
				}
			}
		}

		if ([extraLines count]) {
			NSString *extra = [extraLines componentsJoinedByString:@"\n"];
			description = description ? [description stringByAppendingFormat:@"\n%@", extra] : extra;
		}
	}

	[delegate notifyWithName:type
							 title:title
					 description:description
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
	NSString *devicePath = [[aNotification userInfo] objectForKey:@"NSDevicePath"];
	// Let the "Disk Not Readable" grouping know this physical card has (at least) one
	// partition that mounted fine — see noteReadableSiblingForMountedPath:.
	[self noteReadableSiblingForMountedPath:devicePath];
	//send notification
	VolumeInfo *volume = [VolumeInfo volumeInfoForMountWithPath:devicePath];
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
// F33: single generic handler for every per-field visibility checkbox — mirrors the other
// monitors' `fieldToggleChanged:`. Each checkbox's `identifier` carries the NSUserDefaults
// key it controls.
-(IBAction)fieldToggleChanged:(NSButton*)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
}

-(NSButton *)checkboxWithKey:(NSString *)key title:(NSString *)title defaultOn:(BOOL)defaultOn {
	NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(fieldToggleChanged:)];
	box.identifier = key;
	box.state = HWGVolumeBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = YES;   // frame-based layout, see preferencePane
	return box;
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	// The nib lives in THIS plugin's bundle, not the main app bundle. Its top-level view
	// (the ignore-list picker: a table + add/remove buttons) is assigned to `prefsView` via
	// the IBOutlet, which this method then wraps with the appended section below.
	[[NSBundle bundleForClass:[self class]] loadNibNamed:@"VolumeMonitorPrefs" owner:self topLevelObjects:nil];
	NSView *xibView = prefsView;

	// Unlike PowerMonitorPrefs.xib, this xib's declared frame (202x195) has NO baked-in
	// blank space — its scrollView + add/remove buttons genuinely occupy the full height
	// (confirmed in VolumeMonitorPrefs.xib: scrollView spans y=18..195, buttons at y=-1..20)
	// — so no "recover slack" trick is needed here; xibH can be reserved directly.
	CGFloat width = 380;
	CGFloat pad = 16;
	CGFloat xibW = 202, xibH = 195;
	CGFloat headerH = 18;
	CGFloat rowH = 24;
	NSArray<NSButton*> *rows = @[
		[self checkboxWithKey:HWG_VOLUME_SHOW_PATH_KEY   title:NSLocalizedString(@"Mount path", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_VOLUME_SHOW_FSTYPE_KEY title:NSLocalizedString(@"File system type", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_VOLUME_SHOW_SIZE_KEY   title:NSLocalizedString(@"Volume size", @"") defaultOn:YES],
	];
	// Build top-down (cursor starts at 0, grows downward) in a FLIPPED content view — see
	// HWGVolumeFlippedContentView above. This fixes two related problems at once:
	// (1) a plain non-flipped document view, when shorter than the visible clip area
	// (AppDelegate stretches the outer scroll view to match the container — see
	// `containerViewFrameDidChange:`), gets anchored to the BOTTOM of the clip by default,
	// leaving the slack as a gap ABOVE the content instead of below it (reported by the
	// user: "Notification fields" appeared floating with a gap above it, not flush at the
	// top like every other monitor's pane). A flipped view anchors to the TOP instead.
	// (2) it also sidesteps the historical "pre-computed totalHeight drifts from the real
	// content extent" class of bug (already hit once in Power Monitor's pane) — height is
	// simply wherever the cursor ends up, never a separately hand-computed guess.
	NSView *combined = [[HWGVolumeFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, width, 1)];
	CGFloat cursor = 0;

	// Notification fields first, "Ignored Drives" list last (user's requested order).
	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notification fields", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = YES;
	header.frame = NSMakeRect(pad, cursor, width - 2 * pad, headerH);
	[combined addSubview:header];
	cursor += headerH + 10;

	for (NSButton *row in rows) {
		row.frame = NSMakeRect(pad, cursor, width - 2 * pad, rowH);
		[combined addSubview:row];
		cursor += rowH + 10;
	}
	cursor += 6;

	// The xib's internal Auto Layout (scrollView/tableView pinned to xibView's edges) can
	// grow xibView taller than its declared 195pt — a fixed-size, hard-clipping wrapper
	// decouples the checkbox layout math from whatever xibView's internal content wants to
	// do (found when "Ignored Drives" was moved below the checkboxes: without this, the
	// list's overflow grew upward and silently covered them).
	NSView *xibWrapper = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, xibW, xibH)];
	xibWrapper.wantsLayer = YES;
	xibWrapper.layer.masksToBounds = YES;
	xibView.translatesAutoresizingMaskIntoConstraints = YES;
	xibView.frame = NSMakeRect(0, 0, xibW, xibH);
	[xibWrapper addSubview:xibView];

	xibWrapper.frame = NSMakeRect(0, cursor, xibW, xibH);
	[combined addSubview:xibWrapper];
	cursor += xibH + pad;

	combined.frame = NSMakeRect(0, 0, width, cursor);

	// AppDelegate force-resizes whatever `preferencePane` returns to match the container's
	// real frame — wrap `combined` in a scroll view whose OUTER frame is free to stretch,
	// while `combined` itself keeps its own fixed (flipped, top-anchored) content.
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, width, cursor)];
	scroll.hasVerticalScroller = YES;
	scroll.autohidesScrollers = YES;
	scroll.drawsBackground = NO;
	scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	scroll.documentView = combined;

	prefsView = scroll;
	return prefsView;
}

#pragma mark HWGrowlPluginNotifierProtocol

-(NSArray*)noteNames {
	return [NSArray arrayWithObjects:@"VolumeMounted", @"VolumeUnmounted", @"VolumeNotReadable", nil];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Volume Mounted", @""), @"VolumeMounted",
			  NSLocalizedString(@"Volume Unmounted", @""), @"VolumeUnmounted",
			  NSLocalizedString(@"Disk Not Readable", @""), @"VolumeNotReadable", nil];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Sent when a volume is mounted", @""), @"VolumeMounted",
			  NSLocalizedString(@"Sent when a volume is unmounted", @""), @"VolumeUnmounted",
			  NSLocalizedString(@"Sent when inserted media can't be read/mounted", @""), @"VolumeNotReadable", nil];
}
-(NSArray*)defaultNotifications {
	return [NSArray arrayWithObjects:@"VolumeMounted", @"VolumeUnmounted", @"VolumeNotReadable", nil];
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
