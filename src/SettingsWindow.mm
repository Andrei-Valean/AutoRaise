/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 */

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "SettingsWindow.h"
#import "AppTable.h"
#import "SettingsUI.h"
#import "Stats.h"

#define AR_SIDEBAR_WIDTH 196.0
#define AR_PANE_MARGIN 24.0

//-------------------------------------------------- pages -------------------------------------------------

typedef NS_ENUM(NSInteger, ARPage) {
    ARPageGeneral,
    ARPageRaise,
    ARPageWarp,
    ARPageExceptions,
    ARPageAdvanced,
    ARPageStats,
    ARPageAbout,
    ARPageCount,
};

typedef struct {
    const char *title;
    const char *symbol;
    const char *subtitle;
} ARPageInfo;

static const ARPageInfo ARPages[ARPageCount] = {
    {"General", "switch.2", "Turn AutoRaise on, off, and out of the way."},
    {"Raise & Focus", "square.3.layers.3d.top.filled",
     "What happens when the pointer settles on a window."},
    {"Pointer", "cursorarrow.motionlines", "Where the pointer moves on its own, and when."},
    {"Exceptions", "hand.raised.fill", "How individual applications and windows are treated."},
    {"Advanced", "slider.horizontal.3", "Timing, hit testing, and diagnostics."},
    {"Statistics", "chart.bar.fill", "What hovering has saved you."},
    {"About", "info.circle.fill", NULL},
};

static NSColor *ARPageTint(ARPage page) {
    switch (page) {
        case ARPageGeneral: return NSColor.systemGrayColor;
        case ARPageRaise: return NSColor.systemBlueColor;
        case ARPageWarp: return NSColor.systemPurpleColor;
        case ARPageExceptions: return NSColor.systemOrangeColor;
        case ARPageAdvanced: return NSColor.systemTealColor;
        case ARPageStats: return NSColor.systemIndigoColor;
        default: return NSColor.systemPinkColor;
    }
}

//-------------------------------------------- sidebar --------------------------------------------

@interface ARSidebarController : NSViewController <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, copy) void (^onSelect)(ARPage page);
@property (nonatomic) ARPage selected;
@end

@implementation ARSidebarController {
    NSTableView *_table;
}

- (void)loadView {
    _table = [[NSTableView alloc] init];
    _table.headerView = nil;
    _table.rowHeight = 32;
    _table.style = NSTableViewStyleSourceList;
    _table.backgroundColor = NSColor.clearColor;
    _table.dataSource = self;
    _table.delegate = self;
    _table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier: @"page"];
    [_table addTableColumn: column];

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.documentView = _table;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = NO;
    self.view = scroll;

    [_table selectRowIndexes: [NSIndexSet indexSetWithIndex: 0] byExtendingSelection: NO];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return ARPageCount; }

- (NSView *)tableView:(NSTableView *)tableView
    viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSTableCellView *cell = [[NSTableCellView alloc] init];

    // A tinted rounded square with a symbol in it, the way the system settings
    // sidebar marks its sections.
    ARFillView *badge = [[ARFillView alloc] initWithFrame: NSZeroRect];
    badge.cornerRadius = 5;
    badge.fillColor = ARPageTint((ARPage) row);

    NSImage *symbol = [NSImage imageWithSystemSymbolName: @(ARPages[row].symbol)
                                accessibilityDescription: @(ARPages[row].title)];
    NSImageView *icon = [NSImageView imageViewWithImage: symbol ?:
        [NSImage imageWithSystemSymbolName: @"circle.fill" accessibilityDescription: @""]];
    icon.symbolConfiguration = [NSImageSymbolConfiguration
        configurationWithPointSize: 11 weight: NSFontWeightSemibold];
    icon.contentTintColor = NSColor.whiteColor;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [badge addSubview: icon];

    NSTextField *label = ARLabel(@(ARPages[row].title), [NSFont systemFontOfSize: 13],
                                 NSColor.labelColor);
    [cell addSubview: badge];
    [cell addSubview: label];
    cell.textField = label;

    [NSLayoutConstraint activateConstraints: @[
        [badge.leadingAnchor constraintEqualToAnchor: cell.leadingAnchor constant: 2],
        [badge.centerYAnchor constraintEqualToAnchor: cell.centerYAnchor],
        [badge.widthAnchor constraintEqualToConstant: 22],
        [badge.heightAnchor constraintEqualToConstant: 22],
        [icon.centerXAnchor constraintEqualToAnchor: badge.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor: badge.centerYAnchor],
        [label.leadingAnchor constraintEqualToAnchor: badge.trailingAnchor constant: 9],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor: cell.trailingAnchor constant: -6],
        [label.centerYAnchor constraintEqualToAnchor: cell.centerYAnchor],
    ]];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    _selected = (ARPage) _table.selectedRow;
    if (self.onSelect && _table.selectedRow >= 0) { self.onSelect(_selected); }
}

@end

//---------------------------------------------- the window ------------------------------------------------

@interface ARSettingsWindowController () <NSWindowDelegate>
// Reached from the control blocks, which cannot touch ivars through a weak self.
@property (nonatomic, readonly) id<ARSettingsDelegate> settingsDelegate;
@property (nonatomic, readonly, nullable) ARSliderRow *raiseDelayRow;
@property (nonatomic, readonly, nullable) ARSliderRow *focusDelayRow;
@end

@implementation ARSettingsWindowController {
    __weak id<ARSettingsDelegate> _delegate;
    ARSidebarController *_sidebar;
    NSViewController *_content;
    NSScrollView *_scroll;
    NSStackView *_pane;
    ARPage _page;

    // Rows that other rows switch on and off.
    ARSliderRow *_raiseDelayRow;
    ARSliderRow *_focusDelayRow;
    NSMutableArray<ARRow *> *_warpDependents;
    NSMutableArray<ARSliderRow *> *_warpDependentSliders;
}

- (instancetype)initWithDelegate:(id<ARSettingsDelegate>)delegate {
    NSWindow *window = [[NSWindow alloc] initWithContentRect: NSMakeRect(0, 0, 812, 620)
        styleMask: NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                   NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                   NSWindowStyleMaskFullSizeContentView
        backing: NSBackingStoreBuffered defer: NO];
    window.title = @"AutoRaise Settings";
    window.titlebarAppearsTransparent = NO;
    window.minSize = NSMakeSize(760, 480);
    window.releasedWhenClosed = NO;

    if ((self = [super initWithWindow: window])) {
        _delegate = delegate;
        _page = ARPageGeneral;
        window.delegate = self;
        [self buildWindow];
        [self showPage: ARPageGeneral];
    }
    return self;
}

