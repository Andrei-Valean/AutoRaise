/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 */

#import "SettingsUI.h"

#import <Carbon/Carbon.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "Config.h"   // shortcut parsing and formatting
#import "Stats.h"    // day labels for the chart

NSFont *ARTitleFont(void) { return [NSFont systemFontOfSize: 22 weight: NSFontWeightBold]; }
NSFont *ARRowFont(void) { return [NSFont systemFontOfSize: 13]; }
NSFont *ARSubtitleFont(void) { return [NSFont systemFontOfSize: 11]; }
NSFont *ARFootnoteFont(void) { return [NSFont systemFontOfSize: 11]; }
NSFont *ARValueFont(void) {
    return [NSFont monospacedDigitSystemFontOfSize: 13 weight: NSFontWeightMedium];
}

@interface ARWrappingLabel : NSTextField
@end

@implementation ARWrappingLabel
- (void)layout {
    [super layout];
    if (self.preferredMaxLayoutWidth != self.bounds.size.width) {
        self.preferredMaxLayoutWidth = self.bounds.size.width;
        [self invalidateIntrinsicContentSize];
    }
}
@end

NSTextField *ARLabel(NSString *text, NSFont *font, NSColor *color) {
    ARWrappingLabel *label = [[ARWrappingLabel alloc] init];
    label.stringValue = text;
    label.editable = NO;
    label.selectable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.font = font;
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    // The control next to it wins any argument about width.
    [label setContentCompressionResistancePriority: NSLayoutPriorityDefaultLow - 1
        forOrientation: NSLayoutConstraintOrientationHorizontal];
    return label;
}

static void ARPin(NSView *view, NSView *container, CGFloat leading, CGFloat trailing) {
    [NSLayoutConstraint activateConstraints: @[
        [view.leadingAnchor constraintEqualToAnchor: container.leadingAnchor constant: leading],
        [view.trailingAnchor constraintEqualToAnchor: container.trailingAnchor constant: -trailing],
    ]];
}

@implementation ARFlippedView
- (BOOL)isFlipped { return YES; }
@end

@implementation ARFillView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame: frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.wantsLayer = YES;
    }
    return self;
}

// AppKit runs this with the view's own appearance current, which is the only
// place a dynamic color turns into the right CGColor.
- (BOOL)wantsUpdateLayer { return YES; }

- (void)updateLayer {
    self.layer.cornerRadius = self.cornerRadius;
    if (@available(macOS 10.15, *)) {
        if (self.cornerRadius > 0) { self.layer.cornerCurve = kCACornerCurveContinuous; }
    }
    self.layer.backgroundColor = self.fillColor.CGColor;
    self.layer.borderWidth = self.strokeColor ? self.borderWidth : 0;
    self.layer.borderColor = self.strokeColor.CGColor;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

- (void)setFillColor:(NSColor *)fillColor {
    _fillColor = fillColor;
    self.needsDisplay = YES;
}

- (void)setStrokeColor:(NSColor *)strokeColor {
    _strokeColor = strokeColor;
    self.needsDisplay = YES;
}

@end

//-------------------------------------------------- card --------------------------------------------------

@implementation ARCard {
    NSStackView *_stack;
}

+ (instancetype)cardWithRows:(NSArray<NSView *> *)rows {
    ARCard *card = [[ARCard alloc] initWithFrame: NSZeroRect];
    [card setRows: rows];
    return card;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame: frame])) {
        self.cornerRadius = AR_CARD_RADIUS;
        self.borderWidth = 1;
        self.fillColor = NSColor.controlBackgroundColor;
        self.strokeColor = [NSColor.separatorColor colorWithAlphaComponent: 0.6];

        _stack = [[NSStackView alloc] init];
        _stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        _stack.alignment = NSLayoutAttributeLeading;
        _stack.spacing = 0;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview: _stack];
        [NSLayoutConstraint activateConstraints: @[
            [_stack.topAnchor constraintEqualToAnchor: self.topAnchor],
            [_stack.bottomAnchor constraintEqualToAnchor: self.bottomAnchor],
            [_stack.leadingAnchor constraintEqualToAnchor: self.leadingAnchor],
            [_stack.trailingAnchor constraintEqualToAnchor: self.trailingAnchor],
        ]];
    }
    return self;
}

- (void)setRows:(NSArray<NSView *> *)rows {
    for (NSView *view in _stack.views.copy) { [_stack removeView: view]; }
    for (NSUInteger i = 0; i < rows.count; i++) {
        if (i > 0) {
            ARFillView *separator = [[ARFillView alloc] initWithFrame: NSZeroRect];
            separator.fillColor = NSColor.separatorColor;
            [separator.heightAnchor constraintEqualToConstant: 1].active = YES;
            [_stack addView: separator inGravity: NSStackViewGravityTop];
            // Hairlines start under the label, as they do in system windows.
            ARPin(separator, _stack, AR_ROW_INSET, 0);
        }
        [_stack addView: rows[i] inGravity: NSStackViewGravityTop];
        ARPin(rows[i], _stack, 0, 0);
    }
}

@end

//--------------------------------------------------- row --------------------------------------------------

@implementation ARRow {
    NSMutableArray<NSView *> *_dimmable;
}

- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                    accessory:(NSView *)accessory {
    if ((self = [super initWithFrame: NSZeroRect])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _dimmable = [NSMutableArray array];

        _titleLabel = ARLabel(title, ARRowFont(), NSColor.labelColor);
        [self addSubview: _titleLabel];
        [_dimmable addObject: _titleLabel];

        if (subtitle.length) {
            _subtitleLabel = ARLabel(subtitle, ARSubtitleFont(), NSColor.secondaryLabelColor);
            [self addSubview: _subtitleLabel];
            [_dimmable addObject: _subtitleLabel];
        }

        _accessory = accessory;
        if (accessory) {
            accessory.translatesAutoresizingMaskIntoConstraints = NO;
            // Controls keep the width they ask for; the label gives way.
            [accessory setContentHuggingPriority: NSLayoutPriorityDefaultHigh
                forOrientation: NSLayoutConstraintOrientationHorizontal];
            [self addSubview: accessory];
            [_dimmable addObject: accessory];
        }

        NSMutableArray *constraints = [NSMutableArray array];
        [constraints addObject: [self.heightAnchor
            constraintGreaterThanOrEqualToConstant: AR_ROW_HEIGHT]];
        [constraints addObject: [_titleLabel.leadingAnchor
            constraintEqualToAnchor: self.leadingAnchor constant: AR_ROW_INSET]];

        NSLayoutXAxisAnchor *labelTrailing = accessory ? accessory.leadingAnchor
                                                       : self.trailingAnchor;
        CGFloat labelGap = accessory ? 12 : AR_ROW_INSET;
        [constraints addObject: [_titleLabel.trailingAnchor
            constraintLessThanOrEqualToAnchor: labelTrailing constant: -labelGap]];

        if (_subtitleLabel) {
            [constraints addObjectsFromArray: @[
                [_titleLabel.topAnchor constraintEqualToAnchor: self.topAnchor constant: 9],
                [_subtitleLabel.topAnchor constraintEqualToAnchor: _titleLabel.bottomAnchor constant: 2],
                [_subtitleLabel.leadingAnchor constraintEqualToAnchor: _titleLabel.leadingAnchor],
                // Equality, not a maximum: the label has to know its width to
                // work out how many lines it needs.
                [_subtitleLabel.trailingAnchor constraintEqualToAnchor: labelTrailing
                    constant: -labelGap],
                [self.bottomAnchor constraintEqualToAnchor: _subtitleLabel.bottomAnchor constant: 9],
            ]];
        } else {
            [constraints addObject: [_titleLabel.centerYAnchor
                constraintEqualToAnchor: self.centerYAnchor]];
        }

        if (accessory) {
            [constraints addObjectsFromArray: @[
                [accessory.trailingAnchor constraintEqualToAnchor: self.trailingAnchor
                    constant: -AR_ROW_INSET],
                [accessory.centerYAnchor constraintEqualToAnchor: self.centerYAnchor],
                [accessory.topAnchor constraintGreaterThanOrEqualToAnchor: self.topAnchor constant: 7],
                [accessory.bottomAnchor constraintLessThanOrEqualToAnchor: self.bottomAnchor
                    constant: -7],
            ]];
        }
        [NSLayoutConstraint activateConstraints: constraints];
    }
    return self;
}

- (void)setRowEnabled:(BOOL)enabled {
    for (NSView *view in _dimmable) {
        view.alphaValue = enabled ? 1.0 : 0.4;
        if ([view isKindOfClass: [NSControl class]]) { ((NSControl *) view).enabled = enabled; }
        if ([view respondsToSelector: @selector(setRowEnabled:)]) {
            [(ARRow *) view setRowEnabled: enabled];
        }
    }
}

@end

//------------------------------------------------- toggle -------------------------------------------------

@implementation ARToggleRow

- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle on:(BOOL)on {
    NSSwitch *toggle = [[NSSwitch alloc] init];
    toggle.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    if ((self = [super initWithTitle: title subtitle: subtitle accessory: toggle])) {
        _toggle = toggle;
        toggle.target = self;
        toggle.action = @selector(toggled:);
    }
    return self;
}

- (void)setOn:(BOOL)on {
    _toggle.state = on ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)toggled:(id)sender {
    if (self.onChange) { self.onChange(_toggle.state == NSControlStateValueOn); }
}

@end

//------------------------------------------------- slider -------------------------------------------------

@implementation ARSliderRow {
    NSTextField *_titleLabel;
    NSTextField *_valueLabel;
}

- (instancetype)initWithTitle:(NSString *)title min:(double)min max:(double)max value:(double)value {
    if ((self = [super initWithFrame: NSZeroRect])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;

        _titleLabel = ARLabel(title, ARRowFont(), NSColor.labelColor);
        _valueLabel = ARLabel(@"", ARValueFont(), NSColor.secondaryLabelColor);
        _valueLabel.alignment = NSTextAlignmentRight;

        _slider = [NSSlider sliderWithValue: value minValue: min maxValue: max
                                    target: self action: @selector(slid:)];
        _slider.controlSize = NSControlSizeRegular;
        _slider.continuous = YES;
        _slider.translatesAutoresizingMaskIntoConstraints = NO;

        [self addSubview: _titleLabel];
        [self addSubview: _valueLabel];
        [self addSubview: _slider];

        [NSLayoutConstraint activateConstraints: @[
            [_titleLabel.topAnchor constraintEqualToAnchor: self.topAnchor constant: 11],
            [_titleLabel.leadingAnchor constraintEqualToAnchor: self.leadingAnchor
                constant: AR_ROW_INSET],
            [_valueLabel.firstBaselineAnchor constraintEqualToAnchor: _titleLabel.firstBaselineAnchor],
            [_valueLabel.trailingAnchor constraintEqualToAnchor: self.trailingAnchor
                constant: -AR_ROW_INSET],
            [_valueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:
                _titleLabel.trailingAnchor constant: 12],
            [_slider.topAnchor constraintEqualToAnchor: _titleLabel.bottomAnchor constant: 8],
            [_slider.leadingAnchor constraintEqualToAnchor: self.leadingAnchor constant: AR_ROW_INSET],
            [_slider.trailingAnchor constraintEqualToAnchor: self.trailingAnchor
                constant: -AR_ROW_INSET],
            [self.bottomAnchor constraintEqualToAnchor: _slider.bottomAnchor constant: 12],
        ]];
        [self refreshValueLabel];
    }
    return self;
}

- (void)setFormat:(NSString *(^)(double))format {
    _format = format;
    [self refreshValueLabel];
}

- (void)refreshValueLabel {
    _valueLabel.stringValue = self.format ? self.format(_slider.doubleValue)
                                          : [NSString stringWithFormat: @"%.0f", _slider.doubleValue];
}

