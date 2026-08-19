//
//  HWGrowlCameraMonitor.m
//  HardwareGrowler
//

// compile with ARC: -fobjc-arc
#import "HWGrowlCameraMonitor.h"
#import "HWGIconOverrideStore.h"
#import "HWGIconPickerView.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>       // shares its transport-type FourCharCode space with AVCaptureDevice.transportType
#import <CoreMediaIO/CoreMediaIO.h>
#import <CoreMedia/CoreMedia.h>

// F19: same philosophy as Audio Monitor —
//   1. Connect/disconnect — only for transports NOT already covered by USB/Bluetooth Monitor
//      (AVCaptureDevice.transportType reuses the exact same FourCharCode constants as
//      CoreAudio's kAudioDeviceTransportType*, so the same comparison works verbatim).
//   2. An extra axis no other monitor has: whether the camera is ACTIVELY IN USE by any app
//      right now (kCMIODevicePropertyDeviceIsRunningSomewhere via CoreMediaIO) — a genuine
//      privacy-relevant signal, the same fact macOS's own green/orange camera-in-use
//      indicator dot reflects. Reading this property does NOT require camera/TCC
//      permission — it's hardware-state observation, not frame capture (the same technique
//      used by camera-privacy-watchdog utilities).

#define HWG_CAMERA_SHOW_TRANSPORT_KEY   @"HWGCameraShowTransport"
#define HWG_CAMERA_SHOW_RESOLUTION_KEY  @"HWGCameraShowResolution"
#define HWG_CAMERA_SHOW_POSITION_KEY    @"HWGCameraShowPosition"
// 13-ago-2026: Continuity Camera (iPhone used as a Mac's webcam, macOS 13+) and Center Stage
// (auto-framing, macOS 12.3+) — both pending validation against real hardware (a paired iPhone),
// see TODO.md. Written now so the fields are ready the moment that hardware is available.
#define HWG_CAMERA_SHOW_CONTINUITY_KEY  @"HWGCameraShowContinuity"
#define HWG_CAMERA_SHOW_CENTERSTAGE_KEY @"HWGCameraShowCenterStage"
#define HWG_CAMERA_NOTIFY_CONNECT_KEY   @"HWGCameraNotifyConnect"
#define HWG_CAMERA_NOTIFY_IN_USE_KEY    @"HWGCameraNotifyInUse"
// Per-row refinement on top of HWG_CAMERA_NOTIFY_IN_USE_KEY above (the master "In Use" toggle):
// lets the user silence just one direction (e.g. keep "started" but not "stopped").
#define HWG_CAMERA_NOTIFY_INUSE_ROW_KEY @"HWGCameraNotifyInUseRow"
#define HWG_CAMERA_NOTIFY_IDLE_ROW_KEY  @"HWGCameraNotifyIdleRow"
// Final API audit (18-ago-2026) — Portrait Effect/Studio Light/Reactions/Background Replacement
// are Control Center video-effect toggles, exposed as KVO-observable CLASS properties on
// AVCaptureDevice (system-wide state, not per-camera) — same class-level KVO pattern Apple's own
// sample code uses ([AVCaptureDevice addObserver:...]), works because Class objects fall back to
// NSObject's instance-method KVO machinery via the root metaclass. Each gets its own notify key
// (all OFF by default — frequent Control Center toggles the user may not want surfaced).
#define HWG_CAMERA_SHOW_PORTRAIT_EFFECT_KEY @"HWGCameraShowPortraitEffect"
#define HWG_CAMERA_SHOW_STUDIO_LIGHT_KEY    @"HWGCameraShowStudioLight"
#define HWG_CAMERA_SHOW_REACTIONS_KEY       @"HWGCameraShowReactions"
#define HWG_CAMERA_SHOW_BG_REPLACEMENT_KEY  @"HWGCameraShowBackgroundReplacement"
// Final API audit (18-ago-2026) — +[AVCaptureDevice systemPreferredCamera], macOS 13+, also
// class-level KVO-observable. OFF by default: most Macs only have one candidate camera, so this
// is mostly interesting with more than one connected.
#define HWG_CAMERA_SHOW_SYSTEM_PREFERRED_KEY @"HWGCameraShowSystemPreferred"
// Final API audit (18-ago-2026) — max frame rate at the same "best supported format" already
// used for HWG_CAMERA_SHOW_RESOLUTION_KEY above (AVFrameRateRange.maxFrameRate).
#define HWG_CAMERA_SHOW_MAX_FRAMERATE_KEY   @"HWGCameraShowMaxFrameRate"

static BOOL HWGCameraBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