- (void)buildWindow {
    _sidebar = [[ARSidebarController alloc] init];
    __weak ARSettingsWindowController *weakSelf = self;
    _sidebar.onSelect = ^(ARPage page) { [weakSelf showPage: page]; };

    _pane = [[NSStackView alloc] init];
    _pane.orientation = NSUserInterfaceLayoutOrientationVertical;
    _pane.alignment = NSLayoutAttributeLeading;
    _pane.spacing = 0;
    _pane.translatesAutoresizingMaskIntoConstraints = NO;

    ARFlippedView *document = [[ARFlippedView alloc] init];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview: _pane];

    _scroll = [[NSScrollView alloc] init];
    _scroll.hasVerticalScroller = YES;
    _scroll.drawsBackground = NO;
    _scroll.automaticallyAdjustsContentInsets = YES;
    _scroll.documentView = document;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *contentView = [[NSView alloc] init];
    [contentView addSubview: _scroll];
    [NSLayoutConstraint activateConstraints: @[
        [_scroll.topAnchor constraintEqualToAnchor: contentView.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor: contentView.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor: contentView.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor: contentView.trailingAnchor],
        [document.widthAnchor constraintEqualToAnchor: _scroll.widthAnchor],
        [_pane.topAnchor constraintEqualToAnchor: document.topAnchor constant: AR_PANE_MARGIN],
        [_pane.bottomAnchor constraintEqualToAnchor: document.bottomAnchor constant: -AR_PANE_MARGIN],
        [_pane.leadingAnchor constraintEqualToAnchor: document.leadingAnchor
            constant: AR_PANE_MARGIN],
        [_pane.widthAnchor constraintEqualToConstant: AR_CONTENT_WIDTH],
        [document.trailingAnchor constraintGreaterThanOrEqualToAnchor: _pane.trailingAnchor
            constant: AR_PANE_MARGIN],
    ]];

    _content = [[NSViewController alloc] init];
    _content.view = contentView;

    NSSplitViewController *split = [[NSSplitViewController alloc] init];
    NSSplitViewItem *sidebarItem = [NSSplitViewItem sidebarWithViewController: _sidebar];
    sidebarItem.minimumThickness = AR_SIDEBAR_WIDTH;
    sidebarItem.maximumThickness = AR_SIDEBAR_WIDTH;
    sidebarItem.canCollapse = NO;
    [split addSplitViewItem: sidebarItem];
    [split addSplitViewItem: [NSSplitViewItem splitViewItemWithViewController: _content]];
    self.window.contentViewController = split;
    [self.window setContentSize: NSMakeSize(AR_SIDEBAR_WIDTH + AR_CONTENT_WIDTH +
                                            AR_PANE_MARGIN * 2, 640)];
}

- (void)show {
    if (!self.window.isVisible) { [self.window center]; }
    [self.window makeKeyAndOrderFront: nil];
    [NSApp activateIgnoringOtherApps: YES];
}

- (void)rebuild { [self showPage: _page]; }

//------------------------------------------------ layout --------------------------------------------------

- (void)showPage:(ARPage)page {
    _page = page;
    _warpDependents = [NSMutableArray array];
    _warpDependentSliders = [NSMutableArray array];
    _raiseDelayRow = nil;
    _focusDelayRow = nil;

    for (NSView *view in _pane.views.copy) { [_pane removeView: view]; }

    [self addHeaderForPage: page];
    switch (page) {
        case ARPageGeneral: [self buildGeneral]; break;
        case ARPageRaise: [self buildRaise]; break;
        case ARPageWarp: [self buildWarp]; break;
        case ARPageExceptions: [self buildExceptions]; break;
        case ARPageAdvanced: [self buildAdvanced]; break;
        case ARPageStats: [self buildStats]; break;
        default: [self buildAbout]; break;
    }

    // Show the top of the new page rather than wherever the last one was, once
    // the layout has settled on how tall the page is.
    [_pane layoutSubtreeIfNeeded];
    NSScrollView *scroll = _scroll;
    dispatch_async(dispatch_get_main_queue(), ^{
        [scroll.contentView scrollToPoint: NSZeroPoint];
        [scroll reflectScrolledClipView: scroll.contentView];
    });
}

- (void)addHeaderForPage:(ARPage)page {
    NSTextField *title = ARLabel(@(ARPages[page].title), ARTitleFont(), NSColor.labelColor);
    [self add: title spacingAfter: ARPages[page].subtitle ? 2 : 18];
    if (ARPages[page].subtitle) {
        NSTextField *subtitle = ARLabel(@(ARPages[page].subtitle), [NSFont systemFontOfSize: 12],
                                        NSColor.secondaryLabelColor);
        subtitle.preferredMaxLayoutWidth = AR_CONTENT_WIDTH;
        [self add: subtitle spacingAfter: 18];
    }
}

- (void)add:(NSView *)view spacingAfter:(CGFloat)spacing {
    [_pane addView: view inGravity: NSStackViewGravityTop];
    [NSLayoutConstraint activateConstraints: @[
        [view.leadingAnchor constraintEqualToAnchor: _pane.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor: _pane.trailingAnchor],
    ]];
    if (spacing > 0) { [_pane setCustomSpacing: spacing afterView: view]; }
}

- (void)addCard:(NSArray<NSView *> *)rows {
    [self add: [ARCard cardWithRows: rows] spacingAfter: 8];
}

- (void)addFootnote:(NSString *)text {
    NSTextField *label = ARLabel(text, ARFootnoteFont(), NSColor.tertiaryLabelColor);
    label.preferredMaxLayoutWidth = AR_CONTENT_WIDTH - 4;
    NSView *wrapper = [[NSView alloc] init];
    wrapper.translatesAutoresizingMaskIntoConstraints = NO;
    [wrapper addSubview: label];
    [NSLayoutConstraint activateConstraints: @[
        [label.topAnchor constraintEqualToAnchor: wrapper.topAnchor],
        [label.bottomAnchor constraintEqualToAnchor: wrapper.bottomAnchor],
        [label.leadingAnchor constraintEqualToAnchor: wrapper.leadingAnchor constant: AR_ROW_INSET],
        [label.trailingAnchor constraintEqualToAnchor: wrapper.trailingAnchor],
    ]];
    [self add: wrapper spacingAfter: 20];
}

- (void)addSectionTitle:(NSString *)text {
    NSTextField *label = ARLabel(text, [NSFont systemFontOfSize: 11 weight: NSFontWeightSemibold],
                                 NSColor.secondaryLabelColor);
    NSView *wrapper = [[NSView alloc] init];
    wrapper.translatesAutoresizingMaskIntoConstraints = NO;
    [wrapper addSubview: label];
    [NSLayoutConstraint activateConstraints: @[
        [label.topAnchor constraintEqualToAnchor: wrapper.topAnchor],
        [label.bottomAnchor constraintEqualToAnchor: wrapper.bottomAnchor constant: -6],
        [label.leadingAnchor constraintEqualToAnchor: wrapper.leadingAnchor constant: AR_ROW_INSET],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor: wrapper.trailingAnchor],
    ]];
    [self add: wrapper spacingAfter: 0];
}