- (void)setValue:(double)value {
    _slider.doubleValue = value;
    [self refreshValueLabel];
}

- (void)setRowEnabled:(BOOL)enabled {
    _slider.enabled = enabled;
    CGFloat alpha = enabled ? 1.0 : 0.4;
    _titleLabel.alphaValue = alpha;
    _valueLabel.alphaValue = alpha;
    _slider.alphaValue = alpha;
}

- (void)slid:(id)sender {
    if (self.snapsToIntegers) { _slider.doubleValue = round(_slider.doubleValue); }
    [self refreshValueLabel];
    if (self.onChange) { self.onChange(_slider.doubleValue); }
    // Writing the settings file on every pixel of a drag would be silly, so the
    // file is written when the mouse comes back up.
    BOOL stillDragging = NSApp.currentEvent.type == NSEventTypeLeftMouseDragged ||
                         NSApp.currentEvent.type == NSEventTypeLeftMouseDown;
    if (!stillDragging && self.onCommit) { self.onCommit(_slider.doubleValue); }
}

@end

//------------------------------------------------ segments ------------------------------------------------

@implementation ARSegmentRow

- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                      choices:(NSArray<NSString *> *)choices
                     selected:(NSInteger)selected {
    NSSegmentedControl *segments = [NSSegmentedControl segmentedControlWithLabels: choices
        trackingMode: NSSegmentSwitchTrackingSelectOne target: nil action: nil];
    segments.selectedSegment = selected;
    if ((self = [super initWithTitle: title subtitle: subtitle accessory: segments])) {
        _segments = segments;
        segments.target = self;
        segments.action = @selector(changed:);
    }
    return self;
}

- (void)setSelected:(NSInteger)index { _segments.selectedSegment = index; }

- (void)changed:(id)sender {
    if (self.onChange) { self.onChange(_segments.selectedSegment); }
}

@end

//-------------------------------------------------- popup -------------------------------------------------

@implementation ARPopupRow

- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                      choices:(NSArray<NSString *> *)choices
                     selected:(NSInteger)selected {
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame: NSZeroRect pullsDown: NO];
    [popup addItemsWithTitles: choices];
    if (selected >= 0 && selected < (NSInteger) choices.count) {
        [popup selectItemAtIndex: selected];
    }
    if ((self = [super initWithTitle: title subtitle: subtitle accessory: popup])) {
        _popup = popup;
        popup.target = self;
        popup.action = @selector(changed:);
    }
    return self;
}

- (void)changed:(id)sender {
    if (self.onChange) { self.onChange(_popup.indexOfSelectedItem); }
}

@end

//-------------------------------------------------- field -------------------------------------------------

@implementation ARFieldRow

- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                        value:(NSString *)value
                        width:(CGFloat)width
                  placeholder:(NSString *)placeholder {
    NSTextField *field = [NSTextField textFieldWithString: value];
    field.placeholderString = placeholder;
    field.alignment = NSTextAlignmentRight;
    field.font = ARValueFont();
    [field.widthAnchor constraintEqualToConstant: width].active = YES;
    if ((self = [super initWithTitle: title subtitle: subtitle accessory: field])) {
        _field = field;
        field.target = self;
        field.action = @selector(committed:);
        field.delegate = (id<NSTextFieldDelegate>) self;
    }
    return self;
}

- (void)committed:(id)sender {
    if (self.onChange) { self.onChange(_field.stringValue); }
}

// Leaving the field counts as confirming it, which is what people expect.
- (void)controlTextDidEndEditing:(NSNotification *)notification {
    [self committed: nil];
}

@end

//------------------------------------------------- button -------------------------------------------------

@interface ARButtonRow ()
@property (nonatomic, copy) void (^handler)(void);
@end

@implementation ARButtonRow

- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                  buttonTitle:(NSString *)buttonTitle
                       action:(void (^)(void))action {
    NSButton *button = [NSButton buttonWithTitle: buttonTitle target: nil action: nil];
    button.bezelStyle = NSBezelStyleRounded;
    button.controlSize = NSControlSizeRegular;
    if ((self = [super initWithTitle: title subtitle: subtitle accessory: button])) {
        _handler = action;
        button.target = self;
        button.action = @selector(pressed:);
    }
    return self;
}

- (void)pressed:(id)sender { if (self.handler) { self.handler(); } }

@end

//----------------------------------------------- list editor ----------------------------------------------

@interface ARListEditor () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation ARListEditor {
    NSTableView *_table;
    NSMutableArray<NSString *> *_rows;
    NSButton *_remove;
    BOOL _allowsApps;
    BOOL _bundleIdMode;
}