@interface HWGrowlCameraMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, strong) NSView *prefsView;
@property (nonatomic, strong) NSMutableSet<NSString *> *runningCameraUIDs;   // cameras currently "in use" (any app) — raw, updated every callback
// BUG FIX (06-ago-2026): confirmed live (user screenshot showing Started -> Stopped -> Started
// for a single camera activation) that opening a video call briefly cycles CoreMediaIO's
// kCMIODevicePropertyDeviceIsRunningSomewhere itself during stream setup — the same class of
// flicker Audio Monitor's microphone "in use" signal has (see that file's 05-ago-2026 fix).
// `lastNotifiedCameraUIDs` is the notified baseline (what the user was actually last told).
//
// BUG FIX (06-ago-2026, follow-up): a plain trailing debounce (delay EVERY notification by
// kCameraInUseDebounceInterval, like Audio Monitor's mic fix) made "Started" itself feel
// laggy — confirmed by user feedback ("la notificacion esta lenta, antes no era asi") — even
// though "Started" was never the flickery half of the burst. Only "Stopped" needs the wait
// (to see whether it's genuine or the device is about to flicker back on): "Started" now
// fires the instant it's first observed, matching pre-fix responsiveness, while each stopped
// UID gets its OWN delayed re-check in `pendingStopBlocksByUID`, cancelled if that same UID
// shows up running again before it fires.
@property (nonatomic, strong) NSMutableSet<NSString *> *lastNotifiedCameraUIDs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, dispatch_block_t> *pendingStopBlocksByUID;
// MUST be `copy`, not `assign` — `assign` doesn't trigger ARC's copy-to-heap for block
// literals, so the block stays STACK-allocated and becomes a dangling pointer the moment
// -init's stack frame returns. Every later use (any subsequent CMIOObjectAddPropertyListenerBlock/
// RemovePropertyListenerBlock call passing this property) then reads freed/garbage memory —
// this was the real cause of the SIGSEGV inside CMIO's internal `_Block_copy` (confirmed via
// crash log, 22-jul-2026: crashed on a plain CONNECT event, not just disconnect, ruling out
// the earlier reentrancy theory as the sole cause — a dangling block pointer explains
// crashing unpredictably on ANY subsequent listener add/remove, regardless of connect vs
// disconnect).
@property (nonatomic, copy) CMIOObjectPropertyListenerBlock inUseListenerBlock;
@property (nonatomic, copy) CMIOObjectPropertyListenerBlock deviceListChangedBlock;
// CMIODeviceIDs that currently have an -inUseListenerBlock attached — tracked explicitly so
// -unregisterInUseListeners removes listeners from the exact IDs they were added to, not
// whatever -allCMIODeviceIDs happens to return NOW (which, when called from the device-list-
// changed callback itself, may already reflect devices that just appeared/disappeared).
@property (nonatomic, strong) NSMutableSet<NSNumber *> *deviceIDsWithInUseListener;

@end

@implementation HWGrowlCameraMonitor

@synthesize delegate;
@synthesize prefsView;
@synthesize runningCameraUIDs;
@synthesize lastNotifiedCameraUIDs;
@synthesize pendingStopBlocksByUID;
@synthesize inUseListenerBlock;
@synthesize deviceListChangedBlock;
@synthesize deviceIDsWithInUseListener;

static const NSTimeInterval kCameraInUseDebounceInterval = 1.0;