//----------------------------------------------- shorthands -----------------------------------------------

- (ARConfig *)config { return [_delegate currentConfig]; }
- (id<ARSettingsDelegate>)settingsDelegate { return _delegate; }
- (ARSliderRow *)raiseDelayRow { return _raiseDelayRow; }
- (ARSliderRow *)focusDelayRow { return _focusDelayRow; }

- (void)set:(NSString *)key to:(id)value {
    [_delegate applySettings: @{key: value ?: [NSNull null]}];
}

- (void)setBool:(NSString *)key to:(BOOL)value {
    [self set: key to: value ? @"true" : @"false"];
}

//------------------------------------------------ general -------------------------------------------------

- (void)buildGeneral {
    if (![_delegate accessibilityGranted]) {
        __weak ARSettingsWindowController *weakSelf = self;
        ARNoticeView *notice = [[ARNoticeView alloc]
            initWithSymbol: @"exclamationmark.triangle.fill" tint: NSColor.systemOrangeColor
            title: @"AutoRaise needs accessibility access"
            message: @"Without it macOS will not let AutoRaise see or raise your windows."
            buttonTitle: @"Open Settings"
            action: ^{ [weakSelf.settingsDelegate requestAccessibility]; }];
        [self add: notice spacingAfter: 18];
    }

    ARConfig *config = self.config;
    __weak ARSettingsWindowController *weakSelf = self;

    ARToggleRow *enabled = [[ARToggleRow alloc] initWithTitle: @"Raise windows on hover"
        subtitle: [_delegate statusSummary] on: config.enabled];
    __weak ARToggleRow *weakEnabled = enabled;
    enabled.onChange = ^(BOOL on) {
        [weakSelf setBool: @"enabled" to: on];
        weakEnabled.subtitleLabel.stringValue = [weakSelf.settingsDelegate statusSummary];
    };

    NSMutableArray *rows = [@[enabled] mutableCopy];

    if ([_delegate loginItemAvailable]) {
        ARToggleRow *login = [[ARToggleRow alloc] initWithTitle: @"Open at login"
            subtitle: @"Start AutoRaise when you log in" on: [_delegate loginItemEnabled]];
        login.onChange = ^(BOOL on) { [weakSelf.settingsDelegate setLoginItemEnabled: on]; };
        [rows addObject: login];
    }

    ARToggleRow *icon = [[ARToggleRow alloc] initWithTitle: @"Show in the menu bar"
        subtitle: @"Hiding it leaves this window as the only way back in" on: config.menuBarIcon];
    icon.onChange = ^(BOOL on) { [weakSelf setBool: @"menuBarIcon" to: on]; };
    [rows addObject: icon];

    [self addCard: rows];
    [self addFootnote: @"Pausing AutoRaise leaves your windows exactly as they are. "
                       "Nothing is raised again until you switch it back on."];

    ARShortcutField *field = [[ARShortcutField alloc] initWithFrame: NSZeroRect];
    field.shortcut = config.toggleShortcut;
    field.onChange = ^(NSString *shortcut) {
        [weakSelf set: @"toggleShortcut" to: shortcut];
    };
    ARRow *shortcut = [[ARRow alloc] initWithTitle: @"Shortcut to pause and resume"
        subtitle: @"Works in any app. Press escape to cancel, delete to clear."
        accessory: field];

    ARShortcutField *pinField = [[ARShortcutField alloc] initWithFrame: NSZeroRect];
    pinField.shortcut = config.pinShortcut;
    pinField.onChange = ^(NSString *shortcut) {
        [weakSelf set: @"pinShortcut" to: shortcut];
    };
    ARRow *pin = [[ARRow alloc] initWithTitle: @"Keep a window on top"
        subtitle: @"Pins the window under the pointer. Press again over it to let go."
        accessory: pinField];
    [self addCard: @[shortcut, pin]];
    [self addFootnote: @"macOS does not let one app lift another app's window, so AutoRaise "
                       "shows a live copy of a pinned window whenever something covers it, which "
                       "needs the Screen Recording permission. Hovering the copy focuses the "
                       "window, clicking it brings the window forward, right-clicking unpins it."];
}

//---------------------------------------------- raise & focus ---------------------------------------------