- (instancetype)initWithEntries:(NSArray<NSString *> *)entries
                    allowsApps:(BOOL)allowsApps
                   bundleIdMode:(BOOL)bundleIdMode {
    if ((self = [super initWithFrame: NSZeroRect])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _rows = [entries mutableCopy] ?: [NSMutableArray array];
        _allowsApps = allowsApps;
        _bundleIdMode = bundleIdMode;
        _placeholder = @"Nothing yet";

        _table = [[NSTableView alloc] init];
        _table.headerView = nil;
        _table.rowHeight = 24;
        _table.style = NSTableViewStyleInset;
        _table.backgroundColor = NSColor.clearColor;
        _table.gridStyleMask = NSTableViewGridNone;
        _table.allowsMultipleSelection = YES;
        _table.dataSource = self;
        _table.delegate = self;
        _table.target = self;
        _table.doubleAction = @selector(editSelected:);
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier: @"entry"];
        column.editable = YES;
        [_table addTableColumn: column];

        NSScrollView *scroll = [[NSScrollView alloc] init];
        scroll.documentView = _table;
        scroll.hasVerticalScroller = YES;
        scroll.drawsBackground = NO;
        scroll.borderType = NSNoBorder;
        scroll.translatesAutoresizingMaskIntoConstraints = NO;

        ARFillView *frame = [[ARFillView alloc] initWithFrame: NSZeroRect];
        frame.cornerRadius = 6;
        frame.borderWidth = 1;
        frame.strokeColor = NSColor.separatorColor;
        frame.fillColor = NSColor.textBackgroundColor;
        [frame addSubview: scroll];
        [self addSubview: frame];

        NSButton *add = [NSButton buttonWithImage:
            [NSImage imageWithSystemSymbolName: @"plus" accessibilityDescription: @"Add"]
            target: self action: @selector(add:)];
        _remove = [NSButton buttonWithImage:
            [NSImage imageWithSystemSymbolName: @"minus" accessibilityDescription: @"Remove"]
            target: self action: @selector(remove:)];
        for (NSButton *button in @[add, _remove]) {
            button.bezelStyle = NSBezelStyleSmallSquare;
            button.bordered = NO;
            button.translatesAutoresizingMaskIntoConstraints = NO;
            [button.widthAnchor constraintEqualToConstant: 26].active = YES;
            [button.heightAnchor constraintEqualToConstant: 22].active = YES;
        }
        _remove.enabled = NO;

        NSStackView *buttons = [NSStackView stackViewWithViews: @[add, _remove]];
        buttons.spacing = 2;
        buttons.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview: buttons];

        [NSLayoutConstraint activateConstraints: @[
            [frame.topAnchor constraintEqualToAnchor: self.topAnchor],
            [frame.leadingAnchor constraintEqualToAnchor: self.leadingAnchor],
            [frame.trailingAnchor constraintEqualToAnchor: self.trailingAnchor],
            [frame.heightAnchor constraintEqualToConstant: 92],
            [scroll.topAnchor constraintEqualToAnchor: frame.topAnchor constant: 1],
            [scroll.bottomAnchor constraintEqualToAnchor: frame.bottomAnchor constant: -1],
            [scroll.leadingAnchor constraintEqualToAnchor: frame.leadingAnchor constant: 1],
            [scroll.trailingAnchor constraintEqualToAnchor: frame.trailingAnchor constant: -1],
            [buttons.topAnchor constraintEqualToAnchor: frame.bottomAnchor constant: 4],
            [buttons.leadingAnchor constraintEqualToAnchor: self.leadingAnchor],
            [self.bottomAnchor constraintEqualToAnchor: buttons.bottomAnchor],
        ]];
    }
    return self;
}

- (NSArray<NSString *> *)entries { return [_rows copy]; }

- (void)setEntries:(NSArray<NSString *> *)entries {
    _rows = [entries mutableCopy] ?: [NSMutableArray array];
    [_table reloadData];
}

- (void)commit {
    if (self.onChange) { self.onChange([_rows copy]); }
}

- (void)add:(id)sender {
    if (!_allowsApps) { [self addPlaceholderRow]; return; }

    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle: @"Choose Application…" action: @selector(chooseApp:) keyEquivalent: @""];
    [menu addItemWithTitle: @"Type It Myself" action: @selector(addPlaceholderRow) keyEquivalent: @""];
    for (NSMenuItem *item in menu.itemArray) { item.target = self; }
    [menu popUpMenuPositioningItem: nil atLocation:
        NSMakePoint(0, ((NSView *) sender).bounds.size.height + 2) inView: sender];
}

- (void)addPlaceholderRow {
    [_rows addObject: _bundleIdMode ? @"com.example.app" : @"New entry"];
    [_table reloadData];
    NSInteger row = _rows.count - 1;
    [_table selectRowIndexes: [NSIndexSet indexSetWithIndex: row] byExtendingSelection: NO];
    [_table editColumn: 0 row: row withEvent: nil select: YES];
}

- (void)chooseApp:(id)sender {
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
        NSString *entry = nil;
        if (_bundleIdMode) {
            entry = bundle.bundleIdentifier;
        } else {
            // The name the accessibility API reports, which is the display name.
            entry = [[NSFileManager defaultManager] displayNameAtPath: url.path];
            entry = entry.stringByDeletingPathExtension;
        }
        if (entry.length && ![_rows containsObject: entry]) { [_rows addObject: entry]; }
    }
    [_table reloadData];
    [self commit];
}

- (void)remove:(id)sender {
    NSIndexSet *selected = _table.selectedRowIndexes;
    if (!selected.count) { return; }
    [_rows removeObjectsAtIndexes: selected];
    [_table reloadData];
    [self commit];
}

- (void)editSelected:(id)sender {
    if (_table.clickedRow >= 0) {
        [_table editColumn: 0 row: _table.clickedRow withEvent: nil select: YES];
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _rows.count ?: 1;   // one row to hold the "nothing yet" hint
}

- (NSView *)tableView:(NSTableView *)tableView
    viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSTableCellView *cell = [tableView makeViewWithIdentifier: @"cell" owner: self];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        cell.identifier = @"cell";
        NSTextField *field = [NSTextField labelWithString: @""];
        field.font = ARRowFont();
        field.translatesAutoresizingMaskIntoConstraints = NO;
        field.drawsBackground = NO;
        field.bordered = NO;
        [cell addSubview: field];
        cell.textField = field;
        [NSLayoutConstraint activateConstraints: @[
            [field.leadingAnchor constraintEqualToAnchor: cell.leadingAnchor constant: 2],
            [field.trailingAnchor constraintEqualToAnchor: cell.trailingAnchor constant: -2],
            [field.centerYAnchor constraintEqualToAnchor: cell.centerYAnchor],
        ]];
    }
    if (!_rows.count) {
        cell.textField.stringValue = _placeholder;
        cell.textField.textColor = NSColor.tertiaryLabelColor;
        cell.textField.editable = NO;
        cell.textField.selectable = NO;
    } else {
        cell.textField.stringValue = _rows[row];
        cell.textField.textColor = NSColor.labelColor;
        cell.textField.editable = YES;
        cell.textField.selectable = YES;
        cell.textField.target = self;
        cell.textField.action = @selector(cellEdited:);
    }
    return cell;
}

