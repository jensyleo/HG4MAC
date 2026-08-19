//
//  HWGIconPickerView.m
//  HardwareGrowler
//

// compile with ARC: -fobjc-arc
#import "HWGIconPickerView.h"
#import "HWGIconOverrideStore.h"
#import <CoreServices/CoreServices.h>

@implementation HWGFlippedContentView
- (BOOL)isFlipped { return YES; }
@end

@implementation HWGSystemIconCatalog

+ (NSArray<NSArray *> *)availableIcons {
	// Four-char OSTypes recognized by the legacy Icon Services generic-icon lookup —
	// see the header comment above for why this (rather than a UTType-based API) is the
	// only way to reach these particular system-drawn icons. kGenericWORMIcon/others
	// omitted here because they resolve to the same placeholder as a missing icon on
	// modern macOS, not a distinct picture — this list only includes ones confirmed
	// distinct.
	NSArray<NSArray *> *specs = @[
		@[NSLocalizedString(@"Hard Disk", @""), @(kGenericHardDiskIcon)],
		@[NSLocalizedString(@"Removable Media", @""), @(kGenericRemovableMediaIcon)],
		@[NSLocalizedString(@"CD/DVD", @""), @(kGenericCDROMIcon)],
		@[NSLocalizedString(@"Floppy Disk", @""), @(kGenericFloppyIcon)],
		@[NSLocalizedString(@"Network", @""), @(kGenericNetworkIcon)],
		@[NSLocalizedString(@"File Server", @""), @(kGenericFileServerIcon)],
		@[NSLocalizedString(@"PC Card", @""), @(kGenericPCCardIcon)],
		@[NSLocalizedString(@"RAM Disk", @""), @(kGenericRAMDiskIcon)],
	];

	NSMutableArray<NSArray *> *result = [NSMutableArray arrayWithCapacity:specs.count];
	for (NSArray *spec in specs) {
		NSString *label = spec[0];
		OSType code = (OSType)[spec[1] unsignedIntValue];
		NSString *fileType = NSFileTypeForHFSTypeCode(code);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		NSImage *image = [[NSWorkspace sharedWorkspace] iconForFileType:fileType];
#pragma clang diagnostic pop
		if (image) [result addObject:@[label, image]];
	}
	return result;
}

@end

// One tile in the "System Icon…" popover grid — carries the full-size system NSImage
// alongside the defaultName it should be applied to, so the click handler doesn't need
// a second lookup table.
@interface HWGSystemIconButton : NSButton
@property (nonatomic, copy) NSString *defaultName;
@property (nonatomic, strong) NSImage *catalogImage;
@end
@implementation HWGSystemIconButton @end

@interface HWGIconPickerRow : NSObject
@property (nonatomic, copy) NSString *defaultName;
@property (nonatomic, weak) NSImageView *imageView;
@property (nonatomic, weak) NSButton *resetButton;
// Persistent anchor for the "Custom" sub-menu popover — unlike buttons living INSIDE a
// popover's own content view, this one never gets torn down when a popover closes, so it's
// always safe to re-anchor a new popover to it.
@property (nonatomic, weak) NSButton *changeButton;
@end
@implementation HWGIconPickerRow @end

static BOOL HWGIconPickerNotifyBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

@interface HWGIconPickerView ()
@property (nonatomic, strong) NSArray<HWGIconPickerRow *> *rows;
@property (nonatomic, strong) NSPopover *activeSystemIconPopover;
@end

@implementation HWGIconPickerView

- (instancetype)initWithIconSpecs:(NSArray<NSArray *> *)iconSpecs width:(CGFloat)width {
	self = [super initWithFrame:NSZeroRect];
	if (self) {
		self.translatesAutoresizingMaskIntoConstraints = NO;
		[self buildWithIconSpecs:iconSpecs width:width];
	}
	return self;
}

// Handler for every row's "Notify?" checkbox — `identifier` carries the NSUserDefaults key
// (set per-row in `buildWithIconSpecs:` below), same pattern each monitor's own General-tab
// checkboxes already use.
- (void)notifyToggleChanged:(NSButton *)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
}