- (void)buildRaise {
    ARConfig *config = self.config;
    __weak ARSettingsWindowController *weakSelf = self;

    ARSegmentRow *mode = [[ARSegmentRow alloc] initWithTitle: @"When the pointer arrives"
        subtitle: nil
        choices: @[@"Raise it", @"Focus, then raise", @"Only focus"]
        selected: config.mode];
    NSArray *modeValues = @[@"raise", @"focusThenRaise", @"focus"];
    mode.onChange = ^(NSInteger index) {
        [weakSelf set: @"mode" to: modeValues[index]];
        [weakSelf rebuild];   // the raise delay belongs to one mode only
    };

    // One dial. It sets how slowly the pointer has to be moving before AutoRaise
    // decides it has arrived somewhere, which is the only timing question a
    // person actually has.
    ARSegmentRow *eagerness = [[ARSegmentRow alloc] initWithTitle: @"How eager"
        subtitle: @"How much the pointer has to slow down to count as arriving"
        choices: @[@"Instant", @"Quick", @"Normal", @"Relaxed"]
        selected: config.eagerness];
    NSArray *eagernessValues = @[@"instant", @"quick", @"normal", @"relaxed"];
    eagerness.onChange = ^(NSInteger index) {
        [weakSelf set: @"eagerness" to: eagernessValues[index]];
    };

    NSMutableArray *rows = [@[mode, eagerness] mutableCopy];
    if (config.mode == ARHoverModeFocusThenRaise) {
        ARSliderRow *raiseAfter = [[ARSliderRow alloc] initWithTitle: @"Raise after"
            min: 0 max: 3000 value: config.raiseAfterMillis];
        raiseAfter.snapsToIntegers = YES;
        raiseAfter.format = ^NSString *(double value) {
            if (value < 50) { return @"Straight away"; }
            return value >= 1000 ? [NSString stringWithFormat: @"%.1f s", value / 1000]
                                 : [NSString stringWithFormat: @"%.0f ms", value];
        };
        raiseAfter.onCommit = ^(double value) {
            [weakSelf set: @"raiseAfter" to: [NSString stringWithFormat: @"%.0f", value]];
        };
        [rows addObject: raiseAfter];
    }

    [self addCard: rows];
    [self addFootnote: @"A pointer crossing a window on its way somewhere else and a pointer "
                       "arriving at one look the same if all you know is where it is. AutoRaise "
                       "watches how fast it is going instead, so passing over a window does "
                       "nothing and stopping on one does. There is no delay to tune."];

    if (config.focusFirst) {
        [self addFootnote: @"Focusing without raising lets you type into a window that stays "
                           "behind another one. It uses undocumented system calls, so treat it "
                           "as experimental: a macOS update can take it away."];
    }

    ARSliderRow *typing = [[ARSliderRow alloc] initWithTitle: @"While typing, wait"
        min: 0 max: 2000 value: config.typingGraceMillis];
    typing.snapsToIntegers = YES;
    typing.format = ^NSString *(double value) {
        if (value == 0) { return @"Do not wait"; }
        return value >= 1000 ? [NSString stringWithFormat: @"%.1f s after a keystroke", value / 1000]
                             : [NSString stringWithFormat: @"%.0f ms after a keystroke", value];
    };
    typing.onCommit = ^(double value) {
        [weakSelf set: @"typingGrace" to: [NSString stringWithFormat: @"%.0f", value]];
    };

    ARToggleRow *space = [[ARToggleRow alloc] initWithTitle: @"Ignore desktop switches"
        subtitle: @"Do not act right after moving to another desktop"
        on: config.ignoreSpaceChanged];
    space.onChange = ^(BOOL on) { [weakSelf setBool: @"ignoreSpaceChanged" to: on]; };

    NSArray *selfRaisingValues = @[@"focus", @"quiet", @"skip"];
    ARPopupRow *selfRaising = [[ARPopupRow alloc] initWithTitle: @"Apps that raise themselves"
        subtitle: @"Browsers mostly: they come forward the moment they are focused"
        choices: @[@"Let them come forward", @"Focus quietly, no raise", @"Leave them alone"]
        selected: config.selfRaisingApps];
    selfRaising.onChange = ^(NSInteger index) {
        [weakSelf set: @"selfRaisingApps" to: selfRaisingValues[index]];
    };

    [self addCard: @[typing, space, selfRaising]];
    [self addFootnote: @"Focusing a browser quietly keeps it where it is, but the browser then "
                       "decides which of its own windows takes the keyboard, so it suits one "
                       "window per screen better than several. \"AutoRaise -dumpQuirks\" lists "
                       "the applications this applies to."];

    // Focus without raise is invisible unless something says which window is
    // listening, so the ring belongs next to the setting that causes it.
    ARToggleRow *ring = [[ARToggleRow alloc] initWithTitle: @"Outline the focused window"
        subtitle: @"While it has the keyboard but is still behind something"
        on: config.focusRing];
    ring.onChange = ^(BOOL on) { [weakSelf setBool: @"focusRing" to: on]; };

    NSColorWell *well = [[NSColorWell alloc] init];
    well.color = config.focusRingColor.followsAccent
        ? NSColor.controlAccentColor
        : [NSColor colorWithSRGBRed: config.focusRingColor.red
                             green: config.focusRingColor.green
                              blue: config.focusRingColor.blue
                             alpha: config.focusRingColor.alpha];
    [well.widthAnchor constraintEqualToConstant: 52].active = YES;
    [well.heightAnchor constraintEqualToConstant: 24].active = YES;
    well.target = self;
    well.action = @selector(ringColorChanged:);
    ARRow *color = [[ARRow alloc] initWithTitle: @"Outline colour"
        subtitle: config.focusRingColor.followsAccent ? @"Following the system accent colour" : nil
        accessory: well];

    ARShortcutField *returnField = [[ARShortcutField alloc] initWithFrame: NSZeroRect];
    returnField.shortcut = config.returnShortcut;
    returnField.onChange = ^(NSString *shortcut) {
        [weakSelf set: @"returnShortcut" to: shortcut];
    };
    ARRow *returnRow = [[ARRow alloc] initWithTitle: @"Back to the previous window"
        subtitle: @"Whichever window had the keyboard before this one"
        accessory: returnField];

    ARShortcutField *raiseField = [[ARShortcutField alloc] initWithFrame: NSZeroRect];
    raiseField.shortcut = config.raiseShortcut;
    raiseField.onChange = ^(NSString *shortcut) {
        [weakSelf set: @"raiseShortcut" to: shortcut];
    };
    ARRow *raiseRow = [[ARRow alloc] initWithTitle: @"Raise it with"
        subtitle: @"Brings the outlined window to the front" accessory: raiseField];

    [self addCard: @[ring, color, raiseRow, returnRow]];
    BOOL ringUsable = config.focusFirst;
    [color setRowEnabled: ringUsable && config.focusRing];
    [raiseRow setRowEnabled: ringUsable];
    [ring setRowEnabled: ringUsable];
    if (!ringUsable) {
        [self addFootnote: @"The outline only appears when a window is focused without being "
                           "raised, so it needs one of the focus modes above."];
        return;
    }
    [self addFootnote: @"The outline is clipped to the part of the window you can actually see, "
                       "so a window in front of it hides that part of the outline too."];

    ARRingStyle style = config.focusRingStyle;
    NSMutableArray *styleRows = [NSMutableArray array];

    // The names the settings file uses, in the order the menu shows them.
    NSArray *placements = @[@"outline", @"inline", @"top", @"bottom", @"left", @"right"];
    ARPopupRow *placement = [[ARPopupRow alloc] initWithTitle: @"Draw it"
        subtitle: @"Trace the whole window, or glow along one edge"
        choices: @[@"Around the window", @"Inside the edge", @"Along the top",
                   @"Along the bottom", @"Down the left", @"Down the right"]
        selected: style.placement];
    placement.onChange = ^(NSInteger index) {
        [weakSelf set: @"focusRingStyle" to: placements[index]];
        [weakSelf rebuild];   // the bar settings appear and disappear with it
    };
    [styleRows addObject: placement];

    BOOL isBar = ARRingPlacementIsBar(style.placement);
    ARSliderRow *thickness = [[ARSliderRow alloc] initWithTitle:
        isBar ? @"Depth" : @"Thickness" min: 0.5 max: 10 value: style.width];
    thickness.format = ^NSString *(double value) {
        return [NSString stringWithFormat: @"%.1f pt", value];
    };
    thickness.onCommit = ^(double value) {
        [weakSelf set: @"focusRingWidth" to: [NSString stringWithFormat: @"%.1f", value]];
    };
    [styleRows addObject: thickness];

    ARSliderRow *glow = [[ARSliderRow alloc] initWithTitle: @"Glow"
        min: 0 max: 24 value: style.glow];
    glow.snapsToIntegers = YES;
    glow.format = ^NSString *(double value) {
        return value == 0 ? @"None" : [NSString stringWithFormat: @"%.0f pt", value];
    };
    glow.onCommit = ^(double value) {
        [weakSelf set: @"focusRingGlow" to: [NSString stringWithFormat: @"%.0f", value]];
    };
    [styleRows addObject: glow];

    if (isBar) {
        ARSliderRow *spread = [[ARSliderRow alloc] initWithTitle: @"Length"
            min: 5 max: 100 value: style.spread * 100];
        spread.snapsToIntegers = YES;
        spread.format = ^NSString *(double value) {
            return value >= 100 ? @"The whole edge"
                                : [NSString stringWithFormat: @"%.0f%% of the edge", value];
        };
        spread.onCommit = ^(double value) {
            [weakSelf set: @"focusRingSpread" to: [NSString stringWithFormat: @"%.2f", value / 100]];
        };
        [styleRows addObject: spread];

        ARSliderRow *falloff = [[ARSliderRow alloc] initWithTitle: @"Fade at the ends"
            min: 0 max: 100 value: style.falloff * 100];
        falloff.snapsToIntegers = YES;
        falloff.format = ^NSString *(double value) {
            if (value == 0) { return @"Cut off"; }
            return value >= 100 ? @"All the way in"
                                : [NSString stringWithFormat: @"%.0f%%", value];
        };
        falloff.onCommit = ^(double value) {
            [weakSelf set: @"focusRingFalloff" to: [NSString stringWithFormat: @"%.2f", value / 100]];
        };
        [styleRows addObject: falloff];
    }

    ARSliderRow *corners = [[ARSliderRow alloc] initWithTitle: isBar ? @"Rounded ends"
                                                              : @"Corner radius"
        min: 0 max: 32 value: style.radius];
    corners.snapsToIntegers = YES;
    corners.format = ^NSString *(double value) {
        return value == 0 ? @"Square" : [NSString stringWithFormat: @"%.0f pt", value];
    };
    corners.onCommit = ^(double value) {
        [weakSelf set: @"focusRingRadius" to: [NSString stringWithFormat: @"%.0f", value]];
    };
    [styleRows addObject: corners];

    ARSliderRow *opacity = [[ARSliderRow alloc] initWithTitle: @"Brightness"
        min: 10 max: 100 value: style.opacity * 100];
    opacity.snapsToIntegers = YES;
    opacity.format = ^NSString *(double value) {
        return [NSString stringWithFormat: @"%.0f%%", value];
    };
    opacity.onCommit = ^(double value) {
        [weakSelf set: @"focusRingOpacity" to: [NSString stringWithFormat: @"%.2f", value / 100]];
    };
    [styleRows addObject: opacity];

    ARSliderRow *pulse = [[ARSliderRow alloc] initWithTitle: @"Pulse"
        min: 0 max: 60 value: style.pulseSeconds * 10];
    pulse.snapsToIntegers = YES;
    pulse.format = ^NSString *(double tenths) {
        return tenths == 0 ? @"Steady"
                           : [NSString stringWithFormat: @"%.1f s per breath", tenths / 10];
    };
    pulse.onCommit = ^(double tenths) {
        [weakSelf set: @"focusRingPulse" to: [NSString stringWithFormat: @"%.1f", tenths / 10]];
    };
    [styleRows addObject: pulse];

    [self addSectionTitle: @"OUTLINE STYLE"];
    [self addCard: styleRows];
    for (NSView *row in styleRows) {
        if ([row respondsToSelector: @selector(setRowEnabled:)]) {
            [(ARRow *) row setRowEnabled: config.focusRing];
        }
    }
    if (isBar) {
        [self addFootnote: @"Changes show up on the next window you hover. Depth is how far the "
                           "bar reaches in from the edge, and the glow is how much of that is "
                           "soft rather than solid."];
    } else {
        [self addFootnote: @"Changes show up on the next window you hover. Glow at none with a "
                           "thickness of one gives a plain hairline; a wide glow and no pulse "
                           "gives a steady halo. A window filling its display is outlined just "
                           "inside its edge, since there is no room around it."];
    }
}