- (void)cellEdited:(NSTextField *)field {
    NSInteger row = [_table rowForView: field];
    if (row < 0 || row >= (NSInteger) _rows.count) { return; }
    NSString *value = [field.stringValue stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
    if (value.length) { _rows[row] = value; }
    else { [_rows removeObjectAtIndex: row]; }
    [_table reloadData];
    [self commit];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    _remove.enabled = _rows.count && _table.selectedRowIndexes.count;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return _rows.count > 0;
}

@end

//---------------------------------------------- warp target -----------------------------------------------

@implementation ARWarpTargetView {
    BOOL _dragging;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame: frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _target = CGPointMake(0.5, 0.5);
        [self.widthAnchor constraintEqualToConstant: 132].active = YES;
        [self.heightAnchor constraintEqualToConstant: 84].active = YES;
    }
    return self;
}

- (NSRect)mockRect { return NSInsetRect(self.bounds, 2, 2); }

// The window mock uses the same shape language as the app icon: a card with a
// title bar, and the pointer sitting wherever the mouse will land.
- (void)drawRect:(NSRect)dirty {
    NSRect mock = self.mockRect;
    NSBezierPath *card = [NSBezierPath bezierPathWithRoundedRect: mock xRadius: 6 yRadius: 6];
    [NSColor.textBackgroundColor setFill];
    [card fill];
    [[NSColor.separatorColor colorWithAlphaComponent: 0.9] setStroke];
    card.lineWidth = 1;
    [card stroke];

    NSRect titleBar = NSMakeRect(mock.origin.x, NSMaxY(mock) - 14, mock.size.width, 14);
    NSBezierPath *bar = [NSBezierPath bezierPathWithRoundedRect: titleBar xRadius: 6 yRadius: 6];
    [[NSColor.controlAccentColor colorWithAlphaComponent: 0.16] setFill];
    [bar fill];
    [[NSColor.controlAccentColor colorWithAlphaComponent: 0.55] setFill];
    for (int i = 0; i < 3; i++) {
        NSRect dot = NSMakeRect(titleBar.origin.x + 6 + i * 8, NSMidY(titleBar) - 2.5, 5, 5);
        [[NSBezierPath bezierPathWithOvalInRect: dot] fill];
    }

    // Guides, so the eye can find the centre without dragging.
    [[NSColor.separatorColor colorWithAlphaComponent: 0.5] setStroke];
    NSBezierPath *guides = [NSBezierPath bezierPath];
    guides.lineWidth = 1;
    CGFloat dashes[2] = {2, 3};
    [guides setLineDash: dashes count: 2 phase: 0];
    [guides moveToPoint: NSMakePoint(NSMidX(mock), NSMinY(mock) + 3)];
    [guides lineToPoint: NSMakePoint(NSMidX(mock), NSMaxY(mock) - 3)];
    [guides moveToPoint: NSMakePoint(NSMinX(mock) + 3, NSMidY(mock))];
    [guides lineToPoint: NSMakePoint(NSMaxX(mock) - 3, NSMidY(mock))];
    [guides stroke];

    NSPoint point = [self pointForTarget];
    NSRect halo = NSMakeRect(point.x - 11, point.y - 11, 22, 22);
    [[NSColor.controlAccentColor colorWithAlphaComponent: _dragging ? 0.30 : 0.18] setFill];
    [[NSBezierPath bezierPathWithOvalInRect: halo] fill];

    // A small pointer, drawn from the same outline as the app icon.
    static const CGPoint outline[] = {
        {0.000, 1.000}, {0.000, 0.128}, {0.236, 0.356}, {0.379, 0.000},
        {0.548, 0.063}, {0.409, 0.414}, {0.716, 0.437},
    };
    CGFloat size = 15;
    NSBezierPath *pointer = [NSBezierPath bezierPath];
    for (size_t i = 0; i < sizeof(outline) / sizeof(outline[0]); i++) {
        NSPoint p = NSMakePoint(point.x + outline[i].x * size - 1,
                                point.y - (1.0 - outline[i].y) * size + 1);
        if (i == 0) { [pointer moveToPoint: p]; } else { [pointer lineToPoint: p]; }
    }
    [pointer closePath];
    [NSColor.controlAccentColor setFill];
    [pointer fill];
    [NSColor.textBackgroundColor setStroke];
    pointer.lineWidth = 1;
    [pointer stroke];
}

- (NSPoint)pointForTarget {
    NSRect mock = self.mockRect;
    return NSMakePoint(NSMinX(mock) + _target.x * mock.size.width,
                       NSMaxY(mock) - _target.y * mock.size.height);
}

- (void)setTarget:(CGPoint)target {
    _target = CGPointMake(fmin(fmax(target.x, 0), 1), fmin(fmax(target.y, 0), 1));
    self.needsDisplay = YES;
}

- (void)mouseDown:(NSEvent *)event { _dragging = YES; [self trackTo: event]; }
- (void)mouseDragged:(NSEvent *)event { [self trackTo: event]; }

- (void)mouseUp:(NSEvent *)event {
    _dragging = NO;
    [self trackTo: event];
    if (self.onChange) { self.onChange(_target); }
}

- (void)trackTo:(NSEvent *)event {
    NSPoint local = [self convertPoint: event.locationInWindow fromView: nil];
    NSRect mock = self.mockRect;
    // Snap to the middle and the edges, which are the values people actually want.
    CGFloat x = (local.x - NSMinX(mock)) / mock.size.width;
    CGFloat y = (NSMaxY(mock) - local.y) / mock.size.height;
    static const CGFloat snaps[] = {0.0, 0.5, 1.0};
    for (size_t i = 0; i < sizeof(snaps) / sizeof(snaps[0]); i++) {
        if (fabs(x - snaps[i]) < 0.04) { x = snaps[i]; }
        if (fabs(y - snaps[i]) < 0.04) { y = snaps[i]; }
    }
    self.target = CGPointMake(x, y);
}

- (BOOL)acceptsFirstResponder { return NO; }

@end