-(id)init {
	self = [super init];
	if (self) {
		runningCameraUIDs = [NSMutableSet set];
		lastNotifiedCameraUIDs = [NSMutableSet set];
		pendingStopBlocksByUID = [NSMutableDictionary dictionary];
		deviceIDsWithInUseListener = [NSMutableSet set];

		[[NSNotificationCenter defaultCenter] addObserver:self
												  selector:@selector(deviceConnected:)
													  name:AVCaptureDeviceWasConnectedNotification
													object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self
												  selector:@selector(deviceDisconnected:)
													  name:AVCaptureDeviceWasDisconnectedNotification
													object:nil];

		// Baseline the "in use" state silently at launch, then start listening for changes —
		// same "no notification for the pre-existing state" convention every other monitor
		// follows.
		[self refreshRunningStateForAllDevicesNotifying:NO];
		[self registerInUseListeners];

		// Final API audit (18-ago-2026) — class-level KVO on the 4 Control Center video-effect
		// toggles. Each guarded by its own @available since they were introduced across 3
		// different macOS releases (12/13/14/15). No baseline notification at launch — same
		// "silent baseline" convention as the in-use signal above, these only fire on CHANGE.
		[AVCaptureDevice addObserver:self forKeyPath:@"portraitEffectEnabled" options:0 context:NULL];
		if (@available(macOS 13.0, *)) {
			[AVCaptureDevice addObserver:self forKeyPath:@"studioLightEnabled" options:0 context:NULL];
		}
		if (@available(macOS 14.0, *)) {
			[AVCaptureDevice addObserver:self forKeyPath:@"reactionEffectsEnabled" options:0 context:NULL];
		}
		if (@available(macOS 15.0, *)) {
			[AVCaptureDevice addObserver:self forKeyPath:@"backgroundReplacementEnabled" options:0 context:NULL];
		}

		// -registerInUseListeners only attaches to CMIODeviceIDs that exist AT THIS MOMENT.
		// A camera plugged in AFTER launch gets a CMIODeviceID that was never in that list, so
		// it would silently never fire "in use" changes — confirmed live (19-jul-2026): a USB
		// webcam connected mid-session correctly reported Connected/Disconnected (that's
		// AVCaptureDevice's own notification, always current) but never "Started/Stopped
		// Being Used" (the CMIO listener, which had nothing attached to its ID). Listening for
		// the CMIO device LIST to change and re-registering closes that gap.
		__weak typeof(self) weakSelf = self;
		deviceListChangedBlock = ^(UInt32 n, const CMIOObjectPropertyAddress *addrs) {
			(void)n; (void)addrs;
			// CRASH FIX (confirmed via crash log, 22-jul-2026): calling
			// CMIOObjectRemovePropertyListenerBlock synchronously from INSIDE the CMIO device-
			// list-changed callback itself is an unsafe reentrant call into CoreMediaIO's
			// internal DAL (crashed in CMIO::DAL::PropertyListener::PropertyListener via
			// _Block_copy, SIGSEGV) — happened specifically when a camera was disconnected,
			// i.e. exactly the moment its CMIODeviceID becomes stale. Deferring to the next
			// run-loop turn via dispatch_async lets CMIO finish its own internal teardown
			// first, so we're no longer inside its call stack when we touch listeners.
			dispatch_async(dispatch_get_main_queue(), ^{
				[weakSelf unregisterInUseListeners];
				[weakSelf registerInUseListeners];
				[weakSelf refreshRunningStateForAllDevicesNotifying:YES];
			});
		};
		CMIOObjectPropertyAddress devicesAddress = { kCMIOHardwarePropertyDevices, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
		CMIOObjectAddPropertyListenerBlock(kCMIOObjectSystemObject, &devicesAddress, dispatch_get_main_queue(), deviceListChangedBlock);
	}
	return self;
}

-(void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	for (dispatch_block_t block in pendingStopBlocksByUID.allValues) dispatch_block_cancel(block);
	[self unregisterInUseListeners];
	if (deviceListChangedBlock) {
		CMIOObjectPropertyAddress devicesAddress = { kCMIOHardwarePropertyDevices, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
		CMIOObjectRemovePropertyListenerBlock(kCMIOObjectSystemObject, &devicesAddress, dispatch_get_main_queue(), deviceListChangedBlock);
	}
	[AVCaptureDevice removeObserver:self forKeyPath:@"portraitEffectEnabled"];
	if (@available(macOS 13.0, *)) {
		[AVCaptureDevice removeObserver:self forKeyPath:@"studioLightEnabled"];
	}
	if (@available(macOS 14.0, *)) {
		[AVCaptureDevice removeObserver:self forKeyPath:@"reactionEffectsEnabled"];
	}
	if (@available(macOS 15.0, *)) {
		[AVCaptureDevice removeObserver:self forKeyPath:@"backgroundReplacementEnabled"];
	}
}

#pragma mark Video effect KVO (final API audit, 18-ago-2026)

-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
	if (![object isEqual:[AVCaptureDevice class]]) return;

	NSString *noteName = nil, *title = nil, *key = nil;
	BOOL enabled = NO;
	if ([keyPath isEqualToString:@"portraitEffectEnabled"]) {
		noteName = @"CameraPortraitEffectChanged"; title = NSLocalizedString(@"Portrait Effect", @""); key = HWG_CAMERA_SHOW_PORTRAIT_EFFECT_KEY;
		enabled = [AVCaptureDevice isPortraitEffectEnabled];
	} else if ([keyPath isEqualToString:@"studioLightEnabled"]) {
		noteName = @"CameraStudioLightChanged"; title = NSLocalizedString(@"Studio Light", @""); key = HWG_CAMERA_SHOW_STUDIO_LIGHT_KEY;
		if (@available(macOS 13.0, *)) enabled = [AVCaptureDevice isStudioLightEnabled];
	} else if ([keyPath isEqualToString:@"reactionEffectsEnabled"]) {
		noteName = @"CameraReactionsChanged"; title = NSLocalizedString(@"Reactions", @""); key = HWG_CAMERA_SHOW_REACTIONS_KEY;
		if (@available(macOS 14.0, *)) enabled = [AVCaptureDevice reactionEffectsEnabled];
	} else if ([keyPath isEqualToString:@"backgroundReplacementEnabled"]) {
		noteName = @"CameraBackgroundReplacementChanged"; title = NSLocalizedString(@"Background Replacement", @""); key = HWG_CAMERA_SHOW_BG_REPLACEMENT_KEY;
		if (@available(macOS 15.0, *)) enabled = [AVCaptureDevice isBackgroundReplacementEnabled];
	} else {
		return;
	}

	if (!HWGCameraBoolForKey(key, NO)) return;

	[delegate notifyWithName:noteName
						 title:[NSString stringWithFormat:NSLocalizedString(@"%@ %@", @""), title, enabled ? NSLocalizedString(@"Enabled", @"") : NSLocalizedString(@"Disabled", @"")]
					   description:NSLocalizedString(@"Control Center video effect changed system-wide", @"")
						  icon:[self iconDataInUse:NO]
			  identifierString:noteName
				 contextString:nil
						plugin:self];
}

#pragma mark Transport filtering (shared logic/constants with Audio Monitor)

-(BOOL)transportAlreadyCoveredByAnotherMonitor:(int32_t)transport {
	return transport == kAudioDeviceTransportTypeUSB
		|| transport == kAudioDeviceTransportTypeBluetooth
		|| transport == kAudioDeviceTransportTypeBluetoothLE;
}

-(NSString *)labelForTransportType:(int32_t)transport {
	switch (transport) {
		case kAudioDeviceTransportTypeBuiltIn:      return NSLocalizedString(@"Built-in", @"");
		case kAudioDeviceTransportTypeUSB:           return NSLocalizedString(@"USB", @"");
		case kAudioDeviceTransportTypeBluetooth:     return NSLocalizedString(@"Bluetooth", @"");
		case kAudioDeviceTransportTypeBluetoothLE:   return NSLocalizedString(@"Bluetooth LE", @"");
		case kAudioDeviceTransportTypeThunderbolt:   return NSLocalizedString(@"Thunderbolt", @"");
		case kAudioDeviceTransportTypeAirPlay:       return NSLocalizedString(@"AirPlay/Continuity", @"");
		case kAudioDeviceTransportTypeVirtual:       return NSLocalizedString(@"Virtual", @"");
		default:                                      return NSLocalizedString(@"Unknown", @"");
	}
}

#pragma mark Connect/disconnect

-(void)deviceConnected:(NSNotification *)note {
	AVCaptureDevice *device = note.object;
	if (![device hasMediaType:AVMediaTypeVideo]) return;   // this notification also fires for audio-only devices
	if (!HWGCameraBoolForKey(HWG_CAMERA_NOTIFY_CONNECT_KEY, YES)) return;

	int32_t transport = device.transportType;
	if ([self transportAlreadyCoveredByAnotherMonitor:transport]) return;

	NSMutableArray<NSString *> *lines = [NSMutableArray array];
	if (HWGCameraBoolForKey(HWG_CAMERA_SHOW_TRANSPORT_KEY, YES)) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Transport:\t%@", @""), [self labelForTransportType:transport]]];
	}
	if (HWGCameraBoolForKey(HWG_CAMERA_SHOW_RESOLUTION_KEY, YES)) {
		// The device's best supported format, not necessarily what an in-progress capture
		// session is actually using right now — this fires at connect time, before any app
		// has necessarily opened the camera.
		CMVideoDimensions best = {0, 0};
		AVCaptureDeviceFormat *bestFormat = nil;
		for (AVCaptureDeviceFormat *format in device.formats) {
			CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
			if ((int64_t)dims.width * dims.height > (int64_t)best.width * best.height) { best = dims; bestFormat = format; }
		}
		if (best.width > 0) {
			[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Max resolution:\t%dx%d", @""), best.width, best.height]];
		}
		// Final API audit (18-ago-2026) — highest maxFrameRate across the SAME best-resolution
		// format's supported ranges (a format can offer several frame rate ranges, e.g. 24-30fps).
		if (HWGCameraBoolForKey(HWG_CAMERA_SHOW_MAX_FRAMERATE_KEY, NO) && bestFormat) {
			double maxRate = 0;
			for (AVFrameRateRange *range in bestFormat.videoSupportedFrameRateRanges) {
				if (range.maxFrameRate > maxRate) maxRate = range.maxFrameRate;
			}
			if (maxRate > 0) {
				[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Max frame rate:\t%.0f fps", @""), maxRate]];
			}
		}
	}
	if (HWGCameraBoolForKey(HWG_CAMERA_SHOW_CONTINUITY_KEY, YES)) {
		if (@available(macOS 13.0, *)) {
			if (device.isContinuityCamera) {
				[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Continuity Camera:\t%@", @""), NSLocalizedString(@"Yes", @"")]];
				if (device.companionDeskViewCamera) {
					[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Desk View companion:\t%@", @""), NSLocalizedString(@"Yes", @"")]];
				}
			}
		}
	}
	if (HWGCameraBoolForKey(HWG_CAMERA_SHOW_CENTERSTAGE_KEY, YES)) {
		if (@available(macOS 12.3, *)) {
			if (device.isCenterStageActive) {
				[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Center Stage:\t%@", @""), NSLocalizedString(@"Active", @"")]];
			}
		}
	}
	// Added 17-ago-2026 (feedback del usuario) — AVCaptureDevice.position, public, no
	// permission needed beyond what's already required to enumerate devices. OFF by default:
	// most Macs only have one built-in camera, so this is mostly interesting with an external
	// webcam attached (which reports .unspecified, same as most third-party USB cameras).
	if (HWGCameraBoolForKey(HWG_CAMERA_SHOW_POSITION_KEY, NO)) {
		NSString *positionLabel = nil;
		switch (device.position) {
			case AVCaptureDevicePositionFront: positionLabel = NSLocalizedString(@"Front", @""); break;
			case AVCaptureDevicePositionBack:  positionLabel = NSLocalizedString(@"Back", @""); break;
			default:                           positionLabel = NSLocalizedString(@"Unspecified (typical for external webcams)", @""); break;
		}
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Position:\t%@", @""), positionLabel]];
	}
	// Final API audit (18-ago-2026) — +[AVCaptureDevice systemPreferredCamera], macOS 13+.
	if (HWGCameraBoolForKey(HWG_CAMERA_SHOW_SYSTEM_PREFERRED_KEY, NO)) {
		if (@available(macOS 13.0, *)) {
			AVCaptureDevice *preferred = [AVCaptureDevice systemPreferredCamera];
			if (preferred && [preferred.uniqueID isEqualToString:device.uniqueID]) {
				[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"System Preferred Camera:\t%@", @""), NSLocalizedString(@"Yes", @"")]];
			}
		}
	}
	NSString *description = [lines count] ? [NSString stringWithFormat:@"%@\n%@", device.localizedName, [lines componentsJoinedByString:@"\n"]] : device.localizedName;

	[delegate notifyWithName:@"CameraConnected"
						 title:NSLocalizedString(@"Camera Connected", @"")
					   description:description
						  icon:[self iconDataInUse:NO]
			  identifierString:[NSString stringWithFormat:@"HWGrowlCamera-%@", device.uniqueID]
				 contextString:nil
						plugin:self];
}

-(void)deviceDisconnected:(NSNotification *)note {
	AVCaptureDevice *device = note.object;
	if (![device hasMediaType:AVMediaTypeVideo]) return;
	if (!HWGCameraBoolForKey(HWG_CAMERA_NOTIFY_CONNECT_KEY, YES)) return;
	if ([self transportAlreadyCoveredByAnotherMonitor:device.transportType]) return;

	[runningCameraUIDs removeObject:device.uniqueID];
	[lastNotifiedCameraUIDs removeObject:device.uniqueID];   // avoid a stray "stopped" once the debounce settles
	dispatch_block_t pendingStop = pendingStopBlocksByUID[device.uniqueID];
	if (pendingStop) {
		dispatch_block_cancel(pendingStop);
		[pendingStopBlocksByUID removeObjectForKey:device.uniqueID];
	}
	[delegate notifyWithName:@"CameraDisconnected"
						 title:NSLocalizedString(@"Camera Disconnected", @"")
					   description:device.localizedName
						  icon:[self iconDataInUse:NO]
			  identifierString:[NSString stringWithFormat:@"HWGrowlCamera-%@", device.uniqueID]
				 contextString:nil
						plugin:self];
}

#pragma mark "In use" (CoreMediaIO)

// Maps an AVCaptureDevice.uniqueID to its CMIODeviceID by matching kCMIODevicePropertyDeviceUID
// across every currently-enumerated CMIO device — CoreMediaIO and AVFoundation identify the
// same physical camera by the same UID string, but use separate object-ID spaces.
-(NSArray<NSNumber *> *)allCMIODeviceIDs {
	CMIOObjectPropertyAddress address = { kCMIOHardwarePropertyDevices, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
	UInt32 size = 0;
	if (CMIOObjectGetPropertyDataSize(kCMIOObjectSystemObject, &address, 0, NULL, &size) != kCMIOHardwareNoError || size == 0) return @[];
	UInt32 count = size / (UInt32)sizeof(CMIODeviceID);
	CMIODeviceID *deviceIDs = malloc(size);
	if (!deviceIDs) return @[];
	NSMutableArray<NSNumber *> *result = [NSMutableArray array];
	if (CMIOObjectGetPropertyData(kCMIOObjectSystemObject, &address, 0, NULL, size, &size, deviceIDs) == kCMIOHardwareNoError) {
		for (UInt32 i = 0; i < count; i++) [result addObject:@(deviceIDs[i])];
	}
	free(deviceIDs);
	return result;
}

-(NSString *)uidForCMIODevice:(CMIODeviceID)deviceID {
	CMIOObjectPropertyAddress address = { kCMIODevicePropertyDeviceUID, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
	CFStringRef uid = NULL;
	UInt32 size = sizeof(uid);
	if (CMIOObjectGetPropertyData(deviceID, &address, 0, NULL, size, &size, &uid) != kCMIOHardwareNoError || !uid) return nil;
	return CFBridgingRelease(uid);
}

-(BOOL)isCMIODeviceRunningSomewhere:(CMIODeviceID)deviceID {
	CMIOObjectPropertyAddress address = { kCMIODevicePropertyDeviceIsRunningSomewhere, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
	UInt32 isRunning = 0;
	UInt32 size = sizeof(isRunning);
	if (!CMIOObjectHasProperty(deviceID, &address)) return NO;
	CMIOObjectGetPropertyData(deviceID, &address, 0, NULL, size, &size, &isRunning);
	return isRunning != 0;
}

-(void)registerInUseListeners {
	if (!inUseListenerBlock) {
		__weak typeof(self) weakSelf = self;
		inUseListenerBlock = ^(UInt32 n, const CMIOObjectPropertyAddress *addrs) {
			(void)n; (void)addrs;
			[weakSelf refreshRunningStateForAllDevicesNotifying:YES];
		};
	}
	CMIOObjectPropertyAddress address = { kCMIODevicePropertyDeviceIsRunningSomewhere, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
	for (NSNumber *deviceID in [self allCMIODeviceIDs]) {
		if ([deviceIDsWithInUseListener containsObject:deviceID]) continue;   // already listening
		if (CMIOObjectHasProperty([deviceID unsignedIntValue], &address)) {
			CMIOObjectAddPropertyListenerBlock([deviceID unsignedIntValue], &address, dispatch_get_main_queue(), inUseListenerBlock);
			[deviceIDsWithInUseListener addObject:deviceID];
		}
	}
}

-(void)unregisterInUseListeners {
	if (!inUseListenerBlock) return;
	CMIOObjectPropertyAddress address = { kCMIODevicePropertyDeviceIsRunningSomewhere, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
	// Only call CMIOObjectRemovePropertyListenerBlock for IDs that are STILL in the current
	// device list — a device that just disconnected (the common reason this runs at all) has
	// an already-torn-down CMIODeviceID, and removing a listener from a stale/dead ID is what
	// crashed (confirmed via crash log, 22-jul-2026: SIGSEGV inside CoreMediaIO's internal
	// PropertyListener teardown). For an ID that's gone, there's nothing left to remove a
	// listener FROM — CMIO already discarded it along with the device — so we just drop our
	// own bookkeeping for it instead of calling into the framework at all.
	NSSet<NSNumber *> *currentIDs = [NSSet setWithArray:[self allCMIODeviceIDs]];
	for (NSNumber *deviceID in deviceIDsWithInUseListener) {
		if ([currentIDs containsObject:deviceID]) {
			CMIOObjectRemovePropertyListenerBlock([deviceID unsignedIntValue], &address, dispatch_get_main_queue(), inUseListenerBlock);
		}
	}
	[deviceIDsWithInUseListener removeAllObjects];
}

// Recomputes which cameras are currently "in use". "Started" fires the instant it's first
// observed — no delay, matching pre-fix responsiveness, since that's the privacy-relevant
// signal users watch for and it was never the flickery half of the CMIO burst. "Stopped" is
// held for `kCameraInUseDebounceInterval` before being believed, so a camera that flickers
// off and immediately back on (see the 06-ago-2026 fix note above) never gets a spurious
// Stopped/Started pair — only a genuine, held-stable stop is announced.
// `shouldNotify:NO` is used only for the initial silent baseline (at launch) — same pattern
// as every other monitor's baseline-then-live-diff approach.
-(void)refreshRunningStateForAllDevicesNotifying:(BOOL)shouldNotify {
	NSMutableSet<NSString *> *currentlyRunning = [NSMutableSet set];
	for (NSNumber *deviceIDNumber in [self allCMIODeviceIDs]) {
		CMIODeviceID deviceID = [deviceIDNumber unsignedIntValue];
		NSString *uid = [self uidForCMIODevice:deviceID];
		if (!uid) continue;
		if ([self isCMIODeviceRunningSomewhere:deviceID]) [currentlyRunning addObject:uid];
	}
	self.runningCameraUIDs = currentlyRunning;

	if (!shouldNotify) {
		// Silent baseline (launch) — this IS the notified baseline going forward.
		self.lastNotifiedCameraUIDs = [currentlyRunning mutableCopy];
		return;
	}

	BOOL wantsInUse = HWGCameraBoolForKey(HWG_CAMERA_NOTIFY_IN_USE_KEY, YES);

	// A UID running again cancels its pending "stopped" re-check — it never really stopped
	// from the user's perspective (they were already told "Started" and nothing since
	// contradicted that), so there's nothing new to announce.
	for (NSString *uid in currentlyRunning) {
		dispatch_block_t pendingStop = self.pendingStopBlocksByUID[uid];
		if (pendingStop) {
			dispatch_block_cancel(pendingStop);
			[self.pendingStopBlocksByUID removeObjectForKey:uid];
		}
	}

	// Genuinely new starts (not already-notified, no cancelled-pending-stop above implies this
	// is really new — a UID with a pending stop stays in lastNotifiedCameraUIDs throughout, so
	// it's excluded here already) get announced immediately.
	for (NSString *uid in currentlyRunning) {
		if ([self.lastNotifiedCameraUIDs containsObject:uid]) continue;
		if (wantsInUse) [self notifyCameraInUseChangedForUID:uid running:YES];
		[self.lastNotifiedCameraUIDs addObject:uid];
	}

	// UIDs that just dropped out get a delayed re-check rather than an immediate "Stopped" —
	// skip any that already have one scheduled from an earlier drop in this same burst.
	NSMutableSet<NSString *> *droppedOut = [self.lastNotifiedCameraUIDs mutableCopy];
	[droppedOut minusSet:currentlyRunning];
	__weak typeof(self) weakSelf = self;
	for (NSString *uid in droppedOut) {
		if (self.pendingStopBlocksByUID[uid]) continue;
		dispatch_block_t stopBlock = dispatch_block_create(0, ^{
			typeof(self) strongSelf = weakSelf;
			if (!strongSelf) return;
			if (![strongSelf.runningCameraUIDs containsObject:uid]) {
				if (HWGCameraBoolForKey(HWG_CAMERA_NOTIFY_IN_USE_KEY, YES)) {
					[strongSelf notifyCameraInUseChangedForUID:uid running:NO];
				}
				[strongSelf.lastNotifiedCameraUIDs removeObject:uid];
			}
			[strongSelf.pendingStopBlocksByUID removeObjectForKey:uid];
		});
		self.pendingStopBlocksByUID[uid] = stopBlock;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCameraInUseDebounceInterval * NSEC_PER_SEC)),
		               dispatch_get_main_queue(), stopBlock);
	}
}

-(void)notifyCameraInUseChangedForUID:(NSString *)uid running:(BOOL)nowRunning {
	NSString *rowKey = nowRunning ? HWG_CAMERA_NOTIFY_INUSE_ROW_KEY : HWG_CAMERA_NOTIFY_IDLE_ROW_KEY;
	if (!HWGCameraBoolForKey(rowKey, YES)) return;

	AVCaptureDevice *device = [AVCaptureDevice deviceWithUniqueID:uid];
	NSString *name = device.localizedName ?: NSLocalizedString(@"Camera", @"");
	// Started/Stopped use a distinct identifierString per transition (not just per device) —
	// see F19/05-ago-2026 note: a stable per-device identifier would make
	// UNUserNotificationCenter treat "Stopped" as an update to the still-displayed "Started"
	// banner instead of a fresh one.
	[delegate notifyWithName:@"CameraInUseChanged"
						 title:nowRunning ? NSLocalizedString(@"Camera Started Being Used", @"") : NSLocalizedString(@"Camera Stopped Being Used", @"")
					   description:name
						  icon:[self iconDataInUse:nowRunning]
				  identifierString:[NSString stringWithFormat:@"HWGrowlCameraInUse-%@-%@", uid, nowRunning ? @"started" : @"stopped"]
					 contextString:nil
							plugin:self];
}

#pragma mark Icon

// Designed PNGs (Assets.xcassets) — replaces the hand-drawn single-blue outline glyph this
// used to render at runtime. Redesigned with more color variety per the user's feedback
// (coral body + blue lens ring + yellow highlight) instead of the single blue tone shared
// with Bluetooth Monitor. The in-use/not-in-use distinction that the old glyph conveyed via
// a filled-vs-outlined lens center is preserved as two separate PNGs (a filled red "REC"
// dot + matching indicator light for in-use, a plain yellow highlight otherwise).
-(NSImage *)cameraIconInUse:(BOOL)inUse {
	return HWGResolveIconNamed(inUse ? @"CameraMonitor-Icon-InUse" : @"CameraMonitor-Icon");
}

-(NSData *)iconDataInUse:(BOOL)inUse {
	return HWGResolveIconDataNamed(inUse ? @"CameraMonitor-Icon-InUse" : @"CameraMonitor-Icon");
}

#pragma mark HWGrowlPluginProtocol

-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Camera Monitor", @"");
}
-(NSImage*)preferenceIcon {
	// Resolved fresh every call (not cached) since this is user-customizable — see the same
	// note on AudioMonitor's -preferenceIcon. Own dedicated default name ("-Module"),
	// separate from -cameraIconInUse:'s "CameraMonitor-Icon" — customizing one must never
	// silently change the other.
	return HWGResolveIconNamed(@"CameraMonitor-Icon-Module");
}

-(IBAction)fieldToggleChanged:(NSButton*)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
}

-(NSButton *)checkboxWithKey:(NSString *)key title:(NSString *)title defaultOn:(BOOL)defaultOn {
	NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(fieldToggleChanged:)];
	box.identifier = key;
	box.state = HWGCameraBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	return box;
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	// BUG FIX (18-ago-2026): was 230 — same fixed-constant risk class, bumped after adding 6 rows
	// (Max frame rate/System Preferred/Portrait Effect/Studio Light/Reactions/Background
	// Replacement). Auto Layout's top-anchor chain below drives the real size regardless — see
	// the Gamepad Monitor note on this same constant class.
	NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 560, 420)];
	tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 420)];

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notification fields", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;

	NSArray<NSButton*> *rows = @[
		[self checkboxWithKey:HWG_CAMERA_SHOW_TRANSPORT_KEY title:NSLocalizedString(@"Transport type (USB, Bluetooth, Thunderbolt, AirPlay/Continuity [iPhone as camera], Built-in, Virtual)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_CAMERA_SHOW_RESOLUTION_KEY title:NSLocalizedString(@"Max resolution", @"") defaultOn:YES],
		// Added 17-ago-2026 — AVCaptureDevice.position, OFF by default.
		[self checkboxWithKey:HWG_CAMERA_SHOW_POSITION_KEY title:NSLocalizedString(@"Position (Front/Back/Unspecified)", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_CAMERA_SHOW_CONTINUITY_KEY title:NSLocalizedString(@"Continuity Camera / Desk View companion (iPhone as webcam, macOS 13+)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_CAMERA_SHOW_CENTERSTAGE_KEY title:NSLocalizedString(@"Center Stage active (auto-framing, macOS 12.3+)", @"") defaultOn:YES],
		// Final API audit (18-ago-2026) — OFF by default.
		[self checkboxWithKey:HWG_CAMERA_SHOW_MAX_FRAMERATE_KEY title:NSLocalizedString(@"Max frame rate", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_CAMERA_SHOW_SYSTEM_PREFERRED_KEY title:NSLocalizedString(@"System Preferred Camera (macOS 13+)", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_CAMERA_SHOW_PORTRAIT_EFFECT_KEY title:NSLocalizedString(@"Notify when Portrait Effect changes (macOS 12+)", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_CAMERA_SHOW_STUDIO_LIGHT_KEY title:NSLocalizedString(@"Notify when Studio Light changes (macOS 13+)", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_CAMERA_SHOW_REACTIONS_KEY title:NSLocalizedString(@"Notify when Reactions changes (macOS 14+)", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_CAMERA_SHOW_BG_REPLACEMENT_KEY title:NSLocalizedString(@"Notify when Background Replacement changes (macOS 15+)", @"") defaultOn:NO],
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
		@[@"Module Icon (Sidebar)", @"CameraMonitor-Icon-Module"],
		// Moved here from the General tab (13-ago-2026, feedback del usuario): these are the
		// MASTER toggles for the Connected/Disconnected and Started/Stopped notifications —
		// per the app's convention, notification on/off toggles belong in Icons, not General
		// (General is only for field-visibility toggles on an existing notice).
		@[@"Connected / Disconnected", @"CameraMonitor-Icon", HWG_CAMERA_NOTIFY_CONNECT_KEY],
		@[@"In Use", @"CameraMonitor-Icon-InUse", HWG_CAMERA_NOTIFY_IN_USE_KEY],
		@[@"In Use — Started (icon)", @"CameraMonitor-Icon-InUse", HWG_CAMERA_NOTIFY_INUSE_ROW_KEY],
		@[@"In Use — Stopped (icon)", @"CameraMonitor-Icon", HWG_CAMERA_NOTIFY_IDLE_ROW_KEY],
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

	NSScrollView *iconsScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 560, 160)];
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
	return @[@"CameraConnected", @"CameraDisconnected", @"CameraInUseChanged",
			 @"CameraPortraitEffectChanged", @"CameraStudioLightChanged",
			 @"CameraReactionsChanged", @"CameraBackgroundReplacementChanged"];
}
-(NSDictionary*)localizedNames {
	return @{
		@"CameraConnected": NSLocalizedString(@"Camera Connected", @""),
		@"CameraDisconnected": NSLocalizedString(@"Camera Disconnected", @""),
		@"CameraInUseChanged": NSLocalizedString(@"Camera In Use Changed", @""),
		@"CameraPortraitEffectChanged": NSLocalizedString(@"Portrait Effect Changed", @""),
		@"CameraStudioLightChanged": NSLocalizedString(@"Studio Light Changed", @""),
		@"CameraReactionsChanged": NSLocalizedString(@"Reactions Changed", @""),
		@"CameraBackgroundReplacementChanged": NSLocalizedString(@"Background Replacement Changed", @""),
	};
}
-(NSDictionary*)noteDescriptions {
	return @{
		@"CameraConnected": NSLocalizedString(@"Sent when a camera not already covered by USB/Bluetooth Monitor is connected", @""),
		@"CameraDisconnected": NSLocalizedString(@"Sent when such a camera is disconnected", @""),
		@"CameraInUseChanged": NSLocalizedString(@"Sent when a camera starts or stops being used by any app — a privacy-relevant signal, same fact macOS's own camera-in-use indicator reflects", @""),
		@"CameraPortraitEffectChanged": NSLocalizedString(@"Sent when Control Center's Portrait Effect is turned on/off system-wide (off by default, macOS 12+)", @""),
		@"CameraStudioLightChanged": NSLocalizedString(@"Sent when Control Center's Studio Light is turned on/off system-wide (off by default, macOS 13+)", @""),
		@"CameraReactionsChanged": NSLocalizedString(@"Sent when Control Center's Reactions is turned on/off system-wide (off by default, macOS 14+)", @""),
		@"CameraBackgroundReplacementChanged": NSLocalizedString(@"Sent when Control Center's Background Replacement is turned on/off system-wide (off by default, macOS 15+)", @""),
	};
}
-(NSArray*)defaultNotifications {
	return [self noteNames];
}

@end