//------------------------------------------------ pointer -------------------------------------------------

- (void)buildWarp {
    ARConfig *config = self.config;
    __weak ARSettingsWindowController *weakSelf = self;
    BOOL warping = config.warpMouse;

    ARToggleRow *warp = [[ARToggleRow alloc] initWithTitle: @"Move the pointer to the new window"
        subtitle: @"When you switch windows with command-tab or command-grave"
        on: warping];

    ARWarpTargetView *target = [[ARWarpTargetView alloc] initWithFrame: NSZeroRect];
    target.target = CGPointMake(warping ? config.warpX : 0.5, warping ? config.warpY : 0.5);

    ARRow *where = [[ARRow alloc] initWithTitle: @"Where it lands"
        subtitle: @"Drag the pointer inside the window" accessory: target];
    __weak ARRow *weakWhere = where;
    target.onChange = ^(CGPoint point) {
        [weakSelf.settingsDelegate applySettings: @{
            @"warpX": [NSString stringWithFormat: @"%.2f", point.x],
            @"warpY": [NSString stringWithFormat: @"%.2f", point.y]}];
        weakWhere.subtitleLabel.stringValue = [weakSelf describeWarpTarget: point];
    };
    where.subtitleLabel.stringValue = [self describeWarpTarget: target.target];

    ARToggleRow *grow = [[ARToggleRow alloc] initWithTitle: @"Briefly enlarge the pointer"
        subtitle: @"So you can see where it went" on: config.cursorScale > 1];
    ARSliderRow *scale = [[ARSliderRow alloc] initWithTitle: @"Pointer size"
        min: 1.5 max: 4 value: config.cursorScale > 1 ? config.cursorScale : 2.5];
    scale.format = ^NSString *(double value) {
        return [NSString stringWithFormat: @"%.1f×", value];
    };
    scale.onCommit = ^(double value) {
        [weakSelf set: @"scale" to: [NSString stringWithFormat: @"%.1f", value]];
    };
    grow.onChange = ^(BOOL on) {
        [weakSelf set: @"scale" to: on ? [NSString stringWithFormat: @"%.1f",
            scale.slider.doubleValue] : @"1.0"];
        [scale setRowEnabled: on && weakSelf.config.warpMouse];
    };

    warp.onChange = ^(BOOL on) {
        if (on) {
            CGPoint point = target.target;
            [weakSelf.settingsDelegate applySettings: @{
                @"warpX": [NSString stringWithFormat: @"%.2f", point.x],
                @"warpY": [NSString stringWithFormat: @"%.2f", point.y]}];
        } else {
            // Both factors have to go for warping to be off.
            [weakSelf.settingsDelegate applySettings: @{
                @"warpX": [NSNull null], @"warpY": [NSNull null]}];
        }
        [where setRowEnabled: on];
        [grow setRowEnabled: on];
        [scale setRowEnabled: on && grow.toggle.state == NSControlStateValueOn];
    };

    [self addCard: @[warp, where, grow, scale]];
    [where setRowEnabled: warping];
    [grow setRowEnabled: warping];
    [scale setRowEnabled: warping && config.cursorScale > 1];

    [self addFootnote: @"With the pointer in the window you switched to, hovering keeps working "
                       "straight away instead of raising whatever the pointer was left on top of."];

    // The same bargain as above, with better odds: a dialog leaves two or three
    // places a click can land, and it says which one each key would press.
    NSArray *aims = @[@"off", @"default", @"cancel", @"nearest"];
    ARPopupRow *dialog = [[ARPopupRow alloc] initWithTitle: @"Put the pointer on"
        subtitle: @"When a dialog or a sheet appears"
        choices: @[@"Nothing, leave it alone", @"The button Return would press",
                   @"The button Escape would press", @"Whichever button is nearest"]
        selected: config.dialogAim];
    dialog.onChange = ^(NSInteger index) {
        [weakSelf set: @"dialogPointer" to: aims[index]];
    };

    ARToggleRow *back = [[ARToggleRow alloc] initWithTitle: @"Put it back afterwards"
        subtitle: @"Once the dialog is answered, unless you have moved the pointer since"
        on: config.dialogPointerReturn];
    back.onChange = ^(BOOL on) { [weakSelf setBool: @"dialogPointerReturn" to: on]; };
    [back setRowEnabled: config.dialogAim != ARDialogAimOff];

    [self addSectionTitle: @"WHEN A DIALOG APPEARS"];
    [self addCard: @[dialog, back]];
    [self addFootnote: @"The pointer is never left sitting on a button that destroys something. "
                       "Aim at the button Return would press and, when that button is Delete or "
                       "Don't Save, the pointer goes to the way out instead, or nowhere at all if "
                       "every way out is destructive. The titles it recognises are in quirks.json, "
                       "so another language can be added without a new version. A dialog waiting "
                       "for you to type is left alone."];
}