//--------------------------------------------- shortcut field ---------------------------------------------

@implementation ARShortcutField {
    BOOL _recording;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame: frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.bezelStyle = NSBezelStyleRounded;
        self.target = self;
        self.action = @selector(startRecording:);
        [self.widthAnchor constraintGreaterThanOrEqualToConstant: 110].active = YES;
        [self refreshTitle];
    }
    return self;
}

- (void)setShortcut:(NSString *)shortcut {
    _shortcut = [shortcut copy];
    [self refreshTitle];
}

- (void)refreshTitle {
    if (_recording) {
        self.title = @"Press keys…";
        self.font = ARRowFont();
        return;
    }
    ARShortcut parsed = ARShortcutParse(_shortcut);
    self.title = parsed.valid ? ARShortcutDisplay(parsed) : @"Record Shortcut";
    self.font = parsed.valid ? [NSFont systemFontOfSize: 13 weight: NSFontWeightMedium]
                             : ARRowFont();
}

- (void)startRecording:(id)sender {
    _recording = YES;
    [self refreshTitle];
    [self.window makeFirstResponder: self];
}

- (BOOL)acceptsFirstResponder { return YES; }

- (BOOL)resignFirstResponder {
    if (_recording) { _recording = NO; [self refreshTitle]; }
    return YES;
}

- (void)keyDown:(NSEvent *)event {
    if (!_recording) { [super keyDown: event]; return; }

    if (event.keyCode == kVK_Escape) {
        _recording = NO;
        [self refreshTitle];
        return;
    }
    if (event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete) {
        _recording = NO;
        self.shortcut = nil;
        if (self.onChange) { self.onChange(nil); }
        return;
    }

    ARShortcut shortcut = {YES, event.keyCode, 0};
    NSEventModifierFlags flags = event.modifierFlags;
    if (flags & NSEventModifierFlagControl) { shortcut.modifiers |= kCGEventFlagMaskControl; }
    if (flags & NSEventModifierFlagOption) { shortcut.modifiers |= kCGEventFlagMaskAlternate; }
    if (flags & NSEventModifierFlagShift) { shortcut.modifiers |= kCGEventFlagMaskShift; }
    if (flags & NSEventModifierFlagCommand) { shortcut.modifiers |= kCGEventFlagMaskCommand; }

    NSString *described = shortcut.modifiers ? ARShortcutDescribe(shortcut) : nil;
    if (!described) {
        // A shortcut with no modifier would fire while typing. Keep recording.
        NSBeep();
        return;
    }
    _recording = NO;
    self.shortcut = described;
    if (self.onChange) { self.onChange(described); }
}

- (void)flagsChanged:(NSEvent *)event {
    if (!_recording) { [super flagsChanged: event]; }
}

@end

//-------------------------------------------------- notice ------------------------------------------------

@interface ARNoticeView ()
@property (nonatomic, copy, nullable) void (^handler)(void);
@end

@implementation ARNoticeView

- (instancetype)initWithSymbol:(NSString *)symbol
                         tint:(NSColor *)tint
                        title:(NSString *)title
                      message:(NSString *)message
                  buttonTitle:(NSString *)buttonTitle
                       action:(void (^)(void))action {
    if ((self = [super initWithFrame: NSZeroRect])) {
        self.cornerRadius = AR_CARD_RADIUS;
        self.fillColor = [tint colorWithAlphaComponent: 0.12];
        _handler = action;

        NSImageView *icon = [NSImageView imageViewWithImage:
            [NSImage imageWithSystemSymbolName: symbol accessibilityDescription: title]];
        icon.contentTintColor = tint;
        icon.symbolConfiguration = [NSImageSymbolConfiguration
            configurationWithPointSize: 20 weight: NSFontWeightSemibold];
        icon.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *titleLabel = ARLabel(title,
            [NSFont systemFontOfSize: 13 weight: NSFontWeightSemibold], NSColor.labelColor);
        NSTextField *messageLabel = ARLabel(message, ARSubtitleFont(), NSColor.secondaryLabelColor);
        messageLabel.preferredMaxLayoutWidth = 320;

        [self addSubview: icon];
        [self addSubview: titleLabel];
        [self addSubview: messageLabel];

        NSMutableArray *constraints = [@[
            [icon.leadingAnchor constraintEqualToAnchor: self.leadingAnchor constant: 14],
            [icon.topAnchor constraintEqualToAnchor: self.topAnchor constant: 13],
            [titleLabel.leadingAnchor constraintEqualToAnchor: icon.trailingAnchor constant: 12],
            [titleLabel.topAnchor constraintEqualToAnchor: self.topAnchor constant: 12],
            [messageLabel.leadingAnchor constraintEqualToAnchor: titleLabel.leadingAnchor],
            [messageLabel.topAnchor constraintEqualToAnchor: titleLabel.bottomAnchor constant: 2],
            [self.bottomAnchor constraintEqualToAnchor: messageLabel.bottomAnchor constant: 13],
        ] mutableCopy];

        if (buttonTitle.length) {
            NSButton *button = [NSButton buttonWithTitle: buttonTitle target: self
                                                 action: @selector(pressed:)];
            button.bezelStyle = NSBezelStyleRounded;
            button.controlSize = NSControlSizeRegular;
            button.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview: button];
            [constraints addObjectsFromArray: @[
                [button.trailingAnchor constraintEqualToAnchor: self.trailingAnchor constant: -14],
                [button.centerYAnchor constraintEqualToAnchor: self.centerYAnchor],
                [button.leadingAnchor constraintGreaterThanOrEqualToAnchor:
                    titleLabel.trailingAnchor constant: 12],
                [button.leadingAnchor constraintGreaterThanOrEqualToAnchor:
                    messageLabel.trailingAnchor constant: 12],
            ]];
        } else {
            [constraints addObjectsFromArray: @[
                [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:
                    self.trailingAnchor constant: -14],
                [messageLabel.trailingAnchor constraintLessThanOrEqualToAnchor:
                    self.trailingAnchor constant: -14],
            ]];
        }
        [NSLayoutConstraint activateConstraints: constraints];
    }
    return self;
}