- (void)buildWithIconSpecs:(NSArray<NSArray *> *)iconSpecs width:(CGFloat)pickerWidth {
	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Icons", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;
	[self addSubview:header];

	NSMutableArray<HWGIconPickerRow *> *rows = [NSMutableArray array];
	NSView *previous = header;

	// Name column width: sized to the widest label actually in THIS picker's list, not a
	// single constant shared by every monitor — some monitors' labels are short single words
	// ("Mouse", "Speaker") while others (Volume's "External Disk (Unmounted)") are much
	// longer. A fixed 150pt fit the short lists but truncated the long ones; measuring here
	// keeps every row's button columns aligned (they all still share this one width) while
	// guaranteeing no label ever needs the "…"/tooltip fallback.
	CGFloat nameColumnWidth = 150;
	// BUG FIX (18-ago-2026, made structural 19-ago-2026) — this column width used to grow
	// completely unbounded to fit whatever the widest label happened to be, then (18-ago) was
	// capped at a hardcoded 240pt. That hardcoded cap turned out to be its own bug: 240pt plus
	// the other fixed-width columns (image + 3 buttons + the notify checkbox + all the gaps
	// between them, kFixedColumnsWidth below) adds up to MORE than the actual width every
	// caller allocates this view (their `iconsWidth`, typically ~528pt) — so any row whose
	// label needs anywhere near the 240pt cap pushes the LAST column (the "Notify?" checkbox)
	// past this view's own real width. Confirmed live via AXUIElementCopyElementAtPosition
	// (19-ago-2026, Camera Monitor): a real screen click exactly on a checkbox's own reported
	// position resolved to the enclosing NSScrollView's AXScrollArea, not the checkbox — the
	// checkbox was being painted (Auto Layout doesn't clip child rendering) but sat outside the
	// NSClipView's real, hit-testable document bounds. This is why the bug kept recurring across
	// different monitors/labels each time a new notify row was added: 240 was never actually
	// safe, it just happened not to be reached by whichever labels existed at the time.
	//
	// Fixed structurally instead of re-guessing a bigger constant: the cap is now DERIVED from
	// the real `width` the caller passes to -initWithIconSpecs:width: (every caller already
	// computes this as its own `iconsWidth` before constructing this view), so it can never
	// exceed what actually fits, for this or any future caller/label — no more picking a number
	// and hoping.
	CGFloat const kFixedColumnsWidth = 32 /*image*/ + 10 /*gap*/ + 10 /*gap*/ + 70 /*change*/ + 8 /*gap*/ + 70 /*system*/ + 8 /*gap*/ + 70 /*reset*/ + 16 /*gap*/ + 20 /*notify*/;
	CGFloat const kMinNameColumnWidth = 80;
	// `pickerWidth <= 0` is a defensive fallback only (e.g. a future caller that forgets to
	// pass a real width) — every current caller passes its real `iconsWidth`.
	CGFloat const kMaxNameColumnWidth = (pickerWidth > 0)
		? MAX(kMinNameColumnWidth, pickerWidth - kFixedColumnsWidth)
		: 240;
	for (NSArray *spec in iconSpecs) {
		// Measure with an actual NSTextField (not NSString sizeWithAttributes:), then read its
		// real -intrinsicContentSize — the two didn't agree closely enough in practice ("Other
		// Interface Connected/Disconnected" in Network Monitor still got truncated with "…"
		// even after bumping the NSString-based safety margin from +4 to +16). Building the
		// same kind of label this row will actually use and asking IT for its size sidesteps
		// whatever gap causes the mismatch — plus a small +6 margin for a bit of breathing room.
		NSTextField *measuringField = [NSTextField labelWithString:spec[0]];
		// +24 margin — generous on purpose. A real Retina display can measure/render text
		// slightly wider than this headless-style measurement predicts; a few points of unused
		// trailing space in a name column is invisible, but truncating the longest label isn't.
		CGFloat needed = MIN(ceil(measuringField.intrinsicContentSize.width) + 24, kMaxNameColumnWidth);
		if (needed > nameColumnWidth) nameColumnWidth = needed;
	}

	for (NSArray *spec in iconSpecs) {
		NSString *label = spec[0];
		NSString *defaultName = spec[1];

		NSImageView *imageView = [NSImageView new];
		imageView.translatesAutoresizingMaskIntoConstraints = NO;
		imageView.image = HWGResolveIconNamed(defaultName);
		imageView.imageScaling = NSImageScaleProportionallyUpOrDown;

		// REVERTED (19-ago-2026) — a multi-line wrapping version of this label was tried so
		// long labels stay fully visible instead of truncating, using a "hug the taller of
		// two views" dual-priority Auto Layout constraint pair for row spacing. That
		// introduced a NEW checkbox-click regression (reported live, affecting rows beyond
		// just the wrapped ones) on top of being unnecessary: the only labels that ever
		// needed it (Thermal Monitor's 2 Intel-only rows) were removed from this Apple
		// Silicon build entirely — see TODO.md's "PENDIENTE — SOLO PARA HG4MAC-INTEL" section.
		// Back to the simple, previously-verified single-line + truncate-with-tooltip
		// approach; the 240pt column cap above still protects every row's controls from ever
		// being pushed out of bounds by a future long label, it just truncates instead of
		// wrapping when that happens.
		NSTextField *nameField = [NSTextField labelWithString:label];
		nameField.translatesAutoresizingMaskIntoConstraints = NO;
		nameField.lineBreakMode = NSLineBreakByTruncatingTail;
		nameField.toolTip = label; // safety net for any label the 240pt cap must truncate

		NSButton *changeButton = [NSButton buttonWithTitle:NSLocalizedString(@"Custom", @"") target:self action:@selector(changeButtonClicked:)];
		changeButton.translatesAutoresizingMaskIntoConstraints = NO;
		changeButton.identifier = defaultName;
		changeButton.toolTip = NSLocalizedString(@"Choose an image file", @"");

		NSButton *systemIconButton = [NSButton buttonWithTitle:NSLocalizedString(@"System", @"") target:self action:@selector(systemIconButtonClicked:)];
		systemIconButton.translatesAutoresizingMaskIntoConstraints = NO;
		systemIconButton.identifier = defaultName;
		systemIconButton.toolTip = NSLocalizedString(@"Choose a macOS system icon", @"");

		NSButton *resetButton = [NSButton buttonWithTitle:NSLocalizedString(@"Reset", @"") target:self action:@selector(resetButtonClicked:)];
		resetButton.translatesAutoresizingMaskIntoConstraints = NO;
		resetButton.identifier = defaultName;
		resetButton.enabled = [[HWGIconOverrideStore sharedStore] hasOverrideForDefaultName:defaultName];

		// "Notify?" column — always created so every row has the exact same subview/constraint
		// structure (no per-row branching that could make Auto Layout treat rows differently);
		// simply hidden for rows whose spec has no 3rd element (Module Icon/Connected/
		// Disconnected — not a distinct notification event).
		NSString *notifyKey = (spec.count > 2) ? spec[2] : nil;
		BOOL notifyDefaultOn = (spec.count > 3) ? [spec[3] boolValue] : YES;
		NSButton *notifyBox = [NSButton checkboxWithTitle:@"" target:self action:@selector(notifyToggleChanged:)];
		notifyBox.translatesAutoresizingMaskIntoConstraints = NO;
		if (notifyKey) {
			notifyBox.identifier = notifyKey;
			notifyBox.state = HWGIconPickerNotifyBoolForKey(notifyKey, notifyDefaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
			notifyBox.toolTip = NSLocalizedString(@"Notify for this event", @"");
		} else {
			notifyBox.hidden = YES;
			notifyBox.enabled = NO;
		}
		[self addSubview:notifyBox];

		HWGIconPickerRow *row = [HWGIconPickerRow new];
		row.defaultName = defaultName;
		row.imageView = imageView;
		row.resetButton = resetButton;
		row.changeButton = changeButton;
		[rows addObject:row];

		[self addSubview:imageView];
		[self addSubview:nameField];
		[self addSubview:changeButton];
		[self addSubview:systemIconButton];
		[self addSubview:resetButton];

		[NSLayoutConstraint activateConstraints:@[
			[imageView.topAnchor constraintEqualToAnchor:previous.bottomAnchor constant:previous == header ? 10 : 12],
			[imageView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
			[imageView.widthAnchor constraintEqualToConstant:32],
			[imageView.heightAnchor constraintEqualToConstant:32],

			[nameField.centerYAnchor constraintEqualToAnchor:imageView.centerYAnchor],
			[nameField.leadingAnchor constraintEqualToAnchor:imageView.trailingAnchor constant:10],
			[nameField.widthAnchor constraintEqualToConstant:nameColumnWidth],

			// Fixed-width name column + fixed-width, equally-spaced buttons — every row's
			// button block now starts at the exact same x and each column lines up
			// vertically across every row (previously each button's leading edge depended
			// on that row's own label's natural width, which varied per row and made the
			// columns look staggered/disordered). Every monitor's tab width was widened
			// (28-jul-2026) specifically so these columns are wide enough to show every
			// label/button in full — no more mid-word truncation anywhere.
			[changeButton.centerYAnchor constraintEqualToAnchor:imageView.centerYAnchor],
			[changeButton.leadingAnchor constraintEqualToAnchor:nameField.trailingAnchor constant:10],
			[changeButton.widthAnchor constraintEqualToConstant:70],

			[systemIconButton.centerYAnchor constraintEqualToAnchor:imageView.centerYAnchor],
			[systemIconButton.leadingAnchor constraintEqualToAnchor:changeButton.trailingAnchor constant:8],
			[systemIconButton.widthAnchor constraintEqualToAnchor:changeButton.widthAnchor],

			[resetButton.centerYAnchor constraintEqualToAnchor:imageView.centerYAnchor],
			[resetButton.leadingAnchor constraintEqualToAnchor:systemIconButton.trailingAnchor constant:8],
			[resetButton.widthAnchor constraintEqualToAnchor:changeButton.widthAnchor],
		]];

		[NSLayoutConstraint activateConstraints:@[
			// BUG FIX (18-ago-2026) — root cause of "the last 2 checkboxes don't respond to
			// clicks", reported live on Thermal Monitor's two newest Icons-tab rows and
			// confirmed via an isolated test harness dumping this view's real frame geometry:
			// notifyBox previously had NO width constraint at all, only `leading = X` and
			// `trailing <= self.trailingAnchor` (an inequality). With nothing pulling it wider
			// and an empty-title checkbox's intrinsic content size apparently not resolving to
			// a positive width in this constraint system, Auto Layout collapsed it to
			// frame.width == 0 on EVERY row across EVERY monitor that uses this shared
			// component — a real, silent click target of zero width, invisible until a user
			// actually needed to toggle a row that defaults OFF (most existing rows default ON,
			// so this went unnoticed until Thermal Monitor's two Intel-only additions, which
			// default OFF). Explicit width constraint fixes it for all 13 monitors at once.
			[notifyBox.centerYAnchor constraintEqualToAnchor:imageView.centerYAnchor],
			[notifyBox.leadingAnchor constraintEqualToAnchor:resetButton.trailingAnchor constant:16],
			[notifyBox.widthAnchor constraintEqualToConstant:20],
			// Structural safety net (19-ago-2026): even though kMaxNameColumnWidth above is now
			// derived from this view's real width so the columns should always fit, this
			// explicit trailing bound means a future change to a button width/gap constant
			// (without updating kFixedColumnsWidth to match) fails LOUDLY — Auto Layout logs a
			// constraint-breakage warning to the console and visibly clips/misplaces the row —
			// instead of silently laying the checkbox out past the clipped, hit-testable area
			// where it looks fine but never responds to a click. Priority just below required
			// (999) so it wins over nothing else here but still reports as a real break rather
			// than being silently dropped as unsatisfiable.
			[notifyBox.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor],
		]];

		previous = imageView;
	}

	// BUG FIX (18-ago-2026) — this used to pin the LAST row flush to self.bottomAnchor with
	// zero margin (`== self.bottomAnchor`, no slack at all). Every caller then sizes this
	// view's frame from -fittingSize, which resolves that equality as tightly as Auto Layout's
	// internal rounding allows — any fractional-point rounding shortfall clips exactly the
	// bottom row and nothing else, which matches the reported symptom precisely: only the
	// LAST row(s) in a list ever failed to respond to clicks, never an earlier one (those have
	// real margin below them from the next row's own top gap). A few points of bottom padding
	// costs nothing and removes the whole class of "last row only" clipping.
	[NSLayoutConstraint activateConstraints:@[
		[header.topAnchor constraintEqualToAnchor:self.topAnchor],
		[header.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
		[self.bottomAnchor constraintEqualToAnchor:previous.bottomAnchor constant:8],
	]];

	self.rows = rows;
}

- (HWGIconPickerRow *)rowForDefaultName:(NSString *)defaultName {
	for (HWGIconPickerRow *row in self.rows) {
		if ([row.defaultName isEqualToString:defaultName]) return row;
	}
	return nil;
}

- (void)changeButtonClicked:(NSButton *)sender {
	NSString *defaultName = sender.identifier;
	if (![defaultName length]) return;

	NSOpenPanel *panel = [NSOpenPanel openPanel];
	panel.allowsMultipleSelection = NO;
	panel.canChooseDirectories = NO;
	panel.canChooseFiles = YES;
	panel.title = NSLocalizedString(@"Choose Icon Image", @"");

	[panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
		if (result != NSModalResponseOK) return;
		NSURL *url = panel.URLs.firstObject;
		if (!url) return;
		NSImage *image = [[NSImage alloc] initWithContentsOfURL:url];
		if (!image) return; // not a decodable image — silently ignore rather than guessing a UTType-based filter

		[[HWGIconOverrideStore sharedStore] setOverrideImage:image forDefaultName:defaultName];

		HWGIconPickerRow *row = [self rowForDefaultName:defaultName];
		row.imageView.image = HWGResolveIconNamed(defaultName);
		row.resetButton.enabled = YES;
	}];
}

- (void)systemIconButtonClicked:(NSButton *)sender {
	NSString *defaultName = sender.identifier;
	if (![defaultName length]) return;

	NSArray<NSArray *> *catalog = [HWGSystemIconCatalog availableIcons];
	if (![catalog count]) return;

	NSInteger columns = 4;
	CGFloat tileSize = 64, tilePad = 12;
	NSInteger rowCount = (catalog.count + columns - 1) / columns;
	CGFloat gridW = columns * tileSize + (columns + 1) * tilePad;
	CGFloat gridH = rowCount * (tileSize + 18) + (rowCount + 1) * tilePad;

	NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, gridW, gridH)];
	for (NSUInteger i = 0; i < catalog.count; i++) {
		NSString *label = catalog[i][0];
		NSImage *image = catalog[i][1];
		NSInteger col = i % columns, row = i / columns;

		HWGSystemIconButton *tile = [HWGSystemIconButton buttonWithTitle:label target:self action:@selector(systemIconChosen:)];
		tile.defaultName = defaultName;
		tile.catalogImage = image;
		tile.image = image;
		tile.imagePosition = NSImageAbove;
		tile.bezelStyle = NSBezelStyleShadowlessSquare;
		tile.bordered = NO;
		tile.font = [NSFont systemFontOfSize:10];
		CGFloat x = tilePad + col * (tileSize + tilePad);
		CGFloat y = gridH - tilePad - (row + 1) * (tileSize + 18) - row * tilePad;
		tile.frame = NSMakeRect(x, y, tileSize, tileSize + 18);
		[content addSubview:tile];
	}

	NSPopover *popover = [NSPopover new];
	NSViewController *vc = [NSViewController new];
	vc.view = content;
	popover.contentViewController = vc;
	popover.behavior = NSPopoverBehaviorTransient;
	self.activeSystemIconPopover = popover;
	[popover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSMaxYEdge];
}

- (void)systemIconChosen:(HWGSystemIconButton *)sender {
	NSString *defaultName = sender.defaultName;
	if (![defaultName length] || !sender.catalogImage) return;

	[[HWGIconOverrideStore sharedStore] setOverrideImage:sender.catalogImage forDefaultName:defaultName];

	HWGIconPickerRow *row = [self rowForDefaultName:defaultName];
	row.imageView.image = HWGResolveIconNamed(defaultName);
	row.resetButton.enabled = YES;

	[self.activeSystemIconPopover close];
	self.activeSystemIconPopover = nil;
}

- (void)resetButtonClicked:(NSButton *)sender {
	NSString *defaultName = sender.identifier;
	if (![defaultName length]) return;

	[[HWGIconOverrideStore sharedStore] removeOverrideForDefaultName:defaultName];

	HWGIconPickerRow *row = [self rowForDefaultName:defaultName];
	row.imageView.image = HWGResolveIconNamed(defaultName);
	row.resetButton.enabled = NO;
}

@end