- (NSString *)describeWarpTarget:(CGPoint)point {
    if (point.x == 0.5 && point.y == 0.5) { return @"Centre of the window"; }
    if (point.x == 0.5 && point.y == 0.0) { return @"Top edge, centred"; }
    if (point.x == 0.5 && point.y == 1.0) { return @"Bottom edge, centred"; }
    return [NSString stringWithFormat: @"%.0f%% across, %.0f%% down", point.x * 100, point.y * 100];
}

//----------------------------------------------- exceptions -----------------------------------------------

- (void)buildExceptions {
    ARConfig *config = self.config;
    ARAppTable *table = [ARAppTable shared];
    __weak ARSettingsWindowController *weakSelf = self;

    NSArray<NSString *> *choices = ARAppPolicyNames();
    NSMutableArray<NSView *> *rows = [NSMutableArray array];
    BOOL anyLearned = NO;
    for (ARAppRule *rule in table.rules) {
        NSMutableArray<NSString *> *notes = [NSMutableArray array];
        if (rule.learned) { [notes addObject: @"learned"]; }
        if (rule.traits.raisesItself) { [notes addObject: @"comes forward on its own"]; }
        if (rule.traits.needsLegacyActivation) { [notes addObject: @"needs the old way of activating"]; }
        anyLearned = anyLearned || rule.learned;

        NSString *match = rule.match;
        ARRuleRow *row = [[ARRuleRow alloc] initWithMatch: match
            note: [notes componentsJoinedByString: @", "]
            choices: choices selected: rule.policy];
        row.onChange = ^(NSInteger index) {
            [[ARAppTable shared] setPolicy: (ARAppPolicy) index for: match];
            [weakSelf rebuild];
        };
        row.onRemove = ^{
            [[ARAppTable shared] removeRuleFor: match];
            [weakSelf rebuild];
        };
        [rows addObject: row];
    }

    if (!rows.count) {
        [rows addObject: [[ARRow alloc] initWithTitle: @"No rules yet"
            subtitle: @"Every application follows the settings on the other pages."
            accessory: nil]];
    }
    [rows addObject: [[ARButtonRow alloc] initWithTitle: @"Add an application"
        subtitle: @"Pick it once; AutoRaise remembers it by bundle identifier"
        buttonTitle: @"Choose Application…" action: ^{ [weakSelf addAppRule]; }]];

    [self addSectionTitle: @"PER-APP RULES"];
    [self addCard: rows];
    [self addFootnote: @"One line per application, and the line wins over every general setting. "
                       "Leave it alone skips the application entirely; Focus without raising gives "
                       "it the keyboard where it stands; Never lose the keyboard means that while "
                       "it is in front, hovering elsewhere changes nothing."];

    if (anyLearned) {
        ARButtonRow *forget = [[ARButtonRow alloc] initWithTitle: @"Forget what AutoRaise learned"
            subtitle: @"Keeps the rules you wrote and watches those applications again"
            buttonTitle: @"Forget" action: ^{
                [[ARAppTable shared] forgetLearned];
                [weakSelf rebuild];
            }];
        [self addCard: @[forget]];
        [self addFootnote: @"AutoRaise watches what an application does when it is focused and "
                           "writes down what it finds, so nobody has to know it in advance."];
    }

    ARListEditor *titles = [[ARListEditor alloc] initWithEntries: config.ignoreTitles
        allowsApps: NO bundleIdMode: NO];
    titles.placeholder = @"No patterns";
    titles.onChange = ^(NSArray<NSString *> *entries) {
        [weakSelf set: @"ignoreTitles" to: [weakSelf joinList: entries]];
    };
    [self addSectionTitle: @"WINDOW TITLES"];
    [self addCard: @[[self rowWrapping: titles]]];
    [self addFootnote: @"Regular expressions, for single windows rather than whole applications. "
                       "^Downloads$ matches that title exactly, Microsoft Teams matches any title "
                       "containing it."];

    // One setting says both the key and what holding it means; the file writes
    // the second half as a ! in front of the first.
    NSArray *keys = @[@"Control", @"Option", @"Command", @"Shift", @"None"];
    NSArray *names = @[@"control", @"option", @"command", @"shift", @"disabled"];
    NSInteger selected = [names indexOfObject: config.disableKeyName];
    BOOL inverted = config.invertDisableKey;
    ARSegmentRow *key = [[ARSegmentRow alloc] initWithTitle: @"Hold this key"
        subtitle: nil choices: keys selected: selected == NSNotFound ? 4 : selected];
    ARSegmentRow *meaning = [[ARSegmentRow alloc] initWithTitle: @"While it is down"
        subtitle: @"So hovering can be switched off, or kept for when you ask"
        choices: @[@"Leave windows alone", @"Raise as usual"] selected: inverted ? 1 : 0];

    __weak ARSegmentRow *weakKey = key, *weakMeaning = meaning;
    void (^write)(void) = ^{
        NSInteger index = weakKey.segments.selectedSegment;
        NSString *name = names[index < 0 ? 0 : index];
        BOOL holdToRaise = weakMeaning.segments.selectedSegment == 1;
        [weakSelf set: @"disableKey" to: holdToRaise && index < 4
            ? [@"!" stringByAppendingString: name] : name];
    };
    key.onChange = ^(NSInteger index) { write(); };
    meaning.onChange = ^(NSInteger index) { write(); };
    [meaning setRowEnabled: config.disableKey != 0];

    [self addSectionTitle: @"MODIFIER KEY"];
    [self addCard: @[key, meaning]];
}