- (void)pressed:(id)sender { if (self.handler) { self.handler(); } }

@end

//----------------------------------------------- figures ---------------------------------------------------

@implementation ARHeroFigure

- (instancetype)initWithValue:(NSString *)value caption:(NSString *)caption {
    if ((self = [super initWithFrame: NSZeroRect])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        // Big enough to be the thing you read first, in ink rather than the
        // data colour.
        NSTextField *figure = ARLabel(value,
            [NSFont monospacedDigitSystemFontOfSize: 52 weight: NSFontWeightBold],
            NSColor.labelColor);
        NSTextField *label = ARLabel(caption, [NSFont systemFontOfSize: 13],
                                     NSColor.secondaryLabelColor);
        label.preferredMaxLayoutWidth = AR_CONTENT_WIDTH - AR_ROW_INSET * 2;
        [self addSubview: figure];
        [self addSubview: label];
        [NSLayoutConstraint activateConstraints: @[
            [figure.topAnchor constraintEqualToAnchor: self.topAnchor],
            [figure.leadingAnchor constraintEqualToAnchor: self.leadingAnchor],
            [figure.trailingAnchor constraintLessThanOrEqualToAnchor: self.trailingAnchor],
            [label.topAnchor constraintEqualToAnchor: figure.bottomAnchor constant: 2],
            [label.leadingAnchor constraintEqualToAnchor: self.leadingAnchor],
            [label.trailingAnchor constraintEqualToAnchor: self.trailingAnchor],
            [self.bottomAnchor constraintEqualToAnchor: label.bottomAnchor],
        ]];
    }
    return self;
}

@end

@implementation ARStatTile

- (instancetype)initWithValue:(NSString *)value label:(NSString *)label {
    if ((self = [super initWithFrame: NSZeroRect])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *figure = ARLabel(value,
            [NSFont monospacedDigitSystemFontOfSize: 22 weight: NSFontWeightSemibold],
            NSColor.labelColor);
        NSTextField *caption = ARLabel(label, ARSubtitleFont(), NSColor.secondaryLabelColor);
        caption.preferredMaxLayoutWidth = 150;
        [self addSubview: figure];
        [self addSubview: caption];
        [NSLayoutConstraint activateConstraints: @[
            [figure.topAnchor constraintEqualToAnchor: self.topAnchor constant: 12],
            [figure.leadingAnchor constraintEqualToAnchor: self.leadingAnchor
                constant: AR_ROW_INSET],
            [figure.trailingAnchor constraintLessThanOrEqualToAnchor: self.trailingAnchor
                constant: -AR_ROW_INSET],
            [caption.topAnchor constraintEqualToAnchor: figure.bottomAnchor constant: 1],
            [caption.leadingAnchor constraintEqualToAnchor: figure.leadingAnchor],
            [caption.trailingAnchor constraintEqualToAnchor: self.trailingAnchor
                constant: -AR_ROW_INSET],
            [self.bottomAnchor constraintEqualToAnchor: caption.bottomAnchor constant: 12],
        ]];
    }
    return self;
}

@end

//--------------------------------------------- column chart -----------------------------------------------

#define AR_COLUMN_MAX_WIDTH 24.0
#define AR_COLUMN_GAP 2.0
#define AR_COLUMN_CAP 4.0
#define AR_CHART_LABEL_HEIGHT 16.0

@implementation ARColumnChart {
    NSArray<NSNumber *> *_counts;
    NSDate *_endDate;
    NSColor *_tint;
}

- (instancetype)initWithCounts:(NSArray<NSNumber *> *)counts
                       endDate:(NSDate *)endDate
                       tint:(NSColor *)tint {
    if ((self = [super initWithFrame: NSZeroRect])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _counts = [counts copy];
        _endDate = endDate;
        _tint = tint;
        [self.heightAnchor constraintEqualToConstant: 132].active = YES;
    }
    return self;
}

- (NSInteger)largest {
    NSInteger largest = 0;
    for (NSNumber *count in _counts) { largest = MAX(largest, count.integerValue); }
    return largest;
}