// Browsing for the application beats typing a localized name, and the bundle
// identifier it yields keeps working when the name changes.
- (void)addAppRule {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = YES;
    panel.allowedContentTypes = @[[UTType typeWithIdentifier: @"com.apple.application-bundle"]];
    panel.directoryURL = [NSURL fileURLWithPath: @"/Applications"];
    panel.prompt = @"Choose";
    if ([panel runModal] != NSModalResponseOK) { return; }

    for (NSURL *url in panel.URLs) {
        NSBundle *bundle = [NSBundle bundleWithURL: url];
        NSString *match = bundle.bundleIdentifier;
        if (!match.length) {
            match = [[NSFileManager defaultManager] displayNameAtPath: url.path]
                .stringByDeletingPathExtension;
        }
        // Leaving it alone is what people came to this page for; the menu on the
        // row changes it to anything else.
        if (match.length) { [[ARAppTable shared] setPolicy: ARAppPolicyIgnore for: match]; }
    }
    [self rebuild];
}

- (NSString *)joinList:(NSArray<NSString *> *)entries {
    NSMutableArray *escaped = [NSMutableArray array];
    for (NSString *entry in entries) {
        [escaped addObject: [entry stringByReplacingOccurrencesOfString: @"," withString: @"\\,"]];
    }
    return [escaped componentsJoinedByString: @","];
}

// Controls that are taller than a row get their own padded row.
- (NSView *)rowWrapping:(NSView *)view {
    NSView *wrapper = [[NSView alloc] init];
    wrapper.translatesAutoresizingMaskIntoConstraints = NO;
    [wrapper addSubview: view];
    [NSLayoutConstraint activateConstraints: @[
        [view.topAnchor constraintEqualToAnchor: wrapper.topAnchor constant: 12],
        [view.bottomAnchor constraintEqualToAnchor: wrapper.bottomAnchor constant: -12],
        [view.leadingAnchor constraintEqualToAnchor: wrapper.leadingAnchor constant: AR_ROW_INSET],
        [view.trailingAnchor constraintEqualToAnchor: wrapper.trailingAnchor
            constant: -AR_ROW_INSET],
    ]];
    return wrapper;
}

//------------------------------------------------ advanced ------------------------------------------------

- (void)buildAdvanced {
    ARConfig *config = self.config;
    __weak ARSettingsWindowController *weakSelf = self;

    ARSegmentRow *hitTest = [[ARSegmentRow alloc] initWithTitle: @"Find the hovered window with"
        subtitle: @"The window server is faster and cannot be held up by a busy app"
        choices: @[@"Window server", @"Accessibility"]
        selected: config.windowServerHitTest ? 0 : 1];
    hitTest.onChange = ^(NSInteger index) {
        [weakSelf setBool: @"windowServerHitTest" to: index == 0];
    };

    ARToggleRow *legacy = [[ARToggleRow alloc] initWithTitle: @"Activate apps the old way"
        subtitle: @"For apps built on GTK, SDL or wine that refuse to come forward"
        on: config.legacyActivation];
    legacy.onChange = ^(BOOL on) { [weakSelf setBool: @"legacyActivation" to: on]; };

    [self addCard: @[hitTest, legacy]];
    [self addFootnote: @"If the wrong window raises, switch the hit test to accessibility and "
                       "please report it."];

    ARToggleRow *reload = [[ARToggleRow alloc] initWithTitle: @"Watch the settings file"
        subtitle: @"Apply changes made in a text editor straight away" on: config.liveReload];
    reload.onChange = ^(BOOL on) { [weakSelf setBool: @"liveReload" to: on]; };

    ARToggleRow *verbose = [[ARToggleRow alloc] initWithTitle: @"Verbose logging"
        subtitle: @"Log every decision: log stream --process AutoRaise" on: config.verbose];
    verbose.onChange = ^(BOOL on) { [weakSelf setBool: @"verbose" to: on]; };

    NSString *path = [_delegate settingsFilePath];
    ARButtonRow *reveal = [[ARButtonRow alloc] initWithTitle: @"Settings file"
        subtitle: path.stringByAbbreviatingWithTildeInPath ?: @"Not created yet"
        buttonTitle: @"Show in Finder" action: ^{
            NSString *file = [weakSelf.settingsDelegate settingsFilePath];
            if (file) { [[NSWorkspace sharedWorkspace] selectFile: file
                inFileViewerRootedAtPath: file.stringByDeletingLastPathComponent]; }
        }];

    ARButtonRow *diagnostics = [[ARButtonRow alloc] initWithTitle: @"Diagnostics"
        subtitle: @"Everything worth putting in a bug report"
        buttonTitle: @"Copy" action: ^{
            NSPasteboard *board = [NSPasteboard generalPasteboard];
            [board clearContents];
            [board setString: [weakSelf.settingsDelegate diagnosticsReport] forType: NSPasteboardTypeString];
        }];

    ARButtonRow *reset = [[ARButtonRow alloc] initWithTitle: @"Reset everything"
        subtitle: @"Put every setting back the way it started"
        buttonTitle: @"Reset…" action: ^{ [weakSelf confirmReset]; }];

    [self addCard: @[reload, verbose, reveal, diagnostics, reset]];
}

- (void)confirmReset {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Reset all settings?";
    alert.informativeText = @"Every setting goes back to its default. Your exceptions and "
                             "shortcut are cleared as well.";
    [alert addButtonWithTitle: @"Reset"];
    [alert addButtonWithTitle: @"Cancel"];
    alert.alertStyle = NSAlertStyleWarning;
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [_delegate resetAllSettings];
        [self rebuild];
    }
}

//----------------------------------------------- statistics -----------------------------------------------

static NSString *ARGrouped(NSInteger value) {
    static NSNumberFormatter *formatter = nil;
    if (!formatter) {
        formatter = [[NSNumberFormatter alloc] init];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
    }
    return [formatter stringFromNumber: @(value)];
}

- (NSView *)tileRow:(NSArray<NSView *> *)tiles {
    NSStackView *row = [NSStackView stackViewWithViews: tiles];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.distribution = NSStackViewDistributionFillEqually;
    row.spacing = 8;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    return row;
}

- (void)buildStats {
    ARStats *stats = [ARStats shared];
    __weak ARSettingsWindowController *weakSelf = self;
    NSInteger saved = stats.clicksSaved;

    // The page leads with one figure, because that is the question being asked.
    NSDateFormatter *since = [[NSDateFormatter alloc] init];
    since.dateStyle = NSDateFormatterMediumStyle;
    since.timeStyle = NSDateFormatterNoStyle;
    NSString *caption = saved > 0
        ? [NSString stringWithFormat: @"clicks you did not have to make, since %@",
           [since stringFromDate: stats.since]]
        : @"no clicks saved yet: hover a window that is not in front and this starts counting";
    [self add: [[ARHeroFigure alloc] initWithValue: ARGrouped(saved) caption: caption]
        spacingAfter: 20];

    // A handful of headline numbers, each its own tile rather than a chart.
    NSMutableArray *tiles = [NSMutableArray array];
    [tiles addObject: [ARCard cardWithRows: @[[[ARStatTile alloc]
        initWithValue: ARGrouped(stats.today) label: @"today"]]]];
    [tiles addObject: [ARCard cardWithRows: @[[[ARStatTile alloc]
        initWithValue: ARGrouped(stats.raises) label: @"windows raised"]]]];
    [tiles addObject: [ARCard cardWithRows: @[[[ARStatTile alloc]
        initWithValue: ARGrouped(stats.focuses) label: @"focused where they stood"]]]];
    [self add: [self tileRow: tiles] spacingAfter: 8];

    if (stats.shortcutRaises > 0 || stats.warps > 0) {
        NSScreen *screen = NSScreen.screens.firstObject;
        CGFloat widths = screen ? stats.warpPixels / NSWidth(screen.frame) : 0;
        NSMutableArray *more = [NSMutableArray array];
        [more addObject: [ARCard cardWithRows: @[[[ARStatTile alloc]
            initWithValue: ARGrouped(stats.shortcutRaises) label: @"raised by shortcut"]]]];
        [more addObject: [ARCard cardWithRows: @[[[ARStatTile alloc]
            initWithValue: ARGrouped(stats.warps) label: @"pointer warps"]]]];
        [more addObject: [ARCard cardWithRows: @[[[ARStatTile alloc]
            initWithValue: [NSString stringWithFormat: @"%.0f", widths]
            label: @"screen widths the pointer skipped"]]]];
        [self add: [self tileRow: more] spacingAfter: 8];
    }

    [self addFootnote: @"A window raised or focused because you hovered it is a click you would "
                       "otherwise have made. Repeated attempts to make one app listen count once."];

    // Fourteen days of one series: a column each, so no legend is needed.
    NSTextField *chartTitle = ARLabel(@"Clicks saved per day",
        [NSFont systemFontOfSize: 12 weight: NSFontWeightSemibold], NSColor.labelColor);
    NSView *chartHeader = [[NSView alloc] init];
    chartHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [chartHeader addSubview: chartTitle];
    [NSLayoutConstraint activateConstraints: @[
        [chartTitle.topAnchor constraintEqualToAnchor: chartHeader.topAnchor constant: 12],
        [chartTitle.leadingAnchor constraintEqualToAnchor: chartHeader.leadingAnchor
            constant: AR_ROW_INSET],
        [chartHeader.bottomAnchor constraintEqualToAnchor: chartTitle.bottomAnchor],
    ]];
    ARColumnChart *chart = [[ARColumnChart alloc]
        initWithCounts: [stats countsForLastDays: 14] endDate: [NSDate date]
        tint: NSColor.controlAccentColor];
    [self addSectionTitle: @"THE LAST TWO WEEKS"];
    [self addCard: @[chartHeader, chart]];

    NSArray<ARAppTally *> *top = [stats topApps: 5];
    if (top.count) {
        NSMutableArray *rows = [NSMutableArray array];
        NSInteger largest = top.firstObject.count;
        for (ARAppTally *tally in top) {
            [rows addObject: [[ARRankRow alloc] initWithName: tally.name value: tally.count
                largest: largest tint: NSColor.controlAccentColor]];
        }
        [self addSectionTitle: @"WHERE THOSE CLICKS WOULD HAVE GONE"];
        [self addCard: rows];
    }

    ARButtonRow *reset = [[ARButtonRow alloc] initWithTitle: @"Start counting again"
        subtitle: @"Clears the figures on this page, nothing else"
        buttonTitle: @"Reset…" action: ^{ [weakSelf confirmStatsReset]; }];
    [self addCard: @[reset]];
}

- (void)confirmStatsReset {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Start counting again?";
    alert.informativeText = @"The figures on this page go back to zero. Your settings are not "
                             "affected.";
    [alert addButtonWithTitle: @"Reset"];
    [alert addButtonWithTitle: @"Cancel"];
    alert.alertStyle = NSAlertStyleWarning;
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [[ARStats shared] reset];
        [self rebuild];
    }
}

//-------------------------------------------------- about -------------------------------------------------

- (void)buildAbout {
    NSImage *icon = [NSApp applicationIconImage];
    NSImageView *iconView = [NSImageView imageViewWithImage: icon];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [iconView.widthAnchor constraintEqualToConstant: 96].active = YES;
    [iconView.heightAnchor constraintEqualToConstant: 96].active = YES;

    NSString *version = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"6.0";
    NSTextField *name = ARLabel(@"AutoRaise", [NSFont systemFontOfSize: 26 weight: NSFontWeightBold],
                                NSColor.labelColor);
    NSTextField *versionLabel = ARLabel([NSString stringWithFormat: @"Version %@", version],
        [NSFont systemFontOfSize: 12], NSColor.secondaryLabelColor);
    NSTextField *tagline = ARLabel(@"Hover a window, and it comes to the front.",
        [NSFont systemFontOfSize: 13], NSColor.labelColor);

    NSStackView *identity = [NSStackView stackViewWithViews: @[name, versionLabel, tagline]];
    identity.orientation = NSUserInterfaceLayoutOrientationVertical;
    identity.alignment = NSLayoutAttributeLeading;
    identity.spacing = 3;

    NSStackView *header = [NSStackView stackViewWithViews: @[iconView, identity]];
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.alignment = NSLayoutAttributeCenterY;
    header.spacing = 18;
    [self add: header spacingAfter: 24];

    ARButtonRow *project = [[ARButtonRow alloc] initWithTitle: @"Project page"
        subtitle: @"github.com/sbmpost/AutoRaise" buttonTitle: @"Open" action: ^{
            [[NSWorkspace sharedWorkspace] openURL:
                [NSURL URLWithString: @"https://github.com/sbmpost/AutoRaise"]];
        }];
    ARRow *license = [[ARRow alloc] initWithTitle: @"License"
        subtitle: @"GNU General Public License, version 2 or later" accessory: nil];
    ARRow *credits = [[ARRow alloc] initWithTitle: @"Built on other people's work"
        subtitle: @"metamove by jmgao, and the focus-first calls from yabai" accessory: nil];
    [self addCard: @[project, license, credits]];

    NSTextField *report = ARLabel([_delegate diagnosticsReport],
        [NSFont monospacedSystemFontOfSize: 11 weight: NSFontWeightRegular],
        NSColor.secondaryLabelColor);
    report.selectable = YES;
    [self addSectionTitle: @"THIS INSTALLATION"];
    [self addCard: @[[self rowWrapping: report]]];
}

//------------------------------------------------- window -------------------------------------------------

- (void)windowWillClose:(NSNotification *)notification {
    // Back to a menu bar only app: no dock icon, no menu bar of our own.
    [NSApp setActivationPolicy: NSApplicationActivationPolicyAccessory];
}

@end