- (void)drawRect:(NSRect)dirty {
    if (!_counts.count) { return; }
    NSRect bounds = NSInsetRect(self.bounds, AR_ROW_INSET, 0);
    CGFloat baseline = NSMinY(bounds) + AR_CHART_LABEL_HEIGHT;
    CGFloat plotHeight = NSMaxY(bounds) - baseline - 18;   // room for the one label
    NSInteger largest = [self largest];

    // One hairline baseline, a step off the surface. No gridlines: fourteen
    // columns and a labelled maximum carry the reading on their own.
    [[NSColor.separatorColor colorWithAlphaComponent: 0.9] setStroke];
    NSBezierPath *axis = [NSBezierPath bezierPath];
    axis.lineWidth = 1;
    [axis moveToPoint: NSMakePoint(NSMinX(bounds), baseline - 0.5)];
    [axis lineToPoint: NSMakePoint(NSMaxX(bounds), baseline - 0.5)];
    [axis stroke];

    CGFloat slot = bounds.size.width / _counts.count;
    CGFloat width = fmin(AR_COLUMN_MAX_WIDTH, slot - AR_COLUMN_GAP);
    NSInteger peakIndex = -1;
    for (NSInteger i = 0; i < (NSInteger) _counts.count; i++) {
        if (_counts[i].integerValue == largest && largest > 0) { peakIndex = i; }
    }

    for (NSInteger i = 0; i < (NSInteger) _counts.count; i++) {
        NSInteger value = _counts[i].integerValue;
        CGFloat x = NSMinX(bounds) + slot * i + (slot - width) / 2;
        CGFloat height = largest > 0 ? plotHeight * value / largest : 0;

        if (value == 0) {
            // A day with nothing gets a token of a column, so the axis reads as
            // a series of days rather than a gap.
            NSRect stub = NSMakeRect(x, baseline, width, 2);
            [[NSColor.separatorColor colorWithAlphaComponent: 0.7] setFill];
            [[NSBezierPath bezierPathWithRect: stub] fill];
            continue;
        }
        height = fmax(height, AR_COLUMN_CAP);

        // Rounded at the data end, square at the baseline.
        NSRect bar = NSMakeRect(x, baseline, width, height);
        NSBezierPath *column = [NSBezierPath bezierPath];
        CGFloat radius = fmin(AR_COLUMN_CAP, width / 2);
        [column moveToPoint: NSMakePoint(NSMinX(bar), NSMinY(bar))];
        [column lineToPoint: NSMakePoint(NSMinX(bar), NSMaxY(bar) - radius)];
        [column appendBezierPathWithArcFromPoint: NSMakePoint(NSMinX(bar), NSMaxY(bar))
            toPoint: NSMakePoint(NSMinX(bar) + radius, NSMaxY(bar)) radius: radius];
        [column lineToPoint: NSMakePoint(NSMaxX(bar) - radius, NSMaxY(bar))];
        [column appendBezierPathWithArcFromPoint: NSMakePoint(NSMaxX(bar), NSMaxY(bar))
            toPoint: NSMakePoint(NSMaxX(bar), NSMaxY(bar) - radius) radius: radius];
        [column lineToPoint: NSMakePoint(NSMaxX(bar), NSMinY(bar))];
        [column closePath];
        [(i == peakIndex ? _tint : [_tint colorWithAlphaComponent: 0.55]) setFill];
        [column fill];

        // The extreme is the only column with a number on it.
        if (i == peakIndex) {
            NSString *text = [NSString stringWithFormat: @"%ld", (long) value];
            NSDictionary *attributes = @{
                NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize: 10
                    weight: NSFontWeightSemibold],
                NSForegroundColorAttributeName: NSColor.secondaryLabelColor};
            NSSize size = [text sizeWithAttributes: attributes];
            [text drawAtPoint: NSMakePoint(NSMidX(bar) - size.width / 2, NSMaxY(bar) + 3)
                withAttributes: attributes];
        }
    }

    // Two dates, at the ends, rather than fourteen.
    NSDictionary *dayAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize: 10],
        NSForegroundColorAttributeName: NSColor.tertiaryLabelColor};
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *first = [calendar dateByAddingUnit: NSCalendarUnitDay
        value: -((NSInteger) _counts.count - 1) toDate: _endDate options: 0];
    [[ARStats shortDayLabelFor: first] drawAtPoint: NSMakePoint(NSMinX(bounds), NSMinY(bounds))
        withAttributes: dayAttributes];
    NSString *last = @"today";
    NSSize lastSize = [last sizeWithAttributes: dayAttributes];
    [last drawAtPoint: NSMakePoint(NSMaxX(bounds) - lastSize.width, NSMinY(bounds))
        withAttributes: dayAttributes];
}

// The value of a day is one hover away, rather than printed fourteen times.
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    [self removeAllToolTips];
    if (!_counts.count) { return; }
    NSRect bounds = NSInsetRect(self.bounds, AR_ROW_INSET, 0);
    CGFloat slot = bounds.size.width / _counts.count;
    NSCalendar *calendar = [NSCalendar currentCalendar];
    for (NSInteger i = 0; i < (NSInteger) _counts.count; i++) {
        NSRect slotRect = NSMakeRect(NSMinX(bounds) + slot * i, NSMinY(bounds), slot,
                                     bounds.size.height);
        NSDate *day = [calendar dateByAddingUnit: NSCalendarUnitDay
            value: -((NSInteger) _counts.count - 1 - i) toDate: _endDate options: 0];
        NSString *tip = [NSString stringWithFormat: @"%@: %ld",
            [ARStats shortDayLabelFor: day], (long) _counts[i].integerValue];
        [self addToolTipRect: slotRect owner: tip userData: NULL];
    }
}

@end

//------------------------------------------------ rank row ------------------------------------------------

@implementation ARRankRow {
    NSInteger _value;
    NSInteger _largest;
    NSColor *_tint;
}

- (instancetype)initWithName:(NSString *)name
                       value:(NSInteger)value
                     largest:(NSInteger)largest
                        tint:(NSColor *)tint {
    if ((self = [super initWithFrame: NSZeroRect])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _value = value;
        _largest = MAX(largest, 1);
        _tint = tint;

        NSTextField *label = ARLabel(name, ARRowFont(), NSColor.labelColor);
        label.maximumNumberOfLines = 1;
        NSTextField *count = ARLabel([NSString stringWithFormat: @"%ld", (long) value],
            ARValueFont(), NSColor.secondaryLabelColor);
        count.alignment = NSTextAlignmentRight;
        [self addSubview: label];
        [self addSubview: count];
        [NSLayoutConstraint activateConstraints: @[
            [self.heightAnchor constraintEqualToConstant: 38],
            [label.leadingAnchor constraintEqualToAnchor: self.leadingAnchor
                constant: AR_ROW_INSET],
            [label.topAnchor constraintEqualToAnchor: self.topAnchor constant: 6],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor: count.leadingAnchor
                constant: -12],
            [count.trailingAnchor constraintEqualToAnchor: self.trailingAnchor
                constant: -AR_ROW_INSET],
            [count.firstBaselineAnchor constraintEqualToAnchor: label.firstBaselineAnchor],
        ]];
    }
    return self;
}

- (void)drawRect:(NSRect)dirty {
    // A thin bar under the name, the same colour on every row: the colour means
    // clicks saved, not rank.
    CGFloat available = self.bounds.size.width - AR_ROW_INSET * 2;
    CGFloat width = fmax(3, available * _value / _largest);
    NSRect bar = NSMakeRect(AR_ROW_INSET, 7, width, 3);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect: bar
        xRadius: 1.5 yRadius: 1.5];
    [[_tint colorWithAlphaComponent: 0.85] setFill];
    [path fill];
}

@end
